#[cfg(not(windows))]
#[test]
fn m8_worker_supervisor_requires_windows() {
    eprintln!("SKIP: M8 production worker supervisor tests require Windows");
}

#[cfg(windows)]
mod windows {
    use std::ffi::c_void;
    use std::fs;
    use std::mem::{size_of, zeroed};
    use std::path::PathBuf;
    use std::ptr::null_mut;
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    use std::time::{Duration, Instant};

    use serde_json::json;
    use subversionr_daemon::{
        BridgeCancellationToken, ProcessRemoteWorkerSupervisor, RemoteConfigPlan,
        RemoteConfigScheme, RemoteConfigServerAuth, RemoteOperationEffect, RemoteWorkerSettlement,
        RemoteWorkerSupervisor, UnavailableAuthRequestBroker, UnavailableBridge,
    };
    use subversionr_protocol::RemoteOperationEnvelope;

    static FIXTURE_SEQUENCE: AtomicU64 = AtomicU64::new(1);
    const CONTROLLED_WORKER_CRASH_CODE: u32 = 0x5356_5243;
    const TH32CS_SNAPPROCESS: u32 = 0x0000_0002;
    const PROCESS_TERMINATE: u32 = 0x0001;
    const SYNCHRONIZE: u32 = 0x0010_0000;
    const WAIT_OBJECT_0: u32 = 0;
    const STD_INPUT_HANDLE: u32 = -10i32 as u32;
    const INVALID_HANDLE_VALUE: *mut c_void = usize::MAX as *mut c_void;
    const CRASH_REQUEST_BARRIER: &str = "worker-request-read.barrier";

    #[repr(C)]
    struct ProcessEntry32W {
        size: u32,
        usage_count: u32,
        process_id: u32,
        default_heap_id: usize,
        module_id: u32,
        thread_count: u32,
        parent_process_id: u32,
        base_priority: i32,
        flags: u32,
        executable_file: [u16; 260],
    }

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn CreateToolhelp32Snapshot(flags: u32, process_id: u32) -> *mut c_void;
        fn Process32FirstW(snapshot: *mut c_void, entry: *mut ProcessEntry32W) -> i32;
        fn Process32NextW(snapshot: *mut c_void, entry: *mut ProcessEntry32W) -> i32;
        fn GetCurrentProcessId() -> u32;
        fn GetStdHandle(std_handle: u32) -> *mut c_void;
        fn ReadFile(
            file: *mut c_void,
            buffer: *mut c_void,
            bytes_to_read: u32,
            bytes_read: *mut u32,
            overlapped: *mut c_void,
        ) -> i32;
        fn OpenProcess(access: u32, inherit_handle: i32, process_id: u32) -> *mut c_void;
        fn TerminateProcess(process: *mut c_void, exit_code: u32) -> i32;
        fn WaitForSingleObject(handle: *mut c_void, milliseconds: u32) -> u32;
        fn CloseHandle(handle: *mut c_void) -> i32;
        fn GetModuleFileNameW(module: *mut c_void, file_name: *mut u16, size: u32) -> u32;
        fn Sleep(milliseconds: u32);
        fn ExitProcess(exit_code: u32) -> !;
    }

    #[used]
    #[unsafe(link_section = ".CRT$XCU")]
    static CRASH_FIXTURE_INITIALIZER: unsafe extern "C" fn() = stall_crash_fixture_before_main;

    unsafe extern "C" fn stall_crash_fixture_before_main() {
        const CRASH_MARKER: &[u8] = b"subversionr-i6-worker-crash-";
        const PROTOCOL_MARKER: &[u8] = b"subversionr-i6-worker-protocol-";
        let mut module_path = [0u16; 260];
        // SAFETY: the null module denotes the current executable and the buffer is writable.
        let length = unsafe {
            GetModuleFileNameW(
                null_mut(),
                module_path.as_mut_ptr(),
                module_path.len() as u32,
            )
        } as usize;
        if length > 0
            && length < module_path.len()
            && module_path[..length]
                .windows(PROTOCOL_MARKER.len())
                .any(|window| {
                    window
                        .iter()
                        .zip(PROTOCOL_MARKER)
                        .all(|(wide, ascii)| *wide == u16::from(*ascii))
                })
        {
            // SAFETY: this dedicated copied fixture uses the reserved protocol-invalid exit.
            unsafe { ExitProcess(3) };
        }
        if length > 0
            && length < module_path.len()
            && module_path[..length]
                .windows(CRASH_MARKER.len())
                .any(|window| {
                    window
                        .iter()
                        .zip(CRASH_MARKER)
                        .all(|(wide, ascii)| *wide == u16::from(*ascii))
                })
        {
            let input = unsafe { GetStdHandle(STD_INPUT_HANDLE) };
            if input == null_mut() || input == INVALID_HANDLE_VALUE {
                unsafe { ExitProcess(4) };
            }
            let mut header = [0u8; 4];
            if !unsafe { read_exact_handle(input, &mut header) } {
                unsafe { ExitProcess(4) };
            }
            let mut remaining = u32::from_le_bytes(header) as usize;
            if remaining == 0 || remaining > 64 * 1024 {
                unsafe { ExitProcess(4) };
            }
            let mut buffer = [0u8; 4096];
            while remaining > 0 {
                let chunk = remaining.min(buffer.len());
                if !unsafe { read_exact_handle(input, &mut buffer[..chunk]) } {
                    unsafe { ExitProcess(4) };
                }
                remaining -= chunk;
            }
            let Some(temp_root) = std::env::var_os("TEMP") else {
                unsafe { ExitProcess(4) };
            };
            if fs::write(
                PathBuf::from(temp_root).join(CRASH_REQUEST_BARRIER),
                b"ready",
            )
            .is_err()
            {
                unsafe { ExitProcess(4) };
            }
            // SAFETY: this dedicated copied fixture must stall before libtest parses the private arg.
            unsafe { Sleep(u32::MAX) };
        }
    }

    unsafe fn read_exact_handle(handle: *mut c_void, buffer: &mut [u8]) -> bool {
        let mut offset = 0usize;
        while offset < buffer.len() {
            let mut read = 0u32;
            // SAFETY: the caller supplies a valid readable handle and the remaining slice is writable.
            if unsafe {
                ReadFile(
                    handle,
                    buffer[offset..].as_mut_ptr().cast::<c_void>(),
                    (buffer.len() - offset) as u32,
                    &mut read,
                    null_mut(),
                )
            } == 0
                || read == 0
            {
                return false;
            }
            offset += read as usize;
        }
        true
    }

    #[derive(Debug)]
    struct FixedCancellation(AtomicBool);

    impl FixedCancellation {
        fn new(cancelled: bool) -> Self {
            Self(AtomicBool::new(cancelled))
        }
    }

    impl BridgeCancellationToken for FixedCancellation {
        fn is_cancelled(&self) -> bool {
            self.0.load(Ordering::Acquire)
        }
    }

    #[derive(Debug)]
    struct DelayedNotCancelled(Duration);

    impl BridgeCancellationToken for DelayedNotCancelled {
        fn is_cancelled(&self) -> bool {
            std::thread::sleep(self.0);
            false
        }
    }

    #[test]
    fn cancellation_and_protocol_exit_hard_stop_before_releasing_the_lane() {
        let fixture = SupervisorFixture::new();
        fixture
            .supervisor
            .update_workspace_trust(true)
            .expect("trusted initialize must open the launch gate");

        let cancelled = fixture.execute(
            envelope("12700000-0000-4000-8000-000000000101"),
            &FixedCancellation::new(true),
            Instant::now() + Duration::from_secs(5),
        );
        assert_eq!(
            cancelled
                .result
                .as_ref()
                .expect_err("pre-resume cancellation must hard-stop")
                .code(),
            "SUBVERSIONR_REMOTE_WORKER_CANCELLED"
        );
        assert!(!cancelled.worker_was_resumed);
        assert_owned_cleanup(&cancelled);
        fixture.assert_settled();

        let crashed = fixture.execute(
            envelope("12700000-0000-4000-8000-000000000102"),
            &FixedCancellation::new(false),
            Instant::now() + Duration::from_secs(5),
        );
        assert_eq!(
            crashed
                .result
                .as_ref()
                .expect_err("fixture child must use the reserved protocol-invalid exit")
                .code(),
            "SUBVERSIONR_REMOTE_WORKER_PROTOCOL_INVALID"
        );
        assert!(crashed.worker_was_resumed);
        assert_owned_cleanup(&crashed);
        fixture.assert_settled();
    }

    #[test]
    fn controlled_abnormal_exit_is_reported_as_worker_crash_after_owned_cleanup() {
        let fixture = CrashSupervisorFixture::new();
        fixture
            .supervisor
            .update_workspace_trust(true)
            .expect("trusted initialize must open the launch gate");
        let cancellation = FixedCancellation::new(false);

        let crashed = std::thread::scope(|scope| {
            let worker = scope.spawn(|| {
                fixture.execute(
                    envelope("12700000-0000-4000-8000-000000000106"),
                    &cancellation,
                    Instant::now() + Duration::from_secs(5),
                )
            });
            wait_for_crash_request_barrier(&fixture.temp_base);
            terminate_child_process(&fixture.worker_name, CONTROLLED_WORKER_CRASH_CODE);
            worker.join().expect("supervisor thread must settle")
        });

        let failure = crashed
            .result
            .as_ref()
            .expect_err("controlled abnormal exit must fail the worker operation");
        assert_eq!(failure.code(), "SUBVERSIONR_REMOTE_WORKER_CRASHED");
        assert_eq!(failure.safe_args(), &json!({ "stage": "workerProcess" }));
        assert!(crashed.worker_was_resumed);
        assert_owned_cleanup(&crashed);
        fixture.assert_settled();
    }

    #[test]
    fn trust_revoke_closes_pre_registration_launches_and_grant_reopens_them() {
        let fixture = SupervisorFixture::new();
        fixture
            .supervisor
            .update_workspace_trust(true)
            .expect("trusted initialize must open the launch gate");
        fixture
            .supervisor
            .update_workspace_trust(false)
            .expect("revoke with no live worker must settle");

        let revoked = fixture.execute(
            envelope("12700000-0000-4000-8000-000000000103"),
            &FixedCancellation::new(false),
            Instant::now() + Duration::from_secs(5),
        );
        assert_eq!(
            revoked
                .result
                .as_ref()
                .expect_err("revoked launch must never resume")
                .code(),
            "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED"
        );
        assert!(!revoked.worker_was_resumed);
        assert_owned_cleanup(&revoked);
        fixture.assert_settled();

        fixture
            .supervisor
            .update_workspace_trust(true)
            .expect("a later acknowledged grant must reopen launches");
        let cancelled = fixture.execute(
            envelope("12700000-0000-4000-8000-000000000104"),
            &FixedCancellation::new(true),
            Instant::now() + Duration::from_secs(5),
        );
        assert_eq!(
            cancelled
                .result
                .as_ref()
                .expect_err("reopened launch must reach cancellation checkpoint")
                .code(),
            "SUBVERSIONR_REMOTE_WORKER_CANCELLED"
        );
        assert!(!cancelled.worker_was_resumed);
        assert_owned_cleanup(&cancelled);
        fixture.assert_settled();
    }

    #[test]
    fn deadline_expiry_during_suspended_setup_never_resumes_the_worker() {
        let fixture = SupervisorFixture::new();
        fixture
            .supervisor
            .update_workspace_trust(true)
            .expect("trusted initialize must open the launch gate");

        let timed_out = fixture.execute(
            envelope("12700000-0000-4000-8000-000000000105"),
            &DelayedNotCancelled(Duration::from_millis(25)),
            Instant::now() + Duration::from_millis(5),
        );
        assert_eq!(
            timed_out
                .result
                .as_ref()
                .expect_err("expired suspended setup must hard-stop before resume")
                .code(),
            "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT"
        );
        assert!(!timed_out.worker_was_resumed);
        assert_owned_cleanup(&timed_out);
        fixture.assert_settled();
    }

    struct SupervisorFixture {
        supervisor: ProcessRemoteWorkerSupervisor,
        root: PathBuf,
        temp_base: PathBuf,
    }

    struct CrashSupervisorFixture {
        supervisor: ProcessRemoteWorkerSupervisor,
        root: PathBuf,
        temp_base: PathBuf,
        worker_name: String,
    }

    impl SupervisorFixture {
        fn new() -> Self {
            let executable = std::env::current_exe()
                .and_then(|path| path.canonicalize())
                .expect("test executable must resolve");
            let sequence = FIXTURE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let root = std::env::temp_dir().join(format!(
                "subversionr-m8-worker-supervisor-{}-{sequence}",
                std::process::id()
            ));
            let temp_base = root.join("operations");
            fs::create_dir_all(&temp_base).expect("unique supervisor temp root must be created");
            let worker_executable =
                root.join(format!("subversionr-i6-worker-protocol-{sequence}.exe"));
            fs::copy(&executable, &worker_executable)
                .expect("protocol fixture executable must be copied");
            let supervisor = ProcessRemoteWorkerSupervisor::new(
                worker_executable,
                executable,
                temp_base.clone(),
            )
            .expect("production supervisor must accept verified fixture paths");
            Self {
                supervisor,
                root,
                temp_base,
            }
        }

        fn execute(
            &self,
            envelope: RemoteOperationEnvelope,
            cancellation: &dyn BridgeCancellationToken,
            deadline: Instant,
        ) -> RemoteWorkerSettlement {
            let mut auth = UnavailableAuthRequestBroker;
            self.supervisor.execute(
                &envelope,
                plan(envelope.timeout_ms),
                "C:/checkout/worker-supervisor",
                RemoteOperationEffect::ReadOnly,
                cancellation,
                &mut auth,
                &UnavailableBridge,
                deadline,
            )
        }

        fn assert_settled(&self) {
            assert_eq!(self.supervisor.active_worker_count(), 0);
            assert!(
                fs::read_dir(&self.temp_base)
                    .expect("supervisor temp root must remain readable")
                    .next()
                    .is_none(),
                "operation temp roots must be removed before the lane is released"
            );
        }
    }

    impl CrashSupervisorFixture {
        fn new() -> Self {
            let bridge_fixture = std::env::current_exe()
                .and_then(|path| path.canonicalize())
                .expect("test executable must resolve");
            let sequence = FIXTURE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let root = std::env::temp_dir().join(format!(
                "subversionr-m8-worker-crash-{}-{sequence}",
                std::process::id()
            ));
            let temp_base = root.join("operations");
            fs::create_dir_all(&temp_base).expect("crash fixture temp root must be created");
            let worker_name = format!("subversionr-i6-worker-crash-{sequence}.exe");
            let worker_executable = root.join(&worker_name);
            fs::copy(&bridge_fixture, &worker_executable)
                .expect("distinct greeting-stall fixture executable must be copied");
            let supervisor = ProcessRemoteWorkerSupervisor::new(
                worker_executable,
                bridge_fixture,
                temp_base.clone(),
            )
            .expect("production supervisor must accept the crash fixture");
            Self {
                supervisor,
                root,
                temp_base,
                worker_name,
            }
        }

        fn execute(
            &self,
            envelope: RemoteOperationEnvelope,
            cancellation: &dyn BridgeCancellationToken,
            deadline: Instant,
        ) -> RemoteWorkerSettlement {
            let mut auth = UnavailableAuthRequestBroker;
            self.supervisor.execute(
                &envelope,
                plan(envelope.timeout_ms),
                "C:/checkout/worker-supervisor",
                RemoteOperationEffect::ReadOnly,
                cancellation,
                &mut auth,
                &UnavailableBridge,
                deadline,
            )
        }

        fn assert_settled(&self) {
            assert_eq!(self.supervisor.active_worker_count(), 0);
            assert!(
                fs::read_dir(&self.temp_base)
                    .expect("crash operations root must remain readable")
                    .next()
                    .is_none(),
                "operation temp roots must be removed before the lane is released"
            );
        }
    }

    fn assert_owned_cleanup(settlement: &RemoteWorkerSettlement) {
        assert!(settlement.job_descendants_zero);
        assert!(settlement.temp_root_removed);
        assert!(settlement.cleanup_safe());
    }

    impl Drop for SupervisorFixture {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.root).expect("supervisor fixture root must be removable");
        }
    }

    impl Drop for CrashSupervisorFixture {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.root).expect("crash fixture root must be removable");
        }
    }

    fn terminate_child_process(executable_name: &str, exit_code: u32) {
        // SAFETY: GetCurrentProcessId has no preconditions.
        let parent_process_id = unsafe { GetCurrentProcessId() };
        let discovery_deadline = Instant::now() + Duration::from_secs(2);
        loop {
            // SAFETY: the snapshot handle is validated and closed within this iteration.
            let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
            assert_ne!(snapshot, INVALID_HANDLE_VALUE, "process snapshot must open");
            assert_ne!(snapshot, null_mut(), "process snapshot must be valid");
            // SAFETY: zero is valid initialization before setting the required size field.
            let mut entry: ProcessEntry32W = unsafe { zeroed() };
            entry.size = size_of::<ProcessEntry32W>() as u32;
            // SAFETY: the snapshot and entry pointer remain valid for enumeration.
            let mut has_entry = unsafe { Process32FirstW(snapshot, &mut entry) } != 0;
            let mut process_id = None;
            while has_entry {
                let name_length = entry
                    .executable_file
                    .iter()
                    .position(|character| *character == 0)
                    .unwrap_or(entry.executable_file.len());
                let name = String::from_utf16_lossy(&entry.executable_file[..name_length]);
                if entry.parent_process_id == parent_process_id
                    && name.eq_ignore_ascii_case(executable_name)
                {
                    process_id = Some(entry.process_id);
                    break;
                }
                // SAFETY: the snapshot and entry pointer remain valid for enumeration.
                has_entry = unsafe { Process32NextW(snapshot, &mut entry) } != 0;
            }
            // SAFETY: snapshot is a valid owned handle.
            unsafe { CloseHandle(snapshot) };
            if let Some(process_id) = process_id {
                // SAFETY: the enumerated PID is opened only for termination and waiting.
                let process =
                    unsafe { OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, 0, process_id) };
                assert_ne!(process, null_mut(), "fixture worker process must open");
                // SAFETY: process is a valid owned test handle.
                assert_ne!(
                    unsafe { TerminateProcess(process, exit_code) },
                    0,
                    "fixture worker must terminate with the controlled exit code"
                );
                // SAFETY: waiting on and closing the valid handle is permitted exactly once.
                assert_eq!(
                    unsafe { WaitForSingleObject(process, 5_000) },
                    WAIT_OBJECT_0
                );
                unsafe { CloseHandle(process) };
                return;
            }
            assert!(
                Instant::now() < discovery_deadline,
                "controlled fixture worker must be discoverable"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    fn wait_for_crash_request_barrier(temp_base: &PathBuf) {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let observed = fs::read_dir(temp_base)
                .expect("crash operations root must remain readable")
                .filter_map(Result::ok)
                .any(|entry| entry.path().join(CRASH_REQUEST_BARRIER).is_file());
            if observed {
                return;
            }
            assert!(
                Instant::now() < deadline,
                "fixture worker must consume the complete private request before abnormal exit"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    fn plan(timeout_ms: u64) -> RemoteConfigPlan {
        RemoteConfigPlan {
            scheme: RemoteConfigScheme::Https,
            server_auth: RemoteConfigServerAuth::Anonymous,
            timeout_ms,
            trust_windows_roots: true,
        }
    }

    fn envelope(operation_id: &str) -> RemoteOperationEnvelope {
        serde_json::from_value(json!({
            "version": 1,
            "operationId": operation_id,
            "intent": "foreground",
            "interaction": "forbidden",
            "timeoutMs": 5_000,
            "workspaceTrust": "trusted",
            "trustEpoch": 1,
            "profile": {
                "schema": "subversionr.remote-profile.v1",
                "profileId": "worker-supervisor-test",
                "authority": {
                    "scheme": "https",
                    "canonicalHost": "svn.example.invalid",
                    "effectivePort": 443
                },
                "serverAuth": "anonymous",
                "serverAccount": "none",
                "serverCredentialPersistence": "secretStorage",
                "tls": { "trust": "windowsRootsThenBroker" },
                "proxy": "none",
                "ssh": "none",
                "redirectPolicy": "rejectAll"
            },
            "expectedOrigin": {
                "scheme": "https",
                "canonicalHost": "svn.example.invalid",
                "effectivePort": 443
            }
        }))
        .expect("fixture envelope must match the strict public contract")
    }
}

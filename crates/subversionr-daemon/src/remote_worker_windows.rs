use super::*;
use std::collections::HashMap;
use std::ffi::{OsStr, OsString, c_void};
use std::fs::{self, File};
use std::io::{self, Read};
use std::mem::{ManuallyDrop, size_of, zeroed};
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::{FromRawHandle, RawHandle};
use std::ptr::{null, null_mut};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;

use serde_json::{Value, json};

type Bool = i32;
type Dword = u32;
type Handle = *mut c_void;
type SizeT = usize;

const FALSE: Bool = 0;
const TRUE: Bool = 1;
const INVALID_HANDLE_VALUE: Handle = usize::MAX as Handle;
const HANDLE_FLAG_INHERIT: Dword = 1;
const GENERIC_WRITE: Dword = 0x4000_0000;
const OPEN_EXISTING: Dword = 3;
const FILE_ATTRIBUTE_NORMAL: Dword = 0x80;
const STARTF_USESTDHANDLES: Dword = 0x100;
const CREATE_SUSPENDED: Dword = 0x4;
const CREATE_UNICODE_ENVIRONMENT: Dword = 0x400;
const EXTENDED_STARTUPINFO_PRESENT: Dword = 0x0008_0000;
const CREATE_NO_WINDOW: Dword = 0x0800_0000;
const PROC_THREAD_ATTRIBUTE_HANDLE_LIST: usize = 0x0002_0002;
const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: Dword = 0x2000;
const JOB_OBJECT_BASIC_ACCOUNTING_INFORMATION_CLASS: Dword = 1;
const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS: Dword = 9;
const WAIT_OBJECT_0: Dword = 0;
const WAIT_TIMEOUT: Dword = 258;
const PIPE_BUFFER_BYTES: Dword = 4096;
const STD_INPUT_HANDLE: Dword = -10i32 as Dword;
const STD_OUTPUT_HANDLE: Dword = -11i32 as Dword;
const FILE_TYPE_PIPE: Dword = 3;

#[repr(C)]
struct SecurityAttributes {
    length: Dword,
    security_descriptor: *mut c_void,
    inherit_handle: Bool,
}

#[repr(C)]
struct StartupInfoW {
    cb: Dword,
    reserved: *mut u16,
    desktop: *mut u16,
    title: *mut u16,
    x: Dword,
    y: Dword,
    x_size: Dword,
    y_size: Dword,
    x_count_chars: Dword,
    y_count_chars: Dword,
    fill_attribute: Dword,
    flags: Dword,
    show_window: u16,
    reserved2_bytes: u16,
    reserved2: *mut u8,
    std_input: Handle,
    std_output: Handle,
    std_error: Handle,
}

#[repr(C)]
struct StartupInfoExW {
    startup_info: StartupInfoW,
    attribute_list: *mut c_void,
}

#[repr(C)]
struct ProcessInformation {
    process: Handle,
    thread: Handle,
    process_id: Dword,
    thread_id: Dword,
}

#[repr(C)]
#[derive(Default)]
struct IoCounters {
    read_operation_count: u64,
    write_operation_count: u64,
    other_operation_count: u64,
    read_transfer_count: u64,
    write_transfer_count: u64,
    other_transfer_count: u64,
}

#[repr(C)]
#[derive(Default)]
struct JobObjectBasicLimitInformation {
    per_process_user_time_limit: i64,
    per_job_user_time_limit: i64,
    limit_flags: Dword,
    minimum_working_set_size: usize,
    maximum_working_set_size: usize,
    active_process_limit: Dword,
    affinity: usize,
    priority_class: Dword,
    scheduling_class: Dword,
}

#[repr(C)]
#[derive(Default)]
struct JobObjectExtendedLimitInformation {
    basic_limit_information: JobObjectBasicLimitInformation,
    io_info: IoCounters,
    process_memory_limit: usize,
    job_memory_limit: usize,
    peak_process_memory_used: usize,
    peak_job_memory_used: usize,
}

#[repr(C)]
#[derive(Default, Clone, Copy)]
struct JobObjectBasicAccountingInformation {
    total_user_time: i64,
    total_kernel_time: i64,
    this_period_total_user_time: i64,
    this_period_total_kernel_time: i64,
    total_page_fault_count: Dword,
    total_processes: Dword,
    active_processes: Dword,
    total_terminated_processes: Dword,
}

#[link(name = "kernel32")]
unsafe extern "system" {
    fn CreatePipe(
        read_pipe: *mut Handle,
        write_pipe: *mut Handle,
        pipe_attributes: *mut SecurityAttributes,
        size: Dword,
    ) -> Bool;
    fn SetHandleInformation(handle: Handle, mask: Dword, flags: Dword) -> Bool;
    fn GetHandleInformation(handle: Handle, flags: *mut Dword) -> Bool;
    fn GetStdHandle(std_handle: Dword) -> Handle;
    fn GetFileType(handle: Handle) -> Dword;
    fn CreateFileW(
        file_name: *const u16,
        desired_access: Dword,
        share_mode: Dword,
        security_attributes: *mut SecurityAttributes,
        creation_disposition: Dword,
        flags_and_attributes: Dword,
        template_file: Handle,
    ) -> Handle;
    fn CloseHandle(handle: Handle) -> Bool;
    fn InitializeProcThreadAttributeList(
        attribute_list: *mut c_void,
        attribute_count: Dword,
        flags: Dword,
        size: *mut SizeT,
    ) -> Bool;
    fn UpdateProcThreadAttribute(
        attribute_list: *mut c_void,
        flags: Dword,
        attribute: usize,
        value: *mut c_void,
        size: SizeT,
        previous_value: *mut c_void,
        return_size: *mut SizeT,
    ) -> Bool;
    fn DeleteProcThreadAttributeList(attribute_list: *mut c_void);
    fn CreateProcessW(
        application_name: *const u16,
        command_line: *mut u16,
        process_attributes: *mut SecurityAttributes,
        thread_attributes: *mut SecurityAttributes,
        inherit_handles: Bool,
        creation_flags: Dword,
        environment: *mut c_void,
        current_directory: *const u16,
        startup_info: *mut StartupInfoW,
        process_information: *mut ProcessInformation,
    ) -> Bool;
    fn ResumeThread(thread: Handle) -> Dword;
    fn TerminateProcess(process: Handle, exit_code: Dword) -> Bool;
    fn CreateJobObjectW(attributes: *mut SecurityAttributes, name: *const u16) -> Handle;
    fn SetInformationJobObject(
        job: Handle,
        information_class: Dword,
        information: *const c_void,
        information_length: Dword,
    ) -> Bool;
    fn QueryInformationJobObject(
        job: Handle,
        information_class: Dword,
        information: *mut c_void,
        information_length: Dword,
        return_length: *mut Dword,
    ) -> Bool;
    fn AssignProcessToJobObject(job: Handle, process: Handle) -> Bool;
    fn TerminateJobObject(job: Handle, exit_code: Dword) -> Bool;
    fn IsProcessInJob(process: Handle, job: Handle, result: *mut Bool) -> Bool;
    fn GetCurrentProcess() -> Handle;
    fn WaitForSingleObject(handle: Handle, milliseconds: Dword) -> Dword;
}

#[derive(Debug)]
struct OwnedHandle(Handle);

unsafe impl Send for OwnedHandle {}
unsafe impl Sync for OwnedHandle {}

impl OwnedHandle {
    fn new(handle: Handle) -> io::Result<Self> {
        if handle.is_null() || handle == INVALID_HANDLE_VALUE {
            Err(io::Error::last_os_error())
        } else {
            Ok(Self(handle))
        }
    }

    fn raw(&self) -> Handle {
        self.0
    }

    fn into_file(self) -> File {
        let this = ManuallyDrop::new(self);
        // SAFETY: ownership of this valid handle is transferred to File exactly once.
        unsafe { File::from_raw_handle(this.0 as RawHandle) }
    }
}

impl Drop for OwnedHandle {
    fn drop(&mut self) {
        if !self.0.is_null() && self.0 != INVALID_HANDLE_VALUE {
            // SAFETY: this value exclusively owns the kernel handle.
            unsafe { CloseHandle(self.0) };
            self.0 = null_mut();
        }
    }
}

struct PipeEnds {
    read: OwnedHandle,
    write: OwnedHandle,
}

struct AttributeList {
    storage: Vec<usize>,
    _handles: Vec<Handle>,
}

impl AttributeList {
    fn with_handles(handles: &[Handle]) -> io::Result<Self> {
        let mut handles = handles.to_vec();
        let mut bytes = 0usize;
        // SAFETY: documented sizing call with a null output list.
        unsafe { InitializeProcThreadAttributeList(null_mut(), 1, 0, &mut bytes) };
        if bytes == 0 {
            return Err(io::Error::last_os_error());
        }
        let mut storage = vec![0usize; bytes.div_ceil(size_of::<usize>())];
        let pointer = storage.as_mut_ptr().cast::<c_void>();
        let mut initialized_bytes = bytes;
        // SAFETY: the storage has the alignment and size reported by the sizing call.
        if unsafe { InitializeProcThreadAttributeList(pointer, 1, 0, &mut initialized_bytes) }
            == FALSE
        {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: the list and owned handle buffer remain alive through CreateProcessW.
        if unsafe {
            UpdateProcThreadAttribute(
                pointer,
                0,
                PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                handles.as_mut_ptr().cast::<c_void>(),
                size_of_val(handles.as_slice()),
                null_mut(),
                null_mut(),
            )
        } == FALSE
        {
            // SAFETY: list initialization succeeded.
            unsafe { DeleteProcThreadAttributeList(pointer) };
            return Err(io::Error::last_os_error());
        }
        Ok(Self {
            storage,
            _handles: handles,
        })
    }

    fn pointer(&mut self) -> *mut c_void {
        self.storage.as_mut_ptr().cast::<c_void>()
    }
}

impl Drop for AttributeList {
    fn drop(&mut self) {
        // SAFETY: the list was initialized and is deleted exactly once.
        unsafe { DeleteProcThreadAttributeList(self.storage.as_mut_ptr().cast::<c_void>()) };
    }
}

struct SuspendedChild {
    process: Option<OwnedHandle>,
    thread: Option<OwnedHandle>,
}

impl SuspendedChild {
    fn process(&self) -> &OwnedHandle {
        self.process.as_ref().expect("suspended process handle exists")
    }

    fn thread(&self) -> &OwnedHandle {
        self.thread.as_ref().expect("suspended thread handle exists")
    }

    fn disarm(mut self) -> (OwnedHandle, OwnedHandle) {
        (
            self.process.take().expect("suspended process handle exists"),
            self.thread.take().expect("suspended thread handle exists"),
        )
    }
}

impl Drop for SuspendedChild {
    fn drop(&mut self) {
        let Some(process) = self.process.as_ref() else {
            return;
        };
        // SAFETY: the process is still suspended and exclusively supervised here.
        unsafe {
            TerminateProcess(process.raw(), WORKER_TERMINATION_CODE);
            WaitForSingleObject(process.raw(), duration_ms(CLEANUP_TIMEOUT));
        }
    }
}

#[derive(Debug)]
struct ActiveJob {
    job: OwnedHandle,
}

impl ActiveJob {
    fn terminate(&self) {
        // SAFETY: the unnamed operation Job remains valid while this Arc exists.
        unsafe { TerminateJobObject(self.job.raw(), WORKER_TERMINATION_CODE) };
    }

    fn accounting(&self) -> io::Result<JobObjectBasicAccountingInformation> {
        job_accounting(&self.job)
    }
}

#[derive(Debug, Default)]
struct ActiveState {
    next_id: u64,
    launch_allowed: bool,
    launches_in_flight: u64,
    jobs: HashMap<u64, Arc<ActiveJob>>,
}

#[derive(Debug, Default)]
pub(super) struct ActiveWorkerRegistry {
    state: Arc<Mutex<ActiveState>>,
}

struct ActiveRegistration {
    id: u64,
    job: Arc<ActiveJob>,
    state: Arc<Mutex<ActiveState>>,
    retained: bool,
}

struct LaunchReservation {
    state: Arc<Mutex<ActiveState>>,
}

impl ActiveWorkerRegistry {
    fn reserve_launch(
        &self,
        disconnected: &AtomicBool,
        parent_disconnected: &AtomicBool,
    ) -> Result<LaunchReservation, BridgeFailure> {
        let mut state = self.state.lock().expect("active worker mutex poisoned");
        if !state.launch_allowed
            || disconnected.load(Ordering::Acquire)
            || parent_disconnected.load(Ordering::Acquire)
        {
            return Err(disconnected_failure());
        }
        state.launches_in_flight = state
            .launches_in_flight
            .checked_add(1)
            .ok_or_else(worker_start_failure)?;
        Ok(LaunchReservation {
            state: Arc::clone(&self.state),
        })
    }

    fn register(
        &self,
        job: OwnedHandle,
        disconnected: &AtomicBool,
        parent_disconnected: &AtomicBool,
    ) -> Result<ActiveRegistration, BridgeFailure> {
        let mut state = self.state.lock().expect("active worker mutex poisoned");
        if !state.launch_allowed
            || disconnected.load(Ordering::Acquire)
            || parent_disconnected.load(Ordering::Acquire)
        {
            drop(state);
            let job = ActiveJob { job };
            job.terminate();
            if wait_job_zero_until(&job, Instant::now() + CLEANUP_TIMEOUT).is_err() {
                return Err(cleanup_blocked_failure());
            }
            return Err(disconnected_failure());
        }
        let Some(next_id) = state.next_id.checked_add(1) else {
            drop(state);
            let job = ActiveJob { job };
            job.terminate();
            if wait_job_zero_until(&job, Instant::now() + CLEANUP_TIMEOUT).is_err() {
                return Err(cleanup_blocked_failure());
            }
            return Err(worker_start_failure());
        };
        state.next_id = next_id;
        let id = state.next_id;
        let job = Arc::new(ActiveJob { job });
        state.jobs.insert(id, Arc::clone(&job));
        Ok(ActiveRegistration {
            id,
            job,
            state: Arc::clone(&self.state),
            retained: false,
        })
    }

    pub(super) fn count(&self) -> usize {
        self.state
            .lock()
            .expect("active worker mutex poisoned")
            .jobs
            .len()
    }

    pub(super) fn allow_launches(
        &self,
        disconnected: &AtomicBool,
    ) -> Result<(), BridgeFailure> {
        let mut state = self.state.lock().expect("active worker mutex poisoned");
        if disconnected.load(Ordering::Acquire) {
            return Err(disconnected_failure());
        }
        state.launch_allowed = true;
        Ok(())
    }

    pub(super) fn block_launches_and_terminate_all(&self) {
        let jobs = {
            let mut state = self.state.lock().expect("active worker mutex poisoned");
            state.launch_allowed = false;
            state.jobs.values().cloned().collect::<Vec<_>>()
        };
        for job in jobs {
            job.terminate();
        }
    }

    pub(super) fn launches_allowed(&self) -> bool {
        self.state
            .lock()
            .expect("active worker mutex poisoned")
            .launch_allowed
    }

    pub(super) fn wait_for_zero(&self, timeout: Duration) -> Result<(), BridgeFailure> {
        let deadline = Instant::now() + timeout;
        loop {
            let mut state = self.state.lock().expect("active worker mutex poisoned");
            let completed = state
                .jobs
                .iter()
                .filter_map(|(id, job)| {
                    job.accounting()
                        .ok()
                        .filter(|accounting| accounting.active_processes == 0)
                        .map(|_| *id)
                })
                .collect::<Vec<_>>();
            for id in completed {
                state.jobs.remove(&id);
            }
            if state.jobs.is_empty() && state.launches_in_flight == 0 {
                return Ok(());
            }
            drop(state);
            if Instant::now() >= deadline {
                return Err(cleanup_blocked_failure());
            }
            thread::sleep(SUPERVISION_POLL);
        }
    }
}

impl Drop for LaunchReservation {
    fn drop(&mut self) {
        let mut state = self.state.lock().expect("active worker mutex poisoned");
        state.launches_in_flight = state
            .launches_in_flight
            .checked_sub(1)
            .expect("launch reservation count must remain positive");
    }
}

impl Drop for ActiveRegistration {
    fn drop(&mut self) {
        if self.retained {
            return;
        }
        self.state
            .lock()
            .expect("active worker mutex poisoned")
            .jobs
            .remove(&self.id);
    }
}

impl ActiveRegistration {
    fn retain_blocked(mut self) {
        self.retained = true;
    }
}

enum WorkerIoEvent {
    Complete(io::Result<WorkerExchange>),
    Credential {
        request: CredentialRequest,
        responder: mpsc::SyncSender<Result<WorkerIoReply, ()>>,
    },
    Settlement {
        request: CredentialSettlementRequest,
        responder: mpsc::SyncSender<Result<WorkerIoReply, BridgeFailure>>,
    },
}

enum WorkerIoReply {
    Credential(CredentialResponse),
    Settlement(CredentialSettlementAck),
}

struct WorkerExchange {
    response: WorkerResponse,
    result_bytes: Vec<u8>,
    result_chunk_count: u32,
}

pub(super) fn execute_worker(
    worker_executable: &Path,
    bridge_path: &Path,
    temp_base: &Path,
    envelope: &RemoteOperationEnvelope,
    mut plan: RemoteConfigPlan,
    cancellation: &dyn BridgeCancellationToken,
    auth: &mut dyn AuthRequestBroker,
    disconnected: &AtomicBool,
    parent_disconnected: &AtomicBool,
    active: &ActiveWorkerRegistry,
    deadline: Instant,
    execution: WorkerExecution,
    effect: RemoteOperationEffect,
) -> RemoteWorkerSettlement {
    let launch = match active.reserve_launch(disconnected, parent_disconnected) {
        Ok(launch) => launch,
        Err(failure) => return RemoteWorkerSettlement::pre_launch(effect, Err(failure)),
    };
    let operation_temp_root = temp_base.join(format!("subversionr-remote-{}", envelope.operation_id));
    if fs::create_dir(&operation_temp_root).is_err() {
        return RemoteWorkerSettlement::pre_launch(effect, Err(worker_start_failure()));
    }
    let worker_was_resumed = AtomicBool::new(false);
    let hard_stopped = AtomicBool::new(false);
    let job_descendants_zero = AtomicBool::new(true);
    let execution_result = execute_worker_inner(
        worker_executable,
        bridge_path,
        &operation_temp_root,
        envelope,
        &mut plan,
        cancellation,
        auth,
        disconnected,
        parent_disconnected,
        active,
        launch,
        deadline,
        execution,
        &worker_was_resumed,
        &hard_stopped,
        &job_descendants_zero,
    );
    let temp_root_removed = fs::remove_dir_all(&operation_temp_root).is_ok();
    let descendants_zero = job_descendants_zero.load(Ordering::Acquire)
        && !execution_result.as_ref().is_err_and(|failure| {
            failure.code() == "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED"
        });
    let hard_stop = hard_stopped.load(Ordering::Acquire);
    let cleanup_safe = descendants_zero && temp_root_removed;
    let execution_result = if cleanup_safe {
        execution_result
    } else {
        Err(cleanup_blocked_failure())
    };
    let result = execution_result.as_ref().map(|_| ()).map_err(Clone::clone);
    let operation_output = execution_result.ok().flatten();
    let remote_failure = result
        .as_ref()
        .err()
        .map(crate::remote::classify_remote_failure);
    RemoteWorkerSettlement {
        result,
        operation_output,
        remote_failure,
        effect,
        worker_was_resumed: worker_was_resumed.load(Ordering::Acquire),
        execution_origin_known: true,
        termination: if !cleanup_safe {
            WorkerTerminationDisposition::Blocked
        } else if hard_stop {
            WorkerTerminationDisposition::Settled
        } else {
            WorkerTerminationDisposition::NotRequired
        },
        job_descendants_zero: descendants_zero,
        temp_root_removed,
    }
}

pub(super) fn worker_control_channel_is_private() -> bool {
    // SAFETY: these APIs inspect the process standard handles without taking ownership.
    unsafe {
        let input = GetStdHandle(STD_INPUT_HANDLE);
        let output = GetStdHandle(STD_OUTPUT_HANDLE);
        if input.is_null()
            || output.is_null()
            || input == INVALID_HANDLE_VALUE
            || output == INVALID_HANDLE_VALUE
            || GetFileType(input) != FILE_TYPE_PIPE
            || GetFileType(output) != FILE_TYPE_PIPE
        {
            return false;
        }
        let mut input_flags = 0;
        let mut output_flags = 0;
        GetHandleInformation(input, &mut input_flags) != FALSE
            && GetHandleInformation(output, &mut output_flags) != FALSE
            && input_flags & HANDLE_FLAG_INHERIT != 0
            && output_flags & HANDLE_FLAG_INHERIT != 0
    }
}

#[allow(clippy::too_many_arguments)]
fn execute_worker_inner(
    worker_executable: &Path,
    bridge_path: &Path,
    operation_temp_root: &Path,
    envelope: &RemoteOperationEnvelope,
    plan: &mut RemoteConfigPlan,
    cancellation: &dyn BridgeCancellationToken,
    auth: &mut dyn AuthRequestBroker,
    disconnected: &AtomicBool,
    parent_disconnected: &AtomicBool,
    active: &ActiveWorkerRegistry,
    launch: LaunchReservation,
    deadline: Instant,
    execution: WorkerExecution,
    worker_was_resumed: &AtomicBool,
    hard_stopped: &AtomicBool,
    job_descendants_zero: &AtomicBool,
) -> Result<Option<RemoteSvnAnonymousOutput>, BridgeFailure> {
    plan.timeout_ms = remaining_timeout_ms(deadline, plan.timeout_ms)?;

    let bridge_path = bridge_path.to_str().ok_or_else(worker_start_failure)?;
    let operation_temp_root_text = operation_temp_root
        .to_str()
        .ok_or_else(worker_start_failure)?;
    let request = WorkerRequest {
        protocol_version: PRIVATE_WORKER_PROTOCOL_VERSION,
        request_id: envelope.operation_id.clone(),
        bridge_path: bridge_path.to_string(),
        operation_temp_root: operation_temp_root_text.to_string(),
        envelope: envelope.clone(),
        plan: *plan,
        execution,
    };
    let start_frame = ParentWorkerFrame::Start {
        protocol_version: PRIVATE_WORKER_PROTOCOL_VERSION,
        request,
    };
    let request_bytes = serde_json::to_vec(&start_frame).map_err(|_| worker_protocol_failure())?;
    if request_bytes.is_empty() || request_bytes.len() > MAX_REQUEST_FRAME_BYTES {
        return Err(worker_protocol_failure());
    }

    let inbound = create_pipe().map_err(|error| win32_start_failure("stdinPipe", &error))?;
    let outbound = create_pipe().map_err(|error| win32_start_failure("stdoutPipe", &error))?;
    clear_inherit(&inbound.write)
        .map_err(|error| win32_start_failure("stdinParentHandle", &error))?;
    clear_inherit(&outbound.read)
        .map_err(|error| win32_start_failure("stdoutParentHandle", &error))?;
    let stderr = open_inheritable_nul()
        .map_err(|error| win32_start_failure("stderrHandle", &error))?;

    query_current_job_state().map_err(|error| win32_start_failure("parentJobQuery", &error))?;
    let child = spawn_suspended(
        worker_executable,
        inbound.read.raw(),
        outbound.write.raw(),
        stderr.raw(),
        operation_temp_root,
    )
    .map_err(|error| win32_start_failure("createProcess", &error))?;
    let job = new_kill_on_close_job().map_err(|error| win32_start_failure("createJob", &error))?;
    assign_and_verify(&job, child.process())
        .map_err(|error| win32_start_failure("assignJob", &error))?;
    let registration = active.register(job, disconnected, parent_disconnected)?;
    job_descendants_zero.store(false, Ordering::Release);
    drop(launch);
    if disconnected.load(Ordering::Acquire) || parent_disconnected.load(Ordering::Acquire) {
        registration.job.terminate();
        return finish_hard_stop(
            hard_stopped,
            job_descendants_zero,
            registration,
            operation_temp_root,
            disconnected_failure(),
            None,
        );
    }
    if cancellation.is_cancelled() {
        registration.job.terminate();
        return finish_hard_stop(hard_stopped, job_descendants_zero, registration, operation_temp_root, cancelled_failure(), None);
    }
    if Instant::now() >= deadline {
        registration.job.terminate();
        return finish_hard_stop(hard_stopped, job_descendants_zero, registration, operation_temp_root, timed_out_failure(), None);
    }

    // SAFETY: this is the primary thread from CREATE_SUSPENDED and containment was verified.
    let previous = unsafe { ResumeThread(child.thread().raw()) };
    if previous != 1 {
        registration.job.terminate();
        return finish_hard_stop(hard_stopped, job_descendants_zero, registration, operation_temp_root, worker_start_failure(), None);
    }
    worker_was_resumed.store(true, Ordering::Release);
    let (process, thread_handle) = child.disarm();
    drop(thread_handle);
    drop(inbound.read);
    drop(outbound.write);
    drop(stderr);

    let request_writer = inbound.write.into_file();
    let response_reader = outbound.read.into_file();
    let (sender, receiver) = mpsc::sync_channel(4);
    let expected_operation_id = envelope.operation_id.clone();
    let io_thread = thread::spawn(move || {
        let result = exchange_frames(
            request_writer,
            response_reader,
            &request_bytes,
            &expected_operation_id,
            &sender,
        );
        let _ = sender.send(WorkerIoEvent::Complete(result));
    });

    let response = loop {
        if disconnected.load(Ordering::Acquire) || parent_disconnected.load(Ordering::Acquire) {
            registration.job.terminate();
            return finish_hard_stop(
                hard_stopped,
                job_descendants_zero,
                registration,
                operation_temp_root,
                disconnected_failure(),
                Some(io_thread),
            );
        }
        if cancellation.is_cancelled() {
            registration.job.terminate();
            return finish_hard_stop(
                hard_stopped,
                job_descendants_zero,
                registration,
                operation_temp_root,
                cancelled_failure(),
                Some(io_thread),
            );
        }
        let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
            registration.job.terminate();
            return finish_hard_stop(
                hard_stopped,
                job_descendants_zero,
                registration,
                operation_temp_root,
                timed_out_failure(),
                Some(io_thread),
            );
        };
        match receiver.recv_timeout(remaining.min(SUPERVISION_POLL)) {
            Ok(WorkerIoEvent::Complete(Ok(response))) => break response,
            Ok(WorkerIoEvent::Complete(Err(_))) => {
                registration.job.terminate();
                return finish_hard_stop(
                    hard_stopped,
                    job_descendants_zero,
                    registration,
                    operation_temp_root,
                    worker_protocol_failure(),
                    Some(io_thread),
                );
            }
            Ok(WorkerIoEvent::Credential { request, responder }) => {
                match auth.request_credential(request) {
                    Ok(response) => {
                        if responder.send(Ok(WorkerIoReply::Credential(response))).is_err() {
                            registration.job.terminate();
                            return finish_hard_stop(
                                hard_stopped,
                                job_descendants_zero,
                                registration,
                                operation_temp_root,
                                worker_protocol_failure(),
                                Some(io_thread),
                            );
                        }
                    }
                    Err(failure) => {
                        let _ = responder.send(Err(()));
                        registration.job.terminate();
                        return finish_hard_stop(
                            hard_stopped,
                            job_descendants_zero,
                            registration,
                            operation_temp_root,
                            failure,
                            Some(io_thread),
                        );
                    }
                }
            }
            Ok(WorkerIoEvent::Settlement { request, responder }) => {
                match auth.settle_credential(request) {
                    Ok(ack) => {
                        if responder.send(Ok(WorkerIoReply::Settlement(ack))).is_err() {
                            registration.job.terminate();
                            return finish_hard_stop(
                                hard_stopped,
                                job_descendants_zero,
                                registration,
                                operation_temp_root,
                                worker_protocol_failure(),
                                Some(io_thread),
                            );
                        }
                    }
                    Err(failure) => {
                        let failure = match validate_credential_settlement_wire_failure(
                            WireFailure::from_bridge(failure),
                        ) {
                            Ok(failure) => failure,
                            Err(failure) => {
                                registration.job.terminate();
                                return finish_hard_stop(
                                    hard_stopped,
                                    job_descendants_zero,
                                    registration,
                                    operation_temp_root,
                                    failure,
                                    Some(io_thread),
                                );
                            }
                        };
                        if responder.send(Err(failure)).is_err() {
                            registration.job.terminate();
                            return finish_hard_stop(
                                hard_stopped,
                                job_descendants_zero,
                                registration,
                                operation_temp_root,
                                worker_protocol_failure(),
                                Some(io_thread),
                            );
                        }
                    }
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                registration.job.terminate();
                return finish_hard_stop(
                    hard_stopped,
                    job_descendants_zero,
                    registration,
                    operation_temp_root,
                    worker_protocol_failure(),
                    Some(io_thread),
                );
            }
        }
    };

    let response = match validate_response(response, envelope) {
        Ok(response) => response,
        Err(failure) => {
            registration.job.terminate();
            return finish_hard_stop(
                hard_stopped,
                job_descendants_zero,
                registration,
                operation_temp_root,
                failure,
                Some(io_thread),
            );
        }
    };
    loop {
        // SAFETY: process is the valid child process handle.
        match unsafe { WaitForSingleObject(process.raw(), 0) } {
            WAIT_OBJECT_0 => break,
            WAIT_TIMEOUT => {}
            _ => {
                registration.job.terminate();
                return finish_hard_stop(
                    hard_stopped,
                    job_descendants_zero,
                    registration,
                    operation_temp_root,
                    worker_protocol_failure(),
                    Some(io_thread),
                );
            }
        }
        if Instant::now() >= deadline {
            registration.job.terminate();
            return finish_hard_stop(
                hard_stopped,
                job_descendants_zero,
                registration,
                operation_temp_root,
                timed_out_failure(),
                Some(io_thread),
            );
        }
        thread::sleep(SUPERVISION_POLL);
    }
    if wait_job_zero_until(&registration.job, deadline).is_err() {
        registration.job.terminate();
        return finish_hard_stop(
            hard_stopped,
            job_descendants_zero,
            registration,
            operation_temp_root,
            timed_out_failure(),
            Some(io_thread),
        );
    }
    drop(process);
    drop(registration);
    job_descendants_zero.store(true, Ordering::Release);
    io_thread.join().map_err(|_| worker_protocol_failure())?;
    Ok(response)
}

fn finish_hard_stop(
    hard_stopped: &AtomicBool,
    job_descendants_zero: &AtomicBool,
    registration: ActiveRegistration,
    _operation_temp_root: &Path,
    settled: BridgeFailure,
    io_thread: Option<thread::JoinHandle<()>>,
) -> Result<Option<RemoteSvnAnonymousOutput>, BridgeFailure> {
    hard_stopped.store(true, Ordering::Release);
    let cleanup_deadline = Instant::now() + CLEANUP_TIMEOUT;
    if wait_job_zero_until(&registration.job, cleanup_deadline).is_err() {
        registration.retain_blocked();
        return Err(cleanup_blocked_failure());
    }
    job_descendants_zero.store(true, Ordering::Release);
    drop(registration);
    if let Some(io_thread) = io_thread {
        io_thread.join().map_err(|_| worker_protocol_failure())?;
    }
    Err(settled)
}

fn exchange_frames(
    mut writer: File,
    mut reader: File,
    request: &[u8],
    expected_operation_id: &str,
    events: &mpsc::SyncSender<WorkerIoEvent>,
) -> io::Result<WorkerExchange> {
    write_frame(&mut writer, request, MAX_REQUEST_FRAME_BYTES)?;
    writer.flush()?;
    let mut expected_sequence = 1u32;
    let mut expected_result_sequence = 0u32;
    let mut result_bytes = Vec::new();
    let mut result_started = false;
    loop {
        let bytes = read_frame(&mut reader, MAX_RESPONSE_FRAME_BYTES)?;
        let frame: ChildWorkerFrame = serde_json::from_slice(&bytes)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid worker frame"))?;
        match frame {
            ChildWorkerFrame::CredentialRequest {
                protocol_version,
                operation_id,
                sequence,
                request,
            } if protocol_version == PRIVATE_WORKER_PROTOCOL_VERSION
                && operation_id == expected_operation_id
                && operation_id == request.operation_id
                && sequence == expected_sequence
                && !result_started =>
            {
                let (responder, response) = mpsc::sync_channel(1);
                events
                    .send(WorkerIoEvent::Credential { request, responder })
                    .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "worker broker closed"))?;
                let reply = response.recv().map_err(|_| {
                    io::Error::new(io::ErrorKind::BrokenPipe, "worker broker reply closed")
                })?.map_err(|_| io::Error::new(io::ErrorKind::PermissionDenied, "worker broker rejected"))?;
                let WorkerIoReply::Credential(response) = reply else {
                    return Err(io::Error::new(io::ErrorKind::InvalidData, "worker broker reply kind"));
                };
                let parent = ParentWorkerFrame::CredentialResponse {
                    protocol_version: PRIVATE_WORKER_PROTOCOL_VERSION,
                    operation_id,
                    sequence,
                    response,
                };
                write_parent_worker_frame(&mut writer, &parent)?;
                expected_sequence = expected_sequence.checked_add(1).ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidData, "worker sequence overflow")
                })?;
            }
            ChildWorkerFrame::CredentialSettlement {
                protocol_version,
                operation_id,
                sequence,
                request,
            } if protocol_version == PRIVATE_WORKER_PROTOCOL_VERSION
                && operation_id == expected_operation_id
                && operation_id == request.operation_id
                && sequence == expected_sequence
                && !result_started =>
            {
                let (responder, response) = mpsc::sync_channel(1);
                events
                    .send(WorkerIoEvent::Settlement { request, responder })
                    .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "worker broker closed"))?;
                let reply = response.recv().map_err(|_| {
                    io::Error::new(io::ErrorKind::BrokenPipe, "worker broker reply closed")
                })?;
                let parent = settlement_parent_frame(operation_id, sequence, reply)?;
                write_parent_worker_frame(&mut writer, &parent)?;
                expected_sequence = expected_sequence.checked_add(1).ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidData, "worker sequence overflow")
                })?;
            }
            ChildWorkerFrame::ResultChunk {
                protocol_version,
                operation_id,
                sequence,
                data_base64,
            } if protocol_version == PRIVATE_WORKER_PROTOCOL_VERSION
                && operation_id == expected_operation_id
                && sequence == expected_result_sequence =>
            {
                result_started = true;
                let chunk = STANDARD.decode(data_base64).map_err(|_| {
                    io::Error::new(io::ErrorKind::InvalidData, "invalid worker result chunk")
                })?;
                if chunk.is_empty()
                    || chunk.len() > OPERATION_RESULT_CHUNK_BYTES
                    || result_bytes.len().saturating_add(chunk.len()) > MAX_OPERATION_RESULT_BYTES
                {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "worker result size",
                    ));
                }
                result_bytes.extend_from_slice(&chunk);
                expected_result_sequence = expected_result_sequence.checked_add(1).ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidData, "worker result sequence overflow")
                })?;
            }
            ChildWorkerFrame::Final {
                protocol_version,
                operation_id,
                response,
            } if protocol_version == PRIVATE_WORKER_PROTOCOL_VERSION
                && operation_id == expected_operation_id
                && response.operation_id == expected_operation_id => {
                drop(writer);
                let mut trailing = [0u8; 1];
                if reader.read(&mut trailing)? != 0 {
                    return Err(io::Error::new(io::ErrorKind::InvalidData, "worker emitted trailing data"));
                }
                return Ok(WorkerExchange {
                    response,
                    result_bytes,
                    result_chunk_count: expected_result_sequence,
                });
            }
            _ => return Err(io::Error::new(io::ErrorKind::InvalidData, "worker frame order")),
        }
    }
}

fn settlement_parent_frame(
    operation_id: String,
    sequence: u32,
    reply: Result<WorkerIoReply, BridgeFailure>,
) -> io::Result<ParentWorkerFrame> {
    match reply {
        Ok(WorkerIoReply::Settlement(ack)) => Ok(ParentWorkerFrame::CredentialSettlementAck {
            protocol_version: PRIVATE_WORKER_PROTOCOL_VERSION,
            operation_id,
            sequence,
            ack,
        }),
        Ok(_) => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "worker broker reply kind",
        )),
        Err(failure) => {
            let failure = validate_credential_settlement_wire_failure(WireFailure::from_bridge(
                failure,
            ))
            .map_err(|_| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "worker broker failure contract",
                )
            })?;
            Ok(ParentWorkerFrame::CredentialSettlementFailure {
                protocol_version: PRIVATE_WORKER_PROTOCOL_VERSION,
                operation_id,
                sequence,
                failure: WireFailure::from_bridge(failure),
            })
        }
    }
}

fn write_parent_worker_frame(writer: &mut File, frame: &ParentWorkerFrame) -> io::Result<()> {
    let bytes = serde_json::to_vec(frame)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid parent worker frame"))?;
    write_frame(writer, &bytes, MAX_REQUEST_FRAME_BYTES)?;
    writer.flush()
}

fn validate_response(
    exchange: WorkerExchange,
    envelope: &RemoteOperationEnvelope,
) -> Result<Option<RemoteSvnAnonymousOutput>, BridgeFailure> {
    let WorkerExchange {
        response,
        result_bytes,
        result_chunk_count,
    } = exchange;
    if response.protocol_version != PRIVATE_WORKER_PROTOCOL_VERSION
        || response.request_id != envelope.operation_id
        || response.operation_id != envelope.operation_id
    {
        return Err(worker_protocol_failure());
    }
    match response.result {
        WorkerResult::Success {
            operation_result: None,
        } if result_bytes.is_empty() && result_chunk_count == 0 => Ok(None),
        WorkerResult::Success {
            operation_result: Some(descriptor),
        } => {
            if descriptor.byte_count as usize != result_bytes.len()
                || descriptor.chunk_count != result_chunk_count
                || descriptor.chunk_count == 0
                || !is_lowercase_sha256(&descriptor.sha256)
                || format!("{:x}", Sha256::digest(&result_bytes)) != descriptor.sha256
            {
                return Err(worker_protocol_failure());
            }
            serde_json::from_slice::<RemoteSvnAnonymousOutput>(&result_bytes)
                .map(Some)
                .map_err(|_| worker_protocol_failure())
        }
        WorkerResult::Failure { failure }
            if result_bytes.is_empty() && result_chunk_count == 0 =>
        {
            Err(validate_wire_failure(failure)?)
        }
        _ => Err(worker_protocol_failure()),
    }
}

fn validate_wire_failure(failure: WireFailure) -> Result<BridgeFailure, BridgeFailure> {
    if matches!(
        failure.code.as_str(),
        "SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE"
            | "SUBVERSIONR_CREDENTIAL_TIMEOUT"
            | "SUBVERSIONR_CREDENTIAL_LEASE_UNKNOWN"
            | "SUBVERSIONR_CREDENTIAL_LEASE_FOREIGN"
            | "SUBVERSIONR_CREDENTIAL_LEASE_EXPIRED"
            | "SUBVERSIONR_CREDENTIAL_SETTLEMENT_CONFLICT"
    ) {
        return validate_credential_settlement_wire_failure(failure);
    }
    if failure.retryable {
        return Err(worker_protocol_failure());
    }
    if let Some((category, key, args_kind, diagnostics_allowed)) =
        svn_anonymous_failure_contract(&failure.code)
    {
        if failure.category != category
            || failure.message_key != key
            || !validate_svn_anonymous_failure_args(&failure.args, args_kind)
            || !validate_wire_diagnostics(failure.diagnostics.as_ref(), diagnostics_allowed)
        {
            return Err(worker_protocol_failure());
        }
        let mut validated = BridgeFailure::new(
            failure.code,
            category,
            key,
            failure.args,
            false,
        );
        if let Some(diagnostics) = failure.diagnostics {
            validated = validated.with_diagnostics(diagnostics);
        }
        return Ok(validated);
    }
    let (category, key, permits_status) = match failure.code.as_str() {
        "SUBVERSIONR_REMOTE_CONFIG_CREATE_FAILED" => {
            ("native", "error.remote.configCreateFailed", true)
        }
        "SUBVERSIONR_REMOTE_CONFIG_CREATE_NULL" => {
            ("native", "error.remote.configCreateNull", true)
        }
        "SUBVERSIONR_REMOTE_CONFIG_INSPECTION_FAILED" => {
            ("native", "error.remote.configInspectionFailed", true)
        }
        "SUBVERSIONR_REMOTE_CONFIG_INSPECTION_INVALID" => {
            ("native", "error.remote.configInspectionInvalid", false)
        }
        "SUBVERSIONR_REMOTE_WORKER_START_FAILED" => {
            ("process", "error.remote.workerStartFailed", false)
        }
        _ => return Err(worker_protocol_failure()),
    };
    if failure.category != category
        || failure.message_key != key
        || failure.diagnostics.is_some()
        || (permits_status
            && !failure.args.as_object().is_some_and(|args| {
                args.len() == 1 && args.get("status").is_some_and(Value::is_i64)
            }))
        || (!permits_status && failure.args != json!({}))
    {
        return Err(worker_protocol_failure());
    }
    Ok(BridgeFailure::new(
        failure.code,
        category,
        key,
        failure.args,
        false,
    ))
}

#[derive(Clone, Copy)]
enum WireFailureArgsKind {
    Empty,
    PathStatus,
    PathStatusMutation,
    PathStatusOptionalMutation,
    AnonymousAuth,
}

fn svn_anonymous_failure_contract(
    code: &str,
) -> Option<(&'static str, &'static str, WireFailureArgsKind, bool)> {
    use WireFailureArgsKind::*;
    let contract = match code {
        "SUBVERSIONR_REMOTE_WORKER_PROTOCOL_INVALID" => (
            "protocol",
            "error.remote.workerProtocolInvalid",
            Empty,
            false,
        ),
        "SUBVERSIONR_REMOTE_CONTRACT_INVALID" => (
            "configuration",
            "error.remote.contractInvalid",
            Empty,
            false,
        ),
        "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH" => (
            "configuration",
            "error.remote.originMismatch",
            Empty,
            true,
        ),
        "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED" => (
            "unsupported",
            "error.remote.authUnsupported",
            AnonymousAuth,
            false,
        ),
        "SVN_BRIDGE_INVALID_ARGUMENT" => (
            "native",
            "error.native.bridgeInvalidArgument",
            PathStatus,
            true,
        ),
        "SVN_BRIDGE_UNHANDLED_STATUS" => (
            "native",
            "error.native.bridgeUnhandledStatus",
            PathStatus,
            true,
        ),
        "SVN_REMOTE_STATUS_FAILED" => (
            "network",
            "error.native.remoteStatusFailed",
            PathStatus,
            true,
        ),
        "SVN_REMOTE_STATUS_CANCEL_CALLBACK_FAILED" => (
            "native",
            "error.native.remoteStatusCancelCallbackFailed",
            PathStatus,
            true,
        ),
        "SVN_REMOTE_STATUS_CANCELLED" => (
            "cancelled",
            "error.native.remoteStatusCancelled",
            PathStatus,
            true,
        ),
        "SVN_REMOTE_STATUS_AUTH_FAILED" => (
            "auth",
            "error.native.remoteStatusAuthFailed",
            PathStatus,
            true,
        ),
        "SVN_CONTENT_FAILED" => (
            "native",
            "error.native.contentFailed",
            PathStatus,
            true,
        ),
        "SVN_CONTENT_REVISION_UNSUPPORTED" => (
            "native",
            "error.native.contentRevisionUnsupported",
            PathStatus,
            true,
        ),
        "SVN_HISTORY_LOG_FAILED" => (
            "native",
            "error.native.historyLogFailed",
            PathStatus,
            true,
        ),
        "SVN_HISTORY_BLAME_FAILED" => (
            "native",
            "error.native.historyBlameFailed",
            PathStatus,
            true,
        ),
        "SVN_HISTORY_REVISION_UNSUPPORTED" => (
            "native",
            "error.native.historyRevisionUnsupported",
            PathStatus,
            true,
        ),
        "SVN_HISTORY_BLAME_BINARY_FILE" => (
            "native",
            "error.native.historyBlameBinaryFile",
            PathStatus,
            true,
        ),
        "SVN_REPOSITORY_CHECKOUT_FAILED" => (
            "native",
            "error.native.repositoryCheckoutFailed",
            PathStatus,
            true,
        ),
        "SVN_REPOSITORY_CHECKOUT_DEPTH_UNSUPPORTED" => (
            "native",
            "error.native.repositoryCheckoutDepthUnsupported",
            PathStatus,
            true,
        ),
        "SVN_REPOSITORY_CHECKOUT_REVISION_UNSUPPORTED" => (
            "native",
            "error.native.repositoryCheckoutRevisionUnsupported",
            PathStatus,
            true,
        ),
        "SVN_REPOSITORY_CHECKOUT_EXTERNALS_POLICY_UNSUPPORTED" => (
            "native",
            "error.native.repositoryCheckoutExternalsPolicyUnsupported",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_UPDATE_FAILED" => (
            "native",
            "error.native.operationUpdateFailed",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_DEPTH_UNSUPPORTED" => (
            "native",
            "error.native.operationDepthUnsupported",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_UPDATE_REVISION_UNSUPPORTED" => (
            "native",
            "error.native.operationUpdateRevisionUnsupported",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_UPDATE_STICKY_DEPTH_UNSUPPORTED" => (
            "native",
            "error.native.operationUpdateStickyDepthUnsupported",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_UPDATE_EXTERNALS_POLICY_UNSUPPORTED" => (
            "native",
            "error.native.operationUpdateExternalsPolicyUnsupported",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_LOCK_FAILED" => (
            "native",
            "error.native.operationLockFailed",
            PathStatusMutation,
            true,
        ),
        "SVN_OPERATION_UNLOCK_FAILED" => (
            "native",
            "error.native.operationUnlockFailed",
            PathStatusMutation,
            true,
        ),
        "SVN_OPERATION_BRANCH_CREATE_FAILED" => (
            "native",
            "error.native.operationBranchCreateFailed",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_BRANCH_CREATE_MESSAGE_INVALID" => (
            "native",
            "error.native.operationBranchCreateMessageInvalid",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_BRANCH_CREATE_REVISION_UNSUPPORTED" => (
            "native",
            "error.native.operationBranchCreateRevisionUnsupported",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_BRANCH_CREATE_PARENTS_POLICY_UNSUPPORTED" => (
            "native",
            "error.native.operationBranchCreateParentsPolicyUnsupported",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_BRANCH_CREATE_EXTERNALS_POLICY_UNSUPPORTED" => (
            "native",
            "error.native.operationBranchCreateExternalsPolicyUnsupported",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_BRANCH_CREATE_REVISION_MISSING" => (
            "native",
            "error.native.operationBranchCreateRevisionMissing",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_SWITCH_FAILED" => (
            "native",
            "error.native.operationSwitchFailed",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_SWITCH_REVISION_UNSUPPORTED" => (
            "native",
            "error.native.operationSwitchRevisionUnsupported",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_SWITCH_STICKY_DEPTH_UNSUPPORTED" => (
            "native",
            "error.native.operationSwitchStickyDepthUnsupported",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_SWITCH_EXTERNALS_POLICY_UNSUPPORTED" => (
            "native",
            "error.native.operationSwitchExternalsPolicyUnsupported",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_SWITCH_REVISION_MISSING" => (
            "native",
            "error.native.operationSwitchRevisionMissing",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_SWITCH_ANCESTRY_POLICY_UNSUPPORTED" => (
            "native",
            "error.native.operationSwitchAncestryPolicyUnsupported",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_COMMIT_FAILED" => (
            "native",
            "error.native.operationCommitFailed",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_COMMIT_CHANGELISTS_INVALID" => (
            "native",
            "error.native.operationCommitChangelistsInvalid",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_COMMIT_OPTIONS_UNSUPPORTED" => (
            "native",
            "error.native.operationCommitOptionsUnsupported",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_COMMIT_MESSAGE_INVALID" => (
            "native",
            "error.native.operationCommitMessageInvalid",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_COMMIT_NO_CHANGES" => (
            "native",
            "error.native.operationCommitNoChanges",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_COMMIT_TARGET_NOT_FILE" => (
            "native",
            "error.native.operationCommitTargetNotFile",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_AUTH_CALLBACK_FAILED" => (
            "native",
            "error.native.operationAuthCallbackFailed",
            PathStatus,
            true,
        ),
        "SVN_OPERATION_CANCEL_CALLBACK_FAILED" => (
            "native",
            "error.native.operationCancelCallbackFailed",
            PathStatusOptionalMutation,
            true,
        ),
        "SVN_OPERATION_CANCELLED" => (
            "cancelled",
            "error.native.operationCancelled",
            PathStatusOptionalMutation,
            true,
        ),
        _ => return None,
    };
    Some(contract)
}

fn validate_svn_anonymous_failure_args(args: &Value, kind: WireFailureArgsKind) -> bool {
    let Some(object) = args.as_object() else {
        return false;
    };
    match kind {
        WireFailureArgsKind::Empty => object.is_empty(),
        WireFailureArgsKind::AnonymousAuth => {
            object.len() == 2
                && object.get("scheme").and_then(Value::as_str) == Some("svn")
                && object.get("auth").and_then(Value::as_str) == Some("anonymous")
        }
        WireFailureArgsKind::PathStatus => validate_path_status_args(object, false, false),
        WireFailureArgsKind::PathStatusMutation => validate_path_status_args(object, true, false),
        WireFailureArgsKind::PathStatusOptionalMutation => {
            validate_path_status_args(object, false, true)
        }
    }
}

fn validate_path_status_args(
    object: &serde_json::Map<String, Value>,
    requires_mutation: bool,
    permits_mutation: bool,
) -> bool {
    let Some(path) = object.get("path").and_then(Value::as_str) else {
        return false;
    };
    if path.is_empty() || path.len() > 32 * 1024 {
        return false;
    }
    let Some(status) = object.get("status").and_then(Value::as_i64) else {
        return false;
    };
    if i32::try_from(status).is_err() {
        return false;
    }
    let mutation = object.get("mayHaveMutated");
    if requires_mutation {
        object.len() == 3 && mutation.is_some_and(Value::is_boolean)
    } else if permits_mutation {
        (object.len() == 2 && mutation.is_none())
            || (object.len() == 3 && mutation.and_then(Value::as_bool) == Some(true))
    } else {
        object.len() == 2 && mutation.is_none()
    }
}

fn validate_wire_diagnostics(
    diagnostics: Option<&OperationFailureDiagnostics>,
    allowed: bool,
) -> bool {
    let Some(diagnostics) = diagnostics else {
        return true;
    };
    allowed
        && !diagnostics.svn.entries.is_empty()
        && diagnostics.svn.entries.len() <= 8
        && diagnostics.svn.entries.iter().all(|entry| {
            !entry.name.is_empty()
                && entry.name.len() <= 128
                && entry.name.bytes().all(|byte| {
                    byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_'
                })
                && (entry.name.starts_with("SVN_ERR_")
                    || entry.name == "SUBVERSIONR_ERR_REMOTE_ORIGIN_MISMATCH")
        })
}

fn create_pipe() -> io::Result<PipeEnds> {
    let mut read = null_mut();
    let mut write = null_mut();
    let mut attributes = inheritable_attributes();
    // SAFETY: output pointers and attributes are valid.
    if unsafe { CreatePipe(&mut read, &mut write, &mut attributes, PIPE_BUFFER_BYTES) } == FALSE {
        return Err(io::Error::last_os_error());
    }
    Ok(PipeEnds {
        read: OwnedHandle::new(read)?,
        write: OwnedHandle::new(write)?,
    })
}

fn inheritable_attributes() -> SecurityAttributes {
    SecurityAttributes {
        length: size_of::<SecurityAttributes>() as Dword,
        security_descriptor: null_mut(),
        inherit_handle: TRUE,
    }
}

fn clear_inherit(handle: &OwnedHandle) -> io::Result<()> {
    // SAFETY: handle is valid and owned by the parent.
    if unsafe { SetHandleInformation(handle.raw(), HANDLE_FLAG_INHERIT, 0) } == FALSE {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn require_inheritable(handle: Handle) -> io::Result<()> {
    let mut flags = 0;
    // SAFETY: handle was created by this process.
    if unsafe { GetHandleInformation(handle, &mut flags) } == FALSE
        || flags & HANDLE_FLAG_INHERIT == 0
    {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn open_inheritable_nul() -> io::Result<OwnedHandle> {
    let name = wide_null(OsStr::new("NUL"))?;
    let mut attributes = inheritable_attributes();
    // SAFETY: all input pointers are valid through the call.
    OwnedHandle::new(unsafe {
        CreateFileW(
            name.as_ptr(),
            GENERIC_WRITE,
            0,
            &mut attributes,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            null_mut(),
        )
    })
}

fn spawn_suspended(
    executable: &Path,
    stdin: Handle,
    stdout: Handle,
    stderr: Handle,
    temp_root: &Path,
) -> io::Result<SuspendedChild> {
    for handle in [stdin, stdout, stderr] {
        require_inheritable(handle)?;
    }
    let mut attributes = AttributeList::with_handles(&[stdin, stdout, stderr])?;
    // SAFETY: zero is the required initialization for STARTUPINFOEXW.
    let mut startup: StartupInfoExW = unsafe { zeroed() };
    startup.startup_info.cb = size_of::<StartupInfoExW>() as Dword;
    startup.startup_info.flags = STARTF_USESTDHANDLES;
    startup.startup_info.std_input = stdin;
    startup.startup_info.std_output = stdout;
    startup.startup_info.std_error = stderr;
    startup.attribute_list = attributes.pointer();

    let executable_wide = wide_null(executable.as_os_str())?;
    let mut command = command_line(executable, &[OsString::from(PRIVATE_REMOTE_WORKER_MODE)])?;
    let mut environment = minimal_environment(temp_root)?;
    // SAFETY: zero is the required initialization for PROCESS_INFORMATION.
    let mut process: ProcessInformation = unsafe { zeroed() };
    // SAFETY: every pointer references live initialized storage for the duration of the call.
    if unsafe {
        CreateProcessW(
            executable_wide.as_ptr(),
            command.as_mut_ptr(),
            null_mut(),
            null_mut(),
            TRUE,
            CREATE_SUSPENDED
                | CREATE_NO_WINDOW
                | CREATE_UNICODE_ENVIRONMENT
                | EXTENDED_STARTUPINFO_PRESENT,
            environment.as_mut_ptr().cast::<c_void>(),
            null(),
            &mut startup.startup_info,
            &mut process,
        )
    } == FALSE
    {
        return Err(io::Error::last_os_error());
    }
    Ok(SuspendedChild {
        process: Some(OwnedHandle::new(process.process)?),
        thread: Some(OwnedHandle::new(process.thread)?),
    })
}

fn new_kill_on_close_job() -> io::Result<OwnedHandle> {
    // SAFETY: this creates an unnamed, non-inheritable Job with default security.
    let job = OwnedHandle::new(unsafe { CreateJobObjectW(null_mut(), null()) })?;
    let mut limits = JobObjectExtendedLimitInformation::default();
    limits.basic_limit_information.limit_flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    // SAFETY: the information pointer and exact size are valid.
    if unsafe {
        SetInformationJobObject(
            job.raw(),
            JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS,
            (&limits as *const JobObjectExtendedLimitInformation).cast::<c_void>(),
            size_of::<JobObjectExtendedLimitInformation>() as Dword,
        )
    } == FALSE
    {
        return Err(io::Error::last_os_error());
    }
    Ok(job)
}

fn assign_and_verify(job: &OwnedHandle, process: &OwnedHandle) -> io::Result<()> {
    // SAFETY: both handles are valid and the process primary thread is suspended.
    if unsafe { AssignProcessToJobObject(job.raw(), process.raw()) } == FALSE {
        return Err(io::Error::last_os_error());
    }
    let mut in_job = FALSE;
    // SAFETY: both handles are valid.
    if unsafe { IsProcessInJob(process.raw(), job.raw(), &mut in_job) } == FALSE || in_job == FALSE {
        return Err(io::Error::last_os_error());
    }
    let accounting = job_accounting(job)?;
    if accounting.active_processes != 1 {
        return Err(io::Error::other("operation Job assignment was not observable"));
    }
    Ok(())
}

fn query_current_job_state() -> io::Result<bool> {
    let mut in_job = FALSE;
    // SAFETY: GetCurrentProcess returns the documented pseudo-handle and null means any Job.
    if unsafe { IsProcessInJob(GetCurrentProcess(), null_mut(), &mut in_job) } == FALSE {
        Err(io::Error::last_os_error())
    } else {
        Ok(in_job != FALSE)
    }
}

fn job_accounting(job: &OwnedHandle) -> io::Result<JobObjectBasicAccountingInformation> {
    let mut accounting = JobObjectBasicAccountingInformation::default();
    // SAFETY: output pointer and exact structure size are valid.
    if unsafe {
        QueryInformationJobObject(
            job.raw(),
            JOB_OBJECT_BASIC_ACCOUNTING_INFORMATION_CLASS,
            (&mut accounting as *mut JobObjectBasicAccountingInformation).cast::<c_void>(),
            size_of::<JobObjectBasicAccountingInformation>() as Dword,
            null_mut(),
        )
    } == FALSE
    {
        Err(io::Error::last_os_error())
    } else {
        Ok(accounting)
    }
}

fn wait_job_zero_until(job: &ActiveJob, deadline: Instant) -> io::Result<()> {
    loop {
        if job.accounting()?.active_processes == 0 {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(io::Error::new(io::ErrorKind::TimedOut, "Job cleanup timed out"));
        }
        thread::sleep(SUPERVISION_POLL);
    }
}

fn minimal_environment(temp_root: &Path) -> io::Result<Vec<u16>> {
    let temp = temp_root.to_str().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "temporary root is not Unicode")
    })?;
    let mut entries = Vec::new();
    for name in ["SystemRoot", "WINDIR"] {
        let value = std::env::var(name).map_err(|_| {
            io::Error::new(io::ErrorKind::NotFound, "required system environment is missing")
        })?;
        entries.push((name.to_string(), value));
    }
    entries.push(("TEMP".to_string(), temp.to_string()));
    entries.push(("TMP".to_string(), temp.to_string()));
    entries.sort_by_key(|(name, _)| name.to_ascii_uppercase());
    let mut block = Vec::new();
    for (name, value) in entries {
        if value.contains('\0') {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid environment value"));
        }
        block.extend(OsStr::new(&format!("{name}={value}")).encode_wide());
        block.push(0);
    }
    block.push(0);
    Ok(block)
}

fn wide_null(value: &OsStr) -> io::Result<Vec<u16>> {
    let mut wide = value.encode_wide().collect::<Vec<_>>();
    if wide.contains(&0) {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "Windows string contains NUL"));
    }
    wide.push(0);
    Ok(wide)
}

fn quote_argument(value: &OsStr) -> io::Result<String> {
    let value = value.to_str().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "Windows argument is not Unicode")
    })?;
    if !value.chars().any(|character| character.is_whitespace() || character == '"') {
        return Ok(value.to_string());
    }
    let mut quoted = String::from("\"");
    let mut backslashes = 0usize;
    for character in value.chars() {
        if character == '\\' {
            backslashes += 1;
        } else if character == '"' {
            quoted.push_str(&"\\".repeat(backslashes * 2 + 1));
            quoted.push('"');
            backslashes = 0;
        } else {
            quoted.push_str(&"\\".repeat(backslashes));
            backslashes = 0;
            quoted.push(character);
        }
    }
    quoted.push_str(&"\\".repeat(backslashes * 2));
    quoted.push('"');
    Ok(quoted)
}

fn command_line(executable: &Path, arguments: &[OsString]) -> io::Result<Vec<u16>> {
    let mut parts = vec![quote_argument(executable.as_os_str())?];
    for argument in arguments {
        parts.push(quote_argument(argument)?);
    }
    wide_null(OsStr::new(&parts.join(" ")))
}

fn duration_ms(duration: Duration) -> Dword {
    duration.as_millis().min(Dword::MAX as u128) as Dword
}

fn remaining_timeout_ms(deadline: Instant, configured_timeout_ms: u64) -> Result<u64, BridgeFailure> {
    let remaining = deadline
        .checked_duration_since(Instant::now())
        .filter(|duration| !duration.is_zero())
        .ok_or_else(timed_out_failure)?;
    Ok(u64::try_from(remaining.as_millis().max(1))
        .unwrap_or(u64::MAX)
        .min(configured_timeout_ms))
}

fn win32_start_failure(stage: &'static str, error: &io::Error) -> BridgeFailure {
    let args = error.raw_os_error().map_or_else(
        || json!({ "stage": stage }),
        |code| json!({ "stage": stage, "win32Code": code }),
    );
    BridgeFailure::new(
        "SUBVERSIONR_REMOTE_WORKER_START_FAILED",
        "process",
        "error.remote.workerStartFailed",
        args,
        false,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn revoke_waits_for_a_pre_registration_launch_reservation() {
        let active = Arc::new(ActiveWorkerRegistry::default());
        let disconnected = AtomicBool::new(false);
        let parent_disconnected = AtomicBool::new(false);
        active
            .allow_launches(&disconnected)
            .expect("trusted gate must open");
        let reservation = active
            .reserve_launch(&disconnected, &parent_disconnected)
            .expect("launch reservation must be admitted before revoke");
        let (sender, receiver) = mpsc::sync_channel(1);
        let revoked = Arc::clone(&active);
        let waiter = thread::spawn(move || {
            revoked.block_launches_and_terminate_all();
            let result = revoked.wait_for_zero(Duration::from_secs(1));
            let _ = sender.send(result);
        });

        assert!(
            receiver.recv_timeout(Duration::from_millis(25)).is_err(),
            "revoke acknowledgement must wait for pre-registration setup"
        );
        drop(reservation);
        receiver
            .recv_timeout(Duration::from_secs(1))
            .expect("revoke wait must finish after setup reservation drops")
            .expect("zero-worker revoke must settle");
        waiter.join().expect("revoke waiter must not panic");
    }

    #[test]
    fn remaining_timeout_never_resets_the_parent_budget() {
        let deadline = Instant::now() + Duration::from_millis(40);
        thread::sleep(Duration::from_millis(10));
        let remaining = remaining_timeout_ms(deadline, 300_000).expect("deadline remains live");
        assert!(remaining > 0);
        assert!(remaining < 40);
    }

    #[test]
    fn worker_failure_wire_is_allowlisted_and_redacted() {
        let accepted = WireFailure {
            code: "SUBVERSIONR_REMOTE_CONFIG_CREATE_FAILED".to_string(),
            category: "native".to_string(),
            message_key: "error.remote.configCreateFailed".to_string(),
            args: json!({ "status": 17 }),
            retryable: false,
            diagnostics: None,
        };
        assert_eq!(
            validate_wire_failure(accepted)
                .expect("allowlisted native failure must survive")
                .safe_args(),
            &json!({ "status": 17 })
        );

        let rejected = WireFailure {
            code: "SVN_SECRET_PATH".to_string(),
            category: "native".to_string(),
            message_key: "C:\\Users\\secret".to_string(),
            args: json!({ "url": "https://user:password@example.invalid" }),
            retryable: false,
            diagnostics: None,
        };
        assert_eq!(
            validate_wire_failure(rejected)
                .expect_err("untrusted failure values must be rejected")
                .code(),
            "SUBVERSIONR_REMOTE_WORKER_PROTOCOL_INVALID"
        );

        let settlement = WireFailure {
            code: "SUBVERSIONR_CREDENTIAL_TIMEOUT".to_string(),
            category: "auth".to_string(),
            message_key: "error.auth.credentialTimeout".to_string(),
            args: json!({
                "operationHash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                "leaseHash": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
                "outcome": "accepted"
            }),
            retryable: false,
            diagnostics: None,
        };
        assert_eq!(
            validate_wire_failure(settlement)
                .expect("allowlisted settlement failure must survive")
                .code(),
            "SUBVERSIONR_CREDENTIAL_TIMEOUT"
        );

        let settlement_with_extra_args = WireFailure {
            code: "SUBVERSIONR_CREDENTIAL_TIMEOUT".to_string(),
            category: "auth".to_string(),
            message_key: "error.auth.credentialTimeout".to_string(),
            args: json!({
                "operationHash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                "leaseHash": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
                "outcome": "accepted",
                "realm": "must-not-cross-worker-boundary"
            }),
            retryable: false,
            diagnostics: None,
        };
        assert_eq!(
            validate_wire_failure(settlement_with_extra_args)
                .expect_err("extra settlement args must fail closed")
                .code(),
            "SUBVERSIONR_REMOTE_WORKER_PROTOCOL_INVALID"
        );
    }

    #[test]
    fn settlement_broker_failure_is_encoded_as_a_strict_private_parent_frame() {
        let operation_id = "01234567-89ab-4def-8123-456789abcdef";
        let failure = BridgeFailure::new(
            "SUBVERSIONR_CREDENTIAL_TIMEOUT",
            "auth",
            "error.auth.credentialTimeout",
            json!({
                "operationHash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                "leaseHash": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
                "outcome": "accepted"
            }),
            false,
        );
        let frame = settlement_parent_frame(operation_id.to_string(), 7, Err(failure))
            .expect("stable settlement failure must become a private parent frame");
        let encoded = serde_json::to_vec(&frame).expect("private parent frame must serialize");
        let decoded: ParentWorkerFrame =
            serde_json::from_slice(&encoded).expect("private parent frame must deserialize");
        let ParentWorkerFrame::CredentialSettlementFailure {
            protocol_version,
            operation_id: decoded_operation_id,
            sequence,
            failure,
        } = decoded
        else {
            panic!("settlement failure must use its dedicated private frame")
        };
        assert_eq!(protocol_version, PRIVATE_WORKER_PROTOCOL_VERSION);
        assert_eq!(decoded_operation_id, operation_id);
        assert_eq!(sequence, 7);
        assert_eq!(failure.code, "SUBVERSIONR_CREDENTIAL_TIMEOUT");

        let unknown = BridgeFailure::new(
            "SUBVERSIONR_CREDENTIAL_UNKNOWN",
            "auth",
            "error.auth.credentialUnknown",
            json!({}),
            false,
        );
        assert_eq!(
            settlement_parent_frame(operation_id.to_string(), 8, Err(unknown))
                .expect_err("unknown failure must not cross the private worker boundary")
                .kind(),
            io::ErrorKind::InvalidData
        );
    }
}

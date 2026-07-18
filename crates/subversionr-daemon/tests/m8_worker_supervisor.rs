#[cfg(not(windows))]
#[test]
fn m8_worker_supervisor_requires_windows() {
    eprintln!("SKIP: M8 production worker supervisor tests require Windows");
}

#[cfg(windows)]
mod windows {
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    use std::time::{Duration, Instant};

    use serde_json::json;
    use subversionr_daemon::{
        BridgeCancellationToken, ProcessRemoteWorkerSupervisor, RemoteConfigPlan,
        RemoteConfigScheme, RemoteConfigServerAuth, RemoteWorkerSupervisor,
        UnavailableAuthRequestBroker, UnavailableBridge,
    };
    use subversionr_protocol::RemoteOperationEnvelope;

    static FIXTURE_SEQUENCE: AtomicU64 = AtomicU64::new(1);

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
    fn cancellation_and_child_crash_hard_stop_before_releasing_the_lane() {
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
                .expect_err("pre-resume cancellation must hard-stop")
                .code(),
            "SUBVERSIONR_REMOTE_WORKER_CANCELLED"
        );
        fixture.assert_settled();

        let crashed = fixture.execute(
            envelope("12700000-0000-4000-8000-000000000102"),
            &FixedCancellation::new(false),
            Instant::now() + Duration::from_secs(5),
        );
        assert_eq!(
            crashed
                .expect_err("fixture child must emit an invalid worker response")
                .code(),
            "SUBVERSIONR_REMOTE_WORKER_PROTOCOL_INVALID"
        );
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
                .expect_err("revoked launch must never resume")
                .code(),
            "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED"
        );
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
                .expect_err("reopened launch must reach cancellation checkpoint")
                .code(),
            "SUBVERSIONR_REMOTE_WORKER_CANCELLED"
        );
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
                .expect_err("expired suspended setup must hard-stop before resume")
                .code(),
            "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT"
        );
        fixture.assert_settled();
    }

    struct SupervisorFixture {
        supervisor: ProcessRemoteWorkerSupervisor,
        temp_base: PathBuf,
    }

    impl SupervisorFixture {
        fn new() -> Self {
            let executable = std::env::current_exe()
                .and_then(|path| path.canonicalize())
                .expect("test executable must resolve");
            let sequence = FIXTURE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let temp_base = std::env::temp_dir().join(format!(
                "subversionr-m8-worker-supervisor-{}-{sequence}",
                std::process::id()
            ));
            fs::create_dir(&temp_base).expect("unique supervisor temp root must be created");
            let supervisor = ProcessRemoteWorkerSupervisor::new(
                executable.clone(),
                executable,
                temp_base.clone(),
            )
            .expect("production supervisor must accept verified fixture paths");
            Self {
                supervisor,
                temp_base,
            }
        }

        fn execute(
            &self,
            envelope: RemoteOperationEnvelope,
            cancellation: &dyn BridgeCancellationToken,
            deadline: Instant,
        ) -> Result<(), subversionr_daemon::BridgeFailure> {
            let mut auth = UnavailableAuthRequestBroker;
            self.supervisor.execute(
                &envelope,
                plan(envelope.timeout_ms),
                "C:/checkout/worker-supervisor",
                cancellation,
                &mut auth,
                &UnavailableBridge,
                deadline,
            )
        }

        fn assert_settled(&self) {
            assert_eq!(self.supervisor.active_worker_count(), 0);
            assert_eq!(self.supervisor.blocked_lane_count(), 0);
            assert!(
                fs::read_dir(&self.temp_base)
                    .expect("supervisor temp root must remain readable")
                    .next()
                    .is_none(),
                "operation temp roots must be removed before the lane is released"
            );
        }
    }

    impl Drop for SupervisorFixture {
        fn drop(&mut self) {
            fs::remove_dir(&self.temp_base).expect("empty supervisor temp root must be removable");
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

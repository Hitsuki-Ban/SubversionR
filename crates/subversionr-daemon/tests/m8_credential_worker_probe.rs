#[cfg(not(windows))]
#[test]
fn credential_worker_probe_requires_windows() {
    eprintln!("SKIP: packaged credential worker probe requires Windows");
}

#[cfg(windows)]
mod windows {
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{Duration, Instant};

    use serde_json::json;
    use subversionr_daemon::{
        AuthRequestBroker, BridgeFailure, NeverCancelled, ProcessRemoteWorkerSupervisor,
        RemoteConfigPlan, RemoteConfigScheme, RemoteConfigServerAuth,
        RemoteCredentialProbeScenario, RemoteWorkerSupervisor,
    };
    use subversionr_protocol::{
        CertificateTrustRequest, CertificateTrustResponse, Credential, CredentialAttempt,
        CredentialPersistenceIntent, CredentialRequest, CredentialResponse,
        CredentialSettlementAck, CredentialSettlementOutcome, CredentialSettlementRequest,
        RemoteOperationEnvelope,
    };

    static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(1);

    #[test]
    #[ignore = "requires SUBVERSIONR_TEST_BRIDGE_DLL pointing at a staged real bridge"]
    fn real_packaged_worker_runs_all_provider_settlement_scenarios() {
        let bridge_path = PathBuf::from(
            std::env::var_os("SUBVERSIONR_TEST_BRIDGE_DLL")
                .expect("SUBVERSIONR_TEST_BRIDGE_DLL must identify the staged real bridge"),
        );
        let worker_executable = PathBuf::from(env!("CARGO_BIN_EXE_subversionr-daemon"));
        let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let temp_base = std::env::temp_dir().join(format!(
            "subversionr-m8-credential-worker-{}-{sequence}",
            std::process::id()
        ));
        fs::create_dir(&temp_base).expect("unique worker temp root must be created");
        let supervisor =
            ProcessRemoteWorkerSupervisor::new(worker_executable, bridge_path, temp_base.clone())
                .expect("packaged worker inputs must resolve");
        supervisor
            .update_workspace_trust(true)
            .expect("trusted evidence launch gate must open");
        assert!(supervisor.credential_lease_settlement_available());

        let scenarios = [
            (
                RemoteCredentialProbeScenario::FirstSave,
                vec![BrokerEvent::AcquireInitial, BrokerEvent::SettleAccepted],
            ),
            (
                RemoteCredentialProbeScenario::FirstNextSave,
                vec![
                    BrokerEvent::AcquireInitial,
                    BrokerEvent::SettleRejected,
                    BrokerEvent::AcquireRetry,
                    BrokerEvent::SettleAccepted,
                ],
            ),
            (
                RemoteCredentialProbeScenario::Unused,
                vec![BrokerEvent::AcquireInitial, BrokerEvent::SettleUnused],
            ),
            (
                RemoteCredentialProbeScenario::Cancelled,
                vec![BrokerEvent::AcquireInitial, BrokerEvent::SettleCancelled],
            ),
            (
                RemoteCredentialProbeScenario::TimedOut,
                vec![BrokerEvent::AcquireInitial, BrokerEvent::SettleTimedOut],
            ),
        ];

        for (index, (scenario, expected)) in scenarios.into_iter().enumerate() {
            let operation_id = format!("12900000-0000-4000-8000-{index:012}");
            let envelope = envelope(&operation_id);
            let mut broker = RecordingBroker::default();
            supervisor
                .execute_credential_probe(
                    &envelope,
                    plan(envelope.timeout_ms),
                    "C:/credential-provider-probe",
                    &NeverCancelled,
                    &mut broker,
                    Instant::now() + Duration::from_secs(10),
                    scenario,
                )
                .expect("real provider probe must complete through the packaged worker broker");
            assert_eq!(broker.events, expected);
            assert_eq!(supervisor.active_worker_count(), 0);
            assert!(
                fs::read_dir(&temp_base)
                    .expect("worker temp root must remain readable")
                    .next()
                    .is_none(),
                "the lane may be released only after worker cleanup"
            );
        }

        let failure_operation_id = "12900000-0000-4000-8000-000000000006";
        let failure_envelope = envelope(failure_operation_id);
        let mut failure_broker = SettlementFailureBroker;
        let failure = supervisor
            .execute_credential_probe(
                &failure_envelope,
                plan(failure_envelope.timeout_ms),
                "C:/credential-provider-probe",
                &NeverCancelled,
                &mut failure_broker,
                Instant::now() + Duration::from_secs(10),
                RemoteCredentialProbeScenario::FirstSave,
            )
            .expect_err("real private worker must preserve settlement broker failures");
        assert_eq!(failure.code(), "SUBVERSIONR_CREDENTIAL_TIMEOUT");
        assert_eq!(
            failure.safe_args(),
            &json!({
                "operationHash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                "leaseHash": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
                "outcome": "accepted"
            })
        );
        assert_eq!(supervisor.active_worker_count(), 0);
        assert!(
            fs::read_dir(&temp_base)
                .expect("worker temp root must remain readable after broker failure")
                .next()
                .is_none(),
            "broker failure path must clean the worker temp root"
        );

        supervisor
            .disconnect()
            .expect("settled evidence supervisor must disconnect");
        fs::remove_dir(&temp_base).expect("empty evidence temp root must be removable");
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum BrokerEvent {
        AcquireInitial,
        AcquireRetry,
        SettleAccepted,
        SettleRejected,
        SettleUnused,
        SettleCancelled,
        SettleTimedOut,
    }

    #[derive(Default)]
    struct RecordingBroker {
        events: Vec<BrokerEvent>,
        leases_issued: usize,
    }

    struct SettlementFailureBroker;

    impl AuthRequestBroker for SettlementFailureBroker {
        fn native_credential_callback_policy(
            &self,
        ) -> subversionr_daemon::NativeCredentialCallbackPolicy {
            subversionr_daemon::NativeCredentialCallbackPolicy::RemoteWorkerRequired
        }

        fn request_credential(
            &mut self,
            request: CredentialRequest,
        ) -> Result<CredentialResponse, BridgeFailure> {
            Ok(CredentialResponse::Provide {
                request_id: request.request_id,
                operation_id: request.operation_id,
                lease_id: "failure-lease".to_string(),
                credential: Credential {
                    username: "alice".to_string(),
                    secret: "credential-probe-secret".to_string(),
                },
                persistence_intent: CredentialPersistenceIntent::Session,
            })
        }

        fn settle_credential(
            &mut self,
            _request: CredentialSettlementRequest,
        ) -> Result<CredentialSettlementAck, BridgeFailure> {
            Err(BridgeFailure::new(
                "SUBVERSIONR_CREDENTIAL_TIMEOUT",
                "auth",
                "error.auth.credentialTimeout",
                json!({
                    "operationHash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                    "leaseHash": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
                    "outcome": "accepted"
                }),
                false,
            ))
        }

        fn request_certificate_trust(
            &mut self,
            _request: CertificateTrustRequest,
        ) -> Result<CertificateTrustResponse, BridgeFailure> {
            panic!("server credential probe must not enter the certificate contract")
        }
    }

    impl AuthRequestBroker for RecordingBroker {
        fn native_credential_callback_policy(
            &self,
        ) -> subversionr_daemon::NativeCredentialCallbackPolicy {
            subversionr_daemon::NativeCredentialCallbackPolicy::RemoteWorkerRequired
        }

        fn request_credential(
            &mut self,
            request: CredentialRequest,
        ) -> Result<CredentialResponse, BridgeFailure> {
            match &request.attempt {
                CredentialAttempt::Initial => self.events.push(BrokerEvent::AcquireInitial),
                CredentialAttempt::RetryAfterRejected { previous_lease_id } => {
                    assert_eq!(previous_lease_id, "lease-1");
                    self.events.push(BrokerEvent::AcquireRetry);
                }
            }
            self.leases_issued += 1;
            Ok(CredentialResponse::Provide {
                request_id: request.request_id,
                operation_id: request.operation_id,
                lease_id: format!("lease-{}", self.leases_issued),
                credential: Credential {
                    username: "alice".to_string(),
                    secret: "credential-probe-secret".to_string(),
                },
                persistence_intent: CredentialPersistenceIntent::Session,
            })
        }

        fn settle_credential(
            &mut self,
            request: CredentialSettlementRequest,
        ) -> Result<CredentialSettlementAck, BridgeFailure> {
            self.events.push(match request.outcome {
                CredentialSettlementOutcome::Accepted => BrokerEvent::SettleAccepted,
                CredentialSettlementOutcome::Rejected => BrokerEvent::SettleRejected,
                CredentialSettlementOutcome::Unused => BrokerEvent::SettleUnused,
                CredentialSettlementOutcome::Cancelled => BrokerEvent::SettleCancelled,
                CredentialSettlementOutcome::TimedOut => BrokerEvent::SettleTimedOut,
            });
            Ok(CredentialSettlementAck {
                request_id: request.request_id,
                operation_id: request.operation_id,
                lease_id: request.lease_id,
                outcome: request.outcome,
            })
        }

        fn request_certificate_trust(
            &mut self,
            _request: CertificateTrustRequest,
        ) -> Result<CertificateTrustResponse, BridgeFailure> {
            panic!("server credential probe must not enter the certificate contract")
        }
    }

    fn plan(timeout_ms: u64) -> RemoteConfigPlan {
        RemoteConfigPlan {
            scheme: RemoteConfigScheme::Https,
            server_auth: RemoteConfigServerAuth::Basic,
            timeout_ms,
            trust_windows_roots: true,
        }
    }

    fn envelope(operation_id: &str) -> RemoteOperationEnvelope {
        serde_json::from_value(json!({
            "version": 1,
            "operationId": operation_id,
            "intent": "foreground",
            "interaction": "allowed",
            "timeoutMs": 10_000,
            "workspaceTrust": "trusted",
            "trustEpoch": 1,
            "profile": {
                "schema": "subversionr.remote-profile.v1",
                "profileId": "credential-worker-probe",
                "authority": {
                    "scheme": "https",
                    "canonicalHost": "svn.example.invalid",
                    "effectivePort": 443
                },
                "serverAuth": "basic",
                "serverAccount": { "mode": "fixed", "username": "alice" },
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
        .expect("probe envelope must match the strict public contract")
    }
}

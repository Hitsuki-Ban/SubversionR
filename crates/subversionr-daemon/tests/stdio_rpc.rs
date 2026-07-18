use std::collections::BTreeMap;
use std::io::{self, Read};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use subversionr_daemon::{
    AddOperationRequest, AuthRequestBroker, BridgeApi, BridgeCancellationToken, BridgeFailure,
    BridgeInfo, CleanupOperationRequest, CommitOperationRequest, CommitOperationResult,
    ContentBlob, HistoryBlameRequest, HistoryBlameResult, HistoryLogRequest, HistoryLogResult,
    MoveOperationRequest, OperationResult, PropertiesListResult, PropertyDeleteOperationRequest,
    PropertyEntry, PropertySetOperationRequest, RemoteConfigPlan, RemoteOperationEffect,
    RemoteWorkerSettlement, RemoteWorkerSupervisor, RemoveOperationRequest,
    ResolveOperationRequest, RevertOperationRequest, UpdateOperationRequest, UpdateOperationResult,
    WorkerTerminationDisposition, run_json_rpc_stdio, run_json_rpc_stdio_with_remote_worker,
};
use subversionr_protocol::{
    CanonicalEndpoint, CertificateTrustRequest, CertificateTrustResponse, Credential,
    CredentialAttempt, CredentialAuthKind, CredentialPersistenceIntent, CredentialRequest,
    CredentialResponse, CredentialSettlementOutcome, CredentialSettlementRequest, RemoteFailure,
    RemoteFailureCategory, RemoteFailureClass, RemoteOperationEnvelope, RemoteOperationIntent,
    RemoteScheme, RepositoryIdentity, ServerAccountSelection, StatusEntry, StatusSnapshot,
    StatusSummary,
};

fn credential_request(
    request_id: &str,
    realm: &str,
    interactive: bool,
    persistence_allowed: bool,
    origin: RemoteOperationIntent,
    timeout_ms: u64,
) -> CredentialRequest {
    CredentialRequest {
        request_id: request_id.to_string(),
        operation_id: format!("{request_id}-operation"),
        endpoint: CanonicalEndpoint {
            scheme: RemoteScheme::Https,
            canonical_host: "svn.example.invalid".to_string(),
            effective_port: 443,
        },
        auth_kind: CredentialAuthKind::Basic,
        realm: realm.to_string(),
        account: ServerAccountSelection::Fixed {
            username: "alice".to_string(),
        },
        attempt: CredentialAttempt::Initial,
        interactive,
        persistence_allowed,
        origin,
        timeout_ms,
    }
}

fn provided_credential(request_id: &str) -> CredentialResponse {
    CredentialResponse::Provide {
        request_id: request_id.to_string(),
        operation_id: format!("{request_id}-operation"),
        lease_id: format!("{request_id}-lease"),
        credential: Credential {
            username: "alice".to_string(),
            secret: "secret".to_string(),
        },
        persistence_intent: CredentialPersistenceIntent::SecretStorage,
    }
}

fn credential_settlement_request(
    operation_id: &str,
    timeout_ms: u64,
) -> CredentialSettlementRequest {
    CredentialSettlementRequest {
        request_id: "settle-expected".to_string(),
        operation_id: operation_id.to_string(),
        lease_id: "01234567-89ab-4def-8123-456789abcdef".to_string(),
        outcome: CredentialSettlementOutcome::Accepted,
        timeout_ms,
    }
}

fn assert_credential_request_frame(frame: &serde_json::Value, request_id: &str, realm: &str) {
    assert_eq!(frame["id"], request_id);
    assert_eq!(frame["method"], "credentials/request");
    assert_eq!(frame["params"]["requestId"], request_id);
    assert_eq!(
        frame["params"]["operationId"],
        format!("{request_id}-operation")
    );
    assert_eq!(frame["params"]["realm"], realm);
    assert_eq!(frame["params"]["authKind"], "basic");
    assert_eq!(frame["params"]["endpoint"]["scheme"], "https");
    assert_eq!(
        frame["params"]["endpoint"]["canonicalHost"],
        "svn.example.invalid"
    );
    assert_eq!(frame["params"]["endpoint"]["effectivePort"], 443);
    assert_eq!(frame["params"]["account"]["mode"], "fixed");
    assert_eq!(frame["params"]["account"]["username"], "alice");
    assert_eq!(frame["params"]["attempt"]["kind"], "initial");
}

#[derive(Debug)]
struct FakeBridge;

#[derive(Debug, Clone)]
struct RecoveryTaskControl {
    started: Arc<AtomicBool>,
    release: Arc<AtomicBool>,
    cancelled: Arc<AtomicBool>,
}

fn recovery_task_controls() -> &'static Mutex<BTreeMap<String, RecoveryTaskControl>> {
    static CONTROLS: OnceLock<Mutex<BTreeMap<String, RecoveryTaskControl>>> = OnceLock::new();
    CONTROLS.get_or_init(|| Mutex::new(BTreeMap::new()))
}

impl BridgeApi for FakeBridge {
    fn info(&self) -> BridgeInfo {
        BridgeInfo::available("subversionr-svn-bridge/0.1.0-test", "1.14.5")
    }

    fn create_recovery_status_task(
        &self,
        identity: RepositoryIdentity,
        generation: u64,
    ) -> Result<subversionr_daemon::BridgeRecoveryTask, BridgeFailure> {
        let control = recovery_task_controls()
            .lock()
            .expect("recovery task controls must not be poisoned")
            .get(&identity.working_copy_root)
            .cloned();
        Ok(Box::new(move |cancellation| {
            if let Some(control) = control {
                control.started.store(true, Ordering::SeqCst);
                while !control.release.load(Ordering::SeqCst) {
                    if cancellation.is_cancelled() {
                        control.cancelled.store(true, Ordering::SeqCst);
                        return Err(BridgeFailure::new(
                            "SVN_STATUS_CANCELLED",
                            "cancelled",
                            "error.native.statusCancelled",
                            serde_json::json!({}),
                            false,
                        ));
                    }
                    thread::sleep(Duration::from_millis(2));
                }
            }
            FakeBridge.status_snapshot_with_cancellation(&identity, generation, cancellation)
        }))
    }

    fn open_working_copy(&self, path: &str) -> Result<RepositoryIdentity, BridgeFailure> {
        Ok(RepositoryIdentity {
            repository_uuid: "repo-uuid".to_string(),
            repository_root_url: if path.contains("remote-recovery") {
                "https://svn.example.invalid/project".to_string()
            } else {
                "file:///repo".to_string()
            },
            working_copy_root: path.to_string(),
            workspace_scope_root: path.to_string(),
            format: 31,
        })
    }

    fn status_snapshot(
        &self,
        identity: &RepositoryIdentity,
        generation: u64,
    ) -> Result<StatusSnapshot, BridgeFailure> {
        self.status_snapshot_with_cancellation(
            identity,
            generation,
            &subversionr_daemon::NeverCancelled,
        )
    }

    fn status_snapshot_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        generation: u64,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<StatusSnapshot, BridgeFailure> {
        self.status_scan_with_cancellation(identity, ".", "infinity", generation, cancellation)
    }

    fn status_scan(
        &self,
        identity: &RepositoryIdentity,
        _path: &str,
        _depth: &str,
        generation: u64,
    ) -> Result<StatusSnapshot, BridgeFailure> {
        self.status_scan_with_cancellation(
            identity,
            ".",
            "infinity",
            generation,
            &subversionr_daemon::NeverCancelled,
        )
    }

    fn status_scan_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _path: &str,
        _depth: &str,
        generation: u64,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<StatusSnapshot, BridgeFailure> {
        Ok(StatusSnapshot {
            repository_id: format!(
                "{}:{}",
                identity.repository_uuid, identity.working_copy_root
            ),
            epoch: 1,
            generation,
            completeness: "complete".to_string(),
            identity: identity.clone(),
            local_entries: vec![StatusEntry {
                path: "tracked.txt".to_string(),
                kind: "file".to_string(),
                node_status: "modified".to_string(),
                text_status: "modified".to_string(),
                property_status: "normal".to_string(),
                local_status: "modified".to_string(),
                remote_status: "notChecked".to_string(),
                revision: 1,
                changed_revision: 1,
                changed_author: None,
                changed_date: None,
                changelist: None,
                lock: None,
                needs_lock: false,
                copy: None,
                move_: None,
                switched: false,
                depth: "infinity".to_string(),
                conflict: None,
                conflict_artifacts: vec![],
                external: false,
                generation,
            }],
            remote_entries: Vec::new(),
            summary: StatusSummary {
                local_changes: 1,
                remote_changes: 0,
                conflicts: 0,
                unversioned: 0,
            },
            timestamp: "2026-06-22T00:00:00Z".to_string(),
            source: "libsvn-local".to_string(),
        })
    }

    fn content_get(
        &self,
        _identity: &RepositoryIdentity,
        _path: &str,
        _revision: &str,
        _auth: &mut dyn AuthRequestBroker,
    ) -> Result<ContentBlob, BridgeFailure> {
        Ok(ContentBlob {
            data: b"base\n".to_vec(),
            mime_type: Some("text/plain".to_string()),
            is_binary: false,
            source: "libsvn-base".to_string(),
        })
    }

    fn properties_list(
        &self,
        _identity: &RepositoryIdentity,
        path: &str,
    ) -> Result<PropertiesListResult, BridgeFailure> {
        Ok(PropertiesListResult {
            properties: vec![PropertyEntry {
                name: "svn:ignore".to_string(),
                value: "target".to_string(),
                value_encoding: "utf8".to_string(),
            }],
            source: format!("fake-properties:{path}"),
        })
    }

    fn history_log(
        &self,
        _identity: &RepositoryIdentity,
        _request: &HistoryLogRequest,
        _auth: &mut dyn AuthRequestBroker,
    ) -> Result<HistoryLogResult, BridgeFailure> {
        Ok(HistoryLogResult {
            entries: Vec::new(),
            source: "libsvn-log".to_string(),
        })
    }

    fn history_blame(
        &self,
        _identity: &RepositoryIdentity,
        request: &HistoryBlameRequest,
        _auth: &mut dyn AuthRequestBroker,
    ) -> Result<HistoryBlameResult, BridgeFailure> {
        Ok(HistoryBlameResult {
            resolved_start_revision: 0,
            resolved_end_revision: 1,
            line_start: request.line_start,
            line_limit: request.line_limit,
            ignore_whitespace: request.ignore_whitespace.clone(),
            ignore_eol_style: request.ignore_eol_style,
            ignore_mime_type: request.ignore_mime_type,
            include_merged_revisions: request.include_merged_revisions,
            has_more: false,
            lines: Vec::new(),
            source: "libsvn-blame".to_string(),
        })
    }

    fn operation_revert(
        &self,
        _identity: &RepositoryIdentity,
        request: &RevertOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        self.operation_revert_with_cancellation(
            _identity,
            request,
            &subversionr_daemon::NeverCancelled,
        )
    }

    fn operation_revert_with_cancellation(
        &self,
        _identity: &RepositoryIdentity,
        request: &RevertOperationRequest,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Ok(OperationResult {
            touched_paths: request.paths.clone(),
            skipped_paths: Vec::new(),
        })
    }

    fn operation_add(
        &self,
        _identity: &RepositoryIdentity,
        request: &AddOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        self.operation_add_with_cancellation(
            _identity,
            request,
            &subversionr_daemon::NeverCancelled,
        )
    }

    fn operation_add_with_cancellation(
        &self,
        _identity: &RepositoryIdentity,
        request: &AddOperationRequest,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Ok(OperationResult {
            touched_paths: request.paths.clone(),
            skipped_paths: Vec::new(),
        })
    }

    fn operation_remove(
        &self,
        _identity: &RepositoryIdentity,
        request: &RemoveOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        self.operation_remove_with_cancellation(
            _identity,
            request,
            &subversionr_daemon::NeverCancelled,
        )
    }

    fn operation_remove_with_cancellation(
        &self,
        _identity: &RepositoryIdentity,
        request: &RemoveOperationRequest,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Ok(OperationResult {
            touched_paths: request.paths.clone(),
            skipped_paths: Vec::new(),
        })
    }

    fn operation_move_with_cancellation(
        &self,
        _identity: &RepositoryIdentity,
        request: &MoveOperationRequest,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Ok(OperationResult {
            touched_paths: vec![
                request.source_path.clone(),
                request.destination_path.clone(),
            ],
            skipped_paths: Vec::new(),
        })
    }

    fn operation_resolve(
        &self,
        _identity: &RepositoryIdentity,
        request: &ResolveOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        self.operation_resolve_with_cancellation(
            _identity,
            request,
            &subversionr_daemon::NeverCancelled,
        )
    }

    fn operation_resolve_with_cancellation(
        &self,
        _identity: &RepositoryIdentity,
        request: &ResolveOperationRequest,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Ok(OperationResult {
            touched_paths: request.paths.clone(),
            skipped_paths: Vec::new(),
        })
    }

    fn operation_cleanup(
        &self,
        _identity: &RepositoryIdentity,
        request: &CleanupOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        self.operation_cleanup_with_cancellation(
            _identity,
            request,
            &subversionr_daemon::NeverCancelled,
        )
    }

    fn operation_cleanup_with_cancellation(
        &self,
        _identity: &RepositoryIdentity,
        request: &CleanupOperationRequest,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Ok(OperationResult {
            touched_paths: vec![request.path.clone()],
            skipped_paths: Vec::new(),
        })
    }

    fn operation_update(
        &self,
        _identity: &RepositoryIdentity,
        request: &UpdateOperationRequest,
        _auth: &mut dyn AuthRequestBroker,
    ) -> Result<UpdateOperationResult, BridgeFailure> {
        self.operation_update_with_cancellation(
            _identity,
            request,
            _auth,
            &subversionr_daemon::NeverCancelled,
        )
    }

    fn operation_update_with_cancellation(
        &self,
        _identity: &RepositoryIdentity,
        request: &UpdateOperationRequest,
        _auth: &mut dyn AuthRequestBroker,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<UpdateOperationResult, BridgeFailure> {
        Ok(UpdateOperationResult {
            result: OperationResult {
                touched_paths: vec![request.path.clone()],
                skipped_paths: Vec::new(),
            },
            revision: 2,
        })
    }

    fn operation_property_set_with_cancellation(
        &self,
        _identity: &RepositoryIdentity,
        request: &PropertySetOperationRequest,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Ok(OperationResult {
            touched_paths: vec![request.path.clone()],
            skipped_paths: Vec::new(),
        })
    }

    fn operation_property_delete_with_cancellation(
        &self,
        _identity: &RepositoryIdentity,
        request: &PropertyDeleteOperationRequest,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Ok(OperationResult {
            touched_paths: vec![request.path.clone()],
            skipped_paths: Vec::new(),
        })
    }

    fn operation_commit(
        &self,
        _identity: &RepositoryIdentity,
        request: &CommitOperationRequest,
        _auth: &mut dyn AuthRequestBroker,
    ) -> Result<CommitOperationResult, BridgeFailure> {
        self.operation_commit_with_cancellation(
            _identity,
            request,
            _auth,
            &subversionr_daemon::NeverCancelled,
        )
    }

    fn operation_commit_with_cancellation(
        &self,
        _identity: &RepositoryIdentity,
        request: &CommitOperationRequest,
        _auth: &mut dyn AuthRequestBroker,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<CommitOperationResult, BridgeFailure> {
        Ok(CommitOperationResult {
            result: OperationResult {
                touched_paths: request.paths.clone(),
                skipped_paths: Vec::new(),
            },
            revision: 3,
        })
    }
}

macro_rules! delegate_property_methods_to_fake_bridge {
    () => {
        fn properties_list(
            &self,
            identity: &RepositoryIdentity,
            path: &str,
        ) -> Result<PropertiesListResult, BridgeFailure> {
            FakeBridge.properties_list(identity, path)
        }

        fn operation_property_set_with_cancellation(
            &self,
            identity: &RepositoryIdentity,
            request: &PropertySetOperationRequest,
            cancellation: &dyn BridgeCancellationToken,
        ) -> Result<OperationResult, BridgeFailure> {
            FakeBridge.operation_property_set_with_cancellation(identity, request, cancellation)
        }

        fn operation_property_delete_with_cancellation(
            &self,
            identity: &RepositoryIdentity,
            request: &PropertyDeleteOperationRequest,
            cancellation: &dyn BridgeCancellationToken,
        ) -> Result<OperationResult, BridgeFailure> {
            FakeBridge.operation_property_delete_with_cancellation(identity, request, cancellation)
        }
    };
}

#[derive(Debug)]
struct CancellableStatusBridge;

impl CancellableStatusBridge {
    fn cancelled_status(path: &str) -> BridgeFailure {
        BridgeFailure::new(
            "SVN_STATUS_CANCELLED",
            "cancelled",
            "error.native.statusCancelled",
            serde_json::json!({ "path": path, "status": 11 }),
            false,
        )
    }

    fn uncancellable_status(path: &str) -> BridgeFailure {
        BridgeFailure::new(
            "TEST_STATUS_NOT_CANCELABLE",
            "test",
            "error.test.statusNotCancelable",
            serde_json::json!({ "path": path }),
            false,
        )
    }
}

impl BridgeApi for CancellableStatusBridge {
    fn info(&self) -> BridgeInfo {
        FakeBridge.info()
    }

    fn open_working_copy(&self, path: &str) -> Result<RepositoryIdentity, BridgeFailure> {
        FakeBridge.open_working_copy(path)
    }

    fn status_snapshot(
        &self,
        identity: &RepositoryIdentity,
        generation: u64,
    ) -> Result<StatusSnapshot, BridgeFailure> {
        FakeBridge.status_snapshot(identity, generation)
    }

    fn status_snapshot_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        generation: u64,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<StatusSnapshot, BridgeFailure> {
        FakeBridge.status_snapshot_with_cancellation(identity, generation, cancellation)
    }

    fn status_scan(
        &self,
        _identity: &RepositoryIdentity,
        path: &str,
        _depth: &str,
        _generation: u64,
    ) -> Result<StatusSnapshot, BridgeFailure> {
        thread::sleep(Duration::from_millis(100));
        Err(Self::uncancellable_status(path))
    }

    fn status_scan_with_cancellation(
        &self,
        _identity: &RepositoryIdentity,
        path: &str,
        _depth: &str,
        _generation: u64,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<StatusSnapshot, BridgeFailure> {
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if cancellation.is_cancelled() {
                return Err(Self::cancelled_status(path));
            }
            thread::sleep(Duration::from_millis(5));
        }
        Err(Self::uncancellable_status(path))
    }

    fn content_get(
        &self,
        identity: &RepositoryIdentity,
        path: &str,
        revision: &str,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<ContentBlob, BridgeFailure> {
        FakeBridge.content_get(identity, path, revision, auth)
    }

    fn history_log(
        &self,
        identity: &RepositoryIdentity,
        request: &HistoryLogRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<HistoryLogResult, BridgeFailure> {
        FakeBridge.history_log(identity, request, auth)
    }

    fn history_blame(
        &self,
        identity: &RepositoryIdentity,
        request: &HistoryBlameRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<HistoryBlameResult, BridgeFailure> {
        FakeBridge.history_blame(identity, request, auth)
    }

    fn operation_revert(
        &self,
        identity: &RepositoryIdentity,
        request: &RevertOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        FakeBridge.operation_revert(identity, request)
    }

    fn operation_revert_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &RevertOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        FakeBridge.operation_revert_with_cancellation(identity, request, cancellation)
    }

    fn operation_add(
        &self,
        identity: &RepositoryIdentity,
        request: &AddOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        FakeBridge.operation_add(identity, request)
    }

    fn operation_add_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &AddOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        FakeBridge.operation_add_with_cancellation(identity, request, cancellation)
    }

    fn operation_remove(
        &self,
        identity: &RepositoryIdentity,
        request: &RemoveOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        FakeBridge.operation_remove(identity, request)
    }

    fn operation_remove_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &RemoveOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        FakeBridge.operation_remove_with_cancellation(identity, request, cancellation)
    }

    fn operation_move_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &MoveOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        FakeBridge.operation_move_with_cancellation(identity, request, cancellation)
    }

    fn operation_resolve(
        &self,
        identity: &RepositoryIdentity,
        request: &ResolveOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        FakeBridge.operation_resolve(identity, request)
    }

    fn operation_resolve_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &ResolveOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        FakeBridge.operation_resolve_with_cancellation(identity, request, cancellation)
    }

    fn operation_cleanup(
        &self,
        identity: &RepositoryIdentity,
        request: &CleanupOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        FakeBridge.operation_cleanup(identity, request)
    }

    fn operation_cleanup_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &CleanupOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        FakeBridge.operation_cleanup_with_cancellation(identity, request, cancellation)
    }

    fn operation_update(
        &self,
        identity: &RepositoryIdentity,
        request: &UpdateOperationRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<UpdateOperationResult, BridgeFailure> {
        FakeBridge.operation_update(identity, request, auth)
    }

    fn operation_update_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &UpdateOperationRequest,
        auth: &mut dyn AuthRequestBroker,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<UpdateOperationResult, BridgeFailure> {
        FakeBridge.operation_update_with_cancellation(identity, request, auth, cancellation)
    }

    delegate_property_methods_to_fake_bridge!();

    fn operation_commit(
        &self,
        identity: &RepositoryIdentity,
        request: &CommitOperationRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<CommitOperationResult, BridgeFailure> {
        FakeBridge.operation_commit(identity, request, auth)
    }

    fn operation_commit_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &CommitOperationRequest,
        auth: &mut dyn AuthRequestBroker,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<CommitOperationResult, BridgeFailure> {
        FakeBridge.operation_commit_with_cancellation(identity, request, auth, cancellation)
    }
}

macro_rules! delegate_fake_bridge_without_content_update_or_commit {
    () => {
        fn open_working_copy(&self, path: &str) -> Result<RepositoryIdentity, BridgeFailure> {
            FakeBridge.open_working_copy(path)
        }

        fn status_snapshot(
            &self,
            identity: &RepositoryIdentity,
            generation: u64,
        ) -> Result<StatusSnapshot, BridgeFailure> {
            FakeBridge.status_snapshot(identity, generation)
        }

        fn status_snapshot_with_cancellation(
            &self,
            identity: &RepositoryIdentity,
            generation: u64,
            cancellation: &dyn BridgeCancellationToken,
        ) -> Result<StatusSnapshot, BridgeFailure> {
            FakeBridge.status_snapshot_with_cancellation(identity, generation, cancellation)
        }

        fn status_scan(
            &self,
            identity: &RepositoryIdentity,
            path: &str,
            depth: &str,
            generation: u64,
        ) -> Result<StatusSnapshot, BridgeFailure> {
            FakeBridge.status_scan(identity, path, depth, generation)
        }

        fn status_scan_with_cancellation(
            &self,
            identity: &RepositoryIdentity,
            path: &str,
            depth: &str,
            generation: u64,
            cancellation: &dyn BridgeCancellationToken,
        ) -> Result<StatusSnapshot, BridgeFailure> {
            FakeBridge.status_scan_with_cancellation(
                identity,
                path,
                depth,
                generation,
                cancellation,
            )
        }

        fn history_log(
            &self,
            identity: &RepositoryIdentity,
            request: &HistoryLogRequest,
            auth: &mut dyn AuthRequestBroker,
        ) -> Result<HistoryLogResult, BridgeFailure> {
            FakeBridge.history_log(identity, request, auth)
        }

        fn history_blame(
            &self,
            identity: &RepositoryIdentity,
            request: &HistoryBlameRequest,
            auth: &mut dyn AuthRequestBroker,
        ) -> Result<HistoryBlameResult, BridgeFailure> {
            FakeBridge.history_blame(identity, request, auth)
        }

        fn operation_revert(
            &self,
            identity: &RepositoryIdentity,
            request: &RevertOperationRequest,
        ) -> Result<OperationResult, BridgeFailure> {
            FakeBridge.operation_revert(identity, request)
        }

        fn operation_revert_with_cancellation(
            &self,
            identity: &RepositoryIdentity,
            request: &RevertOperationRequest,
            cancellation: &dyn BridgeCancellationToken,
        ) -> Result<OperationResult, BridgeFailure> {
            FakeBridge.operation_revert_with_cancellation(identity, request, cancellation)
        }

        fn operation_add(
            &self,
            identity: &RepositoryIdentity,
            request: &AddOperationRequest,
        ) -> Result<OperationResult, BridgeFailure> {
            FakeBridge.operation_add(identity, request)
        }

        fn operation_add_with_cancellation(
            &self,
            identity: &RepositoryIdentity,
            request: &AddOperationRequest,
            cancellation: &dyn BridgeCancellationToken,
        ) -> Result<OperationResult, BridgeFailure> {
            FakeBridge.operation_add_with_cancellation(identity, request, cancellation)
        }

        fn operation_remove(
            &self,
            identity: &RepositoryIdentity,
            request: &RemoveOperationRequest,
        ) -> Result<OperationResult, BridgeFailure> {
            FakeBridge.operation_remove(identity, request)
        }

        fn operation_remove_with_cancellation(
            &self,
            identity: &RepositoryIdentity,
            request: &RemoveOperationRequest,
            cancellation: &dyn BridgeCancellationToken,
        ) -> Result<OperationResult, BridgeFailure> {
            FakeBridge.operation_remove_with_cancellation(identity, request, cancellation)
        }

        fn operation_move_with_cancellation(
            &self,
            identity: &RepositoryIdentity,
            request: &MoveOperationRequest,
            cancellation: &dyn BridgeCancellationToken,
        ) -> Result<OperationResult, BridgeFailure> {
            FakeBridge.operation_move_with_cancellation(identity, request, cancellation)
        }

        fn operation_resolve(
            &self,
            identity: &RepositoryIdentity,
            request: &ResolveOperationRequest,
        ) -> Result<OperationResult, BridgeFailure> {
            FakeBridge.operation_resolve(identity, request)
        }

        fn operation_resolve_with_cancellation(
            &self,
            identity: &RepositoryIdentity,
            request: &ResolveOperationRequest,
            cancellation: &dyn BridgeCancellationToken,
        ) -> Result<OperationResult, BridgeFailure> {
            FakeBridge.operation_resolve_with_cancellation(identity, request, cancellation)
        }

        fn operation_cleanup(
            &self,
            identity: &RepositoryIdentity,
            request: &CleanupOperationRequest,
        ) -> Result<OperationResult, BridgeFailure> {
            FakeBridge.operation_cleanup(identity, request)
        }

        fn operation_cleanup_with_cancellation(
            &self,
            identity: &RepositoryIdentity,
            request: &CleanupOperationRequest,
            cancellation: &dyn BridgeCancellationToken,
        ) -> Result<OperationResult, BridgeFailure> {
            FakeBridge.operation_cleanup_with_cancellation(identity, request, cancellation)
        }

        delegate_property_methods_to_fake_bridge!();
    };
}

macro_rules! delegate_fake_bridge_without_content_or_update {
    () => {
        delegate_fake_bridge_without_content_update_or_commit!();

        fn operation_commit(
            &self,
            identity: &RepositoryIdentity,
            request: &CommitOperationRequest,
            auth: &mut dyn AuthRequestBroker,
        ) -> Result<CommitOperationResult, BridgeFailure> {
            FakeBridge.operation_commit(identity, request, auth)
        }

        fn operation_commit_with_cancellation(
            &self,
            identity: &RepositoryIdentity,
            request: &CommitOperationRequest,
            auth: &mut dyn AuthRequestBroker,
            cancellation: &dyn BridgeCancellationToken,
        ) -> Result<CommitOperationResult, BridgeFailure> {
            FakeBridge.operation_commit_with_cancellation(identity, request, auth, cancellation)
        }
    };
}

macro_rules! delegate_fake_bridge_without_update {
    () => {
        delegate_fake_bridge_without_content_update_or_commit!();

        fn content_get(
            &self,
            identity: &RepositoryIdentity,
            path: &str,
            revision: &str,
            auth: &mut dyn AuthRequestBroker,
        ) -> Result<ContentBlob, BridgeFailure> {
            FakeBridge.content_get(identity, path, revision, auth)
        }

        fn operation_commit(
            &self,
            identity: &RepositoryIdentity,
            request: &CommitOperationRequest,
            auth: &mut dyn AuthRequestBroker,
        ) -> Result<CommitOperationResult, BridgeFailure> {
            FakeBridge.operation_commit(identity, request, auth)
        }

        fn operation_commit_with_cancellation(
            &self,
            identity: &RepositoryIdentity,
            request: &CommitOperationRequest,
            auth: &mut dyn AuthRequestBroker,
            cancellation: &dyn BridgeCancellationToken,
        ) -> Result<CommitOperationResult, BridgeFailure> {
            FakeBridge.operation_commit_with_cancellation(identity, request, auth, cancellation)
        }
    };
}

macro_rules! delegate_fake_bridge_without_commit {
    () => {
        delegate_fake_bridge_without_content_update_or_commit!();

        fn content_get(
            &self,
            identity: &RepositoryIdentity,
            path: &str,
            revision: &str,
            auth: &mut dyn AuthRequestBroker,
        ) -> Result<ContentBlob, BridgeFailure> {
            FakeBridge.content_get(identity, path, revision, auth)
        }

        fn operation_update(
            &self,
            identity: &RepositoryIdentity,
            request: &UpdateOperationRequest,
            auth: &mut dyn AuthRequestBroker,
        ) -> Result<UpdateOperationResult, BridgeFailure> {
            FakeBridge.operation_update(identity, request, auth)
        }

        fn operation_update_with_cancellation(
            &self,
            identity: &RepositoryIdentity,
            request: &UpdateOperationRequest,
            auth: &mut dyn AuthRequestBroker,
            cancellation: &dyn BridgeCancellationToken,
        ) -> Result<UpdateOperationResult, BridgeFailure> {
            FakeBridge.operation_update_with_cancellation(identity, request, auth, cancellation)
        }
    };
}

macro_rules! delegate_fake_bridge {
    () => {
        delegate_fake_bridge_without_commit!();

        fn operation_commit(
            &self,
            identity: &RepositoryIdentity,
            request: &CommitOperationRequest,
            auth: &mut dyn AuthRequestBroker,
        ) -> Result<CommitOperationResult, BridgeFailure> {
            FakeBridge.operation_commit(identity, request, auth)
        }

        fn operation_commit_with_cancellation(
            &self,
            identity: &RepositoryIdentity,
            request: &CommitOperationRequest,
            auth: &mut dyn AuthRequestBroker,
            cancellation: &dyn BridgeCancellationToken,
        ) -> Result<CommitOperationResult, BridgeFailure> {
            FakeBridge.operation_commit_with_cancellation(identity, request, auth, cancellation)
        }
    };
}

#[derive(Debug)]
struct CancellableOperationBridge;

impl CancellableOperationBridge {
    fn cancelled_operation(path: &str) -> BridgeFailure {
        BridgeFailure::new(
            "SVN_OPERATION_CANCELLED",
            "cancelled",
            "error.native.operationCancelled",
            serde_json::json!({ "path": path, "status": 12 }),
            false,
        )
    }

    fn uncancellable_operation(path: &str) -> BridgeFailure {
        BridgeFailure::new(
            "TEST_OPERATION_NOT_CANCELABLE",
            "test",
            "error.test.operationNotCancelable",
            serde_json::json!({ "path": path }),
            false,
        )
    }
}

impl BridgeApi for CancellableOperationBridge {
    fn info(&self) -> BridgeInfo {
        FakeBridge.info()
    }

    delegate_fake_bridge_without_update!();

    fn operation_update(
        &self,
        _identity: &RepositoryIdentity,
        request: &UpdateOperationRequest,
        _auth: &mut dyn AuthRequestBroker,
    ) -> Result<UpdateOperationResult, BridgeFailure> {
        thread::sleep(Duration::from_millis(100));
        Err(Self::uncancellable_operation(&request.path))
    }

    fn operation_update_with_cancellation(
        &self,
        _identity: &RepositoryIdentity,
        request: &UpdateOperationRequest,
        _auth: &mut dyn AuthRequestBroker,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<UpdateOperationResult, BridgeFailure> {
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if cancellation.is_cancelled() {
                return Err(Self::cancelled_operation(&request.path));
            }
            thread::sleep(Duration::from_millis(5));
        }
        Err(Self::uncancellable_operation(&request.path))
    }
}

macro_rules! delegate_fake_bridge_without_history {
    () => {
        fn open_working_copy(&self, path: &str) -> Result<RepositoryIdentity, BridgeFailure> {
            FakeBridge.open_working_copy(path)
        }

        fn status_snapshot(
            &self,
            identity: &RepositoryIdentity,
            generation: u64,
        ) -> Result<StatusSnapshot, BridgeFailure> {
            FakeBridge.status_snapshot(identity, generation)
        }

        fn status_snapshot_with_cancellation(
            &self,
            identity: &RepositoryIdentity,
            generation: u64,
            cancellation: &dyn BridgeCancellationToken,
        ) -> Result<StatusSnapshot, BridgeFailure> {
            FakeBridge.status_snapshot_with_cancellation(identity, generation, cancellation)
        }

        fn status_scan(
            &self,
            identity: &RepositoryIdentity,
            path: &str,
            depth: &str,
            generation: u64,
        ) -> Result<StatusSnapshot, BridgeFailure> {
            FakeBridge.status_scan(identity, path, depth, generation)
        }

        fn status_scan_with_cancellation(
            &self,
            identity: &RepositoryIdentity,
            path: &str,
            depth: &str,
            generation: u64,
            cancellation: &dyn BridgeCancellationToken,
        ) -> Result<StatusSnapshot, BridgeFailure> {
            FakeBridge.status_scan_with_cancellation(
                identity,
                path,
                depth,
                generation,
                cancellation,
            )
        }

        fn content_get(
            &self,
            identity: &RepositoryIdentity,
            path: &str,
            revision: &str,
            auth: &mut dyn AuthRequestBroker,
        ) -> Result<ContentBlob, BridgeFailure> {
            FakeBridge.content_get(identity, path, revision, auth)
        }

        fn operation_revert(
            &self,
            identity: &RepositoryIdentity,
            request: &RevertOperationRequest,
        ) -> Result<OperationResult, BridgeFailure> {
            FakeBridge.operation_revert(identity, request)
        }

        fn operation_revert_with_cancellation(
            &self,
            identity: &RepositoryIdentity,
            request: &RevertOperationRequest,
            cancellation: &dyn BridgeCancellationToken,
        ) -> Result<OperationResult, BridgeFailure> {
            FakeBridge.operation_revert_with_cancellation(identity, request, cancellation)
        }

        fn operation_add(
            &self,
            identity: &RepositoryIdentity,
            request: &AddOperationRequest,
        ) -> Result<OperationResult, BridgeFailure> {
            FakeBridge.operation_add(identity, request)
        }

        fn operation_add_with_cancellation(
            &self,
            identity: &RepositoryIdentity,
            request: &AddOperationRequest,
            cancellation: &dyn BridgeCancellationToken,
        ) -> Result<OperationResult, BridgeFailure> {
            FakeBridge.operation_add_with_cancellation(identity, request, cancellation)
        }

        fn operation_remove(
            &self,
            identity: &RepositoryIdentity,
            request: &RemoveOperationRequest,
        ) -> Result<OperationResult, BridgeFailure> {
            FakeBridge.operation_remove(identity, request)
        }

        fn operation_remove_with_cancellation(
            &self,
            identity: &RepositoryIdentity,
            request: &RemoveOperationRequest,
            cancellation: &dyn BridgeCancellationToken,
        ) -> Result<OperationResult, BridgeFailure> {
            FakeBridge.operation_remove_with_cancellation(identity, request, cancellation)
        }

        fn operation_move_with_cancellation(
            &self,
            identity: &RepositoryIdentity,
            request: &MoveOperationRequest,
            cancellation: &dyn BridgeCancellationToken,
        ) -> Result<OperationResult, BridgeFailure> {
            FakeBridge.operation_move_with_cancellation(identity, request, cancellation)
        }

        fn operation_resolve(
            &self,
            identity: &RepositoryIdentity,
            request: &ResolveOperationRequest,
        ) -> Result<OperationResult, BridgeFailure> {
            FakeBridge.operation_resolve(identity, request)
        }

        fn operation_resolve_with_cancellation(
            &self,
            identity: &RepositoryIdentity,
            request: &ResolveOperationRequest,
            cancellation: &dyn BridgeCancellationToken,
        ) -> Result<OperationResult, BridgeFailure> {
            FakeBridge.operation_resolve_with_cancellation(identity, request, cancellation)
        }

        fn operation_cleanup(
            &self,
            identity: &RepositoryIdentity,
            request: &CleanupOperationRequest,
        ) -> Result<OperationResult, BridgeFailure> {
            FakeBridge.operation_cleanup(identity, request)
        }

        fn operation_cleanup_with_cancellation(
            &self,
            identity: &RepositoryIdentity,
            request: &CleanupOperationRequest,
            cancellation: &dyn BridgeCancellationToken,
        ) -> Result<OperationResult, BridgeFailure> {
            FakeBridge.operation_cleanup_with_cancellation(identity, request, cancellation)
        }

        delegate_property_methods_to_fake_bridge!();

        fn operation_update(
            &self,
            identity: &RepositoryIdentity,
            request: &UpdateOperationRequest,
            auth: &mut dyn AuthRequestBroker,
        ) -> Result<UpdateOperationResult, BridgeFailure> {
            FakeBridge.operation_update(identity, request, auth)
        }

        fn operation_update_with_cancellation(
            &self,
            identity: &RepositoryIdentity,
            request: &UpdateOperationRequest,
            auth: &mut dyn AuthRequestBroker,
            cancellation: &dyn BridgeCancellationToken,
        ) -> Result<UpdateOperationResult, BridgeFailure> {
            FakeBridge.operation_update_with_cancellation(identity, request, auth, cancellation)
        }

        fn operation_commit(
            &self,
            identity: &RepositoryIdentity,
            request: &CommitOperationRequest,
            auth: &mut dyn AuthRequestBroker,
        ) -> Result<CommitOperationResult, BridgeFailure> {
            FakeBridge.operation_commit(identity, request, auth)
        }

        fn operation_commit_with_cancellation(
            &self,
            identity: &RepositoryIdentity,
            request: &CommitOperationRequest,
            auth: &mut dyn AuthRequestBroker,
            cancellation: &dyn BridgeCancellationToken,
        ) -> Result<CommitOperationResult, BridgeFailure> {
            FakeBridge.operation_commit_with_cancellation(identity, request, auth, cancellation)
        }
    };
}

#[derive(Debug)]
struct CredentialChallengeBridge;

impl BridgeApi for CredentialChallengeBridge {
    fn info(&self) -> BridgeInfo {
        FakeBridge.info()
    }

    delegate_fake_bridge!();

    fn open_working_copy_with_auth(
        &self,
        path: &str,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<RepositoryIdentity, BridgeFailure> {
        let response = auth.request_credential(credential_request(
            "cred-1",
            "svn://example",
            true,
            true,
            RemoteOperationIntent::Foreground,
            30_000,
        ))?;

        assert_eq!(response, provided_credential("cred-1"));

        FakeBridge.open_working_copy(path)
    }
}

#[derive(Debug)]
struct CertificateChallengeBridge;

impl BridgeApi for CertificateChallengeBridge {
    fn info(&self) -> BridgeInfo {
        FakeBridge.info()
    }

    delegate_fake_bridge!();

    fn open_working_copy_with_auth(
        &self,
        path: &str,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<RepositoryIdentity, BridgeFailure> {
        let response = auth.request_certificate_trust(CertificateTrustRequest {
            request_id: "cert-1".to_string(),
            realm: "https://svn.example.com:443".to_string(),
            host: "svn.example.com".to_string(),
            fingerprint: "AA:BB:CC".to_string(),
            fingerprint_algorithm: "sha256-der".to_string(),
            failures: vec!["unknownCa".to_string(), "hostnameMismatch".to_string()],
            valid_from: "2026-01-01T00:00:00Z".to_string(),
            valid_to: "2027-01-01T00:00:00Z".to_string(),
            issuer: Some("CN=Example Test CA".to_string()),
            subject: Some("CN=svn.example.com".to_string()),
            interactive: true,
            persistence_allowed: true,
            origin: "foreground".to_string(),
            timeout_ms: 30000,
            repository_id: None,
            working_copy_root: Some(path.to_string()),
        })?;

        assert_eq!(
            response,
            CertificateTrustResponse::Trust {
                request_id: "cert-1".to_string(),
                trust: "once".to_string(),
                fingerprint: "AA:BB:CC".to_string(),
                fingerprint_algorithm: "sha256-der".to_string(),
            }
        );

        FakeBridge.open_working_copy(path)
    }
}

#[derive(Debug)]
struct UpdateCredentialChallengeBridge;

impl BridgeApi for UpdateCredentialChallengeBridge {
    fn info(&self) -> BridgeInfo {
        FakeBridge.info()
    }

    delegate_fake_bridge_without_update!();

    fn operation_update(
        &self,
        _identity: &RepositoryIdentity,
        request: &UpdateOperationRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<UpdateOperationResult, BridgeFailure> {
        let response = auth.request_credential(credential_request(
            "update-cred-1",
            "svn://example/update",
            true,
            true,
            RemoteOperationIntent::Foreground,
            30_000,
        ))?;

        assert_eq!(response, provided_credential("update-cred-1"));

        Ok(UpdateOperationResult {
            result: OperationResult {
                touched_paths: vec![request.path.clone()],
                skipped_paths: Vec::new(),
            },
            revision: 9,
        })
    }

    fn operation_update_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &UpdateOperationRequest,
        auth: &mut dyn AuthRequestBroker,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<UpdateOperationResult, BridgeFailure> {
        self.operation_update(identity, request, auth)
    }
}

#[derive(Debug)]
struct RemoteStatusCredentialChallengeBridge;

impl BridgeApi for RemoteStatusCredentialChallengeBridge {
    fn info(&self) -> BridgeInfo {
        FakeBridge.info()
    }

    delegate_fake_bridge!();

    fn status_remote_check_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        generation: u64,
        auth: &mut dyn AuthRequestBroker,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<StatusSnapshot, BridgeFailure> {
        let response = auth.request_credential(credential_request(
            "remote-status-cred-1",
            "svn://example/status",
            true,
            true,
            RemoteOperationIntent::Foreground,
            30_000,
        ))?;
        assert!(matches!(response, CredentialResponse::Provide { .. }));

        let mut snapshot = FakeBridge.status_snapshot(identity, generation)?;
        let mut entry = snapshot.local_entries.remove(0);
        entry.remote_status = "modified".to_string();
        snapshot.local_entries.clear();
        snapshot.remote_entries = vec![entry];
        snapshot.summary = StatusSummary {
            local_changes: 0,
            remote_changes: 1,
            conflicts: 0,
            unversioned: 0,
        };
        snapshot.source = "libsvn-remote".to_string();
        Ok(snapshot)
    }
}

#[derive(Debug)]
struct UpdateFailureBridge;

impl BridgeApi for UpdateFailureBridge {
    fn info(&self) -> BridgeInfo {
        FakeBridge.info()
    }

    delegate_fake_bridge_without_update!();

    fn operation_update(
        &self,
        _identity: &RepositoryIdentity,
        _request: &UpdateOperationRequest,
        _auth: &mut dyn AuthRequestBroker,
    ) -> Result<UpdateOperationResult, BridgeFailure> {
        Err(BridgeFailure::new(
            "SVN_OPERATION_UPDATE_FAILED",
            "native",
            "error.native.operationUpdateFailed",
            serde_json::json!({ "kind": "update" }),
            false,
        ))
    }

    fn operation_update_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &UpdateOperationRequest,
        auth: &mut dyn AuthRequestBroker,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<UpdateOperationResult, BridgeFailure> {
        self.operation_update(identity, request, auth)
    }
}

#[derive(Debug)]
struct ContentCredentialChallengeBridge;

impl BridgeApi for ContentCredentialChallengeBridge {
    fn info(&self) -> BridgeInfo {
        FakeBridge.info()
    }

    delegate_fake_bridge_without_content_or_update!();

    fn content_get(
        &self,
        _identity: &RepositoryIdentity,
        path: &str,
        revision: &str,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<ContentBlob, BridgeFailure> {
        assert_eq!(path, "tracked.txt");
        assert_eq!(revision, "head");
        let response = auth.request_credential(credential_request(
            "content-cred-1",
            "svn://example/content",
            true,
            true,
            RemoteOperationIntent::Foreground,
            30_000,
        ))?;

        assert_eq!(response, provided_credential("content-cred-1"));

        Ok(ContentBlob {
            data: b"head content\n".to_vec(),
            mime_type: Some("text/plain".to_string()),
            is_binary: false,
            source: "libsvn-head".to_string(),
        })
    }

    fn operation_update(
        &self,
        identity: &RepositoryIdentity,
        request: &UpdateOperationRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<UpdateOperationResult, BridgeFailure> {
        FakeBridge.operation_update(identity, request, auth)
    }

    fn operation_update_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &UpdateOperationRequest,
        auth: &mut dyn AuthRequestBroker,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<UpdateOperationResult, BridgeFailure> {
        FakeBridge.operation_update_with_cancellation(identity, request, auth, cancellation)
    }
}

#[derive(Debug)]
struct HistoryLogCredentialChallengeBridge;

impl BridgeApi for HistoryLogCredentialChallengeBridge {
    fn info(&self) -> BridgeInfo {
        FakeBridge.info()
    }

    delegate_fake_bridge_without_history!();

    fn history_log(
        &self,
        _identity: &RepositoryIdentity,
        request: &HistoryLogRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<HistoryLogResult, BridgeFailure> {
        assert_eq!(request.path, "tracked.txt");
        assert_eq!(request.start_revision, "head");
        let response = auth.request_credential(credential_request(
            "history-log-cred-1",
            "svn://example/history-log",
            true,
            true,
            RemoteOperationIntent::Foreground,
            30_000,
        ))?;

        assert_eq!(response, provided_credential("history-log-cred-1"));

        Ok(HistoryLogResult {
            entries: Vec::new(),
            source: "libsvn-log".to_string(),
        })
    }

    fn history_blame(
        &self,
        identity: &RepositoryIdentity,
        request: &HistoryBlameRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<HistoryBlameResult, BridgeFailure> {
        FakeBridge.history_blame(identity, request, auth)
    }
}

#[derive(Debug)]
struct HistoryBlameCredentialChallengeBridge;

impl BridgeApi for HistoryBlameCredentialChallengeBridge {
    fn info(&self) -> BridgeInfo {
        FakeBridge.info()
    }

    delegate_fake_bridge_without_history!();

    fn history_log(
        &self,
        identity: &RepositoryIdentity,
        request: &HistoryLogRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<HistoryLogResult, BridgeFailure> {
        FakeBridge.history_log(identity, request, auth)
    }

    fn history_blame(
        &self,
        _identity: &RepositoryIdentity,
        request: &HistoryBlameRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<HistoryBlameResult, BridgeFailure> {
        assert_eq!(request.path, "tracked.txt");
        assert_eq!(request.end_revision, "head");
        let response = auth.request_credential(credential_request(
            "history-blame-cred-1",
            "svn://example/history-blame",
            true,
            true,
            RemoteOperationIntent::Foreground,
            30_000,
        ))?;

        assert_eq!(response, provided_credential("history-blame-cred-1"));

        Ok(HistoryBlameResult {
            resolved_start_revision: 0,
            resolved_end_revision: 2,
            line_start: request.line_start,
            line_limit: request.line_limit,
            ignore_whitespace: request.ignore_whitespace.clone(),
            ignore_eol_style: request.ignore_eol_style,
            ignore_mime_type: request.ignore_mime_type,
            include_merged_revisions: request.include_merged_revisions,
            has_more: false,
            lines: Vec::new(),
            source: "libsvn-blame".to_string(),
        })
    }
}

#[derive(Debug)]
struct CommitCredentialChallengeBridge;

impl BridgeApi for CommitCredentialChallengeBridge {
    fn info(&self) -> BridgeInfo {
        FakeBridge.info()
    }

    delegate_fake_bridge_without_commit!();

    fn operation_commit(
        &self,
        _identity: &RepositoryIdentity,
        request: &CommitOperationRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<CommitOperationResult, BridgeFailure> {
        assert_eq!(request.paths, vec!["tracked.txt".to_string()]);
        assert_eq!(request.message, "commit through broker");
        let response = auth.request_credential(credential_request(
            "commit-cred-1",
            "svn://example/commit",
            true,
            true,
            RemoteOperationIntent::Foreground,
            30_000,
        ))?;

        assert_eq!(response, provided_credential("commit-cred-1"));

        Ok(CommitOperationResult {
            result: OperationResult {
                touched_paths: request.paths.clone(),
                skipped_paths: Vec::new(),
            },
            revision: 10,
        })
    }

    fn operation_commit_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &CommitOperationRequest,
        auth: &mut dyn AuthRequestBroker,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<CommitOperationResult, BridgeFailure> {
        self.operation_commit(identity, request, auth)
    }
}

#[derive(Debug)]
struct NonInteractiveCredentialBridge;

impl BridgeApi for NonInteractiveCredentialBridge {
    fn info(&self) -> BridgeInfo {
        FakeBridge.info()
    }

    delegate_fake_bridge!();

    fn open_working_copy_with_auth(
        &self,
        path: &str,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<RepositoryIdentity, BridgeFailure> {
        let response = auth.request_credential(credential_request(
            "cred-background",
            "svn://example",
            false,
            false,
            RemoteOperationIntent::Background,
            30_000,
        ))?;
        assert!(matches!(
            response,
            CredentialResponse::Provide {
                persistence_intent: CredentialPersistenceIntent::Session,
                ..
            }
        ));
        FakeBridge.open_working_copy(path)
    }
}

#[derive(Debug)]
struct NonInteractiveCertificateBridge;

impl BridgeApi for NonInteractiveCertificateBridge {
    fn info(&self) -> BridgeInfo {
        FakeBridge.info()
    }

    delegate_fake_bridge!();

    fn open_working_copy_with_auth(
        &self,
        path: &str,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<RepositoryIdentity, BridgeFailure> {
        match auth.request_certificate_trust(CertificateTrustRequest {
            request_id: "cert-background".to_string(),
            realm: "https://svn.example.com:443".to_string(),
            host: "svn.example.com".to_string(),
            fingerprint: "AA:BB:CC".to_string(),
            fingerprint_algorithm: "sha256-der".to_string(),
            failures: vec!["unknownCa".to_string()],
            valid_from: "2026-01-01T00:00:00Z".to_string(),
            valid_to: "2027-01-01T00:00:00Z".to_string(),
            issuer: None,
            subject: None,
            interactive: false,
            persistence_allowed: false,
            origin: "background".to_string(),
            timeout_ms: 30000,
            repository_id: None,
            working_copy_root: Some(path.to_string()),
        }) {
            Ok(_) => panic!("non-interactive certificate request must not trust a certificate"),
            Err(failure) => Err(failure),
        }
    }
}

#[derive(Debug)]
struct CredentialBodyValidationBridge;

impl BridgeApi for CredentialBodyValidationBridge {
    fn info(&self) -> BridgeInfo {
        FakeBridge.info()
    }

    delegate_fake_bridge!();

    fn open_working_copy_with_auth(
        &self,
        path: &str,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<RepositoryIdentity, BridgeFailure> {
        auth.request_credential(credential_request(
            "cred-expected",
            "svn://example",
            true,
            true,
            RemoteOperationIntent::Foreground,
            30_000,
        ))?;

        FakeBridge.open_working_copy(path)
    }
}

#[derive(Debug)]
struct CredentialSettlementValidationBridge;

impl BridgeApi for CredentialSettlementValidationBridge {
    fn info(&self) -> BridgeInfo {
        FakeBridge.info()
    }

    delegate_fake_bridge!();

    fn open_working_copy_with_auth(
        &self,
        _path: &str,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<RepositoryIdentity, BridgeFailure> {
        auth.settle_credential(credential_settlement_request(
            "settle-expected-operation",
            30_000,
        ))?;
        panic!("settlement error fixture must not succeed")
    }
}

#[derive(Debug)]
struct CredentialTimeoutBridge;

impl BridgeApi for CredentialTimeoutBridge {
    fn info(&self) -> BridgeInfo {
        FakeBridge.info()
    }

    delegate_fake_bridge!();

    fn open_working_copy_with_auth(
        &self,
        path: &str,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<RepositoryIdentity, BridgeFailure> {
        auth.request_credential(credential_request(
            "cred-timeout",
            "svn://example",
            true,
            true,
            RemoteOperationIntent::Foreground,
            0,
        ))?;

        FakeBridge.open_working_copy(path)
    }
}

#[derive(Debug)]
struct CredentialShortTimeoutBridge;

impl BridgeApi for CredentialShortTimeoutBridge {
    fn info(&self) -> BridgeInfo {
        FakeBridge.info()
    }

    delegate_fake_bridge!();

    fn open_working_copy_with_auth(
        &self,
        path: &str,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<RepositoryIdentity, BridgeFailure> {
        auth.request_credential(credential_request(
            "cred-short-timeout",
            "svn://example",
            true,
            true,
            RemoteOperationIntent::Foreground,
            1,
        ))?;

        FakeBridge.open_working_copy(path)
    }
}

#[derive(Debug)]
struct CertificateBodyValidationBridge;

impl BridgeApi for CertificateBodyValidationBridge {
    fn info(&self) -> BridgeInfo {
        FakeBridge.info()
    }

    delegate_fake_bridge!();

    fn open_working_copy_with_auth(
        &self,
        path: &str,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<RepositoryIdentity, BridgeFailure> {
        auth.request_certificate_trust(CertificateTrustRequest {
            request_id: "cert-expected".to_string(),
            realm: "https://svn.example.com:443".to_string(),
            host: "svn.example.com".to_string(),
            fingerprint: "AA:BB:CC".to_string(),
            fingerprint_algorithm: "sha256-der".to_string(),
            failures: vec!["unknownCa".to_string()],
            valid_from: "2026-01-01T00:00:00Z".to_string(),
            valid_to: "2027-01-01T00:00:00Z".to_string(),
            issuer: None,
            subject: None,
            interactive: true,
            persistence_allowed: true,
            origin: "foreground".to_string(),
            timeout_ms: 30000,
            repository_id: None,
            working_copy_root: Some(path.to_string()),
        })?;

        FakeBridge.open_working_copy(path)
    }
}

#[derive(Debug)]
struct CertificateShortTimeoutBridge;

impl BridgeApi for CertificateShortTimeoutBridge {
    fn info(&self) -> BridgeInfo {
        FakeBridge.info()
    }

    delegate_fake_bridge!();

    fn open_working_copy_with_auth(
        &self,
        path: &str,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<RepositoryIdentity, BridgeFailure> {
        auth.request_certificate_trust(CertificateTrustRequest {
            request_id: "cert-short-timeout".to_string(),
            realm: "https://svn.example.com:443".to_string(),
            host: "svn.example.com".to_string(),
            fingerprint: "AA:BB:CC".to_string(),
            fingerprint_algorithm: "sha256-der".to_string(),
            failures: vec!["unknownCa".to_string()],
            valid_from: "2026-01-01T00:00:00Z".to_string(),
            valid_to: "2027-01-01T00:00:00Z".to_string(),
            issuer: None,
            subject: None,
            interactive: true,
            persistence_allowed: true,
            origin: "foreground".to_string(),
            timeout_ms: 1,
            repository_id: None,
            working_copy_root: Some(path.to_string()),
        })?;

        FakeBridge.open_working_copy(path)
    }
}

#[test]
fn stdio_loop_dispatches_content_length_framed_requests_until_shutdown() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","trustEpoch":1,"cacheRoot":"C:/Users/Alice/AppData/Roaming/Code/User/globalStorage/subversionr/cache"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":2,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(io::Cursor::new(input), &mut output, &FakeBridge)
        .expect("stdio loop should dispatch framed requests");

    let responses = decode_frames(&output).expect("responses should be content-length framed");
    assert_eq!(responses.len(), 2);
    assert_eq!(responses[0]["id"], 1);
    assert_eq!(
        responses[0]["result"]["bridgeVersion"],
        "subversionr-svn-bridge/0.1.0-test"
    );
    assert_eq!(responses[1]["id"], 2);
    assert_eq!(responses[1]["result"]["accepted"], true);
}

#[test]
fn stdio_loop_cancels_active_status_refresh_notification() {
    let first = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":2,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":"tracked.txt","depth":"empty","reason":"fileChanged"}]}}"#),
    ]
    .concat();
    let second = [
        frame(r#"{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":2}}"#),
        frame(r#"{"jsonrpc":"2.0","id":3,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let reader = DelayedSecondChunkReader::new(first, second, Duration::from_millis(50));
    let mut output = Vec::new();

    run_json_rpc_stdio(reader, &mut output, &CancellableStatusBridge)
        .expect("stdio loop should cancel active status refreshes");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 3);
    assert_eq!(frames[0]["id"], 1);
    assert_eq!(frames[0]["result"]["repositoryId"], "repo-uuid:C:/wc");
    assert_eq!(frames[1]["id"], 2);
    assert_eq!(frames[1]["error"]["code"], "SVN_STATUS_CANCELLED");
    assert_eq!(frames[1]["error"]["category"], "cancelled");
    assert_eq!(
        frames[1]["error"]["messageKey"],
        "error.native.statusCancelled"
    );
    assert_eq!(frames[2]["id"], 3);
    assert_eq!(frames[2]["result"]["accepted"], true);
}

#[test]
fn stdio_loop_cancels_active_update_operation_notification() {
    let first = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":2,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"update","options":{"version":1,"path":".","revision":"head","depth":"workingCopy","depthIsSticky":false,"ignoreExternals":true}}}"#),
    ]
    .concat();
    let second = [
        frame(r#"{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":2}}"#),
        frame(r#"{"jsonrpc":"2.0","id":3,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let reader = DelayedSecondChunkReader::new(first, second, Duration::from_millis(50));
    let mut output = Vec::new();

    run_json_rpc_stdio(reader, &mut output, &CancellableOperationBridge)
        .expect("stdio loop should cancel active update operations");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 4);
    assert_eq!(frames[0]["id"], 1);
    assert_eq!(frames[0]["result"]["repositoryId"], "repo-uuid:C:/wc");
    assert_eq!(frames[1]["id"], 2);
    assert_eq!(frames[1]["error"]["code"], "SVN_OPERATION_CANCELLED");
    assert_eq!(frames[1]["error"]["category"], "cancelled");
    assert_eq!(
        frames[1]["error"]["messageKey"],
        "error.native.operationCancelled"
    );
    assert!(frames[2].get("id").is_none());
    assert_eq!(frames[2]["method"], "status/stale");
    assert_eq!(frames[2]["params"]["repositoryId"], "repo-uuid:C:/wc");
    assert_eq!(frames[2]["params"]["epoch"], 1);
    assert_eq!(frames[2]["params"]["reason"], "operationUpdateFailed");
    assert_eq!(frames[2]["params"]["source"], "subversionr-daemon");
    assert_eq!(frames[3]["id"], 3);
    assert_eq!(frames[3]["result"]["accepted"], true);
}

#[test]
fn stdio_loop_sends_credential_request_and_waits_for_client_response() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cred-1","result":{"requestId":"cred-1","operationId":"cred-1-operation","action":"provide","leaseId":"cred-1-lease","credential":{"username":"alice","secret":"secret"},"persistenceIntent":"secretStorage"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":2,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CredentialChallengeBridge,
    )
    .expect("stdio loop should bridge credential challenges");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 3);
    assert_credential_request_frame(&frames[0], "cred-1", "svn://example");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(frames[1]["result"]["repositoryId"], "repo-uuid:C:/wc");
    assert_eq!(frames[2]["id"], 2);
    assert_eq!(frames[2]["result"]["accepted"], true);
}

#[test]
fn stdio_loop_routes_update_operation_through_credential_broker() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":2,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"update","options":{"version":1,"path":".","revision":"head","depth":"workingCopy","depthIsSticky":false,"ignoreExternals":true}}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"update-cred-1","result":{"requestId":"update-cred-1","operationId":"update-cred-1-operation","action":"provide","leaseId":"update-cred-1-lease","credential":{"username":"alice","secret":"secret"},"persistenceIntent":"secretStorage"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":3,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &UpdateCredentialChallengeBridge,
    )
    .expect("stdio loop should bridge update credential challenges");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 5);
    assert_eq!(frames[0]["id"], 1);
    assert_eq!(frames[0]["result"]["repositoryId"], "repo-uuid:C:/wc");
    assert_credential_request_frame(&frames[1], "update-cred-1", "svn://example/update");
    assert_eq!(frames[2]["id"], 2);
    assert_eq!(frames[2]["result"]["kind"], "update");
    assert_eq!(frames[2]["result"]["revision"], 9);
    assert!(frames[3].get("id").is_none());
    assert_eq!(frames[3]["method"], "status/stale");
    assert_eq!(frames[3]["params"]["repositoryId"], "repo-uuid:C:/wc");
    assert_eq!(frames[3]["params"]["epoch"], 1);
    assert_eq!(
        frames[3]["params"]["reason"],
        "operationUpdateRequiresFullReconcile"
    );
    assert_eq!(frames[3]["params"]["source"], "subversionr-daemon");
    assert!(
        frames[3]["params"]["timestamp"]
            .as_str()
            .is_some_and(|timestamp| !timestamp.is_empty())
    );
    assert_eq!(frames[4]["id"], 3);
    assert_eq!(frames[4]["result"]["accepted"], true);
}

#[test]
fn stdio_loop_routes_remote_status_through_credential_broker() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":2,"method":"status/checkRemote","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"remote-status-cred-1","result":{"requestId":"remote-status-cred-1","operationId":"remote-status-cred-1-operation","action":"provide","leaseId":"remote-status-cred-1-lease","credential":{"username":"alice","secret":"secret"},"persistenceIntent":"secretStorage"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":3,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &RemoteStatusCredentialChallengeBridge,
    )
    .expect("stdio loop should bridge remote-status credential challenges");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 4);
    assert_credential_request_frame(&frames[1], "remote-status-cred-1", "svn://example/status");
    assert_eq!(frames[2]["id"], 2);
    assert_eq!(frames[2]["result"]["source"], "libsvn-remote");
    assert_eq!(
        frames[2]["result"]["remoteUpsert"][0]["remoteStatus"],
        "modified"
    );
    assert_eq!(frames[3]["result"]["accepted"], true);
}

#[test]
fn stdio_loop_remote_status_auth_cancel_preserves_generation() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":2,"method":"status/checkRemote","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"remote-status-cred-1","result":{"requestId":"remote-status-cred-1","operationId":"remote-status-cred-1-operation","action":"cancel","error":{"code":"SUBVERSIONR_CREDENTIAL_CANCELLED","category":"auth","messageKey":"error.auth.credentialCancelled","args":{},"retryable":false}}}"#),
        frame(r#"{"jsonrpc":"2.0","id":3,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":"tracked.txt","depth":"empty","reason":"fileChanged"}]}}"#),
        frame(r#"{"jsonrpc":"2.0","id":4,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &RemoteStatusCredentialChallengeBridge,
    )
    .expect("stdio loop should preserve remote status state after auth cancellation");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 5);
    assert_eq!(frames[2]["id"], 2);
    assert_eq!(
        frames[2]["error"]["code"],
        "SUBVERSIONR_CREDENTIAL_CANCELLED"
    );
    assert_eq!(frames[3]["id"], 3);
    assert_eq!(frames[3]["result"]["generation"], 1);
    assert_eq!(frames[3]["result"]["remoteUpsert"], serde_json::json!([]));
    assert_eq!(frames[4]["result"]["accepted"], true);
}

#[test]
fn stdio_loop_marks_status_stale_after_update_operation_failure() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":2,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"update","options":{"version":1,"path":".","revision":"head","depth":"workingCopy","depthIsSticky":false,"ignoreExternals":true}}}"#),
        frame(r#"{"jsonrpc":"2.0","id":3,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(io::Cursor::new(input), &mut output, &UpdateFailureBridge)
        .expect("stdio loop should dispatch update failure");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 4);
    assert_eq!(frames[0]["id"], 1);
    assert_eq!(frames[0]["result"]["repositoryId"], "repo-uuid:C:/wc");
    assert_eq!(frames[1]["id"], 2);
    assert_eq!(frames[1]["error"]["code"], "SVN_OPERATION_UPDATE_FAILED");
    assert!(frames[2].get("id").is_none());
    assert_eq!(frames[2]["method"], "status/stale");
    assert_eq!(frames[2]["params"]["repositoryId"], "repo-uuid:C:/wc");
    assert_eq!(frames[2]["params"]["epoch"], 1);
    assert_eq!(frames[2]["params"]["reason"], "operationUpdateFailed");
    assert_eq!(frames[2]["params"]["source"], "subversionr-daemon");
    assert!(
        frames[2]["params"]["timestamp"]
            .as_str()
            .is_some_and(|timestamp| !timestamp.is_empty())
    );
    assert_eq!(frames[3]["id"], 3);
    assert_eq!(frames[3]["result"]["accepted"], true);
}

#[test]
fn stdio_loop_routes_head_content_through_credential_broker() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":2,"method":"content/get","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"path":"tracked.txt","revision":"head"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"content-cred-1","result":{"requestId":"content-cred-1","operationId":"content-cred-1-operation","action":"provide","leaseId":"content-cred-1-lease","credential":{"username":"alice","secret":"secret"},"persistenceIntent":"secretStorage"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":3,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &ContentCredentialChallengeBridge,
    )
    .expect("stdio loop should bridge HEAD content credential challenges");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 4);
    assert_eq!(frames[0]["id"], 1);
    assert_credential_request_frame(&frames[1], "content-cred-1", "svn://example/content");
    assert_eq!(frames[2]["id"], 2);
    assert_eq!(frames[2]["result"]["revision"], "head");
    assert_eq!(frames[2]["result"]["contentBase64"], "aGVhZCBjb250ZW50Cg==");
    assert_eq!(frames[2]["result"]["source"], "libsvn-head");
    assert_eq!(frames[3]["id"], 3);
    assert_eq!(frames[3]["result"]["accepted"], true);
}

#[test]
fn stdio_loop_routes_history_log_through_credential_broker() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":2,"method":"history/log","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"path":"tracked.txt","startRevision":"head","endRevision":"r0","limit":10,"discoverChangedPaths":true,"strictNodeHistory":true,"includeMergedRevisions":false}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"history-log-cred-1","result":{"requestId":"history-log-cred-1","operationId":"history-log-cred-1-operation","action":"provide","leaseId":"history-log-cred-1-lease","credential":{"username":"alice","secret":"secret"},"persistenceIntent":"secretStorage"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":3,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &HistoryLogCredentialChallengeBridge,
    )
    .expect("stdio loop should bridge history log credential challenges");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 4);
    assert_eq!(frames[0]["id"], 1);
    assert_credential_request_frame(
        &frames[1],
        "history-log-cred-1",
        "svn://example/history-log",
    );
    assert_eq!(frames[2]["id"], 2);
    assert_eq!(frames[2]["result"]["path"], "tracked.txt");
    assert_eq!(frames[2]["result"]["source"], "libsvn-log");
    assert_eq!(frames[3]["id"], 3);
    assert_eq!(frames[3]["result"]["accepted"], true);
}

#[test]
fn stdio_loop_routes_history_blame_through_credential_broker() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":2,"method":"history/blame","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"path":"tracked.txt","pegRevision":"head","startRevision":"r0","endRevision":"head","lineStart":1,"lineLimit":10,"ignoreWhitespace":"none","ignoreEolStyle":false,"ignoreMimeType":false,"includeMergedRevisions":false}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"history-blame-cred-1","result":{"requestId":"history-blame-cred-1","operationId":"history-blame-cred-1-operation","action":"provide","leaseId":"history-blame-cred-1-lease","credential":{"username":"alice","secret":"secret"},"persistenceIntent":"secretStorage"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":3,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &HistoryBlameCredentialChallengeBridge,
    )
    .expect("stdio loop should bridge history blame credential challenges");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 4);
    assert_eq!(frames[0]["id"], 1);
    assert_credential_request_frame(
        &frames[1],
        "history-blame-cred-1",
        "svn://example/history-blame",
    );
    assert_eq!(frames[2]["id"], 2);
    assert_eq!(frames[2]["result"]["path"], "tracked.txt");
    assert_eq!(frames[2]["result"]["source"], "libsvn-blame");
    assert_eq!(frames[2]["result"]["resolvedEndRevision"], 2);
    assert_eq!(frames[3]["id"], 3);
    assert_eq!(frames[3]["result"]["accepted"], true);
}

#[test]
fn stdio_loop_routes_commit_operation_through_credential_broker() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":2,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"commit","options":{"version":1,"paths":["tracked.txt"],"message":"commit through broker","depth":"empty","changelists":[],"keepLocks":false,"keepChangelists":false,"commitAsOperations":false,"includeFileExternals":false,"includeDirExternals":false}}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"commit-cred-1","result":{"requestId":"commit-cred-1","operationId":"commit-cred-1-operation","action":"provide","leaseId":"commit-cred-1-lease","credential":{"username":"alice","secret":"secret"},"persistenceIntent":"secretStorage"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":3,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CommitCredentialChallengeBridge,
    )
    .expect("stdio loop should bridge commit credential challenges");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 4);
    assert_eq!(frames[0]["id"], 1);
    assert_credential_request_frame(&frames[1], "commit-cred-1", "svn://example/commit");
    assert_eq!(frames[2]["id"], 2);
    assert_eq!(frames[2]["result"]["kind"], "commit");
    assert_eq!(frames[2]["result"]["revision"], 10);
    assert_eq!(frames[3]["id"], 3);
    assert_eq!(frames[3]["result"]["accepted"], true);
}

#[test]
fn stdio_loop_rejects_credential_response_with_mismatched_body_request_id() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cred-expected","result":{"requestId":"cred-other","operationId":"cred-expected-operation","action":"provide","leaseId":"cred-other-lease","credential":{"username":"alice","secret":"secret"},"persistenceIntent":"secretStorage"}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CredentialBodyValidationBridge,
    )
    .expect("stdio loop should reject mismatched credential responses");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0]["id"], "cred-expected");
    assert_eq!(frames[0]["method"], "credentials/request");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(
        frames[1]["error"]["code"],
        "SUBVERSIONR_AUTH_RESPONSE_INVALID"
    );
    assert_eq!(frames[1]["error"]["args"]["method"], "credentials/request");
}

#[test]
fn stdio_loop_rejects_credential_response_with_mismatched_operation_id() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cred-expected","result":{"requestId":"cred-expected","operationId":"other-operation","action":"provide","leaseId":"cred-expected-lease","credential":{"username":"alice","secret":"secret"},"persistenceIntent":"secretStorage"}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CredentialBodyValidationBridge,
    )
    .expect("stdio loop should reject cross-operation credential responses");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 2);
    assert_credential_request_frame(&frames[0], "cred-expected", "svn://example");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(
        frames[1]["error"]["code"],
        "SUBVERSIONR_AUTH_RESPONSE_INVALID"
    );
    assert_eq!(frames[1]["error"]["args"]["method"], "credentials/request");
}

#[test]
fn stdio_loop_maps_credential_cancel_response_to_original_request_error() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cred-expected","result":{"requestId":"cred-expected","operationId":"cred-expected-operation","action":"cancel","error":{"code":"SUBVERSIONR_CREDENTIAL_CANCELLED","category":"auth","messageKey":"error.auth.credentialCancelled","args":{"realmHash":"abc123","secret":"leak","rawRealm":"svn://example"},"retryable":false}}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CredentialBodyValidationBridge,
    )
    .expect("stdio loop should map credential cancel to an auth error");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0]["id"], "cred-expected");
    assert_eq!(frames[0]["method"], "credentials/request");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(
        frames[1]["error"]["code"],
        "SUBVERSIONR_CREDENTIAL_CANCELLED"
    );
    assert_eq!(
        frames[1]["error"]["messageKey"],
        "error.auth.credentialCancelled"
    );
    assert_eq!(
        frames[1]["error"]["args"]["authorityHash"],
        "cd56ba62d5168a30ccdf4fff862338dbf8b7ba234023a8b54a023ed5cfa0331d"
    );
    assert_eq!(frames[1]["error"]["args"]["authKind"], "basic");
    assert_eq!(frames[1]["error"]["args"]["attempt"]["kind"], "initial");
    assert_eq!(frames[1]["error"]["args"]["origin"], "foreground");
    assert!(frames[1]["error"]["args"].get("secret").is_none());
    assert!(frames[1]["error"]["args"].get("rawRealm").is_none());
}

#[test]
fn stdio_loop_preserves_secret_invalid_credential_cancel_contract() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cred-expected","result":{"requestId":"cred-expected","operationId":"cred-expected-operation","action":"cancel","error":{"code":"SUBVERSIONR_CREDENTIAL_SECRET_INVALID","category":"auth","messageKey":"error.auth.credentialSecretInvalid","args":{"operationHash":"safe-hash","secret":"must-not-leak"},"retryable":false}}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CredentialBodyValidationBridge,
    )
    .expect("secret-invalid credential cancellation must remain serviceable");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 2);
    assert_eq!(
        frames[1]["error"]["code"],
        "SUBVERSIONR_CREDENTIAL_SECRET_INVALID"
    );
    assert_eq!(
        frames[1]["error"]["messageKey"],
        "error.auth.credentialSecretInvalid"
    );
    assert!(frames[1]["error"]["args"].get("secret").is_none());
    assert_eq!(frames[1]["error"]["args"]["authKind"], "basic");
}

#[test]
fn stdio_loop_rejects_credential_cancel_response_with_unexpected_error_contract() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cred-expected","result":{"requestId":"cred-expected","operationId":"cred-expected-operation","action":"cancel","error":{"code":"RPC_METHOD_NOT_FOUND","category":"unsupported","messageKey":"error.rpc.methodNotFound","args":{"method":"credentials/request","secret":"leak"},"retryable":false}}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CredentialBodyValidationBridge,
    )
    .expect("stdio loop should reject unexpected credential error contracts");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0]["id"], "cred-expected");
    assert_eq!(frames[0]["method"], "credentials/request");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(
        frames[1]["error"]["code"],
        "SUBVERSIONR_AUTH_RESPONSE_INVALID"
    );
    assert_eq!(frames[1]["error"]["args"]["method"], "credentials/request");
    assert!(frames[1]["error"]["args"].get("secret").is_none());
}

#[test]
fn stdio_loop_routes_non_interactive_credential_for_stored_secret_lookup() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cred-background","result":{"requestId":"cred-background","operationId":"cred-background-operation","action":"provide","leaseId":"cred-background-lease","credential":{"username":"alice","secret":"secret"},"persistenceIntent":"session"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":2,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &NonInteractiveCredentialBridge,
    )
    .expect("stdio loop should route non-interactive stored-secret lookup");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 3);
    assert_credential_request_frame(&frames[0], "cred-background", "svn://example");
    assert_eq!(frames[0]["params"]["interactive"], false);
    assert_eq!(frames[0]["params"]["persistenceAllowed"], false);
    assert_eq!(frames[0]["params"]["origin"], "background");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(frames[1]["result"]["repositoryId"], "repo-uuid:C:/wc");
    assert_eq!(frames[2]["result"]["accepted"], true);
}

#[test]
fn stdio_loop_cancels_pending_auth_on_matching_cancel_notification() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":"cred-expected"}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CredentialBodyValidationBridge,
    )
    .expect("stdio loop should cancel a pending auth request");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0]["id"], "cred-expected");
    assert_eq!(frames[0]["method"], "credentials/request");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(frames[1]["error"]["code"], "SUBVERSIONR_AUTH_CANCELLED");
    assert_eq!(frames[1]["error"]["messageKey"], "error.auth.cancelled");
    assert_eq!(frames[1]["error"]["args"]["method"], "credentials/request");
}

#[test]
fn stdio_loop_maps_auth_cancel_error_response_to_original_request_error() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cred-expected","error":{"code":-32800,"message":"Request cancelled"}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CredentialBodyValidationBridge,
    )
    .expect("stdio loop should map JSON-RPC auth cancellation errors");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0]["id"], "cred-expected");
    assert_eq!(frames[0]["method"], "credentials/request");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(frames[1]["error"]["code"], "SUBVERSIONR_AUTH_CANCELLED");
    assert_eq!(frames[1]["error"]["messageKey"], "error.auth.cancelled");
    assert_eq!(frames[1]["error"]["args"]["method"], "credentials/request");
}

#[test]
fn stdio_loop_rejects_malformed_auth_error_response() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cred-expected","error":{"code":"BAD"}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CredentialBodyValidationBridge,
    )
    .expect("stdio loop should reject malformed JSON-RPC auth error responses");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0]["id"], "cred-expected");
    assert_eq!(frames[0]["method"], "credentials/request");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(
        frames[1]["error"]["code"],
        "SUBVERSIONR_AUTH_RESPONSE_INVALID"
    );
}

#[test]
fn stdio_loop_preserves_empty_structured_secret_invalid_request_error() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cred-expected","error":{"code":"SUBVERSIONR_CREDENTIAL_SECRET_INVALID","category":"auth","messageKey":"error.auth.credentialSecretInvalid","args":{},"retryable":false,"diagnostics":null}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CredentialBodyValidationBridge,
    )
    .expect("empty structured secret-invalid errors must remain serviceable");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(
        frames[1]["error"]["code"],
        "SUBVERSIONR_CREDENTIAL_SECRET_INVALID"
    );
    assert_eq!(frames[1]["error"]["args"], serde_json::json!({}));
}

#[test]
fn stdio_loop_rejects_structured_credential_request_error_args() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cred-expected","error":{"code":"SUBVERSIONR_CREDENTIAL_SECRET_INVALID","category":"auth","messageKey":"error.auth.credentialSecretInvalid","args":{"realm":"must-not-leak"},"retryable":false,"diagnostics":null}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CredentialBodyValidationBridge,
    )
    .expect("structured request error args must fail closed without terminating stdio");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(
        frames[1]["error"]["code"],
        "SUBVERSIONR_AUTH_RESPONSE_INVALID"
    );
    assert!(frames[1]["error"]["args"].get("realm").is_none());
}

#[test]
fn stdio_loop_preserves_structured_credential_settlement_error_codes() {
    for (code, category, message_key, args) in [
        (
            "SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE",
            "lifecycle",
            "error.auth.credentialUntrustedWorkspace",
            serde_json::json!({
                "operationHash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                "leaseHash": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
            }),
        ),
        (
            "SUBVERSIONR_CREDENTIAL_TIMEOUT",
            "auth",
            "error.auth.credentialTimeout",
            serde_json::json!({
                "operationHash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                "leaseHash": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
                "outcome": "accepted"
            }),
        ),
        (
            "SUBVERSIONR_CREDENTIAL_LEASE_UNKNOWN",
            "auth",
            "error.auth.credentialLeaseUnknown",
            serde_json::json!({
                "operationHash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                "leaseHash": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
                "outcome": "accepted"
            }),
        ),
        (
            "SUBVERSIONR_CREDENTIAL_LEASE_FOREIGN",
            "auth",
            "error.auth.credentialLeaseForeign",
            serde_json::json!({
                "operationHash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                "leaseHash": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
                "outcome": "accepted"
            }),
        ),
        (
            "SUBVERSIONR_CREDENTIAL_LEASE_EXPIRED",
            "auth",
            "error.auth.credentialLeaseExpired",
            serde_json::json!({
                "operationHash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                "leaseHash": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
                "outcome": "accepted"
            }),
        ),
        (
            "SUBVERSIONR_CREDENTIAL_SETTLEMENT_CONFLICT",
            "auth",
            "error.auth.credentialSettlementConflict",
            serde_json::json!({
                "operationHash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                "leaseHash": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
                "outcome": "accepted"
            }),
        ),
    ] {
        let input = [
            frame(
                r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#,
            ),
            frame(
                &serde_json::json!({
                    "jsonrpc": "2.0",
                    "id": "settle-expected",
                    "error": {
                        "code": code,
                        "category": category,
                        "messageKey": message_key,
                        "args": args,
                        "retryable": false,
                        "diagnostics": null
                    }
                })
                .to_string(),
            ),
        ]
        .concat();
        let mut output = Vec::new();

        run_json_rpc_stdio(
            io::Cursor::new(input),
            &mut output,
            &CredentialSettlementValidationBridge,
        )
        .expect("structured settlement errors must remain serviceable");

        let frames = decode_frames(&output).expect("frames should be content-length encoded");
        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0]["method"], "credentials/settle");
        assert_eq!(frames[1]["error"]["code"], code);
        assert_eq!(frames[1]["error"]["category"], category);
        assert_eq!(frames[1]["error"]["messageKey"], message_key);
        assert_eq!(
            frames[1]["error"]["args"]["leaseHash"],
            "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        );
    }
}

#[test]
fn stdio_loop_rejects_unvalidated_structured_credential_settlement_args() {
    for (code, category, message_key, args) in [
        (
            "SUBVERSIONR_CREDENTIAL_LEASE_UNKNOWN",
            "auth",
            "error.auth.credentialLeaseUnknown",
            serde_json::json!({
                "operationHash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                "leaseHash": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
                "outcome": "accepted",
                "realm": "must-not-leak"
            }),
        ),
        (
            "SUBVERSIONR_CREDENTIAL_TIMEOUT",
            "auth",
            "error.auth.credentialTimeout",
            serde_json::json!({
                "operationHash": "UPPERCASE_OR_SHORT",
                "leaseHash": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
                "outcome": "accepted"
            }),
        ),
        (
            "SUBVERSIONR_CREDENTIAL_TIMEOUT",
            "auth",
            "error.auth.credentialTimeout",
            serde_json::json!({
                "operationHash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                "leaseHash": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
                "outcome": "unknown"
            }),
        ),
        (
            "SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE",
            "lifecycle",
            "error.auth.credentialUntrustedWorkspace",
            serde_json::json!({
                "operationHash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                "leaseHash": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
                "outcome": "accepted"
            }),
        ),
    ] {
        let input = [
            frame(
                r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#,
            ),
            frame(
                &serde_json::json!({
                    "jsonrpc": "2.0",
                    "id": "settle-expected",
                    "error": {
                        "code": code,
                        "category": category,
                        "messageKey": message_key,
                        "args": args,
                        "retryable": false,
                        "diagnostics": null
                    }
                })
                .to_string(),
            ),
        ]
        .concat();
        let mut output = Vec::new();

        run_json_rpc_stdio(
            io::Cursor::new(input),
            &mut output,
            &CredentialSettlementValidationBridge,
        )
        .expect("invalid settlement args must fail closed without terminating stdio");

        let frames = decode_frames(&output).expect("frames should be content-length encoded");
        assert_eq!(
            frames[1]["error"]["code"],
            "SUBVERSIONR_AUTH_RESPONSE_INVALID"
        );
        assert!(frames[1]["error"]["args"].get("realm").is_none());
    }
}

#[test]
fn stdio_loop_outer_cancellation_interrupts_synchronous_auth_wait() {
    let first =
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#);
    let cancellation = frame(r#"{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":1}}"#);
    let reader = DelayedSecondChunkReader::new(first, cancellation, Duration::from_millis(20));
    let mut output = Vec::new();
    let started = Instant::now();

    run_json_rpc_stdio(reader, &mut output, &CredentialBodyValidationBridge)
        .expect("outer cancellation must interrupt the synchronous auth wait");

    assert!(started.elapsed() < Duration::from_secs(1));
    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0]["method"], "credentials/request");
    assert_eq!(frames[1]["error"]["code"], "SUBVERSIONR_AUTH_CANCELLED");
}

#[test]
fn stdio_loop_rejects_cancel_request_with_envelope_id_while_auth_continues() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":77,"method":"$/cancelRequest","params":{"id":"cred-expected"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cred-expected","result":{"requestId":"cred-expected","operationId":"cred-expected-operation","action":"provide","leaseId":"cred-expected-lease","credential":{"username":"alice","secret":"secret"},"persistenceIntent":"session"}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CredentialBodyValidationBridge,
    )
    .expect("stdio loop should not treat request-shaped cancel as a notification");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 3);
    assert_eq!(frames[0]["id"], "cred-expected");
    assert_eq!(frames[0]["method"], "credentials/request");
    assert_eq!(frames[1]["id"], 77);
    assert_eq!(
        frames[1]["error"]["code"],
        "SUBVERSIONR_AUTH_REQUEST_PENDING"
    );
    assert_eq!(frames[2]["id"], 1);
    assert_eq!(frames[2]["result"]["repositoryId"], "repo-uuid:C:/wc");
}

#[test]
fn stdio_loop_ignores_nonmatching_cancel_notification_while_waiting_for_auth() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":"other-request"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cred-expected","result":{"requestId":"cred-expected","operationId":"cred-expected-operation","action":"provide","leaseId":"cred-expected-lease","credential":{"username":"alice","secret":"secret"},"persistenceIntent":"session"}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CredentialBodyValidationBridge,
    )
    .expect("stdio loop should ignore nonmatching cancel notifications");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0]["id"], "cred-expected");
    assert_eq!(frames[0]["method"], "credentials/request");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(frames[1]["result"]["repositoryId"], "repo-uuid:C:/wc");
}

#[test]
fn stdio_loop_rejects_unrelated_request_while_waiting_for_auth_and_continues() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":99,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","trustEpoch":1,"cacheRoot":"C:/Users/Alice/AppData/Roaming/Code/User/globalStorage/subversionr/cache"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cred-expected","result":{"requestId":"cred-expected","operationId":"cred-expected-operation","action":"provide","leaseId":"cred-expected-lease","credential":{"username":"alice","secret":"secret"},"persistenceIntent":"session"}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CredentialBodyValidationBridge,
    )
    .expect("stdio loop should reject unrelated requests while auth is pending");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 3);
    assert_eq!(frames[0]["id"], "cred-expected");
    assert_eq!(frames[0]["method"], "credentials/request");
    assert_eq!(frames[1]["id"], 99);
    assert_eq!(
        frames[1]["error"]["code"],
        "SUBVERSIONR_AUTH_REQUEST_PENDING"
    );
    assert_eq!(
        frames[1]["error"]["args"]["pendingMethod"],
        "credentials/request"
    );
    assert_eq!(frames[2]["id"], 1);
    assert_eq!(frames[2]["result"]["repositoryId"], "repo-uuid:C:/wc");
}

#[test]
fn stdio_loop_rejects_auth_request_flood_while_waiting_for_response() {
    let mut input = Vec::new();
    input.extend(frame(
        r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#,
    ));
    for id in 2..=66 {
        input.extend(frame(&format!(
            r#"{{"jsonrpc":"2.0","id":{id},"method":"initialize","params":{{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","trustEpoch":1,"cacheRoot":"C:/Users/Alice/AppData/Roaming/Code/User/globalStorage/subversionr/cache"}}}}"#
        )));
    }
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CredentialBodyValidationBridge,
    )
    .expect("stdio loop should reject auth wait request floods");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames[0]["id"], "cred-expected");
    assert_eq!(frames[0]["method"], "credentials/request");
    assert_eq!(
        frames.last().expect("original response should be present")["id"],
        1
    );
    assert_eq!(
        frames.last().expect("original response should be present")["error"]["code"],
        "SUBVERSIONR_AUTH_REQUEST_FLOOD"
    );
    assert_eq!(
        frames.last().expect("original response should be present")["error"]["messageKey"],
        "error.auth.requestFlood"
    );
    assert_eq!(
        frames.last().expect("original response should be present")["error"]["args"]["method"],
        "credentials/request"
    );
}

#[test]
fn stdio_loop_ignores_unrelated_notification_while_waiting_for_auth() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","method":"backend/log","params":{"level":"debug"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cred-expected","result":{"requestId":"cred-expected","operationId":"cred-expected-operation","action":"provide","leaseId":"cred-expected-lease","credential":{"username":"alice","secret":"secret"},"persistenceIntent":"session"}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CredentialBodyValidationBridge,
    )
    .expect("stdio loop should ignore unrelated notifications while auth is pending");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0]["id"], "cred-expected");
    assert_eq!(frames[0]["method"], "credentials/request");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(frames[1]["result"]["repositoryId"], "repo-uuid:C:/wc");
}

#[test]
fn stdio_loop_times_out_auth_request_before_waiting_for_response() {
    let input =
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#);
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CredentialTimeoutBridge,
    )
    .expect("stdio loop should map daemon-side auth request timeouts");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0]["id"], "cred-timeout");
    assert_eq!(frames[0]["method"], "credentials/request");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(frames[1]["error"]["code"], "SUBVERSIONR_AUTH_TIMEOUT");
    assert_eq!(frames[1]["error"]["messageKey"], "error.auth.timeout");
    assert_eq!(frames[1]["error"]["args"]["method"], "credentials/request");
}

#[test]
fn stdio_loop_times_out_idle_auth_wait_before_reader_eof() {
    let input =
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#);
    let reader = DelayedEofReader::new(input, Duration::from_millis(50));
    let mut output = Vec::new();

    run_json_rpc_stdio(reader, &mut output, &CredentialShortTimeoutBridge)
        .expect("stdio loop should map idle auth wait timeouts");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0]["id"], "cred-short-timeout");
    assert_eq!(frames[0]["method"], "credentials/request");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(frames[1]["error"]["code"], "SUBVERSIONR_AUTH_TIMEOUT");
    assert_eq!(frames[1]["error"]["messageKey"], "error.auth.timeout");
    assert_eq!(frames[1]["error"]["args"]["method"], "credentials/request");
}

#[test]
fn stdio_loop_times_out_idle_certificate_wait_before_reader_eof() {
    let input =
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#);
    let reader = DelayedEofReader::new(input, Duration::from_millis(50));
    let mut output = Vec::new();

    run_json_rpc_stdio(reader, &mut output, &CertificateShortTimeoutBridge)
        .expect("stdio loop should map idle certificate auth wait timeouts");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0]["id"], "cert-short-timeout");
    assert_eq!(frames[0]["method"], "certificate/request");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(frames[1]["error"]["code"], "SUBVERSIONR_AUTH_TIMEOUT");
    assert_eq!(frames[1]["error"]["messageKey"], "error.auth.timeout");
    assert_eq!(frames[1]["error"]["args"]["method"], "certificate/request");
}

#[test]
fn stdio_loop_drops_late_auth_response_after_timeout_and_continues() {
    let first =
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#);
    let late_and_next = [
        frame(r#"{"jsonrpc":"2.0","id":"cred-short-timeout","result":{"requestId":"cred-short-timeout","operationId":"cred-short-timeout-operation","action":"provide","leaseId":"cred-short-timeout-lease","credential":{"username":"alice","secret":"late-secret"},"persistenceIntent":"session"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":2,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let reader = DelayedSecondChunkReader::new(first, late_and_next, Duration::from_millis(50));
    let mut output = Vec::new();

    run_json_rpc_stdio(reader, &mut output, &CredentialShortTimeoutBridge)
        .expect("stdio loop should drop stale auth responses and continue");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 3);
    assert_eq!(frames[0]["id"], "cred-short-timeout");
    assert_eq!(frames[0]["method"], "credentials/request");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(frames[1]["error"]["code"], "SUBVERSIONR_AUTH_TIMEOUT");
    assert_eq!(frames[1]["error"]["args"]["method"], "credentials/request");
    assert_eq!(frames[2]["id"], 2);
    assert_eq!(frames[2]["result"]["accepted"], true);
    let output_text = String::from_utf8_lossy(&output);
    assert!(
        !output_text.contains("late-secret"),
        "stale auth response payload must not be echoed"
    );
}

#[test]
fn stdio_loop_drops_late_certificate_response_after_timeout_and_continues() {
    let first =
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#);
    let late_and_next = [
        frame(r#"{"jsonrpc":"2.0","id":"cert-short-timeout","result":{"requestId":"cert-short-timeout","action":"trust","trust":"once","fingerprint":"AA:BB:CC","fingerprintAlgorithm":"sha256-der"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":2,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let reader = DelayedSecondChunkReader::new(first, late_and_next, Duration::from_millis(50));
    let mut output = Vec::new();

    run_json_rpc_stdio(reader, &mut output, &CertificateShortTimeoutBridge)
        .expect("stdio loop should drop stale certificate responses and continue");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 3);
    assert_eq!(frames[0]["id"], "cert-short-timeout");
    assert_eq!(frames[0]["method"], "certificate/request");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(frames[1]["error"]["code"], "SUBVERSIONR_AUTH_TIMEOUT");
    assert_eq!(frames[1]["error"]["args"]["method"], "certificate/request");
    assert_eq!(frames[2]["id"], 2);
    assert_eq!(frames[2]["result"]["accepted"], true);
}

#[test]
fn stdio_loop_rejects_oversized_auth_response_frame_before_reading_payload() {
    let oversized_auth_response_header = b"Content-Length: 10485760\r\n\r\n";
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        oversized_auth_response_header.to_vec(),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CredentialBodyValidationBridge,
    )
    .expect("stdio loop should reject oversized auth response frames");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0]["id"], "cred-expected");
    assert_eq!(frames[0]["method"], "credentials/request");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(
        frames[1]["error"]["code"],
        "SUBVERSIONR_AUTH_RESPONSE_INVALID"
    );
    assert_eq!(frames[1]["error"]["args"]["method"], "credentials/request");
}

#[test]
fn stdio_loop_rejects_auth_response_with_invalid_jsonrpc_envelope() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"id":"cred-expected","result":{"requestId":"cred-expected","operationId":"cred-expected-operation","action":"provide","leaseId":"cred-expected-lease","credential":{"username":"alice","secret":"secret"},"persistenceIntent":"session"}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CredentialBodyValidationBridge,
    )
    .expect("stdio loop should reject auth responses with invalid JSON-RPC envelopes");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0]["id"], "cred-expected");
    assert_eq!(frames[0]["method"], "credentials/request");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(
        frames[1]["error"]["code"],
        "SUBVERSIONR_AUTH_RESPONSE_INVALID"
    );
}

#[test]
fn stdio_loop_rejects_auth_response_with_result_and_error() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cred-expected","result":{"requestId":"cred-expected","operationId":"cred-expected-operation","action":"provide","leaseId":"cred-expected-lease","credential":{"username":"alice","secret":"secret"},"persistenceIntent":"session"},"error":{"code":"BAD","message":"bad"}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CredentialBodyValidationBridge,
    )
    .expect("stdio loop should reject auth responses with ambiguous result and error fields");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0]["id"], "cred-expected");
    assert_eq!(frames[0]["method"], "credentials/request");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(
        frames[1]["error"]["code"],
        "SUBVERSIONR_AUTH_RESPONSE_INVALID"
    );
}

#[test]
fn stdio_loop_reports_auth_unavailable_on_eof_inside_auth_response_frame() {
    let partial_auth_response =
        "Content-Length: 128\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":\"cred-expected\"";
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        partial_auth_response.as_bytes().to_vec(),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CredentialBodyValidationBridge,
    )
    .expect("stdio loop should report unavailable auth responses on EOF");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0]["id"], "cred-expected");
    assert_eq!(frames[0]["method"], "credentials/request");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(
        frames[1]["error"]["code"],
        "SUBVERSIONR_AUTH_RESPONSE_UNAVAILABLE"
    );
}

#[test]
fn stdio_loop_rejects_non_interactive_certificate_without_prompting() {
    let input =
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#);
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &NonInteractiveCertificateBridge,
    )
    .expect("stdio loop should fail non-interactive certificate requests without prompting");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0]["id"], 1);
    assert_eq!(
        frames[0]["error"]["code"],
        "SUBVERSIONR_CERTIFICATE_NON_INTERACTIVE"
    );
    assert_eq!(
        frames[0]["error"]["messageKey"],
        "error.auth.certificateNonInteractive"
    );
    assert_eq!(frames[0]["error"]["args"]["method"], "certificate/request");
    assert!(frames[0]["method"].is_null());
}

#[test]
fn stdio_loop_maps_certificate_reject_response_to_original_request_error() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cert-expected","result":{"requestId":"cert-expected","action":"reject","error":{"code":"SUBVERSIONR_CERTIFICATE_REJECTED","category":"auth","messageKey":"error.auth.certificateRejected","args":{"fingerprint":"DD:EE:FF","fingerprintAlgorithm":"sha1","secret":"leak"},"retryable":false}}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CertificateBodyValidationBridge,
    )
    .expect("stdio loop should map certificate reject to an auth error");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0]["id"], "cert-expected");
    assert_eq!(frames[0]["method"], "certificate/request");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(
        frames[1]["error"]["code"],
        "SUBVERSIONR_CERTIFICATE_REJECTED"
    );
    assert_eq!(
        frames[1]["error"]["messageKey"],
        "error.auth.certificateRejected"
    );
    assert_eq!(
        frames[1]["error"]["args"]["realmHash"],
        "8e0a94c10101998df9239e44e6fbceb402c5d50f4cd8237321de503a71e51358"
    );
    assert_eq!(frames[1]["error"]["args"]["fingerprint"], "AA:BB:CC");
    assert_eq!(
        frames[1]["error"]["args"]["fingerprintAlgorithm"],
        "sha256-der"
    );
    assert_eq!(frames[1]["error"]["args"]["failureCount"], 1);
    assert_eq!(frames[1]["error"]["args"]["origin"], "foreground");
    assert!(frames[1]["error"]["args"].get("secret").is_none());
}

#[test]
fn stdio_loop_rejects_certificate_reject_response_with_unexpected_error_contract() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cert-expected","result":{"requestId":"cert-expected","action":"reject","error":{"code":"SUBVERSIONR_CREDENTIAL_CANCELLED","category":"auth","messageKey":"error.auth.credentialCancelled","args":{"secret":"leak"},"retryable":false}}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CertificateBodyValidationBridge,
    )
    .expect("stdio loop should reject unexpected certificate error contracts");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0]["id"], "cert-expected");
    assert_eq!(frames[0]["method"], "certificate/request");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(
        frames[1]["error"]["code"],
        "SUBVERSIONR_AUTH_RESPONSE_INVALID"
    );
    assert_eq!(frames[1]["error"]["args"]["method"], "certificate/request");
    assert!(frames[1]["error"]["args"].get("secret").is_none());
}

#[test]
fn stdio_loop_rejects_certificate_response_with_mismatched_fingerprint() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cert-expected","result":{"requestId":"cert-expected","action":"trust","trust":"once","fingerprint":"DD:EE:FF","fingerprintAlgorithm":"sha256-der"}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CertificateBodyValidationBridge,
    )
    .expect("stdio loop should reject certificate responses with the wrong fingerprint");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0]["id"], "cert-expected");
    assert_eq!(frames[0]["method"], "certificate/request");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(
        frames[1]["error"]["code"],
        "SUBVERSIONR_AUTH_RESPONSE_INVALID"
    );
    assert_eq!(frames[1]["error"]["args"]["method"], "certificate/request");
}

#[test]
fn stdio_loop_rejects_certificate_response_with_mismatched_fingerprint_algorithm() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cert-expected","result":{"requestId":"cert-expected","action":"trust","trust":"once","fingerprint":"AA:BB:CC","fingerprintAlgorithm":"sha1"}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CertificateBodyValidationBridge,
    )
    .expect("stdio loop should reject certificate responses with the wrong fingerprint algorithm");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0]["id"], "cert-expected");
    assert_eq!(frames[0]["method"], "certificate/request");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(
        frames[1]["error"]["code"],
        "SUBVERSIONR_AUTH_RESPONSE_INVALID"
    );
    assert_eq!(frames[1]["error"]["args"]["method"], "certificate/request");
}

#[test]
fn stdio_loop_sends_certificate_request_and_waits_for_client_response() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cert-1","result":{"requestId":"cert-1","action":"trust","trust":"once","fingerprint":"AA:BB:CC","fingerprintAlgorithm":"sha256-der"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":2,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &CertificateChallengeBridge,
    )
    .expect("stdio loop should bridge certificate challenges");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 3);
    assert_eq!(frames[0]["id"], "cert-1");
    assert_eq!(frames[0]["method"], "certificate/request");
    assert_eq!(frames[0]["params"]["host"], "svn.example.com");
    assert_eq!(frames[0]["params"]["fingerprintAlgorithm"], "sha256-der");
    assert_eq!(frames[0]["params"]["failures"][0], "unknownCa");
    assert_eq!(frames[1]["id"], 1);
    assert_eq!(frames[1]["result"]["repositoryId"], "repo-uuid:C:/wc");
    assert_eq!(frames[2]["id"], 2);
    assert_eq!(frames[2]["result"]["accepted"], true);
}

#[test]
fn stdio_loop_keeps_repository_session_between_framed_requests() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":2,"method":"status/getSnapshot","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#),
        frame(r#"{"jsonrpc":"2.0","id":3,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(io::Cursor::new(input), &mut output, &FakeBridge)
        .expect("stdio loop should keep state across frames");

    let responses = decode_frames(&output).expect("responses should be content-length framed");
    assert_eq!(responses.len(), 3);
    assert_eq!(responses[0]["result"]["repositoryId"], "repo-uuid:C:/wc");
    assert_eq!(responses[0]["result"]["epoch"], 1);
    assert_eq!(responses[1]["result"]["repositoryId"], "repo-uuid:C:/wc");
    assert_eq!(responses[1]["result"]["epoch"], 1);
    assert_eq!(responses[1]["result"]["generation"], 1);
    assert_eq!(
        responses[1]["result"]["localEntries"][0]["path"],
        "tracked.txt"
    );
    assert_eq!(
        responses[1]["result"]["remoteEntries"]
            .as_array()
            .expect("remote entries should be an array")
            .len(),
        0
    );
    assert_eq!(responses[2]["result"]["accepted"], true);
}

#[derive(Debug, Default)]
struct DelayedRemoteWorker {
    executions: AtomicUsize,
    disconnects: AtomicUsize,
}

#[derive(Debug, Default)]
struct AuthWaitingRemoteWorker {
    started: AtomicBool,
    auth_wait_cancelled: AtomicBool,
}

impl RemoteWorkerSupervisor for AuthWaitingRemoteWorker {
    fn execute(
        &self,
        envelope: &RemoteOperationEnvelope,
        _plan: RemoteConfigPlan,
        _lane_key: &str,
        effect: RemoteOperationEffect,
        _cancellation: &dyn BridgeCancellationToken,
        auth: &mut dyn AuthRequestBroker,
        _bridge: &dyn BridgeApi,
        _deadline: Instant,
    ) -> RemoteWorkerSettlement {
        self.started.store(true, Ordering::SeqCst);
        let result = (|| {
            let mut request = credential_request(
                "worker-auth-wait",
                "private worker auth wait",
                true,
                true,
                RemoteOperationIntent::Foreground,
                300_000,
            );
            request.operation_id = envelope.operation_id.clone();
            auth.request_credential(request)?;
            Ok(())
        })();
        worker_settlement(effect, result, true, true)
    }

    fn terminate_active(&self) -> Result<(), BridgeFailure> {
        self.auth_wait_cancelled.store(true, Ordering::SeqCst);
        Ok(())
    }

    fn update_workspace_trust(&self, trusted: bool) -> Result<(), BridgeFailure> {
        if !trusted {
            self.auth_wait_cancelled.store(true, Ordering::SeqCst);
        }
        Ok(())
    }

    fn disconnect(&self) -> Result<(), BridgeFailure> {
        self.auth_wait_cancelled.store(true, Ordering::SeqCst);
        Ok(())
    }

    fn capability_available(&self) -> bool {
        true
    }

    fn auth_wait_cancelled(&self) -> bool {
        self.auth_wait_cancelled.load(Ordering::SeqCst)
    }
}

#[derive(Debug, Default)]
struct SettlementErrorRemoteWorker;

impl RemoteWorkerSupervisor for SettlementErrorRemoteWorker {
    fn execute(
        &self,
        envelope: &RemoteOperationEnvelope,
        _plan: RemoteConfigPlan,
        _lane_key: &str,
        effect: RemoteOperationEffect,
        _cancellation: &dyn BridgeCancellationToken,
        auth: &mut dyn AuthRequestBroker,
        _bridge: &dyn BridgeApi,
        _deadline: Instant,
    ) -> RemoteWorkerSettlement {
        let failure = auth
            .settle_credential(credential_settlement_request(
                &envelope.operation_id,
                30_000,
            ))
            .expect_err("settlement error worker fixture must not succeed");
        worker_settlement(effect, Err(failure), true, true)
    }

    fn terminate_active(&self) -> Result<(), BridgeFailure> {
        Ok(())
    }

    fn disconnect(&self) -> Result<(), BridgeFailure> {
        Ok(())
    }

    fn capability_available(&self) -> bool {
        true
    }
}

impl RemoteWorkerSupervisor for DelayedRemoteWorker {
    fn execute(
        &self,
        _envelope: &RemoteOperationEnvelope,
        _plan: RemoteConfigPlan,
        _lane_key: &str,
        effect: RemoteOperationEffect,
        cancellation: &dyn BridgeCancellationToken,
        _auth: &mut dyn AuthRequestBroker,
        _bridge: &dyn BridgeApi,
        deadline: Instant,
    ) -> RemoteWorkerSettlement {
        self.executions.fetch_add(1, Ordering::SeqCst);
        let finish = Instant::now() + Duration::from_millis(80);
        while Instant::now() < finish {
            if cancellation.is_cancelled() || Instant::now() >= deadline {
                return worker_settlement(
                    effect,
                    Err(remote_worker_test_failure(
                        "SUBVERSIONR_REMOTE_WORKER_CANCELLED",
                    )),
                    true,
                    true,
                );
            }
            thread::sleep(Duration::from_millis(2));
        }
        worker_settlement(effect, Ok(()), true, true)
    }

    fn terminate_active(&self) -> Result<(), BridgeFailure> {
        Ok(())
    }

    fn disconnect(&self) -> Result<(), BridgeFailure> {
        self.disconnects.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }

    fn capability_available(&self) -> bool {
        true
    }
}

#[derive(Debug, Default)]
struct DisconnectBlockingRemoteWorker {
    started: AtomicBool,
    disconnected: AtomicBool,
}

#[derive(Debug, Default)]
struct RecoveryBlockedRemoteWorker;

#[derive(Debug, Default)]
struct MutationFailureRemoteWorker;

impl RemoteWorkerSupervisor for MutationFailureRemoteWorker {
    fn execute(
        &self,
        _envelope: &RemoteOperationEnvelope,
        _plan: RemoteConfigPlan,
        _lane_key: &str,
        effect: RemoteOperationEffect,
        _cancellation: &dyn BridgeCancellationToken,
        _auth: &mut dyn AuthRequestBroker,
        _bridge: &dyn BridgeApi,
        _deadline: Instant,
    ) -> RemoteWorkerSettlement {
        worker_settlement(
            effect,
            Err(remote_worker_test_failure(
                "SUBVERSIONR_REMOTE_WORKER_CANCELLED",
            )),
            true,
            true,
        )
    }

    fn terminate_active(&self) -> Result<(), BridgeFailure> {
        Ok(())
    }

    fn disconnect(&self) -> Result<(), BridgeFailure> {
        Ok(())
    }

    fn capability_available(&self) -> bool {
        true
    }
}

impl RemoteWorkerSupervisor for RecoveryBlockedRemoteWorker {
    fn execute(
        &self,
        _envelope: &RemoteOperationEnvelope,
        _plan: RemoteConfigPlan,
        _lane_key: &str,
        effect: RemoteOperationEffect,
        _cancellation: &dyn BridgeCancellationToken,
        _auth: &mut dyn AuthRequestBroker,
        _bridge: &dyn BridgeApi,
        _deadline: Instant,
    ) -> RemoteWorkerSettlement {
        worker_settlement(
            effect,
            Err(remote_worker_test_failure(
                "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
            )),
            true,
            false,
        )
    }

    fn terminate_active(&self) -> Result<(), BridgeFailure> {
        Ok(())
    }

    fn disconnect(&self) -> Result<(), BridgeFailure> {
        Ok(())
    }

    fn capability_available(&self) -> bool {
        true
    }
}

impl RemoteWorkerSupervisor for DisconnectBlockingRemoteWorker {
    fn execute(
        &self,
        _envelope: &RemoteOperationEnvelope,
        _plan: RemoteConfigPlan,
        _lane_key: &str,
        effect: RemoteOperationEffect,
        _cancellation: &dyn BridgeCancellationToken,
        _auth: &mut dyn AuthRequestBroker,
        _bridge: &dyn BridgeApi,
        _deadline: Instant,
    ) -> RemoteWorkerSettlement {
        self.started.store(true, Ordering::SeqCst);
        while !self.disconnected.load(Ordering::SeqCst) {
            thread::sleep(Duration::from_millis(2));
        }
        worker_settlement(
            effect,
            Err(remote_worker_test_failure(
                "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED",
            )),
            true,
            true,
        )
    }

    fn terminate_active(&self) -> Result<(), BridgeFailure> {
        self.disconnected.store(true, Ordering::SeqCst);
        Ok(())
    }

    fn disconnect(&self) -> Result<(), BridgeFailure> {
        self.disconnected.store(true, Ordering::SeqCst);
        Ok(())
    }

    fn capability_available(&self) -> bool {
        true
    }
}

#[test]
fn stdio_remote_worker_keeps_diagnostics_and_other_working_copies_responsive() {
    let worker = Arc::new(DelayedRemoteWorker::default());
    let initialize = frame(
        r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","trustEpoch":1,"cacheRoot":"C:/cache"}}"#,
    );
    let checkout =
        remote_checkout_frame(2, "01234567-89ab-cdef-0123-456789abcdef", "C:/checkout/a");
    let diagnostics = frame(r#"{"jsonrpc":"2.0","id":3,"method":"diagnostics/get","params":{}}"#);
    let same_lane =
        remote_checkout_frame(4, "11234567-89ab-cdef-0123-456789abcdef", "C:/checkout/a");
    let child_path = frame(
        r#"{"jsonrpc":"2.0","id":6,"method":"repository/open","params":{"path":"C:/checkout/a/child"}}"#,
    );
    let discovery_ancestor = frame(
        r#"{"jsonrpc":"2.0","id":7,"method":"repository/discover","params":{"workspaceRoots":["C:/checkout"],"discoverNested":false,"discoveryDepth":0,"discoveryIgnore":[],"ignoredRoots":[],"externalsMode":"off"}}"#,
    );
    let repository_b =
        frame(r#"{"jsonrpc":"2.0","id":5,"method":"repository/open","params":{"path":"C:/wc-b"}}"#);
    let first = [
        initialize,
        checkout,
        diagnostics,
        same_lane,
        child_path,
        discovery_ancestor,
        repository_b,
    ]
    .concat();
    let shutdown = frame(r#"{"jsonrpc":"2.0","id":8,"method":"shutdown","params":{}}"#);
    let reader = DelayedSecondChunkReader::new(first, shutdown, Duration::from_millis(500));
    let mut output = Vec::new();

    run_json_rpc_stdio_with_remote_worker(reader, &mut output, &FakeBridge, worker.clone())
        .expect("stdio coordinator should remain responsive while a remote worker runs");

    let responses = decode_frames(&output).expect("responses should be content-length framed");
    let ids = responses
        .iter()
        .map(|value| value["id"].as_u64().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(ids, vec![1, 3, 4, 6, 7, 5, 2, 8]);
    assert_eq!(
        responses[0]["result"]["capabilities"]["remoteWorkerIsolation"],
        true
    );
    assert_eq!(responses[1]["result"]["protocol"]["minor"], 35);
    assert_eq!(
        responses[2]["error"]["code"],
        "SUBVERSIONR_REMOTE_NATIVE_LANE_BUSY"
    );
    assert_eq!(
        responses[3]["error"]["code"],
        "SUBVERSIONR_REMOTE_NATIVE_LANE_BUSY"
    );
    assert_eq!(
        responses[4]["error"]["code"],
        "SUBVERSIONR_REMOTE_NATIVE_LANE_BUSY"
    );
    assert_eq!(responses[5]["result"]["repositoryId"], "repo-uuid:C:/wc-b");
    assert_eq!(
        responses[6]["error"]["code"],
        "SUBVERSIONR_REMOTE_TRANSPORT_UNSUPPORTED"
    );
    assert_eq!(responses[7]["result"]["accepted"], true);
    assert_eq!(worker.executions.load(Ordering::SeqCst), 1);
}

#[test]
fn stdio_eof_disconnects_an_active_remote_worker_before_returning() {
    let worker = Arc::new(DisconnectBlockingRemoteWorker::default());
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","trustEpoch":1,"cacheRoot":"C:/cache"}}"#),
        remote_checkout_frame(2, "21234567-89ab-cdef-0123-456789abcdef", "C:/checkout/eof"),
    ]
    .concat();
    let reader = DelayedEofReader::new(input, Duration::from_millis(60));
    let mut output = Vec::new();

    run_json_rpc_stdio_with_remote_worker(reader, &mut output, &FakeBridge, worker.clone())
        .expect("EOF should terminate and settle the active remote worker");

    assert!(worker.started.load(Ordering::SeqCst));
    assert!(worker.disconnected.load(Ordering::SeqCst));
    let responses = decode_frames(&output).expect("initialize response should remain framed");
    assert_eq!(responses.len(), 1);
    assert_eq!(responses[0]["id"], 1);
}

#[test]
fn stdio_remote_worker_auth_wait_is_interrupted_by_outer_cancellation() {
    let worker = Arc::new(AuthWaitingRemoteWorker::default());
    let operation_id = "41234567-89ab-4def-8123-456789abcdef";
    let stage = Arc::new(AtomicUsize::new(0));
    let reader = BrokerRoundTripReader::new(
        vec![
            [
                frame(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","trustEpoch":1,"cacheRoot":"C:/cache"}}"#),
                remote_checkout_frame(2, operation_id, "C:/checkout/cancel-auth"),
            ]
            .concat(),
            frame(r#"{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":2}}"#),
            frame(r#"{"jsonrpc":"2.0","id":3,"method":"shutdown","params":{}}"#),
        ],
        vec![1, 3],
        stage.clone(),
    );
    let mut output = BrokerRoundTripWriter::new(stage);
    let started = Instant::now();

    run_json_rpc_stdio_with_remote_worker(reader, &mut output, &FakeBridge, worker.clone())
        .expect("outer cancellation must interrupt a worker broker wait");

    assert!(started.elapsed() < Duration::from_secs(1));
    assert!(worker.started.load(Ordering::SeqCst));
    let responses = decode_frames(output.as_bytes()).expect("responses should remain framed");
    let checkout = responses
        .iter()
        .find(|response| response["id"] == 2)
        .expect("cancelled checkout response must be emitted");
    assert_eq!(
        checkout["error"]["code"],
        "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED"
    );
}

#[test]
fn stdio_remote_worker_auth_wait_is_interrupted_by_trust_revoke() {
    let worker = Arc::new(AuthWaitingRemoteWorker::default());
    let operation_id = "51234567-89ab-4def-8123-456789abcdef";
    let stage = Arc::new(AtomicUsize::new(0));
    let reader = BrokerRoundTripReader::new(
        vec![
            [
                frame(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","trustEpoch":1,"cacheRoot":"C:/cache"}}"#),
                remote_checkout_frame(2, operation_id, "C:/checkout/revoke-auth"),
            ]
            .concat(),
            frame(r#"{"jsonrpc":"2.0","id":3,"method":"workspaceTrust/update","params":{"trusted":false,"trustEpoch":2}}"#),
            frame(r#"{"jsonrpc":"2.0","id":4,"method":"shutdown","params":{}}"#),
        ],
        vec![1, 3],
        stage.clone(),
    );
    let mut output = BrokerRoundTripWriter::new(stage);
    let started = Instant::now();

    run_json_rpc_stdio_with_remote_worker(reader, &mut output, &FakeBridge, worker.clone())
        .expect("trust revoke must interrupt a worker broker wait");

    assert!(started.elapsed() < Duration::from_secs(1));
    assert!(worker.auth_wait_cancelled.load(Ordering::SeqCst));
    let responses = decode_frames(output.as_bytes()).expect("responses should remain framed");
    assert!(responses.iter().any(|response| {
        response["id"] == 2 && response["error"]["code"] == "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED"
    }));
    assert!(responses.iter().any(|response| {
        response["id"] == 3 && response["result"]["acknowledgedTrustEpoch"] == 2
    }));
}

#[test]
fn stdio_remote_worker_auth_wait_obeys_the_operation_deadline() {
    let worker = Arc::new(AuthWaitingRemoteWorker::default());
    let stage = Arc::new(AtomicUsize::new(0));
    let reader = BrokerRoundTripReader::new(
        vec![
            [
                frame(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","trustEpoch":1,"cacheRoot":"C:/cache"}}"#),
                remote_checkout_frame_with_timeout(
                    2,
                    "61234567-89ab-4def-8123-456789abcdef",
                    "C:/checkout/deadline-auth",
                    1_000,
                ),
            ]
            .concat(),
            frame(r#"{"jsonrpc":"2.0","id":3,"method":"shutdown","params":{}}"#),
        ],
        vec![3],
        stage.clone(),
    );
    let mut output = BrokerRoundTripWriter::new(stage);

    run_json_rpc_stdio_with_remote_worker(reader, &mut output, &FakeBridge, worker)
        .expect("operation deadline must interrupt a longer credential request timeout");

    let responses = decode_frames(output.as_bytes()).expect("responses should remain framed");
    assert!(responses.iter().any(|response| {
        response["id"] == "worker-auth-wait"
            && response["method"] == "credentials/request"
            && response["params"]["requestId"] == "worker-auth-wait"
            && response["params"]["operationId"] == "61234567-89ab-4def-8123-456789abcdef"
    }));
    assert!(responses.iter().any(|response| {
        response["id"] == 2 && response["error"]["code"] == "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED"
    }));
}

#[test]
fn stdio_eof_interrupts_a_remote_worker_auth_wait() {
    let worker = Arc::new(AuthWaitingRemoteWorker::default());
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","trustEpoch":1,"cacheRoot":"C:/cache"}}"#),
        remote_checkout_frame(
            2,
            "81234567-89ab-4def-8123-456789abcdef",
            "C:/checkout/eof-auth",
        ),
    ]
    .concat();
    let reader = DelayedEofReader::new(input, Duration::from_millis(40));
    let mut output = Vec::new();
    let started = Instant::now();

    run_json_rpc_stdio_with_remote_worker(reader, &mut output, &FakeBridge, worker.clone())
        .expect("EOF must interrupt the pending remote worker broker call");

    assert!(started.elapsed() < Duration::from_secs(1));
    assert!(worker.started.load(Ordering::SeqCst));
    assert!(worker.auth_wait_cancelled.load(Ordering::SeqCst));
}

#[test]
fn stdio_remote_worker_preserves_structured_settlement_error_over_private_broker() {
    for (code, category, message_key, args) in [
        (
            "SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE",
            "lifecycle",
            "error.auth.credentialUntrustedWorkspace",
            serde_json::json!({
                "operationHash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                "leaseHash": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
            }),
        ),
        (
            "SUBVERSIONR_CREDENTIAL_TIMEOUT",
            "auth",
            "error.auth.credentialTimeout",
            serde_json::json!({
                "operationHash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                "leaseHash": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
                "outcome": "accepted"
            }),
        ),
    ] {
        let operation_id = "71234567-89ab-4def-8123-456789abcdef";
        let stage = Arc::new(AtomicUsize::new(0));
        let reader = BrokerRoundTripReader::new(
            vec![
                [
                    frame(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","trustEpoch":1,"cacheRoot":"C:/cache"}}"#),
                    frame(r#"{"jsonrpc":"2.0","id":10,"method":"repository/open","params":{"path":"C:/wc-remote-recovery"}}"#),
                    remote_status_frame(2, operation_id, 30_000),
                ]
                .concat(),
                frame(
                    &serde_json::json!({
                        "jsonrpc": "2.0",
                        "id": "settle-expected",
                        "error": {
                            "code": code,
                            "category": category,
                            "messageKey": message_key,
                            "args": args,
                            "retryable": false,
                            "diagnostics": null
                        }
                    })
                    .to_string(),
                ),
                frame(r#"{"jsonrpc":"2.0","id":3,"method":"shutdown","params":{}}"#),
            ],
            vec![1, 3],
            Arc::clone(&stage),
        );
        let mut output = BrokerRoundTripWriter::new(Arc::clone(&stage));

        run_json_rpc_stdio_with_remote_worker(
            reader,
            &mut output,
            &FakeBridge,
            Arc::new(SettlementErrorRemoteWorker),
        )
        .expect("private worker settlement failure must remain serviceable");

        let responses = decode_frames(output.as_bytes()).expect("responses should remain framed");
        assert!(
            responses.iter().any(|response| {
                response["id"] == 2
                    && response["error"]["code"] == code
                    && response["error"]["category"] == category
                    && response["error"]["messageKey"] == message_key
                    && response["error"]["args"]["leaseHash"]
                        == "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
            }),
            "private settlement response did not preserve {code}: {responses:#?}"
        );
    }
}

#[test]
fn stdio_remote_worker_cancel_retires_late_auth_response_and_keeps_serviceable() {
    let operation_id = "91234567-89ab-4def-8123-456789abcdef";
    let stage = Arc::new(AtomicUsize::new(0));
    let worker = Arc::new(AuthWaitingRemoteWorker::default());
    let reader = BrokerRoundTripReader::new(
        vec![
            [
                frame(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","trustEpoch":1,"cacheRoot":"C:/cache"}}"#),
                remote_checkout_frame(2, operation_id, "C:/checkout/late-auth-cancel"),
            ]
            .concat(),
            frame(r#"{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":2}}"#),
            [
                frame(r#"{"jsonrpc":"2.0","id":"worker-auth-wait","result":{}}"#),
                frame(r#"{"jsonrpc":"2.0","id":3,"method":"diagnostics/get","params":{}}"#),
                frame(r#"{"jsonrpc":"2.0","id":4,"method":"shutdown","params":{}}"#),
            ]
            .concat(),
        ],
        vec![1, 3],
        Arc::clone(&stage),
    );
    let mut output = BrokerRoundTripWriter::new(stage);

    run_json_rpc_stdio_with_remote_worker(reader, &mut output, &FakeBridge, worker)
        .expect("late auth response after remote cancellation must be retired");

    assert_late_remote_auth_response_kept_serviceable(output.as_bytes());
}

#[test]
fn stdio_remote_worker_failure_retires_late_auth_response_and_keeps_serviceable() {
    let operation_id = "a1234567-89ab-4def-8123-456789abcdef";
    let stage = Arc::new(AtomicUsize::new(0));
    let worker = Arc::new(AuthWaitingRemoteWorker::default());
    let trigger_stage = Arc::clone(&stage);
    let trigger_worker = Arc::clone(&worker);
    let trigger = thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(1);
        while trigger_stage.load(Ordering::SeqCst) < 1 {
            assert!(
                Instant::now() < deadline,
                "remote auth request was not emitted before worker failure"
            );
            thread::yield_now();
        }
        trigger_worker
            .auth_wait_cancelled
            .store(true, Ordering::SeqCst);
    });
    let reader = BrokerRoundTripReader::new(
        vec![
            [
                frame(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","trustEpoch":1,"cacheRoot":"C:/cache"}}"#),
                remote_checkout_frame(2, operation_id, "C:/checkout/late-auth-failure"),
            ]
            .concat(),
            [
                frame(r#"{"jsonrpc":"2.0","id":"worker-auth-wait","result":{}}"#),
                frame(r#"{"jsonrpc":"2.0","id":3,"method":"diagnostics/get","params":{}}"#),
                frame(r#"{"jsonrpc":"2.0","id":4,"method":"shutdown","params":{}}"#),
            ]
            .concat(),
        ],
        vec![3],
        Arc::clone(&stage),
    );
    let mut output = BrokerRoundTripWriter::new(stage);

    run_json_rpc_stdio_with_remote_worker(reader, &mut output, &FakeBridge, worker)
        .expect("late auth response after remote worker failure must be retired");
    trigger
        .join()
        .expect("worker failure trigger must complete");

    assert_late_remote_auth_response_kept_serviceable(output.as_bytes());
}

fn assert_late_remote_auth_response_kept_serviceable(output: &[u8]) {
    let responses = decode_frames(output).expect("responses should remain framed");
    assert!(responses.iter().any(|response| {
        response["id"] == 2 && response["error"]["code"] == "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED"
    }));
    assert!(responses.iter().any(|response| {
        response["id"] == 3 && response["result"]["source"] == "subversionr-daemon"
    }));
    assert!(
        responses
            .iter()
            .any(|response| response["id"] == 4 && response["result"]["accepted"] == true)
    );
}

#[test]
fn stdio_recovery_blocked_lane_rejects_child_and_discovery_paths_but_keeps_diagnostics_live() {
    let worker = Arc::new(RecoveryBlockedRemoteWorker);
    let first = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","trustEpoch":1,"cacheRoot":"C:/cache"}}"#),
        remote_checkout_frame(2, "31234567-89ab-cdef-0123-456789abcdef", "C:/checkout/blocked"),
    ]
    .concat();
    let second = [
        frame(r#"{"jsonrpc":"2.0","id":3,"method":"repository/open","params":{"path":"C:/checkout/blocked/child"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":4,"method":"repository/discover","params":{"workspaceRoots":["C:/checkout"],"discoverNested":false,"discoveryDepth":0,"discoveryIgnore":[],"ignoredRoots":[],"externalsMode":"off"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":5,"method":"diagnostics/get","params":{}}"#),
        frame(r#"{"jsonrpc":"2.0","id":6,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let reader = DelayedSecondChunkReader::new(first, second, Duration::from_millis(100));
    let mut output = Vec::new();

    run_json_rpc_stdio_with_remote_worker(reader, &mut output, &FakeBridge, worker)
        .expect("blocked recovery lane must not stop unrelated diagnostics or shutdown");

    let responses = decode_frames(&output).expect("responses should remain framed");
    let ids = responses
        .iter()
        .map(|value| value["id"].as_u64().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(ids, vec![1, 2, 3, 4, 5, 6]);
    assert_eq!(
        responses[1]["error"]["code"],
        "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED"
    );
    assert_eq!(
        responses[2]["error"]["code"],
        "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED"
    );
    assert_eq!(
        responses[3]["error"]["code"],
        "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED"
    );
    assert_eq!(responses[4]["result"]["protocol"]["minor"], 35);
    assert_eq!(responses[5]["result"]["accepted"], true);
}

#[test]
fn stdio_mutation_failure_requires_fresh_recovery_and_safe_reconcile_before_release() {
    let origin_operation_id = "61234567-89ab-4def-8123-456789abcdef";
    let wrong_origin_operation_id = "41234567-89ab-4def-8123-456789abcdef";
    let mismatched_recovery_operation_id = "51234567-89ab-4def-8123-456789abcdef";
    let recovery_operation_id = "71234567-89ab-4def-8123-456789abcdef";
    let first = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","trustEpoch":1,"cacheRoot":"C:/cache"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":2,"method":"repository/open","params":{"path":"C:/wc-remote-recovery"}}"#),
        remote_update_frame(3, origin_operation_id, 50),
    ]
    .concat();
    let recovery_requests = [
        frame(
            &serde_json::json!({
                "jsonrpc": "2.0",
                "id": 4,
                "method": "remote/recoverWorkingCopy",
                "params": {
                    "repositoryId": "repo-uuid:C:/wc-remote-recovery",
                    "epoch": 1,
                    "originOperationId": wrong_origin_operation_id,
                    "operationId": mismatched_recovery_operation_id,
                    "timeoutMs": 30_000
                }
            })
            .to_string(),
        ),
        frame(
            &serde_json::json!({
                "jsonrpc": "2.0",
                "id": 5,
                "method": "remote/recoverWorkingCopy",
                "params": {
                    "repositoryId": "repo-uuid:C:/wc-remote-recovery",
                    "epoch": 1,
                    "originOperationId": origin_operation_id,
                    "operationId": origin_operation_id,
                    "timeoutMs": 30_000
                }
            })
            .to_string(),
        ),
        frame(
            &serde_json::json!({
                "jsonrpc": "2.0",
                "id": 6,
                "method": "remote/recoverWorkingCopy",
                "params": {
                    "repositoryId": "repo-uuid:C:/wc-remote-recovery",
                    "epoch": 1,
                    "originOperationId": origin_operation_id,
                    "operationId": recovery_operation_id,
                    "timeoutMs": 30_000
                }
            })
            .to_string(),
        ),
    ]
    .concat();
    let reader = DelayedChunkReader::new(
        vec![
            first,
            recovery_requests,
            frame(r#"{"jsonrpc":"2.0","id":7,"method":"shutdown","params":{}}"#),
        ],
        vec![Duration::from_millis(80), Duration::from_millis(40)],
    );
    let mut output = Vec::new();

    run_json_rpc_stdio_with_remote_worker(
        reader,
        &mut output,
        &FakeBridge,
        Arc::new(MutationFailureRemoteWorker),
    )
    .expect("mutation recovery workflow must remain serviceable");

    let frames = decode_frames(&output).expect("responses must be framed");
    let by_id = |id: u64| {
        frames
            .iter()
            .find(|frame| frame["id"].as_u64() == Some(id))
            .expect("expected response id")
    };
    assert_eq!(
        by_id(1)["result"]["capabilities"]["remoteConnectionState"],
        true
    );
    assert_eq!(
        by_id(3)["error"]["args"]["remoteFailure"]["reason"],
        "operationCancelled"
    );
    assert_eq!(
        by_id(4)["error"]["code"],
        "SUBVERSIONR_REMOTE_RECOVERY_ORIGIN_MISMATCH"
    );
    assert_eq!(by_id(5)["error"]["code"], "RPC_INVALID_PARAMS");
    assert_eq!(by_id(6)["result"]["outcome"], "safe");
    assert_eq!(by_id(6)["result"]["operationId"], recovery_operation_id);
    assert!(frames.iter().any(|frame| {
        frame["method"] == "remoteConnection/state"
            && frame["params"]["repositoryId"] == "repo-uuid:C:/wc-remote-recovery"
            && frame["params"]["state"]["kind"] == "checking"
            && frame["params"]["state"]["operationId"] == origin_operation_id
    }));
    let checking_index = frames
        .iter()
        .position(|frame| {
            frame["method"] == "remoteConnection/state"
                && frame["params"]["state"]["kind"] == "checking"
                && frame["params"]["state"]["operationId"] == origin_operation_id
        })
        .expect("checking notification");
    let mutation_response_index = frames
        .iter()
        .position(|frame| frame["id"] == 3)
        .expect("mutation response");
    let indeterminate_index = frames
        .iter()
        .position(|frame| {
            frame["method"] == "remoteConnection/state"
                && frame["params"]["state"]["kind"] == "indeterminate"
        })
        .expect("indeterminate notification");
    assert!(checking_index < mutation_response_index);
    assert!(mutation_response_index < indeterminate_index);
    assert!(frames.iter().any(|frame| {
        frame["method"] == "remoteConnection/state"
            && frame["params"]["state"]["kind"] == "indeterminate"
            && frame["params"]["state"]["recovery"] == "pending"
    }));
    assert!(frames.iter().any(|frame| {
        frame["method"] == "status/stale"
            && frame["params"]["reason"] == "remoteRecoverySafeRequiresFullReconcile"
    }));
}

#[test]
fn stdio_backend_reconnect_rebuilds_recovery_lane_before_full_reconcile() {
    let origin_operation_id = "b1234567-89ab-4def-8123-456789abcdef";
    let recovery_operation_id = "c1234567-89ab-4def-8123-456789abcdef";
    let recovery_input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","trustEpoch":1,"cacheRoot":"C:/cache"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":2,"method":"repository/open","params":{"path":"C:/wc-remote-recovery"}}"#),
        frame(
            &serde_json::json!({
                "jsonrpc": "2.0",
                "id": 3,
                "method": "remote/recoverWorkingCopy",
                "params": {
                    "repositoryId": "repo-uuid:C:/wc-remote-recovery",
                    "epoch": 1,
                    "originOperationId": origin_operation_id,
                    "operationId": recovery_operation_id,
                    "timeoutMs": 30_000
                }
            })
            .to_string(),
        ),
    ]
    .concat();
    let reader = DelayedSecondChunkReader::new(
        recovery_input,
        frame(r#"{"jsonrpc":"2.0","id":4,"method":"shutdown","params":{}}"#),
        Duration::from_millis(100),
    );
    let mut output = Vec::new();

    run_json_rpc_stdio_with_remote_worker(
        reader,
        &mut output,
        &FakeBridge,
        Arc::new(MutationFailureRemoteWorker),
    )
    .expect("a fresh daemon must conservatively re-drive recovery after reconnect");

    let frames = decode_frames(&output).expect("responses must remain framed");
    let recovery = frames
        .iter()
        .find(|frame| frame["id"] == 3)
        .expect("recovery response");
    assert_eq!(recovery["result"]["outcome"], "safe");
    assert_eq!(recovery["result"]["operationId"], recovery_operation_id);
    assert!(frames.iter().any(|frame| {
        frame["method"] == "status/stale"
            && frame["params"]["reason"] == "remoteRecoverySafeRequiresFullReconcile"
    }));
    assert!(frames.iter().any(|frame| {
        frame["method"] == "remoteConnection/state"
            && frame["params"]["state"]["kind"] == "unchecked"
    }));
}

#[test]
fn stdio_recovery_keeps_unrelated_requests_live_and_blocks_close_until_safe() {
    let path = "C:/wc-remote-recovery-blocking-serviceability";
    let repository_id = format!("repo-uuid:{path}");
    let origin_operation_id = "d1234567-89ab-4def-8123-456789abcdef";
    let recovery_operation_id = "e1234567-89ab-4def-8123-456789abcdef";
    let control = RecoveryTaskControl {
        started: Arc::new(AtomicBool::new(false)),
        release: Arc::new(AtomicBool::new(false)),
        cancelled: Arc::new(AtomicBool::new(false)),
    };
    recovery_task_controls()
        .lock()
        .expect("recovery task controls must not be poisoned")
        .insert(path.to_string(), control.clone());

    let first = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","trustEpoch":1,"cacheRoot":"C:/cache"}}"#),
        frame(&serde_json::json!({"jsonrpc":"2.0","id":2,"method":"repository/open","params":{"path":path}}).to_string()),
        remote_recovery_frame(3, &repository_id, origin_operation_id, recovery_operation_id, 30_000),
    ]
    .concat();
    let while_blocked = [
        frame(r#"{"jsonrpc":"2.0","id":4,"method":"diagnostics/get","params":{}}"#),
        frame(r#"{"jsonrpc":"2.0","id":5,"method":"repository/open","params":{"path":"C:/unrelated-during-recovery"}}"#),
        frame(&serde_json::json!({"jsonrpc":"2.0","id":6,"method":"repository/close","params":{"repositoryId":repository_id,"epoch":1}}).to_string()),
    ]
    .concat();
    let after_safe = [
        frame(&serde_json::json!({"jsonrpc":"2.0","id":7,"method":"repository/close","params":{"repositoryId":repository_id,"epoch":1}}).to_string()),
        frame(r#"{"jsonrpc":"2.0","id":8,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let reader = DelayedChunkReader::new(
        vec![first, while_blocked, after_safe],
        vec![Duration::from_millis(30), Duration::from_millis(200)],
    );
    let release = control.release.clone();
    let started = control.started.clone();
    let releaser = thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(2);
        while !started.load(Ordering::SeqCst) {
            assert!(Instant::now() < deadline, "recovery task did not start");
            thread::yield_now();
        }
        thread::sleep(Duration::from_millis(100));
        release.store(true, Ordering::SeqCst);
    });
    let mut output = Vec::new();

    run_json_rpc_stdio_with_remote_worker(
        reader,
        &mut output,
        &FakeBridge,
        Arc::new(MutationFailureRemoteWorker),
    )
    .expect("blocking recovery must not stall unrelated stdio requests");
    releaser.join().expect("recovery releaser must finish");
    recovery_task_controls()
        .lock()
        .expect("recovery task controls must not be poisoned")
        .remove(path);

    let frames = decode_frames(&output).expect("responses must remain framed");
    let response_index = |id: u64| {
        frames
            .iter()
            .position(|frame| frame["id"] == id)
            .expect("expected response id")
    };
    assert!(response_index(4) < response_index(3));
    assert!(response_index(5) < response_index(3));
    assert!(response_index(6) < response_index(3));
    assert_eq!(
        frames[response_index(4)]["result"]["source"],
        "subversionr-daemon"
    );
    assert_eq!(
        frames[response_index(5)]["result"]["repositoryId"],
        "repo-uuid:C:/unrelated-during-recovery"
    );
    assert_eq!(
        frames[response_index(6)]["error"]["code"],
        "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE"
    );
    assert_eq!(frames[response_index(3)]["result"]["outcome"], "safe");
    assert_eq!(frames[response_index(7)]["result"]["closed"], true);
    assert!(!control.cancelled.load(Ordering::SeqCst));
}

#[test]
fn stdio_matching_cancel_settles_blocking_recovery_as_indeterminate() {
    let path = "C:/wc-remote-recovery-blocking-cancel";
    let repository_id = format!("repo-uuid:{path}");
    let origin_operation_id = "f1234567-89ab-4def-8123-456789abcdef";
    let recovery_operation_id = "01234567-89ab-4def-8123-456789abcdef";
    let control = RecoveryTaskControl {
        started: Arc::new(AtomicBool::new(false)),
        release: Arc::new(AtomicBool::new(false)),
        cancelled: Arc::new(AtomicBool::new(false)),
    };
    recovery_task_controls()
        .lock()
        .expect("recovery task controls must not be poisoned")
        .insert(path.to_string(), control.clone());
    let first = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","trustEpoch":1,"cacheRoot":"C:/cache"}}"#),
        frame(&serde_json::json!({"jsonrpc":"2.0","id":2,"method":"repository/open","params":{"path":path}}).to_string()),
        remote_recovery_frame(3, &repository_id, origin_operation_id, recovery_operation_id, 30_000),
    ]
    .concat();
    let cancel_and_diagnostics = [
        frame(r#"{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":3}}"#),
        frame(r#"{"jsonrpc":"2.0","id":4,"method":"diagnostics/get","params":{}}"#),
    ]
    .concat();
    let reader = DelayedChunkReader::new(
        vec![
            first,
            cancel_and_diagnostics,
            frame(r#"{"jsonrpc":"2.0","id":5,"method":"shutdown","params":{}}"#),
        ],
        vec![Duration::from_millis(30), Duration::from_millis(100)],
    );
    let mut output = Vec::new();

    run_json_rpc_stdio_with_remote_worker(
        reader,
        &mut output,
        &FakeBridge,
        Arc::new(MutationFailureRemoteWorker),
    )
    .expect("matching cancellation must settle recovery without stalling stdio");
    recovery_task_controls()
        .lock()
        .expect("recovery task controls must not be poisoned")
        .remove(path);

    let frames = decode_frames(&output).expect("responses must remain framed");
    let recovery = frames
        .iter()
        .find(|frame| frame["id"] == 3)
        .expect("cancelled recovery response");
    assert_eq!(recovery["result"]["outcome"], "indeterminate");
    assert_eq!(
        recovery["result"]["failure"]["reason"],
        "operationCancelled"
    );
    assert!(frames.iter().any(|frame| frame["id"] == 4));
    assert!(control.cancelled.load(Ordering::SeqCst));
}

#[test]
fn stdio_eof_cancels_and_settles_blocking_recovery_without_a_late_response() {
    let path = "C:/wc-remote-recovery-blocking-eof";
    let repository_id = format!("repo-uuid:{path}");
    let control = RecoveryTaskControl {
        started: Arc::new(AtomicBool::new(false)),
        release: Arc::new(AtomicBool::new(false)),
        cancelled: Arc::new(AtomicBool::new(false)),
    };
    recovery_task_controls()
        .lock()
        .expect("recovery task controls must not be poisoned")
        .insert(path.to_string(), control.clone());
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","trustEpoch":1,"cacheRoot":"C:/cache"}}"#),
        frame(&serde_json::json!({"jsonrpc":"2.0","id":2,"method":"repository/open","params":{"path":path}}).to_string()),
        remote_recovery_frame(
            3,
            &repository_id,
            "11234567-89ab-4def-8123-456789abcdef",
            "21234567-89ab-4def-8123-456789abcdef",
            30_000,
        ),
    ]
    .concat();
    let reader = DelayedEofReader::new(input, Duration::from_millis(40));
    let mut output = Vec::new();

    run_json_rpc_stdio_with_remote_worker(
        reader,
        &mut output,
        &FakeBridge,
        Arc::new(MutationFailureRemoteWorker),
    )
    .expect("EOF must cancel and settle a blocking recovery task");
    recovery_task_controls()
        .lock()
        .expect("recovery task controls must not be poisoned")
        .remove(path);

    let frames = decode_frames(&output).expect("completed responses must remain framed");
    assert!(frames.iter().any(|frame| frame["id"] == 1));
    assert!(frames.iter().any(|frame| frame["id"] == 2));
    assert!(!frames.iter().any(|frame| frame["id"] == 3));
    assert!(control.started.load(Ordering::SeqCst));
    assert!(control.cancelled.load(Ordering::SeqCst));
}

fn remote_worker_test_failure(code: &str) -> BridgeFailure {
    BridgeFailure::new(
        code,
        "state",
        "error.remote.workerTest",
        serde_json::json!({}),
        false,
    )
}

fn worker_settlement(
    effect: RemoteOperationEffect,
    result: Result<(), BridgeFailure>,
    worker_was_resumed: bool,
    cleanup_safe: bool,
) -> RemoteWorkerSettlement {
    let remote_failure = result.as_ref().err().map(|failure| {
        let (category, reason) = match failure.code() {
            "SUBVERSIONR_REMOTE_WORKER_CANCELLED" => (
                RemoteFailureCategory::Cancellation,
                RemoteFailureClass::OperationCancelled,
            ),
            "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED" => (
                RemoteFailureCategory::Recovery,
                RemoteFailureClass::RemoteRecoveryBlocked,
            ),
            "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED" => (
                RemoteFailureCategory::Process,
                RemoteFailureClass::WorkerContainmentFailed,
            ),
            _ => (
                RemoteFailureCategory::Unknown,
                RemoteFailureClass::UnknownRemote,
            ),
        };
        RemoteFailure {
            category,
            reason,
            cleanup_appropriate: false,
        }
    });
    RemoteWorkerSettlement {
        result,
        operation_output: None,
        remote_failure,
        effect,
        worker_was_resumed,
        execution_origin_known: true,
        termination: if cleanup_safe {
            WorkerTerminationDisposition::NotRequired
        } else {
            WorkerTerminationDisposition::Blocked
        },
        job_descendants_zero: cleanup_safe,
        temp_root_removed: cleanup_safe,
    }
}

fn remote_checkout_frame(id: u64, operation_id: &str, target_path: &str) -> Vec<u8> {
    remote_checkout_frame_with_timeout(id, operation_id, target_path, 30_000)
}

fn remote_update_frame(id: u64, operation_id: &str, timeout_ms: u64) -> Vec<u8> {
    frame(
        &serde_json::json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": "operation/run",
            "params": {
                "repositoryId": "repo-uuid:C:/wc-remote-recovery",
                "epoch": 1,
                "kind": "update",
                "options": {
                    "version": 1,
                    "path": ".",
                    "revision": "head",
                    "depth": "workingCopy",
                    "depthIsSticky": false,
                    "ignoreExternals": true
                },
                "remote": {
                    "version": 1,
                    "operationId": operation_id,
                    "intent": "foreground",
                    "interaction": "allowed",
                    "timeoutMs": timeout_ms,
                    "workspaceTrust": "trusted",
                    "trustEpoch": 1,
                    "profile": {
                        "schema": "subversionr.remote-profile.v1",
                        "profileId": "stdio-recovery-test",
                        "authority": { "scheme": "https", "canonicalHost": "svn.example.invalid", "effectivePort": 443 },
                        "serverAuth": "anonymous",
                        "serverAccount": "none",
                        "serverCredentialPersistence": "secretStorage",
                        "tls": { "trust": "windowsRootsThenBroker" },
                        "proxy": "none",
                        "ssh": "none",
                        "redirectPolicy": "rejectAll"
                    },
                    "expectedOrigin": { "scheme": "https", "canonicalHost": "svn.example.invalid", "effectivePort": 443 }
                }
            }
        })
        .to_string(),
    )
}

fn remote_recovery_frame(
    id: u64,
    repository_id: &str,
    origin_operation_id: &str,
    operation_id: &str,
    timeout_ms: u64,
) -> Vec<u8> {
    frame(
        &serde_json::json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": "remote/recoverWorkingCopy",
            "params": {
                "repositoryId": repository_id,
                "epoch": 1,
                "originOperationId": origin_operation_id,
                "operationId": operation_id,
                "timeoutMs": timeout_ms
            }
        })
        .to_string(),
    )
}

fn remote_status_frame(id: u64, operation_id: &str, timeout_ms: u64) -> Vec<u8> {
    frame(
        &serde_json::json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": "status/checkRemote",
            "params": {
                "repositoryId": "repo-uuid:C:/wc-remote-recovery",
                "epoch": 1,
                "remote": {
                    "version": 1,
                    "operationId": operation_id,
                    "intent": "foreground",
                    "interaction": "allowed",
                    "timeoutMs": timeout_ms,
                    "workspaceTrust": "trusted",
                    "trustEpoch": 1,
                    "profile": {
                        "schema": "subversionr.remote-profile.v1",
                        "profileId": "stdio-status-worker-test",
                        "authority": { "scheme": "https", "canonicalHost": "svn.example.invalid", "effectivePort": 443 },
                        "serverAuth": "anonymous",
                        "serverAccount": "none",
                        "serverCredentialPersistence": "secretStorage",
                        "tls": { "trust": "windowsRootsThenBroker" },
                        "proxy": "none",
                        "ssh": "none",
                        "redirectPolicy": "rejectAll"
                    },
                    "expectedOrigin": { "scheme": "https", "canonicalHost": "svn.example.invalid", "effectivePort": 443 }
                }
            }
        })
        .to_string(),
    )
}

fn remote_checkout_frame_with_timeout(
    id: u64,
    operation_id: &str,
    target_path: &str,
    timeout_ms: u64,
) -> Vec<u8> {
    frame(
        &serde_json::json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": "repository/checkout",
            "params": {
                "url": "https://svn.example.invalid/project/trunk",
                "targetPath": target_path,
                "revision": "head",
                "depth": "infinity",
                "ignoreExternals": true,
                "remote": {
                    "version": 1,
                    "operationId": operation_id,
                    "intent": "foreground",
                    "interaction": "allowed",
                    "timeoutMs": timeout_ms,
                    "workspaceTrust": "trusted",
                    "trustEpoch": 1,
                    "profile": {
                        "schema": "subversionr.remote-profile.v1",
                        "profileId": "stdio-worker-test",
                        "authority": { "scheme": "https", "canonicalHost": "svn.example.invalid", "effectivePort": 443 },
                        "serverAuth": "anonymous",
                        "serverAccount": "none",
                        "serverCredentialPersistence": "secretStorage",
                        "tls": { "trust": "windowsRootsThenBroker" },
                        "proxy": "none",
                        "ssh": "none",
                        "redirectPolicy": "rejectAll"
                    },
                    "expectedOrigin": { "scheme": "https", "canonicalHost": "svn.example.invalid", "effectivePort": 443 }
                }
            }
        })
        .to_string(),
    )
}

fn frame(payload: &str) -> Vec<u8> {
    static NEXT_REMOTE_STATE_ROOT: AtomicUsize = AtomicUsize::new(1);
    let mut value: serde_json::Value = serde_json::from_str(payload).expect("test frame JSON");
    if value.get("method").and_then(serde_json::Value::as_str) == Some("initialize")
        && value
            .get("params")
            .and_then(serde_json::Value::as_object)
            .is_some_and(|params| !params.contains_key("remoteStateRoot"))
    {
        let root = std::env::temp_dir().join(format!(
            "subversionr-stdio-remote-state-{}-{}",
            std::process::id(),
            NEXT_REMOTE_STATE_ROOT.fetch_add(1, Ordering::Relaxed),
        ));
        std::fs::create_dir_all(&root).expect("test remote state root");
        value
            .get_mut("params")
            .and_then(serde_json::Value::as_object_mut)
            .expect("initialize params object")
            .insert(
                "remoteStateRoot".to_string(),
                serde_json::Value::String(
                    root.canonicalize()
                        .expect("canonical test remote state root")
                        .to_string_lossy()
                        .into_owned(),
                ),
            );
    }
    let payload = value.to_string();
    format!("Content-Length: {}\r\n\r\n{payload}", payload.len()).into_bytes()
}

struct DelayedEofReader {
    payload: io::Cursor<Vec<u8>>,
    eof_delay: Duration,
    delayed: bool,
}

impl DelayedEofReader {
    fn new(payload: Vec<u8>, eof_delay: Duration) -> Self {
        Self {
            payload: io::Cursor::new(payload),
            eof_delay,
            delayed: false,
        }
    }
}

impl Read for DelayedEofReader {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let bytes_read = self.payload.read(buffer)?;
        if bytes_read == 0 && !self.delayed {
            self.delayed = true;
            thread::sleep(self.eof_delay);
        }
        Ok(bytes_read)
    }
}

struct DelayedSecondChunkReader {
    first: io::Cursor<Vec<u8>>,
    second: io::Cursor<Vec<u8>>,
    second_delay: Duration,
    delayed: bool,
}

struct DelayedChunkReader {
    chunks: Vec<io::Cursor<Vec<u8>>>,
    delays: Vec<Duration>,
    next_chunk: usize,
}

impl DelayedChunkReader {
    fn new(chunks: Vec<Vec<u8>>, delays: Vec<Duration>) -> Self {
        assert_eq!(chunks.len(), delays.len() + 1);
        Self {
            chunks: chunks.into_iter().map(io::Cursor::new).collect(),
            delays,
            next_chunk: 0,
        }
    }
}

impl Read for DelayedChunkReader {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        loop {
            if self.next_chunk >= self.chunks.len() {
                return Ok(0);
            }
            let read = self.chunks[self.next_chunk].read(buffer)?;
            if read > 0 {
                return Ok(read);
            }
            let completed = self.next_chunk;
            self.next_chunk += 1;
            if let Some(delay) = self.delays.get(completed) {
                thread::sleep(*delay);
            }
        }
    }
}

impl DelayedSecondChunkReader {
    fn new(first: Vec<u8>, second: Vec<u8>, second_delay: Duration) -> Self {
        Self {
            first: io::Cursor::new(first),
            second: io::Cursor::new(second),
            second_delay,
            delayed: false,
        }
    }
}

impl Read for DelayedSecondChunkReader {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let bytes_read = self.first.read(buffer)?;
        if bytes_read > 0 {
            return Ok(bytes_read);
        }
        if !self.delayed {
            self.delayed = true;
            thread::sleep(self.second_delay);
        }
        self.second.read(buffer)
    }
}

struct BrokerRoundTripReader {
    chunks: Vec<io::Cursor<Vec<u8>>>,
    gates: Vec<usize>,
    next_chunk: usize,
    stage: Arc<AtomicUsize>,
}

struct BrokerRoundTripWriter {
    output: Vec<u8>,
    stage: Arc<AtomicUsize>,
}

impl BrokerRoundTripWriter {
    fn new(stage: Arc<AtomicUsize>) -> Self {
        Self {
            output: Vec::new(),
            stage,
        }
    }

    fn as_bytes(&self) -> &[u8] {
        &self.output
    }
}

impl io::Write for BrokerRoundTripWriter {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        self.output.extend_from_slice(buffer);
        if [
            b"\"method\":\"credentials/request\"".as_slice(),
            b"\"method\":\"credentials/settle\"".as_slice(),
        ]
        .iter()
        .any(|method| {
            self.output
                .windows(method.len())
                .any(|window| window == *method)
        }) {
            self.stage.fetch_max(1, Ordering::SeqCst);
        }
        if self
            .output
            .windows(b"\"id\":2".len())
            .any(|window| window == b"\"id\":2")
        {
            self.stage.fetch_max(3, Ordering::SeqCst);
        }
        Ok(buffer.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl BrokerRoundTripReader {
    fn new(chunks: Vec<Vec<u8>>, gates: Vec<usize>, stage: Arc<AtomicUsize>) -> Self {
        assert_eq!(chunks.len(), gates.len() + 1);
        Self {
            chunks: chunks.into_iter().map(io::Cursor::new).collect(),
            gates,
            next_chunk: 0,
            stage,
        }
    }

    fn wait_for_stage(&self, required: usize) -> io::Result<()> {
        let deadline = Instant::now() + Duration::from_secs(5);
        while self.stage.load(Ordering::SeqCst) < required {
            if Instant::now() >= deadline {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "settlement round trip did not reach the required stage",
                ));
            }
            thread::yield_now();
        }
        Ok(())
    }
}

impl Read for BrokerRoundTripReader {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        loop {
            if self.next_chunk >= self.chunks.len() {
                return Ok(0);
            }
            let bytes_read = self.chunks[self.next_chunk].read(buffer)?;
            if bytes_read > 0 {
                return Ok(bytes_read);
            }
            self.next_chunk += 1;
            if let Some(required) = self.gates.get(self.next_chunk - 1) {
                self.wait_for_stage(*required)?;
            }
        }
    }
}

fn decode_frames(output: &[u8]) -> io::Result<Vec<serde_json::Value>> {
    let mut cursor = 0;
    let mut responses = Vec::new();
    while cursor < output.len() {
        let header_end = find_header_end(&output[cursor..])
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing header end"))?;
        let header = std::str::from_utf8(&output[cursor..cursor + header_end])
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        let length = header
            .strip_prefix("Content-Length: ")
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing content length"))?
            .parse::<usize>()
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        let body_start = cursor + header_end + 4;
        let body_end = body_start + length;
        responses.push(
            serde_json::from_slice(&output[body_start..body_end])
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?,
        );
        cursor = body_end;
    }

    Ok(responses)
}

fn find_header_end(bytes: &[u8]) -> Option<usize> {
    bytes.windows(4).position(|window| window == b"\r\n\r\n")
}

use std::io::{self, Read};
use std::thread;
use std::time::{Duration, Instant};

use subversionr_daemon::{
    AddOperationRequest, AuthRequestBroker, BridgeApi, BridgeCancellationToken, BridgeFailure,
    BridgeInfo, CleanupOperationRequest, CommitOperationRequest, CommitOperationResult,
    ContentBlob, HistoryBlameRequest, HistoryBlameResult, HistoryLogRequest, HistoryLogResult,
    MoveOperationRequest, OperationResult, PropertiesListResult, PropertyDeleteOperationRequest,
    PropertyEntry, PropertySetOperationRequest, RemoveOperationRequest, ResolveOperationRequest,
    RevertOperationRequest, UpdateOperationRequest, UpdateOperationResult, run_json_rpc_stdio,
};
use subversionr_protocol::{
    CertificateTrustRequest, CertificateTrustResponse, Credential, CredentialRequest,
    CredentialResponse, RepositoryIdentity, StatusEntry, StatusSnapshot, StatusSummary,
};

#[derive(Debug)]
struct FakeBridge;

impl BridgeApi for FakeBridge {
    fn info(&self) -> BridgeInfo {
        BridgeInfo::available("subversionr-svn-bridge/0.1.0-test", "1.14.5")
    }

    fn open_working_copy(&self, path: &str) -> Result<RepositoryIdentity, BridgeFailure> {
        Ok(RepositoryIdentity {
            repository_uuid: "repo-uuid".to_string(),
            repository_root_url: "file:///repo".to_string(),
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
        let response = auth.request_credential(CredentialRequest {
            request_id: "cred-1".to_string(),
            realm: "svn://example".to_string(),
            kind: "usernamePassword".to_string(),
            username: Some("alice".to_string()),
            interactive: true,
            persistence_allowed: true,
            origin: "foreground".to_string(),
            timeout_ms: 30000,
            repository_id: None,
            working_copy_root: Some(path.to_string()),
        })?;

        assert_eq!(
            response,
            CredentialResponse::Provide {
                request_id: "cred-1".to_string(),
                credential: Credential {
                    username: Some("alice".to_string()),
                    secret: "secret".to_string(),
                },
                persistence: "secretStorage".to_string(),
            }
        );

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
        identity: &RepositoryIdentity,
        request: &UpdateOperationRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<UpdateOperationResult, BridgeFailure> {
        let repository_id = format!(
            "{}:{}",
            identity.repository_uuid, identity.working_copy_root
        );
        let response = auth.request_credential(CredentialRequest {
            request_id: "update-cred-1".to_string(),
            realm: "svn://example/update".to_string(),
            kind: "usernamePassword".to_string(),
            username: Some("alice".to_string()),
            interactive: true,
            persistence_allowed: true,
            origin: "foreground".to_string(),
            timeout_ms: 30000,
            repository_id: Some(repository_id),
            working_copy_root: Some(identity.working_copy_root.clone()),
        })?;

        assert_eq!(
            response,
            CredentialResponse::Provide {
                request_id: "update-cred-1".to_string(),
                credential: Credential {
                    username: Some("alice".to_string()),
                    secret: "secret".to_string(),
                },
                persistence: "secretStorage".to_string(),
            }
        );

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
        let repository_id = format!(
            "{}:{}",
            identity.repository_uuid, identity.working_copy_root
        );
        let response = auth.request_credential(CredentialRequest {
            request_id: "remote-status-cred-1".to_string(),
            realm: "svn://example/status".to_string(),
            kind: "usernamePassword".to_string(),
            username: Some("alice".to_string()),
            interactive: true,
            persistence_allowed: true,
            origin: "foreground".to_string(),
            timeout_ms: 30000,
            repository_id: Some(repository_id.clone()),
            working_copy_root: Some(identity.working_copy_root.clone()),
        })?;
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
        identity: &RepositoryIdentity,
        path: &str,
        revision: &str,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<ContentBlob, BridgeFailure> {
        assert_eq!(path, "tracked.txt");
        assert_eq!(revision, "head");
        let repository_id = format!(
            "{}:{}",
            identity.repository_uuid, identity.working_copy_root
        );
        let response = auth.request_credential(CredentialRequest {
            request_id: "content-cred-1".to_string(),
            realm: "svn://example/content".to_string(),
            kind: "usernamePassword".to_string(),
            username: Some("alice".to_string()),
            interactive: true,
            persistence_allowed: true,
            origin: "foreground".to_string(),
            timeout_ms: 30000,
            repository_id: Some(repository_id),
            working_copy_root: Some(identity.working_copy_root.clone()),
        })?;

        assert_eq!(
            response,
            CredentialResponse::Provide {
                request_id: "content-cred-1".to_string(),
                credential: Credential {
                    username: Some("alice".to_string()),
                    secret: "secret".to_string(),
                },
                persistence: "secretStorage".to_string(),
            }
        );

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
        identity: &RepositoryIdentity,
        request: &HistoryLogRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<HistoryLogResult, BridgeFailure> {
        assert_eq!(request.path, "tracked.txt");
        assert_eq!(request.start_revision, "head");
        let repository_id = format!(
            "{}:{}",
            identity.repository_uuid, identity.working_copy_root
        );
        let response = auth.request_credential(CredentialRequest {
            request_id: "history-log-cred-1".to_string(),
            realm: "svn://example/history-log".to_string(),
            kind: "usernamePassword".to_string(),
            username: Some("alice".to_string()),
            interactive: true,
            persistence_allowed: true,
            origin: "foreground".to_string(),
            timeout_ms: 30000,
            repository_id: Some(repository_id),
            working_copy_root: Some(identity.working_copy_root.clone()),
        })?;

        assert_eq!(
            response,
            CredentialResponse::Provide {
                request_id: "history-log-cred-1".to_string(),
                credential: Credential {
                    username: Some("alice".to_string()),
                    secret: "secret".to_string(),
                },
                persistence: "secretStorage".to_string(),
            }
        );

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
        identity: &RepositoryIdentity,
        request: &HistoryBlameRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<HistoryBlameResult, BridgeFailure> {
        assert_eq!(request.path, "tracked.txt");
        assert_eq!(request.end_revision, "head");
        let repository_id = format!(
            "{}:{}",
            identity.repository_uuid, identity.working_copy_root
        );
        let response = auth.request_credential(CredentialRequest {
            request_id: "history-blame-cred-1".to_string(),
            realm: "svn://example/history-blame".to_string(),
            kind: "usernamePassword".to_string(),
            username: Some("alice".to_string()),
            interactive: true,
            persistence_allowed: true,
            origin: "foreground".to_string(),
            timeout_ms: 30000,
            repository_id: Some(repository_id),
            working_copy_root: Some(identity.working_copy_root.clone()),
        })?;

        assert_eq!(
            response,
            CredentialResponse::Provide {
                request_id: "history-blame-cred-1".to_string(),
                credential: Credential {
                    username: Some("alice".to_string()),
                    secret: "secret".to_string(),
                },
                persistence: "secretStorage".to_string(),
            }
        );

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
        identity: &RepositoryIdentity,
        request: &CommitOperationRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<CommitOperationResult, BridgeFailure> {
        assert_eq!(request.paths, vec!["tracked.txt".to_string()]);
        assert_eq!(request.message, "commit through broker");
        let repository_id = format!(
            "{}:{}",
            identity.repository_uuid, identity.working_copy_root
        );
        let response = auth.request_credential(CredentialRequest {
            request_id: "commit-cred-1".to_string(),
            realm: "svn://example/commit".to_string(),
            kind: "usernamePassword".to_string(),
            username: Some("alice".to_string()),
            interactive: true,
            persistence_allowed: true,
            origin: "foreground".to_string(),
            timeout_ms: 30000,
            repository_id: Some(repository_id),
            working_copy_root: Some(identity.working_copy_root.clone()),
        })?;

        assert_eq!(
            response,
            CredentialResponse::Provide {
                request_id: "commit-cred-1".to_string(),
                credential: Credential {
                    username: Some("alice".to_string()),
                    secret: "secret".to_string(),
                },
                persistence: "secretStorage".to_string(),
            }
        );

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
        match auth.request_credential(CredentialRequest {
            request_id: "cred-background".to_string(),
            realm: "svn://example".to_string(),
            kind: "usernamePassword".to_string(),
            username: None,
            interactive: false,
            persistence_allowed: false,
            origin: "background".to_string(),
            timeout_ms: 30000,
            repository_id: None,
            working_copy_root: Some(path.to_string()),
        }) {
            Ok(_) => panic!("non-interactive credential request must not provide a credential"),
            Err(failure) => Err(failure),
        }
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
        auth.request_credential(CredentialRequest {
            request_id: "cred-expected".to_string(),
            realm: "svn://example".to_string(),
            kind: "usernamePassword".to_string(),
            username: Some("alice".to_string()),
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
        auth.request_credential(CredentialRequest {
            request_id: "cred-timeout".to_string(),
            realm: "svn://example".to_string(),
            kind: "usernamePassword".to_string(),
            username: Some("alice".to_string()),
            interactive: true,
            persistence_allowed: true,
            origin: "foreground".to_string(),
            timeout_ms: 0,
            repository_id: None,
            working_copy_root: Some(path.to_string()),
        })?;

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
        auth.request_credential(CredentialRequest {
            request_id: "cred-short-timeout".to_string(),
            realm: "svn://example".to_string(),
            kind: "usernamePassword".to_string(),
            username: Some("alice".to_string()),
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
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","cacheRoot":"C:/Users/Alice/AppData/Roaming/Code/User/globalStorage/subversionr/cache"}}"#),
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
        frame(r#"{"jsonrpc":"2.0","id":"cred-1","result":{"requestId":"cred-1","action":"provide","credential":{"username":"alice","secret":"secret"},"persistence":"secretStorage"}}"#),
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
    assert_eq!(frames[0]["id"], "cred-1");
    assert_eq!(frames[0]["method"], "credentials/request");
    assert_eq!(frames[0]["params"]["realm"], "svn://example");
    assert_eq!(frames[0]["params"]["kind"], "usernamePassword");
    assert_eq!(frames[0]["params"]["workingCopyRoot"], "C:/wc");
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
        frame(r#"{"jsonrpc":"2.0","id":"update-cred-1","result":{"requestId":"update-cred-1","action":"provide","credential":{"username":"alice","secret":"secret"},"persistence":"secretStorage"}}"#),
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
    assert_eq!(frames[1]["id"], "update-cred-1");
    assert_eq!(frames[1]["method"], "credentials/request");
    assert_eq!(frames[1]["params"]["realm"], "svn://example/update");
    assert_eq!(frames[1]["params"]["repositoryId"], "repo-uuid:C:/wc");
    assert_eq!(frames[1]["params"]["workingCopyRoot"], "C:/wc");
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
        frame(r#"{"jsonrpc":"2.0","id":"remote-status-cred-1","result":{"requestId":"remote-status-cred-1","action":"provide","credential":{"username":"alice","secret":"secret"},"persistence":"secretStorage"}}"#),
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
    assert_eq!(frames[1]["id"], "remote-status-cred-1");
    assert_eq!(frames[1]["method"], "credentials/request");
    assert_eq!(frames[1]["params"]["repositoryId"], "repo-uuid:C:/wc");
    assert_eq!(frames[1]["params"]["workingCopyRoot"], "C:/wc");
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
        frame(r#"{"jsonrpc":"2.0","id":"remote-status-cred-1","result":{"requestId":"remote-status-cred-1","action":"cancel","error":{"code":"SUBVERSIONR_CREDENTIAL_CANCELLED","category":"auth","messageKey":"error.auth.credentialCancelled","args":{},"retryable":false}}}"#),
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
        frame(r#"{"jsonrpc":"2.0","id":"content-cred-1","result":{"requestId":"content-cred-1","action":"provide","credential":{"username":"alice","secret":"secret"},"persistence":"secretStorage"}}"#),
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
    assert_eq!(frames[1]["id"], "content-cred-1");
    assert_eq!(frames[1]["method"], "credentials/request");
    assert_eq!(frames[1]["params"]["realm"], "svn://example/content");
    assert_eq!(frames[1]["params"]["repositoryId"], "repo-uuid:C:/wc");
    assert_eq!(frames[1]["params"]["workingCopyRoot"], "C:/wc");
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
        frame(r#"{"jsonrpc":"2.0","id":"history-log-cred-1","result":{"requestId":"history-log-cred-1","action":"provide","credential":{"username":"alice","secret":"secret"},"persistence":"secretStorage"}}"#),
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
    assert_eq!(frames[1]["id"], "history-log-cred-1");
    assert_eq!(frames[1]["method"], "credentials/request");
    assert_eq!(frames[1]["params"]["realm"], "svn://example/history-log");
    assert_eq!(frames[1]["params"]["repositoryId"], "repo-uuid:C:/wc");
    assert_eq!(frames[1]["params"]["workingCopyRoot"], "C:/wc");
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
        frame(r#"{"jsonrpc":"2.0","id":"history-blame-cred-1","result":{"requestId":"history-blame-cred-1","action":"provide","credential":{"username":"alice","secret":"secret"},"persistence":"secretStorage"}}"#),
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
    assert_eq!(frames[1]["id"], "history-blame-cred-1");
    assert_eq!(frames[1]["method"], "credentials/request");
    assert_eq!(frames[1]["params"]["realm"], "svn://example/history-blame");
    assert_eq!(frames[1]["params"]["repositoryId"], "repo-uuid:C:/wc");
    assert_eq!(frames[1]["params"]["workingCopyRoot"], "C:/wc");
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
        frame(r#"{"jsonrpc":"2.0","id":"commit-cred-1","result":{"requestId":"commit-cred-1","action":"provide","credential":{"username":"alice","secret":"secret"},"persistence":"secretStorage"}}"#),
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
    assert_eq!(frames[1]["id"], "commit-cred-1");
    assert_eq!(frames[1]["method"], "credentials/request");
    assert_eq!(frames[1]["params"]["realm"], "svn://example/commit");
    assert_eq!(frames[1]["params"]["repositoryId"], "repo-uuid:C:/wc");
    assert_eq!(frames[1]["params"]["workingCopyRoot"], "C:/wc");
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
        frame(r#"{"jsonrpc":"2.0","id":"cred-expected","result":{"requestId":"cred-other","action":"provide","credential":{"username":"alice","secret":"secret"},"persistence":"secretStorage"}}"#),
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
fn stdio_loop_maps_credential_cancel_response_to_original_request_error() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cred-expected","result":{"requestId":"cred-expected","action":"cancel","error":{"code":"SUBVERSIONR_CREDENTIAL_CANCELLED","category":"auth","messageKey":"error.auth.credentialCancelled","args":{"realmHash":"abc123","secret":"leak","rawRealm":"svn://example"},"retryable":false}}}"#),
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
        frames[1]["error"]["args"]["realmHash"],
        "66405412e36fad5c5c8f589fcce7183e434f5bc68b99742e30b02e56cc090733"
    );
    assert_eq!(frames[1]["error"]["args"]["kind"], "usernamePassword");
    assert_eq!(frames[1]["error"]["args"]["origin"], "foreground");
    assert!(frames[1]["error"]["args"].get("secret").is_none());
    assert!(frames[1]["error"]["args"].get("rawRealm").is_none());
}

#[test]
fn stdio_loop_rejects_credential_cancel_response_with_unexpected_error_contract() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cred-expected","result":{"requestId":"cred-expected","action":"cancel","error":{"code":"RPC_METHOD_NOT_FOUND","category":"unsupported","messageKey":"error.rpc.methodNotFound","args":{"method":"credentials/request","secret":"leak"},"retryable":false}}}"#),
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
fn stdio_loop_rejects_non_interactive_credential_without_prompting() {
    let input =
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#);
    let mut output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(input),
        &mut output,
        &NonInteractiveCredentialBridge,
    )
    .expect("stdio loop should fail non-interactive credential requests without prompting");

    let frames = decode_frames(&output).expect("frames should be content-length encoded");
    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0]["id"], 1);
    assert_eq!(
        frames[0]["error"]["code"],
        "SUBVERSIONR_CREDENTIAL_NON_INTERACTIVE"
    );
    assert_eq!(
        frames[0]["error"]["messageKey"],
        "error.auth.credentialNonInteractive"
    );
    assert_eq!(frames[0]["error"]["args"]["method"], "credentials/request");
    assert!(frames[0]["method"].is_null());
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
fn stdio_loop_rejects_cancel_request_with_envelope_id_while_auth_continues() {
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"repository/open","params":{"path":"C:/wc"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":77,"method":"$/cancelRequest","params":{"id":"cred-expected"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cred-expected","result":{"requestId":"cred-expected","action":"provide","credential":{"username":"alice","secret":"secret"},"persistence":"session"}}"#),
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
        frame(r#"{"jsonrpc":"2.0","id":"cred-expected","result":{"requestId":"cred-expected","action":"provide","credential":{"username":"alice","secret":"secret"},"persistence":"session"}}"#),
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
        frame(r#"{"jsonrpc":"2.0","id":99,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","cacheRoot":"C:/Users/Alice/AppData/Roaming/Code/User/globalStorage/subversionr/cache"}}"#),
        frame(r#"{"jsonrpc":"2.0","id":"cred-expected","result":{"requestId":"cred-expected","action":"provide","credential":{"username":"alice","secret":"secret"},"persistence":"session"}}"#),
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
            r#"{{"jsonrpc":"2.0","id":{id},"method":"initialize","params":{{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","cacheRoot":"C:/Users/Alice/AppData/Roaming/Code/User/globalStorage/subversionr/cache"}}}}"#
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
        frame(r#"{"jsonrpc":"2.0","id":"cred-expected","result":{"requestId":"cred-expected","action":"provide","credential":{"username":"alice","secret":"secret"},"persistence":"session"}}"#),
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
        frame(r#"{"jsonrpc":"2.0","id":"cred-short-timeout","result":{"requestId":"cred-short-timeout","action":"provide","credential":{"username":"alice","secret":"late-secret"},"persistence":"session"}}"#),
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
        frame(r#"{"id":"cred-expected","result":{"requestId":"cred-expected","action":"provide","credential":{"username":"alice","secret":"secret"},"persistence":"session"}}"#),
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
        frame(r#"{"jsonrpc":"2.0","id":"cred-expected","result":{"requestId":"cred-expected","action":"provide","credential":{"username":"alice","secret":"secret"},"persistence":"session"},"error":{"code":"BAD","message":"bad"}}"#),
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

fn frame(payload: &str) -> Vec<u8> {
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

use std::{
    cell::RefCell,
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};
use subversionr_daemon::{
    BridgeApi, BridgeFailure, BridgeInfo, ContentBlob, DaemonState, DispatchOutcome,
    HistoryBlameRequest, HistoryBlameResult, HistoryLogRequest, HistoryLogResult,
    dispatch_json_rpc, dispatch_json_rpc_with_bridge,
};

use subversionr_protocol::{
    CredentialRequest, HistoryBlameLine, HistoryLogChangedPath, HistoryLogEntry, LockInfo,
    RepositoryIdentity, StatusEntry, StatusSnapshot, StatusSummary,
};

#[derive(Debug)]
struct FakeBridge {
    open_result: Result<RepositoryIdentity, BridgeFailure>,
    open_results: BTreeMap<String, Result<RepositoryIdentity, BridgeFailure>>,
    relocated_identity: RefCell<Option<RepositoryIdentity>>,
    snapshot_result: Result<StatusSnapshot, BridgeFailure>,
    remote_result: Result<StatusSnapshot, BridgeFailure>,
    remote_requests: RefCell<u32>,
    scan_results: BTreeMap<(String, String), Result<StatusSnapshot, BridgeFailure>>,
    content_results: BTreeMap<(String, String), Result<ContentBlob, BridgeFailure>>,
    properties_results:
        BTreeMap<String, Result<subversionr_daemon::PropertiesListResult, BridgeFailure>>,
    properties_requests: RefCell<Vec<String>>,
    history_results: BTreeMap<String, Result<HistoryLogResult, BridgeFailure>>,
    history_requests: RefCell<Vec<HistoryLogRequest>>,
    blame_results: BTreeMap<String, Result<HistoryBlameResult, BridgeFailure>>,
    blame_requests: RefCell<Vec<HistoryBlameRequest>>,
    checkout_results:
        BTreeMap<String, Result<subversionr_daemon::RepositoryCheckoutResult, BridgeFailure>>,
    checkout_requests: RefCell<Vec<subversionr_daemon::RepositoryCheckoutRequest>>,
    revert_results: BTreeMap<String, Result<subversionr_daemon::OperationResult, BridgeFailure>>,
    add_results: BTreeMap<String, Result<subversionr_daemon::OperationResult, BridgeFailure>>,
    add_requests: RefCell<Vec<subversionr_daemon::AddOperationRequest>>,
    remove_results: BTreeMap<String, Result<subversionr_daemon::OperationResult, BridgeFailure>>,
    remove_requests: RefCell<Vec<subversionr_daemon::RemoveOperationRequest>>,
    move_results: BTreeMap<String, Result<subversionr_daemon::OperationResult, BridgeFailure>>,
    move_requests: RefCell<Vec<subversionr_daemon::MoveOperationRequest>>,
    resolve_results: BTreeMap<String, Result<subversionr_daemon::OperationResult, BridgeFailure>>,
    resolve_requests: RefCell<Vec<subversionr_daemon::ResolveOperationRequest>>,
    cleanup_results: BTreeMap<String, Result<subversionr_daemon::OperationResult, BridgeFailure>>,
    cleanup_requests: RefCell<Vec<subversionr_daemon::CleanupOperationRequest>>,
    upgrade_results: BTreeMap<String, Result<subversionr_daemon::OperationResult, BridgeFailure>>,
    upgrade_requests: RefCell<Vec<subversionr_daemon::UpgradeOperationRequest>>,
    update_results:
        BTreeMap<String, Result<subversionr_daemon::UpdateOperationResult, BridgeFailure>>,
    update_requests: RefCell<Vec<subversionr_daemon::UpdateOperationRequest>>,
    property_set_results:
        BTreeMap<String, Result<subversionr_daemon::OperationResult, BridgeFailure>>,
    property_set_requests: RefCell<Vec<subversionr_daemon::PropertySetOperationRequest>>,
    property_delete_results:
        BTreeMap<String, Result<subversionr_daemon::OperationResult, BridgeFailure>>,
    property_delete_requests: RefCell<Vec<subversionr_daemon::PropertyDeleteOperationRequest>>,
    changelist_set_results:
        BTreeMap<String, Result<subversionr_daemon::OperationResult, BridgeFailure>>,
    changelist_set_requests: RefCell<Vec<subversionr_daemon::ChangelistSetOperationRequest>>,
    changelist_clear_results:
        BTreeMap<String, Result<subversionr_daemon::OperationResult, BridgeFailure>>,
    changelist_clear_requests: RefCell<Vec<subversionr_daemon::ChangelistClearOperationRequest>>,
    lock_results: BTreeMap<String, Result<subversionr_daemon::OperationResult, BridgeFailure>>,
    lock_requests: RefCell<Vec<subversionr_daemon::LockOperationRequest>>,
    unlock_results: BTreeMap<String, Result<subversionr_daemon::OperationResult, BridgeFailure>>,
    unlock_requests: RefCell<Vec<subversionr_daemon::UnlockOperationRequest>>,
    branch_create_results:
        BTreeMap<String, Result<subversionr_daemon::BranchCreateOperationResult, BridgeFailure>>,
    branch_create_requests: RefCell<Vec<subversionr_daemon::BranchCreateOperationRequest>>,
    switch_results:
        BTreeMap<String, Result<subversionr_daemon::SwitchOperationResult, BridgeFailure>>,
    switch_requests: RefCell<Vec<subversionr_daemon::SwitchOperationRequest>>,
    relocate_results: BTreeMap<String, Result<subversionr_daemon::OperationResult, BridgeFailure>>,
    relocate_requests: RefCell<Vec<subversionr_daemon::RelocateOperationRequest>>,
    merge_results: BTreeMap<String, Result<subversionr_daemon::OperationResult, BridgeFailure>>,
    merge_requests: RefCell<Vec<subversionr_daemon::MergeOperationRequest>>,
    commit_results:
        BTreeMap<String, Result<subversionr_daemon::CommitOperationResult, BridgeFailure>>,
    commit_requests: RefCell<Vec<subversionr_daemon::CommitOperationRequest>>,
    history_requires_auth: bool,
    blame_requires_auth: bool,
    commit_requires_auth: bool,
}

impl FakeBridge {
    fn identity() -> RepositoryIdentity {
        RepositoryIdentity {
            repository_uuid: "repo-uuid".to_string(),
            repository_root_url: "file:///C:/repo".to_string(),
            working_copy_root: "C:/wc".to_string(),
            workspace_scope_root: "C:/workspace".to_string(),
            format: 31,
        }
    }

    fn status_entry(path: &str, status: &str, generation: u64) -> StatusEntry {
        StatusEntry {
            path: path.to_string(),
            kind: "file".to_string(),
            node_status: status.to_string(),
            text_status: status.to_string(),
            property_status: "normal".to_string(),
            local_status: status.to_string(),
            remote_status: "notChecked".to_string(),
            revision: 7,
            changed_revision: 7,
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
            external: false,
            generation,
        }
    }

    fn remote_status_entry(path: &str, remote_status: &str, generation: u64) -> StatusEntry {
        let mut entry = Self::status_entry(path, "normal", generation);
        entry.remote_status = remote_status.to_string();
        entry
    }

    fn status_entry_with_kind(
        path: &str,
        kind: &str,
        status: &str,
        generation: u64,
    ) -> StatusEntry {
        StatusEntry {
            kind: kind.to_string(),
            ..Self::status_entry(path, status, generation)
        }
    }

    fn property_only_status_entry(path: &str, generation: u64) -> StatusEntry {
        let mut entry = Self::status_entry(path, "normal", generation);
        entry.property_status = "modified".to_string();
        entry
    }

    fn sparse_metadata_status_entry(path: &str, generation: u64) -> StatusEntry {
        let mut entry = Self::status_entry_with_kind(path, "dir", "normal", generation);
        entry.depth = "files".to_string();
        entry
    }

    fn switched_metadata_status_entry(path: &str, generation: u64) -> StatusEntry {
        let mut entry = Self::status_entry_with_kind(path, "dir", "normal", generation);
        entry.switched = true;
        entry
    }

    fn locked_metadata_status_entry(path: &str, generation: u64) -> StatusEntry {
        let mut entry = Self::status_entry(path, "normal", generation);
        entry.lock = Some(LockInfo {
            token: Some("opaquelocktoken:local".to_string()),
            owner: Some("alice".to_string()),
            comment: Some("editing file".to_string()),
            created_date: Some("2026-06-22T00:00:00Z".to_string()),
            expires_date: None,
            is_remote: false,
        });
        entry
    }

    fn needs_lock_metadata_status_entry(path: &str, generation: u64) -> StatusEntry {
        let mut entry = Self::status_entry(path, "normal", generation);
        entry.needs_lock = true;
        entry
    }

    fn sparse_metadata_snapshot_entry(path: &str, generation: u64) -> StatusSnapshot {
        let entries = vec![Self::sparse_metadata_status_entry(path, generation)];
        StatusSnapshot {
            repository_id: "repo-uuid:C:/wc".to_string(),
            epoch: 1,
            generation,
            completeness: "complete".to_string(),
            identity: Self::identity(),
            summary: StatusSummary {
                local_changes: 0,
                remote_changes: 0,
                conflicts: 0,
                unversioned: 0,
            },
            local_entries: entries,
            remote_entries: Vec::new(),
            timestamp: "2026-06-22T00:00:00Z".to_string(),
            source: "libsvn-local".to_string(),
        }
    }

    fn open_success() -> Self {
        Self {
            open_result: Ok(Self::identity()),
            open_results: BTreeMap::new(),
            relocated_identity: RefCell::new(None),
            snapshot_result: Ok(StatusSnapshot {
                repository_id: "repo-uuid:C:/wc".to_string(),
                epoch: 1,
                generation: 1,
                completeness: "complete".to_string(),
                identity: Self::identity(),
                local_entries: vec![Self::status_entry("src/main.c", "modified", 1)],
                remote_entries: Vec::new(),
                summary: StatusSummary {
                    local_changes: 1,
                    remote_changes: 0,
                    conflicts: 0,
                    unversioned: 0,
                },
                timestamp: "2026-06-22T00:00:00Z".to_string(),
                source: "libsvn-local".to_string(),
            }),
            remote_result: Ok(StatusSnapshot {
                repository_id: "repo-uuid:C:/wc".to_string(),
                epoch: 1,
                generation: 1,
                completeness: "complete".to_string(),
                identity: Self::identity(),
                local_entries: Vec::new(),
                remote_entries: Vec::new(),
                summary: StatusSummary {
                    local_changes: 0,
                    remote_changes: 0,
                    conflicts: 0,
                    unversioned: 0,
                },
                timestamp: "2026-06-22T00:00:00Z".to_string(),
                source: "libsvn-remote".to_string(),
            }),
            remote_requests: RefCell::new(0),
            scan_results: BTreeMap::new(),
            content_results: BTreeMap::new(),
            properties_results: BTreeMap::new(),
            properties_requests: RefCell::new(Vec::new()),
            history_results: BTreeMap::new(),
            history_requests: RefCell::new(Vec::new()),
            blame_results: BTreeMap::new(),
            blame_requests: RefCell::new(Vec::new()),
            checkout_results: BTreeMap::new(),
            checkout_requests: RefCell::new(Vec::new()),
            revert_results: BTreeMap::new(),
            add_results: BTreeMap::new(),
            add_requests: RefCell::new(Vec::new()),
            remove_results: BTreeMap::new(),
            remove_requests: RefCell::new(Vec::new()),
            move_results: BTreeMap::new(),
            move_requests: RefCell::new(Vec::new()),
            resolve_results: BTreeMap::new(),
            resolve_requests: RefCell::new(Vec::new()),
            cleanup_results: BTreeMap::new(),
            cleanup_requests: RefCell::new(Vec::new()),
            upgrade_results: BTreeMap::new(),
            upgrade_requests: RefCell::new(Vec::new()),
            update_results: BTreeMap::new(),
            update_requests: RefCell::new(Vec::new()),
            property_set_results: BTreeMap::new(),
            property_set_requests: RefCell::new(Vec::new()),
            property_delete_results: BTreeMap::new(),
            property_delete_requests: RefCell::new(Vec::new()),
            changelist_set_results: BTreeMap::new(),
            changelist_set_requests: RefCell::new(Vec::new()),
            changelist_clear_results: BTreeMap::new(),
            changelist_clear_requests: RefCell::new(Vec::new()),
            lock_results: BTreeMap::new(),
            lock_requests: RefCell::new(Vec::new()),
            unlock_results: BTreeMap::new(),
            unlock_requests: RefCell::new(Vec::new()),
            branch_create_results: BTreeMap::new(),
            branch_create_requests: RefCell::new(Vec::new()),
            switch_results: BTreeMap::new(),
            switch_requests: RefCell::new(Vec::new()),
            relocate_results: BTreeMap::new(),
            relocate_requests: RefCell::new(Vec::new()),
            merge_results: BTreeMap::new(),
            merge_requests: RefCell::new(Vec::new()),
            commit_results: BTreeMap::new(),
            commit_requests: RefCell::new(Vec::new()),
            history_requires_auth: false,
            blame_requires_auth: false,
            commit_requires_auth: false,
        }
    }

    fn with_open_result(
        mut self,
        path: &Path,
        result: Result<RepositoryIdentity, BridgeFailure>,
    ) -> Self {
        self.open_results
            .insert(open_result_key(&path.to_string_lossy()), result);
        self
    }

    fn with_checkout_result(
        mut self,
        url: &str,
        result: Result<subversionr_daemon::RepositoryCheckoutResult, BridgeFailure>,
    ) -> Self {
        self.checkout_results.insert(url.to_string(), result);
        self
    }

    fn identity_at(
        path: &Path,
        repository_uuid: &str,
        repository_root_url: &str,
    ) -> RepositoryIdentity {
        let root = path.to_string_lossy().to_string();
        RepositoryIdentity {
            repository_uuid: repository_uuid.to_string(),
            repository_root_url: repository_root_url.to_string(),
            working_copy_root: root.clone(),
            workspace_scope_root: root,
            format: 31,
        }
    }

    fn with_snapshot_entries(mut self, entries: Vec<StatusEntry>) -> Self {
        self.snapshot_result = Ok(StatusSnapshot {
            repository_id: "repo-uuid:C:/wc".to_string(),
            epoch: 1,
            generation: 1,
            completeness: "complete".to_string(),
            identity: Self::identity(),
            summary: StatusSummary {
                local_changes: entries.len() as u32,
                remote_changes: 0,
                conflicts: entries
                    .iter()
                    .filter(|entry| entry.conflict.is_some())
                    .count() as u32,
                unversioned: entries
                    .iter()
                    .filter(|entry| entry.local_status == "unversioned")
                    .count() as u32,
            },
            local_entries: entries,
            remote_entries: Vec::new(),
            timestamp: "2026-06-22T00:00:00Z".to_string(),
            source: "libsvn-local".to_string(),
        });
        self
    }

    fn with_snapshot_remote_entries(mut self, entries: Vec<StatusEntry>) -> Self {
        let local_entries = self
            .snapshot_result
            .as_ref()
            .map(|snapshot| snapshot.local_entries.clone())
            .unwrap_or_default();
        let summary = status_summary_for_entries(&local_entries, &entries);
        self.snapshot_result = Ok(StatusSnapshot {
            repository_id: "repo-uuid:C:/wc".to_string(),
            epoch: 1,
            generation: 1,
            completeness: "complete".to_string(),
            identity: Self::identity(),
            local_entries,
            remote_entries: entries,
            summary,
            timestamp: "2026-06-22T00:00:00Z".to_string(),
            source: "libsvn-local".to_string(),
        });
        self
    }

    fn with_snapshot_result(mut self, snapshot: StatusSnapshot) -> Self {
        self.snapshot_result = Ok(snapshot);
        self
    }

    fn with_remote_entries(mut self, entries: Vec<StatusEntry>) -> Self {
        self.remote_result = Ok(StatusSnapshot {
            repository_id: "repo-uuid:C:/wc".to_string(),
            epoch: 1,
            generation: 1,
            completeness: "complete".to_string(),
            identity: Self::identity(),
            local_entries: Vec::new(),
            summary: status_summary_for_entries(&[], &entries),
            remote_entries: entries,
            timestamp: "2026-06-22T00:00:00Z".to_string(),
            source: "libsvn-remote".to_string(),
        });
        self
    }

    fn with_remote_result(mut self, result: Result<StatusSnapshot, BridgeFailure>) -> Self {
        self.remote_result = result;
        self
    }

    fn with_scan_result(
        mut self,
        path: &str,
        depth: &str,
        result: Result<StatusSnapshot, BridgeFailure>,
    ) -> Self {
        self.scan_results
            .insert((path.to_string(), depth.to_string()), result);
        self
    }

    fn with_content_result(
        mut self,
        path: &str,
        revision: &str,
        result: Result<ContentBlob, BridgeFailure>,
    ) -> Self {
        self.content_results
            .insert((path.to_string(), revision.to_string()), result);
        self
    }

    fn with_properties_result(
        mut self,
        path: &str,
        result: Result<subversionr_daemon::PropertiesListResult, BridgeFailure>,
    ) -> Self {
        self.properties_results.insert(path.to_string(), result);
        self
    }

    fn with_history_result(
        mut self,
        path: &str,
        result: Result<HistoryLogResult, BridgeFailure>,
    ) -> Self {
        self.history_results.insert(path.to_string(), result);
        self
    }

    fn with_history_requires_auth(mut self) -> Self {
        self.history_requires_auth = true;
        self
    }

    fn with_blame_result(
        mut self,
        path: &str,
        result: Result<HistoryBlameResult, BridgeFailure>,
    ) -> Self {
        self.blame_results.insert(path.to_string(), result);
        self
    }

    fn with_blame_requires_auth(mut self) -> Self {
        self.blame_requires_auth = true;
        self
    }

    fn with_revert_result(
        mut self,
        path: &str,
        result: Result<subversionr_daemon::OperationResult, BridgeFailure>,
    ) -> Self {
        self.revert_results.insert(path.to_string(), result);
        self
    }

    fn with_add_result(
        mut self,
        path: &str,
        result: Result<subversionr_daemon::OperationResult, BridgeFailure>,
    ) -> Self {
        self.add_results.insert(path.to_string(), result);
        self
    }

    fn with_remove_result(
        mut self,
        path: &str,
        result: Result<subversionr_daemon::OperationResult, BridgeFailure>,
    ) -> Self {
        self.remove_results.insert(path.to_string(), result);
        self
    }

    fn with_move_result(
        mut self,
        source_path: &str,
        result: Result<subversionr_daemon::OperationResult, BridgeFailure>,
    ) -> Self {
        self.move_results.insert(source_path.to_string(), result);
        self
    }

    fn with_resolve_result(
        mut self,
        path: &str,
        result: Result<subversionr_daemon::OperationResult, BridgeFailure>,
    ) -> Self {
        self.resolve_results.insert(path.to_string(), result);
        self
    }

    fn with_cleanup_result(
        mut self,
        path: &str,
        result: Result<subversionr_daemon::OperationResult, BridgeFailure>,
    ) -> Self {
        self.cleanup_results.insert(path.to_string(), result);
        self
    }

    fn with_upgrade_result(
        mut self,
        path: &str,
        result: Result<subversionr_daemon::OperationResult, BridgeFailure>,
    ) -> Self {
        self.upgrade_results.insert(path.to_string(), result);
        self
    }

    fn with_update_result(
        mut self,
        path: &str,
        result: Result<subversionr_daemon::UpdateOperationResult, BridgeFailure>,
    ) -> Self {
        self.update_results.insert(path.to_string(), result);
        self
    }

    fn with_property_set_result(
        mut self,
        path: &str,
        result: Result<subversionr_daemon::OperationResult, BridgeFailure>,
    ) -> Self {
        self.property_set_results.insert(path.to_string(), result);
        self
    }

    fn with_property_delete_result(
        mut self,
        path: &str,
        result: Result<subversionr_daemon::OperationResult, BridgeFailure>,
    ) -> Self {
        self.property_delete_results
            .insert(path.to_string(), result);
        self
    }

    fn with_changelist_set_result(
        mut self,
        path: &str,
        result: Result<subversionr_daemon::OperationResult, BridgeFailure>,
    ) -> Self {
        self.changelist_set_results.insert(path.to_string(), result);
        self
    }

    fn with_changelist_clear_result(
        mut self,
        path: &str,
        result: Result<subversionr_daemon::OperationResult, BridgeFailure>,
    ) -> Self {
        self.changelist_clear_results
            .insert(path.to_string(), result);
        self
    }

    fn with_lock_result(
        mut self,
        path: &str,
        result: Result<subversionr_daemon::OperationResult, BridgeFailure>,
    ) -> Self {
        self.lock_results.insert(path.to_string(), result);
        self
    }

    fn with_unlock_result(
        mut self,
        path: &str,
        result: Result<subversionr_daemon::OperationResult, BridgeFailure>,
    ) -> Self {
        self.unlock_results.insert(path.to_string(), result);
        self
    }

    fn with_branch_create_result(
        mut self,
        destination_url: &str,
        result: Result<subversionr_daemon::BranchCreateOperationResult, BridgeFailure>,
    ) -> Self {
        self.branch_create_results
            .insert(destination_url.to_string(), result);
        self
    }

    fn with_switch_result(
        mut self,
        path: &str,
        result: Result<subversionr_daemon::SwitchOperationResult, BridgeFailure>,
    ) -> Self {
        self.switch_results.insert(path.to_string(), result);
        self
    }

    fn with_relocate_result(
        mut self,
        from_url: &str,
        result: Result<subversionr_daemon::OperationResult, BridgeFailure>,
    ) -> Self {
        self.relocate_results.insert(from_url.to_string(), result);
        self
    }

    fn with_merge_result(
        mut self,
        target_path: &str,
        result: Result<subversionr_daemon::OperationResult, BridgeFailure>,
    ) -> Self {
        self.merge_results.insert(target_path.to_string(), result);
        self
    }

    fn with_commit_result(
        mut self,
        path: &str,
        result: Result<subversionr_daemon::CommitOperationResult, BridgeFailure>,
    ) -> Self {
        self.commit_results.insert(path.to_string(), result);
        self
    }

    fn with_commit_requires_auth(mut self) -> Self {
        self.commit_requires_auth = true;
        self
    }

    fn scan_failure(path: &str) -> Result<StatusSnapshot, BridgeFailure> {
        Err(BridgeFailure::new(
            "SVN_STATUS_FAILED",
            "native",
            "error.native.statusFailed",
            serde_json::json!({ "path": path }),
            false,
        ))
    }

    fn scan_cancelled(path: &str) -> Result<StatusSnapshot, BridgeFailure> {
        Err(BridgeFailure::new(
            "SVN_STATUS_CANCELLED",
            "cancelled",
            "error.native.statusCancelled",
            serde_json::json!({ "path": path, "status": 11 }),
            false,
        ))
    }

    fn scan_success(
        path: &str,
        entries: Vec<StatusEntry>,
    ) -> Result<StatusSnapshot, BridgeFailure> {
        Self::scan_success_with_remote_entries(path, entries, Vec::new())
    }

    fn scan_success_with_remote_entries(
        path: &str,
        entries: Vec<StatusEntry>,
        remote_entries: Vec<StatusEntry>,
    ) -> Result<StatusSnapshot, BridgeFailure> {
        Ok(StatusSnapshot {
            repository_id: "repo-uuid:C:/wc".to_string(),
            epoch: 1,
            generation: 1,
            completeness: "partial".to_string(),
            identity: Self::identity(),
            summary: status_summary_for_entries(&entries, &remote_entries),
            local_entries: entries,
            remote_entries,
            timestamp: "2026-06-22T00:00:00Z".to_string(),
            source: format!("fake-scan:{path}"),
        })
    }

    fn open_failure() -> Self {
        Self {
            open_result: Err(BridgeFailure::new(
                "SVN_WC_NOT_FOUND",
                "native",
                "error.native.workingCopyNotFound",
                serde_json::json!({ "path": "C:\\missing" }),
                false,
            )),
            open_results: BTreeMap::new(),
            relocated_identity: RefCell::new(None),
            snapshot_result: Err(BridgeFailure::new(
                "SVN_WC_NOT_FOUND",
                "native",
                "error.native.workingCopyNotFound",
                serde_json::json!({ "path": "C:\\missing" }),
                false,
            )),
            remote_result: Err(BridgeFailure::new(
                "SVN_REMOTE_STATUS_FAILED",
                "network",
                "error.native.remoteStatusFailed",
                serde_json::json!({ "path": "C:\\missing" }),
                false,
            )),
            remote_requests: RefCell::new(0),
            scan_results: BTreeMap::new(),
            content_results: BTreeMap::new(),
            properties_results: BTreeMap::new(),
            properties_requests: RefCell::new(Vec::new()),
            history_results: BTreeMap::new(),
            history_requests: RefCell::new(Vec::new()),
            blame_results: BTreeMap::new(),
            blame_requests: RefCell::new(Vec::new()),
            checkout_results: BTreeMap::new(),
            checkout_requests: RefCell::new(Vec::new()),
            revert_results: BTreeMap::new(),
            add_results: BTreeMap::new(),
            add_requests: RefCell::new(Vec::new()),
            remove_results: BTreeMap::new(),
            remove_requests: RefCell::new(Vec::new()),
            move_results: BTreeMap::new(),
            move_requests: RefCell::new(Vec::new()),
            resolve_results: BTreeMap::new(),
            resolve_requests: RefCell::new(Vec::new()),
            cleanup_results: BTreeMap::new(),
            cleanup_requests: RefCell::new(Vec::new()),
            upgrade_results: BTreeMap::new(),
            upgrade_requests: RefCell::new(Vec::new()),
            update_results: BTreeMap::new(),
            update_requests: RefCell::new(Vec::new()),
            property_set_results: BTreeMap::new(),
            property_set_requests: RefCell::new(Vec::new()),
            property_delete_results: BTreeMap::new(),
            property_delete_requests: RefCell::new(Vec::new()),
            changelist_set_results: BTreeMap::new(),
            changelist_set_requests: RefCell::new(Vec::new()),
            changelist_clear_results: BTreeMap::new(),
            changelist_clear_requests: RefCell::new(Vec::new()),
            lock_results: BTreeMap::new(),
            lock_requests: RefCell::new(Vec::new()),
            unlock_results: BTreeMap::new(),
            unlock_requests: RefCell::new(Vec::new()),
            branch_create_results: BTreeMap::new(),
            branch_create_requests: RefCell::new(Vec::new()),
            switch_results: BTreeMap::new(),
            switch_requests: RefCell::new(Vec::new()),
            relocate_results: BTreeMap::new(),
            relocate_requests: RefCell::new(Vec::new()),
            merge_results: BTreeMap::new(),
            merge_requests: RefCell::new(Vec::new()),
            commit_results: BTreeMap::new(),
            commit_requests: RefCell::new(Vec::new()),
            history_requires_auth: false,
            blame_requires_auth: false,
            commit_requires_auth: false,
        }
    }
}

fn status_summary_for_entries(
    local_entries: &[StatusEntry],
    remote_entries: &[StatusEntry],
) -> StatusSummary {
    StatusSummary {
        local_changes: local_entries.len() as u32,
        remote_changes: remote_entries
            .iter()
            .filter(|entry| {
                !matches!(
                    entry.remote_status.as_str(),
                    "none" | "normal" | "notChecked"
                )
            })
            .count() as u32,
        conflicts: local_entries
            .iter()
            .filter(|entry| entry.conflict.is_some())
            .count() as u32,
        unversioned: local_entries
            .iter()
            .filter(|entry| entry.local_status == "unversioned")
            .count() as u32,
    }
}

#[derive(Debug)]
struct DiscoveryTempTree {
    path: PathBuf,
}

impl DiscoveryTempTree {
    fn create(name: &str) -> Self {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock should be after the Unix epoch")
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "subversionr-rpc-discovery-{name}-{}-{unique}",
            std::process::id()
        ));
        if path.exists() {
            fs::remove_dir_all(&path).expect("stale discovery temp tree should be removable");
        }
        fs::create_dir_all(&path).expect("discovery temp tree should be created");
        Self { path }
    }

    fn working_copy(&self, relative_path: &str) -> PathBuf {
        let path = self.path.join(relative_path);
        fs::create_dir_all(path.join(".svn")).expect("fake working copy marker should be created");
        path
    }
}

impl Drop for DiscoveryTempTree {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

fn open_result_key(path: &str) -> String {
    path.replace('\\', "/").trim_end_matches('/').to_string()
}

impl BridgeApi for FakeBridge {
    fn info(&self) -> BridgeInfo {
        BridgeInfo::available("subversionr-svn-bridge/0.1.0-test", "1.14.5 (r1922182)")
    }

    fn open_working_copy(&self, path: &str) -> Result<RepositoryIdentity, BridgeFailure> {
        if let Some(identity) = self.relocated_identity.borrow().as_ref() {
            if open_result_key(&identity.working_copy_root) == open_result_key(path) {
                return Ok(identity.clone());
            }
        }
        if let Some(result) = self.open_results.get(&open_result_key(path)) {
            return result.clone();
        }
        self.open_result.clone()
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
        _cancellation: &dyn subversionr_daemon::BridgeCancellationToken,
    ) -> Result<StatusSnapshot, BridgeFailure> {
        self.snapshot_result.clone().map(|mut snapshot| {
            snapshot.repository_id = format!(
                "{}:{}",
                identity.repository_uuid, identity.working_copy_root
            );
            snapshot.identity = identity.clone();
            snapshot.generation = generation;
            for entry in &mut snapshot.local_entries {
                entry.generation = generation;
            }
            for entry in &mut snapshot.remote_entries {
                entry.generation = generation;
            }
            snapshot
        })
    }

    fn status_scan(
        &self,
        identity: &RepositoryIdentity,
        path: &str,
        depth: &str,
        generation: u64,
    ) -> Result<StatusSnapshot, BridgeFailure> {
        self.status_scan_with_cancellation(
            identity,
            path,
            depth,
            generation,
            &subversionr_daemon::NeverCancelled,
        )
    }

    fn status_scan_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        path: &str,
        depth: &str,
        generation: u64,
        _cancellation: &dyn subversionr_daemon::BridgeCancellationToken,
    ) -> Result<StatusSnapshot, BridgeFailure> {
        let result = self
            .scan_results
            .get(&(path.to_string(), depth.to_string()))
            .cloned()
            .unwrap_or_else(|| FakeBridge::scan_failure(path));
        result.map(|mut snapshot| {
            snapshot.repository_id = format!(
                "{}:{}",
                identity.repository_uuid, identity.working_copy_root
            );
            snapshot.identity = identity.clone();
            snapshot.generation = generation;
            for entry in &mut snapshot.local_entries {
                entry.generation = generation;
            }
            snapshot
        })
    }

    fn status_remote_check_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        generation: u64,
        _auth: &mut dyn subversionr_daemon::AuthRequestBroker,
        _cancellation: &dyn subversionr_daemon::BridgeCancellationToken,
    ) -> Result<StatusSnapshot, BridgeFailure> {
        *self.remote_requests.borrow_mut() += 1;
        self.remote_result.clone().map(|mut snapshot| {
            snapshot.repository_id = format!(
                "{}:{}",
                identity.repository_uuid, identity.working_copy_root
            );
            snapshot.identity = identity.clone();
            snapshot.generation = generation;
            for entry in &mut snapshot.remote_entries {
                entry.generation = generation;
            }
            snapshot
        })
    }

    fn content_get(
        &self,
        _identity: &RepositoryIdentity,
        path: &str,
        revision: &str,
        _auth: &mut dyn subversionr_daemon::AuthRequestBroker,
    ) -> Result<ContentBlob, BridgeFailure> {
        self.content_results
            .get(&(path.to_string(), revision.to_string()))
            .cloned()
            .unwrap_or_else(|| {
                Err(BridgeFailure::new(
                    "SVN_CONTENT_FAILED",
                    "native",
                    "error.native.contentFailed",
                    serde_json::json!({ "path": path, "revision": revision }),
                    false,
                ))
            })
    }

    fn properties_list(
        &self,
        _identity: &RepositoryIdentity,
        path: &str,
    ) -> Result<subversionr_daemon::PropertiesListResult, BridgeFailure> {
        self.properties_requests.borrow_mut().push(path.to_string());
        self.properties_results
            .get(path)
            .cloned()
            .unwrap_or_else(|| {
                Err(BridgeFailure::new(
                    "SVN_PROPERTIES_LIST_FAILED",
                    "native",
                    "error.native.propertiesListFailed",
                    serde_json::json!({ "path": path }),
                    false,
                ))
            })
    }

    fn history_log(
        &self,
        identity: &RepositoryIdentity,
        request: &HistoryLogRequest,
        auth: &mut dyn subversionr_daemon::AuthRequestBroker,
    ) -> Result<HistoryLogResult, BridgeFailure> {
        self.history_requests.borrow_mut().push(request.clone());
        if self.history_requires_auth {
            auth.request_credential(CredentialRequest {
                request_id: "history-log-dispatch-cred-1".to_string(),
                realm: "svn://example/history-log".to_string(),
                kind: "usernamePassword".to_string(),
                username: Some("alice".to_string()),
                interactive: true,
                persistence_allowed: true,
                origin: "foreground".to_string(),
                timeout_ms: 30000,
                repository_id: Some(format!(
                    "{}:{}",
                    identity.repository_uuid, identity.working_copy_root
                )),
                working_copy_root: Some(identity.working_copy_root.clone()),
            })?;
        }
        self.history_results
            .get(&request.path)
            .cloned()
            .unwrap_or_else(|| {
                Err(BridgeFailure::new(
                    "SVN_HISTORY_LOG_FAILED",
                    "native",
                    "error.native.historyLogFailed",
                    serde_json::json!({ "path": request.path }),
                    false,
                ))
            })
    }

    fn history_blame(
        &self,
        identity: &RepositoryIdentity,
        request: &HistoryBlameRequest,
        auth: &mut dyn subversionr_daemon::AuthRequestBroker,
    ) -> Result<HistoryBlameResult, BridgeFailure> {
        self.blame_requests.borrow_mut().push(request.clone());
        if self.blame_requires_auth {
            auth.request_credential(CredentialRequest {
                request_id: "history-blame-dispatch-cred-1".to_string(),
                realm: "svn://example/history-blame".to_string(),
                kind: "usernamePassword".to_string(),
                username: Some("alice".to_string()),
                interactive: true,
                persistence_allowed: true,
                origin: "foreground".to_string(),
                timeout_ms: 30000,
                repository_id: Some(format!(
                    "{}:{}",
                    identity.repository_uuid, identity.working_copy_root
                )),
                working_copy_root: Some(identity.working_copy_root.clone()),
            })?;
        }
        self.blame_results
            .get(&request.path)
            .cloned()
            .unwrap_or_else(|| {
                Err(BridgeFailure::new(
                    "SVN_HISTORY_BLAME_FAILED",
                    "native",
                    "error.native.historyBlameFailed",
                    serde_json::json!({ "path": request.path }),
                    false,
                ))
            })
    }

    fn repository_checkout_with_cancellation(
        &self,
        request: &subversionr_daemon::RepositoryCheckoutRequest,
        _auth: &mut dyn subversionr_daemon::AuthRequestBroker,
        _cancellation: &dyn subversionr_daemon::BridgeCancellationToken,
    ) -> Result<subversionr_daemon::RepositoryCheckoutResult, BridgeFailure> {
        self.checkout_requests.borrow_mut().push(request.clone());
        self.checkout_results
            .get(&request.url)
            .cloned()
            .unwrap_or_else(|| {
                Err(BridgeFailure::new(
                    "SVN_CHECKOUT_FAILED",
                    "native",
                    "error.native.checkoutFailed",
                    serde_json::json!({ "path": request.target_path }),
                    false,
                ))
            })
    }

    fn operation_revert(
        &self,
        _identity: &RepositoryIdentity,
        request: &subversionr_daemon::RevertOperationRequest,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        let first_path = request.paths.first().cloned().unwrap_or_default();
        self.revert_results
            .get(&first_path)
            .cloned()
            .unwrap_or_else(|| {
                Err(BridgeFailure::new(
                    "SVN_OPERATION_FAILED",
                    "native",
                    "error.native.operationFailed",
                    serde_json::json!({ "path": first_path, "kind": "revert" }),
                    false,
                ))
            })
    }

    fn operation_revert_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &subversionr_daemon::RevertOperationRequest,
        _cancellation: &dyn subversionr_daemon::BridgeCancellationToken,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.operation_revert(identity, request)
    }

    fn operation_add(
        &self,
        _identity: &RepositoryIdentity,
        request: &subversionr_daemon::AddOperationRequest,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.add_requests.borrow_mut().push(request.clone());
        let first_path = request.paths.first().cloned().unwrap_or_default();
        self.add_results
            .get(&first_path)
            .cloned()
            .unwrap_or_else(|| {
                Err(BridgeFailure::new(
                    "SVN_OPERATION_FAILED",
                    "native",
                    "error.native.operationFailed",
                    serde_json::json!({ "path": first_path, "kind": "add" }),
                    false,
                ))
            })
    }

    fn operation_add_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &subversionr_daemon::AddOperationRequest,
        _cancellation: &dyn subversionr_daemon::BridgeCancellationToken,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.operation_add(identity, request)
    }

    fn operation_remove(
        &self,
        _identity: &RepositoryIdentity,
        request: &subversionr_daemon::RemoveOperationRequest,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.remove_requests.borrow_mut().push(request.clone());
        let first_path = request.paths.first().cloned().unwrap_or_default();
        self.remove_results
            .get(&first_path)
            .cloned()
            .unwrap_or_else(|| {
                Err(BridgeFailure::new(
                    "SVN_OPERATION_FAILED",
                    "native",
                    "error.native.operationFailed",
                    serde_json::json!({ "path": first_path, "kind": "remove" }),
                    false,
                ))
            })
    }

    fn operation_remove_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &subversionr_daemon::RemoveOperationRequest,
        _cancellation: &dyn subversionr_daemon::BridgeCancellationToken,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.operation_remove(identity, request)
    }

    fn operation_move(
        &self,
        _identity: &RepositoryIdentity,
        request: &subversionr_daemon::MoveOperationRequest,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.move_requests.borrow_mut().push(request.clone());
        self.move_results
            .get(&request.source_path)
            .cloned()
            .unwrap_or_else(|| {
                Err(BridgeFailure::new(
                    "SVN_OPERATION_MOVE_FAILED",
                    "native",
                    "error.native.operationMoveFailed",
                    serde_json::json!({
                        "sourcePath": request.source_path,
                        "destinationPath": request.destination_path,
                        "kind": "move",
                    }),
                    false,
                ))
            })
    }

    fn operation_move_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &subversionr_daemon::MoveOperationRequest,
        _cancellation: &dyn subversionr_daemon::BridgeCancellationToken,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.operation_move(identity, request)
    }

    fn operation_resolve(
        &self,
        _identity: &RepositoryIdentity,
        request: &subversionr_daemon::ResolveOperationRequest,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.resolve_requests.borrow_mut().push(request.clone());
        let first_path = request.paths.first().cloned().unwrap_or_default();
        self.resolve_results
            .get(&first_path)
            .cloned()
            .unwrap_or_else(|| {
                Err(BridgeFailure::new(
                    "SVN_OPERATION_FAILED",
                    "native",
                    "error.native.operationFailed",
                    serde_json::json!({ "path": first_path, "kind": "resolve" }),
                    false,
                ))
            })
    }

    fn operation_resolve_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &subversionr_daemon::ResolveOperationRequest,
        _cancellation: &dyn subversionr_daemon::BridgeCancellationToken,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.operation_resolve(identity, request)
    }

    fn operation_cleanup(
        &self,
        _identity: &RepositoryIdentity,
        request: &subversionr_daemon::CleanupOperationRequest,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.cleanup_requests.borrow_mut().push(request.clone());
        self.cleanup_results
            .get(&request.path)
            .cloned()
            .unwrap_or_else(|| {
                Err(BridgeFailure::new(
                    "SVN_OPERATION_FAILED",
                    "native",
                    "error.native.operationFailed",
                    serde_json::json!({ "path": request.path, "kind": "cleanup" }),
                    false,
                ))
            })
    }

    fn operation_cleanup_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &subversionr_daemon::CleanupOperationRequest,
        _cancellation: &dyn subversionr_daemon::BridgeCancellationToken,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.operation_cleanup(identity, request)
    }

    fn operation_upgrade(
        &self,
        _identity: &RepositoryIdentity,
        request: &subversionr_daemon::UpgradeOperationRequest,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.upgrade_requests.borrow_mut().push(request.clone());
        self.upgrade_results
            .get(&request.path)
            .cloned()
            .unwrap_or_else(|| {
                Err(BridgeFailure::new(
                    "SVN_OPERATION_FAILED",
                    "native",
                    "error.native.operationFailed",
                    serde_json::json!({ "path": request.path, "kind": "upgrade" }),
                    false,
                ))
            })
    }

    fn operation_upgrade_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &subversionr_daemon::UpgradeOperationRequest,
        _cancellation: &dyn subversionr_daemon::BridgeCancellationToken,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.operation_upgrade(identity, request)
    }

    fn operation_update(
        &self,
        _identity: &RepositoryIdentity,
        request: &subversionr_daemon::UpdateOperationRequest,
        _auth: &mut dyn subversionr_daemon::AuthRequestBroker,
    ) -> Result<subversionr_daemon::UpdateOperationResult, BridgeFailure> {
        self.update_requests.borrow_mut().push(request.clone());
        self.update_results
            .get(&request.path)
            .cloned()
            .unwrap_or_else(|| {
                Err(BridgeFailure::new(
                    "SVN_OPERATION_UPDATE_FAILED",
                    "native",
                    "error.native.operationUpdateFailed",
                    serde_json::json!({ "path": request.path, "kind": "update" }),
                    false,
                ))
            })
    }

    fn operation_update_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &subversionr_daemon::UpdateOperationRequest,
        auth: &mut dyn subversionr_daemon::AuthRequestBroker,
        _cancellation: &dyn subversionr_daemon::BridgeCancellationToken,
    ) -> Result<subversionr_daemon::UpdateOperationResult, BridgeFailure> {
        self.operation_update(identity, request, auth)
    }

    fn operation_property_set(
        &self,
        _identity: &RepositoryIdentity,
        request: &subversionr_daemon::PropertySetOperationRequest,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.property_set_requests
            .borrow_mut()
            .push(request.clone());
        self.property_set_results
            .get(&request.path)
            .cloned()
            .unwrap_or_else(|| {
                Err(BridgeFailure::new(
                    "SVN_OPERATION_PROPERTY_SET_FAILED",
                    "native",
                    "error.native.operationPropertySetFailed",
                    serde_json::json!({
                        "path": request.path,
                        "name": request.name,
                        "kind": "propertySet",
                    }),
                    false,
                ))
            })
    }

    fn operation_property_set_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &subversionr_daemon::PropertySetOperationRequest,
        _cancellation: &dyn subversionr_daemon::BridgeCancellationToken,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.operation_property_set(identity, request)
    }

    fn operation_property_delete(
        &self,
        _identity: &RepositoryIdentity,
        request: &subversionr_daemon::PropertyDeleteOperationRequest,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.property_delete_requests
            .borrow_mut()
            .push(request.clone());
        self.property_delete_results
            .get(&request.path)
            .cloned()
            .unwrap_or_else(|| {
                Err(BridgeFailure::new(
                    "SVN_OPERATION_PROPERTY_DELETE_FAILED",
                    "native",
                    "error.native.operationPropertyDeleteFailed",
                    serde_json::json!({
                        "path": request.path,
                        "name": request.name,
                        "kind": "propertyDelete",
                    }),
                    false,
                ))
            })
    }

    fn operation_property_delete_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &subversionr_daemon::PropertyDeleteOperationRequest,
        _cancellation: &dyn subversionr_daemon::BridgeCancellationToken,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.operation_property_delete(identity, request)
    }

    fn operation_changelist_set(
        &self,
        _identity: &RepositoryIdentity,
        request: &subversionr_daemon::ChangelistSetOperationRequest,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.changelist_set_requests
            .borrow_mut()
            .push(request.clone());
        let first_path = request.paths.first().cloned().unwrap_or_default();
        self.changelist_set_results
            .get(&first_path)
            .cloned()
            .unwrap_or_else(|| {
                Err(BridgeFailure::new(
                    "SVN_OPERATION_CHANGELIST_SET_FAILED",
                    "native",
                    "error.native.operationChangelistSetFailed",
                    serde_json::json!({
                        "path": first_path,
                        "changelist": request.changelist,
                        "kind": "changelistSet",
                    }),
                    false,
                ))
            })
    }

    fn operation_changelist_set_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &subversionr_daemon::ChangelistSetOperationRequest,
        _cancellation: &dyn subversionr_daemon::BridgeCancellationToken,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.operation_changelist_set(identity, request)
    }

    fn operation_changelist_clear(
        &self,
        _identity: &RepositoryIdentity,
        request: &subversionr_daemon::ChangelistClearOperationRequest,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.changelist_clear_requests
            .borrow_mut()
            .push(request.clone());
        let first_path = request.paths.first().cloned().unwrap_or_default();
        self.changelist_clear_results
            .get(&first_path)
            .cloned()
            .unwrap_or_else(|| {
                Err(BridgeFailure::new(
                    "SVN_OPERATION_CHANGELIST_CLEAR_FAILED",
                    "native",
                    "error.native.operationChangelistClearFailed",
                    serde_json::json!({
                        "path": first_path,
                        "kind": "changelistClear",
                    }),
                    false,
                ))
            })
    }

    fn operation_changelist_clear_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &subversionr_daemon::ChangelistClearOperationRequest,
        _cancellation: &dyn subversionr_daemon::BridgeCancellationToken,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.operation_changelist_clear(identity, request)
    }

    fn operation_lock(
        &self,
        _identity: &RepositoryIdentity,
        request: &subversionr_daemon::LockOperationRequest,
        _auth: &mut dyn subversionr_daemon::AuthRequestBroker,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.lock_requests.borrow_mut().push(request.clone());
        let first_path = request.paths.first().cloned().unwrap_or_default();
        self.lock_results
            .get(&first_path)
            .cloned()
            .unwrap_or_else(|| {
                Err(BridgeFailure::new(
                    "SVN_OPERATION_LOCK_FAILED",
                    "native",
                    "error.native.operationLockFailed",
                    serde_json::json!({ "path": first_path, "kind": "lock" }),
                    false,
                ))
            })
    }

    fn operation_lock_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &subversionr_daemon::LockOperationRequest,
        auth: &mut dyn subversionr_daemon::AuthRequestBroker,
        _cancellation: &dyn subversionr_daemon::BridgeCancellationToken,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.operation_lock(identity, request, auth)
    }

    fn operation_unlock(
        &self,
        _identity: &RepositoryIdentity,
        request: &subversionr_daemon::UnlockOperationRequest,
        _auth: &mut dyn subversionr_daemon::AuthRequestBroker,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.unlock_requests.borrow_mut().push(request.clone());
        let first_path = request.paths.first().cloned().unwrap_or_default();
        self.unlock_results
            .get(&first_path)
            .cloned()
            .unwrap_or_else(|| {
                Err(BridgeFailure::new(
                    "SVN_OPERATION_UNLOCK_FAILED",
                    "native",
                    "error.native.operationUnlockFailed",
                    serde_json::json!({ "path": first_path, "kind": "unlock" }),
                    false,
                ))
            })
    }

    fn operation_unlock_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &subversionr_daemon::UnlockOperationRequest,
        auth: &mut dyn subversionr_daemon::AuthRequestBroker,
        _cancellation: &dyn subversionr_daemon::BridgeCancellationToken,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.operation_unlock(identity, request, auth)
    }

    fn operation_branch_create(
        &self,
        _identity: &RepositoryIdentity,
        request: &subversionr_daemon::BranchCreateOperationRequest,
        _auth: &mut dyn subversionr_daemon::AuthRequestBroker,
    ) -> Result<subversionr_daemon::BranchCreateOperationResult, BridgeFailure> {
        self.branch_create_requests
            .borrow_mut()
            .push(request.clone());
        self.branch_create_results
            .get(&request.destination_url)
            .cloned()
            .unwrap_or_else(|| {
                Err(BridgeFailure::new(
                    "SVN_OPERATION_BRANCH_CREATE_FAILED",
                    "native",
                    "error.native.operationBranchCreateFailed",
                    serde_json::json!({
                        "path": request.destination_url,
                        "kind": "branchCreate",
                    }),
                    false,
                ))
            })
    }

    fn operation_branch_create_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &subversionr_daemon::BranchCreateOperationRequest,
        auth: &mut dyn subversionr_daemon::AuthRequestBroker,
        _cancellation: &dyn subversionr_daemon::BridgeCancellationToken,
    ) -> Result<subversionr_daemon::BranchCreateOperationResult, BridgeFailure> {
        self.operation_branch_create(identity, request, auth)
    }

    fn operation_switch(
        &self,
        _identity: &RepositoryIdentity,
        request: &subversionr_daemon::SwitchOperationRequest,
        _auth: &mut dyn subversionr_daemon::AuthRequestBroker,
    ) -> Result<subversionr_daemon::SwitchOperationResult, BridgeFailure> {
        self.switch_requests.borrow_mut().push(request.clone());
        self.switch_results
            .get(&request.path)
            .cloned()
            .unwrap_or_else(|| {
                Err(BridgeFailure::new(
                    "SVN_OPERATION_SWITCH_FAILED",
                    "native",
                    "error.native.operationSwitchFailed",
                    serde_json::json!({
                        "path": request.path,
                        "kind": "switch",
                    }),
                    false,
                ))
            })
    }

    fn operation_switch_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &subversionr_daemon::SwitchOperationRequest,
        auth: &mut dyn subversionr_daemon::AuthRequestBroker,
        _cancellation: &dyn subversionr_daemon::BridgeCancellationToken,
    ) -> Result<subversionr_daemon::SwitchOperationResult, BridgeFailure> {
        self.operation_switch(identity, request, auth)
    }

    fn operation_relocate(
        &self,
        _identity: &RepositoryIdentity,
        request: &subversionr_daemon::RelocateOperationRequest,
        _auth: &mut dyn subversionr_daemon::AuthRequestBroker,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.relocate_requests.borrow_mut().push(request.clone());
        let result = self
            .relocate_results
            .get(&request.from_url)
            .cloned()
            .unwrap_or_else(|| {
                Err(BridgeFailure::new(
                    "SVN_OPERATION_RELOCATE_FAILED",
                    "native",
                    "error.native.operationRelocateFailed",
                    serde_json::json!({
                        "path": request.from_url,
                        "kind": "relocate",
                    }),
                    false,
                ))
            });
        if result.is_ok() {
            let mut relocated_identity = _identity.clone();
            relocated_identity.repository_root_url = request.to_url.clone();
            *self.relocated_identity.borrow_mut() = Some(relocated_identity);
        }
        result
    }

    fn operation_relocate_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &subversionr_daemon::RelocateOperationRequest,
        auth: &mut dyn subversionr_daemon::AuthRequestBroker,
        _cancellation: &dyn subversionr_daemon::BridgeCancellationToken,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.operation_relocate(identity, request, auth)
    }

    fn operation_merge(
        &self,
        _identity: &RepositoryIdentity,
        request: &subversionr_daemon::MergeOperationRequest,
        _auth: &mut dyn subversionr_daemon::AuthRequestBroker,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.merge_requests.borrow_mut().push(request.clone());
        self.merge_results
            .get(&request.target_path)
            .cloned()
            .unwrap_or_else(|| {
                Ok(subversionr_daemon::OperationResult {
                    touched_paths: vec![request.target_path.clone()],
                    skipped_paths: Vec::new(),
                })
            })
    }

    fn operation_merge_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &subversionr_daemon::MergeOperationRequest,
        auth: &mut dyn subversionr_daemon::AuthRequestBroker,
        _cancellation: &dyn subversionr_daemon::BridgeCancellationToken,
    ) -> Result<subversionr_daemon::OperationResult, BridgeFailure> {
        self.operation_merge(identity, request, auth)
    }

    fn operation_commit(
        &self,
        identity: &RepositoryIdentity,
        request: &subversionr_daemon::CommitOperationRequest,
        auth: &mut dyn subversionr_daemon::AuthRequestBroker,
    ) -> Result<subversionr_daemon::CommitOperationResult, BridgeFailure> {
        self.commit_requests.borrow_mut().push(request.clone());
        if self.commit_requires_auth {
            auth.request_credential(subversionr_protocol::CredentialRequest {
                request_id: "commit-dispatch-cred-1".to_string(),
                realm: "svn://example/commit".to_string(),
                kind: "usernamePassword".to_string(),
                username: Some("alice".to_string()),
                interactive: true,
                persistence_allowed: true,
                origin: "foreground".to_string(),
                timeout_ms: 30000,
                repository_id: Some(format!(
                    "{}:{}",
                    identity.repository_uuid, identity.working_copy_root
                )),
                working_copy_root: Some(identity.working_copy_root.clone()),
            })?;
        }
        let first_path = request.paths.first().cloned().unwrap_or_default();
        self.commit_results
            .get(&first_path)
            .cloned()
            .unwrap_or_else(|| {
                Err(BridgeFailure::new(
                    "SVN_OPERATION_COMMIT_FAILED",
                    "native",
                    "error.native.operationCommitFailed",
                    serde_json::json!({ "path": first_path, "kind": "commit" }),
                    false,
                ))
            })
    }

    fn operation_commit_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &subversionr_daemon::CommitOperationRequest,
        auth: &mut dyn subversionr_daemon::AuthRequestBroker,
        _cancellation: &dyn subversionr_daemon::BridgeCancellationToken,
    ) -> Result<subversionr_daemon::CommitOperationResult, BridgeFailure> {
        self.operation_commit(identity, request, auth)
    }
}

#[test]
fn initialize_request_returns_versions_and_keeps_process_running() {
    let request = r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","cacheRoot":"C:/Users/Alice/AppData/Roaming/Code/User/globalStorage/subversionr/cache"}}"#;
    let bridge = FakeBridge::open_success();

    let outcome =
        dispatch_json_rpc_with_bridge(request, &bridge).expect("initialize should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["id"], 1);
    assert_eq!(outcome.response()["result"]["protocol"]["major"], 1);
    assert_eq!(outcome.response()["result"]["protocol"]["minor"], 28);
    assert_eq!(
        outcome.response()["result"]["cacheSchema"]["schemaId"],
        "subversionr.cache.v1"
    );
    assert_eq!(outcome.response()["result"]["protocol"]["major"], 1);
    assert_eq!(outcome.response()["result"]["protocol"]["minor"], 28);
    assert_eq!(outcome.response()["result"]["cacheSchema"]["version"], 1);
    assert_eq!(
        outcome.response()["result"]["cacheSchema"]["rollback"],
        "delete-and-reconcile"
    );
    assert_eq!(
        outcome.response()["result"]["bridgeVersion"],
        "subversionr-svn-bridge/0.1.0-test"
    );
    assert_eq!(
        outcome.response()["result"]["libsvnVersion"],
        "1.14.5 (r1922182)"
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["repositoryOpen"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["repositoryDiscover"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["repositoryClose"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["statusSnapshot"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["statusRemoteCheck"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["statusStaleNotification"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["realLibsvnBridge"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["historyLog"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["historyBlame"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["operationRunAdd"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["operationRunRemove"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["operationRunMove"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["operationRunCleanup"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["operationRunResolve"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["operationRunUpdate"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["operationRunUpdateSelectedPath"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["operationRunUpdateToRevision"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["operationRunUpdateDepth"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["operationRunUpdateExternalsPolicy"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["operationRunCommit"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["operationRunChangelistSet"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["operationRunChangelistClear"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["operationRunLock"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["operationRunUnlock"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["operationRunBranchCreate"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["operationRunSwitch"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["diagnosticsGet"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["credentialRequest"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["certificateRequest"],
        true
    );
}

#[test]
fn initialize_request_requires_cache_root_param() {
    let request = r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted"}}"#;
    let bridge = FakeBridge::open_success();

    let outcome =
        dispatch_json_rpc_with_bridge(request, &bridge).expect("initialize should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["id"], 1);
    assert_eq!(outcome.response()["error"]["code"], "RPC_INVALID_PARAMS");
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.rpc.invalidParams"
    );
    assert_eq!(outcome.response()["error"]["args"]["field"], "cacheRoot");
}

#[test]
fn initialize_request_rejects_relative_cache_root_param() {
    let request = r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","cacheRoot":"subversionr/cache"}}"#;
    let bridge = FakeBridge::open_success();

    let outcome =
        dispatch_json_rpc_with_bridge(request, &bridge).expect("initialize should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["id"], 1);
    assert_eq!(outcome.response()["error"]["code"], "RPC_INVALID_PARAMS");
    assert_eq!(outcome.response()["error"]["args"]["field"], "cacheRoot");
}

#[test]
fn diagnostics_get_returns_versions_platform_and_safe_counts() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    let open_request =
        r#"{"jsonrpc":"2.0","id":41,"method":"repository/open","params":{"path":"C:/wc"}}"#;
    state
        .dispatch_json_rpc_with_bridge(open_request, &bridge)
        .expect("repository/open should dispatch");
    let request = r#"{"jsonrpc":"2.0","id":42,"method":"diagnostics/get","params":{}}"#;

    let outcome = state
        .dispatch_json_rpc_with_bridge(request, &bridge)
        .expect("diagnostics/get should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["id"], 42);
    assert_eq!(
        outcome.response()["result"]["backendVersion"],
        env!("CARGO_PKG_VERSION")
    );
    assert_eq!(
        outcome.response()["result"]["bridgeVersion"],
        "subversionr-svn-bridge/0.1.0-test"
    );
    assert_eq!(
        outcome.response()["result"]["libsvnVersion"],
        "1.14.5 (r1922182)"
    );
    assert_eq!(
        outcome.response()["result"]["cacheSchema"]["schemaId"],
        "subversionr.cache.v1"
    );
    assert_eq!(outcome.response()["result"]["cacheSchema"]["version"], 1);
    assert_eq!(
        outcome.response()["result"]["cacheSchema"]["rollback"],
        "delete-and-reconcile"
    );
    assert_eq!(
        outcome.response()["result"]["capabilities"]["diagnosticsGet"],
        true
    );
    assert_eq!(
        outcome.response()["result"]["repositorySummary"]["openRepositories"],
        1
    );
    assert_eq!(
        outcome.response()["result"]["repositorySummary"]["cachedLocalEntries"],
        0
    );
    assert_eq!(
        outcome.response()["result"]["backendStderr"]["truncated"],
        false
    );
    assert_eq!(
        outcome.response()["result"]["backendStderr"]["text"],
        serde_json::Value::Null
    );
    assert_eq!(outcome.response()["result"]["source"], "subversionr-daemon");
}

#[test]
fn diagnostics_get_rejects_unexpected_params() {
    let request =
        r#"{"jsonrpc":"2.0","id":43,"method":"diagnostics/get","params":{"path":"C:/wc"}}"#;

    let outcome = dispatch_json_rpc(request).expect("diagnostics/get should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["error"]["code"], "RPC_INVALID_PARAMS");
    assert_eq!(outcome.response()["error"]["category"], "protocol");
    assert_eq!(outcome.response()["error"]["args"]["field"], "path");
}

#[test]
fn shutdown_request_returns_shutdown_outcome() {
    let request = r#"{"jsonrpc":"2.0","id":2,"method":"shutdown","params":{}}"#;

    let outcome = dispatch_json_rpc(request).expect("shutdown should dispatch");

    assert_eq!(outcome, DispatchOutcome::Shutdown);
    assert_eq!(outcome.response()["id"], 2);
    assert_eq!(outcome.response()["result"]["accepted"], true);
}

#[test]
fn unknown_method_returns_structured_error() {
    let request = r#"{"jsonrpc":"2.0","id":3,"method":"missing/method","params":{}}"#;

    let outcome = dispatch_json_rpc(request).expect("unknown method should produce response");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["error"]["code"], "RPC_METHOD_NOT_FOUND");
    assert_eq!(outcome.response()["error"]["category"], "unsupported");
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.rpc.methodNotFound"
    );
}

#[test]
fn repository_open_requires_a_path_param() {
    let request = r#"{"jsonrpc":"2.0","id":4,"method":"repository/open","params":{}}"#;

    let outcome = dispatch_json_rpc(request).expect("repository/open should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["error"]["code"], "RPC_INVALID_PARAMS");
    assert_eq!(outcome.response()["error"]["category"], "protocol");
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.rpc.invalidParams"
    );
}

#[test]
fn repository_open_returns_structured_error_until_bridge_is_loaded() {
    let request =
        r#"{"jsonrpc":"2.0","id":5,"method":"repository/open","params":{"path":"C:\\wc"}}"#;

    let outcome = dispatch_json_rpc(request).expect("repository/open should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(
        outcome.response()["error"]["code"],
        "SVN_BRIDGE_UNAVAILABLE"
    );
    assert_eq!(outcome.response()["error"]["category"], "native");
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.native.bridgeUnavailable"
    );
    assert_eq!(outcome.response()["error"]["args"]["path"], "C:\\wc");
}

#[test]
fn repository_open_returns_identity_from_loaded_bridge() {
    let request =
        r#"{"jsonrpc":"2.0","id":6,"method":"repository/open","params":{"path":"C:\\wc"}}"#;
    let bridge = FakeBridge::open_success();

    let outcome =
        dispatch_json_rpc_with_bridge(request, &bridge).expect("repository/open should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["id"], 6);
    assert_eq!(
        outcome.response()["result"]["repositoryId"],
        "repo-uuid:C:/wc"
    );
    assert_eq!(outcome.response()["result"]["epoch"], 1);
    assert_eq!(
        outcome.response()["result"]["identity"]["repositoryUuid"],
        "repo-uuid"
    );
    assert_eq!(
        outcome.response()["result"]["identity"]["repositoryRootUrl"],
        "file:///C:/repo"
    );
    assert_eq!(
        outcome.response()["result"]["identity"]["workingCopyRoot"],
        "C:/wc"
    );
    assert_eq!(
        outcome.response()["result"]["identity"]["workspaceScopeRoot"],
        "C:/workspace"
    );
    assert_eq!(outcome.response()["result"]["identity"]["format"], 31);
}

#[test]
fn repository_checkout_returns_working_copy_path_and_revision_from_loaded_bridge() {
    let request = r#"{"jsonrpc":"2.0","id":60,"method":"repository/checkout","params":{"url":"https://svn.example.invalid/project/trunk","targetPath":"C:/checkout/project","revision":9,"depth":"files","ignoreExternals":true}}"#;
    let bridge = FakeBridge::open_success().with_checkout_result(
        "https://svn.example.invalid/project/trunk",
        Ok(subversionr_daemon::RepositoryCheckoutResult {
            working_copy_path: "C:/checkout/project".to_string(),
            revision: 9,
        }),
    );

    let outcome = dispatch_json_rpc_with_bridge(request, &bridge)
        .expect("repository/checkout should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["id"], 60);
    assert_eq!(
        outcome.response()["result"]["workingCopyPath"],
        "C:/checkout/project"
    );
    assert_eq!(outcome.response()["result"]["revision"], 9);
    assert_eq!(
        bridge.checkout_requests.borrow().as_slice(),
        &[subversionr_daemon::RepositoryCheckoutRequest {
            url: "https://svn.example.invalid/project/trunk".to_string(),
            target_path: "C:/checkout/project".to_string(),
            revision: "9".to_string(),
            depth: "files".to_string(),
            ignore_externals: true,
        }]
    );
}

#[test]
fn repository_checkout_returns_structured_error_until_bridge_is_loaded() {
    let request = r#"{"jsonrpc":"2.0","id":61,"method":"repository/checkout","params":{"url":"https://svn.example.invalid/project/trunk","targetPath":"C:/checkout/project","revision":"head","depth":"infinity","ignoreExternals":false}}"#;

    let outcome = dispatch_json_rpc(request).expect("repository/checkout should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["id"], 61);
    assert_eq!(
        outcome.response()["error"]["code"],
        "SVN_BRIDGE_UNAVAILABLE"
    );
    assert_eq!(outcome.response()["error"]["category"], "native");
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.native.bridgeUnavailable"
    );
    assert_eq!(
        outcome.response()["error"]["args"]["path"],
        "C:/checkout/project"
    );
}

#[test]
fn repository_checkout_rejects_invalid_params_before_bridge_call() {
    let cases = [
        (
            "missing-url",
            r#"{"jsonrpc":"2.0","id":62,"method":"repository/checkout","params":{"targetPath":"C:/checkout/project","revision":"head","depth":"infinity","ignoreExternals":false}}"#,
            "url",
        ),
        (
            "invalid-revision",
            r#"{"jsonrpc":"2.0","id":63,"method":"repository/checkout","params":{"url":"https://svn.example.invalid/project/trunk","targetPath":"C:/checkout/project","revision":"latest","depth":"infinity","ignoreExternals":false}}"#,
            "revision",
        ),
        (
            "invalid-depth",
            r#"{"jsonrpc":"2.0","id":64,"method":"repository/checkout","params":{"url":"https://svn.example.invalid/project/trunk","targetPath":"C:/checkout/project","revision":"head","depth":"workingCopy","ignoreExternals":false}}"#,
            "depth",
        ),
        (
            "unexpected-field",
            r#"{"jsonrpc":"2.0","id":65,"method":"repository/checkout","params":{"url":"https://svn.example.invalid/project/trunk","targetPath":"C:/checkout/project","revision":"head","depth":"infinity","ignoreExternals":false,"path":"C:/other"}}"#,
            "path",
        ),
    ];
    let bridge = FakeBridge::open_success();

    for (label, request, field) in cases {
        let outcome = dispatch_json_rpc_with_bridge(request, &bridge).unwrap_or_else(|error| {
            panic!("repository/checkout should dispatch for {label}: {error}")
        });

        assert_eq!(outcome, DispatchOutcome::Continue, "{label}");
        assert_eq!(
            outcome.response()["error"]["code"],
            "RPC_INVALID_PARAMS",
            "{label}"
        );
        assert_eq!(
            outcome.response()["error"]["args"]["field"],
            field,
            "{label}"
        );
    }
    assert!(bridge.checkout_requests.borrow().is_empty());
}

#[test]
fn repository_discover_returns_candidates_without_opening_a_session() {
    let request = r#"{"jsonrpc":"2.0","id":8,"method":"repository/discover","params":{"workspaceRoots":["C:\\wc\\subdir"],"discoverNested":false,"discoveryDepth":4,"discoveryIgnore":[],"ignoredRoots":[],"externalsMode":"lazy"}}"#;
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();

    let outcome = state
        .dispatch_json_rpc_with_bridge(request, &bridge)
        .expect("repository/discover should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["id"], 8);
    assert_eq!(
        outcome.response()["result"]["candidates"][0]["identity"]["workingCopyRoot"],
        "C:/wc"
    );
    assert_eq!(
        outcome.response()["result"]["candidates"][0]["isNested"],
        false
    );
    assert_eq!(
        outcome.response()["result"]["candidates"][0]["isExternal"],
        false
    );

    let snapshot = r#"{"jsonrpc":"2.0","id":9,"method":"status/getSnapshot","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#;
    let snapshot_outcome = state
        .dispatch_json_rpc_with_bridge(snapshot, &bridge)
        .expect("status/getSnapshot should dispatch");

    assert_eq!(
        snapshot_outcome.response()["error"]["code"],
        "REPOSITORY_NOT_OPEN"
    );
}

#[test]
fn repository_discover_with_nested_enabled_returns_parent_and_nested_candidates() {
    let tree = DiscoveryTempTree::create("nested");
    let parent = tree.working_copy("");
    let nested = tree.working_copy("vendor/nested");
    let parent_identity = FakeBridge::identity_at(&parent, "parent-uuid", "file:///parent-repo");
    let nested_identity = FakeBridge::identity_at(&nested, "nested-uuid", "file:///nested-repo");
    let request = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 24,
        "method": "repository/discover",
        "params": {
            "workspaceRoots": [parent.to_string_lossy().to_string()],
            "discoverNested": true,
            "discoveryDepth": 4,
            "discoveryIgnore": [],
            "ignoredRoots": [],
            "externalsMode": "lazy"
        }
    })
    .to_string();
    let bridge = FakeBridge::open_failure()
        .with_snapshot_entries(Vec::new())
        .with_open_result(&parent, Ok(parent_identity.clone()))
        .with_open_result(&nested, Ok(nested_identity.clone()));
    let mut state = DaemonState::new();

    let outcome = state
        .dispatch_json_rpc_with_bridge(&request, &bridge)
        .expect("repository/discover should dispatch");

    let candidates = outcome.response()["result"]["candidates"]
        .as_array()
        .expect("discovery candidates should be an array");
    assert_eq!(candidates.len(), 2);
    assert_eq!(
        candidates[0]["identity"]["workingCopyRoot"],
        parent_identity.working_copy_root
    );
    assert_eq!(candidates[0]["isNested"], false);
    assert_eq!(candidates[0]["isExternal"], false);
    assert_eq!(
        candidates[1]["identity"]["workingCopyRoot"],
        nested_identity.working_copy_root
    );
    assert_eq!(candidates[1]["isNested"], true);
    assert_eq!(candidates[1]["isExternal"], false);
    assert_eq!(
        candidates[1]["parentWorkingCopyRoot"],
        parent_identity.working_copy_root
    );
}

#[test]
fn repository_discover_lazy_externals_returns_directory_external_candidates() {
    let tree = DiscoveryTempTree::create("dir-external");
    let parent = tree.working_copy("");
    let external = tree.path.join("externals/library");
    let parent_identity = FakeBridge::identity_at(&parent, "parent-uuid", "file:///parent-repo");
    let external_identity =
        FakeBridge::identity_at(&external, "external-uuid", "file:///external-repo");
    let mut external_entry =
        FakeBridge::status_entry_with_kind("externals/library", "dir", "normal", 1);
    external_entry.external = true;
    let request = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 29,
        "method": "repository/discover",
        "params": {
            "workspaceRoots": [parent.to_string_lossy().to_string()],
            "discoverNested": false,
            "discoveryDepth": 0,
            "discoveryIgnore": [],
            "ignoredRoots": [],
            "externalsMode": "lazy"
        }
    })
    .to_string();
    let bridge = FakeBridge::open_failure()
        .with_open_result(&parent, Ok(parent_identity.clone()))
        .with_open_result(&external, Ok(external_identity.clone()))
        .with_snapshot_entries(vec![external_entry]);
    let mut state = DaemonState::new();

    let outcome = state
        .dispatch_json_rpc_with_bridge(&request, &bridge)
        .expect("repository/discover should dispatch");

    let candidates = outcome.response()["result"]["candidates"]
        .as_array()
        .expect("discovery candidates should be an array");
    assert_eq!(candidates.len(), 2);
    assert_eq!(
        candidates[0]["identity"]["workingCopyRoot"],
        parent_identity.working_copy_root
    );
    assert_eq!(candidates[0]["isNested"], false);
    assert_eq!(candidates[0]["isExternal"], false);
    assert_eq!(
        candidates[1]["identity"]["workingCopyRoot"],
        external_identity.working_copy_root
    );
    assert_eq!(candidates[1]["isNested"], false);
    assert_eq!(candidates[1]["isExternal"], true);
    assert_eq!(
        candidates[1]["parentWorkingCopyRoot"],
        parent_identity.working_copy_root
    );
}

#[test]
fn repository_discover_lazy_externals_returns_file_external_boundaries() {
    let tree = DiscoveryTempTree::create("file-external");
    let parent_identity = FakeBridge::identity_at(&tree.path, "parent-uuid", "file:///parent-repo");
    let mut external_entry =
        FakeBridge::status_entry_with_kind("externals/pinned.txt", "file", "normal", 1);
    external_entry.external = true;
    let directory_entry =
        FakeBridge::status_entry_with_kind("externals/not-external-dir", "dir", "normal", 1);
    let mut invalid_external_entry =
        FakeBridge::status_entry_with_kind("../outside.txt", "file", "normal", 1);
    invalid_external_entry.external = true;
    let request = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 118,
        "method": "repository/discover",
        "params": {
            "workspaceRoots": [tree.path.to_string_lossy()],
            "discoverNested": false,
            "discoveryDepth": 0,
            "discoveryIgnore": [],
            "ignoredRoots": [],
            "externalsMode": "lazy"
        }
    })
    .to_string();
    let bridge = FakeBridge::open_success()
        .with_open_result(&tree.path, Ok(parent_identity))
        .with_snapshot_entries(vec![
            external_entry,
            directory_entry,
            invalid_external_entry,
        ]);
    let mut state = DaemonState::new();

    let outcome = state
        .dispatch_json_rpc_with_bridge(&request, &bridge)
        .expect("repository/discover should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    let boundaries = outcome.response()["result"]["fileExternalBoundaries"]
        .as_array()
        .expect("file external boundaries should be an array");
    assert_eq!(boundaries.len(), 1);
    assert_eq!(
        boundaries[0],
        tree.path
            .join("externals")
            .join("pinned.txt")
            .to_string_lossy()
            .to_string()
    );
}

#[test]
fn repository_discover_respects_nested_depth_ignore_patterns_and_ignored_roots() {
    let tree = DiscoveryTempTree::create("filters");
    let parent = tree.working_copy("");
    let ignored = tree.working_copy("ignored");
    let vendor_nested = tree.working_copy("vendor/nested");
    let kept = tree.working_copy("kept");
    let too_deep = tree.working_copy("too/deep/nested");
    let parent_identity = FakeBridge::identity_at(&parent, "parent-uuid", "file:///parent-repo");
    let ignored_identity =
        FakeBridge::identity_at(&ignored, "ignored-uuid", "file:///ignored-repo");
    let vendor_identity =
        FakeBridge::identity_at(&vendor_nested, "vendor-uuid", "file:///vendor-repo");
    let kept_identity = FakeBridge::identity_at(&kept, "kept-uuid", "file:///kept-repo");
    let deep_identity = FakeBridge::identity_at(&too_deep, "deep-uuid", "file:///deep-repo");
    let request = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 25,
        "method": "repository/discover",
        "params": {
            "workspaceRoots": [parent.to_string_lossy().to_string()],
            "discoverNested": true,
            "discoveryDepth": 1,
            "discoveryIgnore": ["ignored", "**/vendor"],
            "ignoredRoots": [kept_identity.working_copy_root.clone()],
            "externalsMode": "lazy"
        }
    })
    .to_string();
    let bridge = FakeBridge::open_failure()
        .with_snapshot_entries(Vec::new())
        .with_open_result(&parent, Ok(parent_identity.clone()))
        .with_open_result(&ignored, Ok(ignored_identity))
        .with_open_result(&vendor_nested, Ok(vendor_identity))
        .with_open_result(&kept, Ok(kept_identity))
        .with_open_result(&too_deep, Ok(deep_identity));
    let mut state = DaemonState::new();

    let outcome = state
        .dispatch_json_rpc_with_bridge(&request, &bridge)
        .expect("repository/discover should dispatch");

    let candidates = outcome.response()["result"]["candidates"]
        .as_array()
        .expect("discovery candidates should be an array");
    assert_eq!(candidates.len(), 1);
    assert_eq!(
        candidates[0]["identity"]["workingCopyRoot"],
        parent_identity.working_copy_root
    );
    assert_eq!(candidates[0]["isNested"], false);
}

#[test]
fn repository_discover_matches_ignore_patterns_case_insensitively_on_windows() {
    let tree = DiscoveryTempTree::create("ignore-case");
    let parent = tree.working_copy("");
    let vendor_nested = tree.working_copy("Vendor/nested");
    let parent_identity = FakeBridge::identity_at(&parent, "parent-uuid", "file:///parent-repo");
    let vendor_identity =
        FakeBridge::identity_at(&vendor_nested, "vendor-uuid", "file:///vendor-repo");
    let request = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 27,
        "method": "repository/discover",
        "params": {
            "workspaceRoots": [parent.to_string_lossy().to_string()],
            "discoverNested": true,
            "discoveryDepth": 4,
            "discoveryIgnore": ["**/vendor"],
            "ignoredRoots": [],
            "externalsMode": "lazy"
        }
    })
    .to_string();
    let bridge = FakeBridge::open_failure()
        .with_snapshot_entries(Vec::new())
        .with_open_result(&parent, Ok(parent_identity.clone()))
        .with_open_result(&vendor_nested, Ok(vendor_identity));
    let mut state = DaemonState::new();

    let outcome = state
        .dispatch_json_rpc_with_bridge(&request, &bridge)
        .expect("repository/discover should dispatch");

    let candidates = outcome.response()["result"]["candidates"]
        .as_array()
        .expect("discovery candidates should be an array");
    if cfg!(windows) {
        assert_eq!(candidates.len(), 1);
        assert_eq!(
            candidates[0]["identity"]["workingCopyRoot"],
            parent_identity.working_copy_root
        );
    } else {
        assert_eq!(candidates.len(), 2);
    }
}

#[test]
fn repository_discover_scans_nested_children_under_ignored_workspace_roots() {
    let tree = DiscoveryTempTree::create("ignored-parent");
    let parent = tree.working_copy("");
    let nested = tree.working_copy("vendor/nested");
    let parent_identity = FakeBridge::identity_at(&parent, "parent-uuid", "file:///parent-repo");
    let nested_identity = FakeBridge::identity_at(&nested, "nested-uuid", "file:///nested-repo");
    let request = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 26,
        "method": "repository/discover",
        "params": {
            "workspaceRoots": [parent.to_string_lossy().to_string()],
            "discoverNested": true,
            "discoveryDepth": 4,
            "discoveryIgnore": [],
            "ignoredRoots": [parent_identity.working_copy_root.clone()],
            "externalsMode": "lazy"
        }
    })
    .to_string();
    let bridge = FakeBridge::open_failure()
        .with_open_result(&parent, Ok(parent_identity.clone()))
        .with_open_result(&nested, Ok(nested_identity.clone()));
    let mut state = DaemonState::new();

    let outcome = state
        .dispatch_json_rpc_with_bridge(&request, &bridge)
        .expect("repository/discover should dispatch");

    let candidates = outcome.response()["result"]["candidates"]
        .as_array()
        .expect("discovery candidates should be an array");
    assert_eq!(candidates.len(), 1);
    assert_eq!(
        candidates[0]["identity"]["workingCopyRoot"],
        nested_identity.working_copy_root
    );
    assert_eq!(candidates[0]["isNested"], true);
    assert_eq!(
        candidates[0]["parentWorkingCopyRoot"],
        parent_identity.working_copy_root
    );
}

#[test]
fn repository_discover_rejects_unbounded_nested_discovery_depth() {
    let request = r#"{"jsonrpc":"2.0","id":28,"method":"repository/discover","params":{"workspaceRoots":["C:\\wc"],"discoverNested":true,"discoveryDepth":65,"discoveryIgnore":[],"ignoredRoots":[],"externalsMode":"lazy"}}"#;
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();

    let outcome = state
        .dispatch_json_rpc_with_bridge(request, &bridge)
        .expect("repository/discover should dispatch");

    assert_eq!(outcome.response()["error"]["code"], "RPC_INVALID_PARAMS");
    assert_eq!(
        outcome.response()["error"]["args"]["field"],
        "discoveryDepth"
    );
}

#[test]
fn repository_discover_requires_the_full_parameter_contract() {
    let request = r#"{"jsonrpc":"2.0","id":22,"method":"repository/discover","params":{"workspaceRoots":["C:\\wc"]}}"#;
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();

    let outcome = state
        .dispatch_json_rpc_with_bridge(request, &bridge)
        .expect("repository/discover should dispatch");

    assert_eq!(outcome.response()["error"]["code"], "RPC_INVALID_PARAMS");
    assert_eq!(
        outcome.response()["error"]["args"]["field"],
        "discoverNested"
    );
}

#[test]
fn repository_discover_rejects_unsupported_eager_externals() {
    let request = r#"{"jsonrpc":"2.0","id":23,"method":"repository/discover","params":{"workspaceRoots":["C:\\wc"],"discoverNested":false,"discoveryDepth":4,"discoveryIgnore":[],"ignoredRoots":[],"externalsMode":"eager"}}"#;
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();

    let outcome = state
        .dispatch_json_rpc_with_bridge(request, &bridge)
        .expect("repository/discover should dispatch");

    assert_eq!(
        outcome.response()["error"]["code"],
        "REPOSITORY_DISCOVERY_MODE_UNSUPPORTED"
    );
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.repository.discoveryModeUnsupported"
    );
}

#[test]
fn repository_open_registers_session_with_epoch_and_repository_id() {
    let request =
        r#"{"jsonrpc":"2.0","id":10,"method":"repository/open","params":{"path":"C:\\wc"}}"#;
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();

    let outcome = state
        .dispatch_json_rpc_with_bridge(request, &bridge)
        .expect("repository/open should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["id"], 10);
    assert_eq!(
        outcome.response()["result"]["repositoryId"],
        "repo-uuid:C:/wc"
    );
    assert_eq!(outcome.response()["result"]["epoch"], 1);
    assert_eq!(
        outcome.response()["result"]["identity"]["repositoryUuid"],
        "repo-uuid"
    );
}

#[test]
fn repository_open_rejects_boundary_roots_outside_or_equal_to_working_copy_root() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();

    for (id, boundary_root) in [(101, "D:/other-wc"), (102, "C:/wc")] {
        let request = serde_json::json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": "repository/open",
            "params": {
                "path": "C:\\wc",
                "boundaryRoots": [boundary_root]
            }
        })
        .to_string();

        let outcome = state
            .dispatch_json_rpc_with_bridge(&request, &bridge)
            .expect("repository/open should dispatch");

        assert_eq!(outcome, DispatchOutcome::Continue);
        assert_eq!(outcome.response()["id"], id);
        assert_eq!(outcome.response()["error"]["code"], "RPC_INVALID_PARAMS");
        assert_eq!(
            outcome.response()["error"]["args"]["field"],
            "boundaryRoots.0"
        );
    }

    let status_request = r#"{"jsonrpc":"2.0","id":103,"method":"status/getSnapshot","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#;
    let status_outcome = state
        .dispatch_json_rpc_with_bridge(status_request, &bridge)
        .expect("status/getSnapshot should dispatch");
    assert_eq!(
        status_outcome.response()["error"]["code"],
        "REPOSITORY_NOT_OPEN"
    );
}

#[test]
fn status_get_snapshot_returns_local_snapshot_for_open_repository() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    let open = r#"{"jsonrpc":"2.0","id":11,"method":"repository/open","params":{"path":"C:\\wc"}}"#;
    state
        .dispatch_json_rpc_with_bridge(open, &bridge)
        .expect("repository/open should dispatch");
    let request = r#"{"jsonrpc":"2.0","id":12,"method":"status/getSnapshot","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#;

    let outcome = state
        .dispatch_json_rpc_with_bridge(request, &bridge)
        .expect("status/getSnapshot should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["id"], 12);
    assert_eq!(
        outcome.response()["result"]["repositoryId"],
        "repo-uuid:C:/wc"
    );
    assert_eq!(outcome.response()["result"]["epoch"], 1);
    assert_eq!(outcome.response()["result"]["generation"], 1);
    assert_eq!(outcome.response()["result"]["completeness"], "complete");
    assert_eq!(
        outcome.response()["result"]["identity"]["workspaceScopeRoot"],
        "C:/workspace"
    );
    assert_eq!(outcome.response()["result"]["source"], "libsvn-local");
    assert_eq!(
        outcome.response()["result"]["localEntries"][0]["path"],
        "src/main.c"
    );
    assert_eq!(
        outcome.response()["result"]["localEntries"][0]["nodeStatus"],
        "modified"
    );
    assert_eq!(
        outcome.response()["result"]["localEntries"][0]["generation"],
        1
    );
    assert_eq!(
        outcome.response()["result"]["remoteEntries"]
            .as_array()
            .expect("remote entries should be an array")
            .len(),
        0
    );
    assert_eq!(outcome.response()["result"]["summary"]["localChanges"], 1);
}

#[test]
fn status_get_snapshot_preserves_property_only_changes() {
    let bridge = FakeBridge::open_success()
        .with_snapshot_entries(vec![FakeBridge::property_only_status_entry(
            "src/properties.txt",
            1,
        )])
        .with_scan_result(
            "src/properties.txt",
            "empty",
            FakeBridge::scan_success("src/properties.txt", Vec::new()),
        );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":114,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":115,"method":"status/getSnapshot","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#,
            &bridge,
        )
        .expect("status/getSnapshot should dispatch");

    assert_eq!(
        outcome.response()["result"]["localEntries"][0]["path"],
        "src/properties.txt"
    );
    assert_eq!(
        outcome.response()["result"]["localEntries"][0]["localStatus"],
        "normal"
    );
    assert_eq!(
        outcome.response()["result"]["localEntries"][0]["propertyStatus"],
        "modified"
    );
    assert_eq!(outcome.response()["result"]["summary"]["localChanges"], 1);

    let refresh = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":118,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":"src/properties.txt","depth":"empty","reason":"fileChanged"}]}}"#,
            &bridge,
        )
        .expect("status/refresh should dispatch");

    assert_eq!(
        refresh.response()["result"]["remove"][0],
        "src/properties.txt"
    );
    assert_eq!(
        refresh.response()["result"]["summaryDelta"]["localChanges"],
        -1
    );
}

#[test]
fn status_get_snapshot_filters_entries_inside_repository_boundaries() {
    let bridge = FakeBridge::open_success().with_snapshot_entries(vec![
        FakeBridge::status_entry("src/main.c", "modified", 1),
        FakeBridge::status_entry("vendor/nested/src/lib.c", "modified", 1),
    ]);
    let mut state = DaemonState::new();
    let open = r#"{"jsonrpc":"2.0","id":112,"method":"repository/open","params":{"path":"C:\\wc","boundaryRoots":["C:\\wc\\vendor\\nested"]}}"#;
    state
        .dispatch_json_rpc_with_bridge(open, &bridge)
        .expect("repository/open should dispatch");
    let request = r#"{"jsonrpc":"2.0","id":113,"method":"status/getSnapshot","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#;

    let outcome = state
        .dispatch_json_rpc_with_bridge(request, &bridge)
        .expect("status/getSnapshot should dispatch");

    let entries = outcome.response()["result"]["localEntries"]
        .as_array()
        .expect("local entries should be an array");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0]["path"], "src/main.c");
    assert_eq!(outcome.response()["result"]["summary"]["localChanges"], 1);
}

#[test]
fn status_refresh_filters_boundary_entries_and_skips_boundary_targets() {
    let bridge = FakeBridge::open_success()
        .with_scan_result(
            ".",
            "infinity",
            FakeBridge::scan_success(
                ".",
                vec![
                    FakeBridge::status_entry("src/main.c", "modified", 1),
                    FakeBridge::status_entry("vendor/nested/src/lib.c", "modified", 1),
                ],
            ),
        )
        .with_scan_result(
            "vendor/nested/src/lib.c",
            "empty",
            Err(BridgeFailure::new(
                "BOUNDARY_TARGET_SHOULD_NOT_SCAN",
                "test",
                "error.test.boundaryTargetShouldNotScan",
                serde_json::json!({ "path": "vendor/nested/src/lib.c" }),
                false,
            )),
        );
    let mut state = DaemonState::new();
    let open = r#"{"jsonrpc":"2.0","id":114,"method":"repository/open","params":{"path":"C:\\wc","boundaryRoots":["C:\\wc\\vendor\\nested"]}}"#;
    state
        .dispatch_json_rpc_with_bridge(open, &bridge)
        .expect("repository/open should dispatch");

    let full_refresh = r#"{"jsonrpc":"2.0","id":115,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":".","depth":"infinity","reason":"manualFullReconcile"}]}}"#;
    let full_outcome = state
        .dispatch_json_rpc_with_bridge(full_refresh, &bridge)
        .expect("status/refresh should dispatch");

    let upserts = full_outcome.response()["result"]["upsert"]
        .as_array()
        .expect("upserts should be an array");
    assert_eq!(upserts.len(), 1);
    assert_eq!(upserts[0]["path"], "src/main.c");

    let boundary_refresh = r#"{"jsonrpc":"2.0","id":116,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":"vendor/nested/src/lib.c","depth":"empty","reason":"fileChanged"}]}}"#;
    let boundary_outcome = state
        .dispatch_json_rpc_with_bridge(boundary_refresh, &bridge)
        .expect("status/refresh should dispatch");

    assert_eq!(boundary_outcome.response()["result"]["generation"], 2);
    assert_eq!(
        boundary_outcome.response()["result"]["upsert"]
            .as_array()
            .expect("upserts should be an array")
            .len(),
        0
    );
    assert_eq!(
        boundary_outcome.response()["result"]["coverage"]
            .as_array()
            .expect("coverage should be an array")
            .len(),
        0
    );
}

#[test]
fn content_get_returns_base_content_for_open_repository() {
    let bridge = FakeBridge::open_success().with_content_result(
        "tracked.txt",
        "base",
        Ok(ContentBlob {
            data: b"base\n".to_vec(),
            mime_type: Some("text/plain".to_string()),
            is_binary: false,
            source: "libsvn-base".to_string(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":52,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":53,"method":"content/get","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"path":"tracked.txt","revision":"base"}}"#,
            &bridge,
        )
        .expect("content/get should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(
        outcome.response()["result"]["repositoryId"],
        "repo-uuid:C:/wc"
    );
    assert_eq!(outcome.response()["result"]["epoch"], 1);
    assert_eq!(outcome.response()["result"]["path"], "tracked.txt");
    assert_eq!(outcome.response()["result"]["revision"], "base");
    assert_eq!(outcome.response()["result"]["contentBase64"], "YmFzZQo=");
    assert_eq!(outcome.response()["result"]["byteLength"], 5);
    assert_eq!(outcome.response()["result"]["mimeType"], "text/plain");
    assert_eq!(outcome.response()["result"]["isBinary"], false);
    assert_eq!(outcome.response()["result"]["source"], "libsvn-base");
}

#[test]
fn content_get_returns_head_content_for_open_repository() {
    let bridge = FakeBridge::open_success().with_content_result(
        "tracked.txt",
        "head",
        Ok(ContentBlob {
            data: b"head\n".to_vec(),
            mime_type: Some("text/plain".to_string()),
            is_binary: false,
            source: "libsvn-head".to_string(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":54,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":55,"method":"content/get","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"path":"tracked.txt","revision":"head"}}"#,
            &bridge,
        )
        .expect("content/get should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["revision"], "head");
    assert_eq!(outcome.response()["result"]["contentBase64"], "aGVhZAo=");
    assert_eq!(outcome.response()["result"]["source"], "libsvn-head");
}

#[test]
fn content_get_returns_explicit_revision_content_for_open_repository() {
    let bridge = FakeBridge::open_success().with_content_result(
        "tracked.txt",
        "r7",
        Ok(ContentBlob {
            data: b"revision 7\n".to_vec(),
            mime_type: None,
            is_binary: false,
            source: "libsvn-revision".to_string(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":54,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":55,"method":"content/get","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"path":"tracked.txt","revision":"r7"}}"#,
            &bridge,
        )
        .expect("content/get should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["revision"], "r7");
    assert_eq!(
        outcome.response()["result"]["contentBase64"],
        "cmV2aXNpb24gNwo="
    );
    assert_eq!(outcome.response()["result"]["source"], "libsvn-revision");
}

#[test]
fn content_get_accepts_revision_zero_grammar_branch() {
    let bridge = FakeBridge::open_success().with_content_result(
        "tracked.txt",
        "r0",
        Ok(ContentBlob {
            data: b"revision 0\n".to_vec(),
            mime_type: None,
            is_binary: false,
            source: "libsvn-revision".to_string(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":56,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":57,"method":"content/get","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"path":"tracked.txt","revision":"r0"}}"#,
            &bridge,
        )
        .expect("content/get should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["revision"], "r0");
    assert_eq!(
        outcome.response()["result"]["contentBase64"],
        "cmV2aXNpb24gMAo="
    );
    assert_eq!(outcome.response()["result"]["source"], "libsvn-revision");
}

#[test]
fn content_get_rejects_invalid_revisions_before_bridge_call() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":54,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    for (request_id, revision) in [
        (55, "HEAD"),
        (56, "7"),
        (57, "r"),
        (58, "r-1"),
        (59, "r01"),
        (60, "working"),
        (61, "r2147483648"),
    ] {
        let request = format!(
            r#"{{"jsonrpc":"2.0","id":{request_id},"method":"content/get","params":{{"repositoryId":"repo-uuid:C:/wc","epoch":1,"path":"tracked.txt","revision":"{revision}"}}}}"#
        );
        let outcome = state
            .dispatch_json_rpc_with_bridge(&request, &bridge)
            .unwrap_or_else(|error| panic!("request {request_id} should dispatch: {error}"));

        assert_eq!(outcome.response()["error"]["code"], "RPC_INVALID_PARAMS");
        assert_eq!(outcome.response()["error"]["args"]["field"], "revision");
    }
}

#[test]
fn content_get_rejects_extra_params_before_bridge_call() {
    let bridge = FakeBridge::open_success().with_content_result(
        "tracked.txt",
        "base",
        Ok(ContentBlob {
            data: b"base\n".to_vec(),
            mime_type: Some("text/plain".to_string()),
            is_binary: false,
            source: "libsvn-base".to_string(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":62,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":63,"method":"content/get","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"path":"tracked.txt","revision":"base","extra":true}}"#,
            &bridge,
        )
        .expect("content/get should dispatch");

    assert_eq!(outcome.response()["error"]["code"], "RPC_INVALID_PARAMS");
    assert_eq!(outcome.response()["error"]["args"]["field"], "extra");
}

#[test]
fn content_get_rejects_absolute_or_parent_relative_path() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":56,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let parent = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":57,"method":"content/get","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"path":"..\\outside.txt","revision":"base"}}"#,
            &bridge,
        )
        .expect("content/get should dispatch");
    assert_eq!(parent.response()["error"]["code"], "RPC_INVALID_PARAMS");
    assert_eq!(parent.response()["error"]["args"]["field"], "path");

    let absolute = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":58,"method":"content/get","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"path":"C:\\wc\\tracked.txt","revision":"base"}}"#,
            &bridge,
        )
        .expect("content/get should dispatch");
    assert_eq!(absolute.response()["error"]["code"], "RPC_INVALID_PARAMS");
    assert_eq!(absolute.response()["error"]["args"]["field"], "path");
}

#[test]
fn content_get_requires_matching_open_repository_epoch() {
    let bridge = FakeBridge::open_success().with_content_result(
        "tracked.txt",
        "base",
        Ok(ContentBlob {
            data: b"base\n".to_vec(),
            mime_type: None,
            is_binary: false,
            source: "libsvn-base".to_string(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":59,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":60,"method":"content/get","params":{"repositoryId":"repo-uuid:C:/wc","epoch":2,"path":"tracked.txt","revision":"base"}}"#,
            &bridge,
        )
        .expect("content/get should dispatch");

    assert_eq!(outcome.response()["error"]["code"], "REPOSITORY_NOT_OPEN");
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.repository.notOpen"
    );
}

#[test]
fn properties_list_returns_properties_for_open_repository_path() {
    let bridge = FakeBridge::open_success().with_properties_result(
        "src",
        Ok(subversionr_daemon::PropertiesListResult {
            properties: vec![subversionr_daemon::PropertyEntry {
                name: "svn:ignore".to_string(),
                value: "target\nnode_modules".to_string(),
                value_encoding: "utf8".to_string(),
            }],
            source: "libsvn-local".to_string(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":92,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":93,"method":"properties/list","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"path":"src"}}"#,
            &bridge,
        )
        .expect("properties/list should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(
        outcome.response()["result"]["repositoryId"],
        "repo-uuid:C:/wc"
    );
    assert_eq!(outcome.response()["result"]["epoch"], 1);
    assert_eq!(outcome.response()["result"]["path"], "src");
    assert_eq!(
        outcome.response()["result"]["properties"][0]["name"],
        "svn:ignore"
    );
    assert_eq!(
        outcome.response()["result"]["properties"][0]["value"],
        "target\nnode_modules"
    );
    assert_eq!(
        outcome.response()["result"]["properties"][0]["valueEncoding"],
        "utf8"
    );
    assert_eq!(outcome.response()["result"]["source"], "libsvn-local");
    assert_eq!(bridge.properties_requests.borrow().as_slice(), ["src"]);
}

#[test]
fn properties_list_accepts_working_copy_root_path() {
    let bridge = FakeBridge::open_success().with_properties_result(
        ".",
        Ok(subversionr_daemon::PropertiesListResult {
            properties: Vec::new(),
            source: "libsvn-local".to_string(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":94,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":95,"method":"properties/list","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"path":"."}}"#,
            &bridge,
        )
        .expect("properties/list should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["path"], ".");
    assert_eq!(
        outcome.response()["result"]["properties"]
            .as_array()
            .expect("properties array")
            .len(),
        0
    );
    assert_eq!(bridge.properties_requests.borrow().as_slice(), ["."]);
}

#[test]
fn properties_list_rejects_invalid_path_before_bridge_call() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":96,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":97,"method":"properties/list","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"path":"../outside"}}"#,
            &bridge,
        )
        .expect("properties/list should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["error"]["code"], "RPC_INVALID_PARAMS");
    assert_eq!(outcome.response()["error"]["args"]["field"], "path");
    assert!(bridge.properties_requests.borrow().is_empty());
}

#[test]
fn properties_list_rejects_unexpected_param_before_bridge_call() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":98,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":99,"method":"properties/list","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"path":"src","recursive":true}}"#,
            &bridge,
        )
        .expect("properties/list should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["error"]["code"], "RPC_INVALID_PARAMS");
    assert_eq!(outcome.response()["error"]["args"]["field"], "recursive");
    assert!(bridge.properties_requests.borrow().is_empty());
}

#[test]
fn properties_list_requires_matching_open_repository_epoch() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":100,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":101,"method":"properties/list","params":{"repositoryId":"repo-uuid:C:/wc","epoch":2,"path":"src"}}"#,
            &bridge,
        )
        .expect("properties/list should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["error"]["code"], "REPOSITORY_NOT_OPEN");
    assert!(bridge.properties_requests.borrow().is_empty());
}

#[test]
fn properties_list_maps_bridge_failure_to_structured_error_without_stale_notification() {
    let bridge = FakeBridge::open_success().with_properties_result(
        "src",
        Err(subversionr_daemon::BridgeFailure::new(
            "SVN_PROPERTIES_LIST_FAILED",
            "native",
            "error.native.propertiesListFailed",
            serde_json::json!({ "path": "src" }),
            false,
        )),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":102,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":103,"method":"properties/list","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"path":"src"}}"#,
            &bridge,
        )
        .expect("properties/list should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(
        outcome.response()["error"]["code"],
        "SVN_PROPERTIES_LIST_FAILED"
    );
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.native.propertiesListFailed"
    );
    assert_eq!(outcome.response()["error"]["args"]["path"], "src");
    assert!(outcome.notifications().is_empty());
    assert_eq!(bridge.properties_requests.borrow().as_slice(), ["src"]);
}

#[test]
fn history_log_returns_entries_for_open_repository() {
    let bridge = FakeBridge::open_success().with_history_result(
        "src/main.c",
        Ok(HistoryLogResult {
            entries: vec![HistoryLogEntry {
                revision: 7,
                author: Some("alice".to_string()),
                date: Some("2026-06-23T00:00:00.000000Z".to_string()),
                message: Some("edit file".to_string()),
                changed_paths: vec![HistoryLogChangedPath {
                    path: "/trunk/src/main.c".to_string(),
                    action: "M".to_string(),
                    copy_from_path: None,
                    copy_from_revision: None,
                    node_kind: "file".to_string(),
                    text_modified: "true".to_string(),
                    properties_modified: "false".to_string(),
                }],
                has_children: false,
                non_inheritable: false,
                subtractive_merge: false,
            }],
            source: "libsvn-log".to_string(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":64,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":65,"method":"history/log","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"path":"src/main.c","startRevision":"head","endRevision":"r0","limit":25,"discoverChangedPaths":true,"strictNodeHistory":true,"includeMergedRevisions":false}}"#,
            &bridge,
        )
        .expect("history/log should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(
        outcome.response()["result"]["repositoryId"],
        "repo-uuid:C:/wc"
    );
    assert_eq!(outcome.response()["result"]["epoch"], 1);
    assert_eq!(outcome.response()["result"]["path"], "src/main.c");
    assert_eq!(outcome.response()["result"]["startRevision"], "head");
    assert_eq!(outcome.response()["result"]["endRevision"], "r0");
    assert_eq!(outcome.response()["result"]["limit"], 25);
    assert_eq!(outcome.response()["result"]["entries"][0]["revision"], 7);
    assert_eq!(
        outcome.response()["result"]["entries"][0]["author"],
        "alice"
    );
    assert_eq!(
        outcome.response()["result"]["entries"][0]["changedPaths"][0]["path"],
        "/trunk/src/main.c"
    );
    assert_eq!(
        outcome.response()["result"]["entries"][0]["changedPaths"][0]["textModified"],
        "true"
    );
    assert_eq!(
        outcome.response()["result"]["entries"][0]["changedPaths"][0]["propertiesModified"],
        "false"
    );
    assert_eq!(outcome.response()["result"]["source"], "libsvn-log");

    let requests = bridge.history_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].path, "src/main.c");
    assert_eq!(requests[0].start_revision, "head");
    assert_eq!(requests[0].end_revision, "r0");
    assert_eq!(requests[0].limit, 25);
    assert!(requests[0].discover_changed_paths);
    assert!(requests[0].strict_node_history);
    assert!(!requests[0].include_merged_revisions);
}

#[test]
fn history_log_accepts_root_history_path() {
    let bridge = FakeBridge::open_success().with_history_result(
        ".",
        Ok(HistoryLogResult {
            entries: Vec::new(),
            source: "libsvn-log".to_string(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":66,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":67,"method":"history/log","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"path":".","startRevision":"r10","endRevision":"r0","limit":1,"discoverChangedPaths":false,"strictNodeHistory":false,"includeMergedRevisions":true}}"#,
            &bridge,
        )
        .expect("history/log should dispatch");

    assert_eq!(outcome.response()["result"]["path"], ".");
    assert_eq!(outcome.response()["result"]["startRevision"], "r10");
    assert_eq!(outcome.response()["result"]["limit"], 1);
    assert!(bridge.history_requests.borrow()[0].include_merged_revisions);
}

#[test]
fn history_log_rejects_invalid_params_before_bridge_call() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":68,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    for (request_id, params, field) in [
        (
            69,
            r#""path":"src\\main.c","startRevision":"head","endRevision":"r0","limit":25,"discoverChangedPaths":true,"strictNodeHistory":true,"includeMergedRevisions":false"#,
            "path",
        ),
        (
            70,
            r#""path":"../outside.c","startRevision":"head","endRevision":"r0","limit":25,"discoverChangedPaths":true,"strictNodeHistory":true,"includeMergedRevisions":false"#,
            "path",
        ),
        (
            71,
            r#""path":"src/main.c","startRevision":"base","endRevision":"r0","limit":25,"discoverChangedPaths":true,"strictNodeHistory":true,"includeMergedRevisions":false"#,
            "startRevision",
        ),
        (
            72,
            r#""path":"src/main.c","startRevision":"HEAD","endRevision":"r0","limit":25,"discoverChangedPaths":true,"strictNodeHistory":true,"includeMergedRevisions":false"#,
            "startRevision",
        ),
        (
            73,
            r#""path":"src/main.c","startRevision":"head","endRevision":"head","limit":25,"discoverChangedPaths":true,"strictNodeHistory":true,"includeMergedRevisions":false"#,
            "endRevision",
        ),
        (
            74,
            r#""path":"src/main.c","startRevision":"head","endRevision":"r01","limit":25,"discoverChangedPaths":true,"strictNodeHistory":true,"includeMergedRevisions":false"#,
            "endRevision",
        ),
        (
            75,
            r#""path":"src/main.c","startRevision":"head","endRevision":"r0","limit":0,"discoverChangedPaths":true,"strictNodeHistory":true,"includeMergedRevisions":false"#,
            "limit",
        ),
        (
            76,
            r#""path":"src/main.c","startRevision":"head","endRevision":"r0","limit":501,"discoverChangedPaths":true,"strictNodeHistory":true,"includeMergedRevisions":false"#,
            "limit",
        ),
        (
            77,
            r#""path":"src/main.c","startRevision":"head","endRevision":"r0","limit":25,"discoverChangedPaths":true,"strictNodeHistory":true,"includeMergedRevisions":false,"extra":true"#,
            "extra",
        ),
    ] {
        let request = format!(
            r#"{{"jsonrpc":"2.0","id":{request_id},"method":"history/log","params":{{"repositoryId":"repo-uuid:C:/wc","epoch":1,{params}}}}}"#
        );
        let outcome = state
            .dispatch_json_rpc_with_bridge(&request, &bridge)
            .unwrap_or_else(|error| panic!("request {request_id} should dispatch: {error}"));

        assert_eq!(outcome.response()["error"]["code"], "RPC_INVALID_PARAMS");
        assert_eq!(outcome.response()["error"]["args"]["field"], field);
    }
    assert!(bridge.history_requests.borrow().is_empty());
}

#[test]
fn history_log_requires_matching_open_repository_epoch() {
    let bridge = FakeBridge::open_success().with_history_result(
        "src/main.c",
        Ok(HistoryLogResult {
            entries: Vec::new(),
            source: "libsvn-log".to_string(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":78,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":79,"method":"history/log","params":{"repositoryId":"repo-uuid:C:/wc","epoch":2,"path":"src/main.c","startRevision":"head","endRevision":"r0","limit":25,"discoverChangedPaths":true,"strictNodeHistory":true,"includeMergedRevisions":false}}"#,
            &bridge,
        )
        .expect("history/log should dispatch");

    assert_eq!(outcome.response()["error"]["code"], "REPOSITORY_NOT_OPEN");
    assert!(bridge.history_requests.borrow().is_empty());
}

#[test]
fn history_log_reports_auth_broker_unavailable_on_non_stdio_dispatch() {
    let bridge = FakeBridge::open_success()
        .with_history_requires_auth()
        .with_history_result(
            "src/main.c",
            Ok(HistoryLogResult {
                entries: Vec::new(),
                source: "libsvn-log".to_string(),
            }),
        );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":80,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":81,"method":"history/log","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"path":"src/main.c","startRevision":"head","endRevision":"r0","limit":25,"discoverChangedPaths":true,"strictNodeHistory":true,"includeMergedRevisions":false}}"#,
            &bridge,
        )
        .expect("history/log should dispatch");

    assert_eq!(
        outcome.response()["error"]["code"],
        "SUBVERSIONR_AUTH_BROKER_UNAVAILABLE"
    );
    assert_eq!(outcome.response()["error"]["category"], "auth");
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.auth.brokerUnavailable"
    );
    assert_eq!(
        outcome.response()["error"]["args"]["method"],
        "credentials/request"
    );
}

#[test]
fn history_blame_returns_windowed_lines_for_open_repository() {
    let bridge = FakeBridge::open_success().with_blame_result(
        "src/main.c",
        Ok(HistoryBlameResult {
            resolved_start_revision: 1,
            resolved_end_revision: 7,
            line_start: 1,
            line_limit: 2,
            ignore_whitespace: "none".to_string(),
            ignore_eol_style: false,
            ignore_mime_type: false,
            include_merged_revisions: true,
            has_more: true,
            lines: vec![
                HistoryBlameLine {
                    line_number: 1,
                    revision: Some(7),
                    author: Some("alice".to_string()),
                    date: Some("2026-06-23T00:00:00.000000Z".to_string()),
                    merged_revision: None,
                    merged_author: None,
                    merged_date: None,
                    merged_path: None,
                    line_base64: "bGluZSAx".to_string(),
                    byte_length: 6,
                    local_change: false,
                },
                HistoryBlameLine {
                    line_number: 2,
                    revision: Some(6),
                    author: Some("bob".to_string()),
                    date: Some("2026-06-22T00:00:00.000000Z".to_string()),
                    merged_revision: Some(5),
                    merged_author: Some("carol".to_string()),
                    merged_date: Some("2026-06-21T00:00:00.000000Z".to_string()),
                    merged_path: Some("/branches/feature/src/main.c".to_string()),
                    line_base64: "bGluZSAy".to_string(),
                    byte_length: 6,
                    local_change: false,
                },
            ],
            source: "libsvn-blame".to_string(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":80,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":81,"method":"history/blame","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"path":"src/main.c","pegRevision":"base","startRevision":"r0","endRevision":"base","lineStart":1,"lineLimit":2,"ignoreWhitespace":"none","ignoreEolStyle":false,"ignoreMimeType":false,"includeMergedRevisions":true}}"#,
            &bridge,
        )
        .expect("history/blame should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(
        outcome.response()["result"]["repositoryId"],
        "repo-uuid:C:/wc"
    );
    assert_eq!(outcome.response()["result"]["epoch"], 1);
    assert_eq!(outcome.response()["result"]["path"], "src/main.c");
    assert_eq!(outcome.response()["result"]["pegRevision"], "base");
    assert_eq!(outcome.response()["result"]["startRevision"], "r0");
    assert_eq!(outcome.response()["result"]["endRevision"], "base");
    assert_eq!(outcome.response()["result"]["resolvedStartRevision"], 1);
    assert_eq!(outcome.response()["result"]["resolvedEndRevision"], 7);
    assert_eq!(outcome.response()["result"]["lineStart"], 1);
    assert_eq!(outcome.response()["result"]["lineLimit"], 2);
    assert_eq!(outcome.response()["result"]["ignoreWhitespace"], "none");
    assert_eq!(outcome.response()["result"]["ignoreEolStyle"], false);
    assert_eq!(outcome.response()["result"]["ignoreMimeType"], false);
    assert_eq!(outcome.response()["result"]["includeMergedRevisions"], true);
    assert_eq!(outcome.response()["result"]["hasMore"], true);
    assert_eq!(outcome.response()["result"]["lines"][0]["lineNumber"], 1);
    assert_eq!(outcome.response()["result"]["lines"][0]["revision"], 7);
    assert_eq!(
        outcome.response()["result"]["lines"][0]["lineBase64"],
        "bGluZSAx"
    );
    assert_eq!(outcome.response()["result"]["lines"][0]["byteLength"], 6);
    assert_eq!(
        outcome.response()["result"]["lines"][1]["mergedPath"],
        "/branches/feature/src/main.c"
    );
    assert_eq!(outcome.response()["result"]["source"], "libsvn-blame");

    let requests = bridge.blame_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].path, "src/main.c");
    assert_eq!(requests[0].peg_revision, "base");
    assert_eq!(requests[0].start_revision, "r0");
    assert_eq!(requests[0].end_revision, "base");
    assert_eq!(requests[0].line_start, 1);
    assert_eq!(requests[0].line_limit, 2);
    assert_eq!(requests[0].ignore_whitespace, "none");
    assert!(!requests[0].ignore_eol_style);
    assert!(!requests[0].ignore_mime_type);
    assert!(requests[0].include_merged_revisions);
}

#[test]
fn history_blame_rejects_invalid_params_before_bridge_call() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":82,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    for (request_id, params, field) in [
        (
            83,
            r#""path":".","pegRevision":"head","startRevision":"r0","endRevision":"head","lineStart":1,"lineLimit":50,"ignoreWhitespace":"none","ignoreEolStyle":false,"ignoreMimeType":false,"includeMergedRevisions":false"#,
            "path",
        ),
        (
            84,
            r#""path":"src\\main.c","pegRevision":"head","startRevision":"r0","endRevision":"head","lineStart":1,"lineLimit":50,"ignoreWhitespace":"none","ignoreEolStyle":false,"ignoreMimeType":false,"includeMergedRevisions":false"#,
            "path",
        ),
        (
            85,
            r#""path":"src/main.c","pegRevision":"working","startRevision":"r0","endRevision":"head","lineStart":1,"lineLimit":50,"ignoreWhitespace":"none","ignoreEolStyle":false,"ignoreMimeType":false,"includeMergedRevisions":false"#,
            "pegRevision",
        ),
        (
            86,
            r#""path":"src/main.c","pegRevision":"head","startRevision":"head","endRevision":"head","lineStart":1,"lineLimit":50,"ignoreWhitespace":"none","ignoreEolStyle":false,"ignoreMimeType":false,"includeMergedRevisions":false"#,
            "startRevision",
        ),
        (
            87,
            r#""path":"src/main.c","pegRevision":"head","startRevision":"r0","endRevision":"working","lineStart":1,"lineLimit":50,"ignoreWhitespace":"none","ignoreEolStyle":false,"ignoreMimeType":false,"includeMergedRevisions":false"#,
            "endRevision",
        ),
        (
            88,
            r#""path":"src/main.c","pegRevision":"head","startRevision":"r0","endRevision":"head","lineStart":0,"lineLimit":50,"ignoreWhitespace":"none","ignoreEolStyle":false,"ignoreMimeType":false,"includeMergedRevisions":false"#,
            "lineStart",
        ),
        (
            89,
            r#""path":"src/main.c","pegRevision":"head","startRevision":"r0","endRevision":"head","lineStart":9223372036854775808,"lineLimit":50,"ignoreWhitespace":"none","ignoreEolStyle":false,"ignoreMimeType":false,"includeMergedRevisions":false"#,
            "lineStart",
        ),
        (
            90,
            r#""path":"src/main.c","pegRevision":"head","startRevision":"r0","endRevision":"head","lineStart":1,"lineLimit":0,"ignoreWhitespace":"none","ignoreEolStyle":false,"ignoreMimeType":false,"includeMergedRevisions":false"#,
            "lineLimit",
        ),
        (
            91,
            r#""path":"src/main.c","pegRevision":"head","startRevision":"r0","endRevision":"head","lineStart":1,"lineLimit":5001,"ignoreWhitespace":"none","ignoreEolStyle":false,"ignoreMimeType":false,"includeMergedRevisions":false"#,
            "lineLimit",
        ),
        (
            92,
            r#""path":"src/main.c","pegRevision":"head","startRevision":"r0","endRevision":"head","lineStart":1,"lineLimit":50,"ignoreWhitespace":"tabs","ignoreEolStyle":false,"ignoreMimeType":false,"includeMergedRevisions":false"#,
            "ignoreWhitespace",
        ),
        (
            93,
            r#""path":"src/main.c","pegRevision":"head","startRevision":"r0","endRevision":"head","lineStart":1,"lineLimit":50,"ignoreWhitespace":"none","ignoreEolStyle":false,"ignoreMimeType":false,"includeMergedRevisions":false,"extra":true"#,
            "extra",
        ),
    ] {
        let request = format!(
            r#"{{"jsonrpc":"2.0","id":{request_id},"method":"history/blame","params":{{"repositoryId":"repo-uuid:C:/wc","epoch":1,{params}}}}}"#
        );
        let outcome = state
            .dispatch_json_rpc_with_bridge(&request, &bridge)
            .unwrap_or_else(|error| panic!("request {request_id} should dispatch: {error}"));

        assert_eq!(outcome.response()["error"]["code"], "RPC_INVALID_PARAMS");
        assert_eq!(outcome.response()["error"]["args"]["field"], field);
    }
    assert!(bridge.blame_requests.borrow().is_empty());
}

#[test]
fn history_blame_requires_matching_open_repository_epoch() {
    let bridge = FakeBridge::open_success().with_blame_result(
        "src/main.c",
        Ok(HistoryBlameResult {
            resolved_start_revision: 1,
            resolved_end_revision: 7,
            line_start: 1,
            line_limit: 50,
            ignore_whitespace: "none".to_string(),
            ignore_eol_style: false,
            ignore_mime_type: false,
            include_merged_revisions: false,
            has_more: false,
            lines: Vec::new(),
            source: "libsvn-blame".to_string(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":92,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":93,"method":"history/blame","params":{"repositoryId":"repo-uuid:C:/wc","epoch":2,"path":"src/main.c","pegRevision":"head","startRevision":"r0","endRevision":"head","lineStart":1,"lineLimit":50,"ignoreWhitespace":"none","ignoreEolStyle":false,"ignoreMimeType":false,"includeMergedRevisions":false}}"#,
            &bridge,
        )
        .expect("history/blame should dispatch");

    assert_eq!(outcome.response()["error"]["code"], "REPOSITORY_NOT_OPEN");
    assert!(bridge.blame_requests.borrow().is_empty());
}

#[test]
fn history_blame_reports_auth_broker_unavailable_on_non_stdio_dispatch() {
    let bridge = FakeBridge::open_success()
        .with_blame_requires_auth()
        .with_blame_result(
            "src/main.c",
            Ok(HistoryBlameResult {
                resolved_start_revision: 0,
                resolved_end_revision: 1,
                line_start: 1,
                line_limit: 2,
                ignore_whitespace: "none".to_string(),
                ignore_eol_style: false,
                ignore_mime_type: false,
                include_merged_revisions: false,
                has_more: false,
                lines: Vec::new(),
                source: "libsvn-blame".to_string(),
            }),
        );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":94,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":95,"method":"history/blame","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"path":"src/main.c","pegRevision":"head","startRevision":"r0","endRevision":"head","lineStart":1,"lineLimit":2,"ignoreWhitespace":"none","ignoreEolStyle":false,"ignoreMimeType":false,"includeMergedRevisions":false}}"#,
            &bridge,
        )
        .expect("history/blame should dispatch");

    assert_eq!(
        outcome.response()["error"]["code"],
        "SUBVERSIONR_AUTH_BROKER_UNAVAILABLE"
    );
    assert_eq!(outcome.response()["error"]["category"], "auth");
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.auth.brokerUnavailable"
    );
    assert_eq!(
        outcome.response()["error"]["args"]["method"],
        "credentials/request"
    );
}

#[test]
fn operation_run_revert_returns_touched_paths_and_reconcile_hint() {
    let bridge = FakeBridge::open_success().with_revert_result(
        "tracked.txt",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec!["tracked.txt".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":61,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":62,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"revert","options":{"version":1,"paths":["tracked.txt"],"depth":"empty","changelists":[],"clearChangelists":false,"metadataOnly":false,"addedKeepLocal":false}}}"#,
            &bridge,
        )
        .expect("operation/run should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(
        outcome.response()["result"]["repositoryId"],
        "repo-uuid:C:/wc"
    );
    assert_eq!(outcome.response()["result"]["epoch"], 1);
    assert_eq!(outcome.response()["result"]["operationId"], "op-1");
    assert_eq!(outcome.response()["result"]["kind"], "revert");
    assert_eq!(
        outcome.response()["result"]["touchedPaths"][0],
        "tracked.txt"
    );
    assert_eq!(
        outcome.response()["result"]["revision"],
        serde_json::Value::Null
    );
    assert_eq!(outcome.response()["result"]["summary"]["affectedPaths"], 1);
    assert_eq!(outcome.response()["result"]["summary"]["skippedPaths"], 0);
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["path"],
        "tracked.txt"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["depth"],
        "empty"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["reason"],
        "operationRevert"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["requiresFullReconcile"],
        false
    );
}

#[test]
fn operation_run_add_returns_touched_paths_and_reconcile_hint() {
    let bridge = FakeBridge::open_success().with_add_result(
        "scratch.txt",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec!["scratch.txt".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":72,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":73,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"add","options":{"version":1,"paths":["scratch.txt"],"depth":"empty","force":false,"noIgnore":false,"noAutoprops":false,"addParents":false}}}"#,
            &bridge,
        )
        .expect("operation/run add should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["kind"], "add");
    assert_eq!(
        outcome.response()["result"]["touchedPaths"][0],
        "scratch.txt"
    );
    assert_eq!(outcome.response()["result"]["summary"]["affectedPaths"], 1);
    assert_eq!(outcome.response()["result"]["summary"]["skippedPaths"], 0);
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["path"],
        "scratch.txt"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["depth"],
        "empty"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["reason"],
        "operationAdd"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["requiresFullReconcile"],
        false
    );
}

#[test]
fn operation_run_add_rejects_multiple_paths_to_preserve_failure_reconcile_safety() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":170,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":171,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"add","options":{"version":1,"paths":["scratch-a.txt","scratch-b.txt"],"depth":"empty","force":false,"noIgnore":false,"noAutoprops":false,"addParents":false}}}"#,
            &bridge,
        )
        .expect("operation/run add should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["error"]["code"], "RPC_INVALID_PARAMS");
    assert_eq!(
        outcome.response()["error"]["args"]["field"],
        "options.paths"
    );
    assert!(bridge.add_requests.borrow().is_empty());
}

#[test]
fn operation_run_remove_returns_touched_paths_and_reconcile_hint() {
    let bridge = FakeBridge::open_success().with_remove_result(
        "src/old.c",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec!["src/old.c".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":74,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":75,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"remove","options":{"version":1,"paths":["src/old.c"],"force":false,"keepLocal":false}}}"#,
            &bridge,
        )
        .expect("operation/run remove should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["kind"], "remove");
    assert_eq!(outcome.response()["result"]["touchedPaths"][0], "src/old.c");
    assert_eq!(outcome.response()["result"]["summary"]["affectedPaths"], 1);
    assert_eq!(outcome.response()["result"]["summary"]["skippedPaths"], 0);
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["path"],
        "src/old.c"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["depth"],
        "empty"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["reason"],
        "operationRemove"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["requiresFullReconcile"],
        false
    );
}

#[test]
fn operation_run_remove_accepts_multiple_paths_and_returns_targeted_reconcile_hints() {
    let bridge = FakeBridge::open_success().with_remove_result(
        "src/old.c",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec!["src/old.c".to_string(), "src/other.c".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":172,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":173,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"remove","options":{"version":1,"paths":["src/old.c","src/other.c"],"force":false,"keepLocal":false}}}"#,
            &bridge,
        )
        .expect("operation/run remove should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["kind"], "remove");
    assert_eq!(outcome.response()["result"]["touchedPaths"][0], "src/old.c");
    assert_eq!(
        outcome.response()["result"]["touchedPaths"][1],
        "src/other.c"
    );
    assert_eq!(outcome.response()["result"]["summary"]["affectedPaths"], 2);
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["path"],
        "src/old.c"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][1]["path"],
        "src/other.c"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["reason"],
        "operationRemove"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][1]["reason"],
        "operationRemove"
    );
    let requests = bridge.remove_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0].paths,
        vec!["src/old.c".to_string(), "src/other.c".to_string()]
    );
}

#[test]
fn operation_run_remove_forwards_force_and_keep_local_options_to_bridge() {
    let bridge = FakeBridge::open_success().with_remove_result(
        "src/keep.c",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec!["src/keep.c".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":76,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":77,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"remove","options":{"version":1,"paths":["src/keep.c"],"force":true,"keepLocal":true}}}"#,
            &bridge,
        )
        .expect("operation/run remove should dispatch");

    let requests = bridge.remove_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0],
        subversionr_daemon::RemoveOperationRequest {
            paths: vec!["src/keep.c".to_string()],
            force: true,
            keep_local: true,
        }
    );
}

#[test]
fn operation_run_move_returns_touched_paths_and_reconcile_hint() {
    let bridge = FakeBridge::open_success().with_move_result(
        "src/old.c",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec!["src/old.c".to_string(), "src/new.c".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":78,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":79,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"move","options":{"version":1,"sourcePath":"src/old.c","destinationPath":"src/new.c","makeParents":false}}}"#,
            &bridge,
        )
        .expect("operation/run move should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["kind"], "move");
    assert_eq!(outcome.response()["result"]["touchedPaths"][0], "src/old.c");
    assert_eq!(outcome.response()["result"]["touchedPaths"][1], "src/new.c");
    assert_eq!(outcome.response()["result"]["summary"]["affectedPaths"], 2);
    assert_eq!(outcome.response()["result"]["summary"]["skippedPaths"], 0);
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["path"],
        "src"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["depth"],
        "immediates"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["reason"],
        "operationMove"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["requiresFullReconcile"],
        false
    );
}

#[test]
fn operation_run_move_returns_parent_reconcile_hints_for_cross_directory_move() {
    let bridge = FakeBridge::open_success().with_move_result(
        "src/old.c",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec!["src/old.c".to_string(), "assets/new.c".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":780,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":781,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"move","options":{"version":1,"sourcePath":"src/old.c","destinationPath":"assets/new.c","makeParents":false}}}"#,
            &bridge,
        )
        .expect("operation/run move should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["path"],
        "src"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][1]["path"],
        "assets"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["depth"],
        "immediates"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][1]["depth"],
        "immediates"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["reason"],
        "operationMove"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][1]["reason"],
        "operationMove"
    );
}

#[test]
fn operation_run_move_forwards_make_parent_option_to_bridge() {
    let bridge = FakeBridge::open_success().with_move_result(
        "src/old.c",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec!["src/old.c".to_string(), "src/nested/new.c".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":80,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":81,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"move","options":{"version":1,"sourcePath":"src/old.c","destinationPath":"src/nested/new.c","makeParents":true}}}"#,
            &bridge,
        )
        .expect("operation/run move should dispatch");

    let requests = bridge.move_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0],
        subversionr_daemon::MoveOperationRequest {
            source_path: "src/old.c".to_string(),
            destination_path: "src/nested/new.c".to_string(),
            make_parents: true,
        }
    );
}

#[test]
fn operation_run_resolve_returns_touched_paths_and_reconcile_hint() {
    let bridge = FakeBridge::open_success().with_resolve_result(
        "src/conflicted.txt",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec!["src/conflicted.txt".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":78,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":79,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"resolve","options":{"version":1,"paths":["src/conflicted.txt"],"depth":"empty","choice":"working"}}}"#,
            &bridge,
        )
        .expect("operation/run resolve should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["kind"], "resolve");
    assert_eq!(
        outcome.response()["result"]["touchedPaths"][0],
        "src/conflicted.txt"
    );
    assert_eq!(outcome.response()["result"]["summary"]["affectedPaths"], 1);
    assert_eq!(outcome.response()["result"]["summary"]["skippedPaths"], 0);
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["path"],
        "src/conflicted.txt"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["depth"],
        "empty"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["reason"],
        "operationResolve"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["requiresFullReconcile"],
        false
    );
}

#[test]
fn operation_run_resolve_forwards_working_choice_to_bridge() {
    let bridge = FakeBridge::open_success().with_resolve_result(
        "src/conflicted.txt",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec!["src/conflicted.txt".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":84,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":85,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"resolve","options":{"version":1,"paths":["src/conflicted.txt"],"depth":"empty","choice":"working"}}}"#,
            &bridge,
        )
        .expect("operation/run resolve should dispatch");

    let requests = bridge.resolve_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0],
        subversionr_daemon::ResolveOperationRequest {
            paths: vec!["src/conflicted.txt".to_string()],
            depth: "empty".to_string(),
            choice: "working".to_string(),
        }
    );
}

#[test]
fn operation_run_resolve_forwards_hunk_conflict_choices_to_bridge() {
    for (index, choice) in ["mineConflict", "theirsConflict"].iter().enumerate() {
        let bridge = FakeBridge::open_success().with_resolve_result(
            "src/conflicted.txt",
            Ok(subversionr_daemon::OperationResult {
                touched_paths: vec!["src/conflicted.txt".to_string()],
                skipped_paths: Vec::new(),
            }),
        );
        let mut state = DaemonState::new();
        state
            .dispatch_json_rpc_with_bridge(
                r#"{"jsonrpc":"2.0","id":86,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
                &bridge,
            )
            .expect("repository/open should dispatch");

        let request = format!(
            r#"{{"jsonrpc":"2.0","id":{},"method":"operation/run","params":{{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"resolve","options":{{"version":1,"paths":["src/conflicted.txt"],"depth":"empty","choice":"{}"}}}}}}"#,
            87 + index,
            choice
        );
        let outcome = state
            .dispatch_json_rpc_with_bridge(&request, &bridge)
            .expect("operation/run resolve should dispatch");

        assert_eq!(outcome, DispatchOutcome::Continue);
        let requests = bridge.resolve_requests.borrow();
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].choice, *choice);
    }
}

#[test]
fn operation_run_resolve_maps_bridge_failure_to_structured_error() {
    let bridge = FakeBridge::open_success().with_resolve_result(
        "src/conflicted.txt",
        Err(subversionr_daemon::BridgeFailure::new(
            "SVN_OPERATION_RESOLVE_FAILED",
            "native",
            "error.native.operationResolveFailed",
            serde_json::json!({ "path": "C:/wc/src/conflicted.txt" }),
            false,
        )),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":86,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":87,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"resolve","options":{"version":1,"paths":["src/conflicted.txt"],"depth":"empty","choice":"working"}}}"#,
            &bridge,
        )
        .expect("operation/run resolve should dispatch");

    assert_eq!(
        outcome.response()["error"]["code"],
        "SVN_OPERATION_RESOLVE_FAILED"
    );
    assert_eq!(outcome.response()["error"]["category"], "native");
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.native.operationResolveFailed"
    );
}

#[test]
fn operation_run_rejects_invalid_resolve_options() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":88,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    for (request_id, request, field) in [
        (
            89,
            r#"{"jsonrpc":"2.0","id":89,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"resolve","options":{"version":2,"paths":["src/conflicted.txt"],"depth":"empty","choice":"working"}}}"#,
            "options.version",
        ),
        (
            90,
            r#"{"jsonrpc":"2.0","id":90,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"resolve","options":{"version":1,"paths":["src/conflicted.txt","src/other.txt"],"depth":"empty","choice":"working"}}}"#,
            "options.paths",
        ),
        (
            91,
            r#"{"jsonrpc":"2.0","id":91,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"resolve","options":{"version":1,"paths":["..\\conflicted.txt"],"depth":"empty","choice":"working"}}}"#,
            "options.paths",
        ),
        (
            92,
            r#"{"jsonrpc":"2.0","id":92,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"resolve","options":{"version":1,"paths":["src/conflicted.txt"],"depth":"files","choice":"working"}}}"#,
            "options.depth",
        ),
        (
            93,
            r#"{"jsonrpc":"2.0","id":93,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"resolve","options":{"version":1,"paths":["src/conflicted.txt"],"depth":"immediates","choice":"working"}}}"#,
            "options.depth",
        ),
        (
            94,
            r#"{"jsonrpc":"2.0","id":94,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"resolve","options":{"version":1,"paths":["src/conflicted.txt"],"depth":"infinity","choice":"working"}}}"#,
            "options.depth",
        ),
        (
            95,
            r#"{"jsonrpc":"2.0","id":95,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"resolve","options":{"version":1,"paths":["src/conflicted.txt"],"depth":"empty","choice":"merged"}}}"#,
            "options.choice",
        ),
        (
            96,
            r#"{"jsonrpc":"2.0","id":96,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"resolve","options":{"version":1,"paths":["src/conflicted.txt"],"depth":"empty","choice":"working","recursive":true}}}"#,
            "options.recursive",
        ),
    ] {
        let outcome = state
            .dispatch_json_rpc_with_bridge(request, &bridge)
            .unwrap_or_else(|error| panic!("request {request_id} should dispatch: {error}"));
        assert_eq!(
            outcome.response()["error"]["code"],
            "RPC_INVALID_PARAMS",
            "request {request_id} should fail with invalid params",
        );
        assert_eq!(
            outcome.response()["error"]["args"]["field"],
            field,
            "request {request_id} should report {field}",
        );
    }

    assert_eq!(bridge.resolve_requests.borrow().len(), 0);
}

#[test]
fn operation_run_cleanup_returns_full_reconcile_hint() {
    let bridge = FakeBridge::open_success().with_cleanup_result(
        ".",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec![".".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":80,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":81,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"cleanup","options":{"version":1,"path":".","breakLocks":true,"fixRecordedTimestamps":false,"clearDavCache":false,"vacuumPristines":false,"includeExternals":false}}}"#,
            &bridge,
        )
        .expect("operation/run cleanup should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["kind"], "cleanup");
    assert_eq!(outcome.response()["result"]["touchedPaths"][0], ".");
    assert_eq!(outcome.response()["result"]["summary"]["affectedPaths"], 1);
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"]
            .as_array()
            .expect("targets should be an array")
            .len(),
        0
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["requiresFullReconcile"],
        true
    );
    assert_eq!(outcome.notifications().len(), 1);
    assert_eq!(outcome.notifications()[0]["method"], "status/stale");
    assert_eq!(
        outcome.notifications()[0]["params"]["repositoryId"],
        "repo-uuid:C:/wc"
    );
    assert_eq!(outcome.notifications()[0]["params"]["epoch"], 1);
    assert_eq!(
        outcome.notifications()[0]["params"]["reason"],
        "operationCleanupRequiresFullReconcile"
    );
    assert_eq!(
        outcome.notifications()[0]["params"]["source"],
        "subversionr-daemon"
    );
    assert!(outcome.notifications()[0].get("id").is_none());
}

#[test]
fn operation_run_cleanup_forwards_all_cleanup_options_to_bridge() {
    let bridge = FakeBridge::open_success().with_cleanup_result(
        ".",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec![".".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":82,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":83,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"cleanup","options":{"version":1,"path":".","breakLocks":true,"fixRecordedTimestamps":true,"clearDavCache":true,"vacuumPristines":true,"includeExternals":true}}}"#,
            &bridge,
        )
        .expect("operation/run cleanup should dispatch");

    let requests = bridge.cleanup_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0],
        subversionr_daemon::CleanupOperationRequest {
            path: ".".to_string(),
            break_locks: true,
            fix_recorded_timestamps: true,
            clear_dav_cache: true,
            vacuum_pristines: true,
            include_externals: true,
        }
    );
}

#[test]
fn operation_run_upgrade_returns_full_reconcile_hint() {
    let bridge = FakeBridge::open_success().with_upgrade_result(
        ".",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec![".".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":84,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":85,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"upgrade","options":{"version":1,"path":"."}}}"#,
            &bridge,
        )
        .expect("operation/run upgrade should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["kind"], "upgrade");
    assert_eq!(outcome.response()["result"]["touchedPaths"][0], ".");
    assert_eq!(outcome.response()["result"]["summary"]["affectedPaths"], 1);
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"]
            .as_array()
            .expect("targets should be an array")
            .len(),
        0
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["requiresFullReconcile"],
        true
    );
    assert_eq!(outcome.notifications().len(), 1);
    assert_eq!(outcome.notifications()[0]["method"], "status/stale");
    assert_eq!(
        outcome.notifications()[0]["params"]["reason"],
        "operationUpgradeRequiresFullReconcile"
    );

    let requests = bridge.upgrade_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0],
        subversionr_daemon::UpgradeOperationRequest {
            path: ".".to_string(),
        }
    );
}

#[test]
fn operation_run_update_returns_revision_and_full_reconcile_hint() {
    let bridge = FakeBridge::open_success().with_update_result(
        ".",
        Ok(subversionr_daemon::UpdateOperationResult {
            result: subversionr_daemon::OperationResult {
                touched_paths: vec![".".to_string()],
                skipped_paths: Vec::new(),
            },
            revision: 8,
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":97,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":98,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"update","options":{"version":1,"path":".","revision":"head","depth":"workingCopy","depthIsSticky":false,"ignoreExternals":true}}}"#,
            &bridge,
        )
        .expect("operation/run update should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["kind"], "update");
    assert_eq!(outcome.response()["result"]["touchedPaths"][0], ".");
    assert_eq!(outcome.response()["result"]["revision"], 8);
    assert_eq!(outcome.response()["result"]["summary"]["affectedPaths"], 1);
    assert_eq!(outcome.response()["result"]["summary"]["skippedPaths"], 0);
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"]
            .as_array()
            .expect("targets should be an array")
            .len(),
        0
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["requiresFullReconcile"],
        true
    );
    assert_eq!(outcome.notifications().len(), 1);
    assert_eq!(outcome.notifications()[0]["method"], "status/stale");
    assert_eq!(
        outcome.notifications()[0]["params"]["repositoryId"],
        "repo-uuid:C:/wc"
    );
    assert_eq!(outcome.notifications()[0]["params"]["epoch"], 1);
    assert_eq!(
        outcome.notifications()[0]["params"]["reason"],
        "operationUpdateRequiresFullReconcile"
    );
    assert_eq!(
        outcome.notifications()[0]["params"]["source"],
        "subversionr-daemon"
    );
    assert!(outcome.notifications()[0].get("id").is_none());
}

#[test]
fn operation_run_update_forwards_head_working_copy_options_to_bridge() {
    let bridge = FakeBridge::open_success().with_update_result(
        ".",
        Ok(subversionr_daemon::UpdateOperationResult {
            result: subversionr_daemon::OperationResult {
                touched_paths: vec![".".to_string()],
                skipped_paths: Vec::new(),
            },
            revision: 8,
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":99,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":100,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"update","options":{"version":1,"path":".","revision":"head","depth":"workingCopy","depthIsSticky":false,"ignoreExternals":true}}}"#,
            &bridge,
        )
        .expect("operation/run update should dispatch");

    let requests = bridge.update_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0],
        subversionr_daemon::UpdateOperationRequest {
            path: ".".to_string(),
            revision: "head".to_string(),
            depth: "workingCopy".to_string(),
            depth_is_sticky: false,
            ignore_externals: true,
        }
    );
}

#[test]
fn operation_run_update_forwards_revision_depth_and_externals_options_to_bridge() {
    let bridge = FakeBridge::open_success().with_update_result(
        "src",
        Ok(subversionr_daemon::UpdateOperationResult {
            result: subversionr_daemon::OperationResult {
                touched_paths: vec!["src".to_string()],
                skipped_paths: Vec::new(),
            },
            revision: 42,
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":116,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":117,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"update","options":{"version":1,"path":"src","revision":42,"depth":"files","depthIsSticky":true,"ignoreExternals":false}}}"#,
            &bridge,
        )
        .expect("operation/run update should dispatch");

    let requests = bridge.update_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0],
        subversionr_daemon::UpdateOperationRequest {
            path: "src".to_string(),
            revision: "42".to_string(),
            depth: "files".to_string(),
            depth_is_sticky: true,
            ignore_externals: false,
        }
    );
}

#[test]
fn operation_run_resolve_forwards_explicit_theirs_full_choice_to_bridge() {
    let bridge = FakeBridge::open_success().with_resolve_result(
        "src/conflicted.txt",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec!["src/conflicted.txt".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":118,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":119,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"resolve","options":{"version":1,"paths":["src/conflicted.txt"],"depth":"empty","choice":"theirsFull"}}}"#,
            &bridge,
        )
        .expect("operation/run resolve should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["kind"], "resolve");
    let requests = bridge.resolve_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0],
        subversionr_daemon::ResolveOperationRequest {
            paths: vec!["src/conflicted.txt".to_string()],
            depth: "empty".to_string(),
            choice: "theirsFull".to_string(),
        }
    );
}

#[test]
fn operation_run_update_accepts_selected_repository_relative_path() {
    let bridge = FakeBridge::open_success().with_update_result(
        "src/main.c",
        Ok(subversionr_daemon::UpdateOperationResult {
            result: subversionr_daemon::OperationResult {
                touched_paths: vec!["src/main.c".to_string()],
                skipped_paths: Vec::new(),
            },
            revision: 8,
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":112,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":113,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"update","options":{"version":1,"path":"src/main.c","revision":"head","depth":"workingCopy","depthIsSticky":false,"ignoreExternals":true}}}"#,
            &bridge,
        )
        .expect("operation/run selected update should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["kind"], "update");
    assert_eq!(
        outcome.response()["result"]["touchedPaths"][0],
        "src/main.c"
    );
    assert_eq!(outcome.response()["result"]["revision"], 8);
    assert_eq!(
        outcome.response()["result"]["reconcile"]["requiresFullReconcile"],
        true
    );
    let requests = bridge.update_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0],
        subversionr_daemon::UpdateOperationRequest {
            path: "src/main.c".to_string(),
            revision: "head".to_string(),
            depth: "workingCopy".to_string(),
            depth_is_sticky: false,
            ignore_externals: true,
        }
    );
}

#[test]
fn operation_run_update_maps_bridge_failure_to_structured_error() {
    let bridge = FakeBridge::open_success().with_update_result(
        ".",
        Err(subversionr_daemon::BridgeFailure::new(
            "SVN_OPERATION_UPDATE_FAILED",
            "native",
            "error.native.operationUpdateFailed",
            serde_json::json!({ "path": "C:/wc", "kind": "update" }),
            false,
        )),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":101,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":102,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"update","options":{"version":1,"path":".","revision":"head","depth":"workingCopy","depthIsSticky":false,"ignoreExternals":true}}}"#,
            &bridge,
        )
        .expect("operation/run update should dispatch");

    assert_eq!(
        outcome.response()["error"]["code"],
        "SVN_OPERATION_UPDATE_FAILED"
    );
    assert_eq!(outcome.response()["error"]["category"], "native");
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.native.operationUpdateFailed"
    );
    assert_eq!(outcome.response()["error"]["args"]["kind"], "update");
    assert_eq!(outcome.notifications().len(), 1);
    assert_eq!(outcome.notifications()[0]["method"], "status/stale");
    assert_eq!(
        outcome.notifications()[0]["params"]["repositoryId"],
        "repo-uuid:C:/wc"
    );
    assert_eq!(outcome.notifications()[0]["params"]["epoch"], 1);
    assert_eq!(
        outcome.notifications()[0]["params"]["reason"],
        "operationUpdateFailed"
    );
    assert_eq!(
        outcome.notifications()[0]["params"]["source"],
        "subversionr-daemon"
    );
    assert!(outcome.notifications()[0].get("id").is_none());
}

#[test]
fn operation_run_rejects_invalid_update_options() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":103,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    for (request_id, request, field) in [
        (
            104,
            r#"{"jsonrpc":"2.0","id":104,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"update","options":{"version":2,"path":".","revision":"head","depth":"workingCopy","depthIsSticky":false,"ignoreExternals":true}}}"#,
            "options.version",
        ),
        (
            105,
            r#"{"jsonrpc":"2.0","id":105,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"update","options":{"version":1,"path":"../src","revision":"head","depth":"workingCopy","depthIsSticky":false,"ignoreExternals":true}}}"#,
            "options.path",
        ),
        (
            106,
            r#"{"jsonrpc":"2.0","id":106,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"update","options":{"version":1,"path":"","revision":"head","depth":"workingCopy","depthIsSticky":false,"ignoreExternals":true}}}"#,
            "options.path",
        ),
        (
            107,
            r#"{"jsonrpc":"2.0","id":107,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"update","options":{"version":1,"path":"/src/main.c","revision":"head","depth":"workingCopy","depthIsSticky":false,"ignoreExternals":true}}}"#,
            "options.path",
        ),
        (
            108,
            r#"{"jsonrpc":"2.0","id":108,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"update","options":{"version":1,"path":"C:/wc/src/main.c","revision":"head","depth":"workingCopy","depthIsSticky":false,"ignoreExternals":true}}}"#,
            "options.path",
        ),
        (
            109,
            r#"{"jsonrpc":"2.0","id":109,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"update","options":{"version":1,"path":"src\\main.c","revision":"head","depth":"workingCopy","depthIsSticky":false,"ignoreExternals":true}}}"#,
            "options.path",
        ),
        (
            110,
            r#"{"jsonrpc":"2.0","id":110,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"update","options":{"version":1,"path":".","revision":"5","depth":"workingCopy","depthIsSticky":false,"ignoreExternals":true}}}"#,
            "options.revision",
        ),
        (
            111,
            r#"{"jsonrpc":"2.0","id":111,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"update","options":{"version":1,"path":".","revision":"r5","depth":"workingCopy","depthIsSticky":false,"ignoreExternals":true}}}"#,
            "options.revision",
        ),
        (
            112,
            r#"{"jsonrpc":"2.0","id":112,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"update","options":{"version":1,"path":".","revision":"head","depth":"workingCopy","depthIsSticky":true,"ignoreExternals":true}}}"#,
            "options.depthIsSticky",
        ),
        (
            113,
            r#"{"jsonrpc":"2.0","id":113,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"update","options":{"version":1,"path":".","revision":2147483648,"depth":"workingCopy","depthIsSticky":false,"ignoreExternals":true}}}"#,
            "options.revision",
        ),
        (
            114,
            r#"{"jsonrpc":"2.0","id":114,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"update","options":{"version":1,"path":".","revision":"head","depth":"workingCopy","depthIsSticky":false}}}"#,
            "options.ignoreExternals",
        ),
        (
            115,
            r#"{"jsonrpc":"2.0","id":115,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"update","options":{"version":1,"path":".","revision":"head","depth":"workingCopy","depthIsSticky":false,"ignoreExternals":true,"recursive":true}}}"#,
            "options.recursive",
        ),
        (
            116,
            r#"{"jsonrpc":"2.0","id":116,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"update","options":{"version":1,"path":".","revision":"head","depth":"unknown","depthIsSticky":false,"ignoreExternals":true}}}"#,
            "options.depth",
        ),
    ] {
        let outcome = state
            .dispatch_json_rpc_with_bridge(request, &bridge)
            .unwrap_or_else(|error| panic!("request {request_id} should dispatch: {error}"));
        assert_eq!(
            outcome.response()["error"]["code"],
            "RPC_INVALID_PARAMS",
            "request {request_id} should fail with invalid params",
        );
        assert_eq!(
            outcome.response()["error"]["args"]["field"],
            field,
            "request {request_id} should report {field}",
        );
        assert!(
            outcome.notifications().is_empty(),
            "request {request_id} should not mark status stale before bridge execution"
        );
    }

    assert_eq!(bridge.update_requests.borrow().len(), 0);
}

#[test]
fn operation_run_branch_create_returns_remote_revision_without_local_reconcile() {
    let bridge = FakeBridge::open_success().with_branch_create_result(
        "file:///repo/branches/feature",
        Ok(subversionr_daemon::BranchCreateOperationResult {
            result: subversionr_daemon::OperationResult {
                touched_paths: Vec::new(),
                skipped_paths: Vec::new(),
            },
            revision: 42,
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":180,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":181,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"branchCreate","options":{"version":1,"sourceUrl":"file:///repo/trunk","destinationUrl":"file:///repo/branches/feature","revision":"head","message":"Create feature branch","makeParents":true,"ignoreExternals":false}}}"#,
            &bridge,
        )
        .expect("operation/run branchCreate should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["kind"], "branchCreate");
    assert_eq!(outcome.response()["result"]["revision"], 42);
    assert_eq!(outcome.response()["result"]["summary"]["affectedPaths"], 0);
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"]
            .as_array()
            .expect("reconcile targets should be an array")
            .len(),
        0
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["requiresFullReconcile"],
        false
    );
    assert!(outcome.notifications().is_empty());

    let requests = bridge.branch_create_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0],
        subversionr_daemon::BranchCreateOperationRequest {
            source_url: "file:///repo/trunk".to_string(),
            destination_url: "file:///repo/branches/feature".to_string(),
            revision: "head".to_string(),
            message: "Create feature branch".to_string(),
            make_parents: true,
            ignore_externals: false,
        }
    );
}

#[test]
fn operation_run_branch_create_maps_bridge_failure_to_structured_error() {
    let bridge = FakeBridge::open_success().with_branch_create_result(
        "file:///repo/branches/feature",
        Err(subversionr_daemon::BridgeFailure::new(
            "SVN_OPERATION_BRANCH_CREATE_FAILED",
            "native",
            "error.native.operationBranchCreateFailed",
            serde_json::json!({
                "path": "file:///repo/branches/feature",
                "kind": "branchCreate",
            }),
            false,
        )),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":182,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":183,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"branchCreate","options":{"version":1,"sourceUrl":"file:///repo/trunk","destinationUrl":"file:///repo/branches/feature","revision":"head","message":"Create feature branch","makeParents":false,"ignoreExternals":true}}}"#,
            &bridge,
        )
        .expect("operation/run branchCreate should dispatch");

    assert_eq!(
        outcome.response()["error"]["code"],
        "SVN_OPERATION_BRANCH_CREATE_FAILED"
    );
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.native.operationBranchCreateFailed"
    );
    assert_eq!(outcome.response()["error"]["args"]["kind"], "branchCreate");
    assert_eq!(outcome.notifications().len(), 1);
    assert_eq!(
        outcome.notifications()[0]["params"]["reason"],
        "operationBranchCreateFailed"
    );
}

#[test]
fn operation_run_switch_returns_revision_and_requires_full_reconcile() {
    let bridge = FakeBridge::open_success().with_switch_result(
        "src",
        Ok(subversionr_daemon::SwitchOperationResult {
            result: subversionr_daemon::OperationResult {
                touched_paths: vec!["src".to_string()],
                skipped_paths: Vec::new(),
            },
            revision: 55,
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":184,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":185,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"switch","options":{"version":1,"path":"src","url":"file:///repo/branches/feature/src","revision":55,"depth":"infinity","depthIsSticky":true,"ignoreExternals":true,"ignoreAncestry":false}}}"#,
            &bridge,
        )
        .expect("operation/run switch should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["kind"], "switch");
    assert_eq!(outcome.response()["result"]["revision"], 55);
    assert_eq!(outcome.response()["result"]["touchedPaths"][0], "src");
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"]
            .as_array()
            .expect("reconcile targets should be an array")
            .len(),
        0
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["requiresFullReconcile"],
        true
    );
    assert_eq!(outcome.notifications().len(), 1);
    assert_eq!(
        outcome.notifications()[0]["params"]["reason"],
        "operationSwitchRequiresFullReconcile"
    );

    let requests = bridge.switch_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0],
        subversionr_daemon::SwitchOperationRequest {
            path: "src".to_string(),
            url: "file:///repo/branches/feature/src".to_string(),
            revision: "55".to_string(),
            depth: "infinity".to_string(),
            depth_is_sticky: true,
            ignore_externals: true,
            ignore_ancestry: false,
        }
    );
}

#[test]
fn operation_run_switch_maps_bridge_failure_to_structured_error() {
    let bridge = FakeBridge::open_success().with_switch_result(
        "src",
        Err(subversionr_daemon::BridgeFailure::new(
            "SVN_OPERATION_SWITCH_FAILED",
            "native",
            "error.native.operationSwitchFailed",
            serde_json::json!({ "path": "src", "kind": "switch" }),
            false,
        )),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":186,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":187,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"switch","options":{"version":1,"path":"src","url":"file:///repo/branches/feature/src","revision":"head","depth":"workingCopy","depthIsSticky":false,"ignoreExternals":false,"ignoreAncestry":true}}}"#,
            &bridge,
        )
        .expect("operation/run switch should dispatch");

    assert_eq!(
        outcome.response()["error"]["code"],
        "SVN_OPERATION_SWITCH_FAILED"
    );
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.native.operationSwitchFailed"
    );
    assert_eq!(outcome.response()["error"]["args"]["kind"], "switch");
    assert_eq!(outcome.notifications().len(), 1);
    assert_eq!(
        outcome.notifications()[0]["params"]["reason"],
        "operationSwitchFailed"
    );
}

#[test]
fn operation_run_relocate_returns_full_reconcile() {
    let bridge = FakeBridge::open_success().with_relocate_result(
        "file:///repo",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec![".".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":210,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":211,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"relocate","options":{"version":1,"fromUrl":"file:///repo","toUrl":"https://svn.example.invalid/repo","ignoreExternals":true}}}"#,
            &bridge,
        )
        .expect("operation/run relocate should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["kind"], "relocate");
    assert_eq!(
        outcome.response()["result"]["revision"],
        serde_json::Value::Null
    );
    assert_eq!(outcome.response()["result"]["touchedPaths"][0], ".");
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"]
            .as_array()
            .expect("reconcile targets should be an array")
            .len(),
        0
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["requiresFullReconcile"],
        true
    );
    assert_eq!(outcome.notifications().len(), 1);
    assert_eq!(
        outcome.notifications()[0]["params"]["reason"],
        "operationRelocateRequiresFullReconcile"
    );

    let requests = bridge.relocate_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0],
        subversionr_daemon::RelocateOperationRequest {
            from_url: "file:///repo".to_string(),
            to_url: "https://svn.example.invalid/repo".to_string(),
            ignore_externals: true,
        }
    );
}

#[test]
fn operation_run_relocate_refreshes_open_session_identity() {
    let bridge = FakeBridge::open_success().with_relocate_result(
        "file:///C:/repo",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec![".".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":210,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":211,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"relocate","options":{"version":1,"fromUrl":"file:///C:/repo","toUrl":"https://svn.example.invalid/repo","ignoreExternals":true}}}"#,
            &bridge,
        )
        .expect("operation/run relocate should dispatch");

    let snapshot = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":212,"method":"status/getSnapshot","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#,
            &bridge,
        )
        .expect("status/getSnapshot should dispatch");

    assert_eq!(
        snapshot.response()["result"]["identity"]["repositoryRootUrl"],
        "https://svn.example.invalid/repo"
    );
}

#[test]
fn operation_run_relocate_maps_bridge_failure_to_structured_error() {
    let bridge = FakeBridge::open_success().with_relocate_result(
        "file:///repo",
        Err(subversionr_daemon::BridgeFailure::new(
            "SVN_OPERATION_RELOCATE_FAILED",
            "native",
            "error.native.operationRelocateFailed",
            serde_json::json!({ "path": "file:///repo", "kind": "relocate" }),
            false,
        )),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":212,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":213,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"relocate","options":{"version":1,"fromUrl":"file:///repo","toUrl":"https://svn.example.invalid/repo","ignoreExternals":false}}}"#,
            &bridge,
        )
        .expect("operation/run relocate should dispatch");

    assert_eq!(
        outcome.response()["error"]["code"],
        "SVN_OPERATION_RELOCATE_FAILED"
    );
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.native.operationRelocateFailed"
    );
    assert_eq!(outcome.response()["error"]["args"]["kind"], "relocate");
    assert_eq!(outcome.notifications().len(), 1);
    assert_eq!(
        outcome.notifications()[0]["params"]["reason"],
        "operationRelocateFailed"
    );
}

#[test]
fn operation_run_rejects_invalid_branch_and_switch_options_before_bridge_call() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":188,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    for (request_id, request, field) in [
        (
            189,
            r#"{"jsonrpc":"2.0","id":189,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"branchCreate","options":{"version":2,"sourceUrl":"file:///repo/trunk","destinationUrl":"file:///repo/branches/feature","revision":"head","message":"Create branch","makeParents":false,"ignoreExternals":false}}}"#,
            "options.version",
        ),
        (
            190,
            r#"{"jsonrpc":"2.0","id":190,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"branchCreate","options":{"version":1,"sourceUrl":"file:///repo/trunk\nbad","destinationUrl":"file:///repo/branches/feature","revision":"head","message":"Create branch","makeParents":false,"ignoreExternals":false}}}"#,
            "options.sourceUrl",
        ),
        (
            191,
            r#"{"jsonrpc":"2.0","id":191,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"branchCreate","options":{"version":1,"sourceUrl":"file:///repo/trunk","destinationUrl":"file:///repo/trunk","revision":"head","message":"Create branch","makeParents":false,"ignoreExternals":false}}}"#,
            "options.destinationUrl",
        ),
        (
            192,
            r#"{"jsonrpc":"2.0","id":192,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"branchCreate","options":{"version":1,"sourceUrl":"file:///repo/trunk","destinationUrl":"file:///repo/branches/feature","revision":"r5","message":"Create branch","makeParents":false,"ignoreExternals":false}}}"#,
            "options.revision",
        ),
        (
            193,
            r#"{"jsonrpc":"2.0","id":193,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"branchCreate","options":{"version":1,"sourceUrl":"file:///repo/trunk","destinationUrl":"file:///repo/branches/feature","revision":"head","message":"bad\rmessage","makeParents":false,"ignoreExternals":false}}}"#,
            "options.message",
        ),
        (
            194,
            r#"{"jsonrpc":"2.0","id":194,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"branchCreate","options":{"version":1,"sourceUrl":"file:///repo/trunk","destinationUrl":"file:///repo/branches/feature","revision":"head","message":"Create branch","ignoreExternals":false}}}"#,
            "options.makeParents",
        ),
        (
            195,
            r#"{"jsonrpc":"2.0","id":195,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"branchCreate","options":{"version":1,"sourceUrl":"file:///repo/trunk","destinationUrl":"file:///repo/branches/feature","revision":"head","message":"Create branch","makeParents":false,"ignoreExternals":false,"recursive":true}}}"#,
            "options.recursive",
        ),
        (
            196,
            r#"{"jsonrpc":"2.0","id":196,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"switch","options":{"version":1,"path":"..\\src","url":"file:///repo/branches/feature/src","revision":"head","depth":"workingCopy","depthIsSticky":false,"ignoreExternals":false,"ignoreAncestry":false}}}"#,
            "options.path",
        ),
        (
            197,
            r#"{"jsonrpc":"2.0","id":197,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"switch","options":{"version":1,"path":"src","url":"file:///repo/branches/feature/src\nbad","revision":"head","depth":"workingCopy","depthIsSticky":false,"ignoreExternals":false,"ignoreAncestry":false}}}"#,
            "options.url",
        ),
        (
            198,
            r#"{"jsonrpc":"2.0","id":198,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"switch","options":{"version":1,"path":"src","url":"file:///repo/branches/feature/src","revision":"r5","depth":"workingCopy","depthIsSticky":false,"ignoreExternals":false,"ignoreAncestry":false}}}"#,
            "options.revision",
        ),
        (
            199,
            r#"{"jsonrpc":"2.0","id":199,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"switch","options":{"version":1,"path":"src","url":"file:///repo/branches/feature/src","revision":"head","depth":"unknown","depthIsSticky":false,"ignoreExternals":false,"ignoreAncestry":false}}}"#,
            "options.depth",
        ),
        (
            200,
            r#"{"jsonrpc":"2.0","id":200,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"switch","options":{"version":1,"path":"src","url":"file:///repo/branches/feature/src","revision":"head","depth":"workingCopy","depthIsSticky":true,"ignoreExternals":false,"ignoreAncestry":false}}}"#,
            "options.depthIsSticky",
        ),
        (
            201,
            r#"{"jsonrpc":"2.0","id":201,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"switch","options":{"version":1,"path":"src","url":"file:///repo/branches/feature/src","revision":"head","depth":"workingCopy","depthIsSticky":false,"ignoreExternals":false}}}"#,
            "options.ignoreAncestry",
        ),
        (
            202,
            r#"{"jsonrpc":"2.0","id":202,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"switch","options":{"version":1,"path":"src","url":"file:///repo/branches/feature/src","revision":"head","depth":"workingCopy","depthIsSticky":false,"ignoreExternals":false,"ignoreAncestry":false,"recursive":true}}}"#,
            "options.recursive",
        ),
    ] {
        let outcome = state
            .dispatch_json_rpc_with_bridge(request, &bridge)
            .unwrap_or_else(|error| panic!("request {request_id} should dispatch: {error}"));
        assert_eq!(
            outcome.response()["error"]["code"],
            "RPC_INVALID_PARAMS",
            "request {request_id} should fail with invalid params",
        );
        assert_eq!(
            outcome.response()["error"]["args"]["field"],
            field,
            "request {request_id} should report {field}",
        );
        assert!(
            outcome.notifications().is_empty(),
            "request {request_id} should not mark status stale before bridge execution"
        );
    }

    assert!(bridge.branch_create_requests.borrow().is_empty());
    assert!(bridge.switch_requests.borrow().is_empty());
}

#[test]
fn operation_run_rejects_invalid_relocate_options_before_bridge_call() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":214,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    for (request_id, request, field) in [
        (
            215,
            r#"{"jsonrpc":"2.0","id":215,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"relocate","options":{"version":2,"fromUrl":"file:///repo","toUrl":"https://svn.example.invalid/repo","ignoreExternals":true}}}"#,
            "options.version",
        ),
        (
            216,
            r#"{"jsonrpc":"2.0","id":216,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"relocate","options":{"version":1,"fromUrl":"file:///repo\nbad","toUrl":"https://svn.example.invalid/repo","ignoreExternals":true}}}"#,
            "options.fromUrl",
        ),
        (
            217,
            r#"{"jsonrpc":"2.0","id":217,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"relocate","options":{"version":1,"fromUrl":"file:///repo","toUrl":"file:///repo","ignoreExternals":true}}}"#,
            "options.toUrl",
        ),
        (
            218,
            r#"{"jsonrpc":"2.0","id":218,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"relocate","options":{"version":1,"fromUrl":"file:///repo","toUrl":"https://svn.example.invalid/repo"}}}"#,
            "options.ignoreExternals",
        ),
        (
            219,
            r#"{"jsonrpc":"2.0","id":219,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"relocate","options":{"version":1,"fromUrl":"file:///repo","toUrl":"https://svn.example.invalid/repo","ignoreExternals":true,"recursive":true}}}"#,
            "options.recursive",
        ),
    ] {
        let outcome = state
            .dispatch_json_rpc_with_bridge(request, &bridge)
            .unwrap_or_else(|error| panic!("request {request_id} should dispatch: {error}"));
        assert_eq!(
            outcome.response()["error"]["code"],
            "RPC_INVALID_PARAMS",
            "request {request_id} should fail with invalid params",
        );
        assert_eq!(
            outcome.response()["error"]["args"]["field"],
            field,
            "request {request_id} should report {field}",
        );
        assert!(
            outcome.notifications().is_empty(),
            "request {request_id} should not mark status stale before bridge execution"
        );
    }

    assert!(bridge.relocate_requests.borrow().is_empty());
}

#[test]
fn operation_run_property_set_returns_touched_path_and_reconcile_hint() {
    let bridge = FakeBridge::open_success().with_property_set_result(
        "src",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec!["src".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":190,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":191,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"propertySet","options":{"version":1,"path":"src","name":"svn:ignore","value":"target\nnode_modules"}}}"#,
            &bridge,
        )
        .expect("operation/run propertySet should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["kind"], "propertySet");
    assert_eq!(outcome.response()["result"]["touchedPaths"][0], "src");
    assert_eq!(
        outcome.response()["result"]["revision"],
        serde_json::Value::Null
    );
    assert_eq!(outcome.response()["result"]["summary"]["affectedPaths"], 1);
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["path"],
        "src"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["depth"],
        "empty"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["reason"],
        "operationPropertySet"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["requiresFullReconcile"],
        false
    );
    assert!(outcome.notifications().is_empty());

    let requests = bridge.property_set_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0],
        subversionr_daemon::PropertySetOperationRequest {
            path: "src".to_string(),
            name: "svn:ignore".to_string(),
            value: "target\nnode_modules".to_string(),
        }
    );
}

#[test]
fn operation_run_property_delete_returns_touched_path_and_reconcile_hint() {
    let bridge = FakeBridge::open_success().with_property_delete_result(
        "src",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec!["src".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":192,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":193,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"propertyDelete","options":{"version":1,"path":"src","name":"svn:ignore"}}}"#,
            &bridge,
        )
        .expect("operation/run propertyDelete should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["kind"], "propertyDelete");
    assert_eq!(outcome.response()["result"]["touchedPaths"][0], "src");
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["reason"],
        "operationPropertyDelete"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["requiresFullReconcile"],
        false
    );
    assert!(outcome.notifications().is_empty());

    let requests = bridge.property_delete_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0],
        subversionr_daemon::PropertyDeleteOperationRequest {
            path: "src".to_string(),
            name: "svn:ignore".to_string(),
        }
    );
}

#[test]
fn operation_run_property_set_accepts_working_copy_root_path() {
    let bridge = FakeBridge::open_success().with_property_set_result(
        ".",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec![".".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":194,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":195,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"propertySet","options":{"version":1,"path":".","name":"svn:ignore","value":"scratch.txt"}}}"#,
            &bridge,
        )
        .expect("operation/run root propertySet should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["kind"], "propertySet");
    assert_eq!(
        bridge.property_set_requests.borrow()[0].path,
        ".".to_string()
    );
}

#[test]
fn operation_run_property_delete_maps_bridge_failure_to_structured_error() {
    let bridge = FakeBridge::open_success().with_property_delete_result(
        "src",
        Err(subversionr_daemon::BridgeFailure::new(
            "SVN_OPERATION_PROPERTY_DELETE_FAILED",
            "native",
            "error.native.operationPropertyDeleteFailed",
            serde_json::json!({ "path": "src", "name": "svn:ignore", "kind": "propertyDelete" }),
            false,
        )),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":196,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":197,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"propertyDelete","options":{"version":1,"path":"src","name":"svn:ignore"}}}"#,
            &bridge,
        )
        .expect("operation/run propertyDelete should dispatch");

    assert_eq!(
        outcome.response()["error"]["code"],
        "SVN_OPERATION_PROPERTY_DELETE_FAILED"
    );
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.native.operationPropertyDeleteFailed"
    );
    assert_eq!(
        outcome.response()["error"]["args"]["kind"],
        "propertyDelete"
    );
    assert_eq!(outcome.notifications().len(), 1);
    assert_eq!(
        outcome.notifications()[0]["params"]["reason"],
        "operationPropertyDeleteFailed"
    );
}

#[test]
fn operation_run_property_set_maps_bridge_failure_to_structured_error() {
    let bridge = FakeBridge::open_success().with_property_set_result(
        "src",
        Err(subversionr_daemon::BridgeFailure::new(
            "SVN_OPERATION_PROPERTY_SET_FAILED",
            "native",
            "error.native.operationPropertySetFailed",
            serde_json::json!({ "path": "src", "name": "svn:ignore", "kind": "propertySet" }),
            false,
        )),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":204,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":205,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"propertySet","options":{"version":1,"path":"src","name":"svn:ignore","value":"scratch.txt"}}}"#,
            &bridge,
        )
        .expect("operation/run propertySet should dispatch");

    assert_eq!(
        outcome.response()["error"]["code"],
        "SVN_OPERATION_PROPERTY_SET_FAILED"
    );
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.native.operationPropertySetFailed"
    );
    assert_eq!(outcome.response()["error"]["args"]["kind"], "propertySet");
    assert_eq!(outcome.notifications().len(), 1);
    assert_eq!(
        outcome.notifications()[0]["params"]["reason"],
        "operationPropertySetFailed"
    );
}

#[test]
fn operation_run_rejects_invalid_property_options_before_bridge_call() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":198,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    for (request_id, request, field) in [
        (
            199,
            r#"{"jsonrpc":"2.0","id":199,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"propertySet","options":{"version":2,"path":"src","name":"svn:ignore","value":"scratch.txt"}}}"#,
            "options.version",
        ),
        (
            200,
            r#"{"jsonrpc":"2.0","id":200,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"propertySet","options":{"version":1,"path":"../src","name":"svn:ignore","value":"scratch.txt"}}}"#,
            "options.path",
        ),
        (
            201,
            r#"{"jsonrpc":"2.0","id":201,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"propertySet","options":{"version":1,"path":"src","name":"svn:\nignore","value":"scratch.txt"}}}"#,
            "options.name",
        ),
        (
            202,
            r#"{"jsonrpc":"2.0","id":202,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"propertySet","options":{"version":1,"path":"src","name":"svn:ignore","value":"bad\rvalue"}}}"#,
            "options.value",
        ),
        (
            203,
            r#"{"jsonrpc":"2.0","id":203,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"propertyDelete","options":{"version":1,"path":"src","name":"svn:ignore","recursive":true}}}"#,
            "options.recursive",
        ),
    ] {
        let outcome = state
            .dispatch_json_rpc_with_bridge(request, &bridge)
            .unwrap_or_else(|error| panic!("request {request_id} should dispatch: {error}"));
        assert_eq!(
            outcome.response()["error"]["code"],
            "RPC_INVALID_PARAMS",
            "request {request_id} should fail with invalid params",
        );
        assert_eq!(
            outcome.response()["error"]["args"]["field"],
            field,
            "request {request_id} should report {field}",
        );
        assert!(
            outcome.notifications().is_empty(),
            "request {request_id} should not mark status stale before bridge execution"
        );
    }

    assert!(bridge.property_set_requests.borrow().is_empty());
    assert!(bridge.property_delete_requests.borrow().is_empty());
}

#[test]
fn operation_run_changelist_set_returns_touched_paths_and_reconcile_hint() {
    let bridge = FakeBridge::open_success().with_changelist_set_result(
        "src/main.c",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec!["src/main.c".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":206,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":207,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"changelistSet","options":{"version":1,"paths":["src/main.c"],"depth":"empty","changelist":"review","changelists":[]}}}"#,
            &bridge,
        )
        .expect("operation/run changelistSet should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["kind"], "changelistSet");
    assert_eq!(
        outcome.response()["result"]["touchedPaths"][0],
        "src/main.c"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["reason"],
        "operationChangelistSet"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["depth"],
        "empty"
    );
    assert!(outcome.notifications().is_empty());

    let requests = bridge.changelist_set_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0],
        subversionr_daemon::ChangelistSetOperationRequest {
            paths: vec!["src/main.c".to_string()],
            depth: "empty".to_string(),
            changelist: "review".to_string(),
            changelists: Vec::new(),
        }
    );
}

#[test]
fn operation_run_changelist_clear_forwards_restrictive_changelists() {
    let bridge = FakeBridge::open_success().with_changelist_clear_result(
        "src/main.c",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec!["src/main.c".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":208,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":209,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"changelistClear","options":{"version":1,"paths":["src/main.c"],"depth":"empty","changelists":["review"]}}}"#,
            &bridge,
        )
        .expect("operation/run changelistClear should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["kind"], "changelistClear");
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["reason"],
        "operationChangelistClear"
    );
    assert!(outcome.notifications().is_empty());

    let requests = bridge.changelist_clear_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0],
        subversionr_daemon::ChangelistClearOperationRequest {
            paths: vec!["src/main.c".to_string()],
            depth: "empty".to_string(),
            changelists: vec!["review".to_string()],
        }
    );
}

#[test]
fn operation_run_changelist_set_maps_bridge_failure_to_structured_error() {
    let bridge = FakeBridge::open_success().with_changelist_set_result(
        "src/main.c",
        Err(subversionr_daemon::BridgeFailure::new(
            "SVN_OPERATION_CHANGELIST_SET_FAILED",
            "native",
            "error.native.operationChangelistSetFailed",
            serde_json::json!({ "path": "src/main.c", "changelist": "review", "kind": "changelistSet" }),
            false,
        )),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":210,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":211,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"changelistSet","options":{"version":1,"paths":["src/main.c"],"depth":"empty","changelist":"review","changelists":[]}}}"#,
            &bridge,
        )
        .expect("operation/run changelistSet should dispatch");

    assert_eq!(
        outcome.response()["error"]["code"],
        "SVN_OPERATION_CHANGELIST_SET_FAILED"
    );
    assert_eq!(outcome.response()["error"]["args"]["kind"], "changelistSet");
    assert_eq!(outcome.notifications().len(), 1);
    assert_eq!(
        outcome.notifications()[0]["params"]["reason"],
        "operationChangelistSetFailed"
    );
}

#[test]
fn operation_run_changelist_clear_maps_bridge_failure_to_structured_error() {
    let bridge = FakeBridge::open_success().with_changelist_clear_result(
        "src/main.c",
        Err(subversionr_daemon::BridgeFailure::new(
            "SVN_OPERATION_CHANGELIST_CLEAR_FAILED",
            "native",
            "error.native.operationChangelistClearFailed",
            serde_json::json!({ "path": "src/main.c", "kind": "changelistClear" }),
            false,
        )),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":212,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":213,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"changelistClear","options":{"version":1,"paths":["src/main.c"],"depth":"empty","changelists":[]}}}"#,
            &bridge,
        )
        .expect("operation/run changelistClear should dispatch");

    assert_eq!(
        outcome.response()["error"]["code"],
        "SVN_OPERATION_CHANGELIST_CLEAR_FAILED"
    );
    assert_eq!(
        outcome.response()["error"]["args"]["kind"],
        "changelistClear"
    );
    assert_eq!(outcome.notifications().len(), 1);
    assert_eq!(
        outcome.notifications()[0]["params"]["reason"],
        "operationChangelistClearFailed"
    );
}

#[test]
fn operation_run_rejects_invalid_changelist_options_before_bridge_call() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":214,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    for (request_id, request, field) in [
        (
            215,
            r#"{"jsonrpc":"2.0","id":215,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"changelistSet","options":{"version":2,"paths":["src/main.c"],"depth":"empty","changelist":"review","changelists":[]}}}"#,
            "options.version",
        ),
        (
            216,
            r#"{"jsonrpc":"2.0","id":216,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"changelistSet","options":{"version":1,"paths":["src/main.c","src/main.c"],"depth":"empty","changelist":"review","changelists":[]}}}"#,
            "options.paths",
        ),
        (
            217,
            r#"{"jsonrpc":"2.0","id":217,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"changelistSet","options":{"version":1,"paths":["src\\main.c"],"depth":"empty","changelist":"review","changelists":[]}}}"#,
            "options.paths",
        ),
        (
            218,
            r#"{"jsonrpc":"2.0","id":218,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"changelistSet","options":{"version":1,"paths":["src/main.c"],"depth":"workingCopy","changelist":"review","changelists":[]}}}"#,
            "options.depth",
        ),
        (
            219,
            r#"{"jsonrpc":"2.0","id":219,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"changelistSet","options":{"version":1,"paths":["src/main.c"],"depth":"empty","changelist":"bad\nname","changelists":[]}}}"#,
            "options.changelist",
        ),
        (
            220,
            r#"{"jsonrpc":"2.0","id":220,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"changelistClear","options":{"version":1,"paths":["src/main.c"],"depth":"empty","changelists":["bad\rname"]}}}"#,
            "options.changelists",
        ),
        (
            221,
            r#"{"jsonrpc":"2.0","id":221,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"changelistClear","options":{"version":1,"paths":["src/main.c"],"depth":"empty","changelists":[],"changelist":"review"}}}"#,
            "options.changelist",
        ),
    ] {
        let outcome = state
            .dispatch_json_rpc_with_bridge(request, &bridge)
            .unwrap_or_else(|error| panic!("request {request_id} should dispatch: {error}"));
        assert_eq!(
            outcome.response()["error"]["code"],
            "RPC_INVALID_PARAMS",
            "request {request_id} should fail with invalid params",
        );
        assert_eq!(
            outcome.response()["error"]["args"]["field"],
            field,
            "request {request_id} should report {field}",
        );
        assert!(outcome.notifications().is_empty());
    }

    assert!(bridge.changelist_set_requests.borrow().is_empty());
    assert!(bridge.changelist_clear_requests.borrow().is_empty());
}

#[test]
fn operation_run_lock_returns_touched_paths_and_reconcile_hint() {
    let bridge = FakeBridge::open_success().with_lock_result(
        "src/main.c",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec!["src/main.c".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":222,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":223,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"lock","options":{"version":1,"paths":["src/main.c"],"comment":"editing main","stealLock":false}}}"#,
            &bridge,
        )
        .expect("operation/run lock should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["kind"], "lock");
    assert_eq!(
        outcome.response()["result"]["touchedPaths"][0],
        "src/main.c"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["reason"],
        "operationLock"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["depth"],
        "empty"
    );
    assert!(outcome.notifications().is_empty());

    let requests = bridge.lock_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0],
        subversionr_daemon::LockOperationRequest {
            paths: vec!["src/main.c".to_string()],
            comment: Some("editing main".to_string()),
            steal_lock: false,
        }
    );
}

#[test]
fn operation_run_unlock_forwards_break_lock_and_reconcile_hint() {
    let bridge = FakeBridge::open_success().with_unlock_result(
        "src/main.c",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec!["src/main.c".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":224,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":225,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"unlock","options":{"version":1,"paths":["src/main.c"],"breakLock":true}}}"#,
            &bridge,
        )
        .expect("operation/run unlock should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["kind"], "unlock");
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["reason"],
        "operationUnlock"
    );
    assert!(outcome.notifications().is_empty());

    let requests = bridge.unlock_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0],
        subversionr_daemon::UnlockOperationRequest {
            paths: vec!["src/main.c".to_string()],
            break_lock: true,
        }
    );
}

#[test]
fn operation_run_lock_maps_bridge_failure_to_structured_error() {
    let bridge = FakeBridge::open_success().with_lock_result(
        "src/main.c",
        Err(subversionr_daemon::BridgeFailure::new(
            "SVN_OPERATION_LOCK_FAILED",
            "native",
            "error.native.operationLockFailed",
            serde_json::json!({ "path": "src/main.c", "kind": "lock" }),
            false,
        )),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":226,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":227,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"lock","options":{"version":1,"paths":["src/main.c"],"comment":null,"stealLock":true}}}"#,
            &bridge,
        )
        .expect("operation/run lock should dispatch");

    assert_eq!(
        outcome.response()["error"]["code"],
        "SVN_OPERATION_LOCK_FAILED"
    );
    assert_eq!(outcome.response()["error"]["args"]["kind"], "lock");
    assert_eq!(outcome.notifications().len(), 1);
    assert_eq!(
        outcome.notifications()[0]["params"]["reason"],
        "operationLockFailed"
    );
}

#[test]
fn operation_run_unlock_maps_bridge_failure_to_structured_error() {
    let bridge = FakeBridge::open_success().with_unlock_result(
        "src/main.c",
        Err(subversionr_daemon::BridgeFailure::new(
            "SVN_OPERATION_UNLOCK_FAILED",
            "native",
            "error.native.operationUnlockFailed",
            serde_json::json!({ "path": "src/main.c", "kind": "unlock" }),
            false,
        )),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":228,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":229,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"unlock","options":{"version":1,"paths":["src/main.c"],"breakLock":false}}}"#,
            &bridge,
        )
        .expect("operation/run unlock should dispatch");

    assert_eq!(
        outcome.response()["error"]["code"],
        "SVN_OPERATION_UNLOCK_FAILED"
    );
    assert_eq!(outcome.response()["error"]["args"]["kind"], "unlock");
    assert_eq!(outcome.notifications().len(), 1);
    assert_eq!(
        outcome.notifications()[0]["params"]["reason"],
        "operationUnlockFailed"
    );
}

#[test]
fn operation_run_rejects_invalid_lock_options_before_bridge_call() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":230,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    for (request_id, request, field) in [
        (
            231,
            r#"{"jsonrpc":"2.0","id":231,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"lock","options":{"version":2,"paths":["src/main.c"],"comment":null,"stealLock":false}}}"#,
            "options.version",
        ),
        (
            232,
            r#"{"jsonrpc":"2.0","id":232,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"lock","options":{"version":1,"paths":["."],"comment":null,"stealLock":false}}}"#,
            "options.paths",
        ),
        (
            233,
            r#"{"jsonrpc":"2.0","id":233,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"lock","options":{"version":1,"paths":["src/main.c","src/main.c"],"comment":null,"stealLock":false}}}"#,
            "options.paths",
        ),
        (
            234,
            r#"{"jsonrpc":"2.0","id":234,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"lock","options":{"version":1,"paths":["src\\main.c"],"comment":null,"stealLock":false}}}"#,
            "options.paths",
        ),
        (
            235,
            r#"{"jsonrpc":"2.0","id":235,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"lock","options":{"version":1,"paths":["src/main.c"],"comment":"","stealLock":false}}}"#,
            "options.comment",
        ),
        (
            236,
            r#"{"jsonrpc":"2.0","id":236,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"lock","options":{"version":1,"paths":["src/main.c"],"comment":"bad\rcomment","stealLock":false}}}"#,
            "options.comment",
        ),
        (
            237,
            r#"{"jsonrpc":"2.0","id":237,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"lock","options":{"version":1,"paths":["src/main.c"],"stealLock":false}}}"#,
            "options.comment",
        ),
        (
            238,
            r#"{"jsonrpc":"2.0","id":238,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"lock","options":{"version":1,"paths":["src/main.c"],"comment":null,"stealLock":false,"force":true}}}"#,
            "options.force",
        ),
        (
            239,
            r#"{"jsonrpc":"2.0","id":239,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"unlock","options":{"version":1,"paths":["src/main.c"],"breakLock":false,"comment":null}}}"#,
            "options.comment",
        ),
        (
            240,
            r#"{"jsonrpc":"2.0","id":240,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"unlock","options":{"version":1,"paths":["src/main.c"]}}}"#,
            "options.breakLock",
        ),
    ] {
        let outcome = state
            .dispatch_json_rpc_with_bridge(request, &bridge)
            .unwrap_or_else(|error| panic!("request {request_id} should dispatch: {error}"));
        assert_eq!(
            outcome.response()["error"]["code"],
            "RPC_INVALID_PARAMS",
            "request {request_id} should fail with invalid params",
        );
        assert_eq!(
            outcome.response()["error"]["args"]["field"],
            field,
            "request {request_id} should report {field}",
        );
        assert!(
            outcome.notifications().is_empty(),
            "request {request_id} should not mark status stale before bridge execution"
        );
    }

    assert!(bridge.lock_requests.borrow().is_empty());
    assert!(bridge.unlock_requests.borrow().is_empty());
}

#[test]
fn operation_run_commit_returns_revision_and_targeted_reconcile_hint() {
    let bridge = FakeBridge::open_success().with_commit_result(
        "src/main.c",
        Ok(subversionr_daemon::CommitOperationResult {
            result: subversionr_daemon::OperationResult {
                touched_paths: vec!["src/main.c".to_string()],
                skipped_paths: Vec::new(),
            },
            revision: 9,
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":112,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":113,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"commit","options":{"version":1,"paths":["src/main.c"],"message":"commit tracked file","depth":"empty","changelists":[],"keepLocks":false,"keepChangelists":false,"commitAsOperations":false,"includeFileExternals":false,"includeDirExternals":false}}}"#,
            &bridge,
        )
        .expect("operation/run commit should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["kind"], "commit");
    assert_eq!(
        outcome.response()["result"]["touchedPaths"][0],
        "src/main.c"
    );
    assert_eq!(outcome.response()["result"]["revision"], 9);
    assert_eq!(outcome.response()["result"]["summary"]["affectedPaths"], 1);
    assert_eq!(outcome.response()["result"]["summary"]["skippedPaths"], 0);
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["path"],
        "src/main.c"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["depth"],
        "empty"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["reason"],
        "operationCommit"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["requiresFullReconcile"],
        false
    );
}

#[test]
fn operation_run_commit_accepts_multiple_file_paths_and_returns_targeted_reconcile_hints() {
    let bridge = FakeBridge::open_success().with_commit_result(
        "src/main.c",
        Ok(subversionr_daemon::CommitOperationResult {
            result: subversionr_daemon::OperationResult {
                touched_paths: vec!["src/main.c".to_string(), "src/other.c".to_string()],
                skipped_paths: Vec::new(),
            },
            revision: 10,
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":134,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":135,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"commit","options":{"version":1,"paths":["src/main.c","src/other.c"],"message":"commit selected files","depth":"empty","changelists":[],"keepLocks":false,"keepChangelists":false,"commitAsOperations":false,"includeFileExternals":false,"includeDirExternals":false}}}"#,
            &bridge,
        )
        .expect("operation/run commit should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["kind"], "commit");
    assert_eq!(outcome.response()["result"]["revision"], 10);
    assert_eq!(outcome.response()["result"]["summary"]["affectedPaths"], 2);
    assert_eq!(
        outcome.response()["result"]["touchedPaths"],
        serde_json::json!(["src/main.c", "src/other.c"])
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"],
        serde_json::json!([
            { "path": "src/main.c", "depth": "empty", "reason": "operationCommit" },
            { "path": "src/other.c", "depth": "empty", "reason": "operationCommit" }
        ])
    );

    let requests = bridge.commit_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0].paths,
        vec!["src/main.c".to_string(), "src/other.c".to_string()]
    );
}

#[test]
fn operation_run_commit_accepts_working_copy_root_path_and_returns_root_reconcile_hint() {
    let bridge = FakeBridge::open_success().with_commit_result(
        ".",
        Ok(subversionr_daemon::CommitOperationResult {
            result: subversionr_daemon::OperationResult {
                touched_paths: vec![".".to_string()],
                skipped_paths: Vec::new(),
            },
            revision: 11,
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":136,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":137,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"commit","options":{"version":1,"paths":["."],"message":"commit root properties","depth":"empty","changelists":[],"keepLocks":false,"keepChangelists":false,"commitAsOperations":false,"includeFileExternals":false,"includeDirExternals":false}}}"#,
            &bridge,
        )
        .expect("operation/run root commit should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["result"]["kind"], "commit");
    assert_eq!(outcome.response()["result"]["revision"], 11);
    assert_eq!(outcome.response()["result"]["summary"]["affectedPaths"], 1);
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"],
        serde_json::json!([{ "path": ".", "depth": "empty", "reason": "operationCommit" }])
    );

    let requests = bridge.commit_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].paths, vec![".".to_string()]);
}

#[test]
fn operation_run_commit_forwards_single_file_options_to_bridge() {
    let bridge = FakeBridge::open_success().with_commit_result(
        "src/main.c",
        Ok(subversionr_daemon::CommitOperationResult {
            result: subversionr_daemon::OperationResult {
                touched_paths: vec!["src/main.c".to_string()],
                skipped_paths: Vec::new(),
            },
            revision: 9,
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":114,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":115,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"commit","options":{"version":1,"paths":["src/main.c"],"message":"commit tracked file","depth":"empty","changelists":[],"keepLocks":false,"keepChangelists":false,"commitAsOperations":false,"includeFileExternals":false,"includeDirExternals":false}}}"#,
            &bridge,
        )
        .expect("operation/run commit should dispatch");

    let requests = bridge.commit_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0],
        subversionr_daemon::CommitOperationRequest {
            paths: vec!["src/main.c".to_string()],
            message: "commit tracked file".to_string(),
            depth: "empty".to_string(),
            changelists: Vec::new(),
            keep_locks: false,
            keep_changelists: false,
            commit_as_operations: false,
            include_file_externals: false,
            include_dir_externals: false,
        }
    );
}

#[test]
fn operation_run_commit_forwards_changelist_filter_to_bridge() {
    let bridge = FakeBridge::open_success().with_commit_result(
        "src/review.c",
        Ok(subversionr_daemon::CommitOperationResult {
            result: subversionr_daemon::OperationResult {
                touched_paths: vec!["src/review.c".to_string()],
                skipped_paths: Vec::new(),
            },
            revision: 11,
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":222,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":223,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"commit","options":{"version":1,"paths":["src/review.c"],"message":"commit review changelist","depth":"empty","changelists":["review"],"keepLocks":false,"keepChangelists":false,"commitAsOperations":false,"includeFileExternals":false,"includeDirExternals":false}}}"#,
            &bridge,
        )
        .expect("operation/run commit should dispatch");

    let requests = bridge.commit_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0],
        subversionr_daemon::CommitOperationRequest {
            paths: vec!["src/review.c".to_string()],
            message: "commit review changelist".to_string(),
            depth: "empty".to_string(),
            changelists: vec!["review".to_string()],
            keep_locks: false,
            keep_changelists: false,
            commit_as_operations: false,
            include_file_externals: false,
            include_dir_externals: false,
        }
    );
}

#[test]
fn operation_run_commit_maps_bridge_failure_to_structured_error() {
    let bridge = FakeBridge::open_success().with_commit_result(
        "src/main.c",
        Err(subversionr_daemon::BridgeFailure::new(
            "SVN_OPERATION_COMMIT_FAILED",
            "native",
            "error.native.operationCommitFailed",
            serde_json::json!({ "path": "src/main.c", "kind": "commit" }),
            false,
        )),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":116,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":117,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"commit","options":{"version":1,"paths":["src/main.c"],"message":"commit tracked file","depth":"empty","changelists":[],"keepLocks":false,"keepChangelists":false,"commitAsOperations":false,"includeFileExternals":false,"includeDirExternals":false}}}"#,
            &bridge,
        )
        .expect("operation/run commit should dispatch");

    assert_eq!(
        outcome.response()["error"]["code"],
        "SVN_OPERATION_COMMIT_FAILED"
    );
    assert_eq!(outcome.response()["error"]["category"], "native");
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.native.operationCommitFailed"
    );
    assert_eq!(outcome.response()["error"]["args"]["kind"], "commit");
}

#[test]
fn operation_run_commit_reports_auth_broker_unavailable_on_non_stdio_dispatch() {
    let bridge = FakeBridge::open_success().with_commit_requires_auth();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":138,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":139,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"commit","options":{"version":1,"paths":["src/main.c"],"message":"commit tracked file","depth":"empty","changelists":[],"keepLocks":false,"keepChangelists":false,"commitAsOperations":false,"includeFileExternals":false,"includeDirExternals":false}}}"#,
            &bridge,
        )
        .expect("operation/run commit should dispatch");

    assert_eq!(
        outcome.response()["error"]["code"],
        "SUBVERSIONR_AUTH_BROKER_UNAVAILABLE"
    );
    assert_eq!(outcome.response()["error"]["category"], "auth");
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.auth.brokerUnavailable"
    );
    assert_eq!(
        outcome.response()["error"]["args"]["method"],
        "credentials/request"
    );
}

#[test]
fn operation_run_commit_maps_non_file_target_bridge_failure_to_structured_error() {
    let bridge = FakeBridge::open_success().with_commit_result(
        "src",
        Err(subversionr_daemon::BridgeFailure::new(
            "SVN_OPERATION_COMMIT_TARGET_NOT_FILE",
            "native",
            "error.native.operationCommitTargetNotFile",
            serde_json::json!({ "path": "C:/wc/src", "status": 10 }),
            false,
        )),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":136,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":137,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"commit","options":{"version":1,"paths":["src"],"message":"commit forged directory target","depth":"empty","changelists":[],"keepLocks":false,"keepChangelists":false,"commitAsOperations":false,"includeFileExternals":false,"includeDirExternals":false}}}"#,
            &bridge,
        )
        .expect("operation/run commit should dispatch");

    assert_eq!(
        outcome.response()["error"]["code"],
        "SVN_OPERATION_COMMIT_TARGET_NOT_FILE"
    );
    assert_eq!(outcome.response()["error"]["category"], "native");
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.native.operationCommitTargetNotFile"
    );
    assert_eq!(outcome.response()["error"]["args"]["status"], 10);
}

#[test]
fn operation_run_rejects_invalid_commit_options() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":118,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    for (request_id, request, field) in [
        (
            119,
            r#"{"jsonrpc":"2.0","id":119,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"commit","options":{"version":2,"paths":["src/main.c"],"message":"commit tracked file","depth":"empty","changelists":[],"keepLocks":false,"keepChangelists":false,"commitAsOperations":false,"includeFileExternals":false,"includeDirExternals":false}}}"#,
            "options.version",
        ),
        (
            120,
            r#"{"jsonrpc":"2.0","id":120,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"commit","options":{"version":1,"paths":[],"message":"commit tracked file","depth":"empty","changelists":[],"keepLocks":false,"keepChangelists":false,"commitAsOperations":false,"includeFileExternals":false,"includeDirExternals":false}}}"#,
            "options.paths",
        ),
        (
            121,
            r#"{"jsonrpc":"2.0","id":121,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"commit","options":{"version":1,"paths":["src/main.c","src/main.c"],"message":"commit tracked file","depth":"empty","changelists":[],"keepLocks":false,"keepChangelists":false,"commitAsOperations":false,"includeFileExternals":false,"includeDirExternals":false}}}"#,
            "options.paths",
        ),
        (
            123,
            r#"{"jsonrpc":"2.0","id":123,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"commit","options":{"version":1,"paths":["src\\main.c"],"message":"commit tracked file","depth":"empty","changelists":[],"keepLocks":false,"keepChangelists":false,"commitAsOperations":false,"includeFileExternals":false,"includeDirExternals":false}}}"#,
            "options.paths",
        ),
        (
            124,
            r#"{"jsonrpc":"2.0","id":124,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"commit","options":{"version":1,"paths":["src/main.c"],"message":"","depth":"empty","changelists":[],"keepLocks":false,"keepChangelists":false,"commitAsOperations":false,"includeFileExternals":false,"includeDirExternals":false}}}"#,
            "options.message",
        ),
        (
            125,
            r#"{"jsonrpc":"2.0","id":125,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"commit","options":{"version":1,"paths":["src/main.c"],"message":"line one\r\nline two","depth":"empty","changelists":[],"keepLocks":false,"keepChangelists":false,"commitAsOperations":false,"includeFileExternals":false,"includeDirExternals":false}}}"#,
            "options.message",
        ),
        (
            126,
            r#"{"jsonrpc":"2.0","id":126,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"commit","options":{"version":1,"paths":["src/main.c"],"message":"commit tracked file","depth":"files","changelists":[],"keepLocks":false,"keepChangelists":false,"commitAsOperations":false,"includeFileExternals":false,"includeDirExternals":false}}}"#,
            "options.depth",
        ),
        (
            127,
            r#"{"jsonrpc":"2.0","id":127,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"commit","options":{"version":1,"paths":["src/main.c"],"message":"commit tracked file","depth":"empty","changelists":["bad\nname"],"keepLocks":false,"keepChangelists":false,"commitAsOperations":false,"includeFileExternals":false,"includeDirExternals":false}}}"#,
            "options.changelists",
        ),
        (
            128,
            r#"{"jsonrpc":"2.0","id":128,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"commit","options":{"version":1,"paths":["src/main.c"],"message":"commit tracked file","depth":"empty","changelists":[],"keepLocks":true,"keepChangelists":false,"commitAsOperations":false,"includeFileExternals":false,"includeDirExternals":false}}}"#,
            "options.keepLocks",
        ),
        (
            129,
            r#"{"jsonrpc":"2.0","id":129,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"commit","options":{"version":1,"paths":["src/main.c"],"message":"commit tracked file","depth":"empty","changelists":[],"keepLocks":false,"keepChangelists":true,"commitAsOperations":false,"includeFileExternals":false,"includeDirExternals":false}}}"#,
            "options.keepChangelists",
        ),
        (
            130,
            r#"{"jsonrpc":"2.0","id":130,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"commit","options":{"version":1,"paths":["src/main.c"],"message":"commit tracked file","depth":"empty","changelists":[],"keepLocks":false,"keepChangelists":false,"commitAsOperations":true,"includeFileExternals":false,"includeDirExternals":false}}}"#,
            "options.commitAsOperations",
        ),
        (
            131,
            r#"{"jsonrpc":"2.0","id":131,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"commit","options":{"version":1,"paths":["src/main.c"],"message":"commit tracked file","depth":"empty","changelists":[],"keepLocks":false,"keepChangelists":false,"commitAsOperations":false,"includeFileExternals":true,"includeDirExternals":false}}}"#,
            "options.includeFileExternals",
        ),
        (
            132,
            r#"{"jsonrpc":"2.0","id":132,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"commit","options":{"version":1,"paths":["src/main.c"],"message":"commit tracked file","depth":"empty","changelists":[],"keepLocks":false,"keepChangelists":false,"commitAsOperations":false,"includeFileExternals":false,"includeDirExternals":true}}}"#,
            "options.includeDirExternals",
        ),
        (
            133,
            r#"{"jsonrpc":"2.0","id":133,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"commit","options":{"version":1,"paths":["src/main.c"],"message":"commit tracked file","depth":"empty","changelists":[],"keepLocks":false,"keepChangelists":false,"commitAsOperations":false,"includeFileExternals":false,"includeDirExternals":false,"recursive":true}}}"#,
            "options.recursive",
        ),
    ] {
        let outcome = state
            .dispatch_json_rpc_with_bridge(request, &bridge)
            .unwrap_or_else(|error| panic!("request {request_id} should dispatch: {error}"));
        assert_eq!(
            outcome.response()["error"]["code"],
            "RPC_INVALID_PARAMS",
            "request {request_id} should fail with invalid params",
        );
        assert_eq!(
            outcome.response()["error"]["args"]["field"],
            field,
            "request {request_id} should report {field}",
        );
    }

    assert_eq!(bridge.commit_requests.borrow().len(), 0);
}

#[test]
fn operation_run_revert_reports_skipped_paths_as_warnings() {
    let bridge = FakeBridge::open_success().with_revert_result(
        "scratch.txt",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: Vec::new(),
            skipped_paths: vec!["scratch.txt".to_string()],
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":63,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":64,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"revert","options":{"version":1,"paths":["scratch.txt"],"depth":"empty","changelists":[],"clearChangelists":false,"metadataOnly":false,"addedKeepLocal":false}}}"#,
            &bridge,
        )
        .expect("operation/run should dispatch");

    assert_eq!(outcome.response()["result"]["summary"]["affectedPaths"], 0);
    assert_eq!(outcome.response()["result"]["summary"]["skippedPaths"], 1);
    assert_eq!(
        outcome.response()["result"]["warnings"][0]["code"],
        "SVN_OPERATION_PATH_SKIPPED"
    );
    assert_eq!(
        outcome.response()["result"]["warnings"][0]["args"]["path"],
        "scratch.txt"
    );
}

#[test]
fn operation_run_rejects_unsupported_kind_and_invalid_revert_options() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":65,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let unsupported = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":66,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"shelve","options":{}}}"#,
            &bridge,
        )
        .expect("operation/run should dispatch");
    assert_eq!(
        unsupported.response()["error"]["code"],
        "OPERATION_KIND_UNSUPPORTED"
    );
    assert!(unsupported.notifications().is_empty());

    let invalid_path = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":67,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"revert","options":{"version":1,"paths":["..\\outside.txt"],"depth":"empty","changelists":[],"clearChangelists":false,"metadataOnly":false,"addedKeepLocal":false}}}"#,
            &bridge,
        )
        .expect("operation/run should dispatch");
    assert_eq!(
        invalid_path.response()["error"]["code"],
        "RPC_INVALID_PARAMS"
    );
    assert_eq!(
        invalid_path.response()["error"]["args"]["field"],
        "options.paths"
    );
    assert!(invalid_path.notifications().is_empty());

    let duplicate_changelists = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":222,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"revert","options":{"version":1,"paths":["tracked.txt"],"depth":"empty","changelists":["review","review"],"clearChangelists":false,"metadataOnly":false,"addedKeepLocal":false}}}"#,
            &bridge,
        )
        .expect("operation/run should dispatch");
    assert_eq!(
        duplicate_changelists.response()["error"]["code"],
        "RPC_INVALID_PARAMS"
    );
    assert_eq!(
        duplicate_changelists.response()["error"]["args"]["field"],
        "options.changelists"
    );
    assert!(duplicate_changelists.notifications().is_empty());
}

#[test]
fn operation_run_merge_range_returns_full_reconcile_hint() {
    let bridge = FakeBridge::open_success().with_merge_result(
        ".",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec![".".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":65,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":66,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"merge","options":{"version":1,"sourceUrl":"file:///repo/branches/feature","targetPath":".","startRevision":10,"endRevision":12,"depth":"infinity","ignoreMergeinfo":false,"diffIgnoreAncestry":false,"forceDelete":false,"recordOnly":false,"dryRun":false,"allowMixedRevisions":false}}}"#,
            &bridge,
        )
        .expect("operation/run should dispatch");

    assert_eq!(outcome.response()["result"]["kind"], "merge");
    assert_eq!(outcome.response()["result"]["touchedPaths"][0], ".");
    assert_eq!(
        outcome.response()["result"]["revision"],
        serde_json::Value::Null
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["requiresFullReconcile"],
        true
    );
    assert_eq!(outcome.notifications().len(), 1);
    assert_eq!(
        outcome.notifications()[0]["params"]["reason"],
        "operationMergeRequiresFullReconcile"
    );

    let requests = bridge.merge_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0],
        subversionr_daemon::MergeOperationRequest {
            source_url: "file:///repo/branches/feature".to_string(),
            target_path: ".".to_string(),
            start_revision: 10,
            end_revision: 12,
            depth: "infinity".to_string(),
            ignore_mergeinfo: false,
            diff_ignore_ancestry: false,
            force_delete: false,
            record_only: false,
            dry_run: false,
            allow_mixed_revisions: false,
        }
    );
}

#[test]
fn operation_run_merge_range_dry_run_returns_targeted_reconcile_hint() {
    let bridge = FakeBridge::open_success().with_merge_result(
        ".",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec!["src/main.c".to_string(), "src/lib.c".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":65,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":66,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"merge","options":{"version":1,"sourceUrl":"file:///repo/branches/feature","targetPath":".","startRevision":10,"endRevision":12,"depth":"infinity","ignoreMergeinfo":false,"diffIgnoreAncestry":false,"forceDelete":false,"recordOnly":false,"dryRun":true,"allowMixedRevisions":false}}}"#,
            &bridge,
        )
        .expect("operation/run should dispatch");

    assert_eq!(outcome.response()["result"]["kind"], "merge");
    assert_eq!(
        outcome.response()["result"]["touchedPaths"][0],
        "src/main.c"
    );
    assert_eq!(outcome.response()["result"]["touchedPaths"][1], "src/lib.c");
    assert_eq!(
        outcome.response()["result"]["revision"],
        serde_json::Value::Null
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["requiresFullReconcile"],
        false
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["path"],
        "src/main.c"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][1]["path"],
        "src/lib.c"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["depth"],
        "infinity"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][1]["depth"],
        "infinity"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["reason"],
        "operationMergePreview"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][1]["reason"],
        "operationMergePreview"
    );
    assert!(outcome.notifications().is_empty());

    let requests = bridge.merge_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert!(requests[0].dry_run);
}

#[test]
fn operation_run_merge_range_dry_run_uses_target_path_when_no_paths_are_touched() {
    let bridge = FakeBridge::open_success().with_merge_result(
        ".",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: Vec::new(),
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":65,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":66,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"merge","options":{"version":1,"sourceUrl":"file:///repo/branches/feature","targetPath":".","startRevision":10,"endRevision":12,"depth":"infinity","ignoreMergeinfo":false,"diffIgnoreAncestry":false,"forceDelete":false,"recordOnly":false,"dryRun":true,"allowMixedRevisions":false}}}"#,
            &bridge,
        )
        .expect("operation/run should dispatch");

    assert_eq!(outcome.response()["result"]["kind"], "merge");
    assert_eq!(
        outcome.response()["result"]["touchedPaths"]
            .as_array()
            .expect("touched paths array")
            .len(),
        0
    );
    assert_eq!(outcome.response()["result"]["summary"]["affectedPaths"], 0);
    assert_eq!(
        outcome.response()["result"]["reconcile"]["requiresFullReconcile"],
        false
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["path"],
        "."
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["depth"],
        "infinity"
    );
    assert_eq!(
        outcome.response()["result"]["reconcile"]["targets"][0]["reason"],
        "operationMergePreview"
    );
    assert!(outcome.notifications().is_empty());

    let requests = bridge.merge_requests.borrow();
    assert_eq!(requests.len(), 1);
    assert!(requests[0].dry_run);
}

#[test]
fn operation_run_rejects_invalid_merge_options_before_bridge_call() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":167,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    for (request_id, request, field) in [
        (
            168,
            r#"{"jsonrpc":"2.0","id":168,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"merge","options":{"version":2,"sourceUrl":"file:///repo/branches/feature","targetPath":".","startRevision":10,"endRevision":12,"depth":"infinity","ignoreMergeinfo":false,"diffIgnoreAncestry":false,"forceDelete":false,"recordOnly":false,"dryRun":false,"allowMixedRevisions":false}}}"#,
            "options.version",
        ),
        (
            169,
            r#"{"jsonrpc":"2.0","id":169,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"merge","options":{"version":1,"sourceUrl":"file:///repo/branches/feature\nbad","targetPath":".","startRevision":10,"endRevision":12,"depth":"infinity","ignoreMergeinfo":false,"diffIgnoreAncestry":false,"forceDelete":false,"recordOnly":false,"dryRun":false,"allowMixedRevisions":false}}}"#,
            "options.sourceUrl",
        ),
        (
            170,
            r#"{"jsonrpc":"2.0","id":170,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"merge","options":{"version":1,"sourceUrl":"file:///repo/branches/feature","targetPath":"..\\outside","startRevision":10,"endRevision":12,"depth":"infinity","ignoreMergeinfo":false,"diffIgnoreAncestry":false,"forceDelete":false,"recordOnly":false,"dryRun":false,"allowMixedRevisions":false}}}"#,
            "options.targetPath",
        ),
        (
            171,
            r#"{"jsonrpc":"2.0","id":171,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"merge","options":{"version":1,"sourceUrl":"file:///repo/branches/feature","targetPath":".","startRevision":12,"endRevision":12,"depth":"infinity","ignoreMergeinfo":false,"diffIgnoreAncestry":false,"forceDelete":false,"recordOnly":false,"dryRun":false,"allowMixedRevisions":false}}}"#,
            "options.endRevision",
        ),
        (
            172,
            r#"{"jsonrpc":"2.0","id":172,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"merge","options":{"version":1,"sourceUrl":"file:///repo/branches/feature","targetPath":".","startRevision":10,"endRevision":12,"depth":"workingCopy","ignoreMergeinfo":false,"diffIgnoreAncestry":false,"forceDelete":false,"recordOnly":false,"dryRun":false,"allowMixedRevisions":false}}}"#,
            "options.depth",
        ),
        (
            173,
            r#"{"jsonrpc":"2.0","id":173,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"merge","options":{"version":1,"sourceUrl":"file:///repo/branches/feature","targetPath":".","startRevision":10,"endRevision":12,"depth":"infinity","ignoreMergeinfo":false,"diffIgnoreAncestry":false,"forceDelete":false,"recordOnly":false,"dryRun":false}}}"#,
            "options.allowMixedRevisions",
        ),
        (
            174,
            r#"{"jsonrpc":"2.0","id":174,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"merge","options":{"version":1,"sourceUrl":"file:///repo/branches/feature","targetPath":".","startRevision":10,"endRevision":12,"depth":"infinity","ignoreMergeinfo":false,"diffIgnoreAncestry":false,"forceDelete":false,"recordOnly":false,"dryRun":false,"allowMixedRevisions":false,"recursive":true}}}"#,
            "options.recursive",
        ),
    ] {
        let outcome = state
            .dispatch_json_rpc_with_bridge(request, &bridge)
            .unwrap_or_else(|error| panic!("request {request_id} should dispatch: {error}"));
        assert_eq!(
            outcome.response()["error"]["code"],
            "RPC_INVALID_PARAMS",
            "request {request_id} should fail with invalid params",
        );
        assert_eq!(
            outcome.response()["error"]["args"]["field"],
            field,
            "request {request_id} should report {field}",
        );
        assert!(outcome.notifications().is_empty());
    }

    assert!(bridge.merge_requests.borrow().is_empty());
}

#[test]
fn operation_run_rejects_unexpected_top_level_params_before_bridge_call() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":68,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":69,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"propertySet","options":{"version":1,"path":"src","name":"svn:ignore","value":"scratch.txt"},"recursive":true}}"#,
            &bridge,
        )
        .expect("operation/run should dispatch");

    assert_eq!(outcome.response()["error"]["code"], "RPC_INVALID_PARAMS");
    assert_eq!(outcome.response()["error"]["args"]["field"], "recursive");
    assert!(outcome.notifications().is_empty());
    assert!(bridge.property_set_requests.borrow().is_empty());
}

#[test]
fn operation_run_rejects_invalid_add_options() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":74,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let invalid_path = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":75,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"add","options":{"version":1,"paths":["..\\outside.txt"],"depth":"empty","force":false,"noIgnore":false,"noAutoprops":false,"addParents":false}}}"#,
            &bridge,
        )
        .expect("operation/run add should dispatch");
    assert_eq!(
        invalid_path.response()["error"]["code"],
        "RPC_INVALID_PARAMS"
    );
    assert_eq!(
        invalid_path.response()["error"]["args"]["field"],
        "options.paths"
    );

    let multiple_paths = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":80,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"add","options":{"version":1,"paths":["scratch-a.txt","scratch-b.txt"],"depth":"empty","force":false,"noIgnore":false,"noAutoprops":false,"addParents":false}}}"#,
            &bridge,
        )
        .expect("operation/run add should dispatch");
    assert_eq!(
        multiple_paths.response()["error"]["code"],
        "RPC_INVALID_PARAMS"
    );
    assert_eq!(
        multiple_paths.response()["error"]["args"]["field"],
        "options.paths"
    );

    let missing_no_autoprops = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":76,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"add","options":{"version":1,"paths":["scratch.txt"],"depth":"empty","force":false,"noIgnore":false,"addParents":false}}}"#,
            &bridge,
        )
        .expect("operation/run add should dispatch");
    assert_eq!(
        missing_no_autoprops.response()["error"]["code"],
        "RPC_INVALID_PARAMS"
    );
    assert_eq!(
        missing_no_autoprops.response()["error"]["args"]["field"],
        "options.noAutoprops"
    );

    let extra_option = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":79,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"add","options":{"version":1,"paths":["scratch.txt"],"depth":"empty","force":false,"noIgnore":false,"noAutoprops":false,"addParents":false,"recursive":false}}}"#,
            &bridge,
        )
        .expect("operation/run add should dispatch");
    assert_eq!(
        extra_option.response()["error"]["code"],
        "RPC_INVALID_PARAMS"
    );
    assert_eq!(
        extra_option.response()["error"]["args"]["field"],
        "options.recursive"
    );
}

#[test]
fn operation_run_rejects_invalid_remove_options() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":81,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    for (request_id, request, field) in [
        (
            82,
            r#"{"jsonrpc":"2.0","id":82,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"remove","options":{"version":2,"paths":["src/old.c"],"force":false,"keepLocal":false}}}"#,
            "options.version",
        ),
        (
            83,
            r#"{"jsonrpc":"2.0","id":83,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"remove","options":{"version":1,"paths":["src/old.c","src/old.c"],"force":false,"keepLocal":false}}}"#,
            "options.paths",
        ),
        (
            84,
            r#"{"jsonrpc":"2.0","id":84,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"remove","options":{"version":1,"paths":["..\\old.c"],"force":false,"keepLocal":false}}}"#,
            "options.paths",
        ),
        (
            85,
            r#"{"jsonrpc":"2.0","id":85,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"remove","options":{"version":1,"paths":["src/old.c"],"keepLocal":false}}}"#,
            "options.force",
        ),
        (
            86,
            r#"{"jsonrpc":"2.0","id":86,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"remove","options":{"version":1,"paths":["src/old.c"],"force":false,"keepLocal":false,"recursive":true}}}"#,
            "options.recursive",
        ),
    ] {
        let outcome = state
            .dispatch_json_rpc_with_bridge(request, &bridge)
            .unwrap_or_else(|error| panic!("request {request_id} should dispatch: {error}"));
        assert_eq!(
            outcome.response()["error"]["code"],
            "RPC_INVALID_PARAMS",
            "request {request_id} should fail with invalid params",
        );
        assert_eq!(
            outcome.response()["error"]["args"]["field"],
            field,
            "request {request_id} should report {field}",
        );
    }
}

#[test]
fn operation_run_rejects_invalid_move_options() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":87,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    for (request_id, request, field) in [
        (
            88,
            r#"{"jsonrpc":"2.0","id":88,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"move","options":{"version":2,"sourcePath":"src/old.c","destinationPath":"src/new.c","makeParents":false}}}"#,
            "options.version",
        ),
        (
            89,
            r#"{"jsonrpc":"2.0","id":89,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"move","options":{"version":1,"sourcePath":".","destinationPath":"src/new.c","makeParents":false}}}"#,
            "options.sourcePath",
        ),
        (
            90,
            r#"{"jsonrpc":"2.0","id":90,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"move","options":{"version":1,"sourcePath":"src\\old.c","destinationPath":"src/new.c","makeParents":false}}}"#,
            "options.sourcePath",
        ),
        (
            91,
            r#"{"jsonrpc":"2.0","id":91,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"move","options":{"version":1,"sourcePath":"src/old.c","destinationPath":"..\\new.c","makeParents":false}}}"#,
            "options.destinationPath",
        ),
        (
            92,
            r#"{"jsonrpc":"2.0","id":92,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"move","options":{"version":1,"sourcePath":"src/old.c","destinationPath":"src/old.c","makeParents":false}}}"#,
            "options.destinationPath",
        ),
        (
            93,
            r#"{"jsonrpc":"2.0","id":93,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"move","options":{"version":1,"sourcePath":"src/old.c","destinationPath":"src/new.c"}}}"#,
            "options.makeParents",
        ),
        (
            94,
            r#"{"jsonrpc":"2.0","id":94,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"move","options":{"version":1,"sourcePath":"src/old.c","destinationPath":"src/new.c","parents":true}}}"#,
            "options.parents",
        ),
    ] {
        let outcome = state
            .dispatch_json_rpc_with_bridge(request, &bridge)
            .unwrap_or_else(|error| panic!("request {request_id} should dispatch: {error}"));
        assert_eq!(
            outcome.response()["error"]["code"],
            "RPC_INVALID_PARAMS",
            "request {request_id} should fail with invalid params",
        );
        assert_eq!(
            outcome.response()["error"]["args"]["field"],
            field,
            "request {request_id} should report {field}",
        );
        assert!(outcome.notifications().is_empty());
    }
}

#[test]
fn operation_run_rejects_invalid_cleanup_options() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":87,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    for (request_id, request, field) in [
        (
            88,
            r#"{"jsonrpc":"2.0","id":88,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"cleanup","options":{"version":2,"path":".","breakLocks":true,"fixRecordedTimestamps":false,"clearDavCache":false,"vacuumPristines":false,"includeExternals":false}}}"#,
            "options.version",
        ),
        (
            89,
            r#"{"jsonrpc":"2.0","id":89,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"cleanup","options":{"version":1,"path":"src","breakLocks":true,"fixRecordedTimestamps":false,"clearDavCache":false,"vacuumPristines":false,"includeExternals":false}}}"#,
            "options.path",
        ),
        (
            90,
            r#"{"jsonrpc":"2.0","id":90,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"cleanup","options":{"version":1,"path":".","fixRecordedTimestamps":false,"clearDavCache":false,"vacuumPristines":false,"includeExternals":false}}}"#,
            "options.breakLocks",
        ),
        (
            91,
            r#"{"jsonrpc":"2.0","id":91,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"cleanup","options":{"version":1,"path":".","breakLocks":true,"fixRecordedTimestamps":false,"clearDavCache":false,"vacuumPristines":false,"includeExternals":false,"removeUnversioned":false}}}"#,
            "options.removeUnversioned",
        ),
    ] {
        let outcome = state
            .dispatch_json_rpc_with_bridge(request, &bridge)
            .unwrap_or_else(|error| panic!("request {request_id} should dispatch: {error}"));
        assert_eq!(
            outcome.response()["error"]["code"],
            "RPC_INVALID_PARAMS",
            "request {request_id} should fail with invalid params",
        );
        assert_eq!(
            outcome.response()["error"]["args"]["field"],
            field,
            "request {request_id} should report {field}",
        );
    }
}

#[test]
fn operation_run_rejects_invalid_upgrade_options() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":92,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    for (request_id, request, field) in [
        (
            93,
            r#"{"jsonrpc":"2.0","id":93,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"upgrade","options":{"version":2,"path":"."}}}"#,
            "options.version",
        ),
        (
            94,
            r#"{"jsonrpc":"2.0","id":94,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"upgrade","options":{"version":1,"path":"src"}}}"#,
            "options.path",
        ),
        (
            95,
            r#"{"jsonrpc":"2.0","id":95,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"upgrade","options":{"version":1,"path":".","includeExternals":false}}}"#,
            "options.includeExternals",
        ),
    ] {
        let outcome = state
            .dispatch_json_rpc_with_bridge(request, &bridge)
            .unwrap_or_else(|error| panic!("request {request_id} should dispatch: {error}"));
        assert_eq!(
            outcome.response()["error"]["code"],
            "RPC_INVALID_PARAMS",
            "request {request_id} should fail with invalid params",
        );
        assert_eq!(
            outcome.response()["error"]["args"]["field"],
            field,
            "request {request_id} should report {field}",
        );
    }
}

#[test]
fn operation_run_requires_matching_open_repository_epoch() {
    let bridge = FakeBridge::open_success().with_revert_result(
        "tracked.txt",
        Ok(subversionr_daemon::OperationResult {
            touched_paths: vec!["tracked.txt".to_string()],
            skipped_paths: Vec::new(),
        }),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":68,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":69,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":2,"kind":"revert","options":{"version":1,"paths":["tracked.txt"],"depth":"empty","changelists":[],"clearChangelists":false,"metadataOnly":false,"addedKeepLocal":false}}}"#,
            &bridge,
        )
        .expect("operation/run should dispatch");

    assert_eq!(outcome.response()["error"]["code"], "REPOSITORY_NOT_OPEN");
    assert!(outcome.notifications().is_empty());

    let unopened = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":70,"method":"operation/run","params":{"repositoryId":"repo-missing:C:/wc","epoch":1,"kind":"revert","options":{"version":1,"paths":["tracked.txt"],"depth":"empty","changelists":[],"clearChangelists":false,"metadataOnly":false,"addedKeepLocal":false}}}"#,
            &bridge,
        )
        .expect("operation/run should dispatch");

    assert_eq!(unopened.response()["error"]["code"], "REPOSITORY_NOT_OPEN");
    assert!(unopened.notifications().is_empty());
}

#[test]
fn operation_run_revert_maps_bridge_failure_to_structured_error() {
    let bridge = FakeBridge::open_success().with_revert_result(
        "locked.txt",
        Err(BridgeFailure::new(
            "SVN_OPERATION_FAILED",
            "native",
            "error.native.operationFailed",
            serde_json::json!({ "path": "locked.txt", "kind": "revert" }),
            false,
        )),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":70,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":71,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"revert","options":{"version":1,"paths":["locked.txt"],"depth":"empty","changelists":[],"clearChangelists":false,"metadataOnly":false,"addedKeepLocal":false}}}"#,
            &bridge,
        )
        .expect("operation/run should dispatch");

    assert_eq!(outcome.response()["error"]["code"], "SVN_OPERATION_FAILED");
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.native.operationFailed"
    );
    assert_eq!(outcome.response()["error"]["args"]["kind"], "revert");
}

#[test]
fn operation_run_add_maps_bridge_failure_to_structured_error() {
    let bridge = FakeBridge::open_success().with_add_result(
        "ignored.txt",
        Err(BridgeFailure::new(
            "SVN_OPERATION_ADD_FAILED",
            "native",
            "error.native.operationAddFailed",
            serde_json::json!({ "path": "ignored.txt", "kind": "add" }),
            false,
        )),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":77,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":78,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"add","options":{"version":1,"paths":["ignored.txt"],"depth":"empty","force":false,"noIgnore":false,"noAutoprops":false,"addParents":false}}}"#,
            &bridge,
        )
        .expect("operation/run add should dispatch");

    assert_eq!(
        outcome.response()["error"]["code"],
        "SVN_OPERATION_ADD_FAILED"
    );
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.native.operationAddFailed"
    );
    assert_eq!(outcome.response()["error"]["args"]["kind"], "add");
}

#[test]
fn operation_run_remove_maps_bridge_failure_to_structured_error() {
    let bridge = FakeBridge::open_success().with_remove_result(
        "src/old.c",
        Err(BridgeFailure::new(
            "SVN_OPERATION_REMOVE_FAILED",
            "native",
            "error.native.operationRemoveFailed",
            serde_json::json!({ "path": "src/old.c", "kind": "remove" }),
            false,
        )),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":87,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":88,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"remove","options":{"version":1,"paths":["src/old.c"],"force":false,"keepLocal":false}}}"#,
            &bridge,
        )
        .expect("operation/run remove should dispatch");

    assert_eq!(
        outcome.response()["error"]["code"],
        "SVN_OPERATION_REMOVE_FAILED"
    );
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.native.operationRemoveFailed"
    );
    assert_eq!(outcome.response()["error"]["args"]["kind"], "remove");
}

#[test]
fn operation_run_move_maps_bridge_failure_to_structured_error() {
    let bridge = FakeBridge::open_success().with_move_result(
        "src/old.c",
        Err(BridgeFailure::new(
            "SVN_OPERATION_MOVE_FAILED",
            "native",
            "error.native.operationMoveFailed",
            serde_json::json!({
                "sourcePath": "src/old.c",
                "destinationPath": "src/new.c",
                "kind": "move",
            }),
            false,
        )),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":89,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":90,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"move","options":{"version":1,"sourcePath":"src/old.c","destinationPath":"src/new.c","makeParents":false}}}"#,
            &bridge,
        )
        .expect("operation/run move should dispatch");

    assert_eq!(
        outcome.response()["error"]["code"],
        "SVN_OPERATION_MOVE_FAILED"
    );
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.native.operationMoveFailed"
    );
    assert_eq!(outcome.response()["error"]["args"]["kind"], "move");
    assert_eq!(
        outcome.notifications()[0]["params"]["reason"],
        "operationMoveFailed"
    );
}

#[test]
fn operation_run_cleanup_maps_bridge_failure_to_structured_error() {
    let bridge = FakeBridge::open_success().with_cleanup_result(
        ".",
        Err(BridgeFailure::new(
            "SVN_OPERATION_CLEANUP_FAILED",
            "native",
            "error.native.operationCleanupFailed",
            serde_json::json!({ "path": ".", "kind": "cleanup" }),
            false,
        )),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":92,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":93,"method":"operation/run","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"kind":"cleanup","options":{"version":1,"path":".","breakLocks":true,"fixRecordedTimestamps":false,"clearDavCache":false,"vacuumPristines":false,"includeExternals":false}}}"#,
            &bridge,
        )
        .expect("operation/run cleanup should dispatch");

    assert_eq!(
        outcome.response()["error"]["code"],
        "SVN_OPERATION_CLEANUP_FAILED"
    );
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.native.operationCleanupFailed"
    );
    assert_eq!(outcome.response()["error"]["args"]["kind"], "cleanup");
}

#[test]
fn status_refresh_returns_delta_and_removes_restored_path_from_cached_snapshot() {
    let bridge = FakeBridge::open_success().with_scan_result(
        "src/main.c",
        "empty",
        FakeBridge::scan_success("src/main.c", Vec::new()),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":24,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":25,"method":"status/getSnapshot","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#,
            &bridge,
        )
        .expect("status/getSnapshot should seed the local cache");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":26,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":"src/main.c","depth":"empty","reason":"fileChanged"}]}}"#,
            &bridge,
        )
        .expect("status/refresh should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(
        outcome.response()["result"]["repositoryId"],
        "repo-uuid:C:/wc"
    );
    assert_eq!(outcome.response()["result"]["epoch"], 1);
    assert_eq!(outcome.response()["result"]["generation"], 2);
    assert_eq!(
        outcome.response()["result"]["coverage"][0]["path"],
        "src/main.c"
    );
    assert_eq!(
        outcome.response()["result"]["coverage"][0]["depth"],
        "empty"
    );
    assert_eq!(
        outcome.response()["result"]["upsert"]
            .as_array()
            .expect("upsert should be an array")
            .len(),
        0
    );
    assert_eq!(outcome.response()["result"]["remove"][0], "src/main.c");
    assert_eq!(
        outcome.response()["result"]["summaryDelta"]["localChanges"],
        -1
    );
    assert_eq!(outcome.response()["result"]["completeness"], "partial");
}

#[test]
fn status_refresh_upserts_targeted_entry_without_remote_status() {
    let bridge = FakeBridge::open_success().with_scan_result(
        "src/other.c",
        "empty",
        FakeBridge::scan_success(
            "src/other.c",
            vec![FakeBridge::status_entry("src/other.c", "modified", 1)],
        ),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":27,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":28,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":"src/other.c","depth":"empty","reason":"fileChanged"}]}}"#,
            &bridge,
        )
        .expect("status/refresh should dispatch");

    assert_eq!(outcome.response()["result"]["generation"], 1);
    assert_eq!(
        outcome.response()["result"]["upsert"][0]["path"],
        "src/other.c"
    );
    assert_eq!(
        outcome.response()["result"]["upsert"][0]["remoteStatus"],
        "notChecked"
    );
    assert_eq!(
        outcome.response()["result"]["remove"]
            .as_array()
            .expect("remove should be an array")
            .len(),
        0
    );
    assert_eq!(
        outcome.response()["result"]["summaryDelta"]["localChanges"],
        1
    );
}

#[test]
fn status_refresh_local_scan_does_not_clear_cached_remote_entries() {
    let bridge = FakeBridge::open_success()
        .with_snapshot_remote_entries(vec![FakeBridge::remote_status_entry(
            "src/incoming.c",
            "modified",
            1,
        )])
        .with_scan_result(
            "src/local.c",
            "empty",
            FakeBridge::scan_success(
                "src/local.c",
                vec![FakeBridge::status_entry("src/local.c", "modified", 1)],
            ),
        );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":130,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":131,"method":"status/getSnapshot","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#,
            &bridge,
        )
        .expect("status/getSnapshot should seed remote cache");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":132,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":"src/local.c","depth":"empty","reason":"fileChanged"}]}}"#,
            &bridge,
        )
        .expect("status/refresh should dispatch");

    assert_eq!(
        outcome.response()["result"]["upsert"][0]["path"],
        "src/local.c"
    );
    assert_eq!(
        outcome.response()["result"]["remoteUpsert"]
            .as_array()
            .expect("remoteUpsert should be an array")
            .len(),
        0
    );
    assert_eq!(
        outcome.response()["result"]["remoteRemove"]
            .as_array()
            .expect("remoteRemove should be an array")
            .len(),
        0
    );
    assert_eq!(
        outcome.response()["result"]["summaryDelta"]["remoteChanges"],
        0
    );
}

#[test]
fn status_check_remote_upserts_authoritative_remote_entries() {
    let bridge = FakeBridge::open_success()
        .with_snapshot_entries(Vec::new())
        .with_remote_entries(vec![FakeBridge::remote_status_entry(
            "src/incoming.c",
            "modified",
            1,
        )]);
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":133,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":134,"method":"status/getSnapshot","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#,
            &bridge,
        )
        .expect("status/getSnapshot should seed empty cache");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":135,"method":"status/checkRemote","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#,
            &bridge,
        )
        .expect("status/refresh should dispatch");

    assert_eq!(
        outcome.response()["result"]["upsert"]
            .as_array()
            .expect("upsert should be an array")
            .len(),
        0
    );
    assert_eq!(
        outcome.response()["result"]["remoteUpsert"][0]["path"],
        "src/incoming.c"
    );
    assert_eq!(
        outcome.response()["result"]["remoteUpsert"][0]["remoteStatus"],
        "modified"
    );
    assert_eq!(
        outcome.response()["result"]["summaryDelta"]["remoteChanges"],
        1
    );
    assert_eq!(outcome.response()["result"]["source"], "libsvn-remote");
    assert_eq!(
        outcome.response()["result"]["coverage"][0]["depth"],
        "workingCopy"
    );
    assert_eq!(*bridge.remote_requests.borrow(), 1);
}

#[test]
fn status_check_remote_removes_cached_entries_absent_from_authoritative_result() {
    let bridge = FakeBridge::open_success().with_snapshot_remote_entries(vec![
        FakeBridge::remote_status_entry("src/incoming.c", "modified", 1),
    ]);
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":136,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":137,"method":"status/getSnapshot","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#,
            &bridge,
        )
        .expect("status/getSnapshot should seed remote cache");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":138,"method":"status/checkRemote","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#,
            &bridge,
        )
        .expect("status/refresh should dispatch");

    assert_eq!(
        outcome.response()["result"]["remoteUpsert"]
            .as_array()
            .expect("remoteUpsert should be an array")
            .len(),
        0
    );
    assert_eq!(
        outcome.response()["result"]["remoteRemove"][0],
        "src/incoming.c"
    );
    assert_eq!(
        outcome.response()["result"]["summaryDelta"]["remoteChanges"],
        -1
    );
}

#[test]
fn status_check_remote_failure_preserves_cache_and_generation() {
    let bridge = FakeBridge::open_success()
        .with_snapshot_entries(Vec::new())
        .with_remote_result(Err(BridgeFailure::new(
            "SVN_REMOTE_STATUS_FAILED",
            "network",
            "error.native.remoteStatusFailed",
            serde_json::json!({ "path": "C:/wc" }),
            true,
        )));
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":143,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let failed = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":144,"method":"status/checkRemote","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#,
            &bridge,
        )
        .expect("status/checkRemote failure should dispatch");
    assert_eq!(
        failed.response()["error"]["code"],
        "SVN_REMOTE_STATUS_FAILED"
    );

    let snapshot = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":145,"method":"status/getSnapshot","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#,
            &bridge,
        )
        .expect("status/getSnapshot should dispatch after failure");
    assert_eq!(snapshot.response()["result"]["generation"], 1);
    assert_eq!(snapshot.response()["result"]["summary"]["remoteChanges"], 0);
}

#[test]
fn status_get_snapshot_preserves_cached_remote_entries_when_local_snapshot_has_no_remote_status() {
    let bridge = FakeBridge::open_success()
        .with_snapshot_entries(Vec::new())
        .with_remote_entries(vec![FakeBridge::remote_status_entry(
            "src/incoming.c",
            "modified",
            1,
        )]);
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":139,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":140,"method":"status/getSnapshot","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#,
            &bridge,
        )
        .expect("initial local snapshot should dispatch");
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":141,"method":"status/checkRemote","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#,
            &bridge,
        )
        .expect("remote refresh should seed remote cache");

    let snapshot = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":142,"method":"status/getSnapshot","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#,
            &bridge,
        )
        .expect("local snapshot should preserve remote cache");

    assert_eq!(
        snapshot.response()["result"]["remoteEntries"][0]["path"],
        "src/incoming.c"
    );
    assert_eq!(
        snapshot.response()["result"]["remoteEntries"][0]["generation"],
        3
    );
    assert_eq!(snapshot.response()["result"]["summary"]["remoteChanges"], 1);
}

#[test]
fn status_refresh_upserts_property_only_changes() {
    let bridge = FakeBridge::open_success().with_scan_result(
        "src/properties.txt",
        "empty",
        FakeBridge::scan_success(
            "src/properties.txt",
            vec![FakeBridge::property_only_status_entry(
                "src/properties.txt",
                1,
            )],
        ),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":116,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":117,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":"src/properties.txt","depth":"empty","reason":"fileChanged"}]}}"#,
            &bridge,
        )
        .expect("status/refresh should dispatch");

    assert_eq!(
        outcome.response()["result"]["upsert"][0]["path"],
        "src/properties.txt"
    );
    assert_eq!(
        outcome.response()["result"]["upsert"][0]["localStatus"],
        "normal"
    );
    assert_eq!(
        outcome.response()["result"]["upsert"][0]["propertyStatus"],
        "modified"
    );
    assert_eq!(
        outcome.response()["result"]["summaryDelta"]["localChanges"],
        1
    );
}

#[test]
fn status_refresh_upserts_sparse_metadata_without_counting_local_changes() {
    let bridge = FakeBridge::open_success()
        .with_snapshot_entries(Vec::new())
        .with_scan_result(
            "sparse-dir",
            "empty",
            FakeBridge::scan_success(
                "sparse-dir",
                vec![FakeBridge::sparse_metadata_status_entry("sparse-dir", 1)],
            ),
        );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":119,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":120,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":"sparse-dir","depth":"empty","reason":"directoryChanged"}]}}"#,
            &bridge,
        )
        .expect("status/refresh should dispatch");

    assert_eq!(
        outcome.response()["result"]["upsert"][0]["path"],
        "sparse-dir"
    );
    assert_eq!(
        outcome.response()["result"]["upsert"][0]["localStatus"],
        "normal"
    );
    assert_eq!(outcome.response()["result"]["upsert"][0]["depth"], "files");
    assert_eq!(
        outcome.response()["result"]["summaryDelta"]["localChanges"],
        0
    );
}

#[test]
fn status_refresh_upserts_switched_metadata_without_counting_local_changes() {
    let bridge = FakeBridge::open_success()
        .with_snapshot_entries(Vec::new())
        .with_scan_result(
            "branches/feature-src",
            "empty",
            FakeBridge::scan_success(
                "branches/feature-src",
                vec![FakeBridge::switched_metadata_status_entry(
                    "branches/feature-src",
                    1,
                )],
            ),
        );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":124,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":125,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":"branches/feature-src","depth":"empty","reason":"directoryChanged"}]}}"#,
            &bridge,
        )
        .expect("status/refresh should dispatch");

    assert_eq!(
        outcome.response()["result"]["upsert"][0]["path"],
        "branches/feature-src"
    );
    assert_eq!(
        outcome.response()["result"]["upsert"][0]["localStatus"],
        "normal"
    );
    assert_eq!(outcome.response()["result"]["upsert"][0]["switched"], true);
    assert_eq!(
        outcome.response()["result"]["summaryDelta"]["localChanges"],
        0
    );
}

#[test]
fn status_refresh_upserts_lock_metadata_without_counting_local_changes() {
    let bridge = FakeBridge::open_success()
        .with_snapshot_entries(Vec::new())
        .with_scan_result(
            "src/locked.c",
            "empty",
            FakeBridge::scan_success(
                "src/locked.c",
                vec![FakeBridge::locked_metadata_status_entry("src/locked.c", 1)],
            ),
        );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":126,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":127,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":"src/locked.c","depth":"empty","reason":"operationLock"}]}}"#,
            &bridge,
        )
        .expect("status/refresh should dispatch");

    assert_eq!(
        outcome.response()["result"]["upsert"][0]["path"],
        "src/locked.c"
    );
    assert_eq!(
        outcome.response()["result"]["upsert"][0]["localStatus"],
        "normal"
    );
    assert_eq!(
        outcome.response()["result"]["upsert"][0]["lock"]["owner"],
        "alice"
    );
    assert_eq!(
        outcome.response()["result"]["summaryDelta"]["localChanges"],
        0
    );
}

#[test]
fn status_refresh_upserts_needs_lock_metadata_without_counting_local_changes() {
    let bridge = FakeBridge::open_success()
        .with_snapshot_entries(Vec::new())
        .with_scan_result(
            "src/needs-lock.c",
            "empty",
            FakeBridge::scan_success(
                "src/needs-lock.c",
                vec![FakeBridge::needs_lock_metadata_status_entry(
                    "src/needs-lock.c",
                    1,
                )],
            ),
        );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":128,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":129,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":"src/needs-lock.c","depth":"empty","reason":"fileChanged"}]}}"#,
            &bridge,
        )
        .expect("status/refresh should dispatch");

    assert_eq!(
        outcome.response()["result"]["upsert"][0]["path"],
        "src/needs-lock.c"
    );
    assert_eq!(outcome.response()["result"]["upsert"][0]["needsLock"], true);
    assert_eq!(
        outcome.response()["result"]["summaryDelta"]["localChanges"],
        0
    );
}

#[test]
fn status_refresh_removes_cached_sparse_metadata_when_full_reconcile_restores_depth() {
    let bridge = FakeBridge::open_success()
        .with_snapshot_result(FakeBridge::sparse_metadata_snapshot_entry("sparse-dir", 1))
        .with_scan_result(".", "infinity", FakeBridge::scan_success(".", Vec::new()));
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":121,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");
    let snapshot = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":122,"method":"status/getSnapshot","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#,
            &bridge,
        )
        .expect("status/getSnapshot should seed sparse metadata in the local cache");
    assert_eq!(
        snapshot.response()["result"]["localEntries"][0]["path"],
        "sparse-dir"
    );
    assert_eq!(snapshot.response()["result"]["summary"]["localChanges"], 0);

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":123,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":".","depth":"infinity","reason":"manualFullReconcile"}]}}"#,
            &bridge,
        )
        .expect("status/refresh should dispatch");

    assert_eq!(outcome.response()["result"]["remove"][0], "sparse-dir");
    assert_eq!(
        outcome.response()["result"]["summaryDelta"]["localChanges"],
        0
    );
    assert_eq!(outcome.response()["result"]["completeness"], "complete");
}

#[test]
fn status_refresh_rejects_absolute_or_parent_relative_targets() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":29,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":30,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":"..\\outside.c","depth":"empty","reason":"fileChanged"}]}}"#,
            &bridge,
        )
        .expect("status/refresh should dispatch");

    assert_eq!(outcome.response()["error"]["code"], "RPC_INVALID_PARAMS");
    assert_eq!(outcome.response()["error"]["args"]["field"], "targets.path");

    let absolute = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":31,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":"C:\\wc\\src\\main.c","depth":"empty","reason":"fileChanged"}]}}"#,
            &bridge,
        )
        .expect("status/refresh should dispatch");

    assert_eq!(absolute.response()["error"]["code"], "RPC_INVALID_PARAMS");
    assert_eq!(
        absolute.response()["error"]["args"]["field"],
        "targets.path"
    );
}

#[test]
fn status_refresh_failure_does_not_commit_partial_multi_target_state() {
    let bridge = FakeBridge::open_success()
        .with_snapshot_entries(Vec::new())
        .with_scan_result(
            "src/other.c",
            "empty",
            FakeBridge::scan_success(
                "src/other.c",
                vec![FakeBridge::status_entry("src/other.c", "modified", 1)],
            ),
        )
        .with_scan_result(
            "src/fail.c",
            "empty",
            FakeBridge::scan_failure("src/fail.c"),
        );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":31,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":32,"method":"status/getSnapshot","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#,
            &bridge,
        )
        .expect("status/getSnapshot should seed an empty local cache");

    let failed = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":33,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":"src/other.c","depth":"empty","reason":"fileChanged"},{"path":"src/fail.c","depth":"empty","reason":"fileChanged"}]}}"#,
            &bridge,
        )
        .expect("status/refresh should dispatch");
    assert_eq!(failed.response()["error"]["code"], "SVN_STATUS_FAILED");

    let retry = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":34,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":"src/other.c","depth":"empty","reason":"fileChanged"}]}}"#,
            &bridge,
        )
        .expect("status/refresh retry should dispatch");

    assert_eq!(retry.response()["result"]["generation"], 2);
    assert_eq!(
        retry.response()["result"]["summaryDelta"]["localChanges"],
        1
    );
}

#[test]
fn status_refresh_cancelled_scan_does_not_advance_generation() {
    let bridge = FakeBridge::open_success()
        .with_snapshot_entries(Vec::new())
        .with_scan_result(
            "src/cancelled.c",
            "empty",
            FakeBridge::scan_cancelled("src/cancelled.c"),
        )
        .with_scan_result(
            "src/other.c",
            "empty",
            FakeBridge::scan_success(
                "src/other.c",
                vec![FakeBridge::status_entry("src/other.c", "modified", 1)],
            ),
        );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":35,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":36,"method":"status/getSnapshot","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#,
            &bridge,
        )
        .expect("status/getSnapshot should seed an empty local cache");

    let cancelled = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":37,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":"src/cancelled.c","depth":"empty","reason":"fileChanged"}]}}"#,
            &bridge,
        )
        .expect("status/refresh cancellation should dispatch");

    assert_eq!(
        cancelled.response()["error"]["code"],
        "SVN_STATUS_CANCELLED"
    );
    assert_eq!(cancelled.response()["error"]["category"], "cancelled");
    assert_eq!(
        cancelled.response()["error"]["messageKey"],
        "error.native.statusCancelled"
    );

    let retry = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":38,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":"src/other.c","depth":"empty","reason":"fileChanged"}]}}"#,
            &bridge,
        )
        .expect("status/refresh retry should dispatch");

    assert_eq!(retry.response()["result"]["generation"], 2);
    assert_eq!(
        retry.response()["result"]["upsert"][0]["path"],
        "src/other.c"
    );
}

#[test]
fn status_refresh_immediates_depth_sweeps_direct_children_but_not_grandchildren() {
    let bridge = FakeBridge::open_success()
        .with_snapshot_entries(vec![
            FakeBridge::status_entry_with_kind("src/file.c", "file", "modified", 1),
            FakeBridge::status_entry_with_kind("src/generated", "dir", "modified", 1),
            FakeBridge::status_entry_with_kind("src/generated/deep.c", "file", "modified", 1),
        ])
        .with_scan_result(
            "src",
            "immediates",
            FakeBridge::scan_success("src", Vec::new()),
        );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":46,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":47,"method":"status/getSnapshot","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#,
            &bridge,
        )
        .expect("status/getSnapshot should seed local entries");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":48,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":"src","depth":"immediates","reason":"directoryChanged"}]}}"#,
            &bridge,
        )
        .expect("status/refresh should dispatch");

    let remove = outcome.response()["result"]["remove"]
        .as_array()
        .expect("remove should be an array");
    assert!(remove.iter().any(|path| path == "src/file.c"));
    assert!(remove.iter().any(|path| path == "src/generated"));
    assert!(!remove.iter().any(|path| path == "src/generated/deep.c"));
    assert_eq!(
        outcome.response()["result"]["summaryDelta"]["localChanges"],
        -2
    );
}

#[test]
fn status_refresh_files_depth_does_not_sweep_child_directory_entries() {
    let bridge = FakeBridge::open_success()
        .with_snapshot_entries(vec![
            FakeBridge::status_entry_with_kind("src/file.c", "file", "modified", 1),
            FakeBridge::status_entry_with_kind("src/generated", "dir", "modified", 1),
        ])
        .with_scan_result("src", "files", FakeBridge::scan_success("src", Vec::new()));
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":35,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":36,"method":"status/getSnapshot","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#,
            &bridge,
        )
        .expect("status/getSnapshot should seed local entries");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":37,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":"src","depth":"files","reason":"directoryChanged"}]}}"#,
            &bridge,
        )
        .expect("status/refresh should dispatch");

    let remove = outcome.response()["result"]["remove"]
        .as_array()
        .expect("remove should be an array");
    assert!(remove.iter().any(|path| path == "src/file.c"));
    assert!(!remove.iter().any(|path| path == "src/generated"));
    assert_eq!(
        outcome.response()["result"]["summaryDelta"]["localChanges"],
        -1
    );
}

#[test]
fn status_refresh_keeps_conflict_entries_even_when_node_status_is_normal() {
    let mut conflict = FakeBridge::status_entry("src/conflicted.txt", "normal", 1);
    conflict.conflict = Some("text".to_string());
    let bridge = FakeBridge::open_success().with_scan_result(
        "src/conflicted.txt",
        "empty",
        FakeBridge::scan_success("src/conflicted.txt", vec![conflict]),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":38,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":39,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":"src/conflicted.txt","depth":"empty","reason":"fileChanged"}]}}"#,
            &bridge,
        )
        .expect("status/refresh should dispatch");

    assert_eq!(
        outcome.response()["result"]["upsert"][0]["path"],
        "src/conflicted.txt"
    );
    assert_eq!(
        outcome.response()["result"]["summaryDelta"]["localChanges"],
        1
    );
    assert_eq!(outcome.response()["result"]["summaryDelta"]["conflicts"], 1);
}

#[test]
fn status_refresh_accepts_root_target_for_manual_full_reconcile() {
    let bridge = FakeBridge::open_success().with_scan_result(
        ".",
        "infinity",
        FakeBridge::scan_success(
            ".",
            vec![FakeBridge::status_entry("src/other.c", "modified", 1)],
        ),
    );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":40,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":41,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":".","depth":"infinity","reason":"manualFullReconcile"}]}}"#,
            &bridge,
        )
        .expect("status/refresh should dispatch");

    assert_eq!(outcome.response()["result"]["coverage"][0]["path"], ".");
    assert_eq!(outcome.response()["result"]["completeness"], "complete");
    assert_eq!(
        outcome.response()["result"]["upsert"][0]["path"],
        "src/other.c"
    );
}

#[test]
fn status_refresh_overlapping_targets_emit_delta_matching_final_cache() {
    let bridge = FakeBridge::open_success()
        .with_snapshot_entries(Vec::new())
        .with_scan_result(
            "src/main.c",
            "empty",
            FakeBridge::scan_success(
                "src/main.c",
                vec![FakeBridge::status_entry("src/main.c", "modified", 1)],
            ),
        )
        .with_scan_result(
            "src",
            "infinity",
            FakeBridge::scan_success("src", Vec::new()),
        );
    let mut state = DaemonState::new();
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":42,"method":"repository/open","params":{"path":"C:\\wc"}}"#,
            &bridge,
        )
        .expect("repository/open should dispatch");
    state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":43,"method":"status/getSnapshot","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#,
            &bridge,
        )
        .expect("status/getSnapshot should seed empty local entries");

    let outcome = state
        .dispatch_json_rpc_with_bridge(
            r#"{"jsonrpc":"2.0","id":44,"method":"status/refresh","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1,"targets":[{"path":"src/main.c","depth":"empty","reason":"fileChanged"},{"path":"src","depth":"infinity","reason":"directoryChanged"}]}}"#,
            &bridge,
        )
        .expect("status/refresh should dispatch");

    assert_eq!(
        outcome.response()["result"]["upsert"]
            .as_array()
            .expect("upsert should be an array")
            .len(),
        0
    );
    assert_eq!(
        outcome.response()["result"]["remove"]
            .as_array()
            .expect("remove should be an array")
            .len(),
        0
    );
    assert_eq!(
        outcome.response()["result"]["summaryDelta"]["localChanges"],
        0
    );
}

#[test]
fn repository_close_invalidates_session_and_later_snapshot_requests() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    let open = r#"{"jsonrpc":"2.0","id":13,"method":"repository/open","params":{"path":"C:\\wc"}}"#;
    state
        .dispatch_json_rpc_with_bridge(open, &bridge)
        .expect("repository/open should dispatch");
    let close = r#"{"jsonrpc":"2.0","id":14,"method":"repository/close","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#;

    let close_outcome = state
        .dispatch_json_rpc_with_bridge(close, &bridge)
        .expect("repository/close should dispatch");

    assert_eq!(close_outcome, DispatchOutcome::Continue);
    assert_eq!(close_outcome.response()["result"]["closed"], true);
    assert_eq!(
        close_outcome.response()["result"]["repositoryId"],
        "repo-uuid:C:/wc"
    );
    assert_eq!(close_outcome.response()["result"]["epoch"], 1);

    let snapshot = r#"{"jsonrpc":"2.0","id":15,"method":"status/getSnapshot","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#;
    let snapshot_outcome = state
        .dispatch_json_rpc_with_bridge(snapshot, &bridge)
        .expect("status/getSnapshot should dispatch");

    assert_eq!(
        snapshot_outcome.response()["error"]["code"],
        "REPOSITORY_NOT_OPEN"
    );
    assert_eq!(
        snapshot_outcome.response()["error"]["messageKey"],
        "error.repository.notOpen"
    );
}

#[test]
fn repository_close_rejects_stale_epoch_and_reopen_advances_epoch() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    let open = r#"{"jsonrpc":"2.0","id":16,"method":"repository/open","params":{"path":"C:\\wc"}}"#;
    state
        .dispatch_json_rpc_with_bridge(open, &bridge)
        .expect("repository/open should dispatch");
    let stale_close = r#"{"jsonrpc":"2.0","id":17,"method":"repository/close","params":{"repositoryId":"repo-uuid:C:/wc","epoch":2}}"#;

    let stale_outcome = state
        .dispatch_json_rpc_with_bridge(stale_close, &bridge)
        .expect("repository/close should dispatch");

    assert_eq!(
        stale_outcome.response()["error"]["code"],
        "REPOSITORY_NOT_OPEN"
    );

    let current_close = r#"{"jsonrpc":"2.0","id":18,"method":"repository/close","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#;
    state
        .dispatch_json_rpc_with_bridge(current_close, &bridge)
        .expect("repository/close should dispatch");
    let reopen =
        r#"{"jsonrpc":"2.0","id":19,"method":"repository/open","params":{"path":"C:\\wc"}}"#;
    let reopen_outcome = state
        .dispatch_json_rpc_with_bridge(reopen, &bridge)
        .expect("repository/open should dispatch");

    assert_eq!(reopen_outcome.response()["result"]["epoch"], 2);
}

#[test]
fn repository_open_rejects_duplicate_session_without_advancing_epoch() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    let open = r#"{"jsonrpc":"2.0","id":47,"method":"repository/open","params":{"path":"C:\\wc"}}"#;
    state
        .dispatch_json_rpc_with_bridge(open, &bridge)
        .expect("repository/open should dispatch");
    let duplicate =
        r#"{"jsonrpc":"2.0","id":48,"method":"repository/open","params":{"path":"C:\\wc"}}"#;

    let duplicate_outcome = state
        .dispatch_json_rpc_with_bridge(duplicate, &bridge)
        .expect("duplicate repository/open should dispatch");

    assert_eq!(
        duplicate_outcome.response()["error"]["code"],
        "REPOSITORY_ALREADY_OPEN"
    );
    assert_eq!(
        duplicate_outcome.response()["error"]["messageKey"],
        "error.repository.alreadyOpen"
    );
    assert_eq!(
        duplicate_outcome.response()["error"]["args"]["repositoryId"],
        "repo-uuid:C:/wc"
    );

    let close = r#"{"jsonrpc":"2.0","id":49,"method":"repository/close","params":{"repositoryId":"repo-uuid:C:/wc","epoch":1}}"#;
    let close_outcome = state
        .dispatch_json_rpc_with_bridge(close, &bridge)
        .expect("repository/close should dispatch");
    assert_eq!(close_outcome.response()["result"]["closed"], true);

    let reopen =
        r#"{"jsonrpc":"2.0","id":50,"method":"repository/open","params":{"path":"C:\\wc"}}"#;
    let reopen_outcome = state
        .dispatch_json_rpc_with_bridge(reopen, &bridge)
        .expect("repository/open should dispatch");
    assert_eq!(reopen_outcome.response()["result"]["epoch"], 2);
}

#[test]
fn status_get_snapshot_requires_matching_epoch() {
    let bridge = FakeBridge::open_success();
    let mut state = DaemonState::new();
    let open = r#"{"jsonrpc":"2.0","id":20,"method":"repository/open","params":{"path":"C:\\wc"}}"#;
    state
        .dispatch_json_rpc_with_bridge(open, &bridge)
        .expect("repository/open should dispatch");
    let request = r#"{"jsonrpc":"2.0","id":21,"method":"status/getSnapshot","params":{"repositoryId":"repo-uuid:C:/wc","epoch":2}}"#;

    let outcome = state
        .dispatch_json_rpc_with_bridge(request, &bridge)
        .expect("status/getSnapshot should dispatch");

    assert_eq!(outcome.response()["error"]["code"], "REPOSITORY_NOT_OPEN");
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.repository.notOpen"
    );
}

#[test]
fn repository_open_maps_loaded_bridge_failure_to_structured_error() {
    let request =
        r#"{"jsonrpc":"2.0","id":7,"method":"repository/open","params":{"path":"C:\\missing"}}"#;
    let bridge = FakeBridge::open_failure();

    let outcome =
        dispatch_json_rpc_with_bridge(request, &bridge).expect("repository/open should dispatch");

    assert_eq!(outcome, DispatchOutcome::Continue);
    assert_eq!(outcome.response()["id"], 7);
    assert_eq!(outcome.response()["error"]["code"], "SVN_WC_NOT_FOUND");
    assert_eq!(outcome.response()["error"]["category"], "native");
    assert_eq!(
        outcome.response()["error"]["messageKey"],
        "error.native.workingCopyNotFound"
    );
    assert_eq!(outcome.response()["error"]["args"]["path"], "C:\\missing");
}

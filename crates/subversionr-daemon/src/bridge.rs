use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use subversionr_protocol::{
    Capabilities, CertificateTrustRequest, CertificateTrustResponse, CredentialRequest,
    CredentialResponse, CredentialSettlementAck, CredentialSettlementRequest, HistoryBlameLine,
    HistoryLogEntry, OperationFailureDiagnostics, RepositoryIdentity, StatusSnapshot,
    default_capabilities,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RemoteConfigScheme {
    Http,
    Https,
    Svn,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RemoteConfigServerAuth {
    Anonymous,
    Basic,
    CramMd5,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct RemoteConfigPlan {
    pub scheme: RemoteConfigScheme,
    pub server_auth: RemoteConfigServerAuth,
    pub timeout_ms: u64,
    pub trust_windows_roots: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeInfo {
    pub bridge_version: String,
    pub libsvn_version: String,
    pub real_libsvn_bridge: bool,
}

impl BridgeInfo {
    pub fn available(bridge_version: impl Into<String>, libsvn_version: impl Into<String>) -> Self {
        Self {
            bridge_version: bridge_version.into(),
            libsvn_version: libsvn_version.into(),
            real_libsvn_bridge: true,
        }
    }

    pub fn unavailable() -> Self {
        Self {
            bridge_version: "bridge-unavailable".to_string(),
            libsvn_version: "1.14.5".to_string(),
            real_libsvn_bridge: false,
        }
    }

    pub(crate) fn capabilities(&self) -> Capabilities {
        let mut capabilities = default_capabilities();
        capabilities.real_libsvn_bridge = self.real_libsvn_bridge;
        capabilities
    }
}

pub trait BridgeCancellationToken {
    fn is_cancelled(&self) -> bool;
}

#[derive(Debug, Default, Clone, Copy)]
pub struct NeverCancelled;

impl BridgeCancellationToken for NeverCancelled {
    fn is_cancelled(&self) -> bool {
        false
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct BridgeFailure {
    pub(crate) code: String,
    pub(crate) category: String,
    pub(crate) message_key: String,
    pub(crate) args: Value,
    pub(crate) retryable: bool,
    pub(crate) diagnostics: Option<Box<OperationFailureDiagnostics>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContentBlob {
    pub data: Vec<u8>,
    pub mime_type: Option<String>,
    pub is_binary: bool,
    pub source: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PropertyEntry {
    pub name: String,
    pub value: String,
    pub value_encoding: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PropertiesListResult {
    pub properties: Vec<PropertyEntry>,
    pub source: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryLogRequest {
    pub path: String,
    pub start_revision: String,
    pub end_revision: String,
    pub limit: u32,
    pub discover_changed_paths: bool,
    pub strict_node_history: bool,
    pub include_merged_revisions: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryLogResult {
    pub entries: Vec<HistoryLogEntry>,
    pub source: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryBlameRequest {
    pub path: String,
    pub peg_revision: String,
    pub start_revision: String,
    pub end_revision: String,
    pub line_start: u64,
    pub line_limit: u32,
    pub ignore_whitespace: String,
    pub ignore_eol_style: bool,
    pub ignore_mime_type: bool,
    pub include_merged_revisions: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryBlameResult {
    pub resolved_start_revision: i64,
    pub resolved_end_revision: i64,
    pub line_start: u64,
    pub line_limit: u32,
    pub ignore_whitespace: String,
    pub ignore_eol_style: bool,
    pub ignore_mime_type: bool,
    pub include_merged_revisions: bool,
    pub has_more: bool,
    pub lines: Vec<HistoryBlameLine>,
    pub source: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RepositoryCheckoutRequest {
    pub url: String,
    pub target_path: String,
    pub revision: String,
    pub depth: String,
    pub ignore_externals: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RepositoryCheckoutResult {
    pub working_copy_path: String,
    pub revision: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RevertOperationRequest {
    pub paths: Vec<String>,
    pub depth: String,
    pub changelists: Vec<String>,
    pub clear_changelists: bool,
    pub metadata_only: bool,
    pub added_keep_local: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AddOperationRequest {
    pub paths: Vec<String>,
    pub depth: String,
    pub force: bool,
    pub no_ignore: bool,
    pub no_autoprops: bool,
    pub add_parents: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoveOperationRequest {
    pub paths: Vec<String>,
    pub force: bool,
    pub keep_local: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MoveOperationRequest {
    pub source_path: String,
    pub destination_path: String,
    pub make_parents: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolveOperationRequest {
    pub paths: Vec<String>,
    pub depth: String,
    pub choice: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CleanupOperationRequest {
    pub path: String,
    pub break_locks: bool,
    pub fix_recorded_timestamps: bool,
    pub clear_dav_cache: bool,
    pub vacuum_pristines: bool,
    pub include_externals: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpgradeOperationRequest {
    pub path: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpdateOperationRequest {
    pub path: String,
    pub revision: String,
    pub depth: String,
    pub depth_is_sticky: bool,
    pub ignore_externals: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PropertySetOperationRequest {
    pub path: String,
    pub name: String,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PropertyDeleteOperationRequest {
    pub path: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChangelistSetOperationRequest {
    pub paths: Vec<String>,
    pub depth: String,
    pub changelist: String,
    pub changelists: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChangelistClearOperationRequest {
    pub paths: Vec<String>,
    pub depth: String,
    pub changelists: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LockOperationRequest {
    pub paths: Vec<String>,
    pub comment: Option<String>,
    pub steal_lock: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnlockOperationRequest {
    pub paths: Vec<String>,
    pub break_lock: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BranchCreateOperationRequest {
    pub source_url: String,
    pub destination_url: String,
    pub revision: String,
    pub message: String,
    pub make_parents: bool,
    pub ignore_externals: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BranchCreateOperationResult {
    pub result: OperationResult,
    pub revision: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SwitchOperationRequest {
    pub path: String,
    pub url: String,
    pub revision: String,
    pub depth: String,
    pub depth_is_sticky: bool,
    pub ignore_externals: bool,
    pub ignore_ancestry: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SwitchOperationResult {
    pub result: OperationResult,
    pub revision: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelocateOperationRequest {
    pub from_url: String,
    pub to_url: String,
    pub ignore_externals: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MergeOperationRequest {
    pub source_url: String,
    pub target_path: String,
    pub start_revision: i64,
    pub end_revision: i64,
    pub depth: String,
    pub ignore_mergeinfo: bool,
    pub diff_ignore_ancestry: bool,
    pub force_delete: bool,
    pub record_only: bool,
    pub dry_run: bool,
    pub allow_mixed_revisions: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommitOperationRequest {
    pub paths: Vec<String>,
    pub message: String,
    pub depth: String,
    pub changelists: Vec<String>,
    pub keep_locks: bool,
    pub keep_changelists: bool,
    pub commit_as_operations: bool,
    pub include_file_externals: bool,
    pub include_dir_externals: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OperationResult {
    pub touched_paths: Vec<String>,
    pub skipped_paths: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpdateOperationResult {
    pub result: OperationResult,
    pub revision: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommitOperationResult {
    pub result: OperationResult,
    pub revision: i64,
}

impl BridgeFailure {
    pub fn new(
        code: impl Into<String>,
        category: impl Into<String>,
        message_key: impl Into<String>,
        args: Value,
        retryable: bool,
    ) -> Self {
        Self {
            code: code.into(),
            category: category.into(),
            message_key: message_key.into(),
            args,
            retryable,
            diagnostics: None,
        }
    }

    pub(crate) fn with_diagnostics(mut self, diagnostics: OperationFailureDiagnostics) -> Self {
        self.diagnostics = Some(Box::new(diagnostics));
        self
    }

    pub fn code(&self) -> &str {
        &self.code
    }

    pub fn safe_args(&self) -> &Value {
        &self.args
    }

    pub fn diagnostics(&self) -> Option<&OperationFailureDiagnostics> {
        self.diagnostics.as_deref()
    }

    pub(crate) fn bridge_unavailable(path: &str) -> Self {
        Self::new(
            "SVN_BRIDGE_UNAVAILABLE",
            "native",
            "error.native.bridgeUnavailable",
            json!({ "path": path }),
            false,
        )
    }

    pub(crate) fn invalid_path() -> Self {
        Self::new(
            "RPC_INVALID_PARAMS",
            "protocol",
            "error.rpc.invalidParams",
            json!({ "field": "path" }),
            false,
        )
    }
}

pub trait BridgeApi {
    fn info(&self) -> BridgeInfo;

    fn create_remote_context_foundation(
        &self,
        _plan: RemoteConfigPlan,
    ) -> Result<(), BridgeFailure> {
        Err(BridgeFailure::new(
            "SUBVERSIONR_REMOTE_CONFIG_UNAVAILABLE",
            "native",
            "error.remote.configUnavailable",
            json!({}),
            false,
        ))
    }

    fn open_working_copy(&self, path: &str) -> Result<RepositoryIdentity, BridgeFailure>;

    fn open_working_copy_with_auth(
        &self,
        path: &str,
        _auth: &mut dyn AuthRequestBroker,
    ) -> Result<RepositoryIdentity, BridgeFailure> {
        self.open_working_copy(path)
    }

    fn repository_checkout(
        &self,
        request: &RepositoryCheckoutRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<RepositoryCheckoutResult, BridgeFailure> {
        let cancellation = NeverCancelled;
        self.repository_checkout_with_cancellation(request, auth, &cancellation)
    }

    fn repository_checkout_with_cancellation(
        &self,
        request: &RepositoryCheckoutRequest,
        _auth: &mut dyn AuthRequestBroker,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<RepositoryCheckoutResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(&request.target_path))
    }

    fn status_snapshot(
        &self,
        identity: &RepositoryIdentity,
        generation: u64,
    ) -> Result<StatusSnapshot, BridgeFailure> {
        let cancellation = NeverCancelled;
        self.status_snapshot_with_cancellation(identity, generation, &cancellation)
    }

    fn status_snapshot_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        generation: u64,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<StatusSnapshot, BridgeFailure>;

    fn status_scan(
        &self,
        identity: &RepositoryIdentity,
        path: &str,
        depth: &str,
        generation: u64,
    ) -> Result<StatusSnapshot, BridgeFailure> {
        let cancellation = NeverCancelled;
        self.status_scan_with_cancellation(identity, path, depth, generation, &cancellation)
    }

    fn status_scan_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        path: &str,
        depth: &str,
        generation: u64,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<StatusSnapshot, BridgeFailure>;

    fn status_remote_check_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _generation: u64,
        _auth: &mut dyn AuthRequestBroker,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<StatusSnapshot, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn content_get(
        &self,
        identity: &RepositoryIdentity,
        path: &str,
        revision: &str,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<ContentBlob, BridgeFailure>;

    fn properties_list(
        &self,
        identity: &RepositoryIdentity,
        path: &str,
    ) -> Result<PropertiesListResult, BridgeFailure>;

    fn history_log(
        &self,
        identity: &RepositoryIdentity,
        request: &HistoryLogRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<HistoryLogResult, BridgeFailure>;

    fn history_blame(
        &self,
        identity: &RepositoryIdentity,
        request: &HistoryBlameRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<HistoryBlameResult, BridgeFailure>;

    fn operation_revert(
        &self,
        identity: &RepositoryIdentity,
        request: &RevertOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        let cancellation = NeverCancelled;
        self.operation_revert_with_cancellation(identity, request, &cancellation)
    }

    fn operation_revert_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &RevertOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure>;

    fn operation_add(
        &self,
        identity: &RepositoryIdentity,
        request: &AddOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        let cancellation = NeverCancelled;
        self.operation_add_with_cancellation(identity, request, &cancellation)
    }

    fn operation_add_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &AddOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure>;

    fn operation_remove(
        &self,
        identity: &RepositoryIdentity,
        request: &RemoveOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        let cancellation = NeverCancelled;
        self.operation_remove_with_cancellation(identity, request, &cancellation)
    }

    fn operation_remove_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &RemoveOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure>;

    fn operation_move(
        &self,
        identity: &RepositoryIdentity,
        request: &MoveOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        let cancellation = NeverCancelled;
        self.operation_move_with_cancellation(identity, request, &cancellation)
    }

    fn operation_move_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &MoveOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure>;

    fn operation_resolve(
        &self,
        identity: &RepositoryIdentity,
        request: &ResolveOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        let cancellation = NeverCancelled;
        self.operation_resolve_with_cancellation(identity, request, &cancellation)
    }

    fn operation_resolve_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &ResolveOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure>;

    fn operation_cleanup(
        &self,
        identity: &RepositoryIdentity,
        request: &CleanupOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        let cancellation = NeverCancelled;
        self.operation_cleanup_with_cancellation(identity, request, &cancellation)
    }

    fn operation_cleanup_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &CleanupOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure>;

    fn operation_upgrade(
        &self,
        identity: &RepositoryIdentity,
        request: &UpgradeOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        let cancellation = NeverCancelled;
        self.operation_upgrade_with_cancellation(identity, request, &cancellation)
    }

    fn operation_upgrade_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _request: &UpgradeOperationRequest,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_update(
        &self,
        identity: &RepositoryIdentity,
        request: &UpdateOperationRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<UpdateOperationResult, BridgeFailure> {
        let cancellation = NeverCancelled;
        self.operation_update_with_cancellation(identity, request, auth, &cancellation)
    }

    fn operation_update_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &UpdateOperationRequest,
        auth: &mut dyn AuthRequestBroker,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<UpdateOperationResult, BridgeFailure>;

    fn operation_property_set(
        &self,
        identity: &RepositoryIdentity,
        request: &PropertySetOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        let cancellation = NeverCancelled;
        self.operation_property_set_with_cancellation(identity, request, &cancellation)
    }

    fn operation_property_set_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &PropertySetOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure>;

    fn operation_property_delete(
        &self,
        identity: &RepositoryIdentity,
        request: &PropertyDeleteOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        let cancellation = NeverCancelled;
        self.operation_property_delete_with_cancellation(identity, request, &cancellation)
    }

    fn operation_property_delete_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &PropertyDeleteOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure>;

    fn operation_changelist_set(
        &self,
        identity: &RepositoryIdentity,
        request: &ChangelistSetOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        let cancellation = NeverCancelled;
        self.operation_changelist_set_with_cancellation(identity, request, &cancellation)
    }

    fn operation_changelist_set_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _request: &ChangelistSetOperationRequest,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_changelist_clear(
        &self,
        identity: &RepositoryIdentity,
        request: &ChangelistClearOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        let cancellation = NeverCancelled;
        self.operation_changelist_clear_with_cancellation(identity, request, &cancellation)
    }

    fn operation_changelist_clear_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _request: &ChangelistClearOperationRequest,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_lock(
        &self,
        identity: &RepositoryIdentity,
        request: &LockOperationRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<OperationResult, BridgeFailure> {
        let cancellation = NeverCancelled;
        self.operation_lock_with_cancellation(identity, request, auth, &cancellation)
    }

    fn operation_lock_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _request: &LockOperationRequest,
        _auth: &mut dyn AuthRequestBroker,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_unlock(
        &self,
        identity: &RepositoryIdentity,
        request: &UnlockOperationRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<OperationResult, BridgeFailure> {
        let cancellation = NeverCancelled;
        self.operation_unlock_with_cancellation(identity, request, auth, &cancellation)
    }

    fn operation_unlock_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _request: &UnlockOperationRequest,
        _auth: &mut dyn AuthRequestBroker,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_branch_create(
        &self,
        identity: &RepositoryIdentity,
        request: &BranchCreateOperationRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<BranchCreateOperationResult, BridgeFailure> {
        let cancellation = NeverCancelled;
        self.operation_branch_create_with_cancellation(identity, request, auth, &cancellation)
    }

    fn operation_branch_create_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _request: &BranchCreateOperationRequest,
        _auth: &mut dyn AuthRequestBroker,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<BranchCreateOperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_switch(
        &self,
        identity: &RepositoryIdentity,
        request: &SwitchOperationRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<SwitchOperationResult, BridgeFailure> {
        let cancellation = NeverCancelled;
        self.operation_switch_with_cancellation(identity, request, auth, &cancellation)
    }

    fn operation_switch_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _request: &SwitchOperationRequest,
        _auth: &mut dyn AuthRequestBroker,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<SwitchOperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_relocate(
        &self,
        identity: &RepositoryIdentity,
        request: &RelocateOperationRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<OperationResult, BridgeFailure> {
        let cancellation = NeverCancelled;
        self.operation_relocate_with_cancellation(identity, request, auth, &cancellation)
    }

    fn operation_relocate_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _request: &RelocateOperationRequest,
        _auth: &mut dyn AuthRequestBroker,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_merge(
        &self,
        identity: &RepositoryIdentity,
        request: &MergeOperationRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<OperationResult, BridgeFailure> {
        let cancellation = NeverCancelled;
        self.operation_merge_with_cancellation(identity, request, auth, &cancellation)
    }

    fn operation_merge_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _request: &MergeOperationRequest,
        _auth: &mut dyn AuthRequestBroker,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_commit(
        &self,
        identity: &RepositoryIdentity,
        request: &CommitOperationRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<CommitOperationResult, BridgeFailure> {
        let cancellation = NeverCancelled;
        self.operation_commit_with_cancellation(identity, request, auth, &cancellation)
    }

    fn operation_commit_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &CommitOperationRequest,
        auth: &mut dyn AuthRequestBroker,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<CommitOperationResult, BridgeFailure>;
}

pub trait AuthRequestBroker {
    fn request_credential(
        &mut self,
        request: CredentialRequest,
    ) -> Result<CredentialResponse, BridgeFailure>;

    fn settle_credential(
        &mut self,
        request: CredentialSettlementRequest,
    ) -> Result<CredentialSettlementAck, BridgeFailure>;

    fn request_certificate_trust(
        &mut self,
        request: CertificateTrustRequest,
    ) -> Result<CertificateTrustResponse, BridgeFailure>;
}

#[derive(Debug, Default)]
pub struct UnavailableAuthRequestBroker;

impl AuthRequestBroker for UnavailableAuthRequestBroker {
    fn request_credential(
        &mut self,
        _request: CredentialRequest,
    ) -> Result<CredentialResponse, BridgeFailure> {
        Err(BridgeFailure::new(
            "SUBVERSIONR_AUTH_BROKER_UNAVAILABLE",
            "auth",
            "error.auth.brokerUnavailable",
            json!({ "method": "credentials/request" }),
            false,
        ))
    }

    fn settle_credential(
        &mut self,
        _request: CredentialSettlementRequest,
    ) -> Result<CredentialSettlementAck, BridgeFailure> {
        Err(BridgeFailure::new(
            "SUBVERSIONR_AUTH_BROKER_UNAVAILABLE",
            "auth",
            "error.auth.brokerUnavailable",
            json!({ "method": "credentials/settle" }),
            false,
        ))
    }

    fn request_certificate_trust(
        &mut self,
        _request: CertificateTrustRequest,
    ) -> Result<CertificateTrustResponse, BridgeFailure> {
        Err(BridgeFailure::new(
            "SUBVERSIONR_AUTH_BROKER_UNAVAILABLE",
            "auth",
            "error.auth.brokerUnavailable",
            json!({ "method": "certificate/request" }),
            false,
        ))
    }
}

#[derive(Debug, Default)]
pub struct UnavailableBridge;

impl BridgeApi for UnavailableBridge {
    fn info(&self) -> BridgeInfo {
        BridgeInfo::unavailable()
    }

    fn open_working_copy(&self, path: &str) -> Result<RepositoryIdentity, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(path))
    }

    fn repository_checkout_with_cancellation(
        &self,
        request: &RepositoryCheckoutRequest,
        _auth: &mut dyn AuthRequestBroker,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<RepositoryCheckoutResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(&request.target_path))
    }

    fn status_snapshot(
        &self,
        identity: &RepositoryIdentity,
        _generation: u64,
    ) -> Result<StatusSnapshot, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn status_snapshot_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _generation: u64,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<StatusSnapshot, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn status_scan(
        &self,
        identity: &RepositoryIdentity,
        _path: &str,
        _depth: &str,
        _generation: u64,
    ) -> Result<StatusSnapshot, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn status_scan_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _path: &str,
        _depth: &str,
        _generation: u64,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<StatusSnapshot, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn content_get(
        &self,
        identity: &RepositoryIdentity,
        _path: &str,
        _revision: &str,
        _auth: &mut dyn AuthRequestBroker,
    ) -> Result<ContentBlob, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn properties_list(
        &self,
        identity: &RepositoryIdentity,
        _path: &str,
    ) -> Result<PropertiesListResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn history_log(
        &self,
        identity: &RepositoryIdentity,
        _request: &HistoryLogRequest,
        _auth: &mut dyn AuthRequestBroker,
    ) -> Result<HistoryLogResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn history_blame(
        &self,
        identity: &RepositoryIdentity,
        _request: &HistoryBlameRequest,
        _auth: &mut dyn AuthRequestBroker,
    ) -> Result<HistoryBlameResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_revert(
        &self,
        identity: &RepositoryIdentity,
        _request: &RevertOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_revert_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _request: &RevertOperationRequest,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_add(
        &self,
        identity: &RepositoryIdentity,
        _request: &AddOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_add_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _request: &AddOperationRequest,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_remove(
        &self,
        identity: &RepositoryIdentity,
        _request: &RemoveOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_remove_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _request: &RemoveOperationRequest,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_move(
        &self,
        identity: &RepositoryIdentity,
        _request: &MoveOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_move_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _request: &MoveOperationRequest,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_resolve(
        &self,
        identity: &RepositoryIdentity,
        _request: &ResolveOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_resolve_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _request: &ResolveOperationRequest,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_cleanup(
        &self,
        identity: &RepositoryIdentity,
        _request: &CleanupOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_cleanup_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _request: &CleanupOperationRequest,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_upgrade(
        &self,
        identity: &RepositoryIdentity,
        _request: &UpgradeOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_upgrade_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _request: &UpgradeOperationRequest,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_update(
        &self,
        identity: &RepositoryIdentity,
        _request: &UpdateOperationRequest,
        _auth: &mut dyn AuthRequestBroker,
    ) -> Result<UpdateOperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_update_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _request: &UpdateOperationRequest,
        _auth: &mut dyn AuthRequestBroker,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<UpdateOperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_property_set(
        &self,
        identity: &RepositoryIdentity,
        _request: &PropertySetOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_property_set_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _request: &PropertySetOperationRequest,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_property_delete(
        &self,
        identity: &RepositoryIdentity,
        _request: &PropertyDeleteOperationRequest,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_property_delete_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _request: &PropertyDeleteOperationRequest,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_commit(
        &self,
        identity: &RepositoryIdentity,
        _request: &CommitOperationRequest,
        _auth: &mut dyn AuthRequestBroker,
    ) -> Result<CommitOperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_merge(
        &self,
        identity: &RepositoryIdentity,
        _request: &MergeOperationRequest,
        _auth: &mut dyn AuthRequestBroker,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_merge_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _request: &MergeOperationRequest,
        _auth: &mut dyn AuthRequestBroker,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }

    fn operation_commit_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        _request: &CommitOperationRequest,
        _auth: &mut dyn AuthRequestBroker,
        _cancellation: &dyn BridgeCancellationToken,
    ) -> Result<CommitOperationResult, BridgeFailure> {
        Err(BridgeFailure::bridge_unavailable(
            &identity.working_copy_root,
        ))
    }
}

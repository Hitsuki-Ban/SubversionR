use serde::{
    Deserialize, Deserializer, Serialize, Serializer,
    de::{self, Visitor},
};
use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProtocolVersion {
    pub major: u16,
    pub minor: u16,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlatformDescriptor {
    pub os: String,
    pub arch: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum WorkspaceTrustState {
    Trusted,
    Untrusted,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct InitializeParams {
    pub client_name: String,
    pub client_version: String,
    pub locale: String,
    pub workspace_trust: WorkspaceTrustState,
    pub trust_epoch: u64,
    pub cache_root: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct WorkspaceTrustUpdateParams {
    pub trusted: bool,
    pub trust_epoch: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct WorkspaceTrustUpdateResponse {
    pub acknowledged_trust_epoch: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Capabilities {
    pub content_length_framing: bool,
    pub real_libsvn_bridge: bool,
    pub repository_discover: bool,
    pub repository_open: bool,
    pub repository_checkout: bool,
    pub repository_close: bool,
    pub status_snapshot: bool,
    pub status_refresh: bool,
    pub status_remote_check: bool,
    pub status_stale_notification: bool,
    pub content_get: bool,
    pub content_get_revision: bool,
    pub history_log: bool,
    pub history_blame: bool,
    pub operation_run: bool,
    pub operation_run_add: bool,
    pub operation_run_remove: bool,
    pub operation_run_move: bool,
    pub operation_run_cleanup: bool,
    pub operation_run_resolve: bool,
    pub operation_run_update: bool,
    pub operation_run_update_selected_path: bool,
    pub operation_run_update_to_revision: bool,
    pub operation_run_update_depth: bool,
    pub operation_run_update_externals_policy: bool,
    pub properties_list: bool,
    pub operation_run_property_set: bool,
    pub operation_run_property_delete: bool,
    pub ignore: bool,
    pub operation_run_changelist_set: bool,
    pub operation_run_changelist_clear: bool,
    pub operation_run_lock: bool,
    pub operation_run_unlock: bool,
    pub operation_run_branch_create: bool,
    pub operation_run_switch: bool,
    pub operation_run_relocate: bool,
    pub operation_run_commit: bool,
    pub operation_run_commit_multi_path: bool,
    pub diagnostics_get: bool,
    pub credential_request: bool,
    pub certificate_request: bool,
    pub remote_operation_envelope: bool,
    pub trusted_config_snapshot: bool,
    pub remote_worker_isolation: bool,
    pub credential_lease_settlement: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RemoteScheme {
    Http,
    Https,
    Svn,
    #[serde(rename = "svn+ssh")]
    SvnSsh,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct CanonicalEndpoint {
    pub scheme: RemoteScheme,
    pub canonical_host: String,
    pub effective_port: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RemoteServerAuth {
    Anonymous,
    Basic,
    CramMd5,
    WindowsIntegrated,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NoServerAccount {
    None,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "mode", rename_all = "camelCase", deny_unknown_fields)]
pub enum ServerAccountSelection {
    Fixed { username: String },
    ChooseForeground,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ServerAccountSnapshot {
    None(NoServerAccount),
    Selection(ServerAccountSelection),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ServerCredentialPersistence {
    SecretStorage,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TlsTrustPolicy {
    WindowsRootsThenBroker,
    ExplicitCaThenBroker,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TlsProfileSnapshot {
    pub trust: TlsTrustPolicy,
    pub ca_bundle_path: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NoProxyProfile {
    None,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ProxyAuth {
    Anonymous,
    Basic,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct FixedProxyAccount {
    pub mode: FixedAccountMode,
    pub username: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FixedAccountMode {
    Fixed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ProxyAccountSnapshot {
    None(NoServerAccount),
    Fixed(FixedProxyAccount),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct ProxyProfileConfiguration {
    pub authority: CanonicalEndpoint,
    pub auth: ProxyAuth,
    pub account: ProxyAccountSnapshot,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ProxyProfileSnapshot {
    None(NoProxyProfile),
    Configuration(ProxyProfileConfiguration),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NoSshProfile {
    None,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OpenSshAdapter {
    WindowsInboxOpenSsh,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OpenSshAgentAuth {
    Agent,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct OpenSshIdentityFileAuth {
    pub identity_file_path: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum OpenSshAuth {
    Agent(OpenSshAgentAuth),
    IdentityFile(OpenSshIdentityFileAuth),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct OpenSshHostKey {
    pub algorithm: String,
    pub public_key_blob: String,
    pub fingerprint: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct OpenSshProfileSnapshot {
    pub adapter: OpenSshAdapter,
    pub ssh_username: String,
    pub auth: OpenSshAuth,
    pub host_key: OpenSshHostKey,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum SshProfileSnapshot {
    None(NoSshProfile),
    OpenSsh(OpenSshProfileSnapshot),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RedirectPolicy {
    RejectAll,
    SameAuthorityInitialOptions301,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct RemoteAccessProfileSnapshot {
    pub schema: String,
    pub profile_id: String,
    pub authority: CanonicalEndpoint,
    pub server_auth: RemoteServerAuth,
    pub server_account: ServerAccountSnapshot,
    pub server_credential_persistence: ServerCredentialPersistence,
    pub tls: Option<TlsProfileSnapshot>,
    pub proxy: ProxyProfileSnapshot,
    pub ssh: SshProfileSnapshot,
    pub redirect_policy: RedirectPolicy,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RemoteOperationIntent {
    Foreground,
    Background,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RemoteInteraction {
    Allowed,
    Forbidden,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TrustedWorkspaceState {
    Trusted,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct RemoteOperationEnvelope {
    pub version: u16,
    pub operation_id: String,
    pub intent: RemoteOperationIntent,
    pub interaction: RemoteInteraction,
    pub timeout_ms: u64,
    pub workspace_trust: TrustedWorkspaceState,
    pub trust_epoch: u64,
    pub profile: RemoteAccessProfileSnapshot,
    pub expected_origin: CanonicalEndpoint,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CacheSchema {
    pub schema_id: String,
    pub version: u16,
    pub rollback: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InitializeResponse {
    pub protocol: ProtocolVersion,
    pub backend_version: String,
    pub bridge_version: String,
    pub libsvn_version: String,
    pub platform: PlatformDescriptor,
    pub cache_schema: CacheSchema,
    pub capabilities: Capabilities,
    pub acknowledged_trust_epoch: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RepositoryOpenParams {
    pub path: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RepositoryIdentity {
    pub repository_uuid: String,
    pub repository_root_url: String,
    pub working_copy_root: String,
    pub workspace_scope_root: String,
    pub format: i32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RepositoryOpenResponse {
    pub repository_id: String,
    pub epoch: u64,
    pub identity: RepositoryIdentity,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RepositoryCheckoutParams {
    pub url: String,
    pub target_path: String,
    pub revision: RepositoryCheckoutRevision,
    pub depth: String,
    pub ignore_externals: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RepositoryCheckoutRevision {
    Head,
    Number(i64),
}

impl Serialize for RepositoryCheckoutRevision {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match self {
            Self::Head => serializer.serialize_str("head"),
            Self::Number(revision) => serializer.serialize_i64(*revision),
        }
    }
}

impl<'de> Deserialize<'de> for RepositoryCheckoutRevision {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        deserializer.deserialize_any(RepositoryCheckoutRevisionVisitor)
    }
}

struct RepositoryCheckoutRevisionVisitor;

impl<'de> Visitor<'de> for RepositoryCheckoutRevisionVisitor {
    type Value = RepositoryCheckoutRevision;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(r#""head" or a non-negative SVN revision number"#)
    }

    fn visit_str<E>(self, value: &str) -> Result<Self::Value, E>
    where
        E: de::Error,
    {
        if value == "head" {
            return Ok(RepositoryCheckoutRevision::Head);
        }
        Err(E::custom("checkout revision must be \"head\" or a number"))
    }

    fn visit_i64<E>(self, value: i64) -> Result<Self::Value, E>
    where
        E: de::Error,
    {
        if value >= 0 {
            return Ok(RepositoryCheckoutRevision::Number(value));
        }
        Err(E::custom("checkout revision must be non-negative"))
    }

    fn visit_u64<E>(self, value: u64) -> Result<Self::Value, E>
    where
        E: de::Error,
    {
        let revision =
            i64::try_from(value).map_err(|_| E::custom("checkout revision is too large"))?;
        Ok(RepositoryCheckoutRevision::Number(revision))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RepositoryCheckoutResponse {
    pub working_copy_path: String,
    pub revision: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RepositoryCloseResponse {
    pub repository_id: String,
    pub epoch: u64,
    pub closed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RepositoryDiscoveryCandidate {
    pub identity: RepositoryIdentity,
    pub is_nested: bool,
    pub is_external: bool,
    pub parent_working_copy_root: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RepositoryDiscoverResponse {
    pub candidates: Vec<RepositoryDiscoveryCandidate>,
    pub file_external_boundaries: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LockInfo {
    pub token: Option<String>,
    pub owner: Option<String>,
    pub comment: Option<String>,
    pub created_date: Option<String>,
    pub expires_date: Option<String>,
    pub is_remote: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusEntry {
    pub path: String,
    pub kind: String,
    pub node_status: String,
    pub text_status: String,
    pub property_status: String,
    pub local_status: String,
    pub remote_status: String,
    pub revision: i64,
    pub changed_revision: i64,
    pub changed_author: Option<String>,
    pub changed_date: Option<String>,
    pub changelist: Option<String>,
    pub lock: Option<LockInfo>,
    pub needs_lock: bool,
    pub copy: Option<String>,
    #[serde(rename = "move")]
    pub move_: Option<String>,
    pub switched: bool,
    pub depth: String,
    pub conflict: Option<String>,
    pub conflict_artifacts: Vec<String>,
    pub external: bool,
    pub generation: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusSummary {
    pub local_changes: u32,
    pub remote_changes: u32,
    pub conflicts: u32,
    pub unversioned: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusSummaryDelta {
    pub local_changes: i32,
    pub remote_changes: i32,
    pub conflicts: i32,
    pub unversioned: i32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusSnapshot {
    pub repository_id: String,
    pub epoch: u64,
    pub generation: u64,
    pub completeness: String,
    pub identity: RepositoryIdentity,
    pub local_entries: Vec<StatusEntry>,
    pub remote_entries: Vec<StatusEntry>,
    pub summary: StatusSummary,
    pub timestamp: String,
    pub source: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusRefreshTarget {
    pub path: String,
    pub depth: String,
    pub reason: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusCoverageScope {
    pub path: String,
    pub depth: String,
    pub generation: u64,
    pub reason: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusDelta {
    pub repository_id: String,
    pub epoch: u64,
    pub generation: u64,
    pub coverage: Vec<StatusCoverageScope>,
    pub upsert: Vec<StatusEntry>,
    pub remove: Vec<String>,
    pub remote_upsert: Vec<StatusEntry>,
    pub remote_remove: Vec<String>,
    pub summary_delta: StatusSummaryDelta,
    pub completeness: String,
    pub timestamp: String,
    pub source: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContentGetResponse {
    pub repository_id: String,
    pub epoch: u64,
    pub path: String,
    pub revision: String,
    pub content_base64: String,
    pub byte_length: u64,
    pub mime_type: Option<String>,
    pub is_binary: bool,
    pub source: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryLogChangedPath {
    pub path: String,
    pub action: String,
    pub copy_from_path: Option<String>,
    pub copy_from_revision: Option<i64>,
    pub node_kind: String,
    pub text_modified: String,
    pub properties_modified: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryLogEntry {
    pub revision: i64,
    pub author: Option<String>,
    pub date: Option<String>,
    pub message: Option<String>,
    pub changed_paths: Vec<HistoryLogChangedPath>,
    pub has_children: bool,
    pub non_inheritable: bool,
    pub subtractive_merge: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryLogResponse {
    pub repository_id: String,
    pub epoch: u64,
    pub path: String,
    pub start_revision: String,
    pub end_revision: String,
    pub limit: u32,
    pub entries: Vec<HistoryLogEntry>,
    pub source: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryBlameLine {
    pub line_number: u64,
    pub revision: Option<i64>,
    pub author: Option<String>,
    pub date: Option<String>,
    pub merged_revision: Option<i64>,
    pub merged_author: Option<String>,
    pub merged_date: Option<String>,
    pub merged_path: Option<String>,
    pub line_base64: String,
    pub byte_length: u64,
    pub local_change: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryBlameResponse {
    pub repository_id: String,
    pub epoch: u64,
    pub path: String,
    pub peg_revision: String,
    pub start_revision: String,
    pub end_revision: String,
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OperationWarning {
    pub code: String,
    pub message_key: String,
    pub args: serde_json::Value,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OperationSummary {
    pub affected_paths: u32,
    pub skipped_paths: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OperationReconcileHint {
    pub targets: Vec<StatusRefreshTarget>,
    pub requires_full_reconcile: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OperationRunResponse {
    pub repository_id: String,
    pub epoch: u64,
    pub operation_id: String,
    pub kind: String,
    pub touched_paths: Vec<String>,
    pub revision: Option<i64>,
    pub summary: OperationSummary,
    pub warnings: Vec<OperationWarning>,
    pub reconcile: OperationReconcileHint,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PropertyEntry {
    pub name: String,
    pub value: String,
    pub value_encoding: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PropertiesListResponse {
    pub repository_id: String,
    pub epoch: u64,
    pub path: String,
    pub properties: Vec<PropertyEntry>,
    pub source: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiagnosticsRepositorySummary {
    pub open_repositories: u32,
    pub cached_local_entries: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiagnosticsBackendStderr {
    pub truncated: bool,
    pub text: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SvnErrorDiagnosticEntry {
    pub code: i32,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SvnErrorDiagnostics {
    pub entries: Vec<SvnErrorDiagnosticEntry>,
    pub truncated: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OperationFailureCause {
    OutOfDate,
    ConflictPresent,
    AuthenticationFailed,
    NotWorkingCopy,
    UnknownNative,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OperationFailureDiagnostics {
    pub cause: OperationFailureCause,
    pub svn: SvnErrorDiagnostics,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiagnosticsGetResponse {
    pub backend_version: String,
    pub bridge_version: String,
    pub libsvn_version: String,
    pub protocol: ProtocolVersion,
    pub platform: PlatformDescriptor,
    pub cache_schema: CacheSchema,
    pub capabilities: Capabilities,
    pub repository_summary: DiagnosticsRepositorySummary,
    pub backend_stderr: DiagnosticsBackendStderr,
    pub generated_at: String,
    pub source: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CredentialAuthKind {
    Basic,
    CramMd5,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum CredentialAttempt {
    Initial,
    RetryAfterRejected { previous_lease_id: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CredentialPersistenceIntent {
    SecretStorage,
    Session,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CredentialSettlementOutcome {
    Accepted,
    Rejected,
    Unused,
    Cancelled,
    TimedOut,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct CredentialRequest {
    pub request_id: String,
    pub operation_id: String,
    pub endpoint: CanonicalEndpoint,
    pub auth_kind: CredentialAuthKind,
    pub realm: String,
    pub account: ServerAccountSelection,
    pub attempt: CredentialAttempt,
    pub interactive: bool,
    pub persistence_allowed: bool,
    pub origin: RemoteOperationIntent,
    pub timeout_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Credential {
    pub username: String,
    pub secret: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct CredentialError {
    pub code: String,
    pub category: String,
    pub message_key: String,
    pub args: serde_json::Value,
    pub retryable: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "camelCase", deny_unknown_fields)]
pub enum CredentialResponse {
    #[serde(rename_all = "camelCase")]
    Provide {
        request_id: String,
        operation_id: String,
        lease_id: String,
        credential: Credential,
        persistence_intent: CredentialPersistenceIntent,
    },
    #[serde(rename_all = "camelCase")]
    Cancel {
        request_id: String,
        operation_id: String,
        error: CredentialError,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct CredentialSettlementRequest {
    pub request_id: String,
    pub operation_id: String,
    pub lease_id: String,
    pub outcome: CredentialSettlementOutcome,
    pub timeout_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct CredentialSettlementAck {
    pub request_id: String,
    pub operation_id: String,
    pub lease_id: String,
    pub outcome: CredentialSettlementOutcome,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CertificateTrustRequest {
    pub request_id: String,
    pub realm: String,
    pub host: String,
    pub fingerprint: String,
    pub fingerprint_algorithm: String,
    pub failures: Vec<String>,
    pub valid_from: String,
    pub valid_to: String,
    pub issuer: Option<String>,
    pub subject: Option<String>,
    pub interactive: bool,
    pub persistence_allowed: bool,
    pub origin: String,
    pub timeout_ms: u64,
    pub repository_id: Option<String>,
    pub working_copy_root: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CertificateTrustError {
    pub code: String,
    pub category: String,
    pub message_key: String,
    pub args: serde_json::Value,
    pub retryable: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "camelCase")]
pub enum CertificateTrustResponse {
    #[serde(rename_all = "camelCase")]
    Trust {
        request_id: String,
        trust: String,
        fingerprint: String,
        fingerprint_algorithm: String,
    },
    #[serde(rename_all = "camelCase")]
    Reject {
        request_id: String,
        error: CertificateTrustError,
    },
}

impl InitializeResponse {
    pub fn new(
        backend_version: String,
        bridge_version: String,
        libsvn_version: String,
        platform: PlatformDescriptor,
        capabilities: Capabilities,
        acknowledged_trust_epoch: u64,
    ) -> Self {
        Self {
            protocol: ProtocolVersion {
                major: 1,
                minor: 33,
            },
            backend_version,
            bridge_version,
            libsvn_version,
            platform,
            cache_schema: default_cache_schema(),
            capabilities,
            acknowledged_trust_epoch,
        }
    }
}

pub fn default_cache_schema() -> CacheSchema {
    CacheSchema {
        schema_id: "subversionr.cache.v1".to_string(),
        version: 1,
        rollback: "delete-and-reconcile".to_string(),
    }
}

pub fn default_capabilities() -> Capabilities {
    Capabilities {
        content_length_framing: true,
        real_libsvn_bridge: false,
        repository_discover: true,
        repository_open: true,
        repository_checkout: true,
        repository_close: true,
        status_snapshot: true,
        status_refresh: true,
        status_remote_check: true,
        status_stale_notification: true,
        content_get: true,
        content_get_revision: true,
        history_log: true,
        history_blame: true,
        operation_run: true,
        operation_run_add: true,
        operation_run_remove: true,
        operation_run_move: true,
        operation_run_cleanup: true,
        operation_run_resolve: true,
        operation_run_update: true,
        operation_run_update_selected_path: true,
        operation_run_update_to_revision: true,
        operation_run_update_depth: true,
        operation_run_update_externals_policy: true,
        properties_list: true,
        operation_run_property_set: true,
        operation_run_property_delete: true,
        ignore: true,
        operation_run_changelist_set: true,
        operation_run_changelist_clear: true,
        operation_run_lock: true,
        operation_run_unlock: true,
        operation_run_branch_create: true,
        operation_run_switch: true,
        operation_run_relocate: true,
        operation_run_commit: true,
        operation_run_commit_multi_path: true,
        diagnostics_get: true,
        credential_request: true,
        certificate_request: true,
        remote_operation_envelope: true,
        trusted_config_snapshot: true,
        remote_worker_isolation: false,
        credential_lease_settlement: false,
    }
}

pub fn current_platform() -> PlatformDescriptor {
    PlatformDescriptor {
        os: std::env::consts::OS.to_string(),
        arch: std::env::consts::ARCH.to_string(),
    }
}

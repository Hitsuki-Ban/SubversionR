use std::collections::BTreeSet;
use std::ffi::{CStr, CString, c_char, c_int, c_uchar, c_void};
use std::fmt;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::ptr::{self, NonNull};
use std::slice;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use base64::{Engine as _, engine::general_purpose::STANDARD};
use libloading::Library;
use serde_json::json;
use sha2::{Digest, Sha256};
use subversionr_protocol::{
    CertificateTrustRequest, CertificateTrustResponse, CredentialAttempt, CredentialAuthKind,
    CredentialPersistenceIntent, CredentialRequest, CredentialResponse, CredentialSettlementAck,
    CredentialSettlementOutcome, CredentialSettlementRequest, HistoryBlameLine,
    HistoryLogChangedPath, HistoryLogEntry, LockInfo, OperationFailureCause,
    OperationFailureDiagnostics, RemoteInteraction, RemoteOperationEnvelope, RemoteServerAuth,
    RepositoryIdentity, ServerAccountSelection, ServerAccountSnapshot, StatusEntry, StatusSnapshot,
    StatusSummary, SvnErrorDiagnosticEntry, SvnErrorDiagnostics,
};

use crate::{
    AddOperationRequest, AuthRequestBroker, BranchCreateOperationRequest,
    BranchCreateOperationResult, BridgeApi, BridgeCancellationToken, BridgeFailure, BridgeInfo,
    ChangelistClearOperationRequest, ChangelistSetOperationRequest, CleanupOperationRequest,
    CommitOperationRequest, CommitOperationResult, ContentBlob, HistoryBlameRequest,
    HistoryBlameResult, HistoryLogRequest, HistoryLogResult, LockOperationRequest,
    MergeOperationRequest, MoveOperationRequest, NeverCancelled, OperationResult,
    PropertiesListResult, PropertyDeleteOperationRequest, PropertyEntry,
    PropertySetOperationRequest, RelocateOperationRequest, RemoteConfigPlan, RemoteConfigScheme,
    RemoteConfigServerAuth, RemoveOperationRequest, RepositoryCheckoutRequest,
    RepositoryCheckoutResult, ResolveOperationRequest, RevertOperationRequest,
    SwitchOperationRequest, SwitchOperationResult, UnlockOperationRequest, UpdateOperationRequest,
    UpdateOperationResult, UpgradeOperationRequest, current_timestamp,
};

const BRIDGE_RUNTIME_VERSION: &str = concat!("subversionr-svn-bridge/", env!("CARGO_PKG_VERSION"));
const MAX_SVN_REVNUM: u64 = 2_147_483_647;
const RAW_AUTH_ABI_VERSION: u32 = 1;
const RAW_REMOTE_CREDENTIAL_ABI_VERSION: u32 = 2;
const RAW_AUTH_CALLBACK_OK: c_int = 0;
const RAW_AUTH_CALLBACK_DENIED: c_int = 1;
const RAW_AUTH_CALLBACK_INVALID: c_int = 2;
const RAW_CANCEL_ABI_VERSION: u32 = 1;
const RAW_CANCEL_CALLBACK_CONTINUE: c_int = 0;
const RAW_CANCEL_CALLBACK_CANCEL: c_int = 1;
const RAW_CANCEL_CALLBACK_INVALID: c_int = 2;
const RAW_STATUS_CALLBACK_FAILED: c_int = 10;
const RAW_STATUS_CANCELLED: c_int = 11;
const RAW_OPERATION_CANCEL_CALLBACK_FAILED: c_int = 11;
const RAW_OPERATION_CANCELLED: c_int = 12;
const RAW_OPERATION_LOCAL_COMMIT_AUTHOR_UNAVAILABLE: c_int = 13;
const RAW_OPERATION_PARTIAL_FAILURE: c_int = 14;
const RAW_OPERATION_PARTIAL_CANCEL_CALLBACK_FAILED: c_int = 15;
const RAW_OPERATION_PARTIAL_CANCELLED: c_int = 16;
const RAW_REMOTE_CONFIG_ABI_VERSION: u32 = 1;
const RAW_REMOTE_CATEGORY_MASK: u32 = 0b11;
const RAW_REMOTE_OPTION_MASK: u32 = 0b11_1111;
const NATIVE_AUTH_REQUEST_TIMEOUT_MS: u64 = 120_000;
const RAW_CERT_FAILURE_NOT_YET_VALID: u32 = 0x0000_0001;
const RAW_CERT_FAILURE_EXPIRED: u32 = 0x0000_0002;
const RAW_CERT_FAILURE_CN_MISMATCH: u32 = 0x0000_0004;
const RAW_CERT_FAILURE_UNKNOWN_CA: u32 = 0x0000_0008;
const RAW_CERT_FAILURE_OTHER: u32 = 0x4000_0000;
static NEXT_NATIVE_AUTH_REQUEST_ID: AtomicU64 = AtomicU64::new(1);

#[repr(C)]
struct RawVersionInfo {
    major: c_int,
    minor: c_int,
    patch: c_int,
    display: *const c_char,
}

#[repr(C)]
struct RawErrorEntry {
    code: c_int,
    name: *const c_char,
}

#[repr(C)]
struct RawErrorDiagnostics {
    entries: *const RawErrorEntry,
    entry_count: usize,
    truncated: c_int,
}

#[repr(C)]
struct RawWorkingCopyInfo {
    repository_uuid: *const c_char,
    repository_root_url: *const c_char,
    working_copy_root: *const c_char,
    format: c_int,
}

#[repr(C)]
struct RawCredentialRequest {
    realm: *const c_char,
    username: *const c_char,
    may_save: c_int,
    working_copy_root: *const c_char,
}

#[repr(C)]
struct RawCredentialResponse {
    username: *const c_char,
    secret: *const c_char,
    may_save: c_int,
}

#[repr(C)]
struct RawRemoteCredentialRequestV2 {
    realm: *const c_char,
    suggested_username: *const c_char,
    working_copy_root: *const c_char,
    attempt: u32,
    previous_lease_id: *const c_char,
}

#[repr(C)]
struct RawRemoteCredentialResponseV2 {
    username: *const c_char,
    secret: *const c_char,
    lease_id: *const c_char,
    persistence_requested: c_int,
}

#[repr(C)]
struct RawPrivateCredentialProbeRequest {
    abi_version: u32,
    scenario: u32,
    realm: *const c_char,
    suggested_username: *const c_char,
    terminal_outcome: u32,
}

const RAW_CREDENTIAL_PROBE_EVENT_LIMIT: usize = 8;

#[repr(C)]
#[derive(Debug, Default)]
struct RawPrivateCredentialProbeInspection {
    abi_version: u32,
    scenario: u32,
    terminal_outcome: u32,
    event_count: u32,
    events: [u32; RAW_CREDENTIAL_PROBE_EVENT_LIMIT],
}

#[repr(C)]
struct RawCertificateRequest {
    realm: *const c_char,
    host: *const c_char,
    ascii_cert: *const c_char,
    valid_from: *const c_char,
    valid_to: *const c_char,
    issuer: *const c_char,
    subject: *const c_char,
    failures: u32,
    may_save: c_int,
    working_copy_root: *const c_char,
}

#[repr(C)]
struct RawCertificateResponse {
    accepted_failures: u32,
    may_save: c_int,
}

type RawCredentialCallback = unsafe extern "C" fn(
    *mut c_void,
    *const RawCredentialRequest,
    *mut RawCredentialResponse,
) -> c_int;
type RawCredentialResponseDispose = unsafe extern "C" fn(*mut c_void, *mut RawCredentialResponse);
type RawRemoteCredentialCallbackV2 = unsafe extern "C" fn(
    *mut c_void,
    *const RawRemoteCredentialRequestV2,
    *mut RawRemoteCredentialResponseV2,
) -> c_int;
type RawRemoteCredentialResponseDisposeV2 =
    unsafe extern "C" fn(*mut c_void, *mut RawRemoteCredentialResponseV2);
type RawRemoteCredentialSettlementCallbackV2 =
    unsafe extern "C" fn(*mut c_void, *const c_char, u32) -> c_int;
type RawCertificateCallback = unsafe extern "C" fn(
    *mut c_void,
    *const RawCertificateRequest,
    *mut RawCertificateResponse,
) -> c_int;

#[repr(C)]
struct RawAuthCallbacks {
    abi_version: u32,
    baton: *mut c_void,
    credential_callback: Option<RawCredentialCallback>,
    credential_response_dispose: Option<RawCredentialResponseDispose>,
    certificate_callback: Option<RawCertificateCallback>,
}

#[repr(C)]
struct RawRemoteCredentialCallbacksV2 {
    abi_version: u32,
    baton: *mut c_void,
    credential_callback: Option<RawRemoteCredentialCallbackV2>,
    credential_response_dispose: Option<RawRemoteCredentialResponseDisposeV2>,
    credential_settlement_callback: Option<RawRemoteCredentialSettlementCallbackV2>,
}

type RawCancelCallback = unsafe extern "C" fn(*mut c_void) -> c_int;

#[repr(C)]
struct RawCancelCallbacks {
    abi_version: u32,
    baton: *mut c_void,
    cancel_callback: Option<RawCancelCallback>,
}

#[repr(C)]
struct RawLockInfo {
    token: *const c_char,
    owner: *const c_char,
    comment: *const c_char,
    created_date: *const c_char,
    expires_date: *const c_char,
    is_remote: c_int,
}

#[repr(C)]
struct RawStatusEntry {
    path: *const c_char,
    kind: *const c_char,
    node_status: *const c_char,
    text_status: *const c_char,
    property_status: *const c_char,
    repos_node_status: *const c_char,
    repos_text_status: *const c_char,
    repos_property_status: *const c_char,
    repos_kind: *const c_char,
    repos_changed_revision: i64,
    repos_changed_author: *const c_char,
    repos_changed_date: *const c_char,
    revision: i64,
    changed_revision: i64,
    changed_author: *const c_char,
    changed_date: *const c_char,
    changelist: *const c_char,
    lock: *const RawLockInfo,
    repos_lock: *const RawLockInfo,
    needs_lock: c_int,
    depth: *const c_char,
    conflicted: c_int,
    switched: c_int,
    external: c_int,
    copied: c_int,
    copy_from_path: *const c_char,
    copy_from_revision: i64,
    moved_from_abspath: *const c_char,
    conflict_artifact_paths: [*const c_char; 4],
    conflict_artifact_count: usize,
}

#[repr(C)]
struct RawStatusSnapshot {
    entries: *const RawStatusEntry,
    entry_count: usize,
}

#[repr(C)]
struct RawContent {
    data: *const c_uchar,
    byte_count: usize,
    mime_type: *const c_char,
    is_binary: c_int,
}

#[repr(C)]
struct RawPropertyEntry {
    name: *const c_char,
    value: *const c_char,
    value_encoding: *const c_char,
}

#[repr(C)]
struct RawPropertyList {
    entries: *const RawPropertyEntry,
    entry_count: usize,
}

#[repr(C)]
struct RawHistoryLogChangedPath {
    path: *const c_char,
    action: *const c_char,
    copy_from_path: *const c_char,
    copy_from_revision: i64,
    node_kind: *const c_char,
    text_modified: *const c_char,
    properties_modified: *const c_char,
}

#[repr(C)]
struct RawHistoryLogEntry {
    revision: i64,
    author: *const c_char,
    date: *const c_char,
    message: *const c_char,
    changed_paths: *const RawHistoryLogChangedPath,
    changed_path_count: usize,
    has_children: c_int,
    non_inheritable: c_int,
    subtractive_merge: c_int,
}

#[repr(C)]
struct RawHistoryLog {
    entries: *const RawHistoryLogEntry,
    entry_count: usize,
}

#[repr(C)]
struct RawHistoryBlameLine {
    line_number: i64,
    revision: i64,
    author: *const c_char,
    date: *const c_char,
    merged_revision: i64,
    merged_author: *const c_char,
    merged_date: *const c_char,
    merged_path: *const c_char,
    line_data: *const c_uchar,
    line_byte_count: usize,
    local_change: c_int,
}

#[repr(C)]
struct RawHistoryBlame {
    resolved_start_revision: i64,
    resolved_end_revision: i64,
    lines: *const RawHistoryBlameLine,
    line_count: usize,
    has_more: c_int,
}

#[repr(C)]
struct RawOperationResult {
    touched_paths: *const *const c_char,
    touched_path_count: usize,
    skipped_paths: *const *const c_char,
    skipped_path_count: usize,
}

#[repr(C)]
struct RawRemoteConfigV1 {
    abi_version: u32,
    scheme: u32,
    server_auth: u32,
    timeout_ms: u64,
    trust_windows_roots: c_int,
}

#[repr(C)]
#[derive(Default)]
struct RawRemoteConfigInspection {
    abi_version: u32,
    category_mask: u32,
    option_mask: u32,
    provider_mask: u32,
    forbidden_input_mask: u32,
}

type RuntimeCreate = unsafe extern "C" fn(*mut *mut c_void) -> c_int;
type RuntimeDestroy = unsafe extern "C" fn(*mut c_void);
type RemoteContextCreate = unsafe extern "C" fn(
    *const RawRemoteConfigV1,
    *const RawRemoteCredentialCallbacksV2,
    *mut *mut c_void,
) -> c_int;
type RemoteContextInspect =
    unsafe extern "C" fn(*const c_void, *mut RawRemoteConfigInspection) -> c_int;
type RemoteContextDestroy = unsafe extern "C" fn(*mut c_void);
type RemoteContextFinishCredentials = unsafe extern "C" fn(*mut c_void, u32) -> c_int;
type PrivateRemoteCredentialProviderProbe = unsafe extern "C" fn(
    *const RawRemoteCredentialCallbacksV2,
    *const RawPrivateCredentialProbeRequest,
    *mut RawPrivateCredentialProbeInspection,
) -> c_int;
type Version = unsafe extern "C" fn() -> RawVersionInfo;
type OpenWorkingCopy =
    unsafe extern "C" fn(*mut c_void, *const c_char, *mut RawWorkingCopyInfo) -> c_int;
type OpenWorkingCopyWithAuth = unsafe extern "C" fn(
    *mut c_void,
    *const c_char,
    *const RawAuthCallbacks,
    *mut RawWorkingCopyInfo,
) -> c_int;
type ProbeRemoteUrlWithAuth =
    unsafe extern "C" fn(*mut c_void, *const c_char, *const RawAuthCallbacks) -> c_int;
type StatusSnapshotFn = unsafe extern "C" fn(
    *mut c_void,
    *const c_char,
    *const c_char,
    *const RawCancelCallbacks,
    *mut RawStatusSnapshot,
) -> c_int;
type StatusRemoteScanFn = unsafe extern "C" fn(
    *mut c_void,
    *const c_char,
    *const RawAuthCallbacks,
    *const RawCancelCallbacks,
    *mut RawStatusSnapshot,
) -> c_int;
type ContentGetFn = unsafe extern "C" fn(
    *mut c_void,
    *const c_char,
    *const c_char,
    *const RawAuthCallbacks,
    *mut RawContent,
) -> c_int;
type PropertiesListFn =
    unsafe extern "C" fn(*mut c_void, *const c_char, *mut RawPropertyList) -> c_int;
type HistoryLogFn = unsafe extern "C" fn(
    *mut c_void,
    *const c_char,
    *const c_char,
    *const c_char,
    c_int,
    c_int,
    c_int,
    c_int,
    *const RawAuthCallbacks,
    *mut RawHistoryLog,
) -> c_int;
type HistoryBlameFn = unsafe extern "C" fn(
    *mut c_void,
    *const c_char,
    *const c_char,
    *const c_char,
    *const c_char,
    *const c_char,
    c_int,
    c_int,
    c_int,
    i64,
    c_int,
    *const RawAuthCallbacks,
    *mut RawHistoryBlame,
) -> c_int;
type OperationRevertFn = unsafe extern "C" fn(
    *mut c_void,
    *const *const c_char,
    usize,
    *const c_char,
    *const *const c_char,
    usize,
    c_int,
    c_int,
    c_int,
    *const RawCancelCallbacks,
    *mut RawOperationResult,
) -> c_int;
type OperationAddFn = unsafe extern "C" fn(
    *mut c_void,
    *const *const c_char,
    usize,
    *const c_char,
    c_int,
    c_int,
    c_int,
    c_int,
    *const RawCancelCallbacks,
    *mut RawOperationResult,
) -> c_int;
type OperationRemoveFn = unsafe extern "C" fn(
    *mut c_void,
    *const *const c_char,
    usize,
    c_int,
    c_int,
    *const RawCancelCallbacks,
    *mut RawOperationResult,
) -> c_int;
type OperationMoveFn = unsafe extern "C" fn(
    *mut c_void,
    *const c_char,
    *const c_char,
    c_int,
    *const RawCancelCallbacks,
    *mut RawOperationResult,
) -> c_int;
type OperationResolveFn = unsafe extern "C" fn(
    *mut c_void,
    *const *const c_char,
    usize,
    *const c_char,
    *const c_char,
    *const RawCancelCallbacks,
    *mut RawOperationResult,
) -> c_int;
type OperationCleanupFn = unsafe extern "C" fn(
    *mut c_void,
    *const c_char,
    c_int,
    c_int,
    c_int,
    c_int,
    c_int,
    *const RawCancelCallbacks,
    *mut RawOperationResult,
) -> c_int;
type OperationUpgradeFn = unsafe extern "C" fn(
    *mut c_void,
    *const c_char,
    *const RawCancelCallbacks,
    *mut RawOperationResult,
) -> c_int;
type OperationUpdateFn = unsafe extern "C" fn(
    *mut c_void,
    *const c_char,
    *const c_char,
    *const c_char,
    c_int,
    c_int,
    *const RawAuthCallbacks,
    *const RawCancelCallbacks,
    *mut RawOperationResult,
    *mut i64,
) -> c_int;
type RepositoryCheckoutFn = unsafe extern "C" fn(
    *mut c_void,
    *const c_char,
    *const c_char,
    *const c_char,
    *const c_char,
    c_int,
    *const RawAuthCallbacks,
    *const RawCancelCallbacks,
    *mut i64,
) -> c_int;
type OperationPropertySetFn = unsafe extern "C" fn(
    *mut c_void,
    *const c_char,
    *const c_char,
    *const c_char,
    *const RawCancelCallbacks,
    *mut RawOperationResult,
) -> c_int;
type OperationPropertyDeleteFn = unsafe extern "C" fn(
    *mut c_void,
    *const c_char,
    *const c_char,
    *const RawCancelCallbacks,
    *mut RawOperationResult,
) -> c_int;
type OperationChangelistSetFn = unsafe extern "C" fn(
    *mut c_void,
    *const *const c_char,
    usize,
    *const c_char,
    *const c_char,
    *const *const c_char,
    usize,
    *const RawCancelCallbacks,
    *mut RawOperationResult,
) -> c_int;
type OperationChangelistClearFn = unsafe extern "C" fn(
    *mut c_void,
    *const *const c_char,
    usize,
    *const c_char,
    *const *const c_char,
    usize,
    *const RawCancelCallbacks,
    *mut RawOperationResult,
) -> c_int;
type OperationLockFn = unsafe extern "C" fn(
    *mut c_void,
    *const *const c_char,
    usize,
    *const c_char,
    c_int,
    *const RawAuthCallbacks,
    *const RawCancelCallbacks,
    *mut RawOperationResult,
) -> c_int;
type OperationUnlockFn = unsafe extern "C" fn(
    *mut c_void,
    *const *const c_char,
    usize,
    c_int,
    *const RawAuthCallbacks,
    *const RawCancelCallbacks,
    *mut RawOperationResult,
) -> c_int;
type OperationBranchCreateFn = unsafe extern "C" fn(
    *mut c_void,
    *const c_char,
    *const c_char,
    *const c_char,
    *const c_char,
    *const c_char,
    c_int,
    c_int,
    *const RawAuthCallbacks,
    *const RawCancelCallbacks,
    *mut RawOperationResult,
    *mut i64,
) -> c_int;
type OperationSwitchFn = unsafe extern "C" fn(
    *mut c_void,
    *const c_char,
    *const c_char,
    *const c_char,
    *const c_char,
    c_int,
    c_int,
    c_int,
    *const RawAuthCallbacks,
    *const RawCancelCallbacks,
    *mut RawOperationResult,
    *mut i64,
) -> c_int;
type OperationRelocateFn = unsafe extern "C" fn(
    *mut c_void,
    *const c_char,
    *const c_char,
    *const c_char,
    c_int,
    *const RawAuthCallbacks,
    *const RawCancelCallbacks,
    *mut RawOperationResult,
) -> c_int;
type OperationMergeRangeFn = unsafe extern "C" fn(
    *mut c_void,
    *const c_char,
    *const c_char,
    i64,
    i64,
    *const c_char,
    c_int,
    c_int,
    c_int,
    c_int,
    c_int,
    c_int,
    *const RawAuthCallbacks,
    *const RawCancelCallbacks,
    *mut RawOperationResult,
) -> c_int;
type OperationCommitFn = unsafe extern "C" fn(
    *mut c_void,
    *const *const c_char,
    usize,
    *const c_char,
    *const c_char,
    *const *const c_char,
    usize,
    c_int,
    c_int,
    c_int,
    c_int,
    c_int,
    *const RawAuthCallbacks,
    *const RawCancelCallbacks,
    *mut RawOperationResult,
    *mut i64,
) -> c_int;
type LastErrorDiagnosticsFn = unsafe extern "C" fn(*mut c_void, *mut RawErrorDiagnostics) -> c_int;

#[derive(Clone, Copy)]
struct NativeSymbols {
    runtime_create: RuntimeCreate,
    runtime_destroy: RuntimeDestroy,
    remote_context_create: RemoteContextCreate,
    remote_context_inspect: RemoteContextInspect,
    remote_context_destroy: RemoteContextDestroy,
    version: Version,
    last_error_diagnostics: LastErrorDiagnosticsFn,
    open_working_copy: OpenWorkingCopy,
    open_working_copy_with_auth: OpenWorkingCopyWithAuth,
    probe_remote_url_with_auth: ProbeRemoteUrlWithAuth,
    status_snapshot: StatusSnapshotFn,
    status_remote_scan: StatusRemoteScanFn,
    content_get: ContentGetFn,
    properties_list: PropertiesListFn,
    history_log: HistoryLogFn,
    history_blame: HistoryBlameFn,
    operation_revert: OperationRevertFn,
    operation_add: OperationAddFn,
    operation_remove: OperationRemoveFn,
    operation_move: OperationMoveFn,
    operation_resolve: OperationResolveFn,
    operation_cleanup: OperationCleanupFn,
    operation_upgrade: OperationUpgradeFn,
    operation_update: OperationUpdateFn,
    repository_checkout: RepositoryCheckoutFn,
    operation_property_set: OperationPropertySetFn,
    operation_property_delete: OperationPropertyDeleteFn,
    operation_changelist_set: OperationChangelistSetFn,
    operation_changelist_clear: OperationChangelistClearFn,
    operation_lock: OperationLockFn,
    operation_unlock: OperationUnlockFn,
    operation_branch_create: OperationBranchCreateFn,
    operation_switch: OperationSwitchFn,
    operation_relocate: OperationRelocateFn,
    operation_merge_range: OperationMergeRangeFn,
    operation_commit: OperationCommitFn,
}

impl NativeSymbols {
    unsafe fn load(library: &Library) -> Result<Self, libloading::Error> {
        Ok(Self {
            runtime_create: *unsafe { library.get(b"subversionr_bridge_runtime_create\0") }?,
            runtime_destroy: *unsafe { library.get(b"subversionr_bridge_runtime_destroy\0") }?,
            remote_context_create: *unsafe {
                library.get(b"subversionr_bridge_remote_context_create\0")
            }?,
            remote_context_inspect: *unsafe {
                library.get(b"subversionr_bridge_remote_context_inspect\0")
            }?,
            remote_context_destroy: *unsafe {
                library.get(b"subversionr_bridge_remote_context_destroy\0")
            }?,
            version: *unsafe { library.get(b"subversionr_bridge_version\0") }?,
            last_error_diagnostics: *unsafe {
                library.get(b"subversionr_bridge_last_error_diagnostics\0")
            }?,
            open_working_copy: *unsafe { library.get(b"subversionr_bridge_open_working_copy\0") }?,
            open_working_copy_with_auth: *unsafe {
                library.get(b"subversionr_bridge_open_working_copy_with_auth\0")
            }?,
            probe_remote_url_with_auth: *unsafe {
                library.get(b"subversionr_bridge_probe_remote_url_with_auth\0")
            }?,
            status_snapshot: *unsafe { library.get(b"subversionr_bridge_status_scan\0") }?,
            status_remote_scan: *unsafe {
                library.get(b"subversionr_bridge_status_remote_scan_with_auth\0")
            }?,
            content_get: *unsafe { library.get(b"subversionr_bridge_content_get_with_auth\0") }?,
            properties_list: *unsafe { library.get(b"subversionr_bridge_properties_list\0") }?,
            history_log: *unsafe { library.get(b"subversionr_bridge_history_log_with_auth\0") }?,
            history_blame: *unsafe {
                library.get(b"subversionr_bridge_history_blame_with_auth\0")
            }?,
            operation_revert: *unsafe { library.get(b"subversionr_bridge_operation_revert\0") }?,
            operation_add: *unsafe { library.get(b"subversionr_bridge_operation_add\0") }?,
            operation_remove: *unsafe { library.get(b"subversionr_bridge_operation_remove\0") }?,
            operation_move: *unsafe { library.get(b"subversionr_bridge_operation_move\0") }?,
            operation_resolve: *unsafe { library.get(b"subversionr_bridge_operation_resolve\0") }?,
            operation_cleanup: *unsafe { library.get(b"subversionr_bridge_operation_cleanup\0") }?,
            operation_upgrade: *unsafe { library.get(b"subversionr_bridge_operation_upgrade\0") }?,
            operation_update: *unsafe { library.get(b"subversionr_bridge_operation_update\0") }?,
            repository_checkout: *unsafe {
                library.get(b"subversionr_bridge_repository_checkout_with_auth\0")
            }?,
            operation_property_set: *unsafe {
                library.get(b"subversionr_bridge_operation_property_set\0")
            }?,
            operation_property_delete: *unsafe {
                library.get(b"subversionr_bridge_operation_property_delete\0")
            }?,
            operation_changelist_set: *unsafe {
                library.get(b"subversionr_bridge_operation_changelist_set\0")
            }?,
            operation_changelist_clear: *unsafe {
                library.get(b"subversionr_bridge_operation_changelist_clear\0")
            }?,
            operation_lock: *unsafe {
                library.get(b"subversionr_bridge_operation_lock_with_auth\0")
            }?,
            operation_unlock: *unsafe {
                library.get(b"subversionr_bridge_operation_unlock_with_auth\0")
            }?,
            operation_branch_create: *unsafe {
                library.get(b"subversionr_bridge_operation_branch_create_with_auth\0")
            }?,
            operation_switch: *unsafe {
                library.get(b"subversionr_bridge_operation_switch_with_auth\0")
            }?,
            operation_relocate: *unsafe {
                library.get(b"subversionr_bridge_operation_relocate_with_auth\0")
            }?,
            operation_merge_range: *unsafe {
                library.get(b"subversionr_bridge_operation_merge_range_with_auth\0")
            }?,
            operation_commit: *unsafe {
                library.get(b"subversionr_bridge_operation_commit_with_auth\0")
            }?,
        })
    }
}

#[derive(Clone, Copy)]
struct RemoteNativeSymbols {
    remote_context_create: RemoteContextCreate,
    remote_context_inspect: RemoteContextInspect,
    remote_context_destroy: RemoteContextDestroy,
    remote_context_finish_credentials: RemoteContextFinishCredentials,
    private_remote_credential_provider_probe: PrivateRemoteCredentialProviderProbe,
    version: Version,
}

impl RemoteNativeSymbols {
    unsafe fn load_foundation(library: &Library) -> Result<Self, libloading::Error> {
        Ok(Self {
            remote_context_create: *unsafe {
                library.get(b"subversionr_bridge_remote_context_create\0")
            }?,
            remote_context_inspect: *unsafe {
                library.get(b"subversionr_bridge_remote_context_inspect\0")
            }?,
            remote_context_destroy: *unsafe {
                library.get(b"subversionr_bridge_remote_context_destroy\0")
            }?,
            remote_context_finish_credentials: *unsafe {
                library.get(b"subversionr_bridge_remote_context_finish_credentials\0")
            }?,
            private_remote_credential_provider_probe: *unsafe {
                library.get(b"subversionr_bridge_private_remote_credential_provider_probe\0")
            }?,
            version: *unsafe { library.get(b"subversionr_bridge_version\0") }?,
        })
    }
}

#[derive(Debug)]
pub enum NativeBridgeLoadError {
    PathMustBeAbsolute(PathBuf),
    MissingLibrary(PathBuf),
    LoadLibrary {
        path: PathBuf,
        source: libloading::Error,
    },
    MissingSymbol(libloading::Error),
    RuntimeCreateFailed(c_int),
    RuntimeCreateReturnedNull,
    NullString(&'static str),
    InvalidUtf8 {
        field: &'static str,
        source: std::str::Utf8Error,
    },
}

impl fmt::Display for NativeBridgeLoadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::PathMustBeAbsolute(path) => {
                write!(f, "native bridge path must be absolute: {}", path.display())
            }
            Self::MissingLibrary(path) => {
                write!(f, "native bridge library is missing: {}", path.display())
            }
            Self::LoadLibrary { path, source } => {
                write!(
                    f,
                    "failed to load native bridge {}: {source}",
                    path.display()
                )
            }
            Self::MissingSymbol(source) => write!(f, "native bridge symbol is missing: {source}"),
            Self::RuntimeCreateFailed(status) => {
                write!(
                    f,
                    "native bridge runtime creation failed with status {status}"
                )
            }
            Self::RuntimeCreateReturnedNull => {
                write!(f, "native bridge runtime creation returned a null runtime")
            }
            Self::NullString(field) => write!(f, "native bridge returned null {field}"),
            Self::InvalidUtf8 { field, source } => {
                write!(
                    f,
                    "native bridge returned invalid UTF-8 for {field}: {source}"
                )
            }
        }
    }
}

impl std::error::Error for NativeBridgeLoadError {}

impl NativeBridgeLoadError {
    pub fn startup_error(&self) -> serde_json::Value {
        let (code, message_key, safe_args) = match self {
            Self::PathMustBeAbsolute(_) => (
                "SUBVERSIONR_NATIVE_BRIDGE_PATH_NOT_ABSOLUTE",
                "error.backend.nativeBridgePathNotAbsolute",
                json!({}),
            ),
            Self::MissingLibrary(_) => (
                "SUBVERSIONR_NATIVE_BRIDGE_LIBRARY_MISSING",
                "error.backend.nativeBridgeLibraryMissing",
                json!({}),
            ),
            Self::LoadLibrary { .. } => (
                "SUBVERSIONR_NATIVE_BRIDGE_LOAD_FAILED",
                "error.backend.nativeBridgeLoadFailed",
                json!({}),
            ),
            Self::MissingSymbol(_) => (
                "SUBVERSIONR_NATIVE_BRIDGE_SYMBOL_MISSING",
                "error.backend.nativeBridgeSymbolMissing",
                json!({}),
            ),
            Self::RuntimeCreateFailed(status) => (
                "SUBVERSIONR_NATIVE_BRIDGE_RUNTIME_CREATE_FAILED",
                "error.backend.nativeBridgeRuntimeCreateFailed",
                json!({ "status": status }),
            ),
            Self::RuntimeCreateReturnedNull => (
                "SUBVERSIONR_NATIVE_BRIDGE_RUNTIME_CREATE_NULL",
                "error.backend.nativeBridgeRuntimeCreateNull",
                json!({}),
            ),
            Self::NullString(field) => (
                "SUBVERSIONR_NATIVE_BRIDGE_STRING_NULL",
                "error.backend.nativeBridgeStringNull",
                json!({ "field": field }),
            ),
            Self::InvalidUtf8 { field, .. } => (
                "SUBVERSIONR_NATIVE_BRIDGE_STRING_INVALID_UTF8",
                "error.backend.nativeBridgeStringInvalidUtf8",
                json!({ "field": field }),
            ),
        };

        json!({
            "schema": "subversionr.daemon.startup-error.v1",
            "code": code,
            "category": "process",
            "messageKey": message_key,
            "safeArgs": safe_args,
            "retryable": false,
            "diagnostics": null,
        })
    }
}

pub struct NativeBridge {
    info: BridgeInfo,
    runtime: NonNull<c_void>,
    symbols: NativeSymbols,
    _library: Library,
}

pub struct RemoteNativeBridge {
    symbols: RemoteNativeSymbols,
    _library: Library,
}

impl RemoteNativeBridge {
    pub fn load_foundation(path: impl AsRef<Path>) -> Result<Self, NativeBridgeLoadError> {
        let path = path.as_ref();
        if !path.is_absolute() {
            return Err(NativeBridgeLoadError::PathMustBeAbsolute(
                path.to_path_buf(),
            ));
        }
        if !path.is_file() {
            return Err(NativeBridgeLoadError::MissingLibrary(path.to_path_buf()));
        }
        let library =
            unsafe { load_library(path) }.map_err(|source| NativeBridgeLoadError::LoadLibrary {
                path: path.to_path_buf(),
                source,
            })?;
        let symbols = unsafe { RemoteNativeSymbols::load_foundation(&library) }
            .map_err(NativeBridgeLoadError::MissingSymbol)?;
        unsafe { format_libsvn_version((symbols.version)())? };
        Ok(Self {
            symbols,
            _library: library,
        })
    }

    pub fn create_remote_context_foundation(
        &self,
        plan: RemoteConfigPlan,
        envelope: &RemoteOperationEnvelope,
        auth: &mut dyn AuthRequestBroker,
        deadline: Instant,
    ) -> Result<(), BridgeFailure> {
        let _required_finish_symbol = self.symbols.remote_context_finish_credentials;
        create_remote_context_foundation_worker_raw(
            self.symbols.remote_context_create,
            self.symbols.remote_context_inspect,
            self.symbols.remote_context_destroy,
            plan,
            envelope,
            auth,
            deadline,
        )
    }

    pub(crate) fn probe_remote_credentials(
        &self,
        envelope: &RemoteOperationEnvelope,
        auth: &mut dyn AuthRequestBroker,
        deadline: Instant,
        scenario: u32,
    ) -> Result<(), BridgeFailure> {
        let (raw_scenario, terminal_outcome) = match scenario {
            1 => (1, 0),
            2 => (2, 0),
            3 => (3, 3),
            4 => (4, 4),
            5 => (5, 5),
            _ => return Err(native_auth_response_invalid("credentials/probe")),
        };
        let realm = CString::new("SubversionR private credential provider probe")
            .expect("fixed probe realm");
        let suggested_username = match &envelope.profile.server_account {
            ServerAccountSnapshot::Selection(ServerAccountSelection::Fixed { username }) => {
                username.as_str()
            }
            ServerAccountSnapshot::Selection(ServerAccountSelection::ChooseForeground) => {
                "subversionr-probe"
            }
            ServerAccountSnapshot::None(_) => {
                return Err(native_auth_response_invalid("credentials/probe"));
            }
        };
        if !valid_remote_username(suggested_username) {
            return Err(native_auth_response_invalid("credentials/probe"));
        }
        let suggested_username = CString::new(suggested_username)
            .map_err(|_| native_auth_response_invalid("credentials/probe"))?;
        let mut baton = RemoteCredentialBaton {
            auth,
            envelope,
            deadline,
            failure: None,
        };
        let callbacks = raw_remote_credential_callbacks(&mut baton);
        let request = RawPrivateCredentialProbeRequest {
            abi_version: RAW_REMOTE_CREDENTIAL_ABI_VERSION,
            scenario: raw_scenario,
            realm: realm.as_ptr(),
            suggested_username: suggested_username.as_ptr(),
            terminal_outcome,
        };
        let mut inspection = RawPrivateCredentialProbeInspection::default();
        let status = unsafe {
            (self.symbols.private_remote_credential_provider_probe)(
                &callbacks,
                &request,
                &mut inspection,
            )
        };
        if let Some(failure) = baton.take_failure() {
            return Err(failure);
        }
        if status != 0
            || inspection.abi_version != RAW_REMOTE_CREDENTIAL_ABI_VERSION
            || inspection.scenario != raw_scenario
            || inspection.terminal_outcome != terminal_outcome
            || inspection.event_count == 0
            || inspection.event_count as usize > RAW_CREDENTIAL_PROBE_EVENT_LIMIT
        {
            return Err(remote_context_failure(
                "SUBVERSIONR_REMOTE_CREDENTIAL_PROBE_FAILED",
                "error.remote.credentialProbeFailed",
                status,
            ));
        }
        Ok(())
    }
}

impl NativeBridge {
    pub fn load(path: impl AsRef<Path>) -> Result<Self, NativeBridgeLoadError> {
        let path = path.as_ref();
        if !path.is_absolute() {
            return Err(NativeBridgeLoadError::PathMustBeAbsolute(
                path.to_path_buf(),
            ));
        }
        if !path.is_file() {
            return Err(NativeBridgeLoadError::MissingLibrary(path.to_path_buf()));
        }

        let library =
            unsafe { load_library(path) }.map_err(|source| NativeBridgeLoadError::LoadLibrary {
                path: path.to_path_buf(),
                source,
            })?;
        let symbols = unsafe { NativeSymbols::load(&library) }
            .map_err(NativeBridgeLoadError::MissingSymbol)?;
        let libsvn_version = unsafe { format_libsvn_version((symbols.version)())? };

        let mut runtime = ptr::null_mut();
        let create_status = unsafe { (symbols.runtime_create)(&mut runtime) };
        if create_status != 0 {
            return Err(NativeBridgeLoadError::RuntimeCreateFailed(create_status));
        }
        let runtime =
            NonNull::new(runtime).ok_or(NativeBridgeLoadError::RuntimeCreateReturnedNull)?;

        Ok(Self {
            info: BridgeInfo::available(BRIDGE_RUNTIME_VERSION, libsvn_version),
            runtime,
            symbols,
            _library: library,
        })
    }

    pub fn probe_remote_url_with_auth(
        &self,
        url: &str,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<(), BridgeFailure> {
        let url_c = CString::new(url).map_err(|_| BridgeFailure::invalid_path())?;
        let mut auth_baton = NativeAuthBaton::new(auth, None, None);
        let callbacks = RawAuthCallbacks {
            abi_version: RAW_AUTH_ABI_VERSION,
            baton: (&mut auth_baton as *mut NativeAuthBaton<'_>).cast::<c_void>(),
            credential_callback: Some(native_credential_callback),
            credential_response_dispose: Some(native_credential_response_dispose),
            certificate_callback: Some(native_certificate_callback),
        };

        let status = unsafe {
            (self.symbols.probe_remote_url_with_auth)(
                self.runtime.as_ptr(),
                url_c.as_ptr(),
                &callbacks,
            )
        };
        if status != 0 {
            let native_failure =
                self.with_native_diagnostics(remote_url_probe_failure(status, url));
            if let Some(mut failure) = auth_baton.take_failure() {
                failure.diagnostics = native_failure.diagnostics;
                return Err(failure);
            }
            return Err(native_failure);
        }

        Ok(())
    }

    fn with_native_diagnostics(&self, failure: BridgeFailure) -> BridgeFailure {
        let mut raw = RawErrorDiagnostics {
            entries: ptr::null(),
            entry_count: 0,
            truncated: 0,
        };
        let status =
            unsafe { (self.symbols.last_error_diagnostics)(self.runtime.as_ptr(), &mut raw) };
        let entries = if status == 0
            && raw.entry_count <= 8
            && (raw.entry_count == 0 || !raw.entries.is_null())
        {
            unsafe { slice::from_raw_parts(raw.entries, raw.entry_count) }
                .iter()
                .filter_map(|entry| {
                    let name = unsafe { optional_c_string_to_owned(entry.name, "error.name") }
                        .ok()
                        .flatten()?;
                    Some(SvnErrorDiagnosticEntry {
                        code: entry.code,
                        name,
                    })
                })
                .collect()
        } else {
            Vec::new()
        };
        if entries.is_empty() {
            return failure;
        }
        let cause = native_failure_cause(&entries);
        failure.with_diagnostics(OperationFailureDiagnostics {
            cause,
            svn: SvnErrorDiagnostics {
                entries,
                truncated: raw.truncated != 0,
            },
        })
    }
}

fn native_failure_cause(entries: &[SvnErrorDiagnosticEntry]) -> OperationFailureCause {
    for entry in entries {
        if matches!(
            entry.name.as_str(),
            "SVN_ERR_FS_TXN_OUT_OF_DATE" | "SVN_ERR_RA_OUT_OF_DATE"
        ) {
            return OperationFailureCause::OutOfDate;
        }
        if entry.name.contains("CONFLICT") {
            return OperationFailureCause::ConflictPresent;
        }
        if entry.name.contains("AUTH") || entry.name.contains("NOT_AUTHORIZED") {
            return OperationFailureCause::AuthenticationFailed;
        }
        if matches!(
            entry.name.as_str(),
            "SVN_ERR_WC_NOT_WORKING_COPY" | "SVN_ERR_WC_NOT_DIRECTORY"
        ) {
            return OperationFailureCause::NotWorkingCopy;
        }
    }
    OperationFailureCause::UnknownNative
}

impl BridgeApi for NativeBridge {
    fn info(&self) -> BridgeInfo {
        self.info.clone()
    }

    fn create_remote_context_foundation(
        &self,
        plan: RemoteConfigPlan,
    ) -> Result<(), BridgeFailure> {
        create_remote_context_foundation_raw(
            self.symbols.remote_context_create,
            self.symbols.remote_context_inspect,
            self.symbols.remote_context_destroy,
            plan,
        )
    }

    fn open_working_copy(&self, path: &str) -> Result<RepositoryIdentity, BridgeFailure> {
        let path_c = CString::new(path).map_err(|_| BridgeFailure::invalid_path())?;
        let mut info = RawWorkingCopyInfo {
            repository_uuid: ptr::null(),
            repository_root_url: ptr::null(),
            working_copy_root: ptr::null(),
            format: 0,
        };

        let status = unsafe {
            (self.symbols.open_working_copy)(self.runtime.as_ptr(), path_c.as_ptr(), &mut info)
        };
        if status != 0 {
            return Err(self.with_native_diagnostics(open_working_copy_failure(status, path)));
        }

        repository_identity_from_raw(path, info)
    }
    fn open_working_copy_with_auth(
        &self,
        path: &str,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<RepositoryIdentity, BridgeFailure> {
        let path_c = CString::new(path).map_err(|_| BridgeFailure::invalid_path())?;
        let mut info = RawWorkingCopyInfo {
            repository_uuid: ptr::null(),
            repository_root_url: ptr::null(),
            working_copy_root: ptr::null(),
            format: 0,
        };
        let mut auth_baton = NativeAuthBaton::new(auth, None, Some(path.to_string()));
        let callbacks = RawAuthCallbacks {
            abi_version: RAW_AUTH_ABI_VERSION,
            baton: (&mut auth_baton as *mut NativeAuthBaton<'_>).cast::<c_void>(),
            credential_callback: Some(native_credential_callback),
            credential_response_dispose: Some(native_credential_response_dispose),
            certificate_callback: Some(native_certificate_callback),
        };

        let status = unsafe {
            (self.symbols.open_working_copy_with_auth)(
                self.runtime.as_ptr(),
                path_c.as_ptr(),
                &callbacks,
                &mut info,
            )
        };
        if status != 0 {
            let native_failure =
                self.with_native_diagnostics(open_working_copy_failure(status, path));
            if let Some(mut failure) = auth_baton.take_failure() {
                failure.diagnostics = native_failure.diagnostics;
                return Err(failure);
            }
            return Err(native_failure);
        }

        repository_identity_from_raw(path, info)
    }

    fn repository_checkout_with_cancellation(
        &self,
        request: &RepositoryCheckoutRequest,
        auth: &mut dyn AuthRequestBroker,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<RepositoryCheckoutResult, BridgeFailure> {
        if !valid_checkout_url(&request.url)
            || !valid_checkout_target_path(&request.target_path)
            || !valid_update_revision(&request.revision)
            || !valid_checkout_depth(&request.depth)
        {
            return Err(BridgeFailure::invalid_path());
        }

        let target_path = normalize_bridge_path(&request.target_path);
        let url_c =
            CString::new(request.url.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let target_path_c =
            CString::new(target_path.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let revision_c =
            CString::new(request.revision.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let depth_c =
            CString::new(request.depth.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let mut raw_revision = -1_i64;
        let mut auth_baton = NativeAuthBaton::new(auth, None, Some(target_path.clone()));
        let callbacks = RawAuthCallbacks {
            abi_version: RAW_AUTH_ABI_VERSION,
            baton: (&mut auth_baton as *mut NativeAuthBaton<'_>).cast::<c_void>(),
            credential_callback: Some(native_credential_callback),
            credential_response_dispose: Some(native_credential_response_dispose),
            certificate_callback: Some(native_certificate_callback),
        };
        let mut cancel_baton = NativeCancelBaton {
            token: cancellation,
        };
        let cancel_callbacks = raw_cancel_callbacks(&mut cancel_baton);

        let status = unsafe {
            (self.symbols.repository_checkout)(
                self.runtime.as_ptr(),
                url_c.as_ptr(),
                target_path_c.as_ptr(),
                revision_c.as_ptr(),
                depth_c.as_ptr(),
                request.ignore_externals as c_int,
                &callbacks,
                &cancel_callbacks,
                &mut raw_revision,
            )
        };
        if status != 0 {
            let native_failure =
                self.with_native_diagnostics(repository_checkout_failure(status, &target_path));
            if let Some(mut failure) = auth_baton.take_failure() {
                failure.diagnostics = native_failure.diagnostics;
                return Err(failure);
            }
            return Err(native_failure);
        }
        if raw_revision < 0 {
            return Err(native_invalid_response(&target_path, "checkout.revision"));
        }

        Ok(RepositoryCheckoutResult {
            working_copy_path: target_path,
            revision: raw_revision,
        })
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
    ) -> Result<StatusSnapshot, BridgeFailure> {
        self.status_scan_with_cancellation(identity, ".", "infinity", generation, cancellation)
    }

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
    ) -> Result<StatusSnapshot, BridgeFailure> {
        if !valid_scan_path(path) || !matches!(depth, "empty" | "files" | "immediates" | "infinity")
        {
            return Err(BridgeFailure::invalid_path());
        }
        let scan_path = scan_path(&identity.working_copy_root, path);
        let path_c = CString::new(scan_path.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let depth_c = CString::new(depth).map_err(|_| BridgeFailure::invalid_path())?;
        let mut raw_snapshot = RawStatusSnapshot {
            entries: ptr::null(),
            entry_count: 0,
        };
        let mut cancel_baton = NativeCancelBaton {
            token: cancellation,
        };
        let cancel_callbacks = RawCancelCallbacks {
            abi_version: RAW_CANCEL_ABI_VERSION,
            baton: (&mut cancel_baton as *mut NativeCancelBaton<'_>).cast::<c_void>(),
            cancel_callback: Some(native_cancel_callback),
        };

        let status = unsafe {
            (self.symbols.status_snapshot)(
                self.runtime.as_ptr(),
                path_c.as_ptr(),
                depth_c.as_ptr(),
                &cancel_callbacks,
                &mut raw_snapshot,
            )
        };
        if status != 0 {
            return Err(self.with_native_diagnostics(status_snapshot_failure(status, &scan_path)));
        }
        if raw_snapshot.entry_count > 0 && raw_snapshot.entries.is_null() {
            return Err(native_invalid_response(&scan_path, "status.entries"));
        }

        let raw_entries = if raw_snapshot.entry_count == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(raw_snapshot.entries, raw_snapshot.entry_count) }
        };
        let mut local_entries = Vec::with_capacity(raw_entries.len());
        for raw_entry in raw_entries {
            local_entries.push(raw_status_entry_to_protocol(
                raw_entry, identity, generation,
            )?);
        }
        remove_conflict_artifact_entries(&mut local_entries);
        let summary = status_summary(&local_entries);

        Ok(StatusSnapshot {
            repository_id: repository_id(identity),
            epoch: 0,
            generation,
            completeness: if path == "." && depth == "infinity" {
                "complete".to_string()
            } else {
                "partial".to_string()
            },
            identity: identity.clone(),
            local_entries,
            remote_entries: Vec::new(),
            summary,
            timestamp: current_timestamp(),
            source: "libsvn-local".to_string(),
        })
    }

    fn status_remote_check_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        generation: u64,
        auth: &mut dyn AuthRequestBroker,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<StatusSnapshot, BridgeFailure> {
        let scan_path = scan_path(&identity.working_copy_root, ".");
        let path_c = CString::new(scan_path.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let mut raw_snapshot = RawStatusSnapshot {
            entries: ptr::null(),
            entry_count: 0,
        };
        let mut auth_baton = NativeAuthBaton::new(
            auth,
            Some(repository_id(identity)),
            Some(identity.working_copy_root.clone()),
        );
        let auth_callbacks = RawAuthCallbacks {
            abi_version: RAW_AUTH_ABI_VERSION,
            baton: (&mut auth_baton as *mut NativeAuthBaton<'_>).cast::<c_void>(),
            credential_callback: Some(native_credential_callback),
            credential_response_dispose: Some(native_credential_response_dispose),
            certificate_callback: Some(native_certificate_callback),
        };
        let mut cancel_baton = NativeCancelBaton {
            token: cancellation,
        };
        let cancel_callbacks = RawCancelCallbacks {
            abi_version: RAW_CANCEL_ABI_VERSION,
            baton: (&mut cancel_baton as *mut NativeCancelBaton<'_>).cast::<c_void>(),
            cancel_callback: Some(native_cancel_callback),
        };

        let status = unsafe {
            (self.symbols.status_remote_scan)(
                self.runtime.as_ptr(),
                path_c.as_ptr(),
                &auth_callbacks,
                &cancel_callbacks,
                &mut raw_snapshot,
            )
        };
        if status != 0 {
            let native_failure =
                self.with_native_diagnostics(remote_status_failure(status, &scan_path));
            if let Some(mut failure) = auth_baton.take_failure() {
                failure.diagnostics = native_failure.diagnostics;
                return Err(failure);
            }
            return Err(native_failure);
        }
        if raw_snapshot.entry_count > 0 && raw_snapshot.entries.is_null() {
            return Err(native_invalid_response(&scan_path, "remoteStatus.entries"));
        }

        let raw_entries = if raw_snapshot.entry_count == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(raw_snapshot.entries, raw_snapshot.entry_count) }
        };
        let mut remote_entries = Vec::with_capacity(raw_entries.len());
        for raw_entry in raw_entries {
            let entry = raw_remote_status_entry_to_protocol(raw_entry, identity, generation)?;
            if is_actionable_remote_entry(&entry) {
                remote_entries.push(entry);
            }
        }
        let remote_changes = remote_entries
            .len()
            .try_into()
            .map_err(|_| native_invalid_response(&scan_path, "remoteStatus.entries"))?;

        Ok(StatusSnapshot {
            repository_id: repository_id(identity),
            epoch: 0,
            generation,
            completeness: "complete".to_string(),
            identity: identity.clone(),
            local_entries: Vec::new(),
            remote_entries,
            summary: StatusSummary {
                local_changes: 0,
                remote_changes,
                conflicts: 0,
                unversioned: 0,
            },
            timestamp: current_timestamp(),
            source: "libsvn-remote".to_string(),
        })
    }

    fn content_get(
        &self,
        identity: &RepositoryIdentity,
        path: &str,
        revision: &str,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<ContentBlob, BridgeFailure> {
        if !valid_content_path(path) || !valid_content_revision(revision) {
            return Err(BridgeFailure::invalid_path());
        }
        let content_path = scan_path(&identity.working_copy_root, path);
        let path_c =
            CString::new(content_path.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let revision_c = CString::new(revision).map_err(|_| BridgeFailure::invalid_path())?;
        let mut raw_content = RawContent {
            data: ptr::null(),
            byte_count: 0,
            mime_type: ptr::null(),
            is_binary: 0,
        };
        let mut auth_baton = NativeAuthBaton::new(
            auth,
            Some(repository_id(identity)),
            Some(identity.working_copy_root.clone()),
        );
        let callbacks = RawAuthCallbacks {
            abi_version: RAW_AUTH_ABI_VERSION,
            baton: (&mut auth_baton as *mut NativeAuthBaton<'_>).cast::<c_void>(),
            credential_callback: Some(native_credential_callback),
            credential_response_dispose: Some(native_credential_response_dispose),
            certificate_callback: Some(native_certificate_callback),
        };

        let status = unsafe {
            (self.symbols.content_get)(
                self.runtime.as_ptr(),
                path_c.as_ptr(),
                revision_c.as_ptr(),
                &callbacks,
                &mut raw_content,
            )
        };
        if status != 0 {
            let native_failure =
                self.with_native_diagnostics(content_get_failure(status, &content_path));
            if let Some(mut failure) = auth_baton.take_failure() {
                failure.diagnostics = native_failure.diagnostics;
                return Err(failure);
            }
            return Err(native_failure);
        }
        if raw_content.byte_count > 0 && raw_content.data.is_null() {
            return Err(native_invalid_response(&content_path, "content.data"));
        }

        let data = if raw_content.byte_count == 0 {
            Vec::new()
        } else {
            unsafe { slice::from_raw_parts(raw_content.data, raw_content.byte_count) }.to_vec()
        };
        let mime_type =
            unsafe { optional_c_string_to_owned(raw_content.mime_type, "content.mimeType") }
                .map_err(|failure| native_field_failure(&content_path, failure))?;

        Ok(ContentBlob {
            data,
            mime_type,
            is_binary: raw_content.is_binary != 0,
            source: content_source(revision).to_string(),
        })
    }

    fn properties_list(
        &self,
        identity: &RepositoryIdentity,
        path: &str,
    ) -> Result<PropertiesListResult, BridgeFailure> {
        if !valid_property_path(path) {
            return Err(BridgeFailure::invalid_path());
        }
        let property_path = scan_path(&identity.working_copy_root, path);
        let path_c =
            CString::new(property_path.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let mut raw_properties = RawPropertyList {
            entries: ptr::null(),
            entry_count: 0,
        };

        let status = unsafe {
            (self.symbols.properties_list)(
                self.runtime.as_ptr(),
                path_c.as_ptr(),
                &mut raw_properties,
            )
        };
        if status != 0 {
            return Err(
                self.with_native_diagnostics(properties_list_failure(status, &property_path))
            );
        }
        if raw_properties.entry_count > 0 && raw_properties.entries.is_null() {
            return Err(native_invalid_response(
                &property_path,
                "properties.entries",
            ));
        }

        let raw_entries = if raw_properties.entry_count == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(raw_properties.entries, raw_properties.entry_count) }
        };
        let mut properties = Vec::with_capacity(raw_entries.len());
        for raw_entry in raw_entries {
            properties.push(raw_property_entry_to_protocol(raw_entry, &property_path)?);
        }

        Ok(PropertiesListResult {
            properties,
            source: "libsvn-local".to_string(),
        })
    }

    fn history_log(
        &self,
        identity: &RepositoryIdentity,
        request: &HistoryLogRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<HistoryLogResult, BridgeFailure> {
        if !valid_history_path(&request.path)
            || !valid_history_start_revision(&request.start_revision)
            || !valid_history_end_revision(&request.end_revision)
            || !(1..=500).contains(&request.limit)
        {
            return Err(BridgeFailure::invalid_path());
        }

        let log_path = scan_path(&identity.working_copy_root, &request.path);
        let path_c = CString::new(log_path.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let start_revision_c = CString::new(request.start_revision.as_str())
            .map_err(|_| BridgeFailure::invalid_path())?;
        let end_revision_c = CString::new(request.end_revision.as_str())
            .map_err(|_| BridgeFailure::invalid_path())?;
        let mut raw_log = RawHistoryLog {
            entries: ptr::null(),
            entry_count: 0,
        };
        let mut auth_baton = NativeAuthBaton::new(
            auth,
            Some(repository_id(identity)),
            Some(identity.working_copy_root.clone()),
        );
        let callbacks = RawAuthCallbacks {
            abi_version: RAW_AUTH_ABI_VERSION,
            baton: (&mut auth_baton as *mut NativeAuthBaton<'_>).cast::<c_void>(),
            credential_callback: Some(native_credential_callback),
            credential_response_dispose: Some(native_credential_response_dispose),
            certificate_callback: Some(native_certificate_callback),
        };

        let status = unsafe {
            (self.symbols.history_log)(
                self.runtime.as_ptr(),
                path_c.as_ptr(),
                start_revision_c.as_ptr(),
                end_revision_c.as_ptr(),
                request.limit as c_int,
                c_int::from(request.discover_changed_paths),
                c_int::from(request.strict_node_history),
                c_int::from(request.include_merged_revisions),
                &callbacks,
                &mut raw_log,
            )
        };
        if status != 0 {
            let native_failure =
                self.with_native_diagnostics(history_log_failure(status, &log_path));
            if let Some(mut failure) = auth_baton.take_failure() {
                failure.diagnostics = native_failure.diagnostics;
                return Err(failure);
            }
            return Err(native_failure);
        }
        if raw_log.entry_count > 0 && raw_log.entries.is_null() {
            return Err(native_invalid_response(&log_path, "history.entries"));
        }

        let raw_entries = if raw_log.entry_count == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(raw_log.entries, raw_log.entry_count) }
        };
        let mut entries = Vec::with_capacity(raw_entries.len());
        for raw_entry in raw_entries {
            entries.push(raw_history_entry_to_protocol(raw_entry, &log_path)?);
        }

        Ok(HistoryLogResult {
            entries,
            source: "libsvn-log".to_string(),
        })
    }

    fn history_blame(
        &self,
        identity: &RepositoryIdentity,
        request: &HistoryBlameRequest,
        auth: &mut dyn AuthRequestBroker,
    ) -> Result<HistoryBlameResult, BridgeFailure> {
        if !valid_blame_path(&request.path)
            || !valid_blame_peg_or_end_revision(&request.peg_revision)
            || !valid_numbered_revision(&request.start_revision)
            || !valid_blame_peg_or_end_revision(&request.end_revision)
            || request.line_start == 0
            || request.line_start > i64::MAX as u64
            || !(1..=5000).contains(&request.line_limit)
            || !valid_ignore_whitespace(&request.ignore_whitespace)
        {
            return Err(BridgeFailure::invalid_path());
        }

        let blame_path = scan_path(&identity.working_copy_root, &request.path);
        let path_c =
            CString::new(blame_path.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let peg_revision_c = CString::new(request.peg_revision.as_str())
            .map_err(|_| BridgeFailure::invalid_path())?;
        let start_revision_c = CString::new(request.start_revision.as_str())
            .map_err(|_| BridgeFailure::invalid_path())?;
        let end_revision_c = CString::new(request.end_revision.as_str())
            .map_err(|_| BridgeFailure::invalid_path())?;
        let ignore_whitespace_c = CString::new(request.ignore_whitespace.as_str())
            .map_err(|_| BridgeFailure::invalid_path())?;
        let mut raw_blame = RawHistoryBlame {
            resolved_start_revision: -1,
            resolved_end_revision: -1,
            lines: ptr::null(),
            line_count: 0,
            has_more: 0,
        };
        let mut auth_baton = NativeAuthBaton::new(
            auth,
            Some(repository_id(identity)),
            Some(identity.working_copy_root.clone()),
        );
        let callbacks = RawAuthCallbacks {
            abi_version: RAW_AUTH_ABI_VERSION,
            baton: (&mut auth_baton as *mut NativeAuthBaton<'_>).cast::<c_void>(),
            credential_callback: Some(native_credential_callback),
            credential_response_dispose: Some(native_credential_response_dispose),
            certificate_callback: Some(native_certificate_callback),
        };

        let status = unsafe {
            (self.symbols.history_blame)(
                self.runtime.as_ptr(),
                path_c.as_ptr(),
                peg_revision_c.as_ptr(),
                start_revision_c.as_ptr(),
                end_revision_c.as_ptr(),
                ignore_whitespace_c.as_ptr(),
                c_int::from(request.ignore_eol_style),
                c_int::from(request.ignore_mime_type),
                c_int::from(request.include_merged_revisions),
                request.line_start as i64,
                request.line_limit as c_int,
                &callbacks,
                &mut raw_blame,
            )
        };
        if status != 0 {
            let native_failure =
                self.with_native_diagnostics(history_blame_failure(status, &blame_path));
            if let Some(mut failure) = auth_baton.take_failure() {
                failure.diagnostics = native_failure.diagnostics;
                return Err(failure);
            }
            return Err(native_failure);
        }
        if raw_blame.resolved_start_revision < 0 || raw_blame.resolved_end_revision < 0 {
            return Err(native_invalid_response(
                &blame_path,
                "history.blame.resolvedRevision",
            ));
        }
        if raw_blame.line_count > 0 && raw_blame.lines.is_null() {
            return Err(native_invalid_response(&blame_path, "history.blame.lines"));
        }

        let raw_lines = if raw_blame.line_count == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(raw_blame.lines, raw_blame.line_count) }
        };
        let mut lines = Vec::with_capacity(raw_lines.len());
        for raw_line in raw_lines {
            lines.push(raw_history_blame_line_to_protocol(raw_line, &blame_path)?);
        }

        Ok(HistoryBlameResult {
            resolved_start_revision: raw_blame.resolved_start_revision,
            resolved_end_revision: raw_blame.resolved_end_revision,
            line_start: request.line_start,
            line_limit: request.line_limit,
            ignore_whitespace: request.ignore_whitespace.clone(),
            ignore_eol_style: request.ignore_eol_style,
            ignore_mime_type: request.ignore_mime_type,
            include_merged_revisions: request.include_merged_revisions,
            has_more: raw_blame.has_more != 0,
            lines,
            source: "libsvn-blame".to_string(),
        })
    }

    fn operation_revert_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &RevertOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        if request.paths.is_empty()
            || !request.paths.iter().all(|path| valid_scan_path(path))
            || !matches!(
                request.depth.as_str(),
                "empty" | "files" | "immediates" | "infinity"
            )
            || !request
                .changelists
                .iter()
                .all(|changelist| valid_changelist(changelist))
            || has_duplicate_paths(&request.changelists)
        {
            return Err(BridgeFailure::invalid_path());
        }

        let path_strings = request
            .paths
            .iter()
            .map(|path| CString::new(scan_path(&identity.working_copy_root, path)))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| BridgeFailure::invalid_path())?;
        let path_ptrs = path_strings
            .iter()
            .map(|path| path.as_ptr())
            .collect::<Vec<_>>();
        let depth_c =
            CString::new(request.depth.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let changelist_strings = request
            .changelists
            .iter()
            .map(|changelist| CString::new(changelist.as_str()))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| BridgeFailure::invalid_path())?;
        let changelist_ptrs = changelist_strings
            .iter()
            .map(|changelist| changelist.as_ptr())
            .collect::<Vec<_>>();
        let changelist_ptr = if changelist_ptrs.is_empty() {
            ptr::null()
        } else {
            changelist_ptrs.as_ptr()
        };
        let mut raw_result = RawOperationResult {
            touched_paths: ptr::null(),
            touched_path_count: 0,
            skipped_paths: ptr::null(),
            skipped_path_count: 0,
        };
        let mut cancel_baton = NativeCancelBaton {
            token: cancellation,
        };
        let cancel_callbacks = raw_cancel_callbacks(&mut cancel_baton);

        let status = unsafe {
            (self.symbols.operation_revert)(
                self.runtime.as_ptr(),
                path_ptrs.as_ptr(),
                path_ptrs.len(),
                depth_c.as_ptr(),
                changelist_ptr,
                changelist_ptrs.len(),
                request.clear_changelists as c_int,
                request.metadata_only as c_int,
                request.added_keep_local as c_int,
                &cancel_callbacks,
                &mut raw_result,
            )
        };
        if status != 0 {
            return Err(self.with_native_diagnostics(operation_revert_failure(
                status,
                &identity.working_copy_root,
            )));
        }

        Ok(OperationResult {
            touched_paths: raw_operation_paths_to_protocol(
                raw_result.touched_paths,
                raw_result.touched_path_count,
                identity,
                "operation.touchedPaths",
            )?,
            skipped_paths: raw_operation_paths_to_protocol(
                raw_result.skipped_paths,
                raw_result.skipped_path_count,
                identity,
                "operation.skippedPaths",
            )?,
        })
    }

    fn operation_add_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &AddOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        if request.paths.is_empty()
            || !request.paths.iter().all(|path| valid_scan_path(path))
            || !matches!(
                request.depth.as_str(),
                "empty" | "files" | "immediates" | "infinity"
            )
        {
            return Err(BridgeFailure::invalid_path());
        }

        let path_strings = request
            .paths
            .iter()
            .map(|path| CString::new(scan_path(&identity.working_copy_root, path)))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| BridgeFailure::invalid_path())?;
        let path_ptrs = path_strings
            .iter()
            .map(|path| path.as_ptr())
            .collect::<Vec<_>>();
        let depth_c =
            CString::new(request.depth.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let mut raw_result = RawOperationResult {
            touched_paths: ptr::null(),
            touched_path_count: 0,
            skipped_paths: ptr::null(),
            skipped_path_count: 0,
        };
        let mut cancel_baton = NativeCancelBaton {
            token: cancellation,
        };
        let cancel_callbacks = raw_cancel_callbacks(&mut cancel_baton);

        let status = unsafe {
            (self.symbols.operation_add)(
                self.runtime.as_ptr(),
                path_ptrs.as_ptr(),
                path_ptrs.len(),
                depth_c.as_ptr(),
                request.force as c_int,
                request.no_ignore as c_int,
                request.no_autoprops as c_int,
                request.add_parents as c_int,
                &cancel_callbacks,
                &mut raw_result,
            )
        };
        if status != 0 {
            return Err(self.with_native_diagnostics(operation_add_failure(
                status,
                &identity.working_copy_root,
            )));
        }

        Ok(OperationResult {
            touched_paths: raw_operation_paths_to_protocol(
                raw_result.touched_paths,
                raw_result.touched_path_count,
                identity,
                "operation.touchedPaths",
            )?,
            skipped_paths: raw_operation_paths_to_protocol(
                raw_result.skipped_paths,
                raw_result.skipped_path_count,
                identity,
                "operation.skippedPaths",
            )?,
        })
    }

    fn operation_remove_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &RemoveOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        if request.paths.is_empty() || !request.paths.iter().all(|path| valid_scan_path(path)) {
            return Err(BridgeFailure::invalid_path());
        }

        let path_strings = request
            .paths
            .iter()
            .map(|path| CString::new(scan_path(&identity.working_copy_root, path)))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| BridgeFailure::invalid_path())?;
        let path_ptrs = path_strings
            .iter()
            .map(|path| path.as_ptr())
            .collect::<Vec<_>>();
        let mut raw_result = RawOperationResult {
            touched_paths: ptr::null(),
            touched_path_count: 0,
            skipped_paths: ptr::null(),
            skipped_path_count: 0,
        };
        let mut cancel_baton = NativeCancelBaton {
            token: cancellation,
        };
        let cancel_callbacks = raw_cancel_callbacks(&mut cancel_baton);

        let status = unsafe {
            (self.symbols.operation_remove)(
                self.runtime.as_ptr(),
                path_ptrs.as_ptr(),
                path_ptrs.len(),
                request.force as c_int,
                request.keep_local as c_int,
                &cancel_callbacks,
                &mut raw_result,
            )
        };
        if status != 0 {
            return Err(self.with_native_diagnostics(operation_remove_failure(
                status,
                &identity.working_copy_root,
            )));
        }

        Ok(OperationResult {
            touched_paths: raw_operation_paths_to_protocol(
                raw_result.touched_paths,
                raw_result.touched_path_count,
                identity,
                "operation.touchedPaths",
            )?,
            skipped_paths: raw_operation_paths_to_protocol(
                raw_result.skipped_paths,
                raw_result.skipped_path_count,
                identity,
                "operation.skippedPaths",
            )?,
        })
    }

    fn operation_move_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &MoveOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        if !valid_move_scan_path(&request.source_path)
            || !valid_move_scan_path(&request.destination_path)
            || request.source_path == request.destination_path
        {
            return Err(BridgeFailure::invalid_path());
        }

        let source_path =
            CString::new(scan_path(&identity.working_copy_root, &request.source_path))
                .map_err(|_| BridgeFailure::invalid_path())?;
        let destination_path = CString::new(scan_path(
            &identity.working_copy_root,
            &request.destination_path,
        ))
        .map_err(|_| BridgeFailure::invalid_path())?;
        let mut raw_result = RawOperationResult {
            touched_paths: ptr::null(),
            touched_path_count: 0,
            skipped_paths: ptr::null(),
            skipped_path_count: 0,
        };
        let mut cancel_baton = NativeCancelBaton {
            token: cancellation,
        };
        let cancel_callbacks = raw_cancel_callbacks(&mut cancel_baton);

        let status = unsafe {
            (self.symbols.operation_move)(
                self.runtime.as_ptr(),
                source_path.as_ptr(),
                destination_path.as_ptr(),
                request.make_parents as c_int,
                &cancel_callbacks,
                &mut raw_result,
            )
        };
        if status != 0 {
            return Err(self.with_native_diagnostics(operation_move_failure(
                status,
                &request.source_path,
                &request.destination_path,
            )));
        }

        Ok(OperationResult {
            touched_paths: raw_operation_paths_to_protocol(
                raw_result.touched_paths,
                raw_result.touched_path_count,
                identity,
                "operation.touchedPaths",
            )?,
            skipped_paths: raw_operation_paths_to_protocol(
                raw_result.skipped_paths,
                raw_result.skipped_path_count,
                identity,
                "operation.skippedPaths",
            )?,
        })
    }

    fn operation_resolve_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &ResolveOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        if request.paths.len() != 1
            || !request.paths.iter().all(|path| valid_scan_path(path))
            || request.depth != "empty"
            || !valid_resolve_choice(&request.choice)
        {
            return Err(BridgeFailure::invalid_path());
        }

        let path_strings = request
            .paths
            .iter()
            .map(|path| CString::new(scan_path(&identity.working_copy_root, path)))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| BridgeFailure::invalid_path())?;
        let path_ptrs = path_strings
            .iter()
            .map(|path| path.as_ptr())
            .collect::<Vec<_>>();
        let depth_c =
            CString::new(request.depth.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let choice_c =
            CString::new(request.choice.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let mut raw_result = RawOperationResult {
            touched_paths: ptr::null(),
            touched_path_count: 0,
            skipped_paths: ptr::null(),
            skipped_path_count: 0,
        };
        let mut cancel_baton = NativeCancelBaton {
            token: cancellation,
        };
        let cancel_callbacks = raw_cancel_callbacks(&mut cancel_baton);

        let status = unsafe {
            (self.symbols.operation_resolve)(
                self.runtime.as_ptr(),
                path_ptrs.as_ptr(),
                path_ptrs.len(),
                depth_c.as_ptr(),
                choice_c.as_ptr(),
                &cancel_callbacks,
                &mut raw_result,
            )
        };
        if status != 0 {
            return Err(self.with_native_diagnostics(operation_resolve_failure(
                status,
                &identity.working_copy_root,
            )));
        }

        Ok(OperationResult {
            touched_paths: raw_operation_paths_to_protocol(
                raw_result.touched_paths,
                raw_result.touched_path_count,
                identity,
                "operation.touchedPaths",
            )?,
            skipped_paths: raw_operation_paths_to_protocol(
                raw_result.skipped_paths,
                raw_result.skipped_path_count,
                identity,
                "operation.skippedPaths",
            )?,
        })
    }

    fn operation_cleanup_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &CleanupOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        if request.path != "." {
            return Err(BridgeFailure::invalid_path());
        }

        let cleanup_path = scan_path(&identity.working_copy_root, &request.path);
        let path_c =
            CString::new(cleanup_path.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let mut raw_result = RawOperationResult {
            touched_paths: ptr::null(),
            touched_path_count: 0,
            skipped_paths: ptr::null(),
            skipped_path_count: 0,
        };
        let mut cancel_baton = NativeCancelBaton {
            token: cancellation,
        };
        let cancel_callbacks = raw_cancel_callbacks(&mut cancel_baton);

        let status = unsafe {
            (self.symbols.operation_cleanup)(
                self.runtime.as_ptr(),
                path_c.as_ptr(),
                request.break_locks as c_int,
                request.fix_recorded_timestamps as c_int,
                request.clear_dav_cache as c_int,
                request.vacuum_pristines as c_int,
                request.include_externals as c_int,
                &cancel_callbacks,
                &mut raw_result,
            )
        };
        if status != 0 {
            return Err(
                self.with_native_diagnostics(operation_cleanup_failure(status, &cleanup_path))
            );
        }

        Ok(OperationResult {
            touched_paths: raw_operation_paths_to_protocol(
                raw_result.touched_paths,
                raw_result.touched_path_count,
                identity,
                "operation.touchedPaths",
            )?,
            skipped_paths: raw_operation_paths_to_protocol(
                raw_result.skipped_paths,
                raw_result.skipped_path_count,
                identity,
                "operation.skippedPaths",
            )?,
        })
    }

    fn operation_upgrade_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &UpgradeOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        if request.path != "." {
            return Err(BridgeFailure::invalid_path());
        }

        let upgrade_path = scan_path(&identity.working_copy_root, &request.path);
        let path_c =
            CString::new(upgrade_path.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let mut raw_result = RawOperationResult {
            touched_paths: ptr::null(),
            touched_path_count: 0,
            skipped_paths: ptr::null(),
            skipped_path_count: 0,
        };
        let mut cancel_baton = NativeCancelBaton {
            token: cancellation,
        };
        let cancel_callbacks = raw_cancel_callbacks(&mut cancel_baton);

        let status = unsafe {
            (self.symbols.operation_upgrade)(
                self.runtime.as_ptr(),
                path_c.as_ptr(),
                &cancel_callbacks,
                &mut raw_result,
            )
        };
        if status != 0 {
            return Err(
                self.with_native_diagnostics(operation_upgrade_failure(status, &upgrade_path))
            );
        }

        Ok(OperationResult {
            touched_paths: raw_operation_paths_to_protocol(
                raw_result.touched_paths,
                raw_result.touched_path_count,
                identity,
                "operation.touchedPaths",
            )?,
            skipped_paths: raw_operation_paths_to_protocol(
                raw_result.skipped_paths,
                raw_result.skipped_path_count,
                identity,
                "operation.skippedPaths",
            )?,
        })
    }

    fn operation_update_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &UpdateOperationRequest,
        auth: &mut dyn AuthRequestBroker,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<UpdateOperationResult, BridgeFailure> {
        if !valid_update_revision(&request.revision)
            || !valid_update_depth(&request.depth)
            || (request.depth == "workingCopy" && request.depth_is_sticky)
        {
            return Err(BridgeFailure::invalid_path());
        }

        let update_path = update_scan_path(&identity.working_copy_root, &request.path)?;
        let path_c =
            CString::new(update_path.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let revision_c =
            CString::new(request.revision.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let depth_c =
            CString::new(request.depth.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let mut raw_result = RawOperationResult {
            touched_paths: ptr::null(),
            touched_path_count: 0,
            skipped_paths: ptr::null(),
            skipped_path_count: 0,
        };
        let mut raw_revision = -1_i64;
        let mut auth_baton = NativeAuthBaton::new(
            auth,
            Some(repository_id(identity)),
            Some(identity.working_copy_root.clone()),
        );
        let callbacks = RawAuthCallbacks {
            abi_version: RAW_AUTH_ABI_VERSION,
            baton: (&mut auth_baton as *mut NativeAuthBaton<'_>).cast::<c_void>(),
            credential_callback: Some(native_credential_callback),
            credential_response_dispose: Some(native_credential_response_dispose),
            certificate_callback: Some(native_certificate_callback),
        };
        let mut cancel_baton = NativeCancelBaton {
            token: cancellation,
        };
        let cancel_callbacks = raw_cancel_callbacks(&mut cancel_baton);

        let status = unsafe {
            (self.symbols.operation_update)(
                self.runtime.as_ptr(),
                path_c.as_ptr(),
                revision_c.as_ptr(),
                depth_c.as_ptr(),
                request.depth_is_sticky as c_int,
                request.ignore_externals as c_int,
                &callbacks,
                &cancel_callbacks,
                &mut raw_result,
                &mut raw_revision,
            )
        };
        if status != 0 {
            let native_failure =
                self.with_native_diagnostics(operation_update_failure(status, &update_path));
            if let Some(mut failure) = auth_baton.take_failure() {
                failure.diagnostics = native_failure.diagnostics;
                return Err(failure);
            }
            return Err(native_failure);
        }
        if raw_revision < 0 {
            return Err(native_invalid_response(&update_path, "operation.revision"));
        }

        Ok(UpdateOperationResult {
            result: OperationResult {
                touched_paths: raw_operation_paths_to_protocol(
                    raw_result.touched_paths,
                    raw_result.touched_path_count,
                    identity,
                    "operation.touchedPaths",
                )?,
                skipped_paths: raw_operation_paths_to_protocol(
                    raw_result.skipped_paths,
                    raw_result.skipped_path_count,
                    identity,
                    "operation.skippedPaths",
                )?,
            },
            revision: raw_revision,
        })
    }

    fn operation_property_set_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &PropertySetOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        if !valid_property_path(&request.path)
            || !valid_property_name(&request.name)
            || !valid_property_value(&request.value)
        {
            return Err(BridgeFailure::invalid_path());
        }

        let property_path = scan_path(&identity.working_copy_root, &request.path);
        let path_c =
            CString::new(property_path.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let name_c =
            CString::new(request.name.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let value_c =
            CString::new(request.value.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let mut raw_result = RawOperationResult {
            touched_paths: ptr::null(),
            touched_path_count: 0,
            skipped_paths: ptr::null(),
            skipped_path_count: 0,
        };
        let mut cancel_baton = NativeCancelBaton {
            token: cancellation,
        };
        let cancel_callbacks = raw_cancel_callbacks(&mut cancel_baton);

        let status = unsafe {
            (self.symbols.operation_property_set)(
                self.runtime.as_ptr(),
                path_c.as_ptr(),
                name_c.as_ptr(),
                value_c.as_ptr(),
                &cancel_callbacks,
                &mut raw_result,
            )
        };
        if status != 0 {
            return Err(
                self.with_native_diagnostics(operation_property_failure(status, &property_path))
            );
        }

        raw_operation_result_to_protocol(raw_result, identity)
    }

    fn operation_property_delete_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &PropertyDeleteOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        if !valid_property_path(&request.path) || !valid_property_name(&request.name) {
            return Err(BridgeFailure::invalid_path());
        }

        let property_path = scan_path(&identity.working_copy_root, &request.path);
        let path_c =
            CString::new(property_path.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let name_c =
            CString::new(request.name.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let mut raw_result = RawOperationResult {
            touched_paths: ptr::null(),
            touched_path_count: 0,
            skipped_paths: ptr::null(),
            skipped_path_count: 0,
        };
        let mut cancel_baton = NativeCancelBaton {
            token: cancellation,
        };
        let cancel_callbacks = raw_cancel_callbacks(&mut cancel_baton);

        let status = unsafe {
            (self.symbols.operation_property_delete)(
                self.runtime.as_ptr(),
                path_c.as_ptr(),
                name_c.as_ptr(),
                &cancel_callbacks,
                &mut raw_result,
            )
        };
        if status != 0 {
            return Err(
                self.with_native_diagnostics(operation_property_failure(status, &property_path))
            );
        }

        raw_operation_result_to_protocol(raw_result, identity)
    }

    fn operation_changelist_set_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &ChangelistSetOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        if request.paths.is_empty()
            || !request.paths.iter().all(|path| valid_changelist_path(path))
            || has_duplicate_paths(&request.paths)
            || !matches!(
                request.depth.as_str(),
                "empty" | "files" | "immediates" | "infinity"
            )
            || !valid_changelist(&request.changelist)
            || !request
                .changelists
                .iter()
                .all(|changelist| valid_changelist(changelist))
            || has_duplicate_paths(&request.changelists)
        {
            return Err(BridgeFailure::invalid_path());
        }

        let path_strings = request
            .paths
            .iter()
            .map(|path| CString::new(scan_path(&identity.working_copy_root, path)))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| BridgeFailure::invalid_path())?;
        let path_ptrs = path_strings
            .iter()
            .map(|path| path.as_ptr())
            .collect::<Vec<_>>();
        let depth_c =
            CString::new(request.depth.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let changelist_c =
            CString::new(request.changelist.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let changelist_strings = request
            .changelists
            .iter()
            .map(|changelist| CString::new(changelist.as_str()))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| BridgeFailure::invalid_path())?;
        let changelist_ptrs = changelist_strings
            .iter()
            .map(|changelist| changelist.as_ptr())
            .collect::<Vec<_>>();
        let changelist_ptr = if changelist_ptrs.is_empty() {
            ptr::null()
        } else {
            changelist_ptrs.as_ptr()
        };
        let mut raw_result = RawOperationResult {
            touched_paths: ptr::null(),
            touched_path_count: 0,
            skipped_paths: ptr::null(),
            skipped_path_count: 0,
        };
        let mut cancel_baton = NativeCancelBaton {
            token: cancellation,
        };
        let cancel_callbacks = raw_cancel_callbacks(&mut cancel_baton);

        let status = unsafe {
            (self.symbols.operation_changelist_set)(
                self.runtime.as_ptr(),
                path_ptrs.as_ptr(),
                path_ptrs.len(),
                depth_c.as_ptr(),
                changelist_c.as_ptr(),
                changelist_ptr,
                changelist_ptrs.len(),
                &cancel_callbacks,
                &mut raw_result,
            )
        };
        let failure_path = scan_path(&identity.working_copy_root, &request.paths[0]);
        if status != 0 {
            return Err(
                self.with_native_diagnostics(operation_changelist_failure(status, &failure_path))
            );
        }

        raw_operation_result_to_protocol(raw_result, identity)
    }

    fn operation_changelist_clear_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &ChangelistClearOperationRequest,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        if request.paths.is_empty()
            || !request.paths.iter().all(|path| valid_changelist_path(path))
            || has_duplicate_paths(&request.paths)
            || !matches!(
                request.depth.as_str(),
                "empty" | "files" | "immediates" | "infinity"
            )
            || !request
                .changelists
                .iter()
                .all(|changelist| valid_changelist(changelist))
            || has_duplicate_paths(&request.changelists)
        {
            return Err(BridgeFailure::invalid_path());
        }

        let path_strings = request
            .paths
            .iter()
            .map(|path| CString::new(scan_path(&identity.working_copy_root, path)))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| BridgeFailure::invalid_path())?;
        let path_ptrs = path_strings
            .iter()
            .map(|path| path.as_ptr())
            .collect::<Vec<_>>();
        let depth_c =
            CString::new(request.depth.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let changelist_strings = request
            .changelists
            .iter()
            .map(|changelist| CString::new(changelist.as_str()))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| BridgeFailure::invalid_path())?;
        let changelist_ptrs = changelist_strings
            .iter()
            .map(|changelist| changelist.as_ptr())
            .collect::<Vec<_>>();
        let changelist_ptr = if changelist_ptrs.is_empty() {
            ptr::null()
        } else {
            changelist_ptrs.as_ptr()
        };
        let mut raw_result = RawOperationResult {
            touched_paths: ptr::null(),
            touched_path_count: 0,
            skipped_paths: ptr::null(),
            skipped_path_count: 0,
        };
        let mut cancel_baton = NativeCancelBaton {
            token: cancellation,
        };
        let cancel_callbacks = raw_cancel_callbacks(&mut cancel_baton);

        let status = unsafe {
            (self.symbols.operation_changelist_clear)(
                self.runtime.as_ptr(),
                path_ptrs.as_ptr(),
                path_ptrs.len(),
                depth_c.as_ptr(),
                changelist_ptr,
                changelist_ptrs.len(),
                &cancel_callbacks,
                &mut raw_result,
            )
        };
        let failure_path = scan_path(&identity.working_copy_root, &request.paths[0]);
        if status != 0 {
            return Err(
                self.with_native_diagnostics(operation_changelist_failure(status, &failure_path))
            );
        }

        raw_operation_result_to_protocol(raw_result, identity)
    }

    fn operation_lock_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &LockOperationRequest,
        auth: &mut dyn AuthRequestBroker,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        if request.paths.is_empty()
            || !request.paths.iter().all(|path| valid_lock_scan_path(path))
            || has_duplicate_paths(&request.paths)
            || request
                .comment
                .as_ref()
                .is_some_and(|comment| !valid_lock_comment(comment))
        {
            return Err(BridgeFailure::invalid_path());
        }

        let path_strings = request
            .paths
            .iter()
            .map(|path| CString::new(scan_path(&identity.working_copy_root, path)))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| BridgeFailure::invalid_path())?;
        let path_ptrs = path_strings
            .iter()
            .map(|path| path.as_ptr())
            .collect::<Vec<_>>();
        let comment_c = request
            .comment
            .as_ref()
            .map(|comment| CString::new(comment.as_str()))
            .transpose()
            .map_err(|_| BridgeFailure::invalid_path())?;
        let comment_ptr = comment_c
            .as_ref()
            .map_or(ptr::null(), |comment| comment.as_ptr());
        let mut raw_result = RawOperationResult {
            touched_paths: ptr::null(),
            touched_path_count: 0,
            skipped_paths: ptr::null(),
            skipped_path_count: 0,
        };
        let mut auth_baton = NativeAuthBaton::new(
            auth,
            Some(repository_id(identity)),
            Some(identity.working_copy_root.clone()),
        );
        let callbacks = RawAuthCallbacks {
            abi_version: RAW_AUTH_ABI_VERSION,
            baton: (&mut auth_baton as *mut NativeAuthBaton<'_>).cast::<c_void>(),
            credential_callback: Some(native_credential_callback),
            credential_response_dispose: Some(native_credential_response_dispose),
            certificate_callback: Some(native_certificate_callback),
        };
        let mut cancel_baton = NativeCancelBaton {
            token: cancellation,
        };
        let cancel_callbacks = raw_cancel_callbacks(&mut cancel_baton);

        let status = unsafe {
            (self.symbols.operation_lock)(
                self.runtime.as_ptr(),
                path_ptrs.as_ptr(),
                path_ptrs.len(),
                comment_ptr,
                request.steal_lock as c_int,
                &callbacks,
                &cancel_callbacks,
                &mut raw_result,
            )
        };
        let failure_path = scan_path(&identity.working_copy_root, &request.paths[0]);
        if status != 0 {
            let native_failure =
                self.with_native_diagnostics(operation_lock_failure(status, &failure_path));
            if let Some(mut failure) = auth_baton.take_failure() {
                failure.diagnostics = native_failure.diagnostics;
                return Err(failure);
            }
            return Err(native_failure);
        }

        raw_operation_result_to_protocol(raw_result, identity)
    }

    fn operation_unlock_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &UnlockOperationRequest,
        auth: &mut dyn AuthRequestBroker,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        if request.paths.is_empty()
            || !request.paths.iter().all(|path| valid_lock_scan_path(path))
            || has_duplicate_paths(&request.paths)
        {
            return Err(BridgeFailure::invalid_path());
        }

        let path_strings = request
            .paths
            .iter()
            .map(|path| CString::new(scan_path(&identity.working_copy_root, path)))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| BridgeFailure::invalid_path())?;
        let path_ptrs = path_strings
            .iter()
            .map(|path| path.as_ptr())
            .collect::<Vec<_>>();
        let mut raw_result = RawOperationResult {
            touched_paths: ptr::null(),
            touched_path_count: 0,
            skipped_paths: ptr::null(),
            skipped_path_count: 0,
        };
        let mut auth_baton = NativeAuthBaton::new(
            auth,
            Some(repository_id(identity)),
            Some(identity.working_copy_root.clone()),
        );
        let callbacks = RawAuthCallbacks {
            abi_version: RAW_AUTH_ABI_VERSION,
            baton: (&mut auth_baton as *mut NativeAuthBaton<'_>).cast::<c_void>(),
            credential_callback: Some(native_credential_callback),
            credential_response_dispose: Some(native_credential_response_dispose),
            certificate_callback: Some(native_certificate_callback),
        };
        let mut cancel_baton = NativeCancelBaton {
            token: cancellation,
        };
        let cancel_callbacks = raw_cancel_callbacks(&mut cancel_baton);

        let status = unsafe {
            (self.symbols.operation_unlock)(
                self.runtime.as_ptr(),
                path_ptrs.as_ptr(),
                path_ptrs.len(),
                request.break_lock as c_int,
                &callbacks,
                &cancel_callbacks,
                &mut raw_result,
            )
        };
        let failure_path = scan_path(&identity.working_copy_root, &request.paths[0]);
        if status != 0 {
            let native_failure =
                self.with_native_diagnostics(operation_unlock_failure(status, &failure_path));
            if let Some(mut failure) = auth_baton.take_failure() {
                failure.diagnostics = native_failure.diagnostics;
                return Err(failure);
            }
            return Err(native_failure);
        }

        raw_operation_result_to_protocol(raw_result, identity)
    }

    fn operation_branch_create_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &BranchCreateOperationRequest,
        auth: &mut dyn AuthRequestBroker,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<BranchCreateOperationResult, BridgeFailure> {
        if !valid_branch_url(&request.source_url)
            || !valid_branch_url(&request.destination_url)
            || request.source_url == request.destination_url
            || !valid_update_revision(&request.revision)
            || !valid_commit_message(&request.message)
        {
            return Err(BridgeFailure::invalid_path());
        }

        let source_url_c =
            CString::new(request.source_url.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let working_copy_root_c = CString::new(identity.working_copy_root.as_str())
            .map_err(|_| BridgeFailure::invalid_path())?;
        let destination_url_c = CString::new(request.destination_url.as_str())
            .map_err(|_| BridgeFailure::invalid_path())?;
        let revision_c =
            CString::new(request.revision.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let message_c =
            CString::new(request.message.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let mut raw_result = RawOperationResult {
            touched_paths: ptr::null(),
            touched_path_count: 0,
            skipped_paths: ptr::null(),
            skipped_path_count: 0,
        };
        let mut raw_revision = -1_i64;
        let mut auth_baton = NativeAuthBaton::new(
            auth,
            Some(repository_id(identity)),
            Some(identity.working_copy_root.clone()),
        );
        let callbacks = RawAuthCallbacks {
            abi_version: RAW_AUTH_ABI_VERSION,
            baton: (&mut auth_baton as *mut NativeAuthBaton<'_>).cast::<c_void>(),
            credential_callback: Some(native_credential_callback),
            credential_response_dispose: Some(native_credential_response_dispose),
            certificate_callback: Some(native_certificate_callback),
        };
        let mut cancel_baton = NativeCancelBaton {
            token: cancellation,
        };
        let cancel_callbacks = raw_cancel_callbacks(&mut cancel_baton);

        let status = unsafe {
            (self.symbols.operation_branch_create)(
                self.runtime.as_ptr(),
                working_copy_root_c.as_ptr(),
                source_url_c.as_ptr(),
                destination_url_c.as_ptr(),
                revision_c.as_ptr(),
                message_c.as_ptr(),
                request.make_parents as c_int,
                request.ignore_externals as c_int,
                &callbacks,
                &cancel_callbacks,
                &mut raw_result,
                &mut raw_revision,
            )
        };
        if status != 0 {
            let native_failure = self.with_native_diagnostics(operation_branch_create_failure(
                status,
                &request.destination_url,
            ));
            if let Some(mut failure) = auth_baton.take_failure() {
                failure.diagnostics = native_failure.diagnostics;
                return Err(failure);
            }
            return Err(native_failure);
        }
        if raw_revision < 0 {
            return Err(native_invalid_response(
                &request.destination_url,
                "operation.revision",
            ));
        }

        Ok(BranchCreateOperationResult {
            result: OperationResult {
                touched_paths: Vec::new(),
                skipped_paths: raw_operation_paths_to_protocol(
                    raw_result.skipped_paths,
                    raw_result.skipped_path_count,
                    identity,
                    "operation.skippedPaths",
                )?,
            },
            revision: raw_revision,
        })
    }

    fn operation_switch_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &SwitchOperationRequest,
        auth: &mut dyn AuthRequestBroker,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<SwitchOperationResult, BridgeFailure> {
        if !valid_update_path(&request.path)
            || !valid_branch_url(&request.url)
            || !valid_update_revision(&request.revision)
            || !valid_update_depth(&request.depth)
            || (request.depth == "workingCopy" && request.depth_is_sticky)
        {
            return Err(BridgeFailure::invalid_path());
        }

        let switch_path = update_scan_path(&identity.working_copy_root, &request.path)?;
        let path_c =
            CString::new(switch_path.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let url_c =
            CString::new(request.url.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let revision_c =
            CString::new(request.revision.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let depth_c =
            CString::new(request.depth.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let mut raw_result = RawOperationResult {
            touched_paths: ptr::null(),
            touched_path_count: 0,
            skipped_paths: ptr::null(),
            skipped_path_count: 0,
        };
        let mut raw_revision = -1_i64;
        let mut auth_baton = NativeAuthBaton::new(
            auth,
            Some(repository_id(identity)),
            Some(identity.working_copy_root.clone()),
        );
        let callbacks = RawAuthCallbacks {
            abi_version: RAW_AUTH_ABI_VERSION,
            baton: (&mut auth_baton as *mut NativeAuthBaton<'_>).cast::<c_void>(),
            credential_callback: Some(native_credential_callback),
            credential_response_dispose: Some(native_credential_response_dispose),
            certificate_callback: Some(native_certificate_callback),
        };
        let mut cancel_baton = NativeCancelBaton {
            token: cancellation,
        };
        let cancel_callbacks = raw_cancel_callbacks(&mut cancel_baton);

        let status = unsafe {
            (self.symbols.operation_switch)(
                self.runtime.as_ptr(),
                path_c.as_ptr(),
                url_c.as_ptr(),
                revision_c.as_ptr(),
                depth_c.as_ptr(),
                request.depth_is_sticky as c_int,
                request.ignore_externals as c_int,
                request.ignore_ancestry as c_int,
                &callbacks,
                &cancel_callbacks,
                &mut raw_result,
                &mut raw_revision,
            )
        };
        if status != 0 {
            let native_failure =
                self.with_native_diagnostics(operation_switch_failure(status, &switch_path));
            if let Some(mut failure) = auth_baton.take_failure() {
                failure.diagnostics = native_failure.diagnostics;
                return Err(failure);
            }
            return Err(native_failure);
        }
        if raw_revision < 0 {
            return Err(native_invalid_response(&switch_path, "operation.revision"));
        }

        Ok(SwitchOperationResult {
            result: raw_operation_result_to_protocol(raw_result, identity)?,
            revision: raw_revision,
        })
    }

    fn operation_relocate_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &RelocateOperationRequest,
        auth: &mut dyn AuthRequestBroker,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        if !valid_branch_url(&request.from_url)
            || !valid_branch_url(&request.to_url)
            || request.from_url == request.to_url
        {
            return Err(BridgeFailure::invalid_path());
        }

        let working_copy_root_c = CString::new(identity.working_copy_root.as_str())
            .map_err(|_| BridgeFailure::invalid_path())?;
        let from_url_c =
            CString::new(request.from_url.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let to_url_c =
            CString::new(request.to_url.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let mut raw_result = RawOperationResult {
            touched_paths: ptr::null(),
            touched_path_count: 0,
            skipped_paths: ptr::null(),
            skipped_path_count: 0,
        };
        let mut auth_baton = NativeAuthBaton::new(
            auth,
            Some(repository_id(identity)),
            Some(identity.working_copy_root.clone()),
        );
        let callbacks = RawAuthCallbacks {
            abi_version: RAW_AUTH_ABI_VERSION,
            baton: (&mut auth_baton as *mut NativeAuthBaton<'_>).cast::<c_void>(),
            credential_callback: Some(native_credential_callback),
            credential_response_dispose: Some(native_credential_response_dispose),
            certificate_callback: Some(native_certificate_callback),
        };
        let mut cancel_baton = NativeCancelBaton {
            token: cancellation,
        };
        let cancel_callbacks = raw_cancel_callbacks(&mut cancel_baton);

        let status = unsafe {
            (self.symbols.operation_relocate)(
                self.runtime.as_ptr(),
                working_copy_root_c.as_ptr(),
                from_url_c.as_ptr(),
                to_url_c.as_ptr(),
                request.ignore_externals as c_int,
                &callbacks,
                &cancel_callbacks,
                &mut raw_result,
            )
        };
        if status != 0 {
            let native_failure = self.with_native_diagnostics(operation_relocate_failure(
                status,
                &identity.working_copy_root,
            ));
            if let Some(mut failure) = auth_baton.take_failure() {
                failure.diagnostics = native_failure.diagnostics;
                return Err(failure);
            }
            return Err(native_failure);
        }

        raw_operation_result_to_protocol(raw_result, identity)
    }

    fn operation_merge_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &MergeOperationRequest,
        auth: &mut dyn AuthRequestBroker,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<OperationResult, BridgeFailure> {
        if !valid_branch_url(&request.source_url)
            || !valid_update_path(&request.target_path)
            || !valid_merge_revision(request.start_revision)
            || !valid_merge_revision(request.end_revision)
            || request.start_revision == request.end_revision
            || !valid_merge_depth(&request.depth)
        {
            return Err(BridgeFailure::invalid_path());
        }

        let target_path = update_scan_path(&identity.working_copy_root, &request.target_path)?;
        let source_url_c =
            CString::new(request.source_url.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let target_path_c =
            CString::new(target_path.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let depth_c =
            CString::new(request.depth.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let mut raw_result = RawOperationResult {
            touched_paths: ptr::null(),
            touched_path_count: 0,
            skipped_paths: ptr::null(),
            skipped_path_count: 0,
        };
        let mut auth_baton = NativeAuthBaton::new(
            auth,
            Some(repository_id(identity)),
            Some(identity.working_copy_root.clone()),
        );
        let callbacks = RawAuthCallbacks {
            abi_version: RAW_AUTH_ABI_VERSION,
            baton: (&mut auth_baton as *mut NativeAuthBaton<'_>).cast::<c_void>(),
            credential_callback: Some(native_credential_callback),
            credential_response_dispose: Some(native_credential_response_dispose),
            certificate_callback: Some(native_certificate_callback),
        };
        let mut cancel_baton = NativeCancelBaton {
            token: cancellation,
        };
        let cancel_callbacks = raw_cancel_callbacks(&mut cancel_baton);

        let status = unsafe {
            (self.symbols.operation_merge_range)(
                self.runtime.as_ptr(),
                source_url_c.as_ptr(),
                target_path_c.as_ptr(),
                request.start_revision,
                request.end_revision,
                depth_c.as_ptr(),
                request.ignore_mergeinfo as c_int,
                request.diff_ignore_ancestry as c_int,
                request.force_delete as c_int,
                request.record_only as c_int,
                request.dry_run as c_int,
                request.allow_mixed_revisions as c_int,
                &callbacks,
                &cancel_callbacks,
                &mut raw_result,
            )
        };
        if status != 0 {
            let native_failure =
                self.with_native_diagnostics(operation_merge_failure(status, &target_path));
            if let Some(mut failure) = auth_baton.take_failure() {
                failure.diagnostics = native_failure.diagnostics;
                return Err(failure);
            }
            return Err(native_failure);
        }

        raw_operation_result_to_protocol(raw_result, identity)
    }

    fn operation_commit_with_cancellation(
        &self,
        identity: &RepositoryIdentity,
        request: &CommitOperationRequest,
        auth: &mut dyn AuthRequestBroker,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<CommitOperationResult, BridgeFailure> {
        if request.paths.is_empty()
            || !request
                .paths
                .iter()
                .all(|path| valid_commit_scan_path(path))
            || has_duplicate_paths(&request.paths)
            || !valid_commit_message(&request.message)
            || request.depth != "empty"
            || !request
                .changelists
                .iter()
                .all(|changelist| valid_changelist(changelist))
            || has_duplicate_paths(&request.changelists)
            || request.keep_locks
            || request.keep_changelists
            || request.commit_as_operations
            || request.include_file_externals
            || request.include_dir_externals
        {
            return Err(BridgeFailure::invalid_path());
        }

        let path_strings = request
            .paths
            .iter()
            .map(|path| CString::new(scan_path(&identity.working_copy_root, path)))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| BridgeFailure::invalid_path())?;
        let path_ptrs = path_strings
            .iter()
            .map(|path| path.as_ptr())
            .collect::<Vec<_>>();
        let message_c =
            CString::new(request.message.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let depth_c =
            CString::new(request.depth.as_str()).map_err(|_| BridgeFailure::invalid_path())?;
        let changelist_strings = request
            .changelists
            .iter()
            .map(|changelist| CString::new(changelist.as_str()))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| BridgeFailure::invalid_path())?;
        let changelist_ptrs = changelist_strings
            .iter()
            .map(|changelist| changelist.as_ptr())
            .collect::<Vec<_>>();
        let changelist_ptr = if changelist_ptrs.is_empty() {
            ptr::null()
        } else {
            changelist_ptrs.as_ptr()
        };
        let mut raw_result = RawOperationResult {
            touched_paths: ptr::null(),
            touched_path_count: 0,
            skipped_paths: ptr::null(),
            skipped_path_count: 0,
        };
        let mut raw_revision = -1_i64;
        let mut auth_baton = NativeAuthBaton::new(
            auth,
            Some(repository_id(identity)),
            Some(identity.working_copy_root.clone()),
        );
        let callbacks = RawAuthCallbacks {
            abi_version: RAW_AUTH_ABI_VERSION,
            baton: (&mut auth_baton as *mut NativeAuthBaton<'_>).cast::<c_void>(),
            credential_callback: Some(native_credential_callback),
            credential_response_dispose: Some(native_credential_response_dispose),
            certificate_callback: Some(native_certificate_callback),
        };
        let mut cancel_baton = NativeCancelBaton {
            token: cancellation,
        };
        let cancel_callbacks = raw_cancel_callbacks(&mut cancel_baton);

        let status = unsafe {
            (self.symbols.operation_commit)(
                self.runtime.as_ptr(),
                path_ptrs.as_ptr(),
                path_ptrs.len(),
                message_c.as_ptr(),
                depth_c.as_ptr(),
                changelist_ptr,
                changelist_ptrs.len(),
                request.keep_locks as c_int,
                request.keep_changelists as c_int,
                request.commit_as_operations as c_int,
                request.include_file_externals as c_int,
                request.include_dir_externals as c_int,
                &callbacks,
                &cancel_callbacks,
                &mut raw_result,
                &mut raw_revision,
            )
        };
        let commit_path = scan_path(&identity.working_copy_root, &request.paths[0]);
        if status != 0 {
            let native_failure =
                self.with_native_diagnostics(operation_commit_failure(status, &commit_path));
            if let Some(mut failure) = auth_baton.take_failure() {
                failure.diagnostics = native_failure.diagnostics;
                return Err(failure);
            }
            return Err(native_failure);
        }
        if raw_revision < 0 {
            return Err(native_invalid_response(&commit_path, "operation.revision"));
        }

        Ok(CommitOperationResult {
            result: OperationResult {
                touched_paths: raw_operation_paths_to_protocol(
                    raw_result.touched_paths,
                    raw_result.touched_path_count,
                    identity,
                    "operation.touchedPaths",
                )?,
                skipped_paths: raw_operation_paths_to_protocol(
                    raw_result.skipped_paths,
                    raw_result.skipped_path_count,
                    identity,
                    "operation.skippedPaths",
                )?,
            },
            revision: raw_revision,
        })
    }
}

impl Drop for NativeBridge {
    fn drop(&mut self) {
        unsafe {
            (self.symbols.runtime_destroy)(self.runtime.as_ptr());
        }
    }
}

#[cfg(windows)]
unsafe fn load_library(path: &Path) -> Result<Library, libloading::Error> {
    use libloading::os::windows::{
        LOAD_LIBRARY_SEARCH_DEFAULT_DIRS, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR,
        Library as WindowsLibrary,
    };

    let flags = LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS;
    unsafe { WindowsLibrary::load_with_flags(path, flags) }.map(Into::into)
}

#[cfg(not(windows))]
unsafe fn load_library(path: &Path) -> Result<Library, libloading::Error> {
    unsafe { Library::new(path) }
}

struct NativeAuthBaton<'a> {
    auth: &'a mut dyn AuthRequestBroker,
    repository_id: Option<String>,
    working_copy_root: Option<String>,
    failure: Option<BridgeFailure>,
}

impl<'a> NativeAuthBaton<'a> {
    fn new(
        auth: &'a mut dyn AuthRequestBroker,
        repository_id: Option<String>,
        working_copy_root: Option<String>,
    ) -> Self {
        Self {
            auth,
            repository_id,
            working_copy_root,
            failure: None,
        }
    }

    fn request_id(&mut self, kind: &str) -> String {
        let id = NEXT_NATIVE_AUTH_REQUEST_ID.fetch_add(1, Ordering::Relaxed);
        format!("native-{kind}-{id}")
    }

    fn record_failure(&mut self, failure: BridgeFailure) {
        self.failure = Some(failure);
    }

    fn take_failure(&mut self) -> Option<BridgeFailure> {
        self.failure.take()
    }

    #[cfg(test)]
    fn failure(&self) -> Option<&BridgeFailure> {
        self.failure.as_ref()
    }
}

struct RemoteCredentialBaton<'a> {
    auth: &'a mut dyn AuthRequestBroker,
    envelope: &'a RemoteOperationEnvelope,
    deadline: Instant,
    failure: Option<BridgeFailure>,
}

impl RemoteCredentialBaton<'_> {
    fn request_id(&self, kind: &str) -> String {
        let id = NEXT_NATIVE_AUTH_REQUEST_ID.fetch_add(1, Ordering::Relaxed);
        format!("remote-{kind}-{id}")
    }

    fn record_failure(&mut self, failure: BridgeFailure) {
        if self.failure.is_none() {
            self.failure = Some(failure);
        }
    }

    fn take_failure(&mut self) -> Option<BridgeFailure> {
        self.failure.take()
    }

    fn remaining_timeout_ms(&self, method: &str) -> Result<u64, BridgeFailure> {
        let remaining = self
            .deadline
            .checked_duration_since(Instant::now())
            .ok_or_else(|| remote_credential_timeout(method))?;
        let millis = remaining.as_millis().min(u64::MAX as u128) as u64;
        if millis == 0 {
            return Err(remote_credential_timeout(method));
        }
        Ok(millis)
    }
}

unsafe extern "C" fn remote_credential_callback_v2(
    baton: *mut c_void,
    request: *const RawRemoteCredentialRequestV2,
    response: *mut RawRemoteCredentialResponseV2,
) -> c_int {
    match catch_unwind(AssertUnwindSafe(|| unsafe {
        remote_credential_callback_v2_inner(baton, request, response)
    })) {
        Ok(status) => status,
        Err(_) => unsafe {
            dispose_raw_remote_credential_response_v2(response);
            record_remote_credential_failure(
                baton,
                native_auth_response_invalid("credentials/request"),
            );
            RAW_AUTH_CALLBACK_DENIED
        },
    }
}

unsafe fn remote_credential_callback_v2_inner(
    baton: *mut c_void,
    request: *const RawRemoteCredentialRequestV2,
    response: *mut RawRemoteCredentialResponseV2,
) -> c_int {
    if baton.is_null() || request.is_null() || response.is_null() {
        return RAW_AUTH_CALLBACK_INVALID;
    }
    unsafe { write_empty_remote_credential_response_v2(response) };
    let auth_baton = unsafe { &mut *(baton.cast::<RemoteCredentialBaton<'_>>()) };
    let raw = unsafe { &*request };
    let realm = match unsafe { optional_c_string_to_owned(raw.realm, "remoteCredential.realm") } {
        Ok(Some(realm)) if !realm.is_empty() && realm.len() <= 4096 => realm,
        _ => {
            auth_baton.record_failure(native_auth_response_invalid("credentials/request"));
            return RAW_AUTH_CALLBACK_DENIED;
        }
    };
    let suggested_username = match unsafe {
        optional_c_string_to_owned(raw.suggested_username, "remoteCredential.suggestedUsername")
    } {
        Ok(value) => value,
        Err(_) => {
            auth_baton.record_failure(native_auth_response_invalid("credentials/request"));
            return RAW_AUTH_CALLBACK_DENIED;
        }
    };
    let account = match &auth_baton.envelope.profile.server_account {
        ServerAccountSnapshot::Selection(account) => account.clone(),
        ServerAccountSnapshot::None(_) => {
            auth_baton.record_failure(native_auth_response_invalid("credentials/request"));
            return RAW_AUTH_CALLBACK_DENIED;
        }
    };
    if let (ServerAccountSelection::Fixed { username }, Some(suggested)) =
        (&account, suggested_username.as_ref())
        && username != suggested
    {
        auth_baton.record_failure(native_auth_response_invalid("credentials/request"));
        return RAW_AUTH_CALLBACK_DENIED;
    }
    let attempt = match raw.attempt {
        0 if raw.previous_lease_id.is_null() => CredentialAttempt::Initial,
        1 => {
            let previous_lease_id = match unsafe {
                optional_c_string_to_owned(
                    raw.previous_lease_id,
                    "remoteCredential.previousLeaseId",
                )
            } {
                Ok(Some(value)) if !value.is_empty() && value.len() <= 128 => value,
                _ => {
                    auth_baton.record_failure(native_auth_response_invalid("credentials/request"));
                    return RAW_AUTH_CALLBACK_DENIED;
                }
            };
            CredentialAttempt::RetryAfterRejected { previous_lease_id }
        }
        _ => {
            auth_baton.record_failure(native_auth_response_invalid("credentials/request"));
            return RAW_AUTH_CALLBACK_DENIED;
        }
    };
    let auth_kind = match auth_baton.envelope.profile.server_auth {
        RemoteServerAuth::Basic => CredentialAuthKind::Basic,
        RemoteServerAuth::CramMd5 => CredentialAuthKind::CramMd5,
        _ => {
            auth_baton.record_failure(native_auth_response_invalid("credentials/request"));
            return RAW_AUTH_CALLBACK_DENIED;
        }
    };
    let timeout_ms = match auth_baton.remaining_timeout_ms("credentials/request") {
        Ok(timeout_ms) => timeout_ms,
        Err(failure) => {
            auth_baton.record_failure(failure);
            return RAW_AUTH_CALLBACK_DENIED;
        }
    };
    let request_id = auth_baton.request_id("credential");
    let protocol_request = CredentialRequest {
        request_id: request_id.clone(),
        operation_id: auth_baton.envelope.operation_id.clone(),
        endpoint: auth_baton.envelope.expected_origin.clone(),
        auth_kind,
        realm,
        account,
        attempt,
        interactive: matches!(auth_baton.envelope.interaction, RemoteInteraction::Allowed),
        persistence_allowed: true,
        origin: auth_baton.envelope.intent,
        timeout_ms,
    };
    let safe_args = credential_safe_args(&protocol_request);
    match auth_baton.auth.request_credential(protocol_request) {
        Ok(CredentialResponse::Provide {
            request_id: response_request_id,
            operation_id,
            lease_id,
            credential,
            persistence_intent,
        }) if response_request_id == request_id
            && operation_id == auth_baton.envelope.operation_id
            && valid_remote_username(&credential.username)
            && !credential.secret.is_empty()
            && credential.secret.len() <= 32768
            && !lease_id.is_empty()
            && lease_id.len() <= 128 =>
        {
            if matches!(
                &auth_baton.envelope.profile.server_account,
                ServerAccountSnapshot::Selection(ServerAccountSelection::Fixed { username })
                    if &credential.username != username
            ) {
                auth_baton.record_failure(native_auth_response_invalid("credentials/request"));
                return RAW_AUTH_CALLBACK_DENIED;
            }
            let username = match CString::new(credential.username) {
                Ok(value) => value,
                Err(_) => {
                    auth_baton.record_failure(native_auth_response_invalid("credentials/request"));
                    return RAW_AUTH_CALLBACK_DENIED;
                }
            };
            let secret = match CString::new(credential.secret) {
                Ok(value) => value,
                Err(_) => {
                    auth_baton.record_failure(native_auth_response_invalid("credentials/request"));
                    return RAW_AUTH_CALLBACK_DENIED;
                }
            };
            let lease_id = match CString::new(lease_id) {
                Ok(value) => value,
                Err(_) => {
                    auth_baton.record_failure(native_auth_response_invalid("credentials/request"));
                    return RAW_AUTH_CALLBACK_DENIED;
                }
            };
            unsafe {
                (*response).username = username.into_raw();
                (*response).secret = secret.into_raw();
                (*response).lease_id = lease_id.into_raw();
                (*response).persistence_requested = i32::from(matches!(
                    persistence_intent,
                    CredentialPersistenceIntent::SecretStorage
                ));
            }
            RAW_AUTH_CALLBACK_OK
        }
        Ok(CredentialResponse::Cancel {
            request_id: response_request_id,
            operation_id,
            error,
        }) if response_request_id == request_id
            && operation_id == auth_baton.envelope.operation_id =>
        {
            auth_baton.record_failure(credential_error_to_bridge(&error, safe_args));
            RAW_AUTH_CALLBACK_DENIED
        }
        Ok(_) => {
            auth_baton.record_failure(native_auth_response_invalid("credentials/request"));
            RAW_AUTH_CALLBACK_DENIED
        }
        Err(failure) => {
            auth_baton.record_failure(failure);
            RAW_AUTH_CALLBACK_DENIED
        }
    }
}

unsafe extern "C" fn remote_credential_response_dispose_v2(
    _baton: *mut c_void,
    response: *mut RawRemoteCredentialResponseV2,
) {
    unsafe { dispose_raw_remote_credential_response_v2(response) };
}

unsafe fn write_empty_remote_credential_response_v2(response: *mut RawRemoteCredentialResponseV2) {
    if !response.is_null() {
        unsafe {
            *response = RawRemoteCredentialResponseV2 {
                username: ptr::null(),
                secret: ptr::null(),
                lease_id: ptr::null(),
                persistence_requested: 0,
            };
        }
    }
}

unsafe fn dispose_raw_remote_credential_response_v2(response: *mut RawRemoteCredentialResponseV2) {
    if response.is_null() {
        return;
    }
    let response = unsafe { &mut *response };
    unsafe {
        drop_c_string(response.username, false);
        drop_c_string(response.secret, true);
        drop_c_string(response.lease_id, false);
    }
    response.username = ptr::null();
    response.secret = ptr::null();
    response.lease_id = ptr::null();
    response.persistence_requested = 0;
}

unsafe extern "C" fn remote_credential_settlement_callback_v2(
    baton: *mut c_void,
    lease_id: *const c_char,
    outcome: u32,
) -> c_int {
    match catch_unwind(AssertUnwindSafe(|| unsafe {
        remote_credential_settlement_callback_v2_inner(baton, lease_id, outcome)
    })) {
        Ok(status) => status,
        Err(_) => unsafe {
            record_remote_credential_failure(
                baton,
                native_auth_response_invalid("credentials/settle"),
            );
            RAW_AUTH_CALLBACK_DENIED
        },
    }
}

unsafe fn remote_credential_settlement_callback_v2_inner(
    baton: *mut c_void,
    lease_id: *const c_char,
    outcome: u32,
) -> c_int {
    if baton.is_null() {
        return RAW_AUTH_CALLBACK_INVALID;
    }
    let auth_baton = unsafe { &mut *(baton.cast::<RemoteCredentialBaton<'_>>()) };
    let lease_id = match unsafe { optional_c_string_to_owned(lease_id, "settlement.leaseId") } {
        Ok(Some(value)) if !value.is_empty() && value.len() <= 128 => value,
        _ => {
            auth_baton.record_failure(native_auth_response_invalid("credentials/settle"));
            return RAW_AUTH_CALLBACK_DENIED;
        }
    };
    let outcome = match raw_settlement_outcome(outcome) {
        Some(outcome) => outcome,
        None => {
            auth_baton.record_failure(native_auth_response_invalid("credentials/settle"));
            return RAW_AUTH_CALLBACK_DENIED;
        }
    };
    let timeout_ms = match auth_baton.remaining_timeout_ms("credentials/settle") {
        Ok(timeout_ms) => timeout_ms,
        Err(failure) => {
            auth_baton.record_failure(failure);
            return RAW_AUTH_CALLBACK_DENIED;
        }
    };
    let request_id = auth_baton.request_id("settlement");
    let request = CredentialSettlementRequest {
        request_id: request_id.clone(),
        operation_id: auth_baton.envelope.operation_id.clone(),
        lease_id: lease_id.clone(),
        outcome,
        timeout_ms,
    };
    match auth_baton.auth.settle_credential(request) {
        Ok(CredentialSettlementAck {
            request_id: ack_request_id,
            operation_id,
            lease_id: ack_lease_id,
            outcome: ack_outcome,
        }) if ack_request_id == request_id
            && operation_id == auth_baton.envelope.operation_id
            && ack_lease_id == lease_id
            && ack_outcome == outcome =>
        {
            RAW_AUTH_CALLBACK_OK
        }
        Ok(_) => {
            auth_baton.record_failure(native_auth_response_invalid("credentials/settle"));
            RAW_AUTH_CALLBACK_DENIED
        }
        Err(failure) => {
            auth_baton.record_failure(failure);
            RAW_AUTH_CALLBACK_DENIED
        }
    }
}

unsafe fn record_remote_credential_failure(baton: *mut c_void, failure: BridgeFailure) {
    if !baton.is_null() {
        unsafe { &mut *(baton.cast::<RemoteCredentialBaton<'_>>()) }.record_failure(failure);
    }
}

fn raw_settlement_outcome(value: u32) -> Option<CredentialSettlementOutcome> {
    match value {
        1 => Some(CredentialSettlementOutcome::Accepted),
        2 => Some(CredentialSettlementOutcome::Rejected),
        3 => Some(CredentialSettlementOutcome::Unused),
        4 => Some(CredentialSettlementOutcome::Cancelled),
        5 => Some(CredentialSettlementOutcome::TimedOut),
        _ => None,
    }
}

fn valid_remote_username(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 256
        && value.trim() == value
        && !value.chars().any(char::is_control)
}

fn remote_credential_timeout(method: &str) -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_CREDENTIAL_TIMEOUT",
        "auth",
        "error.auth.credentialTimeout",
        json!({ "method": method }),
        false,
    )
}

struct NativeCancelBaton<'a> {
    token: &'a dyn BridgeCancellationToken,
}

fn raw_cancel_callbacks(cancel_baton: &mut NativeCancelBaton<'_>) -> RawCancelCallbacks {
    RawCancelCallbacks {
        abi_version: RAW_CANCEL_ABI_VERSION,
        baton: (cancel_baton as *mut NativeCancelBaton<'_>).cast::<c_void>(),
        cancel_callback: Some(native_cancel_callback),
    }
}

unsafe extern "C" fn native_cancel_callback(baton: *mut c_void) -> c_int {
    catch_unwind(AssertUnwindSafe(|| unsafe {
        native_cancel_callback_inner(baton)
    }))
    .unwrap_or(RAW_CANCEL_CALLBACK_INVALID)
}

unsafe fn native_cancel_callback_inner(baton: *mut c_void) -> c_int {
    if baton.is_null() {
        return RAW_CANCEL_CALLBACK_INVALID;
    }
    let cancel_baton = unsafe { &*(baton.cast::<NativeCancelBaton<'_>>()) };
    if cancel_baton.token.is_cancelled() {
        RAW_CANCEL_CALLBACK_CANCEL
    } else {
        RAW_CANCEL_CALLBACK_CONTINUE
    }
}

unsafe extern "C" fn native_credential_callback(
    baton: *mut c_void,
    request: *const RawCredentialRequest,
    response: *mut RawCredentialResponse,
) -> c_int {
    match catch_unwind(AssertUnwindSafe(|| unsafe {
        native_credential_callback_inner(baton, request, response)
    })) {
        Ok(status) => status,
        Err(_) => unsafe {
            dispose_raw_credential_response(response);
            record_native_auth_panic_failure(baton, "credentials/request");
            RAW_AUTH_CALLBACK_DENIED
        },
    }
}

unsafe fn native_credential_callback_inner(
    baton: *mut c_void,
    request: *const RawCredentialRequest,
    response: *mut RawCredentialResponse,
) -> c_int {
    if baton.is_null() || request.is_null() || response.is_null() {
        return RAW_AUTH_CALLBACK_INVALID;
    }
    let auth_baton = unsafe { &mut *(baton.cast::<NativeAuthBaton<'_>>()) };
    let _request = unsafe { &*request };
    unsafe { write_empty_credential_response(response) };
    auth_baton.record_failure(BridgeFailure::new(
        "SUBVERSIONR_CREDENTIAL_REMOTE_WORKER_REQUIRED",
        "auth",
        "error.auth.credentialRemoteWorkerRequired",
        json!({ "method": "credentials/request" }),
        false,
    ));
    RAW_AUTH_CALLBACK_DENIED
}

unsafe extern "C" fn native_credential_response_dispose(
    _baton: *mut c_void,
    response: *mut RawCredentialResponse,
) {
    if response.is_null() {
        return;
    }
    unsafe { dispose_raw_credential_response(response) };
}

unsafe fn write_empty_credential_response(response: *mut RawCredentialResponse) {
    if response.is_null() {
        return;
    }
    unsafe {
        *response = RawCredentialResponse {
            username: ptr::null(),
            secret: ptr::null(),
            may_save: 0,
        };
    }
}

unsafe fn dispose_raw_credential_response(response: *mut RawCredentialResponse) {
    if response.is_null() {
        return;
    }
    let response = unsafe { &mut *response };
    unsafe {
        drop_c_string(response.username, false);
        drop_c_string(response.secret, true);
    }
    response.username = ptr::null();
    response.secret = ptr::null();
    response.may_save = 0;
}

unsafe extern "C" fn native_certificate_callback(
    baton: *mut c_void,
    request: *const RawCertificateRequest,
    response: *mut RawCertificateResponse,
) -> c_int {
    match catch_unwind(AssertUnwindSafe(|| unsafe {
        native_certificate_callback_inner(baton, request, response)
    })) {
        Ok(status) => status,
        Err(_) => unsafe {
            write_empty_certificate_response(response);
            record_native_auth_panic_failure(baton, "certificate/request");
            RAW_AUTH_CALLBACK_DENIED
        },
    }
}

unsafe fn write_empty_certificate_response(response: *mut RawCertificateResponse) {
    if response.is_null() {
        return;
    }
    unsafe {
        *response = RawCertificateResponse {
            accepted_failures: 0,
            may_save: 0,
        };
    }
}

unsafe fn record_native_auth_panic_failure(baton: *mut c_void, method: &str) {
    if baton.is_null() {
        return;
    }
    let auth_baton = unsafe { &mut *(baton.cast::<NativeAuthBaton<'_>>()) };
    auth_baton.record_failure(native_auth_response_invalid(method));
}

unsafe fn native_certificate_callback_inner(
    baton: *mut c_void,
    request: *const RawCertificateRequest,
    response: *mut RawCertificateResponse,
) -> c_int {
    if baton.is_null() || request.is_null() || response.is_null() {
        return RAW_AUTH_CALLBACK_INVALID;
    }
    let auth_baton = unsafe { &mut *(baton.cast::<NativeAuthBaton<'_>>()) };
    let request = unsafe { &*request };
    unsafe { write_empty_certificate_response(response) };

    let realm = match unsafe { optional_c_string_to_owned(request.realm, "certificate.realm") } {
        Ok(Some(realm)) if !realm.trim().is_empty() => realm,
        _ => {
            auth_baton.record_failure(certificate_realm_required(request.failures));
            return RAW_AUTH_CALLBACK_DENIED;
        }
    };
    let host = match unsafe { optional_c_string_to_owned(request.host, "certificate.host") } {
        Ok(Some(host)) if !host.trim().is_empty() => host,
        _ => {
            auth_baton.record_failure(native_auth_response_invalid("certificate/request"));
            return RAW_AUTH_CALLBACK_DENIED;
        }
    };
    let ascii_cert =
        match unsafe { optional_c_string_to_owned(request.ascii_cert, "certificate.asciiCert") } {
            Ok(Some(ascii_cert)) if !ascii_cert.trim().is_empty() => ascii_cert,
            _ => {
                auth_baton.record_failure(certificate_fingerprint_unavailable(request.failures));
                return RAW_AUTH_CALLBACK_DENIED;
            }
        };
    let fingerprint = match sha256_der_fingerprint(&ascii_cert) {
        Some(fingerprint) => fingerprint,
        None => {
            auth_baton.record_failure(certificate_fingerprint_unavailable(request.failures));
            return RAW_AUTH_CALLBACK_DENIED;
        }
    };
    let valid_from =
        match unsafe { optional_c_string_to_owned(request.valid_from, "certificate.validFrom") } {
            Ok(Some(value)) if !value.trim().is_empty() => value,
            _ => {
                auth_baton.record_failure(native_auth_response_invalid("certificate/request"));
                return RAW_AUTH_CALLBACK_DENIED;
            }
        };
    let valid_to =
        match unsafe { optional_c_string_to_owned(request.valid_to, "certificate.validTo") } {
            Ok(Some(value)) if !value.trim().is_empty() => value,
            _ => {
                auth_baton.record_failure(native_auth_response_invalid("certificate/request"));
                return RAW_AUTH_CALLBACK_DENIED;
            }
        };
    let issuer = match unsafe { optional_c_string_to_owned(request.issuer, "certificate.issuer") } {
        Ok(value) => value,
        Err(failure) => {
            auth_baton.record_failure(native_auth_invalid_string("certificate/request", failure));
            return RAW_AUTH_CALLBACK_DENIED;
        }
    };
    let subject = match unsafe {
        optional_c_string_to_owned(request.subject, "certificate.subject")
    } {
        Ok(value) => value,
        Err(failure) => {
            auth_baton.record_failure(native_auth_invalid_string("certificate/request", failure));
            return RAW_AUTH_CALLBACK_DENIED;
        }
    };
    let raw_working_copy_root = match unsafe {
        optional_c_string_to_owned(request.working_copy_root, "certificate.workingCopyRoot")
    } {
        Ok(root) => root,
        Err(failure) => {
            auth_baton.record_failure(native_auth_invalid_string("certificate/request", failure));
            return RAW_AUTH_CALLBACK_DENIED;
        }
    };
    let working_copy_root = auth_baton
        .working_copy_root
        .clone()
        .or(raw_working_copy_root);
    let failures = certificate_failure_words(request.failures);
    if failures.is_empty() {
        auth_baton.record_failure(native_auth_response_invalid("certificate/request"));
        return RAW_AUTH_CALLBACK_DENIED;
    }

    let persistence_allowed = request.may_save != 0;
    let request_id = auth_baton.request_id("certificate");
    let protocol_request = CertificateTrustRequest {
        request_id: request_id.clone(),
        realm,
        host,
        fingerprint: fingerprint.clone(),
        fingerprint_algorithm: "sha256-der".to_string(),
        failures,
        valid_from,
        valid_to,
        issuer,
        subject,
        interactive: true,
        persistence_allowed,
        origin: "foreground".to_string(),
        timeout_ms: NATIVE_AUTH_REQUEST_TIMEOUT_MS,
        repository_id: auth_baton.repository_id.clone(),
        working_copy_root,
    };
    let safe_args = certificate_safe_args(&protocol_request);

    match auth_baton.auth.request_certificate_trust(protocol_request) {
        Ok(CertificateTrustResponse::Trust {
            request_id: response_request_id,
            trust,
            fingerprint: response_fingerprint,
            fingerprint_algorithm,
        }) if response_request_id == request_id
            && response_fingerprint == fingerprint
            && fingerprint_algorithm == "sha256-der" =>
        {
            if !certificate_trust_is_allowed(&trust, persistence_allowed) {
                auth_baton.record_failure(native_auth_response_invalid("certificate/request"));
                return RAW_AUTH_CALLBACK_DENIED;
            }
            unsafe {
                (*response).accepted_failures = request.failures;
                (*response).may_save = 0;
            }
            RAW_AUTH_CALLBACK_OK
        }
        Ok(CertificateTrustResponse::Reject {
            request_id: response_request_id,
            error,
        }) if response_request_id == request_id => {
            auth_baton.record_failure(certificate_error_to_bridge(&error, safe_args));
            RAW_AUTH_CALLBACK_DENIED
        }
        Ok(_) => {
            auth_baton.record_failure(native_auth_response_invalid("certificate/request"));
            RAW_AUTH_CALLBACK_DENIED
        }
        Err(failure) => {
            auth_baton.record_failure(failure);
            RAW_AUTH_CALLBACK_DENIED
        }
    }
}

unsafe fn format_libsvn_version(raw: RawVersionInfo) -> Result<String, NativeBridgeLoadError> {
    let display =
        unsafe { c_string_to_owned(raw.display, "libsvn_version_display") }.map_err(|failure| {
            match failure {
                NativeStringFailure::Null(field) => NativeBridgeLoadError::NullString(field),
                NativeStringFailure::InvalidUtf8 { field, source } => {
                    NativeBridgeLoadError::InvalidUtf8 { field, source }
                }
            }
        })?;

    Ok(format!(
        "{}.{}.{} ({display})",
        raw.major, raw.minor, raw.patch
    ))
}

unsafe fn c_string_to_owned(
    ptr: *const c_char,
    field: &'static str,
) -> Result<String, NativeStringFailure> {
    if ptr.is_null() {
        return Err(NativeStringFailure::Null(field));
    }

    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map(str::to_string)
        .map_err(|source| NativeStringFailure::InvalidUtf8 { field, source })
}

fn repository_identity_from_raw(
    path: &str,
    info: RawWorkingCopyInfo,
) -> Result<RepositoryIdentity, BridgeFailure> {
    let repository_uuid = unsafe { c_string_to_owned(info.repository_uuid, "repository_uuid") }
        .map_err(|failure| native_field_failure(path, failure))?;
    let repository_root_url =
        unsafe { c_string_to_owned(info.repository_root_url, "repository_root_url") }
            .map_err(|failure| native_field_failure(path, failure))?;
    let working_copy_root =
        unsafe { c_string_to_owned(info.working_copy_root, "working_copy_root") }
            .map_err(|failure| native_field_failure(path, failure))?;

    Ok(RepositoryIdentity {
        repository_uuid,
        repository_root_url,
        working_copy_root,
        workspace_scope_root: path.to_string(),
        format: info.format,
    })
}

fn credential_safe_args(request: &CredentialRequest) -> serde_json::Value {
    json!({
        "authorityHash": credential_authority_hash(request),
        "authKind": request.auth_kind,
        "attempt": request.attempt,
        "origin": request.origin,
    })
}

fn credential_authority_hash(request: &CredentialRequest) -> String {
    let mut hasher = Sha256::new();
    hasher.update(serde_json::to_vec(&request.endpoint).expect("endpoint serialization"));
    hasher.update([0]);
    hasher.update(serde_json::to_vec(&request.auth_kind).expect("auth kind serialization"));
    hasher.update([0]);
    hasher.update(request.realm.as_bytes());
    hex_digest(hasher.finalize())
}

fn hex_digest(digest: impl AsRef<[u8]>) -> String {
    digest
        .as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn certificate_safe_args(request: &CertificateTrustRequest) -> serde_json::Value {
    json!({
        "realmHash": auth_realm_hash("certificate", &request.realm),
        "fingerprint": request.fingerprint,
        "fingerprintAlgorithm": request.fingerprint_algorithm,
        "failureCount": request.failures.len(),
        "origin": request.origin,
    })
}

fn auth_realm_hash(kind: &str, realm: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(kind.as_bytes());
    hasher.update([0]);
    hasher.update(realm.as_bytes());
    hex_digest(hasher.finalize())
}

fn credential_error_to_bridge(
    error: &subversionr_protocol::CredentialError,
    safe_args: serde_json::Value,
) -> BridgeFailure {
    if !credential_error_contract_is_allowed(error) {
        return native_auth_response_invalid("credentials/request");
    }
    BridgeFailure::new(
        error.code.clone(),
        error.category.clone(),
        error.message_key.clone(),
        safe_args,
        false,
    )
}

fn certificate_error_to_bridge(
    error: &subversionr_protocol::CertificateTrustError,
    safe_args: serde_json::Value,
) -> BridgeFailure {
    if !certificate_error_contract_is_allowed(error) {
        return native_auth_response_invalid("certificate/request");
    }
    BridgeFailure::new(
        error.code.clone(),
        error.category.clone(),
        error.message_key.clone(),
        safe_args,
        false,
    )
}

fn certificate_trust_is_allowed(trust: &str, persistence_allowed: bool) -> bool {
    matches!(trust, "once") || (persistence_allowed && matches!(trust, "permanent"))
}

fn credential_error_contract_is_allowed(error: &subversionr_protocol::CredentialError) -> bool {
    !error.retryable
        && matches!(
            (
                error.code.as_str(),
                error.category.as_str(),
                error.message_key.as_str(),
            ),
            (
                "SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE",
                "lifecycle",
                "error.auth.credentialUntrustedWorkspace"
            ) | (
                "SUBVERSIONR_CREDENTIAL_NON_INTERACTIVE",
                "auth",
                "error.auth.credentialNonInteractive"
            ) | (
                "SUBVERSIONR_CREDENTIAL_TIMEOUT",
                "auth",
                "error.auth.credentialTimeout"
            ) | (
                "SUBVERSIONR_CREDENTIAL_CANCELLED",
                "auth",
                "error.auth.credentialCancelled"
            ) | (
                "SUBVERSIONR_CREDENTIAL_LEGACY_BLOCKED",
                "auth",
                "error.auth.credentialLegacyBlocked"
            ) | (
                "SUBVERSIONR_CREDENTIAL_LEGACY_CLEAR_DECLINED",
                "auth",
                "error.auth.credentialLegacyClearDeclined"
            ) | (
                "SUBVERSIONR_CREDENTIAL_ACCOUNT_UNAVAILABLE",
                "auth",
                "error.auth.credentialAccountUnavailable"
            ) | (
                "SUBVERSIONR_CREDENTIAL_RETRY_INVALID",
                "auth",
                "error.auth.credentialRetryInvalid"
            ) | (
                "SUBVERSIONR_CREDENTIAL_STORAGE_INTEGRITY",
                "auth",
                "error.auth.credentialStorageIntegrity"
            ) | (
                "SUBVERSIONR_CREDENTIAL_SECRET_INVALID",
                "auth",
                "error.auth.credentialSecretInvalid"
            )
        )
}

fn certificate_error_contract_is_allowed(
    error: &subversionr_protocol::CertificateTrustError,
) -> bool {
    !error.retryable
        && matches!(
            (
                error.code.as_str(),
                error.category.as_str(),
                error.message_key.as_str(),
            ),
            (
                "SUBVERSIONR_CERTIFICATE_UNTRUSTED_WORKSPACE",
                "lifecycle",
                "error.auth.certificateUntrustedWorkspace"
            ) | (
                "SUBVERSIONR_CERTIFICATE_REALM_REQUIRED",
                "auth",
                "error.auth.certificateRealmRequired"
            ) | (
                "SUBVERSIONR_CERTIFICATE_FINGERPRINT_ALGORITHM_UNSUPPORTED",
                "auth",
                "error.auth.certificateFingerprintAlgorithmUnsupported"
            ) | (
                "SUBVERSIONR_CERTIFICATE_CHANGED",
                "auth",
                "error.auth.certificateChanged"
            ) | (
                "SUBVERSIONR_CERTIFICATE_NON_INTERACTIVE",
                "auth",
                "error.auth.certificateNonInteractive"
            ) | (
                "SUBVERSIONR_CERTIFICATE_TIMEOUT",
                "auth",
                "error.auth.certificateTimeout"
            ) | (
                "SUBVERSIONR_CERTIFICATE_CANCELLED",
                "auth",
                "error.auth.certificateCancelled"
            ) | (
                "SUBVERSIONR_CERTIFICATE_REJECTED",
                "auth",
                "error.auth.certificateRejected"
            ) | (
                "SUBVERSIONR_CERTIFICATE_PERSISTENCE_DISALLOWED",
                "auth",
                "error.auth.certificatePersistenceDisallowed"
            ) | (
                "SUBVERSIONR_CERTIFICATE_STORE_INVALID",
                "auth",
                "error.auth.certificateStoreInvalid"
            )
        )
}

fn certificate_realm_required(failure_bits: u32) -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_CERTIFICATE_REALM_REQUIRED",
        "auth",
        "error.auth.certificateRealmRequired",
        json!({
            "realmHash": auth_realm_hash("certificate", ""),
            "fingerprint": "",
            "fingerprintAlgorithm": "sha256-der",
            "failureCount": certificate_failure_words(failure_bits).len(),
            "origin": "foreground",
        }),
        false,
    )
}

fn certificate_fingerprint_unavailable(failure_bits: u32) -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_CERTIFICATE_FINGERPRINT_ALGORITHM_UNSUPPORTED",
        "auth",
        "error.auth.certificateFingerprintAlgorithmUnsupported",
        json!({
            "realmHash": auth_realm_hash("certificate", ""),
            "fingerprint": "",
            "fingerprintAlgorithm": "sha256-der",
            "failureCount": certificate_failure_words(failure_bits).len(),
            "origin": "foreground",
        }),
        false,
    )
}

fn native_auth_response_invalid(method: &str) -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_AUTH_RESPONSE_INVALID",
        "auth",
        "error.auth.responseInvalid",
        json!({ "method": method }),
        false,
    )
}

fn native_auth_invalid_string(method: &str, _failure: NativeStringFailure) -> BridgeFailure {
    native_auth_response_invalid(method)
}

fn certificate_failure_words(failures: u32) -> Vec<String> {
    let mut words = Vec::new();
    if failures & RAW_CERT_FAILURE_NOT_YET_VALID != 0 {
        words.push("notYetValid".to_string());
    }
    if failures & RAW_CERT_FAILURE_EXPIRED != 0 {
        words.push("expired".to_string());
    }
    if failures & RAW_CERT_FAILURE_CN_MISMATCH != 0 {
        words.push("commonNameMismatch".to_string());
    }
    if failures & RAW_CERT_FAILURE_UNKNOWN_CA != 0 {
        words.push("unknownCa".to_string());
    }
    if failures & RAW_CERT_FAILURE_OTHER != 0
        || failures
            & !(RAW_CERT_FAILURE_NOT_YET_VALID
                | RAW_CERT_FAILURE_EXPIRED
                | RAW_CERT_FAILURE_CN_MISMATCH
                | RAW_CERT_FAILURE_UNKNOWN_CA
                | RAW_CERT_FAILURE_OTHER)
            != 0
    {
        words.push("other".to_string());
    }
    words
}

fn sha256_der_fingerprint(ascii_cert: &str) -> Option<String> {
    let compact = ascii_cert
        .chars()
        .filter(|character| !character.is_ascii_whitespace())
        .collect::<String>();
    let der = STANDARD.decode(compact.as_bytes()).ok()?;
    Some(sha256_hex(&der))
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    digest
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>()
}

unsafe fn drop_c_string(ptr: *const c_char, zeroize: bool) {
    if ptr.is_null() {
        return;
    }
    let string = unsafe { CString::from_raw(ptr as *mut c_char) };
    if zeroize {
        let mut bytes = string.into_bytes_with_nul();
        for byte in &mut bytes {
            unsafe { ptr::write_volatile(byte, 0) };
        }
        return;
    }
    drop(string);
}

fn remote_context_failure(code: &str, message_key: &str, status: c_int) -> BridgeFailure {
    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({ "status": status }),
        false,
    )
}

fn create_remote_context_foundation_raw(
    create: RemoteContextCreate,
    inspect: RemoteContextInspect,
    destroy: RemoteContextDestroy,
    plan: RemoteConfigPlan,
) -> Result<(), BridgeFailure> {
    if !matches!(plan.server_auth, RemoteConfigServerAuth::Anonymous) {
        return Err(BridgeFailure::new(
            "SUBVERSIONR_CREDENTIAL_REMOTE_WORKER_REQUIRED",
            "auth",
            "error.auth.credentialRemoteWorkerRequired",
            json!({ "method": "credentials/request" }),
            false,
        ));
    }
    let config = RawRemoteConfigV1 {
        abi_version: RAW_REMOTE_CONFIG_ABI_VERSION,
        scheme: match plan.scheme {
            RemoteConfigScheme::Http => 1,
            RemoteConfigScheme::Https => 2,
            RemoteConfigScheme::Svn => 3,
        },
        server_auth: match plan.server_auth {
            RemoteConfigServerAuth::Anonymous => 1,
            RemoteConfigServerAuth::Basic => 2,
            RemoteConfigServerAuth::CramMd5 => 3,
        },
        timeout_ms: plan.timeout_ms,
        trust_windows_roots: i32::from(plan.trust_windows_roots),
    };
    let mut context = ptr::null_mut();
    let status = unsafe { create(&config, ptr::null(), &mut context) };
    if status != 0 {
        return Err(remote_context_failure(
            "SUBVERSIONR_REMOTE_CONFIG_CREATE_FAILED",
            "error.remote.configCreateFailed",
            status,
        ));
    }
    let Some(context) = NonNull::new(context) else {
        return Err(remote_context_failure(
            "SUBVERSIONR_REMOTE_CONFIG_CREATE_NULL",
            "error.remote.configCreateNull",
            0,
        ));
    };
    let mut inspection = RawRemoteConfigInspection::default();
    let inspect_status = unsafe { inspect(context.as_ptr(), &mut inspection) };
    unsafe { destroy(context.as_ptr()) };
    if inspect_status != 0 {
        return Err(remote_context_failure(
            "SUBVERSIONR_REMOTE_CONFIG_INSPECTION_FAILED",
            "error.remote.configInspectionFailed",
            inspect_status,
        ));
    }
    if inspection.abi_version != RAW_REMOTE_CONFIG_ABI_VERSION
        || inspection.category_mask != RAW_REMOTE_CATEGORY_MASK
        || inspection.option_mask != RAW_REMOTE_OPTION_MASK
        || inspection.provider_mask != 0
        || inspection.forbidden_input_mask != 0
    {
        return Err(BridgeFailure::new(
            "SUBVERSIONR_REMOTE_CONFIG_INSPECTION_INVALID",
            "native",
            "error.remote.configInspectionInvalid",
            json!({}),
            false,
        ));
    }
    Ok(())
}

fn raw_remote_credential_callbacks(
    baton: &mut RemoteCredentialBaton<'_>,
) -> RawRemoteCredentialCallbacksV2 {
    RawRemoteCredentialCallbacksV2 {
        abi_version: RAW_REMOTE_CREDENTIAL_ABI_VERSION,
        baton: (baton as *mut RemoteCredentialBaton<'_>).cast::<c_void>(),
        credential_callback: Some(remote_credential_callback_v2),
        credential_response_dispose: Some(remote_credential_response_dispose_v2),
        credential_settlement_callback: Some(remote_credential_settlement_callback_v2),
    }
}

fn create_remote_context_foundation_worker_raw(
    create: RemoteContextCreate,
    inspect: RemoteContextInspect,
    destroy: RemoteContextDestroy,
    plan: RemoteConfigPlan,
    envelope: &RemoteOperationEnvelope,
    auth: &mut dyn AuthRequestBroker,
    deadline: Instant,
) -> Result<(), BridgeFailure> {
    let config = RawRemoteConfigV1 {
        abi_version: RAW_REMOTE_CONFIG_ABI_VERSION,
        scheme: match plan.scheme {
            RemoteConfigScheme::Http => 1,
            RemoteConfigScheme::Https => 2,
            RemoteConfigScheme::Svn => 3,
        },
        server_auth: match plan.server_auth {
            RemoteConfigServerAuth::Anonymous => 1,
            RemoteConfigServerAuth::Basic => 2,
            RemoteConfigServerAuth::CramMd5 => 3,
        },
        timeout_ms: plan.timeout_ms,
        trust_windows_roots: i32::from(plan.trust_windows_roots),
    };
    let mut baton = RemoteCredentialBaton {
        auth,
        envelope,
        deadline,
        failure: None,
    };
    let callbacks = raw_remote_credential_callbacks(&mut baton);
    let callback_ptr = if matches!(plan.server_auth, RemoteConfigServerAuth::Anonymous) {
        ptr::null()
    } else {
        &callbacks
    };
    let mut context = ptr::null_mut();
    let status = unsafe { create(&config, callback_ptr, &mut context) };
    if let Some(failure) = baton.take_failure() {
        return Err(failure);
    }
    if status != 0 {
        return Err(remote_context_failure(
            "SUBVERSIONR_REMOTE_CONFIG_CREATE_FAILED",
            "error.remote.configCreateFailed",
            status,
        ));
    }
    let Some(context) = NonNull::new(context) else {
        return Err(remote_context_failure(
            "SUBVERSIONR_REMOTE_CONFIG_CREATE_NULL",
            "error.remote.configCreateNull",
            0,
        ));
    };
    let mut inspection = RawRemoteConfigInspection::default();
    let inspect_status = unsafe { inspect(context.as_ptr(), &mut inspection) };
    unsafe { destroy(context.as_ptr()) };
    if let Some(failure) = baton.take_failure() {
        return Err(failure);
    }
    if inspect_status != 0 {
        return Err(remote_context_failure(
            "SUBVERSIONR_REMOTE_CONFIG_INSPECTION_FAILED",
            "error.remote.configInspectionFailed",
            inspect_status,
        ));
    }
    let expected_provider_mask = u32::from(!matches!(
        plan.server_auth,
        RemoteConfigServerAuth::Anonymous
    ));
    if inspection.abi_version != RAW_REMOTE_CONFIG_ABI_VERSION
        || inspection.category_mask != RAW_REMOTE_CATEGORY_MASK
        || inspection.option_mask != RAW_REMOTE_OPTION_MASK
        || inspection.provider_mask != expected_provider_mask
        || inspection.forbidden_input_mask != 0
    {
        return Err(BridgeFailure::new(
            "SUBVERSIONR_REMOTE_CONFIG_INSPECTION_INVALID",
            "native",
            "error.remote.configInspectionInvalid",
            json!({}),
            false,
        ));
    }
    Ok(())
}

fn open_working_copy_failure(status: c_int, path: &str) -> BridgeFailure {
    let (code, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "error.native.bridgeInvalidArgument",
        ),
        2 => ("SVN_WC_NOT_FOUND", "error.native.workingCopyNotFound"),
        3 => (
            "SVN_WC_IDENTITY_INCOMPLETE",
            "error.native.workingCopyIdentityIncomplete",
        ),
        4 => (
            "SVN_WC_FORMAT_UNAVAILABLE",
            "error.native.workingCopyFormatUnavailable",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({ "path": path, "status": status }),
        false,
    )
}

fn remote_url_probe_failure(status: c_int, url: &str) -> BridgeFailure {
    let (code, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "error.native.bridgeInvalidArgument",
        ),
        2 => ("SVN_REMOTE_INFO_FAILED", "error.native.remoteInfoFailed"),
        3 => (
            "SVN_REMOTE_INFO_INCOMPLETE",
            "error.native.remoteInfoIncomplete",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({ "urlHash": auth_realm_hash("remote-url", url), "status": status }),
        false,
    )
}

fn status_snapshot_failure(status: c_int, path: &str) -> BridgeFailure {
    let (code, category, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "native",
            "error.native.bridgeInvalidArgument",
        ),
        2 => ("SVN_STATUS_FAILED", "native", "error.native.statusFailed"),
        5 => (
            "SVN_STATUS_DEPTH_UNSUPPORTED",
            "native",
            "error.native.statusDepthUnsupported",
        ),
        RAW_STATUS_CALLBACK_FAILED => (
            "SVN_STATUS_CANCEL_CALLBACK_FAILED",
            "native",
            "error.native.statusCancelCallbackFailed",
        ),
        RAW_STATUS_CANCELLED => (
            "SVN_STATUS_CANCELLED",
            "cancelled",
            "error.native.statusCancelled",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "native",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        category,
        message_key,
        json!({ "path": path, "status": status }),
        false,
    )
}

fn remote_status_failure(status: c_int, path: &str) -> BridgeFailure {
    let (code, category, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "native",
            "error.native.bridgeInvalidArgument",
        ),
        2 => (
            "SVN_REMOTE_STATUS_FAILED",
            "network",
            "error.native.remoteStatusFailed",
        ),
        RAW_STATUS_CALLBACK_FAILED => (
            "SVN_REMOTE_STATUS_CANCEL_CALLBACK_FAILED",
            "native",
            "error.native.remoteStatusCancelCallbackFailed",
        ),
        RAW_STATUS_CANCELLED => (
            "SVN_REMOTE_STATUS_CANCELLED",
            "cancelled",
            "error.native.remoteStatusCancelled",
        ),
        12 => (
            "SVN_REMOTE_STATUS_AUTH_FAILED",
            "auth",
            "error.native.remoteStatusAuthFailed",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "native",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        category,
        message_key,
        json!({ "path": path, "status": status }),
        false,
    )
}

fn content_get_failure(status: c_int, path: &str) -> BridgeFailure {
    let (code, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "error.native.bridgeInvalidArgument",
        ),
        2 => ("SVN_CONTENT_FAILED", "error.native.contentFailed"),
        6 => (
            "SVN_CONTENT_REVISION_UNSUPPORTED",
            "error.native.contentRevisionUnsupported",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({ "path": path, "status": status }),
        false,
    )
}

fn properties_list_failure(status: c_int, path: &str) -> BridgeFailure {
    let (code, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "error.native.bridgeInvalidArgument",
        ),
        2 => (
            "SVN_PROPERTIES_LIST_FAILED",
            "error.native.propertiesListFailed",
        ),
        3 => (
            "SVN_PROPERTIES_VALUE_UNSUPPORTED",
            "error.native.propertiesValueUnsupported",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({ "path": path, "status": status }),
        false,
    )
}

fn history_log_failure(status: c_int, path: &str) -> BridgeFailure {
    let (code, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "error.native.bridgeInvalidArgument",
        ),
        2 => ("SVN_HISTORY_LOG_FAILED", "error.native.historyLogFailed"),
        6 => (
            "SVN_HISTORY_REVISION_UNSUPPORTED",
            "error.native.historyRevisionUnsupported",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({ "path": path, "status": status }),
        false,
    )
}

fn history_blame_failure(status: c_int, path: &str) -> BridgeFailure {
    let (code, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "error.native.bridgeInvalidArgument",
        ),
        2 => (
            "SVN_HISTORY_BLAME_FAILED",
            "error.native.historyBlameFailed",
        ),
        6 => (
            "SVN_HISTORY_REVISION_UNSUPPORTED",
            "error.native.historyRevisionUnsupported",
        ),
        9 => (
            "SVN_HISTORY_BLAME_BINARY_FILE",
            "error.native.historyBlameBinaryFile",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({ "path": path, "status": status }),
        false,
    )
}

fn operation_cancellation_failure(status: c_int, path: &str) -> Option<BridgeFailure> {
    let (code, category, message_key, may_have_mutated) = match status {
        RAW_OPERATION_CANCEL_CALLBACK_FAILED => (
            "SVN_OPERATION_CANCEL_CALLBACK_FAILED",
            "native",
            "error.native.operationCancelCallbackFailed",
            false,
        ),
        RAW_OPERATION_CANCELLED => (
            "SVN_OPERATION_CANCELLED",
            "cancelled",
            "error.native.operationCancelled",
            false,
        ),
        RAW_OPERATION_PARTIAL_CANCEL_CALLBACK_FAILED => (
            "SVN_OPERATION_CANCEL_CALLBACK_FAILED",
            "native",
            "error.native.operationCancelCallbackFailed",
            true,
        ),
        RAW_OPERATION_PARTIAL_CANCELLED => (
            "SVN_OPERATION_CANCELLED",
            "cancelled",
            "error.native.operationCancelled",
            true,
        ),
        _ => return None,
    };

    let args = if may_have_mutated {
        json!({ "path": path, "status": status, "mayHaveMutated": true })
    } else {
        json!({ "path": path, "status": status })
    };
    Some(BridgeFailure::new(code, category, message_key, args, false))
}

fn operation_revert_failure(status: c_int, path: &str) -> BridgeFailure {
    if let Some(failure) = operation_cancellation_failure(status, path) {
        return failure;
    }

    let (code, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "error.native.bridgeInvalidArgument",
        ),
        2 => (
            "SVN_OPERATION_REVERT_FAILED",
            "error.native.operationRevertFailed",
        ),
        5 => (
            "SVN_OPERATION_DEPTH_UNSUPPORTED",
            "error.native.operationDepthUnsupported",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({ "path": path, "status": status }),
        false,
    )
}

fn operation_add_failure(status: c_int, path: &str) -> BridgeFailure {
    if let Some(failure) = operation_cancellation_failure(status, path) {
        return failure;
    }

    let (code, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "error.native.bridgeInvalidArgument",
        ),
        2 => (
            "SVN_OPERATION_ADD_FAILED",
            "error.native.operationAddFailed",
        ),
        5 => (
            "SVN_OPERATION_DEPTH_UNSUPPORTED",
            "error.native.operationDepthUnsupported",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({ "path": path, "status": status }),
        false,
    )
}

fn operation_remove_failure(status: c_int, path: &str) -> BridgeFailure {
    if let Some(failure) = operation_cancellation_failure(status, path) {
        return failure;
    }

    let (code, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "error.native.bridgeInvalidArgument",
        ),
        2 => (
            "SVN_OPERATION_REMOVE_FAILED",
            "error.native.operationRemoveFailed",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({ "path": path, "status": status }),
        false,
    )
}

fn operation_move_failure(
    status: c_int,
    source_path: &str,
    destination_path: &str,
) -> BridgeFailure {
    if let Some(failure) = operation_cancellation_failure(status, source_path) {
        return failure;
    }

    let (code, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "error.native.bridgeInvalidArgument",
        ),
        2 => (
            "SVN_OPERATION_MOVE_FAILED",
            "error.native.operationMoveFailed",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({
            "sourcePath": source_path,
            "destinationPath": destination_path,
            "status": status,
        }),
        false,
    )
}

fn operation_resolve_failure(status: c_int, path: &str) -> BridgeFailure {
    if let Some(failure) = operation_cancellation_failure(status, path) {
        return failure;
    }

    let (code, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "error.native.bridgeInvalidArgument",
        ),
        2 => (
            "SVN_OPERATION_RESOLVE_FAILED",
            "error.native.operationResolveFailed",
        ),
        5 => (
            "SVN_OPERATION_DEPTH_UNSUPPORTED",
            "error.native.operationDepthUnsupported",
        ),
        7 => (
            "SVN_OPERATION_RESOLVE_CHOICE_UNSUPPORTED",
            "error.native.operationResolveChoiceUnsupported",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({ "path": path, "status": status }),
        false,
    )
}

fn operation_cleanup_failure(status: c_int, path: &str) -> BridgeFailure {
    if let Some(failure) = operation_cancellation_failure(status, path) {
        return failure;
    }

    let (code, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "error.native.bridgeInvalidArgument",
        ),
        2 => (
            "SVN_OPERATION_CLEANUP_FAILED",
            "error.native.operationCleanupFailed",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({ "path": path, "status": status }),
        false,
    )
}

fn operation_upgrade_failure(status: c_int, path: &str) -> BridgeFailure {
    if let Some(failure) = operation_cancellation_failure(status, path) {
        return failure;
    }

    let (code, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "error.native.bridgeInvalidArgument",
        ),
        2 => (
            "SVN_OPERATION_UPGRADE_FAILED",
            "error.native.operationUpgradeFailed",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({ "path": path, "status": status }),
        false,
    )
}

fn operation_update_failure(status: c_int, path: &str) -> BridgeFailure {
    if let Some(failure) = operation_cancellation_failure(status, path) {
        return failure;
    }

    let (code, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "error.native.bridgeInvalidArgument",
        ),
        2 => (
            "SVN_OPERATION_UPDATE_FAILED",
            "error.native.operationUpdateFailed",
        ),
        5 => (
            "SVN_OPERATION_DEPTH_UNSUPPORTED",
            "error.native.operationDepthUnsupported",
        ),
        6 => (
            "SVN_OPERATION_UPDATE_REVISION_UNSUPPORTED",
            "error.native.operationUpdateRevisionUnsupported",
        ),
        7 => (
            "SVN_OPERATION_UPDATE_STICKY_DEPTH_UNSUPPORTED",
            "error.native.operationUpdateStickyDepthUnsupported",
        ),
        8 => (
            "SVN_OPERATION_UPDATE_EXTERNALS_POLICY_UNSUPPORTED",
            "error.native.operationUpdateExternalsPolicyUnsupported",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({ "path": path, "status": status }),
        false,
    )
}

fn repository_checkout_failure(status: c_int, path: &str) -> BridgeFailure {
    if let Some(failure) = operation_cancellation_failure(status, path) {
        return failure;
    }

    let (code, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "error.native.bridgeInvalidArgument",
        ),
        2 => (
            "SVN_REPOSITORY_CHECKOUT_FAILED",
            "error.native.repositoryCheckoutFailed",
        ),
        5 => (
            "SVN_REPOSITORY_CHECKOUT_DEPTH_UNSUPPORTED",
            "error.native.repositoryCheckoutDepthUnsupported",
        ),
        6 => (
            "SVN_REPOSITORY_CHECKOUT_REVISION_UNSUPPORTED",
            "error.native.repositoryCheckoutRevisionUnsupported",
        ),
        8 => (
            "SVN_REPOSITORY_CHECKOUT_EXTERNALS_POLICY_UNSUPPORTED",
            "error.native.repositoryCheckoutExternalsPolicyUnsupported",
        ),
        10 => (
            "SVN_OPERATION_AUTH_CALLBACK_FAILED",
            "error.native.operationAuthCallbackFailed",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({ "path": path, "status": status }),
        false,
    )
}

fn operation_property_failure(status: c_int, path: &str) -> BridgeFailure {
    if let Some(failure) = operation_cancellation_failure(status, path) {
        return failure;
    }

    let (code, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "error.native.bridgeInvalidArgument",
        ),
        2 => (
            "SVN_OPERATION_PROPERTY_FAILED",
            "error.native.operationPropertyFailed",
        ),
        4 => (
            "SVN_OPERATION_PROPERTY_NAME_INVALID",
            "error.native.operationPropertyNameInvalid",
        ),
        5 => (
            "SVN_OPERATION_PROPERTY_VALUE_INVALID",
            "error.native.operationPropertyValueInvalid",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({ "path": path, "status": status }),
        false,
    )
}

fn operation_changelist_failure(status: c_int, path: &str) -> BridgeFailure {
    if let Some(failure) = operation_cancellation_failure(status, path) {
        return failure;
    }

    let (code, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "error.native.bridgeInvalidArgument",
        ),
        2 => (
            "SVN_OPERATION_CHANGELIST_FAILED",
            "error.native.operationChangelistFailed",
        ),
        5 => (
            "SVN_OPERATION_DEPTH_UNSUPPORTED",
            "error.native.operationDepthUnsupported",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({ "path": path, "status": status }),
        false,
    )
}

fn operation_lock_failure(status: c_int, path: &str) -> BridgeFailure {
    if let Some(failure) = operation_cancellation_failure(status, path) {
        return failure;
    }

    let (code, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "error.native.bridgeInvalidArgument",
        ),
        2 | RAW_OPERATION_PARTIAL_FAILURE => (
            "SVN_OPERATION_LOCK_FAILED",
            "error.native.operationLockFailed",
        ),
        10 => (
            "SVN_OPERATION_AUTH_CALLBACK_FAILED",
            "error.native.operationAuthCallbackFailed",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({
            "path": path,
            "status": status,
            "mayHaveMutated": status == RAW_OPERATION_PARTIAL_FAILURE,
        }),
        false,
    )
}

fn operation_unlock_failure(status: c_int, path: &str) -> BridgeFailure {
    if let Some(failure) = operation_cancellation_failure(status, path) {
        return failure;
    }

    let (code, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "error.native.bridgeInvalidArgument",
        ),
        2 | RAW_OPERATION_PARTIAL_FAILURE => (
            "SVN_OPERATION_UNLOCK_FAILED",
            "error.native.operationUnlockFailed",
        ),
        10 => (
            "SVN_OPERATION_AUTH_CALLBACK_FAILED",
            "error.native.operationAuthCallbackFailed",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({
            "path": path,
            "status": status,
            "mayHaveMutated": status == RAW_OPERATION_PARTIAL_FAILURE,
        }),
        false,
    )
}

fn operation_commit_failure(status: c_int, path: &str) -> BridgeFailure {
    if let Some(failure) = operation_cancellation_failure(status, path) {
        return failure;
    }

    if status == RAW_OPERATION_LOCAL_COMMIT_AUTHOR_UNAVAILABLE {
        return BridgeFailure::new(
            "SUBVERSIONR_LOCAL_COMMIT_AUTHOR_UNAVAILABLE",
            "native",
            "error.native.localCommitAuthorUnavailable",
            json!({ "status": status }),
            false,
        );
    }

    let (code, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "error.native.bridgeInvalidArgument",
        ),
        2 => (
            "SVN_OPERATION_COMMIT_FAILED",
            "error.native.operationCommitFailed",
        ),
        5 => (
            "SVN_OPERATION_DEPTH_UNSUPPORTED",
            "error.native.operationDepthUnsupported",
        ),
        6 => (
            "SVN_OPERATION_COMMIT_CHANGELISTS_INVALID",
            "error.native.operationCommitChangelistsInvalid",
        ),
        7 => (
            "SVN_OPERATION_COMMIT_OPTIONS_UNSUPPORTED",
            "error.native.operationCommitOptionsUnsupported",
        ),
        8 => (
            "SVN_OPERATION_COMMIT_MESSAGE_INVALID",
            "error.native.operationCommitMessageInvalid",
        ),
        9 => (
            "SVN_OPERATION_COMMIT_NO_CHANGES",
            "error.native.operationCommitNoChanges",
        ),
        10 => (
            "SVN_OPERATION_COMMIT_TARGET_NOT_FILE",
            "error.native.operationCommitTargetNotFile",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({ "path": path, "status": status }),
        false,
    )
}

fn operation_branch_create_failure(status: c_int, path: &str) -> BridgeFailure {
    if let Some(failure) = operation_cancellation_failure(status, path) {
        return failure;
    }

    let (code, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "error.native.bridgeInvalidArgument",
        ),
        2 => (
            "SVN_OPERATION_BRANCH_CREATE_FAILED",
            "error.native.operationBranchCreateFailed",
        ),
        3 => (
            "SVN_OPERATION_BRANCH_CREATE_MESSAGE_INVALID",
            "error.native.operationBranchCreateMessageInvalid",
        ),
        6 => (
            "SVN_OPERATION_BRANCH_CREATE_REVISION_UNSUPPORTED",
            "error.native.operationBranchCreateRevisionUnsupported",
        ),
        7 => (
            "SVN_OPERATION_BRANCH_CREATE_PARENTS_POLICY_UNSUPPORTED",
            "error.native.operationBranchCreateParentsPolicyUnsupported",
        ),
        8 => (
            "SVN_OPERATION_BRANCH_CREATE_EXTERNALS_POLICY_UNSUPPORTED",
            "error.native.operationBranchCreateExternalsPolicyUnsupported",
        ),
        9 => (
            "SVN_OPERATION_BRANCH_CREATE_REVISION_MISSING",
            "error.native.operationBranchCreateRevisionMissing",
        ),
        10 => (
            "SVN_OPERATION_AUTH_CALLBACK_FAILED",
            "error.native.operationAuthCallbackFailed",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({ "path": path, "status": status }),
        false,
    )
}

fn operation_switch_failure(status: c_int, path: &str) -> BridgeFailure {
    if let Some(failure) = operation_cancellation_failure(status, path) {
        return failure;
    }

    let (code, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "error.native.bridgeInvalidArgument",
        ),
        2 => (
            "SVN_OPERATION_SWITCH_FAILED",
            "error.native.operationSwitchFailed",
        ),
        5 => (
            "SVN_OPERATION_DEPTH_UNSUPPORTED",
            "error.native.operationDepthUnsupported",
        ),
        6 => (
            "SVN_OPERATION_SWITCH_REVISION_UNSUPPORTED",
            "error.native.operationSwitchRevisionUnsupported",
        ),
        7 => (
            "SVN_OPERATION_SWITCH_STICKY_DEPTH_UNSUPPORTED",
            "error.native.operationSwitchStickyDepthUnsupported",
        ),
        8 => (
            "SVN_OPERATION_SWITCH_EXTERNALS_POLICY_UNSUPPORTED",
            "error.native.operationSwitchExternalsPolicyUnsupported",
        ),
        9 => (
            "SVN_OPERATION_SWITCH_REVISION_MISSING",
            "error.native.operationSwitchRevisionMissing",
        ),
        10 => (
            "SVN_OPERATION_AUTH_CALLBACK_FAILED",
            "error.native.operationAuthCallbackFailed",
        ),
        13 => (
            "SVN_OPERATION_SWITCH_ANCESTRY_POLICY_UNSUPPORTED",
            "error.native.operationSwitchAncestryPolicyUnsupported",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({ "path": path, "status": status }),
        false,
    )
}

fn operation_relocate_failure(status: c_int, path: &str) -> BridgeFailure {
    if let Some(failure) = operation_cancellation_failure(status, path) {
        return failure;
    }

    let (code, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "error.native.bridgeInvalidArgument",
        ),
        2 => (
            "SVN_OPERATION_RELOCATE_FAILED",
            "error.native.operationRelocateFailed",
        ),
        8 => (
            "SVN_OPERATION_RELOCATE_EXTERNALS_POLICY_UNSUPPORTED",
            "error.native.operationRelocateExternalsPolicyUnsupported",
        ),
        10 => (
            "SVN_OPERATION_AUTH_CALLBACK_FAILED",
            "error.native.operationAuthCallbackFailed",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({ "path": path, "status": status }),
        false,
    )
}

fn operation_merge_failure(status: c_int, path: &str) -> BridgeFailure {
    if let Some(failure) = operation_cancellation_failure(status, path) {
        return failure;
    }

    let (code, message_key) = match status {
        1 => (
            "SVN_BRIDGE_INVALID_ARGUMENT",
            "error.native.bridgeInvalidArgument",
        ),
        2 => (
            "SVN_OPERATION_MERGE_FAILED",
            "error.native.operationMergeFailed",
        ),
        5 => (
            "SVN_OPERATION_DEPTH_UNSUPPORTED",
            "error.native.operationDepthUnsupported",
        ),
        6 => (
            "SVN_OPERATION_MERGE_REVISION_UNSUPPORTED",
            "error.native.operationMergeRevisionUnsupported",
        ),
        7 => (
            "SVN_OPERATION_MERGE_OPTIONS_UNSUPPORTED",
            "error.native.operationMergeOptionsUnsupported",
        ),
        10 => (
            "SVN_OPERATION_AUTH_CALLBACK_FAILED",
            "error.native.operationAuthCallbackFailed",
        ),
        _ => (
            "SVN_BRIDGE_UNHANDLED_STATUS",
            "error.native.bridgeUnhandledStatus",
        ),
    };

    BridgeFailure::new(
        code,
        "native",
        message_key,
        json!({ "path": path, "status": status }),
        false,
    )
}

fn valid_scan_path(path: &str) -> bool {
    if path == "." {
        return true;
    }
    if path.trim().is_empty() {
        return false;
    }
    let normalized = path.replace('\\', "/");
    if normalized.starts_with('/') || normalized.contains(':') || normalized.contains('\0') {
        return false;
    }
    normalized
        .split('/')
        .all(|part| !part.is_empty() && part != "." && part != "..")
}

fn valid_commit_scan_path(path: &str) -> bool {
    path == "." || (!path.contains('\\') && valid_scan_path(path))
}

fn valid_update_path(path: &str) -> bool {
    path == "." || (!path.contains('\\') && valid_scan_path(path))
}

fn valid_merge_revision(revision: i64) -> bool {
    revision >= 0 && revision <= MAX_SVN_REVNUM as i64
}

fn valid_move_scan_path(path: &str) -> bool {
    path != "." && !path.contains('\\') && valid_scan_path(path)
}

fn valid_resolve_choice(choice: &str) -> bool {
    matches!(
        choice,
        "working" | "base" | "mineFull" | "theirsFull" | "mineConflict" | "theirsConflict"
    )
}

fn valid_update_scan_path(path: &str) -> bool {
    path == "." || (!path.contains('\\') && valid_scan_path(path))
}

fn has_duplicate_paths(paths: &[String]) -> bool {
    let mut seen = BTreeSet::new();
    paths.iter().any(|path| !seen.insert(path.as_str()))
}

fn valid_commit_message(message: &str) -> bool {
    !message.trim().is_empty() && !message.contains('\0') && !message.contains('\r')
}

fn valid_content_path(path: &str) -> bool {
    path != "." && valid_scan_path(path)
}

fn valid_property_path(path: &str) -> bool {
    path == "." || (!path.contains('\\') && valid_scan_path(path))
}

fn valid_property_name(name: &str) -> bool {
    if name.trim().is_empty() || name.contains('\0') || name.contains('\r') || name.contains('\n') {
        return false;
    }
    let mut parts = name.split(':');
    let first = parts.next().unwrap_or_default();
    if first.is_empty() || !valid_property_name_part(first) {
        return false;
    }
    parts.all(|part| !part.is_empty() && valid_property_name_part(part))
}

fn valid_property_name_part(part: &str) -> bool {
    part.bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_'))
}

fn valid_property_value(value: &str) -> bool {
    !value.contains('\0') && !value.contains('\r')
}

fn valid_changelist_path(path: &str) -> bool {
    !path.contains('\\') && valid_scan_path(path)
}

fn valid_lock_scan_path(path: &str) -> bool {
    path != "." && !path.contains('\\') && valid_scan_path(path)
}

fn valid_lock_comment(comment: &str) -> bool {
    !comment.trim().is_empty() && !comment.contains('\0') && !comment.contains('\r')
}

fn valid_content_revision(revision: &str) -> bool {
    if revision == "base" || revision == "head" {
        return true;
    }
    let Some(number) = revision.strip_prefix('r') else {
        return false;
    };
    if number.is_empty() || (number.len() > 1 && number.starts_with('0')) {
        return false;
    }
    if !number.chars().all(|character| character.is_ascii_digit()) {
        return false;
    }
    number
        .parse::<u64>()
        .is_ok_and(|revision| revision <= MAX_SVN_REVNUM)
}

fn valid_history_path(path: &str) -> bool {
    path == "." || (!path.contains('\\') && valid_scan_path(path))
}

fn valid_history_start_revision(revision: &str) -> bool {
    revision == "head" || valid_numbered_revision(revision)
}

fn valid_history_end_revision(revision: &str) -> bool {
    valid_numbered_revision(revision)
}

fn valid_blame_path(path: &str) -> bool {
    path != "." && !path.contains('\\') && valid_scan_path(path)
}

fn valid_blame_peg_or_end_revision(revision: &str) -> bool {
    matches!(revision, "base" | "head") || valid_numbered_revision(revision)
}

fn valid_ignore_whitespace(value: &str) -> bool {
    matches!(value, "none" | "change" | "all")
}

fn valid_numbered_revision(revision: &str) -> bool {
    let Some(number) = revision.strip_prefix('r') else {
        return false;
    };
    valid_revision_number_text(number)
}

fn valid_update_revision(revision: &str) -> bool {
    revision == "head" || valid_revision_number_text(revision)
}

fn valid_update_depth(depth: &str) -> bool {
    matches!(
        depth,
        "workingCopy" | "empty" | "files" | "immediates" | "infinity"
    )
}

fn valid_merge_depth(depth: &str) -> bool {
    valid_checkout_depth(depth)
}

fn valid_checkout_depth(depth: &str) -> bool {
    matches!(depth, "empty" | "files" | "immediates" | "infinity")
}

fn valid_checkout_url(url: &str) -> bool {
    !url.trim().is_empty() && !url.contains('\0') && !url.contains('\r') && !url.contains('\n')
}

fn valid_branch_url(url: &str) -> bool {
    valid_checkout_url(url)
}

fn valid_checkout_target_path(path: &str) -> bool {
    !path.trim().is_empty()
        && !path.contains('\0')
        && !path.contains('\r')
        && !path.contains('\n')
        && Path::new(path).is_absolute()
}

fn valid_revision_number_text(number: &str) -> bool {
    if number.is_empty() || (number.len() > 1 && number.starts_with('0')) {
        return false;
    }
    if !number.chars().all(|character| character.is_ascii_digit()) {
        return false;
    }
    number
        .parse::<u64>()
        .is_ok_and(|revision| revision <= MAX_SVN_REVNUM)
}

fn content_source(revision: &str) -> &'static str {
    match revision {
        "base" => "libsvn-base",
        "head" => "libsvn-head",
        _ => "libsvn-revision",
    }
}

fn valid_changelist(changelist: &str) -> bool {
    !changelist.trim().is_empty()
        && !changelist.contains('\0')
        && !changelist.contains('\r')
        && !changelist.contains('\n')
}

fn scan_path(working_copy_root: &str, path: &str) -> String {
    let normalized_root = normalize_bridge_path(working_copy_root);
    if path == "." {
        return normalized_root;
    }

    let normalized_path = path.replace('\\', "/");
    if normalized_root.ends_with('/') {
        format!("{normalized_root}{normalized_path}")
    } else {
        format!("{normalized_root}/{normalized_path}")
    }
}

fn update_scan_path(working_copy_root: &str, path: &str) -> Result<String, BridgeFailure> {
    if !valid_update_scan_path(path) {
        return Err(BridgeFailure::invalid_path());
    }
    Ok(scan_path(working_copy_root, path))
}

fn normalize_bridge_path(path: &str) -> String {
    let normalized = path.replace('\\', "/");
    if normalized == "/" || is_windows_drive_root(&normalized) {
        return normalized;
    }
    normalized.trim_end_matches('/').to_string()
}

fn is_windows_drive_root(path: &str) -> bool {
    let bytes = path.as_bytes();
    bytes.len() == 3 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && bytes[2] == b'/'
}

fn raw_status_entry_to_protocol(
    raw_entry: &RawStatusEntry,
    identity: &RepositoryIdentity,
    generation: u64,
) -> Result<StatusEntry, BridgeFailure> {
    let raw_path = unsafe { c_string_to_owned(raw_entry.path, "status.path") }
        .map_err(|failure| native_field_failure(&identity.working_copy_root, failure))?;
    let path = relative_status_path(&identity.working_copy_root, &raw_path)?;
    let kind = unsafe { c_string_to_owned(raw_entry.kind, "status.kind") }
        .map_err(|failure| native_field_failure(&identity.working_copy_root, failure))?;
    let node_status = unsafe { c_string_to_owned(raw_entry.node_status, "status.nodeStatus") }
        .map_err(|failure| native_field_failure(&identity.working_copy_root, failure))?;
    let text_status = unsafe { c_string_to_owned(raw_entry.text_status, "status.textStatus") }
        .map_err(|failure| native_field_failure(&identity.working_copy_root, failure))?;
    let property_status =
        unsafe { c_string_to_owned(raw_entry.property_status, "status.propertyStatus") }
            .map_err(|failure| native_field_failure(&identity.working_copy_root, failure))?;
    let changed_author =
        unsafe { optional_c_string_to_owned(raw_entry.changed_author, "status.changedAuthor") }
            .map_err(|failure| native_field_failure(&identity.working_copy_root, failure))?;
    let changed_date =
        unsafe { optional_c_string_to_owned(raw_entry.changed_date, "status.changedDate") }
            .map_err(|failure| native_field_failure(&identity.working_copy_root, failure))?;
    let changelist =
        unsafe { optional_c_string_to_owned(raw_entry.changelist, "status.changelist") }
            .map_err(|failure| native_field_failure(&identity.working_copy_root, failure))?;
    let lock = raw_lock_info_to_protocol(raw_entry.lock, &identity.working_copy_root)?;
    let depth = unsafe { c_string_to_owned(raw_entry.depth, "status.depth") }
        .map_err(|failure| native_field_failure(&identity.working_copy_root, failure))?;
    let raw_copy_from_path =
        unsafe { optional_c_string_to_owned(raw_entry.copy_from_path, "status.copyFromPath") }
            .map_err(|failure| native_field_failure(&identity.working_copy_root, failure))?;
    let copy = status_copy_from_protocol(
        raw_entry.copied,
        raw_copy_from_path,
        raw_entry.copy_from_revision,
    );
    let move_ = unsafe {
        optional_c_string_to_owned(raw_entry.moved_from_abspath, "status.movedFromAbspath")
    }
    .map_err(|failure| native_field_failure(&identity.working_copy_root, failure))?
    .map(|path| relative_native_path(&identity.working_copy_root, &path, "status.move"))
    .transpose()?;
    let conflict = (raw_entry.conflicted != 0).then(|| "conflicted".to_string());
    let conflict_artifacts = raw_conflict_artifacts_to_protocol(raw_entry, identity, &path)?;

    Ok(StatusEntry {
        path,
        kind,
        node_status: node_status.clone(),
        text_status,
        property_status,
        local_status: node_status,
        remote_status: "notChecked".to_string(),
        revision: raw_entry.revision,
        changed_revision: raw_entry.changed_revision,
        changed_author,
        changed_date,
        changelist,
        lock,
        needs_lock: raw_entry.needs_lock != 0,
        copy,
        move_,
        switched: raw_entry.switched != 0,
        depth,
        conflict,
        conflict_artifacts,
        external: raw_entry.external != 0,
        generation,
    })
}

fn raw_remote_status_entry_to_protocol(
    raw_entry: &RawStatusEntry,
    identity: &RepositoryIdentity,
    generation: u64,
) -> Result<StatusEntry, BridgeFailure> {
    let mut entry = raw_status_entry_to_protocol(raw_entry, identity, generation)?;
    if !entry.conflict_artifacts.is_empty() {
        return Err(native_invalid_response(
            &identity.working_copy_root,
            "remoteStatus.conflictArtifacts",
        ));
    }
    let repos_node_status =
        unsafe { c_string_to_owned(raw_entry.repos_node_status, "remoteStatus.nodeStatus") }
            .map_err(|failure| native_field_failure(&identity.working_copy_root, failure))?;
    let repos_text_status =
        unsafe { c_string_to_owned(raw_entry.repos_text_status, "remoteStatus.textStatus") }
            .map_err(|failure| native_field_failure(&identity.working_copy_root, failure))?;
    let repos_property_status = unsafe {
        c_string_to_owned(
            raw_entry.repos_property_status,
            "remoteStatus.propertyStatus",
        )
    }
    .map_err(|failure| native_field_failure(&identity.working_copy_root, failure))?;
    let repos_kind = unsafe { c_string_to_owned(raw_entry.repos_kind, "remoteStatus.kind") }
        .map_err(|failure| native_field_failure(&identity.working_copy_root, failure))?;
    let repos_changed_author = unsafe {
        optional_c_string_to_owned(raw_entry.repos_changed_author, "remoteStatus.changedAuthor")
    }
    .map_err(|failure| native_field_failure(&identity.working_copy_root, failure))?;
    let repos_changed_date = unsafe {
        optional_c_string_to_owned(raw_entry.repos_changed_date, "remoteStatus.changedDate")
    }
    .map_err(|failure| native_field_failure(&identity.working_copy_root, failure))?;
    let repos_lock = raw_lock_info_to_protocol(raw_entry.repos_lock, &identity.working_copy_root)?;

    entry.remote_status = repos_node_status;
    if !matches!(repos_kind.as_str(), "none" | "unknown") {
        entry.kind = repos_kind;
    }
    entry.text_status = repos_text_status;
    entry.property_status = repos_property_status;
    entry.changed_revision = raw_entry.repos_changed_revision;
    entry.changed_author = repos_changed_author;
    entry.changed_date = repos_changed_date;
    entry.lock = repos_lock;
    Ok(entry)
}

fn raw_conflict_artifacts_to_protocol(
    raw_entry: &RawStatusEntry,
    identity: &RepositoryIdentity,
    owner_path: &str,
) -> Result<Vec<String>, BridgeFailure> {
    const FIELD: &str = "status.conflictArtifacts";
    if raw_entry.conflict_artifact_count > raw_entry.conflict_artifact_paths.len() {
        return Err(native_invalid_response(&identity.working_copy_root, FIELD));
    }
    if raw_entry.conflict_artifact_count > 0 && raw_entry.conflicted == 0 {
        return Err(native_invalid_response(&identity.working_copy_root, FIELD));
    }
    if raw_entry.conflict_artifact_paths[raw_entry.conflict_artifact_count..]
        .iter()
        .any(|path| !path.is_null())
    {
        return Err(native_invalid_response(&identity.working_copy_root, FIELD));
    }

    let mut artifacts = Vec::with_capacity(raw_entry.conflict_artifact_count);
    let mut seen = BTreeSet::new();
    for raw_path in &raw_entry.conflict_artifact_paths[..raw_entry.conflict_artifact_count] {
        let absolute_path = unsafe { c_string_to_owned(*raw_path, FIELD) }
            .map_err(|failure| native_field_failure(&identity.working_copy_root, failure))?;
        if !is_native_absolute_path(&absolute_path) {
            return Err(native_invalid_response(&identity.working_copy_root, FIELD));
        }
        let artifact_path =
            relative_native_path(&identity.working_copy_root, &absolute_path, FIELD)?;
        if artifact_path == "."
            || !valid_scan_path(&artifact_path)
            || artifact_path
                .split('/')
                .any(|component| component.eq_ignore_ascii_case(".svn"))
            || same_native_path(&artifact_path, owner_path)
        {
            return Err(native_invalid_response(&identity.working_copy_root, FIELD));
        }
        if !seen.insert(native_path_key(&artifact_path)) {
            return Err(native_invalid_response(&identity.working_copy_root, FIELD));
        }
        artifacts.push(artifact_path);
    }
    artifacts.sort();
    Ok(artifacts)
}

fn remove_conflict_artifact_entries(entries: &mut Vec<StatusEntry>) {
    let artifact_paths = entries
        .iter()
        .flat_map(|entry| entry.conflict_artifacts.iter())
        .map(|path| native_path_key(path))
        .collect::<BTreeSet<_>>();
    entries.retain(|entry| {
        entry.local_status != "unversioned"
            || !artifact_paths.contains(&native_path_key(&entry.path))
    });
}

fn is_native_absolute_path(path: &str) -> bool {
    let normalized = path.replace('\\', "/");
    normalized.starts_with('/')
        || (normalized.len() >= 3
            && normalized.as_bytes()[0].is_ascii_alphabetic()
            && normalized.as_bytes()[1] == b':'
            && normalized.as_bytes()[2] == b'/')
}

fn same_native_path(left: &str, right: &str) -> bool {
    native_path_key(left) == native_path_key(right)
}

fn native_path_key(path: &str) -> String {
    let normalized = path.replace('\\', "/");
    if cfg!(windows) {
        normalized.to_ascii_lowercase()
    } else {
        normalized
    }
}

fn status_copy_from_protocol(
    copied: c_int,
    copy_from_path: Option<String>,
    revision: i64,
) -> Option<String> {
    if copied == 0 {
        return None;
    }
    copy_from_path.map(|path| {
        if revision >= 0 {
            format!("{path}@{revision}")
        } else {
            path
        }
    })
}

fn raw_lock_info_to_protocol(
    raw_lock: *const RawLockInfo,
    path: &str,
) -> Result<Option<LockInfo>, BridgeFailure> {
    if raw_lock.is_null() {
        return Ok(None);
    }

    let raw_lock = unsafe { &*raw_lock };
    let token = unsafe { optional_c_string_to_owned(raw_lock.token, "status.lock.token") }
        .map_err(|failure| native_field_failure(path, failure))?;
    let owner = unsafe { optional_c_string_to_owned(raw_lock.owner, "status.lock.owner") }
        .map_err(|failure| native_field_failure(path, failure))?;
    let comment = unsafe { optional_c_string_to_owned(raw_lock.comment, "status.lock.comment") }
        .map_err(|failure| native_field_failure(path, failure))?;
    let created_date =
        unsafe { optional_c_string_to_owned(raw_lock.created_date, "status.lock.createdDate") }
            .map_err(|failure| native_field_failure(path, failure))?;
    let expires_date =
        unsafe { optional_c_string_to_owned(raw_lock.expires_date, "status.lock.expiresDate") }
            .map_err(|failure| native_field_failure(path, failure))?;

    Ok(Some(LockInfo {
        token,
        owner,
        comment,
        created_date,
        expires_date,
        is_remote: raw_lock.is_remote != 0,
    }))
}

fn relative_status_path(root: &str, path: &str) -> Result<String, BridgeFailure> {
    relative_native_path(root, path, "status.path")
}

fn relative_native_path(
    root: &str,
    path: &str,
    field: &'static str,
) -> Result<String, BridgeFailure> {
    let normalized_root = normalize_status_path(root);
    let normalized_path = normalize_status_path(path);
    if normalized_path == normalized_root {
        return Ok(".".to_string());
    }

    let root_prefix = format!("{normalized_root}/");
    let Some(relative) = normalized_path.strip_prefix(&root_prefix) else {
        return Err(native_invalid_response(root, field));
    };
    if relative.is_empty() {
        return Err(native_invalid_response(root, field));
    }

    Ok(relative.to_string())
}

fn raw_history_entry_to_protocol(
    raw_entry: &RawHistoryLogEntry,
    path: &str,
) -> Result<HistoryLogEntry, BridgeFailure> {
    if raw_entry.revision < 0 {
        return Err(native_invalid_response(path, "history.revision"));
    }
    if raw_entry.changed_path_count > 0 && raw_entry.changed_paths.is_null() {
        return Err(native_invalid_response(path, "history.changedPaths"));
    }
    let author = unsafe { optional_c_string_to_owned(raw_entry.author, "history.author") }
        .map_err(|failure| native_field_failure(path, failure))?;
    let date = unsafe { optional_c_string_to_owned(raw_entry.date, "history.date") }
        .map_err(|failure| native_field_failure(path, failure))?;
    let message = unsafe { optional_c_string_to_owned(raw_entry.message, "history.message") }
        .map_err(|failure| native_field_failure(path, failure))?;
    let raw_changed_paths = if raw_entry.changed_path_count == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(raw_entry.changed_paths, raw_entry.changed_path_count) }
    };
    let mut changed_paths = Vec::with_capacity(raw_changed_paths.len());
    for raw_changed_path in raw_changed_paths {
        changed_paths.push(raw_history_changed_path_to_protocol(
            raw_changed_path,
            path,
        )?);
    }

    Ok(HistoryLogEntry {
        revision: raw_entry.revision,
        author,
        date,
        message,
        changed_paths,
        has_children: raw_entry.has_children != 0,
        non_inheritable: raw_entry.non_inheritable != 0,
        subtractive_merge: raw_entry.subtractive_merge != 0,
    })
}

fn raw_history_changed_path_to_protocol(
    raw_changed_path: &RawHistoryLogChangedPath,
    path: &str,
) -> Result<HistoryLogChangedPath, BridgeFailure> {
    let path_value =
        unsafe { c_string_to_owned(raw_changed_path.path, "history.changedPath.path") }
            .map_err(|failure| native_field_failure(path, failure))?;
    let action =
        unsafe { c_string_to_owned(raw_changed_path.action, "history.changedPath.action") }
            .map_err(|failure| native_field_failure(path, failure))?;
    let copy_from_path = unsafe {
        optional_c_string_to_owned(
            raw_changed_path.copy_from_path,
            "history.changedPath.copyFromPath",
        )
    }
    .map_err(|failure| native_field_failure(path, failure))?;
    let copy_from_revision =
        (raw_changed_path.copy_from_revision >= 0).then_some(raw_changed_path.copy_from_revision);
    let node_kind =
        unsafe { c_string_to_owned(raw_changed_path.node_kind, "history.changedPath.nodeKind") }
            .map_err(|failure| native_field_failure(path, failure))?;
    let text_modified = unsafe {
        c_string_to_owned(
            raw_changed_path.text_modified,
            "history.changedPath.textModified",
        )
    }
    .map_err(|failure| native_field_failure(path, failure))?;
    let properties_modified = unsafe {
        c_string_to_owned(
            raw_changed_path.properties_modified,
            "history.changedPath.propertiesModified",
        )
    }
    .map_err(|failure| native_field_failure(path, failure))?;
    if !valid_tristate_word(&text_modified) {
        return Err(native_invalid_response(
            path,
            "history.changedPath.textModified",
        ));
    }
    if !valid_tristate_word(&properties_modified) {
        return Err(native_invalid_response(
            path,
            "history.changedPath.propertiesModified",
        ));
    }

    Ok(HistoryLogChangedPath {
        path: path_value,
        action,
        copy_from_path,
        copy_from_revision,
        node_kind,
        text_modified,
        properties_modified,
    })
}

fn raw_history_blame_line_to_protocol(
    raw_line: &RawHistoryBlameLine,
    path: &str,
) -> Result<HistoryBlameLine, BridgeFailure> {
    if raw_line.line_number <= 0 {
        return Err(native_invalid_response(path, "history.blame.lineNumber"));
    }
    if raw_line.line_byte_count > 0 && raw_line.line_data.is_null() {
        return Err(native_invalid_response(path, "history.blame.lineBase64"));
    }

    let author = unsafe { optional_c_string_to_owned(raw_line.author, "history.blame.author") }
        .map_err(|failure| native_field_failure(path, failure))?;
    let date = unsafe { optional_c_string_to_owned(raw_line.date, "history.blame.date") }
        .map_err(|failure| native_field_failure(path, failure))?;
    let merged_author =
        unsafe { optional_c_string_to_owned(raw_line.merged_author, "history.blame.mergedAuthor") }
            .map_err(|failure| native_field_failure(path, failure))?;
    let merged_date =
        unsafe { optional_c_string_to_owned(raw_line.merged_date, "history.blame.mergedDate") }
            .map_err(|failure| native_field_failure(path, failure))?;
    let merged_path =
        unsafe { optional_c_string_to_owned(raw_line.merged_path, "history.blame.mergedPath") }
            .map_err(|failure| native_field_failure(path, failure))?;
    let line_data = if raw_line.line_byte_count == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(raw_line.line_data, raw_line.line_byte_count) }
    };

    Ok(HistoryBlameLine {
        line_number: u64::try_from(raw_line.line_number)
            .map_err(|_| native_invalid_response(path, "history.blame.lineNumber"))?,
        revision: (raw_line.revision >= 0).then_some(raw_line.revision),
        author,
        date,
        merged_revision: (raw_line.merged_revision >= 0).then_some(raw_line.merged_revision),
        merged_author,
        merged_date,
        merged_path,
        line_base64: STANDARD.encode(line_data),
        byte_length: raw_line.line_byte_count as u64,
        local_change: raw_line.local_change != 0,
    })
}

fn valid_tristate_word(value: &str) -> bool {
    matches!(value, "true" | "false" | "unknown")
}

fn raw_operation_paths_to_protocol(
    raw_paths: *const *const c_char,
    path_count: usize,
    identity: &RepositoryIdentity,
    field: &'static str,
) -> Result<Vec<String>, BridgeFailure> {
    if path_count == 0 {
        return Ok(Vec::new());
    }
    if raw_paths.is_null() {
        return Err(native_invalid_response(&identity.working_copy_root, field));
    }

    let paths = unsafe { slice::from_raw_parts(raw_paths, path_count) };
    let mut protocol_paths = Vec::with_capacity(paths.len());
    for raw_path in paths {
        let absolute_path = unsafe { c_string_to_owned(*raw_path, field) }
            .map_err(|failure| native_field_failure(&identity.working_copy_root, failure))?;
        protocol_paths.push(relative_native_path(
            &identity.working_copy_root,
            &absolute_path,
            field,
        )?);
    }

    Ok(protocol_paths)
}

fn raw_operation_result_to_protocol(
    raw_result: RawOperationResult,
    identity: &RepositoryIdentity,
) -> Result<OperationResult, BridgeFailure> {
    Ok(OperationResult {
        touched_paths: raw_operation_paths_to_protocol(
            raw_result.touched_paths,
            raw_result.touched_path_count,
            identity,
            "operation.touchedPaths",
        )?,
        skipped_paths: raw_operation_paths_to_protocol(
            raw_result.skipped_paths,
            raw_result.skipped_path_count,
            identity,
            "operation.skippedPaths",
        )?,
    })
}

fn raw_property_entry_to_protocol(
    raw_entry: &RawPropertyEntry,
    path: &str,
) -> Result<PropertyEntry, BridgeFailure> {
    let name = unsafe { c_string_to_owned(raw_entry.name, "properties.name") }
        .map_err(|failure| native_field_failure(path, failure))?;
    if !valid_property_name(&name) {
        return Err(native_invalid_response(path, "properties.name"));
    }
    let value = unsafe { c_string_to_owned(raw_entry.value, "properties.value") }
        .map_err(|failure| native_field_failure(path, failure))?;
    let value_encoding =
        unsafe { c_string_to_owned(raw_entry.value_encoding, "properties.valueEncoding") }
            .map_err(|failure| native_field_failure(path, failure))?;
    if value_encoding != "utf8" {
        return Err(native_invalid_response(path, "properties.valueEncoding"));
    }

    Ok(PropertyEntry {
        name,
        value,
        value_encoding,
    })
}

fn normalize_status_path(path: &str) -> String {
    path.replace('\\', "/").trim_end_matches('/').to_string()
}

fn status_summary(entries: &[StatusEntry]) -> StatusSummary {
    let artifact_paths = entries
        .iter()
        .flat_map(|entry| entry.conflict_artifacts.iter())
        .collect::<BTreeSet<_>>();
    let mut local_changes = 0;
    let mut conflicts = 0;
    let mut unversioned = 0;
    for entry in entries {
        if entry.local_status == "unversioned" && artifact_paths.contains(&entry.path) {
            continue;
        }
        if is_local_status_change(entry) {
            local_changes += 1;
        }
        if entry.local_status == "unversioned" {
            unversioned += 1;
        }
        if entry.conflict.is_some() {
            conflicts += 1;
        }
    }

    StatusSummary {
        local_changes,
        remote_changes: 0,
        conflicts,
        unversioned,
    }
}

fn is_local_status_change(entry: &StatusEntry) -> bool {
    entry.conflict.is_some()
        || is_actionable_local_status(&entry.local_status)
        || is_actionable_local_status(&entry.node_status)
        || is_actionable_local_status(&entry.text_status)
        || is_actionable_local_status(&entry.property_status)
}

fn is_actionable_local_status(status: &str) -> bool {
    !matches!(status, "none" | "normal")
}

fn is_actionable_remote_status(status: &str) -> bool {
    !matches!(status, "none" | "normal" | "notChecked")
}

fn is_actionable_remote_entry(entry: &StatusEntry) -> bool {
    if !is_actionable_remote_status(&entry.remote_status) {
        return false;
    }
    entry.kind != "dir"
        || entry.remote_status != "modified"
        || is_actionable_remote_status(&entry.property_status)
}

fn repository_id(identity: &RepositoryIdentity) -> String {
    format!(
        "{}:{}",
        identity.repository_uuid, identity.working_copy_root
    )
}

fn native_field_failure(path: &str, failure: NativeStringFailure) -> BridgeFailure {
    let field = match failure {
        NativeStringFailure::Null(field) | NativeStringFailure::InvalidUtf8 { field, .. } => field,
    };

    BridgeFailure::new(
        "SVN_BRIDGE_INVALID_RESPONSE",
        "native",
        "error.native.bridgeInvalidResponse",
        json!({ "path": path, "field": field }),
        false,
    )
}

fn native_invalid_response(path: &str, field: &'static str) -> BridgeFailure {
    BridgeFailure::new(
        "SVN_BRIDGE_INVALID_RESPONSE",
        "native",
        "error.native.bridgeInvalidResponse",
        json!({ "path": path, "field": field }),
        false,
    )
}

enum NativeStringFailure {
    Null(&'static str),
    InvalidUtf8 {
        field: &'static str,
        source: std::str::Utf8Error,
    },
}

unsafe fn optional_c_string_to_owned(
    ptr: *const c_char,
    field: &'static str,
) -> Result<Option<String>, NativeStringFailure> {
    if ptr.is_null() {
        return Ok(None);
    }

    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map(|value| Some(value.to_string()))
        .map_err(|source| NativeStringFailure::InvalidUtf8 { field, source })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remote_foundation_loader_never_resolves_or_creates_local_runtime() {
        let source = include_str!("native.rs");
        let remote_symbols = source
            .split("impl RemoteNativeSymbols")
            .nth(1)
            .and_then(|tail| tail.split("pub enum NativeBridgeLoadError").next())
            .expect("remote-only symbol loader source section must remain present");
        assert!(!remote_symbols.contains("runtime_create"));
        assert!(!remote_symbols.contains("runtime_destroy"));

        let remote_bridge = source
            .split("impl RemoteNativeBridge")
            .nth(1)
            .and_then(|tail| tail.split("impl NativeBridge").next())
            .expect("remote-only bridge source section must remain present");
        assert!(!remote_bridge.contains("runtime_create"));
        assert!(!remote_bridge.contains("svn_config_get_config"));
    }

    #[test]
    fn native_bridge_startup_errors_are_stable_and_path_safe() {
        let missing = NativeBridgeLoadError::MissingLibrary(PathBuf::from(
            r"C:\Users\fixture\secret\subversionr_svn_bridge.dll",
        ));
        let missing_record = missing.startup_error();
        assert_eq!(
            missing_record["code"],
            "SUBVERSIONR_NATIVE_BRIDGE_LIBRARY_MISSING"
        );
        assert_eq!(missing_record["category"], "process");
        assert_eq!(missing_record["safeArgs"], json!({}));
        assert!(!missing_record.to_string().contains("fixture"));

        let create_failed = NativeBridgeLoadError::RuntimeCreateFailed(17).startup_error();
        assert_eq!(
            create_failed["code"],
            "SUBVERSIONR_NATIVE_BRIDGE_RUNTIME_CREATE_FAILED"
        );
        assert_eq!(create_failed["safeArgs"], json!({ "status": 17 }));
        assert_eq!(create_failed["retryable"], false);
        assert_eq!(create_failed["diagnostics"], serde_json::Value::Null);
    }

    #[test]
    fn native_diagnostic_causes_map_only_safe_symbolic_names() {
        let entry = |name: &str| SvnErrorDiagnosticEntry {
            code: 1,
            name: name.to_string(),
        };
        assert_eq!(
            native_failure_cause(&[entry("SVN_ERR_FS_TXN_OUT_OF_DATE")]),
            OperationFailureCause::OutOfDate
        );
        assert_eq!(
            native_failure_cause(&[entry("SVN_ERR_WC_FOUND_CONFLICT")]),
            OperationFailureCause::ConflictPresent
        );
        assert_eq!(
            native_failure_cause(&[entry("SVN_ERR_RA_NOT_AUTHORIZED")]),
            OperationFailureCause::AuthenticationFailed
        );
        assert_eq!(
            native_failure_cause(&[entry("SVN_ERR_WC_NOT_WORKING_COPY")]),
            OperationFailureCause::NotWorkingCopy
        );
        assert_eq!(
            native_failure_cause(&[entry("SVN_ERR_FS_GENERAL")]),
            OperationFailureCause::UnknownNative
        );
    }

    #[test]
    fn status_summary_counts_conflict_metadata_as_a_local_change() {
        let mut entry = status_entry("src/conflicted.txt", "normal");
        entry.conflict = Some("text".to_string());

        let summary = status_summary(&[entry]);

        assert_eq!(summary.local_changes, 1);
        assert_eq!(summary.conflicts, 1);
    }

    #[test]
    fn status_summary_counts_property_only_changes_as_local_changes() {
        let mut entry = status_entry("src/properties.txt", "normal");
        entry.property_status = "modified".to_string();

        let summary = status_summary(&[entry]);

        assert_eq!(summary.local_changes, 1);
        assert_eq!(summary.conflicts, 0);
        assert_eq!(summary.unversioned, 0);
    }

    #[test]
    fn raw_status_entry_to_protocol_preserves_copy_from_revision_and_move_metadata() {
        let identity = RepositoryIdentity {
            repository_uuid: "uuid".to_string(),
            repository_root_url: "file:///repo".to_string(),
            working_copy_root: "C:/workspace/wc".to_string(),
            workspace_scope_root: "C:/workspace/wc".to_string(),
            format: 31,
        };
        let path = CString::new("C:/workspace/wc/src/copied.c").unwrap();
        let kind = CString::new("file").unwrap();
        let status = CString::new("added").unwrap();
        let property_status = CString::new("normal").unwrap();
        let depth = CString::new("infinity").unwrap();
        let copy_from = CString::new("branches/stable/src/copied.c").unwrap();
        let moved_from = CString::new("C:/workspace/wc/src/old.c").unwrap();
        let mut raw_entry =
            raw_status_entry_fixture(&path, &kind, &status, &property_status, &depth);
        raw_entry.revision = 99;
        raw_entry.changed_revision = 42;
        raw_entry.copied = 1;
        raw_entry.copy_from_path = copy_from.as_ptr();
        raw_entry.copy_from_revision = 42;
        raw_entry.moved_from_abspath = moved_from.as_ptr();

        let entry =
            raw_status_entry_to_protocol(&raw_entry, &identity, 7).expect("status should convert");

        assert_eq!(
            entry.copy.as_deref(),
            Some("branches/stable/src/copied.c@42")
        );
        assert_eq!(entry.move_.as_deref(), Some("src/old.c"));
    }

    #[test]
    fn raw_status_entry_to_protocol_strictly_validates_and_sorts_conflict_artifacts() {
        let identity = RepositoryIdentity {
            repository_uuid: "uuid".to_string(),
            repository_root_url: "file:///repo".to_string(),
            working_copy_root: "C:/workspace/wc".to_string(),
            workspace_scope_root: "C:/workspace/wc".to_string(),
            format: 31,
        };
        let path = CString::new("C:/workspace/wc/src/conflicted.txt").unwrap();
        let kind = CString::new("file").unwrap();
        let status = CString::new("conflicted").unwrap();
        let normal = CString::new("normal").unwrap();
        let depth = CString::new("infinity").unwrap();
        let incoming = CString::new("C:/workspace/wc/src/conflicted.txt.r8").unwrap();
        let mine = CString::new("C:/workspace/wc/src/conflicted.txt.mine").unwrap();
        let bmp = CString::new("C:/workspace/wc/src/\u{e000}.mine").unwrap();
        let non_bmp = CString::new("C:/workspace/wc/src/\u{10000}.mine").unwrap();
        let mut raw_entry = raw_status_entry_fixture(&path, &kind, &status, &normal, &depth);
        raw_entry.conflicted = 1;
        raw_entry.conflict_artifact_paths =
            [incoming.as_ptr(), mine.as_ptr(), ptr::null(), ptr::null()];
        raw_entry.conflict_artifact_count = 2;

        let entry = raw_status_entry_to_protocol(&raw_entry, &identity, 7)
            .expect("conflict artifacts should convert");

        assert_eq!(
            entry.conflict_artifacts,
            vec![
                "src/conflicted.txt.mine".to_string(),
                "src/conflicted.txt.r8".to_string()
            ]
        );

        let mut unicode = raw_status_entry_fixture(&path, &kind, &status, &normal, &depth);
        unicode.conflicted = 1;
        unicode.conflict_artifact_paths =
            [non_bmp.as_ptr(), bmp.as_ptr(), ptr::null(), ptr::null()];
        unicode.conflict_artifact_count = 2;
        let unicode_entry = raw_status_entry_to_protocol(&unicode, &identity, 7)
            .expect("conflict artifacts must use UTF-8 byte ordering");
        assert_eq!(
            unicode_entry.conflict_artifacts,
            vec![
                "src/\u{e000}.mine".to_string(),
                "src/\u{10000}.mine".to_string()
            ]
        );

        let invalid_paths = [
            CString::new("C:/outside.txt").unwrap(),
            CString::new("C:/workspace/wc/src/conflicted.txt").unwrap(),
            CString::new("C:/workspace/wc/.svn/conflict.tmp").unwrap(),
            CString::new("C:/workspace/wc/src/.SvN/conflict.tmp").unwrap(),
            CString::new("relative/conflict.tmp").unwrap(),
        ];
        for invalid_path in &invalid_paths {
            let mut invalid = raw_status_entry_fixture(&path, &kind, &status, &normal, &depth);
            invalid.conflicted = 1;
            invalid.conflict_artifact_paths[0] = invalid_path.as_ptr();
            invalid.conflict_artifact_count = 1;
            let failure = raw_status_entry_to_protocol(&invalid, &identity, 7)
                .expect_err("invalid conflict artifact path must fail");
            assert_eq!(failure.code, "SVN_BRIDGE_INVALID_RESPONSE");
            assert_eq!(failure.args["field"], "status.conflictArtifacts");
        }

        let mut duplicate = raw_status_entry_fixture(&path, &kind, &status, &normal, &depth);
        duplicate.conflicted = 1;
        duplicate.conflict_artifact_paths = [
            incoming.as_ptr(),
            incoming.as_ptr(),
            ptr::null(),
            ptr::null(),
        ];
        duplicate.conflict_artifact_count = 2;
        assert!(raw_status_entry_to_protocol(&duplicate, &identity, 7).is_err());

        let mut excessive = raw_status_entry_fixture(&path, &kind, &status, &normal, &depth);
        excessive.conflicted = 1;
        excessive.conflict_artifact_count = 5;
        assert!(raw_status_entry_to_protocol(&excessive, &identity, 7).is_err());

        let mut non_conflict = raw_status_entry_fixture(&path, &kind, &status, &normal, &depth);
        non_conflict.conflict_artifact_paths[0] = incoming.as_ptr();
        non_conflict.conflict_artifact_count = 1;
        assert!(raw_status_entry_to_protocol(&non_conflict, &identity, 7).is_err());

        let mut non_null_tail = raw_status_entry_fixture(&path, &kind, &status, &normal, &depth);
        non_null_tail.conflicted = 1;
        non_null_tail.conflict_artifact_paths[1] = incoming.as_ptr();
        assert!(raw_status_entry_to_protocol(&non_null_tail, &identity, 7).is_err());

        let mut null_counted_path =
            raw_status_entry_fixture(&path, &kind, &status, &normal, &depth);
        null_counted_path.conflicted = 1;
        null_counted_path.conflict_artifact_count = 1;
        assert!(raw_status_entry_to_protocol(&null_counted_path, &identity, 7).is_err());

        let invalid_utf8 = [0xff_u8, 0];
        let mut invalid_utf8_path =
            raw_status_entry_fixture(&path, &kind, &status, &normal, &depth);
        invalid_utf8_path.conflicted = 1;
        invalid_utf8_path.conflict_artifact_paths[0] = invalid_utf8.as_ptr().cast();
        invalid_utf8_path.conflict_artifact_count = 1;
        assert!(raw_status_entry_to_protocol(&invalid_utf8_path, &identity, 7).is_err());

        let mut remote_artifact = raw_status_entry_fixture(&path, &kind, &status, &normal, &depth);
        remote_artifact.conflicted = 1;
        remote_artifact.conflict_artifact_paths[0] = incoming.as_ptr();
        remote_artifact.conflict_artifact_count = 1;
        let failure = raw_remote_status_entry_to_protocol(&remote_artifact, &identity, 7)
            .expect_err("remote status must reject conflict artifacts");
        assert_eq!(failure.code, "SVN_BRIDGE_INVALID_RESPONSE");
        assert_eq!(failure.args["field"], "remoteStatus.conflictArtifacts");
    }

    #[test]
    fn conflict_artifact_entries_are_removed_without_hiding_unrelated_unversioned_files() {
        let mut owner = status_entry("src/conflicted.txt", "conflicted");
        owner.conflict = Some("conflicted".to_string());
        owner.conflict_artifacts = vec!["src/conflicted.txt.mine".to_string()];
        let artifact = status_entry("src/conflicted.txt.mine", "unversioned");
        let ordinary = status_entry("src/conflicted-copy.txt.mine", "unversioned");
        let mut entries = vec![owner, artifact, ordinary];

        remove_conflict_artifact_entries(&mut entries);
        let summary = status_summary(&entries);

        assert_eq!(
            entries
                .iter()
                .map(|entry| entry.path.as_str())
                .collect::<Vec<_>>(),
            vec!["src/conflicted.txt", "src/conflicted-copy.txt.mine"]
        );
        assert_eq!(summary.conflicts, 1);
        assert_eq!(summary.unversioned, 1);
    }

    #[test]
    fn scan_path_outputs_slash_normalized_absolute_paths_for_bridge_calls() {
        assert_eq!(
            scan_path("C:\\workspace\\wc", "src/main.c"),
            "C:/workspace/wc/src/main.c"
        );
        assert_eq!(scan_path("C:\\workspace\\wc", "."), "C:/workspace/wc");
        assert_eq!(scan_path("C:\\", "tracked.txt"), "C:/tracked.txt");
    }

    #[test]
    fn update_scan_path_rejects_invalid_selected_paths_before_bridge_calls() {
        assert_eq!(
            update_scan_path("C:\\workspace\\wc", ".").expect("root update path should be valid"),
            "C:/workspace/wc"
        );
        assert_eq!(
            update_scan_path("C:\\workspace\\wc", "src/main.c")
                .expect("selected update path should be valid"),
            "C:/workspace/wc/src/main.c"
        );

        for path in [
            "",
            "../src",
            "/src/main.c",
            "C:/workspace/wc/src/main.c",
            "src\\main.c",
        ] {
            assert!(update_scan_path("C:\\workspace\\wc", path).is_err());
        }
    }

    #[test]
    fn commit_scan_path_validation_accepts_root_and_repository_relative_paths() {
        assert!(valid_commit_scan_path("."));
        assert!(valid_commit_scan_path("src/main.c"));
        assert_eq!(scan_path("C:\\workspace\\wc", "."), "C:/workspace/wc");

        for path in [
            "",
            "../src",
            "/src/main.c",
            "C:/workspace/wc/src/main.c",
            "src\\main.c",
        ] {
            assert!(!valid_commit_scan_path(path), "{path} should be invalid");
        }
    }

    #[test]
    fn update_revision_and_depth_validation_accepts_beta_supported_values() {
        for revision in ["head", "0", "42", "2147483647"] {
            assert!(
                valid_update_revision(revision),
                "{revision} should be valid"
            );
        }
        for revision in ["", "r42", "042", "-1", "2147483648"] {
            assert!(
                !valid_update_revision(revision),
                "{revision} should be invalid"
            );
        }
        for depth in ["workingCopy", "empty", "files", "immediates", "infinity"] {
            assert!(valid_update_depth(depth), "{depth} should be valid");
        }
        for depth in ["", "unknown", "exclude"] {
            assert!(!valid_update_depth(depth), "{depth} should be invalid");
        }
    }

    #[test]
    fn checkout_validation_accepts_only_explicit_beta_checkout_inputs() {
        for depth in ["empty", "files", "immediates", "infinity"] {
            assert!(valid_checkout_depth(depth), "{depth} should be valid");
        }
        for depth in ["", "workingCopy", "unknown", "exclude"] {
            assert!(!valid_checkout_depth(depth), "{depth} should be invalid");
        }

        for url in [
            "file:///C:/repo/project/trunk",
            "https://svn.example.invalid/project/trunk",
            "svn://127.0.0.1/project/trunk",
        ] {
            assert!(valid_checkout_url(url), "{url} should be valid");
        }
        for url in ["", "   ", "https://svn.example.invalid/project\ntrunk"] {
            assert!(!valid_checkout_url(url), "{url} should be invalid");
        }

        let absolute_checkout_path = std::env::current_dir()
            .expect("current directory should be available")
            .join("checkout")
            .join("project");
        let absolute_checkout_path = absolute_checkout_path.to_string_lossy();
        assert!(
            valid_checkout_target_path(&absolute_checkout_path),
            "{absolute_checkout_path} should be valid"
        );
        for path in ["", "project", "../project", "C:/checkout/project\nnext"] {
            assert!(
                !valid_checkout_target_path(path),
                "{path} should be invalid"
            );
        }
    }

    #[test]
    fn repository_checkout_failure_maps_beta_status_contract() {
        let failed = repository_checkout_failure(2, "C:/checkout/project");
        assert_eq!(failed.code, "SVN_REPOSITORY_CHECKOUT_FAILED");
        assert_eq!(failed.message_key, "error.native.repositoryCheckoutFailed");
        assert_eq!(failed.args["path"], "C:/checkout/project");
        assert_eq!(failed.args["status"], 2);

        let cancelled = repository_checkout_failure(RAW_OPERATION_CANCELLED, "C:/checkout/project");
        assert_eq!(cancelled.code, "SVN_OPERATION_CANCELLED");
        assert_eq!(cancelled.category, "cancelled");
        assert_eq!(cancelled.message_key, "error.native.operationCancelled");
    }

    #[test]
    fn operation_relocate_failure_maps_beta_status_contract() {
        let failed = operation_relocate_failure(2, "C:/workspace/wc");
        assert_eq!(failed.code, "SVN_OPERATION_RELOCATE_FAILED");
        assert_eq!(failed.message_key, "error.native.operationRelocateFailed");
        assert_eq!(failed.args["path"], "C:/workspace/wc");
        assert_eq!(failed.args["status"], 2);

        let cancelled = operation_relocate_failure(RAW_OPERATION_CANCELLED, "C:/workspace/wc");
        assert_eq!(cancelled.code, "SVN_OPERATION_CANCELLED");
        assert_eq!(cancelled.category, "cancelled");
        assert_eq!(cancelled.message_key, "error.native.operationCancelled");
    }

    #[test]
    fn lock_and_unlock_partial_failures_preserve_stable_codes_and_mutation_signal() {
        let lock_failure =
            operation_lock_failure(RAW_OPERATION_PARTIAL_FAILURE, "C:/workspace/wc/first.txt");
        assert_eq!(lock_failure.code, "SVN_OPERATION_LOCK_FAILED");
        assert_eq!(lock_failure.message_key, "error.native.operationLockFailed");
        assert_eq!(lock_failure.args["status"], RAW_OPERATION_PARTIAL_FAILURE);
        assert_eq!(lock_failure.args["mayHaveMutated"].as_bool(), Some(true));

        let unlock_failure =
            operation_unlock_failure(RAW_OPERATION_PARTIAL_FAILURE, "C:/workspace/wc/first.txt");
        assert_eq!(unlock_failure.code, "SVN_OPERATION_UNLOCK_FAILED");
        assert_eq!(
            unlock_failure.message_key,
            "error.native.operationUnlockFailed"
        );
        assert_eq!(unlock_failure.args["status"], RAW_OPERATION_PARTIAL_FAILURE);
        assert_eq!(unlock_failure.args["mayHaveMutated"].as_bool(), Some(true));

        let ordinary_lock_failure = operation_lock_failure(2, "C:/workspace/wc/first.txt");
        assert_eq!(
            ordinary_lock_failure.args["mayHaveMutated"].as_bool(),
            Some(false)
        );
        let ordinary_unlock_failure = operation_unlock_failure(2, "C:/workspace/wc/first.txt");
        assert_eq!(
            ordinary_unlock_failure.args["mayHaveMutated"].as_bool(),
            Some(false)
        );

        let cancelled_after_mutation =
            operation_lock_failure(RAW_OPERATION_PARTIAL_CANCELLED, "C:/workspace/wc/first.txt");
        assert_eq!(cancelled_after_mutation.code, "SVN_OPERATION_CANCELLED");
        assert_eq!(cancelled_after_mutation.category, "cancelled");
        assert_eq!(
            cancelled_after_mutation.args["mayHaveMutated"].as_bool(),
            Some(true)
        );

        let callback_failed_after_mutation = operation_unlock_failure(
            RAW_OPERATION_PARTIAL_CANCEL_CALLBACK_FAILED,
            "C:/workspace/wc/first.txt",
        );
        assert_eq!(
            callback_failed_after_mutation.code,
            "SVN_OPERATION_CANCEL_CALLBACK_FAILED"
        );
        assert_eq!(
            callback_failed_after_mutation.args["mayHaveMutated"].as_bool(),
            Some(true)
        );
    }

    #[test]
    fn operation_commit_failure_maps_missing_local_author_without_path_disclosure() {
        let failure = operation_commit_failure(
            RAW_OPERATION_LOCAL_COMMIT_AUTHOR_UNAVAILABLE,
            "C:/Users/fixture/private/wc/tracked.txt",
        );

        assert_eq!(failure.code, "SUBVERSIONR_LOCAL_COMMIT_AUTHOR_UNAVAILABLE");
        assert_eq!(failure.category, "native");
        assert_eq!(
            failure.message_key,
            "error.native.localCommitAuthorUnavailable"
        );
        assert_eq!(
            failure.args,
            json!({ "status": RAW_OPERATION_LOCAL_COMMIT_AUTHOR_UNAVAILABLE })
        );
        assert!(!failure.args.to_string().contains("fixture"));
        assert!(!failure.retryable);
    }

    #[test]
    fn native_cancel_callback_maps_token_state_for_libsvn() {
        struct StaticCancellationToken(bool);

        impl crate::BridgeCancellationToken for StaticCancellationToken {
            fn is_cancelled(&self) -> bool {
                self.0
            }
        }

        let continue_token = StaticCancellationToken(false);
        let mut continue_baton = NativeCancelBaton {
            token: &continue_token,
        };
        let continue_status = unsafe {
            native_cancel_callback((&mut continue_baton as *mut NativeCancelBaton<'_>).cast())
        };
        assert_eq!(continue_status, RAW_CANCEL_CALLBACK_CONTINUE);

        let cancel_token = StaticCancellationToken(true);
        let mut cancel_baton = NativeCancelBaton {
            token: &cancel_token,
        };
        let cancel_status = unsafe {
            native_cancel_callback((&mut cancel_baton as *mut NativeCancelBaton<'_>).cast())
        };
        assert_eq!(cancel_status, RAW_CANCEL_CALLBACK_CANCEL);
    }

    #[test]
    fn status_snapshot_failure_maps_cancelled_status_contract() {
        let failure = status_snapshot_failure(RAW_STATUS_CANCELLED, "C:/workspace/wc/src/main.c");

        assert_eq!(failure.code, "SVN_STATUS_CANCELLED");
        assert_eq!(failure.category, "cancelled");
        assert_eq!(failure.message_key, "error.native.statusCancelled");
        assert_eq!(failure.args["path"], "C:/workspace/wc/src/main.c");
        assert_eq!(failure.args["status"], RAW_STATUS_CANCELLED);
        assert!(!failure.retryable);
    }

    #[test]
    fn native_auth_request_ids_are_not_reused_across_batons() {
        let mut first_broker = crate::UnavailableAuthRequestBroker;
        let mut second_broker = crate::UnavailableAuthRequestBroker;
        let mut first_baton = NativeAuthBaton::new(&mut first_broker, None, None);
        let mut second_baton = NativeAuthBaton::new(&mut second_broker, None, None);

        let first_id = first_baton.request_id("credential");
        let second_id = second_baton.request_id("credential");

        assert_ne!(first_id, second_id);
        assert!(first_id.starts_with("native-credential-"));
        assert!(second_id.starts_with("native-credential-"));
        assert!(
            native_auth_request_sequence(&second_id, "native-credential-")
                > native_auth_request_sequence(&first_id, "native-credential-")
        );
    }

    #[test]
    fn native_parent_credential_callback_rejects_without_invoking_broker() {
        let mut broker = RecordingAuthBroker::empty();
        let mut baton =
            NativeAuthBaton::new(&mut broker, None, Some("C:/workspace/wc".to_string()));
        let realm = CString::new("<https://svn.example.com> SubversionR").unwrap();
        let username = CString::new("alice").unwrap();
        let working_copy_root = CString::new("C:/workspace/wc").unwrap();
        let request = RawCredentialRequest {
            realm: realm.as_ptr(),
            username: username.as_ptr(),
            may_save: 1,
            working_copy_root: working_copy_root.as_ptr(),
        };
        let mut response = RawCredentialResponse {
            username: ptr::null(),
            secret: ptr::null(),
            may_save: 1,
        };

        let status = unsafe {
            native_credential_callback(
                (&mut baton as *mut NativeAuthBaton<'_>).cast::<c_void>(),
                &request,
                &mut response,
            )
        };

        assert_eq!(status, RAW_AUTH_CALLBACK_DENIED);
        assert!(response.username.is_null());
        assert!(response.secret.is_null());
        let failure = baton
            .failure()
            .expect("parent credential route must fail closed");
        assert_eq!(
            failure.code,
            "SUBVERSIONR_CREDENTIAL_REMOTE_WORKER_REQUIRED"
        );
        assert_eq!(failure.category, "auth");
        assert_eq!(
            failure.message_key,
            "error.auth.credentialRemoteWorkerRequired"
        );
        assert_eq!(failure.args["method"], "credentials/request");
    }

    #[test]
    fn native_credential_error_allowlist_preserves_current_codes_with_safe_args() {
        for (code, category, message_key) in [
            (
                "SUBVERSIONR_CREDENTIAL_SECRET_INVALID",
                "auth",
                "error.auth.credentialSecretInvalid",
            ),
            (
                "SUBVERSIONR_CREDENTIAL_TIMEOUT",
                "auth",
                "error.auth.credentialTimeout",
            ),
            (
                "SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE",
                "lifecycle",
                "error.auth.credentialUntrustedWorkspace",
            ),
        ] {
            let error = subversionr_protocol::CredentialError {
                code: code.to_string(),
                category: category.to_string(),
                message_key: message_key.to_string(),
                args: json!({ "secret": "must-not-leak" }),
                retryable: false,
            };

            let failure = credential_error_to_bridge(&error, json!({ "authorityHash": "safe" }));

            assert_eq!(failure.code, code);
            assert_eq!(failure.category, category);
            assert_eq!(failure.message_key, message_key);
            assert_eq!(failure.args, json!({ "authorityHash": "safe" }));
        }
    }

    #[test]
    fn native_certificate_callback_computes_sha256_der_and_preserves_failure_bits() {
        let der = b"subversionr test certificate";
        let ascii_cert = CString::new(STANDARD.encode(der)).unwrap();
        let expected_fingerprint = sha256_hex(der);
        let mut broker = RecordingAuthBroker::certificate_trust(
            "permanent",
            expected_fingerprint.clone(),
            "sha256-der",
        );
        let mut baton =
            NativeAuthBaton::new(&mut broker, None, Some("C:/workspace/wc".to_string()));
        let realm = CString::new("<https://svn.example.com:443> SubversionR").unwrap();
        let host = CString::new("svn.example.com").unwrap();
        let valid_from = CString::new("2026-06-01T00:00:00Z").unwrap();
        let valid_to = CString::new("2026-07-01T00:00:00Z").unwrap();
        let issuer = CString::new("CN=Example Issuer").unwrap();
        let subject = CString::new("CN=svn.example.com").unwrap();
        let failure_bits = RAW_CERT_FAILURE_UNKNOWN_CA | RAW_CERT_FAILURE_CN_MISMATCH;
        let request = RawCertificateRequest {
            realm: realm.as_ptr(),
            host: host.as_ptr(),
            ascii_cert: ascii_cert.as_ptr(),
            valid_from: valid_from.as_ptr(),
            valid_to: valid_to.as_ptr(),
            issuer: issuer.as_ptr(),
            subject: subject.as_ptr(),
            failures: failure_bits,
            may_save: 1,
            working_copy_root: ptr::null(),
        };
        let mut response = RawCertificateResponse {
            accepted_failures: 0,
            may_save: 1,
        };

        let status = unsafe {
            native_certificate_callback(
                (&mut baton as *mut NativeAuthBaton<'_>).cast::<c_void>(),
                &request,
                &mut response,
            )
        };

        assert_eq!(status, RAW_AUTH_CALLBACK_OK);
        assert_eq!(response.accepted_failures, failure_bits);
        assert_eq!(response.may_save, 0);
        assert!(baton.failure().is_none());
        drop(baton);

        assert_eq!(broker.certificate_requests.len(), 1);
        let captured = &broker.certificate_requests[0];
        assert!(captured.request_id.starts_with("native-certificate-"));
        assert_eq!(captured.realm, "<https://svn.example.com:443> SubversionR");
        assert_eq!(captured.host, "svn.example.com");
        assert_eq!(captured.fingerprint, expected_fingerprint);
        assert_eq!(captured.fingerprint_algorithm, "sha256-der");
        assert_eq!(captured.failures, vec!["commonNameMismatch", "unknownCa"]);
        assert_eq!(captured.valid_from, "2026-06-01T00:00:00Z");
        assert_eq!(captured.valid_to, "2026-07-01T00:00:00Z");
        assert_eq!(captured.issuer.as_deref(), Some("CN=Example Issuer"));
        assert_eq!(captured.subject.as_deref(), Some("CN=svn.example.com"));
        assert!(captured.persistence_allowed);
    }

    #[test]
    fn native_certificate_callback_rejects_mismatched_trust_identity() {
        let ascii_cert = CString::new(STANDARD.encode(b"certificate")).unwrap();
        let mut broker =
            RecordingAuthBroker::certificate_trust("once", "different".to_string(), "sha256-der");
        let mut baton =
            NativeAuthBaton::new(&mut broker, None, Some("C:/workspace/wc".to_string()));
        let realm = CString::new("<https://svn.example.com:443> SubversionR").unwrap();
        let host = CString::new("svn.example.com").unwrap();
        let valid_from = CString::new("2026-06-01T00:00:00Z").unwrap();
        let valid_to = CString::new("2026-07-01T00:00:00Z").unwrap();
        let request = RawCertificateRequest {
            realm: realm.as_ptr(),
            host: host.as_ptr(),
            ascii_cert: ascii_cert.as_ptr(),
            valid_from: valid_from.as_ptr(),
            valid_to: valid_to.as_ptr(),
            issuer: ptr::null(),
            subject: ptr::null(),
            failures: RAW_CERT_FAILURE_UNKNOWN_CA,
            may_save: 0,
            working_copy_root: ptr::null(),
        };
        let mut response = RawCertificateResponse {
            accepted_failures: 0,
            may_save: 0,
        };

        let status = unsafe {
            native_certificate_callback(
                (&mut baton as *mut NativeAuthBaton<'_>).cast::<c_void>(),
                &request,
                &mut response,
            )
        };

        assert_eq!(status, RAW_AUTH_CALLBACK_DENIED);
        assert_eq!(response.accepted_failures, 0);
        let failure = baton.failure().expect("mismatch should be captured");
        assert_eq!(failure.code, "SUBVERSIONR_AUTH_RESPONSE_INVALID");
        assert_eq!(failure.message_key, "error.auth.responseInvalid");
        assert_eq!(failure.args["method"], "certificate/request");
    }

    #[test]
    fn native_certificate_callback_rejects_missing_validity_dates() {
        let ascii_cert = CString::new(STANDARD.encode(b"certificate")).unwrap();
        let mut broker = RecordingAuthBroker::certificate(CertificateTrustResponse::Trust {
            request_id: "native-certificate-1".to_string(),
            trust: "once".to_string(),
            fingerprint: sha256_hex(b"certificate"),
            fingerprint_algorithm: "sha256-der".to_string(),
        });
        let mut baton =
            NativeAuthBaton::new(&mut broker, None, Some("C:/workspace/wc".to_string()));
        let realm = CString::new("<https://svn.example.com:443> SubversionR").unwrap();
        let host = CString::new("svn.example.com").unwrap();
        let request = RawCertificateRequest {
            realm: realm.as_ptr(),
            host: host.as_ptr(),
            ascii_cert: ascii_cert.as_ptr(),
            valid_from: ptr::null(),
            valid_to: ptr::null(),
            issuer: ptr::null(),
            subject: ptr::null(),
            failures: RAW_CERT_FAILURE_UNKNOWN_CA,
            may_save: 0,
            working_copy_root: ptr::null(),
        };
        let mut response = RawCertificateResponse {
            accepted_failures: 0,
            may_save: 0,
        };

        let status = unsafe {
            native_certificate_callback(
                (&mut baton as *mut NativeAuthBaton<'_>).cast::<c_void>(),
                &request,
                &mut response,
            )
        };

        assert_eq!(status, RAW_AUTH_CALLBACK_DENIED);
        assert_eq!(response.accepted_failures, 0);
        let failure = baton.failure().expect("missing dates should be captured");
        assert_eq!(failure.code, "SUBVERSIONR_AUTH_RESPONSE_INVALID");
        assert_eq!(failure.message_key, "error.auth.responseInvalid");
        assert_eq!(failure.args["method"], "certificate/request");
        drop(baton);

        assert!(broker.certificate_requests.is_empty());
    }

    #[test]
    fn native_certificate_callback_rejects_unrecognized_trust_decision() {
        let ascii_cert = CString::new(STANDARD.encode(b"certificate")).unwrap();
        let expected_fingerprint = sha256_hex(b"certificate");
        let mut broker =
            RecordingAuthBroker::certificate_trust("forever", expected_fingerprint, "sha256-der");
        let mut baton =
            NativeAuthBaton::new(&mut broker, None, Some("C:/workspace/wc".to_string()));
        let realm = CString::new("<https://svn.example.com:443> SubversionR").unwrap();
        let host = CString::new("svn.example.com").unwrap();
        let valid_from = CString::new("2026-06-01T00:00:00Z").unwrap();
        let valid_to = CString::new("2026-07-01T00:00:00Z").unwrap();
        let request = RawCertificateRequest {
            realm: realm.as_ptr(),
            host: host.as_ptr(),
            ascii_cert: ascii_cert.as_ptr(),
            valid_from: valid_from.as_ptr(),
            valid_to: valid_to.as_ptr(),
            issuer: ptr::null(),
            subject: ptr::null(),
            failures: RAW_CERT_FAILURE_UNKNOWN_CA,
            may_save: 1,
            working_copy_root: ptr::null(),
        };
        let mut response = RawCertificateResponse {
            accepted_failures: 0,
            may_save: 0,
        };

        let status = unsafe {
            native_certificate_callback(
                (&mut baton as *mut NativeAuthBaton<'_>).cast::<c_void>(),
                &request,
                &mut response,
            )
        };

        assert_eq!(status, RAW_AUTH_CALLBACK_DENIED);
        assert_eq!(response.accepted_failures, 0);
        let failure = baton.failure().expect("invalid trust should fail");
        assert_eq!(failure.code, "SUBVERSIONR_AUTH_RESPONSE_INVALID");
        assert_eq!(failure.message_key, "error.auth.responseInvalid");
        assert_eq!(failure.args["method"], "certificate/request");
    }

    #[test]
    fn native_certificate_callback_records_panic_failure_without_crossing_ffi() {
        let ascii_cert = CString::new(STANDARD.encode(b"certificate")).unwrap();
        let mut broker = RecordingAuthBroker::certificate_panic();
        let mut baton =
            NativeAuthBaton::new(&mut broker, None, Some("C:/workspace/wc".to_string()));
        let realm = CString::new("<https://svn.example.com:443> SubversionR").unwrap();
        let host = CString::new("svn.example.com").unwrap();
        let valid_from = CString::new("2026-06-01T00:00:00Z").unwrap();
        let valid_to = CString::new("2026-07-01T00:00:00Z").unwrap();
        let request = RawCertificateRequest {
            realm: realm.as_ptr(),
            host: host.as_ptr(),
            ascii_cert: ascii_cert.as_ptr(),
            valid_from: valid_from.as_ptr(),
            valid_to: valid_to.as_ptr(),
            issuer: ptr::null(),
            subject: ptr::null(),
            failures: RAW_CERT_FAILURE_UNKNOWN_CA,
            may_save: 1,
            working_copy_root: ptr::null(),
        };
        let mut response = RawCertificateResponse {
            accepted_failures: 0,
            may_save: 0,
        };

        let status = unsafe {
            native_certificate_callback(
                (&mut baton as *mut NativeAuthBaton<'_>).cast::<c_void>(),
                &request,
                &mut response,
            )
        };

        assert_eq!(status, RAW_AUTH_CALLBACK_DENIED);
        assert_eq!(response.accepted_failures, 0);
        let failure = baton.failure().expect("panic should be captured");
        assert_eq!(failure.code, "SUBVERSIONR_AUTH_RESPONSE_INVALID");
        assert_eq!(failure.message_key, "error.auth.responseInvalid");
        assert_eq!(failure.args["method"], "certificate/request");
    }

    #[test]
    fn remote_url_probe_failure_redacts_raw_url_from_safe_args() {
        let failure = remote_url_probe_failure(2, "https://alice:secret@example.test/repo");

        assert_eq!(failure.code, "SVN_REMOTE_INFO_FAILED");
        assert_eq!(failure.args["status"], 2);
        assert!(failure.args["urlHash"].as_str().is_some());
        assert!(!failure.args.to_string().contains("alice"));
        assert!(!failure.args.to_string().contains("secret"));
        assert!(!failure.args.to_string().contains("example.test"));
    }

    fn status_entry(path: &str, status: &str) -> StatusEntry {
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
            conflict_artifacts: vec![],
            external: false,
            generation: 1,
        }
    }

    fn raw_status_entry_fixture(
        path: &CString,
        kind: &CString,
        status: &CString,
        property_status: &CString,
        depth: &CString,
    ) -> RawStatusEntry {
        RawStatusEntry {
            path: path.as_ptr(),
            kind: kind.as_ptr(),
            node_status: status.as_ptr(),
            text_status: status.as_ptr(),
            property_status: property_status.as_ptr(),
            repos_node_status: property_status.as_ptr(),
            repos_text_status: property_status.as_ptr(),
            repos_property_status: property_status.as_ptr(),
            repos_kind: kind.as_ptr(),
            repos_changed_revision: -1,
            repos_changed_author: ptr::null(),
            repos_changed_date: ptr::null(),
            revision: 7,
            changed_revision: 7,
            changed_author: ptr::null(),
            changed_date: ptr::null(),
            changelist: ptr::null(),
            lock: ptr::null(),
            repos_lock: ptr::null(),
            needs_lock: 0,
            depth: depth.as_ptr(),
            conflicted: 0,
            switched: 0,
            external: 0,
            copied: 0,
            copy_from_path: ptr::null(),
            copy_from_revision: -1,
            moved_from_abspath: ptr::null(),
            conflict_artifact_paths: [ptr::null(); 4],
            conflict_artifact_count: 0,
        }
    }

    fn native_auth_request_sequence(request_id: &str, prefix: &str) -> u64 {
        request_id
            .strip_prefix(prefix)
            .expect("native auth request id should use the expected prefix")
            .parse()
            .expect("native auth request id should end with a numeric sequence")
    }

    enum RecordingCertificateOutcome {
        Ready(CertificateTrustResponse),
        Trust {
            trust: String,
            fingerprint: String,
            fingerprint_algorithm: String,
        },
        Panic,
    }

    struct RecordingAuthBroker {
        certificate_outcome: Option<RecordingCertificateOutcome>,
        certificate_requests: Vec<CertificateTrustRequest>,
    }

    impl RecordingAuthBroker {
        fn empty() -> Self {
            Self {
                certificate_outcome: None,
                certificate_requests: Vec::new(),
            }
        }

        fn certificate(response: CertificateTrustResponse) -> Self {
            Self {
                certificate_outcome: Some(RecordingCertificateOutcome::Ready(response)),
                certificate_requests: Vec::new(),
            }
        }

        fn certificate_trust(
            trust: &str,
            fingerprint: String,
            fingerprint_algorithm: &str,
        ) -> Self {
            Self {
                certificate_outcome: Some(RecordingCertificateOutcome::Trust {
                    trust: trust.to_string(),
                    fingerprint,
                    fingerprint_algorithm: fingerprint_algorithm.to_string(),
                }),
                certificate_requests: Vec::new(),
            }
        }

        fn certificate_panic() -> Self {
            Self {
                certificate_outcome: Some(RecordingCertificateOutcome::Panic),
                certificate_requests: Vec::new(),
            }
        }
    }

    impl AuthRequestBroker for RecordingAuthBroker {
        fn request_credential(
            &mut self,
            _request: CredentialRequest,
        ) -> Result<CredentialResponse, BridgeFailure> {
            panic!("parent credential callback must not invoke the broker")
        }

        fn settle_credential(
            &mut self,
            _request: subversionr_protocol::CredentialSettlementRequest,
        ) -> Result<subversionr_protocol::CredentialSettlementAck, BridgeFailure> {
            panic!("parent credential callback must not settle a lease")
        }

        fn request_certificate_trust(
            &mut self,
            request: CertificateTrustRequest,
        ) -> Result<CertificateTrustResponse, BridgeFailure> {
            let request_id = request.request_id.clone();
            self.certificate_requests.push(request);
            match self
                .certificate_outcome
                .take()
                .expect("certificate outcome should be configured")
            {
                RecordingCertificateOutcome::Ready(response) => Ok(response),
                RecordingCertificateOutcome::Trust {
                    trust,
                    fingerprint,
                    fingerprint_algorithm,
                } => Ok(CertificateTrustResponse::Trust {
                    request_id,
                    trust,
                    fingerprint,
                    fingerprint_algorithm,
                }),
                RecordingCertificateOutcome::Panic => panic!("certificate broker panic"),
            }
        }
    }
}

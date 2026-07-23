use serde::{Deserialize, Serialize};
use serde_json::json;
use subversionr_protocol::{
    CanonicalEndpoint, CertificateTrustRequest, CertificateTrustResponse, CredentialRequest,
    CredentialResponse, CredentialSettlementAck, CredentialSettlementRequest,
    OperationFailureCause, RepositoryIdentity, StatusSnapshot,
};

use crate::{
    AuthRequestBroker, BranchCreateOperationRequest, BranchCreateOperationResult, BridgeApi,
    BridgeCancellationToken, BridgeFailure, CommitOperationRequest, CommitOperationResult,
    ContentBlob, HistoryBlameRequest, HistoryBlameResult, HistoryLogRequest, HistoryLogResult,
    LockOperationRequest, NativeBridge, OperationResult, RepositoryCheckoutRequest,
    RepositoryCheckoutResult, SwitchOperationRequest, SwitchOperationResult,
    UnlockOperationRequest, UpdateOperationRequest, UpdateOperationResult,
};

pub(crate) const ANONYMOUS_IDENTITY_REQUIRED_ARG: &str = "anonymousIdentityRequired";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum RemoteSvnAnonymousRequest {
    Checkout {
        request: RepositoryCheckoutRequest,
    },
    Status {
        identity: RepositoryIdentity,
        generation: u64,
    },
    Content {
        identity: RepositoryIdentity,
        path: String,
        revision: String,
    },
    Log {
        identity: RepositoryIdentity,
        request: HistoryLogRequest,
    },
    Blame {
        identity: RepositoryIdentity,
        request: HistoryBlameRequest,
    },
    Update {
        identity: RepositoryIdentity,
        request: UpdateOperationRequest,
    },
    Lock {
        identity: RepositoryIdentity,
        request: LockOperationRequest,
    },
    Unlock {
        identity: RepositoryIdentity,
        request: UnlockOperationRequest,
    },
    BranchCreate {
        identity: RepositoryIdentity,
        request: BranchCreateOperationRequest,
    },
    Switch {
        identity: RepositoryIdentity,
        request: SwitchOperationRequest,
    },
    Commit {
        identity: RepositoryIdentity,
        request: CommitOperationRequest,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    content = "value",
    rename_all = "camelCase",
    deny_unknown_fields
)]
pub enum RemoteSvnAnonymousOutput {
    Checkout(RepositoryCheckoutResult),
    Status(StatusSnapshot),
    Content(ContentBlob),
    Log(HistoryLogResult),
    Blame(HistoryBlameResult),
    Update(UpdateOperationResult),
    Lock(OperationResult),
    Unlock(OperationResult),
    BranchCreate(BranchCreateOperationResult),
    Switch(SwitchOperationResult),
    Commit(CommitOperationResult),
}

impl RemoteSvnAnonymousRequest {
    pub(crate) fn execute(
        self,
        bridge: &NativeBridge,
        expected_origin: &CanonicalEndpoint,
        cancellation: &dyn BridgeCancellationToken,
    ) -> Result<RemoteSvnAnonymousOutput, BridgeFailure> {
        bridge.configure_svn_anonymous(expected_origin)?;
        let mut anonymous = AnonymousOnlyAuthBroker;
        match self {
            Self::Checkout { request } => bridge
                .repository_checkout_with_cancellation(&request, &mut anonymous, cancellation)
                .map_err(|failure| {
                    normalize_anonymous_checkout_auth_capability_failure(failure, &request)
                })
                .map(RemoteSvnAnonymousOutput::Checkout),
            Self::Status {
                identity,
                generation,
            } => bridge
                .status_remote_check_with_cancellation(
                    &identity,
                    generation,
                    &mut anonymous,
                    cancellation,
                )
                .map_err(normalize_anonymous_read_only_auth_capability_failure)
                .map(RemoteSvnAnonymousOutput::Status),
            Self::Content {
                identity,
                path,
                revision,
            } => bridge
                .content_get(&identity, &path, &revision, &mut anonymous)
                .map_err(normalize_anonymous_read_only_auth_capability_failure)
                .map(RemoteSvnAnonymousOutput::Content),
            Self::Log { identity, request } => bridge
                .history_log(&identity, &request, &mut anonymous)
                .map_err(normalize_anonymous_read_only_auth_capability_failure)
                .map(RemoteSvnAnonymousOutput::Log),
            Self::Blame { identity, request } => bridge
                .history_blame(&identity, &request, &mut anonymous)
                .map_err(normalize_anonymous_read_only_auth_capability_failure)
                .map(RemoteSvnAnonymousOutput::Blame),
            Self::Update { identity, request } => bridge
                .operation_update_with_cancellation(
                    &identity,
                    &request,
                    &mut anonymous,
                    cancellation,
                )
                .map(RemoteSvnAnonymousOutput::Update),
            Self::Lock { identity, request } => bridge
                .operation_lock_with_cancellation(&identity, &request, &mut anonymous, cancellation)
                .map_err(|failure| {
                    normalize_anonymous_lock_failure(failure, "SVN_OPERATION_LOCK_FAILED")
                })
                .map(RemoteSvnAnonymousOutput::Lock),
            Self::Unlock { identity, request } => bridge
                .operation_unlock_with_cancellation(
                    &identity,
                    &request,
                    &mut anonymous,
                    cancellation,
                )
                .map_err(|failure| {
                    normalize_anonymous_lock_failure(failure, "SVN_OPERATION_UNLOCK_FAILED")
                })
                .map(RemoteSvnAnonymousOutput::Unlock),
            Self::BranchCreate { identity, request } => bridge
                .operation_branch_create_with_cancellation(
                    &identity,
                    &request,
                    &mut anonymous,
                    cancellation,
                )
                .map(RemoteSvnAnonymousOutput::BranchCreate),
            Self::Switch { identity, request } => bridge
                .operation_switch_with_cancellation(
                    &identity,
                    &request,
                    &mut anonymous,
                    cancellation,
                )
                .map(RemoteSvnAnonymousOutput::Switch),
            Self::Commit { identity, request } => bridge
                .operation_commit_with_cancellation(
                    &identity,
                    &request,
                    &mut anonymous,
                    cancellation,
                )
                .map(RemoteSvnAnonymousOutput::Commit),
        }
    }
}

fn normalize_anonymous_read_only_auth_capability_failure(failure: BridgeFailure) -> BridgeFailure {
    normalize_anonymous_auth_capability_failure(failure)
}

fn normalize_anonymous_checkout_auth_capability_failure(
    failure: BridgeFailure,
    request: &RepositoryCheckoutRequest,
) -> BridgeFailure {
    if !request.ignore_externals || !checkout_target_is_absent(&request.target_path) {
        return failure;
    }
    normalize_anonymous_auth_capability_failure(failure)
}

fn checkout_target_is_absent(target_path: &str) -> bool {
    matches!(
        std::fs::symlink_metadata(target_path),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound
    )
}

fn normalize_anonymous_auth_capability_failure(failure: BridgeFailure) -> BridgeFailure {
    let should_normalize = failure
        .diagnostics()
        .is_some_and(anonymous_auth_capability_diagnostics);
    if !should_normalize {
        return failure;
    }

    let mut normalized = anonymous_auth_challenge();
    normalized.diagnostics = failure.diagnostics;
    normalized
}

fn anonymous_auth_capability_diagnostics(
    diagnostics: &subversionr_protocol::OperationFailureDiagnostics,
) -> bool {
    !diagnostics.svn.truncated
        && !diagnostics.svn.entries.is_empty()
        && diagnostics.svn.entries.len() <= 8
        && diagnostics.svn.entries.iter().any(|entry| {
            matches!(
                entry.name.as_str(),
                "SVN_ERR_RA_SVN_NO_MECHANISMS" | "SVN_ERR_AUTHN_NO_PROVIDER"
            )
        })
}

fn normalize_anonymous_lock_failure(
    mut failure: BridgeFailure,
    expected_code: &str,
) -> BridgeFailure {
    let should_normalize = failure.code() == expected_code
        && failure.safe_args().as_object().is_some_and(|args| {
            args.get("mayHaveMutated")
                .and_then(serde_json::Value::as_bool)
                == Some(false)
                && !args.contains_key(ANONYMOUS_IDENTITY_REQUIRED_ARG)
        })
        && failure
            .diagnostics()
            .is_some_and(native_identity_required_diagnostics);
    if should_normalize {
        failure
            .diagnostics
            .as_mut()
            .expect("normalization requires diagnostics")
            .cause = OperationFailureCause::AuthenticationFailed;
        failure
            .args
            .as_object_mut()
            .expect("normalization requires native safe args")
            .insert(
                ANONYMOUS_IDENTITY_REQUIRED_ARG.to_string(),
                serde_json::Value::Bool(true),
            );
    }
    failure
}

pub(crate) fn is_anonymous_identity_required_failure(failure: &BridgeFailure) -> bool {
    matches!(
        failure.code(),
        "SVN_OPERATION_LOCK_FAILED" | "SVN_OPERATION_UNLOCK_FAILED"
    ) && failure.safe_args().as_object().is_some_and(|args| {
        args.get("mayHaveMutated")
            .and_then(serde_json::Value::as_bool)
            == Some(false)
            && args
                .get(ANONYMOUS_IDENTITY_REQUIRED_ARG)
                .and_then(serde_json::Value::as_bool)
                == Some(true)
    }) && failure.diagnostics().is_some_and(|diagnostics| {
        diagnostics.cause == OperationFailureCause::AuthenticationFailed
            && bounded_identity_required_chain(diagnostics)
    })
}

fn native_identity_required_diagnostics(
    diagnostics: &subversionr_protocol::OperationFailureDiagnostics,
) -> bool {
    bounded_identity_required_chain(diagnostics)
        && match diagnostics.cause {
            OperationFailureCause::AuthorizationDenied => diagnostics
                .svn
                .entries
                .iter()
                .any(|entry| entry.name == "SVN_ERR_RA_NOT_AUTHORIZED"),
            OperationFailureCause::UnknownNative => diagnostics
                .svn
                .entries
                .iter()
                .any(|entry| entry.name == "SVN_ERR_FS_NO_USER"),
            _ => false,
        }
}

fn bounded_identity_required_chain(
    diagnostics: &subversionr_protocol::OperationFailureDiagnostics,
) -> bool {
    !diagnostics.svn.truncated
        && !diagnostics.svn.entries.is_empty()
        && diagnostics.svn.entries.len() <= 8
        && diagnostics.svn.entries.iter().any(|entry| {
            matches!(
                entry.name.as_str(),
                "SVN_ERR_RA_NOT_AUTHORIZED" | "SVN_ERR_FS_NO_USER"
            )
        })
}

struct AnonymousOnlyAuthBroker;

impl AuthRequestBroker for AnonymousOnlyAuthBroker {
    fn native_credential_callback_policy(&self) -> crate::NativeCredentialCallbackPolicy {
        crate::NativeCredentialCallbackPolicy::AnonymousUnsupported
    }

    fn request_credential(
        &mut self,
        _request: CredentialRequest,
    ) -> Result<CredentialResponse, BridgeFailure> {
        Err(anonymous_auth_challenge())
    }

    fn settle_credential(
        &mut self,
        _request: CredentialSettlementRequest,
    ) -> Result<CredentialSettlementAck, BridgeFailure> {
        Err(anonymous_auth_challenge())
    }

    fn request_certificate_trust(
        &mut self,
        _request: CertificateTrustRequest,
    ) -> Result<CertificateTrustResponse, BridgeFailure> {
        Err(anonymous_auth_challenge())
    }
}

fn anonymous_auth_challenge() -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED",
        "unsupported",
        "error.remote.authUnsupported",
        json!({ "scheme": "svn", "auth": "anonymous" }),
        false,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use subversionr_protocol::{
        OperationFailureDiagnostics, SvnErrorDiagnosticEntry, SvnErrorDiagnostics,
    };

    fn native_failure(
        code: &str,
        cause: OperationFailureCause,
        may_have_mutated: Option<bool>,
        entries: Vec<SvnErrorDiagnosticEntry>,
    ) -> BridgeFailure {
        let mut args = serde_json::Map::from_iter([
            ("path".to_string(), json!("C:/wc/trunk.txt")),
            ("status".to_string(), json!(2)),
        ]);
        if let Some(may_have_mutated) = may_have_mutated {
            args.insert("mayHaveMutated".to_string(), json!(may_have_mutated));
        }
        BridgeFailure::new(
            code,
            "native",
            "error.native.operationLockFailed",
            serde_json::Value::Object(args),
            false,
        )
        .with_diagnostics(OperationFailureDiagnostics {
            cause,
            svn: SvnErrorDiagnostics {
                entries,
                truncated: false,
            },
        })
    }

    fn not_authorized_entries() -> Vec<SvnErrorDiagnosticEntry> {
        vec![
            SvnErrorDiagnosticEntry {
                code: 160035,
                name: "SVN_ERR_CLIENT_UNRELATED_RESOURCES".to_string(),
            },
            SvnErrorDiagnosticEntry {
                code: 170001,
                name: "SVN_ERR_RA_NOT_AUTHORIZED".to_string(),
            },
        ]
    }

    fn no_user_entries() -> Vec<SvnErrorDiagnosticEntry> {
        vec![SvnErrorDiagnosticEntry {
            code: 160034,
            name: "SVN_ERR_FS_NO_USER".to_string(),
        }]
    }

    #[test]
    fn anonymous_auth_boundary_normalizes_only_exact_capability_diagnostics() {
        for name in ["SVN_ERR_RA_SVN_NO_MECHANISMS", "SVN_ERR_AUTHN_NO_PROVIDER"] {
            let normalized = normalize_anonymous_read_only_auth_capability_failure(native_failure(
                "SVN_REPOSITORY_CHECKOUT_FAILED",
                OperationFailureCause::AuthenticationFailed,
                None,
                vec![SvnErrorDiagnosticEntry {
                    code: 170000,
                    name: name.to_string(),
                }],
            ));
            assert_eq!(normalized.code(), "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED");
            assert_eq!(normalized.category, "unsupported");
            assert_eq!(normalized.message_key, "error.remote.authUnsupported");
            assert_eq!(
                normalized.safe_args(),
                &json!({ "scheme": "svn", "auth": "anonymous" })
            );
            assert_eq!(
                normalized
                    .diagnostics()
                    .expect("native diagnostics must survive")
                    .svn
                    .entries[0]
                    .name,
                name
            );
        }

        for name in ["SVN_ERR_RA_NOT_AUTHORIZED", "SVN_ERR_AUTHZ_ROOT_UNREADABLE"] {
            let original = native_failure(
                "SVN_REPOSITORY_CHECKOUT_FAILED",
                OperationFailureCause::AuthorizationDenied,
                None,
                vec![SvnErrorDiagnosticEntry {
                    code: 170001,
                    name: name.to_string(),
                }],
            );
            assert_eq!(
                normalize_anonymous_read_only_auth_capability_failure(original).code(),
                "SVN_REPOSITORY_CHECKOUT_FAILED"
            );
        }

        let mut truncated = native_failure(
            "SVN_REPOSITORY_CHECKOUT_FAILED",
            OperationFailureCause::AuthenticationFailed,
            None,
            vec![SvnErrorDiagnosticEntry {
                code: 170001,
                name: "SVN_ERR_RA_SVN_NO_MECHANISMS".to_string(),
            }],
        );
        truncated
            .diagnostics
            .as_mut()
            .expect("fixture diagnostics")
            .svn
            .truncated = true;
        assert_eq!(
            normalize_anonymous_read_only_auth_capability_failure(truncated).code(),
            "SVN_REPOSITORY_CHECKOUT_FAILED"
        );
    }

    #[test]
    fn anonymous_checkout_auth_normalization_requires_a_proven_uncreated_target() {
        let target = std::env::temp_dir().join(format!(
            "subversionr-anonymous-auth-boundary-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system clock must follow the Unix epoch")
                .as_nanos()
        ));
        let request = RepositoryCheckoutRequest {
            url: "svn://127.0.0.1/repo".to_string(),
            target_path: target.to_string_lossy().into_owned(),
            revision: "head".to_string(),
            depth: "infinity".to_string(),
            ignore_externals: true,
        };
        let capability_failure = || {
            native_failure(
                "SVN_REPOSITORY_CHECKOUT_FAILED",
                OperationFailureCause::AuthenticationFailed,
                None,
                vec![SvnErrorDiagnosticEntry {
                    code: 170000,
                    name: "SVN_ERR_RA_SVN_NO_MECHANISMS".to_string(),
                }],
            )
        };

        assert_eq!(
            normalize_anonymous_checkout_auth_capability_failure(capability_failure(), &request)
                .code(),
            "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED"
        );

        let mut externals_allowed = request.clone();
        externals_allowed.ignore_externals = false;
        assert_eq!(
            normalize_anonymous_checkout_auth_capability_failure(
                capability_failure(),
                &externals_allowed
            )
            .code(),
            "SVN_REPOSITORY_CHECKOUT_FAILED"
        );

        std::fs::create_dir(&target).expect("checkout target fixture must be created");
        assert_eq!(
            normalize_anonymous_checkout_auth_capability_failure(capability_failure(), &request)
                .code(),
            "SVN_REPOSITORY_CHECKOUT_FAILED"
        );
        std::fs::remove_dir(&target).expect("checkout target fixture must be removed");
    }

    #[test]
    fn anonymous_lock_boundary_normalizes_only_exact_lock_and_unlock_authorization_failures() {
        for code in ["SVN_OPERATION_LOCK_FAILED", "SVN_OPERATION_UNLOCK_FAILED"] {
            let normalized = normalize_anonymous_lock_failure(
                native_failure(
                    code,
                    OperationFailureCause::AuthorizationDenied,
                    Some(false),
                    not_authorized_entries(),
                ),
                code,
            );
            let diagnostics = normalized
                .diagnostics()
                .expect("diagnostics must remain present");
            assert_eq!(
                diagnostics.cause,
                OperationFailureCause::AuthenticationFailed
            );
            assert_eq!(diagnostics.svn.entries.len(), 2);
            assert_eq!(diagnostics.svn.entries[1].name, "SVN_ERR_RA_NOT_AUTHORIZED");
            assert!(!diagnostics.svn.truncated);
            assert_eq!(
                normalized.safe_args()[ANONYMOUS_IDENTITY_REQUIRED_ARG],
                true
            );
            assert!(is_anonymous_identity_required_failure(&normalized));
        }

        let no_user = normalize_anonymous_lock_failure(
            native_failure(
                "SVN_OPERATION_UNLOCK_FAILED",
                OperationFailureCause::UnknownNative,
                Some(false),
                no_user_entries(),
            ),
            "SVN_OPERATION_UNLOCK_FAILED",
        );
        assert_eq!(
            no_user.diagnostics().expect("diagnostics").cause,
            OperationFailureCause::AuthenticationFailed
        );
        assert_eq!(no_user.safe_args()[ANONYMOUS_IDENTITY_REQUIRED_ARG], true);
        assert!(is_anonymous_identity_required_failure(&no_user));

        let other_code = normalize_anonymous_lock_failure(
            native_failure(
                "SVN_OPERATION_UPDATE_FAILED",
                OperationFailureCause::AuthorizationDenied,
                Some(false),
                not_authorized_entries(),
            ),
            "SVN_OPERATION_LOCK_FAILED",
        );
        assert_eq!(
            other_code.diagnostics().expect("diagnostics").cause,
            OperationFailureCause::AuthorizationDenied
        );

        let other_cause = normalize_anonymous_lock_failure(
            native_failure(
                "SVN_OPERATION_LOCK_FAILED",
                OperationFailureCause::AuthorizationConfigurationInvalid,
                Some(false),
                not_authorized_entries(),
            ),
            "SVN_OPERATION_LOCK_FAILED",
        );
        assert_eq!(
            other_cause.diagnostics().expect("diagnostics").cause,
            OperationFailureCause::AuthorizationConfigurationInvalid
        );

        for may_have_mutated in [Some(true), None] {
            let conservative = normalize_anonymous_lock_failure(
                native_failure(
                    "SVN_OPERATION_LOCK_FAILED",
                    OperationFailureCause::AuthorizationDenied,
                    may_have_mutated,
                    not_authorized_entries(),
                ),
                "SVN_OPERATION_LOCK_FAILED",
            );
            assert_eq!(
                conservative.diagnostics().expect("diagnostics").cause,
                OperationFailureCause::AuthorizationDenied
            );
            assert!(conservative.safe_args()[ANONYMOUS_IDENTITY_REQUIRED_ARG].is_null());
        }

        let unrelated_cause_chain = normalize_anonymous_lock_failure(
            native_failure(
                "SVN_OPERATION_LOCK_FAILED",
                OperationFailureCause::AuthorizationDenied,
                Some(false),
                vec![SvnErrorDiagnosticEntry {
                    code: 170001,
                    name: "SVN_ERR_AUTHZ_UNWRITABLE".to_string(),
                }],
            ),
            "SVN_OPERATION_LOCK_FAILED",
        );
        assert_eq!(
            unrelated_cause_chain
                .diagnostics()
                .expect("diagnostics")
                .cause,
            OperationFailureCause::AuthorizationDenied
        );
        assert!(unrelated_cause_chain.safe_args()[ANONYMOUS_IDENTITY_REQUIRED_ARG].is_null());

        let mut truncated = native_failure(
            "SVN_OPERATION_LOCK_FAILED",
            OperationFailureCause::AuthorizationDenied,
            Some(false),
            not_authorized_entries(),
        );
        truncated
            .diagnostics
            .as_mut()
            .expect("fixture diagnostics")
            .svn
            .truncated = true;
        let truncated = normalize_anonymous_lock_failure(truncated, "SVN_OPERATION_LOCK_FAILED");
        assert_eq!(
            truncated.diagnostics().expect("diagnostics").cause,
            OperationFailureCause::AuthorizationDenied
        );
        assert!(truncated.safe_args()[ANONYMOUS_IDENTITY_REQUIRED_ARG].is_null());
    }
}

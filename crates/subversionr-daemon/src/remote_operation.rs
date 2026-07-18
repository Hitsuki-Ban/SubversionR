use serde::{Deserialize, Serialize};
use serde_json::json;
use subversionr_protocol::{
    CanonicalEndpoint, CertificateTrustRequest, CertificateTrustResponse, CredentialRequest,
    CredentialResponse, CredentialSettlementAck, CredentialSettlementRequest, RepositoryIdentity,
    StatusSnapshot,
};

use crate::{
    AuthRequestBroker, BranchCreateOperationRequest, BranchCreateOperationResult, BridgeApi,
    BridgeCancellationToken, BridgeFailure, CommitOperationRequest, CommitOperationResult,
    ContentBlob, HistoryBlameRequest, HistoryBlameResult, HistoryLogRequest, HistoryLogResult,
    LockOperationRequest, NativeBridge, OperationResult, RepositoryCheckoutRequest,
    RepositoryCheckoutResult, SwitchOperationRequest, SwitchOperationResult,
    UnlockOperationRequest, UpdateOperationRequest, UpdateOperationResult,
};

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
                .map(RemoteSvnAnonymousOutput::Status),
            Self::Content {
                identity,
                path,
                revision,
            } => bridge
                .content_get(&identity, &path, &revision, &mut anonymous)
                .map(RemoteSvnAnonymousOutput::Content),
            Self::Log { identity, request } => bridge
                .history_log(&identity, &request, &mut anonymous)
                .map(RemoteSvnAnonymousOutput::Log),
            Self::Blame { identity, request } => bridge
                .history_blame(&identity, &request, &mut anonymous)
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
                .map(RemoteSvnAnonymousOutput::Lock),
            Self::Unlock { identity, request } => bridge
                .operation_unlock_with_cancellation(
                    &identity,
                    &request,
                    &mut anonymous,
                    cancellation,
                )
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

struct AnonymousOnlyAuthBroker;

impl AuthRequestBroker for AnonymousOnlyAuthBroker {
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

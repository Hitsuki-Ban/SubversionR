use std::net::{Ipv4Addr, Ipv6Addr};

use serde_json::{Value, json};
use subversionr_protocol::{
    CanonicalEndpoint, NoProxyProfile, NoServerAccount, NoSshProfile, RedirectPolicy,
    RemoteAccessProfileSnapshot, RemoteInteraction, RemoteOperationEnvelope, RemoteOperationIntent,
    RemoteScheme, RemoteServerAuth, ServerAccountSelection, ServerAccountSnapshot,
    SshProfileSnapshot, TlsTrustPolicy,
};

use crate::{
    BridgeFailure, JsonRpcRequest, RemoteConfigPlan, RemoteConfigScheme, RemoteConfigServerAuth,
};

pub(crate) const REMOTE_OPERATION_VERSION: u16 = 1;
pub(crate) const REMOTE_PROFILE_SCHEMA: &str = "subversionr.remote-profile.v1";
pub(crate) const MAX_REMOTE_TIMEOUT_MS: u64 = 300_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct RemoteTrustState {
    trusted: bool,
    current_epoch: u64,
    acknowledged_epoch: u64,
}

impl RemoteTrustState {
    pub(crate) fn new(trusted: bool, trust_epoch: u64) -> Result<Self, BridgeFailure> {
        if trust_epoch == 0 {
            return Err(invalid_remote_field("trustEpoch"));
        }
        Ok(Self {
            trusted,
            current_epoch: trust_epoch,
            acknowledged_epoch: trust_epoch,
        })
    }

    pub(crate) fn acknowledged_epoch(&self) -> u64 {
        self.acknowledged_epoch
    }

    pub(crate) fn apply_update(
        &mut self,
        trusted: bool,
        trust_epoch: u64,
    ) -> Result<u64, BridgeFailure> {
        let expected_epoch = self.current_epoch.checked_add(1).ok_or_else(|| {
            BridgeFailure::new(
                "SUBVERSIONR_REMOTE_TRUST_EPOCH_EXHAUSTED",
                "state",
                "error.remote.trustEpochExhausted",
                json!({}),
                false,
            )
        })?;
        if trust_epoch != expected_epoch {
            return Err(trust_epoch_mismatch());
        }
        self.trusted = trusted;
        self.current_epoch = trust_epoch;
        self.acknowledged_epoch = trust_epoch;
        Ok(trust_epoch)
    }

    fn permits(&self, envelope_epoch: u64) -> bool {
        self.trusted
            && envelope_epoch == self.current_epoch
            && envelope_epoch == self.acknowledged_epoch
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ClassifiedRepositoryUrl {
    LocalFile,
    Remote(CanonicalEndpoint),
}

pub(crate) fn classify_repository_url(url: &str) -> Result<ClassifiedRepositoryUrl, BridgeFailure> {
    let (scheme, remainder) = url
        .split_once("://")
        .ok_or_else(|| invalid_remote_field("url"))?;
    if scheme == "file" {
        if !remainder.starts_with('/') {
            return Err(invalid_remote_field("url"));
        }
        return Ok(ClassifiedRepositoryUrl::LocalFile);
    }

    let remote_scheme = match scheme {
        "http" => RemoteScheme::Http,
        "https" => RemoteScheme::Https,
        "svn" => RemoteScheme::Svn,
        "svn+ssh" => RemoteScheme::SvnSsh,
        _ => return Err(invalid_remote_field("url")),
    };
    let authority = remainder
        .split(['/', '?', '#'])
        .next()
        .filter(|authority| !authority.is_empty())
        .ok_or_else(|| invalid_remote_field("url"))?;
    if authority.contains('@') {
        return Err(invalid_remote_field("url"));
    }
    let (host, port) = parse_authority(authority, remote_scheme)?;
    let endpoint = CanonicalEndpoint {
        scheme: remote_scheme,
        canonical_host: host,
        effective_port: port,
    };
    validate_endpoint(&endpoint)?;
    Ok(ClassifiedRepositoryUrl::Remote(endpoint))
}

pub(crate) fn envelope_value(request: &JsonRpcRequest) -> Option<&Value> {
    request.params.as_ref()?.get("remote")
}

pub(crate) fn validate_remote_envelope(
    request: &JsonRpcRequest,
    endpoint: &CanonicalEndpoint,
    trust: Option<&RemoteTrustState>,
) -> Result<RemoteConfigPlan, BridgeFailure> {
    let value = envelope_value(request).ok_or_else(|| {
        BridgeFailure::new(
            "SUBVERSIONR_REMOTE_ENVELOPE_REQUIRED",
            "configuration",
            "error.remote.envelopeRequired",
            json!({}),
            false,
        )
    })?;
    let envelope: RemoteOperationEnvelope =
        serde_json::from_value(value.clone()).map_err(|_| invalid_remote_field("remote"))?;
    validate_envelope(&envelope, endpoint, trust)
}

pub(crate) fn reject_file_envelope(request: &JsonRpcRequest) -> Result<(), BridgeFailure> {
    if envelope_value(request).is_some() {
        return Err(BridgeFailure::new(
            "SUBVERSIONR_REMOTE_ENVELOPE_FORBIDDEN",
            "configuration",
            "error.remote.envelopeForbidden",
            json!({ "scheme": "file" }),
            false,
        ));
    }
    Ok(())
}

pub(crate) fn preflight_repository_urls(
    request: &JsonRpcRequest,
    urls: &[&str],
    trust: Option<&RemoteTrustState>,
    bridge: &dyn crate::BridgeApi,
) -> Result<(), BridgeFailure> {
    let mut remote_endpoint: Option<CanonicalEndpoint> = None;
    let mut saw_file = false;
    for url in urls {
        match classify_repository_url(url)? {
            ClassifiedRepositoryUrl::LocalFile => saw_file = true,
            ClassifiedRepositoryUrl::Remote(endpoint) => {
                if remote_endpoint
                    .as_ref()
                    .is_some_and(|existing| *existing != endpoint)
                {
                    return Err(BridgeFailure::new(
                        "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH",
                        "configuration",
                        "error.remote.originMismatch",
                        json!({}),
                        false,
                    ));
                }
                remote_endpoint = Some(endpoint);
            }
        }
    }
    if saw_file && remote_endpoint.is_some() {
        return Err(BridgeFailure::new(
            "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH",
            "configuration",
            "error.remote.originMismatch",
            json!({}),
            false,
        ));
    }
    let Some(endpoint) = remote_endpoint else {
        return reject_file_envelope(request);
    };
    let plan = validate_remote_envelope(request, &endpoint, trust)?;
    bridge.create_remote_context_foundation(plan)?;
    Err(unsupported_transport(&endpoint))
}

pub(crate) fn unsupported_transport(endpoint: &CanonicalEndpoint) -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_REMOTE_TRANSPORT_UNSUPPORTED",
        "unsupported",
        "error.remote.transportUnsupported",
        json!({ "scheme": scheme_name(endpoint.scheme) }),
        false,
    )
}

fn validate_envelope(
    envelope: &RemoteOperationEnvelope,
    endpoint: &CanonicalEndpoint,
    trust: Option<&RemoteTrustState>,
) -> Result<RemoteConfigPlan, BridgeFailure> {
    if envelope.version != REMOTE_OPERATION_VERSION {
        return Err(invalid_remote_field("remote.version"));
    }
    if !is_canonical_uuid(&envelope.operation_id) {
        return Err(invalid_remote_field("remote.operationId"));
    }
    if envelope.timeout_ms == 0 || envelope.timeout_ms > MAX_REMOTE_TIMEOUT_MS {
        return Err(invalid_remote_field("remote.timeoutMs"));
    }
    if envelope.trust_epoch == 0 || !trust.is_some_and(|state| state.permits(envelope.trust_epoch))
    {
        return Err(trust_epoch_mismatch());
    }
    if envelope.intent == RemoteOperationIntent::Background
        && envelope.interaction != RemoteInteraction::Forbidden
    {
        return Err(invalid_remote_field("remote.interaction"));
    }
    validate_endpoint(&envelope.expected_origin)?;
    if envelope.expected_origin != *endpoint || envelope.profile.authority != *endpoint {
        return Err(BridgeFailure::new(
            "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH",
            "configuration",
            "error.remote.originMismatch",
            json!({}),
            false,
        ));
    }
    validate_profile(&envelope.profile, envelope.intent, envelope.interaction).map(
        |(scheme, server_auth, trust_windows_roots)| RemoteConfigPlan {
            scheme,
            server_auth,
            timeout_ms: envelope.timeout_ms,
            trust_windows_roots,
        },
    )
}

fn validate_profile(
    profile: &RemoteAccessProfileSnapshot,
    intent: RemoteOperationIntent,
    interaction: RemoteInteraction,
) -> Result<(RemoteConfigScheme, RemoteConfigServerAuth, bool), BridgeFailure> {
    if profile.schema != REMOTE_PROFILE_SCHEMA {
        return Err(invalid_remote_field("remote.profile.schema"));
    }
    if profile.profile_id.is_empty()
        || profile.profile_id.len() > 128
        || !profile.profile_id.is_ascii()
        || !profile
            .profile_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
    {
        return Err(invalid_remote_field("remote.profile.profileId"));
    }
    validate_endpoint(&profile.authority)?;
    if !matches!(
        profile.proxy,
        subversionr_protocol::ProxyProfileSnapshot::None(NoProxyProfile::None)
    ) {
        return Err(BridgeFailure::new(
            "SUBVERSIONR_REMOTE_PROXY_UNSUPPORTED",
            "unsupported",
            "error.remote.proxyUnsupported",
            json!({}),
            false,
        ));
    }
    if profile.redirect_policy != RedirectPolicy::RejectAll {
        return Err(BridgeFailure::new(
            "SUBVERSIONR_REMOTE_REDIRECT_POLICY_UNSUPPORTED",
            "unsupported",
            "error.remote.redirectPolicyUnsupported",
            json!({}),
            false,
        ));
    }

    let (scheme, server_auth, trust_windows_roots) = match profile.authority.scheme {
        RemoteScheme::Http => {
            if profile.tls.is_some() {
                return Err(invalid_remote_field("remote.profile.tls"));
            }
            require_no_ssh(profile)?;
            (
                RemoteConfigScheme::Http,
                http_server_auth(profile.server_auth)?,
                false,
            )
        }
        RemoteScheme::Https => {
            let Some(tls) = profile.tls.as_ref() else {
                return Err(invalid_remote_field("remote.profile.tls"));
            };
            if tls.trust != TlsTrustPolicy::WindowsRootsThenBroker || tls.ca_bundle_path.is_some() {
                return Err(BridgeFailure::new(
                    "SUBVERSIONR_REMOTE_TLS_POLICY_UNSUPPORTED",
                    "unsupported",
                    "error.remote.tlsPolicyUnsupported",
                    json!({}),
                    false,
                ));
            }
            require_no_ssh(profile)?;
            (
                RemoteConfigScheme::Https,
                http_server_auth(profile.server_auth)?,
                true,
            )
        }
        RemoteScheme::Svn => {
            if profile.tls.is_some() {
                return Err(invalid_remote_field("remote.profile.tls"));
            }
            require_no_ssh(profile)?;
            (
                RemoteConfigScheme::Svn,
                svn_server_auth(profile.server_auth)?,
                false,
            )
        }
        RemoteScheme::SvnSsh => {
            return Err(BridgeFailure::new(
                "SUBVERSIONR_REMOTE_SSH_PROFILE_UNSUPPORTED",
                "unsupported",
                "error.remote.sshProfileUnsupported",
                json!({}),
                false,
            ));
        }
    };
    validate_server_account(profile, intent, interaction)?;
    Ok((scheme, server_auth, trust_windows_roots))
}

fn validate_server_account(
    profile: &RemoteAccessProfileSnapshot,
    intent: RemoteOperationIntent,
    interaction: RemoteInteraction,
) -> Result<(), BridgeFailure> {
    match (profile.server_auth, &profile.server_account) {
        (RemoteServerAuth::Anonymous, ServerAccountSnapshot::None(NoServerAccount::None)) => Ok(()),
        (
            RemoteServerAuth::Basic | RemoteServerAuth::CramMd5,
            ServerAccountSnapshot::Selection(ServerAccountSelection::Fixed { username }),
        ) if normalized_username(username) => Ok(()),
        (
            RemoteServerAuth::Basic | RemoteServerAuth::CramMd5,
            ServerAccountSnapshot::Selection(ServerAccountSelection::ChooseForeground),
        ) if intent == RemoteOperationIntent::Foreground
            && interaction == RemoteInteraction::Allowed =>
        {
            Ok(())
        }
        _ => Err(invalid_remote_field("remote.profile.serverAccount")),
    }
}

fn normalized_username(username: &str) -> bool {
    !username.is_empty()
        && username.len() <= 256
        && username == username.trim()
        && !username.chars().any(char::is_control)
}

fn require_no_ssh(profile: &RemoteAccessProfileSnapshot) -> Result<(), BridgeFailure> {
    if matches!(profile.ssh, SshProfileSnapshot::None(NoSshProfile::None)) {
        Ok(())
    } else {
        Err(BridgeFailure::new(
            "SUBVERSIONR_REMOTE_SSH_PROFILE_UNSUPPORTED",
            "unsupported",
            "error.remote.sshProfileUnsupported",
            json!({}),
            false,
        ))
    }
}

fn http_server_auth(auth: RemoteServerAuth) -> Result<RemoteConfigServerAuth, BridgeFailure> {
    match auth {
        RemoteServerAuth::Anonymous => Ok(RemoteConfigServerAuth::Anonymous),
        RemoteServerAuth::Basic => Ok(RemoteConfigServerAuth::Basic),
        _ => Err(BridgeFailure::new(
            "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED",
            "unsupported",
            "error.remote.authUnsupported",
            json!({}),
            false,
        )),
    }
}

fn svn_server_auth(auth: RemoteServerAuth) -> Result<RemoteConfigServerAuth, BridgeFailure> {
    match auth {
        RemoteServerAuth::Anonymous => Ok(RemoteConfigServerAuth::Anonymous),
        RemoteServerAuth::CramMd5 => Ok(RemoteConfigServerAuth::CramMd5),
        _ => Err(BridgeFailure::new(
            "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED",
            "unsupported",
            "error.remote.authUnsupported",
            json!({}),
            false,
        )),
    }
}

fn validate_endpoint(endpoint: &CanonicalEndpoint) -> Result<(), BridgeFailure> {
    if endpoint.effective_port == 0 || !canonical_host(&endpoint.canonical_host) {
        return Err(invalid_remote_field("remote.expectedOrigin"));
    }
    Ok(())
}

fn canonical_host(host: &str) -> bool {
    if host.is_empty() || host.len() > 253 || !host.is_ascii() || host != host.to_ascii_lowercase()
    {
        return false;
    }
    if let Ok(ipv4) = host.parse::<Ipv4Addr>() {
        return ipv4.to_string() == host;
    }
    if let Ok(ipv6) = host.parse::<Ipv6Addr>() {
        return ipv6.to_string() == host;
    }
    if host.starts_with('.') || host.ends_with('.') {
        return false;
    }
    host.split('.').all(|label| {
        !label.is_empty()
            && label.len() <= 63
            && !label.starts_with('-')
            && !label.ends_with('-')
            && label
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
    })
}

fn parse_authority(authority: &str, scheme: RemoteScheme) -> Result<(String, u16), BridgeFailure> {
    let default_port = match scheme {
        RemoteScheme::Http => 80,
        RemoteScheme::Https => 443,
        RemoteScheme::Svn => 3690,
        RemoteScheme::SvnSsh => 22,
    };
    if let Some(remainder) = authority.strip_prefix('[') {
        let (host, suffix) = remainder
            .split_once(']')
            .ok_or_else(|| invalid_remote_field("url"))?;
        let canonical = host
            .parse::<Ipv6Addr>()
            .map_err(|_| invalid_remote_field("url"))?
            .to_string();
        let port = if suffix.is_empty() {
            default_port
        } else {
            suffix
                .strip_prefix(':')
                .and_then(|port| port.parse::<u16>().ok())
                .filter(|port| *port > 0)
                .ok_or_else(|| invalid_remote_field("url"))?
        };
        return Ok((canonical, port));
    }
    let (host, port) = match authority.rsplit_once(':') {
        Some((host, port)) if !host.contains(':') => (
            host,
            port.parse::<u16>()
                .ok()
                .filter(|port| *port > 0)
                .ok_or_else(|| invalid_remote_field("url"))?,
        ),
        _ => (authority, default_port),
    };
    Ok((host.to_ascii_lowercase(), port))
}

fn is_canonical_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte),
        })
        && value.bytes().any(|byte| byte != b'0' && byte != b'-')
}

fn scheme_name(scheme: RemoteScheme) -> &'static str {
    match scheme {
        RemoteScheme::Http => "http",
        RemoteScheme::Https => "https",
        RemoteScheme::Svn => "svn",
        RemoteScheme::SvnSsh => "svn+ssh",
    }
}

fn invalid_remote_field(field: &str) -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_REMOTE_CONTRACT_INVALID",
        "configuration",
        "error.remote.contractInvalid",
        json!({ "field": field }),
        false,
    )
}

fn trust_epoch_mismatch() -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_REMOTE_TRUST_EPOCH_MISMATCH",
        "state",
        "error.remote.trustEpochMismatch",
        json!({}),
        false,
    )
}

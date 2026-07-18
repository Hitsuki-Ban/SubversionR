use subversionr_protocol::{
    CertificateTrustError, CertificateTrustRequest, CertificateTrustResponse, ContentGetResponse,
    Credential, CredentialError, CredentialRequest, CredentialResponse, DiagnosticsBackendStderr,
    DiagnosticsGetResponse, DiagnosticsRepositorySummary, HistoryBlameLine, HistoryBlameResponse,
    HistoryLogChangedPath, HistoryLogEntry, HistoryLogResponse, InitializeResponse, LockInfo,
    OperationFailureCause, OperationFailureDiagnostics, OperationReconcileHint,
    OperationRunResponse, OperationSummary, OperationWarning, PropertiesListResponse,
    PropertyEntry, ProtocolVersion, RemoteOperationEnvelope, RepositoryCheckoutParams,
    RepositoryCheckoutRevision, RepositoryCloseResponse, RepositoryDiscoverResponse,
    RepositoryDiscoveryCandidate, RepositoryIdentity, StatusCoverageScope, StatusDelta,
    StatusEntry, StatusRefreshTarget, StatusSnapshot, StatusSummary, StatusSummaryDelta,
    SvnErrorDiagnosticEntry, SvnErrorDiagnostics, current_platform, default_cache_schema,
    default_capabilities,
};

#[test]
fn remote_operation_envelope_rejects_unknown_fields_versions_and_enums() {
    let valid = serde_json::json!({
        "version": 1,
        "operationId": "01234567-89ab-cdef-0123-456789abcdef",
        "intent": "foreground",
        "interaction": "allowed",
        "timeoutMs": 30000,
        "workspaceTrust": "trusted",
        "trustEpoch": 1,
        "profile": {
            "schema": "subversionr.remote-profile.v1",
            "profileId": "corp-svn",
            "authority": { "scheme": "https", "canonicalHost": "svn.example.invalid", "effectivePort": 443 },
            "serverAuth": "basic",
            "serverAccount": { "mode": "fixed", "username": "alice" },
            "serverCredentialPersistence": "secretStorage",
            "tls": { "trust": "windowsRootsThenBroker" },
            "proxy": "none",
            "ssh": "none",
            "redirectPolicy": "rejectAll"
        },
        "expectedOrigin": { "scheme": "https", "canonicalHost": "svn.example.invalid", "effectivePort": 443 }
    });
    serde_json::from_value::<RemoteOperationEnvelope>(valid.clone())
        .expect("the strict v1 envelope should deserialize");

    for invalid in [
        {
            let mut value = valid.clone();
            value["expectedProxy"] = serde_json::Value::Null;
            value
        },
        {
            let mut value = valid.clone();
            value["profile"]["unknown"] = serde_json::json!(true);
            value
        },
        {
            let mut value = valid.clone();
            value["intent"] = serde_json::json!("automatic");
            value
        },
    ] {
        assert!(serde_json::from_value::<RemoteOperationEnvelope>(invalid).is_err());
    }
}

#[test]
fn operation_failure_diagnostics_serialize_strict_safe_shape() {
    let diagnostics = OperationFailureDiagnostics {
        cause: OperationFailureCause::OutOfDate,
        svn: SvnErrorDiagnostics {
            entries: vec![SvnErrorDiagnosticEntry {
                code: 160028,
                name: "SVN_ERR_FS_TXN_OUT_OF_DATE".to_string(),
            }],
            truncated: false,
        },
    };

    let json = serde_json::to_value(diagnostics).expect("diagnostics must serialize");
    assert_eq!(json["cause"], "outOfDate");
    assert_eq!(json["svn"]["entries"][0]["code"], 160028);
    assert_eq!(
        json["svn"]["entries"][0]["name"],
        "SVN_ERR_FS_TXN_OUT_OF_DATE"
    );
    assert_eq!(json["svn"]["truncated"], false);
}

#[test]
fn initialize_response_uses_protocol_v1_and_declares_required_capabilities() {
    let response = InitializeResponse::new(
        "0.1.0".to_string(),
        "bridge-unavailable".to_string(),
        "1.14.5".to_string(),
        current_platform(),
        default_capabilities(),
        1,
    );

    assert_eq!(
        response.protocol,
        ProtocolVersion {
            major: 1,
            minor: 32
        }
    );
    assert_eq!(response.cache_schema, default_cache_schema());
    assert!(response.capabilities.content_length_framing);
    assert!(!response.capabilities.real_libsvn_bridge);
    assert!(response.capabilities.repository_open);
    assert!(response.capabilities.repository_checkout);
    assert!(response.capabilities.repository_close);
    assert!(response.capabilities.repository_discover);
    assert!(response.capabilities.status_snapshot);
    assert!(response.capabilities.status_refresh);
    assert!(response.capabilities.status_remote_check);
    assert!(response.capabilities.status_stale_notification);
    assert!(response.capabilities.content_get);
    assert!(response.capabilities.content_get_revision);
    assert!(response.capabilities.history_log);
    assert!(response.capabilities.history_blame);
    assert!(response.capabilities.operation_run);
    assert!(response.capabilities.operation_run_add);
    assert!(response.capabilities.operation_run_remove);
    assert!(response.capabilities.operation_run_move);
    assert!(response.capabilities.operation_run_cleanup);
    assert!(response.capabilities.operation_run_resolve);
    assert!(response.capabilities.operation_run_update);
    assert!(response.capabilities.operation_run_update_selected_path);
    assert!(response.capabilities.operation_run_update_to_revision);
    assert!(response.capabilities.operation_run_update_depth);
    assert!(response.capabilities.operation_run_update_externals_policy);
    assert!(response.capabilities.properties_list);
    assert!(response.capabilities.operation_run_property_set);
    assert!(response.capabilities.operation_run_property_delete);
    assert!(response.capabilities.ignore);
    assert!(response.capabilities.operation_run_changelist_set);
    assert!(response.capabilities.operation_run_changelist_clear);
    assert!(response.capabilities.operation_run_lock);
    assert!(response.capabilities.operation_run_unlock);
    assert!(response.capabilities.operation_run_branch_create);
    assert!(response.capabilities.operation_run_switch);
    assert!(response.capabilities.operation_run_relocate);
    assert!(response.capabilities.operation_run_commit);
    assert!(response.capabilities.operation_run_commit_multi_path);
    assert!(response.capabilities.diagnostics_get);
    assert!(response.capabilities.credential_request);
    assert!(response.capabilities.certificate_request);
    assert!(response.capabilities.remote_operation_envelope);
    assert!(response.capabilities.trusted_config_snapshot);
    assert_eq!(response.acknowledged_trust_epoch, 1);
}

#[test]
fn initialize_response_serializes_stable_wire_field_names() {
    let response = InitializeResponse::new(
        "0.1.0".to_string(),
        "bridge-unavailable".to_string(),
        "1.14.5".to_string(),
        current_platform(),
        default_capabilities(),
        1,
    );

    let json = serde_json::to_value(response).expect("initialize response must serialize");

    assert_eq!(json["protocol"]["major"], 1);
    assert_eq!(json["protocol"]["minor"], 32);
    assert_eq!(json["cacheSchema"]["schemaId"], "subversionr.cache.v1");
    assert_eq!(json["cacheSchema"]["version"], 1);
    assert_eq!(json["cacheSchema"]["rollback"], "delete-and-reconcile");
    assert_eq!(json["backendVersion"], "0.1.0");
    assert_eq!(json["bridgeVersion"], "bridge-unavailable");
    assert_eq!(json["libsvnVersion"], "1.14.5");
    assert_eq!(json["capabilities"]["contentLengthFraming"], true);
    assert_eq!(json["capabilities"]["repositoryDiscover"], true);
    assert_eq!(json["capabilities"]["repositoryCheckout"], true);
    assert_eq!(json["capabilities"]["repositoryClose"], true);
    assert_eq!(json["capabilities"]["statusSnapshot"], true);
    assert_eq!(json["capabilities"]["statusRefresh"], true);
    assert_eq!(json["capabilities"]["statusRemoteCheck"], true);
    assert_eq!(json["capabilities"]["statusStaleNotification"], true);
    assert_eq!(json["capabilities"]["contentGet"], true);
    assert_eq!(json["capabilities"]["contentGetRevision"], true);
    assert_eq!(json["capabilities"]["historyLog"], true);
    assert_eq!(json["capabilities"]["historyBlame"], true);
    assert_eq!(json["capabilities"]["operationRun"], true);
    assert_eq!(json["capabilities"]["operationRunAdd"], true);
    assert_eq!(json["capabilities"]["operationRunRemove"], true);
    assert_eq!(json["capabilities"]["operationRunMove"], true);
    assert_eq!(json["capabilities"]["operationRunCleanup"], true);
    assert_eq!(json["capabilities"]["operationRunResolve"], true);
    assert_eq!(json["capabilities"]["operationRunUpdate"], true);
    assert_eq!(json["capabilities"]["operationRunUpdateSelectedPath"], true);
    assert_eq!(json["capabilities"]["operationRunUpdateToRevision"], true);
    assert_eq!(json["capabilities"]["operationRunUpdateDepth"], true);
    assert_eq!(
        json["capabilities"]["operationRunUpdateExternalsPolicy"],
        true
    );
    assert_eq!(json["capabilities"]["propertiesList"], true);
    assert_eq!(json["capabilities"]["operationRunPropertySet"], true);
    assert_eq!(json["capabilities"]["operationRunPropertyDelete"], true);
    assert_eq!(json["capabilities"]["ignore"], true);
    assert_eq!(json["capabilities"]["operationRunChangelistSet"], true);
    assert_eq!(json["capabilities"]["operationRunChangelistClear"], true);
    assert_eq!(json["capabilities"]["operationRunLock"], true);
    assert_eq!(json["capabilities"]["operationRunUnlock"], true);
    assert_eq!(json["capabilities"]["operationRunBranchCreate"], true);
    assert_eq!(json["capabilities"]["operationRunSwitch"], true);
    assert_eq!(json["capabilities"]["operationRunCommit"], true);
    assert_eq!(json["capabilities"]["operationRunCommitMultiPath"], true);
    assert_eq!(json["capabilities"]["diagnosticsGet"], true);
    assert_eq!(json["capabilities"]["credentialRequest"], true);
    assert_eq!(json["capabilities"]["certificateRequest"], true);
    assert_eq!(json["capabilities"]["remoteOperationEnvelope"], true);
    assert_eq!(json["capabilities"]["trustedConfigSnapshot"], true);
    assert_eq!(json["capabilities"]["remoteWorkerIsolation"], false);
    assert_eq!(json["acknowledgedTrustEpoch"], 1);
    assert!(json["capabilities"].get("authCallbacks").is_none());
}

#[test]
fn repository_checkout_params_serialize_revision_as_head_or_number() {
    let head = RepositoryCheckoutParams {
        url: "https://svn.example.invalid/project/trunk".to_string(),
        target_path: "C:/workspace/project".to_string(),
        revision: RepositoryCheckoutRevision::Head,
        depth: "infinity".to_string(),
        ignore_externals: false,
    };
    let json = serde_json::to_value(head).expect("checkout params must serialize");

    assert_eq!(json["revision"], "head");

    let number = serde_json::from_value::<RepositoryCheckoutParams>(serde_json::json!({
        "url": "https://svn.example.invalid/project/trunk",
        "targetPath": "C:/workspace/project",
        "revision": 42,
        "depth": "files",
        "ignoreExternals": true
    }))
    .expect("numbered checkout revision must deserialize");

    assert_eq!(number.revision, RepositoryCheckoutRevision::Number(42));
    assert!(
        serde_json::from_value::<RepositoryCheckoutParams>(serde_json::json!({
            "url": "https://svn.example.invalid/project/trunk",
            "targetPath": "C:/workspace/project",
            "revision": "42",
            "depth": "files",
            "ignoreExternals": true
        }))
        .is_err()
    );
}

#[test]
fn diagnostics_get_response_serializes_safe_wire_fields() {
    let response = DiagnosticsGetResponse {
        backend_version: "0.1.0".to_string(),
        bridge_version: "subversionr-svn-bridge/0.1.0".to_string(),
        libsvn_version: "1.14.5".to_string(),
        protocol: ProtocolVersion {
            major: 1,
            minor: 23,
        },
        cache_schema: default_cache_schema(),
        platform: current_platform(),
        capabilities: default_capabilities(),
        repository_summary: DiagnosticsRepositorySummary {
            open_repositories: 2,
            cached_local_entries: 7,
        },
        backend_stderr: DiagnosticsBackendStderr {
            truncated: false,
            text: None,
        },
        generated_at: "2026-06-24T00:00:00Z".to_string(),
        source: "subversionr-daemon".to_string(),
    };

    let json = serde_json::to_value(response).expect("diagnostics/get response must serialize");

    assert_eq!(json["backendVersion"], "0.1.0");
    assert_eq!(json["bridgeVersion"], "subversionr-svn-bridge/0.1.0");
    assert_eq!(json["libsvnVersion"], "1.14.5");
    assert_eq!(json["protocol"]["major"], 1);
    assert_eq!(json["protocol"]["minor"], 23);
    assert_eq!(json["cacheSchema"]["schemaId"], "subversionr.cache.v1");
    assert_eq!(json["cacheSchema"]["version"], 1);
    assert_eq!(json["cacheSchema"]["rollback"], "delete-and-reconcile");
    assert_eq!(json["capabilities"]["diagnosticsGet"], true);
    assert_eq!(json["capabilities"]["credentialRequest"], true);
    assert_eq!(json["capabilities"]["certificateRequest"], true);
    assert_eq!(json["repositorySummary"]["openRepositories"], 2);
    assert_eq!(json["repositorySummary"]["cachedLocalEntries"], 7);
    assert_eq!(json["backendStderr"]["truncated"], false);
    assert_eq!(json["backendStderr"]["text"], serde_json::Value::Null);
    assert_eq!(json["generatedAt"], "2026-06-24T00:00:00Z");
    assert_eq!(json["source"], "subversionr-daemon");
}

#[test]
fn repository_discover_response_serializes_file_external_boundaries() {
    let response = RepositoryDiscoverResponse {
        candidates: vec![RepositoryDiscoveryCandidate {
            identity: RepositoryIdentity {
                repository_uuid: "repo-uuid".to_string(),
                repository_root_url: "file:///repo".to_string(),
                working_copy_root: "C:/wc".to_string(),
                workspace_scope_root: "C:/wc".to_string(),
                format: 31,
            },
            is_nested: false,
            is_external: false,
            parent_working_copy_root: None,
        }],
        file_external_boundaries: vec!["C:/wc/externals/pinned.txt".to_string()],
    };

    let json = serde_json::to_value(response).expect("repository/discover response must serialize");

    assert_eq!(
        json["candidates"][0]["identity"]["workingCopyRoot"],
        "C:/wc"
    );
    assert_eq!(json["candidates"][0]["isExternal"], false);
    assert_eq!(
        json["fileExternalBoundaries"][0],
        "C:/wc/externals/pinned.txt"
    );
}

#[test]
fn credential_request_serializes_auth_challenge_contract() {
    let request = CredentialRequest {
        request_id: "cred-1".to_string(),
        realm: "svn://example".to_string(),
        kind: "usernamePassword".to_string(),
        username: Some("alice".to_string()),
        interactive: true,
        persistence_allowed: true,
        origin: "foreground".to_string(),
        timeout_ms: 30000,
        repository_id: Some("repo-uuid:C:/wc".to_string()),
        working_copy_root: Some("C:/wc".to_string()),
    };

    let json = serde_json::to_value(request).expect("credential request must serialize");

    assert_eq!(json["requestId"], "cred-1");
    assert_eq!(json["realm"], "svn://example");
    assert_eq!(json["kind"], "usernamePassword");
    assert_eq!(json["username"], "alice");
    assert_eq!(json["interactive"], true);
    assert_eq!(json["persistenceAllowed"], true);
    assert_eq!(json["origin"], "foreground");
    assert_eq!(json["timeoutMs"], 30000);
    assert_eq!(json["repositoryId"], "repo-uuid:C:/wc");
    assert_eq!(json["workingCopyRoot"], "C:/wc");
}

#[test]
fn credential_response_serializes_provide_and_cancel_variants() {
    let provide = CredentialResponse::Provide {
        request_id: "cred-1".to_string(),
        credential: Credential {
            username: Some("alice".to_string()),
            secret: "secret".to_string(),
        },
        persistence: "secretStorage".to_string(),
    };
    let cancel = CredentialResponse::Cancel {
        request_id: "cred-2".to_string(),
        error: CredentialError {
            code: "SUBVERSIONR_CREDENTIAL_NON_INTERACTIVE".to_string(),
            category: "auth".to_string(),
            message_key: "error.auth.credentialNonInteractive".to_string(),
            args: serde_json::json!({ "realmHash": "abc123" }),
            retryable: false,
        },
    };

    let provide_json =
        serde_json::to_value(provide).expect("credential provide response must serialize");
    let cancel_json =
        serde_json::to_value(cancel).expect("credential cancel response must serialize");

    assert_eq!(provide_json["requestId"], "cred-1");
    assert_eq!(provide_json["action"], "provide");
    assert_eq!(provide_json["credential"]["username"], "alice");
    assert_eq!(provide_json["credential"]["secret"], "secret");
    assert_eq!(provide_json["persistence"], "secretStorage");
    assert_eq!(cancel_json["requestId"], "cred-2");
    assert_eq!(cancel_json["action"], "cancel");
    assert_eq!(
        cancel_json["error"]["code"],
        "SUBVERSIONR_CREDENTIAL_NON_INTERACTIVE"
    );
    assert_eq!(cancel_json["error"]["category"], "auth");
    assert_eq!(
        cancel_json["error"]["messageKey"],
        "error.auth.credentialNonInteractive"
    );
    assert_eq!(cancel_json["error"]["args"]["realmHash"], "abc123");
    assert_eq!(cancel_json["error"]["retryable"], false);
}

#[test]
fn certificate_trust_request_serializes_auth_challenge_contract() {
    let request = CertificateTrustRequest {
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
        repository_id: Some("repo-uuid:C:/wc".to_string()),
        working_copy_root: Some("C:/wc".to_string()),
    };

    let json = serde_json::to_value(request).expect("certificate trust request must serialize");

    assert_eq!(json["requestId"], "cert-1");
    assert_eq!(json["realm"], "https://svn.example.com:443");
    assert_eq!(json["host"], "svn.example.com");
    assert_eq!(json["fingerprint"], "AA:BB:CC");
    assert_eq!(json["fingerprintAlgorithm"], "sha256-der");
    assert_eq!(json["failures"][0], "unknownCa");
    assert_eq!(json["failures"][1], "hostnameMismatch");
    assert_eq!(json["validFrom"], "2026-01-01T00:00:00Z");
    assert_eq!(json["validTo"], "2027-01-01T00:00:00Z");
    assert_eq!(json["issuer"], "CN=Example Test CA");
    assert_eq!(json["subject"], "CN=svn.example.com");
    assert_eq!(json["interactive"], true);
    assert_eq!(json["persistenceAllowed"], true);
    assert_eq!(json["origin"], "foreground");
    assert_eq!(json["timeoutMs"], 30000);
    assert_eq!(json["repositoryId"], "repo-uuid:C:/wc");
    assert_eq!(json["workingCopyRoot"], "C:/wc");
}

#[test]
fn certificate_trust_response_serializes_trust_and_reject_variants() {
    let trust_once = CertificateTrustResponse::Trust {
        request_id: "cert-1".to_string(),
        trust: "once".to_string(),
        fingerprint: "AA:BB:CC".to_string(),
        fingerprint_algorithm: "sha256-der".to_string(),
    };
    let reject = CertificateTrustResponse::Reject {
        request_id: "cert-2".to_string(),
        error: CertificateTrustError {
            code: "SUBVERSIONR_CERTIFICATE_NON_INTERACTIVE".to_string(),
            category: "auth".to_string(),
            message_key: "error.auth.certificateNonInteractive".to_string(),
            args: serde_json::json!({
                "realmHash": "abc123",
                "fingerprint": "AA:BB:CC",
                "fingerprintAlgorithm": "sha256-der"
            }),
            retryable: false,
        },
    };

    let trust_json =
        serde_json::to_value(trust_once).expect("certificate trust response must serialize");
    let reject_json =
        serde_json::to_value(reject).expect("certificate reject response must serialize");

    assert_eq!(trust_json["requestId"], "cert-1");
    assert_eq!(trust_json["action"], "trust");
    assert_eq!(trust_json["trust"], "once");
    assert_eq!(trust_json["fingerprint"], "AA:BB:CC");
    assert_eq!(trust_json["fingerprintAlgorithm"], "sha256-der");
    assert_eq!(reject_json["requestId"], "cert-2");
    assert_eq!(reject_json["action"], "reject");
    assert_eq!(
        reject_json["error"]["code"],
        "SUBVERSIONR_CERTIFICATE_NON_INTERACTIVE"
    );
    assert_eq!(reject_json["error"]["category"], "auth");
    assert_eq!(
        reject_json["error"]["messageKey"],
        "error.auth.certificateNonInteractive"
    );
    assert_eq!(reject_json["error"]["args"]["realmHash"], "abc123");
    assert_eq!(reject_json["error"]["args"]["fingerprint"], "AA:BB:CC");
    assert_eq!(reject_json["error"]["retryable"], false);
}

#[test]
fn content_get_response_serializes_binary_safe_wire_fields() {
    let response = ContentGetResponse {
        repository_id: "uuid:C:/wc".to_string(),
        epoch: 9,
        path: "src/main.c".to_string(),
        revision: "base".to_string(),
        content_base64: "YmFzZQo=".to_string(),
        byte_length: 5,
        mime_type: Some("text/plain".to_string()),
        is_binary: false,
        source: "libsvn-base".to_string(),
    };

    let json = serde_json::to_value(response).expect("content/get response must serialize");

    assert_eq!(json["repositoryId"], "uuid:C:/wc");
    assert_eq!(json["epoch"], 9);
    assert_eq!(json["path"], "src/main.c");
    assert_eq!(json["revision"], "base");
    assert_eq!(json["contentBase64"], "YmFzZQo=");
    assert_eq!(json["byteLength"], 5);
    assert_eq!(json["mimeType"], "text/plain");
    assert_eq!(json["isBinary"], false);
    assert_eq!(json["source"], "libsvn-base");
}

#[test]
fn history_blame_response_serializes_stable_wire_fields() {
    let response = HistoryBlameResponse {
        repository_id: "uuid:C:/wc".to_string(),
        epoch: 12,
        path: "src/main.c".to_string(),
        peg_revision: "head".to_string(),
        start_revision: "r0".to_string(),
        end_revision: "head".to_string(),
        resolved_start_revision: 1,
        resolved_end_revision: 7,
        line_start: 1,
        line_limit: 100,
        ignore_whitespace: "none".to_string(),
        ignore_eol_style: false,
        ignore_mime_type: false,
        include_merged_revisions: true,
        has_more: true,
        lines: vec![HistoryBlameLine {
            line_number: 1,
            revision: Some(7),
            author: Some("alice".to_string()),
            date: Some("2026-06-23T00:00:00.000000Z".to_string()),
            merged_revision: None,
            merged_author: None,
            merged_date: None,
            merged_path: None,
            line_base64: "aW50IG1haW4oKSB7".to_string(),
            byte_length: 12,
            local_change: false,
        }],
        source: "libsvn-blame".to_string(),
    };

    let json = serde_json::to_value(response).expect("history/blame response must serialize");

    assert_eq!(json["repositoryId"], "uuid:C:/wc");
    assert_eq!(json["epoch"], 12);
    assert_eq!(json["path"], "src/main.c");
    assert_eq!(json["pegRevision"], "head");
    assert_eq!(json["startRevision"], "r0");
    assert_eq!(json["endRevision"], "head");
    assert_eq!(json["resolvedStartRevision"], 1);
    assert_eq!(json["resolvedEndRevision"], 7);
    assert_eq!(json["lineStart"], 1);
    assert_eq!(json["lineLimit"], 100);
    assert_eq!(json["ignoreWhitespace"], "none");
    assert_eq!(json["ignoreEolStyle"], false);
    assert_eq!(json["ignoreMimeType"], false);
    assert_eq!(json["includeMergedRevisions"], true);
    assert_eq!(json["hasMore"], true);
    assert_eq!(json["lines"][0]["lineNumber"], 1);
    assert_eq!(json["lines"][0]["revision"], 7);
    assert_eq!(json["lines"][0]["author"], "alice");
    assert_eq!(json["lines"][0]["date"], "2026-06-23T00:00:00.000000Z");
    assert_eq!(json["lines"][0]["mergedRevision"], serde_json::Value::Null);
    assert_eq!(json["lines"][0]["mergedAuthor"], serde_json::Value::Null);
    assert_eq!(json["lines"][0]["mergedDate"], serde_json::Value::Null);
    assert_eq!(json["lines"][0]["mergedPath"], serde_json::Value::Null);
    assert_eq!(json["lines"][0]["lineBase64"], "aW50IG1haW4oKSB7");
    assert_eq!(json["lines"][0]["byteLength"], 12);
    assert_eq!(json["lines"][0]["localChange"], false);
    assert_eq!(json["source"], "libsvn-blame");
}

#[test]
fn history_log_response_serializes_stable_wire_fields() {
    let response = HistoryLogResponse {
        repository_id: "uuid:C:/wc".to_string(),
        epoch: 11,
        path: "src/main.c".to_string(),
        start_revision: "head".to_string(),
        end_revision: "r0".to_string(),
        limit: 25,
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
    };

    let json = serde_json::to_value(response).expect("history/log response must serialize");

    assert_eq!(json["repositoryId"], "uuid:C:/wc");
    assert_eq!(json["epoch"], 11);
    assert_eq!(json["path"], "src/main.c");
    assert_eq!(json["startRevision"], "head");
    assert_eq!(json["endRevision"], "r0");
    assert_eq!(json["limit"], 25);
    assert_eq!(json["entries"][0]["revision"], 7);
    assert_eq!(json["entries"][0]["author"], "alice");
    assert_eq!(json["entries"][0]["date"], "2026-06-23T00:00:00.000000Z");
    assert_eq!(json["entries"][0]["message"], "edit file");
    assert_eq!(
        json["entries"][0]["changedPaths"][0]["path"],
        "/trunk/src/main.c"
    );
    assert_eq!(json["entries"][0]["changedPaths"][0]["action"], "M");
    assert_eq!(
        json["entries"][0]["changedPaths"][0]["copyFromPath"],
        serde_json::Value::Null
    );
    assert_eq!(
        json["entries"][0]["changedPaths"][0]["copyFromRevision"],
        serde_json::Value::Null
    );
    assert_eq!(json["entries"][0]["changedPaths"][0]["nodeKind"], "file");
    assert_eq!(
        json["entries"][0]["changedPaths"][0]["textModified"],
        "true"
    );
    assert_eq!(
        json["entries"][0]["changedPaths"][0]["propertiesModified"],
        "false"
    );
    assert_eq!(json["entries"][0]["hasChildren"], false);
    assert_eq!(json["entries"][0]["nonInheritable"], false);
    assert_eq!(json["entries"][0]["subtractiveMerge"], false);
    assert_eq!(json["source"], "libsvn-log");
}

#[test]
fn properties_list_response_serializes_property_entries_contract() {
    let response = PropertiesListResponse {
        repository_id: "uuid:C:/wc".to_string(),
        epoch: 3,
        path: "src".to_string(),
        properties: vec![PropertyEntry {
            name: "svn:ignore".to_string(),
            value: "target\nnode_modules".to_string(),
            value_encoding: "utf8".to_string(),
        }],
        source: "libsvn-local".to_string(),
    };

    let json = serde_json::to_value(response).expect("properties/list response must serialize");

    assert_eq!(json["repositoryId"], "uuid:C:/wc");
    assert_eq!(json["epoch"], 3);
    assert_eq!(json["path"], "src");
    assert_eq!(json["properties"][0]["name"], "svn:ignore");
    assert_eq!(json["properties"][0]["value"], "target\nnode_modules");
    assert_eq!(json["properties"][0]["valueEncoding"], "utf8");
    assert_eq!(json["source"], "libsvn-local");
}

#[test]
fn operation_run_response_serializes_revert_result_contract() {
    let response = OperationRunResponse {
        repository_id: "uuid:C:/wc".to_string(),
        epoch: 3,
        operation_id: "op-1".to_string(),
        kind: "revert".to_string(),
        touched_paths: vec!["src/main.c".to_string()],
        revision: None,
        summary: OperationSummary {
            affected_paths: 1,
            skipped_paths: 0,
        },
        warnings: vec![OperationWarning {
            code: "SVN_OPERATION_PATH_SKIPPED".to_string(),
            message_key: "warning.operation.pathSkipped".to_string(),
            args: serde_json::json!({ "path": "scratch.txt" }),
        }],
        reconcile: OperationReconcileHint {
            targets: vec![StatusRefreshTarget {
                path: "src/main.c".to_string(),
                depth: "empty".to_string(),
                reason: "operationRevert".to_string(),
            }],
            requires_full_reconcile: false,
        },
    };

    let json = serde_json::to_value(response).expect("operation/run response must serialize");

    assert_eq!(json["repositoryId"], "uuid:C:/wc");
    assert_eq!(json["epoch"], 3);
    assert_eq!(json["operationId"], "op-1");
    assert_eq!(json["kind"], "revert");
    assert_eq!(json["touchedPaths"][0], "src/main.c");
    assert_eq!(json["revision"], serde_json::Value::Null);
    assert_eq!(json["summary"]["affectedPaths"], 1);
    assert_eq!(json["summary"]["skippedPaths"], 0);
    assert_eq!(json["warnings"][0]["code"], "SVN_OPERATION_PATH_SKIPPED");
    assert_eq!(json["reconcile"]["targets"][0]["path"], "src/main.c");
    assert_eq!(json["reconcile"]["targets"][0]["reason"], "operationRevert");
    assert_eq!(json["reconcile"]["requiresFullReconcile"], false);
}

#[test]
fn operation_run_response_serializes_add_result_contract() {
    let response = OperationRunResponse {
        repository_id: "uuid:C:/wc".to_string(),
        epoch: 3,
        operation_id: "op-2".to_string(),
        kind: "add".to_string(),
        touched_paths: vec!["scratch.txt".to_string()],
        revision: None,
        summary: OperationSummary {
            affected_paths: 1,
            skipped_paths: 0,
        },
        warnings: Vec::new(),
        reconcile: OperationReconcileHint {
            targets: vec![StatusRefreshTarget {
                path: "scratch.txt".to_string(),
                depth: "empty".to_string(),
                reason: "operationAdd".to_string(),
            }],
            requires_full_reconcile: false,
        },
    };

    let json = serde_json::to_value(response).expect("operation/run add response must serialize");

    assert_eq!(json["kind"], "add");
    assert_eq!(json["touchedPaths"][0], "scratch.txt");
    assert_eq!(json["summary"]["affectedPaths"], 1);
    assert_eq!(
        json["warnings"].as_array().expect("warnings array").len(),
        0
    );
    assert_eq!(json["reconcile"]["targets"][0]["reason"], "operationAdd");
}

#[test]
fn operation_run_response_serializes_remove_result_contract() {
    let response = OperationRunResponse {
        repository_id: "uuid:C:/wc".to_string(),
        epoch: 3,
        operation_id: "op-3".to_string(),
        kind: "remove".to_string(),
        touched_paths: vec!["src/old.c".to_string()],
        revision: None,
        summary: OperationSummary {
            affected_paths: 1,
            skipped_paths: 0,
        },
        warnings: Vec::new(),
        reconcile: OperationReconcileHint {
            targets: vec![StatusRefreshTarget {
                path: "src/old.c".to_string(),
                depth: "empty".to_string(),
                reason: "operationRemove".to_string(),
            }],
            requires_full_reconcile: false,
        },
    };

    let json =
        serde_json::to_value(response).expect("operation/run remove response must serialize");

    assert_eq!(json["kind"], "remove");
    assert_eq!(json["touchedPaths"][0], "src/old.c");
    assert_eq!(json["summary"]["affectedPaths"], 1);
    assert_eq!(
        json["warnings"].as_array().expect("warnings array").len(),
        0
    );
    assert_eq!(json["reconcile"]["targets"][0]["reason"], "operationRemove");
}

#[test]
fn operation_run_response_serializes_cleanup_result_contract() {
    let response = OperationRunResponse {
        repository_id: "uuid:C:/wc".to_string(),
        epoch: 4,
        operation_id: "op-4".to_string(),
        kind: "cleanup".to_string(),
        touched_paths: vec![".".to_string()],
        revision: None,
        summary: OperationSummary {
            affected_paths: 1,
            skipped_paths: 0,
        },
        warnings: Vec::new(),
        reconcile: OperationReconcileHint {
            targets: Vec::new(),
            requires_full_reconcile: true,
        },
    };

    let json =
        serde_json::to_value(response).expect("operation/run cleanup response must serialize");

    assert_eq!(json["kind"], "cleanup");
    assert_eq!(json["touchedPaths"][0], ".");
    assert_eq!(json["summary"]["affectedPaths"], 1);
    assert_eq!(
        json["warnings"].as_array().expect("warnings array").len(),
        0
    );
    assert_eq!(json["reconcile"]["targets"].as_array().unwrap().len(), 0);
    assert_eq!(json["reconcile"]["requiresFullReconcile"], true);
}

#[test]
fn operation_run_response_serializes_update_result_contract() {
    let response = OperationRunResponse {
        repository_id: "uuid:C:/wc".to_string(),
        epoch: 6,
        operation_id: "op-6".to_string(),
        kind: "update".to_string(),
        touched_paths: vec![".".to_string()],
        revision: Some(8),
        summary: OperationSummary {
            affected_paths: 1,
            skipped_paths: 0,
        },
        warnings: Vec::new(),
        reconcile: OperationReconcileHint {
            targets: Vec::new(),
            requires_full_reconcile: true,
        },
    };

    let json =
        serde_json::to_value(response).expect("operation/run update response must serialize");

    assert_eq!(json["kind"], "update");
    assert_eq!(json["touchedPaths"][0], ".");
    assert_eq!(json["revision"], 8);
    assert_eq!(json["summary"]["affectedPaths"], 1);
    assert_eq!(
        json["warnings"].as_array().expect("warnings array").len(),
        0
    );
    assert_eq!(json["reconcile"]["targets"].as_array().unwrap().len(), 0);
    assert_eq!(json["reconcile"]["requiresFullReconcile"], true);
}

#[test]
fn operation_run_response_serializes_property_set_result_contract() {
    let response = OperationRunResponse {
        repository_id: "uuid:C:/wc".to_string(),
        epoch: 6,
        operation_id: "op-7".to_string(),
        kind: "propertySet".to_string(),
        touched_paths: vec!["src".to_string()],
        revision: None,
        summary: OperationSummary {
            affected_paths: 1,
            skipped_paths: 0,
        },
        warnings: Vec::new(),
        reconcile: OperationReconcileHint {
            targets: vec![StatusRefreshTarget {
                path: "src".to_string(),
                depth: "empty".to_string(),
                reason: "operationPropertySet".to_string(),
            }],
            requires_full_reconcile: false,
        },
    };

    let json =
        serde_json::to_value(response).expect("operation/run propertySet response must serialize");

    assert_eq!(json["kind"], "propertySet");
    assert_eq!(json["touchedPaths"][0], "src");
    assert_eq!(json["revision"], serde_json::Value::Null);
    assert_eq!(
        json["reconcile"]["targets"][0]["reason"],
        "operationPropertySet"
    );
    assert_eq!(json["reconcile"]["requiresFullReconcile"], false);
}

#[test]
fn operation_run_response_serializes_property_delete_result_contract() {
    let response = OperationRunResponse {
        repository_id: "uuid:C:/wc".to_string(),
        epoch: 6,
        operation_id: "op-8".to_string(),
        kind: "propertyDelete".to_string(),
        touched_paths: vec!["src".to_string()],
        revision: None,
        summary: OperationSummary {
            affected_paths: 1,
            skipped_paths: 0,
        },
        warnings: Vec::new(),
        reconcile: OperationReconcileHint {
            targets: vec![StatusRefreshTarget {
                path: "src".to_string(),
                depth: "empty".to_string(),
                reason: "operationPropertyDelete".to_string(),
            }],
            requires_full_reconcile: false,
        },
    };

    let json = serde_json::to_value(response)
        .expect("operation/run propertyDelete response must serialize");

    assert_eq!(json["kind"], "propertyDelete");
    assert_eq!(json["touchedPaths"][0], "src");
    assert_eq!(json["revision"], serde_json::Value::Null);
    assert_eq!(
        json["reconcile"]["targets"][0]["reason"],
        "operationPropertyDelete"
    );
    assert_eq!(json["reconcile"]["requiresFullReconcile"], false);
}

#[test]
fn operation_run_response_serializes_commit_result_contract() {
    let response = OperationRunResponse {
        repository_id: "uuid:C:/wc".to_string(),
        epoch: 7,
        operation_id: "op-7".to_string(),
        kind: "commit".to_string(),
        touched_paths: vec!["src/main.c".to_string()],
        revision: Some(9),
        summary: OperationSummary {
            affected_paths: 1,
            skipped_paths: 0,
        },
        warnings: Vec::new(),
        reconcile: OperationReconcileHint {
            targets: vec![StatusRefreshTarget {
                path: "src/main.c".to_string(),
                depth: "empty".to_string(),
                reason: "operationCommit".to_string(),
            }],
            requires_full_reconcile: false,
        },
    };

    let json =
        serde_json::to_value(response).expect("operation/run commit response must serialize");

    assert_eq!(json["kind"], "commit");
    assert_eq!(json["touchedPaths"][0], "src/main.c");
    assert_eq!(json["revision"], 9);
    assert_eq!(json["summary"]["affectedPaths"], 1);
    assert_eq!(
        json["warnings"].as_array().expect("warnings array").len(),
        0
    );
    assert_eq!(json["reconcile"]["targets"][0]["reason"], "operationCommit");
    assert_eq!(json["reconcile"]["requiresFullReconcile"], false);
}

#[test]
fn operation_run_response_serializes_resolve_result_contract() {
    let response = OperationRunResponse {
        repository_id: "uuid:C:/wc".to_string(),
        epoch: 5,
        operation_id: "op-5".to_string(),
        kind: "resolve".to_string(),
        touched_paths: vec!["src/conflicted.txt".to_string()],
        revision: None,
        summary: OperationSummary {
            affected_paths: 1,
            skipped_paths: 0,
        },
        warnings: Vec::new(),
        reconcile: OperationReconcileHint {
            targets: vec![StatusRefreshTarget {
                path: "src/conflicted.txt".to_string(),
                depth: "empty".to_string(),
                reason: "operationResolve".to_string(),
            }],
            requires_full_reconcile: false,
        },
    };

    let json =
        serde_json::to_value(response).expect("operation/run resolve response must serialize");

    assert_eq!(json["kind"], "resolve");
    assert_eq!(json["touchedPaths"][0], "src/conflicted.txt");
    assert_eq!(json["summary"]["affectedPaths"], 1);
    assert_eq!(
        json["warnings"].as_array().expect("warnings array").len(),
        0
    );
    assert_eq!(
        json["reconcile"]["targets"][0]["reason"],
        "operationResolve"
    );
    assert_eq!(json["reconcile"]["requiresFullReconcile"], false);
}

#[test]
fn repository_identity_serializes_stable_wire_field_names() {
    let identity = RepositoryIdentity {
        repository_uuid: "uuid".to_string(),
        repository_root_url: "file:///repo".to_string(),
        working_copy_root: "C:/wc".to_string(),
        workspace_scope_root: "C:/workspace".to_string(),
        format: 31,
    };

    let json = serde_json::to_value(identity).expect("repository identity must serialize");

    assert_eq!(json["repositoryUuid"], "uuid");
    assert_eq!(json["repositoryRootUrl"], "file:///repo");
    assert_eq!(json["workingCopyRoot"], "C:/wc");
    assert_eq!(json["workspaceScopeRoot"], "C:/workspace");
    assert_eq!(json["format"], 31);
}

#[test]
fn repository_close_response_serializes_stable_wire_field_names() {
    let response = RepositoryCloseResponse {
        repository_id: "uuid:C:/wc".to_string(),
        epoch: 7,
        closed: true,
    };

    let json = serde_json::to_value(response).expect("repository close response must serialize");

    assert_eq!(json["repositoryId"], "uuid:C:/wc");
    assert_eq!(json["epoch"], 7);
    assert_eq!(json["closed"], true);
}

#[test]
fn status_delta_serializes_local_and_remote_upsert_remove_fields() {
    let delta = StatusDelta {
        repository_id: "uuid:C:/wc".to_string(),
        epoch: 2,
        generation: 4,
        coverage: vec![StatusCoverageScope {
            path: "src/main.c".to_string(),
            depth: "empty".to_string(),
            generation: 4,
            reason: "fileChanged".to_string(),
        }],
        upsert: vec![StatusEntry {
            path: "src/main.c".to_string(),
            kind: "file".to_string(),
            node_status: "modified".to_string(),
            text_status: "modified".to_string(),
            property_status: "normal".to_string(),
            local_status: "modified".to_string(),
            remote_status: "notChecked".to_string(),
            revision: 7,
            changed_revision: 7,
            changed_author: None,
            changed_date: None,
            changelist: None,
            lock: Some(LockInfo {
                token: Some("opaquelocktoken:local".to_string()),
                owner: Some("alice".to_string()),
                comment: Some("editing main".to_string()),
                created_date: Some("2026-06-22T00:00:00Z".to_string()),
                expires_date: None,
                is_remote: false,
            }),
            needs_lock: true,
            copy: None,
            move_: None,
            switched: false,
            depth: "infinity".to_string(),
            conflict: Some("conflicted".to_string()),
            conflict_artifacts: vec!["src/main.c.mine".to_string(), "src/main.c.r8".to_string()],
            external: false,
            generation: 4,
        }],
        remove: vec!["src/old.c".to_string()],
        remote_upsert: vec![StatusEntry {
            path: "src/incoming.c".to_string(),
            kind: "file".to_string(),
            node_status: "normal".to_string(),
            text_status: "normal".to_string(),
            property_status: "normal".to_string(),
            local_status: "normal".to_string(),
            remote_status: "modified".to_string(),
            revision: 7,
            changed_revision: 8,
            changed_author: Some("bob".to_string()),
            changed_date: Some("2026-06-22T00:01:00Z".to_string()),
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
            generation: 4,
        }],
        remote_remove: vec!["src/old-incoming.c".to_string()],
        summary_delta: StatusSummaryDelta {
            local_changes: -1,
            remote_changes: 1,
            conflicts: 0,
            unversioned: 0,
        },
        completeness: "partial".to_string(),
        timestamp: "2026-06-22T00:00:00Z".to_string(),
        source: "libsvn-local".to_string(),
    };
    let target = StatusRefreshTarget {
        path: "src/main.c".to_string(),
        depth: "empty".to_string(),
        reason: "fileChanged".to_string(),
    };

    let delta_json = serde_json::to_value(delta).expect("status delta must serialize");
    let target_json = serde_json::to_value(target).expect("refresh target must serialize");

    assert_eq!(target_json["path"], "src/main.c");
    assert_eq!(target_json["depth"], "empty");
    assert_eq!(target_json["reason"], "fileChanged");
    assert_eq!(delta_json["coverage"][0]["path"], "src/main.c");
    assert_eq!(delta_json["coverage"][0]["depth"], "empty");
    assert_eq!(delta_json["upsert"][0]["path"], "src/main.c");
    assert_eq!(delta_json["upsert"][0]["lock"]["owner"], "alice");
    assert_eq!(delta_json["upsert"][0]["lock"]["isRemote"], false);
    assert_eq!(delta_json["upsert"][0]["needsLock"], true);
    assert_eq!(
        delta_json["upsert"][0]["conflictArtifacts"][0],
        "src/main.c.mine"
    );
    assert_eq!(
        delta_json["upsert"][0]["conflictArtifacts"][1],
        "src/main.c.r8"
    );
    assert_eq!(delta_json["remove"][0], "src/old.c");
    assert_eq!(delta_json["remoteUpsert"][0]["path"], "src/incoming.c");
    assert_eq!(delta_json["remoteUpsert"][0]["remoteStatus"], "modified");
    assert_eq!(delta_json["remoteRemove"][0], "src/old-incoming.c");
    assert_eq!(delta_json["summaryDelta"]["localChanges"], -1);
    assert_eq!(delta_json["summaryDelta"]["remoteChanges"], 1);
    assert_eq!(delta_json["completeness"], "partial");

    let mut missing_conflict_artifacts = delta_json["upsert"][0].clone();
    missing_conflict_artifacts
        .as_object_mut()
        .expect("status entry must be an object")
        .remove("conflictArtifacts");
    assert!(serde_json::from_value::<StatusEntry>(missing_conflict_artifacts).is_err());
}

#[test]
fn status_snapshot_serializes_local_and_remote_dimensions_separately() {
    let snapshot = StatusSnapshot {
        repository_id: "uuid:C:/wc".to_string(),
        epoch: 2,
        generation: 3,
        completeness: "complete".to_string(),
        identity: RepositoryIdentity {
            repository_uuid: "uuid".to_string(),
            repository_root_url: "file:///repo".to_string(),
            working_copy_root: "C:/wc".to_string(),
            workspace_scope_root: "C:/workspace".to_string(),
            format: 31,
        },
        local_entries: vec![StatusEntry {
            path: "src/main.c".to_string(),
            kind: "file".to_string(),
            node_status: "modified".to_string(),
            text_status: "modified".to_string(),
            property_status: "normal".to_string(),
            local_status: "modified".to_string(),
            remote_status: "notChecked".to_string(),
            revision: 7,
            changed_revision: 7,
            changed_author: Some("alice".to_string()),
            changed_date: Some("2026-06-22T00:00:00Z".to_string()),
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
            generation: 3,
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
    };

    let json = serde_json::to_value(snapshot).expect("status snapshot must serialize");

    assert_eq!(json["repositoryId"], "uuid:C:/wc");
    assert_eq!(json["identity"]["workspaceScopeRoot"], "C:/workspace");
    assert_eq!(json["localEntries"][0]["propertyStatus"], "normal");
    assert_eq!(json["localEntries"][0]["localStatus"], "modified");
    assert_eq!(json["localEntries"][0]["remoteStatus"], "notChecked");
    assert_eq!(
        json["localEntries"][0]["conflictArtifacts"],
        serde_json::json!([])
    );
    assert_eq!(json["localEntries"][0]["move"], serde_json::Value::Null);
    assert_eq!(
        json["remoteEntries"]
            .as_array()
            .expect("remote entries array")
            .len(),
        0
    );
    assert_eq!(json["summary"]["localChanges"], 1);
    assert_eq!(json["timestamp"], "2026-06-22T00:00:00Z");
}

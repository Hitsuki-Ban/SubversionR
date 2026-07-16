use std::collections::BTreeMap;
use std::env;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::io::{self, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{
    Arc, Mutex, MutexGuard,
    atomic::{AtomicBool, AtomicUsize, Ordering},
    mpsc,
};
use std::thread;
use std::time::{Duration, Instant};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use subversionr_daemon::{
    AuthRequestBroker, BridgeApi, BridgeCancellationToken, BridgeFailure, HistoryBlameRequest,
    HistoryLogRequest, NativeBridge, UnavailableAuthRequestBroker, run_json_rpc_stdio,
};
use subversionr_protocol::{
    CertificateTrustError, CertificateTrustRequest, CertificateTrustResponse, Credential,
    CredentialRequest, CredentialResponse, OperationFailureCause,
};

static NATIVE_TEST_MUTEX: Mutex<()> = Mutex::new(());

#[test]
fn native_bridge_configures_file_commit_author_before_commit_mutation() {
    let source_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../native/svn-bridge/src/subversionr_bridge.c");
    let source = fs::read_to_string(&source_path)
        .expect("native bridge source should be readable")
        .replace("\r\n", "\n");
    let commit_start = source
        .find("static int bridge_operation_commit_impl(")
        .expect("commit implementation should exist");
    let commit_end = source[commit_start..]
        .find("\nint subversionr_bridge_operation_commit_with_auth(")
        .map(|offset| commit_start + offset)
        .expect("commit implementation should be bounded");
    let commit = &source[commit_start..commit_end];

    let unavailable_check = commit
        .find("return BRIDGE_OPERATION_LOCAL_COMMIT_AUTHOR_UNAVAILABLE;")
        .expect("file-backed commits should reject a missing OS username");
    let default_username_parameter = commit
        .find("SVN_AUTH_PARAM_DEFAULT_USERNAME")
        .expect("file-backed commits should inject the OS username through libsvn auth");
    let commit_mutation = commit
        .find("svn_client_commit6(")
        .expect("commit implementation should call libsvn commit");

    assert!(unavailable_check < default_username_parameter);
    assert!(default_username_parameter < commit_mutation);
    assert!(
        commit.contains("file_url_err->apr_err == SVN_ERR_RA_ILLEGAL_URL"),
        "only libsvn's explicit non-file URL result may classify the target as remote"
    );
    assert_eq!(
        source.matches("SVN_AUTH_PARAM_DEFAULT_USERNAME").count(),
        1,
        "default username injection must remain scoped to local commit setup"
    );
}

#[test]
fn native_bridge_public_operations_clear_stale_diagnostics_before_validation() {
    let source_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../native/svn-bridge/src/subversionr_bridge.c");
    let source = fs::read_to_string(&source_path)
        .expect("native bridge source should be readable")
        .replace("\r\n", "\n");
    let operations = [
        "subversionr_bridge_open_working_copy",
        "subversionr_bridge_open_working_copy_with_auth",
        "subversionr_bridge_probe_remote_url_with_auth",
        "subversionr_bridge_status_scan",
        "subversionr_bridge_status_remote_scan_with_auth",
        "subversionr_bridge_content_get_with_auth",
        "subversionr_bridge_properties_list",
        "subversionr_bridge_history_log_with_auth",
        "subversionr_bridge_history_blame_with_auth",
        "subversionr_bridge_operation_revert",
        "subversionr_bridge_operation_add",
        "subversionr_bridge_operation_remove",
        "subversionr_bridge_operation_move",
        "subversionr_bridge_operation_resolve",
        "subversionr_bridge_operation_cleanup",
        "subversionr_bridge_operation_upgrade",
        "subversionr_bridge_operation_update",
        "subversionr_bridge_repository_checkout_with_auth",
        "subversionr_bridge_operation_property_set",
        "subversionr_bridge_operation_property_delete",
        "subversionr_bridge_operation_changelist_set",
        "subversionr_bridge_operation_changelist_clear",
        "subversionr_bridge_operation_lock_with_auth",
        "subversionr_bridge_operation_unlock_with_auth",
        "subversionr_bridge_operation_branch_create_with_auth",
        "subversionr_bridge_operation_switch_with_auth",
        "subversionr_bridge_operation_relocate_with_auth",
        "subversionr_bridge_operation_merge_range_with_auth",
        "subversionr_bridge_operation_commit_with_auth",
    ];

    for operation in operations {
        let declaration = format!("int {operation}(");
        let start = source
            .find(&declaration)
            .unwrap_or_else(|| panic!("missing public operation {operation}"));
        let body = &source[start..];
        let body_start = body
            .find("{\n")
            .unwrap_or_else(|| panic!("missing function body for {operation}"));
        let prefix = body[body_start + 2..].trim_start();
        assert!(
            prefix.starts_with("bridge_prepare_call(runtime);"),
            "{operation} must clear stale diagnostics before any validation or setup"
        );
    }

    let getter_start = source
        .find("int subversionr_bridge_last_error_diagnostics(")
        .expect("last error diagnostics getter should exist");
    let getter = &source[getter_start
        ..source[getter_start..]
            .find("\n}\n")
            .map(|end| getter_start + end + 3)
            .expect("last error diagnostics getter should be bounded")];
    assert!(
        !getter.contains("bridge_prepare_call(runtime)"),
        "diagnostics getter must not clear the diagnostics it returns"
    );
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_failure_diagnostics_do_not_leak_into_later_validation_failure() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    let non_working_copy = fixture._temp.path.join("not-a-working-copy");
    fs::create_dir(&non_working_copy).expect("non-working-copy fixture should be created");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let native_failure = bridge
        .open_working_copy(
            non_working_copy
                .to_str()
                .expect("fixture path should be UTF-8"),
        )
        .expect_err("plain directory must not open as a working copy");
    let diagnostics = native_failure
        .diagnostics()
        .expect("libsvn failure should retain safe diagnostics");
    assert_eq!(diagnostics.cause, OperationFailureCause::NotWorkingCopy);
    assert!(!diagnostics.svn.entries.is_empty());
    assert!(diagnostics.svn.entries.len() <= 8);

    let mut auth = UnavailableAuthRequestBroker;
    let validation_failure = bridge
        .probe_remote_url_with_auth("not-a-repository-url", &mut auth)
        .expect_err("invalid URL should fail native validation");
    assert!(
        validation_failure.diagnostics().is_none(),
        "validation failure must not reuse the previous libsvn chain"
    );

    bridge
        .open_working_copy(&fixture.wc_path())
        .expect("a successful call should clear earlier diagnostics");
    let later_validation_failure = bridge
        .probe_remote_url_with_auth("still-not-a-repository-url", &mut auth)
        .expect_err("invalid URL should fail after a successful call");
    assert!(
        later_validation_failure.diagnostics().is_none(),
        "post-success validation failure must start with empty diagnostics"
    );
}

#[test]
#[ignore = "requires a verified native bridge DLL built from staged Apache Subversion"]
fn native_bridge_loads_built_dll_and_reports_libsvn_version() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let info = bridge.info();

    assert!(info.real_libsvn_bridge);
    assert_eq!(
        info.bridge_version,
        format!("subversionr-svn-bridge/{}", env!("CARGO_PKG_VERSION"))
    );
    assert!(info.libsvn_version.starts_with("1.14.5"));
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_opens_working_copy_created_by_staged_subversion_tools() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let fixture =
        WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &tool_dir.join("svn.exe"));

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let wc_path = fixture.wc_path();
    let identity = bridge
        .open_working_copy(&wc_path)
        .expect("native bridge should open the fixture working copy");

    assert!(!identity.repository_uuid.trim().is_empty());
    assert_eq!(identity.repository_root_url, fixture.repo_url);
    assert_eq!(identity.workspace_scope_root, wc_path);
    assert!(identity.format > 0);
    assert!(
        identity.working_copy_root.ends_with("\\wc") || identity.working_copy_root.ends_with("/wc"),
        "working copy root should point at the checked-out fixture, got {}",
        identity.working_copy_root
    );
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_opens_subdirectory_created_by_staged_subversion_tools() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    let source_dir = fixture.wc.join("src");
    fs::create_dir_all(&source_dir).expect("source fixture directory should be created");
    fs::write(source_dir.join("tracked.txt"), "initial\n")
        .expect("source fixture file should be written");
    run_tool(
        &svn,
        [
            "add".as_ref(),
            source_dir.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    fixture.commit_path(&svn, &source_dir, "add source directory fixture");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let subdirectory_path = source_dir.to_string_lossy().to_string();
    let identity = bridge
        .open_working_copy(&subdirectory_path)
        .expect("native bridge should open the fixture working copy from a subdirectory");

    assert!(!identity.repository_uuid.trim().is_empty());
    assert_eq!(identity.repository_root_url, fixture.repo_url);
    assert_eq!(identity.workspace_scope_root, subdirectory_path);
    assert!(
        identity.working_copy_root.ends_with("\\wc") || identity.working_copy_root.ends_with("/wc"),
        "working copy root should point at the checked-out fixture, got {}",
        identity.working_copy_root
    );
    assert!(
        !identity.working_copy_root.ends_with("\\src")
            && !identity.working_copy_root.ends_with("/src"),
        "subdirectory open must resolve provider root to the parent working copy root, got {}",
        identity.working_copy_root
    );
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_repository_checkout_file_url_creates_working_copy_and_reports_revision() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    fixture.add_committed_file(&svn, "tracked.txt", "checked out by bridge\n");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let mut auth = UnavailableAuthRequestBroker;
    let checkout = fixture._temp.path.join("bridge-checkout-head");
    let checkout_path = checkout.to_string_lossy().to_string();
    let result = bridge
        .repository_checkout(
            &subversionr_daemon::RepositoryCheckoutRequest {
                url: format!("{}/trunk", fixture.repo_url),
                target_path: checkout_path.clone(),
                revision: "head".to_string(),
                depth: "infinity".to_string(),
                ignore_externals: true,
            },
            &mut auth,
        )
        .expect("native bridge should checkout file URL through libsvn");

    assert_eq!(
        result.working_copy_path,
        checkout_path
            .replace('\\', "/")
            .trim_end_matches('/')
            .to_string()
    );
    assert!(result.revision >= 2);
    assert_eq!(
        fs::read_to_string(checkout.join("tracked.txt"))
            .expect("checked-out file should be readable"),
        "checked out by bridge\n"
    );
    bridge
        .open_working_copy(&checkout_path)
        .expect("native bridge should open the checked-out working copy");

    let revision_one_checkout = fixture._temp.path.join("bridge-checkout-r1-empty");
    let revision_one_path = revision_one_checkout.to_string_lossy().to_string();
    let revision_one = bridge
        .repository_checkout(
            &subversionr_daemon::RepositoryCheckoutRequest {
                url: format!("{}/trunk", fixture.repo_url),
                target_path: revision_one_path,
                revision: "1".to_string(),
                depth: "empty".to_string(),
                ignore_externals: true,
            },
            &mut auth,
        )
        .expect("native bridge should checkout numbered revision through libsvn");
    assert_eq!(revision_one.revision, 1);
    assert!(
        !revision_one_checkout.join("tracked.txt").exists(),
        "r1 empty-depth checkout should not materialize the r2 fixture file"
    );
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_repository_checkout_against_svnserve_routes_credentials_through_broker() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svnadmin = tool_dir.join("svnadmin.exe");
    let svn = tool_dir.join("svn.exe");
    let svnserve = tool_dir.join("svnserve.exe");
    assert!(
        svnserve.is_file(),
        "staged svnserve.exe is required beside the bridge DLL"
    );

    let fixture = SvnserveFixture::create(&svnadmin, &svn, &svnserve);
    let checkout = fixture.temp.path.join("broker-checkout-wc");
    let checkout_path = checkout.to_string_lossy().to_string();
    let expected_working_copy_root = checkout_path
        .replace('\\', "/")
        .trim_end_matches('/')
        .to_string();
    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let mut auth = RecordingAuthBroker::new("alice", "secret");

    let result = bridge
        .repository_checkout(
            &subversionr_daemon::RepositoryCheckoutRequest {
                url: fixture.trunk_url(),
                target_path: checkout_path.clone(),
                revision: "head".to_string(),
                depth: "infinity".to_string(),
                ignore_externals: true,
            },
            &mut auth,
        )
        .expect("native bridge should checkout svnserve URL through the auth broker");

    assert!(result.revision >= 2);
    assert_eq!(result.working_copy_path, expected_working_copy_root);
    assert!(
        !auth.credential_requests.is_empty(),
        "svnserve checkout must prompt through the SubversionR auth broker"
    );
    assert_eq!(auth.credential_requests[0].repository_id, None);
    assert_eq!(
        auth.credential_requests[0].working_copy_root.as_deref(),
        Some(result.working_copy_path.as_str())
    );
    assert_eq!(
        fs::read_to_string(checkout.join("tracked.txt"))
            .expect("authenticated svnserve checkout content should be readable"),
        "served over svnserve\n"
    );
    bridge
        .open_working_copy(&checkout_path)
        .expect("native bridge should open the svnserve checkout working copy");
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_stdio_rpc_opens_working_copy_with_real_bridge() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let fixture =
        WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &tool_dir.join("svn.exe"));
    let wc_path_json =
        serde_json::to_string(&fixture.wc_path()).expect("WC path should serialize as JSON");
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","cacheRoot":"C:/Users/Alice/AppData/Roaming/Code/User/globalStorage/subversionr/cache"}}"#),
        frame(&format!(
            r#"{{"jsonrpc":"2.0","id":2,"method":"repository/open","params":{{"path":{wc_path_json}}}}}"#
        )),
        frame(r#"{"jsonrpc":"2.0","id":3,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let mut output = Vec::new();

    run_json_rpc_stdio(io::Cursor::new(input), &mut output, &bridge)
        .expect("stdio RPC should dispatch through the real bridge");

    let responses = decode_frames(&output).expect("responses should decode");
    assert_eq!(responses.len(), 3);
    assert_eq!(
        responses[0]["result"]["capabilities"]["realLibsvnBridge"],
        true
    );
    assert_eq!(
        responses[1]["result"]["identity"]["repositoryRootUrl"],
        fixture.repo_url
    );
    assert_eq!(
        responses[1]["result"]["identity"]["workspaceScopeRoot"],
        fixture.wc_path()
    );
    assert_eq!(responses[2]["result"]["accepted"], true);
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_stdio_rpc_file_url_lock_operation_run_uses_non_empty_default_username() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    fixture.add_committed_file(&svn, "tracked.txt", "initial\n");
    let locked_path = fixture.wc.join("tracked.txt");
    run_tool(
        &svn,
        [
            "propset".as_ref(),
            "svn:needs-lock".as_ref(),
            "yes".as_ref(),
            locked_path.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    fixture.commit_path(&svn, &locked_path, "add needs-lock metadata");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");
    let repository_id = format!(
        "{}:{}",
        identity.repository_uuid, identity.working_copy_root
    );
    let input = [
        frame(
            &serde_json::json!({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientName": "test",
                    "clientVersion": "0.0.0",
                    "locale": "en",
                    "workspaceTrust": "trusted",
                    "cacheRoot": "C:/Users/Alice/AppData/Roaming/Code/User/globalStorage/subversionr/cache"
                }
            })
            .to_string(),
        ),
        frame(
            &serde_json::json!({
                "jsonrpc": "2.0",
                "id": 2,
                "method": "repository/open",
                "params": { "path": fixture.wc_path() }
            })
            .to_string(),
        ),
        frame(
            &serde_json::json!({
                "jsonrpc": "2.0",
                "id": 3,
                "method": "operation/run",
                "params": {
                    "repositoryId": repository_id,
                    "epoch": 1,
                    "kind": "lock",
                    "options": {
                        "version": 1,
                        "paths": ["tracked.txt"],
                        "comment": "file URL lock RPC default username test",
                        "stealLock": false
                    }
                }
            })
            .to_string(),
        ),
        frame(
            &serde_json::json!({
                "jsonrpc": "2.0",
                "id": 4,
                "method": "status/refresh",
                "params": {
                    "repositoryId": repository_id,
                    "epoch": 1,
                    "targets": [
                        {
                            "path": "tracked.txt",
                            "depth": "empty",
                            "reason": "operationLock"
                        }
                    ]
                }
            })
            .to_string(),
        ),
        frame(
            &serde_json::json!({
                "jsonrpc": "2.0",
                "id": 5,
                "method": "operation/run",
                "params": {
                    "repositoryId": repository_id,
                    "epoch": 1,
                    "kind": "unlock",
                    "options": {
                        "version": 1,
                        "paths": ["tracked.txt"],
                        "breakLock": false
                    }
                }
            })
            .to_string(),
        ),
        frame(r#"{"jsonrpc":"2.0","id":6,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(io::Cursor::new(input), &mut output, &bridge)
        .expect("stdio RPC should dispatch file:// lock through the real bridge");

    let responses = decode_frames(&output).expect("responses should decode");
    assert_eq!(responses.len(), 6);
    assert_eq!(
        responses[0]["result"]["capabilities"]["realLibsvnBridge"],
        true
    );
    assert_eq!(responses[1]["result"]["repositoryId"], repository_id);
    assert!(
        responses[2].get("error").is_none(),
        "operation/run file:// lock should succeed, got {}",
        responses[2]["error"]
    );
    assert_eq!(responses[2]["result"]["kind"], "lock");
    assert_eq!(responses[2]["result"]["touchedPaths"][0], "tracked.txt");
    let upsert = responses[3]["result"]["upsert"]
        .as_array()
        .unwrap_or_else(|| {
            panic!(
                "status/refresh should return upsert entries: {}",
                responses[3]
            )
        })
        .first()
        .expect("locked file should be refreshed");
    assert_eq!(upsert["path"], "tracked.txt");
    assert_eq!(upsert["needsLock"], true);
    assert!(
        upsert["lock"]["owner"]
            .as_str()
            .is_some_and(|owner| !owner.trim().is_empty()),
        "status/refresh should expose a non-empty file:// lock owner"
    );
    assert_eq!(
        upsert["lock"]["comment"],
        "file URL lock RPC default username test"
    );
    assert!(
        responses[4].get("error").is_none(),
        "operation/run file:// unlock should succeed, got {}",
        responses[4]["error"]
    );
    assert_eq!(responses[4]["result"]["kind"], "unlock");
    assert_eq!(responses[5]["result"]["accepted"], true);
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_stdio_rpc_discovers_multiple_working_copy_roots_with_real_bridge() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svnadmin = tool_dir.join("svnadmin.exe");
    let svn = tool_dir.join("svn.exe");
    let first_fixture = WorkingCopyFixture::create(&svnadmin, &svn);
    let second_fixture = WorkingCopyFixture::create(&svnadmin, &svn);
    let discover = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "repository/discover",
        "params": {
            "workspaceRoots": [
                first_fixture.wc_path(),
                second_fixture.wc_path()
            ],
            "discoverNested": false,
            "discoveryDepth": 4,
            "discoveryIgnore": [],
            "ignoredRoots": [],
            "externalsMode": "lazy"
        }
    })
    .to_string();
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","cacheRoot":"C:/Users/Alice/AppData/Roaming/Code/User/globalStorage/subversionr/cache"}}"#),
        frame(&discover),
        frame(r#"{"jsonrpc":"2.0","id":3,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let mut output = Vec::new();

    run_json_rpc_stdio(io::Cursor::new(input), &mut output, &bridge)
        .expect("stdio RPC should dispatch multi-root discovery through the real bridge");

    let responses = decode_frames(&output).expect("responses should decode");
    assert_eq!(responses.len(), 3);
    assert_eq!(
        responses[0]["result"]["capabilities"]["realLibsvnBridge"],
        true
    );
    let candidates = responses[1]["result"]["candidates"]
        .as_array()
        .expect("discovery candidates should be an array");
    assert_eq!(candidates.len(), 2);
    assert_eq!(
        candidates[0]["identity"]["repositoryRootUrl"],
        first_fixture.repo_url
    );
    assert_eq!(
        candidates[1]["identity"]["repositoryRootUrl"],
        second_fixture.repo_url
    );
    assert_ne!(
        candidates[0]["identity"]["repositoryUuid"],
        candidates[1]["identity"]["repositoryUuid"]
    );
    assert_ne!(
        candidates[0]["identity"]["workingCopyRoot"],
        candidates[1]["identity"]["workingCopyRoot"]
    );
    assert_eq!(candidates[0]["isNested"], false);
    assert_eq!(candidates[0]["isExternal"], false);
    assert_eq!(candidates[1]["isNested"], false);
    assert_eq!(candidates[1]["isExternal"], false);
    assert_eq!(responses[2]["result"]["accepted"], true);
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_stdio_rpc_discovers_nested_working_copy_roots_with_real_bridge() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svnadmin = tool_dir.join("svnadmin.exe");
    let svn = tool_dir.join("svn.exe");
    let parent_fixture = WorkingCopyFixture::create(&svnadmin, &svn);
    let nested_fixture = WorkingCopyFixture::create(&svnadmin, &svn);
    let nested_parent = parent_fixture.wc.join("vendor");
    let nested_checkout = nested_parent.join("nested");
    fs::create_dir_all(&nested_parent).expect("nested checkout parent should be created");
    run_tool(
        &svn,
        [
            "checkout".as_ref(),
            format!("{}/trunk", nested_fixture.repo_url).as_ref(),
            nested_checkout.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    let discover = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "repository/discover",
        "params": {
            "workspaceRoots": [parent_fixture.wc_path()],
            "discoverNested": true,
            "discoveryDepth": 4,
            "discoveryIgnore": [],
            "ignoredRoots": [],
            "externalsMode": "lazy"
        }
    })
    .to_string();
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","cacheRoot":"C:/Users/Alice/AppData/Roaming/Code/User/globalStorage/subversionr/cache"}}"#),
        frame(&discover),
        frame(r#"{"jsonrpc":"2.0","id":3,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let mut output = Vec::new();

    run_json_rpc_stdio(io::Cursor::new(input), &mut output, &bridge)
        .expect("stdio RPC should dispatch nested discovery through the real bridge");

    let responses = decode_frames(&output).expect("responses should decode");
    assert_eq!(responses.len(), 3);
    let candidates = responses[1]["result"]["candidates"]
        .as_array()
        .expect("discovery candidates should be an array");
    assert_eq!(candidates.len(), 2);
    assert_eq!(
        candidates[0]["identity"]["repositoryRootUrl"],
        parent_fixture.repo_url
    );
    assert_eq!(
        candidates[1]["identity"]["repositoryRootUrl"],
        nested_fixture.repo_url
    );
    assert_eq!(candidates[0]["isNested"], false);
    assert_eq!(candidates[0]["isExternal"], false);
    assert_eq!(candidates[1]["isNested"], true);
    assert_eq!(candidates[1]["isExternal"], false);
    assert_eq!(
        candidates[1]["parentWorkingCopyRoot"],
        candidates[0]["identity"]["workingCopyRoot"]
    );
    assert_eq!(responses[2]["result"]["accepted"], true);
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_stdio_rpc_discovers_directory_external_with_real_bridge() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svnadmin = tool_dir.join("svnadmin.exe");
    let svn = tool_dir.join("svn.exe");
    let parent_fixture = WorkingCopyFixture::create(&svnadmin, &svn);
    let external_fixture = WorkingCopyFixture::create(&svnadmin, &svn);
    external_fixture.add_committed_file(&svn, "external.txt", "external initial\n");
    run_tool(
        &svn,
        [
            "propset".as_ref(),
            "svn:externals".as_ref(),
            format!("{}/trunk library", external_fixture.repo_url).as_ref(),
            parent_fixture.wc.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    parent_fixture.commit_path(&svn, &parent_fixture.wc, "add directory external");
    run_tool(
        &svn,
        [
            "update".as_ref(),
            parent_fixture.wc.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    let discover = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "repository/discover",
        "params": {
            "workspaceRoots": [parent_fixture.wc_path()],
            "discoverNested": false,
            "discoveryDepth": 0,
            "discoveryIgnore": [],
            "ignoredRoots": [],
            "externalsMode": "lazy"
        }
    })
    .to_string();
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","cacheRoot":"C:/Users/Alice/AppData/Roaming/Code/User/globalStorage/subversionr/cache"}}"#),
        frame(&discover),
        frame(r#"{"jsonrpc":"2.0","id":3,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let mut output = Vec::new();

    run_json_rpc_stdio(io::Cursor::new(input), &mut output, &bridge)
        .expect("stdio RPC should dispatch directory external discovery through the real bridge");

    let responses = decode_frames(&output).expect("responses should decode");
    assert_eq!(responses.len(), 3);
    let candidates = responses[1]["result"]["candidates"]
        .as_array()
        .expect("discovery candidates should be an array");
    assert_eq!(candidates.len(), 2);
    assert_eq!(
        candidates[0]["identity"]["repositoryRootUrl"],
        parent_fixture.repo_url
    );
    assert_eq!(
        candidates[1]["identity"]["repositoryRootUrl"],
        external_fixture.repo_url
    );
    assert_eq!(candidates[0]["isNested"], false);
    assert_eq!(candidates[0]["isExternal"], false);
    assert_eq!(candidates[1]["isNested"], false);
    assert_eq!(candidates[1]["isExternal"], true);
    assert_eq!(
        candidates[1]["parentWorkingCopyRoot"],
        candidates[0]["identity"]["workingCopyRoot"]
    );
    assert_eq!(responses[2]["result"]["accepted"], true);
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_stdio_rpc_parent_status_excludes_nested_working_copy_changes_with_boundaries() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svnadmin = tool_dir.join("svnadmin.exe");
    let svn = tool_dir.join("svn.exe");
    let parent_fixture = WorkingCopyFixture::create(&svnadmin, &svn);
    let nested_fixture = WorkingCopyFixture::create(&svnadmin, &svn);
    parent_fixture.add_committed_file(&svn, "tracked.txt", "parent initial\n");
    nested_fixture.add_committed_file(&svn, "nested.txt", "nested initial\n");

    let nested_parent = parent_fixture.wc.join("vendor");
    let nested_checkout = nested_parent.join("nested");
    fs::create_dir_all(&nested_parent).expect("nested checkout parent should be created");
    run_tool(
        &svn,
        [
            "add".as_ref(),
            nested_parent.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    parent_fixture.commit_path(&svn, &nested_parent, "add nested checkout parent");
    run_tool(
        &svn,
        [
            "checkout".as_ref(),
            format!("{}/trunk", nested_fixture.repo_url).as_ref(),
            nested_checkout.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    parent_fixture.write_file("tracked.txt", "parent modified\n");
    fs::write(nested_checkout.join("nested.txt"), "nested modified\n")
        .expect("nested fixture file should be modified");

    let parent_wc_json =
        serde_json::to_string(&parent_fixture.wc_path()).expect("parent WC path should serialize");
    let nested_wc_json = serde_json::to_string(&nested_checkout.to_string_lossy().to_string())
        .expect("nested WC path should serialize");
    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let parent_identity = bridge
        .open_working_copy(&parent_fixture.wc_path())
        .expect("native bridge should open parent working copy");
    let repository_id = format!(
        "{}:{}",
        parent_identity.repository_uuid, parent_identity.working_copy_root
    );
    let repository_id_json =
        serde_json::to_string(&repository_id).expect("repository id should serialize");
    let open = format!(
        r#"{{"jsonrpc":"2.0","id":2,"method":"repository/open","params":{{"path":{parent_wc_json},"boundaryRoots":[{nested_wc_json}]}}}}"#
    );
    let snapshot = format!(
        r#"{{"jsonrpc":"2.0","id":3,"method":"status/getSnapshot","params":{{"repositoryId":{repository_id_json},"epoch":1}}}}"#
    );
    let input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","cacheRoot":"C:/Users/Alice/AppData/Roaming/Code/User/globalStorage/subversionr/cache"}}"#),
        frame(&open),
        frame(&snapshot),
        frame(r#"{"jsonrpc":"2.0","id":4,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let mut output = Vec::new();

    run_json_rpc_stdio(io::Cursor::new(input), &mut output, &bridge)
        .expect("stdio RPC should dispatch bounded parent status through the real bridge");

    let responses = decode_frames(&output).expect("responses should decode");
    assert_eq!(responses.len(), 4);
    assert_eq!(
        responses[1]["result"]["identity"]["repositoryRootUrl"],
        parent_fixture.repo_url
    );
    let entries = responses[2]["result"]["localEntries"]
        .as_array()
        .expect("parent status entries should be an array");
    let paths = entries
        .iter()
        .map(|entry| {
            entry["path"]
                .as_str()
                .expect("status entry path should be a string")
                .replace('\\', "/")
        })
        .collect::<Vec<_>>();
    assert_eq!(paths, vec!["tracked.txt"]);
    assert_eq!(responses[2]["result"]["summary"]["localChanges"], 1);
    assert_eq!(responses[2]["result"]["summary"]["unversioned"], 0);
    assert_eq!(responses[2]["result"]["completeness"], "complete");
    assert_eq!(responses[3]["result"]["accepted"], true);
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_stdio_rpc_discovers_and_excludes_file_external_boundaries_with_real_bridge() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svnadmin = tool_dir.join("svnadmin.exe");
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&svnadmin, &svn);
    fixture.add_committed_file(&svn, "tracked.txt", "parent initial\n");
    fixture.add_committed_file(&svn, "external-source.txt", "external initial\n");

    let external_parent = fixture.wc.join("externals");
    fs::create_dir_all(&external_parent).expect("file external parent should be created");
    run_tool(
        &svn,
        [
            "add".as_ref(),
            external_parent.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    fixture.commit_path(&svn, &external_parent, "add file external parent directory");
    run_tool(
        &svn,
        [
            "propset".as_ref(),
            "svn:externals".as_ref(),
            "^/trunk/external-source.txt pinned.txt".as_ref(),
            external_parent.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    fixture.commit_path(&svn, &external_parent, "add file external definition");
    run_tool(
        &svn,
        [
            "update".as_ref(),
            fixture.wc.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );

    fixture.write_file("tracked.txt", "parent modified\n");
    let file_external = external_parent.join("pinned.txt");
    fs::write(&file_external, "file external modified\n")
        .expect("file external fixture should be modified");

    let parent_wc_json =
        serde_json::to_string(&fixture.wc_path()).expect("parent WC path should serialize");
    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let parent_identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open parent working copy");
    let repository_id = format!(
        "{}:{}",
        parent_identity.repository_uuid, parent_identity.working_copy_root
    );
    let repository_id_json =
        serde_json::to_string(&repository_id).expect("repository id should serialize");
    let discover = format!(
        r#"{{"jsonrpc":"2.0","id":2,"method":"repository/discover","params":{{"workspaceRoots":[{parent_wc_json}],"discoverNested":false,"discoveryDepth":0,"discoveryIgnore":[],"ignoredRoots":[],"externalsMode":"lazy"}}}}"#
    );
    let discovery_input = [
        frame(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","cacheRoot":"C:/Users/Alice/AppData/Roaming/Code/User/globalStorage/subversionr/cache"}}"#),
        frame(&discover),
        frame(r#"{"jsonrpc":"2.0","id":3,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let mut discovery_output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(discovery_input),
        &mut discovery_output,
        &bridge,
    )
    .expect("stdio RPC should dispatch file external discovery through the real bridge");

    let discovery_responses = decode_frames(&discovery_output).expect("responses should decode");
    assert_eq!(discovery_responses.len(), 3);
    let discovered_boundaries = discovery_responses[1]["result"]["fileExternalBoundaries"]
        .as_array()
        .expect("file external boundaries should be an array");
    assert_eq!(discovered_boundaries.len(), 1);
    let discovered_file_external_boundary = discovered_boundaries[0]
        .as_str()
        .expect("file external boundary should be a string")
        .to_string();
    assert_eq!(
        discovered_file_external_boundary.replace('\\', "/"),
        file_external.to_string_lossy().replace('\\', "/")
    );
    let discovered_file_external_json = serde_json::to_string(&discovered_file_external_boundary)
        .expect("discovered file external path should serialize");

    let open = format!(
        r#"{{"jsonrpc":"2.0","id":4,"method":"repository/open","params":{{"path":{parent_wc_json},"boundaryRoots":[{discovered_file_external_json}]}}}}"#
    );
    let snapshot = format!(
        r#"{{"jsonrpc":"2.0","id":5,"method":"status/getSnapshot","params":{{"repositoryId":{repository_id_json},"epoch":1}}}}"#
    );
    let bounded_status_input = [
        frame(r#"{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"clientName":"test","clientVersion":"0.0.0","locale":"en","workspaceTrust":"trusted","cacheRoot":"C:/Users/Alice/AppData/Roaming/Code/User/globalStorage/subversionr/cache"}}"#),
        frame(&open),
        frame(&snapshot),
        frame(r#"{"jsonrpc":"2.0","id":6,"method":"shutdown","params":{}}"#),
    ]
    .concat();
    let mut bounded_status_output = Vec::new();

    run_json_rpc_stdio(
        io::Cursor::new(bounded_status_input),
        &mut bounded_status_output,
        &bridge,
    )
    .expect("stdio RPC should dispatch file external boundary status through the real bridge");

    let responses = decode_frames(&bounded_status_output).expect("responses should decode");
    assert_eq!(responses.len(), 4);
    let entries = responses[2]["result"]["localEntries"]
        .as_array()
        .expect("parent status entries should be an array");
    let paths = entries
        .iter()
        .map(|entry| {
            entry["path"]
                .as_str()
                .expect("status entry path should be a string")
                .replace('\\', "/")
        })
        .collect::<Vec<_>>();
    assert_eq!(paths, vec!["tracked.txt"]);
    assert_eq!(responses[2]["result"]["summary"]["localChanges"], 1);
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_svnserve_fixture_requires_credentials_and_accepts_explicit_credentials() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svnadmin = tool_dir.join("svnadmin.exe");
    let svn = tool_dir.join("svn.exe");
    let svnserve = tool_dir.join("svnserve.exe");
    assert!(
        svnserve.is_file(),
        "staged svnserve.exe is required beside the bridge DLL"
    );

    let fixture = SvnserveFixture::create(&svnadmin, &svn, &svnserve);
    let checkout_url = fixture.trunk_url();
    let unauthenticated_checkout = fixture.temp.path.join("unauthenticated-wc");
    let authenticated_checkout = fixture.temp.path.join("authenticated-wc");
    let unauthenticated_config = fixture.temp.path.join("unauthenticated-config");
    let authenticated_config = fixture.temp.path.join("authenticated-config");

    let unauthenticated = run_tool_output(
        &svn,
        [
            "checkout".as_ref(),
            checkout_url.as_ref(),
            unauthenticated_checkout.as_os_str(),
            "--non-interactive".as_ref(),
            "--config-dir".as_ref(),
            unauthenticated_config.as_os_str(),
        ],
    );
    assert!(
        !unauthenticated.status.success(),
        "svnserve fixture should reject unauthenticated checkout\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&unauthenticated.stdout),
        String::from_utf8_lossy(&unauthenticated.stderr)
    );

    run_tool(
        &svn,
        [
            "checkout".as_ref(),
            checkout_url.as_ref(),
            authenticated_checkout.as_os_str(),
            "--username".as_ref(),
            "alice".as_ref(),
            "--password".as_ref(),
            "secret".as_ref(),
            "--no-auth-cache".as_ref(),
            "--non-interactive".as_ref(),
            "--config-dir".as_ref(),
            authenticated_config.as_os_str(),
        ],
    );

    assert_eq!(
        fs::read_to_string(authenticated_checkout.join("tracked.txt"))
            .expect("authenticated svnserve checkout should retrieve the committed fixture file"),
        "served over svnserve\n"
    );
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_update_against_svnserve_routes_credentials_through_broker() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svnadmin = tool_dir.join("svnadmin.exe");
    let svn = tool_dir.join("svn.exe");
    let svnserve = tool_dir.join("svnserve.exe");
    assert!(
        svnserve.is_file(),
        "staged svnserve.exe is required beside the bridge DLL"
    );

    let fixture = SvnserveFixture::create(&svnadmin, &svn, &svnserve);
    let checkout_url = fixture.trunk_url();
    let checkout = fixture.temp.path.join("broker-update-wc");
    let checkout_config = fixture.temp.path.join("broker-update-checkout-config");

    run_tool(
        &svn,
        [
            "checkout".as_ref(),
            checkout_url.as_ref(),
            checkout.as_os_str(),
            "--username".as_ref(),
            "alice".as_ref(),
            "--password".as_ref(),
            "secret".as_ref(),
            "--no-auth-cache".as_ref(),
            "--non-interactive".as_ref(),
            "--config-dir".as_ref(),
            checkout_config.as_os_str(),
        ],
    );
    assert_eq!(
        fs::read_to_string(checkout.join("tracked.txt"))
            .expect("authenticated svnserve checkout should retrieve fixture content"),
        "served over svnserve\n"
    );

    fixture.commit_seed_file(
        &svn,
        "tracked.txt",
        "updated through svnserve broker\n",
        "remote edit for brokered update",
    );

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(
            checkout
                .to_str()
                .expect("svnserve checkout path should be valid UTF-8"),
        )
        .expect("native bridge should open the svnserve working copy");
    let expected_repository_id = format!(
        "{}:{}",
        identity.repository_uuid, identity.working_copy_root
    );
    let mut auth = RecordingAuthBroker::new("alice", "secret");

    let result = bridge
        .operation_update(
            &identity,
            &subversionr_daemon::UpdateOperationRequest {
                path: ".".to_string(),
                revision: "head".to_string(),
                depth: "workingCopy".to_string(),
                depth_is_sticky: false,
                ignore_externals: true,
            },
            &mut auth,
        )
        .expect("native bridge should update through the auth broker");

    assert!(
        !auth.credential_requests.is_empty(),
        "svnserve update must prompt through the SubversionR auth broker"
    );
    assert_eq!(
        auth.credential_requests[0].repository_id.as_deref(),
        Some(expected_repository_id.as_str())
    );
    assert_eq!(
        auth.credential_requests[0].working_copy_root.as_deref(),
        Some(identity.working_copy_root.as_str())
    );
    assert!(result.revision >= 3);
    assert_eq!(result.result.touched_paths, vec!["."]);
    assert_eq!(
        fs::read_to_string(checkout.join("tracked.txt"))
            .expect("updated svnserve checkout content should be readable"),
        "updated through svnserve broker\n"
    );
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_remote_status_against_svnserve_routes_credentials_through_broker() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svnadmin = tool_dir.join("svnadmin.exe");
    let svn = tool_dir.join("svn.exe");
    let svnserve = tool_dir.join("svnserve.exe");
    let fixture = SvnserveFixture::create(&svnadmin, &svn, &svnserve);
    let checkout = fixture.temp.path.join("broker-remote-status-wc");
    let checkout_config = fixture.temp.path.join("broker-remote-status-config");
    let checkout_url = fixture.trunk_url();
    run_tool(
        &svn,
        [
            "checkout".as_ref(),
            checkout_url.as_ref(),
            checkout.as_os_str(),
            "--username".as_ref(),
            "alice".as_ref(),
            "--password".as_ref(),
            "secret".as_ref(),
            "--no-auth-cache".as_ref(),
            "--non-interactive".as_ref(),
            "--config-dir".as_ref(),
            checkout_config.as_os_str(),
        ],
    );
    fixture.commit_seed_file(
        &svn,
        "tracked.txt",
        "remote status through svnserve broker\n",
        "remote edit for brokered status",
    );

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(
            checkout
                .to_str()
                .expect("svnserve checkout path should be valid UTF-8"),
        )
        .expect("native bridge should open the svnserve working copy");
    let expected_repository_id = format!(
        "{}:{}",
        identity.repository_uuid, identity.working_copy_root
    );
    let mut auth = RecordingAuthBroker::new("alice", "secret");

    let snapshot = bridge
        .status_remote_check_with_cancellation(
            &identity,
            73,
            &mut auth,
            &subversionr_daemon::NeverCancelled,
        )
        .expect("native bridge should check remote status through the auth broker");

    assert!(!auth.credential_requests.is_empty());
    assert_eq!(
        auth.credential_requests[0].repository_id.as_deref(),
        Some(expected_repository_id.as_str())
    );
    assert_eq!(
        auth.credential_requests[0].working_copy_root.as_deref(),
        Some(identity.working_copy_root.as_str())
    );
    assert!(
        snapshot
            .remote_entries
            .iter()
            .any(|entry| { entry.path == "tracked.txt" && entry.remote_status == "modified" })
    );
    assert_eq!(snapshot.source, "libsvn-remote");

    let mut wrong_auth = RecordingAuthBroker::new("alice", "wrong-secret");
    let failure = bridge
        .status_remote_check_with_cancellation(
            &identity,
            74,
            &mut wrong_auth,
            &subversionr_daemon::NeverCancelled,
        )
        .expect_err("svnserve must reject incorrect remote-status credentials");
    assert_eq!(failure.code(), "SVN_REMOTE_STATUS_AUTH_FAILED");
    assert!(!wrong_auth.credential_requests.is_empty());
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_head_content_against_svnserve_routes_credentials_through_broker() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svnadmin = tool_dir.join("svnadmin.exe");
    let svn = tool_dir.join("svn.exe");
    let svnserve = tool_dir.join("svnserve.exe");
    assert!(
        svnserve.is_file(),
        "staged svnserve.exe is required beside the bridge DLL"
    );

    let fixture = SvnserveFixture::create(&svnadmin, &svn, &svnserve);
    let checkout_url = fixture.trunk_url();
    let checkout = fixture.temp.path.join("broker-head-content-wc");
    let checkout_config = fixture
        .temp
        .path
        .join("broker-head-content-checkout-config");

    run_tool(
        &svn,
        [
            "checkout".as_ref(),
            checkout_url.as_ref(),
            checkout.as_os_str(),
            "--username".as_ref(),
            "alice".as_ref(),
            "--password".as_ref(),
            "secret".as_ref(),
            "--no-auth-cache".as_ref(),
            "--non-interactive".as_ref(),
            "--config-dir".as_ref(),
            checkout_config.as_os_str(),
        ],
    );
    fixture.commit_seed_file(
        &svn,
        "tracked.txt",
        "head content through broker\n",
        "remote edit for brokered head content",
    );

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(
            checkout
                .to_str()
                .expect("svnserve checkout path should be valid UTF-8"),
        )
        .expect("native bridge should open the svnserve working copy");
    let expected_repository_id = format!(
        "{}:{}",
        identity.repository_uuid, identity.working_copy_root
    );
    let mut auth = RecordingAuthBroker::new("alice", "secret");

    let content = bridge
        .content_get(&identity, "tracked.txt", "head", &mut auth)
        .expect("native bridge should retrieve HEAD content through the auth broker");

    assert!(
        !auth.credential_requests.is_empty(),
        "svnserve HEAD content must prompt through the SubversionR auth broker"
    );
    assert_eq!(
        auth.credential_requests[0].repository_id.as_deref(),
        Some(expected_repository_id.as_str())
    );
    assert_eq!(
        auth.credential_requests[0].working_copy_root.as_deref(),
        Some(identity.working_copy_root.as_str())
    );
    assert_eq!(content.data, b"head content through broker\n");
    assert_eq!(content.source, "libsvn-head");
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_history_log_against_svnserve_routes_credentials_through_broker() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svnadmin = tool_dir.join("svnadmin.exe");
    let svn = tool_dir.join("svn.exe");
    let svnserve = tool_dir.join("svnserve.exe");
    assert!(
        svnserve.is_file(),
        "staged svnserve.exe is required beside the bridge DLL"
    );

    let fixture = SvnserveFixture::create(&svnadmin, &svn, &svnserve);
    let checkout_url = fixture.trunk_url();
    let checkout = fixture.temp.path.join("broker-history-log-wc");
    let checkout_config = fixture.temp.path.join("broker-history-log-config");

    run_tool(
        &svn,
        [
            "checkout".as_ref(),
            checkout_url.as_ref(),
            checkout.as_os_str(),
            "--username".as_ref(),
            "alice".as_ref(),
            "--password".as_ref(),
            "secret".as_ref(),
            "--no-auth-cache".as_ref(),
            "--non-interactive".as_ref(),
            "--config-dir".as_ref(),
            checkout_config.as_os_str(),
        ],
    );
    fixture.commit_seed_file(
        &svn,
        "tracked.txt",
        "history log through broker\n",
        "remote edit for brokered history log",
    );

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(
            checkout
                .to_str()
                .expect("svnserve checkout path should be valid UTF-8"),
        )
        .expect("native bridge should open the svnserve working copy");
    let expected_repository_id = format!(
        "{}:{}",
        identity.repository_uuid, identity.working_copy_root
    );
    let mut auth = RecordingAuthBroker::new("alice", "secret");

    let log = bridge
        .history_log(
            &identity,
            &HistoryLogRequest {
                path: "tracked.txt".to_string(),
                start_revision: "head".to_string(),
                end_revision: "r0".to_string(),
                limit: 10,
                discover_changed_paths: true,
                strict_node_history: true,
                include_merged_revisions: false,
            },
            &mut auth,
        )
        .expect("native bridge should retrieve history log through the auth broker");

    assert!(
        !auth.credential_requests.is_empty(),
        "svnserve history log must prompt through the SubversionR auth broker"
    );
    assert_eq!(
        auth.credential_requests[0].repository_id.as_deref(),
        Some(expected_repository_id.as_str())
    );
    assert_eq!(
        auth.credential_requests[0].working_copy_root.as_deref(),
        Some(identity.working_copy_root.as_str())
    );
    assert!(
        log.entries
            .iter()
            .any(|entry| entry.message.as_deref() == Some("remote edit for brokered history log")),
        "history log should include the remote svnserve edit"
    );
    assert_eq!(log.source, "libsvn-log");
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_history_blame_against_svnserve_routes_credentials_through_broker() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svnadmin = tool_dir.join("svnadmin.exe");
    let svn = tool_dir.join("svn.exe");
    let svnserve = tool_dir.join("svnserve.exe");
    assert!(
        svnserve.is_file(),
        "staged svnserve.exe is required beside the bridge DLL"
    );

    let fixture = SvnserveFixture::create(&svnadmin, &svn, &svnserve);
    let checkout_url = fixture.trunk_url();
    let checkout = fixture.temp.path.join("broker-history-blame-wc");
    let checkout_config = fixture.temp.path.join("broker-history-blame-config");

    run_tool(
        &svn,
        [
            "checkout".as_ref(),
            checkout_url.as_ref(),
            checkout.as_os_str(),
            "--username".as_ref(),
            "alice".as_ref(),
            "--password".as_ref(),
            "secret".as_ref(),
            "--no-auth-cache".as_ref(),
            "--non-interactive".as_ref(),
            "--config-dir".as_ref(),
            checkout_config.as_os_str(),
        ],
    );
    fixture.commit_seed_file(
        &svn,
        "tracked.txt",
        "served over svnserve\nblame through broker\n",
        "remote edit for brokered history blame",
    );

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(
            checkout
                .to_str()
                .expect("svnserve checkout path should be valid UTF-8"),
        )
        .expect("native bridge should open the svnserve working copy");
    let expected_repository_id = format!(
        "{}:{}",
        identity.repository_uuid, identity.working_copy_root
    );
    let mut auth = RecordingAuthBroker::new("alice", "secret");

    let blame = bridge
        .history_blame(
            &identity,
            &HistoryBlameRequest {
                path: "tracked.txt".to_string(),
                peg_revision: "head".to_string(),
                start_revision: "r0".to_string(),
                end_revision: "head".to_string(),
                line_start: 1,
                line_limit: 10,
                ignore_whitespace: "none".to_string(),
                ignore_eol_style: false,
                ignore_mime_type: false,
                include_merged_revisions: false,
            },
            &mut auth,
        )
        .expect("native bridge should retrieve history blame through the auth broker");

    assert!(
        !auth.credential_requests.is_empty(),
        "svnserve history blame must prompt through the SubversionR auth broker"
    );
    assert_eq!(
        auth.credential_requests[0].repository_id.as_deref(),
        Some(expected_repository_id.as_str())
    );
    assert_eq!(
        auth.credential_requests[0].working_copy_root.as_deref(),
        Some(identity.working_copy_root.as_str())
    );
    assert!(
        blame.lines.len() >= 2,
        "history blame should include lines from the remote svnserve file"
    );
    assert_eq!(blame.source, "libsvn-blame");
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_commit_against_svnserve_routes_credentials_through_broker() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svnadmin = tool_dir.join("svnadmin.exe");
    let svn = tool_dir.join("svn.exe");
    let svnserve = tool_dir.join("svnserve.exe");
    assert!(
        svnserve.is_file(),
        "staged svnserve.exe is required beside the bridge DLL"
    );

    let fixture = SvnserveFixture::create(&svnadmin, &svn, &svnserve);
    let checkout_url = fixture.trunk_url();
    let checkout = fixture.temp.path.join("broker-commit-wc");
    let checkout_config = fixture.temp.path.join("broker-commit-checkout-config");

    run_tool(
        &svn,
        [
            "checkout".as_ref(),
            checkout_url.as_ref(),
            checkout.as_os_str(),
            "--username".as_ref(),
            "alice".as_ref(),
            "--password".as_ref(),
            "secret".as_ref(),
            "--no-auth-cache".as_ref(),
            "--non-interactive".as_ref(),
            "--config-dir".as_ref(),
            checkout_config.as_os_str(),
        ],
    );
    fs::write(
        checkout.join("tracked.txt"),
        "committed through svnserve broker\n",
    )
    .expect("broker commit fixture file should be edited");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(
            checkout
                .to_str()
                .expect("svnserve checkout path should be valid UTF-8"),
        )
        .expect("native bridge should open the svnserve working copy");
    let expected_repository_id = format!(
        "{}:{}",
        identity.repository_uuid, identity.working_copy_root
    );
    let mut auth = RecordingAuthBroker::new("alice", "secret");

    let result = bridge
        .operation_commit(
            &identity,
            &subversionr_daemon::CommitOperationRequest {
                paths: vec!["tracked.txt".to_string()],
                message: "commit through svnserve auth broker".to_string(),
                depth: "empty".to_string(),
                changelists: Vec::new(),
                keep_locks: false,
                keep_changelists: false,
                commit_as_operations: false,
                include_file_externals: false,
                include_dir_externals: false,
            },
            &mut auth,
        )
        .expect("native bridge should commit through the auth broker");

    assert!(
        !auth.credential_requests.is_empty(),
        "svnserve commit must prompt through the SubversionR auth broker"
    );
    assert_eq!(
        auth.credential_requests[0].repository_id.as_deref(),
        Some(expected_repository_id.as_str())
    );
    assert_eq!(
        auth.credential_requests[0].working_copy_root.as_deref(),
        Some(identity.working_copy_root.as_str())
    );
    assert_eq!(result.result.touched_paths, vec!["tracked.txt"]);
    assert!(result.result.skipped_paths.is_empty());
    assert!(result.revision >= 3);

    let committed_author = raw_revision_author(
        &svn,
        &checkout_url,
        result.revision,
        [
            "--username".as_ref(),
            "alice".as_ref(),
            "--password".as_ref(),
            "secret".as_ref(),
            "--no-auth-cache".as_ref(),
            "--non-interactive".as_ref(),
            "--config-dir".as_ref(),
            checkout_config.as_os_str(),
        ],
    );
    assert_eq!(
        committed_author, "alice",
        "svnserve commits must preserve the authenticated broker identity as svn:author"
    );

    fixture.update_seed_wc(&svn);
    assert_eq!(
        fs::read_to_string(fixture.seed_wc.join("tracked.txt"))
            .expect("seed checkout should read broker commit"),
        "committed through svnserve broker\n"
    );
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_malicious_svn_server_response_history_log_fails_without_auth_prompts_or_crash() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svnadmin = tool_dir.join("svnadmin.exe");
    let svn = tool_dir.join("svn.exe");
    let svnserve = tool_dir.join("svnserve.exe");
    assert!(
        svnserve.is_file(),
        "staged svnserve.exe is required beside the bridge DLL"
    );

    let mut fixture = SvnserveFixture::create(&svnadmin, &svn, &svnserve);
    let checkout_url = fixture.trunk_url();
    let checkout = fixture.temp.path.join("malicious-svn-response-wc");
    let checkout_config = fixture
        .temp
        .path
        .join("malicious-svn-response-checkout-config");
    run_tool(
        &svn,
        [
            "checkout".as_ref(),
            checkout_url.as_ref(),
            checkout.as_os_str(),
            "--username".as_ref(),
            "alice".as_ref(),
            "--password".as_ref(),
            "secret".as_ref(),
            "--no-auth-cache".as_ref(),
            "--non-interactive".as_ref(),
            "--config-dir".as_ref(),
            checkout_config.as_os_str(),
        ],
    );

    let control_bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = control_bridge
        .open_working_copy(
            checkout
                .to_str()
                .expect("malicious svn server-response checkout path should be valid UTF-8"),
        )
        .expect("native bridge should open the svnserve working copy before malicious swap");
    let expected_repository_id = format!(
        "{}:{}",
        identity.repository_uuid, identity.working_copy_root
    );

    let mut control_auth = RecordingAuthBroker::new("alice", "secret");
    let control_log = control_bridge
        .history_log(
            &identity,
            &HistoryLogRequest {
                path: "tracked.txt".to_string(),
                start_revision: "head".to_string(),
                end_revision: "r0".to_string(),
                limit: 10,
                discover_changed_paths: true,
                strict_node_history: true,
                include_merged_revisions: false,
            },
            &mut control_auth,
        )
        .expect("control svnserve history log should pass before malicious server swap");
    assert!(
        control_log
            .entries
            .iter()
            .any(|entry| entry.message.as_deref() == Some("add svnserve fixture file")),
        "control svnserve history log should prove the checkout and bridge are valid"
    );
    assert!(
        !control_auth.credential_requests.is_empty(),
        "control svnserve history log must prompt through the SubversionR auth broker"
    );
    assert_eq!(
        control_auth.credential_requests[0].repository_id.as_deref(),
        Some(expected_repository_id.as_str())
    );
    assert_eq!(
        control_auth.credential_requests[0]
            .working_copy_root
            .as_deref(),
        Some(identity.working_copy_root.as_str())
    );
    assert!(
        control_auth.certificate_requests.is_empty(),
        "plain svn:// control history log must not route certificate prompts"
    );
    drop(control_bridge);

    let repository_uuid = identity.repository_uuid.clone();
    let repository_root_url = identity.repository_root_url.clone();
    let port = fixture.port;
    fixture.stop_server();
    let malicious_fixture =
        MaliciousSvnServerResponseFixture::bind(port, &repository_uuid, &repository_root_url);
    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let mut malicious_auth = RecordingAuthBroker::new("unused", "unused");

    let failure = bridge
        .history_log(
            &identity,
            &HistoryLogRequest {
                path: "tracked.txt".to_string(),
                start_revision: "head".to_string(),
                end_revision: "r0".to_string(),
                limit: 10,
                discover_changed_paths: true,
                strict_node_history: true,
                include_merged_revisions: false,
            },
            &mut malicious_auth,
        )
        .expect_err("malicious svn:// log response should fail as a native history log error");

    assert_eq!(failure.code(), "SVN_HISTORY_LOG_FAILED");
    assert!(
        malicious_auth.credential_requests.is_empty(),
        "malicious svn:// server-response history log must not route credential prompts"
    );
    assert!(
        malicious_auth.certificate_requests.is_empty(),
        "plain svn:// malicious server-response history log must not route certificate prompts"
    );
    let events = malicious_fixture.observed_events();
    assert_malicious_svn_server_response_sequence(&events);
}

#[test]
#[ignore = "requires a verified native bridge DLL, staged ra_serf/OpenSSL, and staged OpenSSL CLI"]
fn native_bridge_remote_probe_https_certificate_failure_routes_through_broker() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let openssl = native_openssl_path();
    let fixture = TlsEndpointFixture::create(&openssl);
    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let mut auth = RecordingAuthBroker::reject_certificates();

    let failure = bridge
        .probe_remote_url_with_auth(&fixture.url(), &mut auth)
        .expect_err("certificate rejection should stop remote URL probing before DAV probing");

    assert_eq!(failure.code(), "SUBVERSIONR_CERTIFICATE_REJECTED");
    assert_eq!(
        auth.certificate_requests.len(),
        1,
        "real libsvn/ra_serf TLS validation must enter the SubversionR certificate broker"
    );
    let request = &auth.certificate_requests[0];
    assert!(request.request_id.starts_with("native-certificate-"));
    assert!(
        request
            .realm
            .contains(&format!("127.0.0.1:{}", fixture.port())),
        "certificate realm should include the TLS endpoint, got {}",
        request.realm
    );
    assert_eq!(request.host, "localhost");
    assert_eq!(request.fingerprint_algorithm, "sha256-der");
    assert_eq!(request.fingerprint.len(), 64);
    assert!(
        request
            .fingerprint
            .chars()
            .all(|character| character.is_ascii_hexdigit())
    );
    assert!(
        request
            .failures
            .iter()
            .any(|failure| failure == "unknownCa"),
        "self-signed fixture certificate should report an unknown CA failure: {:?}",
        request.failures
    );
    assert!(!request.valid_from.trim().is_empty());
    assert!(!request.valid_to.trim().is_empty());
    assert!(
        request
            .issuer
            .as_deref()
            .is_some_and(|issuer| !issuer.trim().is_empty())
    );
    assert_eq!(request.subject, None);
    assert!(request.interactive);
    assert!(request.persistence_allowed);
    assert_eq!(request.origin, "foreground");
    assert_eq!(request.timeout_ms, 120_000);
    assert_eq!(request.repository_id, None);
    assert_eq!(request.working_copy_root, None);
}

#[test]
#[ignore = "requires a verified native bridge DLL built with source-built ra_serf HTTP support"]
fn native_bridge_malicious_dav_xml_history_log_fails_without_auth_prompts_or_crash() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svnadmin = tool_dir.join("svnadmin.exe");
    let svn = tool_dir.join("svn.exe");
    let wc_fixture = WorkingCopyFixture::create(&svnadmin, &svn);
    wc_fixture.add_committed_file(&svn, "tracked.txt", "malicious DAV XML target\n");
    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let initial_identity = bridge
        .open_working_copy(&wc_fixture.wc_path())
        .expect("native bridge should open the fixture working copy before relocation");
    let fixture = MaliciousDavXmlFixture::create(initial_identity.repository_uuid.as_str());
    let malicious_root = fixture.repository_root_url();
    let relocate_output = run_tool_output(
        &svn,
        [
            "relocate".as_ref(),
            wc_fixture.repo_url.as_ref(),
            malicious_root.as_ref(),
            wc_fixture.wc.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    let relocate_methods = fixture.observed_methods();
    assert!(
        relocate_output.status.success(),
        "svn relocate should accept the valid DAV/XML phase before malicious mode\nmethods: {:?}\nstdout:\n{}\nstderr:\n{}",
        relocate_methods,
        String::from_utf8_lossy(&relocate_output.stdout),
        String::from_utf8_lossy(&relocate_output.stderr)
    );
    fixture.enable_malicious_xml();
    let identity = bridge
        .open_working_copy(&wc_fixture.wc_path())
        .expect("native bridge should open the relocated malicious DAV working copy");
    assert_eq!(identity.repository_root_url, malicious_root);
    let mut auth = RecordingAuthBroker::new("unused", "unused");

    let failure = bridge
        .history_log(
            &identity,
            &HistoryLogRequest {
                path: "tracked.txt".to_string(),
                start_revision: "head".to_string(),
                end_revision: "r0".to_string(),
                limit: 10,
                discover_changed_paths: true,
                strict_node_history: true,
                include_merged_revisions: false,
            },
            &mut auth,
        )
        .expect_err("malicious DAV/XML REPORT response should fail as a native history log error");

    assert_eq!(failure.code(), "SVN_HISTORY_LOG_FAILED");
    assert!(
        auth.credential_requests.is_empty(),
        "malicious DAV/XML history log must not route credential prompts"
    );
    assert!(
        auth.certificate_requests.is_empty(),
        "plain HTTP malicious DAV/XML history log must not route certificate prompts"
    );
    let records = fixture.observed_records();
    let methods: Vec<_> = records
        .iter()
        .map(|record| record.method.as_str())
        .collect();
    assert!(
        methods.contains(&"OPTIONS"),
        "malicious DAV/XML history log should observe libsvn/ra_serf OPTIONS negotiation, got {methods:?}"
    );
    assert!(
        records
            .iter()
            .any(|record| record.method == "REPORT" && record.served_malicious_xml),
        "malicious DAV/XML history log should serve malicious XML for a DAV REPORT request after fully reading its request body, got {records:?}"
    );
}

#[test]
#[ignore = "requires a verified native bridge DLL, staged OpenSSL CLI, staged Apache HTTPD/Subversion DAV runtime, and staged Subversion fixture tools"]
fn native_bridge_https_dav_content_and_update_route_certificate_trust_through_broker() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svnadmin = tool_dir.join("svnadmin.exe");
    let svn = tool_dir.join("svn.exe");
    let openssl = native_openssl_path();
    let httpd_stage = native_httpd_dav_stage_path();
    let fixture = HttpdDavFixture::create(&httpd_stage, &openssl, &svnadmin, &svn);
    let checkout = fixture.checkout(&svn, "broker-https-dav-wc");

    fixture.commit_seed_file(
        &svn,
        "tracked.txt",
        "head content through https dav broker\n",
        "remote edit for brokered https dav head content",
    );

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(
            checkout
                .to_str()
                .expect("https DAV checkout path should be valid UTF-8"),
        )
        .expect("native bridge should open the HTTPS DAV working copy");
    let expected_repository_id = format!(
        "{}:{}",
        identity.repository_uuid, identity.working_copy_root
    );
    let mut auth = RecordingAuthBroker::trust_certificates();

    let content = bridge
        .content_get(&identity, "tracked.txt", "head", &mut auth)
        .expect("native bridge should retrieve HTTPS DAV HEAD content through the auth broker");

    assert_eq!(content.data, b"head content through https dav broker\n");
    assert_eq!(content.source, "libsvn-head");
    assert!(
        !auth.certificate_requests.is_empty(),
        "HTTPS DAV HEAD content must prompt through the SubversionR certificate broker"
    );
    assert!(
        auth.credential_requests.is_empty(),
        "anonymous HTTPS DAV fixture must not prompt for credentials"
    );
    let content_certificate_request = &auth.certificate_requests[0];
    assert!(
        content_certificate_request
            .realm
            .contains(&format!("127.0.0.1:{}", fixture.port())),
        "certificate realm should include the HTTPS DAV endpoint, got {}",
        content_certificate_request.realm
    );
    assert_eq!(
        content_certificate_request.repository_id.as_deref(),
        Some(expected_repository_id.as_str())
    );
    assert_eq!(
        content_certificate_request.working_copy_root.as_deref(),
        Some(identity.working_copy_root.as_str())
    );
    assert_eq!(
        content_certificate_request.fingerprint_algorithm,
        "sha256-der"
    );
    assert!(
        content_certificate_request
            .failures
            .iter()
            .any(|failure| failure == "unknownCa"),
        "self-signed HTTPS DAV fixture certificate should report unknownCa: {:?}",
        content_certificate_request.failures
    );

    fixture.commit_seed_file(
        &svn,
        "tracked.txt",
        "updated through https dav broker\n",
        "remote edit for brokered https dav update",
    );

    let previous_certificate_requests = auth.certificate_requests.len();
    let result = bridge
        .operation_update(
            &identity,
            &subversionr_daemon::UpdateOperationRequest {
                path: ".".to_string(),
                revision: "head".to_string(),
                depth: "workingCopy".to_string(),
                depth_is_sticky: false,
                ignore_externals: true,
            },
            &mut auth,
        )
        .expect("native bridge should update through HTTPS DAV certificate broker");

    assert!(
        auth.certificate_requests.len() > previous_certificate_requests,
        "HTTPS DAV update must prompt through the SubversionR certificate broker"
    );
    let update_certificate_request = &auth.certificate_requests[previous_certificate_requests];
    assert!(
        update_certificate_request
            .realm
            .contains(&format!("127.0.0.1:{}", fixture.port())),
        "update certificate realm should include the HTTPS DAV endpoint, got {}",
        update_certificate_request.realm
    );
    assert_eq!(
        update_certificate_request.repository_id.as_deref(),
        Some(expected_repository_id.as_str())
    );
    assert_eq!(
        update_certificate_request.working_copy_root.as_deref(),
        Some(identity.working_copy_root.as_str())
    );
    assert_eq!(
        update_certificate_request.fingerprint_algorithm,
        "sha256-der"
    );
    assert!(
        update_certificate_request
            .failures
            .iter()
            .any(|failure| failure == "unknownCa"),
        "self-signed HTTPS DAV update certificate should report unknownCa: {:?}",
        update_certificate_request.failures
    );
    assert!(
        auth.credential_requests.is_empty(),
        "anonymous HTTPS DAV update must not prompt for credentials"
    );
    assert!(result.revision >= 3);
    assert_eq!(result.result.touched_paths, vec!["."]);
    assert_eq!(
        fs::read_to_string(checkout.join("tracked.txt"))
            .expect("updated HTTPS DAV checkout content should be readable"),
        "updated through https dav broker\n"
    );
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_status_snapshot_reports_local_modified_and_unversioned_paths() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let fixture =
        WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &tool_dir.join("svn.exe"));
    fixture.add_committed_file(&tool_dir.join("svn.exe"), "tracked.txt", "initial\n");
    fixture.write_file("tracked.txt", "modified\n");
    fixture.write_file("scratch.txt", "unversioned\n");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");

    let snapshot = bridge
        .status_snapshot(&identity, 42)
        .expect("native bridge should return a local status snapshot");

    assert_eq!(snapshot.generation, 42);
    assert_eq!(snapshot.completeness, "complete");
    assert_eq!(snapshot.source, "libsvn-local");
    assert!(snapshot.remote_entries.is_empty());
    assert_eq!(snapshot.summary.local_changes, 2);
    assert_eq!(snapshot.summary.remote_changes, 0);
    assert_eq!(snapshot.summary.conflicts, 0);
    assert_eq!(snapshot.summary.unversioned, 1);
    let entries = snapshot
        .local_entries
        .iter()
        .map(|entry| (entry.path.replace('\\', "/"), entry))
        .collect::<BTreeMap<_, _>>();
    let tracked = entries
        .get("tracked.txt")
        .expect("modified tracked file should be reported");
    assert_eq!(tracked.kind, "file");
    assert_eq!(tracked.node_status, "modified");
    assert_eq!(tracked.text_status, "modified");
    assert_eq!(tracked.property_status, "none");
    assert_eq!(tracked.local_status, "modified");
    assert_eq!(tracked.remote_status, "notChecked");
    assert!(tracked.revision > 0);
    assert!(tracked.changed_revision > 0);
    assert!(tracked.changed_date.is_some());
    assert_eq!(tracked.lock, None);
    assert_eq!(tracked.copy, None);
    assert_eq!(tracked.move_, None);
    assert_eq!(tracked.conflict, None);
    assert!(!tracked.switched);
    assert!(!tracked.external);
    assert_eq!(tracked.generation, 42);

    let scratch = entries
        .get("scratch.txt")
        .expect("unversioned file should be reported");
    assert_eq!(scratch.kind, "file");
    assert_eq!(scratch.node_status, "unversioned");
    assert_eq!(scratch.text_status, "none");
    assert_eq!(scratch.property_status, "none");
    assert_eq!(scratch.local_status, "unversioned");
    assert_eq!(scratch.remote_status, "notChecked");
    assert_eq!(scratch.revision, -1);
    assert_eq!(scratch.changed_revision, -1);
    assert_eq!(scratch.changed_author, None);
    assert_eq!(scratch.changed_date, None);
    assert_eq!(scratch.changelist, None);
    assert_eq!(scratch.lock, None);
    assert_eq!(scratch.copy, None);
    assert_eq!(scratch.move_, None);
    assert_eq!(scratch.conflict, None);
    assert!(!scratch.switched);
    assert!(!scratch.external);
    assert_eq!(scratch.generation, 42);
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_remote_status_matches_peer_commit_and_preserves_dual_state_path() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    fixture.add_committed_file(&svn, "tracked.txt", "base\n");
    let peer = fixture.checkout_copy(&svn, "remote-status-peer");

    fs::write(fixture.wc.join("tracked.txt"), "local edit\n")
        .expect("primary working copy should contain a local edit");
    fs::write(peer.join("tracked.txt"), "peer edit\n")
        .expect("peer working copy should contain a remote edit");
    fs::write(peer.join("incoming-only.txt"), "remote addition\n")
        .expect("peer working copy should contain a remote addition");
    run_tool(
        &svn,
        [
            "add".as_ref(),
            peer.join("incoming-only.txt").as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    fixture.commit_path(&svn, &peer, "remote status fixture");

    let oracle = run_tool_output(
        &svn,
        [
            "status".as_ref(),
            "--show-updates".as_ref(),
            "--xml".as_ref(),
            fixture.wc.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    assert!(
        oracle.status.success(),
        "svn status --show-updates oracle should succeed"
    );
    let oracle_xml = String::from_utf8_lossy(&oracle.stdout);
    assert!(oracle_xml.contains("tracked.txt"));
    assert!(oracle_xml.contains("incoming-only.txt"));

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the primary working copy");
    let local = bridge
        .status_snapshot(&identity, 1)
        .expect("local status should succeed without remote access");
    let mut auth = UnavailableAuthRequestBroker;
    let remote = bridge
        .status_remote_check_with_cancellation(
            &identity,
            2,
            &mut auth,
            &subversionr_daemon::NeverCancelled,
        )
        .expect("remote status should succeed against the file repository");

    assert!(
        local
            .local_entries
            .iter()
            .any(|entry| { entry.path == "tracked.txt" && entry.local_status == "modified" })
    );
    assert!(remote.local_entries.is_empty());
    assert!(
        remote
            .remote_entries
            .iter()
            .any(|entry| { entry.path == "tracked.txt" && entry.remote_status == "modified" })
    );
    assert!(remote.remote_entries.iter().any(|entry| {
        entry.path == "incoming-only.txt" && entry.remote_status == "added" && entry.kind == "file"
    }));
    assert_eq!(
        remote.summary.remote_changes,
        2,
        "unexpected remote entries: {:?}",
        remote
            .remote_entries
            .iter()
            .map(|entry| (
                &entry.path,
                &entry.kind,
                &entry.remote_status,
                &entry.text_status,
                &entry.property_status
            ))
            .collect::<Vec<_>>()
    );
    assert_eq!(remote.source, "libsvn-remote");
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_status_snapshot_excludes_ignored_items_by_default() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    run_tool(
        &svn,
        [
            "propset".as_ref(),
            "svn:ignore".as_ref(),
            "ignored.log".as_ref(),
            fixture.wc.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    fixture.commit_path(&svn, &fixture.wc, "add ignored status fixture rule");
    fixture.write_file("ignored.log", "ignored by svn status\n");
    fixture.write_file("scratch.txt", "visible unversioned\n");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");

    let snapshot = bridge
        .status_snapshot(&identity, 46)
        .expect("native bridge should return a default local status snapshot");

    assert_eq!(snapshot.generation, 46);
    assert_eq!(snapshot.completeness, "complete");
    assert_eq!(snapshot.summary.local_changes, 1);
    assert_eq!(snapshot.summary.unversioned, 1);
    let entries = snapshot
        .local_entries
        .iter()
        .map(|entry| (entry.path.replace('\\', "/"), entry))
        .collect::<BTreeMap<_, _>>();
    assert!(
        !entries.contains_key("ignored.log"),
        "default status must not force ignored item discovery"
    );
    assert!(
        snapshot
            .local_entries
            .iter()
            .all(|entry| entry.local_status != "ignored"),
        "default status must not report ignored status entries"
    );
    let scratch = entries
        .get("scratch.txt")
        .expect("non-ignored unversioned file should still be reported");
    assert_eq!(scratch.local_status, "unversioned");
    assert_eq!(scratch.generation, 46);
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_status_snapshot_preserves_sparse_depth_and_excluded_semantics() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    let sparse_dir = fixture.wc.join("sparse-dir");
    let excluded_dir = fixture.wc.join("excluded-dir");
    fs::create_dir_all(sparse_dir.join("deep")).expect("sparse fixture tree should be created");
    fs::create_dir_all(&excluded_dir).expect("excluded fixture tree should be created");
    fs::write(sparse_dir.join("visible.txt"), "visible\n")
        .expect("sparse visible file should be written");
    fs::write(sparse_dir.join("deep").join("inside.txt"), "deep\n")
        .expect("sparse deep file should be written");
    fs::write(excluded_dir.join("inside.txt"), "excluded\n")
        .expect("excluded fixture file should be written");
    run_tool(
        &svn,
        [
            "add".as_ref(),
            sparse_dir.as_os_str(),
            excluded_dir.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    fixture.commit_path(&svn, &fixture.wc, "add sparse working-copy fixture tree");
    run_tool(
        &svn,
        [
            "update".as_ref(),
            "--set-depth".as_ref(),
            "files".as_ref(),
            sparse_dir.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    run_tool(
        &svn,
        [
            "update".as_ref(),
            "--set-depth".as_ref(),
            "exclude".as_ref(),
            excluded_dir.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    assert!(
        !fixture.path_exists("sparse-dir/deep/inside.txt"),
        "files-depth sparse directory must remove deeper descendants from the working copy"
    );
    assert!(
        !fixture.path_exists("excluded-dir/inside.txt"),
        "excluded sparse target must be removed from the working copy"
    );
    assert!(
        !fixture.path_exists("excluded-dir"),
        "excluded sparse directory itself must be removed from the working copy"
    );

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");

    let snapshot = bridge
        .status_snapshot(&identity, 48)
        .expect("native bridge should return sparse working-copy metadata");

    assert_eq!(snapshot.summary.local_changes, 0);
    let entries = snapshot
        .local_entries
        .iter()
        .map(|entry| (entry.path.replace('\\', "/"), entry))
        .collect::<BTreeMap<_, _>>();
    let sparse_dir = entries
        .get("sparse-dir")
        .expect("sparse directory metadata should be reported");
    assert_eq!(sparse_dir.kind, "dir");
    assert_eq!(sparse_dir.local_status, "normal");
    assert_eq!(sparse_dir.node_status, "normal");
    assert_eq!(sparse_dir.depth, "files");
    assert_eq!(sparse_dir.generation, 48);
    assert!(
        !entries.contains_key("sparse-dir/visible.txt"),
        "ordinary present children must not be promoted as metadata-only status entries"
    );
    assert!(
        !entries.contains_key("sparse-dir/deep/inside.txt"),
        "absent descendants below sparse depth must not be reported as local changes"
    );
    assert!(!entries.contains_key("excluded-dir/inside.txt"));
    assert!(
        !entries.contains_key("excluded-dir"),
        "excluded sparse target must stay absent from status projection"
    );
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_status_snapshot_reports_switched_directory_and_branch_history() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    let src_dir = fixture.wc.join("src");
    fs::create_dir_all(&src_dir).expect("trunk source directory should be created");
    fs::write(src_dir.join("main.c"), "trunk\n").expect("trunk source file should be written");
    run_tool(
        &svn,
        [
            "add".as_ref(),
            src_dir.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    fixture.commit_path(&svn, &src_dir, "add trunk src");

    let branches_url = format!("{}/branches", fixture.repo_url);
    let feature_url = format!("{branches_url}/feature-src");
    let trunk_src_url = format!("{}/trunk/src", fixture.repo_url);
    run_tool(
        &svn,
        [
            "mkdir".as_ref(),
            branches_url.as_ref(),
            "-m".as_ref(),
            "create branches".as_ref(),
            "--non-interactive".as_ref(),
        ],
    );
    run_tool(
        &svn,
        [
            "copy".as_ref(),
            trunk_src_url.as_ref(),
            feature_url.as_ref(),
            "-m".as_ref(),
            "branch src".as_ref(),
            "--non-interactive".as_ref(),
        ],
    );

    let branch_wc = fixture._temp.path.join("feature-src-wc");
    run_tool(
        &svn,
        [
            "checkout".as_ref(),
            feature_url.as_ref(),
            branch_wc.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    fs::write(branch_wc.join("main.c"), "feature\n")
        .expect("feature source file should be written");
    fs::write(branch_wc.join("feature-only.c"), "feature only\n")
        .expect("feature-only source file should be written");
    run_tool(
        &svn,
        [
            "add".as_ref(),
            branch_wc.join("feature-only.c").as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    fixture.commit_path(&svn, &branch_wc, "edit feature src");

    run_tool(
        &svn,
        [
            "switch".as_ref(),
            feature_url.as_ref(),
            src_dir.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    assert_eq!(
        fs::read_to_string(src_dir.join("main.c")).expect("switched file should be readable"),
        "feature\n",
        "svn switch fixture should replace trunk contents with branch contents"
    );
    assert!(
        fixture.path_exists("src/feature-only.c"),
        "svn switch fixture should materialize a branch-only child"
    );

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the switched working copy");

    let snapshot = bridge
        .status_snapshot(&identity, 50)
        .expect("native bridge should return switched working-copy metadata");

    assert_eq!(snapshot.summary.local_changes, 0);
    let entries = snapshot
        .local_entries
        .iter()
        .map(|entry| (entry.path.replace('\\', "/"), entry))
        .collect::<BTreeMap<_, _>>();
    let switched_dir = entries
        .get("src")
        .expect("switched directory metadata should be reported");
    assert_eq!(switched_dir.kind, "dir");
    assert_eq!(switched_dir.node_status, "normal");
    assert_eq!(switched_dir.local_status, "normal");
    assert!(switched_dir.switched);
    assert_eq!(switched_dir.depth, "infinity");
    assert_eq!(switched_dir.generation, 50);
    assert!(
        !entries.contains_key("src/main.c"),
        "ordinary clean switched children must not be promoted as metadata-only status entries"
    );
    assert!(
        !entries.contains_key("src/feature-only.c"),
        "ordinary clean branch-only children must not be promoted as metadata-only status entries"
    );

    let mut auth = UnavailableAuthRequestBroker;
    let log = bridge
        .history_log(
            &identity,
            &HistoryLogRequest {
                path: "src/feature-only.c".to_string(),
                start_revision: "head".to_string(),
                end_revision: "r0".to_string(),
                limit: 10,
                discover_changed_paths: true,
                strict_node_history: true,
                include_merged_revisions: false,
            },
            &mut auth,
        )
        .expect("native bridge should query switched branch history");

    assert_eq!(log.source, "libsvn-log");
    assert_eq!(log.entries[0].message.as_deref(), Some("edit feature src"));
    assert!(
        log.entries
            .iter()
            .flat_map(|entry| entry.changed_paths.iter())
            .any(|path| path.path == "/branches/feature-src/feature-only.c" && path.action == "A")
    );
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_targeted_status_scan_reports_property_only_change() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    fixture.add_committed_file(&svn, "tracked.txt", "initial\n");
    run_tool(
        &svn,
        [
            "propset".as_ref(),
            "subversionr:test".as_ref(),
            "enabled".as_ref(),
            fixture.wc.join("tracked.txt").as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");

    let snapshot = bridge
        .status_scan(&identity, "tracked.txt", "empty", 47)
        .expect("native bridge should return a property-only status snapshot");

    assert_eq!(snapshot.summary.local_changes, 1);
    assert_eq!(snapshot.summary.conflicts, 0);
    assert_eq!(snapshot.summary.unversioned, 0);
    let tracked = snapshot
        .local_entries
        .iter()
        .find(|entry| entry.path.replace('\\', "/") == "tracked.txt")
        .expect("property-only change should be reported");
    assert_eq!(tracked.local_status, "modified");
    assert_eq!(tracked.node_status, "modified");
    assert_eq!(tracked.text_status, "normal");
    assert_eq!(tracked.property_status, "modified");
    assert_eq!(tracked.generation, 47);
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_lock_unlock_and_needs_lock_status_use_libsvn() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svnadmin = tool_dir.join("svnadmin.exe");
    let svn = tool_dir.join("svn.exe");
    let svnserve = tool_dir.join("svnserve.exe");
    assert!(
        svnserve.is_file(),
        "staged svnserve.exe is required beside the bridge DLL"
    );
    let fixture = SvnserveFixture::create(&svnadmin, &svn, &svnserve);
    let locked_path = fixture.seed_wc.join("tracked.txt");
    let partial_path = fixture.seed_wc.join("partial-first.txt");
    fs::write(&partial_path, "partial lock fixture\n")
        .expect("partial lock fixture file should be written");
    run_tool(
        &svn,
        [
            "add".as_ref(),
            partial_path.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    run_tool(
        &svn,
        [
            "propset".as_ref(),
            "svn:needs-lock".as_ref(),
            "yes".as_ref(),
            locked_path.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    run_tool(
        &svn,
        [
            "propset".as_ref(),
            "svn:needs-lock".as_ref(),
            "yes".as_ref(),
            partial_path.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    run_tool(
        &svn,
        [
            "commit".as_ref(),
            fixture.seed_wc.as_os_str(),
            "-m".as_ref(),
            "add needs-lock fixtures".as_ref(),
            "--non-interactive".as_ref(),
        ],
    );
    let checkout = fixture.temp.path.join("lock-wc");
    let checkout_config = fixture.temp.path.join("lock-checkout-config");
    let checkout_url = fixture.trunk_url();
    run_tool(
        &svn,
        [
            "checkout".as_ref(),
            checkout_url.as_ref(),
            checkout.as_os_str(),
            "--username".as_ref(),
            "alice".as_ref(),
            "--password".as_ref(),
            "secret".as_ref(),
            "--no-auth-cache".as_ref(),
            "--non-interactive".as_ref(),
            "--config-dir".as_ref(),
            checkout_config.as_os_str(),
        ],
    );

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(
            checkout
                .to_str()
                .expect("svnserve checkout path should be valid UTF-8"),
        )
        .expect("native bridge should open the fixture working copy");
    let mut auth = RecordingAuthBroker::new("alice", "secret");

    let needs_lock_snapshot = bridge
        .status_scan(&identity, "tracked.txt", "empty", 91)
        .expect("native bridge should report needs-lock metadata");
    assert_eq!(needs_lock_snapshot.summary.local_changes, 0);
    let needs_lock_entry = needs_lock_snapshot
        .local_entries
        .first()
        .expect("clean needs-lock file should still be projected");
    assert_eq!(needs_lock_entry.path.replace('\\', "/"), "tracked.txt");
    assert!(needs_lock_entry.needs_lock);
    assert_eq!(needs_lock_entry.lock, None);

    let lock_result = bridge
        .operation_lock(
            &identity,
            &subversionr_daemon::LockOperationRequest {
                paths: vec!["tracked.txt".to_string()],
                comment: Some("native lock test".to_string()),
                steal_lock: false,
            },
            &mut auth,
        )
        .expect("native bridge should lock the file through libsvn");
    assert_eq!(lock_result.touched_paths, vec!["tracked.txt"]);

    let locked_snapshot = bridge
        .status_scan(&identity, "tracked.txt", "empty", 92)
        .expect("native bridge should report lock metadata");
    assert_eq!(locked_snapshot.summary.local_changes, 0);
    let locked_entry = locked_snapshot
        .local_entries
        .first()
        .expect("locked file should remain projected");
    assert!(locked_entry.needs_lock);
    let lock = locked_entry
        .lock
        .as_ref()
        .expect("locked file should include structured lock info");
    assert!(lock.token.as_deref().is_some_and(|token| !token.is_empty()));
    assert_eq!(lock.comment.as_deref(), Some("native lock test"));
    assert!(!lock.is_remote);

    let unlock_result = bridge
        .operation_unlock(
            &identity,
            &subversionr_daemon::UnlockOperationRequest {
                paths: vec!["tracked.txt".to_string()],
                break_lock: false,
            },
            &mut auth,
        )
        .expect("native bridge should unlock the file through libsvn");
    assert_eq!(unlock_result.touched_paths, vec!["tracked.txt"]);

    let unlocked_snapshot = bridge
        .status_scan(&identity, "tracked.txt", "empty", 93)
        .expect("native bridge should retain needs-lock metadata after unlock");
    let unlocked_entry = unlocked_snapshot
        .local_entries
        .first()
        .expect("needs-lock file should remain projected after unlock");
    assert!(unlocked_entry.needs_lock);
    assert_eq!(unlocked_entry.lock, None);

    let contender_checkout = fixture.temp.path.join("lock-contender-wc");
    let contender_config = fixture.temp.path.join("lock-contender-config");
    run_tool(
        &svn,
        [
            "checkout".as_ref(),
            checkout_url.as_ref(),
            contender_checkout.as_os_str(),
            "--username".as_ref(),
            "alice".as_ref(),
            "--password".as_ref(),
            "secret".as_ref(),
            "--no-auth-cache".as_ref(),
            "--non-interactive".as_ref(),
            "--config-dir".as_ref(),
            contender_config.as_os_str(),
        ],
    );
    let contender_path = contender_checkout.join("tracked.txt");
    run_tool(
        &svn,
        [
            "lock".as_ref(),
            contender_path.as_os_str(),
            "-m".as_ref(),
            "competing native lock test".as_ref(),
            "--username".as_ref(),
            "alice".as_ref(),
            "--password".as_ref(),
            "secret".as_ref(),
            "--no-auth-cache".as_ref(),
            "--non-interactive".as_ref(),
            "--config-dir".as_ref(),
            contender_config.as_os_str(),
        ],
    );

    let partial_lock_failure = bridge
        .operation_lock(
            &identity,
            &subversionr_daemon::LockOperationRequest {
                paths: vec!["partial-first.txt".to_string(), "tracked.txt".to_string()],
                comment: Some("partial native lock test".to_string()),
                steal_lock: false,
            },
            &mut auth,
        )
        .expect_err("a partial per-path libsvn lock failure must fail the bridge operation");
    assert_eq!(partial_lock_failure.code(), "SVN_OPERATION_LOCK_FAILED");
    assert_eq!(
        partial_lock_failure.safe_args()["mayHaveMutated"].as_bool(),
        Some(true),
        "a real per-path failure after a successful lock must expose partial mutation"
    );
    assert!(
        partial_lock_failure
            .diagnostics()
            .is_some_and(|diagnostics| !diagnostics.svn.entries.is_empty()),
        "the partial lock error must retain safe libsvn diagnostics"
    );
    let partially_locked_snapshot = bridge
        .status_scan(&identity, "partial-first.txt", "empty", 94)
        .expect("the successful target from a partial lock must remain inspectable");
    assert!(
        partially_locked_snapshot
            .local_entries
            .first()
            .and_then(|entry| entry.lock.as_ref())
            .is_some_and(|lock| !lock.is_remote),
        "the first target must remain locally locked when the second target fails"
    );

    let unlock_failure_after_partial_lock = bridge
        .operation_unlock(
            &identity,
            &subversionr_daemon::UnlockOperationRequest {
                paths: vec!["partial-first.txt".to_string(), "tracked.txt".to_string()],
                break_lock: false,
            },
            &mut auth,
        )
        .expect_err("a per-path libsvn unlock failure must fail the bridge operation");
    assert_eq!(
        unlock_failure_after_partial_lock.code(),
        "SVN_OPERATION_UNLOCK_FAILED"
    );
    assert_eq!(
        unlock_failure_after_partial_lock.safe_args()["mayHaveMutated"].as_bool(),
        Some(false),
        "a failed unlock with no successful notification must not claim mutation"
    );
    assert!(
        unlock_failure_after_partial_lock
            .diagnostics()
            .is_some_and(|diagnostics| !diagnostics.svn.entries.is_empty()),
        "the unlock error must retain safe libsvn diagnostics"
    );
    let failed_unlock_snapshot = bridge
        .status_scan(&identity, "partial-first.txt", "empty", 95)
        .expect("the failed unlock target must remain inspectable");
    assert!(
        failed_unlock_snapshot
            .local_entries
            .first()
            .and_then(|entry| entry.lock.as_ref())
            .is_some(),
        "a batch with no successful unlock notification must not be treated as mutated"
    );

    run_tool(
        &svn,
        [
            "unlock".as_ref(),
            contender_path.as_os_str(),
            "--username".as_ref(),
            "alice".as_ref(),
            "--password".as_ref(),
            "secret".as_ref(),
            "--no-auth-cache".as_ref(),
            "--non-interactive".as_ref(),
            "--config-dir".as_ref(),
            contender_config.as_os_str(),
        ],
    );
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_file_url_lock_uses_non_empty_default_username() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    fixture.add_committed_file(&svn, "tracked.txt", "initial\n");
    let locked_path = fixture.wc.join("tracked.txt");
    run_tool(
        &svn,
        [
            "propset".as_ref(),
            "svn:needs-lock".as_ref(),
            "yes".as_ref(),
            locked_path.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    fixture.commit_path(&svn, &locked_path, "add needs-lock metadata");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");
    let mut auth = UnavailableAuthRequestBroker;

    let lock_result = bridge
        .operation_lock(
            &identity,
            &subversionr_daemon::LockOperationRequest {
                paths: vec!["tracked.txt".to_string()],
                comment: Some("file URL lock default username test".to_string()),
                steal_lock: false,
            },
            &mut auth,
        )
        .expect("native bridge should lock file:// working copies through libsvn");
    assert_eq!(lock_result.touched_paths, vec!["tracked.txt"]);

    let locked_snapshot = bridge
        .status_scan(&identity, "tracked.txt", "empty", 94)
        .expect("native bridge should report file:// lock metadata");
    let locked_entry = locked_snapshot
        .local_entries
        .first()
        .expect("locked file should remain projected");
    assert!(locked_entry.needs_lock);
    let lock = locked_entry
        .lock
        .as_ref()
        .expect("locked file should include structured lock info");
    assert!(
        lock.owner
            .as_deref()
            .is_some_and(|owner| !owner.trim().is_empty())
    );
    assert_eq!(
        lock.comment.as_deref(),
        Some("file URL lock default username test")
    );

    let unlock_result = bridge
        .operation_unlock(
            &identity,
            &subversionr_daemon::UnlockOperationRequest {
                paths: vec!["tracked.txt".to_string()],
                break_lock: false,
            },
            &mut auth,
        )
        .expect("native bridge should unlock file:// working copies through libsvn");
    assert_eq!(unlock_result.touched_paths, vec!["tracked.txt"]);
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_targeted_empty_scan_reports_only_the_requested_file() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let fixture =
        WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &tool_dir.join("svn.exe"));
    fixture.add_committed_file(&tool_dir.join("svn.exe"), "tracked.txt", "initial\n");
    fixture.write_file("tracked.txt", "modified\n");
    fixture.write_file("scratch.txt", "unversioned\n");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");

    let snapshot = bridge
        .status_scan(&identity, "tracked.txt", "empty", 43)
        .expect("native bridge should return a targeted status scan");

    assert_eq!(snapshot.generation, 43);
    assert_eq!(snapshot.completeness, "partial");
    assert!(snapshot.remote_entries.is_empty());
    let entries = snapshot
        .local_entries
        .iter()
        .map(|entry| (entry.path.replace('\\', "/"), entry))
        .collect::<BTreeMap<_, _>>();
    assert!(entries.contains_key("tracked.txt"));
    assert!(!entries.contains_key("scratch.txt"));
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_status_scan_honors_libsvn_cancellation_token() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let fixture =
        WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &tool_dir.join("svn.exe"));
    fixture.add_committed_file(&tool_dir.join("svn.exe"), "tracked.txt", "initial\n");
    fixture.write_file("tracked.txt", "modified\n");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");
    let cancellation = CancelOnFirstCheck::default();

    let failure = bridge
        .status_scan_with_cancellation(&identity, "tracked.txt", "empty", 44, &cancellation)
        .expect_err("native status scan should honor libsvn cancellation");

    assert_eq!(failure.code(), "SVN_STATUS_CANCELLED");
    assert!(
        cancellation.check_count() > 0,
        "libsvn should invoke the bridge cancellation callback"
    );
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_remote_status_honors_libsvn_cancellation_token() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let fixture =
        WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &tool_dir.join("svn.exe"));
    fixture.add_committed_file(&tool_dir.join("svn.exe"), "tracked.txt", "initial\n");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");
    let cancellation = CancelOnFirstCheck::default();
    let mut auth = UnavailableAuthRequestBroker;

    let failure = bridge
        .status_remote_check_with_cancellation(&identity, 45, &mut auth, &cancellation)
        .expect_err("native remote status should honor libsvn cancellation");

    assert_eq!(failure.code(), "SVN_REMOTE_STATUS_CANCELLED");
    assert!(cancellation.check_count() > 0);
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_status_scan_cancels_during_large_status_stream() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let fixture =
        WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &tool_dir.join("svn.exe"));
    fixture.add_committed_file(&tool_dir.join("svn.exe"), "tracked.txt", "initial\n");
    for index in 0..128 {
        fixture.write_file(&format!("scratch-{index:03}.txt"), "unversioned\n");
    }

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");
    let cancellation = CancelAfterChecks::new(2);

    let failure = bridge
        .status_snapshot_with_cancellation(&identity, 45, &cancellation)
        .expect_err("native status stream should stop when cancellation flips during traversal");

    assert_eq!(failure.code(), "SVN_STATUS_CANCELLED");
    assert!(
        cancellation.check_count() >= 2,
        "status traversal should keep checking cancellation while streaming entries"
    );
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_update_operation_honors_libsvn_cancellation_token() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    fixture.add_committed_file(&svn, "tracked.txt", "initial\n");
    let producer = fixture.checkout_copy(&svn, "producer");
    fixture.write_file_in(&producer, "tracked.txt", "remote\n");
    fixture.commit_path(&svn, &producer.join("tracked.txt"), "remote update fixture");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");
    let cancellation = CancelOnFirstCheck::default();
    let mut auth = UnavailableAuthRequestBroker;

    let failure = bridge
        .operation_update_with_cancellation(
            &identity,
            &subversionr_daemon::UpdateOperationRequest {
                path: ".".to_string(),
                revision: "head".to_string(),
                depth: "workingCopy".to_string(),
                depth_is_sticky: false,
                ignore_externals: true,
            },
            &mut auth,
            &cancellation,
        )
        .expect_err("native update should honor libsvn cancellation");

    assert_eq!(failure.code(), "SVN_OPERATION_CANCELLED");
    assert!(
        cancellation.check_count() > 0,
        "libsvn update should invoke the bridge cancellation callback"
    );
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_content_get_returns_base_text_not_modified_working_file() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let fixture =
        WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &tool_dir.join("svn.exe"));
    fixture.add_committed_file(&tool_dir.join("svn.exe"), "tracked.txt", "initial\n");
    fixture.write_file("tracked.txt", "modified\n");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");
    let mut auth = UnavailableAuthRequestBroker;

    let content = bridge
        .content_get(&identity, "tracked.txt", "base", &mut auth)
        .expect("native bridge should return BASE file content");

    assert_eq!(content.data, b"initial\n");
    assert_eq!(content.mime_type, None);
    assert!(!content.is_binary);
    assert_eq!(content.source, "libsvn-base");
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_content_get_reports_base_mime_type_and_binary_flag() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let fixture =
        WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &tool_dir.join("svn.exe"));
    fixture.add_committed_file_with_mime_type(
        &tool_dir.join("svn.exe"),
        "binary.dat",
        "binary\n",
        "application/octet-stream",
    );

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");
    let mut auth = UnavailableAuthRequestBroker;

    let content = bridge
        .content_get(&identity, "binary.dat", "base", &mut auth)
        .expect("native bridge should return BASE file content metadata");

    assert_eq!(content.data, b"binary\n");
    assert_eq!(
        content.mime_type.as_deref(),
        Some("application/octet-stream")
    );
    assert!(content.is_binary);
    assert_eq!(content.source, "libsvn-base");
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_content_get_returns_head_and_explicit_revision_text() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    fixture.add_committed_file(&svn, "tracked.txt", "initial\n");
    let peer = fixture.checkout_copy(&svn, "peer");
    fixture.write_file_in(&peer, "tracked.txt", "remote head\n");
    fixture.commit_path(&svn, &peer.join("tracked.txt"), "advance remote head");
    fixture.write_file("tracked.txt", "local working\n");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");
    let mut auth = UnavailableAuthRequestBroker;

    let base = bridge
        .content_get(&identity, "tracked.txt", "base", &mut auth)
        .expect("native bridge should return BASE file content");
    let head = bridge
        .content_get(&identity, "tracked.txt", "head", &mut auth)
        .expect("native bridge should return HEAD file content");
    let revision_two = bridge
        .content_get(&identity, "tracked.txt", "r2", &mut auth)
        .expect("native bridge should return r2 file content");
    let revision_three = bridge
        .content_get(&identity, "tracked.txt", "r3", &mut auth)
        .expect("native bridge should return r3 file content");

    assert_eq!(base.data, b"initial\n");
    assert_eq!(head.data, b"remote head\n");
    assert_eq!(revision_two.data, b"initial\n");
    assert_eq!(revision_three.data, b"remote head\n");
    assert_eq!(base.source, "libsvn-base");
    assert_eq!(head.source, "libsvn-head");
    assert_eq!(revision_two.source, "libsvn-revision");
    assert_eq!(revision_three.source, "libsvn-revision");
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_history_log_returns_file_revision_entries() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    fixture.add_committed_file(&svn, "tracked.txt", "initial\n");
    fixture.write_file("tracked.txt", "edit one\n");
    fixture.commit_path(
        &svn,
        &fixture.wc.join("tracked.txt"),
        "edit tracked fixture file once",
    );
    fixture.write_file("tracked.txt", "edit two\n");
    fixture.commit_path(
        &svn,
        &fixture.wc.join("tracked.txt"),
        "edit tracked fixture file twice",
    );

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");
    let mut auth = UnavailableAuthRequestBroker;

    let log = bridge
        .history_log(
            &identity,
            &HistoryLogRequest {
                path: "tracked.txt".to_string(),
                start_revision: "head".to_string(),
                end_revision: "r0".to_string(),
                limit: 10,
                discover_changed_paths: true,
                strict_node_history: true,
                include_merged_revisions: false,
            },
            &mut auth,
        )
        .expect("native bridge should return file history");

    assert_eq!(log.source, "libsvn-log");
    assert!(log.entries.len() >= 3);
    assert_eq!(
        log.entries[0].message.as_deref(),
        Some("edit tracked fixture file twice")
    );
    assert_eq!(
        log.entries[1].message.as_deref(),
        Some("edit tracked fixture file once")
    );
    assert_eq!(
        log.entries[2].message.as_deref(),
        Some("add tracked fixture file")
    );
    assert!(
        log.entries
            .iter()
            .flat_map(|entry| entry.changed_paths.iter())
            .any(|path| path.path == "/trunk/tracked.txt" && path.action == "A")
    );
    assert!(
        log.entries
            .iter()
            .flat_map(|entry| entry.changed_paths.iter())
            .any(|path| path.path == "/trunk/tracked.txt" && path.action == "M")
    );
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_history_log_returns_repository_root_history_for_dot_path() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    fixture.add_committed_file(&svn, "tracked.txt", "root history fixture\n");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");
    let mut auth = UnavailableAuthRequestBroker;
    let log = bridge
        .history_log(
            &identity,
            &HistoryLogRequest {
                path: ".".to_string(),
                start_revision: "head".to_string(),
                end_revision: "r0".to_string(),
                limit: 10,
                discover_changed_paths: true,
                strict_node_history: false,
                include_merged_revisions: false,
            },
            &mut auth,
        )
        .expect("native bridge should return repository-root history");

    assert_eq!(log.source, "libsvn-log");
    assert!(!log.entries.is_empty());
    assert!(log.entries.iter().any(|entry| {
        entry
            .changed_paths
            .iter()
            .any(|path| path.path == "/trunk/tracked.txt")
    }));
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_history_log_normalizes_missing_and_empty_revision_authors() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svnadmin = tool_dir.join("svnadmin.exe");
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&svnadmin, &svn);
    fixture.add_committed_file(&svn, "tracked.txt", "author metadata fixture\n");
    fixture.delete_revision_author(&svnadmin, 1);
    fixture.set_empty_revision_author(&svnadmin, 2);

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");
    let mut auth = UnavailableAuthRequestBroker;
    let log = bridge
        .history_log(
            &identity,
            &HistoryLogRequest {
                path: ".".to_string(),
                start_revision: "head".to_string(),
                end_revision: "r0".to_string(),
                limit: 10,
                discover_changed_paths: true,
                strict_node_history: false,
                include_merged_revisions: false,
            },
            &mut auth,
        )
        .expect("native bridge should return history with nullable author metadata");

    assert_eq!(
        log.entries
            .iter()
            .find(|entry| entry.revision == 1)
            .expect("trunk creation revision should be present")
            .author,
        None
    );
    assert_eq!(
        log.entries
            .iter()
            .find(|entry| entry.revision == 2)
            .expect("file addition revision should be present")
            .author,
        None
    );
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_history_blame_returns_line_revision_entries() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    fixture.add_committed_file(&svn, "tracked.txt", "alpha\nbeta\ngamma\n");
    fixture.write_file("tracked.txt", "alpha\nbeta changed\ngamma\n");
    fixture.commit_path(
        &svn,
        &fixture.wc.join("tracked.txt"),
        "edit middle line for blame",
    );

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");
    let mut auth = UnavailableAuthRequestBroker;

    let blame = bridge
        .history_blame(
            &identity,
            &HistoryBlameRequest {
                path: "tracked.txt".to_string(),
                peg_revision: "base".to_string(),
                start_revision: "r0".to_string(),
                end_revision: "base".to_string(),
                line_start: 1,
                line_limit: 10,
                ignore_whitespace: "none".to_string(),
                ignore_eol_style: false,
                ignore_mime_type: false,
                include_merged_revisions: false,
            },
            &mut auth,
        )
        .expect("native bridge should return file blame");

    assert_eq!(blame.source, "libsvn-blame");
    assert_eq!(blame.resolved_start_revision, 0);
    assert!(blame.resolved_end_revision >= blame.resolved_start_revision);
    assert_eq!(blame.line_start, 1);
    assert_eq!(blame.line_limit, 10);
    assert_eq!(blame.ignore_whitespace, "none");
    assert!(!blame.ignore_eol_style);
    assert!(!blame.ignore_mime_type);
    assert!(!blame.include_merged_revisions);
    assert!(!blame.has_more);
    assert_eq!(blame.lines.len(), 3);

    let line_texts = blame
        .lines
        .iter()
        .map(|line| {
            String::from_utf8(
                STANDARD
                    .decode(&line.line_base64)
                    .expect("blame line should be valid base64"),
            )
            .expect("fixture blame line should be UTF-8")
        })
        .collect::<Vec<_>>();
    assert_eq!(line_texts, vec!["alpha", "beta changed", "gamma"]);

    let first_revision = blame.lines[0]
        .revision
        .expect("first line should have blame revision");
    let second_revision = blame.lines[1]
        .revision
        .expect("second line should have blame revision");
    assert_eq!(blame.lines[0].line_number, 1);
    assert_eq!(blame.lines[1].line_number, 2);
    assert_eq!(blame.lines[2].line_number, 3);
    assert_eq!(blame.lines[2].revision, Some(first_revision));
    assert!(second_revision > first_revision);
    assert!(blame.lines.iter().all(|line| !line.local_change));
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_revert_restores_modified_file_and_reports_touched_path() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let fixture =
        WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &tool_dir.join("svn.exe"));
    fixture.add_committed_file(&tool_dir.join("svn.exe"), "tracked.txt", "initial\n");
    fixture.write_file("tracked.txt", "modified\n");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");

    let result = bridge
        .operation_revert(
            &identity,
            &subversionr_daemon::RevertOperationRequest {
                paths: vec!["tracked.txt".to_string()],
                depth: "empty".to_string(),
                changelists: Vec::new(),
                clear_changelists: false,
                metadata_only: false,
                added_keep_local: false,
            },
        )
        .expect("native bridge should revert the modified file");

    assert_eq!(result.touched_paths, vec!["tracked.txt"]);
    assert!(result.skipped_paths.is_empty());
    assert_eq!(fixture.read_file("tracked.txt"), "initial\n");

    let snapshot = bridge
        .status_scan(&identity, "tracked.txt", "empty", 77)
        .expect("native bridge should scan the reverted file");
    assert_eq!(snapshot.summary.local_changes, 0);
    assert!(snapshot.local_entries.is_empty());
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_add_schedules_unversioned_file_and_reports_touched_path() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let fixture =
        WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &tool_dir.join("svn.exe"));
    fixture.write_file("scratch.txt", "new file\n");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");

    let result = bridge
        .operation_add(
            &identity,
            &subversionr_daemon::AddOperationRequest {
                paths: vec!["scratch.txt".to_string()],
                depth: "empty".to_string(),
                force: false,
                no_ignore: false,
                no_autoprops: false,
                add_parents: false,
            },
        )
        .expect("native bridge should add the unversioned file");

    assert_eq!(result.touched_paths, vec!["scratch.txt"]);
    assert!(result.skipped_paths.is_empty());
    assert_eq!(fixture.read_file("scratch.txt"), "new file\n");

    let snapshot = bridge
        .status_scan(&identity, "scratch.txt", "empty", 78)
        .expect("native bridge should scan the added file");
    assert_eq!(snapshot.summary.local_changes, 1);
    assert_eq!(snapshot.summary.unversioned, 0);
    let scratch = snapshot
        .local_entries
        .iter()
        .find(|entry| entry.path.replace('\\', "/") == "scratch.txt")
        .expect("added file should be reported");
    assert_eq!(scratch.local_status, "added");
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_remove_schedules_versioned_file_delete_and_reports_touched_path() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let fixture =
        WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &tool_dir.join("svn.exe"));
    fixture.add_committed_file(&tool_dir.join("svn.exe"), "tracked.txt", "initial\n");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");

    let result = bridge
        .operation_remove(
            &identity,
            &subversionr_daemon::RemoveOperationRequest {
                paths: vec!["tracked.txt".to_string()],
                force: false,
                keep_local: false,
            },
        )
        .expect("native bridge should remove the versioned file");

    assert_eq!(result.touched_paths, vec!["tracked.txt"]);
    assert!(result.skipped_paths.is_empty());
    assert!(!fixture.path_exists("tracked.txt"));

    let snapshot = bridge
        .status_scan(&identity, "tracked.txt", "empty", 79)
        .expect("native bridge should scan the removed file");
    assert_eq!(snapshot.summary.local_changes, 1);
    let tracked = snapshot
        .local_entries
        .iter()
        .find(|entry| entry.path.replace('\\', "/") == "tracked.txt")
        .expect("removed file should be reported");
    assert_eq!(tracked.local_status, "deleted");
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_remove_keep_local_preserves_file_and_schedules_delete() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let fixture =
        WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &tool_dir.join("svn.exe"));
    fixture.add_committed_file(&tool_dir.join("svn.exe"), "keep.txt", "keep local\n");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");

    let result = bridge
        .operation_remove(
            &identity,
            &subversionr_daemon::RemoveOperationRequest {
                paths: vec!["keep.txt".to_string()],
                force: false,
                keep_local: true,
            },
        )
        .expect("native bridge should remove the versioned file with keep_local");

    assert_eq!(result.touched_paths, vec!["keep.txt"]);
    assert!(result.skipped_paths.is_empty());
    assert!(fixture.path_exists("keep.txt"));
    assert_eq!(fixture.read_file("keep.txt"), "keep local\n");

    let snapshot = bridge
        .status_scan(&identity, "keep.txt", "empty", 80)
        .expect("native bridge should scan the keep-local removed file");
    assert_eq!(snapshot.summary.local_changes, 1);
    let tracked = snapshot
        .local_entries
        .iter()
        .find(|entry| entry.path.replace('\\', "/") == "keep.txt")
        .expect("keep-local removed file should be reported");
    assert_eq!(tracked.local_status, "deleted");
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_move_schedules_versioned_file_rename_and_reports_touched_paths() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let fixture =
        WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &tool_dir.join("svn.exe"));
    fixture.add_committed_file(&tool_dir.join("svn.exe"), "tracked.txt", "initial\n");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");

    let result = bridge
        .operation_move(
            &identity,
            &subversionr_daemon::MoveOperationRequest {
                source_path: "tracked.txt".to_string(),
                destination_path: "renamed/tracked.txt".to_string(),
                make_parents: true,
            },
        )
        .expect("native bridge should move the versioned file");

    assert!(
        result
            .touched_paths
            .iter()
            .any(|path| path == "tracked.txt"),
        "move should report the source path as touched"
    );
    assert!(
        result
            .touched_paths
            .iter()
            .any(|path| path.replace('\\', "/") == "renamed/tracked.txt"),
        "move should report the destination path as touched"
    );
    assert!(result.skipped_paths.is_empty());
    assert!(!fixture.path_exists("tracked.txt"));
    assert_eq!(fixture.read_file("renamed/tracked.txt"), "initial\n");

    let source_parent_snapshot = bridge
        .status_scan(&identity, ".", "immediates", 82)
        .expect("native bridge should scan the move source parent");
    let source_parent_deleted = source_parent_snapshot
        .local_entries
        .iter()
        .find(|entry| entry.path.replace('\\', "/") == "tracked.txt")
        .expect("move source should be reported from parent immediates scan");
    assert_eq!(source_parent_deleted.local_status, "deleted");

    let destination_parent_snapshot = bridge
        .status_scan(&identity, "renamed", "immediates", 83)
        .expect("native bridge should scan the move destination parent");
    let destination_parent_added = destination_parent_snapshot
        .local_entries
        .iter()
        .find(|entry| entry.path.replace('\\', "/") == "renamed/tracked.txt")
        .expect("move destination should be reported from parent immediates scan");
    assert_eq!(destination_parent_added.local_status, "added");
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_resolve_clears_text_conflict_and_reports_touched_path() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    fixture.add_committed_file(&svn, "conflicted.txt", "base\n");
    let peer_wc = fixture.checkout_copy(&svn, "peer-wc");
    fixture.write_file_in(&peer_wc, "conflicted.txt", "remote\n");
    fixture.commit_path(&svn, &peer_wc.join("conflicted.txt"), "remote edit");
    fixture.write_file("conflicted.txt", "local\n");
    fixture.update_accepting_conflicts(&svn, "conflicted.txt");
    fixture.write_file("conflicted-copy.txt.mine", "ordinary unversioned file\n");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");
    let conflicted = bridge
        .status_scan(&identity, ".", "infinity", 81)
        .expect("native bridge should scan the conflicted working copy");
    assert_eq!(conflicted.summary.conflicts, 1);
    let conflict_owner = conflicted
        .local_entries
        .iter()
        .find(|entry| entry.path.replace('\\', "/") == "conflicted.txt")
        .expect("conflicted owner should be reported");
    assert_eq!(conflict_owner.conflict_artifacts.len(), 3);
    let mut sorted_artifacts = conflict_owner.conflict_artifacts.clone();
    sorted_artifacts.sort();
    assert_eq!(conflict_owner.conflict_artifacts, sorted_artifacts);
    assert!(
        conflict_owner
            .conflict_artifacts
            .iter()
            .all(|artifact| artifact != "conflicted.txt" && !artifact.starts_with(".svn/"))
    );
    assert!(conflict_owner.conflict_artifacts.iter().all(|artifact| {
        conflicted
            .local_entries
            .iter()
            .all(|entry| entry.path.replace('\\', "/") != *artifact)
    }));
    assert!(conflicted.local_entries.iter().any(|entry| {
        entry.path.replace('\\', "/") == "conflicted-copy.txt.mine"
            && entry.local_status == "unversioned"
    }));
    let artifact_paths = conflict_owner.conflict_artifacts.clone();
    let fixture_root = PathBuf::from(fixture.wc_path());
    assert!(
        artifact_paths
            .iter()
            .all(|artifact| fixture_root.join(artifact).is_file())
    );
    let working_copy_contents_before_resolve = fixture.read_file("conflicted.txt");

    let result = bridge
        .operation_resolve(
            &identity,
            &subversionr_daemon::ResolveOperationRequest {
                paths: vec!["conflicted.txt".to_string()],
                depth: "empty".to_string(),
                choice: "working".to_string(),
            },
        )
        .expect("native bridge should mark the conflict resolved");

    assert_eq!(result.touched_paths, vec!["conflicted.txt"]);
    assert!(result.skipped_paths.is_empty());

    let resolved = bridge
        .status_scan(&identity, ".", "infinity", 82)
        .expect("native bridge should scan the resolved working copy");
    assert_eq!(
        fixture.read_file("conflicted.txt"),
        working_copy_contents_before_resolve
    );
    assert_eq!(resolved.summary.conflicts, 0);
    assert!(
        resolved
            .local_entries
            .iter()
            .all(|entry| entry.conflict.is_none() && entry.conflict_artifacts.is_empty())
    );
    assert!(
        artifact_paths
            .iter()
            .all(|artifact| !fixture_root.join(artifact).exists())
    );
    assert!(resolved.local_entries.iter().any(|entry| {
        entry.path.replace('\\', "/") == "conflicted-copy.txt.mine"
            && entry.local_status == "unversioned"
    }));
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_resolve_accepts_hunk_conflict_choice() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    fixture.add_committed_file(&svn, "conflicted.txt", "base\n");
    let peer_wc = fixture.checkout_copy(&svn, "peer-wc");
    fixture.write_file_in(&peer_wc, "conflicted.txt", "remote\n");
    fixture.commit_path(&svn, &peer_wc.join("conflicted.txt"), "remote edit");
    fixture.write_file("conflicted.txt", "local\n");
    fixture.update_accepting_conflicts(&svn, "conflicted.txt");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");

    let result = bridge
        .operation_resolve(
            &identity,
            &subversionr_daemon::ResolveOperationRequest {
                paths: vec!["conflicted.txt".to_string()],
                depth: "empty".to_string(),
                choice: "mineConflict".to_string(),
            },
        )
        .expect("native bridge should mark the conflict resolved with a hunk strategy");

    assert_eq!(result.touched_paths, vec!["conflicted.txt"]);
    assert!(result.skipped_paths.is_empty());
    let resolved = bridge
        .status_scan(&identity, "conflicted.txt", "empty", 82)
        .expect("native bridge should scan the resolved file");
    assert_eq!(resolved.summary.conflicts, 0);
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_cleanup_preserves_unversioned_files_and_reports_root() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let fixture =
        WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &tool_dir.join("svn.exe"));
    fixture.write_file("scratch.txt", "unversioned\n");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");

    let result = bridge
        .operation_cleanup(
            &identity,
            &subversionr_daemon::CleanupOperationRequest {
                path: ".".to_string(),
                break_locks: true,
                fix_recorded_timestamps: false,
                clear_dav_cache: false,
                vacuum_pristines: false,
                include_externals: false,
            },
        )
        .expect("native bridge should clean up the working copy");

    assert_eq!(result.touched_paths, vec!["."]);
    assert!(result.skipped_paths.is_empty());
    assert!(fixture.path_exists("scratch.txt"));
    assert_eq!(fixture.read_file("scratch.txt"), "unversioned\n");
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_upgrade_working_copy_reports_root() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let fixture =
        WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &tool_dir.join("svn.exe"));

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");

    let result = bridge
        .operation_upgrade(
            &identity,
            &subversionr_daemon::UpgradeOperationRequest {
                path: ".".to_string(),
            },
        )
        .expect("native bridge should upgrade the working copy");

    assert_eq!(result.touched_paths, vec!["."]);
    assert!(result.skipped_paths.is_empty());
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_update_root_to_head_applies_remote_change_and_reports_revision() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    fixture.add_committed_file(&svn, "tracked.txt", "initial\n");
    let peer_wc = fixture.checkout_copy(&svn, "peer-wc");
    fixture.write_file_in(&peer_wc, "tracked.txt", "remote\n");
    fixture.commit_path(&svn, &peer_wc.join("tracked.txt"), "remote edit");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");
    let mut auth = UnavailableAuthRequestBroker;

    let result = bridge
        .operation_update(
            &identity,
            &subversionr_daemon::UpdateOperationRequest {
                path: ".".to_string(),
                revision: "head".to_string(),
                depth: "workingCopy".to_string(),
                depth_is_sticky: false,
                ignore_externals: true,
            },
            &mut auth,
        )
        .expect("native bridge should update the working copy root");

    assert_eq!(result.result.touched_paths, vec!["."]);
    assert!(result.result.skipped_paths.is_empty());
    assert!(result.revision >= 3);
    assert_eq!(fixture.read_file("tracked.txt"), "remote\n");

    let snapshot = bridge
        .status_scan(&identity, "tracked.txt", "empty", 83)
        .expect("native bridge should scan the updated file");
    assert_eq!(snapshot.summary.local_changes, 0);
    assert!(snapshot.local_entries.is_empty());
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_branch_create_and_switch_use_libsvn() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    fixture.add_committed_file(&svn, "tracked.txt", "trunk\n");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");
    let mut auth = UnavailableAuthRequestBroker;
    let branch_url = format!("{}/branches/feature", fixture.repo_url);

    let create_result = bridge
        .operation_branch_create(
            &identity,
            &subversionr_daemon::BranchCreateOperationRequest {
                source_url: format!("{}/trunk", fixture.repo_url),
                destination_url: branch_url.clone(),
                revision: "head".to_string(),
                message: "create feature branch".to_string(),
                make_parents: true,
                ignore_externals: true,
            },
            &mut auth,
        )
        .expect("native bridge should create an SVN branch through libsvn");

    assert!(create_result.revision >= 3);
    assert!(create_result.result.touched_paths.is_empty());
    assert!(create_result.result.skipped_paths.is_empty());

    let branch_wc = fixture._temp.path.join("feature-operation-wc");
    run_tool(
        &svn,
        [
            "checkout".as_ref(),
            branch_url.as_ref(),
            branch_wc.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    fixture.write_file_in(&branch_wc, "tracked.txt", "feature\n");
    fixture.commit_path(&svn, &branch_wc.join("tracked.txt"), "edit feature branch");
    assert_eq!(fixture.read_file("tracked.txt"), "trunk\n");

    let switch_result = bridge
        .operation_switch(
            &identity,
            &subversionr_daemon::SwitchOperationRequest {
                path: ".".to_string(),
                url: branch_url,
                revision: "head".to_string(),
                depth: "workingCopy".to_string(),
                depth_is_sticky: false,
                ignore_externals: true,
                ignore_ancestry: false,
            },
            &mut auth,
        )
        .expect("native bridge should switch the working copy through libsvn");

    assert!(switch_result.revision >= create_result.revision);
    assert!(switch_result.result.skipped_paths.is_empty());
    assert_eq!(fixture.read_file("tracked.txt"), "feature\n");
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_update_root_to_numbered_revision_restores_historical_content() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    fixture.add_committed_file(&svn, "tracked.txt", "initial\n");
    let peer_wc = fixture.checkout_copy(&svn, "peer-wc");
    fixture.write_file_in(&peer_wc, "tracked.txt", "remote\n");
    fixture.commit_path(&svn, &peer_wc.join("tracked.txt"), "remote edit");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");
    let mut auth = UnavailableAuthRequestBroker;

    bridge
        .operation_update(
            &identity,
            &subversionr_daemon::UpdateOperationRequest {
                path: ".".to_string(),
                revision: "head".to_string(),
                depth: "workingCopy".to_string(),
                depth_is_sticky: false,
                ignore_externals: true,
            },
            &mut auth,
        )
        .expect("native bridge should update the working copy root to HEAD");
    assert_eq!(fixture.read_file("tracked.txt"), "remote\n");

    let result = bridge
        .operation_update(
            &identity,
            &subversionr_daemon::UpdateOperationRequest {
                path: ".".to_string(),
                revision: "2".to_string(),
                depth: "workingCopy".to_string(),
                depth_is_sticky: false,
                ignore_externals: true,
            },
            &mut auth,
        )
        .expect("native bridge should update the working copy root to r2");

    assert_eq!(result.result.touched_paths, vec!["."]);
    assert!(result.result.skipped_paths.is_empty());
    assert_eq!(result.revision, 2);
    assert_eq!(fixture.read_file("tracked.txt"), "initial\n");
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_update_with_sparse_sticky_depth_keeps_children_absent() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    let peer_wc = fixture.checkout_copy(&svn, "peer-wc");
    let peer_src = peer_wc.join("src");
    fs::create_dir_all(&peer_src).expect("fixture directory should be created");
    fixture.write_file_in(&peer_wc, "src/tracked.txt", "remote child\n");
    run_tool(
        &svn,
        [
            "add".as_ref(),
            peer_src.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    fixture.commit_path(&svn, &peer_src, "add child tree");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");
    let mut auth = UnavailableAuthRequestBroker;

    let result = bridge
        .operation_update(
            &identity,
            &subversionr_daemon::UpdateOperationRequest {
                path: ".".to_string(),
                revision: "head".to_string(),
                depth: "empty".to_string(),
                depth_is_sticky: true,
                ignore_externals: true,
            },
            &mut auth,
        )
        .expect("native bridge should update with sparse sticky depth");

    assert_eq!(result.result.touched_paths, vec!["."]);
    assert!(result.result.skipped_paths.is_empty());
    assert!(result.revision >= 2);
    assert!(!fixture.path_exists("src/tracked.txt"));
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_update_includes_externals_when_requested() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    let external_url = format!("{}/external", fixture.repo_url);
    run_tool(
        &svn,
        [
            "mkdir".as_ref(),
            external_url.as_ref(),
            "-m".as_ref(),
            "create external root".as_ref(),
            "--non-interactive".as_ref(),
        ],
    );
    let external_wc = fixture._temp.path.join("external-wc");
    run_tool(
        &svn,
        [
            "checkout".as_ref(),
            external_url.as_ref(),
            external_wc.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    fixture.write_file_in(&external_wc, "external.txt", "external content\n");
    let external_file = external_wc.join("external.txt");
    run_tool(
        &svn,
        [
            "add".as_ref(),
            external_file.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    fixture.commit_path(&svn, &external_file, "add external content");
    let externals_value = format!("external-dir {external_url}");
    run_tool(
        &svn,
        [
            "propset".as_ref(),
            "svn:externals".as_ref(),
            externals_value.as_ref(),
            fixture.wc.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    fixture.commit_path(&svn, &fixture.wc, "add external definition");
    assert!(!fixture.path_exists("external-dir/external.txt"));

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");
    let mut auth = UnavailableAuthRequestBroker;

    bridge
        .operation_update(
            &identity,
            &subversionr_daemon::UpdateOperationRequest {
                path: ".".to_string(),
                revision: "head".to_string(),
                depth: "workingCopy".to_string(),
                depth_is_sticky: false,
                ignore_externals: false,
            },
            &mut auth,
        )
        .expect("native bridge should update SVN externals when requested");

    assert!(fixture.path_exists("external-dir/external.txt"));
    assert_eq!(
        fixture.read_file("external-dir/external.txt"),
        "external content\n"
    );
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_update_selected_path_applies_only_that_remote_change() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    fixture.add_committed_file(&svn, "tracked.txt", "initial\n");
    fixture.add_committed_file(&svn, "other.txt", "other initial\n");
    let peer_wc = fixture.checkout_copy(&svn, "peer-wc");
    fixture.write_file_in(&peer_wc, "tracked.txt", "remote selected\n");
    fixture.write_file_in(&peer_wc, "other.txt", "remote other\n");
    fixture.commit_path(&svn, &peer_wc, "remote edit two files");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");
    let mut auth = UnavailableAuthRequestBroker;

    let result = bridge
        .operation_update(
            &identity,
            &subversionr_daemon::UpdateOperationRequest {
                path: "tracked.txt".to_string(),
                revision: "head".to_string(),
                depth: "workingCopy".to_string(),
                depth_is_sticky: false,
                ignore_externals: true,
            },
            &mut auth,
        )
        .expect("native bridge should update the selected path");

    assert_eq!(result.result.touched_paths, vec!["tracked.txt"]);
    assert!(result.result.skipped_paths.is_empty());
    assert!(result.revision >= 4);
    assert_eq!(fixture.read_file("tracked.txt"), "remote selected\n");
    assert_eq!(fixture.read_file("other.txt"), "other initial\n");
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_commit_modified_file_publishes_revision_and_cleans_status() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    fixture.add_committed_file(&svn, "tracked.txt", "initial\n");
    let peer_wc = fixture.checkout_copy(&svn, "peer-wc");
    fixture.write_file("tracked.txt", "committed through bridge\n");
    let expected_os_username = raw_revision_author(&svn, &fixture.repo_url, 1, []);
    assert!(
        !expected_os_username.is_empty(),
        "the staged SVN client must record the current OS username for the file-backed fixture"
    );

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");
    let mut auth = UnavailableAuthRequestBroker;

    let result = bridge
        .operation_commit(
            &identity,
            &subversionr_daemon::CommitOperationRequest {
                paths: vec!["tracked.txt".to_string()],
                message: "commit tracked file through SubversionR bridge".to_string(),
                depth: "empty".to_string(),
                changelists: Vec::new(),
                keep_locks: false,
                keep_changelists: false,
                commit_as_operations: false,
                include_file_externals: false,
                include_dir_externals: false,
            },
            &mut auth,
        )
        .expect("native bridge should commit the modified file");

    assert_eq!(result.result.touched_paths, vec!["tracked.txt"]);
    assert!(result.result.skipped_paths.is_empty());
    assert!(result.revision >= 3);
    assert_eq!(
        raw_revision_author(&svn, &fixture.repo_url, result.revision, []),
        expected_os_username,
        "file-backed bridge commits must record the same OS username as native SVN"
    );

    let snapshot = bridge
        .status_scan(&identity, "tracked.txt", "empty", 84)
        .expect("native bridge should scan the committed file");
    assert_eq!(snapshot.summary.local_changes, 0);
    assert!(snapshot.local_entries.is_empty());

    run_tool(
        &svn,
        [
            "update".as_ref(),
            peer_wc.join("tracked.txt").as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    let peer_contents =
        fs::read_to_string(peer_wc.join("tracked.txt")).expect("peer file should be read");
    assert_eq!(peer_contents, "committed through bridge\n");
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_commit_multiple_modified_files_publishes_one_revision() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    fixture.add_committed_file(&svn, "tracked.txt", "initial\n");
    fixture.add_committed_file(&svn, "other.txt", "other initial\n");
    let peer_wc = fixture.checkout_copy(&svn, "peer-wc");
    fixture.write_file("tracked.txt", "committed multi one\n");
    fixture.write_file("other.txt", "committed multi two\n");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");
    let mut auth = UnavailableAuthRequestBroker;

    let result = bridge
        .operation_commit(
            &identity,
            &subversionr_daemon::CommitOperationRequest {
                paths: vec!["tracked.txt".to_string(), "other.txt".to_string()],
                message: "commit multiple tracked files through SubversionR bridge".to_string(),
                depth: "empty".to_string(),
                changelists: Vec::new(),
                keep_locks: false,
                keep_changelists: false,
                commit_as_operations: false,
                include_file_externals: false,
                include_dir_externals: false,
            },
            &mut auth,
        )
        .expect("native bridge should commit both modified files");

    let mut touched_paths = result.result.touched_paths.clone();
    touched_paths.sort();
    assert_eq!(touched_paths, vec!["other.txt", "tracked.txt"]);
    assert!(result.result.skipped_paths.is_empty());
    assert!(result.revision >= 4);

    let tracked_snapshot = bridge
        .status_scan(&identity, "tracked.txt", "empty", 85)
        .expect("native bridge should scan the first committed file");
    assert_eq!(tracked_snapshot.summary.local_changes, 0);
    assert!(tracked_snapshot.local_entries.is_empty());
    let other_snapshot = bridge
        .status_scan(&identity, "other.txt", "empty", 86)
        .expect("native bridge should scan the second committed file");
    assert_eq!(other_snapshot.summary.local_changes, 0);
    assert!(other_snapshot.local_entries.is_empty());

    run_tool(
        &svn,
        [
            "update".as_ref(),
            peer_wc.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    let peer_tracked_contents =
        fs::read_to_string(peer_wc.join("tracked.txt")).expect("peer first file should be read");
    let peer_other_contents =
        fs::read_to_string(peer_wc.join("other.txt")).expect("peer second file should be read");
    assert_eq!(peer_tracked_contents, "committed multi one\n");
    assert_eq!(peer_other_contents, "committed multi two\n");
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_changelist_set_clear_and_commit_filter_use_libsvn() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    fixture.add_committed_file(&svn, "tracked.txt", "initial\n");
    fixture.add_committed_file(&svn, "other.txt", "other initial\n");
    let peer_wc = fixture.checkout_copy(&svn, "peer-wc");
    fixture.write_file("tracked.txt", "review changelist commit\n");
    fixture.write_file("other.txt", "not in review changelist\n");

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");

    let set_result = bridge
        .operation_changelist_set(
            &identity,
            &subversionr_daemon::ChangelistSetOperationRequest {
                paths: vec!["tracked.txt".to_string()],
                depth: "empty".to_string(),
                changelist: "review".to_string(),
                changelists: Vec::new(),
            },
        )
        .expect("native bridge should assign the changelist through libsvn");
    assert_eq!(set_result.touched_paths, vec!["tracked.txt"]);

    let tracked_after_set = bridge
        .status_scan(&identity, "tracked.txt", "empty", 88)
        .expect("native bridge should scan the changelisted file")
        .local_entries
        .into_iter()
        .find(|entry| entry.path == "tracked.txt")
        .expect("tracked file should appear in status after changelist set");
    assert_eq!(tracked_after_set.changelist.as_deref(), Some("review"));

    let clear_result = bridge
        .operation_changelist_clear(
            &identity,
            &subversionr_daemon::ChangelistClearOperationRequest {
                paths: vec!["tracked.txt".to_string()],
                depth: "empty".to_string(),
                changelists: vec!["review".to_string()],
            },
        )
        .expect("native bridge should clear the changelist through libsvn");
    assert_eq!(clear_result.touched_paths, vec!["tracked.txt"]);

    let tracked_after_clear = bridge
        .status_scan(&identity, "tracked.txt", "empty", 89)
        .expect("native bridge should scan the cleared file")
        .local_entries
        .into_iter()
        .find(|entry| entry.path == "tracked.txt")
        .expect("tracked file should remain modified after changelist clear");
    assert_eq!(tracked_after_clear.changelist, None);

    bridge
        .operation_changelist_set(
            &identity,
            &subversionr_daemon::ChangelistSetOperationRequest {
                paths: vec!["tracked.txt".to_string()],
                depth: "empty".to_string(),
                changelist: "review".to_string(),
                changelists: Vec::new(),
            },
        )
        .expect("native bridge should reassign the changelist before filtered commit");

    let mut auth = UnavailableAuthRequestBroker;
    let commit_result = bridge
        .operation_commit(
            &identity,
            &subversionr_daemon::CommitOperationRequest {
                paths: vec!["tracked.txt".to_string(), "other.txt".to_string()],
                message: "commit review changelist through SubversionR bridge".to_string(),
                depth: "empty".to_string(),
                changelists: vec!["review".to_string()],
                keep_locks: false,
                keep_changelists: false,
                commit_as_operations: false,
                include_file_externals: false,
                include_dir_externals: false,
            },
            &mut auth,
        )
        .expect("native bridge should commit only the matching changelist file");
    assert!(
        commit_result
            .result
            .touched_paths
            .contains(&"tracked.txt".to_string())
    );
    assert!(commit_result.revision >= 4);

    run_tool(
        &svn,
        [
            "update".as_ref(),
            peer_wc.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    let peer_tracked_contents =
        fs::read_to_string(peer_wc.join("tracked.txt")).expect("peer tracked file should be read");
    let peer_other_contents =
        fs::read_to_string(peer_wc.join("other.txt")).expect("peer other file should be read");
    assert_eq!(peer_tracked_contents, "review changelist commit\n");
    assert_eq!(peer_other_contents, "other initial\n");

    let other_snapshot = bridge
        .status_scan(&identity, "other.txt", "empty", 90)
        .expect("native bridge should scan the non-changelist file");
    assert_eq!(other_snapshot.summary.local_changes, 1);
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_commit_directory_property_change_publishes_revision_and_cleans_status() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    let peer_wc = fixture.checkout_copy(&svn, "peer-wc");
    fs::create_dir_all(fixture.wc.join("src")).expect("fixture directory should be created");
    run_tool(
        &svn,
        [
            "add".as_ref(),
            fixture.wc.join("src").as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    fixture.commit_path(&svn, &fixture.wc.join("src"), "add directory fixture");
    run_tool(
        &svn,
        [
            "propset".as_ref(),
            "subversionr:test".as_ref(),
            "value".as_ref(),
            fixture.wc.join("src").as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");
    let mut auth = UnavailableAuthRequestBroker;

    let result = bridge
        .operation_commit(
            &identity,
            &subversionr_daemon::CommitOperationRequest {
                paths: vec!["src".to_string()],
                message: "commit directory properties through SubversionR bridge".to_string(),
                depth: "empty".to_string(),
                changelists: Vec::new(),
                keep_locks: false,
                keep_changelists: false,
                commit_as_operations: false,
                include_file_externals: false,
                include_dir_externals: false,
            },
            &mut auth,
        )
        .expect("native bridge should commit directory property changes");

    assert_eq!(result.result.touched_paths, vec!["src"]);
    assert!(result.result.skipped_paths.is_empty());
    assert_eq!(result.revision, 3);

    let snapshot = bridge
        .status_scan(&identity, "src", "empty", 91)
        .expect("native bridge should scan the committed directory");
    assert_eq!(snapshot.summary.local_changes, 0);
    assert!(snapshot.local_entries.is_empty());

    run_tool(
        &svn,
        [
            "update".as_ref(),
            peer_wc.join("src").as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    let propget = run_tool_output(
        &svn,
        [
            "propget".as_ref(),
            "subversionr:test".as_ref(),
            peer_wc.join("src").as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    assert!(
        propget.status.success(),
        "peer propget should succeed: {}",
        String::from_utf8_lossy(&propget.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&propget.stdout).trim_end_matches(['\r', '\n']),
        "value"
    );
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_commit_removed_file_target_remains_allowed() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    fixture.add_committed_file(&svn, "removed.txt", "remove me\n");
    let peer_wc = fixture.checkout_copy(&svn, "peer-wc");
    run_tool(
        &svn,
        [
            "remove".as_ref(),
            fixture.wc.join("removed.txt").as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );

    let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
    let identity = bridge
        .open_working_copy(&fixture.wc_path())
        .expect("native bridge should open the fixture working copy");
    let mut auth = UnavailableAuthRequestBroker;

    let result = bridge
        .operation_commit(
            &identity,
            &subversionr_daemon::CommitOperationRequest {
                paths: vec!["removed.txt".to_string()],
                message: "commit removed file through SubversionR bridge".to_string(),
                depth: "empty".to_string(),
                changelists: Vec::new(),
                keep_locks: false,
                keep_changelists: false,
                commit_as_operations: false,
                include_file_externals: false,
                include_dir_externals: false,
            },
            &mut auth,
        )
        .expect("native bridge should commit a versioned file deletion");

    assert_eq!(result.result.touched_paths, vec!["removed.txt"]);
    assert!(result.result.skipped_paths.is_empty());
    assert!(result.revision >= 3);

    run_tool(
        &svn,
        [
            "update".as_ref(),
            peer_wc.as_os_str(),
            "--non-interactive".as_ref(),
        ],
    );
    assert!(
        !peer_wc.join("removed.txt").exists(),
        "peer checkout should receive the committed file deletion"
    );
}

#[test]
#[ignore = "requires a verified native bridge DLL and staged Apache Subversion fixture tools"]
fn native_bridge_commit_then_update_with_fresh_runtime_stays_stable() {
    let _guard = native_test_guard();
    let bridge_path = native_bridge_path();
    let tool_dir = bridge_tool_dir(&bridge_path);
    let svn = tool_dir.join("svn.exe");
    let fixture = WorkingCopyFixture::create(&tool_dir.join("svnadmin.exe"), &svn);
    fixture.add_committed_file(&svn, "tracked.txt", "initial\n");
    fixture.write_file("tracked.txt", "committed through first runtime\n");

    {
        let bridge = NativeBridge::load(&bridge_path).expect("native bridge should load");
        let identity = bridge
            .open_working_copy(&fixture.wc_path())
            .expect("native bridge should open the fixture working copy");
        let mut auth = UnavailableAuthRequestBroker;
        bridge
            .operation_commit(
                &identity,
                &subversionr_daemon::CommitOperationRequest {
                    paths: vec!["tracked.txt".to_string()],
                    message: "commit before fresh-runtime update".to_string(),
                    depth: "empty".to_string(),
                    changelists: Vec::new(),
                    keep_locks: false,
                    keep_changelists: false,
                    commit_as_operations: false,
                    include_file_externals: false,
                    include_dir_externals: false,
                },
                &mut auth,
            )
            .expect("first runtime should commit the modified file");
    }

    let peer_wc = fixture.checkout_copy(&svn, "peer-wc");
    fixture.write_file_in(&peer_wc, "tracked.txt", "remote after bridge commit\n");
    fixture.commit_path(
        &svn,
        &peer_wc.join("tracked.txt"),
        "remote edit after bridge commit",
    );

    {
        let bridge = NativeBridge::load(&bridge_path).expect("fresh native bridge should load");
        let identity = bridge
            .open_working_copy(&fixture.wc_path())
            .expect("fresh native bridge should open the fixture working copy");
        let mut auth = UnavailableAuthRequestBroker;
        let result = bridge
            .operation_update(
                &identity,
                &subversionr_daemon::UpdateOperationRequest {
                    path: ".".to_string(),
                    revision: "head".to_string(),
                    depth: "workingCopy".to_string(),
                    depth_is_sticky: false,
                    ignore_externals: true,
                },
                &mut auth,
            )
            .expect("fresh runtime should update after an earlier commit runtime was destroyed");

        assert_eq!(result.result.touched_paths, vec!["."]);
        assert!(result.result.skipped_paths.is_empty());
        assert!(result.revision >= 4);
    }

    assert_eq!(
        fixture.read_file("tracked.txt"),
        "remote after bridge commit\n"
    );
}

struct WorkingCopyFixture {
    _temp: TempTree,
    repo_url: String,
    wc: PathBuf,
}

impl WorkingCopyFixture {
    fn create(svnadmin: &PathBuf, svn: &PathBuf) -> Self {
        assert!(
            svnadmin.is_file(),
            "staged svnadmin.exe is required beside the bridge DLL"
        );
        assert!(
            svn.is_file(),
            "staged svn.exe is required beside the bridge DLL"
        );

        let temp = TempTree::create();
        let repo = temp.path.join("repo");
        let wc = temp.path.join("wc");
        let repo_url = file_url(&repo);
        let trunk_url = format!("{repo_url}/trunk");

        run_tool(svnadmin, ["create".as_ref(), repo.as_os_str()]);
        run_tool(
            svn,
            [
                "mkdir".as_ref(),
                trunk_url.as_ref(),
                "-m".as_ref(),
                "create trunk".as_ref(),
                "--non-interactive".as_ref(),
            ],
        );
        run_tool(
            svn,
            [
                "checkout".as_ref(),
                trunk_url.as_ref(),
                wc.as_os_str(),
                "--non-interactive".as_ref(),
            ],
        );

        Self {
            _temp: temp,
            repo_url,
            wc,
        }
    }

    fn wc_path(&self) -> String {
        self.wc.to_string_lossy().to_string()
    }

    fn delete_revision_author(&self, svnadmin: &PathBuf, revision: u64) {
        let repo = self._temp.path.join("repo");
        let revision = revision.to_string();
        run_tool(
            svnadmin,
            [
                "delrevprop".as_ref(),
                repo.as_os_str(),
                "-r".as_ref(),
                revision.as_ref(),
                "svn:author".as_ref(),
            ],
        );
    }

    fn set_empty_revision_author(&self, svnadmin: &PathBuf, revision: u64) {
        let repo = self._temp.path.join("repo");
        let empty = self._temp.path.join("empty-author.txt");
        fs::write(&empty, "").expect("empty author fixture should be written");
        let revision = revision.to_string();
        run_tool(
            svnadmin,
            [
                "setrevprop".as_ref(),
                repo.as_os_str(),
                "-r".as_ref(),
                revision.as_ref(),
                "svn:author".as_ref(),
                empty.as_os_str(),
            ],
        );
    }

    fn add_committed_file(&self, svn: &PathBuf, relative_path: &str, contents: &str) {
        self.add_committed_file_inner(svn, relative_path, contents, None);
    }

    fn add_committed_file_with_mime_type(
        &self,
        svn: &PathBuf,
        relative_path: &str,
        contents: &str,
        mime_type: &str,
    ) {
        self.add_committed_file_inner(svn, relative_path, contents, Some(mime_type));
    }

    fn add_committed_file_inner(
        &self,
        svn: &PathBuf,
        relative_path: &str,
        contents: &str,
        mime_type: Option<&str>,
    ) {
        self.write_file(relative_path, contents);
        let path = self.wc.join(relative_path);
        run_tool(
            svn,
            [
                "add".as_ref(),
                path.as_os_str(),
                "--non-interactive".as_ref(),
            ],
        );
        if let Some(mime_type) = mime_type {
            run_tool(
                svn,
                [
                    "propset".as_ref(),
                    "svn:mime-type".as_ref(),
                    mime_type.as_ref(),
                    path.as_os_str(),
                    "--non-interactive".as_ref(),
                ],
            );
        }
        run_tool(
            svn,
            [
                "commit".as_ref(),
                path.as_os_str(),
                "-m".as_ref(),
                "add tracked fixture file".as_ref(),
                "--non-interactive".as_ref(),
            ],
        );
    }

    fn checkout_copy(&self, svn: &PathBuf, name: &str) -> PathBuf {
        let checkout = self._temp.path.join(name);
        let trunk_url = format!("{}/trunk", self.repo_url);
        run_tool(
            svn,
            [
                "checkout".as_ref(),
                trunk_url.as_ref(),
                checkout.as_os_str(),
                "--non-interactive".as_ref(),
            ],
        );
        checkout
    }

    fn write_file(&self, relative_path: &str, contents: &str) {
        self.write_file_in(&self.wc, relative_path, contents);
    }

    fn write_file_in(&self, root: &Path, relative_path: &str, contents: &str) {
        fs::write(root.join(relative_path), contents).expect("fixture file should be written");
    }

    fn commit_path(&self, svn: &PathBuf, path: &Path, message: &str) {
        run_tool(
            svn,
            [
                "commit".as_ref(),
                path.as_os_str(),
                "-m".as_ref(),
                message.as_ref(),
                "--non-interactive".as_ref(),
            ],
        );
    }

    fn update_accepting_conflicts(&self, svn: &PathBuf, relative_path: &str) {
        run_tool(
            svn,
            [
                "update".as_ref(),
                self.wc.join(relative_path).as_os_str(),
                "--accept".as_ref(),
                "postpone".as_ref(),
                "--non-interactive".as_ref(),
            ],
        );
    }

    fn read_file(&self, relative_path: &str) -> String {
        fs::read_to_string(self.wc.join(relative_path)).expect("fixture file should be read")
    }

    fn path_exists(&self, relative_path: &str) -> bool {
        self.wc.join(relative_path).exists()
    }
}

struct SvnserveFixture {
    temp: TempTree,
    seed_wc: PathBuf,
    port: u16,
    server: Option<Child>,
}

impl SvnserveFixture {
    fn create(svnadmin: &PathBuf, svn: &PathBuf, svnserve: &PathBuf) -> Self {
        let temp = TempTree::create();
        let repo = temp.path.join("repo");
        let seed_wc = temp.path.join("seed-wc");
        let repo_url = file_url(&repo);
        let trunk_url = format!("{repo_url}/trunk");

        run_tool(svnadmin, ["create".as_ref(), repo.as_os_str()]);
        run_tool(
            svn,
            [
                "mkdir".as_ref(),
                trunk_url.as_ref(),
                "-m".as_ref(),
                "create trunk".as_ref(),
                "--non-interactive".as_ref(),
            ],
        );
        run_tool(
            svn,
            [
                "checkout".as_ref(),
                trunk_url.as_ref(),
                seed_wc.as_os_str(),
                "--non-interactive".as_ref(),
            ],
        );
        fs::write(seed_wc.join("tracked.txt"), "served over svnserve\n")
            .expect("svnserve fixture file should be written");
        run_tool(
            svn,
            [
                "add".as_ref(),
                seed_wc.join("tracked.txt").as_os_str(),
                "--non-interactive".as_ref(),
            ],
        );
        run_tool(
            svn,
            [
                "commit".as_ref(),
                seed_wc.join("tracked.txt").as_os_str(),
                "-m".as_ref(),
                "add svnserve fixture file".as_ref(),
                "--non-interactive".as_ref(),
            ],
        );

        fs::write(
            repo.join("conf").join("svnserve.conf"),
            "[general]\nanon-access = none\nauth-access = write\npassword-db = passwd\nrealm = SubversionR Test\n[sasl]\nuse-sasl = false\n",
        )
        .expect("svnserve fixture config should be written");
        fs::write(
            repo.join("conf").join("passwd"),
            "[users]\nalice = secret\n",
        )
        .expect("svnserve fixture password db should be written");

        let port = reserve_loopback_port();
        let readiness_config = temp.path.join("readiness-config");
        let mut server = Command::new(svnserve)
            .args([
                "--daemon",
                "--foreground",
                "--listen-host",
                "127.0.0.1",
                "--listen-port",
                &port.to_string(),
                "--root",
            ])
            .arg(temp.path.as_os_str())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("staged svnserve fixture server should start");
        if let Err(error) = wait_for_svnserve(svn, port, &readiness_config, &mut server) {
            let _ = server.kill();
            let _ = server.wait();
            panic!("{error}");
        }

        Self {
            temp,
            seed_wc,
            port,
            server: Some(server),
        }
    }

    fn trunk_url(&self) -> String {
        format!("svn://127.0.0.1:{}/repo/trunk", self.port)
    }

    fn commit_seed_file(&self, svn: &PathBuf, relative_path: &str, content: &str, message: &str) {
        let path = self.seed_wc.join(relative_path);
        fs::write(&path, content).expect("svnserve seed file should be updated");
        run_tool(
            svn,
            [
                "commit".as_ref(),
                path.as_os_str(),
                "-m".as_ref(),
                message.as_ref(),
                "--non-interactive".as_ref(),
            ],
        );
    }

    fn update_seed_wc(&self, svn: &PathBuf) {
        run_tool(
            svn,
            [
                "update".as_ref(),
                self.seed_wc.as_os_str(),
                "--non-interactive".as_ref(),
            ],
        );
    }

    fn stop_server(&mut self) {
        if let Some(mut server) = self.server.take() {
            let _ = server.kill();
            let _ = server.wait();
        }
    }
}

impl Drop for SvnserveFixture {
    fn drop(&mut self) {
        self.stop_server();
    }
}

struct MaliciousSvnServerResponseFixture {
    port: u16,
    events: mpsc::Receiver<MaliciousSvnServerResponseEvent>,
    stop: mpsc::Sender<()>,
    thread: Option<thread::JoinHandle<()>>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum MaliciousSvnServerResponseEvent {
    GreetingSent,
    ClientResponseReceived,
    AuthRequestSent,
    ReposInfoSent,
    MainCommandReceived(String),
    MaliciousLogResponseSent,
    ConnectionError(String),
}

impl MaliciousSvnServerResponseFixture {
    fn bind(port: u16, repository_uuid: &str, repository_root_url: &str) -> Self {
        let listener = bind_malicious_svn_listener(port);
        listener
            .set_nonblocking(true)
            .expect("malicious svn:// fixture listener should become nonblocking");
        let (event_tx, event_rx) = mpsc::channel();
        let (stop_tx, stop_rx) = mpsc::channel();
        let repository_uuid = repository_uuid.to_string();
        let repository_root_url = repository_root_url.to_string();

        let thread = thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(15);
            loop {
                if stop_rx.try_recv().is_ok() || Instant::now() >= deadline {
                    break;
                }
                match listener.accept() {
                    Ok((mut stream, _peer)) => {
                        let handler_event_tx = event_tx.clone();
                        let handler_repository_uuid = repository_uuid.clone();
                        let handler_repository_root_url = repository_root_url.clone();
                        thread::spawn(move || {
                            handle_malicious_svn_server_connection(
                                &mut stream,
                                handler_repository_uuid.as_str(),
                                handler_repository_root_url.as_str(),
                                &handler_event_tx,
                            );
                        });
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(10));
                    }
                    Err(_) => break,
                }
            }
        });

        Self {
            port,
            events: event_rx,
            stop: stop_tx,
            thread: Some(thread),
        }
    }

    fn observed_events(&self) -> Vec<MaliciousSvnServerResponseEvent> {
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut events = Vec::new();
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break;
            }
            match self
                .events
                .recv_timeout(remaining.min(Duration::from_millis(50)))
            {
                Ok(event) => {
                    let is_terminal = matches!(
                        event,
                        MaliciousSvnServerResponseEvent::MaliciousLogResponseSent
                            | MaliciousSvnServerResponseEvent::ConnectionError(_)
                    );
                    events.push(event);
                    if is_terminal {
                        break;
                    }
                }
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
        }
        events
    }
}

impl Drop for MaliciousSvnServerResponseFixture {
    fn drop(&mut self) {
        let _ = self.stop.send(());
        let _ = TcpStream::connect(("127.0.0.1", self.port));
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn bind_malicious_svn_listener(port: u16) -> TcpListener {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match TcpListener::bind(("127.0.0.1", port)) {
            Ok(listener) => return listener,
            Err(error) if error.kind() == io::ErrorKind::AddrInUse && Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(25));
            }
            Err(error) => {
                panic!(
                    "malicious svn:// fixture should bind 127.0.0.1:{port} after svnserve shutdown: {error}"
                );
            }
        }
    }
}

fn handle_malicious_svn_server_connection(
    stream: &mut TcpStream,
    repository_uuid: &str,
    repository_root_url: &str,
    event_tx: &mpsc::Sender<MaliciousSvnServerResponseEvent>,
) {
    if stream
        .set_nonblocking(false)
        .and_then(|_| stream.set_read_timeout(Some(Duration::from_secs(5))))
        .and_then(|_| stream.set_write_timeout(Some(Duration::from_secs(5))))
        .is_err()
    {
        return;
    }

    if let Err(error) = write_svn_protocol_item(stream, svn_server_greeting().as_str()) {
        let _ = event_tx.send(MaliciousSvnServerResponseEvent::ConnectionError(format!(
            "write greeting: {error}"
        )));
        return;
    }
    let _ = event_tx.send(MaliciousSvnServerResponseEvent::GreetingSent);

    if let Err(error) = read_svn_protocol_item(stream) {
        let _ = event_tx.send(MaliciousSvnServerResponseEvent::ConnectionError(format!(
            "read client response: {error}"
        )));
        return;
    }
    let _ = event_tx.send(MaliciousSvnServerResponseEvent::ClientResponseReceived);

    if let Err(error) = write_svn_protocol_item(stream, svn_no_auth_request().as_str()) {
        let _ = event_tx.send(MaliciousSvnServerResponseEvent::ConnectionError(format!(
            "write auth request: {error}"
        )));
        return;
    }
    let _ = event_tx.send(MaliciousSvnServerResponseEvent::AuthRequestSent);

    if write_svn_protocol_item(
        stream,
        svn_repos_info(repository_uuid, repository_root_url).as_str(),
    )
    .map_err(|error| {
        let _ = event_tx.send(MaliciousSvnServerResponseEvent::ConnectionError(format!(
            "write repos info: {error}"
        )));
        error
    })
    .is_err()
    {
        return;
    }
    let _ = event_tx.send(MaliciousSvnServerResponseEvent::ReposInfoSent);

    loop {
        let command = match read_svn_protocol_item(stream) {
            Ok(command) => command,
            Err(error) => {
                let _ = event_tx.send(MaliciousSvnServerResponseEvent::ConnectionError(format!(
                    "read command: {error}"
                )));
                return;
            }
        };
        let Some(command_name) = svn_command_name(&command) else {
            let _ = event_tx.send(MaliciousSvnServerResponseEvent::ConnectionError(
                "parse command name".to_string(),
            ));
            return;
        };
        let _ = event_tx.send(MaliciousSvnServerResponseEvent::MainCommandReceived(
            command_name.clone(),
        ));
        if let Err(error) = write_svn_protocol_item(stream, svn_no_auth_request().as_str()) {
            let _ = event_tx.send(MaliciousSvnServerResponseEvent::ConnectionError(format!(
                "write command auth request: {error}"
            )));
            return;
        }
        if command_name == "log" {
            let _ = stream.write_all(malicious_svn_log_response().as_bytes());
            let _ = stream.flush();
            let _ = event_tx.send(MaliciousSvnServerResponseEvent::MaliciousLogResponseSent);
            return;
        }
        if write_svn_protocol_item(
            stream,
            svn_success_response_for_command(&command_name).as_str(),
        )
        .map_err(|error| {
            let _ = event_tx.send(MaliciousSvnServerResponseEvent::ConnectionError(format!(
                "write command response: {error}"
            )));
            error
        })
        .is_err()
        {
            return;
        }
    }
}

fn write_svn_protocol_item(stream: &mut TcpStream, item: &str) -> io::Result<()> {
    stream.write_all(item.as_bytes())?;
    stream.flush()
}

fn read_svn_protocol_item(stream: &mut TcpStream) -> io::Result<Vec<u8>> {
    let mut item = Vec::new();
    let mut byte = [0_u8; 1];
    let mut depth = 0_i32;
    let mut started = false;
    let mut closed = false;
    while item.len() < 1024 * 1024 {
        match stream.read(&mut byte) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "connection closed before a complete svn protocol item was received",
                ));
            }
            Ok(_) => {
                let value = byte[0];
                item.push(value);
                if value == b'(' {
                    started = true;
                    depth += 1;
                } else if value == b')' {
                    depth -= 1;
                    if started && depth == 0 {
                        closed = true;
                    }
                } else if closed && value.is_ascii_whitespace() {
                    return Ok(item);
                }
            }
            Err(error)
                if error.kind() == io::ErrorKind::WouldBlock
                    || error.kind() == io::ErrorKind::TimedOut =>
            {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "timed out before a complete svn protocol item was received",
                ));
            }
            Err(error) => return Err(error),
        }
    }
    Err(io::Error::new(
        io::ErrorKind::InvalidData,
        "svn protocol item exceeded fixture limit",
    ))
}

fn svn_command_name(item: &[u8]) -> Option<String> {
    let text = String::from_utf8_lossy(item);
    let trimmed = text.trim_start();
    let inner = trimmed.strip_prefix('(')?.trim_start();
    inner.split_whitespace().next().map(str::to_string)
}

fn svn_server_greeting() -> String {
    "( success ( 2 2 ( ) ( edit-pipeline svndiff1 accepts-svndiff2 absent-entries commit-revprops depth log-revprops atomic-revprops partial-replay inherited-props ephemeral-txnprops file-revs-reverse list ) ) ) ".to_string()
}

fn svn_no_auth_request() -> String {
    format!(
        "( success ( ( ) {} ) ) ",
        svn_protocol_string("SubversionR M7l6 malicious svn fixture")
    )
}

fn svn_repos_info(repository_uuid: &str, repository_root_url: &str) -> String {
    format!(
        "( success ( {} {} ( mergeinfo depth log-revprops atomic-revprops ) ) ) ",
        svn_protocol_string(repository_uuid),
        svn_protocol_string(repository_root_url)
    )
}

fn svn_success_response_for_command(command_name: &str) -> String {
    match command_name {
        "get-latest-rev" => "( success ( 2 ) ) ".to_string(),
        "check-path" => "( success ( file ) ) ".to_string(),
        "stat" => "( success ( ( file 0 false 2 ) ) ) ".to_string(),
        "reparent" => "( success ( ) ) ".to_string(),
        _ => "( success ( ) ) ".to_string(),
    }
}

fn malicious_svn_log_response() -> String {
    "( ( ) 2 5:alice 27:2024-01-01T00:00:00.000000Z 999999999:unterminated".to_string()
}

fn svn_protocol_string(value: &str) -> String {
    format!("{}:{} ", value.len(), value)
}

fn assert_malicious_svn_server_response_sequence(events: &[MaliciousSvnServerResponseEvent]) {
    assert!(
        !events
            .iter()
            .any(|event| matches!(event, MaliciousSvnServerResponseEvent::ConnectionError(_))),
        "malicious svn:// fixture should not record connection errors, got {events:?}"
    );
    let position = |expected: &MaliciousSvnServerResponseEvent| {
        events
            .iter()
            .position(|event| event == expected)
            .unwrap_or_else(|| {
                panic!(
                    "malicious svn:// fixture missing expected event {expected:?}, got {events:?}"
                )
            })
    };
    let greeting = position(&MaliciousSvnServerResponseEvent::GreetingSent);
    let client_response = position(&MaliciousSvnServerResponseEvent::ClientResponseReceived);
    let auth_request = position(&MaliciousSvnServerResponseEvent::AuthRequestSent);
    let repos_info = position(&MaliciousSvnServerResponseEvent::ReposInfoSent);
    let log_command = position(&MaliciousSvnServerResponseEvent::MainCommandReceived(
        "log".to_string(),
    ));
    let malicious_response = position(&MaliciousSvnServerResponseEvent::MaliciousLogResponseSent);

    assert!(
        greeting < client_response
            && client_response < auth_request
            && auth_request < repos_info
            && repos_info < log_command
            && log_command < malicious_response,
        "malicious svn:// fixture events should follow greeting/client/auth/repos/log/malicious-response order, got {events:?}"
    );
}

struct HttpdDavFixture {
    temp: TempTree,
    seed_wc: PathBuf,
    port: u16,
    server: Child,
    stdout: PathBuf,
    stderr: PathBuf,
    error_log: PathBuf,
}

impl HttpdDavFixture {
    fn create(httpd_stage: &Path, openssl: &Path, svnadmin: &PathBuf, svn: &PathBuf) -> Self {
        assert_staged_httpd_dav_stage(httpd_stage);
        assert_staged_openssl(openssl);

        let temp = TempTree::create();
        let repo = temp.path.join("repo");
        let seed_wc = temp.path.join("seed-wc");
        let repo_url = file_url(&repo);
        let trunk_url = format!("{repo_url}/trunk");

        run_tool(svnadmin, ["create".as_ref(), repo.as_os_str()]);
        run_tool(
            svn,
            [
                "mkdir".as_ref(),
                trunk_url.as_ref(),
                "-m".as_ref(),
                "create HTTPS DAV trunk".as_ref(),
                "--non-interactive".as_ref(),
            ],
        );
        run_tool(
            svn,
            [
                "checkout".as_ref(),
                trunk_url.as_ref(),
                seed_wc.as_os_str(),
                "--non-interactive".as_ref(),
            ],
        );
        fs::write(seed_wc.join("tracked.txt"), "served over https dav\n")
            .expect("HTTPS DAV fixture file should be written");
        run_tool(
            svn,
            [
                "add".as_ref(),
                seed_wc.join("tracked.txt").as_os_str(),
                "--non-interactive".as_ref(),
            ],
        );
        run_tool(
            svn,
            [
                "commit".as_ref(),
                seed_wc.join("tracked.txt").as_os_str(),
                "-m".as_ref(),
                "add HTTPS DAV fixture file".as_ref(),
                "--non-interactive".as_ref(),
            ],
        );

        let openssl_config = temp.path.join("openssl.cnf");
        fs::write(&openssl_config, fixture_openssl_config())
            .expect("OpenSSL HTTPS DAV fixture config should be written");
        let cert = temp.path.join("cert.pem");
        let key = temp.path.join("key.pem");
        generate_fixture_certificate(openssl, &temp.path, &openssl_config);
        assert!(
            cert.is_file(),
            "HTTPS DAV fixture certificate should be generated"
        );
        assert!(
            key.is_file(),
            "HTTPS DAV fixture private key should be generated"
        );

        let port = reserve_loopback_port();
        let logs = temp.path.join("logs");
        fs::create_dir_all(&logs).expect("HTTPS DAV fixture log directory should be created");
        let config_path = temp.path.join("httpd-dav-https.conf");
        let error_log = logs.join("error.log");
        let access_log = logs.join("access.log");
        let pid_file = temp.path.join("httpd.pid");
        let session_cache = temp.path.join("ssl-session-cache");
        let config = format!(
            "ServerRoot \"{}\"\n\
ServerName localhost\n\
Listen 127.0.0.1:{port} https\n\
PidFile \"{}\"\n\
ErrorLog \"{}\"\n\
CustomLog \"{}\" common\n\
Mutex default\n\
LoadModule authn_core_module modules/mod_authn_core.so\n\
LoadModule authz_core_module modules/mod_authz_core.so\n\
LoadModule authz_host_module modules/mod_authz_host.so\n\
LoadModule log_config_module modules/mod_log_config.so\n\
LoadModule socache_shmcb_module modules/mod_socache_shmcb.so\n\
LoadModule ssl_module modules/mod_ssl.so\n\
LoadModule dav_module modules/mod_dav.so\n\
LoadModule dav_svn_module modules/mod_dav_svn.so\n\
LoadModule authz_svn_module modules/mod_authz_svn.so\n\
SSLSessionCache \"shmcb:{}(512000)\"\n\
SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1\n\
<VirtualHost 127.0.0.1:{port}>\n\
  SSLEngine on\n\
  SSLCertificateFile \"{}\"\n\
  SSLCertificateKeyFile \"{}\"\n\
  <Location /svn>\n\
    DAV svn\n\
    SVNPath \"{}\"\n\
    Require all granted\n\
  </Location>\n\
</VirtualHost>\n",
            apache_path(httpd_stage),
            apache_path(&pid_file),
            apache_path(&error_log),
            apache_path(&access_log),
            apache_path(&session_cache),
            apache_path(&cert),
            apache_path(&key),
            apache_path(&repo)
        );
        fs::write(&config_path, config).expect("HTTPS DAV httpd config should be written");

        let httpd = httpd_stage.join("bin").join("httpd.exe");
        let syntax_output = Command::new(&httpd)
            .args(["-t", "-d"])
            .arg(httpd_stage.as_os_str())
            .arg("-f")
            .arg(config_path.as_os_str())
            .current_dir(httpd_stage.join("bin"))
            .env("PATH", httpd_runtime_path(httpd_stage))
            .output()
            .expect("staged Apache HTTP Server should run syntax check");
        if !syntax_output.status.success() {
            panic!(
                "Apache HTTPS DAV fixture syntax check failed with status {}\nstdout:\n{}\nstderr:\n{}\nconfig:\n{}",
                syntax_output.status,
                String::from_utf8_lossy(&syntax_output.stdout),
                String::from_utf8_lossy(&syntax_output.stderr),
                fs::read_to_string(&config_path).unwrap_or_default()
            );
        }

        let stdout = logs.join("httpd.stdout");
        let stderr = logs.join("httpd.stderr");
        let mut server = Command::new(&httpd)
            .arg("-X")
            .arg("-d")
            .arg(httpd_stage.as_os_str())
            .arg("-f")
            .arg(config_path.as_os_str())
            .current_dir(httpd_stage.join("bin"))
            .env("PATH", httpd_runtime_path(httpd_stage))
            .stdin(Stdio::null())
            .stdout(Stdio::from(
                fs::File::create(&stdout).expect("HTTPD fixture stdout log should be created"),
            ))
            .stderr(Stdio::from(
                fs::File::create(&stderr).expect("HTTPD fixture stderr log should be created"),
            ))
            .spawn()
            .expect("staged Apache HTTP Server HTTPS DAV fixture should start");
        let readiness_config = temp.path.join("readiness-config");
        if let Err(error) = wait_for_httpd_dav(
            svn,
            port,
            &readiness_config,
            &mut server,
            &stdout,
            &stderr,
            &error_log,
        ) {
            let _ = server.kill();
            let _ = server.wait();
            panic!("{error}");
        }

        Self {
            temp,
            seed_wc,
            port,
            server,
            stdout,
            stderr,
            error_log,
        }
    }

    fn trunk_url(&self) -> String {
        format!("https://127.0.0.1:{}/svn/trunk", self.port)
    }

    fn port(&self) -> u16 {
        self.port
    }

    fn checkout(&self, svn: &PathBuf, name: &str) -> PathBuf {
        let checkout = self.temp.path.join(name);
        let config_dir = self.temp.path.join(format!("{name}-config"));
        let url = self.trunk_url();
        run_tool(
            svn,
            [
                "checkout".as_ref(),
                url.as_ref(),
                checkout.as_os_str(),
                "--trust-server-cert-failures".as_ref(),
                "unknown-ca,cn-mismatch,expired,not-yet-valid,other".as_ref(),
                "--no-auth-cache".as_ref(),
                "--non-interactive".as_ref(),
                "--config-dir".as_ref(),
                config_dir.as_os_str(),
            ],
        );
        checkout
    }

    fn commit_seed_file(&self, svn: &PathBuf, relative_path: &str, content: &str, message: &str) {
        let path = self.seed_wc.join(relative_path);
        fs::write(&path, content).expect("HTTPS DAV seed file should be updated");
        run_tool(
            svn,
            [
                "commit".as_ref(),
                path.as_os_str(),
                "-m".as_ref(),
                message.as_ref(),
                "--non-interactive".as_ref(),
            ],
        );
    }
}

impl Drop for HttpdDavFixture {
    fn drop(&mut self) {
        let _ = self.server.kill();
        let _ = self.server.wait();
        let _ = fs::read(&self.stdout);
        let _ = fs::read(&self.stderr);
        let _ = fs::read(&self.error_log);
        let _ = &self.temp;
    }
}

struct MaliciousDavXmlFixture {
    port: u16,
    records: mpsc::Receiver<MaliciousDavRequestRecord>,
    stop: mpsc::Sender<()>,
    malicious_enabled: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}

#[derive(Debug)]
struct MaliciousDavRequestRecord {
    method: String,
    served_malicious_xml: bool,
}

impl MaliciousDavXmlFixture {
    fn create(repository_uuid: &str) -> Self {
        let listener = TcpListener::bind(("127.0.0.1", 0))
            .expect("malicious DAV/XML fixture should bind a loopback port");
        listener
            .set_nonblocking(true)
            .expect("malicious DAV/XML listener should become nonblocking");
        let port = listener
            .local_addr()
            .expect("malicious DAV/XML fixture should have a local address")
            .port();
        let (record_tx, record_rx) = mpsc::channel();
        let (stop_tx, stop_rx) = mpsc::channel();
        let repository_uuid = repository_uuid.to_string();
        let malicious_enabled = Arc::new(AtomicBool::new(false));
        let thread_malicious_enabled = Arc::clone(&malicious_enabled);

        let thread = thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(15);
            loop {
                if stop_rx.try_recv().is_ok() || Instant::now() >= deadline {
                    break;
                }
                match listener.accept() {
                    Ok((mut stream, _peer)) => {
                        let handler_record_tx = record_tx.clone();
                        let handler_repository_uuid = repository_uuid.clone();
                        let handler_malicious_enabled = Arc::clone(&thread_malicious_enabled);
                        thread::spawn(move || {
                            if let Some(record) = handle_malicious_dav_connection(
                                &mut stream,
                                handler_repository_uuid.as_str(),
                                &handler_malicious_enabled,
                            ) {
                                let _ = handler_record_tx.send(record);
                            }
                        });
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(10));
                    }
                    Err(_) => break,
                }
            }
        });

        Self {
            port,
            records: record_rx,
            stop: stop_tx,
            malicious_enabled,
            thread: Some(thread),
        }
    }

    fn repository_root_url(&self) -> String {
        format!("http://127.0.0.1:{}/repo", self.port)
    }

    fn enable_malicious_xml(&self) {
        self.malicious_enabled.store(true, Ordering::SeqCst);
    }

    fn observed_methods(&self) -> Vec<String> {
        self.observed_records()
            .into_iter()
            .map(|record| record.method)
            .collect()
    }

    fn observed_records(&self) -> Vec<MaliciousDavRequestRecord> {
        let deadline = Instant::now() + Duration::from_millis(500);
        let mut records = Vec::new();
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break;
            }
            match self
                .records
                .recv_timeout(remaining.min(Duration::from_millis(50)))
            {
                Ok(record) => records.push(record),
                Err(mpsc::RecvTimeoutError::Timeout) if !records.is_empty() => break,
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
        }
        records
    }
}

impl Drop for MaliciousDavXmlFixture {
    fn drop(&mut self) {
        let _ = self.stop.send(());
        let _ = TcpStream::connect(("127.0.0.1", self.port));
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn handle_malicious_dav_connection(
    stream: &mut TcpStream,
    repository_uuid: &str,
    malicious_enabled: &AtomicBool,
) -> Option<MaliciousDavRequestRecord> {
    let request = read_http_request(stream).ok().flatten()?;
    let method = http_request_method(&request)?;
    let served_malicious_xml = method != "OPTIONS" && malicious_enabled.load(Ordering::SeqCst);
    let response = if method == "OPTIONS" {
        malicious_dav_options_response(repository_uuid)
    } else if served_malicious_xml {
        malicious_dav_xml_response()
    } else {
        valid_dav_xml_response(repository_uuid)
    };
    let _ = stream.write_all(response.as_bytes());
    let _ = stream.flush();
    Some(MaliciousDavRequestRecord {
        method,
        served_malicious_xml,
    })
}

fn read_http_request(stream: &mut TcpStream) -> io::Result<Option<Vec<u8>>> {
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    let mut request = Vec::new();
    let mut buffer = [0_u8; 1024];
    let header_end = loop {
        if let Some(header_end) = http_header_end(&request) {
            break header_end;
        }
        if request.len() >= 64 * 1024 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "HTTP request headers exceeded fixture limit",
            ));
        }
        match stream.read(&mut buffer) {
            Ok(0) if request.is_empty() => return Ok(None),
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "connection closed before full HTTP request headers were received",
                ));
            }
            Ok(count) => request.extend_from_slice(&buffer[..count]),
            Err(error)
                if error.kind() == io::ErrorKind::WouldBlock
                    || error.kind() == io::ErrorKind::TimedOut =>
            {
                if request.is_empty() {
                    return Ok(None);
                }
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "timed out before full HTTP request headers were received",
                ));
            }
            Err(error) => return Err(error),
        }
    };
    if request.is_empty() {
        return Ok(None);
    }
    let content_length = http_content_length(&request[..header_end + 4])?;
    let total_len = header_end + 4 + content_length;
    if total_len > 1024 * 1024 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "HTTP request body exceeded fixture limit",
        ));
    }
    while request.len() < total_len {
        match stream.read(&mut buffer) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "connection closed before full HTTP request body was received",
                ));
            }
            Ok(count) => request.extend_from_slice(&buffer[..count]),
            Err(error)
                if error.kind() == io::ErrorKind::WouldBlock
                    || error.kind() == io::ErrorKind::TimedOut =>
            {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "timed out before full HTTP request body was received",
                ));
            }
            Err(error) => return Err(error),
        }
    }
    request.truncate(total_len);
    Ok(Some(request))
}

fn http_header_end(request: &[u8]) -> Option<usize> {
    request.windows(4).position(|window| window == b"\r\n\r\n")
}

fn http_content_length(headers: &[u8]) -> io::Result<usize> {
    let text = String::from_utf8_lossy(headers);
    for line in text.lines().skip(1) {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        if name.eq_ignore_ascii_case("content-length") {
            return value.trim().parse::<usize>().map_err(|_| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "HTTP Content-Length header is not a valid unsigned integer",
                )
            });
        }
    }
    Ok(0)
}

fn http_request_method(request: &[u8]) -> Option<String> {
    let text = String::from_utf8_lossy(request);
    text.lines()
        .next()
        .and_then(|line| line.split_whitespace().next())
        .map(str::to_string)
}

fn malicious_dav_options_response(repository_uuid: &str) -> String {
    let body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n\
<D:options-response xmlns:D=\"DAV:\">\n\
  <D:activity-collection-set>\n\
    <D:href>/repo/!svn/act</D:href>\n\
  </D:activity-collection-set>\n\
</D:options-response>\n";
    [
        "HTTP/1.1 200 OK",
        "Server: SubversionR-malicious-dav-xml-fixture",
        "DAV: 1,2",
        "DAV: version-control,checkout,working-resource",
        "DAV: merge,baseline,activity,version-controlled-collection",
        "DAV: http://subversion.tigris.org/xmlns/dav/svn/depth",
        "DAV: http://subversion.tigris.org/xmlns/dav/svn/log-revprops",
        "DAV: http://subversion.tigris.org/xmlns/dav/svn/atomic-revprops",
        "DAV: http://subversion.tigris.org/xmlns/dav/svn/partial-replay",
        "DAV: http://subversion.tigris.org/xmlns/dav/svn/mergeinfo",
        "MS-Author-Via: DAV",
        "Allow: OPTIONS,GET,HEAD,POST,DELETE,TRACE,PROPFIND,PROPPATCH,COPY,MOVE,LOCK,UNLOCK,CHECKOUT,REPORT",
        "SVN-Youngest-Rev: 1",
        &format!("SVN-Repository-UUID: {repository_uuid}"),
        "SVN-Repository-Root: /repo",
        "SVN-Me-Resource: /repo/!svn/me",
        "SVN-Rev-Root-Stub: /repo/!svn/rvr",
        "SVN-Rev-Stub: /repo/!svn/rev",
        "SVN-Txn-Root-Stub: /repo/!svn/txr",
        "SVN-Txn-Stub: /repo/!svn/txn",
        "SVN-VTxn-Root-Stub: /repo/!svn/vtxr",
        "SVN-VTxn-Stub: /repo/!svn/vtxn",
        "SVN-Relative-Path: trunk",
        "SVN-Repository-MergeInfo: yes",
        "SVN-Allow-Bulk-Updates: Prefer",
        "SVN-Supported-Posts: create-txn",
        "Content-Type: text/xml; charset=utf-8",
        &format!("Content-Length: {}", body.len()),
        "Connection: close",
        "",
        body,
    ]
    .join("\r\n")
}

fn valid_dav_xml_response(repository_uuid: &str) -> String {
    let body = format!(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n\
<D:multistatus xmlns:D=\"DAV:\" xmlns:V=\"http://subversion.tigris.org/xmlns/dav/\">\n\
  <D:response>\n\
    <D:href>/repo/trunk</D:href>\n\
    <D:propstat>\n\
      <D:prop>\n\
        <D:resourcetype><D:collection/></D:resourcetype>\n\
        <D:version-name>1</D:version-name>\n\
        <V:repository-uuid>{repository_uuid}</V:repository-uuid>\n\
        <V:baseline-relative-path>trunk</V:baseline-relative-path>\n\
      </D:prop>\n\
      <D:status>HTTP/1.1 200 OK</D:status>\n\
    </D:propstat>\n\
  </D:response>\n\
</D:multistatus>\n"
    );
    [
        "HTTP/1.1 207 Multi-Status",
        "Server: SubversionR-malicious-dav-xml-fixture",
        "Content-Type: text/xml; charset=utf-8",
        &format!("Content-Length: {}", body.len()),
        "Connection: close",
        "",
        body.as_str(),
    ]
    .join("\r\n")
}

fn malicious_dav_xml_response() -> String {
    let body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n\
<!DOCTYPE malicious [\n\
  <!ENTITY xxe SYSTEM \"file:///SubversionR-test-fixture-must-not-be-read\">\n\
]>\n\
<D:multistatus xmlns:D=\"DAV:\" xmlns:S=\"svn:\">\n\
  <D:response>\n\
    <D:href>/repo/trunk</D:href>\n\
    <D:propstat>\n\
      <D:prop>\n\
        <D:version-name>&xxe;</D:version-name>\n\
        <S:malformed>unterminated";
    [
        "HTTP/1.1 207 Multi-Status",
        "Server: SubversionR-malicious-dav-xml-fixture",
        "Content-Type: text/xml; charset=utf-8",
        &format!("Content-Length: {}", body.len()),
        "Connection: close",
        "",
        body,
    ]
    .join("\r\n")
}

struct TlsEndpointFixture {
    temp: TempTree,
    port: u16,
    server: Child,
    stdout: PathBuf,
    stderr: PathBuf,
}

impl TlsEndpointFixture {
    fn create(openssl: &Path) -> Self {
        assert_staged_openssl(openssl);

        let temp = TempTree::create();
        let config = temp.path.join("openssl.cnf");
        fs::write(&config, fixture_openssl_config())
            .expect("OpenSSL fixture config should be written");
        let cert = temp.path.join("cert.pem");
        let key = temp.path.join("key.pem");
        generate_fixture_certificate(openssl, &temp.path, &config);
        assert!(cert.is_file(), "fixture certificate should be generated");
        assert!(key.is_file(), "fixture private key should be generated");

        let port = reserve_loopback_port();
        let stdout = temp.path.join("openssl-s_server.stdout");
        let stderr = temp.path.join("openssl-s_server.stderr");
        let mut server = Command::new(openssl)
            .args([
                "s_server",
                "-accept",
                &port.to_string(),
                "-cert",
                "cert.pem",
                "-key",
                "key.pem",
                "-www",
            ])
            .current_dir(&temp.path)
            .env("OPENSSL_CONF", &config)
            .stdin(Stdio::null())
            .stdout(Stdio::from(
                fs::File::create(&stdout).expect("OpenSSL server stdout log should be created"),
            ))
            .stderr(Stdio::from(
                fs::File::create(&stderr).expect("OpenSSL server stderr log should be created"),
            ))
            .spawn()
            .expect("staged OpenSSL s_server fixture should start");
        if let Err(error) = wait_for_tls_server(port, &mut server, &stdout, &stderr) {
            let _ = server.kill();
            let _ = server.wait();
            panic!("{error}");
        }

        Self {
            temp,
            port,
            server,
            stdout,
            stderr,
        }
    }

    fn url(&self) -> String {
        format!("https://127.0.0.1:{}/repo/trunk", self.port)
    }

    fn port(&self) -> u16 {
        self.port
    }
}

impl Drop for TlsEndpointFixture {
    fn drop(&mut self) {
        let _ = self.server.kill();
        let _ = self.server.wait();
        let _ = fs::read(&self.stdout);
        let _ = fs::read(&self.stderr);
        let _ = &self.temp;
    }
}

struct RecordingAuthBroker {
    username: String,
    secret: String,
    credential_requests: Vec<CredentialRequest>,
    certificate_requests: Vec<CertificateTrustRequest>,
    certificate_mode: RecordingCertificateMode,
}

enum RecordingCertificateMode {
    Unexpected,
    Reject,
    Trust,
}

impl RecordingAuthBroker {
    fn new(username: &str, secret: &str) -> Self {
        Self {
            username: username.to_string(),
            secret: secret.to_string(),
            credential_requests: Vec::new(),
            certificate_requests: Vec::new(),
            certificate_mode: RecordingCertificateMode::Unexpected,
        }
    }

    fn reject_certificates() -> Self {
        Self {
            username: String::new(),
            secret: String::new(),
            credential_requests: Vec::new(),
            certificate_requests: Vec::new(),
            certificate_mode: RecordingCertificateMode::Reject,
        }
    }

    fn trust_certificates() -> Self {
        Self {
            username: String::new(),
            secret: String::new(),
            credential_requests: Vec::new(),
            certificate_requests: Vec::new(),
            certificate_mode: RecordingCertificateMode::Trust,
        }
    }
}

impl AuthRequestBroker for RecordingAuthBroker {
    fn request_credential(
        &mut self,
        request: CredentialRequest,
    ) -> Result<CredentialResponse, BridgeFailure> {
        self.credential_requests.push(request.clone());
        Ok(CredentialResponse::Provide {
            request_id: request.request_id,
            credential: Credential {
                username: Some(self.username.clone()),
                secret: self.secret.clone(),
            },
            persistence: "session".to_string(),
        })
    }

    fn request_certificate_trust(
        &mut self,
        request: CertificateTrustRequest,
    ) -> Result<CertificateTrustResponse, BridgeFailure> {
        self.certificate_requests.push(request.clone());
        match self.certificate_mode {
            RecordingCertificateMode::Unexpected => Err(BridgeFailure::new(
                "SUBVERSIONR_TEST_UNEXPECTED_CERTIFICATE_REQUEST",
                "auth",
                "error.auth.unexpectedCertificateRequest",
                serde_json::json!({}),
                false,
            )),
            RecordingCertificateMode::Reject => Ok(CertificateTrustResponse::Reject {
                request_id: request.request_id,
                error: CertificateTrustError {
                    code: "SUBVERSIONR_CERTIFICATE_REJECTED".to_string(),
                    category: "auth".to_string(),
                    message_key: "error.auth.certificateRejected".to_string(),
                    args: serde_json::json!({}),
                    retryable: false,
                },
            }),
            RecordingCertificateMode::Trust => Ok(CertificateTrustResponse::Trust {
                request_id: request.request_id,
                trust: "once".to_string(),
                fingerprint: request.fingerprint,
                fingerprint_algorithm: request.fingerprint_algorithm,
            }),
        }
    }
}

struct TempTree {
    path: PathBuf,
}

#[derive(Default)]
struct CancelOnFirstCheck {
    checks: AtomicUsize,
}

impl CancelOnFirstCheck {
    fn check_count(&self) -> usize {
        self.checks.load(Ordering::SeqCst)
    }
}

impl BridgeCancellationToken for CancelOnFirstCheck {
    fn is_cancelled(&self) -> bool {
        self.checks.fetch_add(1, Ordering::SeqCst);
        true
    }
}

struct CancelAfterChecks {
    cancel_after: usize,
    checks: AtomicUsize,
}

impl CancelAfterChecks {
    fn new(cancel_after: usize) -> Self {
        Self {
            cancel_after,
            checks: AtomicUsize::new(0),
        }
    }

    fn check_count(&self) -> usize {
        self.checks.load(Ordering::SeqCst)
    }
}

impl BridgeCancellationToken for CancelAfterChecks {
    fn is_cancelled(&self) -> bool {
        self.checks.fetch_add(1, Ordering::SeqCst) + 1 >= self.cancel_after
    }
}

impl TempTree {
    fn create() -> Self {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time should be after Unix epoch")
            .as_nanos();
        let path = env::temp_dir().join(format!(
            "subversionr-native-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir_all(&path).expect("fixture temp directory should be created");
        Self { path }
    }
}

impl Drop for TempTree {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

fn native_bridge_path() -> PathBuf {
    env::var_os("SUBVERSIONR_TEST_BRIDGE_DLL")
        .map(PathBuf::from)
        .expect("SUBVERSIONR_TEST_BRIDGE_DLL is required for the native bridge integration test")
}

fn native_openssl_path() -> PathBuf {
    env::var_os("SUBVERSIONR_TEST_OPENSSL_EXE")
        .map(PathBuf::from)
        .expect(
            "SUBVERSIONR_TEST_OPENSSL_EXE is required for the HTTPS certificate native bridge test",
        )
}

fn native_httpd_dav_stage_path() -> PathBuf {
    env::var_os("SUBVERSIONR_TEST_HTTPD_DAV_STAGE")
        .map(PathBuf::from)
        .expect("SUBVERSIONR_TEST_HTTPD_DAV_STAGE is required for the HTTPS DAV native bridge test")
}

fn assert_staged_openssl(openssl: &Path) {
    assert!(
        openssl.is_file(),
        "SUBVERSIONR_TEST_OPENSSL_EXE must point at the staged OpenSSL executable"
    );
    let output = Command::new(openssl)
        .arg("version")
        .output()
        .expect("staged OpenSSL should report its version");
    assert!(
        output.status.success(),
        "staged OpenSSL version probe failed with status {}\nstdout:\n{}\nstderr:\n{}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let version = String::from_utf8_lossy(&output.stdout);
    assert!(
        version.starts_with("OpenSSL 3.5.7 "),
        "SUBVERSIONR_TEST_OPENSSL_EXE must be the staged OpenSSL 3.5.7 executable, got {version}"
    );
}

fn assert_staged_httpd_dav_stage(stage: &Path) {
    assert!(
        stage.is_dir(),
        "SUBVERSIONR_TEST_HTTPD_DAV_STAGE must point at the staged Apache HTTPD/Subversion DAV runtime"
    );
    for required_file in [
        "bin/httpd.exe",
        "modules/mod_ssl.so",
        "modules/mod_dav.so",
        "modules/mod_dav_svn.so",
        "modules/mod_authz_svn.so",
        "bin/libsvn_repos-1.dll",
        "bin/libsvn_fs-1.dll",
        "bin/libsvn_subr-1.dll",
        "subversionr-httpd-subversion-dav-stage-manifest.json",
    ] {
        assert!(
            stage.join(required_file).is_file(),
            "SUBVERSIONR_TEST_HTTPD_DAV_STAGE is missing required HTTPS DAV runtime file: {}",
            stage.join(required_file).display()
        );
    }
}

fn native_test_guard() -> MutexGuard<'static, ()> {
    NATIVE_TEST_MUTEX
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn bridge_tool_dir(bridge_path: &Path) -> PathBuf {
    bridge_path
        .parent()
        .expect("bridge DLL path should have a parent directory")
        .to_path_buf()
}

fn apache_path(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

fn httpd_runtime_path(stage: &Path) -> OsString {
    env::join_paths([stage.join("bin"), stage.join("modules")])
        .expect("HTTPD fixture runtime PATH should be joinable")
}

fn fixture_openssl_config() -> &'static str {
    "[req]\n\
default_bits = 2048\n\
prompt = no\n\
distinguished_name = dn\n\
x509_extensions = v3_req\n\
\n\
[dn]\n\
CN = localhost\n\
\n\
[v3_req]\n\
basicConstraints = critical,CA:false\n\
keyUsage = critical,digitalSignature,keyEncipherment\n\
extendedKeyUsage = serverAuth\n\
subjectAltName = @alt_names\n\
\n\
[alt_names]\n\
DNS.1 = localhost\n\
IP.1 = 127.0.0.1\n"
}

fn generate_fixture_certificate(openssl: &Path, working_dir: &Path, config: &Path) {
    let output = Command::new(openssl)
        .args([
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            "key.pem",
            "-out",
            "cert.pem",
            "-days",
            "1",
            "-config",
            "openssl.cnf",
        ])
        .current_dir(working_dir)
        .env("OPENSSL_CONF", config)
        .output()
        .expect("staged OpenSSL should run for fixture certificate generation");
    if !output.status.success() {
        panic!(
            "OpenSSL fixture certificate generation failed with status {}\nstdout:\n{}\nstderr:\n{}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

fn reserve_loopback_port() -> u16 {
    let listener = TcpListener::bind(("127.0.0.1", 0))
        .expect("ephemeral loopback port should be reservable for svnserve fixture");
    let port = listener
        .local_addr()
        .expect("loopback listener should have a local address")
        .port();
    drop(listener);
    port
}

fn wait_for_tls_server(
    port: u16,
    server: &mut Child,
    stdout: &Path,
    stderr: &Path,
) -> Result<(), String> {
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(status) = server
            .try_wait()
            .map_err(|error| format!("OpenSSL server fixture status check failed: {error}"))?
        {
            return Err(format!(
                "OpenSSL server fixture exited before accepting TLS connections with status {status}\nstdout:\n{}\nstderr:\n{}",
                fs::read_to_string(stdout).unwrap_or_default(),
                fs::read_to_string(stderr).unwrap_or_default()
            ));
        }

        if TcpStream::connect(("127.0.0.1", port)).is_ok() {
            return Ok(());
        }

        if std::time::Instant::now() >= deadline {
            return Err(format!(
                "OpenSSL server fixture did not accept TLS connections on 127.0.0.1:{port}\nstdout:\n{}\nstderr:\n{}",
                fs::read_to_string(stdout).unwrap_or_default(),
                fs::read_to_string(stderr).unwrap_or_default()
            ));
        }
        thread::sleep(Duration::from_millis(25));
    }
}

fn wait_for_httpd_dav(
    svn: &PathBuf,
    port: u16,
    config_dir: &Path,
    server: &mut Child,
    stdout: &Path,
    stderr: &Path,
    error_log: &Path,
) -> Result<(), String> {
    let url = format!("https://127.0.0.1:{port}/svn/trunk");
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(status) = server
            .try_wait()
            .map_err(|error| format!("HTTPD DAV fixture status check failed: {error}"))?
        {
            return Err(format!(
                "HTTPD DAV fixture exited before accepting HTTPS SVN requests with status {status}\nstdout:\n{}\nstderr:\n{}\nerror_log:\n{}",
                fs::read_to_string(stdout).unwrap_or_default(),
                fs::read_to_string(stderr).unwrap_or_default(),
                fs::read_to_string(error_log).unwrap_or_default()
            ));
        }

        let output = run_tool_output(
            svn,
            [
                "info".as_ref(),
                url.as_ref(),
                "--trust-server-cert-failures".as_ref(),
                "unknown-ca,cn-mismatch,expired,not-yet-valid,other".as_ref(),
                "--no-auth-cache".as_ref(),
                "--non-interactive".as_ref(),
                "--config-dir".as_ref(),
                config_dir.as_os_str(),
            ],
        );
        if output.status.success() {
            return Ok(());
        }

        if std::time::Instant::now() >= deadline {
            return Err(format!(
                "HTTPD DAV fixture did not accept HTTPS SVN info requests on 127.0.0.1:{port}\nstdout:\n{}\nstderr:\n{}\nhttpd_stdout:\n{}\nhttpd_stderr:\n{}\nerror_log:\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr),
                fs::read_to_string(stdout).unwrap_or_default(),
                fs::read_to_string(stderr).unwrap_or_default(),
                fs::read_to_string(error_log).unwrap_or_default()
            ));
        }
        thread::sleep(Duration::from_millis(50));
    }
}

fn wait_for_svnserve(
    svn: &PathBuf,
    port: u16,
    config_dir: &Path,
    server: &mut Child,
) -> Result<(), String> {
    let url = format!("svn://127.0.0.1:{port}/repo/trunk");
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(status) = server
            .try_wait()
            .map_err(|error| format!("svnserve fixture status check failed: {error}"))?
        {
            return Err(format!(
                "svnserve fixture exited before accepting authenticated info request with status {status}"
            ));
        }

        let output = run_tool_output(
            svn,
            [
                "info".as_ref(),
                url.as_ref(),
                "--username".as_ref(),
                "alice".as_ref(),
                "--password".as_ref(),
                "secret".as_ref(),
                "--no-auth-cache".as_ref(),
                "--non-interactive".as_ref(),
                "--config-dir".as_ref(),
                config_dir.as_os_str(),
            ],
        );
        if output.status.success() {
            return Ok(());
        }

        if std::time::Instant::now() >= deadline {
            return Err(format!(
                "svnserve fixture did not accept authenticated info request on 127.0.0.1:{port}\nstdout:\n{}\nstderr:\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            ));
        }
        thread::sleep(Duration::from_millis(25));
    }
}

fn run_tool<const N: usize>(tool: &PathBuf, args: [&OsStr; N]) {
    let output = run_tool_output(tool, args);
    if !output.status.success() {
        panic!(
            "{} failed with status {}\nstdout:\n{}\nstderr:\n{}",
            tool.display(),
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

fn run_tool_output<const N: usize>(tool: &PathBuf, args: [&OsStr; N]) -> std::process::Output {
    Command::new(tool)
        .args(args)
        .output()
        .expect("staged Subversion fixture tool should run")
}

fn raw_revision_author<const N: usize>(
    svn: &PathBuf,
    repository_url: &str,
    revision: i64,
    additional_args: [&OsStr; N],
) -> String {
    let revision = revision.to_string();
    let output = Command::new(svn)
        .args(["propget", "--revprop", "-r"])
        .arg(&revision)
        .args(["svn:author", repository_url])
        .args(additional_args)
        .output()
        .expect("staged SVN client should read the raw revision author");
    assert!(
        output.status.success(),
        "svn:author lookup for r{revision} failed with status {}\nstdout:\n{}\nstderr:\n{}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("svn:author should be valid UTF-8")
        .trim_end_matches(['\r', '\n'])
        .to_string()
}

fn file_url(path: &Path) -> String {
    format!(
        "file:///{}",
        path.to_string_lossy()
            .replace('\\', "/")
            .trim_start_matches('/')
    )
}

fn frame(payload: &str) -> Vec<u8> {
    format!("Content-Length: {}\r\n\r\n{payload}", payload.len()).into_bytes()
}

fn decode_frames(output: &[u8]) -> io::Result<Vec<serde_json::Value>> {
    let mut cursor = 0;
    let mut responses = Vec::new();
    while cursor < output.len() {
        let header_end = output[cursor..]
            .windows(4)
            .position(|window| window == b"\r\n\r\n")
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

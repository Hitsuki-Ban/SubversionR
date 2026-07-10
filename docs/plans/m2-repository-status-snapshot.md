# M2 Repository And Status Snapshot Plan

## Goal

Implement the first stateful repository session contract and a local-only status snapshot path backed by the source-built Apache Subversion 1.14.5 `libsvn` runtime.

## Implemented Scope

- `repository/discover` accepts workspace roots and returns discovered working-copy candidates without registering sessions.
- `repository/open` creates a repository session and returns `repositoryId`, `epoch`, and `identity`.
- `repository/close` requires a matching `repositoryId` and `epoch`, removes the session, and invalidates later requests for the closed epoch.
- `status/getSnapshot` requires a matching `repositoryId` and `epoch`, increments the session generation, and returns a complete local-only snapshot.
- Stdio JSON-RPC dispatch keeps a `DaemonState` for the lifetime of the sidecar process, so an open repository session is available to later framed requests.

## Protocol Shape

Repository identity uses:

- `repositoryUuid`
- `repositoryRootUrl`
- `workingCopyRoot`
- `workspaceScopeRoot`
- `format`

Status snapshots use separate local and remote dimensions:

- `repositoryId`
- `epoch`
- `generation`
- `completeness`
- `identity`
- `localEntries`
- `remoteEntries`
- `summary`
- `timestamp`
- `source`

M2 does not perform remote status checks. `remoteEntries` is empty and local entries use `remoteStatus: "notChecked"`.

## Native Gate

The C bridge exposes `subversionr_bridge_status_scan` with a hand-written C ABI that returns bridge-owned status entries and does not expose APR or libsvn types to Rust.

The implementation calls `svn_client_status6` with remote out-of-date checking disabled and working-copy status enabled. Externals are ignored in this first snapshot gate; nested and external repository sessions remain later work.

Rust maps the bridge entries into the protocol model and computes the first local summary:

- local change count
- remote change count, always `0` in M2
- conflict count
- unversioned count

## Gates

- Protocol contract tests serialize the M2 wire fields.
- RPC dispatch tests cover discover without session registration, open epoch creation, close invalidation, stale epoch rejection, and snapshot generation.
- Stdio tests verify session state survives across framed requests.
- Native ignored integration tests rebuild/load the bridge DLL, create a fixture repository and working copy with the staged `svnadmin.exe` and `svn.exe`, modify a tracked file, create an unversioned file, and verify libsvn-derived local status entries.
- Windows CI runs the native bridge integration test after building the Apache Subversion stage and the bridge.

## Lifecycle Follow-up

The first repository lifecycle follow-up closes open VS Code adapter sessions when their working-copy root is explicitly missing:

- `RepositoryLifecycleService.closeDisappearedRepositories` checks currently open sessions through an injected working-copy existence probe and calls `RepositorySessionService.closeRepository` only for roots reported missing.
- Missing-root close success emits an `openSessionClosed` lifecycle event with reason `workingCopyMissing`; close failure emits `openSessionCloseFailed` with the stable error code.
- Existence-check failures emit `openSessionCloseFailed` with reason `workingCopyStatusUnavailable` and do not close the session.
- The VS Code activation path runs disappeared-session cleanup before automatic repository discovery on activation, workspace-trust grant, and workspace-folder changes.
- User-visible missing-root close and close-failure messages are localized in English, Japanese, and Chinese.
- Unit tests cover missing-root close behavior, close-failure reporting, existence-check failure reporting, and runtime localization coverage.

This follow-up does not implement automatic repository re-open after backend restart, backend close failure recovery UX, or installed deletion/move E2E evidence.

## Moved Working Copy Follow-up

The moved working-copy lifecycle follow-up reopens an already tracked repository when its old working-copy root disappears and discovery finds the same SVN repository identity at a new workspace path:

- `RepositoryLifecycleService.recoverMovedRepositories` checks currently open sessions through the same injected working-copy existence probe used by disappeared-session cleanup.
- Trusted workspaces with missing open roots run one repository discovery pass before disappeared-session cleanup.
- Discovery ignores still-existing open roots but does not ignore the missing root, so a moved working copy can be rediscovered at its new path.
- A moved candidate must match the previous session's `repositoryUuid` and `repositoryRootUrl`; the lifecycle service does not guess from path similarity.
- Exactly one identity-matched moved candidate closes the old session and opens the moved candidate with the shared boundary-root planning helper.
- Multiple identity-matched moved candidates fail with a stable `SUBVERSIONR_REPOSITORY_MOVED_CANDIDATE_AMBIGUOUS` event instead of selecting one.
- No identity match leaves the missing session untouched so the existing disappeared-session cleanup can close it as a genuinely missing working copy.
- The VS Code activation path runs moved recovery before disappeared-session cleanup and ordinary automatic open.
- User-visible moved recovery success and failure messages are localized in English, Japanese, and Chinese.
- Unit tests cover identity-matched recovery in a multi-candidate discovery result, no-match preservation for cleanup, ambiguous moved candidates, and runtime localization coverage.

This follow-up does not implement installed deletion/move E2E evidence or richer backend close failure recovery UX after a moved-session close succeeds but moved open fails.

## Repository Lifecycle Recovery UX Follow-up

The repository lifecycle recovery UX follow-up makes close and moved-recovery failures actionable from VS Code notifications:

- `RepositoryLifecycleNotificationService` handles lifecycle notification text through the TypeScript localization layer instead of a non-testable activation-local function.
- Missing working-copy close failures show a `Retry Close` action that reruns disappeared-session cleanup for the same lifecycle trigger.
- Working-copy existence probe failures show a `Retry Check` action that reruns the same disappeared-session cleanup path without closing sessions that still cannot be checked.
- Moved working-copy close failures show a `Retry Recovery` action that reruns identity-based moved recovery while the old missing session is still open.
- Moved working-copy open failures after the old session has already closed show a `Retry Open` action that reruns automatic workspace repository open.
- Retry callback failures surface a stable localized lifecycle retry error code instead of producing an unhandled promise rejection.
- Unit tests cover each retry action path and runtime localization coverage includes the new action labels and retry error message.

This follow-up does not implement installed deletion/move E2E evidence.

## REP-001 Subdirectory Open Evidence Follow-up

The REP-001 release evidence now proves that a workspace opened from inside a working-copy subdirectory is still owned by the parent working-copy provider:

- `crates/subversionr-daemon/tests/native_bridge.rs` includes an ignored real native bridge fixture that creates and commits `wc/src/tracked.txt`, opens `wc/src` through the staged libsvn bridge, and asserts that `workspace_scope_root` remains the requested subdirectory while `working_copy_root` resolves to the parent `wc`.
- `InstalledSourceControlSurfaceReport` records the original open request, its relation to the resolved working-copy root, and provider-resolution assertions for workspace scope, SourceControl root, and subdirectory-to-root ownership.
- The M7j1 installed Source Control surface gate runs the hidden report command once for the working-copy root and once for `wc/src`, then records `sourceControlSubdirectoryOpenReport` in the release evidence JSON.
- `docs/release/requirements-release-evidence.csv` marks `REP-001` verified because the adapter, daemon contract, native bridge fixture, installed VSIX gate, and script tests all cover the subdirectory-open provider acceptance path.

## REP-002 Multi-Root Provider Evidence Follow-up

The REP-002 release evidence now proves that independent working-copy roots can coexist as separate providers:

- `crates/subversionr-daemon/tests/native_bridge.rs` includes an ignored real native bridge JSON-RPC fixture that creates two independent source-built working copies, sends both as `repository/discover.workspaceRoots`, and asserts that two distinct discovery candidates with distinct repository UUIDs and working-copy roots are returned.
- The TypeScript lifecycle/session/projection tests cover multi-root discovery requests, automatic opening for multiple independent unopened candidates, explicit open semantics, and independent `SourceControl` projections for separate repository sessions.
- The M7j3 installed Source Control UI E2E gate opens a second source-built working-copy fixture while the first repository remains open, drives the installed `subversionr.refreshRepository` Quick Pick, selects the second working-copy root, and records that the selected repository is distinct, refreshed, and coexists with the first provider.
- `docs/release/requirements-release-evidence.csv` marks `REP-002` verified because daemon native discovery, adapter lifecycle/provider tests, installed VSIX UI E2E evidence, and script tests all cover the multi-root provider acceptance path.

## Deferred Work

- Dirty-path watcher, targeted status, snapshot deltas, and full reconcile are M3.
- Remote status scheduling and `status/checkRemote` remain separate from ordinary local refresh.
- Externals, nested working-copy boundaries, repository list/summary, and installed move/delete lifecycle evidence are outside this M2 slice.

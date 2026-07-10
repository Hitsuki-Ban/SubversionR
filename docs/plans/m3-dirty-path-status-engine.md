# M3 Dirty-Path Status Engine Plan

## Goal

Build the status engine that turns changed paths into targeted `libsvn` scans, generation-bearing deltas, and low-frequency full reconciliation.

## M3a Implemented Slice

The first M3 slice implements manual targeted local refresh:

- `status/refresh` requires `repositoryId`, `epoch`, and explicit targets.
- Each target uses repository-relative `path`, `depth`, and `reason`.
- The daemon assigns the next session generation; clients never provide generation.
- The repository session keeps an in-memory map of current non-normal local entries.
- `status/getSnapshot` seeds the in-memory map with the latest complete local snapshot.
- `status/refresh` calls a real targeted bridge scan for each target and returns a delta payload.
- A single `.` / `infinity` target is accepted as a manual complete local reconcile.
- Delta coverage includes path, depth, reason, and generation.
- Delta `upsert` contains interesting local entries from the scan.
- Delta `remove` contains cached entries that are covered by the scan and are now normal or absent.
- Delta `summaryDelta` reports signed changes in local, remote, conflict, and unversioned counts.

Remote status remains separate. `status/refresh` does not perform remote checks and local entries continue to use `remoteStatus: "notChecked"`.

## Native Gate

The bridge ABI now exposes `subversionr_bridge_status_scan(runtime, path, depth, snapshot)`.

Rust maps repository-relative targets to paths under the opened working-copy root and passes the requested depth to the bridge. The C bridge maps supported depth words to `svn_depth_t` and calls `svn_client_status6` with:

- `check_out_of_date = FALSE`
- `check_working_copy = TRUE`
- `no_ignore = FALSE`
- `ignore_externals = TRUE`

Native integration verifies that an `empty` scan of a modified tracked file does not return a sibling unversioned file. It also verifies the default ignored-item policy by creating a real `svn:ignore` rule, leaving `ignored.log` and a non-ignored unversioned file in the working copy, and proving the default local snapshot excludes the ignored file without hiding the visible unversioned entry. Backend status classification now treats property-only local changes as interesting local changes in native summaries, initial snapshot session caching, and targeted refresh deltas; this does not implement property diff rendering.

## M3a Invariants

- Missing or malformed refresh targets fail fast.
- Absolute paths, parent-relative paths, empty segments, and drive-qualified paths are rejected.
- Stale or mismatched epochs are rejected.
- Targeted refresh only sweeps entries inside the reported coverage.
- Normal or absent entries inside coverage are removed from the session snapshot map.
- Uncovered paths remain unchanged.
- Delta generation is monotonic per repository session.

## M3b Implemented Slice

The second M3 slice implements the VS Code adapter-side dirty-path core as pure TypeScript modules:

- `watcherEvents` normalizes raw watcher paths, maps create/change/delete event kinds, filters repository-external paths, filters `.svn` internals, and respects configured repository boundaries.
- `DirtyPathSet` stores dirty paths with explicit case policy, merges repeated path events, produces deterministic `status/refresh` targets, and folds overflow to `.` / `infinity` with `watcherOverflow`.
- File changes become `empty` / `fileChanged` targets.
- Create/delete events include both the changed path at `empty` depth and the parent at `immediates` depth.
- `StatusRefreshScheduler` debounces accepted dirty paths, sends explicit refresh requests, clears dirty paths only after success, and preserves them after backend failure.
- `StatusRefreshRpcClient` emits only `status/refresh` and fails fast on empty target lists.
- `DirtyPathPipeline` composes watcher normalization and refresh scheduling without depending on a live VS Code host.

M3b does not apply status deltas to SCM UI, does not start the backend from activation, and does not perform repository scans in the extension host.

## M3c Implemented Slice

The third M3 slice connects the VS Code adapter to the Rust sidecar lifecycle over the existing Content-Length JSON-RPC transport:

- `subversionr.backend.executablePath` and `subversionr.backend.bridgeDllPath` were contributed as machine-scoped settings for the first-stage development build. This path was superseded by M6f packaged backend resource resolution.
- The settings had no default value. Before M6f, missing paths failed fast instead of probing `PATH`, system SVN, TortoiseSVN, or random libsvn locations.
- Before M6f, untrusted workspaces rejected custom backend paths before spawning a process.
- The sidecar is spawned with `shell: false`, `stdio: ["pipe", "pipe", "pipe"]`, `windowsHide: true`, and an explicit `SUBVERSIONR_BRIDGE_DLL` environment value.
- `initialize` is sent with client name, client version, locale, and workspace trust state.
- The initialize response is structurally validated before the connection becomes ready.
- Unsupported protocol major versions and missing required capabilities terminate the just-started process and surface stable protocol errors.
- Startup failure captures bounded stderr diagnostic context without sending final localized prose from Rust.
- `BackendService` coalesces concurrent initialize calls so the Extension Host has one sidecar startup at a time.
- `shutdown` sends a JSON-RPC request before disposing an initialized connection.
- The `subversionr.initialize` command now starts the backend and reports the negotiated libsvn version through the TypeScript localization layer.

M3c does not implement binary signature/hash verification, packaged binary resolution, automatic restart/backoff, degraded-state context keys, shutdown timeout/kill escalation, heartbeat, or full SCM UI binding.

## M3d Implemented Slice

The fourth M3 slice adds the VS Code watcher lifecycle adapter for repository-scoped dirty-path refresh:

- `RepositoryWatcherService` creates one watcher per registered repository scope.
- Watchers are rooted at the normalized working-copy root and use the recursive `**/*` pattern.
- Create/change/delete watcher callbacks are converted into `RawWatcherEvent` values and passed to `DirtyPathPipeline`.
- The existing pipeline still filters `.svn` internals, repository-external paths, and configured nested/external boundaries before scheduling `status/refresh`.
- Duplicate watcher registration fails fast instead of creating multiple watchers for the same repository.
- Watcher creation failure rolls back the pipeline registration so retry does not inherit a half-registered repository.
- `unregisterRepository` and `dispose` remove all event listeners, dispose the watcher, and unregister the dirty-path pipeline scope.
- `createVscodeRepositoryWatcherFactory` is a thin adapter from repository watcher requests to VS Code `createFileSystemWatcher` using a relative pattern.
- The VS Code extension activation now constructs the watcher service with a backend-backed `status/refresh` client but does not register watchers until a repository scope is provided.
- The first-stage activation events stay command-driven for this slice so activation does not depend on probing `.svn/wc.db`; repository-driven activation/discovery is deferred to the repository-open binding.
- `deactivate` disposes repository watchers before shutting down the backend.
- `BackendConnection` exposes a narrow JSON-RPC sender surface so typed status clients can reuse the initialized sidecar connection.
- Unit tests cover event routing, create/delete planner behavior, duplicate registration, rollback, unregister, and bulk disposal.

M3d does not yet bind repository-opened sessions from the extension command to watcher registration, does not surface watcher metrics/diagnostics, and does not implement native watcher overflow notifications.

## M3e Implemented Slice

The fifth M3 slice adds the first VS Code Source Control projection layer:

- `SourceControlResourceStore` maintains per-repository SCM resource groups from accepted status snapshots and refresh deltas.
- The fixed first-pass groups are `Conflicts`, `Changes`, `Unversioned`, `Incoming`, `Externals`, and `Ignored`.
- Local entries are grouped only from backend-provided `StatusEntry` fields. TypeScript does not scan the filesystem, read `wc.db`, or recompute SVN status.
- Conflict entries take priority over external, ignored, unversioned, and regular change grouping.
- Property-only local changes are shown in `Changes`.
- Incoming resources are projected only from `remoteEntries`; ordinary local refresh deltas do not alter incoming resources.
- Refresh deltas update only explicit local `upsert` and `remove` paths in the projection store.
- Projection deltas require matching epoch and a strictly newer generation because deltas are not idempotent.
- `RepositorySessionService` registers the projection when a repository opens and publishes the initial projection only after the canonical status store accepts the initial snapshot.
- `StatusRefreshScheduler` publishes refresh deltas only after the canonical status store accepts the delta.
- `VscodeSourceControlPresenter` is a thin injectable adapter over the VS Code Source Control API. User-visible group labels and resource tooltips go through the TypeScript localization layer.

M3e does not implement SCM resource commands, QuickDiff, commit input behavior, changelist-specific grouping, remote status polling, ignored on-demand scans, external repository providers, context keys, or count policy.

## M3f Implemented Slice

The sixth M3 slice binds repository open and close to explicit development VS Code commands:

- `subversionr.openRepository` discovers SVN working copies from the current workspace folders through the existing `repository/discover` RPC.
- `subversionr.closeRepository` closes repository sessions through `RepositorySessionService.closeRepository`.
- The open command contributes only an explicit command-palette entry. It does not add workspace probing activation or legacy command aliases.
- The close command is contributed to the `scm/title` menu only when `scmProvider == svn-r`.
- Multiple discovered working copies require an explicit Quick Pick selection before opening.
- Multiple open repository sessions require an explicit Quick Pick selection before closing.
- Empty workspaces and empty discovery results fail before opening a session and do not start alternate discovery paths.
- `RepositorySessionService.listOpenSessions()` exposes defensive session copies so command UI does not maintain a second source of lifecycle truth.
- The command path uses the current Windows-first path-case policy. Unsupported platforms fail fast until a reviewed cross-platform filesystem case policy is implemented.
- All command titles and command-result messages pass through the TypeScript localization layer.

M3f does not implement automatic repository discovery on activation, checkout/open-URL empty states, public command-catalog finalization, legacy `svn.*` aliases, QuickDiff, SCM resource commands, or repository list RPC usage.

## M3g Implemented Slice

The seventh M3 slice adds explicit local refresh commands for open repositories:

- `subversionr.refreshRepository` flushes pending dirty paths for the selected open repository through the existing dirty-path pipeline.
- `subversionr.fullReconcile` sends a local `status/refresh` request with `path = "."`, `depth = "infinity"`, and `reason = "manualFullReconcile"`.
- Full reconcile is executed through the same scheduler as dirty-path refresh, clearing pending dirty paths before the root scan and rejecting responses that are not complete root/infinity coverage.
- Full reconcile applies the returned delta to `StatusSnapshotStore` before publishing it to the Source Control projection.
- Multiple open repository sessions require explicit Quick Pick selection before refresh or full reconcile.
- The commands are contributed to the `scm/title` menu only when `scmProvider == svn-r`.
- Command titles are localized through the package NLS bundles, and command-result messages pass through the TypeScript localization layer.
- Full reconcile remains a local status operation. It does not run remote status, poll remotes, inspect TortoiseSVN, use the SVN CLI, or scan from the Extension Host.
- The installed Source Control UI E2E gate executes `subversionr.refreshRepository` against the single open source-built fixture repository, verifies the SourceControl surface remains available through the hidden freshness report path, opens a 64-item modified source-built load fixture and proves modified SourceControl projection before and after manual Refresh, then opens a second source-built fixture repository and captures the multi-repository Refresh Quick Pick before selecting and refreshing the second repository.

M3g does not implement automatic low-frequency reconcile scheduling, stale/partial notifications, installed manual Refresh cancellation evidence, progress UI, large-working-copy performance evidence beyond the 64-item Refresh load fixture, remote status checks, command-catalog finalization, legacy aliases, or QuickDiff.

## M3h Implemented Slice

The eighth M3 slice adds the first Source Control badge count policy:

- `ScmRepositoryProjection` carries a computed `count` value from the Source Control resource store.
- `VscodeSourceControlPresenter` publishes that value to VS Code `SourceControl.count` without recomputing SVN status.
- The default badge count includes local conflicts and versioned local changes.
- Unversioned resources are excluded by default and are included only when `subversionr.status.countUnversioned` is explicitly enabled.
- Ignored resources, externals, and incoming remote resources are not counted.
- Changelists listed in `subversionr.status.ignoreChangelistsInCount` are excluded from the badge count.
- The settings use VS Code `window` scope for the current activation-wide policy.
- The new settings use `subversionr.*` keys only; no legacy `svnNative.*` setting aliases or migration shims are added in this slice.

M3h does not implement command-catalog finalization, SCM resource commands, QuickDiff, changelist-specific groups, remote status polling, stale/partial UI indicators, or compatibility aliases.

## M3i Implemented Slice

The ninth M3 slice adds the first Source Control resource-level local refresh command:

- `subversionr.refreshResource` is contributed only to SubversionR local SCM resource contexts: conflicted, changed, unversioned, external, and ignored.
- The resource command is hidden from the Command Palette because it requires an SCM resource argument.
- Incoming remote resources are intentionally excluded from the menu and rejected by the direct command handler.
- The command resolves its repository only from currently open repository sessions, choosing the most specific working-copy root for nested sessions.
- Single-resource refresh delegates to the existing dirty-path status pipeline and sends one `status/refresh` target with `depth = "empty"` and `reason = "resourceRefresh"`.
- Explicit resource refresh does not drain already pending watcher dirty paths.
- `VscodeSourceControlPresenter` keeps refresh on the resource context menu only; it does not assign a default `SourceControlResourceState.command`, leaving click/open behavior available for QuickDiff/content work.
- The slice does not add legacy `svn.*` or `svnNative.*` command aliases, remote status polling, SVN CLI use, TortoiseSVN use, backend/native changes, or Extension Host repository scans.

M3i does not implement QuickDiff, batch resource operations, SCM resource add/revert/resolve/commit commands, changelist-specific groups, stale/partial UI indicators, or compatibility aliases.

## M3j Implemented Slice

The tenth M3 slice tightens repository-open lifecycle guardrails for nested and external working-copy boundaries:

- `subversionr.openRepository` passes currently open working-copy roots to `repository/discover` as explicit `ignoredRoots`.
- The command path also filters already open discovered candidates locally, so duplicate opens do not depend on backend duplicate-session errors for normal product flow.
- When discovery returns a parent candidate plus nested or external child candidates, opening the parent passes the child working-copy roots as `boundaryRoots` to the repository session.
- `RepositoryDiscoveryService` rejects inconsistent candidate metadata: nested or external candidates must carry `parentWorkingCopyRoot`, while top-level candidates must not.
- `RepositorySessionService` rejects relative boundary roots before backend startup.
- If a backend open succeeds but a boundary root is equal to or outside the opened working-copy root, the session service rolls the backend session back before registering watchers, status storage, or SCM projection.
- Boundary validation uses the selected platform path-case policy and preserves the original backend/discovery root strings when registering watcher scopes.

M3j does not implement daemon-side nested working-copy discovery, file or directory external discovery, automatic repository discovery on activation, repository picker UX, native nested/external fixtures, or installed VS Code lifecycle evidence.

## M3k Implemented Slice

The eleventh M3 slice preserves explicit operation reconcile targets across retryable local-refresh failures:

- `StatusRefreshScheduler.refreshTargets` now requeues explicit operation reconcile targets when the backend `status/refresh` request fails.
- The same targets are requeued when the canonical `StatusSnapshotStore.applyDelta` step rejects the delta.
- The requeued targets are retried by the next repository flush through the existing dirty-path target queue.
- If canonical status accepts the delta and only SCM projection publishing fails, the targets are not requeued, because refresh deltas are generation-bearing and not idempotent after canonical application.
- Tests cover backend failure, canonical store failure, and projection-only failure for operation reconcile targets.

M3k does not implement operation progress, cancellation, native watcher suppression windows, operation journals, backend restart recovery, or user-visible stale/partial status.

## M3l Implemented Slice

The twelfth M3 slice binds trusted-workspace automatic repository discovery to VS Code activation and workspace lifecycle events:

- The extension manifest now activates on `workspaceContains:**/.svn`, not on `*`, `onStartupFinished`, or `.svn/wc.db` internals.
- `RepositoryLifecycleService` gates automatic discovery on VS Code Workspace Trust before starting backend-backed repository discovery.
- Automatic discovery runs for extension activation, newly trusted workspaces, and workspace folder changes.
- The automatic path uses the same discovery request policy as `subversionr.openRepository`: workspace roots, `discoverNested = false`, `discoveryDepth = 4`, no discovery ignore entries, current open sessions as `ignoredRoots`, and lazy externals mode.
- The automatic path filters already open working copies with the shared path-case-aware discovery planning helper.
- A single unopened discovered candidate is opened without prompting.
- Empty results, already open results, and multiple unopened candidates stop with structured lifecycle events instead of prompting or guessing.
- Overlapping automatic runs stop with an `alreadyRunning` lifecycle event while the first discovery/open request remains in flight.
- Discovery and open failures return `autoOpenFailed` lifecycle events so activation does not create unhandled promise failures.
- Manual open and automatic open share boundary-root planning for nested/external child working copies.
- Unit tests cover trust gating, no-workspace gating, single-candidate open, ignored open roots, no candidates, all-open candidates, ambiguous candidates, overlapping automatic runs, failure events, and manifest activation constraints.

M3l does not implement SCM-view-reveal prompts, daemon-side nested/external discovery, installed VS Code activation evidence, repository picker empty-state UX, retry/backoff diagnostics for transient backend startup failure, or cross-platform path-case policy expansion.

## M3m Implemented Slice

The thirteenth M3 slice adds low-frequency local full reconcile scheduling to the dirty-path status engine:

- `StatusRefreshScheduler` accepts an explicit `fullReconcileIntervalMs` option.
- Repositories with that option set schedule a local `.` / `infinity` full reconcile after registration.
- Scheduled full reconcile uses the distinct `scheduledFullReconcile` reason so it remains distinguishable from manual full reconcile evidence.
- Scheduled full reconcile reuses the same complete-root delta validation as manual full reconcile before updating the canonical status store and Source Control projection.
- Manual full reconcile clears and resets the low-frequency timer to avoid back-to-back whole-working-copy scans.
- Repository unregister clears both dirty-path debounce timers and low-frequency reconcile timers.
- If a full reconcile fails before canonical status application, pending dirty-path targets are merged back into the queue through the existing scheduler path.
- The VS Code extension configures the dirty-path pipeline with a five-minute local full reconcile interval.
- Unit tests cover scheduled firing, unregister cancellation, manual full reconcile interval reset, complete-root coverage validation, pending dirty-path preservation on validation failure, and projection-only failure behavior.

M3m does not implement progress reporting, cancellation, adaptive/load-based interval tuning, remote status polling, or installed large-working-copy load evidence.

## M3n Implemented Slice

The fourteenth M3 slice exposes stale and partial repository freshness in the VS Code Source Control surface:

- `VscodeSourceControlPresenter` maps `ScmProjectionFreshness.repositoryCompleteness` values of `partial` and `stale` to Source Control status bar commands.
- The partial and stale indicators are localized runtime strings and are included in English, Japanese, and Chinese bundles.
- The status bar command invokes `subversionr.fullReconcile` with the affected repository id, so multi-repository workspaces do not require an extra picker when the user refreshes from the indicator.
- Complete repository projections clear the Source Control status bar freshness command.
- The indicator uses existing projection freshness metadata and does not add repository scans, remote polling, protocol changes, or compatibility aliases.
- Unit tests cover partial indicator rendering, stale indicator rendering, clearing on complete projections, localized runtime-key coverage, and repository-id command routing for full reconcile.

M3n does not implement in-flight progress/cancellation UI, `status/stale` transport routing, installed VS Code accessibility evidence, or backend restart/recovery freshness transitions.

## M3o Implemented Slice

The fifteenth M3 slice adds the receive side of `status/stale` notifications over stdio:

- The JSON-RPC stream client distinguishes daemon-initiated requests from id-less notifications and does not write responses for notifications.
- `startBackendProcess` accepts a notification handler and routes daemon-originated notifications from the sidecar stdio stream.
- The initialize handshake declares the required `statusStaleNotification` capability and advances the protocol minor to `1.18`.
- `StatusSnapshotStore.markStale` preserves the current generation, local entries, remote entries, and summary while marking repository completeness as `stale`.
- `SourceControlResourceStore.markStale` and `SourceControlProjectionService.markStale` publish stale freshness to the Source Control presenter without scanning or recomputing SVN status.
- The VS Code extension wires `status/stale` notifications to the canonical status store and Source Control projection.
- Unit and protocol tests cover notification transport, invalid notification rejection, canonical stale marking, SCM projection updates, backend-process routing, and protocol capability serialization.

M3o does not implement daemon trigger sources for backend restart, watcher overflow, cancellation, operation failure, or `status/delta` push notifications.

## M3p Implemented Slice

The sixteenth M3 slice extends the backend notification receive path to `status/delta`:

- `StatusRefreshRpcClient` exports the strict `StatusDelta` parser so push notifications and direct `status/refresh` responses share the same wire validation.
- The status notification handler accepts `status/delta` alongside `status/stale`, prevalidates initialized canonical and Source Control projection state, and applies the delta to both stores without issuing scans or remote checks.
- Invalid `status/delta` payloads and unavailable projection state fail before mutating status state, preserving the same no-half-update behavior used by stale notifications.
- Unit tests cover valid delta notification routing, invalid delta payload rejection, and projection-unavailable rejection.

M3p does not implement daemon-originated trigger sources for `status/delta` or `status/stale`, status progress notifications, cancellation UI, or installed VS Code accessibility evidence.

## M3q Implemented Slice

The seventeenth M3 slice adds the daemon-side emit path for operation-triggered stale status:

- `DispatchResult` can carry daemon-originated JSON-RPC notifications in addition to the request response.
- The stdio loop writes the request response first, then writes any queued notifications as id-less JSON-RPC frames, matching the JSON-RPC notification contract.
- Successful full-reconcile operations (`cleanup` and `update`) queue `status/stale` notifications with explicit operation reasons before the extension completes the requested reconcile.
- Rust dispatch and stdio tests cover cleanup/update notification payloads, response-before-notification ordering, and the absence of notification ids.

M3q does not implement watcher overflow, backend restart, cancellation, operation-failure stale transitions, daemon-originated `status/delta` push triggers, status progress notifications, or installed VS Code accessibility evidence.

## M3r Implemented Slice

The eighteenth M3 slice adds daemon-side stale transitions for failed libsvn operations:

- Once an operation request has passed parameter, repository, and epoch validation and the daemon has called the bridge, a bridge failure queues a `status/stale` notification before returning the structured operation error.
- Mutating operation failures use stable per-kind reasons such as `operationUpdateFailed`, `operationCleanupFailed`, and `operationCommitFailed`.
- Invalid operation parameters still fail before bridge execution and do not queue stale notifications.
- Rust dispatch and stdio tests cover update failure notification payloads, error-response-before-notification ordering, and the no-notification behavior for invalid update options.

M3r does not implement watcher overflow, backend restart, cancellation, daemon-originated `status/delta` push triggers, status progress notifications, or installed VS Code accessibility evidence.

## M3s Implemented Slice

The nineteenth M3 slice marks visible status state stale when the VS Code watcher dirty-path set overflows:

- `DirtyPathSet` exposes overflow state and the watcher timestamp that caused the bounded dirty-path map to collapse to `.` / `infinity`.
- `StatusRefreshScheduler` marks initialized canonical status and Source Control projection state stale with reason `watcherOverflow` and source `vscode-watcher` before sending the overflow-triggered `status/refresh`.
- The scheduler prevalidates visible status and projection state before mutating either store, preserving the existing no-half-update stale transition behavior.
- If no visible snapshot/projection exists yet during repository open, the dirty-path queue remains overflowed and the later refresh still runs; the extension does not fabricate an empty stale snapshot.
- Unit tests cover stale-before-refresh ordering, single stale marking for an event storm, and the existing `watcherOverflow` root/infinity refresh target.

M3s does not implement backend restart, cancellation, daemon-originated `status/delta` push triggers, native watcher overflow notifications, status progress notifications, or installed VS Code accessibility evidence.

## M3t Implemented Slice

The twentieth M3 slice marks already visible repository status stale when an initialized backend sidecar connection terminates unexpectedly:

- `BackendConnection` exposes a one-shot termination event for post-initialize `exit`, `close`, and `error` process events.
- Explicit shutdown and disposal detach process termination listeners before the child process exits, so intentional lifecycle transitions do not mark repository status stale.
- `BackendService` clears its initialized connection when that event fires, allowing the next backend-backed request to launch a new sidecar instead of reusing a dead JSON-RPC stream.
- `RepositorySessionService.markOpenSessionsStale` maps backend connection loss onto every currently open repository session with reason `backendConnectionLost` and source `backend-lifecycle`.
- The session service prevalidates initialized canonical status and Source Control projection state for every open repository before mutating either store, preserving the existing no-half-update stale transition behavior.
- The VS Code activation path wires backend termination to stale marking without using the `svn` CLI, scanning the working copy from the Extension Host, or fabricating missing status snapshots.
- Unit tests cover backend-process termination notification de-duplication, service-side connection clearing/restart, stale mark ordering, and unavailable-projection rejection before mutation.

M3t does not implement automatic repository re-open against the replacement sidecar, backend heartbeat/restart backoff, degraded-state context keys, cancellation stale transitions, daemon-originated `status/delta` push triggers, native watcher overflow notifications, status progress notifications, or installed VS Code accessibility evidence.

## M3u Implemented Slice

The twenty-first M3 slice reopens already open repository sessions after an initialized backend sidecar terminates and a replacement sidecar is started:

- `RepositorySessionService.reopenOpenSessions` reuses the existing session identity and working-copy root to send `repository/open` to the replacement backend, then loads a fresh `status/getSnapshot` for the replacement epoch.
- Reopen accepts only the same `repositoryId`, repository UUID, repository root URL, and working-copy root. Moved or different working copies fail fast instead of being treated as restart recovery.
- `StatusSnapshotStore.replaceSnapshot` and `SourceControlResourceStore.replaceSnapshot` allow a replacement epoch to seed a new complete snapshot for an already registered repository without unregistering the visible repository first.
- `SourceControlProjectionService.replaceSnapshot` publishes the replacement projection through the existing presenter.
- `RepositoryWatcherService.replaceRepository` updates the dirty-path pipeline scope for the replacement epoch when the watcher root is unchanged; it does not recreate watchers or support moved-root recovery in this slice.
- `RepositoryLifecycleService.reopenBackendRestartedRepositories` maps per-session reopen success and failure results to lifecycle events without running repository rediscovery.
- The VS Code backend termination path marks current status stale first, then asks the lifecycle service to reopen sessions against the replacement backend.
- Unit tests cover successful replacement-epoch reopen, preservation of stale local state when backend reopen fails, lifecycle event mapping, and runtime localization for reopen failure reporting.

M3u does not implement backend heartbeat/restart backoff, degraded-state context keys, moved working-copy rediscovery, cancellation stale transitions, daemon-originated `status/delta` push triggers, native watcher overflow notifications, status progress notifications, or installed VS Code accessibility evidence.

## M3v Implemented Slice

The twenty-second M3 slice makes backend restart degradation observable and throttled in the VS Code adapter:

- `BackendService` records a lifecycle state of `idle`, `ready`, or `degraded` without probing alternate backend paths or system SVN installations.
- Startup failures mark the backend lifecycle as `degraded` with reason `startupFailed`, a stable last error code, consecutive failure count, and an explicit `restartAfter` timestamp.
- Unexpected initialized sidecar termination marks the backend lifecycle as `degraded` with reason `terminated` and the same restart-backoff fields.
- Replacement startup requests wait for the configured restart backoff before spawning another sidecar, preventing tight restart loops after repeated startup or process failures.
- A successful replacement startup records `ready` state and emits a `recovered` lifecycle event carrying the degraded reason it recovered from.
- The VS Code activation path configures a fixed backend restart policy of 1 second initial backoff and 30 seconds maximum backoff.
- Version reports and diagnostics bundles include the sanitized backend lifecycle state, so support evidence can distinguish startup failure, unexpected termination, backoff timing, and recovery.
- Unit tests cover startup-failure degradation, termination degradation, restart backoff waiting, recovery events, and diagnostics report serialization.

M3v does not implement active heartbeat probes, degraded-state context keys or status-bar UI, cancellation stale transitions, daemon-originated `status/delta` push triggers, native watcher overflow notifications, status progress notifications, or installed VS Code accessibility evidence.

## M3w Implemented Slice

The twenty-third M3 slice adds active backend heartbeat probes to the VS Code adapter lifecycle:

- `BackendService` now requires an explicit heartbeat policy, keeping tests disabled by default and production activation enabled through fixed policy constants.
- The production adapter sends a lightweight `diagnostics/get` JSON-RPC heartbeat every 30 seconds with a 5 second timeout after the backend reaches `ready`.
- Heartbeat timers are routed through the lifecycle clock abstraction and use cancelable Node timers in production, so shutdown, disposal, process termination, and replacement startup invalidate pending probes.
- A rejected or timed-out heartbeat marks the backend lifecycle as `degraded` with reason `heartbeatFailed`, preserves a stable last error code, disposes the unhealthy connection, and emits the existing backend termination event for repository stale/reopen handling.
- Replacement startup after heartbeat failure uses the same restart backoff and recovery event path as startup and process termination failures.
- Unit tests cover heartbeat scheduling, diagnostics probe dispatch, heartbeat failure degradation, synthetic termination notification, restart backoff waiting, and recovery events.

M3w does not implement degraded-state context keys or status-bar UI, cancellation stale transitions, daemon-originated `status/delta` push triggers, native watcher overflow notifications, status progress notifications, installed restart diagnostics, or installed VS Code accessibility evidence.

## M3x Implemented Slice

The twenty-fourth M3 slice surfaces backend degraded state through VS Code context keys and a global status-bar item:

- `BackendService` now publishes an initial `ready` lifecycle event after the first successful sidecar startup, while preserving `recovered` events for degraded-to-ready transitions.
- `BackendLifecycleUiService` publishes `subversionr.backendLifecycleState`, `subversionr.backendDegraded`, and `subversionr.backendDegradedReason` through VS Code `setContext`.
- The degraded backend state displays a single left-aligned status-bar item with a short localized `SVN backend` label, accessible status metadata, a stable degraded reason/error-code tooltip, and an action that opens the existing SubversionR version report.
- Ready and idle states hide the degraded status-bar item and clear degraded-specific context without introducing legacy `svnNative.*` context aliases.
- Runtime strings are localized in English, Japanese, and Chinese.
- Unit tests cover initial ready lifecycle emission, context publication, degraded status rendering, recovery cleanup, disposal behavior, and runtime localization coverage.

M3x does not implement status refresh cancellation transport, cancellation stale transitions, daemon-originated `status/delta` push triggers, native watcher overflow notifications, status progress notifications, installed restart diagnostics, or installed VS Code accessibility evidence.

## M3y Implemented Slice

The twenty-fifth M3 slice adds client-side cancellation transport and stale handling for superseded status refreshes:

- `JsonRpcStreamClient.sendRequest` accepts an optional `AbortSignal`; aborting a pending request sends a JSON-RPC `$/cancelRequest` notification, rejects the local promise with a stable cancellation error, and ignores any later response for the canceled id.
- `StatusRefreshRpcClient` and `BackendStatusRefreshClient` pass cancellation signals through the status refresh RPC path without changing the serialized `status/refresh` request body.
- `StatusRefreshScheduler` creates an `AbortController` for each dirty-path refresh, explicit target refresh, and full reconcile request.
- When a new dirty-path generation arrives while a refresh is in flight, the scheduler prevalidates visible status/projection state, marks both stale with reason `refreshCancelled` and source `vscode-status-scheduler`, aborts the in-flight request, rejects the stale refresh with `SUBVERSIONR_STATUS_REFRESH_CANCELLED`, and merges the canceled targets back into the dirty-path set.
- Late successful responses from a canceled refresh are rejected before canonical status or Source Control projection mutation, so a superseded generation cannot be published as current state.
- Unit tests cover outbound cancel notification framing, status client signal propagation, stale marking, canceled target requeue, late-result rejection, and existing dirty-path pipeline behavior with cancellation signals.

M3y does not implement daemon-side status refresh cancellation execution, libsvn cancellation callbacks, native watcher overflow notifications, status progress notifications, installed stale/partial accessibility evidence, or native cancellation fixtures.

## M3z Implemented Slice

The twenty-sixth M3 slice connects status-refresh cancellation through the daemon and native bridge:

- `BridgeApi` now exposes explicit cancellation-aware status snapshot and status scan methods, with a `BridgeCancellationToken` contract and a `NeverCancelled` token for direct non-stdio dispatch paths.
- The stdio reader records active request cancellation state, consumes matching JSON-RPC `$/cancelRequest` notifications, and preserves a bounded pending-cancel window so a cancel frame that arrives immediately after the request frame still flips the request token.
- `DaemonState` passes the active cancellation token into `status/getSnapshot` and `status/refresh`; canceled scans return a stable `SVN_STATUS_CANCELLED` error without advancing the status generation or mutating cached entries.
- The native status-scan ABI now requires a cancel callback struct. The C bridge installs a `svn_client_ctx_t.cancel_func` / `cancel_baton` pair around `svn_client_status6`, restores any previous handler afterward, maps `SVN_ERR_CANCELLED` to bridge status `11`, and maps callback contract failures to bridge status `10`.
- Rust native bridge code maps bridge status `11` to `SVN_STATUS_CANCELLED` with category `cancelled` and message key `error.native.statusCancelled`.
- Tests cover native cancel callback translation, native canceled-status error mapping, daemon status-refresh atomicity after cancellation, stdio active-request cancellation while a status refresh is in progress, real native status snapshot/targeted-scan fixtures through the rebuilt bridge, a real native/libsvn status-scan cancellation fixture that verifies libsvn invokes the bridge cancellation callback, and a large status-stream cancellation fixture that verifies receiver-level cancellation checks while libsvn is emitting many entries.
- The source-built native bridge was rebuilt with MSVC/CMake and passed the staged bridge smoke check against libsvn `1.14.5`.

M3z does not implement native watcher overflow notifications, status progress notifications, installed stale/partial accessibility evidence, or installed large-working-copy load/performance evidence.

## M3aa Implemented Slice

The twenty-seventh M3 slice extends cancellation from status refreshes to native SVN operations:

- `BridgeApi` now exposes explicit cancellation-aware operation methods for revert, add, remove, resolve, cleanup, update, and commit while preserving `NeverCancelled` wrappers for direct non-stdio dispatch paths.
- `DaemonState` passes the active stdio cancellation token into `operation/run`, so JSON-RPC `$/cancelRequest` can interrupt in-flight operation bridge calls.
- The native operation ABI now requires a cancel callback struct for local operations and authenticated update/commit operations. The C bridge installs and restores `svn_client_ctx_t.cancel_func` / `cancel_baton` around each libsvn operation and maps callback contract failures to bridge status `11` and `SVN_ERR_CANCELLED` to bridge status `12`.
- Rust native bridge code maps operation bridge status `12` to `SVN_OPERATION_CANCELLED` with category `cancelled` and message key `error.native.operationCancelled`.
- Tests cover stdio active update-operation cancellation, operation cancellation error mapping through the daemon response path, and a real native/libsvn update cancellation fixture through the rebuilt bridge.
- The source-built native bridge was rebuilt with MSVC/CMake and passed the staged bridge smoke check against libsvn `1.14.5`.

M3aa does not implement installed operation-cancellation UX evidence, native watcher overflow notifications, or installed large-working-copy load/performance evidence.

## M3ab Implemented Slice

The twenty-eighth M3 slice adds the VS Code adapter receive path for daemon/native watcher overflow notifications:

- `StatusNotificationHandler` now accepts the daemon-originated `watcher/overflow` notification method with exact `repositoryId`, `epoch`, and `timestamp` fields.
- Native watcher overflow notifications mark the canonical status snapshot and Source Control projection stale with reason `watcherOverflow` and source `native-watcher`.
- Invalid watcher overflow notification payloads fail before mutating status or projection state; daemon-provided source fields are rejected instead of trusted.
- `WatcherOverflowDiagnostics` records a bounded, redacted overflow summary containing only the total count and last overflow metadata with a truncated repository hash.
- Diagnostics bundles now include sanitized watcher overflow metrics under `metrics.watcher`.
- Tests cover native watcher overflow stale marking, invalid payload rejection, redacted diagnostics snapshots, and diagnostics bundle exposure.

M3ab does not implement daemon-side native watcher event production, installed stale/partial accessibility evidence, installed operation-cancellation UX evidence, status progress notifications, or installed large-working-copy load/performance evidence.

## M3ac Implemented Slice

The twenty-ninth M3 slice adds installed-product evidence for the stale/partial SourceControl API freshness affordance:

- `VscodeSourceControlPresenter.snapshotRepository` now includes the live `SourceControl.statusBarCommands` contract in release diagnostic snapshots.
- The installed Source Control UI E2E hidden diagnostics path can drive an already-open fixture repository to synthetic `partial` and `stale` freshness states without scanning from the Extension Host.
- The partial and stale installed reports require a single `subversionr.fullReconcile` SourceControl status bar command with the opened repository id as its argument.
- The installed E2E release gate records both freshness reports under the `STA-014` trace id while retaining `publicReadinessClaim: false`.
- Tests cover snapshot command serialization, installed partial/stale freshness report validation, and release script evidence persistence.

M3ac does not implement stale/partial renderer accessibility capture, daemon protocol fault injection, daemon-side native watcher event production, status progress notifications, operation-cancellation UX evidence, or installed large-working-copy load/performance evidence.

## M3ad Implemented Slice

The thirtieth M3 slice preserves daemon protocol fault identity through backend lifecycle recovery:

- `BackendConnectionImpl` already turns daemon-initiated notification handler failures into `protocolFault` termination events and terminates the sidecar instead of continuing on a corrupt protocol stream.
- `BackendService` now keeps `protocolFault` as a distinct degraded lifecycle reason and carries the protocol error code from the daemon notification fault into `lastErrorCode`.
- `BackendLifecycleUiService` publishes `subversionr.backendDegradedReason = "protocolFault"` and renders localized status-bar and accessibility text for backend protocol faults.
- English, Japanese, and Chinese runtime localization bundles include the protocol-fault degraded reason label.
- Tests cover protocol-fault lifecycle classification, recovered lifecycle events, status-bar/a11y rendering, and runtime localization coverage.

M3ad does not implement installed protocol-fault E2E evidence, stale/partial renderer accessibility capture, daemon-side native watcher event production, status progress notifications, operation-cancellation UX evidence, or installed large-working-copy load/performance evidence.

## M3ae Implemented Slice

The thirty-first M3 slice adds installed-product renderer evidence for the stale/partial SourceControl freshness affordance:

- The installed Source Control UI E2E gate now captures separate VS Code renderer DOM, accessibility-tree, and nonblank screenshot artifacts after driving the fixture repository into `partial` and `stale` freshness states.
- The partial and stale renderer capture expectations require the localized SourceControl status affordance labels `SVN status partial` and `SVN status stale` in both DOM text and accessibility output.
- The release script validates the freshness renderer artifacts by SHA256, required tokens, and PNG pixel evidence instead of trusting driver-reported assertions alone.
- The final `subversionr.release.installed-source-control-ui-e2e.win32-x64.v1` evidence records `partialFreshnessRendererCapture`, `staleFreshnessRendererCapture`, and their isolated capture roots under the `STA-014` trace id.
- Script-level tests and `verify-readiness.ps1` require the stale/partial renderer capture fields so the release gate fails fast if this evidence is removed.

M3ae does not implement installed protocol-fault E2E evidence, daemon-side native watcher event production, status progress notifications, full reconcile progress/cancellation UI, operation-cancellation UX evidence, or installed large-working-copy load/performance evidence.

## M3af Implemented Slice

The thirty-second M3 slice closes the manual Full Reconcile cancellation evidence gap:

- `subversionr.refreshRepository` and `subversionr.fullReconcile` now run through cancellable VS Code notification progress and forward the progress `AbortSignal` into `RepositoryRefreshService`, `DirtyPathPipeline`, and `StatusRefreshScheduler`.
- Manual full reconcile cancellation now aborts the active `status/refresh` request, records stable `SUBVERSIONR_STATUS_REFRESH_CANCELLED` evidence with reason `userCancelled`, requeues the root `manualFullReconcile` target, and leaves the repository recoverable for a subsequent full reconcile.
- Runtime progress titles are localized through the TypeScript localization bundle for English, Japanese, and Chinese.
- The installed Source Control UI E2E gate arms a one-shot hidden status-refresh probe, captures the `Reconciling SVN working copy status` progress notification through the VS Code renderer, clicks `Cancel`, verifies `userCancelled` propagation, and proves a recovery full reconcile keeps SourceControl available.
- Script-level tests and `verify-readiness.ps1` require `sourceControlUiFullReconcileCancellationWorkflow`, `fullReconcileCancellationProgressCapture`, and the `full-reconcile-cancellation-progress-capture` fixture root, so STA-013 is now marked verified in the release evidence matrix.

M3af does not implement installed protocol-fault E2E evidence, daemon-side native watcher event production, operation-cancellation UX evidence for update/commit/add/remove/revert/resolve, or installed large-working-copy load/performance evidence beyond the current Refresh load fixture.

## M3ag Implemented Slice

The thirty-third M3 slice enables daemon-confirmed nested working-copy discovery:

- `repository/discover` now accepts `discoverNested = true` and uses a bounded filesystem walk only to find `.svn` candidate hints; every candidate is still confirmed by `BridgeApi.open_working_copy` before it is returned.
- Nested discovery rejects `discoveryDepth` values above the daemon cap, applies `discoveryDepth`, `discoveryIgnore`, and `ignoredRoots` to scanned child candidates, dedupes returned working-copy roots, and marks nested candidates with `parentWorkingCopyRoot`.
- Manual open and trusted-workspace automatic open now request nested discovery. Automatic open suppresses child candidates when their unopened parent candidate is opened in the same pass, then passes the child roots as `boundaryRoots`.
- `rpc_dispatch.rs` covers parent/nested candidate metadata plus depth, ignore-pattern, and ignored-root filtering.
- `native_bridge.rs` includes an ignored real-bridge fixture that checks out an independent repository under a parent working copy and verifies nested `repository/discover` metadata.
- Release readiness verification now keeps `REP-003` partial while requiring the daemon, native, and lifecycle nested-discovery evidence to remain present.

M3ag does not implement daemon-side external discovery, workspace setting wiring for nested discovery policy, daemon/session status-snapshot boundary propagation, a native parent-status no-duplicate fixture, or installed large-working-copy boundary load evidence.

## M3ah Implemented Slice

The thirty-fourth M3 slice propagates nested working-copy boundaries into daemon status sessions:

- `repository/open` now carries validated `boundaryRoots` from the VS Code adapter to the daemon when a repository is first opened and when stale sessions are reopened.
- The daemon stores repository boundary roots as canonical repository-relative paths after native working-copy identity confirmation.
- `status/getSnapshot` filters local and remote status entries below configured boundary roots before replacing the session cache or returning summary counts.
- `status/refresh` filters scan results below configured boundary roots and drops refresh targets that are themselves inside a boundary, so parent sessions do not scan nested child working-copy paths.
- `repositorySessionService.test.ts` covers boundary propagation across open, reopen, and rollback paths, while `rpc_dispatch.rs` covers daemon snapshot filtering and skipped boundary refresh targets.
- Release readiness verification now requires the boundary propagation unit evidence for `REP-003` while keeping the requirement partial until the remaining native/release evidence lands.

M3ah does not implement daemon-side external discovery, workspace setting wiring for nested discovery policy, a native parent-status no-duplicate fixture, a native external discovery fixture, or installed large-working-copy boundary load evidence.

## M3ai Implemented Slice

The thirty-fifth M3 slice closes the `REP-003` native nested working-copy boundary evidence:

- `native_bridge.rs` now includes an ignored real-bridge stdio RPC fixture that creates an independent nested working copy below a versioned parent directory, modifies both parent and nested files, opens the parent repository with the nested checkout as `boundaryRoots`, and verifies `status/getSnapshot` reports only the parent change.
- The fixture exercises the same daemon session boundary filtering used by the VS Code adapter path while still relying on the real source-built Apache Subversion tools and native bridge for the working-copy status data.
- Release readiness verification now requires the native parent status no-duplicate fixture name alongside the nested discovery fixture.
- `REP-003` is now marked verified in the release evidence matrix; broader `DIR-003` boundary work remains partial because native external discovery and installed large-workspace boundary load evidence are still open.

M3ai does not implement daemon-side external discovery, workspace setting wiring for nested discovery policy, a native external discovery fixture, or installed large-working-copy boundary load evidence.

## M3aj Implemented Slice

The thirty-sixth M3 slice adds lazy directory-external discovery evidence:

- `repository/discover` in `externalsMode = "lazy"` now asks the confirmed parent working copy for a libsvn status snapshot, extracts directory entries marked `external`, opens each external directory through libsvn, and returns confirmed external candidates with `isExternal = true` and `parentWorkingCopyRoot`.
- `rpc_dispatch.rs` covers directory external discovery with `discoverNested = false`, proving the result does not depend on filesystem `.svn` hint scanning.
- `native_bridge.rs` now includes an ignored real-bridge stdio RPC fixture that creates a real `svn:externals` directory, runs `repository/discover`, and verifies the external repository is returned as an external candidate.
- Release readiness verification now requires both daemon unit and native directory-external discovery evidence for `REP-004`.

M3aj does not implement file-external discovery, workspace setting wiring for external discovery policy, installed lazy external provider evidence, or installed large-working-copy boundary load evidence.

### M3ak Implemented Slice

The thirty-seventh M3 slice adds lazy file-external boundary discovery and propagation:

- `repository/discover` in `externalsMode = "lazy"` now extracts file entries marked `external` from the confirmed parent working copy status snapshot and returns their absolute paths as `fileExternalBoundaries` instead of modeling file externals as independent working-copy candidates.
- The protocol response shape now includes required `fileExternalBoundaries` under protocol v1.20; TypeScript discovery parsing rejects responses that omit the field, and backend startup rejects sidecars below protocol minor 20 before discovery can run.
- Manual and trusted-workspace automatic repository open flows merge discovered file external boundaries into the parent session `boundaryRoots`, alongside nested working copies, directory externals, and already open child sessions.
- `rpc_dispatch.rs`, `protocol_contract.rs`, `backendProcess.test.ts`, `repositoryDiscoveryService.test.ts`, `repositoryCommandController.test.ts`, and `repositoryLifecycleService.test.ts` cover the new contract, startup gate, and propagation path.
- `native_bridge.rs` includes an ignored real-bridge stdio RPC fixture that creates a real `svn:externals` file external, verifies `repository/discover` reports the file boundary, opens the parent with the discovered boundary value, and verifies parent status excludes the file external modification.
- Release readiness verification now requires file-external boundary protocol, daemon, TypeScript, and native evidence for `REP-004`; `DIR-003` remains partial only for large-workspace boundary load evidence.

M3ak does not implement workspace setting wiring for external discovery policy, installed lazy external provider evidence, or installed large-working-copy boundary load evidence.

## M3al Implemented Slice

The thirty-eighth M3 slice closes the installed lazy external provider evidence for `REP-004`:

- The installed Source Control UI E2E harness now builds a real parent working copy with both a directory external and a file external, then drives a hidden diagnostic command against the installed VSIX.
- `collectInstalledSourceControlUiE2eLazyExternalProviderReport` requests `repository/discover` through the TypeScript discovery service with `externalsMode = "lazy"`, opens the parent provider with computed boundary roots, opens the directory external as a distinct provider, and records the file external boundary evidence.
- Script-level evidence now records `sourceControlUiLazyExternalProviderWorkflow`, including assertions for lazy discovery, directory-external discovery, file-external boundaries, parent boundary propagation, distinct external provider opening, and provider cleanup.
- Release readiness verification now requires the diagnostic implementation, command/activation registration, unit tests, installed gate, and script tests for `REP-004`; `REP-004` is now marked verified in the release evidence matrix.

M3al does not implement workspace setting wiring for external discovery policy or installed large-working-copy boundary load evidence.

## M3am Implemented Slice

The thirty-ninth M3 slice closes the installed large-workspace boundary load evidence for `DIR-003`:

- The installed Source Control UI E2E harness now creates a source-built parent working copy with 128 modified parent resources plus a directory external boundary with 128 modified resources below it.
- `sourceControlUiBoundaryLoadWorkflow` reuses the installed lazy external provider diagnostic path, proving the parent provider records boundary roots, projects all parent load resources, excludes every boundary-prefixed resource from the parent provider, and still opens the external provider with its own load resources.
- Script-level tests cover the boundary load workflow shape, parent/boundary/external load counts, the `boundary-load-fixture` root, and the `DIR-003` trace id.
- Release readiness verification now requires the installed boundary load workflow and script-test evidence for `DIR-003`; `DIR-003` is now marked verified in the release evidence matrix.

M3am does not implement installed protocol-fault E2E, backend restart installed evidence, or broader non-boundary large-working-copy performance benchmarks.

## M3an Implemented Slice

The fortieth M3 slice adds deterministic dirty-path sibling folding before root overflow:

- `DirtyPathSet` now folds same-parent dirty path storms into one directory refresh target when the bounded dirty-path queue would otherwise exceed its path budget.
- Change/metadata-only sibling storms fold to `depth = "files"` with reason `dirtyPathFold`; create/delete sibling storms fold to `depth = "immediates"` so parent child state is revalidated.
- New direct-child events that land under an already folded parent are merged into the folded target instead of growing the dirty-path queue again.
- Unrelated directory storms still collapse to the existing `.` / `infinity` `watcherOverflow` target, preserving full-reconcile backpressure when no local common parent can absorb the burst.
- Boundary filtering still happens before dirty-path folding, so nested working copies and externals are not folded into a parent provider refresh.
- Unit and pipeline tests cover sibling change folding, sibling create/delete folding, true cross-directory overflow, scheduler overflow stale marking, and watcher-service overflow fixtures.

M3an does not implement the full adaptive ScanPlanner cost model, historical scan-cost feedback, rename-pair reconstruction, native watcher event production, or installed large-working-copy performance evidence.

## M3ao Implemented Slice

The forty-first M3 slice adds deterministic subtree folding for nested dirty-path storms:

- When dirty paths exceed the watcher queue budget and are spread across multiple descendants of the same non-root ancestor, `DirtyPathSet` now folds them into one `depth = "infinity"` refresh target with reason `dirtyPathSubtreeFold`.
- The planner prefers the deepest common non-root ancestor that reduces the queue, so `generated/module-*/src/file.txt` folds to `generated` instead of the repository root.
- New descendant events below an existing subtree folded target are merged into that target without adding more queued paths.
- Storms whose only common ancestor is the working-copy root still collapse to `.` / `infinity` with reason `watcherOverflow`.
- Unit and pipeline tests cover nested subtree folding, later descendant merging, and preservation of true root-overflow behavior.

M3ao does not implement adaptive scan-cost feedback, installed large-working-copy performance evidence, native watcher production, or operation-aware subtree planning.

## M3ap Implemented Slice

The forty-second M3 slice preserves same-path create/delete ordering in dirty-path event merge:

- `DirtyPathSet` now records the first and last watcher event kind by receive order for each dirty path in addition to the merged event-kind set; watcher timestamps remain diagnostic range data.
- Create then delete on the same path collapses to parent `immediates` verification with reason `childDeleted`, avoiding redundant file-level refresh for a transient path that no longer exists.
- Delete then create on the same path is treated as a replacement refresh, producing parent `immediates` coverage with reason `childReplaced` and path `empty` coverage with reason `fileReplaced`.
- Raw VS Code watcher `deleted` then `created` events preserve the replacement target shape through `DirtyPathPipeline`.
- The existing sibling/subtree folding and root-overflow behavior continue to operate after same-path event merging.

M3ap does not implement rename old/new pairing, operation-epoch correlation, native watcher production, or installed/load evidence for event storms.

## M3aq Implemented Slice

The forty-third M3 slice closes the installed mark/sweep load evidence for `DIR-010`:

- The installed Source Control UI E2E Refresh load workflow still opens a source-built 64-file modified working-copy fixture and proves all modified load resources remain projected after installed repository Refresh.
- The workflow now restores `load/modified-001.txt` to its base content after the initial Refresh load check, invokes the installed `subversionr.refreshResource` command for that SCM resource, and captures a second freshness report.
- The installed evidence requires the resource-level refresh to reduce projected load resources from 64 to 63 and to remove the restored path from Source Control, proving the daemon/store mark/sweep path clears normal entries under installed load.
- Script-level tests cover the restored-path report shape, the 64-to-63 projection change, the zero restored-path count, and the `DIR-010` trace id.
- Release readiness verification now requires the installed Source Control UI E2E script and script-test evidence for `DIR-010`; `DIR-010` is now marked verified in the release evidence matrix.

M3aq does not implement adaptive ScanPlanner cost feedback, native watcher event production, operation-aware event-storm evidence, or broader performance benchmark evidence beyond the installed Refresh mark/sweep load fixture.

## M3ar Implemented Slice

The forty-fourth M3 slice closes the installed/load coverage evidence for `DIR-009`:

- `StatusRefreshScheduler` now records the requested refresh targets and returned delta coverage for each completed `status/refresh` after both the status snapshot store and Source Control projection accept the delta.
- `StatusRefreshCoverageStore` retains the latest completed refresh coverage per repository/epoch for installed diagnostics without changing Source Control resource projection behavior.
- The installed Source Control UI E2E Refresh load workflow now verifies the restored-path `subversionr.refreshResource` refresh recorded one requested target and one returned coverage scope for `load/modified-001.txt`, both at `depth = "empty"` and `reason = "resourceRefresh"`, with coverage generation matching the delta generation.
- Script-level tests cover the coverage report shape, target/scope path-depth-reason fields, generation equality, and the `DIR-009` trace id.
- Release readiness verification now requires the installed Source Control UI E2E script and script-test coverage evidence for `DIR-009`; `DIR-009` is now marked verified in the release evidence matrix.

M3ar does not claim adaptive scan planning, native watcher production, remote-status coverage, or large-working-copy performance beyond the existing source-built 64-item installed load fixture.

## M3as Implemented Slice

The forty-fifth M3 slice closes the installed/load dirty-generation cancellation evidence for `DIR-013`:

- `InstalledSourceControlUiE2eStatusRefreshProbe` now supports a one-shot dirty-generation hold/report mode for a specific status refresh target, in addition to the existing manual Full Reconcile cancellation probe.
- The installed Source Control UI E2E harness registers hidden dirty-generation diagnostics for arming the probe, reading cancellation reports, and injecting a deterministic dirty event through `DirtyPathPipeline.accept`.
- The new installed load workflow opens the source-built 64-file modified fixture, injects a first `fileChanged` dirty target for `load/modified-002.txt`, starts installed `subversionr.refreshRepository`, waits until the first refresh is in flight, injects a second dirty event for `load/modified-003.txt`, and verifies the held refresh signal is aborted with workflow reason `dirtyGenerationSuperseded`.
- The workflow captures stale SourceControl freshness after the supersede cancellation sequence, then attempts an installed Refresh and verifies completed post-cancellation coverage includes both the held and superseding load targets. The completed coverage may be drained by the explicit Refresh or by the scheduler's normal pending dirty-path flush; the evidence does not attribute coverage to one path over the other.
- Script-level tests and `verify-readiness.ps1` now require `sourceControlUiDirtyGenerationCancellationLoadWorkflow`, the dirty-generation diagnostic commands, `dirtyGenerationSuperseded`, stale capture after cancellation, and completed coverage for both load targets; `DIR-013` is now marked verified in the release evidence matrix.

M3as does not claim native watcher event production, OS-level watcher timing, adaptive scan planning, remote-status cancellation, or large-working-copy performance beyond the existing source-built 64-item installed load fixture.

## M3at Implemented Slice

The forty-sixth M3 slice closes the installed/load generation-supersede evidence for `DIR-012`:

- The installed dirty-generation cancellation load workflow is now traced to both `DIR-012` and `DIR-013`, because it proves a first dirty refresh is in flight before a superseding dirty event enters the scheduler.
- The workflow records `firstRefreshObservedBeforeSupersede`, `dirtyGenerationSuperseded`, and completed post-cancellation coverage for both `load/modified-002.txt` and `load/modified-003.txt`, proving the superseded installed load targets are requeued and eventually refreshed.
- Core stale-result protection remains covered by `StatusRefreshScheduler` and `StatusSnapshotStore` unit tests, including late in-flight result rejection before canonical status or Source Control projection mutation.
- Script-level tests and `verify-readiness.ps1` now require `DIR-012` trace evidence, the dirty-generation workflow shape, supersede reason, and completed coverage for both installed load targets; `DIR-012` is now marked verified in the release evidence matrix.

M3at does not claim native watcher event production, OS-level watcher timing, remote-status supersede behavior, or a separate installed late-success race harness beyond the scheduler/store unit evidence and the installed dirty-generation load workflow.

## Deferred M3 Work

- SCM view reveal repository picker and empty-state UX.
- Adaptive ScanPlanner cost feedback beyond deterministic sibling/subtree budget folding.
- Native watcher event production and broader overflow/load evidence.
- Broader large-working-copy performance benchmarks beyond the installed Refresh mark/sweep and boundary-load fixtures.
- Daemon-originated `status/delta` notifications plus daemon-side trigger sources for `status/stale`.
- Installed protocol-fault E2E evidence.
- Installed operation-cancellation UX evidence.
- QuickDiff binding and non-refresh Source Control resource commands.
- Public command-catalog finalization and legacy alias migration.
- Packaged backend/bridge path resolution and launch verification.
- Installed backend restart diagnostics.
- Complete initialize handshake fields for cache schema and message/content limits.

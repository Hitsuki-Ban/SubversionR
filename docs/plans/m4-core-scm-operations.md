# M4 Core SCM Operations Plan

## Goal

Build SubversionR core working-copy operations on top of libsvn, with stable protocol contracts, explicit refresh hints, and no production dependency on the `svn` CLI or TortoiseSVN.

## M4a Implemented Slice

The first M4 slice adds the backend foundation for revert:

- The daemon exposes `operation/run` for `kind = "revert"`.
- The protocol minor version advances to `1.1`; the major remains `1`, and feature availability is still negotiated through `operationRun`.
- Revert requires an open `repositoryId`, matching `epoch`, and `options.version = 1`.
- Revert options carry repository-relative `paths`, `depth`, `changelists`, `clearChangelists`, `metadataOnly`, and `addedKeepLocal`.
- Unsupported operation kinds fail fast with `OPERATION_KIND_UNSUPPORTED`.
- Invalid paths, unsupported depths, missing options, stale epochs, and unopened repositories are rejected before native execution.
- The response carries `operationId`, `kind`, `touchedPaths`, `revision = null`, `summary`, structured `warnings`, and a targeted `reconcile` hint.
- Skipped paths are returned as stable warnings with code `SVN_OPERATION_PATH_SKIPPED` and localization key `warning.operation.pathSkipped`.
- The Rust bridge abstraction exposes a narrow `operation_revert` method and does not leak APR or libsvn types.
- The C bridge exposes `subversionr_bridge_operation_revert(...)` as a hand-written narrow ABI.
- The C implementation calls `svn_client_revert4` and uses libsvn notify callbacks to report reverted and skipped paths.
- The VS Code backend startup gate requires the `operationRun` initialize capability.

This slice intentionally does not implement VS Code command surfaces, confirmation dialogs, cancellation, progress events, undo, commit/update/add/remove/resolve/cleanup, remote operations, or TortoiseSVN adapters.

## M4a Gates

- Rust protocol contract tests cover `operationRun` capability and the stable `operation/run` response shape.
- Rust RPC tests cover successful revert dispatch, skipped-path warnings, unsupported operation kinds, invalid revert options, stale epoch rejection, and bridge error mapping.
- The native bridge builds against the staged Apache Subversion 1.14.5 prefix.
- Ignored native integration tests load the rebuilt bridge DLL and verify that libsvn-backed revert restores a modified working-copy file.
- These ignored native integration tests are not covered by default `cargo test`; CI and release gates invoke them explicitly after the bridge DLL is built and `SUBVERSIONR_TEST_BRIDGE_DLL` is set.
- TypeScript checks and extension tests require the new `operationRun` initialize capability.

## M4b Implemented Slice

The second M4 slice connects the backend revert operation to a VS Code SCM resource command:

- The extension contributes `subversionr.revertResource` only for local changed and conflicted SCM resources.
- Unknown future local status tokens stay visible in the Changes group with `subversionr.changedUnknown` and do not expose destructive revert.
- The command is hidden from the Command Palette because it requires SCM resource arguments.
- The command accepts VS Code SCM single-resource and multi-selection argument shapes for selected resources in one open working copy.
- The command resolves the selected file against the currently open repository sessions and chooses the most specific working-copy root.
- Revert asks for explicit modal confirmation before calling the backend.
- The operation client sends `operation/run` with `kind = "revert"` and `options.version = 1`.
- Request and response parsing is strict: malformed paths, unsupported depths, extra fields, response identity mismatch, and malformed reconcile hints fail fast.
- Successful revert applies the operation `reconcile` hint through targeted status refresh, or full reconcile when the backend explicitly requires it.
- User-visible command title, confirmation text, notifications, SCM group labels, and tooltips are routed through VS Code localization bundles.

This slice intentionally does not implement group-level revert, progress UI, undo, changelist-specific revert, keep-local variants for added files, or operation suppression windows for watcher events. Installed Revert confirmation and modal cancellation E2E evidence is covered by the M7j3 release gate.

## M4b Gates

- Operation RPC client tests cover request validation, exact response parsing, identity matching, reconcile hint validation, and backend error propagation.
- Backend operation client tests cover backend initialization and active JSON-RPC sender usage.
- Repository command tests cover confirmation, cancellation, multi-selection, changed/conflicted context acceptance, unversioned/external/ignored/incoming rejection, and reconcile handling.
- Refresh pipeline tests cover explicit operation reconcile targets without draining pending dirty paths.
- Manifest and localization tests cover command contribution, command-palette hiding, SCM menu visibility, and English/Japanese/Chinese NLS entries.
- Runtime localization bundles cover current English/Japanese/Chinese `vscode.l10n.t` strings and are checked by `pnpm i18n:verify`.
- TypeScript checks, extension tests, localization checks, and Rust workspace tests pass.
- The installed Source Control UI E2E gate executes `subversionr.revertResource` against an independent source-built changed-resource fixture, captures and clicks the VS Code Revert confirmation modal through CDP renderer evidence, verifies `src/tracked.txt` returns to the repository baseline content, and verifies the reverted changed resource disappears from SourceControl projection. It also opens a separate Revert cancellation fixture, captures the same modal, cancels it with Escape, and verifies `src/tracked.txt` remains modified while SourceControl projection stays unchanged.

## M4c Implemented Slice

The third M4 slice adds the libsvn-backed add operation and the first VS Code SCM surface for unversioned resources:

- The daemon exposes `operation/run` for `kind = "add"` using `options.version = 1`.
- The protocol minor version advances to `1.2`, and add availability is negotiated through the `operationRunAdd` initialize capability.
- Add options carry repository-relative `paths`, `depth`, `force`, `noIgnore`, `noAutoprops`, and `addParents`.
- Add request parsing accepts one explicit repository-relative path and rejects empty or multi-path arrays, unsupported depths, invalid paths, missing fields, and extra option fields before native execution. Selected multi-resource Add is implemented in the VS Code command layer as ordered single-path Add operations so each successful path receives reconcile before a later path can fail.
- The Rust bridge abstraction exposes a narrow `operation_add` method and does not leak APR or libsvn types.
- The C bridge exposes `subversionr_bridge_operation_add(...)` as a hand-written narrow ABI.
- The C implementation calls `svn_client_add5` and uses libsvn notify callbacks to report added and skipped paths.
- The extension contributes `subversionr.addResource` only for unversioned SCM resources, hides it from the Command Palette, and routes success text through the localization layer.
- Successful add applies the operation `reconcile` hint through targeted status refresh, or full reconcile when the backend explicitly requires it.

This slice intentionally does not implement folder/group add commands, explicit recursive UI, ignored-resource force add, custom autoprops controls, add-parents UI, operation progress/cancellation, undo, commit integration, or operation suppression windows for watcher events.

## M4c Gates

- Rust RPC tests cover successful add dispatch, multi-path add rejection for failure-reconcile safety, invalid add options, bridge error mapping, and stable add reconcile hints.
- Ignored native integration tests load the rebuilt bridge DLL and verify that libsvn-backed add schedules an unversioned file.
- Operation RPC client tests cover add request validation, multi-path rejection, response identity matching, and backend error propagation.
- Backend operation client tests cover add dispatch through the active JSON-RPC sender.
- Repository command tests cover unversioned context acceptance, selected multi-resource Add through ordered single-path operation requests, changed/conflicted/external/ignored/incoming rejection, targeted reconcile, full reconcile, stale projection rejection, duplicate selection rejection, root rejection, and cross-repository rejection.
- Manifest and localization tests cover `subversionr.addResource` activation, SCM menu visibility, command-palette hiding, and English/Japanese/Chinese NLS entries.
- The installed Source Control UI E2E gate executes `subversionr.addResource` against an independent source-built unversioned fixture resource, proves `scratch.txt` remains on disk, and verifies the SourceControl projection refreshes from `unversioned` to `changes` with `subversionr.changedFile`.

## M4d Implemented Slice

The fourth M4 slice adds the libsvn-backed remove operation and the first VS Code SCM surface for versioned resource removal:

- The daemon exposes `operation/run` for `kind = "remove"` using `options.version = 1`.
- The protocol minor version advances to `1.3`, and remove availability is negotiated through the `operationRunRemove` initialize capability.
- Remove options carry repository-relative `paths`, `force`, and `keepLocal`.
- Remove request parsing accepts one or more explicit repository-relative paths and rejects empty path arrays, duplicate paths, invalid paths, missing fields, unsupported option versions, and extra option fields before native execution.
- The Rust bridge abstraction exposes a narrow `operation_remove` method and does not leak APR or libsvn types.
- The C bridge exposes `subversionr_bridge_operation_remove(...)` as a hand-written narrow ABI.
- The C implementation calls `svn_client_delete4` and uses libsvn notify callbacks to report deleted and skipped paths.
- The extension contributes `subversionr.removeResource` only for changed and conflicted SVN SCM resources, hides it from the Command Palette, asks for modal confirmation, and routes all user-visible text through the localization layer.
- Successful remove applies the operation `reconcile` hint through targeted status refresh, or full reconcile when the backend explicitly requires it.

This slice intentionally does not implement group-level remove commands, force-remove UI, unversioned local delete, missing-file-specific remove, operation progress/cancellation, undo, commit integration, or operation suppression windows for watcher events.

## M4d Gates

- Rust protocol contract tests cover `operationRunRemove` capability and the stable remove response shape.
- Rust RPC tests cover successful remove dispatch, multi-path remove dispatch, invalid remove options, bridge error mapping, and stable remove reconcile hints.
- Ignored native integration tests load the rebuilt bridge DLL and verify that libsvn-backed remove schedules a versioned file deletion, including `keepLocal = true` preservation semantics.
- Operation RPC client tests cover remove request validation, multi-path exact request payloads with non-default boolean options, response identity matching, and backend error propagation.
- Backend operation client tests cover remove dispatch through the active JSON-RPC sender.
- Repository command tests cover confirmation, cancellation, multi-selection, changed/conflicted context acceptance, unversioned/external/ignored/incoming rejection, targeted reconcile, and full reconcile.
- Manifest and localization tests cover `subversionr.removeResource` activation, SCM menu visibility, command-palette hiding, and English/Japanese/Chinese NLS entries.
- The installed Source Control UI E2E gate executes `subversionr.removeResource` against an independent missing versioned fixture resource, captures and clicks the VS Code Remove confirmation modal through CDP renderer evidence, proves the file remains absent on disk, and verifies the SourceControl projection refreshes to the scheduled-deletion context. It also opens a separate Remove cancellation fixture, captures the same modal, cancels it with Escape, and verifies `src/tracked.txt` remains modified while SourceControl projection stays unchanged.

## M4e Implemented Slice

The fifth M4 slice adds an explicit repository-level cleanup operation for working-copy recovery:

- The daemon exposes `operation/run` for `kind = "cleanup"` using `options.version = 1`.
- The protocol minor version advances to `1.4`, and cleanup availability is negotiated through the `operationRunCleanup` initialize capability.
- Cleanup options carry root-only `path = "."`, `breakLocks`, `fixRecordedTimestamps`, `clearDavCache`, `vacuumPristines`, and `includeExternals`.
- The VS Code repository command uses the first-slice recovery defaults: `breakLocks = true`, all timestamp/cache/vacuum/external options false.
- Cleanup request parsing rejects non-root paths, missing fields, unsupported option versions, and extra option fields before native execution.
- The Rust bridge abstraction exposes a narrow `operation_cleanup` method and does not leak APR or libsvn types.
- The C bridge exposes `subversionr_bridge_operation_cleanup(...)` as a hand-written narrow ABI.
- The C implementation calls `svn_client_cleanup2` and does not call `svn_client_vacuum`.
- Successful cleanup always returns a full-reconcile hint because cleanup can repair working-copy metadata outside a single dirty path.
- The extension contributes `subversionr.cleanupRepository` as a repository-level SCM title command and routes user-visible text through the localization layer.

This slice intentionally does not implement automatic cleanup prompts, progress/cancellation, `svn_client_vacuum`, unversioned or ignored item deletion, cleanup of arbitrary subpaths, externals cleanup UI, legacy `svn.cleanup` aliases, or TortoiseSVN cleanup integration.

## M4e Gates

- Rust protocol contract tests cover `operationRunCleanup` capability and the stable full-reconcile cleanup response shape.
- Rust RPC tests cover successful cleanup dispatch, strict invalid cleanup options, bridge error mapping, full-reconcile hints, and explicit boolean option forwarding.
- Ignored native integration tests load the rebuilt bridge DLL and verify that libsvn-backed cleanup preserves unversioned files.
- Operation RPC client tests cover cleanup request validation, exact request payloads, response identity matching, and backend error propagation.
- Backend operation client tests cover cleanup dispatch through the active JSON-RPC sender.
- Repository command tests cover repository selection, conservative cleanup defaults, full reconcile, and localized success text.
- Manifest and localization tests cover `subversionr.cleanupRepository` activation, SCM menu visibility, command contribution, and English/Japanese/Chinese NLS entries.
- The installed Source Control UI E2E gate executes `subversionr.cleanupRepository` against the live source-built fixture repository after earlier local workflows, verifies the conservative root cleanup request shape, and proves a post-cleanup full reconcile keeps the SourceControl surface available.

## M4f Implemented Slice

The sixth M4 slice adds an explicit conflict resolve operation for a single conflicted SCM resource:

- The daemon exposes `operation/run` for `kind = "resolve"` using `options.version = 1`.
- The protocol minor version advances to `1.5`, and resolve availability is negotiated through the `operationRunResolve` initialize capability.
- Resolve options carry exactly one repository-relative `path`, `depth = "empty"` from the first VS Code surface, and `choice = "working"` for the Working copy Quick Pick choice.
- The operation uses SVN terminology and maps the first UI surface to libsvn's "mark merged" behavior: SubversionR keeps the working-copy file contents exactly as they are at resolve time and removes the SVN conflict marker state.
- Resolve request parsing rejects missing fields, unsupported depths, multiple paths, invalid paths, unsupported choices, and extra option fields before native execution.
- The Rust bridge abstraction exposes a narrow `operation_resolve` method and does not leak APR or libsvn types.
- The C bridge exposes `subversionr_bridge_operation_resolve(...)` as a hand-written narrow ABI.
- The C implementation calls `svn_client_resolve` with `svn_wc_conflict_choose_merged` and uses libsvn notify callbacks to report resolved paths.
- The extension contributes `subversionr.resolveResource` only for conflicted SVN SCM resources, hides it from the Command Palette, shows a VS Code Quick Pick for the Working copy choice, and routes all user-visible text through the localization layer.
- Successful resolve applies the operation `reconcile` hint through targeted status refresh, or full reconcile when the backend explicitly requires it.

This slice intentionally does not implement batch resolve, folder/group resolve, automatic conflict choice detection, mine/theirs/base choice UI, conflict editor flows, progress/cancellation, undo, commit integration, operation suppression windows for watcher events, legacy `svn.resolve` aliases, or TortoiseSVN resolve integration.

## M4f Gates

- Rust protocol contract tests cover `operationRunResolve` capability and the stable resolve response shape.
- Rust RPC tests cover successful resolve dispatch, strict invalid resolve options, bridge error mapping, targeted reconcile hints, and explicit `working` choice forwarding to libsvn merged resolution.
- Ignored native integration tests load the rebuilt bridge DLL and verify that libsvn-backed resolve clears a postponed text conflict.
- Operation RPC client tests cover resolve request validation, exact request payloads, response identity matching, and backend error propagation.
- Backend operation client tests cover resolve dispatch through the active JSON-RPC sender.
- Repository command tests cover confirmation, cancellation, conflicted-context acceptance, non-conflicted context rejection, targeted reconcile, and full reconcile.
- Manifest and localization tests cover `subversionr.resolveResource` activation, SCM menu visibility, command-palette hiding, command contribution, and English/Japanese/Chinese NLS entries.
- Installed Source Control UI E2E script tests cover command registration, VS Code Resolve Quick Pick capture, `choice = "working"` and `depth = "empty"` evidence, working-copy content preservation, and conflict projection refresh for a source-built postponed text-conflict fixture.

## M4g Implemented Slice

The seventh M4 slice adds the first libsvn-backed update foundation for a working-copy root:

- The daemon exposes `operation/run` for `kind = "update"` using `options.version = 1`.
- The protocol minor version advances to `1.6`, and update availability is negotiated through the `operationRunUpdate` initialize capability.
- Update options are intentionally narrow for the first slice: root-only `path = "."`, `revision = "head"`, `depth = "workingCopy"`, `depthIsSticky = false`, and `ignoreExternals = true`.
- Update request parsing rejects selected paths, non-HEAD revisions, sticky depth, externals traversal, missing fields, unsupported option versions, and extra option fields before native execution.
- The Rust bridge abstraction exposes a narrow `operation_update` method and does not leak APR or libsvn types.
- The C bridge exposes `subversionr_bridge_operation_update(...)` as a hand-written narrow ABI.
- The C implementation maps `depth = "workingCopy"` to libsvn's ambient working-copy depth, calls `svn_client_update4`, and reports the resulting repository revision.
- The Windows bridge runtime explicitly preloads the staged libsvn RA and filesystem modules that Apache Subversion builds as delay-loaded DLLs for the update path.
- Successful update returns `revision` as a concrete revision number and always returns a full-reconcile hint because remote changes can affect paths beyond the initial dirty set.
- The VS Code backend startup gate requires the `operationRunUpdate` initialize capability, and the TypeScript backend operation client can call update directly for future UI surfaces.

This slice intentionally does not implement a VS Code command, selected-path update, update-to-revision, sticky-depth UI, externals traversal, progress/cancellation, authentication prompts, operation suppression windows, legacy `svn.update` aliases, or TortoiseSVN update integration.

## M4g Gates

- Rust protocol contract tests cover `operationRunUpdate` capability, protocol minor `1.6`, and the stable full-reconcile update response shape.
- Rust RPC tests cover successful update dispatch, strict invalid update options, bridge error mapping, full-reconcile hints, and explicit option forwarding.
- Ignored native integration tests load the rebuilt bridge DLL and verify that libsvn-backed root update applies a remote repository change and reports a concrete revision.
- Native script tests require the staged `libsvn_ra-1.lib` import library because the bridge must build and run against the source-built libsvn RA stack.
- Operation RPC client tests cover update request validation, exact request payloads, response identity matching, non-null revision enforcement, and backend error propagation.
- Backend operation client tests cover update dispatch through the active JSON-RPC sender.
- TypeScript checks, extension tests, localization checks, Rust workspace tests, bridge smoke tests, and explicit ignored native integration tests pass.

## M4h Implemented Slice

The eighth M4 slice connects the root update foundation to a repository-level VS Code command:

- The extension contributes `subversionr.updateRepository` as `SubversionR: Update Working Copy`.
- The command is visible from the SCM title surface and remains available from the Command Palette, matching the command catalog's root update surface.
- The command selects an open repository session using the same repository picker path as refresh, full reconcile, and cleanup.
- The command sends the first-slice update request exactly: `path = "."`, `revision = "head"`, `depth = "workingCopy"`, `depthIsSticky = false`, and `ignoreExternals = true`.
- Successful update always runs a full reconcile after the backend operation because remote changes can invalidate more than the pre-update dirty set.
- The success notification includes the revision reported by libsvn and the working-copy root.
- User-visible command title and notification text are routed through English, Japanese, and Chinese localization bundles.

This slice intentionally does not implement selected-path update, update-to-revision, sticky-depth UI, externals traversal, progress/cancellation, authentication prompts, conflict editor handoff, operation suppression windows, legacy `svn.update` aliases, or TortoiseSVN update integration.

## M4h Gates

- Repository command tests cover exact update request construction, explicit repository selection, no-open-repository warning behavior, full reconcile, and localized success text.
- Manifest tests cover `subversionr.updateRepository` activation, command contribution, SCM title visibility, Command Palette availability, and English/Japanese/Chinese package NLS entries.
- Runtime localization tests cover the update success message in English, Japanese, and Chinese bundles.
- TypeScript checks, extension tests, localization checks, and Rust workspace tests pass.

## M4i Implemented Slice

The ninth M4 slice adds the backend/native foundation for committing one explicit file path through libsvn:

- The daemon exposes `operation/run` for `kind = "commit"` using `options.version = 1`.
- The protocol minor version advances to `1.7`, and commit availability is negotiated through the `operationRunCommit` initialize capability.
- Commit options are intentionally narrow for the first slice: exactly one repository-relative non-root path, non-empty LF-only `message`, `depth = "empty"`, empty `changelists`, `keepLocks = false`, `keepChangelists = false`, `commitAsOperations = false`, `includeFileExternals = false`, and `includeDirExternals = false`.
- Commit request parsing rejects root commits, batch commits, backslash paths, CR/NUL messages, unsupported depth, changelist filters, lock retention, commit-as-operations, externals traversal, missing fields, unsupported option versions, and extra option fields before native execution.
- The Rust bridge abstraction exposes a narrow `operation_commit` method and does not leak APR or libsvn types.
- The C bridge originally exposed commit as a hand-written narrow ABI; M6o upgrades the current export to `subversionr_bridge_operation_commit_with_auth(...)` so commit uses the daemon auth broker.
- The C implementation installs temporary libsvn notify, log-message, and commit callbacks, calls `svn_client_commit6`, and returns only the committed revision from `svn_commit_info_t.revision`.
- Successful commit returns `revision` as a concrete revision number and a targeted reconcile hint for the requested file path.
- The VS Code backend startup gate requires the `operationRunCommit` initialize capability, and the TypeScript backend operation client can call commit directly for future UI surfaces.

This slice intentionally does not implement a VS Code commit command, SCM input box wiring, commit all, Commit Selected UI, changelist commit, message history/templates, conflict/unsaved-editor guard UI, progress/cancellation, auth prompts, revprops, externals commit, lock workflows, legacy `svn.commit` aliases, or TortoiseSVN commit dialog integration.

## M4i Gates

- Rust protocol contract tests cover `operationRunCommit` capability, protocol minor `1.7`, and the stable targeted commit response shape.
- Rust RPC tests cover successful commit dispatch, strict invalid commit options, bridge error mapping, targeted reconcile hints, non-null revision, and exact option/message forwarding.
- Ignored native integration tests load the rebuilt bridge DLL and verify that libsvn-backed commit publishes a modified file, reports a concrete revision, leaves the source working copy clean, and is visible from a peer checkout.
- Operation RPC client tests cover commit request validation, exact request payloads, response identity matching, non-null revision enforcement, and backend error propagation.
- Backend operation client tests cover commit dispatch through the active JSON-RPC sender.
- TypeScript checks, extension tests, localization checks, Rust workspace tests, bridge smoke tests, and explicit ignored native integration tests pass.

## M4j Implemented Slice

The tenth M4 slice connects the single-file commit foundation to the first VS Code-facing Commit Selected command:

- The extension contributes `subversionr.commitResource` as `SubversionR: Commit Resource`.
- Known local changes are split into `subversionr.changedFile` and `subversionr.changedDirectory` SCM resource states so file-only command surfaces can fail fast without guessing node kind.
- The command is visible only on `subversionr.changedFile` SCM resource states and is hidden from the Command Palette because it requires an explicit SCM resource argument.
- The command reads the message from the repository's VS Code `SourceControl.inputBox`, matching VS Code's source-control input contract.
- Empty or whitespace-only Source Control messages open one explicit localized prompt before backend dispatch. Cancellation performs no operation, CR/NUL messages fail fast with a stable command error code, and the input message is preserved unless commit succeeds.
- The command is disabled in untrusted workspaces and warns without dispatch when the selected resource has unsaved editor contents.
- The command sends the first-slice commit request exactly: one non-root repository-relative path, `depth = "empty"`, empty `changelists`, and all deferred lock/changelist/externals/commit-as-operation flags set to `false`.
- Successful commit clears the repository input box, shows the committed revision and path through localized text, and then applies the backend reconcile hint. If post-commit reconcile fails, the commit is still reported as successful and the reconcile failure is shown as a separate warning.
- SourceControl input placeholder and all new command strings are routed through English, Japanese, and Chinese localization bundles.

This slice intentionally does not implement Commit All / input accept, multi-select commit, folder/root commit, changelist commit, Review & Commit, message history/templates, `bugtraq:*` / `tsvn:*` project-property parsing, progress/cancellation, authentication prompts, operation suppression windows, legacy `svn.commit` aliases, TortoiseSVN commit dialog integration, revprops, locks, externals commit, or non-file commit scopes.

## M4j Gates

- Repository command tests cover exact commit request construction, SourceControl input reads, message preservation on backend commit failure, empty/invalid message blocking, untrusted workspace blocking, unsaved-editor warning behavior, targeted/full reconcile, post-commit reconcile failure warning behavior, root rejection, non-file rejection, context rejection, input clearing, and localized success text.
- SourceControl presenter tests cover commit input placeholder setup, resource kind propagation, input reads, input clearing, and fail-fast behavior for unknown repositories.
- Manifest tests cover `subversionr.commitResource` activation, command contribution, SCM resource-menu visibility, Command Palette hiding, and English/Japanese/Chinese package NLS entries.
- Runtime localization tests cover the commit input placeholder, empty-message warning, unsaved-editor warning, success message, and post-commit reconcile warning in English, Japanese, and Chinese bundles.
- TypeScript checks, extension tests, localization checks, and Rust workspace tests pass.

## M4k Implemented Slice

The eleventh M4 slice expands Commit Selected from one explicit file target to multiple selected file targets in the same open repository:

- The protocol minor version advances to `1.8`, and multi-target commit availability is negotiated through the `operationRunCommitMultiPath` initialize capability.
- The backend and Rust/native bridge accept one or more explicit repository-relative non-root file paths for `kind = "commit"`.
- The commit option contract remains narrow: `depth = "empty"`, empty `changelists`, `keepLocks = false`, `keepChangelists = false`, `commitAsOperations = false`, `includeFileExternals = false`, and `includeDirExternals = false`.
- Request parsing rejects empty target sets, duplicate paths, root targets, backslash paths, CR/NUL messages, unsupported depth, changelist filters, lock retention, commit-as-operations, externals traversal, missing fields, unsupported option versions, and extra option fields before native execution.
- The C bridge still calls `svn_client_commit6`; the target array now contains every validated file path. This follows libsvn's documented target-array commit API and uses `svn_depth_empty` so only the named file targets' content and property changes are committed.
- Before calling `svn_client_commit6`, the C bridge checks each commit target through libsvn working-copy info at `svn_depth_empty` and rejects targets that are not versioned files. This keeps file-only commit semantics authoritative in native code instead of trusting VS Code SCM resource metadata.
- The native fallback touched-path result reports all requested paths when libsvn notify callbacks produce no touched path details.
- The VS Code backend startup gate requires `operationRunCommitMultiPath`, keeping old sidecars from silently accepting a UI they cannot implement.
- The SCM resource command accepts VS Code multi-selection arguments for `subversionr.commitResource`; Add, Remove, Keep-local Remove, and Revert also accept selected multi-resource arguments in their narrower operation contracts. Add keeps the backend operation contract single-path and executes selected resources as ordered single-path requests for failure-reconcile safety; Remove and Revert use their multi-path backend requests.
- Multi-select commit is limited to changed file resources from one repository session and one epoch. Root, directory, duplicate, cross-repository, forged-context, and outside-repository selections fail before backend dispatch.
- The command checks workspace trust before reading the repository input message, preserves the message on warnings/errors, warns on the first selected resource with unsaved editor contents, clears the input only after a successful commit, and applies the backend's targeted reconcile hints for all committed paths.
- Localized success text distinguishes single-resource and multi-resource notifications while keeping the path list explicit.

This slice intentionally does not implement Commit All / input accept, folder/root commit, changelist commit, Review & Commit, message history/templates, `bugtraq:*` / `tsvn:*` project-property parsing, progress/cancellation, authentication prompts, operation suppression windows, legacy `svn.commit` aliases, TortoiseSVN commit dialog integration, revprops, locks, externals commit, or non-file commit scopes.

## M4k Gates

- Rust protocol contract tests cover `operationRunCommitMultiPath`, protocol minor `1.8`, and stable wire field naming.
- Rust RPC tests cover multi-file commit dispatch, strict duplicate-path rejection, bridge error mapping, targeted reconcile hints, non-null revision, and exact option/message forwarding.
- Operation RPC client tests cover multi-path commit request validation, duplicate-path rejection, exact request payloads, response identity matching, non-null revision enforcement, and backend error propagation.
- Repository command tests cover SCM multi-selection commit, duplicate selection rejection, cross-repository rejection, multi-selection unsaved-editor warnings, single-file behavior preservation, message preservation, input clearing, targeted/full reconcile, and localized success text.
- Ignored native integration tests verify that one libsvn-backed bridge commit can publish modifications to multiple files in one revision and that the changes are visible from a peer checkout.
- Backend process tests cover startup gating for the new capability, and runtime localization tests cover the multi-resource success message in English, Japanese, and Chinese bundles.
- TypeScript checks, extension tests, localization checks, Rust workspace tests, bridge smoke tests, and explicit ignored native integration tests pass.

## M4l Implemented Slice

The twelfth M4 slice adds repository-level Commit All for currently projected local file changes:

- The extension contributes `subversionr.commitAll` as `SubversionR: Commit Changes`.
- Each registered SubversionR `SourceControl` provider wires `acceptInputCommand` to `subversionr.commitAll` with its exact `repositoryId`, so VS Code's source-control input accept path commits the matching working copy.
- The command is visible from the SCM title surface and remains available from the Command Palette as a repository command.
- Commit All derives its targets from the current Source Control projection instead of scanning the working copy or reading `.svn/wc.db`.
- Eligible targets are local `changes` group resources with `subversionr.changedFile`, file kind, non-root repository-relative paths, non-ignored status, non-external status, and changelists not excluded by `subversionr.status.ignoreChangelistsInCount`.
- Unversioned, ignored, external, incoming, directory, root, unknown, and conflicted resources are not Commit All targets.
- If the projection contains unresolved conflicts, the command fails before reading the commit message.
- If there are no eligible file targets, the command warns and preserves the repository input message.
- The command checks workspace trust before reading the commit message, warns on the first eligible target with unsaved editor contents, and preserves the input message unless commit succeeds.
- The backend request reuses the M4k multi-path commit contract exactly: explicit `paths`, `depth = "empty"`, empty `changelists`, and all deferred lock/changelist/externals/commit-as-operation flags set to `false`.
- Successful Commit All clears only the matching repository input box, reports the committed revision through localized text, and applies the backend's targeted reconcile hints. If post-commit reconcile fails, the commit remains reported and the reconcile failure is shown as a warning.

This slice intentionally does not implement folder/root commit, changelist commit UI, Review & Commit, message history/templates, `bugtraq:*` / `tsvn:*` project-property parsing, progress/cancellation, authentication prompts, operation suppression windows, legacy `svn.commit` aliases, TortoiseSVN commit dialog integration, revprops, locks, externals commit, or non-file commit scopes.

## M4l Gates

- SourceControl resource store tests cover Commit All target derivation, ignored changelist exclusion, deterministic path ordering, conflict detection, and malformed eligible target fail-fast behavior.
- Repository command tests cover repository input accept, no-argument repository selection, untrusted workspace blocking before message reads, empty target warnings, conflict blocking, exact multi-path commit request construction, targeted reconcile, input clearing, and localized success text.
- SourceControl presenter and command-argument tests cover `acceptInputCommand` wiring with the exact repository id, localized title, and direct SCM title `SourceControl` object mapping.
- Manifest tests cover `subversionr.commitAll` activation, command contribution, SCM title visibility, Command Palette availability, and English/Japanese/Chinese package NLS entries.
- Runtime localization tests cover the Commit input title and empty Commit All target warning in English, Japanese, and Chinese bundles.
- TypeScript checks, extension tests, localization checks, and Rust workspace tests pass.

## M4m Implemented Slice

The thirteenth M4 slice adds selected-path update for incoming remote status resources:

- The daemon keeps `operation/run` for `kind = "update"` on `options.version = 1` and now accepts strict repository-relative non-root paths in addition to `"."`.
- The protocol minor version advances to `1.9`, and selected-path update availability is negotiated through the `operationRunUpdateSelectedPath` initialize capability.
- Update request parsing still rejects path traversal, absolute paths, empty paths, non-HEAD revisions, sticky depth, externals traversal, missing fields, unsupported option versions, and extra option fields before native execution.
- The Rust bridge continues to use the existing narrow `operation_update` method and the C ABI continues to expose the existing `subversionr_bridge_operation_update(...)` entry point.
- The native bridge resolves the repository-relative target to a slash-normalized absolute working-copy path before calling libsvn.
- The extension contributes `subversionr.updateResource` as `SubversionR: Update Selected` for SCM resources with `subversionr.incoming` context and hides the command from the Command Palette.
- The command updates exactly one selected incoming resource, uses `revision = "head"`, `depth = "workingCopy"`, `depthIsSticky = false`, and `ignoreExternals = true`, then performs a full local reconcile after success.
- Selected update does not clear or refresh remote-status caches; explicit remote refresh remains a separate future workflow.

This slice intentionally does not implement update-to-revision, sticky-depth UI, externals traversal, progress/cancellation, authentication prompts, conflict editor handoff, operation suppression windows, remote cache invalidation, legacy `svn.update` aliases, or TortoiseSVN update integration.

## M4m Gates

- Rust protocol contract tests cover `operationRunUpdateSelectedPath`, protocol minor `1.9`, and stable initialize capability serialization.
- Rust RPC tests cover selected repository-relative update dispatch, root update preservation, strict invalid update options including empty, absolute, traversal, and backslash paths, bridge error mapping, full-reconcile hints, and cleanup path validation remaining root-only.
- Operation RPC client tests cover exact selected update request payloads, selected-path validation including empty, absolute, traversal, and backslash paths, response identity matching, non-null revision enforcement, and backend error propagation.
- Backend operation client and backend startup tests cover selected update capability gating and dispatch through the active JSON-RPC sender.
- Repository command tests cover incoming resource selection, non-incoming rejection, root-resource rejection, multi-selection rejection, outside-repository rejection, exact update request construction, full reconcile, and localized success text.
- Ignored native integration tests verify that one libsvn-backed selected-path update applies the remote change for the selected file without updating a sibling file through the existing C ABI.
- Manifest and localization tests cover `subversionr.updateResource` activation, SCM incoming-resource menu visibility, Command Palette hiding, and English/Japanese/Chinese NLS entries.
- TypeScript checks, targeted extension tests, protocol tests, and targeted daemon RPC tests pass.

## M4n Implemented Slice

The fourteenth M4 slice adds a VS Code extension-side repository operation scheduler for already implemented write commands:

- A new `RepositoryOperationScheduler` serializes operation tasks by exact `repositoryId` using FIFO ordering.
- Queues are independent per repository id, so operations for different open working copies are not serialized by this layer.
- Failed operation tasks do not poison the repository queue; the next queued task still runs.
- Invalid blank or whitespace-padded repository ids fail fast with a stable coded scheduler error.
- Repository-level cleanup and update now enqueue their backend operation plus the required full reconcile as one repository-scoped task.
- Selected update now enqueues its backend operation plus the required full reconcile as one repository-scoped task.
- Add, remove, resolve, and revert now enqueue their backend operation plus the backend-provided reconcile hint application as one repository-scoped task.
- Commit Selected and Commit All now enqueue commit message checks, unsaved-editor checks, the backend commit, successful input clearing, and post-commit reconcile handling as one repository-scoped task.
- Read-only commands remain outside this scheduler: open, close, refresh, full reconcile, and BASE diff are unchanged.

This slice intentionally does not implement operation progress, cancellation, persistence, telemetry, watcher suppression windows, native-side operation locks, Rust protocol changes, or new libsvn capabilities.

## M4n Gates

- Scheduler unit tests cover same-repository FIFO behavior, different-repository independence, post-failure queue continuation, and invalid repository id rejection.
- Repository command tests cover that concurrent repository update commands do not start the second backend update until the first full reconcile has completed.
- Targeted extension tests pass for the scheduler and repository command controller.

## M4o Implemented Slice

The fifteenth M4 slice adds a bounded, sanitized operation journal for implemented core SVN operations:

- A new `RepositoryOperationJournal` keeps the most recent operation summaries in memory with an explicit capacity bound.
- Journal entries include operation kind, repository hash, start/end timestamps, duration, result category, scan plan, touched count, retry count, and cancellation state.
- Repository identity is SHA-256 hashed and truncated before it enters the journal as a correlation token, not an anonymity guarantee. Entries do not store working-copy paths, repository URLs, source content, commit messages, credentials, or backend stderr.
- Operation duration is computed from the extension's monotonic runtime clock, so wall-clock adjustments do not turn a successful SVN operation into a command failure or skip the required reconcile.
- `RepositoryCommandController` records backend `operation/run` outcomes for cleanup, update, selected update, revert, add, remove, resolve, and commit without changing the daemon protocol or SVN semantics.
- Successful entries derive `scanPlan` from the backend reconcile hint. Failed entries record an explicit `unknown` scan plan and classify cancellation, input, lifecycle, protocol, and generic failures as safe categories.
- Diagnostics bundles include the recent operation journal snapshot, journal recording failure counts, and the existing omitted-field declaration.

This slice intentionally does not implement operation progress UI, cross-session operation persistence, telemetry upload, watcher suppression windows, native-side operation locks, Rust protocol changes, or user-visible queue diagnostics.

## M4o Gates

- Operation journal unit tests cover bounded retention, deterministic repository hashing, timestamp validation, and absence of raw repository identity/path material.
- Repository command tests cover sanitized journal entries for successful and cancelled update operations.
- Diagnostics report tests cover recent operation journal inclusion in the redacted diagnostics bundle.
- Targeted extension tests pass for the operation journal, repository command controller, and diagnostics report service.

## M4p Implemented Slice

The sixteenth M4 slice adds VS Code operation progress UI and a frontend cancellation path for implemented core SVN operations:

- `RepositoryCommandController` runs cleanup, update, selected update, revert, add, remove, resolve, and commit backend `operation/run` calls inside a localized operation progress boundary.
- The VS Code adapter uses `window.withProgress` with notification-location cancellable progress for operation calls.
- Progress cancellation aborts the operation request through the existing JSON-RPC `AbortSignal` path, causing the client to send `$/cancelRequest` for active `operation/run` calls without changing the daemon protocol.
- `OperationRunRpcClient`, `BackendOperationClient`, and `BackendConnection` now preserve optional operation request signals through to the JSON-RPC stream client.
- Existing operation scheduling and post-operation reconcile semantics remain unchanged; progress cancellation is scoped to the backend operation request rather than acting as a watcher-suppression or queue-management feature.

This slice intentionally does not implement installed operation-cancellation UX evidence, operation progress percentages, user-visible queue diagnostics, cross-session operation persistence, watcher suppression windows, native-side operation locks, Rust protocol changes, or new libsvn capabilities.

## M4p Gates

- Operation RPC client tests cover forwarding cancellation signals to `operation/run`.
- Backend operation client tests cover preserving cancellation signals through the active backend connection.
- Repository command tests cover cancellable repository update progress and signal forwarding to the operation client while preserving per-repository update serialization through reconcile.
- Targeted extension tests pass for operation RPC, backend operation client, and repository command controller.

## M4q Implemented Slice

The seventeenth M4 slice adds the first explicit unversioned-resource deletion workflow for local SVN working-copy hygiene:

- The extension contributes `subversionr.deleteUnversionedResource` only for trusted-workspace SCM resources with the `subversionr.unversioned` context, and contributes `subversionr.deleteAllUnversionedResources` only on the trusted unversioned SCM resource group.
- The command accepts one or more projected unversioned files or directories, shows one modal delete confirmation, deletes each local item through the VS Code filesystem API with explicit `recursive` and `useTrash: false` options, and then runs targeted status refresh for the deleted repository-relative paths.
- Delete All reads the current repository projection, selects every projected unversioned file or directory in that repository, shows the same modal delete confirmation, deletes the selected local items, and refreshes the deleted paths together.
- Files delete with `recursive: false`; directories delete with `recursive: true` only after the current SCM projection still proves each resource is an unversioned directory.
- The command rejects repository roots, mixed-repository selections, duplicate paths, non-unversioned contexts, malformed SCM resources, stale projected resources, kind mismatches, and resources outside the selected repository before touching the local filesystem.
- Delete Unversioned does not call libsvn, the SVN CLI, or TortoiseSVN because unversioned items are not scheduled SVN nodes; libsvn remains the authority for versioned SVN operations and the follow-up status reconcile confirms the working-copy projection.
- Package and runtime localization cover the command title, confirmation action, confirmation prompt, and success notification in English, Japanese, and Chinese.

This slice intentionally does not implement ignored-item cleanup, trash-mode deletion, operation journal entries, or watcher suppression windows.

## M4q Gates

- Repository command tests cover confirmed file deletion, confirmed recursive directory deletion, confirmed multi-selected file/directory deletion, confirmed delete-all deletion from the current projection, no-op delete-all handling, cancellation, absence of libsvn add/remove calls, mixed-repository rejection, stale projection rejection, forged-context rejection, kind-mismatch rejection, and targeted status refresh.
- Manifest tests cover command activation, command contribution, SCM resource and resource-group context menu gating, workspace-trust gating, package localization, and runtime localization.
- `docs/release/delete-unversioned-trash-policy.md` records the release policy that Delete Unversioned permanently deletes through `vscode.workspace.fs.delete` with `useTrash: false` after modal confirmation, with no trash-mode fallback.
- The installed Source Control UI E2E gate now executes `subversionr.deleteUnversionedResource` against the source-built fixture, captures and clicks the VS Code Delete confirmation modal through CDP renderer evidence, and verifies that `scratch.txt` is removed from both the filesystem and SourceControl projection.
- The same installed Source Control UI E2E gate also opens a separate source-built 64-item unversioned load fixture, executes `subversionr.deleteAllUnversionedResources`, captures and clicks the aggregate Delete confirmation modal, and verifies that every load file and unversioned SourceControl resource is cleared.
- Targeted extension tests pass for repository command controller and extension manifest.

## M4r Implemented Slice

The eighteenth M4 slice adds the first explicit SVN move workflow for single-file rename/move operations:

- The daemon exposes `operation/run` for `kind = "move"` using `options.version = 1`.
- The protocol minor version advances to `1.19`, and move availability is negotiated through the `operationRunMove` initialize capability.
- Move options carry exactly one repository-relative `sourcePath`, one repository-relative `destinationPath`, and explicit `makeParents`.
- Move request parsing rejects repository roots, empty paths, absolute paths, path traversal, backslash paths, same-source/destination requests, missing fields, unsupported option versions, and extra option fields before native execution.
- The Rust bridge abstraction exposes a narrow `operation_move` method and does not leak APR or libsvn types.
- The C bridge exposes `subversionr_bridge_operation_move(...)` as a hand-written narrow ABI.
- The C implementation calls `svn_client_move7` with `move_as_child = false`, `allow_mixed_revisions = false`, and `metadata_only = false`.
- The extension contributes `subversionr.moveResource` for trusted SCM changed/conflicted file resources, Explorer resources, and the SubversionR editor context, hides it from the Command Palette, asks for an explicit repository-relative destination, and routes user-visible text through the localization layer.
- Successful move applies targeted reconcile hints for both the source and destination paths.

This slice intentionally does not implement batch moves, folder/group move UI, destination browse UI, move-as-child behavior, mixed-revision compatibility behavior, metadata-only moves, operation watcher suppression windows, legacy `svn.renameExplorer` aliases, or TortoiseSVN rename integration. Installed positive Move command and Move prompt cancellation E2E evidence is covered by the M7j3 release gate.

## M4r Gates

- Rust protocol contract tests cover `operationRunMove`, protocol minor `1.19`, and stable initialize capability serialization.
- Rust RPC tests cover successful move dispatch, strict invalid move options, bridge error mapping, targeted reconcile hints, and explicit `makeParents` forwarding.
- Ignored native integration tests load the rebuilt bridge DLL and verify that libsvn-backed move schedules a versioned file rename and reports source/destination touched paths.
- Operation RPC client tests cover move request validation, exact request payloads, response identity matching, and backend error propagation.
- Backend operation client and backend startup tests cover move capability gating and dispatch through the active JSON-RPC sender.
- Repository command tests cover SCM-resource move, destination prompting, exact backend request construction, targeted reconcile, and localized success text.
- Manifest and localization tests cover `subversionr.moveResource` activation, command contribution, SCM/Explorer/editor context menu visibility, Command Palette hiding, workspace-trust gating, and English/Japanese/Chinese NLS entries.
- The M7j3 installed Source Control UI E2E gate opens a separate source-built Move fixture, executes `subversionr.moveResource`, captures and submits the VS Code QuickInput destination prompt, verifies `src/tracked.txt` leaves disk, `src/moved.txt` exists, and SourceControl projection refreshes for source deletion plus destination addition. It also opens a separate Move cancellation fixture, captures the same QuickInput prompt, cancels it with Escape, and verifies `src/tracked.txt` remains, no destination file is created, and SourceControl projection stays unchanged.

## M4s Implemented Slice

The nineteenth M4 slice adds the first explicit Keep-local Remove VS Code surface for versioned resources:

- The extension contributes `subversionr.removeResourceKeepLocal` for trusted changed and conflicted SVN SCM resources.
- Keep-local Remove reuses the existing libsvn-backed `operation/run` remove path and sends `keepLocal = true`.
- The ordinary `subversionr.removeResource` command remains destructive-local-remove and still sends `keepLocal = false`.
- Keep-local Remove is hidden from the Command Palette because it requires an explicit SCM resource argument.
- The command asks for explicit confirmation using keep-local wording and routes all user-visible text through the localization layer.
- Successful Keep-local Remove applies the backend reconcile hint through the same targeted/full reconcile path as ordinary Remove.

This slice intentionally does not implement folder-specific keep-local UX, missing-file-specific remove, operation watcher suppression windows, undo, commit integration, legacy aliases, or TortoiseSVN remove integration.

## M4s Gates

- Repository command tests cover confirmation, cancellation, exact `keepLocal = true` backend request construction, targeted reconcile, and localized success text.
- Manifest and localization tests cover `subversionr.removeResourceKeepLocal` activation, command contribution, SCM menu visibility, Command Palette hiding, workspace-trust gating, and English/Japanese/Chinese NLS entries.
- Existing operation RPC, backend operation, Rust RPC, and ignored native integration tests cover strict `keepLocal` payload handling and libsvn `keepLocal = true` preservation semantics.
- The installed Source Control UI E2E gate executes `subversionr.removeResourceKeepLocal` against the source-built fixture changed resource, captures and clicks the VS Code Remove confirmation modal through CDP renderer evidence, proves the local file remains on disk, and verifies the SourceControl projection refreshes to the scheduled-removal context.

## M4t Implemented Slice

The twentieth M4 slice makes successful Update completion reporting reflect unresolved conflicts discovered by the mandatory post-update status reconcile:

- Repository Update, Update to Revision, Update Selected, and Update All Incoming all read the authoritative local `conflicts` Source Control group after their existing full reconcile completes.
- An Update whose reconciled scope contains unresolved text, property, or tree conflicts shows a warning instead of the ordinary information notification. The warning retains the Update result, states the total conflict count, and names at most three deterministic repository-relative paths with an explicit remaining count.
- Selected and aggregate incoming updates report only conflicts below the paths they updated. Repository Update reports the reconciled conflicts projected by its selected repository session; child sessions are not inferred to be externals from filesystem nesting alone.
- The notification describes unresolved working-copy state rather than attributing every projected conflict to the current Update. This keeps libsvn status authoritative and avoids deriving conflict semantics from touched paths or reimplementing SVN conflict classification in the Extension Host.
- Missing or stale post-reconcile projection state fails fast and cannot produce a plain success notification.
- The native ABI, daemon protocol, Update options, and reconciliation behavior are unchanged.

This slice does not implement automatic conflict resolution, conflict editor handoff, or remote/auth/certificate Update failure reporting.

## M4t Gates

- Repository command tests cover zero-conflict information notifications, warning severity for conflicts, deterministic three-path truncation, selected-path filtering, aggregate incoming updates, and unavailable projection fail-fast behavior.
- Runtime localization checks cover the warning and truncated-path summary in English, Japanese, and Chinese.
- The installed Source Control UI E2E gate creates a real text conflict through the installed `subversionr.updateRepository` command, captures the warning notification through renderer DOM and accessibility evidence, verifies the conflict count and path, rejects the ordinary success-only notification, and then reuses the projected conflict in the existing Resolve workflow.

## M4u Implemented Slice

The twenty-first M4 slice completes explicit missing-message handling for Commit Selected, Commit All, Review & Commit, and Commit Changelist:

- An empty or whitespace-only Source Control message opens one localized commit-message InputBox. The extension never synthesizes a default message and the daemon/native non-empty-message contract remains unchanged.
- Prompt cancellation returns before repository scheduling, the operation journal, backend/native dispatch, commit-message history, input mutation, or reconcile.
- A valid prompted message is retained in the matching Source Control input until commit succeeds, so a native failure leaves both the message and Review & Commit selection available for retry.
- After the prompt resolves and immediately before RPC dispatch, the controller revalidates the open repository epoch, Source Control projection generation, selected paths, resource kinds, and changelist identities. Changed state fails with a stable localized stale-selection error instead of committing an obsolete selection.
- Review & Commit clears its remembered selection only after a commit returns a concrete revision. Selection survives message prompting, cancellation, stale-state rejection, and commit failure.

This slice does not add commit templates, generated messages, message aliases, blank commits, project-property commit policy, or a compatibility fallback.

## M4u Gates

- Repository command tests cover all four commit entry points, whitespace-only input, valid prompted input, prompt cancellation with no journal/history/reconcile/backend side effects, invalid prompt characters, epoch/generation/path/changelist changes after prompting, commit failure, and successful Review & Commit selection clearing.
- Runtime localization tests cover the prompt title, prompt text, validation, invalid-message recovery, and stale-selection recovery in English, Japanese, and Chinese.
- Installed Source Control UI E2E evidence covers prompted local commit success, prompt cancellation with unchanged bytes/state/projection, Review & Commit selection retention after cancellation and a real forced commit failure, exact reviewed-path repository state, and authoritative targeted reconcile.

## Deferred M4 Work

- Batch revert, group/folder revert, and richer status-context-specific revert variants.
- Cross-session operation persistence, telemetry, progress percentages, and user-visible operation queue diagnostics.
- Recursive/ignored variants of `add`; group/force variants of `remove`; batch/directory unversioned cleanup; richer resolve choices and conflict editor flows; plus commit message templates/history breadth, project-property commit policy, and broader non-file commit scopes.
- Rich cleanup recovery diagnostics, automatic cleanup-required actions, cancellation/progress, externals cleanup UI, and vacuum/unversioned cleanup workflows.
- Operation suppression windows that prevent watcher-triggered duplicate refresh bursts.
- Auth, certificate, workspace trust, and diagnostics integration for operations that require network access.

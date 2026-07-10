# M5 Content, Diff, History, Blame Plan

## Goal

Build SubversionR content, diff, history, blame, and SVN Lens features on top of libsvn-backed content semantics without reading `.svn` internals from Rust or the VS Code Extension Host.

## M5a Implemented Slice

The first M5 slice adds the native and protocol foundation for BASE content retrieval:

- `content/get` requires an open `repositoryId`, matching `epoch`, repository-relative `path`, and `revision = "base"`.
- Unsupported revisions fail fast with `RPC_INVALID_PARAMS` instead of falling through to alternate retrieval paths.
- Absolute paths, parent-relative paths, drive-qualified paths, empty segments, and the repository root sentinel are rejected before native calls.
- The protocol response is binary-safe and carries `contentBase64`, `byteLength`, `mimeType`, `isBinary`, and `source`.
- The daemon advertises `contentGet` as a required initialize capability.
- The TypeScript backend startup gate requires `contentGet` before accepting an initialized sidecar.
- The Rust bridge abstraction returns bytes plus metadata only. It does not expose APR, Subversion handles, or final localized prose.
- The C bridge exposes `subversionr_bridge_content_get(runtime, path, revision, content)` as a hand-written narrow ABI.
- The C implementation accepts only `revision = "base"` and calls `svn_client_cat3` with BASE peg and operative revisions.
- The C implementation requests file properties from libsvn and maps `svn:mime-type` through `svn_mime_type_is_binary`.
- Native integration verifies that BASE content comes from libsvn and remains the committed file content after the working file is modified.

This slice intentionally does not implement VS Code `quickDiffProvider`, virtual document URI handling, text decoding, HEAD/previous/revision content, streaming content reads, diff computation, history, blame, or SVN Lens.

## M5a Gates

- Rust protocol contract tests cover the stable `ContentGetResponse` wire shape and `contentGet` capability.
- Rust RPC tests cover successful BASE content retrieval, unsupported revision rejection, invalid path rejection, and stale epoch rejection.
- The native bridge builds against the staged Apache Subversion 1.14.5 prefix.
- The native smoke test verifies the bridge still reports libsvn `1.14.5`.
- Ignored Rust native integration tests load the rebuilt bridge DLL and verify BASE content through a real local repository and working copy fixture.
- TypeScript checks and tests require the new `contentGet` initialize capability.

## M5b Implemented Slice

The second M5 slice wires the BASE content RPC into VS Code QuickDiff:

- Each registered Source Control instance receives a `quickDiffProvider`.
- The provider returns `svn-r-base` virtual document URIs only for projected local versioned file changes and conflicts.
- Unversioned, ignored, external, incoming remote, repository-root, repository-external, added, deleted, missing, obstructed, incomplete, and property-only resources do not receive QuickDiff originals.
- QuickDiff URI identity stores `repositoryId`, `epoch`, `generation`, repository-relative `path`, and `revision = "base"` in the query string.
- The URI does not expose the local working-copy root or encode repository identity in authority/path segments.
- `generation` is carried only to force original-resource URI invalidation as status projection changes. The backend request remains `repositoryId`, `epoch`, `path`, and `revision`.
- A readonly text document provider is registered once for the `svn-r-base` scheme during extension activation.
- The provider parses the virtual URI, calls `content/get`, validates response echoes, decodes base64 bytes, and returns UTF-8 text for text content.
- Binary BASE content returns a localized placeholder instead of pushing binary bytes into VS Code text documents.
- TypeScript content parsing rejects malformed requests, unsupported revisions, invalid base64, byte-length mismatches, malformed virtual URIs, and mismatched response identity.

This slice intentionally does not implement manual “open BASE” commands, text encoding detection beyond UTF-8 decoding, binary external viewers, HEAD/PREV/explicit revision content, streaming content, `vscode.diff` command surfaces, history, blame, or SVN Lens.

## M5b Gates

- `ContentGetRpcClient` tests cover request validation, base64 decode, empty files, byte-length mismatch, and response identity matching.
- `BackendContentClient` tests cover backend initialization and active JSON-RPC sender usage.
- Base content URI tests cover stable URI components and malformed URI rejection.
- Base content document provider tests cover text content and localized binary placeholder behavior.
- Source Control presenter tests cover QuickDiff original URI generation for supported local versioned text changes and rejection for unversioned, ignored, external, incoming, root, outside, added, deleted, missing, obstructed, incomplete, and property-only paths.
- TypeScript checks and extension tests pass.

## M5c Implemented Slice

The third M5 slice adds an explicit user-facing BASE diff command on top of the M5b virtual document provider:

- `subversionr.diffWithBase` opens a VS Code diff editor with the `svn-r-base` URI on the left and the working-copy file URI on the right.
- The command is contributed only to SubversionR SCM resource state context menus for `subversionr.changedFile.baseDiffable`, a VS Code-facing derived context for text file changes that have a supported BASE comparison.
- The command is hidden from the Command Palette because it requires a concrete SCM resource state argument.
- The controller accepts the SCM context as the menu-level file signal, then validates the current Source Control projection before opening a diff.
- Projection validation requires an open repository, matching `repositoryId`, matching `epoch`, local `changes` group source, projection context `subversionr.changedFile`, `kind = "file"`, a non-external resource, and a supported text status.
- Added, deleted, missing, obstructed, incomplete, and property-only file states do not receive the BASE diff menu context and fail fast with stable command error codes if invoked through a spoofed command argument.
- The generated BASE URI carries `repositoryId`, `epoch`, current projection `generation`, canonical repository-relative `path` from the projection, and `revision = "base"`.
- The working-copy side of the diff is derived from the projection working-copy root and canonical repository-relative path, not from untrusted command argument casing.
- Runtime diff titles are localized through the VS Code extension l10n bundle.

This slice intentionally does not implement open-BASE-only commands, editor context menu entry points, active-editor inference, added/deleted/missing/obstructed/incomplete synthetic content, property diffs, binary external viewers, HEAD/PREV/explicit revision comparisons, history, blame, or SVN Lens.

## M5c Gates

- Repository command controller tests cover successful BASE diff URI generation with projection-canonical paths, unavailable projection state, added-file rejection, unsafe-state rejection, property-only rejection, and non-file resource rejection.
- Source Control presenter tests cover derived base-diffable menu context assignment only for supported changed files.
- Extension manifest tests cover activation, command contribution, SCM menu placement, Command Palette hiding, and contributed command localization keys.
- Runtime localization tests require the diff editor title in English, Japanese, and Chinese bundles.
- TypeScript checks and extension tests pass.

## M5d Implemented Slice

The fourth M5 slice extends the existing libsvn-backed `content/get` foundation from BASE-only content to strict revision content:

- `content/get` now accepts `revision = "base"`, `revision = "head"`, and explicit numeric revision strings in the canonical form `r<N>`.
- Explicit `r<N>` revisions are constrained to the Windows x64 MSVC/libsvn `svn_revnum_t` range `0..=2147483647`.
- Invalid revision forms such as uppercase `HEAD`, bare numbers, empty `r`, negative revisions, leading-zero numeric revisions, out-of-range revisions, and working-copy pseudo-revisions fail fast before bridge calls.
- Extra `content/get` request fields are rejected instead of being ignored by the TypeScript client or Rust daemon.
- The protocol minor version advances to `1.10`, and revision content availability is negotiated through the `contentGetRevision` initialize capability.
- The C bridge keeps the existing narrow `subversionr_bridge_content_get(runtime, path, revision, content)` ABI and parses the revision string internally.
- The C implementation maps `base`, `head`, and `r<N>` to `svn_client_cat3` peg and operative revisions, preserving libsvn as the source of content semantics.
- The Rust native bridge validates the same revision grammar before crossing the C ABI and labels response sources as `libsvn-base`, `libsvn-head`, or `libsvn-revision`.
- The TypeScript `ContentGetRpcClient` validates request and response revision identity and rejects response source labels that do not match the requested revision family.
- The existing `svn-r-base` URI scheme remains BASE-only for QuickDiff and explicit BASE diff. This slice adds backend/content-client capability only, not a revision virtual-document scheme.

This slice intentionally does not implement user-facing HEAD or revision diff commands, history actions, PREV content, revision URI schemes, streaming content reads, authentication prompts, cancellation, cache policy, binary external viewers, or text encoding improvements.

## M5d Gates

- Protocol contract tests cover protocol minor `1.10` and the `contentGetRevision` capability.
- Rust RPC tests cover HEAD and explicit revision dispatch, invalid revision rejection before bridge calls, stale epoch preservation, invalid path preservation, and stable response serialization.
- TypeScript content client tests cover HEAD and explicit revision requests, strict invalid revision rejection, exact request fields, response identity validation, malformed response revision rejection, and revision/source mismatch rejection.
- Base content URI tests lock the `svn-r-base` scheme to `revision = "base"`.
- Backend startup tests require the new `contentGetRevision` capability before accepting an initialized sidecar.
- Ignored native integration tests verify that libsvn-backed BASE, HEAD, and explicit revision content return distinct expected bytes from a real local repository fixture.

## M5e Implemented Slice

The fifth M5 slice adds the backend-only `history/log` foundation on top of libsvn log semantics:

- `history/log` requires an open `repositoryId`, matching `epoch`, repository-relative `path`, explicit `startRevision`, explicit `endRevision`, explicit `limit`, and explicit boolean log options.
- `path = "."` is allowed for repository-root history. Other paths must be repository-relative slash paths without backslashes, drive qualifiers, parent segments, empty segments, or NUL bytes.
- `startRevision` accepts `head` or canonical numeric `r<N>`. `endRevision` accepts only canonical numeric `r<N>`.
- Numeric revisions are constrained to `0..=2147483647`, matching the staged Windows x64 MSVC libsvn `svn_revnum_t` range already enforced for revision content.
- `limit` is required and constrained to `1..=500`; no unbounded log request is accepted.
- Extra `history/log` request fields are rejected by both the Rust daemon and TypeScript client.
- The request exposes libsvn-aligned options as explicit booleans: `discoverChangedPaths`, `strictNodeHistory`, and `includeMergedRevisions`.
- The protocol minor version advances to `1.11`, and history availability is negotiated through the `historyLog` initialize capability.
- The response echoes repository identity, epoch, path, revision range, and limit, returns revision entries plus changed-path metadata, and labels the source as `libsvn-log`.
- Changed-path metadata preserves repository paths such as `/trunk/file`, SVN action letters, copy-from path/revision, node kind, and `true`/`false`/`unknown` text/property modification states.
- The current C bridge exposes `subversionr_bridge_history_log_with_auth(runtime, path, start_revision, end_revision, limit, discover_changed_paths, strict_node_history, include_merged_revisions, callbacks, log)` as the hand-written narrow ABI for this operation; M6u makes the auth callback table mandatory.
- The C implementation calls `svn_client_log5`, requests only `svn:author`, `svn:date`, and `svn:log`, and skips merge child stack sentinel entries with invalid revisions.
- The Rust native bridge copies bridge-owned log arrays immediately and does not expose APR, libsvn handles, or localized prose.
- The TypeScript layer adds `HistoryLogRpcClient` and `BackendHistoryClient` only. No commands, views, CodeLens, decorations, notifications, package manifest entries, or localized UI strings are added in this slice.

This slice intentionally does not implement history UI, revision details UI, line history, blame, mergeinfo visualization, page tokens, cancellation, auth/cert prompts, cache policy, or background remote polling.

## M5e Gates

- Protocol contract tests cover protocol minor `1.11`, the `historyLog` capability, and the stable `HistoryLogResponse` wire shape.
- Rust RPC tests cover successful history dispatch, root history path support, invalid path/revision/limit/extra-field rejection before bridge calls, stale epoch rejection, and option forwarding to `BridgeApi`.
- TypeScript history client tests cover request validation, exact-key rejection, response identity/source validation, changed-path parsing, malformed response rejection, and backend lazy initialization.
- Backend startup tests require the new `historyLog` capability before accepting an initialized sidecar.
- The native bridge builds against the staged Apache Subversion 1.14.5 prefix and the native smoke test still links and reports libsvn `1.14.5`.
- An ignored Rust native integration test verifies that real `svn_client_log5` history returns add/edit revision entries and changed paths from a local repository fixture.

## M5f Implemented Slice

The sixth M5 slice adds the backend-only `history/blame` foundation on top of libsvn blame semantics:

- `history/blame` requires an open `repositoryId`, matching `epoch`, a file `path`, explicit `pegRevision`, explicit `startRevision`, explicit `endRevision`, explicit line window, and explicit blame options.
- `path = "."` is rejected because this slice supports file blame only. Other paths must be repository-relative slash paths without backslashes, drive qualifiers, parent segments, empty segments, or NUL bytes.
- `pegRevision` and `endRevision` accept `base`, `head`, or canonical numeric `r<N>`. `startRevision` accepts only canonical numeric `r<N>`.
- Numeric revisions remain constrained to `0..=2147483647`.
- `lineStart` is 1-based and constrained to the native signed ABI range. `lineLimit` is constrained to `1..=5000`.
- Extra `history/blame` request fields are rejected by both the Rust daemon and TypeScript client.
- The request exposes libsvn-aligned options as explicit values: `ignoreWhitespace = none|change|all`, `ignoreEolStyle`, `ignoreMimeType`, and `includeMergedRevisions`.
- The protocol minor version advances to `1.12`, and blame availability is negotiated through the `historyBlame` initialize capability.
- The response echoes repository identity, epoch, path, revision range, line window, and blame options, returns line attribution entries, and labels the source as `libsvn-blame`.
- Line content is transported as `lineBase64` plus `byteLength`; neither Rust nor TypeScript assumes text encoding for blame line bytes.
- Line numbers exposed on the wire are 1-based, while libsvn's receiver line numbers are converted from its 0-based callback value.
- The current C bridge exposes `subversionr_bridge_history_blame_with_auth(runtime, path, peg_revision, start_revision, end_revision, ignore_whitespace, ignore_eol_style, ignore_mime_type, include_merged_revisions, line_start, line_limit, callbacks, blame)` as the hand-written narrow ABI for this operation; M6u makes the auth callback table mandatory.
- The C implementation calls `svn_client_blame6`, sets `svn_diff_file_options_t` from explicit request options, maps binary-file rejection to a stable bridge status, and treats `SVN_ERR_CEASE_INVOCATION` only as the expected line-window stop condition.
- The Rust native bridge copies bridge-owned blame arrays immediately and does not expose APR, libsvn handles, raw working-copy database state, or localized prose.
- The TypeScript layer adds `HistoryBlameRpcClient` and extends `BackendHistoryClient` only. No commands, views, CodeLens, decorations, package manifest entries, or localized UI strings are added in this slice.

This slice intentionally does not implement blame UI, current-line blame, gutter decorations, CodeLens, merge visualization UI, cache policy, cancellation, auth/cert prompts, or SVN Lens surfaces.

## M5f Gates

- Protocol contract tests cover protocol minor `1.12`, the `historyBlame` capability, and the stable `HistoryBlameResponse` wire shape.
- Rust RPC tests cover successful blame dispatch, invalid path/revision/window/option/extra-field rejection before bridge calls, stale epoch rejection, and option forwarding to `BridgeApi`.
- TypeScript blame client tests cover request validation, exact-key rejection, response identity/source validation, base64 byte-length validation, contiguous line-window validation, malformed response rejection, and backend lazy initialization.
- Backend startup tests require the new `historyBlame` capability before accepting an initialized sidecar.
- The native bridge builds against the staged Apache Subversion 1.14.5 prefix and the native smoke test still links and reports libsvn `1.14.5`.
- An ignored Rust native integration test verifies that real `svn_client_blame6` line attribution reflects add/edit revisions from a local repository fixture.

## M5g Implemented Slice

The seventh M5 slice turns the backend-only `history/log` foundation into a native VS Code history surface:

- The extension contributes a native `SVN History` TreeView under the Source Control view container.
- The view is implemented with a `TreeDataProvider`, not a webview, and the Extension Host only formats bounded libsvn log results for display.
- `subversionr.showRepositoryLog` opens repository-root history for an explicitly selected open repository and requests `path = "."`.
- `subversionr.showFileHistory` opens file history only from concrete SubversionR SCM resource states for versioned local files and conflicts.
- File history rejects unversioned, ignored, external, incoming, directory, repository-root, and spoofed resource states with stable command error codes.
- File history validates the current Source Control projection before opening the view and uses the projection-canonical repository-relative path rather than untrusted command-argument casing.
- Conflicted resources are accepted only when they are local versioned files in the conflicts/changes projection groups; conflicted externals and ignored resources remain rejected.
- History requests use explicit bounded parameters: `startRevision = "head"` for the first page, `endRevision = "r0"`, `discoverChangedPaths = true`, `strictNodeHistory = false`, and a configured `limit` constrained to `1..=500`.
- `strictNodeHistory = false` is used deliberately so default file history follows SVN copy history rather than presenting a Git-style file identity.
- `subversionr.history.pageSize` and `subversionr.history.includeMergedRevisions` are explicit window-scoped settings with manifest defaults and fail-fast runtime validation.
- The view renders a target root, revision rows, changed-path children, copy-from metadata, localized empty/placeholder rows, refresh, and a foreground-only Load More command.
- Load More continues below the oldest loaded revision by requesting `r<N-1>` down to `r0`; no page token, cache, or background prefetch is introduced.
- The TreeDataProvider ignores stale async refresh/load-more results when a newer history target or request generation has superseded them.
- The new command, view, configuration, runtime strings, and three priority localization bundles are covered by manifest and localization tests.

This slice intentionally does not implement revision detail panes, current-line blame, blame documents, gutter/status decorations, CodeLens, line history, history search/filter, arbitrary revision comparison, cancellation protocol, long-term history cache, or background remote polling.

## M5g Gates

- History settings tests cover bounded page size, include-merged validation, and fail-fast configuration errors.
- History TreeDataProvider tests cover exact `history/log` request parameters, repository history, file history, changed-path rendering, copy-from metadata, placeholder rows, and Load More continuation.
- Repository command controller tests cover repository-log target selection, projection-canonical file-history paths, unavailable projection state, and invalid SCM resource rejection.
- Extension manifest tests cover activation events, command contributions, SCM/resource/view menus, the native history view contribution, configuration schema, package localization keys, and runtime localization key parity.
- `pnpm check`, targeted extension tests, and `pnpm i18n:verify` pass.

## M5h Implemented Slice

The eighth M5 slice exposes explicit revision content from file history revision rows:

- The extension registers a readonly `svn-r-revision` virtual document provider backed by the existing `content/get` revision-capable RPC.
- `svn-r-revision` URIs carry only `repositoryId`, `epoch`, repository-relative `path`, and an explicit numeric `revision = r<N>`.
- The revision URI parser rejects `base`, `head`, malformed numeric revisions, duplicate query keys, local filesystem paths, repository-root paths, parent segments, drive-qualified paths, and NUL bytes.
- The provider calls `content/get` with the parsed explicit revision and decodes non-binary bytes as UTF-8 text.
- Binary revision content returns a localized placeholder instead of writing binary bytes into a VS Code text editor.
- File history revision rows receive an `subversionr.history.openRevision` command with a validated target `{ repositoryId, epoch, path, revision, label }`.
- Repository-log revision rows remain display-only for this slice because they do not carry a single working-copy file path.
- The command is contributed only for `subversionr.history.fileRevision` TreeView items and is hidden from the Command Palette.
- The extension command validates the target shape, creates a revision virtual URI, opens the readonly document, and lets the strict URI/content clients enforce path and revision grammar.
- The slice reuses the M5d libsvn revision content backend; no new native ABI, PREV diff, revision details webview, URL revision content, cache layer, or cancellation protocol is introduced.

This slice intentionally does not implement Revision Details webviews, Compare PREV, arbitrary two-revision compare, repository changed-path open by repository URL, binary external viewers, line history, blame UI, CodeLens, or revision content cache policy.

## M5h Gates

- Revision content URI tests cover stable URI shape, parsing, duplicate-key rejection, malformed URI rejection, and explicit numeric revision grammar.
- Revision content document provider tests cover `content/get` request forwarding, UTF-8 text display, and localized binary placeholders.
- History TreeDataProvider tests cover file revision commands and repository revision display-only behavior.
- Extension manifest tests cover the new activation event, command contribution, TreeView item menu placement, Command Palette hiding, package localization, and runtime localization key parity.
- `pnpm check`, targeted extension tests, and `pnpm i18n:verify` pass.

## M5i Implemented Slice

The ninth M5 slice adds a foreground file-history action that compares a selected file revision against the previous already loaded file-history revision:

- `subversionr.history.compareWithPrevious` is contributed only for `subversionr.history.fileRevision.previousDiffable` TreeView items and is hidden from the Command Palette.
- File-history revision rows become previous-diffable only when the immediately older log entry is already loaded in the current foreground page set.
- The oldest loaded file-history row remains open-only until the user explicitly loads more history; repository-log revision rows remain display-only because they do not carry a single working-copy file path.
- The compare target is `{ repositoryId, epoch, path, leftRevision, rightRevision, label }`, where both revisions are strict explicit `r<N>` values and `leftRevision < rightRevision`.
- The extension validates the TreeView node through `HistoryTreeDataProvider`, validates the final compare target through a separate command helper, creates two strict `svn-r-revision` virtual document URIs, and opens them with the built-in `vscode.diff` command using localized editor title text.
- The existing Open Revision command now also resolves its target from the TreeView node, so default item activation and `view/item/context` execution use the same provider-owned path.
- This slice reuses the M5d/M5h revision content backend and does not add native ABI, Rust RPC, page-token, cache, or background history prefetch behavior.
- This slice advances `DIF-003` and `HIS-010` for normal same-path file-history rows, but it does not claim complete peg-aware PREV semantics across rename/copy boundaries.

This slice intentionally does not implement full peg-revision content refs, copy-source path remapping, arbitrary two-revision or two-URL compare, multi-select history compare, repository changed-path open/compare by URL, binary external diff, line history, blame UI, CodeLens, or revision detail UI.

## M5i Gates

- History TreeDataProvider tests cover previous-diffable file revision context values, provider-owned Open Revision targets, compare targets for adjacent loaded file-history revisions, oldest-row rejection, and repository-row rejection.
- Compare command helper tests cover strict URI generation, explicit revision grammar, left/right revision ordering, path validation through the revision URI helper, and spoofed target rejection.
- Extension manifest tests cover the activation event, command contribution, TreeView item menu placement, Command Palette hiding, package localization, and runtime localization key parity for the compare command.
- Targeted extension tests pass for `historyTreeDataProvider`, `historyCompareRevisionCommand`, and `extensionManifest`.

## M5j Implemented Slice

The tenth M5 slice adds a readonly Revision Details document for already loaded history rows:

- `subversionr.history.openRevisionDetails` is contributed for repository and file revision rows and hidden from the Command Palette.
- Repository revision rows use Open Revision Details as their default command. File revision rows keep Open Revision as their default command and expose Revision Details through the TreeView item menu.
- The command validates the current TreeView revision node through `HistoryTreeDataProvider`; shallow clones, deep clones, stale nodes, and non-revision rows are rejected with stable command error codes.
- Revision Details documents are served by a strict in-memory `svn-r-revision-details` virtual document provider. The URI carries only an opaque generated document id and `r<N>.txt` display path, not local filesystem paths or serialized log metadata; cached details are released when the backing virtual document is closed.
- The document renders only metadata already loaded by `history/log`: repository identity, target scope, revision, author, date, log message, merge child flags, changed paths, node kind, text/property modified flags, and copy-from metadata.
- The slice partially advances `HIS-008` for the existing history surfaces without adding native ABI, Rust RPC, extra `history/log` fetches, page tokens, cache, background prefetch, or a webview.

This slice intentionally does not implement full revprop retrieval beyond `svn:author`, `svn:date`, and `svn:log`, mergeinfo visualization, changed-path open/compare by repository URL, working-copy open actions, copy URL/message/revision commands, arbitrary revision compare, line history, blame UI, CodeLens, or Revision Details webviews.

## M5j Gates

- History TreeDataProvider tests cover details targets for file and repository revision rows, repository-row default command wiring, and spoofed-node rejection.
- Revision Details document tests cover strict URI shape/parsing, localized metadata rendering, nullable metadata placeholders, changed-path copy-from rendering, unknown-document rejection, and document release after close.
- Extension manifest tests cover the activation event, command contribution, TreeView item menu placement, Command Palette hiding, package localization, and runtime localization key parity for the details command and document strings.
- Targeted extension tests pass for `historyRevisionDetailsDocument`, `historyTreeDataProvider`, and `extensionManifest`.

## M5k Implemented Slice

The eleventh M5 slice exposes file blame through a readonly VS Code document backed by the existing `history/blame` RPC:

- `subversionr.showBlame` is contributed for local versioned file SCM resources in Changes and Conflicts and hidden from the Command Palette.
- The repository command controller validates the selected SCM resource through the current Source Control projection, rejects spoofed/stale/unversioned/ignored/external/incoming/directory targets, and uses the projection-canonical repository-relative path.
- The command opens a strict `svn-r-blame` virtual document using fixed explicit BASE blame parameters: `pegRevision = base`, `startRevision = r0`, `endRevision = base`, `lineStart = 1`, `lineLimit = 5000`, `ignoreWhitespace = none`, `ignoreEolStyle = false`, `ignoreMimeType = false`, and `includeMergedRevisions = false`; crafted URIs outside that contract are rejected.
- The blame URI carries repository identity, epoch, projection generation, repository-relative path, and the fixed revision/window/options. The working-copy root is not encoded into URI authority/path segments, and the generation is used only for VS Code virtual-document invalidation before forwarding the strict `history/blame` request.
- The document provider calls `history/blame`, renders localized metadata, line attribution, uncommitted lines, nullable author/date placeholders, merged-revision markers, and line text decoded from the binary-safe blame payload.
- This slice advances `HIS-004` and `PRD-009` for SCM resource files without adding native ABI, Rust RPC, cache, cancellation, background polling, or editor decoration behavior.

This slice intentionally does not implement active-editor blame for unmodified files, current-line blame, gutter/status decorations, CodeLens, hover, line history, BASE-to-WORKING uncommitted line mapping, HEAD/revision blame, pagination/load-more, cache policy, cancellation protocol, binary/external viewer UX, Tortoise blame, auth/cert prompts, or legacy aliases.

## M5k Gates

- Blame document tests cover strict URI shape/parsing, duplicate-key rejection, invalid path rejection, fixed BASE blame contract rejection, generation-based invalidation identity, RPC request forwarding without generation, localized metadata rendering, nullable metadata placeholders, merged revision display, `hasMore` display, and line text decoding.
- Repository command controller tests cover projection-canonical blame targets and invalid SCM resource rejection.
- Extension manifest tests cover activation, command contribution, SCM resource menu placement, Command Palette hiding, package localization, and runtime localization key parity for the blame command and document strings.
- Targeted extension tests pass for `historyBlameDocument`, `repositoryCommandController`, and `extensionManifest`.

## M5l Implemented Slice

The twelfth M5 slice exposes the existing readonly BASE content document as an explicit SCM resource command:

- `subversionr.openBase` is contributed for local `subversionr.changedFile.baseDiffable` SCM resources and hidden from the Command Palette.
- The repository command controller validates the selected SCM resource through the current Source Control projection, rejects spoofed, unavailable, unsupported, or non-file targets, and uses the projection-canonical repository-relative path.
- The command opens a strict `svn-r-base` virtual document with the current repository id, epoch, projection generation, repository-relative path, and `revision = base`.
- The extension opens the readonly virtual document through the built-in VS Code open command with a localized editor title.
- This slice advances `DIF-001` and command-catalog row `svnNative.file.openBase` without adding native ABI, Rust RPC, working-copy scans, CLI use, TortoiseSVN integration, remote polling, or alternate BASE resolution paths.

This slice intentionally does not implement editor context menu entry points, open BASE for unmodified active editors, synthetic added/deleted/missing content, property diffs, binary external viewers, HEAD/arbitrary revision open commands, or legacy aliases.

## M5l Gates

- Repository command controller tests cover projection-canonical BASE open targets and invalid SCM resource rejection.
- Extension manifest tests cover activation, command contribution, SCM resource menu placement, Command Palette hiding, package localization, and runtime localization key parity for the Open BASE command and document title string.
- Targeted extension tests pass for `repositoryCommandController` and `extensionManifest`.

## M5m Implemented Slice

The thirteenth M5 slice adds clipboard utilities for already loaded history revision rows:

- `subversionr.history.copyMessage` and `subversionr.history.copyRevision` are contributed for repository and file revision TreeView rows and hidden from the Command Palette.
- The extension registers the explicit legacy aliases required by `Reference/legacy_migration.csv`: `svn.itemlog.copymsg`, `svn.repolog.copymsg`, `svn.itemlog.copyrevision`, and `svn.repolog.copyrevision`. These aliases are activation-only/programmatic compatibility commands and are not contributed as user-visible command titles.
- The history TreeDataProvider validates the selected revision node through the current live TreeView node set before returning copy data, so cloned or stale nodes are rejected with stable command error codes.
- Copy Revision Number writes the bare SVN revision number, for example `8`, to the clipboard. Copy Commit Message writes the original `svn:log` value and writes an empty string when `svn:log` is absent; it does not copy localized placeholder text.
- The commands use the VS Code clipboard API and localized success notifications.
- This slice advances `HIS-008`, command-catalog rows `svnNative.history.copyMessage` and `svnNative.history.copyRevision`, and the four explicit legacy migration rows without adding native ABI, Rust RPC, history refetches, background prefetch, or additional compatibility aliases.

This slice intentionally does not implement copy URL, changed-path URL reconstruction, revision details action buttons, repository changed-path open/compare by URL, cache policy, or history search/filter.

## M5m Gates

- History TreeDataProvider tests cover current-node copy targets, nullable `svn:log` preservation, and cloned-node rejection.
- History copy command tests cover clipboard writes for revision numbers, original log messages, absent log messages, localized success notifications, and invalid target rejection before clipboard writes.
- Extension manifest tests cover canonical command activation, explicit legacy alias activation, command contribution, TreeView item menu placement, Command Palette hiding, package localization, and runtime localization key parity.
- Targeted extension tests pass for `historyTreeDataProvider`, `historyCopyCommand`, and `extensionManifest`.

## M5n Implemented Slice

The fourteenth M5 slice exposes user-triggered HEAD content and Working Copy versus HEAD comparison for local changed file SCM resources:

- `subversionr.openHead` and `subversionr.diffWithHead` are contributed for local `subversionr.changedFile.baseDiffable` SCM resources and hidden from the Command Palette.
- The extension registers the explicit legacy aliases required by `Reference/legacy_migration.csv`: `svn.openHEADFile` and `svn.openChangeHead`. These aliases are activation-only/programmatic compatibility commands and are not contributed as user-visible command titles.
- HEAD content uses a separate mutable `svn-r-head` virtual document scheme instead of widening immutable `svn-r-revision` explicit-revision semantics.
- Each HEAD command invocation creates a strict HEAD URI containing repository id, epoch, projection generation, repository-relative path, `revision = head`, and a fresh request id. The document provider forwards only repository id, epoch, path, and `revision = head` to `content/get`.
- The repository command controller validates selected SCM resources through the current Source Control projection, rejects spoofed, unavailable, stale, unsupported, or non-file targets, and uses the projection-canonical repository-relative path.
- This slice advances `DIF-002`, command-catalog rows `svnNative.file.openHead` and `svnNative.file.compareHead`, and the two explicit legacy migration rows without adding native ABI, Rust RPC, background remote polling, cache invalidation machinery, or alternate HEAD resolution paths.

This slice intentionally does not implement editor context menu entry points, open HEAD for unmodified active editors, peg-aware URL HEAD content across rename/copy boundaries, stale open HEAD tab invalidation, cancellation/auth prompts, synthetic added/deleted/missing diffs, arbitrary revision/URL diffs, binary external viewers, or additional legacy aliases.

## M5n Gates

- HEAD content URI tests cover strict URI shape/parsing, duplicate-key rejection, invalid path rejection, `revision = head` enforcement, and request-id validation.
- HEAD content document provider tests cover `content/get` request forwarding without generation/request id, UTF-8 text display, and localized binary placeholders.
- Repository command controller tests cover projection-canonical Open HEAD and Compare with HEAD targets, per-invocation HEAD request identities, unavailable/stale projection errors, and invalid SCM resource rejection.
- Extension manifest tests cover canonical command activation, explicit legacy alias activation, command contribution, SCM resource menu placement, Command Palette hiding, package localization, and runtime localization key parity.
- Targeted extension tests pass for `headContentUri`, `headContentDocumentProvider`, `repositoryCommandController`, and `extensionManifest`.

## M5o Implemented Slice

The fifteenth M5 slice adds a projection-backed File Header CodeLens foundation for editor-visible SVN history actions:

- The extension registers a `file`-scheme CodeLens provider after repository session state is available. The provider reads only open repository sessions and the current Source Control projection; it does not start backend requests, scan the working copy, read `.svn`, or call the SVN CLI.
- `provideCodeLenses` returns unresolved CodeLens entries on line 0 for projected local versioned text documents only. `resolveCodeLens` binds visible lenses to localized commands, following the VS Code CodeLens provider model.
- The first lens summarizes the current projected changed revision, author, and date from status metadata and opens file history. Additional lenses open File History, Blame, and repository Log through the existing canonical SubversionR commands.
- Eligibility is conservative: file documents must map to the most-specific open repository, match the current projection epoch, be local file resources in Changes or Conflicts, not be ignored/external/deleted/missing, and stay below `subversionr.lens.maxFileLines`.
- The Source Control resource store maintains an exact path map plus a case-insensitive path index for lightweight lookup, so File Header CodeLens avoids rebuilding sorted full projections or scanning local resources in `provideCodeLenses`.
- The extension refreshes File Header CodeLens on lens setting changes, projection changes, and repository session changes. Session changes are emitted only after the opened session is visible to `listOpenSessions`.
- New settings `subversionr.lens.enabled`, `subversionr.lens.fileHeader`, and `subversionr.lens.maxFileLines` are manifest-backed, fail-fast validated, localized, and deliberately do not introduce `svnNative.*` or legacy `svn.*` setting aliases.
- This slice advances `HIS-006`, `PRD-009`, and `PER-011` for projected local SCM file resources without adding native ABI, Rust RPC, history caches, current-line blame, symbol lenses, unmodified-file discovery, background remote polling, or compatibility aliases.

This slice intentionally does not implement CodeLens for normal unmodified versioned files that are absent from the current projection, Compare PREV from active editors, latest-revision lookup beyond projected status metadata, current-line blame, revision hover, symbol lens, line history, full Lens cancellation, or large-file visible-range fallback.

## M5o Gates

- Lens settings tests cover default values, fail-fast validation, and absence of legacy setting aliases.
- File Header CodeLens provider tests cover unresolved lens creation, resolve-time command binding, localized titles, most-specific repository matching, path-before-lookup behavior, setting disables, max-line threshold, outside/root/non-file schemes, and rejection of unversioned/incoming/external/ignored/directory/deleted resources.
- Source Control store/projection/session tests cover indexed single-resource lookup without building full projections, index updates after deltas, projection-change events, and session-change events after opened sessions are visible.
- Extension manifest tests cover the three new lens settings, absence of legacy aliases, package localization keys, and runtime localization key parity.
- Targeted extension tests pass for `lensSettings`, `fileHeaderCodeLensProvider`, and `extensionManifest`.

## M5p Implemented Slice

The sixteenth M5 slice extends the File Header CodeLens surface with BASE and HEAD comparison actions for projected base-diffable files:

- Base-diffable editor-visible files receive additional `Compare BASE` and `Compare HEAD` CodeLens entries between the summary lens and the existing File History/Blame/Log lenses.
- The compare lenses invoke existing canonical commands `subversionr.diffWithBase` and `subversionr.diffWithHead`; no new native ABI, Rust RPC, content URI scheme, or backend request type is introduced.
- The compare command arguments deliberately use the `subversionr.changedFile.baseDiffable` SCM context required by the existing repository command controller. History and blame lenses continue to use the projection's original context.
- Non-base-diffable projected files, including property-only changes and conflicted files, keep only the existing summary/history/blame/log lenses and do not expose unsupported compare actions.
- The slice advances `HIS-006`, `PRD-009`, `PER-011`, `DIF-001`, `DIF-002`, and command-catalog rows `svnNative.file.compareBase` and `svnNative.file.compareHead` for File Header CodeLens without adding compatibility aliases, CLI dependency, remote polling, unmodified-file discovery, or Compare PREV semantics.

This slice intentionally does not implement Compare PREV from active editors, editor context menu BASE/HEAD/diff entries, CodeLens for normal unmodified versioned files absent from the current projection, synthetic added/deleted/missing content, property diffs, binary external viewers, arbitrary revision/URL diff commands, current-line blame, line history, hover, or symbol lenses.

## M5p Gates

- File Header CodeLens provider tests cover unresolved lens count for base-diffable files, resolve-time BASE/HEAD compare command binding, base-diffable SCM context arguments for diff commands, and absence of compare lenses for property-only/conflicted files.
- Extension manifest localization parity covers the new runtime CodeLens titles in English, Japanese, and Chinese bundles.
- Targeted extension tests pass for `fileHeaderCodeLensProvider` and `extensionManifest`.

## M5q Implemented Slice

The seventeenth M5 slice exposes existing file actions in the editor context menu for projected local SVN files:

- The extension maintains projection-backed activity context keys `subversionr.activeEditorHistoryFile` and `subversionr.activeEditorBaseDiffable`.
- Context keys are refreshed on active editor changes, Source Control projection changes, and repository session changes. Files outside open repository scopes are rejected before projection lookup.
- Editor context menu entries are grouped under a localized `SubversionR` submenu. The submenu is shown only for `resourceScheme == file && subversionr.activeEditorHistoryFile`; BASE/HEAD submenu actions add the stricter `subversionr.activeEditorBaseDiffable` guard.
- Existing canonical commands now accept the VS Code `editor/context` file URI argument for these read-only content/history/diff actions. Write operations and refresh/update operations still require SCM resource states.
- Command execution still revalidates the current Source Control projection and uses projection-canonical repository-relative paths before opening content, diff, history, or blame surfaces.
- The slice advances command-catalog rows `svnNative.file.compareBase`, `svnNative.file.compareHead`, `svnNative.history.file`, and `svnNative.history.blame` for editor surfaces without adding native ABI, Rust RPC, protocol changes, SVN CLI dependency, remote polling, legacy aliases, or background scans.

This slice intentionally does not implement editor context menu entries for write operations, refresh/update operations, unmodified versioned files absent from the current projection, Compare PREV, arbitrary revision/URL diff commands, added/deleted/missing synthetic content, property diff rendering, binary external viewers, current-line blame, line history, hover, or symbol lenses.

## M5q Gates

- Active editor context service tests cover base-diffable context, history-only context for non-base-diffable files, and outside-repository files clearing context keys without projection lookup.
- Repository command controller tests cover editor URI arguments for BASE diff and file history, plus outside-repository URI rejection with stable command errors.
- Extension manifest tests cover editor context menu contribution and SubversionR activity context key guards.
- Targeted extension tests pass for `activeEditorContextService`, `repositoryCommandController`, and `extensionManifest`.

## M5r Implemented Slice

The eighteenth M5 slice adds a projection-backed Compare PREV command for editor-visible local SVN files:

- `subversionr.diffWithPrevious` is contributed as a hidden canonical command and exposed through the SubversionR editor context submenu only when the active projected local history-file editor has a valid previous-revision candidate.
- The extension registers the explicit legacy alias required by `Reference/legacy_migration.csv`: `svn.openChangePrev`. The alias is activation-only/programmatic compatibility and is not contributed as a user-visible command title.
- File Header CodeLens now shows `Compare PREV` between the revision summary lens and BASE/HEAD compare lenses when projected status metadata carries a valid changed revision.
- Command execution revalidates the active editor or SCM resource argument through the current Source Control projection, matching repository id, epoch, resource kind, projection-canonical path, supported local history-file context, and the carried projection generation when CodeLens or SCM resource state supplies it.
- Compare PREV performs no background prefetch. On invocation it requests a bounded file history page through `history/log` with `startRevision = r<changedRevision>`, `endRevision = r0`, `limit = 2`, `discoverChangedPaths = false`, `strictNodeHistory = false`, and `includeMergedRevisions = false`.
- The command opens a VS Code diff between strict immutable `svn-r-revision` URIs for the previous and current file-history revisions. Unsupported targets, invalid changed revisions, stale projections, missing previous revisions, and outside-repository editor URIs fail fast with stable command errors.
- This slice advances `DIF-003`, `HIS-006`, and command-catalog row `svnNative.file.comparePrev` for projected local file surfaces without adding native ABI, Rust RPC, SVN CLI dependency, background remote polling, a revision cache, or synthetic working-copy content.

This slice intentionally does not implement full peg-aware PREV across rename/copy boundaries, Compare PREV for unmodified versioned files absent from the projection, added/deleted/missing synthetic content, property diff rendering, binary external viewers, arbitrary revision/URL diff commands, current-line blame, line history, hover, symbol lenses, or broader SVN Lens UI surfaces.

## M5r Gates

- Repository command controller tests cover editor URI and SCM resource Compare PREV invocation, bounded file-history requests, strict revision diff URI construction, stale projection generation rejection, missing previous-revision rejection, and invalid changed-revision rejection before history requests.
- File Header CodeLens provider tests cover PREV lens placement, command binding, absence when changed revision is not a valid previous-revision candidate, and coexistence with BASE/HEAD compare lenses.
- Extension manifest tests cover canonical command activation, explicit legacy alias activation, command contribution, editor context menu placement, Command Palette hiding, package localization, and runtime localization key parity.
- Targeted extension tests pass for `repositoryCommandController`, `fileHeaderCodeLensProvider`, and `extensionManifest`.

## M5s Implemented Slice

The nineteenth M5 slice adds loaded-row Compare Revisions for file history:

- `subversionr.history.compareRevisions` is contributed for multi-selected file revision rows in the native `SVN History` TreeView and hidden from the Command Palette.
- The extension registers the explicit legacy aliases required by `Reference/legacy_migration.csv`: `svn.itemlog.openDiff` and `svn.repolog.openDiff`. These aliases are activation-only/programmatic compatibility commands and are not contributed as user-visible command titles.
- The `SVN History` TreeView enables multi-selection. Single-row history actions are hidden while multiple rows are selected so they do not silently act on only the focused revision.
- Command execution validates exactly two current provider-owned file revision nodes from the same loaded file-history target, requires the focused row to be part of the selection, rejects duplicates, orders revisions older-to-newer, and opens a VS Code diff between strict immutable `svn-r-revision` URIs.
- The slice performs no history refetch, background prefetch, native ABI change, Rust RPC change, SVN CLI call, Tortoise integration, or URL/repository revision comparison. It compares only already loaded revisions for the same file history target.
- This slice advances `HIS-010`, `DIF-004`, and command-catalog row `svnNative.history.compare` for a bounded same-file loaded-history case without claiming full arbitrary revision/URL diff semantics.

This slice intentionally does not implement repository revision comparison, changed-path open/compare by repository URL, copy URL commands, full peg-aware compare across rename/copy boundaries beyond the loaded file-history path, arbitrary URL diff commands, current-line blame, line history, hover, symbol lenses, or broader SVN Lens UI surfaces.

## M5s Gates

- History TreeDataProvider tests cover two-row loaded file revision compare target creation, reverse selection ordering, duplicate/count/focused-row validation, cloned-node rejection, and repository-row rejection.
- Extension manifest tests cover canonical command activation, explicit legacy alias activation, command contribution, multi-select view-item menu placement, single-row action hiding during multi-selection, Command Palette hiding, and package localization.
- Targeted extension tests pass for `historyTreeDataProvider` and `extensionManifest`.

## M5t Implemented Slice

The twentieth M5 slice adds a foreground filter for already loaded `SVN History` rows:

- `subversionr.history.searchLoaded` is contributed to the native `SVN History` TreeView title menu and hidden from the Command Palette.
- The extension registers the explicit legacy alias required by `Reference/legacy_migration.csv`: `svn.searchLogByText`. The alias is activation-only/programmatic compatibility and is not contributed as a user-visible command title.
- The command opens a localized input box, validates the query length, and applies the filter only to the provider's already loaded `history/log` entries.
- The filter matches raw loaded revision metadata: revision number, author, date, log message, changed-path action/path/copy-from metadata, node kind, and text/property modified flags. It does not search localized placeholder text or reconstruct repository URLs.
- Empty trimmed input clears the filter. Cancelled input is a no-op. Opening a different history target clears the filter and TreeView message.
- Zero matches render a localized empty row while keeping explicit `Load More` available if the current loaded page has more history. Search never triggers `history/log`, future `history/search`, Rust/native calls, the SVN CLI, TortoiseSVN, background prefetch, or automatic pagination.
- Hidden previously visible revision nodes are invalidated when the filter changes. Compare PREV semantics continue to use the unfiltered loaded SVN log order rather than the previous visible filtered row.
- This slice advances `HIS-011` and the command-catalog row `svnNative.history.search` for a bounded loaded-history filter without claiming backend history search or full repository-wide search semantics.

This slice intentionally does not implement `history/search` RPC, backend/native search, author/date/path query grammar, full repository log search, background search, automatic page loading on zero matches, persistent history cache, cancellation protocol, or URL-based history actions.

## M5t Gates

- History TreeDataProvider tests cover loaded-entry filtering across revision metadata, messages, changed paths, copy-from metadata, zero-match rows, explicit Load More preservation, no backend calls during search, search clearing, target-switch clearing, stale-node rejection, missing-target rejection, and invalid query rejection.
- History search command tests cover input prompt wiring, current-query defaults, cancellation no-op behavior, clear behavior, TreeView message updates, and query-length validation.
- Extension manifest tests cover canonical command activation, explicit legacy alias activation, command contribution, view-title placement, Command Palette hiding, package localization, and runtime localization key parity.
- Targeted extension tests pass for `historyTreeDataProvider`, `historySearchCommand`, and `extensionManifest`.

## M5u Implemented Slice

The twenty-first M5 slice adds the manifest-backed settings baseline for the remaining SVN Lens surfaces:

- `subversionr.lens.currentLine`, `subversionr.lens.hover`, and `subversionr.lens.symbols` are explicit window-scoped settings under the current SubversionR namespace.
- Defaults match the product settings catalog: current-line blame context and revision hover are enabled by default, while optional symbol history CodeLens remains disabled by default.
- `readLensSettings` fail-fast validates all three settings as booleans. It does not read `svnNative.*` or legacy `svn.*` aliases and does not introduce setting migration behavior.
- The existing `subversionr.lens.enabled`, `subversionr.lens.fileHeader`, and `subversionr.lens.maxFileLines` contract remains unchanged.
- This slice adds settings and localization only. It does not enable any unimplemented current-line, hover, or symbol UI behavior.
- This slice prepares `HIS-005`, `HIS-007`, `HIS-006`, `PRD-009`, and `PER-011` for later SVN Lens UI work without adding backend/native calls, background blame, history caches, or compatibility aliases.

This slice intentionally does not implement current-line blame decorations/status bar, revision hover providers, symbol history CodeLens, line history, backend cancellation, background prefetch, or blame/history caching.

## M5u Gates

- Lens settings tests cover defaults, fail-fast malformed-value validation, and absence of `svnNative.*`/legacy `svn.*` setting aliases for the new Lens settings.
- Extension manifest tests cover contributed window-scoped setting schemas and package localization keys in English, Japanese, and Chinese.
- File Header CodeLens provider tests continue to cover unchanged behavior with the expanded `LensSettings` contract.
- Targeted extension tests pass for `lensSettings` and `extensionManifest`.

## M5v Implemented Slice

The twenty-second M5 slice adds a conservative current-line blame status bar baseline:

- The extension creates one contextual status bar item with a stable VS Code item id, short text, and a command that opens the existing full-file `subversionr.showBlame` view.
- The service is projection-backed. It uses only open repository sessions and `SourceControlProjectionService.getProjectedResource`; it does not scan the working copy, read `.svn`, call the SVN CLI, or add Rust/native ABI.
- The status bar requests exactly one foreground `history/blame` line with `pegRevision = base`, `startRevision = r0`, `endRevision = base`, `lineStart = active editor line + 1`, `lineLimit = 1`, `ignoreWhitespace = none`, no EOL/MIME ignore, and no merged revisions.
- Eligibility is deliberately narrow until BASE-to-WORKING line mapping exists: projected local `changes` file resources only, `subversionr.changedFile` context only, non-external, non-ignored/non-unversioned, non-deleted/non-missing, non-added/non-replaced/non-obstructed/non-incomplete/non-conflicted local status, `nodeStatus = normal`, and `textStatus = normal`.
- Dirty editors, text-modified files, conflicts, unversioned/ignored/external resources, remote-only entries, missing/deleted states, absent projection state, oversized documents, and unknown/local-change blame rows hide the item instead of showing a misleading revision.
- Cursor, active-editor, current-document, projection, session, and Lens setting changes debounce through the service and stale async blame responses are discarded by refresh serial.
- Runtime status text and tooltip strings are localized through the VS Code l10n bundle.
- This slice advances `HIS-005`, `PRD-009`, and `PER-011` as a safe UI foundation without claiming full uncommitted-line semantics.

This slice intentionally does not implement BASE-to-WORKING diff line mapping, `Uncommitted` current-line display, gutter decorations, hover details, revprop/log-message enrichment, current-line cache policy, backend cancellation, unmodified-file discovery outside projection, or symbol/line-history surfaces.

## M5v Gates

- Current-line blame status bar tests cover single-line blame request identity, localized status item rendering, full-blame command arguments, disabled-setting behavior, outside-repository short-circuiting, text-modified resource rejection, and stale response discard.
- Extension manifest runtime localization parity covers the new status bar strings in English, Japanese, and Chinese bundles.
- Targeted extension tests pass for `currentLineBlameStatusBarService` and `extensionManifest`.

## M5w Implemented Slice

The twenty-third M5 slice adds a conservative current-line blame hover baseline:

- The extension registers one `file`-scheme VS Code `HoverProvider` for `subversionr.lens.hover`.
- Hover requests are foreground and on-demand only. The provider does not start background scans, status refreshes, history prefetch, SVN CLI calls, wc.db reads, Rust/protocol changes, or native ABI changes.
- The provider uses the same safe line identity boundary as M5v: projected local `changes` file resources only, `subversionr.changedFile` context only, non-external, non-ignored/non-unversioned, non-deleted/non-missing, non-added/non-replaced/non-obstructed/non-incomplete/non-conflicted local status, `nodeStatus = normal`, `textStatus = normal`, non-dirty editor documents, and files under `subversionr.lens.maxFileLines`.
- For eligible files, the provider requests exactly one `history/blame` line with `pegRevision = base`, `startRevision = r0`, `endRevision = base`, `lineStart = hovered editor line + 1`, `lineLimit = 1`, `ignoreWhitespace = none`, no EOL/MIME ignore, and no merged revisions.
- The hover displays localized `SVN Blame`, revision, author, and date metadata from the libsvn blame row. Dynamic Markdown content is escaped and command links are deliberately not emitted in this slice.
- Cancelled hovers, dirty editors, text-modified files, conflicts, unversioned/ignored/external resources, remote-only entries, missing/deleted states, absent projection state, oversized documents, local-change blame rows, and unknown-revision rows return no hover instead of showing a misleading line attribution.
- This slice advances `HIS-005`, `HIS-007`, `PRD-009`, and `PER-011` as a safe editor hover foundation without claiming full uncommitted-line semantics.

This slice intentionally does not implement BASE-to-WORKING diff line mapping, `Uncommitted` hover display, log-message summaries, changed-path/mergeinfo/copy-lineage hover content, hover command links, line history, current-line cache policy, backend cancellation protocol, unmodified-file discovery outside projection, or symbol lenses.

## M5w Gates

- Current-line blame hover provider tests cover one-line blame request identity, localized escaped Markdown rendering, disabled-setting behavior, outside-repository short-circuiting, dirty/text-modified/conflicted/unsafe-local-state/unsafe-node-state rejection, cancellation before and after blame requests, and local-change/unknown-revision rejection.
- TypeScript checks verify the provider is compatible with VS Code `HoverProvider` registration.
- Targeted extension tests pass for `currentLineBlameHoverProvider`.

## M5x Implemented Slice

The twenty-fourth M5 slice adds the optional symbol history CodeLens baseline:

- The extension registers a second `file`-scheme VS Code `CodeLensProvider` for `subversionr.lens.symbols`, which remains disabled by default.
- `provideCodeLenses` performs only local eligibility checks plus `vscode.executeDocumentSymbolProvider`. It returns unresolved lenses and does not call libsvn, Rust RPC, the SVN CLI, wc.db, or background history prefetch.
- Eligibility follows the same safe line identity boundary as M5w: projected local `changes` file resources only, `subversionr.changedFile` context only, non-external, non-ignored/non-unversioned, non-deleted/non-missing, non-added/non-replaced/non-obstructed/non-incomplete/non-conflicted local status, `nodeStatus = normal`, `textStatus = normal`, non-dirty editor documents, and files under `subversionr.lens.maxFileLines`.
- Document symbols from VS Code `DocumentSymbol` trees and current-document `SymbolInformation` results are flattened into bounded symbol ranges. Missing symbols, invalid ranges, ranges outside the document, and ranges over the blame line-window limit produce no lens.
- `resolveCodeLens` is the only stage that requests `history/blame`. It requests exactly the visible symbol range with `pegRevision = base`, `startRevision = r0`, `endRevision = base`, `ignoreWhitespace = none`, no EOL/MIME ignore, and no merged revisions.
- A resolved symbol lens binds to the existing `subversionr.showBlame` command and displays localized conservative aggregate metadata: latest revision, distinct author count, and distinct revision count.
- Cancelled resolution, blame errors, incomplete windows, `hasMore`, local-change rows, unknown-revision rows, and non-contiguous blame rows leave the lens unresolved instead of showing partial attribution.
- This slice advances `HIS-007`, `PRD-009`, and `PER-011` without claiming BASE-to-WORKING line mapping, copy lineage, log summaries, caching, or full line history.

This slice intentionally does not implement symbol history cache policy, visible-range prefetch, backend cancellation protocol, BASE-to-WORKING line mapping, `Uncommitted` symbol attribution, log-message summaries, copy-lineage/mergeinfo aggregation, changed-path drilldown, line history, symbol decorations, or unmodified-file discovery outside projection.

## M5x Gates

- Symbol history CodeLens tests cover unresolved lens creation, document-symbol and symbol-information handling, resolve-time blame request identity, localized aggregate command binding, disabled/outside/dirty/oversized/unsafe-state rejection before symbol lookup, cancellation, blame failure, incomplete blame, local-change rows, and unknown-revision rows.
- Extension manifest runtime localization parity covers the new symbol aggregate title in English, Japanese, and Chinese bundles.
- Targeted extension tests pass for `symbolHistoryCodeLensProvider` and `extensionManifest`.

## M5y Implemented Slice

The twenty-fifth M5 slice enriches the conservative current-line blame hover with a bounded SVN log summary:

- After a successful one-line `history/blame` response with a concrete non-local revision, the hover provider requests exactly one `history/log` entry for the same projected path and revision with `startRevision = rN`, `endRevision = rN`, `limit = 1`, no changed paths, no strict node-history walk, and no merged revisions.
- The hover now displays localized `Log Message:` metadata with the first non-empty trimmed log-message line, or localized `No log message` when the single matching revision has no message.
- Log messages are treated as untrusted repository content. Dynamic Markdown is escaped, including command-link and HTML-like characters, and the hover still emits no command links.
- Cancellation before blame, after blame, or after the log request returns no hover. Blame failures, log failures, local-change rows, unknown-revision rows, missing log rows, and revision-mismatched log rows also return no hover instead of showing partial or misleading attribution.
- This slice advances `HIS-005`, `HIS-007`, `PRD-009`, and `PER-011` by closing the first-log-line hover gap from the product reference without broadening the safe line identity boundary.

This slice intentionally does not implement peg-aware current-line log lookup across rename/copy boundaries, changed-path/mergeinfo/copy-lineage hover content, hover command links, line history, BASE-to-WORKING line mapping, `Uncommitted` hover display, backend cancellation protocol, current-line cache policy, or rich Revision Details hover surfaces.

## M5y Gates

- Current-line blame hover provider tests cover blame-to-log request identity, first non-empty log line extraction, empty/null/whitespace message rendering, dynamic Markdown escaping for repository log text, cancellation before log and after log, log failure, missing log rows, revision mismatch, and no log request for local-change or unknown-revision blame rows.
- Targeted extension tests pass for `currentLineBlameHoverProvider`.

## M5z Implemented Slice

The twenty-sixth M5 slice adds a conservative active-editor Line History command:

- `subversionr.showLineHistory` is contributed to the editor context menu only when `subversionr.activeEditorLineHistoryFile` is true, and remains hidden from the Command Palette because it depends on the active editor and current SVN projection.
- The command is projection-backed and uses the active primary selection from a `file` editor. VS Code's 0-based inclusive selection lines are normalized to a 1-based BASE blame window, with a maximum foreground window of 5000 lines.
- Eligibility deliberately matches the safe current-line identity boundary: projected local `changes` file resources only, `subversionr.changedFile` context only, non-external, non-dirty editors, files under `subversionr.lens.maxFileLines`, `nodeStatus = normal`, `textStatus = normal`, and no ignored, unversioned, deleted, missing, added, replaced, obstructed, incomplete, or conflicted local states.
- The command requests one foreground `history/blame` window with `pegRevision = base`, `startRevision = r0`, `endRevision = base`, `ignoreWhitespace = none`, no EOL/MIME ignore, and no merged revisions.
- Blame rows must be complete, contiguous, concrete, and non-local. Partial windows, local-change rows, unknown revisions, and non-contiguous line numbers fail with stable command error codes instead of showing incomplete attribution.
- Unique concrete line revisions are capped at 500, sorted newest-first, then each revision is resolved through exactly one bounded `history/log` request with `startRevision = endRevision = rN`, `limit = 1`, no changed paths, no strict node-history walk, and no merged revisions.
- The native `SVN History` TreeView accepts a preloaded `line` target for this command. It does not paginate, treats the generic Refresh command as a no-op for line targets, does not render `Load More`, and deliberately exposes only Revision Details and clipboard revision/message actions for line-history rows.
- Line-history Revision Details documents render the target as a localized line-history target and keep existing metadata-only behavior from already loaded log entries.
- This slice advances the first visible line-history workflow without adding a Rust protocol method, native ABI, history cache, cancellation protocol, background prefetch, SCM resource entry, or unmodified-file discovery outside the current projection.

This slice intentionally does not implement a backend `history/line` RPC, BASE-to-WORKING line mapping, dirty or uncommitted line history, copy/rename-aware line tracing, changed-path loading for line-history rows, merged-revision expansion, pagination, arbitrary editor-line targets outside the current projection, or a richer dedicated line-history UI.

## M5z Gates

- Line history command tests cover selection normalization, exact blame and per-revision log request identity, safe-target rejection, incomplete blame rejection, and missing or mismatched log rejection.
- History TreeDataProvider tests cover preloaded line-history targets with no backend pagination, no `Load More`, line-specific revision context, and disabled open/compare actions.
- Active-editor context tests cover the `subversionr.activeEditorLineHistoryFile` boundary for clean text-stable projected files and unsafe local states.
- Extension manifest and localization tests cover command activation, editor context menu placement, Command Palette hiding, view-item action visibility, and English/Japanese/Chinese localization keys.
- Revision Details document tests cover line-history target rendering.
- TypeScript checks and targeted extension tests pass for the affected surfaces.

## Deferred M5 Work

- Text decoding, binary document handling, and user-facing binary diagnostics through localization.
- `content/openStream`, `content/read`, and `content/release` for larger payloads.
- Full peg-aware PREV content retrieval across rename/copy boundaries, authentication prompts, cancellation behavior, and revision content cache policy.
- Full revprop retrieval, mergeinfo visualization, Revision Details webviews and action buttons, repository revision comparison, changed-path open/compare by repository URL, copy URL commands, arbitrary URL diff commands, backend history search, Compare PREV for unmodified versioned files absent from the projection, added/deleted/missing synthetic diff content, property diffs, backend `history/line`, copy/rename-aware full line history, peg-aware current-line log lookup across rename/copy boundaries, BASE-to-WORKING line mapping and full current-line blame behavior, rich revision hover behavior, hover command links, full symbol history CodeLens behavior, CodeLens for unmodified files, decorations, and broader SVN Lens UI surfaces.
- Cache invalidation tied to repository generation, epoch, and full reconcile boundaries.

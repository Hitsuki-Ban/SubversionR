# M6 Auth, Security, Trust, and Diagnostics Plan

## Goal

Build SubversionR's security surfaces around explicit Workspace Trust boundaries, stable non-localized backend error contracts, safe credential/certificate workflows, and redacted diagnostics suitable for public support.

## M6a Implemented Slice

The first M6 slice establishes the VS Code Workspace Trust baseline for currently implemented mutating, update, remote-read, and history/blame operations:

- The extension manifest declares limited untrusted-workspace support through `capabilities.untrustedWorkspaces`.
- The trust description states the concrete Restricted Mode surface: local read-only SVN status, BASE content, and already loaded history metadata can remain available while write operations, update/commit remote operations, external tool integrations, and custom SVN config/tunnel settings require workspace trust.
- The first-stage backend path settings from M3c were a private development limitation and were removed in M6f; current startup uses mandatory packaged backend resources instead.
- The Source Control, editor context, and history view menus hide currently implemented write, update, remote content, history loading, blame, line history, and revision-compare commands in untrusted workspaces via VS Code's `isWorkspaceTrusted` context key.
- The Source Control commit input affordance is trust-aware outside manifest menus: untrusted workspaces remove the `subversionr.commitAll` accept-input command and show a localized Restricted Mode placeholder, then restore the commit command after workspace trust is granted.
- Runtime command handlers enforce the same trust boundary before side effects, so direct command invocation through keybindings, command palette routing, or extension API calls cannot bypass the menu condition.
- The command-controller blocked set is `subversionr.cleanupRepository`, `subversionr.updateRepository`, `subversionr.updateResource`, `subversionr.revertResource`, `subversionr.addResource`, `subversionr.removeResource`, `subversionr.resolveResource`, `subversionr.commitResource`, `subversionr.commitAll`, `subversionr.diffWithHead`, `subversionr.openHead`, `subversionr.diffWithPrevious`, `subversionr.showRepositoryLog`, `subversionr.showFileHistory`, and `subversionr.showBlame`.
- The history tree blocks remote `history/log` refresh/load-more, explicit revision open, and revision comparison when workspace trust is absent. Search, revision-details documents, and copy actions over already loaded history metadata remain available.
- The line-history command blocks before `history/blame` or per-revision `history/log` calls when workspace trust is absent.
- The HEAD content, explicit revision content, and blame document providers reject direct virtual-document opens before backend RPC calls when workspace trust is absent. BASE content remains available.
- Current-line blame status, current-line blame hover, and symbol history CodeLens do not request `history/blame` or `history/log` in untrusted workspaces.
- File-header CodeLens exposes only BASE comparison in untrusted workspaces.
- `workspace.onDidGrantWorkspaceTrust` refreshes the Source Control commit affordance, file-header and symbol CodeLens, active-editor contexts, current-line blame, and loaded history tree rendering so trust-sensitive UI returns without waiting for unrelated editor or projection events.
- Restricted operations report a stable generic code, `SUBVERSIONR_WORKSPACE_UNTRUSTED_OPERATION`, with message key `error.workspace.untrustedOperation`; they do not return final user-facing prose from Rust or libsvn.
- The package manifest trust description is localized for English, Japanese, and Chinese.
- M6f removes the first-stage custom-path backend startup limitation, allowing the packaged backend to start in untrusted workspaces for the documented local readonly subset.

This slice intentionally does not add auth prompts, certificate callbacks, SecretStorage persistence, diagnostics bundle generation, new protocol capabilities, native ABI changes, TortoiseSVN integration, compatibility aliases, or silent fallback paths.

## M6a Gates

- Repository command controller tests cover all currently implemented mutating/update commands and remote-read history/content commands, verifying that untrusted workspaces block before operation clients, reconcile requests, confirmation prompts, commit message reads, history calls, projection reads, or user-facing remote views.
- History TreeDataProvider tests cover blocked remote loading/load-more/open-revision/compare-revision behavior and allowed already-loaded revision details.
- Line history, HEAD/revision/blame document provider, current-line blame status, hover, symbol CodeLens, and file-header CodeLens tests cover the runtime trust boundary.
- Source Control presenter tests cover hidden/restored commit input commands across workspace trust changes.
- History TreeDataProvider tests cover trust refresh tree rerendering without backend history loading.
- Manifest tests cover the limited Workspace Trust declaration and current restricted external-tool/SVN configuration keys.
- Manifest tests require every current write/update/remote-read menu contribution to include `isWorkspaceTrusted`.
- Package localization tests require the Workspace Trust description in English, Japanese, and Chinese bundles.
- Backend configuration tests cover packaged resource launch configuration for trusted and untrusted workspaces.

## M6b Implemented Slice

The second M6 slice establishes the redacted diagnostics and version-report foundation required by `OBS-005`, `OBS-006`, `OBS-007`, and `SEC-014`:

- The protocol exposes `diagnostics/get` and the `diagnosticsGet` capability under protocol v1.13.
- The daemon returns backend, bridge, libsvn, protocol, platform, capability, open-repository count, cached-local-entry count, and bounded backend-stderr metadata. It does not return repository paths, repository URLs, log messages, source content, or credentials.
- The VS Code extension contributes public palette commands `subversionr.diagnostics.collect` and `subversionr.diagnostics.versionReport`.
- `subversionr.diagnostics.collect` writes a JSON diagnostics bundle chosen through VS Code's save dialog. The command takes no arbitrary path argument.
- `subversionr.diagnostics.versionReport` opens a readonly JSON document with extension, VS Code, process, workspace-trust, backend, bridge, libsvn, protocol, platform, and capability data.
- The extension diagnostics service merges extension/VS Code/process/workspace metadata with daemon `diagnostics/get` output.
- Default redaction is recursive at the report sink and covers credentials, authorization/cookie/token/password/passphrase-like fields, repository URLs and queries, Windows/POSIX/UNC paths, remote authorities, repository log messages, source content, backend startup error safe args, and backend diagnostics stderr.
- Redaction markers are fixed ASCII, such as `[REDACTED:secret]`, `[REDACTED:url:<hash>]`, and `[REDACTED:path:<hash>]`, so support bundles remain comparable across locales.
- Backend startup is reported as packaged-source metadata; raw executable, bridge, and packaged resource paths are omitted.
- The package manifest and runtime diagnostics messages are localized for English, Japanese, and Chinese.

This slice intentionally does not add credential prompts, certificate callbacks, SecretStorage persistence, telemetry upload, output channels, rich operation journals, watcher/cache metrics beyond empty safe placeholders, native stderr streaming, diagnostics webviews, path-inclusion opt-ins, compatibility aliases, or silent fallback paths.

## M6b Gates

- Protocol contract tests cover `diagnosticsGet` capability and stable `diagnostics/get` camelCase response fields.
- Daemon dispatch tests cover `diagnostics/get` version/platform/capability/count output.
- Redaction tests cover credentials, URL userinfo/query strings, `svn+ssh`, URL-encoded credentials, Windows long paths, drive paths, UNC paths, POSIX paths, authorization headers, CLI password options, repository log messages, source content, and idempotent already-redacted markers.
- Report service tests cover initialized backend version reporting, backend startup error redaction, daemon diagnostics merge, packaged backend-source metadata, workspace folder counts, and remote authority redaction.
- Command controller tests cover diagnostics JSON file output and version-report document display.
- Manifest tests cover diagnostics activation events, contributed commands, and English/Japanese/Chinese package/runtime localization keys.

## M6c Implemented Slice

The third M6 slice establishes the TypeScript-owned credential request/response foundation required by `SEC-001`, `SEC-002`, `SEC-003`, and `SEC-006`:

- The protocol crate now defines stable `credentials/request` challenge and credential/cancel response wire structs under protocol v1.14.
- The VS Code JSON-RPC stream client can distinguish daemon-initiated requests from normal responses, invoke a registered inbound request handler, and return structured method-not-found or handler errors.
- Backend process startup wires the inbound request handler into the stream client, so daemon-originated `credentials/request` frames can be answered by the extension host.
- The extension creates a credential controller backed by `ExtensionContext.secrets`, with TypeScript owning all prompts and persistence decisions.
- SecretStorage keys use credential kind plus a SHA-256 hash of `kind + NUL + realm`; raw realms are not stored in the key or returned in structured error args.
- Non-interactive requests and background-origin requests may use an existing stored credential but never prompt. Missing stored credentials return `SUBVERSIONR_CREDENTIAL_NON_INTERACTIVE`.
- Untrusted workspaces are blocked before any SecretStorage read or prompt and return `SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE`.
- Interactive username/password requests can return a one-shot session credential or persist explicitly to VS Code SecretStorage when persistence is allowed and selected.
- Prompt timeout is treated as credential cancel with `SUBVERSIONR_CREDENTIAL_TIMEOUT`, and VS Code quick-input surfaces receive cancellation tokens tied to the request timeout.
- Credential cancel and validation failures return stable codes, categories, message keys, and safe args. Secrets appear only in successful one-shot credential response payloads.
- Runtime credential UI strings are localized in English, Japanese, and Chinese.

This slice intentionally does not wire libsvn auth callbacks, persist secrets from Rust, enable the standard SVN credential store, add certificate prompts, add auth telemetry, introduce background remote polling, or advertise native auth callback capability.

## M6c Gates

- Credential controller tests cover SecretStorage lookup/save by realm and credential kind, cross-realm isolation, untrusted-workspace blocking before SecretStorage access, non-interactive and background-origin no-prompt behavior, explicit session-only behavior, same-realm prompt coalescing, timeout cancellation, and JSON-RPC handler routing.
- JSON-RPC stream tests cover daemon-initiated request handling, explicit method-not-found responses, safe handler-error args, and existing extension-initiated response matching.
- Backend process tests cover request-handler wiring from sidecar stdout to extension stdin response frames.
- Protocol contract tests cover stable camelCase credential challenge fields and `provide`/`cancel` response variants.
- Manifest/localization tests cover the added runtime credential UI strings across English, Japanese, and Chinese bundles.

## M6d Implemented Slice

The fourth M6 slice establishes the TypeScript-owned certificate trust request/response foundation required by `SEC-004`, `SEC-005`, and `SEC-006`:

- The protocol crate defines stable `certificate/request` challenge and trust/reject response wire structs under protocol v1.15.
- Certificate challenge payloads carry the display and decision fields required by the reference docs: realm, host, fingerprint, pinned fingerprint algorithm, validation failures, validity period, optional issuer/subject, interactivity, origin, persistence allowance, timeout, repository id, and working-copy root.
- The supported fingerprint algorithm is explicitly `sha256-der`; unknown algorithms are rejected with `SUBVERSIONR_CERTIFICATE_FINGERPRINT_ALGORITHM_UNSUPPORTED` instead of normalized or silently compared.
- The VS Code inbound auth handler routes both `credentials/request` and `certificate/request` through a neutral auth request router. Unknown auth methods still fail with stable method-not-found errors.
- The extension creates a certificate trust controller backed by `ExtensionContext.secrets`, with TypeScript owning all prompts and persistence decisions.
- Workspace Trust is the first gate. Untrusted workspaces return `SUBVERSIONR_CERTIFICATE_UNTRUSTED_WORKSPACE` before SecretStorage reads or UI prompts.
- Permanent trust records are stored under a SHA-256 hash of `certificate + NUL + realm`; raw realms are not embedded in SecretStorage keys or structured error args. The stored record pins fingerprint, fingerprint algorithm, and trust timestamp.
- Exact stored realm/fingerprint trust may satisfy non-interactive and background certificate requests without prompting.
- Missing certificate trust in non-interactive or background requests returns `SUBVERSIONR_CERTIFICATE_NON_INTERACTIVE` without prompting or writing storage.
- Changed certificate fingerprints for an already trusted realm never reuse the previous trust. Foreground requests prompt again; background and non-interactive requests return `SUBVERSIONR_CERTIFICATE_CHANGED`.
- Interactive certificate UI uses VS Code QuickPick with cancellation tokens tied to request timeouts and displays host, fingerprint, algorithm, validation failures, validity period, issuer, and subject.
- Interactive users can reject, trust once, or trust permanently when persistence is allowed. Trust-once does not write SecretStorage. Permanent trust is rejected with `SUBVERSIONR_CERTIFICATE_PERSISTENCE_DISALLOWED` if persistence is disallowed.
- Prompt timeout returns `SUBVERSIONR_CERTIFICATE_TIMEOUT`; UI cancellation returns `SUBVERSIONR_CERTIFICATE_CANCELLED`; explicit reject returns `SUBVERSIONR_CERTIFICATE_REJECTED`.
- Runtime certificate UI strings are localized in English, Japanese, and Chinese.

This slice intentionally does not wire native libsvn SSL server certificate callbacks, compute certificate fingerprints in the native bridge, write standard SVN auth cache files, add certificate review/revoke UI, expose certificate trust records through diagnostics, introduce background remote polling, or advertise native certificate-auth callback capability.

## M6d Gates

- Certificate trust controller tests cover untrusted workspace ordering, background/non-interactive no-prompt behavior, exact stored trust reuse, changed-fingerprint foreground recovery, changed-fingerprint background rejection, trust-once non-persistence, permanent SecretStorage writes without raw realms in keys, persistence-disallowed rejection, unsupported fingerprint algorithm rejection, timeout cancellation, prompt coalescing, and JSON-RPC handler routing.
- Auth request handler tests cover `credentials/request`, `certificate/request`, and method-not-found routing.
- Protocol contract tests cover stable camelCase certificate challenge fields and `trust`/`reject` response variants.
- Protocol initialization and daemon dispatch tests cover protocol v1.15 without adding certificate/native-auth callback capabilities.
- Manifest/localization tests cover certificate UI strings across English, Japanese, and Chinese bundles.

## M6e Implemented Slice

The fifth M6 slice establishes the future external-tool trust boundary required by `SEC-007`, `SEC-008`, `SEC-011`, `PRD-004`, and the TortoiseSVN reference requirements without implementing the M7 Tortoise adapter:

- The extension manifest lists future external executable/config/tunnel settings in `capabilities.untrustedWorkspaces.restrictedConfigurations`: `subversionr.tortoise.executablePath`, `subversionr.tortoise.configDirectory`, `subversionr.svn.configDirectory`, and `subversionr.svn.tunnelCommand`.
- These settings use current SubversionR IDs only. Historical `svnNative.*` catalog rows remain trace references and are not contributed as live aliases.
- The settings are `machine-overridable` and have no defaults, so trusted users can make explicit per-workspace choices later while Restricted Mode suppresses workspace-provided values.
- A TypeScript security policy module reads optional settings, checks VS Code configuration provenance through `inspect`, and rejects workspace/folder/language-scoped values in untrusted workspaces with stable code `SUBVERSIONR_EXTERNAL_TOOL_WORKSPACE_SETTING_UNTRUSTED`.
- External tool execution has an explicit runtime gate, `SUBVERSIONR_EXTERNAL_TOOL_UNTRUSTED_WORKSPACE`, so direct command invocation cannot bypass manifest/menu gating when future adapters call the policy.
- Tortoise executable/config and SVN config-directory values must be absolute paths when used. Missing optional Tortoise settings remain unconfigured and do not break native core workflows.
- Structured errors return stable code, category, message key, and safe args containing only setting IDs or feature names; raw executable paths, config directories, and tunnel commands are not included in safe args.
- Package configuration descriptions and the Workspace Trust description are localized in English, Japanese, and Chinese.

This slice intentionally does not launch TortoiseSVN, detect Tortoise installations, probe PATH or registry locations, pass SVN config/tunnel settings to libsvn, parse shell command strings, add `svnNative.*` aliases, add diagnostics exposure for raw external-tool settings, or implement external mutation reconcile flows.

## M6e Gates

- External tool configuration tests cover the exact restricted setting list, optional missing Tortoise settings, untrusted external-tool execution blocking, untrusted workspace/folder/language setting provenance blocking, trusted workspace setting allowance, absolute path normalization, and non-absolute path rejection without raw value leakage.
- Manifest tests cover the restricted configuration list, the four no-default `machine-overridable` settings, English/Japanese/Chinese package localization, and absence of historical `svnNative.*` setting aliases.

## M6f Implemented Slice

The sixth M6 slice replaces the first-stage private-development backend path requirement with mandatory packaged backend resources, closing the Restricted Mode startup gap identified in M6a:

- The VS Code extension resolves backend resources from its own installed extension directory via `ExtensionContext.asAbsolutePath`.
- The only supported packaged target in this slice is `win32-x64`, matching the current Windows-first development and CI baseline.
- The packaged target maps to `resources/backend/win32-x64/subversionr-daemon.exe` and `resources/backend/win32-x64/subversionr_svn_bridge.dll`.
- Unsupported host targets fail fast with `SUBVERSIONR_BACKEND_PACKAGE_UNSUPPORTED_TARGET`; the extension does not probe `PATH`, system SVN, TortoiseSVN, registry locations, or user-provided executable paths.
- Missing packaged resources fail fast with `SUBVERSIONR_BACKEND_PACKAGE_RESOURCE_MISSING`, and non-absolute extension-resource resolution fails with `SUBVERSIONR_BACKEND_PACKAGE_PATH_NOT_ABSOLUTE`.
- Packaged resource errors use stable categories, message keys, and safe args containing only resource names, target IDs, platform, and architecture. Raw local extension paths are not included.
- `BackendService` startup now builds its launch config from packaged resources in both trusted and untrusted workspaces. The `workspaceTrust` initialize parameter reflects the actual VS Code trust state instead of being hard-coded to trusted.
- The extension manifest no longer contributes `subversionr.backend.executablePath` or `subversionr.backend.bridgeDllPath`, and the Workspace Trust restricted configuration list contains only external tool and SVN config/tunnel settings.
- Diagnostics bundles report `settings.backend.source = "packaged"` and do not expose packaged resource paths.
- Startup failure messages for unsupported packaged targets, missing packaged resources, and invalid packaged resource paths are localized in English, Japanese, and Chinese.
- Ask Gemini/OpenCode consultation is available as a routine blind-spot review tool; on Windows PowerShell, wrapper calls use UTF-8 Python stdout handling when printing model output.

This slice intentionally does not add dev override paths, PATH/system/Tortoise fallback, VSIX binary staging automation, transitive native dependency manifests, binary signature/hash verification, per-platform VSIX publishing, macOS/Linux target support, or path redaction inside Rust/libsvn panic surfaces beyond the existing diagnostics redaction boundary.

## M6f Gates

- Backend package resolver tests cover supported `win32-x64` resolution, unsupported target failure, missing resource failure, and non-absolute resolver output without raw path leakage.
- Backend configuration tests cover packaged launch config generation in untrusted workspaces and required client metadata.
- Manifest tests cover removal of backend path settings and English/Japanese/Chinese package localization cleanup.
- Diagnostics report tests cover packaged backend-source metadata and absence of packaged backend paths in version reports and support bundles.

## M6g Implemented Slice

The seventh M6 slice establishes the daemon-side auth request broker that future libsvn callbacks will use to reach the TypeScript-owned credential and certificate controllers:

- The protocol minor version advances to v1.16 and initialization advertises `credentialRequest` and `certificateRequest` capabilities.
- The daemon exposes an `AuthRequestBroker` boundary for credential and certificate trust challenges without exposing APR or libsvn types to Rust domain code.
- `BridgeApi::open_working_copy_with_auth` is the first auth-aware bridge entrypoint. Existing bridge implementations keep the direct `open_working_copy` path until native auth providers are wired.
- The stdio transport can emit daemon-initiated `credentials/request` and `certificate/request` JSON-RPC frames using `Content-Length` framing, then require a matching response id and matching response body identity before continuing the foreground `repository/open` response.
- Invalid, rejected, unavailable, or transport-failed auth responses fail fast with stable auth errors and safe args containing only the auth method name.
- Non-interactive or background-origin auth requests are rejected in the daemon without writing a prompt frame, returning `SUBVERSIONR_CREDENTIAL_NON_INTERACTIVE` or `SUBVERSIONR_CERTIFICATE_NON_INTERACTIVE`.
- Ask Gemini/OpenCode preflight was verified for this development environment, and a blind-spot review identified reentrant stdio pumping and native callback lifetime handling as the highest-risk next items.

This slice intentionally does not wire native libsvn auth providers or SSL server certificate callbacks, compute native certificate fingerprints, enable standard SVN credential-store persistence, implement sidecar-side timeout timers, keep the stdio pump responsive to unrelated requests while a callback waits, or add cancellation mapping.

## M6g Gates

- Daemon stdio tests cover credential and certificate auth challenge round-trips from `repository/open` through daemon-initiated JSON-RPC requests and back to the original response.
- Daemon stdio tests cover mismatched credential response body request ids and mismatched certificate trust fingerprints/fingerprint algorithms.
- Daemon stdio tests cover non-interactive/background credential and certificate requests returning stable no-prompt errors without emitting inbound auth request frames.
- Protocol contract tests cover protocol v1.16 and the `credentialRequest` and `certificateRequest` capability fields.
- Backend process tests cover TypeScript initialization parsing and fail-fast required-capability enforcement for the new auth request capabilities.

## M6h Implemented Slice

The eighth M6 slice hardens the synchronous stdio auth wait loop without turning the daemon into a full concurrent JSON-RPC dispatcher:

- While waiting for a daemon-originated `credentials/request` or `certificate/request`, the stdio broker now keeps reading framed JSON-RPC messages until the matching auth response, a matching cancellation, or a deterministic auth transport failure.
- Credential cancel response bodies and certificate reject response bodies are mapped back to the original foreground operation only when their code/category/message-key contract matches the TypeScript auth controllers. The daemon rebuilds safe args from the original pending challenge and never trusts args supplied in the response body.
- `$/cancelRequest` notifications whose `params.id` matches the pending auth request id cancel the original operation with `SUBVERSIONR_AUTH_CANCELLED`; nonmatching cancel notifications are ignored.
- JSON-RPC error responses with LSP `RequestCancelled` code `-32800` also map to `SUBVERSIONR_AUTH_CANCELLED`.
- Unrelated notifications received while an auth prompt is pending are ignored. Unrelated requests receive `SUBVERSIONR_AUTH_REQUEST_PENDING` with safe args containing only the pending auth method, then the auth wait loop continues.
- Auth response envelopes now fail fast when `jsonrpc` is missing or not `2.0`, the id does not match the pending auth request, both `result` and `error` are present, neither is present, the JSON-RPC error body is malformed, a cancel/reject DTO has an unexpected error contract, or the result body cannot deserialize into the expected auth response type.
- EOF before a matching response, including EOF inside a `Content-Length` frame, now returns `SUBVERSIONR_AUTH_RESPONSE_UNAVAILABLE` instead of collapsing into a malformed-response error.
- Ask Gemini/OpenCode preflight was reverified on the updated development environment, and a blind-spot review confirmed the scoped hardening while calling out full reader-pump dispatch, id reuse policy, flood backpressure, and Rust-side wall-clock auth timeout as later risks.

This slice intentionally does not implement multiple concurrent daemon-originated auth requests, a reader-thread dispatcher, Rust-side wall-clock auth timeout enforcement, request-flood throttling, broader `Content-Length` parser limits, native libsvn auth providers, SSL server certificate callbacks, or standard SVN credential-store persistence. TypeScript auth controllers still own prompt timeout decisions for this stage.

## M6h Gates

- Daemon stdio tests cover credential cancel DTO mapping, certificate reject DTO mapping, daemon-derived safe args despite polluted response args, unexpected cancel/reject error-contract rejection, matching and nonmatching `$/cancelRequest` notifications, request-shaped `$/cancelRequest` rejection while auth continues, JSON-RPC `-32800` auth cancellation, malformed JSON-RPC error bodies, unrelated request rejection, unrelated notification ignoring, malformed auth envelopes, ambiguous `result` plus `error`, and EOF inside an auth response frame.
- Existing daemon stdio tests continue to cover successful credential and certificate request round-trips, body identity validation, certificate fingerprint validation, non-interactive no-prompt errors, repository session continuity, and shutdown handling.
- The RPC catalog records `$/cancelRequest` as a notification used to cancel pending JSON-RPC requests by id.

## M6i Implemented Slice

The ninth M6 slice wires native libsvn auth prompt callbacks through the daemon broker without exposing APR or libsvn types across the Rust boundary:

- The native bridge ABI now includes a required auth callback table plus plain C credential and SSL server certificate request/response structs. The Rust native loader requires `subversionr_bridge_open_working_copy_with_auth`; missing symbols fail load-time rather than falling back to unauthenticated open.
- `NativeBridge::open_working_copy_with_auth` passes credential and certificate callbacks into the C bridge, records broker failures inside a scoped Rust auth baton, and returns the original stable auth failure when a libsvn prompt aborts the foreground `repository/open`.
- The C bridge installs scoped libsvn prompt providers for `SVN_AUTH_CRED_SIMPLE` and `SVN_AUTH_CRED_SSL_SERVER_TRUST` around auth-aware open, restores the prior `svn_client_ctx_t.auth_baton` after the call, and copies secrets into the libsvn pool before immediately asking Rust to dispose callback-owned strings.
- Credential prompts are mapped to the existing `usernamePassword` protocol kind. Credential cancel/error responses are accepted only when their stable code/category/message-key contract matches the TypeScript auth controllers, and safe args are rebuilt from the original native request.
- SSL server certificate prompts compute a `sha256-der` fingerprint in Rust from libsvn's base64 DER certificate, map libsvn failure bits to protocol failure words, require trust responses to echo the exact fingerprint identity, and return the exact original libsvn failure bitmask to C on trust.
- The native bridge does not enable standard SVN auth cache persistence in this slice. SecretStorage remains TypeScript-owned; libsvn credential structs returned by the prompt callbacks set `may_save` false for the native auth cache.
- Ask Gemini/OpenCode preflight was verified in the updated environment and an architecture consultation confirmed the narrow C translation layer, callback lifetime, secret-copy/dispose boundary, exact certificate bitmask preservation, and no silent fallback policy.

This slice intentionally does not implement username-only, proxy password, SSH passphrase, client certificate password, standard SVN credential-store opt-in, HTTPS/svnserve auth fixtures, Rust-side wall-clock timeout enforcement, full reader-thread dispatch while libsvn blocks, or certificate review/revoke UI.

## M6i Gates

- Rust native callback unit tests cover credential request round-trip, credential cancel mapping without secret response pointers, SHA-256 DER certificate fingerprint computation, exact certificate failure-bit preservation, and rejection of mismatched certificate trust response identity.
- Native bridge build and smoke tests compile the new C ABI with MSVC/CMake and verify the bridge still reports libsvn `1.14.5`.
- Ignored native bridge integration tests run against the rebuilt staged DLL and staged Apache Subversion fixture tools, confirming existing file-backed working-copy open/status/content/history/operation behavior still passes through the auth-aware native loader.

## M6j Implemented Slice

The tenth M6 slice adds bounded stdio auth transport hardening around the synchronous wait loop without claiming full concurrent dispatch or idle blocking-read interruption:

- The daemon stdio frame parser now rejects duplicate `Content-Length` headers, unsupported headers, oversized header lines, oversized total headers, and payload lengths above the fixed frame limit before allocating the payload buffer.
- While a daemon-originated `credentials/request` or `certificate/request` is pending, oversized auth response frames fail the original foreground operation with a stable auth transport error instead of allocating unbounded memory or waiting for payload bytes.
- The synchronous auth wait loop now enforces an inbound-message budget for unrelated requests and notifications. After the budget is exceeded, the original foreground operation fails fast with `SUBVERSIONR_AUTH_REQUEST_FLOOD` and safe args containing only the auth method.
- `CredentialRequest.timeoutMs` and `CertificateTrustRequest.timeoutMs` are now enforced by a Rust-side deadline gate before waiting and after each inbound frame. `timeoutMs <= 0` deterministically returns `SUBVERSIONR_AUTH_TIMEOUT`.
- The timeout gate is deliberately scoped to points where the synchronous loop has control. It does not claim to interrupt an idle blocking `Read`; that requires a later reader-thread, non-blocking IO, or platform wait primitive design.

This slice intentionally does not implement a reader-thread correlation pump, multiple concurrent daemon-originated auth requests, full concurrent foreground request dispatch, queued request replay after auth completion, standard SVN credential-store opt-in, or network-auth fixtures.

## M6j Gates

- Daemon stdio tests cover daemon-side auth timeout before waiting for a response.
- Daemon stdio tests cover oversized auth response `Content-Length` rejection before payload allocation.
- Daemon stdio tests cover request-flood backpressure while a credential auth response is pending.
- Existing daemon stdio auth tests continue to cover successful credential/certificate request round-trips, cancellation, malformed envelopes, EOF, unrelated request rejection, unrelated notification ignoring, body identity validation, and repository session continuity.

## M6k Implemented Slice

The eleventh M6 slice moves stdio frame reads out of the foreground auth wait path so daemon-side auth deadlines can fire even when the client sends no additional frame:

- The production stdio loop now starts a single named reader thread that owns the blocking input reader, parses the existing `Content-Length` protocol with the same frame/header limits, and sends payload, EOF, or parser-error events to the dispatcher through a bounded synchronous channel.
- The main thread remains the only JSON-RPC dispatcher and the only stdout writer. This is not a full concurrent dispatcher; unrelated foreground requests observed during auth wait still receive the existing `SUBVERSIONR_AUTH_REQUEST_PENDING` response.
- `credentials/request` and `certificate/request` waits now use the bounded frame receiver with an `Instant` deadline. If no frame arrives before the deadline, the original foreground operation fails with `SUBVERSIONR_AUTH_TIMEOUT`.
- EOF and malformed-frame handling preserve the M6j contracts: EOF during auth maps to response unavailable, non-EOF parser errors map to invalid auth response, and a consumed terminal reader event ends the outer stdio loop without surfacing an extra process-level IO error.
- A reader-channel disconnect without an explicit EOF or parser-error event is treated as an internal stdio reader fault rather than as EOF.
- Ask Gemini/OpenCode blind-spot review was run against the abstract design. The integrated conclusion kept the bounded reader-thread design, rejected the concern that unrelated requests cannot be drained during auth wait because the loop does drain channel frames, and retained late/stale auth response policy plus broader concurrent dispatch as later risks.

This slice intentionally does not implement multiple concurrent daemon-originated auth requests, full concurrent foreground request dispatch, queued request replay after auth completion, late/stale auth response recovery after timeout, standard SVN credential-store opt-in, or network-auth fixtures.

## M6k Gates

- Daemon stdio tests cover credential auth timeout when the input reader stays idle until after the daemon deadline.
- Daemon stdio tests cover certificate trust timeout when the input reader stays idle until after the daemon deadline.
- Existing daemon stdio tests continue to cover auth cancellation, unrelated request-pending responses while auth is pending, request-flood rejection, oversized frame rejection, malformed envelope handling, EOF handling, and repository session continuity.

## M6l Implemented Slice

The twelfth M6 slice starts the real network-auth fixture track for the `svn://` protocol without claiming HTTPS or broader operation-auth coverage:

- The Apache Subversion source build stage now treats `svnserve.exe` as a required fixture tool alongside `svn.exe` and `svnadmin.exe`.
- `Copy-SubversionBuildStage` copies the built `svnserve.exe` from the official Apache Subversion source tree into the generated native stage, and `Assert-SubversionStageForBridge` fails fast if the staged runtime lacks it.
- Bridge runtime dependency copy continues to copy the staged `bin` directory as a single current path, so rebuilt bridge output now includes `svnserve.exe` beside the bridge DLL and fixture client tools.
- An ignored native integration fixture creates a local repository, configures `svnserve` with anonymous access disabled and a fixed test-only username/password, starts a localhost `svn://` server from the staged source-built `svnserve.exe`, verifies anonymous checkout fails, and verifies explicit credentials with `--no-auth-cache` can checkout committed content.
- Current source research confirmed the boundary: `svnserve` is Subversion's standalone server path for the custom protocol, while HTTP/HTTPS support requires Serf/OpenSSL/httpd-related work not present in the current source lock or build scripts.

This slice intentionally does not implement Serf/OpenSSL, HTTPS certificate fixtures, SASL, standard SVN credential-store opt-in, or auth-broker plumbing for remote operations beyond the existing `repository/open` auth-aware path.

## M6l Gates

- Native script tests cover `svnserve.exe` copying into the stage and stage validation failure when required fixture tools are absent.
- The Apache Subversion source build gate rebuilds the generated stage with `svnserve.exe` present.
- Native bridge smoke still verifies the staged bridge DLL reports Apache Subversion `1.14.5`.
- Ignored native integration tests include a localhost `svn://` credential fixture that rejects anonymous checkout and accepts explicit test credentials.

## M6m Implemented Slice

The thirteenth M6 slice routes the first already-open working-copy remote operation through the daemon auth broker:

- `BridgeApi::operation_update` now requires an `AuthRequestBroker`, making broker availability explicit at the Rust bridge boundary instead of keeping a separate unauthenticated production update path.
- `operation/run` passes the foreground stdio auth broker into update, allowing `credentials/request` frames to be emitted while the original update request is still outstanding.
- Direct non-stdio callers must pass `UnavailableAuthRequestBroker` explicitly, so missing auth support fails through the existing stable auth error contract if libsvn prompts.
- `NativeBridge::operation_update` creates the same narrow C auth callback table used by auth-aware open, records callback failures in the scoped Rust auth baton, and returns the original stable auth failure ahead of generic update failures.
- The native auth baton now carries the active repository id for update prompts, while open prompts remain repository-id unknown until the working copy identity is discovered.
- The C bridge `subversionr_bridge_operation_update` now requires auth callbacks, installs a scoped libsvn auth baton around `svn_client_update4`, includes simple, username-only, and SSL server-trust prompt providers needed by current libsvn RA paths, restores the previous `svn_client_ctx_t.auth_baton`, and preserves the existing notify callback restore behavior.
- The `svnserve` fixture now exercises a real authenticated update: a checkout created with `--no-auth-cache` is updated through `NativeBridge`, the test broker must record a credential challenge, and the working-copy file content must advance.
- Ask Gemini/OpenCode preflight and an architecture consultation were used for this slice; the integrated decision kept a single broker-required update path and added explicit fixture assertions to avoid false greens from credential caches.

This slice intentionally does not route commit, HEAD content, history, blame, or cleanup through native auth callbacks; enable standard SVN auth-cache persistence; add HTTPS/Serf/OpenSSL fixtures; implement multiple concurrent auth prompts; or define late/stale auth response recovery after timeout.

## M6m Gates

- Daemon stdio tests cover `operation/run` update issuing a daemon-originated `credentials/request`, accepting the matching response, and then completing the original update response.
- Rust compile tests cover the broker-required `BridgeApi::operation_update` signature across daemon fakes and native bridge callers.
- Native bridge build tests compile the updated C ABI with MSVC/CMake and stage the rebuilt DLL with Apache Subversion `1.14.5` runtime dependencies.
- Ignored native integration tests cover localhost `svn://` update through the broker, asserting that a credential request was recorded and that the working copy received the remote change.

## M6n Implemented Slice

The fourteenth M6 slice routes HEAD content retrieval through the daemon auth broker:

- `BridgeApi::content_get` now requires an `AuthRequestBroker`, matching the update operation's broker-required Rust boundary and avoiding a separate unauthenticated production content path.
- `content/get` passes the foreground stdio auth broker into the bridge, allowing daemon-originated `credentials/request` frames while a HEAD content request is outstanding.
- `NativeBridge::content_get` constructs the narrow auth callback table, records callback failures in the scoped Rust auth baton, and returns the original stable auth failure ahead of generic content failures.
- The native auth baton now takes precedence over target-path callback data when populating `repositoryId` and `workingCopyRoot`, so selected-file content prompts carry the repository identity working-copy root rather than the file path.
- The C bridge `subversionr_bridge_content_get_with_auth` now requires auth callbacks and installs a scoped libsvn auth baton around `svn_client_cat3`, while keeping the existing BASE/HEAD/explicit-revision content semantics and result-pool ownership.
- The `svnserve` fixture now exercises authenticated HEAD content retrieval: a checkout created with `--no-auth-cache` reads HEAD content through `NativeBridge`, the test broker must record a credential challenge, and the returned bytes must match the remote change.

This slice intentionally does not route commit, history, blame, or cleanup through native auth callbacks; enable standard SVN auth-cache persistence; add HTTPS/Serf/OpenSSL fixtures; implement multiple concurrent auth prompts; or define late/stale auth response recovery after timeout.

## M6n Gates

- Daemon stdio tests cover `content/get` HEAD issuing a daemon-originated `credentials/request`, accepting the matching response, and then completing the original content response.
- Rust compile tests cover the broker-required `BridgeApi::content_get` signature across daemon fakes and native bridge callers.
- Native bridge build tests compile the updated C ABI with MSVC/CMake and stage the rebuilt DLL with Apache Subversion `1.14.5` runtime dependencies.
- Ignored native integration tests cover localhost `svn://` HEAD content through the broker, asserting that a credential request was recorded with the repository working-copy root and that returned content reflects the remote HEAD.

## M6o Implemented Slice

The fifteenth M6 slice routes the first mutating remote operation through the daemon auth broker:

- `BridgeApi::operation_commit` now requires an `AuthRequestBroker`, matching update/content broker-required Rust boundaries and avoiding a separate unauthenticated production commit path.
- `operation/run` passes the foreground stdio auth broker into commit, allowing daemon-originated `credentials/request` frames while the original commit request remains outstanding.
- Direct non-stdio callers must pass `UnavailableAuthRequestBroker` explicitly; if libsvn prompts, commit returns the existing stable auth-broker unavailable error instead of a generic commit failure.
- `NativeBridge::operation_commit` constructs the narrow auth callback table, records callback failures in the scoped Rust auth baton, and returns the original stable auth failure ahead of generic commit failures.
- The C bridge exports `subversionr_bridge_operation_commit_with_auth`, requires callbacks, installs a scoped libsvn auth baton around exactly one `svn_client_commit6` call, restores the previous `svn_client_ctx_t.auth_baton`, and keeps log/notify callback restoration inside the commit implementation.
- The old `subversionr_bridge_operation_commit` export is not kept, so old bridge DLLs fail fast at Rust symbol loading rather than silently mismatching the changed ABI.
- The `svnserve` fixture now exercises authenticated commit through `NativeBridge`: a checkout created with `--no-auth-cache` commits a modified file through the test broker, records a credential challenge, returns the committed revision, and verifies the seed checkout can update to the committed content.

This slice intentionally does not add automatic retry for ambiguous commit failures; change lock-token behavior; add HTTPS/Serf/OpenSSL fixtures; implement multiple concurrent auth prompts; or define late/stale auth response recovery after timeout.

## M6o Gates

- Daemon stdio tests cover `operation/run` commit issuing a daemon-originated `credentials/request`, accepting the matching response, and then completing the original commit response.
- Dispatch tests cover non-stdio commit auth prompts returning `SUBVERSIONR_AUTH_BROKER_UNAVAILABLE` through the stable auth error contract.
- Native script tests assert that Rust loads `subversionr_bridge_operation_commit_with_auth` and that the C header/source do not keep the old `subversionr_bridge_operation_commit` export after adding auth callbacks.
- Native bridge build and smoke tests compile the updated C ABI with MSVC/CMake and verify the staged DLL still reports Apache Subversion `1.14.5`.
- Ignored native integration tests cover localhost `svn://` commit through the broker, asserting that a credential request was recorded with the repository working-copy root and that the committed content is visible from another working copy after update.

## M6p Implemented Slice

The sixteenth M6 slice defines and implements late auth response handling after daemon-side auth wait expiry:

- The daemon stdio transport records a bounded window of auth request ids retired by timeout, matching cancellation, or inbound request flood while a foreground auth request is pending.
- Later top-level JSON-RPC response frames whose string id matches a retired auth request id are consumed by the stdio receiver before request dispatch, so stale credential/certificate responses cannot be parsed as new top-level requests or terminate the stream.
- The stale response payload is not echoed in daemon output, preserving the existing no-secret/no-raw-realm error contract.
- The implementation does not send a response to a JSON-RPC response frame; this keeps SubversionR aligned with JSON-RPC id-correlation semantics instead of inventing a response-to-response path.
- Native auth request ids now use a process-level monotonic sequence across `NativeAuthBaton` instances, so stale responses from a previous libsvn callback cannot collide with a later native auth request id in the same daemon session.

This slice intentionally does not add protocol fields, VS Code transport stale-response rejection, auth-controller daemon-timeout awareness, automatic retry after timeout, or a diagnostics notification for dropped stale responses.

## M6p Gates

- Daemon stdio tests cover stale credential and certificate responses arriving after daemon-side timeout and before a new `shutdown` request; the loop must continue and the stale credential secret must not appear in output.
- Daemon stdio tests continue to cover malformed auth responses, inbound request floods, matching and nonmatching cancellation, unrelated notifications, and unrelated requests while an auth wait is pending.
- Daemon unit tests cover the retired auth id window remaining bounded and evicting oldest entries.
- Native daemon unit tests cover auth request ids increasing monotonically across independent native auth batons.

## M6q Implemented Slice

The seventeenth M6 slice starts the HTTPS native dependency track as a source-lock gate only:

- `native/sources.lock.json` now locks Apache Serf 1.3.10 from the Apache distribution backup URL, including SHA512, PGP signature URL, KEYS URL, and Apache-2.0 license metadata.
- `native/sources.lock.json` now locks OpenSSL 3.5.7 from the official OpenSSL GitHub release artifact, including project SHA512, upstream SHA256, PGP signature URL, OpenSSL release-signing keys URL, and Apache-2.0 license metadata for OpenSSL 3.x.
- `scripts/native/verify-sources.ps1` now delegates archive checksum checks to `Assert-NativeArchiveChecksum`, so the required SHA512 and any present SHA256 field are both enforced before PGP verification.
- Native script tests assert the exact Serf/OpenSSL source-lock metadata, assert SHA256 mismatch behavior, and assert the current source-lock slice does not add Serf/OpenSSL to dependency build scripts or the Subversion generator path.
- Ask Gemini/OpenCode preflight was reverified on the updated environment, and a blind-spot consultation confirmed the source-lock-only boundary while calling out build/link/runtime HTTPS claims as later work.

This slice intentionally does not build Serf, build OpenSSL, pass `--with-serf` or OpenSSL paths to Subversion, add `libsvn_ra_serf` stage assertions, add HTTPS certificate fixtures, validate TLS handshakes, or claim HTTP/HTTPS repository support.

## M6q Gates

- Native script tests cover real source-lock completeness for Serf/OpenSSL and optional SHA256 checksum enforcement.
- The native source verifier downloads and verifies the locked Serf/OpenSSL release archives through the existing fail-fast source gate.
- Current-source research confirms the dependency boundary: Apache Serf is the Subversion HTTP client path, OpenSSL enables HTTPS through Serf, Apache Serf 1.3.10 is the latest stable Serf release, and OpenSSL 3.5.7 is the current 3.5 LTS release.

## M6r Implemented Slice

The eighteenth M6 slice turns the HTTPS dependency track from source locks into a Windows build, stage, and link gate without claiming Subversion HTTPS runtime support:

- `scripts/native/build-dependencies.ps1 -Only all` now includes OpenSSL 3.5.7 and Apache Serf 1.3.10 after the existing SQLite, zlib, Expat, and APR stack stages.
- OpenSSL is built from the locked upstream source through Strawberry Perl, NASM, and the VS 2022 x64 developer environment with `perl Configure VC-WIN64A no-makedepend`, `nmake`, and `nmake install_sw`.
- The OpenSSL build gate checks that Perl and NASM are present on `PATH` before invoking the upstream Configure script.
- Windows CI installs NASM 3.01 from the official NASM Windows x64 ZIP and verifies the pinned SHA256 before adding it to `PATH`, so the OpenSSL assembly build gate does not depend on runner image preinstalls.
- The OpenSSL stage check requires `include/openssl/opensslv.h`, `ssl.h`, `crypto.h`, `lib/libssl.lib`, `lib/libcrypto.lib`, and matching `bin/libssl-*.dll` and `bin/libcrypto-*.dll` runtimes, and validates the staged version.
- Serf is built from the locked Apache source through `uv run --no-project --with scons==4.9.1 scons` under the VS 2022 x64 developer environment.
- The Serf SCons invocation keeps Serf's Windows source-layout include behavior, but explicitly passes `LINKFLAGS=/LIBPATH:<stage-lib>` so SCons configure checks and final DLL linking use the staged APR, zlib, and OpenSSL import libraries.
- The Serf SCons invocation forces `PYTHONIOENCODING=utf-8` so configure diagnostics do not fail under Windows console encodings when linker output contains localized text.
- The Serf stage check requires public headers, the static `serf-1.lib`, the DLL import library `libserf-1.lib`, and the staged `bin/libserf-1.dll` runtime, and validates the staged version.
- A native MSVC link probe compiles and runs a temporary C executable against the staged Serf DLL import library, OpenSSL, APR, APR-util, and zlib, includes `<serf.h>` and `<openssl/crypto.h>`, calls `serf_error_string` and `OpenSSL_version`, and runs with the staged `bin` directory on `PATH`.
- The current Apache Subversion bridge stage still copies only the pre-HTTPS Subversion dependency closure. OpenSSL and Serf remain in the dependency-stage superset for this gate and are not copied into the Subversion bridge runtime until the later generator-wiring slice.
- Ask Gemini/OpenCode preflight succeeded in the refreshed environment. A lightweight review consultation highlighted that link success does not validate CRT/provider behavior, TLS handshakes, certificate verification, proxy/auth behavior, or runtime `libsvn_ra_serf` call paths; those are kept as later gates.

This slice intentionally does not pass `--with-serf` or OpenSSL paths to Subversion's `gen-make.py`, assert `libsvn_ra_serf`, add HTTPS certificate fixtures, validate TLS handshakes, change auth callback routing, or claim HTTP/HTTPS repository support.

## M6r Gates

- Native script tests cover OpenSSL and Serf dependency targets, stage assertions, required tool preflight wiring, Serf SCons staged-lib and UTF-8 invocation arguments, Serf DLL import-library probe wiring, the bridge-stage exclusion of future HTTPS artifacts, and the absence of Subversion generator Serf/OpenSSL wiring in this slice.
- The real Windows dependency build gate rebuilds `.cache/native/stage/subversion-deps-win-x64` from locked sources and verifies OpenSSL 3.5.7, Serf 1.3.10, and the Serf/OpenSSL mutual link probe.
- Current-source research confirms the Windows build commands from upstream OpenSSL docs, the Serf SCons `APR`/`APU`/`OPENSSL`/`PREFIX` contract, and the Subversion `--with-serf`/`--with-openssl` generator boundary reserved for the next slice.

## M6s Implemented Slice

The nineteenth M6 slice wires the staged OpenSSL/Serf dependency closure into the Apache Subversion 1.14.5 Windows source build and asserts the resulting ra_serf registration without claiming end-to-end HTTPS behavior:

- `scripts/native/build-subversion.ps1` now requires explicit `SerfRoot` and `OpenSslRoot` inputs. Missing paths fail before Visual Studio toolchain setup.
- The current Subversion build entrypoint is intentionally a single dependency-stage model: all explicit generator roots must resolve to `DependencyStageRoot`, because bridge staging copies dependencies from that one verified prefix and records that prefix's source-lock manifest.
- The Subversion build entrypoint validates the staged Serf 1.3.10 and OpenSSL 3.5.7 roots before invoking `gen-make.py`.
- `gen-make.py` now receives `--with-serf=<staged-root>` and `--with-openssl=<staged-root>`, so the generated solution includes `libsvn_ra_serf.vcxproj` and links Serf/OpenSSL into the RA runtime graph.
- The build gate checks the generated MSBuild project graph before compiling: `libsvn_ra_serf.vcxproj` must be a static library, `libsvn_ra_dll.vcxproj` must be the final dynamic `libsvn_ra-1` target, the RA DLL must reference `libsvn_ra_serf.vcxproj`, and its link inputs must include `serf-1.lib`, `libssl.lib`, and `libcrypto.lib`.
- `Assert-SubversionDependencyStage` now treats APR, zlib, Expat, SQLite, OpenSSL, and Serf as the current Subversion dependency closure instead of keeping OpenSSL/Serf as future artifacts.
- `Copy-SubversionBuildStage` copies the OpenSSL headers, import libraries, and runtime DLLs required by `libsvn_ra-1.dll`, plus the Serf headers and static `serf-1.lib` build input used by the generated RA graph.
- The Subversion stage manifest now records `openssl` and `serf` alongside the existing locked dependency entries.
- The bridge-stage validator requires the source-built `libsvn_ra_serf-1.lib` static RA target, validates the copied OpenSSL and Serf headers against the source lock, and does not require a standalone `libsvn_ra_serf-1.dll` because the Apache Subversion 1.14.5 Windows generator links `libsvn_ra_serf` into `libsvn_ra-1.dll`.
- `bin/libserf-1.dll` and the Serf DLL import library remain dependency-stage build artifacts only. They are not copied into the bridge runtime stage because the current generated RA DLL links static Serf and local `dumpbin /dependents` evidence does not show a Serf DLL runtime dependency.
- The build gate runs staged `svn.exe --version` with the staged `bin` directory on `PATH` and requires the output to report `ra_serf` handling both `http` and `https` schemes. This is a registration probe, not an HTTPS handshake or certificate-validation claim.
- A local `dumpbin /dependents` check confirmed that the staged `libsvn_ra-1.dll` now depends on the source-built OpenSSL runtime DLLs, matching the generated RA link graph.

This slice intentionally does not add an HTTPS server fixture, perform a TLS handshake, validate certificate callbacks, change auth callback routing, enable proxy-auth scenarios, add product protocol capabilities, or claim user-facing HTTP/HTTPS repository support.

## M6s Gates

- Native script tests cover explicit Serf/OpenSSL Subversion build inputs, single dependency-stage enforcement, generator arguments, generated MSBuild RA project-graph validation, dependency-stage hard requirements, source-lock version checks on copied OpenSSL/Serf headers, stage-manifest dependency expansion, `libsvn_ra_serf-1.lib` staging, OpenSSL runtime copying, Serf DLL exclusion from the bridge runtime, and staged `svn.exe --version` ra_serf registration wiring.
- The real Windows Subversion source build confirms `gen-make.py` finds OpenSSL 3.5.7 and Serf 1.3.10, generates `libsvn_ra_serf.vcxproj`, builds `__ALL__`, stages the HTTPS dependency closure, and verifies `ra_serf` reports `http` and `https` schemes.
- Current-source research confirms the upstream Windows generator behavior: `libsvn_ra_serf` is a static target on this build path and is linked into `libsvn_ra-1.dll`, not emitted as a standalone runtime DLL.

## M6t Implemented Slice

The twentieth M6 slice adds the first HTTPS certificate callback fixture gate without claiming full SVN-over-HTTPS repository support:

- `subversionr_bridge_probe_remote_url_with_auth` is now a narrow C ABI for probing a remote URL through `svn_client_info4` under the SubversionR auth baton. It exists to exercise libsvn/RA auth callbacks and can support later remote-discovery work, but it is not exposed as a product JSON-RPC capability in this slice.
- `NativeBridge::probe_remote_url_with_auth` loads the new symbol fail-fast, reuses the existing credential and certificate callback wiring, and returns broker-originated auth failures before mapping generic remote probe failures.
- The native HTTPS fixture generates a self-signed test certificate with the staged OpenSSL executable and an explicit temporary OpenSSL config, starts a local `openssl s_server`, then probes `https://127.0.0.1:<port>/repo/trunk` through the source-built libsvn/ra_serf bridge path.
- The fixture rejects the certificate through the Rust auth broker and asserts that the real libsvn SSL trust callback produced a `certificate/request` with a `sha256-der` fingerprint, URL realm, primary-CN host, validation failures including `unknownCa`, validity dates, issuer metadata, foreground interactivity, persistence allowance, and no working-copy scope.
- `BridgeFailure::code()` provides a read-only failure-code accessor for integration tests without exposing mutable error fields.
- Ask Gemini/OpenCode preflight succeeded in the refreshed environment, and a blind-spot consultation called out the exact evidence boundary: `E230001` alone proves TLS validation, but this gate directly asserts bridge callback entry and field marshaling.
- Current-source research confirmed that `svn_auth_ssl_server_cert_info_t.hostname` is the certificate primary CN; the fixture therefore treats the connection realm and certificate host as distinct observable fields.

This slice intentionally does not add Apache httpd/mod_dav_svn, perform a successful SVN-over-HTTPS DAV operation, add product protocol capabilities, route user-facing repository opens through remote URL probing, enable standard SVN auth-cache persistence, cover proxy auth or client certificates, implement certificate review/revoke UI, or claim product-level HTTPS repository support.

## M6t Gates

- `pnpm native:build-bridge:staged` rebuilds the bridge against the verified Subversion/OpenSSL/Serf stage and exports the new remote probe ABI.
- The ignored native integration test `native_bridge_remote_probe_https_certificate_failure_routes_through_broker` runs with `SUBVERSIONR_TEST_BRIDGE_DLL` and `SUBVERSIONR_TEST_OPENSSL_EXE` and verifies that the real libsvn/ra_serf certificate callback reaches the Rust broker.
- The gate uses only staged source-built native artifacts for libsvn/ra_serf/OpenSSL. The `svn` CLI remains outside the fixture path and is not a production dependency.

## M6u Implemented Slice

The twenty-first M6 slice routes history retrieval through the daemon auth broker:

- `BridgeApi::history_log` and `BridgeApi::history_blame` now require an `AuthRequestBroker`, matching the broker-required remote-read and mutating operation boundary already used by content, update, and commit.
- `history/log` and `history/blame` dispatch pass the foreground stdio broker while the original JSON-RPC request remains outstanding, so libsvn credential prompts become daemon-originated `credentials/request` frames.
- Direct non-stdio callers must pass `UnavailableAuthRequestBroker` explicitly; if libsvn prompts, history operations return `SUBVERSIONR_AUTH_BROKER_UNAVAILABLE` rather than a generic native history failure.
- `NativeBridge::history_log` and `NativeBridge::history_blame` construct scoped auth callback tables with repository id and working-copy root context, and return broker-originated auth failures before generic history/blame mappings.
- The C bridge exports `subversionr_bridge_history_log_with_auth` and `subversionr_bridge_history_blame_with_auth`, requires callbacks, installs a scoped libsvn auth baton around exactly one `svn_client_log5` or `svn_client_blame6` call, restores the previous `svn_client_ctx_t.auth_baton`, and keeps existing history result-pool ownership.
- The old no-auth history C exports are not kept, so old bridge DLLs fail fast at Rust symbol loading instead of silently bypassing the auth broker.
- The `svnserve` fixture now exercises authenticated history log and blame through `NativeBridge`: checkouts created with `--no-auth-cache` call `history_log` and `history_blame` through the test broker, and the broker must record repository-scoped credential challenges.

This slice intentionally does not add cancellation UI, streaming progress, copy-from authz edge fixtures, HTTPS DAV success fixtures, standard SVN auth-cache persistence, new protocol capabilities, or product-level remote polling.

## M6u Gates

- Daemon stdio tests cover `history/log` and `history/blame` issuing daemon-originated `credentials/request` frames, accepting matching responses, and then completing the original history responses.
- Dispatch tests cover non-stdio history log and blame auth prompts returning `SUBVERSIONR_AUTH_BROKER_UNAVAILABLE` through the stable auth error contract.
- Native script tests assert that Rust loads `subversionr_bridge_history_log_with_auth` and `subversionr_bridge_history_blame_with_auth`, and that the C header/source do not keep the old no-auth history exports.
- Native bridge build and smoke tests compile the updated C ABI with MSVC/CMake and verify the staged DLL still reports Apache Subversion `1.14.5`.
- Ignored native integration tests cover localhost `svn://` history log and blame through the broker, asserting that a credential request was recorded with the repository working-copy root and that libsvn returns the expected history data.

## M6v Implemented Slice

The twenty-second M6 slice starts the real Apache httpd/mod_dav_svn HTTPS fixture track as a source-lock and dependency-strategy gate:

- `native/sources.lock.json` now locks Apache HTTP Server 2.4.68 from the official Apache HTTP Server source distribution, including SHA512, SHA256, PGP signature URL, Apache HTTP Server KEYS URL, and Apache-2.0 license metadata.
- `native/sources.lock.json` now locks PCRE2 10.47 from the official PCRE2 GitHub release source artifact, including SHA512, upstream SHA256, GPG signature URL, the documented Nicholas Wilson release-signing key fingerprint URL, and the upstream `BSD-3-Clause WITH PCRE2-exception` license expression.
- The current M6v dependency strategy is source-first: httpd and PCRE2 are verified native sources but are not yet dependency-build targets, not copied into the bridge stage, and not included in the Subversion stage manifest.
- The future fixture remains a source-built local test server path: Apache httpd provides the HTTPS/WebDAV server process, Subversion's source-built `mod_dav_svn`/`mod_authz_svn` modules provide repository DAV behavior, and the existing source-built libsvn/ra_serf bridge path remains the client under test.
- Current-source research confirmed that Apache HTTP Server 2.4.68 is the latest stable httpd release, official httpd releases require independent checksum and PGP verification, Windows httpd builds support MSVC project-file and CMake routes with documented CMake limitations, PCRE2 publishes source-only signed releases on GitHub, and PCRE2 10.47 is the current release after the 10.46 security-only release.

This slice intentionally does not build PCRE2, build Apache httpd, build or stage `mod_dav_svn`/`mod_authz_svn`, generate httpd configuration, launch an HTTPS DAV server, add product protocol capabilities, route user-facing remote repository opens through HTTPS, enable standard SVN auth-cache persistence, or claim product-level SVN-over-HTTPS support.

## M6v Gates

- Native script tests assert the exact Apache HTTP Server and PCRE2 source-lock metadata, including URLs, SHA512/SHA256 checksums, signatures, key sources, and license fields.
- The native source verifier downloads and verifies the locked Apache HTTP Server and PCRE2 release archives through the existing fail-fast source gate.
- Manual source verification confirmed the Apache HTTP Server 2.4.68 tarball against the Apache HTTP Server KEYS file and the PCRE2 10.47 tarball against the documented Nicholas Wilson release-signing key path.

## M6w Implemented Slice

The twenty-third M6 slice turns the future HTTPS fixture track's PCRE2 prerequisite into a source-built Windows x64 dependency stage:

- `scripts/native/build-dependencies.ps1 -Only pcre2` now builds locked PCRE2 10.47 from source with the Visual Studio 2022 CMake generator, installs an 8-bit static PCRE2 package into the native dependency stage, and pins the MSVC runtime flavor to `MultiThreadedDLL`.
- `scripts/native/build-dependencies.ps1 -Only all` now includes PCRE2 before the APR/OpenSSL/Serf stack while keeping PCRE2 out of the Subversion bridge stage manifest because the current libsvn client runtime does not consume it.
- `Assert-Pcre2StageForHttpd` validates the staged generated `pcre2.h`, static `pcre2-8-static.lib`, installed CMake package files, exact locked `10.47` release version, empty prerelease marker, exported static target metadata, and absence of PCRE2 DLL runtime artifacts for this gate.
- The dependency script runs both a raw MSVC static link probe and a CMake `find_package(PCRE2 CONFIG REQUIRED COMPONENTS 8BIT)` consumer probe against the staged package, so future Apache httpd work starts from a tested CMake consumption path rather than a file-existence-only stage.
- Ask Gemini/OpenCode architecture consultation was verified through the local wrapper and used as an independent blind-spot check for this slice; the integrated decision was to keep this as a PCRE2-only gate and defer Apache httpd/mod_dav_svn build claims until their own stage is proven.

This slice intentionally does not build Apache httpd, build or stage `mod_dav_svn`/`mod_authz_svn`, generate httpd configuration, launch an HTTPS DAV server, add product protocol capabilities, route user-facing remote repository opens through HTTPS, enable standard SVN auth-cache persistence, or claim product-level SVN-over-HTTPS support.

## M6w Gates

- Native script tests assert the PCRE2 build target, static 8-bit CMake options, disabled unused PCRE2 variants/tools, MSVC runtime pin, raw link probe, CMake consumer probe, and continued absence of an Apache HTTP Server build target.
- Module tests cover `Assert-Pcre2StageForHttpd` accepting a locked 10.47 static stage and rejecting missing static libraries, wrong header versions, prerelease headers, and unexpected PCRE2 DLL runtime artifacts.
- Local native dependency verification must run `build-dependencies.ps1 -Only pcre2` with `VsDevCmd.bat`, proving the locked source archive builds and both probes execute on Windows x64.

## M6x Implemented Slice

The twenty-fourth M6 slice stages the source-built Apache HTTP Server core substrate required before the `mod_dav_svn` HTTPS fixture:

- `scripts/native/build-httpd.ps1` now builds locked Apache HTTP Server 2.4.68 from source with the Visual Studio 2022 CMake generator, consuming the explicit `.cache/native/stage/subversion-deps-win-x64` dependency stage and installing to `.cache/native/stage/httpd-win-x64`.
- `scripts/native/build-dependencies.ps1 -Only all` now stages the exact APR private headers listed by upstream APR's `APR_INSTALL_PRIVATE_H` path, and `Assert-AprPrivateHeadersForHttpd` fails fast if the dependency stage cannot compile Apache HTTP Server.
- The httpd CMake invocation binds APR/APR-util/APR-iconv, PCRE2, OpenSSL, and zlib to the source-built dependency stage, propagates `PCRE2_STATIC`, reuses the APR Windows network compile definitions required by `apr_arch_misc.h`, and disables unowned `LibXml2`, `Lua51`, and `CURL` discovery.
- The gate explicitly requires inactive `mod_dav`, inactive `mod_ssl`, and inactive `mod_deflate` link sentinels while omitting `mod_dav_fs` and `mod_dav_lock`. Apache httpd's Windows CMake defaults still stage other built-in/default modules; M6x is a verified fixture substrate, not a minimized redistributable runtime.
- `Assert-ApacheHttpdStageForDavFixture` validates `httpd.exe`, `libhttpd`, `mod_dav`, `mod_ssl`, `mod_deflate`, required headers/import libraries, copied APR/Expat/OpenSSL runtime DLLs, APR iconv modules, and `subversionr-httpd-stage-manifest.json`.
- The stage assertion rejects PCRE2 runtime DLLs, zlib runtime DLLs, and premature `mod_dav_svn`/`mod_authz_svn` artifacts so this gate remains a static-PCRE2 httpd substrate, not a working SVN-over-HTTPS server claim.
- Windows CI now runs the httpd substrate build after the native dependency stage and before the Apache Subversion library gate.

This slice intentionally does not build or stage `mod_dav_svn`/`mod_authz_svn`, generate an SVN repository DAV configuration, launch an HTTPS DAV server, add product protocol capabilities, route user-facing remote repository opens through HTTPS, enable standard SVN auth-cache persistence, or claim product-level SVN-over-HTTPS support.

## M6x Gates

- Native script tests assert the dedicated `build-httpd.ps1` entrypoint, APR private-header staging, explicit CMake dependency binding, disabled unowned package discovery, inactive DAV/SSL/deflate substrate modules, stage manifest validation, and forbidden premature DAV SVN artifacts.
- Local native dependency verification must run `build-dependencies.ps1 -Only all` with `VsDevCmd.bat`, proving the APR private headers are staged without breaking the existing Subversion dependency chain.
- Local httpd verification must run `build-httpd.ps1 -DependencyStageRoot .cache/native/stage/subversion-deps-win-x64 -StageRoot .cache/native/stage/httpd-win-x64`, proving the locked source archive builds and the CMake cache resolves APR, PCRE2, OpenSSL, and zlib to the staged paths.
- The httpd probe runs staged `httpd.exe -V` and `httpd.exe -t -d <stage> -f conf/httpd.conf`; the verified local output reported Apache HTTP Server `2.4.68`, APR `1.7.6`, APR-util `1.6.3`, PCRE `10.47`, and `Syntax OK`.

## M6y Implemented Slice

The twenty-fifth M6 slice compiles and stages the source-built Apache Subversion DAV modules against the verified httpd substrate:

- `scripts/native/build-subversion-dav-modules.ps1` re-extracts the locked Apache Subversion 1.14.5 source, runs the Windows generator with explicit staged dependency roots plus `--with-httpd=.cache/native/stage/httpd-win-x64`, retargets generated projects from `v142` to `v143`, and builds `mod_authz_svn.vcxproj` directly with an explicit `SolutionDir`.
- `Assert-GeneratedSubversionApacheModuleProjectGraph` fails fast unless the generator emits `mod_dav_svn.vcxproj` and `mod_authz_svn.vcxproj` as `.so` dynamic-library targets, links `mod_dav_svn` to `libhttpd.lib` and `mod_dav.lib`, and makes `mod_authz_svn` reference `mod_dav_svn.vcxproj`.
- The clean `.cache/native/stage/httpd-win-x64` substrate remains unchanged and still rejects premature SVN DAV artifacts. The new composite runtime is staged separately under `.cache/native/stage/httpd-subversion-dav-win-x64`.
- `Copy-ApacheHttpdSubversionDavStage` copies the verified httpd runtime, the built `mod_dav_svn.so`/`mod_authz_svn.so` plus PDBs, and the required source-built `libsvn_repos/fs/fs_fs/fs_x/fs_util/delta/subr` DLL closure without copying `svn.exe`, `svnadmin.exe`, or `svnserve.exe`.
- `subversionr-httpd-subversion-dav-stage-manifest.json` records both locked sources, the union of httpd/Subversion native dependency locks, module hashes, and runtime DLL hashes.
- The M6y probe writes a load-only httpd configuration and runs staged `httpd.exe -M` plus `httpd.exe -t` with explicit `LoadModule dav_module`, `dav_svn_module`, and `authz_svn_module` lines. The probe intentionally rejects repository-serving directives such as `SVNPath` and `SVNParentPath`, and it uses only the composite stage `bin`/`modules` paths for DLL resolution.
- Windows CI now runs the Subversion DAV module gate after the httpd substrate and libsvn source build, before building the bridge.

This slice intentionally does not create a repository DAV configuration, launch a long-running HTTPS server, perform a successful SVN-over-HTTPS working-copy operation, add product protocol capabilities, route user-facing repository opens through HTTPS, enable standard SVN auth-cache persistence, or claim product-level SVN-over-HTTPS support.

## M6y Gates

- Native script tests assert the dedicated `build-subversion-dav-modules.ps1` entrypoint, clean-substrate validation, generator `--with-httpd` wiring, generated Apache module project graph validation, protected-root overlap rejection before any generated directory clear, exact manifest artifact paths, separate composite stage manifest validation, forbidden `mod_dontdothat`, and the absence of copied SVN CLI fixture tools.
- Local verification must run `build-subversion-dav-modules.ps1 -DependencyStageRoot .cache/native/stage/subversion-deps-win-x64 -HttpdStageRoot .cache/native/stage/httpd-win-x64 -SubversionStageRoot .cache/native/stage/subversion-win-x64 -StageRoot .cache/native/stage/httpd-subversion-dav-win-x64`, proving the locked source archive builds and the modules load into the staged Apache HTTP Server runtime.
- The load-only probe must report `dav_svn_module` and `authz_svn_module` and return `Syntax OK` without `SVNPath`, `SVNParentPath`, or HTTPS certificate directives.

## M6z Implemented Slice

The twenty-sixth M6 slice adds the first successful SVN-over-HTTPS DAV operation gate through the existing source-built libsvn/ra_serf bridge path:

- The ignored native bridge integration test now creates a temporary FSFS repository with the staged source-built `svnadmin.exe` and seeds it with the staged source-built `svn.exe`.
- The fixture generates a one-day self-signed localhost certificate with the staged OpenSSL executable and SAN entries for `localhost` and `127.0.0.1`.
- The fixture starts the staged source-built Apache HTTP Server as an owned foreground `httpd.exe -X` child process, using an explicit temporary `httpd.conf` that loads `mod_ssl`, `mod_dav`, `mod_dav_svn`, and `mod_authz_svn`, binds only `https://127.0.0.1:<port>/svn`, and writes logs/PID files under the fixture temp root.
- The fixture runs `httpd.exe -t` before startup and polls readiness with staged `svn info` over HTTPS using a unique config directory and explicit non-interactive test-only certificate trust.
- `NativeBridge::content_get(..., "head")` retrieves committed HEAD content from the HTTPS DAV working copy through libsvn/ra_serf, and `NativeBridge::operation_update(...)` updates the same working copy after a remote commit.
- The test broker returns `CertificateTrustResponse::Trust { trust: "once" }` and asserts that real certificate requests were observed for both HEAD content and update, including repository id, working-copy root, SHA-256 DER fingerprinting, and the expected `unknownCa` failure.
- `scripts/native/smoke-httpd-dav-https.ps1` provides a dedicated exact-test entrypoint that fails fast on missing bridge, staged OpenSSL, staged Subversion CLI fixture tools, or staged HTTPD/Subversion DAV runtime artifacts.
- Windows CI passes `SUBVERSIONR_TEST_HTTPD_DAV_STAGE` into the existing ignored native bridge integration gate so the HTTPS DAV smoke runs after the source-built DAV runtime has been staged.
- Ask Gemini/OpenCode and a read-only subagent review both recommended a dedicated fixture/test gate, foreground child-process ownership, self-signed SAN certificates, explicit stage-only runtime paths, and certificate-broker assertions; the implementation follows that boundary.

This slice intentionally does not add Basic auth, proxy auth, client certificates, standard SVN credential-store opt-in, product JSON-RPC capabilities for remote HTTPS repository discovery, background remote polling, performance/concurrency coverage for Apache HTTP Server, public packaging of httpd modules, or a product-level claim that arbitrary HTTPS SVN repositories are supported.

## M6z Gates

- The exact ignored Rust integration test `native_bridge_https_dav_content_and_update_route_certificate_trust_through_broker` must pass with `SUBVERSIONR_TEST_BRIDGE_DLL`, `SUBVERSIONR_TEST_OPENSSL_EXE`, and `SUBVERSIONR_TEST_HTTPD_DAV_STAGE` pointing only at source-built staged artifacts.
- `scripts/native/smoke-httpd-dav-https.ps1` must run that exact test and fail fast on missing required staged artifacts.
- Native script tests assert the package script, smoke script, exact test name, staged DAV runtime environment variable, and CI wiring.

## M6aa Implemented Slice

The twenty-seventh M6 slice closes the public-readiness security documentation gap and sets the security boundary for M7 packaging work:

- `docs/security/threat-model.md` records the public security threat model for the current VS Code extension, Rust sidecar, C bridge, libsvn, working-copy, diagnostics, support, and packaging boundaries.
- `docs/security/support-handling.md` records the security vulnerability report process, support bundle handling rules, sensitive-material do-not-request list, redaction expectations, retention expectations, and telemetry non-upload policy.
- `docs/security/m6-to-m7-security-decision.md` separates M6aa documentation completeness from M7 release blockers such as `SECURITY.md`, SBOM, NOTICE, CVE review, signing, platform VSIX packaging, rollback, migration reporting, and public claim matrices.
- The docs explicitly track `SEC-001` through `SEC-016`, `OBS-005` through `OBS-008`, and `MIG-008` through `MIG-012` without marking documentation review as runtime security verification.
- The public claim boundary for HTTPS remains the source-built localhost DAV fixture proven in M6z. Arbitrary HTTPS SVN servers, proxy authentication, client certificates, `svn+ssh`, Kerberos/NTLM, SASL, and custom tunnels remain unclaimed.
- A root package script, `pnpm docs:verify-security`, verifies the required public security documents, sections, roadmap linkage, M6 plan linkage, and requirement-id traceability.
- Windows CI runs the public security documentation check before test execution, so future public-readiness edits fail fast when the security docs drift.
- An Ask Gemini/OpenCode security consultation reviewed the M6aa scope for misleading public claims and highlighted certificate coverage, SecretStorage-unavailable behavior, diagnostics redaction specificity, libsvn cache behavior, sidecar lifecycle, and M7 gate separation as public-readiness risks.

This slice intentionally does not implement new runtime security behavior, enable standard SVN credential-store persistence, add certificate review/revoke UI, add rich diagnostics UI, add telemetry, add TortoiseSVN execution, expand HTTPS product support, create public release artifacts, or close M7 supply-chain gates.

## M6aa Gates

- `pnpm docs:verify-security` must pass.
- The security documentation gate must require `docs/security/threat-model.md`, `docs/security/support-handling.md`, and `docs/security/m6-to-m7-security-decision.md`.
- The security documentation gate must require M6 plan and roadmap references for the public-readiness security documentation slice.
- The security documentation gate must fail if any required `SEC`, `OBS`, or `MIG` trace ID is removed from the public security documentation set.

## Next M6 Slices

- No additional M6 slices are currently planned. M7 should start from the M6aa security decision document and turn the listed release blockers into packaging, migration, and public-release gates.

## Deferred M6 Work

- Per-folder trust nuance beyond VS Code's current `workspace.isTrusted` boolean surface.
- Rich diagnostics UI and support bundle export UX.
- Standard SVN credential-store opt-in.
- Certificate trust review and revoke UI.
- Native stderr streaming beyond bounded startup and diagnostics metadata.
- Full concurrent stdio dispatch while a foreground libsvn callback is blocked.

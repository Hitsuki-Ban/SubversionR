# SubversionR Public Security Threat Model

## Scope

This document describes the public-readiness security model for the M6 implementation of SubversionR. It covers the VS Code TypeScript extension, the Rust sidecar, the narrow C bridge, Apache Subversion `libsvn`, local working copies, explicit authentication prompts, certificate trust prompts, diagnostics, and the first source-built native HTTPS DAV fixture gates.

This is a documentation and release-readiness control, not a final security certification. A control marked as implemented still needs the matching automated evidence and release gate before a public build can claim product readiness.

Out of scope for M6aa:

- General support for arbitrary HTTPS SVN servers beyond the source-built localhost DAV fixture that currently proves HEAD content and update flows through the certificate broker.
- `svn+ssh`, proxy authentication, client certificates, Kerberos/NTLM, SASL, and standard SVN credential-store opt-in.
- TortoiseSVN write-dialog execution, custom shell/tunnel execution, remote path mapping, and rich diagnostics UI.
- Signing, SBOM, NOTICE, CVE, platform packaging, rollback, and migration reporting gates, which remain M7 release work.

## Assets

Protected assets include:

- SVN credentials, certificate trust decisions, passphrases, proxy passwords, and future client-certificate passwords (`SEC-001`, `SEC-002`, `SEC-003`, `SEC-004`, `SEC-005`, `SEC-006`).
- Working-copy metadata, local paths, repository URLs, repository UUIDs, file contents, log messages, blame output, and diagnostics bundles (`SEC-012`, `SEC-013`, `SEC-014`, `OBS-005`, `OBS-006`, `OBS-007`).
- JSON-RPC method names, frame payloads, auth request identities, cancellation messages, and sidecar lifecycle state (`SEC-009`, `SEC-010`, `SEC-016`).
- Packaged backend binaries, native dependency archives, built native stages, VSIX artifacts, release provenance, SBOM, and legal notices (`SEC-015`, `MIG-009`, `MIG-012`).
- Workspace trust state, extension settings, external-tool paths, SVN config directories, and future tunnel commands (`SEC-007`, `SEC-008`, `SEC-011`).
- Cache schema state, rollback behavior, and public support/migration reporting (`MIG-008`, `MIG-010`, `MIG-011`).

## Trust Boundaries

| Boundary | Trusted Inputs | Untrusted Inputs | Current Control |
| --- | --- | --- | --- |
| VS Code extension host | VS Code APIs, localized strings, explicit user choices | Workspace files, workspace settings, command invocations, virtual document opens | Workspace Trust gates, localization layer, stable error keys (`SEC-007`, `SEC-008`) |
| SecretStorage | Explicit user-approved credential and certificate persistence | Raw realms, untrusted workspace requests, background prompts | Hashed realm keys, no backend persistence of final user prose, no prompt in background (`SEC-001`, `SEC-003`, `SEC-006`) |
| Rust sidecar | Parent-child stdio, typed protocol structs, C ABI wrappers | Malformed frames, unexpected requests, stale auth responses, sidecar EOF | Stdio-only transport, frame limits, allowlisted methods, stable auth errors (`SEC-009`, `SEC-010`) |
| C bridge and `libsvn` | Source-built Apache Subversion 1.14.5, scoped callback tables | APR/libsvn callback data, remote server responses, certificate metadata | Narrow C ABI, Rust-owned broker, no Rust exposure of APR structs (`SEC-004`, `SEC-005`, `SEC-016`) |
| Working copy | libsvn-confirmed operation results | Corrupt `.svn/wc.db`, malicious paths, oversized metadata | libsvn remains authoritative; direct fast paths must be read-only and bounded (`SEC-016`) |
| Diagnostics and support | User-initiated JSON bundle, version report | Secrets, paths, URLs, source content, raw stderr, crash artifacts | Recursive redaction, local save dialog, no automatic upload (`SEC-002`, `SEC-014`, `OBS-005`, `OBS-006`, `OBS-007`) |
| Packaging and release | Locked source manifests, CI artifacts, release metadata | Replaced binaries, stale dependencies, license drift, rollback failures | M7 signing, SBOM, NOTICE, CVE, platform VSIX, rollback gates (`SEC-015`, `MIG-008`, `MIG-009`, `MIG-010`, `MIG-012`) |
| External tools | Explicit executable/config selections and optional Tortoise read-only GUI handoff | Workspace-provided binaries, shell strings, Tortoise automation | Restricted configuration declarations plus M7e structured Tortoise args with no shell launch (`SEC-008`, `SEC-011`) |

## Threats And Controls

| Threat | Control | Trace IDs | Verification Status |
| --- | --- | --- | --- |
| Credential disclosure through logs, diagnostics, settings, or Rust error payloads | TypeScript-owned SecretStorage, realm hashing, no secrets in safe args, diagnostics redaction | `SEC-001`, `SEC-002`, `SEC-003`, `SEC-014`, `OBS-005`, `OBS-007` | Implemented with tests in M6b/M6c; public support handling remains M6aa doc-gated |
| Background or untrusted workspace auth prompts | Workspace Trust and origin gates block before SecretStorage read or UI prompt | `SEC-006`, `SEC-007`, `SEC-008` | Implemented with TypeScript tests; SecretStorage-unavailable hard-fail behavior remains a M7 acceptance check |
| Certificate man-in-the-middle or stale permanent trust | SHA-256 DER fingerprint identity, reject/once/permanent decisions, changed-fingerprint re-prompt/rejection | `SEC-004`, `SEC-005`, `SEC-006` | Implemented in controller and native callback tests; current HTTPS DAV success gate is localhost fixture only |
| JSON-RPC injection, oversized frames, stale auth responses, or request floods | Parent-child stdio only, frame limits, envelope validation, allowlisted dispatch, auth wait budgets | `SEC-009`, `SEC-010`, `SEC-016` | Implemented in daemon stdio tests; full concurrent dispatcher remains deferred |
| Command injection through external tools or custom SVN tunnel/config settings | Restricted configurations and no shell-concatenated external execution in current product path | `SEC-008`, `SEC-011` | M7e read-only Tortoise adapter execution is covered by TypeScript tests; mutating dialogs and custom tunnel execution remain deferred |
| Temp/cache leakage or support bundle oversharing | Current-user temp/cache policy, no secret cache, redacted diagnostics output | `SEC-012`, `SEC-013`, `SEC-014`, `OBS-005`, `OBS-006`, `OBS-007`, `OBS-008` | Diagnostics redaction implemented; richer bundle UX and retention workflow are M7/public support gates |
| Malicious paths, URLs, XML, logs, server responses, or working-copy metadata | Stable parser limits, libsvn as semantic authority, fuzz/fixture gates before public claim | `SEC-016` | Deterministic malicious-input corpus evidence now maps focused path, URL redaction, log rendering, JSON-RPC tests, the M7l5 native malicious DAV/XML history-log fixture, the M7l6 native malicious `svn://` server-response fixture, the M7l7 native remote-protocol fuzz readiness contract, the M7l8 native remote-protocol fuzz target source preflight, and the M7l9 native remote-protocol fixed seed harness smoke; coverage-guided fuzzing remains an M7 blocker |
| Replaced binaries, stale dependencies, missing notices, or unverifiable public artifacts | Source locks, checksums/PGP where available, future release signing, SBOM, NOTICE, CVE scan, platform VSIX matching | `SEC-015`, `MIG-009`, `MIG-012` | Source build gates exist; public release supply-chain gates are not complete |
| Cache schema or extension update leaves users unable to recover | Versioned cache schema, delete/rollback path, user-visible migration report | `MIG-008`, `MIG-010`, `MIG-011` | M7 requirement; not closed by M6aa docs |

## Security Acceptance Matrix

| ID | Public-Readiness Disposition |
| --- | --- |
| `SEC-001` | Implemented SecretStorage-first design; public release must still document hard failure when SecretStorage is unavailable. |
| `SEC-002` | Implemented no-secret diagnostics/log policy; support handling defines what maintainers must not request. |
| `SEC-003` | Implemented realm-scoped hashing in TypeScript; raw realms must stay out of storage keys and safe args. |
| `SEC-004` | Implemented certificate reject/once/permanent controller and native callback route; non-localhost/product coverage is not claimed. |
| `SEC-005` | Implemented changed-fingerprint rejection/re-prompt semantics; review/revoke UI remains deferred. |
| `SEC-006` | Implemented no background prompt policy; public docs must preserve the hard-fail contract. |
| `SEC-007` | Implemented VS Code Workspace Trust limited mode for current operations. |
| `SEC-008` | Implemented restricted configuration declarations for future external tool/config paths. |
| `SEC-009` | Implemented stdio-only daemon transport; no sockets or ports are part of production IPC. |
| `SEC-010` | Implemented JSON-RPC framing and auth wait limits; full concurrent dispatch remains deferred. |
| `SEC-011` | Implemented policy foundation plus M7e optional Tortoise read-only launcher with structured args and no shell execution. |
| `SEC-012` | Requires public release evidence for temp permissions across packaged flows. |
| `SEC-013` | Requires public release evidence that caches contain no secrets and Clear Cache does not mutate working copies. |
| `SEC-014` | Implemented redaction foundation; support bundle policy and redaction fixture are M6aa/M7 release evidence. |
| `SEC-015` | M7 gate: signing, SBOM, NOTICE, CVE scan, binary verification, release provenance. |
| `SEC-016` | M7 gate: malicious path/URL/log/XML/server-response/fuzz evidence. Current corpus preflight plus M7l5 native DAV/XML, M7l6 native `svn://` server-response fixtures, M7l7 native remote-protocol fuzz readiness contract, M7l8 native remote-protocol fuzz target source preflight, and M7l9 native remote-protocol fixed seed harness smoke remain a minimum evidence floor while coverage-guided fuzzing stays blocked. |

## Deferred Risks

- Per-folder trust nuance is not promised. M6 uses VS Code's current `workspace.isTrusted` surface and VS Code-restricted configuration behavior.
- Standard SVN credential-store opt-in is deferred because it expands secret lifetime and must be explicit, tested, and documented.
- Certificate trust review and revoke UI is deferred. Until implemented, trust records are managed only through the implemented SecretStorage-backed controller and documented support process.
- Native stderr streaming remains bounded. Rich streaming diagnostics would increase privacy risk and needs separate redaction controls.
- Full concurrent stdio dispatch during a blocking libsvn callback is deferred. Current behavior supports a single pending auth request with bounded handling, cancellation, and timeout checkpoints.
- Product-level claims for arbitrary HTTPS, proxy auth, client certificates, `svn+ssh`, Kerberos/NTLM, SASL, and non-localhost TLS are deferred.
- libsvn in-process credential caching and future standard SVN auth cache behavior must be reviewed before enabling any persistent SVN credential-store path.
- Sidecar crash dumps, if produced by the host platform, are local artifacts and must never be collected automatically. Public support handling must request only user-initiated, redacted evidence.
- Missing localization keys must not cause Rust or the daemon to synthesize end-user prose. Public release must verify the TypeScript localization layer for English, Japanese, and Chinese.

## M7 Release Gates

Before public packaging work can start, M7 must define executable release gates for:

- SBOM generation and third-party dependency inventory (`SEC-015`).
- MIT, Apache, OpenSSL, PCRE2, zlib, SQLite, APR, Serf, Apache HTTP Server, and Apache Subversion NOTICE/license publication (`SEC-015`, `MIG-012`).
- Native dependency CVE review and public vulnerability handling (`SEC-015`).
- Binary signing, hash verification, packaged sidecar/native dependency manifest, and sidecar replacement checks (`SEC-015`).
- Platform-specific VSIX packaging and update matching (`MIG-009`).
- Cache schema rollback, extension rollback, and migration user reports (`MIG-008`, `MIG-010`, `MIG-011`).
- Public support handling, diagnostics redaction fixture, telemetry opt-in policy, and vulnerability reporting path (`SEC-002`, `SEC-014`, `OBS-005`, `OBS-006`, `OBS-007`, `OBS-008`).

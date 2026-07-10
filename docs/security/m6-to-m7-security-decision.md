# M6aa To M7 Security Decision

## Required Before M7 Packaging

M6aa closes the public-readiness security documentation gap only. The following controls are required before M7 packaging or public release preparation can claim product readiness:

1. Publish a repository `SECURITY.md` with supported versions and a private vulnerability reporting path. M7a creates the initial policy.
2. Define public release gate documents in `docs/release/m7-release-readiness-gates.md`, `docs/release/security-evidence-matrix.md`, and `docs/release/public-claim-matrix.md`.
3. Generate and review SBOM output for the VS Code extension, Rust crates, C bridge, Apache Subversion, and bundled native dependencies (`SEC-015`).
4. Publish third-party NOTICE and license materials for MIT project code and bundled Apache/OpenSSL/PCRE2/zlib/SQLite/APR/Serf/httpd/Subversion dependencies (`SEC-015`, `MIG-012`).
5. Add native dependency CVE review to the release checklist and record the source-lock versions used for each VSIX (`SEC-015`).
6. Define binary signing, hash verification, packaged resource manifest, and sidecar replacement checks (`SEC-015`).
7. Build platform-specific VSIX artifacts with explicit target matching and no runtime dependency on system SVN, TortoiseSVN, or PATH probing (`MIG-009`).
8. Add cache schema rollback, extension rollback, and user-visible migration report gates (`MIG-008`, `MIG-010`, `MIG-011`).
9. Publish a security acceptance evidence matrix that maps `SEC-001` through `SEC-016`, `OBS-005` through `OBS-008`, and `MIG-008` through `MIG-012` to tests, fixtures, manual checks, or unresolved release blockers.
10. Add a diagnostics redaction fixture and support-bundle review checklist before asking public users for issue evidence (`SEC-002`, `SEC-014`, `OBS-005`, `OBS-006`, `OBS-007`). M7k1 implements the public support intake preflight, while broader release blockers remain open.
11. Document hard-fail behavior for unavailable SecretStorage, missing localization keys, sidecar crash during auth, auth timeout, and certificate prompt cancellation.
12. Add a public claim matrix for repository transports and auth modes. The current HTTPS DAV fixture supports only the documented source-built localhost evidence and must not be expanded into arbitrary HTTPS support without additional gates.

## Deferred After M6aa

The following items are intentionally deferred and must not be described as available product behavior:

- Per-folder trust nuance beyond VS Code's current workspace trust surface.
- Rich diagnostics UI and support bundle export UX beyond the current local JSON command.
- Standard SVN credential-store opt-in.
- Certificate trust review and revoke UI.
- Native stderr streaming beyond bounded startup and diagnostics metadata.
- Full concurrent stdio dispatch while a foreground libsvn callback is blocked.
- TortoiseSVN adapter execution and any external tool shell/tunnel invocation.
- Proxy authentication, client certificates, `svn+ssh`, Kerberos/NTLM, SASL, and non-localhost TLS assurance.
- Public packaging of the staged Apache HTTP Server/DAV fixture runtime.

## Requirement Traceability

| IDs | M6aa Decision |
| --- | --- |
| `SEC-001`, `SEC-003` | Keep TypeScript SecretStorage as the default credential authority; document unavailable SecretStorage as a hard failure before public release. |
| `SEC-002`, `SEC-014`, `OBS-005`, `OBS-006`, `OBS-007` | Keep diagnostics local and redacted; M7k1 adds public issue forms, a support redaction checklist, and a release redaction fixture before public support. |
| `SEC-004`, `SEC-005`, `SEC-006` | Keep certificate prompts explicit and non-background; do not claim arbitrary HTTPS coverage from the localhost DAV fixture. |
| `SEC-007`, `SEC-008`, `SEC-011` | Keep Workspace Trust and restricted settings as the external-tool boundary; do not add Tortoise/custom-tool fallback paths. |
| `SEC-009`, `SEC-010` | Keep parent-child stdio only with bounded framing; full concurrent dispatch is a later reliability/security enhancement. |
| `SEC-012`, `SEC-013` | Require packaged-flow temp/cache evidence before public release. |
| `SEC-015`, `MIG-009`, `MIG-012` | Treat signing, SBOM, NOTICE, CVE, and platform VSIX matching as M7 release blockers. |
| `SEC-016` | Require malicious input and protocol fuzz evidence beyond current focused tests before broad public claims. |
| `OBS-008` | Keep telemetry off by default; any future telemetry must be opt-in and localized. |
| `MIG-008`, `MIG-010`, `MIG-011` | Require cache schema, rollback, and migration report gates before public release. |

## Non-Claims

M6aa does not claim:

- Product-level support for arbitrary remote HTTPS SVN servers.
- Support for standard SVN credential-store persistence.
- Support for proxy auth, client certificates, `svn+ssh`, Kerberos/NTLM, SASL, or custom tunnels.
- That diagnostics redaction alone makes arbitrary user data safe to publish.
- That M6 source-built fixture gates are redistributable packaging gates.
- That public release security requirements are complete without SBOM, NOTICE, CVE, signing, rollback, and platform VSIX evidence.

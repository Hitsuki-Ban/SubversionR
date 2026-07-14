# Security Evidence Matrix

This matrix records public-release security evidence status. It is intentionally conservative: documentation can define a gate, but only automated tests, fixture runs, manual release checks, or signed release artifacts can close a release blocker.

## Status Vocabulary

- verified: current automated or fixture evidence exists and is named.
- doc-gated: documented policy or boundary exists, but release evidence is not complete.
- blocked: generic status for work that cannot be claimed complete.
- release-blocker: public release cannot claim readiness until this row receives stronger evidence.
- deferred: intentionally not part of the current public claim.

## PRD Evidence

| ID | Status | Evidence | Release Requirement |
| --- | --- | --- | --- |
| `PRD-010` | doc-gated | `docs/security/threat-model.md`, `docs/security/support-handling.md`, `docs/security/support-redaction-checklist.md`, `SECURITY.md`, public issue forms, and `pnpm docs:verify-support-intake` | Broader security tests must still prove secrets do not enter logs, cache, diagnostics, or telemetry. |
| `PRD-012` | verified | `diagnostics/get`, local diagnostics bundle command, `.github/ISSUE_TEMPLATE/`, `docs/security/support-redaction-checklist.md`, public support redaction fixture, and `pnpm docs:verify-support-intake` | Public repository publication still requires final release blocker closure and private vulnerability reporting setup. |
| `PRD-015` | release-blocker | This matrix and M7 release gates | Public product completion requires all P0/P1 rows to have release evidence. |

## SEC Evidence

| ID | Status | Evidence | Release Requirement |
| --- | --- | --- | --- |
| `SEC-001` | verified | VS Code SecretStorage credential controller tests | Document and test hard failure when SecretStorage is unavailable. |
| `SEC-002` | verified | Diagnostics redaction tests, public support redaction fixture, support handling, support redaction checklist, public issue forms, `SECURITY.md`, and `pnpm docs:verify-support-intake` | Keep future diagnostics schemas covered by the redaction fixture before requesting public user evidence. |
| `SEC-003` | verified | Realm-hashed credential key tests | Keep raw realms out of keys and safe args. |
| `SEC-004` | verified | Certificate controller tests and localhost HTTPS DAV fixture | Do not expand claim beyond current fixture until more transport evidence exists. |
| `SEC-005` | verified | Changed-fingerprint controller tests | Add future review/revoke UI evidence before claiming trust management completeness. |
| `SEC-006` | verified | Non-interactive/background auth and certificate tests | Preserve no-background-prompt policy across new transports. |
| `SEC-007` | verified | Workspace Trust manifest/menu/runtime tests | Keep restricted mode behavior aligned with docs. |
| `SEC-008` | verified | Restricted configuration tests | Keep external-tool settings restricted in untrusted workspaces. |
| `SEC-009` | verified | Stdio-only transport implementation and tests | Confirm packaged release opens no IPC sockets. |
| `SEC-010` | verified | JSON-RPC frame, auth wait, flood, and timeout tests | Add fuzz coverage before public readiness. |
| `SEC-011` | verified | M7e Tortoise detector, command-controller, launcher, and manifest tests prove Workspace Trust gating, structured read-only intents, exact `TortoiseProc.exe` executable validation, and `shell: false` process launch. | Mutating Tortoise dialogs, custom tunnel commands, pathfiles, and remote path mapping still need separate evidence. |
| `SEC-012` | release-blocker | M7f isolated install/upgrade/rollback fixture plus M7g isolated VS Code CLI install gate keep fixture and evidence roots under repository `target/` and prove recursive working-copy `.svn` sentinel non-mutation | Signed artifacts, installed-product cleanup, and previous-stable upgrade/rollback still need release evidence. |
| `SEC-013` | release-blocker | M7 release gates plus M7d extension-owned cache clear tests, `subversionr.cacheMigrationReport` evidence, and M7f fixture-local `.svn/wc.db` non-mutation sentinel | Public release still needs install/upgrade/rollback cache privacy evidence across packaged builds and previous-stable installed-product E2E. |
| `SEC-014` | verified | Redaction tests, public support redaction fixture, support handling, support redaction checklist, and public issue forms | Keep new support artifact types behind the same checklist and verifier. |
| `SEC-015` | release-blocker | Deterministic `0.2.4` pre-release VSIX/package evidence, exact pending candidate contract, candidate/historical provenance separation, historical live `0.2.3` custom-predicate attestation and Marketplace publication evidence, vulnerability decisions, and native artifact mapping | Final SBOM/NOTICE/legal and vulnerability approval, reproducible or signed source-to-binary provenance, public-install verification, and artifact signing are not complete. |
| `SEC-016` | release-blocker | Malicious input corpus preflight plus focused protocol/native tests, including the M7l5 source-built `ra_serf` malicious DAV/XML history-log fixture, the M7l6 stateful malicious `svn://` server-response history-log fixture, the M7l7 native remote-protocol fuzz readiness contract, the M7l8 native remote-protocol fuzz target source preflight, and the M7l9 native remote-protocol fixed seed harness smoke | Coverage-guided native remote-protocol fuzzing is not complete. |

## OBS Evidence

| ID | Status | Evidence | Release Requirement |
| --- | --- | --- | --- |
| `OBS-005` | verified | Local diagnostics bundle command, public issue templates, support redaction checklist, and `pnpm docs:verify-support-intake` | Public support can request diagnostics only through the checklist and only after final release blockers close. |
| `OBS-006` | verified | Version report command and diagnostics tests | Keep version fields aligned with packaged release metadata. |
| `OBS-007` | verified | Redaction tests, public support redaction fixture, support handling, support redaction checklist, `pnpm docs:verify-support-intake`, and installed Extension Host redaction report evidence | Keep new diagnostics bundle sections covered by both public support fixtures and installed-product evidence before requesting user bundles. |
| `OBS-008` | doc-gated | No telemetry implementation in M6aa scope | Any future telemetry must be opt-in, localized, and secret-free. |

## MIG Evidence

| ID | Status | Evidence | Release Requirement |
| --- | --- | --- | --- |
| `MIG-008` | release-blocker | M7d protocol v1.20 `cacheSchema`, extension cache schema metadata, delete-and-reconcile cache reset tests, working-copy non-mutation report evidence, and M7f `.svn/wc.db` sentinel hash evidence | Previous-stable installed-product migration E2E is not complete. |
| `MIG-009` | release-blocker | M7 release gates, staged/installed `win32-x64` evidence, M7j2a provenance, M7j3 renderer evidence, M7k2a listing metadata, exact deterministic `0.2.4` pre-release VSIX, and historical live `0.2.3` attestation and Marketplace Gallery state | Signing/provenance trust, public-install verification, and previous-stable upgrade/rollback are not complete. |
| `MIG-010` | release-blocker | M7f synthetic previous/current install, upgrade, and rollback fixture evidence with `workingCopyMutation: "none"` | Upgrade and rollback from a previous stable release artifact are not complete. |
| `MIG-011` | release-blocker | M7d `subversionr.migration.showReport` foundation and `subversionr.cacheMigrationReport` evidence | Full imported-settings and command-behavior migration report evidence is not complete. |
| `MIG-012` | release-blocker | Generated NOTICE evidence, exact pending `0.2.4` candidate contract, historical live `0.2.3` attestation and Marketplace publication evidence, #56 bounded owner exception, vulnerability decisions, and native artifact mapping | Final NOTICE/license and legal review, signed provenance, artifact signing, public-install verification, and final vulnerability approval are not complete. |

## TST Evidence

| ID | Status | Evidence | Release Requirement |
| --- | --- | --- | --- |
| `TST-020` | release-blocker | Malicious input corpus preflight plus existing focused protocol/native tests, including the M7l5 source-built `ra_serf` malicious DAV/XML history-log fixture, the M7l6 stateful malicious `svn://` server-response history-log fixture, the M7l7 native remote-protocol fuzz readiness contract, the M7l8 native remote-protocol fuzz target source preflight, and the M7l9 native remote-protocol fixed seed harness smoke | Security fuzz matrix remains incomplete while coverage-guided native remote-protocol fuzzing remains deferred. |
| `TST-022` | release-blocker | M7 release gates | Migration E2E is not complete. |
| `TST-018` | release-blocker | M7j3 installed Source Control UI E2E gate captures DOM text, accessibility-tree, and nonblank screenshot PNG evidence for the local installed VSIX fixture Source Control view, no-repository welcome, checkout prompts, update revision/depth/sticky-depth/externals prompts, Lock message/Lock mode/Unlock mode prompts, Set Changelist QuickInput, Revert Changelist confirmation, Add to Ignore/`svn:ignore` workflow evidence, Lock/Unlock/`svn:needs-lock` workflow evidence, and operation confirmation modals | Broader keyboard and screen-reader acceptance across non-SCM product surfaces is not complete. |
| `TST-024` | release-blocker | Installed package/workflow/UI evidence, deterministic `0.2.4` pre-release VSIX tests, candidate-versus-historical provenance/publication/Beta-G separation tests, historical successful `0.2.3` attestation and Marketplace publication runs, vulnerability gates, native artifact mapping, and Source Control UI E2E evidence | Public-install verification, previous-stable upgrade/rollback, final vulnerability approval, signed source-to-binary provenance, and artifact signing remain incomplete. |

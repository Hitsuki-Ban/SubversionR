# SubversionR Engineering Handoff And Direction Calibration

> Target repository path: `docs/onboarding/ENGINEERING_HANDOFF.md`
> Review baseline: `main`, after PR #157 was merged (merge commit `784de993`), 2026-06-29. This handoff is calibrated for the Windows `win32-x64` Beta packaging-readiness track after the local workflow closure, installed VSIX evidence, Beta candidate consistency, and security release-evidence reconciliation slices.
> Completion percentages in this document are code-review estimates, not existing project KPIs.

## 1. Project Mission

SubversionR should become a complete, native, high-performance SVN client inside VS Code:

- TypeScript owns VS Code interaction and projection only.
- The Rust sidecar owns status, scheduling, caching, diagnostics, and long-lived state.
- The narrow C ABI owns APR/libsvn lifetime, callbacks, and error conversion.
- libsvn is the single authoritative SVN semantics layer.
- The extension uses only stable VS Code APIs for core functionality; proposed APIs are not required.
- Production functionality must not depend on `svn.exe` or write `.svn/wc.db` directly.
- TortoiseSVN is an optional GUI integration, not a core dependency.

Do not turn the product into an SVN shell with Git semantics. Preserve native SVN concepts such as revisions, changelists, copy lineage, mergeinfo, properties, locks, and sparse depth.

## 2. Current Overall Assessment

The project should currently be classified as:

> Windows Beta candidate for local file-backed `win32-x64` workflows: the native core, Source Control surface, daily local SVN workflows, happy-path installed VSIX evidence, and the Beta state-engine performance floor are established. Beta packaging now has `pnpm release:prepare-beta-candidate:win32-x64` to regenerate same-run candidate VSIX/evidence consistency, generate the artifact bundle manifest, and run the strict verifier against the explicit CI upload allowlist, while installed negative/failure-flow breadth remains active packaging-readiness work. Public release, cross-platform support, and post-Beta merge capabilities are not closed.

| Area | Review Estimate | Current Assessment |
|---|---:|---|
| Architecture foundation | 80% | Correct and worth extending; no rewrite needed |
| Dirty-path status engine | 65% | Targeted status/delta and recovery evidence exist, still first-generation |
| Basic SCM operations | 75% | Daily local edit, commit, update, resolve, checkout, lock, changelist, and branch/switch workflows are usable |
| Complete SVN feature set | 55% | Beta-local workflows are closed; merge/mergeinfo, repository browser, externals editor, relocate/export/import, patch, and upgrade remain gaps |
| History / SVN Lens | 70% | The most complete and differentiated subsystem |
| Auth / security / diagnostics | 65% | Strong foundation, limited real protocol and public product coverage |
| TortoiseSVN integration | 25% | Local read-only log/diff/graph/blame only |
| Cross-platform and public release | 30% | The released win32-x64 VSIX has verified live GitHub attestation evidence; artifact signing/signed provenance, Marketplace, rollback, and the platform matrix remain blocked |
| Overall | 60%-65% for Windows Beta packaging scope | Not yet suitable as public RC or full SVN product completion |

Recent PRs #128-#157 shifted effort back to product closure and Beta packaging readiness: readiness governance, fast PR gates, remote/incoming delta, projection recovery, lifecycle coordination, update revision/depth/externals policy, properties and `svn:ignore`, changelists, lock/unlock, checkout/open URL, branch/tag/switch, installed VSIX workflow evidence, the Beta state-engine floor, same-run Beta candidate consistency, and security release-evidence reconciliation are now aligned for the Windows Beta local workflow claim. Merge, merge preview, and mergeinfo remain explicit post-Beta non-claims.

## 3. Already Done; Do Not Rebuild From Scratch

### Architecture And Native Path

- TypeScript adapter, Rust daemon, C bridge, and bundled libsvn are connected.
- stdio JSON-RPC, major/minor/capability handshake, epoch, and generation already exist.
- libsvn covers status, content, log, blame, and several write operations.
- Workspace Trust, SecretStorage, certificate trust, and diagnostic redaction have a foundation.

### SCM And Status

- Snapshot, targeted refresh, coverage, delta upsert/remove, and full reconcile exist.
- SCM already has Conflicts, Changes, Unversioned, Incoming, Externals, and Ignored groups.
- BASE/HEAD/PREV content, diff, and Quick Diff exist.

### Basic Write Operations

- Add, Remove, Revert, Resolve, Cleanup, and Update.
- Commit Selected, same-repository multi-file commit, and Commit All.
- Operation results include touched paths and reconcile hints.

### History / Lens

- Repository/File/Line History, Blame, and Revision Details.
- Open revision, compare PREV, and compare two revisions.
- File Header Lens, Current-Line Blame, Hover, and optional Symbol Lens.

### Engineering And Security Assets

- win32-x64 native dependency builds, VSIX install verification, SBOM/NOTICE, CVE review, and malicious-input fixtures are comparatively complete.
- Preserve these assets, but do not keep prioritizing them ahead of core product capability expansion.

## 4. Key Current Gaps

### 4.1 Repository Lifecycle Is Not Complete

Discovery currently mostly tries to open workspace roots. Nested working copies and externals are not fully discovered. Required follow-up:

- Map workspace subdirectories upward to their owning working copy.
- Support automatic discovery, multi-root workspaces, and nested working-copy boundaries.
- Lazily load file and directory externals.
- Separate workspace scope from working-copy root.
- Handle moved, disappeared, and reopened working copies.
- Fully represent sparse, switched, and mixed-revision working copies.

### 4.2 Dirty-Path Is Not At The Final Design

The current watcher uses `**/*` from TypeScript/VS Code, and a fixed threshold falls back to full reconcile. Missing work:

- Native Rust watcher, with the VS Code watcher only as a fallback.
- Prefix tree and subtree folding.
- Adaptive planning based on event scale and historical duration.
- Generation supersede and active cancellation.
- Bounded backpressure.
- Network-filesystem polling fallback.
- Independent local, remote, and external scheduling.
- Avoid cloning the entire status `Map` in the daemon for every delta.

### 4.3 The Daemon Is Still A Synchronous RPC Executor

A complete Operation Coordinator is still missing:

- Operation progress/completed/failed notifications and installed cancellation UX evidence.
- Priority queues for foreground writes, local status, history, and remote work.
- Sidecar crash restart, repository reopen, and snapshot retention.
- Stale/partial state.
- Large-content stream handles instead of full Base64 JSON payloads.

Foundations now exist for libsvn cancel callback integration and a bounded sanitized operation journal, but they are not yet a complete operation coordinator.

### 4.4 Remaining SVN Workflow Gaps After Beta Core Closure

Recently closed Beta-local workflows:

- Checkout, automatic open, and local no-repository entry points.
- Rename/Move, Add, Remove, Revert, Resolve, Cleanup, Update, Commit Selected, Commit All, and Delete Unversioned.
- Update to explicit revision, sparse depth, sticky depth, and externals policy.
- Property list/set/delete and `svn:ignore`.
- Changelist set/clear, Source Control grouping, and commit/revert by changelist.
- Lock/unlock plus structured lock and `svn:needs-lock` status projection.
- Branch/tag create and switch.

High-priority remaining workflows:

- Merge, merge preview, and mergeinfo remain post-Beta non-claims.
- Full `svn:externals` editing and validation.
- Revert All, Bulk Resolve, richer conflict choices, and conflict editor flows.
- Patch, Upgrade, Relocate, Export, Import, and Repository Browser.
- Review & Commit, message history, templates, project properties, broader progress, and cancellation evidence.

### 4.5 Release State Is Not At Public Product Standard

- Current coverage is mostly win32-x64.
- HTTPS has controlled fixtures only; that is not broad server support.
- `svn+ssh`, proxy auth, client certificates, Kerberos/NTLM/SASL are not complete.
- Live GitHub artifact attestation publication and verification are recorded for the released `win32-x64` VSIX. Marketplace/public install, artifact signing/signed provenance, previous-stable rollback, and the inconsistent Beta candidate ZIP are not closed.
- `.github/workflows/ci.yml` is currently `workflow_dispatch` only and does not provide automatic PR/push gates.

## 5. Direction Calibration: Recommended Order

### P0 - Keep The Project Fact Source Current

Before continuing feature development:

1. Keep README, roadmap, release gates, public claim matrix, and requirement evidence aligned with the current Beta scope.
2. Keep `Reference/requirements.csv` as specification approval, not implementation completion.
3. Continue using `docs/release/requirements-release-evidence.csv` for P0/P1 implementation evidence, exceptions, and blockers.
4. Preserve lightweight automatic PR CI; heavyweight native/security workflows can remain scheduled or manual.

### P1 - Finish State Engine And Failure Recovery

Prioritize:

- Repository Registry and nested/external discovery.
- Rust watcher plus adaptive dirty planner.
- Operation Coordinator, cancellation, progress, and scheduling isolation.
- Sidecar restart, snapshot retention, and stale indicators.
- Complete separation of local and remote status.
- Large-content streaming.
- 10k/100k/1M working-copy performance gates.

This is the product's main technical path and should outrank additional M7x preflight-only documentation.

### P2 - Finish Post-Beta SVN Workflows

Completed for the Windows Beta local claim: checkout/open URL, changelist, properties/ignore, rename/move, lock/unlock, update-to-revision/sparse depth/externals policy, and branch/tag/switch.

Recommended remaining sequence:

1. Merge, merge preview, and mergeinfo.
2. Full `svn:externals` editor and validation.
3. Revert All, Bulk Resolve, richer conflict choices, and conflict editor flows.
4. Patch.
5. Browser, Relocate, Export, and Import.

### P3 - Improve History, Lens, And Tortoise

- Peg-aware rename/copy history.
- WORKING-to-BASE line mapping and `Uncommitted` lines.
- Server-side history search, copy lineage, and mergeinfo.
- History cache, cancellation, and offline reads.
- Tortoise showcompare, browser, conflict editor, repostatus, and properties.
- Stale plus reconcile after Tortoise write dialogs exit.

### P4 - Cross-Platform And Formal Release

- Linux/macOS x64/arm64.
- WSL, Containers, and Remote SSH.
- Real HTTPS, `svn+ssh`, and proxy/certificate matrices.
- Artifact signing/signed provenance, Marketplace/public install, previous-stable rollback, and self-consistent Beta candidate regeneration.

## 6. Engineering Constraints

All future implementation must follow these constraints:

1. libsvn is the authoritative semantics layer. Do not reimplement working-copy semantics.
2. Production paths do not call the SVN CLI. The CLI may be used only for fixtures and differential oracles.
3. Do not write `.svn/wc.db` directly.
4. Keep the Extension Host lightweight. Do not run full-repository scans, large diffs, XML parsing, or heavy caches there.
5. TortoiseSVN is always optional. Its absence must not create noise or weaken core functionality.
6. Keep local and remote operations separate. Ordinary file changes must not implicitly go online.
7. All long operations must be cancellable; all queues and caches must be bounded.
8. Use SVN terminology. Do not introduce fake staged/push/pull semantics.
9. Do not overstate support scope. A fixture, preflight, or source skeleton is not product support.
10. Every feature must close protocol, native, daemon, VS Code UI, errors, i18n, tests, and reconcile behavior together.

## 7. Recommended Reading Order For New Engineers

1. `README.md`
2. This document
3. `Reference/requirements.csv`
4. `Reference/command_catalog.csv`
5. `Reference/settings_catalog.csv`
6. `Reference/rpc_catalog.csv`
7. `docs/roadmap/README.md`
8. `docs/release/m7-release-readiness-gates.md`
9. `packages/vscode-extension/src/extension.ts`
10. `packages/vscode-extension/src/status/*`
11. `crates/subversionr-daemon/src/state.rs`
12. `crates/subversionr-daemon/src/bridge.rs`
13. `native/svn-bridge/src/subversionr_bridge.c`
14. `.github/workflows/ci.yml`

Code navigation:

```text
User command / VS Code UI
-> RepositoryCommandController or relevant provider
-> Backend*Client
-> JSON-RPC method
-> DaemonState dispatch
-> BridgeApi
-> NativeBridge FFI
-> subversionr_bridge.c
-> libsvn API
-> reconcile hint / status delta
-> SCM projection
```

## 8. Local Baseline Verification

```powershell
pnpm install
pnpm check
pnpm test
pnpm i18n:verify
cargo fmt --all -- --check
cargo test --workspace
pnpm native:test-scripts
pnpm native:verify-sources
```

Windows native path:

```powershell
$env:SUBVERSIONR_VSDEVCMD = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat"
pnpm native:build-deps:all
pnpm native:build-subversion:staged
pnpm native:build-bridge:staged
pnpm native:smoke-bridge:staged
```

When changing product capability, close at least: unit tests, RPC contract, native integration, VS Code surface/E2E, i18n, and state-reconcile tests for success, failure, and cancellation.

## 9. Project Completion Standard

The project cannot be called complete just because architecture, fixtures, or release preflights exist. Formal completion requires at least:

- Every P0/P1 requirement has explicit `implemented + verified` evidence or an approved exception.
- Complete daily SVN workflows work without the CLI or TortoiseSVN.
- Large working copies do not trigger a full scan on ordinary saves.
- Sidecar, watcher, network, and cache failures recover.
- Windows, macOS, Linux, and target Remote environments pass the platform matrix.
- Publicly supported protocol/auth combinations have real E2E coverage.
- Automatic PR CI, performance gates, supply-chain review, and release verification are closed.

## 10. Windows Beta Packaging Track

The next phase should not expand public-release preflights or the Beta feature set. Its purpose is to turn the implemented Windows local SVN workflows into an installable, demonstrable, and regression-tested Beta package.

Recommended PR order:

1. Keep the handoff, roadmap, release gates, public claim matrix, and requirement evidence aligned with the PR #157 Beta packaging fact source and later Beta evidence changes.
2. Extend installed VSIX E2E checkout coverage beyond the covered URL prompt cancellation, pre-existing obstructing target file failure, invalid URL failure, pre-existing local directory success, and pre-existing local directory obstruction tree-conflict paths to repository browser, remote/auth/certificate, and broader checkout failure cases.
3. Keep update follow-up gaps explicit: remote/network failures, auth/certificate update flows, backend failure UX, mixed-revision edge analysis, and load behavior remain outside the local-file Update to Revision happy-path plus revision prompt cancellation evidence.
4. Keep Beta-D evidence current: installed local-file Add to Ignore/`svn:ignore`, Set/Clear Changelist, Commit Changelist, and Revert Changelist happy paths are covered; full property editor UX, `svn:externals` editing, load/cancellation breadth, remote/auth/certificate behavior, and commit template/message-history behavior remain outside that evidence.
5. Keep Branch/Tag create and Switch installed VSIX E2E evidence scoped to the local-file happy path; target browsing, switch-after-copy, broad remote/auth/certificate matrices, repository-browser integration, and switched working-copy edge/load behavior remain outside that evidence. Local-file Lock/Unlock/`svn:needs-lock` happy-path evidence is covered, while broad remote lock-server matrices, cancellation UX, break/steal policy breadth, and load-scale lock behavior remain outside that evidence.
6. Keep the Beta state-engine performance gate current: `pnpm release:test-state-engine-beta-performance:win32-x64` records that single-file save does not trigger full scan, watcher/event burst stays bounded, nested working copies and externals do not pollute parent providers, dirty-generation supersede does not allow stale results to win, sidecar restart reopens or marks stale explicitly, and a 10k local working-copy fixture stays within the accepted baseline. Native watcher production, adaptive cost feedback, idle CPU measurement, 100k/1M scale, and default background remote polling remain outside that Beta floor.
7. Keep the Beta candidate consistency gate current: `pnpm release:verify-beta-candidate:win32-x64` must run after VSIX package, native artifact map, provenance, publication gaps, installed VSIX gates, install rollback fixture, state-engine Beta performance evidence, `pnpm release:generate-beta-artifact-bundle-manifest:win32-x64`, and the explicit CI upload allowlist have been regenerated for the same candidate. The manifest writes `subversionr.release.beta-artifact-bundle-manifest.win32-x64.v1` and binds the current VSIX, SBOM, NOTICE, release evidence JSONs, and installed UI artifacts; the final gate writes `subversionr.release.beta-candidate-consistency.win32-x64.v1`, requires the provenance/publication chain to record the verified live GitHub attestation for the current VSIX, rejects stale VSIX hashes, stale input evidence, stale artifact bundle manifest payload hashes, and drift from the `actions/upload-artifact@v7` `subversionr-win32-x64-beta-candidate` upload contract, and keeps Marketplace/public install, artifact signing/signed provenance, previous-stable rollback, broad remote/auth, and public readiness as non-claims. The published candidate ZIP remains blocked as inconsistent.

Each PR should keep Cloudflare PR Fast and readiness smoke green, record local Windows validation in the PR body while GitHub Actions Windows runner coverage is unavailable, and avoid claiming public release, Marketplace, artifact signing/signed provenance, previous-stable rollback, broad remote/auth, cross-platform, coverage-guided fuzzing, merge, merge preview, or mergeinfo support.

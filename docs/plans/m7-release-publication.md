# M7 Release, Packaging, Migration, and Public Publication Plan

## Goal

Turn the M6 security and native foundations into a product-grade public release path: optional TortoiseSVN adapter, migration, platform packaging, performance gates, release security evidence, and public repository preparation.

## M7a Implemented Slice

The first M7 slice establishes release-readiness gates without claiming that public packaging is complete:

- `SECURITY.md` defines the private vulnerability reporting policy, supported-version placeholder, sensitive-material handling, and diagnostics evidence rules.
- `docs/release/m7-release-readiness-gates.md` defines blocking release gates for channels, platform packaging, supply chain, migration/rollback, security, support, and public non-claims.
- `docs/release/security-evidence-matrix.md` maps `PRD-010`, `PRD-012`, `PRD-015`, `SEC-001` through `SEC-016`, `OBS-005` through `OBS-008`, `MIG-008` through `MIG-012`, and `TST-020`, `TST-022`, `TST-024` to current evidence status.
- `docs/release/public-claim-matrix.md` separates claimed, fixture-only, deferred, and unsupported repository transports, auth modes, and optional external integrations.
- `pnpm release:verify-readiness` verifies that the release-readiness documents, trace IDs, required blocker statuses, and public claim boundaries remain present.
- Windows CI runs the release readiness check after public security documentation checks and before tests.

This slice intentionally does not build or sign VSIX artifacts, generate a final SBOM, complete NOTICE publication, perform CVE review, enable public vulnerability reporting in GitHub settings, implement TortoiseSVN execution, enable standard SVN credential-store persistence, or claim arbitrary HTTPS SVN server support.

## M7a Gates

- `pnpm release:verify-readiness` must pass.
- The verifier must fail when `SECURITY.md`, release gate docs, security evidence matrix, public claim matrix, or this plan is missing.
- The verifier must require release-blocker status for `SEC-015`, `MIG-009`, `MIG-010`, and `TST-024` until stronger release evidence exists.
- The verifier must require public non-claims for arbitrary HTTPS SVN servers, `svn+ssh`, proxy auth, client certificates, Kerberos/NTLM, SASL, standard SVN credential-store persistence, and TortoiseSVN execution.

## M7b Implemented Slice

The second M7 slice establishes the first platform packaging layout gate for `win32-x64` without publishing a VSIX:

- `scripts/release/stage-vscode-package-layout.ps1` stages a VS Code extension package root under `target/` for the exact VS Code platform target `win32-x64`.
- The staged layout matches the runtime resolver contract: `resources/backend/win32-x64/subversionr-daemon.exe` and `resources/backend/win32-x64/subversionr_svn_bridge.dll`.
- The staging script requires explicit `ExtensionRoot`, `DaemonExe`, `BridgeRuntimeDirectory`, `SourceLockPath`, and `OutputRoot` inputs. It does not probe `PATH`, system `svn`, TortoiseSVN, registry locations, or random libsvn directories.
- The staged backend resources include the release sidecar executable, the bridge DLL, required private libsvn/APR/OpenSSL DLL runtime dependencies, and APR iconv converter modules from the bridge runtime directory.
- Runtime staging uses an explicit allowlist for top-level native dependencies. Stale or unrelated DLLs in the bridge runtime directory are not copied or authorized by the manifest.
- SVN CLI executables, including `svn.exe`, `svnadmin.exe`, `svnserve.exe`, `svnversion.exe`, `svnlook.exe`, `svnsync.exe`, `svnrdump.exe`, and related fixture/build tools, are not copied into the staged VS Code package.
- `subversionr-backend-package-manifest.json` records schema `subversionr.vscode.backend-package.win32-x64.v1`, layout kind `staged-vsix-layout`, target `win32-x64`, architecture `x64`, configuration `Release`, extension identity, relative artifact paths, SHA256 hashes, sizes, source-lock metadata, and non-packaged CLI tools.
- `scripts/release/verify-vscode-package-layout.ps1` validates the staged layout, manifest target/schema, normalized relative artifact paths, artifact hashes/sizes, exact sidecar/bridge paths, required private libsvn/APR/OpenSSL/iconv native dependencies, AMD64 PE machine headers for staged executables and native modules, and forbidden CLI tools anywhere under the staged package root.
- `pnpm release:test-scripts` covers the staging and verification scripts with synthetic PE artifacts, including negative checks for hash mismatch, missing sidecar, missing native dependency, forbidden SVN CLI tools, and unexpected backend resource files.
- Windows CI builds the release sidecar, builds and smokes the native bridge, stages the `win32-x64` package layout, and verifies it.

This slice intentionally does not run `vsce package`, produce a `.vsix`, bundle extension JavaScript, sign binaries, generate SBOM/NOTICE, complete CVE review, install/upgrade/rollback a VSIX, or add macOS/Linux/ARM64 package targets.

## M7b Gates

- `pnpm release:test-scripts` must pass.
- `pnpm release:stage-vscode:win32-x64` must run after the release sidecar and native bridge runtime are built.
- `pnpm release:verify-vscode:win32-x64` must pass against the staged layout.
- CI must keep `MIG-009`, `MIG-010`, and `TST-024` as release blockers until real package creation, installation, upgrade, and rollback gates exist.

## M7c Implemented Slice

The third M7 slice establishes generated supply-chain evidence without closing the full public-release legal or security review:

- `scripts/release/generate-source-sbom.ps1` generates a CycloneDX 1.6 JSON SBOM under `target/release-evidence/` from explicit inputs: `native/sources.lock.json`, the VS Code extension manifest, `pnpm-lock.yaml`, the Rust workspace manifest, `Cargo.lock`, and the C bridge CMake project.
- The generated SBOM covers the SubversionR root component, the `svn-r` VS Code extension, Rust workspace crates, the `subversionr_svn_bridge` C bridge, resolved pnpm lockfile components, resolved Cargo lockfile components, and locked native source dependencies.
- Native source components preserve source-lock versions, SPDX license expressions, license URLs, distribution URLs, SHA-512 hashes, optional SHA-256/SHA3-256 hashes, and upstream signature/key references where available.
- `scripts/release/generate-third-party-notice.ps1` generates `THIRD-PARTY-NOTICES.md` evidence under `target/release-evidence/`, separating internal MIT components, locked native sources, and lockfile dependency evidence with unresolved license-review status where lockfiles do not provide license metadata.
- `scripts/release/verify-release-evidence.ps1` verifies that generated SBOM and NOTICE evidence still match the source lock, extension manifest, pnpm lockfile, Rust workspace manifests, Cargo lockfile, and C bridge CMake project. Missing source-lock license metadata, missing lockfile integrity/checksum metadata, missing SBOM components, missing NOTICE entries, or unexpected SBOM components fail fast.
- `pnpm release:test-evidence-scripts` covers generation and verification with fixture source locks, including negative checks for missing SBOM components and incomplete source-lock license metadata.
- Windows CI runs the M7c evidence script tests, generates the source SBOM, generates third-party notice evidence, and verifies both before the main TypeScript, Rust, native, and packaging gates.

This slice intentionally does not perform final legal review, publish full third-party license text bundles, run CVE automation, sign binaries, create release provenance attestations, trust-anchor generated manifests, produce a `.vsix`, or claim Marketplace/public release readiness.

## M7c Gates

- `pnpm release:test-evidence-scripts` must pass.
- `pnpm release:generate-source-sbom`, `pnpm release:generate-third-party-notice`, and `pnpm release:verify-evidence` must pass against the current repository inputs.
- CI must keep `SEC-015` and `MIG-012` as release blockers until final SBOM review, NOTICE/license text publication, CVE review, signing, and provenance gates exist.

## M7d Implemented Slice

The fourth M7 slice establishes a versioned cache schema and rollback-report foundation without claiming release install/upgrade/rollback completion:

- Protocol v1.20 includes `cacheSchema` in both `initialize` and `diagnostics/get` responses. The current schema is `subversionr.cache.v1`, version `1`, with rollback policy `delete-and-reconcile`.
- The VS Code extension sends an explicit absolute `cacheRoot` to the sidecar during `initialize`. Missing or non-absolute cache roots fail fast before process spawn.
- The extension rejects unsupported backend cache schemas during startup instead of accepting unknown cache layouts.
- `CacheLifecycleService` stores the current cache schema metadata in VS Code workspace state and resets only extension-owned workspace/global cache roots when metadata is stale or from a future schema.
- Cache reset reports are stored as `subversionr.cacheMigrationReport` with `workingCopyMutation: "none"` and trace IDs `MIG-008`, `MIG-010`, `MIG-011`, and `SEC-013`.
- `subversionr.cache.clear` deletes extension-owned cache roots idempotently and reports that SVN working copies were not modified.
- `subversionr.migration.showReport` opens the last cache migration report through the readonly diagnostics document provider.
- English, Japanese, and Chinese localization exists for the new cache commands, startup errors, and migration report UI.

This slice intentionally does not implement VSIX install/upgrade/rollback fixtures, import settings from a legacy extension, mutate `.svn/wc.db`, migrate repository metadata across stable releases, preserve old cache formats, or close the full migration E2E gate.

## M7d Gates

- `pnpm --filter svn-r test -- cacheLifecycleService.test.ts cacheCommandController.test.ts backendProcess.test.ts backendConfiguration.test.ts diagnosticsReportService.test.ts extensionManifest.test.ts` must pass.
- `cargo test -p subversionr-protocol --test protocol_contract` must pass with protocol v1.20 cache schema assertions.
- `cargo test -p subversionr-daemon` must pass with initialize and diagnostics cache schema assertions.
- `pnpm release:verify-readiness` must keep `SEC-013`, `MIG-008`, and `MIG-011` as partial M7d evidence rows, while `MIG-010`, `TST-024`, previous-stable upgrade/rollback, and full imported-settings/command-behavior migration reporting remain release blockers.

## M7e Implemented Slice

The fifth M7 slice implements the first optional TortoiseSVN GUI handoff without changing core SVN semantics:

- The VS Code extension detects `TortoiseProc.exe` only for the optional Tortoise capability. Core SubversionR workflows continue to use the packaged Rust sidecar and source-built `libsvn`.
- Detection runs behind Workspace Trust and uses the documented order from the reference design: explicit `subversionr.tortoise.executablePath`, Windows registry App Paths, common TortoiseSVN install directories, then `PATH`.
- An explicitly configured executable path must be a Windows drive or UNC absolute path with no dot segments, must be named `TortoiseProc.exe`, and must exist. Invalid explicit configuration fails fast instead of silently falling back to another source.
- Missing TortoiseSVN reports capability unavailable, hides contributed Tortoise menus through `subversionr.tortoiseAvailable`, and makes direct Tortoise command invocations return without a missing-tool warning; it does not break repository open/status/history/core operations.
- The launch adapter maps structured read-only intents to allowlisted `TortoiseProc.exe` arguments for `log`, `diff`, `revisiongraph`, and `blame`.
- Launch uses a process argument array with `shell: false`, Windows drive/UNC target-path validation, dot-segment rejection, no command-line string concatenation, no `tsvncmd:` URL handler, no `windowsVerbatimArguments`, and no output/log-message switches.
- Tortoise commands are blocked in untrusted workspaces before settings are read or any process spawn is attempted. Invalid direct command targets and invalid configured executable paths still fail fast.
- English, Japanese, and Chinese localization exists for the new `subversionr.tortoise.*` command titles and runtime failure messages.

This slice intentionally does not implement Tortoise write dialogs, Repository Browser, `showcompare`, multi-path UTF-16 pathfiles, `TortoiseMerge.exe`, remote-to-local path mapping, default diff/merge tool replacement, Tortoise project-property parsing, installed VSIX E2E coverage, or post-Tortoise mutation reconcile flows.

## M7e Gates

- `pnpm --filter svn-r test -- tortoiseDetector.test.ts tortoiseLauncher.test.ts tortoiseCommandController.test.ts extensionManifest.test.ts` must pass.
- `pnpm --filter svn-r check` must pass with the new Tortoise TypeScript modules.
- `pnpm i18n:verify` must pass after adding the Tortoise command titles and runtime messages.
- `pnpm release:verify-readiness` must keep the public TortoiseSVN claim deferred until write-dialog reconcile, remote policy, install/E2E, and release packaging evidence exist.

## M7f Implemented Slice

The sixth M7 slice adds a release install/upgrade/rollback CI fixture without claiming real VSIX installation or public release readiness:

- `scripts/release/test-vscode-install-rollback-fixture.ps1` verifies the current `win32-x64` staged package layout through the existing package-layout verifier before any fixture install step.
- The fixture creates an isolated VS Code-style `extensions/` directory under `target/` and installs only package directory copies into publisher-qualified directories such as `hitsuki-ban.subversionr-0.2.0`.
- The synthetic previous package is derived from the current verified layout with only the explicit version changed to `0.0.0-m7f.fixture`; it is not treated as a stable released version.
- Fresh install, upgrade from the synthetic previous package, and rollback back to the synthetic previous package each require exactly one active SubversionR extension directory.
- The fixture writes `target/release-evidence/subversionr-install-rollback-fixture-win32-x64.json` with trace IDs `MIG-009`, `MIG-010`, and `TST-024`, `publicReadinessClaim: false`, and `workingCopyMutation: "none"` for every phase.
- A fixture-local `.svn/wc.db` sentinel is hashed before and after install/upgrade/rollback to prove that this package-flow gate does not mutate SVN working-copy metadata.
- Fixture root and evidence output must resolve inside the repository `target/` directory. Missing package roots, target mismatch, wrong extension identity, tampered manifest artifacts, same previous/current version, or package-layout verifier failures stop the gate.
- Windows CI runs script-level fixture tests before evidence generation and runs the current staged package install/upgrade/rollback fixture immediately after verifying the `win32-x64` package layout.

This slice intentionally does not run `vsce package`, produce or install a `.vsix`, call `code --install-extension`, mutate real VS Code user data, use Marketplace services, sign artifacts, verify Marketplace signatures, test update from a previous stable release, import legacy settings, or close installed-product VS Code E2E coverage.

## M7f Gates

- `pnpm release:test-install-rollback-fixture` must pass.
- `pnpm release:install-rollback:win32-x64` must run after `pnpm release:verify-vscode:win32-x64`.
- `pnpm release:verify-readiness` must continue to keep `MIG-009`, `MIG-010`, and `TST-024` as release blockers until a real VSIX package, install through VS Code CLI or Marketplace flow, previous-stable upgrade/rollback, signing/provenance, and installed-product E2E evidence exist.

## M7g Implemented Slice

The seventh M7 slice adds the first real VSIX package and VS Code CLI install gate for `win32-x64` without claiming Marketplace/public release readiness:

- `packages/vscode-extension/tsconfig.build.json` emits release JavaScript from `src/` into `packages/vscode-extension/dist/` and excludes tests from the release build.
- `@vscode/vsce` is pinned in the root workspace and used through `pnpm exec vsce`; pnpm build-script approvals explicitly keep signing-helper package builds disabled because signing is not part of this slice.
- `scripts/release/package-vscode-vsix.ps1` packages the verified staged `win32-x64` layout with `vsce package --target win32-x64 --ignore-other-target-folders --no-dependencies`.
- VSIX packaging fails fast when the compiled `dist/extension.js` entrypoint is missing, compiled test artifacts are present, required backend resources are absent, source/tests/node_modules leak into the archive, or SVN CLI fixture tools appear anywhere in the archive.
- VSIX package evidence is written as `subversionr.release.vsix-package.win32-x64.v1` with `publicReadinessClaim: false`, the extension identity/version, VSIX path, size, SHA256, compiled entrypoint hash continuity, generated `.vscodeignore` hash, and trace IDs `SEC-015` and `MIG-009`.
- `scripts/release/test-vscode-cli-install-vsix.ps1` requires an explicit absolute `code.cmd` or `code.exe` path, rejects unresolved placeholders, uses isolated `--user-data-dir` and `--extensions-dir` roots under `target/`, verifies the VSIX manifest `Identity TargetPlatform`, records the Code CLI version/hash, installs through `code --install-extension`, checks `--list-extensions --show-versions`, proves installed `dist/extension.js` matches the VSIX entry hash, and hashes a fixture-local `.svn` tree before and after install.
- VS Code CLI install evidence is written as `subversionr.release.vsix-cli-install.win32-x64.v1` with `publicReadinessClaim: false`, installed extension identity/version, isolated roots, installed extension list, the installed VSIX path/size/target/SHA256, VSIX-to-installed entrypoint hash continuity, unchanged working-copy `.svn` tree sentinel, and trace IDs `MIG-009` and `TST-024`.
- Windows CI runs the VSIX script tests, builds extension JavaScript, packages the real `win32-x64` VSIX, downloads the official latest stable Windows x64 VS Code ZIP to locate `bin/code.cmd`, and runs the isolated CLI install gate.

This slice intentionally does not publish to Marketplace, sign the VSIX or native binaries, produce provenance attestations, test update from a previous stable release artifact, exercise installed VS Code Extension Host activation, add macOS/Linux/ARM64 targets, or close final SBOM/NOTICE/CVE review.

## M7g Gates

- `pnpm release:test-vsix-scripts` must pass.
- `pnpm release:build-vscode-extension` must run before packaging.
- `pnpm release:package-vsix:win32-x64` must run after `pnpm release:verify-vscode:win32-x64`.
- `pnpm release:test-vsix-cli-install:win32-x64` must receive an explicit `SUBVERSIONR_CODE_CLI` path and must run against the generated VSIX.
- `pnpm release:verify-readiness` must continue to keep `SEC-015`, `MIG-009`, `MIG-010`, and `TST-024` as release blockers until signing/provenance, previous-stable upgrade/rollback, Marketplace/public install, installed Extension Host E2E, final SBOM/NOTICE review, and CVE review are complete.

## M7h Implemented Slice

The eighth M7 slice adds the first installed-product Extension Host command smoke gate without claiming full installed workflow E2E:

- `scripts/release/test-vscode-installed-extension-host.ps1` installs the generated `win32-x64` VSIX into an isolated VS Code `extensions/` directory under `target/`.
- The gate creates a separate test harness extension only as the `--extensionDevelopmentPath` test runner. SubversionR itself must be loaded from the installed VSIX package root; loading SubversionR from the harness or repository source path fails the gate.
- The harness runs inside a real VS Code Extension Host through `--extensionTestsPath`, resolves `vscode.extensions.getExtension("hitsuki-ban.subversionr")`, verifies SubversionR is initially inactive, executes `subversionr.diagnostics.versionReport`, verifies SubversionR becomes active, and parses the opened readonly `subversionr.versionReport` document.
- The version report smoke path does not require a real SVN working copy. Backend startup may be `initialized` or `unavailable`, but the report must preserve the stable `subversionr.versionReport` shape and installed extension version.
- The gate records the explicit Code CLI path/version/hash, VSIX hash, isolated user-data/extensions/workspace/harness roots, installed extension list, installed package root, Extension Host path, invoked command, activation state transition, parsed version report, recursive `.svn` sentinel hash non-mutation, and trace IDs `MIG-009` and `TST-024`.
- Script-level fixture tests cover the M7h evidence schema, root package scripts, CI wiring, unresolved `SUBVERSIONR_CODE_CLI` rejection, and fixture-root containment.
- Windows CI runs the installed Extension Host script tests and then runs the real installed VSIX Extension Host version-report gate after VSIX packaging and CLI installation.

This slice intentionally does not require successful Rust sidecar initialization, open a real SVN working copy, exercise Source Control UI, prove installed core workflow E2E, sign artifacts, publish provenance, install through Marketplace, or test upgrade/rollback from a previous stable release artifact.

## M7h Gates

- `pnpm release:test-installed-extension-host-scripts` must pass.
- `pnpm release:test-installed-extension-host:win32-x64` must receive an explicit `SUBVERSIONR_CODE_CLI` path and must run against the generated VSIX after `pnpm release:package-vsix:win32-x64`.
- `pnpm release:verify-readiness` must continue to keep `SEC-015`, `MIG-009`, `MIG-010`, and `TST-024` as release blockers until signing/provenance, previous-stable upgrade/rollback, Marketplace/public install, installed core workflow E2E, final SBOM/NOTICE review, and CVE review are complete.

## M7i Implemented Slice

The ninth M7 slice adds the first sidecar-backed installed-product core workflow gate for `win32-x64` without claiming public release readiness:

- Organic extension activation awaits the initial repository reconciliation before completing, so `extension.isActive` cannot race ahead of workspace repository auto-open. `subversionr.diagnostics.installedCoreWorkflowReport` is a hidden release diagnostics command. It requires organic activation to have already opened the explicit absolute working-copy path, reuses that owned session without closing it, requires a matching SCM projection, and returns stable evidence for repository identity, session source, status snapshot, and SCM projection groups.
- `scripts/release/test-vscode-installed-core-workflow.ps1` creates a local file-backed SVN repository and working copy with the source-built Apache Subversion 1.14.5 fixture tools from `.cache/native/stage/subversion-win-x64/bin`. The generated VSIX remains the product under test and does not package or use `svn.exe`/`svnadmin.exe`.
- The fixture commits `src/tracked.txt`, checks out a real working copy, modifies the tracked file, adds an unversioned `scratch.txt`, and opens that working copy as the VS Code workspace.
- The fixture uses dedicated SVN CLI config and fixture-local `APPDATA/Subversion` roots so the installed VSIX and sidecar do not inherit the developer or CI user's Subversion runtime configuration.
- The installed Extension Host harness runs from a separate test extension only as the `--extensionDevelopmentPath` runner. SubversionR must load from the isolated installed VSIX package root.
- The harness executes `subversionr.diagnostics.installedCoreWorkflowReport`, requires backend open/status/projection plus organic-session reuse/preservation evidence, asserts SCM projection resources for the modified tracked file and unversioned file, then executes `subversionr.diagnostics.versionReport` and requires backend status `initialized`, libsvn `1.14.5`, and repository/status/real-bridge capabilities.
- Evidence is written as `subversionr.release.installed-core-workflow.win32-x64.v2` with `publicReadinessClaim: false`, Code CLI hash/version, VSIX hash/target, source-built fixture tool hashes/versions, isolated roots, organic-session reuse/preservation proof, workflow report, version report, explicit non-claims, and trace IDs `MIG-009` and `TST-024`.
- Script-level fixture tests cover the M7i evidence schema, root package scripts, CI wiring, fake VSIX/fake Code/fake source-built SVN tools, unresolved Code/SVN placeholders, fixture-root containment, target-platform mismatch, non-1.14.5 SVN tools, and Extension Host timeout handling.
- Windows CI runs the installed core workflow script tests and then runs the real installed VSIX core workflow gate after VSIX packaging, CLI installation, and the M7h installed Extension Host version-report gate.

This slice intentionally does not publish to Marketplace, sign artifacts, publish provenance, test upgrade/rollback from a previous stable release artifact, exercise VS Code Source Control UI pixels, cover svnserve/HTTP/HTTPS/auth/certificate flows, add macOS/Linux/ARM64 targets, or close final SBOM/NOTICE/CVE review.

## M7i Gates

- `pnpm release:test-installed-core-workflow-scripts` must pass.
- `pnpm release:test-installed-core-workflow:win32-x64` must receive explicit `SUBVERSIONR_CODE_CLI` and source-built Apache Subversion 1.14.5 fixture tools, and must run against the generated VSIX after `pnpm release:package-vsix:win32-x64`.
- `pnpm release:verify-readiness` must continue to keep `SEC-015`, `MIG-009`, `MIG-010`, and `TST-024` as release blockers until artifact signing/signed provenance, previous-stable upgrade/rollback, Marketplace/public install, final SBOM/NOTICE review, and CVE review are complete.

## M7j1 Implemented Slice

The first M7j slice adds installed-product Source Control surface evidence for `win32-x64` without claiming DOM, accessibility-tree, or pixel UI E2E readiness:

- `subversionr.diagnostics.installedSourceControlSurfaceReport` is a hidden release diagnostics command. It opens an explicit absolute working-copy path, records whether the request was the working-copy root or a subdirectory, requires the matching SCM projection, captures the live VS Code `SourceControl` groups/resource states produced by the installed extension, and closes the repository before returning.
- `VscodeSourceControlPresenter.snapshotRepository` records the SourceControl id-bound repository state, generation, count, commit-input command, group context values, and resource context values without exposing user-facing prose from Rust/backend errors.
- `scripts/release/test-vscode-installed-source-control-surface.ps1` creates the same source-built Apache Subversion 1.14.5 local fixture shape as M7i, installs the generated VSIX into isolated VS Code roots, runs the installed VSIX under fixture-local `APPDATA/Subversion`, and executes the hidden Source Control surface report command in a real Extension Host for both the working-copy root and `wc/src`.
- The harness asserts that the installed VSIX reports `changes/src/tracked.txt` with `subversionr.changedFile.baseDiffable`, `unversioned/scratch.txt` with `subversionr.unversioned`, SourceControl count `1` under the default unversioned-count policy, commit input command `subversionr.commitAll`, initialized backend status, libsvn `1.14.5`, repository/status/real-bridge capabilities, and subdirectory-open provider resolution from `wc/src` back to the parent working-copy root.
- Evidence is written as `subversionr.release.installed-source-control-surface.win32-x64.v1` with `publicReadinessClaim: false`, Code CLI hash/version, VSIX hash/target, source-built fixture tool hashes/versions, isolated roots, root Source Control surface report, subdirectory-open Source Control surface report, version report, explicit non-claims, and trace IDs `REP-001`, `MIG-009`, and `TST-024`.
- Script-level fixture tests cover the M7j1 evidence schema, root package scripts, CI wiring, fake VSIX/fake Code/fake source-built SVN tools, root and subdirectory-open Source Control surface reports, unresolved Code/SVN placeholders, fixture-root containment, target-platform mismatch, non-1.14.5 SVN tools, and Extension Host timeout handling.
- Windows CI runs the installed Source Control surface script tests and then runs the real installed VSIX Source Control surface gate after VSIX packaging, CLI installation, M7h version-report smoke, and M7i installed core workflow.

This slice intentionally does not publish to Marketplace, sign artifacts, publish provenance, test upgrade/rollback from a previous stable release artifact, assert VS Code DOM/accessibility-tree/pixel Source Control UI state, cover svnserve/HTTP/HTTPS/auth/certificate flows, add macOS/Linux/ARM64 targets, or close final SBOM/NOTICE/CVE review.

## M7j1 Gates

- `pnpm release:test-installed-source-control-surface-scripts` must pass.
- `pnpm release:test-installed-source-control-surface:win32-x64` must receive explicit `SUBVERSIONR_CODE_CLI` and source-built Apache Subversion 1.14.5 fixture tools, and must run against the generated VSIX after `pnpm release:package-vsix:win32-x64`.
- `pnpm release:verify-readiness` must continue to keep `SEC-015`, `MIG-009`, `MIG-010`, and `TST-024` as release blockers until signing/provenance, previous-stable upgrade/rollback, Marketplace/public install, final SBOM/NOTICE review, and CVE review are complete.

## M7j2a Implemented Slice

The second M7j slice adds unsigned local provenance and Marketplace metadata preflight evidence. M7j2b later supplies live GitHub attestation publication and verification; signing, Marketplace publication/public install, and previous-stable rollback remain non-claims:

- `CHANGELOG.md` and `SUPPORT.md` provide local Marketplace/support metadata inputs for future public publication. Security reports still route through `SECURITY.md`, and support instructions prohibit secrets, credentials, private repository URLs, cookies, certificate private keys, and sensitive working-copy data in public reports.
- `scripts/release/package-vscode-vsix.ps1` now requires `CHANGELOG.md` and `SUPPORT.md`, packages them into the VSIX, and records their SHA256 hashes in VSIX package evidence.
- `scripts/release/generate-release-provenance.ps1` generates `target/release-evidence/subversionr-marketplace-provenance-preflight-win32-x64.json` with schema `subversionr.release.marketplace-provenance-preflight.win32-x64.v1`.
- The evidence binds the exact VSIX bytes, VSIX package evidence, backend package manifest, extension/root package manifests, README, LICENSE, CHANGELOG, SUPPORT, source lock, pnpm lock, Cargo lock, generated SBOM, and generated NOTICE by SHA256.
- The evidence records the current git commit, branch, dirty-working-tree state, and explicitly sets `remoteUrlRecorded: false` so private repository URLs are not copied into release evidence.
- The Marketplace metadata preflight validates required package fields for `hitsuki-ban.subversionr`, VS Code engine range, categories, compiled entrypoint, README, and LICENSE while keeping `publicationReady: false`.
- The evidence keeps signing `unsigned`, records the hash-bound M7j2b artifact attestation as `verified`, keeps Marketplace publication `not-published`, previous-stable rollback `not-proven`, and `publicReadinessClaim: false`.
- `scripts/release/verify-release-provenance.ps1` re-hashes the VSIX, upstream evidence, manifests, locks, SBOM, NOTICE, and docs from the generated evidence and fails on byte drift, missing non-claims, target/schema mismatch, or accidental public-readiness claims.
- Script-level fixture tests cover generation, verification, VSIX byte drift, output-root containment, upstream VSIX evidence overclaim rejection, extension identity drift, missing CHANGELOG, required non-claims, root package scripts, CI wiring, and VSIX inclusion of CHANGELOG/SUPPORT metadata.
- Windows CI runs the provenance script tests and then generates and verifies the real `win32-x64` provenance preflight evidence after VSIX packaging.
- The provenance preflight has exactly two explicit modes. `candidate-seal` (the script default and the local Beta candidate flow) seals a frozen candidate: it requires the just-built VSIX bytes to equal the `docs/release/github-attestation-candidate-contract.win32-x64.json` subject name, size, and SHA256 exactly. `continuous-validation` keeps every other gate on the current snapshot — including the pending contract status, `publicReadinessClaim=false`, and `subject.preReleaseProperty=true` self-integrity asserts — but does not assert frozen contract subject byte equality, so post-release source changes do not fail scheduled full `main` CI. The evidence records the top-level `mode` and `candidateAttestation.subjectComparison` (`asserted-exact-match` vs `not-asserted-continuous-validation`), and `verify-release-provenance.ps1` requires them to be consistent and to match an optional `-ExpectedMode`.
- Windows full `main` CI computes the mode once from the `candidate_seal` `workflow_dispatch` input: scheduled runs and default dispatches pass `-Mode continuous-validation` and `-ExpectedMode continuous-validation`; an explicit `candidate_seal=true` dispatch passes `candidate-seal` for frozen exact-byte sealing.
- Continuous validation still runs the installed VSIX and native integration gates, but it does not generate the Beta artifact bundle manifest, run the Beta candidate consistency verifier, or upload `subversionr-win32-x64-beta-candidate`. Those three candidate-only steps share the explicit `candidate-seal` condition. The bundle generator and consistency verifier independently require provenance `mode=candidate-seal` plus `candidateAttestation.subjectComparison=asserted-exact-match`, so direct invocation cannot label an unsealed snapshot as a candidate.

This slice remains unsigned and does not by itself publish a GitHub artifact attestation; M7j2b supplies the separately verified live GitHub attestation evidence. It does not publish to Marketplace, install from Marketplace, prove previous-stable upgrade/rollback, complete final SBOM/NOTICE legal review, complete CVE review, or close public release readiness.

## M7j2a Gates

- `pnpm release:test-provenance-scripts` must pass.
- `pnpm release:generate-provenance:win32-x64` must run after `pnpm release:package-vsix:win32-x64`, `pnpm release:generate-source-sbom`, `pnpm release:generate-third-party-notice`, and `pnpm release:verify-evidence`.
- `pnpm release:verify-provenance:win32-x64` must pass against the generated provenance preflight evidence.
- `pnpm release:generate-provenance:win32-x64` must default to `candidate-seal` so no invocation silently weakens frozen exact-byte contract matching, and `continuous-validation` must be selected only through the explicit `-Mode` parameter that scheduled/default-dispatch full `main` CI passes.
- `pnpm release:verify-provenance:win32-x64` must reject a recorded mode outside the two documented values, a `subjectComparison` inconsistent with the recorded mode, and a recorded mode that differs from an explicit `-ExpectedMode`.
- `pnpm release:verify-readiness` must continue to keep `SEC-015`, `MIG-009`, `MIG-010`, `MIG-012`, and `TST-024` as release blockers until signing, Marketplace/public install, previous-stable upgrade/rollback, final SBOM/NOTICE review, and CVE review are complete.

## M7j2b Implemented Slice

The third M7j slice publishes and verifies a post-release GitHub artifact attestation for the exact released `win32-x64` VSIX while preserving the source-controlled subject and verification contract:

- `.github/workflows/attest-release-vsix.yml` is an explicit `workflow_dispatch` workflow. It downloads the release asset named by `docs/release/github-attestation-contract.win32-x64.json`, verifies its name, size, and SHA256, generates the custom predicate defined by `docs/release/post-release-asset-verification-predicate.v1.schema.json`, publishes it with the SHA-pinned `actions/attest` action, verifies the exact output bundle with pinned signer/source ref and digest constraints, and uploads the predicate, bundle, and verification records.
- `docs/release/github-attestation-evidence.win32-x64.json` records the successful `main` workflow run `https://github.com/Hitsuki-Ban/SubversionR/actions/runs/29104476735`, attestation `https://github.com/Hitsuki-Ban/SubversionR/attestations/34774737`, exact source-controlled `docs/release/github-attestation-bundle.win32-x64.json` and `docs/release/github-attestation-verification.win32-x64.json` bytes, their SHA256 values, the exact released VSIX subject, `refs/heads/main` signer/source refs and digests, predicate type, and self-hosted-runner denial policy. The earlier branch-anchored run `29089455425` and attestation `34738487` are superseded.
- `scripts/release/generate-release-provenance.ps1` requires the source-controlled contract, live record, exact bundle, and exact verification result, validates the released subject, writes `attestation.status` `verified` and `readinessStatus` `live-attestation-verified`, and records their paths and SHA256 bindings.
- `scripts/release/verify-release-provenance.ps1` rejects drift in the subject, contract, live evidence, required permissions, signer/source policy, run/attestation URLs, exact bundle or verification-result bytes, or source-controlled evidence hashes, then reruns `gh attestation verify --bundle` against the released VSIX.
- `scripts/release/verify-publication-gaps.ps1` and the Beta-G candidate verifier require the same live attestation facts through the hash-bound provenance and publication-gaps chain.
- `scripts/tests/release-live-attestation-scripts.tests.ps1`, `scripts/tests/release-provenance-scripts.tests.ps1`, `scripts/tests/release-publication-gaps-scripts.tests.ps1`, and `scripts/tests/release-beta-candidate-evidence-scripts.tests.ps1` cover the direct contract, evidence recording, downstream bindings, and rejection of obsolete input-only evidence.

The signed custom predicate states `originalBuildProvenanceClaim=false` and `artifactSignatureClaim=false`; this post-release attestation does not use the SLSA build-provenance predicate and does not prove the original VSIX source-to-binary build provenance. This slice intentionally does not add a signing key, sign VSIX or native artifacts, publish to Marketplace, install from Marketplace, prove previous-stable upgrade/rollback, complete final SBOM/NOTICE legal review, complete CVE review, or claim public release readiness. The replaced published Beta candidate ZIP is now internally self-consistent and supplies the released VSIX bytes without changing those non-claims.

## M7j2b Gates

- `pnpm release:test-live-attestation-scripts`, `pnpm release:test-provenance-scripts`, `pnpm release:test-publication-gaps-scripts`, and `pnpm release:test-beta-candidate-evidence-scripts` must pass.
- `pnpm release:generate-provenance:win32-x64` must require the exact source-controlled subject contract and live evidence and set `attestation.status` to `verified`.
- `pnpm release:verify-provenance:win32-x64` must fail on live attestation evidence drift, removed verification policy, or signing/public-readiness overclaiming.
- `pnpm release:verify-readiness` must continue to keep `SEC-015`, `MIG-009`, `MIG-010`, `MIG-012`, and `TST-024` as release blockers until signed artifacts, Marketplace/public install, previous-stable upgrade/rollback, final SBOM/NOTICE review, and CVE review are complete.

## M7j3 Implemented Slice

The fourth M7j slice adds installed-product Source Control renderer UI E2E evidence for `win32-x64` without claiming Marketplace/public install, signing, provenance publication, previous-stable rollback, remote/auth/certificate workflows, or full product accessibility completion:

- `subversionr.diagnostics.installedSourceControlUiE2eOpenReport`, `subversionr.diagnostics.installedSourceControlUiE2eCloseReport`, and `subversionr.diagnostics.installedRepositoryLifecycleReport` are hidden release diagnostics commands. The open command opens an explicit absolute working-copy path, requires matching SCM projection and SourceControl surface state, returns renderer capture expectations, and intentionally keeps the repository open. The close command requires the same `repositoryId` and `epoch` before closing the session. The lifecycle command runs the same moved-recovery, disappeared-cleanup, and auto-open sequence used by activation/workspace events, then verifies the expected deleted or moved working-copy event for the already opened installed session.
- `scripts/release/test-vscode-installed-source-control-ui-e2e.ps1` creates the same source-built Apache Subversion 1.14.5 local fixture shape as M7i/M7j1, installs the generated VSIX into isolated VS Code roots, sets fixture-local `APPDATA/Subversion`, launches VS Code with an explicit remote debugging port, and uses a separate harness extension only as the readiness and cleanup coordinator.
- The harness executes the hidden UI E2E open command, records installed partial and stale SourceControl freshness reports with the `subversionr.fullReconcile` status bar command contract, captures separate renderer DOM, accessibility-tree, and nonblank screenshot evidence for the partial and stale status affordances, arms a one-shot Full Reconcile cancellation probe, captures and clicks the VS Code progress notification Cancel button, verifies `userCancelled` status-refresh propagation plus recovery, focuses `workbench.view.scm`, writes a ready sentinel containing the open report and renderer expectations, waits for the external capture sentinel, executes `subversionr.refreshRepository` against the single open fixture repository and verifies the SourceControl surface remains available, opens a 64-item modified source-built Refresh load fixture, executes `subversionr.refreshRepository`, verifies every modified load resource remains projected before and after Refresh, opens a second source-built fixture repository, executes `subversionr.refreshRepository`, captures the multi-repository Quick Pick through CDP, selects the second repository working-copy root, and verifies the selected repository refresh plus first-repository availability, executes `subversionr.deleteUnversionedResource` against `scratch.txt`, captures and clicks the VS Code Delete confirmation modal through CDP, verifies the file and SourceControl resource are gone after targeted refresh, opens a separate source-built 64-item unversioned load fixture, executes `subversionr.deleteAllUnversionedResources`, captures and clicks the aggregate Delete confirmation modal, verifies every load file and unversioned SourceControl resource is cleared, opens a separate source-built Add fixture, executes `subversionr.addResource`, verifies the file remains on disk and SourceControl projection moves from unversioned to local changes, opens a separate source-built Move fixture, executes `subversionr.moveResource`, captures and submits the VS Code QuickInput destination prompt with `src/moved.txt`, verifies the source file leaves disk, the destination file exists, and SourceControl projection refreshes for source deletion plus destination addition, opens a separate source-built Move cancellation fixture, executes `subversionr.moveResource`, captures the VS Code QuickInput destination prompt, cancels it with Escape, verifies the source file remains, no destination file is created, and SourceControl projection stays unchanged, opens a separate source-built Remove fixture with a missing versioned file, executes `subversionr.removeResource`, captures and clicks the Remove confirmation modal, verifies the file remains absent and SourceControl projection refreshes to the scheduled-deletion context, opens a separate source-built Remove cancellation fixture, executes `subversionr.removeResource`, captures the Remove confirmation modal, cancels it with Escape, verifies the modified file remains and SourceControl projection stays unchanged, executes `subversionr.removeResourceKeepLocal` against the fixture changed resource, captures and clicks the Keep-local Remove confirmation modal, verifies the local file remains on disk and SourceControl projection refreshes to the scheduled-removal context, opens a separate source-built Revert fixture, executes `subversionr.revertResource`, captures and clicks the Revert confirmation modal, verifies the file content returns to the repository baseline and the changed resource leaves SourceControl projection, opens a separate source-built Revert cancellation fixture, executes `subversionr.revertResource`, captures the Revert confirmation modal, cancels it with Escape, verifies the file remains modified and SourceControl projection stays unchanged, opens a separate source-built Resolve fixture with a postponed text conflict, executes `subversionr.resolveResource`, captures the Resolve Quick Pick through CDP, selects the Working copy choice, verifies the `working` choice preserves the working-copy file content and clears the conflict projection into local changes, opens a separate source-built Resolve cancellation fixture with a postponed text conflict, executes `subversionr.resolveResource`, captures the Resolve Quick Pick through CDP, cancels it with Escape, verifies the working-copy file content remains and SourceControl conflict projection stays unchanged, executes `subversionr.cleanupRepository` against the still-open fixture repository, verifies the conservative root cleanup request shape and post-cleanup full reconcile, executes the hidden close command, opens separate source-built working-copy fixtures for deletion and move lifecycle checks, mutates those fixture roots from the harness, executes the hidden lifecycle report command for both scenarios, and then runs `subversionr.diagnostics.versionReport`.
- The Refresh load workflow also restores `load/modified-001.txt` to the repository baseline after the repository Refresh assertion, executes installed `subversionr.refreshResource` for that resource, records the completed `status/refresh` target and returned coverage scope, and verifies the projected modified load count moves from 64 to 63 with zero projection remaining for the restored path.
- The dirty-generation load workflow arms the installed dirty-generation status-refresh probe, injects `fileChanged` dirty events for `load/modified-002.txt` and `load/modified-003.txt`, verifies the first refresh was observed before supersede, records `dirtyGenerationSuperseded`, and verifies completed post-cancellation coverage includes both load targets without attributing that completion to a specific flush path.
- The same harness records `sourceControlUiBoundaryLoadWorkflow`, opening a source-built parent working copy with 128 modified parent resources and a directory external boundary with 128 modified resources, then proving the parent provider projects every parent load resource while projecting zero boundary-prefixed resources.
- The same harness records `sourceControlUiCheckoutWorkflow` and `checkoutRepositoryOracle`, executing the installed local-file Checkout Repository happy path from the no-repository welcome entry through URL, target, revision, depth, and externals prompts, libsvn checkout, automatic repository open, Source Control projection availability, checked-out repository close, and repository-baseline content comparison.
- The same harness records `sourceControlUiCheckoutInvalidUrlFailureWorkflow` plus invalid-URL prompt and notification capture evidence, executing installed local-file Checkout Repository against a missing local-file URL and proving `SVN_REPOSITORY_CHECKOUT_FAILED`, no target directory, no `.svn` metadata, no opened repository, and unchanged Source Control projection.
- The same harness records `sourceControlUiUpdateToRevisionCancellationWorkflow`, `sourceControlUiUpdateToRevisionWorkflow`, and `updateToRevisionRepositoryOracle`, executing installed local-file Update to Revision against an independent source-built fixture, cancelling the revision QuickInput with Escape to prove no target content or Source Control projection mutation, then running the revision, depth, sticky-depth, and externals prompts, requesting r2 with Files depth, sticky depth, and Include externals, verifying r2 content, post-update Source Control reconciliation, evidence cleanup, and repository-oracle content comparison.
- The same harness records `sourceControlUiAddToIgnoreWorkflow` and `addToIgnoreWorkingCopyOracle`, executing installed local-file Add to Ignore against an unversioned fixture path, proving `properties/list` is read before `propertySet`, writing `svn:ignore`, and clearing the unversioned Source Control projection.
- The same harness records `sourceControlUiChangelistSetClearWorkflow`, `sourceControlUiCommitChangelistWorkflow`, `sourceControlUiRevertChangelistWorkflow`, `changelistSetPromptCapture`, `changelistRevertPromptCapture`, and `commitChangelistRepositoryOracle`, proving Set/Clear Changelist, Source Control changelist grouping, Commit Changelist filtering, Revert Changelist confirmation, and local working-copy baseline restoration.
- The same harness records `sourceControlUiLockUnlockWorkflow`, `sourceControlUiLockMessageCancellationWorkflow`, `sourceControlUiUnlockModeCancellationWorkflow`, `lockHeldWorkingCopyOracle`, `lockUnlockWorkingCopyOracle`, `lockMessageCancellationPromptCapture`, `lockMessagePromptCapture`, `lockModePromptCapture`, `unlockModeCancellationPromptCapture`, and `unlockModePromptCapture`, proving local-file `svn:needs-lock` metadata projection, Lock/Unlock command execution, local Lock message and Unlock mode prompt cancellation only, normal lock/unlock policy selection, held-lock `svn info` evidence before unlock, post-unlock token absence, no Source Control projection mutation on the covered cancellations, and targeted `operationLock`/`operationUnlock` reconcile coverage.
- The same harness records `sourceControlUiBranchCreateWorkflow`, `branchCreateRepositoryOracle`, `sourceControlUiSwitchWorkflow`, and `switchWorkingCopyOracle`, proving installed local-file Branch/Tag create prompt capture, SVN copyfrom metadata through `svn log -v`, Branch/Tag repository content/log validation, Switch prompt capture, post-switch Source Control generation advancement, repository identity preservation, and switched working-copy URL validation.
- `scripts/release/capture-vscode-renderer-ui.mjs` attaches to the VS Code workbench CDP target through Node built-in `fetch`/`WebSocket`, captures DOM text, `Accessibility.getFullAXTree` output, and a PNG screenshot, verifies required Source Control, confirmation-modal, or QuickInput tokens, optionally clicks an expected VS Code button, submits expected QuickInput text, or cancels a QuickInput/modal with Escape, parses PNG pixels for a nonblank sample, and writes SHA256-bound renderer evidence.
- Evidence is written as `subversionr.release.installed-source-control-ui-e2e.win32-x64.v1` with `publicReadinessClaim: false`, Code CLI hash/version/remote-debugging port, VSIX hash/target, renderer capture driver hash, source-built fixture tool hashes/versions, isolated roots, open/checkout-cancellation/checkout-existing-target-failure/checkout-invalid-url-failure/checkout/update-to-revision/update-to-revision-cancellation/Add to Ignore/lock-unlock/lock-message-cancellation/unlock-mode-cancellation/Branch-Tag create/Switch/changelist set-clear/commit-changelist/revert-changelist/partial-freshness/stale-freshness/Refresh/Refresh load/restored-resource Refresh/restored-resource coverage/dirty-generation supersede and cancellation load/boundary load/multi-repository Refresh/Delete Unversioned/Delete All Unversioned Items/Add/Move/Move cancellation/Remove/Remove cancellation/Keep-local Remove/Revert/Revert cancellation/Resolve/Resolve cancellation/Cleanup/close reports, deletion and move lifecycle reports, version report, renderer capture artifacts for SCM, no-repository welcome, checkout cancellation, checkout existing-target failure, checkout invalid URL failure, and checkout happy-path prompts, update cancellation revision prompt, update revision/depth/sticky-depth/externals prompts, Branch/Tag source/destination/revision/message/parents/externals prompts, Switch URL/revision/depth/sticky-depth/externals/ancestry prompts, Lock message cancellation/Lock message/Lock mode/Unlock mode cancellation/Unlock mode prompts, Set Changelist and Revert Changelist prompts, partial/stale freshness states, Full Reconcile cancellation progress, multi-repository Refresh, Delete, Move, Move cancellation, Remove, Remove cancellation, Keep-local Remove, Revert, Revert cancellation, Resolve and Resolve cancellation Quick Pick prompts, non-claims, and trace IDs `BRM-001`, `BRM-005`, `COM-003`, `DIR-003`, `DIR-009`, `DIR-010`, `DIR-012`, `DIR-013`, `REP-002`, `REP-004`, `MIG-009`, `OPS-001`, `OPS-002`, `OPS-003`, `OPS-004`, `OPS-005`, `OPS-006`, `OPS-007`, `OPS-008`, `OPS-010`, `OPS-011`, `OPS-013`, `OPS-014`, `OPS-015`, `STA-003`, `STA-009`, `STA-013`, `STA-014`, `SYN-003`, `SYN-004`, `SYN-005`, `TST-018`, `TST-024`, `UX-001`, `UX-002`, and `UX-007`.
- UX-001 is closed for installed on-demand activation evidence: opening an installed local SVN working copy activates the VSIX without a SubversionR command, automatically opens its provider, and publishes the expected Source Control surface before diagnostic inspection; the local Source Control renderer DOM, accessibility-tree, and screenshot evidence is also captured. UX-002 is partial: the installed no-repository SCM welcome contributes localized `Open SVN Working Copy…` and `Checkout SVN Repository…` entries plus renderer DOM, accessibility-tree, screenshot evidence, the installed local-file Checkout Repository happy path, URL prompt cancellation, pre-existing obstructing target file failure/no-state-pollution flow, invalid URL failure/no-state-pollution flow, pre-existing local directory target success path, and pre-existing local directory obstruction tree-conflict projection path, while repository browser, remote/auth/certificate, and broader checkout failure matrices remain open. UX-007 is closed for the installed multi-repository QuickPick selection path with renderer DOM, accessibility-tree, screenshot, and selected-item evidence. Broader accessibility acceptance remains tracked by its own requirement rows.
- Script-level fixture tests cover the M7j3 evidence schema, root package scripts, CI wiring, fake VSIX/fake Code/fake source-built SVN tools, fake renderer capture driver, hidden freshness, current-surface, and lifecycle report command registration, Checkout Repository happy path, Checkout existing-target failure, Checkout invalid URL failure, checkout prompt capture, checkout repository oracle, Update to Revision happy path, update cancellation prompt capture/no-state-pollution evidence, update prompt capture, update repository oracle, installed root Update conflict creation and warning notification capture, Add to Ignore, `svn:ignore` working-copy oracle, Set/Clear Changelist, Set Changelist QuickInput capture, Commit Changelist, commit-by-changelist repository oracle, Revert Changelist, Revert Changelist confirmation capture, Lock/Unlock, Lock message cancellation, Unlock mode cancellation, Branch/Tag create, Branch/Tag prompt capture, Branch/Tag copyfrom repository oracle, Switch, Switch prompt capture, Switch Source Control generation/identity assertions, Switch working-copy URL oracle, Refresh, Refresh load, restored-resource Refresh, restored-resource coverage, dirty-generation supersede/cancellation load, boundary load, multi-repository Refresh, Delete Unversioned, Delete All Unversioned Items, Add, Move, Move cancellation, Remove, Remove cancellation, Keep-local Remove, Revert, Revert cancellation, Resolve, Resolve cancellation, and Cleanup command registration and workflow evidence, prompt capture click, QuickPick selection, QuickInput submission, QuickInput cancellation, notification cancellation, and modal cancellation evidence, partial/stale SourceControl status bar command and renderer capture evidence, Full Reconcile cancellation and recovery evidence, deletion/move lifecycle report persistence, unresolved Code/driver placeholders, renderer DOM token failure, blank screenshot rejection, and partial accessibility artifact rejection.
- Windows CI runs the installed Source Control UI E2E script tests and then runs the real installed VSIX Source Control UI E2E gate after VSIX packaging, CLI installation, M7h version-report smoke, M7i installed core workflow, and M7j1 Source Control surface gates.

This slice intentionally does not publish to Marketplace, sign artifacts, publish provenance, test upgrade/rollback from a previous stable release artifact, cover svnserve/HTTP/HTTPS/auth/certificate flows, add macOS/Linux/ARM64 targets, complete installed protocol-fault E2E evidence, cover repository browser, remote/auth/certificate, and broader checkout failure matrices, close full property editor UX, `svn:externals` editing, property/changelist load or cancellation breadth, broaden lock cancellation beyond local Lock message and Unlock mode prompt cancellation only, broad remote lock-server matrices, break/steal policy breadth, load-scale lock behavior, switch-after-copy, branch/switch target browsing, broad branch-management remote/auth/certificate matrices, repository-browser integration, merge workflows, switched working-copy edge/load behavior, commit template/message-history behavior, broader accessibility acceptance, or final SBOM/NOTICE/CVE review.

## M7j3 Gates

- `pnpm release:test-installed-source-control-ui-e2e-scripts` must pass.
- `pnpm release:test-installed-source-control-ui-e2e:win32-x64` must receive explicit `SUBVERSIONR_CODE_CLI`, the source-built Apache Subversion 1.14.5 fixture tools, the tracked renderer capture driver, and an available remote debugging port, and must run against the generated VSIX after `pnpm release:package-vsix:win32-x64`.
- `pnpm release:verify-readiness` must continue to keep `SEC-015`, `MIG-009`, `MIG-010`, `MIG-012`, `TST-018`, and `TST-024` as release blockers until signed artifacts, Marketplace/public install, previous-stable upgrade/rollback, final SBOM/NOTICE review, CVE review, broader accessibility evidence, broader no-repository UX evidence, repository browser, remote/auth/certificate, broader checkout failure matrices, full property editor UX, `svn:externals` editing, property/changelist load or cancellation breadth, lock cancellation beyond local Lock message and Unlock mode prompt cancellation only, broad remote lock-server matrices, break/steal policy breadth, load-scale lock behavior, and commit template/message-history behavior are complete.

## M7k1 Implemented Slice

The first M7k slice adds public support intake and redaction preflight evidence without enabling the public repository or claiming public release readiness:

- `.github/ISSUE_TEMPLATE/config.yml` disables blank public issues so reporters must choose a structured intake path.
- `.github/ISSUE_TEMPLATE/01_bug_report.yml` and `.github/ISSUE_TEMPLATE/02_support_request.yml` collect only sanitized environment, workflow, transport category, Workspace Trust, and reproduction details.
- The public issue forms route suspected vulnerabilities to `SECURITY.md`, warn in English, Japanese, and Chinese before any evidence fields, and require reporters to acknowledge that they did not include credentials, tokens, cookies, private repository URLs, client certificate private keys, `.svn/wc.db`, raw logs, or source content.
- `docs/security/support-redaction-checklist.md` gives maintainers a stop-condition checklist for public reports, diagnostics artifacts, credentialed repository URLs, auth headers, cookies, working-copy absolute paths, stack traces, source content, raw logs, and accidental public exposure.
- `docs/security/support-handling.md`, `docs/release/security-evidence-matrix.md`, and `docs/release/public-claim-matrix.md` now trace this gate to `SEC-002`, `SEC-014`, `OBS-005`, `OBS-007`, `PRD-010`, and `PRD-012`.
- `packages/vscode-extension/tests/diagnosticsRedaction.test.ts` includes a public support redaction fixture with fake credentialed HTTPS and `svn://` URLs, `.svn/wc.db`, `Authorization`, `Cookie`, and local stack-trace path samples.
- `scripts/verify-support-intake.ps1` fails fast when blank issues are enabled, public issue forms omit security routing or sensitive-data acknowledgements, `SECURITY.md` loses private-reporting guidance, the redaction checklist omits SVN-specific sensitive categories, the public support redaction fixture disappears, package scripts are missing, or CI stops running the support intake gate.
- `scripts/tests/support-intake-scripts.tests.ps1` covers the verifier with valid and negative fixtures for blank issues, missing `SECURITY.md` routing, missing `.svn/wc.db` checklist coverage, missing redaction fixture evidence, and missing CI wiring.
- Windows CI runs `pnpm docs:verify-support-intake` after public security documentation checks and before `pnpm release:verify-readiness`, then runs `pnpm release:test-support-intake-scripts` with the release script tests.

This slice intentionally does not publish the repository, enable GitHub Private Vulnerability Reporting, publish to Marketplace, install from Marketplace, sign VSIX or native artifacts, generate GitHub artifact attestations, prove previous-stable upgrade/rollback, complete final SBOM/NOTICE legal review, or complete CVE review.

## M7k1 Gates

- `pnpm docs:verify-support-intake` must pass.
- `pnpm release:test-support-intake-scripts` must pass.
- `pnpm release:verify-readiness` must call the support intake verifier and keep `SEC-015`, `MIG-009`, `MIG-010`, `MIG-012`, `TST-018`, and `TST-024` as release blockers until artifact signing and signed provenance, Marketplace/public install, previous-stable upgrade/rollback, final SBOM/NOTICE review, CVE review, and broader accessibility evidence are complete.

## M7k2a Implemented Slice

The second M7k slice hardens Marketplace listing metadata and icon evidence without publishing the repository or extension:

- `packages/vscode-extension/package.json` now declares SVN-focused Marketplace keywords and `resources/marketplace/icon.png` as the extension icon.
- The icon is a packaged PNG asset, not an SVG, and the staged layout verifier requires a normalized package-relative icon path, PNG signature, and at least 128x128 pixels.
- `scripts/release/stage-vscode-package-layout.ps1` copies the icon from the extension source into the staged package root, while `scripts/release/verify-vscode-package-layout.ps1` fails on missing icon assets, invalid icon paths, invalid PNGs, undersized icons, or missing Marketplace keywords.
- `scripts/release/package-vscode-vsix.ps1` requires the VSIX to contain the same icon path and records icon hash continuity from the staged package into `subversionr.release.vsix-package.win32-x64.v1`.
- `scripts/release/generate-release-provenance.ps1` now fails on missing icon metadata, missing required keywords, or VSIX package evidence whose icon hash differs from the source package icon.
- `scripts/release/verify-release-provenance.ps1` re-hashes the icon, checks the recorded PNG dimensions, checks required keywords, and requires explicit blockers for missing public repository metadata, Marketplace publisher authorization, publish authentication, Marketplace/public install evidence, and previous-stable rollback evidence.
- Script-level fixture tests cover staged icon copying, layout rejection when the icon is missing, VSIX icon inclusion/hash continuity, provenance icon/keyword evidence, and VSIX icon hash drift rejection.

This slice intentionally keeps the root package private, records only approved public repository metadata from the extension manifest, does not verify Marketplace publisher ownership, does not configure publish credentials, does not publish or install from Marketplace, does not sign artifacts, does not generate live attestations, and does not prove previous-stable upgrade/rollback.

## M7k2a Gates

- `pnpm release:test-scripts` must pass with the staged Marketplace icon checks.
- `pnpm release:test-vsix-scripts` must pass with VSIX icon inclusion and hash-continuity evidence.
- `pnpm release:test-provenance-scripts` must pass with Marketplace icon, keyword, and publication-blocker fixtures.
- `pnpm release:stage-vscode:win32-x64`, `pnpm release:verify-vscode:win32-x64`, `pnpm release:package-vsix:win32-x64`, `pnpm release:generate-provenance:win32-x64`, and `pnpm release:verify-provenance:win32-x64` must preserve the same icon hash from source package to staged package, VSIX, and provenance evidence.
- `pnpm release:verify-readiness` must keep `SEC-015`, `MIG-009`, `MIG-010`, `MIG-012`, `TST-018`, and `TST-024` as release blockers until public repository metadata, Marketplace publisher authorization, publish authentication, artifact signing and signed provenance, Marketplace/public install, previous-stable upgrade/rollback, final SBOM/NOTICE review, CVE review, and broader accessibility evidence are complete.

## M7k2b Implemented Slice

The third M7k slice maintains the publication-gaps and publish-auth contract after the public repository cutover while keeping the current `0.2.0` candidate unpublished by the controlled Marketplace pipeline:

- `scripts/release/generate-publication-gaps.ps1` writes `subversionr.release.publication-gaps.win32-x64.v1` after the VSIX package evidence and Marketplace provenance preflight have been generated and verified.
- The gate binds the exact VSIX bytes, VSIX package evidence, provenance preflight, extension/root package manifests, README, LICENSE, CHANGELOG, SUPPORT, the public cutover runbook, and `docs/release/public-cutover-evidence.json` by SHA256.
- The root package remains private, while the extension package must publish from the public `hitsuki-ban.subversionr` identity with `repository`, `homepage`, and `bugs` manifest fields pointing to the approved public repository.
- Public repository metadata fields are recorded from the extension manifest with `repositoryUrlRecorded`, `homepageUrlRecorded`, and `bugsUrlRecorded` all true. The hash-bound cutover evidence records only that `https://github.com/Hitsuki-Ban/SubversionR` resolves publicly; homepage and social metadata remain an explicit follow-up.
- `docs/release/public-cutover-evidence.json` records the fresh public baseline commit, the successful `PR Fast` main run, Private Vulnerability Reporting enablement, Cloudflare Workers Builds trigger retirement and repository disconnection, and the published `v0.2.0-beta.1` prerelease with its four asset names, sizes, URLs, and SHA256 values.
- The released VSIX asset must match the current candidate bytes exactly. The recorded anchor is `d8ea4bfc187598a80ef0131f6345a60b8f3dcba2c9b22b992ea370f12eaa85cb`.
- The active public `protect-main` ruleset and both `disabled_manually` private workflows are recorded as completed owner operations. Private-repository archive/freeze remains a separate follow-up. Live GitHub artifact attestation publication and verification are recorded through the M7j2b evidence chain.
- The replaced published Beta candidate ZIP is SHA256 `ca79f8cd2716caadc9c6e1e6c712c6904770a05e3660835b0ab58ce75bbbb266` with size 15,300,834. Its manifest declares 1,462 payloads, with 0 missing and 0 mismatched; the only two additional ZIP entries are the manifest and final consistency JSON. It contains the released `subversionr-win32-x64-0.2.0.vsix` with SHA256 `d8ea4bfc187598a80ef0131f6345a60b8f3dcba2c9b22b992ea370f12eaa85cb`, and `betaCandidateEvidence.status` is `consistent` after the unchanged Beta-G verifier passed.
- `docs/release/marketplace-publisher-authorization-evidence.json` records the repository owner's attestation that the resolved Entra identity has `Contributor` authorization for `hitsuki-ban.subversionr`. The evidence binds owner comment `issuecomment-4938167334` and bootstrap run `29107576798` by fixed public URLs without recording tenant, client, identity, credential, token, or authorization-header values.
- Publish authentication is recorded as `entra-federated-workflow-configured`. The hash-bound workflow uses the protected `marketplace` environment, GitHub OIDC, owner-managed `AZURE_CLIENT_ID` and `AZURE_TENANT_ID` variable names, `azure/login`, and direct `vsce --azure-credential`; it has no credential fallback and records no variable values.
- Marketplace public install is recorded as `not-run`, bound to expected extension id/version, and explicitly records no public extension page, acquisition, or install evidence.
- `scripts/release/verify-publication-gaps.ps1` rejects public-readiness claims, private repository URLs, credential/token-like fields, Cloudflare live IDs, stale or drifted publisher authorization evidence, publish-auth overclaims, Marketplace publication/public-install overclaims, missing or drifted live-attestation evidence, missing non-claims, hash drift, target/schema mismatch, and output paths outside generated evidence roots.
- `scripts/tests/release-publication-gaps-scripts.tests.ps1` covers positive generation/verification, output-root containment, unexpected public-resource metadata rejection, upstream provenance overclaim rejection, stale publisher state, publisher identity-value leakage, publisher evidence hash drift, credential/public-install overclaims, missing live-attestation evidence, released-VSIX hash drift, invalid public CI URLs, cutover source hash drift, package scripts, CI wiring, and release-readiness verifier terms.
- Windows CI runs the script tests, then generates and verifies the real `win32-x64` publication-gaps evidence immediately after provenance verification.

This evidence records the consistent published Beta candidate, `main`-anchored verified live GitHub attestation, active public branch ruleset, disabled private workflows, source-controlled Entra publish-auth contract, successful hash-bound identity bootstrap run, and separately hash-bound owner-attested Marketplace Contributor authorization. It does not archive the private repository, publish the current candidate to Marketplace, install from Marketplace, sign artifacts, prove previous-stable upgrade/rollback, or claim public release readiness.

## M7k2b Gates

- `pnpm release:test-publication-gaps-scripts` must pass.
- `pnpm release:generate-publication-gaps:win32-x64` must run after `pnpm release:verify-provenance:win32-x64`.
- `pnpm release:verify-publication-gaps:win32-x64` must reject any Marketplace publication, publisher-auth, publish-auth, credential, public-install, missing or drifted live-attestation evidence, or public-readiness overclaim and any drift from the hash-bound public cutover facts.
- `pnpm release:verify-readiness` must keep `SEC-015`, `MIG-009`, `MIG-010`, `MIG-012`, `TST-018`, and `TST-024` as release blockers until public repository metadata is approved, signing is complete, Marketplace/public install evidence exists, previous-stable upgrade/rollback is proven, final SBOM/NOTICE review and CVE review are complete, and broader accessibility evidence is complete. Publisher Contributor authorization and Entra publish authentication are recorded but do not close those other requirements.

## M7k2c Implemented Slice

The fourth M7k slice adds the secretless Marketplace pre-release pipeline without claiming that the current candidate was published:

- `.github/workflows/publish-marketplace.yml` accepts a dispatch `release_tag`, downloads the exact source-controlled release subject, verifies its contract and GitHub artifact attestation before Azure login, and binds the job to the protected `marketplace` environment with `contents: read` and `id-token: write` only.
- The workflow uses GitHub OIDC with owner-managed `AZURE_CLIENT_ID` and `AZURE_TENANT_ID` repository variables, then publishes only the downloaded path with `vsce publish --packagePath ... --pre-release --azure-credential`. No publish credential, token exchange, or fallback path is stored in the repository.
- `docs/release/marketplace-identity-bootstrap-evidence.json` preserves successful public run `29107576798`, the `marketplace` environment OIDC subject, variable names, Azure CLI login, and Marketplace identity resolution without recording variable or identity values. The later owner-attested Contributor authorization is recorded separately in `docs/release/marketplace-publisher-authorization-evidence.json` so the historical bootstrap record remains unchanged.
- The workflow fails before Azure login unless the VSIX already contains `Microsoft.VisualStudio.Code.PreRelease`. The attested `0.2.0` release VSIX lacks that property, and changing its bytes would break its attestation contract, so `0.2.0` cannot be published through this pre-release path.
- `packages/vscode-extension/README.md` is the Marketplace listing source for the next attested pre-release candidate. The existing `0.2.0` asset keeps its already-attested README bytes; this slice does not rebuild or replace it.
- `scripts/release/record-marketplace-publication.ps1` can write bounded post-publish evidence only after a successful workflow run. Its publication claim applies to the exact extension version and VSIX subject while `publicReadinessClaim` remains false.
- `docs/release/marketplace-pre-release-owner-exception.md` records the issue #14 owner decision for `SEC-015`, `MIG-010`, and `MIG-012`. The exception permits one evidence-gated pre-release operation before final SBOM/NOTICE/legal review and real previous-stable rollback evidence, but those rows and the security matrix remain release blockers outside that bounded operation.
- `docs/release/marketplace-existing-listing-evidence.json` records the public Gallery API observation that the existing `win32-x64` listing is version `0.1.0` and predates this pipeline. It is not evidence that version `0.2.0` was published by this workflow.

This slice intentionally does not publish or rewrite the attested `0.2.0` asset, verify Marketplace public install, sign artifacts, complete final review, prove previous-stable rollback, or claim public release readiness. Successful OIDC bootstrap and later owner-attested Marketplace Contributor authorization are recorded as separate bounded evidence.

## M7k2c Gates

- `pnpm release:test-marketplace-publication-scripts` must pass with the workflow order, exact-subject, OIDC, pre-release eligibility, recorder, path-containment, and non-claim fixtures.
- `pnpm release:test-vsix-scripts` must pass with packaged README hash-continuity evidence while preserving the current release bytes.
- `pnpm release:test-publication-gaps-scripts` must record the Entra workflow as configured, owner-attested Contributor authorization as verified, and current `0.2.0` pre-release eligibility as blocked.
- `pnpm release:verify-readiness:smoke` must require the three owner-exception rows while keeping the security evidence matrix release blockers and `publicReadinessClaim=false` contracts unchanged.
- A real publication claim is allowed only after the source-controlled workflow succeeds and emits `subversionr.release.marketplace-publication.win32-x64.v1` evidence for the exact published subject.

## 0.2.1 Pre-release Candidate Refresh

Issue [#20](https://github.com/Hitsuki-Ban/SubversionR/issues/20) replaces the blocked current-artifact state without rewriting the historical `0.2.0` release:

- root and extension versions are `0.2.1`, and `vsce package --pre-release` produces an exact `subversionr-win32-x64-0.2.1.vsix` whose manifest contains one `Microsoft.VisualStudio.Code.PreRelease=true` property;
- VSIX ZIP timestamps and entry ordering are normalized so repeated packaging of identical inputs produces identical bytes;
- issue [#22](https://github.com/Hitsuki-Ban/SubversionR/issues/22) makes the MSVC Release bridge deterministic with `/Brepro` and rejects bridge output without `IMAGE_DEBUG_TYPE_REPRO` before packaging;
- issue [#24](https://github.com/Hitsuki-Ban/SubversionR/issues/24) applies the same deterministic linker policy to the Windows MSVC Rust daemon, rejects ambient Rust flag overrides, and validates the resulting PE before packaging;
- the released `v0.2.1-beta.1` asset is 8,251,798 bytes with SHA256 `13dac1f5faadff04e414d413fe4306309889b95bd03c108e42d411bc4b6fc936` and has verified live GitHub attestation `34858009`;
- provenance, publication gaps, and Beta-G bind that current candidate contract while retaining the `v0.2.0-beta.1` release and attestation only as historical public-cutover evidence;
- the attestation workflow creates and verifies the current live attestation after the release exists, and the publish workflow independently verifies that live attestation against its own public `main` workflow SHA before Azure login; and
- `docs/release/marketplace-pre-release-owner-exception-0.2.1.md` records the exact #20/#22/#24 owner authorization. `publicReadinessClaim` remains false throughout the candidate, attestation, and publication evidence chain.

The 0.2.1 Marketplace workflow reached the exact `vsce publish` call after its release, pre-release property, live attestation, Entra variables, and federated login were verified. Marketplace rejected the display name `SubversionR` because a deleted pre-governance extension permanently reserved it, so no 0.2.1 Marketplace publication evidence was recorded.

## 0.2.2 Marketplace Display Name Alignment

Issue [#26](https://github.com/Hitsuki-Ban/SubversionR/issues/26) preserves the product name while aligning the package metadata with the existing live listing:

- root and extension versions are `0.2.2`, and the exact Marketplace package `displayName` is `SVN-R`;
- SubversionR remains the product and brand name in README, diagnostics, SBOM, NOTICE, and Source Control UI surfaces;
- the extension id remains `hitsuki-ban.subversionr`, with no command, protocol, or compatibility aliases;
- `docs/release/github-attestation-candidate-contract.win32-x64.json` bound the then-pending `v0.2.2-beta.1` subject at 8,251,930 bytes with SHA256 `47d6d9718614bb2e81706af2096e7387fadeeec34db7d6867c3233c8206dc378`;
- `docs/release/marketplace-pre-release-owner-exception-0.2.2.md` scopes the one automated publication authorization to the exact 0.2.2 bytes; and
- [`docs/release/0.2.2-publication-evidence.md`](../release/0.2.2-publication-evidence.md) records the completed GitHub release, live custom-predicate attestation, Marketplace publish workflow, and public Gallery state. Signing, signed source-to-binary provenance, previous-stable rollback, final legal and vulnerability approval, and public readiness remain separate open gates.

## 0.2.4 Source Control Information-architecture Candidate

The pending 0.2.4 candidate preserves the `SVN-R` Marketplace identity while packaging the completed Source Control information-architecture, runtime count-policy, working-copy metadata grouping, and installed UI-evidence hardening slices:

- root and extension versions are `0.2.4`; the extension version remains plain `major.minor.patch`, while the planned GitHub pre-release tag is `v0.2.4-beta.1`;
- `vsce package --target win32-x64 --pre-release` bakes exactly one `Microsoft.VisualStudio.Code.PreRelease=true` property into the candidate before its bytes are hashed;
- the provisional release subject is `subversionr-win32-x64-0.2.4.vsix`, 8,295,021 bytes, SHA256 `880e7937423695ca772436f01e2419498463ebd7cc25ba8a283a135530418249`;
- `docs/release/github-attestation-candidate-contract.win32-x64.json` binds the exact pending release/attestation subject with `publicReadinessClaim=false`; and
- `docs/release/marketplace-pre-release-owner-exception-0.2.4.md` authorizes only those exact bytes after the candidate is sealed.

This candidate-preparation slice does not create the GitHub release, publish a live attestation, publish to the Marketplace, prove public installation, or claim public release readiness. The published 0.2.3 release, attestation, Marketplace workflow, and Gallery evidence remain historical facts recorded below.

## 0.2.3 Actionable Core-loop Publication

The published 0.2.3 candidate preserves the `SVN-R` Marketplace identity and packages the completed activation, on-demand remote status, conflict-aware Update, and actionable operation-failure slices:

- root and extension versions are `0.2.3`; the extension version remains plain `major.minor.patch`, while the GitHub pre-release tag is `v0.2.3-beta.1`;
- `vsce package --target win32-x64 --pre-release` bakes exactly one `Microsoft.VisualStudio.Code.PreRelease=true` property into the candidate before its bytes are hashed;
- the reproducible GitHub CI release subject is `subversionr-win32-x64-0.2.3.vsix`, 8,292,661 bytes, SHA256 `991199a1cd874b76e10dd8ca383edac766b169d638e0b42253022507c435b12b`, generated by successful `main` workflow run [`29213416025`](https://github.com/Hitsuki-Ban/SubversionR/actions/runs/29213416025) in artifact `8266138557`;
- `docs/release/github-attestation-candidate-contract.win32-x64.json` records the then-pending release/attestation contract and requires `artifact-metadata: write` in addition to the existing GitHub attestation permissions;
- `docs/release/marketplace-pre-release-owner-exception-0.2.3.md` authorizes only those exact bytes; and
- [`docs/release/0.2.3-publication-evidence.md`](../release/0.2.3-publication-evidence.md) records the completed GitHub release, live custom-predicate attestation, successful Marketplace publish workflow, and byte-identical public Gallery state. Public-install verification, signing, signed source-to-binary provenance, previous-stable rollback, final legal and vulnerability approval, and public readiness remain separate open gates.

## M7l1 Implemented Slice

The first M7l slice adds a vulnerability review input-contract preflight without querying live advisory services or claiming CVE review completion:

- `scripts/release/generate-vulnerability-review-preflight.ps1` writes `subversionr.release.vulnerability-review-preflight.win32-x64.v1` from the generated CycloneDX 1.6 source SBOM.
- The gate binds the SBOM by SHA256 and records the current SBOM component count before any vulnerability review assertions are made.
- Versioned npm and Cargo PURLs are converted into OSV `/v1/querybatch` request contracts using `queries[].package.purl` only, matching the OSV rule that a versioned PURL must not be combined with a separate `version` field.
- Generic native source-lock components and any unsupported ecosystem components are kept in `manualReview.components` with explicit reasons, so Apache Subversion, APR, Serf, Apache HTTP Server, OpenSSL, PCRE2, Expat, zlib, SQLite, and similar native inputs still require vendor/advisory/CVE review.
- The evidence records OSV status as `not-run`, `liveQueryPerformed: false`, `resultRecorded: false`, and `vulnerabilityReviewComplete: false`.
- `scripts/release/verify-vulnerability-review-preflight.ps1` rejects public-readiness claims, CVE review completion overclaims, live OSV result fields, credential/token-like fields, OSV queries that combine versioned PURL with version/name/ecosystem fields, SBOM hash drift, target/schema mismatch, missing non-claims, and output paths outside generated evidence roots.
- `scripts/tests/release-vulnerability-review-scripts.tests.ps1` covers positive generation/verification, output-root containment, CVE completion overclaims, live OSV result overclaims, malformed OSV query contracts, SBOM hash drift, package scripts, CI wiring, and release-readiness verifier terms.
- Windows CI runs the script tests, then generates and verifies the real `win32-x64` vulnerability review preflight after SBOM/NOTICE evidence verification and before runtime tests.

This slice intentionally does not query OSV live services, record vulnerability IDs/results, complete native advisory review, make VEX decisions, approve remediation, complete final SBOM/NOTICE legal review, sign artifacts, publish attestations, install from Marketplace, or prove previous-stable upgrade/rollback.

## M7l1 Gates

- `pnpm release:test-vulnerability-review-scripts` must pass.
- `pnpm release:generate-vulnerability-review:win32-x64` must run after `pnpm release:verify-evidence`.
- `pnpm release:verify-vulnerability-review:win32-x64` must reject live-result, credential, malformed OSV query, CVE completion, public-readiness, schema, target, or SBOM drift overclaims.
- `pnpm release:verify-readiness` must keep `SEC-015`, `MIG-009`, `MIG-010`, `MIG-012`, `TST-018`, and `TST-024` as release blockers until live CVE/OSV review, native advisory review, remediation/VEX decisions, artifact signing and signed provenance, Marketplace/public install, previous-stable upgrade/rollback, final SBOM/NOTICE review, and broader accessibility evidence are complete.

## M7l2a Implemented Slice

The first M7l2 slice records live OSV result evidence for the M7l1 npm/Cargo query contracts without claiming full vulnerability review completion:

- `scripts/release/generate-live-osv-vulnerability-review.ps1` consumes the M7l1 preflight evidence and writes `subversionr.release.vulnerability-review-osv.win32-x64.v1`.
- The generator re-validates the preflight schema, target, public-readiness flags, vulnerability-completion flags, and `not-run` OSV status before any live request is made.
- The generator uses the ordered M7l1 `osv.queries` list as the sole live OSV input. It does not rebuild queries from the SBOM, use `npm audit`, use `cargo audit`, use OSV-Scanner, or treat network failure as a zero-finding result.
- Before recording project results, the generator runs a documented positive-control query for `pkg:pypi/mlflow@0.4.0` and requires at least one OSV vulnerability ID, so a broken or empty OSV response path cannot be mistaken for a clean project result.
- Live OSV execution uses `POST https://api.osv.dev/v1/querybatch`, preserves response ordering against preflight query indices, handles per-query pagination through `page_token`, and fetches full detail records through `GET https://api.osv.dev/v1/vulns/{id}` for every unique vulnerability ID.
- Querybatch `modified` timestamps must match the fetched vulnerability detail `modified` timestamp, so stale or inconsistent OSV detail evidence fails fast.
- Evidence records `osv.status: queried`, `liveQueryPerformed: true`, `resultRecorded: true`, ordered query results, vulnerability detail records, and pending finding rows for triage/remediation/VEX review.
- Native source-lock and unsupported ecosystem components remain in `manualReview.components` with `manualReview.status: required` and `releaseBlocking: true`.
- `scripts/release/verify-live-osv-vulnerability-review.ps1` rejects public-readiness claims, vulnerability-review completion claims, triage/remediation/VEX completion claims, credential/token-like evidence, preflight hash drift, non-official endpoints in release evidence, order drift between preflight queries and live results, missing vulnerability details, missing blockers, and missing non-claims.
- `scripts/tests/release-live-osv-review-scripts.tests.ps1` covers positive generation/verification through a fixture-local mock OSV TCP server, paginated querybatch responses, detail fetching, output-root containment, completion overclaims, preflight hash drift, result-order drift, credential-like evidence rejection, package scripts, CI wiring, and release-readiness verifier terms.
- Windows CI runs the script tests, then generates and verifies the real `win32-x64` live OSV review immediately after the M7l1 preflight verification.

This slice intentionally does not complete native dependency advisory review, make VEX decisions, approve remediation, complete final SBOM/NOTICE legal review, sign artifacts, publish attestations, install from Marketplace, prove previous-stable upgrade/rollback, or claim public release readiness.

## M7l2a Gates

- `pnpm release:test-live-osv-review-scripts` must pass.
- `pnpm release:generate-live-osv-review:win32-x64` must run after `pnpm release:verify-vulnerability-review:win32-x64`.
- `pnpm release:verify-live-osv-review:win32-x64` must reject credential, endpoint, preflight hash, query ordering, missing detail, triage/remediation/VEX completion, vulnerability-completion, public-readiness, schema, or target overclaims.
- `pnpm release:verify-readiness` must keep `SEC-015`, `MIG-009`, `MIG-010`, `MIG-012`, `TST-018`, and `TST-024` as release blockers until native advisory review, remediation/VEX decisions, artifact signing and signed provenance, Marketplace/public install, previous-stable upgrade/rollback, final SBOM/NOTICE review, and broader accessibility evidence are complete.

## M7l2b Implemented Slice

The second M7l2 slice adds native advisory source-contract evidence without claiming native advisory review completion:

- `docs/security/native-advisory-sources.lock.json` records official/project advisory source contracts for every native source-lock component: Apache Subversion, Apache HTTP Server, PCRE2, Apache Serf, OpenSSL, APR, APR-util, APR-iconv, Expat, zlib, and SQLite.
- `scripts/release/generate-native-advisory-review.ps1` writes `subversionr.release.native-advisory-review.win32-x64.v1` from `native/sources.lock.json`, the M7l2a live OSV evidence, and the advisory source contract.
- The gate binds the native source lock, live OSV evidence, and advisory source contract by SHA256, requires live OSV evidence to be no older than seven days, and rejects source-lock/advisory-contract component coverage drift.
- Components without a dedicated advisory index, such as Serf, APR-family inputs, Expat, and zlib, remain explicit release blockers instead of being treated as clean.
- The evidence keeps `publicReadinessClaim`, `vulnerabilityReviewComplete`, `nativeAdvisoryReviewComplete`, triage completion, remediation approval, and VEX completion false.
- `scripts/release/verify-native-advisory-review.ps1` rejects public-readiness claims, vulnerability/native-review completion overclaims, stale live OSV evidence, source/advisory/live-OSV hash drift, missing/extra/duplicate native component coverage, credential-like evidence, schema mismatch, target mismatch, and output paths outside generated evidence roots.
- `scripts/tests/release-native-advisory-review-scripts.tests.ps1` covers positive generation/verification, output-root containment, missing source-contract coverage, stale live OSV evidence, source-lock hash drift, overclaim rejection, credential-like evidence rejection, package scripts, CI wiring, and release-readiness verifier terms.
- Windows CI runs the script tests, then generates and verifies the real `win32-x64` native advisory review evidence immediately after the M7l2a live OSV evidence verification.

This slice intentionally does not assert that native dependencies are free of known vulnerabilities, complete native advisory review, make VEX decisions, approve remediation, prove reproducible builds or signed source-to-binary build attestation, complete final SBOM/NOTICE legal review, sign artifacts, publish attestations, install from Marketplace, prove previous-stable upgrade/rollback, or claim public release readiness.

## M7l2b Gates

- `pnpm release:test-native-advisory-review-scripts` must pass.
- `pnpm release:generate-native-advisory-review:win32-x64` must run after `pnpm release:verify-live-osv-review:win32-x64`.
- `pnpm release:verify-native-advisory-review:win32-x64` must reject stale OSV evidence, credential, source-lock hash, advisory-source hash, live-OSV hash, missing/extra/duplicate component coverage, native-review completion, vulnerability-completion, public-readiness, schema, or target overclaims.
- `pnpm release:verify-readiness` must keep `SEC-015`, `MIG-009`, `MIG-010`, `MIG-012`, `TST-018`, and `TST-024` as release blockers until native advisory triage, remediation/VEX decisions, reproducible build or signed source-to-binary build attestation, artifact signing and signed provenance, Marketplace/public install, previous-stable upgrade/rollback, final SBOM/NOTICE review, and broader accessibility evidence are complete.

## M7l2c Implemented Slice

The third M7l2 slice adds a native advisory triage input-contract gate without claiming triage, remediation, or VEX approval:

- `scripts/release/generate-native-advisory-triage-input.ps1` writes `subversionr.release.native-advisory-triage-input.win32-x64.v1` from the M7l2b native advisory evidence.
- The generator re-reads the M7l2a live OSV evidence referenced by M7l2b, verifies the referenced SHA256, and rejects stale M7l2b evidence before creating any triage input rows.
- The evidence creates one release-blocking triage/remediation/VEX input row for every M7l2b native source-lock component and one row for every M7l2a live OSV finding.
- Each row keeps current triage, remediation, and VEX status as `pending`, records reviewer and analysis-evidence requirements as inputs, and requires analysis evidence before any later approval gate can make an exploitability or VEX claim.
- `scripts/release/verify-native-advisory-triage-input.ps1` rejects public-readiness claims, vulnerability/native-review/triage/remediation/VEX completion overclaims, stale or hash-drifted upstream evidence, missing/extra/duplicate input rows, credential-like evidence, schema mismatch, target mismatch, and output paths outside generated evidence roots.
- `scripts/tests/release-native-advisory-triage-input-scripts.tests.ps1` covers positive generation/verification, output-root containment, stale M7l2b evidence, missing row rejection, extra row rejection, completion overclaim rejection, upstream hash drift, credential-like evidence rejection, package scripts, CI wiring, and release-readiness verifier terms.
- Windows CI runs the script tests, then generates and verifies the real `win32-x64` native advisory triage input evidence immediately after M7l2b verification.

This slice intentionally does not complete native advisory review, complete live OSV finding triage, approve remediation, approve VEX decisions, assert reachability or exploitability, prove reproducible builds or signed source-to-binary build attestation, complete final SBOM/NOTICE legal review, sign artifacts, publish attestations, install from Marketplace, prove previous-stable upgrade/rollback, or claim public release readiness.

## M7l2c Gates

- `pnpm release:test-native-advisory-triage-input-scripts` must pass.
- `pnpm release:generate-native-advisory-triage-input:win32-x64` must run after `pnpm release:verify-native-advisory-review:win32-x64`.
- `pnpm release:verify-native-advisory-triage-input:win32-x64` must reject stale upstream evidence, credential, M7l2b hash, M7l2a hash, missing/extra/duplicate input row, triage/remediation/VEX completion, vulnerability-completion, public-readiness, schema, or target overclaims.
- `pnpm release:verify-readiness` must keep `SEC-015`, `MIG-009`, `MIG-010`, `MIG-012`, `TST-018`, and `TST-024` as release blockers until native/OSV triage decisions, remediation/VEX approval, reproducible build or signed source-to-binary build attestation, artifact signing and signed provenance, Marketplace/public install, previous-stable upgrade/rollback, final SBOM/NOTICE review, and broader accessibility evidence are complete.

## M7l2d Implemented Slice

The fourth M7l2 slice adds a vulnerability decision evidence gate without claiming public release readiness:

- `docs/security/vulnerability-decisions.win32-x64.json` records the explicit decision input contract for every current M7l2c native component row. Rows may be terminal only when a later input gate verifies source-lock, advisory-source, artifact-map, and status-specific evidence; `under_investigation` remains non-terminal and release-blocking.
- `scripts/release/generate-vulnerability-decision-evidence.ps1` consumes the M7l2c triage input evidence and the decision input contract, verifies upstream SHA256 bindings, and writes `subversionr.release.vulnerability-decision-evidence.win32-x64.v1`.
- The generator requires one decision row for every M7l2c row and rejects missing, extra, duplicate, or schema/target-drifted rows. It does not create decisions from defaults.
- Terminal VEX decisions are limited to `not_affected`, `affected`, and `fixed`; `under_investigation` is allowed only as a non-terminal release-blocking state.
- Terminal `not_affected` decisions require an allowed VEX justification, `affected` decisions require an action statement and remain release-blocking, and `fixed` decisions require fixed-version evidence.
- `scripts/release/verify-vulnerability-decision-evidence.ps1` rejects public-readiness claims, completion overclaims, upstream hash drift, decision-input hash drift, invalid status combinations, credential-like evidence, schema mismatch, target mismatch, and evidence outside generated roots.
- `scripts/tests/release-vulnerability-decision-evidence-scripts.tests.ps1` covers blocked evidence, complete terminal fixture evidence, missing/extra rows, invalid status-specific evidence, under-investigation overclaims, completion overclaims, credential-like evidence rejection, package scripts, CI wiring, and release-readiness verifier terms.
- The local release gate runs the script tests, then generates and verifies the real `win32-x64` vulnerability decision evidence immediately after M7l2c verification.

This slice intentionally does not assert that native dependencies are vulnerability-free, approve public release readiness, prove reproducible builds or signed source-to-binary build attestation, complete final SBOM/NOTICE legal review, sign artifacts, publish attestations, install from Marketplace, or prove previous-stable upgrade/rollback.

## M7l2d Gates

- `pnpm release:test-vulnerability-decision-evidence-scripts` must pass.
- `pnpm release:generate-vulnerability-decision-evidence:win32-x64` must run after `pnpm release:verify-native-advisory-triage-input:win32-x64`.
- `pnpm release:verify-vulnerability-decision-evidence:win32-x64` must reject credential, M7l2c hash, decision-input hash, missing/extra/duplicate decision row, invalid VEX status, missing justification/action/fix evidence, completion overclaim, public-readiness, schema, or target overclaims.
- `pnpm release:verify-readiness` must keep `SEC-015`, `MIG-009`, `MIG-010`, `MIG-012`, `TST-018`, and `TST-024` as release blockers until terminal vulnerability decisions, remediation approval for affected findings, reproducible build or signed source-to-binary build attestation, artifact signing and signed provenance, Marketplace/public install, previous-stable upgrade/rollback, final SBOM/NOTICE review, and broader accessibility evidence are complete.

## M7l2e Implemented Slice

The fifth M7l2 slice adds the M7l2e vulnerability decision input terminal-progress gate without claiming public release readiness:

- `scripts/release/verify-vulnerability-decision-input.ps1` validates `docs/security/vulnerability-decisions.win32-x64.json` against `native/sources.lock.json`, `docs/security/native-advisory-sources.lock.json`, `docs/release/native-artifact-map.win32-x64.json`, and the M7l2f manual review input.
- The verifier requires one decision row per exact native source-lock `(name, version)` key, rejects extra rows, rejects public-readiness/completion claims in the decision input, rejects credential-like text, and requires terminal decisions to be reviewed within 90 days.
- Terminal decisions must use allowed VEX statuses and status-specific evidence: `fixed` requires `fixedVersion` equal to the locked source version plus `fixEvidence`; `not_affected` requires an allowed justification; `affected` requires a remediation action statement and remains release-blocking.
- Components whose advisory source contract has no dedicated advisory index require an M7l2f manual terminal grant before the decision input may use a terminal VEX status.
- `component_not_present` is accepted only when the native artifact map marks the component as `fixture-runtime`; this currently applies to Apache HTTP Server and PCRE2 fixture inputs.
- The current `win32-x64` decision input records 11 terminal decisions and 0 remaining `under_investigation` decisions. Apache Subversion 1.14.5, OpenSSL 3.5.7, SQLite 3.53.2, Expat 2.8.1, APR 1.7.6, APR-util 1.6.3, and Serf 1.3.10 are recorded as `fixed`; Apache HTTP Server 2.4.68 and PCRE2 10.47 are recorded as `not_affected` because they are fixture-only and not shipped in the VSIX backend runtime; zlib 1.3.2 is recorded as `not_affected` for CVE-2026-22184 because SubversionR does not build or ship the vulnerable standalone `contrib/untgz` utility; APR-iconv 1.2.2 is recorded as `not_affected` for the named source-review finding `APR-ICONV-1.2.2-NO-PUBLISHED-ADVISORY`.
- `release:generate-vulnerability-decision-evidence:win32-x64` now runs the M7l2f manual review verifier and the decision input verifier before generating the M7l2d evidence, so the local evidence path cannot bypass the terminal-progress gate.
- `scripts/tests/release-vulnerability-decision-input-scripts.tests.ps1` covers positive verification, terminal rejection without a manual terminal grant, `component_not_present` package-mode rejection, source-lock version drift, unknown evidence source IDs, stale terminal reviews, public-readiness claim rejection, package scripts, and release-readiness verifier terms.

This slice intentionally does not assert that native dependencies are vulnerability-free, approve public release readiness, prove reproducible builds or signed source-to-binary build attestation, complete final SBOM/NOTICE legal review, sign artifacts, publish attestations, install from Marketplace, or prove previous-stable upgrade/rollback.

## M7l2e Gates

- `pnpm release:test-vulnerability-decision-input-scripts` must pass.
- `pnpm release:verify-vulnerability-decision-input:win32-x64` must reject source-lock drift, advisory-source drift, artifact-map package-mode drift, credential-like evidence, stale terminal reviews, terminal decisions without an M7l2f manual terminal grant, `component_not_present` overclaims, public-readiness claims, schema drift, or target drift.
- `pnpm release:generate-vulnerability-decision-evidence:win32-x64` must run the M7l2f manual review verifier and the decision input verifier before writing M7l2d evidence.
- `pnpm release:verify-readiness` must keep `SEC-015`, `MIG-009`, `MIG-010`, `MIG-012`, `TST-018`, and `TST-024` as release blockers until all vulnerability decisions are terminal, affected decisions have approved remediation, reproducible build or signed source-to-binary build attestation exists, artifact signing and signed provenance are complete, Marketplace/public install exists, previous-stable upgrade/rollback is proven, final SBOM/NOTICE review is complete, and broader accessibility evidence is complete.

## M7l2f Implemented Slice

The sixth M7l2 slice adds the M7l2f manual native advisory terminal-review gate, a local, source-controlled terminal review path for native components whose advisory source contract has no dedicated advisory index:

- `docs/security/native-manual-advisory-review.win32-x64.json` uses schema `subversionr.security.native-manual-advisory-review.win32-x64.v1` and records one manual review row for each current no-dedicated-index source-lock component: Serf, APR, APR-util, APR-iconv, Expat, and zlib.
- `scripts/release/verify-native-manual-advisory-review.ps1` derives the required manual row set from `native/sources.lock.json` and `docs/security/native-advisory-sources.lock.json`, rejects missing/extra rows, and rejects dedicated-index components in the manual path.
- Terminal grants require exact component/version/package-mode binding, source-contract evidence IDs, fresh review timestamps, CVE or named security-finding mapping to the locked version, and two distinct reviewer approvals.
- The current manual review input grants six terminal decisions: Expat 2.8.1 is fixed for CVE-2026-45186 through the M7l2g terminal grant, zlib 1.3.2 is not_affected for CVE-2026-22184 through the M7l2h terminal grant, APR 1.7.6 is fixed for CVE-2023-49582, CVE-2022-24963, CVE-2022-28331, and CVE-2021-35940 through the M7l2i terminal grant, APR-util 1.6.3 is fixed for CVE-2022-25147 and CVE-2017-12618 through the M7l2j terminal grant, Serf 1.3.10 is fixed for CVE-2014-3504 through the M7l2k terminal grant, and APR-iconv 1.2.2 is not_affected for `APR-ICONV-1.2.2-NO-PUBLISHED-ADVISORY` through the M7l2l terminal grant.
- `release:verify-vulnerability-decision-input:win32-x64` and `release:generate-vulnerability-decision-evidence:win32-x64` run the manual review verifier before decision verification, and direct `verify-vulnerability-decision-input.ps1` invocation requires the same manual review input.
- `scripts/tests/release-native-manual-advisory-review-scripts.tests.ps1` covers positive verification, missing row rejection, dedicated-row rejection, terminal grant rejection without finding mapping, terminal grant rejection without two approvals, stale review rejection, public-readiness claim rejection, terminal decision rejection without a matching grant, terminal fixed acceptance with finding mapping and approvals, package scripts, and release-readiness verifier terms.

This slice intentionally does not assert that native dependencies are vulnerability-free, approve public release readiness, prove reproducible builds or signed source-to-binary build attestation, complete final SBOM/NOTICE legal review, sign artifacts, publish attestations, install from Marketplace, or prove previous-stable upgrade/rollback.

## M7l2f Gates

- `pnpm release:test-native-manual-advisory-review-scripts` must pass.
- `pnpm release:verify-native-manual-advisory-review:win32-x64` must reject source-lock drift, advisory-source drift, artifact-map package-mode drift, missing or extra manual rows, dedicated-index manual rows, stale review rows, weak terminal grants, single-reviewer terminal grants, terminal decisions without matching grants, credential-like evidence, public-readiness claims, schema drift, or target drift.
- `pnpm release:verify-vulnerability-decision-input:win32-x64` must run after the manual review gate and must require a matching manual terminal grant for any no-dedicated-index component that becomes terminal.
- `pnpm release:verify-readiness` must keep `SEC-015`, `MIG-009`, `MIG-010`, `MIG-012`, `TST-018`, and `TST-024` as release blockers until all vulnerability decisions are terminal, affected decisions have approved remediation, reproducible build or signed source-to-binary build attestation exists, artifact signing and signed provenance are complete, Marketplace/public install exists, previous-stable upgrade/rollback is proven, final SBOM/NOTICE review is complete, and broader accessibility evidence is complete.

## M7l2g Implemented Slice

The seventh M7l2 slice uses the M7l2f manual terminal-review path to record a narrow Expat terminal decision without claiming broader native dependency readiness:

- M7l2g Expat terminal CVE-2026-45186 decision gate records a local, source-controlled terminal decision for exactly `native:expat@2.8.1`.
- `docs/security/native-manual-advisory-review.win32-x64.json` grants `native:expat@2.8.1` a terminal `fixed` status only for `CVE-2026-45186`, with `fixedVersion: "2.8.1"`, one `terminalFindings` CVE mapping, and two distinct approvals.
- `docs/security/vulnerability-decisions.win32-x64.json` records the matching `fixed` decision for Expat 2.8.1.
- The official Expat 2.8.1 changelog evidence at `https://raw.githubusercontent.com/libexpat/libexpat/R_2_8_1/expat/Changes` is the source-contract evidence for the fixed decision.
- `scripts/tests/release-expat-terminal-decision-scripts.tests.ps1` checks the real source-controlled manual review and vulnerability decision inputs for the exact `native:expat@2.8.1`/`CVE-2026-45186` scope, two approvals, local package script exposure, and release-readiness verifier terms.
- Ask Gemini preflight confirmed OpenCode availability, but the consultation call timed out; this slice uses local official-source evidence plus the read-only subagent release-security review as the independent second approval.

This slice intentionally does not assert that Expat 2.8.1 is free of all known or unknown vulnerabilities, approve public release readiness, prove reproducible builds or signed source-to-binary build attestation, complete final SBOM/NOTICE legal review, sign artifacts, publish attestations, install from Marketplace, or prove previous-stable upgrade/rollback.

## M7l2g Gates

- `pnpm release:test-expat-terminal-decision-scripts` must pass.
- `pnpm release:verify-native-manual-advisory-review:win32-x64` must accept the Expat terminal grant only while the finding mapping, fixed version, approvals, source-contract IDs, and matching decision row remain exact.
- `pnpm release:verify-vulnerability-decision-input:win32-x64` must keep the Expat decision terminal only while it has its matching M7l2f-compliant grant.
- `pnpm release:verify-readiness` must keep `SEC-015`, `MIG-009`, `MIG-010`, `MIG-012`, `TST-018`, and `TST-024` as release blockers until all vulnerability decisions are terminal, affected decisions have approved remediation, reproducible build or signed source-to-binary build attestation exists, artifact signing and signed provenance are complete, Marketplace/public install exists, previous-stable upgrade/rollback is proven, final SBOM/NOTICE review is complete, and broader accessibility evidence is complete.

## M7l2h Implemented Slice

The eighth M7l2 slice uses the M7l2f manual terminal-review path to record a narrow zlib terminal decision without claiming broader native dependency readiness:

- M7l2h zlib terminal CVE-2026-22184 decision gate records a local, source-controlled terminal decision for exactly `native:zlib@1.3.2`.
- `docs/security/native-advisory-sources.lock.json` extends the zlib source contract with `zlib-issue-1142` and `nvd-cve-2026-22184` so terminal evidence source IDs remain explicit and gate-checked.
- `docs/security/native-manual-advisory-review.win32-x64.json` grants `native:zlib@1.3.2` a terminal `not_affected` status only for `CVE-2026-22184`, with `vexJustification: "vulnerable_code_not_present"`, one `terminalFindings` CVE mapping, and two distinct approvals.
- `docs/security/vulnerability-decisions.win32-x64.json` records the matching `not_affected` decision for zlib 1.3.2.
- The NVD CVE record and zlib project issue identify the vulnerable code path as the standalone `contrib/untgz` utility; SubversionR's native build stages `zlib.lib` as a static-link input and does not build or ship `untgz`.
- `scripts/tests/release-zlib-terminal-decision-scripts.tests.ps1` checks the real source-controlled source contract, manual review, and vulnerability decision inputs for the exact `native:zlib@1.3.2`/`CVE-2026-22184` scope, two approvals, local package script exposure, and release-readiness verifier terms.
- Ask Gemini/OpenCode consultation timed out and is not counted as approval; this slice uses local official-source evidence plus the read-only subagent release-security review as the independent second approval.

This slice intentionally does not assert that zlib 1.3.2 is free of all known or unknown vulnerabilities, approve public release readiness, prove reproducible builds or signed source-to-binary build attestation, complete final SBOM/NOTICE legal review, sign artifacts, publish attestations, install from Marketplace, or prove previous-stable upgrade/rollback.

## M7l2h Gates

- `pnpm release:test-zlib-terminal-decision-scripts` must pass.
- `pnpm release:verify-native-manual-advisory-review:win32-x64` must accept the zlib terminal grant only while the finding mapping, not_affected justification, impact statement, approvals, source-contract IDs, and matching decision row remain exact.
- `pnpm release:verify-vulnerability-decision-input:win32-x64` must keep the zlib decision terminal only while it has its matching M7l2f-compliant grant.
- `pnpm release:verify-readiness` must keep `SEC-015`, `MIG-009`, `MIG-010`, `MIG-012`, `TST-018`, and `TST-024` as release blockers until all vulnerability decisions are terminal, affected decisions have approved remediation, reproducible build or signed source-to-binary build attestation exists, artifact signing and signed provenance are complete, Marketplace/public install exists, previous-stable upgrade/rollback is proven, final SBOM/NOTICE review is complete, and broader accessibility evidence is complete.

## M7l2i Implemented Slice

The ninth M7l2 slice uses the M7l2f manual terminal-review path to record a narrow APR terminal decision without claiming broader native dependency readiness:

- M7l2i APR terminal CVE decision gate records a local, source-controlled terminal decision for exactly `native:apr@1.7.6`.
- `docs/security/native-advisory-sources.lock.json` extends the APR source contract with `apr-changes-1-7` plus NVD source IDs for CVE-2023-49582, CVE-2022-24963, CVE-2022-28331, and CVE-2021-35940 so terminal evidence source IDs remain explicit and gate-checked.
- `docs/security/native-manual-advisory-review.win32-x64.json` grants `native:apr@1.7.6` a terminal `fixed` status only for CVE-2023-49582, CVE-2022-24963, CVE-2022-28331, and CVE-2021-35940, with `fixedVersion: "1.7.6"`, four `terminalFindings` CVE mappings, and two distinct approvals.
- `docs/security/vulnerability-decisions.win32-x64.json` records the matching `fixed` decision for APR 1.7.6.
- The APR 1.7 changelog records the 1.7.5 fix for CVE-2023-49582 and the 1.7.1 fixes for CVE-2022-24963, CVE-2022-28331, and CVE-2021-35940; the locked packaged runtime source is APR 1.7.6.
- `scripts/tests/release-apr-terminal-decision-scripts.tests.ps1` checks the real source-controlled source contract, manual review, and vulnerability decision inputs for the exact `native:apr@1.7.6` CVE scope, two approvals, local package script exposure, and release-readiness verifier terms.

This slice intentionally does not assert that APR 1.7.6 is free of all known or unknown vulnerabilities, approve public release readiness, prove reproducible builds or signed source-to-binary build attestation, complete final SBOM/NOTICE legal review, sign artifacts, publish attestations, install from Marketplace, or prove previous-stable upgrade/rollback.

## M7l2i Gates

- `pnpm release:test-apr-terminal-decision-scripts` must pass.
- `pnpm release:verify-native-manual-advisory-review:win32-x64` must accept the APR terminal grant only while the finding mappings, fixed version, approvals, source-contract IDs, and matching decision row remain exact.
- `pnpm release:verify-vulnerability-decision-input:win32-x64` must keep the APR decision terminal only while it has its matching M7l2f-compliant grant.
- `pnpm release:verify-readiness` must keep `SEC-015`, `MIG-009`, `MIG-010`, `MIG-012`, `TST-018`, and `TST-024` as release blockers until all vulnerability decisions are terminal, affected decisions have approved remediation, reproducible build or signed source-to-binary build attestation exists, artifact signing and signed provenance are complete, Marketplace/public install exists, previous-stable upgrade/rollback is proven, final SBOM/NOTICE review is complete, and broader accessibility evidence is complete.

## M7l2j Implemented Slice

The tenth M7l2 slice uses the M7l2f manual terminal-review path to record a narrow APR-util terminal decision without claiming broader native dependency readiness:

- M7l2j APR-util terminal CVE decision gate records a local, source-controlled terminal decision for exactly `native:apr-util@1.6.3`.
- `docs/security/native-advisory-sources.lock.json` extends the APR-util source contract with `apr-util-changes-1-6` plus NVD source IDs for CVE-2022-25147 and CVE-2017-12618 so terminal evidence source IDs remain explicit and gate-checked.
- `docs/security/native-manual-advisory-review.win32-x64.json` grants `native:apr-util@1.6.3` a terminal `fixed` status only for CVE-2022-25147 and CVE-2017-12618, with `fixedVersion: "1.6.3"`, two `terminalFindings` CVE mappings, and two distinct approvals.
- `docs/security/vulnerability-decisions.win32-x64.json` records the matching `fixed` decision for APR-util 1.6.3.
- The APR-util 1.6 changelog records the 1.6.2 fix for CVE-2022-25147 and the 1.6.1 SDBM corrupted database validation fix for CVE-2017-12618; the locked packaged runtime source is APR-util 1.6.3.
- `scripts/tests/release-apr-util-terminal-decision-scripts.tests.ps1` checks the real source-controlled source contract, manual review, and vulnerability decision inputs for the exact `native:apr-util@1.6.3` CVE scope, two approvals, local package script exposure, and release-readiness verifier terms.

This slice intentionally does not assert that APR-util 1.6.3 is free of all known or unknown vulnerabilities, approve public release readiness, prove reproducible builds or signed source-to-binary build attestation, complete final SBOM/NOTICE legal review, sign artifacts, publish attestations, install from Marketplace, or prove previous-stable upgrade/rollback.

## M7l2j Gates

- `pnpm release:test-apr-util-terminal-decision-scripts` must pass.
- `pnpm release:verify-native-manual-advisory-review:win32-x64` must accept the APR-util terminal grant only while the finding mappings, fixed version, approvals, source-contract IDs, and matching decision row remain exact.
- `pnpm release:verify-vulnerability-decision-input:win32-x64` must keep the APR-util decision terminal only while it has its matching M7l2f-compliant grant.
- `pnpm release:verify-readiness` must keep `SEC-015`, `MIG-009`, `MIG-010`, `MIG-012`, `TST-018`, and `TST-024` as release blockers until all vulnerability decisions are terminal, affected decisions have approved remediation, reproducible build or signed source-to-binary build attestation exists, artifact signing and signed provenance are complete, Marketplace/public install exists, previous-stable upgrade/rollback is proven, final SBOM/NOTICE review is complete, and broader accessibility evidence is complete.

## M7l2k Implemented Slice

The eleventh M7l2 slice uses the M7l2f manual terminal-review path to record a narrow Serf terminal decision without claiming broader native dependency readiness:

- M7l2k Serf terminal CVE-2014-3504 decision gate records a local, source-controlled terminal decision for exactly `native:serf@1.3.10`.
- `docs/security/native-advisory-sources.lock.json` extends the Serf source contract with the Serf 1.3 changelog plus the NVD source ID for CVE-2014-3504 so terminal evidence source IDs remain explicit and gate-checked.
- `docs/security/native-manual-advisory-review.win32-x64.json` grants `native:serf@1.3.10` a terminal `fixed` status only for CVE-2014-3504, with `fixedVersion: "1.3.10"`, one `terminalFindings` CVE mapping, and two distinct approvals.
- `docs/security/vulnerability-decisions.win32-x64.json` records the matching `fixed` decision for Serf 1.3.10.
- The Serf 1.3 changelog records the 1.3.7 fix that handled NUL bytes in fields of an X.509 certificate; NVD records CVE-2014-3504 as affecting Serf 0.2.0 through 1.3.x before 1.3.7, and the locked static-link input source is Serf 1.3.10.
- `scripts/tests/release-serf-terminal-decision-scripts.tests.ps1` checks the real source-controlled source contract, manual review, and vulnerability decision inputs for the exact `native:serf@1.3.10` CVE scope, two approvals, local package script exposure, and release-readiness verifier terms.

This slice intentionally does not assert that Serf 1.3.10 is free of all known or unknown vulnerabilities, map Apache Subversion CVE-2014-3522 to the Serf library component row, approve public release readiness, prove reproducible builds or signed source-to-binary build attestation, complete final SBOM/NOTICE legal review, sign artifacts, publish attestations, install from Marketplace, or prove previous-stable upgrade/rollback.

## M7l2k Gates

- `pnpm release:test-serf-terminal-decision-scripts` must pass.
- `pnpm release:verify-native-manual-advisory-review:win32-x64` must accept the Serf terminal grant only while the finding mapping, fixed version, approvals, source-contract IDs, and matching decision row remain exact.
- `pnpm release:verify-vulnerability-decision-input:win32-x64` must keep the Serf decision terminal only while it has its matching M7l2f-compliant grant.

## M7l2l Implemented Slice

The twelfth M7l2 slice uses the M7l2f manual terminal-review path to record a narrow APR-iconv terminal named security finding decision without claiming broader native dependency readiness:

- M7l2l APR-iconv terminal named security finding decision gate records a local, source-controlled terminal decision for exactly `native:apr-iconv@1.2.2`.
- `docs/security/native-advisory-sources.lock.json` extends the APR-iconv source contract with Apache APR download metadata, APR-iconv 1.2 CHANGES, apache/apr-iconv GitHub advisories, NVD keyword-search evidence, and OSV query evidence so terminal evidence source IDs remain explicit and gate-checked.
- `docs/security/native-manual-advisory-review.win32-x64.json` grants `native:apr-iconv@1.2.2` a terminal `not_affected` status only for `APR-ICONV-1.2.2-NO-PUBLISHED-ADVISORY`, with `vexJustification: "vulnerable_code_not_present"`, one `terminalFindings` named-security-finding mapping, and two distinct approvals.
- `docs/security/vulnerability-decisions.win32-x64.json` records the matching `not_affected` decision for APR-iconv 1.2.2.
- Apache APR download metadata records APR-iconv 1.2.2 as the best available version and Windows APR-iconv as required for APR-util `apr_xlate`; APR-iconv 1.2.2 CHANGES records only Win32 Visual Studio build fixes; apache/apr-iconv GitHub advisories report no published advisories; manual NVD keyword and OSV repository/package queries returned empty vulnerability results for the APR-iconv review terms.
- `scripts/tests/release-apr-iconv-terminal-decision-scripts.tests.ps1` checks the real source-controlled source contract, manual review, and vulnerability decision inputs for the exact `native:apr-iconv@1.2.2` named finding scope, two approvals, local package script exposure, and release-readiness verifier terms.

This slice intentionally does not assert that APR-iconv 1.2.2 is free of all known or unknown vulnerabilities, approve public release readiness, prove reproducible builds or signed source-to-binary build attestation, complete final SBOM/NOTICE legal review, sign artifacts, publish attestations, install from Marketplace, or prove previous-stable upgrade/rollback.

## M7l2l Gates

- `pnpm release:test-apr-iconv-terminal-decision-scripts` must pass.
- `pnpm release:verify-native-manual-advisory-review:win32-x64` must accept the APR-iconv terminal grant only while the named security-finding mapping, not_affected justification, impact statement, approvals, source-contract IDs, and matching decision row remain exact.
- `pnpm release:verify-vulnerability-decision-input:win32-x64` must keep the APR-iconv decision terminal only while it has its matching M7l2f-compliant grant.
- `pnpm release:verify-readiness` must keep `SEC-015`, `MIG-009`, `MIG-010`, `MIG-012`, `TST-018`, and `TST-024` as release blockers until final SBOM/NOTICE review, final vulnerability release approval, reproducible build or signed source-to-binary build attestation, artifact signing and signed provenance, Marketplace/public install, previous-stable upgrade/rollback, and broader accessibility evidence are complete.
- `pnpm release:verify-readiness` must keep `SEC-015`, `MIG-009`, `MIG-010`, `MIG-012`, `TST-018`, and `TST-024` as release blockers until all vulnerability decisions are terminal, affected decisions have approved remediation, reproducible build or signed source-to-binary build attestation exists, artifact signing and signed provenance are complete, Marketplace/public install exists, previous-stable upgrade/rollback is proven, final SBOM/NOTICE review is complete, and broader accessibility evidence is complete.

## M7l3 Implemented Slice

The M7l3 slice adds a native source-lock artifact map preflight without claiming reproducible builds, source-to-binary compilation proof, or signed release provenance:

- `docs/release/native-artifact-map.win32-x64.json` records a closed package-role map for every current `native/sources.lock.json` component. The only allowed roles are `packaged-runtime`, `static-link-input`, and `fixture-runtime`; unknown roles, missing source-lock entries, extra mapped entries, and missing non-shipping reasons fail fast.
- `scripts/release/generate-native-artifact-map-preflight.ps1` consumes the native source lock, artifact map input, backend package manifest, and VSIX package evidence, verifies all input hashes and staged artifact hashes, and writes `subversionr.release.native-artifact-map-preflight.win32-x64.v1`.
- The real `win32-x64` evidence currently maps 11 native source-lock components, 229 packaged `nativeDependency` artifacts, and 2 first-party sidecar/bridge artifacts. Apache Subversion, OpenSSL, APR, APR-util, APR-iconv, and Expat have packaged runtime mappings; Serf, zlib, and SQLite are explicit static-link inputs; Apache HTTP Server and PCRE2 are explicit fixture-runtime inputs.
- `scripts/release/verify-native-artifact-map-preflight.ps1` rejects public-readiness, reproducible-build, signed-attestation, hash-drift, package-mode, missing-non-claim, credential-like evidence, schema, target, package-root, or artifact-byte drift overclaims.
- `scripts/tests/release-native-artifact-map-scripts.tests.ps1` covers positive generation/verification, staged artifact drift, missing/extra source-map coverage, missing required artifacts, unknown package modes, missing non-shipping reasons, reproducible-build overclaims, output-root containment, package scripts, and CI wiring.
- Windows CI runs the script tests, then generates and verifies the real `win32-x64` native artifact map preflight after VSIX package evidence exists and before the broader local release provenance preflight.

This slice intentionally does not prove reproducible builds, prove that staged binaries were compiled from the locked source archives, sign artifacts, publish or verify GitHub artifact attestations, complete terminal vulnerability decisions, approve remediation, complete final SBOM/NOTICE legal review, install from Marketplace, prove previous-stable upgrade/rollback, or claim public release readiness.

## M7l3 Gates

- `pnpm release:test-native-artifact-map-scripts` must pass.
- `pnpm release:generate-native-artifact-map:win32-x64` must run after `pnpm release:package-vsix:win32-x64`.
- `pnpm release:verify-native-artifact-map:win32-x64` must reject source-lock hash drift, artifact-map hash drift, backend-manifest hash drift, VSIX-evidence hash drift, missing/extra source component coverage, unmapped packaged native artifacts, unknown package modes, non-shipping rows without reasons, reproducible-build overclaims, signed-attestation overclaims, public-readiness overclaims, schema drift, target drift, or staged artifact byte drift.
- `pnpm release:verify-readiness` must keep `SEC-015`, `MIG-009`, `MIG-010`, `MIG-012`, `TST-018`, and `TST-024` as release blockers until terminal vulnerability decisions, remediation approval for affected findings, reproducible build or signed source-to-binary build attestation, artifact signing and signed provenance, Marketplace/public install, previous-stable upgrade/rollback, final SBOM/NOTICE review, and broader accessibility evidence are complete.

## M7l4 Implemented Slice

The M7l4 slice adds a malicious-input corpus preflight without claiming coverage-guided fuzzing or complete native remote-protocol fuzz coverage:

- `docs/security/malicious-input-corpus.win32-x64.json` records deterministic malicious-input categories for unsafe paths, credential-bearing URL redaction, log rendering, JSON-RPC response shape handling, native SVN server responses, and XML/DTD payloads.
- Covered entries must name exact repository test files and exact test names. Missing files, renamed tests, duplicate entry IDs, unsupported trace IDs, undeclared categories, or credential-like payload text fail fast.
- Release-blocker entries must record explicit blockers. Current real corpus keeps native SVN server-response coverage blocked instead of treating JSON-RPC, TypeScript log-rendering, or DAV/XML fixture tests as complete native server-response evidence.
- `scripts/release/generate-malicious-input-corpus.ps1` consumes the corpus manifest and security evidence matrix, verifies `SEC-016` and `TST-020` remain release-blocker, binds input hashes, and writes `subversionr.release.malicious-input-corpus.win32-x64.v1`.
- `scripts/release/verify-malicious-input-corpus.ps1` rejects public-readiness claims, complete-fuzz claims, credential-like evidence, input hash drift, test-source hash drift, missing non-claims, schema drift, target drift, and missing blocker entries.
- `scripts/tests/release-malicious-input-corpus-scripts.tests.ps1` covers positive generation/verification, test drift, missing test evidence, missing blockers, security-matrix overclaims, complete-fuzz overclaims, credential-like payload rejection, output-root containment, package scripts, and CI wiring.
- The TypeScript revision-details document renderer escapes control characters in untrusted SVN log messages so CR/LF and NUL payloads cannot create synthetic document section breaks while HTML/XML-like text remains inert text.
- Windows CI runs the script tests, then generates and verifies the real `win32-x64` malicious-input corpus preflight after TypeScript and Rust tests pass.

This slice intentionally does not perform coverage-guided fuzzing, prove complete libsvn remote-protocol fuzz coverage, assert arbitrary remote-server safety, close `SEC-016` or `TST-020`, install from Marketplace, or claim public release readiness.

## M7l4 Gates

- `pnpm release:test-malicious-input-corpus-scripts` must pass.
- `pnpm release:generate-malicious-input-corpus:win32-x64` must run after the focused TypeScript and Rust tests it references have passed.
- `pnpm release:verify-malicious-input-corpus:win32-x64` must reject input hash drift, test-source hash drift, missing/extra/duplicate corpus evidence, missing blockers, complete-fuzz overclaims, public-readiness overclaims, credential-like payload evidence, schema drift, target drift, or evidence outside generated roots.
- `pnpm release:verify-readiness` must keep `SEC-016` and `TST-020` as release blockers until coverage-guided native remote-protocol fuzzing has release evidence.

## M7l5 Implemented Slice

The M7l5 slice adds a deterministic native malicious DAV/XML fixture without claiming coverage-guided fuzzing or arbitrary DAV server safety:

- `crates/subversionr-daemon/tests/native_bridge.rs` now contains `native_bridge_malicious_dav_xml_history_log_fails_without_auth_prompts_or_crash`, an ignored native bridge test that creates a source-built local working copy, relocates it to a localhost DAV fixture with the same repository UUID, switches the fixture from valid OPTIONS/XML to malicious DTD/external-entity/malformed XML mode, and proves `history_log` returns the stable `SVN_HISTORY_LOG_FAILED` key without credential or certificate prompts.
- `scripts/native/smoke-malicious-dav-xml.ps1` exposes the exact ignored Rust test as a native smoke entrypoint that requires the staged bridge, `libsvn_client-1.dll`, `libsvn_ra-1.dll`, and `libsvn_subr-1.dll`.
- `native:smoke-malicious-dav-xml:staged` and Windows CI run the deterministic native DAV/XML smoke after the source-built native bridge is built and smoke-tested.
- `docs/security/malicious-input-corpus.win32-x64.json` maps `NATIVE-XML-DAV-001` to the exact Rust fixture test while the separate native remote-protocol fuzzing entry remains release-blocker.

This slice intentionally does not implement coverage-guided fuzzing, prove arbitrary DAV server safety, exercise installed VSIX behavior, close `SEC-016` or `TST-020`, install from Marketplace, or claim public release readiness.

## M7l5 Gates

- `pnpm native:test-scripts` must prove the new native smoke wrapper, package script, exact Rust test name, and CI step stay wired.
- `pnpm native:smoke-malicious-dav-xml:staged` must pass against the source-built native bridge runtime.
- `pnpm release:generate-malicious-input-corpus:win32-x64` and `pnpm release:verify-malicious-input-corpus:win32-x64` must treat `NATIVE-XML-DAV-001` as covered and keep a separate native remote-protocol fuzzing entry as release-blocker.
- `pnpm release:verify-readiness` must keep `SEC-016` and `TST-020` as release blockers until coverage-guided native remote-protocol fuzzing has release evidence.

## M7l6 Implemented Slice

The M7l6 slice adds a deterministic native malicious `svn://` server-response fixture without claiming coverage-guided fuzzing or arbitrary `svn://` server safety:

- `crates/subversionr-daemon/tests/native_bridge.rs` now contains `native_bridge_malicious_svn_server_response_history_log_fails_without_auth_prompts_or_crash`, an ignored native bridge test that creates a source-built authenticated `svnserve` working copy, proves a real control `history_log` succeeds through `libsvn`, stops the real server, binds a stateful malicious loopback `svn://` responder to the same port, and proves a malformed log response returns the stable `SVN_HISTORY_LOG_FAILED` key without credential or certificate prompts.
- `scripts/native/smoke-malicious-svn-server-response.ps1` exposes the exact ignored Rust test as a native smoke entrypoint that requires the staged bridge, source-built `svn.exe`, `svnadmin.exe`, `svnserve.exe`, `libsvn_client-1.dll`, `libsvn_ra-1.dll`, and `libsvn_subr-1.dll`.
- `native:smoke-malicious-svn-server-response:staged` and the scheduled/manual Windows workflow run the deterministic native `svn://` server-response smoke after the source-built native bridge is built and smoke-tested.
- `docs/security/malicious-input-corpus.win32-x64.json` maps `NATIVE-SVN-SERVER-001` to the exact Rust fixture test and keeps `NATIVE-REMOTE-FUZZ-001` as the release-blocker entry for coverage-guided libsvn remote-protocol fuzzing.

This slice intentionally does not implement coverage-guided fuzzing, prove arbitrary `svn://` server safety, exercise installed VSIX behavior, close `SEC-016` or `TST-020`, install from Marketplace, or claim public release readiness.

## M7l6 Gates

- `pnpm native:test-scripts` must prove the new native smoke wrapper, package script, exact Rust test name, and workflow step stay wired.
- `pnpm native:smoke-malicious-svn-server-response:staged` must pass against the source-built native bridge runtime.
- `pnpm release:generate-malicious-input-corpus:win32-x64` and `pnpm release:verify-malicious-input-corpus:win32-x64` must treat `NATIVE-SVN-SERVER-001` as covered and keep `NATIVE-REMOTE-FUZZ-001` as release-blocker.
- `pnpm release:verify-readiness` must keep `SEC-016` and `TST-020` as release blockers until coverage-guided native remote-protocol fuzzing has release evidence.

## M7l7 Implemented Slice

The M7l7 slice adds a native remote-protocol fuzz readiness contract without claiming coverage-guided fuzzing or libsvn sanitizer coverage:

- `docs/security/native-remote-fuzz-contract.win32-x64.json` records the first future fuzz target contract for `svn://` history/log responses, with `publicReadinessClaim`, `completeFuzzClaim`, and `coverageGuidedLibsvnClaim` all false.
- The contract requires nightly `x86_64-pc-windows-msvc` Rust, `cargo-fuzz`, MSVC `cl.exe`, `/fsanitize=fuzzer`, `/fsanitize=address`, source-built libsvn/APR/bridge sanitizer coverage instrumentation, a seed corpus, run evidence, and coverage evidence before any future coverage-guided claim is allowed.
- `scripts/release/generate-native-remote-fuzz-contract.ps1` consumes the contract, the malicious input corpus, and the security evidence matrix, verifies that `SEC-016`, `TST-020`, and `NATIVE-REMOTE-FUZZ-001` remain blocked, records local toolchain observations without command paths or credentials, and writes `subversionr.release.native-remote-fuzz-contract.win32-x64.v1`.
- `scripts/release/verify-native-remote-fuzz-contract.ps1` re-reads all input hashes, rejects public-readiness, complete-fuzz, and coverage-guided-libsvn overclaims, and confirms sanitizer coverage remains `not-proven`.
- `scripts/tests/release-native-remote-fuzz-contract-scripts.tests.ps1` covers positive generation/verification, output-root containment, security-matrix overclaims, malicious-corpus blocker drift, input hash drift, missing non-claims, credential-like text rejection, and package scripts.

This slice intentionally does not create a fuzzer target, run `cargo fuzz`, prove source-built libsvn sanitizer coverage, discover crashes, prove libsvn edge growth, cover DAV or `svn+ssh` providers, close `SEC-016` or `TST-020`, install from Marketplace, or claim public release readiness.

## M7l7 Gates

- `pnpm release:test-native-remote-fuzz-contract-scripts` must pass locally.
- `pnpm release:generate-native-remote-fuzz-contract:win32-x64` and `pnpm release:verify-native-remote-fuzz-contract:win32-x64` must pass against the real repository contract, malicious corpus, and security matrix.
- `pnpm release:verify-readiness` must require the M7l7 contract docs, package scripts, public claim row, security evidence row text, and roadmap entry while keeping `SEC-016` and `TST-020` as release blockers.
- This heavy gate remains scheduled/manual and is not part of automatic pull-request validation.

## M7l8 Implemented Slice

The M7l8 slice adds the first source-controlled native remote-protocol fuzz target preflight without claiming a fuzz build, fuzz run, seed execution, sanitizer coverage, edge growth, crash discovery, or public release readiness:

- `fuzz/Cargo.toml` defines an independent `subversionr-native-remote-fuzz` cargo-fuzz package with `libfuzzer-sys` pinned to `=0.4.13`, package metadata `cargo-fuzz = true`, and a single `svn_server_response_history_log` binary target.
- `fuzz/fuzz_targets/svn_server_response_history_log.rs` defines the bounded source preflight target for `svn://` history/log response bytes, rejects empty or oversized inputs, records the `NATIVE-REMOTE-FUZZ-001` trace scope in source, and intentionally avoids network, process, filesystem, unsafe, and FFI APIs.
- `fuzz/corpus/svn_server_response_history_log/manifest.json` binds `malicious-log-response-v1` to a SHA256 hash and provenance from the M7l6 malicious `svn://` history/log fixture shape while keeping seed execution and coverage evidence false.
- `docs/security/native-remote-fuzz-contract.win32-x64.json` now records `sourcePreflight` paths and moves `fuzzer-target` and `seed-corpus` required evidence to `source-created`, while `instrumented-libsvn-build`, `run-evidence`, and `coverage-evidence` remain blocked.
- `scripts/release/generate-native-remote-fuzz-target-preflight.ps1` consumes the contract, malicious corpus, security matrix, fuzz package manifest, fuzz target source, and seed manifest, verifies all input hashes and source-only constraints, and writes `subversionr.release.native-remote-fuzz-target-preflight.win32-x64.v1`.
- `scripts/release/verify-native-remote-fuzz-target-preflight.ps1` re-reads every bound input, rejects source drift and overclaims, confirms `SEC-016`, `TST-020`, and `NATIVE-REMOTE-FUZZ-001` remain blocked, and verifies the evidence still says no build/run/seed execution/coverage occurred.
- `scripts/tests/release-native-remote-fuzz-target-preflight-scripts.tests.ps1` covers positive generation/verification, network/process/filesystem/unsafe/FFI source rejection, missing sourcePreflight contract fields, security-matrix overclaims, malicious-corpus blocker drift, seed hash drift, evidence overclaims, input hash drift, output-root containment, and package scripts.

This slice intentionally does not compile, link, run, or execute `cargo-fuzz`, execute seed files, prove source-built libsvn sanitizer coverage, discover crashes, prove libsvn edge growth, cover DAV or `svn+ssh` providers, close `SEC-016` or `TST-020`, install from Marketplace, or claim public release readiness.

## M7l8 Gates

- `pnpm release:test-native-remote-fuzz-target-preflight-scripts` must pass locally.
- `pnpm release:generate-native-remote-fuzz-target-preflight:win32-x64` and `pnpm release:verify-native-remote-fuzz-target-preflight:win32-x64` must pass against the real repository contract, malicious corpus, security matrix, fuzz target source, and seed manifest.
- `pnpm release:verify-readiness` must require the M7l8 source preflight docs, package scripts, public claim row, security evidence row text, roadmap entry, and manual-only GitHub Actions trigger state while keeping `SEC-016` and `TST-020` as release blockers.
- The source-only target preflight runs in PR Fast; coverage-guided and fixed-seed build/run evidence remains outside the automatic pull-request gate.

## M7l9 Implemented Slice

The M7l9 slice adds the first local cargo-fuzz fixed seed harness smoke without claiming libsvn FFI reachability, coverage-guided fuzzing, sanitizer-instrumented libsvn coverage, edge growth, crash discovery, or public release readiness:

- `fuzz/Cargo.lock` is source-controlled so the fuzz harness dependency graph is pinned alongside `fuzz/Cargo.toml`.
- `docs/security/native-remote-fuzz-contract.win32-x64.json` now records the `fixed-seed-smoke` required evidence row as `local-smoke-required`, while `instrumented-libsvn-build`, `run-evidence`, and `coverage-evidence` remain blocked.
- `scripts/release/generate-native-remote-fuzz-fixed-seed-smoke.ps1` consumes the contract, malicious corpus, security matrix, fuzz manifest, fuzz lock, target source, and seed manifest, enters the explicit VS Build Tools x64 developer environment, runs `cargo fuzz --version`, `cargo +nightly --version`, `cargo +nightly fuzz build svn_server_response_history_log`, executes only the SHA256-bound `malicious-log-response-v1` seed with `cargo +nightly fuzz run ... -- -runs=1 -max_total_time=30`, records `libsvnFfiReached=false`, and writes `subversionr.release.native-remote-fuzz-fixed-seed-smoke.win32-x64.v1`.
- `scripts/release/verify-native-remote-fuzz-fixed-seed-smoke.ps1` re-reads every bound input, rejects hash drift and overclaims, confirms `SEC-016`, `TST-020`, and `NATIVE-REMOTE-FUZZ-001` remain blocked, and verifies the evidence still says libsvn FFI reachability, coverage-guided fuzzing, and coverage evidence did not occur.
- `scripts/tests/release-native-remote-fuzz-fixed-seed-smoke-scripts.tests.ps1` covers positive generation/verification, fixed seed run failure, missing `fixed-seed-smoke` evidence id, security-matrix overclaims, evidence overclaims, input hash drift, output-root containment, and package scripts.

This slice intentionally does not call libsvn, run a coverage-guided campaign, prove source-built libsvn sanitizer coverage, discover crashes, prove libsvn edge growth, cover DAV or `svn+ssh` providers, close `SEC-016` or `TST-020`, install from Marketplace, or claim public release readiness.

## M7l9 Gates

- `pnpm release:test-native-remote-fuzz-fixed-seed-smoke-scripts` must pass locally.
- `pnpm release:generate-native-remote-fuzz-fixed-seed-smoke:win32-x64` and `pnpm release:verify-native-remote-fuzz-fixed-seed-smoke:win32-x64` must pass against the real repository contract, malicious corpus, security matrix, fuzz manifest, fuzz lock, target source, seed manifest, local nightly toolchain, cargo-fuzz, and explicit VS Build Tools developer command.
- `pnpm release:verify-readiness` must require the M7l9 fixed seed harness smoke docs, package scripts, public claim row, security evidence row text, roadmap entry, and manual-only GitHub Actions trigger state while keeping `SEC-016` and `TST-020` as release blockers.
- This heavy fixed-seed build/run gate remains scheduled/manual and is not part of automatic pull-request validation.

## Windows Beta Packaging Slices

This section records the Windows `win32-x64` Beta packaging-readiness slices for local file-backed SVN workflows. They do not broaden the Beta feature set or convert public-release blockers into Beta blockers.

- Beta-A: keep the public engineering guide, roadmap, release gates, public claim matrix, and requirement evidence aligned with current packaging evidence.
- Beta-B: covered by installed VSIX E2E coverage for the local-file Checkout SVN Repository… prompt cancellation, pre-existing obstructing target file failure/no-state-pollution flow, invalid URL failure/no-state-pollution flow, pre-existing local directory target success path, pre-existing local directory obstruction tree-conflict projection path, and happy path: no-repository welcome, cancellation without checkout state pollution, obstructing-file failure without checkout state pollution, invalid-URL failure without checkout state pollution, existing-directory local file preservation plus unversioned projection, obstruction preservation plus tree-conflict projection and working-copy oracle confirmation, prompt flow, libsvn checkout, automatic repository open, Source Control projection, and repository-baseline content oracle. Follow-up checkout negative-flow coverage must still cover repository browser, remote/auth/certificate, and broader checkout failure cases.
- Beta-C: covered by M7j3 installed VSIX E2E evidence for local-file update to revision, revision prompt cancellation without working-copy or Source Control projection mutation, update depth, sticky depth, externals policy prompt selection, post-update reconcile behavior, and repository-oracle content comparison; follow-up update coverage must still cover remote failures, auth/certificate flows, backend failure UX, mixed-revision edge analysis, and load behavior.
- Beta-D: covered by M7j3 installed VSIX E2E evidence for local-file Add to Ignore/`svn:ignore`, changelist grouping, Set/Clear Changelist, Commit Changelist, Revert Changelist, prompt capture, and repository/working-copy oracles. Follow-up property and changelist coverage must still cover full property editor UX, `svn:externals` editing, broad load behavior, cancellation UX, remote/auth/certificate behavior, and commit template/message-history behavior.
- Beta-E: covered by M7j3 installed VSIX E2E evidence for local-file Lock/Unlock/`svn:needs-lock` projection, local Lock message and Unlock mode prompt cancellation only, Branch/Tag create, and Switch happy paths, with prompt capture, lock and branch/switch oracles, post-operation reconcile coverage, and explicit non-claims for switch-after-copy, target browsing, broad remote/auth/certificate matrices, repository-browser integration, break/steal policy breadth, lock cancellation breadth beyond the covered prompts, and edge/load behavior.
- Beta-F: covered by `pnpm release:test-state-engine-beta-performance:win32-x64`, which writes `subversionr.release.state-engine-beta-performance.win32-x64.v1` evidence for single-file no-full-scan behavior, bounded event bursts, nested/external isolation, dirty-generation supersede, sidecar restart stale/reopen behavior, and a 10k local working-copy baseline. This remains a Windows Beta packaging floor only; native watcher production, adaptive cost feedback, 100k/1M working-copy performance, idle CPU measurement, default background remote polling, Marketplace/public install, signing/provenance, previous-stable rollback, and public readiness remain non-claims.
- Beta-G: covered by `pnpm release:verify-beta-candidate:win32-x64`, which writes `subversionr.release.beta-candidate-consistency.win32-x64.v1` after package, native artifact map, provenance, publication gaps, installed VSIX gates, install rollback, Beta-F state-engine evidence, and the artifact bundle manifest have been regenerated for the same candidate. `pnpm release:generate-beta-artifact-bundle-manifest:win32-x64` writes `subversionr.release.beta-artifact-bundle-manifest.win32-x64.v1`, enumerates the current VSIX, SBOM, NOTICE, release evidence, and installed UI renderer artifacts, and records the explicit CI upload allowlist. The final verifier checks the current VSIX bytes, VSIX package identity, manifest TargetPlatform, packaged backend ZIP entries, installed evidence VSIX hashes, provenance/publication evidence hashes and verified live GitHub attestation binding, native artifact map inputs, state-engine floor, artifact bundle manifest, explicit CI upload allowlist, and manifest SHA256 binding before CI uploads `subversionr-win32-x64-beta-candidate` with `actions/upload-artifact@v7`. The published 0.2.3 candidate ZIP is 14,979,306 bytes with SHA256 `aaad65fd21de301397f25cfad0a30f3ff26b7ce1a2826dac451682fac6272889`; it has 1,469 verified payloads plus the manifest and consistency JSONs, for 1,471 entries, and passes the same contract. The gate does not close public-install verification, signing, previous-stable rollback, broad remote/auth, coverage-guided fuzzing, or public readiness.

## Deferred Public-Release M7 Slices

- M7j4: previous-stable installed-product upgrade/rollback once a real previous stable artifact exists.
- M7l2 continuation: produce final vulnerability release approval evidence after terminal rows receive final release review, keep affected-row remediation explicit if future findings are introduced, and avoid turning terminal VEX inputs into broad vulnerability-free claims.
- Future coverage-guided native remote-protocol fuzzing: run coverage-guided campaigns from the source-controlled fuzzer target, prove sanitizer-instrumented libsvn coverage, record edge growth and crash/run artifacts, and close the M7l7/M7l8/M7l9 blockers only after evidence exists.

# SubversionR Engineering Guide

This guide is the public starting point for engineers who need to understand the repository before changing it. It contains stable architecture and development guidance, not completion estimates, internal prioritization, or release claims.

## Public Fact Sources

Use the public repository as a self-contained source of truth:

1. `README.md` describes the product and current user-facing limits.
2. `CONTRIBUTING.md` defines the contributor setup and CI policy.
3. `docs/adr/README.md` indexes accepted architecture decisions.
4. `docs/roadmap/README.md` records implemented milestones and current engineering focus.
5. `docs/release/public-claim-matrix.md` defines what the current release may claim.
6. `docs/release/m7-release-readiness-gates.md` and `docs/release/requirements-release-evidence.csv` define release evidence and blockers.
7. `docs/plans/` records the implementation history behind the current design.

Do not infer current product support from a historical plan alone. When sources differ, the release claim matrix and current executable gates take precedence for release claims.

## Architecture

SubversionR is split across four ownership boundaries:

- The VS Code TypeScript adapter owns commands, editors, Source Control projection, localization, and user interaction.
- The Rust sidecar owns repository sessions, scheduling, status state, diagnostics, and long-lived coordination.
- The narrow C ABI owns APR/libsvn lifetime, callbacks, and error conversion.
- Bundled `libsvn` is the authoritative source for SVN semantics.

The primary request path is:

```text
VS Code command or provider
-> TypeScript controller/client
-> Content-Length JSON-RPC over stdio
-> Rust daemon state
-> native bridge FFI
-> libsvn
-> structured result and reconcile hint
-> TypeScript projection and localized UI
```

The sidecar does not expose a listening network port. One sidecar belongs to one Extension Host and can coordinate multiple repositories.

## Engineering Invariants

The accepted decisions under `docs/adr/` are normative. In particular:

1. Production workflows do not call the `svn` CLI. CLI tools are allowed only in fixtures, diagnostics, and differential tests.
2. Neither Rust nor TypeScript writes `.svn/wc.db` directly.
3. Ordinary status refresh is dirty-path targeted, with bounded full reconciliation used for recovery.
4. Local and remote status are scheduled independently. Local changes do not trigger background remote polling.
5. The Extension Host remains lightweight and does not perform repository scans, XML parsing, large history/diff work, or working-copy database reads.
6. The extension uses only stable VS Code APIs for core functionality; proposed APIs are not required.
7. TortoiseSVN is optional and must not affect native core workflows when absent.
8. User-visible text belongs in the TypeScript localization layer. Backend errors return stable keys and safe arguments.
9. SVN terminology is preserved. Do not introduce staging, push/pull, or Git commit-graph semantics.
10. Required configuration and protocol contracts fail fast. Do not add silent fallbacks or compatibility aliases without an explicit reviewed requirement.

## Repository Map

- `packages/vscode-extension/`: VS Code adapter, providers, commands, localization, and TypeScript tests.
- `crates/subversionr-protocol/`: versioned JSON-RPC wire contracts.
- `crates/subversionr-daemon/`: repository state, scheduling, auth brokering, diagnostics, and native calls.
- `native/svn-bridge/`: narrow C ABI over APR and libsvn.
- `scripts/native/`: locked native dependency build and smoke workflows.
- `scripts/release/`: evidence generation, verification, packaging, and readiness gates.
- `scripts/tests/`: PowerShell contract tests for native and release scripts.
- `docs/adr/`: stable architecture decisions.
- `docs/plans/`: implemented milestone history.
- `docs/release/`: claim boundaries, evidence contracts, security matrices, and release runbooks.
- `.github/workflows/pr-fast.yml`: automatic pull-request and `main` gate.
- `.github/workflows/ci.yml`: scheduled/manual native, packaging, security, and release workflow.

## Change Ownership

Keep changes in the layer that owns the behavior:

- VS Code interaction or projection changes belong in TypeScript.
- Scheduling, repository state, cancellation, and durable coordination belong in Rust.
- SVN semantics and APR/libsvn callbacks belong behind the native bridge.
- Wire changes require protocol types, daemon dispatch, TypeScript clients, version/capability updates, and contract tests in the same change.
- User-visible features require localization, accessibility consideration, diagnostics, recoverable errors, and success/failure/cancellation tests.
- Release-claim changes require the corresponding evidence generator, verifier, tests, matrices, and roadmap updates.

Read-only optimizations must not replace libsvn confirmation where correctness matters. Cache data is discardable; the working copy remains external source data.

## Development Setup

Use `pnpm` for Node.js workflows and `cargo` through `rustup` for Rust. Use `uv` for Python helper work. Do not use bare `npm`, `npx`, or `pip`.

```powershell
pnpm install --frozen-lockfile
pnpm check
pnpm test
pnpm i18n:verify
cargo fmt --all -- --check
cargo test --workspace
pnpm native:test-scripts
```

Windows native builds require Visual Studio 2022 Build Tools and an explicit developer-command path:

```powershell
$env:SUBVERSIONR_VSDEVCMD = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat"
pnpm native:verify-sources
pnpm native:build-deps:all
pnpm native:build-subversion:staged
pnpm native:build-daemon:release
pnpm native:build-bridge:staged
pnpm native:smoke-bridge:staged
```

Generated native dependencies, VSIX layouts, evidence, and test fixtures stay under ignored `.cache/`, `dist/`, and `target/` roots.

## Validation Policy

Choose validation based on the touched boundary:

- TypeScript: `pnpm check` and `pnpm test`.
- Localization or public text: `pnpm i18n:verify` and the relevant documentation verifier.
- Rust/protocol: `cargo fmt --all -- --check` and `cargo test --workspace`.
- Native scripts: `pnpm native:test-scripts`; run staged native builds for native source or bridge changes.
- Release contracts: focused `release:test-*` suites plus `pnpm release:verify-readiness`.
- Pull requests: the automatic `PR Fast / windows` check must pass.

The heavy workflow remains scheduled/manual because it builds native dependencies, packages and installs VSIX artifacts, queries live advisory services, and regenerates release evidence.

## Current Scope

The public target is the Windows `win32-x64` Beta distributed through the Visual Studio Marketplace pre-release channel, with the same VSIX available from GitHub Releases for offline installation. The current release claim does not include stable-channel publication, artifact signing, cross-platform packages, broad remote/auth matrices, merge/mergeinfo, or previous-stable rollback.

Use `docs/release/public-claim-matrix.md` for the exact boundary. Never promote fixture, preflight, source-only, or local-smoke evidence into a broader product claim.

## Reading Order

For a first repository pass:

1. `README.md`
2. `CONTRIBUTING.md`
3. This guide
4. `docs/adr/README.md`
5. `docs/roadmap/README.md`
6. `docs/release/public-claim-matrix.md`
7. The plan and release evidence documents for the subsystem being changed
8. The owning TypeScript, Rust, protocol, or native modules and their tests

Keep this guide stable. Put changing milestone status in the roadmap and release documents, and put durable design changes in a new ADR.

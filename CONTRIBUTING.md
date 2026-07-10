# Contributing to SubversionR

SubversionR is implemented as a VS Code TypeScript adapter, a Rust sidecar, and a narrow C ABI bridge over bundled Apache Subversion `libsvn`. Product behavior must preserve native SVN concepts and must not depend on the `svn` CLI, TortoiseSVN, or direct `.svn/wc.db` writes.

## Development Setup

Use `pnpm` for Node.js workflows and `cargo` through `rustup` for Rust workflows. Use `uv` for any Python helper work. Do not use bare `npm`, `npx`, or `pip` in this repository.

Windows native build scripts require `SUBVERSIONR_VSDEVCMD` to point at the Visual Studio 2022 developer command entrypoint:

```powershell
$env:SUBVERSIONR_VSDEVCMD = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat"
```

## Fast Local Gates

Run these before sending a normal product or adapter change:

```powershell
pnpm install --frozen-lockfile
pnpm check
pnpm test
pnpm i18n:verify
cargo fmt --all -- --check
cargo test --workspace
pnpm native:test-scripts
```

Run release and native gates only when the touched area requires them:

```powershell
pnpm release:verify-readiness
pnpm native:verify-sources
pnpm native:build-deps:all
pnpm native:build-subversion:staged
pnpm native:build-bridge:staged
pnpm native:smoke-bridge:staged
```

## Requirement Status

The authoritative requirement catalog records specification approval and lives in the private planning archive since the public cutover. Maintainers cross-check the public evidence mapping against it with `scripts/release/verify-requirement-catalog-alignment.ps1`.

`docs/release/requirements-release-evidence.csv` maps every P0/P1 requirement to release evidence state:

- `requirement_status` mirrors the catalog approval state.
- `release_evidence_status` records `blocked`, `partial`, `verified`, or `exception`.
- `evidence_refs`, `exception_ref`, and `blocker_reason` must explain the current release posture.

Do not treat `Approved` specification status as implemented or verified product behavior. Release readiness must be proven through the release evidence mapping and its referenced gates.

## Engineering Rules

- Keep VS Code Extension Host work lightweight. Heavy status, history, diff, cache, and SVN semantics belong in the Rust sidecar or native bridge.
- Route user-visible UI text through the TypeScript localization layer. Rust/backend errors should return stable keys and safe arguments.
- Fail fast when required configuration, schema, files, tools, or environment variables are missing.
- Do not add compatibility aliases, silent fallbacks, migration shims, or alternate execution paths unless a reviewed requirement explicitly asks for them.
- Keep local and remote status scheduling separate. Ordinary local file changes must not implicitly perform remote polling.
- TortoiseSVN is optional. Missing TortoiseSVN must not affect native SubversionR workflows.

## CI Policy

`.github/workflows/pr-fast.yml` is the automatic pull request gate for lightweight TypeScript, Rust, localization, and script checks.

`.github/workflows/ci.yml` is the heavy release workflow, triggered manually or by the weekly schedule. It contains native build, packaging, VSIX install, vulnerability, and release-evidence gates and must not be used as an automatic PR gate until it is split further.

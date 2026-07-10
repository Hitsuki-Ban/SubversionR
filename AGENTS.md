# SubversionR Agent Instructions

Instructions for AI coding agents working in this repository. Human contributors should read `CONTRIBUTING.md` first; everything there applies to agents as well.

## Project Identity

- The formal project name is **SubversionR**. Historical planning documents may use `SVN Native` as a working name; new implementation, package, and user-facing naming uses `SubversionR` unless a reviewed naming decision changes it.
- The complete product and engineering reference specification lives in a private planning archive and is not part of this repository. Treat `docs/` — especially `docs/release/` (claim matrix, readiness gates, evidence contracts) and `docs/roadmap/` — as the authoritative public fact source.

## Product Invariants

- Architecture is VS Code TypeScript adapter + Rust sidecar + libsvn through a narrow C ABI.
- Production workflows must not depend on the `svn` CLI. The CLI may be used only as a fixture or differential-test oracle.
- libsvn is the authoritative source for SVN semantics. Do not reimplement working-copy semantics, and do not write `.svn/wc.db` directly.
- The VS Code Extension Host stays lightweight: no repository scans, XML parsing, large diff/blame/history work, or wc.db reads there.
- Status refresh uses dirty-path targeted status plus low-frequency full reconciliation, not whole-repository scans for ordinary events. Local and remote status are independently scheduled; do not add default background remote polling.
- TortoiseSVN is optional. Its absence must not break or degrade native core workflows.
- Use SVN terminology. Do not fake Git concepts such as staging, push/pull, or Git commit graphs.
- User-facing text goes through the TypeScript localization layer (English, Japanese, and Chinese are the priority languages). Rust/backend errors return stable keys and safe arguments, not localized prose.
- Do not add silent fallbacks, compatibility aliases, migration shims, or alternate execution paths unless a reviewed requirement explicitly asks for them. Fail fast on missing required configuration, unsupported protocol versions, unsafe workspace trust state, or invalid external-tool configuration.

## Working Rules

- One bounded change per branch and pull request, with the acceptance criteria stated up front. `PR Fast / windows` must be green before merge.
- Every product capability change closes protocol, native, daemon, VS Code UI, error handling, localization, tests, and state-reconcile behavior together.
- Do not overstate support scope in code, docs, or claims: a fixture, preflight, or source skeleton is not product support. `docs/release/public-claim-matrix.md` defines what may be claimed.
- Verification baseline and heavier gates are documented in `CONTRIBUTING.md`. Release evidence expectations live in `docs/release/m7-release-readiness-gates.md`.

# SubversionR Development Instructions

## Project Identity

- The formal project name is **SubversionR**.
- The historical planning documents may use `SVN Native` as the working name. New implementation, package, and user-facing naming should use `SubversionR` unless a reviewed naming decision changes it.
- The complete product and engineering reference (`Reference/`) lives in the private planning archive and is not part of the public repository. In the public repository, treat `docs/` plus the release governance documents (`docs/release/`, `docs/roadmap/`) as the authoritative fact source; consult the private archive before resolving deep design ambiguity.

## Communication And Documentation

- Reply to the user in Chinese by default.
- Use English for team-facing prompts, subagent instructions, Ask Gemini prompts, code comments, commit messages, and project documentation.
- User-facing product text must be planned for localization, with English, Japanese, and Chinese as priority languages.
- UI text belongs in the TypeScript localization layer. Rust/backend errors should return stable keys and safe arguments, not final localized prose.

## Research And Delegation

- Use current internet research for version-sensitive framework, API, packaging, security, platform, and toolchain decisions. Prefer official documentation, primary repositories, and vendor docs.
- Use read-only subagents to expand exploration when tasks can be split independently. Keep the main thread responsible for final decisions.
- Use Ask Gemini/OpenCode freely, without waiting for user approval, for focused architecture, debugging, design critique, security review, and blind-spot checks when an independent consultation would reduce risk. Codex remains responsible for final decisions, edits, verification, and user-facing conclusions.
- Treat optional Ask Gemini/OpenCode consultation failures as visible diagnostics: report the failure when it matters, then continue with local evidence and verification rather than silently skipping the consultation.
- On Windows PowerShell, run Ask Gemini/OpenCode wrapper calls with `PYTHONIOENCODING=utf-8` when printing model output to avoid console encoding failures.
- Do not send secrets, credentials, private repository URLs, source content, cookies, or unnecessary personal data to web tools, subagents, or external reviewers.

## Tooling Defaults

- Use `pnpm` for Node.js project and global workflows. Do not use bare `npm` or `npx`.
- Use `uv` for Python project and global workflows. Do not use bare `pip`.
- Prefer `rg` / `rg --files` for repository search.
- Prefer Browser/in-app browser tools for local browser checks when available; use Playwright CLI explicitly when needed.
- On Windows, use PowerShell-native file operations and avoid destructive commands unless explicitly requested.

## Product Invariants From Reference Docs

- Architecture is VS Code TypeScript adapter + Rust sidecar + libsvn.
- Production workflows must not depend on the `svn` CLI. CLI may be used only as a diagnostic or differential-test oracle.
- libsvn is the authoritative source for SVN semantics.
- Rust must not directly write `.svn/wc.db`; read-only fast paths must never replace libsvn confirmation where correctness matters.
- Status refresh uses dirty-path targeted status plus low-frequency full reconciliation, not whole-repository scans for ordinary events.
- Local status and remote status are independently scheduled. Do not add default background remote polling.
- VS Code Extension Host must stay lightweight and must not perform repository scans, XML parsing, large diff/blame/history work, or wc.db reads.
- TortoiseSVN is optional. Missing TortoiseSVN must not break native core workflows.
- SVN terminology is required. Do not fake Git concepts such as staging, push/pull, or Git commit graphs.
- All user-visible functionality must map to requirement IDs, acceptance scenarios, recoverable error behavior, tests, diagnostics, localization, and accessibility considerations.

## Compatibility And Migration

- Do not add silent fallbacks, compatibility aliases, migration shims, or alternate execution paths unless they are explicitly required by the user or the `Reference/` specifications.
- When compatibility is required by the reference docs, make it explicit, trace it to requirement IDs or catalog rows, and avoid behavior that silently changes SVN semantics.
- Fail fast on missing required configuration, unsupported protocol major versions, unsafe workspace trust state, or invalid external-tool configuration.

## Current Workspace State

- As of the first project inventory on 2026-06-22, the workspace root contained only reference materials and was not a Git repository.
- Expected implementation scaffolding has not yet been created.

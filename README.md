# SubversionR

SubversionR is a native Apache Subversion (SVN) client for Visual Studio Code. It talks to `libsvn` directly through a bundled Rust sidecar and C bridge — no `svn` command line, no TortoiseSVN dependency, and no Git-flavored reinterpretation of SVN concepts.

The current public target is a Windows `win32-x64` Beta package distributed as a VSIX from GitHub Releases. It is not yet a Marketplace or cross-platform release.

## Install From Releases

1. After `v0.2.1-beta.1` is published, download its `subversionr-win32-x64-0.2.1.vsix` asset from GitHub Releases.
2. In VS Code, run **Extensions: Install from VSIX...** and select the downloaded file.
3. Open a local SVN working copy or run **SubversionR: Checkout Repository**.

Release assets also include the SBOM, third-party notices, and the Beta evidence bundle. The evidence bundle contains the installed Source Control UI screenshots used for release verification.

## Features

- Open or checkout SVN working copies.
- View SVN status in Source Control with native SVN groups: Conflicts, Changes, Unversioned, Incoming, Externals, Ignored, and changelists.
- Add, remove, move, revert, resolve, update, and commit changes.
- Delete unversioned files.
- Update to a specific revision and choose SVN depth or externals behavior.
- Manage properties, `svn:ignore`, changelists, locks, branches, tags, and switch operations.
- View diffs, file history, repository log, and blame information, including inline SVN Lens surfaces (current-line blame, hover summaries, and history CodeLens).
- Optional read-only TortoiseSVN handoff for log, diff, revision graph, and blame dialogs when TortoiseSVN is installed.

## Current Limits

- Windows `win32-x64` only.
- Local file-backed working copies are the intended test path.
- Remote server, proxy, client-certificate, Kerberos/NTLM, SASL, and broad certificate workflows are not public Beta claims.
- Merge, merge preview, and mergeinfo are not included.
- Marketplace installation, signing, and cross-platform packages are not included.

The full claim boundary is documented in [docs/release/public-claim-matrix.md](docs/release/public-claim-matrix.md).

## Feedback And Support

Use the repository issue forms for bug reports and support requests. See [SUPPORT.md](SUPPORT.md) for what to include.

When reporting an issue, include the SubversionR version, VS Code version, Windows version, repository transport type, and a short description of the action that failed.

Use sanitized diagnostics evidence only. Do not include secrets, credentials, private repository URLs, cookies, certificate private keys, or sensitive working-copy data in public reports.

For security vulnerabilities, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Start with the [engineering onboarding guide](docs/onboarding/ENGINEERING_HANDOFF.md) and the [Architecture Decision Records](docs/adr/README.md). Release governance, claim boundaries, and readiness gates live under [docs/release/](docs/release/), and the development roadmap lives under [docs/roadmap/](docs/roadmap/).

## License And Attribution

SubversionR is released under the [MIT License](LICENSE). The packaged backend embeds Apache Subversion and other third-party components; see the `THIRD-PARTY-NOTICES.md` asset attached to each release for the full attribution list.

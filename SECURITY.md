# Security Policy

## Supported Versions

SubversionR is still in private development. No public stable release is currently supported for general security response.

Before the first public release, this policy must be updated with the exact supported stable and pre-release channels. After the first stable release, security fixes are expected to target the current stable release line and any active public pre-release candidate unless a release note states otherwise.

## Reporting a Vulnerability

Do not report security vulnerabilities through a public issue, discussion, pull request, or social channel.

During private repository development, report security issues through the private repository channel available to the maintainers. Before public release, GitHub Private Vulnerability Reporting must be enabled or an equivalent private reporting path must be documented here.

When reporting a vulnerability, include:

- SubversionR version or commit.
- VS Code version, operating system, architecture, and whether the workspace is local or remote.
- Repository transport involved, such as local file, `svn://`, HTTPS DAV fixture, or another deferred transport.
- Minimal reproduction steps using synthetic data whenever possible.
- Whether the issue concerns credentials, SecretStorage, certificate trust, Workspace Trust, diagnostics, native packaging, or optional external tools.

## Private Vulnerability Reporting

The intended public-release path is GitHub Private Vulnerability Reporting. This gives security researchers a private, structured reporting channel when it is enabled for the public repository.

Until the repository is public and that feature is enabled, maintainers must keep vulnerability reports inside private project channels and must not ask reporters to disclose secrets or customer source material.

At public cutover, maintainers must enable GitHub Private Vulnerability Reporting on `Hitsuki-Ban/SubversionR` before inviting public vulnerability reports. If PVR is unavailable, this document must be updated in the same cutover PR with an equivalent private reporting path before the first public release is announced.

## Do Not Include

Reports must not include:

- Passwords, personal access tokens, cookies, SSH keys, private keys, client-certificate private keys, or passphrases.
- Raw VS Code SecretStorage contents or operating-system credential-store exports.
- Standard SVN auth cache directories.
- Full working copies, complete `.svn` directories, customer source trees, private repository dumps, or unredacted server logs.
- Unredacted diagnostics bundles, crash dumps, screenshots, or terminal output containing repository URLs, credentials, private paths, or source content.

If sensitive material is required to reproduce an issue, reduce it to a synthetic fixture first.

## Response Expectations

Maintainers should acknowledge private security reports within a reasonable project-maintainer window, triage whether the issue affects a supported or pre-release channel, and keep follow-up discussion private until a fix and disclosure plan are ready.

Public release requires documented handling for:

- Supported versions and release channels.
- Access to shared diagnostics artifacts.
- Retention and deletion requests for mistakenly shared material.
- Advisory publication and release notes when a vulnerability affects public builds.

## Diagnostics And Evidence

SubversionR diagnostics are user-initiated local artifacts. They are not telemetry and are not uploaded automatically.

Maintainers may request a redacted diagnostics bundle only when it is necessary for the report. Reporters should inspect the bundle before sharing it. If a redaction gap is suspected, the report must be handled as a security issue.

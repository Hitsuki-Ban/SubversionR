# Security Policy

## Supported Versions

SubversionR currently publishes the Windows `win32-x64` `0.2.2` Beta through the Marketplace pre-release channel and GitHub Releases. No stable release is currently supported.

Security fixes target the active public pre-release candidate. After the first stable release, fixes are expected to target the current stable release line and any active public pre-release candidate unless a release note states otherwise.

## Reporting a Vulnerability

Do not report security vulnerabilities through a public issue, discussion, pull request, or social channel.

Use GitHub Private Vulnerability Reporting from the repository **Security** tab and select **Report a vulnerability**. This sends the report privately to the maintainers.

When reporting a vulnerability, include:

- SubversionR version or commit.
- VS Code version, operating system, architecture, and whether the workspace is local or remote.
- Repository transport involved, such as local file, `svn://`, HTTPS DAV fixture, or another deferred transport.
- Minimal reproduction steps using synthetic data whenever possible.
- Whether the issue concerns credentials, SecretStorage, certificate trust, Workspace Trust, diagnostics, native packaging, or optional external tools.

## Private Vulnerability Reporting

GitHub Private Vulnerability Reporting is enabled for `Hitsuki-Ban/SubversionR` and is the supported private, structured reporting channel. Maintainers must keep vulnerability reports in that private channel and must not ask reporters to disclose secrets or customer source material.

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

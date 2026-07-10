# SubversionR Security Support Handling

## Security Vulnerability Reports

Security reports must use a private channel. For the private repository phase, maintainers handle reports inside the private GitHub repository and security advisory workflow when enabled. For public release, the repository must publish a `SECURITY.md` with supported versions and a private vulnerability reporting path before a marketplace release is announced.

The public issue templates are limited to non-security bug reports and support requests. They must route suspected vulnerabilities to `SECURITY.md`, block blank public issues, and require reporters to acknowledge that public reports must not include secrets or sensitive repository material (`SEC-002`, `SEC-014`, `OBS-005`, `OBS-007`, `PRD-010`, `PRD-012`).

Reporters should include:

- SubversionR version and release channel.
- VS Code version, operating system, and platform target.
- Reproduction steps using a minimal repository or working copy.
- Redacted diagnostics bundle or version report when requested.
- Whether the issue affects credentials, certificate trust, Workspace Trust, diagnostics, native packaging, or external tools.

Reporters and maintainers must not include credentials, private keys, auth-cache files, raw repository dumps, full working copies, unredacted logs, or customer source files (`SEC-002`, `SEC-014`).

## Support Bundle Handling

SubversionR support bundles are user-initiated local JSON files. They are not uploaded automatically, and they are not telemetry. Maintainers may request the bundle only when it is needed for a concrete issue and must ask the user to inspect it before sharing (`OBS-005`, `OBS-006`, `OBS-007`, `OBS-008`).

Maintainers must apply the maintainer redaction checklist in `docs/security/support-redaction-checklist.md` before requesting, copying, quoting, or retaining diagnostics evidence from a public issue. If any checklist category is not reviewed, support handling stops normal public triage and asks for a sanitized summary instead.

Expected safe bundle shape:

```json
{
  "extension": { "version": "0.1.0" },
  "workspace": {
    "trusted": true,
    "folderCount": 1,
    "remoteAuthority": "[REDACTED:authority:example]"
  },
  "backend": {
    "protocol": { "version": "1.16" },
    "libsvn": { "version": "1.14.5" },
    "stderr": "[REDACTED:backend-stderr]"
  },
  "repository": {
    "url": "[REDACTED:url:example]",
    "path": "[REDACTED:path:example]"
  },
  "operationJournal": {
    "entries": [],
    "omittedFields": ["paths", "urls", "repositoryLogMessages", "sourceContent", "credentials"]
  },
  "metrics": {
    "watcher": {
      "overflowCount": 0
    }
  }
}
```

The example is illustrative. Automated redaction tests, not this sample, are the release evidence for the current bundle schema.

## Do Not Request

Support responders must not request:

- Passwords, tokens, SSH keys, client certificate private keys, or passphrases.
- VS Code SecretStorage content or OS credential-store exports.
- Raw Subversion auth cache directories, including standard SVN credential-store files.
- Complete `.svn` directories or `wc.db` unless a separate security triage explicitly defines a sanitized minimal fixture.
- Full source trees, private repository dumps, raw server logs, unredacted command output, or crash dumps.
- Screenshots that expose credentials, repository URLs, customer names, or private paths.

If a report cannot be investigated without sensitive material, the default answer is to reduce the reproduction to a synthetic fixture rather than to collect the material.

## Redaction

Current diagnostics redaction must cover secrets, authorization headers, cookies, tokens, passwords, passphrases, repository URLs and query strings, Windows/POSIX/UNC paths, remote authorities, source content, repository log messages, backend startup safe args, backend stderr, operation journal summaries, and watcher metrics (`SEC-002`, `SEC-014`, `OBS-007`).

Redaction markers must stay locale-neutral ASCII so support can compare bundles across English, Japanese, and Chinese environments. Stable markers such as `[REDACTED:secret]`, `[REDACTED:url:<hash>]`, and `[REDACTED:path:<hash>]` are preferred.

If a redaction gap is suspected, support handling stops normal triage and treats the report as a security issue.

## Retention

Support artifacts are private issue evidence, not durable telemetry. Maintainers should retain redacted bundles only for the life of the issue or advisory and delete local copies after the issue is resolved.

Public release must define:

- The supported-version window for security fixes.
- The retention expectation for private vulnerability reports.
- Who may access shared diagnostics artifacts.
- How reporters can request removal of mistakenly shared sensitive material.

## Telemetry

M6aa does not add telemetry upload. Public release must keep telemetry disabled by default unless a later reviewed design adds explicit opt-in collection with localized disclosure, revocation, and no secret-bearing payloads (`OBS-008`).

Diagnostics, version reports, crash artifacts, and support bundles are user-controlled local artifacts. They must not be sent from the extension, Rust sidecar, C bridge, `libsvn`, fixture tools, or Tortoise adapter without explicit user action.

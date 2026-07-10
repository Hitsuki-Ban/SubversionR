# Support Redaction Checklist

This checklist is the maintainer-side public support intake gate for `SEC-002`, `SEC-014`, `OBS-005`, `OBS-007`, `PRD-010`, and `PRD-012`. Use it before requesting, copying, quoting, or retaining user-provided diagnostics evidence.

## Public Issue Intake

- Confirm that the report is not a security vulnerability. If it is or might be, route it to `SECURITY.md` and stop normal public triage.
- Confirm that the reporter used a synthetic reproduction or summarized the behavior without private repository material.
- Confirm that the report does not include credentials, auth tokens, cookies, `Authorization` headers, passphrases, SSH keys, private keys, client certificate private keys, or credential-store exports.
- Confirm that the report does not include private repository URLs, credentialed `svn://` URLs, credentialed `http://` URLs, credentialed `https://` URLs, or query strings carrying secrets.
- Confirm that the report does not include `.svn/wc.db`, complete `.svn` directories, standard SVN auth cache directories, raw working copies, private repository dumps, or customer source trees.
- Confirm that the report does not include working-copy absolute paths, UNC shares, remote authorities, stack traces with private paths, raw logs, crash dumps, screenshots with private data, source content, repository log messages, or unredacted diagnostics bundles.
- Confirm that operation journal entries and watcher overflow metrics contain only counts, hashes, timings, enum values, and redaction markers; they must not include raw paths, URLs, credentials, source snippets, or repository log messages.

## Diagnostics Evidence

- Request redacted diagnostics only when the issue cannot be triaged from the sanitized report fields.
- Ask the reporter to inspect the local diagnostics artifact before sharing it.
- Do not paste redacted bundles into public comments. Use private issue evidence when a bundle is required.
- Do not ask for raw logs, full support bundles, screenshots, or crash artifacts in public issues.
- Treat any suspected redaction gap as a security report and route it through `SECURITY.md`.

## Maintainer Stop Conditions

- If any required category is unreviewed, stop normal public triage and request a sanitized summary instead.
- If a public report already contains sensitive material, remove or minimize the exposure through the platform moderation tools and continue privately.
- If sensitive material is required to reproduce the behavior, build a synthetic fixture instead of collecting user data.

# ADR-010: Credential Storage

Status: Accepted

## Context

SVN operations may require credentials, but secrets must not be stored in ordinary settings, caches, logs, or diagnostics.

## Decision

Persistent credentials are stored only in VS Code SecretStorage. If SecretStorage is unavailable or a read/write operation fails, credential persistence fails closed. It does not fall back to settings, extension caches, sidecar storage, diagnostics, or the standard SVN auth cache. The TypeScript layer brokers bounded credential requests for the sidecar.

## Consequences

- Credential persistence uses VS Code's secret-storage boundary rather than plaintext configuration.
- A SecretStorage failure prevents persistence instead of selecting a weaker storage path.
- Credential prompts and reads remain subject to Workspace Trust and explicit interaction policies.
- Diagnostics and caches must remain free of credential values.

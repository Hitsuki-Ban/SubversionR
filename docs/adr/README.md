# Architecture Decision Records

These Architecture Decision Records (ADRs) document the accepted architectural boundaries of SubversionR. Each record captures one decision and its consequences for contributors.

## Governance

- ADR numbers are stable and are never reused or renumbered.
- Accepted records remain in the repository even when a later decision replaces them.
- A change that reverses or materially weakens an accepted decision requires a new ADR and product, architecture, security, and QA review.
- The new ADR must identify the records it supersedes, and each superseded record must link to its replacement and change status to `Superseded`.
- Editorial clarification may update an accepted record only when it does not change the decision or its consequences.

## Accepted Decisions

- [ADR-001: TypeScript UI, Rust Sidecar, and libsvn](ADR-001-typescript-rust-libsvn-architecture.md)
- [ADR-002: Stdio RPC Transport](ADR-002-stdio-rpc-transport.md)
- [ADR-003: Bundled libsvn Runtime](ADR-003-bundled-libsvn-runtime.md)
- [ADR-004: Working Copy Database Integrity](ADR-004-working-copy-database-integrity.md)
- [ADR-005: Dirty-Path Status Refresh](ADR-005-dirty-path-status-refresh.md)
- [ADR-006: Local and Remote Status Scheduling](ADR-006-local-and-remote-status-scheduling.md)
- [ADR-007: Sidecar Process Lifetime](ADR-007-sidecar-process-lifetime.md)
- [ADR-008: Stable VS Code APIs](ADR-008-stable-vscode-apis.md)
- [ADR-009: Optional TortoiseSVN Adapter](ADR-009-optional-tortoisesvn-adapter.md)
- [ADR-010: Credential Storage](ADR-010-credential-storage.md)
- [ADR-011: Cache Source of Truth](ADR-011-cache-source-of-truth.md)
- [ADR-012: SVN Terminology](ADR-012-svn-terminology.md)
- [ADR-013: Disposable Remote Operation Workers](ADR-013-disposable-remote-operation-workers.md)

# ADR-001: TypeScript UI, Rust Sidecar, and libsvn

Status: Accepted

## Context

SubversionR must integrate with VS Code while keeping native SVN work and authoritative working-copy semantics outside the Extension Host.

## Decision

The VS Code UI and adapter are implemented in TypeScript. Native and long-running work runs in a Rust sidecar, which accesses SVN through a narrow C bridge to libsvn. libsvn is authoritative for SVN semantics.

## Consequences

- The Extension Host remains focused on VS Code APIs, presentation, and localization.
- Native work and long-lived state belong in the sidecar.
- Production SVN behavior is defined by libsvn rather than a reimplementation in TypeScript or Rust.

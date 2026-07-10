# ADR-002: Stdio RPC Transport

Status: Accepted

## Context

The TypeScript extension and Rust sidecar need a private, bounded communication channel with a lifecycle controlled by the Extension Host.

## Decision

The extension and sidecar communicate through framed RPC over the child process's standard input and output. The sidecar does not open a listening port.

## Consequences

- Production IPC exposes no network listening endpoint.
- Sidecar startup, shutdown, framing, and failure handling are owned by the parent Extension Host process.
- Protocol input remains bounded and validated at the stdio boundary.

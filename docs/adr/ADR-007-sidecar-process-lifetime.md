# ADR-007: Sidecar Process Lifetime

Status: Accepted

## Context

A single VS Code Extension Host can manage several SVN working copies, while each native process has startup cost and long-lived protocol state.

## Decision

Each Extension Host starts one Rust sidecar and shares it across all repositories managed by that host.

## Consequences

- Repository sessions are multiplexed through one sidecar connection.
- Sidecar lifecycle and protocol negotiation happen once per Extension Host.
- Repository state must remain explicitly separated inside the shared process.

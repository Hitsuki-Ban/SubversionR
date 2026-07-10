# ADR-006: Local and Remote Status Scheduling

Status: Accepted

## Context

Local working-copy state is cheap and continuously relevant, while remote repository status can require authentication, network access, and user-visible latency.

## Decision

Local and remote status are scheduled independently. Remote status is manual-first, with no default background remote polling.

## Consequences

- Local refresh remains useful without network access.
- Remote checks occur through explicit user action.
- Local and remote freshness are represented independently.

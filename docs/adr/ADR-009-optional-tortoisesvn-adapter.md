# ADR-009: Optional TortoiseSVN Adapter

Status: Accepted

## Context

Some Windows users have TortoiseSVN installed and may value access to its GUI, but SubversionR's native workflows must stand on their own.

## Decision

TortoiseSVN is an optional adapter integration, not a core dependency.

## Consequences

- Missing TortoiseSVN does not break or weaken native core workflows.
- TortoiseSVN actions are explicit external-tool handoffs rather than substitutes for native operations.
- Adapter availability and executable configuration are validated before invocation.

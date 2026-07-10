# ADR-008: Stable VS Code APIs

Status: Accepted

## Context

Core SubversionR workflows must run in ordinary supported VS Code installations without experimental editor configuration.

## Decision

Core functionality uses stable VS Code APIs and does not depend on proposed APIs.

## Consequences

- Users do not need to enable proposed API access for core workflows.
- Core behavior follows the compatibility surface published by VS Code.
- Features that require unavailable stable APIs are not part of the core path.

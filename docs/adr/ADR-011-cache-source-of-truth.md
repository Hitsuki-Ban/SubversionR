# ADR-011: Cache Source of Truth

Status: Accepted

## Context

Status, history, and protocol caches can improve responsiveness, but cached state can become stale or be lost.

## Decision

All SubversionR caches are discardable. The working copy, interpreted through libsvn, is the external source of truth.

## Consequences

- Clearing or losing a cache does not change working-copy state.
- Cache recovery rebuilds state by reconciling with the working copy.
- Cached data must never override a contradictory libsvn-confirmed result.

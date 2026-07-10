# ADR-005: Dirty-Path Status Refresh

Status: Accepted

## Context

Whole-working-copy scans on ordinary file events would add unnecessary latency and load, especially for large working copies.

## Decision

Ordinary local status refresh targets the dirty paths reported by file and operation events. Low-frequency full reconciliation is a separate repair mechanism, not the ordinary refresh path.

## Consequences

- A normal file change does not trigger a whole-repository scan.
- Dirty paths must be coalesced, bounded, and tracked across overlapping refreshes.
- Periodic reconciliation repairs missed events and accumulated drift.

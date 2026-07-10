# ADR-004: Working Copy Database Integrity

Status: Accepted

## Context

The `.svn/wc.db` database is internal working-copy state whose invariants are owned by Apache Subversion.

## Decision

SubversionR never writes `.svn/wc.db` directly. Working-copy changes go through libsvn, and any read-only optimization must not replace libsvn confirmation where correctness matters.

## Consequences

- SubversionR does not implement or mutate private working-copy database semantics.
- Operations may incur native-call cost to preserve correctness.
- Tests and release checks can treat unexpected `.svn/wc.db` mutation as a defect.

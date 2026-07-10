# ADR-012: SVN Terminology

Status: Accepted

## Context

SVN has its own concepts and workflows. Recasting them as Git concepts would misrepresent behavior and create incorrect user expectations.

## Decision

SubversionR uses SVN terminology and semantics. It does not invent staging, push/pull, Git commit graphs, or other fake Git equivalents.

## Consequences

- UI, documentation, localization, and commands use terms such as revisions, changelists, properties, locks, depth, and update.
- Contributors model workflows on SVN behavior rather than Git analogies.
- Familiarity for Git users does not take precedence over semantic accuracy.

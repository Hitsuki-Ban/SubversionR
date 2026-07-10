# ADR-003: Bundled libsvn Runtime

Status: Accepted

## Context

SubversionR needs a known native SVN runtime whose version and dependency closure can be packaged and verified with the extension.

## Decision

The bundled libsvn and its packaged native dependencies are the default production runtime.

## Consequences

- Core workflows do not depend on a system `svn` installation or TortoiseSVN.
- Native artifacts, licenses, and dependency versions are part of the release package and its verification.
- Platform packages must carry and validate their own native runtime closure.

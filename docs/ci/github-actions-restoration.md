# GitHub Actions Restoration

This note records the prepared GitHub Actions trigger design for the public SubversionR repository migration.

## Trigger Design

- `.github/workflows/pr-fast.yml` runs automatically on every `pull_request`, on `push` to `main`, and still supports `workflow_dispatch` for manual reruns.
- `.github/workflows/ci.yml` remains explicit for release-grade native and packaging gates: it supports `workflow_dispatch` and a weekly schedule, but it does not run on `pull_request` or `push`.
- Both workflows use concurrency groups so superseded PR Fast runs can cancel while scheduled/manual heavy CI runs remain serialized by branch or run identity.

## Required Check

Branch protection for the public repository should require the `PR Fast / windows` check. That check name comes from the workflow name `PR Fast` and the job id `windows`.

## Public Cutover Checklist

1. Push the fresh public baseline to `Hitsuki-Ban/SubversionR`.
2. Confirm the first public `PR Fast / windows` run is green.
3. Require `PR Fast / windows` on public `main` branch protection.
4. Keep `.github/workflows/ci.yml` scheduled/manual on the public repository only.
5. Disable both workflows in the private repository through the GitHub Actions UI.
6. Record the private workflow disable date here after the cutover.

Private workflow disable date: not cut over.

## Heavy Gates

The heavy native, VSIX, installed VS Code, live vulnerability review, fixed-seed fuzz, provenance, and publication readiness gates stay scheduled/manual. They are not part of automatic PR validation.

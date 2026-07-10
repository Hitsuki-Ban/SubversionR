# GitHub Actions Restoration

This note records the active GitHub Actions trigger design after the public repository cutover.

## Trigger Design

- `.github/workflows/pr-fast.yml` runs automatically on every `pull_request`, on `push` to `main`, and supports `workflow_dispatch` for manual reruns.
- `.github/workflows/ci.yml` is the scheduled/manual release-grade workflow with a weekly schedule. It does not run automatically on `pull_request` or `push`.
- Both workflows use concurrency groups. Superseded PR Fast runs can cancel, while heavy CI runs remain serialized by branch or run identity.

## Required Check

Public branch protection should require `PR Fast / windows`. The context comes from workflow name `PR Fast` and job id `windows`.

Branch protection is an owner-managed repository setting and is not inferred from workflow files. The public cutover evidence records its separately verified state.

## Cutover State

- The public baseline is on `main`.
- `PR Fast / windows` has passed on public pull requests and `main` pushes.
- The temporary Cloudflare Workers Builds bridge was retired on 2026-07-10; its final state is recorded in `docs/ci/cloudflare-pr-fast-bridge.md`.
- Private-repository workflow disablement remains a separate owner operation and no completion date is recorded in this public document.

## Heavy Gates

The heavy native, VSIX, installed VS Code, live vulnerability review, fixed-seed fuzz, provenance, and publication readiness gates stay scheduled/manual. They are not part of automatic PR validation.

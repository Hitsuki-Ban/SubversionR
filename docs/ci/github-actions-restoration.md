# GitHub Actions Restoration

This note records the active GitHub Actions trigger design after the public repository cutover.

## Trigger Design

- `.github/workflows/pr-fast.yml` runs automatically on every `pull_request`, on `push` to `main`, and supports `workflow_dispatch` for manual reruns.
- `.github/workflows/ci.yml` is the scheduled/manual release-grade workflow with a weekly schedule. It does not run automatically on `pull_request` or `push`.
- Both workflows use concurrency groups. Superseded PR Fast runs can cancel, while heavy CI runs remain serialized by branch or run identity.

## Required Check

Public branch protection requires `PR Fast / windows`. The active `protect-main` repository ruleset targets the default branch, binds job context `windows` to the GitHub Actions integration, requires pull requests, blocks non-fast-forward updates, and has no bypass actors.

Branch protection is an owner-managed repository setting and is not inferred from workflow files. The public cutover evidence records its separately verified state.

## Cutover State

- The public baseline is on `main`.
- `PR Fast / windows` has passed on public pull requests and `main` pushes.
- The `protect-main` repository ruleset has enforced the required public check and pull-request path since 2026-07-10.
- The temporary Cloudflare Workers Builds bridge was retired on 2026-07-10; its final state is recorded in `docs/ci/cloudflare-pr-fast-bridge.md`.
- The private-repository `CI` and `PR Fast` workflows were both set to `disabled_manually` on 2026-07-10. Private-repository archival remains a separate owner operation.

## Heavy Gates

The heavy native, VSIX, installed VS Code, live vulnerability review, fixed-seed fuzz, provenance, and publication readiness gates stay scheduled/manual. They are not part of automatic PR validation.

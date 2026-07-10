# Retired Cloudflare PR Fast Bridge

This document preserves the retirement record for the temporary Cloudflare Workers Builds bridge that carried a portable subset of pull-request checks before the public GitHub Actions gate was available.

## Final State

Retirement date: `2026-07-10`.

- The public `PR Fast / windows` check passed on both a pull request and the resulting `main` push before retirement.
- Both Workers Builds branch triggers were removed; the final trigger count is zero build triggers.
- The repository connection was removed.
- The account no longer has a build configuration associated with `subversionr-pr-fast`.
- The Worker deployment and historical build records were retained as historical platform records.
- Public branch protection remained a separate repository-owner setting and was not changed by the retirement operation.

The current automatic gate is `.github/workflows/pr-fast.yml`. Heavy native, packaging, installed VSIX, live advisory, and release-evidence work remains in the scheduled/manual `.github/workflows/ci.yml` workflow.

## Source Disposition

The retired bridge runner, Worker response, and Wrangler configuration were removed from the active source tree after retirement. Git history preserves the exact implementation that ran during the temporary period; keeping executable copies in the current tree would incorrectly imply that the bridge is still supported.

Reactivation requires a new reviewed infrastructure decision, a current Cloudflare configuration, and new credentials managed outside the repository. The historical implementation must not be treated as a deployment template.

No Cloudflare live identifiers, repository connection identifiers, tokens, secrets, deploy hooks, or credentials are recorded in this document.

## Evidence Boundary

This record proves only that the temporary build connection and triggers were retired on the stated date. It does not prove public branch protection, private-workflow disablement, deletion of historical platform logs, or any current Cloudflare deployment state beyond the retired bridge.

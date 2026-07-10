# Cloudflare PR Fast Bridge

This document records the retired Cloudflare Workers Builds bridge that carried the SubversionR PR-fast gate while GitHub Actions could not start Windows runners.

## Historical Cloudflare Workers Project

- Worker name: `subversionr-pr-fast`
- Source: GitHub repository `Hitsuki-Ban/SubversionR-private`
- Production branch: `main`
- Non-production branch trigger while active: enabled for all branches except `main`
- Workers.dev route: enabled
- Worker Preview URLs: disabled
- PR comments: disabled
- Root directory: `/`
- Build command: `node scripts/ci/cloudflare-pr-fast-bridge.mjs`
- Deploy command: `corepack enable && corepack prepare pnpm@11.5.2 --activate && pnpm dlx wrangler@4.105.0 deploy --config scripts/ci/cloudflare-pr-fast.wrangler.jsonc`
- Preview deploy command: `corepack enable && corepack prepare pnpm@11.5.2 --activate && pnpm dlx wrangler@4.105.0 versions upload --config scripts/ci/cloudflare-pr-fast.wrangler.jsonc`
- Environment variables:
  - `NODE_VERSION=24.16.0`
  - `PNPM_VERSION=11.5.2`

## Retirement

Retirement completed on 2026-07-10 after the public repository baseline was published and `PR Fast / windows` passed on both a public pull request and the resulting `main` push.

The Cloudflare API retirement sequence:

1. Removed the non-production branch trigger.
2. Removed the default-branch trigger.
3. Confirmed the Worker build trigger list was empty.
4. Disconnected the GitHub repository connection.
5. Confirmed no build configuration remained for `subversionr-pr-fast` and that the known Phase 1 success record was still readable.

Final state: Workers Builds is disconnected, zero build triggers remain, and the Worker deployment plus historical build records were not deleted. Public `main` branch protection remained a separate owner setting and was not configured by this retirement operation. No Cloudflare live identifiers or credentials are recorded here.

## Historical Authorization Recovery

Cloudflare API setup failed on 2026-06-28 before authorization was repaired because the account Git integration reported a disconnected GitHub installation. The following sequence is retained as historical evidence and must not be used to reconnect the retired bridge without a new reviewed infrastructure decision:

1. Open Cloudflare Dashboard > Workers & Pages > Git integrations.
2. Reconnect or reinstall the GitHub integration for the `Hitsuki-Ban` account.
3. Grant the integration access to the private `Hitsuki-Ban/SubversionR-private` repository.
4. Return to Workers & Pages and reconnect `subversionr-pr-fast` to `Hitsuki-Ban/SubversionR-private`.
5. Open a test pull request and confirm Workers Builds creates a preview build check for the head commit.

If the dashboard still reports the Git account as disconnected after reinstalling, remove the Cloudflare GitHub app installation and install it again for this repository before retrying the Workers Builds connection.

The bridge script fails fast when required tools or commands are unavailable. It prepares `pnpm@11.5.2`, installs PowerShell `7.6.3` when `pwsh` is not already available, installs Rust `1.96.0` with `rustfmt`, then runs:

1. `pnpm install --frozen-lockfile`
2. `pnpm -r check`
3. `pnpm -r test`
4. `pnpm release:test-state-engine-beta-performance:win32-x64`
5. `cargo +1.96.0 fmt --all -- --check`
6. `cargo +1.96.0 test --workspace --lib`
7. `cargo +1.96.0 test -p subversionr-protocol --test protocol_contract`

## Scope

This bridge is a Linux Workers Builds check. It does not replace the Windows-only native release gates in `.github/workflows/ci.yml`.

Excluded from the bridge:

- Other PowerShell release/documentation checks that require heavier Windows, native, VSIX, installed VS Code, or publication state.
- `win32-x64` native remote fuzz preflight generation and verification.
- Native script tests that depend on Windows paths, MSVC, `VsDevCmd.bat`, or staged native binaries.
- Daemon integration tests that assert Windows-specific path handling.

The historical plan stated: the bridge is scheduled for retirement at the public repository migration. After the public `Hitsuki-Ban/SubversionR` repository has the baseline and the GitHub Actions `PR Fast / windows` check is green there, disconnect Workers Builds from the repository, disable non-production branch triggers, record the retirement date and final state here, and keep this document for historical evidence.

Cutover evidence: the public baseline, public pull-request check, and public `main` push check are green. The bridge was then disconnected through the Cloudflare API; both trigger records were removed and the post-retirement trigger count is zero.

Retirement date: 2026-07-10.

## Required Check Naming

The short-path Workers Builds bridge creates a Cloudflare-owned build check. If repository protection later requires a specific legacy GitHub Actions context, change the required check to the Cloudflare Workers Builds check for the temporary period.

If the required check name cannot change, use a separate relay:

1. Create a Cloudflare Worker that receives GitHub `pull_request` and `push` webhooks.
2. Verify `X-Hub-Signature-256` with a webhook secret stored as a Cloudflare secret.
3. Write a `pending` commit status to the PR head SHA.
4. Trigger a Cloudflare Workers Builds or Pages build for that head branch or commit.
5. Poll the Cloudflare build result.
6. Write `success`, `failure`, or `error` back to GitHub with a dedicated status context such as `PR Fast / Cloudflare`.

Do not store the GitHub token, Cloudflare API token, webhook secret, deploy hook URL, or build token in this repository.

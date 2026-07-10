# Public Cutover Runbook

This runbook records the controlled move from the private development repository to the public `Hitsuki-Ban/SubversionR` repository. The cutover procedure remains for auditability; the post-cutover section records current evidence and unresolved owner or release-evidence work.

## Preconditions

- #236 has merged and the public command namespace is the only supported command namespace.
- #243 has merged and the `win32-x64` Beta candidate evidence bundle has been regenerated and verified from that merge base.
- The private repository working tree has no unrelated uncommitted changes before the baseline is prepared.
- `.gitignore` excludes `target/`, `.cache/`, `node_modules/`, generated VSIX files, and transient logs.
- `Reference/` remains private and is excluded from the public baseline history.

## Baseline

The public repository history starts from one fresh squash-style baseline commit. Do not push private history, private issue references, local handoff notes, release evidence caches, build outputs, or generated dependency directories.

Baseline verification before the public push:

1. Create the baseline from the merged private `main` tree after removing private-only material.
2. Confirm `Reference/` is absent from the public baseline tree.
3. Confirm ignored generated paths are absent: `target/`, `.cache/`, `node_modules/`, `packages/vscode-extension/dist/`, and `*.vsix`.
4. Run a secrets scan on the public baseline tree.
5. Confirm `README.md`, `SECURITY.md`, `SUPPORT.md`, `CHANGELOG.md`, `.github/workflows/pr-fast.yml`, `.github/workflows/ci.yml`, and `.github/ISSUE_TEMPLATE/` are present.

## Public Repository

- Repository: `https://github.com/Hitsuki-Ban/SubversionR`
- Default branch: `main`
- Public branch protection must require the exact `PR Fast / windows` check after the first public run creates it.
- Repository metadata after baseline:
  - Description: `Native Subversion client for VS Code`
  - Topics: `svn`, `subversion`, `vscode-extension`, `scm`
  - Homepage: `https://github.com/Hitsuki-Ban/SubversionR#readme`
  - Social preview: SubversionR-branded image prepared outside the private evidence tree.

## CI Home Migration

After the public baseline is pushed:

1. Open a public test PR or push a temporary branch to confirm `.github/workflows/pr-fast.yml` creates `PR Fast / windows`.
2. Require `PR Fast / windows` on public `main` branch protection.
3. Confirm `.github/workflows/ci.yml` remains `workflow_dispatch` plus weekly schedule only.
4. Disable both workflows in the private repository through GitHub Actions UI.
5. Record the private workflow disable date in `docs/ci/github-actions-restoration.md`.

## Cloudflare Bridge Retirement

The temporary private-repository Workers Builds bridge was retired on 2026-07-10 after `PR Fast / windows` passed on a public pull request and the resulting public `main` push. Public branch protection remained a separate owner UI follow-up and had not been configured at the time of retirement.

Completed retirement state:

1. The non-production branch trigger and default-branch trigger were removed.
2. The private GitHub repository connection was disconnected.
3. The post-retirement trigger count is zero and no build configuration remains for `subversionr-pr-fast`.
4. The known Phase 1 successful build record remains readable as historical evidence.
5. The retirement date and final state are recorded in `docs/ci/cloudflare-pr-fast-bridge.md`.

Do not record Cloudflare API tokens, deploy hook URLs, build tokens, webhook secrets, or credential values in this repository.

## Release

The first public Beta release is `v0.2.0-beta.1`.

Release checklist:

1. Tag `v0.2.0-beta.1` in the public repository after the baseline and CI home migration are complete.
2. Create a GitHub pre-release.
3. Attach the audited `win32-x64` VSIX, SBOM, `THIRD-PARTY-NOTICES.md`, and Beta evidence bundle.
4. Generate artifact attestation with the public GitHub Actions release workflow and verify it with the command recorded by the M7j2b provenance input contract.
5. Keep Marketplace publication and Marketplace public install as blocked until a separate release gate closes them.

## Public Information Surface

Before public announcement:

1. Confirm `README.md` describes install-from-Releases VSIX sideloading, Beta scope, current limits, support paths, and screenshots or release-evidence image locations.
2. Confirm `SECURITY.md` routes vulnerability reports to GitHub Private Vulnerability Reporting after it is enabled.
3. Enable GitHub Private Vulnerability Reporting on the public repository.
4. Confirm issue forms render in the public repository and blank issues remain disabled.
5. Confirm `CHANGELOG.md` and release notes describe the same `0.2.0` Beta scope and non-claims as `docs/release/public-claim-matrix.md`.

## Private Repository Freeze

After the public repository baseline and CI home are confirmed:

1. The private repository becomes a read-only archive: no new branches, pull requests, or merges after the cutover.
2. Development, Codex slices, and all CI move to the public repository; private GitHub Actions workflows stay disabled so no scheduled or PR runs consume paid minutes.
3. Record the freeze date in this runbook when it happens.

## Post-Cutover Evidence

After the public cutover:

1. Record confirmed public repository, CI, Cloudflare retirement, and GitHub prerelease facts in `docs/release/public-cutover-evidence.json`; do not infer unverified repository metadata or owner-only settings.
2. Regenerate and verify `subversionr.release.publication-gaps.win32-x64.v1` only from the exact released VSIX bytes and matching upstream VSIX/provenance evidence. The released VSIX SHA256 must remain `d8ea4bfc187598a80ef0131f6345a60b8f3dcba2c9b22b992ea370f12eaa85cb`.
3. Keep the post-cutover Beta-G chain blocked. The published `subversionr-win32-x64-beta-candidate.zip` declares 1,462 manifest payloads but has 29 missing payloads and 421 size or SHA256 mismatches; it contains `svn-r-win32-x64-0.1.0.vsix` (`ff7094c02b27914351fde4d9ae9b09dd8a3cf4af00f983ddf085adb808a3167b`) instead of the released VSIX.
4. Regenerate a self-consistent Beta candidate bundle from matching candidate inputs, then run the unchanged bundle-manifest and candidate-consistency verifiers. Do not recover evidence from the inconsistent published ZIP or weaken either verifier.
5. The released VSIX subject was published and verified by workflow run `https://github.com/Hitsuki-Ban/SubversionR/actions/runs/29087683655`; the attestation is `https://github.com/Hitsuki-Ban/SubversionR/attestations/34733676`, with the hash-bound record, exact Sigstore bundle, and exact verification result in `docs/release/github-attestation-evidence.win32-x64.json`, `docs/release/github-attestation-bundle.win32-x64.json`, and `docs/release/github-attestation-verification.win32-x64.json`. This post-release attestation does not prove the original VSIX source-to-binary build provenance.
6. Keep `publicReadinessClaim=false` until the Beta-G inconsistency, Marketplace/public install, signing, previous-stable rollback, and final approval gates are closed.

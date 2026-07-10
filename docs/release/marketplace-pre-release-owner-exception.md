# Marketplace Pre-release Owner Exception

Decision source: public issue [#14](https://github.com/Hitsuki-Ban/SubversionR/issues/14), recorded on 2026-07-11.

## Scope

The owner authorizes one automated Visual Studio Marketplace pre-release publication for the exact `hitsuki-ban.subversionr` Windows `win32-x64` candidate after all of these conditions pass:

- release tag: `v0.2.0-beta.1`;
- extension version: `0.2.0`;
- asset name: `subversionr-win32-x64-0.2.0.vsix`;
- asset SHA256: `d8ea4bfc187598a80ef0131f6345a60b8f3dcba2c9b22b992ea370f12eaa85cb`;

- the release asset name, size, and SHA256 match the source-controlled GitHub attestation contract;
- `gh attestation verify` passes the contract's repository, signer workflow, source ref, source digest, signer digest, predicate type, and hosted-runner policy;
- the VSIX manifest already contains `Microsoft.VisualStudio.Code.PreRelease`;
- GitHub OIDC signs in through the protected `marketplace` environment and `vsce` uses `--azure-credential` directly;
- the exact downloaded VSIX is published with `--packagePath` and `--pre-release` without rebuilding or rewriting it; and
- a successful workflow run records the bounded Marketplace publication evidence.

This exception applies to `SEC-015`, `MIG-010`, and `MIG-012` only for that bounded pre-release operation. It permits the operation before final SBOM/NOTICE/legal approval and before real previous-stable upgrade/rollback evidence exists. It does not mark those requirements verified and does not change their release-blocker status in the security evidence matrix.

## Current 0.2.0 Constraint

The attested `subversionr-win32-x64-0.2.0.vsix` from release `v0.2.0-beta.1` does not contain the Marketplace pre-release manifest property. `vsce publish --packagePath ... --pre-release` rejects those bytes. Rebuilding or rewriting the released asset would invalidate its attestation contract, so the automated workflow must fail before Azure login for this asset.

The existing Marketplace listing predates this pipeline. It is not evidence that version `0.2.0` was published by the Entra workflow.

## Non-claims

This exception does not claim public release readiness, Marketplace public-install verification, artifact signing, signed source-to-binary provenance, final vulnerability approval, final SBOM/NOTICE/legal approval, or previous-stable rollback. It does not authorize a stable Marketplace publication, a credential fallback, or replacement of an existing release asset.

The exception is consumed only by one successful, evidence-recorded pre-release workflow run for the exact subject above. It cannot transfer to a rebuilt asset or a later version; a later candidate requires a new owner decision. Until such a run exists, Marketplace publication for the current candidate remains blocked.

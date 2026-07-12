# Marketplace 0.2.3 Pre-release Owner Exception

Decision sources: public issues [#14](https://github.com/Hitsuki-Ban/SubversionR/issues/14) and [#43](https://github.com/Hitsuki-Ban/SubversionR/issues/43), recorded on 2026-07-12.

## Scope

The owner authorizes one automated Visual Studio Marketplace pre-release publication for this exact Windows candidate:

- extension: `hitsuki-ban.subversionr`;
- Marketplace display name: `SVN-R`;
- target: `win32-x64`;
- release tag: `v0.2.3-beta.1`;
- asset name: `subversionr-win32-x64-0.2.3.vsix`;
- asset size: `8287085` bytes;
- asset SHA256: `f99b52d7b5c2b881796ddb66aa141e2ae44edcebe70a2925abdf3457b14d6db4`.

The operation is authorized only after the source-controlled candidate contract matches those bytes, the GitHub pre-release exists, and `gh attestation verify` succeeds for the public `main` workflow SHA, signer workflow, source ref and digest, predicate type, and hosted-runner policy. The packaged VSIX must contain exactly one `Microsoft.VisualStudio.Code.PreRelease` property with `Value="true"`. Verification must finish before Azure login; publication then uses the protected `marketplace` environment and direct `vsce publish --packagePath ... --pre-release --azure-credential` with no credential fallback or rebuild.

The consumed 0.2.2 exception and its completed release, attestation, and Marketplace publication remain historical evidence. This 0.2.3 authorization is a separate exact-subject decision and does not alter or reuse the 0.2.2 bytes.

## Non-claims

This exception permits one bounded pre-release publication before final SBOM/NOTICE/legal approval and real previous-stable upgrade/rollback evidence. It does not mark `SEC-015`, `MIG-010`, or `MIG-012` verified, authorize a stable publication, prove Marketplace public install, prove artifact signing or signed source-to-binary provenance, or claim public release readiness.

The bounded authorization applies to `SEC-015`, `MIG-010`, and `MIG-012` only for the exact operation above; their release-blocker status otherwise remains unchanged.

This exception does not claim public release readiness.

The exception is consumed only by one successful workflow run whose publication evidence binds the exact subject above. It cannot transfer to different bytes, another tag, or a later version.

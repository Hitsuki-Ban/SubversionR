# Marketplace 0.2.4 Pre-release Owner Exception

Decision sources: public issues [#14](https://github.com/Hitsuki-Ban/SubversionR/issues/14) and [#56](https://github.com/Hitsuki-Ban/SubversionR/issues/56), recorded on 2026-07-14.

## Scope

The owner authorizes one automated Visual Studio Marketplace pre-release publication for this exact Windows candidate:

- extension: `hitsuki-ban.subversionr`;
- Marketplace display name: `SVN-R`;
- target: `win32-x64`;
- release tag: `v0.2.4-beta.1`;
- asset name: `subversionr-win32-x64-0.2.4.vsix`;
- asset size: `8291313` bytes;
- asset SHA256: `b21b9082e52b48d5521f988394a6aa0ce0bbf88e3ab0d2bdbafd0445a375742e`.

The operation is authorized only after the source-controlled candidate contract matches those bytes, the GitHub pre-release exists, and `gh attestation verify` succeeds for the public `main` workflow SHA, signer workflow, source ref and digest, predicate type, and hosted-runner policy. The packaged VSIX must contain exactly one `Microsoft.VisualStudio.Code.PreRelease` property with `Value="true"`. Verification must finish before Azure login; publication then uses the protected `marketplace` environment and direct `vsce publish --packagePath ... --pre-release --azure-credential` with no credential fallback or rebuild.

The consumed 0.2.3 exception and its completed release, attestation, and Marketplace publication remain historical evidence. This 0.2.4 authorization is a separate exact-subject decision and does not alter or reuse the 0.2.3 bytes.

## Non-claims

This exception permits one bounded pre-release publication before final SBOM/NOTICE/legal approval and real previous-stable upgrade/rollback evidence. It does not mark `SEC-015`, `MIG-010`, or `MIG-012` verified, authorize a stable publication, prove Marketplace public install, prove artifact signing or signed source-to-binary provenance, or claim public release readiness.

The bounded authorization applies to `SEC-015`, `MIG-010`, and `MIG-012` only for the exact operation above; their release-blocker status otherwise remains unchanged.

This exception does not claim public release readiness.

The exception is consumed only by one successful workflow run whose publication evidence binds the exact subject above. It cannot transfer to different bytes, another tag, or a later version.

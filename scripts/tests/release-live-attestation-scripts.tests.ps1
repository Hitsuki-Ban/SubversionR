$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$subjectVerifier = Join-Path $repoRoot "scripts\release\verify-release-attestation-subject.ps1"
$predicateGenerator = Join-Path $repoRoot "scripts\release\generate-post-release-asset-verification-predicate.ps1"
$evidenceRecorder = Join-Path $repoRoot "scripts\release\record-live-github-attestation.ps1"
$workflowPath = Join-Path $repoRoot ".github\workflows\attest-release-vsix.yml"

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw $Message
  }
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
  if ($Expected -ne $Actual) {
    throw "$Message Expected '$Expected', got '$Actual'."
  }
}

function Assert-NativeCommandFailsContaining([scriptblock]$Action, [string]$ExpectedText, [string]$Message) {
  $output = & $Action 2>&1
  $exitCode = $LASTEXITCODE
  Assert-True ($exitCode -ne 0) "$Message Expected native command to fail."
  $text = $output | Out-String
  Assert-True ($text.Contains($ExpectedText)) "$Message Expected output to contain '$ExpectedText', got '$text'."
}

function Get-Sha256([string]$Path) {
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-JsonFile([string]$Path, [object]$Value) {
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

$tempRoot = Join-Path $repoRoot "target\tests\release-live-attestation-scripts\$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  $subjectPath = Join-Path $tempRoot "subversionr-win32-x64-0.2.0.vsix"
  [System.IO.File]::WriteAllBytes($subjectPath, [byte[]](0x53, 0x75, 0x62, 0x76, 0x65, 0x72, 0x73, 0x69, 0x6f, 0x6e, 0x52))
  $subjectSha256 = Get-Sha256 $subjectPath
  $contractPath = Join-Path $tempRoot "github-attestation-contract.win32-x64.json"
  $contract = [pscustomobject]@{
    schemaVersion = 1
    schema = "subversionr.release.github-attestation-contract.win32-x64.v1"
    publicReadinessClaim = $false
    target = "win32-x64"
    release = [pscustomobject]@{
      tag = "v0.2.0-beta.1"
      url = "https://github.com/Hitsuki-Ban/SubversionR/releases/tag/v0.2.0-beta.1"
    }
    subject = [pscustomobject]@{
      name = "subversionr-win32-x64-0.2.0.vsix"
      size = (Get-Item -LiteralPath $subjectPath).Length
      sha256 = $subjectSha256
    }
    attestation = [pscustomobject]@{
      provider = "github-artifact-attestations"
      action = "actions/attest@v4"
      actionDigest = "a1948c3f048ba23858d222213b7c278aabede763"
      predicateType = "https://raw.githubusercontent.com/Hitsuki-Ban/SubversionR/main/docs/release/post-release-asset-verification-predicate.v1.schema.json"
      predicateSchemaPath = "docs/release/post-release-asset-verification-predicate.v1.schema.json"
    }
    workflow = [pscustomobject]@{
      path = ".github/workflows/attest-release-vsix.yml"
      runner = "ubuntu-24.04"
      trigger = "workflow_dispatch"
      requiredPermissions = @("contents: read", "id-token: write", "attestations: write")
    }
    verificationPolicy = [pscustomobject]@{
      repository = "Hitsuki-Ban/SubversionR"
      signerWorkflow = "Hitsuki-Ban/SubversionR/.github/workflows/attest-release-vsix.yml"
      predicateType = "https://raw.githubusercontent.com/Hitsuki-Ban/SubversionR/main/docs/release/post-release-asset-verification-predicate.v1.schema.json"
      bundleRequired = $true
      sourceRefRequired = $true
      sourceDigestRequired = $true
      signerDigestRequired = $true
      denySelfHostedRunners = $true
      format = "json"
    }
  }
  Write-JsonFile $contractPath $contract

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $subjectVerifier `
    -Target win32-x64 `
    -ContractPath $contractPath `
    -SubjectPath $subjectPath `
    -ReleaseTag v0.2.0-beta.1
  if ($LASTEXITCODE -ne 0) {
    throw "verify-release-attestation-subject.ps1 failed with exit code $LASTEXITCODE."
  }

  $predicatePath = Join-Path $tempRoot "post-release-asset-verification-predicate.json"
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $predicateGenerator `
    -Target win32-x64 `
    -ContractPath $contractPath `
    -SubjectPath $subjectPath `
    -ReleaseTag v0.2.0-beta.1 `
    -OutputPath $predicatePath
  if ($LASTEXITCODE -ne 0) {
    throw "generate-post-release-asset-verification-predicate.ps1 failed with exit code $LASTEXITCODE."
  }
  $predicate = Get-Content -Raw -LiteralPath $predicatePath | ConvertFrom-Json
  Assert-Equal "post-release-asset-digest-verification" $predicate.claim "Generated predicate should record the post-release verification claim."
  Assert-Equal "False" ([string]$predicate.originalBuildProvenanceClaim) "Generated predicate must reject original build provenance claims."
  Assert-Equal "False" ([string]$predicate.artifactSignatureClaim) "Generated predicate must reject artifact signature claims."
  Assert-Equal $subjectSha256 $predicate.release.assetSha256 "Generated predicate should bind the verified asset digest."
  Assert-Equal (Get-Sha256 $contractPath) $predicate.contract.sha256 "Generated predicate should bind the contract digest."

  $bundlePath = Join-Path $tempRoot "sha256-$subjectSha256.jsonl"
  $bundle = [pscustomobject]@{
    mediaType = "application/vnd.dev.sigstore.bundle.v0.3+json"
    verificationMaterial = [pscustomobject]@{ certificate = [pscustomobject]@{ rawBytes = "fixture" } }
    dsseEnvelope = [pscustomobject]@{ payloadType = "application/vnd.in-toto+json"; payload = "fixture"; signatures = @() }
  }
  Write-JsonFile $bundlePath $bundle
  $verificationResultPath = Join-Path $tempRoot "verification.json"
  Write-JsonFile $verificationResultPath @(
    [pscustomobject]@{
      attestation = [pscustomobject]@{ bundle = $bundle }
      verificationResult = [pscustomobject]@{
        mediaType = "application/vnd.dev.sigstore.verificationresult+json;version=0.1"
        signature = [pscustomobject]@{
          certificate = [pscustomobject]@{
            subjectAlternativeName = "https://github.com/Hitsuki-Ban/SubversionR/.github/workflows/attest-release-vsix.yml@refs/heads/codex/issue-5-live-attestation"
            githubWorkflowRepository = "Hitsuki-Ban/SubversionR"
            githubWorkflowTrigger = "workflow_dispatch"
            githubWorkflowSHA = "0123456789abcdef0123456789abcdef01234567"
            githubWorkflowRef = "refs/heads/codex/issue-5-live-attestation"
            buildSignerDigest = "0123456789abcdef0123456789abcdef01234567"
            sourceRepositoryDigest = "0123456789abcdef0123456789abcdef01234567"
            runnerEnvironment = "github-hosted"
            sourceRepositoryVisibilityAtSigning = "public"
            runInvocationURI = "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/456/attempts/1"
          }
        }
        verifiedTimestamps = @([pscustomobject]@{ type = "Tlog"; uri = "https://rekor.sigstore.dev" })
        statement = [pscustomobject]@{
          subject = @(
            [pscustomobject]@{
              name = "subversionr-win32-x64-0.2.0.vsix"
              digest = [pscustomobject]@{ sha256 = $subjectSha256 }
            }
          )
          predicateType = "https://raw.githubusercontent.com/Hitsuki-Ban/SubversionR/main/docs/release/post-release-asset-verification-predicate.v1.schema.json"
          predicate = $predicate
        }
      }
    }
  )
  $evidencePath = Join-Path $tempRoot "subversionr-live-github-attestation-win32-x64.json"
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $evidenceRecorder `
    -Target win32-x64 `
    -ContractPath $contractPath `
    -SubjectPath $subjectPath `
    -ReleaseTag v0.2.0-beta.1 `
    -BundlePath $bundlePath `
    -VerificationResultPath $verificationResultPath `
    -RunId 456 `
    -RunAttempt 1 `
    -RunUrl "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/456" `
    -HeadSha "0123456789abcdef0123456789abcdef01234567" `
    -SourceRef "refs/heads/codex/issue-5-live-attestation" `
    -EventName workflow_dispatch `
    -AttestationId 123 `
    -AttestationUrl "https://github.com/Hitsuki-Ban/SubversionR/attestations/123" `
    -OutputPath $evidencePath
  if ($LASTEXITCODE -ne 0) {
    throw "record-live-github-attestation.ps1 failed with exit code $LASTEXITCODE."
  }

  $evidence = Get-Content -Raw -LiteralPath $evidencePath | ConvertFrom-Json
  Assert-Equal "subversionr.release.live-github-attestation.win32-x64.v1" $evidence.schema "Live attestation evidence schema should match."
  Assert-Equal "False" ([string]$evidence.publicReadinessClaim) "Live attestation evidence must not claim public readiness."
  Assert-Equal "False" ([string]$evidence.signingClaim) "Live attestation evidence must not claim signing."
  Assert-Equal "live-attestation-verified" $evidence.status "Live attestation evidence should record successful verification."
  Assert-Equal $subjectSha256 $evidence.subject.sha256 "Live attestation evidence should bind the subject SHA256."
  Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/456" $evidence.workflow.runUrl "Live attestation evidence should record the run URL."
  Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/attestations/123" $evidence.attestation.url "Live attestation evidence should record the attestation URL."
  Assert-Equal (Get-Sha256 $bundlePath) $evidence.attestation.bundleSha256 "Live attestation evidence should hash the exact bundle."
  Assert-Equal (Get-Sha256 $verificationResultPath) $evidence.verification.resultSha256 "Live attestation evidence should hash the exact verification result."
  Assert-Equal "True" ([string]$evidence.verification.bundleMatched) "Live attestation evidence should record exact bundle matching."
  Assert-Equal "False" ([string]$evidence.attestation.originalBuildProvenanceClaim) "Live attestation evidence must preserve the signed original-build non-claim."
  Assert-Equal "False" ([string]$evidence.attestation.artifactSignatureClaim) "Live attestation evidence must preserve the signed artifact-signature non-claim."
  Assert-True ($evidence.verification.command.Contains("--bundle $($evidence.attestation.bundlePath)")) "Live attestation verification command should bind the exact bundle path."
  Assert-True ($evidence.verification.command.Contains("--source-ref refs/heads/codex/issue-5-live-attestation")) "Live attestation verification command should bind the source ref."
  Assert-True ($evidence.verification.command.Contains("--source-digest 0123456789abcdef0123456789abcdef01234567")) "Live attestation verification command should bind the source digest."
  Assert-Equal "True" ([string]$evidence.verification.verified) "Live attestation evidence should record successful verification."

  $badContractPath = Join-Path $tempRoot "bad-hash-contract.json"
  $badContract = Get-Content -Raw -LiteralPath $contractPath | ConvertFrom-Json
  $badContract.subject.sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  Write-JsonFile $badContractPath $badContract
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $subjectVerifier `
      -Target win32-x64 `
      -ContractPath $badContractPath `
      -SubjectPath $subjectPath `
      -ReleaseTag v0.2.0-beta.1
  } "SHA256 must match current bytes" "Subject verification should reject SHA256 drift."

  $badContractPath = Join-Path $tempRoot "bad-boolean-contract.json"
  $badContract = Get-Content -Raw -LiteralPath $contractPath | ConvertFrom-Json
  $badContract.publicReadinessClaim = "False"
  Write-JsonFile $badContractPath $badContract
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $subjectVerifier `
      -Target win32-x64 `
      -ContractPath $badContractPath `
      -SubjectPath $subjectPath `
      -ReleaseTag v0.2.0-beta.1
  } "must be a JSON boolean" "Subject verification should reject string boolean values."

  $badVerificationPath = Join-Path $tempRoot "bad-verification.json"
  $badVerification = Get-Content -Raw -LiteralPath $verificationResultPath | ConvertFrom-Json
  @($badVerification)[0].verificationResult.statement.subject[0].digest.sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  Write-JsonFile $badVerificationPath $badVerification
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $evidenceRecorder `
      -Target win32-x64 `
      -ContractPath $contractPath `
      -SubjectPath $subjectPath `
      -ReleaseTag v0.2.0-beta.1 `
      -BundlePath $bundlePath `
      -VerificationResultPath $badVerificationPath `
      -RunId 456 `
      -RunAttempt 1 `
      -RunUrl "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/456" `
      -HeadSha "0123456789abcdef0123456789abcdef01234567" `
      -SourceRef "refs/heads/codex/issue-5-live-attestation" `
      -EventName workflow_dispatch `
      -AttestationId 123 `
      -AttestationUrl "https://github.com/Hitsuki-Ban/SubversionR/attestations/123" `
      -OutputPath (Join-Path $tempRoot "bad-evidence.json")
  } "must bind the contracted subject" "Evidence recording should reject verification results for another digest."

  $overclaimVerificationPath = Join-Path $tempRoot "overclaim-verification.json"
  $overclaimVerification = Get-Content -Raw -LiteralPath $verificationResultPath | ConvertFrom-Json
  @($overclaimVerification)[0].verificationResult.statement.predicate.originalBuildProvenanceClaim = $true
  Write-JsonFile $overclaimVerificationPath $overclaimVerification
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $evidenceRecorder `
      -Target win32-x64 `
      -ContractPath $contractPath `
      -SubjectPath $subjectPath `
      -ReleaseTag v0.2.0-beta.1 `
      -BundlePath $bundlePath `
      -VerificationResultPath $overclaimVerificationPath `
      -RunId 456 `
      -RunAttempt 1 `
      -RunUrl "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/456" `
      -HeadSha "0123456789abcdef0123456789abcdef01234567" `
      -SourceRef "refs/heads/codex/issue-5-live-attestation" `
      -EventName workflow_dispatch `
      -AttestationId 123 `
      -AttestationUrl "https://github.com/Hitsuki-Ban/SubversionR/attestations/123" `
      -OutputPath (Join-Path $tempRoot "overclaim-evidence.json")
  } "originalBuildProvenanceClaim must match the signed predicate contract" "Evidence recording should reject signed build provenance overclaims."

  $mismatchedBundleVerificationPath = Join-Path $tempRoot "mismatched-bundle-verification.json"
  $mismatchedBundleVerification = Get-Content -Raw -LiteralPath $verificationResultPath | ConvertFrom-Json
  @($mismatchedBundleVerification)[0].attestation.bundle.mediaType = "application/vnd.dev.sigstore.bundle.v0.2+json"
  Write-JsonFile $mismatchedBundleVerificationPath $mismatchedBundleVerification
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $evidenceRecorder `
      -Target win32-x64 `
      -ContractPath $contractPath `
      -SubjectPath $subjectPath `
      -ReleaseTag v0.2.0-beta.1 `
      -BundlePath $bundlePath `
      -VerificationResultPath $mismatchedBundleVerificationPath `
      -RunId 456 `
      -RunAttempt 1 `
      -RunUrl "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/456" `
      -HeadSha "0123456789abcdef0123456789abcdef01234567" `
      -SourceRef "refs/heads/codex/issue-5-live-attestation" `
      -EventName workflow_dispatch `
      -AttestationId 123 `
      -AttestationUrl "https://github.com/Hitsuki-Ban/SubversionR/attestations/123" `
      -OutputPath (Join-Path $tempRoot "mismatched-bundle-evidence.json")
  } "exact BundlePath attestation" "Evidence recording should reject a verification result for a different bundle."

  $workflow = Get-Content -Raw -LiteralPath $workflowPath
  foreach ($term in @(
      "workflow_dispatch:",
      "contents: read",
      "id-token: write",
      "attestations: write",
      "actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5",
      "actions/attest@a1948c3f048ba23858d222213b7c278aabede763",
      "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
      "subject-path: target/release-attestation/win32-x64/subversionr-win32-x64-0.2.0.vsix",
      "generate-post-release-asset-verification-predicate.ps1",
      "predicate-type: https://raw.githubusercontent.com/Hitsuki-Ban/SubversionR/main/docs/release/post-release-asset-verification-predicate.v1.schema.json",
      "predicate-path: target/release-attestation/win32-x64/post-release-asset-verification-predicate.json",
      "--bundle `$env:ATTESTATION_BUNDLE_PATH",
      "--signer-workflow Hitsuki-Ban/SubversionR/.github/workflows/attest-release-vsix.yml",
      "--signer-digest `$env:SOURCE_SHA",
      "--source-ref `$env:SOURCE_REF",
      "--source-digest `$env:SOURCE_SHA",
      "--deny-self-hosted-runners",
      "record-live-github-attestation.ps1"
    )) {
    Assert-True ($workflow.Contains($term)) "Attestation workflow should include '$term'."
  }
  Write-Host "Release live GitHub attestation script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

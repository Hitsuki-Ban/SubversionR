$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$recorder = Join-Path $repoRoot "scripts\release\record-marketplace-publication.ps1"
$workflowPath = Join-Path $repoRoot ".github\workflows\publish-marketplace.yml"
$publicationHeadSha = "fedcba9876543210fedcba9876543210fedcba98"

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
  if ($Expected -ne $Actual) { throw "$Message Expected '$Expected', got '$Actual'." }
}

function Assert-NativeCommandFailsContaining([scriptblock]$Action, [string]$ExpectedText, [string]$Message) {
  $output = & $Action 2>&1
  $exitCode = $LASTEXITCODE
  Assert-True ($exitCode -ne 0) "$Message Expected native command to fail."
  $text = $output | Out-String
  Assert-True ($text.Contains($ExpectedText)) "$Message Expected output to contain '$ExpectedText', got '$text'."
}

function Assert-ContainsInOrder([string]$Text, [string[]]$Terms, [string]$Message) {
  $offset = 0
  foreach ($term in $Terms) {
    $index = $Text.IndexOf($term, $offset, [System.StringComparison]::Ordinal)
    Assert-True ($index -ge 0) "$Message Missing '$term'."
    $offset = $index + $term.Length
  }
}

function Get-Sha256([string]$Path) {
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-JsonFile([string]$Path, [object]$Value) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8
}

function New-TestVsix([string]$Path, [bool]$PreRelease) {
  $stagingRoot = Join-Path (Split-Path -Parent $Path) "vsix-$([Guid]::NewGuid().ToString('N'))"
  New-Item -ItemType Directory -Force -Path (Join-Path $stagingRoot "extension") | Out-Null
  $property = if ($PreRelease) {
    '<Properties><Property Id="Microsoft.VisualStudio.Code.PreRelease" Value="true" /></Properties>'
  }
  else { "" }
  @"
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Language="en-US" Id="subversionr" Version="0.2.4" Publisher="hitsuki-ban" TargetPlatform="win32-x64" />
    <DisplayName>SVN-R</DisplayName>
    $property
  </Metadata>
</PackageManifest>
"@ | Set-Content -LiteralPath (Join-Path $stagingRoot "extension.vsixmanifest") -NoNewline -Encoding utf8
  @{ name = "subversionr"; publisher = "hitsuki-ban"; version = "0.2.4" } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stagingRoot "extension\package.json") -Encoding utf8
  [System.IO.Compression.ZipFile]::CreateFromDirectory($stagingRoot, $Path)
  Remove-Item -LiteralPath $stagingRoot -Recurse -Force
}

function New-Fixture([string]$Root, [bool]$PreRelease) {
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  $vsixPath = Join-Path $Root "subversionr-win32-x64-0.2.4.vsix"
  New-TestVsix -Path $vsixPath -PreRelease $PreRelease
  $subjectSha = Get-Sha256 $vsixPath
  $contractPath = Join-Path $Root "github-attestation-candidate-contract.win32-x64.json"
  $contract = [pscustomobject]@{
    schemaVersion = 1
    schema = "subversionr.release.github-attestation-contract.win32-x64.v1"
    publicReadinessClaim = $false
    target = "win32-x64"
    release = [pscustomobject]@{
      tag = "v0.2.4-beta.1"
      url = "https://github.com/Hitsuki-Ban/SubversionR/releases/tag/v0.2.4-beta.1"
    }
    subject = [pscustomobject]@{
      name = "subversionr-win32-x64-0.2.4.vsix"
      size = [int64](Get-Item -LiteralPath $vsixPath).Length
      sha256 = $subjectSha
    }
    attestation = [pscustomobject]@{
      provider = "github-artifact-attestations"
      action = "actions/attest@v4"
      actionDigest = "a1948c3f048ba23858d222213b7c278aabede763"
      predicateType = "https://github.com/Hitsuki-Ban/SubversionR/attestations/post-release-asset/v1"
      predicateSchemaPath = "docs/release/post-release-asset-verification-predicate.v1.schema.json"
    }
    workflow = [pscustomobject]@{
      path = ".github/workflows/attest-release-vsix.yml"
      runner = "ubuntu-24.04"
      trigger = "workflow_dispatch"
      requiredPermissions = @("contents: read", "id-token: write", "attestations: write", "artifact-metadata: write")
    }
    verificationPolicy = [pscustomobject]@{
      repository = "Hitsuki-Ban/SubversionR"
      signerWorkflow = "Hitsuki-Ban/SubversionR/.github/workflows/attest-release-vsix.yml"
      predicateType = "https://github.com/Hitsuki-Ban/SubversionR/attestations/post-release-asset/v1"
      bundleRequired = $true
      sourceRefRequired = $true
      sourceDigestRequired = $true
      signerDigestRequired = $true
      denySelfHostedRunners = $true
      format = "json"
    }
  }
  Write-JsonFile $contractPath $contract

  $verificationPath = Join-Path $Root "gh-attestation-verification.json"
  Write-JsonFile $verificationPath @(
    [pscustomobject]@{
      verificationResult = [pscustomobject]@{
        verifiedTimestamps = @([pscustomobject]@{ type = "Tlog"; uri = "https://rekor.sigstore.dev" })
        signature = [pscustomobject]@{
          certificate = [pscustomobject]@{
            subjectAlternativeName = "https://github.com/Hitsuki-Ban/SubversionR/.github/workflows/attest-release-vsix.yml@refs/heads/main"
            githubWorkflowRepository = "Hitsuki-Ban/SubversionR"
            githubWorkflowTrigger = "workflow_dispatch"
            githubWorkflowRef = "refs/heads/main"
            githubWorkflowSHA = $publicationHeadSha
            buildSignerDigest = $publicationHeadSha
            sourceRepositoryRef = "refs/heads/main"
            sourceRepositoryDigest = $publicationHeadSha
            runnerEnvironment = "github-hosted"
            sourceRepositoryVisibilityAtSigning = "public"
          }
        }
        statement = [pscustomobject]@{
          subject = @([pscustomobject]@{ name = $contract.subject.name; digest = [pscustomobject]@{ sha256 = $contract.subject.sha256 } })
          predicateType = $contract.verificationPolicy.predicateType
        }
      }
    }
  )

  [pscustomobject]@{
    root = $Root
    vsixPath = $vsixPath
    contractPath = $contractPath
    verificationPath = $verificationPath
    outputPath = Join-Path $Root "marketplace-publication.json"
    subjectSha = $subjectSha
  }
}

function Invoke-Recorder([object]$Fixture, [string]$OutputPath = $Fixture.outputPath, [string]$VsixPath = $Fixture.vsixPath, [string]$VerificationPath = $Fixture.verificationPath, [switch]$ValidateOnly) {
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $recorder `
    -Target win32-x64 `
    -ContractPath $Fixture.contractPath `
    -AttestationVerificationResultPath $VerificationPath `
    -VsixPath $VsixPath `
    -ReleaseTag v0.2.4-beta.1 `
    -ExtensionId hitsuki-ban.subversionr `
    -ExtensionVersion 0.2.4 `
    -Repository Hitsuki-Ban/SubversionR `
    -WorkflowPath .github/workflows/publish-marketplace.yml `
    -RunId 789 `
    -RunAttempt 2 `
    -RunUrl https://github.com/Hitsuki-Ban/SubversionR/actions/runs/789 `
    -HeadSha $publicationHeadSha `
    -SourceRef refs/heads/main `
    -EventName workflow_dispatch `
    -OutputPath $OutputPath `
    -ValidateOnly:$ValidateOnly
}

$tempRoot = Join-Path $repoRoot "target\tests\release-marketplace-publication-scripts\$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  $fixture = New-Fixture -Root (Join-Path $tempRoot "positive") -PreRelease $true
  Invoke-Recorder $fixture
  if ($LASTEXITCODE -ne 0) { throw "record-marketplace-publication.ps1 failed with exit code $LASTEXITCODE." }

  $evidence = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  Assert-Equal "subversionr.release.marketplace-publication.win32-x64.v1" $evidence.schema "Publication evidence schema should match."
  Assert-Equal "marketplace-prerelease-published" $evidence.status "Publication evidence status should match."
  Assert-Equal "True" ([string]$evidence.preReleaseClaim) "Publication evidence must make the exact prerelease claim."
  foreach ($claim in @("publicReadinessClaim", "publicInstallClaim", "signingClaim", "rollbackClaim", "finalReviewClaim")) {
    Assert-Equal "False" ([string]$evidence.$claim) "Publication evidence $claim must remain false."
  }
  Assert-Equal "v0.2.4-beta.1" $evidence.release.tag "Publication evidence should bind the candidate release."
  Assert-Equal "0.2.4" $evidence.extension.version "Publication evidence should bind the extension version."
  Assert-Equal $fixture.subjectSha $evidence.vsix.sha256 "Publication evidence should bind the exact VSIX hash."
  Assert-Equal "True" ([string]$evidence.vsix.marketplacePreReleaseProperty) "Publication evidence should record the packaged prerelease property."
  Assert-Equal "True" ([string]$evidence.attestation.verified) "Publication evidence should record runtime attestation verification."
  Assert-Equal 1 $evidence.attestation.verificationResultCount "Publication evidence should record every matching verified attestation."
  Assert-Equal $publicationHeadSha $evidence.attestation.sourceSha "Publication evidence should bind verification to the current commit."
  Assert-Equal "refs/heads/main" $evidence.attestation.sourceRef "Publication evidence should bind verification to public main."
  Assert-Equal "True" ([string]$evidence.attestation.denySelfHostedRunners) "Publication evidence should record the runner policy."
  Assert-True (-not $evidence.attestation.PSObject.Properties["bundlePath"]) "Publication evidence must not depend on an attestation bundle."
  Assert-True (-not $evidence.attestation.PSObject.Properties["liveEvidencePath"]) "Publication evidence must not depend on historical live evidence."
  Assert-True ($evidence.publication.command.EndsWith("--pre-release --azure-credential")) "Publication evidence should record only the direct Azure credential publish path."
  foreach ($path in @($evidence.vsix.path, $evidence.attestation.contractPath, $evidence.attestation.verificationResultPath)) {
    Assert-True (-not [System.IO.Path]::IsPathRooted([string]$path)) "Recorded evidence paths must be repository-relative."
    Assert-True (-not ([string]$path).StartsWith("../", [System.StringComparison]::Ordinal)) "Recorded evidence paths must stay in the repository."
  }
  $serializedEvidence = Get-Content -Raw -LiteralPath $fixture.outputPath
  foreach ($forbidden in @("VSCE_PAT", "clientId", "tenantId", "clientSecret", "accessToken", "refreshToken", "AZURE_CLIENT_ID", "AZURE_TENANT_ID")) {
    Assert-True (-not $serializedEvidence.Contains($forbidden, [System.StringComparison]::OrdinalIgnoreCase)) "Publication evidence must not contain identity or credential field '$forbidden'."
  }

  $preflightOutputPath = Join-Path $fixture.root "preflight-must-not-exist.json"
  Invoke-Recorder -Fixture $fixture -OutputPath $preflightOutputPath -ValidateOnly
  if ($LASTEXITCODE -ne 0) { throw "record-marketplace-publication.ps1 preflight failed with exit code $LASTEXITCODE." }
  Assert-True (-not (Test-Path -LiteralPath $preflightOutputPath)) "Validation-only preflight must not write publication evidence."

  $duplicateVerificationPath = Join-Path $fixture.root "duplicate-valid-verification.json"
  $duplicateVerification = Get-Content -Raw -LiteralPath $fixture.verificationPath | ConvertFrom-Json
  Write-JsonFile $duplicateVerificationPath @($duplicateVerification, $duplicateVerification)
  $duplicateOutputPath = Join-Path $fixture.root "duplicate-valid-output.json"
  Invoke-Recorder -Fixture $fixture -VerificationPath $duplicateVerificationPath -OutputPath $duplicateOutputPath
  if ($LASTEXITCODE -ne 0) { throw "Recorder should accept multiple attestations that all satisfy the exact policy." }
  $duplicateEvidence = Get-Content -Raw -LiteralPath $duplicateOutputPath | ConvertFrom-Json
  Assert-Equal 2 $duplicateEvidence.attestation.verificationResultCount "Publication evidence should bind the complete verified-attestation result count."

  $mixedVerificationPath = Join-Path $fixture.root "mixed-verification.json"
  $invalidVerification = Get-Content -Raw -LiteralPath $fixture.verificationPath | ConvertFrom-Json
  $invalidVerification.verificationResult.signature.certificate.githubWorkflowSHA = "0" * 40
  Write-JsonFile $mixedVerificationPath @($duplicateVerification, $invalidVerification)
  Assert-NativeCommandFailsContaining {
    Invoke-Recorder -Fixture $fixture -VerificationPath $mixedVerificationPath -OutputPath (Join-Path $fixture.root "mixed-output.json")
  } "signer SHA must match the publication commit" "Recorder should reject the complete set when any matching result violates policy."

  $tamperedVsixPath = Join-Path $fixture.root "tampered\subversionr-win32-x64-0.2.4.vsix"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $tamperedVsixPath) | Out-Null
  Copy-Item -LiteralPath $fixture.vsixPath -Destination $tamperedVsixPath
  [System.IO.File]::AppendAllText($tamperedVsixPath, "tampered")
  Assert-NativeCommandFailsContaining {
    Invoke-Recorder -Fixture $fixture -VsixPath $tamperedVsixPath -OutputPath (Join-Path $fixture.root "tampered-output.json")
  } "size must match current bytes" "Recorder should reject tampered VSIX bytes."

  $badDigestPath = Join-Path $fixture.root "bad-digest-verification.json"
  $badDigest = Get-Content -Raw -LiteralPath $fixture.verificationPath | ConvertFrom-Json
  @($badDigest)[0].verificationResult.statement.subject[0].digest.sha256 = "a" * 64
  Write-JsonFile $badDigestPath $badDigest
  Assert-NativeCommandFailsContaining {
    Invoke-Recorder -Fixture $fixture -VerificationPath $badDigestPath -OutputPath (Join-Path $fixture.root "bad-digest-output.json")
  } "subject SHA256 must match" "Recorder should reject verification for different subject bytes."

  $badSignerPath = Join-Path $fixture.root "bad-signer-verification.json"
  $badSigner = Get-Content -Raw -LiteralPath $fixture.verificationPath | ConvertFrom-Json
  @($badSigner)[0].verificationResult.signature.certificate.githubWorkflowSHA = "0" * 40
  Write-JsonFile $badSignerPath $badSigner
  Assert-NativeCommandFailsContaining {
    Invoke-Recorder -Fixture $fixture -VerificationPath $badSignerPath -OutputPath (Join-Path $fixture.root "bad-signer-output.json")
  } "signer SHA must match the publication commit" "Recorder should reject verification from another signer commit."

  $overclaimContractPath = Join-Path $fixture.root "overclaim-contract.json"
  $overclaimContract = Get-Content -Raw -LiteralPath $fixture.contractPath | ConvertFrom-Json
  $overclaimContract.publicReadinessClaim = $true
  Write-JsonFile $overclaimContractPath $overclaimContract
  $overclaimFixture = $fixture.PSObject.Copy()
  $overclaimFixture.contractPath = $overclaimContractPath
  Assert-NativeCommandFailsContaining {
    Invoke-Recorder -Fixture $overclaimFixture -OutputPath (Join-Path $fixture.root "overclaim-output.json")
  } "publicReadinessClaim must match the contract" "Recorder should reject a public-readiness overclaim."

  $nonPrereleaseFixture = New-Fixture -Root (Join-Path $tempRoot "no-prerelease") -PreRelease $false
  Assert-NativeCommandFailsContaining {
    Invoke-Recorder -Fixture $nonPrereleaseFixture
  } "Microsoft.VisualStudio.Code.PreRelease" "Recorder should reject a VSIX without the packaged prerelease property."

  $outsideOutput = Join-Path ([System.IO.Path]::GetTempPath()) "subversionr-marketplace-publication-$([Guid]::NewGuid().ToString('N')).json"
  Assert-NativeCommandFailsContaining { Invoke-Recorder -Fixture $fixture -OutputPath $outsideOutput } "must resolve inside the repository" "Recorder should reject output outside the repository."
  Assert-True (-not (Test-Path -LiteralPath $outsideOutput)) "Recorder must not write outside the repository."

  $workflow = Get-Content -Raw -LiteralPath $workflowPath
  foreach ($term in @(
      "workflow_dispatch:",
      "environment: marketplace",
      "contents: read",
      "id-token: write",
      "docs/release/github-attestation-candidate-contract.win32-x64.json",
      "verify-release-attestation-subject.ps1",
      "Microsoft.VisualStudio.Code.PreRelease",
      "gh attestation verify `$env:SUBJECT_PATH",
      "--signer-workflow `$env:ATTESTATION_SIGNER_WORKFLOW",
      "--signer-digest `$env:GITHUB_SHA",
      "--source-ref refs/heads/main",
      "--source-digest `$env:GITHUB_SHA",
      "--predicate-type `$env:ATTESTATION_PREDICATE_TYPE",
      "--deny-self-hosted-runners --format json",
      "ATTESTATION_VERIFICATION_RESULT_PATH",
      "Preflight Marketplace publication evidence recording",
      "-ValidateOnly",
      "node-version: 24.16.0",
      "version: 11.5.2",
      "pnpm install --frozen-lockfile",
      "azure/login@532459ea530d8321f2fb9bb10d1e0bcf23869a43",
      "pnpm exec vsce publish --packagePath `$env:SUBJECT_PATH --pre-release --azure-credential",
      "record-marketplace-publication.ps1"
    )) {
    Assert-True ($workflow.Contains($term)) "Marketplace workflow should include '$term'."
  }
  Assert-ContainsInOrder $workflow @(
    "Download exact candidate release VSIX",
    "Verify exact candidate VSIX bytes",
    "Require packaged Marketplace prerelease property",
    "Verify live GitHub attestation for candidate VSIX",
    "Preflight Marketplace publication evidence recording",
    "Validate required Entra variables",
    "Azure login with federated Marketplace identity",
    "Publish exact VSIX as Marketplace prerelease",
    "Record Marketplace publication evidence",
    "Upload Marketplace publication evidence"
  ) "Marketplace workflow security gates must precede authentication and publication."

  $uses = [regex]::Matches($workflow, '(?m)^\s*-?\s*uses:\s*[^\r\n]+$')
  Assert-True ($uses.Count -gt 0) "Marketplace workflow should use pinned actions."
  foreach ($use in $uses) {
    Assert-True ($use.Value -match '@[a-f0-9]{40}\s*$') "Marketplace workflow action must be pinned by full SHA: $($use.Value)"
  }
  $inputExpressionLines = @($workflow -split "`r?`n" | Where-Object { $_.Contains('${{ inputs.') })
  Assert-Equal 1 $inputExpressionLines.Count "release_tag input expression should occur exactly once."
  foreach ($forbidden in @(
      "github-attestation-evidence.win32-x64.json",
      "LIVE_ATTESTATION_EVIDENCE_PATH",
      "ATTESTATION_BUNDLE_PATH",
      "--bundle",
      "subversionr-win32-x64-0.2.0.vsix",
      "v0.2.0-beta.1",
      "VSCE_PAT",
      "continue-on-error",
      "||"
    )) {
    Assert-True (-not $workflow.Contains($forbidden, [System.StringComparison]::OrdinalIgnoreCase)) "Marketplace workflow must not contain stale or fallback term '$forbidden'."
  }
  Assert-True (-not [regex]::IsMatch($workflow, '(?im)(^|\s)--pat(?:\s|=|$)')) "Workflow must not expose a PAT publish path."
  Assert-True (-not $workflow.Contains("secrets.", [System.StringComparison]::OrdinalIgnoreCase)) "Workflow must not read GitHub secrets."

  Write-Host "Release Marketplace publication script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

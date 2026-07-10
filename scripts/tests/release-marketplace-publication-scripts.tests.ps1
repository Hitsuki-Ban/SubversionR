$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$recorder = Join-Path $repoRoot "scripts\release\record-marketplace-publication.ps1"
$workflowPath = Join-Path $repoRoot ".github\workflows\publish-marketplace.yml"
$productionContractPath = Join-Path $repoRoot "docs\release\github-attestation-contract.win32-x64.json"

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

function Get-RepoRelativePath([string]$Path) {
  [System.IO.Path]::GetRelativePath($repoRoot, $Path).Replace("\", "/")
}

function Write-JsonFile([string]$Path, [object]$Value) {
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8
}

function New-TestVsix([string]$Path, [bool]$PreRelease) {
  $stagingRoot = Join-Path (Split-Path -Parent $Path) "vsix-$([Guid]::NewGuid().ToString('N'))"
  New-Item -ItemType Directory -Force -Path (Join-Path $stagingRoot "extension") | Out-Null
  $property = if ($PreRelease) {
    @"
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.PreRelease" Value="true" />
    </Properties>
"@
  }
  else {
    ""
  }
  @"
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Language="en-US" Id="subversionr" Version="0.2.0" Publisher="hitsuki-ban" TargetPlatform="win32-x64" />
    <DisplayName>SubversionR</DisplayName>
$property
  </Metadata>
</PackageManifest>
"@ | Set-Content -LiteralPath (Join-Path $stagingRoot "extension.vsixmanifest") -NoNewline -Encoding utf8
  @{
    name = "subversionr"
    publisher = "hitsuki-ban"
    version = "0.2.0"
  } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stagingRoot "extension\package.json") -Encoding utf8
  if (Test-Path -LiteralPath $Path) {
    Remove-Item -LiteralPath $Path -Force
  }
  [System.IO.Compression.ZipFile]::CreateFromDirectory($stagingRoot, $Path)
  Remove-Item -LiteralPath $stagingRoot -Recurse -Force
}

function New-Fixture([string]$Root, [bool]$PreRelease) {
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  $vsixPath = Join-Path $Root "subversionr-win32-x64-0.2.0.vsix"
  New-TestVsix -Path $vsixPath -PreRelease $PreRelease
  $subjectSha = Get-Sha256 $vsixPath
  $sourceSha = "0123456789abcdef0123456789abcdef01234567"
  $contractPath = Join-Path $Root "github-attestation-contract.win32-x64.json"
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
      requiredPermissions = @("contents: read", "id-token: write", "attestations: write")
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

  $bundlePath = Join-Path $Root "github-attestation-bundle.win32-x64.json"
  Write-JsonFile $bundlePath ([pscustomobject]@{
      mediaType = "application/vnd.dev.sigstore.bundle.v0.3+json"
      verificationMaterial = [pscustomobject]@{ certificate = [pscustomobject]@{ rawBytes = "fixture" } }
      dsseEnvelope = [pscustomobject]@{ payloadType = "application/vnd.in-toto+json"; payload = "fixture"; signatures = @() }
    })

  $recordedVerificationPath = Join-Path $Root "recorded-github-attestation-verification.win32-x64.json"
  Write-JsonFile $recordedVerificationPath ([pscustomobject]@{ verified = $true; fixture = "recorded-live-verification" })

  $liveEvidencePath = Join-Path $Root "github-attestation-evidence.win32-x64.json"
  $liveEvidence = [pscustomobject]@{
    schemaVersion = 1
    schema = "subversionr.release.live-github-attestation.win32-x64.v1"
    publicReadinessClaim = $false
    signingClaim = $false
    target = "win32-x64"
    status = "live-attestation-verified"
    contract = [pscustomobject]@{
      path = Get-RepoRelativePath $contractPath
      sha256 = Get-Sha256 $contractPath
      schema = $contract.schema
    }
    release = $contract.release
    subject = [pscustomobject]@{
      name = $contract.subject.name
      path = Get-RepoRelativePath $vsixPath
      size = $contract.subject.size
      sha256 = $contract.subject.sha256
    }
    workflow = [pscustomobject]@{
      path = $contract.workflow.path
      event = "workflow_dispatch"
      runId = "456"
      runAttempt = 1
      runUrl = "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/456"
      headSha = $sourceSha
      sourceRef = "refs/heads/main"
    }
    attestation = [pscustomobject]@{
      provider = $contract.attestation.provider
      action = $contract.attestation.action
      actionDigest = $contract.attestation.actionDigest
      predicateType = $contract.attestation.predicateType
      originalBuildProvenanceClaim = $false
      artifactSignatureClaim = $false
      bundlePath = Get-RepoRelativePath $bundlePath
      bundleSha256 = Get-Sha256 $bundlePath
    }
    verification = [pscustomobject]@{
      verified = $true
      repository = $contract.verificationPolicy.repository
      signerWorkflow = $contract.verificationPolicy.signerWorkflow
      predicateType = $contract.verificationPolicy.predicateType
      resultPath = Get-RepoRelativePath $recordedVerificationPath
      resultSha256 = Get-Sha256 $recordedVerificationPath
      certificate = [pscustomobject]@{
        workflowRef = "refs/heads/main"
        workflowSha = $sourceSha
        runnerEnvironment = "github-hosted"
        sourceVisibility = "public"
      }
    }
  }
  Write-JsonFile $liveEvidencePath $liveEvidence

  $verificationPath = Join-Path $Root "gh-attestation-verification.json"
  Write-JsonFile $verificationPath @(
    [pscustomobject]@{
      verificationResult = [pscustomobject]@{
        verifiedTimestamps = @([pscustomobject]@{ type = "Tlog"; uri = "https://rekor.sigstore.dev" })
        signature = [pscustomobject]@{
          certificate = [pscustomobject]@{
            githubWorkflowRepository = "Hitsuki-Ban/SubversionR"
            githubWorkflowRef = "refs/heads/main"
            githubWorkflowSHA = $sourceSha
            sourceRepositoryRef = "refs/heads/main"
            sourceRepositoryDigest = $sourceSha
            sourceRepositoryVisibilityAtSigning = "public"
          }
        }
        statement = [pscustomobject]@{
          subject = @(
            [pscustomobject]@{
              name = $contract.subject.name
              digest = [pscustomobject]@{ sha256 = $contract.subject.sha256 }
            }
          )
          predicateType = $contract.verificationPolicy.predicateType
        }
      }
    }
  )

  [pscustomobject]@{
    root = $Root
    vsixPath = $vsixPath
    contractPath = $contractPath
    liveEvidencePath = $liveEvidencePath
    verificationPath = $verificationPath
    outputPath = Join-Path $Root "marketplace-publication.json"
    subjectSha = $subjectSha
  }
}

function Invoke-Recorder([object]$Fixture, [string]$OutputPath = $Fixture.outputPath, [string]$VsixPath = $Fixture.vsixPath, [string]$LiveEvidencePath = $Fixture.liveEvidencePath) {
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $recorder `
    -Target win32-x64 `
    -ContractPath $Fixture.contractPath `
    -LiveAttestationEvidencePath $LiveEvidencePath `
    -AttestationVerificationResultPath $Fixture.verificationPath `
    -VsixPath $VsixPath `
    -ReleaseTag v0.2.0-beta.1 `
    -ExtensionId hitsuki-ban.subversionr `
    -ExtensionVersion 0.2.0 `
    -Repository Hitsuki-Ban/SubversionR `
    -WorkflowPath .github/workflows/publish-marketplace.yml `
    -RunId 789 `
    -RunAttempt 2 `
    -RunUrl https://github.com/Hitsuki-Ban/SubversionR/actions/runs/789 `
    -HeadSha fedcba9876543210fedcba9876543210fedcba98 `
    -SourceRef refs/heads/main `
    -EventName workflow_dispatch `
    -OutputPath $OutputPath
}

$tempRoot = Join-Path $repoRoot "target\tests\release-marketplace-publication-scripts\$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  $fixture = New-Fixture -Root (Join-Path $tempRoot "positive") -PreRelease $true
  Invoke-Recorder $fixture
  if ($LASTEXITCODE -ne 0) {
    throw "record-marketplace-publication.ps1 failed with exit code $LASTEXITCODE."
  }

  $evidence = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  Assert-Equal "subversionr.release.marketplace-publication.win32-x64.v1" $evidence.schema "Publication evidence schema should match."
  Assert-Equal "marketplace-prerelease-published" $evidence.status "Publication evidence status should match."
  Assert-Equal "True" ([string]$evidence.preReleaseClaim) "Publication evidence must make the exact prerelease claim."
  foreach ($claim in @("publicReadinessClaim", "publicInstallClaim", "signingClaim", "rollbackClaim", "finalReviewClaim")) {
    Assert-Equal "False" ([string]$evidence.$claim) "Publication evidence $claim must remain false."
  }
  Assert-Equal "hitsuki-ban.subversionr" $evidence.extension.id "Publication evidence should bind the extension id."
  Assert-Equal "0.2.0" $evidence.extension.version "Publication evidence should bind the extension version."
  Assert-Equal "win32-x64" $evidence.extension.targetPlatform "Publication evidence should bind the target."
  Assert-Equal $fixture.subjectSha $evidence.vsix.sha256 "Publication evidence should bind the VSIX hash."
  Assert-Equal "True" ([string]$evidence.vsix.marketplacePreReleaseProperty) "Publication evidence should record the packaged prerelease property."
  Assert-Equal "refs/heads/main" $evidence.attestation.sourceRef "Publication evidence should bind the attestation source ref."
  Assert-Equal "refs/heads/main" $evidence.workflow.sourceRef "Publication evidence should bind the publication workflow source ref."
  Assert-Equal "marketplace" $evidence.workflow.environment "Publication evidence should bind the protected environment."
  Assert-Equal "microsoft-entra-id-workload-identity" $evidence.publication.authentication "Publication evidence should record secretless Entra authentication."
  Assert-True ($evidence.publication.command.EndsWith("--pre-release --azure-credential")) "Publication evidence should record the exact publish flags."
  foreach ($path in @($evidence.vsix.path, $evidence.attestation.contractPath, $evidence.attestation.liveEvidencePath, $evidence.attestation.bundlePath, $evidence.attestation.recordedVerificationResultPath, $evidence.attestation.verificationResultPath)) {
    Assert-True (-not [System.IO.Path]::IsPathRooted([string]$path)) "Recorded evidence paths must be repository-relative."
    Assert-True (-not ([string]$path).StartsWith("../", [System.StringComparison]::Ordinal)) "Recorded evidence paths must stay in the repository."
  }
  $serializedEvidence = Get-Content -Raw -LiteralPath $fixture.outputPath
  foreach ($forbidden in @("VSCE_PAT", "clientSecret", "accessToken", "refreshToken")) {
    Assert-True (-not $serializedEvidence.Contains($forbidden, [System.StringComparison]::OrdinalIgnoreCase)) "Publication evidence must not contain credential field '$forbidden'."
  }

  $tamperedRoot = Join-Path $fixture.root "tampered"
  New-Item -ItemType Directory -Force -Path $tamperedRoot | Out-Null
  $tamperedVsixPath = Join-Path $tamperedRoot "subversionr-win32-x64-0.2.0.vsix"
  Copy-Item -LiteralPath $fixture.vsixPath -Destination $tamperedVsixPath
  [System.IO.File]::AppendAllText($tamperedVsixPath, "tampered")
  Assert-NativeCommandFailsContaining {
    Invoke-Recorder -Fixture $fixture -VsixPath $tamperedVsixPath -OutputPath (Join-Path $fixture.root "tampered-output.json")
  } "size must match current bytes" "Recorder should reject tampered VSIX bytes."

  $overclaimPath = Join-Path $fixture.root "overclaim-live-evidence.json"
  $overclaim = Get-Content -Raw -LiteralPath $fixture.liveEvidencePath | ConvertFrom-Json
  $overclaim.publicReadinessClaim = $true
  Write-JsonFile $overclaimPath $overclaim
  Assert-NativeCommandFailsContaining {
    Invoke-Recorder -Fixture $fixture -LiveEvidencePath $overclaimPath -OutputPath (Join-Path $fixture.root "overclaim-output.json")
  } "publicReadinessClaim must match" "Recorder should reject live attestation overclaims."

  $outsideOutput = Join-Path ([System.IO.Path]::GetTempPath()) "subversionr-marketplace-publication-$([Guid]::NewGuid().ToString('N')).json"
  Assert-NativeCommandFailsContaining {
    Invoke-Recorder -Fixture $fixture -OutputPath $outsideOutput
  } "must resolve inside the repository" "Recorder should reject output paths outside the repository."
  Assert-True (-not (Test-Path -LiteralPath $outsideOutput)) "Recorder must not write outside the repository."

  $nonPrereleaseFixture = New-Fixture -Root (Join-Path $tempRoot "current-contract-no-prerelease") -PreRelease $false
  Assert-NativeCommandFailsContaining {
    Invoke-Recorder -Fixture $nonPrereleaseFixture
  } "Microsoft.VisualStudio.Code.PreRelease" "Current 0.2.0 identity must not bypass the packaged prerelease-property gate."

  $productionContract = Get-Content -Raw -LiteralPath $productionContractPath | ConvertFrom-Json
  Assert-Equal "v0.2.0-beta.1" $productionContract.release.tag "The workflow test must track the current source-controlled release contract."
  Assert-Equal "subversionr-win32-x64-0.2.0.vsix" $productionContract.subject.name "The workflow test must track the current released VSIX contract."

  $workflow = Get-Content -Raw -LiteralPath $workflowPath
  foreach ($term in @(
      "workflow_dispatch:",
      "release_tag:",
      "environment: marketplace",
      "contents: read",
      "id-token: write",
      "node-version: 24.16.0",
      "version: 11.5.2",
      "pnpm install --frozen-lockfile",
      "actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0",
      "pnpm/action-setup@0ebf47130e4866e96fce0953f49152a61190b271",
      "actions/setup-node@48b55a011bda9f5d6aeb4c2d9c7362e8dae4041e",
      "azure/login@532459ea530d8321f2fb9bb10d1e0bcf23869a43",
      "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
      'AZURE_CLIENT_ID: ${{ vars.AZURE_CLIENT_ID }}',
      'AZURE_TENANT_ID: ${{ vars.AZURE_TENANT_ID }}',
      "allow-no-subscriptions: true",
      "verify-release-attestation-subject.ps1",
      "gh attestation verify `$env:SUBJECT_PATH",
      "--signer-workflow `$env:ATTESTATION_SIGNER_WORKFLOW",
      "--signer-digest `$env:ATTESTATION_SOURCE_SHA",
      "--source-ref `$env:ATTESTATION_SOURCE_REF",
      "--source-digest `$env:ATTESTATION_SOURCE_SHA",
      "Microsoft.VisualStudio.Code.PreRelease",
      'if ($parsedVersion -lt [version]"2.26.1")',
      "pnpm exec vsce publish --packagePath `$env:SUBJECT_PATH --pre-release --azure-credential",
      "record-marketplace-publication.ps1"
    )) {
    Assert-True ($workflow.Contains($term)) "Marketplace workflow should include '$term'."
  }
  Assert-ContainsInOrder $workflow @(
    "Verify exact released VSIX bytes",
    "Validate exact live attestation evidence",
    "Verify live attestation for downloaded VSIX",
    "Require packaged Marketplace prerelease property",
    "Validate required Entra variables",
    "Verify locked vsce supports Entra credentials",
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
  Assert-True ($inputExpressionLines[0].Trim().StartsWith("RELEASE_TAG:", [System.StringComparison]::Ordinal)) "Input expressions must only flow through env."
  Assert-True (-not $workflow.Contains("refs/tags/v0.2.0", [System.StringComparison]::Ordinal)) "Workflow must not hardcode the superseded refs/tags/v0.2.0 requirement."
  Assert-True (-not $workflow.Contains("VSCE_PAT", [System.StringComparison]::OrdinalIgnoreCase)) "Workflow must not reference VSCE_PAT."
  Assert-True (-not [regex]::IsMatch($workflow, '(?im)(^|\s)--pat(?:\s|=|$)')) "Workflow must not expose a PAT publish path."
  Assert-True (-not $workflow.Contains("secrets.", [System.StringComparison]::OrdinalIgnoreCase)) "Workflow must not read GitHub secrets."
  Assert-True (-not $workflow.Contains("continue-on-error", [System.StringComparison]::OrdinalIgnoreCase)) "Workflow must not add failure fallbacks."
  Assert-True (-not $workflow.Contains("||", [System.StringComparison]::Ordinal)) "Workflow must not add shell fallback branches."

  Write-Host "Release Marketplace publication script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

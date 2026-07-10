$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$generatePublicationGapsScript = Join-Path $repoRoot "scripts\release\generate-publication-gaps.ps1"
$verifyPublicationGapsScript = Join-Path $repoRoot "scripts\release\verify-publication-gaps.ps1"
$packageJsonPath = Join-Path $repoRoot "package.json"
$ciWorkflowPath = Join-Path $repoRoot ".github\workflows\ci.yml"
$extensionPackagePath = Join-Path $repoRoot "packages\vscode-extension\package.json"
$readinessVerifierPath = Join-Path $repoRoot "scripts\release\verify-readiness.ps1"
$publicCutoverRunbookPath = Join-Path $repoRoot "docs\release\public-cutover-runbook.md"

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

function Assert-ContainsInOrder([string]$Text, [string[]]$Needles, [string]$Message) {
  $previousIndex = -1
  foreach ($needle in $Needles) {
    $currentIndex = $Text.IndexOf($needle, [System.StringComparison]::Ordinal)
    Assert-True ($currentIndex -ge 0) "$Message Missing '$needle'."
    Assert-True ($currentIndex -gt $previousIndex) "$Message '$needle' should appear after the previous checked step."
    $previousIndex = $currentIndex
  }
}

function Get-Sha256([string]$Path) {
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-JsonFile([string]$Path, [object]$Value) {
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

function New-PublicationGapsFixture([string]$Root) {
  $artifactsRoot = Join-Path $Root "artifacts"
  $evidenceRoot = Join-Path $Root "evidence"
  New-Item -ItemType Directory -Force -Path $artifactsRoot | Out-Null
  New-Item -ItemType Directory -Force -Path $evidenceRoot | Out-Null

  $vsixPath = Join-Path $artifactsRoot "subversionr-win32-x64-0.2.0.vsix"
  [System.IO.File]::WriteAllBytes($vsixPath, [byte[]](0x53, 0x75, 0x62, 0x76, 0x65, 0x72, 0x73, 0x69, 0x6f, 0x6e, 0x52))
  $vsixSha256 = Get-Sha256 $vsixPath

  $vsixEvidencePath = Join-Path $evidenceRoot "subversionr-vsix-package-win32-x64.json"
  Write-JsonFile $vsixEvidencePath ([pscustomobject]@{
      schemaVersion = 1
      schema = "subversionr.release.vsix-package.win32-x64.v1"
      publicReadinessClaim = $false
      target = "win32-x64"
      extension = [pscustomobject]@{
        id = "hitsuki-ban.subversionr"
        displayName = "SubversionR"
        version = "0.2.0"
      }
      vsix = [pscustomobject]@{
        path = $vsixPath
        relativePath = "target/tests/release-publication-gaps-scripts/artifacts/subversionr-win32-x64-0.2.0.vsix"
        size = (Get-Item -LiteralPath $vsixPath).Length
        sha256 = $vsixSha256
      }
    })

  $provenancePath = Join-Path $evidenceRoot "subversionr-marketplace-provenance-preflight-win32-x64.json"
  Write-JsonFile $provenancePath ([pscustomobject]@{
      schemaVersion = 1
      schema = "subversionr.release.marketplace-provenance-preflight.win32-x64.v1"
      publicReadinessClaim = $false
      localPreflightOnly = $true
      target = "win32-x64"
      extension = [pscustomobject]@{
        id = "hitsuki-ban.subversionr"
        displayName = "SubversionR"
        version = "0.2.0"
      }
      repository = [pscustomobject]@{
        remoteUrlRecorded = $false
      }
      artifacts = [pscustomobject]@{
        vsix = [pscustomobject]@{
          path = $vsixPath
          relativePath = "target/tests/release-publication-gaps-scripts/artifacts/subversionr-win32-x64-0.2.0.vsix"
          size = (Get-Item -LiteralPath $vsixPath).Length
          sha256 = $vsixSha256
        }
      }
      marketplaceMetadata = [pscustomobject]@{
        publicationReady = $false
      }
      signing = [pscustomobject]@{
        status = "unsigned"
      }
      attestation = [pscustomobject]@{
        status = "not-generated"
      }
      marketplace = [pscustomobject]@{
        status = "not-published"
      }
      previousStableRollback = [pscustomobject]@{
        status = "not-proven"
      }
    })

  [pscustomobject]@{
    root = $Root
    vsixPath = $vsixPath
    vsixEvidencePath = $vsixEvidencePath
    provenancePath = $provenancePath
    outputPath = Join-Path $evidenceRoot "subversionr-publication-gaps-win32-x64.json"
  }
}

function Invoke-GeneratePublicationGaps([object]$Fixture, [string]$OutputPath, [string]$ExtensionPackage = "packages/vscode-extension/package.json", [string]$ProvenancePath = $null) {
  if ([string]::IsNullOrWhiteSpace($ProvenancePath)) {
    $ProvenancePath = $Fixture.provenancePath
  }

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $generatePublicationGapsScript `
    -Target win32-x64 `
    -ExtensionPackagePath $ExtensionPackage `
    -RootPackagePath "package.json" `
    -ReadmePath "README.md" `
    -LicensePath "LICENSE" `
    -ChangelogPath "CHANGELOG.md" `
    -SupportPath "SUPPORT.md" `
    -ProvenanceEvidencePath $ProvenancePath `
    -VsixEvidencePath $Fixture.vsixEvidencePath `
    -OutputPath $OutputPath
}

$tempRoot = Join-Path $repoRoot "target\tests\release-publication-gaps-scripts\$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  Assert-True (Test-Path -LiteralPath $generatePublicationGapsScript -PathType Leaf) "generate-publication-gaps.ps1 should exist."
  Assert-True (Test-Path -LiteralPath $verifyPublicationGapsScript -PathType Leaf) "verify-publication-gaps.ps1 should exist."

  $fixture = New-PublicationGapsFixture $tempRoot
  Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "generate-publication-gaps.ps1 failed with exit code $LASTEXITCODE."
  }

  $report = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  Assert-Equal "subversionr.release.publication-gaps.win32-x64.v1" $report.schema "Publication gaps should use the M7k2b schema."
  Assert-Equal "False" ([string]$report.publicReadinessClaim) "Publication gaps must not claim public readiness."
  Assert-Equal "True" ([string]$report.localGapReportOnly) "Publication gaps should be local-gap only."
  Assert-Equal "hitsuki-ban.subversionr" $report.extension.id "Publication gaps should bind the extension identity."
  Assert-Equal "False" ([string]$report.extension.privatePackage) "Publication gaps should record public extension package state."
  Assert-Equal "configured" $report.publicRepositoryMetadata.status "Public repository metadata should be configured."
  Assert-Equal "True" ([string]$report.publicRepositoryMetadata.repositoryUrlRecorded) "Publication gaps must record the public repository URL."
  Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR.git" $report.publicRepositoryMetadata.repositoryUrl "Publication gaps should record the public repository URL."
  Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR#readme" $report.publicRepositoryMetadata.homepageUrl "Publication gaps should record the public homepage URL."
  Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/issues" $report.publicRepositoryMetadata.bugsUrl "Publication gaps should record the public issue tracker URL."
  Assert-Equal "not-verified" $report.marketplacePublisherAuthorization.status "Publisher authorization should remain not-verified."
  Assert-Equal "False" ([string]$report.marketplacePublisherAuthorization.credentialRecorded) "Publisher authorization must not record credentials."
  Assert-Equal "not-configured" $report.publishAuth.status "Publish auth should remain not-configured."
  Assert-Equal "microsoft-entra-id-workload-identity" $report.publishAuth.primaryMode "Publish auth should track Entra ID as the primary mode."
  Assert-Equal "VSCE_PAT" $report.publishAuth.legacyPatSecretName "Publish auth may record only the legacy VSCE_PAT secret name."
  Assert-Equal "False" ([string]$report.publishAuth.secretValueRecorded) "Publish auth must not record secret values."
  Assert-Equal "not-run" $report.marketplacePublicInstall.status "Marketplace public install should remain not-run."
  Assert-Equal "False" ([string]$report.marketplacePublicInstall.installEvidenceRecorded) "Marketplace public install evidence must not be recorded."
  Assert-Equal "blocked-pending-cutover" $report.publicCutover.status "Public cutover should remain blocked until public baseline migration."
  Assert-Equal "not-created" $report.publicCutover.baseline.status "Public cutover baseline should not be created by this local gap report."
  Assert-Equal "PR Fast / windows" $report.publicCutover.publicRepository.branchProtectionRequiredCheck "Public cutover should record the public PR Fast branch-protection check."
  Assert-Equal "not-retired" $report.publicCutover.cloudflareBridgeRetirement.status "Cloudflare bridge retirement should remain not-retired before cutover."
  Assert-Equal "v0.2.0-beta.1" $report.publicCutover.release.tag "Public cutover should record the first public Beta tag."
  Assert-Equal (Get-Sha256 $fixture.vsixPath) $report.artifacts.vsix.sha256 "Publication gaps should bind the exact VSIX hash."
  foreach ($blocker in @(
      "Marketplace publisher authorization is not verified by this local gap report.",
      "Marketplace publish authentication is not configured by this local gap report.",
      "Marketplace publication is not run by this local gap report.",
      "Marketplace public install evidence is not generated by this local gap report.",
      "Public repository baseline push and CI home migration are not performed by this local gap report.",
      "Private workflow disablement and Cloudflare bridge retirement remain manual cutover steps."
    )) {
    Assert-True (@($report.blockers | Where-Object { $_ -eq $blocker }).Count -eq 1) "Publication gaps should include blocker '$blocker'."
  }

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyPublicationGapsScript `
    -Target win32-x64 `
    -EvidencePath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "verify-publication-gaps.ps1 failed with exit code $LASTEXITCODE."
  }

  $badOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "subversionr-publication-gaps-outside-target.json"
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath $badOutputPath
  } "OutputPath must resolve inside" "Publication gaps generation should reject output paths outside target."

  $badPackagePath = Join-Path $tempRoot "bad-repository-package.json"
  $badPackage = Get-Content -Raw -LiteralPath $extensionPackagePath | ConvertFrom-Json
  $badPackage.repository.url = "https://example.invalid/SubversionR.git"
  Write-JsonFile $badPackagePath $badPackage
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-repository-report.json") -ExtensionPackage $badPackagePath
  } "repository URL must point" "Publication gaps generation should reject unexpected public repository metadata."

  $badProvenancePath = Join-Path $tempRoot "bad-publication-ready-provenance.json"
  $badProvenance = Get-Content -Raw -LiteralPath $fixture.provenancePath | ConvertFrom-Json
  $badProvenance.marketplaceMetadata.publicationReady = $true
  Write-JsonFile $badProvenancePath $badProvenance
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-provenance-report.json") -ProvenancePath $badProvenancePath
  } "publication readiness" "Publication gaps generation should reject upstream provenance that claims Marketplace publication readiness."

  $tamperedPath = Join-Path $tempRoot "tampered-public-readiness.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tampered.publicReadinessClaim = $true
  Write-JsonFile $tamperedPath $tampered
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyPublicationGapsScript `
      -Target win32-x64 `
      -EvidencePath $tamperedPath
  } "publicReadinessClaim" "Publication gaps verification should reject public readiness claims."

  $tamperedPath = Join-Path $tempRoot "tampered-publisher-verified.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tampered.marketplacePublisherAuthorization.status = "verified"
  $tampered.marketplacePublisherAuthorization.ownerOrContributorVerified = $true
  Write-JsonFile $tamperedPath $tampered
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyPublicationGapsScript `
      -Target win32-x64 `
      -EvidencePath $tamperedPath
  } "not-verified" "Publication gaps verification should reject publisher authorization overclaims."

  $tamperedPath = Join-Path $tempRoot "tampered-token-value.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tampered.publishAuth | Add-Member -NotePropertyName "tokenValue" -NotePropertyValue "github_pat_fake"
  Write-JsonFile $tamperedPath $tampered
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyPublicationGapsScript `
      -Target win32-x64 `
      -EvidencePath $tamperedPath
  } "must not record credentials" "Publication gaps verification should reject token-like fields."

  $tamperedPath = Join-Path $tempRoot "tampered-public-install.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tampered.marketplacePublicInstall.status = "installed"
  $tampered.marketplacePublicInstall.installEvidenceRecorded = $true
  Write-JsonFile $tamperedPath $tampered
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyPublicationGapsScript `
      -Target win32-x64 `
      -EvidencePath $tamperedPath
  } "not-run" "Publication gaps verification should reject public install overclaims."

  $tamperedPath = Join-Path $tempRoot "tampered-public-cutover.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tampered.publicCutover.status = "complete"
  $tampered.publicCutover.cloudflareBridgeRetirement.status = "retired"
  $tampered.publicCutover.cloudflareBridgeRetirement.disconnected = $true
  Write-JsonFile $tamperedPath $tampered
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyPublicationGapsScript `
      -Target win32-x64 `
      -EvidencePath $tamperedPath
  } "blocked-pending-cutover" "Publication gaps verification should reject public cutover overclaims."

  $tamperedPath = Join-Path $tempRoot "tampered-cloudflare-live-id.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tampered.publicCutover.cloudflareBridgeRetirement | Add-Member -NotePropertyName "repo_id" -NotePropertyValue "1276845591"
  Write-JsonFile $tamperedPath $tampered
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyPublicationGapsScript `
      -Target win32-x64 `
      -EvidencePath $tamperedPath
  } "must not record credentials" "Publication gaps verification should reject Cloudflare live IDs."

  $tamperedPath = Join-Path $tempRoot "tampered-nonclaims.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tampered.nonClaims = @($tampered.nonClaims | Where-Object { $_ -ne "This gate does not publish to Visual Studio Marketplace." })
  Write-JsonFile $tamperedPath $tampered
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyPublicationGapsScript `
      -Target win32-x64 `
      -EvidencePath $tamperedPath
  } "nonClaims" "Publication gaps verification should reject missing non-claims."

  $packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  Assert-True ($packageJson.scripts."release:test-publication-gaps-scripts".Contains("release-publication-gaps-scripts.tests.ps1")) "Root package should expose publication gaps script tests."
  Assert-True ($packageJson.scripts."release:generate-publication-gaps:win32-x64".Contains("generate-publication-gaps.ps1")) "Root package should expose publication gaps generation."
  Assert-True ($packageJson.scripts."release:verify-publication-gaps:win32-x64".Contains("verify-publication-gaps.ps1")) "Root package should expose publication gaps verification."

  $ciWorkflow = Get-Content -Raw -LiteralPath $ciWorkflowPath
  Assert-ContainsInOrder $ciWorkflow @(
    "Release provenance script tests",
    "Release publication gaps script tests",
    "Generate release provenance preflight",
    "Verify release provenance preflight",
    "Generate publication gaps preflight",
    "Verify publication gaps preflight"
  ) "CI should run publication gaps tests and generate the gap report after provenance verification."

  $readinessVerifier = Get-Content -Raw -LiteralPath $readinessVerifierPath
  foreach ($term in @(
      "M7k2b publication gaps and publish-auth contract preflight",
      "subversionr.release.publication-gaps.win32-x64.v1",
      "docs/release/public-cutover-runbook.md",
      "pnpm release:test-publication-gaps-scripts",
      "pnpm release:generate-publication-gaps:win32-x64",
      "pnpm release:verify-publication-gaps:win32-x64"
    )) {
    Assert-True ($readinessVerifier.Contains($term)) "Release readiness verifier should require '$term'."
  }

  Assert-True (Test-Path -LiteralPath $publicCutoverRunbookPath -PathType Leaf) "Public cutover runbook should exist."
  $publicCutoverRunbook = Get-Content -Raw -LiteralPath $publicCutoverRunbookPath
  foreach ($term in @(
      "# Public Cutover Runbook",
      "fresh squash-style baseline commit",
      'Reference/` remains private',
      "PR Fast / windows",
      "GitHub Private Vulnerability Reporting",
      "subversionr-pr-fast",
      "v0.2.0-beta.1"
    )) {
    Assert-True ($publicCutoverRunbook.Contains($term)) "Public cutover runbook should include '$term'."
  }

  Write-Host "Release publication gaps script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

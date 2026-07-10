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
  $baselineCommit = "1111111111111111111111111111111111111111"
  $cutoverHeadCommit = "0123456789abcdef0123456789abcdef01234567"

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

  $cutoverEvidencePath = Join-Path $Root "public-cutover-evidence.json"
  $releaseAssetBaseUrl = "https://github.com/Hitsuki-Ban/SubversionR/releases/download/v0.2.0-beta.1"
  Write-JsonFile $cutoverEvidencePath ([pscustomobject]@{
      schemaVersion = 1
      schema = "subversionr.release.public-cutover-evidence.v1"
      status = "recorded-post-cutover"
      repository = [pscustomobject]@{
        url = "https://github.com/Hitsuki-Ban/SubversionR"
        defaultBranch = "main"
        baselineCommit = $baselineCommit
        cutoverHeadCommit = $cutoverHeadCommit
        resolvesToPublic = $true
        branchProtectionRequiredCheck = "PR Fast / windows"
        branchProtectionConfigured = $false
        privateVulnerabilityReportingEnabled = $true
        metadataVerified = $false
      }
      ci = [pscustomobject]@{
        status = "green"
        workflow = "PR Fast"
        requiredCheck = "PR Fast / windows"
        runUrl = "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/123456789"
        headSha = $cutoverHeadCommit
        event = "push"
        conclusion = "success"
        startedAt = "2026-07-10T07:00:34Z"
        completedAt = "2026-07-10T07:02:49Z"
        publicPrFastFirstRunGreen = $true
        publicHeavyWorkflowScheduleOnly = $true
        privateWorkflowsDisabled = $false
        privateWorkflowDisableDateRecorded = $false
      }
      cloudflareBridgeRetirement = [pscustomobject]@{
        status = "retired"
        workerName = "subversionr-pr-fast"
        publicCiReplacement = "PR Fast / windows"
        disconnected = $true
        triggersDisabled = $true
        retirementDate = "2026-07-10"
      }
      release = [pscustomobject]@{
        status = "published"
        tag = "v0.2.0-beta.1"
        tagCommit = $cutoverHeadCommit
        url = "https://github.com/Hitsuki-Ban/SubversionR/releases/tag/v0.2.0-beta.1"
        prerelease = $true
        publishedAt = "2026-07-10T07:24:13Z"
        artifactAttestationPublished = $false
        assets = @(
          [pscustomobject]@{
            name = "subversionr-source-sbom.cdx.json"
            size = 101
            sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            url = "$releaseAssetBaseUrl/subversionr-source-sbom.cdx.json"
          },
          [pscustomobject]@{
            name = "subversionr-win32-x64-0.2.0.vsix"
            size = (Get-Item -LiteralPath $vsixPath).Length
            sha256 = $vsixSha256
            url = "$releaseAssetBaseUrl/subversionr-win32-x64-0.2.0.vsix"
          },
          [pscustomobject]@{
            name = "subversionr-win32-x64-beta-candidate.zip"
            size = 303
            sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            url = "$releaseAssetBaseUrl/subversionr-win32-x64-beta-candidate.zip"
          },
          [pscustomobject]@{
            name = "THIRD-PARTY-NOTICES.md"
            size = 404
            sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
            url = "$releaseAssetBaseUrl/THIRD-PARTY-NOTICES.md"
          }
        )
      }
      betaCandidateEvidence = [pscustomobject]@{
        status = "blocked-published-bundle-inconsistent"
        publishedBundleAssetName = "subversionr-win32-x64-beta-candidate.zip"
        publishedBundleSha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        expectedVsixName = "subversionr-win32-x64-0.2.0.vsix"
        expectedVsixSha256 = $vsixSha256
        containedVsixName = "svn-r-win32-x64-0.1.0.vsix"
        containedVsixSha256 = "ff7094c02b27914351fde4d9ae9b09dd8a3cf4af00f983ddf085adb808a3167b"
        declaredPayloadCount = 1462
        missingPayloadCount = 29
        mismatchedPayloadCount = 421
        consistencyVerified = $false
        regenerationCompleted = $false
      }
    })

  [pscustomobject]@{
    root = $Root
    vsixPath = $vsixPath
    vsixEvidencePath = $vsixEvidencePath
    provenancePath = $provenancePath
    cutoverEvidencePath = $cutoverEvidencePath
    baselineCommit = $baselineCommit
    cutoverHeadCommit = $cutoverHeadCommit
    outputPath = Join-Path $evidenceRoot "subversionr-publication-gaps-win32-x64.json"
  }
}

function Invoke-GeneratePublicationGaps([object]$Fixture, [string]$OutputPath, [string]$ExtensionPackage = "packages/vscode-extension/package.json", [string]$ProvenancePath = $null, [string]$CutoverEvidencePath = $null) {
  if ([string]::IsNullOrWhiteSpace($ProvenancePath)) {
    $ProvenancePath = $Fixture.provenancePath
  }
  if ([string]::IsNullOrWhiteSpace($CutoverEvidencePath)) {
    $CutoverEvidencePath = $Fixture.cutoverEvidencePath
  }

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $generatePublicationGapsScript `
    -Target win32-x64 `
    -ExtensionPackagePath $ExtensionPackage `
    -RootPackagePath "package.json" `
    -ReadmePath "README.md" `
    -LicensePath "LICENSE" `
    -ChangelogPath "CHANGELOG.md" `
    -SupportPath "SUPPORT.md" `
    -PublicCutoverRunbookPath "docs/release/public-cutover-runbook.md" `
    -PublicCutoverEvidencePath $CutoverEvidencePath `
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
  Assert-Equal "recorded-post-cutover" $report.publicCutover.status "Public cutover should record the completed publication state."
  Assert-Equal "published" $report.publicCutover.baseline.status "Public cutover baseline should be recorded as published."
  Assert-Equal $fixture.baselineCommit $report.publicCutover.baseline.commit "Public cutover should preserve the fresh baseline commit."
  Assert-Equal $fixture.cutoverHeadCommit $report.publicCutover.publicRepository.cutoverHeadCommit "Public cutover should preserve the later cutover head commit."
  Assert-Equal "True" ([string]$report.publicCutover.baseline.publicPushRecorded) "Public cutover should record the public push."
  Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/123456789" $report.publicCutover.ciHomeMigration.runUrl "Public cutover should record the green public CI run."
  Assert-Equal "True" ([string]$report.publicCutover.publicRepository.privateVulnerabilityReportingEnabled) "Public cutover should record Private Vulnerability Reporting enablement."
  Assert-Equal "PR Fast / windows" $report.publicCutover.publicRepository.branchProtectionRequiredCheck "Public cutover should record the public PR Fast branch-protection check."
  Assert-Equal "False" ([string]$report.publicCutover.publicRepository.branchProtectionConfigured) "Public branch protection should remain an explicit owner follow-up."
  Assert-Equal "False" ([string]$report.publicCutover.publicRepository.metadataVerified) "Incomplete public repository metadata should remain explicit."
  Assert-Equal "retired" $report.publicCutover.cloudflareBridgeRetirement.status "Cloudflare bridge retirement should be recorded."
  Assert-Equal "True" ([string]$report.publicCutover.cloudflareBridgeRetirement.disconnected) "Cloudflare bridge should be disconnected."
  Assert-Equal "published" $report.publicCutover.release.status "Public release should be recorded as published."
  Assert-Equal "v0.2.0-beta.1" $report.publicCutover.release.tag "Public cutover should record the first public Beta tag."
  Assert-Equal "False" ([string]$report.publicCutover.release.artifactAttestationPublished) "Live artifact attestation should remain blocked for public issue #5."
  Assert-Equal 4 @($report.publicCutover.release.assets).Count "Public cutover should record all four release assets."
  Assert-Equal "blocked-published-bundle-inconsistent" $report.publicCutover.betaCandidateEvidence.status "Published Beta candidate evidence should remain blocked on bundle inconsistency."
  Assert-Equal "False" ([string]$report.publicCutover.betaCandidateEvidence.consistencyVerified) "Published Beta candidate evidence must not claim consistency."
  Assert-Equal (Get-Sha256 $fixture.vsixPath) $report.artifacts.vsix.sha256 "Publication gaps should bind the exact VSIX hash."
  foreach ($blocker in @(
      "Marketplace publisher authorization is not verified by this local gap report.",
      "Marketplace publish authentication is not configured by this local gap report.",
      "Marketplace publication is not run by this local gap report.",
      "Marketplace public install evidence is not generated by this local gap report.",
      "VSIX signing remains absent in the upstream provenance preflight.",
      "Public branch protection is not configured.",
      "Public repository homepage and social metadata are not fully verified.",
      "Private repository workflows are not disabled.",
      "Live GitHub artifact attestation is not published or verified."
      "The published Beta candidate bundle is inconsistent with its manifest and cannot close the post-cutover Beta-G chain."
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

  $badProvenancePath = Join-Path $tempRoot "bad-signed-provenance.json"
  $badProvenance = Get-Content -Raw -LiteralPath $fixture.provenancePath | ConvertFrom-Json
  $badProvenance.signing.status = "signed"
  Write-JsonFile $badProvenancePath $badProvenance
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-signed-report.json") -ProvenancePath $badProvenancePath
  } "signing status must remain unsigned" "Publication gaps generation should reject upstream signing overclaims."

  $badProvenancePath = Join-Path $tempRoot "bad-rollback-provenance.json"
  $badProvenance = Get-Content -Raw -LiteralPath $fixture.provenancePath | ConvertFrom-Json
  $badProvenance.previousStableRollback.status = "proven"
  Write-JsonFile $badProvenancePath $badProvenance
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-rollback-report.json") -ProvenancePath $badProvenancePath
  } "previous-stable rollback status must remain not-proven" "Publication gaps generation should reject upstream rollback overclaims."

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

  $tamperedPath = Join-Path $tempRoot "tampered-live-attestation.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tampered.publicCutover.release.artifactAttestationPublished = $true
  Write-JsonFile $tamperedPath $tampered
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyPublicationGapsScript `
      -Target win32-x64 `
      -EvidencePath $tamperedPath
  } "must remain false" "Publication gaps verification should reject live attestation overclaims."

  $badCutoverPath = Join-Path $tempRoot "bad-released-vsix-cutover.json"
  $badCutover = Get-Content -Raw -LiteralPath $fixture.cutoverEvidencePath | ConvertFrom-Json
  @($badCutover.release.assets | Where-Object { $_.name -eq "subversionr-win32-x64-0.2.0.vsix" })[0].sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  Write-JsonFile $badCutoverPath $badCutover
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-released-vsix-report.json") -CutoverEvidencePath $badCutoverPath
  } "Released VSIX SHA256 must match" "Publication gaps generation should reject a released VSIX hash that differs from current bytes."

  $badCutoverPath = Join-Path $tempRoot "bad-ci-url-cutover.json"
  $badCutover = Get-Content -Raw -LiteralPath $fixture.cutoverEvidencePath | ConvertFrom-Json
  $badCutover.ci.runUrl = "https://example.invalid/actions/runs/123456789"
  Write-JsonFile $badCutoverPath $badCutover
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-ci-url-report.json") -CutoverEvidencePath $badCutoverPath
  } "runUrl must identify a public repository Actions run" "Publication gaps generation should reject a CI run outside the public repository."

  $badCutoverPath = Join-Path $tempRoot "bad-string-boolean-cutover.json"
  $badCutover = Get-Content -Raw -LiteralPath $fixture.cutoverEvidencePath | ConvertFrom-Json
  $badCutover.repository.branchProtectionConfigured = "False"
  Write-JsonFile $badCutoverPath $badCutover
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-string-boolean-report.json") -CutoverEvidencePath $badCutoverPath
  } "must be a JSON boolean" "Publication gaps generation should reject string values for boolean cutover fields."

  $tamperedPath = Join-Path $tempRoot "tampered-source-divergence.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tampered.publicCutover.ciHomeMigration.runUrl = "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/987654321"
  Write-JsonFile $tamperedPath $tampered
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyPublicationGapsScript `
      -Target win32-x64 `
      -EvidencePath $tamperedPath
  } "must match public cutover evidence" "Publication gaps verification should reject report facts that diverge from the hash-bound cutover source."

  $productionMismatchPath = Join-Path $repoRoot "target\release-evidence\publication-gaps-test-$([Guid]::NewGuid().ToString('N')).json"
  try {
    Copy-Item -LiteralPath $fixture.outputPath -Destination $productionMismatchPath
    Assert-NativeCommandFailsContaining {
      & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyPublicationGapsScript `
        -Target win32-x64 `
        -EvidencePath $productionMismatchPath
    } "must bind the source-controlled public cutover contract" "Production publication gaps verification should reject test-fixture cutover evidence."
  }
  finally {
    Remove-Item -LiteralPath $productionMismatchPath -Force -ErrorAction SilentlyContinue
  }

  $cutoverEvidenceBytes = Get-Content -Raw -LiteralPath $fixture.cutoverEvidencePath
  try {
    $driftedCutover = $cutoverEvidenceBytes | ConvertFrom-Json
    $driftedCutover.release.publishedAt = "2026-07-10T07:25:00Z"
    Write-JsonFile $fixture.cutoverEvidencePath $driftedCutover
    Assert-NativeCommandFailsContaining {
      & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyPublicationGapsScript `
        -Target win32-x64 `
        -EvidencePath $fixture.outputPath
    } "SHA256 must match current bytes" "Publication gaps verification should reject public cutover evidence drift."
  }
  finally {
    Set-Content -LiteralPath $fixture.cutoverEvidencePath -Value $cutoverEvidenceBytes -NoNewline -Encoding utf8
  }

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
  Assert-True ($packageJson.scripts."release:generate-publication-gaps:win32-x64".Contains("-PublicCutoverRunbookPath docs/release/public-cutover-runbook.md")) "Root package should pass the public cutover runbook explicitly."
  Assert-True ($packageJson.scripts."release:generate-publication-gaps:win32-x64".Contains("-PublicCutoverEvidencePath docs/release/public-cutover-evidence.json")) "Root package should pass the public cutover evidence explicitly."
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
      "docs/release/public-cutover-evidence.json",
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

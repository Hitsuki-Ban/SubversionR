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

  $vsixPath = Join-Path $artifactsRoot "subversionr-win32-x64-0.2.4.vsix"
  [System.IO.File]::WriteAllBytes($vsixPath, [byte[]](0x53, 0x75, 0x62, 0x76, 0x65, 0x72, 0x73, 0x69, 0x6f, 0x6e, 0x52))
  $vsixSha256 = Get-Sha256 $vsixPath
  $historicalVsixSha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  $historicalVsixSize = 12
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
        displayName = "SVN-R"
        version = "0.2.4"
        preRelease = $true
      }
      vsix = [pscustomobject]@{
        path = $vsixPath
        relativePath = "target/tests/release-publication-gaps-scripts/artifacts/subversionr-win32-x64-0.2.4.vsix"
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
        displayName = "SVN-R"
        version = "0.2.4"
      }
      repository = [pscustomobject]@{
        remoteUrlRecorded = $false
      }
      artifacts = [pscustomobject]@{
        vsix = [pscustomobject]@{
          path = $vsixPath
          relativePath = "target/tests/release-publication-gaps-scripts/artifacts/subversionr-win32-x64-0.2.4.vsix"
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
        status = "verified"
        scope = "historical-public-cutover-release"
        readiness = [pscustomobject]@{
          readinessStatus = "live-attestation-verified"
          action = "actions/attest@v4"
          actionDigest = "a1948c3f048ba23858d222213b7c278aabede763"
          predicateClaim = "post-release-asset-digest-verification"
          originalBuildProvenanceClaim = $false
          artifactSignatureClaim = $false
          workflowPath = ".github/workflows/attest-release-vsix.yml"
          subjectName = "subversionr-win32-x64-0.2.0.vsix"
          subjectSha256 = $historicalVsixSha256
          artifactSize = $historicalVsixSize
          repoUrlRecorded = $true
          bundleRecorded = $true
          attestationUrlRecorded = $true
          verified = $true
          runUrl = "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/456"
          attestationUrl = "https://github.com/Hitsuki-Ban/SubversionR/attestations/123"
          evidencePath = "target/tests/release-publication-gaps-scripts/github-attestation-evidence.win32-x64.json"
          evidenceSha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        }
      }
      candidateAttestation = [pscustomobject]@{
        status = "pending-release-attestation"
        scope = "current-candidate"
        contractPath = "docs/release/github-attestation-candidate-contract.win32-x64.json"
        contractSha256 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        releaseTag = "v0.2.4-beta.1"
        releaseUrl = "https://github.com/Hitsuki-Ban/SubversionR/releases/tag/v0.2.4-beta.1"
        subjectName = "subversionr-win32-x64-0.2.4.vsix"
        subjectSha256 = $vsixSha256
        subjectSize = (Get-Item -LiteralPath $vsixPath).Length
        preReleaseProperty = $true
        liveEvidenceRecorded = $false
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
        branchProtectionConfigured = $true
        branchProtection = [pscustomobject]@{
          status = "active"
          provider = "github-repository-ruleset"
          rulesetId = [int64]18761017
          rulesetName = "protect-main"
          target = "branch"
          enforcement = "active"
          refIncludes = @("~DEFAULT_BRANCH")
          refExcludes = @()
          requiredStatusCheck = [pscustomobject]@{
            displayName = "PR Fast / windows"
            context = "windows"
            integrationId = [int64]15368
            strict = $false
          }
          pullRequestRequired = $true
          requiredApprovingReviewCount = 0
          nonFastForwardBlocked = $true
          bypassActorCount = 0
          updatedAt = "2026-07-10T07:29:42.633Z"
        }
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
        privateWorkflowsDisabled = $true
        privateWorkflowDisableDateRecorded = $true
        privateWorkflowDisablement = [pscustomobject]@{
          status = "complete"
          disableDate = "2026-07-10"
          workflows = @(
            [pscustomobject]@{
              name = "CI"
              workflowId = [int64]300115281
              path = ".github/workflows/ci.yml"
              state = "disabled_manually"
            },
            [pscustomobject]@{
              name = "PR Fast"
              workflowId = [int64]303103620
              path = ".github/workflows/pr-fast.yml"
              state = "disabled_manually"
            }
          )
        }
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
        artifactAttestationPublished = $true
        assets = @(
          [pscustomobject]@{
            name = "subversionr-source-sbom.cdx.json"
            size = 101
            sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            url = "$releaseAssetBaseUrl/subversionr-source-sbom.cdx.json"
          },
          [pscustomobject]@{
            name = "subversionr-win32-x64-0.2.0.vsix"
            size = $historicalVsixSize
            sha256 = $historicalVsixSha256
            url = "$releaseAssetBaseUrl/subversionr-win32-x64-0.2.0.vsix"
          },
          [pscustomobject]@{
            name = "subversionr-win32-x64-beta-candidate.zip"
            size = 15300834
            sha256 = "ca79f8cd2716caadc9c6e1e6c712c6904770a05e3660835b0ab58ce75bbbb266"
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
        status = "consistent"
        publishedBundleAssetName = "subversionr-win32-x64-beta-candidate.zip"
        publishedBundleSha256 = "ca79f8cd2716caadc9c6e1e6c712c6904770a05e3660835b0ab58ce75bbbb266"
        expectedVsixName = "subversionr-win32-x64-0.2.0.vsix"
        expectedVsixSha256 = $historicalVsixSha256
        containedVsixName = "subversionr-win32-x64-0.2.0.vsix"
        containedVsixSha256 = $historicalVsixSha256
        declaredPayloadCount = 1462
        missingPayloadCount = 0
        mismatchedPayloadCount = 0
        consistencyVerified = $true
        regenerationCompleted = $true
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

function Invoke-GeneratePublicationGaps([object]$Fixture, [string]$OutputPath, [string]$ExtensionPackage = "packages/vscode-extension/package.json", [string]$ProvenancePath = $null, [string]$CutoverEvidencePath = $null, [string]$BootstrapEvidencePath = "docs/release/marketplace-identity-bootstrap-evidence.json", [string]$PublisherAuthorizationEvidencePath = "docs/release/marketplace-publisher-authorization-evidence.json") {
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
    -MarketplacePublishWorkflowPath ".github/workflows/publish-marketplace.yml" `
    -MarketplaceIdentityBootstrapEvidencePath $BootstrapEvidencePath `
    -MarketplacePublisherAuthorizationEvidencePath $PublisherAuthorizationEvidencePath `
    -MarketplaceExistingListingEvidencePath "docs/release/marketplace-existing-listing-evidence.json" `
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
  Assert-Equal "verified" $report.marketplacePublisherAuthorization.status "Publisher authorization should record owner-attested Contributor access."
  Assert-Equal "True" ([string]$report.marketplacePublisherAuthorization.ownerOrContributorVerified) "Publisher authorization should be verified."
  Assert-Equal "False" ([string]$report.marketplacePublisherAuthorization.credentialRecorded) "Publisher authorization must not record credentials."
  Assert-Equal "False" ([string]$report.marketplacePublisherAuthorization.identityValueRecorded) "Publisher authorization must not record identity values."
  Assert-Equal "entra-federated-workflow-configured" $report.publishAuth.status "Publish auth should record the source-controlled Entra workflow."
  Assert-Equal "microsoft-entra-id-workload-identity" $report.publishAuth.primaryMode "Publish auth should track Entra ID as the primary mode."
  Assert-Equal ".github/workflows/publish-marketplace.yml" $report.publishAuth.workflowPath "Publish auth should bind the Marketplace workflow."
  Assert-Equal "marketplace" $report.publishAuth.githubEnvironment "Publish auth should bind the Marketplace environment."
  Assert-Equal "True" ([string]$report.publishAuth.azureCredentialConfigured) "Publish auth should record Entra workflow configuration."
  Assert-Equal "True" ([string]$report.publishAuth.claimAllowed) "Publish auth configuration claim should be allowed."
  Assert-Equal "entra-federated-login-verified" $report.publishAuth.bootstrap.status "Publish auth should bind the successful identity bootstrap."
  Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/29107576798" $report.publishAuth.bootstrap.runUrl "Publish auth should bind the public bootstrap run."
  Assert-Equal "False" ([string]$report.publishAuth.secretValueRecorded) "Publish auth must not record secret values."
  Assert-Equal "pre-existing-manual-publication" $report.marketplace.existingListing.status "Publication gaps should distinguish the existing listing from the Entra pipeline."
  Assert-Equal "0.1.0" $report.marketplace.existingListing.version "Publication gaps should record the observed existing listing version."
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
  Assert-Equal "True" ([string]$report.publicCutover.publicRepository.branchProtectionConfigured) "Public branch protection should record the active ruleset."
  Assert-Equal 18761017 ([int64]$report.publicCutover.publicRepository.branchProtection.rulesetId) "Public branch protection should bind the exact ruleset."
  Assert-Equal "windows" $report.publicCutover.publicRepository.branchProtection.requiredStatusCheck.context "Public branch protection should bind the exact check context."
  Assert-Equal "True" ([string]$report.publicCutover.publicRepository.branchProtection.pullRequestRequired) "Public branch protection should require pull requests."
  Assert-Equal "True" ([string]$report.publicCutover.publicRepository.branchProtection.nonFastForwardBlocked) "Public branch protection should block non-fast-forward updates."
  Assert-Equal 0 @($report.publicCutover.publicRepository.branchProtection.refExcludes).Count "Public branch protection should not exclude the default branch."
  Assert-Equal "False" ([string]$report.publicCutover.publicRepository.metadataVerified) "Incomplete public repository metadata should remain explicit."
  Assert-Equal "complete" $report.publicCutover.ciHomeMigration.status "CI home migration should record completed owner operations."
  Assert-Equal "True" ([string]$report.publicCutover.ciHomeMigration.privateWorkflowsDisabled) "Private workflows should be recorded as disabled."
  Assert-Equal "2026-07-10" $report.publicCutover.ciHomeMigration.privateWorkflowDisablement.disableDate "Private workflow disablement should bind its date."
  Assert-Equal 2 @($report.publicCutover.ciHomeMigration.privateWorkflowDisablement.workflows).Count "Private workflow disablement should record both workflows."
  Assert-Equal 0 @($report.publicCutover.ciHomeMigration.blockers).Count "Completed CI home migration should not retain blockers."
  Assert-Equal 1 @($report.publicCutover.manualSteps).Count "Public cutover should retain only metadata manual work."
  Assert-Equal "retired" $report.publicCutover.cloudflareBridgeRetirement.status "Cloudflare bridge retirement should be recorded."
  Assert-Equal "True" ([string]$report.publicCutover.cloudflareBridgeRetirement.disconnected) "Cloudflare bridge should be disconnected."
  Assert-Equal "published" $report.publicCutover.release.status "Public release should be recorded as published."
  Assert-Equal "v0.2.0-beta.1" $report.publicCutover.release.tag "Public cutover should record the first public Beta tag."
  Assert-Equal "True" ([string]$report.publicCutover.release.artifactAttestationPublished) "Live artifact attestation should be recorded."
  Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/456" $report.publicCutover.release.attestationRunUrl "Publication gaps should record the attestation run URL."
  Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/attestations/123" $report.publicCutover.release.attestationUrl "Publication gaps should record the attestation URL."
  Assert-Equal 4 @($report.publicCutover.release.assets).Count "Public cutover should record all four release assets."
  Assert-Equal "consistent" $report.publicCutover.betaCandidateEvidence.status "Published Beta candidate evidence should record verified consistency."
  Assert-Equal "True" ([string]$report.publicCutover.betaCandidateEvidence.consistencyVerified) "Published Beta candidate evidence should record consistency verification."
  Assert-Equal (Get-Sha256 $fixture.vsixPath) $report.artifacts.vsix.sha256 "Publication gaps should bind the exact VSIX hash."
  Assert-Equal "pending-release-attestation" $report.currentCandidate.status "Publication gaps should keep the current 0.2.4 candidate pending before release."
  Assert-Equal "True" ([string]$report.currentCandidate.preReleaseProperty) "Publication gaps should record current-candidate pre-release eligibility."
  $historicalReleasedVsix = @($report.publicCutover.release.assets | Where-Object { $_.name -eq "subversionr-win32-x64-0.2.0.vsix" })[0]
  Assert-True ($historicalReleasedVsix.sha256 -ne $report.artifacts.vsix.sha256) "Historical 0.2.0 and current 0.2.4 VSIX digests must remain distinct."
  foreach ($blocker in @(
      "The current 0.2.4 candidate release and live GitHub attestation have not been published.",
      "Marketplace publication is not run by this local gap report.",
      "Marketplace public install evidence is not generated by this local gap report.",
      "VSIX signing remains absent in the upstream provenance preflight.",
      "Public repository homepage and social metadata are not fully verified."
    )) {
    Assert-True (@($report.blockers | Where-Object { $_ -eq $blocker }).Count -eq 1) "Publication gaps should include blocker '$blocker'."
  }
  foreach ($resolvedBlocker in @(
      "Public branch protection is not configured.",
      "Private repository workflows are not disabled.",
      "The published Beta candidate bundle is inconsistent with its manifest and cannot close the post-cutover Beta-G chain."
    )) {
    Assert-Equal 0 @($report.blockers | Where-Object { $_ -eq $resolvedBlocker }).Count "Publication gaps should remove resolved blocker '$resolvedBlocker'."
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

  $badBootstrapPath = Join-Path $tempRoot "bad-marketplace-identity-bootstrap.json"
  $badBootstrap = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "docs\release\marketplace-identity-bootstrap-evidence.json") | ConvertFrom-Json
  $badBootstrap.status = "not-run"
  Write-JsonFile $badBootstrapPath $badBootstrap
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-bootstrap-report.json") -BootstrapEvidencePath $badBootstrapPath
  } "must record successful federation" "Publication gaps generation should reject unverified Marketplace identity bootstrap evidence."

  $badPublisherAuthorizationPath = Join-Path $tempRoot "bad-marketplace-publisher-authorization.json"
  $badPublisherAuthorization = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "docs\release\marketplace-publisher-authorization-evidence.json") | ConvertFrom-Json
  $badPublisherAuthorization.status = "pending-owner-membership"
  $badPublisherAuthorization.authorization.ownerOrContributorVerified = $false
  Write-JsonFile $badPublisherAuthorizationPath $badPublisherAuthorization
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-publisher-authorization-report.json") -PublisherAuthorizationEvidencePath $badPublisherAuthorizationPath
  } "status must be verified" "Publication gaps generation should reject unverified Marketplace publisher authorization evidence."

  $sensitivePublisherAuthorizationPath = Join-Path $tempRoot "sensitive-marketplace-publisher-authorization.json"
  $sensitivePublisherAuthorization = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "docs\release\marketplace-publisher-authorization-evidence.json") | ConvertFrom-Json
  $sensitivePublisherAuthorization.authorization.commentUrl = "https://github.com/Hitsuki-Ban/SubversionR/issues/14#00000000-0000-0000-0000-000000000000"
  Write-JsonFile $sensitivePublisherAuthorizationPath $sensitivePublisherAuthorization
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "sensitive-publisher-authorization-report.json") -PublisherAuthorizationEvidencePath $sensitivePublisherAuthorizationPath
  } "must not record identity or credential values" "Publication gaps generation should reject Marketplace identity values."

  $weakPublisherAuthorizationPath = Join-Path $tempRoot "weak-marketplace-publisher-authorization.json"
  $weakPublisherAuthorization = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "docs\release\marketplace-publisher-authorization-evidence.json") | ConvertFrom-Json
  $weakPublisherAuthorization.nonClaims = @($weakPublisherAuthorization.nonClaims | Select-Object -First 2)
  Write-JsonFile $weakPublisherAuthorizationPath $weakPublisherAuthorization
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "weak-publisher-authorization-report.json") -PublisherAuthorizationEvidencePath $weakPublisherAuthorizationPath
  } "non-claim count must match" "Publication gaps generation should reject weakened Marketplace publisher authorization non-claims."

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

  $tamperedPath = Join-Path $tempRoot "tampered-publisher-pending.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tampered.marketplacePublisherAuthorization.status = "pending-owner-membership"
  $tampered.marketplacePublisherAuthorization.ownerOrContributorVerified = $false
  Write-JsonFile $tamperedPath $tampered
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyPublicationGapsScript `
      -Target win32-x64 `
      -EvidencePath $tamperedPath
  } "must be verified" "Publication gaps verification should reject stale publisher authorization state."

  $tamperedPath = Join-Path $tempRoot "tampered-publisher-identity-value.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tampered.marketplacePublisherAuthorization | Add-Member -NotePropertyName "identityId" -NotePropertyValue "00000000-0000-0000-0000-000000000000"
  Write-JsonFile $tamperedPath $tampered
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyPublicationGapsScript `
      -Target win32-x64 `
      -EvidencePath $tamperedPath
  } "contains unexpected property 'identityId'" "Publication gaps verification should reject Marketplace identity values."

  $tamperedPath = Join-Path $tempRoot "tampered-publisher-evidence-path.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $replacementPublisherEvidencePath = Join-Path $repoRoot "docs\release\marketplace-existing-listing-evidence.json"
  $tampered.evidence.marketplacePublisherAuthorization.path = "docs/release/marketplace-existing-listing-evidence.json"
  $tampered.evidence.marketplacePublisherAuthorization.sha256 = Get-Sha256 $replacementPublisherEvidencePath
  Write-JsonFile $tamperedPath $tampered
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyPublicationGapsScript `
      -Target win32-x64 `
      -EvidencePath $tamperedPath
  } "must bind the source-controlled contract" "Publication gaps verification should reject a substituted Marketplace publisher authorization evidence path."

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
  $tampered.publicCutover.release.artifactAttestationPublished = $false
  Write-JsonFile $tamperedPath $tampered
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyPublicationGapsScript `
      -Target win32-x64 `
      -EvidencePath $tamperedPath
  } "must be true" "Publication gaps verification should reject removal of live attestation evidence."

  $badCutoverPath = Join-Path $tempRoot "bad-released-vsix-cutover.json"
  $badCutover = Get-Content -Raw -LiteralPath $fixture.cutoverEvidencePath | ConvertFrom-Json
  @($badCutover.release.assets | Where-Object { $_.name -eq "subversionr-win32-x64-0.2.0.vsix" })[0].sha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  Write-JsonFile $badCutoverPath $badCutover
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-released-vsix-report.json") -CutoverEvidencePath $badCutoverPath
  } "Historical released VSIX SHA256 must match historical provenance attestation evidence" "Publication gaps generation should reject historical release evidence whose asset and attestation records disagree."

  $badCutoverPath = Join-Path $tempRoot "bad-beta-candidate-consistency-cutover.json"
  $badCutover = Get-Content -Raw -LiteralPath $fixture.cutoverEvidencePath | ConvertFrom-Json
  $badCutover.betaCandidateEvidence.consistencyVerified = $false
  Write-JsonFile $badCutoverPath $badCutover
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-beta-candidate-consistency-report.json") -CutoverEvidencePath $badCutoverPath
  } "consistencyVerified must be true" "Publication gaps generation should reject a cutover record that withdraws published bundle consistency."

  $badCutoverPath = Join-Path $tempRoot "bad-ci-url-cutover.json"
  $badCutover = Get-Content -Raw -LiteralPath $fixture.cutoverEvidencePath | ConvertFrom-Json
  $badCutover.ci.runUrl = "https://example.invalid/actions/runs/123456789"
  Write-JsonFile $badCutoverPath $badCutover
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-ci-url-report.json") -CutoverEvidencePath $badCutoverPath
  } "runUrl must identify a public repository Actions run" "Publication gaps generation should reject a CI run outside the public repository."

  $badCutoverPath = Join-Path $tempRoot "bad-string-boolean-cutover.json"
  $badCutover = Get-Content -Raw -LiteralPath $fixture.cutoverEvidencePath | ConvertFrom-Json
  $badCutover.repository.branchProtectionConfigured = "True"
  Write-JsonFile $badCutoverPath $badCutover
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-string-boolean-report.json") -CutoverEvidencePath $badCutoverPath
  } "must be a JSON boolean" "Publication gaps generation should reject string values for boolean cutover fields."

  $badCutoverPath = Join-Path $tempRoot "bad-disabled-branch-protection-cutover.json"
  $badCutover = Get-Content -Raw -LiteralPath $fixture.cutoverEvidencePath | ConvertFrom-Json
  $badCutover.repository.branchProtectionConfigured = $false
  Write-JsonFile $badCutoverPath $badCutover
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-disabled-branch-protection-report.json") -CutoverEvidencePath $badCutoverPath
  } "must be true" "Publication gaps generation should reject unresolved branch protection state."

  $badCutoverPath = Join-Path $tempRoot "bad-missing-ruleset-check-cutover.json"
  $badCutover = Get-Content -Raw -LiteralPath $fixture.cutoverEvidencePath | ConvertFrom-Json
  $badCutover.repository.branchProtection.PSObject.Properties.Remove("requiredStatusCheck")
  Write-JsonFile $badCutoverPath $badCutover
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-missing-ruleset-check-report.json") -CutoverEvidencePath $badCutoverPath
  } "must define requiredStatusCheck" "Publication gaps generation should reject incomplete ruleset evidence."

  $badCutoverPath = Join-Path $tempRoot "bad-scalar-ruleset-ref-cutover.json"
  $badCutover = Get-Content -Raw -LiteralPath $fixture.cutoverEvidencePath | ConvertFrom-Json
  $badCutover.repository.branchProtection.refIncludes = "~DEFAULT_BRANCH"
  Write-JsonFile $badCutoverPath $badCutover
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-scalar-ruleset-ref-report.json") -CutoverEvidencePath $badCutoverPath
  } "refIncludes must be a JSON array" "Publication gaps generation should reject a scalar ruleset ref selector."

  $badCutoverPath = Join-Path $tempRoot "bad-nested-ruleset-ref-cutover.json"
  $badCutover = Get-Content -Raw -LiteralPath $fixture.cutoverEvidencePath | ConvertFrom-Json
  $badCutover.repository.branchProtection.refIncludes = [object[]]@(, [object[]]@("~DEFAULT_BRANCH"))
  Write-JsonFile $badCutoverPath $badCutover
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-nested-ruleset-ref-report.json") -CutoverEvidencePath $badCutoverPath
  } "entries must be JSON strings" "Publication gaps generation should reject a nested ruleset ref selector."

  $badCutoverPath = Join-Path $tempRoot "bad-ruleset-ref-exclusion-cutover.json"
  $badCutover = Get-Content -Raw -LiteralPath $fixture.cutoverEvidencePath | ConvertFrom-Json
  $badCutover.repository.branchProtection.refExcludes = @("refs/heads/main")
  Write-JsonFile $badCutoverPath $badCutover
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-ruleset-ref-exclusion-report.json") -CutoverEvidencePath $badCutoverPath
  } "must not exclude any refs" "Publication gaps generation should reject a ruleset that excludes main."

  $badCutoverPath = Join-Path $tempRoot "bad-scalar-ruleset-ref-exclusion-cutover.json"
  $badCutover = Get-Content -Raw -LiteralPath $fixture.cutoverEvidencePath | ConvertFrom-Json
  $badCutover.repository.branchProtection.refExcludes = "refs/heads/main"
  Write-JsonFile $badCutoverPath $badCutover
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-scalar-ruleset-ref-exclusion-report.json") -CutoverEvidencePath $badCutoverPath
  } "refExcludes must be a JSON array" "Publication gaps generation should reject a scalar ruleset exclusion."

  $badCutoverPath = Join-Path $tempRoot "bad-ruleset-integration-cutover.json"
  $badCutover = Get-Content -Raw -LiteralPath $fixture.cutoverEvidencePath | ConvertFrom-Json
  $badCutover.repository.branchProtection.requiredStatusCheck.integrationId = [int64]0
  Write-JsonFile $badCutoverPath $badCutover
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-ruleset-integration-report.json") -CutoverEvidencePath $badCutoverPath
  } "integrationId must match" "Publication gaps generation should reject a different required-check integration."

  $badCutoverPath = Join-Path $tempRoot "bad-string-ruleset-integration-cutover.json"
  $badCutover = Get-Content -Raw -LiteralPath $fixture.cutoverEvidencePath | ConvertFrom-Json
  $badCutover.repository.branchProtection.requiredStatusCheck.integrationId = "15368"
  Write-JsonFile $badCutoverPath $badCutover
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-string-ruleset-integration-report.json") -CutoverEvidencePath $badCutoverPath
  } "must be a JSON integer" "Publication gaps generation should reject string values for numeric ruleset fields."

  $badCutoverPath = Join-Path $tempRoot "bad-array-ruleset-status-cutover.json"
  $badCutover = Get-Content -Raw -LiteralPath $fixture.cutoverEvidencePath | ConvertFrom-Json
  $badCutover.repository.branchProtection.status = @("active")
  Write-JsonFile $badCutoverPath $badCutover
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-array-ruleset-status-report.json") -CutoverEvidencePath $badCutoverPath
  } "must be a non-empty JSON string" "Publication gaps generation should reject an array ruleset status."

  $badCutoverPath = Join-Path $tempRoot "bad-private-workflow-state-cutover.json"
  $badCutover = Get-Content -Raw -LiteralPath $fixture.cutoverEvidencePath | ConvertFrom-Json
  @($badCutover.ci.privateWorkflowDisablement.workflows | Where-Object { $_.name -eq "CI" })[0].state = "active"
  Write-JsonFile $badCutoverPath $badCutover
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-private-workflow-state-report.json") -CutoverEvidencePath $badCutoverPath
  } "state must be disabled_manually" "Publication gaps generation should reject an active private workflow."

  $badCutoverPath = Join-Path $tempRoot "bad-array-private-workflow-state-cutover.json"
  $badCutover = Get-Content -Raw -LiteralPath $fixture.cutoverEvidencePath | ConvertFrom-Json
  @($badCutover.ci.privateWorkflowDisablement.workflows | Where-Object { $_.name -eq "CI" })[0].state = @("disabled_manually")
  Write-JsonFile $badCutoverPath $badCutover
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-array-private-workflow-state-report.json") -CutoverEvidencePath $badCutoverPath
  } "must be a non-empty JSON string" "Publication gaps generation should reject an array private workflow state."

  $badCutoverPath = Join-Path $tempRoot "bad-private-workflow-date-cutover.json"
  $badCutover = Get-Content -Raw -LiteralPath $fixture.cutoverEvidencePath | ConvertFrom-Json
  $badCutover.ci.privateWorkflowDisablement.disableDate = "2026-07-11"
  Write-JsonFile $badCutoverPath $badCutover
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-private-workflow-date-report.json") -CutoverEvidencePath $badCutoverPath
  } "must match the owner operation date" "Publication gaps generation should reject a different private workflow disable date."

  $badCutoverPath = Join-Path $tempRoot "bad-unknown-cutover-property.json"
  $badCutover = Get-Content -Raw -LiteralPath $fixture.cutoverEvidencePath | ConvertFrom-Json
  $badCutover.repository | Add-Member -NotePropertyName "unexpectedOwnerState" -NotePropertyValue "present"
  Write-JsonFile $badCutoverPath $badCutover
  Assert-NativeCommandFailsContaining {
    Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-unknown-cutover-property-report.json") -CutoverEvidencePath $badCutoverPath
  } "contains unexpected property" "Publication gaps generation should reject unknown cutover fields."

  foreach ($sensitiveCase in @(
      [pscustomobject]@{ name = "private-ssh"; property = "ownerRemote"; value = "git@github.com:Hitsuki-Ban/SubversionR-private.git"; target = "repository" },
      [pscustomobject]@{ name = "github-token-family"; property = "ownerToken"; value = "gho_aaaaaaaaaaaaaaaaaaaaaaaa"; target = "ci" },
      [pscustomobject]@{ name = "cloudflare-account-id"; property = "accountId"; value = "0123456789abcdef0123456789abcdef"; target = "cloudflareBridgeRetirement" }
    )) {
    $badCutoverPath = Join-Path $tempRoot "bad-$($sensitiveCase.name)-cutover.json"
    $badCutover = Get-Content -Raw -LiteralPath $fixture.cutoverEvidencePath | ConvertFrom-Json
    $badCutover.($sensitiveCase.target) | Add-Member -NotePropertyName $sensitiveCase.property -NotePropertyValue $sensitiveCase.value
    Write-JsonFile $badCutoverPath $badCutover
    Assert-NativeCommandFailsContaining {
      Invoke-GeneratePublicationGaps -Fixture $fixture -OutputPath (Join-Path $tempRoot "bad-$($sensitiveCase.name)-report.json") -CutoverEvidencePath $badCutoverPath
    } "must not record credentials" "Publication gaps generation should reject sensitive case '$($sensitiveCase.name)'."
  }

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
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $productionMismatchPath) | Out-Null
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

  $publisherAuthorizationEvidencePath = Join-Path $repoRoot "docs\release\marketplace-publisher-authorization-evidence.json"
  $publisherAuthorizationEvidenceBytes = Get-Content -Raw -LiteralPath $publisherAuthorizationEvidencePath
  try {
    $driftedPublisherAuthorization = $publisherAuthorizationEvidenceBytes | ConvertFrom-Json
    $driftedPublisherAuthorization.authorization.verifiedAt = "2026-07-10T18:05:39Z"
    Write-JsonFile $publisherAuthorizationEvidencePath $driftedPublisherAuthorization
    Assert-NativeCommandFailsContaining {
      & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyPublicationGapsScript `
        -Target win32-x64 `
        -EvidencePath $fixture.outputPath
    } "SHA256 must match current bytes" "Publication gaps verification should reject Marketplace publisher authorization evidence drift."
  }
  finally {
    Set-Content -LiteralPath $publisherAuthorizationEvidencePath -Value $publisherAuthorizationEvidenceBytes -NoNewline -Encoding utf8
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
  } "non-claim count must match" "Publication gaps verification should reject missing non-claims."

  $tamperedPath = Join-Path $tempRoot "tampered-stale-blocker.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tampered.blockers = @($tampered.blockers) + "Public branch protection is not configured."
  Write-JsonFile $tamperedPath $tampered
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyPublicationGapsScript `
      -Target win32-x64 `
      -EvidencePath $tamperedPath
  } "blocker count must match" "Publication gaps verification should reject stale resolved blockers."

  $tamperedPath = Join-Path $tempRoot "tampered-scalar-repository-blocker.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tampered.publicCutover.publicRepository.blockers = "Verify and complete public repository homepage and social metadata."
  Write-JsonFile $tamperedPath $tampered
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyPublicationGapsScript `
      -Target win32-x64 `
      -EvidencePath $tamperedPath
  } "blockers must be a JSON array" "Publication gaps verification should reject a scalar repository blocker."

  $packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  Assert-True ($packageJson.scripts."release:test-publication-gaps-scripts".Contains("release-publication-gaps-scripts.tests.ps1")) "Root package should expose publication gaps script tests."
  Assert-True ($packageJson.scripts."release:generate-publication-gaps:win32-x64".Contains("generate-publication-gaps.ps1")) "Root package should expose publication gaps generation."
  Assert-True ($packageJson.scripts."release:generate-publication-gaps:win32-x64".Contains("-PublicCutoverRunbookPath docs/release/public-cutover-runbook.md")) "Root package should pass the public cutover runbook explicitly."
  Assert-True ($packageJson.scripts."release:generate-publication-gaps:win32-x64".Contains("-PublicCutoverEvidencePath docs/release/public-cutover-evidence.json")) "Root package should pass the public cutover evidence explicitly."
  Assert-True ($packageJson.scripts."release:generate-publication-gaps:win32-x64".Contains("-MarketplacePublishWorkflowPath .github/workflows/publish-marketplace.yml")) "Root package should pass the Marketplace publish workflow explicitly."
  Assert-True ($packageJson.scripts."release:generate-publication-gaps:win32-x64".Contains("-MarketplaceIdentityBootstrapEvidencePath docs/release/marketplace-identity-bootstrap-evidence.json")) "Root package should pass the Marketplace identity bootstrap evidence explicitly."
  Assert-True ($packageJson.scripts."release:generate-publication-gaps:win32-x64".Contains("-MarketplacePublisherAuthorizationEvidencePath docs/release/marketplace-publisher-authorization-evidence.json")) "Root package should pass the Marketplace publisher authorization evidence explicitly."
  Assert-True ($packageJson.scripts."release:generate-publication-gaps:win32-x64".Contains("-MarketplaceExistingListingEvidencePath docs/release/marketplace-existing-listing-evidence.json")) "Root package should pass the Marketplace existing-listing evidence explicitly."
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
      "docs/release/marketplace-publisher-authorization-evidence.json",
      '"rulesetId": 18761017',
      '"integrationId": 15368',
      '"workflowId": 300115281',
      '"workflowId": 303103620',
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

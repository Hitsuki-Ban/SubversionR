$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$generateProvenanceScript = Join-Path $repoRoot "scripts\release\generate-release-provenance.ps1"
$verifyProvenanceScript = Join-Path $repoRoot "scripts\release\verify-release-provenance.ps1"
$packageJsonPath = Join-Path $repoRoot "package.json"
$ciWorkflowPath = Join-Path $repoRoot ".github\workflows\ci.yml"
$extensionPackagePath = Join-Path $repoRoot "packages\vscode-extension\package.json"

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

function New-ProvenanceFixture([string]$Root) {
  $artifactsRoot = Join-Path $Root "artifacts"
  $evidenceRoot = Join-Path $Root "evidence"
  New-Item -ItemType Directory -Force -Path $artifactsRoot | Out-Null
  New-Item -ItemType Directory -Force -Path $evidenceRoot | Out-Null

  $vsixPath = Join-Path $artifactsRoot "subversionr-win32-x64-0.2.0.vsix"
  [System.IO.File]::WriteAllBytes($vsixPath, [byte[]](0x53, 0x75, 0x62, 0x76, 0x65, 0x72, 0x73, 0x69, 0x6f, 0x6e, 0x52))
  $vsixSha256 = Get-Sha256 $vsixPath
  $marketplaceIconPath = Join-Path $repoRoot "packages\vscode-extension\resources\marketplace\icon.png"
  $marketplaceIconSha256 = Get-Sha256 $marketplaceIconPath

  $vsixEvidencePath = Join-Path $evidenceRoot "subversionr-vsix-package-win32-x64.json"
  Write-JsonFile $vsixEvidencePath ([pscustomobject]@{
      schemaVersion = 1
      schema = "subversionr.release.vsix-package.win32-x64.v1"
      publicReadinessClaim = $false
      target = "win32-x64"
      traceIds = @("SEC-015", "MIG-009")
      extension = [pscustomobject]@{
        id = "hitsuki-ban.subversionr"
        displayName = "SubversionR"
        version = "0.2.0"
      }
      inputs = [pscustomobject]@{
        extensionEntrypointSha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        vscodeIgnoreSha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        marketplaceIcon = [pscustomobject]@{
          path = "resources/marketplace/icon.png"
          sha256 = $marketplaceIconSha256
        }
      }
      vsix = [pscustomobject]@{
        path = $vsixPath
        relativePath = "target/tests/release-provenance-scripts/artifacts/subversionr-win32-x64-0.2.0.vsix"
        size = (Get-Item -LiteralPath $vsixPath).Length
        sha256 = $vsixSha256
        extensionEntrypointSha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        marketplaceIconSha256 = $marketplaceIconSha256
      }
    })

  $sbomPath = Join-Path $evidenceRoot "subversionr-source-sbom.cdx.json"
  Write-JsonFile $sbomPath ([pscustomobject]@{
      bomFormat = "CycloneDX"
      specVersion = "1.6"
      metadata = [pscustomobject]@{
        component = [pscustomobject]@{
          type = "application"
          name = "SubversionR"
        }
        properties = @(
          [pscustomobject]@{
            name = "subversionr:evidenceKind"
            value = "source-lock-sbom"
          }
        )
      }
      components = @(
        [pscustomobject]@{
          type = "application"
          name = "subversionr"
          version = "0.2.0"
        }
      )
    })

  $noticePath = Join-Path $evidenceRoot "THIRD-PARTY-NOTICES.md"
  @"
# SubversionR Third-Party Notices

This generated evidence is not a completed legal review.
"@ | Set-Content -LiteralPath $noticePath -Encoding utf8

  $backendManifestPath = Join-Path $evidenceRoot "subversionr-backend-package-manifest.json"
  Write-JsonFile $backendManifestPath ([pscustomobject]@{
      schemaVersion = 1
      schema = "subversionr.vscode.backend-package.win32-x64.v1"
      target = "win32-x64"
      extension = [pscustomobject]@{
        id = "subversionr"
        displayName = "SubversionR"
        version = "0.2.0"
      }
      artifacts = @(
        [pscustomobject]@{
          role = "sidecar"
          path = "resources/backend/win32-x64/subversionr-daemon.exe"
          sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
        }
      )
    })

  [pscustomobject]@{
    vsixPath = $vsixPath
    vsixEvidencePath = $vsixEvidencePath
    sbomPath = $sbomPath
    noticePath = $noticePath
    backendManifestPath = $backendManifestPath
    outputPath = Join-Path $evidenceRoot "subversionr-marketplace-provenance-preflight-win32-x64.json"
  }
}

function Invoke-GenerateProvenance([object]$Fixture, [string]$OutputPath) {
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $generateProvenanceScript `
    -Target win32-x64 `
    -ExtensionPackagePath "packages/vscode-extension/package.json" `
    -RootPackagePath "package.json" `
    -ReadmePath "README.md" `
    -LicensePath "LICENSE" `
    -ChangelogPath "CHANGELOG.md" `
    -SupportPath "SUPPORT.md" `
    -SourceLockPath "native/sources.lock.json" `
    -PnpmLockPath "pnpm-lock.yaml" `
    -CargoLockPath "Cargo.lock" `
    -SbomPath $Fixture.sbomPath `
    -NoticePath $Fixture.noticePath `
    -VsixEvidencePath $Fixture.vsixEvidencePath `
    -BackendManifestPath $Fixture.backendManifestPath `
    -OutputPath $OutputPath
}

$tempRoot = Join-Path $repoRoot "target\tests\release-provenance-scripts\$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  Assert-True (Test-Path -LiteralPath $generateProvenanceScript -PathType Leaf) "generate-release-provenance.ps1 should exist."
  Assert-True (Test-Path -LiteralPath $verifyProvenanceScript -PathType Leaf) "verify-release-provenance.ps1 should exist."
  Assert-True (Test-Path -LiteralPath (Join-Path $repoRoot "CHANGELOG.md") -PathType Leaf) "CHANGELOG.md should exist before Marketplace preflight."
  Assert-True (Test-Path -LiteralPath (Join-Path $repoRoot "SUPPORT.md") -PathType Leaf) "SUPPORT.md should exist before Marketplace preflight."
  $expectedMarketplaceIconSha256 = Get-Sha256 (Join-Path $repoRoot "packages\vscode-extension\resources\marketplace\icon.png")

  $fixture = New-ProvenanceFixture $tempRoot
  Invoke-GenerateProvenance -Fixture $fixture -OutputPath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "generate-release-provenance.ps1 failed with exit code $LASTEXITCODE."
  }
  $validReportPath = $fixture.outputPath

  $report = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  Assert-Equal "subversionr.release.marketplace-provenance-preflight.win32-x64.v1" $report.schema "Provenance preflight evidence should use the M7j2a schema."
  Assert-Equal "False" ([string]$report.publicReadinessClaim) "Provenance preflight evidence must not claim public readiness."
  Assert-Equal "True" ([string]$report.localPreflightOnly) "Provenance preflight evidence must be local-preflight only."
  Assert-Equal "win32-x64" $report.target "Provenance preflight evidence should record the target."
  Assert-Equal "hitsuki-ban.subversionr" $report.extension.id "Provenance preflight should bind the extension identity."
  Assert-Equal "SubversionR" $report.extension.displayName "Provenance preflight should bind the display name."
  Assert-Equal "^1.101.0" $report.extension.enginesVscode "Provenance preflight should record the VS Code engine range."
  Assert-Equal "resources/marketplace/icon.png" $report.extension.icon.path "Provenance preflight should bind the Marketplace icon path."
  Assert-True ([int]$report.extension.icon.width -ge 128) "Provenance preflight should record a Marketplace icon width of at least 128 pixels."
  Assert-True ([int]$report.extension.icon.height -ge 128) "Provenance preflight should record a Marketplace icon height of at least 128 pixels."
  Assert-Equal $expectedMarketplaceIconSha256 $report.extension.icon.sha256 "Provenance preflight should bind the Marketplace icon SHA256."
  foreach ($keyword in @("svn", "subversion", "source-control", "scm", "apache-subversion")) {
    Assert-True (@($report.extension.keywords | Where-Object { $_ -eq $keyword }).Count -eq 1) "Provenance preflight should record Marketplace keyword $keyword."
  }
  Assert-Equal "False" ([string]$report.repository.remoteUrlRecorded) "Provenance preflight must not record private remote URLs."
  Assert-True ($null -ne $report.repository.dirtyWorkingTree) "Provenance preflight should record the working-tree cleanliness state."
  Assert-Equal "unsigned" $report.signing.status "Provenance preflight should keep signing status explicit."
  Assert-Equal "not-generated" $report.attestation.status "Provenance preflight should keep attestation status explicit."
  Assert-Equal "input-contract-ready" $report.attestation.readiness.readinessStatus "Attestation readiness should record only input-contract readiness."
  Assert-Equal "github-artifact-attestations" $report.attestation.readiness.provider "Attestation readiness should record the provider."
  Assert-Equal "actions/attest@v4" $report.attestation.readiness.action "Attestation readiness should record the current GitHub attestation action contract."
  Assert-Equal "https://slsa.dev/provenance/v1" $report.attestation.readiness.predicateType "Attestation readiness should record the SLSA provenance predicate type."
  Assert-Equal "subversionr-win32-x64-0.2.0.vsix" $report.attestation.readiness.subjectName "Attestation readiness should bind the VSIX file name."
  Assert-Equal (Get-Sha256 $fixture.vsixPath) $report.attestation.readiness.subjectSha256 "Attestation readiness should bind the exact VSIX SHA256."
  Assert-Equal $report.artifacts.vsix.relativePath $report.attestation.readiness.artifactPath "Attestation readiness should bind the VSIX relative path."
  Assert-Equal ([int64](Get-Item -LiteralPath $fixture.vsixPath).Length) ([int64]$report.attestation.readiness.artifactSize) "Attestation readiness should bind the VSIX size."
  Assert-Equal ".github/workflows/ci.yml" $report.attestation.readiness.workflowPath "Attestation readiness should record the release-producing workflow path."
  Assert-Equal "False" ([string]$report.attestation.readiness.repoUrlRecorded) "Attestation readiness must not record repository URLs."
  Assert-Equal "False" ([string]$report.attestation.readiness.bundleRecorded) "Attestation readiness must not record attestation bundles in the local preflight."
  Assert-Equal "False" ([string]$report.attestation.readiness.attestationUrlRecorded) "Attestation readiness must not record attestation URLs in the local preflight."
  Assert-Equal "False" ([string]$report.attestation.readiness.verified) "Attestation readiness must not claim GitHub verification."
  foreach ($permission in @("id-token: write", "contents: read", "attestations: write")) {
    Assert-True (@($report.attestation.readiness.requiredPermissions | Where-Object { $_ -eq $permission }).Count -eq 1) "Attestation readiness should record required permission $permission."
  }
  Assert-True ($report.attestation.readiness.verificationCommand.Contains("--signer-workflow Hitsuki-Ban/SubversionR/.github/workflows/ci.yml")) "Attestation readiness verification command should pin the signer workflow."
  Assert-True ($report.attestation.readiness.verificationCommand.Contains("--predicate-type https://slsa.dev/provenance/v1")) "Attestation readiness verification command should pin the provenance predicate."
  Assert-True ($report.attestation.readiness.verificationCommand.Contains("--deny-self-hosted-runners")) "Attestation readiness verification command should reject self-hosted runner attestations."
  Assert-Equal "not-published" $report.marketplace.status "Provenance preflight should keep Marketplace publication status explicit."
  Assert-Equal "False" ([string]$report.marketplaceMetadata.publicationReady) "Marketplace metadata preflight should not claim publication readiness."
  Assert-Equal "True" ([string]$report.marketplaceMetadata.required.hasReadme) "Marketplace metadata should require README."
  Assert-Equal "True" ([string]$report.marketplaceMetadata.required.hasLicense) "Marketplace metadata should require LICENSE."
  Assert-Equal "True" ([string]$report.marketplaceMetadata.required.hasIcon) "Marketplace metadata should require icon."
  Assert-Equal "True" ([string]$report.marketplaceMetadata.required.hasKeywords) "Marketplace metadata should require keywords."
  Assert-Equal "True" ([string]$report.marketplaceMetadata.recommended.hasChangelog) "Marketplace metadata should record CHANGELOG."
  Assert-Equal "True" ([string]$report.marketplaceMetadata.recommended.hasSupport) "Marketplace metadata should record SUPPORT."
  Assert-Equal $expectedMarketplaceIconSha256 $report.marketplaceMetadata.icon.sha256 "Marketplace metadata should bind the icon SHA256."
  Assert-Equal "True" ([string]$report.marketplaceMetadata.recommended.hasRepository) "Provenance should record repository metadata presence."
  Assert-Equal "True" ([string]$report.marketplaceMetadata.recommended.hasHomepage) "Provenance should record homepage metadata presence."
  Assert-Equal "True" ([string]$report.marketplaceMetadata.recommended.hasBugs) "Provenance should record issue tracker metadata presence."
  Assert-Equal "False" ([string]$report.marketplaceMetadata.recommended.privatePackage) "Provenance should record public extension package state."
  foreach ($blocker in @(
      "Marketplace publisher authorization is not verified by this local preflight.",
      "Marketplace publish authentication is not configured by this local preflight.",
      "Marketplace/public install evidence is not generated by this local preflight.",
      "Previous stable artifact rollback evidence is not generated by this local preflight."
    )) {
    Assert-True (@($report.marketplaceMetadata.blockers | Where-Object { $_ -eq $blocker }).Count -eq 1) "Marketplace metadata blockers should include '$blocker'."
  }
  Assert-Equal (Get-Sha256 $fixture.vsixPath) $report.artifacts.vsix.sha256 "Provenance preflight should hash the exact VSIX bytes."
  Assert-Equal $expectedMarketplaceIconSha256 $report.evidence.marketplaceIcon.sha256 "Provenance preflight should hash the Marketplace icon evidence."
  Assert-Equal (Get-Sha256 $fixture.sbomPath) $report.evidence.sbom.sha256 "Provenance preflight should hash SBOM evidence."
  Assert-Equal (Get-Sha256 $fixture.noticePath) $report.evidence.notice.sha256 "Provenance preflight should hash NOTICE evidence."
  foreach ($traceId in @("SEC-015", "MIG-009", "MIG-012")) {
    Assert-True (@($report.traceIds | Where-Object { $_ -eq $traceId }).Count -eq 1) "Provenance preflight should trace $traceId."
  }
  foreach ($nonClaim in @(
      "This gate does not prove VSIX signing.",
      "This gate does not prove GitHub artifact attestation publication.",
      "This gate does not prove GitHub artifact attestation generation, publication, or verification.",
      "This gate does not prove Marketplace publication or public install.",
      "This gate does not prove previous-stable upgrade or rollback."
    )) {
    Assert-True (@($report.nonClaims | Where-Object { $_ -eq $nonClaim }).Count -eq 1) "Provenance preflight should preserve non-claim: $nonClaim"
  }

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyProvenanceScript `
    -Target win32-x64 `
    -EvidencePath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "verify-release-provenance.ps1 failed with exit code $LASTEXITCODE."
  }

  [System.IO.File]::WriteAllBytes($fixture.vsixPath, [byte[]](0x74, 0x61, 0x6d, 0x70, 0x65, 0x72))
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyProvenanceScript `
      -Target win32-x64 `
      -EvidencePath $fixture.outputPath
  } "VSIX SHA256" "Provenance verification should fail when the VSIX bytes drift."

  $fixture = New-ProvenanceFixture (Join-Path $tempRoot "second")
  $badOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "subversionr-provenance-outside-target.json"
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateProvenance -Fixture $fixture -OutputPath $badOutputPath
  } "OutputPath must resolve inside" "Provenance generation should reject output paths outside target."

  $badVsixEvidencePath = Join-Path $tempRoot "public-readiness-true.json"
  $badVsixEvidence = Get-Content -Raw -LiteralPath $fixture.vsixEvidencePath | ConvertFrom-Json
  $badVsixEvidence.publicReadinessClaim = $true
  Write-JsonFile $badVsixEvidencePath $badVsixEvidence
  $badVsixFixture = [pscustomobject]@{
    vsixPath = $fixture.vsixPath
    vsixEvidencePath = $badVsixEvidencePath
    sbomPath = $fixture.sbomPath
    noticePath = $fixture.noticePath
    backendManifestPath = $fixture.backendManifestPath
  }
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateProvenance -Fixture $badVsixFixture -OutputPath (Join-Path $tempRoot "bad-public-readiness.json")
  } "publicReadinessClaim" "Provenance generation should reject upstream evidence that claims public readiness."

  $badIconEvidencePath = Join-Path $tempRoot "bad-icon-evidence.json"
  $badIconEvidence = Get-Content -Raw -LiteralPath $fixture.vsixEvidencePath | ConvertFrom-Json
  $badIconEvidence.vsix.marketplaceIconSha256 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  Write-JsonFile $badIconEvidencePath $badIconEvidence
  $badIconFixture = [pscustomobject]@{
    vsixPath = $fixture.vsixPath
    vsixEvidencePath = $badIconEvidencePath
    sbomPath = $fixture.sbomPath
    noticePath = $fixture.noticePath
    backendManifestPath = $fixture.backendManifestPath
  }
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateProvenance -Fixture $badIconFixture -OutputPath (Join-Path $tempRoot "bad-icon-report.json")
  } "Marketplace icon SHA256" "Provenance generation should reject VSIX evidence with Marketplace icon hash drift."

  $badIconPathCases = @(
    [pscustomobject]@{ value = "../icon.png"; name = "parent-relative" },
    [pscustomobject]@{ value = "C:/SubversionR/icon.png"; name = "absolute" },
    [pscustomobject]@{ value = "resources\marketplace\icon.png"; name = "backslash" },
    [pscustomobject]@{ value = "./resources/marketplace/icon.png"; name = "dot-relative" }
  )
  foreach ($badIconPathCase in $badIconPathCases) {
    $badIconPathPackagePath = Join-Path $tempRoot "bad-icon-path-$($badIconPathCase.name)-package.json"
    $badIconPathPackage = Get-Content -Raw -LiteralPath $extensionPackagePath | ConvertFrom-Json
    $badIconPathPackage.icon = $badIconPathCase.value
    Write-JsonFile $badIconPathPackagePath $badIconPathPackage
    Assert-NativeCommandFailsContaining {
      & pwsh -NoProfile -ExecutionPolicy Bypass -File $generateProvenanceScript `
        -Target win32-x64 `
        -ExtensionPackagePath $badIconPathPackagePath `
        -RootPackagePath "package.json" `
        -ReadmePath "README.md" `
        -LicensePath "LICENSE" `
        -ChangelogPath "CHANGELOG.md" `
        -SupportPath "SUPPORT.md" `
        -SourceLockPath "native/sources.lock.json" `
        -PnpmLockPath "pnpm-lock.yaml" `
        -CargoLockPath "Cargo.lock" `
        -SbomPath $fixture.sbomPath `
        -NoticePath $fixture.noticePath `
        -VsixEvidencePath $fixture.vsixEvidencePath `
        -BackendManifestPath $fixture.backendManifestPath `
        -OutputPath (Join-Path $tempRoot "bad-icon-path-$($badIconPathCase.name)-report.json")
    } "normalized package-relative path" "Provenance generation should reject $($badIconPathCase.name) Marketplace icon paths."
  }

  $badPackagePath = Join-Path $tempRoot "bad-package.json"
  $badPackage = Get-Content -Raw -LiteralPath $extensionPackagePath | ConvertFrom-Json
  $badPackage.publisher = "wrong-publisher"
  Write-JsonFile $badPackagePath $badPackage
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $generateProvenanceScript `
      -Target win32-x64 `
      -ExtensionPackagePath $badPackagePath `
      -RootPackagePath "package.json" `
      -ReadmePath "README.md" `
      -LicensePath "LICENSE" `
      -ChangelogPath "CHANGELOG.md" `
      -SupportPath "SUPPORT.md" `
      -SourceLockPath "native/sources.lock.json" `
      -PnpmLockPath "pnpm-lock.yaml" `
      -CargoLockPath "Cargo.lock" `
      -SbomPath $fixture.sbomPath `
      -NoticePath $fixture.noticePath `
      -VsixEvidencePath $fixture.vsixEvidencePath `
      -BackendManifestPath $fixture.backendManifestPath `
      -OutputPath (Join-Path $tempRoot "bad-package-report.json")
  } "hitsuki-ban.subversionr" "Provenance generation should reject package identity drift."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $generateProvenanceScript `
      -Target win32-x64 `
      -ExtensionPackagePath "packages/vscode-extension/package.json" `
      -RootPackagePath "package.json" `
      -ReadmePath "README.md" `
      -LicensePath "LICENSE" `
      -ChangelogPath (Join-Path $tempRoot "missing-CHANGELOG.md") `
      -SupportPath "SUPPORT.md" `
      -SourceLockPath "native/sources.lock.json" `
      -PnpmLockPath "pnpm-lock.yaml" `
      -CargoLockPath "Cargo.lock" `
      -SbomPath $fixture.sbomPath `
      -NoticePath $fixture.noticePath `
      -VsixEvidencePath $fixture.vsixEvidencePath `
      -BackendManifestPath $fixture.backendManifestPath `
      -OutputPath (Join-Path $tempRoot "missing-changelog-report.json")
  } "ChangelogPath" "Provenance generation should fail fast when CHANGELOG is missing."

  $readinessFixture = New-ProvenanceFixture (Join-Path $tempRoot "readiness")
  Invoke-GenerateProvenance -Fixture $readinessFixture -OutputPath $readinessFixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "generate-release-provenance.ps1 failed for attestation readiness fixture with exit code $LASTEXITCODE."
  }
  $readinessValidReportPath = $readinessFixture.outputPath

  $tamperedReportPath = Join-Path $tempRoot "tampered-nonclaims.json"
  $tamperedReport = Get-Content -Raw -LiteralPath $readinessValidReportPath | ConvertFrom-Json
  $tamperedReport.nonClaims = @($tamperedReport.nonClaims | Where-Object { $_ -ne "This gate does not prove GitHub artifact attestation generation, publication, or verification." })
  Write-JsonFile $tamperedReportPath $tamperedReport
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyProvenanceScript `
      -Target win32-x64 `
      -EvidencePath $tamperedReportPath
  } "nonClaims" "Provenance verification should fail when required non-claims are removed."

  $tamperedReportPath = Join-Path $tempRoot "tampered-attestation-sha.json"
  $tamperedReport = Get-Content -Raw -LiteralPath $readinessValidReportPath | ConvertFrom-Json
  $tamperedReport.attestation.readiness.subjectSha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  Write-JsonFile $tamperedReportPath $tamperedReport
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyProvenanceScript `
      -Target win32-x64 `
      -EvidencePath $tamperedReportPath
  } "subjectSha256" "Provenance verification should fail when attestation readiness drifts from the VSIX SHA256."

  $tamperedReportPath = Join-Path $tempRoot "tampered-attestation-path.json"
  $tamperedReport = Get-Content -Raw -LiteralPath $readinessValidReportPath | ConvertFrom-Json
  $tamperedReport.attestation.readiness.artifactPath = "target/vsix/wrong.vsix"
  Write-JsonFile $tamperedReportPath $tamperedReport
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyProvenanceScript `
      -Target win32-x64 `
      -EvidencePath $tamperedReportPath
  } "artifactPath" "Provenance verification should fail when attestation readiness drifts from the VSIX path."

  $tamperedReportPath = Join-Path $tempRoot "tampered-attestation-permissions.json"
  $tamperedReport = Get-Content -Raw -LiteralPath $readinessValidReportPath | ConvertFrom-Json
  $tamperedReport.attestation.readiness.PSObject.Properties.Remove("requiredPermissions")
  Write-JsonFile $tamperedReportPath $tamperedReport
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyProvenanceScript `
      -Target win32-x64 `
      -EvidencePath $tamperedReportPath
  } "requiredPermissions" "Provenance verification should fail when attestation readiness permissions are missing."

  $tamperedReportPath = Join-Path $tempRoot "tampered-attestation-status.json"
  $tamperedReport = Get-Content -Raw -LiteralPath $readinessValidReportPath | ConvertFrom-Json
  $tamperedReport.attestation.status = "generated"
  Write-JsonFile $tamperedReportPath $tamperedReport
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyProvenanceScript `
      -Target win32-x64 `
      -EvidencePath $tamperedReportPath
  } "not-generated" "Provenance verification should fail when the local preflight claims an attestation was generated."

  $tamperedReportPath = Join-Path $tempRoot "tampered-attestation-bundle.json"
  $tamperedReport = Get-Content -Raw -LiteralPath $readinessValidReportPath | ConvertFrom-Json
  $tamperedReport.attestation.readiness.bundleRecorded = $true
  $tamperedReport.attestation.readiness.verified = $true
  $tamperedReport.attestation.readiness | Add-Member -NotePropertyName "bundlePath" -NotePropertyValue "target/release-evidence/attestation.jsonl"
  $tamperedReport.attestation.readiness | Add-Member -NotePropertyName "attestationUrl" -NotePropertyValue "https://example.invalid/attestation"
  $tamperedReport.attestation.readiness | Add-Member -NotePropertyName "repositoryUrl" -NotePropertyValue "https://example.invalid/repo"
  Write-JsonFile $tamperedReportPath $tamperedReport
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyProvenanceScript `
      -Target win32-x64 `
      -EvidencePath $tamperedReportPath
  } "bundleRecorded" "Provenance verification should fail when local readiness records attestation bundles, URLs, or verification success."

  $packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  Assert-True ($packageJson.scripts."release:test-provenance-scripts".Contains("release-provenance-scripts.tests.ps1")) "Root package should expose provenance script tests."
  Assert-True ($packageJson.scripts."release:generate-provenance:win32-x64".Contains("generate-release-provenance.ps1")) "Root package should expose provenance generation."
  Assert-True ($packageJson.scripts."release:verify-provenance:win32-x64".Contains("verify-release-provenance.ps1")) "Root package should expose provenance verification."

  $ciWorkflow = Get-Content -Raw -LiteralPath $ciWorkflowPath
  Assert-ContainsInOrder $ciWorkflow @(
    "Release provenance script tests",
    "Generate source SBOM",
    "Generate third-party notices",
    "Verify release evidence",
    "Package VS Code win32-x64 VSIX",
    "Generate release provenance preflight",
    "Verify release provenance preflight"
  ) "CI should run M7j2a provenance preflight after the VSIX package exists."

  Write-Host "Release provenance preflight script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

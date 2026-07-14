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

  $vsixPath = Join-Path $artifactsRoot "subversionr-win32-x64-0.2.4.vsix"
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
        displayName = "SVN-R"
        version = "0.2.4"
        preRelease = $true
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
        relativePath = "target/tests/release-provenance-scripts/artifacts/subversionr-win32-x64-0.2.4.vsix"
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
          version = "0.2.4"
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
        displayName = "SVN-R"
        version = "0.2.4"
      }
      artifacts = @(
        [pscustomobject]@{
          role = "sidecar"
          path = "resources/backend/win32-x64/subversionr-daemon.exe"
          sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
        }
      )
    })

  $candidateAttestationContractPath = Join-Path $evidenceRoot "github-attestation-candidate-contract.win32-x64.json"
  Write-JsonFile $candidateAttestationContractPath ([pscustomobject]@{
      schemaVersion = 1
      schema = "subversionr.release.github-attestation-contract.win32-x64.v1"
      status = "pending-release-attestation"
      publicReadinessClaim = $false
      target = "win32-x64"
      release = [pscustomobject]@{
        tag = "v0.2.4-beta.1"
        url = "https://github.com/Hitsuki-Ban/SubversionR/releases/tag/v0.2.4-beta.1"
      }
      subject = [pscustomobject]@{
        name = "subversionr-win32-x64-0.2.4.vsix"
        size = (Get-Item -LiteralPath $vsixPath).Length
        sha256 = $vsixSha256
        preReleaseProperty = $true
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
    })

  $historicalVsixSha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  $historicalVsixSize = 12
  $attestationContractPath = Join-Path $evidenceRoot "github-attestation-contract.win32-x64.json"
  Write-JsonFile $attestationContractPath ([pscustomobject]@{
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
        size = $historicalVsixSize
        sha256 = $historicalVsixSha256
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
    })
  $attestationContractRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $attestationContractPath).Replace("\", "/")
  $signedPredicate = [pscustomobject]@{
    schemaVersion = 1
    schema = "subversionr.release.post-release-asset-verification-predicate.v1"
    claim = "post-release-asset-digest-verification"
    originalBuildProvenanceClaim = $false
    artifactSignatureClaim = $false
    release = [pscustomobject]@{
      tag = "v0.2.0-beta.1"
      url = "https://github.com/Hitsuki-Ban/SubversionR/releases/tag/v0.2.0-beta.1"
      assetName = "subversionr-win32-x64-0.2.0.vsix"
      assetSize = $historicalVsixSize
      assetSha256 = $historicalVsixSha256
    }
    contract = [pscustomobject]@{
      path = $attestationContractRelativePath
      sha256 = Get-Sha256 $attestationContractPath
    }
    verification = [pscustomobject]@{
      assetDownloadedFromRelease = $true
      subjectNameMatched = $true
      subjectSizeMatched = $true
      subjectSha256Matched = $true
    }
  }
  $attestationBundlePath = Join-Path $evidenceRoot "github-attestation-bundle.win32-x64.json"
  $attestationBundle = [pscustomobject]@{
    mediaType = "application/vnd.dev.sigstore.bundle.v0.3+json"
    verificationMaterial = [pscustomobject]@{ certificate = [pscustomobject]@{ rawBytes = "fixture" } }
    dsseEnvelope = [pscustomobject]@{ payloadType = "application/vnd.in-toto+json"; payload = "fixture"; signatures = @() }
  }
  Write-JsonFile $attestationBundlePath $attestationBundle
  $attestationBundleRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $attestationBundlePath).Replace("\", "/")
  $attestationVerificationPath = Join-Path $evidenceRoot "github-attestation-verification.win32-x64.json"
  Write-JsonFile $attestationVerificationPath @(
    [pscustomobject]@{
      attestation = [pscustomobject]@{ bundle = $attestationBundle }
      verificationResult = [pscustomobject]@{
        mediaType = "application/vnd.dev.sigstore.verificationresult+json;version=0.1"
        signature = [pscustomobject]@{
          certificate = [pscustomobject]@{
            subjectAlternativeName = "https://github.com/Hitsuki-Ban/SubversionR/.github/workflows/attest-release-vsix.yml@refs/heads/codex/test"
            githubWorkflowRepository = "Hitsuki-Ban/SubversionR"
            githubWorkflowTrigger = "workflow_dispatch"
            githubWorkflowSHA = "0123456789abcdef0123456789abcdef01234567"
            githubWorkflowRef = "refs/heads/codex/test"
            buildSignerDigest = "0123456789abcdef0123456789abcdef01234567"
            sourceRepositoryDigest = "0123456789abcdef0123456789abcdef01234567"
            runnerEnvironment = "github-hosted"
            sourceRepositoryVisibilityAtSigning = "public"
            runInvocationURI = "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/456/attempts/1"
          }
        }
        verifiedTimestamps = @([pscustomobject]@{ type = "Tlog"; uri = "https://rekor.sigstore.dev" })
        statement = [pscustomobject]@{
          subject = @([pscustomobject]@{ name = "subversionr-win32-x64-0.2.0.vsix"; digest = [pscustomobject]@{ sha256 = $historicalVsixSha256 } })
          predicateType = "https://github.com/Hitsuki-Ban/SubversionR/attestations/post-release-asset/v1"
          predicate = $signedPredicate
        }
      }
    }
  )
  $attestationVerificationRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $attestationVerificationPath).Replace("\", "/")
  $liveAttestationEvidencePath = Join-Path $evidenceRoot "github-attestation-evidence.win32-x64.json"
  $verificationCommand = "gh attestation verify target/release-attestation/win32-x64/subversionr-win32-x64-0.2.0.vsix -R Hitsuki-Ban/SubversionR --bundle $attestationBundleRelativePath --signer-workflow Hitsuki-Ban/SubversionR/.github/workflows/attest-release-vsix.yml --signer-digest 0123456789abcdef0123456789abcdef01234567 --source-ref refs/heads/codex/test --source-digest 0123456789abcdef0123456789abcdef01234567 --predicate-type https://github.com/Hitsuki-Ban/SubversionR/attestations/post-release-asset/v1 --deny-self-hosted-runners --format json"
  Write-JsonFile $liveAttestationEvidencePath ([pscustomobject]@{
      schemaVersion = 1
      schema = "subversionr.release.live-github-attestation.win32-x64.v1"
      publicReadinessClaim = $false
      signingClaim = $false
      target = "win32-x64"
      status = "live-attestation-verified"
      contract = [pscustomobject]@{
        path = $attestationContractRelativePath
        sha256 = Get-Sha256 $attestationContractPath
        schema = "subversionr.release.github-attestation-contract.win32-x64.v1"
      }
      release = [pscustomobject]@{
        tag = "v0.2.0-beta.1"
        url = "https://github.com/Hitsuki-Ban/SubversionR/releases/tag/v0.2.0-beta.1"
      }
      subject = [pscustomobject]@{
        name = "subversionr-win32-x64-0.2.0.vsix"
        path = "target/release-attestation/win32-x64/subversionr-win32-x64-0.2.0.vsix"
        size = $historicalVsixSize
        sha256 = $historicalVsixSha256
      }
      workflow = [pscustomobject]@{
        path = ".github/workflows/attest-release-vsix.yml"
        event = "workflow_dispatch"
        runId = "456"
        runAttempt = 1
        runUrl = "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/456"
        headSha = "0123456789abcdef0123456789abcdef01234567"
        sourceRef = "refs/heads/codex/test"
      }
      attestation = [pscustomobject]@{
        provider = "github-artifact-attestations"
        action = "actions/attest@v4"
        actionDigest = "a1948c3f048ba23858d222213b7c278aabede763"
        predicateType = "https://github.com/Hitsuki-Ban/SubversionR/attestations/post-release-asset/v1"
        predicateSchemaPath = "docs/release/post-release-asset-verification-predicate.v1.schema.json"
        predicateSchema = "subversionr.release.post-release-asset-verification-predicate.v1"
        predicateClaim = "post-release-asset-digest-verification"
        originalBuildProvenanceClaim = $false
        artifactSignatureClaim = $false
        id = "123"
        url = "https://github.com/Hitsuki-Ban/SubversionR/attestations/123"
        outputSource = "actions/attest outputs"
        bundlePath = $attestationBundleRelativePath
        bundleSha256 = Get-Sha256 $attestationBundlePath
      }
      verification = [pscustomobject]@{
        verified = $true
        repository = "Hitsuki-Ban/SubversionR"
        signerWorkflow = "Hitsuki-Ban/SubversionR/.github/workflows/attest-release-vsix.yml"
        predicateType = "https://github.com/Hitsuki-Ban/SubversionR/attestations/post-release-asset/v1"
        denySelfHostedRunners = $true
        format = "json"
        bundleMatched = $true
        command = $verificationCommand
        resultPath = $attestationVerificationRelativePath
        resultSha256 = Get-Sha256 $attestationVerificationPath
        certificate = [pscustomobject]@{
          signerIdentity = "https://github.com/Hitsuki-Ban/SubversionR/.github/workflows/attest-release-vsix.yml@refs/heads/codex/test"
          workflowSha = "0123456789abcdef0123456789abcdef01234567"
          workflowRef = "refs/heads/codex/test"
          runnerEnvironment = "github-hosted"
          runInvocationUrl = "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/456/attempts/1"
          sourceVisibility = "public"
        }
      }
    })

  [pscustomobject]@{
    vsixPath = $vsixPath
    vsixEvidencePath = $vsixEvidencePath
    sbomPath = $sbomPath
    noticePath = $noticePath
    backendManifestPath = $backendManifestPath
    candidateAttestationContractPath = $candidateAttestationContractPath
    attestationContractPath = $attestationContractPath
    attestationBundlePath = $attestationBundlePath
    attestationVerificationPath = $attestationVerificationPath
    liveAttestationEvidencePath = $liveAttestationEvidencePath
    outputPath = Join-Path $evidenceRoot "subversionr-marketplace-provenance-preflight-win32-x64.json"
  }
}

function Invoke-GenerateProvenance([object]$Fixture, [string]$OutputPath, [string]$Mode) {
  $modeArguments = @()
  if (-not [string]::IsNullOrEmpty($Mode)) {
    $modeArguments = @("-Mode", $Mode)
  }
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $generateProvenanceScript `
    @modeArguments `
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
    -CandidateAttestationContractPath $Fixture.candidateAttestationContractPath `
    -AttestationContractPath $Fixture.attestationContractPath `
    -LiveAttestationEvidencePath $Fixture.liveAttestationEvidencePath `
    -OutputPath $OutputPath
}

$tempRoot = Join-Path $repoRoot "target\tests\release-provenance-scripts\$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
$originalPath = $env:PATH

try {
  Assert-True (Test-Path -LiteralPath $generateProvenanceScript -PathType Leaf) "generate-release-provenance.ps1 should exist."
  Assert-True (Test-Path -LiteralPath $verifyProvenanceScript -PathType Leaf) "verify-release-provenance.ps1 should exist."
  Assert-True (Test-Path -LiteralPath (Join-Path $repoRoot "CHANGELOG.md") -PathType Leaf) "CHANGELOG.md should exist before Marketplace preflight."
  Assert-True (Test-Path -LiteralPath (Join-Path $repoRoot "SUPPORT.md") -PathType Leaf) "SUPPORT.md should exist before Marketplace preflight."
  $expectedMarketplaceIconSha256 = Get-Sha256 (Join-Path $repoRoot "packages\vscode-extension\resources\marketplace\icon.png")

  $fixture = New-ProvenanceFixture $tempRoot
  $ghShimRoot = Join-Path $tempRoot "gh-shim"
  New-Item -ItemType Directory -Force -Path $ghShimRoot | Out-Null
  $ghShimPath = Join-Path $ghShimRoot "gh.ps1"
  $escapedVerificationPath = $fixture.attestationVerificationPath.Replace("'", "''")
  @"
param([Parameter(ValueFromRemainingArguments = `$true)][string[]]`$Arguments)
Get-Content -Raw -LiteralPath '$escapedVerificationPath'
exit 0
"@ | Set-Content -LiteralPath $ghShimPath -Encoding utf8
  $env:PATH = "$ghShimRoot$([System.IO.Path]::PathSeparator)$originalPath"
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
  Assert-Equal "SVN-R" $report.extension.displayName "Provenance preflight should bind the Marketplace display name."
  Assert-Equal "True" ([string]$report.extension.preRelease) "Provenance preflight should record the pre-release package property."
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
  Assert-Equal "candidate-seal" ([string]$report.mode) "Provenance preflight should default to candidate-seal mode."
  Assert-Equal "asserted-exact-match" ([string]$report.candidateAttestation.subjectComparison) "Candidate-seal provenance should record the asserted exact contract subject comparison."
  Assert-Equal "pending-release-attestation" $report.candidateAttestation.status "Current candidate attestation should remain pending before release."
  Assert-Equal "current-candidate" $report.candidateAttestation.scope "Current candidate attestation should remain scoped to the candidate."
  Assert-Equal (Get-Sha256 $fixture.vsixPath) $report.candidateAttestation.subjectSha256 "Current candidate attestation should bind the exact candidate VSIX."
  Assert-Equal "subversionr-win32-x64-0.2.4.vsix" $report.candidateAttestation.subjectName "Current candidate attestation should bind the 0.2.4 VSIX name."
  Assert-Equal "True" ([string]$report.candidateAttestation.preReleaseProperty) "Current candidate attestation should require the VS Code pre-release property."
  Assert-Equal "False" ([string]$report.candidateAttestation.liveEvidenceRecorded) "Current candidate attestation must not claim live evidence before release."
  Assert-Equal "verified" $report.attestation.status "Provenance preflight should record the verified live attestation."
  Assert-Equal "historical-public-cutover-release" $report.attestation.scope "Verified live attestation should remain scoped to the historical public-cutover release."
  Assert-Equal "live-attestation-verified" $report.attestation.readiness.readinessStatus "Attestation readiness should record live verification."
  Assert-Equal "github-artifact-attestations" $report.attestation.readiness.provider "Attestation readiness should record the provider."
  Assert-Equal "actions/attest@v4" $report.attestation.readiness.action "Attestation readiness should record the issue #5 action contract."
  Assert-Equal "a1948c3f048ba23858d222213b7c278aabede763" $report.attestation.readiness.actionDigest "Attestation readiness should record the pinned action digest."
  Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/attestations/post-release-asset/v1" $report.attestation.readiness.predicateType "Attestation readiness should record the custom post-release verification predicate type."
  Assert-Equal "post-release-asset-digest-verification" $report.attestation.readiness.predicateClaim "Attestation readiness should record the signed post-release verification claim."
  Assert-Equal "False" ([string]$report.attestation.readiness.originalBuildProvenanceClaim) "Attestation readiness must preserve the signed original-build non-claim."
  Assert-Equal "False" ([string]$report.attestation.readiness.artifactSignatureClaim) "Attestation readiness must preserve the signed artifact-signature non-claim."
  Assert-Equal "subversionr-win32-x64-0.2.0.vsix" $report.attestation.readiness.subjectName "Attestation readiness should bind the VSIX file name."
  Assert-Equal "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" $report.attestation.readiness.subjectSha256 "Historical attestation readiness should retain its own VSIX SHA256."
  Assert-Equal "target/release-attestation/win32-x64/subversionr-win32-x64-0.2.0.vsix" $report.attestation.readiness.artifactPath "Historical attestation readiness should retain its own VSIX path."
  Assert-Equal 12 ([int64]$report.attestation.readiness.artifactSize) "Historical attestation readiness should retain its own VSIX size."
  Assert-Equal ".github/workflows/attest-release-vsix.yml" $report.attestation.readiness.workflowPath "Attestation readiness should record the live signer workflow path."
  Assert-Equal "True" ([string]$report.attestation.readiness.repoUrlRecorded) "Attestation readiness should record the public repository URL."
  Assert-Equal "True" ([string]$report.attestation.readiness.bundleRecorded) "Attestation readiness should record the bundle digest."
  Assert-Equal "True" ([string]$report.attestation.readiness.attestationUrlRecorded) "Attestation readiness should record the attestation URL."
  Assert-Equal "True" ([string]$report.attestation.readiness.verified) "Attestation readiness should record successful GitHub verification."
  Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/456" $report.attestation.readiness.runUrl "Attestation readiness should record the run URL."
  Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/attestations/123" $report.attestation.readiness.attestationUrl "Attestation readiness should record the attestation URL."
  Assert-Equal ([System.IO.Path]::GetRelativePath($repoRoot, $fixture.attestationBundlePath).Replace("\", "/")) $report.attestation.readiness.bundlePath "Attestation readiness should bind the exact bundle path."
  Assert-Equal (Get-Sha256 $fixture.attestationVerificationPath) $report.attestation.readiness.verificationResultSha256 "Attestation readiness should bind the exact verification-result bytes."
  foreach ($permission in @("id-token: write", "contents: read", "attestations: write")) {
    Assert-True (@($report.attestation.readiness.requiredPermissions | Where-Object { $_ -eq $permission }).Count -eq 1) "Attestation readiness should record required permission $permission."
  }
  Assert-True ($report.attestation.readiness.verificationCommand.Contains("--signer-workflow Hitsuki-Ban/SubversionR/.github/workflows/attest-release-vsix.yml")) "Attestation readiness verification command should pin the signer workflow."
  Assert-True ($report.attestation.readiness.verificationCommand.Contains("--bundle $($report.attestation.readiness.bundlePath)")) "Attestation readiness verification command should pin the exact bundle."
  Assert-True ($report.attestation.readiness.verificationCommand.Contains("--source-ref refs/heads/codex/test")) "Attestation readiness verification command should pin the source ref."
  Assert-True ($report.attestation.readiness.verificationCommand.Contains("--source-digest 0123456789abcdef0123456789abcdef01234567")) "Attestation readiness verification command should pin the source digest."
  Assert-True ($report.attestation.readiness.verificationCommand.Contains("--predicate-type https://github.com/Hitsuki-Ban/SubversionR/attestations/post-release-asset/v1")) "Attestation readiness verification command should pin the custom post-release verification predicate."
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
  Assert-Equal (Get-Sha256 $fixture.candidateAttestationContractPath) $report.evidence.candidateAttestationContract.sha256 "Provenance preflight should hash the pending candidate attestation contract."
  Assert-Equal (Get-Sha256 $fixture.attestationBundlePath) $report.evidence.attestationBundle.sha256 "Provenance preflight should hash the exact attestation bundle."
  Assert-Equal (Get-Sha256 $fixture.attestationVerificationPath) $report.evidence.attestationVerification.sha256 "Provenance preflight should hash the exact attestation verification result."
  foreach ($traceId in @("SEC-015", "MIG-009", "MIG-012")) {
    Assert-True (@($report.traceIds | Where-Object { $_ -eq $traceId }).Count -eq 1) "Provenance preflight should trace $traceId."
  }
  foreach ($nonClaim in @(
      "This gate does not prove VSIX signing.",
      "This gate records the current candidate attestation contract as pending; it does not claim current-candidate live attestation.",
      "This gate preserves historical GitHub artifact attestation publication and verification without applying it to the current candidate.",
      "The historical post-release attestation does not prove the current VSIX source-to-binary build provenance.",
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

  $staleContractFixture = New-ProvenanceFixture (Join-Path $tempRoot "stale-contract")
  $staleContract = Get-Content -Raw -LiteralPath $staleContractFixture.candidateAttestationContractPath | ConvertFrom-Json
  $staleContract.subject.sha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  Write-JsonFile $staleContractFixture.candidateAttestationContractPath $staleContract
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateProvenance -Fixture $staleContractFixture -OutputPath $staleContractFixture.outputPath
  } "Attestation subject SHA256" "Default candidate-seal provenance generation should fail when the frozen contract subject bytes are stale."
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateProvenance -Fixture $staleContractFixture -OutputPath $staleContractFixture.outputPath -Mode candidate-seal
  } "Attestation subject SHA256" "Explicit candidate-seal provenance generation should fail when the frozen contract subject bytes are stale."
  Invoke-GenerateProvenance -Fixture $staleContractFixture -OutputPath $staleContractFixture.outputPath -Mode continuous-validation
  if ($LASTEXITCODE -ne 0) {
    throw "generate-release-provenance.ps1 failed in continuous-validation mode with exit code $LASTEXITCODE."
  }
  $continuousReport = Get-Content -Raw -LiteralPath $staleContractFixture.outputPath | ConvertFrom-Json
  Assert-Equal "continuous-validation" ([string]$continuousReport.mode) "Continuous-validation provenance should record its mode."
  Assert-Equal "not-asserted-continuous-validation" ([string]$continuousReport.candidateAttestation.subjectComparison) "Continuous-validation provenance should record that frozen contract subject byte equality is not asserted."
  Assert-Equal "pending-release-attestation" ([string]$continuousReport.candidateAttestation.status) "Continuous-validation provenance should keep the pending candidate contract status assert."
  Assert-Equal (Get-Sha256 $staleContractFixture.vsixPath) ([string]$continuousReport.candidateAttestation.subjectSha256) "Continuous-validation provenance should still bind the exact current VSIX bytes."
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyProvenanceScript `
    -Target win32-x64 `
    -EvidencePath $staleContractFixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "verify-release-provenance.ps1 failed for continuous-validation evidence with exit code $LASTEXITCODE."
  }
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyProvenanceScript `
    -Target win32-x64 `
    -EvidencePath $staleContractFixture.outputPath `
    -ExpectedMode continuous-validation
  if ($LASTEXITCODE -ne 0) {
    throw "verify-release-provenance.ps1 failed for the matching -ExpectedMode continuous-validation with exit code $LASTEXITCODE."
  }
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyProvenanceScript `
      -Target win32-x64 `
      -EvidencePath $staleContractFixture.outputPath `
      -ExpectedMode candidate-seal
  } "must match the expected mode" "Provenance verification should fail when -ExpectedMode disagrees with the recorded mode."
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyProvenanceScript `
      -Target win32-x64 `
      -EvidencePath $staleContractFixture.outputPath `
      -ExpectedMode weakened
  } "ExpectedMode" "Provenance verification should reject -ExpectedMode values outside the documented mode set."

  $tamperedModeReportPath = Join-Path $tempRoot "tampered-mode-mismatch.json"
  $tamperedModeReport = Get-Content -Raw -LiteralPath $staleContractFixture.outputPath | ConvertFrom-Json
  $tamperedModeReport.mode = "candidate-seal"
  Write-JsonFile $tamperedModeReportPath $tamperedModeReport
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyProvenanceScript `
      -Target win32-x64 `
      -EvidencePath $tamperedModeReportPath
  } "subjectComparison" "Provenance verification should fail when the recorded mode disagrees with subjectComparison."

  $tamperedModeReportPath = Join-Path $tempRoot "tampered-mode-invalid.json"
  $tamperedModeReport = Get-Content -Raw -LiteralPath $staleContractFixture.outputPath | ConvertFrom-Json
  $tamperedModeReport.mode = "weakened"
  Write-JsonFile $tamperedModeReportPath $tamperedModeReport
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyProvenanceScript `
      -Target win32-x64 `
      -EvidencePath $tamperedModeReportPath
  } "Provenance report mode" "Provenance verification should reject recorded modes outside the documented mode set."

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
    candidateAttestationContractPath = $fixture.candidateAttestationContractPath
    attestationContractPath = $fixture.attestationContractPath
    liveAttestationEvidencePath = $fixture.liveAttestationEvidencePath
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
    candidateAttestationContractPath = $fixture.candidateAttestationContractPath
    attestationContractPath = $fixture.attestationContractPath
    liveAttestationEvidencePath = $fixture.liveAttestationEvidencePath
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
        -CandidateAttestationContractPath $fixture.candidateAttestationContractPath `
        -AttestationContractPath $fixture.attestationContractPath `
        -LiveAttestationEvidencePath $fixture.liveAttestationEvidencePath `
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
      -CandidateAttestationContractPath $fixture.candidateAttestationContractPath `
      -AttestationContractPath $fixture.attestationContractPath `
      -LiveAttestationEvidencePath $fixture.liveAttestationEvidencePath `
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
      -CandidateAttestationContractPath $fixture.candidateAttestationContractPath `
      -AttestationContractPath $fixture.attestationContractPath `
      -LiveAttestationEvidencePath $fixture.liveAttestationEvidencePath `
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
  $tamperedReport.nonClaims = @($tamperedReport.nonClaims | Where-Object { $_ -ne "This gate records the current candidate attestation contract as pending; it does not claim current-candidate live attestation." })
  Write-JsonFile $tamperedReportPath $tamperedReport
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyProvenanceScript `
      -Target win32-x64 `
      -EvidencePath $tamperedReportPath
  } "nonClaims" "Provenance verification should fail when required non-claims are removed."

  $tamperedReportPath = Join-Path $tempRoot "tampered-attestation-sha.json"
  $tamperedReport = Get-Content -Raw -LiteralPath $readinessValidReportPath | ConvertFrom-Json
  $tamperedReport.candidateAttestation.subjectSha256 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  Write-JsonFile $tamperedReportPath $tamperedReport
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyProvenanceScript `
      -Target win32-x64 `
      -EvidencePath $tamperedReportPath
  } "Candidate attestation SHA256" "Provenance verification should fail when candidate attestation drifts from the current VSIX SHA256."

  $tamperedReportPath = Join-Path $tempRoot "tampered-attestation-path.json"
  $tamperedReport = Get-Content -Raw -LiteralPath $readinessValidReportPath | ConvertFrom-Json
  $tamperedReport.candidateAttestation.subjectName = "wrong.vsix"
  Write-JsonFile $tamperedReportPath $tamperedReport
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyProvenanceScript `
      -Target win32-x64 `
      -EvidencePath $tamperedReportPath
  } "Candidate attestation subject name" "Provenance verification should fail when candidate attestation drifts from the current VSIX name."

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
  $tamperedReport.attestation.status = "not-generated"
  Write-JsonFile $tamperedReportPath $tamperedReport
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyProvenanceScript `
      -Target win32-x64 `
      -EvidencePath $tamperedReportPath
  } "live verification" "Provenance verification should fail when live attestation status is removed."

  $tamperedReportPath = Join-Path $tempRoot "tampered-attestation-bundle.json"
  $tamperedReport = Get-Content -Raw -LiteralPath $readinessValidReportPath | ConvertFrom-Json
  $tamperedReport.attestation.readiness.bundleRecorded = $false
  $tamperedReport.attestation.readiness.verified = $false
  Write-JsonFile $tamperedReportPath $tamperedReport
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyProvenanceScript `
      -Target win32-x64 `
      -EvidencePath $tamperedReportPath
  } "must be true" "Provenance verification should fail when live attestation bundle or verification records are removed."

  $packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  Assert-True ($packageJson.scripts."release:test-provenance-scripts".Contains("release-provenance-scripts.tests.ps1")) "Root package should expose provenance script tests."
  Assert-True ($packageJson.scripts."release:generate-provenance:win32-x64".Contains("generate-release-provenance.ps1")) "Root package should expose provenance generation."
  Assert-True ($packageJson.scripts."release:generate-provenance:win32-x64".Contains("-CandidateAttestationContractPath docs/release/github-attestation-candidate-contract.win32-x64.json")) "Root package should pass the pending candidate attestation contract explicitly."
  Assert-True ($packageJson.scripts."release:generate-provenance:win32-x64".Contains("-AttestationContractPath docs/release/github-attestation-contract.win32-x64.json")) "Root package should pass the attestation contract explicitly."
  Assert-True ($packageJson.scripts."release:generate-provenance:win32-x64".Contains("-LiveAttestationEvidencePath docs/release/github-attestation-evidence.win32-x64.json")) "Root package should pass live attestation evidence explicitly."
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
  Assert-True ($ciWorkflow.Contains("candidate_seal:")) "CI workflow_dispatch should expose the candidate_seal input."
  Assert-True ($ciWorkflow.Contains("Run in frozen candidate-seal mode (exact-byte contract matching)")) "CI candidate_seal input should document the frozen candidate-seal mode."
  Assert-True ($ciWorkflow.Contains('SUBVERSIONR_RELEASE_CI_MODE: ${{ github.event_name == ''workflow_dispatch'' && inputs.candidate_seal == true && ''candidate-seal'' || ''continuous-validation'' }}')) "CI should compute the release provenance mode once from the candidate_seal dispatch input with a schedule-safe expression."
  Assert-True ($ciWorkflow.Contains('pnpm release:generate-provenance:win32-x64 -Mode $env:SUBVERSIONR_RELEASE_CI_MODE')) "CI should pass the computed mode explicitly to provenance generation."
  Assert-True ($ciWorkflow.Contains('pnpm release:verify-provenance:win32-x64 -ExpectedMode $env:SUBVERSIONR_RELEASE_CI_MODE')) "CI should require provenance verification to match the computed mode."
  $candidateSealStepCondition = "if: `${{ env.SUBVERSIONR_RELEASE_CI_MODE == 'candidate-seal' }}"
  Assert-Equal 3 ([regex]::Matches($ciWorkflow, [regex]::Escape($candidateSealStepCondition))).Count "CI should apply the explicit candidate-seal condition only to candidate manifest generation, verification, and upload."
  Assert-ContainsInOrder $ciWorkflow @(
    "Test installed VSIX Source Control UI E2E",
    "Generate Beta artifact bundle manifest",
    "Verify Beta candidate evidence consistency",
    "Rust native bridge integration test",
    "Upload Beta candidate VSIX and evidence bundle"
  ) "Continuous validation should retain installed/native gates while candidate-only steps remain sealed."

  Write-Host "Release provenance preflight script tests passed."
}
finally {
  $env:PATH = $originalPath
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

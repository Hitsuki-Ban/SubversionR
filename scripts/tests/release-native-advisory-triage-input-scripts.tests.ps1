$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$generateScript = Join-Path $repoRoot "scripts\release\generate-native-advisory-triage-input.ps1"
$verifyScript = Join-Path $repoRoot "scripts\release\verify-native-advisory-triage-input.ps1"
$packageJsonPath = Join-Path $repoRoot "package.json"
$ciWorkflowPath = Join-Path $repoRoot ".github\workflows\ci.yml"
$readinessVerifierPath = Join-Path $repoRoot "scripts\release\verify-readiness.ps1"

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

function Get-RepoRelativePath([string]$Path) {
  [System.IO.Path]::GetRelativePath($repoRoot, $Path).Replace("\", "/")
}

function Write-JsonFile([string]$Path, [object]$Value) {
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $Value | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $Path -Encoding utf8
}

function New-FixtureDigest([string]$Seed) {
  $bytes = [Text.Encoding]::UTF8.GetBytes($Seed)
  $sha = [Security.Cryptography.SHA256]::HashData($bytes)
  -join ($sha | ForEach-Object { $_.ToString("x2") })
}

function New-NativeTriageInputFixture([string]$Root, [int]$FindingCount = 1) {
  $evidenceRoot = Join-Path $Root "evidence"
  New-Item -ItemType Directory -Force -Path $evidenceRoot | Out-Null

  $now = [DateTime]::UtcNow
  $opensslDigest = New-FixtureDigest "openssl-source"
  $zlibDigest = New-FixtureDigest "zlib-source"
  $findings = @()
  if ($FindingCount -eq 1) {
    $findings = @(
      [pscustomobject]@{
        id = "GHSA-test-one"
        affectedPurls = @("pkg:npm/example@1.0.0")
        triageStatus = "pending"
        remediationDecision = "pending"
        vexDecision = "pending"
      }
    )
  } elseif ($FindingCount -ne 0) {
    throw "Fixture supports FindingCount 0 or 1."
  }

  $liveOsvPath = Join-Path $evidenceRoot "subversionr-live-osv-vulnerability-review-win32-x64.json"
  Write-JsonFile $liveOsvPath ([pscustomobject]@{
      schemaVersion = 1
      schema = "subversionr.release.vulnerability-review-osv.win32-x64.v1"
      publicReadinessClaim = $false
      vulnerabilityReviewComplete = $false
      liveOsvEvidence = $true
      target = "win32-x64"
      traceIds = @("SEC-015", "MIG-012", "TST-024")
      generatedAt = $now.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
      osv = [pscustomobject]@{
        status = "queried"
        liveQueryPerformed = $true
        resultRecorded = $true
        positiveControl = [pscustomobject]@{ status = "passed"; vulnerabilityCount = 1; vulnerabilityIds = @("GHSA-positive-control") }
      }
      manualReview = [pscustomobject]@{
        status = "required"
        releaseBlocking = $true
        componentCount = 2
      }
      review = [pscustomobject]@{
        status = "requires-triage"
        triageComplete = $false
        remediationApproved = $false
        vexDecisionsComplete = $false
        findingCount = $FindingCount
        findings = $findings
      }
    })

  $nativeAdvisoryPath = Join-Path $evidenceRoot "subversionr-native-advisory-review-win32-x64.json"
  Write-JsonFile $nativeAdvisoryPath ([pscustomobject]@{
      schemaVersion = 1
      schema = "subversionr.release.native-advisory-review.win32-x64.v1"
      publicReadinessClaim = $false
      vulnerabilityReviewComplete = $false
      nativeAdvisoryReviewComplete = $false
      target = "win32-x64"
      traceIds = @("SEC-015", "MIG-012", "TST-024")
      generatedAt = $now.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
      evidence = [pscustomobject]@{
        sourceLock = [pscustomobject]@{ path = "fixture/sources.lock.json"; sha256 = New-FixtureDigest "source-lock"; componentCount = 2 }
        liveOsv = [pscustomobject]@{
          path = Get-RepoRelativePath $liveOsvPath
          sha256 = Get-Sha256 $liveOsvPath
          schema = "subversionr.release.vulnerability-review-osv.win32-x64.v1"
          maxAgeDays = 7
          fresh = $true
          findingCount = $FindingCount
          manualReviewComponentCount = 2
        }
        advisorySources = [pscustomobject]@{ path = "fixture/native-advisory-sources.lock.json"; sha256 = New-FixtureDigest "advisory-sources"; schema = "subversionr.security.native-advisory-sources.v1"; componentCount = 2 }
      }
      nativeReview = [pscustomobject]@{
        status = "required"
        releaseBlocking = $true
        sourceContractComplete = $true
        componentCount = 2
        components = @(
          [pscustomobject]@{
            name = "openssl"
            displayName = "OpenSSL"
            version = "3.5.7"
            sourceDigest = [pscustomobject]@{ sha256 = $opensslDigest }
            advisorySources = @(
              [pscustomobject]@{ id = "openssl-vulnerabilities"; url = "https://openssl-library.org/news/vulnerabilities/" },
              [pscustomobject]@{ id = "openssl-security-policy"; url = "https://openssl-library.org/policies/general/security-policy/" }
            )
            reviewStatus = "pending"
            releaseBlocking = $true
            triageStatus = "pending"
            remediationDecision = "pending"
            vexDecision = "pending"
          },
          [pscustomobject]@{
            name = "zlib"
            displayName = "zlib"
            version = "1.3.2"
            sourceDigest = [pscustomobject]@{ sha256 = $zlibDigest }
            advisorySources = @(
              [pscustomobject]@{ id = "zlib-github-security"; url = "https://github.com/madler/zlib/security" },
              [pscustomobject]@{ id = "zlib-release-notes"; url = "https://github.com/madler/zlib/releases/tag/v1.3.2" }
            )
            reviewStatus = "pending"
            releaseBlocking = $true
            triageStatus = "pending"
            remediationDecision = "pending"
            vexDecision = "pending"
          }
        )
      }
      review = [pscustomobject]@{
        status = "requires-native-advisory-review"
        triageComplete = $false
        remediationApproved = $false
        vexDecisionsComplete = $false
        findingCount = $FindingCount
      }
    })

  [pscustomobject]@{
    nativeAdvisoryPath = $nativeAdvisoryPath
    liveOsvPath = $liveOsvPath
    outputPath = Join-Path $evidenceRoot "subversionr-native-advisory-triage-input-win32-x64.json"
  }
}

$tempId = [Guid]::NewGuid().ToString('N')
$tempRoot = Join-Path $repoRoot "target\tests\release-native-advisory-triage-input-scripts\$tempId"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  Assert-True (Test-Path -LiteralPath $generateScript -PathType Leaf) "generate-native-advisory-triage-input.ps1 should exist."
  Assert-True (Test-Path -LiteralPath $verifyScript -PathType Leaf) "verify-native-advisory-triage-input.ps1 should exist."

  $fixture = New-NativeTriageInputFixture $tempRoot
  $zeroFindingFixture = New-NativeTriageInputFixture (Join-Path $tempRoot "zero-findings") 0

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $generateScript `
    -Target win32-x64 `
    -NativeAdvisoryEvidencePath $fixture.nativeAdvisoryPath `
    -OutputPath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "generate-native-advisory-triage-input.ps1 failed with exit code $LASTEXITCODE."
  }

  $report = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  Assert-Equal "subversionr.release.native-advisory-triage-input.win32-x64.v1" $report.schema "Native advisory triage input should use the M7l2c schema."
  Assert-Equal "False" ([string]$report.publicReadinessClaim) "Native advisory triage input must not claim public readiness."
  Assert-Equal "False" ([string]$report.vulnerabilityReviewComplete) "Native advisory triage input must not claim full vulnerability review completion."
  Assert-Equal "False" ([string]$report.nativeAdvisoryReviewComplete) "Native advisory triage input must not claim native advisory completion."
  Assert-Equal "False" ([string]$report.triageComplete) "Native advisory triage input must not claim triage completion."
  Assert-Equal "False" ([string]$report.remediationApproved) "Native advisory triage input must not claim remediation approval."
  Assert-Equal "False" ([string]$report.vexDecisionsComplete) "Native advisory triage input must not claim VEX completion."
  Assert-Equal "required" ([string]$report.triageInput.status) "Native advisory triage input should remain required."
  Assert-Equal "True" ([string]$report.triageInput.releaseBlocking) "Native advisory triage input should remain release-blocking."
  Assert-Equal 2 ([int]$report.triageInput.nativeComponentRowCount) "Fixture should record two native component rows."
  Assert-Equal 1 ([int]$report.triageInput.osvFindingRowCount) "Fixture should carry forward one live OSV finding row."
  Assert-Equal 3 ([int]$report.triageInput.totalRowCount) "Fixture should record all triage input rows."
  Assert-Equal (Get-Sha256 $fixture.nativeAdvisoryPath) $report.evidence.nativeAdvisory.sha256 "Native triage input should bind native advisory evidence SHA256."
  Assert-Equal (Get-Sha256 $fixture.liveOsvPath) $report.evidence.liveOsv.sha256 "Native triage input should bind live OSV evidence SHA256."
  Assert-Equal 7 ([int]$report.evidence.nativeAdvisory.maxAgeDays) "Native triage input should enforce M7l2b evidence freshness."

  $nativeRow = @($report.triageInput.rows | Where-Object { $_.kind -eq "native-component" -and $_.componentName -eq "openssl" })[0]
  Assert-Equal "native:openssl@3.5.7" ([string]$nativeRow.key) "Native component row key should be stable."
  Assert-Equal "required" ([string]$nativeRow.requiredInputs.triageStatus) "Native component row should require triage input."
  Assert-Equal "required-before-approval" ([string]$nativeRow.requiredInputs.analysisEvidence) "Native component row should require analysis evidence before approval."
  Assert-Equal "pending" ([string]$nativeRow.currentStatus.triageStatus) "Native component row should remain pending."
  Assert-Equal "True" ([string]$nativeRow.releaseBlocking) "Native component row should remain release-blocking."

  $osvRow = @($report.triageInput.rows | Where-Object { $_.kind -eq "osv-finding" -and $_.findingId -eq "GHSA-test-one" })[0]
  Assert-Equal "osv:GHSA-test-one" ([string]$osvRow.key) "OSV finding row key should be stable."
  Assert-Equal "pending" ([string]$osvRow.currentStatus.vexDecision) "OSV finding row should keep VEX pending."

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
    -Target win32-x64 `
    -EvidencePath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "verify-native-advisory-triage-input.ps1 failed with exit code $LASTEXITCODE."
  }

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $generateScript `
    -Target win32-x64 `
    -NativeAdvisoryEvidencePath $zeroFindingFixture.nativeAdvisoryPath `
    -OutputPath $zeroFindingFixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "generate-native-advisory-triage-input.ps1 failed for zero-finding fixture with exit code $LASTEXITCODE."
  }

  $zeroFindingReport = Get-Content -Raw -LiteralPath $zeroFindingFixture.outputPath | ConvertFrom-Json
  Assert-Equal 2 ([int]$zeroFindingReport.triageInput.nativeComponentRowCount) "Zero-finding fixture should still record native component rows."
  Assert-Equal 0 ([int]$zeroFindingReport.triageInput.osvFindingRowCount) "Zero-finding fixture should record zero OSV finding rows."
  Assert-Equal 2 ([int]$zeroFindingReport.triageInput.totalRowCount) "Zero-finding fixture should record only native component rows."

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
    -Target win32-x64 `
    -EvidencePath $zeroFindingFixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "verify-native-advisory-triage-input.ps1 failed for zero-finding fixture with exit code $LASTEXITCODE."
  }

  $badOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "subversionr-native-advisory-triage-input-outside-target.json"
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $generateScript `
      -Target win32-x64 `
      -NativeAdvisoryEvidencePath $fixture.nativeAdvisoryPath `
      -OutputPath $badOutputPath
  } "OutputPath must resolve inside" "Native advisory triage input generation should reject output paths outside target."

  $staleEvidencePath = Join-Path $tempRoot "stale-native-advisory.json"
  $staleEvidence = Get-Content -Raw -LiteralPath $fixture.nativeAdvisoryPath | ConvertFrom-Json
  $staleEvidence.generatedAt = ([DateTime]::UtcNow.AddDays(-8)).ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
  Write-JsonFile $staleEvidencePath $staleEvidence
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $generateScript `
      -Target win32-x64 `
      -NativeAdvisoryEvidencePath $staleEvidencePath `
      -OutputPath (Join-Path $tempRoot "evidence\stale-native-output.json")
  } "Native advisory evidence is older than" "Native advisory triage input should reject stale M7l2b evidence."

  $tamperedPath = Join-Path $tempRoot "tampered-missing-row.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tampered.triageInput.rows = @($tampered.triageInput.rows | Where-Object { $_.key -ne "native:zlib@1.3.2" })
  Write-JsonFile $tamperedPath $tampered
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript -Target win32-x64 -EvidencePath $tamperedPath
  } "Missing native advisory triage input rows" "Native advisory triage input verification should reject missing rows."

  $tamperedPath = Join-Path $tempRoot "tampered-extra-row.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tampered.triageInput.rows += [pscustomobject]@{ kind = "native-component"; key = "native:extra@0.0.0"; componentName = "extra"; version = "0.0.0" }
  Write-JsonFile $tamperedPath $tampered
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript -Target win32-x64 -EvidencePath $tamperedPath
  } "Unexpected native advisory triage input rows" "Native advisory triage input verification should reject extra rows."

  $tamperedPath = Join-Path $tempRoot "tampered-complete.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tampered.publicReadinessClaim = $true
  $tampered.vulnerabilityReviewComplete = $true
  $tampered.nativeAdvisoryReviewComplete = $true
  $tampered.triageComplete = $true
  $tampered.remediationApproved = $true
  $tampered.vexDecisionsComplete = $true
  $tampered.triageInput.releaseBlocking = $false
  Write-JsonFile $tamperedPath $tampered
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript -Target win32-x64 -EvidencePath $tamperedPath
  } "publicReadinessClaim" "Native advisory triage input verification should reject completion/readiness overclaims."

  $tamperedPath = Join-Path $tempRoot "tampered-native-hash.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tampered.evidence.nativeAdvisory.sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  Write-JsonFile $tamperedPath $tampered
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript -Target win32-x64 -EvidencePath $tamperedPath
  } "Native advisory evidence SHA256" "Native advisory triage input verification should reject native advisory hash drift."

  $tamperedPath = Join-Path $tempRoot "tampered-secret.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath
  $tampered = $tampered -replace '"reviewQueue": "native-advisory"', '"reviewQueue": "Authorization: Bearer fake-token"'
  Set-Content -LiteralPath $tamperedPath -Value $tampered -Encoding utf8
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript -Target win32-x64 -EvidencePath $tamperedPath
  } "must not record credentials" "Native advisory triage input verification should reject credential-like evidence text."

  $packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  Assert-True ($packageJson.scripts."release:test-native-advisory-triage-input-scripts".Contains("release-native-advisory-triage-input-scripts.tests.ps1")) "Root package should expose native advisory triage input script tests."
  Assert-True ($packageJson.scripts."release:generate-native-advisory-triage-input:win32-x64".Contains("generate-native-advisory-triage-input.ps1")) "Root package should expose native advisory triage input generation."
  Assert-True ($packageJson.scripts."release:verify-native-advisory-triage-input:win32-x64".Contains("verify-native-advisory-triage-input.ps1")) "Root package should expose native advisory triage input verification."

  $ciWorkflow = Get-Content -Raw -LiteralPath $ciWorkflowPath
  Assert-ContainsInOrder $ciWorkflow @(
    "Release native advisory review script tests",
    "Release native advisory triage input script tests",
    "Generate native advisory review",
    "Verify native advisory review",
    "Generate native advisory triage input",
    "Verify native advisory triage input"
  ) "CI should run native advisory triage input tests and the gate after M7l2b."

  $readinessVerifier = Get-Content -Raw -LiteralPath $readinessVerifierPath
  foreach ($term in @(
      "M7l2c native advisory triage input-contract gate",
      "subversionr.release.native-advisory-triage-input.win32-x64.v1",
      "pnpm release:test-native-advisory-triage-input-scripts",
      "pnpm release:generate-native-advisory-triage-input:win32-x64",
      "pnpm release:verify-native-advisory-triage-input:win32-x64"
    )) {
    Assert-True ($readinessVerifier.Contains($term)) "Release readiness verifier should require '$term'."
  }

  Write-Host "Release native advisory triage input script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

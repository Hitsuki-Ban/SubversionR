$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$generateScript = Join-Path $repoRoot "scripts\release\generate-native-advisory-review.ps1"
$verifyScript = Join-Path $repoRoot "scripts\release\verify-native-advisory-review.ps1"
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

function Write-JsonFile([string]$Path, [object]$Value) {
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $Value | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $Path -Encoding utf8
}

function New-NativeAdvisoryFixture([string]$Root) {
  $evidenceRoot = Join-Path $Root "evidence"
  New-Item -ItemType Directory -Force -Path $evidenceRoot | Out-Null

  $sourceLockPath = Join-Path $Root "sources.lock.json"
  Write-JsonFile $sourceLockPath ([pscustomobject]@{
      sources = @(
        [pscustomobject]@{
          name = "openssl"
          version = "3.5.7"
          license = "Apache-2.0"
          licenseUrl = "https://openssl-library.org/source/license/"
          url = "https://github.com/openssl/openssl/releases/download/openssl-3.5.7/openssl-3.5.7.tar.gz"
          sha512 = "de5351d2d532e1a3908a738f7d8aae448d32bc60bdb24808c556a24bc37a3f53daedf12b5d432eeb8c235e16939d842f908332ede8a447ca103ad1c493c820d7"
          sha256 = "a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8"
        },
        [pscustomobject]@{
          name = "zlib"
          version = "1.3.2"
          license = "Zlib"
          licenseUrl = "https://github.com/madler/zlib/blob/v1.3.2/LICENSE"
          url = "https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.gz"
          sha512 = "70963771ea5d763614278a69b474f09b7d237ef8f53b675a10fe31d9923aeef601504b35d7ebd1b1e7f347e9ebb048e6b3b47fffdf137e7bdc7e8d5eb4ec4692"
        }
      )
    })

  $advisorySourcesPath = Join-Path $Root "native-advisory-sources.lock.json"
  Write-JsonFile $advisorySourcesPath ([pscustomobject]@{
      schemaVersion = 1
      schema = "subversionr.security.native-advisory-sources.v1"
      capturedAt = "2026-06-25"
      components = @(
        [pscustomobject]@{
          name = "openssl"
          displayName = "OpenSSL"
          primaryAuthority = "OpenSSL project"
          dedicatedAdvisoryIndex = $true
          reviewLimitation = "Release review must still check current OpenSSL 3.5 vulnerability entries and policy scope."
          advisorySources = @(
            [pscustomobject]@{
              id = "openssl-vulnerabilities"
              type = "vendor-vulnerability-index"
              authority = "vendor"
              url = "https://openssl-library.org/news/vulnerabilities/"
              purpose = "OpenSSL vulnerability index and advisory links."
            },
            [pscustomobject]@{
              id = "openssl-security-policy"
              type = "vendor-security-policy"
              authority = "vendor"
              url = "https://openssl-library.org/policies/general/security-policy/"
              purpose = "OpenSSL issue severity and handling policy."
            }
          )
        },
        [pscustomobject]@{
          name = "zlib"
          displayName = "zlib"
          primaryAuthority = "zlib project"
          dedicatedAdvisoryIndex = $false
          reviewLimitation = "The project security page has no published advisory feed; release review must remain manual and blocking."
          advisorySources = @(
            [pscustomobject]@{
              id = "zlib-github-security"
              type = "github-security-overview"
              authority = "github-security"
              url = "https://github.com/madler/zlib/security"
              purpose = "Project GitHub security overview records lack of published advisories/policy."
            },
            [pscustomobject]@{
              id = "zlib-release-notes"
              type = "project-release-notes"
              authority = "project"
              url = "https://github.com/madler/zlib/releases/tag/v1.3.2"
              purpose = "Project release notes for the locked source version."
            },
            [pscustomobject]@{
              id = "zlib-nvd-keyword"
              type = "cve-database-keyword-search"
              authority = "nvd"
              url = "https://services.nvd.nist.gov/rest/json/cves/2.0?keywordSearch=zlib"
              purpose = "NVD keyword-search fixture source."
            },
            [pscustomobject]@{
              id = "zlib-osv-query"
              type = "vulnerability-database-query"
              authority = "osv"
              url = "https://api.osv.dev/v1/query"
              purpose = "OSV query fixture source."
            }
          )
        }
      )
    })

  $liveOsvPath = Join-Path $evidenceRoot "subversionr-live-osv-vulnerability-review-win32-x64.json"
  Write-JsonFile $liveOsvPath ([pscustomobject]@{
      schemaVersion = 1
      schema = "subversionr.release.vulnerability-review-osv.win32-x64.v1"
      publicReadinessClaim = $false
      vulnerabilityReviewComplete = $false
      liveOsvEvidence = $true
      target = "win32-x64"
      traceIds = @("SEC-015", "MIG-012", "TST-024")
      generatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
      osv = [pscustomobject]@{
        status = "queried"
        liveQueryPerformed = $true
        resultRecorded = $true
        queriedComponentCount = 2
        vulnerabilityIdCount = 1
        detailCount = 1
        positiveControl = [pscustomobject]@{
          status = "passed"
          vulnerabilityCount = 1
          vulnerabilityIds = @("GHSA-positive-control")
        }
      }
      manualReview = [pscustomobject]@{
        status = "required"
        releaseBlocking = $true
        componentCount = 2
        components = @(
          [pscustomobject]@{ name = "openssl"; version = "3.5.7"; reason = "Native source-lock review remains required." },
          [pscustomobject]@{ name = "zlib"; version = "1.3.2"; reason = "Native source-lock review remains required." }
        )
      }
      review = [pscustomobject]@{
        status = "requires-triage"
        triageComplete = $false
        remediationApproved = $false
        vexDecisionsComplete = $false
        findingCount = 1
        findings = @(
          [pscustomobject]@{
            id = "GHSA-test-one"
            affectedPurls = @("pkg:npm/example@1.0.0")
            triageStatus = "pending"
            remediationDecision = "pending"
            vexDecision = "pending"
          }
        )
      }
    })

  [pscustomobject]@{
    sourceLockPath = $sourceLockPath
    advisorySourcesPath = $advisorySourcesPath
    liveOsvPath = $liveOsvPath
    outputPath = Join-Path $evidenceRoot "subversionr-native-advisory-review-win32-x64.json"
  }
}

$tempId = [Guid]::NewGuid().ToString('N')
$tempRoot = Join-Path $repoRoot "target\tests\release-native-advisory-review-scripts\$tempId"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  Assert-True (Test-Path -LiteralPath $generateScript -PathType Leaf) "generate-native-advisory-review.ps1 should exist."
  Assert-True (Test-Path -LiteralPath $verifyScript -PathType Leaf) "verify-native-advisory-review.ps1 should exist."

  $fixture = New-NativeAdvisoryFixture $tempRoot

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $generateScript `
    -Target win32-x64 `
    -SourceLockPath $fixture.sourceLockPath `
    -LiveOsvEvidencePath $fixture.liveOsvPath `
    -AdvisorySourcesPath $fixture.advisorySourcesPath `
    -OutputPath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "generate-native-advisory-review.ps1 failed with exit code $LASTEXITCODE."
  }

  $report = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  Assert-Equal "subversionr.release.native-advisory-review.win32-x64.v1" $report.schema "Native advisory review should use the M7l2b schema."
  Assert-Equal "False" ([string]$report.publicReadinessClaim) "Native advisory review must not claim public readiness."
  Assert-Equal "False" ([string]$report.vulnerabilityReviewComplete) "Native advisory review must not claim full vulnerability review completion."
  Assert-Equal "False" ([string]$report.nativeAdvisoryReviewComplete) "Native advisory review must not claim native advisory completion."
  Assert-Equal "required" ([string]$report.nativeReview.status) "Native advisory review should remain required."
  Assert-Equal "True" ([string]$report.nativeReview.releaseBlocking) "Native advisory review should stay release-blocking."
  Assert-Equal "True" ([string]$report.nativeReview.sourceContractComplete) "Every native source-lock component should have an advisory source contract."
  Assert-Equal 2 ([int]$report.nativeReview.componentCount) "Fixture should record two native components."
  Assert-Equal 2 @($report.nativeReview.components).Count "Fixture should record two native component review records."
  Assert-Equal (Get-Sha256 $fixture.sourceLockPath) $report.evidence.sourceLock.sha256 "Native advisory review should bind the source lock SHA256."
  Assert-Equal (Get-Sha256 $fixture.liveOsvPath) $report.evidence.liveOsv.sha256 "Native advisory review should bind the live OSV evidence SHA256."
  Assert-Equal (Get-Sha256 $fixture.advisorySourcesPath) $report.evidence.advisorySources.sha256 "Native advisory review should bind the advisory source contract SHA256."
  Assert-Equal 7 ([int]$report.evidence.liveOsv.maxAgeDays) "Native advisory review should enforce live OSV evidence freshness."

  $zlibRecord = @($report.nativeReview.components | Where-Object { $_.name -eq "zlib" })[0]
  Assert-Equal "False" ([string]$zlibRecord.dedicatedAdvisoryIndex) "zlib fixture should preserve the no-dedicated-feed limitation."
  Assert-Equal "pending" ([string]$zlibRecord.reviewStatus) "Native component review status should remain pending."
  Assert-Equal "pending" ([string]$zlibRecord.triageStatus) "Native component triage status should remain pending."
  Assert-Equal "pending" ([string]$zlibRecord.remediationDecision) "Native component remediation decision should remain pending."
  Assert-Equal "pending" ([string]$zlibRecord.vexDecision) "Native component VEX decision should remain pending."
  Assert-True (@($zlibRecord.advisorySources | Where-Object { [string]$_.authority -eq "nvd" }).Count -eq 1) "Native advisory review should preserve NVD authority sources."
  Assert-True (@($zlibRecord.advisorySources | Where-Object { [string]$_.authority -eq "osv" }).Count -eq 1) "Native advisory review should preserve OSV authority sources."

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
    -Target win32-x64 `
    -EvidencePath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "verify-native-advisory-review.ps1 failed with exit code $LASTEXITCODE."
  }

  $badOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "subversionr-native-advisory-review-outside-target.json"
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $generateScript `
      -Target win32-x64 `
      -SourceLockPath $fixture.sourceLockPath `
      -LiveOsvEvidencePath $fixture.liveOsvPath `
      -AdvisorySourcesPath $fixture.advisorySourcesPath `
      -OutputPath $badOutputPath
  } "OutputPath must resolve inside" "Native advisory generation should reject output paths outside target."

  $missingContractPath = Join-Path $tempRoot "missing-contract.json"
  $missingContract = Get-Content -Raw -LiteralPath $fixture.advisorySourcesPath | ConvertFrom-Json
  $missingContract.components = @($missingContract.components | Where-Object { $_.name -ne "zlib" })
  Write-JsonFile $missingContractPath $missingContract
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $generateScript `
      -Target win32-x64 `
      -SourceLockPath $fixture.sourceLockPath `
      -LiveOsvEvidencePath $fixture.liveOsvPath `
      -AdvisorySourcesPath $missingContractPath `
      -OutputPath (Join-Path $tempRoot "evidence\missing-contract-output.json")
  } "Missing advisory source contracts" "Native advisory generation should reject incomplete source-contract coverage."

  $staleOsvPath = Join-Path $tempRoot "stale-live-osv.json"
  $staleOsv = Get-Content -Raw -LiteralPath $fixture.liveOsvPath | ConvertFrom-Json
  $staleOsv.generatedAt = ([DateTime]::UtcNow.AddDays(-8)).ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
  Write-JsonFile $staleOsvPath $staleOsv
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $generateScript `
      -Target win32-x64 `
      -SourceLockPath $fixture.sourceLockPath `
      -LiveOsvEvidencePath $staleOsvPath `
      -AdvisorySourcesPath $fixture.advisorySourcesPath `
      -OutputPath (Join-Path $tempRoot "evidence\stale-osv-output.json")
  } "Live OSV evidence is older than" "Native advisory generation should reject stale live OSV evidence."

  $tamperedPath = Join-Path $tempRoot "tampered-complete.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tampered.publicReadinessClaim = $true
  $tampered.vulnerabilityReviewComplete = $true
  $tampered.nativeAdvisoryReviewComplete = $true
  $tampered.nativeReview.releaseBlocking = $false
  $tampered.review.triageComplete = $true
  $tampered.review.remediationApproved = $true
  $tampered.review.vexDecisionsComplete = $true
  Write-JsonFile $tamperedPath $tampered
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript -Target win32-x64 -EvidencePath $tamperedPath
  } "publicReadinessClaim" "Native advisory verification should reject completion/readiness overclaims."

  $tamperedPath = Join-Path $tempRoot "tampered-source-lock-hash.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tampered.evidence.sourceLock.sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  Write-JsonFile $tamperedPath $tampered
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript -Target win32-x64 -EvidencePath $tamperedPath
  } "Source lock SHA256" "Native advisory verification should reject source-lock hash drift."

  $tamperedPath = Join-Path $tempRoot "tampered-secret.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath
  $tampered = $tampered -replace '"reviewStatus": "pending"', '"reviewStatus": "Authorization: Bearer fake-token"'
  Set-Content -LiteralPath $tamperedPath -Value $tampered -Encoding utf8
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript -Target win32-x64 -EvidencePath $tamperedPath
  } "must not record credentials" "Native advisory verification should reject credential-like evidence text."

  $packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  Assert-True ($packageJson.scripts."release:test-native-advisory-review-scripts".Contains("release-native-advisory-review-scripts.tests.ps1")) "Root package should expose native advisory script tests."
  Assert-True ($packageJson.scripts."release:generate-native-advisory-review:win32-x64".Contains("generate-native-advisory-review.ps1")) "Root package should expose native advisory generation."
  Assert-True ($packageJson.scripts."release:verify-native-advisory-review:win32-x64".Contains("verify-native-advisory-review.ps1")) "Root package should expose native advisory verification."

  $ciWorkflow = Get-Content -Raw -LiteralPath $ciWorkflowPath
  Assert-ContainsInOrder $ciWorkflow @(
    "Release live OSV review script tests",
    "Release native advisory review script tests",
    "Generate live OSV vulnerability review",
    "Verify live OSV vulnerability review",
    "Generate native advisory review",
    "Verify native advisory review"
  ) "CI should run native advisory tests and the native gate after the live OSV gate."

  $readinessVerifier = Get-Content -Raw -LiteralPath $readinessVerifierPath
  foreach ($term in @(
      "M7l2b native advisory review evidence gate",
      "subversionr.release.native-advisory-review.win32-x64.v1",
      "pnpm release:test-native-advisory-review-scripts",
      "pnpm release:generate-native-advisory-review:win32-x64",
      "pnpm release:verify-native-advisory-review:win32-x64"
    )) {
    Assert-True ($readinessVerifier.Contains($term)) "Release readiness verifier should require '$term'."
  }

  Write-Host "Release native advisory review script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

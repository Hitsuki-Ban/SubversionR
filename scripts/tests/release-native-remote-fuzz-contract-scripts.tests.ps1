$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$generateScript = Join-Path $repoRoot "scripts\release\generate-native-remote-fuzz-contract.ps1"
$verifyScript = Join-Path $repoRoot "scripts\release\verify-native-remote-fuzz-contract.ps1"
$packageJsonPath = Join-Path $repoRoot "package.json"

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
  $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8
}

function New-FileWithText([string]$Path, [string]$Text) {
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  Set-Content -LiteralPath $Path -Value $Text -Encoding utf8
}

function New-TestFile([string]$Root, [string]$RelativePath, [string]$TestName) {
  $path = Join-Path $Root $RelativePath.Replace("/", [System.IO.Path]::DirectorySeparatorChar)
  New-FileWithText -Path $path -Text "fn $TestName() {}"
}

function New-SecurityEvidenceMatrix([string]$Path, [string]$Sec016Status = "release-blocker", [string]$Tst020Status = "release-blocker") {
  New-FileWithText -Path $Path -Text @"
| ID | Status | Evidence | Release Requirement |
| --- | --- | --- | --- |
| ``SEC-016`` | $Sec016Status | M7l7 native remote-protocol fuzz readiness contract plus malicious input corpus preflight | Coverage-guided native remote-protocol fuzzing remains incomplete. |
| ``TST-020`` | $Tst020Status | M7l7 native remote-protocol fuzz readiness contract plus malicious input corpus preflight | Security fuzz matrix remains incomplete while coverage-guided native remote-protocol fuzzing remains deferred. |
"@
}

function New-MaliciousInputCorpus([string]$Path, [string]$BlockerStatus = "release-blocker") {
  $fixtureRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $Path))
  $seedTestName = "native_bridge_malicious_svn_server_response_history_log_fails_without_auth_prompts_or_crash"
  $seedTestPath = Join-Path $fixtureRoot "fixture-tests\native_bridge.rs"
  $seedTestRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $seedTestPath).Replace("\", "/")
  New-TestFile -Root $repoRoot -RelativePath $seedTestRelativePath -TestName $seedTestName

  Write-JsonFile $Path ([pscustomobject]@{
      schemaVersion = 1
      schema = "subversionr.security.malicious-input-corpus.win32-x64.v1"
      target = "win32-x64"
      publicReadinessClaim = $false
      completeFuzzClaim = $false
      localCorpusOnly = $true
      evidenceBoundary = "Deterministic malicious-input corpus evidence floor; not coverage-guided fuzzing and not complete libsvn remote-protocol fuzz coverage."
      requiredTraceIds = @("SEC-016", "TST-020")
      requiredCategories = @("svn-server-response")
      entries = @(
        [pscustomobject]@{
          id = "NATIVE-SVN-SERVER-001"
          traceIds = @("SEC-016", "TST-020")
          category = "svn-server-response"
          boundary = "native-libsvn-remote-protocols"
          payloadClasses = @("malformed SVN server responses", "stateful remote protocol sequences")
          status = "covered"
          test = [pscustomobject]@{
            file = $seedTestRelativePath
            name = $seedTestName
          }
        },
        [pscustomobject]@{
          id = "NATIVE-REMOTE-FUZZ-001"
          traceIds = @("SEC-016", "TST-020")
          category = "svn-server-response"
          boundary = "native-libsvn-remote-protocol-fuzzing"
          payloadClasses = @("coverage-guided remote protocol fuzzing", "cross-provider libsvn server-response fuzzing")
          status = $BlockerStatus
          blocker = "Coverage-guided fuzzing across libsvn remote access providers is not complete."
        }
      )
    })
}

function New-NativeRemoteFuzzContract([string]$Path) {
  Write-JsonFile $Path ([pscustomobject]@{
      schemaVersion = 1
      schema = "subversionr.security.native-remote-fuzz-contract.win32-x64.v1"
      target = "win32-x64"
      publicReadinessClaim = $false
      completeFuzzClaim = $false
      coverageGuidedLibsvnClaim = $false
      localPreflightOnly = $true
      requiredTraceIds = @("SEC-016", "TST-020")
      blockerEntryId = "NATIVE-REMOTE-FUZZ-001"
      scope = [pscustomobject]@{
        provider = "svn://"
        operation = "history/log"
        seedCorpus = @(
          "native_bridge_malicious_svn_server_response_history_log_fails_without_auth_prompts_or_crash"
        )
        excludedProviders = @("dav/http(s)", "svn+ssh")
        evidenceBoundary = "Readiness contract only; no fuzz execution, sanitizer coverage proof, edge-growth proof, or provider-complete claim."
      }
      toolchainRequirements = [pscustomobject]@{
        rustToolchain = "nightly-x86_64-pc-windows-msvc"
        cargoSubcommand = "cargo-fuzz"
        msvcCompiler = "MSVC cl.exe"
        msvcFlags = @("/fsanitize=fuzzer", "/fsanitize=address")
        nativeRuntime = "source-built libsvn/APR/bridge with sanitizer coverage instrumentation"
      }
      requiredEvidence = @(
        [pscustomobject]@{ id = "instrumented-libsvn-build"; required = $true; status = "not-proven" },
        [pscustomobject]@{ id = "fuzzer-target"; required = $true; status = "not-created" },
        [pscustomobject]@{ id = "seed-corpus"; required = $true; status = "contract-only" },
        [pscustomobject]@{ id = "run-evidence"; required = $true; status = "not-run" },
        [pscustomobject]@{ id = "coverage-evidence"; required = $true; status = "not-proven" }
      )
      blockers = @(
        "Nightly Rust and cargo-fuzz are not part of the current local baseline.",
        "Source-built libsvn/APR/bridge sanitizer coverage instrumentation has not been proven.",
        "No native remote-protocol fuzzer target has produced run, crash, or edge-growth evidence."
      )
      nonClaims = @(
        "This gate is a local fuzz readiness contract, not a coverage-guided fuzz run.",
        "This gate does not prove sanitizer coverage, libsvn edge growth, crash discovery, or provider-complete remote-protocol fuzzing.",
        "This gate does not close SEC-016, TST-020, NATIVE-REMOTE-FUZZ-001, or public release readiness."
      )
      currentStatus = [pscustomobject]@{
        status = "blocked"
        publicReadinessAllowed = $false
      }
    })
}

function New-NativeRemoteFuzzFixture([string]$Root) {
  $contractPath = Join-Path $Root "docs\security\native-remote-fuzz-contract.win32-x64.json"
  $corpusPath = Join-Path $Root "docs\security\malicious-input-corpus.win32-x64.json"
  $matrixPath = Join-Path $Root "docs\release\security-evidence-matrix.md"
  $outputPath = Join-Path $Root "target\release-evidence\subversionr-native-remote-fuzz-contract-win32-x64.json"
  New-NativeRemoteFuzzContract -Path $contractPath
  New-MaliciousInputCorpus -Path $corpusPath
  New-SecurityEvidenceMatrix -Path $matrixPath

  [pscustomobject]@{
    root = $Root
    contractPath = $contractPath
    corpusPath = $corpusPath
    matrixPath = $matrixPath
    outputPath = $outputPath
  }
}

function Invoke-GenerateNativeRemoteFuzzContract([object]$Fixture, [string]$OutputPath) {
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $generateScript `
    -Target win32-x64 `
    -ContractPath $Fixture.contractPath `
    -MaliciousInputCorpusPath $Fixture.corpusPath `
    -SecurityEvidenceMatrixPath $Fixture.matrixPath `
    -OutputPath $OutputPath
}

$tempRoot = Join-Path $repoRoot "target\tests\release-native-remote-fuzz-contract-scripts\$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  Assert-True (Test-Path -LiteralPath $generateScript -PathType Leaf) "generate-native-remote-fuzz-contract.ps1 should exist."
  Assert-True (Test-Path -LiteralPath $verifyScript -PathType Leaf) "verify-native-remote-fuzz-contract.ps1 should exist."

  $fixture = New-NativeRemoteFuzzFixture $tempRoot
  Invoke-GenerateNativeRemoteFuzzContract -Fixture $fixture -OutputPath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "generate-native-remote-fuzz-contract.ps1 failed with exit code $LASTEXITCODE."
  }

  $report = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  Assert-Equal "subversionr.release.native-remote-fuzz-contract.win32-x64.v1" $report.schema "Native remote fuzz contract evidence should use the release schema."
  Assert-Equal "False" ([string]$report.publicReadinessClaim) "Native remote fuzz contract evidence must not claim public readiness."
  Assert-Equal "False" ([string]$report.completeFuzzClaim) "Native remote fuzz contract evidence must not claim complete fuzzing."
  Assert-Equal "False" ([string]$report.coverageGuidedLibsvnClaim) "Native remote fuzz contract evidence must not claim coverage-guided libsvn fuzzing."
  Assert-Equal "True" ([string]$report.localPreflightOnly) "Native remote fuzz contract evidence should be local preflight only."
  Assert-Equal (Get-Sha256 $fixture.contractPath) $report.inputs.contract.sha256 "Evidence should bind the native remote fuzz contract manifest."
  Assert-Equal (Get-Sha256 $fixture.corpusPath) $report.inputs.maliciousInputCorpus.sha256 "Evidence should bind the malicious input corpus manifest."
  Assert-Equal (Get-Sha256 $fixture.matrixPath) $report.inputs.securityEvidenceMatrix.sha256 "Evidence should bind the security evidence matrix."
  Assert-Equal "NATIVE-REMOTE-FUZZ-001" $report.blockerEntryId "Evidence should bind the native remote fuzz blocker entry."
  Assert-Equal "blocked" $report.currentStatus.status "Evidence should keep the fuzz contract blocked."
  Assert-Equal "not-proven" $report.toolchainObservations.sanitizerCoverage.status "Evidence should not claim sanitizer coverage instrumentation."
  foreach ($evidenceId in @("instrumented-libsvn-build", "fuzzer-target", "seed-corpus", "run-evidence", "coverage-evidence")) {
    Assert-True (@($report.requiredEvidence | Where-Object { [string]$_.id -eq $evidenceId }).Count -eq 1) "Native remote fuzz contract should require evidence '$evidenceId'."
  }
  foreach ($nonClaim in @(
      "This gate is a local fuzz readiness contract, not a coverage-guided fuzz run.",
      "This gate does not prove sanitizer coverage, libsvn edge growth, crash discovery, or provider-complete remote-protocol fuzzing.",
      "This gate does not close SEC-016, TST-020, NATIVE-REMOTE-FUZZ-001, or public release readiness."
    )) {
    Assert-True (@($report.nonClaims | Where-Object { $_ -eq $nonClaim }).Count -eq 1) "Native remote fuzz contract evidence should preserve non-claim: $nonClaim"
  }

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
    -Target win32-x64 `
    -EvidencePath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "verify-native-remote-fuzz-contract.ps1 failed with exit code $LASTEXITCODE."
  }

  $fixture = New-NativeRemoteFuzzFixture (Join-Path $tempRoot "contract-overclaim")
  $badContract = Get-Content -Raw -LiteralPath $fixture.contractPath | ConvertFrom-Json
  $badContract.coverageGuidedLibsvnClaim = $true
  Write-JsonFile $fixture.contractPath $badContract
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateNativeRemoteFuzzContract -Fixture $fixture -OutputPath $fixture.outputPath
  } "coverageGuidedLibsvnClaim" "Native remote fuzz contract generation should reject contract overclaims."

  $fixture = New-NativeRemoteFuzzFixture (Join-Path $tempRoot "matrix-overclaim")
  New-SecurityEvidenceMatrix -Path $fixture.matrixPath -Sec016Status "verified"
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateNativeRemoteFuzzContract -Fixture $fixture -OutputPath $fixture.outputPath
  } "SEC-016" "Native remote fuzz contract generation should reject evidence-matrix overclaims."

  $fixture = New-NativeRemoteFuzzFixture (Join-Path $tempRoot "missing-corpus-blocker")
  New-MaliciousInputCorpus -Path $fixture.corpusPath -BlockerStatus "covered"
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateNativeRemoteFuzzContract -Fixture $fixture -OutputPath $fixture.outputPath
  } "NATIVE-REMOTE-FUZZ-001" "Native remote fuzz contract generation should require the malicious corpus release blocker."

  $fixture = New-NativeRemoteFuzzFixture (Join-Path $tempRoot "missing-seed-corpus")
  $badContract = Get-Content -Raw -LiteralPath $fixture.contractPath | ConvertFrom-Json
  $badContract.scope.seedCorpus = @("nonexistent_seed_corpus_name")
  Write-JsonFile $fixture.contractPath $badContract
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateNativeRemoteFuzzContract -Fixture $fixture -OutputPath $fixture.outputPath
  } "seedCorpus" "Native remote fuzz contract generation should require seedCorpus entries to match covered malicious corpus tests."

  $fixture = New-NativeRemoteFuzzFixture (Join-Path $tempRoot "evidence-overclaim")
  Invoke-GenerateNativeRemoteFuzzContract -Fixture $fixture -OutputPath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "generate-native-remote-fuzz-contract.ps1 failed for overclaim fixture with exit code $LASTEXITCODE."
  }
  $tamperedReportPath = Join-Path $tempRoot "tampered-overclaim.json"
  $tamperedReport = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tamperedReport.coverageGuidedLibsvnClaim = $true
  Write-JsonFile $tamperedReportPath $tamperedReport
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
      -Target win32-x64 `
      -EvidencePath $tamperedReportPath
  } "coverageGuidedLibsvnClaim" "Native remote fuzz contract verification should reject evidence overclaims."

  $fixture = New-NativeRemoteFuzzFixture (Join-Path $tempRoot "contract-derived-drift")
  Invoke-GenerateNativeRemoteFuzzContract -Fixture $fixture -OutputPath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "generate-native-remote-fuzz-contract.ps1 failed for contract-derived drift fixture with exit code $LASTEXITCODE."
  }
  $tamperedReportPath = Join-Path $tempRoot "tampered-contract-derived-drift.json"
  $tamperedReport = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tamperedReport.scope.evidenceBoundary = "Coverage-guided fuzzing complete."
  $tamperedReport.toolchainRequirements.msvcCompiler = "different compiler"
  $tamperedReport.toolchainRequirements.nativeRuntime = "sanitizer-instrumented libsvn coverage proven"
  Write-JsonFile $tamperedReportPath $tamperedReport
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
      -Target win32-x64 `
      -EvidencePath $tamperedReportPath
  } "evidenceBoundary" "Native remote fuzz contract verification should reject drift in contract-derived evidence fields."

  $fixture = New-NativeRemoteFuzzFixture (Join-Path $tempRoot "missing-nonclaim")
  Invoke-GenerateNativeRemoteFuzzContract -Fixture $fixture -OutputPath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "generate-native-remote-fuzz-contract.ps1 failed for nonclaim fixture with exit code $LASTEXITCODE."
  }
  $tamperedReportPath = Join-Path $tempRoot "tampered-nonclaim.json"
  $tamperedReport = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tamperedReport.nonClaims = @($tamperedReport.nonClaims | Where-Object { $_ -ne "This gate does not close SEC-016, TST-020, NATIVE-REMOTE-FUZZ-001, or public release readiness." })
  Write-JsonFile $tamperedReportPath $tamperedReport
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
      -Target win32-x64 `
      -EvidencePath $tamperedReportPath
  } "nonClaims" "Native remote fuzz contract verification should reject missing nonclaims."

  $fixture = New-NativeRemoteFuzzFixture (Join-Path $tempRoot "hash-drift")
  Invoke-GenerateNativeRemoteFuzzContract -Fixture $fixture -OutputPath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "generate-native-remote-fuzz-contract.ps1 failed for hash drift fixture with exit code $LASTEXITCODE."
  }
  $contract = Get-Content -Raw -LiteralPath $fixture.contractPath | ConvertFrom-Json
  $contract.blockers += "New blocker introduced after evidence generation."
  Write-JsonFile $fixture.contractPath $contract
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
      -Target win32-x64 `
      -EvidencePath $fixture.outputPath
  } "sha256" "Native remote fuzz contract verification should reject input hash drift."

  $fixture = New-NativeRemoteFuzzFixture (Join-Path $tempRoot "credential-pattern")
  $badContract = Get-Content -Raw -LiteralPath $fixture.contractPath | ConvertFrom-Json
  $badContract.blockers += "Do not record https://alice:secret@example.invalid/svn in fuzz evidence."
  Write-JsonFile $fixture.contractPath $badContract
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateNativeRemoteFuzzContract -Fixture $fixture -OutputPath $fixture.outputPath
  } "credentials" "Native remote fuzz contract generation should reject credential-like contract text."

  $fixture = New-NativeRemoteFuzzFixture (Join-Path $tempRoot "outside-output")
  $badOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "subversionr-native-remote-fuzz-contract-outside-target.json"
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateNativeRemoteFuzzContract -Fixture $fixture -OutputPath $badOutputPath
  } "OutputPath must resolve inside" "Native remote fuzz contract generation should reject output paths outside target."

  $packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  Assert-True ($packageJson.scripts."release:test-native-remote-fuzz-contract-scripts".Contains("release-native-remote-fuzz-contract-scripts.tests.ps1")) "Root package should expose native remote fuzz contract script tests."
  Assert-True ($packageJson.scripts."release:generate-native-remote-fuzz-contract:win32-x64".Contains("generate-native-remote-fuzz-contract.ps1")) "Root package should expose native remote fuzz contract generation."
  Assert-True ($packageJson.scripts."release:verify-native-remote-fuzz-contract:win32-x64".Contains("verify-native-remote-fuzz-contract.ps1")) "Root package should expose native remote fuzz contract verification."

  Write-Host "Release native remote fuzz contract script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

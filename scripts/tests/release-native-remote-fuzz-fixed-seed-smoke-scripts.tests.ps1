$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$generateScript = Join-Path $repoRoot "scripts\release\generate-native-remote-fuzz-fixed-seed-smoke.ps1"
$verifyScript = Join-Path $repoRoot "scripts\release\verify-native-remote-fuzz-fixed-seed-smoke.ps1"
$packageJsonPath = Join-Path $repoRoot "package.json"
$ciWorkflowPath = Join-Path $repoRoot ".github\workflows\ci.yml"
$prFastWorkflowPath = Join-Path $repoRoot ".github\workflows\pr-fast.yml"

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
  $Value | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $Path -Encoding utf8
}

function New-FileWithText([string]$Path, [string]$Text) {
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  Set-Content -LiteralPath $Path -Value $Text -Encoding utf8
}

function New-FakeVsDevCmd([string]$Path) {
  New-FileWithText -Path $Path -Text @"
@echo off
set SUBVERSIONR_FAKE_VSDEVCMD=1
exit /b 0
"@
}

function New-FakeCargo([string]$Path, [bool]$FailRun = $false) {
  $runBlock = if ($FailRun) {
    @"
if "%~2"=="fuzz" if "%~3"=="run" (
  echo fixed seed run failed 1>&2
  exit /b 7
)
"@
  }
  else {
    @"
if "%~2"=="fuzz" if "%~3"=="run" (
  echo     Finished release profile in 0.04s
  echo      Running `fuzz\target\x86_64-pc-windows-msvc\release\svn_server_response_history_log.exe -runs=1 %~5`
  echo Running: fuzz\corpus\svn_server_response_history_log\malicious-log-response.seed
  echo Executed fuzz\corpus\svn_server_response_history_log\malicious-log-response.seed in 0 ms
  echo *** NOTE: fuzzing was not performed, you have only executed the target code on a fixed set of inputs.
  exit /b 0
)
"@
  }
  New-FileWithText -Path $Path -Text @"
@echo off
if "%~1"=="fuzz" if "%~2"=="--version" (
  echo cargo-fuzz 0.13.2
  exit /b 0
)
if "%~1"=="+nightly" if "%~2"=="--version" (
  echo cargo 1.98.0-nightly a595d0da2-2026-06-20
  exit /b 0
)
if "%~1"=="+nightly" if "%~2"=="fuzz" if "%~3"=="build" (
  echo     Finished release profile in 0.04s
  exit /b 0
)
$runBlock
echo unexpected fake cargo args: %*
exit /b 9
"@
}

function New-SecurityEvidenceMatrix([string]$Path, [string]$Sec016Status = "release-blocker", [string]$Tst020Status = "release-blocker") {
  New-FileWithText -Path $Path -Text @"
| ID | Status | Evidence | Release Requirement |
| --- | --- | --- | --- |
| ``SEC-016`` | $Sec016Status | M7l9 native remote-protocol fixed seed harness smoke gate | Coverage-guided native remote-protocol fuzzing remains incomplete. |
| ``TST-020`` | $Tst020Status | M7l9 native remote-protocol fixed seed harness smoke gate | Security fuzz matrix remains incomplete while coverage-guided native remote-protocol fuzzing remains deferred. |
"@
}

function New-MaliciousInputCorpus([string]$Path, [string]$BlockerStatus = "release-blocker") {
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

function New-FuzzFiles([string]$Root) {
  $manifestPath = Join-Path $Root "fuzz\Cargo.toml"
  $lockPath = Join-Path $Root "fuzz\Cargo.lock"
  $targetPath = Join-Path $Root "fuzz\fuzz_targets\svn_server_response_history_log.rs"
  $seedPath = Join-Path $Root "fuzz\corpus\svn_server_response_history_log\malicious-log-response.seed"
  $seedManifestPath = Join-Path $Root "fuzz\corpus\svn_server_response_history_log\manifest.json"
  New-FileWithText -Path $manifestPath -Text @"
[workspace]

[package]
name = "subversionr-native-remote-fuzz"
version = "0.0.0"
publish = false
edition = "2024"

[package.metadata]
cargo-fuzz = true

[dependencies]
libfuzzer-sys = "=0.4.13"

[[bin]]
name = "svn_server_response_history_log"
path = "fuzz_targets/svn_server_response_history_log.rs"
test = false
doc = false
bench = false
"@
  New-FileWithText -Path $lockPath -Text @"
# This file is automatically @generated by Cargo.
# It is not intended for manual editing.
version = 4

[[package]]
name = "libfuzzer-sys"
version = "0.4.13"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "a9fd2f41a1cba099f79a0b6b6c35656cf7c03351a7bae8ff0f28f25270f929d2"

[[package]]
name = "subversionr-native-remote-fuzz"
version = "0.0.0"
dependencies = [
 "libfuzzer-sys",
]
"@
  New-FileWithText -Path $targetPath -Text @"
#![no_main]
use libfuzzer_sys::{fuzz_target, Corpus};
const MAX_FUZZ_INPUT_BYTES: usize = 65_536;
const TARGET_TRACE_ID: &str = "NATIVE-REMOTE-FUZZ-001";
const TARGET_SCOPE: &str = "svn:// history/log";
const SOURCE_SEED_ID: &str = "malicious-log-response-v1";
fuzz_target!(|data: &[u8]| -> Corpus {
    let _ = (MAX_FUZZ_INPUT_BYTES, TARGET_TRACE_ID, TARGET_SCOPE, SOURCE_SEED_ID, data);
    Corpus::Keep
});
"@
  New-FileWithText -Path $seedPath -Text "( ( ) 2 4:anon 27:2024-01-01T00:00:00.000000Z 999999999:unterminated"
  $seedRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $seedPath).Replace("\", "/")
  Write-JsonFile $seedManifestPath ([pscustomobject]@{
      schemaVersion = 1
      schema = "subversionr.fuzz.seed-corpus.svn-server-response-history-log.v1"
      target = "svn_server_response_history_log"
      provider = "svn://"
      operation = "history/log"
      publicReadinessClaim = $false
      fuzzRunPerformed = $false
      coverageEvidenceRecorded = $false
      seeds = @(
        [pscustomobject]@{
          id = "malicious-log-response-v1"
          path = $seedRelativePath
          sha256 = Get-Sha256 $seedPath
          source = "Protocol-faithful seed derived from the M7l6 malicious svn:// history/log fixture shape; auth material is intentionally omitted."
          traceIds = @("SEC-016", "TST-020")
        }
      )
      nonClaims = @(
        "This seed corpus is for source preflight only and is not coverage-guided fuzz evidence.",
        "This seed corpus does not prove arbitrary svn:// server safety or provider-complete remote-protocol fuzzing."
      )
    })
  [pscustomobject]@{
    manifestPath = $manifestPath
    lockPath = $lockPath
    targetPath = $targetPath
    seedManifestPath = $seedManifestPath
    seedPath = $seedPath
  }
}

function New-NativeRemoteFuzzContract([string]$Path, [object]$FuzzFiles) {
  $fixtureRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $Path))
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
        seedCorpus = @("native_bridge_malicious_svn_server_response_history_log_fails_without_auth_prompts_or_crash")
        excludedProviders = @("dav/http(s)", "svn+ssh")
        evidenceBoundary = "Readiness contract only; no fuzz execution, sanitizer coverage proof, edge-growth proof, or provider-complete claim."
      }
      sourcePreflight = [pscustomobject]@{
        status = "source-created"
        packageManifest = [System.IO.Path]::GetRelativePath($repoRoot, $FuzzFiles.manifestPath).Replace("\", "/")
        targetName = "svn_server_response_history_log"
        targetPath = [System.IO.Path]::GetRelativePath($repoRoot, $FuzzFiles.targetPath).Replace("\", "/")
        seedCorpusDirectory = [System.IO.Path]::GetRelativePath($repoRoot, (Join-Path $fixtureRoot "fuzz\corpus\svn_server_response_history_log")).Replace("\", "/")
        seedCorpusManifest = [System.IO.Path]::GetRelativePath($repoRoot, $FuzzFiles.seedManifestPath).Replace("\", "/")
        evidenceBoundary = "Source preflight only; no cargo-fuzz build, run, seed execution, sanitizer coverage, crash, or edge-growth evidence is recorded."
      }
      requiredEvidence = @(
        [pscustomobject]@{ id = "instrumented-libsvn-build"; required = $true; status = "not-proven" },
        [pscustomobject]@{ id = "fuzzer-target"; required = $true; status = "source-created" },
        [pscustomobject]@{ id = "seed-corpus"; required = $true; status = "source-created" },
        [pscustomobject]@{ id = "fixed-seed-smoke"; required = $true; status = "local-smoke-required" },
        [pscustomobject]@{ id = "run-evidence"; required = $true; status = "not-run" },
        [pscustomobject]@{ id = "coverage-evidence"; required = $true; status = "not-proven" }
      )
      blockers = @(
        "Source-built libsvn/APR/bridge sanitizer coverage instrumentation has not been proven.",
        "The fixed-seed smoke gate is not a coverage-guided fuzz run and does not prove edge growth."
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

function New-NativeRemoteFuzzFixedSeedFixture([string]$Root, [bool]$FailRun = $false) {
  $contractPath = Join-Path $Root "docs\security\native-remote-fuzz-contract.win32-x64.json"
  $corpusPath = Join-Path $Root "docs\security\malicious-input-corpus.win32-x64.json"
  $matrixPath = Join-Path $Root "docs\release\security-evidence-matrix.md"
  $fuzzFiles = New-FuzzFiles $Root
  New-NativeRemoteFuzzContract -Path $contractPath -FuzzFiles $fuzzFiles
  New-MaliciousInputCorpus -Path $corpusPath
  New-SecurityEvidenceMatrix -Path $matrixPath
  $fakeVsDevCmd = Join-Path $Root "tools\VsDevCmd.bat"
  $fakeCargo = Join-Path $Root "tools\cargo.cmd"
  New-FakeVsDevCmd $fakeVsDevCmd
  New-FakeCargo -Path $fakeCargo -FailRun $FailRun

  [pscustomobject]@{
    root = $Root
    contractPath = $contractPath
    corpusPath = $corpusPath
    matrixPath = $matrixPath
    fuzzManifestPath = $fuzzFiles.manifestPath
    fuzzLockPath = $fuzzFiles.lockPath
    fuzzTargetPath = $fuzzFiles.targetPath
    seedManifestPath = $fuzzFiles.seedManifestPath
    vsDevCmdPath = $fakeVsDevCmd
    cargoExePath = $fakeCargo
    outputPath = Join-Path $Root "target\release-evidence\subversionr-native-remote-fuzz-fixed-seed-smoke-win32-x64.json"
  }
}

function Invoke-GenerateNativeRemoteFuzzFixedSeedSmoke([object]$Fixture, [string]$OutputPath) {
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $generateScript `
    -Target win32-x64 `
    -ContractPath $Fixture.contractPath `
    -MaliciousInputCorpusPath $Fixture.corpusPath `
    -SecurityEvidenceMatrixPath $Fixture.matrixPath `
    -FuzzManifestPath $Fixture.fuzzManifestPath `
    -FuzzLockPath $Fixture.fuzzLockPath `
    -FuzzTargetPath $Fixture.fuzzTargetPath `
    -SeedManifestPath $Fixture.seedManifestPath `
    -VsDevCmdPath $Fixture.vsDevCmdPath `
    -CargoExePath $Fixture.cargoExePath `
    -OutputPath $OutputPath
}

$tempRoot = Join-Path $repoRoot "target\tests\release-native-remote-fuzz-fixed-seed-smoke-scripts\$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  Assert-True (Test-Path -LiteralPath $generateScript -PathType Leaf) "generate-native-remote-fuzz-fixed-seed-smoke.ps1 should exist."
  Assert-True (Test-Path -LiteralPath $verifyScript -PathType Leaf) "verify-native-remote-fuzz-fixed-seed-smoke.ps1 should exist."

  $fixture = New-NativeRemoteFuzzFixedSeedFixture $tempRoot
  Invoke-GenerateNativeRemoteFuzzFixedSeedSmoke -Fixture $fixture -OutputPath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "generate-native-remote-fuzz-fixed-seed-smoke.ps1 failed with exit code $LASTEXITCODE."
  }

  $report = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  Assert-Equal "subversionr.release.native-remote-fuzz-fixed-seed-smoke.win32-x64.v1" $report.schema "Fixed seed smoke evidence should use the release schema."
  Assert-Equal "True" ([string]$report.cargoFuzzBuildPerformed) "Fixed seed smoke should record cargo-fuzz build performed."
  Assert-Equal "True" ([string]$report.fixedSeedExecutionPerformed) "Fixed seed smoke should record fixed seed execution performed."
  Assert-Equal "False" ([string]$report.coverageGuidedFuzzRunPerformed) "Fixed seed smoke must not claim coverage-guided fuzzing."
  Assert-Equal "False" ([string]$report.coverageEvidenceRecorded) "Fixed seed smoke must not claim coverage evidence."
  Assert-Equal "False" ([string]$report.libsvnFfiReached) "Fixed seed smoke must not claim libsvn FFI reachability."
  Assert-Equal "not-run" $report.execution.coverageGuidedFuzzRun.status "Coverage-guided fuzz run status must remain not-run."
  Assert-Equal "rust-parser-only" $report.execution.harnessDepth.status "Fixed seed smoke should identify harness depth as Rust-parser-only."
  Assert-Equal "not-proven" $report.execution.coverage.status "Coverage status must remain not-proven."
  Assert-Equal "passed" $report.execution.cargoFuzzBuild.status "cargo-fuzz build should pass."
  Assert-Equal "passed" $report.execution.fixedSeedRun.status "fixed seed run should pass."
  Assert-True ($report.execution.fixedSeedRun.libFuzzerNote.Contains("fuzzing was not performed")) "Fixed seed evidence should preserve the libFuzzer fixed-input note."
  Assert-Equal (Get-Sha256 $fixture.fuzzManifestPath) $report.inputs.fuzzManifest.sha256 "Evidence should bind fuzz manifest."
  Assert-Equal (Get-Sha256 $fixture.fuzzLockPath) $report.inputs.fuzzLock.sha256 "Evidence should bind fuzz lock."
  Assert-Equal (Get-Sha256 $fixture.fuzzTargetPath) $report.inputs.fuzzTarget.sha256 "Evidence should bind fuzz target."
  Assert-Equal (Get-Sha256 $fixture.seedManifestPath) $report.inputs.seedManifest.sha256 "Evidence should bind seed manifest."

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
    -Target win32-x64 `
    -EvidencePath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "verify-native-remote-fuzz-fixed-seed-smoke.ps1 failed with exit code $LASTEXITCODE."
  }

  $fixture = New-NativeRemoteFuzzFixedSeedFixture (Join-Path $tempRoot "run-failure") -FailRun $true
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateNativeRemoteFuzzFixedSeedSmoke -Fixture $fixture -OutputPath $fixture.outputPath
  } "fixed seed run failed" "Fixed seed smoke generation should fail when cargo-fuzz fixed seed execution fails."

  $fixture = New-NativeRemoteFuzzFixedSeedFixture (Join-Path $tempRoot "missing-evidence-id")
  $badContract = Get-Content -Raw -LiteralPath $fixture.contractPath | ConvertFrom-Json
  $badContract.requiredEvidence = @($badContract.requiredEvidence | Where-Object { [string]$_.id -ne "fixed-seed-smoke" })
  Write-JsonFile $fixture.contractPath $badContract
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateNativeRemoteFuzzFixedSeedSmoke -Fixture $fixture -OutputPath $fixture.outputPath
  } "fixed-seed-smoke" "Fixed seed smoke generation should require the fixed-seed-smoke evidence id."

  $fixture = New-NativeRemoteFuzzFixedSeedFixture (Join-Path $tempRoot "matrix-overclaim")
  New-SecurityEvidenceMatrix -Path $fixture.matrixPath -Sec016Status "verified"
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateNativeRemoteFuzzFixedSeedSmoke -Fixture $fixture -OutputPath $fixture.outputPath
  } "SEC-016" "Fixed seed smoke generation should reject security matrix overclaims."

  $fixture = New-NativeRemoteFuzzFixedSeedFixture (Join-Path $tempRoot "evidence-overclaim")
  Invoke-GenerateNativeRemoteFuzzFixedSeedSmoke -Fixture $fixture -OutputPath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "generate-native-remote-fuzz-fixed-seed-smoke.ps1 failed for overclaim fixture with exit code $LASTEXITCODE."
  }
  $tamperedReportPath = Join-Path $tempRoot "tampered-overclaim.json"
  $tamperedReport = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tamperedReport.coverageGuidedFuzzRunPerformed = $true
  Write-JsonFile $tamperedReportPath $tamperedReport
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
      -Target win32-x64 `
      -EvidencePath $tamperedReportPath
  } "coverageGuidedFuzzRunPerformed" "Fixed seed smoke verification should reject coverage-guided overclaims."

  $fixture = New-NativeRemoteFuzzFixedSeedFixture (Join-Path $tempRoot "hash-drift")
  Invoke-GenerateNativeRemoteFuzzFixedSeedSmoke -Fixture $fixture -OutputPath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "generate-native-remote-fuzz-fixed-seed-smoke.ps1 failed for hash drift fixture with exit code $LASTEXITCODE."
  }
  Add-Content -LiteralPath $fixture.fuzzTargetPath -Value "// drift"
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
      -Target win32-x64 `
      -EvidencePath $fixture.outputPath
  } "sha256" "Fixed seed smoke verification should reject input hash drift."

  $fixture = New-NativeRemoteFuzzFixedSeedFixture (Join-Path $tempRoot "outside-output")
  $badOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "subversionr-native-remote-fuzz-fixed-seed-smoke-outside-target.json"
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateNativeRemoteFuzzFixedSeedSmoke -Fixture $fixture -OutputPath $badOutputPath
  } "OutputPath must resolve inside" "Fixed seed smoke generation should reject output paths outside target."

  $packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  Assert-True ($packageJson.scripts."release:test-native-remote-fuzz-fixed-seed-smoke-scripts".Contains("release-native-remote-fuzz-fixed-seed-smoke-scripts.tests.ps1")) "Root package should expose fixed seed smoke script tests."
  Assert-True ($packageJson.scripts."release:generate-native-remote-fuzz-fixed-seed-smoke:win32-x64".Contains("generate-native-remote-fuzz-fixed-seed-smoke.ps1")) "Root package should expose fixed seed smoke generation."
  Assert-True ($packageJson.scripts."release:verify-native-remote-fuzz-fixed-seed-smoke:win32-x64".Contains("verify-native-remote-fuzz-fixed-seed-smoke.ps1")) "Root package should expose fixed seed smoke verification."
  $ciWorkflow = Get-Content -Raw -LiteralPath $ciWorkflowPath
  Assert-True ($ciWorkflow.Contains("pnpm release:generate-native-remote-fuzz-fixed-seed-smoke:win32-x64")) "Manual CI should retain fixed seed smoke generation."
  Assert-True ($ciWorkflow.Contains("pnpm release:verify-native-remote-fuzz-fixed-seed-smoke:win32-x64")) "Manual CI should retain fixed seed smoke verification."
  $prFastWorkflow = Get-Content -Raw -LiteralPath $prFastWorkflowPath
  foreach ($forbiddenCommand in @(
      "pnpm release:test-native-remote-fuzz-fixed-seed-smoke-scripts",
      "pnpm release:generate-native-remote-fuzz-fixed-seed-smoke:win32-x64",
      "pnpm release:verify-native-remote-fuzz-fixed-seed-smoke:win32-x64"
    )) {
    Assert-True (-not $prFastWorkflow.Contains($forbiddenCommand)) "PR Fast must not run the fixed seed smoke build/run gate: $forbiddenCommand"
  }

  Write-Host "Release native remote fixed seed harness smoke script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

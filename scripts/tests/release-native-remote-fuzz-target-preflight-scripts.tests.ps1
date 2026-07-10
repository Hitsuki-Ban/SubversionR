$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$generateScript = Join-Path $repoRoot "scripts\release\generate-native-remote-fuzz-target-preflight.ps1"
$verifyScript = Join-Path $repoRoot "scripts\release\verify-native-remote-fuzz-target-preflight.ps1"
$packageJsonPath = Join-Path $repoRoot "package.json"
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
  $Value | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $Path -Encoding utf8
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
| ``SEC-016`` | $Sec016Status | M7l7 native remote-protocol fuzz readiness contract plus M7l8 native remote-protocol fuzz target source preflight | Coverage-guided native remote-protocol fuzzing remains incomplete. |
| ``TST-020`` | $Tst020Status | M7l8 native remote-protocol fuzz target source preflight plus malicious input corpus preflight | Security fuzz matrix remains incomplete while coverage-guided native remote-protocol fuzzing remains deferred. |
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

function New-FuzzTargetSource([string]$Path, [string]$ExtraText = "") {
  New-FileWithText -Path $Path -Text @"
#![no_main]

use libfuzzer_sys::{fuzz_target, Corpus};

const MAX_FUZZ_INPUT_BYTES: usize = 65_536;
const TARGET_TRACE_ID: &str = "NATIVE-REMOTE-FUZZ-001";
const TARGET_SCOPE: &str = "svn:// history/log";
const SOURCE_SEED_ID: &str = "malicious-log-response-v1";

fuzz_target!(|data: &[u8]| -> Corpus {
    if data.is_empty() || data.len() > MAX_FUZZ_INPUT_BYTES {
        return Corpus::Reject;
    }

    let candidate = FuzzLogResponse::from_bytes(data);
    if !candidate.looks_like_history_log() {
        return Corpus::Reject;
    }

    let _ = (TARGET_TRACE_ID, TARGET_SCOPE, SOURCE_SEED_ID);
    candidate.scan_length_prefixed_tokens();
    Corpus::Keep
});

struct FuzzLogResponse<'a> {
    bytes: &'a [u8],
}

impl<'a> FuzzLogResponse<'a> {
    fn from_bytes(bytes: &'a [u8]) -> Self {
        Self { bytes }
    }

    fn looks_like_history_log(&self) -> bool {
        self.bytes.windows(6).any(|window| window == b"( ( ) ")
            && self.bytes.iter().any(u8::is_ascii_digit)
            && self.bytes.contains(&b':')
    }

    fn scan_length_prefixed_tokens(&self) -> usize {
        let mut index = 0usize;
        let mut tokens = 0usize;
        while index < self.bytes.len() && tokens < 64 {
            if !self.bytes[index].is_ascii_digit() {
                index += 1;
                continue;
            }
            let start = index;
            while index < self.bytes.len() && self.bytes[index].is_ascii_digit() && index - start < 9 {
                index += 1;
            }
            if index == self.bytes.len() || self.bytes[index] != b':' {
                continue;
            }
            let Ok(length_text) = std::str::from_utf8(&self.bytes[start..index]) else {
                continue;
            };
            let Ok(length) = length_text.parse::<usize>() else {
                continue;
            };
            index += 1;
            if index.checked_add(length).is_none_or(|end| end > self.bytes.len()) {
                break;
            }
            index += length;
            tokens += 1;
        }
        tokens
    }
}
$ExtraText
"@
}

function New-FuzzManifest([string]$Path) {
  New-FileWithText -Path $Path -Text @"
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
}

function New-SeedManifest([string]$Root, [string]$SeedRelativePath = "") {
  $localSeedPath = "fuzz/corpus/svn_server_response_history_log/malicious-log-response.seed"
  $seedPath = Join-Path $Root $localSeedPath.Replace("/", [System.IO.Path]::DirectorySeparatorChar)
  if ([string]::IsNullOrWhiteSpace($SeedRelativePath)) {
    $SeedRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $seedPath).Replace("\", "/")
  }
  New-FileWithText -Path $seedPath -Text "( ( ) 2 4:anon 27:2024-01-01T00:00:00.000000Z 999999999:unterminated"
  $manifestPath = Join-Path $Root "fuzz\corpus\svn_server_response_history_log\manifest.json"
  Write-JsonFile $manifestPath ([pscustomobject]@{
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
          path = $SeedRelativePath
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
  $manifestPath
}

function New-NativeRemoteFuzzContract([string]$Path) {
  $fixtureRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $Path))
  $fuzzManifestRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, (Join-Path $fixtureRoot "fuzz\Cargo.toml")).Replace("\", "/")
  $fuzzTargetRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, (Join-Path $fixtureRoot "fuzz\fuzz_targets\svn_server_response_history_log.rs")).Replace("\", "/")
  $seedCorpusRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, (Join-Path $fixtureRoot "fuzz\corpus\svn_server_response_history_log")).Replace("\", "/")
  $seedManifestRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, (Join-Path $fixtureRoot "fuzz\corpus\svn_server_response_history_log\manifest.json")).Replace("\", "/")
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
      sourcePreflight = [pscustomobject]@{
        status = "source-created"
        packageManifest = $fuzzManifestRelativePath
        targetName = "svn_server_response_history_log"
        targetPath = $fuzzTargetRelativePath
        seedCorpusDirectory = $seedCorpusRelativePath
        seedCorpusManifest = $seedManifestRelativePath
        evidenceBoundary = "Source preflight only; no cargo-fuzz build, run, seed execution, sanitizer coverage, crash, or edge-growth evidence is recorded."
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
        [pscustomobject]@{ id = "fuzzer-target"; required = $true; status = "source-created" },
        [pscustomobject]@{ id = "seed-corpus"; required = $true; status = "source-created" },
        [pscustomobject]@{ id = "run-evidence"; required = $true; status = "not-run" },
        [pscustomobject]@{ id = "coverage-evidence"; required = $true; status = "not-proven" }
      )
      blockers = @(
        "Nightly Rust and cargo-fuzz are not part of the current local baseline.",
        "Source-built libsvn/APR/bridge sanitizer coverage instrumentation has not been proven.",
        "The source-created native remote-protocol fuzz target has not produced build, run, crash, or edge-growth evidence."
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

function New-NativeRemoteFuzzTargetFixture([string]$Root) {
  $contractPath = Join-Path $Root "docs\security\native-remote-fuzz-contract.win32-x64.json"
  $corpusPath = Join-Path $Root "docs\security\malicious-input-corpus.win32-x64.json"
  $matrixPath = Join-Path $Root "docs\release\security-evidence-matrix.md"
  $fuzzManifestPath = Join-Path $Root "fuzz\Cargo.toml"
  $fuzzTargetPath = Join-Path $Root "fuzz\fuzz_targets\svn_server_response_history_log.rs"
  $seedManifestPath = Join-Path $Root "fuzz\corpus\svn_server_response_history_log\manifest.json"
  $outputPath = Join-Path $Root "target\release-evidence\subversionr-native-remote-fuzz-target-preflight-win32-x64.json"
  New-NativeRemoteFuzzContract -Path $contractPath
  New-MaliciousInputCorpus -Path $corpusPath
  New-SecurityEvidenceMatrix -Path $matrixPath
  New-FuzzManifest -Path $fuzzManifestPath
  New-FuzzTargetSource -Path $fuzzTargetPath
  New-SeedManifest -Root $Root | Out-Null

  [pscustomobject]@{
    root = $Root
    contractPath = $contractPath
    corpusPath = $corpusPath
    matrixPath = $matrixPath
    fuzzManifestPath = $fuzzManifestPath
    fuzzTargetPath = $fuzzTargetPath
    seedManifestPath = $seedManifestPath
    outputPath = $outputPath
  }
}

function Invoke-GenerateNativeRemoteFuzzTargetPreflight([object]$Fixture, [string]$OutputPath) {
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $generateScript `
    -Target win32-x64 `
    -ContractPath $Fixture.contractPath `
    -MaliciousInputCorpusPath $Fixture.corpusPath `
    -SecurityEvidenceMatrixPath $Fixture.matrixPath `
    -FuzzManifestPath $Fixture.fuzzManifestPath `
    -FuzzTargetPath $Fixture.fuzzTargetPath `
    -SeedManifestPath $Fixture.seedManifestPath `
    -OutputPath $OutputPath
}

$tempRoot = Join-Path $repoRoot "target\tests\release-native-remote-fuzz-target-preflight-scripts\$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  Assert-True (Test-Path -LiteralPath $generateScript -PathType Leaf) "generate-native-remote-fuzz-target-preflight.ps1 should exist."
  Assert-True (Test-Path -LiteralPath $verifyScript -PathType Leaf) "verify-native-remote-fuzz-target-preflight.ps1 should exist."

  $fixture = New-NativeRemoteFuzzTargetFixture $tempRoot
  Invoke-GenerateNativeRemoteFuzzTargetPreflight -Fixture $fixture -OutputPath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "generate-native-remote-fuzz-target-preflight.ps1 failed with exit code $LASTEXITCODE."
  }

  $report = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  Assert-Equal "subversionr.release.native-remote-fuzz-target-preflight.win32-x64.v1" $report.schema "Native remote fuzz target preflight evidence should use the release schema."
  Assert-Equal "True" ([string]$report.sourceTargetPreflight) "Native remote fuzz target preflight should mark only the source preflight true."
  Assert-Equal "False" ([string]$report.publicReadinessClaim) "Native remote fuzz target preflight must not claim public readiness."
  Assert-Equal "False" ([string]$report.completeFuzzClaim) "Native remote fuzz target preflight must not claim complete fuzzing."
  Assert-Equal "False" ([string]$report.coverageGuidedLibsvnClaim) "Native remote fuzz target preflight must not claim coverage-guided libsvn fuzzing."
  Assert-Equal "False" ([string]$report.fuzzBuildPerformed) "Native remote fuzz target preflight must not claim a cargo-fuzz build."
  Assert-Equal "False" ([string]$report.fuzzRunPerformed) "Native remote fuzz target preflight must not claim a fuzz run."
  Assert-Equal "False" ([string]$report.seedExecutionPerformed) "Native remote fuzz target preflight must not claim seed execution."
  Assert-Equal "False" ([string]$report.sanitizerCoverageProven) "Native remote fuzz target preflight must not claim sanitizer coverage."
  Assert-Equal (Get-Sha256 $fixture.fuzzManifestPath) $report.inputs.fuzzManifest.sha256 "Evidence should bind the fuzz package manifest."
  Assert-Equal (Get-Sha256 $fixture.fuzzTargetPath) $report.inputs.fuzzTarget.sha256 "Evidence should bind the fuzz target source."
  Assert-Equal (Get-Sha256 $fixture.seedManifestPath) $report.inputs.seedManifest.sha256 "Evidence should bind the seed corpus manifest."
  Assert-Equal "source-created" $report.sourcePreflight.status "Evidence should record a source-created target only."
  Assert-Equal "not-run" $report.execution.fuzzRun.status "Evidence should record fuzz execution as not-run."
  Assert-Equal "not-proven" $report.execution.coverage.status "Evidence should record coverage as not-proven."
  foreach ($seed in @($report.seedCorpus.seeds)) {
    $seedPath = Join-Path $repoRoot ([string]$seed.path).Replace("/", [System.IO.Path]::DirectorySeparatorChar)
    Assert-Equal (Get-Sha256 $seedPath) $seed.sha256 "Evidence should bind seed file hashes."
  }

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
    -Target win32-x64 `
    -EvidencePath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "verify-native-remote-fuzz-target-preflight.ps1 failed with exit code $LASTEXITCODE."
  }

  $fixture = New-NativeRemoteFuzzTargetFixture (Join-Path $tempRoot "target-network-overreach")
  New-FuzzTargetSource -Path $fixture.fuzzTargetPath -ExtraText "fn forbidden_socket_marker() { let _ = std::net::TcpStream::connect; }"
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateNativeRemoteFuzzTargetPreflight -Fixture $fixture -OutputPath $fixture.outputPath
  } "network, process, filesystem, unsafe, or FFI APIs" "Native remote fuzz target preflight should reject source that opens external execution paths."

  $fixture = New-NativeRemoteFuzzTargetFixture (Join-Path $tempRoot "missing-source-preflight")
  $badContract = Get-Content -Raw -LiteralPath $fixture.contractPath | ConvertFrom-Json
  $badContract.PSObject.Properties.Remove("sourcePreflight")
  Write-JsonFile $fixture.contractPath $badContract
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateNativeRemoteFuzzTargetPreflight -Fixture $fixture -OutputPath $fixture.outputPath
  } "sourcePreflight" "Native remote fuzz target preflight should require sourcePreflight contract fields."

  $fixture = New-NativeRemoteFuzzTargetFixture (Join-Path $tempRoot "matrix-overclaim")
  New-SecurityEvidenceMatrix -Path $fixture.matrixPath -Sec016Status "verified"
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateNativeRemoteFuzzTargetPreflight -Fixture $fixture -OutputPath $fixture.outputPath
  } "SEC-016" "Native remote fuzz target preflight should reject evidence-matrix overclaims."

  $fixture = New-NativeRemoteFuzzTargetFixture (Join-Path $tempRoot "missing-corpus-blocker")
  New-MaliciousInputCorpus -Path $fixture.corpusPath -BlockerStatus "covered"
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateNativeRemoteFuzzTargetPreflight -Fixture $fixture -OutputPath $fixture.outputPath
  } "NATIVE-REMOTE-FUZZ-001" "Native remote fuzz target preflight should require the malicious corpus release blocker."

  $fixture = New-NativeRemoteFuzzTargetFixture (Join-Path $tempRoot "seed-hash-drift")
  New-FileWithText -Path (Join-Path $fixture.root "fuzz\corpus\svn_server_response_history_log\malicious-log-response.seed") -Text "changed seed bytes"
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateNativeRemoteFuzzTargetPreflight -Fixture $fixture -OutputPath $fixture.outputPath
  } "sha256" "Native remote fuzz target preflight should reject seed hash drift."

  $fixture = New-NativeRemoteFuzzTargetFixture (Join-Path $tempRoot "evidence-overclaim")
  Invoke-GenerateNativeRemoteFuzzTargetPreflight -Fixture $fixture -OutputPath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "generate-native-remote-fuzz-target-preflight.ps1 failed for overclaim fixture with exit code $LASTEXITCODE."
  }
  $tamperedReportPath = Join-Path $tempRoot "tampered-overclaim.json"
  $tamperedReport = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tamperedReport.fuzzRunPerformed = $true
  Write-JsonFile $tamperedReportPath $tamperedReport
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
      -Target win32-x64 `
      -EvidencePath $tamperedReportPath
  } "fuzzRunPerformed" "Native remote fuzz target preflight verification should reject fuzz-run overclaims."

  $fixture = New-NativeRemoteFuzzTargetFixture (Join-Path $tempRoot "hash-drift")
  Invoke-GenerateNativeRemoteFuzzTargetPreflight -Fixture $fixture -OutputPath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "generate-native-remote-fuzz-target-preflight.ps1 failed for hash drift fixture with exit code $LASTEXITCODE."
  }
  Add-Content -LiteralPath $fixture.fuzzTargetPath -Value "// drift"
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
      -Target win32-x64 `
      -EvidencePath $fixture.outputPath
  } "sha256" "Native remote fuzz target preflight verification should reject input hash drift."

  $fixture = New-NativeRemoteFuzzTargetFixture (Join-Path $tempRoot "outside-output")
  $badOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "subversionr-native-remote-fuzz-target-preflight-outside-target.json"
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateNativeRemoteFuzzTargetPreflight -Fixture $fixture -OutputPath $badOutputPath
  } "OutputPath must resolve inside" "Native remote fuzz target preflight generation should reject output paths outside target."

  $packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  Assert-True ($packageJson.scripts."release:test-native-remote-fuzz-target-preflight-scripts".Contains("release-native-remote-fuzz-target-preflight-scripts.tests.ps1")) "Root package should expose native remote fuzz target preflight script tests."
  Assert-True ($packageJson.scripts."release:generate-native-remote-fuzz-target-preflight:win32-x64".Contains("generate-native-remote-fuzz-target-preflight.ps1")) "Root package should expose native remote fuzz target preflight generation."
  Assert-True ($packageJson.scripts."release:verify-native-remote-fuzz-target-preflight:win32-x64".Contains("verify-native-remote-fuzz-target-preflight.ps1")) "Root package should expose native remote fuzz target preflight verification."
  $prFastWorkflow = Get-Content -Raw -LiteralPath $prFastWorkflowPath
  Assert-True ($prFastWorkflow.Contains("pnpm release:test-native-remote-fuzz-target-preflight-scripts")) "PR Fast should run native remote fuzz target preflight script tests."
  Assert-True ($prFastWorkflow.Contains("pnpm release:generate-native-remote-fuzz-target-preflight:win32-x64")) "PR Fast should generate native remote fuzz target preflight evidence."
  Assert-True ($prFastWorkflow.Contains("pnpm release:verify-native-remote-fuzz-target-preflight:win32-x64")) "PR Fast should verify native remote fuzz target preflight evidence."

  Write-Host "Release native remote fuzz target preflight script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

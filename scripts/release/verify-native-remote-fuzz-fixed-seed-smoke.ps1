[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$EvidencePath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$allowedEvidenceRoots = @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-native-remote-fuzz-fixed-seed-smoke-scripts"))
)
$requiredTraceIds = @("SEC-016", "TST-020")
$requiredEvidenceStatuses = @{
  "instrumented-libsvn-build" = "not-proven"
  "fuzzer-target" = "source-created"
  "seed-corpus" = "source-created"
  "fixed-seed-smoke" = "local-smoke-required"
  "run-evidence" = "not-run"
  "coverage-evidence" = "not-proven"
}
$requiredNonClaims = @(
  "This gate is a fixed-input cargo-fuzz smoke, not a coverage-guided fuzz campaign.",
  "This gate proves only cargo-fuzz build and fixed seed execution for the Rust harness.",
  "This gate does not call libsvn or prove native FFI parser depth.",
  "This gate does not prove sanitizer coverage, libsvn edge growth, crash discovery, provider-complete remote-protocol fuzzing, or public release readiness.",
  "This gate does not close SEC-016, TST-020, or NATIVE-REMOTE-FUZZ-001."
)

function Get-RepoAbsolutePath([string]$Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Test-IsPathWithin([string]$Path, [string]$Root) {
  $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  $pathFull = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  $pathFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-GeneratedPath([string]$Path, [string]$Name, [string[]]$AllowedRoots, [string]$Description) {
  $absolute = Get-RepoAbsolutePath $Path
  foreach ($allowedRoot in $AllowedRoots) {
    if (Test-IsPathWithin -Path $absolute -Root $allowedRoot) {
      return $absolute
    }
  }
  throw "$Name must resolve inside $Description`: $Path"
}

function Assert-File([string]$Path, [string]$Name) {
  $absolute = Get-RepoAbsolutePath $Path
  if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) {
    throw "$Name must be a file: $Path"
  }
  (Resolve-Path -LiteralPath $absolute -ErrorAction Stop).Path
}

function Get-Sha256([string]$Path) {
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-HasProperty([object]$Object, [string]$Name) {
  $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
  if ($Expected -ne $Actual) {
    throw "$Message Expected '$Expected', got '$Actual'."
  }
}

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw $Message
  }
}

function Assert-RequiredString([object]$Object, [string]$Name, [string]$Context) {
  if (-not (Test-HasProperty $Object $Name) -or [string]::IsNullOrWhiteSpace([string]$Object.$Name)) {
    throw "$Context must define $Name."
  }
  [string]$Object.$Name
}

function Get-StringArray([object]$Object, [string]$Name, [string]$Context) {
  if (-not (Test-HasProperty $Object $Name)) {
    throw "$Context must define $Name."
  }
  $values = @($Object.$Name | ForEach-Object { [string]$_ })
  Assert-True ($values.Count -gt 0) "$Context $Name must not be empty."
  foreach ($value in $values) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($value)) "$Context $Name must not contain empty values."
  }
  $values
}

function Assert-BooleanFalse([object]$Object, [string]$Name, [string]$Context) {
  if (-not (Test-HasProperty $Object $Name)) {
    throw "$Context must define $Name."
  }
  Assert-Equal "False" ([string]$Object.$Name) "$Context $Name must remain false."
}

function Assert-BooleanTrue([object]$Object, [string]$Name, [string]$Context) {
  if (-not (Test-HasProperty $Object $Name)) {
    throw "$Context must define $Name."
  }
  Assert-Equal "True" ([string]$Object.$Name) "$Context $Name must remain true."
}

function Assert-ArrayContainsExactlyOnce([object[]]$Values, [string]$Expected, [string]$Context) {
  Assert-True (@($Values | Where-Object { [string]$_ -eq $Expected }).Count -eq 1) "$Context must include '$Expected'."
}

function Assert-NormalizedRepoPath([string]$Path, [string]$Context) {
  Assert-True (-not [System.IO.Path]::IsPathRooted($Path)) "$Context must use a repository-relative path."
  $normalized = $Path.Replace("\", "/")
  Assert-True (-not $normalized.StartsWith("/")) "$Context must not start with a slash."
  Assert-True (-not ($normalized -match "(^|/)\.\.($|/)")) "$Context must not contain parent traversal segments."
  Assert-True (-not ($normalized -match "(^|/)\.($|/)")) "$Context must not contain current-directory traversal segments."
  $normalized
}

function Assert-NoCredentialEvidenceText([string]$Text, [string]$Context) {
  $patterns = @(
    'ghp_[A-Za-z0-9_]{20,}',
    'github_pat_[A-Za-z0-9_]+',
    '://[^/\s:@"]+:[^/\s:@"]+@',
    '(?i)Authorization:\s*Bearer\s+',
    '(?i)"token(Value)?"\s*:',
    '(?i)"credential"\s*:',
    '(?i)"password"\s*:',
    '(?i)"secret"\s*:'
  )
  foreach ($pattern in $patterns) {
    if ($Text -match $pattern) {
      throw "$Context must not record credentials, tokens, authorization headers, passwords, or secrets."
    }
  }
}

function Assert-NoForbiddenOverclaimText([string]$Text, [string]$Context) {
  $patterns = @(
    '(?i)"coverageGuidedFuzzRunPerformed"\s*:\s*true',
    '(?i)"coverageGuidedLibsvnClaim"\s*:\s*true',
    '(?i)"coverageEvidenceRecorded"\s*:\s*true',
    '(?i)"providerCompleteFuzzClaim"\s*:\s*true',
    '(?i)"libsvnFfiReached"\s*:\s*true',
    '(?i)"sanitizerCoverageProven"\s*:\s*true',
    '(?i)"libsvnEdgeGrowthProven"\s*:\s*true',
    '(?i)"publicReadinessClaim"\s*:\s*true',
    '(?i)"completeFuzzClaim"\s*:\s*true'
  )
  foreach ($pattern in $patterns) {
    if ($Text -match $pattern) {
      throw "$Context must not record overclaim matching $pattern."
    }
  }
}

function Assert-MatrixReleaseBlocker([string]$MatrixText, [string]$TraceId) {
  $pattern = "\|\s*``?$TraceId``?\s*\|\s*release-blocker\s*\|"
  if ($MatrixText -notmatch $pattern) {
    throw "$TraceId must remain release-blocker in the security evidence matrix for this fixed seed smoke gate."
  }
}

function Assert-SecurityEvidenceMatrix([string]$MatrixText) {
  Assert-MatrixReleaseBlocker -MatrixText $MatrixText -TraceId "SEC-016"
  Assert-MatrixReleaseBlocker -MatrixText $MatrixText -TraceId "TST-020"
  Assert-True ($MatrixText.IndexOf("native remote-protocol fixed seed harness smoke", [System.StringComparison]::OrdinalIgnoreCase) -ge 0) "Security evidence matrix must name the native remote-protocol fixed seed harness smoke gate."
}

function Assert-HashRecord([object]$Record, [string]$Context) {
  $path = Assert-RequiredString $Record "path" $Context
  $sha256 = Assert-RequiredString $Record "sha256" $Context
  $resolved = Assert-File $path $Context
  Assert-Equal $sha256 (Get-Sha256 $resolved) "$Context sha256 should match current bytes."
  $resolved
}

function Assert-MaliciousInputCorpusBlocker([object]$Corpus, [string]$BlockerEntryId) {
  Assert-Equal 1 ([int]$Corpus.schemaVersion) "Malicious input corpus schemaVersion must be stable."
  Assert-Equal "subversionr.security.malicious-input-corpus.win32-x64.v1" ([string]$Corpus.schema) "Malicious input corpus schema must match."
  Assert-Equal $Target ([string]$Corpus.target) "Malicious input corpus target must match."
  Assert-BooleanFalse $Corpus "publicReadinessClaim" "Malicious input corpus"
  Assert-BooleanFalse $Corpus "completeFuzzClaim" "Malicious input corpus"
  Assert-BooleanTrue $Corpus "localCorpusOnly" "Malicious input corpus"
  $blockerEntries = @($Corpus.entries | Where-Object { [string]$_.id -eq $BlockerEntryId })
  Assert-Equal 1 $blockerEntries.Count "Malicious input corpus must define the native remote fuzz blocker entry once."
  Assert-Equal "release-blocker" ([string]$blockerEntries[0].status) "Malicious input corpus $BlockerEntryId must remain release-blocker."
}

function Assert-ContractShape([object]$Contract) {
  Assert-Equal 1 ([int]$Contract.schemaVersion) "Native remote fuzz contract schemaVersion must be stable."
  Assert-Equal "subversionr.security.native-remote-fuzz-contract.win32-x64.v1" ([string]$Contract.schema) "Native remote fuzz contract schema must match."
  Assert-Equal $Target ([string]$Contract.target) "Native remote fuzz contract target must match."
  Assert-BooleanFalse $Contract "publicReadinessClaim" "Native remote fuzz contract"
  Assert-BooleanFalse $Contract "completeFuzzClaim" "Native remote fuzz contract"
  Assert-BooleanFalse $Contract "coverageGuidedLibsvnClaim" "Native remote fuzz contract"
  Assert-BooleanTrue $Contract "localPreflightOnly" "Native remote fuzz contract"
  foreach ($traceId in $requiredTraceIds) {
    Assert-ArrayContainsExactlyOnce -Values (Get-StringArray $Contract "requiredTraceIds" "Native remote fuzz contract") -Expected $traceId -Context "Native remote fuzz contract requiredTraceIds"
  }
  Assert-Equal "NATIVE-REMOTE-FUZZ-001" (Assert-RequiredString $Contract "blockerEntryId" "Native remote fuzz contract") "Native remote fuzz contract must bind the native remote fuzz blocker entry."
  $sourcePreflight = if (Test-HasProperty $Contract "sourcePreflight") { $Contract.sourcePreflight } else { throw "Native remote fuzz contract must define sourcePreflight." }
  Assert-Equal "svn_server_response_history_log" (Assert-RequiredString $sourcePreflight "targetName" "Native remote fuzz contract sourcePreflight") "Native remote fuzz sourcePreflight targetName should match."
  foreach ($evidenceId in $requiredEvidenceStatuses.Keys) {
    $matches = @($Contract.requiredEvidence | Where-Object { [string]$_.id -eq $evidenceId })
    Assert-Equal 1 $matches.Count "Native remote fuzz contract requiredEvidence must include $evidenceId once."
    Assert-Equal "True" ([string]$matches[0].required) "Native remote fuzz contract requiredEvidence $evidenceId must be required."
    Assert-Equal $requiredEvidenceStatuses[$evidenceId] ([string]$matches[0].status) "Native remote fuzz contract requiredEvidence $evidenceId status should match fixed seed smoke state."
  }
  $currentStatus = if (Test-HasProperty $Contract "currentStatus") { $Contract.currentStatus } else { throw "Native remote fuzz contract must define currentStatus." }
  Assert-Equal "blocked" (Assert-RequiredString $currentStatus "status" "Native remote fuzz contract currentStatus") "Native remote fuzz contract currentStatus must remain blocked."
  Assert-BooleanFalse $currentStatus "publicReadinessAllowed" "Native remote fuzz contract currentStatus"
  $Contract
}

function Assert-FuzzInputs([object]$Inputs, [object]$SourcePreflight) {
  $fuzzManifestResolved = Assert-HashRecord $Inputs.fuzzManifest "Fuzz manifest input"
  $fuzzLockResolved = Assert-HashRecord $Inputs.fuzzLock "Fuzz lock input"
  $fuzzTargetResolved = Assert-HashRecord $Inputs.fuzzTarget "Fuzz target input"
  $seedManifestResolved = Assert-HashRecord $Inputs.seedManifest "Seed manifest input"
  $fixedSeedResolved = Assert-HashRecord $Inputs.fixedSeed "Fixed seed input"

  Assert-Equal (Assert-NormalizedRepoPath ([string]$SourcePreflight.packageManifest) "sourcePreflight.packageManifest") ([string]$Inputs.fuzzManifest.path) "Fuzz manifest path should match sourcePreflight."
  Assert-Equal (Assert-NormalizedRepoPath ([string]$SourcePreflight.targetPath) "sourcePreflight.targetPath") ([string]$Inputs.fuzzTarget.path) "Fuzz target path should match sourcePreflight."
  Assert-Equal (Assert-NormalizedRepoPath ([string]$SourcePreflight.seedCorpusManifest) "sourcePreflight.seedCorpusManifest") ([string]$Inputs.seedManifest.path) "Seed manifest path should match sourcePreflight."

  $manifestText = Get-Content -Raw -LiteralPath $fuzzManifestResolved
  $lockText = Get-Content -Raw -LiteralPath $fuzzLockResolved
  $targetText = Get-Content -Raw -LiteralPath $fuzzTargetResolved
  $seedManifestText = Get-Content -Raw -LiteralPath $seedManifestResolved
  $fixedSeedText = Get-Content -Raw -LiteralPath $fixedSeedResolved
  Assert-NoCredentialEvidenceText $manifestText "Fuzz manifest"
  Assert-NoCredentialEvidenceText $lockText "Fuzz lock"
  Assert-NoCredentialEvidenceText $targetText "Fuzz target"
  Assert-NoCredentialEvidenceText $seedManifestText "Seed manifest"
  Assert-NoCredentialEvidenceText $fixedSeedText "Fixed seed"
  Assert-True ($manifestText -match '(?m)^libfuzzer-sys\s*=\s*"=0\.4\.13"\s*$') "Fuzz manifest must pin libfuzzer-sys =0.4.13."
  Assert-True ($lockText.Contains('name = "libfuzzer-sys"')) "Fuzz lock must include libfuzzer-sys."
  Assert-True ($lockText.Contains('version = "0.4.13"')) "Fuzz lock must bind libfuzzer-sys 0.4.13."
  Assert-True ($lockText.Contains('name = "subversionr-native-remote-fuzz"')) "Fuzz lock must include the fuzz package."
  Assert-True ($targetText.Contains('fuzz_target!')) "Fuzz target must define a fuzz_target."

  $seedManifest = $seedManifestText | ConvertFrom-Json
  Assert-BooleanFalse $seedManifest "publicReadinessClaim" "Seed manifest"
  Assert-BooleanFalse $seedManifest "fuzzRunPerformed" "Seed manifest"
  Assert-BooleanFalse $seedManifest "coverageEvidenceRecorded" "Seed manifest"
  $seed = @($seedManifest.seeds | Where-Object { [string]$_.id -eq "malicious-log-response-v1" })
  Assert-Equal 1 $seed.Count "Seed manifest must include malicious-log-response-v1 once."
  Assert-Equal ([string]$seed[0].path) ([string]$Inputs.fixedSeed.path) "Fixed seed input path should match seed manifest."
  Assert-Equal ([string]$seed[0].sha256) ([string]$Inputs.fixedSeed.sha256) "Fixed seed input sha256 should match seed manifest."
}

$evidenceResolved = Assert-GeneratedPath -Path $EvidencePath -Name "EvidencePath" -AllowedRoots $allowedEvidenceRoots -Description "target/release-evidence or target/tests/release-native-remote-fuzz-fixed-seed-smoke-scripts"
$rawEvidence = Get-Content -Raw -LiteralPath $evidenceResolved
Assert-NoCredentialEvidenceText -Text $rawEvidence -Context "Native remote fuzz fixed seed smoke evidence"
Assert-NoForbiddenOverclaimText -Text $rawEvidence -Context "Native remote fuzz fixed seed smoke evidence"
$report = $rawEvidence | ConvertFrom-Json

Assert-Equal 1 ([int]$report.schemaVersion) "Native remote fuzz fixed seed smoke evidence schemaVersion should be stable."
Assert-Equal "subversionr.release.native-remote-fuzz-fixed-seed-smoke.win32-x64.v1" ([string]$report.schema) "Native remote fuzz fixed seed smoke evidence schema should match."
Assert-Equal $Target ([string]$report.target) "Native remote fuzz fixed seed smoke evidence target should match."
Assert-BooleanFalse $report "publicReadinessClaim" "Native remote fuzz fixed seed smoke evidence"
Assert-BooleanFalse $report "completeFuzzClaim" "Native remote fuzz fixed seed smoke evidence"
Assert-BooleanFalse $report "coverageGuidedLibsvnClaim" "Native remote fuzz fixed seed smoke evidence"
Assert-BooleanTrue $report "cargoFuzzBuildPerformed" "Native remote fuzz fixed seed smoke evidence"
Assert-BooleanTrue $report "fixedSeedExecutionPerformed" "Native remote fuzz fixed seed smoke evidence"
Assert-BooleanFalse $report "coverageGuidedFuzzRunPerformed" "Native remote fuzz fixed seed smoke evidence"
Assert-BooleanFalse $report "coverageEvidenceRecorded" "Native remote fuzz fixed seed smoke evidence"
Assert-BooleanFalse $report "libsvnFfiReached" "Native remote fuzz fixed seed smoke evidence"
Assert-BooleanFalse $report "sanitizerCoverageProven" "Native remote fuzz fixed seed smoke evidence"
Assert-BooleanFalse $report "libsvnEdgeGrowthProven" "Native remote fuzz fixed seed smoke evidence"
foreach ($traceId in $requiredTraceIds) {
  Assert-ArrayContainsExactlyOnce -Values @($report.traceIds) -Expected $traceId -Context "Native remote fuzz fixed seed smoke evidence traceIds"
}
Assert-Equal "NATIVE-REMOTE-FUZZ-001" (Assert-RequiredString $report "blockerEntryId" "Native remote fuzz fixed seed smoke evidence") "Native remote fuzz fixed seed smoke evidence must bind the native remote fuzz blocker entry."
foreach ($nonClaim in $requiredNonClaims) {
  Assert-ArrayContainsExactlyOnce -Values @($report.nonClaims) -Expected $nonClaim -Context "Native remote fuzz fixed seed smoke evidence nonClaims"
}

$inputs = if (Test-HasProperty $report "inputs") { $report.inputs } else { throw "Native remote fuzz fixed seed smoke evidence must define inputs." }
$contractResolved = Assert-HashRecord $inputs.contract "Native remote fuzz contract input"
$corpusResolved = Assert-HashRecord $inputs.maliciousInputCorpus "Malicious input corpus input"
$matrixResolved = Assert-HashRecord $inputs.securityEvidenceMatrix "Security evidence matrix input"

$contractRaw = Get-Content -Raw -LiteralPath $contractResolved
$corpusRaw = Get-Content -Raw -LiteralPath $corpusResolved
$matrixRaw = Get-Content -Raw -LiteralPath $matrixResolved
Assert-NoCredentialEvidenceText -Text $contractRaw -Context "Native remote fuzz contract"
Assert-NoCredentialEvidenceText -Text $corpusRaw -Context "Malicious input corpus"
Assert-NoCredentialEvidenceText -Text $matrixRaw -Context "Security evidence matrix"
Assert-NoForbiddenOverclaimText -Text $contractRaw -Context "Native remote fuzz contract"
Assert-NoForbiddenOverclaimText -Text $corpusRaw -Context "Malicious input corpus"
Assert-SecurityEvidenceMatrix -MatrixText $matrixRaw

$contract = Assert-ContractShape ($contractRaw | ConvertFrom-Json)
Assert-MaliciousInputCorpusBlocker -Corpus ($corpusRaw | ConvertFrom-Json) -BlockerEntryId ([string]$contract.blockerEntryId)
Assert-FuzzInputs -Inputs $inputs -SourcePreflight $contract.sourcePreflight

Assert-Equal ([string]$contract.scope.provider) ([string]$report.scope.provider) "Native remote fuzz fixed seed smoke scope provider should match contract."
Assert-Equal ([string]$contract.scope.operation) ([string]$report.scope.operation) "Native remote fuzz fixed seed smoke scope operation should match contract."
Assert-Equal ([string]$contract.sourcePreflight.targetName) ([string]$report.sourcePreflight.targetName) "Native remote fuzz fixed seed smoke target name should match contract."

Assert-Equal "rust-parser-only" (Assert-RequiredString $report.execution.harnessDepth "status" "Native remote fuzz fixed seed smoke harnessDepth execution") "fixed seed smoke harness depth must stay Rust-parser-only."
Assert-BooleanFalse $report.execution.harnessDepth "libsvnFfiReached" "Native remote fuzz fixed seed smoke harnessDepth execution"
Assert-Equal "passed" (Assert-RequiredString $report.execution.cargoFuzzBuild "status" "Native remote fuzz fixed seed smoke cargoFuzzBuild execution") "cargo-fuzz build must pass."
Assert-True ((Assert-RequiredString $report.execution.cargoFuzzBuild "command" "Native remote fuzz fixed seed smoke cargoFuzzBuild execution").Contains("cargo +nightly fuzz build")) "cargo-fuzz build command should be recorded without local paths."
Assert-RequiredString $report.execution.cargoFuzzBuild "sanitizedOutputSha256" "Native remote fuzz fixed seed smoke cargoFuzzBuild execution" | Out-Null
Assert-Equal "passed" (Assert-RequiredString $report.execution.fixedSeedRun "status" "Native remote fuzz fixed seed smoke fixedSeedRun execution") "fixed seed run must pass."
Assert-Equal "malicious-log-response-v1" (Assert-RequiredString $report.execution.fixedSeedRun "seedId" "Native remote fuzz fixed seed smoke fixedSeedRun execution") "fixed seed run seed id should match."
Assert-Equal ([string]$inputs.fixedSeed.path) (Assert-RequiredString $report.execution.fixedSeedRun "seedPath" "Native remote fuzz fixed seed smoke fixedSeedRun execution") "fixed seed run seed path should match input binding."
Assert-True ((Assert-RequiredString $report.execution.fixedSeedRun "libFuzzerNote" "Native remote fuzz fixed seed smoke fixedSeedRun execution").Contains("fuzzing was not performed")) "Fixed seed evidence should preserve the libFuzzer fixed-input note."
Assert-RequiredString $report.execution.fixedSeedRun "sanitizedOutputSha256" "Native remote fuzz fixed seed smoke fixedSeedRun execution" | Out-Null
Assert-Equal "not-run" (Assert-RequiredString $report.execution.coverageGuidedFuzzRun "status" "Native remote fuzz fixed seed smoke coverageGuidedFuzzRun execution") "coverage-guided fuzz run must remain not-run."
Assert-Equal "not-proven" (Assert-RequiredString $report.execution.coverage "status" "Native remote fuzz fixed seed smoke coverage execution") "coverage must remain not-proven."
Assert-BooleanFalse $report.execution.coverage "instrumentedLibsvn" "Native remote fuzz fixed seed smoke coverage execution"
Assert-BooleanFalse $report.execution.coverage "edgeGrowth" "Native remote fuzz fixed seed smoke coverage execution"
Assert-Equal "blocked" (Assert-RequiredString $report.currentStatus "status" "Native remote fuzz fixed seed smoke currentStatus") "Native remote fuzz fixed seed smoke currentStatus must remain blocked."
Assert-BooleanFalse $report.currentStatus "publicReadinessAllowed" "Native remote fuzz fixed seed smoke currentStatus"

foreach ($evidenceId in $requiredEvidenceStatuses.Keys) {
  $matches = @($report.requiredEvidence | Where-Object { [string]$_.id -eq $evidenceId })
  Assert-Equal 1 $matches.Count "Native remote fuzz fixed seed smoke requiredEvidence must include $evidenceId once."
  Assert-Equal "True" ([string]$matches[0].required) "Native remote fuzz fixed seed smoke requiredEvidence $evidenceId must be required."
  Assert-Equal $requiredEvidenceStatuses[$evidenceId] ([string]$matches[0].status) "Native remote fuzz fixed seed smoke requiredEvidence $evidenceId status should match fixed seed smoke state."
}

Write-Host "Verified SubversionR native remote fixed seed harness smoke for $Target at $evidenceResolved."

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$ContractPath,

  [Parameter(Mandatory = $true)]
  [string]$MaliciousInputCorpusPath,

  [Parameter(Mandatory = $true)]
  [string]$SecurityEvidenceMatrixPath,

  [Parameter(Mandatory = $true)]
  [string]$FuzzManifestPath,

  [Parameter(Mandatory = $true)]
  [string]$FuzzLockPath,

  [Parameter(Mandatory = $true)]
  [string]$FuzzTargetPath,

  [Parameter(Mandatory = $true)]
  [string]$SeedManifestPath,

  [Parameter(Mandatory = $true)]
  [string]$VsDevCmdPath,

  [Parameter(Mandatory = $true)]
  [string]$CargoExePath,

  [Parameter(Mandatory = $true)]
  [string]$OutputPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
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

function Get-RepoRelativePath([string]$Path) {
  [System.IO.Path]::GetRelativePath($repoRoot, $Path).Replace("\", "/")
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

function Resolve-RequiredCommand([string]$Command, [string]$Name) {
  if ([System.IO.Path]::IsPathRooted($Command) -or $Command.Contains("\") -or $Command.Contains("/")) {
    return Assert-File $Command $Name
  }
  $resolvedCommand = Get-Command -Name $Command -CommandType Application -ErrorAction Stop
  if ($null -eq $resolvedCommand -or [string]::IsNullOrWhiteSpace($resolvedCommand.Source)) {
    throw "$Name must resolve to an executable command: $Command"
  }
  (Resolve-Path -LiteralPath $resolvedCommand.Source -ErrorAction Stop).Path
}

function Get-Sha256([string]$Path) {
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TextSha256([string]$Text) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
  ([System.BitConverter]::ToString($hash) -replace "-", "").ToLowerInvariant()
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

function New-HashRecord([string]$Path) {
  $resolved = Assert-File $Path "hash input"
  [pscustomobject]@{
    path = Get-RepoRelativePath $resolved
    sha256 = Get-Sha256 $resolved
  }
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
  $Contract
}

function Assert-FuzzInputs([object]$Contract) {
  $manifestResolved = Assert-File $FuzzManifestPath "FuzzManifestPath"
  $lockResolved = Assert-File $FuzzLockPath "FuzzLockPath"
  $targetResolved = Assert-File $FuzzTargetPath "FuzzTargetPath"
  $seedManifestResolved = Assert-File $SeedManifestPath "SeedManifestPath"
  Assert-Equal (Assert-NormalizedRepoPath ([string]$Contract.sourcePreflight.packageManifest) "sourcePreflight.packageManifest") (Get-RepoRelativePath $manifestResolved) "Fuzz manifest path should match sourcePreflight."
  Assert-Equal (Assert-NormalizedRepoPath ([string]$Contract.sourcePreflight.targetPath) "sourcePreflight.targetPath") (Get-RepoRelativePath $targetResolved) "Fuzz target path should match sourcePreflight."
  Assert-Equal (Assert-NormalizedRepoPath ([string]$Contract.sourcePreflight.seedCorpusManifest) "sourcePreflight.seedCorpusManifest") (Get-RepoRelativePath $seedManifestResolved) "Seed manifest path should match sourcePreflight."

  $manifestText = Get-Content -Raw -LiteralPath $manifestResolved
  $lockText = Get-Content -Raw -LiteralPath $lockResolved
  $targetText = Get-Content -Raw -LiteralPath $targetResolved
  Assert-NoCredentialEvidenceText $manifestText "Fuzz manifest"
  Assert-NoCredentialEvidenceText $lockText "Fuzz lock"
  Assert-NoCredentialEvidenceText $targetText "Fuzz target"
  Assert-True ($manifestText -match '(?m)^libfuzzer-sys\s*=\s*"=0\.4\.13"\s*$') "Fuzz manifest must pin libfuzzer-sys =0.4.13."
  Assert-True ($lockText.Contains('name = "libfuzzer-sys"')) "Fuzz lock must include libfuzzer-sys."
  Assert-True ($lockText.Contains('version = "0.4.13"')) "Fuzz lock must bind libfuzzer-sys 0.4.13."
  Assert-True ($lockText.Contains('name = "subversionr-native-remote-fuzz"')) "Fuzz lock must include the fuzz package."
  Assert-True ($targetText.Contains('fuzz_target!')) "Fuzz target must define a fuzz_target."

  $seedRaw = Get-Content -Raw -LiteralPath $seedManifestResolved
  Assert-NoCredentialEvidenceText $seedRaw "Seed manifest"
  $seedManifest = $seedRaw | ConvertFrom-Json
  Assert-BooleanFalse $seedManifest "publicReadinessClaim" "Seed manifest"
  Assert-BooleanFalse $seedManifest "fuzzRunPerformed" "Seed manifest"
  Assert-BooleanFalse $seedManifest "coverageEvidenceRecorded" "Seed manifest"
  $seed = @($seedManifest.seeds | Where-Object { [string]$_.id -eq "malicious-log-response-v1" })
  Assert-Equal 1 $seed.Count "Seed manifest must include malicious-log-response-v1 once."
  $seedPath = Assert-NormalizedRepoPath (Assert-RequiredString $seed[0] "path" "Seed manifest seed") "Seed manifest seed path"
  $seedResolved = Assert-File $seedPath "Seed file"
  Assert-Equal ([string]$seed[0].sha256) (Get-Sha256 $seedResolved) "Seed file sha256 should match seed manifest."
  [pscustomobject]@{
    manifest = $manifestResolved
    lock = $lockResolved
    target = $targetResolved
    seedManifest = $seedManifestResolved
    seed = $seedResolved
    seedId = [string]$seed[0].id
  }
}

function ConvertTo-CmdArgument([string]$Value) {
  '"' + ($Value -replace '"', '""') + '"'
}

function Invoke-VsCargo([string[]]$Arguments, [string]$Name, [string]$WorkRoot) {
  $scriptRoot = Join-Path $WorkRoot "command-scripts"
  New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
  $scriptPath = Join-Path $scriptRoot "$Name.cmd"
  $argumentText = ($Arguments | ForEach-Object { ConvertTo-CmdArgument $_ }) -join " "
  $content = @(
    "@echo off",
    "call $(ConvertTo-CmdArgument $VsDevCmdPath) -arch=x64 -host_arch=x64 >nul",
    "if errorlevel 1 exit /b %errorlevel%",
    "cd /d $(ConvertTo-CmdArgument $repoRoot)",
    "$(ConvertTo-CmdArgument $CargoExePath) $argumentText",
    "exit /b %errorlevel%"
  ) -join [Environment]::NewLine
  Set-Content -LiteralPath $scriptPath -Value $content -Encoding ascii
  $output = & cmd.exe /d /c $scriptPath 2>&1
  [pscustomobject]@{
    name = $Name
    exitCode = $LASTEXITCODE
    output = ($output | Out-String)
  }
}

function ConvertTo-SanitizedOutput([string]$Text) {
  $sanitized = $Text.Replace([string]$repoRoot, "<repo>")
  if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $sanitized = $sanitized.Replace($env:USERPROFILE, "<home>")
  }
  $sanitized
}

$allowedOutputRoots = @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-native-remote-fuzz-fixed-seed-smoke-scripts"))
)
$outputResolved = Assert-GeneratedPath -Path $OutputPath -Name "OutputPath" -AllowedRoots $allowedOutputRoots -Description "target/release-evidence or target/tests/release-native-remote-fuzz-fixed-seed-smoke-scripts"
$workRoot = Join-Path (Split-Path -Parent $outputResolved) "native-remote-fuzz-fixed-seed-smoke-work"

$vsDevCmdResolved = Assert-File $VsDevCmdPath "VsDevCmdPath"
$cargoResolved = Resolve-RequiredCommand $CargoExePath "CargoExePath"
$contractResolved = Assert-File $ContractPath "ContractPath"
$corpusResolved = Assert-File $MaliciousInputCorpusPath "MaliciousInputCorpusPath"
$matrixResolved = Assert-File $SecurityEvidenceMatrixPath "SecurityEvidenceMatrixPath"
$contractRaw = Get-Content -Raw -LiteralPath $contractResolved
$corpusRaw = Get-Content -Raw -LiteralPath $corpusResolved
$matrixRaw = Get-Content -Raw -LiteralPath $matrixResolved
Assert-NoCredentialEvidenceText $contractRaw "Native remote fuzz contract"
Assert-NoCredentialEvidenceText $corpusRaw "Malicious input corpus"
Assert-NoCredentialEvidenceText $matrixRaw "Security evidence matrix"
Assert-NoForbiddenOverclaimText $contractRaw "Native remote fuzz contract"
Assert-NoForbiddenOverclaimText $corpusRaw "Malicious input corpus"
Assert-SecurityEvidenceMatrix $matrixRaw
$contract = Assert-ContractShape ($contractRaw | ConvertFrom-Json)
Assert-MaliciousInputCorpusBlocker ($corpusRaw | ConvertFrom-Json) ([string]$contract.blockerEntryId)
$fuzzInputs = Assert-FuzzInputs $contract

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputResolved) | Out-Null
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null

$versionResult = Invoke-VsCargo -Arguments @("fuzz", "--version") -Name "cargo-fuzz-version" -WorkRoot $workRoot
if ($versionResult.exitCode -ne 0) {
  throw "cargo fuzz --version failed with exit code $($versionResult.exitCode): $($versionResult.output)"
}
$nightlyResult = Invoke-VsCargo -Arguments @("+nightly", "--version") -Name "cargo-nightly-version" -WorkRoot $workRoot
if ($nightlyResult.exitCode -ne 0) {
  throw "cargo +nightly --version failed with exit code $($nightlyResult.exitCode): $($nightlyResult.output)"
}
$buildResult = Invoke-VsCargo -Arguments @("+nightly", "fuzz", "build", [string]$contract.sourcePreflight.targetName) -Name "cargo-fuzz-build" -WorkRoot $workRoot
if ($buildResult.exitCode -ne 0) {
  throw "cargo-fuzz build failed with exit code $($buildResult.exitCode): $($buildResult.output)"
}
$seedRelativePath = Get-RepoRelativePath $fuzzInputs.seed
$runResult = Invoke-VsCargo -Arguments @("+nightly", "fuzz", "run", [string]$contract.sourcePreflight.targetName, $seedRelativePath, "--", "-runs=1", "-max_total_time=30") -Name "cargo-fuzz-fixed-seed-run" -WorkRoot $workRoot
if ($runResult.exitCode -ne 0) {
  throw "cargo-fuzz fixed seed run failed with exit code $($runResult.exitCode): $($runResult.output)"
}

$runOutput = ConvertTo-SanitizedOutput $runResult.output
Assert-True ($runOutput.Contains("fuzzing was not performed")) "Fixed seed run output must include the libFuzzer fixed-input note."
Assert-True ($runOutput.Contains("Executed")) "Fixed seed run output must record fixed input execution."
$buildOutput = ConvertTo-SanitizedOutput $buildResult.output

$report = [pscustomobject]@{
  schemaVersion = 1
  schema = "subversionr.release.native-remote-fuzz-fixed-seed-smoke.win32-x64.v1"
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
  target = $Target
  publicReadinessClaim = $false
  completeFuzzClaim = $false
  coverageGuidedLibsvnClaim = $false
  cargoFuzzBuildPerformed = $true
  fixedSeedExecutionPerformed = $true
  coverageGuidedFuzzRunPerformed = $false
  coverageEvidenceRecorded = $false
  libsvnFfiReached = $false
  sanitizerCoverageProven = $false
  libsvnEdgeGrowthProven = $false
  traceIds = $requiredTraceIds
  blockerEntryId = [string]$contract.blockerEntryId
  scope = $contract.scope
  sourcePreflight = $contract.sourcePreflight
  toolchain = [pscustomobject]@{
    cargoFuzzVersion = (($versionResult.output -split "`r?`n") | Where-Object { $_.Trim().Length -gt 0 } | Select-Object -First 1).Trim()
    nightlyCargoVersion = (($nightlyResult.output -split "`r?`n") | Where-Object { $_.Trim().Length -gt 0 } | Select-Object -First 1).Trim()
    vsDevCmd = "provided"
    msvcDeveloperEnvironment = "x64"
  }
  inputs = [pscustomobject]@{
    contract = New-HashRecord $contractResolved
    maliciousInputCorpus = New-HashRecord $corpusResolved
    securityEvidenceMatrix = New-HashRecord $matrixResolved
    fuzzManifest = New-HashRecord $fuzzInputs.manifest
    fuzzLock = New-HashRecord $fuzzInputs.lock
    fuzzTarget = New-HashRecord $fuzzInputs.target
    seedManifest = New-HashRecord $fuzzInputs.seedManifest
    fixedSeed = New-HashRecord $fuzzInputs.seed
  }
  requiredEvidence = @($contract.requiredEvidence)
  execution = [pscustomobject]@{
    harnessDepth = [pscustomobject]@{
      status = "rust-parser-only"
      libsvnFfiReached = $false
      reason = "The M7l9 source-controlled harness intentionally avoids FFI; source-built libsvn sanitizer coverage remains a future gate."
    }
    cargoFuzzBuild = [pscustomobject]@{
      status = "passed"
      command = "cargo +nightly fuzz build svn_server_response_history_log"
      sanitizedOutputSha256 = Get-TextSha256 $buildOutput
    }
    fixedSeedRun = [pscustomobject]@{
      status = "passed"
      command = "cargo +nightly fuzz run svn_server_response_history_log <fixed-seed> -- -runs=1 -max_total_time=30"
      seedId = $fuzzInputs.seedId
      seedPath = Get-RepoRelativePath $fuzzInputs.seed
      libFuzzerNote = "fuzzing was not performed; the target code executed on a fixed input"
      sanitizedOutputSha256 = Get-TextSha256 $runOutput
    }
    coverageGuidedFuzzRun = [pscustomobject]@{
      status = "not-run"
      reason = "This gate executes one fixed seed only and is not a coverage-guided fuzz campaign."
    }
    coverage = [pscustomobject]@{
      status = "not-proven"
      instrumentedLibsvn = $false
      edgeGrowth = $false
      reason = "Source-built libsvn/APR/bridge sanitizer coverage instrumentation remains unproven."
    }
  }
  blockers = @($contract.blockers)
  nonClaims = $requiredNonClaims
  currentStatus = $contract.currentStatus
}

$report | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $outputResolved -Encoding utf8
Write-Host "Generated SubversionR native remote fixed seed harness smoke for $Target at $outputResolved."

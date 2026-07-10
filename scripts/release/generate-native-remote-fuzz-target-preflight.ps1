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
  [string]$FuzzTargetPath,

  [Parameter(Mandatory = $true)]
  [string]$SeedManifestPath,

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
  "run-evidence" = "not-run"
  "coverage-evidence" = "not-proven"
}
$requiredNonClaims = @(
  "This gate is a source-controlled fuzz target preflight, not a coverage-guided fuzz run.",
  "This gate does not compile, link, run, or execute cargo-fuzz.",
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

function Assert-Directory([string]$Path, [string]$Name) {
  $absolute = Get-RepoAbsolutePath $Path
  if (-not (Test-Path -LiteralPath $absolute -PathType Container)) {
    throw "$Name must be a directory: $Path"
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
    '(?i)"fuzzBuildPerformed"\s*:\s*true',
    '(?i)"fuzzRunPerformed"\s*:\s*true',
    '(?i)"seedExecutionPerformed"\s*:\s*true',
    '(?i)"coverageEvidenceRecorded"\s*:\s*true',
    '(?i)"providerCompleteFuzzClaim"\s*:\s*true',
    '(?i)"sanitizerCoverageProven"\s*:\s*true',
    '(?i)"libsvnEdgeGrowthProven"\s*:\s*true'
  )
  foreach ($pattern in $patterns) {
    if ($Text -match $pattern) {
      throw "$Context must not record fuzz-build, fuzz-run, seed-execution, sanitizer-coverage, libsvn-edge-growth, provider-complete, or coverage-evidence overclaims."
    }
  }
}

function Assert-MatrixReleaseBlocker([string]$MatrixText, [string]$TraceId) {
  $pattern = "\|\s*``?$TraceId``?\s*\|\s*release-blocker\s*\|"
  if ($MatrixText -notmatch $pattern) {
    throw "$TraceId must remain release-blocker in the security evidence matrix for this native remote fuzz target preflight gate."
  }
}

function Assert-SecurityEvidenceMatrix([string]$MatrixText) {
  Assert-MatrixReleaseBlocker -MatrixText $MatrixText -TraceId "SEC-016"
  Assert-MatrixReleaseBlocker -MatrixText $MatrixText -TraceId "TST-020"
  Assert-True ($MatrixText.IndexOf("native remote-protocol fuzz target source preflight", [System.StringComparison]::OrdinalIgnoreCase) -ge 0) "Security evidence matrix must name the native remote-protocol fuzz target source preflight."
}

function New-HashRecord([string]$Path) {
  $resolved = Assert-File $Path "hash input"
  [pscustomobject]@{
    path = Get-RepoRelativePath $resolved
    sha256 = Get-Sha256 $resolved
  }
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
  Assert-RequiredString $blockerEntries[0] "blocker" "Malicious input corpus $BlockerEntryId" | Out-Null
}

function Assert-ContractShape([object]$Contract) {
  Assert-Equal 1 ([int]$Contract.schemaVersion) "Native remote fuzz contract schemaVersion must be stable."
  Assert-Equal "subversionr.security.native-remote-fuzz-contract.win32-x64.v1" ([string]$Contract.schema) "Native remote fuzz contract schema must match."
  Assert-Equal $Target ([string]$Contract.target) "Native remote fuzz contract target must match."
  Assert-BooleanFalse $Contract "publicReadinessClaim" "Native remote fuzz contract"
  Assert-BooleanFalse $Contract "completeFuzzClaim" "Native remote fuzz contract"
  Assert-BooleanFalse $Contract "coverageGuidedLibsvnClaim" "Native remote fuzz contract"
  Assert-BooleanTrue $Contract "localPreflightOnly" "Native remote fuzz contract"

  $traceIds = Get-StringArray $Contract "requiredTraceIds" "Native remote fuzz contract"
  foreach ($traceId in $requiredTraceIds) {
    Assert-ArrayContainsExactlyOnce -Values $traceIds -Expected $traceId -Context "Native remote fuzz contract requiredTraceIds"
  }
  Assert-Equal "NATIVE-REMOTE-FUZZ-001" (Assert-RequiredString $Contract "blockerEntryId" "Native remote fuzz contract") "Native remote fuzz contract must bind the native remote fuzz blocker entry."

  $scope = if (Test-HasProperty $Contract "scope") { $Contract.scope } else { throw "Native remote fuzz contract must define scope." }
  Assert-Equal "svn://" (Assert-RequiredString $scope "provider" "Native remote fuzz contract scope") "Native remote fuzz contract should start with the svn:// provider."
  Assert-Equal "history/log" (Assert-RequiredString $scope "operation" "Native remote fuzz contract scope") "Native remote fuzz contract should start with history/log."
  Get-StringArray $scope "seedCorpus" "Native remote fuzz contract scope" | Out-Null
  Get-StringArray $scope "excludedProviders" "Native remote fuzz contract scope" | Out-Null
  Assert-True ((Assert-RequiredString $scope "evidenceBoundary" "Native remote fuzz contract scope").Contains("Readiness contract only")) "Native remote fuzz contract scope must keep a readiness-only evidence boundary."

  $sourcePreflight = if (Test-HasProperty $Contract "sourcePreflight") { $Contract.sourcePreflight } else { throw "Native remote fuzz contract must define sourcePreflight." }
  Assert-Equal "source-created" (Assert-RequiredString $sourcePreflight "status" "Native remote fuzz contract sourcePreflight") "Native remote fuzz contract sourcePreflight status should be source-created."
  foreach ($field in @("packageManifest", "targetName", "targetPath", "seedCorpusDirectory", "seedCorpusManifest", "evidenceBoundary")) {
    Assert-RequiredString $sourcePreflight $field "Native remote fuzz contract sourcePreflight" | Out-Null
  }
  Assert-Equal "svn_server_response_history_log" ([string]$sourcePreflight.targetName) "Native remote fuzz sourcePreflight targetName should match the first target."
  Assert-True ([string]$sourcePreflight.evidenceBoundary -match "Source preflight only") "Native remote fuzz sourcePreflight must keep a source-only evidence boundary."

  $toolchain = if (Test-HasProperty $Contract "toolchainRequirements") { $Contract.toolchainRequirements } else { throw "Native remote fuzz contract must define toolchainRequirements." }
  Assert-Equal "nightly-x86_64-pc-windows-msvc" (Assert-RequiredString $toolchain "rustToolchain" "Native remote fuzz contract toolchain requirements") "Native remote fuzz contract must require the Windows MSVC nightly Rust toolchain."
  Assert-Equal "cargo-fuzz" (Assert-RequiredString $toolchain "cargoSubcommand" "Native remote fuzz contract toolchain requirements") "Native remote fuzz contract must require cargo-fuzz."
  Assert-Equal "MSVC cl.exe" (Assert-RequiredString $toolchain "msvcCompiler" "Native remote fuzz contract toolchain requirements") "Native remote fuzz contract must require MSVC cl.exe."
  $msvcFlags = Get-StringArray $toolchain "msvcFlags" "Native remote fuzz contract toolchain requirements"
  foreach ($flag in @("/fsanitize=fuzzer", "/fsanitize=address")) {
    Assert-ArrayContainsExactlyOnce -Values $msvcFlags -Expected $flag -Context "Native remote fuzz contract MSVC flags"
  }
  Assert-True ((Assert-RequiredString $toolchain "nativeRuntime" "Native remote fuzz contract toolchain requirements").Contains("sanitizer coverage instrumentation")) "Native remote fuzz contract must require sanitizer coverage instrumentation for native code."

  foreach ($evidenceId in $requiredEvidenceStatuses.Keys) {
    $matches = @($Contract.requiredEvidence | Where-Object { [string]$_.id -eq $evidenceId })
    Assert-Equal 1 $matches.Count "Native remote fuzz contract requiredEvidence must include $evidenceId once."
    Assert-Equal "True" ([string]$matches[0].required) "Native remote fuzz contract requiredEvidence $evidenceId must be required."
    Assert-Equal $requiredEvidenceStatuses[$evidenceId] ([string]$matches[0].status) "Native remote fuzz contract requiredEvidence $evidenceId status should match source preflight state."
  }

  $currentStatus = if (Test-HasProperty $Contract "currentStatus") { $Contract.currentStatus } else { throw "Native remote fuzz contract must define currentStatus." }
  Assert-Equal "blocked" (Assert-RequiredString $currentStatus "status" "Native remote fuzz contract currentStatus") "Native remote fuzz contract currentStatus must remain blocked."
  Assert-BooleanFalse $currentStatus "publicReadinessAllowed" "Native remote fuzz contract currentStatus"

  $Contract
}

function Assert-FuzzManifest([string]$Path, [object]$SourcePreflight) {
  $resolved = Assert-File $Path "FuzzManifestPath"
  Assert-Equal (Assert-NormalizedRepoPath ([string]$SourcePreflight.packageManifest) "sourcePreflight.packageManifest") (Get-RepoRelativePath $resolved) "Fuzz manifest path should match sourcePreflight."
  $text = Get-Content -Raw -LiteralPath $resolved
  Assert-NoCredentialEvidenceText -Text $text -Context "Fuzz manifest"
  Assert-NoForbiddenOverclaimText -Text $text -Context "Fuzz manifest"
  foreach ($pattern in @(
      '(?m)^\[workspace\]\s*$',
      '(?m)^name\s*=\s*"subversionr-native-remote-fuzz"\s*$',
      '(?m)^publish\s*=\s*false\s*$',
      '(?m)^edition\s*=\s*"2024"\s*$',
      '(?m)^\[package\.metadata\]\s*$',
      '(?m)^cargo-fuzz\s*=\s*true\s*$',
      '(?m)^libfuzzer-sys\s*=\s*"=0\.4\.13"\s*$'
    )) {
    Assert-True ($text -match $pattern) "Fuzz manifest missing required pattern: $pattern"
  }
  Assert-True ($text -match '(?ms)\[\[bin\]\].*?name\s*=\s*"svn_server_response_history_log".*?path\s*=\s*"fuzz_targets/svn_server_response_history_log\.rs".*?test\s*=\s*false.*?doc\s*=\s*false.*?bench\s*=\s*false') "Fuzz manifest must define the svn_server_response_history_log cargo-fuzz binary without test/doc/bench."
  [pscustomobject]@{
    resolved = $resolved
    packageName = "subversionr-native-remote-fuzz"
    libfuzzerSysVersion = "=0.4.13"
  }
}

function Assert-FuzzTarget([string]$Path, [object]$SourcePreflight) {
  $resolved = Assert-File $Path "FuzzTargetPath"
  Assert-Equal (Assert-NormalizedRepoPath ([string]$SourcePreflight.targetPath) "sourcePreflight.targetPath") (Get-RepoRelativePath $resolved) "Fuzz target path should match sourcePreflight."
  $text = Get-Content -Raw -LiteralPath $resolved
  Assert-NoCredentialEvidenceText -Text $text -Context "Fuzz target"
  Assert-NoForbiddenOverclaimText -Text $text -Context "Fuzz target"
  foreach ($pattern in @(
      '#!\[no_main\]',
      'use\s+libfuzzer_sys::\{fuzz_target,\s*Corpus\};',
      'fuzz_target!\(\|data:\s*&\[u8\]\|\s*->\s*Corpus',
      'MAX_FUZZ_INPUT_BYTES',
      'NATIVE-REMOTE-FUZZ-001',
      'svn:// history/log',
      'malicious-log-response-v1',
      'Corpus::Reject',
      'Corpus::Keep'
    )) {
    Assert-True ($text -match $pattern) "Fuzz target missing required pattern: $pattern"
  }
  $forbiddenPatterns = @(
    '(?i)\bstd::net\b',
    '\bTcp(Stream|Listener)\b',
    '\bUdpSocket\b',
    '(?i)\bstd::process\b',
    '\bCommand::new\b',
    '(?i)\bstd::fs\b',
    '\bFile::open\b',
    '\bOpenOptions\b',
    '(?i)\bunsafe\b',
    'extern\s+"C"',
    '\bunwrap\s*\(',
    '\bexpect\s*\(',
    '\bpanic!\s*\('
  )
  foreach ($pattern in $forbiddenPatterns) {
    if ($text -match $pattern) {
      throw "Fuzz target must not use network, process, filesystem, unsafe, or FFI APIs in source preflight scope."
    }
  }
  $match = [regex]::Match($text, 'const\s+MAX_FUZZ_INPUT_BYTES:\s*usize\s*=\s*(?<value>[0-9_]+)\s*;')
  Assert-True $match.Success "Fuzz target must define MAX_FUZZ_INPUT_BYTES as a numeric constant."
  $maxInputBytes = [int]($match.Groups["value"].Value.Replace("_", ""))
  Assert-True ($maxInputBytes -gt 0 -and $maxInputBytes -le 1048576) "Fuzz target MAX_FUZZ_INPUT_BYTES must be positive and at most 1 MiB."
  [pscustomobject]@{
    resolved = $resolved
    maxInputBytes = $maxInputBytes
  }
}

function Assert-SeedManifest([string]$Path, [object]$SourcePreflight) {
  $resolved = Assert-File $Path "SeedManifestPath"
  Assert-Equal (Assert-NormalizedRepoPath ([string]$SourcePreflight.seedCorpusManifest) "sourcePreflight.seedCorpusManifest") (Get-RepoRelativePath $resolved) "Seed manifest path should match sourcePreflight."
  $raw = Get-Content -Raw -LiteralPath $resolved
  Assert-NoCredentialEvidenceText -Text $raw -Context "Seed corpus manifest"
  Assert-NoForbiddenOverclaimText -Text $raw -Context "Seed corpus manifest"
  $manifest = $raw | ConvertFrom-Json
  Assert-Equal 1 ([int]$manifest.schemaVersion) "Seed corpus manifest schemaVersion must be stable."
  Assert-Equal "subversionr.fuzz.seed-corpus.svn-server-response-history-log.v1" ([string]$manifest.schema) "Seed corpus manifest schema must match."
  Assert-Equal "svn_server_response_history_log" (Assert-RequiredString $manifest "target" "Seed corpus manifest") "Seed corpus manifest target should match."
  Assert-Equal "svn://" (Assert-RequiredString $manifest "provider" "Seed corpus manifest") "Seed corpus manifest provider should match."
  Assert-Equal "history/log" (Assert-RequiredString $manifest "operation" "Seed corpus manifest") "Seed corpus manifest operation should match."
  Assert-BooleanFalse $manifest "publicReadinessClaim" "Seed corpus manifest"
  Assert-BooleanFalse $manifest "fuzzRunPerformed" "Seed corpus manifest"
  Assert-BooleanFalse $manifest "coverageEvidenceRecorded" "Seed corpus manifest"
  $nonClaims = Get-StringArray $manifest "nonClaims" "Seed corpus manifest"
  Assert-ArrayContainsExactlyOnce -Values $nonClaims -Expected "This seed corpus is for source preflight only and is not coverage-guided fuzz evidence." -Context "Seed corpus manifest nonClaims"
  Assert-ArrayContainsExactlyOnce -Values $nonClaims -Expected "This seed corpus does not prove arbitrary svn:// server safety or provider-complete remote-protocol fuzzing." -Context "Seed corpus manifest nonClaims"

  $seedDirectoryRelative = Assert-NormalizedRepoPath ([string]$SourcePreflight.seedCorpusDirectory) "sourcePreflight.seedCorpusDirectory"
  $seedDirectoryResolved = Assert-Directory $seedDirectoryRelative "sourcePreflight.seedCorpusDirectory"
  $seeds = @($manifest.seeds)
  Assert-True ($seeds.Count -gt 0) "Seed corpus manifest must contain at least one seed."
  Assert-True (@($seeds | Where-Object { [string]$_.id -eq "malicious-log-response-v1" }).Count -eq 1) "Seed corpus manifest must contain malicious-log-response-v1 exactly once."

  $seedRecords = @()
  foreach ($seed in $seeds) {
    $id = Assert-RequiredString $seed "id" "Seed corpus entry"
    $seedPath = Assert-NormalizedRepoPath (Assert-RequiredString $seed "path" "Seed corpus entry $id") "Seed corpus entry $id path"
    $sha256 = Assert-RequiredString $seed "sha256" "Seed corpus entry $id"
    $source = Assert-RequiredString $seed "source" "Seed corpus entry $id"
    Assert-True ($source.Contains("M7l6 malicious svn:// history/log fixture")) "Seed corpus entry $id must document source provenance."
    $traceIds = Get-StringArray $seed "traceIds" "Seed corpus entry $id"
    foreach ($traceId in $requiredTraceIds) {
      Assert-ArrayContainsExactlyOnce -Values $traceIds -Expected $traceId -Context "Seed corpus entry $id traceIds"
    }
    $seedResolved = Assert-File $seedPath "Seed corpus entry $id file"
    Assert-True (Test-IsPathWithin -Path $seedResolved -Root $seedDirectoryResolved) "Seed corpus entry $id must resolve inside sourcePreflight.seedCorpusDirectory."
    Assert-Equal $sha256 (Get-Sha256 $seedResolved) "Seed corpus entry $id sha256 should match current bytes."
    $seedBytes = [System.IO.File]::ReadAllBytes($seedResolved)
    Assert-True ($seedBytes.Length -gt 0) "Seed corpus entry $id must not be empty."
    Assert-True ($seedBytes.Length -le 65536) "Seed corpus entry $id must stay bounded for source preflight."
    $seedText = [System.Text.Encoding]::UTF8.GetString($seedBytes)
    Assert-NoCredentialEvidenceText -Text $seedText -Context "Seed corpus entry $id"
    Assert-True ($seedText.Contains("( ( ) ")) "Seed corpus entry $id should preserve the svn:// log response list shape."
    Assert-True ($seedText.Contains("999999999:unterminated")) "Seed corpus entry $id should preserve the malformed length-prefixed token shape."
    $seedRecords += [pscustomobject]@{
      id = $id
      path = Get-RepoRelativePath $seedResolved
      sha256 = $sha256
      sizeBytes = $seedBytes.Length
      traceIds = $traceIds
      source = $source
    }
  }

  [pscustomobject]@{
    resolved = $resolved
    directory = Get-RepoRelativePath $seedDirectoryResolved
    seeds = $seedRecords
    nonClaims = $nonClaims
  }
}

$allowedOutputRoots = @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-native-remote-fuzz-target-preflight-scripts"))
)
$outputResolved = Assert-GeneratedPath -Path $OutputPath -Name "OutputPath" -AllowedRoots $allowedOutputRoots -Description "target/release-evidence or target/tests/release-native-remote-fuzz-target-preflight-scripts"

$contractResolved = Assert-File $ContractPath "ContractPath"
$corpusResolved = Assert-File $MaliciousInputCorpusPath "MaliciousInputCorpusPath"
$matrixResolved = Assert-File $SecurityEvidenceMatrixPath "SecurityEvidenceMatrixPath"

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
$corpus = $corpusRaw | ConvertFrom-Json
Assert-MaliciousInputCorpusBlocker -Corpus $corpus -BlockerEntryId ([string]$contract.blockerEntryId)

$manifestReport = Assert-FuzzManifest -Path $FuzzManifestPath -SourcePreflight $contract.sourcePreflight
$targetReport = Assert-FuzzTarget -Path $FuzzTargetPath -SourcePreflight $contract.sourcePreflight
$seedReport = Assert-SeedManifest -Path $SeedManifestPath -SourcePreflight $contract.sourcePreflight

$parent = Split-Path -Parent $outputResolved
New-Item -ItemType Directory -Force -Path $parent | Out-Null

$report = [pscustomobject]@{
  schemaVersion = 1
  schema = "subversionr.release.native-remote-fuzz-target-preflight.win32-x64.v1"
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
  target = $Target
  publicReadinessClaim = $false
  completeFuzzClaim = $false
  coverageGuidedLibsvnClaim = $false
  sourceTargetPreflight = $true
  fuzzBuildPerformed = $false
  fuzzRunPerformed = $false
  seedExecutionPerformed = $false
  sanitizerCoverageProven = $false
  libsvnEdgeGrowthProven = $false
  traceIds = $requiredTraceIds
  blockerEntryId = [string]$contract.blockerEntryId
  scope = $contract.scope
  sourcePreflight = $contract.sourcePreflight
  fuzzTarget = [pscustomobject]@{
    packageName = $manifestReport.packageName
    targetName = [string]$contract.sourcePreflight.targetName
    manifestPath = Get-RepoRelativePath $manifestReport.resolved
    targetPath = Get-RepoRelativePath $targetReport.resolved
    libfuzzerSysVersion = $manifestReport.libfuzzerSysVersion
    maxInputBytes = $targetReport.maxInputBytes
    forbiddenApiScan = "passed"
  }
  seedCorpus = [pscustomobject]@{
    manifestPath = Get-RepoRelativePath $seedReport.resolved
    directory = $seedReport.directory
    seeds = $seedReport.seeds
    nonClaims = $seedReport.nonClaims
  }
  requiredEvidence = @($contract.requiredEvidence)
  execution = [pscustomobject]@{
    cargoFuzzBuild = [pscustomobject]@{
      status = "not-run"
      reason = "Source preflight only; cargo-fuzz build is a future execution gate."
    }
    fuzzRun = [pscustomobject]@{
      status = "not-run"
      reason = "Source preflight only; no fuzz campaign or seed execution was performed."
    }
    coverage = [pscustomobject]@{
      status = "not-proven"
      instrumentedLibsvn = $false
      edgeGrowth = $false
      reason = "Source-built libsvn/APR/bridge sanitizer coverage instrumentation remains unproven."
    }
  }
  inputs = [pscustomobject]@{
    contract = New-HashRecord $contractResolved
    maliciousInputCorpus = New-HashRecord $corpusResolved
    securityEvidenceMatrix = New-HashRecord $matrixResolved
    fuzzManifest = New-HashRecord $manifestReport.resolved
    fuzzTarget = New-HashRecord $targetReport.resolved
    seedManifest = New-HashRecord $seedReport.resolved
    seeds = @($seedReport.seeds | ForEach-Object {
        [pscustomobject]@{
          id = [string]$_.id
          path = [string]$_.path
          sha256 = [string]$_.sha256
        }
      })
  }
  blockers = @($contract.blockers)
  nonClaims = $requiredNonClaims
  contractNonClaims = @($contract.nonClaims)
  currentStatus = $contract.currentStatus
}

$report | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $outputResolved -Encoding utf8
Write-Host "Generated SubversionR native remote fuzz target source preflight for $Target at $outputResolved."

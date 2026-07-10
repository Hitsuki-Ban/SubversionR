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
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-native-remote-fuzz-contract-scripts"))
)
$requiredTraceIds = @("SEC-016", "TST-020")
$requiredEvidenceIds = @("instrumented-libsvn-build", "fuzzer-target", "seed-corpus", "run-evidence", "coverage-evidence")
$requiredNonClaims = @(
  "This gate is a local fuzz readiness contract, not a coverage-guided fuzz run.",
  "This gate does not prove sanitizer coverage, libsvn edge growth, crash discovery, or provider-complete remote-protocol fuzzing.",
  "This gate does not close SEC-016, TST-020, NATIVE-REMOTE-FUZZ-001, or public release readiness."
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
    '(?i)"fuzzRunRecorded"\s*:\s*true',
    '(?i)"coverageEvidenceRecorded"\s*:\s*true',
    '(?i)"providerCompleteFuzzClaim"\s*:\s*true',
    '(?i)"sanitizerCoverageProven"\s*:\s*true',
    '(?i)"libsvnEdgeGrowthProven"\s*:\s*true'
  )
  foreach ($pattern in $patterns) {
    if ($Text -match $pattern) {
      throw "$Context must not record fuzz-run, sanitizer-coverage, libsvn-edge-growth, provider-complete, or coverage-evidence overclaims."
    }
  }
}

function Assert-ArrayContainsExactlyOnce([object[]]$Values, [string]$Expected, [string]$Context) {
  Assert-True (@($Values | Where-Object { [string]$_ -eq $Expected }).Count -eq 1) "$Context must include '$Expected'."
}

function Assert-StringArrayEqual([string[]]$Expected, [string[]]$Actual, [string]$Context) {
  Assert-Equal $Expected.Count $Actual.Count "$Context count should match."
  for ($index = 0; $index -lt $Expected.Count; $index += 1) {
    Assert-Equal $Expected[$index] $Actual[$index] "$Context item $index should match."
  }
}

function Assert-MatrixReleaseBlocker([string]$MatrixText, [string]$TraceId) {
  $pattern = "\|\s*``?$TraceId``?\s*\|\s*release-blocker\s*\|"
  if ($MatrixText -notmatch $pattern) {
    throw "$TraceId must remain release-blocker in the security evidence matrix for this native remote fuzz contract gate."
  }
}

function Assert-SecurityEvidenceMatrix([string]$MatrixText) {
  Assert-MatrixReleaseBlocker -MatrixText $MatrixText -TraceId "SEC-016"
  Assert-MatrixReleaseBlocker -MatrixText $MatrixText -TraceId "TST-020"
  Assert-True ($MatrixText.IndexOf("native remote-protocol fuzz", [System.StringComparison]::OrdinalIgnoreCase) -ge 0) "Security evidence matrix must name the native remote-protocol fuzz readiness contract."
}

function Assert-HashRecord([object]$Record, [string]$Context) {
  $path = Assert-RequiredString $Record "path" $Context
  $sha256 = Assert-RequiredString $Record "sha256" $Context
  $resolved = Assert-File $path $Context
  Assert-Equal $sha256 (Get-Sha256 $resolved) "$Context sha256 should match current bytes."
  $resolved
}

function Assert-RequiredEvidenceMatches([object[]]$Expected, [object[]]$Actual) {
  foreach ($evidenceId in $requiredEvidenceIds) {
    $expectedMatches = @($Expected | Where-Object { [string]$_.id -eq $evidenceId })
    $actualMatches = @($Actual | Where-Object { [string]$_.id -eq $evidenceId })
    Assert-Equal 1 $expectedMatches.Count "Contract requiredEvidence must include $evidenceId once."
    Assert-Equal 1 $actualMatches.Count "Evidence requiredEvidence must include $evidenceId once."
    Assert-Equal "True" ([string]$expectedMatches[0].required) "Contract requiredEvidence $evidenceId must be required."
    Assert-Equal ([string]$expectedMatches[0].required) ([string]$actualMatches[0].required) "Evidence requiredEvidence $evidenceId required should match contract."
    Assert-Equal ([string]$expectedMatches[0].status) ([string]$actualMatches[0].status) "Evidence requiredEvidence $evidenceId status should match contract."
  }
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

  $toolchain = if (Test-HasProperty $Contract "toolchainRequirements") { $Contract.toolchainRequirements } else { throw "Native remote fuzz contract must define toolchainRequirements." }
  Assert-Equal "nightly-x86_64-pc-windows-msvc" (Assert-RequiredString $toolchain "rustToolchain" "Native remote fuzz contract toolchain requirements") "Native remote fuzz contract must require the Windows MSVC nightly Rust toolchain."
  Assert-Equal "cargo-fuzz" (Assert-RequiredString $toolchain "cargoSubcommand" "Native remote fuzz contract toolchain requirements") "Native remote fuzz contract must require cargo-fuzz."
  Assert-Equal "MSVC cl.exe" (Assert-RequiredString $toolchain "msvcCompiler" "Native remote fuzz contract toolchain requirements") "Native remote fuzz contract must require MSVC cl.exe."
  $msvcFlags = Get-StringArray $toolchain "msvcFlags" "Native remote fuzz contract toolchain requirements"
  foreach ($flag in @("/fsanitize=fuzzer", "/fsanitize=address")) {
    Assert-ArrayContainsExactlyOnce -Values $msvcFlags -Expected $flag -Context "Native remote fuzz contract MSVC flags"
  }
  Assert-True ((Assert-RequiredString $toolchain "nativeRuntime" "Native remote fuzz contract toolchain requirements").Contains("sanitizer coverage instrumentation")) "Native remote fuzz contract must require sanitizer coverage instrumentation for native code."

  $nonClaims = Get-StringArray $Contract "nonClaims" "Native remote fuzz contract"
  foreach ($nonClaim in $requiredNonClaims) {
    Assert-ArrayContainsExactlyOnce -Values $nonClaims -Expected $nonClaim -Context "Native remote fuzz contract nonClaims"
  }
  $currentStatus = if (Test-HasProperty $Contract "currentStatus") { $Contract.currentStatus } else { throw "Native remote fuzz contract must define currentStatus." }
  Assert-Equal "blocked" (Assert-RequiredString $currentStatus "status" "Native remote fuzz contract currentStatus") "Native remote fuzz contract currentStatus must remain blocked."
  Assert-BooleanFalse $currentStatus "publicReadinessAllowed" "Native remote fuzz contract currentStatus"
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

function Assert-SeedCorpusMatchesMaliciousInputCorpus([object]$Corpus, [string[]]$SeedCorpus) {
  foreach ($seedName in $SeedCorpus) {
    $matches = @($Corpus.entries | Where-Object {
        [string]$_.status -eq "covered" -and
        (Test-HasProperty $_ "test") -and
        [string]$_.test.name -eq $seedName
      })
    Assert-Equal 1 $matches.Count "Native remote fuzz contract seedCorpus '$seedName' must match exactly one covered malicious input corpus test."
    $traceIds = Get-StringArray $matches[0] "traceIds" "Malicious input corpus seed '$seedName'"
    foreach ($traceId in $requiredTraceIds) {
      Assert-ArrayContainsExactlyOnce -Values $traceIds -Expected $traceId -Context "Malicious input corpus seed '$seedName' traceIds"
    }
  }
}

$evidenceResolved = Assert-GeneratedPath -Path $EvidencePath -Name "EvidencePath" -AllowedRoots $allowedEvidenceRoots -Description "target/release-evidence or target/tests/release-native-remote-fuzz-contract-scripts"
$rawEvidence = Get-Content -Raw -LiteralPath $evidenceResolved
Assert-NoCredentialEvidenceText -Text $rawEvidence -Context "Native remote fuzz contract evidence"
Assert-NoForbiddenOverclaimText -Text $rawEvidence -Context "Native remote fuzz contract evidence"
$report = $rawEvidence | ConvertFrom-Json

Assert-Equal 1 ([int]$report.schemaVersion) "Native remote fuzz contract evidence schemaVersion should be stable."
Assert-Equal "subversionr.release.native-remote-fuzz-contract.win32-x64.v1" ([string]$report.schema) "Native remote fuzz contract evidence schema should match."
Assert-Equal $Target ([string]$report.target) "Native remote fuzz contract evidence target should match."
Assert-BooleanFalse $report "publicReadinessClaim" "Native remote fuzz contract evidence"
Assert-BooleanFalse $report "completeFuzzClaim" "Native remote fuzz contract evidence"
Assert-BooleanFalse $report "coverageGuidedLibsvnClaim" "Native remote fuzz contract evidence"
Assert-BooleanTrue $report "localPreflightOnly" "Native remote fuzz contract evidence"
foreach ($traceId in $requiredTraceIds) {
  Assert-ArrayContainsExactlyOnce -Values @($report.traceIds) -Expected $traceId -Context "Native remote fuzz contract evidence traceIds"
}
Assert-Equal "NATIVE-REMOTE-FUZZ-001" (Assert-RequiredString $report "blockerEntryId" "Native remote fuzz contract evidence") "Native remote fuzz contract evidence must bind the native remote fuzz blocker entry."

foreach ($nonClaim in $requiredNonClaims) {
  Assert-ArrayContainsExactlyOnce -Values @($report.nonClaims) -Expected $nonClaim -Context "Native remote fuzz contract evidence nonClaims"
}

$inputs = if (Test-HasProperty $report "inputs") { $report.inputs } else { throw "Native remote fuzz contract evidence must define inputs." }
$contractResolved = Assert-HashRecord $inputs.contract "Native remote fuzz contract manifest input"
$corpusResolved = Assert-HashRecord $inputs.maliciousInputCorpus "Malicious input corpus manifest input"
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
$contract = $contractRaw | ConvertFrom-Json
$corpus = $corpusRaw | ConvertFrom-Json
Assert-ContractShape $contract
Assert-MaliciousInputCorpusBlocker -Corpus $corpus -BlockerEntryId ([string]$contract.blockerEntryId)
Assert-SeedCorpusMatchesMaliciousInputCorpus -Corpus $corpus -SeedCorpus (Get-StringArray $contract.scope "seedCorpus" "Native remote fuzz contract scope")

Assert-StringArrayEqual (Get-StringArray $contract "requiredTraceIds" "Native remote fuzz contract") (Get-StringArray $report "traceIds" "Native remote fuzz contract evidence") "Native remote fuzz contract traceIds"
Assert-Equal ([string]$contract.blockerEntryId) ([string]$report.blockerEntryId) "Native remote fuzz contract blockerEntryId should match evidence."
Assert-Equal ([string]$contract.scope.provider) ([string]$report.scope.provider) "Native remote fuzz contract scope provider should match evidence."
Assert-Equal ([string]$contract.scope.operation) ([string]$report.scope.operation) "Native remote fuzz contract scope operation should match evidence."
Assert-Equal ([string]$contract.scope.evidenceBoundary) ([string]$report.scope.evidenceBoundary) "Native remote fuzz contract scope evidenceBoundary should match evidence."
Assert-StringArrayEqual (Get-StringArray $contract.scope "seedCorpus" "Native remote fuzz contract scope") (Get-StringArray $report.scope "seedCorpus" "Native remote fuzz contract evidence scope") "Native remote fuzz contract seedCorpus"
Assert-StringArrayEqual (Get-StringArray $contract.scope "excludedProviders" "Native remote fuzz contract scope") (Get-StringArray $report.scope "excludedProviders" "Native remote fuzz contract evidence scope") "Native remote fuzz contract excludedProviders"
Assert-Equal ([string]$contract.toolchainRequirements.rustToolchain) ([string]$report.toolchainRequirements.rustToolchain) "Native remote fuzz contract rustToolchain should match evidence."
Assert-Equal ([string]$contract.toolchainRequirements.cargoSubcommand) ([string]$report.toolchainRequirements.cargoSubcommand) "Native remote fuzz contract cargoSubcommand should match evidence."
Assert-Equal ([string]$contract.toolchainRequirements.msvcCompiler) ([string]$report.toolchainRequirements.msvcCompiler) "Native remote fuzz contract msvcCompiler should match evidence."
Assert-StringArrayEqual (Get-StringArray $contract.toolchainRequirements "msvcFlags" "Native remote fuzz contract toolchain requirements") (Get-StringArray $report.toolchainRequirements "msvcFlags" "Native remote fuzz contract evidence toolchain requirements") "Native remote fuzz contract MSVC flags"
Assert-Equal ([string]$contract.toolchainRequirements.nativeRuntime) ([string]$report.toolchainRequirements.nativeRuntime) "Native remote fuzz contract nativeRuntime should match evidence."
Assert-RequiredEvidenceMatches -Expected @($contract.requiredEvidence) -Actual @($report.requiredEvidence)
Assert-StringArrayEqual (Get-StringArray $contract "blockers" "Native remote fuzz contract") (Get-StringArray $report "blockers" "Native remote fuzz contract evidence") "Native remote fuzz contract blockers"
Assert-StringArrayEqual (Get-StringArray $contract "nonClaims" "Native remote fuzz contract") (Get-StringArray $report "nonClaims" "Native remote fuzz contract evidence") "Native remote fuzz contract nonClaims"
Assert-Equal "blocked" (Assert-RequiredString $report.currentStatus "status" "Native remote fuzz contract evidence currentStatus") "Native remote fuzz contract evidence currentStatus must remain blocked."
Assert-BooleanFalse $report.currentStatus "publicReadinessAllowed" "Native remote fuzz contract evidence currentStatus"

$observations = if (Test-HasProperty $report "toolchainObservations") { $report.toolchainObservations } else { throw "Native remote fuzz contract evidence must define toolchainObservations." }
Assert-RequiredString $observations.rust "status" "Native remote fuzz contract rust observation" | Out-Null
Assert-RequiredString $observations.cargoFuzz "status" "Native remote fuzz contract cargo-fuzz observation" | Out-Null
Assert-RequiredString $observations.msvc "status" "Native remote fuzz contract MSVC observation" | Out-Null
Assert-Equal "not-proven" (Assert-RequiredString $observations.sanitizerCoverage "status" "Native remote fuzz contract sanitizer coverage observation") "Native remote fuzz contract evidence must not claim sanitizer coverage instrumentation."
Assert-BooleanFalse $observations.sanitizerCoverage "instrumentedLibsvn" "Native remote fuzz contract sanitizer coverage observation"

Write-Host "Verified SubversionR native remote fuzz readiness contract for $Target at $evidenceResolved."

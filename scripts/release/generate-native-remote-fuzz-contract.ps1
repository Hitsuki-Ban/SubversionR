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
  [string]$OutputPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
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

function Assert-MaliciousInputCorpusBlocker([object]$Corpus, [string]$BlockerEntryId) {
  Assert-Equal 1 ([int]$Corpus.schemaVersion) "Malicious input corpus schemaVersion must be stable."
  Assert-Equal "subversionr.security.malicious-input-corpus.win32-x64.v1" ([string]$Corpus.schema) "Malicious input corpus schema must match."
  Assert-Equal $Target ([string]$Corpus.target) "Malicious input corpus target must match."
  Assert-BooleanFalse $Corpus "publicReadinessClaim" "Malicious input corpus"
  Assert-BooleanFalse $Corpus "completeFuzzClaim" "Malicious input corpus"
  Assert-BooleanTrue $Corpus "localCorpusOnly" "Malicious input corpus"

  $entries = @($Corpus.entries)
  $blockerEntries = @($entries | Where-Object { [string]$_.id -eq $BlockerEntryId })
  Assert-Equal 1 $blockerEntries.Count "Malicious input corpus must define the native remote fuzz blocker entry once."
  $blockerEntry = $blockerEntries[0]
  Assert-Equal "release-blocker" ([string]$blockerEntry.status) "Malicious input corpus $BlockerEntryId must remain release-blocker."
  Assert-RequiredString $blockerEntry "blocker" "Malicious input corpus $BlockerEntryId" | Out-Null
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

function ConvertTo-ContractReport([object]$Contract) {
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

  $blockerEntryId = Assert-RequiredString $Contract "blockerEntryId" "Native remote fuzz contract"
  Assert-Equal "NATIVE-REMOTE-FUZZ-001" $blockerEntryId "Native remote fuzz contract blockerEntryId should bind the malicious corpus release blocker."

  $scope = if (Test-HasProperty $Contract "scope") { $Contract.scope } else { throw "Native remote fuzz contract must define scope." }
  Assert-Equal "svn://" (Assert-RequiredString $scope "provider" "Native remote fuzz contract scope") "Native remote fuzz contract should start with the svn:// provider."
  Assert-Equal "history/log" (Assert-RequiredString $scope "operation" "Native remote fuzz contract scope") "Native remote fuzz contract should start with history/log."
  $seedCorpus = Get-StringArray $scope "seedCorpus" "Native remote fuzz contract scope"
  Get-StringArray $scope "excludedProviders" "Native remote fuzz contract scope" | Out-Null
  $boundary = Assert-RequiredString $scope "evidenceBoundary" "Native remote fuzz contract scope"
  Assert-True ($boundary.Contains("Readiness contract only")) "Native remote fuzz contract scope must keep a readiness-only evidence boundary."

  $toolchain = if (Test-HasProperty $Contract "toolchainRequirements") { $Contract.toolchainRequirements } else { throw "Native remote fuzz contract must define toolchainRequirements." }
  Assert-Equal "nightly-x86_64-pc-windows-msvc" (Assert-RequiredString $toolchain "rustToolchain" "Native remote fuzz contract toolchain requirements") "Native remote fuzz contract must require the Windows MSVC nightly Rust toolchain."
  Assert-Equal "cargo-fuzz" (Assert-RequiredString $toolchain "cargoSubcommand" "Native remote fuzz contract toolchain requirements") "Native remote fuzz contract must require cargo-fuzz."
  Assert-Equal "MSVC cl.exe" (Assert-RequiredString $toolchain "msvcCompiler" "Native remote fuzz contract toolchain requirements") "Native remote fuzz contract must require MSVC cl.exe."
  $msvcFlags = Get-StringArray $toolchain "msvcFlags" "Native remote fuzz contract toolchain requirements"
  foreach ($flag in @("/fsanitize=fuzzer", "/fsanitize=address")) {
    Assert-ArrayContainsExactlyOnce -Values $msvcFlags -Expected $flag -Context "Native remote fuzz contract MSVC flags"
  }
  $nativeRuntime = Assert-RequiredString $toolchain "nativeRuntime" "Native remote fuzz contract toolchain requirements"
  Assert-True ($nativeRuntime.Contains("sanitizer coverage instrumentation")) "Native remote fuzz contract must require sanitizer coverage instrumentation for native code."

  $evidence = @($Contract.requiredEvidence)
  Assert-True ($evidence.Count -gt 0) "Native remote fuzz contract must define requiredEvidence."
  foreach ($evidenceId in $requiredEvidenceIds) {
    $matches = @($evidence | Where-Object { [string]$_.id -eq $evidenceId })
    Assert-Equal 1 $matches.Count "Native remote fuzz contract requiredEvidence must include $evidenceId once."
    Assert-Equal "True" ([string]$matches[0].required) "Native remote fuzz contract requiredEvidence $evidenceId must be required."
    Assert-RequiredString $matches[0] "status" "Native remote fuzz contract requiredEvidence $evidenceId" | Out-Null
  }

  $blockers = Get-StringArray $Contract "blockers" "Native remote fuzz contract"
  $nonClaims = Get-StringArray $Contract "nonClaims" "Native remote fuzz contract"
  foreach ($nonClaim in $requiredNonClaims) {
    Assert-ArrayContainsExactlyOnce -Values $nonClaims -Expected $nonClaim -Context "Native remote fuzz contract nonClaims"
  }

  $currentStatus = if (Test-HasProperty $Contract "currentStatus") { $Contract.currentStatus } else { throw "Native remote fuzz contract must define currentStatus." }
  Assert-Equal "blocked" (Assert-RequiredString $currentStatus "status" "Native remote fuzz contract currentStatus") "Native remote fuzz contract currentStatus must remain blocked."
  Assert-BooleanFalse $currentStatus "publicReadinessAllowed" "Native remote fuzz contract currentStatus"

  [pscustomobject]@{
    traceIds = $traceIds
    blockerEntryId = $blockerEntryId
    scope = $scope
    seedCorpus = $seedCorpus
    toolchainRequirements = $toolchain
    requiredEvidence = $evidence
    blockers = $blockers
    nonClaims = $nonClaims
    currentStatus = $currentStatus
  }
}

function Get-CommandAvailability([string]$Name) {
  $command = Get-Command $Name -ErrorAction SilentlyContinue
  if ($null -eq $command) {
    return [pscustomobject]@{ status = "missing"; available = $false; sourceRecorded = $false }
  }
  [pscustomobject]@{ status = "available"; available = $true; sourceRecorded = $false }
}

function Invoke-ObservedNativeCommand([string]$Name, [string[]]$Arguments) {
  $availability = Get-CommandAvailability $Name
  if (-not [bool]$availability.available) {
    return [pscustomobject]@{
      status = "missing"
      available = $false
      exitCode = $null
      outputSummary = ""
      sourceRecorded = $false
    }
  }

  $output = & $Name @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  $summary = (($output | Select-Object -First 1) | Out-String).Trim()
  if ($summary.Length -gt 160) {
    $summary = $summary.Substring(0, 160)
  }
  [pscustomobject]@{
    status = if ($exitCode -eq 0) { "available" } else { "unavailable" }
    available = ($exitCode -eq 0)
    exitCode = $exitCode
    outputSummary = $summary
    sourceRecorded = $false
  }
}

function Get-ToolchainObservations([object]$ToolchainRequirements) {
  $rustup = Invoke-ObservedNativeCommand -Name "rustup" -Arguments @("show", "active-toolchain")
  $activeToolchain = if ([bool]$rustup.available) { $rustup.outputSummary } else { "" }
  $rustStatus = if ($activeToolchain.StartsWith("nightly-x86_64-pc-windows-msvc", [System.StringComparison]::OrdinalIgnoreCase)) { "available" } else { "blocked" }

  $cargoFuzz = Invoke-ObservedNativeCommand -Name "cargo" -Arguments @("fuzz", "--version")
  $cargoFuzzStatus = if ([bool]$cargoFuzz.available) { "available" } else { "missing" }
  $cl = Get-CommandAvailability "cl.exe"

  [pscustomobject]@{
    rust = [pscustomobject]@{
      status = $rustStatus
      activeToolchain = $activeToolchain
      requiredToolchain = [string]$ToolchainRequirements.rustToolchain
      sourceRecorded = $false
    }
    cargoFuzz = [pscustomobject]@{
      status = $cargoFuzzStatus
      available = [bool]$cargoFuzz.available
      version = if ([bool]$cargoFuzz.available) { $cargoFuzz.outputSummary } else { "" }
      sourceRecorded = $false
    }
    msvc = [pscustomobject]@{
      status = [string]$cl.status
      clAvailable = [bool]$cl.available
      requiredCompiler = [string]$ToolchainRequirements.msvcCompiler
      requiredFlags = @($ToolchainRequirements.msvcFlags)
      sourceRecorded = $false
    }
    sanitizerCoverage = [pscustomobject]@{
      status = "not-proven"
      instrumentedLibsvn = $false
      requiredNativeRuntime = [string]$ToolchainRequirements.nativeRuntime
    }
  }
}

function New-HashRecord([string]$Path) {
  [pscustomobject]@{
    path = Get-RepoRelativePath $Path
    sha256 = Get-Sha256 $Path
  }
}

$contractResolved = Assert-File $ContractPath "ContractPath"
$corpusResolved = Assert-File $MaliciousInputCorpusPath "MaliciousInputCorpusPath"
$matrixResolved = Assert-File $SecurityEvidenceMatrixPath "SecurityEvidenceMatrixPath"
$outputResolved = Assert-GeneratedPath -Path $OutputPath -Name "OutputPath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-native-remote-fuzz-contract-scripts"))
) -Description "target/release-evidence or target/tests/release-native-remote-fuzz-contract-scripts"

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
$contractReport = ConvertTo-ContractReport $contract
$corpus = $corpusRaw | ConvertFrom-Json
Assert-MaliciousInputCorpusBlocker -Corpus $corpus -BlockerEntryId $contractReport.blockerEntryId
Assert-SeedCorpusMatchesMaliciousInputCorpus -Corpus $corpus -SeedCorpus $contractReport.seedCorpus

$report = [pscustomobject]@{
  schemaVersion = 1
  schema = "subversionr.release.native-remote-fuzz-contract.win32-x64.v1"
  publicReadinessClaim = $false
  completeFuzzClaim = $false
  coverageGuidedLibsvnClaim = $false
  localPreflightOnly = $true
  target = $Target
  traceIds = $contractReport.traceIds
  generatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
  blockerEntryId = $contractReport.blockerEntryId
  inputs = [pscustomobject]@{
    contract = New-HashRecord $contractResolved
    maliciousInputCorpus = New-HashRecord $corpusResolved
    securityEvidenceMatrix = New-HashRecord $matrixResolved
  }
  scope = $contractReport.scope
  toolchainRequirements = $contractReport.toolchainRequirements
  toolchainObservations = Get-ToolchainObservations -ToolchainRequirements $contractReport.toolchainRequirements
  requiredEvidence = $contractReport.requiredEvidence
  currentStatus = $contractReport.currentStatus
  blockers = $contractReport.blockers
  nonClaims = $contractReport.nonClaims
  assertions = @(
    "SEC-016 and TST-020 remain release-blocker in the security evidence matrix",
    "NATIVE-REMOTE-FUZZ-001 remains a release-blocker in the malicious input corpus",
    "coverage-guided libsvn fuzzing is not claimed without sanitizer-instrumented libsvn and run evidence",
    "the local report records toolchain observations without recording command paths or credentials"
  )
}

$outputParent = Split-Path -Parent $outputResolved
New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
$report | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $outputResolved -Encoding utf8

Write-Host "Generated SubversionR native remote fuzz readiness contract for $Target at $outputResolved."

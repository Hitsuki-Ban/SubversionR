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
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-malicious-input-corpus-scripts"))
)
$allowedStatuses = @("covered", "release-blocker")
$requiredNonClaims = @(
  "This gate is a deterministic malicious-input corpus evidence floor, not coverage-guided fuzzing.",
  "This gate does not prove complete libsvn remote-protocol fuzz coverage, filesystem normalization, or VS Code rendering coverage.",
  "This gate does not close public release readiness while any corpus entry remains release-blocker."
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

function Assert-NormalizedRepoPath([string]$Path, [string]$Context) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "$Context must not be empty."
  }
  if ([System.IO.Path]::IsPathRooted($Path) -or $Path.Contains("\") -or $Path.Contains("../") -or $Path.Contains("/../") -or $Path -eq "." -or $Path.StartsWith("./") -or $Path.Contains("*")) {
    throw "$Context must be a normalized repository-relative path: $Path"
  }
  foreach ($segment in $Path.Split("/")) {
    if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq "." -or $segment -eq "..") {
      throw "$Context must be a normalized repository-relative path: $Path"
    }
  }
}

function Test-DeclaredTestName([string]$Text, [string]$Name) {
  $escapedName = [regex]::Escape($Name)
  $typescriptPattern = "(?m)^\s*(?:it|test)\s*\(\s*[""'``]$escapedName[""'``]\s*,"
  $rustPattern = "(?m)^\s*fn\s+$escapedName\s*\("
  [regex]::IsMatch($Text, $typescriptPattern) -or [regex]::IsMatch($Text, $rustPattern)
}

function Assert-TestEvidence([object]$Test, [string]$Context) {
  if ($null -eq $Test) {
    throw "$Context must define test evidence."
  }
  $file = Assert-RequiredString $Test "file" $Context
  $name = Assert-RequiredString $Test "name" $Context
  Assert-NormalizedRepoPath -Path $file -Context "$Context file"
  $resolved = Assert-File $file "$Context file"
  $text = Get-Content -Raw -LiteralPath $resolved
  if (-not (Test-DeclaredTestName -Text $text -Name $name)) {
    throw "$Context test declaration '$name' was not found in $file."
  }
  $expectedSha256 = Assert-RequiredString $Test "sha256" $Context
  Assert-Equal $expectedSha256 (Get-Sha256 $resolved) "$Context test file sha256 should match current bytes."
}

function Assert-StringArrayEqual([string[]]$Expected, [string[]]$Actual, [string]$Context) {
  Assert-Equal $Expected.Count $Actual.Count "$Context count should match."
  for ($index = 0; $index -lt $Expected.Count; $index += 1) {
    Assert-Equal $Expected[$index] $Actual[$index] "$Context item $index should match."
  }
}

function Assert-OptionalTestMatches([object]$Expected, [object]$Actual, [string]$Context) {
  if ($null -eq $Expected -and $null -eq $Actual) {
    return
  }
  if ($null -eq $Expected -or $null -eq $Actual) {
    throw "$Context test evidence should match manifest."
  }
  Assert-Equal (Assert-RequiredString $Expected "file" $Context) (Assert-RequiredString $Actual "file" $Context) "$Context test file should match manifest."
  Assert-Equal (Assert-RequiredString $Expected "name" $Context) (Assert-RequiredString $Actual "name" $Context) "$Context test name should match manifest."
}

function Assert-MatrixReleaseBlocker([string]$MatrixText, [string]$TraceId) {
  $pattern = "\|\s*``?$TraceId``?\s*\|\s*release-blocker\s*\|"
  if ($MatrixText -notmatch $pattern) {
    throw "$TraceId must remain release-blocker in the security evidence matrix for this corpus gate."
  }
}

function Assert-SecurityEvidenceMatrix([string]$MatrixText) {
  Assert-MatrixReleaseBlocker -MatrixText $MatrixText -TraceId "SEC-016"
  Assert-MatrixReleaseBlocker -MatrixText $MatrixText -TraceId "TST-020"
  Assert-True ($MatrixText.IndexOf("malicious input corpus", [System.StringComparison]::OrdinalIgnoreCase) -ge 0) "Security evidence matrix must name the malicious input corpus preflight."
}

function Assert-HashRecord([object]$Record, [string]$Context) {
  $path = Assert-RequiredString $Record "path" $Context
  $sha256 = Assert-RequiredString $Record "sha256" $Context
  $resolved = Assert-File $path $Context
  Assert-Equal $sha256 (Get-Sha256 $resolved) "$Context sha256 should match current bytes."
  $resolved
}

$evidenceResolved = Assert-GeneratedPath -Path $EvidencePath -Name "EvidencePath" -AllowedRoots $allowedEvidenceRoots -Description "target/release-evidence or target/tests/release-malicious-input-corpus-scripts"
$rawEvidence = Get-Content -Raw -LiteralPath $evidenceResolved
Assert-NoCredentialEvidenceText -Text $rawEvidence -Context "Malicious input corpus evidence"
$report = $rawEvidence | ConvertFrom-Json

Assert-Equal 1 ([int]$report.schemaVersion) "Malicious input corpus evidence schemaVersion should be stable."
Assert-Equal "subversionr.release.malicious-input-corpus.win32-x64.v1" ([string]$report.schema) "Malicious input corpus evidence schema should match the M7 contract."
Assert-Equal $Target ([string]$report.target) "Malicious input corpus evidence target should match the requested target."
Assert-Equal "False" ([string]$report.publicReadinessClaim) "Malicious input corpus evidence publicReadinessClaim must remain false."
Assert-Equal "False" ([string]$report.completeFuzzClaim) "Malicious input corpus evidence completeFuzzClaim must remain false."
Assert-Equal "True" ([string]$report.localCorpusOnly) "Malicious input corpus evidence localCorpusOnly must be true."
$boundary = Assert-RequiredString $report "evidenceBoundary" "Malicious input corpus evidence"
Assert-True ($boundary.Contains("not coverage-guided fuzzing")) "Malicious input corpus evidenceBoundary must reject fuzzing overclaims."
foreach ($nonClaim in $requiredNonClaims) {
  Assert-True (@($report.nonClaims | Where-Object { [string]$_ -eq $nonClaim }).Count -eq 1) "Malicious input corpus evidence nonClaims must include '$nonClaim'."
}

$inputs = if (Test-HasProperty $report "inputs") { $report.inputs } else { throw "Malicious input corpus evidence must define inputs." }
$corpusResolved = Assert-HashRecord $inputs.corpus "Malicious input corpus manifest input"
$matrixResolved = Assert-HashRecord $inputs.securityEvidenceMatrix "Security evidence matrix input"

$corpusRaw = Get-Content -Raw -LiteralPath $corpusResolved
$matrixRaw = Get-Content -Raw -LiteralPath $matrixResolved
Assert-NoCredentialEvidenceText -Text $corpusRaw -Context "Malicious input corpus"
Assert-NoCredentialEvidenceText -Text $matrixRaw -Context "Security evidence matrix"
Assert-SecurityEvidenceMatrix -MatrixText $matrixRaw
$corpus = $corpusRaw | ConvertFrom-Json

Assert-Equal 1 ([int]$corpus.schemaVersion) "Malicious input corpus manifest schemaVersion should be stable."
Assert-Equal "subversionr.security.malicious-input-corpus.win32-x64.v1" ([string]$corpus.schema) "Malicious input corpus manifest schema should match."
Assert-Equal $Target ([string]$corpus.target) "Malicious input corpus manifest target should match."
Assert-Equal "False" ([string]$corpus.publicReadinessClaim) "Malicious input corpus manifest publicReadinessClaim must remain false."
Assert-Equal "False" ([string]$corpus.completeFuzzClaim) "Malicious input corpus manifest completeFuzzClaim must remain false."
Assert-Equal "True" ([string]$corpus.localCorpusOnly) "Malicious input corpus manifest localCorpusOnly must be true."

$requiredTraceIds = Get-StringArray $corpus "requiredTraceIds" "Malicious input corpus manifest"
$requiredCategories = Get-StringArray $corpus "requiredCategories" "Malicious input corpus manifest"
foreach ($traceId in @("SEC-016", "TST-020")) {
  Assert-True (@($requiredTraceIds | Where-Object { $_ -eq $traceId }).Count -eq 1) "Malicious input corpus manifest requiredTraceIds must include $traceId."
  Assert-True (@($report.traceIds | Where-Object { [string]$_ -eq $traceId }).Count -eq 1) "Malicious input corpus evidence traceIds must include $traceId."
}

$entries = @($corpus.entries)
$reportEntries = @($report.entries)
Assert-Equal $entries.Count ([int]$report.coverage.entryCount) "Coverage entryCount should match the corpus manifest."
$coveredCount = @($entries | Where-Object { [string]$_.status -eq "covered" }).Count
$blockerCount = @($entries | Where-Object { [string]$_.status -eq "release-blocker" }).Count
Assert-Equal $coveredCount ([int]$report.coverage.coveredEntryCount) "Coverage coveredEntryCount should match the corpus manifest."
Assert-Equal $blockerCount ([int]$report.coverage.releaseBlockerEntryCount) "Coverage releaseBlockerEntryCount should match the corpus manifest."

$manifestById = @{}
foreach ($manifestEntry in $entries) {
  $manifestId = Assert-RequiredString $manifestEntry "id" "Manifest entry"
  if ($manifestById.ContainsKey($manifestId)) {
    throw "Manifest entry '$manifestId' is duplicated."
  }
  $manifestById[$manifestId] = $manifestEntry
}

$seenIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($entry in $reportEntries) {
  $id = Assert-RequiredString $entry "id" "Evidence entry"
  Assert-True ($seenIds.Add($id)) "Evidence entry '$id' is duplicated."
  if (-not $manifestById.ContainsKey($id)) {
    throw "Evidence entry '$id' does not match any manifest entry."
  }
  $manifestEntry = $manifestById[$id]
  $status = Assert-RequiredString $entry "status" "Evidence entry '$id'"
  Assert-True ($allowedStatuses -contains $status) "Evidence entry '$id' status must be one of: $($allowedStatuses -join ', ')."
  Assert-Equal (Assert-RequiredString $manifestEntry "status" "Manifest entry '$id'") $status "Evidence entry '$id' status should match manifest."
  $category = Assert-RequiredString $entry "category" "Evidence entry '$id'"
  Assert-True ($requiredCategories -contains $category) "Evidence entry '$id' category '$category' is not declared in the manifest."
  Assert-Equal (Assert-RequiredString $manifestEntry "category" "Manifest entry '$id'") $category "Evidence entry '$id' category should match manifest."
  Assert-Equal (Assert-RequiredString $manifestEntry "boundary" "Manifest entry '$id'") (Assert-RequiredString $entry "boundary" "Evidence entry '$id'") "Evidence entry '$id' boundary should match manifest."
  Assert-StringArrayEqual (Get-StringArray $manifestEntry "traceIds" "Manifest entry '$id'") (Get-StringArray $entry "traceIds" "Evidence entry '$id'") "Evidence entry '$id' traceIds"
  Assert-StringArrayEqual (Get-StringArray $manifestEntry "payloadClasses" "Manifest entry '$id'") (Get-StringArray $entry "payloadClasses" "Evidence entry '$id'") "Evidence entry '$id' payloadClasses"
  if ($status -eq "covered") {
    Assert-OptionalTestMatches $manifestEntry.test $entry.test "Evidence entry '$id'"
    Assert-TestEvidence -Test $entry.test -Context "Evidence entry '$id'"
  }
  else {
    Assert-Equal (Assert-RequiredString $manifestEntry "blocker" "Manifest entry '$id'") (Assert-RequiredString $entry "blocker" "Evidence entry '$id'") "Evidence entry '$id' blocker should match manifest."
  }
}
foreach ($manifestId in $manifestById.Keys) {
  Assert-True ($seenIds.Contains($manifestId)) "Evidence is missing manifest entry '$manifestId'."
}
Assert-Equal $entries.Count $reportEntries.Count "Evidence should report every corpus entry."
foreach ($category in $requiredCategories) {
  Assert-True (@($reportEntries | Where-Object { [string]$_.category -eq $category }).Count -gt 0) "Required malicious input category '$category' has no evidence entry."
}
$reportBlockerCount = @($reportEntries | Where-Object { [string]$_.status -eq "release-blocker" }).Count
Assert-True ($reportBlockerCount -gt 0) "Malicious input corpus evidence must keep at least one explicit release-blocker entry until fuzz coverage is complete."

Write-Host "Verified SubversionR malicious input corpus preflight for $Target at $evidenceResolved."

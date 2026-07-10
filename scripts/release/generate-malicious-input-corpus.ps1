[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$CorpusPath,

  [Parameter(Mandatory = $true)]
  [string]$SecurityEvidenceMatrixPath,

  [Parameter(Mandatory = $true)]
  [string]$OutputPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
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
  [pscustomobject]@{
    file = Get-RepoRelativePath $resolved
    name = $name
    sha256 = Get-Sha256 $resolved
  }
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

function ConvertTo-CorpusReport([object]$Corpus) {
  Assert-Equal 1 ([int]$Corpus.schemaVersion) "Malicious input corpus schemaVersion must be stable."
  Assert-Equal "subversionr.security.malicious-input-corpus.win32-x64.v1" ([string]$Corpus.schema) "Malicious input corpus schema must match the M7 malicious-input contract."
  Assert-Equal $Target ([string]$Corpus.target) "Malicious input corpus target must match the requested target."
  Assert-Equal "False" ([string]$Corpus.publicReadinessClaim) "Malicious input corpus publicReadinessClaim must remain false."
  Assert-Equal "False" ([string]$Corpus.completeFuzzClaim) "Malicious input corpus completeFuzzClaim must remain false."
  Assert-Equal "True" ([string]$Corpus.localCorpusOnly) "Malicious input corpus localCorpusOnly must be true."
  $boundary = Assert-RequiredString $Corpus "evidenceBoundary" "Malicious input corpus"
  Assert-True ($boundary.Contains("not coverage-guided fuzzing")) "Malicious input corpus evidenceBoundary must reject fuzzing overclaims."

  $requiredTraceIds = Get-StringArray $Corpus "requiredTraceIds" "Malicious input corpus"
  foreach ($traceId in @("SEC-016", "TST-020")) {
    Assert-True (@($requiredTraceIds | Where-Object { $_ -eq $traceId }).Count -eq 1) "Malicious input corpus requiredTraceIds must include $traceId."
  }
  $requiredCategories = Get-StringArray $Corpus "requiredCategories" "Malicious input corpus"
  $requiredCategorySet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($category in $requiredCategories) {
    Assert-True ($requiredCategorySet.Add($category)) "Malicious input corpus required category '$category' is duplicated."
  }

  $entries = @($Corpus.entries)
  Assert-True ($entries.Count -gt 0) "Malicious input corpus must define entries."
  $seenIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $coveredCategories = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $blockedCategories = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $entryReports = @()
  foreach ($entry in $entries) {
    $id = Assert-RequiredString $entry "id" "Corpus entry"
    Assert-True ($seenIds.Add($id)) "Corpus entry '$id' is duplicated."
    $traceIds = Get-StringArray $entry "traceIds" "Corpus entry '$id'"
    foreach ($traceId in $traceIds) {
      Assert-True ($requiredTraceIds -contains $traceId) "Corpus entry '$id' has unsupported traceId '$traceId'."
    }
    $category = Assert-RequiredString $entry "category" "Corpus entry '$id'"
    Assert-True ($requiredCategorySet.Contains($category)) "Corpus entry '$id' category '$category' is not declared in requiredCategories."
    $boundary = Assert-RequiredString $entry "boundary" "Corpus entry '$id'"
    $payloadClasses = Get-StringArray $entry "payloadClasses" "Corpus entry '$id'"
    $status = Assert-RequiredString $entry "status" "Corpus entry '$id'"
    Assert-True ($allowedStatuses -contains $status) "Corpus entry '$id' status must be one of: $($allowedStatuses -join ', ')."
    $testEvidence = $null
    $blocker = ""
    if ($status -eq "covered") {
      $testEvidence = Assert-TestEvidence -Test $entry.test -Context "Corpus entry '$id'"
      $coveredCategories.Add($category) | Out-Null
    }
    else {
      $blocker = Assert-RequiredString $entry "blocker" "Corpus entry '$id'"
      $blockedCategories.Add($category) | Out-Null
    }
    $entryReports += [pscustomobject]@{
      id = $id
      traceIds = $traceIds
      category = $category
      boundary = $boundary
      payloadClasses = $payloadClasses
      status = $status
      test = $testEvidence
      blocker = $blocker
    }
  }
  foreach ($category in $requiredCategories) {
    Assert-True (@($entryReports | Where-Object { $_.category -eq $category }).Count -gt 0) "Required malicious input category '$category' has no corpus entry."
  }

  [pscustomobject]@{
    requiredTraceIds = $requiredTraceIds
    requiredCategories = $requiredCategories
    entries = $entryReports
    coveredCategories = @($coveredCategories | Sort-Object)
    blockedCategories = @($blockedCategories | Sort-Object)
  }
}

$corpusResolved = Assert-File $CorpusPath "CorpusPath"
$matrixResolved = Assert-File $SecurityEvidenceMatrixPath "SecurityEvidenceMatrixPath"
$outputResolved = Assert-GeneratedPath -Path $OutputPath -Name "OutputPath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-malicious-input-corpus-scripts"))
) -Description "target/release-evidence or target/tests/release-malicious-input-corpus-scripts"

$corpusRaw = Get-Content -Raw -LiteralPath $corpusResolved
$matrixRaw = Get-Content -Raw -LiteralPath $matrixResolved
Assert-NoCredentialEvidenceText -Text $corpusRaw -Context "Malicious input corpus"
Assert-NoCredentialEvidenceText -Text $matrixRaw -Context "Security evidence matrix"
Assert-SecurityEvidenceMatrix -MatrixText $matrixRaw
$corpus = $corpusRaw | ConvertFrom-Json
$corpusReport = ConvertTo-CorpusReport $corpus
$coveredEntries = @($corpusReport.entries | Where-Object { $_.status -eq "covered" })
$releaseBlockerEntries = @($corpusReport.entries | Where-Object { $_.status -eq "release-blocker" })

$report = [pscustomobject]@{
  schemaVersion = 1
  schema = "subversionr.release.malicious-input-corpus.win32-x64.v1"
  publicReadinessClaim = $false
  completeFuzzClaim = $false
  localCorpusOnly = $true
  target = $Target
  traceIds = $corpusReport.requiredTraceIds
  generatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
  evidenceBoundary = [string]$corpus.evidenceBoundary
  inputs = [pscustomobject]@{
    corpus = [pscustomobject]@{ path = Get-RepoRelativePath $corpusResolved; sha256 = Get-Sha256 $corpusResolved }
    securityEvidenceMatrix = [pscustomobject]@{ path = Get-RepoRelativePath $matrixResolved; sha256 = Get-Sha256 $matrixResolved }
  }
  coverage = [pscustomobject]@{
    entryCount = $corpusReport.entries.Count
    coveredEntryCount = $coveredEntries.Count
    releaseBlockerEntryCount = $releaseBlockerEntries.Count
    requiredCategories = $corpusReport.requiredCategories
    coveredCategories = $corpusReport.coveredCategories
    blockedCategories = $corpusReport.blockedCategories
  }
  entries = $corpusReport.entries
  nonClaims = $requiredNonClaims
  assertions = @(
    "every covered malicious-input corpus entry names a repository test file and exact test name",
    "every release-blocker corpus entry records an explicit blocker instead of a silent gap",
    "SEC-016 and TST-020 remain release-blocker in the security evidence matrix",
    "the corpus evidence contains no credential-like payload text"
  )
}

$outputParent = Split-Path -Parent $outputResolved
New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $outputResolved -Encoding utf8

Write-Host "Generated SubversionR malicious input corpus preflight for $Target at $outputResolved."

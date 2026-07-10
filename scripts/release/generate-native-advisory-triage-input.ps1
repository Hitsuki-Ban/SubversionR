[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$NativeAdvisoryEvidencePath,

  [Parameter(Mandatory = $true)]
  [string]$OutputPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$maxNativeAdvisoryAgeDays = 7

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
  if (-not (Test-HasProperty $Object $Name) -or [string]::IsNullOrWhiteSpace([string]$Object.PSObject.Properties[$Name].Value)) {
    throw "$Context must define $Name."
  }
  [string]$Object.PSObject.Properties[$Name].Value
}

function Assert-RequiredBooleanFalse([object]$Object, [string]$Name, [string]$Context) {
  if (-not (Test-HasProperty $Object $Name)) {
    throw "$Context must define $Name."
  }
  Assert-Equal "False" ([string]$Object.PSObject.Properties[$Name].Value) "$Context $Name must remain false."
}

function Assert-RequiredBooleanTrue([object]$Object, [string]$Name, [string]$Context) {
  if (-not (Test-HasProperty $Object $Name)) {
    throw "$Context must define $Name."
  }
  Assert-Equal "True" ([string]$Object.PSObject.Properties[$Name].Value) "$Context $Name must be true."
}

function Assert-FreshTimestamp([string]$Value, [string]$Context, [int]$MaxAgeDays) {
  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "$Context must define generatedAt."
  }
  $timestamp = [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
  $now = [DateTimeOffset]::UtcNow
  if ($timestamp.UtcDateTime -gt $now.UtcDateTime.AddMinutes(5)) {
    throw "$Context generatedAt is in the future: $Value"
  }
  $age = $now - $timestamp
  if ($age.TotalDays -gt $MaxAgeDays) {
    throw "$Context is older than $MaxAgeDays days: $Value"
  }
  [pscustomobject]@{
    generatedAt = $timestamp.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
    maxAgeDays = $MaxAgeDays
    ageSeconds = [Math]::Max(0, [int][Math]::Round($age.TotalSeconds))
    fresh = $true
  }
}

function ConvertTo-StringArray([object]$Value) {
  @($Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
}

function ConvertTo-ObjectArray([object]$Value) {
  if ($null -eq $Value) {
    return @()
  }
  @($Value | Where-Object { $null -ne $_ })
}

function ConvertTo-AdvisorySourceIds([object]$Sources, [string]$ComponentName) {
  $ids = @($Sources | ForEach-Object { Assert-RequiredString $_ "id" "Advisory source for '$ComponentName'" })
  Assert-True (@($ids).Count -gt 0) "Native component '$ComponentName' must have advisory source IDs."
  @($ids | Sort-Object -Unique)
}

function ConvertTo-NativeComponentRows([object[]]$Components) {
  $rows = @()
  foreach ($component in $Components) {
    $name = Assert-RequiredString $component "name" "Native advisory component"
    $version = Assert-RequiredString $component "version" "Native advisory component '$name'"
    Assert-Equal "pending" ([string]$component.reviewStatus) "Native advisory component '$name' reviewStatus must remain pending."
    Assert-Equal "pending" ([string]$component.triageStatus) "Native advisory component '$name' triageStatus must remain pending."
    Assert-Equal "pending" ([string]$component.remediationDecision) "Native advisory component '$name' remediationDecision must remain pending."
    Assert-Equal "pending" ([string]$component.vexDecision) "Native advisory component '$name' vexDecision must remain pending."
    Assert-RequiredBooleanTrue $component "releaseBlocking" "Native advisory component '$name'"
    $sourceDigest = $component.sourceDigest
    $rows += [pscustomobject]@{
      kind = "native-component"
      key = "native:$name@$version"
      reviewQueue = "native-advisory"
      componentName = $name
      displayName = if (Test-HasProperty $component "displayName") { [string]$component.displayName } else { $name }
      version = $version
      sourceDigest = $sourceDigest
      advisorySourceIds = ConvertTo-AdvisorySourceIds $component.advisorySources $name
      requiredInputs = [pscustomobject]@{
        triageStatus = "required"
        remediationDecision = "required"
        vexDecision = "required"
        reviewer = "required"
        analysisEvidence = "required-before-approval"
      }
      currentStatus = [pscustomobject]@{
        triageStatus = "pending"
        remediationDecision = "pending"
        vexDecision = "pending"
      }
      releaseBlocking = $true
    }
  }
  @($rows)
}

function ConvertTo-OsvFindingRows([object[]]$Findings) {
  $rows = @()
  foreach ($finding in $Findings) {
    $id = Assert-RequiredString $finding "id" "OSV finding"
    Assert-Equal "pending" ([string]$finding.triageStatus) "OSV finding '$id' triageStatus must remain pending."
    Assert-Equal "pending" ([string]$finding.remediationDecision) "OSV finding '$id' remediationDecision must remain pending."
    Assert-Equal "pending" ([string]$finding.vexDecision) "OSV finding '$id' vexDecision must remain pending."
    $rows += [pscustomobject]@{
      kind = "osv-finding"
      key = "osv:$id"
      reviewQueue = "osv-vulnerability"
      findingId = $id
      affectedPurls = if (Test-HasProperty $finding "affectedPurls") { ConvertTo-StringArray $finding.affectedPurls } else { @() }
      requiredInputs = [pscustomobject]@{
        triageStatus = "required"
        remediationDecision = "required"
        vexDecision = "required"
        reviewer = "required"
        analysisEvidence = "required-before-approval"
      }
      currentStatus = [pscustomobject]@{
        triageStatus = "pending"
        remediationDecision = "pending"
        vexDecision = "pending"
      }
      releaseBlocking = $true
    }
  }
  @($rows)
}

$nativeAdvisoryResolved = Assert-File $NativeAdvisoryEvidencePath "NativeAdvisoryEvidencePath"
$outputResolved = Assert-GeneratedPath -Path $OutputPath -Name "OutputPath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-native-advisory-triage-input-scripts"))
) -Description "target/release-evidence or target/tests/release-native-advisory-triage-input-scripts"

$nativeAdvisory = Get-Content -Raw -LiteralPath $nativeAdvisoryResolved | ConvertFrom-Json
Assert-Equal "subversionr.release.native-advisory-review.win32-x64.v1" ([string]$nativeAdvisory.schema) "Native advisory evidence schema must match M7l2b."
Assert-Equal $Target ([string]$nativeAdvisory.target) "Native advisory evidence target must match the requested target."
Assert-RequiredBooleanFalse $nativeAdvisory "publicReadinessClaim" "Native advisory evidence"
Assert-RequiredBooleanFalse $nativeAdvisory "vulnerabilityReviewComplete" "Native advisory evidence"
Assert-RequiredBooleanFalse $nativeAdvisory "nativeAdvisoryReviewComplete" "Native advisory evidence"
Assert-Equal "required" ([string]$nativeAdvisory.nativeReview.status) "Native advisory review status must remain required."
Assert-RequiredBooleanTrue $nativeAdvisory.nativeReview "releaseBlocking" "Native advisory review"
Assert-RequiredBooleanTrue $nativeAdvisory.nativeReview "sourceContractComplete" "Native advisory review"
Assert-RequiredBooleanFalse $nativeAdvisory.review "triageComplete" "Native advisory review"
Assert-RequiredBooleanFalse $nativeAdvisory.review "remediationApproved" "Native advisory review"
Assert-RequiredBooleanFalse $nativeAdvisory.review "vexDecisionsComplete" "Native advisory review"
$nativeFreshness = Assert-FreshTimestamp ([string]$nativeAdvisory.generatedAt) "Native advisory evidence" $maxNativeAdvisoryAgeDays

$liveOsvEvidence = $nativeAdvisory.evidence.liveOsv
$liveOsvPath = Assert-File (Assert-RequiredString $liveOsvEvidence "path" "Live OSV evidence reference") "Live OSV evidence reference"
Assert-Equal "subversionr.release.vulnerability-review-osv.win32-x64.v1" ([string]$liveOsvEvidence.schema) "Live OSV evidence reference schema must match M7l2a."
Assert-Equal ([string]$liveOsvEvidence.sha256) (Get-Sha256 $liveOsvPath) "Live OSV evidence SHA256 must match current bytes."

$liveOsv = Get-Content -Raw -LiteralPath $liveOsvPath | ConvertFrom-Json
Assert-Equal "subversionr.release.vulnerability-review-osv.win32-x64.v1" ([string]$liveOsv.schema) "Live OSV evidence schema must match M7l2a."
Assert-Equal $Target ([string]$liveOsv.target) "Live OSV target must match the requested target."
Assert-RequiredBooleanFalse $liveOsv "publicReadinessClaim" "Live OSV evidence"
Assert-RequiredBooleanFalse $liveOsv "vulnerabilityReviewComplete" "Live OSV evidence"
Assert-RequiredBooleanTrue $liveOsv "liveOsvEvidence" "Live OSV evidence"
Assert-Equal "queried" ([string]$liveOsv.osv.status) "Live OSV status must be queried."
Assert-RequiredBooleanTrue $liveOsv.osv "liveQueryPerformed" "Live OSV"
Assert-RequiredBooleanTrue $liveOsv.osv "resultRecorded" "Live OSV"
Assert-Equal "passed" ([string]$liveOsv.osv.positiveControl.status) "Live OSV positive control must pass."
Assert-Equal "required" ([string]$liveOsv.manualReview.status) "Live OSV manual review must remain required."
Assert-RequiredBooleanTrue $liveOsv.manualReview "releaseBlocking" "Live OSV manual review"
Assert-RequiredBooleanFalse $liveOsv.review "triageComplete" "Live OSV review"
Assert-RequiredBooleanFalse $liveOsv.review "remediationApproved" "Live OSV review"
Assert-RequiredBooleanFalse $liveOsv.review "vexDecisionsComplete" "Live OSV review"

$nativeComponents = ConvertTo-ObjectArray $nativeAdvisory.nativeReview.components
Assert-Equal ([int]$nativeAdvisory.nativeReview.componentCount) (@($nativeComponents).Count) "Native advisory componentCount must match components."
$osvFindings = @()
if (Test-HasProperty $liveOsv.review "findings") {
  $osvFindings = ConvertTo-ObjectArray $liveOsv.review.findings
}
Assert-Equal ([int]$liveOsv.review.findingCount) (@($osvFindings).Count) "Live OSV findingCount must match findings."

$nativeRows = @(ConvertTo-NativeComponentRows $nativeComponents)
$osvRows = @(ConvertTo-OsvFindingRows $osvFindings)
$allRows = @()
$allRows += @($nativeRows)
$allRows += @($osvRows)
$rowKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($row in $allRows) {
  Assert-True ($rowKeys.Add([string]$row.key)) "Native advisory triage input row key '$($row.key)' is duplicated."
}

$report = [pscustomobject]@{
  schemaVersion = 1
  schema = "subversionr.release.native-advisory-triage-input.win32-x64.v1"
  publicReadinessClaim = $false
  vulnerabilityReviewComplete = $false
  nativeAdvisoryReviewComplete = $false
  triageComplete = $false
  remediationApproved = $false
  vexDecisionsComplete = $false
  target = $Target
  traceIds = @("SEC-015", "MIG-012", "TST-024")
  generatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
  evidence = [pscustomobject]@{
    nativeAdvisory = [pscustomobject]@{
      path = Get-RepoRelativePath $nativeAdvisoryResolved
      sha256 = Get-Sha256 $nativeAdvisoryResolved
      schema = [string]$nativeAdvisory.schema
      generatedAt = $nativeFreshness.generatedAt
      maxAgeDays = $nativeFreshness.maxAgeDays
      ageSeconds = $nativeFreshness.ageSeconds
      fresh = $nativeFreshness.fresh
    }
    liveOsv = [pscustomobject]@{
      path = Get-RepoRelativePath $liveOsvPath
      sha256 = Get-Sha256 $liveOsvPath
      schema = [string]$liveOsv.schema
      findingCount = @($osvFindings).Count
    }
  }
  triageInput = [pscustomobject]@{
    status = "required"
    releaseBlocking = $true
    nativeComponentRowCount = @($nativeRows).Count
    osvFindingRowCount = @($osvRows).Count
    totalRowCount = @($allRows).Count
    rows = $allRows
    blockers = @(
      "Native advisory triage input rows require human review.",
      "Live OSV finding input rows require human triage, remediation, and VEX decisions."
    )
  }
  blockers = @(
    "Native advisory review is not complete.",
    "Vulnerability triage and remediation approval are not complete.",
    "VEX decisions are not complete.",
    "Final release approval for vulnerability findings is not complete."
  )
  nonClaims = @(
    "This gate creates triage/remediation/VEX input rows only.",
    "This gate does not assert that native dependencies are free of known vulnerabilities.",
    "This gate does not complete native dependency advisory review.",
    "This gate does not approve remediation, suppression, exploitability, or VEX decisions.",
    "This gate does not claim public release readiness."
  )
  assertions = @(
    "M7l2b native advisory evidence is bound by SHA256 and freshness checked.",
    "The M7l2a live OSV evidence referenced by M7l2b is re-read and hash checked.",
    "Every M7l2b native source-lock component has a triage input row.",
    "Every live OSV finding has a triage input row.",
    "All triage, remediation, and VEX outcomes remain pending."
  )
}

$parent = Split-Path -Parent $outputResolved
New-Item -ItemType Directory -Force -Path $parent | Out-Null
$report | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $outputResolved -Encoding utf8

Write-Host "Generated SubversionR native advisory triage input for $Target at $outputResolved."

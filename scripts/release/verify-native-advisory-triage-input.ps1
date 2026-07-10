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
$releaseEvidenceRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence"))
$testEvidenceRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-native-advisory-triage-input-scripts"))

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

function Assert-ArrayContainsExactlyOnce([object[]]$Values, [string]$Expected, [string]$Context) {
  Assert-True (@($Values | Where-Object { [string]$_ -eq $Expected }).Count -eq 1) "$Context must include '$Expected'."
}

function Assert-NoCredentialEvidenceText([string]$Text) {
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
      throw "Native advisory triage input evidence must not record credentials, tokens, authorization headers, passwords, or secrets."
    }
  }
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

function New-ExpectedNativeRow([object]$Component) {
  $name = Assert-RequiredString $Component "name" "Native advisory component"
  $version = Assert-RequiredString $Component "version" "Native advisory component '$name'"
  [pscustomobject]@{
    kind = "native-component"
    key = "native:$name@$version"
    componentName = $name
    version = $version
    advisorySourceIds = ConvertTo-AdvisorySourceIds $Component.advisorySources $name
  }
}

function New-ExpectedOsvRow([object]$Finding) {
  $id = Assert-RequiredString $Finding "id" "OSV finding"
  [pscustomobject]@{
    kind = "osv-finding"
    key = "osv:$id"
    findingId = $id
    affectedPurls = if (Test-HasProperty $Finding "affectedPurls") { ConvertTo-StringArray $Finding.affectedPurls } else { @() }
  }
}

function Assert-RequiredInputShape([object]$Row, [string]$Context) {
  Assert-Equal "required" ([string]$Row.requiredInputs.triageStatus) "$Context triageStatus input should be required."
  Assert-Equal "required" ([string]$Row.requiredInputs.remediationDecision) "$Context remediationDecision input should be required."
  Assert-Equal "required" ([string]$Row.requiredInputs.vexDecision) "$Context vexDecision input should be required."
  Assert-Equal "required" ([string]$Row.requiredInputs.reviewer) "$Context reviewer input should be required."
  Assert-Equal "required-before-approval" ([string]$Row.requiredInputs.analysisEvidence) "$Context analysisEvidence input should be required before approval."
  Assert-Equal "pending" ([string]$Row.currentStatus.triageStatus) "$Context triageStatus should remain pending."
  Assert-Equal "pending" ([string]$Row.currentStatus.remediationDecision) "$Context remediationDecision should remain pending."
  Assert-Equal "pending" ([string]$Row.currentStatus.vexDecision) "$Context vexDecision should remain pending."
  Assert-RequiredBooleanTrue $Row "releaseBlocking" $Context
}

$evidenceResolved = Assert-GeneratedPath -Path $EvidencePath -Name "EvidencePath" -AllowedRoots @(
  $releaseEvidenceRoot,
  $testEvidenceRoot
) -Description "target/release-evidence or target/tests/release-native-advisory-triage-input-scripts"

$rawEvidence = Get-Content -Raw -LiteralPath $evidenceResolved
Assert-NoCredentialEvidenceText $rawEvidence
$report = $rawEvidence | ConvertFrom-Json

Assert-Equal 1 ([int]$report.schemaVersion) "Native advisory triage input schemaVersion should be 1."
Assert-Equal "subversionr.release.native-advisory-triage-input.win32-x64.v1" ([string]$report.schema) "Native advisory triage input schema should match M7l2c."
Assert-Equal $Target ([string]$report.target) "Native advisory triage input target should match the requested target."
Assert-RequiredBooleanFalse $report "publicReadinessClaim" "Native advisory triage input"
Assert-RequiredBooleanFalse $report "vulnerabilityReviewComplete" "Native advisory triage input"
Assert-RequiredBooleanFalse $report "nativeAdvisoryReviewComplete" "Native advisory triage input"
Assert-RequiredBooleanFalse $report "triageComplete" "Native advisory triage input"
Assert-RequiredBooleanFalse $report "remediationApproved" "Native advisory triage input"
Assert-RequiredBooleanFalse $report "vexDecisionsComplete" "Native advisory triage input"

foreach ($traceId in @("SEC-015", "MIG-012", "TST-024")) {
  Assert-ArrayContainsExactlyOnce -Values @($report.traceIds) -Expected $traceId -Context "Native advisory triage input trace IDs"
}

$nativeEvidence = $report.evidence.nativeAdvisory
$nativeEvidencePath = Assert-File (Assert-RequiredString $nativeEvidence "path" "Native advisory evidence") "Native advisory evidence"
Assert-Equal ([string]$nativeEvidence.sha256) (Get-Sha256 $nativeEvidencePath) "Native advisory evidence SHA256 must match current bytes."
Assert-Equal "subversionr.release.native-advisory-review.win32-x64.v1" ([string]$nativeEvidence.schema) "Native advisory evidence schema should match M7l2b."
Assert-Equal 7 ([int]$nativeEvidence.maxAgeDays) "Native advisory evidence maxAgeDays should remain seven days."
Assert-RequiredBooleanTrue $nativeEvidence "fresh" "Native advisory evidence freshness"

$nativeAdvisory = Get-Content -Raw -LiteralPath $nativeEvidencePath | ConvertFrom-Json
Assert-Equal "subversionr.release.native-advisory-review.win32-x64.v1" ([string]$nativeAdvisory.schema) "Native advisory evidence schema should match M7l2b."
Assert-Equal $Target ([string]$nativeAdvisory.target) "Native advisory evidence target should match the requested target."
Assert-RequiredBooleanFalse $nativeAdvisory "publicReadinessClaim" "Native advisory evidence"
Assert-RequiredBooleanFalse $nativeAdvisory "vulnerabilityReviewComplete" "Native advisory evidence"
Assert-RequiredBooleanFalse $nativeAdvisory "nativeAdvisoryReviewComplete" "Native advisory evidence"
Assert-Equal "required" ([string]$nativeAdvisory.nativeReview.status) "Native advisory review status must remain required."
Assert-RequiredBooleanTrue $nativeAdvisory.nativeReview "releaseBlocking" "Native advisory review"
Assert-RequiredBooleanTrue $nativeAdvisory.nativeReview "sourceContractComplete" "Native advisory review"
Assert-RequiredBooleanFalse $nativeAdvisory.review "triageComplete" "Native advisory review"
Assert-RequiredBooleanFalse $nativeAdvisory.review "remediationApproved" "Native advisory review"
Assert-RequiredBooleanFalse $nativeAdvisory.review "vexDecisionsComplete" "Native advisory review"
Assert-FreshTimestamp ([string]$nativeAdvisory.generatedAt) "Native advisory evidence" ([int]$nativeEvidence.maxAgeDays)

$liveOsvEvidence = $report.evidence.liveOsv
$liveOsvPath = Assert-File (Assert-RequiredString $liveOsvEvidence "path" "Live OSV evidence") "Live OSV evidence"
Assert-Equal ([string]$liveOsvEvidence.sha256) (Get-Sha256 $liveOsvPath) "Live OSV evidence SHA256 must match current bytes."
Assert-Equal "subversionr.release.vulnerability-review-osv.win32-x64.v1" ([string]$liveOsvEvidence.schema) "Live OSV evidence schema should match M7l2a."
Assert-Equal ([string]$nativeAdvisory.evidence.liveOsv.sha256) ([string]$liveOsvEvidence.sha256) "Live OSV SHA256 should match the M7l2b reference."

$liveOsv = Get-Content -Raw -LiteralPath $liveOsvPath | ConvertFrom-Json
Assert-Equal "subversionr.release.vulnerability-review-osv.win32-x64.v1" ([string]$liveOsv.schema) "Live OSV evidence schema should match M7l2a."
Assert-Equal $Target ([string]$liveOsv.target) "Live OSV target should match the requested target."
Assert-RequiredBooleanFalse $liveOsv "publicReadinessClaim" "Live OSV evidence"
Assert-RequiredBooleanFalse $liveOsv "vulnerabilityReviewComplete" "Live OSV evidence"
Assert-RequiredBooleanTrue $liveOsv "liveOsvEvidence" "Live OSV evidence"
Assert-RequiredBooleanFalse $liveOsv.review "triageComplete" "Live OSV review"
Assert-RequiredBooleanFalse $liveOsv.review "remediationApproved" "Live OSV review"
Assert-RequiredBooleanFalse $liveOsv.review "vexDecisionsComplete" "Live OSV review"

$nativeComponents = ConvertTo-ObjectArray $nativeAdvisory.nativeReview.components
$osvFindings = @()
if (Test-HasProperty $liveOsv.review "findings") {
  $osvFindings = ConvertTo-ObjectArray $liveOsv.review.findings
}
$expectedRows = @()
$expectedRows += @($nativeComponents | ForEach-Object { New-ExpectedNativeRow $_ })
$expectedRows += @($osvFindings | ForEach-Object { New-ExpectedOsvRow $_ })
$actualRows = ConvertTo-ObjectArray $report.triageInput.rows

Assert-Equal "required" ([string]$report.triageInput.status) "Native advisory triage input status must remain required."
Assert-RequiredBooleanTrue $report.triageInput "releaseBlocking" "Native advisory triage input"
Assert-Equal (@($nativeComponents).Count) ([int]$report.triageInput.nativeComponentRowCount) "nativeComponentRowCount should match M7l2b native components."
Assert-Equal (@($osvFindings).Count) ([int]$report.triageInput.osvFindingRowCount) "osvFindingRowCount should match M7l2a findings."
Assert-Equal (@($expectedRows).Count) ([int]$report.triageInput.totalRowCount) "totalRowCount should match expected rows."

$actualByKey = @{}
foreach ($row in $actualRows) {
  $key = Assert-RequiredString $row "key" "Native advisory triage input row"
  Assert-True (-not $actualByKey.ContainsKey($key)) "Native advisory triage input row key '$key' is duplicated."
  $actualByKey[$key] = $row
}

$expectedKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($expected in $expectedRows) {
  [void]$expectedKeys.Add([string]$expected.key)
  Assert-True ($actualByKey.ContainsKey([string]$expected.key)) "Missing native advisory triage input rows: $($expected.key)"
  $row = $actualByKey[[string]$expected.key]
  Assert-Equal ([string]$expected.kind) ([string]$row.kind) "Native advisory triage input row '$($expected.key)' kind should match."
  if ([string]$expected.kind -eq "native-component") {
    Assert-Equal ([string]$expected.componentName) ([string]$row.componentName) "Native row '$($expected.key)' componentName should match."
    Assert-Equal ([string]$expected.version) ([string]$row.version) "Native row '$($expected.key)' version should match."
    Assert-Equal (@($expected.advisorySourceIds) -join ",") (@($row.advisorySourceIds) -join ",") "Native row '$($expected.key)' advisorySourceIds should match."
  } else {
    Assert-Equal ([string]$expected.findingId) ([string]$row.findingId) "OSV row '$($expected.key)' findingId should match."
    Assert-Equal (@($expected.affectedPurls) -join ",") (@($row.affectedPurls) -join ",") "OSV row '$($expected.key)' affectedPurls should match."
  }
  Assert-RequiredInputShape $row "Native advisory triage input row '$($expected.key)'"
}

$extraRows = @($actualRows | Where-Object { -not $expectedKeys.Contains([string]$_.key) })
if (@($extraRows).Count -gt 0) {
  throw "Unexpected native advisory triage input rows: $(@($extraRows | ForEach-Object { $_.key }) -join ', ')."
}

foreach ($blocker in @(
    "Native advisory review is not complete.",
    "Vulnerability triage and remediation approval are not complete.",
    "VEX decisions are not complete.",
    "Final release approval for vulnerability findings is not complete."
  )) {
  Assert-ArrayContainsExactlyOnce -Values @($report.blockers) -Expected $blocker -Context "Native advisory triage input blockers"
}

foreach ($nonClaim in @(
    "This gate creates triage/remediation/VEX input rows only.",
    "This gate does not assert that native dependencies are free of known vulnerabilities.",
    "This gate does not complete native dependency advisory review.",
    "This gate does not approve remediation, suppression, exploitability, or VEX decisions.",
    "This gate does not claim public release readiness."
  )) {
  Assert-ArrayContainsExactlyOnce -Values @($report.nonClaims) -Expected $nonClaim -Context "Native advisory triage input nonClaims"
}

Write-Host "Verified SubversionR native advisory triage input for $Target at $evidenceResolved."

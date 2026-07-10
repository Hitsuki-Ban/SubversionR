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
$testEvidenceRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-native-advisory-review-scripts"))

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

function Assert-RequiredBooleanFalse([object]$Object, [string]$Name, [string]$Context) {
  if (-not (Test-HasProperty $Object $Name)) {
    throw "$Context must define $Name."
  }
  Assert-Equal "False" ([string]$Object.$Name) "$Context $Name must remain false."
}

function Assert-RequiredBooleanTrue([object]$Object, [string]$Name, [string]$Context) {
  if (-not (Test-HasProperty $Object $Name)) {
    throw "$Context must define $Name."
  }
  Assert-Equal "True" ([string]$Object.$Name) "$Context $Name must be true."
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
      throw "Native advisory review evidence must not record credentials, tokens, authorization headers, passwords, or secrets."
    }
  }
}

function Assert-SafeHttpsUrl([string]$Url, [string]$Context) {
  $uri = [System.Uri]::new($Url)
  if ($uri.Scheme -ne "https") {
    throw "$Context URL must use https: $Url"
  }
  if (-not [string]::IsNullOrEmpty($uri.UserInfo)) {
    throw "$Context URL must not include credentials: $Url"
  }
  $uri.AbsoluteUri
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

function ConvertTo-SourceDigest([object]$Source) {
  $digest = [ordered]@{}
  foreach ($name in @("sha512", "sha256", "sha3_256")) {
    $property = $Source.PSObject.Properties[$name]
    if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
      $digest[$name] = [string]$property.Value
    }
  }
  Assert-True ($digest.Count -gt 0) "Source lock component '$($Source.name)' must define at least one source digest."
  [pscustomobject]$digest
}

function Assert-DigestMatch([object]$Expected, [object]$Actual, [string]$Context) {
  foreach ($name in @("sha512", "sha256", "sha3_256")) {
    if (Test-HasProperty $Expected $name) {
      Assert-True (Test-HasProperty $Actual $name) "$Context should include digest $name."
      Assert-Equal ([string]$Expected.PSObject.Properties[$name].Value) ([string]$Actual.PSObject.Properties[$name].Value) "$Context digest $name should match the source lock."
    }
  }
}

function ConvertTo-AdvisorySourceRecords([object]$Sources, [string]$ComponentName) {
  $records = @()
  $seenIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($source in @($Sources)) {
    $id = Assert-RequiredString $source "id" "Advisory source for '$ComponentName'"
    Assert-True ($seenIds.Add($id)) "Advisory source ID '$id' is duplicated for '$ComponentName'."
    $type = Assert-RequiredString $source "type" "Advisory source '$id'"
    $authority = Assert-RequiredString $source "authority" "Advisory source '$id'"
    if (@("project", "vendor", "asf", "github-security", "nvd", "osv") -notcontains $authority) {
      throw "Advisory source '$id' authority must be project, vendor, asf, github-security, nvd, or osv."
    }
    $url = Assert-SafeHttpsUrl (Assert-RequiredString $source "url" "Advisory source '$id'") "Advisory source '$id'"
    $purpose = Assert-RequiredString $source "purpose" "Advisory source '$id'"
    $records += [pscustomobject]@{
      id = $id
      type = $type
      authority = $authority
      url = $url
      purpose = $purpose
    }
  }
  Assert-True ($records.Count -gt 0) "Component '$ComponentName' must define at least one advisory source."
  @($records)
}

$evidenceResolved = Assert-GeneratedPath -Path $EvidencePath -Name "EvidencePath" -AllowedRoots @(
  $releaseEvidenceRoot,
  $testEvidenceRoot
) -Description "target/release-evidence or target/tests/release-native-advisory-review-scripts"

$rawEvidence = Get-Content -Raw -LiteralPath $evidenceResolved
Assert-NoCredentialEvidenceText $rawEvidence
$report = $rawEvidence | ConvertFrom-Json

Assert-Equal 1 ([int]$report.schemaVersion) "Native advisory review schemaVersion should be 1."
Assert-Equal "subversionr.release.native-advisory-review.win32-x64.v1" ([string]$report.schema) "Native advisory review schema should match M7l2b."
Assert-Equal $Target ([string]$report.target) "Native advisory review target should match the requested target."
Assert-RequiredBooleanFalse $report "publicReadinessClaim" "Native advisory review"
Assert-RequiredBooleanFalse $report "vulnerabilityReviewComplete" "Native advisory review"
Assert-RequiredBooleanFalse $report "nativeAdvisoryReviewComplete" "Native advisory review"

foreach ($traceId in @("SEC-015", "MIG-012", "TST-024")) {
  Assert-ArrayContainsExactlyOnce -Values @($report.traceIds) -Expected $traceId -Context "Native advisory review trace IDs"
}

$sourceLockEvidence = $report.evidence.sourceLock
$sourceLockPath = Assert-File (Assert-RequiredString $sourceLockEvidence "path" "Source lock evidence") "Source lock evidence"
Assert-Equal ([string]$sourceLockEvidence.sha256) (Get-Sha256 $sourceLockPath) "Source lock SHA256 must match current bytes."

$liveOsvEvidence = $report.evidence.liveOsv
$liveOsvPath = Assert-File (Assert-RequiredString $liveOsvEvidence "path" "Live OSV evidence") "Live OSV evidence"
Assert-Equal ([string]$liveOsvEvidence.sha256) (Get-Sha256 $liveOsvPath) "Live OSV SHA256 must match current bytes."
Assert-Equal "subversionr.release.vulnerability-review-osv.win32-x64.v1" ([string]$liveOsvEvidence.schema) "Live OSV evidence schema should match M7l2a."
Assert-Equal 7 ([int]$liveOsvEvidence.maxAgeDays) "Live OSV maxAgeDays should remain seven days."
Assert-RequiredBooleanTrue $liveOsvEvidence "fresh" "Live OSV evidence freshness"

$advisorySourcesEvidence = $report.evidence.advisorySources
$advisorySourcesPath = Assert-File (Assert-RequiredString $advisorySourcesEvidence "path" "Advisory source contract evidence") "Advisory source contract evidence"
Assert-Equal ([string]$advisorySourcesEvidence.sha256) (Get-Sha256 $advisorySourcesPath) "Advisory source contract SHA256 must match current bytes."
Assert-Equal "subversionr.security.native-advisory-sources.v1" ([string]$advisorySourcesEvidence.schema) "Advisory source contract schema should match M7l2b."

$sourceLock = Get-Content -Raw -LiteralPath $sourceLockPath | ConvertFrom-Json
$liveOsv = Get-Content -Raw -LiteralPath $liveOsvPath | ConvertFrom-Json
$advisoryContract = Get-Content -Raw -LiteralPath $advisorySourcesPath | ConvertFrom-Json

Assert-Equal "subversionr.release.vulnerability-review-osv.win32-x64.v1" ([string]$liveOsv.schema) "Live OSV evidence schema should match M7l2a."
Assert-Equal $Target ([string]$liveOsv.target) "Live OSV target should match the requested target."
Assert-RequiredBooleanFalse $liveOsv "publicReadinessClaim" "Live OSV evidence"
Assert-RequiredBooleanFalse $liveOsv "vulnerabilityReviewComplete" "Live OSV evidence"
Assert-RequiredBooleanTrue $liveOsv "liveOsvEvidence" "Live OSV evidence"
Assert-Equal "queried" ([string]$liveOsv.osv.status) "Live OSV status must be queried."
Assert-RequiredBooleanTrue $liveOsv.osv "liveQueryPerformed" "Live OSV"
Assert-RequiredBooleanTrue $liveOsv.osv "resultRecorded" "Live OSV"
Assert-Equal "passed" ([string]$liveOsv.osv.positiveControl.status) "Live OSV positive control must pass."
Assert-Equal "required" ([string]$liveOsv.manualReview.status) "Live OSV manual review status must remain required."
Assert-RequiredBooleanTrue $liveOsv.manualReview "releaseBlocking" "Live OSV manual review"
Assert-RequiredBooleanFalse $liveOsv.review "triageComplete" "Live OSV review"
Assert-RequiredBooleanFalse $liveOsv.review "remediationApproved" "Live OSV review"
Assert-RequiredBooleanFalse $liveOsv.review "vexDecisionsComplete" "Live OSV review"
Assert-FreshTimestamp ([string]$liveOsv.generatedAt) "Live OSV evidence" ([int]$liveOsvEvidence.maxAgeDays)

Assert-Equal 1 ([int]$advisoryContract.schemaVersion) "Advisory source contract schemaVersion should be 1."
Assert-Equal "subversionr.security.native-advisory-sources.v1" ([string]$advisoryContract.schema) "Advisory source contract schema should match M7l2b."

$sourceComponents = @($sourceLock.sources)
Assert-Equal $sourceComponents.Count ([int]$sourceLockEvidence.componentCount) "Source lock componentCount should match sources."
Assert-Equal $sourceComponents.Count ([int]$advisorySourcesEvidence.componentCount) "Advisory source contract componentCount should match sources."
Assert-Equal $sourceComponents.Count ([int]$report.nativeReview.componentCount) "Native review componentCount should match sources."
Assert-Equal $sourceComponents.Count @($report.nativeReview.components).Count "Native review components should match sources."

$contractByName = @{}
foreach ($contract in @($advisoryContract.components)) {
  $name = Assert-RequiredString $contract "name" "Advisory source contract component"
  Assert-True (-not $contractByName.ContainsKey($name)) "Advisory source contract component '$name' is duplicated."
  $contractByName[$name] = $contract
}

$reportByName = @{}
foreach ($component in @($report.nativeReview.components)) {
  $name = Assert-RequiredString $component "name" "Native review component"
  Assert-True (-not $reportByName.ContainsKey($name)) "Native review component '$name' is duplicated."
  $reportByName[$name] = $component
}

foreach ($source in $sourceComponents) {
  $name = Assert-RequiredString $source "name" "Source lock component"
  Assert-True ($contractByName.ContainsKey($name)) "Advisory source contract should include '$name'."
  Assert-True ($reportByName.ContainsKey($name)) "Native advisory review should include '$name'."
  $contract = $contractByName[$name]
  $component = $reportByName[$name]
  $expectedSources = ConvertTo-AdvisorySourceRecords $contract.advisorySources $name
  Assert-Equal ([string]$source.version) ([string]$component.version) "Native review '$name' version should match source lock."
  Assert-Equal ([string]$source.license) ([string]$component.license) "Native review '$name' license should match source lock."
  Assert-Equal (Assert-SafeHttpsUrl ([string]$source.url) "Source lock component '$name'") ([string]$component.sourceUrl) "Native review '$name' sourceUrl should match source lock."
  Assert-DigestMatch (ConvertTo-SourceDigest $source) $component.sourceDigest "Native review '$name'"
  Assert-Equal ([string]$contract.displayName) ([string]$component.displayName) "Native review '$name' displayName should match advisory contract."
  Assert-Equal ([string]$contract.primaryAuthority) ([string]$component.primaryAuthority) "Native review '$name' primaryAuthority should match advisory contract."
  Assert-Equal ([string]$contract.dedicatedAdvisoryIndex) ([string]$component.dedicatedAdvisoryIndex) "Native review '$name' dedicatedAdvisoryIndex should match advisory contract."
  Assert-Equal ([string]$contract.reviewLimitation) ([string]$component.reviewLimitation) "Native review '$name' reviewLimitation should match advisory contract."
  Assert-Equal $expectedSources.Count ([int]$component.advisorySourceCount) "Native review '$name' advisorySourceCount should match advisory contract."
  Assert-Equal $expectedSources.Count @($component.advisorySources).Count "Native review '$name' advisorySources should match advisory contract."
  for ($index = 0; $index -lt $expectedSources.Count; $index += 1) {
    Assert-Equal ([string]$expectedSources[$index].id) ([string]$component.advisorySources[$index].id) "Native review '$name' advisory source ID should match."
    Assert-Equal ([string]$expectedSources[$index].url) ([string]$component.advisorySources[$index].url) "Native review '$name' advisory source URL should match."
  }
  Assert-Equal "pending" ([string]$component.reviewStatus) "Native review '$name' reviewStatus must remain pending."
  Assert-RequiredBooleanTrue $component "releaseBlocking" "Native review '$name'"
  Assert-RequiredBooleanFalse $component "sourceReviewComplete" "Native review '$name'"
  Assert-Equal "pending" ([string]$component.triageStatus) "Native review '$name' triageStatus must remain pending."
  Assert-Equal "pending" ([string]$component.remediationDecision) "Native review '$name' remediationDecision must remain pending."
  Assert-Equal "pending" ([string]$component.vexDecision) "Native review '$name' vexDecision must remain pending."
}

Assert-Equal "required" ([string]$report.nativeReview.status) "Native review status must remain required."
Assert-RequiredBooleanTrue $report.nativeReview "releaseBlocking" "Native review"
Assert-RequiredBooleanTrue $report.nativeReview "sourceContractComplete" "Native review"
Assert-Equal "requires-native-advisory-review" ([string]$report.review.status) "Native advisory review status should require native advisory review."
Assert-RequiredBooleanFalse $report.review "triageComplete" "Native advisory review"
Assert-RequiredBooleanFalse $report.review "remediationApproved" "Native advisory review"
Assert-RequiredBooleanFalse $report.review "vexDecisionsComplete" "Native advisory review"

foreach ($blocker in @(
    "Native advisory review is not complete.",
    "Vulnerability triage and remediation approval are not complete.",
    "VEX decisions are not complete.",
    "Built-artifact provenance binding remains required before public release.",
    "Final release approval for vulnerability findings is not complete."
  )) {
  Assert-ArrayContainsExactlyOnce -Values @($report.blockers) -Expected $blocker -Context "Native advisory blockers"
}

foreach ($nonClaim in @(
    "This gate records advisory source contracts for native source-lock components only.",
    "This gate does not assert that native dependencies are free of known vulnerabilities.",
    "This gate does not complete native dependency advisory review.",
    "This gate does not approve remediation, suppression, exploitability, or VEX decisions.",
    "This gate does not prove that the source lock matches the built native artifact.",
    "This gate does not complete final SBOM, NOTICE, signing, attestation, Marketplace/public install, or previous-stable rollback blockers.",
    "This gate does not claim public release readiness."
  )) {
  Assert-ArrayContainsExactlyOnce -Values @($report.nonClaims) -Expected $nonClaim -Context "Native advisory nonClaims"
}

Write-Host "Verified SubversionR native advisory review for $Target at $evidenceResolved."

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$SourceLockPath,

  [Parameter(Mandatory = $true)]
  [string]$LiveOsvEvidencePath,

  [Parameter(Mandatory = $true)]
  [string]$AdvisorySourcesPath,

  [Parameter(Mandatory = $true)]
  [string]$OutputPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$maxLiveOsvAgeDays = 7

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

function Assert-SafeHttpsUrl([string]$Url, [string]$Context) {
  if ([string]::IsNullOrWhiteSpace($Url)) {
    throw "$Context URL must be non-empty."
  }
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
  [pscustomobject]@{
    generatedAt = $timestamp.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
    maxAgeDays = $MaxAgeDays
    ageSeconds = [Math]::Max(0, [int][Math]::Round($age.TotalSeconds))
    fresh = $true
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

$sourceLockResolved = Assert-File $SourceLockPath "SourceLockPath"
$liveOsvResolved = Assert-File $LiveOsvEvidencePath "LiveOsvEvidencePath"
$advisorySourcesResolved = Assert-File $AdvisorySourcesPath "AdvisorySourcesPath"
$outputResolved = Assert-GeneratedPath -Path $OutputPath -Name "OutputPath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-native-advisory-review-scripts"))
) -Description "target/release-evidence or target/tests/release-native-advisory-review-scripts"

$sourceLock = Get-Content -Raw -LiteralPath $sourceLockResolved | ConvertFrom-Json
$liveOsv = Get-Content -Raw -LiteralPath $liveOsvResolved | ConvertFrom-Json
$advisoryContract = Get-Content -Raw -LiteralPath $advisorySourcesResolved | ConvertFrom-Json

$sourceComponents = @($sourceLock.sources)
Assert-True ($sourceComponents.Count -gt 0) "Source lock must contain native sources."
$sourceByName = @{}
foreach ($source in $sourceComponents) {
  $name = Assert-RequiredString $source "name" "Source lock component"
  Assert-True (-not $sourceByName.ContainsKey($name)) "Source lock component '$name' is duplicated."
  Assert-RequiredString $source "version" "Source lock component '$name'" | Out-Null
  Assert-RequiredString $source "license" "Source lock component '$name'" | Out-Null
  Assert-SafeHttpsUrl (Assert-RequiredString $source "url" "Source lock component '$name'") "Source lock component '$name'" | Out-Null
  ConvertTo-SourceDigest $source | Out-Null
  $sourceByName[$name] = $source
}

Assert-Equal "subversionr.release.vulnerability-review-osv.win32-x64.v1" ([string]$liveOsv.schema) "Live OSV evidence schema must match M7l2a."
Assert-Equal $Target ([string]$liveOsv.target) "Live OSV target must match the requested target."
Assert-RequiredBooleanFalse $liveOsv "publicReadinessClaim" "Live OSV evidence"
Assert-RequiredBooleanFalse $liveOsv "vulnerabilityReviewComplete" "Live OSV evidence"
Assert-RequiredBooleanTrue $liveOsv "liveOsvEvidence" "Live OSV evidence"
Assert-Equal "queried" ([string]$liveOsv.osv.status) "Live OSV status must be queried."
Assert-RequiredBooleanTrue $liveOsv.osv "liveQueryPerformed" "Live OSV"
Assert-RequiredBooleanTrue $liveOsv.osv "resultRecorded" "Live OSV"
Assert-Equal "passed" ([string]$liveOsv.osv.positiveControl.status) "Live OSV positive control must pass."
Assert-True ([int]$liveOsv.osv.positiveControl.vulnerabilityCount -gt 0) "Live OSV positive control must include at least one vulnerability."
Assert-Equal "required" ([string]$liveOsv.manualReview.status) "Live OSV manual review status must remain required."
Assert-RequiredBooleanTrue $liveOsv.manualReview "releaseBlocking" "Live OSV manual review"
Assert-RequiredBooleanFalse $liveOsv.review "triageComplete" "Live OSV review"
Assert-RequiredBooleanFalse $liveOsv.review "remediationApproved" "Live OSV review"
Assert-RequiredBooleanFalse $liveOsv.review "vexDecisionsComplete" "Live OSV review"
$liveOsvFreshness = Assert-FreshTimestamp ([string]$liveOsv.generatedAt) "Live OSV evidence" $maxLiveOsvAgeDays

Assert-Equal 1 ([int]$advisoryContract.schemaVersion) "Advisory source contract schemaVersion should be 1."
Assert-Equal "subversionr.security.native-advisory-sources.v1" ([string]$advisoryContract.schema) "Advisory source contract schema should match M7l2b."
Assert-RequiredString $advisoryContract "capturedAt" "Advisory source contract" | Out-Null
$contracts = @($advisoryContract.components)
Assert-True ($contracts.Count -gt 0) "Advisory source contract must contain components."
$contractByName = @{}
foreach ($contract in $contracts) {
  $name = Assert-RequiredString $contract "name" "Advisory source contract component"
  Assert-True (-not $contractByName.ContainsKey($name)) "Advisory source contract component '$name' is duplicated."
  Assert-RequiredString $contract "displayName" "Advisory source contract component '$name'" | Out-Null
  Assert-RequiredString $contract "primaryAuthority" "Advisory source contract component '$name'" | Out-Null
  Assert-RequiredString $contract "reviewLimitation" "Advisory source contract component '$name'" | Out-Null
  if (-not (Test-HasProperty $contract "dedicatedAdvisoryIndex")) {
    throw "Advisory source contract component '$name' must define dedicatedAdvisoryIndex."
  }
  ConvertTo-AdvisorySourceRecords $contract.advisorySources $name | Out-Null
  $contractByName[$name] = $contract
}

$missingContracts = @($sourceByName.Keys | Where-Object { -not $contractByName.ContainsKey($_) } | Sort-Object)
if ($missingContracts.Count -gt 0) {
  throw "Missing advisory source contracts for native source-lock components: $($missingContracts -join ', ')."
}
$extraContracts = @($contractByName.Keys | Where-Object { -not $sourceByName.ContainsKey($_) } | Sort-Object)
if ($extraContracts.Count -gt 0) {
  throw "Advisory source contracts are not present in the native source lock: $($extraContracts -join ', ')."
}

$componentRecords = @()
foreach ($source in $sourceComponents) {
  $name = [string]$source.name
  $contract = $contractByName[$name]
  $advisorySources = ConvertTo-AdvisorySourceRecords $contract.advisorySources $name
  $componentRecords += [pscustomobject]@{
    name = $name
    displayName = [string]$contract.displayName
    version = [string]$source.version
    license = [string]$source.license
    sourceUrl = Assert-SafeHttpsUrl ([string]$source.url) "Source lock component '$name'"
    sourceDigest = ConvertTo-SourceDigest $source
    primaryAuthority = [string]$contract.primaryAuthority
    dedicatedAdvisoryIndex = [bool]$contract.dedicatedAdvisoryIndex
    advisorySourceCount = $advisorySources.Count
    advisorySources = $advisorySources
    reviewLimitation = [string]$contract.reviewLimitation
    reviewStatus = "pending"
    releaseBlocking = $true
    sourceReviewComplete = $false
    triageStatus = "pending"
    remediationDecision = "pending"
    vexDecision = "pending"
  }
}

$report = [pscustomobject]@{
  schemaVersion = 1
  schema = "subversionr.release.native-advisory-review.win32-x64.v1"
  publicReadinessClaim = $false
  vulnerabilityReviewComplete = $false
  nativeAdvisoryReviewComplete = $false
  target = $Target
  traceIds = @("SEC-015", "MIG-012", "TST-024")
  generatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
  evidence = [pscustomobject]@{
    sourceLock = [pscustomobject]@{
      path = Get-RepoRelativePath $sourceLockResolved
      sha256 = Get-Sha256 $sourceLockResolved
      componentCount = $sourceComponents.Count
    }
    liveOsv = [pscustomobject]@{
      path = Get-RepoRelativePath $liveOsvResolved
      sha256 = Get-Sha256 $liveOsvResolved
      schema = [string]$liveOsv.schema
      generatedAt = $liveOsvFreshness.generatedAt
      maxAgeDays = $liveOsvFreshness.maxAgeDays
      ageSeconds = $liveOsvFreshness.ageSeconds
      fresh = $liveOsvFreshness.fresh
      findingCount = [int]$liveOsv.review.findingCount
      manualReviewComponentCount = [int]$liveOsv.manualReview.componentCount
    }
    advisorySources = [pscustomobject]@{
      path = Get-RepoRelativePath $advisorySourcesResolved
      sha256 = Get-Sha256 $advisorySourcesResolved
      schema = [string]$advisoryContract.schema
      capturedAt = [string]$advisoryContract.capturedAt
      componentCount = $contracts.Count
    }
  }
  nativeReview = [pscustomobject]@{
    status = "required"
    releaseBlocking = $true
    sourceContractComplete = $true
    componentCount = $componentRecords.Count
    components = $componentRecords
    blockers = @(
      "Native source-lock components have advisory source contracts but still require manual review.",
      "Native advisory source coverage does not prove built-artifact provenance."
    )
  }
  review = [pscustomobject]@{
    status = "requires-native-advisory-review"
    triageComplete = $false
    remediationApproved = $false
    vexDecisionsComplete = $false
    findingCount = [int]$liveOsv.review.findingCount
    upstreamLiveOsvFindingsCarriedForward = $true
  }
  blockers = @(
    "Native advisory review is not complete.",
    "Vulnerability triage and remediation approval are not complete.",
    "VEX decisions are not complete.",
    "Built-artifact provenance binding remains required before public release.",
    "Final release approval for vulnerability findings is not complete."
  )
  nonClaims = @(
    "This gate records advisory source contracts for native source-lock components only.",
    "This gate does not assert that native dependencies are free of known vulnerabilities.",
    "This gate does not complete native dependency advisory review.",
    "This gate does not approve remediation, suppression, exploitability, or VEX decisions.",
    "This gate does not prove that the source lock matches the built native artifact.",
    "This gate does not complete final SBOM, NOTICE, signing, attestation, Marketplace/public install, or previous-stable rollback blockers.",
    "This gate does not claim public release readiness."
  )
  assertions = @(
    "The native source lock is bound by SHA256.",
    "The live OSV evidence is bound by SHA256 and must be no older than seven days.",
    "Every native source-lock component has an explicit advisory source contract.",
    "Components without a dedicated advisory feed remain release-blocking.",
    "Native advisory review, triage, remediation, and VEX decisions remain pending."
  )
}

$parent = Split-Path -Parent $outputResolved
New-Item -ItemType Directory -Force -Path $parent | Out-Null
$report | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $outputResolved -Encoding utf8

Write-Host "Generated SubversionR native advisory review for $Target at $outputResolved."

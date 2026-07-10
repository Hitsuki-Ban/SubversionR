[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$SourceLockPath,

  [Parameter(Mandatory = $true)]
  [string]$AdvisorySourcesPath,

  [Parameter(Mandatory = $true)]
  [string]$ArtifactMapPath,

  [Parameter(Mandatory = $true)]
  [string]$ManualReviewPath,

  [Parameter(Mandatory = $true)]
  [string]$DecisionInputPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$manualReviewTestRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-native-manual-advisory-review-scripts"))
$decisionInputTestRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-vulnerability-decision-input-scripts"))
$terminalVexStatuses = @("not_affected", "affected", "fixed")
$nonTerminalVexStatuses = @("under_investigation")

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

function Assert-InputPath([string]$Path, [string]$Name, [string[]]$AllowedRoots, [string]$Description) {
  $absolute = Get-RepoAbsolutePath $Path
  foreach ($allowedRoot in $AllowedRoots) {
    if (Test-IsPathWithin -Path $absolute -Root $allowedRoot) {
      if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) {
        throw "$Name must be a file: $Path"
      }
      return (Resolve-Path -LiteralPath $absolute -ErrorAction Stop).Path
    }
  }
  throw "$Name must resolve inside $Description`: $Path"
}

function Test-HasProperty([object]$Object, [string]$Name) {
  $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function ConvertTo-ObjectArray([object]$Value) {
  if ($null -eq $Value) {
    return @()
  }
  @($Value | Where-Object { $null -ne $_ })
}

function ConvertTo-StringArray([object]$Value) {
  @($Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
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

function Assert-RequiredBoolean([object]$Object, [string]$Name, [string]$Context) {
  if (-not (Test-HasProperty $Object $Name)) {
    throw "$Context must define $Name."
  }
  $value = $Object.PSObject.Properties[$Name].Value
  if ($value -isnot [bool]) {
    throw "$Context $Name must be a JSON boolean."
  }
  [bool]$value
}

function Assert-RequiredBooleanFalse([object]$Object, [string]$Name, [string]$Context) {
  $value = Assert-RequiredBoolean $Object $Name $Context
  if ($value) {
    throw "$Context $Name must remain false."
  }
}

function Assert-RequiredBooleanTrue([object]$Object, [string]$Name, [string]$Context) {
  $value = Assert-RequiredBoolean $Object $Name $Context
  if (-not $value) {
    throw "$Context $Name must be true."
  }
}

function Assert-ExactStringSet([string[]]$Actual, [string[]]$Expected, [string]$Context) {
  $actualSet = @($Actual | Sort-Object)
  $expectedSet = @($Expected | Sort-Object)
  Assert-Equal ($expectedSet -join ",") ($actualSet -join ",") "$Context must match the expected string set."
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
      throw "Native manual advisory review must not record credentials, tokens, authorization headers, passwords, or secrets."
    }
  }
}

function Assert-SafeHttpsUrl([string]$Url, [string]$Context) {
  if ([string]::IsNullOrWhiteSpace($Url)) {
    throw "$Context must define url."
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

function Assert-ReviewTimestamp([string]$Value, [string]$Context, [int]$MaxAgeDays) {
  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "$Context must define reviewedAt."
  }
  $timestamp = [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
  $now = [DateTimeOffset]::UtcNow
  if ($timestamp.UtcDateTime -gt $now.UtcDateTime.AddMinutes(5)) {
    throw "$Context reviewedAt is in the future: $Value"
  }
  if ($timestamp.UtcDateTime -lt $now.UtcDateTime.AddDays(-$MaxAgeDays)) {
    throw "$Context reviewedAt is stale; manual advisory reviews must be reviewed within $MaxAgeDays days."
  }
}

function Assert-ApprovalTimestamp([string]$Value, [string]$Context, [int]$MaxAgeDays) {
  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "$Context must define approvedAt."
  }
  $timestamp = [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
  $now = [DateTimeOffset]::UtcNow
  if ($timestamp.UtcDateTime -gt $now.UtcDateTime.AddMinutes(5)) {
    throw "$Context approvedAt is in the future: $Value"
  }
  if ($timestamp.UtcDateTime -lt $now.UtcDateTime.AddDays(-$MaxAgeDays)) {
    throw "$Context approvedAt is stale; terminal approvals must be reviewed within $MaxAgeDays days."
  }
}

function New-UniqueMap([object[]]$Rows, [string]$PropertyName, [string]$Context) {
  $map = @{}
  foreach ($row in $Rows) {
    $key = Assert-RequiredString $row $PropertyName $Context
    Assert-True (-not $map.ContainsKey($key)) "$Context '$key' is duplicated."
    $map[$key] = $row
  }
  $map
}

function Assert-ReviewEvidence([object[]]$EvidenceRows, [hashtable]$AllowedSourceIds, [string]$Context) {
  Assert-True (@($EvidenceRows).Count -gt 0) "$Context must define evidence."
  foreach ($evidence in $EvidenceRows) {
    [void](Assert-RequiredString $evidence "type" "$Context evidence")
    $sourceId = Assert-RequiredString $evidence "sourceId" "$Context evidence"
    Assert-True ($AllowedSourceIds.ContainsKey($sourceId)) "$Context evidence sourceId '$sourceId' is not present in the native advisory source contract."
    [void](Assert-SafeHttpsUrl (Assert-RequiredString $evidence "url" "$Context evidence") "$Context evidence")
    [void](Assert-RequiredString $evidence "summary" "$Context evidence")
  }
}

function Assert-TerminalFindings([object]$Review, [hashtable]$AllowedSourceIds, [string]$ComponentName, [string]$Version, [string]$Context) {
  $findings = ConvertTo-ObjectArray $Review.terminalFindings
  Assert-True (@($findings).Count -gt 0) "$Context terminalFindings must include CVE or named security-finding mapping."
  foreach ($finding in $findings) {
    $id = Assert-RequiredString $finding "id" "$Context terminalFindings"
    $type = Assert-RequiredString $finding "type" "$Context terminalFindings '$id'"
    Assert-True (@("cve", "named-security-finding") -contains $type) "$Context terminalFindings '$id' type must be cve or named-security-finding."
    if ($type -eq "cve") {
      Assert-True ($id -match '^CVE-\d{4}-\d{4,}$') "$Context terminalFindings '$id' must use a CVE identifier."
    }
    Assert-Equal $ComponentName (Assert-RequiredString $finding "affectedComponent" "$Context terminalFindings '$id'") "$Context terminalFindings '$id' affectedComponent should match the review component."
    Assert-Equal $Version (Assert-RequiredString $finding "resolvedInVersion" "$Context terminalFindings '$id'") "$Context terminalFindings '$id' resolvedInVersion should match the locked source version."
    $sourceId = Assert-RequiredString $finding "sourceId" "$Context terminalFindings '$id'"
    Assert-True ($AllowedSourceIds.ContainsKey($sourceId)) "$Context terminalFindings '$id' sourceId '$sourceId' is not present in the native advisory source contract."
    [void](Assert-SafeHttpsUrl (Assert-RequiredString $finding "url" "$Context terminalFindings '$id'") "$Context terminalFindings '$id'")
    [void](Assert-RequiredString $finding "resolutionStatement" "$Context terminalFindings '$id'")
  }
}

function Assert-NamedFindingResearchBurden([object]$Review, [hashtable]$SourceAuthorities, [string]$Context) {
  $hasNamedFinding = $false
  foreach ($finding in ConvertTo-ObjectArray $Review.terminalFindings) {
    if ((Assert-RequiredString $finding "type" "$Context terminalFindings") -eq "named-security-finding") {
      $hasNamedFinding = $true
    }
  }
  if (-not $hasNamedFinding) {
    return
  }
  $authorities = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($evidence in ConvertTo-ObjectArray $Review.evidence) {
    $sourceId = Assert-RequiredString $evidence "sourceId" "$Context evidence"
    if ($SourceAuthorities.ContainsKey($sourceId)) {
      [void]$authorities.Add([string]$SourceAuthorities[$sourceId])
    }
  }
  Assert-True ($authorities.Contains("nvd")) "$Context named-security-finding terminal grants require at least one nvd-authority evidence entry."
  Assert-True ($authorities.Contains("osv")) "$Context named-security-finding terminal grants require at least one osv-authority evidence entry."
  $impactStatement = Assert-RequiredString $Review "impactStatement" "$Context named-security-finding terminal grant"
  Assert-True ($impactStatement.Contains("does not assert")) "$Context named-security-finding terminal grants must keep an explicit does-not-assert impact disclaimer."
}

function Assert-TerminalApprovals([object]$Review, [string]$Context, [int]$MaxAgeDays, [string]$TerminalVexStatus) {
  $approvals = ConvertTo-ObjectArray $Review.approvals
  $reviewers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $expectedDecision = "approve-terminal-$TerminalVexStatus"
  foreach ($approval in $approvals) {
    $reviewer = Assert-RequiredString $approval "reviewer" "$Context approvals"
    [void]$reviewers.Add($reviewer)
    Assert-ApprovalTimestamp (Assert-RequiredString $approval "approvedAt" "$Context approvals '$reviewer'") "$Context approvals '$reviewer'" $MaxAgeDays
    $decision = Assert-RequiredString $approval "decision" "$Context approvals '$reviewer'"
    Assert-Equal $expectedDecision $decision "$Context approvals '$reviewer' approval decision should match terminalVexStatus."
  }
  Assert-True ($reviewers.Count -ge 2) "$Context terminal decisions require two distinct reviewer approvals."
}

function Assert-ManualReviewRow(
  [object]$Source,
  [object]$AdvisoryContract,
  [object]$ArtifactMapRow,
  [object]$Review,
  [object]$Decision,
  [int]$MaxAgeDays
) {
  $sourceName = Assert-RequiredString $Source "name" "Source lock row"
  $sourceVersion = Assert-RequiredString $Source "version" "Source lock row '$sourceName'"
  $expectedKey = "native:$sourceName@$sourceVersion"
  $context = "Manual advisory review row '$expectedKey'"

  Assert-Equal $expectedKey (Assert-RequiredString $Review "key" $context) "$context key should match source lock."
  Assert-Equal $sourceName (Assert-RequiredString $Review "componentName" $context) "$context componentName should match source lock."
  Assert-Equal $sourceVersion (Assert-RequiredString $Review "version" $context) "$context version should match source lock."

  $dedicatedAdvisoryIndex = Assert-RequiredBoolean $AdvisoryContract "dedicatedAdvisoryIndex" "Native advisory source contract '$sourceName'"
  Assert-True (-not $dedicatedAdvisoryIndex) "$context must only cover no-dedicated-index advisory source contracts."
  Assert-RequiredBooleanFalse $Review "dedicatedAdvisoryIndex" $context

  $packageMode = Assert-RequiredString $ArtifactMapRow "packageMode" "Native artifact map row '$sourceName'"
  Assert-Equal $sourceVersion (Assert-RequiredString $ArtifactMapRow "expectedVersion" "Native artifact map row '$sourceName'") "Native artifact map row '$sourceName' expectedVersion should match source lock."
  Assert-Equal $packageMode (Assert-RequiredString $Review "packageMode" $context) "$context packageMode should match the native artifact map."

  $contractSourceRows = ConvertTo-ObjectArray $AdvisoryContract.advisorySources
  $allowedSourceIds = @{}
  $expectedSourceIds = @()
  foreach ($sourceRow in $contractSourceRows) {
    $sourceId = Assert-RequiredString $sourceRow "id" "Native advisory source contract '$sourceName'"
    Assert-True (-not $allowedSourceIds.ContainsKey($sourceId)) "Native advisory source contract '$sourceName' sourceId '$sourceId' is duplicated."
    $allowedSourceIds[$sourceId] = Assert-RequiredString $sourceRow "authority" "Native advisory source contract '$sourceName' source '$sourceId'"
    $expectedSourceIds += $sourceId
    [void](Assert-SafeHttpsUrl (Assert-RequiredString $sourceRow "url" "Native advisory source contract '$sourceName' source '$sourceId'") "Native advisory source contract '$sourceName' source '$sourceId'")
  }
  Assert-True (@($expectedSourceIds).Count -gt 0) "Native advisory source contract '$sourceName' must define advisory sources."
  Assert-ExactStringSet (ConvertTo-StringArray $Review.advisorySourceIds) $expectedSourceIds "$context advisorySourceIds"

  [void](Assert-RequiredString $Review "reviewer" $context)
  Assert-ReviewTimestamp (Assert-RequiredString $Review "reviewedAt" $context) $context $MaxAgeDays
  Assert-ReviewEvidence (ConvertTo-ObjectArray $Review.evidence) $allowedSourceIds $context

  $terminalDecisionAllowed = Assert-RequiredBoolean $Review "terminalDecisionAllowed" $context
  $vexStatus = Assert-RequiredString $Review "vexStatus" $context
  $triageStatus = Assert-RequiredString $Review "triageStatus" $context
  $remediationDecision = Assert-RequiredString $Review "remediationDecision" $context

  if (-not $terminalDecisionAllowed) {
    Assert-Equal "under_investigation" $triageStatus "$context pending review triageStatus should remain under_investigation."
    Assert-Equal "under_investigation" $vexStatus "$context pending review vexStatus should remain under_investigation."
    Assert-Equal "pending" $remediationDecision "$context pending review remediationDecision should remain pending."
    Assert-RequiredBooleanTrue $Review "releaseBlocking" $context
    Assert-True (@(ConvertTo-ObjectArray $Review.blockers).Count -gt 0) "$context pending review must define blockers."
    Assert-True (@(ConvertTo-ObjectArray $Review.nonClaims).Count -gt 0) "$context pending review must define nonClaims."
  } else {
    $terminalVexStatus = Assert-RequiredString $Review "terminalVexStatus" $context
    Assert-True ($terminalVexStatuses -contains $terminalVexStatus) "$context terminalVexStatus '$terminalVexStatus' is unsupported."
    Assert-Equal $terminalVexStatus $vexStatus "$context vexStatus should match terminalVexStatus."
    Assert-Equal "complete" $triageStatus "$context terminal review must complete triage."
    Assert-TerminalFindings $Review $allowedSourceIds $sourceName $sourceVersion $context
    Assert-NamedFindingResearchBurden $Review $allowedSourceIds $context
    Assert-TerminalApprovals $Review $context $MaxAgeDays $terminalVexStatus
    if ($terminalVexStatus -eq "fixed") {
      Assert-Equal $sourceVersion (Assert-RequiredString $Review "fixedVersion" "$context fixed review") "$context fixedVersion should match locked source version."
      Assert-Equal "fixed" $remediationDecision "$context fixed review remediationDecision should be fixed."
    } elseif ($terminalVexStatus -eq "affected") {
      [void](Assert-RequiredString $Review "actionStatement" "$context affected review")
      Assert-Equal "remediate_before_release" $remediationDecision "$context affected review remediationDecision should require remediation before release."
    } elseif ($terminalVexStatus -eq "not_affected") {
      [void](Assert-RequiredString $Review "vexJustification" "$context not_affected review")
      [void](Assert-RequiredString $Review "impactStatement" "$context not_affected review")
      Assert-Equal "not_required" $remediationDecision "$context not_affected review remediationDecision should be not_required."
    }
  }

  if ($null -ne $Decision) {
    $decisionStatus = Assert-RequiredString $Decision "vexStatus" "Vulnerability decision row '$expectedKey'"
    if ($terminalVexStatuses -contains $decisionStatus) {
      if (-not $terminalDecisionAllowed) {
        throw "Vulnerability decision row '$expectedKey' requires a matching manual terminal review grant."
      }
      Assert-Equal $decisionStatus (Assert-RequiredString $Review "terminalVexStatus" $context) "Vulnerability decision row '$expectedKey' should match the manual terminal review grant."
      if ($decisionStatus -eq "fixed") {
        Assert-Equal (Assert-RequiredString $Review "fixedVersion" "$context fixed review") (Assert-RequiredString $Decision "fixedVersion" "Vulnerability decision row '$expectedKey' fixed decision") "Vulnerability decision row '$expectedKey' fixedVersion should match the manual terminal review grant."
      } elseif ($decisionStatus -eq "not_affected") {
        Assert-Equal (Assert-RequiredString $Review "vexJustification" "$context not_affected review") (Assert-RequiredString $Decision "vexJustification" "Vulnerability decision row '$expectedKey' not_affected decision") "Vulnerability decision row '$expectedKey' vexJustification should match the manual terminal review grant."
        Assert-Equal (Assert-RequiredString $Review "impactStatement" "$context not_affected review") (Assert-RequiredString $Decision "impactStatement" "Vulnerability decision row '$expectedKey' not_affected decision") "Vulnerability decision row '$expectedKey' impactStatement should match the manual terminal review grant."
      } elseif ($decisionStatus -eq "affected") {
        Assert-Equal (Assert-RequiredString $Review "actionStatement" "$context affected review") (Assert-RequiredString $Decision "actionStatement" "Vulnerability decision row '$expectedKey' affected decision") "Vulnerability decision row '$expectedKey' actionStatement should match the manual terminal review grant."
      }
    } elseif ($nonTerminalVexStatuses -contains $decisionStatus) {
      Assert-Equal "under_investigation" $decisionStatus "Vulnerability decision row '$expectedKey' non-terminal status should remain under_investigation."
    } else {
      throw "Vulnerability decision row '$expectedKey' has unsupported vexStatus '$decisionStatus'."
    }
  }
}

$sourceLockResolved = Assert-InputPath -Path $SourceLockPath -Name "SourceLockPath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "native")),
  $manualReviewTestRoot,
  $decisionInputTestRoot
) -Description "native or target/tests release script fixtures"
$advisorySourcesResolved = Assert-InputPath -Path $AdvisorySourcesPath -Name "AdvisorySourcesPath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "docs\security")),
  $manualReviewTestRoot,
  $decisionInputTestRoot
) -Description "docs/security or target/tests release script fixtures"
$artifactMapResolved = Assert-InputPath -Path $ArtifactMapPath -Name "ArtifactMapPath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "docs\release")),
  $manualReviewTestRoot,
  $decisionInputTestRoot
) -Description "docs/release or target/tests release script fixtures"
$manualReviewResolved = Assert-InputPath -Path $ManualReviewPath -Name "ManualReviewPath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "docs\security")),
  $manualReviewTestRoot,
  $decisionInputTestRoot
) -Description "docs/security or target/tests release script fixtures"
$decisionInputResolved = Assert-InputPath -Path $DecisionInputPath -Name "DecisionInputPath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "docs\security")),
  $manualReviewTestRoot,
  $decisionInputTestRoot
) -Description "docs/security or target/tests release script fixtures"

$rawManualReview = Get-Content -Raw -LiteralPath $manualReviewResolved
Assert-NoCredentialEvidenceText $rawManualReview
$manualReview = $rawManualReview | ConvertFrom-Json
$sourceLock = Get-Content -Raw -LiteralPath $sourceLockResolved | ConvertFrom-Json
$advisorySources = Get-Content -Raw -LiteralPath $advisorySourcesResolved | ConvertFrom-Json
$artifactMap = Get-Content -Raw -LiteralPath $artifactMapResolved | ConvertFrom-Json
$decisionInput = Get-Content -Raw -LiteralPath $decisionInputResolved | ConvertFrom-Json

Assert-Equal 1 ([int]$manualReview.schemaVersion) "Manual native advisory review schemaVersion should be 1."
Assert-Equal "subversionr.security.native-manual-advisory-review.win32-x64.v1" ([string]$manualReview.schema) "Manual native advisory review schema should match M7l2f."
Assert-Equal $Target ([string]$manualReview.target) "Manual native advisory review target should match the requested target."
Assert-RequiredBooleanFalse $manualReview "publicReadinessClaim" "Manual native advisory review"
Assert-RequiredBooleanFalse $manualReview "nativeManualAdvisoryReviewComplete" "Manual native advisory review"
Assert-RequiredBooleanFalse $manualReview.reviewPolicy "appliesToDedicatedAdvisoryIndex" "Manual native advisory review policy"
Assert-Equal 90 ([int]$manualReview.reviewPolicy.terminalDecisionMaxAgeDays) "Manual native advisory review policy terminalDecisionMaxAgeDays should remain 90."
Assert-RequiredBooleanTrue $manualReview.reviewPolicy "terminalDecisionRequiresFindingMapping" "Manual native advisory review policy"
Assert-RequiredBooleanTrue $manualReview.reviewPolicy "terminalDecisionRequiresTwoApprovals" "Manual native advisory review policy"
Assert-RequiredBooleanTrue $manualReview.reviewPolicy "underInvestigationIsReleaseBlocking" "Manual native advisory review policy"

Assert-Equal "subversionr.security.native-advisory-sources.v1" ([string]$advisorySources.schema) "Native advisory sources schema should match M7l2b."
Assert-Equal "subversionr.release.native-artifact-map.win32-x64.v1" ([string]$artifactMap.schema) "Native artifact map schema should match M7h."
Assert-Equal $Target ([string]$artifactMap.target) "Native artifact map target should match the requested target."
Assert-Equal "subversionr.security.vulnerability-decisions.v1" ([string]$decisionInput.schema) "Decision input schema should match M7l2d."
Assert-Equal $Target ([string]$decisionInput.target) "Decision input target should match the requested target."

$sourceRows = ConvertTo-ObjectArray $sourceLock.sources
$advisoryRows = ConvertTo-ObjectArray $advisorySources.components
$artifactRows = ConvertTo-ObjectArray $artifactMap.components
$reviewRows = ConvertTo-ObjectArray $manualReview.reviews
$decisionRows = ConvertTo-ObjectArray $decisionInput.decisions

$advisoryByName = New-UniqueMap $advisoryRows "name" "Native advisory source contract"
$artifactByName = New-UniqueMap $artifactRows "sourceName" "Native artifact map row"
$reviewByKey = New-UniqueMap $reviewRows "key" "Manual native advisory review row"
$decisionByKey = New-UniqueMap $decisionRows "key" "Decision input row"

$expectedManualKeys = @()
foreach ($source in $sourceRows) {
  $sourceName = Assert-RequiredString $source "name" "Source lock row"
  $sourceVersion = Assert-RequiredString $source "version" "Source lock row '$sourceName'"
  Assert-True ($advisoryByName.ContainsKey($sourceName)) "Missing native advisory source contract for '$sourceName'."
  Assert-True ($artifactByName.ContainsKey($sourceName)) "Missing native artifact map row for '$sourceName'."
  $dedicatedAdvisoryIndex = Assert-RequiredBoolean $advisoryByName[$sourceName] "dedicatedAdvisoryIndex" "Native advisory source contract '$sourceName'"
  if (-not $dedicatedAdvisoryIndex) {
    $expectedManualKeys += "native:$sourceName@$sourceVersion"
  }
}

$missingManualRows = @($expectedManualKeys | Where-Object { -not $reviewByKey.ContainsKey([string]$_) })
if (@($missingManualRows).Count -gt 0) {
  throw "Missing manual advisory review rows: $(@($missingManualRows) -join ', ')."
}

$expectedManualKeySet = @{}
foreach ($key in $expectedManualKeys) {
  $expectedManualKeySet[$key] = $true
}
$extraManualRows = @($reviewRows | Where-Object { -not $expectedManualKeySet.ContainsKey([string]$_.key) })
if (@($extraManualRows).Count -gt 0) {
  throw "Unexpected manual advisory review rows: $(@($extraManualRows | ForEach-Object { $_.key }) -join ', ')."
}

$terminalGrantCount = 0
foreach ($source in $sourceRows) {
  $sourceName = [string]$source.name
  $sourceVersion = [string]$source.version
  $key = "native:$sourceName@$sourceVersion"
  if (-not $expectedManualKeySet.ContainsKey($key)) {
    continue
  }
  $review = $reviewByKey[$key]
  $decision = $null
  if ($decisionByKey.ContainsKey($key)) {
    $decision = $decisionByKey[$key]
  }
  if (Assert-RequiredBoolean $review "terminalDecisionAllowed" "Manual advisory review row '$key'") {
    $terminalGrantCount += 1
  }
  Assert-ManualReviewRow $source $advisoryByName[$sourceName] $artifactByName[$sourceName] $review $decision ([int]$manualReview.reviewPolicy.terminalDecisionMaxAgeDays)
}

Write-Host "Verified SubversionR native manual advisory review for $Target at $manualReviewResolved. Manual rows: $(@($expectedManualKeys).Count); terminal grants: $terminalGrantCount."

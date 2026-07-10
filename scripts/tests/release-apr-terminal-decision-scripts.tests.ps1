$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$advisorySourcesPath = Join-Path $repoRoot "docs\security\native-advisory-sources.lock.json"
$manualReviewPath = Join-Path $repoRoot "docs\security\native-manual-advisory-review.win32-x64.json"
$decisionInputPath = Join-Path $repoRoot "docs\security\vulnerability-decisions.win32-x64.json"
$packageJsonPath = Join-Path $repoRoot "package.json"
$readinessVerifierPath = Join-Path $repoRoot "scripts\release\verify-readiness.ps1"

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw $Message
  }
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
  if ($Expected -ne $Actual) {
    throw "$Message Expected '$Expected', got '$Actual'."
  }
}

function Assert-HasProperty([object]$Value, [string]$PropertyName, [string]$Message) {
  Assert-True ($null -ne $Value.PSObject.Properties[$PropertyName]) $Message
}

function Assert-ExactStringSet([string[]]$Expected, [string[]]$Actual, [string]$Message) {
  $expectedSorted = @($Expected | Sort-Object)
  $actualSorted = @($Actual | Sort-Object)
  $missing = @($expectedSorted | Where-Object { $actualSorted -notcontains $_ })
  $extra = @($actualSorted | Where-Object { $expectedSorted -notcontains $_ })
  Assert-Equal $expectedSorted.Count $actualSorted.Count "$Message Set size should match."
  Assert-True ($missing.Count -eq 0) "$Message Missing expected values: $($missing -join ', ')."
  Assert-True ($extra.Count -eq 0) "$Message Unexpected values: $($extra -join ', ')."
}

function Get-RequiredKeyedRow([object[]]$Rows, [string]$Key, [string]$Label) {
  $matches = @($Rows | Where-Object { [string]$_.key -eq $Key })
  Assert-Equal 1 $matches.Count "$Label should contain exactly one row for $Key."
  $matches[0]
}

function Get-RequiredNamedRow([object[]]$Rows, [string]$Name, [string]$Label) {
  $matches = @($Rows | Where-Object { [string]$_.name -eq $Name })
  Assert-Equal 1 $matches.Count "$Label should contain exactly one row for $Name."
  $matches[0]
}

function Assert-RecentTimestamp([string]$Timestamp, [string]$Label) {
  $parsed = [DateTimeOffset]::Parse($Timestamp, [Globalization.CultureInfo]::InvariantCulture)
  Assert-True ($parsed -ge [DateTimeOffset]::UtcNow.AddDays(-90)) "$Label should be within the 90-day terminal decision window."
  Assert-True ($parsed -le [DateTimeOffset]::UtcNow.AddDays(1)) "$Label should not be future-dated."
}

$advisorySources = Get-Content -Raw -LiteralPath $advisorySourcesPath | ConvertFrom-Json
$manualReview = Get-Content -Raw -LiteralPath $manualReviewPath | ConvertFrom-Json
$decisionInput = Get-Content -Raw -LiteralPath $decisionInputPath | ConvertFrom-Json

$expectedTerminalNoDedicatedRows = @(
  "native:expat@2.8.1",
  "native:zlib@1.3.2",
  "native:apr@1.7.6",
  "native:apr-util@1.6.3",
  "native:serf@1.3.10",
  "native:apr-iconv@1.2.2"
)
$expectedRemainingNoDedicatedRows = @(
)
$expectedAprSourceIds = @(
  "apr-security-report",
  "asf-security",
  "apr-changes-1-7",
  "nvd-cve-2023-49582",
  "nvd-cve-2022-24963",
  "nvd-cve-2022-28331",
  "nvd-cve-2021-35940"
)
$expectedAprFindings = @(
  "CVE-2023-49582",
  "CVE-2022-24963",
  "CVE-2022-28331",
  "CVE-2021-35940"
)

$aprSourceContract = Get-RequiredNamedRow @($advisorySources.components) "apr" "Native advisory source contract"
Assert-Equal $false ([bool]$aprSourceContract.dedicatedAdvisoryIndex) "APR source contract should remain a no-dedicated-index component."
Assert-ExactStringSet $expectedAprSourceIds @($aprSourceContract.advisorySources | ForEach-Object { [string]$_.id }) "APR advisory source IDs should include reporting guidance, ASF process, APR changelog, and each named NVD CVE record."

Assert-Equal "subversionr.security.native-manual-advisory-review.win32-x64.v1" ([string]$manualReview.schema) "Manual review schema should stay bound to the native manual advisory gate."
Assert-Equal $false ([bool]$manualReview.publicReadinessClaim) "Manual review must not claim public release readiness."
Assert-Equal $false ([bool]$manualReview.nativeManualAdvisoryReviewComplete) "Manual review must remain an input contract and not claim full native advisory completion."
Assert-ExactStringSet $expectedTerminalNoDedicatedRows @($manualReview.reviews | Where-Object { [bool]$_.terminalDecisionAllowed } | ForEach-Object { [string]$_.key }) "Manual review terminal grant set should include every no-dedicated native row."
Assert-ExactStringSet $expectedRemainingNoDedicatedRows @($manualReview.reviews | Where-Object { -not [bool]$_.terminalDecisionAllowed } | ForEach-Object { [string]$_.key }) "Manual review pending set should be empty after APR-iconv terminal review."

$manualApr = Get-RequiredKeyedRow @($manualReview.reviews) "native:apr@1.7.6" "Manual review"
Assert-Equal "apr" ([string]$manualApr.componentName) "Manual APR row should stay component-bound."
Assert-Equal "1.7.6" ([string]$manualApr.version) "Manual APR row should stay version-bound."
Assert-Equal "packaged-runtime" ([string]$manualApr.packageMode) "Manual APR row should preserve packaged-runtime package scope."
Assert-ExactStringSet $expectedAprSourceIds @($manualApr.advisorySourceIds | ForEach-Object { [string]$_ }) "Manual APR row should list every APR source-contract source ID."
Assert-Equal $true ([bool]$manualApr.terminalDecisionAllowed) "Manual APR row should grant a terminal decision."
Assert-Equal "fixed" ([string]$manualApr.terminalVexStatus) "Manual APR row should grant only a fixed terminal status."
Assert-Equal "complete" ([string]$manualApr.triageStatus) "Manual APR row should complete triage."
Assert-Equal "fixed" ([string]$manualApr.vexStatus) "Manual APR row should record fixed VEX status."
Assert-Equal "fixed" ([string]$manualApr.remediationDecision) "Manual APR row should record fixed remediation."
Assert-Equal "1.7.6" ([string]$manualApr.fixedVersion) "Manual APR row should bind the fixed version to the locked source version."
Assert-Equal $false ([bool]$manualApr.releaseBlocking) "Manual APR terminal fixed row should not be release-blocking by itself."
Assert-RecentTimestamp ([string]$manualApr.reviewedAt) "Manual APR reviewedAt"

$manualFindings = @($manualApr.terminalFindings)
Assert-Equal 4 $manualFindings.Count "Manual APR row should map exactly four terminal findings in this slice."
Assert-ExactStringSet $expectedAprFindings @($manualFindings | ForEach-Object { [string]$_.id }) "Manual APR terminal findings should identify the expected CVEs."
foreach ($finding in $manualFindings) {
  $id = [string]$finding.id
  Assert-Equal "cve" ([string]$finding.type) "Manual APR terminal finding $id should be a CVE mapping."
  Assert-Equal "apr" ([string]$finding.affectedComponent) "Manual APR terminal finding $id should bind to APR."
  Assert-Equal "1.7.6" ([string]$finding.resolvedInVersion) "Manual APR terminal finding $id should resolve in the locked 1.7.6 source."
  Assert-True ([string]$finding.sourceId).Contains(($id.ToLowerInvariant())) "Manual APR terminal finding $id should use its locked NVD source."
  Assert-True ([string]$finding.url).Contains($id) "Manual APR terminal finding $id should cite the CVE URL."
  Assert-True ([string]$finding.resolutionStatement).Contains("1.7.6") "Manual APR terminal finding $id should mention the locked fixed source version."
}

$manualEvidenceText = ($manualApr.evidence | ConvertTo-Json -Depth 20)
foreach ($needle in @("apr-changes-1-7", "Changes for APR 1.7.5", "Changes for APR 1.7.1", "CVE-2023-49582", "CVE-2022-24963", "CVE-2022-28331", "CVE-2021-35940")) {
  Assert-True $manualEvidenceText.Contains($needle) "Manual APR evidence should include '$needle'."
}

$manualApprovals = @($manualApr.approvals)
Assert-Equal 2 $manualApprovals.Count "Manual APR row should include two terminal approvals."
Assert-Equal 2 @($manualApprovals | ForEach-Object { [string]$_.reviewer } | Sort-Object -Unique).Count "Manual APR approvals should come from two distinct reviewers."
foreach ($approval in $manualApprovals) {
  Assert-Equal "approve-terminal-fixed" ([string]$approval.decision) "Manual APR approval should match the fixed terminal status."
  Assert-RecentTimestamp ([string]$approval.approvedAt) "Manual APR approval approvedAt"
}

$manualNonClaims = @($manualApr.nonClaims | ForEach-Object { [string]$_ }) -join "`n"
Assert-True $manualNonClaims.Contains("does not claim public release readiness") "Manual APR row should keep public readiness out of scope."
Assert-True $manualNonClaims.Contains("does not assert that APR 1.7.6 is free of all known or unknown vulnerabilities") "Manual APR row should avoid broad vulnerability-free claims."

$decisionApr = Get-RequiredKeyedRow @($decisionInput.decisions) "native:apr@1.7.6" "Decision input"
Assert-Equal "complete" ([string]$decisionApr.triageStatus) "Decision APR row should complete triage."
Assert-Equal "fixed" ([string]$decisionApr.vexStatus) "Decision APR row should record fixed VEX status."
Assert-Equal "fixed" ([string]$decisionApr.remediationDecision) "Decision APR row should record fixed remediation."
Assert-Equal "1.7.6" ([string]$decisionApr.fixedVersion) "Decision APR row should bind fixedVersion to 1.7.6."
Assert-RecentTimestamp ([string]$decisionApr.reviewedAt) "Decision APR reviewedAt"

$decisionEvidenceText = (@($decisionApr.analysisEvidence) + @($decisionApr.fixEvidence) | ConvertTo-Json -Depth 20)
foreach ($needle in @("apr-changes-1-7", "CVE-2023-49582", "CVE-2022-24963", "CVE-2022-28331", "CVE-2021-35940", "1.7.6")) {
  Assert-True $decisionEvidenceText.Contains($needle) "Decision APR evidence should include '$needle'."
}

$manualReviewKeys = @($manualReview.reviews | ForEach-Object { [string]$_.key })
$manualDecisionTerminalKeys = @($decisionInput.decisions | Where-Object { ($manualReviewKeys -contains [string]$_.key) -and @("not_affected", "affected", "fixed").Contains([string]$_.vexStatus) } | ForEach-Object { [string]$_.key })
$underInvestigationKeys = @($decisionInput.decisions | Where-Object { [string]$_.vexStatus -eq "under_investigation" } | ForEach-Object { [string]$_.key })
Assert-ExactStringSet $expectedTerminalNoDedicatedRows $manualDecisionTerminalKeys "Decision input no-dedicated terminal set should include every no-dedicated native row."
Assert-ExactStringSet $expectedRemainingNoDedicatedRows $underInvestigationKeys "Decision input under-investigation set should be empty after APR-iconv terminal review."

$packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
Assert-HasProperty $packageJson.scripts "release:test-apr-terminal-decision-scripts" "Root package should expose APR terminal decision script tests."
Assert-True ($packageJson.scripts."release:test-apr-terminal-decision-scripts".Contains("release-apr-terminal-decision-scripts.tests.ps1")) "Root package APR terminal test script should run this test file."

$readinessVerifier = Get-Content -Raw -LiteralPath $readinessVerifierPath
foreach ($term in @(
    "M7l2i APR terminal CVE decision gate",
    "native:apr@1.7.6",
    "CVE-2023-49582",
    "CVE-2022-24963",
    "CVE-2022-28331",
    "CVE-2021-35940",
    "pnpm release:test-apr-terminal-decision-scripts"
  )) {
  Assert-True ($readinessVerifier.Contains($term)) "Release readiness verifier should require '$term'."
}

Write-Host "Release APR terminal decision script tests passed."

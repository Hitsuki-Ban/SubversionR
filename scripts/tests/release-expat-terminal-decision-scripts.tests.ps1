$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
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

function Get-RequiredRow([object[]]$Rows, [string]$Key, [string]$Label) {
  $matches = @($Rows | Where-Object { [string]$_.key -eq $Key })
  Assert-Equal 1 $matches.Count "$Label should contain exactly one row for $Key."
  $matches[0]
}

function Assert-RecentTimestamp([string]$Timestamp, [string]$Label) {
  $parsed = [DateTimeOffset]::Parse($Timestamp, [Globalization.CultureInfo]::InvariantCulture)
  Assert-True ($parsed -ge [DateTimeOffset]::UtcNow.AddDays(-90)) "$Label should be within the 90-day terminal decision window."
  Assert-True ($parsed -le [DateTimeOffset]::UtcNow.AddDays(1)) "$Label should not be future-dated."
}

$manualReview = Get-Content -Raw -LiteralPath $manualReviewPath | ConvertFrom-Json
$decisionInput = Get-Content -Raw -LiteralPath $decisionInputPath | ConvertFrom-Json
$expectedRemainingNoDedicatedRows = @(
)

Assert-Equal "subversionr.security.native-manual-advisory-review.win32-x64.v1" ([string]$manualReview.schema) "Manual review schema should stay bound to the native manual advisory gate."
Assert-Equal $false ([bool]$manualReview.publicReadinessClaim) "Manual review must not claim public release readiness."
Assert-Equal $false ([bool]$manualReview.nativeManualAdvisoryReviewComplete) "Manual review must remain an input contract and not claim full native advisory completion."
Assert-ExactStringSet @("native:expat@2.8.1", "native:zlib@1.3.2", "native:apr@1.7.6", "native:apr-util@1.6.3", "native:serf@1.3.10", "native:apr-iconv@1.2.2") @($manualReview.reviews | Where-Object { [bool]$_.terminalDecisionAllowed } | ForEach-Object { [string]$_.key }) "Manual review terminal grant set should include every no-dedicated native row."
Assert-ExactStringSet $expectedRemainingNoDedicatedRows @($manualReview.reviews | Where-Object { -not [bool]$_.terminalDecisionAllowed } | ForEach-Object { [string]$_.key }) "Manual review pending set should be empty after APR-iconv terminal review."

$manualExpat = Get-RequiredRow @($manualReview.reviews) "native:expat@2.8.1" "Manual review"
Assert-Equal "expat" ([string]$manualExpat.componentName) "Manual Expat row should stay component-bound."
Assert-Equal "2.8.1" ([string]$manualExpat.version) "Manual Expat row should stay version-bound."
Assert-Equal $true ([bool]$manualExpat.terminalDecisionAllowed) "Manual Expat row should grant a terminal decision."
Assert-Equal "fixed" ([string]$manualExpat.terminalVexStatus) "Manual Expat row should grant only a fixed terminal status."
Assert-Equal "complete" ([string]$manualExpat.triageStatus) "Manual Expat row should complete triage."
Assert-Equal "fixed" ([string]$manualExpat.vexStatus) "Manual Expat row should record fixed VEX status."
Assert-Equal "fixed" ([string]$manualExpat.remediationDecision) "Manual Expat row should record fixed remediation."
Assert-Equal "2.8.1" ([string]$manualExpat.fixedVersion) "Manual Expat row should bind the fixed version to the locked source version."
Assert-Equal $false ([bool]$manualExpat.releaseBlocking) "Manual Expat terminal fixed row should not be release-blocking by itself."
Assert-RecentTimestamp ([string]$manualExpat.reviewedAt) "Manual Expat reviewedAt"

$manualFindings = @($manualExpat.terminalFindings)
Assert-Equal 1 $manualFindings.Count "Manual Expat row should map exactly one terminal finding in this slice."
$expatFinding = $manualFindings[0]
Assert-Equal "CVE-2026-45186" ([string]$expatFinding.id) "Manual Expat terminal finding should identify CVE-2026-45186."
Assert-Equal "cve" ([string]$expatFinding.type) "Manual Expat terminal finding should be a CVE mapping."
Assert-Equal "expat" ([string]$expatFinding.affectedComponent) "Manual Expat terminal finding should bind to Expat."
Assert-Equal "2.8.1" ([string]$expatFinding.resolvedInVersion) "Manual Expat terminal finding should resolve in 2.8.1."
Assert-Equal "libexpat-changes" ([string]$expatFinding.sourceId) "Manual Expat terminal finding should use the locked source-contract changelog."
Assert-True ([string]$expatFinding.url).Contains("R_2_8_1/expat/Changes") "Manual Expat terminal finding should cite the 2.8.1 changelog."

$manualApprovals = @($manualExpat.approvals)
Assert-Equal 2 $manualApprovals.Count "Manual Expat row should include two terminal approvals."
Assert-Equal 2 @($manualApprovals | ForEach-Object { [string]$_.reviewer } | Sort-Object -Unique).Count "Manual Expat approvals should come from two distinct reviewers."
foreach ($approval in $manualApprovals) {
  Assert-Equal "approve-terminal-fixed" ([string]$approval.decision) "Manual Expat approval should match the fixed terminal status."
  Assert-RecentTimestamp ([string]$approval.approvedAt) "Manual Expat approval approvedAt"
}

$manualNonClaims = @($manualExpat.nonClaims | ForEach-Object { [string]$_ }) -join "`n"
Assert-True $manualNonClaims.Contains("does not claim public release readiness") "Manual Expat row should keep public readiness out of scope."

$decisionExpat = Get-RequiredRow @($decisionInput.decisions) "native:expat@2.8.1" "Decision input"
Assert-Equal "complete" ([string]$decisionExpat.triageStatus) "Decision Expat row should complete triage."
Assert-Equal "fixed" ([string]$decisionExpat.vexStatus) "Decision Expat row should record fixed VEX status."
Assert-Equal "fixed" ([string]$decisionExpat.remediationDecision) "Decision Expat row should record fixed remediation."
Assert-Equal "2.8.1" ([string]$decisionExpat.fixedVersion) "Decision Expat row should bind fixedVersion to 2.8.1."
Assert-RecentTimestamp ([string]$decisionExpat.reviewedAt) "Decision Expat reviewedAt"

$decisionEvidenceText = (@($decisionExpat.analysisEvidence) + @($decisionExpat.fixEvidence) | ConvertTo-Json -Depth 20)
Assert-True $decisionEvidenceText.Contains("libexpat-changes") "Decision Expat evidence should cite the libexpat changelog source contract."
Assert-True $decisionEvidenceText.Contains("CVE-2026-45186") "Decision Expat evidence should scope the fixed decision to CVE-2026-45186."
Assert-True $decisionEvidenceText.Contains("R_2_8_1/expat/Changes") "Decision Expat evidence should cite the 2.8.1 changelog URL."

$manualReviewKeys = @($manualReview.reviews | ForEach-Object { [string]$_.key })
$manualDecisionTerminalKeys = @($decisionInput.decisions | Where-Object { ($manualReviewKeys -contains [string]$_.key) -and @("not_affected", "affected", "fixed").Contains([string]$_.vexStatus) } | ForEach-Object { [string]$_.key })
$underInvestigationKeys = @($decisionInput.decisions | Where-Object { [string]$_.vexStatus -eq "under_investigation" } | ForEach-Object { [string]$_.key })
Assert-ExactStringSet @("native:expat@2.8.1", "native:zlib@1.3.2", "native:apr@1.7.6", "native:apr-util@1.6.3", "native:serf@1.3.10", "native:apr-iconv@1.2.2") $manualDecisionTerminalKeys "Decision input no-dedicated terminal set should include every no-dedicated native row."
Assert-ExactStringSet $expectedRemainingNoDedicatedRows $underInvestigationKeys "Decision input under-investigation set should be empty after APR-iconv terminal review."

$packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
Assert-HasProperty $packageJson.scripts "release:test-expat-terminal-decision-scripts" "Root package should expose Expat terminal decision script tests."
Assert-True ($packageJson.scripts."release:test-expat-terminal-decision-scripts".Contains("release-expat-terminal-decision-scripts.tests.ps1")) "Root package Expat terminal test script should run this test file."

$readinessVerifier = Get-Content -Raw -LiteralPath $readinessVerifierPath
foreach ($term in @(
    "M7l2g Expat terminal CVE-2026-45186 decision gate",
    "native:expat@2.8.1",
    "CVE-2026-45186",
    "pnpm release:test-expat-terminal-decision-scripts"
  )) {
  Assert-True ($readinessVerifier.Contains($term)) "Release readiness verifier should require '$term'."
}

Write-Host "Release Expat terminal decision script tests passed."

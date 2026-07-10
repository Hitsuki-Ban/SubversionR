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
$expectedSerfSourceIds = @(
  "apache-serf-project",
  "asf-security",
  "serf-changes-1-3",
  "nvd-cve-2014-3504"
)

$serfSourceContract = Get-RequiredNamedRow @($advisorySources.components) "serf" "Native advisory source contract"
Assert-Equal $false ([bool]$serfSourceContract.dedicatedAdvisoryIndex) "Serf source contract should remain a no-dedicated-index component."
Assert-ExactStringSet $expectedSerfSourceIds @($serfSourceContract.advisorySources | ForEach-Object { [string]$_.id }) "Serf advisory source IDs should include project context, ASF process, Serf changelog, and the named NVD CVE record."

Assert-Equal "subversionr.security.native-manual-advisory-review.win32-x64.v1" ([string]$manualReview.schema) "Manual review schema should stay bound to the native manual advisory gate."
Assert-Equal $false ([bool]$manualReview.publicReadinessClaim) "Manual review must not claim public release readiness."
Assert-Equal $false ([bool]$manualReview.nativeManualAdvisoryReviewComplete) "Manual review must remain an input contract and not claim full native advisory completion."
Assert-ExactStringSet $expectedTerminalNoDedicatedRows @($manualReview.reviews | Where-Object { [bool]$_.terminalDecisionAllowed } | ForEach-Object { [string]$_.key }) "Manual review terminal grant set should include every no-dedicated native row."
Assert-ExactStringSet $expectedRemainingNoDedicatedRows @($manualReview.reviews | Where-Object { -not [bool]$_.terminalDecisionAllowed } | ForEach-Object { [string]$_.key }) "Manual review pending set should be empty after APR-iconv terminal review."

$manualSerf = Get-RequiredKeyedRow @($manualReview.reviews) "native:serf@1.3.10" "Manual review"
Assert-Equal "serf" ([string]$manualSerf.componentName) "Manual Serf row should stay component-bound."
Assert-Equal "1.3.10" ([string]$manualSerf.version) "Manual Serf row should stay version-bound."
Assert-Equal "static-link-input" ([string]$manualSerf.packageMode) "Manual Serf row should preserve static-link-input package scope."
Assert-ExactStringSet $expectedSerfSourceIds @($manualSerf.advisorySourceIds | ForEach-Object { [string]$_ }) "Manual Serf row should list every Serf source-contract source ID."
Assert-Equal $true ([bool]$manualSerf.terminalDecisionAllowed) "Manual Serf row should grant a terminal decision."
Assert-Equal "fixed" ([string]$manualSerf.terminalVexStatus) "Manual Serf row should grant only a fixed terminal status."
Assert-Equal "complete" ([string]$manualSerf.triageStatus) "Manual Serf row should complete triage."
Assert-Equal "fixed" ([string]$manualSerf.vexStatus) "Manual Serf row should record fixed VEX status."
Assert-Equal "fixed" ([string]$manualSerf.remediationDecision) "Manual Serf row should record fixed remediation."
Assert-Equal "1.3.10" ([string]$manualSerf.fixedVersion) "Manual Serf row should bind the fixed version to the locked source version."
Assert-Equal $false ([bool]$manualSerf.releaseBlocking) "Manual Serf terminal fixed row should not be release-blocking by itself."
Assert-RecentTimestamp ([string]$manualSerf.reviewedAt) "Manual Serf reviewedAt"

$manualFindings = @($manualSerf.terminalFindings)
Assert-Equal 1 $manualFindings.Count "Manual Serf row should map exactly one terminal finding in this slice."
$serfFinding = $manualFindings[0]
Assert-Equal "CVE-2014-3504" ([string]$serfFinding.id) "Manual Serf terminal finding should identify CVE-2014-3504."
Assert-Equal "cve" ([string]$serfFinding.type) "Manual Serf terminal finding should be a CVE mapping."
Assert-Equal "serf" ([string]$serfFinding.affectedComponent) "Manual Serf terminal finding should bind to Serf."
Assert-Equal "1.3.10" ([string]$serfFinding.resolvedInVersion) "Manual Serf terminal finding should resolve in the locked 1.3.10 source."
Assert-Equal "nvd-cve-2014-3504" ([string]$serfFinding.sourceId) "Manual Serf terminal finding should use the locked NVD CVE source."
Assert-True ([string]$serfFinding.url).Contains("CVE-2014-3504") "Manual Serf terminal finding should cite the CVE URL."
Assert-True ([string]$serfFinding.resolutionStatement).Contains("1.3.x before 1.3.7") "Manual Serf resolution statement should record the affected upstream range."
Assert-True ([string]$serfFinding.resolutionStatement).Contains("1.3.10") "Manual Serf resolution statement should mention the locked fixed source version."

$manualEvidenceText = ($manualSerf.evidence | ConvertTo-Json -Depth 20)
foreach ($needle in @("serf-changes-1-3", "Serf 1.3.7", "Handle NUL bytes in fields of an X.509 certificate", "CVE-2014-3504", "1.3.x before 1.3.7")) {
  Assert-True $manualEvidenceText.Contains($needle) "Manual Serf evidence should include '$needle'."
}

$manualApprovals = @($manualSerf.approvals)
Assert-Equal 2 $manualApprovals.Count "Manual Serf row should include two terminal approvals."
Assert-Equal 2 @($manualApprovals | ForEach-Object { [string]$_.reviewer } | Sort-Object -Unique).Count "Manual Serf approvals should come from two distinct reviewers."
foreach ($approval in $manualApprovals) {
  Assert-Equal "approve-terminal-fixed" ([string]$approval.decision) "Manual Serf approval should match the fixed terminal status."
  Assert-RecentTimestamp ([string]$approval.approvedAt) "Manual Serf approval approvedAt"
}

$manualNonClaims = @($manualSerf.nonClaims | ForEach-Object { [string]$_ }) -join "`n"
Assert-True $manualNonClaims.Contains("does not claim public release readiness") "Manual Serf row should keep public readiness out of scope."
Assert-True $manualNonClaims.Contains("does not assert that Serf 1.3.10 is free of all known or unknown vulnerabilities") "Manual Serf row should avoid broad vulnerability-free claims."

$decisionSerf = Get-RequiredKeyedRow @($decisionInput.decisions) "native:serf@1.3.10" "Decision input"
Assert-Equal "complete" ([string]$decisionSerf.triageStatus) "Decision Serf row should complete triage."
Assert-Equal "fixed" ([string]$decisionSerf.vexStatus) "Decision Serf row should record fixed VEX status."
Assert-Equal "fixed" ([string]$decisionSerf.remediationDecision) "Decision Serf row should record fixed remediation."
Assert-Equal "1.3.10" ([string]$decisionSerf.fixedVersion) "Decision Serf row should bind fixedVersion to 1.3.10."
Assert-RecentTimestamp ([string]$decisionSerf.reviewedAt) "Decision Serf reviewedAt"

$decisionEvidenceText = (@($decisionSerf.analysisEvidence) + @($decisionSerf.fixEvidence) | ConvertTo-Json -Depth 20)
foreach ($needle in @("serf-changes-1-3", "CVE-2014-3504", "1.3.x before 1.3.7", "1.3.10")) {
  Assert-True $decisionEvidenceText.Contains($needle) "Decision Serf evidence should include '$needle'."
}

$manualReviewKeys = @($manualReview.reviews | ForEach-Object { [string]$_.key })
$manualDecisionTerminalKeys = @($decisionInput.decisions | Where-Object { ($manualReviewKeys -contains [string]$_.key) -and @("not_affected", "affected", "fixed").Contains([string]$_.vexStatus) } | ForEach-Object { [string]$_.key })
$underInvestigationKeys = @($decisionInput.decisions | Where-Object { [string]$_.vexStatus -eq "under_investigation" } | ForEach-Object { [string]$_.key })
Assert-ExactStringSet $expectedTerminalNoDedicatedRows $manualDecisionTerminalKeys "Decision input no-dedicated terminal set should include every no-dedicated native row."
Assert-ExactStringSet $expectedRemainingNoDedicatedRows $underInvestigationKeys "Decision input under-investigation set should be empty after APR-iconv terminal review."

$packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
Assert-HasProperty $packageJson.scripts "release:test-serf-terminal-decision-scripts" "Root package should expose Serf terminal decision script tests."
Assert-True ($packageJson.scripts."release:test-serf-terminal-decision-scripts".Contains("release-serf-terminal-decision-scripts.tests.ps1")) "Root package Serf terminal test script should run this test file."

$readinessVerifier = Get-Content -Raw -LiteralPath $readinessVerifierPath
foreach ($term in @(
    "M7l2k Serf terminal CVE-2014-3504 decision gate",
    "native:serf@1.3.10",
    "CVE-2014-3504",
    "pnpm release:test-serf-terminal-decision-scripts"
  )) {
  Assert-True ($readinessVerifier.Contains($term)) "Release readiness verifier should require '$term'."
}

Write-Host "Release Serf terminal decision script tests passed."

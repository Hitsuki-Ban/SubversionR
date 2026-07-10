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
$expectedZlibSourceIds = @(
  "zlib-github-security",
  "zlib-release-notes",
  "zlib-issue-1142",
  "nvd-cve-2026-22184"
)

$zlibSourceContract = Get-RequiredNamedRow @($advisorySources.components) "zlib" "Native advisory source contract"
Assert-Equal $false ([bool]$zlibSourceContract.dedicatedAdvisoryIndex) "zlib source contract should remain a no-dedicated-index component."
Assert-ExactStringSet $expectedZlibSourceIds @($zlibSourceContract.advisorySources | ForEach-Object { [string]$_.id }) "zlib advisory source IDs should include release notes, GitHub security overview, project issue, and NVD CVE evidence."

Assert-Equal "subversionr.security.native-manual-advisory-review.win32-x64.v1" ([string]$manualReview.schema) "Manual review schema should stay bound to the native manual advisory gate."
Assert-Equal $false ([bool]$manualReview.publicReadinessClaim) "Manual review must not claim public release readiness."
Assert-Equal $false ([bool]$manualReview.nativeManualAdvisoryReviewComplete) "Manual review must remain an input contract and not claim full native advisory completion."
Assert-ExactStringSet $expectedTerminalNoDedicatedRows @($manualReview.reviews | Where-Object { [bool]$_.terminalDecisionAllowed } | ForEach-Object { [string]$_.key }) "Manual review terminal grant set should include every no-dedicated native row."
Assert-ExactStringSet $expectedRemainingNoDedicatedRows @($manualReview.reviews | Where-Object { -not [bool]$_.terminalDecisionAllowed } | ForEach-Object { [string]$_.key }) "Manual review pending set should be empty after APR-iconv terminal review."

$manualZlib = Get-RequiredKeyedRow @($manualReview.reviews) "native:zlib@1.3.2" "Manual review"
Assert-Equal "zlib" ([string]$manualZlib.componentName) "Manual zlib row should stay component-bound."
Assert-Equal "1.3.2" ([string]$manualZlib.version) "Manual zlib row should stay version-bound."
Assert-Equal "static-link-input" ([string]$manualZlib.packageMode) "Manual zlib row should preserve static-link-input package scope."
Assert-ExactStringSet $expectedZlibSourceIds @($manualZlib.advisorySourceIds | ForEach-Object { [string]$_ }) "Manual zlib row should list every zlib source-contract source ID."
Assert-Equal $true ([bool]$manualZlib.terminalDecisionAllowed) "Manual zlib row should grant a terminal decision."
Assert-Equal "not_affected" ([string]$manualZlib.terminalVexStatus) "Manual zlib row should grant only a not_affected terminal status."
Assert-Equal "complete" ([string]$manualZlib.triageStatus) "Manual zlib row should complete triage."
Assert-Equal "not_affected" ([string]$manualZlib.vexStatus) "Manual zlib row should record not_affected VEX status."
Assert-Equal "not_required" ([string]$manualZlib.remediationDecision) "Manual zlib row should record not_required remediation."
Assert-Equal "vulnerable_code_not_present" ([string]$manualZlib.vexJustification) "Manual zlib row should justify not_affected by absent vulnerable utility code."
Assert-True ([string]$manualZlib.impactStatement).Contains("contrib/untgz") "Manual zlib impact statement should identify the vulnerable contrib/untgz utility."
Assert-True ([string]$manualZlib.impactStatement).Contains("does not build or ship") "Manual zlib impact statement should state the utility is not built or shipped."
Assert-Equal $false ([bool]$manualZlib.releaseBlocking) "Manual zlib terminal not_affected row should not be release-blocking by itself."
Assert-RecentTimestamp ([string]$manualZlib.reviewedAt) "Manual zlib reviewedAt"

$manualFindings = @($manualZlib.terminalFindings)
Assert-Equal 1 $manualFindings.Count "Manual zlib row should map exactly one terminal finding in this slice."
$zlibFinding = $manualFindings[0]
Assert-Equal "CVE-2026-22184" ([string]$zlibFinding.id) "Manual zlib terminal finding should identify CVE-2026-22184."
Assert-Equal "cve" ([string]$zlibFinding.type) "Manual zlib terminal finding should be a CVE mapping."
Assert-Equal "zlib" ([string]$zlibFinding.affectedComponent) "Manual zlib terminal finding should bind to zlib."
Assert-Equal "1.3.2" ([string]$zlibFinding.resolvedInVersion) "Manual zlib terminal finding should resolve in 1.3.2."
Assert-Equal "nvd-cve-2026-22184" ([string]$zlibFinding.sourceId) "Manual zlib terminal finding should use the locked NVD CVE source."
Assert-True ([string]$zlibFinding.url).Contains("CVE-2026-22184") "Manual zlib terminal finding should cite the CVE URL."
Assert-True ([string]$zlibFinding.resolutionStatement).Contains("contrib/untgz") "Manual zlib resolution statement should identify the vulnerable contrib/untgz utility."
Assert-True ([string]$zlibFinding.resolutionStatement).Contains("1.3.1.2") "Manual zlib resolution statement should record the affected upstream range."

$manualEvidenceText = ($manualZlib.evidence | ConvertTo-Json -Depth 20)
foreach ($needle in @("zlib-issue-1142", "nvd-cve-2026-22184", "contrib/untgz", "standalone demonstration utility", "core zlib compression library")) {
  Assert-True $manualEvidenceText.Contains($needle) "Manual zlib evidence should include '$needle'."
}

$manualApprovals = @($manualZlib.approvals)
Assert-Equal 2 $manualApprovals.Count "Manual zlib row should include two terminal approvals."
Assert-Equal 2 @($manualApprovals | ForEach-Object { [string]$_.reviewer } | Sort-Object -Unique).Count "Manual zlib approvals should come from two distinct reviewers."
foreach ($approval in $manualApprovals) {
  Assert-Equal "approve-terminal-not_affected" ([string]$approval.decision) "Manual zlib approval should match the not_affected terminal status."
  Assert-RecentTimestamp ([string]$approval.approvedAt) "Manual zlib approval approvedAt"
}

$manualNonClaims = @($manualZlib.nonClaims | ForEach-Object { [string]$_ }) -join "`n"
Assert-True $manualNonClaims.Contains("does not claim public release readiness") "Manual zlib row should keep public readiness out of scope."
Assert-True $manualNonClaims.Contains("does not assert that zlib 1.3.2 is free of all known or unknown vulnerabilities") "Manual zlib row should avoid broad vulnerability-free claims."

$decisionZlib = Get-RequiredKeyedRow @($decisionInput.decisions) "native:zlib@1.3.2" "Decision input"
Assert-Equal "complete" ([string]$decisionZlib.triageStatus) "Decision zlib row should complete triage."
Assert-Equal "not_affected" ([string]$decisionZlib.vexStatus) "Decision zlib row should record not_affected VEX status."
Assert-Equal "not_required" ([string]$decisionZlib.remediationDecision) "Decision zlib row should record not_required remediation."
Assert-Equal "vulnerable_code_not_present" ([string]$decisionZlib.vexJustification) "Decision zlib row should match the manual not_affected justification."
Assert-Equal ([string]$manualZlib.impactStatement) ([string]$decisionZlib.impactStatement) "Decision zlib impact statement should match the manual grant exactly."
Assert-RecentTimestamp ([string]$decisionZlib.reviewedAt) "Decision zlib reviewedAt"

$decisionEvidenceText = ($decisionZlib.analysisEvidence | ConvertTo-Json -Depth 20)
foreach ($needle in @("zlib-issue-1142", "nvd-cve-2026-22184", "CVE-2026-22184", "contrib/untgz", "standalone demonstration utility", "core zlib compression library")) {
  Assert-True $decisionEvidenceText.Contains($needle) "Decision zlib evidence should include '$needle'."
}

$manualReviewKeys = @($manualReview.reviews | ForEach-Object { [string]$_.key })
$manualDecisionTerminalKeys = @($decisionInput.decisions | Where-Object { ($manualReviewKeys -contains [string]$_.key) -and @("not_affected", "affected", "fixed").Contains([string]$_.vexStatus) } | ForEach-Object { [string]$_.key })
$underInvestigationKeys = @($decisionInput.decisions | Where-Object { [string]$_.vexStatus -eq "under_investigation" } | ForEach-Object { [string]$_.key })
Assert-ExactStringSet $expectedTerminalNoDedicatedRows $manualDecisionTerminalKeys "Decision input no-dedicated terminal set should include every no-dedicated native row."
Assert-ExactStringSet $expectedRemainingNoDedicatedRows $underInvestigationKeys "Decision input under-investigation set should be empty after APR-iconv terminal review."

$packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
Assert-HasProperty $packageJson.scripts "release:test-zlib-terminal-decision-scripts" "Root package should expose zlib terminal decision script tests."
Assert-True ($packageJson.scripts."release:test-zlib-terminal-decision-scripts".Contains("release-zlib-terminal-decision-scripts.tests.ps1")) "Root package zlib terminal test script should run this test file."

$readinessVerifier = Get-Content -Raw -LiteralPath $readinessVerifierPath
foreach ($term in @(
    "M7l2h zlib terminal CVE-2026-22184 decision gate",
    "native:zlib@1.3.2",
    "CVE-2026-22184",
    "pnpm release:test-zlib-terminal-decision-scripts"
  )) {
  Assert-True ($readinessVerifier.Contains($term)) "Release readiness verifier should require '$term'."
}

Write-Host "Release zlib terminal decision script tests passed."

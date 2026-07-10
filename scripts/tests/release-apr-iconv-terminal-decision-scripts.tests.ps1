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
$expectedRemainingNoDedicatedRows = @()
$expectedAprIconvSourceIds = @(
  "apr-security-report",
  "asf-security",
  "apr-iconv-download",
  "apr-iconv-changes-1-2",
  "apr-iconv-github-advisories",
  "nvd-apr-iconv-keyword-search",
  "osv-apr-iconv-query"
)

$aprIconvSourceContract = Get-RequiredNamedRow @($advisorySources.components) "apr-iconv" "Native advisory source contract"
Assert-Equal $false ([bool]$aprIconvSourceContract.dedicatedAdvisoryIndex) "APR-iconv source contract should remain a no-dedicated-index component."
Assert-ExactStringSet $expectedAprIconvSourceIds @($aprIconvSourceContract.advisorySources | ForEach-Object { [string]$_.id }) "APR-iconv advisory source IDs should include APR reporting, ASF process, APR-iconv release, changelog, GitHub advisory, NVD keyword, and OSV query evidence."

Assert-Equal "subversionr.security.native-manual-advisory-review.win32-x64.v1" ([string]$manualReview.schema) "Manual review schema should stay bound to the native manual advisory gate."
Assert-Equal $false ([bool]$manualReview.publicReadinessClaim) "Manual review must not claim public release readiness."
Assert-Equal $false ([bool]$manualReview.nativeManualAdvisoryReviewComplete) "Manual review must remain an input contract and not claim full native advisory completion."
Assert-ExactStringSet $expectedTerminalNoDedicatedRows @($manualReview.reviews | Where-Object { [bool]$_.terminalDecisionAllowed } | ForEach-Object { [string]$_.key }) "Manual review terminal grant set should include every no-dedicated native row."
Assert-ExactStringSet $expectedRemainingNoDedicatedRows @($manualReview.reviews | Where-Object { -not [bool]$_.terminalDecisionAllowed } | ForEach-Object { [string]$_.key }) "Manual review pending set should be empty after APR-iconv terminal review."

$manualAprIconv = Get-RequiredKeyedRow @($manualReview.reviews) "native:apr-iconv@1.2.2" "Manual review"
Assert-Equal "apr-iconv" ([string]$manualAprIconv.componentName) "Manual APR-iconv row should stay component-bound."
Assert-Equal "1.2.2" ([string]$manualAprIconv.version) "Manual APR-iconv row should stay version-bound."
Assert-Equal "packaged-runtime" ([string]$manualAprIconv.packageMode) "Manual APR-iconv row should preserve packaged-runtime package scope."
Assert-ExactStringSet $expectedAprIconvSourceIds @($manualAprIconv.advisorySourceIds | ForEach-Object { [string]$_ }) "Manual APR-iconv row should list every APR-iconv source-contract source ID."
Assert-Equal $true ([bool]$manualAprIconv.terminalDecisionAllowed) "Manual APR-iconv row should grant a terminal decision."
Assert-Equal "not_affected" ([string]$manualAprIconv.terminalVexStatus) "Manual APR-iconv row should grant only a not_affected terminal status."
Assert-Equal "complete" ([string]$manualAprIconv.triageStatus) "Manual APR-iconv row should complete triage."
Assert-Equal "not_affected" ([string]$manualAprIconv.vexStatus) "Manual APR-iconv row should record not_affected VEX status."
Assert-Equal "not_required" ([string]$manualAprIconv.remediationDecision) "Manual APR-iconv row should record not_required remediation."
Assert-Equal "vulnerable_code_not_present" ([string]$manualAprIconv.vexJustification) "Manual APR-iconv row should use the supported not_affected justification for the named finding."
Assert-True ([string]$manualAprIconv.impactStatement).Contains("no applicable published vulnerability") "Manual APR-iconv impact statement should scope the terminal finding to published vulnerability evidence."
Assert-True ([string]$manualAprIconv.impactStatement).Contains("packaged-runtime") "Manual APR-iconv impact statement should bind the decision to the packaged-runtime scope."
Assert-Equal $false ([bool]$manualAprIconv.releaseBlocking) "Manual APR-iconv terminal not_affected row should not be release-blocking by itself."
Assert-RecentTimestamp ([string]$manualAprIconv.reviewedAt) "Manual APR-iconv reviewedAt"

$manualFindings = @($manualAprIconv.terminalFindings)
Assert-Equal 1 $manualFindings.Count "Manual APR-iconv row should map exactly one named terminal finding in this slice."
$aprIconvFinding = $manualFindings[0]
Assert-Equal "APR-ICONV-1.2.2-NO-PUBLISHED-ADVISORY" ([string]$aprIconvFinding.id) "Manual APR-iconv terminal finding should identify the named source-review finding."
Assert-Equal "named-security-finding" ([string]$aprIconvFinding.type) "Manual APR-iconv terminal finding should be a named security finding, not a synthetic CVE."
Assert-Equal "apr-iconv" ([string]$aprIconvFinding.affectedComponent) "Manual APR-iconv terminal finding should bind to APR-iconv."
Assert-Equal "1.2.2" ([string]$aprIconvFinding.resolvedInVersion) "Manual APR-iconv terminal finding should resolve in the locked 1.2.2 source."
Assert-Equal "apr-iconv-github-advisories" ([string]$aprIconvFinding.sourceId) "Manual APR-iconv terminal finding should use the locked GitHub advisories source."
Assert-True ([string]$aprIconvFinding.url).Contains("apache/apr-iconv/security/advisories") "Manual APR-iconv terminal finding should cite the repository advisories URL."
Assert-True ([string]$aprIconvFinding.resolutionStatement).Contains("no applicable published vulnerability") "Manual APR-iconv resolution statement should scope the negative finding."
Assert-True ([string]$aprIconvFinding.resolutionStatement).Contains("does not assert that APR-iconv 1.2.2 is vulnerability-free") "Manual APR-iconv resolution statement should avoid a broad clean-component claim."

$manualEvidenceText = ($manualAprIconv.evidence | ConvertTo-Json -Depth 20)
foreach ($needle in @("apr-iconv-download", "APR iconv 1.2.2 is the best available version", "apr_xlate", "apr-iconv-changes-1-2", "Win32: Resolve build issues with modern Visual Studio toolchains", "apr-iconv-github-advisories", "There aren't any published security advisories", "nvd-apr-iconv-keyword-search", "totalResults 0", "osv-apr-iconv-query", "empty vulnerability result")) {
  Assert-True $manualEvidenceText.Contains($needle) "Manual APR-iconv evidence should include '$needle'."
}

$manualApprovals = @($manualAprIconv.approvals)
Assert-Equal 2 $manualApprovals.Count "Manual APR-iconv row should include two terminal approvals."
Assert-Equal 2 @($manualApprovals | ForEach-Object { [string]$_.reviewer } | Sort-Object -Unique).Count "Manual APR-iconv approvals should come from two distinct reviewers."
foreach ($approval in $manualApprovals) {
  Assert-Equal "approve-terminal-not_affected" ([string]$approval.decision) "Manual APR-iconv approval should match the not_affected terminal status."
  Assert-RecentTimestamp ([string]$approval.approvedAt) "Manual APR-iconv approval approvedAt"
}

$manualNonClaims = @($manualAprIconv.nonClaims | ForEach-Object { [string]$_ }) -join "`n"
Assert-True $manualNonClaims.Contains("does not claim public release readiness") "Manual APR-iconv row should keep public readiness out of scope."
Assert-True $manualNonClaims.Contains("does not assert that APR-iconv 1.2.2 is free of all known or unknown vulnerabilities") "Manual APR-iconv row should avoid broad vulnerability-free claims."

$decisionAprIconv = Get-RequiredKeyedRow @($decisionInput.decisions) "native:apr-iconv@1.2.2" "Decision input"
Assert-Equal "complete" ([string]$decisionAprIconv.triageStatus) "Decision APR-iconv row should complete triage."
Assert-Equal "not_affected" ([string]$decisionAprIconv.vexStatus) "Decision APR-iconv row should record not_affected VEX status."
Assert-Equal "not_required" ([string]$decisionAprIconv.remediationDecision) "Decision APR-iconv row should record not_required remediation."
Assert-Equal "vulnerable_code_not_present" ([string]$decisionAprIconv.vexJustification) "Decision APR-iconv row should match the manual not_affected justification."
Assert-Equal ([string]$manualAprIconv.impactStatement) ([string]$decisionAprIconv.impactStatement) "Decision APR-iconv impact statement should match the manual grant exactly."
Assert-RecentTimestamp ([string]$decisionAprIconv.reviewedAt) "Decision APR-iconv reviewedAt"

$decisionEvidenceText = ($decisionAprIconv.analysisEvidence | ConvertTo-Json -Depth 20)
foreach ($needle in @("apr-iconv-download", "apr-iconv-changes-1-2", "apr-iconv-github-advisories", "nvd-apr-iconv-keyword-search", "osv-apr-iconv-query", "APR-ICONV-1.2.2-NO-PUBLISHED-ADVISORY", "no applicable published vulnerability")) {
  Assert-True $decisionEvidenceText.Contains($needle) "Decision APR-iconv evidence should include '$needle'."
}

$manualReviewKeys = @($manualReview.reviews | ForEach-Object { [string]$_.key })
$manualDecisionTerminalKeys = @($decisionInput.decisions | Where-Object { ($manualReviewKeys -contains [string]$_.key) -and @("not_affected", "affected", "fixed").Contains([string]$_.vexStatus) } | ForEach-Object { [string]$_.key })
$underInvestigationKeys = @($decisionInput.decisions | Where-Object { [string]$_.vexStatus -eq "under_investigation" } | ForEach-Object { [string]$_.key })
Assert-ExactStringSet $expectedTerminalNoDedicatedRows $manualDecisionTerminalKeys "Decision input no-dedicated terminal set should include every no-dedicated native row."
Assert-ExactStringSet $expectedRemainingNoDedicatedRows $underInvestigationKeys "Decision input under-investigation set should be empty after APR-iconv terminal review."

$packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
Assert-HasProperty $packageJson.scripts "release:test-apr-iconv-terminal-decision-scripts" "Root package should expose APR-iconv terminal decision script tests."
Assert-True ($packageJson.scripts."release:test-apr-iconv-terminal-decision-scripts".Contains("release-apr-iconv-terminal-decision-scripts.tests.ps1")) "Root package APR-iconv terminal test script should run this test file."

$readinessVerifier = Get-Content -Raw -LiteralPath $readinessVerifierPath
foreach ($term in @(
    "M7l2l APR-iconv terminal named security finding decision gate",
    "native:apr-iconv@1.2.2",
    "APR-ICONV-1.2.2-NO-PUBLISHED-ADVISORY",
    "pnpm release:test-apr-iconv-terminal-decision-scripts"
  )) {
  Assert-True ($readinessVerifier.Contains($term)) "Release readiness verifier should require '$term'."
}

Write-Host "Release APR-iconv terminal decision script tests passed."

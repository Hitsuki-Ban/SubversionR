$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).ProviderPath
$workflowScript = Join-Path $repoRoot "scripts\release\test-state-engine-beta-performance.ps1"
$packageJsonPath = Join-Path $repoRoot "package.json"
$ciWorkflowPath = Join-Path $repoRoot ".github\workflows\ci.yml"
$prFastWorkflowPath = Join-Path $repoRoot ".github\workflows\pr-fast.yml"

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

function Assert-NativeCommandFailsContaining([scriptblock]$Action, [string]$ExpectedText, [string]$Message) {
  $output = & $Action 2>&1
  $exitCode = $LASTEXITCODE
  Assert-True ($exitCode -ne 0) "$Message Expected native command to fail."
  $text = $output | Out-String
  Assert-True ($text.Contains($ExpectedText)) "$Message Expected output to contain '$ExpectedText', got '$text'."
}

function Assert-TraceIds([object]$Report, [string[]]$TraceIds) {
  $actualIds = @($Report.traceIds | ForEach-Object { [string]$_ })
  foreach ($traceId in $TraceIds) {
    Assert-True ($actualIds -contains $traceId) "State-engine Beta performance report should trace $traceId."
  }
}

$tempRoot = Join-Path $repoRoot "target\release-evidence\tests\release-state-engine-beta-performance-scripts\$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  Assert-True (Test-Path -LiteralPath $workflowScript -PathType Leaf) "test-state-engine-beta-performance.ps1 should exist."
  $workflowScriptContent = Get-Content -Raw -LiteralPath $workflowScript
  Assert-True (
    -not $workflowScriptContent.Contains('"target\release-evidence"')
  ) "State-engine Beta performance gate should build release-evidence paths with platform separators."
  Assert-True (
    $workflowScriptContent.Contains('Join-Path (Join-Path $repoRoot "packages") "vscode-extension"')
  ) "State-engine Beta performance gate should target the extension workspace by path."
  Assert-True (
    $workflowScriptContent.Contains('--dir $extensionWorkspacePath')
  ) "State-engine Beta performance gate should run pnpm from the extension workspace path."
  Assert-True (
    -not $workflowScriptContent.Contains('--filter svn-r')
  ) "State-engine Beta performance gate must not depend on the public extension package name."

  $fixtureRoot = Join-Path $tempRoot "state-engine-beta-performance\win32-x64"
  $evidencePath = Join-Path $tempRoot "evidence\subversionr-state-engine-beta-performance-win32-x64.json"

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $workflowScript `
    -Target win32-x64 `
    -FixtureRoot $fixtureRoot `
    -EvidencePath $evidencePath `
    -MaxProjectionMs 10000
  if ($LASTEXITCODE -ne 0) {
    throw "test-state-engine-beta-performance.ps1 failed with exit code $LASTEXITCODE."
  }

  $report = Get-Content -Raw -LiteralPath $evidencePath | ConvertFrom-Json
  Assert-Equal "subversionr.release.state-engine-beta-performance.win32-x64.v1" $report.schema "State-engine Beta performance evidence should use the Beta-F schema."
  Assert-Equal "False" ([string]$report.publicReadinessClaim) "State-engine Beta performance evidence must not claim public readiness."
  Assert-Equal "win32-x64" $report.target "State-engine Beta performance evidence should record the target."
  Assert-Equal "packages/vscode-extension/tests/stateEngineBetaPerformanceGate.test.ts" $report.source "State-engine Beta performance evidence should bind to the TS gate."
  Assert-Equal "none" $report.workingCopyMutation "State-engine Beta performance gate should not mutate a real working copy."
  Assert-Equal "10000" ([string]$report.thresholds.tenThousandLocalResourceCount) "State-engine Beta performance evidence should record the 10k fixture size."
  Assert-Equal "10000" ([string]$report.thresholds.maxProjectionMs) "State-engine Beta performance evidence should record the configured projection budget."
  Assert-Equal "0" ([string]$report.assertions.singleFileSaveNoFullScan.rootInfinityTargetCount) "Single-file save should not produce a root infinity target."
  Assert-True ([int]$report.assertions.eventBurstBounded.actualRefreshTargets -le [int]$report.assertions.eventBurstBounded.maxRefreshTargets) "Burst targets should stay bounded."
  Assert-Equal "False" ([string]$report.assertions.nestedExternalBoundaryIsolation.boundaryAcceptedByParent) "Parent boundary should reject nested/external events."
  Assert-Equal "True" ([string]$report.assertions.dirtyGenerationSupersede.firstSignalAborted) "Dirty-generation supersede should abort stale refreshes."
  Assert-Equal "stale" ([string]$report.assertions.sidecarRestartRecovery.statusCompleteness) "Backend restart should mark status stale before reopen."
  Assert-Equal "10000" ([string]$report.assertions.tenThousandWorkingCopyProjection.localEntryCount) "10k projection evidence should use the expected fixture size."
  Assert-TraceIds $report @(
    "PRD-006",
    "REP-005",
    "STA-001",
    "STA-012",
    "STA-014",
    "ARC-011",
    "DIR-002",
    "DIR-004",
    "DIR-006",
    "DIR-007",
    "DIR-009",
    "DIR-010",
    "DIR-011",
    "DIR-012",
    "DIR-013",
    "DIR-020",
    "OBS-004",
    "TST-024"
  )
  Assert-True (@($report.nonClaims | Where-Object { [string]$_ -like "*100k or 1M*" }).Count -gt 0) "State-engine Beta performance evidence should keep 100k/1M non-claims explicit."
  Assert-True (@($report.nonClaims | Where-Object { [string]$_ -like "*default background remote polling*" }).Count -gt 0) "State-engine Beta performance evidence should keep remote polling non-claims explicit."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $workflowScript `
      -Target win32-x64 `
      -FixtureRoot "%SUBVERSIONR_STATE_ENGINE_FIXTURE%" `
      -EvidencePath (Join-Path $tempRoot "evidence\placeholder.json")
  } "FixtureRoot must be an explicit path" "State-engine Beta performance gate should reject unresolved fixture placeholders."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $workflowScript `
      -Target win32-x64 `
      -FixtureRoot (Join-Path $env:TEMP "subversionr-state-engine-outside-target") `
      -EvidencePath (Join-Path $tempRoot "evidence\outside-target.json")
  } "FixtureRoot must resolve inside the repository target directory" "State-engine Beta performance gate should reject fixture roots outside target."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $workflowScript `
      -Target win32-x64 `
      -FixtureRoot (Join-Path $tempRoot "outside-release-evidence") `
      -EvidencePath (Join-Path $repoRoot "target\tests\state-engine-beta-performance\outside-release-evidence.json")
  } "EvidencePath must resolve inside the repository target/release-evidence directory" "State-engine Beta performance gate should reject evidence paths outside target/release-evidence."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $workflowScript `
      -Target win32-x64 `
      -FixtureRoot (Join-Path $tempRoot "invalid-budget") `
      -EvidencePath (Join-Path $tempRoot "evidence\invalid-budget.json") `
      -MaxProjectionMs 0
  } "MaxProjectionMs must be positive" "State-engine Beta performance gate should reject non-positive projection budgets."

  $packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  Assert-True ($packageJson.scripts."release:test-state-engine-beta-performance-scripts".Contains("release-state-engine-beta-performance-scripts.tests.ps1")) "Root package should expose state-engine Beta performance script tests."
  Assert-True ($packageJson.scripts."release:test-state-engine-beta-performance:win32-x64".Contains("test-state-engine-beta-performance.ps1")) "Root package should expose the state-engine Beta performance gate."
  Assert-True ($packageJson.scripts."release:test-state-engine-beta-performance:win32-x64".Contains("target/release-evidence/state-engine-beta-performance/win32-x64")) "State-engine Beta performance gate should write fixtures under target/release-evidence."

  $ciWorkflow = Get-Content -Raw -LiteralPath $ciWorkflowPath
  Assert-True ($ciWorkflow.Contains("Release state-engine Beta performance script tests")) "CI should run state-engine Beta performance script tests."
  Assert-True ($ciWorkflow.Contains("Test state-engine Beta performance")) "CI should run the state-engine Beta performance gate."

  $prFastWorkflow = Get-Content -Raw -LiteralPath $prFastWorkflowPath
  Assert-True ($prFastWorkflow.Contains("Test state-engine Beta performance")) "PR Fast should run the lightweight state-engine Beta performance gate."

  Write-Host "Release state-engine Beta performance script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

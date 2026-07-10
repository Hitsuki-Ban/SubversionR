[CmdletBinding()]
param(
  [ValidateSet("win32-x64")]
  [string]$Target = "win32-x64",

  [Parameter(Mandatory = $true)]
  [string]$FixtureRoot,

  [Parameter(Mandatory = $true)]
  [string]$EvidencePath,

  [int]$MaxProjectionMs = 10000
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).ProviderPath
$extensionWorkspacePath = Join-Path (Join-Path $repoRoot "packages") "vscode-extension"

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

function Assert-ExplicitPath([string]$Path, [string]$Name) {
  Assert-True (-not [string]::IsNullOrWhiteSpace($Path)) "$Name is required."
  Assert-True (-not $Path.Contains("%")) "$Name must be an explicit path, not an unresolved environment placeholder."
}

function Resolve-RepoPath([string]$Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Assert-PathInsideTarget([string]$Path, [string]$Name) {
  $fullPath = Resolve-RepoPath $Path
  $targetRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target")).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  )
  $targetPrefix = "$targetRoot$([System.IO.Path]::DirectorySeparatorChar)"
  Assert-True (
    $fullPath.Equals($targetRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
    $fullPath.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)
  ) "$Name must resolve inside the repository target directory: $fullPath"
  $fullPath
}

function Assert-PathInsideReleaseEvidence([string]$Path, [string]$Name) {
  $fullPath = Resolve-RepoPath $Path
  $releaseEvidenceRoot = [System.IO.Path]::GetFullPath(
    (Join-Path (Join-Path $repoRoot "target") "release-evidence")
  ).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  )
  $releaseEvidencePrefix = "$releaseEvidenceRoot$([System.IO.Path]::DirectorySeparatorChar)"
  Assert-True (
    $fullPath.Equals($releaseEvidenceRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
    $fullPath.StartsWith($releaseEvidencePrefix, [System.StringComparison]::OrdinalIgnoreCase)
  ) "$Name must resolve inside the repository target/release-evidence directory: $fullPath"
  $fullPath
}

function Assert-TraceIds([object]$Report, [string[]]$TraceIds) {
  $actualIds = @($Report.traceIds | ForEach-Object { [string]$_ })
  foreach ($traceId in $TraceIds) {
    Assert-True ($actualIds -contains $traceId) "State-engine Beta performance evidence must trace $traceId."
  }
}

function Assert-ScenarioAssertions([object]$Report) {
  $assertions = $Report.assertions
  Assert-True ($null -ne $assertions) "State-engine Beta performance evidence must include scenario assertions."
  Assert-Equal "0" ([string]$assertions.singleFileSaveNoFullScan.rootInfinityTargetCount) "Single-file save must not trigger a root infinity full scan target."
  Assert-Equal "1" ([string]$assertions.singleFileSaveNoFullScan.refreshRequestCount) "Single-file save should issue one targeted refresh request."
  Assert-Equal "10000" ([string]$assertions.eventBurstBounded.inputEventCount) "Event burst evidence must cover the 10k event baseline."
  Assert-True ([int]$assertions.eventBurstBounded.actualRefreshTargets -le [int]$assertions.eventBurstBounded.maxRefreshTargets) "Event burst refresh targets must stay bounded."
  Assert-Equal "False" ([string]$assertions.nestedExternalBoundaryIsolation.boundaryAcceptedByParent) "Parent provider must reject nested/external boundary events."
  Assert-Equal "True" ([string]$assertions.nestedExternalBoundaryIsolation.boundaryAcceptedByChild) "Child provider must accept its own boundary event."
  Assert-Equal "True" ([string]$assertions.dirtyGenerationSupersede.firstSignalAborted) "Dirty-generation supersede must abort the stale in-flight refresh."
  Assert-Equal "refreshCancelled" ([string]$assertions.dirtyGenerationSupersede.staleMarkReason) "Dirty-generation supersede must mark status stale before recovery."
  Assert-Equal "stale" ([string]$assertions.sidecarRestartRecovery.statusCompleteness) "Backend restart must mark canonical status stale when reopening sessions."
  Assert-Equal "1" ([string]$assertions.sidecarRestartRecovery.reopenedCount) "Backend restart evidence must record an explicit reopen result."
  Assert-Equal "10000" ([string]$assertions.tenThousandWorkingCopyProjection.localEntryCount) "Projection evidence must use the 10k local working-copy fixture."
  Assert-True ([double]$assertions.tenThousandWorkingCopyProjection.elapsedMs -le [double]$assertions.tenThousandWorkingCopyProjection.maxProjectionMs) "10k projection elapsed time exceeds the configured Beta baseline."
}

Assert-ExplicitPath $FixtureRoot "FixtureRoot"
Assert-ExplicitPath $EvidencePath "EvidencePath"
Assert-True ($MaxProjectionMs -gt 0) "MaxProjectionMs must be positive."

$fixtureRootPath = Assert-PathInsideTarget $FixtureRoot "FixtureRoot"
$evidencePathFull = Assert-PathInsideReleaseEvidence $EvidencePath "EvidencePath"
$evidenceParent = Split-Path -Parent $evidencePathFull
New-Item -ItemType Directory -Force -Path $fixtureRootPath | Out-Null
New-Item -ItemType Directory -Force -Path $evidenceParent | Out-Null
Remove-Item -LiteralPath $evidencePathFull -Force -ErrorAction SilentlyContinue

$previousTarget = $env:SUBVERSIONR_STATE_ENGINE_BETA_PERFORMANCE_TARGET
$previousFixtureRoot = $env:SUBVERSIONR_STATE_ENGINE_BETA_PERFORMANCE_FIXTURE_ROOT
$previousEvidencePath = $env:SUBVERSIONR_STATE_ENGINE_BETA_PERFORMANCE_EVIDENCE_PATH
$previousMaxProjectionMs = $env:SUBVERSIONR_STATE_ENGINE_BETA_PERFORMANCE_MAX_PROJECTION_MS

try {
  $env:SUBVERSIONR_STATE_ENGINE_BETA_PERFORMANCE_TARGET = $Target
  $env:SUBVERSIONR_STATE_ENGINE_BETA_PERFORMANCE_FIXTURE_ROOT = $fixtureRootPath
  $env:SUBVERSIONR_STATE_ENGINE_BETA_PERFORMANCE_EVIDENCE_PATH = $evidencePathFull
  $env:SUBVERSIONR_STATE_ENGINE_BETA_PERFORMANCE_MAX_PROJECTION_MS = [string]$MaxProjectionMs

  Push-Location $repoRoot
  try {
    & pnpm --dir $extensionWorkspacePath exec vitest run tests/stateEngineBetaPerformanceGate.test.ts
    if ($LASTEXITCODE -ne 0) {
      throw "State-engine Beta performance Vitest gate failed with exit code $LASTEXITCODE."
    }
  }
  finally {
    Pop-Location
  }
}
finally {
  $env:SUBVERSIONR_STATE_ENGINE_BETA_PERFORMANCE_TARGET = $previousTarget
  $env:SUBVERSIONR_STATE_ENGINE_BETA_PERFORMANCE_FIXTURE_ROOT = $previousFixtureRoot
  $env:SUBVERSIONR_STATE_ENGINE_BETA_PERFORMANCE_EVIDENCE_PATH = $previousEvidencePath
  $env:SUBVERSIONR_STATE_ENGINE_BETA_PERFORMANCE_MAX_PROJECTION_MS = $previousMaxProjectionMs
}

Assert-True (Test-Path -LiteralPath $evidencePathFull -PathType Leaf) "State-engine Beta performance evidence was not written: $evidencePathFull"
$report = Get-Content -Raw -LiteralPath $evidencePathFull | ConvertFrom-Json

Assert-Equal "subversionr.release.state-engine-beta-performance.$Target.v1" $report.schema "State-engine Beta performance evidence schema should bind to the target."
Assert-Equal "False" ([string]$report.publicReadinessClaim) "State-engine Beta performance evidence must not claim public readiness."
Assert-Equal $Target $report.target "State-engine Beta performance evidence target should match the gate target."
Assert-Equal "packages/vscode-extension/tests/stateEngineBetaPerformanceGate.test.ts" $report.source "State-engine Beta performance evidence should bind to the TS gate."
Assert-Equal "none" $report.workingCopyMutation "State-engine Beta performance gate must not mutate a real working copy."
Assert-Equal "10000" ([string]$report.thresholds.tenThousandLocalResourceCount) "State-engine Beta performance threshold should record the 10k local baseline."
Assert-Equal ([string]$MaxProjectionMs) ([string]$report.thresholds.maxProjectionMs) "State-engine Beta performance threshold should record the configured projection budget."
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
Assert-ScenarioAssertions $report
Assert-True (@($report.nonClaims | Where-Object { [string]$_ -like "*100k or 1M*" }).Count -gt 0) "State-engine Beta performance evidence must keep larger working-copy performance non-claims explicit."
Assert-True (@($report.nonClaims | Where-Object { [string]$_ -like "*default background remote polling*" }).Count -gt 0) "State-engine Beta performance evidence must keep remote-polling non-claims explicit."

Write-Host "State-engine Beta performance gate passed."

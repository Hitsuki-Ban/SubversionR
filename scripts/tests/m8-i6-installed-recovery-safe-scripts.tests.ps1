$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$probePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-recovery-safe.ps1"

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

Assert-True (Test-Path -LiteralPath $probePath -PathType Leaf) "Installed recovery-safe probe must exist."
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($probePath, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) "Installed recovery-safe probe must parse without PowerShell errors."

$parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
$expectedParameters = @(
  "VsixPath", "CodeCliPath", "FixtureRoot", "WorkingCopyPath", "RepositoryUrl", "FixtureStatePath",
  "OperationId", "OperationTimeoutMilliseconds", "ExpectedProductVersion", "DaemonPath", "BridgePath", "TimeoutSeconds"
)
Assert-True (($parameterNames -join ",") -ceq ($expectedParameters -join ",")) "Installed recovery-safe probe must expose only the exact required parameters."

$source = Get-Content -Raw -LiteralPath $probePath
foreach ($required in @(
    'subversionr.diagnostics.installedSvnAnonymousRecoverySafeReport',
    'SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_SAFE_REPORT_TOKEN',
    'SUBVERSIONR_INSTALLED_I6_RECOVERY_SAFE_FIXTURE_STATE_PATH',
    'token, repositoryUrl, workingCopyPath, fixtureStatePath, operationId, timeoutMs: operationTimeoutMs',
    '[ValidateSet(500)] [int]$OperationTimeoutMilliseconds',
    'subversionr.release.m8-i6-installed-vsix-recovery-safe.v1',
    'subversionr.release.m8-i6-installed-vsix-recovery-safe-wrapper.v1',
    'subversionr.installedSvnAnonymousRecoverySafeReport',
    'SUBVERSIONR_REMOTE_WORKER_TIMED_OUT',
    'operationDeadlineExceeded',
    'required,checking,safe',
    'remoteRecoverySafeRequiresFullReconcile',
    'freshReconcile', 'nativeLaneReleased', 'subsequentRequestPassed',
    'fixtureCountersUnchangedAfterPrerequisite',
    'Get-CandidateProcessCount', 'Wait-CandidateProcessAbsent', 'Get-TemporaryRootCount',
    'Assert-EmptyCheckoutJournal', 'Assert-WorkingCopyContentPreserved',
    '--uninstall-extension', 'extensionInstalledAfterCleanup', 'fixtureRemovedAfterCleanup',
    'diagnosticsRedacted'
  )) {
  Assert-True ($source.Contains($required)) "Installed recovery-safe probe is missing the contract lock: $required"
}

foreach ($forbidden in @(
    'installedSvnAnonymousDeadlineReport',
    'SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DEADLINE_REPORT_TOKEN',
    'installedSvnAnonymousRecoveryBlockedReport',
    'remote/recoverWorkingCopy',
    'subversionr.retryRemoteRecovery',
    'Get-WmiObject',
    'Register-WmiEvent',
    'svn.exe',
    'svnadmin.exe',
    'synthetic',
    'fallback',
    'Remove-Item -LiteralPath $workingCopyResolved'
  )) {
  Assert-True (-not $source.Contains($forbidden)) "Installed recovery-safe probe contains a forbidden alternate/destructive route: $forbidden"
}

$commandLiterals = @($ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
      $node.Value -ceq "subversionr.diagnostics.installedSvnAnonymousRecoverySafeReport"
    }, $true))
Assert-True ($commandLiterals.Count -eq 1) "Installed recovery-safe probe must bind exactly one internal product command."

$removeCalls = @($ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.CommandAst] -and
      $node.GetCommandName() -ceq "Remove-Item"
    }, $true))
Assert-True ($removeCalls.Count -gt 0) "Installed recovery-safe probe must clean its isolated fixture."
foreach ($remove in $removeCalls) {
  Assert-True (-not $remove.Extent.Text.Contains('$workingCopyResolved')) "Installed recovery-safe cleanup must preserve the working copy."
}

Write-Host "M8 I6 installed recovery-safe probe script tests passed."

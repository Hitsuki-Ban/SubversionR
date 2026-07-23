$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$probePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-recovery-indeterminate.ps1"

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

Assert-True (Test-Path -LiteralPath $probePath -PathType Leaf) "Installed recovery-indeterminate probe must exist."
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($probePath, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) "Installed recovery-indeterminate probe must parse without PowerShell errors."

$parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
$expectedParameters = @(
  "VsixPath", "CodeCliPath", "FixtureRoot", "WorkingCopyPath", "RepositoryUrl", "FixtureStatePath",
  "OperationId", "OperationTimeoutMilliseconds", "ExpectedProductVersion", "DaemonPath", "BridgePath", "TimeoutSeconds"
)
Assert-True (($parameterNames -join ",") -ceq ($expectedParameters -join ",")) "Installed recovery-indeterminate probe must expose only the exact required parameters."

$source = Get-Content -Raw -LiteralPath $probePath
foreach ($required in @(
    'subversionr.diagnostics.installedSvnAnonymousRecoveryIndeterminateReport',
    'SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_REPORT_TOKEN',
    'SUBVERSIONR_INSTALLED_I6_RECOVERY_INDETERMINATE_FIXTURE_STATE_PATH',
    'token, repositoryUrl, workingCopyPath, fixtureStatePath, operationId, timeoutMs: operationTimeoutMs',
    '[ValidateSet(5000)] [int]$OperationTimeoutMilliseconds',
    'subversionr.release.m8-i6-installed-vsix-recovery-indeterminate.v1',
    'subversionr.release.m8-i6-installed-vsix-recovery-indeterminate-wrapper.v1',
    'subversionr.installedSvnAnonymousRecoveryIndeterminateReport',
    'SUBVERSIONR_REMOTE_WORKER_TIMED_OUT', 'operationDeadlineExceeded', 'pending',
    'SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE', 'remoteOperationIndeterminate',
    'stableCode', 'originCode', 'settlementCode', 'originReason', 'settlementReason',
    'required,checking,required', 'nativeLaneBlocked', 'explicitRecoveryRequired',
    'networkAttempts', 'networkConnections', 'followupNetworkContacts',
    'Wait-CommandBarrier', 'commandsReceived', 'commandBarrierObserved',
    'Get-Acl', 'Set-Acl', 'FileSystemAccessRule', 'Add-WorkingCopyDatabaseDeny',
    'SetFileSecurity', 'DaclSecurityInformation', 'GetSecurityDescriptorBinaryForm',
    'must be owned by the current Windows identity', 'securityDescriptorSha256', 'currentUserSidSha256',
    'readFaultObserved', 'daclRestoredExactly',
    'Assert-WorkingCopyDatabaseReadDenied', 'Restore-WorkingCopyDatabaseAcl',
    'workingCopyDatabaseDenyApplied', 'workingCopyDatabaseAclRestored',
    'Get-CandidateProcessCount', 'Wait-CandidateProcessAbsent', 'Get-TemporaryRootCount',
    'Assert-EmptyCheckoutJournal', 'Assert-WorkingCopyContentPreserved',
    '--uninstall-extension', 'extensionInstalledAfterCleanup', 'fixtureRemovedAfterCleanup',
    'diagnosticsRedacted'
  )) {
  Assert-True ($source.Contains($required)) "Installed recovery-indeterminate probe is missing the contract lock: $required"
}

foreach ($forbidden in @(
    'installedSvnAnonymousRecoverySafeReport',
    'SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_SAFE_REPORT_TOKEN',
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
  Assert-True (-not $source.Contains($forbidden)) "Installed recovery-indeterminate probe contains a forbidden alternate/destructive route: $forbidden"
}

$aclFlagIndex = $source.IndexOf('$aclApplied = $true', [System.StringComparison]::Ordinal)
$aclMutationIndex = $source.IndexOf('Add-WorkingCopyDatabaseDeny $workingCopyDatabaseSecurity', [System.StringComparison]::Ordinal)
Assert-True ($aclFlagIndex -ge 0 -and $aclMutationIndex -gt $aclFlagIndex) "Installed recovery-indeterminate cleanup flag must be armed before the DACL mutation."

$commandLiterals = @($ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
      $node.Value -ceq "subversionr.diagnostics.installedSvnAnonymousRecoveryIndeterminateReport"
    }, $true))
Assert-True ($commandLiterals.Count -eq 1) "Installed recovery-indeterminate probe must bind exactly one internal product command."

$removeCalls = @($ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.CommandAst] -and
      $node.GetCommandName() -ceq "Remove-Item"
    }, $true))
Assert-True ($removeCalls.Count -gt 0) "Installed recovery-indeterminate probe must clean its isolated fixture."
foreach ($remove in $removeCalls) {
  Assert-True (-not $remove.Extent.Text.Contains('$workingCopyResolved')) "Installed recovery-indeterminate cleanup must preserve the working copy."
}

Write-Host "M8 I6 installed recovery-indeterminate probe script tests passed."

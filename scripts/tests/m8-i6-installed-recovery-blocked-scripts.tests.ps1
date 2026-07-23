$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$probePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-recovery-blocked.ps1"
$reportPath = Join-Path $repoRoot "packages\vscode-extension\src\diagnostics\installedSvnAnonymousRecoveryBlockedReport.ts"
$reportTestPath = Join-Path $repoRoot "packages\vscode-extension\tests\installedSvnAnonymousRecoveryBlockedReport.test.ts"
$extensionPath = Join-Path $repoRoot "packages\vscode-extension\src\extension.ts"
$manifestPath = Join-Path $repoRoot "packages\vscode-extension\package.json"
$testRoot = Join-Path $repoRoot "target\t\i6irb\$([Guid]::NewGuid().ToString('N').Substring(0, 8))"

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Assert-ScriptThrowsContaining([scriptblock]$Action, [string]$ExpectedText, [string]$Message) {
  $thrown = $null
  try { & $Action }
  catch { $thrown = $_ }
  Assert-True ($null -ne $thrown) "$Message Expected the script block to throw."
  Assert-True ($thrown.Exception.Message.Contains($ExpectedText)) "$Message Expected '$ExpectedText', got '$($thrown.Exception.Message)'."
}

foreach ($path in @($probePath, $reportPath, $reportTestPath, $extensionPath, $manifestPath)) {
  Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Installed recovery-blocked contract file is missing: $path"
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($probePath, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) "Installed recovery-blocked probe must parse without PowerShell errors."
$parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
$expectedParameters = @(
  "VsixPath", "CodeCliPath", "FixtureRoot", "FaultRepositoryUrl", "HealthyRepositoryUrl", "UnrelatedRepositoryUrl",
  "UnrelatedTargetPath", "FaultFixtureStatePath",
  "OriginOperationId", "RetryOperationId", "FreshOperationId", "OperationTimeoutMilliseconds",
  "ExpectedProductVersion", "DaemonPath", "BridgePath", "TimeoutSeconds"
)
Assert-True (($parameterNames -join ",") -ceq ($expectedParameters -join ",")) "Installed recovery-blocked probe parameters drifted."

$source = Get-Content -Raw -LiteralPath $probePath
foreach ($required in @(
    'subversionr.diagnostics.installedSvnAnonymousRecoveryBlockedReport',
    'SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_REPORT_TOKEN',
    '[ValidateSet(5000)] [int]$OperationTimeoutMilliseconds',
    '$OperationTimeoutMilliseconds + 30000',
    'Wait-ArmedCheckoutJournal',
    'Read-CheckoutJournal $JournalPath "armed"',
    'Read-CheckoutJournal $journalPath "blocked"',
    'state -ceq $ExpectedState',
    'effect -ceq "checkoutTarget"',
    'originOperationId -ceq $OperationId',
    'targetDisposition = [string]$recoverReport.targetDisposition',
    'unexpectedly created a target before the first RA command',
    'fixtureCountersUnchangedOnBlockedRetry',
    'unrelatedRepositoryServed',
    'blockedEntryUnchangedAfterUnrelated',
    'blockedJournalUnchangedAfterUnrelated',
    'blockedJournalBytesSha256BeforeUnrelated',
    'blockedJournalBytesSha256AfterUnrelated',
    'unrelatedCheckoutRevision',
    'unrelatedTargetPathSha256',
    'SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_UNRELATED_URL',
    'SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_UNRELATED_TARGET',
    'Assert-NonemptyWorkingCopyDatabase $unrelatedTargetResolved',
    '[int]$recoverReport.authActivity.credentialRequests -eq 0',
    '[int]$recoverReport.authActivity.credentialSettlements -eq 0',
    '[int]$recoverReport.authActivity.certificateRequests -eq 0',
    '$FaultRepositoryUrl, $HealthyRepositoryUrl, $UnrelatedRepositoryUrl',
    '$unrelatedTargetResolved, $OriginOperationId',
    'requiredConfirmation',
    'reviewedAndResolved',
    'subsequentCheckoutPassed',
    'Get-Sha256 $installedDaemonPath',
    'Get-Sha256 $installedBridgePath',
    'Wait-CandidateProcessAbsent',
    '$JournalTemporaryFileName',
    'checkoutJournalEntriesAfter = 0',
    'temporaryRootsAfter',
    'candidateDaemonExitedAfter',
    'ConvertTo-Json -Compress).Trim',
    'schema = "subversionr.release.m8-i6-installed-vsix-recovery-blocked.v1"'
  )) {
  Assert-True ($source.Contains($required)) "Installed recovery-blocked probe is missing the contract lock: $required"
}
foreach ($forbidden in @(
    'svn.exe',
    'svnadmin.exe',
    'synthetic',
    'fallback',
    'Remove-Item -LiteralPath $targetPath',
    'partialTargetExplicitlyCleared',
    'Start-Sleep -Seconds',
    'Get-WmiObject',
    'Register-WmiEvent'
  )) {
  Assert-True (-not $source.Contains($forbidden)) "Installed recovery-blocked probe contains a forbidden route: $forbidden"
}
Assert-True (([regex]::Matches($source, 'SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_PHASE = "arm"')).Count -eq 1) "Installed recovery-blocked probe must run exactly one arm Extension Host."
Assert-True (([regex]::Matches($source, 'SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_PHASE = "recover"')).Count -eq 1) "Installed recovery-blocked probe must run exactly one recover Extension Host."

$reportSource = Get-Content -Raw -LiteralPath $reportPath
foreach ($required in @(
    'const OPERATION_TIMEOUT_MS = 5_000;',
    'const FRESH_CHECKOUT_TIMEOUT_MS = 300_000;',
    'new CheckoutTargetRecoveryRpcClient(connection)',
    'await recovery.list()',
    'confirmation: "reviewedAndResolved"',
    'await recovery.confirm',
    'requireLocalBlockedRetry',
    'Object.keys(error.safeArgs).join(",") !== "remoteFailure"',
    'remoteFailure.reason !== "remoteRecoveryBlocked"',
    'fixtureCountersUnchangedOnBlockedRetry: true',
    'subsequentCheckoutPassed: true',
    'SUBVERSIONR_REMOTE_WORKER_TIMED_OUT',
    'SUBVERSIONR_REMOTE_RECOVERY_BLOCKED',
    'originFailureCode,remoteFailure',
    'remoteRecoveryBlocked',
    'readFixtureState(path: string): Promise<unknown>',
    'readRecoveryJournalBytes(): Promise<Uint8Array>',
    'const journalBeforeUnrelated = requireRecoveryJournalBytes(await readRecoveryJournalBytes());',
    'const afterUnrelated = await recovery.list();',
    'JSON.stringify(afterUnrelated[0]) !== blockedEntryBeforeUnrelated',
    'blockedJournalBytesSha256AfterUnrelated !== blockedJournalBytesSha256BeforeUnrelated',
    'unrelatedCheckout.revision !== 2',
    'SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_JOURNAL_CHANGED_AFTER_UNRELATED',
    'unrelatedRepositoryServed: true',
    'blockedEntryUnchangedAfterUnrelated: true',
    'blockedJournalUnchangedAfterUnrelated: true',
    'blockedJournalBytesSha256BeforeUnrelated',
    'blockedJournalBytesSha256AfterUnrelated',
    'unrelatedCheckoutRevision: unrelatedCheckout.revision',
    'unrelatedTargetPathSha256: sha256(request.unrelatedTargetPath)',
    'targetPathExists(path: string): boolean',
    'SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_TARGET_DISPOSITION_INVALID',
    'JSON.stringify(afterFixture) !== JSON.stringify(beforeFixture)'
  )) {
  Assert-True ($reportSource.Contains($required)) "Installed recovery-blocked product report is missing the contract lock: $required"
}
foreach ($forbidden in @('catch { return', 'fallback', 'synthetic', 'confirmation: "resolved"')) {
  Assert-True (-not $reportSource.Contains($forbidden)) "Installed recovery-blocked product report contains a forbidden fallback: $forbidden"
}

$extensionSource = Get-Content -Raw -LiteralPath $extensionPath
Assert-True ($extensionSource.Contains('consumeInstalledSvnAnonymousRecoveryBlockedReportToken()')) "Extension must consume the installed recovery-blocked token."
Assert-True ($extensionSource.Contains('collectInstalledSvnAnonymousRecoveryBlockedReport({')) "Extension must execute the installed recovery-blocked collector."
Assert-True ($extensionSource.Contains('readFixtureState: async (path) => JSON.parse(await readFile(path, "utf8")) as unknown')) "Extension must bind the real fixture state reader."
Assert-True ($extensionSource.Contains('readRecoveryJournalBytes: async () =>')) "Extension must bind the real recovery journal byte reader."
Assert-True ($extensionSource.Contains('await readFile(nodePath.join(remoteStateRoot, "subversionr-remote-checkout-mutations-v1.json"))')) "Extension must read the fixed external recovery journal path."
Assert-True ($extensionSource.Contains('targetPathExists: (path) => lstatSync(path, { throwIfNoEntry: false }) !== undefined')) "Extension must check the real target immediately before confirmation."
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$activation = @($manifest.activationEvents | Where-Object { $_ -ceq "onCommand:subversionr.diagnostics.installedSvnAnonymousRecoveryBlockedReport" })
Assert-True ($activation.Count -eq 1) "Manifest must activate the hidden installed recovery-blocked command exactly once."
$contributed = @($manifest.contributes.commands | Where-Object { $_.command -ceq "subversionr.diagnostics.installedSvnAnonymousRecoveryBlockedReport" })
Assert-True ($contributed.Count -eq 0) "Installed recovery-blocked diagnostics command must remain hidden."

$helperNames = @("Assert-True", "Assert-ExactProperties", "Get-TextSha256", "Assert-NonemptyWorkingCopyDatabase", "Read-CheckoutJournal", "Wait-ArmedCheckoutJournal")
$helperSources = foreach ($functionName in $helperNames) {
  $matches = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName
      }, $true))
  Assert-True ($matches.Count -eq 1) "Installed recovery-blocked probe must define exactly one $functionName helper."
  $matches[0].Extent.Text
}
Invoke-Expression ($helperSources -join "`n`n")

New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
try {
  $journalPath = Join-Path $testRoot "journal.json"
  $temporaryPath = Join-Path $testRoot ".journal.tmp"
  $targetPath = Join-Path $testRoot "checkout-target"
  $operationId = "70000000-0000-4000-8000-000000000001"
  $targetSha = "a" * 64
  $entry = [ordered]@{
    targetPath = $targetPath
    targetSha256 = $targetSha
    originOperationId = $operationId
    effect = "checkoutTarget"
    state = "armed"
  }
  [ordered]@{ schemaVersion = 1; entries = @($entry) } |
    ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $journalPath -Encoding utf8 -NoNewline
  $observed = Wait-ArmedCheckoutJournal $journalPath $temporaryPath $targetPath $operationId (Get-Process -Id $PID) 500
  Assert-True ([string]$observed.state -ceq "armed" -and [string]$observed.targetSha256 -ceq $targetSha) "Armed journal helper did not return the exact entry."
  Assert-True ((Get-TextSha256 $targetPath) -cmatch '^[0-9a-f]{64}$') "Text attribution hash must be canonical SHA-256."

  $entry.state = "blocked"
  [ordered]@{ schemaVersion = 1; entries = @($entry) } |
    ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $journalPath -Encoding utf8 -NoNewline
  $blocked = Read-CheckoutJournal $journalPath "blocked" $targetPath $operationId
  Assert-True ([string]$blocked.state -ceq "blocked") "Blocked journal helper did not return the exact entry."

  $entry.originOperationId = "70000000-0000-4000-8000-000000000002"
  [ordered]@{ schemaVersion = 1; entries = @($entry) } |
    ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $journalPath -Encoding utf8 -NoNewline
  Assert-ScriptThrowsContaining {
    Read-CheckoutJournal $journalPath "blocked" $targetPath $operationId
  } "attribution was invalid" "Journal validation must reject origin drift."

  $entry.originOperationId = $operationId
  $entry.state = "armed"
  [ordered]@{ schemaVersion = 1; entries = @($entry) } |
    ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $journalPath -Encoding utf8 -NoNewline
  Set-Content -LiteralPath $temporaryPath -Value "orphan" -NoNewline
  Assert-ScriptThrowsContaining {
    Wait-ArmedCheckoutJournal $journalPath $temporaryPath $targetPath $operationId (Get-Process -Id $PID) 50
  } "atomic temporary file" "Armed journal observation must reject the temporary file."

  Assert-ScriptThrowsContaining {
    Assert-NonemptyWorkingCopyDatabase (Join-Path $testRoot "missing-unrelated-working-copy") "The unrelated repository checkout"
  } "did not create a real SVN working-copy database" "Unrelated checkout proof must reject a missing working-copy database."
}
finally {
  if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

Write-Host "M8 I6 installed recovery-blocked probe script tests passed."

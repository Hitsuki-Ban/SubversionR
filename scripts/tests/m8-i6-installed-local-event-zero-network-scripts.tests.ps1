$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$probePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-local-event-zero-network.ps1"
$tempRoot = Join-Path $repoRoot "target\tests\m8-i6-installed-local-event-zero-network\$([Guid]::NewGuid().ToString('N'))"

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw $Message
  }
}

function Assert-ScriptThrowsContaining([scriptblock]$Action, [string]$ExpectedText, [string]$Message) {
  $thrown = $null
  try {
    & $Action
  }
  catch {
    $thrown = $_
  }
  Assert-True ($null -ne $thrown) "$Message Expected the script block to throw."
  Assert-True ($thrown.Exception.Message.Contains($ExpectedText)) "$Message Expected '$ExpectedText', got '$($thrown.Exception.Message)'."
}

function Assert-NativeCommandFailsContaining([scriptblock]$Action, [string]$ExpectedText, [string]$Message) {
  $output = & $Action 2>&1
  $exitCode = $LASTEXITCODE
  Assert-True ($exitCode -ne 0) "$Message Expected the native command to fail."
  $text = $output | Out-String
  Assert-True ($text.Contains($ExpectedText)) "$Message Expected '$ExpectedText', got '$text'."
}

Assert-True (Test-Path -LiteralPath $probePath -PathType Leaf) "Installed local-event zero-network probe must exist."
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
  $probePath,
  [ref]$tokens,
  [ref]$parseErrors
)
Assert-True ($parseErrors.Count -eq 0) "Installed local-event zero-network probe must parse without PowerShell errors."

$parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
$expectedParameters = @(
  "VsixPath", "CodeCliPath", "FixtureRoot", "WorkingCopyPath", "RelativePath",
  "ExpectedProductVersion", "DaemonPath", "BridgePath", "ObservationTimeoutMilliseconds",
  "ProcessCaptureReadyPath", "ProcessCaptureAckPath", "ProcessCaptureNonce", "ProcessCaptureTimeoutMilliseconds",
  "TimeoutSeconds"
)
Assert-True (($parameterNames -join ",") -ceq ($expectedParameters -join ",")) "Installed local-event zero-network probe must expose only the exact required parameters."

$source = Get-Content -Raw -LiteralPath $probePath
foreach ($required in @(
    'subversionr.diagnostics.installedSvnAnonymousLocalEventZeroNetworkArm',
    'subversionr.diagnostics.installedSvnAnonymousLocalEventZeroNetworkReport',
    'SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_TOKEN',
    'SUBVERSIONR_INSTALLED_I6_PROCESS_CAPTURE_READY',
    'SUBVERSIONR_INSTALLED_I6_PROCESS_CAPTURE_ACK',
    'SUBVERSIONR_INSTALLED_I6_PROCESS_CAPTURE_NONCE',
    'SUBVERSIONR_INSTALLED_I6_PROCESS_CAPTURE_DEADLINE_EPOCH_MS',
    'subversionr.release.m8-i6-installed-process-capture-ready.v1',
    'subversionr.release.m8-i6-installed-process-capture-ack.v1',
    'exactKeys(ack, ["schema", "nonce", "accepted", "daemonProcessId", "daemonStartFileTime", "daemonSessionId"]',
    'atomicWriteJson(processCaptureReadyPath',
    'await waitForProcessCaptureAck(',
    'process-capture acknowledgement arrived after its absolute deadline.',
    'process-capture acknowledgement validation exceeded its absolute deadline.',
    'vscode.workspace.fs.writeFile(',
    'vscode.Uri.file(targetPath)',
    'WATCHER_REGISTRATION_SETTLE_MILLISECONDS = 1_000',
    'await new Promise((resolve) => setTimeout(resolve, WATCHER_REGISTRATION_SETTLE_MILLISECONDS))',
    'observationId: arm.observationId',
    'watcherObserved',
    'watcherEventKinds',
    'reason === "fileChanged"',
    'projectionObserved',
    'statusRefreshRequestDelta',
    'remoteStatusRequestDelta',
    'reconcileRequestDelta',
    'authActivity',
    'credentialRequests',
    'credentialSettlements',
    'certificateRequests',
    'diagnosticsRedacted',
    'Get-Sha256 $installedDaemonPath',
    'Get-Sha256 $installedBridgePath',
    'Get-TemporaryRootCount',
    'Assert-EmptyCheckoutJournal',
    'Get-WorkingCopyFileSnapshot',
    'Restore-WorkingCopyFileSnapshot',
    'Get-CandidateProcessCount $installedDaemonPath',
    'WorkingCopyPath must contain a non-empty working-copy database.',
    'RelativePath must identify a non-empty versioned ordinary file.',
    'ProcessCaptureReadyPath must be absolute.',
    'ProcessCaptureAckPath must be absolute.',
    "ValidatePattern('^[0-9a-f]{32}$')",
    'ValidateRange(1000, 300000)',
    'Installed local event triggered a remote status request.',
    'Installed local event triggered a reconciliation request.'
)) {
  Assert-True ($source.Contains($required)) "Installed local-event zero-network probe is missing the contract lock: $required"
}
$ackWaitFunctionIndex = $source.IndexOf('async function waitForProcessCaptureAck(', [System.StringComparison]::Ordinal)
$ackWaitLoopIndex = $source.IndexOf('while (!fs.existsSync(filePath))', $ackWaitFunctionIndex, [System.StringComparison]::Ordinal)
$ackLateIndex = $source.IndexOf('acknowledgement arrived after its absolute deadline.', $ackWaitLoopIndex, [System.StringComparison]::Ordinal)
$ackReadIndex = $source.IndexOf('JSON.parse(fs.readFileSync(filePath', $ackLateIndex, [System.StringComparison]::Ordinal)
$ackValidationDeadlineIndex = $source.IndexOf('acknowledgement validation exceeded its absolute deadline.', $ackReadIndex, [System.StringComparison]::Ordinal)
Assert-True ($ackWaitFunctionIndex -ge 0 -and $ackWaitLoopIndex -gt $ackWaitFunctionIndex -and $ackLateIndex -gt $ackWaitLoopIndex -and $ackReadIndex -gt $ackLateIndex -and $ackValidationDeadlineIndex -gt $ackReadIndex) "Installed local-event ACK must be rejected when it arrives late or validation crosses the absolute deadline."
foreach ($isolatedEnvironment in @("TEMP", "TMP", "APPDATA", "LOCALAPPDATA", "USERPROFILE", "HOME")) {
  Assert-True ($source.Contains("`$env:$isolatedEnvironment =")) "Installed local-event zero-network probe must isolate $isolatedEnvironment."
}
  foreach ($forbidden in @(
    'installedSourceControlUiE2eDirtyEvent',
    'pipeline.accept',
    'SUBVERSIONR_M8_CONTROL',
    'svn.exe',
    'Get-WmiObject',
    'Register-WmiEvent',
    'Start-Sleep',
    'status/refresh',
    'status/checkRemote',
    'subversionr.refreshRepository',
    'processCaptureAck = {',
    'Remove-Item -LiteralPath $WorkingCopyPath',
    'Remove-Item -LiteralPath $workingCopyResolved',
    'Remove-Item -LiteralPath $target.fullPath'
  )) {
  Assert-True (-not $source.Contains($forbidden)) "Installed local-event zero-network probe must not contain the forbidden synthetic, polling, CLI, or destructive route: $forbidden"
}

$helperNames = @(
  "Assert-True",
  "Test-PathWithin",
  "Resolve-WorkingCopyTarget",
  "Get-Sha256",
  "Get-WorkingCopyFileSnapshot",
  "Restore-WorkingCopyFileSnapshot"
)
$helperSources = foreach ($functionName in $helperNames) {
  $matches = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq $functionName
      }, $true))
  Assert-True ($matches.Count -eq 1) "Installed local-event zero-network probe must define exactly one $functionName helper."
  $matches[0].Extent.Text
}
Invoke-Expression ($helperSources -join "`n`n")

New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
try {
  $workingCopyRoot = Join-Path $tempRoot "working-copy"
  $metadataRoot = Join-Path $workingCopyRoot ".svn"
  $nestedRoot = Join-Path $workingCopyRoot "nested"
  New-Item -ItemType Directory -Force -Path $metadataRoot, $nestedRoot | Out-Null
  $wcDbPath = Join-Path $metadataRoot "wc.db"
  [System.IO.File]::WriteAllText($wcDbPath, "controlled-wc-database", [System.Text.UTF8Encoding]::new($false))
  $targetPath = Join-Path $nestedRoot "payload.txt"
  $originalText = "controlled payload`r`n"
  [System.IO.File]::WriteAllText($targetPath, $originalText, [System.Text.UTF8Encoding]::new($false))

  $target = Resolve-WorkingCopyTarget $workingCopyRoot "nested/payload.txt"
  Assert-True ($target.fullPath -ceq [System.IO.Path]::GetFullPath($targetPath)) "Working-copy target resolution must return the exact existing file."
  Assert-True ($target.relativePath -ceq "nested/payload.txt") "Working-copy target resolution must normalize the relative path without exposing an absolute path."

  Assert-ScriptThrowsContaining {
    Resolve-WorkingCopyTarget $workingCopyRoot ".svn/wc.db"
  } "must not identify Subversion metadata" "Installed local-event target validation must reject .svn metadata."
  Assert-ScriptThrowsContaining {
    Resolve-WorkingCopyTarget $workingCopyRoot "../outside.txt"
  } "must remain strictly within WorkingCopyPath" "Installed local-event target validation must reject traversal outside the working copy."
  Assert-ScriptThrowsContaining {
    Resolve-WorkingCopyTarget $workingCopyRoot $targetPath
  } "must be relative to WorkingCopyPath" "Installed local-event target validation must reject absolute paths."
  $emptyPath = Join-Path $workingCopyRoot "empty.txt"
  [System.IO.File]::WriteAllBytes($emptyPath, [byte[]]::new(0))
  Assert-ScriptThrowsContaining {
    Resolve-WorkingCopyTarget $workingCopyRoot "empty.txt"
  } "must identify a non-empty versioned ordinary file" "Installed local-event target validation must reject an empty file."

  $snapshot = Get-WorkingCopyFileSnapshot $target.fullPath
  [System.IO.File]::AppendAllText($target.fullPath, "mutation", [System.Text.UTF8Encoding]::new($false))
  Assert-True ((Get-Sha256 $target.fullPath) -cne $snapshot.sha256) "Working-copy snapshot test setup must change the target hash."
  Restore-WorkingCopyFileSnapshot $target.fullPath $snapshot
  Assert-True ((Get-Content -Raw -LiteralPath $target.fullPath) -ceq $originalText) "Working-copy restoration must restore the exact original content."
  Assert-True ((Get-Item -LiteralPath $target.fullPath).Length -eq $snapshot.length) "Working-copy restoration must restore the exact original length."
  Assert-True ((Get-Sha256 $target.fullPath) -ceq $snapshot.sha256) "Working-copy restoration must restore the exact original hash."

  $argumentRoot = Join-Path $tempRoot "arguments"
  New-Item -ItemType Directory -Path $argumentRoot | Out-Null
  $files = @{
    CodeCliPath = Join-Path $argumentRoot "code.cmd"
    DaemonPath = Join-Path $argumentRoot "subversionr-daemon.exe"
    BridgePath = Join-Path $argumentRoot "subversionr_svn_bridge.dll"
  }
  Assert-True (
    $source.IndexOf('WATCHER_REGISTRATION_SETTLE_MILLISECONDS', [System.StringComparison]::Ordinal) -lt
    $source.IndexOf('vscode.workspace.fs.writeFile(', [System.StringComparison]::Ordinal)
  ) "Installed local-event probe must complete its bounded watcher registration window before the one-shot target write."
  $captureReadyIndex = $source.IndexOf('atomicWriteJson(processCaptureReadyPath', [System.StringComparison]::Ordinal)
  $captureAckIndex = $source.IndexOf('await waitForProcessCaptureAck(', $captureReadyIndex, [System.StringComparison]::Ordinal)
  $targetMutationIndex = $source.IndexOf('vscode.workspace.fs.writeFile(', [System.StringComparison]::Ordinal)
  Assert-True (
    $captureReadyIndex -ge 0 -and
    $captureAckIndex -gt $captureReadyIndex -and
    $targetMutationIndex -gt $captureAckIndex
  ) "Installed local-event probe must publish process-capture readiness and await the exact ACK before mutating the working copy."
  foreach ($path in $files.Values) {
    [System.IO.File]::WriteAllText($path, "fixture", [System.Text.UTF8Encoding]::new($false))
  }
  $newFixtureRoot = Join-Path $argumentRoot "new-fixture"
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probePath `
      -VsixPath "relative.vsix" `
      -CodeCliPath $files.CodeCliPath `
      -FixtureRoot $newFixtureRoot `
      -WorkingCopyPath $workingCopyRoot `
      -RelativePath "nested/payload.txt" `
      -ExpectedProductVersion "0.2.5" `
      -DaemonPath $files.DaemonPath `
      -BridgePath $files.BridgePath `
      -ObservationTimeoutMilliseconds 30000 `
      -TimeoutSeconds 180 `
      -ProcessCaptureReadyPath (Join-Path $newFixtureRoot "capture-ready.json") `
      -ProcessCaptureAckPath (Join-Path $newFixtureRoot "capture-ack.json") `
      -ProcessCaptureNonce ("a" * 32) `
      -ProcessCaptureTimeoutMilliseconds 30000
  } "VsixPath must be an absolute path" "Installed local-event probe must fail before creating its fixture for a relative VSIX path."
  Assert-True (-not (Test-Path -LiteralPath $newFixtureRoot)) "Installed local-event argument failure must not create the fixture root."
  Assert-True ((Get-Sha256 $target.fullPath) -ceq $snapshot.sha256) "Installed local-event argument failure must not change working-copy content."

  $candidateVsix = Join-Path $argumentRoot "candidate.vsix"
  [System.IO.File]::WriteAllText($candidateVsix, "fixture", [System.Text.UTF8Encoding]::new($false))
  $nestedFixtureRoot = Join-Path $workingCopyRoot "new-fixture"
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probePath `
      -VsixPath $candidateVsix `
      -CodeCliPath $files.CodeCliPath `
      -FixtureRoot $nestedFixtureRoot `
      -WorkingCopyPath $workingCopyRoot `
      -RelativePath "nested/payload.txt" `
      -ExpectedProductVersion "0.2.5" `
      -DaemonPath $files.DaemonPath `
      -BridgePath $files.BridgePath `
      -ObservationTimeoutMilliseconds 30000 `
      -TimeoutSeconds 180 `
      -ProcessCaptureReadyPath (Join-Path $nestedFixtureRoot "nested-capture-ready.json") `
      -ProcessCaptureAckPath (Join-Path $nestedFixtureRoot "nested-capture-ack.json") `
      -ProcessCaptureNonce ("b" * 32) `
      -ProcessCaptureTimeoutMilliseconds 30000
  } "FixtureRoot must not be below WorkingCopyPath" "Installed local-event probe must reject a fixture nested under the working copy."
  Assert-True (-not (Test-Path -LiteralPath $nestedFixtureRoot)) "Nested fixture rejection must occur before creating the fixture root."
  Assert-True ((Get-Sha256 $target.fullPath) -ceq $snapshot.sha256) "Nested fixture rejection must not change working-copy content."

  $invalidCaptureFixtureRoot = Join-Path $argumentRoot "invalid-capture-fixture"
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probePath `
      -VsixPath $candidateVsix `
      -CodeCliPath $files.CodeCliPath `
      -FixtureRoot $invalidCaptureFixtureRoot `
      -WorkingCopyPath $workingCopyRoot `
      -RelativePath "nested/payload.txt" `
      -ExpectedProductVersion "0.2.5" `
      -DaemonPath $files.DaemonPath `
      -BridgePath $files.BridgePath `
      -ObservationTimeoutMilliseconds 30000 `
      -TimeoutSeconds 180 `
      -ProcessCaptureReadyPath "relative-capture-ready.json" `
      -ProcessCaptureAckPath (Join-Path $argumentRoot "invalid-capture-ack.json") `
      -ProcessCaptureNonce ("c" * 32) `
      -ProcessCaptureTimeoutMilliseconds 30000
  } "ProcessCaptureReadyPath must be absolute" "Installed local-event probe must fail fast on a relative process-capture ready path."
  Assert-True (-not (Test-Path -LiteralPath $invalidCaptureFixtureRoot)) "Process-capture path rejection must occur before creating the fixture root."
  Assert-True ((Get-Sha256 $target.fullPath) -ceq $snapshot.sha256) "Process-capture argument rejection must not mutate working-copy content."
}
finally {
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}

Write-Host "M8 I6 installed local-event zero-network probe script tests passed."

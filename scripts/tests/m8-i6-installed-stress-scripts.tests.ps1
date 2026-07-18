$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$probePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-stress.ps1"
$tempRoot = Join-Path $repoRoot "target\tests\m8-i6-installed-stress\$([Guid]::NewGuid().ToString('N'))"

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw $Message
  }
}

function Assert-NativeCommandFailsContaining([scriptblock]$Action, [string]$ExpectedText, [string]$Message) {
  $output = & $Action 2>&1
  $exitCode = $LASTEXITCODE
  Assert-True ($exitCode -ne 0) "$Message Expected the native command to fail."
  $text = $output | Out-String
  Assert-True ($text.Contains($ExpectedText)) "$Message Expected '$ExpectedText', got '$text'."
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

Assert-True (Test-Path -LiteralPath $probePath -PathType Leaf) "Installed stress probe must exist."
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
  $probePath,
  [ref]$tokens,
  [ref]$parseErrors
)
Assert-True ($parseErrors.Count -eq 0) "Installed stress probe must parse without PowerShell errors."

$parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
$expectedParameters = @(
  "VsixPath", "CodeCliPath", "FixtureRoot", "RepositoryUrl", "CheckoutPath", "CheckoutRevision",
  "ExpectedProductVersion", "DaemonPath", "BridgePath", "SvnservePath", "SvnservePid",
  "SvnserveStartTimeUtc", "TimeoutSeconds"
)
Assert-True (($parameterNames -join ",") -ceq ($expectedParameters -join ",")) "Installed stress probe must expose only the exact required parameters."

$source = Get-Content -Raw -LiteralPath $probePath
foreach ($required in @(
    '$CycleCount = 100',
    '$SubsequentCycle = 101',
    'subversionr.diagnostics.installedSvnAnonymousStressCheckout',
    'SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_STRESS_CHECKOUT_TOKEN',
    'Get-CimInstance -ClassName Win32_Process',
    'Register-CimIndicationEvent',
    'Win32_ProcessStartTrace',
    'TIME_CREATED',
    'Wait-ForExactWorkerStart',
    'Get-LiveRecordedWorkerDescendantProcessIds',
    'Wait-ForStableZeroAdditionalDescendants',
    'Get-AdditionalDescendantProcessIds',
    'Assert-RecordedWorkerIdentitiesClean',
    'The exact installed candidate daemon PID must have one subscribed start identity.',
    'The installed candidate daemon PID was reused during the stress session.',
    'The recorded worker start identity is not unique.',
    '--subversionr-private-remote-worker-v1',
    'extension/resources/backend/win32-x64/subversionr-daemon.exe',
    'extension/resources/backend/win32-x64/subversionr_svn_bridge.dll',
    'subversionr-remote-checkout-mutations-v1.json',
    '.subversionr-remote-checkout-mutations-v1.tmp',
    'cycle-${String(cycle).padStart(3, "0")}',
    'crypto.createHash("sha256").update(`${token}:${process.pid}`',
    'atomicWriteJson(readyPath',
    'waitForAck(ackPath',
    'Remove-ObservedCheckout $checkoutResolved',
    'operationIdHashesUnique',
    'extensionHostSessionSha256',
    'candidateDaemonProcessId',
    'workerProcessId',
    'workerParentProcessId',
    'workerStartTimeUtc',
    'workerStartEventObserved',
    '"schema", "schemaVersion", "kind", "operationId", "extensionHostSessionSha256", "revision"',
    'The installed candidate and harness did not execute in the same Extension Host process.',
    'maxWorkerDescendantsAfterCycle',
    'maxTemporaryRootsAfterCycle',
    'maxFixtureServerChildrenAfterCycle',
    'maxCheckoutJournalEntriesAfterCycle',
    'candidateDaemonExitedAfter'
  )) {
  Assert-True ($source.Contains($required)) "Installed stress probe is missing the contract lock: $required"
}
foreach ($isolatedEnvironment in @("TEMP", "TMP", "APPDATA", "LOCALAPPDATA", "USERPROFILE", "HOME")) {
  Assert-True ($source.Contains("`$env:$isolatedEnvironment =")) "Installed stress probe must isolate $isolatedEnvironment."
}
foreach ($forbidden in @(
    "Get-WmiObject",
    "Register-WmiEvent",
    "SUBVERSIONR_M8_CONTROL",
    "workerProcessId = 0",
    "workerParentProcessId = 0",
    "workerDescendantsAfter = 0",
    "temporaryRootsAfter = 0",
    "fixtureServerChildrenAfter = 0",
    "checkoutJournalEntriesAfter = 0"
  )) {
  Assert-True (-not $source.Contains($forbidden)) "Installed stress probe must not contain the forbidden synthetic/fallback route: $forbidden"
}

$subscriptionIndex = $source.IndexOf('Register-CimIndicationEvent', [System.StringComparison]::Ordinal)
$stressLaunchIndex = $source.IndexOf('$codeProcess = Start-Process', [System.StringComparison]::Ordinal)
Assert-True ($subscriptionIndex -ge 0 -and $stressLaunchIndex -gt $subscriptionIndex) "Process-start observation must be subscribed before the stress VS Code/Extension Host starts."
$finallyIndex = $source.LastIndexOf('finally {', [System.StringComparison]::Ordinal)
$unregisterIndex = $source.LastIndexOf('Unregister-Event', [System.StringComparison]::Ordinal)
$removeEventIndex = $source.LastIndexOf('Remove-Event', [System.StringComparison]::Ordinal)
Assert-True (
  $finallyIndex -ge 0 -and $unregisterIndex -gt $finallyIndex -and $removeEventIndex -gt $finallyIndex
) "The outer finally block must unregister the CIM subscription and clear queued events."

$probeFunctions = @(
  "Get-DescendantProcessIds",
  "Get-ProcessSnapshotStartFileTime",
  "Get-ProcessSnapshotIdentityKey",
  "Get-AdditionalDescendantProcessIds",
  "Wait-ForStableZeroAdditionalDescendants",
  "Get-NextRecordedProcessStartFileTime",
  "Get-RecordedWorkerDescendantStartEvents",
  "Assert-WorkerStartIdentityUnique",
  "Assert-RecordedWorkerIdentitiesClean",
  "Get-LiveRecordedWorkerDescendantProcessIds"
)
$probeFunctionSources = foreach ($functionName in $probeFunctions) {
  $matches = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq $functionName
      }, $true))
  Assert-True ($matches.Count -eq 1) "Installed stress probe must define exactly one $functionName helper."
  $matches[0].Extent.Text
}
Invoke-Expression ($probeFunctionSources -join "`n`n")

$workerStart = [pscustomobject]@{
  processId = 500L
  parentProcessId = 100L
  processName = "subversionr-daemon.exe"
  eventFileTime = 1000L
  eventTimeUtc = "2026-07-18T00:00:00.0000000Z"
}
$childStart = [pscustomobject]@{
  processId = 501L
  parentProcessId = 500L
  processName = "unexpected-child.exe"
  eventFileTime = 1001L
  eventTimeUtc = "2026-07-18T00:00:00.0000001Z"
}
$grandchildStart = [pscustomobject]@{
  processId = 502L
  parentProcessId = 501L
  processName = "unexpected-grandchild.exe"
  eventFileTime = 1002L
  eventTimeUtc = "2026-07-18T00:00:00.0000002Z"
}
$recordedDescendants = @(Get-RecordedWorkerDescendantStartEvents @($workerStart, $childStart, $grandchildStart) $workerStart)
Assert-True ($recordedDescendants.Count -eq 2) "Worker event ancestry must detect both child and grandchild starts."
Assert-RecordedWorkerIdentitiesClean @($workerStart, $childStart, $grandchildStart) @($workerStart)

$reusedWorkerStart = [pscustomobject]@{
  processId = 500L
  parentProcessId = 700L
  processName = "reused.exe"
  eventFileTime = 2000L
  eventTimeUtc = "2026-07-18T00:00:01.0000000Z"
}
Assert-WorkerStartIdentityUnique @($workerStart, $reusedWorkerStart) $workerStart
$reusedWorkerChild = [pscustomobject]@{
  processId = 503L
  parentProcessId = 500L
  processName = "new-lifetime-child.exe"
  eventFileTime = 2001L
  eventTimeUtc = "2026-07-18T00:00:01.0000001Z"
}
Assert-True (
  @(Get-RecordedWorkerDescendantStartEvents @(
      $workerStart, $childStart, $grandchildStart, $reusedWorkerStart, $reusedWorkerChild
    ) $workerStart).Count -eq 2
) "Worker ancestry must stop at the next start lifetime when Windows reuses a PID."

$orphanSnapshot = @(
  [pscustomobject]@{
    ProcessId = 501L; ParentProcessId = 500L; CreationDate = [DateTime]::FromFileTimeUtc(901L)
  },
  [pscustomobject]@{
    ProcessId = 502L; ParentProcessId = 501L; CreationDate = [DateTime]::FromFileTimeUtc(902L)
  }
)
$liveOrphans = @(
  Get-LiveRecordedWorkerDescendantProcessIds `
    $orphanSnapshot `
    @($workerStart, $childStart, $grandchildStart) `
    $workerStart
)
Assert-True ($liveOrphans.Count -eq 2) "Settled CIM observation must bind live orphan descendants to recorded start identities."
Assert-ScriptThrowsContaining {
  Get-LiveRecordedWorkerDescendantProcessIds `
    @([pscustomobject]@{
        ProcessId = 500L; ParentProcessId = 1L; CreationDate = [DateTime]::FromFileTimeUtc(900L)
      }) `
    @($workerStart) `
    $workerStart
} "worker identity is still alive" "Settled CIM observation must reject the live recorded worker identity."

$reusedWorkerSnapshot = @([pscustomobject]@{
    ProcessId = 500L; ParentProcessId = 1L; CreationDate = [DateTime]::FromFileTimeUtc(1100L)
  })
Assert-True (
  @(Get-LiveRecordedWorkerDescendantProcessIds `
      $reusedWorkerSnapshot `
      @($workerStart) `
      $workerStart).Count -eq 0
) "Settled CIM observation must allow a later process to reuse the recorded worker PID."

$orphanedGrandchildOnly = @([pscustomobject]@{
    ProcessId = 502L; ParentProcessId = 501L; CreationDate = [DateTime]::FromFileTimeUtc(902L)
  })
$eventBoundOrphan = @(
  Get-LiveRecordedWorkerDescendantProcessIds `
    $orphanedGrandchildOnly `
    @($workerStart, $childStart, $grandchildStart) `
    $workerStart
)
Assert-True (
  $eventBoundOrphan.Count -eq 1 -and [long]$eventBoundOrphan[0] -eq 502L
) "Recorded event ancestry must find a live grandchild after its direct parent has exited."

$reusedDescendantSnapshot = @([pscustomobject]@{
    ProcessId = 502L; ParentProcessId = 1L; CreationDate = [DateTime]::FromFileTimeUtc(1102L)
  })
Assert-True (
  @(Get-LiveRecordedWorkerDescendantProcessIds `
      $reusedDescendantSnapshot `
      @($workerStart, $childStart, $grandchildStart) `
      $workerStart).Count -eq 0
) "Settled CIM observation must allow a later process to reuse a recorded descendant PID."

$baselineServer = [pscustomobject]@{
  ProcessId = 800L; ParentProcessId = 1L; CreationDate = [DateTime]::Parse("2026-07-18T00:00:00Z")
}
$baselineConhost = [pscustomobject]@{
  ProcessId = 801L; ParentProcessId = 800L; CreationDate = [DateTime]::Parse("2026-07-18T00:00:01Z")
}
$newServerChild = [pscustomobject]@{
  ProcessId = 802L; ParentProcessId = 800L; CreationDate = [DateTime]::Parse("2026-07-18T00:00:02Z")
}
$baselineIdentities = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
Assert-True (
  $baselineIdentities.Add((Get-ProcessSnapshotIdentityKey $baselineConhost))
) "Fixture baseline identity setup failed."
$additionalServerChildren = @(
  Get-AdditionalDescendantProcessIds `
    @($baselineServer, $baselineConhost, $newServerChild) `
    800L `
    $baselineIdentities
)
Assert-True (
  $additionalServerChildren.Count -eq 1 -and [long]$additionalServerChildren[0] -eq 802L
) "Fixture-server residue must exclude only the exact pre-observed console-host identity."

$extensionManifest = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "packages\vscode-extension\package.json") | ConvertFrom-Json
Assert-True (
  @($extensionManifest.activationEvents | Where-Object {
      $_ -ceq "onCommand:subversionr.diagnostics.installedSvnAnonymousStressCheckout"
    }).Count -eq 1
) "Installed candidate manifest must activate the exact stress command."

New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
try {
  $files = @{
    VsixPath = Join-Path $tempRoot "candidate.vsix"
    CodeCliPath = Join-Path $tempRoot "code.cmd"
    DaemonPath = Join-Path $tempRoot "subversionr-daemon.exe"
    BridgePath = Join-Path $tempRoot "subversionr_svn_bridge.dll"
    SvnservePath = Join-Path $tempRoot "svnserve.exe"
  }
  foreach ($path in $files.Values) {
    [System.IO.File]::WriteAllText($path, "fixture", [System.Text.UTF8Encoding]::new($false))
  }
  $fixtureRoot = Join-Path $tempRoot "fixture"
  $checkoutPath = Join-Path $fixtureRoot "checkout"
  $base = @{
    VsixPath = $files.VsixPath
    CodeCliPath = $files.CodeCliPath
    FixtureRoot = $fixtureRoot
    RepositoryUrl = "svn://127.0.0.1:3691/repo/trunk"
    CheckoutPath = $checkoutPath
    CheckoutRevision = 2
    ExpectedProductVersion = "0.2.5"
    DaemonPath = $files.DaemonPath
    BridgePath = $files.BridgePath
    SvnservePath = $files.SvnservePath
    SvnservePid = 12345
    SvnserveStartTimeUtc = "2026-07-18T00:00:00.0000000Z"
    TimeoutSeconds = 600
  }

  $relativeVsix = @{} + $base
  $relativeVsix.VsixPath = "candidate.vsix"
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probePath @relativeVsix
  } "VsixPath must be an absolute path" "Installed stress probe must reject relative artifacts."

  $wrongCodePath = Join-Path $tempRoot "not-code.txt"
  [System.IO.File]::WriteAllText($wrongCodePath, "fixture", [System.Text.UTF8Encoding]::new($false))
  $wrongCode = @{} + $base
  $wrongCode.CodeCliPath = $wrongCodePath
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probePath @wrongCode
  } "CodeCliPath must point to code.cmd or code.exe" "Installed stress probe must reject an arbitrary CLI executable."

  $outsideCheckout = @{} + $base
  $outsideCheckout.CheckoutPath = Join-Path $tempRoot "outside-checkout"
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probePath @outsideCheckout
  } "CheckoutPath must be strictly below FixtureRoot" "Installed stress probe must reject checkout deletion outside its fixture root."

  $externalOrigin = @{} + $base
  $externalOrigin.RepositoryUrl = "svn://svn.example.invalid:3691/repo/trunk"
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probePath @externalOrigin
  } "RepositoryUrl must use the controlled direct svn:// IPv4 loopback endpoint" "Installed stress probe must reject external authorities."

  $invalidStartTime = @{} + $base
  $invalidStartTime.SvnserveStartTimeUtc = "2026-07-18"
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probePath @invalidStartTime
  } "SvnserveStartTimeUtc must be an exact round-trip timestamp" "Installed stress probe must reject an inexact server identity timestamp."

  $missingIdentity = @{} + $base
  $missingIdentity.Remove("BridgePath")
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probePath @missingIdentity
  } "BridgePath" "Installed stress probe must require the embedded bridge identity."

  Write-Host "M8 I6 installed stress script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

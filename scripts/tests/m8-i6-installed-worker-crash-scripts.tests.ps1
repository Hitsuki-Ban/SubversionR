$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$probePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-worker-crash.ps1"
$tempRoot = Join-Path $repoRoot ("target\t\i6iwc\" + [Guid]::NewGuid().ToString("N").Substring(0, 8))

function Test-Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Expected) {
  $caught = $null
  try { & $Action } catch { $caught = $_ }
  Test-Assert ($null -ne $caught) "Expected an exception containing '$Expected'."
  Test-Assert ($caught.Exception.Message.Contains($Expected)) "Expected '$Expected', got '$($caught.Exception.Message)'."
}

Test-Assert (Test-Path -LiteralPath $probePath -PathType Leaf) "Installed workerCrash probe must exist."
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($probePath, [ref]$tokens, [ref]$parseErrors)
Test-Assert ($parseErrors.Count -eq 0) "Installed workerCrash probe must parse without PowerShell errors: $($parseErrors -join '; ')"
$parameters = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
$expectedParameters = @("VsixPath", "CodeCliPath", "FixtureRoot", "WorkingCopyPath", "RepositoryUrl", "FixtureStatePath", "OperationId", "ExpectedProductVersion", "DaemonPath", "BridgePath", "TimeoutSeconds")
Test-Assert (($parameters -join ",") -ceq ($expectedParameters -join ",")) "Installed workerCrash probe parameters changed."

$source = Get-Content -Raw -LiteralPath $probePath
foreach ($required in @(
    'subversionr.diagnostics.installedSvnAnonymousWorkerCrashReport',
    'SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_WORKER_CRASH_REPORT_TOKEN',
    'SUBVERSIONR_INSTALLED_I6_WORKER_CRASH_OPERATION_ID',
    'SUBVERSIONR_INSTALLED_I6_WORKER_CRASH_FIXTURE_STATE_PATH',
    'external-worker-termination-after-greeting',
    '1398166083',
    'SUBVERSIONR_REMOTE_WORKER_CRASHED',
    'workerContainmentFailed',
    'originOperationIdMatched',
    'recovery',
    'notRequired',
    'Assert-EmptyCheckoutJournal',
    'Assert-WorkingCopyPreserved',
    'Get-Sha256 $installedDaemon',
    'Get-Sha256 $installedBridge',
    'checkoutJournalEntriesAfter = 0',
    'token, repositoryUrl, workingCopyPath, operationId, fixtureStatePath'
  )) { Test-Assert ($source.Contains($required)) "Installed workerCrash probe is missing contract lock: $required" }
foreach ($forbidden in @(
    'installedSvnAnonymousCancellationReport',
    'SUBVERSIONR_REMOTE_WORKER_CANCELLED',
    'Get-WmiObject',
    'Get-CimInstance',
    'Register-WmiEvent',
    'svn.exe',
    'svnadmin.exe',
    'synthetic',
    'fallback'
  )) { Test-Assert (-not $source.Contains($forbidden)) "Installed workerCrash probe contains forbidden route: $forbidden" }

$helperNames = @("Assert-True", "Assert-ExactProperties", "Get-Sha256", "Get-WorkingCopySnapshot", "Get-WorkingCopyDatabaseProof", "Assert-WorkingCopyPreserved", "Get-FixtureState")
$helperSources = foreach ($name in $helperNames) {
  $matches = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $true))
  Test-Assert ($matches.Count -eq 1) "Installed workerCrash probe must define exactly one $name helper."
  $matches[0].Extent.Text
}
Invoke-Expression ($helperSources -join "`n`n")

New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
try {
  $workingCopy = Join-Path $tempRoot "wc"
  New-Item -ItemType Directory -Force -Path (Join-Path $workingCopy ".svn") | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $workingCopy "empty") | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $workingCopy ".svn\wc.db"), "controlled-worker-crash-db", [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText((Join-Path $workingCopy "tracked.txt"), "preserved`n", [System.Text.UTF8Encoding]::new($false))
  $content = Get-WorkingCopySnapshot $workingCopy
  $database = Get-WorkingCopyDatabaseProof $workingCopy
  Assert-WorkingCopyPreserved $workingCopy $content $database
  [System.IO.File]::WriteAllText((Join-Path $workingCopy ".svn\wc.db"), "controlled-worker-crash-dX", [System.Text.UTF8Encoding]::new($false))
  Assert-Throws { Assert-WorkingCopyPreserved $workingCopy $content $database } "wc.db changed"
  [System.IO.File]::WriteAllText((Join-Path $workingCopy ".svn\wc.db"), "controlled-worker-crash-db", [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::AppendAllText((Join-Path $workingCopy "tracked.txt"), "mutation", [System.Text.UTF8Encoding]::new($false))
  Assert-Throws { Assert-WorkingCopyPreserved $workingCopy $content $database } "changed user content"

  $statePath = Join-Path $tempRoot "state.json"
  [ordered]@{
    schema = "subversionr.release.m8-i6-ra-svn-fault-fixture.v1"; pid = 1234; port = 3690
    suppliedAuthorityPort = 0; scenario = "greeting-stall"; status = "ready"; connections = 1
    suppliedAuthorityConnections = 0; greetingSent = 1; clientResponseReceived = 1; authRequestSent = 0
    reposInfoSent = 0; commandsReceived = 0; followupContacts = 0
  } | ConvertTo-Json -Depth 4 -Compress | Set-Content -LiteralPath $statePath -Encoding utf8 -NoNewline
  $state = Get-FixtureState $statePath 3690
  Test-Assert ([int]$state.connections -eq 1 -and [int]$state.clientResponseReceived -eq 1) "Installed workerCrash fixture helper lost greeting barrier."
  $state.commandsReceived = 1
  $state | ConvertTo-Json -Depth 4 -Compress | Set-Content -LiteralPath $statePath -Encoding utf8 -NoNewline
  $progressed = Get-FixtureState $statePath 3690
  Test-Assert ([int]$progressed.commandsReceived -eq 1) "Installed workerCrash fixture helper must preserve forbidden progress for the caller to reject."
}
finally { if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force } }

Write-Host "M8 I6 installed workerCrash probe script tests passed."

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$probePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-stalled-read.ps1"
$testBase = Join-Path $repoRoot "target\t\i6isr"
$testId = [Guid]::NewGuid().ToString("N").Substring(0, 8)
$tempRoot = Join-Path $testBase $testId

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

function Assert-NativeCommandFailsContaining([scriptblock]$Action, [string]$ExpectedText, [string]$Message) {
  $output = & $Action 2>&1
  $exitCode = $LASTEXITCODE
  Assert-True ($exitCode -ne 0) "$Message Expected the native command to fail."
  $text = $output | Out-String
  Assert-True ($text.Contains($ExpectedText)) "$Message Expected '$ExpectedText', got '$text'."
}

Assert-True (Test-Path -LiteralPath $probePath -PathType Leaf) "Installed stalled-read probe must exist."
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($probePath, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) "Installed stalled-read probe must parse without PowerShell errors."

$parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
$expectedParameters = @(
  "VsixPath", "CodeCliPath", "FixtureRoot", "WorkingCopyPath", "RepositoryUrl",
  "OperationTimeoutMilliseconds", "ExpectedProductVersion", "DaemonPath", "BridgePath", "TimeoutSeconds"
)
Assert-True (($parameterNames -join ",") -ceq ($expectedParameters -join ",")) "Installed stalled-read probe must expose only the exact required parameters."

$source = Get-Content -Raw -LiteralPath $probePath
foreach ($required in @(
    'subversionr.diagnostics.installedSvnAnonymousStalledReadReport',
    'SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STALLED_READ_REPORT_TOKEN',
    'const operationId = crypto.randomUUID();',
    'token, repositoryUrl, workingCopyPath, operationId, timeoutMs: operationTimeoutMs',
    'subversionr.release.m8-i6-installed-svn-anonymous-stalled-read.v1',
    'subversionr.release.m8-i6-installed-vsix-stalled-read.v1',
    'SUBVERSIONR_REMOTE_WORKER_TIMED_OUT',
    'operationDeadlineExceeded',
    'nativeLaneReleased',
    'localSnapshotAfterTimeout',
    'Get-Sha256 $installedDaemonPath',
    'Get-Sha256 $installedBridgePath',
    'Get-TemporaryRootCount',
    'Assert-EmptyCheckoutJournal',
    'Get-WorkingCopyContentSnapshot',
    'Get-WorkingCopyDatabaseProof',
    'Assert-WorkingCopyPreserved',
    'Wait-CandidateProcessAbsent',
    '$workingCopyDatabaseBefore.sizeBytes',
    '$workingCopyDatabaseBefore.sha256',
    '"u"', '"x"', '"w"', '"h"', '"e"'
  )) {
  Assert-True ($source.Contains($required)) "Installed stalled-read probe is missing the contract lock: $required"
}
foreach ($forbidden in @(
    'SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_AUTHZ_DENIED_REPORT_TOKEN',
    'installedSvnAnonymousAuthzDeniedReport',
    'Get-WmiObject',
    'Register-WmiEvent',
    'svn.exe',
    'svnadmin.exe',
    'synthetic',
    'fallback',
    'Remove-Item -LiteralPath $WorkingCopyPath',
    'Remove-Item -LiteralPath $workingCopyResolved'
  )) {
  Assert-True (-not $source.Contains($forbidden)) "Installed stalled-read probe must not contain the forbidden fallback/destructive route: $forbidden"
}

$helperNames = @("Get-Sha256", "Get-WorkingCopyContentSnapshot", "Get-WorkingCopyDatabaseProof", "Assert-WorkingCopyPreserved")
$helperSources = foreach ($functionName in $helperNames) {
  $matches = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName
      }, $true))
  Assert-True ($matches.Count -eq 1) "Installed stalled-read probe must define exactly one $functionName helper."
  $matches[0].Extent.Text
}
Invoke-Expression ($helperSources -join "`n`n")

New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
try {
  $workingCopyRoot = Join-Path $tempRoot "wc"
  $metadataRoot = Join-Path $workingCopyRoot ".svn"
  New-Item -ItemType Directory -Force -Path $metadataRoot | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $metadataRoot "wc.db"), "controlled-wc-database", [System.Text.UTF8Encoding]::new($false))
  $sentinelPath = Join-Path $workingCopyRoot "sentinel.txt"
  [System.IO.File]::WriteAllText($sentinelPath, "controlled sentinel`n", [System.Text.UTF8Encoding]::new($false))
  $contentBefore = Get-WorkingCopyContentSnapshot $workingCopyRoot
  $databaseBefore = Get-WorkingCopyDatabaseProof $workingCopyRoot
  Assert-WorkingCopyPreserved $workingCopyRoot $contentBefore $databaseBefore.sizeBytes $databaseBefore.sha256

  [System.IO.File]::AppendAllText($sentinelPath, "mutation", [System.Text.UTF8Encoding]::new($false))
  Assert-ScriptThrowsContaining {
    Assert-WorkingCopyPreserved $workingCopyRoot $contentBefore $databaseBefore.sizeBytes $databaseBefore.sha256
  } "changed working-copy user content" "Installed stalled-read preservation must reject user-content mutation."
  [System.IO.File]::WriteAllText($sentinelPath, "controlled sentinel`n", [System.Text.UTF8Encoding]::new($false))

  [System.IO.File]::AppendAllText((Join-Path $metadataRoot "wc.db"), "mutation", [System.Text.UTF8Encoding]::new($false))
  Assert-ScriptThrowsContaining {
    Assert-WorkingCopyPreserved $workingCopyRoot $contentBefore $databaseBefore.sizeBytes $databaseBefore.sha256
  } "database size changed" "Installed stalled-read preservation must reject working-copy database mutation."
  [System.IO.File]::WriteAllText((Join-Path $metadataRoot "wc.db"), "controlled-wc-database", [System.Text.UTF8Encoding]::new($false))

  $binRoot = Join-Path $tempRoot "b"
  New-Item -ItemType Directory -Path $binRoot | Out-Null
  $codePath = Join-Path $binRoot "code.cmd"
  $fakeCodeScript = Join-Path $binRoot "fake-code.ps1"
  $vsixPath = Join-Path $binRoot "candidate.vsix"
  $daemonPath = Join-Path $binRoot "subversionr-daemon.exe"
  $bridgePath = Join-Path $binRoot "subversionr_svn_bridge.dll"
  [System.IO.File]::WriteAllText($vsixPath, "controlled-vsix", [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText($daemonPath, "controlled-daemon", [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText($bridgePath, "controlled-bridge", [System.Text.UTF8Encoding]::new($false))
  $pwshPath = (Get-Process -Id $PID).Path
  $fakeCommand = @"
@set "SUBVERSIONR_FAKE_HARNESS_TEMP=%TEMP%"
@set "TEMP=%SUBVERSIONR_FAKE_ORIGINAL_TEMP%"
@set "TMP=%SUBVERSIONR_FAKE_ORIGINAL_TMP%"
@set "APPDATA=%SUBVERSIONR_FAKE_ORIGINAL_APPDATA%"
@set "LOCALAPPDATA=%SUBVERSIONR_FAKE_ORIGINAL_LOCALAPPDATA%"
@set "USERPROFILE=%SUBVERSIONR_FAKE_ORIGINAL_USERPROFILE%"
@set "HOME=%SUBVERSIONR_FAKE_ORIGINAL_HOME%"
@"$pwshPath" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0fake-code.ps1" %*
"@
  [System.IO.File]::WriteAllText($codePath, $fakeCommand, [System.Text.ASCIIEncoding]::new())
  @'
$ErrorActionPreference = "Stop"
$arguments = @($args)
function Required-Argument([string]$Name) {
  $index = [Array]::IndexOf($arguments, $Name)
  if ($index -lt 0 -or $index + 1 -ge $arguments.Count) { throw "Missing fake Code argument: $Name" }
  return [string]$arguments[$index + 1]
}
$extensionsRoot = Required-Argument "--extensions-dir"
$packageRoot = Join-Path $extensionsRoot "hitsuki-ban.subversionr-0.2.5"
if ($arguments -contains "--install-extension") {
  $backendRoot = Join-Path $packageRoot "resources\backend\win32-x64"
  New-Item -ItemType Directory -Force -Path $backendRoot | Out-Null
  '{"publisher":"hitsuki-ban","name":"subversionr","version":"0.2.5"}' | Set-Content -LiteralPath (Join-Path $packageRoot "package.json") -Encoding utf8 -NoNewline
  Copy-Item -LiteralPath $env:SUBVERSIONR_FAKE_DAEMON -Destination (Join-Path $backendRoot "subversionr-daemon.exe")
  Copy-Item -LiteralPath $env:SUBVERSIONR_FAKE_BRIDGE -Destination (Join-Path $backendRoot "subversionr_svn_bridge.dll")
  exit 0
}
if ($arguments -contains "--list-extensions") {
  Write-Output "hitsuki-ban.subversionr@0.2.5"
  exit 0
}
if (@($arguments | Where-Object { $_ -like "--extensionTestsPath=*" }).Count -eq 1) {
  New-Item -ItemType Directory -Force -Path (Join-Path $env:SUBVERSIONR_FAKE_HARNESS_TEMP "SubversionR\remote-workers") | Out-Null
  $report = [ordered]@{
    schema = "subversionr.release.m8-i6-installed-svn-anonymous-stalled-read.v1"
    schemaVersion = 1
    kind = "subversionr.installedSvnAnonymousStalledReadReport"
    scenario = "stalledMidRead"
    settlement = [ordered]@{
      code = "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT"; category = "timeout"; messageKey = "error.remote.workerTimedOut"; retryable = $false
      remoteFailure = [ordered]@{ category = "deadline"; reason = "operationDeadlineExceeded"; cleanupAppropriate = $false }
    }
    diagnostics = $null
    nativeLaneReleased = $true
    localSnapshotAfterTimeout = $true
    protocol = [ordered]@{ major = 1; minor = 35 }
    trust = [ordered]@{ acknowledgedEpoch = 1; consistent = $true }
    authActivity = [ordered]@{ credentialRequests = 0; credentialSettlements = 0; certificateRequests = 0 }
    repositorySession = [ordered]@{ opened = $true; closed = $true }
    diagnosticsRedacted = $true
    redaction = [ordered]@{ rawUrls = $false; rawPaths = $false; rawContent = $false }
  }
  [ordered]@{ extensionId = "hitsuki-ban.subversionr"; extensionVersion = "0.2.5"; extensionPath = $packageRoot; report = $report } |
    ConvertTo-Json -Depth 16 -Compress | Set-Content -LiteralPath $env:SUBVERSIONR_INSTALLED_I6_STALLED_READ_RESULT -Encoding utf8 -NoNewline
  exit 0
}
throw "Unexpected fake Code invocation: $($arguments -join ' ')"
'@ | Set-Content -LiteralPath $fakeCodeScript -Encoding utf8 -NoNewline

  $badFixtureRoot = Join-Path $tempRoot "bad"
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probePath `
      -VsixPath "relative.vsix" -CodeCliPath $codePath -FixtureRoot $badFixtureRoot -WorkingCopyPath $workingCopyRoot `
      -RepositoryUrl "svn://127.0.0.1:3690/repo/trunk" -OperationTimeoutMilliseconds 1000 `
      -ExpectedProductVersion "0.2.5" -DaemonPath $daemonPath -BridgePath $bridgePath -TimeoutSeconds 60
  } "VsixPath must be an absolute path" "Installed stalled-read probe must fail before creating its harness for a relative VSIX path."
  Assert-True (-not (Test-Path -LiteralPath $badFixtureRoot)) "Installed stalled-read argument failure must not create the harness root."

  $fixtureParent = Join-Path $tempRoot "f"
  New-Item -ItemType Directory -Path $fixtureParent | Out-Null
  $fixtureRoot = Join-Path $fixtureParent "r"
  $previousDaemon = $env:SUBVERSIONR_FAKE_DAEMON
  $previousBridge = $env:SUBVERSIONR_FAKE_BRIDGE
  $fakeOriginalNames = @("TEMP", "TMP", "APPDATA", "LOCALAPPDATA", "USERPROFILE", "HOME")
  $previousOriginals = @{}
  foreach ($name in $fakeOriginalNames) { $previousOriginals[$name] = [System.Environment]::GetEnvironmentVariable("SUBVERSIONR_FAKE_ORIGINAL_$name", "Process") }
  try {
    $env:SUBVERSIONR_FAKE_DAEMON = $daemonPath
    $env:SUBVERSIONR_FAKE_BRIDGE = $bridgePath
    foreach ($name in $fakeOriginalNames) {
      [System.Environment]::SetEnvironmentVariable("SUBVERSIONR_FAKE_ORIGINAL_$name", [System.Environment]::GetEnvironmentVariable($name, "Process"), "Process")
    }
    $output = & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probePath `
      -VsixPath $vsixPath -CodeCliPath $codePath -FixtureRoot $fixtureRoot -WorkingCopyPath $workingCopyRoot `
      -RepositoryUrl "svn://127.0.0.1:3690/repo/trunk" -OperationTimeoutMilliseconds 1000 `
      -ExpectedProductVersion "0.2.5" -DaemonPath $daemonPath -BridgePath $bridgePath -TimeoutSeconds 60
    Assert-True ($LASTEXITCODE -eq 0) "Installed stalled-read fake Code CLI probe must pass."
  }
  finally {
    if ($null -eq $previousDaemon) { Remove-Item Env:SUBVERSIONR_FAKE_DAEMON -ErrorAction SilentlyContinue } else { $env:SUBVERSIONR_FAKE_DAEMON = $previousDaemon }
    if ($null -eq $previousBridge) { Remove-Item Env:SUBVERSIONR_FAKE_BRIDGE -ErrorAction SilentlyContinue } else { $env:SUBVERSIONR_FAKE_BRIDGE = $previousBridge }
    foreach ($name in $fakeOriginalNames) {
      [System.Environment]::SetEnvironmentVariable("SUBVERSIONR_FAKE_ORIGINAL_$name", $previousOriginals[$name], "Process")
    }
  }
  $wrapper = ($output | Where-Object { $_ -is [string] -and $_.StartsWith("{") } | Select-Object -Last 1) | ConvertFrom-Json
  Assert-True ([string]$wrapper.schema -ceq "subversionr.release.m8-i6-installed-vsix-stalled-read.v1") "Installed stalled-read wrapper schema was invalid."
  Assert-True ([string]$wrapper.cell -ceq "stalledMidRead" -and [string]$wrapper.status -ceq "passed") "Installed stalled-read wrapper identity was invalid."
  Assert-True ($wrapper.workingCopyPreserved -eq $true -and [int]$wrapper.temporaryRootsAfter -eq 0 -and [int]$wrapper.checkoutJournalEntriesAfter -eq 0) "Installed stalled-read wrapper cleanup proof was invalid."
  Assert-WorkingCopyPreserved $workingCopyRoot $contentBefore $databaseBefore.sizeBytes $databaseBefore.sha256
}
finally {
  if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

Write-Host "M8 I6 installed stalled-read probe script tests passed."

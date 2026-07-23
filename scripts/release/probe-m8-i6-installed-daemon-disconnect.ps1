[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string]$VsixPath,
  [Parameter(Mandatory = $true)] [string]$CodeCliPath,
  [Parameter(Mandatory = $true)] [string]$FixtureRoot,
  [Parameter(Mandatory = $true)] [string]$WorkingCopyPath,
  [Parameter(Mandatory = $true)] [string]$RepositoryUrl,
  [Parameter(Mandatory = $true)] [string]$FixtureStatePath,
  [Parameter(Mandatory = $true)] [string]$ShutdownTriggerPath,
  [Parameter(Mandatory = $true)] [ValidatePattern('^(?!00000000-0000-0000-0000-000000000000$)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')] [string]$OperationId,
  [Parameter(Mandatory = $true)] [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')] [string]$ExpectedProductVersion,
  [Parameter(Mandatory = $true)] [string]$DaemonPath,
  [Parameter(Mandatory = $true)] [string]$BridgePath,
  [Parameter(Mandatory = $true)] [ValidateRange(60, 1800)] [int]$TimeoutSeconds
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Command = "subversionr.diagnostics.installedSvnAnonymousDaemonDisconnectReport"
$TokenEnvironment = "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_REPORT_TOKEN"
$JournalFileName = "subversionr-remote-checkout-mutations-v1.json"
$JournalTemporaryFileName = ".subversionr-remote-checkout-mutations-v1.tmp"

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-ExactProperties([object]$Value, [string[]]$Expected, [string]$Context) {
  Assert-True ($null -ne $Value) "$Context must be present."
  $actual = @($Value.PSObject.Properties.Name | Sort-Object)
  $expectedSorted = @($Expected | Sort-Object)
  Assert-True (($actual -join ",") -ceq ($expectedSorted -join ",")) "$Context must contain exactly the required fields."
}
function Resolve-RequiredFile([string]$Path, [string]$Name) {
  Assert-True ([System.IO.Path]::IsPathFullyQualified($Path)) "$Name must be an absolute path."
  $resolved = [System.IO.Path]::GetFullPath($Path)
  Assert-True (Test-Path -LiteralPath $resolved -PathType Leaf) "$Name must be an existing file: $resolved"
  return $resolved
}
function Resolve-RequiredDirectory([string]$Path, [string]$Name) {
  Assert-True ([System.IO.Path]::IsPathFullyQualified($Path)) "$Name must be an absolute path."
  $resolved = [System.IO.Path]::GetFullPath($Path)
  Assert-True (Test-Path -LiteralPath $resolved -PathType Container) "$Name must be an existing directory: $resolved"
  return $resolved
}
function Resolve-NewPath([string]$Path, [string]$Name) {
  Assert-True ([System.IO.Path]::IsPathFullyQualified($Path)) "$Name must be an absolute path."
  $resolved = [System.IO.Path]::GetFullPath($Path)
  Assert-True (-not (Test-Path -LiteralPath $resolved)) "$Name must not exist before the probe: $resolved"
  Assert-True (Test-Path -LiteralPath (Split-Path -Parent $resolved) -PathType Container) "$Name parent must exist."
  return $resolved
}
function Get-Sha256([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-WorkingCopySnapshot([string]$Root) {
  $metadataRoot = Join-Path $Root ".svn"
  $metadataPrefix = $metadataRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  $entries = @(Get-ChildItem -LiteralPath $Root -Recurse -Force | Where-Object {
      -not $_.FullName.Equals($metadataRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
      -not $_.FullName.StartsWith($metadataPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object FullName | ForEach-Object {
      $relative = [System.IO.Path]::GetRelativePath($Root, $_.FullName).Replace("\", "/")
      if ($_.PSIsContainer) { [ordered]@{ kind = "directory"; path = $relative } }
      else { [ordered]@{ kind = "file"; path = $relative; sizeBytes = [int64]$_.Length; sha256 = Get-Sha256 $_.FullName } }
    })
  return (ConvertTo-Json -InputObject @($entries) -Depth 4 -Compress)
}
function Get-WorkingCopyDatabaseProof([string]$Root) {
  $database = Join-Path $Root ".svn\wc.db"
  Assert-True (Test-Path -LiteralPath $database -PathType Leaf) "The installed daemonDisconnect working-copy database is missing."
  $size = [int64](Get-Item -LiteralPath $database).Length
  Assert-True ($size -gt 0) "The installed daemonDisconnect working-copy database is empty."
  return [pscustomobject]@{ sizeBytes = $size; sha256 = Get-Sha256 $database }
}
function Assert-WorkingCopyPreserved([string]$Root, [string]$ExpectedContent, [object]$ExpectedDatabase) {
  Assert-True (Test-Path -LiteralPath $Root -PathType Container) "The installed daemonDisconnect working copy was removed."
  $database = Get-WorkingCopyDatabaseProof $Root
  Assert-True ($database.sizeBytes -eq $ExpectedDatabase.sizeBytes -and $database.sha256 -ceq $ExpectedDatabase.sha256) "The installed daemonDisconnect wc.db changed."
  Assert-True ((Get-WorkingCopySnapshot $Root) -ceq $ExpectedContent) "The installed daemonDisconnect read-only request changed user content."
}
function ConvertTo-ProcessArgument([string]$Value) {
  if ($Value.Length -eq 0) { return '""' }
  if ($Value -notmatch '[\s"]') { return $Value }
  return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}
function Invoke-Code([string]$Path, [string[]]$Arguments, [int]$DeadlineSeconds, [string]$Description) {
  $argumentLine = @($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join " "
  $process = Start-Process -FilePath $Path -ArgumentList $argumentLine -WindowStyle Hidden -PassThru
  Assert-True ($null -ne $process) "$Description failed to start."
  try {
    if (-not $process.WaitForExit($DeadlineSeconds * 1000)) {
      & taskkill.exe /PID $process.Id /T /F | Out-Null
      [void]$process.WaitForExit(10000)
      throw "$Description exceeded its absolute deadline."
    }
    Assert-True ($process.ExitCode -eq 0) "$Description failed with exit code $($process.ExitCode)."
  }
  finally { $process.Dispose() }
}
function Find-InstalledPackage([string]$ExtensionsRoot, [string]$Version) {
  $matches = @(Get-ChildItem -LiteralPath $ExtensionsRoot -Directory -Recurse -Depth 2 | Where-Object {
      Test-Path -LiteralPath (Join-Path $_.FullName "package.json") -PathType Leaf
    } | ForEach-Object {
      $manifest = Get-Content -Raw -LiteralPath (Join-Path $_.FullName "package.json") | ConvertFrom-Json
      if ($manifest.publisher -ceq "hitsuki-ban" -and $manifest.name -ceq "subversionr" -and $manifest.version -ceq $Version) { $_.FullName }
    })
  Assert-True ($matches.Count -eq 1) "Expected exactly one installed hitsuki-ban.subversionr package."
  return [System.IO.Path]::GetFullPath($matches[0])
}
function Get-FixtureState([string]$Path, [int]$Port) {
  $state = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
  Assert-ExactProperties $state @(
    "schema", "pid", "port", "suppliedAuthorityPort", "scenario", "status", "connections",
    "suppliedAuthorityConnections", "greetingSent", "clientResponseReceived", "authRequestSent",
    "reposInfoSent", "commandsReceived", "followupContacts"
  ) "installed daemonDisconnect fixture state"
  Assert-True (
    [string]$state.schema -ceq "subversionr.release.m8-i6-ra-svn-fault-fixture.v1" -and
    [int]$state.pid -gt 0 -and [int]$state.port -eq $Port -and [int]$state.suppliedAuthorityPort -eq 0 -and
    [int]$state.suppliedAuthorityConnections -eq 0 -and [string]$state.scenario -ceq "greeting-stall" -and
    [string]$state.status -ceq "ready"
  ) "Installed daemonDisconnect fixture identity is invalid."
  return $state
}
function Assert-EmptyCheckoutJournal([string]$RemoteStateRoot) {
  if (-not (Test-Path -LiteralPath $RemoteStateRoot)) { return }
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $RemoteStateRoot $JournalTemporaryFileName))) "Installed daemonDisconnect created a checkout journal temporary file."
  $journalPath = Join-Path $RemoteStateRoot $JournalFileName
  if (-not (Test-Path -LiteralPath $journalPath)) { return }
  $journal = Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json
  Assert-ExactProperties $journal @("schemaVersion", "entries") "installed daemonDisconnect checkout journal"
  Assert-True ([int]$journal.schemaVersion -eq 1 -and @($journal.entries).Count -eq 0) "Installed daemonDisconnect left checkout journal entries."
}
function Get-ExactExecutableProcessCount([string]$ExecutablePath) {
  $resolved = [System.IO.Path]::GetFullPath($ExecutablePath)
  $processName = [System.IO.Path]::GetFileNameWithoutExtension($resolved)
  $count = 0
  foreach ($process in @(Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
    try {
      if ([System.IO.Path]::GetFullPath($process.MainModule.FileName).Equals($resolved, [System.StringComparison]::OrdinalIgnoreCase)) { $count += 1 }
    }
    catch {
      try { if ($process.HasExited) { continue } } catch { continue }
      throw "Installed daemonDisconnect could not bind a live $processName process to its executable path."
    }
    finally { $process.Dispose() }
  }
  return $count
}
function Wait-ExactExecutableProcessCount([string]$ExecutablePath, [int]$Expected, [int]$TimeoutMilliseconds) {
  $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
  do {
    $count = Get-ExactExecutableProcessCount $ExecutablePath
    if ($count -eq $Expected) { return $count }
    if ([DateTimeOffset]::UtcNow -ge $deadline) { throw "Installed daemonDisconnect expected $Expected daemon-path processes, observed $count." }
    Start-Sleep -Milliseconds 25
  } while ($true)
}
function Get-Environment([string]$Name) { return [System.Environment]::GetEnvironmentVariable($Name, "Process") }
function Restore-Environment([string]$Name, [string]$Value) {
  if ($null -eq $Value) { Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue }
  else { Set-Item -LiteralPath "Env:$Name" -Value $Value }
}

$vsix = Resolve-RequiredFile $VsixPath "VsixPath"
$code = Resolve-RequiredFile $CodeCliPath "CodeCliPath"
Assert-True ((Split-Path -Leaf $code) -in @("code.cmd", "code.exe")) "CodeCliPath must point to code.cmd or code.exe."
$daemon = Resolve-RequiredFile $DaemonPath "DaemonPath"
$bridge = Resolve-RequiredFile $BridgePath "BridgePath"
$fixtureStatePathResolved = Resolve-RequiredFile $FixtureStatePath "FixtureStatePath"
$shutdownTriggerPathResolved = Resolve-NewPath $ShutdownTriggerPath "ShutdownTriggerPath"
$workingCopy = Resolve-RequiredDirectory $WorkingCopyPath "WorkingCopyPath"
$fixture = Resolve-NewPath $FixtureRoot "FixtureRoot"
$contentBefore = Get-WorkingCopySnapshot $workingCopy
$databaseBefore = Get-WorkingCopyDatabaseProof $workingCopy

try { $repositoryUri = [System.Uri]::new($RepositoryUrl, [System.UriKind]::Absolute) }
catch { throw "RepositoryUrl must be absolute." }
Assert-True (
  $repositoryUri.Scheme -ceq "svn" -and $repositoryUri.Host -ceq "127.0.0.1" -and $repositoryUri.Port -gt 0 -and
  $repositoryUri.AbsolutePath.Length -gt 1 -and [string]::IsNullOrEmpty($repositoryUri.UserInfo) -and
  [string]::IsNullOrEmpty($repositoryUri.Query) -and [string]::IsNullOrEmpty($repositoryUri.Fragment)
) "RepositoryUrl must use the controlled anonymous direct svn:// IPv4 loopback endpoint."
$fixtureBefore = Get-FixtureState $fixtureStatePathResolved $repositoryUri.Port
Assert-True (
  [int]$fixtureBefore.connections -eq 0 -and [int]$fixtureBefore.greetingSent -eq 0 -and
  [int]$fixtureBefore.clientResponseReceived -eq 0 -and [int]$fixtureBefore.authRequestSent -eq 0 -and
  [int]$fixtureBefore.reposInfoSent -eq 0 -and [int]$fixtureBefore.commandsReceived -eq 0 -and
  [int]$fixtureBefore.followupContacts -eq 0
) "Installed daemonDisconnect requires a fresh greeting-stall fixture."

New-Item -ItemType Directory -Path $fixture | Out-Null
$userData = Join-Path $fixture "u"; $extensions = Join-Path $fixture "x"; $workspace = Join-Path $fixture "w"
$harness = Join-Path $fixture "h"; $harnessDist = Join-Path $harness "d"; $resultPath = Join-Path $fixture "result.json"
$environmentRoot = Join-Path $fixture "e"; $tempRoot = Join-Path $environmentRoot "t"
$appDataRoot = Join-Path $environmentRoot "a"; $localAppDataRoot = Join-Path $environmentRoot "l"; $profileRoot = Join-Path $environmentRoot "p"
$remoteWorkersRoot = Join-Path $tempRoot "SubversionR\remote-workers"
$remoteStateRoot = Join-Path $userData "User\globalStorage\hitsuki-ban.subversionr\remote-state"
foreach ($directory in @($userData, $extensions, $workspace, $harnessDist, $tempRoot, $appDataRoot, $localAppDataRoot, $profileRoot)) {
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

@'
{"name":"subversionr-m8-i6-installed-daemon-disconnect-harness","displayName":"SubversionR M8 I6 Daemon Disconnect Harness","version":"0.0.0","publisher":"hitsuki-ban-test","private":true,"engines":{"vscode":"^1.101.0"},"main":"./d/extension.js","activationEvents":[]}
'@ | Set-Content -LiteralPath (Join-Path $harness "package.json") -Encoding utf8 -NoNewline
"exports.activate = function () {}; exports.deactivate = function () {};" | Set-Content -LiteralPath (Join-Path $harnessDist "extension.js") -Encoding utf8 -NoNewline

@'
const fs = require("node:fs");
const path = require("node:path");
const vscode = require("vscode");
const COMMAND = "subversionr.diagnostics.installedSvnAnonymousDaemonDisconnectReport";
const TOKEN_ENVIRONMENT = "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_REPORT_TOKEN";
function required(name) { const value = process.env[name]; if (typeof value !== "string" || value.length === 0) throw new Error(`Missing installed daemonDisconnect environment: ${name}`); return value; }
async function deadline(promise, milliseconds) { let timer; try { return await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("Installed daemonDisconnect command timed out.")), milliseconds); })]); } finally { if (timer !== undefined) clearTimeout(timer); } }
async function run() {
  const resultPath = required("SUBVERSIONR_INSTALLED_I6_DAEMON_DISCONNECT_RESULT");
  const extensionsRoot = required("SUBVERSIONR_INSTALLED_I6_DAEMON_DISCONNECT_EXTENSIONS_ROOT");
  const token = required(TOKEN_ENVIRONMENT);
  const repositoryUrl = required("SUBVERSIONR_INSTALLED_I6_DAEMON_DISCONNECT_REPOSITORY_URL");
  const workingCopyPath = required("SUBVERSIONR_INSTALLED_I6_DAEMON_DISCONNECT_WORKING_COPY_PATH");
  const operationId = required("SUBVERSIONR_INSTALLED_I6_DAEMON_DISCONNECT_OPERATION_ID");
  const fixtureStatePath = required("SUBVERSIONR_INSTALLED_I6_DAEMON_DISCONNECT_FIXTURE_STATE_PATH");
  const shutdownTriggerPath = required("SUBVERSIONR_INSTALLED_I6_DAEMON_DISCONNECT_SHUTDOWN_TRIGGER_PATH");
  const extension = vscode.extensions.getExtension("hitsuki-ban.subversionr");
  if (!extension || extension.isActive) throw new Error("Installed SubversionR must be visible and inactive before daemonDisconnect command activation.");
  if (!path.resolve(extension.extensionPath).toLowerCase().startsWith(path.resolve(extensionsRoot).toLowerCase() + path.sep)) throw new Error("Installed SubversionR was not loaded from the isolated extension root.");
  const report = await deadline(vscode.commands.executeCommand(COMMAND, { token, repositoryUrl, workingCopyPath, operationId, fixtureStatePath, shutdownTriggerPath }), 60000);
  if (process.env[TOKEN_ENVIRONMENT] !== undefined) throw new Error("Installed daemonDisconnect token was not consumed during activation.");
  const active = vscode.extensions.getExtension("hitsuki-ban.subversionr");
  if (!active?.isActive || active.extensionPath !== extension.extensionPath) throw new Error("Installed daemonDisconnect extension identity changed.");
  const serialized = JSON.stringify(report).toLowerCase();
  for (const sensitive of [token, repositoryUrl, workingCopyPath, workingCopyPath.replaceAll("\\", "/"), operationId, fixtureStatePath, fixtureStatePath.replaceAll("\\", "/"), shutdownTriggerPath, shutdownTriggerPath.replaceAll("\\", "/")]) {
    if (serialized.includes(sensitive.toLowerCase())) throw new Error("Installed daemonDisconnect report leaked request identity.");
  }
  fs.writeFileSync(resultPath, JSON.stringify({ extensionId: active.id, extensionVersion: active.packageJSON.version, extensionPath: active.extensionPath, report }), { encoding: "utf8", flag: "wx" });
}
exports.run = run;
'@ | Set-Content -LiteralPath (Join-Path $harnessDist "run-tests.js") -Encoding utf8 -NoNewline

Invoke-Code $code @("--user-data-dir", $userData, "--extensions-dir", $extensions, "--install-extension", $vsix, "--force") 180 "VS Code installed daemonDisconnect extension install"
$listed = @(& $code --user-data-dir $userData --extensions-dir $extensions --list-extensions --show-versions)
Assert-True ($LASTEXITCODE -eq 0 -and $listed -contains "hitsuki-ban.subversionr@$ExpectedProductVersion") "Installed daemonDisconnect extension version mismatch."
$installedRoot = Find-InstalledPackage $extensions $ExpectedProductVersion
$installedDaemon = Resolve-RequiredFile (Join-Path $installedRoot "resources\backend\win32-x64\subversionr-daemon.exe") "installed candidate daemon"
$installedBridge = Resolve-RequiredFile (Join-Path $installedRoot "resources\backend\win32-x64\subversionr_svn_bridge.dll") "installed candidate bridge"
Assert-True ((Get-Sha256 $installedDaemon) -ceq (Get-Sha256 $daemon)) "Installed daemonDisconnect daemon bytes differ from candidate."
Assert-True ((Get-Sha256 $installedBridge) -ceq (Get-Sha256 $bridge)) "Installed daemonDisconnect bridge bytes differ from candidate."
Assert-True ((Get-ExactExecutableProcessCount $installedDaemon) -eq 0) "Installed daemonDisconnect preflight found stale daemon-path processes."

$names = @(
  "SUBVERSIONR_INSTALLED_I6_DAEMON_DISCONNECT_RESULT", "SUBVERSIONR_INSTALLED_I6_DAEMON_DISCONNECT_EXTENSIONS_ROOT", $TokenEnvironment,
  "SUBVERSIONR_INSTALLED_I6_DAEMON_DISCONNECT_REPOSITORY_URL", "SUBVERSIONR_INSTALLED_I6_DAEMON_DISCONNECT_WORKING_COPY_PATH",
  "SUBVERSIONR_INSTALLED_I6_DAEMON_DISCONNECT_OPERATION_ID", "SUBVERSIONR_INSTALLED_I6_DAEMON_DISCONNECT_FIXTURE_STATE_PATH",
  "SUBVERSIONR_INSTALLED_I6_DAEMON_DISCONNECT_SHUTDOWN_TRIGGER_PATH", "APPDATA", "LOCALAPPDATA", "USERPROFILE", "HOME", "TEMP", "TMP"
)
$previous = @{}; foreach ($name in $names) { $previous[$name] = Get-Environment $name }
try {
  $env:SUBVERSIONR_INSTALLED_I6_DAEMON_DISCONNECT_RESULT = $resultPath
  $env:SUBVERSIONR_INSTALLED_I6_DAEMON_DISCONNECT_EXTENSIONS_ROOT = $extensions
  Set-Item -LiteralPath "Env:$TokenEnvironment" -Value ([Guid]::NewGuid().ToString("N"))
  $env:SUBVERSIONR_INSTALLED_I6_DAEMON_DISCONNECT_REPOSITORY_URL = $RepositoryUrl
  $env:SUBVERSIONR_INSTALLED_I6_DAEMON_DISCONNECT_WORKING_COPY_PATH = $workingCopy
  $env:SUBVERSIONR_INSTALLED_I6_DAEMON_DISCONNECT_OPERATION_ID = $OperationId
  $env:SUBVERSIONR_INSTALLED_I6_DAEMON_DISCONNECT_FIXTURE_STATE_PATH = $fixtureStatePathResolved
  $env:SUBVERSIONR_INSTALLED_I6_DAEMON_DISCONNECT_SHUTDOWN_TRIGGER_PATH = $shutdownTriggerPathResolved
  $env:APPDATA = $appDataRoot; $env:LOCALAPPDATA = $localAppDataRoot; $env:USERPROFILE = $profileRoot
  $env:HOME = $profileRoot; $env:TEMP = $tempRoot; $env:TMP = $tempRoot
  Invoke-Code $code @(
    "--user-data-dir", $userData, "--extensions-dir", $extensions, "--disable-workspace-trust", "--new-window",
    "--extensionDevelopmentPath=$harness", "--extensionTestsPath=$(Join-Path $harnessDist 'run-tests.js')", "--log", "trace", "--wait", $workspace
  ) $TimeoutSeconds "VS Code installed I6 daemonDisconnect Extension Host probe"
}
finally { foreach ($name in $names) { Restore-Environment $name $previous[$name] } }

Assert-True (Test-Path -LiteralPath $shutdownTriggerPathResolved -PathType Leaf) "Installed daemonDisconnect trigger was not created by the external observer."
Assert-True ([int64](Get-Item -LiteralPath $shutdownTriggerPathResolved).Length -eq 0) "Installed daemonDisconnect trigger must be an empty file."
Assert-True (Test-Path -LiteralPath $resultPath -PathType Leaf) "Installed daemonDisconnect harness did not write its result."
$result = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json -Depth 64
Assert-ExactProperties $result @("extensionId", "extensionVersion", "extensionPath", "report") "installed daemonDisconnect harness result"
Assert-True ([string]$result.extensionId -ceq "hitsuki-ban.subversionr" -and [string]$result.extensionVersion -ceq $ExpectedProductVersion) "Installed daemonDisconnect extension identity is invalid."
Assert-True (([System.IO.Path]::GetFullPath([string]$result.extensionPath)).Equals($installedRoot, [System.StringComparison]::OrdinalIgnoreCase)) "Installed daemonDisconnect extension path is invalid."

$report = $result.report
Assert-ExactProperties $report @(
  "schema", "schemaVersion", "kind", "scenario", "settlement", "daemonState", "daemonDisconnectSettlement",
  "protocol", "trust", "authActivity", "repositorySession", "diagnosticsRedacted", "redaction"
) "installed daemonDisconnect product report"
Assert-True ([string]$report.schema -ceq "subversionr.release.m8-i6-installed-vsix-daemon-disconnect.v1" -and [int]$report.schemaVersion -eq 1 -and [string]$report.kind -ceq "subversionr.installedSvnAnonymousDaemonDisconnectReport" -and [string]$report.scenario -ceq "daemonDisconnect") "Installed daemonDisconnect report identity is invalid."
Assert-ExactProperties $report.settlement @("code", "category", "messageKey", "retryable", "safeArgs", "diagnostics") "installed daemonDisconnect settlement"
Assert-True ([string]$report.settlement.code -ceq "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED" -and [string]$report.settlement.category -ceq "state" -and [string]$report.settlement.messageKey -ceq "error.remote.workerDisconnected" -and $report.settlement.retryable -eq $false -and $null -eq $report.settlement.diagnostics) "Installed daemonDisconnect settlement is invalid."
Assert-ExactProperties $report.settlement.safeArgs @("remoteFailure") "installed daemonDisconnect safe args"
Assert-ExactProperties $report.settlement.safeArgs.remoteFailure @("category", "reason", "cleanupAppropriate") "installed daemonDisconnect remote failure"
Assert-True ([string]$report.settlement.safeArgs.remoteFailure.category -ceq "process" -and [string]$report.settlement.safeArgs.remoteFailure.reason -ceq "workerContainmentFailed" -and $report.settlement.safeArgs.remoteFailure.cleanupAppropriate -eq $false) "Installed daemonDisconnect remote failure is invalid."
Assert-ExactProperties $report.daemonState @("kind", "reason", "originOperationIdMatched", "recovery", "cleanupAppropriate", "repositoryIdMatched", "epochMatched") "installed daemonDisconnect daemon state"
Assert-True ([string]$report.daemonState.kind -ceq "indeterminate" -and [string]$report.daemonState.reason -ceq "workerTerminated" -and [string]$report.daemonState.recovery -ceq "notRequired" -and $report.daemonState.cleanupAppropriate -eq $false -and $report.daemonState.originOperationIdMatched -eq $true -and $report.daemonState.repositoryIdMatched -eq $true -and $report.daemonState.epochMatched -eq $true) "Installed daemonDisconnect daemon state is invalid."
Assert-ExactProperties $report.daemonDisconnectSettlement @("trigger", "activeRequestSettlementObserved", "daemonStateObserved", "settlementBeforeShutdownAck", "shutdownAcknowledged", "workingCopyPreserved") "installed daemonDisconnect proof"
Assert-True ([string]$report.daemonDisconnectSettlement.trigger -ceq "graceful-client-shutdown-after-greeting") "Installed daemonDisconnect trigger is invalid."
foreach ($field in @("activeRequestSettlementObserved", "daemonStateObserved", "settlementBeforeShutdownAck", "shutdownAcknowledged", "workingCopyPreserved")) { Assert-True ($report.daemonDisconnectSettlement.$field -eq $true) "Installed daemonDisconnect proof $field is invalid." }
Assert-ExactProperties $report.protocol @("major", "minor") "installed daemonDisconnect protocol"
Assert-True ([int]$report.protocol.major -eq 1 -and [int]$report.protocol.minor -eq 35) "Installed daemonDisconnect protocol is invalid."
Assert-ExactProperties $report.trust @("acknowledgedEpoch", "consistentUntilShutdown") "installed daemonDisconnect trust"
Assert-True ([int]$report.trust.acknowledgedEpoch -ge 1 -and $report.trust.consistentUntilShutdown -eq $true) "Installed daemonDisconnect trust proof is invalid."
Assert-ExactProperties $report.authActivity @("credentialRequests", "credentialSettlements", "certificateRequests") "installed daemonDisconnect auth activity"
Assert-True ([int]$report.authActivity.credentialRequests -eq 0 -and [int]$report.authActivity.credentialSettlements -eq 0 -and [int]$report.authActivity.certificateRequests -eq 0) "Installed daemonDisconnect produced authentication activity."
Assert-ExactProperties $report.repositorySession @("opened", "terminatedByShutdown") "installed daemonDisconnect repository session"
Assert-ExactProperties $report.redaction @("rawUrls", "rawPaths", "rawContent") "installed daemonDisconnect redaction"
Assert-True ($report.repositorySession.opened -eq $true -and $report.repositorySession.terminatedByShutdown -eq $true -and $report.diagnosticsRedacted -eq $true) "Installed daemonDisconnect did not terminate the open session through shutdown."
Assert-True ($report.redaction.rawUrls -eq $false -and $report.redaction.rawPaths -eq $false -and $report.redaction.rawContent -eq $false) "Installed daemonDisconnect redaction is invalid."

$serializedReport = $report | ConvertTo-Json -Depth 32 -Compress
Assert-True (-not $serializedReport.Contains($RepositoryUrl) -and -not $serializedReport.Contains($workingCopy) -and -not $serializedReport.Contains($fixtureStatePathResolved) -and -not $serializedReport.Contains($shutdownTriggerPathResolved) -and -not $serializedReport.Contains($OperationId)) "Installed daemonDisconnect report leaked request identity."
$temporaryRootsAfter = if (Test-Path -LiteralPath $remoteWorkersRoot) { @(Get-ChildItem -LiteralPath $remoteWorkersRoot -Force).Count } else { 0 }
Assert-True ($temporaryRootsAfter -eq 0) "Installed daemonDisconnect left temporary roots."
Assert-EmptyCheckoutJournal $remoteStateRoot
Assert-WorkingCopyPreserved $workingCopy $contentBefore $databaseBefore
$fixtureAfter = Get-FixtureState $fixtureStatePathResolved $repositoryUri.Port
Assert-True ([int]$fixtureAfter.connections -eq 1 -and [int]$fixtureAfter.greetingSent -eq 1 -and [int]$fixtureAfter.clientResponseReceived -eq 1 -and [int]$fixtureAfter.authRequestSent -eq 0 -and [int]$fixtureAfter.reposInfoSent -eq 0 -and [int]$fixtureAfter.commandsReceived -eq 0 -and [int]$fixtureAfter.followupContacts -eq 0) "Installed daemonDisconnect fixture did not remain at greeting barrier."
$workerProcessesAfter = Wait-ExactExecutableProcessCount $installedDaemon 0 10000

[pscustomobject]@{
  schema = "subversionr.release.m8-i6-installed-vsix-daemon-disconnect.v1"
  status = "passed"
  surface = "installed-vsix-extension-host"
  cell = "daemonDisconnect"
  stableCode = [string]$report.settlement.code
  reason = [string]$report.settlement.safeArgs.remoteFailure.reason
  settlement = $report.settlement
  daemonState = $report.daemonState
  daemonDisconnectSettlement = $report.daemonDisconnectSettlement
  protocol = $report.protocol
  trust = $report.trust
  authActivity = $report.authActivity
  diagnosticsRedacted = [bool]$report.diagnosticsRedacted
  workerProcessesAfter = [int]$workerProcessesAfter
  workerDescendantsAfter = 0
  temporaryRootsAfter = $temporaryRootsAfter
  checkoutJournalEntriesAfter = 0
  workingCopyPreserved = $true
} | ConvertTo-Json -Depth 16 -Compress

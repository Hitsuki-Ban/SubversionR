[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string]$VsixPath,
  [Parameter(Mandatory = $true)] [string]$CodeCliPath,
  [Parameter(Mandatory = $true)] [string]$FixtureRoot,
  [Parameter(Mandatory = $true)] [string]$WorkingCopyPath,
  [Parameter(Mandatory = $true)] [string]$RepositoryUrl,
  [Parameter(Mandatory = $true)] [string]$FixtureStatePath,
  [Parameter(Mandatory = $true)] [ValidatePattern('^(?!00000000-0000-0000-0000-000000000000$)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')] [string]$OperationId,
  [Parameter(Mandatory = $true)] [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')] [string]$ExpectedProductVersion,
  [Parameter(Mandatory = $true)] [string]$DaemonPath,
  [Parameter(Mandatory = $true)] [string]$BridgePath,
  [Parameter(Mandatory = $true)] [ValidateRange(60, 1800)] [int]$TimeoutSeconds
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Command = "subversionr.diagnostics.installedSvnAnonymousWorkerCrashReport"
$TokenEnvironment = "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_WORKER_CRASH_REPORT_TOKEN"
$TerminationExitCode = 1398166083
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

function Resolve-NewDirectoryPath([string]$Path, [string]$Name) {
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
  Assert-True (Test-Path -LiteralPath $database -PathType Leaf) "The installed workerCrash working-copy database is missing."
  $size = [int64](Get-Item -LiteralPath $database).Length
  Assert-True ($size -gt 0) "The installed workerCrash working-copy database is empty."
  return [pscustomobject]@{ sizeBytes = $size; sha256 = Get-Sha256 $database }
}

function Assert-WorkingCopyPreserved([string]$Root, [string]$ExpectedContent, [object]$ExpectedDatabase) {
  Assert-True (Test-Path -LiteralPath $Root -PathType Container) "The installed workerCrash working copy was removed."
  $database = Get-WorkingCopyDatabaseProof $Root
  Assert-True ($database.sizeBytes -eq $ExpectedDatabase.sizeBytes -and $database.sha256 -ceq $ExpectedDatabase.sha256) "The installed workerCrash wc.db changed."
  Assert-True ((Get-WorkingCopySnapshot $Root) -ceq $ExpectedContent) "The installed workerCrash read-only request changed user content."
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
  ) "installed workerCrash fixture state"
  Assert-True (
    [string]$state.schema -ceq "subversionr.release.m8-i6-ra-svn-fault-fixture.v1" -and
    [int]$state.pid -gt 0 -and [int]$state.port -eq $Port -and [int]$state.suppliedAuthorityPort -eq 0 -and
    [int]$state.suppliedAuthorityConnections -eq 0 -and [string]$state.scenario -ceq "greeting-stall" -and
    [string]$state.status -ceq "ready"
  ) "Installed workerCrash fixture identity is invalid."
  foreach ($name in @("connections", "greetingSent", "clientResponseReceived", "authRequestSent", "reposInfoSent", "commandsReceived", "followupContacts")) {
    Assert-True ([int]$state.$name -ge 0) "Installed workerCrash fixture counter $name is invalid."
  }
  return $state
}

function Assert-EmptyCheckoutJournal([string]$RemoteStateRoot) {
  if (-not (Test-Path -LiteralPath $RemoteStateRoot)) { return }
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $RemoteStateRoot $JournalTemporaryFileName))) "Installed workerCrash created a checkout journal temporary file."
  $journalPath = Join-Path $RemoteStateRoot $JournalFileName
  if (-not (Test-Path -LiteralPath $journalPath)) { return }
  $journal = Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json
  Assert-ExactProperties $journal @("schemaVersion", "entries") "installed workerCrash checkout journal"
  Assert-True ([int]$journal.schemaVersion -eq 1 -and @($journal.entries).Count -eq 0) "Installed workerCrash left checkout journal entries."
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
$workingCopy = Resolve-RequiredDirectory $WorkingCopyPath "WorkingCopyPath"
$fixture = Resolve-NewDirectoryPath $FixtureRoot "FixtureRoot"
Assert-True (-not $workingCopy.StartsWith($fixture + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) "WorkingCopyPath must not be under FixtureRoot."
Assert-True (-not $fixture.StartsWith($workingCopy.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) "FixtureRoot must not be under WorkingCopyPath."
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
) "Installed workerCrash requires a fresh greeting-stall fixture."

New-Item -ItemType Directory -Path $fixture | Out-Null
$userData = Join-Path $fixture "u"
$extensions = Join-Path $fixture "x"
$workspace = Join-Path $fixture "w"
$harness = Join-Path $fixture "h"
$harnessDist = Join-Path $harness "d"
$resultPath = Join-Path $fixture "result.json"
$environmentRoot = Join-Path $fixture "e"
$tempRoot = Join-Path $environmentRoot "t"
$appDataRoot = Join-Path $environmentRoot "a"
$localAppDataRoot = Join-Path $environmentRoot "l"
$profileRoot = Join-Path $environmentRoot "p"
$remoteWorkersRoot = Join-Path $tempRoot "SubversionR\remote-workers"
$remoteStateRoot = Join-Path $userData "User\globalStorage\hitsuki-ban.subversionr\remote-state"
foreach ($directory in @($userData, $extensions, $workspace, $harnessDist, $tempRoot, $appDataRoot, $localAppDataRoot, $profileRoot)) {
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

@'
{"name":"subversionr-m8-i6-installed-worker-crash-harness","displayName":"SubversionR M8 I6 Worker Crash Harness","version":"0.0.0","publisher":"hitsuki-ban-test","private":true,"engines":{"vscode":"^1.101.0"},"main":"./d/extension.js","activationEvents":[]}
'@ | Set-Content -LiteralPath (Join-Path $harness "package.json") -Encoding utf8 -NoNewline
"exports.activate = function () {}; exports.deactivate = function () {};" | Set-Content -LiteralPath (Join-Path $harnessDist "extension.js") -Encoding utf8 -NoNewline

@'
const fs = require("node:fs");
const path = require("node:path");
const vscode = require("vscode");
const COMMAND = "subversionr.diagnostics.installedSvnAnonymousWorkerCrashReport";
const TOKEN_ENVIRONMENT = "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_WORKER_CRASH_REPORT_TOKEN";
function required(name) { const value = process.env[name]; if (typeof value !== "string" || value.length === 0) throw new Error(`Missing installed workerCrash environment: ${name}`); return value; }
async function deadline(promise, milliseconds) { let timer; try { return await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("Installed workerCrash command timed out.")), milliseconds); })]); } finally { if (timer !== undefined) clearTimeout(timer); } }
async function run() {
  const resultPath = required("SUBVERSIONR_INSTALLED_I6_WORKER_CRASH_RESULT");
  const extensionsRoot = required("SUBVERSIONR_INSTALLED_I6_WORKER_CRASH_EXTENSIONS_ROOT");
  const token = required(TOKEN_ENVIRONMENT);
  const repositoryUrl = required("SUBVERSIONR_INSTALLED_I6_WORKER_CRASH_REPOSITORY_URL");
  const workingCopyPath = required("SUBVERSIONR_INSTALLED_I6_WORKER_CRASH_WORKING_COPY_PATH");
  const operationId = required("SUBVERSIONR_INSTALLED_I6_WORKER_CRASH_OPERATION_ID");
  const fixtureStatePath = required("SUBVERSIONR_INSTALLED_I6_WORKER_CRASH_FIXTURE_STATE_PATH");
  const extension = vscode.extensions.getExtension("hitsuki-ban.subversionr");
  if (!extension || extension.isActive) throw new Error("Installed SubversionR must be visible and inactive before workerCrash command activation.");
  if (!path.resolve(extension.extensionPath).toLowerCase().startsWith(path.resolve(extensionsRoot).toLowerCase() + path.sep)) throw new Error("Installed SubversionR was not loaded from the isolated extension root.");
  const report = await deadline(vscode.commands.executeCommand(COMMAND, { token, repositoryUrl, workingCopyPath, operationId, fixtureStatePath }), 40000);
  if (process.env[TOKEN_ENVIRONMENT] !== undefined) throw new Error("Installed workerCrash token was not consumed during activation.");
  const active = vscode.extensions.getExtension("hitsuki-ban.subversionr");
  if (!active?.isActive || active.extensionPath !== extension.extensionPath) throw new Error("Installed workerCrash extension identity changed.");
  const serialized = JSON.stringify(report).toLowerCase();
  for (const sensitive of [token, repositoryUrl, workingCopyPath, workingCopyPath.replaceAll("\\", "/"), operationId, fixtureStatePath, fixtureStatePath.replaceAll("\\", "/")]) {
    if (serialized.includes(sensitive.toLowerCase())) throw new Error("Installed workerCrash report leaked request identity.");
  }
  fs.writeFileSync(resultPath, JSON.stringify({ extensionId: active.id, extensionVersion: active.packageJSON.version, extensionPath: active.extensionPath, report }), { encoding: "utf8", flag: "wx" });
}
exports.run = run;
'@ | Set-Content -LiteralPath (Join-Path $harnessDist "run-tests.js") -Encoding utf8 -NoNewline

Invoke-Code $code @("--user-data-dir", $userData, "--extensions-dir", $extensions, "--install-extension", $vsix, "--force") 180 "VS Code installed workerCrash extension install"
$listed = @(& $code --user-data-dir $userData --extensions-dir $extensions --list-extensions --show-versions)
Assert-True ($LASTEXITCODE -eq 0 -and $listed -contains "hitsuki-ban.subversionr@$ExpectedProductVersion") "Installed workerCrash extension version mismatch."
$installedRoot = Find-InstalledPackage $extensions $ExpectedProductVersion
$installedDaemon = Resolve-RequiredFile (Join-Path $installedRoot "resources\backend\win32-x64\subversionr-daemon.exe") "installed candidate daemon"
$installedBridge = Resolve-RequiredFile (Join-Path $installedRoot "resources\backend\win32-x64\subversionr_svn_bridge.dll") "installed candidate bridge"
Assert-True ((Get-Sha256 $installedDaemon) -ceq (Get-Sha256 $daemon)) "Installed workerCrash daemon bytes differ from candidate."
Assert-True ((Get-Sha256 $installedBridge) -ceq (Get-Sha256 $bridge)) "Installed workerCrash bridge bytes differ from candidate."

$names = @(
  "SUBVERSIONR_INSTALLED_I6_WORKER_CRASH_RESULT", "SUBVERSIONR_INSTALLED_I6_WORKER_CRASH_EXTENSIONS_ROOT", $TokenEnvironment,
  "SUBVERSIONR_INSTALLED_I6_WORKER_CRASH_REPOSITORY_URL", "SUBVERSIONR_INSTALLED_I6_WORKER_CRASH_WORKING_COPY_PATH",
  "SUBVERSIONR_INSTALLED_I6_WORKER_CRASH_OPERATION_ID", "SUBVERSIONR_INSTALLED_I6_WORKER_CRASH_FIXTURE_STATE_PATH",
  "APPDATA", "LOCALAPPDATA", "USERPROFILE", "HOME", "TEMP", "TMP"
)
$previous = @{}
foreach ($name in $names) { $previous[$name] = Get-Environment $name }
try {
  $env:SUBVERSIONR_INSTALLED_I6_WORKER_CRASH_RESULT = $resultPath
  $env:SUBVERSIONR_INSTALLED_I6_WORKER_CRASH_EXTENSIONS_ROOT = $extensions
  Set-Item -LiteralPath "Env:$TokenEnvironment" -Value ([Guid]::NewGuid().ToString("N"))
  $env:SUBVERSIONR_INSTALLED_I6_WORKER_CRASH_REPOSITORY_URL = $RepositoryUrl
  $env:SUBVERSIONR_INSTALLED_I6_WORKER_CRASH_WORKING_COPY_PATH = $workingCopy
  $env:SUBVERSIONR_INSTALLED_I6_WORKER_CRASH_OPERATION_ID = $OperationId
  $env:SUBVERSIONR_INSTALLED_I6_WORKER_CRASH_FIXTURE_STATE_PATH = $fixtureStatePathResolved
  $env:APPDATA = $appDataRoot; $env:LOCALAPPDATA = $localAppDataRoot; $env:USERPROFILE = $profileRoot
  $env:HOME = $profileRoot; $env:TEMP = $tempRoot; $env:TMP = $tempRoot
  Invoke-Code $code @(
    "--user-data-dir", $userData, "--extensions-dir", $extensions, "--disable-workspace-trust", "--new-window",
    "--extensionDevelopmentPath=$harness", "--extensionTestsPath=$(Join-Path $harnessDist 'run-tests.js')", "--log", "trace", "--wait", $workspace
  ) $TimeoutSeconds "VS Code installed I6 workerCrash Extension Host probe"
}
finally { foreach ($name in $names) { Restore-Environment $name $previous[$name] } }

Assert-True (Test-Path -LiteralPath $resultPath -PathType Leaf) "Installed workerCrash harness did not write its result."
$result = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json -Depth 64
Assert-ExactProperties $result @("extensionId", "extensionVersion", "extensionPath", "report") "installed workerCrash harness result"
Assert-True ([string]$result.extensionId -ceq "hitsuki-ban.subversionr" -and [string]$result.extensionVersion -ceq $ExpectedProductVersion) "Installed workerCrash extension identity is invalid."
Assert-True (([System.IO.Path]::GetFullPath([string]$result.extensionPath)).Equals($installedRoot, [System.StringComparison]::OrdinalIgnoreCase)) "Installed workerCrash extension path is invalid."

$report = $result.report
Assert-ExactProperties $report @(
  "schema", "schemaVersion", "kind", "scenario", "settlement", "daemonState", "workerCrashSettlement",
  "protocol", "trust", "authActivity", "repositorySession", "diagnosticsRedacted", "redaction"
) "installed workerCrash product report"
Assert-True ([string]$report.schema -ceq "subversionr.release.m8-i6-installed-vsix-worker-crash.v1" -and [int]$report.schemaVersion -eq 1 -and [string]$report.kind -ceq "subversionr.installedSvnAnonymousWorkerCrashReport" -and [string]$report.scenario -ceq "workerCrash") "Installed workerCrash report identity is invalid."
Assert-ExactProperties $report.settlement @("code", "category", "messageKey", "retryable", "safeArgs", "diagnostics") "installed workerCrash settlement"
Assert-True ([string]$report.settlement.code -ceq "SUBVERSIONR_REMOTE_WORKER_CRASHED" -and [string]$report.settlement.category -ceq "process" -and [string]$report.settlement.messageKey -ceq "error.remote.workerCrashed" -and $report.settlement.retryable -eq $false -and $null -eq $report.settlement.diagnostics) "Installed workerCrash settlement is invalid."
Assert-ExactProperties $report.settlement.safeArgs @("stage", "remoteFailure") "installed workerCrash safe args"
Assert-True ([string]$report.settlement.safeArgs.stage -ceq "workerProcess") "Installed workerCrash stage is invalid."
Assert-ExactProperties $report.settlement.safeArgs.remoteFailure @("category", "reason", "cleanupAppropriate") "installed workerCrash remote failure"
Assert-True ([string]$report.settlement.safeArgs.remoteFailure.category -ceq "process" -and [string]$report.settlement.safeArgs.remoteFailure.reason -ceq "workerContainmentFailed" -and $report.settlement.safeArgs.remoteFailure.cleanupAppropriate -eq $false) "Installed workerCrash remote failure is invalid."
Assert-ExactProperties $report.daemonState @("kind", "reason", "originOperationIdMatched", "recovery", "cleanupAppropriate", "repositoryIdMatched", "epochMatched") "installed workerCrash daemon state"
Assert-True ([string]$report.daemonState.kind -ceq "indeterminate" -and [string]$report.daemonState.reason -ceq "workerTerminated" -and [string]$report.daemonState.recovery -ceq "notRequired" -and $report.daemonState.cleanupAppropriate -eq $false -and $report.daemonState.originOperationIdMatched -eq $true -and $report.daemonState.repositoryIdMatched -eq $true -and $report.daemonState.epochMatched -eq $true) "Installed workerCrash daemon state is invalid."
Assert-ExactProperties $report.workerCrashSettlement @("trigger", "terminationExitCode", "workerIdentityBound", "workerTerminationObserved", "wireSettlementObserved", "daemonSurvived", "nativeLaneReleased", "localSnapshotAfterCrash", "workingCopyPreserved") "installed workerCrash proof"
Assert-True ([string]$report.workerCrashSettlement.trigger -ceq "external-worker-termination-after-greeting" -and [int64]$report.workerCrashSettlement.terminationExitCode -eq $TerminationExitCode) "Installed workerCrash trigger is invalid."
foreach ($field in @("workerIdentityBound", "workerTerminationObserved", "wireSettlementObserved", "daemonSurvived", "nativeLaneReleased", "localSnapshotAfterCrash", "workingCopyPreserved")) { Assert-True ($report.workerCrashSettlement.$field -eq $true) "Installed workerCrash proof $field is invalid." }
Assert-ExactProperties $report.protocol @("major", "minor") "installed workerCrash protocol"
Assert-True ([int]$report.protocol.major -eq 1 -and [int]$report.protocol.minor -eq 35) "Installed workerCrash protocol is invalid."
Assert-ExactProperties $report.trust @("acknowledgedEpoch", "consistent") "installed workerCrash trust"
Assert-True ([int]$report.trust.acknowledgedEpoch -ge 1 -and $report.trust.consistent -eq $true) "Installed workerCrash trust proof is invalid."
Assert-ExactProperties $report.authActivity @("credentialRequests", "credentialSettlements", "certificateRequests") "installed workerCrash auth activity"
Assert-True ([int]$report.authActivity.credentialRequests -eq 0 -and [int]$report.authActivity.credentialSettlements -eq 0 -and [int]$report.authActivity.certificateRequests -eq 0) "Installed workerCrash produced authentication activity."
Assert-ExactProperties $report.repositorySession @("opened", "closed") "installed workerCrash repository session"
Assert-ExactProperties $report.redaction @("rawUrls", "rawPaths", "rawContent") "installed workerCrash redaction"
Assert-True ($report.repositorySession.opened -eq $true -and $report.repositorySession.closed -eq $true -and $report.diagnosticsRedacted -eq $true) "Installed workerCrash did not survive through close and redacted diagnostics."
Assert-True ($report.redaction.rawUrls -eq $false -and $report.redaction.rawPaths -eq $false -and $report.redaction.rawContent -eq $false) "Installed workerCrash redaction is invalid."

$serializedReport = $report | ConvertTo-Json -Depth 32 -Compress
Assert-True (-not $serializedReport.Contains($RepositoryUrl) -and -not $serializedReport.Contains($workingCopy) -and -not $serializedReport.Contains($fixtureStatePathResolved) -and -not $serializedReport.Contains($OperationId)) "Installed workerCrash report leaked request identity."
$temporaryRootsAfter = if (Test-Path -LiteralPath $remoteWorkersRoot) { @(Get-ChildItem -LiteralPath $remoteWorkersRoot -Force).Count } else { 0 }
Assert-True ($temporaryRootsAfter -eq 0) "Installed workerCrash left temporary roots."
Assert-EmptyCheckoutJournal $remoteStateRoot
Assert-WorkingCopyPreserved $workingCopy $contentBefore $databaseBefore
$fixtureAfter = Get-FixtureState $fixtureStatePathResolved $repositoryUri.Port
Assert-True ([int]$fixtureAfter.connections -eq 1 -and [int]$fixtureAfter.greetingSent -eq 1 -and [int]$fixtureAfter.clientResponseReceived -eq 1 -and [int]$fixtureAfter.authRequestSent -eq 0 -and [int]$fixtureAfter.reposInfoSent -eq 0 -and [int]$fixtureAfter.commandsReceived -eq 0 -and [int]$fixtureAfter.followupContacts -eq 0) "Installed workerCrash fixture did not remain at greeting barrier."

[pscustomobject]@{
  schema = "subversionr.release.m8-i6-installed-vsix-worker-crash.v1"
  status = "passed"
  surface = "installed-vsix-extension-host"
  cell = "workerCrash"
  stableCode = [string]$report.settlement.code
  reason = [string]$report.settlement.safeArgs.remoteFailure.reason
  settlement = $report.settlement
  daemonState = $report.daemonState
  workerCrashSettlement = $report.workerCrashSettlement
  protocol = $report.protocol
  trust = $report.trust
  authActivity = $report.authActivity
  diagnosticsRedacted = [bool]$report.diagnosticsRedacted
  temporaryRootsAfter = $temporaryRootsAfter
  checkoutJournalEntriesAfter = 0
  workingCopyPreserved = $true
} | ConvertTo-Json -Depth 16 -Compress

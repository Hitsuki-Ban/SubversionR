[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string]$VsixPath,
  [Parameter(Mandatory = $true)] [string]$CodeCliPath,
  [Parameter(Mandatory = $true)] [string]$FixtureRoot,
  [Parameter(Mandatory = $true)] [string]$WorkingCopyPath,
  [Parameter(Mandatory = $true)] [string]$RepositoryUrl,
  [Parameter(Mandatory = $true)] [ValidateRange(1, 300000)] [int]$OperationTimeoutMilliseconds,
  [Parameter(Mandatory = $true)] [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')] [string]$ExpectedProductVersion,
  [Parameter(Mandatory = $true)] [string]$DaemonPath,
  [Parameter(Mandatory = $true)] [string]$BridgePath,
  [Parameter(Mandatory = $true)] [ValidateRange(60, 1800)] [int]$TimeoutSeconds
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$StalledReadCommand = "subversionr.diagnostics.installedSvnAnonymousStalledReadReport"
$StalledReadTokenEnvironment = "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STALLED_READ_REPORT_TOKEN"
$JournalFileName = "subversionr-remote-checkout-mutations-v1.json"
$JournalTemporaryFileName = ".subversionr-remote-checkout-mutations-v1.tmp"

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Assert-ExactProperties([object]$Value, [string[]]$Expected, [string]$Context) {
  Assert-True ($null -ne $Value) "$Context must be present."
  $actual = @($Value.PSObject.Properties.Name | Sort-Object)
  $expectedSorted = @($Expected | Sort-Object)
  Assert-True (($actual -join ",") -ceq ($expectedSorted -join ",")) "$Context must contain exactly the required fields."
}

function Resolve-RequiredFile([string]$Path, [string]$Name) {
  Assert-True (-not [string]::IsNullOrWhiteSpace($Path)) "$Name is required."
  Assert-True ([System.IO.Path]::IsPathFullyQualified($Path)) "$Name must be an absolute path."
  $resolved = [System.IO.Path]::GetFullPath($Path)
  Assert-True (Test-Path -LiteralPath $resolved -PathType Leaf) "$Name must be an existing file: $resolved"
  return $resolved
}

function Resolve-RequiredDirectory([string]$Path, [string]$Name) {
  Assert-True (-not [string]::IsNullOrWhiteSpace($Path)) "$Name is required."
  Assert-True ([System.IO.Path]::IsPathFullyQualified($Path)) "$Name must be an absolute path."
  $resolved = [System.IO.Path]::GetFullPath($Path)
  Assert-True (Test-Path -LiteralPath $resolved -PathType Container) "$Name must be an existing directory: $resolved"
  return $resolved
}

function Resolve-NewDirectoryPath([string]$Path, [string]$Name) {
  Assert-True (-not [string]::IsNullOrWhiteSpace($Path)) "$Name is required."
  Assert-True ([System.IO.Path]::IsPathFullyQualified($Path)) "$Name must be an absolute path."
  $resolved = [System.IO.Path]::GetFullPath($Path)
  Assert-True (-not (Test-Path -LiteralPath $resolved)) "$Name must not exist before the probe: $resolved"
  Assert-True (Test-Path -LiteralPath (Split-Path -Parent $resolved) -PathType Container) "$Name parent must be an existing directory."
  return $resolved
}

function Test-PathWithin([string]$Path, [string]$Root) {
  $prefix = $Root.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  return $Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-Sha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-WorkingCopyContentSnapshot([string]$WorkingCopyRoot) {
  $metadataRoot = Join-Path $WorkingCopyRoot ".svn"
  $metadataPrefix = $metadataRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  $entries = @(Get-ChildItem -LiteralPath $WorkingCopyRoot -Recurse -File -Force | Where-Object {
      -not $_.FullName.StartsWith($metadataPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object FullName | ForEach-Object {
      [ordered]@{
        path = [System.IO.Path]::GetRelativePath($WorkingCopyRoot, $_.FullName).Replace("\", "/")
        sha256 = Get-Sha256 $_.FullName
        sizeBytes = [int64]$_.Length
      }
    })
  return (ConvertTo-Json -InputObject @($entries) -Depth 4 -Compress)
}

function Get-WorkingCopyDatabaseProof([string]$WorkingCopyRoot) {
  $path = Join-Path $WorkingCopyRoot ".svn\wc.db"
  Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "The installed stalled-read working-copy database is missing."
  $size = [int64](Get-Item -LiteralPath $path).Length
  Assert-True ($size -gt 0) "The installed stalled-read working-copy database is empty."
  return [pscustomobject]@{ sizeBytes = $size; sha256 = Get-Sha256 $path }
}

function Assert-WorkingCopyPreserved(
  [string]$WorkingCopyRoot,
  [string]$ExpectedContentSnapshot,
  [int64]$ExpectedDatabaseSize,
  [string]$ExpectedDatabaseSha256
) {
  Assert-True (Test-Path -LiteralPath $WorkingCopyRoot -PathType Container) "The installed stalled-read working copy root was removed."
  Assert-True (Test-Path -LiteralPath (Join-Path $WorkingCopyRoot ".svn") -PathType Container) "The installed stalled-read working-copy metadata root was removed."
  $actualDatabase = Get-WorkingCopyDatabaseProof $WorkingCopyRoot
  Assert-True ($actualDatabase.sizeBytes -eq $ExpectedDatabaseSize) "The installed stalled-read working-copy database size changed."
  Assert-True ($actualDatabase.sha256 -ceq $ExpectedDatabaseSha256) "The installed stalled-read working-copy database hash changed."
  Assert-True ((Get-WorkingCopyContentSnapshot $WorkingCopyRoot) -ceq $ExpectedContentSnapshot) "The installed stalled-read read-only operation changed working-copy user content."
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

function Get-ProcessEnvironmentValue([string]$Name) {
  return [System.Environment]::GetEnvironmentVariable($Name, "Process")
}

function Restore-ProcessEnvironmentValue([string]$Name, [string]$Value) {
  if ($null -eq $Value) { Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue }
  else { Set-Item -LiteralPath "Env:$Name" -Value $Value }
}

function Find-InstalledPackage([string]$ExtensionsRoot, [string]$Version) {
  $matches = @(Get-ChildItem -LiteralPath $ExtensionsRoot -Directory -Recurse -Depth 2 |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "package.json") -PathType Leaf } |
    ForEach-Object {
      $manifest = Get-Content -Raw -LiteralPath (Join-Path $_.FullName "package.json") | ConvertFrom-Json
      if ($manifest.publisher -ceq "hitsuki-ban" -and $manifest.name -ceq "subversionr" -and $manifest.version -ceq $Version) { $_.FullName }
    })
  Assert-True ($matches.Count -eq 1) "Expected exactly one installed hitsuki-ban.subversionr package."
  return [System.IO.Path]::GetFullPath($matches[0])
}

function Get-CandidateProcessCount([string]$ExecutablePath) {
  try {
    return @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([System.IO.Path]::GetFullPath([string]$_.ExecutablePath)).Equals($ExecutablePath, [System.StringComparison]::OrdinalIgnoreCase)
      }).Count
  }
  catch { throw "Installed stalled-read candidate process cleanup observation through Win32_Process failed." }
}

function Wait-CandidateProcessAbsent([string]$ExecutablePath, [int]$DeadlineMilliseconds) {
  $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($DeadlineMilliseconds)
  do {
    if ((Get-CandidateProcessCount $ExecutablePath) -eq 0) { return }
    Start-Sleep -Milliseconds 50
  } while ([DateTimeOffset]::UtcNow -lt $deadline)
  throw "The installed stalled-read candidate daemon or worker remained alive after the Extension Host exited."
}

function Get-TemporaryRootCount([string]$RemoteWorkersRoot) {
  Assert-True (Test-Path -LiteralPath $RemoteWorkersRoot -PathType Container) "The installed stalled-read remote-workers root was not created."
  return @(Get-ChildItem -LiteralPath $RemoteWorkersRoot -Force).Count
}

function Assert-EmptyCheckoutJournal([string]$RemoteStateRoot) {
  if (-not (Test-Path -LiteralPath $RemoteStateRoot)) { return }
  Assert-True (Test-Path -LiteralPath $RemoteStateRoot -PathType Container) "The installed stalled-read remote-state path was not a directory."
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $RemoteStateRoot $JournalTemporaryFileName))) "The installed stalled-read execution created a checkout journal temporary file."
  $journalPath = Join-Path $RemoteStateRoot $JournalFileName
  if (-not (Test-Path -LiteralPath $journalPath)) { return }
  $journal = Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json
  Assert-ExactProperties $journal @("schemaVersion", "entries") "installed stalled-read checkout journal"
  Assert-True ([int]$journal.schemaVersion -eq 1 -and @($journal.entries).Count -eq 0) "The installed stalled-read execution left checkout journal entries."
}

$vsixResolved = Resolve-RequiredFile $VsixPath "VsixPath"
$codeResolved = Resolve-RequiredFile $CodeCliPath "CodeCliPath"
Assert-True ((Split-Path -Leaf $codeResolved) -in @("code.cmd", "code.exe")) "CodeCliPath must point to code.cmd or code.exe."
$daemonResolved = Resolve-RequiredFile $DaemonPath "DaemonPath"
$bridgeResolved = Resolve-RequiredFile $BridgePath "BridgePath"
$fixtureResolved = Resolve-NewDirectoryPath $FixtureRoot "FixtureRoot"
$workingCopyResolved = Resolve-RequiredDirectory $WorkingCopyPath "WorkingCopyPath"
Assert-True (Test-Path -LiteralPath (Join-Path $workingCopyResolved ".svn") -PathType Container) "WorkingCopyPath must identify an existing Subversion working copy."
Assert-True (Test-Path -LiteralPath (Join-Path $workingCopyResolved ".svn\wc.db") -PathType Leaf) "WorkingCopyPath must contain an existing working-copy database."
Assert-True (-not (Test-PathWithin $workingCopyResolved $fixtureResolved)) "WorkingCopyPath must not be below FixtureRoot."
Assert-True (-not (Test-PathWithin $fixtureResolved $workingCopyResolved)) "FixtureRoot must not be below WorkingCopyPath."
Assert-True (-not $workingCopyResolved.Equals($fixtureResolved, [System.StringComparison]::OrdinalIgnoreCase)) "FixtureRoot and WorkingCopyPath must be distinct."
$workingCopyContentBefore = Get-WorkingCopyContentSnapshot $workingCopyResolved
$workingCopyDatabaseBefore = Get-WorkingCopyDatabaseProof $workingCopyResolved

try { $repositoryUri = [System.Uri]::new($RepositoryUrl, [System.UriKind]::Absolute) }
catch { throw "RepositoryUrl must be an absolute URL." }
Assert-True (
  $repositoryUri.Scheme -ceq "svn" -and $repositoryUri.Host -ceq "127.0.0.1" -and
  $repositoryUri.Port -gt 0 -and $repositoryUri.AbsolutePath.Length -gt 1
) "RepositoryUrl must use the controlled direct svn:// IPv4 loopback endpoint."
Assert-True (
  [string]::IsNullOrEmpty($repositoryUri.UserInfo) -and [string]::IsNullOrEmpty($repositoryUri.Query) -and
  [string]::IsNullOrEmpty($repositoryUri.Fragment)
) "RepositoryUrl must not include user info, query, or fragment."

New-Item -ItemType Directory -Path $fixtureResolved | Out-Null
Assert-True (@(Get-ChildItem -LiteralPath $fixtureResolved -Force).Count -eq 0) "FixtureRoot must be newly created and empty."
$userDataRoot = Join-Path $fixtureResolved "u"
$extensionsRoot = Join-Path $fixtureResolved "x"
$workspaceRoot = Join-Path $fixtureResolved "w"
$harnessRoot = Join-Path $fixtureResolved "h"
$harnessDistRoot = Join-Path $harnessRoot "d"
$resultPath = Join-Path $fixtureResolved "result.json"
$environmentRoot = Join-Path $fixtureResolved "e"
$tempRoot = Join-Path $environmentRoot "t"
$appDataRoot = Join-Path $environmentRoot "a"
$localAppDataRoot = Join-Path $environmentRoot "l"
$profileRoot = Join-Path $environmentRoot "p"
$remoteWorkersRoot = Join-Path $tempRoot "SubversionR\remote-workers"
$remoteStateRoot = Join-Path $userDataRoot "User\globalStorage\hitsuki-ban.subversionr\remote-state"
foreach ($directory in @($userDataRoot, $extensionsRoot, $workspaceRoot, $harnessDistRoot, $tempRoot, $appDataRoot, $localAppDataRoot, $profileRoot)) {
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

@'
{"name":"subversionr-m8-i6-installed-stalled-read-harness","displayName":"SubversionR M8 I6 Installed Stalled Read Harness","version":"0.0.0","publisher":"hitsuki-ban-test","private":true,"engines":{"vscode":"^1.101.0"},"main":"./d/extension.js","activationEvents":[]}
'@ | Set-Content -LiteralPath (Join-Path $harnessRoot "package.json") -Encoding utf8 -NoNewline
"exports.activate = function () {}; exports.deactivate = function () {};" |
  Set-Content -LiteralPath (Join-Path $harnessDistRoot "extension.js") -Encoding utf8 -NoNewline

@'
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const vscode = require("vscode");

const COMMAND = "subversionr.diagnostics.installedSvnAnonymousStalledReadReport";
const TOKEN_ENVIRONMENT = "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STALLED_READ_REPORT_TOKEN";

function requiredEnvironment(name) {
  const value = process.env[name];
  if (typeof value !== "string" || value.length === 0) throw new Error(`Missing required installed stalled-read environment: ${name}`);
  return value;
}

async function withDeadline(promise, label, milliseconds) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`${label} exceeded its absolute deadline.`)), milliseconds);
    })]);
  } finally { if (timer !== undefined) clearTimeout(timer); }
}

async function run() {
  const resultPath = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_STALLED_READ_RESULT");
  const extensionsRoot = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_STALLED_READ_EXTENSIONS_ROOT");
  const token = requiredEnvironment(TOKEN_ENVIRONMENT);
  const repositoryUrl = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_STALLED_READ_REPOSITORY_URL");
  const workingCopyPath = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_STALLED_READ_WORKING_COPY_PATH");
  const operationTimeoutMs = Number(requiredEnvironment("SUBVERSIONR_INSTALLED_I6_STALLED_READ_TIMEOUT_MS"));
  if (!Number.isSafeInteger(operationTimeoutMs) || operationTimeoutMs < 1 || operationTimeoutMs > 300000) {
    throw new Error("Installed stalled-read operation timeout is invalid.");
  }
  const extension = vscode.extensions.getExtension("hitsuki-ban.subversionr");
  if (!extension) throw new Error("Installed SubversionR extension was not visible.");
  if (extension.isActive) throw new Error("Installed SubversionR extension activated before the stalled-read command.");
  const normalizedExtension = path.resolve(extension.extensionPath).toLowerCase();
  const normalizedRoot = path.resolve(extensionsRoot).toLowerCase();
  if (!normalizedExtension.startsWith(normalizedRoot + path.sep)) throw new Error("SubversionR was not loaded from the isolated installed extensions root.");

  const operationId = crypto.randomUUID();
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(operationId)) {
    throw new Error("Installed stalled-read operation ID was not an externally generated canonical UUID.");
  }
  const report = await withDeadline(vscode.commands.executeCommand(COMMAND, {
    token, repositoryUrl, workingCopyPath, operationId, timeoutMs: operationTimeoutMs,
  }), "installed SVN anonymous stalled-read command", operationTimeoutMs + 30000);
  if (process.env[TOKEN_ENVIRONMENT] !== undefined) throw new Error("Installed stalled-read token was not consumed during extension activation.");
  const active = vscode.extensions.getExtension("hitsuki-ban.subversionr");
  if (!active?.isActive || active.extensionPath !== extension.extensionPath) throw new Error("Installed SubversionR extension identity changed during the stalled-read command.");
  const serialized = JSON.stringify(report).toLowerCase();
  for (const sensitive of [token, repositoryUrl, workingCopyPath, workingCopyPath.replaceAll("\\", "/"), operationId]) {
    if (serialized.includes(sensitive.toLowerCase())) throw new Error("Installed stalled-read report leaked request identity.");
  }
  fs.writeFileSync(resultPath, JSON.stringify({ extensionId: active.id, extensionVersion: active.packageJSON.version, extensionPath: active.extensionPath, report }), { encoding: "utf8", flag: "wx" });
}

exports.run = run;
'@ | Set-Content -LiteralPath (Join-Path $harnessDistRoot "run-tests.js") -Encoding utf8 -NoNewline

Invoke-Code $codeResolved @("--user-data-dir", $userDataRoot, "--extensions-dir", $extensionsRoot, "--install-extension", $vsixResolved, "--force") 180 "VS Code CLI installed stalled-read extension install"
$installed = @(& $codeResolved --user-data-dir $userDataRoot --extensions-dir $extensionsRoot --list-extensions --show-versions)
Assert-True ($LASTEXITCODE -eq 0) "VS Code CLI installed stalled-read extension listing failed."
Assert-True ($installed -contains "hitsuki-ban.subversionr@$ExpectedProductVersion") "Installed stalled-read extension version did not match ExpectedProductVersion."
$installedPackageRoot = Find-InstalledPackage $extensionsRoot $ExpectedProductVersion
$installedDaemonPath = Resolve-RequiredFile (Join-Path $installedPackageRoot "resources\backend\win32-x64\subversionr-daemon.exe") "installed candidate daemon"
$installedBridgePath = Resolve-RequiredFile (Join-Path $installedPackageRoot "resources\backend\win32-x64\subversionr_svn_bridge.dll") "installed candidate bridge"
Assert-True ((Get-Sha256 $installedDaemonPath) -ceq (Get-Sha256 $daemonResolved)) "Installed stalled-read daemon bytes did not match the candidate daemon."
Assert-True ((Get-Sha256 $installedBridgePath) -ceq (Get-Sha256 $bridgeResolved)) "Installed stalled-read bridge bytes did not match the candidate bridge."
Assert-True ((Get-CandidateProcessCount $installedDaemonPath) -eq 0) "The installed stalled-read candidate daemon or worker was already running before the Extension Host probe."

$names = @(
  "SUBVERSIONR_INSTALLED_I6_STALLED_READ_RESULT", "SUBVERSIONR_INSTALLED_I6_STALLED_READ_EXTENSIONS_ROOT", $StalledReadTokenEnvironment,
  "SUBVERSIONR_INSTALLED_I6_STALLED_READ_REPOSITORY_URL", "SUBVERSIONR_INSTALLED_I6_STALLED_READ_WORKING_COPY_PATH",
  "SUBVERSIONR_INSTALLED_I6_STALLED_READ_TIMEOUT_MS", "APPDATA", "LOCALAPPDATA", "USERPROFILE", "HOME", "TEMP", "TMP"
)
$previous = @{}
foreach ($name in $names) { $previous[$name] = Get-ProcessEnvironmentValue $name }
try {
  $env:SUBVERSIONR_INSTALLED_I6_STALLED_READ_RESULT = $resultPath
  $env:SUBVERSIONR_INSTALLED_I6_STALLED_READ_EXTENSIONS_ROOT = $extensionsRoot
  Set-Item -LiteralPath "Env:$StalledReadTokenEnvironment" -Value ([Guid]::NewGuid().ToString("N"))
  $env:SUBVERSIONR_INSTALLED_I6_STALLED_READ_REPOSITORY_URL = $RepositoryUrl
  $env:SUBVERSIONR_INSTALLED_I6_STALLED_READ_WORKING_COPY_PATH = $workingCopyResolved
  $env:SUBVERSIONR_INSTALLED_I6_STALLED_READ_TIMEOUT_MS = $OperationTimeoutMilliseconds.ToString([Globalization.CultureInfo]::InvariantCulture)
  $env:APPDATA = $appDataRoot
  $env:LOCALAPPDATA = $localAppDataRoot
  $env:USERPROFILE = $profileRoot
  $env:HOME = $profileRoot
  $env:TEMP = $tempRoot
  $env:TMP = $tempRoot
  Invoke-Code $codeResolved @(
    "--user-data-dir", $userDataRoot, "--extensions-dir", $extensionsRoot, "--disable-workspace-trust", "--new-window",
    "--extensionDevelopmentPath=$harnessRoot", "--extensionTestsPath=$(Join-Path $harnessDistRoot 'run-tests.js')", "--log", "trace", "--wait", $workspaceRoot
  ) $TimeoutSeconds "VS Code installed I6 stalled-read Extension Host probe"
}
finally { foreach ($name in $names) { Restore-ProcessEnvironmentValue $name $previous[$name] } }

Wait-CandidateProcessAbsent $installedDaemonPath 10000
Assert-True (Test-Path -LiteralPath $resultPath -PathType Leaf) "Installed stalled-read harness did not write its bounded result."
$result = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json -Depth 64
Assert-ExactProperties $result @("extensionId", "extensionVersion", "extensionPath", "report") "installed stalled-read harness result"
Assert-True ([string]$result.extensionId -ceq "hitsuki-ban.subversionr") "Installed stalled-read extension identity was invalid."
Assert-True ([string]$result.extensionVersion -ceq $ExpectedProductVersion) "Installed stalled-read extension version was invalid."
Assert-True (([System.IO.Path]::GetFullPath([string]$result.extensionPath)).Equals($installedPackageRoot, [System.StringComparison]::OrdinalIgnoreCase)) "Installed stalled-read extension path did not identify the installed VSIX package."

$report = $result.report
Assert-ExactProperties $report @(
  "schema", "schemaVersion", "kind", "scenario", "settlement", "diagnostics", "nativeLaneReleased", "localSnapshotAfterTimeout",
  "protocol", "trust", "authActivity", "repositorySession", "diagnosticsRedacted", "redaction"
) "installed stalled-read product report"
Assert-True ([string]$report.schema -ceq "subversionr.release.m8-i6-installed-svn-anonymous-stalled-read.v1") "Installed stalled-read report schema was invalid."
Assert-True ([int]$report.schemaVersion -eq 1 -and [string]$report.kind -ceq "subversionr.installedSvnAnonymousStalledReadReport" -and [string]$report.scenario -ceq "stalledMidRead") "Installed stalled-read report identity was invalid."
Assert-ExactProperties $report.settlement @("code", "category", "messageKey", "retryable", "remoteFailure") "installed stalled-read settlement"
Assert-True (
  [string]$report.settlement.code -ceq "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT" -and [string]$report.settlement.category -ceq "timeout" -and
  [string]$report.settlement.messageKey -ceq "error.remote.workerTimedOut" -and $report.settlement.retryable -eq $false
) "Installed stalled-read settlement identity was invalid."
Assert-ExactProperties $report.settlement.remoteFailure @("category", "reason", "cleanupAppropriate") "installed stalled-read remote failure"
Assert-True (
  [string]$report.settlement.remoteFailure.category -ceq "deadline" -and [string]$report.settlement.remoteFailure.reason -ceq "operationDeadlineExceeded" -and
  $report.settlement.remoteFailure.cleanupAppropriate -eq $false
) "Installed stalled-read remote failure was invalid."
Assert-True ($null -eq $report.diagnostics) "Installed stalled-read diagnostics must be null."
Assert-True ($report.nativeLaneReleased -eq $true -and $report.localSnapshotAfterTimeout -eq $true) "Installed stalled-read native-lane recovery proof was invalid."
Assert-ExactProperties $report.protocol @("major", "minor") "installed stalled-read protocol"
Assert-True ([int]$report.protocol.major -eq 1 -and [int]$report.protocol.minor -eq 35) "Installed stalled-read report protocol was invalid."
Assert-ExactProperties $report.trust @("acknowledgedEpoch", "consistent") "installed stalled-read trust"
Assert-True ($report.trust.consistent -eq $true -and [int]$report.trust.acknowledgedEpoch -ge 1) "Installed stalled-read report trust observation was invalid."
Assert-ExactProperties $report.authActivity @("credentialRequests", "credentialSettlements", "certificateRequests") "installed stalled-read authentication activity"
Assert-True ([int]$report.authActivity.credentialRequests -eq 0 -and [int]$report.authActivity.credentialSettlements -eq 0 -and [int]$report.authActivity.certificateRequests -eq 0) "Installed stalled-read anonymous execution produced authentication activity."
Assert-ExactProperties $report.repositorySession @("opened", "closed") "installed stalled-read repository session"
Assert-True ($report.repositorySession.opened -eq $true -and $report.repositorySession.closed -eq $true) "Installed stalled-read repository session did not close cleanly."
Assert-True ($report.diagnosticsRedacted -eq $true) "Installed stalled-read product report did not prove redacted execution."
Assert-ExactProperties $report.redaction @("rawUrls", "rawPaths", "rawContent") "installed stalled-read redaction"
Assert-True ($report.redaction.rawUrls -eq $false -and $report.redaction.rawPaths -eq $false -and $report.redaction.rawContent -eq $false) "Installed stalled-read report redaction contract was invalid."

$reportText = $report | ConvertTo-Json -Depth 32 -Compress
Assert-True (-not $reportText.Contains($RepositoryUrl) -and -not $reportText.Contains($workingCopyResolved)) "Installed stalled-read product report leaked fixture identity."
$temporaryRootsAfter = Get-TemporaryRootCount $remoteWorkersRoot
Assert-True ($temporaryRootsAfter -eq 0) "Installed stalled-read execution left operation temporary roots."
Assert-EmptyCheckoutJournal $remoteStateRoot
Assert-WorkingCopyPreserved $workingCopyResolved $workingCopyContentBefore $workingCopyDatabaseBefore.sizeBytes $workingCopyDatabaseBefore.sha256

[pscustomobject]@{
  schema = "subversionr.release.m8-i6-installed-vsix-stalled-read.v1"
  status = "passed"
  surface = "installed-vsix-extension-host"
  cell = "stalledMidRead"
  stableCode = [string]$report.settlement.code
  reason = [string]$report.settlement.remoteFailure.reason
  protocol = $report.protocol
  trust = $report.trust
  authActivity = $report.authActivity
  nativeLaneReleased = [bool]$report.nativeLaneReleased
  localSnapshotAfterTimeout = [bool]$report.localSnapshotAfterTimeout
  diagnosticsRedacted = [bool]$report.diagnosticsRedacted
  temporaryRootsAfter = $temporaryRootsAfter
  checkoutJournalEntriesAfter = 0
  workingCopyPreserved = $true
  candidateDaemonExitedAfter = $true
} | ConvertTo-Json -Depth 12 -Compress

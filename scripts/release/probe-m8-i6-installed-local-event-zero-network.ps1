[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string]$VsixPath,
  [Parameter(Mandatory = $true)] [string]$CodeCliPath,
  [Parameter(Mandatory = $true)] [string]$FixtureRoot,
  [Parameter(Mandatory = $true)] [string]$WorkingCopyPath,
  [Parameter(Mandatory = $true)] [string]$RelativePath,
  [Parameter(Mandatory = $true)] [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')] [string]$ExpectedProductVersion,
  [Parameter(Mandatory = $true)] [string]$DaemonPath,
  [Parameter(Mandatory = $true)] [string]$BridgePath,
  [Parameter(Mandatory = $true)] [ValidateRange(1, 300000)] [int]$ObservationTimeoutMilliseconds,
  [Parameter(Mandatory = $true)] [ValidateRange(60, 1800)] [int]$TimeoutSeconds
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ArmCommand = "subversionr.diagnostics.installedSvnAnonymousLocalEventZeroNetworkArm"
$ReportCommand = "subversionr.diagnostics.installedSvnAnonymousLocalEventZeroNetworkReport"
$TokenEnvironment = "SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_TOKEN"
$ProductReportSchema = "subversionr.release.m8-i6-installed-svn-anonymous-local-event-zero-network.v1"
$JournalFileName = "subversionr-remote-checkout-mutations-v1.json"
$JournalTemporaryFileName = ".subversionr-remote-checkout-mutations-v1.tmp"

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw $Message
  }
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
  $parent = Split-Path -Parent $resolved
  Assert-True (Test-Path -LiteralPath $parent -PathType Container) "$Name parent must be an existing directory: $parent"
  return $resolved
}

function Test-PathWithin([string]$Path, [string]$Root) {
  $rootPrefix = $Root.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  return $Path.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Resolve-WorkingCopyTarget([string]$WorkingCopyRoot, [string]$RequestedRelativePath) {
  Assert-True (-not [string]::IsNullOrWhiteSpace($RequestedRelativePath)) "RelativePath is required."
  Assert-True (-not [System.IO.Path]::IsPathFullyQualified($RequestedRelativePath)) "RelativePath must be relative to WorkingCopyPath."
  $targetPath = [System.IO.Path]::GetFullPath((Join-Path $WorkingCopyRoot $RequestedRelativePath))
  Assert-True (Test-PathWithin $targetPath $WorkingCopyRoot) "RelativePath must remain strictly within WorkingCopyPath."
  $metadataRoot = [System.IO.Path]::GetFullPath((Join-Path $WorkingCopyRoot ".svn"))
  Assert-True (-not $targetPath.Equals($metadataRoot, [System.StringComparison]::OrdinalIgnoreCase)) "RelativePath must not identify Subversion metadata."
  Assert-True (-not (Test-PathWithin $targetPath $metadataRoot)) "RelativePath must not identify Subversion metadata."
  Assert-True (Test-Path -LiteralPath $targetPath -PathType Leaf) "RelativePath must identify an existing versioned ordinary file."
  $targetItem = Get-Item -LiteralPath $targetPath
  Assert-True (($targetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) "RelativePath must identify an ordinary file, not a reparse point."
  Assert-True ($targetItem.Length -gt 0) "RelativePath must identify a non-empty versioned ordinary file."
  $canonicalRelativePath = [System.IO.Path]::GetRelativePath($WorkingCopyRoot, $targetPath).Replace("\", "/")
  Assert-True (-not $canonicalRelativePath.StartsWith("../", [System.StringComparison]::Ordinal)) "RelativePath must remain inside WorkingCopyPath."
  Assert-True (
    @($canonicalRelativePath.Split("/") | Where-Object { $_.Equals(".svn", [System.StringComparison]::OrdinalIgnoreCase) }).Count -eq 0
  ) "RelativePath must not identify Subversion metadata."
  return [pscustomobject]@{
    fullPath = $targetPath
    relativePath = $canonicalRelativePath
  }
}

function Get-Sha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-WorkingCopyFileSnapshot([string]$TargetPath) {
  $bytes = [System.IO.File]::ReadAllBytes($TargetPath)
  Assert-True ($bytes.Length -gt 0) "The local-event target must remain non-empty before observation."
  return [pscustomobject]@{
    bytes = $bytes
    length = [int64]$bytes.Length
    sha256 = Get-Sha256 $TargetPath
  }
}

function Restore-WorkingCopyFileSnapshot([string]$TargetPath, [object]$Snapshot) {
  Assert-True ($null -ne $Snapshot) "The working-copy file snapshot is required for restoration."
  [System.IO.File]::WriteAllBytes($TargetPath, [byte[]]$Snapshot.bytes)
  Assert-True ((Get-Item -LiteralPath $TargetPath).Length -eq [int64]$Snapshot.length) "The local-event target length was not restored exactly."
  Assert-True ((Get-Sha256 $TargetPath) -ceq [string]$Snapshot.sha256) "The local-event target bytes were not restored exactly."
}

function ConvertTo-ProcessArgument([string]$Value) {
  if ($Value.Length -eq 0) {
    return '""'
  }
  if ($Value -notmatch '[\s"]') {
    return $Value
  }
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
  finally {
    $process.Dispose()
  }
}

function Get-ProcessEnvironmentValue([string]$Name) {
  return [System.Environment]::GetEnvironmentVariable($Name, "Process")
}

function Restore-ProcessEnvironmentValue([string]$Name, [string]$Value) {
  if ($null -eq $Value) {
    Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue
  }
  else {
    Set-Item -LiteralPath "Env:$Name" -Value $Value
  }
}

function Find-InstalledPackage([string]$ExtensionsRoot, [string]$Version) {
  $matches = @(Get-ChildItem -LiteralPath $ExtensionsRoot -Directory -Recurse -Depth 2 |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "package.json") -PathType Leaf } |
    ForEach-Object {
      $manifest = Get-Content -Raw -LiteralPath (Join-Path $_.FullName "package.json") | ConvertFrom-Json
      if ($manifest.publisher -ceq "hitsuki-ban" -and $manifest.name -ceq "subversionr" -and $manifest.version -ceq $Version) {
        $_.FullName
      }
    })
  Assert-True ($matches.Count -eq 1) "Expected exactly one installed hitsuki-ban.subversionr package."
  return [System.IO.Path]::GetFullPath($matches[0])
}

function Get-CandidateProcessCount([string]$ExecutablePath) {
  try {
    return @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([System.IO.Path]::GetFullPath([string]$_.ExecutablePath)).Equals(
          $ExecutablePath,
          [System.StringComparison]::OrdinalIgnoreCase
        )
      }).Count
  }
  catch {
    throw "Installed local-event candidate process cleanup observation through Win32_Process failed."
  }
}

function Get-TemporaryRootCount([string]$RemoteWorkersRoot) {
  Assert-True (Test-Path -LiteralPath $RemoteWorkersRoot -PathType Container) "The installed local-event remote-workers root was not created."
  return @(Get-ChildItem -LiteralPath $RemoteWorkersRoot -Force).Count
}

function Assert-EmptyCheckoutJournal([string]$RemoteStateRoot) {
  if (-not (Test-Path -LiteralPath $RemoteStateRoot)) {
    return
  }
  Assert-True (Test-Path -LiteralPath $RemoteStateRoot -PathType Container) "The installed local-event remote-state path was not a directory."
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $RemoteStateRoot $JournalTemporaryFileName))) "The installed local-event execution created a checkout journal temporary file."
  $journalPath = Join-Path $RemoteStateRoot $JournalFileName
  if (-not (Test-Path -LiteralPath $journalPath)) {
    return
  }
  $journal = Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json
  Assert-ExactProperties $journal @("schemaVersion", "entries") "installed local-event checkout journal"
  Assert-True ([int]$journal.schemaVersion -eq 1 -and @($journal.entries).Count -eq 0) "The installed local-event execution left checkout journal entries."
}

$vsixResolved = Resolve-RequiredFile $VsixPath "VsixPath"
$codeResolved = Resolve-RequiredFile $CodeCliPath "CodeCliPath"
Assert-True ((Split-Path -Leaf $codeResolved) -in @("code.cmd", "code.exe")) "CodeCliPath must point to code.cmd or code.exe."
$daemonResolved = Resolve-RequiredFile $DaemonPath "DaemonPath"
$bridgeResolved = Resolve-RequiredFile $BridgePath "BridgePath"
$fixtureResolved = Resolve-NewDirectoryPath $FixtureRoot "FixtureRoot"
$workingCopyResolved = Resolve-RequiredDirectory $WorkingCopyPath "WorkingCopyPath"
Assert-True (-not $workingCopyResolved.Equals($fixtureResolved, [System.StringComparison]::OrdinalIgnoreCase)) "FixtureRoot and WorkingCopyPath must be distinct."
Assert-True (-not (Test-PathWithin $workingCopyResolved $fixtureResolved)) "WorkingCopyPath must not be below FixtureRoot."
Assert-True (-not (Test-PathWithin $fixtureResolved $workingCopyResolved)) "FixtureRoot must not be below WorkingCopyPath."
$wcDbPath = Join-Path $workingCopyResolved ".svn\wc.db"
Assert-True (Test-Path -LiteralPath $wcDbPath -PathType Leaf) "WorkingCopyPath must contain an existing working-copy database."
Assert-True ((Get-Item -LiteralPath $wcDbPath).Length -gt 0) "WorkingCopyPath must contain a non-empty working-copy database."
$target = Resolve-WorkingCopyTarget $workingCopyResolved $RelativePath
$targetSnapshot = Get-WorkingCopyFileSnapshot $target.fullPath

New-Item -ItemType Directory -Path $fixtureResolved | Out-Null
Assert-True (@(Get-ChildItem -LiteralPath $fixtureResolved -Force).Count -eq 0) "FixtureRoot must be newly created and empty."
$userDataRoot = Join-Path $fixtureResolved "user-data"
$extensionsRoot = Join-Path $fixtureResolved "extensions"
$workspaceRoot = Join-Path $fixtureResolved "workspace"
$harnessRoot = Join-Path $fixtureResolved "harness"
$harnessDistRoot = Join-Path $harnessRoot "dist"
$resultPath = Join-Path $fixtureResolved "installed-local-event-zero-network-result.json"
$environmentRoot = Join-Path $fixtureResolved "environment"
$tempRoot = Join-Path $environmentRoot "temp"
$appDataRoot = Join-Path $environmentRoot "appdata"
$localAppDataRoot = Join-Path $environmentRoot "localappdata"
$profileRoot = Join-Path $environmentRoot "profile"
$remoteWorkersRoot = Join-Path $tempRoot "SubversionR\remote-workers"
$remoteStateRoot = Join-Path $userDataRoot "User\globalStorage\hitsuki-ban.subversionr\remote-state"
foreach ($directory in @(
    $userDataRoot, $extensionsRoot, $workspaceRoot, $harnessDistRoot,
    $tempRoot, $appDataRoot, $localAppDataRoot, $profileRoot
  )) {
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

@'
{
  "name": "subversionr-m8-i6-installed-local-event-zero-network-harness",
  "displayName": "SubversionR M8 I6 Installed Local Event Zero Network Harness",
  "version": "0.0.0",
  "publisher": "hitsuki-ban-test",
  "private": true,
  "engines": { "vscode": "^1.101.0" },
  "main": "./dist/extension.js",
  "activationEvents": []
}
'@ | Set-Content -LiteralPath (Join-Path $harnessRoot "package.json") -Encoding utf8 -NoNewline
"exports.activate = function () {}; exports.deactivate = function () {};" |
  Set-Content -LiteralPath (Join-Path $harnessDistRoot "extension.js") -Encoding utf8 -NoNewline

@'
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const vscode = require("vscode");

const ARM_COMMAND = "subversionr.diagnostics.installedSvnAnonymousLocalEventZeroNetworkArm";
const REPORT_COMMAND = "subversionr.diagnostics.installedSvnAnonymousLocalEventZeroNetworkReport";
const WATCHER_REGISTRATION_SETTLE_MILLISECONDS = 1_000;
const TOKEN_ENVIRONMENT = "SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_TOKEN";
const REPORT_SCHEMA = "subversionr.release.m8-i6-installed-svn-anonymous-local-event-zero-network.v1";

function requiredEnvironment(name) {
  const value = process.env[name];
  if (typeof value !== "string" || value.length === 0) throw new Error(`Missing required installed local-event environment: ${name}`);
  return value;
}

function exactKeys(value, expected, context) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error(`${context} must be an object.`);
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (JSON.stringify(actual) !== JSON.stringify(wanted)) throw new Error(`${context} must contain exactly the required fields.`);
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function withDeadline(promise, label, milliseconds) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(`${label} exceeded its absolute deadline.`)), milliseconds);
      }),
    ]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

function validateIdentity(value, expectedStatus, context) {
  assert(value.schema === REPORT_SCHEMA, `${context} schema was invalid.`);
  assert(value.schemaVersion === 1, `${context} schemaVersion was invalid.`);
  assert(value.kind === "subversionr.installedSvnAnonymousLocalEventZeroNetwork", `${context} kind was invalid.`);
  assert(value.status === expectedStatus, `${context} status was invalid.`);
  assert(value.cell === "localEventZeroNetwork", `${context} cell was invalid.`);
  assert(value.surface === "installed", `${context} surface was invalid.`);
}

function validateTarget(target, relativePath, context) {
  exactKeys(target, ["path", "depth", "reason"], context);
  assert(target.path === relativePath && target.depth === "empty" && target.reason === "fileChanged", `${context} was invalid.`);
}

async function run() {
  const resultPath = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_LOCAL_EVENT_RESULT");
  const extensionsRoot = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_LOCAL_EVENT_EXTENSIONS_ROOT");
  const token = requiredEnvironment(TOKEN_ENVIRONMENT);
  const workingCopyPath = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_LOCAL_EVENT_WORKING_COPY_PATH");
  const relativePath = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_LOCAL_EVENT_RELATIVE_PATH");
  const timeoutText = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_LOCAL_EVENT_TIMEOUT_MS");
  const observationTimeoutMs = Number(timeoutText);
  assert(Number.isSafeInteger(observationTimeoutMs) && observationTimeoutMs >= 1 && observationTimeoutMs <= 300000, "Installed local-event observation timeout is invalid.");

  const extension = vscode.extensions.getExtension("hitsuki-ban.subversionr");
  if (!extension) throw new Error("Installed SubversionR extension was not visible.");
  if (extension.isActive) throw new Error("Installed SubversionR extension activated before the local-event arm command.");
  const normalizedExtension = path.resolve(extension.extensionPath).toLowerCase();
  const normalizedRoot = path.resolve(extensionsRoot).toLowerCase();
  if (!normalizedExtension.startsWith(normalizedRoot + path.sep)) throw new Error("SubversionR was not loaded from the isolated installed extensions root.");

  const targetPath = path.resolve(workingCopyPath, relativePath);
  const normalizedWorkingCopy = path.resolve(workingCopyPath).toLowerCase();
  assert(targetPath.toLowerCase().startsWith(normalizedWorkingCopy + path.sep), "Installed local-event target escaped the working copy.");
  const before = fs.readFileSync(targetPath);
  assert(before.length > 0, "Installed local-event target was empty before mutation.");

  const arm = await withDeadline(vscode.commands.executeCommand(ARM_COMMAND, {
    token,
    workingCopyPath,
    relativePath,
    timeoutMs: observationTimeoutMs,
  }), "installed SVN anonymous local-event arm command", observationTimeoutMs + 30000);
  exactKeys(arm, ["schema", "schemaVersion", "kind", "status", "cell", "surface", "target", "observationId"], "installed local-event arm response");
  validateIdentity(arm, "armed", "Installed local-event arm response");
  validateTarget(arm.target, relativePath, "installed local-event arm target");
  assert(typeof arm.observationId === "string" && arm.observationId.length > 0, "Installed local-event arm observationId was invalid.");

  // VS Code does not expose a readiness promise for a newly created FileSystemWatcher.
  // This bounded registration window is not evidence: the single target write below
  // must still produce the real watcher, coverage, and SCM projection observations.
  await new Promise((resolve) => setTimeout(resolve, WATCHER_REGISTRATION_SETTLE_MILLISECONDS));
  const nonce = `\nsubversionr-i6-local-event-${crypto.randomUUID()}\n`;
  await vscode.workspace.fs.writeFile(
    vscode.Uri.file(targetPath),
    Buffer.concat([before, Buffer.from(nonce, "utf8")]),
  );
  const after = fs.readFileSync(targetPath);
  assert(!crypto.createHash("sha256").update(before).digest().equals(crypto.createHash("sha256").update(after).digest()), "Installed local-event harness did not change the target hash.");

  const report = await withDeadline(vscode.commands.executeCommand(REPORT_COMMAND, {
    token,
    observationId: arm.observationId,
  }), "installed SVN anonymous local-event report command", observationTimeoutMs + 30000);
  if (process.env[TOKEN_ENVIRONMENT] !== undefined) throw new Error("Installed local-event token was not consumed during extension activation.");
  exactKeys(report, [
    "schema", "schemaVersion", "kind", "status", "cell", "surface", "watcherObserved",
    "watcherEventKinds", "target", "projectionObserved", "statusRefreshRequestDelta",
    "remoteStatusRequestDelta", "reconcileRequestDelta", "authActivity", "diagnosticsRedacted",
  ], "installed local-event product report");
  validateIdentity(report, "passed", "Installed local-event product report");
  validateTarget(report.target, relativePath, "installed local-event report target");
  assert(report.watcherObserved === true, "Installed local-event product report did not observe a real watcher event.");
  assert(Array.isArray(report.watcherEventKinds) && report.watcherEventKinds.length >= 1, "Installed local-event watcher event kinds were empty.");
  const allowedEventKinds = new Set(["created", "changed", "deleted"]);
  assert(report.watcherEventKinds.every((kind) => allowedEventKinds.has(kind)), "Installed local-event watcher event kinds were invalid.");
  assert(new Set(report.watcherEventKinds).size === report.watcherEventKinds.length, "Installed local-event watcher event kinds were not unique.");
  assert(report.projectionObserved === true, "Installed local-event projection was not observed.");
  assert(Number.isSafeInteger(report.statusRefreshRequestDelta) && report.statusRefreshRequestDelta >= 1, "Installed local-event status refresh delta was invalid.");
  assert(report.remoteStatusRequestDelta === 0 && report.reconcileRequestDelta === 0, "Installed local event triggered remote or reconciliation work.");
  exactKeys(report.authActivity, ["credentialRequests", "credentialSettlements", "certificateRequests"], "installed local-event authentication activity");
  assert(
    report.authActivity.credentialRequests === 0 &&
      report.authActivity.credentialSettlements === 0 &&
      report.authActivity.certificateRequests === 0,
    "Installed local event produced authentication activity.",
  );
  assert(report.diagnosticsRedacted === true, "Installed local-event diagnostics were not redacted.");

  const active = vscode.extensions.getExtension("hitsuki-ban.subversionr");
  if (!active?.isActive || active.extensionPath !== extension.extensionPath) throw new Error("Installed SubversionR extension identity changed during the local-event command sequence.");
  const serializedReport = JSON.stringify(report);
  for (const sensitive of [token, workingCopyPath, workingCopyPath.replaceAll("\\", "/"), targetPath, targetPath.replaceAll("\\", "/"), arm.observationId]) {
    if (serializedReport.toLowerCase().includes(sensitive.toLowerCase())) throw new Error("Installed local-event report leaked request identity.");
  }
  fs.writeFileSync(resultPath, JSON.stringify({
    extensionId: active.id,
    extensionVersion: active.packageJSON.version,
    extensionPath: active.extensionPath,
    report,
  }), { encoding: "utf8", flag: "wx" });
}

exports.run = run;
'@ | Set-Content -LiteralPath (Join-Path $harnessDistRoot "run-tests.js") -Encoding utf8 -NoNewline

$installedDaemonPath = $null
$environmentNames = @(
  "SUBVERSIONR_INSTALLED_I6_LOCAL_EVENT_RESULT",
  "SUBVERSIONR_INSTALLED_I6_LOCAL_EVENT_EXTENSIONS_ROOT",
  $TokenEnvironment,
  "SUBVERSIONR_INSTALLED_I6_LOCAL_EVENT_WORKING_COPY_PATH",
  "SUBVERSIONR_INSTALLED_I6_LOCAL_EVENT_RELATIVE_PATH",
  "SUBVERSIONR_INSTALLED_I6_LOCAL_EVENT_TIMEOUT_MS",
  "APPDATA", "LOCALAPPDATA", "USERPROFILE", "HOME", "TEMP", "TMP"
)
$previousEnvironment = @{}
foreach ($name in $environmentNames) {
  $previousEnvironment[$name] = Get-ProcessEnvironmentValue $name
}

try {
  Invoke-Code $codeResolved @(
    "--user-data-dir", $userDataRoot,
    "--extensions-dir", $extensionsRoot,
    "--install-extension", $vsixResolved,
    "--force"
  ) 180 "VS Code CLI installed local-event extension install"

  $installed = @(& $codeResolved --user-data-dir $userDataRoot --extensions-dir $extensionsRoot --list-extensions --show-versions)
  Assert-True ($LASTEXITCODE -eq 0) "VS Code CLI installed local-event extension listing failed."
  Assert-True ($installed -contains "hitsuki-ban.subversionr@$ExpectedProductVersion") "Installed local-event extension version did not match ExpectedProductVersion."
  $installedPackageRoot = Find-InstalledPackage $extensionsRoot $ExpectedProductVersion
  $installedDaemonPath = Resolve-RequiredFile (Join-Path $installedPackageRoot "resources\backend\win32-x64\subversionr-daemon.exe") "installed candidate daemon"
  $installedBridgePath = Resolve-RequiredFile (Join-Path $installedPackageRoot "resources\backend\win32-x64\subversionr_svn_bridge.dll") "installed candidate bridge"
  Assert-True ((Get-Sha256 $installedDaemonPath) -ceq (Get-Sha256 $daemonResolved)) "Installed local-event daemon bytes did not match the candidate daemon."
  Assert-True ((Get-Sha256 $installedBridgePath) -ceq (Get-Sha256 $bridgeResolved)) "Installed local-event bridge bytes did not match the candidate bridge."
  Assert-True ((Get-CandidateProcessCount $installedDaemonPath) -eq 0) "The installed local-event candidate daemon was already running before the Extension Host probe."

  $env:SUBVERSIONR_INSTALLED_I6_LOCAL_EVENT_RESULT = $resultPath
  $env:SUBVERSIONR_INSTALLED_I6_LOCAL_EVENT_EXTENSIONS_ROOT = $extensionsRoot
  Set-Item -LiteralPath "Env:$TokenEnvironment" -Value ([Guid]::NewGuid().ToString("N"))
  $env:SUBVERSIONR_INSTALLED_I6_LOCAL_EVENT_WORKING_COPY_PATH = $workingCopyResolved
  $env:SUBVERSIONR_INSTALLED_I6_LOCAL_EVENT_RELATIVE_PATH = $target.relativePath
  $env:SUBVERSIONR_INSTALLED_I6_LOCAL_EVENT_TIMEOUT_MS = $ObservationTimeoutMilliseconds.ToString([Globalization.CultureInfo]::InvariantCulture)
  $env:APPDATA = $appDataRoot
  $env:LOCALAPPDATA = $localAppDataRoot
  $env:USERPROFILE = $profileRoot
  $env:HOME = $profileRoot
  $env:TEMP = $tempRoot
  $env:TMP = $tempRoot
  Invoke-Code $codeResolved @(
    "--user-data-dir", $userDataRoot,
    "--extensions-dir", $extensionsRoot,
    "--disable-workspace-trust",
    "--new-window",
    "--extensionDevelopmentPath=$harnessRoot",
    "--extensionTestsPath=$(Join-Path $harnessDistRoot 'run-tests.js')",
    "--log", "trace",
    "--wait",
    $workspaceRoot
  ) $TimeoutSeconds "VS Code installed I6 local-event zero-network Extension Host probe"
}
finally {
  foreach ($name in $environmentNames) {
    Restore-ProcessEnvironmentValue $name $previousEnvironment[$name]
  }
  Restore-WorkingCopyFileSnapshot $target.fullPath $targetSnapshot
  if ($null -ne $installedDaemonPath) {
    Assert-True ((Get-CandidateProcessCount $installedDaemonPath) -eq 0) "The installed local-event candidate daemon remained alive after the Extension Host exited."
  }
}

Assert-True ($null -ne $installedDaemonPath) "Installed local-event candidate daemon identity was not resolved."
Assert-True ((Get-CandidateProcessCount $installedDaemonPath) -eq 0) "The installed local-event candidate daemon remained alive after the Extension Host exited."
Assert-True (Test-Path -LiteralPath $resultPath -PathType Leaf) "Installed local-event harness did not write its bounded result."
$result = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json -Depth 64
Assert-ExactProperties $result @("extensionId", "extensionVersion", "extensionPath", "report") "installed local-event harness result"
Assert-True ([string]$result.extensionId -ceq "hitsuki-ban.subversionr") "Installed local-event extension identity was invalid."
Assert-True ([string]$result.extensionVersion -ceq $ExpectedProductVersion) "Installed local-event extension version was invalid."
$installedPackageRoot = Find-InstalledPackage $extensionsRoot $ExpectedProductVersion
Assert-True (([System.IO.Path]::GetFullPath([string]$result.extensionPath)).Equals($installedPackageRoot, [System.StringComparison]::OrdinalIgnoreCase)) "Installed local-event extension path did not identify the installed VSIX package."

$report = $result.report
Assert-ExactProperties $report @(
  "schema", "schemaVersion", "kind", "status", "cell", "surface", "watcherObserved",
  "watcherEventKinds", "target", "projectionObserved", "statusRefreshRequestDelta",
  "remoteStatusRequestDelta", "reconcileRequestDelta", "authActivity", "diagnosticsRedacted"
) "installed local-event product report"
Assert-True ([string]$report.schema -ceq $ProductReportSchema) "Installed local-event report schema was invalid."
Assert-True ([int]$report.schemaVersion -eq 1) "Installed local-event report schemaVersion was invalid."
Assert-True ([string]$report.kind -ceq "subversionr.installedSvnAnonymousLocalEventZeroNetwork") "Installed local-event report kind was invalid."
Assert-True ([string]$report.status -ceq "passed" -and [string]$report.cell -ceq "localEventZeroNetwork" -and [string]$report.surface -ceq "installed") "Installed local-event report identity was invalid."
Assert-True ($report.watcherObserved -eq $true) "Installed local-event report did not prove a real watcher event."
$watcherEventKinds = @($report.watcherEventKinds)
Assert-True ($watcherEventKinds.Count -ge 1) "Installed local-event report did not name an observed watcher event kind."
Assert-True (@($watcherEventKinds | Where-Object { [string]$_ -notin @("created", "changed", "deleted") }).Count -eq 0) "Installed local-event report contained an invalid watcher event kind."
Assert-True (@($watcherEventKinds | Sort-Object -Unique).Count -eq $watcherEventKinds.Count) "Installed local-event watcher event kinds must be unique."
Assert-ExactProperties $report.target @("path", "depth", "reason") "installed local-event target"
Assert-True ([string]$report.target.path -ceq $target.relativePath -and [string]$report.target.depth -ceq "empty" -and [string]$report.target.reason -ceq "fileChanged") "Installed local-event target was invalid."
Assert-True ($report.projectionObserved -eq $true) "Installed local-event report did not prove the modified SCM projection."
Assert-True ([int64]$report.statusRefreshRequestDelta -ge 1) "Installed local-event status refresh delta was invalid."
Assert-True ([int64]$report.remoteStatusRequestDelta -eq 0) "Installed local event triggered a remote status request."
Assert-True ([int64]$report.reconcileRequestDelta -eq 0) "Installed local event triggered a reconciliation request."
Assert-ExactProperties $report.authActivity @("credentialRequests", "credentialSettlements", "certificateRequests") "installed local-event authentication activity"
Assert-True (
  [int64]$report.authActivity.credentialRequests -eq 0 -and
  [int64]$report.authActivity.credentialSettlements -eq 0 -and
  [int64]$report.authActivity.certificateRequests -eq 0
) "Installed local event produced authentication activity."
Assert-True ($report.diagnosticsRedacted -eq $true) "Installed local-event diagnostics were not redacted."

$reportText = $report | ConvertTo-Json -Depth 16 -Compress
Assert-True (-not $reportText.Contains($workingCopyResolved) -and -not $reportText.Contains($target.fullPath)) "Installed local-event product report leaked an absolute fixture path."
$temporaryRootsAfter = Get-TemporaryRootCount $remoteWorkersRoot
Assert-True ($temporaryRootsAfter -eq 0) "Installed local-event execution left operation temporary roots."
Assert-EmptyCheckoutJournal $remoteStateRoot
Assert-True (Test-Path -LiteralPath $wcDbPath -PathType Leaf) "Installed local-event execution removed the working-copy database."
Assert-True ((Get-Item -LiteralPath $wcDbPath).Length -gt 0) "Installed local-event execution emptied the working-copy database."
Assert-True ((Get-Item -LiteralPath $target.fullPath).Length -eq $targetSnapshot.length) "Installed local-event target length was not preserved after restoration."
Assert-True ((Get-Sha256 $target.fullPath) -ceq $targetSnapshot.sha256) "Installed local-event target bytes were not preserved after restoration."

[pscustomobject]@{
  schema = "subversionr.release.m8-i6-installed-vsix-local-event-zero-network.v1"
  status = "passed"
  surface = "installed-vsix-extension-host"
  cell = "localEventZeroNetwork"
  watcherObserved = [bool]$report.watcherObserved
  target = $report.target
  statusRefreshRequestDelta = [int64]$report.statusRefreshRequestDelta
  remoteStatusRequestDelta = [int64]$report.remoteStatusRequestDelta
  reconcileRequestDelta = [int64]$report.reconcileRequestDelta
  projectionObserved = [bool]$report.projectionObserved
  credentialRequests = [int64]$report.authActivity.credentialRequests
  credentialSettlements = [int64]$report.authActivity.credentialSettlements
  certificateRequests = [int64]$report.authActivity.certificateRequests
  diagnosticsRedacted = [bool]$report.diagnosticsRedacted
  temporaryRootsAfter = $temporaryRootsAfter
  candidateDaemonExitedAfter = $true
} | ConvertTo-Json -Depth 8 -Compress

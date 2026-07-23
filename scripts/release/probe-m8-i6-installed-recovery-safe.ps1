[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string]$VsixPath,
  [Parameter(Mandatory = $true)] [string]$CodeCliPath,
  [Parameter(Mandatory = $true)] [string]$FixtureRoot,
  [Parameter(Mandatory = $true)] [string]$WorkingCopyPath,
  [Parameter(Mandatory = $true)] [string]$RepositoryUrl,
  [Parameter(Mandatory = $true)] [string]$FixtureStatePath,
  [Parameter(Mandatory = $true)] [ValidatePattern('^(?!00000000-0000-0000-0000-000000000000$)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')] [string]$OperationId,
  [Parameter(Mandatory = $true)] [ValidateSet(500)] [int]$OperationTimeoutMilliseconds,
  [Parameter(Mandatory = $true)] [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')] [string]$ExpectedProductVersion,
  [Parameter(Mandatory = $true)] [string]$DaemonPath,
  [Parameter(Mandatory = $true)] [string]$BridgePath,
  [Parameter(Mandatory = $true)] [ValidateRange(60, 1800)] [int]$TimeoutSeconds
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RecoverySafeCommand = "subversionr.diagnostics.installedSvnAnonymousRecoverySafeReport"
$RecoverySafeTokenEnvironment = "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_SAFE_REPORT_TOKEN"
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
  $entries = @(Get-ChildItem -LiteralPath $WorkingCopyRoot -Recurse -Force | Where-Object {
      -not $_.FullName.Equals($metadataRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
      -not $_.FullName.StartsWith($metadataPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object FullName | ForEach-Object {
      $relativePath = [System.IO.Path]::GetRelativePath($WorkingCopyRoot, $_.FullName).Replace("\", "/")
      if ($_.PSIsContainer) {
        [ordered]@{ kind = "directory"; path = $relativePath }
      }
      else {
        [ordered]@{
          kind = "file"
          path = $relativePath
          sha256 = Get-Sha256 $_.FullName
          sizeBytes = [int64]$_.Length
        }
      }
    })
  return (ConvertTo-Json -InputObject @($entries) -Depth 4 -Compress)
}

function Get-WorkingCopyDatabaseProof([string]$WorkingCopyRoot) {
  $path = Join-Path $WorkingCopyRoot ".svn\wc.db"
  Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "The installed recovery-safe working-copy database is missing."
  $size = [int64](Get-Item -LiteralPath $path).Length
  Assert-True ($size -gt 0) "The installed recovery-safe working-copy database is empty."
  return [pscustomobject]@{ sizeBytes = $size; sha256 = Get-Sha256 $path }
}

function Assert-WorkingCopyContentPreserved([string]$WorkingCopyRoot, [string]$ExpectedContentSnapshot) {
  Assert-True (Test-Path -LiteralPath $WorkingCopyRoot -PathType Container) "The installed recovery-safe working copy root was removed."
  Assert-True (Test-Path -LiteralPath (Join-Path $WorkingCopyRoot ".svn\wc.db") -PathType Leaf) "The installed recovery-safe working-copy database is missing."
  Assert-True ((Get-WorkingCopyContentSnapshot $WorkingCopyRoot) -ceq $ExpectedContentSnapshot) "The installed recovery-safe flow changed working-copy user content."
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
  catch { throw "Installed recovery-safe candidate process cleanup observation through Win32_Process failed." }
}

function Wait-CandidateProcessAbsent([string]$ExecutablePath, [int]$DeadlineMilliseconds) {
  $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($DeadlineMilliseconds)
  do {
    if ((Get-CandidateProcessCount $ExecutablePath) -eq 0) { return }
    Start-Sleep -Milliseconds 50
  } while ([DateTimeOffset]::UtcNow -lt $deadline)
  throw "The installed recovery-safe candidate daemon or worker remained alive after the Extension Host exited."
}

function Get-TemporaryRootCount([string]$RemoteWorkersRoot) {
  Assert-True (Test-Path -LiteralPath $RemoteWorkersRoot -PathType Container) "The installed recovery-safe remote-workers root was not created."
  return @(Get-ChildItem -LiteralPath $RemoteWorkersRoot -Force).Count
}

function Assert-EmptyCheckoutJournal([string]$RemoteStateRoot) {
  if (-not (Test-Path -LiteralPath $RemoteStateRoot)) { return }
  Assert-True (Test-Path -LiteralPath $RemoteStateRoot -PathType Container) "The installed recovery-safe remote-state path was not a directory."
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $RemoteStateRoot $JournalTemporaryFileName))) "The installed recovery-safe execution created a checkout journal temporary file."
  $journalPath = Join-Path $RemoteStateRoot $JournalFileName
  if (-not (Test-Path -LiteralPath $journalPath)) { return }
  $journal = Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json
  Assert-ExactProperties $journal @("schemaVersion", "entries") "installed recovery-safe checkout journal"
  Assert-True ([int]$journal.schemaVersion -eq 1 -and @($journal.entries).Count -eq 0) "The installed recovery-safe execution left checkout journal entries."
}

$vsixResolved = Resolve-RequiredFile $VsixPath "VsixPath"
$codeResolved = Resolve-RequiredFile $CodeCliPath "CodeCliPath"
Assert-True ((Split-Path -Leaf $codeResolved) -in @("code.cmd", "code.exe")) "CodeCliPath must point to code.cmd or code.exe."
$daemonResolved = Resolve-RequiredFile $DaemonPath "DaemonPath"
$bridgeResolved = Resolve-RequiredFile $BridgePath "BridgePath"
$fixtureStateResolved = Resolve-RequiredFile $FixtureStatePath "FixtureStatePath"
$fixtureResolved = Resolve-NewDirectoryPath $FixtureRoot "FixtureRoot"
$workingCopyResolved = Resolve-RequiredDirectory $WorkingCopyPath "WorkingCopyPath"
Assert-True (Test-Path -LiteralPath (Join-Path $workingCopyResolved ".svn") -PathType Container) "WorkingCopyPath must identify an existing Subversion working copy."
Assert-True (Test-Path -LiteralPath (Join-Path $workingCopyResolved ".svn\wc.db") -PathType Leaf) "WorkingCopyPath must contain an existing working-copy database."
Assert-True (-not (Test-PathWithin $workingCopyResolved $fixtureResolved)) "WorkingCopyPath must not be below FixtureRoot."
Assert-True (-not (Test-PathWithin $fixtureResolved $workingCopyResolved)) "FixtureRoot must not be below WorkingCopyPath."
Assert-True (-not $workingCopyResolved.Equals($fixtureResolved, [System.StringComparison]::OrdinalIgnoreCase)) "FixtureRoot and WorkingCopyPath must be distinct."
Assert-True (-not (Test-PathWithin $fixtureStateResolved $fixtureResolved)) "FixtureStatePath must not be below FixtureRoot."
$workingCopyContentBefore = Get-WorkingCopyContentSnapshot $workingCopyResolved

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
{"name":"subversionr-m8-i6-installed-recovery-safe-harness","displayName":"SubversionR M8 I6 Installed Recovery Safe Harness","version":"0.0.0","publisher":"hitsuki-ban-test","private":true,"engines":{"vscode":"^1.101.0"},"main":"./d/extension.js","activationEvents":[]}
'@ | Set-Content -LiteralPath (Join-Path $harnessRoot "package.json") -Encoding utf8 -NoNewline
"exports.activate = function () {}; exports.deactivate = function () {};" |
  Set-Content -LiteralPath (Join-Path $harnessDistRoot "extension.js") -Encoding utf8 -NoNewline

@'
const fs = require("node:fs");
const path = require("node:path");
const vscode = require("vscode");

const COMMAND = "subversionr.diagnostics.installedSvnAnonymousRecoverySafeReport";
const TOKEN_ENVIRONMENT = "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_SAFE_REPORT_TOKEN";

function requiredEnvironment(name) {
  const value = process.env[name];
  if (typeof value !== "string" || value.length === 0) throw new Error(`Missing required installed recovery-safe environment: ${name}`);
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
  const resultPath = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_RECOVERY_SAFE_RESULT");
  const extensionsRoot = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_RECOVERY_SAFE_EXTENSIONS_ROOT");
  const token = requiredEnvironment(TOKEN_ENVIRONMENT);
  const repositoryUrl = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_RECOVERY_SAFE_REPOSITORY_URL");
  const workingCopyPath = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_RECOVERY_SAFE_WORKING_COPY_PATH");
  const fixtureStatePath = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_RECOVERY_SAFE_FIXTURE_STATE_PATH");
  const operationId = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_RECOVERY_SAFE_OPERATION_ID");
  if (!/^(?!00000000-0000-0000-0000-000000000000$)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(operationId)) {
    throw new Error("Installed recovery-safe operation ID must be an externally supplied canonical UUID.");
  }
  const operationTimeoutMs = Number(requiredEnvironment("SUBVERSIONR_INSTALLED_I6_RECOVERY_SAFE_TIMEOUT_MS"));
  if (operationTimeoutMs !== 500) {
    throw new Error("Installed recovery-safe operation timeout is invalid.");
  }
  const extension = vscode.extensions.getExtension("hitsuki-ban.subversionr");
  if (!extension) throw new Error("Installed SubversionR extension was not visible.");
  if (extension.isActive) throw new Error("Installed SubversionR extension activated before the recovery-safe command.");
  const normalizedExtension = path.resolve(extension.extensionPath).toLowerCase();
  const normalizedRoot = path.resolve(extensionsRoot).toLowerCase();
  if (!normalizedExtension.startsWith(normalizedRoot + path.sep)) throw new Error("SubversionR was not loaded from the isolated installed extensions root.");

  const report = await withDeadline(vscode.commands.executeCommand(COMMAND, {
    token, repositoryUrl, workingCopyPath, fixtureStatePath, operationId, timeoutMs: operationTimeoutMs,
  }), "installed SVN anonymous recovery-safe command", operationTimeoutMs + 60000);
  if (process.env[TOKEN_ENVIRONMENT] !== undefined) throw new Error("Installed recovery-safe token was not consumed during extension activation.");
  const active = vscode.extensions.getExtension("hitsuki-ban.subversionr");
  if (!active?.isActive || active.extensionPath !== extension.extensionPath) throw new Error("Installed SubversionR extension identity changed during the recovery-safe command.");
  const serialized = JSON.stringify(report).toLowerCase();
  for (const sensitive of [token, repositoryUrl, workingCopyPath, workingCopyPath.replaceAll("\\", "/"), fixtureStatePath, fixtureStatePath.replaceAll("\\", "/"), operationId]) {
    if (serialized.includes(sensitive.toLowerCase())) throw new Error("Installed recovery-safe report leaked request identity.");
  }
  fs.writeFileSync(resultPath, JSON.stringify({ extensionId: active.id, extensionVersion: active.packageJSON.version, extensionPath: active.extensionPath, report }), { encoding: "utf8", flag: "wx" });
}

exports.run = run;
'@ | Set-Content -LiteralPath (Join-Path $harnessDistRoot "run-tests.js") -Encoding utf8 -NoNewline

Invoke-Code $codeResolved @("--user-data-dir", $userDataRoot, "--extensions-dir", $extensionsRoot, "--install-extension", $vsixResolved, "--force") 180 "VS Code CLI installed recovery-safe extension install"
$installed = @(& $codeResolved --user-data-dir $userDataRoot --extensions-dir $extensionsRoot --list-extensions --show-versions)
Assert-True ($LASTEXITCODE -eq 0) "VS Code CLI installed recovery-safe extension listing failed."
Assert-True ($installed -contains "hitsuki-ban.subversionr@$ExpectedProductVersion") "Installed recovery-safe extension version did not match ExpectedProductVersion."
$installedPackageRoot = Find-InstalledPackage $extensionsRoot $ExpectedProductVersion
$installedDaemonPath = Resolve-RequiredFile (Join-Path $installedPackageRoot "resources\backend\win32-x64\subversionr-daemon.exe") "installed candidate daemon"
$installedBridgePath = Resolve-RequiredFile (Join-Path $installedPackageRoot "resources\backend\win32-x64\subversionr_svn_bridge.dll") "installed candidate bridge"
Assert-True ((Get-Sha256 $installedDaemonPath) -ceq (Get-Sha256 $daemonResolved)) "Installed recovery-safe daemon bytes did not match the candidate daemon."
Assert-True ((Get-Sha256 $installedBridgePath) -ceq (Get-Sha256 $bridgeResolved)) "Installed recovery-safe bridge bytes did not match the candidate bridge."
Assert-True ((Get-CandidateProcessCount $installedDaemonPath) -eq 0) "The installed recovery-safe candidate daemon or worker was already running before the Extension Host probe."

$names = @(
  "SUBVERSIONR_INSTALLED_I6_RECOVERY_SAFE_RESULT", "SUBVERSIONR_INSTALLED_I6_RECOVERY_SAFE_EXTENSIONS_ROOT", $RecoverySafeTokenEnvironment,
  "SUBVERSIONR_INSTALLED_I6_RECOVERY_SAFE_REPOSITORY_URL", "SUBVERSIONR_INSTALLED_I6_RECOVERY_SAFE_WORKING_COPY_PATH",
  "SUBVERSIONR_INSTALLED_I6_RECOVERY_SAFE_FIXTURE_STATE_PATH", "SUBVERSIONR_INSTALLED_I6_RECOVERY_SAFE_OPERATION_ID",
  "SUBVERSIONR_INSTALLED_I6_RECOVERY_SAFE_TIMEOUT_MS", "APPDATA", "LOCALAPPDATA", "USERPROFILE", "HOME", "TEMP", "TMP"
)
$previous = @{}
foreach ($name in $names) { $previous[$name] = Get-ProcessEnvironmentValue $name }
try {
  $env:SUBVERSIONR_INSTALLED_I6_RECOVERY_SAFE_RESULT = $resultPath
  $env:SUBVERSIONR_INSTALLED_I6_RECOVERY_SAFE_EXTENSIONS_ROOT = $extensionsRoot
  Set-Item -LiteralPath "Env:$RecoverySafeTokenEnvironment" -Value ([Guid]::NewGuid().ToString("N"))
  $env:SUBVERSIONR_INSTALLED_I6_RECOVERY_SAFE_REPOSITORY_URL = $RepositoryUrl
  $env:SUBVERSIONR_INSTALLED_I6_RECOVERY_SAFE_WORKING_COPY_PATH = $workingCopyResolved
  $env:SUBVERSIONR_INSTALLED_I6_RECOVERY_SAFE_FIXTURE_STATE_PATH = $fixtureStateResolved
  $env:SUBVERSIONR_INSTALLED_I6_RECOVERY_SAFE_OPERATION_ID = $OperationId
  $env:SUBVERSIONR_INSTALLED_I6_RECOVERY_SAFE_TIMEOUT_MS = $OperationTimeoutMilliseconds.ToString([Globalization.CultureInfo]::InvariantCulture)
  $env:APPDATA = $appDataRoot
  $env:LOCALAPPDATA = $localAppDataRoot
  $env:USERPROFILE = $profileRoot
  $env:HOME = $profileRoot
  $env:TEMP = $tempRoot
  $env:TMP = $tempRoot
  Invoke-Code $codeResolved @(
    "--user-data-dir", $userDataRoot, "--extensions-dir", $extensionsRoot, "--disable-workspace-trust", "--new-window",
    "--extensionDevelopmentPath=$harnessRoot", "--extensionTestsPath=$(Join-Path $harnessDistRoot 'run-tests.js')", "--log", "trace", "--wait", $workspaceRoot
  ) $TimeoutSeconds "VS Code installed I6 recovery-safe Extension Host probe"
}
finally { foreach ($name in $names) { Restore-ProcessEnvironmentValue $name $previous[$name] } }

Wait-CandidateProcessAbsent $installedDaemonPath 10000
Assert-True (Test-Path -LiteralPath $resultPath -PathType Leaf) "Installed recovery-safe harness did not write its bounded result."
$result = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json -Depth 64
Assert-ExactProperties $result @("extensionId", "extensionVersion", "extensionPath", "report") "installed recovery-safe harness result"
Assert-True ([string]$result.extensionId -ceq "hitsuki-ban.subversionr") "Installed recovery-safe extension identity was invalid."
Assert-True ([string]$result.extensionVersion -ceq $ExpectedProductVersion) "Installed recovery-safe extension version was invalid."
Assert-True (([System.IO.Path]::GetFullPath([string]$result.extensionPath)).Equals($installedPackageRoot, [System.StringComparison]::OrdinalIgnoreCase)) "Installed recovery-safe extension path did not identify the installed VSIX package."

$report = $result.report
Assert-ExactProperties $report @(
  "schema", "schemaVersion", "kind", "status", "cell", "surface", "prerequisite", "transitions", "statusStaleReason",
  "fixtureCountersUnchangedAfterPrerequisite", "safe", "protocol", "trust", "authActivity", "repositorySession", "diagnosticsRedacted", "redaction"
) "installed recovery-safe product report"
Assert-True (
  [string]$report.schema -ceq "subversionr.release.m8-i6-installed-vsix-recovery-safe.v1" -and
  [int]$report.schemaVersion -eq 1 -and [string]$report.kind -ceq "subversionr.installedSvnAnonymousRecoverySafeReport" -and
  [string]$report.status -ceq "passed" -and [string]$report.cell -ceq "recoverySafe" -and
  [string]$report.surface -ceq "installed-vsix-extension-host"
) "Installed recovery-safe report identity was invalid."
Assert-ExactProperties $report.prerequisite @("code", "reason", "recovery") "installed recovery-safe prerequisite"
Assert-True (
  [string]$report.prerequisite.code -ceq "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT" -and
  [string]$report.prerequisite.reason -ceq "operationDeadlineExceeded" -and
  [string]$report.prerequisite.recovery -ceq "pending"
) "Installed recovery-safe prerequisite was invalid."
Assert-True ((@($report.transitions) -join ",") -ceq "required,checking,safe") "Installed recovery-safe store transitions were invalid."
Assert-True ([string]$report.statusStaleReason -ceq "remoteRecoverySafeRequiresFullReconcile") "Installed recovery-safe stale reason was invalid."
Assert-True ($report.fixtureCountersUnchangedAfterPrerequisite -eq $true) "Installed recovery-safe fixture counters changed after the prerequisite."
Assert-ExactProperties $report.safe @("outcome", "freshReconcile", "nativeLaneReleased", "subsequentRequestPassed") "installed recovery-safe settlement"
Assert-True (
  [string]$report.safe.outcome -ceq "Safe" -and $report.safe.freshReconcile -eq $true -and
  $report.safe.nativeLaneReleased -eq $true -and $report.safe.subsequentRequestPassed -eq $true
) "Installed recovery-safe settlement proof was invalid."
Assert-ExactProperties $report.protocol @("major", "minor") "installed recovery-safe protocol"
Assert-True ([int]$report.protocol.major -eq 1 -and [int]$report.protocol.minor -eq 35) "Installed recovery-safe protocol was invalid."
Assert-ExactProperties $report.trust @("acknowledgedEpoch", "consistent") "installed recovery-safe trust"
Assert-True ($report.trust.consistent -eq $true -and [int]$report.trust.acknowledgedEpoch -ge 1) "Installed recovery-safe trust was invalid."
Assert-ExactProperties $report.authActivity @("credentialRequests", "credentialSettlements", "certificateRequests") "installed recovery-safe authentication activity"
Assert-True ([int]$report.authActivity.credentialRequests -eq 0 -and [int]$report.authActivity.credentialSettlements -eq 0 -and [int]$report.authActivity.certificateRequests -eq 0) "Installed recovery-safe anonymous execution produced authentication activity."
Assert-ExactProperties $report.repositorySession @("opened", "closed") "installed recovery-safe repository session"
Assert-True ($report.repositorySession.opened -eq $true -and $report.repositorySession.closed -eq $true) "Installed recovery-safe repository session did not close cleanly."
Assert-True ($report.diagnosticsRedacted -eq $true) "Installed recovery-safe report did not prove redacted diagnostics."
Assert-ExactProperties $report.redaction @("rawUrls", "rawPaths", "rawContent") "installed recovery-safe redaction"
Assert-True ($report.redaction.rawUrls -eq $false -and $report.redaction.rawPaths -eq $false -and $report.redaction.rawContent -eq $false) "Installed recovery-safe redaction contract was invalid."

$reportText = $report | ConvertTo-Json -Depth 32 -Compress
Assert-True (-not $reportText.Contains($RepositoryUrl) -and -not $reportText.Contains($workingCopyResolved) -and -not $reportText.Contains($fixtureStateResolved)) "Installed recovery-safe product report leaked fixture identity."
$temporaryRootsAfter = Get-TemporaryRootCount $remoteWorkersRoot
Assert-True ($temporaryRootsAfter -eq 0) "Installed recovery-safe execution left operation temporary roots."
Assert-EmptyCheckoutJournal $remoteStateRoot
Assert-WorkingCopyContentPreserved $workingCopyResolved $workingCopyContentBefore
$workingCopyDatabaseAfter = Get-WorkingCopyDatabaseProof $workingCopyResolved
$wrapper = [ordered]@{
  schema = "subversionr.release.m8-i6-installed-vsix-recovery-safe-wrapper.v1"
  status = "passed"
  surface = "installed-vsix-extension-host"
  cell = "recoverySafe"
  prerequisite = $report.prerequisite
  safe = $report.safe
  transitions = @($report.transitions)
  statusStaleReason = [string]$report.statusStaleReason
  protocol = $report.protocol
  trust = $report.trust
  authActivity = $report.authActivity
  diagnosticsRedacted = [bool]$report.diagnosticsRedacted
  temporaryRootsAfter = $temporaryRootsAfter
  checkoutJournalEntriesAfter = 0
  workingCopyContentPreserved = $true
  workingCopyDatabaseBytes = [int64]$workingCopyDatabaseAfter.sizeBytes
  candidateDaemonExitedAfter = $true
  extensionInstalledAfterCleanup = $false
  fixtureRemovedAfterCleanup = $true
}

Invoke-Code $codeResolved @("--user-data-dir", $userDataRoot, "--extensions-dir", $extensionsRoot, "--uninstall-extension", "hitsuki-ban.subversionr") 180 "VS Code CLI installed recovery-safe extension uninstall"
$remaining = @(& $codeResolved --user-data-dir $userDataRoot --extensions-dir $extensionsRoot --list-extensions --show-versions)
Assert-True ($LASTEXITCODE -eq 0 -and @($remaining | Where-Object { $_ -like "hitsuki-ban.subversionr@*" }).Count -eq 0) "Installed recovery-safe extension remained installed after cleanup."
Remove-Item -LiteralPath $fixtureResolved -Recurse -Force
Assert-True (-not (Test-Path -LiteralPath $fixtureResolved)) "Installed recovery-safe fixture cleanup did not complete."
Assert-WorkingCopyContentPreserved $workingCopyResolved $workingCopyContentBefore
Assert-True ((Get-WorkingCopyDatabaseProof $workingCopyResolved).sizeBytes -eq $workingCopyDatabaseAfter.sizeBytes) "Installed recovery-safe cleanup changed the working-copy database size."
$wrapper | ConvertTo-Json -Depth 12 -Compress

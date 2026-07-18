[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string]$VsixPath,
  [Parameter(Mandatory = $true)] [string]$CodeCliPath,
  [Parameter(Mandatory = $true)] [string]$FixtureRoot,
  [Parameter(Mandatory = $true)] [string]$RepositoryUrl,
  [Parameter(Mandatory = $true)] [string]$CheckoutPath,
  [Parameter(Mandatory = $true)] [ValidateSet("maliciousRoot", "saslOnly")] [string]$Scenario,
  [Parameter(Mandatory = $true)] [ValidateRange(1, 300000)] [int]$OperationTimeoutMilliseconds,
  [Parameter(Mandatory = $true)] [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')] [string]$ExpectedProductVersion,
  [Parameter(Mandatory = $true)] [string]$DaemonPath,
  [Parameter(Mandatory = $true)] [string]$BridgePath,
  [ValidateRange(60, 1800)] [int]$TimeoutSeconds = 600
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$NegativeCommand = "subversionr.diagnostics.installedSvnAnonymousNegativeReport"
$NegativeTokenEnvironment = "SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_NEGATIVE_REPORT_TOKEN"
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

function Resolve-GeneratedPath([string]$Path, [string]$Name) {
  Assert-True (-not [string]::IsNullOrWhiteSpace($Path)) "$Name is required."
  Assert-True ([System.IO.Path]::IsPathFullyQualified($Path)) "$Name must be an absolute path."
  return [System.IO.Path]::GetFullPath($Path)
}

function Test-PathWithin([string]$Path, [string]$Root) {
  $rootPrefix = $Root.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  return $Path.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-Sha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
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
    throw "Installed negative candidate process observation through Win32_Process failed."
  }
}

function Wait-CandidateProcessAbsent([string]$ExecutablePath, [int]$DeadlineMilliseconds) {
  $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($DeadlineMilliseconds)
  do {
    if ((Get-CandidateProcessCount $ExecutablePath) -eq 0) {
      return
    }
    Start-Sleep -Milliseconds 50
  } while ([DateTimeOffset]::UtcNow -lt $deadline)
  throw "The installed negative candidate daemon or worker remained alive after the Extension Host exited."
}

function Get-TemporaryRootCount([string]$RemoteWorkersRoot) {
  Assert-True (Test-Path -LiteralPath $RemoteWorkersRoot -PathType Container) "The installed negative remote-workers root was not created."
  return @(Get-ChildItem -LiteralPath $RemoteWorkersRoot -Force).Count
}

function Get-CheckoutJournalEntryCount([string]$RemoteStateRoot) {
  Assert-True (Test-Path -LiteralPath $RemoteStateRoot -PathType Container) "The installed negative remote-state root was not created."
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $RemoteStateRoot $JournalTemporaryFileName))) "The installed negative checkout journal left an atomic-write temporary file."
  $journalPath = Join-Path $RemoteStateRoot $JournalFileName
  Assert-True (Test-Path -LiteralPath $journalPath -PathType Leaf) "The installed negative checkout journal was not created."
  try {
    $journal = Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json
  }
  catch {
    throw "The installed negative checkout journal is not valid JSON: $($_.Exception.Message)"
  }
  Assert-ExactProperties $journal @("schemaVersion", "entries") "installed negative checkout journal"
  Assert-True ([int]$journal.schemaVersion -eq 1) "The installed negative checkout journal schema must be v1."
  return @($journal.entries).Count
}

$vsixResolved = Resolve-RequiredFile $VsixPath "VsixPath"
$codeResolved = Resolve-RequiredFile $CodeCliPath "CodeCliPath"
$daemonResolved = Resolve-RequiredFile $DaemonPath "DaemonPath"
$bridgeResolved = Resolve-RequiredFile $BridgePath "BridgePath"
$fixtureResolved = Resolve-GeneratedPath $FixtureRoot "FixtureRoot"
$checkoutResolved = Resolve-GeneratedPath $CheckoutPath "CheckoutPath"
Assert-True (Test-PathWithin $checkoutResolved $fixtureResolved) "CheckoutPath must be below FixtureRoot."

try {
  $repositoryUri = [System.Uri]::new($RepositoryUrl, [System.UriKind]::Absolute)
}
catch {
  throw "RepositoryUrl must be an absolute URL."
}
Assert-True (
  $repositoryUri.Scheme -ceq "svn" -and
  $repositoryUri.Host -ceq "127.0.0.1" -and
  $repositoryUri.Port -gt 0 -and
  $repositoryUri.AbsolutePath.Length -gt 1
) "RepositoryUrl must use the controlled direct svn:// loopback endpoint."
Assert-True (
  [string]::IsNullOrEmpty($repositoryUri.UserInfo) -and
  [string]::IsNullOrEmpty($repositoryUri.Query) -and
  [string]::IsNullOrEmpty($repositoryUri.Fragment)
) "RepositoryUrl must not include user info, query, or fragment."

if (Test-Path -LiteralPath $fixtureResolved) {
  Remove-Item -LiteralPath $fixtureResolved -Recurse -Force
}
$userDataRoot = Join-Path $fixtureResolved "user-data"
$extensionsRoot = Join-Path $fixtureResolved "extensions"
$workspaceRoot = Join-Path $fixtureResolved "workspace"
$harnessRoot = Join-Path $fixtureResolved "harness"
$harnessDistRoot = Join-Path $harnessRoot "dist"
$resultPath = Join-Path $fixtureResolved "installed-negative-result.json"
$environmentRoot = Join-Path $fixtureResolved "environment"
$tempRoot = Join-Path $environmentRoot "temp"
$appDataRoot = Join-Path $environmentRoot "appdata"
$localAppDataRoot = Join-Path $environmentRoot "localappdata"
$profileRoot = Join-Path $environmentRoot "profile"
$remoteWorkersRoot = Join-Path $tempRoot "SubversionR\remote-workers"
$remoteStateRoot = Join-Path $userDataRoot "User\globalStorage\hitsuki-ban.subversionr\remote-state"
foreach ($directory in @(
    $userDataRoot, $extensionsRoot, $workspaceRoot, $harnessDistRoot,
    $tempRoot, $appDataRoot, $localAppDataRoot, $profileRoot, (Split-Path -Parent $checkoutResolved)
  )) {
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
}

@'
{
  "name": "subversionr-m8-i6-installed-negative-harness",
  "displayName": "SubversionR M8 I6 Installed Negative Harness",
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

const COMMAND = "subversionr.diagnostics.installedSvnAnonymousNegativeReport";

function requiredEnvironment(name) {
  const value = process.env[name];
  if (typeof value !== "string" || value.length === 0) throw new Error(`Missing required installed negative environment: ${name}`);
  return value;
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

async function run() {
  const resultPath = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_NEGATIVE_RESULT");
  const extensionsRoot = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_NEGATIVE_EXTENSIONS_ROOT");
  const token = requiredEnvironment("SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_NEGATIVE_REPORT_TOKEN");
  const repositoryUrl = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_NEGATIVE_REPOSITORY_URL");
  const checkoutPath = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_NEGATIVE_CHECKOUT_PATH");
  const scenario = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_NEGATIVE_SCENARIO");
  const timeoutText = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_NEGATIVE_TIMEOUT_MS");
  const operationTimeoutMs = Number(timeoutText);
  if (!Number.isSafeInteger(operationTimeoutMs) || operationTimeoutMs < 1 || operationTimeoutMs > 300000) {
    throw new Error("Installed negative operation timeout is invalid.");
  }

  const extension = vscode.extensions.getExtension("hitsuki-ban.subversionr");
  if (!extension) throw new Error("Installed SubversionR extension was not visible.");
  if (extension.isActive) throw new Error("Installed SubversionR extension activated before the negative command.");
  const normalizedExtension = path.resolve(extension.extensionPath).toLowerCase();
  const normalizedRoot = path.resolve(extensionsRoot).toLowerCase();
  if (!normalizedExtension.startsWith(normalizedRoot + path.sep)) {
    throw new Error("SubversionR was not loaded from the isolated installed extensions root.");
  }

  const operationId = crypto.randomUUID();
  const report = await withDeadline(vscode.commands.executeCommand(COMMAND, {
    token,
    scenario,
    repositoryUrl,
    checkoutPath,
    operationId,
    timeoutMs: operationTimeoutMs,
  }), "installed SVN anonymous negative command", operationTimeoutMs + 30000);
  const active = vscode.extensions.getExtension("hitsuki-ban.subversionr");
  if (!active?.isActive || active.extensionPath !== extension.extensionPath) {
    throw new Error("Installed SubversionR extension identity changed during the negative command.");
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

Invoke-Code $codeResolved @(
  "--user-data-dir", $userDataRoot,
  "--extensions-dir", $extensionsRoot,
  "--install-extension", $vsixResolved,
  "--force"
) 180 "VS Code CLI installed negative extension install"

$installed = @(& $codeResolved --user-data-dir $userDataRoot --extensions-dir $extensionsRoot --list-extensions --show-versions)
Assert-True ($LASTEXITCODE -eq 0) "VS Code CLI installed negative extension listing failed."
Assert-True ($installed -contains "hitsuki-ban.subversionr@$ExpectedProductVersion") "Installed negative extension version did not match ExpectedProductVersion."
$installedPackageRoot = Find-InstalledPackage $extensionsRoot $ExpectedProductVersion
$installedDaemonPath = Resolve-RequiredFile (Join-Path $installedPackageRoot "resources\backend\win32-x64\subversionr-daemon.exe") "installed candidate daemon"
$installedBridgePath = Resolve-RequiredFile (Join-Path $installedPackageRoot "resources\backend\win32-x64\subversionr_svn_bridge.dll") "installed candidate bridge"
Assert-True ((Get-Sha256 $installedDaemonPath) -ceq (Get-Sha256 $daemonResolved)) "Installed negative daemon bytes did not match the candidate daemon."
Assert-True ((Get-Sha256 $installedBridgePath) -ceq (Get-Sha256 $bridgeResolved)) "Installed negative bridge bytes did not match the candidate bridge."
Assert-True ((Get-CandidateProcessCount $installedDaemonPath) -eq 0) "The installed negative candidate daemon was already running before the Extension Host probe."

$names = @(
  "SUBVERSIONR_INSTALLED_I6_NEGATIVE_RESULT",
  "SUBVERSIONR_INSTALLED_I6_NEGATIVE_EXTENSIONS_ROOT",
  $NegativeTokenEnvironment,
  "SUBVERSIONR_INSTALLED_I6_NEGATIVE_REPOSITORY_URL",
  "SUBVERSIONR_INSTALLED_I6_NEGATIVE_CHECKOUT_PATH",
  "SUBVERSIONR_INSTALLED_I6_NEGATIVE_SCENARIO",
  "SUBVERSIONR_INSTALLED_I6_NEGATIVE_TIMEOUT_MS",
  "APPDATA", "LOCALAPPDATA", "USERPROFILE", "HOME", "TEMP", "TMP"
)
$previous = @{}
foreach ($name in $names) {
  $previous[$name] = Get-ProcessEnvironmentValue $name
}
try {
  $env:SUBVERSIONR_INSTALLED_I6_NEGATIVE_RESULT = $resultPath
  $env:SUBVERSIONR_INSTALLED_I6_NEGATIVE_EXTENSIONS_ROOT = $extensionsRoot
  Set-Item -LiteralPath "Env:$NegativeTokenEnvironment" -Value ([Guid]::NewGuid().ToString("N"))
  $env:SUBVERSIONR_INSTALLED_I6_NEGATIVE_REPOSITORY_URL = $RepositoryUrl
  $env:SUBVERSIONR_INSTALLED_I6_NEGATIVE_CHECKOUT_PATH = $checkoutResolved
  $env:SUBVERSIONR_INSTALLED_I6_NEGATIVE_SCENARIO = $Scenario
  $env:SUBVERSIONR_INSTALLED_I6_NEGATIVE_TIMEOUT_MS = $OperationTimeoutMilliseconds.ToString([Globalization.CultureInfo]::InvariantCulture)
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
  ) $TimeoutSeconds "VS Code installed I6 negative Extension Host probe"
}
finally {
  foreach ($name in $names) {
    Restore-ProcessEnvironmentValue $name $previous[$name]
  }
}

Wait-CandidateProcessAbsent $installedDaemonPath 10000
Assert-True (Test-Path -LiteralPath $resultPath -PathType Leaf) "Installed negative harness did not write its bounded result."
$result = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json -Depth 64
Assert-ExactProperties $result @("extensionId", "extensionVersion", "extensionPath", "report") "installed negative harness result"
Assert-True ([string]$result.extensionId -ceq "hitsuki-ban.subversionr") "Installed negative extension identity was invalid."
Assert-True ([string]$result.extensionVersion -ceq $ExpectedProductVersion) "Installed negative extension version was invalid."
Assert-True (([System.IO.Path]::GetFullPath([string]$result.extensionPath)).Equals($installedPackageRoot, [System.StringComparison]::OrdinalIgnoreCase)) "Installed negative extension path did not identify the installed VSIX package."

$report = $result.report
Assert-ExactProperties $report @(
  "schema", "schemaVersion", "kind", "scenario", "originCode", "originReason",
  "settlementCode", "settlementReason", "protocol", "trust", "authActivity",
  "diagnosticsRedacted", "redaction"
) "installed negative product report"
Assert-True ([string]$report.schema -ceq "subversionr.release.m8-i6-installed-svn-anonymous-negative.v1") "Installed negative report schema was invalid."
Assert-True ([int]$report.schemaVersion -eq 1 -and [string]$report.kind -ceq "subversionr.installedSvnAnonymousNegativeReport") "Installed negative report identity was invalid."
Assert-True ([string]$report.scenario -ceq $Scenario) "Installed negative report scenario was invalid."
Assert-True ([int]$report.protocol.major -eq 1 -and [int]$report.protocol.minor -eq 35) "Installed negative report protocol was invalid."
Assert-True ($report.trust.consistent -eq $true -and [int]$report.trust.acknowledgedEpoch -ge 1) "Installed negative report trust observation was invalid."
Assert-True (
  [int]$report.authActivity.credentialRequests -eq 0 -and
  [int]$report.authActivity.credentialSettlements -eq 0 -and
  [int]$report.authActivity.certificateRequests -eq 0
) "Installed negative anonymous execution produced authentication activity."
Assert-True ($report.diagnosticsRedacted -eq $true) "Installed negative product report did not prove redacted execution."
Assert-True ($report.redaction.rawUrls -eq $false -and $report.redaction.rawPaths -eq $false -and $report.redaction.rawContent -eq $false) "Installed negative report redaction contract was invalid."

$expected = if ($Scenario -ceq "maliciousRoot") {
  [pscustomobject]@{ Code = "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH"; Reason = "crossAuthorityRejected" }
}
else {
  [pscustomobject]@{ Code = "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED"; Reason = "remoteCapabilityUnsupported" }
}
Assert-True (
  [string]$report.originCode -ceq $expected.Code -and
  [string]$report.originReason -ceq $expected.Reason -and
  [string]$report.settlementCode -ceq $expected.Code -and
  [string]$report.settlementReason -ceq $expected.Reason
) "Installed negative product report did not preserve the exact controlled failure pair."

$reportText = $report | ConvertTo-Json -Depth 32 -Compress
Assert-True (-not $reportText.Contains($RepositoryUrl) -and -not $reportText.Contains($checkoutResolved)) "Installed negative product report leaked fixture identity."
$temporaryRootsAfter = Get-TemporaryRootCount $remoteWorkersRoot
$checkoutJournalEntriesAfter = Get-CheckoutJournalEntryCount $remoteStateRoot
Assert-True ($temporaryRootsAfter -eq 0) "Installed negative execution left operation temporary roots."
Assert-True ($checkoutJournalEntriesAfter -eq 0) "Installed negative execution left durable checkout journal entries."

[pscustomobject]@{
  schema = "subversionr.release.m8-i6-installed-vsix-negative.v1"
  status = "passed"
  surface = "installed-vsix-extension-host"
  scenario = $Scenario
  originCode = [string]$report.originCode
  originReason = [string]$report.originReason
  settlementCode = [string]$report.settlementCode
  settlementReason = [string]$report.settlementReason
  protocol = $report.protocol
  authActivity = $report.authActivity
  temporaryRootsAfter = $temporaryRootsAfter
  checkoutJournalEntriesAfter = $checkoutJournalEntriesAfter
  diagnosticsRedacted = [bool]$report.diagnosticsRedacted
  candidateDaemonExitedAfter = $true
} | ConvertTo-Json -Depth 12 -Compress

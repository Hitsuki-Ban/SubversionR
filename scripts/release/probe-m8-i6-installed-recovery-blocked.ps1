[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string]$VsixPath,
  [Parameter(Mandatory = $true)] [string]$CodeCliPath,
  [Parameter(Mandatory = $true)] [string]$FixtureRoot,
  [Parameter(Mandatory = $true)] [string]$FaultRepositoryUrl,
  [Parameter(Mandatory = $true)] [string]$HealthyRepositoryUrl,
  [Parameter(Mandatory = $true)] [string]$FaultFixtureStatePath,
  [Parameter(Mandatory = $true)] [ValidatePattern('^(?!00000000-0000-0000-0000-000000000000$)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')] [string]$OriginOperationId,
  [Parameter(Mandatory = $true)] [ValidatePattern('^(?!00000000-0000-0000-0000-000000000000$)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')] [string]$RetryOperationId,
  [Parameter(Mandatory = $true)] [ValidatePattern('^(?!00000000-0000-0000-0000-000000000000$)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')] [string]$FreshOperationId,
  [Parameter(Mandatory = $true)] [ValidateSet(5000)] [int]$OperationTimeoutMilliseconds,
  [Parameter(Mandatory = $true)] [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')] [string]$ExpectedProductVersion,
  [Parameter(Mandatory = $true)] [string]$DaemonPath,
  [Parameter(Mandatory = $true)] [string]$BridgePath,
  [Parameter(Mandatory = $true)] [ValidateRange(60, 1800)] [int]$TimeoutSeconds
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ReportCommand = "subversionr.diagnostics.installedSvnAnonymousRecoveryBlockedReport"
$TokenEnvironment = "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_REPORT_TOKEN"
$JournalFileName = "subversionr-remote-checkout-mutations-v1.json"
$JournalTemporaryFileName = ".subversionr-remote-checkout-mutations-v1.tmp"
$FreshCheckoutTimeoutMilliseconds = 300000

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

function Resolve-NewDirectoryPath([string]$Path, [string]$Name) {
  Assert-True (-not [string]::IsNullOrWhiteSpace($Path)) "$Name is required."
  Assert-True ([System.IO.Path]::IsPathFullyQualified($Path)) "$Name must be an absolute path."
  $resolved = [System.IO.Path]::GetFullPath($Path)
  Assert-True (-not (Test-Path -LiteralPath $resolved)) "$Name must not exist before the probe: $resolved"
  Assert-True (Test-Path -LiteralPath (Split-Path -Parent $resolved) -PathType Container) "$Name parent must exist."
  return $resolved
}

function Test-PathWithin([string]$Path, [string]$Root) {
  $resolvedPath = [System.IO.Path]::GetFullPath($Path)
  $prefix = [System.IO.Path]::GetFullPath($Root).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  ) + [System.IO.Path]::DirectorySeparatorChar
  return $resolvedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-Sha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TextSha256([string]$Value) {
  $algorithm = [System.Security.Cryptography.SHA256]::Create()
  try {
    return [Convert]::ToHexString($algorithm.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))).ToLowerInvariant()
  }
  finally { $algorithm.Dispose() }
}

function ConvertTo-ProcessArgument([string]$Value) {
  if ($Value.Length -eq 0) { return '""' }
  if ($Value -notmatch '[\s"]') { return $Value }
  return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Start-CodeProcess([string]$Path, [string[]]$Arguments, [string]$Description) {
  $argumentLine = @($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join " "
  $process = Start-Process -FilePath $Path -ArgumentList $argumentLine -WindowStyle Hidden -PassThru
  Assert-True ($null -ne $process) "$Description failed to start."
  return $process
}

function Complete-CodeProcess([System.Diagnostics.Process]$Process, [int]$DeadlineSeconds, [string]$Description) {
  if (-not $Process.WaitForExit($DeadlineSeconds * 1000)) {
    & taskkill.exe /PID $Process.Id /T /F | Out-Null
    [void]$Process.WaitForExit(10000)
    throw "$Description exceeded its absolute deadline."
  }
  Assert-True ($Process.ExitCode -eq 0) "$Description failed with exit code $($Process.ExitCode)."
}

function Invoke-Code([string]$Path, [string[]]$Arguments, [int]$DeadlineSeconds, [string]$Description) {
  $process = Start-CodeProcess $Path $Arguments $Description
  try { Complete-CodeProcess $process $DeadlineSeconds $Description }
  finally { $process.Dispose() }
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
  catch { throw "Installed recovery-blocked candidate process observation through Win32_Process failed." }
}

function Wait-CandidateProcessAbsent([string]$ExecutablePath, [int]$DeadlineMilliseconds) {
  $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($DeadlineMilliseconds)
  do {
    if ((Get-CandidateProcessCount $ExecutablePath) -eq 0) { return }
    Start-Sleep -Milliseconds 50
  } while ([DateTimeOffset]::UtcNow -lt $deadline)
  throw "The installed recovery-blocked candidate daemon or worker remained alive after the Extension Host exited."
}

function Read-CheckoutJournal([string]$JournalPath, [string]$ExpectedState, [string]$TargetPath, [string]$OperationId) {
  $journal = Get-Content -Raw -LiteralPath $JournalPath | ConvertFrom-Json -Depth 16
  Assert-ExactProperties $journal @("schemaVersion", "entries") "installed recovery-blocked checkout journal"
  Assert-True ([int]$journal.schemaVersion -eq 1) "Installed recovery-blocked checkout journal schema was invalid."
  $entries = @($journal.entries)
  Assert-True ($entries.Count -eq 1) "Installed recovery-blocked checkout journal must contain exactly one entry."
  $entry = $entries[0]
  Assert-ExactProperties $entry @("targetPath", "targetSha256", "originOperationId", "effect", "state") "installed recovery-blocked journal entry"
  Assert-True (
    ([System.IO.Path]::GetFullPath([string]$entry.targetPath)).Equals([System.IO.Path]::GetFullPath($TargetPath), [System.StringComparison]::OrdinalIgnoreCase) -and
    [string]$entry.targetSha256 -cmatch '^[0-9a-f]{64}$' -and
    [string]$entry.originOperationId -ceq $OperationId -and
    [string]$entry.effect -ceq "checkoutTarget" -and
    [string]$entry.state -ceq $ExpectedState
  ) "Installed recovery-blocked checkout journal entry attribution was invalid."
  return $entry
}

function Wait-ArmedCheckoutJournal(
  [string]$JournalPath,
  [string]$TemporaryPath,
  [string]$TargetPath,
  [string]$OperationId,
  [System.Diagnostics.Process]$ExtensionHostProcess,
  [int]$DeadlineMilliseconds
) {
  $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($DeadlineMilliseconds)
  do {
    if ($ExtensionHostProcess.HasExited) { throw "Extension Host exited before the armed checkout journal was observed." }
    if (Test-Path -LiteralPath $JournalPath -PathType Leaf) {
      $entry = $null
      try {
        $entry = Read-CheckoutJournal $JournalPath "armed" $TargetPath $OperationId
      }
      catch {
        if ([DateTimeOffset]::UtcNow -ge $deadline) { throw }
      }
      if ($null -ne $entry) {
        Assert-True (-not (Test-Path -LiteralPath $TemporaryPath)) "The armed checkout journal left its atomic temporary file."
        return $entry
      }
    }
    Start-Sleep -Milliseconds 25
  } while ([DateTimeOffset]::UtcNow -lt $deadline)
  throw "The exact armed checkout journal window was not observed before its absolute deadline."
}

function Get-ProcessEnvironmentValue([string]$Name) {
  return [System.Environment]::GetEnvironmentVariable($Name, "Process")
}

function Restore-ProcessEnvironmentValue([string]$Name, [string]$Value) {
  if ($null -eq $Value) { Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue }
  else { Set-Item -LiteralPath "Env:$Name" -Value $Value }
}

function Assert-LoopbackSvnUrl([string]$Value, [string]$Name) {
  try { $uri = [System.Uri]::new($Value, [System.UriKind]::Absolute) }
  catch { throw "$Name must be an absolute URL." }
  Assert-True (
    $uri.Scheme -ceq "svn" -and $uri.Host -ceq "127.0.0.1" -and $uri.Port -gt 0 -and $uri.AbsolutePath.Length -gt 1 -and
    [string]::IsNullOrEmpty($uri.UserInfo) -and [string]::IsNullOrEmpty($uri.Query) -and [string]::IsNullOrEmpty($uri.Fragment)
  ) "$Name must use a direct anonymous svn:// IPv4 loopback endpoint."
  return $uri
}

$vsixResolved = Resolve-RequiredFile $VsixPath "VsixPath"
$codeResolved = Resolve-RequiredFile $CodeCliPath "CodeCliPath"
Assert-True ((Split-Path -Leaf $codeResolved) -in @("code.cmd", "code.exe")) "CodeCliPath must point to code.cmd or code.exe."
$daemonResolved = Resolve-RequiredFile $DaemonPath "DaemonPath"
$bridgeResolved = Resolve-RequiredFile $BridgePath "BridgePath"
$faultStateResolved = Resolve-RequiredFile $FaultFixtureStatePath "FaultFixtureStatePath"
$fixtureResolved = Resolve-NewDirectoryPath $FixtureRoot "FixtureRoot"
$faultUri = Assert-LoopbackSvnUrl $FaultRepositoryUrl "FaultRepositoryUrl"
$healthyUri = Assert-LoopbackSvnUrl $HealthyRepositoryUrl "HealthyRepositoryUrl"
Assert-True ($faultUri.Port -ne $healthyUri.Port) "FaultRepositoryUrl and HealthyRepositoryUrl must use distinct controlled endpoints."
Assert-True ((@($OriginOperationId, $RetryOperationId, $FreshOperationId) | Sort-Object -Unique).Count -eq 3) "All recovery-blocked operation IDs must be distinct."

New-Item -ItemType Directory -Path $fixtureResolved | Out-Null
$userDataRoot = Join-Path $fixtureResolved "u"
$extensionsRoot = Join-Path $fixtureResolved "x"
$workspaceRoot = Join-Path $fixtureResolved "w"
$harnessRoot = Join-Path $fixtureResolved "h"
$harnessDistRoot = Join-Path $harnessRoot "d"
$environmentRoot = Join-Path $fixtureResolved "e"
$tempRoot = Join-Path $environmentRoot "t"
$appDataRoot = Join-Path $environmentRoot "a"
$localAppDataRoot = Join-Path $environmentRoot "l"
$profileRoot = Join-Path $environmentRoot "p"
$armResultPath = Join-Path $fixtureResolved "arm-result.json"
$recoverResultPath = Join-Path $fixtureResolved "recover-result.json"
$targetPath = Join-Path $fixtureResolved "checkout-target"
$remoteWorkersRoot = Join-Path $tempRoot "SubversionR\remote-workers"
$remoteStateRoot = Join-Path $userDataRoot "User\globalStorage\hitsuki-ban.subversionr\remote-state"
$journalPath = Join-Path $remoteStateRoot $JournalFileName
$journalTemporaryPath = Join-Path $remoteStateRoot $JournalTemporaryFileName
Assert-True (Test-PathWithin $targetPath $fixtureResolved) "The checkout target escaped the isolated fixture root."
foreach ($directory in @($userDataRoot, $extensionsRoot, $workspaceRoot, $harnessDistRoot, $tempRoot, $appDataRoot, $localAppDataRoot, $profileRoot)) {
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

@'
{"name":"subversionr-m8-i6-installed-recovery-blocked-harness","displayName":"SubversionR M8 I6 Installed Recovery Blocked Harness","version":"0.0.0","publisher":"hitsuki-ban-test","private":true,"engines":{"vscode":"^1.101.0"},"main":"./d/extension.js","activationEvents":[]}
'@ | Set-Content -LiteralPath (Join-Path $harnessRoot "package.json") -Encoding utf8 -NoNewline
"exports.activate = function () {}; exports.deactivate = function () {};" |
  Set-Content -LiteralPath (Join-Path $harnessDistRoot "extension.js") -Encoding utf8 -NoNewline

@'
const fs = require("node:fs");
const path = require("node:path");
const vscode = require("vscode");
const COMMAND = "subversionr.diagnostics.installedSvnAnonymousRecoveryBlockedReport";
const TOKEN_ENVIRONMENT = "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_REPORT_TOKEN";
function required(name) { const value = process.env[name]; if (typeof value !== "string" || value.length === 0) throw new Error(`Missing required recovery-blocked environment: ${name}`); return value; }
async function withDeadline(promise, label, milliseconds) { let timer; try { return await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`${label} exceeded its absolute deadline.`)), milliseconds); })]); } finally { if (timer !== undefined) clearTimeout(timer); } }
async function run() {
  const phase = required("SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_PHASE");
  const resultPath = required("SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_RESULT");
  const extensionsRoot = required("SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_EXTENSIONS_ROOT");
  const token = required(TOKEN_ENVIRONMENT);
  const targetPath = required("SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_TARGET");
  const operationId = required("SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_ORIGIN_OPERATION_ID");
  const extension = vscode.extensions.getExtension("hitsuki-ban.subversionr");
  if (!extension || extension.isActive) throw new Error("Installed SubversionR extension identity or activation state was invalid.");
  if (!path.resolve(extension.extensionPath).toLowerCase().startsWith(path.resolve(extensionsRoot).toLowerCase() + path.sep)) throw new Error("SubversionR was not loaded from the isolated installed root.");
  let request;
  if (phase === "arm") {
    request = { token, phase, repositoryUrl: required("SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_FAULT_URL"), targetPath, operationId, timeoutMs: 5000 };
  } else if (phase === "recover") {
    request = {
      token, phase, faultRepositoryUrl: required("SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_FAULT_URL"),
      healthyRepositoryUrl: required("SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_HEALTHY_URL"), targetPath, operationId,
      retryOperationId: required("SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_RETRY_OPERATION_ID"),
      freshOperationId: required("SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_FRESH_OPERATION_ID"),
      fixtureStatePath: required("SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_FAULT_STATE"), timeoutMs: 300000,
    };
  } else { throw new Error("Installed recovery-blocked phase was invalid."); }
  const report = await withDeadline(vscode.commands.executeCommand(COMMAND, request), `installed recovery-blocked ${phase} command`, phase === "arm" ? 35000 : 330000);
  if (process.env[TOKEN_ENVIRONMENT] !== undefined) throw new Error("Installed recovery-blocked token was not consumed during activation.");
  const serialized = JSON.stringify(report).toLowerCase();
  const sensitive = Object.values(request).filter((value) => typeof value === "string" && value !== phase && value !== "arm" && value !== "recover");
  for (const value of sensitive) {
    for (const form of [value, value.replaceAll("\\", "/"), JSON.stringify(value).slice(1, -1)]) {
      if (serialized.includes(form.toLowerCase())) throw new Error("Installed recovery-blocked report leaked request identity.");
    }
  }
  fs.writeFileSync(resultPath, JSON.stringify({ extensionId: extension.id, extensionVersion: extension.packageJSON.version, extensionPath: extension.extensionPath, report }), { encoding: "utf8", flag: "wx" });
}
exports.run = run;
'@ | Set-Content -LiteralPath (Join-Path $harnessDistRoot "run-tests.js") -Encoding utf8 -NoNewline

Invoke-Code $codeResolved @("--user-data-dir", $userDataRoot, "--extensions-dir", $extensionsRoot, "--install-extension", $vsixResolved, "--force") 180 "VS Code CLI installed recovery-blocked extension install"
$installed = @(& $codeResolved --user-data-dir $userDataRoot --extensions-dir $extensionsRoot --list-extensions --show-versions)
Assert-True ($LASTEXITCODE -eq 0 -and $installed -contains "hitsuki-ban.subversionr@$ExpectedProductVersion") "Installed recovery-blocked extension version was invalid."
$installedPackageRoot = Find-InstalledPackage $extensionsRoot $ExpectedProductVersion
$installedDaemonPath = Resolve-RequiredFile (Join-Path $installedPackageRoot "resources\backend\win32-x64\subversionr-daemon.exe") "installed candidate daemon"
$installedBridgePath = Resolve-RequiredFile (Join-Path $installedPackageRoot "resources\backend\win32-x64\subversionr_svn_bridge.dll") "installed candidate bridge"
Assert-True ((Get-Sha256 $installedDaemonPath) -ceq (Get-Sha256 $daemonResolved)) "Installed recovery-blocked daemon bytes did not match the candidate."
Assert-True ((Get-Sha256 $installedBridgePath) -ceq (Get-Sha256 $bridgeResolved)) "Installed recovery-blocked bridge bytes did not match the candidate."
Assert-True ((Get-CandidateProcessCount $installedDaemonPath) -eq 0) "The candidate daemon was already running before the installed recovery-blocked probe."

$environmentNames = @(
  "SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_PHASE", "SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_RESULT",
  "SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_EXTENSIONS_ROOT", "SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_TARGET",
  "SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_ORIGIN_OPERATION_ID", "SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_RETRY_OPERATION_ID",
  "SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_FRESH_OPERATION_ID", "SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_FAULT_URL",
  "SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_HEALTHY_URL", "SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_FAULT_STATE",
  $TokenEnvironment, "APPDATA", "LOCALAPPDATA", "USERPROFILE", "HOME", "TEMP", "TMP"
)
$previousEnvironment = @{}
foreach ($name in $environmentNames) { $previousEnvironment[$name] = Get-ProcessEnvironmentValue $name }

$phaseOne = $null
try {
  $env:SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_EXTENSIONS_ROOT = $extensionsRoot
  $env:SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_TARGET = $targetPath
  $env:SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_ORIGIN_OPERATION_ID = $OriginOperationId
  $env:SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_RETRY_OPERATION_ID = $RetryOperationId
  $env:SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_FRESH_OPERATION_ID = $FreshOperationId
  $env:SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_FAULT_URL = $FaultRepositoryUrl
  $env:SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_HEALTHY_URL = $HealthyRepositoryUrl
  $env:SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_FAULT_STATE = $faultStateResolved
  $env:APPDATA = $appDataRoot
  $env:LOCALAPPDATA = $localAppDataRoot
  $env:USERPROFILE = $profileRoot
  $env:HOME = $profileRoot
  $env:TEMP = $tempRoot
  $env:TMP = $tempRoot

  $env:SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_PHASE = "arm"
  $env:SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_RESULT = $armResultPath
  Set-Item -LiteralPath "Env:$TokenEnvironment" -Value ([Guid]::NewGuid().ToString("N"))
  $phaseOne = Start-CodeProcess $codeResolved @(
    "--user-data-dir", $userDataRoot, "--extensions-dir", $extensionsRoot, "--disable-workspace-trust", "--new-window",
    "--extensionDevelopmentPath=$harnessRoot", "--extensionTestsPath=$(Join-Path $harnessDistRoot 'run-tests.js')", "--log", "trace", "--wait", $workspaceRoot
  ) "VS Code installed recovery-blocked arm Extension Host"
  $armedEntry = Wait-ArmedCheckoutJournal $journalPath $journalTemporaryPath $targetPath $OriginOperationId $phaseOne ($OperationTimeoutMilliseconds + 30000)
  $armedTargetPathSha256 = Get-TextSha256 ([string]$armedEntry.targetPath)
  $armedOriginOperationIdSha256 = Get-TextSha256 ([string]$armedEntry.originOperationId)
  Complete-CodeProcess $phaseOne $TimeoutSeconds "VS Code installed recovery-blocked arm Extension Host"
  $phaseOne.Dispose()
  $phaseOne = $null
  Wait-CandidateProcessAbsent $installedDaemonPath 10000

  Assert-True (Test-Path -LiteralPath $armResultPath -PathType Leaf) "Installed recovery-blocked arm harness did not write its result."
  $armResult = Get-Content -Raw -LiteralPath $armResultPath | ConvertFrom-Json -Depth 32
  Assert-ExactProperties $armResult @("extensionId", "extensionVersion", "extensionPath", "report") "installed recovery-blocked arm result"
  $armReport = $armResult.report
  Assert-ExactProperties $armReport @(
    "schema", "schemaVersion", "kind", "phase", "originCode", "originReason", "settlementCode", "settlementReason",
    "blockedEntryCount", "blockedEntryState", "blockedTargetPathSha256", "blockedOriginOperationIdSha256",
    "protocol", "trust", "authActivity", "diagnosticsRedacted", "redaction"
  ) "installed recovery-blocked arm report"
  Assert-True (
    [string]$armReport.schema -ceq "subversionr.release.m8-i6-installed-vsix-recovery-blocked.v1" -and
    [string]$armReport.kind -ceq "subversionr.installedSvnAnonymousRecoveryBlockedReport" -and
    [string]$armReport.phase -ceq "arm" -and
    [string]$armReport.originCode -ceq "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT" -and
    [string]$armReport.originReason -ceq "operationDeadlineExceeded" -and
    [string]$armReport.settlementCode -ceq "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED" -and
    [string]$armReport.settlementReason -ceq "remoteRecoveryBlocked" -and
    [int]$armReport.blockedEntryCount -eq 1 -and [string]$armReport.blockedEntryState -ceq "blocked"
  ) "Installed recovery-blocked arm settlement was invalid."
  $blockedEntry = Read-CheckoutJournal $journalPath "blocked" $targetPath $OriginOperationId
  Assert-True (
    [string]$blockedEntry.targetSha256 -ceq [string]$armedEntry.targetSha256 -and
    [string]$armReport.blockedTargetPathSha256 -ceq $armedTargetPathSha256 -and
    [string]$armReport.blockedOriginOperationIdSha256 -ceq $armedOriginOperationIdSha256
  ) "Installed recovery-blocked settlement did not preserve the exact armed attribution."
  Assert-True (-not (Test-Path -LiteralPath $journalTemporaryPath)) "Installed recovery-blocked settlement left the checkout journal temporary file."

  Assert-True (-not (Test-Path -LiteralPath $targetPath)) "The command-stall checkout unexpectedly created a target before the first RA command; operator disposition cannot be inferred."

  $env:SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_PHASE = "recover"
  $env:SUBVERSIONR_INSTALLED_I6_RECOVERY_BLOCKED_RESULT = $recoverResultPath
  Set-Item -LiteralPath "Env:$TokenEnvironment" -Value ([Guid]::NewGuid().ToString("N"))
  Invoke-Code $codeResolved @(
    "--user-data-dir", $userDataRoot, "--extensions-dir", $extensionsRoot, "--disable-workspace-trust", "--new-window",
    "--extensionDevelopmentPath=$harnessRoot", "--extensionTestsPath=$(Join-Path $harnessDistRoot 'run-tests.js')", "--log", "trace", "--wait", $workspaceRoot
  ) $TimeoutSeconds "VS Code installed recovery-blocked recover Extension Host"
}
finally {
  if ($null -ne $phaseOne) {
    try {
      if (-not $phaseOne.HasExited) {
        & taskkill.exe /PID $phaseOne.Id /T /F | Out-Null
        [void]$phaseOne.WaitForExit(10000)
      }
    }
    finally { $phaseOne.Dispose() }
  }
  foreach ($name in $environmentNames) { Restore-ProcessEnvironmentValue $name $previousEnvironment[$name] }
}

Wait-CandidateProcessAbsent $installedDaemonPath 10000
Assert-True (Test-Path -LiteralPath $recoverResultPath -PathType Leaf) "Installed recovery-blocked recover harness did not write its result."
$recoverResult = Get-Content -Raw -LiteralPath $recoverResultPath | ConvertFrom-Json -Depth 32
Assert-ExactProperties $recoverResult @("extensionId", "extensionVersion", "extensionPath", "report") "installed recovery-blocked recover result"
Assert-True (
  [string]$recoverResult.extensionId -ceq "hitsuki-ban.subversionr" -and
  [string]$recoverResult.extensionVersion -ceq $ExpectedProductVersion -and
  ([System.IO.Path]::GetFullPath([string]$recoverResult.extensionPath)).Equals($installedPackageRoot, [System.StringComparison]::OrdinalIgnoreCase)
) "Installed recovery-blocked VSIX identity changed across Extension Host restart."
$recoverReport = $recoverResult.report
Assert-ExactProperties $recoverReport @(
  "schema", "schemaVersion", "kind", "phase", "outcome", "stableCode", "reason", "restartRestoredBlocked", "automaticClear",
  "requiredConfirmation", "armedTargetPathSha256", "confirmedTargetPathSha256", "armedOriginOperationIdSha256",
  "confirmedOriginOperationIdSha256", "confirmedEntryRemoved", "fixtureCountersUnchangedOnBlockedRetry",
  "targetDisposition", "subsequentCheckoutPassed", "checkoutRevision", "protocol", "trust", "authActivity", "diagnosticsRedacted", "redaction"
) "installed recovery-blocked recover report"
Assert-True (
  [string]$recoverReport.schema -ceq "subversionr.release.m8-i6-installed-vsix-recovery-blocked.v1" -and
  [string]$recoverReport.phase -ceq "recover" -and [string]$recoverReport.outcome -ceq "Blocked" -and
  [string]$recoverReport.stableCode -ceq "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED" -and
  [string]$recoverReport.reason -ceq "remoteRecoveryBlocked" -and
  $recoverReport.restartRestoredBlocked -eq $true -and $recoverReport.automaticClear -eq $false -and
  [string]$recoverReport.requiredConfirmation -ceq "reviewedAndResolved" -and
  [string]$recoverReport.armedTargetPathSha256 -ceq $armedTargetPathSha256 -and
  [string]$recoverReport.confirmedTargetPathSha256 -ceq $armedTargetPathSha256 -and
  [string]$recoverReport.armedOriginOperationIdSha256 -ceq $armedOriginOperationIdSha256 -and
  [string]$recoverReport.confirmedOriginOperationIdSha256 -ceq $armedOriginOperationIdSha256 -and
  $recoverReport.confirmedEntryRemoved -eq $true -and
  $recoverReport.fixtureCountersUnchangedOnBlockedRetry -eq $true -and
  [string]$recoverReport.targetDisposition -ceq "confirmedAbsent" -and
  $recoverReport.subsequentCheckoutPassed -eq $true -and [int]$recoverReport.checkoutRevision -ge 0
) "Installed recovery-blocked restart, confirmation, or subsequent-checkout proof was invalid."
Assert-ExactProperties $recoverReport.authActivity @("credentialRequests", "credentialSettlements", "certificateRequests") "installed recovery-blocked authentication activity"
Assert-True (
  [int]$recoverReport.authActivity.credentialRequests -eq 0 -and
  [int]$recoverReport.authActivity.credentialSettlements -eq 0 -and
  [int]$recoverReport.authActivity.certificateRequests -eq 0
) "Installed recovery-blocked execution produced authentication activity."
Assert-True ($recoverReport.diagnosticsRedacted -eq $true) "Installed recovery-blocked execution did not prove redaction."
Assert-True (Test-Path -LiteralPath (Join-Path $targetPath ".svn\wc.db") -PathType Leaf) "The fresh healthy checkout did not create a real SVN working copy."
Assert-True ((Get-Item -LiteralPath (Join-Path $targetPath ".svn\wc.db")).Length -gt 0) "The fresh healthy checkout database was empty."
Assert-True (-not (Test-Path -LiteralPath $journalTemporaryPath)) "Installed recovery-blocked recovery left a checkout journal temporary file."
$clearedJournal = Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json -Depth 8
Assert-ExactProperties $clearedJournal @("schemaVersion", "entries") "installed recovery-blocked cleared journal"
Assert-True ([int]$clearedJournal.schemaVersion -eq 1 -and @($clearedJournal.entries).Count -eq 0) "Installed recovery-blocked confirmation did not clear the journal entry."
$temporaryRootsAfter = if (Test-Path -LiteralPath $remoteWorkersRoot) { @(Get-ChildItem -LiteralPath $remoteWorkersRoot -Force).Count } else { 0 }
Assert-True ($temporaryRootsAfter -eq 0) "Installed recovery-blocked execution left operation temporary roots."

$reportText = @($armReport, $recoverReport) | ConvertTo-Json -Depth 32 -Compress
foreach ($sensitive in @($FaultRepositoryUrl, $HealthyRepositoryUrl, $faultStateResolved, $targetPath, $OriginOperationId, $RetryOperationId, $FreshOperationId)) {
  $sensitiveForms = @(
    $sensitive,
    $sensitive.Replace("\", "/"),
    (($sensitive | ConvertTo-Json -Compress).Trim('"'))
  )
  foreach ($form in $sensitiveForms) {
    Assert-True (-not $reportText.ToLowerInvariant().Contains($form.ToLowerInvariant())) "Installed recovery-blocked product report leaked fixture identity."
  }
}

[pscustomobject]@{
  schema = "subversionr.release.m8-i6-installed-vsix-recovery-blocked.v1"
  status = "passed"
  surface = "installed-vsix-extension-host"
  cell = "recoveryBlocked"
  originCode = [string]$armReport.originCode
  originReason = [string]$armReport.originReason
  settlementCode = [string]$armReport.settlementCode
  settlementReason = [string]$armReport.settlementReason
  protocol = $recoverReport.protocol
  trust = $recoverReport.trust
  authActivity = $recoverReport.authActivity
  diagnosticsRedacted = [bool]$recoverReport.diagnosticsRedacted
  armedWindowObserved = $true
  blocked = [ordered]@{
    outcome = "Blocked"
    stableCode = [string]$recoverReport.stableCode
    reason = [string]$recoverReport.reason
    restartRestoredBlocked = [bool]$recoverReport.restartRestoredBlocked
    automaticClear = [bool]$recoverReport.automaticClear
    requiredConfirmation = [string]$recoverReport.requiredConfirmation
    armedTargetPathSha256 = $armedTargetPathSha256
    confirmedTargetPathSha256 = [string]$recoverReport.confirmedTargetPathSha256
    armedOriginOperationIdSha256 = $armedOriginOperationIdSha256
    confirmedOriginOperationIdSha256 = [string]$recoverReport.confirmedOriginOperationIdSha256
    confirmedEntryRemoved = [bool]$recoverReport.confirmedEntryRemoved
    subsequentCheckoutPassed = [bool]$recoverReport.subsequentCheckoutPassed
  }
  fixtureCountersUnchangedOnBlockedRetry = [bool]$recoverReport.fixtureCountersUnchangedOnBlockedRetry
  targetDisposition = [string]$recoverReport.targetDisposition
  temporaryRootsAfter = $temporaryRootsAfter
  checkoutJournalEntriesAfter = 0
  candidateDaemonExitedAfter = $true
} | ConvertTo-Json -Depth 12 -Compress

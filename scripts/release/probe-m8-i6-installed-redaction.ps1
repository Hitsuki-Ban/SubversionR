[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string]$VsixPath,
  [Parameter(Mandatory = $true)] [string]$CodeCliPath,
  [Parameter(Mandatory = $true)] [string]$FixtureRoot,
  [Parameter(Mandatory = $true)] [string]$RepositoryUrl,
  [Parameter(Mandatory = $true)] [string]$CheckoutTarget,
  [Parameter(Mandatory = $true)] [ValidatePattern('^[0-9a-f]{64}$')] [string]$DiagnosticToken,
  [Parameter(Mandatory = $true)] [ValidateRange(1, 2147483647)] [int]$ExpectedRevision,
  [Parameter(Mandatory = $true)] [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')] [string]$ExpectedProductVersion,
  [Parameter(Mandatory = $true)] [string]$DaemonPath,
  [Parameter(Mandatory = $true)] [string]$BridgePath,
  [Parameter(Mandatory = $true)] [ValidateRange(60, 1800)] [int]$TimeoutSeconds
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ReportCommand = "subversionr.diagnostics.installedSvnAnonymousRedactionReport"
$ReportTokenEnvironment = "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_REPORT_TOKEN"
$JournalFileName = "subversionr-remote-checkout-mutations-v1.json"
$JournalTemporaryFileName = ".subversionr-remote-checkout-mutations-v1.tmp"
$script:ProcessLogRoot = $null

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

function Resolve-NewDirectoryPath([string]$Path, [string]$Name) {
  Assert-True (-not [string]::IsNullOrWhiteSpace($Path)) "$Name is required."
  Assert-True ([System.IO.Path]::IsPathFullyQualified($Path)) "$Name must be an absolute path."
  $resolved = [System.IO.Path]::GetFullPath($Path)
  Assert-True (-not (Test-Path -LiteralPath $resolved)) "$Name must not exist before the probe: $resolved"
  $parent = Split-Path -Parent $resolved
  Assert-True (Test-Path -LiteralPath $parent -PathType Container) "$Name parent must be an existing directory: $parent"
  return $resolved
}

function Test-PathsOverlap([string]$Left, [string]$Right) {
  if ($Left.Equals($Right, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $true
  }
  $leftPrefix = $Left.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  $rightPrefix = $Right.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  return $Left.StartsWith($rightPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
    $Right.StartsWith($leftPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-FileSha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-StringSha256([string]$Value) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
  return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
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

function Assert-CodeStderr([string]$Stderr, [string]$Description) {
  $normalized = $Stderr.Replace("`r`n", "`n").Trim()
  if ($normalized.Length -eq 0) {
    return
  }
  $knownDeprecationWarning = '^\(node:[1-9][0-9]*\) \[DEP0169\] DeprecationWarning: `url\.parse\(\)` behavior is not standardized and prone to errors that have security implications\. Use the WHATWG URL API instead\. CVEs are not issued for `url\.parse\(\)` vulnerabilities\.\n\(Use `Code --trace-deprecation \.\.\.` to show where the warning was created\)$'
  Assert-True ($normalized -cmatch $knownDeprecationWarning) "$Description wrote unexpected stderr."
}

function Invoke-Code([string]$Path, [string[]]$Arguments, [int]$DeadlineSeconds, [string]$Description) {
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$script:ProcessLogRoot)) "Process log root is not initialized."
  $invocationId = [Guid]::NewGuid().ToString("N")
  $stdoutPath = Join-Path $script:ProcessLogRoot "$invocationId.stdout.log"
  $stderrPath = Join-Path $script:ProcessLogRoot "$invocationId.stderr.log"
  $argumentLine = @($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join " "
  $process = Start-Process -FilePath $Path -ArgumentList $argumentLine -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
  Assert-True ($null -ne $process) "$Description failed to start."
  try {
    if (-not $process.WaitForExit($DeadlineSeconds * 1000)) {
      & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null
      [void]$process.WaitForExit(10000)
      throw "$Description exceeded its absolute deadline."
    }
    $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -Raw -LiteralPath $stdoutPath } else { "" }
    $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -Raw -LiteralPath $stderrPath } else { "" }
    Assert-True ($process.ExitCode -eq 0) "$Description failed with exit code $($process.ExitCode)."
    Assert-CodeStderr $stderr $Description
    return $stdout
  }
  finally {
    $process.Dispose()
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
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
    throw "Installed redaction candidate process cleanup observation through Win32_Process failed."
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
  throw "The installed redaction candidate daemon or worker remained alive after the Extension Host exited."
}

function Get-TemporaryRootCount([string]$RemoteWorkersRoot) {
  Assert-True (Test-Path -LiteralPath $RemoteWorkersRoot -PathType Container) "The installed redaction remote-workers root was not created."
  return @(Get-ChildItem -LiteralPath $RemoteWorkersRoot -Force).Count
}

function Get-CheckoutJournalObservation([string]$RemoteStateRoot) {
  if (-not (Test-Path -LiteralPath $RemoteStateRoot -PathType Container)) {
    return [pscustomobject]@{
      entryCount = 0
      temporaryFileCount = 0
    }
  }
  $temporaryPath = Join-Path $RemoteStateRoot $JournalTemporaryFileName
  $temporaryCount = if (Test-Path -LiteralPath $temporaryPath) { 1 } else { 0 }
  $journalPath = Join-Path $RemoteStateRoot $JournalFileName
  if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
    return [pscustomobject]@{
      entryCount = 0
      temporaryFileCount = $temporaryCount
    }
  }
  try {
    $journal = Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json
  }
  catch {
    throw "The installed redaction checkout journal is not valid JSON."
  }
  Assert-ExactProperties $journal @("schemaVersion", "entries") "installed redaction checkout journal"
  Assert-True ([int]$journal.schemaVersion -eq 1) "The installed redaction checkout journal schema is invalid."
  return [pscustomobject]@{
    entryCount = @($journal.entries).Count
    temporaryFileCount = $temporaryCount
  }
}

function Assert-WorkingCopyDatabase([string]$TargetPath) {
  Assert-True (Test-Path -LiteralPath $TargetPath -PathType Container) "The installed redaction checkout target was not created."
  $databasePath = Join-Path $TargetPath ".svn\wc.db"
  Assert-True (Test-Path -LiteralPath $databasePath -PathType Leaf) "The installed redaction checkout did not create .svn/wc.db."
  $database = Get-Item -LiteralPath $databasePath
  Assert-True ($database.Length -gt 0) "The installed redaction checkout created an empty .svn/wc.db."
  return [int64]$database.Length
}

function Assert-ReportDoesNotContain([string]$Serialized, [string[]]$SensitiveValues) {
  $normalized = $Serialized.ToLowerInvariant()
  foreach ($sensitive in $SensitiveValues) {
    Assert-True (-not [string]::IsNullOrEmpty($sensitive)) "Sensitive comparison value must not be empty."
    $forms = @(
      $sensitive,
      $sensitive.Replace("\", "/"),
      (($sensitive | ConvertTo-Json -Compress).Trim('"'))
    )
    foreach ($form in $forms) {
      Assert-True (-not $normalized.Contains($form.ToLowerInvariant())) "Installed redaction output leaked request identity."
    }
  }
}

$vsixResolved = Resolve-RequiredFile $VsixPath "VsixPath"
$codeResolved = Resolve-RequiredFile $CodeCliPath "CodeCliPath"
Assert-True ((Split-Path -Leaf $codeResolved) -in @("code.cmd", "code.exe")) "CodeCliPath must point to code.cmd or code.exe."
$daemonResolved = Resolve-RequiredFile $DaemonPath "DaemonPath"
$bridgeResolved = Resolve-RequiredFile $BridgePath "BridgePath"
Assert-True ((Split-Path -Leaf $daemonResolved) -ceq "subversionr-daemon.exe") "DaemonPath must identify subversionr-daemon.exe."
Assert-True ((Split-Path -Leaf $bridgeResolved) -ceq "subversionr_svn_bridge.dll") "BridgePath must identify subversionr_svn_bridge.dll."
$fixtureResolved = Resolve-NewDirectoryPath $FixtureRoot "FixtureRoot"
$checkoutResolved = Resolve-NewDirectoryPath $CheckoutTarget "CheckoutTarget"
Assert-True (-not (Test-PathsOverlap $fixtureResolved $checkoutResolved)) "FixtureRoot and CheckoutTarget must be distinct and must not be nested."

try {
  $repositoryUri = [System.Uri]::new($RepositoryUrl, [System.UriKind]::Absolute)
}
catch {
  throw "RepositoryUrl must be an absolute direct svn:// URL."
}
Assert-True (
  $repositoryUri.Scheme -ceq "svn" -and
  $repositoryUri.Host -ceq "127.0.0.1" -and
  $repositoryUri.Port -ge 1 -and
  $repositoryUri.Port -le 65535 -and
  $repositoryUri.AbsolutePath -ceq "/repo/trunk" -and
  [string]::IsNullOrEmpty($repositoryUri.UserInfo) -and
  [string]::IsNullOrEmpty($repositoryUri.Query) -and
  [string]::IsNullOrEmpty($repositoryUri.Fragment) -and
  $RepositoryUrl -ceq "svn://127.0.0.1:$($repositoryUri.Port)/repo/trunk"
) "RepositoryUrl must exactly match svn://127.0.0.1:<port>/repo/trunk without credentials, query, or fragment."

$fixtureCreated = $false
$extensionInstalled = $false
$environmentRestored = $true
$installedDaemonPath = $null
$safeWrapperReport = $null
$evidenceToken = [Guid]::NewGuid().ToString("N")
Assert-True ($DiagnosticToken -cne $evidenceToken) "DiagnosticToken must be independent from the evidence token."

try {
  New-Item -ItemType Directory -Path $fixtureResolved | Out-Null
  $fixtureCreated = $true
  Assert-True (@(Get-ChildItem -LiteralPath $fixtureResolved -Force).Count -eq 0) "FixtureRoot must be newly created and empty."
  $userDataRoot = Join-Path $fixtureResolved "user-data"
  $extensionsRoot = Join-Path $fixtureResolved "extensions"
  $workspaceRoot = Join-Path $fixtureResolved "workspace"
  $harnessRoot = Join-Path $fixtureResolved "harness"
  $harnessDistRoot = Join-Path $harnessRoot "dist"
  $resultPath = Join-Path $fixtureResolved "installed-redaction-result.json"
  $environmentRoot = Join-Path $fixtureResolved "environment"
  $tempRoot = Join-Path $environmentRoot "temp"
  $appDataRoot = Join-Path $environmentRoot "appdata"
  $localAppDataRoot = Join-Path $environmentRoot "localappdata"
  $profileRoot = Join-Path $environmentRoot "profile"
  $script:ProcessLogRoot = Join-Path $fixtureResolved "process-logs"
  $remoteWorkersRoot = Join-Path $tempRoot "SubversionR\remote-workers"
  $remoteStateRoot = Join-Path $userDataRoot "User\globalStorage\hitsuki-ban.subversionr\remote-state"
  foreach ($directory in @(
      $userDataRoot, $extensionsRoot, $workspaceRoot, $harnessDistRoot,
      $tempRoot, $appDataRoot, $localAppDataRoot, $profileRoot, $script:ProcessLogRoot
    )) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }

  @'
{
  "name": "subversionr-m8-i6-installed-redaction-harness",
  "displayName": "SubversionR M8 I6 Installed Redaction Harness",
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

const COMMAND = "subversionr.diagnostics.installedSvnAnonymousRedactionReport";
const TOKEN_ENVIRONMENT = "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_REPORT_TOKEN";

function requiredEnvironment(name) {
  const value = process.env[name];
  if (typeof value !== "string" || value.length === 0) throw new Error(`Missing required installed redaction environment: ${name}`);
  return value;
}

async function withDeadline(promise, milliseconds) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error("Installed redaction command exceeded its absolute deadline.")), milliseconds);
      }),
    ]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

async function run() {
  const resultPath = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_REDACTION_RESULT");
  const extensionsRoot = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_REDACTION_EXTENSIONS_ROOT");
  const token = requiredEnvironment(TOKEN_ENVIRONMENT);
  const repositoryUrl = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_REDACTION_REPOSITORY_URL");
  const targetPath = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_REDACTION_CHECKOUT_TARGET");
  const secretToken = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_REDACTION_DIAGNOSTIC_TOKEN");
  if (!/^[0-9a-f]{64}$/.test(secretToken)) throw new Error("Installed redaction diagnostic token is invalid.");
  const expectedRevision = Number(requiredEnvironment("SUBVERSIONR_INSTALLED_I6_REDACTION_EXPECTED_REVISION"));
  if (!Number.isSafeInteger(expectedRevision) || expectedRevision < 1 || expectedRevision > 2147483647) {
    throw new Error("Installed redaction expected revision is invalid.");
  }

  const extension = vscode.extensions.getExtension("hitsuki-ban.subversionr");
  if (!extension) throw new Error("Installed SubversionR extension was not visible.");
  if (extension.isActive) throw new Error("Installed SubversionR extension activated before the redaction command.");
  const normalizedExtension = path.resolve(extension.extensionPath).toLowerCase();
  const normalizedRoot = path.resolve(extensionsRoot).toLowerCase();
  if (!normalizedExtension.startsWith(normalizedRoot + path.sep)) {
    throw new Error("SubversionR was not loaded from the isolated installed extensions root.");
  }

  const operationId = crypto.randomUUID();
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(operationId)) {
    throw new Error("Installed redaction operation ID is not a canonical UUID.");
  }
  const report = await withDeadline(vscode.commands.executeCommand(COMMAND, {
    token,
    repositoryUrl,
    targetPath,
    operationId,
    timeoutMs: 300000,
    secretToken,
    expectedRevision,
  }), 330000);
  if (process.env[TOKEN_ENVIRONMENT] !== undefined) {
    throw new Error("Installed redaction evidence token was not consumed during extension activation.");
  }
  const active = vscode.extensions.getExtension("hitsuki-ban.subversionr");
  if (!active?.isActive || active.extensionPath !== extension.extensionPath) {
    throw new Error("Installed SubversionR extension identity changed during the redaction command.");
  }
  const serializedReport = JSON.stringify(report);
  for (const sensitive of [token, repositoryUrl, targetPath, targetPath.replaceAll("\\", "/"), secretToken, operationId]) {
    if (serializedReport.toLowerCase().includes(sensitive.toLowerCase())) {
      throw new Error("Installed redaction report leaked request identity.");
    }
  }
  fs.writeFileSync(resultPath, JSON.stringify({
    extensionId: active.id,
    extensionVersion: active.packageJSON.version,
    extensionPath: active.extensionPath,
    operationId,
    report,
  }), { encoding: "utf8", flag: "wx" });
}

exports.run = run;
'@ | Set-Content -LiteralPath (Join-Path $harnessDistRoot "run-tests.js") -Encoding utf8 -NoNewline

  [void](Invoke-Code $codeResolved @(
      "--user-data-dir", $userDataRoot,
      "--extensions-dir", $extensionsRoot,
      "--install-extension", $vsixResolved,
      "--force"
    ) 180 "VS Code CLI installed redaction extension install")
  $extensionInstalled = $true

  $installedText = Invoke-Code $codeResolved @(
    "--user-data-dir", $userDataRoot,
    "--extensions-dir", $extensionsRoot,
    "--list-extensions", "--show-versions"
  ) 60 "VS Code CLI installed redaction extension listing"
  $installed = @($installedText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  Assert-True ($installed -contains "hitsuki-ban.subversionr@$ExpectedProductVersion") "Installed redaction extension version did not match ExpectedProductVersion."
  $installedPackageRoot = Find-InstalledPackage $extensionsRoot $ExpectedProductVersion
  $installedDaemonPath = Resolve-RequiredFile (Join-Path $installedPackageRoot "resources\backend\win32-x64\subversionr-daemon.exe") "installed candidate daemon"
  $installedBridgePath = Resolve-RequiredFile (Join-Path $installedPackageRoot "resources\backend\win32-x64\subversionr_svn_bridge.dll") "installed candidate bridge"
  Assert-True ((Get-FileSha256 $installedDaemonPath) -ceq (Get-FileSha256 $daemonResolved)) "Installed redaction daemon bytes did not match DaemonPath."
  Assert-True ((Get-FileSha256 $installedBridgePath) -ceq (Get-FileSha256 $bridgeResolved)) "Installed redaction bridge bytes did not match BridgePath."
  Assert-True ((Get-CandidateProcessCount $installedDaemonPath) -eq 0) "The installed redaction candidate daemon was already running before the probe."

  $names = @(
    "SUBVERSIONR_INSTALLED_I6_REDACTION_RESULT",
    "SUBVERSIONR_INSTALLED_I6_REDACTION_EXTENSIONS_ROOT",
    $ReportTokenEnvironment,
    "SUBVERSIONR_INSTALLED_I6_REDACTION_REPOSITORY_URL",
    "SUBVERSIONR_INSTALLED_I6_REDACTION_CHECKOUT_TARGET",
    "SUBVERSIONR_INSTALLED_I6_REDACTION_DIAGNOSTIC_TOKEN",
    "SUBVERSIONR_INSTALLED_I6_REDACTION_EXPECTED_REVISION",
    "APPDATA", "LOCALAPPDATA", "USERPROFILE", "TEMP", "TMP"
  )
  $previous = @{}
  foreach ($name in $names) {
    $previous[$name] = Get-ProcessEnvironmentValue $name
  }
  try {
    $environmentRestored = $false
    $env:SUBVERSIONR_INSTALLED_I6_REDACTION_RESULT = $resultPath
    $env:SUBVERSIONR_INSTALLED_I6_REDACTION_EXTENSIONS_ROOT = $extensionsRoot
    Set-Item -LiteralPath "Env:$ReportTokenEnvironment" -Value $evidenceToken
    $env:SUBVERSIONR_INSTALLED_I6_REDACTION_REPOSITORY_URL = $RepositoryUrl
    $env:SUBVERSIONR_INSTALLED_I6_REDACTION_CHECKOUT_TARGET = $checkoutResolved
    $env:SUBVERSIONR_INSTALLED_I6_REDACTION_DIAGNOSTIC_TOKEN = $DiagnosticToken
    $env:SUBVERSIONR_INSTALLED_I6_REDACTION_EXPECTED_REVISION = $ExpectedRevision.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $env:APPDATA = $appDataRoot
    $env:LOCALAPPDATA = $localAppDataRoot
    $env:USERPROFILE = $profileRoot
    $env:TEMP = $tempRoot
    $env:TMP = $tempRoot
    [void](Invoke-Code $codeResolved @(
        "--user-data-dir", $userDataRoot,
        "--extensions-dir", $extensionsRoot,
        "--disable-workspace-trust",
        "--new-window",
        "--extensionDevelopmentPath=$harnessRoot",
        "--extensionTestsPath=$(Join-Path $harnessDistRoot 'run-tests.js')",
        "--log", "trace",
        "--wait",
        $workspaceRoot
      ) $TimeoutSeconds "VS Code installed I6 redaction Extension Host probe")
  }
  finally {
    foreach ($name in $names) {
      Restore-ProcessEnvironmentValue $name $previous[$name]
    }
    $environmentRestored = $true
  }

  Wait-CandidateProcessAbsent $installedDaemonPath 10000
  $candidateProcessesAfter = Get-CandidateProcessCount $installedDaemonPath
  Assert-True ($candidateProcessesAfter -eq 0) "Installed redaction candidate process residue was nonzero."
  Assert-True (Test-Path -LiteralPath $resultPath -PathType Leaf) "Installed redaction harness did not write its result."
  $result = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json -Depth 64
  Assert-ExactProperties $result @("extensionId", "extensionVersion", "extensionPath", "operationId", "report") "installed redaction harness result"
  Assert-True ([string]$result.extensionId -ceq "hitsuki-ban.subversionr") "Installed redaction extension identity was invalid."
  Assert-True ([string]$result.extensionVersion -ceq $ExpectedProductVersion) "Installed redaction extension version was invalid."
  Assert-True (([System.IO.Path]::GetFullPath([string]$result.extensionPath)).Equals($installedPackageRoot, [System.StringComparison]::OrdinalIgnoreCase)) "Installed redaction extension path did not identify the installed VSIX."
  Assert-True ([string]$result.operationId -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') "Installed redaction operation ID was invalid."

  $report = $result.report
  Assert-ExactProperties $report @(
    "schema", "schemaVersion", "kind", "status", "cell", "surface", "checkoutRevision", "targetPathSha256",
    "inputContainedRawUrl", "inputContainedRawPath", "inputContainedRawToken", "rawUrlCount", "rawPathCount",
    "secretTokenCount", "urlMarkerCount", "pathMarkerCount", "secretMarkerCount", "diagnosticValueCount",
    "maxDiagnosticBytes", "boundedDiagnostics", "protocol", "trust", "authActivity", "redaction", "diagnosticsRedacted"
  ) "installed redaction product report"
  Assert-True (
    [string]$report.schema -ceq "subversionr.release.m8-i6-installed-vsix-redaction.v1" -and
    [int]$report.schemaVersion -eq 1 -and
    [string]$report.kind -ceq "subversionr.installedSvnAnonymousRedactionReport" -and
    [string]$report.status -ceq "passed" -and
    [string]$report.cell -ceq "redaction" -and
    [string]$report.surface -ceq "installed-vsix-extension-host"
  ) "Installed redaction report identity was invalid."
  Assert-True ([int]$report.checkoutRevision -eq $ExpectedRevision) "Installed redaction checkout revision did not match ExpectedRevision."
  Assert-True ([string]$report.targetPathSha256 -ceq (Get-StringSha256 $checkoutResolved)) "Installed redaction target hash was invalid."
  Assert-True (
    $report.inputContainedRawUrl -eq $true -and
    $report.inputContainedRawPath -eq $true -and
    $report.inputContainedRawToken -eq $true
  ) "Installed redaction report did not prove raw diagnostic inputs."
  Assert-True (
    [int]$report.rawUrlCount -eq 0 -and
    [int]$report.rawPathCount -eq 0 -and
    [int]$report.secretTokenCount -eq 0 -and
    [int]$report.urlMarkerCount -ge 1 -and
    [int]$report.pathMarkerCount -ge 1 -and
    [int]$report.secretMarkerCount -ge 1 -and
    [int]$report.diagnosticValueCount -gt 0 -and
    [int]$report.maxDiagnosticBytes -gt 0 -and
    [int]$report.maxDiagnosticBytes -le 32768 -and
    $report.boundedDiagnostics -eq $true
  ) "Installed redaction counts or diagnostic bounds were invalid."
  Assert-ExactProperties $report.protocol @("major", "minor") "installed redaction protocol"
  Assert-True ([int]$report.protocol.major -eq 1 -and [int]$report.protocol.minor -eq 35) "Installed redaction protocol was invalid."
  Assert-ExactProperties $report.trust @("remoteSubmissionEnabled", "epoch") "installed redaction trust"
  Assert-True ($report.trust.remoteSubmissionEnabled -eq $true -and [int]$report.trust.epoch -ge 1) "Installed redaction trust observation was invalid."
  Assert-ExactProperties $report.authActivity @("credentialRequests", "credentialSettlements", "certificateRequests") "installed redaction auth activity"
  Assert-True (
    [int]$report.authActivity.credentialRequests -eq 0 -and
    [int]$report.authActivity.credentialSettlements -eq 0 -and
    [int]$report.authActivity.certificateRequests -eq 0
  ) "Installed redaction anonymous execution produced authentication activity."
  Assert-ExactProperties $report.redaction @("paths", "urls", "secrets") "installed redaction policy"
  Assert-True (
    [string]$report.redaction.paths -ceq "redacted" -and
    [string]$report.redaction.urls -ceq "redacted" -and
    [string]$report.redaction.secrets -ceq "redacted" -and
    $report.diagnosticsRedacted -eq $true
  ) "Installed redaction policy was invalid."

  $reportText = $report | ConvertTo-Json -Depth 32 -Compress
  Assert-ReportDoesNotContain $reportText @($RepositoryUrl, $checkoutResolved, $DiagnosticToken, $evidenceToken, [string]$result.operationId)
  $workingCopyDatabaseBytes = Assert-WorkingCopyDatabase $checkoutResolved
  $temporaryRootsAfter = Get-TemporaryRootCount $remoteWorkersRoot
  Assert-True ($temporaryRootsAfter -eq 0) "Installed redaction operation left remote-worker temporary roots."
  $journalObservation = Get-CheckoutJournalObservation $remoteStateRoot
  Assert-True ($journalObservation.entryCount -eq 0) "Installed redaction operation left checkout journal entries."
  Assert-True ($journalObservation.temporaryFileCount -eq 0) "Installed redaction operation left a checkout journal temporary file."

  $safeWrapperReport = [ordered]@{
    schema = "subversionr.release.m8-i6-installed-vsix-redaction-wrapper.v1"
    status = "passed"
    report = $report
    workingCopyDatabaseBytes = $workingCopyDatabaseBytes
    candidateProcessesAfter = $candidateProcessesAfter
    temporaryRootsAfter = $temporaryRootsAfter
    checkoutJournalEntriesAfter = [int]$journalObservation.entryCount
    journalTemporaryFilesAfter = [int]$journalObservation.temporaryFileCount
    extensionInstalledAfterCleanup = $false
    fixtureRemovedAfterCleanup = $true
    diagnosticsRedacted = $true
  }
}
finally {
  try {
    if ($extensionInstalled -and $fixtureCreated) {
      [void](Invoke-Code $codeResolved @(
          "--user-data-dir", $userDataRoot,
          "--extensions-dir", $extensionsRoot,
          "--uninstall-extension", "hitsuki-ban.subversionr"
        ) 180 "VS Code CLI installed redaction extension uninstall")
      $remainingText = Invoke-Code $codeResolved @(
        "--user-data-dir", $userDataRoot,
        "--extensions-dir", $extensionsRoot,
        "--list-extensions", "--show-versions"
      ) 60 "VS Code CLI installed redaction post-cleanup extension listing"
      $remaining = @($remainingText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      Assert-True (@($remaining | Where-Object { $_ -like "hitsuki-ban.subversionr@*" }).Count -eq 0) "Installed redaction extension remained installed after cleanup."
      $extensionInstalled = $false
    }
  }
  finally {
    if ($fixtureCreated) {
      Assert-True (-not (Test-PathsOverlap $fixtureResolved $checkoutResolved)) "Installed redaction cleanup boundary changed unexpectedly."
      Remove-Item -LiteralPath $fixtureResolved -Recurse -Force
      Assert-True (-not (Test-Path -LiteralPath $fixtureResolved)) "Installed redaction fixture cleanup did not complete."
      $fixtureCreated = $false
    }
  }
  Assert-True ($environmentRestored) "Installed redaction process environment was not restored before cleanup."
}

Assert-True ($null -ne $safeWrapperReport) "Installed redaction wrapper report was not produced."
Assert-True (-not $extensionInstalled -and -not $fixtureCreated) "Installed redaction cleanup state was invalid."
$postCleanupDatabaseBytes = Assert-WorkingCopyDatabase $checkoutResolved
Assert-True ($postCleanupDatabaseBytes -eq [int64]$safeWrapperReport.workingCopyDatabaseBytes) "Installed redaction cleanup changed the checkout working-copy database size."
$safeWrapperText = $safeWrapperReport | ConvertTo-Json -Depth 32 -Compress
Assert-ReportDoesNotContain $safeWrapperText @($RepositoryUrl, $checkoutResolved, $DiagnosticToken, $evidenceToken, [string]$result.operationId)
$safeWrapperText

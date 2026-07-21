[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string]$VsixPath,
  [Parameter(Mandatory = $true)] [string]$CodeCliPath,
  [Parameter(Mandatory = $true)] [string]$FixtureRoot,
  [Parameter(Mandatory = $true)] [string]$RepositoryUrl,
  [Parameter(Mandatory = $true)] [string]$CheckoutPath,
  [Parameter(Mandatory = $true)] [int]$CheckoutRevision,
  [Parameter(Mandatory = $true)] [string]$ExpectedProductVersion,
  [ValidateRange(1, 1800)] [int]$TimeoutSeconds = 600
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw $Message
  }
}

function Assert-ExactProperties($Value, [string[]]$Names, [string]$Context) {
  Assert-True ($null -ne $Value) "$Context was missing."
  $actual = @($Value.PSObject.Properties.Name | Sort-Object)
  $expected = @($Names | Sort-Object)
  Assert-True (($actual -join ",") -ceq ($expected -join ",")) "$Context properties were invalid."
}

function Assert-IdentityRequiredCell($Cell, [string]$Operation, [string]$StableCode, [string]$ExpectedCauseName) {
  Assert-ExactProperties $Cell @(
    "operation", "anonymousIdentityRequired", "stableCode", "diagnosticsCause", "mayHaveMutated",
    "remoteFailure", "promptCount", "credentialSettlement", "laneReleaseProof",
    "nativeLaneReleased", "diagnosticsRedacted", "svnCauseNames"
  ) "Installed I6 $Operation identity-required cell"
  Assert-ExactProperties $Cell.remoteFailure @("category", "reason", "cleanupAppropriate") "Installed I6 $Operation remote failure"
  Assert-ExactProperties $Cell.laneReleaseProof @("method", "reconcile") "Installed I6 $Operation lane-release proof"
  $svnCauseNames = @($Cell.svnCauseNames)
  $observedIdentityCauseNames = @($svnCauseNames | Where-Object {
      [string]$_ -ceq "SVN_ERR_RA_NOT_AUTHORIZED" -or [string]$_ -ceq "SVN_ERR_FS_NO_USER"
    })
  Assert-True (
    [string]$Cell.operation -ceq $Operation -and
    $Cell.anonymousIdentityRequired -eq $true -and
    [string]$Cell.stableCode -ceq $StableCode -and
    [string]$Cell.diagnosticsCause -ceq "authenticationFailed" -and
    $Cell.mayHaveMutated -eq $false -and
    [string]$Cell.remoteFailure.category -ceq "authentication" -and
    [string]$Cell.remoteFailure.reason -ceq "authenticationRequired" -and
    $Cell.remoteFailure.cleanupAppropriate -eq $false -and
    [int]$Cell.promptCount -eq 0 -and
    [string]$Cell.credentialSettlement -ceq "none" -and
    [string]$Cell.laneReleaseProof.method -ceq "status/refresh" -and
    [string]$Cell.laneReleaseProof.reconcile -ceq "fresh" -and
    $Cell.nativeLaneReleased -eq $true -and
    $Cell.diagnosticsRedacted -eq $true -and
    $svnCauseNames.Count -ge 1 -and
    $svnCauseNames.Count -le 8 -and
    @($svnCauseNames | Select-Object -Unique).Count -eq $svnCauseNames.Count -and
    $observedIdentityCauseNames.Count -eq 1 -and
    [string]$observedIdentityCauseNames[0] -ceq $ExpectedCauseName -and
    @($svnCauseNames | Where-Object { [string]$_ -notmatch '^SVN_ERR_[A-Z0-9_]+$' }).Count -eq 0
  ) "Installed I6 $Operation identity-required boundary was invalid."
}

function Resolve-RequiredFile([string]$Path, [string]$Name) {
  Assert-True ([System.IO.Path]::IsPathFullyQualified($Path)) "$Name must be an absolute path."
  $resolved = [System.IO.Path]::GetFullPath($Path)
  Assert-True (Test-Path -LiteralPath $resolved -PathType Leaf) "$Name must be an existing file."
  return $resolved
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
  [System.Environment]::GetEnvironmentVariable($Name, "Process")
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

try {
$vsixResolved = Resolve-RequiredFile $VsixPath "VsixPath"
$codeResolved = Resolve-RequiredFile $CodeCliPath "CodeCliPath"
Assert-True ([System.IO.Path]::IsPathFullyQualified($FixtureRoot)) "FixtureRoot must be an absolute path."
$fixtureResolved = [System.IO.Path]::GetFullPath($FixtureRoot)
Assert-True ([System.IO.Path]::IsPathFullyQualified($CheckoutPath)) "CheckoutPath must be an absolute path."
$checkoutResolved = [System.IO.Path]::GetFullPath($CheckoutPath)
$fixturePrefix = $fixtureResolved.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
Assert-True ($checkoutResolved.StartsWith($fixturePrefix, [System.StringComparison]::OrdinalIgnoreCase)) "CheckoutPath must be below FixtureRoot."
Assert-True ($CheckoutRevision -ge 1) "CheckoutRevision must be positive."

try {
  $repositoryUri = [System.Uri]::new($RepositoryUrl, [System.UriKind]::Absolute)
}
catch {
  throw "RepositoryUrl must be an absolute URL."
}
Assert-True ($repositoryUri.Scheme -ceq "svn" -and $repositoryUri.Host -ceq "127.0.0.1" -and $repositoryUri.Port -gt 0) "RepositoryUrl must use the controlled direct svn:// loopback endpoint."
Assert-True ([string]::IsNullOrEmpty($repositoryUri.UserInfo) -and [string]::IsNullOrEmpty($repositoryUri.Query) -and [string]::IsNullOrEmpty($repositoryUri.Fragment)) "RepositoryUrl must not include user info, query, or fragment."

if (Test-Path -LiteralPath $fixtureResolved) {
  Remove-Item -LiteralPath $fixtureResolved -Recurse -Force
}
$userDataRoot = Join-Path $fixtureResolved "user-data"
$extensionsRoot = Join-Path $fixtureResolved "extensions"
$workspaceRoot = Join-Path $fixtureResolved "workspace"
$harnessRoot = Join-Path $fixtureResolved "harness"
$harnessDistRoot = Join-Path $harnessRoot "dist"
$resultPath = Join-Path $fixtureResolved "installed-result.json"
foreach ($directory in @($userDataRoot, $extensionsRoot, $workspaceRoot, $harnessDistRoot, (Split-Path -Parent $checkoutResolved))) {
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
}
$userSettingsRoot = Join-Path $userDataRoot "User"
New-Item -ItemType Directory -Force -Path $userSettingsRoot | Out-Null
@'
{
  "update.mode": "none",
  "extensions.autoUpdate": false,
  "extensions.autoCheckUpdates": false,
  "telemetry.telemetryLevel": "off"
}
'@ | Set-Content -LiteralPath (Join-Path $userSettingsRoot "settings.json") -Encoding utf8 -NoNewline

@'
{
  "name": "subversionr-m8-i6-installed-harness",
  "displayName": "SubversionR M8 I6 Installed Harness",
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
const fs = require("node:fs");
const path = require("node:path");
const vscode = require("vscode");

async function withDeadline(promise, label, milliseconds = 600000) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(`${label} timed out`)), milliseconds);
      }),
    ]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

async function run() {
  const environment = Object.freeze({
    resultPath: process.env.SUBVERSIONR_INSTALLED_I6_RESULT,
    extensionsRoot: process.env.SUBVERSIONR_INSTALLED_I6_EXTENSIONS_ROOT,
    reportToken: process.env.SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_REPORT_TOKEN,
    repositoryUrl: process.env.SUBVERSIONR_INSTALLED_I6_REPOSITORY_URL,
    checkoutPath: process.env.SUBVERSIONR_INSTALLED_I6_CHECKOUT_PATH,
    checkoutRevision: process.env.SUBVERSIONR_INSTALLED_I6_CHECKOUT_REVISION,
  });
  const required = [
    ["SUBVERSIONR_INSTALLED_I6_RESULT", environment.resultPath],
    ["SUBVERSIONR_INSTALLED_I6_EXTENSIONS_ROOT", environment.extensionsRoot],
    ["SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_REPORT_TOKEN", environment.reportToken],
    ["SUBVERSIONR_INSTALLED_I6_REPOSITORY_URL", environment.repositoryUrl],
    ["SUBVERSIONR_INSTALLED_I6_CHECKOUT_PATH", environment.checkoutPath],
    ["SUBVERSIONR_INSTALLED_I6_CHECKOUT_REVISION", environment.checkoutRevision],
  ];
  for (const [name, value] of required) {
    if (!value) throw new Error(`Missing required installed I6 environment: ${name}`);
  }
  const extension = vscode.extensions.getExtension("hitsuki-ban.subversionr");
  if (!extension) throw new Error("Installed SubversionR extension was not visible.");
  if (extension.isActive) throw new Error("Installed SubversionR extension activated before the harness command.");
  await withDeadline(vscode.commands.executeCommand("subversionr.diagnostics.versionReport"), "version report", 30000);
  const active = vscode.extensions.getExtension("hitsuki-ban.subversionr");
  if (!active?.isActive) throw new Error("Installed SubversionR extension did not activate.");
  const normalizedExtension = path.resolve(active.extensionPath).toLowerCase();
  const normalizedRoot = path.resolve(environment.extensionsRoot).toLowerCase();
  if (!normalizedExtension.startsWith(normalizedRoot + path.sep)) {
    throw new Error("SubversionR was not loaded from the isolated installed extensions root.");
  }
  const commands = await vscode.commands.getCommands(true);
  if (!commands.includes("subversionr.diagnostics.installedSvnAnonymousReport")) {
    throw new Error("Installed I6 diagnostic command was not registered.");
  }
  const report = await withDeadline(
    vscode.commands.executeCommand("subversionr.diagnostics.installedSvnAnonymousReport", {
      token: environment.reportToken,
      repositoryUrl: environment.repositoryUrl,
      checkoutPath: environment.checkoutPath,
      checkoutRevision: Number(environment.checkoutRevision),
      filePath: "tracked.txt",
    }),
    "installed svn anonymous report",
  );
  fs.writeFileSync(environment.resultPath, JSON.stringify({
    extensionId: active.id,
    extensionVersion: active.packageJSON.version,
    extensionPath: active.extensionPath,
    report,
  }));
}

exports.run = run;
'@ | Set-Content -LiteralPath (Join-Path $harnessDistRoot "run-tests.js") -Encoding utf8 -NoNewline

Invoke-Code $codeResolved @(
  "--user-data-dir", $userDataRoot,
  "--extensions-dir", $extensionsRoot,
  "--install-extension", $vsixResolved,
  "--force"
) 180 "VS Code CLI install"

$installed = @(& $codeResolved --user-data-dir $userDataRoot --extensions-dir $extensionsRoot --list-extensions --show-versions)
Assert-True ($LASTEXITCODE -eq 0) "VS Code CLI extension listing failed."
$expectedLine = "hitsuki-ban.subversionr@$ExpectedProductVersion"
Assert-True ($installed -contains $expectedLine) "Installed extension version did not match ExpectedProductVersion."
$installedPackageRoot = Find-InstalledPackage $extensionsRoot $ExpectedProductVersion

$names = @(
  "SUBVERSIONR_INSTALLED_I6_RESULT",
  "SUBVERSIONR_INSTALLED_I6_EXTENSIONS_ROOT",
  "SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_REPORT_TOKEN",
  "SUBVERSIONR_INSTALLED_I6_REPOSITORY_URL",
  "SUBVERSIONR_INSTALLED_I6_CHECKOUT_PATH",
  "SUBVERSIONR_INSTALLED_I6_CHECKOUT_REVISION"
)
$previous = @{}
foreach ($name in $names) {
  $previous[$name] = Get-ProcessEnvironmentValue $name
}
try {
  $env:SUBVERSIONR_INSTALLED_I6_RESULT = $resultPath
  $env:SUBVERSIONR_INSTALLED_I6_EXTENSIONS_ROOT = $extensionsRoot
  $env:SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_REPORT_TOKEN = [Guid]::NewGuid().ToString("N")
  $env:SUBVERSIONR_INSTALLED_I6_REPOSITORY_URL = $RepositoryUrl
  $env:SUBVERSIONR_INSTALLED_I6_CHECKOUT_PATH = $checkoutResolved
  $env:SUBVERSIONR_INSTALLED_I6_CHECKOUT_REVISION = $CheckoutRevision.ToString([Globalization.CultureInfo]::InvariantCulture)
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
  ) $TimeoutSeconds "VS Code installed I6 Extension Host probe"
}
finally {
  foreach ($name in $names) {
    Restore-ProcessEnvironmentValue $name $previous[$name]
  }
}

Assert-True (Test-Path -LiteralPath $resultPath -PathType Leaf) "Installed I6 harness did not write its bounded result."
$result = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json -Depth 64
Assert-True ([string]$result.extensionId -ceq "hitsuki-ban.subversionr") "Installed I6 extension identity was invalid."
Assert-True ([string]$result.extensionVersion -ceq $ExpectedProductVersion) "Installed I6 extension version was invalid."
Assert-True (([System.IO.Path]::GetFullPath([string]$result.extensionPath)).StartsWith(
    $extensionsRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar,
    [System.StringComparison]::OrdinalIgnoreCase
  )) "Installed I6 extension path escaped the isolated extensions root."
Assert-True (([System.IO.Path]::GetFullPath([string]$result.extensionPath)).Equals(
    $installedPackageRoot,
    [System.StringComparison]::OrdinalIgnoreCase
  )) "Installed I6 extension path did not identify the installed VSIX package."

$report = $result.report
$expectedOperations = @("checkoutOpen", "remoteStatus", "content", "historyLog", "historyBlame", "update", "commit", "branchCopy", "switch")
Assert-True ([string]$report.kind -ceq "subversionr.installedSvnAnonymousReport") "Installed I6 report kind was invalid."
Assert-True ([int]$report.schemaVersion -eq 1 -and [int]$report.protocol.major -eq 1 -and [int]$report.protocol.minor -eq 35) "Installed I6 report protocol was invalid."
Assert-True ((@($report.operations) -join ",") -ceq ($expectedOperations -join ",")) "Installed I6 report operation order was invalid."
Assert-True (
  [int]$report.positiveOperationCount -eq 9 -and
  [int]$report.identityRequiredOperationCount -eq 2 -and
  [int]$report.remoteOperationCount -eq 11 -and
  $report.uniqueOperationIds -eq $true
) "Installed I6 report did not prove nine positive and two identity-required unique remote operations."
Assert-ExactProperties $report.anonymousIdentityRequired @("lock", "unlock") "Installed I6 anonymous identity-required report"
Assert-IdentityRequiredCell $report.anonymousIdentityRequired.lock "lock" "SVN_OPERATION_LOCK_FAILED" "SVN_ERR_RA_NOT_AUTHORIZED"
Assert-IdentityRequiredCell $report.anonymousIdentityRequired.unlock "unlock" "SVN_OPERATION_UNLOCK_FAILED" "SVN_ERR_FS_NO_USER"
Assert-True ($report.semanticValidation.freshReconcile -eq $true) "Installed I6 report did not prove fresh reconciliation."
Assert-True ([int]$report.authActivity.credentialRequests -eq 0 -and [int]$report.authActivity.credentialSettlements -eq 0 -and [int]$report.authActivity.certificateRequests -eq 0) "Installed I6 anonymous execution produced authentication activity."
Assert-True ($report.redaction.rawUrls -eq $false -and $report.redaction.rawPaths -eq $false -and $report.redaction.rawContent -eq $false) "Installed I6 report redaction contract was invalid."
$reportText = $report | ConvertTo-Json -Depth 64 -Compress
Assert-True (-not $reportText.Contains($RepositoryUrl) -and -not $reportText.Contains($checkoutResolved)) "Installed I6 report leaked fixture identity."

[pscustomobject]@{
  schema = "subversionr.release.m8-i6-installed-vsix-positive.v1"
  status = "passed"
  protocol = [pscustomobject]@{ major = 1; minor = 35 }
  remoteSvnAnonymous = $true
  fixtureCliInvocations = 0
  positiveOperationCount = 9
  identityRequiredOperationCount = 2
  remoteOperationCount = 11
  uniqueOperationIds = $true
  operations = @(
    "checkoutOpen", "remoteStatus", "content", "historyLog", "historyBlame", "update",
    "commit", "branchCopy", "switch"
  ) | ForEach-Object {
    [pscustomobject]@{
      operation = $_
      status = "passed"
      serverAuth = "anonymous"
      promptCount = 0
      credentialSettlement = "none"
      reconcile = "fresh"
      diagnosticsRedacted = $true
    }
  }
  anonymousIdentityRequired = $report.anonymousIdentityRequired
} | ConvertTo-Json -Depth 12 -Compress
}
catch {
  $localFailure = [string]$_.Exception.Message
  if ($localFailure.Length -gt 4096) {
    $localFailure = $localFailure.Substring(0, 4096)
  }
  [Console]::Error.WriteLine($localFailure)
  [pscustomobject]@{
    schema = "subversionr.release.m8-i6-installed-vsix-positive.v1"
    status = "failed"
    error = [pscustomobject]@{
      code = "SUBVERSIONR_I6_INSTALLED_PROBE_FAILED"
      diagnostics = $null
    }
  } | ConvertTo-Json -Depth 4 -Compress
  exit 1
}

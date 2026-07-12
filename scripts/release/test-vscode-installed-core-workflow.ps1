[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$VsixPath,

  [Parameter(Mandatory = $true)]
  [string]$CodeCliPath,

  [Parameter(Mandatory = $true)]
  [string]$SvnToolsRoot,

  [Parameter(Mandatory = $true)]
  [string]$FixtureRoot,

  [Parameter(Mandatory = $true)]
  [string]$EvidencePath,

  [ValidateRange(1, 1800)]
  [int]$ExtensionHostTimeoutSeconds = 180
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")

function Get-RepoAbsolutePath([string]$Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Get-RepoRelativePath([string]$Path) {
  [System.IO.Path]::GetRelativePath($repoRoot, $Path).Replace("\", "/")
}

function Test-IsPathWithin([string]$Path, [string]$Root) {
  $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  $pathFull = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  $pathFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-IsSamePath([string]$Left, [string]$Right) {
  $leftFull = [System.IO.Path]::GetFullPath($Left).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  $rightFull = [System.IO.Path]::GetFullPath($Right).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  [string]::Equals($leftFull, $rightFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-GeneratedPath([string]$Path, [string]$Name, [string[]]$AllowedRoots, [string]$Description) {
  $absolute = Get-RepoAbsolutePath $Path
  foreach ($allowedRoot in $AllowedRoots) {
    if (Test-IsPathWithin -Path $absolute -Root $allowedRoot) {
      return $absolute
    }
  }
  throw "$Name must resolve inside $Description`: $Path"
}

function Assert-File([string]$Path, [string]$Name) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Name must be a file: $Path"
  }
  (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
}

function Assert-CodeCliPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains("%") -or $Path.Contains("$")) {
    throw "CodeCliPath must be an explicit file path."
  }
  if (-not [System.IO.Path]::IsPathRooted($Path)) {
    throw "CodeCliPath must be an explicit absolute file path: $Path"
  }
  $resolved = Assert-File $Path "CodeCliPath"
  $leaf = Split-Path -Leaf $resolved
  if ($leaf -notin @("code.cmd", "code.exe")) {
    throw "CodeCliPath must point to code.cmd or code.exe: $Path"
  }
  $resolved
}

function Assert-SvnToolsRoot([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains("%") -or $Path.Contains("$")) {
    throw "SvnToolsRoot must be an explicit directory path."
  }
  $allowedRoots = @(
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot ".cache\native\stage\subversion-win-x64\bin")),
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-installed-core-workflow-scripts"))
  )
  $resolved = Assert-GeneratedPath -Path $Path -Name "SvnToolsRoot" -AllowedRoots $allowedRoots -Description ".cache/native/stage/subversion-win-x64/bin or target/tests/release-installed-core-workflow-scripts"
  if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
    throw "SvnToolsRoot must be a directory: $Path"
  }
  (Resolve-Path -LiteralPath $resolved -ErrorAction Stop).Path
}

function Get-VsixPackageJson([string]$Path) {
  $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
  try {
    $entry = $archive.Entries | Where-Object { $_.FullName -eq "extension/package.json" } | Select-Object -First 1
    if ($null -eq $entry) {
      throw "VSIX must contain extension/package.json."
    }
    $reader = [System.IO.StreamReader]::new($entry.Open())
    try {
      $reader.ReadToEnd() | ConvertFrom-Json
    }
    finally {
      $reader.Dispose()
    }
  }
  finally {
    $archive.Dispose()
  }
}

function Get-VsixTargetPlatform([string]$Path) {
  $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
  try {
    $entry = $archive.Entries | Where-Object { $_.FullName -eq "extension.vsixmanifest" } | Select-Object -First 1
    if ($null -eq $entry) {
      throw "VSIX must contain extension.vsixmanifest."
    }
    $reader = [System.IO.StreamReader]::new($entry.Open())
    try {
      $manifestText = $reader.ReadToEnd()
    }
    finally {
      $reader.Dispose()
    }
  }
  finally {
    $archive.Dispose()
  }

  $manifest = [xml]$manifestText
  $identityNodes = @($manifest.SelectNodes("//*[local-name()='PackageManifest']/*[local-name()='Metadata']/*[local-name()='Identity']"))
  if ($identityNodes.Count -ne 1 -or [string]::IsNullOrWhiteSpace($identityNodes[0].TargetPlatform)) {
    throw "VSIX manifest Identity must contain TargetPlatform."
  }
  [string]$identityNodes[0].TargetPlatform
}

function ConvertTo-ProcessArgument([string]$Argument) {
  if ($null -eq $Argument -or $Argument.Length -eq 0) {
    return '""'
  }
  if ($Argument.Contains('"')) {
    throw "Command arguments must not contain double quotes."
  }
  if ($Argument -match '[\s&()^|<>]') {
    return '"' + $Argument + '"'
  }
  $Argument
}

function Invoke-CodeCliWithTimeout(
  [string]$Path,
  [string[]]$Arguments,
  [int]$TimeoutSeconds,
  [string]$Description
) {
  $argumentLine = @($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join " "
  $process = Start-Process -FilePath $Path -ArgumentList $argumentLine -NoNewWindow -PassThru
  if ($null -eq $process) {
    throw "$Description failed to start."
  }

  try {
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      & taskkill.exe /PID $process.Id /T /F | Out-Null
      [void]$process.WaitForExit(10000)
      throw "$Description timed out after $TimeoutSeconds seconds."
    }
    if ($process.ExitCode -ne 0) {
      throw "$Description failed with exit code $($process.ExitCode)."
    }
  }
  finally {
    $process.Dispose()
  }
}

function Invoke-CheckedTool([string]$Path, [string[]]$Arguments, [string]$Description) {
  $output = @(& $Path @Arguments 2>&1)
  if ($LASTEXITCODE -ne 0) {
    $text = $output | Out-String
    throw "$Description failed with exit code $LASTEXITCODE. $text"
  }
  $output
}

function Get-CodeCliVersion([string]$Path) {
  $versionOutput = @(& $Path --version)
  if ($LASTEXITCODE -ne 0) {
    throw "VS Code CLI version probe failed with exit code $LASTEXITCODE."
  }
  if ($versionOutput.Count -eq 0) {
    throw "VS Code CLI version probe returned no output."
  }
  $versionOutput
}

function Get-DirectoryTreeSha256([string]$Root) {
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    throw "Directory tree root must exist: $Root"
  }

  $records = @(Get-ChildItem -LiteralPath $Root -Recurse -Force |
    Sort-Object FullName |
    ForEach-Object {
      $relativePath = [System.IO.Path]::GetRelativePath($Root, $_.FullName).Replace("\", "/")
      if ($_.PSIsContainer) {
        "D|$relativePath"
      }
      else {
        $fileSha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "F|$relativePath|$($_.Length)|$fileSha256"
      }
    })
  $bytes = [System.Text.Encoding]::UTF8.GetBytes(($records -join "`n"))
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    ($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
  }
  finally {
    $sha256.Dispose()
  }
}

function Find-InstalledPackage([string]$ExtensionsRoot, [string]$Publisher, [string]$Name, [string]$Version) {
  $matches = @(Get-ChildItem -LiteralPath $ExtensionsRoot -Directory -Recurse -Depth 2 |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "package.json") -PathType Leaf } |
    ForEach-Object {
      $packageJson = Get-Content -Raw -LiteralPath (Join-Path $_.FullName "package.json") | ConvertFrom-Json
      if ($packageJson.publisher -eq $Publisher -and $packageJson.name -eq $Name -and $packageJson.version -eq $Version) {
        $_.FullName
      }
    })
  if ($matches.Count -ne 1) {
    throw "Expected exactly one installed extension package $Publisher.$Name@$Version; found $($matches.Count)."
  }
  $matches[0]
}

function New-CoreWorkflowFixture([string]$Root, [string]$SvnExe, [string]$SvnAdminExe) {
  $repoPath = Join-Path $Root "repo"
  $importRoot = Join-Path $Root "import"
  $wcRoot = Join-Path $Root "workspace\wc"
  $svnCliConfigRoot = Join-Path $Root "svn-cli-config"
  $svnRuntimeAppDataRoot = Join-Path $Root "runtime-appdata"
  $svnRuntimeConfigRoot = Join-Path $svnRuntimeAppDataRoot "Subversion"
  New-Item -ItemType Directory -Force -Path (Join-Path $importRoot "trunk\src"), $svnCliConfigRoot, $svnRuntimeConfigRoot | Out-Null
  @'
[miscellany]
global-ignores =
enable-auto-props = no
'@ | Set-Content -LiteralPath (Join-Path $svnRuntimeConfigRoot "config") -NoNewline -Encoding utf8
  @'
[global]
store-passwords = no
store-auth-creds = no
'@ | Set-Content -LiteralPath (Join-Path $svnRuntimeConfigRoot "servers") -NoNewline -Encoding utf8
  Set-Content -LiteralPath (Join-Path $importRoot "trunk\src\tracked.txt") -Value "initial`n" -NoNewline -Encoding utf8

  Invoke-CheckedTool -Path $SvnAdminExe -Arguments @("create", $repoPath) -Description "svnadmin create fixture repository" | Out-Null
  $repoUrl = "file:///" + $repoPath.Replace("\", "/")
  Invoke-CheckedTool -Path $SvnExe -Arguments @(
    "import",
    $importRoot,
    $repoUrl,
    "-m",
    "seed M7i fixture",
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $svnCliConfigRoot
  ) -Description "svn import fixture content" | Out-Null
  Invoke-CheckedTool -Path $SvnExe -Arguments @(
    "checkout",
    "$repoUrl/trunk",
    $wcRoot,
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $svnCliConfigRoot
  ) -Description "svn checkout fixture working copy" | Out-Null

  Set-Content -LiteralPath (Join-Path $wcRoot "src\tracked.txt") -Value "modified by M7i`n" -NoNewline -Encoding utf8
  Set-Content -LiteralPath (Join-Path $wcRoot "scratch.txt") -Value "unversioned by M7i`n" -NoNewline -Encoding utf8

  $svnRoot = Join-Path $wcRoot ".svn"
  [pscustomobject]@{
    repoPath = $repoPath
    repoUrl = $repoUrl
    importRoot = $importRoot
    workingCopyRoot = $wcRoot
    svnCliConfigRoot = $svnCliConfigRoot
    svnRuntimeAppDataRoot = $svnRuntimeAppDataRoot
    svnRuntimeConfigRoot = $svnRuntimeConfigRoot
    svnRoot = $svnRoot
    svnTreeBeforeSha256 = Get-DirectoryTreeSha256 $svnRoot
  }
}

function Write-HarnessPackage([string]$HarnessRoot, [string]$ResultPath, [string]$ExtensionsRoot, [string]$WorkingCopyRoot) {
  $distRoot = Join-Path $HarnessRoot "dist"
  New-Item -ItemType Directory -Force -Path $distRoot | Out-Null
  @'
{
  "name": "subversionr-installed-core-workflow-harness",
  "displayName": "SubversionR Installed Core Workflow Harness",
  "version": "0.0.0",
  "publisher": "hitsuki-ban-test",
  "private": true,
  "engines": {
    "vscode": "^1.101.0"
  },
  "main": "./dist/extension.js",
  "activationEvents": []
}
'@ | Set-Content -LiteralPath (Join-Path $HarnessRoot "package.json") -NoNewline

  @'
exports.activate = function () {};
exports.deactivate = function () {};
'@ | Set-Content -LiteralPath (Join-Path $distRoot "extension.js") -NoNewline

  $runner = @'
const fs = require("node:fs");
const path = require("node:path");
const vscode = require("vscode");

function withTimeout(promise, label, timeoutMs) {
  return Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error(`${label} timed out.`)), timeoutMs))
  ]);
}

function findResource(report, groupId, resourcePath, contextValue) {
  const normalized = resourcePath.replace(/\\/g, "/");
  const group = report.projection.groups.find(candidate => candidate.id === groupId);
  if (!group) {
    return undefined;
  }
  return group.resources.find(resource =>
    resource.path.replace(/\\/g, "/") === normalized &&
    resource.contextValue === contextValue
  );
}

async function run() {
  const resultPath = process.env.SUBVERSIONR_INSTALLED_CORE_RESULT;
  const extensionsRoot = process.env.SUBVERSIONR_INSTALLED_CORE_EXTENSIONS_ROOT;
  const workingCopyRoot = process.env.SUBVERSIONR_INSTALLED_CORE_WORKING_COPY;
  if (!resultPath || !extensionsRoot || !workingCopyRoot) {
    throw new Error("Required installed core workflow harness environment variables are missing.");
  }

  let phase = "started";
  let extension;
  let extensionAfterCommand;
  let beforeActive;
  let workflowReport;
  let versionReport;
  function writeResult(payload) {
    fs.writeFileSync(resultPath, JSON.stringify(payload, null, 2));
  }
  function partialResult(extra = {}) {
    return {
      ok: false,
      phase,
      workingCopyRoot,
      workflowReport,
      versionReport,
      ...extra
    };
  }

  try {
    writeResult(partialResult());
    extension = vscode.extensions.getExtension("hitsuki-ban.subversionr");
    if (!extension) {
      throw new Error("Installed SubversionR extension was not visible to Extension Host.");
    }
    beforeActive = extension.isActive;
    if (beforeActive !== true) {
      throw new Error("SubversionR did not activate organically before the installed core workflow report command executed.");
    }
    phase = "executingInstalledCoreWorkflowReport";
    workflowReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedCoreWorkflowReport", { path: workingCopyRoot }),
      "subversionr.diagnostics.installedCoreWorkflowReport",
      60000
    );
    phase = "validatingInstalledCoreWorkflowReport";
    writeResult(partialResult());
    const commands = await vscode.commands.getCommands(true);
    extensionAfterCommand = vscode.extensions.getExtension("hitsuki-ban.subversionr");
    if (!extensionAfterCommand || !extensionAfterCommand.isActive) {
      throw new Error("SubversionR did not report active after installed core workflow command execution.");
    }
    const normalizedExtensionPath = path.resolve(extension.extensionPath).toLowerCase();
    const normalizedRoot = path.resolve(extensionsRoot).toLowerCase();
    if (!normalizedExtensionPath.startsWith(normalizedRoot + path.sep)) {
      throw new Error(`Installed extension path is outside isolated extensions root: ${extension.extensionPath}`);
    }
    if (normalizedExtensionPath.includes("prototype-harness") || normalizedExtensionPath.includes("installed-core-workflow-harness")) {
      throw new Error(`SubversionR must not be loaded from the harness path: ${extension.extensionPath}`);
    }
    if (!commands.includes("subversionr.diagnostics.installedCoreWorkflowReport")) {
      throw new Error("Installed SubversionR command subversionr.diagnostics.installedCoreWorkflowReport was not registered after activation.");
    }
    if (!workflowReport || workflowReport.kind !== "subversionr.installedCoreWorkflowReport") {
      throw new Error(`Unexpected installed core workflow report kind: ${workflowReport && workflowReport.kind}`);
    }
    if (workflowReport.extension.version !== extension.packageJSON.version) {
      throw new Error("Installed core workflow report extension version did not match installed package version.");
    }
    if (path.resolve(workflowReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(workingCopyRoot).toLowerCase()) {
      throw new Error("Installed core workflow report workingCopyRoot did not match the fixture working copy.");
    }
    if (workflowReport.backendWorkflow.repositoryOpen !== true ||
        workflowReport.backendWorkflow.statusSnapshot !== true ||
        workflowReport.backendWorkflow.scmProjection !== true) {
      throw new Error("Installed core workflow report must prove repository open, status snapshot, and SCM projection.");
    }
    if (workflowReport.backendWorkflow.sessionSource !== "organic-activation" ||
        workflowReport.backendWorkflow.repositoryClosed !== false) {
      throw new Error("Installed core workflow report must reuse and preserve the organically activated repository session.");
    }
    const tracked = findResource(workflowReport, "changes", "src/tracked.txt", "subversionr.changedFile");
    if (!tracked || tracked.localStatus !== "modified" || tracked.nodeStatus !== "modified") {
      throw new Error("Installed core workflow report did not include modified src/tracked.txt.");
    }
    const scratch = findResource(workflowReport, "unversioned", "scratch.txt", "subversionr.unversioned");
    if (!scratch || scratch.localStatus !== "unversioned" || scratch.nodeStatus !== "unversioned") {
      throw new Error("Installed core workflow report did not include unversioned scratch.txt.");
    }
    if (workflowReport.projection.groups.length !== 2) {
      throw new Error(`Installed core workflow report must contain exactly two non-empty SCM groups; got ${workflowReport.projection.groups.length}.`);
    }
    for (const group of workflowReport.projection.groups) {
      if ((group.id !== "changes" && group.id !== "unversioned") || group.count !== 1 || group.resources.length !== 1) {
        throw new Error(`Installed core workflow report contained an unexpected SCM group shape: ${JSON.stringify(group)}`);
      }
    }

    phase = "executingVersionReport";
    await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.versionReport"),
      "subversionr.diagnostics.versionReport",
      30000
    );
    phase = "validatingVersionReport";
    const versionReportDocument = vscode.workspace.textDocuments.find(document => document.uri.scheme === "svn-r-diagnostics");
    if (!versionReportDocument) {
      throw new Error("SubversionR version report readonly document was not opened.");
    }
    versionReport = JSON.parse(versionReportDocument.getText());
    writeResult(partialResult());
    if (versionReport.kind !== "subversionr.versionReport") {
      throw new Error(`Unexpected version report kind: ${versionReport.kind}`);
    }
    if (!versionReport.backend || versionReport.backend.status !== "initialized") {
      throw new Error(`Installed core workflow requires initialized backend status; got ${versionReport.backend && versionReport.backend.status}`);
    }
    const backend = versionReport.backend;
    const capabilities = backend.capabilities || {};
    for (const capability of ["repositoryOpen", "statusSnapshot", "statusRefresh", "realLibsvnBridge"]) {
      if (capabilities[capability] !== true) {
        throw new Error(`Version report backend capability ${capability} must be true.`);
      }
    }
    if (typeof backend.libsvnVersion !== "string" || !backend.libsvnVersion.startsWith("1.14.5")) {
      throw new Error(`Version report backend libsvnVersion must be 1.14.5; got ${backend.libsvnVersion}`);
    }

    writeResult({
      ok: true,
      phase: "complete",
      id: extension.id,
      version: extension.packageJSON.version,
      beforeActive,
      afterActive: extensionAfterCommand.isActive,
      extensionPath: extension.extensionPath,
      source: "installed-vsix",
      invokedCommands: [
        "subversionr.diagnostics.installedCoreWorkflowReport",
        "subversionr.diagnostics.versionReport"
      ],
      hasInstalledCoreWorkflowReportCommand: true,
      workflowReport,
      versionReport
    });
  } catch (error) {
    writeResult(partialResult({
      error: {
        message: error && error.message ? error.message : String(error),
        stack: error && error.stack ? error.stack : undefined
      }
    }));
    throw error;
  }
}

exports.run = run;
'@
  $runnerPath = Join-Path $distRoot "run-tests.js"
  $runner | Set-Content -LiteralPath $runnerPath -NoNewline

  [pscustomobject]@{
    Root = $HarnessRoot
    TestsPath = $runnerPath
    ResultPath = $ResultPath
    ExtensionsRoot = $ExtensionsRoot
    WorkingCopyRoot = $WorkingCopyRoot
  }
}

function Assert-ResourcePresent([object]$WorkflowReport, [string]$GroupId, [string]$Path, [string]$ContextValue) {
  $groups = @($WorkflowReport.projection.groups | Where-Object { $_.id -eq $GroupId })
  if ($groups.Count -ne 1) {
    throw "Installed core workflow report must include exactly one $GroupId group."
  }
  $resources = @($groups[0].resources | Where-Object { $_.path -eq $Path -and $_.contextValue -eq $ContextValue })
  if ($resources.Count -ne 1) {
    throw "Installed core workflow report must include $Path in $GroupId with context $ContextValue."
  }
}

function Assert-HarnessResult(
  [object]$Result,
  [string]$ExpectedVersion,
  [string]$ExtensionsRoot,
  [string]$InstalledPackageRoot,
  [string]$WorkingCopyRoot
) {
  if ($Result.PSObject.Properties.Name -contains "ok" -and $Result.ok -ne $true) {
    $message = "Installed core workflow harness did not complete successfully at phase '$($Result.phase)'."
    if ($Result.PSObject.Properties.Name -contains "error" -and $null -ne $Result.error) {
      $message = "$message $($Result.error.message)"
    }
    throw $message
  }
  if ($Result.id -ne "hitsuki-ban.subversionr") {
    throw "Installed core workflow result extension id must be hitsuki-ban.subversionr."
  }
  if ($Result.version -ne $ExpectedVersion) {
    throw "Installed core workflow result extension version must be $ExpectedVersion."
  }
  if ($Result.source -ne "installed-vsix") {
    throw "Installed core workflow result source must be installed-vsix."
  }
  if ($Result.afterActive -ne $true) {
    throw "Installed core workflow result must prove SubversionR is active before workflow validation."
  }
  if ($Result.beforeActive -ne $true) {
    throw "Installed core workflow result must prove SubversionR activated organically before the diagnostic command."
  }
  if ($Result.hasInstalledCoreWorkflowReportCommand -ne $true) {
    throw "Installed core workflow result must prove hidden diagnostic command registration."
  }
  if ($Result.workflowReport.kind -ne "subversionr.installedCoreWorkflowReport") {
    throw "Installed core workflow result must include an installed core workflow report."
  }
  if ($Result.workflowReport.backendWorkflow.repositoryOpen -ne $true -or
    $Result.workflowReport.backendWorkflow.statusSnapshot -ne $true -or
    $Result.workflowReport.backendWorkflow.scmProjection -ne $true) {
    throw "Installed core workflow report must prove open, status, and SCM projection."
  }
  if ($Result.workflowReport.backendWorkflow.sessionSource -ne "organic-activation" -or
    $Result.workflowReport.backendWorkflow.repositoryClosed -ne $false) {
    throw "Installed core workflow report must prove the organically activated repository session was reused and preserved."
  }
  if (-not (Test-IsSamePath -Left ([string]$Result.workflowReport.repository.identity.workingCopyRoot) -Right $WorkingCopyRoot)) {
    throw "Installed core workflow report workingCopyRoot must match the fixture working copy."
  }
  Assert-ResourcePresent -WorkflowReport $Result.workflowReport -GroupId "changes" -Path "src/tracked.txt" -ContextValue "subversionr.changedFile"
  Assert-ResourcePresent -WorkflowReport $Result.workflowReport -GroupId "unversioned" -Path "scratch.txt" -ContextValue "subversionr.unversioned"
  $nonEmptyGroups = @($Result.workflowReport.projection.groups)
  if ($nonEmptyGroups.Count -ne 2) {
    throw "Installed core workflow report must contain exactly two non-empty SCM groups."
  }
  foreach ($group in $nonEmptyGroups) {
    if ($group.id -notin @("changes", "unversioned") -or $group.count -ne 1 -or @($group.resources).Count -ne 1) {
      throw "Installed core workflow report contained an unexpected SCM group shape."
    }
  }
  if ($Result.versionReport.kind -ne "subversionr.versionReport") {
    throw "Installed core workflow result must include a SubversionR version report."
  }
  if ($Result.versionReport.backend.status -ne "initialized") {
    throw "Installed core workflow version report backend status must be initialized."
  }
  if (-not ([string]$Result.versionReport.backend.libsvnVersion).StartsWith("1.14.5", [System.StringComparison]::Ordinal)) {
    throw "Installed core workflow version report libsvnVersion must start with 1.14.5."
  }
  foreach ($capability in @("repositoryOpen", "statusSnapshot", "statusRefresh", "realLibsvnBridge")) {
    if ($Result.versionReport.backend.capabilities.$capability -ne $true) {
      throw "Installed core workflow backend capability $capability must be true."
    }
  }
  $extensionPath = [string]$Result.extensionPath
  if (-not (Test-IsPathWithin -Path $extensionPath -Root $ExtensionsRoot)) {
    throw "Installed core workflow result extension path must be under the isolated extensions root."
  }
  if (-not (Test-IsSamePath -Left $extensionPath -Right $InstalledPackageRoot)) {
    throw "Installed core workflow result extension path must match the installed VSIX package root."
  }
}

$vsixResolved = Assert-GeneratedPath -Path $VsixPath -Name "VsixPath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\vsix")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-installed-core-workflow-scripts"))
) -Description "target/vsix or target/tests/release-installed-core-workflow-scripts"
$vsixResolved = Assert-File $vsixResolved "VsixPath"
$codeCliResolved = Assert-CodeCliPath $CodeCliPath
$svnToolsRootResolved = Assert-SvnToolsRoot $SvnToolsRoot
$svnExeResolved = Assert-File (Join-Path $svnToolsRootResolved "svn.exe") "svn.exe"
$svnAdminExeResolved = Assert-File (Join-Path $svnToolsRootResolved "svnadmin.exe") "svnadmin.exe"

$svnVersion = (Invoke-CheckedTool -Path $svnExeResolved -Arguments @("--version", "--quiet") -Description "svn version probe" | Select-Object -First 1).ToString().Trim()
if ($svnVersion -ne "1.14.5") {
  throw "SvnToolsRoot must provide source-built Apache Subversion 1.14.5 fixture tools; got svn $svnVersion."
}
$svnAdminVersion = (Invoke-CheckedTool -Path $svnAdminExeResolved -Arguments @("--version", "--quiet") -Description "svnadmin version probe" | Select-Object -First 1).ToString().Trim()
if ($svnAdminVersion -ne "1.14.5") {
  throw "SvnToolsRoot must provide source-built Apache Subversion 1.14.5 fixture tools; got svnadmin $svnAdminVersion."
}

$fixtureRootResolved = Assert-GeneratedPath -Path $FixtureRoot -Name "FixtureRoot" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence\installed-core-workflow")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-installed-core-workflow-scripts"))
) -Description "the repository target directory (target/release-evidence/installed-core-workflow or target/tests/release-installed-core-workflow-scripts)"
$aggregateFixtureRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence\installed-core-workflow"))
if (Test-IsSamePath -Left $fixtureRootResolved -Right $aggregateFixtureRoot) {
  throw "FixtureRoot must include a dedicated child directory below target/release-evidence/installed-core-workflow."
}
$evidencePathResolved = Assert-GeneratedPath -Path $EvidencePath -Name "EvidencePath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-installed-core-workflow-scripts"))
) -Description "target/release-evidence or target/tests/release-installed-core-workflow-scripts"

if (Test-Path -LiteralPath $fixtureRootResolved) {
  Remove-Item -LiteralPath $fixtureRootResolved -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $fixtureRootResolved | Out-Null

$packageJson = Get-VsixPackageJson $vsixResolved
if ($packageJson.publisher -ne "hitsuki-ban" -or $packageJson.name -ne "subversionr") {
  throw "VSIX extension identity must be hitsuki-ban.subversionr."
}
$manifestTargetPlatform = Get-VsixTargetPlatform $vsixResolved
if ($manifestTargetPlatform -ne $Target) {
  throw "VSIX target platform must be $Target."
}
$extensionVersion = [string]$packageJson.version
if ([string]::IsNullOrWhiteSpace($extensionVersion)) {
  throw "VSIX package version is required."
}

$codeCliVersion = Get-CodeCliVersion $codeCliResolved
$codeCliSha256 = (Get-FileHash -LiteralPath $codeCliResolved -Algorithm SHA256).Hash.ToLowerInvariant()
$fixture = New-CoreWorkflowFixture -Root (Join-Path $fixtureRootResolved "svn-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
$userDataRoot = Join-Path $fixtureRootResolved "user-data"
$extensionsRoot = Join-Path $fixtureRootResolved "extensions"
$harnessRoot = Join-Path $fixtureRootResolved "installed-core-workflow-harness"
$harnessResultPath = Join-Path $fixtureRootResolved "installed-core-workflow-result.json"
New-Item -ItemType Directory -Force -Path $userDataRoot, $extensionsRoot | Out-Null

& $codeCliResolved --user-data-dir $userDataRoot --extensions-dir $extensionsRoot --install-extension $vsixResolved --force
if ($LASTEXITCODE -ne 0) {
  throw "VS Code CLI install failed with exit code $LASTEXITCODE."
}

$installedExtensions = @(& $codeCliResolved --user-data-dir $userDataRoot --extensions-dir $extensionsRoot --list-extensions --show-versions)
if ($LASTEXITCODE -ne 0) {
  throw "VS Code CLI extension list failed with exit code $LASTEXITCODE."
}
$expectedInstalledLine = "hitsuki-ban.subversionr@$extensionVersion"
if ($installedExtensions -notcontains $expectedInstalledLine) {
  throw "VS Code CLI installed extension list did not contain $expectedInstalledLine. Found: $($installedExtensions -join ', ')"
}
$installedPackageRoot = Find-InstalledPackage -ExtensionsRoot $extensionsRoot -Publisher "hitsuki-ban" -Name "subversionr" -Version $extensionVersion

$harness = Write-HarnessPackage -HarnessRoot $harnessRoot -ResultPath $harnessResultPath -ExtensionsRoot $extensionsRoot -WorkingCopyRoot $fixture.workingCopyRoot
$originalAppData = [Environment]::GetEnvironmentVariable("APPDATA", "Process")
$env:SUBVERSIONR_INSTALLED_CORE_RESULT = $harness.ResultPath
$env:SUBVERSIONR_INSTALLED_CORE_EXTENSIONS_ROOT = $harness.ExtensionsRoot
$env:SUBVERSIONR_INSTALLED_CORE_WORKING_COPY = $harness.WorkingCopyRoot
$env:APPDATA = $fixture.svnRuntimeAppDataRoot
try {
  Invoke-CodeCliWithTimeout -Path $codeCliResolved -Arguments @(
    "--user-data-dir",
    $userDataRoot,
    "--extensions-dir",
    $extensionsRoot,
    "--disable-workspace-trust",
    "--disable-updates",
    "--disable-telemetry",
    "--skip-welcome",
    "--skip-release-notes",
    "--new-window",
    "--extensionDevelopmentPath=$($harness.Root)",
    "--extensionTestsPath=$($harness.TestsPath)",
    "--log",
    "trace",
    "--wait",
    $fixture.workingCopyRoot
  ) -TimeoutSeconds $ExtensionHostTimeoutSeconds -Description "VS Code installed Extension Host core workflow smoke"
}
finally {
  if ($null -eq $originalAppData) {
    Remove-Item Env:APPDATA -ErrorAction SilentlyContinue
  }
  else {
    $env:APPDATA = $originalAppData
  }
  Remove-Item Env:SUBVERSIONR_INSTALLED_CORE_RESULT -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_CORE_EXTENSIONS_ROOT -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_CORE_WORKING_COPY -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $harnessResultPath -PathType Leaf)) {
  throw "Installed core workflow harness did not write the expected result file."
}
$harnessResult = Get-Content -Raw -LiteralPath $harnessResultPath | ConvertFrom-Json
Assert-HarnessResult -Result $harnessResult -ExpectedVersion $extensionVersion -ExtensionsRoot $extensionsRoot -InstalledPackageRoot $installedPackageRoot -WorkingCopyRoot $fixture.workingCopyRoot
$svnTreeAfterSha256 = Get-DirectoryTreeSha256 $fixture.svnRoot

$report = [pscustomobject]@{
  schemaVersion = 1
  schema = "subversionr.release.installed-core-workflow.win32-x64.v1"
  publicReadinessClaim = $false
  target = $Target
  traceIds = @("MIG-009", "TST-024")
  nonClaims = @(
    "This gate does not prove Marketplace publication.",
    "This gate does not prove VSIX signing or supply-chain provenance publication.",
    "This gate does not prove previous-stable upgrade or rollback behavior.",
    "This gate does not prove installed Source Control UI E2E behavior.",
    "This gate does not prove svnserve, HTTP, HTTPS, auth, or certificate flows."
  )
  extension = [pscustomobject]@{
    id = "hitsuki-ban.subversionr"
    version = $extensionVersion
    source = "installed-vsix"
    harnessPhase = [string]$harnessResult.phase
    installedPackageRoot = Get-RepoRelativePath $installedPackageRoot
    extensionHostPath = Get-RepoRelativePath ([string]$harnessResult.extensionPath)
    beforeActive = [bool]$harnessResult.beforeActive
    afterActive = [bool]$harnessResult.afterActive
    invokedCommands = $harnessResult.invokedCommands
    hasInstalledCoreWorkflowReportCommand = [bool]$harnessResult.hasInstalledCoreWorkflowReportCommand
  }
  workflowReport = $harnessResult.workflowReport
  versionReport = $harnessResult.versionReport
  codeCli = [pscustomobject]@{
    path = $codeCliResolved
    sha256 = $codeCliSha256
    versionOutput = $codeCliVersion
  }
  fixtureTools = [pscustomobject]@{
    root = Get-RepoRelativePath $svnToolsRootResolved
    svn = [pscustomobject]@{
      path = Get-RepoRelativePath $svnExeResolved
      version = $svnVersion
      sha256 = (Get-FileHash -LiteralPath $svnExeResolved -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    svnadmin = [pscustomobject]@{
      path = Get-RepoRelativePath $svnAdminExeResolved
      version = $svnAdminVersion
      sha256 = (Get-FileHash -LiteralPath $svnAdminExeResolved -Algorithm SHA256).Hash.ToLowerInvariant()
    }
  }
  vsix = [pscustomobject]@{
    path = $vsixResolved
    relativePath = Get-RepoRelativePath $vsixResolved
    targetPlatform = $manifestTargetPlatform
    sha256 = (Get-FileHash -LiteralPath $vsixResolved -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  fixtureRoots = [pscustomobject]@{
    root = Get-RepoRelativePath $fixtureRootResolved
    repository = Get-RepoRelativePath $fixture.repoPath
    import = Get-RepoRelativePath $fixture.importRoot
    workingCopy = Get-RepoRelativePath $fixture.workingCopyRoot
    svnCliConfig = Get-RepoRelativePath $fixture.svnCliConfigRoot
    svnRuntimeAppData = Get-RepoRelativePath $fixture.svnRuntimeAppDataRoot
    svnRuntimeConfig = Get-RepoRelativePath $fixture.svnRuntimeConfigRoot
    userData = Get-RepoRelativePath $userDataRoot
    extensions = Get-RepoRelativePath $extensionsRoot
    harness = Get-RepoRelativePath $harnessRoot
  }
  installedExtensions = $installedExtensions
  workingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $fixture.workingCopyRoot
    repositoryUrl = $fixture.repoUrl
    svnTreeBeforeSha256 = $fixture.svnTreeBeforeSha256
    svnTreeAfterSha256 = $svnTreeAfterSha256
    svnMetadataMutation = $(if ($svnTreeAfterSha256 -eq $fixture.svnTreeBeforeSha256) { "none" } else { "metadata-refreshed" })
    expectedResources = @(
      [pscustomobject]@{
        path = "src/tracked.txt"
        group = "changes"
        contextValue = "subversionr.changedFile"
        localStatus = "modified"
      },
      [pscustomobject]@{
        path = "scratch.txt"
        group = "unversioned"
        contextValue = "subversionr.unversioned"
        localStatus = "unversioned"
      }
    )
  }
  assertions = @(
    "VSIX was installed into an isolated extensions directory",
    "VSIX manifest TargetPlatform matched the requested release target",
    "Fixture repository and working copy were created with source-built Apache Subversion 1.14.5 CLI tools",
    "Installed VSIX and sidecar ran with fixture-local APPDATA/Subversion config isolation",
    "SubversionR was loaded from the installed VSIX package root, not from the harness extension",
    "SubversionR was active before installed core workflow validation",
    "SubversionR opened the real fixture working copy through its Rust sidecar and libsvn bridge",
    "SubversionR produced SCM projection resources for a modified tracked file and an unversioned file",
    "SubversionR produced exactly the expected non-empty SCM projection groups for this local-only cold-start fixture",
    "SubversionR closed the repository before returning the installed core workflow report",
    "SubversionR version report backend status was initialized with libsvn 1.14.5",
    "publicReadinessClaim remains false"
  )
}

$evidenceParent = Split-Path -Parent $evidencePathResolved
New-Item -ItemType Directory -Force -Path $evidenceParent | Out-Null
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $evidencePathResolved -Encoding utf8

Write-Host "Verified SubversionR installed VSIX core workflow smoke for $Target at $fixtureRootResolved."

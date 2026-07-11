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
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-installed-source-control-surface-scripts"))
  )
  $resolved = Assert-GeneratedPath -Path $Path -Name "SvnToolsRoot" -AllowedRoots $allowedRoots -Description ".cache/native/stage/subversion-win-x64/bin or target/tests/release-installed-source-control-surface-scripts"
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

function New-SourceControlSurfaceFixture([string]$Root, [string]$SvnExe, [string]$SvnAdminExe) {
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
    "seed M7j fixture",
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

  Set-Content -LiteralPath (Join-Path $wcRoot "src\tracked.txt") -Value "modified by M7j`n" -NoNewline -Encoding utf8
  Set-Content -LiteralPath (Join-Path $wcRoot "scratch.txt") -Value "unversioned by M7j`n" -NoNewline -Encoding utf8

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
  "name": "subversionr-installed-source-control-surface-harness",
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

async function waitForOrganicActivation(extension, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (!extension.isActive && Date.now() < deadline) {
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  if (!extension.isActive) {
    throw new Error("SubversionR did not activate organically after opening the SVN working copy.");
  }
  return extension;
}

async function waitForOrganicSourceControlSurface(workingCopyRoot, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const report = await vscode.commands.executeCommand(
        "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport",
        { path: workingCopyRoot }
      );
      if (report && report.kind === "subversionr.installedSourceControlUiE2eCurrentSurfaceReport") {
        return report;
      }
    } catch (error) {
      lastError = error;
    }
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  const detail = lastError && lastError.message ? ` Last error: ${lastError.message}` : "";
  throw new Error(`SubversionR did not publish an organic Source Control surface.${detail}`);
}

function findResource(report, groupId, resourcePath, contextValue) {
  const normalized = resourcePath.replace(/\\/g, "/");
  const group = report.sourceControl.groups.find(candidate => candidate.id === groupId);
  if (!group) {
    return undefined;
  }
  return group.resources.find(resource =>
    resource.path.replace(/\\/g, "/") === normalized &&
    resource.contextValue === contextValue
  );
}

async function run() {
  const resultPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_SURFACE_RESULT;
  const extensionsRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_SURFACE_EXTENSIONS_ROOT;
  const workingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_SURFACE_WORKING_COPY;
  if (!resultPath || !extensionsRoot || !workingCopyRoot) {
    throw new Error("Required installed Source Control surface harness environment variables are missing.");
  }

  let phase = "started";
  let extension;
  let extensionAfterOrganicActivation;
  let extensionAfterCommand;
  let beforeActive;
  let organicActivationWaitMs;
  let organicSourceControlSurfaceReport;
  let organicSourceControlCloseReport;
  let sourceControlSurfaceReport;
  let sourceControlSubdirectoryOpenReport;
  let versionReport;
  function writeResult(payload) {
    fs.writeFileSync(resultPath, JSON.stringify(payload, null, 2));
  }
  function partialResult(extra = {}) {
    return {
      ok: false,
      phase,
      workingCopyRoot,
      organicActivationWaitMs,
      organicSourceControlSurfaceReport,
      organicSourceControlCloseReport,
      sourceControlSurfaceReport,
      sourceControlSubdirectoryOpenReport,
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
    phase = "waitingForOrganicActivation";
    const organicActivationStartedAt = Date.now();
    extensionAfterOrganicActivation = await waitForOrganicActivation(extension, 60000);
    organicActivationWaitMs = Date.now() - organicActivationStartedAt;
    phase = "waitingForOrganicSourceControlSurface";
    organicSourceControlSurfaceReport = await waitForOrganicSourceControlSurface(workingCopyRoot, 60000);
    phase = "closingOrganicSourceControlSurface";
    organicSourceControlCloseReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eCloseReport", {
        repositoryId: organicSourceControlSurfaceReport.repository.repositoryId,
        epoch: organicSourceControlSurfaceReport.repository.epoch
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eCloseReport",
      30000
    );
    if (!organicSourceControlCloseReport || organicSourceControlCloseReport.repositoryClosed !== true) {
      throw new Error("SubversionR did not close the organically opened repository before explicit surface tests.");
    }
    writeResult(partialResult());
    phase = "executingInstalledSourceControlSurfaceReport";
    sourceControlSurfaceReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlSurfaceReport", { path: workingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlSurfaceReport",
      60000
    );
    phase = "validatingInstalledSourceControlSurfaceReport";
    writeResult(partialResult());
    const commands = await vscode.commands.getCommands(true);
    extensionAfterCommand = vscode.extensions.getExtension("hitsuki-ban.subversionr");
    if (!extensionAfterCommand || !extensionAfterCommand.isActive) {
      throw new Error("SubversionR did not report active after installed Source Control surface command execution.");
    }
    const normalizedExtensionPath = path.resolve(extension.extensionPath).toLowerCase();
    const normalizedRoot = path.resolve(extensionsRoot).toLowerCase();
    if (!normalizedExtensionPath.startsWith(normalizedRoot + path.sep)) {
      throw new Error(`Installed extension path is outside isolated extensions root: ${extension.extensionPath}`);
    }
    if (normalizedExtensionPath.includes("prototype-harness") || normalizedExtensionPath.includes("installed-source-control-surface-harness")) {
      throw new Error(`SubversionR must not be loaded from the harness path: ${extension.extensionPath}`);
    }
    if (!extensionAfterOrganicActivation.isActive) {
      throw new Error("SubversionR did not remain active after organic working-copy activation.");
    }
    if (path.resolve(organicSourceControlSurfaceReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(workingCopyRoot).toLowerCase()) {
      throw new Error("Organic Source Control surface workingCopyRoot did not match the fixture working copy.");
    }
    if (!findResource(organicSourceControlSurfaceReport, "changes", "src/tracked.txt", "subversionr.changedFile.baseDiffable")) {
      throw new Error("Organic Source Control surface did not include modified src/tracked.txt.");
    }
    if (!findResource(organicSourceControlSurfaceReport, "unversioned", "scratch.txt", "subversionr.unversioned")) {
      throw new Error("Organic Source Control surface did not include unversioned scratch.txt.");
    }
    if (!commands.includes("subversionr.diagnostics.installedSourceControlSurfaceReport")) {
      throw new Error("Installed SubversionR command subversionr.diagnostics.installedSourceControlSurfaceReport was not registered after activation.");
    }
    if (!sourceControlSurfaceReport || sourceControlSurfaceReport.kind !== "subversionr.installedSourceControlSurfaceReport") {
      throw new Error(`Unexpected installed Source Control surface report kind: ${sourceControlSurfaceReport && sourceControlSurfaceReport.kind}`);
    }
    if (sourceControlSurfaceReport.extension.version !== extension.packageJSON.version) {
      throw new Error("Installed Source Control surface report extension version did not match installed package version.");
    }
    if (path.resolve(sourceControlSurfaceReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(workingCopyRoot).toLowerCase()) {
      throw new Error("Installed Source Control surface report workingCopyRoot did not match the fixture working copy.");
    }
    if (sourceControlSurfaceReport.openRequest.relationToWorkingCopyRoot !== "workingCopyRoot") {
      throw new Error(`Installed Source Control surface root report must record a workingCopyRoot open request; got ${sourceControlSurfaceReport.openRequest.relationToWorkingCopyRoot}.`);
    }
    if (
      sourceControlSurfaceReport.providerResolution.requestedPathResolvedToWorkingCopyRoot !== true ||
      sourceControlSurfaceReport.providerResolution.workspaceScopeRootMatchedRequest !== true ||
      sourceControlSurfaceReport.providerResolution.sourceControlRootMatchedWorkingCopyRoot !== true
    ) {
      throw new Error("Installed Source Control surface root report provider resolution assertions must be true.");
    }
    for (const [key, value] of Object.entries(sourceControlSurfaceReport.surfaceWorkflow)) {
      if (value !== true) {
        throw new Error(`Installed Source Control surface surfaceWorkflow.${key} must be true.`);
      }
    }
    if (sourceControlSurfaceReport.sourceControl.count !== 1) {
      throw new Error(`Installed Source Control surface count must be 1 with unversioned paths excluded from the SourceControl count; got ${sourceControlSurfaceReport.sourceControl.count}.`);
    }
    if (sourceControlSurfaceReport.sourceControl.inputBox.acceptInputCommand !== "subversionr.commitAll") {
      throw new Error("Installed Source Control surface input box must expose the commit-all command.");
    }
    const tracked = findResource(sourceControlSurfaceReport, "changes", "src/tracked.txt", "subversionr.changedFile.baseDiffable");
    if (!tracked || tracked.kind !== "file" || typeof tracked.generation !== "number") {
      throw new Error("Installed Source Control surface report did not include modified src/tracked.txt.");
    }
    const scratch = findResource(sourceControlSurfaceReport, "unversioned", "scratch.txt", "subversionr.unversioned");
    if (!scratch || typeof scratch.kind !== "string" || typeof scratch.generation !== "number") {
      throw new Error("Installed Source Control surface report did not include unversioned scratch.txt.");
    }
    if (sourceControlSurfaceReport.sourceControl.groups.length !== 2) {
      throw new Error(`Installed Source Control surface report must contain exactly two non-empty SCM groups; got ${sourceControlSurfaceReport.sourceControl.groups.length}.`);
    }
    for (const group of sourceControlSurfaceReport.sourceControl.groups) {
      if ((group.id !== "changes" && group.id !== "unversioned") || group.count !== 1 || group.resources.length !== 1) {
        throw new Error(`Installed Source Control surface report contained an unexpected SCM group shape: ${JSON.stringify(group)}`);
      }
    }

    phase = "executingInstalledSourceControlSubdirectoryOpenReport";
    const sourceSubdirectoryPath = path.join(workingCopyRoot, "src");
    sourceControlSubdirectoryOpenReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlSurfaceReport", { path: sourceSubdirectoryPath }),
      "subversionr.diagnostics.installedSourceControlSurfaceReport subdirectory-open",
      60000
    );
    phase = "validatingInstalledSourceControlSubdirectoryOpenReport";
    writeResult(partialResult());
    if (!sourceControlSubdirectoryOpenReport || sourceControlSubdirectoryOpenReport.kind !== "subversionr.installedSourceControlSurfaceReport") {
      throw new Error(`Unexpected installed Source Control subdirectory-open report kind: ${sourceControlSubdirectoryOpenReport && sourceControlSubdirectoryOpenReport.kind}`);
    }
    if (sourceControlSubdirectoryOpenReport.extension.version !== extension.packageJSON.version) {
      throw new Error("Installed Source Control subdirectory-open report extension version did not match installed package version.");
    }
    if (path.resolve(sourceControlSubdirectoryOpenReport.openRequest.path).toLowerCase() !== path.resolve(sourceSubdirectoryPath).toLowerCase()) {
      throw new Error("Installed Source Control subdirectory-open report did not record the requested source subdirectory.");
    }
    if (sourceControlSubdirectoryOpenReport.openRequest.relationToWorkingCopyRoot !== "subdirectory") {
      throw new Error(`Installed Source Control subdirectory-open report must classify the request as subdirectory; got ${sourceControlSubdirectoryOpenReport.openRequest.relationToWorkingCopyRoot}.`);
    }
    if (path.resolve(sourceControlSubdirectoryOpenReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(workingCopyRoot).toLowerCase()) {
      throw new Error("Installed Source Control subdirectory-open report workingCopyRoot did not resolve to the fixture working copy.");
    }
    if (path.resolve(sourceControlSubdirectoryOpenReport.repository.identity.workspaceScopeRoot).toLowerCase() !== path.resolve(sourceSubdirectoryPath).toLowerCase()) {
      throw new Error("Installed Source Control subdirectory-open report workspaceScopeRoot did not match the requested source subdirectory.");
    }
    if (
      sourceControlSubdirectoryOpenReport.providerResolution.requestedPathResolvedToWorkingCopyRoot !== true ||
      sourceControlSubdirectoryOpenReport.providerResolution.workspaceScopeRootMatchedRequest !== true ||
      sourceControlSubdirectoryOpenReport.providerResolution.sourceControlRootMatchedWorkingCopyRoot !== true ||
      sourceControlSubdirectoryOpenReport.providerResolution.subdirectoryOpenResolvedToWorkingCopyRoot !== true
    ) {
      throw new Error("Installed Source Control subdirectory-open report provider resolution assertions must be true.");
    }
    for (const [key, value] of Object.entries(sourceControlSubdirectoryOpenReport.surfaceWorkflow)) {
      if (value !== true) {
        throw new Error(`Installed Source Control subdirectory-open report surfaceWorkflow.${key} must be true.`);
      }
    }
    if (sourceControlSubdirectoryOpenReport.sourceControl.count !== 1) {
      throw new Error(`Installed Source Control subdirectory-open SourceControl count must be 1; got ${sourceControlSubdirectoryOpenReport.sourceControl.count}.`);
    }
    if (!findResource(sourceControlSubdirectoryOpenReport, "changes", "src/tracked.txt", "subversionr.changedFile.baseDiffable")) {
      throw new Error("Installed Source Control subdirectory-open report did not include modified src/tracked.txt.");
    }
    if (!findResource(sourceControlSubdirectoryOpenReport, "unversioned", "scratch.txt", "subversionr.unversioned")) {
      throw new Error("Installed Source Control subdirectory-open report did not include unversioned scratch.txt.");
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
      throw new Error(`Installed Source Control surface requires initialized backend status; got ${versionReport.backend && versionReport.backend.status}`);
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
      afterOrganicActivation: extensionAfterOrganicActivation.isActive,
      afterActive: extensionAfterCommand.isActive,
      organicActivationWaitMs,
      extensionPath: extension.extensionPath,
      source: "installed-vsix",
      invokedCommands: [
        "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport",
        "subversionr.diagnostics.installedSourceControlUiE2eCloseReport",
        "subversionr.diagnostics.installedSourceControlSurfaceReport",
        "subversionr.diagnostics.installedSourceControlSurfaceReport",
        "subversionr.diagnostics.versionReport"
      ],
      commandsBeforeOrganicActivation: [],
      firstCommandAfterOrganicActivation: "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport",
      hasInstalledSourceControlSurfaceReportCommand: true,
      organicSourceControlSurfaceReport,
      organicSourceControlCloseReport,
      sourceControlSurfaceReport,
      sourceControlSubdirectoryOpenReport,
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

function Assert-ResourcePresent([object]$SourceControlSurfaceReport, [string]$GroupId, [string]$Path, [string]$ContextValue) {
  $groups = @($SourceControlSurfaceReport.sourceControl.groups | Where-Object { $_.id -eq $GroupId })
  if ($groups.Count -ne 1) {
    throw "Installed Source Control surface report must include exactly one $GroupId group."
  }
  $resources = @($groups[0].resources | Where-Object { $_.path -eq $Path -and $_.contextValue -eq $ContextValue })
  if ($resources.Count -ne 1) {
    throw "Installed Source Control surface report must include $Path in $GroupId with context $ContextValue."
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
    $message = "Installed Source Control surface harness did not complete successfully at phase '$($Result.phase)'."
    if ($Result.PSObject.Properties.Name -contains "error" -and $null -ne $Result.error) {
      $message = "$message $($Result.error.message)"
    }
    throw $message
  }
  if ($Result.id -ne "hitsuki-ban.subversionr") {
    throw "Installed Source Control surface result extension id must be hitsuki-ban.subversionr."
  }
  if ($Result.version -ne $ExpectedVersion) {
    throw "Installed Source Control surface result extension version must be $ExpectedVersion."
  }
  if ($Result.source -ne "installed-vsix") {
    throw "Installed Source Control surface result source must be installed-vsix."
  }
  if ($Result.afterOrganicActivation -ne $true -or $Result.afterActive -ne $true) {
    throw "Installed Source Control surface result must prove organic activation before diagnostic command execution."
  }
  if (@($Result.commandsBeforeOrganicActivation).Count -ne 0) {
    throw "Installed Source Control surface result must not execute SubversionR commands before organic activation."
  }
  if ($Result.firstCommandAfterOrganicActivation -ne "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport") {
    throw "Installed Source Control surface result must inspect the current surface only after organic activation."
  }
  if ($Result.organicSourceControlSurfaceReport.kind -ne "subversionr.installedSourceControlUiE2eCurrentSurfaceReport") {
    throw "Installed Source Control surface result must include the organically opened Source Control surface."
  }
  if (-not (Test-IsSamePath -Left ([string]$Result.organicSourceControlSurfaceReport.repository.identity.workingCopyRoot) -Right $WorkingCopyRoot)) {
    throw "Organic Source Control surface workingCopyRoot must match the fixture working copy."
  }
  if ($Result.organicSourceControlCloseReport.kind -ne "subversionr.installedSourceControlUiE2eCloseReport" -or $Result.organicSourceControlCloseReport.repositoryClosed -ne $true) {
    throw "Installed Source Control surface result must close the organically opened repository before explicit surface tests."
  }
  if ($Result.hasInstalledSourceControlSurfaceReportCommand -ne $true) {
    throw "Installed Source Control surface result must prove hidden diagnostic command registration."
  }
  if ($Result.sourceControlSurfaceReport.kind -ne "subversionr.installedSourceControlSurfaceReport") {
    throw "Installed Source Control surface result must include an installed Source Control surface report."
  }
  if ($Result.sourceControlSurfaceReport.surfaceWorkflow.repositoryOpen -ne $true -or
    $Result.sourceControlSurfaceReport.surfaceWorkflow.scmProjection -ne $true -or
    $Result.sourceControlSurfaceReport.surfaceWorkflow.sourceControlSurface -ne $true -or
    $Result.sourceControlSurfaceReport.surfaceWorkflow.repositoryClosed -ne $true) {
    throw "Installed Source Control surface report must prove open, SCM projection, SourceControl surface, and close."
  }
  if (-not (Test-IsSamePath -Left ([string]$Result.sourceControlSurfaceReport.repository.identity.workingCopyRoot) -Right $WorkingCopyRoot)) {
    throw "Installed Source Control surface report workingCopyRoot must match the fixture working copy."
  }
  if ($Result.sourceControlSurfaceReport.openRequest.relationToWorkingCopyRoot -ne "workingCopyRoot") {
    throw "Installed Source Control surface report must record a workingCopyRoot open request."
  }
  if ($Result.sourceControlSurfaceReport.providerResolution.requestedPathResolvedToWorkingCopyRoot -ne $true -or
    $Result.sourceControlSurfaceReport.providerResolution.workspaceScopeRootMatchedRequest -ne $true -or
    $Result.sourceControlSurfaceReport.providerResolution.sourceControlRootMatchedWorkingCopyRoot -ne $true) {
    throw "Installed Source Control surface report must prove root provider resolution."
  }
  Assert-ResourcePresent -SourceControlSurfaceReport $Result.sourceControlSurfaceReport -GroupId "changes" -Path "src/tracked.txt" -ContextValue "subversionr.changedFile.baseDiffable"
  Assert-ResourcePresent -SourceControlSurfaceReport $Result.sourceControlSurfaceReport -GroupId "unversioned" -Path "scratch.txt" -ContextValue "subversionr.unversioned"
  $nonEmptyGroups = @($Result.sourceControlSurfaceReport.sourceControl.groups)
  if ($nonEmptyGroups.Count -ne 2) {
    throw "Installed Source Control surface report must contain exactly two non-empty SCM groups."
  }
  foreach ($group in $nonEmptyGroups) {
    if ($group.id -notin @("changes", "unversioned") -or $group.count -ne 1 -or @($group.resources).Count -ne 1) {
      throw "Installed Source Control surface report contained an unexpected SCM group shape."
    }
  }
  $subdirectoryOpenPath = Join-Path $WorkingCopyRoot "src"
  if ($Result.sourceControlSubdirectoryOpenReport.kind -ne "subversionr.installedSourceControlSurfaceReport") {
    throw "Installed Source Control surface result must include an installed Source Control subdirectory-open report."
  }
  if (-not (Test-IsSamePath -Left ([string]$Result.sourceControlSubdirectoryOpenReport.openRequest.path) -Right $subdirectoryOpenPath)) {
    throw "Installed Source Control subdirectory-open report must record the requested source subdirectory."
  }
  if ($Result.sourceControlSubdirectoryOpenReport.openRequest.relationToWorkingCopyRoot -ne "subdirectory") {
    throw "Installed Source Control subdirectory-open report must classify the request as subdirectory."
  }
  if (-not (Test-IsSamePath -Left ([string]$Result.sourceControlSubdirectoryOpenReport.repository.identity.workingCopyRoot) -Right $WorkingCopyRoot)) {
    throw "Installed Source Control subdirectory-open report workingCopyRoot must resolve to the fixture working copy."
  }
  if (-not (Test-IsSamePath -Left ([string]$Result.sourceControlSubdirectoryOpenReport.repository.identity.workspaceScopeRoot) -Right $subdirectoryOpenPath)) {
    throw "Installed Source Control subdirectory-open report workspaceScopeRoot must match the requested source subdirectory."
  }
  if ($Result.sourceControlSubdirectoryOpenReport.providerResolution.requestedPathResolvedToWorkingCopyRoot -ne $true -or
    $Result.sourceControlSubdirectoryOpenReport.providerResolution.workspaceScopeRootMatchedRequest -ne $true -or
    $Result.sourceControlSubdirectoryOpenReport.providerResolution.sourceControlRootMatchedWorkingCopyRoot -ne $true -or
    $Result.sourceControlSubdirectoryOpenReport.providerResolution.subdirectoryOpenResolvedToWorkingCopyRoot -ne $true) {
    throw "Installed Source Control subdirectory-open report must prove provider resolution to the working copy root."
  }
  if ($Result.sourceControlSubdirectoryOpenReport.surfaceWorkflow.repositoryOpen -ne $true -or
    $Result.sourceControlSubdirectoryOpenReport.surfaceWorkflow.scmProjection -ne $true -or
    $Result.sourceControlSubdirectoryOpenReport.surfaceWorkflow.sourceControlSurface -ne $true -or
    $Result.sourceControlSubdirectoryOpenReport.surfaceWorkflow.repositoryClosed -ne $true) {
    throw "Installed Source Control subdirectory-open report must prove open, SCM projection, SourceControl surface, and close."
  }
  Assert-ResourcePresent -SourceControlSurfaceReport $Result.sourceControlSubdirectoryOpenReport -GroupId "changes" -Path "src/tracked.txt" -ContextValue "subversionr.changedFile.baseDiffable"
  Assert-ResourcePresent -SourceControlSurfaceReport $Result.sourceControlSubdirectoryOpenReport -GroupId "unversioned" -Path "scratch.txt" -ContextValue "subversionr.unversioned"
  if ($Result.versionReport.kind -ne "subversionr.versionReport") {
    throw "Installed Source Control surface result must include a SubversionR version report."
  }
  if ($Result.versionReport.backend.status -ne "initialized") {
    throw "Installed Source Control surface version report backend status must be initialized."
  }
  if (-not ([string]$Result.versionReport.backend.libsvnVersion).StartsWith("1.14.5", [System.StringComparison]::Ordinal)) {
    throw "Installed Source Control surface version report libsvnVersion must start with 1.14.5."
  }
  foreach ($capability in @("repositoryOpen", "statusSnapshot", "statusRefresh", "realLibsvnBridge")) {
    if ($Result.versionReport.backend.capabilities.$capability -ne $true) {
      throw "Installed Source Control surface backend capability $capability must be true."
    }
  }
  $extensionPath = [string]$Result.extensionPath
  if (-not (Test-IsPathWithin -Path $extensionPath -Root $ExtensionsRoot)) {
    throw "Installed Source Control surface result extension path must be under the isolated extensions root."
  }
  if (-not (Test-IsSamePath -Left $extensionPath -Right $InstalledPackageRoot)) {
    throw "Installed Source Control surface result extension path must match the installed VSIX package root."
  }
}

$vsixResolved = Assert-GeneratedPath -Path $VsixPath -Name "VsixPath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\vsix")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-installed-source-control-surface-scripts"))
) -Description "target/vsix or target/tests/release-installed-source-control-surface-scripts"
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
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence\installed-source-control-surface")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-installed-source-control-surface-scripts"))
) -Description "the repository target directory (target/release-evidence/installed-source-control-surface or target/tests/release-installed-source-control-surface-scripts)"
$aggregateFixtureRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence\installed-source-control-surface"))
if (Test-IsSamePath -Left $fixtureRootResolved -Right $aggregateFixtureRoot) {
  throw "FixtureRoot must include a dedicated child directory below target/release-evidence/installed-source-control-surface."
}
$evidencePathResolved = Assert-GeneratedPath -Path $EvidencePath -Name "EvidencePath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-installed-source-control-surface-scripts"))
) -Description "target/release-evidence or target/tests/release-installed-source-control-surface-scripts"

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
$fixture = New-SourceControlSurfaceFixture -Root (Join-Path $fixtureRootResolved "svn-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
$workspaceOpenPath = Join-Path $fixture.workingCopyRoot "src"
$userDataRoot = Join-Path $fixtureRootResolved "user-data"
$extensionsRoot = Join-Path $fixtureRootResolved "extensions"
$harnessRoot = Join-Path $fixtureRootResolved "installed-source-control-surface-harness"
$harnessResultPath = Join-Path $fixtureRootResolved "installed-source-control-surface-result.json"
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
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_SURFACE_RESULT = $harness.ResultPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_SURFACE_EXTENSIONS_ROOT = $harness.ExtensionsRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_SURFACE_WORKING_COPY = $harness.WorkingCopyRoot
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
    $workspaceOpenPath
  ) -TimeoutSeconds $ExtensionHostTimeoutSeconds -Description "VS Code installed Extension Host Source Control surface smoke"
}
finally {
  if ($null -eq $originalAppData) {
    Remove-Item Env:APPDATA -ErrorAction SilentlyContinue
  }
  else {
    $env:APPDATA = $originalAppData
  }
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_SURFACE_RESULT -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_SURFACE_EXTENSIONS_ROOT -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_SURFACE_WORKING_COPY -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $harnessResultPath -PathType Leaf)) {
  throw "Installed Source Control surface harness did not write the expected result file."
}
$harnessResult = Get-Content -Raw -LiteralPath $harnessResultPath | ConvertFrom-Json
Assert-HarnessResult -Result $harnessResult -ExpectedVersion $extensionVersion -ExtensionsRoot $extensionsRoot -InstalledPackageRoot $installedPackageRoot -WorkingCopyRoot $fixture.workingCopyRoot
$svnTreeAfterSha256 = Get-DirectoryTreeSha256 $fixture.svnRoot

$report = [pscustomobject]@{
  schemaVersion = 1
  schema = "subversionr.release.installed-source-control-surface.win32-x64.v1"
  publicReadinessClaim = $false
  target = $Target
  traceIds = @("REP-001", "MIG-009", "TST-024", "UX-001")
  nonClaims = @(
    "This gate does not prove Marketplace publication.",
    "This gate does not prove VSIX signing or supply-chain provenance publication.",
    "This gate does not prove previous-stable upgrade or rollback behavior.",
    "This gate does not prove installed Source Control DOM, accessibility tree, or pixel E2E behavior.",
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
    afterOrganicActivation = [bool]$harnessResult.afterOrganicActivation
    afterActive = [bool]$harnessResult.afterActive
    organicActivationWaitMs = [int]$harnessResult.organicActivationWaitMs
    invokedCommands = $harnessResult.invokedCommands
    commandsBeforeOrganicActivation = $harnessResult.commandsBeforeOrganicActivation
    firstCommandAfterOrganicActivation = [string]$harnessResult.firstCommandAfterOrganicActivation
    hasInstalledSourceControlSurfaceReportCommand = [bool]$harnessResult.hasInstalledSourceControlSurfaceReportCommand
  }
  organicSourceControlSurfaceReport = $harnessResult.organicSourceControlSurfaceReport
  organicSourceControlCloseReport = $harnessResult.organicSourceControlCloseReport
  sourceControlSurfaceReport = $harnessResult.sourceControlSurfaceReport
  sourceControlSubdirectoryOpenReport = $harnessResult.sourceControlSubdirectoryOpenReport
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
    workspaceOpen = Get-RepoRelativePath $workspaceOpenPath
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
    "SubversionR activated organically after the installed SVN working copy opened without executing a SubversionR command",
    "SubversionR automatically opened the fixture repository and published its Source Control surface before diagnostic inspection",
    "SubversionR opened the real fixture working copy through its Rust sidecar and libsvn bridge",
    "SubversionR opened the fixture src subdirectory and resolved the provider to the parent working copy root",
    "SubversionR produced SCM projection resources for a modified tracked file and an unversioned file",
    "SubversionR produced exactly the expected non-empty SCM projection groups for this local-only cold-start fixture",
    "SubversionR closed the repository before returning the installed Source Control surface report",
    "SubversionR version report backend status was initialized with libsvn 1.14.5",
    "publicReadinessClaim remains false"
  )
}

$evidenceParent = Split-Path -Parent $evidencePathResolved
New-Item -ItemType Directory -Force -Path $evidenceParent | Out-Null
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $evidencePathResolved -Encoding utf8

Write-Host "Verified SubversionR installed VSIX Source Control surface smoke for $Target at $fixtureRootResolved."

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

function Get-ProcessEnvironmentValue([string]$Name) {
  [System.Environment]::GetEnvironmentVariable($Name, "Process")
}

function Restore-ProcessEnvironmentValue([string]$Name, [string]$Value) {
  if ($null -eq $Value) {
    Remove-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
    return
  }
  Set-Item -Path "Env:$Name" -Value $Value
}

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

function Get-BytesSha256([byte[]]$Bytes) {
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    ($sha256.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
  }
  finally {
    $sha256.Dispose()
  }
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
  Get-BytesSha256 $bytes
}

function New-WorkingCopySentinel([string]$Root) {
  $svnRoot = Join-Path $Root ".svn"
  New-Item -ItemType Directory -Force -Path $svnRoot | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $svnRoot "pristine\00") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $svnRoot "tmp") | Out-Null
  $wcDbPath = Join-Path $svnRoot "wc.db"
  [System.IO.File]::WriteAllBytes($wcDbPath, [System.Text.Encoding]::UTF8.GetBytes("SubversionR M7h installed Extension Host working-copy non-mutation sentinel"))
  $pristinePath = Join-Path $svnRoot "pristine\00\sentinel.svn-base"
  [System.IO.File]::WriteAllBytes($pristinePath, [System.Text.Encoding]::UTF8.GetBytes("SubversionR M7h pristine sentinel"))
  [pscustomobject]@{
    svnRoot = $svnRoot
    wcDbPath = $wcDbPath
    beforeSha256 = (Get-FileHash -LiteralPath $wcDbPath -Algorithm SHA256).Hash.ToLowerInvariant()
    beforeTreeSha256 = Get-DirectoryTreeSha256 $svnRoot
  }
}

function Assert-WorkingCopySentinelUnchanged([object]$Sentinel) {
  if (-not (Test-Path -LiteralPath $Sentinel.wcDbPath -PathType Leaf)) {
    throw "Working-copy sentinel wc.db was removed: $($Sentinel.wcDbPath)"
  }
  $afterSha256 = (Get-FileHash -LiteralPath $Sentinel.wcDbPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($afterSha256 -ne $Sentinel.beforeSha256) {
    throw "Working-copy sentinel wc.db changed during installed Extension Host smoke."
  }
  $afterTreeSha256 = Get-DirectoryTreeSha256 $Sentinel.svnRoot
  if ($afterTreeSha256 -ne $Sentinel.beforeTreeSha256) {
    throw "Working-copy sentinel .svn tree changed during installed Extension Host smoke."
  }
  [pscustomobject]@{
    wcDbSha256 = $afterSha256
    treeSha256 = $afterTreeSha256
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

function Write-HarnessPackage([string]$HarnessRoot, [string]$ResultPath, [string]$ExtensionsRoot) {
  $distRoot = Join-Path $HarnessRoot "dist"
  New-Item -ItemType Directory -Force -Path $distRoot | Out-Null
  @'
{
  "name": "subversionr-installed-product-smoke-harness",
  "displayName": "SubversionR Installed Product Smoke Harness",
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

async function run() {
  const resultPath = process.env.SUBVERSIONR_INSTALLED_E2E_RESULT;
  const extensionsRoot = process.env.SUBVERSIONR_INSTALLED_E2E_EXTENSIONS_ROOT;
  const redactionReportToken = process.env.SUBVERSIONR_INSTALLED_E2E_REDACTION_REPORT_TOKEN;
  const remoteWorkerReportToken = process.env.SUBVERSIONR_INSTALLED_E2E_REMOTE_WORKER_REPORT_TOKEN;
  if (!resultPath || !extensionsRoot || !redactionReportToken || !remoteWorkerReportToken) {
    throw new Error("Required installed-host harness environment variables are missing.");
  }

  const extension = vscode.extensions.getExtension("hitsuki-ban.subversionr");
  if (!extension) {
    throw new Error("Installed SubversionR extension was not visible to Extension Host.");
  }

  const beforeActive = extension.isActive;
  await Promise.race([
    vscode.commands.executeCommand("subversionr.diagnostics.versionReport"),
    new Promise((_, reject) => setTimeout(() => reject(new Error("subversionr.diagnostics.versionReport timed out.")), 30000))
  ]);
  const commands = await vscode.commands.getCommands(true);
  const extensionAfterCommand = vscode.extensions.getExtension("hitsuki-ban.subversionr");
  const normalizedExtensionPath = path.resolve(extension.extensionPath).toLowerCase();
  const normalizedRoot = path.resolve(extensionsRoot).toLowerCase();
  if (!normalizedExtensionPath.startsWith(normalizedRoot + path.sep)) {
    throw new Error(`Installed extension path is outside isolated extensions root: ${extension.extensionPath}`);
  }
  if (normalizedExtensionPath.includes("prototype-harness") || normalizedExtensionPath.includes("installed-host-harness")) {
    throw new Error(`SubversionR must not be loaded from the harness path: ${extension.extensionPath}`);
  }
  if (beforeActive !== false) {
    throw new Error("SubversionR should not activate before the harness explicitly activates it.");
  }
  if (!extensionAfterCommand || !extensionAfterCommand.isActive) {
    throw new Error("SubversionR did not report active after version report command execution.");
  }
  if (!commands.includes("subversionr.diagnostics.versionReport")) {
    throw new Error("Installed SubversionR command subversionr.diagnostics.versionReport was not registered after activation.");
  }
  if (!commands.includes("subversionr.diagnostics.installedRedactionReport")) {
    throw new Error("Installed SubversionR command subversionr.diagnostics.installedRedactionReport was not registered after activation.");
  }
  if (!commands.includes("subversionr.diagnostics.installedRemoteWorkerReport")) {
    throw new Error("Installed SubversionR command subversionr.diagnostics.installedRemoteWorkerReport was not registered after activation.");
  }

  const versionReportDocument = vscode.workspace.textDocuments.find(document => document.uri.scheme === "svn-r-diagnostics");
  if (!versionReportDocument) {
    throw new Error("SubversionR version report readonly document was not opened.");
  }
  const versionReport = JSON.parse(versionReportDocument.getText());
  if (versionReport.kind !== "subversionr.versionReport") {
    throw new Error(`Unexpected version report kind: ${versionReport.kind}`);
  }
  if (!versionReport.extension || versionReport.extension.version !== extension.packageJSON.version) {
    throw new Error("Version report extension version did not match installed package version.");
  }
  if (!versionReport.backend || !["initialized", "unavailable"].includes(versionReport.backend.status)) {
    throw new Error("Version report backend status must be initialized or unavailable.");
  }

  const installedRedactionReport = await Promise.race([
    vscode.commands.executeCommand("subversionr.diagnostics.installedRedactionReport", { token: redactionReportToken }),
    new Promise((_, reject) => setTimeout(() => reject(new Error("subversionr.diagnostics.installedRedactionReport timed out.")), 30000))
  ]);
  if (!installedRedactionReport || installedRedactionReport.kind !== "subversionr.installedRedactionReport") {
    throw new Error("Installed redaction report must use the subversionr.installedRedactionReport schema.");
  }
  if (!installedRedactionReport.diagnosticsBundle || installedRedactionReport.diagnosticsBundle.kind !== "subversionr.diagnosticsBundle") {
    throw new Error("Installed redaction report must include a diagnostics bundle.");
  }
  if (!installedRedactionReport.operationFailureFixture || installedRedactionReport.operationFailureFixture.channel !== "SubversionR") {
    throw new Error("Installed redaction report must include the bounded SubversionR operation failure log fixture.");
  }
  if (!installedRedactionReport.operationFailureFixture.lines.some((line) => line.includes("SVN_ERR_WC_NOT_UP_TO_DATE"))) {
    throw new Error("Installed operation failure log must retain the safe libsvn cause.");
  }
  const redactionText = JSON.stringify(installedRedactionReport);
  for (const forbidden of ["hunter2", "abc123", "Alice", "example.com", ".svn/wc.db"]) {
    if (redactionText.includes(forbidden)) {
      throw new Error(`Installed redaction report leaked forbidden fixture token: ${forbidden}`);
    }
  }
  for (const marker of ["[REDACTED:url:", "[REDACTED:path:", "[REDACTED:secret]", "[REDACTED:repository-log]", "[REDACTED:source-content]"]) {
    if (!redactionText.includes(marker)) {
      throw new Error(`Installed redaction report is missing marker: ${marker}`);
    }
  }

  const installedRemoteWorkerReport = await Promise.race([
    vscode.commands.executeCommand("subversionr.diagnostics.installedRemoteWorkerReport", { token: remoteWorkerReportToken }),
    new Promise((_, reject) => setTimeout(() => reject(new Error("subversionr.diagnostics.installedRemoteWorkerReport timed out.")), 30000))
  ]);
  if (
    !installedRemoteWorkerReport ||
    installedRemoteWorkerReport.schemaVersion !== 3 ||
    installedRemoteWorkerReport.kind !== "subversionr.installedRemoteWorkerReport" ||
    installedRemoteWorkerReport.protocol?.major !== 1 ||
    installedRemoteWorkerReport.protocol?.minor !== 34 ||
    installedRemoteWorkerReport.remoteWorkerIsolation !== true ||
    installedRemoteWorkerReport.credentialLeaseSettlement !== true ||
    JSON.stringify(installedRemoteWorkerReport.remoteConnectionState?.stateUnion) !== JSON.stringify(["unchecked", "checking", "online", "attention", "unreachable", "indeterminate"]) ||
    installedRemoteWorkerReport.remoteConnectionState?.staleIncomingPreserved !== true ||
    installedRemoteWorkerReport.remoteConnectionState?.localProjectionUnchanged !== true ||
    installedRemoteWorkerReport.remoteConnectionState?.separateRecoveryOperation !== true ||
    installedRemoteWorkerReport.remoteConnectionState?.separateRecoveryDeadline !== true ||
    installedRemoteWorkerReport.remoteConnectionState?.recoveryGateEnforced !== true ||
    installedRemoteWorkerReport.remoteConnectionState?.terminalBlockedStateProjected !== true ||
    installedRemoteWorkerReport.remoteConnectionState?.cancellationSettledWithoutReprompt !== true ||
    installedRemoteWorkerReport.remoteConnectionState?.unknownFailureRedacted !== true ||
    installedRemoteWorkerReport.remoteConnectionState?.unrelatedRepositoryUnchanged !== true ||
    installedRemoteWorkerReport.remoteConnectionState?.localEventZeroNetwork !== true ||
    installedRemoteWorkerReport.transportResult !== "unsupportedAfterWorker" ||
    installedRemoteWorkerReport.sameLaneSubsequent !== true ||
    installedRemoteWorkerReport.subsequentDiagnostics !== true ||
    installedRemoteWorkerReport.credentialLeaseReport?.schemaVersion !== 1 ||
    installedRemoteWorkerReport.credentialLeaseReport?.kind !== "subversionr.installedCredentialLeaseReport" ||
    installedRemoteWorkerReport.credentialLeaseReport?.legacyBackgroundBlocked !== true ||
    installedRemoteWorkerReport.credentialLeaseReport?.legacyForegroundCleared !== true ||
    installedRemoteWorkerReport.credentialLeaseReport?.fixedStoredReuse !== true ||
    installedRemoteWorkerReport.credentialLeaseReport?.chooserMultiAccount !== true ||
    installedRemoteWorkerReport.credentialLeaseReport?.promptSingleFlight !== true ||
    installedRemoteWorkerReport.credentialLeaseReport?.independentLeases !== true ||
    JSON.stringify(installedRemoteWorkerReport.credentialLeaseReport?.settlementOutcomes) !== JSON.stringify(["accepted", "rejected", "unused", "cancelled", "timedOut"]) ||
    installedRemoteWorkerReport.credentialLeaseReport?.duplicateSettlementIdempotent !== true ||
    installedRemoteWorkerReport.credentialLeaseReport?.conflictingSettlementRejected !== true ||
    installedRemoteWorkerReport.credentialLeaseReport?.reloadDiscardedPendingLease !== true ||
    installedRemoteWorkerReport.credentialLeaseReport?.storageCleanup !== true
  ) {
    throw new Error("Installed remote worker report did not prove the v1.34 isolated worker, remote connection state, credential lease lifecycle, same-lane recovery, and follow-up request.");
  }
  const credentialEvidenceText = JSON.stringify(installedRemoteWorkerReport.credentialLeaseReport);
  for (const forbidden of ["alice", "bob", "charlie", "installed-evidence-secret", "svn.example.invalid", "SubversionR installed credential evidence"]) {
    if (credentialEvidenceText.includes(forbidden)) {
      throw new Error(`Installed credential lease report leaked forbidden fixture token: ${forbidden}`);
    }
  }

  fs.writeFileSync(resultPath, JSON.stringify({
    id: extension.id,
    version: extension.packageJSON.version,
    beforeActive,
    afterActive: extensionAfterCommand.isActive,
    extensionPath: extension.extensionPath,
    invokedCommand: "subversionr.diagnostics.versionReport",
    redactionCommand: "subversionr.diagnostics.installedRedactionReport",
    remoteWorkerCommand: "subversionr.diagnostics.installedRemoteWorkerReport",
    hasVersionReportCommand: true,
    hasInstalledRedactionReportCommand: true,
    hasInstalledRemoteWorkerReportCommand: true,
    source: "installed-vsix",
    versionReport,
    installedRedactionReport,
    installedRemoteWorkerReport
  }, null, 2));
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
  }
}

function Assert-HarnessResult(
  [object]$Result,
  [string]$ExpectedVersion,
  [string]$ExtensionsRoot,
  [string]$InstalledPackageRoot
) {
  if ($Result.id -ne "hitsuki-ban.subversionr") {
    throw "Installed-host result extension id must be hitsuki-ban.subversionr."
  }
  if ($Result.version -ne $ExpectedVersion) {
    throw "Installed-host result extension version must be $ExpectedVersion."
  }
  if ($Result.source -ne "installed-vsix") {
    throw "Installed-host result source must be installed-vsix."
  }
  if ($Result.beforeActive -ne $false -or $Result.afterActive -ne $true) {
    throw "Installed-host version-report result must prove explicit activation from inactive to active."
  }
  if ($Result.invokedCommand -ne "subversionr.diagnostics.versionReport" -or $Result.hasVersionReportCommand -ne $true) {
    throw "Installed-host result must prove version report command execution."
  }
  if ($Result.redactionCommand -ne "subversionr.diagnostics.installedRedactionReport" -or $Result.hasInstalledRedactionReportCommand -ne $true) {
    throw "Installed-host result must prove installed redaction report command execution."
  }
  if ($Result.remoteWorkerCommand -ne "subversionr.diagnostics.installedRemoteWorkerReport" -or $Result.hasInstalledRemoteWorkerReportCommand -ne $true) {
    throw "Installed-host result must prove installed remote worker report command execution."
  }
  if ($Result.versionReport.kind -ne "subversionr.versionReport") {
    throw "Installed-host result must include a SubversionR version report."
  }
  if ($Result.versionReport.extension.version -ne $ExpectedVersion) {
    throw "Installed-host version report extension version must match the installed VSIX."
  }
  if ($Result.versionReport.backend.status -notin @("initialized", "unavailable")) {
    throw "Installed-host version report backend status must be initialized or unavailable."
  }
  if ($Result.installedRedactionReport.kind -ne "subversionr.installedRedactionReport") {
    throw "Installed-host result must include an installed redaction report."
  }
  if ($Result.installedRedactionReport.diagnosticsBundle.kind -ne "subversionr.diagnosticsBundle") {
    throw "Installed-host installed redaction report must include a diagnostics bundle."
  }
  if ($Result.installedRedactionReport.publicSupportFixture.status -ne "redacted") {
    throw "Installed-host public support fixture must be redacted."
  }
  if ($Result.installedRedactionReport.schemaVersion -ne 2 -or $Result.installedRedactionReport.operationFailureFixture.channel -ne "SubversionR") {
    throw "Installed-host redaction report must include the v2 SubversionR operation failure fixture."
  }
  if (-not (($Result.installedRedactionReport.operationFailureFixture.lines -join "`n").Contains("SVN_ERR_WC_NOT_UP_TO_DATE"))) {
    throw "Installed-host operation failure fixture must retain the safe libsvn cause."
  }
  $installedRedactionText = $Result.installedRedactionReport | ConvertTo-Json -Depth 20
  foreach ($forbidden in @("hunter2", "abc123", "Alice", "example.com", ".svn/wc.db")) {
    if ($installedRedactionText.Contains($forbidden)) {
      throw "Installed-host installed redaction report leaked forbidden fixture token: $forbidden"
    }
  }
  foreach ($marker in @("[REDACTED:url:", "[REDACTED:path:", "[REDACTED:secret]", "[REDACTED:repository-log]", "[REDACTED:source-content]")) {
    if (-not $installedRedactionText.Contains($marker)) {
      throw "Installed-host installed redaction report is missing marker: $marker"
    }
  }
  if (
    $Result.installedRemoteWorkerReport.schemaVersion -ne 3 -or
    $Result.installedRemoteWorkerReport.kind -ne "subversionr.installedRemoteWorkerReport" -or
    $Result.installedRemoteWorkerReport.protocol.major -ne 1 -or
    $Result.installedRemoteWorkerReport.protocol.minor -ne 34 -or
    $Result.installedRemoteWorkerReport.remoteWorkerIsolation -ne $true -or
    $Result.installedRemoteWorkerReport.credentialLeaseSettlement -ne $true -or
    $Result.installedRemoteWorkerReport.remoteConnectionState.staleIncomingPreserved -ne $true -or
    $Result.installedRemoteWorkerReport.remoteConnectionState.localProjectionUnchanged -ne $true -or
    $Result.installedRemoteWorkerReport.remoteConnectionState.separateRecoveryOperation -ne $true -or
    $Result.installedRemoteWorkerReport.remoteConnectionState.separateRecoveryDeadline -ne $true -or
    $Result.installedRemoteWorkerReport.remoteConnectionState.recoveryGateEnforced -ne $true -or
    $Result.installedRemoteWorkerReport.remoteConnectionState.terminalBlockedStateProjected -ne $true -or
    $Result.installedRemoteWorkerReport.remoteConnectionState.cancellationSettledWithoutReprompt -ne $true -or
    $Result.installedRemoteWorkerReport.remoteConnectionState.unknownFailureRedacted -ne $true -or
    $Result.installedRemoteWorkerReport.remoteConnectionState.unrelatedRepositoryUnchanged -ne $true -or
    $Result.installedRemoteWorkerReport.remoteConnectionState.localEventZeroNetwork -ne $true -or
    $Result.installedRemoteWorkerReport.transportResult -ne "unsupportedAfterWorker" -or
    $Result.installedRemoteWorkerReport.sameLaneSubsequent -ne $true -or
    $Result.installedRemoteWorkerReport.subsequentDiagnostics -ne $true -or
    $Result.installedRemoteWorkerReport.credentialLeaseReport.schemaVersion -ne 1 -or
    $Result.installedRemoteWorkerReport.credentialLeaseReport.kind -ne "subversionr.installedCredentialLeaseReport" -or
    $Result.installedRemoteWorkerReport.credentialLeaseReport.legacyBackgroundBlocked -ne $true -or
    $Result.installedRemoteWorkerReport.credentialLeaseReport.legacyForegroundCleared -ne $true -or
    $Result.installedRemoteWorkerReport.credentialLeaseReport.fixedStoredReuse -ne $true -or
    $Result.installedRemoteWorkerReport.credentialLeaseReport.chooserMultiAccount -ne $true -or
    $Result.installedRemoteWorkerReport.credentialLeaseReport.promptSingleFlight -ne $true -or
    $Result.installedRemoteWorkerReport.credentialLeaseReport.independentLeases -ne $true -or
    $Result.installedRemoteWorkerReport.credentialLeaseReport.duplicateSettlementIdempotent -ne $true -or
    $Result.installedRemoteWorkerReport.credentialLeaseReport.conflictingSettlementRejected -ne $true -or
    $Result.installedRemoteWorkerReport.credentialLeaseReport.reloadDiscardedPendingLease -ne $true -or
    $Result.installedRemoteWorkerReport.credentialLeaseReport.storageCleanup -ne $true
  ) {
    throw "Installed-host result must prove the v1.34 isolated remote worker, remote connection state, credential lease lifecycle, same-lane recovery, and a subsequent diagnostics request."
  }
  $remoteStateUnion = @($Result.installedRemoteWorkerReport.remoteConnectionState.stateUnion)
  if (($remoteStateUnion -join ",") -ne "unchecked,checking,online,attention,unreachable,indeterminate") {
    throw "Installed remote connection evidence must prove the exact six-state union."
  }
  $settlementOutcomes = @($Result.installedRemoteWorkerReport.credentialLeaseReport.settlementOutcomes)
  if (($settlementOutcomes -join ",") -ne "accepted,rejected,unused,cancelled,timedOut") {
    throw "Installed credential lease report must prove every settlement outcome."
  }
  $installedCredentialText = $Result.installedRemoteWorkerReport.credentialLeaseReport | ConvertTo-Json -Depth 20
  foreach ($forbidden in @("alice", "bob", "charlie", "installed-evidence-secret", "svn.example.invalid", "SubversionR installed credential evidence")) {
    if ($installedCredentialText.Contains($forbidden)) {
      throw "Installed credential lease report leaked forbidden fixture token: $forbidden"
    }
  }
  $extensionPath = [string]$Result.extensionPath
  if (-not (Test-IsPathWithin -Path $extensionPath -Root $ExtensionsRoot)) {
    throw "Installed-host result extension path must be under the isolated extensions root."
  }
  if (-not (Test-IsSamePath -Left $extensionPath -Right $InstalledPackageRoot)) {
    throw "Installed-host result extension path must match the installed VSIX package root."
  }
}

$vsixResolved = Assert-GeneratedPath -Path $VsixPath -Name "VsixPath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\vsix")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-installed-extension-host-scripts"))
) -Description "target/vsix or target/tests/release-installed-extension-host-scripts"
$vsixResolved = Assert-File $vsixResolved "VsixPath"
$codeCliResolved = Assert-CodeCliPath $CodeCliPath
$fixtureRootResolved = Assert-GeneratedPath -Path $FixtureRoot -Name "FixtureRoot" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence\installed-extension-host")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-installed-extension-host-scripts"))
) -Description "the repository target directory (target/release-evidence/installed-extension-host or target/tests/release-installed-extension-host-scripts)"
$aggregateFixtureRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence\installed-extension-host"))
if (Test-IsSamePath -Left $fixtureRootResolved -Right $aggregateFixtureRoot) {
  throw "FixtureRoot must include a dedicated child directory below target/release-evidence/installed-extension-host."
}
$evidencePathResolved = Assert-GeneratedPath -Path $EvidencePath -Name "EvidencePath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-installed-extension-host-scripts"))
) -Description "target/release-evidence or target/tests/release-installed-extension-host-scripts"

if (Test-Path -LiteralPath $fixtureRootResolved) {
  Remove-Item -LiteralPath $fixtureRootResolved -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $fixtureRootResolved | Out-Null

$userDataRoot = Join-Path $fixtureRootResolved "user-data"
$extensionsRoot = Join-Path $fixtureRootResolved "extensions"
$workspaceRoot = Join-Path $fixtureRootResolved "workspace"
$workingCopySentinelRoot = Join-Path $fixtureRootResolved "working-copy-sentinel"
$harnessRoot = Join-Path $fixtureRootResolved "installed-host-harness"
$harnessResultPath = Join-Path $fixtureRootResolved "installed-host-result.json"
New-Item -ItemType Directory -Force -Path $userDataRoot | Out-Null
New-Item -ItemType Directory -Force -Path $extensionsRoot | Out-Null
New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
$sentinel = New-WorkingCopySentinel -Root $workingCopySentinelRoot

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

$harness = Write-HarnessPackage -HarnessRoot $harnessRoot -ResultPath $harnessResultPath -ExtensionsRoot $extensionsRoot
$previousResultEnv = Get-ProcessEnvironmentValue "SUBVERSIONR_INSTALLED_E2E_RESULT"
$previousExtensionsRootEnv = Get-ProcessEnvironmentValue "SUBVERSIONR_INSTALLED_E2E_EXTENSIONS_ROOT"
$previousRedactionReportTokenEnv = Get-ProcessEnvironmentValue "SUBVERSIONR_INSTALLED_E2E_REDACTION_REPORT_TOKEN"
$previousRemoteWorkerReportTokenEnv = Get-ProcessEnvironmentValue "SUBVERSIONR_INSTALLED_E2E_REMOTE_WORKER_REPORT_TOKEN"
$env:SUBVERSIONR_INSTALLED_E2E_RESULT = $harness.ResultPath
$env:SUBVERSIONR_INSTALLED_E2E_EXTENSIONS_ROOT = $harness.ExtensionsRoot
$env:SUBVERSIONR_INSTALLED_E2E_REDACTION_REPORT_TOKEN = [Guid]::NewGuid().ToString("N")
$env:SUBVERSIONR_INSTALLED_E2E_REMOTE_WORKER_REPORT_TOKEN = [Guid]::NewGuid().ToString("N")
try {
  Invoke-CodeCliWithTimeout -Path $codeCliResolved -Arguments @(
    "--user-data-dir",
    $userDataRoot,
    "--extensions-dir",
    $extensionsRoot,
    "--disable-workspace-trust",
    "--new-window",
    "--extensionDevelopmentPath=$($harness.Root)",
    "--extensionTestsPath=$($harness.TestsPath)",
    "--log",
    "trace",
    "--wait",
    $workspaceRoot
  ) -TimeoutSeconds $ExtensionHostTimeoutSeconds -Description "VS Code installed Extension Host version-report smoke"
}
finally {
  Restore-ProcessEnvironmentValue "SUBVERSIONR_INSTALLED_E2E_RESULT" $previousResultEnv
  Restore-ProcessEnvironmentValue "SUBVERSIONR_INSTALLED_E2E_EXTENSIONS_ROOT" $previousExtensionsRootEnv
  Restore-ProcessEnvironmentValue "SUBVERSIONR_INSTALLED_E2E_REDACTION_REPORT_TOKEN" $previousRedactionReportTokenEnv
  Restore-ProcessEnvironmentValue "SUBVERSIONR_INSTALLED_E2E_REMOTE_WORKER_REPORT_TOKEN" $previousRemoteWorkerReportTokenEnv
}

if (-not (Test-Path -LiteralPath $harnessResultPath -PathType Leaf)) {
  throw "Installed Extension Host harness did not write the expected result file."
}
$harnessResult = Get-Content -Raw -LiteralPath $harnessResultPath | ConvertFrom-Json
Assert-HarnessResult -Result $harnessResult -ExpectedVersion $extensionVersion -ExtensionsRoot $extensionsRoot -InstalledPackageRoot $installedPackageRoot
$sentinelAfter = Assert-WorkingCopySentinelUnchanged -Sentinel $sentinel

$report = [pscustomobject]@{
  schemaVersion = 3
  schema = "subversionr.release.installed-extension-host.win32-x64.v3"
  publicReadinessClaim = $false
  target = $Target
  traceIds = @("MIG-009", "TST-024")
  extension = [pscustomobject]@{
    id = "hitsuki-ban.subversionr"
    version = $extensionVersion
    source = "installed-vsix"
    installedPackageRoot = Get-RepoRelativePath $installedPackageRoot
    extensionHostPath = Get-RepoRelativePath ([string]$harnessResult.extensionPath)
    beforeActive = [bool]$harnessResult.beforeActive
    afterActive = [bool]$harnessResult.afterActive
    invokedCommand = [string]$harnessResult.invokedCommand
    redactionCommand = [string]$harnessResult.redactionCommand
    remoteWorkerCommand = [string]$harnessResult.remoteWorkerCommand
    hasVersionReportCommand = [bool]$harnessResult.hasVersionReportCommand
    hasInstalledRedactionReportCommand = [bool]$harnessResult.hasInstalledRedactionReportCommand
    hasInstalledRemoteWorkerReportCommand = [bool]$harnessResult.hasInstalledRemoteWorkerReportCommand
  }
  versionReport = $harnessResult.versionReport
  installedRedactionReport = $harnessResult.installedRedactionReport
  installedRemoteWorkerReport = $harnessResult.installedRemoteWorkerReport
  codeCli = [pscustomobject]@{
    path = $codeCliResolved
    sha256 = $codeCliSha256
    versionOutput = $codeCliVersion
  }
  vsix = [pscustomobject]@{
    path = $vsixResolved
    relativePath = Get-RepoRelativePath $vsixResolved
    targetPlatform = $manifestTargetPlatform
    sha256 = (Get-FileHash -LiteralPath $vsixResolved -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  fixtureRoots = [pscustomobject]@{
    root = Get-RepoRelativePath $fixtureRootResolved
    userData = Get-RepoRelativePath $userDataRoot
    extensions = Get-RepoRelativePath $extensionsRoot
    workspace = Get-RepoRelativePath $workspaceRoot
    workingCopySentinel = Get-RepoRelativePath $workingCopySentinelRoot
    harness = Get-RepoRelativePath $harnessRoot
  }
  installedExtensions = $installedExtensions
  workingCopySentinel = [pscustomobject]@{
    path = Get-RepoRelativePath $sentinel.wcDbPath
    beforeSha256 = $sentinel.beforeSha256
    afterSha256 = $sentinelAfter.wcDbSha256
    svnTreeBeforeSha256 = $sentinel.beforeTreeSha256
    svnTreeAfterSha256 = $sentinelAfter.treeSha256
    mutation = "none"
  }
  assertions = @(
    "VSIX was installed into an isolated extensions directory",
    "VSIX manifest TargetPlatform matched the requested release target",
    "SubversionR was loaded from the installed VSIX package root, not from the harness extension",
    "SubversionR was inactive before explicit version report command execution",
    "SubversionR became active inside a real VS Code Extension Host",
    "SubversionR version report command executed and opened a readonly report document",
    "SubversionR installed redaction report command executed and returned a redacted diagnostics bundle",
    "SubversionR installed remote worker report proved protocol v1.34 isolation, remote connection state, credential settlement, transport boundary, same-lane recovery, and subsequent diagnostics",
    "working-copy sentinel .svn tree hash was unchanged",
    "publicReadinessClaim remains false"
  )
}

$evidenceParent = Split-Path -Parent $evidencePathResolved
New-Item -ItemType Directory -Force -Path $evidenceParent | Out-Null
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $evidencePathResolved -Encoding utf8

Write-Host "Verified SubversionR installed VSIX Extension Host version-report smoke for $Target at $fixtureRootResolved."

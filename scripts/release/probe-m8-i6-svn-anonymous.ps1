[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string]$RepositoryUrl,
  [Parameter(Mandatory = $true)] [string]$FixtureRoot,
  [Parameter(Mandatory = $true)] [string]$FixtureConfigPath,
  [Parameter(Mandatory = $true)] [string]$FixtureAuthzPath,
  [Parameter(Mandatory = $true)] [string]$SvnPath,
  [Parameter(Mandatory = $true)] [string]$SvnadminPath,
  [Parameter(Mandatory = $true)] [string]$SvnservePath,
  [Parameter(Mandatory = $true)] [string]$VsixPath,
  [Parameter(Mandatory = $true)] [string]$DaemonPath,
  [Parameter(Mandatory = $true)] [string]$BridgePath,
  [Parameter(Mandatory = $true)] [string]$CodeCliPath,
  [Parameter(Mandatory = $true)] [string]$StageManifestPath,
  [Parameter(Mandatory = $true)] [string]$RaSvnOriginPatchPath,
  [Parameter(Mandatory = $true)] [string]$RaSvnOriginContractPath,
  [Parameter(Mandatory = $true)] [string]$NativeSourceLockPath,
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
  [string]$ExpectedProductVersion,
  [Parameter(Mandatory = $true)] [string]$OutputPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$packagedProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-vscode-packaged-native.mjs"))
$installedHarnessPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "test-vscode-installed-extension-host.ps1"))
$installedI6ProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-installed-vsix.ps1"))
$installedHarnessRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence\installed-extension-host"))

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw $Message
  }
}

function Resolve-RequiredFile([string]$Path, [string]$Name) {
  Assert-True ([System.IO.Path]::IsPathFullyQualified($Path)) "$Name must be an absolute path."
  $resolved = [System.IO.Path]::GetFullPath($Path)
  Assert-True (Test-Path -LiteralPath $resolved -PathType Leaf) "$Name must be an existing file."
  return $resolved
}

function Resolve-RequiredDirectory([string]$Path, [string]$Name) {
  Assert-True ([System.IO.Path]::IsPathFullyQualified($Path)) "$Name must be an absolute path."
  $resolved = [System.IO.Path]::GetFullPath($Path)
  Assert-True (Test-Path -LiteralPath $resolved -PathType Container) "$Name must be an existing directory."
  return $resolved
}

function Test-PathWithin([string]$Path, [string]$Root) {
  $pathResolved = [System.IO.Path]::GetFullPath($Path)
  $rootResolved = [System.IO.Path]::GetFullPath($Root).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  ) + [System.IO.Path]::DirectorySeparatorChar
  return $pathResolved.StartsWith($rootResolved, [System.StringComparison]::OrdinalIgnoreCase)
}

function Resolve-FixtureFile([string]$Path, [string]$Name, [string]$Root) {
  $resolved = Resolve-RequiredFile $Path $Name
  Assert-True (Test-PathWithin $resolved $Root) "$Name must be below FixtureRoot."
  return $resolved
}

function Get-Sha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ZipEntry([System.IO.Compression.ZipArchive]$Archive, [string]$Name) {
  $entries = @($Archive.Entries | Where-Object { $_.FullName -ceq $Name })
  Assert-True ($entries.Count -eq 1) "VsixPath must contain exactly one '$Name' entry."
  return $entries[0]
}

function Get-ZipEntrySha256([System.IO.Compression.ZipArchiveEntry]$Entry) {
  $stream = $Entry.Open()
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = $sha.ComputeHash($stream)
    return [Convert]::ToHexString($bytes).ToLowerInvariant()
  }
  finally {
    $sha.Dispose()
    $stream.Dispose()
  }
}

function Read-ZipEntryText([System.IO.Compression.ZipArchiveEntry]$Entry) {
  $stream = $Entry.Open()
  $reader = [System.IO.StreamReader]::new(
    $stream,
    [System.Text.UTF8Encoding]::new($false, $true),
    $true,
    4096,
    $false
  )
  try {
    return $reader.ReadToEnd()
  }
  finally {
    $reader.Dispose()
  }
}

function Invoke-BoundedProcess(
  [string]$FilePath,
  [string[]]$Arguments,
  [int]$TimeoutSeconds,
  [hashtable]$Environment = @{}
) {
  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FilePath
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  foreach ($argument in $Arguments) {
    $startInfo.ArgumentList.Add($argument)
  }
  foreach ($entry in $Environment.GetEnumerator()) {
    $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
  }

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  try {
    Assert-True $process.Start() "Failed to start the controlled probe process."
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      $process.Kill($true)
      $process.WaitForExit()
      throw "Controlled probe process exceeded its absolute deadline."
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    Assert-True ($stdout.Length -le 65536) "Controlled probe stdout exceeded 65536 bytes."
    Assert-True ($stderr.Length -le 32768) "Controlled probe stderr exceeded 32768 bytes."
    return [pscustomobject]@{
      ExitCode = $process.ExitCode
      Stdout = $stdout
      Stderr = $stderr
    }
  }
  finally {
    $process.Dispose()
  }
}

function Resolve-CodeNodeHost([string]$CodePath) {
  $leaf = [System.IO.Path]::GetFileName($CodePath)
  if ($leaf.Equals("code.exe", [System.StringComparison]::OrdinalIgnoreCase)) {
    return $CodePath
  }
  Assert-True ($leaf.Equals("code.cmd", [System.StringComparison]::OrdinalIgnoreCase)) "CodeCliPath must point to code.cmd or code.exe."
  $candidate = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $CodePath) "..\Code.exe"))
  Assert-True (Test-Path -LiteralPath $candidate -PathType Leaf) "CodeCliPath must identify a VS Code installation with an adjacent Code.exe Node host."
  return $candidate
}

function Assert-ToolVersion([string]$ToolPath, [string]$Name) {
  $result = Invoke-BoundedProcess $ToolPath @("--version", "--quiet") 15
  Assert-True ($result.ExitCode -eq 0) "$Name version check failed."
  $lines = @($result.Stdout.Trim() -split '\r?\n')
  Assert-True ($lines.Count -ge 1 -and $lines[0] -ceq "1.14.5") "$Name must be source-built Apache Subversion 1.14.5."
}

function Convert-JsonObject([string]$Text, [string]$Name) {
  try {
    $value = $Text | ConvertFrom-Json -Depth 64
  }
  catch {
    throw "$Name must contain one valid JSON document."
  }
  Assert-True ($null -ne $value) "$Name must contain one valid JSON document."
  return $value
}

$fixtureRootResolved = Resolve-RequiredDirectory $FixtureRoot "FixtureRoot"
Assert-True ([System.IO.Path]::IsPathFullyQualified($OutputPath)) "OutputPath must be an absolute path."
$outputResolved = [System.IO.Path]::GetFullPath($OutputPath)
Assert-True (Test-PathWithin $outputResolved $fixtureRootResolved) "OutputPath must be below FixtureRoot."
Assert-True (-not $outputResolved.Equals($fixtureRootResolved, [System.StringComparison]::OrdinalIgnoreCase)) "OutputPath must name a file below FixtureRoot."
if (Test-Path -LiteralPath $outputResolved) {
  Assert-True (Test-Path -LiteralPath $outputResolved -PathType Leaf) "OutputPath must not be an existing directory."
  Remove-Item -LiteralPath $outputResolved -Force
}

$fixtureConfigResolved = Resolve-FixtureFile $FixtureConfigPath "FixtureConfigPath" $fixtureRootResolved
$fixtureAuthzResolved = Resolve-FixtureFile $FixtureAuthzPath "FixtureAuthzPath" $fixtureRootResolved
$svnResolved = Resolve-RequiredFile $SvnPath "SvnPath"
$svnadminResolved = Resolve-RequiredFile $SvnadminPath "SvnadminPath"
$svnserveResolved = Resolve-RequiredFile $SvnservePath "SvnservePath"
$vsixResolved = Resolve-RequiredFile $VsixPath "VsixPath"
$daemonResolved = Resolve-RequiredFile $DaemonPath "DaemonPath"
$bridgeResolved = Resolve-RequiredFile $BridgePath "BridgePath"
$codeCliResolved = Resolve-RequiredFile $CodeCliPath "CodeCliPath"
$stageManifestResolved = Resolve-RequiredFile $StageManifestPath "StageManifestPath"
$patchResolved = Resolve-RequiredFile $RaSvnOriginPatchPath "RaSvnOriginPatchPath"
$patchContractResolved = Resolve-RequiredFile $RaSvnOriginContractPath "RaSvnOriginContractPath"
$sourceLockResolved = Resolve-RequiredFile $NativeSourceLockPath "NativeSourceLockPath"
$packagedProbeResolved = Resolve-RequiredFile $packagedProbePath "packaged native probe"
$installedHarnessResolved = Resolve-RequiredFile $installedHarnessPath "installed Extension Host harness"
$installedI6ProbeResolved = Resolve-RequiredFile $installedI6ProbePath "installed I6 Extension Host probe"

try {
  $repositoryUri = [System.Uri]::new($RepositoryUrl, [System.UriKind]::Absolute)
}
catch {
  throw "RepositoryUrl must be an absolute direct svn:// URL."
}
Assert-True ($repositoryUri.Scheme -ceq "svn") "RepositoryUrl must use direct svn:// transport."
Assert-True ($repositoryUri.Host -ceq "127.0.0.1") "RepositoryUrl must use the controlled IPv4 loopback host."
Assert-True ([string]::IsNullOrEmpty($repositoryUri.UserInfo)) "RepositoryUrl must not contain user information."
Assert-True ([string]::IsNullOrEmpty($repositoryUri.Query) -and [string]::IsNullOrEmpty($repositoryUri.Fragment)) "RepositoryUrl must not contain a query or fragment."

$expectedConfig = "[general]`nanon-access = write`nauth-access = none`nauthz-db = authz`nrealm = SubversionR I6 Controlled Anonymous`n[sasl]`nuse-sasl = false"
$actualConfig = (Get-Content -Raw -LiteralPath $fixtureConfigResolved).Replace("`r`n", "`n")
Assert-True ($actualConfig -ceq $expectedConfig) "FixtureConfigPath must contain the exact controlled anonymous svnserve configuration."
$expectedAuthz = "[repo:/]`n* = rw"
$actualAuthz = (Get-Content -Raw -LiteralPath $fixtureAuthzResolved).Replace("`r`n", "`n")
Assert-True ($actualAuthz -ceq $expectedAuthz) "FixtureAuthzPath must contain the exact controlled anonymous write authz."

$null = Convert-JsonObject (Get-Content -Raw -LiteralPath $stageManifestResolved) "StageManifestPath"
$null = Convert-JsonObject (Get-Content -Raw -LiteralPath $sourceLockResolved) "NativeSourceLockPath"
$patchContract = Convert-JsonObject (Get-Content -Raw -LiteralPath $patchContractResolved) "RaSvnOriginContractPath"
Assert-True ([int]$patchContract.schemaVersion -eq 1) "RaSvnOriginContractPath schemaVersion must be 1."
Assert-True ([string]$patchContract.source.version -ceq "1.14.5") "RaSvnOriginContractPath must bind Apache Subversion 1.14.5."
Assert-True ([string]$patchContract.patch.sha256 -ceq (Get-Sha256 $patchResolved)) "RaSvnOriginContractPath must bind the exact ra_svn patch bytes."

$archive = $null
try {
  try {
    $archive = [System.IO.Compression.ZipFile]::OpenRead($vsixResolved)
  }
  catch {
    throw "VsixPath must be a valid VSIX ZIP archive."
  }
  $packageEntry = Get-ZipEntry $archive "extension/package.json"
  $backendModuleEntry = Get-ZipEntry $archive "extension/dist/backend/backendProcess.js"
  $daemonEntry = Get-ZipEntry $archive "extension/resources/backend/win32-x64/subversionr-daemon.exe"
  $bridgeEntry = Get-ZipEntry $archive "extension/resources/backend/win32-x64/subversionr_svn_bridge.dll"
  $package = Convert-JsonObject (Read-ZipEntryText $packageEntry) "VSIX extension/package.json"
  Assert-True ([string]$package.version -ceq $ExpectedProductVersion) "VSIX product version must match ExpectedProductVersion."
  Assert-True ((Get-ZipEntrySha256 $daemonEntry) -ceq (Get-Sha256 $daemonResolved)) "DaemonPath must match the daemon embedded in VsixPath."
  Assert-True ((Get-ZipEntrySha256 $bridgeEntry) -ceq (Get-Sha256 $bridgeResolved)) "BridgePath must match the bridge embedded in VsixPath."
  Assert-True ($backendModuleEntry.Length -gt 0) "VSIX packaged backend module must not be empty."
}
finally {
  if ($null -ne $archive) {
    $archive.Dispose()
  }
}

Assert-ToolVersion $svnResolved "SvnPath"
Assert-ToolVersion $svnadminResolved "SvnadminPath"
Assert-ToolVersion $svnserveResolved "SvnservePath"

$probeRoot = Join-Path $fixtureRootResolved "product-probe"
$extractedVsixRoot = Join-Path $probeRoot "vsix"
$packagedWorkspaceRoot = Join-Path $probeRoot "packaged-workspace"
$packagedCacheRoot = Join-Path $probeRoot "packaged-cache"
$packagedProfileRoot = Join-Path $probeRoot "packaged-profile"
$compatWorkspaceRoot = Join-Path $probeRoot "compat-workspace"
$compatCacheRoot = Join-Path $probeRoot "compat-cache"
$compatProfileRoot = Join-Path $probeRoot "compat-profile"
foreach ($path in @(
    $probeRoot,
    $extractedVsixRoot,
    $packagedWorkspaceRoot,
    $packagedCacheRoot,
    $packagedProfileRoot,
    $compatWorkspaceRoot,
    $compatCacheRoot,
    $compatProfileRoot
  )) {
  if ($path -eq $probeRoot -and (Test-Path -LiteralPath $path)) {
    Remove-Item -LiteralPath $path -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $path | Out-Null
}
[System.IO.Compression.ZipFile]::ExtractToDirectory($vsixResolved, $extractedVsixRoot)
$backendModulePath = Resolve-RequiredFile (Join-Path $extractedVsixRoot "extension\dist\backend\backendProcess.js") "packaged VSIX backend module"
$nodeHost = Resolve-CodeNodeHost $codeCliResolved

$packagedI6ProbeResolved = Resolve-RequiredFile (Join-Path $PSScriptRoot "probe-m8-i6-packaged-native.mjs") "packaged-native I6 positive probe"
$seedWorkingCopy = Resolve-RequiredDirectory (Join-Path $fixtureRootResolved "seed-wc") "I6 seed working copy"
$oracleConfigRoot = Resolve-RequiredDirectory (Join-Path $fixtureRootResolved "fixture-cli-config") "I6 fixture CLI configuration"
Add-Content -LiteralPath (Join-Path $seedWorkingCopy "tracked.txt") -Value "SubversionR I6 controlled r3 update fixture"
$seedCommitResult = Invoke-BoundedProcess $svnResolved @(
  "commit", $seedWorkingCopy,
  "-m", "advance I6 controlled fixture to r3",
  "--non-interactive", "--no-auth-cache", "--config-dir", $oracleConfigRoot
) 30
Assert-True ($seedCommitResult.ExitCode -eq 0) "The controlled fixture could not advance to r3 for the packaged update observation."

$positiveTargetPath = Join-Path $packagedWorkspaceRoot "packaged-i6-wc"
$positiveResult = Invoke-BoundedProcess $nodeHost @(
  $packagedI6ProbeResolved,
  "--backend-module", $backendModulePath,
  "--daemon", $daemonResolved,
  "--bridge", $bridgeResolved,
  "--profile-root", (Join-Path $packagedProfileRoot "i6-positive"),
  "--checkout-target", $positiveTargetPath,
  "--repository-url", $RepositoryUrl,
  "--checkout-revision", "2"
) 300 @{ ELECTRON_RUN_AS_NODE = "1" }
$positiveReport = Convert-JsonObject $positiveResult.Stdout.Trim() "packaged-native I6 positive probe stdout"
$positiveFailure = if ($null -ne $positiveReport.error -and $null -ne $positiveReport.error.diagnostics) {
  "$([string]$positiveReport.error.code) / $([string]$positiveReport.error.diagnostics.cause) / $(@($positiveReport.error.diagnostics.names) -join ',')"
}
elseif ($null -ne $positiveReport.error) {
  [string]$positiveReport.error.code
}
else {
  "unknown"
}
Assert-True ($positiveResult.ExitCode -eq 0) "The packaged-native I6 positive operation matrix failed against the candidate artifacts: $positiveFailure."
$expectedPositiveOperations = @("checkoutOpen", "remoteStatus", "content", "historyLog", "historyBlame", "update", "commit", "branchCopy", "switch", "lock", "unlock")
Assert-True ([string]$positiveReport.schema -ceq "subversionr.release.m8-i6-packaged-native-positive.v1") "The packaged-native I6 positive probe returned an unexpected schema."
Assert-True ([string]$positiveReport.status -ceq "passed") "The packaged-native I6 positive probe did not pass."
Assert-True ((@($positiveReport.operations.operation) -join ",") -ceq ($expectedPositiveOperations -join ",")) "The packaged-native I6 positive probe did not execute the exact operation matrix."
Assert-True ($positiveReport.remoteSvnAnonymous -eq $true -and [int]$positiveReport.fixtureCliInvocations -eq 0) "The packaged-native I6 positive probe did not preserve anonymous native-only execution."
foreach ($operation in @($positiveReport.operations)) {
  Assert-True (
    [string]$operation.status -ceq "passed" -and
    [string]$operation.serverAuth -ceq "anonymous" -and
    [int]$operation.promptCount -eq 0 -and
    [string]$operation.credentialSettlement -ceq "none" -and
    [string]$operation.reconcile -ceq "fresh" -and
    [int]$operation.workerDescendantsAfter -eq 0 -and
    [int]$operation.temporaryRootsAfter -eq 0 -and
    $operation.nativeLaneReleased -eq $true -and
    $operation.diagnosticsRedacted -eq $true
  ) "The packaged-native I6 positive probe returned an incomplete operation observation."
}
$packagedResult = Invoke-BoundedProcess $nodeHost @(
  $packagedProbeResolved,
  "--backend-module", $backendModulePath,
  "--daemon", $daemonResolved,
  "--bridge", $bridgeResolved,
  "--cache-root", $compatCacheRoot,
  "--workspace-root", $compatWorkspaceRoot,
  "--profile-root", $compatProfileRoot
) 180 @{ ELECTRON_RUN_AS_NODE = "1" }
Assert-True ($packagedResult.ExitCode -eq 0) "The packaged-native candidate probe failed before it could establish its current boundary."
$packagedReport = Convert-JsonObject $packagedResult.Stdout.Trim() "packaged-native probe stdout"
Assert-True ([string]$packagedReport.schema -ceq "subversionr.release.packaged-native-compatibility.v2") "The packaged-native probe returned an unexpected schema."
Assert-True ([string]$packagedReport.status -ceq "passed") "The packaged-native probe did not pass its current contract."
Assert-True ([int]$packagedReport.protocol.major -eq 1 -and [int]$packagedReport.protocol.minor -eq 35) "The packaged-native probe did not execute protocol 1.35."
Assert-True ([string]$packagedReport.workerIsolation.resultCode -ceq "SUBVERSIONR_REMOTE_TRANSPORT_UNSUPPORTED") "The packaged-native probe did not produce the expected current transport-boundary observation."
Assert-True ([int]$packagedReport.workerIsolation.tempRootCleanup.residualEntryCount -eq 0) "The packaged-native failure observation left worker temporary roots."
Assert-True ([string]$packagedReport.workerIsolation.sameLaneSubsequent.resultCode -ceq "SUBVERSIONR_REMOTE_TRANSPORT_UNSUPPORTED") "The packaged-native failure observation did not release its native lane."

$installedRunId = "m8-i6-$([Guid]::NewGuid().ToString('N'))"
$installedFixtureRoot = Join-Path $installedHarnessRoot $installedRunId
$installedEvidencePath = Join-Path $installedFixtureRoot "evidence.json"
try {
  New-Item -ItemType Directory -Force -Path $installedFixtureRoot | Out-Null
  $installedPositiveRoot = Join-Path $installedFixtureRoot "i6-positive"
  $installedPositive = Invoke-BoundedProcess (Get-Process -Id $PID).Path @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $installedI6ProbeResolved,
    "-VsixPath", $vsixResolved,
    "-CodeCliPath", $codeCliResolved,
    "-FixtureRoot", $installedPositiveRoot,
    "-RepositoryUrl", $RepositoryUrl,
    "-CheckoutPath", (Join-Path $installedPositiveRoot "installed-i6-wc"),
    "-CheckoutRevision", "2",
    "-ExpectedProductVersion", $ExpectedProductVersion,
    "-TimeoutSeconds", "600"
  ) 720
  Assert-True ($installedPositive.ExitCode -eq 0) "The installed Extension Host I6 positive operation matrix failed against the installed candidate."
  $installedPositiveReport = Convert-JsonObject $installedPositive.Stdout.Trim() "installed Extension Host I6 positive probe stdout"
  Assert-True ([string]$installedPositiveReport.schema -ceq "subversionr.release.m8-i6-installed-vsix-positive.v1") "The installed Extension Host I6 positive probe returned an unexpected schema."
  Assert-True ([string]$installedPositiveReport.status -ceq "passed") "The installed Extension Host I6 positive probe did not pass."
  Assert-True ((@($installedPositiveReport.operations.operation) -join ",") -ceq ($expectedPositiveOperations -join ",")) "The installed Extension Host I6 positive probe did not execute the exact operation matrix."
  foreach ($operation in @($installedPositiveReport.operations)) {
    Assert-True (
      [string]$operation.status -ceq "passed" -and
      [string]$operation.serverAuth -ceq "anonymous" -and
      [int]$operation.promptCount -eq 0 -and
      [string]$operation.credentialSettlement -ceq "none" -and
      [string]$operation.reconcile -ceq "fresh" -and
      [int]$operation.workerDescendantsAfter -eq 0 -and
      [int]$operation.temporaryRootsAfter -eq 0 -and
      $operation.nativeLaneReleased -eq $true -and
      $operation.diagnosticsRedacted -eq $true
    ) "The installed Extension Host I6 positive probe returned an incomplete operation observation."
  }

  $installedResult = Invoke-BoundedProcess (Get-Process -Id $PID).Path @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $installedHarnessResolved,
    "-Target", "win32-x64",
    "-VsixPath", $vsixResolved,
    "-CodeCliPath", $codeCliResolved,
    "-FixtureRoot", $installedFixtureRoot,
    "-EvidencePath", $installedEvidencePath,
    "-ExtensionHostTimeoutSeconds", "180"
  ) 300
  Assert-True ($installedResult.ExitCode -eq 0) "The installed Extension Host candidate probe failed before it could establish its current boundary."
  $installedReport = Convert-JsonObject (Get-Content -Raw -LiteralPath $installedEvidencePath) "installed Extension Host evidence"
  Assert-True ([string]$installedReport.extension.version -ceq $ExpectedProductVersion) "Installed Extension Host product version must match ExpectedProductVersion."
  Assert-True ([int]$installedReport.installedRemoteWorkerReport.protocol.major -eq 1 -and [int]$installedReport.installedRemoteWorkerReport.protocol.minor -eq 35) "Installed Extension Host did not execute protocol 1.35."
  Assert-True ([string]$installedReport.installedRemoteWorkerReport.transportResult -ceq "unsupportedAfterWorker") "Installed Extension Host did not produce the expected current transport-boundary observation."
  Assert-True ($installedReport.installedRemoteWorkerReport.remoteConnectionState.separateRecoveryOperation -eq $true) "Installed Extension Host did not prove the current recovery-operation boundary."
}
finally {
  if (Test-Path -LiteralPath $installedFixtureRoot) {
    Remove-Item -LiteralPath $installedFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Assert-True (-not (Test-Path -LiteralPath $outputResolved)) "OutputPath must remain absent until every I6 observation is complete."
throw "SUBVERSIONR_M8_I6_OBSERVATION_BLOCKED: the candidate passed the real packaged-native and installed Extension Host eleven-operation svn:// matrices plus the existing packaged/installed recovery-cleanup probes. The sixteen cross-surface negative/recovery cells and installed 100-cycle residue stress contract are not yet automated; therefore no I6 evidence was written."

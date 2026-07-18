[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$SubversionStageRoot,

  [Parameter(Mandatory = $true)]
  [string]$VsixPath,

  [Parameter(Mandatory = $true)]
  [string]$DaemonPath,

  [Parameter(Mandatory = $true)]
  [string]$BridgePath,

  [Parameter(Mandatory = $true)]
  [string]$CodeCliPath,

  [Parameter(Mandatory = $true)]
  [string]$ProbeDriverPath,

  [Parameter(Mandatory = $true)]
  [string]$RaSvnOriginPatchPath,

  [Parameter(Mandatory = $true)]
  [string]$RaSvnOriginContractPath,

  [Parameter(Mandatory = $true)]
  [string]$NativeSourceLockPath,

  [Parameter(Mandatory = $true)]
  [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
  [string]$ExpectedProductVersion,

  [Parameter(Mandatory = $true)]
  [string]$FixtureRoot,

  [Parameter(Mandatory = $true)]
  [string]$EvidencePath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$allowedFixtureRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\i6-evidence"))
$verifyScript = Join-Path $PSScriptRoot "verify-m8-i6-svn-anonymous-evidence.ps1"
$nativeModulePath = Join-Path $repoRoot "scripts\native\SubversionR.Native.psm1"
$expectedProbeDriverPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "scripts\release\probe-m8-i6-svn-anonymous.ps1"))
$expectedRaSvnOriginPatchPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "native\patches\subversion-1.14.5\ra-svn-authority.patch"))
$expectedRaSvnOriginContractPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "native\patches\subversion-1.14.5\ra-svn-authority.contract.json"))
$expectedNativeSourceLockPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "native\sources.lock.json"))

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw $Message
  }
}

function Resolve-RequiredFile([string]$Path, [string]$Name) {
  Assert-True ([System.IO.Path]::IsPathFullyQualified($Path)) "$Name must be an absolute path."
  $resolved = [System.IO.Path]::GetFullPath($Path)
  Assert-True (Test-Path -LiteralPath $resolved -PathType Leaf) "$Name must be an existing file: $resolved"
  return $resolved
}

function Resolve-RequiredDirectory([string]$Path, [string]$Name) {
  Assert-True ([System.IO.Path]::IsPathFullyQualified($Path)) "$Name must be an absolute path."
  $resolved = [System.IO.Path]::GetFullPath($Path)
  Assert-True (Test-Path -LiteralPath $resolved -PathType Container) "$Name must be an existing directory: $resolved"
  return $resolved
}

function Assert-ExactSourcePath([string]$Path, [string]$ExpectedPath, [string]$Name) {
  Assert-True ([System.IO.Path]::IsPathFullyQualified($Path)) "$Name must be an absolute path."
  $resolved = [System.IO.Path]::GetFullPath($Path)
  Assert-True ($resolved.Equals($ExpectedPath, [System.StringComparison]::OrdinalIgnoreCase)) "$Name must be the exact source-controlled path: $ExpectedPath"
  return $resolved
}

function Assert-GeneratedPath([string]$Path, [string]$Name) {
  Assert-True ([System.IO.Path]::IsPathFullyQualified($Path)) "$Name must be an absolute path."
  $resolved = [System.IO.Path]::GetFullPath($Path)
  $prefix = $allowedFixtureRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  Assert-True ($resolved.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) "$Name must be below $allowedFixtureRoot."
  return $resolved
}

function Invoke-RequiredTool([string]$Tool, [string[]]$Arguments, [string]$Context) {
  $output = & $Tool @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "$Context failed with exit code $LASTEXITCODE.`n$($output | Out-String)"
  }
  return @($output)
}

function Get-LoopbackPort {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  try {
    return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
  }
  finally {
    $listener.Stop()
  }
}

function Wait-SvnserveReady(
  [string]$Svn,
  [string]$RepositoryUrl,
  [string]$ConfigRoot,
  [System.Diagnostics.Process]$Server
) {
  $deadline = [DateTimeOffset]::UtcNow.AddSeconds(20)
  while ([DateTimeOffset]::UtcNow -lt $deadline) {
    if ($Server.HasExited) {
      throw "The controlled source-built svnserve exited before readiness with code $($Server.ExitCode)."
    }
    $output = & $Svn info $RepositoryUrl --non-interactive --no-auth-cache --config-dir $ConfigRoot 2>&1
    if ($LASTEXITCODE -eq 0) {
      return
    }
    Start-Sleep -Milliseconds 100
  }
  throw "The controlled source-built svnserve did not become ready before its 20 second deadline."
}

$stageRootResolved = Resolve-RequiredDirectory $SubversionStageRoot "SubversionStageRoot"
$vsixResolved = Resolve-RequiredFile $VsixPath "VsixPath"
$daemonResolved = Resolve-RequiredFile $DaemonPath "DaemonPath"
$bridgeResolved = Resolve-RequiredFile $BridgePath "BridgePath"
$codeCliResolved = Resolve-RequiredFile $CodeCliPath "CodeCliPath"
$probeDriverSourcePath = Assert-ExactSourcePath $ProbeDriverPath $expectedProbeDriverPath "ProbeDriverPath"
$raSvnOriginPatchSourcePath = Assert-ExactSourcePath $RaSvnOriginPatchPath $expectedRaSvnOriginPatchPath "RaSvnOriginPatchPath"
$raSvnOriginContractSourcePath = Assert-ExactSourcePath $RaSvnOriginContractPath $expectedRaSvnOriginContractPath "RaSvnOriginContractPath"
$nativeSourceLockSourcePath = Assert-ExactSourcePath $NativeSourceLockPath $expectedNativeSourceLockPath "NativeSourceLockPath"
$raSvnOriginPatchResolved = Resolve-RequiredFile $raSvnOriginPatchSourcePath "RaSvnOriginPatchPath"
$raSvnOriginContractResolved = Resolve-RequiredFile $raSvnOriginContractSourcePath "RaSvnOriginContractPath"
$nativeSourceLockResolved = Resolve-RequiredFile $nativeSourceLockSourcePath "NativeSourceLockPath"
$fixtureRootResolved = Assert-GeneratedPath $FixtureRoot "FixtureRoot"
$evidenceResolved = Assert-GeneratedPath $EvidencePath "EvidencePath"
Assert-True ($fixtureRootResolved.Length -le 110) "FixtureRoot exceeds the reviewed 110-character Windows path budget."

Import-Module $nativeModulePath -Force
$stageRootResolved = Assert-SubversionStageForBridge `
  -StageRoot $stageRootResolved `
  -WorkspaceRoot $repoRoot `
  -SourceLockPath $nativeSourceLockResolved `
  -ExpectedArch "x64" `
  -ExpectedConfiguration "Release"

$stageManifestResolved = Resolve-RequiredFile (Join-Path $stageRootResolved "subversionr-stage-manifest.json") "Subversion stage manifest"
$svn = Resolve-RequiredFile (Join-Path $stageRootResolved "bin\svn.exe") "source-built svn.exe"
$svnadmin = Resolve-RequiredFile (Join-Path $stageRootResolved "bin\svnadmin.exe") "source-built svnadmin.exe"
$svnserve = Resolve-RequiredFile (Join-Path $stageRootResolved "bin\svnserve.exe") "source-built svnserve.exe"
$probeDriverResolved = Resolve-RequiredFile $probeDriverSourcePath "ProbeDriverPath"

foreach ($tool in @($svn, $svnadmin, $svnserve)) {
  $version = (Invoke-RequiredTool $tool @("--version", "--quiet") "Version check for $tool" | Select-Object -First 1).ToString().Trim()
  Assert-True ($version -eq "1.14.5") "I6 controlled fixture requires source-built Apache Subversion 1.14.5; got '$version' from $tool."
}

if (Test-Path -LiteralPath $fixtureRootResolved) {
  Remove-Item -LiteralPath $fixtureRootResolved -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $fixtureRootResolved | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $evidenceResolved) | Out-Null

$repositoryRoot = Join-Path $fixtureRootResolved "repositories\repo"
$seedWorkingCopy = Join-Path $fixtureRootResolved "seed-wc"
$oracleConfigRoot = Join-Path $fixtureRootResolved "fixture-cli-config"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $repositoryRoot) | Out-Null
New-Item -ItemType Directory -Force -Path $oracleConfigRoot | Out-Null
Set-Content -LiteralPath (Join-Path $oracleConfigRoot "config") -Value "[auth]`npassword-stores =`nstore-auth-creds = no`nstore-passwords = no`n" -NoNewline
Set-Content -LiteralPath (Join-Path $oracleConfigRoot "servers") -Value "[global]`nstore-auth-creds = no`nstore-passwords = no`n" -NoNewline

Invoke-RequiredTool $svnadmin @("create", $repositoryRoot) "Create I6 fixture repository" | Out-Null
$repositoryFileUrl = ([System.Uri]::new($repositoryRoot)).AbsoluteUri.TrimEnd('/')
Invoke-RequiredTool $svn @(
  "mkdir",
  "$repositoryFileUrl/trunk",
  "$repositoryFileUrl/branches",
  "$repositoryFileUrl/tags",
  "-m",
  "create I6 fixture layout",
  "--non-interactive",
  "--no-auth-cache",
  "--config-dir",
  $oracleConfigRoot
) "Create I6 fixture layout" | Out-Null
Invoke-RequiredTool $svn @(
  "checkout",
  "$repositoryFileUrl/trunk",
  $seedWorkingCopy,
  "--non-interactive",
  "--no-auth-cache",
  "--config-dir",
  $oracleConfigRoot
) "Checkout I6 fixture seed working copy" | Out-Null
Set-Content -LiteralPath (Join-Path $seedWorkingCopy "tracked.txt") -Value "SubversionR I6 controlled anonymous fixture`n" -NoNewline
Invoke-RequiredTool $svn @(
  "add",
  (Join-Path $seedWorkingCopy "tracked.txt"),
  "--non-interactive",
  "--no-auth-cache",
  "--config-dir",
  $oracleConfigRoot
) "Add I6 fixture seed file" | Out-Null
Invoke-RequiredTool $svn @(
  "commit",
  $seedWorkingCopy,
  "-m",
  "seed I6 anonymous fixture",
  "--non-interactive",
  "--no-auth-cache",
  "--config-dir",
  $oracleConfigRoot
) "Commit I6 fixture seed file" | Out-Null

$fixtureConfigPath = Join-Path $repositoryRoot "conf\svnserve.conf"
$fixtureAuthzPath = Join-Path $repositoryRoot "conf\authz"
Set-Content -LiteralPath $fixtureConfigPath -Value @"
[general]
anon-access = write
auth-access = none
authz-db = authz
realm = SubversionR I6 Controlled Anonymous
[sasl]
use-sasl = false
"@ -NoNewline
Set-Content -LiteralPath $fixtureAuthzPath -Value @"
[repo:/]
* = rw
"@ -NoNewline

$port = Get-LoopbackPort
$repositoryUrl = "svn://127.0.0.1:$port/repo/trunk"
$server = $null
try {
  $server = Start-Process -FilePath $svnserve -ArgumentList @(
    "--daemon",
    "--foreground",
    "--listen-host",
    "127.0.0.1",
    "--listen-port",
    $port.ToString(),
    "--root",
    (Join-Path $fixtureRootResolved "repositories")
  ) -PassThru -WindowStyle Hidden
  Wait-SvnserveReady $svn $repositoryUrl $oracleConfigRoot $server
  $svnserveStartTimeUtc = $server.StartTime.ToUniversalTime().ToString("O", [Globalization.CultureInfo]::InvariantCulture)

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $probeDriverResolved `
    -RepositoryUrl $repositoryUrl `
    -FixtureRoot $fixtureRootResolved `
    -FixtureConfigPath $fixtureConfigPath `
    -FixtureAuthzPath $fixtureAuthzPath `
    -SvnPath $svn `
    -SvnadminPath $svnadmin `
    -SvnservePath $svnserve `
    -SvnservePid $server.Id `
    -SvnserveStartTimeUtc $svnserveStartTimeUtc `
    -VsixPath $vsixResolved `
    -DaemonPath $daemonResolved `
    -BridgePath $bridgeResolved `
    -CodeCliPath $codeCliResolved `
    -StageManifestPath $stageManifestResolved `
    -RaSvnOriginPatchPath $raSvnOriginPatchResolved `
    -RaSvnOriginContractPath $raSvnOriginContractResolved `
    -NativeSourceLockPath $nativeSourceLockResolved `
    -ExpectedProductVersion $ExpectedProductVersion `
    -OutputPath $evidenceResolved
  if ($LASTEXITCODE -ne 0) {
    throw "The required I6 packaged/installed probe driver failed with exit code $LASTEXITCODE."
  }

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
    -EvidencePath $evidenceResolved `
    -VsixPath $vsixResolved `
    -DaemonPath $daemonResolved `
    -BridgePath $bridgeResolved `
    -StageManifestPath $stageManifestResolved `
    -ProbeDriverPath $probeDriverResolved `
    -RaSvnOriginPatchPath $raSvnOriginPatchResolved `
    -RaSvnOriginContractPath $raSvnOriginContractResolved `
    -NativeSourceLockPath $nativeSourceLockResolved `
    -SvnPath $svn `
    -SvnadminPath $svnadmin `
    -SvnservePath $svnserve `
    -FixtureConfigPath $fixtureConfigPath `
    -FixtureAuthzPath $fixtureAuthzPath `
    -ExpectedProductVersion $ExpectedProductVersion
  if ($LASTEXITCODE -ne 0) {
    throw "The generated I6 evidence failed its executable contract."
  }
}
finally {
  if ($null -ne $server -and -not $server.HasExited) {
    Stop-Process -Id $server.Id -Force
    $server.WaitForExit()
  }
}

Write-Host "Generated and verified controlled M8 I6 direct svn:// anonymous evidence at $evidenceResolved."

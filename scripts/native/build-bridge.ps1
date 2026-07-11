[CmdletBinding()]
param(
  [string]$SvnRoot,

  [ValidateSet("Release", "Debug")]
  [string]$Configuration = "Release",

  [ValidateSet("x64")]
  [string]$Arch = "x64",

  [string]$VsDevCmd
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$modulePath = Join-Path $PSScriptRoot "SubversionR.Native.psm1"
Import-Module $modulePath -Force
$lockPath = Join-Path $repoRoot "native\sources.lock.json"

if (-not $SvnRoot) {
  throw "SvnRoot is required."
}
if (-not $VsDevCmd) {
  throw "VsDevCmd is required."
}

$svnRootResolved = Resolve-Path -LiteralPath $SvnRoot -ErrorAction Stop
$buildDir = Join-Path $repoRoot "target\native\svn-bridge\$Arch\$Configuration"
$sourceDir = Join-Path $repoRoot "native\svn-bridge"

Assert-SubversionStageForBridge -StageRoot $svnRootResolved.Path -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch $Arch -ExpectedConfiguration $Configuration | Out-Null

if (-not (Test-Path -LiteralPath $VsDevCmd -PathType Leaf)) {
  throw "Visual Studio developer command is missing: $VsDevCmd"
}

Clear-NativeGeneratedDirectory -Path $buildDir -WorkspaceRoot $repoRoot -Description "SubversionR bridge build directory" | Out-Null

$cmd = "call `"$VsDevCmd`" -arch=$Arch -host_arch=$Arch && cmake -S `"$sourceDir`" -B `"$buildDir`" -G `"Visual Studio 17 2022`" -A $Arch -DSVN_ROOT=`"$($svnRootResolved.Path)`" && cmake --build `"$buildDir`" --config $Configuration --parallel"

cmd.exe /d /s /c $cmd
if ($LASTEXITCODE -ne 0) {
  throw "Bridge build failed with exit code $LASTEXITCODE."
}

$bridgeOutputDirectory = Join-Path $buildDir $Configuration
$bridgePath = Join-Path $bridgeOutputDirectory "subversionr_svn_bridge.dll"
if ($Configuration -eq "Release") {
  Assert-DeterministicPeFile -Path $bridgePath | Out-Null
}
$bridgeRuntimeDirectory = Copy-BridgeRuntimeDependencies `
  -SubversionStageRoot $svnRootResolved.Path `
  -OutputDirectory $bridgeOutputDirectory `
  -WorkspaceRoot $repoRoot `
  -SourceLockPath $lockPath `
  -ExpectedArch $Arch `
  -ExpectedConfiguration $Configuration

Write-Host "Built SubversionR bridge for $Arch $Configuration."
Write-Host "Copied SubversionR bridge runtime dependencies to $bridgeRuntimeDirectory."

[CmdletBinding()]
param(
  [string]$BridgeOutputDirectory,

  [string]$ExpectedVersion,

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

function Resolve-RequiredDirectory([string]$Path, [string]$Name) {
  if (-not $Path) {
    throw "$Name is required."
  }

  $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
  if (-not (Test-Path -LiteralPath $resolved.Path -PathType Container)) {
    throw "$Name must be a directory: $Path"
  }

  return $resolved.Path
}

function Assert-RequiredFile([string]$Path, [string]$Description) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Missing $Description`: $Path"
  }
}

function Quote-CmdArgument([string]$Value) {
  return '"' + $Value.Replace('"', '\"') + '"'
}

if (-not $ExpectedVersion) {
  throw "ExpectedVersion is required."
}
if (-not $VsDevCmd) {
  throw "VsDevCmd is required."
}

$versionParts = $ExpectedVersion.Split(".")
if ($versionParts.Count -ne 3) {
  throw "ExpectedVersion must use major.minor.patch format: $ExpectedVersion"
}

$expectedMajor = [int]$versionParts[0]
$expectedMinor = [int]$versionParts[1]
$expectedPatch = [int]$versionParts[2]

try {
  $bridgeOutputResolved = Resolve-RequiredDirectory $BridgeOutputDirectory "BridgeOutputDirectory"
}
catch [System.Management.Automation.ItemNotFoundException] {
  throw "Bridge output directory is missing: $BridgeOutputDirectory"
}

Assert-RequiredFile (Join-Path $bridgeOutputResolved "subversionr_svn_bridge.dll") "SubversionR bridge DLL"
Assert-RequiredFile (Join-Path $bridgeOutputResolved "subversionr_svn_bridge.lib") "SubversionR bridge import library"
Assert-RequiredFile $VsDevCmd "Visual Studio developer command"

$smokeRoot = Join-Path $repoRoot "target\native\svn-bridge-smoke\$Arch\$Configuration"
Clear-NativeGeneratedDirectory -Path $smokeRoot -WorkspaceRoot $repoRoot -Description "SubversionR bridge smoke build directory" | Out-Null

$sourcePath = Join-Path $smokeRoot "smoke_bridge.c"
$objectPath = Join-Path $smokeRoot "smoke_bridge.obj"
$exePath = Join-Path $smokeRoot "smoke_bridge.exe"
$includeDir = Join-Path $repoRoot "native\svn-bridge\include"

@"
#include <stdio.h>

#include "subversionr_bridge.h"

int main(void) {
  subversionr_bridge_version_info version = subversionr_bridge_version();
  if (version.major != $expectedMajor || version.minor != $expectedMinor || version.patch != $expectedPatch) {
    fprintf(stderr, "Expected libsvn $expectedMajor.$expectedMinor.$expectedPatch, got %d.%d.%d (%s)\n", version.major, version.minor, version.patch, version.display);
    return 1;
  }

  printf("SubversionR bridge libsvn version %d.%d.%d (%s)\n", version.major, version.minor, version.patch, version.display);
  return 0;
}
"@ | Set-Content -LiteralPath $sourcePath -Encoding ascii -NoNewline

$quotedVsDevCmd = Quote-CmdArgument $VsDevCmd
$quotedIncludeDir = Quote-CmdArgument $includeDir
$quotedSourcePath = Quote-CmdArgument $sourcePath
$quotedObjectPath = Quote-CmdArgument $objectPath
$quotedBridgeOutput = Quote-CmdArgument $bridgeOutputResolved
$quotedExePath = Quote-CmdArgument $exePath
$cmd = "call $quotedVsDevCmd -arch=$Arch -host_arch=$Arch && cl /nologo /W4 /WX /I $quotedIncludeDir /Fo$quotedObjectPath $quotedSourcePath /link /LIBPATH:$quotedBridgeOutput subversionr_svn_bridge.lib /OUT:$quotedExePath"

cmd.exe /d /s /c $cmd
if ($LASTEXITCODE -ne 0) {
  throw "Bridge smoke test compile failed with exit code $LASTEXITCODE."
}

$previousPath = $env:PATH
try {
  $env:PATH = "$bridgeOutputResolved;$previousPath"
  & $exePath
  if ($LASTEXITCODE -ne 0) {
    throw "Bridge smoke test failed with exit code $LASTEXITCODE."
  }
}
finally {
  $env:PATH = $previousPath
}

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

  subversionr_bridge_remote_config_v1 config = {
    SUBVERSIONR_BRIDGE_REMOTE_CONFIG_ABI_VERSION,
    SUBVERSIONR_BRIDGE_REMOTE_SCHEME_HTTPS,
    SUBVERSIONR_BRIDGE_REMOTE_AUTH_BASIC,
    1234,
    1
  };
  subversionr_bridge_remote_context *context = NULL;
  int create_status = subversionr_bridge_remote_context_create(&config, &context);
  if (create_status != 0 || context == NULL) {
    fprintf(stderr, "Remote context creation failed with status %d\n", create_status);
    return 2;
  }

  subversionr_bridge_remote_config_inspection inspection = {0};
  int inspect_status = subversionr_bridge_remote_context_inspect(context, &inspection);
  if (inspect_status != 0) {
    fprintf(stderr, "Remote context inspection failed with status %d\n", inspect_status);
    subversionr_bridge_remote_context_destroy(context);
    return 3;
  }
  unsigned int expected_categories =
    SUBVERSIONR_BRIDGE_REMOTE_CATEGORY_CONFIG |
    SUBVERSIONR_BRIDGE_REMOTE_CATEGORY_SERVERS;
  unsigned int expected_options =
    SUBVERSIONR_BRIDGE_REMOTE_OPTION_STORE_AUTH_CREDS |
    SUBVERSIONR_BRIDGE_REMOTE_OPTION_STORE_PASSWORDS |
    SUBVERSIONR_BRIDGE_REMOTE_OPTION_PASSWORD_STORES |
    SUBVERSIONR_BRIDGE_REMOTE_OPTION_HTTP_AUTH_TYPES |
    SUBVERSIONR_BRIDGE_REMOTE_OPTION_HTTP_TIMEOUT |
    SUBVERSIONR_BRIDGE_REMOTE_OPTION_SSL_TRUST_DEFAULT_CA;
  if (
    inspection.abi_version != SUBVERSIONR_BRIDGE_REMOTE_CONFIG_ABI_VERSION ||
    inspection.category_mask != expected_categories ||
    inspection.option_mask != expected_options ||
    inspection.provider_mask != 0 ||
    inspection.forbidden_input_mask != 0
  ) {
    fprintf(
      stderr,
      "Unexpected remote context inspection: abi=%u categories=%u options=%u providers=%u forbidden=%u\n",
      inspection.abi_version,
      inspection.category_mask,
      inspection.option_mask,
      inspection.provider_mask,
      inspection.forbidden_input_mask
    );
    subversionr_bridge_remote_context_destroy(context);
    return 4;
  }
  subversionr_bridge_remote_context_destroy(context);

  printf(
    "SubversionR bridge libsvn version %d.%d.%d (%s); remote context allowlist verified\n",
    version.major,
    version.minor,
    version.patch,
    version.display
  );
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
$registrySubKeyPath = "Software\Tigris.org\Subversion\Servers\global"
$registryHierarchy = @(
  "Software\Tigris.org\Subversion",
  "Software\Tigris.org\Subversion\Servers",
  $registrySubKeyPath
)
$registryExistingPaths = @{}
foreach ($path in $registryHierarchy) {
  $existingPath = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path, $false)
  $registryExistingPaths[$path] = $null -ne $existingPath
  if ($existingPath) { $existingPath.Dispose() }
}
$registryValueNames = @("http-proxy-host", "http-proxy-port")
$registryPreviousValues = @{}
$registryPreviousKinds = @{}
$registryExistingKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registrySubKeyPath, $false)
if ($registryExistingKey) {
  try {
    foreach ($name in $registryValueNames) {
      if ($registryExistingKey.GetValueNames() -contains $name) {
        $registryPreviousValues[$name] = $registryExistingKey.GetValue(
          $name,
          $null,
          [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        )
        $registryPreviousKinds[$name] = $registryExistingKey.GetValueKind($name)
      }
    }
  }
  finally {
    $registryExistingKey.Dispose()
  }
}
$registryPoisonKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registrySubKeyPath, $true)
try {
  $registryPoisonKey.SetValue("http-proxy-host", "127.0.0.1", [Microsoft.Win32.RegistryValueKind]::String)
  $registryPoisonKey.SetValue("http-proxy-port", "9", [Microsoft.Win32.RegistryValueKind]::String)
}
finally {
  $registryPoisonKey.Dispose()
}
$poisonRoot = Join-Path $smokeRoot "poison-ambient-inputs"
$poisonAppData = Join-Path $poisonRoot "appdata"
$poisonHome = Join-Path $poisonRoot "home"
$poisonSvn = Join-Path $poisonAppData "Subversion"
$sentinelPath = Join-Path $poisonRoot "ambient-input-was-executed.txt"
New-Item -ItemType Directory -Force -Path (Join-Path $poisonSvn "auth\svn.simple"), (Join-Path $poisonHome ".ssh") | Out-Null
@"
[auth]
store-auth-creds = yes
store-passwords = yes
password-stores = windows-cryptoapi
[tunnels]
ssh = cmd.exe /d /c type nul ^> "$sentinelPath"
"@ | Set-Content -LiteralPath (Join-Path $poisonSvn "config") -Encoding ascii -NoNewline
@"
[global]
http-proxy-host = 127.0.0.1
http-proxy-port = 9
"@ | Set-Content -LiteralPath (Join-Path $poisonSvn "servers") -Encoding ascii -NoNewline
"poison-auth-cache" | Set-Content -LiteralPath (Join-Path $poisonSvn "auth\svn.simple\poison") -Encoding ascii -NoNewline
@"
Host *
  ProxyCommand cmd.exe /d /c type nul ^> "$sentinelPath"
"@ | Set-Content -LiteralPath (Join-Path $poisonHome ".ssh\config") -Encoding ascii -NoNewline
$poisonFiles = @(
  (Join-Path $poisonSvn "config"),
  (Join-Path $poisonSvn "servers"),
  (Join-Path $poisonSvn "auth\svn.simple\poison"),
  (Join-Path $poisonHome ".ssh\config")
)
$poisonFileLocks = @(
  foreach ($poisonFile in $poisonFiles) {
    [IO.File]::Open($poisonFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  }
)

$poisonEnvironment = [ordered]@{
  APPDATA = $poisonAppData
  USERPROFILE = $poisonHome
  HOME = $poisonHome
  SVN_SSH = "cmd.exe /d /c type nul > `"$sentinelPath`""
  http_proxy = "http://127.0.0.1:9"
  https_proxy = "http://127.0.0.1:9"
  USERNAME = "subversionr-ambient-username-poison"
}
$previousEnvironment = @{}
foreach ($name in $poisonEnvironment.Keys) {
  $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
  [Environment]::SetEnvironmentVariable($name, $poisonEnvironment[$name], "Process")
}
try {
  $env:PATH = "$bridgeOutputResolved;$previousPath"
  & $exePath
  if ($LASTEXITCODE -ne 0) {
    throw "Bridge smoke test failed with exit code $LASTEXITCODE."
  }
  if (Test-Path -LiteralPath $sentinelPath) {
    throw "Remote context smoke executed a poisoned ambient configuration command: $sentinelPath"
  }
}
finally {
  $env:PATH = $previousPath
  foreach ($name in $poisonEnvironment.Keys) {
    [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], "Process")
  }
  foreach ($poisonFileLock in $poisonFileLocks) {
    $poisonFileLock.Dispose()
  }
  $registryRestoreKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registrySubKeyPath, $true)
  if ($registryRestoreKey) {
    try {
      foreach ($name in $registryValueNames) {
        if ($registryPreviousValues.ContainsKey($name)) {
          $registryRestoreKey.SetValue($name, $registryPreviousValues[$name], $registryPreviousKinds[$name])
        }
        else {
          $registryRestoreKey.DeleteValue($name, $false)
        }
      }
    }
    finally {
      $registryRestoreKey.Dispose()
    }
  }
  $registryCleanupPaths = @($registryHierarchy)
  [array]::Reverse($registryCleanupPaths)
  foreach ($path in $registryCleanupPaths) {
    if ($registryExistingPaths[$path]) { continue }
    $separator = $path.LastIndexOf("\", [StringComparison]::Ordinal)
    $parentPath = $path.Substring(0, $separator)
    $childName = $path.Substring($separator + 1)
    $registryParent = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($parentPath, $true)
    if (-not $registryParent) { continue }
    try {
      $createdKey = $registryParent.OpenSubKey($childName, $false)
      if (-not $createdKey) { continue }
      try {
        $removeCreatedKey = $createdKey.SubKeyCount -eq 0 -and $createdKey.ValueCount -eq 0
      }
      finally {
        $createdKey.Dispose()
      }
      if ($removeCreatedKey) {
        $registryParent.DeleteSubKey($childName, $false)
      }
    }
    finally {
      $registryParent.Dispose()
    }
  }
}

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$PackageRoot,

  [Parameter(Mandatory = $true)]
  [string]$BackendModulePath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).ProviderPath
$packageRootResolved = (Resolve-Path -LiteralPath $PackageRoot -ErrorAction Stop).ProviderPath
$resourceRoot = Join-Path $packageRootResolved "resources\backend\$Target"
$daemonPath = (Resolve-Path -LiteralPath (Join-Path $resourceRoot "subversionr-daemon.exe") -ErrorAction Stop).ProviderPath
$bridgePath = (Resolve-Path -LiteralPath (Join-Path $resourceRoot "subversionr_svn_bridge.dll") -ErrorAction Stop).ProviderPath
if (-not (Test-Path -LiteralPath $BackendModulePath -PathType Leaf)) {
  throw "BackendModulePath must be the compiled backendProcess.js file: $BackendModulePath"
}
$backendModulePathResolved = (Resolve-Path -LiteralPath $BackendModulePath -ErrorAction Stop).ProviderPath
$probeScriptPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "probe-vscode-packaged-native.mjs") -ErrorAction Stop).ProviderPath
$nodeCommand = Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1
$nodePath = (Resolve-Path -LiteralPath $nodeCommand.Source -ErrorAction Stop).ProviderPath
$probeRoot = Join-Path $repoRoot "target\packaged-native-probe\$([Guid]::NewGuid().ToString('N'))"
$cacheRoot = Join-Path $probeRoot "cache"
$workspaceRoot = Join-Path $probeRoot "workspace"
$profileRoot = Join-Path $probeRoot "profile"
New-Item -ItemType Directory -Force -Path $cacheRoot, $workspaceRoot, $profileRoot | Out-Null
$process = $null

try {
  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $nodePath
  $startInfo.WorkingDirectory = $probeRoot
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  foreach ($argument in @(
    $probeScriptPath,
    "--backend-module", $backendModulePathResolved,
    "--daemon", $daemonPath,
    "--bridge", $bridgePath,
    "--cache-root", $cacheRoot,
    "--workspace-root", $workspaceRoot,
    "--profile-root", $profileRoot
  )) {
    $startInfo.ArgumentList.Add($argument)
  }

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  if (-not $process.Start()) {
    throw "SUBVERSIONR_PACKAGED_NATIVE_PROBE_PROCESS_START_FAILED"
  }
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()
  if (-not $process.WaitForExit(30000)) {
    $process.Kill($true)
    $process.WaitForExit()
    throw "SUBVERSIONR_PACKAGED_NATIVE_PROBE_TIMEOUT"
  }
  $stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
  $stderr = $stderrTask.GetAwaiter().GetResult().Trim()
  $exitCode = $process.ExitCode

  try {
    $probeResult = ConvertFrom-Json -InputObject $stdout -AsHashtable -ErrorAction Stop
  }
  catch {
    throw "SUBVERSIONR_PACKAGED_NATIVE_PROBE_OUTPUT_INVALID"
  }
  if ($probeResult -isnot [System.Collections.IDictionary]) {
    throw "SUBVERSIONR_PACKAGED_NATIVE_PROBE_OUTPUT_INVALID"
  }
  if (-not $probeResult.ContainsKey("schema") -or $probeResult["schema"] -ne "subversionr.release.packaged-native-compatibility.v1") {
    throw "SUBVERSIONR_PACKAGED_NATIVE_PROBE_SCHEMA_INVALID"
  }
  if ($exitCode -ne 0) {
    $probeError = $probeResult["error"]
    if ($probeResult["status"] -eq "failed" -and $probeError -is [System.Collections.IDictionary] -and -not [string]::IsNullOrWhiteSpace([string]$probeError["code"])) {
      throw "Packaged native compatibility probe failed: $($probeError["code"]) ($($probeError["messageKey"]))."
    }
    throw "SUBVERSIONR_PACKAGED_NATIVE_PROBE_PROCESS_FAILED"
  }
  if (-not [string]::IsNullOrWhiteSpace($stderr)) {
    throw "SUBVERSIONR_PACKAGED_NATIVE_PROBE_STDERR_NOT_EMPTY"
  }
  $protocol = $probeResult["protocol"]
  if (
    $probeResult["status"] -ne "passed" `
    -or $protocol -isnot [System.Collections.IDictionary] `
    -or [int]$protocol["major"] -ne 1 `
    -or [int]$protocol["minor"] -lt 29 `
    -or [string]::IsNullOrWhiteSpace([string]$probeResult["backendVersion"]) `
    -or [string]::IsNullOrWhiteSpace([string]$probeResult["bridgeVersion"]) `
    -or [string]::IsNullOrWhiteSpace([string]$probeResult["libsvnVersion"])
  ) {
    throw "SUBVERSIONR_PACKAGED_NATIVE_PROBE_RESULT_INVALID"
  }

  Write-Host "Verified packaged native startup, protocol, ABI, and read-only bridge operation for $Target."
}
finally {
  if ($null -ne $process) {
    $process.Dispose()
  }
  Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
}

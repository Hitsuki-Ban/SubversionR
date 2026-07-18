[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$PackageRoot,

  [Parameter(Mandatory = $true)]
  [string]$BackendModulePath,

  [Parameter(Mandatory = $true)]
  [string]$ExpectedProductVersion
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).ProviderPath
if ([string]::IsNullOrWhiteSpace($ExpectedProductVersion)) {
  throw "SUBVERSIONR_PRODUCT_VERSION_REQUIRED"
}
$expectedBridgeVersion = "subversionr-svn-bridge/$ExpectedProductVersion"
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
  if (-not $probeResult.ContainsKey("schema") -or $probeResult["schema"] -ne "subversionr.release.packaged-native-compatibility.v2") {
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
  if ([string]$probeResult["backendVersion"] -cne $ExpectedProductVersion) {
    throw "SUBVERSIONR_PACKAGED_NATIVE_BACKEND_VERSION_MISMATCH"
  }
  if ([string]$probeResult["bridgeVersion"] -cne $expectedBridgeVersion) {
    throw "SUBVERSIONR_PACKAGED_NATIVE_BRIDGE_VERSION_MISMATCH"
  }
  $protocol = $probeResult["protocol"]
  $capabilities = $probeResult["capabilities"]
  $localDiscovery = $probeResult["localDiscovery"]
  $workerIsolation = $probeResult["workerIsolation"]
  $credentialProviderProbe = $probeResult["credentialProviderProbe"]
  $tempRootCleanup = if ($workerIsolation -is [System.Collections.IDictionary]) { $workerIsolation["tempRootCleanup"] } else { $null }
  $sameLaneSubsequent = if ($workerIsolation -is [System.Collections.IDictionary]) { $workerIsolation["sameLaneSubsequent"] } else { $null }
  $subsequentDiagnostics = if ($workerIsolation -is [System.Collections.IDictionary]) { $workerIsolation["subsequentDiagnostics"] } else { $null }
  $subsequentProtocol = if ($subsequentDiagnostics -is [System.Collections.IDictionary]) { $subsequentDiagnostics["protocol"] } else { $null }
  if (
    $probeResult["status"] -ne "passed" `
    -or $protocol -isnot [System.Collections.IDictionary] `
    -or [int]$protocol["major"] -ne 1 `
    -or [int]$protocol["minor"] -ne 33 `
    -or $capabilities -isnot [System.Collections.IDictionary] `
    -or $capabilities["remoteWorkerIsolation"] -isnot [bool] `
    -or $capabilities["remoteWorkerIsolation"] -ne $true `
    -or $capabilities["credentialLeaseSettlement"] -isnot [bool] `
    -or $capabilities["credentialLeaseSettlement"] -ne $true `
    -or $credentialProviderProbe -isnot [System.Collections.IDictionary] `
    -or $credentialProviderProbe.Count -ne 4 `
    -or [string]$credentialProviderProbe["schema"] -cne "subversionr.private.credential-provider-probe.v1" `
    -or [string]$credentialProviderProbe["status"] -cne "passed" `
    -or $credentialProviderProbe["networkAccess"] -isnot [bool] `
    -or $credentialProviderProbe["networkAccess"] -ne $false `
    -or $credentialProviderProbe["scenarios"] -isnot [System.Collections.IList] `
    -or $credentialProviderProbe["scenarios"].Count -ne 5 `
    -or $localDiscovery -isnot [System.Collections.IDictionary] `
    -or [string]$localDiscovery["status"] -cne "passed" `
    -or [int]$localDiscovery["candidateCount"] -ne 0 `
    -or [int]$localDiscovery["fileExternalBoundaryCount"] -ne 0 `
    -or $workerIsolation -isnot [System.Collections.IDictionary] `
    -or [string]$workerIsolation["operation"] -cne "repository/checkout" `
    -or [string]$workerIsolation["expectedOriginScheme"] -cne "https" `
    -or [string]$workerIsolation["resultCode"] -cne "SUBVERSIONR_REMOTE_TRANSPORT_UNSUPPORTED" `
    -or $tempRootCleanup -isnot [System.Collections.IDictionary] `
    -or [string]$tempRootCleanup["status"] -cne "passed" `
    -or [int]$tempRootCleanup["residualEntryCount"] -ne 0 `
    -or $sameLaneSubsequent -isnot [System.Collections.IDictionary] `
    -or [string]$sameLaneSubsequent["status"] -cne "passed" `
    -or [string]$sameLaneSubsequent["resultCode"] -cne "SUBVERSIONR_REMOTE_TRANSPORT_UNSUPPORTED" `
    -or $subsequentDiagnostics -isnot [System.Collections.IDictionary] `
    -or [string]$subsequentDiagnostics["status"] -cne "passed" `
    -or [string]$subsequentDiagnostics["source"] -cne "subversionr-daemon" `
    -or $subsequentProtocol -isnot [System.Collections.IDictionary] `
    -or [int]$subsequentProtocol["major"] -ne 1 `
    -or [int]$subsequentProtocol["minor"] -ne 33 `
    -or [string]::IsNullOrWhiteSpace([string]$probeResult["backendVersion"]) `
    -or [string]::IsNullOrWhiteSpace([string]$probeResult["bridgeVersion"]) `
    -or [string]::IsNullOrWhiteSpace([string]$probeResult["libsvnVersion"])
  ) {
    throw "SUBVERSIONR_PACKAGED_NATIVE_PROBE_RESULT_INVALID"
  }

  $expectedCredentialScenarios = @(
    [pscustomobject]@{ scenario = "firstSave"; events = @("request:initial", "settle:accepted") },
    [pscustomobject]@{ scenario = "firstNextSave"; events = @("request:initial", "settle:rejected", "request:retryAfterRejected", "settle:accepted") },
    [pscustomobject]@{ scenario = "unused"; events = @("request:initial", "settle:unused") },
    [pscustomobject]@{ scenario = "cancelled"; events = @("request:initial", "settle:cancelled") },
    [pscustomobject]@{ scenario = "timedOut"; events = @("request:initial", "settle:timedOut") }
  )
  for ($index = 0; $index -lt $expectedCredentialScenarios.Count; $index++) {
    $actual = $credentialProviderProbe["scenarios"][$index]
    $expected = $expectedCredentialScenarios[$index]
    if (
      $actual -isnot [System.Collections.IDictionary] `
      -or $actual.Count -ne 2 `
      -or [string]$actual["scenario"] -cne $expected.scenario `
      -or $actual["events"] -isnot [System.Collections.IList] `
      -or (($actual["events"] | ForEach-Object { [string]$_ }) -join "|") -cne ($expected.events -join "|")
    ) {
      throw "SUBVERSIONR_PACKAGED_NATIVE_CREDENTIAL_PROVIDER_PROBE_INVALID"
    }
  }

  $compatibility = [pscustomobject]@{
    schema = "subversionr.release.packaged-native-version-evidence.v2"
    expectedProductVersion = $ExpectedProductVersion
    backendVersion = [string]$probeResult["backendVersion"]
    bridgeVersion = [string]$probeResult["bridgeVersion"]
    libsvnVersion = [string]$probeResult["libsvnVersion"]
    protocol = [pscustomobject]@{
      major = [int]$protocol["major"]
      minor = [int]$protocol["minor"]
    }
    capabilities = [pscustomobject]@{
      remoteWorkerIsolation = [bool]$capabilities["remoteWorkerIsolation"]
      credentialLeaseSettlement = [bool]$capabilities["credentialLeaseSettlement"]
    }
    credentialProviderProbe = $credentialProviderProbe
    localDiscovery = [pscustomobject]@{
      status = [string]$localDiscovery["status"]
      candidateCount = [int]$localDiscovery["candidateCount"]
      fileExternalBoundaryCount = [int]$localDiscovery["fileExternalBoundaryCount"]
    }
    workerIsolation = [pscustomobject]@{
      operation = [string]$workerIsolation["operation"]
      expectedOriginScheme = [string]$workerIsolation["expectedOriginScheme"]
      resultCode = [string]$workerIsolation["resultCode"]
      tempRootCleanup = [pscustomobject]@{
        status = [string]$tempRootCleanup["status"]
        residualEntryCount = [int]$tempRootCleanup["residualEntryCount"]
      }
      sameLaneSubsequent = [pscustomobject]@{
        status = [string]$sameLaneSubsequent["status"]
        resultCode = [string]$sameLaneSubsequent["resultCode"]
      }
      subsequentDiagnostics = [pscustomobject]@{
        status = [string]$subsequentDiagnostics["status"]
        source = [string]$subsequentDiagnostics["source"]
        protocol = [pscustomobject]@{
          major = [int]$subsequentProtocol["major"]
          minor = [int]$subsequentProtocol["minor"]
        }
      }
    }
  }
  Write-Host "Verified packaged native startup, protocol, ABI, local discovery, one-operation remote worker isolation, subsequent diagnostics, and product version $ExpectedProductVersion for $Target."
  $compatibility
}
finally {
  if ($null -ne $process) {
    $process.Dispose()
  }
  Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
}

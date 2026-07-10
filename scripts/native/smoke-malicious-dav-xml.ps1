param(
  [Parameter(Mandatory = $true)]
  [string]$BridgeOutputDirectory
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$bridgeOutputDirectoryResolved = Resolve-Path -LiteralPath $BridgeOutputDirectory -ErrorAction Stop
$bridgeDll = Resolve-Path -LiteralPath (Join-Path $bridgeOutputDirectoryResolved.Path "subversionr_svn_bridge.dll") -ErrorAction Stop

foreach ($requiredPath in @(
  (Join-Path $bridgeOutputDirectoryResolved.Path "svn.exe"),
  (Join-Path $bridgeOutputDirectoryResolved.Path "svnadmin.exe"),
  (Join-Path $bridgeOutputDirectoryResolved.Path "subversionr_svn_bridge.dll"),
  (Join-Path $bridgeOutputDirectoryResolved.Path "libsvn_client-1.dll"),
  (Join-Path $bridgeOutputDirectoryResolved.Path "libsvn_ra-1.dll"),
  (Join-Path $bridgeOutputDirectoryResolved.Path "libsvn_subr-1.dll")
)) {
  if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
    throw "Required malicious DAV/XML smoke artifact is missing: $requiredPath"
  }
}

$env:SUBVERSIONR_TEST_BRIDGE_DLL = $bridgeDll.Path

cargo test -p subversionr-daemon --test native_bridge native_bridge_malicious_dav_xml_history_log_fails_without_auth_prompts_or_crash -- --ignored --exact
if ($LASTEXITCODE -ne 0) {
  throw "Malicious DAV/XML native bridge smoke test failed with exit code $LASTEXITCODE."
}

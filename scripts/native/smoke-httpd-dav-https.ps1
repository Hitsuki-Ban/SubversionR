param(
  [Parameter(Mandatory = $true)]
  [string]$BridgeOutputDirectory,

  [Parameter(Mandatory = $true)]
  [string]$OpenSslExe,

  [Parameter(Mandatory = $true)]
  [string]$HttpdDavStageRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$bridgeOutputDirectoryResolved = Resolve-Path -LiteralPath $BridgeOutputDirectory -ErrorAction Stop
$bridgeDll = Resolve-Path -LiteralPath (Join-Path $bridgeOutputDirectoryResolved.Path "subversionr_svn_bridge.dll") -ErrorAction Stop
$opensslExeResolved = Resolve-Path -LiteralPath $OpenSslExe -ErrorAction Stop
$httpdDavStageRootResolved = Resolve-Path -LiteralPath $HttpdDavStageRoot -ErrorAction Stop

if (-not (Test-Path -LiteralPath $opensslExeResolved.Path -PathType Leaf)) {
  throw "OpenSslExe must resolve to the staged OpenSSL executable: $($opensslExeResolved.Path)"
}

if (-not (Test-Path -LiteralPath $httpdDavStageRootResolved.Path -PathType Container)) {
  throw "HttpdDavStageRoot must resolve to the staged Apache HTTPD/Subversion DAV runtime directory: $($httpdDavStageRootResolved.Path)"
}

foreach ($requiredPath in @(
  (Join-Path $bridgeOutputDirectoryResolved.Path "svn.exe"),
  (Join-Path $bridgeOutputDirectoryResolved.Path "svnadmin.exe"),
  (Join-Path $httpdDavStageRootResolved.Path "bin\httpd.exe"),
  (Join-Path $httpdDavStageRootResolved.Path "modules\mod_ssl.so"),
  (Join-Path $httpdDavStageRootResolved.Path "modules\mod_dav.so"),
  (Join-Path $httpdDavStageRootResolved.Path "modules\mod_dav_svn.so"),
  (Join-Path $httpdDavStageRootResolved.Path "modules\mod_authz_svn.so"),
  (Join-Path $httpdDavStageRootResolved.Path "subversionr-httpd-subversion-dav-stage-manifest.json")
)) {
  if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
    throw "Required HTTPS DAV smoke artifact is missing: $requiredPath"
  }
}

$env:SUBVERSIONR_TEST_BRIDGE_DLL = $bridgeDll.Path
$env:SUBVERSIONR_TEST_OPENSSL_EXE = $opensslExeResolved.Path
$env:SUBVERSIONR_TEST_HTTPD_DAV_STAGE = $httpdDavStageRootResolved.Path

cargo test -p subversionr-daemon --test native_bridge native_bridge_https_dav_content_and_update_route_certificate_trust_through_broker -- --ignored --exact
if ($LASTEXITCODE -ne 0) {
  throw "HTTPS DAV native bridge smoke test failed with exit code $LASTEXITCODE."
}

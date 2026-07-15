function Build-PackagedNativeProbeFixtures {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    [switch]$IncludeCurrentDaemon
  )

  $manifestPath = Join-Path $RepoRoot "scripts\tests\fixtures\packaged-native-probe\Cargo.toml"
  $targetDirectory = Join-Path $RepoRoot "target\tests\packaged-native-probe-fixtures"
  $rootPackage = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "package.json") | ConvertFrom-Json -ErrorAction Stop
  $productVersion = [string]$rootPackage.version
  if ([string]::IsNullOrWhiteSpace($productVersion)) {
    throw "Root package version is required for packaged native probe fixtures."
  }
  $previousProductVersion = $env:SUBVERSIONR_TEST_PRODUCT_VERSION
  try {
    $env:SUBVERSIONR_TEST_PRODUCT_VERSION = $productVersion
    & cargo build --locked --release --manifest-path $manifestPath --target-dir $targetDirectory --bins --lib
    if ($LASTEXITCODE -ne 0) {
      throw "Packaged native probe fixture build failed with exit code $LASTEXITCODE."
    }
  }
  finally {
    if ($null -eq $previousProductVersion) {
      Remove-Item Env:SUBVERSIONR_TEST_PRODUCT_VERSION -ErrorAction SilentlyContinue
    }
    else {
      $env:SUBVERSIONR_TEST_PRODUCT_VERSION = $previousProductVersion
    }
  }

  $currentDaemon = $null
  if ($IncludeCurrentDaemon) {
    & cargo build --locked --release --manifest-path (Join-Path $RepoRoot "Cargo.toml") --package subversionr-daemon
    if ($LASTEXITCODE -ne 0) {
      throw "Current SubversionR daemon build failed with exit code $LASTEXITCODE."
    }
    $currentDaemon = (Resolve-Path -LiteralPath (Join-Path $RepoRoot "target\release\subversionr-daemon.exe") -ErrorAction Stop).ProviderPath
  }

  [pscustomobject]@{
    currentProtocolDaemon = (Resolve-Path -LiteralPath (Join-Path $targetDirectory "release\current-protocol-daemon.exe") -ErrorAction Stop).ProviderPath
    staleProtocolDaemon = (Resolve-Path -LiteralPath (Join-Path $targetDirectory "release\stale-protocol-daemon.exe") -ErrorAction Stop).ProviderPath
    mismatchedBackendVersionDaemon = (Resolve-Path -LiteralPath (Join-Path $targetDirectory "release\mismatched-backend-version-daemon.exe") -ErrorAction Stop).ProviderPath
    mismatchedBridgeVersionDaemon = (Resolve-Path -LiteralPath (Join-Path $targetDirectory "release\mismatched-bridge-version-daemon.exe") -ErrorAction Stop).ProviderPath
    missingSymbolBridge = (Resolve-Path -LiteralPath (Join-Path $targetDirectory "release\packaged_native_probe_fixture.dll") -ErrorAction Stop).ProviderPath
    currentDaemon = $currentDaemon
  }
}

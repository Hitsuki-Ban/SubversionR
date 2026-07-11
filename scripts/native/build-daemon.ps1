[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$modulePath = Join-Path $PSScriptRoot "SubversionR.Native.psm1"
Import-Module $modulePath -Force

if (-not $IsWindows) {
  throw "The SubversionR release daemon build requires Windows."
}

$repositoryOwnedEnvironment = @(
  "RUSTFLAGS",
  "CARGO_ENCODED_RUSTFLAGS",
  "CARGO_BUILD_RUSTFLAGS",
  "CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS",
  "CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER",
  "RUSTC",
  "CARGO_BUILD_RUSTC",
  "RUSTC_WRAPPER",
  "CARGO_BUILD_RUSTC_WRAPPER",
  "RUSTC_WORKSPACE_WRAPPER",
  "CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER",
  "CARGO_TARGET_DIR",
  "CARGO_BUILD_TARGET_DIR",
  "CARGO_BUILD_BUILD_DIR",
  "CARGO_BUILD_TARGET",
  "RUSTUP_TOOLCHAIN"
)
foreach ($variableName in $repositoryOwnedEnvironment) {
  if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($variableName))) {
    throw "$variableName must be unset; the release daemon toolchain and output policy are repository-owned."
  }
}

$repositoryCargoConfig = Join-Path $repoRoot ".cargo\config.toml"
if (-not (Test-Path -LiteralPath $repositoryCargoConfig -PathType Leaf)) {
  throw "Repository Cargo configuration is missing: $repositoryCargoConfig"
}

$externalCargoConfigs = [Collections.Generic.List[string]]::new()
$legacyRepositoryCargoConfig = Join-Path $repoRoot ".cargo\config"
$externalCargoConfigs.Add($legacyRepositoryCargoConfig)

$cargoHomeValue = [Environment]::GetEnvironmentVariable("CARGO_HOME")
$cargoHome = if ([string]::IsNullOrEmpty($cargoHomeValue)) {
  $userProfile = [Environment]::GetEnvironmentVariable("USERPROFILE")
  if ([string]::IsNullOrEmpty($userProfile)) {
    $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
  }
  Join-Path $userProfile ".cargo"
}
elseif ([IO.Path]::IsPathRooted($cargoHomeValue)) {
  [IO.Path]::GetFullPath($cargoHomeValue)
}
else {
  [IO.Path]::GetFullPath((Join-Path $repoRoot $cargoHomeValue))
}
$externalCargoConfigs.Add((Join-Path $cargoHome "config"))
$externalCargoConfigs.Add((Join-Path $cargoHome "config.toml"))

$parentDirectory = [IO.Directory]::GetParent($repoRoot)
while ($null -ne $parentDirectory) {
  $externalCargoConfigs.Add((Join-Path $parentDirectory.FullName ".cargo\config"))
  $externalCargoConfigs.Add((Join-Path $parentDirectory.FullName ".cargo\config.toml"))
  $parentDirectory = $parentDirectory.Parent
}

$discoveredExternalCargoConfigs = @(
  $externalCargoConfigs |
    Select-Object -Unique |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
)
if ($discoveredExternalCargoConfigs.Count -ne 0) {
  throw "Release daemon builds reject external Cargo configuration: $($discoveredExternalCargoConfigs -join ', ')"
}

$cargo = Get-Command cargo -CommandType Application -ErrorAction Stop
$rustc = Get-Command rustc -CommandType Application -ErrorAction Stop
$rustcVersion = @(& $rustc.Source -vV)
$hostLine = @($rustcVersion | Where-Object { $_ -like "host: *" })
$releaseLine = @($rustcVersion | Where-Object { $_ -like "release: *" })
if (
  $LASTEXITCODE -ne 0 -or
  $hostLine.Count -ne 1 -or
  $hostLine[0] -cne "host: x86_64-pc-windows-msvc" -or
  $releaseLine.Count -ne 1 -or
  $releaseLine[0] -cne "release: 1.96.0"
) {
  throw "The SubversionR release daemon build requires Rust 1.96.0 on x86_64-pc-windows-msvc."
}

$targetRoot = Join-Path $repoRoot "target"
$daemonPath = Join-Path $targetRoot "release\subversionr-daemon.exe"
$daemonPdbPath = Join-Path $targetRoot "release\subversionr-daemon.pdb"
foreach ($staleOutput in @($daemonPath, $daemonPdbPath)) {
  if (Test-Path -LiteralPath $staleOutput) {
    Remove-Item -LiteralPath $staleOutput -Force
  }
  if (Test-Path -LiteralPath $staleOutput) {
    throw "Failed to remove stale release daemon output: $staleOutput"
  }
}

Push-Location $repoRoot
try {
  & $cargo.Source build -p subversionr-daemon --release --target-dir $targetRoot
  if ($LASTEXITCODE -ne 0) {
    throw "Release daemon build failed with exit code $LASTEXITCODE."
  }
}
finally {
  Pop-Location
}

Assert-DeterministicPeFile -Path $daemonPath | Out-Null
Write-Host "Built deterministic SubversionR release daemon at $daemonPath."

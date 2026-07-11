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
if (-not [string]::IsNullOrEmpty($env:RUSTFLAGS)) {
  throw "RUSTFLAGS must be unset; the Windows MSVC release linker policy is repository-owned."
}
if (-not [string]::IsNullOrEmpty($env:CARGO_ENCODED_RUSTFLAGS)) {
  throw "CARGO_ENCODED_RUSTFLAGS must be unset; the Windows MSVC release linker policy is repository-owned."
}

$cargo = Get-Command cargo -CommandType Application -ErrorAction Stop
$rustc = Get-Command rustc -CommandType Application -ErrorAction Stop
$hostLine = @(& $rustc.Source -vV | Where-Object { $_ -like "host: *" })
if ($LASTEXITCODE -ne 0 -or $hostLine.Count -ne 1 -or $hostLine[0] -cne "host: x86_64-pc-windows-msvc") {
  throw "The SubversionR release daemon build requires the x86_64-pc-windows-msvc Rust host."
}

Push-Location $repoRoot
try {
  & $cargo.Source build -p subversionr-daemon --release
  if ($LASTEXITCODE -ne 0) {
    throw "Release daemon build failed with exit code $LASTEXITCODE."
  }
}
finally {
  Pop-Location
}

$daemonPath = Join-Path $repoRoot "target\release\subversionr-daemon.exe"
Assert-DeterministicPeFile -Path $daemonPath | Out-Null
Write-Host "Built deterministic SubversionR release daemon at $daemonPath."

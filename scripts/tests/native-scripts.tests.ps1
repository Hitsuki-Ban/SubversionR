$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$modulePath = Join-Path $repoRoot "scripts\native\SubversionR.Native.psm1"
$buildDependenciesScript = Join-Path $repoRoot "scripts\native\build-dependencies.ps1"
$buildHttpdScript = Join-Path $repoRoot "scripts\native\build-httpd.ps1"
$buildSubversionScript = Join-Path $repoRoot "scripts\native\build-subversion.ps1"
$buildDavModulesScript = Join-Path $repoRoot "scripts\native\build-subversion-dav-modules.ps1"
$buildDaemonScript = Join-Path $repoRoot "scripts\native\build-daemon.ps1"
$buildBridgeScript = Join-Path $repoRoot "scripts\native\build-bridge.ps1"
$smokeBridgeScript = Join-Path $repoRoot "scripts\native\smoke-bridge.ps1"
$smokeHttpdDavHttpsScript = Join-Path $repoRoot "scripts\native\smoke-httpd-dav-https.ps1"
$smokeMaliciousDavXmlScript = Join-Path $repoRoot "scripts\native\smoke-malicious-dav-xml.ps1"
$smokeMaliciousSvnServerResponseScript = Join-Path $repoRoot "scripts\native\smoke-malicious-svn-server-response.ps1"
$ciWorkflow = Join-Path $repoRoot ".github\workflows\ci.yml"
$fastPrWorkflow = Join-Path $repoRoot ".github\workflows\pr-fast.yml"
$packageJsonPath = Join-Path $repoRoot "package.json"

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw $Message
  }
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
  if ($Expected -ne $Actual) {
    throw "$Message Expected '$Expected', got '$Actual'."
  }
}

function Assert-PathEqual([string]$Expected, [string]$Actual, [string]$Message) {
  $expectedFull = [IO.Path]::GetFullPath($Expected).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  $actualFull = [IO.Path]::GetFullPath($Actual).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  Assert-True ([StringComparer]::OrdinalIgnoreCase.Equals($expectedFull, $actualFull)) "$Message Expected '$expectedFull', got '$actualFull'."
}

function Assert-ThrowsContaining([scriptblock]$Action, [string]$ExpectedText, [string]$Message) {
  $errorMessage = $null
  try {
    & $Action
  }
  catch {
    $errorMessage = $_.Exception.Message
  }

  Assert-True ($null -ne $errorMessage) "$Message Expected command to throw."
  Assert-True ($errorMessage.Contains($ExpectedText)) "$Message Expected error to contain '$ExpectedText', got '$errorMessage'."
}

function Assert-NativeCommandFailsContaining([scriptblock]$Action, [string]$ExpectedText, [string]$Message) {
  $output = & $Action 2>&1
  $exitCode = $LASTEXITCODE
  Assert-True ($exitCode -ne 0) "$Message Expected native command to fail."
  $text = $output | Out-String
  Assert-True ($text.Contains($ExpectedText)) "$Message Expected output to contain '$ExpectedText', got '$text'."
}

function Assert-SourceField($Source, [string]$Field, [string]$Expected, [string]$Message) {
  $actual = Get-RequiredProperty -Object $Source -Name $Field
  Assert-Equal $Expected $actual $Message
}

function New-TestPeFile([string]$Path, [uint32]$DebugType, [switch]$InvalidSignature, [switch]$DuplicateRepro) {
  $bytes = [byte[]]::new(0x400)
  $bytes[0] = 0x4d
  $bytes[1] = 0x5a
  [BitConverter]::GetBytes([uint32]0x80).CopyTo($bytes, 0x3c)
  if (-not $InvalidSignature) {
    $bytes[0x80] = 0x50
    $bytes[0x81] = 0x45
  }
  [BitConverter]::GetBytes([uint16]1).CopyTo($bytes, 0x86)
  [BitConverter]::GetBytes([uint16]0xf0).CopyTo($bytes, 0x94)
  [BitConverter]::GetBytes([uint16]0x20b).CopyTo($bytes, 0x98)
  [BitConverter]::GetBytes([uint32]16).CopyTo($bytes, 0x104)
  [BitConverter]::GetBytes([uint32]0x1000).CopyTo($bytes, 0x138)
  $debugDirectorySize = if ($DuplicateRepro) { 56 } else { 28 }
  [BitConverter]::GetBytes([uint32]$debugDirectorySize).CopyTo($bytes, 0x13c)
  [BitConverter]::GetBytes([uint32]0x200).CopyTo($bytes, 0x190)
  [BitConverter]::GetBytes([uint32]0x1000).CopyTo($bytes, 0x194)
  [BitConverter]::GetBytes([uint32]0x200).CopyTo($bytes, 0x198)
  [BitConverter]::GetBytes([uint32]0x200).CopyTo($bytes, 0x19c)
  [BitConverter]::GetBytes($DebugType).CopyTo($bytes, 0x20c)
  if ($DuplicateRepro) {
    [BitConverter]::GetBytes([uint32]16).CopyTo($bytes, 0x228)
  }
  [IO.File]::WriteAllBytes($Path, $bytes)
}

function Invoke-FixtureGit([string]$WorkingDirectory, [string[]]$Arguments) {
  $git = @((Get-Command git -CommandType Application -ErrorAction Stop))[0]
  Push-Location $WorkingDirectory
  try {
    $output = @(& $git.Source @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  }
  finally {
    Pop-Location
  }
  if ($exitCode -ne 0) {
    throw "Fixture Git command failed ($($Arguments -join ' ')): $($output -join ' ')"
  }
  return @($output)
}

function New-DaemonBuildWorktreeFixture([string]$Root, [string]$BuildScript, [string]$NativeModule) {
  $primaryRoot = Join-Path $Root "primary"
  $toolsRoot = Join-Path $Root "tools"
  $userProfile = Join-Path $Root "user-profile"
  foreach ($directory in @(
    $primaryRoot,
    $toolsRoot,
    $userProfile,
    (Join-Path $primaryRoot ".cargo"),
    (Join-Path $primaryRoot "scripts\native"),
    (Join-Path $primaryRoot "crates\subversionr-daemon\src")
  )) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
  }

  Copy-Item -LiteralPath $BuildScript -Destination (Join-Path $primaryRoot "scripts\native\build-daemon.ps1")
  Copy-Item -LiteralPath $NativeModule -Destination (Join-Path $primaryRoot "scripts\native\SubversionR.Native.psm1")
  "[target.x86_64-pc-windows-msvc]`nrustflags = [`"-C`", `"link-arg=/Brepro`"]`n" |
    Set-Content -LiteralPath (Join-Path $primaryRoot ".cargo\config.toml") -Encoding ascii -NoNewline
  @'
[workspace]
members = ["crates/subversionr-daemon"]
resolver = "2"
'@ | Set-Content -LiteralPath (Join-Path $primaryRoot "Cargo.toml") -Encoding ascii -NoNewline
  @'
[package]
name = "subversionr-daemon"
version = "0.0.0"
edition = "2024"
'@ | Set-Content -LiteralPath (Join-Path $primaryRoot "crates\subversionr-daemon\Cargo.toml") -Encoding ascii -NoNewline
  "fn main() {}`n" | Set-Content -LiteralPath (Join-Path $primaryRoot "crates\subversionr-daemon\src\main.rs") -Encoding ascii -NoNewline

  Invoke-FixtureGit -WorkingDirectory $primaryRoot -Arguments @("init", "-b", "main") | Out-Null
  Invoke-FixtureGit -WorkingDirectory $primaryRoot -Arguments @("config", "core.autocrlf", "false") | Out-Null
  Invoke-FixtureGit -WorkingDirectory $primaryRoot -Arguments @("config", "user.name", "SubversionR Test") | Out-Null
  Invoke-FixtureGit -WorkingDirectory $primaryRoot -Arguments @("config", "user.email", "subversionr-test@example.invalid") | Out-Null
  Invoke-FixtureGit -WorkingDirectory $primaryRoot -Arguments @("add", ".") | Out-Null
  Invoke-FixtureGit -WorkingDirectory $primaryRoot -Arguments @("commit", "-m", "fixture") | Out-Null

  $linkedRoot = Join-Path $primaryRoot ".worktree\accepted"
  Invoke-FixtureGit -WorkingDirectory $primaryRoot -Arguments @("worktree", "add", "--detach", $linkedRoot, "HEAD") | Out-Null

  @'
[CmdletBinding()]
param()

if ($env:SUBVERSIONR_TEST_TOOL_ARGUMENTS -cne "-vV") {
  Write-Error "Unexpected fake rustc arguments: $env:SUBVERSIONR_TEST_TOOL_ARGUMENTS"
  exit 2
}
[pscustomobject]@{
  cwd = $env:SUBVERSIONR_TEST_TOOL_CWD
  rawArguments = $env:SUBVERSIONR_TEST_TOOL_ARGUMENTS
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $env:SUBVERSIONR_TEST_RUSTC_LOG -Encoding utf8
Write-Output "release: 1.96.0"
Write-Output "host: x86_64-pc-windows-msvc"
'@ | Set-Content -LiteralPath (Join-Path $toolsRoot "fake-rustc.ps1") -Encoding utf8 -NoNewline
  @'
@echo off
set "SUBVERSIONR_TEST_TOOL_CWD=%CD%"
set "SUBVERSIONR_TEST_TOOL_ARGUMENTS=%*"
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-rustc.ps1"
exit /b %ERRORLEVEL%
'@ | Set-Content -LiteralPath (Join-Path $toolsRoot "rustc.cmd") -Encoding ascii -NoNewline

  @'
[CmdletBinding()]
param()

[pscustomobject]@{
  cwd = $env:SUBVERSIONR_TEST_TOOL_CWD
  rawArguments = $env:SUBVERSIONR_TEST_TOOL_ARGUMENTS
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $env:SUBVERSIONR_TEST_CARGO_LOG -Encoding utf8

$daemonPath = $env:SUBVERSIONR_TEST_DAEMON_PATH
if ([string]::IsNullOrWhiteSpace($daemonPath)) {
  Write-Error "SUBVERSIONR_TEST_DAEMON_PATH is required."
  exit 2
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $daemonPath) | Out-Null
$bytes = [byte[]]::new(0x400)
$bytes[0] = 0x4d
$bytes[1] = 0x5a
[BitConverter]::GetBytes([uint32]0x80).CopyTo($bytes, 0x3c)
$bytes[0x80] = 0x50
$bytes[0x81] = 0x45
[BitConverter]::GetBytes([uint16]1).CopyTo($bytes, 0x86)
[BitConverter]::GetBytes([uint16]0xf0).CopyTo($bytes, 0x94)
[BitConverter]::GetBytes([uint16]0x20b).CopyTo($bytes, 0x98)
[BitConverter]::GetBytes([uint32]16).CopyTo($bytes, 0x104)
[BitConverter]::GetBytes([uint32]0x1000).CopyTo($bytes, 0x138)
[BitConverter]::GetBytes([uint32]28).CopyTo($bytes, 0x13c)
[BitConverter]::GetBytes([uint32]0x200).CopyTo($bytes, 0x190)
[BitConverter]::GetBytes([uint32]0x1000).CopyTo($bytes, 0x194)
[BitConverter]::GetBytes([uint32]0x200).CopyTo($bytes, 0x198)
[BitConverter]::GetBytes([uint32]0x200).CopyTo($bytes, 0x19c)
[BitConverter]::GetBytes([uint32]16).CopyTo($bytes, 0x20c)
[IO.File]::WriteAllBytes($daemonPath, $bytes)
'@ | Set-Content -LiteralPath (Join-Path $toolsRoot "fake-cargo.ps1") -Encoding utf8 -NoNewline
  @'
@echo off
set "SUBVERSIONR_TEST_TOOL_CWD=%CD%"
set "SUBVERSIONR_TEST_TOOL_ARGUMENTS=%*"
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-cargo.ps1"
exit /b %ERRORLEVEL%
'@ | Set-Content -LiteralPath (Join-Path $toolsRoot "cargo.cmd") -Encoding ascii -NoNewline

  return [pscustomobject]@{
    primaryRoot = $primaryRoot
    linkedRoot = $linkedRoot
    outsideLinkedRoot = Join-Path $Root "outside-linked"
    toolsRoot = $toolsRoot
    userProfile = $userProfile
    cargoLog = Join-Path $Root "cargo-log.json"
    rustcLog = Join-Path $Root "rustc-log.json"
  }
}

function Invoke-DaemonBuildFixture([object]$Fixture, [string]$WorktreeRoot) {
  $env:SUBVERSIONR_TEST_DAEMON_PATH = Join-Path $WorktreeRoot "target\release\subversionr-daemon.exe"
  $env:SUBVERSIONR_TEST_CARGO_LOG = $Fixture.cargoLog
  $env:SUBVERSIONR_TEST_RUSTC_LOG = $Fixture.rustcLog
  Remove-Item -LiteralPath $Fixture.cargoLog, $Fixture.rustcLog -Force -ErrorAction SilentlyContinue
  $output = @(& pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $WorktreeRoot "scripts\native\build-daemon.ps1") 2>&1)
  return [pscustomobject]@{
    exitCode = $LASTEXITCODE
    output = ($output | Out-String)
    cargoRan = Test-Path -LiteralPath $Fixture.cargoLog -PathType Leaf
    rustcRan = Test-Path -LiteralPath $Fixture.rustcLog -PathType Leaf
  }
}

$tempRoot = Join-Path $repoRoot ".cache\tests\native-scripts\$([Guid]::NewGuid().ToString('N'))"
$worktreeFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "subversionr-native-worktree-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  Import-Module $modulePath -Force

  $deterministicPePath = Join-Path $tempRoot "deterministic.dll"
  New-TestPeFile -Path $deterministicPePath -DebugType 16
  Assert-Equal (Resolve-Path $deterministicPePath).Path (Assert-DeterministicPeFile -Path $deterministicPePath) "Deterministic PE validation should accept IMAGE_DEBUG_TYPE_REPRO."

  $timestampedPePath = Join-Path $tempRoot "timestamped.dll"
  New-TestPeFile -Path $timestampedPePath -DebugType 2
  Assert-ThrowsContaining {
    Assert-DeterministicPeFile -Path $timestampedPePath
  } "IMAGE_DEBUG_TYPE_REPRO" "Deterministic PE validation should reject timestamped linker output."

  $duplicateReproPePath = Join-Path $tempRoot "duplicate-repro.dll"
  New-TestPeFile -Path $duplicateReproPePath -DebugType 16 -DuplicateRepro
  Assert-ThrowsContaining {
    Assert-DeterministicPeFile -Path $duplicateReproPePath
  } "exactly one IMAGE_DEBUG_TYPE_REPRO" "Deterministic PE validation should reject ambiguous duplicate reproducibility metadata."

  $invalidPePath = Join-Path $tempRoot "invalid.dll"
  New-TestPeFile -Path $invalidPePath -DebugType 16 -InvalidSignature
  Assert-ThrowsContaining {
    Assert-DeterministicPeFile -Path $invalidPePath
  } "not a valid PE file" "Deterministic PE validation should reject malformed input."

  $savedSourceDateEpoch = $env:SOURCE_DATE_EPOCH
  try {
    $env:SOURCE_DATE_EPOCH = $null
    Assert-ThrowsContaining {
      Get-RequiredSourceDateEpoch
    } "SOURCE_DATE_EPOCH is required" "Native release timestamp validation should reject a missing epoch."
    $env:SOURCE_DATE_EPOCH = "not-a-timestamp"
    Assert-ThrowsContaining {
      Get-RequiredSourceDateEpoch
    } "positive integer Unix timestamp" "Native release timestamp validation should reject malformed epochs."
    $env:SOURCE_DATE_EPOCH = "0"
    Assert-ThrowsContaining {
      Get-RequiredSourceDateEpoch
    } "positive integer Unix timestamp" "Native release timestamp validation should reject zero because OpenSSL treats it as an absent epoch."
    $env:SOURCE_DATE_EPOCH = "9999999999999999999"
    Assert-ThrowsContaining {
      Get-RequiredSourceDateEpoch
    } "valid Unix timestamp" "Native release timestamp validation should reject out-of-range epochs."

    $env:SOURCE_DATE_EPOCH = "946771200"
    $expectedTimestamp = [DateTimeOffset]::FromUnixTimeSeconds(946771200).ToUniversalTime()
    Assert-Equal $expectedTimestamp (Get-RequiredSourceDateEpoch) "Native release timestamp validation should parse the explicit epoch."

    $subversionTimestampRoot = Join-Path $tempRoot "subversion-timestamp"
    $subversionTimestampSource = Join-Path $subversionTimestampRoot "subversion\libsvn_subr"
    New-Item -ItemType Directory -Force -Path $subversionTimestampSource | Out-Null
    "info->build_date = __DATE__;`ninfo->build_time = __TIME__;`n" | Set-Content -LiteralPath (Join-Path $subversionTimestampSource "version.c") -Encoding utf8 -NoNewline
    "SVN_VERSION, __DATE__, __TIME__);`n" | Set-Content -LiteralPath (Join-Path $subversionTimestampSource "win32_crashrpt.c") -Encoding utf8 -NoNewline
    Set-SubversionReproducibleBuildTimestamp -SourceRoot $subversionTimestampRoot
    $expectedDate = '{0} {1} {2}' -f $expectedTimestamp.ToString("MMM", [Globalization.CultureInfo]::InvariantCulture), $expectedTimestamp.Day.ToString().PadLeft(2, ' '), $expectedTimestamp.Year.ToString("0000")
    $expectedTime = $expectedTimestamp.ToString("HH:mm:ss", [Globalization.CultureInfo]::InvariantCulture)
    Assert-Equal "Jan  2 2000" $expectedDate "Subversion reproducible dates should use the C macro's space-padded day format."
    $versionTimestampText = Get-Content -Raw -LiteralPath (Join-Path $subversionTimestampSource "version.c")
    $crashTimestampText = Get-Content -Raw -LiteralPath (Join-Path $subversionTimestampSource "win32_crashrpt.c")
    Assert-True ($versionTimestampText.Contains("info->build_date = `"$expectedDate`";") -and $versionTimestampText.Contains("info->build_time = `"$expectedTime`";")) "Subversion version metadata should use the explicit source epoch."
    Assert-True ($crashTimestampText.Contains("SVN_VERSION, `"$expectedDate`", `"$expectedTime`");")) "Subversion crash metadata should use the explicit source epoch."
    Assert-ThrowsContaining {
      Set-SubversionReproducibleBuildTimestamp -SourceRoot $subversionTimestampRoot
    } "expected exactly one" "Subversion timestamp patching should reject an already-patched source tree."
  }
  finally {
    $env:SOURCE_DATE_EPOCH = $savedSourceDateEpoch
  }

  $bridgeCMakeText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "native\svn-bridge\CMakeLists.txt")
  $cargoConfigText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot ".cargo\config.toml")
  $rustToolchainText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "rust-toolchain.toml")
  $buildDaemonText = Get-Content -Raw -LiteralPath $buildDaemonScript
  $buildBridgeText = Get-Content -Raw -LiteralPath $buildBridgeScript
  Assert-Equal "[target.x86_64-pc-windows-msvc]`nrustflags = [`"-C`", `"link-arg=/Brepro`"]`n" ($cargoConfigText.Replace("`r`n", "`n")) "Windows MSVC Rust configuration should have one exact reproducible linker policy."
  Assert-True ($rustToolchainText.Contains('channel = "1.96.0"')) "The repository should pin the Rust release used for reproducible daemon builds."
  foreach ($variableName in @(
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
  )) {
    Assert-True ($buildDaemonText.Contains('"' + $variableName + '"')) "Release daemon build should reject ambient $variableName."
  }
  Assert-True ($buildDaemonText.Contains('host: x86_64-pc-windows-msvc')) "Release daemon build should require the exact Windows MSVC Rust host."
  Assert-True ($buildDaemonText.Contains('release: 1.96.0')) "Release daemon build should require the repository-pinned Rust release."
  Assert-True ($buildDaemonText.Contains('build --manifest-path $manifestPath -p subversionr-daemon --release --locked --target-dir $targetRoot')) "Release daemon build should invoke the linked manifest with the exact Cargo package, locked resolution, profile, and worktree output directory."
  Assert-True ($buildDaemonText.Contains('Push-Location $primaryRoot')) "Release daemon rustc and Cargo commands should execute from the verified primary worktree root."
  Assert-True ($buildDaemonText.Contains('worktree", "list", "--porcelain", "-z"')) "Release daemon builds should verify linked worktree registration through Git's stable porcelain format."
  Assert-True ($buildDaemonText.Contains('ls-files", "--stage", "--", ".cargo/config.toml"')) "Release daemon builds should require one tracked regular Cargo config in each participating worktree."
  Assert-True ($buildDaemonText.Contains('ls-tree", "HEAD", "--", ".cargo/config.toml"')) "Release daemon builds should require the Cargo config index entry to match HEAD."
  Assert-True ($buildDaemonText.Contains('status", "--porcelain=v1", "--untracked-files=all", "--", ".cargo/config.toml"')) "Release daemon builds should reject staged and unstaged Cargo config drift."
  Assert-True ($buildDaemonText.Contains('hash-object", "--no-filters", "--", ".cargo/config.toml"')) "Release daemon builds should compare raw working-tree Cargo config bytes with the tracked blob."
  Assert-True ($buildDaemonText.Contains('must reference the same tracked Git blob') -and $buildDaemonText.Contains('must be byte-identical')) "Release daemon builds should require linked and primary Cargo configs to have identical tracked and working-tree bytes."
  Assert-True ($buildDaemonText.Contains('$legacyRepositoryCargoConfig')) "Release daemon build should reject a legacy repository Cargo config that would override config.toml."
  Assert-True ($buildDaemonText.Contains('"CARGO_HOME"') -and $buildDaemonText.Contains('$variableName must be unset')) "Release daemon build should reject an explicit Cargo home instead of accepting alternate configuration discovery."
  Assert-True ($buildDaemonText.Contains('[Environment]::GetEnvironmentVariable("USERPROFILE")')) "Release daemon build should use Cargo's Windows default home resolution."
  Assert-True (-not $buildDaemonText.Contains('[Environment+SpecialFolder]::UserProfile')) "Release daemon build should fail instead of guessing a missing USERPROFILE."
  Assert-True ($buildDaemonText.Contains('[IO.Directory]::GetParent($repoRoot)')) "Release daemon build should inspect parent directories for merged Cargo configuration."
  Assert-True ($buildDaemonText.Contains('Remove-Item -LiteralPath $staleOutput -Force')) "Release daemon build should fail on fixed-path output deletion errors."
  Assert-True (-not $buildDaemonText.Contains('Remove-Item -LiteralPath $daemonPath, $daemonPdbPath -Force -ErrorAction SilentlyContinue')) "Release daemon build must not suppress fixed-path output deletion errors."
  Assert-True ($buildDaemonText.Contains('Assert-DeterministicPeFile -Path $daemonPath')) "Release daemon build should fail fast when deterministic PE metadata is absent."
  Assert-True ($bridgeCMakeText.Contains('target_link_options(subversionr_svn_bridge PRIVATE "$<$<CONFIG:Release>:/Brepro>")')) "Release bridge linking should require MSVC reproducible output."
  Assert-True ($buildBridgeText.Contains('Assert-DeterministicPeFile -Path $bridgePath')) "Release bridge build should fail fast when deterministic PE metadata is absent."

  $savedRustFlags = $env:RUSTFLAGS
  try {
    $env:RUSTFLAGS = "-C opt-level=0"
    Assert-NativeCommandFailsContaining {
      & pwsh -NoProfile -ExecutionPolicy Bypass -File $buildDaemonScript
    } "RUSTFLAGS must be unset" "Release daemon build should reject an ambient linker-policy override."
  }
  finally {
    $env:RUSTFLAGS = $savedRustFlags
  }

  $savedCargoTargetDir = $env:CARGO_TARGET_DIR
  try {
    $env:CARGO_TARGET_DIR = Join-Path $tempRoot "redirected-cargo-target"
    Assert-NativeCommandFailsContaining {
      & pwsh -NoProfile -ExecutionPolicy Bypass -File $buildDaemonScript
    } "CARGO_TARGET_DIR must be unset" "Release daemon build should reject an output-directory override."
  }
  finally {
    $env:CARGO_TARGET_DIR = $savedCargoTargetDir
  }

  $targetRustFlagsName = "CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS"
  $savedTargetRustFlagsExists = Test-Path -LiteralPath "Env:$targetRustFlagsName"
  $savedTargetRustFlags = [Environment]::GetEnvironmentVariable($targetRustFlagsName)
  try {
    [Environment]::SetEnvironmentVariable($targetRustFlagsName, "-C link-arg=/DEBUG")
    Assert-NativeCommandFailsContaining {
      & pwsh -NoProfile -ExecutionPolicy Bypass -File $buildDaemonScript
    } "$targetRustFlagsName must be unset" "Release daemon build should reject a target-specific linker-policy override."
  }
  finally {
    if ($savedTargetRustFlagsExists) {
      Set-Item -LiteralPath "Env:$targetRustFlagsName" -Value $savedTargetRustFlags
    }
    else {
      Remove-Item -LiteralPath "Env:$targetRustFlagsName" -ErrorAction SilentlyContinue
    }
  }

  $savedCargoHome = $env:CARGO_HOME
  $savedUserProfile = $env:USERPROFILE
  $alternateUserProfile = Join-Path $tempRoot "alternate-user-profile"
  $alternateCargoDirectory = Join-Path $alternateUserProfile ".cargo"
  New-Item -ItemType Directory -Force -Path $alternateCargoDirectory | Out-Null
  "[target.x86_64-pc-windows-msvc]`nrustflags = [`"-C`", `"target-cpu=native`"]" |
    Set-Content -LiteralPath (Join-Path $alternateCargoDirectory "config.toml") -Encoding ascii
  try {
    $env:CARGO_HOME = $null
    $env:USERPROFILE = $alternateUserProfile
    Assert-NativeCommandFailsContaining {
      & pwsh -NoProfile -ExecutionPolicy Bypass -File $buildDaemonScript
    } "Release daemon builds reject external Cargo configuration" "Release daemon build should inspect Cargo's USERPROFILE-derived default home."
  }
  finally {
    $env:CARGO_HOME = $savedCargoHome
    $env:USERPROFILE = $savedUserProfile
  }

  $gitLocalEnvironmentNames = @(
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_CONFIG",
    "GIT_CONFIG_PARAMETERS",
    "GIT_CONFIG_COUNT",
    "GIT_OBJECT_DIRECTORY",
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_IMPLICIT_WORK_TREE",
    "GIT_GRAFT_FILE",
    "GIT_INDEX_FILE",
    "GIT_NO_REPLACE_OBJECTS",
    "GIT_REPLACE_REF_BASE",
    "GIT_PREFIX",
    "GIT_SHALLOW_FILE",
    "GIT_COMMON_DIR"
  )
  $savedGitEnvironment = @{}
  $savedFixturePath = $env:PATH
  $savedFixtureCargoHome = $env:CARGO_HOME
  $savedFixtureUserProfile = $env:USERPROFILE
  $savedFixtureDaemonPath = $env:SUBVERSIONR_TEST_DAEMON_PATH
  $savedFixtureCargoLog = $env:SUBVERSIONR_TEST_CARGO_LOG
  $savedFixtureRustcLog = $env:SUBVERSIONR_TEST_RUSTC_LOG
  foreach ($variableName in $gitLocalEnvironmentNames) {
    $savedGitEnvironment[$variableName] = [pscustomobject]@{
      exists = Test-Path -LiteralPath "Env:$variableName"
      value = [Environment]::GetEnvironmentVariable($variableName)
    }
    Remove-Item -LiteralPath "Env:$variableName" -ErrorAction SilentlyContinue
  }
  try {
    $daemonBuildFixture = New-DaemonBuildWorktreeFixture `
      -Root $worktreeFixtureRoot `
      -BuildScript $buildDaemonScript `
      -NativeModule $modulePath
    $env:PATH = "$($daemonBuildFixture.toolsRoot)$([IO.Path]::PathSeparator)$savedFixturePath"
    $env:CARGO_HOME = $null
    $env:USERPROFILE = $daemonBuildFixture.userProfile

    $primaryBuild = Invoke-DaemonBuildFixture -Fixture $daemonBuildFixture -WorktreeRoot $daemonBuildFixture.primaryRoot
    Assert-Equal 0 $primaryBuild.exitCode "Release daemon fixture should build from the primary worktree. $($primaryBuild.output)"
    Assert-True $primaryBuild.cargoRan "Primary worktree fixture should invoke Cargo."
    Assert-True $primaryBuild.rustcRan "Primary worktree fixture should invoke rustc."
    $primaryCargo = Get-Content -Raw -LiteralPath $daemonBuildFixture.cargoLog | ConvertFrom-Json
    $primaryRustc = Get-Content -Raw -LiteralPath $daemonBuildFixture.rustcLog | ConvertFrom-Json
    Assert-PathEqual $daemonBuildFixture.primaryRoot $primaryCargo.cwd "Primary worktree Cargo should run from the primary root."
    Assert-PathEqual $daemonBuildFixture.primaryRoot $primaryRustc.cwd "Primary worktree rustc should run from the primary root."
    $expectedPrimaryCargoArguments = "build --manifest-path $($daemonBuildFixture.primaryRoot)\Cargo.toml -p subversionr-daemon --release --locked --target-dir $($daemonBuildFixture.primaryRoot)\target"
    Assert-Equal $expectedPrimaryCargoArguments $primaryCargo.rawArguments "Primary worktree Cargo arguments should bind the primary manifest and target."

    $linkedBuild = Invoke-DaemonBuildFixture -Fixture $daemonBuildFixture -WorktreeRoot $daemonBuildFixture.linkedRoot
    Assert-Equal 0 $linkedBuild.exitCode "Release daemon fixture should accept the registered repository-owned linked worktree. $($linkedBuild.output)"
    Assert-True $linkedBuild.cargoRan "Accepted linked worktree fixture should invoke Cargo."
    Assert-True $linkedBuild.rustcRan "Accepted linked worktree fixture should invoke rustc."
    $linkedCargo = Get-Content -Raw -LiteralPath $daemonBuildFixture.cargoLog | ConvertFrom-Json
    $linkedRustc = Get-Content -Raw -LiteralPath $daemonBuildFixture.rustcLog | ConvertFrom-Json
    Assert-PathEqual $daemonBuildFixture.primaryRoot $linkedCargo.cwd "Linked worktree Cargo should run from the primary root."
    Assert-PathEqual $daemonBuildFixture.primaryRoot $linkedRustc.cwd "Linked worktree rustc should run from the primary root."
    $expectedLinkedCargoArguments = "build --manifest-path $($daemonBuildFixture.linkedRoot)\Cargo.toml -p subversionr-daemon --release --locked --target-dir $($daemonBuildFixture.linkedRoot)\target"
    Assert-Equal $expectedLinkedCargoArguments $linkedCargo.rawArguments "Linked worktree Cargo arguments should bind the linked manifest and target."

    $primaryCargoConfig = Join-Path $daemonBuildFixture.primaryRoot ".cargo\config.toml"
    $linkedCargoConfig = Join-Path $daemonBuildFixture.linkedRoot ".cargo\config.toml"
    $repositoryCargoConfigText = "[target.x86_64-pc-windows-msvc]`nrustflags = [`"-C`", `"link-arg=/Brepro`"]`n"
    "[target.x86_64-pc-windows-msvc]`nrustflags = [`"-C`", `"target-cpu=native`"]`n" |
      Set-Content -LiteralPath $primaryCargoConfig -Encoding ascii -NoNewline
    Invoke-FixtureGit -WorkingDirectory $daemonBuildFixture.primaryRoot -Arguments @("add", ".cargo/config.toml") | Out-Null
    Invoke-FixtureGit -WorkingDirectory $daemonBuildFixture.primaryRoot -Arguments @("commit", "-m", "primary config drift") | Out-Null
    $primaryDrift = Invoke-DaemonBuildFixture -Fixture $daemonBuildFixture -WorktreeRoot $daemonBuildFixture.linkedRoot
    Assert-True ($primaryDrift.exitCode -ne 0 -and $primaryDrift.output.Contains("must reference the same tracked Git blob")) "Linked builds should reject a clean but differing primary Cargo config before Cargo."
    Assert-True (-not $primaryDrift.cargoRan -and -not $primaryDrift.rustcRan) "Primary Cargo config drift should fail before rustc or Cargo runs."
    $repositoryCargoConfigText | Set-Content -LiteralPath $primaryCargoConfig -Encoding ascii -NoNewline
    Invoke-FixtureGit -WorkingDirectory $daemonBuildFixture.primaryRoot -Arguments @("add", ".cargo/config.toml") | Out-Null
    Invoke-FixtureGit -WorkingDirectory $daemonBuildFixture.primaryRoot -Arguments @("commit", "-m", "restore primary config") | Out-Null

    "# unstaged drift`n" | Add-Content -LiteralPath $linkedCargoConfig -Encoding ascii
    $unstagedDrift = Invoke-DaemonBuildFixture -Fixture $daemonBuildFixture -WorktreeRoot $daemonBuildFixture.linkedRoot
    Assert-True ($unstagedDrift.exitCode -ne 0 -and $unstagedDrift.output.Contains("must match its Git index and HEAD")) "Linked builds should reject unstaged linked Cargo config drift."
    Assert-True (-not $unstagedDrift.cargoRan -and -not $unstagedDrift.rustcRan) "Unstaged linked config drift should fail before rustc or Cargo runs."
    $repositoryCargoConfigText | Set-Content -LiteralPath $linkedCargoConfig -Encoding ascii -NoNewline

    "# staged drift`n" | Add-Content -LiteralPath $linkedCargoConfig -Encoding ascii
    Invoke-FixtureGit -WorkingDirectory $daemonBuildFixture.linkedRoot -Arguments @("add", ".cargo/config.toml") | Out-Null
    $stagedDrift = Invoke-DaemonBuildFixture -Fixture $daemonBuildFixture -WorktreeRoot $daemonBuildFixture.linkedRoot
    Assert-True ($stagedDrift.exitCode -ne 0 -and $stagedDrift.output.Contains("must match its Git index and HEAD")) "Linked builds should reject staged linked Cargo config drift."
    Assert-True (-not $stagedDrift.cargoRan -and -not $stagedDrift.rustcRan) "Staged linked config drift should fail before rustc or Cargo runs."
    $repositoryCargoConfigText | Set-Content -LiteralPath $linkedCargoConfig -Encoding ascii -NoNewline
    Invoke-FixtureGit -WorkingDirectory $daemonBuildFixture.linkedRoot -Arguments @("add", ".cargo/config.toml") | Out-Null

    Invoke-FixtureGit -WorkingDirectory $daemonBuildFixture.linkedRoot -Arguments @("update-index", "--chmod=+x", ".cargo/config.toml") | Out-Null
    $modeDrift = Invoke-DaemonBuildFixture -Fixture $daemonBuildFixture -WorktreeRoot $daemonBuildFixture.linkedRoot
    Assert-True ($modeDrift.exitCode -ne 0 -and $modeDrift.output.Contains("tracked regular 100644 file")) "Linked builds should reject a non-100644 Cargo config index mode."
    Assert-True (-not $modeDrift.cargoRan -and -not $modeDrift.rustcRan) "Cargo config mode drift should fail before rustc or Cargo runs."
    Invoke-FixtureGit -WorkingDirectory $daemonBuildFixture.linkedRoot -Arguments @("update-index", "--chmod=-x", ".cargo/config.toml") | Out-Null

    Invoke-FixtureGit -WorkingDirectory $daemonBuildFixture.linkedRoot -Arguments @("update-index", "--assume-unchanged", ".cargo/config.toml") | Out-Null
    "# hidden assume-unchanged drift`n" | Add-Content -LiteralPath $linkedCargoConfig -Encoding ascii
    $assumeUnchangedDrift = Invoke-DaemonBuildFixture -Fixture $daemonBuildFixture -WorktreeRoot $daemonBuildFixture.linkedRoot
    Assert-True ($assumeUnchangedDrift.exitCode -ne 0 -and $assumeUnchangedDrift.output.Contains("must match its tracked Git blob byte-for-byte")) "Linked builds should reject Cargo config drift hidden by assume-unchanged."
    Assert-True (-not $assumeUnchangedDrift.cargoRan -and -not $assumeUnchangedDrift.rustcRan) "Assume-unchanged Cargo config drift should fail before rustc or Cargo runs."
    $repositoryCargoConfigText | Set-Content -LiteralPath $linkedCargoConfig -Encoding ascii -NoNewline
    Invoke-FixtureGit -WorkingDirectory $daemonBuildFixture.linkedRoot -Arguments @("update-index", "--no-assume-unchanged", ".cargo/config.toml") | Out-Null

    Invoke-FixtureGit -WorkingDirectory $daemonBuildFixture.linkedRoot -Arguments @("update-index", "--skip-worktree", ".cargo/config.toml") | Out-Null
    "# hidden skip-worktree drift`n" | Add-Content -LiteralPath $linkedCargoConfig -Encoding ascii
    $skipWorktreeDrift = Invoke-DaemonBuildFixture -Fixture $daemonBuildFixture -WorktreeRoot $daemonBuildFixture.linkedRoot
    Assert-True ($skipWorktreeDrift.exitCode -ne 0 -and $skipWorktreeDrift.output.Contains("must match its tracked Git blob byte-for-byte")) "Linked builds should reject Cargo config drift hidden by skip-worktree."
    Assert-True (-not $skipWorktreeDrift.cargoRan -and -not $skipWorktreeDrift.rustcRan) "Skip-worktree Cargo config drift should fail before rustc or Cargo runs."
    $repositoryCargoConfigText | Set-Content -LiteralPath $linkedCargoConfig -Encoding ascii -NoNewline
    Invoke-FixtureGit -WorkingDirectory $daemonBuildFixture.linkedRoot -Arguments @("update-index", "--no-skip-worktree", ".cargo/config.toml") | Out-Null

    "legacy" | Set-Content -LiteralPath (Join-Path $daemonBuildFixture.linkedRoot ".cargo\config") -Encoding ascii -NoNewline
    $linkedLegacy = Invoke-DaemonBuildFixture -Fixture $daemonBuildFixture -WorktreeRoot $daemonBuildFixture.linkedRoot
    Assert-True ($linkedLegacy.exitCode -ne 0 -and $linkedLegacy.output.Contains("reject external Cargo configuration")) "Linked builds should reject a linked legacy Cargo config."
    Assert-True (-not $linkedLegacy.cargoRan) "A linked legacy Cargo config should fail before Cargo runs."
    Remove-Item -LiteralPath (Join-Path $daemonBuildFixture.linkedRoot ".cargo\config") -Force

    "legacy" | Set-Content -LiteralPath (Join-Path $daemonBuildFixture.primaryRoot ".cargo\config") -Encoding ascii -NoNewline
    $primaryLegacy = Invoke-DaemonBuildFixture -Fixture $daemonBuildFixture -WorktreeRoot $daemonBuildFixture.linkedRoot
    Assert-True ($primaryLegacy.exitCode -ne 0 -and $primaryLegacy.output.Contains("reject external Cargo configuration")) "Linked builds should reject a primary legacy Cargo config."
    Assert-True (-not $primaryLegacy.cargoRan) "A primary legacy Cargo config should fail before Cargo runs."
    Remove-Item -LiteralPath (Join-Path $daemonBuildFixture.primaryRoot ".cargo\config") -Force

    $intermediateCargoDirectory = Join-Path $daemonBuildFixture.primaryRoot ".worktree\.cargo"
    New-Item -ItemType Directory -Force -Path $intermediateCargoDirectory | Out-Null
    "[build]`ntarget-dir = 'redirected'`n" | Set-Content -LiteralPath (Join-Path $intermediateCargoDirectory "config.toml") -Encoding ascii -NoNewline
    $parentConfig = Invoke-DaemonBuildFixture -Fixture $daemonBuildFixture -WorktreeRoot $daemonBuildFixture.linkedRoot
    Assert-True ($parentConfig.exitCode -ne 0 -and $parentConfig.output.Contains("reject external Cargo configuration")) "Linked builds should reject another parent Cargo config."
    Assert-True (-not $parentConfig.cargoRan) "A differing parent Cargo config should fail before Cargo runs."
    Remove-Item -LiteralPath $intermediateCargoDirectory -Recurse -Force

    $profileCargoDirectory = Join-Path $daemonBuildFixture.userProfile ".cargo"
    New-Item -ItemType Directory -Force -Path $profileCargoDirectory | Out-Null
    "[build]`ntarget-dir = 'redirected'`n" | Set-Content -LiteralPath (Join-Path $profileCargoDirectory "config.toml") -Encoding ascii -NoNewline
    $profileConfig = Invoke-DaemonBuildFixture -Fixture $daemonBuildFixture -WorktreeRoot $daemonBuildFixture.linkedRoot
    Assert-True ($profileConfig.exitCode -ne 0 -and $profileConfig.output.Contains("reject external Cargo configuration")) "Linked builds should reject the default USERPROFILE Cargo config."
    Assert-True (-not $profileConfig.cargoRan) "A USERPROFILE Cargo config should fail before Cargo runs."
    Remove-Item -LiteralPath $profileCargoDirectory -Recurse -Force

    $env:CARGO_HOME = Join-Path $worktreeFixtureRoot "alternate-cargo-home"
    $explicitCargoHome = Invoke-DaemonBuildFixture -Fixture $daemonBuildFixture -WorktreeRoot $daemonBuildFixture.linkedRoot
    Assert-True ($explicitCargoHome.exitCode -ne 0 -and $explicitCargoHome.output.Contains("CARGO_HOME must be unset")) "Linked builds should reject an explicit Cargo home."
    Assert-True (-not $explicitCargoHome.cargoRan) "An explicit Cargo home should fail before Cargo runs."
    $env:CARGO_HOME = $null

    $env:GIT_DIR = "spoofed-git-directory"
    $ambientGit = Invoke-DaemonBuildFixture -Fixture $daemonBuildFixture -WorktreeRoot $daemonBuildFixture.linkedRoot
    Assert-True ($ambientGit.exitCode -ne 0 -and $ambientGit.output.Contains("GIT_DIR must be unset")) "Linked builds should reject ambient Git ownership overrides."
    Assert-True (-not $ambientGit.cargoRan) "An ambient Git directory should fail before Cargo runs."
    $env:GIT_DIR = $null

    Invoke-FixtureGit -WorkingDirectory $daemonBuildFixture.primaryRoot -Arguments @("worktree", "add", "--detach", $daemonBuildFixture.outsideLinkedRoot, "HEAD") | Out-Null
    $outsideLinked = Invoke-DaemonBuildFixture -Fixture $daemonBuildFixture -WorktreeRoot $daemonBuildFixture.outsideLinkedRoot
    Assert-True ($outsideLinked.exitCode -ne 0 -and $outsideLinked.output.Contains("primaryRoot/.worktree/<name>")) "Registered linked worktrees outside primaryRoot/.worktree should be rejected."
    Assert-True (-not $outsideLinked.cargoRan) "A linked worktree outside the owned layout should fail before Cargo runs."
  }
  finally {
    $env:PATH = $savedFixturePath
    $env:CARGO_HOME = $savedFixtureCargoHome
    $env:USERPROFILE = $savedFixtureUserProfile
    $env:SUBVERSIONR_TEST_DAEMON_PATH = $savedFixtureDaemonPath
    $env:SUBVERSIONR_TEST_CARGO_LOG = $savedFixtureCargoLog
    $env:SUBVERSIONR_TEST_RUSTC_LOG = $savedFixtureRustcLog
    foreach ($variableName in $gitLocalEnvironmentNames) {
      if ($savedGitEnvironment[$variableName].exists) {
        Set-Item -LiteralPath "Env:$variableName" -Value $savedGitEnvironment[$variableName].value
      }
      else {
        Remove-Item -LiteralPath "Env:$variableName" -ErrorAction SilentlyContinue
      }
    }
  }

  $releaseDirectory = Join-Path $repoRoot "target\release"
  $releaseDaemonPath = Join-Path $releaseDirectory "subversionr-daemon.exe"
  $savedReleaseDaemonBytes = if (Test-Path -LiteralPath $releaseDaemonPath -PathType Leaf) {
    [IO.File]::ReadAllBytes($releaseDaemonPath)
  }
  else {
    $null
  }
  New-Item -ItemType Directory -Force -Path $releaseDirectory | Out-Null
  New-TestPeFile -Path $releaseDaemonPath -DebugType 16
  $lockedReleaseDaemon = [IO.File]::Open($releaseDaemonPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  $savedStaleOutputCargoHomeExists = Test-Path -LiteralPath "Env:CARGO_HOME"
  $savedStaleOutputCargoHome = [Environment]::GetEnvironmentVariable("CARGO_HOME")
  try {
    Remove-Item -LiteralPath "Env:CARGO_HOME" -ErrorAction SilentlyContinue
    Assert-NativeCommandFailsContaining {
      & pwsh -NoProfile -ExecutionPolicy Bypass -File $buildDaemonScript
    } "subversionr-daemon.exe" "Release daemon build should fail before Cargo when the stale fixed-path output cannot be deleted."
  }
  finally {
    if ($savedStaleOutputCargoHomeExists) {
      Set-Item -LiteralPath "Env:CARGO_HOME" -Value $savedStaleOutputCargoHome
    }
    else {
      Remove-Item -LiteralPath "Env:CARGO_HOME" -ErrorAction SilentlyContinue
    }
    $lockedReleaseDaemon.Dispose()
    if ($null -ne $savedReleaseDaemonBytes) {
      [IO.File]::WriteAllBytes($releaseDaemonPath, $savedReleaseDaemonBytes)
    }
    else {
      Remove-Item -LiteralPath $releaseDaemonPath -Force -ErrorAction SilentlyContinue
    }
  }

  $lockPath = Join-Path $tempRoot "sources.lock.json"
  @'
{
  "sources": [
    {
      "name": "apache-subversion",
      "version": "1.14.5",
      "license": "Apache-2.0",
      "licenseUrl": "https://www.apache.org/licenses/LICENSE-2.0",
      "url": "https://downloads.apache.org/subversion/subversion-1.14.5.zip",
      "sha512": "subversion-sha512"
    },
    {
      "name": "apr",
      "version": "1.7.6",
      "license": "Apache-2.0",
      "licenseUrl": "https://www.apache.org/licenses/LICENSE-2.0",
      "url": "https://downloads.apache.org/apr/apr-1.7.6-win32-src.zip",
      "sha512": "apr-sha512"
    },
    {
      "name": "apr-util",
      "version": "1.6.3",
      "license": "Apache-2.0",
      "licenseUrl": "https://www.apache.org/licenses/LICENSE-2.0",
      "url": "https://downloads.apache.org/apr/apr-util-1.6.3-win32-src.zip",
      "sha512": "apr-util-sha512"
    },
    {
      "name": "apr-iconv",
      "version": "1.2.2",
      "license": "Apache-2.0",
      "licenseUrl": "https://www.apache.org/licenses/LICENSE-2.0",
      "url": "https://downloads.apache.org/apr/apr-iconv-1.2.2-win32-src.zip",
      "sha512": "apr-iconv-sha512"
    },
    {
      "name": "expat",
      "version": "2.8.1",
      "license": "MIT",
      "licenseUrl": "https://github.com/libexpat/libexpat/blob/R_2_8_1/expat/COPYING",
      "url": "https://github.com/libexpat/libexpat/releases/download/R_2_8_1/expat-2.8.1.tar.gz",
      "sha512": "expat-sha512"
    },
    {
      "name": "zlib",
      "version": "1.3.2",
      "license": "Zlib",
      "licenseUrl": "https://github.com/madler/zlib/blob/v1.3.2/LICENSE",
      "url": "https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.gz",
      "sha512": "zlib-sha512"
    },
    {
      "name": "openssl",
      "version": "3.5.7",
      "license": "Apache-2.0",
      "licenseUrl": "https://openssl-library.org/source/license/",
      "url": "https://github.com/openssl/openssl/releases/download/openssl-3.5.7/openssl-3.5.7.tar.gz",
      "sha512": "openssl-sha512"
    },
    {
      "name": "serf",
      "version": "1.3.10",
      "license": "Apache-2.0",
      "licenseUrl": "https://www.apache.org/licenses/LICENSE-2.0",
      "url": "https://downloads.apache.org/serf/serf-1.3.10.zip",
      "sha512": "serf-sha512"
    },
    {
      "name": "apache-httpd",
      "version": "2.4.68",
      "license": "Apache-2.0",
      "licenseUrl": "https://www.apache.org/licenses/LICENSE-2.0",
      "url": "https://downloads.apache.org/httpd/httpd-2.4.68.tar.gz",
      "sha512": "httpd-sha512"
    },
    {
      "name": "pcre2",
      "version": "10.47",
      "license": "BSD-3-Clause WITH PCRE2-exception",
      "licenseUrl": "https://github.com/PCRE2Project/pcre2/blob/pcre2-10.47/LICENCE.md",
      "url": "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.47/pcre2-10.47.tar.gz",
      "sha512": "pcre2-sha512"
    },
    {
      "name": "sqlite-amalgamation",
      "version": "3.53.2",
      "license": "Blessing",
      "licenseUrl": "https://sqlite.org/copyright.html",
      "url": "https://sqlite.org/2026/sqlite-amalgamation-3530200.zip",
      "sha512": "abc"
    }
  ]
}
'@ | Set-Content -LiteralPath $lockPath -NoNewline

  $lock = Read-NativeSourceLock -Path $lockPath
  $source = Get-NativeSourceEntry -Lock $lock -Name "sqlite-amalgamation"
  Assert-Equal "3.53.2" $source.version "Source version should come from the lock file."

  $realLock = Read-NativeSourceLock -Path (Join-Path $repoRoot "native\sources.lock.json")
  $serfSource = Get-NativeSourceEntry -Lock $realLock -Name "serf"
  Assert-SourceField $serfSource "version" "1.3.10" "Serf source lock should pin the current Apache Serf stable release."
  Assert-SourceField $serfSource "license" "Apache-2.0" "Serf source lock should record the SPDX license identifier."
  Assert-SourceField $serfSource "licenseUrl" "https://www.apache.org/licenses/LICENSE-2.0" "Serf source lock should record the Apache license URL."
  Assert-SourceField $serfSource "url" "https://downloads.apache.org/serf/serf-1.3.10.zip" "Serf source lock should use the Apache distribution backup URL, not an untracked mirror."
  Assert-SourceField $serfSource "sha512" "82e1c7342b0fa102c0e853989da0f6b590584e5a1d7737f891edd1d49b2a3ec271fd71f2642813455f73230c57230aebdc3a83808335dd53c5ce9fdab8506e2f" "Serf source lock should record the upstream SHA512 checksum."
  Assert-SourceField $serfSource "signatureUrl" "https://downloads.apache.org/serf/serf-1.3.10.zip.asc" "Serf source lock should require the upstream PGP signature."
  Assert-SourceField $serfSource "keysUrl" "https://downloads.apache.org/serf/KEYS" "Serf source lock should require the Apache Serf KEYS file."

  $opensslSource = Get-NativeSourceEntry -Lock $realLock -Name "openssl"
  Assert-SourceField $opensslSource "version" "3.5.7" "OpenSSL source lock should pin the current OpenSSL 3.5 LTS release."
  Assert-SourceField $opensslSource "license" "Apache-2.0" "OpenSSL source lock should record the SPDX license identifier for OpenSSL 3.x."
  Assert-SourceField $opensslSource "licenseUrl" "https://openssl-library.org/source/license/" "OpenSSL source lock should record the OpenSSL license page."
  Assert-SourceField $opensslSource "url" "https://github.com/openssl/openssl/releases/download/openssl-3.5.7/openssl-3.5.7.tar.gz" "OpenSSL source lock should use the official OpenSSL GitHub release artifact."
  Assert-SourceField $opensslSource "sha512" "de5351d2d532e1a3908a738f7d8aae448d32bc60bdb24808c556a24bc37a3f53daedf12b5d432eeb8c235e16939d842f908332ede8a447ca103ad1c493c820d7" "OpenSSL source lock should record the project SHA512 checksum."
  Assert-SourceField $opensslSource "sha256" "a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8" "OpenSSL source lock should record the upstream SHA256 checksum."
  Assert-SourceField $opensslSource "signatureUrl" "https://github.com/openssl/openssl/releases/download/openssl-3.5.7/openssl-3.5.7.tar.gz.asc" "OpenSSL source lock should require the upstream PGP signature."
  Assert-SourceField $opensslSource "keysUrl" "https://openssl-library.org/source/pubkeys.asc" "OpenSSL source lock should require the OpenSSL release signing keys."

  $httpdSource = Get-NativeSourceEntry -Lock $realLock -Name "apache-httpd"
  Assert-SourceField $httpdSource "version" "2.4.68" "M6v HTTPD source lock should pin the current Apache HTTP Server stable release."
  Assert-SourceField $httpdSource "license" "Apache-2.0" "M6v HTTPD source lock should record the SPDX license identifier."
  Assert-SourceField $httpdSource "licenseUrl" "https://www.apache.org/licenses/LICENSE-2.0" "M6v HTTPD source lock should record the Apache license URL."
  Assert-SourceField $httpdSource "url" "https://downloads.apache.org/httpd/httpd-2.4.68.tar.gz" "M6v HTTPD source lock should use the official Apache HTTP Server source distribution URL."
  Assert-SourceField $httpdSource "sha512" "de3d6e2dd37a600b99b63b6740a06348d6f7642109f3c35e7eb1b82088ade8a5da9145b52c232587b9c2604c33ae908d0009ada4ea3168679e7f061b3135112d" "M6v HTTPD source lock should record the upstream SHA512 checksum."
  Assert-SourceField $httpdSource "sha256" "ed9a9d4500fb48bb28eaffb3ba71d06ccf86d498fa13ab9f781da010cc488498" "M6v HTTPD source lock should record the upstream SHA256 checksum."
  Assert-SourceField $httpdSource "signatureUrl" "https://downloads.apache.org/httpd/httpd-2.4.68.tar.gz.asc" "M6v HTTPD source lock should require the upstream PGP signature."
  Assert-SourceField $httpdSource "keysUrl" "https://downloads.apache.org/httpd/KEYS" "M6v HTTPD source lock should require the Apache HTTP Server KEYS file."

  $pcre2Source = Get-NativeSourceEntry -Lock $realLock -Name "pcre2"
  Assert-SourceField $pcre2Source "version" "10.47" "M6v PCRE2 source lock should pin the current PCRE2 release."
  Assert-SourceField $pcre2Source "license" "BSD-3-Clause WITH PCRE2-exception" "M6v PCRE2 source lock should record the upstream SPDX license expression."
  Assert-SourceField $pcre2Source "licenseUrl" "https://github.com/PCRE2Project/pcre2/blob/pcre2-10.47/LICENCE.md" "M6v PCRE2 source lock should record the upstream license file URL."
  Assert-SourceField $pcre2Source "url" "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.47/pcre2-10.47.tar.gz" "M6v PCRE2 source lock should use the official GitHub release source artifact."
  Assert-SourceField $pcre2Source "sha512" "e461a95f623fe70136b1a070847f317c56f9a31801181cc8fd7eef8077ae6cccd385d5ccb983f6e9b49245830535e7acddb10c6831c20afb9bdf4f9a45ae48eb" "M6v PCRE2 source lock should record the project SHA512 checksum."
  Assert-SourceField $pcre2Source "sha256" "c08ae2388ef333e8403e670ad70c0a11f1eed021fd88308d7e02f596fcd9dc16" "M6v PCRE2 source lock should record the upstream SHA256 checksum."
  Assert-SourceField $pcre2Source "signatureUrl" "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.47/pcre2-10.47.tar.gz.sig" "M6v PCRE2 source lock should require the upstream GPG signature."
  Assert-SourceField $pcre2Source "keysUrl" "https://keys.openpgp.org/vks/v1/by-fingerprint/A95536204A3BB489715231282A98E77EB6F24CA8" "M6v PCRE2 source lock should pin the documented Nicholas Wilson release-signing key by fingerprint."

  $buildDependenciesText = Get-Content -Raw -LiteralPath $buildDependenciesScript
  Assert-True ($buildDependenciesText.Contains('"openssl"')) "M6r dependency build script should expose an OpenSSL target."
  Assert-True ($buildDependenciesText.Contains('"serf"')) "M6r dependency build script should expose a Serf target."
  Assert-True ($buildDependenciesText.Contains("function Build-OpenSsl")) "M6r dependency build script should build OpenSSL from the locked source."
  Assert-True ($buildDependenciesText.Contains("Get-RequiredSourceDateEpoch | Out-Null")) "M6r OpenSSL build should fail fast without an explicit reproducible source epoch."
  Assert-True ($buildDependenciesText.Contains("function Build-Serf")) "M6r dependency build script should build Serf from the locked source."
  Assert-True ($buildDependenciesText.Contains("function Invoke-SerfOpenSslLinkProbe")) "M6r dependency build script should include a Serf/OpenSSL mutual link probe."
  Assert-True ($buildDependenciesText.Contains('Assert-RequiredCommand "perl"') -and $buildDependenciesText.Contains('Assert-RequiredCommand "nasm"')) "M6r OpenSSL build should fail fast when required upstream Windows tools are missing."
  Assert-True ($buildDependenciesText.Contains("serf_error_string") -and $buildDependenciesText.Contains("OpenSSL_version")) "M6r link probe should reference real Serf and OpenSSL symbols."
  Assert-True ($buildDependenciesText.Contains("Invoke-SerfOpenSslLinkProbe -StageRoot")) "M6r Serf build should run the mutual link probe after staging."
  Assert-True ($buildDependenciesText.Contains("serf_openssl_link_probe.obj") -and $buildDependenciesText.Contains("/Fo")) "M6r link probe should keep compiler object output inside the probe work directory."
  Assert-True ($buildDependenciesText.Contains("PYTHONIOENCODING=utf-8")) "M6r Serf SCons invocation should force UTF-8 Python output for configure diagnostics."
  Assert-True ($buildDependenciesText.Contains("LINKFLAGS=/LIBPATH:")) "M6r Serf SCons invocation should pass the staged lib directory to SCons link checks."
  Assert-True ($buildDependenciesText.Contains("libserf-1.lib")) "M6r link probe should use the Serf DLL import library."
  Assert-True ($buildDependenciesText.Contains('"pcre2"')) "M6w PCRE2 staging gate should expose a PCRE2 dependency build target."
  Assert-True ($buildDependenciesText.Contains("function Build-Pcre2")) "M6w PCRE2 staging gate should build PCRE2 from the locked source."
  Assert-True ($buildDependenciesText.Contains("Invoke-Pcre2RawLinkProbe")) "M6w PCRE2 staging gate should include a raw MSVC static link probe."
  Assert-True ($buildDependenciesText.Contains("Invoke-Pcre2CMakeConsumerProbe")) "M6w PCRE2 staging gate should include a CMake package consumer probe."
  Assert-True ($buildDependenciesText.Contains("PCRE2::8BIT")) "M6w CMake consumer probe should link the official installed PCRE2 8-bit target."
  Assert-True ($buildDependenciesText.Contains("-DPCRE2_BUILD_PCRE2_8=ON")) "M6w PCRE2 build should enable the 8-bit library required by Apache HTTP Server."
  Assert-True ($buildDependenciesText.Contains("-DPCRE2_BUILD_PCRE2_16=OFF") -and $buildDependenciesText.Contains("-DPCRE2_BUILD_PCRE2_32=OFF")) "M6w PCRE2 build should disable unused 16-bit and 32-bit libraries."
  Assert-True ($buildDependenciesText.Contains("-DPCRE2_BUILD_TESTS=OFF") -and $buildDependenciesText.Contains("-DPCRE2_BUILD_PCRE2GREP=OFF")) "M6w PCRE2 dependency staging should not build upstream test tools or pcre2grep."
  Assert-True ($buildDependenciesText.Contains("-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL")) "M6w PCRE2 build and consumer probe should pin the MSVC runtime flavor."
  Assert-True ($buildDependenciesText.Contains("CMAKE_PREFIX_PATH")) "M6w PCRE2 CMake consumer probe should discover the staged package through CMAKE_PREFIX_PATH."
  Assert-True (-not $buildDependenciesText.Contains('"apache-httpd"')) "M6x Apache HTTP Server staging should use the dedicated build-httpd.ps1 entrypoint instead of the client dependency stage script."
  Assert-True (-not $buildDependenciesText.Contains("function Build-ApacheHttpd")) "M6x Apache HTTP Server staging should not be implemented inside build-dependencies.ps1."

  $moduleText = Get-Content -Raw -LiteralPath $modulePath
  Assert-True ($moduleText.Contains("function Assert-Pcre2StageForHttpd")) "M6w native module should expose a PCRE2 stage assertion for future httpd fixture builds."
  Assert-True ($moduleText.Contains("pcre2-8-static.lib")) "M6w PCRE2 stage assertion should require the MSVC static 8-bit library."
  Assert-True ($moduleText.Contains("pcre2-config.cmake") -and $moduleText.Contains("pcre2-targets.cmake")) "M6w PCRE2 stage assertion should require the installed CMake package files."
  Assert-True ($moduleText.Contains("PCRE2_PRERELEASE")) "M6w PCRE2 stage assertion should reject prerelease headers."
  Assert-True ($moduleText.Contains("function Assert-AprPrivateHeadersForHttpd")) "M6x native module should expose an APR private-header assertion for Apache HTTP Server builds."
  Assert-True ($moduleText.Contains("function Assert-ApacheHttpdStageForDavFixture")) "M6x native module should expose an Apache HTTP Server DAV fixture stage assertion."
  Assert-True ($moduleText.Contains("subversionr-httpd-stage-manifest.json")) "M6x native module should define the Apache HTTP Server stage manifest path."
  Assert-True ($moduleText.Contains("function Assert-GeneratedSubversionApacheModuleProjectGraph")) "M6y native module should validate generated Apache Subversion DAV module projects."
  Assert-True ($moduleText.Contains("function Assert-ApacheHttpdSubversionDavStage")) "M6y native module should expose the composite Apache HTTPD/Subversion DAV stage assertion."
  Assert-True ($moduleText.Contains("function Copy-ApacheHttpdSubversionDavStage")) "M6y native module should stage the composite Apache HTTPD/Subversion DAV runtime."
  Assert-True ($moduleText.Contains("subversionr-httpd-subversion-dav-stage-manifest.json")) "M6y native module should define an independent DAV module composite stage manifest path."

  Assert-True (Test-Path -LiteralPath $buildHttpdScript -PathType Leaf) "M6x should provide a dedicated Apache HTTP Server build entrypoint."
  $buildHttpdText = Get-Content -Raw -LiteralPath $buildHttpdScript
  Assert-True ($buildHttpdText.Contains('Get-NativeSourceEntry -Lock $lock -Name "apache-httpd"')) "M6x HTTPD script should build the locked Apache HTTP Server source."
  Assert-True ($buildHttpdText.Contains("Assert-RequiredFile `$VsDevCmd") -and $buildHttpdText.Contains("Visual Studio developer command")) "M6x HTTPD script should validate VsDevCmd before clearing generated directories."
  Assert-True ($buildHttpdText.Contains("function Assert-IndependentHttpdStageRoot") -and $buildHttpdText.Contains("StageRoot must be independent from DependencyStageRoot")) "M6x HTTPD script should reject stage roots that overlap the dependency stage."
  Assert-True ($buildHttpdText.Contains("Assert-AprPrivateHeadersForHttpd")) "M6x HTTPD script should fail fast when APR private headers are missing."
  Assert-True ($buildHttpdText.Contains("Assert-Pcre2StageForHttpd")) "M6x HTTPD script should require the staged static PCRE2 package."
  Assert-True ($buildHttpdText.Contains("-DPCRE2_DIR=") -and $buildHttpdText.Contains("-DPCRE_LIBRARIES=PCRE2::8BIT")) "M6x HTTPD script should bind CMake to the staged PCRE2 package target."
  Assert-True ($buildHttpdText.Contains("-DPCRE_CFLAGS=") -and $buildHttpdText.Contains("PCRE2_STATIC")) "M6x HTTPD script should propagate PCRE2_STATIC into libhttpd compilation."
  Assert-True ($buildHttpdText.Contains("-DEXTRA_COMPILE_FLAGS=") -and $buildHttpdText.Contains("NETIOAPI_API_=WINAPI") -and $buildHttpdText.Contains("IF_NAMESIZE=256")) "M6x HTTPD script should reuse the APR Windows network compile definitions required by APR private headers."
  Assert-True ($buildHttpdText.Contains("CMAKE_DISABLE_FIND_PACKAGE_LibXml2=ON") -and $buildHttpdText.Contains("CMAKE_DISABLE_FIND_PACKAGE_Lua51=ON") -and $buildHttpdText.Contains("CMAKE_DISABLE_FIND_PACKAGE_CURL=ON")) "M6x HTTPD script should disable unowned optional package discovery."
  Assert-True ($buildHttpdText.Contains('Assert-CMakeCacheValue -CacheContent $cacheContent -Name "CMAKE_DISABLE_FIND_PACKAGE_LibXml2" -Expected "ON"') -and $buildHttpdText.Contains('Assert-CMakeCacheValue -CacheContent $cacheContent -Name "CMAKE_DISABLE_FIND_PACKAGE_Lua51" -Expected "ON"') -and $buildHttpdText.Contains('Assert-CMakeCacheValue -CacheContent $cacheContent -Name "CMAKE_DISABLE_FIND_PACKAGE_CURL" -Expected "ON"')) "M6x HTTPD script should verify disabled unowned package discovery persisted in CMakeCache."
  Assert-True ($buildHttpdText.Contains("-DENABLE_DAV=I") -and $buildHttpdText.Contains("-DENABLE_SSL=I") -and $buildHttpdText.Contains("-DENABLE_DEFLATE=I")) "M6x HTTPD script should build DAV, SSL, and deflate modules as inactive substrate gates."
  Assert-True ($buildHttpdText.Contains("-DENABLE_DAV_FS=O") -and $buildHttpdText.Contains("-DENABLE_DAV_LOCK=O")) "M6x HTTPD script should not build repository-serving DAV modules before the mod_dav_svn gate."
  Assert-True ($buildHttpdText.Contains('Assert-CMakeCacheValue -CacheContent $cacheContent -Name "ENABLE_MODULES" -Expected "O"') -and $buildHttpdText.Contains('Assert-CMakeCacheValue -CacheContent $cacheContent -Name "ENABLE_DAV" -Expected "I"') -and $buildHttpdText.Contains('Assert-CMakeCacheValue -CacheContent $cacheContent -Name "ENABLE_DAV_FS" -Expected "O"') -and $buildHttpdText.Contains('Assert-CMakeCacheValue -CacheContent $cacheContent -Name "ENABLE_DAV_LOCK" -Expected "O"') -and $buildHttpdText.Contains('Assert-CMakeCacheValue -CacheContent $cacheContent -Name "ENABLE_SSL" -Expected "I"') -and $buildHttpdText.Contains('Assert-CMakeCacheValue -CacheContent $cacheContent -Name "ENABLE_DEFLATE" -Expected "I"')) "M6x HTTPD script should verify the requested substrate module switches persisted in CMakeCache."
  Assert-True ($buildHttpdText.Contains("Assert-ApacheHttpdStageForDavFixture")) "M6x HTTPD script should validate the installed stage after copying support runtimes."

  $packageJsonText = Get-Content -Raw -LiteralPath $packageJsonPath
  Assert-True ($packageJsonText.Contains('"native:build-daemon:release": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/native/build-daemon.ps1"')) "Package scripts should expose the deterministic release daemon build entrypoint."
  Assert-True ($packageJsonText.Contains('"native:build-httpd:staged"')) "M6x package scripts should expose the staged Apache HTTP Server build gate."
  Assert-True ($packageJsonText.Contains('"native:build-subversion-dav-modules:staged"')) "M6y package scripts should expose the staged Subversion DAV module build gate."
  Assert-True ($packageJsonText.Contains('"native:smoke-httpd-dav-https:staged"')) "M6z package scripts should expose the staged HTTPS DAV fixture smoke gate."
  Assert-True ($packageJsonText.Contains('"native:smoke-malicious-dav-xml:staged"')) "M7l5 package scripts should expose the staged malicious DAV/XML fixture smoke gate."
  Assert-True ($packageJsonText.Contains('"native:smoke-malicious-svn-server-response:staged"')) "M7l6 package scripts should expose the staged malicious SVN server-response fixture smoke gate."

  Assert-True (Test-Path -LiteralPath $buildDavModulesScript -PathType Leaf) "M6y should provide a dedicated Subversion DAV module build entrypoint."
  $buildDavModulesText = Get-Content -Raw -LiteralPath $buildDavModulesScript
  Assert-True ($buildDavModulesText.Contains('Assert-RequiredFile $VsDevCmd') -and $buildDavModulesText.Contains("Visual Studio developer command")) "M6y DAV module script should validate VsDevCmd before clearing generated directories."
  Assert-True ($buildDavModulesText.Contains("Assert-ApacheHttpdStageForDavFixture")) "M6y DAV module script should validate the clean Apache HTTP Server substrate before generation."
  Assert-True ($buildDavModulesText.Contains('--with-httpd=$httpdStageRootResolved')) "M6y DAV module generator should receive the verified Apache HTTP Server stage root."
  Assert-True ($buildDavModulesText.Contains("Assert-GeneratedSubversionApacheModuleProjectGraph")) "M6y DAV module script should verify the generated Apache module project graph."
  Assert-True ($buildDavModulesText.Contains("mod_authz_svn.vcxproj")) "M6y DAV module script should build the module project that references mod_dav_svn."
  Assert-True ($buildDavModulesText.Contains("/p:SolutionDir=")) "M6y DAV module script should pass an explicit SolutionDir when building generated vcxproj files directly."
  Assert-True ($buildDavModulesText.Contains("Copy-ApacheHttpdSubversionDavStage")) "M6y DAV module script should populate a separate composite runtime stage."
  Assert-True ($buildDavModulesText.Contains("Invoke-SubversionDavModuleLoadProbe")) "M6y DAV module script should run a load-only httpd module probe."
  Assert-True (-not $buildDavModulesText.Contains('[IO.Path]::PathSeparator + $oldPath')) "M6y DAV module load probe must not keep inherited PATH entries that could satisfy missing DLLs from system SVN/Tortoise installs."
  Assert-True ($buildDavModulesText.Contains("SVNPath") -and $buildDavModulesText.Contains("SVNParentPath")) "M6y DAV module script should explicitly reject repository-serving probe directives."
  Assert-True ($buildDavModulesText.Contains('@{ Name = "DependencyStageRoot"; Value = $dependencyStageRootResolved }') -and $buildDavModulesText.Contains('-CandidateName "WorkRoot" -ExistingName $protectedRoot.Name') -and $buildDavModulesText.Contains('-CandidateName "WorkRoot" -ExistingName "StageRoot"')) "M6y DAV module script should prove WorkRoot is independent from protected native roots before clearing it."
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $buildDavModulesScript `
      -DependencyStageRoot $tempRoot `
      -HttpdStageRoot $tempRoot `
      -SubversionStageRoot $tempRoot `
      -StageRoot (Join-Path $tempRoot "unused-dav-stage") `
      -SkipVerifySources
  } "VsDevCmd is required" "M6y DAV module build entrypoint should require an explicit Visual Studio developer command before staging work."

  Assert-True (Test-Path -LiteralPath $smokeHttpdDavHttpsScript -PathType Leaf) "M6z should provide a dedicated HTTPS DAV fixture smoke entrypoint."
  $smokeHttpdDavHttpsText = Get-Content -Raw -LiteralPath $smokeHttpdDavHttpsScript
  Assert-True ($smokeHttpdDavHttpsText.Contains("SUBVERSIONR_TEST_HTTPD_DAV_STAGE")) "M6z HTTPS DAV smoke should provide the staged Apache HTTPD/Subversion DAV runtime to Rust tests."
  Assert-True ($smokeHttpdDavHttpsText.Contains("native_bridge_https_dav_content_and_update_route_certificate_trust_through_broker")) "M6z HTTPS DAV smoke should run the exact bridge integration test for successful content/update flows."
  Assert-True ($smokeHttpdDavHttpsText.Contains("Resolve-Path -LiteralPath")) "M6z HTTPS DAV smoke should fail fast on missing staged native artifacts."

  Assert-True (Test-Path -LiteralPath $smokeMaliciousDavXmlScript -PathType Leaf) "M7l5 should provide a dedicated malicious DAV/XML fixture smoke entrypoint."
  $smokeMaliciousDavXmlText = Get-Content -Raw -LiteralPath $smokeMaliciousDavXmlScript
  Assert-True ($smokeMaliciousDavXmlText.Contains("SUBVERSIONR_TEST_BRIDGE_DLL")) "M7l5 malicious DAV/XML smoke should provide the staged bridge DLL to Rust tests."
  Assert-True ($smokeMaliciousDavXmlText.Contains("native_bridge_malicious_dav_xml_history_log_fails_without_auth_prompts_or_crash")) "M7l5 malicious DAV/XML smoke should run the exact deterministic Rust fixture test."
  Assert-True ($smokeMaliciousDavXmlText.Contains("Resolve-Path -LiteralPath")) "M7l5 malicious DAV/XML smoke should fail fast on missing staged native artifacts."
  Assert-True ($smokeMaliciousDavXmlText.Contains('"svn.exe"')) "M7l5 malicious DAV/XML smoke should require the staged source-built svn client before cargo starts."
  Assert-True ($smokeMaliciousDavXmlText.Contains('"svnadmin.exe"')) "M7l5 malicious DAV/XML smoke should require the staged source-built svnadmin tool before cargo starts."

  Assert-True (Test-Path -LiteralPath $smokeMaliciousSvnServerResponseScript -PathType Leaf) "M7l6 should provide a dedicated malicious SVN server-response fixture smoke entrypoint."
  $smokeMaliciousSvnServerResponseText = Get-Content -Raw -LiteralPath $smokeMaliciousSvnServerResponseScript
  Assert-True ($smokeMaliciousSvnServerResponseText.Contains("SUBVERSIONR_TEST_BRIDGE_DLL")) "M7l6 malicious SVN server-response smoke should provide the staged bridge DLL to Rust tests."
  Assert-True ($smokeMaliciousSvnServerResponseText.Contains("native_bridge_malicious_svn_server_response_history_log_fails_without_auth_prompts_or_crash")) "M7l6 malicious SVN server-response smoke should run the exact deterministic Rust fixture test."
  Assert-True ($smokeMaliciousSvnServerResponseText.Contains("Resolve-Path -LiteralPath")) "M7l6 malicious SVN server-response smoke should fail fast on missing staged native artifacts."
  Assert-True ($smokeMaliciousSvnServerResponseText.Contains('"svn.exe"')) "M7l6 malicious SVN server-response smoke should require the staged source-built svn client before cargo starts."
  Assert-True ($smokeMaliciousSvnServerResponseText.Contains('"svnadmin.exe"')) "M7l6 malicious SVN server-response smoke should require the staged source-built svnadmin tool before cargo starts."
  Assert-True ($smokeMaliciousSvnServerResponseText.Contains('"svnserve.exe"')) "M7l6 malicious SVN server-response smoke should require the staged source-built svnserve fixture server before cargo starts."

  $pcre2Stage = Join-Path $tempRoot "pcre2-stage"
  foreach ($directory in @(
    "include",
    "lib",
    "bin",
    "lib\cmake\pcre2"
  )) {
    New-Item -ItemType Directory -Force -Path (Join-Path $pcre2Stage $directory) | Out-Null
  }
  @'
#define PCRE2_MAJOR 10
#define PCRE2_MINOR 47
#define PCRE2_PRERELEASE
'@ | Set-Content -LiteralPath (Join-Path $pcre2Stage "include\pcre2.h") -Encoding ascii -NoNewline
  New-Item -ItemType File -Force -Path (Join-Path $pcre2Stage "lib\pcre2-8-static.lib") | Out-Null
  "PCRE2 config" | Set-Content -LiteralPath (Join-Path $pcre2Stage "lib\cmake\pcre2\pcre2-config.cmake") -Encoding ascii -NoNewline
  "add_library(pcre2::pcre2-8-static STATIC IMPORTED)`nset_target_properties(pcre2::pcre2-8-static PROPERTIES INTERFACE_COMPILE_DEFINITIONS PCRE2_STATIC)" | Set-Content -LiteralPath (Join-Path $pcre2Stage "lib\cmake\pcre2\pcre2-targets.cmake") -Encoding ascii -NoNewline
  "set_property(TARGET pcre2::pcre2-8-static PROPERTY IMPORTED_LOCATION_RELEASE pcre2-8-static.lib)" | Set-Content -LiteralPath (Join-Path $pcre2Stage "lib\cmake\pcre2\pcre2-targets-release.cmake") -Encoding ascii -NoNewline
  Assert-Equal (Resolve-Path $pcre2Stage).Path (Assert-Pcre2StageForHttpd -StageRoot $pcre2Stage -ExpectedVersion "10.47") "PCRE2 stage assertion should accept the locked 10.47 static stage."

  @'
#define PCRE2_MAJOR 10
#define PCRE2_MINOR 47
#define PCRE2_PRERELEASE ""
'@ | Set-Content -LiteralPath (Join-Path $pcre2Stage "include\pcre2.h") -Encoding ascii -NoNewline
  Assert-Equal (Resolve-Path $pcre2Stage).Path (Assert-Pcre2StageForHttpd -StageRoot $pcre2Stage -ExpectedVersion "10.47") "PCRE2 stage assertion should accept an empty-string prerelease marker from generated release headers."

  Remove-Item -LiteralPath (Join-Path $pcre2Stage "lib\pcre2-8-static.lib") -Force
  Assert-ThrowsContaining {
    Assert-Pcre2StageForHttpd -StageRoot $pcre2Stage -ExpectedVersion "10.47"
  } "pcre2-8-static.lib" "PCRE2 stage assertion should require the static 8-bit library."
  New-Item -ItemType File -Force -Path (Join-Path $pcre2Stage "lib\pcre2-8-static.lib") | Out-Null

  @'
#define PCRE2_MAJOR 10
#define PCRE2_MINOR 46
#define PCRE2_PRERELEASE
'@ | Set-Content -LiteralPath (Join-Path $pcre2Stage "include\pcre2.h") -Encoding ascii -NoNewline
  Assert-ThrowsContaining {
    Assert-Pcre2StageForHttpd -StageRoot $pcre2Stage -ExpectedVersion "10.47"
  } "10.47" "PCRE2 stage assertion should reject headers that do not match the source lock."

  @'
#define PCRE2_MAJOR 10
#define PCRE2_MINOR 47
#define PCRE2_PRERELEASE -RC1
'@ | Set-Content -LiteralPath (Join-Path $pcre2Stage "include\pcre2.h") -Encoding ascii -NoNewline
  Assert-ThrowsContaining {
    Assert-Pcre2StageForHttpd -StageRoot $pcre2Stage -ExpectedVersion "10.47"
  } "prerelease" "PCRE2 stage assertion should reject prerelease headers."

  @'
#define PCRE2_MAJOR 10
#define PCRE2_MINOR 47
#define PCRE2_PRERELEASE
'@ | Set-Content -LiteralPath (Join-Path $pcre2Stage "include\pcre2.h") -Encoding ascii -NoNewline
  New-Item -ItemType File -Force -Path (Join-Path $pcre2Stage "bin\pcre2-8.dll") | Out-Null
  Assert-ThrowsContaining {
    Assert-Pcre2StageForHttpd -StageRoot $pcre2Stage -ExpectedVersion "10.47"
  } "static-only" "PCRE2 stage assertion should reject shared runtime artifacts for this gate."
  Remove-Item -LiteralPath (Join-Path $pcre2Stage "bin\pcre2-8.dll") -Force

  $aprHttpdStage = Join-Path $tempRoot "apr-httpd-stage"
  foreach ($directory in @(
    "include\arch\win32",
    "include\arch",
    "lib",
    "bin"
  )) {
    New-Item -ItemType Directory -Force -Path (Join-Path $aprHttpdStage $directory) | Out-Null
  }
  foreach ($file in @(
    "include\apr.h",
    "include\apu.h",
    "include\apr_pools.h",
    "include\apr_iconv.h",
    "lib\libapr-1.lib",
    "lib\libaprutil-1.lib",
    "lib\libapriconv-1.lib",
    "bin\libapr-1.dll",
    "bin\libaprutil-1.dll",
    "bin\libapriconv-1.dll",
    "include\arch\win32\apr_arch_file_io.h",
    "include\arch\win32\apr_arch_misc.h",
    "include\arch\win32\apr_arch_utf8.h",
    "include\arch\win32\apr_private.h",
    "include\arch\apr_private_common.h"
  )) {
    New-Item -ItemType File -Force -Path (Join-Path $aprHttpdStage $file) | Out-Null
  }
  Assert-Equal (Resolve-Path $aprHttpdStage).Path (Assert-AprPrivateHeadersForHttpd -StageRoot $aprHttpdStage) "APR private-header assertion should accept the HTTPD-ready APR stage."
  Remove-Item -LiteralPath (Join-Path $aprHttpdStage "include\arch\win32\apr_arch_misc.h") -Force
  Assert-ThrowsContaining {
    Assert-AprPrivateHeadersForHttpd -StageRoot $aprHttpdStage
  } "apr_arch_misc.h" "APR private-header assertion should reject a stage that cannot build Apache HTTP Server."

  $httpdStage = Join-Path $tempRoot "httpd-stage"
  foreach ($directory in @(
    "bin",
    "bin\iconv",
    "conf",
    "include",
    "lib",
    "modules"
  )) {
    New-Item -ItemType Directory -Force -Path (Join-Path $httpdStage $directory) | Out-Null
  }
  foreach ($file in @(
    "bin\httpd.exe",
    "bin\libhttpd.dll",
    "bin\libapr-1.dll",
    "bin\libaprutil-1.dll",
    "bin\libapriconv-1.dll",
    "bin\libexpat.dll",
    "bin\libcrypto-3-x64.dll",
    "bin\libssl-3-x64.dll",
    "bin\iconv\utf-8.so",
    "conf\httpd.conf",
    "include\ap_release.h",
    "include\httpd.h",
    "include\http_config.h",
    "include\mod_dav.h",
    "include\mod_ssl.h",
    "include\mod_ssl_openssl.h",
    "lib\libhttpd.lib",
    "lib\mod_dav.lib",
    "modules\mod_dav.so",
    "modules\mod_ssl.so",
    "modules\mod_deflate.so"
  )) {
    New-Item -ItemType File -Force -Path (Join-Path $httpdStage $file) | Out-Null
  }
  @'
#define AP_SERVER_MAJORVERSION_NUMBER 2
#define AP_SERVER_MINORVERSION_NUMBER 4
#define AP_SERVER_PATCHLEVEL_NUMBER 68
'@ | Set-Content -LiteralPath (Join-Path $httpdStage "include\ap_release.h") -Encoding ascii -NoNewline
  $httpdDependencyManifestEntries = @()
  foreach ($dependencyName in @("apr", "apr-util", "apr-iconv", "expat", "pcre2", "openssl", "zlib")) {
    $dependencySource = Get-NativeSourceEntry -Lock $lock -Name $dependencyName
    $httpdDependencyManifestEntries += @{
      name = Get-RequiredProperty -Object $dependencySource -Name "name"
      version = Get-RequiredProperty -Object $dependencySource -Name "version"
      url = Get-RequiredProperty -Object $dependencySource -Name "url"
      sha512 = Get-RequiredProperty -Object $dependencySource -Name "sha512"
    }
  }
  $httpdManifestSource = Get-NativeSourceEntry -Lock $lock -Name "apache-httpd"
  @{
    schema = "subversionr.native.httpd-stage.v1"
    kind = "apache-httpd-dav-fixture-runtime"
    arch = "x64"
    configuration = "Release"
    source = @{
      name = Get-RequiredProperty -Object $httpdManifestSource -Name "name"
      version = Get-RequiredProperty -Object $httpdManifestSource -Name "version"
      url = Get-RequiredProperty -Object $httpdManifestSource -Name "url"
      sha512 = Get-RequiredProperty -Object $httpdManifestSource -Name "sha512"
    }
    dependencies = $httpdDependencyManifestEntries
  } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $httpdStage "subversionr-httpd-stage-manifest.json") -Encoding ascii
  Assert-Equal (Resolve-Path $httpdStage).Path (Assert-ApacheHttpdStageForDavFixture -StageRoot $httpdStage -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch "x64" -ExpectedConfiguration "Release") "Apache HTTP Server stage assertion should accept the minimal M6x DAV fixture substrate."
  New-Item -ItemType File -Force -Path (Join-Path $httpdStage "modules\mod_dav_svn.so") | Out-Null
  Assert-ThrowsContaining {
    Assert-ApacheHttpdStageForDavFixture -StageRoot $httpdStage -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch "x64" -ExpectedConfiguration "Release"
  } "mod_dav_svn" "Apache HTTP Server stage assertion should reject Subversion DAV modules before the dedicated gate."
  Remove-Item -LiteralPath (Join-Path $httpdStage "modules\mod_dav_svn.so") -Force
  New-Item -ItemType File -Force -Path (Join-Path $httpdStage "bin\pcre2-8.dll") | Out-Null
  Assert-ThrowsContaining {
    Assert-ApacheHttpdStageForDavFixture -StageRoot $httpdStage -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch "x64" -ExpectedConfiguration "Release"
  } "pcre2-8*.dll" "Apache HTTP Server stage assertion should reject PCRE2 runtime DLLs because PCRE2 is static in this gate."
  Remove-Item -LiteralPath (Join-Path $httpdStage "bin\pcre2-8.dll") -Force

  $buildSubversionText = Get-Content -Raw -LiteralPath $buildSubversionScript
  $ciWorkflowText = Get-Content -Raw -LiteralPath $ciWorkflow
  $fastPrWorkflowText = Get-Content -Raw -LiteralPath $fastPrWorkflow
  Assert-True ($ciWorkflowText.Contains("pnpm native:build-daemon:release")) "CI should use the deterministic release daemon build entrypoint."
  $releaseSidecarStepIndex = $ciWorkflowText.IndexOf("- name: Build release sidecar", [StringComparison]::Ordinal)
  $releaseSidecarStepEndIndex = $ciWorkflowText.IndexOf("`n      - name:", $releaseSidecarStepIndex + 1, [StringComparison]::Ordinal)
  Assert-True ($releaseSidecarStepIndex -ge 0 -and $releaseSidecarStepEndIndex -gt $releaseSidecarStepIndex) "CI should expose one bounded release-sidecar step."
  $releaseSidecarStep = $ciWorkflowText.Substring($releaseSidecarStepIndex, $releaseSidecarStepEndIndex - $releaseSidecarStepIndex)
  $cargoHomeRemoval = "Remove-Item -LiteralPath Env:CARGO_HOME -ErrorAction Stop"
  $cargoHomeRemovalIndex = $releaseSidecarStep.IndexOf($cargoHomeRemoval, [StringComparison]::Ordinal)
  $cargoHomePostcondition = 'throw "CARGO_HOME must be absent before the repository-owned release daemon build."'
  $cargoHomePostconditionIndex = $releaseSidecarStep.IndexOf($cargoHomePostcondition, [StringComparison]::Ordinal)
  $releaseDaemonBuild = "pnpm native:build-daemon:release"
  $releaseDaemonBuildIndex = $releaseSidecarStep.IndexOf($releaseDaemonBuild, [StringComparison]::Ordinal)
  Assert-Equal 1 ([regex]::Matches($releaseSidecarStep, [regex]::Escape($cargoHomeRemoval)).Count) "The release-sidecar step should normalize the runner Cargo home exactly once."
  Assert-Equal 1 ([regex]::Matches($releaseSidecarStep, [regex]::Escape($cargoHomePostcondition)).Count) "The release-sidecar step should prove the runner Cargo home is absent exactly once."
  Assert-Equal 1 ([regex]::Matches($releaseSidecarStep, [regex]::Escape($releaseDaemonBuild)).Count) "The release-sidecar step should invoke the deterministic build exactly once."
  Assert-True (
    $cargoHomeRemovalIndex -ge 0 -and
    $cargoHomePostconditionIndex -gt $cargoHomeRemovalIndex -and
    $releaseDaemonBuildIndex -gt $cargoHomePostconditionIndex
  ) "CI should remove and verify the runner Cargo home inside one release-sidecar step before invoking the deterministic build."
  Assert-True (-not $ciWorkflowText.Contains("cargo build -p subversionr-daemon --release")) "CI must not bypass deterministic daemon validation with a raw Cargo release build."
  Assert-True ($ciWorkflowText.Contains("toolchain: 1.96.0")) "Heavy CI should install the repository-pinned Rust release."
  Assert-True ($fastPrWorkflowText.Contains("toolchain: 1.96.0")) "PR Fast should install the repository-pinned Rust release."
  Assert-True ($buildSubversionText.Contains('[string]$SerfRoot')) "M6s Subversion build entrypoint should require an explicit Serf stage root."
  Assert-True ($buildSubversionText.Contains('[string]$OpenSslRoot')) "M6s Subversion build entrypoint should require an explicit OpenSSL stage root."
  Assert-True ($buildSubversionText.Contains('Assert-SerfStageForSubversion -StageRoot $serfRootResolved')) "M6s Subversion build should fail fast on invalid Serf staging."
  Assert-True ($buildSubversionText.Contains('Assert-OpenSslStageForSerf -StageRoot $openSslRootResolved')) "M6s Subversion build should fail fast on invalid OpenSSL staging."
  Assert-True ($buildSubversionText.Contains('--with-serf=$serfRootResolved')) "M6s Subversion generator should receive the staged Serf install root."
  Assert-True ($buildSubversionText.Contains('--with-openssl=$openSslRootResolved')) "M6s Subversion generator should receive the staged OpenSSL install root."
  Assert-True ($buildSubversionText.Contains('Assert-SameResolvedDirectory $dependencyRoot.Value $dependencyStageRootResolved $dependencyRoot.Name')) "M6s Subversion build should reject generator roots that differ from the packaged dependency stage."
  Assert-True ($buildSubversionText.Contains('Assert-GeneratedSubversionRaSerfProjectGraph -SourceRoot $sourceRoot')) "M6s Subversion build should verify the generated ra_serf MSBuild project graph."
  Assert-True ($buildSubversionText.Contains('Set-SubversionReproducibleBuildTimestamp -SourceRoot $sourceRoot')) "M6s Subversion build should replace upstream compile-time clock macros with the explicit source epoch."
  Assert-True ($buildSubversionText.Contains('Assert-SubversionRaSerfRegistration -StageRoot $subversionStageRoot')) "M6s Subversion build should verify staged svn.exe reports ra_serf for http and https."
  Assert-True ($ciWorkflowText.Contains('-SerfRoot .cache/native/stage/subversion-deps-win-x64')) "CI Subversion build should pass the staged Serf root required by M6s."
  Assert-True ($ciWorkflowText.Contains('-OpenSslRoot .cache/native/stage/subversion-deps-win-x64')) "CI Subversion build should pass the staged OpenSSL root required by M6s."
  Assert-True ($ciWorkflowText.Contains("Build Subversion Apache DAV modules")) "CI should run the M6y Subversion DAV module gate after building libsvn and httpd."
  Assert-True ($ciWorkflowText.Contains("scripts/native/build-subversion-dav-modules.ps1")) "CI should call the dedicated M6y DAV module build script."
  Assert-True ($ciWorkflowText.Contains("-HttpdStageRoot .cache/native/stage/httpd-win-x64")) "CI M6y DAV module gate should consume the clean staged httpd substrate."
  Assert-True ($ciWorkflowText.Contains("-StageRoot .cache/native/stage/httpd-subversion-dav-win-x64")) "CI M6y DAV module gate should write a separate composite DAV runtime stage."
  Assert-True ($ciWorkflowText.Contains("-SubversionStageRoot .cache/native/stage/subversion-win-x64")) "CI M6y DAV module gate should consume the staged source-built Subversion runtime."
  Assert-True ($ciWorkflowText.Contains('SUBVERSIONR_TEST_OPENSSL_EXE')) "CI native integration should provide the staged OpenSSL executable required by M6t."
  Assert-True ($ciWorkflowText.Contains('SUBVERSIONR_TEST_HTTPD_DAV_STAGE')) "CI native integration should provide the staged Apache HTTPD/Subversion DAV runtime required by M6z."
  Assert-True ($ciWorkflowText.Contains('Smoke native malicious DAV XML fixture')) "CI should run the M7l5 malicious DAV/XML fixture smoke gate after building the native bridge."
  Assert-True ($ciWorkflowText.Contains('scripts/native/smoke-malicious-dav-xml.ps1')) "CI should call the dedicated M7l5 malicious DAV/XML smoke script."
  Assert-True ($ciWorkflowText.Contains('Smoke native malicious SVN server-response fixture')) "CI should run the M7l6 malicious SVN server-response fixture smoke gate after building the native bridge."
  Assert-True ($ciWorkflowText.Contains('scripts/native/smoke-malicious-svn-server-response.ps1')) "CI should call the dedicated M7l6 malicious SVN server-response smoke script."
  Assert-True ($ciWorkflowText.Contains('Install NASM 3.01')) "CI should install the NASM version required by the OpenSSL Windows build before native dependency staging."
  Assert-True ($ciWorkflowText.Contains('Set reproducible source date epoch') -and $ciWorkflowText.Contains('SOURCE_DATE_EPOCH=$epoch')) "CI should export the versioned reproducible native build epoch."
  Assert-True ($ciWorkflowText.Contains('LINK: /Brepro')) "CI should require reproducible MSVC linking for native release artifacts."
  Assert-True ($ciWorkflowText.IndexOf('Set reproducible source date epoch', [StringComparison]::Ordinal) -lt $ciWorkflowText.IndexOf('Build native dependency stage', [StringComparison]::Ordinal)) "CI should export the source epoch before building native dependencies."
  Assert-True ($ciWorkflowText.Contains('native/release-build-epoch.txt') -and $ciWorkflowText.Contains("-notmatch '^[1-9][0-9]*\r?\n$'") -and $ciWorkflowText.Contains('$env:GITHUB_ENV')) "CI should require one versioned positive epoch and export it through GITHUB_ENV."
  Assert-Equal "1783993493`n" ((Get-Content -Raw -LiteralPath (Join-Path $repoRoot "native\release-build-epoch.txt")).Replace("`r`n", "`n")) "The 0.2.4 native release epoch should remain bound to the public release-slice base commit."
  Assert-True ($ciWorkflowText.Contains('https://www.nasm.us/pub/nasm/releasebuilds/$version/win64/$archiveName')) "CI NASM install should use the official NASM release archive URL."
  Assert-True ($ciWorkflowText.Contains('e0ba5157007abc7b1a65118a96657a961ddf55f7e3f632ee035366dfce039ca4')) "CI NASM install should verify the pinned win64 archive SHA256."
  Assert-True ($ciWorkflowText.Contains('Get-Command nasm -ErrorAction Stop')) "CI native prerequisite checks should fail fast when NASM is not on PATH."

  $raSerfBlock = Get-SubversionRaSerfRegistrationBlock -VersionText @'
* ra_svn : Module for accessing a repository using the svn network protocol.
  - handles 'svn' scheme
* ra_serf : Module for accessing a repository via WebDAV protocol using serf.
  - handles 'http' scheme
  - handles 'https' scheme
* ra_local : Module for accessing a repository on local disk.
  - handles 'file' scheme
'@
  Assert-True ($raSerfBlock.Contains("- handles 'http' scheme") -and $raSerfBlock.Contains("- handles 'https' scheme")) "ra_serf parser should return only the ra_serf registration block."
  $raSerfHttpOnlyBlock = Get-SubversionRaSerfRegistrationBlock -VersionText @'
* ra_serf : Module for accessing a repository via WebDAV protocol using serf.
  - handles 'http' scheme
* ra_svn : Module for accessing a repository using the svn network protocol.
  - handles 'https' scheme
'@
  Assert-True (-not $raSerfHttpOnlyBlock.Contains("- handles 'https' scheme")) "ra_serf parser should not accept schemes reported by later RA modules."
  Assert-ThrowsContaining {
    Get-SubversionRaSerfRegistrationBlock -VersionText "* ra_svn : Module`n  - handles 'svn' scheme"
  } "ra_serf" "ra_serf parser should fail when the module block is absent."

  $bridgeSource = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "native\svn-bridge\src\subversionr_bridge.c")
  $bridgeHeader = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "native\svn-bridge\include\subversionr_bridge.h")
  $nativeRust = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "crates\subversionr-daemon\src\native.rs")
  Assert-True (
    $bridgeSource.Contains("const svn_boolean_t no_ignore = FALSE;") -and
    $bridgeSource.Contains("const svn_boolean_t ignore_externals = TRUE;") -and
    $bridgeSource -match "svn_client_status6\([\s\S]*scan_depth,\s*get_all,\s*check_out_of_date,\s*check_working_copy,\s*no_ignore,\s*ignore_externals,\s*depth_as_sticky,"
  ) "Bridge status scan should call svn_client_status6 with default ignored entries suppressed and externals ignored."
  Assert-True (
    $bridgeHeader.Contains("subversionr_bridge_status_remote_scan_with_auth") -and
    $bridgeSource.Contains("subversionr_bridge_status_remote_scan_with_auth") -and
    $nativeRust.Contains("subversionr_bridge_status_remote_scan_with_auth")
  ) "Remote status C ABI and native loader must require one auth-aware remote scan symbol."
  Assert-True (
    $bridgeHeader.Contains("repos_node_status") -and
    $bridgeHeader.Contains("repos_text_status") -and
    $bridgeHeader.Contains("repos_property_status") -and
    $bridgeSource.Contains("status->repos_node_status") -and
    $bridgeSource.Contains("status->ood_changed_rev")
  ) "Remote status ABI must copy libsvn repository status and out-of-date metadata."
  Assert-True (
    $bridgeSource -match "subversionr_bridge_status_remote_scan_with_auth\([\s\S]*svn_depth_unknown,\s*FALSE,\s*TRUE,\s*FALSE,"
  ) "Explicit remote status must use ambient depth, interesting entries, repository out-of-date checking, and no duplicate working-copy scan."
  Assert-True (
    $bridgeSource.Contains("bridge_error_is_auth_failure") -and
    $bridgeSource.Contains("SVN_ERR_RA_NOT_AUTHORIZED") -and
    $bridgeSource.Contains("SVN_ERR_AUTHN_FAILED")
  ) "Explicit remote status must preserve libsvn authentication failures as a stable auth result."
  Assert-True (
    $nativeRust.Contains("subversionr_bridge_content_get_with_auth")
  ) "Native loader must require the auth-aware content symbol to fail fast on old bridge DLLs."
  Assert-True (
    $nativeRust.Contains("subversionr_bridge_history_log_with_auth")
  ) "Native loader must require the auth-aware history log symbol to fail fast on old bridge DLLs."
  Assert-True (
    $nativeRust.Contains("subversionr_bridge_history_blame_with_auth")
  ) "Native loader must require the auth-aware history blame symbol to fail fast on old bridge DLLs."
  Assert-True (
    $nativeRust.Contains("subversionr_bridge_operation_commit_with_auth")
  ) "Native loader must require the auth-aware commit symbol to fail fast on old bridge DLLs."
  Assert-True (
    $bridgeHeader.Contains("subversionr_bridge_content_get_with_auth") -and
    $bridgeSource.Contains("subversionr_bridge_content_get_with_auth") -and
    -not ($bridgeHeader -match "subversionr_bridge_content_get\s*\(") -and
    -not ($bridgeSource -match "int\s+subversionr_bridge_content_get\s*\(")
  ) "Content C ABI must not reuse the old content_get symbol name after adding auth callbacks."
  Assert-True (
    $bridgeHeader.Contains("subversionr_bridge_history_log_with_auth") -and
    $bridgeSource.Contains("subversionr_bridge_history_log_with_auth") -and
    -not ($bridgeHeader -match "subversionr_bridge_history_log\s*\(") -and
    -not ($bridgeSource -match "int\s+subversionr_bridge_history_log\s*\(")
  ) "History log C ABI must not reuse the old history_log symbol name after adding auth callbacks."
  Assert-True (
    $bridgeHeader.Contains("subversionr_bridge_history_blame_with_auth") -and
    $bridgeSource.Contains("subversionr_bridge_history_blame_with_auth") -and
    -not ($bridgeHeader -match "subversionr_bridge_history_blame\s*\(") -and
    -not ($bridgeSource -match "int\s+subversionr_bridge_history_blame\s*\(")
  ) "History blame C ABI must not reuse the old history_blame symbol name after adding auth callbacks."
  Assert-True (
    $bridgeHeader.Contains("subversionr_bridge_operation_commit_with_auth") -and
    $bridgeSource.Contains("subversionr_bridge_operation_commit_with_auth") -and
    -not ($bridgeHeader -match "subversionr_bridge_operation_commit\s*\(") -and
    -not ($bridgeSource -match "int\s+subversionr_bridge_operation_commit\s*\(")
  ) "Commit C ABI must not reuse the old operation_commit symbol name after adding auth callbacks."

  $archivePath = Get-NativeArchivePath -CacheRoot (Join-Path $tempRoot "sources") -Source $source
  Assert-Equal "sqlite-amalgamation-3530200.zip" (Split-Path -Leaf $archivePath) "Archive path should use URL filename."

  $checksumFixturePath = Join-Path $tempRoot "checksum-fixture.txt"
  "SubversionR checksum fixture" | Set-Content -LiteralPath $checksumFixturePath -Encoding ascii -NoNewline
  $checksumFixtureSha512 = (Get-FileHash -LiteralPath $checksumFixturePath -Algorithm SHA512).Hash.ToLowerInvariant()
  $checksumFixtureSha256 = (Get-FileHash -LiteralPath $checksumFixturePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $checksumSource = [pscustomobject]@{
    name = "checksum-fixture"
    url = "https://example.invalid/checksum-fixture.txt"
    sha512 = $checksumFixtureSha512
    sha256 = $checksumFixtureSha256
  }
  Assert-Equal $checksumFixturePath (Assert-NativeArchiveChecksum -ArchivePath $checksumFixturePath -Source $checksumSource) "Checksum verification should return the verified archive path."
  $badSha512Source = [pscustomobject]@{
    name = "checksum-fixture"
    url = "https://example.invalid/checksum-fixture.txt"
    sha512 = "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
  }
  Assert-ThrowsContaining {
    Assert-NativeArchiveChecksum -ArchivePath $checksumFixturePath -Source $badSha512Source
  } "SHA512 mismatch" "Checksum verification should fail when the required SHA512 lock is mismatched."
  $badSha256Source = [pscustomobject]@{
    name = "checksum-fixture"
    url = "https://example.invalid/checksum-fixture.txt"
    sha512 = $checksumFixtureSha512
    sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
  }
  Assert-ThrowsContaining {
    Assert-NativeArchiveChecksum -ArchivePath $checksumFixturePath -Source $badSha256Source
  } "SHA256 mismatch" "Checksum verification should fail when an optional SHA256 lock is present and mismatched."

  $stageRoot = New-NativeStageLayout -Path (Join-Path $tempRoot "stage")
  foreach ($child in @("include", "lib", "bin")) {
    Assert-True (Test-Path -LiteralPath (Join-Path $stageRoot $child) -PathType Container) "Stage layout should create $child."
  }

  $generatedRoot = Join-Path $tempRoot "generated"
  New-Item -ItemType Directory -Force -Path $generatedRoot | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $generatedRoot "stale.txt") | Out-Null
  $cleanedRoot = Clear-NativeGeneratedDirectory -Path $generatedRoot -WorkspaceRoot $repoRoot -Description "test generated directory"
  Assert-True (Test-Path -LiteralPath $cleanedRoot -PathType Container) "Generated directory cleanup should recreate the target directory."
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $cleanedRoot "stale.txt") -PathType Leaf)) "Generated directory cleanup should remove stale files."

  $outsideGeneratedRoot = Join-Path ([IO.Path]::GetTempPath()) "subversionr-refuse-$([Guid]::NewGuid().ToString('N'))"
  Assert-ThrowsContaining {
    Clear-NativeGeneratedDirectory -Path $outsideGeneratedRoot -WorkspaceRoot $repoRoot -Description "outside generated directory"
  } "outside repository generated roots" "Generated directory cleanup should reject paths outside repository generated roots."
  Assert-ThrowsContaining {
    Clear-NativeGeneratedDirectory -Path (Join-Path $repoRoot ".cache") -WorkspaceRoot $repoRoot -Description "cache root"
  } "outside repository generated roots" "Generated directory cleanup should reject deleting the repository cache root itself."

  $zlibGoodStage = New-NativeStageLayout -Path (Join-Path $tempRoot "zlib-good")
  New-Item -ItemType File -Force -Path (Join-Path $zlibGoodStage "include\zlib.h") | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $zlibGoodStage "include\zconf.h") | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $zlibGoodStage "lib\zlib.lib") | Out-Null

  $zlibLibrary = Assert-ZlibStageForSubversion -StageRoot $zlibGoodStage
  Assert-Equal (Join-Path $zlibGoodStage "lib\zlib.lib") $zlibLibrary "Zlib stage check should return the accepted library path."

  $zlibBadStage = New-NativeStageLayout -Path (Join-Path $tempRoot "zlib-bad")
  New-Item -ItemType File -Force -Path (Join-Path $zlibBadStage "include\zlib.h") | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $zlibBadStage "include\zconf.h") | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $zlibBadStage "lib\zs.lib") | Out-Null
  Assert-ThrowsContaining { Assert-ZlibStageForSubversion -StageRoot $zlibBadStage } "zlib.lib" "Zlib stage check should reject unsupported CMake static library names."

  $expatGoodStage = New-NativeStageLayout -Path (Join-Path $tempRoot "expat-good")
  New-Item -ItemType File -Force -Path (Join-Path $expatGoodStage "include\expat.h") | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $expatGoodStage "include\expat_external.h") | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $expatGoodStage "lib\libexpat.lib") | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $expatGoodStage "bin\libexpat.dll") | Out-Null

  $expatLibrary = Assert-ExpatStageForAprUtil -StageRoot $expatGoodStage
  Assert-Equal (Join-Path $expatGoodStage "lib\libexpat.lib") $expatLibrary "Expat stage check should return the APR-util link library path."

  $expatBadStage = New-NativeStageLayout -Path (Join-Path $tempRoot "expat-bad")
  New-Item -ItemType File -Force -Path (Join-Path $expatBadStage "include\expat.h") | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $expatBadStage "include\expat_external.h") | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $expatBadStage "lib\expat.lib") | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $expatBadStage "bin\libexpat.dll") | Out-Null
  Assert-ThrowsContaining { Assert-ExpatStageForAprUtil -StageRoot $expatBadStage } "libexpat.lib" "Expat stage check should reject unsupported APR-util link library names."

  $aprGoodStage = New-NativeStageLayout -Path (Join-Path $tempRoot "apr-good")
  foreach ($file in @(
    "include\apr.h",
    "include\apu.h",
    "include\apr_pools.h",
    "include\apr_iconv.h",
    "lib\libapr-1.lib",
    "lib\libaprutil-1.lib",
    "lib\libapriconv-1.lib",
    "bin\libapr-1.dll",
    "bin\libaprutil-1.dll",
    "bin\libapriconv-1.dll"
  )) {
    New-Item -ItemType File -Force -Path (Join-Path $aprGoodStage $file) | Out-Null
  }

  $aprStage = Assert-AprStageForSubversion -StageRoot $aprGoodStage
  Assert-Equal $aprGoodStage $aprStage "APR stage check should return the stage root."

  $aprBadStage = New-NativeStageLayout -Path (Join-Path $tempRoot "apr-bad")
  foreach ($file in @(
    "include\apr.h",
    "include\apu.h",
    "include\apr_pools.h",
    "include\apr_iconv.h",
    "lib\libapr-1.lib",
    "lib\libapriconv-1.lib",
    "bin\libapr-1.dll",
    "bin\libaprutil-1.dll",
    "bin\libapriconv-1.dll"
  )) {
    New-Item -ItemType File -Force -Path (Join-Path $aprBadStage $file) | Out-Null
  }
  Assert-ThrowsContaining { Assert-AprStageForSubversion -StageRoot $aprBadStage } "libaprutil-1.lib" "APR stage check should report missing APR-util library."

  $openSslGoodStage = New-NativeStageLayout -Path (Join-Path $tempRoot "openssl-good")
  New-Item -ItemType Directory -Force -Path (Join-Path $openSslGoodStage "include\openssl") | Out-Null
  @'
# define OPENSSL_VERSION_TEXT "OpenSSL 3.5.7 1 Jul 2026"
'@ | Set-Content -LiteralPath (Join-Path $openSslGoodStage "include\openssl\opensslv.h") -Encoding ascii -NoNewline
  foreach ($file in @(
    "include\openssl\ssl.h",
    "include\openssl\crypto.h",
    "lib\libssl.lib",
    "lib\libcrypto.lib",
    "bin\libssl-3-x64.dll",
    "bin\libcrypto-3-x64.dll"
  )) {
    New-Item -ItemType File -Force -Path (Join-Path $openSslGoodStage $file) | Out-Null
  }
  $openSslStage = Assert-OpenSslStageForSerf -StageRoot $openSslGoodStage -ExpectedVersion "3.5.7"
  Assert-Equal $openSslGoodStage $openSslStage "OpenSSL stage check should return the stage root."

  $openSslBadStage = New-NativeStageLayout -Path (Join-Path $tempRoot "openssl-bad")
  New-Item -ItemType Directory -Force -Path (Join-Path $openSslBadStage "include\openssl") | Out-Null
  @'
# define OPENSSL_VERSION_TEXT "OpenSSL 3.5.7 1 Jul 2026"
'@ | Set-Content -LiteralPath (Join-Path $openSslBadStage "include\openssl\opensslv.h") -Encoding ascii -NoNewline
  foreach ($file in @(
    "include\openssl\ssl.h",
    "include\openssl\crypto.h",
    "lib\libcrypto.lib",
    "bin\libssl-3-x64.dll",
    "bin\libcrypto-3-x64.dll"
  )) {
    New-Item -ItemType File -Force -Path (Join-Path $openSslBadStage $file) | Out-Null
  }
  Assert-ThrowsContaining { Assert-OpenSslStageForSerf -StageRoot $openSslBadStage -ExpectedVersion "3.5.7" } "libssl.lib" "OpenSSL stage check should report missing import libraries."

  $serfGoodStage = New-NativeStageLayout -Path (Join-Path $tempRoot "serf-good")
  New-Item -ItemType Directory -Force -Path (Join-Path $serfGoodStage "include\serf-1") | Out-Null
  @'
#define SERF_MAJOR_VERSION 1
#define SERF_MINOR_VERSION 3
#define SERF_PATCH_VERSION 10
'@ | Set-Content -LiteralPath (Join-Path $serfGoodStage "include\serf-1\serf.h") -Encoding ascii -NoNewline
  foreach ($file in @(
    "include\serf-1\serf_bucket_types.h",
    "include\serf-1\serf_bucket_util.h",
    "lib\serf-1.lib",
    "lib\libserf-1.lib",
    "bin\libserf-1.dll"
  )) {
    New-Item -ItemType File -Force -Path (Join-Path $serfGoodStage $file) | Out-Null
  }
  $serfStage = Assert-SerfStageForSubversion -StageRoot $serfGoodStage -ExpectedVersion "1.3.10"
  Assert-Equal $serfGoodStage $serfStage "Serf stage check should return the stage root."

  $serfBadStage = New-NativeStageLayout -Path (Join-Path $tempRoot "serf-bad")
  New-Item -ItemType Directory -Force -Path (Join-Path $serfBadStage "include\serf-1") | Out-Null
  @'
#define SERF_MAJOR_VERSION 1
#define SERF_MINOR_VERSION 3
#define SERF_PATCH_VERSION 10
'@ | Set-Content -LiteralPath (Join-Path $serfBadStage "include\serf-1\serf.h") -Encoding ascii -NoNewline
  foreach ($file in @(
    "include\serf-1\serf_bucket_types.h",
    "include\serf-1\serf_bucket_util.h",
    "lib\serf-1.lib",
    "lib\libserf-1.lib"
  )) {
    New-Item -ItemType File -Force -Path (Join-Path $serfBadStage $file) | Out-Null
  }
  Assert-ThrowsContaining { Assert-SerfStageForSubversion -StageRoot $serfBadStage -ExpectedVersion "1.3.10" } "libserf-1.dll" "Serf stage check should report a missing shared runtime."

  $subversionSourceRootForStage = Join-Path $tempRoot "subversion-stage-source"
  $subversionIncludeRoot = Join-Path $subversionSourceRootForStage "subversion\include"
  $subversionReleaseRoot = Join-Path $subversionSourceRootForStage "Release\subversion"
  New-Item -ItemType Directory -Force -Path $subversionIncludeRoot | Out-Null
  foreach ($header in @("svn_client.h", "svn_wc.h")) {
    New-Item -ItemType File -Force -Path (Join-Path $subversionIncludeRoot $header) | Out-Null
  }
  @'
#define SVN_VER_MAJOR 1
#define SVN_VER_MINOR 14
#define SVN_VER_PATCH 5
'@ | Set-Content -LiteralPath (Join-Path $subversionIncludeRoot "svn_version.h") -Encoding ascii -NoNewline
  foreach ($library in @("client", "delta", "diff", "fs", "fs_fs", "fs_util", "fs_x", "ra", "ra_serf", "repos", "subr", "wc")) {
    $libraryRoot = Join-Path $subversionReleaseRoot "libsvn_$library"
    New-Item -ItemType Directory -Force -Path $libraryRoot | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $libraryRoot "libsvn_$library-1.lib") | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $libraryRoot "svn_$library-1.lib") | Out-Null
    if ($library -ne "ra_serf") {
      New-Item -ItemType File -Force -Path (Join-Path $libraryRoot "libsvn_$library-1.dll") | Out-Null
    }
  }
  foreach ($tool in @("svn", "svnadmin", "svnserve")) {
    $toolRoot = Join-Path $subversionReleaseRoot $tool
    New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $toolRoot "$tool.exe") | Out-Null
  }

  $currentSubversionDependencyFiles = @(
    "include\apr.h",
    "include\apu.h",
    "include\apr_pools.h",
    "include\apr_iconv.h",
    "include\expat.h",
    "include\expat_external.h",
    "include\sqlite3.h",
    "include\zconf.h",
    "include\zlib.h",
    "lib\libapr-1.lib",
    "lib\libapriconv-1.lib",
    "lib\libaprutil-1.lib",
    "lib\libexpat.lib",
    "lib\sqlite3.lib",
    "lib\zlib.lib",
    "bin\libapr-1.dll",
    "bin\libapriconv-1.dll",
    "bin\libexpat.dll",
    "bin\libaprutil-1.dll"
  )
  $futureHttpsDependencyFiles = @(
    "include\openssl\crypto.h",
    "include\openssl\opensslv.h",
    "include\openssl\ssl.h",
    "include\serf-1\serf.h",
    "include\serf-1\serf_bucket_types.h",
    "include\serf-1\serf_bucket_util.h",
    "lib\libcrypto.lib",
    "lib\libssl.lib",
    "lib\serf-1.lib",
    "lib\libserf-1.lib",
    "bin\libcrypto-3-x64.dll",
    "bin\libssl-3-x64.dll",
    "bin\libserf-1.dll"
  )

  $subversionDependencyStage = New-NativeStageLayout -Path (Join-Path $tempRoot "subversion-deps-stage")
  foreach ($file in @($currentSubversionDependencyFiles + $futureHttpsDependencyFiles)) {
    New-Item -ItemType File -Force -Path (Join-Path $subversionDependencyStage $file) | Out-Null
  }
  @'
# define OPENSSL_VERSION_TEXT "OpenSSL 3.5.7 1 Jul 2026"
'@ | Set-Content -LiteralPath (Join-Path $subversionDependencyStage "include\openssl\opensslv.h") -Encoding ascii -NoNewline
  @'
#define SERF_MAJOR_VERSION 1
#define SERF_MINOR_VERSION 3
#define SERF_PATCH_VERSION 10
'@ | Set-Content -LiteralPath (Join-Path $subversionDependencyStage "include\serf-1\serf.h") -Encoding ascii -NoNewline
  New-Item -ItemType Directory -Force -Path (Join-Path $subversionDependencyStage "bin\iconv") | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $subversionDependencyStage "bin\iconv\utf-8.so") | Out-Null
  Assert-SubversionDependencyStage -StageRoot $subversionDependencyStage | Out-Null

  $subversionMinimalDependencyStage = New-NativeStageLayout -Path (Join-Path $tempRoot "subversion-minimal-deps-stage")
  foreach ($file in $currentSubversionDependencyFiles) {
    New-Item -ItemType File -Force -Path (Join-Path $subversionMinimalDependencyStage $file) | Out-Null
  }
  New-Item -ItemType Directory -Force -Path (Join-Path $subversionMinimalDependencyStage "bin\iconv") | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $subversionMinimalDependencyStage "bin\iconv\utf-8.so") | Out-Null
  Assert-ThrowsContaining {
    Assert-SubversionDependencyStage -StageRoot $subversionMinimalDependencyStage
  } "OpenSSL" "M6s Subversion dependency stage should require the HTTPS dependency closure."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $buildSubversionScript `
      -AprRoot $subversionDependencyStage `
      -AprUtilRoot $subversionDependencyStage `
      -AprIconvRoot $subversionDependencyStage `
      -SqliteRoot $subversionDependencyStage `
      -ZlibRoot $subversionDependencyStage `
      -DependencyStageRoot $subversionDependencyStage `
      -StageRoot (Join-Path $tempRoot "unused-subversion-stage")
  } "SerfRoot is required" "M6s Subversion build entrypoint should require an explicit Serf root before toolchain setup."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $buildDependenciesScript -Only "apr-layout" -SkipVerifySources
  } "VsDevCmd is required" "Dependency build entrypoint should require an explicit Visual Studio developer command."
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $buildSubversionScript `
      -AprRoot $subversionDependencyStage `
      -AprUtilRoot $subversionDependencyStage `
      -AprIconvRoot $subversionDependencyStage `
      -SqliteRoot $subversionDependencyStage `
      -ZlibRoot $subversionDependencyStage `
      -SerfRoot $subversionDependencyStage `
      -OpenSslRoot $subversionDependencyStage `
      -DependencyStageRoot $subversionDependencyStage `
      -StageRoot (Join-Path $tempRoot "unused-subversion-stage")
  } "VsDevCmd is required" "Subversion build entrypoint should require an explicit Visual Studio developer command."

  $mismatchedSerfRoot = Join-Path $tempRoot "mismatched-serf-root"
  New-Item -ItemType Directory -Force -Path $mismatchedSerfRoot | Out-Null
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $buildSubversionScript `
      -AprRoot $subversionDependencyStage `
      -AprUtilRoot $subversionDependencyStage `
      -AprIconvRoot $subversionDependencyStage `
      -SqliteRoot $subversionDependencyStage `
      -ZlibRoot $subversionDependencyStage `
      -SerfRoot $mismatchedSerfRoot `
      -OpenSslRoot $subversionDependencyStage `
      -DependencyStageRoot $subversionDependencyStage `
      -StageRoot (Join-Path $tempRoot "unused-subversion-stage")
  } "SerfRoot must resolve to DependencyStageRoot" "Subversion build entrypoint should reject generator roots that differ from the packaged dependency stage."

  $subversionBadDependencyStage = New-NativeStageLayout -Path (Join-Path $tempRoot "subversion-bad-deps-stage")
  foreach ($file in @(
    "include\apr.h",
    "include\apu.h",
    "include\apr_pools.h",
    "include\apr_iconv.h",
    "include\expat.h",
    "include\expat_external.h",
    "include\sqlite3.h",
    "include\openssl\crypto.h",
    "include\openssl\opensslv.h",
    "include\openssl\ssl.h",
    "include\serf-1\serf.h",
    "include\serf-1\serf_bucket_types.h",
    "include\serf-1\serf_bucket_util.h",
    "include\zconf.h",
    "include\zlib.h",
    "lib\libapr-1.lib",
    "lib\libapriconv-1.lib",
    "lib\libaprutil-1.lib",
    "lib\libexpat.lib",
    "lib\libcrypto.lib",
    "lib\libssl.lib",
    "lib\serf-1.lib",
    "lib\libserf-1.lib",
    "lib\zlib.lib",
    "bin\libapr-1.dll",
    "bin\libapriconv-1.dll",
    "bin\libexpat.dll",
    "bin\libaprutil-1.dll",
    "bin\libcrypto-3-x64.dll",
    "bin\libssl-3-x64.dll",
    "bin\libserf-1.dll"
  )) {
    New-Item -ItemType File -Force -Path (Join-Path $subversionBadDependencyStage $file) | Out-Null
  }
  @'
# define OPENSSL_VERSION_TEXT "OpenSSL 3.5.7 1 Jul 2026"
'@ | Set-Content -LiteralPath (Join-Path $subversionBadDependencyStage "include\openssl\opensslv.h") -Encoding ascii -NoNewline
  @'
#define SERF_MAJOR_VERSION 1
#define SERF_MINOR_VERSION 3
#define SERF_PATCH_VERSION 10
'@ | Set-Content -LiteralPath (Join-Path $subversionBadDependencyStage "include\serf-1\serf.h") -Encoding ascii -NoNewline
  Assert-ThrowsContaining { Assert-SubversionDependencyStage -StageRoot $subversionBadDependencyStage } "sqlite3.lib" "Subversion dependency stage should report missing SQLite import library."
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $buildSubversionScript `
      -AprRoot $subversionBadDependencyStage `
      -AprUtilRoot $subversionBadDependencyStage `
      -AprIconvRoot $subversionBadDependencyStage `
      -SqliteRoot $subversionBadDependencyStage `
      -ZlibRoot $subversionBadDependencyStage `
      -SerfRoot $subversionBadDependencyStage `
      -OpenSslRoot $subversionBadDependencyStage `
      -DependencyStageRoot $subversionBadDependencyStage `
      -StageRoot (Join-Path $tempRoot "unused-subversion-stage") `
      -VsDevCmd (Join-Path $tempRoot "missing-vs-dev-cmd.bat")
  } "SQLite stage for Subversion is missing required file" "Subversion build entrypoint should reject incomplete dependency stages before toolchain setup."

  $subversionBridgeStage = Join-Path $tempRoot "subversion-bridge-stage"
  New-Item -ItemType Directory -Force -Path $subversionBridgeStage | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $subversionBridgeStage "stale.txt") | Out-Null
  $subversionTargetStage = Join-Path $repoRoot "target\native\tests\subversion-bridge-stage-$([Guid]::NewGuid().ToString('N'))"
  Assert-ThrowsContaining {
    Copy-SubversionBuildStage `
      -SourceRoot $subversionSourceRootForStage `
      -DependencyStageRoot $subversionDependencyStage `
      -StageRoot $subversionTargetStage `
      -WorkspaceRoot $repoRoot `
      -SourceLockPath $lockPath `
      -Arch "x64" `
      -Configuration "Release"
  } "must be under .cache" "Subversion bridge stage should reject target roots before doing staging work."

  $copiedStage = Copy-SubversionBuildStage `
    -SourceRoot $subversionSourceRootForStage `
    -DependencyStageRoot $subversionDependencyStage `
    -StageRoot $subversionBridgeStage `
    -WorkspaceRoot $repoRoot `
    -SourceLockPath $lockPath `
    -Arch "x64" `
    -Configuration "Release"
  Assert-Equal (Resolve-Path $subversionBridgeStage).Path $copiedStage "Subversion bridge stage should return the staged root."
  Assert-SubversionStageForBridge -StageRoot $subversionBridgeStage -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch "x64" -ExpectedConfiguration "Release" | Out-Null
  Assert-True (Test-Path -LiteralPath (Join-Path $subversionBridgeStage "include\subversion-1\svn_client.h") -PathType Leaf) "Subversion bridge stage should contain public headers."
  Assert-True (Test-Path -LiteralPath (Join-Path $subversionBridgeStage "lib\libsvn_client-1.lib") -PathType Leaf) "Subversion bridge stage should include DLL import libraries."
  Assert-True (Test-Path -LiteralPath (Join-Path $subversionBridgeStage "lib\libsvn_ra-1.lib") -PathType Leaf) "Subversion bridge stage should include the RA DLL import library."
  Assert-True (Test-Path -LiteralPath (Join-Path $subversionBridgeStage "lib\libsvn_ra_serf-1.lib") -PathType Leaf) "M6s Subversion bridge stage should include the source-built ra_serf static library."
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $subversionBridgeStage "bin\libsvn_ra_serf-1.dll") -PathType Leaf)) "M6s Subversion bridge stage should not require a ra_serf DLL because the Windows generator links ra_serf into libsvn_ra."
  Assert-True (Test-Path -LiteralPath (Join-Path $subversionBridgeStage "bin\svn.exe") -PathType Leaf) "Subversion bridge stage should include the fixture svn client built from source."
  Assert-True (Test-Path -LiteralPath (Join-Path $subversionBridgeStage "bin\svnadmin.exe") -PathType Leaf) "Subversion bridge stage should include the fixture svnadmin tool built from source."
  Assert-True (Test-Path -LiteralPath (Join-Path $subversionBridgeStage "bin\svnserve.exe") -PathType Leaf) "Subversion bridge stage should include the fixture svnserve server built from source."
  Assert-True (Test-Path -LiteralPath (Join-Path $subversionBridgeStage "subversionr-stage-manifest.json") -PathType Leaf) "Subversion bridge stage should include a manifest."
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $subversionBridgeStage "stale.txt") -PathType Leaf)) "Subversion bridge stage should remove stale files."
  Assert-True (Test-Path -LiteralPath (Join-Path $subversionBridgeStage "include\openssl\ssl.h") -PathType Leaf) "M6s Subversion bridge stage should copy OpenSSL headers."
  Assert-True (Test-Path -LiteralPath (Join-Path $subversionBridgeStage "include\serf-1\serf.h") -PathType Leaf) "M6s Subversion bridge stage should copy Serf headers."
  foreach ($httpsDependencyFile in @("lib\libcrypto.lib", "lib\libssl.lib", "lib\serf-1.lib", "bin\libcrypto-3-x64.dll", "bin\libssl-3-x64.dll")) {
    Assert-True (Test-Path -LiteralPath (Join-Path $subversionBridgeStage $httpsDependencyFile) -PathType Leaf) "M6s Subversion bridge stage should copy HTTPS dependency file: $httpsDependencyFile"
  }
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $subversionBridgeStage "bin\libserf-1.dll") -PathType Leaf)) "M6s Subversion bridge runtime should not copy the Serf DLL when the source-built RA DLL links static Serf."
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $subversionBridgeStage "lib\libserf-1.lib") -PathType Leaf)) "M6s Subversion bridge stage should not copy the Serf DLL import library when the source-built RA DLL links static Serf."

  New-Item -ItemType File -Force -Path (Join-Path $subversionBridgeStage "bin\libserf-1.dll") | Out-Null
  Assert-ThrowsContaining {
    Assert-SubversionStageForBridge -StageRoot $subversionBridgeStage -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch "x64" -ExpectedConfiguration "Release"
  } "Serf DLL runtime artifacts" "M6s Subversion bridge stage check should reject stale Serf DLL runtimes."
  Remove-Item -LiteralPath (Join-Path $subversionBridgeStage "bin\libserf-1.dll") -Force

  $stageManifestPath = Join-Path $subversionBridgeStage "subversionr-stage-manifest.json"
  $stageManifest = Get-Content -Raw -LiteralPath $stageManifestPath | ConvertFrom-Json
  Assert-Equal "subversionr.native.subversion-stage.v1" $stageManifest.schema "Subversion bridge stage manifest should record the schema."
  Assert-Equal "apache-subversion" $stageManifest.source.name "Subversion bridge stage manifest should record the source name."
  Assert-Equal "1.14.5" $stageManifest.source.version "Subversion bridge stage manifest should record the locked Subversion version."
  Assert-Equal "x64" $stageManifest.arch "Subversion bridge stage manifest should record the architecture."
  $manifestDependencyNames = @($stageManifest.dependencies | ForEach-Object { $_.name })
  Assert-True ($manifestDependencyNames -contains "openssl") "M6s Subversion bridge stage manifest should record OpenSSL."
  Assert-True ($manifestDependencyNames -contains "serf") "M6s Subversion bridge stage manifest should record Serf."

  $subversionDavModuleSourceRoot = Join-Path $tempRoot "subversion-dav-module-source"
  foreach ($moduleName in @("mod_dav_svn", "mod_authz_svn")) {
    $moduleOutputRoot = Join-Path $subversionDavModuleSourceRoot "Release\subversion\$moduleName"
    New-Item -ItemType Directory -Force -Path $moduleOutputRoot | Out-Null
    "binary-$moduleName" | Set-Content -LiteralPath (Join-Path $moduleOutputRoot "$moduleName.so") -Encoding ascii -NoNewline
    "symbols-$moduleName" | Set-Content -LiteralPath (Join-Path $moduleOutputRoot "$moduleName.pdb") -Encoding ascii -NoNewline
  }
  $subversionDavStage = Join-Path $tempRoot "httpd-subversion-dav-stage"
  $copiedDavStage = Copy-ApacheHttpdSubversionDavStage `
    -HttpdStageRoot $httpdStage `
    -DependencyStageRoot $subversionDependencyStage `
    -SubversionStageRoot $subversionBridgeStage `
    -SourceRoot $subversionDavModuleSourceRoot `
    -StageRoot $subversionDavStage `
    -WorkspaceRoot $repoRoot `
    -SourceLockPath $lockPath `
    -Arch "x64" `
    -Configuration "Release"
  Assert-Equal (Resolve-Path $subversionDavStage).Path $copiedDavStage "M6y composite DAV stage should return the staged root."
  Assert-Equal (Resolve-Path $subversionDavStage).Path (Assert-ApacheHttpdSubversionDavStage -StageRoot $subversionDavStage -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch "x64" -ExpectedConfiguration "Release") "M6y composite DAV stage assertion should accept the copied runtime."
  Assert-True (Test-Path -LiteralPath (Join-Path $subversionDavStage "bin\httpd.exe") -PathType Leaf) "M6y composite DAV stage should include the source-built httpd runtime."
  Assert-True (Test-Path -LiteralPath (Join-Path $subversionDavStage "modules\mod_dav_svn.so") -PathType Leaf) "M6y composite DAV stage should include mod_dav_svn."
  Assert-True (Test-Path -LiteralPath (Join-Path $subversionDavStage "modules\mod_authz_svn.so") -PathType Leaf) "M6y composite DAV stage should include mod_authz_svn."
  foreach ($runtimeName in Get-SubversionDavModuleRuntimeFiles) {
    Assert-True (Test-Path -LiteralPath (Join-Path $subversionDavStage "bin\$runtimeName") -PathType Leaf) "M6y composite DAV stage should include the Subversion DAV runtime DLL: $runtimeName"
  }
  foreach ($forbiddenTool in @("svn.exe", "svnadmin.exe", "svnserve.exe")) {
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $subversionDavStage "bin\$forbiddenTool") -PathType Leaf)) "M6y composite DAV stage should not copy fixture CLI tool $forbiddenTool."
  }
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $httpdStage "modules\mod_dav_svn.so") -PathType Leaf)) "M6y composite copy should not mutate the clean httpd substrate."
  $subversionDavManifestPath = Join-Path $subversionDavStage "subversionr-httpd-subversion-dav-stage-manifest.json"
  $subversionDavManifest = Get-Content -Raw -LiteralPath $subversionDavManifestPath | ConvertFrom-Json
  Assert-Equal "subversionr.native.httpd-subversion-dav-stage.v1" $subversionDavManifest.schema "M6y composite DAV stage manifest should record the schema."
  Assert-Equal "apache-httpd-subversion-dav-module-runtime" $subversionDavManifest.kind "M6y composite DAV stage manifest should record the runtime kind."
  $subversionDavManifestSources = @($subversionDavManifest.sources | ForEach-Object { $_.name })
  Assert-True ($subversionDavManifestSources -contains "apache-httpd") "M6y composite DAV stage manifest should record the httpd source."
  Assert-True ($subversionDavManifestSources -contains "apache-subversion") "M6y composite DAV stage manifest should record the Subversion source."
  $subversionDavManifestDependencies = @($subversionDavManifest.dependencies | ForEach-Object { $_.name })
  Assert-True ($subversionDavManifestDependencies -contains "pcre2") "M6y composite DAV stage manifest should include the httpd PCRE2 dependency."
  Assert-True ($subversionDavManifestDependencies -contains "sqlite-amalgamation") "M6y composite DAV stage manifest should include the Subversion SQLite dependency."

  Assert-ThrowsContaining {
    Copy-ApacheHttpdSubversionDavStage `
      -HttpdStageRoot $httpdStage `
      -DependencyStageRoot $subversionDependencyStage `
      -SubversionStageRoot $subversionBridgeStage `
      -SourceRoot $subversionDavModuleSourceRoot `
      -StageRoot $httpdStage `
      -WorkspaceRoot $repoRoot `
      -SourceLockPath $lockPath `
      -Arch "x64" `
      -Configuration "Release"
  } "StageRoot must be independent from HttpdStageRoot" "M6y composite stage copy should reject destructive overlap with the clean httpd substrate before clearing."

  $wrongModulePath = Join-Path $subversionDavStage "modules\wrong-mod_dav_svn.so"
  Copy-Item -LiteralPath (Join-Path $subversionDavStage "modules\mod_dav_svn.so") -Destination $wrongModulePath -Force
  $wrongModuleManifest = Get-Content -Raw -LiteralPath $subversionDavManifestPath | ConvertFrom-Json
  $wrongModuleManifest.modules[0].module.path = "modules/wrong-mod_dav_svn.so"
  $wrongModuleManifest.modules[0].module.sha256 = (Get-FileHash -LiteralPath $wrongModulePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $wrongModuleManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $subversionDavManifestPath -Encoding ascii
  Assert-ThrowsContaining {
    Assert-ApacheHttpdSubversionDavStage -StageRoot $subversionDavStage -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch "x64" -ExpectedConfiguration "Release"
  } "modules/mod_dav_svn.so" "M6y composite DAV stage assertion should require exact manifest paths for module artifacts."
  New-ApacheHttpdSubversionDavStageManifest -StageRoot $subversionDavStage -SourceLockPath $lockPath -Arch "x64" -Configuration "Release" | Out-Null

  Remove-Item -LiteralPath (Join-Path $subversionDavStage "bin\libsvn_fs_x-1.dll") -Force
  Assert-ThrowsContaining {
    Assert-ApacheHttpdSubversionDavStage -StageRoot $subversionDavStage -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch "x64" -ExpectedConfiguration "Release"
  } "libsvn_fs_x-1.dll" "M6y composite DAV stage assertion should require delayed FS backend runtime DLLs."
  "restored-libsvn_fs_x" | Set-Content -LiteralPath (Join-Path $subversionDavStage "bin\libsvn_fs_x-1.dll") -Encoding ascii -NoNewline
  New-ApacheHttpdSubversionDavStageManifest -StageRoot $subversionDavStage -SourceLockPath $lockPath -Arch "x64" -Configuration "Release" | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $subversionDavStage "modules\mod_dontdothat.so") | Out-Null
  Assert-ThrowsContaining {
    Assert-ApacheHttpdSubversionDavStage -StageRoot $subversionDavStage -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch "x64" -ExpectedConfiguration "Release"
  } "mod_dontdothat.so" "M6y composite DAV stage assertion should reject the generated mod_dontdothat module for this gate."
  Remove-Item -LiteralPath (Join-Path $subversionDavStage "modules\mod_dontdothat.so") -Force

  $serfHeaderPath = Join-Path $subversionBridgeStage "include\serf-1\serf.h"
  $serfHeaderContent = Get-Content -Raw -LiteralPath $serfHeaderPath
  @'
#define SERF_MAJOR_VERSION 1
#define SERF_MINOR_VERSION 3
#define SERF_PATCH_VERSION 9
'@ | Set-Content -LiteralPath $serfHeaderPath -Encoding ascii -NoNewline
  Assert-ThrowsContaining {
    Assert-SubversionStageForBridge -StageRoot $subversionBridgeStage -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch "x64" -ExpectedConfiguration "Release"
  } "Serf version" "Subversion bridge stage check should reject Serf headers that do not match the source lock."
  $serfHeaderContent | Set-Content -LiteralPath $serfHeaderPath -Encoding ascii -NoNewline

  $openSslHeaderPath = Join-Path $subversionBridgeStage "include\openssl\opensslv.h"
  $openSslHeaderContent = Get-Content -Raw -LiteralPath $openSslHeaderPath
  '# define OPENSSL_VERSION_TEXT "OpenSSL 3.5.6 1 Jul 2026"' | Set-Content -LiteralPath $openSslHeaderPath -Encoding ascii -NoNewline
  Assert-ThrowsContaining {
    Assert-SubversionStageForBridge -StageRoot $subversionBridgeStage -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch "x64" -ExpectedConfiguration "Release"
  } "OpenSSL version" "Subversion bridge stage check should reject OpenSSL headers that do not match the source lock."
  $openSslHeaderContent | Set-Content -LiteralPath $openSslHeaderPath -Encoding ascii -NoNewline

  $wrongVersionManifest = Get-Content -Raw -LiteralPath $stageManifestPath | ConvertFrom-Json
  $wrongVersionManifest.source.version = "1.14.4"
  $wrongVersionManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stageManifestPath -Encoding ascii
  Assert-ThrowsContaining {
    Assert-SubversionStageForBridge -StageRoot $subversionBridgeStage -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch "x64" -ExpectedConfiguration "Release"
  } "1.14.5" "Subversion bridge stage check should reject manifests with the wrong Subversion version."
  $stageManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stageManifestPath -Encoding ascii

  $wrongUrlManifest = Get-Content -Raw -LiteralPath $stageManifestPath | ConvertFrom-Json
  $wrongUrlManifest.source.url = "https://example.invalid/subversion.zip"
  $wrongUrlManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stageManifestPath -Encoding ascii
  Assert-ThrowsContaining {
    Assert-SubversionStageForBridge -StageRoot $subversionBridgeStage -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch "x64" -ExpectedConfiguration "Release"
  } "source url" "Subversion bridge stage check should reject manifests with the wrong source URL."
  $stageManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stageManifestPath -Encoding ascii

  $duplicateDependencyManifest = Get-Content -Raw -LiteralPath $stageManifestPath | ConvertFrom-Json
  $duplicateDependencyManifest.dependencies = @($duplicateDependencyManifest.dependencies) + @($duplicateDependencyManifest.dependencies[0])
  $duplicateDependencyManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stageManifestPath -Encoding ascii
  Assert-ThrowsContaining {
    Assert-SubversionStageForBridge -StageRoot $subversionBridgeStage -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch "x64" -ExpectedConfiguration "Release"
  } "dependency count" "Subversion bridge stage check should reject duplicate manifest dependencies."
  $stageManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stageManifestPath -Encoding ascii

  $extraDependencyManifest = Get-Content -Raw -LiteralPath $stageManifestPath | ConvertFrom-Json
  $extraDependencyManifest.dependencies = @($extraDependencyManifest.dependencies) + @([pscustomobject]@{
    name = "unexpected"
    version = "0.0.0"
    url = "https://example.invalid/unexpected.zip"
    sha512 = "unexpected"
  })
  $extraDependencyManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stageManifestPath -Encoding ascii
  Assert-ThrowsContaining {
    Assert-SubversionStageForBridge -StageRoot $subversionBridgeStage -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch "x64" -ExpectedConfiguration "Release"
  } "dependency count" "Subversion bridge stage check should reject extra manifest dependencies."
  $stageManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stageManifestPath -Encoding ascii

  $wrongDependencyUrlManifest = Get-Content -Raw -LiteralPath $stageManifestPath | ConvertFrom-Json
  $wrongDependencyUrlManifest.dependencies[0].url = "https://example.invalid/apr.zip"
  $wrongDependencyUrlManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stageManifestPath -Encoding ascii
  Assert-ThrowsContaining {
    Assert-SubversionStageForBridge -StageRoot $subversionBridgeStage -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch "x64" -ExpectedConfiguration "Release"
  } "dependency url mismatch" "Subversion bridge stage check should reject manifests with the wrong dependency URL."
  $stageManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stageManifestPath -Encoding ascii

  Remove-Item -LiteralPath (Join-Path $subversionBridgeStage "include\apr_pools.h") -Force
  Assert-ThrowsContaining {
    Assert-SubversionStageForBridge -StageRoot $subversionBridgeStage -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch "x64" -ExpectedConfiguration "Release"
  } "apr_pools.h" "Subversion bridge stage check should require APR headers used by CMake."
  New-Item -ItemType File -Force -Path (Join-Path $subversionBridgeStage "include\apr_pools.h") | Out-Null

  Remove-Item -LiteralPath (Join-Path $subversionBridgeStage "bin\svnserve.exe") -Force
  Assert-ThrowsContaining {
    Assert-SubversionStageForBridge -StageRoot $subversionBridgeStage -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch "x64" -ExpectedConfiguration "Release"
  } "svnserve.exe" "Subversion bridge stage check should require the source-built svnserve fixture server."
  New-Item -ItemType File -Force -Path (Join-Path $subversionBridgeStage "bin\svnserve.exe") | Out-Null

  Remove-Item -LiteralPath (Join-Path $subversionBridgeStage "lib\libsvn_ra_serf-1.lib") -Force
  Assert-ThrowsContaining {
    Assert-SubversionStageForBridge -StageRoot $subversionBridgeStage -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch "x64" -ExpectedConfiguration "Release"
  } "libsvn_ra_serf-1.lib" "M6s Subversion bridge stage check should require the source-built ra_serf static library."
  New-Item -ItemType File -Force -Path (Join-Path $subversionBridgeStage "lib\libsvn_ra_serf-1.lib") | Out-Null

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $buildBridgeScript -SvnRoot $subversionBridgeStage
  } "VsDevCmd is required" "Bridge build entrypoint should require an explicit Visual Studio developer command."
  $fakeBridgeOutput = Join-Path $tempRoot "fake-bridge-output"
  New-Item -ItemType Directory -Force -Path $fakeBridgeOutput | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $fakeBridgeOutput "subversionr_svn_bridge.dll") | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $fakeBridgeOutput "subversionr_svn_bridge.lib") | Out-Null
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $smokeBridgeScript -BridgeOutputDirectory $fakeBridgeOutput -ExpectedVersion "1.14.5"
  } "VsDevCmd is required" "Bridge smoke entrypoint should require an explicit Visual Studio developer command."

  $bridgeRuntimeOutput = Join-Path $tempRoot "bridge-runtime-output"
  New-Item -ItemType Directory -Force -Path $bridgeRuntimeOutput | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $bridgeRuntimeOutput "subversionr_svn_bridge.dll") | Out-Null
  $copiedBridgeRuntime = Copy-BridgeRuntimeDependencies `
    -SubversionStageRoot $subversionBridgeStage `
    -OutputDirectory $bridgeRuntimeOutput `
    -WorkspaceRoot $repoRoot `
    -SourceLockPath $lockPath `
    -ExpectedArch "x64" `
    -ExpectedConfiguration "Release"
  Assert-Equal (Resolve-Path $bridgeRuntimeOutput).Path $copiedBridgeRuntime "Bridge runtime copy should return the output directory."
  Assert-True (Test-Path -LiteralPath (Join-Path $bridgeRuntimeOutput "libsvn_client-1.dll") -PathType Leaf) "Bridge runtime output should contain libsvn client runtime."
  Assert-True (Test-Path -LiteralPath (Join-Path $bridgeRuntimeOutput "libaprutil-1.dll") -PathType Leaf) "Bridge runtime output should contain APR-util runtime."
  Assert-True (Test-Path -LiteralPath (Join-Path $bridgeRuntimeOutput "libcrypto-3-x64.dll") -PathType Leaf) "Bridge runtime output should contain OpenSSL crypto runtime."
  Assert-True (Test-Path -LiteralPath (Join-Path $bridgeRuntimeOutput "libssl-3-x64.dll") -PathType Leaf) "Bridge runtime output should contain OpenSSL TLS runtime."
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $bridgeRuntimeOutput "libserf-1.dll") -PathType Leaf)) "Bridge runtime output should not contain the unused Serf DLL."
  Assert-True (Test-Path -LiteralPath (Join-Path $bridgeRuntimeOutput "subversionr_svn_bridge.dll") -PathType Leaf) "Bridge runtime copy should not remove existing bridge outputs."

  $outsideBridgeRuntimeOutput = Join-Path ([IO.Path]::GetTempPath()) "subversionr-bridge-output-$([Guid]::NewGuid().ToString('N'))"
  Assert-ThrowsContaining {
    Copy-BridgeRuntimeDependencies `
      -SubversionStageRoot $subversionBridgeStage `
      -OutputDirectory $outsideBridgeRuntimeOutput `
      -WorkspaceRoot $repoRoot `
      -SourceLockPath $lockPath `
      -ExpectedArch "x64" `
      -ExpectedConfiguration "Release"
  } "outside repository generated roots" "Bridge runtime copy should reject output directories outside repository generated roots."

  Remove-Item -LiteralPath (Join-Path $subversionBridgeStage "bin\libsvn_client-1.dll") -Force
  Assert-ThrowsContaining {
    Copy-BridgeRuntimeDependencies `
      -SubversionStageRoot $subversionBridgeStage `
      -OutputDirectory $bridgeRuntimeOutput `
      -WorkspaceRoot $repoRoot `
      -SourceLockPath $lockPath `
      -ExpectedArch "x64" `
      -ExpectedConfiguration "Release"
  } "libsvn_client-1.dll" "Bridge runtime copy should validate the staged runtime before copying."
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $buildBridgeScript `
      -SvnRoot $subversionBridgeStage `
      -VsDevCmd (Join-Path $tempRoot "missing-vs-dev-cmd.bat")
  } "Subversion bridge stage is missing required file" "Bridge build entrypoint should reject incomplete Subversion stages before toolchain setup."
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $smokeBridgeScript `
      -BridgeOutputDirectory (Join-Path $tempRoot "missing-bridge-output") `
      -ExpectedVersion "1.14.5" `
      -VsDevCmd (Join-Path $tempRoot "missing-vs-dev-cmd.bat")
  } "Bridge output directory is missing" "Bridge smoke entrypoint should reject missing bridge outputs before toolchain setup."
  New-Item -ItemType File -Force -Path (Join-Path $subversionBridgeStage "bin\libsvn_client-1.dll") | Out-Null

  Remove-Item -LiteralPath (Join-Path $subversionBridgeStage "lib\libsvn_ra-1.lib") -Force
  Assert-ThrowsContaining {
    Assert-SubversionStageForBridge -StageRoot $subversionBridgeStage -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch "x64" -ExpectedConfiguration "Release"
  } "libsvn_ra-1.lib" "Subversion bridge stage check should report missing RA import library."
  New-Item -ItemType File -Force -Path (Join-Path $subversionBridgeStage "lib\libsvn_ra-1.lib") | Out-Null

  Remove-Item -LiteralPath (Join-Path $subversionBridgeStage "lib\libsvn_wc-1.lib") -Force
  Assert-ThrowsContaining {
    Assert-SubversionStageForBridge -StageRoot $subversionBridgeStage -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch "x64" -ExpectedConfiguration "Release"
  } "libsvn_wc-1.lib" "Subversion bridge stage check should report missing libsvn imports."

  $sqliteRoot = Join-Path $tempRoot "work\sqlite-amalgamation-3530200"
  New-Item -ItemType Directory -Force -Path $sqliteRoot | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $sqliteRoot "sqlite3.c") | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $sqliteRoot "sqlite3.h") | Out-Null

  $resolvedSqliteRoot = Resolve-SqliteAmalgamationRoot -SearchRoot (Join-Path $tempRoot "work")
  Assert-Equal (Resolve-Path $sqliteRoot).Path $resolvedSqliteRoot "SQLite amalgamation root should contain sqlite3.c and sqlite3.h."

  $subversionSourceRoot = Join-Path $tempRoot "subversion"
  $generatorDirectory = Join-Path $subversionSourceRoot "build\generator"
  New-Item -ItemType Directory -Force -Path $generatorDirectory | Out-Null
  $generatorPath = Join-Path $generatorDirectory "gen_win_dependencies.py"
  @'
vermatch = re.search(r'^\s*#define\s+XML_MAJOR_VERSION\s+(\d+)', txt, re.M)
vermatch = re.search(r'^\s*#define\s+XML_MINOR_VERSION\s+(\d+)', txt, re.M)
vermatch = re.search(r'^\s*#define\s+XML_MICRO_VERSION\s+(\d+)', txt, re.M)
'@ | Set-Content -LiteralPath $generatorPath -NoNewline

  Update-SubversionGeneratorForExpat272 -SourceRoot $subversionSourceRoot
  $patchedGenerator = Get-Content -Raw -LiteralPath $generatorPath
  Assert-True ($patchedGenerator.Contains("#\s*define\s+XML_MAJOR_VERSION")) "Subversion generator patch should allow whitespace between # and define."
  Update-SubversionGeneratorForExpat272 -SourceRoot $subversionSourceRoot

  $vcxprojDirectory = Join-Path $subversionSourceRoot "build\win32\vcnet-vcproj"
  New-Item -ItemType Directory -Force -Path $vcxprojDirectory | Out-Null
  $vcxprojPath = Join-Path $vcxprojDirectory "libsvn_subr.vcxproj"
  @'
<Project>
  <ImportGroup Label="PropertySheets" />
  <PropertyGroup Label="Configuration">
    <PlatformToolset>v142</PlatformToolset>
  </PropertyGroup>
</Project>
'@ | Set-Content -LiteralPath $vcxprojPath -NoNewline

  $retargetedProjects = @(Update-GeneratedVcxprojPlatformToolset -SourceRoot $subversionSourceRoot -FromToolset "v142" -ToToolset "v143")
  Assert-Equal 1 $retargetedProjects.Count "Platform toolset retarget should report the changed project."
  $retargetedProject = Get-Content -Raw -LiteralPath $vcxprojPath
  Assert-True ($retargetedProject.Contains("<PlatformToolset>v143</PlatformToolset>")) "Platform toolset retarget should update generated vcxproj files."
  Update-GeneratedVcxprojPlatformToolset -SourceRoot $subversionSourceRoot -FromToolset "v142" -ToToolset "v143" | Out-Null

  $solutionPath = Join-Path $subversionSourceRoot "subversion_vcnet.sln"
  @'
Microsoft Visual Studio Solution File, Format Version 12.00
Project("{00000000-0000-0000-0000-000000000000}") = "libsvn_subr", "build\win32\vcnet-vcproj\libsvn_subr.vcxproj", "{11111111-1111-1111-1111-111111111111}"
EndProject
'@ | Set-Content -LiteralPath $solutionPath -NoNewline

  $validatedProjects = @(Assert-GeneratedVcxprojPlatformToolset -SourceRoot $subversionSourceRoot -ExpectedToolset "v143")
  Assert-Equal 1 $validatedProjects.Count "Platform toolset validation should return validated project files."

  @'
<Project>
  <PropertyGroup Label="Configuration">
    <ConfigurationType>StaticLibrary</ConfigurationType>
    <PlatformToolset>v143</PlatformToolset>
  </PropertyGroup>
  <PropertyGroup>
    <TargetName>libsvn_ra_serf-1</TargetName>
  </PropertyGroup>
  <ItemDefinitionGroup>
    <ClCompile>
      <PreprocessorDefinitions>SVN_HAVE_SERF;SVN_LIBSVN_RA_LINKS_RA_SERF;%(PreprocessorDefinitions)</PreprocessorDefinitions>
    </ClCompile>
  </ItemDefinitionGroup>
</Project>
'@ | Set-Content -LiteralPath (Join-Path $vcxprojDirectory "libsvn_ra_serf.vcxproj") -NoNewline
  @'
<Project>
  <PropertyGroup Label="Configuration">
    <ConfigurationType>DynamicLibrary</ConfigurationType>
    <PlatformToolset>v143</PlatformToolset>
  </PropertyGroup>
  <PropertyGroup>
    <TargetName>libsvn_ra-1</TargetName>
  </PropertyGroup>
  <ItemDefinitionGroup>
    <ClCompile>
      <PreprocessorDefinitions>SVN_HAVE_SERF;SVN_LIBSVN_RA_LINKS_RA_SERF;%(PreprocessorDefinitions)</PreprocessorDefinitions>
    </ClCompile>
    <Link>
      <AdditionalDependencies>serf-1.lib;libssl.lib;libcrypto.lib;%(AdditionalDependencies)</AdditionalDependencies>
    </Link>
  </ItemDefinitionGroup>
  <ItemGroup>
    <ProjectReference Include="libsvn_ra_serf.vcxproj" />
  </ItemGroup>
</Project>
'@ | Set-Content -LiteralPath (Join-Path $vcxprojDirectory "libsvn_ra_dll.vcxproj") -NoNewline
  Assert-GeneratedSubversionRaSerfProjectGraph -SourceRoot $subversionSourceRoot

  $raDllProjectPath = Join-Path $vcxprojDirectory "libsvn_ra_dll.vcxproj"
  $raDllProjectContent = Get-Content -Raw -LiteralPath $raDllProjectPath
  $raDllProjectContent.Replace("serf-1.lib;", "") | Set-Content -LiteralPath $raDllProjectPath -NoNewline
  Assert-ThrowsContaining {
    Assert-GeneratedSubversionRaSerfProjectGraph -SourceRoot $subversionSourceRoot
  } "serf-1.lib" "ra_serf project graph validation should reject missing Serf link input."
  $raDllProjectContent | Set-Content -LiteralPath $raDllProjectPath -NoNewline

  @'
<Project>
  <PropertyGroup Label="Configuration">
    <ConfigurationType>DynamicLibrary</ConfigurationType>
    <PlatformToolset>v143</PlatformToolset>
  </PropertyGroup>
  <PropertyGroup>
    <TargetName>mod_dav_svn</TargetName>
    <TargetExt>.so</TargetExt>
  </PropertyGroup>
  <ItemDefinitionGroup>
    <ClCompile>
      <PreprocessorDefinitions>AP_DECLARE_EXPORT;SVN_USE_DSO;%(PreprocessorDefinitions)</PreprocessorDefinitions>
    </ClCompile>
    <Link>
      <AdditionalDependencies>libhttpd.lib;mod_dav.lib;%(AdditionalDependencies)</AdditionalDependencies>
    </Link>
  </ItemDefinitionGroup>
  <ItemGroup>
    <ProjectReference Include="libsvn_delta_dll.vcxproj" />
    <ProjectReference Include="libsvn_fs_dll.vcxproj" />
    <ProjectReference Include="libsvn_repos_dll.vcxproj" />
    <ProjectReference Include="libsvn_subr_dll.vcxproj" />
  </ItemGroup>
</Project>
'@ | Set-Content -LiteralPath (Join-Path $vcxprojDirectory "mod_dav_svn.vcxproj") -NoNewline
  @'
<Project>
  <PropertyGroup Label="Configuration">
    <ConfigurationType>DynamicLibrary</ConfigurationType>
    <PlatformToolset>v143</PlatformToolset>
  </PropertyGroup>
  <PropertyGroup>
    <TargetName>mod_authz_svn</TargetName>
    <TargetExt>.so</TargetExt>
  </PropertyGroup>
  <ItemDefinitionGroup>
    <ClCompile>
      <PreprocessorDefinitions>AP_DECLARE_EXPORT;SVN_USE_DSO;%(PreprocessorDefinitions)</PreprocessorDefinitions>
    </ClCompile>
    <Link>
      <AdditionalDependencies>libhttpd.lib;%(AdditionalDependencies)</AdditionalDependencies>
    </Link>
  </ItemDefinitionGroup>
  <ItemGroup>
    <ProjectReference Include="mod_dav_svn.vcxproj" />
    <ProjectReference Include="libsvn_repos_dll.vcxproj" />
    <ProjectReference Include="libsvn_subr_dll.vcxproj" />
  </ItemGroup>
</Project>
'@ | Set-Content -LiteralPath (Join-Path $vcxprojDirectory "mod_authz_svn.vcxproj") -NoNewline
  Assert-GeneratedSubversionApacheModuleProjectGraph -SourceRoot $subversionSourceRoot

  $modDavProjectPath = Join-Path $vcxprojDirectory "mod_dav_svn.vcxproj"
  $modDavProjectContent = Get-Content -Raw -LiteralPath $modDavProjectPath
  $modDavProjectContent.Replace("mod_dav.lib;", "") | Set-Content -LiteralPath $modDavProjectPath -NoNewline
  Assert-ThrowsContaining {
    Assert-GeneratedSubversionApacheModuleProjectGraph -SourceRoot $subversionSourceRoot
  } "mod_dav.lib" "Apache module project graph validation should reject a mod_dav_svn project that is not linked to mod_dav."
  $modDavProjectContent | Set-Content -LiteralPath $modDavProjectPath -NoNewline

  $modAuthzProjectPath = Join-Path $vcxprojDirectory "mod_authz_svn.vcxproj"
  $modAuthzProjectContent = Get-Content -Raw -LiteralPath $modAuthzProjectPath
  $modAuthzProjectContent.Replace('<ProjectReference Include="mod_dav_svn.vcxproj" />', "") | Set-Content -LiteralPath $modAuthzProjectPath -NoNewline
  Assert-ThrowsContaining {
    Assert-GeneratedSubversionApacheModuleProjectGraph -SourceRoot $subversionSourceRoot
  } "mod_dav_svn.vcxproj" "Apache module project graph validation should require mod_authz_svn to reference mod_dav_svn."
  $modAuthzProjectContent | Set-Content -LiteralPath $modAuthzProjectPath -NoNewline

  $mixedToolsetPath = Join-Path $vcxprojDirectory "mixed.vcxproj"
  @'
<Project>
  <PropertyGroup Label="Configuration">
    <PlatformToolset>v110</PlatformToolset>
  </PropertyGroup>
</Project>
'@ | Set-Content -LiteralPath $mixedToolsetPath -NoNewline
  Assert-ThrowsContaining {
    Assert-GeneratedVcxprojPlatformToolset -SourceRoot $subversionSourceRoot -ExpectedToolset "v143"
  } "mixed.vcxproj" "Platform toolset validation should reject mixed generated project toolsets."
  Remove-Item -LiteralPath $mixedToolsetPath -Force

  $missingToolsetPath = Join-Path $vcxprojDirectory "missing-toolset.vcxproj"
  "<Project />" | Set-Content -LiteralPath $missingToolsetPath -NoNewline
  Assert-ThrowsContaining {
    Assert-GeneratedVcxprojPlatformToolset -SourceRoot $subversionSourceRoot -ExpectedToolset "v143"
  } "missing-toolset.vcxproj" "Platform toolset validation should reject projects without PlatformToolset."
  Remove-Item -LiteralPath $missingToolsetPath -Force

  @'
Microsoft Visual Studio Solution File, Format Version 12.00
Project("{00000000-0000-0000-0000-000000000000}") = "missing", "build\win32\vcnet-vcproj\missing.vcxproj", "{11111111-1111-1111-1111-111111111111}"
EndProject
'@ | Set-Content -LiteralPath $solutionPath -NoNewline
  Assert-ThrowsContaining {
    Assert-GeneratedVcxprojPlatformToolset -SourceRoot $subversionSourceRoot -ExpectedToolset "v143"
  } "missing.vcxproj" "Platform toolset validation should reject missing solution project references."

  $missingVcxprojRoot = Join-Path $tempRoot "subversion-no-vcxproj"
  New-Item -ItemType Directory -Force -Path $missingVcxprojRoot | Out-Null
  Assert-ThrowsContaining {
    Update-GeneratedVcxprojPlatformToolset -SourceRoot $missingVcxprojRoot -FromToolset "v142" -ToToolset "v143"
  } "vcxproj" "Platform toolset retarget should fail when generated vcxproj files are missing."

  Assert-True (Test-Path -LiteralPath $buildDependenciesScript -PathType Leaf) "build-dependencies.ps1 should exist."
  $buildResult = & pwsh -NoProfile -ExecutionPolicy Bypass -File $buildDependenciesScript `
    -Only sqlite-amalgamation `
    -CacheRoot (Join-Path $tempRoot "missing-sources") `
    -WorkRoot (Join-Path $tempRoot "build-work") `
    -StageRoot (Join-Path $tempRoot "deps-stage") `
    -SkipVerifySources 2>&1
  Assert-True ($LASTEXITCODE -ne 0) "build-dependencies.ps1 should fail when the locked SQLite archive is missing."

  $missingArchiveError = $null
  try {
    Get-NativeArchivePath -CacheRoot (Join-Path $tempRoot "missing-sources") -Source $source -RequireExisting | Out-Null
  }
  catch {
    $missingArchiveError = $_.Exception.Message
  }
  Assert-True ($missingArchiveError.Contains("sqlite-amalgamation-3530200.zip")) "Missing SQLite archive error should name the required archive."

  Write-Host "Native script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
  $fixtureRootFull = [IO.Path]::GetFullPath($worktreeFixtureRoot)
  $systemTempFull = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($fixtureRootFull.StartsWith($systemTempFull, [StringComparison]::OrdinalIgnoreCase)) {
    Remove-Item -LiteralPath $worktreeFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

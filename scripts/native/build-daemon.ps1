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

function Get-NormalizedFullPath([string]$Path) {
  return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Test-SamePath([string]$Left, [string]$Right) {
  return [StringComparer]::OrdinalIgnoreCase.Equals(
    (Get-NormalizedFullPath $Left),
    (Get-NormalizedFullPath $Right)
  )
}

function Resolve-RequiredApplication([string]$Name) {
  $applications = @(Get-Command $Name -CommandType Application -ErrorAction Stop)
  if ($applications.Count -eq 0) {
    throw "Required application is unavailable: $Name"
  }
  return $applications[0]
}

function Invoke-RepositoryGit(
  [string]$GitPath,
  [string]$WorkingDirectory,
  [string[]]$Arguments,
  [string]$Description
) {
  Push-Location $WorkingDirectory
  try {
    $output = @(& $GitPath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  }
  finally {
    Pop-Location
  }

  if ($exitCode -ne 0) {
    throw "$Description failed with exit code $exitCode`: $($output -join ' ')"
  }
  return @($output | ForEach-Object { [string]$_ })
}

function Get-SingleGitPath(
  [string]$GitPath,
  [string]$WorkingDirectory,
  [string[]]$Arguments,
  [string]$Description
) {
  $output = @(Invoke-RepositoryGit -GitPath $GitPath -WorkingDirectory $WorkingDirectory -Arguments $Arguments -Description $Description)
  if ($output.Count -ne 1 -or [string]::IsNullOrWhiteSpace($output[0])) {
    throw "$Description must return exactly one path."
  }
  return Get-NormalizedFullPath $output[0]
}

function Assert-TrackedCleanCargoConfig(
  [string]$GitPath,
  [string]$WorkingDirectory,
  [string]$Description
) {
  $stage = @(Invoke-RepositoryGit `
    -GitPath $GitPath `
    -WorkingDirectory $WorkingDirectory `
    -Arguments @("ls-files", "--stage", "--", ".cargo/config.toml") `
    -Description "$Description tracking check")
  if ($stage.Count -ne 1 -or $stage[0] -notmatch '^100644 ([0-9a-f]+) 0\t\.cargo/config\.toml$') {
    throw "$Description must be one tracked regular 100644 file at .cargo/config.toml."
  }
  $blobOid = $Matches[1]
  $head = @(Invoke-RepositoryGit `
    -GitPath $GitPath `
    -WorkingDirectory $WorkingDirectory `
    -Arguments @("ls-tree", "HEAD", "--", ".cargo/config.toml") `
    -Description "$Description HEAD check")
  if ($head.Count -ne 1 -or $head[0] -notmatch '^100644 blob ([0-9a-f]+)\t\.cargo/config\.toml$' -or $Matches[1] -cne $blobOid) {
    throw "$Description must match its Git index and HEAD without staged or unstaged changes."
  }
  $status = @(Invoke-RepositoryGit `
    -GitPath $GitPath `
    -WorkingDirectory $WorkingDirectory `
    -Arguments @("status", "--porcelain=v1", "--untracked-files=all", "--", ".cargo/config.toml") `
    -Description "$Description clean-state check")
  if ($status.Count -ne 0) {
    throw "$Description must match its Git index and HEAD without staged or unstaged changes."
  }
  $worktreeBlob = @(Invoke-RepositoryGit `
    -GitPath $GitPath `
    -WorkingDirectory $WorkingDirectory `
    -Arguments @("hash-object", "--no-filters", "--", ".cargo/config.toml") `
    -Description "$Description working-tree byte check")
  if ($worktreeBlob.Count -ne 1 -or $worktreeBlob[0] -cne $blobOid) {
    throw "$Description must match its tracked Git blob byte-for-byte."
  }
  return $blobOid
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
  "RUSTUP_TOOLCHAIN",
  "CARGO_HOME"
)
foreach ($variableName in $repositoryOwnedEnvironment) {
  if (Test-Path -LiteralPath "Env:$variableName") {
    throw "$variableName must be unset; the release daemon configuration, toolchain, and output policy are repository-owned."
  }
}

$repositoryLocalGitEnvironment = @(
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
foreach ($variableName in $repositoryLocalGitEnvironment) {
  if (Test-Path -LiteralPath "Env:$variableName") {
    throw "$variableName must be unset; Git must derive the release daemon worktree from the repository itself."
  }
}

$git = Resolve-RequiredApplication "git"
$currentTopLevel = Get-SingleGitPath `
  -GitPath $git.Source `
  -WorkingDirectory $repoRoot `
  -Arguments @("rev-parse", "--path-format=absolute", "--show-toplevel") `
  -Description "Current Git worktree root discovery"
if (-not (Test-SamePath $currentTopLevel $repoRoot)) {
  throw "The release daemon script must reside at the current Git worktree root: $repoRoot"
}
$gitDirectory = Get-SingleGitPath `
  -GitPath $git.Source `
  -WorkingDirectory $repoRoot `
  -Arguments @("rev-parse", "--path-format=absolute", "--git-dir") `
  -Description "Current Git directory discovery"
$commonGitDirectory = Get-SingleGitPath `
  -GitPath $git.Source `
  -WorkingDirectory $repoRoot `
  -Arguments @("rev-parse", "--path-format=absolute", "--git-common-dir") `
  -Description "Common Git directory discovery"
if (
  (Split-Path -Leaf $commonGitDirectory) -cne ".git" -or
  -not (Test-Path -LiteralPath $commonGitDirectory -PathType Container)
) {
  throw "The release daemon build requires a non-bare repository with a primary .git directory."
}

$primaryRoot = Get-NormalizedFullPath (Split-Path -Parent $commonGitDirectory)
$primaryTopLevel = Get-SingleGitPath `
  -GitPath $git.Source `
  -WorkingDirectory $primaryRoot `
  -Arguments @("rev-parse", "--path-format=absolute", "--show-toplevel") `
  -Description "Primary Git worktree root discovery"
$primaryGitDirectory = Get-SingleGitPath `
  -GitPath $git.Source `
  -WorkingDirectory $primaryRoot `
  -Arguments @("rev-parse", "--path-format=absolute", "--git-dir") `
  -Description "Primary Git directory discovery"
if (-not (Test-SamePath $primaryTopLevel $primaryRoot) -or -not (Test-SamePath $primaryGitDirectory $commonGitDirectory)) {
  throw "The common Git directory does not identify a valid primary worktree."
}

$isLinkedWorktree = -not (Test-SamePath $repoRoot $primaryRoot)
if ($isLinkedWorktree) {
  $linkedGitDirectoryRelative = [IO.Path]::GetRelativePath($commonGitDirectory, $gitDirectory).Replace('\', '/')
  $requiredLinkedParent = Get-NormalizedFullPath (Join-Path $primaryRoot ".worktree")
  if (
    $linkedGitDirectoryRelative -notmatch '^worktrees/[^/]+$' -or
    -not (Test-SamePath (Split-Path -Parent $repoRoot) $requiredLinkedParent) -or
    -not (Test-Path -LiteralPath (Join-Path $repoRoot ".git") -PathType Leaf)
  ) {
    throw "Linked release daemon builds require a registered primaryRoot/.worktree/<name> Git worktree."
  }

  $worktreeList = @(Invoke-RepositoryGit `
    -GitPath $git.Source `
    -WorkingDirectory $repoRoot `
    -Arguments @("worktree", "list", "--porcelain", "-z") `
    -Description "Git worktree registration discovery")
  $worktreeFields = @(
    (($worktreeList -join "`n") -split [string][char]0) |
      Where-Object { $_.StartsWith("worktree ", [StringComparison]::Ordinal) } |
      ForEach-Object { Get-NormalizedFullPath $_.Substring("worktree ".Length) }
  )
  if (
    $worktreeFields.Count -lt 2 -or
    -not (Test-SamePath $worktreeFields[0] $primaryRoot) -or
    @($worktreeFields | Where-Object { Test-SamePath $_ $repoRoot }).Count -ne 1
  ) {
    throw "The linked release daemon worktree is not uniquely registered to the discovered primary worktree."
  }
}
elseif (-not (Test-SamePath $gitDirectory $commonGitDirectory)) {
  throw "The primary release daemon checkout has inconsistent Git directory ownership."
}

$repositoryCargoConfig = Join-Path $repoRoot ".cargo\config.toml"
if (-not (Test-Path -LiteralPath $repositoryCargoConfig -PathType Leaf)) {
  throw "Repository Cargo configuration is missing: $repositoryCargoConfig"
}
$repositoryCargoBlob = Assert-TrackedCleanCargoConfig `
  -GitPath $git.Source `
  -WorkingDirectory $repoRoot `
  -Description "Current worktree Cargo configuration"

$primaryCargoConfig = Join-Path $primaryRoot ".cargo\config.toml"
if (-not (Test-Path -LiteralPath $primaryCargoConfig -PathType Leaf)) {
  throw "Primary worktree Cargo configuration is missing: $primaryCargoConfig"
}
if ($isLinkedWorktree) {
  $primaryCargoBlob = Assert-TrackedCleanCargoConfig `
    -GitPath $git.Source `
    -WorkingDirectory $primaryRoot `
    -Description "Primary worktree Cargo configuration"
  if ($repositoryCargoBlob -cne $primaryCargoBlob) {
    throw "Linked and primary worktree Cargo configurations must reference the same tracked Git blob."
  }
  if ((Get-FileHash -LiteralPath $repositoryCargoConfig -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $primaryCargoConfig -Algorithm SHA256).Hash) {
    throw "Linked and primary worktree Cargo configurations must be byte-identical."
  }
}

$externalCargoConfigs = [Collections.Generic.List[string]]::new()
$legacyRepositoryCargoConfig = Join-Path $repoRoot ".cargo\config"
$externalCargoConfigs.Add($legacyRepositoryCargoConfig)
$legacyPrimaryCargoConfig = Join-Path $primaryRoot ".cargo\config"
$externalCargoConfigs.Add($legacyPrimaryCargoConfig)

$userProfile = [Environment]::GetEnvironmentVariable("USERPROFILE")
if ([string]::IsNullOrWhiteSpace($userProfile) -or -not [IO.Path]::IsPathRooted($userProfile)) {
  throw "USERPROFILE must be an absolute path so Cargo's default home configuration can be verified."
}
$cargoHome = Join-Path (Get-NormalizedFullPath $userProfile) ".cargo"
$externalCargoConfigs.Add((Join-Path $cargoHome "config"))
$externalCargoConfigs.Add((Join-Path $cargoHome "config.toml"))

$parentDirectory = [IO.Directory]::GetParent($repoRoot)
while ($null -ne $parentDirectory) {
  $externalCargoConfigs.Add((Join-Path $parentDirectory.FullName ".cargo\config"))
  $parentTomlConfig = Join-Path $parentDirectory.FullName ".cargo\config.toml"
  if (-not (Test-SamePath $parentTomlConfig $primaryCargoConfig)) {
    $externalCargoConfigs.Add($parentTomlConfig)
  }
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

$cargo = Resolve-RequiredApplication "cargo"
$rustc = Resolve-RequiredApplication "rustc"
$manifestPath = Join-Path $repoRoot "Cargo.toml"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
  throw "Repository Cargo workspace manifest is missing: $manifestPath"
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

Push-Location $primaryRoot
try {
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

  & $cargo.Source build --manifest-path $manifestPath -p subversionr-daemon --release --locked --target-dir $targetRoot
  if ($LASTEXITCODE -ne 0) {
    throw "Release daemon build failed with exit code $LASTEXITCODE."
  }
}
finally {
  Pop-Location
}

Assert-DeterministicPeFile -Path $daemonPath | Out-Null
Write-Host "Built deterministic SubversionR release daemon at $daemonPath."

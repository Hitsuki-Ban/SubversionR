[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$CurrentPackageRoot,

  [Parameter(Mandatory = $true)]
  [string]$SyntheticPreviousVersion,

  [Parameter(Mandatory = $true)]
  [string]$FixtureRoot,

  [Parameter(Mandatory = $true)]
  [string]$EvidencePath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$verifyLayoutScript = Join-Path $PSScriptRoot "verify-vscode-package-layout.ps1"

function Get-RepoAbsolutePath([string]$Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }

  [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Get-RepoRelativePath([string]$Path) {
  [System.IO.Path]::GetRelativePath($repoRoot, $Path).Replace("\", "/")
}

function Assert-Directory([string]$Path, [string]$Name) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "$Name must be a directory: $Path"
  }
  (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
}

function Assert-File([string]$Path, [string]$Name) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Name must be a file: $Path"
  }
  (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
}

function Assert-TargetPath([string]$Path, [string]$Name) {
  $absolute = Get-RepoAbsolutePath $Path
  $targetRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target"))
  $targetRootWithSeparator = $targetRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  if (-not ($absolute.StartsWith($targetRootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "$Name must resolve inside the repository target directory: $Path"
  }
  $absolute
}

function Test-IsPathWithin([string]$Path, [string]$Root) {
  $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  $pathFull = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  $pathFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-IsSamePath([string]$Left, [string]$Right) {
  $leftFull = [System.IO.Path]::GetFullPath($Left).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  $rightFull = [System.IO.Path]::GetFullPath($Right).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  [string]::Equals($leftFull, $rightFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-AllowedGeneratedPath([string]$Path, [string]$Name, [string[]]$AllowedRoots, [string]$Description) {
  $absolute = Assert-TargetPath -Path $Path -Name $Name

  foreach ($allowedRoot in $AllowedRoots) {
    if (Test-IsPathWithin -Path $absolute -Root $allowedRoot) {
      return $absolute
    }
  }

  throw "$Name must resolve inside $Description`: $Path"
}

function Assert-AllowedFixtureRoot([string]$Path) {
  $releaseEvidenceRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence\install-rollback-fixture"))
  $testsRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-install-rollback-fixture"))
  $fixtureRoot = Assert-AllowedGeneratedPath -Path $Path -Name "FixtureRoot" -AllowedRoots @(
    $releaseEvidenceRoot,
    $testsRoot
  ) -Description "target/release-evidence/install-rollback-fixture or target/tests/release-install-rollback-fixture"

  if ((Test-IsSamePath -Left $fixtureRoot -Right $releaseEvidenceRoot) -or (Test-IsSamePath -Left $fixtureRoot -Right $testsRoot)) {
    throw "FixtureRoot must include a dedicated child directory below the install rollback fixture root: $Path"
  }

  $fixtureRoot
}

function Assert-AllowedEvidencePath([string]$Path) {
  Assert-AllowedGeneratedPath -Path $Path -Name "EvidencePath" -AllowedRoots @(
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence")),
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-install-rollback-fixture"))
  ) -Description "target/release-evidence or target/tests/release-install-rollback-fixture"
}

function Assert-ChildPath([string]$Root, [string]$Path, [string]$Name) {
  $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  $pathFull = [System.IO.Path]::GetFullPath($Path)
  if (-not $pathFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "$Name must stay inside $Root`: $Path"
  }
  $pathFull
}

function Assert-SemVer([string]$Version, [string]$Name) {
  if ($Version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
    throw "$Name must be a semantic version: $Version"
  }
}

function Invoke-LayoutVerification([string]$PackageRoot) {
  Assert-File $verifyLayoutScript "VS Code package layout verifier" | Out-Null
  & $verifyLayoutScript -Target $Target -PackageRoot $PackageRoot
}

function Read-PackageContract([string]$PackageRoot, [string]$Name) {
  $packageRootResolved = Assert-Directory $PackageRoot $Name
  Invoke-LayoutVerification $packageRootResolved

  $packageJsonPath = Assert-File (Join-Path $packageRootResolved "package.json") "$Name package.json"
  $packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  $resourceRoot = Join-Path $packageRootResolved "resources\backend\$Target"
  $manifestPath = Assert-File (Join-Path $resourceRoot "subversionr-backend-package-manifest.json") "$Name backend package manifest"
  $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json

  if ($packageJson.name -ne "subversionr") {
    throw "Extension package id must be subversionr."
  }
  if ($packageJson.publisher -ne "hitsuki-ban") {
    throw "Extension publisher must be hitsuki-ban."
  }
  if ($packageJson.displayName -ne "SubversionR") {
    throw "Extension displayName must be SubversionR."
  }
  Assert-SemVer -Version $packageJson.version -Name "$Name package version"
  if ($manifest.extension.version -ne $packageJson.version) {
    throw "$Name backend manifest extension version must match package.json version."
  }
  if ($manifest.layoutKind -ne "staged-vsix-layout") {
    throw "$Name layoutKind must remain staged-vsix-layout until a real VSIX gate exists."
  }
  if ($manifest.target -ne $Target -or $manifest.vsceTarget -ne $Target) {
    throw "$Name backend manifest target must match $Target."
  }

  $extensionId = "$($packageJson.publisher).$($packageJson.name)"
  [pscustomobject]@{
    packageRoot = $packageRootResolved
    packageJsonPath = $packageJsonPath
    manifestPath = $manifestPath
    extensionId = $extensionId
    extensionDirectoryName = "$extensionId-$($packageJson.version)"
    publisher = [string]$packageJson.publisher
    name = [string]$packageJson.name
    displayName = [string]$packageJson.displayName
    version = [string]$packageJson.version
    manifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
  }
}

function Copy-PackageDirectory([string]$SourceRoot, [string]$DestinationRoot) {
  $parent = Split-Path -Parent $DestinationRoot
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  if (Test-Path -LiteralPath $DestinationRoot) {
    throw "Destination package directory already exists: $DestinationRoot"
  }
  Copy-Item -LiteralPath $SourceRoot -Destination $DestinationRoot -Recurse
}

function Set-PackageVersion([string]$PackageRoot, [string]$Version) {
  $packageJsonPath = Assert-File (Join-Path $PackageRoot "package.json") "Synthetic previous package.json"
  $packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  $packageJson.version = $Version
  $packageJson | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $packageJsonPath -Encoding utf8

  $manifestPath = Assert-File (Join-Path $PackageRoot "resources\backend\$Target\subversionr-backend-package-manifest.json") "Synthetic previous backend package manifest"
  $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  $manifest.extension.version = $Version
  $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding utf8
}

function Install-ExtensionPackage([object]$Contract, [string]$ExtensionsRoot) {
  New-Item -ItemType Directory -Force -Path $ExtensionsRoot | Out-Null
  $destination = Assert-ChildPath -Root $ExtensionsRoot -Path (Join-Path $ExtensionsRoot $Contract.extensionDirectoryName) -Name "Installed extension directory"
  Copy-PackageDirectory -SourceRoot $Contract.packageRoot -DestinationRoot $destination
  Read-PackageContract -PackageRoot $destination -Name "Installed $($Contract.extensionDirectoryName)" | Out-Null
  $destination
}

function Assert-InstalledOnly([string]$ExtensionsRoot, [string]$ExpectedDirectoryName) {
  $extensionDirectories = @(Get-ChildItem -LiteralPath $ExtensionsRoot -Directory -Filter "hitsuki-ban.subversionr-*" | Sort-Object Name)
  if ($extensionDirectories.Count -ne 1 -or $extensionDirectories[0].Name -ne $ExpectedDirectoryName) {
    throw "Expected exactly one active SubversionR extension directory '$ExpectedDirectoryName' under $ExtensionsRoot; found $($extensionDirectories.Name -join ', ')."
  }
}

function New-PhaseRecord([string]$Name, [AllowNull()][object]$FromVersion, [string]$ToVersion, [string]$ActiveDirectoryName) {
  [pscustomobject]@{
    name = $Name
    result = "passed"
    fromVersion = $FromVersion
    toVersion = $ToVersion
    activeExtensionDirectory = $ActiveDirectoryName
    workingCopyMutation = "none"
  }
}

function New-WorkingCopySentinel([string]$Root) {
  $workingCopyRoot = Assert-ChildPath -Root $Root -Path (Join-Path $Root "working-copy-sentinel") -Name "Working copy sentinel root"
  $svnRoot = Join-Path $workingCopyRoot ".svn"
  New-Item -ItemType Directory -Force -Path $svnRoot | Out-Null
  $wcDbPath = Join-Path $svnRoot "wc.db"
  [System.IO.File]::WriteAllBytes($wcDbPath, [System.Text.Encoding]::UTF8.GetBytes("SubversionR M7f working-copy non-mutation sentinel"))
  [pscustomobject]@{
    root = $workingCopyRoot
    wcDbPath = $wcDbPath
    beforeSha256 = (Get-FileHash -LiteralPath $wcDbPath -Algorithm SHA256).Hash.ToLowerInvariant()
  }
}

function Assert-WorkingCopySentinelUnchanged([object]$Sentinel) {
  if (-not (Test-Path -LiteralPath $Sentinel.wcDbPath -PathType Leaf)) {
    throw "Working-copy sentinel wc.db was removed: $($Sentinel.wcDbPath)"
  }
  $afterSha256 = (Get-FileHash -LiteralPath $Sentinel.wcDbPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($afterSha256 -ne $Sentinel.beforeSha256) {
    throw "Working-copy sentinel wc.db changed during install/upgrade/rollback fixture."
  }
  $afterSha256
}

$currentPackageRootResolved = Assert-Directory $CurrentPackageRoot "CurrentPackageRoot"
Assert-SemVer -Version $SyntheticPreviousVersion -Name "SyntheticPreviousVersion"
$fixtureRootResolved = Assert-AllowedFixtureRoot -Path $FixtureRoot
$evidencePathResolved = Assert-AllowedEvidencePath -Path $EvidencePath

if (Test-IsPathWithin -Path $currentPackageRootResolved -Root $fixtureRootResolved) {
  throw "FixtureRoot must not contain CurrentPackageRoot because the fixture root is cleared before the run."
}

if (Test-Path -LiteralPath $fixtureRootResolved) {
  Remove-Item -LiteralPath $fixtureRootResolved -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $fixtureRootResolved | Out-Null

$workingCopySentinel = New-WorkingCopySentinel -Root $fixtureRootResolved

$currentContract = Read-PackageContract -PackageRoot $currentPackageRootResolved -Name "CurrentPackageRoot"
if ($SyntheticPreviousVersion -eq $currentContract.version) {
  throw "SyntheticPreviousVersion must differ from the current package version."
}

$syntheticPreviousRoot = Assert-ChildPath -Root $fixtureRootResolved -Path (Join-Path $fixtureRootResolved "packages\synthetic-previous") -Name "Synthetic previous package root"
Copy-PackageDirectory -SourceRoot $currentContract.packageRoot -DestinationRoot $syntheticPreviousRoot
Set-PackageVersion -PackageRoot $syntheticPreviousRoot -Version $SyntheticPreviousVersion
$previousContract = Read-PackageContract -PackageRoot $syntheticPreviousRoot -Name "SyntheticPreviousPackage"

if ($previousContract.extensionId -ne $currentContract.extensionId) {
  throw "Synthetic previous package identity must match the current package identity."
}

$freshExtensionsRoot = Assert-ChildPath -Root $fixtureRootResolved -Path (Join-Path $fixtureRootResolved "fresh\extensions") -Name "Fresh install extensions root"
$freshInstalled = Install-ExtensionPackage -Contract $currentContract -ExtensionsRoot $freshExtensionsRoot
Assert-InstalledOnly -ExtensionsRoot $freshExtensionsRoot -ExpectedDirectoryName $currentContract.extensionDirectoryName

$upgradeRoot = Assert-ChildPath -Root $fixtureRootResolved -Path (Join-Path $fixtureRootResolved "upgrade") -Name "Upgrade fixture root"
$upgradeExtensionsRoot = Join-Path $upgradeRoot "extensions"
$rollbackStoreRoot = Join-Path $upgradeRoot "rollback-store"
New-Item -ItemType Directory -Force -Path $rollbackStoreRoot | Out-Null

$previousInstalled = Install-ExtensionPackage -Contract $previousContract -ExtensionsRoot $upgradeExtensionsRoot
Assert-InstalledOnly -ExtensionsRoot $upgradeExtensionsRoot -ExpectedDirectoryName $previousContract.extensionDirectoryName

$rollbackBackup = Assert-ChildPath -Root $rollbackStoreRoot -Path (Join-Path $rollbackStoreRoot $previousContract.extensionDirectoryName) -Name "Rollback backup directory"
Move-Item -LiteralPath $previousInstalled -Destination $rollbackBackup
if (Test-Path -LiteralPath $previousInstalled) {
  throw "Previous extension directory should be moved to the rollback store before upgrade."
}

$currentInstalledForUpgrade = Install-ExtensionPackage -Contract $currentContract -ExtensionsRoot $upgradeExtensionsRoot
Assert-InstalledOnly -ExtensionsRoot $upgradeExtensionsRoot -ExpectedDirectoryName $currentContract.extensionDirectoryName

$currentInstalledForUpgrade = Assert-ChildPath -Root $upgradeExtensionsRoot -Path $currentInstalledForUpgrade -Name "Current installed extension directory"
Remove-Item -LiteralPath $currentInstalledForUpgrade -Recurse -Force
Move-Item -LiteralPath $rollbackBackup -Destination $previousInstalled
Read-PackageContract -PackageRoot $previousInstalled -Name "Rolled back extension" | Out-Null
Assert-InstalledOnly -ExtensionsRoot $upgradeExtensionsRoot -ExpectedDirectoryName $previousContract.extensionDirectoryName
$workingCopyAfterSha256 = Assert-WorkingCopySentinelUnchanged -Sentinel $workingCopySentinel

$phaseRecords = @(
  New-PhaseRecord -Name "fresh-install" -FromVersion $null -ToVersion $currentContract.version -ActiveDirectoryName $currentContract.extensionDirectoryName
  New-PhaseRecord -Name "upgrade" -FromVersion $previousContract.version -ToVersion $currentContract.version -ActiveDirectoryName $currentContract.extensionDirectoryName
  New-PhaseRecord -Name "rollback" -FromVersion $currentContract.version -ToVersion $previousContract.version -ActiveDirectoryName $previousContract.extensionDirectoryName
)

$report = [pscustomobject]@{
  schemaVersion = 1
  schema = "subversionr.release.install-rollback-fixture.win32-x64.v1"
  fixtureKind = "isolated-vscode-extension-directory"
  publicReadinessClaim = $false
  target = $Target
  traceIds = @("MIG-009", "MIG-010", "TST-024")
  extension = [pscustomobject]@{
    id = $currentContract.extensionId
    publisher = $currentContract.publisher
    name = $currentContract.name
    displayName = $currentContract.displayName
    currentVersion = $currentContract.version
    previousVersion = $previousContract.version
  }
  packages = [pscustomobject]@{
    current = [pscustomobject]@{
      root = Get-RepoRelativePath $currentContract.packageRoot
      manifestSha256 = $currentContract.manifestSha256
      source = "staged-package-layout"
    }
    previous = [pscustomobject]@{
      root = Get-RepoRelativePath $previousContract.packageRoot
      manifestSha256 = $previousContract.manifestSha256
      source = "synthetic-current-layout"
    }
  }
  fixtureRoots = [pscustomobject]@{
    root = Get-RepoRelativePath $fixtureRootResolved
    freshExtensions = Get-RepoRelativePath $freshExtensionsRoot
    upgradeExtensions = Get-RepoRelativePath $upgradeExtensionsRoot
    workingCopySentinel = Get-RepoRelativePath $workingCopySentinel.root
  }
  workingCopySentinel = [pscustomobject]@{
    path = Get-RepoRelativePath $workingCopySentinel.wcDbPath
    beforeSha256 = $workingCopySentinel.beforeSha256
    afterSha256 = $workingCopyAfterSha256
    mutation = "none"
  }
  phases = $phaseRecords
  assertions = @(
    "current package layout verifier passed before install",
    "synthetic previous package layout verifier passed before upgrade",
    "fresh install produced exactly one active SubversionR extension directory",
    "upgrade replaced the synthetic previous extension directory with the current directory",
    "rollback restored the synthetic previous extension directory",
    "no real VS Code user-data or extension directory was touched",
    "working-copy sentinel .svn/wc.db hash was unchanged",
    "workingCopyMutation remained none for every phase"
  )
}

$evidenceParent = Split-Path -Parent $evidencePathResolved
New-Item -ItemType Directory -Force -Path $evidenceParent | Out-Null
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $evidencePathResolved -Encoding utf8

Write-Host "Verified SubversionR VS Code install/upgrade/rollback fixture for $Target at $fixtureRootResolved."

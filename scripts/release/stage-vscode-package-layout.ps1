[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$ExtensionRoot,

  [Parameter(Mandatory = $true)]
  [string]$DaemonExe,

  [Parameter(Mandatory = $true)]
  [string]$BridgeRuntimeDirectory,

  [Parameter(Mandatory = $true)]
  [string]$SourceLockPath,

  [Parameter(Mandatory = $true)]
  [string]$OutputRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$svnCliTools = @(
  "svn.exe",
  "svnadmin.exe",
  "svnbench.exe",
  "svndumpfilter.exe",
  "svnfsfs.exe",
  "svnlook.exe",
  "svnmucc.exe",
  "svnrdump.exe",
  "svnserve.exe",
  "svnsync.exe",
  "svnversion.exe"
)
$requiredNativeDependencyNames = @(
  "libsvn_client-1.dll",
  "libsvn_delta-1.dll",
  "libsvn_diff-1.dll",
  "libsvn_fs-1.dll",
  "libsvn_fs_fs-1.dll",
  "libsvn_fs_util-1.dll",
  "libsvn_fs_x-1.dll",
  "libsvn_ra-1.dll",
  "libsvn_repos-1.dll",
  "libsvn_subr-1.dll",
  "libsvn_wc-1.dll",
  "libapr-1.dll",
  "libapriconv-1.dll",
  "libaprutil-1.dll",
  "libexpat.dll"
)
$requiredNativeDependencyPatterns = @(
  "libcrypto-*.dll",
  "libssl-*.dll"
)
$ignoredNativeRuntimeNames = @(
  "apr_dbd_odbc-1.dll",
  "apr_ldap-1.dll"
)

function Get-RepoAbsolutePath([string]$Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }

  [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Assert-File([string]$Path, [string]$Name) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Name must be a file: $Path"
  }
  $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
  $resolved.Path
}

function Assert-Directory([string]$Path, [string]$Name) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "$Name must be a directory: $Path"
  }
  $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
  $resolved.Path
}

function Assert-OutputRoot([string]$Path) {
  $absolute = Get-RepoAbsolutePath $Path
  $targetRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target"))
  $targetRootWithSeparator = $targetRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  if (-not ($absolute.StartsWith($targetRootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "OutputRoot must resolve inside the repository target directory: $Path"
  }
  $absolute
}

function Copy-RequiredFile([string]$Source, [string]$Destination) {
  $parent = Split-Path -Parent $Destination
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Assert-NormalizedPackageRelativePath([string]$Path, [string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "$Name must not be empty."
  }
  if ([System.IO.Path]::IsPathRooted($Path) -or $Path.Contains("\") -or $Path.Contains("../") -or $Path.Contains("/../") -or $Path -eq "." -or $Path.StartsWith("./")) {
    throw "$Name must be a normalized package-relative path: $Path"
  }
  foreach ($segment in $Path.Split("/")) {
    if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq "." -or $segment -eq "..") {
      throw "$Name must be a normalized package-relative path: $Path"
    }
  }
  $Path
}

function Get-PngDimensions([string]$Path, [string]$Name) {
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $signature = [byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
  if ($bytes.Length -lt 24) {
    throw "$Name must be a PNG file with an IHDR chunk: $Path"
  }
  for ($index = 0; $index -lt $signature.Length; $index++) {
    if ($bytes[$index] -ne $signature[$index]) {
      throw "$Name must be a PNG file: $Path"
    }
  }
  $chunkType = [System.Text.Encoding]::ASCII.GetString($bytes, 12, 4)
  if ($chunkType -ne "IHDR") {
    throw "$Name must start with a PNG IHDR chunk: $Path"
  }

  [pscustomobject]@{
    width = (([int]$bytes[16] -shl 24) -bor ([int]$bytes[17] -shl 16) -bor ([int]$bytes[18] -shl 8) -bor [int]$bytes[19])
    height = (([int]$bytes[20] -shl 24) -bor ([int]$bytes[21] -shl 16) -bor ([int]$bytes[22] -shl 8) -bor [int]$bytes[23])
  }
}

function Assert-MarketplaceIcon([string]$Path, [string]$Name) {
  if ([System.IO.Path]::GetExtension($Path) -ne ".png") {
    throw "$Name must be a PNG file: $Path"
  }
  $dimensions = Get-PngDimensions -Path $Path -Name $Name
  if ($dimensions.width -lt 128 -or $dimensions.height -lt 128) {
    throw "$Name must be at least 128x128 pixels for Marketplace presentation: $($dimensions.width)x$($dimensions.height)."
  }
  $dimensions
}

function Get-RequiredRuntimeFilePattern([string]$Root, [string]$Pattern) {
  $matches = @(Get-ChildItem -LiteralPath $Root -File -Filter $Pattern | Sort-Object Name)
  if ($matches.Count -ne 1) {
    throw "BridgeRuntimeDirectory must contain exactly one runtime artifact matching $Pattern; found $($matches.Count)."
  }
  $matches[0].FullName
}

function Get-ArtifactRecord([string]$PackageRoot, [string]$Path, [string]$Role) {
  $relativePath = [System.IO.Path]::GetRelativePath($PackageRoot, $Path).Replace("\", "/")
  if ($relativePath.StartsWith("../", [System.StringComparison]::Ordinal) -or [System.IO.Path]::IsPathRooted($relativePath)) {
    throw "Artifact path must stay inside the staged package root: $Path"
  }
  $item = Get-Item -LiteralPath $Path
  [pscustomobject]@{
    role = $Role
    path = $relativePath
    size = $item.Length
    sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  }
}

function Copy-ExtensionMetadata([string]$SourceRoot, [string]$DestinationRoot) {
  foreach ($fileName in @(
    "package.json",
    "package.nls.json",
    "package.nls.ja.json",
    "package.nls.zh-cn.json"
  )) {
    Copy-RequiredFile (Assert-File (Join-Path $SourceRoot $fileName) $fileName) (Join-Path $DestinationRoot $fileName)
  }

  $l10nRoot = Assert-Directory (Join-Path $SourceRoot "l10n") "Extension l10n directory"
  Copy-Item -LiteralPath $l10nRoot -Destination (Join-Path $DestinationRoot "l10n") -Recurse -Force
}

function Copy-ExtensionMarketplaceAssets([object]$PackageJson, [string]$SourceRoot, [string]$DestinationRoot) {
  $iconPath = [string]$PackageJson.icon
  $iconRelativePath = Assert-NormalizedPackageRelativePath -Path $iconPath -Name "Extension package icon"
  if (-not $iconRelativePath.EndsWith(".png", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Extension package icon must point to a PNG file: $iconRelativePath"
  }

  $sourceIconPath = Assert-File (Join-Path $SourceRoot $iconRelativePath.Replace("/", [System.IO.Path]::DirectorySeparatorChar)) "Extension package icon"
  Assert-MarketplaceIcon -Path $sourceIconPath -Name "Extension package icon" | Out-Null
  Copy-RequiredFile $sourceIconPath (Join-Path $DestinationRoot $iconRelativePath.Replace("/", [System.IO.Path]::DirectorySeparatorChar))
}

function Convert-SourceLocks([string]$Path) {
  $lock = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
  if ($null -eq $lock.sources -or @($lock.sources).Count -eq 0) {
    throw "SourceLockPath must contain a non-empty sources array."
  }

  @($lock.sources | ForEach-Object {
    [pscustomobject]@{
      name = $_.name
      version = $_.version
      license = $_.license
      sha512 = $_.sha512
    }
  })
}

function Assert-NoSvnCliToolsInPackage([string]$Root) {
  $foundTools = @(Get-ChildItem -LiteralPath $Root -File -Recurse |
    Where-Object { $svnCliTools -contains $_.Name } |
    Select-Object -ExpandProperty FullName)
  if ($foundTools.Count -gt 0) {
    throw "Staged VS Code package resources must not include SVN CLI tools: $($foundTools -join ', ')"
  }
}

function Copy-IconvModules([string]$SourceRoot, [string]$DestinationRoot) {
  $iconvSourceRoot = Assert-Directory (Join-Path $SourceRoot "iconv") "APR iconv runtime directory"
  $modules = @(Get-ChildItem -LiteralPath $iconvSourceRoot -File -Filter "*.so" | Sort-Object Name)
  if ($modules.Count -eq 0) {
    throw "APR iconv runtime directory must contain converter modules: $iconvSourceRoot"
  }

  $iconvDestinationRoot = Join-Path $DestinationRoot "iconv"
  New-Item -ItemType Directory -Force -Path $iconvDestinationRoot | Out-Null
  foreach ($module in $modules) {
    Copy-RequiredFile $module.FullName (Join-Path $iconvDestinationRoot $module.Name)
  }
}

$extensionRootResolved = Assert-Directory $ExtensionRoot "ExtensionRoot"
$daemonExeResolved = Assert-File $DaemonExe "DaemonExe"
$bridgeRuntimeResolved = Assert-Directory $BridgeRuntimeDirectory "BridgeRuntimeDirectory"
$sourceLockResolved = Assert-File $SourceLockPath "SourceLockPath"
$outputRootResolved = Assert-OutputRoot $OutputRoot

if ((Split-Path -Leaf $daemonExeResolved) -ne "subversionr-daemon.exe") {
  throw "DaemonExe must point to subversionr-daemon.exe."
}

$bridgeDll = Assert-File (Join-Path $bridgeRuntimeResolved "subversionr_svn_bridge.dll") "Bridge DLL"
$extensionPackageJson = Get-Content -Raw -LiteralPath (Join-Path $extensionRootResolved "package.json") | ConvertFrom-Json
if ($extensionPackageJson.name -ne "subversionr") {
  throw "Extension package id must be subversionr."
}
if ($extensionPackageJson.displayName -ne "SubversionR") {
  throw "Extension displayName must be SubversionR."
}

$packageRoot = Join-Path $outputRootResolved "subversionr-$Target"
$resourceRoot = Join-Path $packageRoot "resources\backend\$Target"

if (Test-Path -LiteralPath $packageRoot) {
  Remove-Item -LiteralPath $packageRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $resourceRoot | Out-Null

Copy-ExtensionMetadata -SourceRoot $extensionRootResolved -DestinationRoot $packageRoot
Copy-ExtensionMarketplaceAssets -PackageJson $extensionPackageJson -SourceRoot $extensionRootResolved -DestinationRoot $packageRoot
Copy-RequiredFile $daemonExeResolved (Join-Path $resourceRoot "subversionr-daemon.exe")
Copy-RequiredFile $bridgeDll (Join-Path $resourceRoot "subversionr_svn_bridge.dll")

foreach ($requiredDependencyName in $requiredNativeDependencyNames) {
  Assert-File (Join-Path $bridgeRuntimeResolved $requiredDependencyName) "Required native dependency" | Out-Null
}
foreach ($requiredPattern in $requiredNativeDependencyPatterns) {
  Get-RequiredRuntimeFilePattern -Root $bridgeRuntimeResolved -Pattern $requiredPattern | Out-Null
}

$copiedNativeDependencies = @()
foreach ($dependencyName in $requiredNativeDependencyNames) {
  $sourcePath = Assert-File (Join-Path $bridgeRuntimeResolved $dependencyName) "Required native dependency"
  $destinationPath = Join-Path $resourceRoot $dependencyName
  Copy-RequiredFile $sourcePath $destinationPath
  $copiedNativeDependencies += $destinationPath
}
foreach ($requiredPattern in $requiredNativeDependencyPatterns) {
  $sourcePath = Get-RequiredRuntimeFilePattern -Root $bridgeRuntimeResolved -Pattern $requiredPattern
  $fileName = Split-Path -Leaf $sourcePath
  if ($requiredNativeDependencyNames -contains $fileName) {
    continue
  }
  $destinationPath = Join-Path $resourceRoot $fileName
  Copy-RequiredFile $sourcePath $destinationPath
  $copiedNativeDependencies += $destinationPath
}
Copy-IconvModules -SourceRoot $bridgeRuntimeResolved -DestinationRoot $resourceRoot

Assert-NoSvnCliToolsInPackage $packageRoot

$artifactRecords = @()
$artifactRecords += Get-ArtifactRecord -PackageRoot $packageRoot -Path (Join-Path $resourceRoot "subversionr-daemon.exe") -Role "sidecar"
$artifactRecords += Get-ArtifactRecord -PackageRoot $packageRoot -Path (Join-Path $resourceRoot "subversionr_svn_bridge.dll") -Role "bridge"
$artifactRecords += @($copiedNativeDependencies |
  Sort-Object |
  ForEach-Object { Get-ArtifactRecord -PackageRoot $packageRoot -Path $_ -Role "nativeDependency" })
$artifactRecords += @(Get-ChildItem -LiteralPath (Join-Path $resourceRoot "iconv") -File -Filter "*.so" |
  Sort-Object Name |
  ForEach-Object { Get-ArtifactRecord -PackageRoot $packageRoot -Path $_.FullName -Role "nativeDependency" })

$manifest = [pscustomobject]@{
  schemaVersion = 1
  schema = "subversionr.vscode.backend-package.win32-x64.v1"
  layoutKind = "staged-vsix-layout"
  target = $Target
  vsceTarget = $Target
  architecture = "x64"
  configuration = "Release"
  extension = [pscustomobject]@{
    id = $extensionPackageJson.name
    displayName = $extensionPackageJson.displayName
    version = $extensionPackageJson.version
  }
  resourceRoot = "resources/backend/$Target"
  artifacts = $artifactRecords
  sourceLocks = @(Convert-SourceLocks $sourceLockResolved)
  nonPackagedTools = $svnCliTools
  ignoredNativeRuntimeFiles = $ignoredNativeRuntimeNames
}

$manifestPath = Join-Path $resourceRoot "subversionr-backend-package-manifest.json"
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding utf8

Write-Host "Staged SubversionR VS Code package layout for $Target at $packageRoot."

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$PackageRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

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

function Assert-File([string]$Path, [string]$Name) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Name must be a file: $Path"
  }
  (Resolve-Path -LiteralPath $Path).Path
}

function Assert-Directory([string]$Path, [string]$Name) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "$Name must be a directory: $Path"
  }
  (Resolve-Path -LiteralPath $Path).Path
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
  if ($Expected -ne $Actual) {
    throw "$Message Expected '$Expected', got '$Actual'."
  }
}

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw $Message
  }
}

function Assert-RelativeArtifactPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "Manifest artifact path must not be empty."
  }
  if ([System.IO.Path]::IsPathRooted($Path) -or $Path.Contains("\") -or $Path.Contains("../") -or $Path.Contains("/../") -or $Path -eq "." -or $Path.StartsWith("./")) {
    throw "Manifest artifact path must be a normalized relative package path: $Path"
  }
  foreach ($segment in $Path.Split("/")) {
    if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq "." -or $segment -eq "..") {
      throw "Manifest artifact path must be a normalized relative package path: $Path"
    }
  }
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

function Get-RelativePackagePath([string]$Root, [string]$Path) {
  $relativePath = [System.IO.Path]::GetRelativePath($Root, $Path).Replace("\", "/")
  Assert-RelativeArtifactPath $relativePath
  $relativePath
}

function Resolve-ArtifactPath([string]$Root, [string]$RelativePath) {
  Assert-RelativeArtifactPath $RelativePath
  $candidate = [System.IO.Path]::GetFullPath((Join-Path $Root $RelativePath.Replace("/", [System.IO.Path]::DirectorySeparatorChar)))
  $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  if (-not $candidate.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Manifest artifact path escapes the package root: $RelativePath"
  }
  $candidate
}

function Get-PeMachine([string]$Path) {
  $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
  try {
    $reader = [System.IO.BinaryReader]::new($stream)
    try {
      if ($stream.Length -lt 0x40) {
        throw "PE file is too small."
      }
      if ($reader.ReadUInt16() -ne 0x5a4d) {
        throw "PE DOS signature is missing."
      }
      $stream.Seek(0x3c, [System.IO.SeekOrigin]::Begin) | Out-Null
      $peOffset = $reader.ReadInt32()
      if ($peOffset -le 0 -or ($peOffset + 6) -gt $stream.Length) {
        throw "PE header offset is invalid."
      }
      $stream.Seek($peOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
      if ($reader.ReadUInt32() -ne 0x00004550) {
        throw "PE signature is missing."
      }
      $machine = $reader.ReadUInt16()
      switch ($machine) {
        0x8664 { "amd64"; break }
        default { "0x{0:x4}" -f $machine }
      }
    }
    finally {
      $reader.Dispose()
    }
  }
  catch {
    throw "Unable to read PE machine for $Path. $($_.Exception.Message)"
  }
  finally {
    $stream.Dispose()
  }
}

function Assert-Win32X64Pe([string]$Path, [string]$RelativePath) {
  $machine = Get-PeMachine $Path
  if ($machine -ne "amd64") {
    throw "Staged win32-x64 PE artifact must be AMD64: $RelativePath reported $machine."
  }
}

function Assert-NoSvnCliToolsInPackage([string]$Root) {
  $foundTools = @(Get-ChildItem -LiteralPath $Root -File -Recurse |
    Where-Object { $svnCliTools -contains $_.Name } |
    ForEach-Object { Get-RelativePackagePath $Root $_.FullName })
  if ($foundTools.Count -gt 0) {
    throw "Staged VS Code package resources must not include SVN CLI tools: $($foundTools -join ', ')"
  }
}

function Test-AllowedNativeDependencyPath([string]$Path, [string]$Target) {
  $prefix = "resources/backend/$Target/"
  if (-not $Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $false
  }

  $relativeToResourceRoot = $Path.Substring($prefix.Length)
  if ($requiredNativeDependencyNames -contains $relativeToResourceRoot) {
    return $true
  }

  foreach ($pattern in $requiredNativeDependencyPatterns) {
    if ($relativeToResourceRoot -like $pattern) {
      return $true
    }
  }

  $relativeToResourceRoot -like "iconv/*.so"
}

function Assert-RequiredNativeDependencyPattern([object[]]$Artifacts, [string]$Pattern, [string]$Target) {
  $requiredPathPattern = "resources/backend/$Target/$Pattern"
  $matches = @($Artifacts | Where-Object { $_.path -like $requiredPathPattern })
  if ($matches.Count -ne 1) {
    throw "Manifest must list exactly one required private native dependency matching $requiredPathPattern; found $($matches.Count)."
  }
}

$packageRootResolved = Assert-Directory $PackageRoot "PackageRoot"
$resourceRoot = Join-Path $packageRootResolved "resources\backend\$Target"
Assert-Directory $resourceRoot "Backend resource root" | Out-Null

$packageJson = Get-Content -Raw -LiteralPath (Assert-File (Join-Path $packageRootResolved "package.json") "package.json") | ConvertFrom-Json
Assert-Equal "subversionr" $packageJson.name "Staged package id should match SubversionR extension id."
Assert-Equal "SVN-R" $packageJson.displayName "Staged package displayName should match the Marketplace listing."
Assert-True ($packageJson.keywords -contains "svn") "Staged package Marketplace keywords should include svn."
Assert-True ($packageJson.keywords -contains "subversion") "Staged package Marketplace keywords should include subversion."
Assert-True ($packageJson.keywords -contains "source-control") "Staged package Marketplace keywords should include source-control."
Assert-True ($packageJson.keywords -contains "scm") "Staged package Marketplace keywords should include scm."
Assert-True ($packageJson.keywords -contains "apache-subversion") "Staged package Marketplace keywords should include apache-subversion."

$iconRelativePath = [string]$packageJson.icon
Assert-RelativeArtifactPath $iconRelativePath
if (-not $iconRelativePath.EndsWith(".png", [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "Staged package icon must point to a PNG file: $iconRelativePath"
}
$iconPath = Assert-File (Resolve-ArtifactPath -Root $packageRootResolved -RelativePath $iconRelativePath) "Staged Marketplace icon"
Assert-MarketplaceIcon -Path $iconPath -Name "Staged Marketplace icon" | Out-Null

$manifestPath = Assert-File (Join-Path $resourceRoot "subversionr-backend-package-manifest.json") "Backend package manifest"
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json

Assert-Equal 1 $manifest.schemaVersion "Manifest schemaVersion should be stable."
Assert-Equal "subversionr.vscode.backend-package.win32-x64.v1" $manifest.schema "Manifest schema should match the staged backend package contract."
Assert-Equal "staged-vsix-layout" $manifest.layoutKind "Manifest layoutKind should not claim a published VSIX."
Assert-Equal $Target $manifest.target "Manifest target should match the requested package target."
Assert-Equal $Target $manifest.vsceTarget "Manifest vsceTarget should match the requested package target."
Assert-Equal "x64" $manifest.architecture "Manifest architecture should match win32-x64."
Assert-Equal "Release" $manifest.configuration "Manifest configuration should be Release."
Assert-Equal "resources/backend/$Target" $manifest.resourceRoot "Manifest resourceRoot should match the resolver layout."
Assert-Equal "subversionr" $manifest.extension.id "Manifest extension id should be subversionr."
Assert-Equal "SVN-R" $manifest.extension.displayName "Manifest extension displayName should match the Marketplace listing."

Assert-NoSvnCliToolsInPackage $packageRootResolved

$artifacts = @($manifest.artifacts)
if ($artifacts.Count -eq 0) {
  throw "Manifest must list staged backend artifacts."
}
if (@($artifacts | Where-Object { $_.role -eq "sidecar" }).Count -ne 1) {
  throw "Manifest must list exactly one sidecar artifact."
}
if (@($artifacts | Where-Object { $_.role -eq "bridge" }).Count -ne 1) {
  throw "Manifest must list exactly one bridge artifact."
}
$nativeDependencyArtifacts = @($artifacts | Where-Object { $_.role -eq "nativeDependency" })
if ($nativeDependencyArtifacts.Count -eq 0) {
  throw "Manifest must list private native dependency artifacts."
}
foreach ($requiredDependencyName in $requiredNativeDependencyNames) {
  $requiredPath = "resources/backend/$Target/$requiredDependencyName"
  if (@($nativeDependencyArtifacts | Where-Object { $_.path -eq $requiredPath }).Count -ne 1) {
    throw "Manifest must list required private native dependency: $requiredPath"
  }
}
foreach ($requiredDependencyPattern in $requiredNativeDependencyPatterns) {
  Assert-RequiredNativeDependencyPattern -Artifacts $nativeDependencyArtifacts -Pattern $requiredDependencyPattern -Target $Target
}
if (@($nativeDependencyArtifacts | Where-Object { $_.path -like "resources/backend/$Target/iconv/*.so" }).Count -eq 0) {
  throw "Manifest must list APR iconv converter modules under resources/backend/$Target/iconv."
}

$expectedResourcePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$expectedResourcePaths.Add((Get-RelativePackagePath $packageRootResolved $manifestPath)) | Out-Null
foreach ($artifact in $artifacts) {
  $expectedResourcePaths.Add([string]$artifact.path) | Out-Null
}

$resourceFiles = @(Get-ChildItem -LiteralPath $resourceRoot -File -Recurse)
foreach ($resourceFile in $resourceFiles) {
  $relativeResourcePath = Get-RelativePackagePath $packageRootResolved $resourceFile.FullName
  if (-not $expectedResourcePaths.Contains($relativeResourcePath)) {
    throw "Staged backend resources contain an unexpected resource file: $relativeResourcePath"
  }
}

foreach ($artifact in $artifacts) {
  $artifactPath = Resolve-ArtifactPath $packageRootResolved $artifact.path
  Assert-File $artifactPath "Manifest artifact" | Out-Null
  $item = Get-Item -LiteralPath $artifactPath
  if (-not $artifact.path.StartsWith("resources/backend/$Target/", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Manifest artifact must stay inside the backend resource root: $($artifact.path)"
  }
  if ($artifact.role -eq "sidecar") {
    Assert-Equal "resources/backend/$Target/subversionr-daemon.exe" $artifact.path "Sidecar artifact path should match the resolver contract."
  }
  elseif ($artifact.role -eq "bridge") {
    Assert-Equal "resources/backend/$Target/subversionr_svn_bridge.dll" $artifact.path "Bridge artifact path should match the resolver contract."
  }
  elseif ($artifact.role -eq "nativeDependency") {
    if (-not (Test-AllowedNativeDependencyPath -Path $artifact.path -Target $Target)) {
      throw "Native dependency artifact is not part of the win32-x64 package allowlist: $($artifact.path)"
    }
  }
  else {
    throw "Manifest artifact role is not recognized: $($artifact.role)"
  }
  if ([int64]$artifact.size -ne [int64]$item.Length) {
    throw "Manifest artifact size mismatch for $($artifact.path). Expected $($artifact.size), got $($item.Length)."
  }
  $actualSha256 = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($artifact.sha256 -ne $actualSha256) {
    throw "Manifest artifact sha256 mismatch for $($artifact.path). Expected $($artifact.sha256), got $actualSha256."
  }
  Assert-Win32X64Pe $artifactPath $artifact.path
}

Assert-File (Join-Path $resourceRoot "subversionr-daemon.exe") "Staged sidecar" | Out-Null
Assert-File (Join-Path $resourceRoot "subversionr_svn_bridge.dll") "Staged bridge" | Out-Null

Write-Host "Verified SubversionR VS Code package layout for $Target at $packageRootResolved."

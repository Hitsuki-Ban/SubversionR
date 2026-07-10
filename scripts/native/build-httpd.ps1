[CmdletBinding()]
param(
  [string]$DependencyStageRoot,

  [string]$CacheRoot,

  [string]$WorkRoot,

  [string]$StageRoot,

  [ValidateSet("Release", "Debug")]
  [string]$Configuration = "Release",

  [ValidateSet("x64")]
  [string]$Arch = "x64",

  [string]$VsDevCmd,

  [switch]$SkipVerifySources
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$modulePath = Join-Path $PSScriptRoot "SubversionR.Native.psm1"
Import-Module $modulePath -Force

if (-not $DependencyStageRoot) {
  throw "DependencyStageRoot is required."
}
if (-not $StageRoot) {
  throw "StageRoot is required."
}
if (-not $VsDevCmd) {
  throw "VsDevCmd is required."
}

if (-not $CacheRoot) {
  $CacheRoot = Join-Path $repoRoot ".cache\native\sources"
}
if (-not $WorkRoot) {
  $WorkRoot = Join-Path $repoRoot ".cache\native\work\httpd"
}

$lockPath = Join-Path $repoRoot "native\sources.lock.json"
$lock = Read-NativeSourceLock -Path $lockPath

function Resolve-RequiredDirectory([string]$Path, [string]$Name) {
  $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
  if (-not (Test-Path -LiteralPath $resolved.Path -PathType Container)) {
    throw "$Name must be a directory: $Path"
  }

  return $resolved.Path
}

function Assert-RequiredFile([string]$Path, [string]$Description) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Missing $Description`: $Path"
  }
}

function Assert-RequiredCommand([string]$CommandName, [string]$Description) {
  if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
    throw "$Description is required on PATH: $CommandName"
  }
}

function Quote-CmdArgument([string]$Value) {
  return '"' + $Value.Replace('"', '\"') + '"'
}

function ConvertTo-CMakePath([string]$Path) {
  return ([IO.Path]::GetFullPath($Path)).Replace("\", "/")
}

function Expand-NativeArchive([string]$ArchivePath, [string]$DestinationPath) {
  New-Item -ItemType Directory -Force -Path $DestinationPath | Out-Null

  if ($ArchivePath.EndsWith(".tar.gz", [StringComparison]::OrdinalIgnoreCase)) {
    $tar = Get-Command tar -ErrorAction Stop
    & $tar.Source -xzf $ArchivePath -C $DestinationPath
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to extract $ArchivePath."
    }
    return
  }

  throw "Unsupported Apache HTTP Server archive type: $ArchivePath"
}

function Invoke-DeveloperCommand([string]$Command) {
  Assert-RequiredFile $VsDevCmd "Visual Studio developer command"

  $quotedVsDevCmd = Quote-CmdArgument $VsDevCmd
  $cmd = "call $quotedVsDevCmd -arch=$Arch -host_arch=$Arch && $Command"
  cmd.exe /d /s /c $cmd

  if ($LASTEXITCODE -ne 0) {
    throw "Developer command failed with exit code $LASTEXITCODE."
  }
}

function Get-CMakeCacheEntry([string]$CacheContent, [string]$Name) {
  $match = [regex]::Match($CacheContent, "(?m)^$([regex]::Escape($Name)):[^=]*=(?<value>.*)$")
  if (-not $match.Success) {
    throw "Apache HTTP Server CMake cache is missing required entry: $Name"
  }

  return $match.Groups["value"].Value.Trim()
}

function Normalize-CachePath([string]$Path) {
  return [IO.Path]::GetFullPath($Path.Replace("/", "\")).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Assert-CMakeCachePath([string]$CacheContent, [string]$Name, [string]$ExpectedPath) {
  $actual = Normalize-CachePath (Get-CMakeCacheEntry -CacheContent $CacheContent -Name $Name)
  $expected = Normalize-CachePath $ExpectedPath
  if (-not [string]::Equals($actual, $expected, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Apache HTTP Server CMake cache entry $Name must resolve to $expected; got $actual."
  }
}

function Assert-CMakeCachePathList([string]$CacheContent, [string]$Name, [string[]]$ExpectedPaths) {
  $actualPaths = @((Get-CMakeCacheEntry -CacheContent $CacheContent -Name $Name).Split(";") | Where-Object { $_ } | ForEach-Object { Normalize-CachePath $_ })
  $expectedNormalized = @($ExpectedPaths | ForEach-Object { Normalize-CachePath $_ })
  if ($actualPaths.Count -ne $expectedNormalized.Count) {
    throw "Apache HTTP Server CMake cache entry $Name must contain $($expectedNormalized.Count) paths; got $($actualPaths.Count)."
  }

  for ($i = 0; $i -lt $expectedNormalized.Count; $i++) {
    if (-not [string]::Equals($actualPaths[$i], $expectedNormalized[$i], [StringComparison]::OrdinalIgnoreCase)) {
      throw "Apache HTTP Server CMake cache entry $Name path $i must resolve to $($expectedNormalized[$i]); got $($actualPaths[$i])."
    }
  }
}

function Assert-CMakeCacheValue([string]$CacheContent, [string]$Name, [string]$Expected) {
  $actual = Get-CMakeCacheEntry -CacheContent $CacheContent -Name $Name
  if ($actual -ne $Expected) {
    throw "Apache HTTP Server CMake cache entry $Name must be $Expected; got $actual."
  }
}

function Assert-HttpdCMakeCache {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BuildRoot,

    [Parameter(Mandatory = $true)]
    [string]$DependencyStageRoot
  )

  $cachePath = Join-Path $BuildRoot "CMakeCache.txt"
  Assert-RequiredFile $cachePath "Apache HTTP Server CMake cache"
  $cacheContent = Get-Content -Raw -LiteralPath $cachePath

  $dependencyStageRootResolved = (Resolve-Path -LiteralPath $DependencyStageRoot -ErrorAction Stop).Path
  Assert-CMakeCachePath -CacheContent $cacheContent -Name "CMAKE_PREFIX_PATH" -ExpectedPath $dependencyStageRootResolved
  Assert-CMakeCachePath -CacheContent $cacheContent -Name "APR_INCLUDE_DIR" -ExpectedPath (Join-Path $dependencyStageRootResolved "include")
  Assert-CMakeCachePathList -CacheContent $cacheContent -Name "APR_LIBRARIES" -ExpectedPaths @(
    (Join-Path $dependencyStageRootResolved "lib\libapr-1.lib"),
    (Join-Path $dependencyStageRootResolved "lib\libaprutil-1.lib"),
    (Join-Path $dependencyStageRootResolved "lib\libapriconv-1.lib")
  )
  Assert-CMakeCachePath -CacheContent $cacheContent -Name "PCRE2_DIR" -ExpectedPath (Join-Path $dependencyStageRootResolved "lib\cmake\pcre2")
  Assert-CMakeCachePath -CacheContent $cacheContent -Name "PCRE_INCLUDE_DIR" -ExpectedPath (Join-Path $dependencyStageRootResolved "include")
  Assert-CMakeCachePath -CacheContent $cacheContent -Name "OPENSSL_ROOT_DIR" -ExpectedPath $dependencyStageRootResolved
  Assert-CMakeCachePath -CacheContent $cacheContent -Name "OPENSSL_INCLUDE_DIR" -ExpectedPath (Join-Path $dependencyStageRootResolved "include")
  Assert-CMakeCachePath -CacheContent $cacheContent -Name "OPENSSL_SSL_LIBRARY" -ExpectedPath (Join-Path $dependencyStageRootResolved "lib\libssl.lib")
  Assert-CMakeCachePath -CacheContent $cacheContent -Name "OPENSSL_CRYPTO_LIBRARY" -ExpectedPath (Join-Path $dependencyStageRootResolved "lib\libcrypto.lib")
  Assert-CMakeCachePath -CacheContent $cacheContent -Name "ZLIB_INCLUDE_DIR" -ExpectedPath (Join-Path $dependencyStageRootResolved "include")
  Assert-CMakeCachePath -CacheContent $cacheContent -Name "ZLIB_LIBRARY" -ExpectedPath (Join-Path $dependencyStageRootResolved "lib\zlib.lib")

  Assert-CMakeCacheValue -CacheContent $cacheContent -Name "PCRE2_USE_STATIC_LIBS" -Expected "ON"
  Assert-CMakeCacheValue -CacheContent $cacheContent -Name "PCRE_LIBRARIES" -Expected "PCRE2::8BIT"
  Assert-CMakeCacheValue -CacheContent $cacheContent -Name "CMAKE_DISABLE_FIND_PACKAGE_LibXml2" -Expected "ON"
  Assert-CMakeCacheValue -CacheContent $cacheContent -Name "CMAKE_DISABLE_FIND_PACKAGE_Lua51" -Expected "ON"
  Assert-CMakeCacheValue -CacheContent $cacheContent -Name "CMAKE_DISABLE_FIND_PACKAGE_CURL" -Expected "ON"
  Assert-CMakeCacheValue -CacheContent $cacheContent -Name "ENABLE_MODULES" -Expected "O"
  Assert-CMakeCacheValue -CacheContent $cacheContent -Name "ENABLE_DAV" -Expected "I"
  Assert-CMakeCacheValue -CacheContent $cacheContent -Name "ENABLE_DAV_FS" -Expected "O"
  Assert-CMakeCacheValue -CacheContent $cacheContent -Name "ENABLE_DAV_LOCK" -Expected "O"
  Assert-CMakeCacheValue -CacheContent $cacheContent -Name "ENABLE_SSL" -Expected "I"
  Assert-CMakeCacheValue -CacheContent $cacheContent -Name "ENABLE_DEFLATE" -Expected "I"

  $pcreCFlags = Get-CMakeCacheEntry -CacheContent $cacheContent -Name "PCRE_CFLAGS"
  foreach ($requiredFlag in @("-DHAVE_PCRE2", "-DPCRE2_STATIC")) {
    if (-not $pcreCFlags.Contains($requiredFlag)) {
      throw "Apache HTTP Server CMake cache PCRE_CFLAGS must contain $requiredFlag."
    }
  }

  $extraCompileFlags = Get-CMakeCacheEntry -CacheContent $cacheContent -Name "EXTRA_COMPILE_FLAGS"
  foreach ($requiredFlag in @("/DNETIOAPI_API_=WINAPI", "/DIF_NAMESIZE=256", "/utf-8")) {
    if (-not $extraCompileFlags.Contains($requiredFlag)) {
      throw "Apache HTTP Server CMake cache EXTRA_COMPILE_FLAGS must contain $requiredFlag."
    }
  }
}

function Test-DirectoryPathWithinRoot([string]$Path, [string]$Root) {
  $absolutePath = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  $absoluteRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)

  return $absolutePath.StartsWith($absoluteRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-IndependentHttpdStageRoot([string]$DependencyStageRoot, [string]$StageRoot) {
  $dependencyStage = [IO.Path]::GetFullPath($DependencyStageRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  $httpdStage = [IO.Path]::GetFullPath($StageRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)

  if ([string]::Equals($dependencyStage, $httpdStage, [StringComparison]::OrdinalIgnoreCase) -or
      (Test-DirectoryPathWithinRoot -Path $httpdStage -Root $dependencyStage) -or
      (Test-DirectoryPathWithinRoot -Path $dependencyStage -Root $httpdStage)) {
    throw "Apache HTTP Server StageRoot must be independent from DependencyStageRoot."
  }
}

function Copy-HttpdSupportRuntimes {
  param(
    [Parameter(Mandatory = $true)]
    [string]$DependencyStageRoot,

    [Parameter(Mandatory = $true)]
    [string]$StageRoot
  )

  $dependencyBin = Join-Path $DependencyStageRoot "bin"
  $stageBin = Join-Path $StageRoot "bin"
  New-Item -ItemType Directory -Force -Path $stageBin | Out-Null

  foreach ($runtime in @("libapr-1.dll", "libaprutil-1.dll", "libapriconv-1.dll", "libexpat.dll")) {
    $sourcePath = Join-Path $dependencyBin $runtime
    Assert-RequiredFile $sourcePath "Apache HTTP Server support runtime"
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $stageBin $runtime) -Force
  }

  foreach ($runtimePattern in @("libcrypto-*.dll", "libssl-*.dll")) {
    $runtime = Get-ChildItem -LiteralPath $dependencyBin -File -Filter $runtimePattern | Select-Object -First 1
    if (-not $runtime) {
      throw "Apache HTTP Server support runtime is missing from dependency stage: bin\$runtimePattern"
    }
    Copy-Item -LiteralPath $runtime.FullName -Destination (Join-Path $stageBin $runtime.Name) -Force
  }

  $sourceIconv = Join-Path $dependencyBin "iconv"
  if (-not (Test-Path -LiteralPath $sourceIconv -PathType Container)) {
    throw "Apache HTTP Server support runtime is missing APR iconv directory: $sourceIconv"
  }
  $targetIconv = Join-Path $stageBin "iconv"
  if (Test-Path -LiteralPath $targetIconv -PathType Container) {
    Remove-Item -LiteralPath $targetIconv -Recurse -Force
  }
  Copy-Item -LiteralPath $sourceIconv -Destination $targetIconv -Recurse
}

function Invoke-HttpdStageProbe {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot
  )

  $stageBin = Join-Path $StageRoot "bin"
  $httpdExe = Join-Path $stageBin "httpd.exe"
  Assert-RequiredFile $httpdExe "Apache HTTP Server executable"

  $probeCommand = "set `"PATH=$stageBin;%PATH%`" && $(Quote-CmdArgument $httpdExe) -V && $(Quote-CmdArgument $httpdExe) -t -d $(Quote-CmdArgument $StageRoot) -f conf/httpd.conf"
  Invoke-DeveloperCommand -Command $probeCommand
}

Assert-RequiredCommand "cmake" "Apache HTTP Server CMake"
Assert-RequiredCommand "perl" "Apache HTTP Server build Perl"
Assert-RequiredFile $VsDevCmd "Visual Studio developer command"

if (-not $SkipVerifySources) {
  & (Join-Path $PSScriptRoot "verify-sources.ps1")
}

$dependencyStageRootResolved = Resolve-RequiredDirectory $DependencyStageRoot "DependencyStageRoot"
Assert-IndependentHttpdStageRoot -DependencyStageRoot $dependencyStageRootResolved -StageRoot $StageRoot
Assert-AprPrivateHeadersForHttpd -StageRoot $dependencyStageRootResolved | Out-Null
Assert-ZlibStageForSubversion -StageRoot $dependencyStageRootResolved | Out-Null
Assert-ExpatStageForAprUtil -StageRoot $dependencyStageRootResolved | Out-Null
Assert-Pcre2StageForHttpd -StageRoot $dependencyStageRootResolved -ExpectedVersion "10.47" | Out-Null
Assert-OpenSslStageForSerf -StageRoot $dependencyStageRootResolved -ExpectedVersion "3.5.7" | Out-Null

$source = Get-NativeSourceEntry -Lock $lock -Name "apache-httpd"
$version = Get-RequiredProperty -Object $source -Name "version"
$archivePath = Get-NativeArchivePath -CacheRoot $CacheRoot -Source $source -RequireExisting

$workRootResolved = Clear-NativeGeneratedDirectory -Path $WorkRoot -WorkspaceRoot $repoRoot -Description "Apache HTTP Server work root"
$stageRootResolved = Clear-NativeGeneratedDirectory -Path $StageRoot -WorkspaceRoot $repoRoot -Description "Apache HTTP Server stage root"
Expand-NativeArchive -ArchivePath $archivePath -DestinationPath $workRootResolved

$httpdRoot = Join-Path $workRootResolved "httpd-$version"
Assert-RequiredFile (Join-Path $httpdRoot "CMakeLists.txt") "Apache HTTP Server CMake project"

$buildRoot = Join-Path $workRootResolved "build"
$dependencyStageCMake = ConvertTo-CMakePath $dependencyStageRootResolved
$stageRootCMake = ConvertTo-CMakePath $stageRootResolved
$httpdRootCMake = ConvertTo-CMakePath $httpdRoot
$buildRootCMake = ConvertTo-CMakePath $buildRoot
$aprLibraries = @(
  (ConvertTo-CMakePath (Join-Path $dependencyStageRootResolved "lib\libapr-1.lib")),
  (ConvertTo-CMakePath (Join-Path $dependencyStageRootResolved "lib\libaprutil-1.lib")),
  (ConvertTo-CMakePath (Join-Path $dependencyStageRootResolved "lib\libapriconv-1.lib"))
) -join ";"
$pcreCFlags = "-DHAVE_PCRE2 -DPCRE2_STATIC"
$extraCompileFlags = "/DNETIOAPI_API_=WINAPI /DIF_NAMESIZE=256 /utf-8"

$cmakeCommand = @(
  "cmake",
  "-S $(Quote-CmdArgument $httpdRootCMake)",
  "-B $(Quote-CmdArgument $buildRootCMake)",
  '-G "Visual Studio 17 2022"',
  "-A $Arch",
  "-DCMAKE_INSTALL_PREFIX=$(Quote-CmdArgument $stageRootCMake)",
  "-DCMAKE_PREFIX_PATH=$(Quote-CmdArgument $dependencyStageCMake)",
  "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL",
  "-DINSTALL_MANUAL=OFF",
  "-DINSTALL_PDB=OFF",
  "-DCMAKE_DISABLE_FIND_PACKAGE_LibXml2=ON",
  "-DCMAKE_DISABLE_FIND_PACKAGE_Lua51=ON",
  "-DCMAKE_DISABLE_FIND_PACKAGE_CURL=ON",
  "-DPCRE2_DIR=$(Quote-CmdArgument (ConvertTo-CMakePath (Join-Path $dependencyStageRootResolved 'lib\cmake\pcre2')))",
  "-DPCRE2_USE_STATIC_LIBS=ON",
  "-DPCRE_INCLUDE_DIR=$(Quote-CmdArgument (ConvertTo-CMakePath (Join-Path $dependencyStageRootResolved 'include')))",
  "-DPCRE_LIBRARIES=PCRE2::8BIT",
  "-DPCRE_CFLAGS=$(Quote-CmdArgument $pcreCFlags)",
  "-DAPR_INCLUDE_DIR=$(Quote-CmdArgument (ConvertTo-CMakePath (Join-Path $dependencyStageRootResolved 'include')))",
  "-DAPR_LIBRARIES=$(Quote-CmdArgument $aprLibraries)",
  "-DOPENSSL_ROOT_DIR=$(Quote-CmdArgument $dependencyStageCMake)",
  "-DOPENSSL_INCLUDE_DIR=$(Quote-CmdArgument (ConvertTo-CMakePath (Join-Path $dependencyStageRootResolved 'include')))",
  "-DOPENSSL_SSL_LIBRARY=$(Quote-CmdArgument (ConvertTo-CMakePath (Join-Path $dependencyStageRootResolved 'lib\libssl.lib')))",
  "-DOPENSSL_CRYPTO_LIBRARY=$(Quote-CmdArgument (ConvertTo-CMakePath (Join-Path $dependencyStageRootResolved 'lib\libcrypto.lib')))",
  "-DZLIB_INCLUDE_DIR=$(Quote-CmdArgument (ConvertTo-CMakePath (Join-Path $dependencyStageRootResolved 'include')))",
  "-DZLIB_LIBRARY=$(Quote-CmdArgument (ConvertTo-CMakePath (Join-Path $dependencyStageRootResolved 'lib\zlib.lib')))",
  "-DENABLE_MODULES=O",
  "-DENABLE_DAV=I",
  "-DENABLE_DAV_FS=O",
  "-DENABLE_DAV_LOCK=O",
  "-DENABLE_SSL=I",
  "-DENABLE_DEFLATE=I",
  "-DEXTRA_COMPILE_FLAGS=$(Quote-CmdArgument $extraCompileFlags)"
) -join " "

$buildCommand = "$cmakeCommand && cmake --build $(Quote-CmdArgument $buildRootCMake) --config $Configuration --target install --parallel"
Invoke-DeveloperCommand -Command $buildCommand

Assert-HttpdCMakeCache -BuildRoot $buildRoot -DependencyStageRoot $dependencyStageRootResolved
Copy-HttpdSupportRuntimes -DependencyStageRoot $dependencyStageRootResolved -StageRoot $stageRootResolved
New-ApacheHttpdStageManifest -StageRoot $stageRootResolved -SourceLockPath $lockPath -Arch $Arch -Configuration $Configuration | Out-Null
Assert-ApacheHttpdStageForDavFixture -StageRoot $stageRootResolved -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch $Arch -ExpectedConfiguration $Configuration | Out-Null
Invoke-HttpdStageProbe -StageRoot $stageRootResolved

Write-Host "Built Apache HTTP Server $version with configuration $Configuration for $Arch."
Write-Host "Staged Apache HTTP Server DAV fixture substrate to $stageRootResolved."

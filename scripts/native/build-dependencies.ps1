[CmdletBinding()]
param(
  [ValidateSet("sqlite-amalgamation", "zlib", "expat", "pcre2", "openssl", "apr-layout", "apr-stack", "serf", "all")]
  [string[]]$Only = @("sqlite-amalgamation"),

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

if (-not $VsDevCmd) {
  throw "VsDevCmd is required."
}

if (-not $CacheRoot) {
  $CacheRoot = Join-Path $repoRoot ".cache\native\sources"
}
if (-not $WorkRoot) {
  $WorkRoot = Join-Path $repoRoot ".cache\native\work\deps"
}
if (-not $StageRoot) {
  $StageRoot = Join-Path $repoRoot ".cache\native\stage\subversion-deps-win-x64"
}

$lockPath = Join-Path $repoRoot "native\sources.lock.json"
$lock = Read-NativeSourceLock -Path $lockPath

function Quote-CmdArgument([string]$Value) {
  return '"' + $Value.Replace('"', '\"') + '"'
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

function Expand-NativeArchive([string]$ArchivePath, [string]$DestinationPath) {
  New-Item -ItemType Directory -Force -Path $DestinationPath | Out-Null

  if ($ArchivePath.EndsWith(".zip", [StringComparison]::OrdinalIgnoreCase)) {
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $DestinationPath -Force
    return
  }

  if ($ArchivePath.EndsWith(".tar.gz", [StringComparison]::OrdinalIgnoreCase)) {
    $tar = Get-Command tar -ErrorAction Stop
    & $tar.Source -xzf $ArchivePath -C $DestinationPath
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to extract $ArchivePath."
    }
    return
  }

  throw "Unsupported native archive type: $ArchivePath"
}

function Invoke-DeveloperCommand([string]$Command, [switch]$EnableDelayedExpansion) {
  Assert-RequiredFile $VsDevCmd "Visual Studio developer command"

  $quotedVsDevCmd = Quote-CmdArgument $VsDevCmd
  if ($EnableDelayedExpansion) {
    $cmd = "setlocal EnableDelayedExpansion && call $quotedVsDevCmd -arch=$Arch -host_arch=$Arch && $Command"
    cmd.exe /v:on /d /s /c $cmd
  }
  else {
    $cmd = "call $quotedVsDevCmd -arch=$Arch -host_arch=$Arch && $Command"
    cmd.exe /d /s /c $cmd
  }

  if ($LASTEXITCODE -ne 0) {
    throw "Developer command failed with exit code $LASTEXITCODE."
  }
}

function Build-SqliteAmalgamation {
  $source = Get-NativeSourceEntry -Lock $lock -Name "sqlite-amalgamation"
  $archivePath = Get-NativeArchivePath -CacheRoot $CacheRoot -Source $source -RequireExisting
  $extractRoot = Join-Path $WorkRoot "sqlite"
  Expand-NativeArchive -ArchivePath $archivePath -DestinationPath $extractRoot

  $sqliteRoot = Resolve-SqliteAmalgamationRoot -SearchRoot $extractRoot
  $stageRootResolved = New-NativeStageLayout -Path $StageRoot
  $objectRoot = Join-Path $WorkRoot "obj\sqlite"
  New-Item -ItemType Directory -Force -Path $objectRoot | Out-Null

  $sqliteC = Join-Path $sqliteRoot "sqlite3.c"
  $sqliteObj = Join-Path $objectRoot "sqlite3.obj"
  $sqliteLib = Join-Path $stageRootResolved "lib\sqlite3.lib"

  $compileCommand = "cl /nologo /c /O2 /MD /DSQLITE_THREADSAFE=1 /DSQLITE_OMIT_LOAD_EXTENSION /Fo$(Quote-CmdArgument $sqliteObj) $(Quote-CmdArgument $sqliteC) && lib /NOLOGO /OUT:$(Quote-CmdArgument $sqliteLib) $(Quote-CmdArgument $sqliteObj)"
  Invoke-DeveloperCommand -Command $compileCommand

  Copy-Item -LiteralPath (Join-Path $sqliteRoot "sqlite3.h") -Destination (Join-Path $stageRootResolved "include\sqlite3.h") -Force
  Copy-Item -LiteralPath (Join-Path $sqliteRoot "sqlite3ext.h") -Destination (Join-Path $stageRootResolved "include\sqlite3ext.h") -Force
  Write-Host "Staged sqlite-amalgamation to $stageRootResolved"
}

function Build-Zlib {
  $source = Get-NativeSourceEntry -Lock $lock -Name "zlib"
  $version = Get-RequiredProperty -Object $source -Name "version"
  $archivePath = Get-NativeArchivePath -CacheRoot $CacheRoot -Source $source -RequireExisting
  $extractRoot = Join-Path $WorkRoot "zlib"
  Expand-NativeArchive -ArchivePath $archivePath -DestinationPath $extractRoot

  $zlibRoot = Join-Path $extractRoot "zlib-$version"
  $makefilePath = Join-Path $zlibRoot "win32\Makefile.msc"
  Assert-RequiredFile $makefilePath "zlib Windows makefile"

  $stageRootResolved = New-NativeStageLayout -Path $StageRoot
  $buildCommand = "cd /d $(Quote-CmdArgument $zlibRoot) && nmake /nologo -f win32\Makefile.msc"
  Invoke-DeveloperCommand -Command $buildCommand

  Copy-Item -LiteralPath (Join-Path $zlibRoot "zlib.h") -Destination (Join-Path $stageRootResolved "include\zlib.h") -Force
  Copy-Item -LiteralPath (Join-Path $zlibRoot "zconf.h") -Destination (Join-Path $stageRootResolved "include\zconf.h") -Force
  Copy-Item -LiteralPath (Join-Path $zlibRoot "zlib.lib") -Destination (Join-Path $stageRootResolved "lib\zlib.lib") -Force
  Assert-ZlibStageForSubversion -StageRoot $stageRootResolved | Out-Null
  Write-Host "Staged zlib to $stageRootResolved"
}

function Build-Expat {
  $source = Get-NativeSourceEntry -Lock $lock -Name "expat"
  $version = Get-RequiredProperty -Object $source -Name "version"
  $archivePath = Get-NativeArchivePath -CacheRoot $CacheRoot -Source $source -RequireExisting
  $extractRoot = Join-Path $WorkRoot "expat"
  Expand-NativeArchive -ArchivePath $archivePath -DestinationPath $extractRoot

  $expatRoot = Join-Path $extractRoot "expat-$version"
  Assert-RequiredFile (Join-Path $expatRoot "CMakeLists.txt") "Expat CMake project"

  $stageRootResolved = New-NativeStageLayout -Path $StageRoot
  $buildRoot = Join-Path $WorkRoot "build\expat-shared"
  $cmakeCommand = "cmake -S $(Quote-CmdArgument $expatRoot) -B $(Quote-CmdArgument $buildRoot) -G `"Visual Studio 17 2022`" -A $Arch -DCMAKE_INSTALL_PREFIX=$(Quote-CmdArgument $stageRootResolved) -DCMAKE_C_FLAGS=/utf-8 -DEXPAT_SHARED_LIBS=ON -DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_EXAMPLES=OFF -DEXPAT_BUILD_TESTS=OFF -DEXPAT_BUILD_DOCS=OFF -DEXPAT_BUILD_PKGCONFIG=OFF && cmake --build $(Quote-CmdArgument $buildRoot) --config $Configuration --target install --parallel"
  Invoke-DeveloperCommand -Command $cmakeCommand

  Assert-ExpatStageForAprUtil -StageRoot $stageRootResolved | Out-Null
  Write-Host "Staged Expat to $stageRootResolved"
}

function Invoke-Pcre2RawLinkProbe {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot
  )

  $stageRootResolved = Assert-Pcre2StageForHttpd -StageRoot $StageRoot
  $probeRoot = Join-Path $WorkRoot "probe\pcre2-raw"
  New-Item -ItemType Directory -Force -Path $probeRoot | Out-Null
  $probeSource = Join-Path $probeRoot "pcre2_raw_link_probe.c"
  $probeObject = Join-Path $probeRoot "pcre2_raw_link_probe.obj"
  $probeExe = Join-Path $probeRoot "pcre2_raw_link_probe.exe"
  @'
#define PCRE2_CODE_UNIT_WIDTH 8
#define PCRE2_STATIC
#include <string.h>
#include <pcre2.h>

int main(void) {
  int error_number = 0;
  PCRE2_SIZE error_offset = 0;
  PCRE2_SPTR pattern = (PCRE2_SPTR)"subversionr";
  PCRE2_SPTR subject = (PCRE2_SPTR)"subversionr";
  pcre2_code *code = pcre2_compile(pattern, PCRE2_ZERO_TERMINATED, 0, &error_number, &error_offset, NULL);
  if (!code) {
    return 2;
  }

  pcre2_match_data *match_data = pcre2_match_data_create_from_pattern(code, NULL);
  int result = pcre2_match(code, subject, (PCRE2_SIZE)strlen((const char *)subject), 0, 0, match_data, NULL);
  pcre2_match_data_free(match_data);
  pcre2_code_free(code);
  return result >= 0 ? 0 : 3;
}
'@ | Set-Content -LiteralPath $probeSource -Encoding ascii -NoNewline

  $includeRoot = Join-Path $stageRootResolved "include"
  $libRoot = Join-Path $stageRootResolved "lib"
  $compileCommand = "cl /nologo /MD /I$(Quote-CmdArgument $includeRoot) /Fo$(Quote-CmdArgument $probeObject) /Fe$(Quote-CmdArgument $probeExe) $(Quote-CmdArgument $probeSource) /link /LIBPATH:$(Quote-CmdArgument $libRoot) pcre2-8-static.lib"
  Invoke-DeveloperCommand -Command $compileCommand
  Invoke-DeveloperCommand -Command (Quote-CmdArgument $probeExe)
  Write-Host "Verified PCRE2 raw MSVC static link probe."
}

function Invoke-Pcre2CMakeConsumerProbe {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot
  )

  $stageRootResolved = Assert-Pcre2StageForHttpd -StageRoot $StageRoot
  $probeRoot = Join-Path $WorkRoot "probe\pcre2-cmake-consumer"
  $probeBuildRoot = Join-Path $WorkRoot "probe-build\pcre2-cmake-consumer"
  New-Item -ItemType Directory -Force -Path $probeRoot | Out-Null

  $probeCMakeLists = Join-Path $probeRoot "CMakeLists.txt"
  @'
cmake_minimum_required(VERSION 3.21)
project(SubversionRPcre2ConsumerProbe C)

set(PCRE2_USE_STATIC_LIBS ON)
find_package(PCRE2 CONFIG REQUIRED COMPONENTS 8BIT)

get_target_property(_pcre2_8_aliased PCRE2::8BIT ALIASED_TARGET)
if(_pcre2_8_aliased)
  set(_pcre2_8_target "${_pcre2_8_aliased}")
else()
  set(_pcre2_8_target PCRE2::8BIT)
endif()
get_target_property(_pcre2_8_defs "${_pcre2_8_target}" INTERFACE_COMPILE_DEFINITIONS)
if(NOT _pcre2_8_defs)
  set(_pcre2_8_defs "")
endif()
if(NOT "PCRE2_STATIC" IN_LIST _pcre2_8_defs)
  message(FATAL_ERROR "PCRE2::8BIT must propagate PCRE2_STATIC for static Windows consumers.")
endif()

add_executable(pcre2_consumer_probe pcre2_consumer_probe.c)
target_link_libraries(pcre2_consumer_probe PRIVATE PCRE2::8BIT)
'@ | Set-Content -LiteralPath $probeCMakeLists -Encoding ascii -NoNewline

  $probeSource = Join-Path $probeRoot "pcre2_consumer_probe.c"
  @'
#define PCRE2_CODE_UNIT_WIDTH 8
#include <string.h>
#include <pcre2.h>

int main(void) {
  int error_number = 0;
  PCRE2_SIZE error_offset = 0;
  PCRE2_SPTR pattern = (PCRE2_SPTR)"subversionr";
  PCRE2_SPTR subject = (PCRE2_SPTR)"subversionr";
  pcre2_code *code = pcre2_compile(pattern, PCRE2_ZERO_TERMINATED, 0, &error_number, &error_offset, NULL);
  if (!code) {
    return 2;
  }

  pcre2_match_data *match_data = pcre2_match_data_create_from_pattern(code, NULL);
  int result = pcre2_match(code, subject, (PCRE2_SIZE)strlen((const char *)subject), 0, 0, match_data, NULL);
  pcre2_match_data_free(match_data);
  pcre2_code_free(code);
  return result >= 0 ? 0 : 3;
}
'@ | Set-Content -LiteralPath $probeSource -Encoding ascii -NoNewline

  $cmakeCommand = "cmake -S $(Quote-CmdArgument $probeRoot) -B $(Quote-CmdArgument $probeBuildRoot) -G `"Visual Studio 17 2022`" -A $Arch -DCMAKE_PREFIX_PATH=$(Quote-CmdArgument $stageRootResolved) -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL && cmake --build $(Quote-CmdArgument $probeBuildRoot) --config $Configuration --parallel"
  Invoke-DeveloperCommand -Command $cmakeCommand

  $probeExe = Join-Path $probeBuildRoot "$Configuration\pcre2_consumer_probe.exe"
  Assert-RequiredFile $probeExe "PCRE2 CMake consumer probe executable"
  Invoke-DeveloperCommand -Command (Quote-CmdArgument $probeExe)
  Write-Host "Verified PCRE2 CMake package consumer probe."
}

function Build-Pcre2 {
  $source = Get-NativeSourceEntry -Lock $lock -Name "pcre2"
  $version = Get-RequiredProperty -Object $source -Name "version"
  $archivePath = Get-NativeArchivePath -CacheRoot $CacheRoot -Source $source -RequireExisting
  $extractRoot = Join-Path $WorkRoot "pcre2"
  Expand-NativeArchive -ArchivePath $archivePath -DestinationPath $extractRoot

  $pcre2Root = Join-Path $extractRoot "pcre2-$version"
  Assert-RequiredFile (Join-Path $pcre2Root "CMakeLists.txt") "PCRE2 CMake project"

  $stageRootResolved = New-NativeStageLayout -Path $StageRoot
  $buildRoot = Join-Path $WorkRoot "build\pcre2-static"
  $cmakeCommand = "cmake -S $(Quote-CmdArgument $pcre2Root) -B $(Quote-CmdArgument $buildRoot) -G `"Visual Studio 17 2022`" -A $Arch -DCMAKE_INSTALL_PREFIX=$(Quote-CmdArgument $stageRootResolved) -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DPCRE2_BUILD_PCRE2_8=ON -DPCRE2_BUILD_PCRE2_16=OFF -DPCRE2_BUILD_PCRE2_32=OFF -DPCRE2_BUILD_TESTS=OFF -DPCRE2_BUILD_PCRE2GREP=OFF -DPCRE2_SUPPORT_JIT=OFF -DPCRE2_SUPPORT_UNICODE=ON && cmake --build $(Quote-CmdArgument $buildRoot) --config $Configuration --target install --parallel"
  Invoke-DeveloperCommand -Command $cmakeCommand

  $cachePath = Join-Path $buildRoot "CMakeCache.txt"
  Assert-RequiredFile $cachePath "PCRE2 CMake cache"
  $cacheContent = Get-Content -Raw -LiteralPath $cachePath
  if (-not $cacheContent.Contains("CMAKE_MSVC_RUNTIME_LIBRARY:UNINITIALIZED=MultiThreadedDLL") -and -not $cacheContent.Contains("CMAKE_MSVC_RUNTIME_LIBRARY:STRING=MultiThreadedDLL")) {
    throw "PCRE2 CMake cache must pin CMAKE_MSVC_RUNTIME_LIBRARY to MultiThreadedDLL."
  }

  Assert-Pcre2StageForHttpd -StageRoot $stageRootResolved -ExpectedVersion $version | Out-Null
  Invoke-Pcre2RawLinkProbe -StageRoot $stageRootResolved
  Invoke-Pcre2CMakeConsumerProbe -StageRoot $stageRootResolved
  Write-Host "Staged PCRE2 to $stageRootResolved"
}

function Build-OpenSsl {
  $source = Get-NativeSourceEntry -Lock $lock -Name "openssl"
  $version = Get-RequiredProperty -Object $source -Name "version"
  $archivePath = Get-NativeArchivePath -CacheRoot $CacheRoot -Source $source -RequireExisting
  $extractRoot = Join-Path $WorkRoot "openssl"
  Expand-NativeArchive -ArchivePath $archivePath -DestinationPath $extractRoot

  $openSslRoot = Join-Path $extractRoot "openssl-$version"
  Assert-RequiredFile (Join-Path $openSslRoot "Configure") "OpenSSL Configure script"
  Assert-RequiredCommand "perl" "OpenSSL Windows build Perl"
  Assert-RequiredCommand "nasm" "OpenSSL Windows build NASM"

  $stageRootResolved = New-NativeStageLayout -Path $StageRoot
  $openSslDir = Join-Path $stageRootResolved "ssl"
  $buildCommand = "cd /d $(Quote-CmdArgument $openSslRoot) && perl Configure VC-WIN64A no-makedepend --prefix=$(Quote-CmdArgument $stageRootResolved) --openssldir=$(Quote-CmdArgument $openSslDir) && nmake /nologo && nmake /nologo install_sw"
  Invoke-DeveloperCommand -Command $buildCommand

  Assert-OpenSslStageForSerf -StageRoot $stageRootResolved -ExpectedVersion $version | Out-Null
  Write-Host "Staged OpenSSL to $stageRootResolved"
}

function Prepare-AprLayout {
  $layoutRoot = Join-Path $WorkRoot "apr-layout"
  $rawRoot = Join-Path $layoutRoot "raw"
  New-Item -ItemType Directory -Force -Path $rawRoot | Out-Null

  foreach ($dependency in @(
    @{ Name = "apr"; Directory = "apr-1.7.6"; Target = "apr" },
    @{ Name = "apr-util"; Directory = "apr-util-1.6.3"; Target = "apr-util" },
    @{ Name = "apr-iconv"; Directory = "apr-iconv-1.2.2"; Target = "apr-iconv" }
  )) {
    $source = Get-NativeSourceEntry -Lock $lock -Name $dependency.Name
    $archivePath = Get-NativeArchivePath -CacheRoot $CacheRoot -Source $source -RequireExisting
    Expand-NativeArchive -ArchivePath $archivePath -DestinationPath $rawRoot

    $sourceDirectory = Join-Path $rawRoot $dependency.Directory
    if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
      throw "Expected APR source directory is missing: $sourceDirectory"
    }

    $targetDirectory = Join-Path $layoutRoot $dependency.Target
    if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
      Copy-Item -LiteralPath $sourceDirectory -Destination $targetDirectory -Recurse
    }
  }

  Write-Host "Prepared APR parallel source layout at $layoutRoot"
}

function Remove-AprGeneratedFile([string]$LayoutRoot, [string]$RelativePath) {
  $layoutRootResolved = (Resolve-Path -LiteralPath $LayoutRoot -ErrorAction Stop).Path
  $targetPath = Join-Path $layoutRootResolved $RelativePath
  if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
    return
  }

  $targetResolved = (Resolve-Path -LiteralPath $targetPath -ErrorAction Stop).Path
  if (-not $targetResolved.StartsWith($layoutRootResolved, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove generated APR file outside layout root: $targetResolved"
  }

  Remove-Item -LiteralPath $targetResolved -Force
}

function Copy-AprPrivateHeadersForHttpd {
  param(
    [Parameter(Mandatory = $true)]
    [string]$LayoutRoot,

    [Parameter(Mandatory = $true)]
    [string]$StageRoot
  )

  $layoutRootResolved = (Resolve-Path -LiteralPath $LayoutRoot -ErrorAction Stop).Path
  $stageRootResolved = (Resolve-Path -LiteralPath $StageRoot -ErrorAction Stop).Path
  foreach ($privateHeader in @(
    @{ Source = "apr\include\arch\win32\apr_arch_file_io.h"; Destination = "include\arch\win32\apr_arch_file_io.h" },
    @{ Source = "apr\include\arch\win32\apr_arch_misc.h"; Destination = "include\arch\win32\apr_arch_misc.h" },
    @{ Source = "apr\include\arch\win32\apr_arch_utf8.h"; Destination = "include\arch\win32\apr_arch_utf8.h" },
    @{ Source = "apr\include\arch\win32\apr_private.h"; Destination = "include\arch\win32\apr_private.h" },
    @{ Source = "apr\include\arch\apr_private_common.h"; Destination = "include\arch\apr_private_common.h" }
  )) {
    $sourcePath = Join-Path $layoutRootResolved $privateHeader.Source
    Assert-RequiredFile $sourcePath "APR private header required by Apache HTTP Server"
    $destinationPath = Join-Path $stageRootResolved $privateHeader.Destination
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destinationPath) | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
  }
}

function Build-AprStack {
  Prepare-AprLayout

  $layoutRoot = Join-Path $WorkRoot "apr-layout"
  $aprUtilRoot = Join-Path $layoutRoot "apr-util"
  Assert-RequiredFile (Join-Path $aprUtilRoot "Makefile.win") "APR-util Windows makefile"

  $stageRootResolved = New-NativeStageLayout -Path $StageRoot
  Assert-ExpatStageForAprUtil -StageRoot $stageRootResolved | Out-Null

  Remove-AprGeneratedFile -LayoutRoot $layoutRoot -RelativePath "apr\include\apr_escape_test_char.h"

  $stageInclude = Join-Path $stageRootResolved "include"
  $stageLib = Join-Path $stageRootResolved "lib"
  $aprArch = "$Arch $Configuration"
  $clFlags = "/DNETIOAPI_API_=WINAPI /DIF_NAMESIZE=256 /utf-8"
  $aprCommand = "set `"INCLUDE=$stageInclude;!INCLUDE!`" && set `"LIB=$stageLib;!LIB!`" && set `"CL=$clFlags`" && cd /d $(Quote-CmdArgument $aprUtilRoot) && nmake /nologo -f Makefile.win PREFIX=$(Quote-CmdArgument $stageRootResolved) USEMAK=1 ARCH=`"$aprArch`" XML_PARSER=libexpat buildall install"
  Invoke-DeveloperCommand -Command $aprCommand -EnableDelayedExpansion

  Copy-Item -LiteralPath (Join-Path $layoutRoot "apr-iconv\include\apr_iconv.h") -Destination (Join-Path $stageRootResolved "include\apr_iconv.h") -Force
  Copy-Item -LiteralPath (Join-Path $layoutRoot "apr-iconv\$Arch\$Configuration\libapriconv-1.lib") -Destination (Join-Path $stageRootResolved "lib\libapriconv-1.lib") -Force
  Copy-AprPrivateHeadersForHttpd -LayoutRoot $layoutRoot -StageRoot $stageRootResolved

  Assert-AprStageForSubversion -StageRoot $stageRootResolved | Out-Null
  Assert-AprPrivateHeadersForHttpd -StageRoot $stageRootResolved | Out-Null
  Write-Host "Staged APR stack to $stageRootResolved"
}

function Invoke-SerfOpenSslLinkProbe {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot
  )

  $stageRootResolved = (Resolve-Path -LiteralPath $StageRoot -ErrorAction Stop).Path
  Assert-AprStageForSubversion -StageRoot $stageRootResolved | Out-Null
  Assert-ZlibStageForSubversion -StageRoot $stageRootResolved | Out-Null
  Assert-OpenSslStageForSerf -StageRoot $stageRootResolved | Out-Null
  Assert-SerfStageForSubversion -StageRoot $stageRootResolved | Out-Null

  $probeRoot = Join-Path $WorkRoot "probe\serf-openssl"
  New-Item -ItemType Directory -Force -Path $probeRoot | Out-Null
  $probeSource = Join-Path $probeRoot "serf_openssl_link_probe.c"
  $probeObject = Join-Path $probeRoot "serf_openssl_link_probe.obj"
  $probeExe = Join-Path $probeRoot "serf_openssl_link_probe.exe"
  @'
#include <stdio.h>
#include <serf.h>
#include <openssl/crypto.h>

int main(void) {
  const char *serf_error = serf_error_string(SERF_ERROR_BAD_HTTP_RESPONSE);
  const char *openssl_version = OpenSSL_version(OPENSSL_VERSION);
  if (!serf_error || !openssl_version) {
    return 2;
  }
  puts(serf_error);
  puts(openssl_version);
  return 0;
}
'@ | Set-Content -LiteralPath $probeSource -Encoding ascii -NoNewline

  $includeRoot = Join-Path $stageRootResolved "include"
  $serfIncludeRoot = Join-Path $stageRootResolved "include\serf-1"
  $libRoot = Join-Path $stageRootResolved "lib"
  $binRoot = Join-Path $stageRootResolved "bin"
  $compileCommand = "cl /nologo /MD /I$(Quote-CmdArgument $includeRoot) /I$(Quote-CmdArgument $serfIncludeRoot) /Fo$(Quote-CmdArgument $probeObject) /Fe$(Quote-CmdArgument $probeExe) $(Quote-CmdArgument $probeSource) /link /LIBPATH:$(Quote-CmdArgument $libRoot) libserf-1.lib libssl.lib libcrypto.lib libapr-1.lib libaprutil-1.lib zlib.lib ws2_32.lib crypt32.lib advapi32.lib gdi32.lib user32.lib shell32.lib"
  Invoke-DeveloperCommand -Command $compileCommand

  $runCommand = "set `"PATH=$binRoot;%PATH%`" && $(Quote-CmdArgument $probeExe)"
  Invoke-DeveloperCommand -Command $runCommand
  Write-Host "Verified Serf/OpenSSL mutual link probe."
}

function Build-Serf {
  $source = Get-NativeSourceEntry -Lock $lock -Name "serf"
  $version = Get-RequiredProperty -Object $source -Name "version"
  $archivePath = Get-NativeArchivePath -CacheRoot $CacheRoot -Source $source -RequireExisting
  $extractRoot = Join-Path $WorkRoot "serf"
  Expand-NativeArchive -ArchivePath $archivePath -DestinationPath $extractRoot

  $serfRoot = Join-Path $extractRoot "serf-$version"
  Assert-RequiredFile (Join-Path $serfRoot "SConstruct") "Serf SCons project"
  Assert-RequiredCommand "uv" "Serf SCons Python runner"

  $stageRootResolved = New-NativeStageLayout -Path $StageRoot
  Assert-AprStageForSubversion -StageRoot $stageRootResolved | Out-Null
  Assert-ZlibStageForSubversion -StageRoot $stageRootResolved | Out-Null
  Assert-OpenSslStageForSerf -StageRoot $stageRootResolved | Out-Null

  $stageLib = Join-Path $stageRootResolved "lib"
  $sconsCommand = "set `"PYTHONIOENCODING=utf-8`" && cd /d $(Quote-CmdArgument $serfRoot) && uv run --no-project --with scons==4.9.1 scons TARGET_ARCH=x86_64 MSVC_VERSION=14.3 PREFIX=$(Quote-CmdArgument $stageRootResolved) LIBDIR=$(Quote-CmdArgument $stageLib) APR=$(Quote-CmdArgument $stageRootResolved) APU=$(Quote-CmdArgument $stageRootResolved) ZLIB=$(Quote-CmdArgument $stageRootResolved) OPENSSL=$(Quote-CmdArgument $stageRootResolved) LINKFLAGS=/LIBPATH:$(Quote-CmdArgument $stageLib) install"
  Invoke-DeveloperCommand -Command $sconsCommand

  $installedSerfRuntime = Join-Path $stageLib "libserf-1.dll"
  $stagedSerfRuntime = Join-Path $stageRootResolved "bin\libserf-1.dll"
  if ((Test-Path -LiteralPath $installedSerfRuntime -PathType Leaf) -and -not (Test-Path -LiteralPath $stagedSerfRuntime -PathType Leaf)) {
    Copy-Item -LiteralPath $installedSerfRuntime -Destination $stagedSerfRuntime -Force
  }

  Assert-SerfStageForSubversion -StageRoot $stageRootResolved -ExpectedVersion $version | Out-Null
  Invoke-SerfOpenSslLinkProbe -StageRoot $stageRootResolved
  Write-Host "Staged Serf to $stageRootResolved"
}

if (-not $SkipVerifySources) {
  & (Join-Path $PSScriptRoot "verify-sources.ps1")
}

$selectedTargets = @($Only)
if ($selectedTargets -contains "all") {
  $selectedTargets = @("sqlite-amalgamation", "zlib", "expat", "pcre2", "openssl", "apr-stack", "serf")
}

Clear-NativeGeneratedDirectory -Path $WorkRoot -WorkspaceRoot $repoRoot -Description "native dependency work root" | Out-Null
if ($selectedTargets | Where-Object { $_ -ne "apr-layout" }) {
  Clear-NativeGeneratedDirectory -Path $StageRoot -WorkspaceRoot $repoRoot -Description "native dependency stage root" | Out-Null
}

foreach ($target in $selectedTargets) {
  switch ($target) {
    "sqlite-amalgamation" { Build-SqliteAmalgamation }
    "zlib" { Build-Zlib }
    "expat" { Build-Expat }
    "pcre2" { Build-Pcre2 }
    "openssl" { Build-OpenSsl }
    "apr-layout" { Prepare-AprLayout }
    "apr-stack" { Build-AprStack }
    "serf" { Build-Serf }
    default { throw "Unsupported dependency build target: $target" }
  }
}

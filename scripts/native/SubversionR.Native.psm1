Set-StrictMode -Version Latest

function Get-RequiredProperty {
  param(
    [Parameter(Mandatory = $true)]
    $Object,

    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or -not $property.Value) {
    throw "Missing required property '$Name'."
  }

  return $property.Value
}

function Read-NativeSourceLock {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Missing native source lock file: $Path"
  }

  $lock = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
  if (-not $lock.sources -or $lock.sources.Count -eq 0) {
    throw "Native source lock must contain at least one source entry."
  }

  return $lock
}

function Get-NativeSourceEntry {
  param(
    [Parameter(Mandatory = $true)]
    $Lock,

    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  foreach ($source in $Lock.sources) {
    $sourceName = Get-RequiredProperty -Object $source -Name "name"
    if ($sourceName -eq $Name) {
      return $source
    }
  }

  throw "Native source '$Name' is not present in native/sources.lock.json."
}

function Get-NativeArchivePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$CacheRoot,

    [Parameter(Mandatory = $true)]
    $Source,

    [switch]$RequireExisting
  )

  $url = Get-RequiredProperty -Object $Source -Name "url"
  $archivePath = Join-Path $CacheRoot ([IO.Path]::GetFileName([Uri]$url))
  if ($RequireExisting -and -not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    throw "Required native source archive is missing: $archivePath"
  }

  return $archivePath
}

function Assert-NativeArchiveChecksum {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,

    [Parameter(Mandatory = $true)]
    $Source
  )

  if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
    throw "Native source archive is missing: $ArchivePath"
  }

  $name = Get-RequiredProperty -Object $Source -Name "name"
  $expectedSha512 = Get-RequiredProperty -Object $Source -Name "sha512"
  $actualSha512 = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA512).Hash.ToLowerInvariant()
  if ($actualSha512 -ne $expectedSha512.ToLowerInvariant()) {
    throw "SHA512 mismatch for $ArchivePath. Expected $expectedSha512, got $actualSha512."
  }

  $sha256Property = $Source.PSObject.Properties["sha256"]
  if ($null -ne $sha256Property) {
    if (-not $sha256Property.Value) {
      throw "Source entry $name has empty sha256 field."
    }

    $expectedSha256 = [string]$sha256Property.Value
    $actualSha256 = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $expectedSha256.ToLowerInvariant()) {
      throw "SHA256 mismatch for $ArchivePath. Expected $expectedSha256, got $actualSha256."
    }
  }

  return $ArchivePath
}

function New-NativeStageLayout {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $stageRoot = New-Item -ItemType Directory -Force -Path $Path
  foreach ($child in @("include", "lib", "bin")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $stageRoot.FullName $child) | Out-Null
  }

  return $stageRoot.FullName
}

function Test-NativePathWithinRoot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string]$Root
  )

  $absolutePath = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  $absoluteRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)

  return $absolutePath.StartsWith($absoluteRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Clear-NativeGeneratedDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [Parameter(Mandatory = $true)]
    [string]$Description
  )

  $absolutePath = [IO.Path]::GetFullPath($Path)
  $workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
  $allowedRoots = @(
    (Join-Path $workspace ".cache"),
    (Join-Path $workspace "target")
  )

  $isAllowed = $false
  foreach ($allowedRoot in $allowedRoots) {
    if (Test-NativePathWithinRoot -Path $absolutePath -Root $allowedRoot) {
      $isAllowed = $true
      break
    }
  }

  if (-not $isAllowed) {
    throw "Refusing to remove generated $Description outside repository generated roots: $absolutePath"
  }

  if (Test-Path -LiteralPath $absolutePath -PathType Leaf) {
    throw "Generated $Description path is a file, not a directory: $absolutePath"
  }

  if (Test-Path -LiteralPath $absolutePath -PathType Container) {
    Remove-Item -LiteralPath $absolutePath -Recurse -Force
  }

  return (New-Item -ItemType Directory -Force -Path $absolutePath).FullName
}

function Test-NativePathUnderCacheRoot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot
  )

  $workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
  return (Test-NativePathWithinRoot -Path ([IO.Path]::GetFullPath($Path)) -Root (Join-Path $workspace ".cache"))
}

function Assert-NativeIndependentDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Candidate,

    [Parameter(Mandatory = $true)]
    [string]$ExistingRoot,

    [Parameter(Mandatory = $true)]
    [string]$CandidateName,

    [Parameter(Mandatory = $true)]
    [string]$ExistingName
  )

  $candidateResolved = [IO.Path]::GetFullPath($Candidate).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  $existingResolved = [IO.Path]::GetFullPath($ExistingRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  if ([string]::Equals($candidateResolved, $existingResolved, [StringComparison]::OrdinalIgnoreCase) -or
      (Test-NativePathWithinRoot -Path $candidateResolved -Root $existingResolved) -or
      (Test-NativePathWithinRoot -Path $existingResolved -Root $candidateResolved)) {
    throw "$CandidateName must be independent from $ExistingName`: $candidateResolved"
  }

  return $candidateResolved
}

function Resolve-SqliteAmalgamationRoot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SearchRoot
  )

  if (-not (Test-Path -LiteralPath $SearchRoot -PathType Container)) {
    throw "SQLite search root is missing: $SearchRoot"
  }

  $candidates = @(Get-ChildItem -LiteralPath $SearchRoot -Directory -Recurse | Where-Object {
    (Test-Path -LiteralPath (Join-Path $_.FullName "sqlite3.c") -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $_.FullName "sqlite3.h") -PathType Leaf)
  })

  if ($candidates.Count -ne 1) {
    throw "Expected exactly one SQLite amalgamation root under $SearchRoot; found $($candidates.Count)."
  }

  return $candidates[0].FullName
}

function Assert-ZlibStageForSubversion {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot
  )

  if (-not (Test-Path -LiteralPath $StageRoot -PathType Container)) {
    throw "Zlib stage root is missing: $StageRoot"
  }

  foreach ($header in @("zlib.h", "zconf.h")) {
    $headerPath = Join-Path $StageRoot "include\$header"
    if (-not (Test-Path -LiteralPath $headerPath -PathType Leaf)) {
      throw "Zlib stage for Subversion is missing required header: $headerPath"
    }
  }

  $acceptedLibraryNames = @("zlibstatic.lib", "zlibstat.lib", "zlib.lib")
  foreach ($libraryName in $acceptedLibraryNames) {
    $libraryPath = Join-Path $StageRoot "lib\$libraryName"
    if (Test-Path -LiteralPath $libraryPath -PathType Leaf) {
      return $libraryPath
    }
  }

  throw "Zlib stage for Subversion must contain one of: lib\zlibstatic.lib, lib\zlibstat.lib, lib\zlib.lib."
}

function Assert-ExpatStageForAprUtil {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot
  )

  if (-not (Test-Path -LiteralPath $StageRoot -PathType Container)) {
    throw "Expat stage root is missing: $StageRoot"
  }

  foreach ($requiredFile in @(
    "include\expat.h",
    "include\expat_external.h",
    "lib\libexpat.lib",
    "bin\libexpat.dll"
  )) {
    $filePath = Join-Path $StageRoot $requiredFile
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
      throw "Expat stage for APR-util is missing required file: $filePath"
    }
  }

  return (Join-Path $StageRoot "lib\libexpat.lib")
}

function Assert-SqliteStageForSubversion {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot
  )

  if (-not (Test-Path -LiteralPath $StageRoot -PathType Container)) {
    throw "SQLite stage root is missing: $StageRoot"
  }

  foreach ($requiredFile in @(
    "include\sqlite3.h",
    "lib\sqlite3.lib"
  )) {
    $filePath = Join-Path $StageRoot $requiredFile
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
      throw "SQLite stage for Subversion is missing required file: $filePath"
    }
  }

  return $StageRoot
}

function Assert-AprStageForSubversion {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot
  )

  if (-not (Test-Path -LiteralPath $StageRoot -PathType Container)) {
    throw "APR stage root is missing: $StageRoot"
  }

  foreach ($requiredFile in @(
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
    $filePath = Join-Path $StageRoot $requiredFile
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
      throw "APR stage for Subversion is missing required file: $filePath"
    }
  }

  return $StageRoot
}

function Assert-AprPrivateHeadersForHttpd {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot
  )

  $stageRootResolved = Assert-AprStageForSubversion -StageRoot $StageRoot
  foreach ($requiredFile in @(
    "include\arch\win32\apr_arch_file_io.h",
    "include\arch\win32\apr_arch_misc.h",
    "include\arch\win32\apr_arch_utf8.h",
    "include\arch\win32\apr_private.h",
    "include\arch\apr_private_common.h"
  )) {
    $filePath = Join-Path $stageRootResolved $requiredFile
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
      throw "APR stage for Apache HTTP Server is missing required private header: $filePath"
    }
  }

  return $stageRootResolved
}

function Get-OpenSslVersionFromHeader {
  param(
    [Parameter(Mandatory = $true)]
    [string]$HeaderPath
  )

  if (-not (Test-Path -LiteralPath $HeaderPath -PathType Leaf)) {
    throw "OpenSSL version header is missing: $HeaderPath"
  }

  $content = Get-Content -Raw -LiteralPath $HeaderPath
  $textMatch = [regex]::Match($content, '(?m)^\s*#\s*define\s+OPENSSL_VERSION_TEXT\s+"OpenSSL\s+(?<version>\d+\.\d+\.\d+)\b')
  if ($textMatch.Success) {
    return $textMatch.Groups["version"].Value
  }

  $strMatch = [regex]::Match($content, '(?m)^\s*#\s*define\s+OPENSSL_VERSION_STR\s+"(?<version>\d+\.\d+\.\d+)"')
  if ($strMatch.Success) {
    return $strMatch.Groups["version"].Value
  }

  throw "OpenSSL version header does not define OPENSSL_VERSION_TEXT or OPENSSL_VERSION_STR: $HeaderPath"
}

function Assert-OpenSslStageForSerf {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot,

    [string]$ExpectedVersion
  )

  if (-not (Test-Path -LiteralPath $StageRoot -PathType Container)) {
    throw "OpenSSL stage root is missing: $StageRoot"
  }

  foreach ($requiredFile in @(
    "include\openssl\opensslv.h",
    "include\openssl\ssl.h",
    "include\openssl\crypto.h",
    "lib\libssl.lib",
    "lib\libcrypto.lib"
  )) {
    $filePath = Join-Path $StageRoot $requiredFile
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
      throw "OpenSSL stage for Serf is missing required file: $filePath"
    }
  }

  foreach ($runtimePattern in @("libssl-*.dll", "libcrypto-*.dll")) {
    $runtime = Get-ChildItem -LiteralPath (Join-Path $StageRoot "bin") -File -Filter $runtimePattern | Select-Object -First 1
    if (-not $runtime) {
      throw "OpenSSL stage for Serf is missing required runtime matching bin\$runtimePattern."
    }
  }

  $version = Get-OpenSslVersionFromHeader -HeaderPath (Join-Path $StageRoot "include\openssl\opensslv.h")
  if ($ExpectedVersion -and $version -ne $ExpectedVersion) {
    throw "OpenSSL stage version must be $ExpectedVersion; got $version."
  }

  return $StageRoot
}

function Get-SerfVersionFromHeader {
  param(
    [Parameter(Mandatory = $true)]
    [string]$HeaderPath
  )

  if (-not (Test-Path -LiteralPath $HeaderPath -PathType Leaf)) {
    throw "Serf version header is missing: $HeaderPath"
  }

  $content = Get-Content -Raw -LiteralPath $HeaderPath
  $parts = @()
  foreach ($macro in @("SERF_MAJOR_VERSION", "SERF_MINOR_VERSION", "SERF_PATCH_VERSION")) {
    $match = [regex]::Match($content, "(?m)^\s*#\s*define\s+$macro\s+(?<value>\d+)\b")
    if (-not $match.Success) {
      throw "Serf version header does not define $macro`: $HeaderPath"
    }
    $parts += $match.Groups["value"].Value
  }

  return ($parts -join ".")
}

function Assert-SerfStageForSubversion {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot,

    [string]$ExpectedVersion
  )

  if (-not (Test-Path -LiteralPath $StageRoot -PathType Container)) {
    throw "Serf stage root is missing: $StageRoot"
  }

  foreach ($requiredFile in @(
    "include\serf-1\serf.h",
    "include\serf-1\serf_bucket_types.h",
    "include\serf-1\serf_bucket_util.h",
    "lib\serf-1.lib",
    "lib\libserf-1.lib",
    "bin\libserf-1.dll"
  )) {
    $filePath = Join-Path $StageRoot $requiredFile
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
      throw "Serf stage for Subversion is missing required file: $filePath"
    }
  }

  $version = Get-SerfVersionFromHeader -HeaderPath (Join-Path $StageRoot "include\serf-1\serf.h")
  if ($ExpectedVersion -and $version -ne $ExpectedVersion) {
    throw "Serf stage version must be $ExpectedVersion; got $version."
  }

  return $StageRoot
}

function Get-Pcre2VersionFromHeader {
  param(
    [Parameter(Mandatory = $true)]
    [string]$HeaderPath
  )

  if (-not (Test-Path -LiteralPath $HeaderPath -PathType Leaf)) {
    throw "PCRE2 version header is missing: $HeaderPath"
  }

  $content = Get-Content -Raw -LiteralPath $HeaderPath
  $parts = @()
  foreach ($macro in @("PCRE2_MAJOR", "PCRE2_MINOR")) {
    $match = [regex]::Match($content, "(?m)^[ \t]*#[ \t]*define[ \t]+$macro[ \t]+(?<value>\d+)\b")
    if (-not $match.Success) {
      throw "PCRE2 version header does not define $macro`: $HeaderPath"
    }
    $parts += $match.Groups["value"].Value
  }

  $prereleaseMatch = [regex]::Match($content, "(?m)^[ \t]*#[ \t]*define[ \t]+PCRE2_PRERELEASE[ \t]*(?<value>[^\r\n]*)")
  if (-not $prereleaseMatch.Success) {
    throw "PCRE2 version header does not define PCRE2_PRERELEASE: $HeaderPath"
  }
  $prereleaseValue = $prereleaseMatch.Groups["value"].Value.Trim()
  if ($prereleaseValue -eq '""') {
    $prereleaseValue = ""
  }
  if ($prereleaseValue.Length -ne 0) {
    throw "PCRE2 version header must not report a prerelease build: $HeaderPath"
  }

  return ($parts -join ".")
}

function Assert-Pcre2StageForHttpd {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot,

    [string]$ExpectedVersion
  )

  if (-not (Test-Path -LiteralPath $StageRoot -PathType Container)) {
    throw "PCRE2 stage root is missing: $StageRoot"
  }

  foreach ($requiredFile in @(
    "include\pcre2.h",
    "lib\pcre2-8-static.lib",
    "lib\cmake\pcre2\pcre2-config.cmake",
    "lib\cmake\pcre2\pcre2-targets.cmake",
    "lib\cmake\pcre2\pcre2-targets-release.cmake"
  )) {
    $filePath = Join-Path $StageRoot $requiredFile
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
      throw "PCRE2 stage for Apache HTTP Server is missing required file: $filePath"
    }
  }

  $runtime = Get-ChildItem -LiteralPath (Join-Path $StageRoot "bin") -File -Filter "pcre2-8*.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($runtime) {
    throw "PCRE2 stage for Apache HTTP Server must be static-only for this gate; found runtime: $($runtime.FullName)"
  }

  $targetsContent = Get-Content -Raw -LiteralPath (Join-Path $StageRoot "lib\cmake\pcre2\pcre2-targets.cmake")
  if (-not $targetsContent.Contains("PCRE2_STATIC")) {
    throw "PCRE2 CMake package must propagate PCRE2_STATIC for static consumers."
  }
  if (-not $targetsContent.Contains("pcre2::pcre2-8-static")) {
    throw "PCRE2 CMake package must export the pcre2::pcre2-8-static target."
  }

  $version = Get-Pcre2VersionFromHeader -HeaderPath (Join-Path $StageRoot "include\pcre2.h")
  if ($ExpectedVersion -and $version -ne $ExpectedVersion) {
    throw "PCRE2 stage version must be $ExpectedVersion; got $version."
  }

  return $StageRoot
}

function Get-ApacheHttpdStageManifestPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot
  )

  return (Join-Path $StageRoot "subversionr-httpd-stage-manifest.json")
}

function Get-ApacheHttpdVersionFromHeader {
  param(
    [Parameter(Mandatory = $true)]
    [string]$HeaderPath
  )

  if (-not (Test-Path -LiteralPath $HeaderPath -PathType Leaf)) {
    throw "Apache HTTP Server release header is missing: $HeaderPath"
  }

  $content = Get-Content -Raw -LiteralPath $HeaderPath
  $parts = @()
  foreach ($macro in @("AP_SERVER_MAJORVERSION_NUMBER", "AP_SERVER_MINORVERSION_NUMBER", "AP_SERVER_PATCHLEVEL_NUMBER")) {
    $match = [regex]::Match($content, "(?m)^\s*#\s*define\s+$macro\s+(?<value>\d+)\b")
    if (-not $match.Success) {
      throw "Apache HTTP Server release header does not define $macro`: $HeaderPath"
    }
    $parts += $match.Groups["value"].Value
  }

  return ($parts -join ".")
}

function New-ApacheHttpdStageManifest {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot,

    [Parameter(Mandatory = $true)]
    [string]$SourceLockPath,

    [Parameter(Mandatory = $true)]
    [string]$Arch,

    [Parameter(Mandatory = $true)]
    [string]$Configuration
  )

  $lock = Read-NativeSourceLock -Path $SourceLockPath
  $source = Get-NativeSourceEntry -Lock $lock -Name "apache-httpd"
  $dependencyNames = @("apr", "apr-util", "apr-iconv", "expat", "pcre2", "openssl", "zlib")
  $dependencies = @()
  foreach ($dependencyName in $dependencyNames) {
    $dependency = Get-NativeSourceEntry -Lock $lock -Name $dependencyName
    $dependencies += [ordered]@{
      name = Get-RequiredProperty -Object $dependency -Name "name"
      version = Get-RequiredProperty -Object $dependency -Name "version"
      url = Get-RequiredProperty -Object $dependency -Name "url"
      sha512 = Get-RequiredProperty -Object $dependency -Name "sha512"
    }
  }

  $manifest = [ordered]@{
    schema = "subversionr.native.httpd-stage.v1"
    kind = "apache-httpd-dav-fixture-runtime"
    arch = $Arch
    configuration = $Configuration
    source = [ordered]@{
      name = Get-RequiredProperty -Object $source -Name "name"
      version = Get-RequiredProperty -Object $source -Name "version"
      url = Get-RequiredProperty -Object $source -Name "url"
      sha512 = Get-RequiredProperty -Object $source -Name "sha512"
    }
    dependencies = $dependencies
  }

  $manifestPath = Get-ApacheHttpdStageManifestPath -StageRoot $StageRoot
  $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding ascii
  return $manifestPath
}

function Assert-ApacheHttpdStageForDavFixtureCore {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [Parameter(Mandatory = $true)]
    [string]$SourceLockPath,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedArch,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedConfiguration,

    [switch]$AllowSubversionDavModules
  )

  if (-not (Test-Path -LiteralPath $StageRoot -PathType Container)) {
    throw "Apache HTTP Server stage root is missing: $StageRoot"
  }

  $stageRootResolved = (Resolve-Path -LiteralPath $StageRoot -ErrorAction Stop).Path
  if (-not (Test-NativePathUnderCacheRoot -Path $stageRootResolved -WorkspaceRoot $WorkspaceRoot)) {
    throw "Apache HTTP Server stage root must be under .cache: $stageRootResolved"
  }

  foreach ($requiredFile in @(
    "bin\httpd.exe",
    "bin\libhttpd.dll",
    "bin\libapr-1.dll",
    "bin\libaprutil-1.dll",
    "bin\libapriconv-1.dll",
    "bin\libexpat.dll",
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
    $filePath = Join-Path $stageRootResolved $requiredFile
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
      throw "Apache HTTP Server DAV fixture stage is missing required file: $filePath"
    }
  }

  foreach ($runtimePattern in @("bin\libcrypto-*.dll", "bin\libssl-*.dll")) {
    $runtimeDirectory = Split-Path -Parent (Join-Path $stageRootResolved $runtimePattern)
    $runtimeFilter = Split-Path -Leaf $runtimePattern
    $runtime = Get-ChildItem -LiteralPath $runtimeDirectory -File -Filter $runtimeFilter | Select-Object -First 1
    if (-not $runtime) {
      throw "Apache HTTP Server DAV fixture stage is missing required runtime matching $runtimePattern."
    }
  }

  $iconvDirectory = Join-Path $stageRootResolved "bin\iconv"
  if (-not (Test-Path -LiteralPath $iconvDirectory -PathType Container)) {
    throw "Apache HTTP Server DAV fixture stage is missing APR iconv runtime directory: $iconvDirectory"
  }
  if (-not (Get-ChildItem -LiteralPath $iconvDirectory -File -Filter "*.so" | Select-Object -First 1)) {
    throw "Apache HTTP Server DAV fixture stage APR iconv runtime directory does not contain converter modules: $iconvDirectory"
  }

  $forbiddenPatterns = @("bin\pcre2-8*.dll", "bin\zlib*.dll")
  if (-not $AllowSubversionDavModules) {
    $forbiddenPatterns += @("modules\mod_dav_svn.so", "modules\mod_authz_svn.so")
  }

  foreach ($forbiddenPattern in $forbiddenPatterns) {
    $forbiddenDirectory = Split-Path -Parent (Join-Path $stageRootResolved $forbiddenPattern)
    $forbiddenFilter = Split-Path -Leaf $forbiddenPattern
    $forbiddenFile = Get-ChildItem -LiteralPath $forbiddenDirectory -File -Filter $forbiddenFilter -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($forbiddenFile) {
      throw "Apache HTTP Server DAV fixture stage must not contain $forbiddenPattern`: $($forbiddenFile.FullName)"
    }
  }

  $lock = Read-NativeSourceLock -Path $SourceLockPath
  $source = Get-NativeSourceEntry -Lock $lock -Name "apache-httpd"
  $expectedSourceVersion = Get-RequiredProperty -Object $source -Name "version"
  $expectedSourceUrl = Get-RequiredProperty -Object $source -Name "url"
  $expectedSourceSha512 = Get-RequiredProperty -Object $source -Name "sha512"

  $headerVersion = Get-ApacheHttpdVersionFromHeader -HeaderPath (Join-Path $stageRootResolved "include\ap_release.h")
  if ($headerVersion -ne $expectedSourceVersion) {
    throw "Apache HTTP Server stage release header must report $expectedSourceVersion; got $headerVersion."
  }

  $manifestPath = Get-ApacheHttpdStageManifestPath -StageRoot $stageRootResolved
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Apache HTTP Server stage manifest is missing: $manifestPath"
  }

  $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  if ((Get-RequiredProperty -Object $manifest -Name "schema") -ne "subversionr.native.httpd-stage.v1") {
    throw "Apache HTTP Server stage manifest schema is invalid: $manifestPath"
  }
  if ((Get-RequiredProperty -Object $manifest -Name "kind") -ne "apache-httpd-dav-fixture-runtime") {
    throw "Apache HTTP Server stage manifest kind is invalid: $manifestPath"
  }
  if ((Get-RequiredProperty -Object $manifest -Name "arch") -ne $ExpectedArch) {
    throw "Apache HTTP Server stage manifest architecture must be $ExpectedArch."
  }
  if ((Get-RequiredProperty -Object $manifest -Name "configuration") -ne $ExpectedConfiguration) {
    throw "Apache HTTP Server stage manifest configuration must be $ExpectedConfiguration."
  }
  if ((Get-RequiredProperty -Object $manifest.source -Name "name") -ne "apache-httpd") {
    throw "Apache HTTP Server stage manifest source must be apache-httpd."
  }
  if ((Get-RequiredProperty -Object $manifest.source -Name "version") -ne $expectedSourceVersion) {
    throw "Apache HTTP Server stage manifest source version must be $expectedSourceVersion."
  }
  if ((Get-RequiredProperty -Object $manifest.source -Name "url") -ne $expectedSourceUrl) {
    throw "Apache HTTP Server stage manifest source url must match native source lock."
  }
  if ((Get-RequiredProperty -Object $manifest.source -Name "sha512") -ne $expectedSourceSha512) {
    throw "Apache HTTP Server stage manifest source sha512 must match native source lock."
  }

  $expectedDependencyNames = @("apr", "apr-util", "apr-iconv", "expat", "pcre2", "openssl", "zlib")
  $manifestDependencies = @($manifest.dependencies)
  if ($manifestDependencies.Count -ne $expectedDependencyNames.Count) {
    throw "Apache HTTP Server stage manifest dependency count must be $($expectedDependencyNames.Count)."
  }

  for ($i = 0; $i -lt $expectedDependencyNames.Count; $i++) {
    $expectedDependencyName = $expectedDependencyNames[$i]
    $manifestDependency = $manifestDependencies[$i]
    $lockDependency = Get-NativeSourceEntry -Lock $lock -Name $expectedDependencyName
    foreach ($field in @("name", "version", "url", "sha512")) {
      $actual = Get-RequiredProperty -Object $manifestDependency -Name $field
      $expected = Get-RequiredProperty -Object $lockDependency -Name $field
      if ($actual -ne $expected) {
        throw "Apache HTTP Server stage manifest dependency $expectedDependencyName field $field must match native source lock."
      }
    }
  }

  return $stageRootResolved
}

function Assert-ApacheHttpdStageForDavFixture {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [Parameter(Mandatory = $true)]
    [string]$SourceLockPath,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedArch,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedConfiguration
  )

  return Assert-ApacheHttpdStageForDavFixtureCore `
    -StageRoot $StageRoot `
    -WorkspaceRoot $WorkspaceRoot `
    -SourceLockPath $SourceLockPath `
    -ExpectedArch $ExpectedArch `
    -ExpectedConfiguration $ExpectedConfiguration
}

function Get-ApacheHttpdSubversionDavStageManifestPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot
  )

  return (Join-Path $StageRoot "subversionr-httpd-subversion-dav-stage-manifest.json")
}

function Get-SubversionDavModuleRuntimeFiles {
  return @(
    "libsvn_delta-1.dll",
    "libsvn_fs-1.dll",
    "libsvn_fs_fs-1.dll",
    "libsvn_fs_util-1.dll",
    "libsvn_fs_x-1.dll",
    "libsvn_repos-1.dll",
    "libsvn_subr-1.dll"
  )
}

function New-ApacheHttpdSubversionDavStageFileEntry {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot,

    [Parameter(Mandatory = $true)]
    [string]$RelativePath
  )

  $path = Join-Path $StageRoot $RelativePath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Apache HTTPD/Subversion DAV stage manifest input is missing: $path"
  }

  return [ordered]@{
    path = $RelativePath.Replace("\", "/")
    sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
  }
}

function New-ApacheHttpdSubversionDavStageManifest {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot,

    [Parameter(Mandatory = $true)]
    [string]$SourceLockPath,

    [Parameter(Mandatory = $true)]
    [string]$Arch,

    [Parameter(Mandatory = $true)]
    [string]$Configuration
  )

  $stageRootResolved = (Resolve-Path -LiteralPath $StageRoot -ErrorAction Stop).Path
  $lock = Read-NativeSourceLock -Path $SourceLockPath
  $subversionSource = Get-NativeSourceEntry -Lock $lock -Name "apache-subversion"
  $httpdSource = Get-NativeSourceEntry -Lock $lock -Name "apache-httpd"
  $dependencyNames = @("apr", "apr-util", "apr-iconv", "expat", "pcre2", "sqlite-amalgamation", "zlib", "openssl", "serf")
  $dependencies = @()
  foreach ($dependencyName in $dependencyNames) {
    $dependency = Get-NativeSourceEntry -Lock $lock -Name $dependencyName
    $dependencies += [ordered]@{
      name = Get-RequiredProperty -Object $dependency -Name "name"
      version = Get-RequiredProperty -Object $dependency -Name "version"
      url = Get-RequiredProperty -Object $dependency -Name "url"
      sha512 = Get-RequiredProperty -Object $dependency -Name "sha512"
    }
  }

  $moduleEntries = @()
  foreach ($moduleName in @("mod_dav_svn", "mod_authz_svn")) {
    $moduleEntries += [ordered]@{
      name = $moduleName
      module = New-ApacheHttpdSubversionDavStageFileEntry -StageRoot $stageRootResolved -RelativePath "modules\$moduleName.so"
      pdb = New-ApacheHttpdSubversionDavStageFileEntry -StageRoot $stageRootResolved -RelativePath "modules\$moduleName.pdb"
    }
  }

  $runtimeEntries = @()
  foreach ($runtimeName in Get-SubversionDavModuleRuntimeFiles) {
    $runtimeEntries += New-ApacheHttpdSubversionDavStageFileEntry -StageRoot $stageRootResolved -RelativePath "bin\$runtimeName"
  }

  $manifest = [ordered]@{
    schema = "subversionr.native.httpd-subversion-dav-stage.v1"
    kind = "apache-httpd-subversion-dav-module-runtime"
    arch = $Arch
    configuration = $Configuration
    sources = @(
      [ordered]@{
        name = Get-RequiredProperty -Object $httpdSource -Name "name"
        version = Get-RequiredProperty -Object $httpdSource -Name "version"
        url = Get-RequiredProperty -Object $httpdSource -Name "url"
        sha512 = Get-RequiredProperty -Object $httpdSource -Name "sha512"
      },
      [ordered]@{
        name = Get-RequiredProperty -Object $subversionSource -Name "name"
        version = Get-RequiredProperty -Object $subversionSource -Name "version"
        url = Get-RequiredProperty -Object $subversionSource -Name "url"
        sha512 = Get-RequiredProperty -Object $subversionSource -Name "sha512"
      }
    )
    dependencies = $dependencies
    modules = $moduleEntries
    runtimeFiles = $runtimeEntries
  }

  $manifestPath = Get-ApacheHttpdSubversionDavStageManifestPath -StageRoot $stageRootResolved
  $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding ascii
  return $manifestPath
}

function Assert-ApacheHttpdSubversionDavStageFileEntry {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot,

    [Parameter(Mandatory = $true)]
    $Entry,

    [Parameter(Mandatory = $true)]
    [string]$Description,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedRelativePath
  )

  $relativePath = Get-RequiredProperty -Object $Entry -Name "path"
  $expectedSha256 = Get-RequiredProperty -Object $Entry -Name "sha256"
  $normalizedRelativePath = ([string]$relativePath).Replace("\", "/")
  $normalizedExpectedPath = $ExpectedRelativePath.Replace("\", "/")
  if ([IO.Path]::IsPathRooted([string]$relativePath) -or ($normalizedRelativePath.Split("/") -contains "..") -or ($normalizedRelativePath.Split("/") -contains ".")) {
    throw "$Description manifest path must be a normalized relative path under the DAV stage: $normalizedRelativePath"
  }
  if ($normalizedRelativePath -ne $normalizedExpectedPath) {
    throw "$Description manifest path must be $normalizedExpectedPath; got $normalizedRelativePath."
  }

  $path = Join-Path $StageRoot $normalizedRelativePath.Replace("/", "\")
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "$Description is missing: $path"
  }

  $actualSha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualSha256 -ne $expectedSha256) {
    throw "$Description SHA256 must match the Apache HTTPD/Subversion DAV stage manifest: $path"
  }
}

function Assert-ApacheHttpdSubversionDavStage {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [Parameter(Mandatory = $true)]
    [string]$SourceLockPath,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedArch,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedConfiguration
  )

  $stageRootResolved = Assert-ApacheHttpdStageForDavFixtureCore `
    -StageRoot $StageRoot `
    -WorkspaceRoot $WorkspaceRoot `
    -SourceLockPath $SourceLockPath `
    -ExpectedArch $ExpectedArch `
    -ExpectedConfiguration $ExpectedConfiguration `
    -AllowSubversionDavModules

  foreach ($requiredFile in @(
    "modules\mod_dav_svn.so",
    "modules\mod_dav_svn.pdb",
    "modules\mod_authz_svn.so",
    "modules\mod_authz_svn.pdb"
  )) {
    $filePath = Join-Path $stageRootResolved $requiredFile
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
      throw "Apache HTTP Server Subversion DAV module stage is missing required file: $filePath"
    }
  }

  foreach ($runtimeName in Get-SubversionDavModuleRuntimeFiles) {
    $runtimePath = Join-Path $stageRootResolved "bin\$runtimeName"
    if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) {
      throw "Apache HTTP Server Subversion DAV module stage is missing required runtime: $runtimePath"
    }
  }

  foreach ($forbiddenTool in @("svn.exe", "svnadmin.exe", "svnserve.exe")) {
    $forbiddenToolPath = Join-Path $stageRootResolved "bin\$forbiddenTool"
    if (Test-Path -LiteralPath $forbiddenToolPath -PathType Leaf) {
      throw "Apache HTTP Server Subversion DAV module stage must not contain fixture CLI tool $forbiddenTool`: $forbiddenToolPath"
    }
  }

  $forbiddenModule = Join-Path $stageRootResolved "modules\mod_dontdothat.so"
  if (Test-Path -LiteralPath $forbiddenModule -PathType Leaf) {
    throw "Apache HTTP Server Subversion DAV module stage must not contain mod_dontdothat.so in this gate: $forbiddenModule"
  }

  $lock = Read-NativeSourceLock -Path $SourceLockPath
  $httpdSource = Get-NativeSourceEntry -Lock $lock -Name "apache-httpd"
  $subversionSource = Get-NativeSourceEntry -Lock $lock -Name "apache-subversion"

  $manifestPath = Get-ApacheHttpdSubversionDavStageManifestPath -StageRoot $stageRootResolved
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Apache HTTPD/Subversion DAV stage manifest is missing: $manifestPath"
  }

  $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  if ((Get-RequiredProperty -Object $manifest -Name "schema") -ne "subversionr.native.httpd-subversion-dav-stage.v1") {
    throw "Apache HTTPD/Subversion DAV stage manifest schema is invalid: $manifestPath"
  }
  if ((Get-RequiredProperty -Object $manifest -Name "kind") -ne "apache-httpd-subversion-dav-module-runtime") {
    throw "Apache HTTPD/Subversion DAV stage manifest kind is invalid: $manifestPath"
  }
  if ((Get-RequiredProperty -Object $manifest -Name "arch") -ne $ExpectedArch) {
    throw "Apache HTTPD/Subversion DAV stage manifest architecture must be $ExpectedArch."
  }
  if ((Get-RequiredProperty -Object $manifest -Name "configuration") -ne $ExpectedConfiguration) {
    throw "Apache HTTPD/Subversion DAV stage manifest configuration must be $ExpectedConfiguration."
  }

  $manifestSources = @($manifest.sources)
  if ($manifestSources.Count -ne 2) {
    throw "Apache HTTPD/Subversion DAV stage manifest must list exactly two sources."
  }
  foreach ($expectedSource in @($httpdSource, $subversionSource)) {
    $expectedSourceName = Get-RequiredProperty -Object $expectedSource -Name "name"
    $sourceEntries = @($manifestSources | Where-Object { $_.name -eq $expectedSourceName })
    if ($sourceEntries.Count -ne 1) {
      throw "Apache HTTPD/Subversion DAV stage manifest must contain exactly one source entry for $expectedSourceName."
    }
    foreach ($field in @("name", "version", "url", "sha512")) {
      $actual = Get-RequiredProperty -Object $sourceEntries[0] -Name $field
      $expected = Get-RequiredProperty -Object $expectedSource -Name $field
      if ($actual -ne $expected) {
        throw "Apache HTTPD/Subversion DAV stage manifest source $expectedSourceName field $field must match native source lock."
      }
    }
  }

  $expectedDependencyNames = @("apr", "apr-util", "apr-iconv", "expat", "pcre2", "sqlite-amalgamation", "zlib", "openssl", "serf")
  $manifestDependencies = @($manifest.dependencies)
  if ($manifestDependencies.Count -ne $expectedDependencyNames.Count) {
    throw "Apache HTTPD/Subversion DAV stage manifest dependency count must be $($expectedDependencyNames.Count)."
  }

  for ($i = 0; $i -lt $expectedDependencyNames.Count; $i++) {
    $expectedDependencyName = $expectedDependencyNames[$i]
    $manifestDependency = $manifestDependencies[$i]
    $lockDependency = Get-NativeSourceEntry -Lock $lock -Name $expectedDependencyName
    foreach ($field in @("name", "version", "url", "sha512")) {
      $actual = Get-RequiredProperty -Object $manifestDependency -Name $field
      $expected = Get-RequiredProperty -Object $lockDependency -Name $field
      if ($actual -ne $expected) {
        throw "Apache HTTPD/Subversion DAV stage manifest dependency $expectedDependencyName field $field must match native source lock."
      }
    }
  }

  $manifestModules = @($manifest.modules)
  if ($manifestModules.Count -ne 2) {
    throw "Apache HTTPD/Subversion DAV stage manifest must list exactly two modules."
  }
  foreach ($moduleName in @("mod_dav_svn", "mod_authz_svn")) {
    $moduleEntries = @($manifestModules | Where-Object { $_.name -eq $moduleName })
    if ($moduleEntries.Count -ne 1) {
      throw "Apache HTTPD/Subversion DAV stage manifest must contain exactly one entry for $moduleName."
    }
    Assert-ApacheHttpdSubversionDavStageFileEntry -StageRoot $stageRootResolved -Entry $moduleEntries[0].module -Description "$moduleName module" -ExpectedRelativePath "modules/$moduleName.so"
    Assert-ApacheHttpdSubversionDavStageFileEntry -StageRoot $stageRootResolved -Entry $moduleEntries[0].pdb -Description "$moduleName debug symbols" -ExpectedRelativePath "modules/$moduleName.pdb"
  }

  $manifestRuntimes = @($manifest.runtimeFiles)
  if ($manifestRuntimes.Count -ne (Get-SubversionDavModuleRuntimeFiles).Count) {
    throw "Apache HTTPD/Subversion DAV stage manifest runtime file count must be $((Get-SubversionDavModuleRuntimeFiles).Count)."
  }
  foreach ($runtimeName in Get-SubversionDavModuleRuntimeFiles) {
    $runtimeEntries = @($manifestRuntimes | Where-Object { $_.path -eq "bin/$runtimeName" })
    if ($runtimeEntries.Count -ne 1) {
      throw "Apache HTTPD/Subversion DAV stage manifest must contain exactly one runtime entry for $runtimeName."
    }
    Assert-ApacheHttpdSubversionDavStageFileEntry -StageRoot $stageRootResolved -Entry $runtimeEntries[0] -Description "$runtimeName runtime" -ExpectedRelativePath "bin/$runtimeName"
  }

  return $stageRootResolved
}

function Copy-ApacheHttpdSubversionDavStage {
  param(
    [Parameter(Mandatory = $true)]
    [string]$HttpdStageRoot,

    [Parameter(Mandatory = $true)]
    [string]$DependencyStageRoot,

    [Parameter(Mandatory = $true)]
    [string]$SubversionStageRoot,

    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$StageRoot,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [Parameter(Mandatory = $true)]
    [string]$SourceLockPath,

    [Parameter(Mandatory = $true)]
    [ValidateSet("x64")]
    [string]$Arch,

    [Parameter(Mandatory = $true)]
    [ValidateSet("Release", "Debug")]
    [string]$Configuration
  )

  $dependencyStageRootResolved = Assert-SubversionDependencyStage -StageRoot $DependencyStageRoot
  $httpdStageRootResolved = Assert-ApacheHttpdStageForDavFixture `
    -StageRoot $HttpdStageRoot `
    -WorkspaceRoot $WorkspaceRoot `
    -SourceLockPath $SourceLockPath `
    -ExpectedArch $Arch `
    -ExpectedConfiguration $Configuration
  $subversionStageRootResolved = Assert-SubversionStageForBridge `
    -StageRoot $SubversionStageRoot `
    -WorkspaceRoot $WorkspaceRoot `
    -SourceLockPath $SourceLockPath `
    -ExpectedArch $Arch `
    -ExpectedConfiguration $Configuration

  if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
    throw "Apache Subversion DAV module source root is missing: $SourceRoot"
  }
  $sourceRootResolved = (Resolve-Path -LiteralPath $SourceRoot -ErrorAction Stop).Path
  if (-not (Test-NativePathUnderCacheRoot -Path $StageRoot -WorkspaceRoot $WorkspaceRoot)) {
    throw "Apache HTTPD/Subversion DAV stage root must be under .cache: $StageRoot"
  }
  foreach ($protectedRoot in @(
    @{ Name = "DependencyStageRoot"; Value = $dependencyStageRootResolved },
    @{ Name = "HttpdStageRoot"; Value = $httpdStageRootResolved },
    @{ Name = "SubversionStageRoot"; Value = $subversionStageRootResolved },
    @{ Name = "SourceRoot"; Value = $sourceRootResolved }
  )) {
    Assert-NativeIndependentDirectory `
      -Candidate $StageRoot `
      -ExistingRoot $protectedRoot.Value `
      -CandidateName "StageRoot" `
      -ExistingName $protectedRoot.Name | Out-Null
  }

  $stageRootResolved = Clear-NativeGeneratedDirectory -Path $StageRoot -WorkspaceRoot $WorkspaceRoot -Description "Apache HTTPD/Subversion DAV stage root"
  Copy-NativeDirectoryContents -SourceRoot $httpdStageRootResolved -DestinationRoot $stageRootResolved

  foreach ($moduleName in @("mod_dav_svn", "mod_authz_svn")) {
    foreach ($extension in @("so", "pdb")) {
      $moduleSourcePath = Join-Path $sourceRootResolved "$Configuration\subversion\$moduleName\$moduleName.$extension"
      if (-not (Test-Path -LiteralPath $moduleSourcePath -PathType Leaf)) {
        throw "Apache Subversion DAV module build output is missing: $moduleSourcePath"
      }
      Copy-Item -LiteralPath $moduleSourcePath -Destination (Join-Path $stageRootResolved "modules\$moduleName.$extension") -Force
    }
  }

  foreach ($runtimeName in Get-SubversionDavModuleRuntimeFiles) {
    $runtimeSourcePath = Join-Path $subversionStageRootResolved "bin\$runtimeName"
    if (-not (Test-Path -LiteralPath $runtimeSourcePath -PathType Leaf)) {
      throw "Apache Subversion DAV runtime dependency is missing: $runtimeSourcePath"
    }
    Copy-Item -LiteralPath $runtimeSourcePath -Destination (Join-Path $stageRootResolved "bin\$runtimeName") -Force
  }

  New-ApacheHttpdSubversionDavStageManifest -StageRoot $stageRootResolved -SourceLockPath $SourceLockPath -Arch $Arch -Configuration $Configuration | Out-Null
  Assert-ApacheHttpdSubversionDavStage -StageRoot $stageRootResolved -WorkspaceRoot $WorkspaceRoot -SourceLockPath $SourceLockPath -ExpectedArch $Arch -ExpectedConfiguration $Configuration | Out-Null
  return $stageRootResolved
}

function Assert-SubversionDependencyStage {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot
  )

  Assert-AprStageForSubversion -StageRoot $StageRoot | Out-Null
  Assert-ZlibStageForSubversion -StageRoot $StageRoot | Out-Null
  Assert-ExpatStageForAprUtil -StageRoot $StageRoot | Out-Null
  Assert-SqliteStageForSubversion -StageRoot $StageRoot | Out-Null
  Assert-OpenSslStageForSerf -StageRoot $StageRoot | Out-Null
  Assert-SerfStageForSubversion -StageRoot $StageRoot | Out-Null

  return $StageRoot
}

function Get-SubversionStageManifestPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot
  )

  return (Join-Path $StageRoot "subversionr-stage-manifest.json")
}

function Get-SubversionVersionFromHeader {
  param(
    [Parameter(Mandatory = $true)]
    [string]$HeaderPath
  )

  if (-not (Test-Path -LiteralPath $HeaderPath -PathType Leaf)) {
    throw "Subversion version header is missing: $HeaderPath"
  }

  $content = Get-Content -Raw -LiteralPath $HeaderPath
  $parts = @()
  foreach ($macro in @("SVN_VER_MAJOR", "SVN_VER_MINOR", "SVN_VER_PATCH")) {
    $match = [regex]::Match($content, "(?m)^\s*#\s*define\s+$macro\s+(?<value>\d+)\b")
    if (-not $match.Success) {
      throw "Subversion version header does not define $macro`: $HeaderPath"
    }
    $parts += $match.Groups["value"].Value
  }

  return ($parts -join ".")
}

function New-SubversionStageManifest {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot,

    [Parameter(Mandatory = $true)]
    [string]$SourceLockPath,

    [Parameter(Mandatory = $true)]
    [string]$Arch,

    [Parameter(Mandatory = $true)]
    [string]$Configuration
  )

  $lock = Read-NativeSourceLock -Path $SourceLockPath
  $source = Get-NativeSourceEntry -Lock $lock -Name "apache-subversion"
  $dependencyNames = @("apr", "apr-util", "apr-iconv", "expat", "sqlite-amalgamation", "zlib", "openssl", "serf")
  $dependencies = @()
  foreach ($dependencyName in $dependencyNames) {
    $dependency = Get-NativeSourceEntry -Lock $lock -Name $dependencyName
    $dependencies += [ordered]@{
      name = Get-RequiredProperty -Object $dependency -Name "name"
      version = Get-RequiredProperty -Object $dependency -Name "version"
      url = Get-RequiredProperty -Object $dependency -Name "url"
      sha512 = Get-RequiredProperty -Object $dependency -Name "sha512"
    }
  }

  $manifest = [ordered]@{
    schema = "subversionr.native.subversion-stage.v1"
    kind = "apache-subversion-bridge-runtime"
    arch = $Arch
    configuration = $Configuration
    source = [ordered]@{
      name = Get-RequiredProperty -Object $source -Name "name"
      version = Get-RequiredProperty -Object $source -Name "version"
      url = Get-RequiredProperty -Object $source -Name "url"
      sha512 = Get-RequiredProperty -Object $source -Name "sha512"
    }
    dependencies = $dependencies
  }

  $manifestPath = Get-SubversionStageManifestPath -StageRoot $StageRoot
  $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding ascii
  return $manifestPath
}

function Assert-SubversionStageForBridge {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [Parameter(Mandatory = $true)]
    [string]$SourceLockPath,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedArch,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedConfiguration
  )

  if (-not (Test-Path -LiteralPath $StageRoot -PathType Container)) {
    throw "Subversion bridge stage root is missing: $StageRoot"
  }

  $stageRootResolved = (Resolve-Path -LiteralPath $StageRoot -ErrorAction Stop).Path
  if (-not (Test-NativePathUnderCacheRoot -Path $stageRootResolved -WorkspaceRoot $WorkspaceRoot)) {
    throw "Subversion bridge stage root must be under .cache: $stageRootResolved"
  }

  foreach ($requiredFile in @(
    "include\subversion-1\svn_client.h",
    "include\subversion-1\svn_wc.h",
    "include\subversion-1\svn_version.h",
    "include\apr.h",
    "include\apu.h",
    "include\apr_pools.h",
    "lib\libsvn_client-1.lib",
    "lib\libsvn_ra-1.lib",
    "lib\libsvn_ra_serf-1.lib",
    "lib\libsvn_wc-1.lib",
    "lib\libsvn_subr-1.lib",
    "lib\libapr-1.lib",
    "lib\libaprutil-1.lib",
    "lib\libcrypto.lib",
    "lib\libssl.lib",
    "lib\serf-1.lib",
    "include\openssl\opensslv.h",
    "include\openssl\ssl.h",
    "include\openssl\crypto.h",
    "include\serf-1\serf.h",
    "include\serf-1\serf_bucket_types.h",
    "include\serf-1\serf_bucket_util.h",
    "bin\libapr-1.dll",
    "bin\libapriconv-1.dll",
    "bin\libaprutil-1.dll",
    "bin\libexpat.dll",
    "bin\libsvn_client-1.dll",
    "bin\libsvn_delta-1.dll",
    "bin\libsvn_diff-1.dll",
    "bin\libsvn_fs-1.dll",
    "bin\libsvn_fs_fs-1.dll",
    "bin\libsvn_fs_util-1.dll",
    "bin\libsvn_fs_x-1.dll",
    "bin\libsvn_ra-1.dll",
    "bin\libsvn_repos-1.dll",
    "bin\libsvn_subr-1.dll",
    "bin\libsvn_wc-1.dll",
    "bin\svn.exe",
    "bin\svnadmin.exe",
    "bin\svnserve.exe"
  )) {
    $filePath = Join-Path $stageRootResolved $requiredFile
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
      throw "Subversion bridge stage is missing required file: $filePath"
    }
  }

  foreach ($runtimePattern in @("libssl-*.dll", "libcrypto-*.dll")) {
    $runtime = Get-ChildItem -LiteralPath (Join-Path $stageRootResolved "bin") -File -Filter $runtimePattern | Select-Object -First 1
    if (-not $runtime) {
      throw "Subversion bridge stage is missing required OpenSSL runtime matching bin\$runtimePattern."
    }
  }

  foreach ($forbiddenFile in @("lib\libserf-1.lib", "bin\libserf-1.dll")) {
    $forbiddenPath = Join-Path $stageRootResolved $forbiddenFile
    if (Test-Path -LiteralPath $forbiddenPath -PathType Leaf) {
      throw "Subversion bridge stage must not contain Serf DLL runtime artifacts: $forbiddenPath"
    }
  }

  $iconvDirectory = Join-Path $stageRootResolved "bin\iconv"
  if (-not (Test-Path -LiteralPath $iconvDirectory -PathType Container)) {
    throw "Subversion bridge stage is missing APR iconv runtime directory: $iconvDirectory"
  }
  if (-not (Get-ChildItem -LiteralPath $iconvDirectory -File -Filter "*.so" | Select-Object -First 1)) {
    throw "Subversion bridge stage APR iconv runtime directory does not contain converter modules: $iconvDirectory"
  }

  $lock = Read-NativeSourceLock -Path $SourceLockPath
  $source = Get-NativeSourceEntry -Lock $lock -Name "apache-subversion"
  $expectedSourceVersion = Get-RequiredProperty -Object $source -Name "version"
  $expectedSourceUrl = Get-RequiredProperty -Object $source -Name "url"
  $expectedSourceSha512 = Get-RequiredProperty -Object $source -Name "sha512"

  $headerVersion = Get-SubversionVersionFromHeader -HeaderPath (Join-Path $stageRootResolved "include\subversion-1\svn_version.h")
  if ($headerVersion -ne $expectedSourceVersion) {
    throw "Subversion bridge stage version header must report $expectedSourceVersion; got $headerVersion."
  }

  $expectedOpenSslVersion = Get-RequiredProperty -Object (Get-NativeSourceEntry -Lock $lock -Name "openssl") -Name "version"
  $openSslVersion = Get-OpenSslVersionFromHeader -HeaderPath (Join-Path $stageRootResolved "include\openssl\opensslv.h")
  if ($openSslVersion -ne $expectedOpenSslVersion) {
    throw "Subversion bridge stage OpenSSL version must report $expectedOpenSslVersion; got $openSslVersion."
  }

  $expectedSerfVersion = Get-RequiredProperty -Object (Get-NativeSourceEntry -Lock $lock -Name "serf") -Name "version"
  $serfVersion = Get-SerfVersionFromHeader -HeaderPath (Join-Path $stageRootResolved "include\serf-1\serf.h")
  if ($serfVersion -ne $expectedSerfVersion) {
    throw "Subversion bridge stage Serf version must report $expectedSerfVersion; got $serfVersion."
  }

  $manifestPath = Get-SubversionStageManifestPath -StageRoot $stageRootResolved
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Subversion bridge stage manifest is missing: $manifestPath"
  }

  $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  if ((Get-RequiredProperty -Object $manifest -Name "schema") -ne "subversionr.native.subversion-stage.v1") {
    throw "Subversion bridge stage manifest schema is invalid: $manifestPath"
  }
  if ((Get-RequiredProperty -Object $manifest -Name "kind") -ne "apache-subversion-bridge-runtime") {
    throw "Subversion bridge stage manifest kind is invalid: $manifestPath"
  }
  if ((Get-RequiredProperty -Object $manifest -Name "arch") -ne $ExpectedArch) {
    throw "Subversion bridge stage manifest architecture must be $ExpectedArch."
  }
  if ((Get-RequiredProperty -Object $manifest -Name "configuration") -ne $ExpectedConfiguration) {
    throw "Subversion bridge stage manifest configuration must be $ExpectedConfiguration."
  }
  if ((Get-RequiredProperty -Object $manifest.source -Name "name") -ne "apache-subversion") {
    throw "Subversion bridge stage manifest source must be apache-subversion."
  }
  if ((Get-RequiredProperty -Object $manifest.source -Name "version") -ne $expectedSourceVersion) {
    throw "Subversion bridge stage manifest source version must be $expectedSourceVersion."
  }
  if ((Get-RequiredProperty -Object $manifest.source -Name "url") -ne $expectedSourceUrl) {
    throw "Subversion bridge stage manifest source url must match native source lock."
  }
  if ((Get-RequiredProperty -Object $manifest.source -Name "sha512") -ne $expectedSourceSha512) {
    throw "Subversion bridge stage manifest source sha512 must match native source lock."
  }

  $expectedDependencyNames = @("apr", "apr-util", "apr-iconv", "expat", "sqlite-amalgamation", "zlib", "openssl", "serf")
  $manifestDependencies = @($manifest.dependencies)
  if ($manifestDependencies.Count -ne $expectedDependencyNames.Count) {
    throw "Subversion bridge stage manifest dependency count must be $($expectedDependencyNames.Count)."
  }

  foreach ($dependencyName in $expectedDependencyNames) {
    $expectedDependency = Get-NativeSourceEntry -Lock $lock -Name $dependencyName
    $matchingDependencies = @($manifestDependencies | Where-Object { $_.name -eq $dependencyName })
    if ($matchingDependencies.Count -ne 1) {
      throw "Subversion bridge stage manifest must contain exactly one dependency entry for: $dependencyName"
    }
    $manifestDependency = $matchingDependencies[0]
    if ($null -eq $manifestDependency) {
      throw "Subversion bridge stage manifest is missing dependency: $dependencyName"
    }
    if ((Get-RequiredProperty -Object $manifestDependency -Name "version") -ne (Get-RequiredProperty -Object $expectedDependency -Name "version")) {
      throw "Subversion bridge stage manifest dependency version mismatch: $dependencyName"
    }
    if ((Get-RequiredProperty -Object $manifestDependency -Name "url") -ne (Get-RequiredProperty -Object $expectedDependency -Name "url")) {
      throw "Subversion bridge stage manifest dependency url mismatch: $dependencyName"
    }
    if ((Get-RequiredProperty -Object $manifestDependency -Name "sha512") -ne (Get-RequiredProperty -Object $expectedDependency -Name "sha512")) {
      throw "Subversion bridge stage manifest dependency sha512 mismatch: $dependencyName"
    }
  }

  return $stageRootResolved
}

function Get-SubversionRaSerfRegistrationBlock {
  param(
    [Parameter(Mandatory = $true)]
    [string]$VersionText
  )

  $blockLines = @()
  $insideRaSerfBlock = $false
  foreach ($line in ($VersionText -split "\r?\n")) {
    if ($line -match "^\*\s+ra_serf\s+:") {
      $insideRaSerfBlock = $true
      $blockLines += $line
      continue
    }

    if ($insideRaSerfBlock -and $line -match "^\*\s+\S+\s+:") {
      break
    }

    if ($insideRaSerfBlock) {
      $blockLines += $line
    }
  }

  if ($blockLines.Count -eq 0) {
    throw "Staged svn.exe --version does not report the ra_serf repository access module."
  }

  return ($blockLines -join "`n")
}

function Assert-SubversionRaSerfRegistration {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot
  )

  if (-not (Test-Path -LiteralPath $StageRoot -PathType Container)) {
    throw "Subversion bridge stage root is missing: $StageRoot"
  }

  $stageRootResolved = (Resolve-Path -LiteralPath $StageRoot -ErrorAction Stop).Path
  $svnExe = Join-Path $stageRootResolved "bin\svn.exe"
  if (-not (Test-Path -LiteralPath $svnExe -PathType Leaf)) {
    throw "Subversion bridge stage is missing source-built svn.exe: $svnExe"
  }

  $oldPath = $env:PATH
  try {
    $env:PATH = (Join-Path $stageRootResolved "bin") + [IO.Path]::PathSeparator + $oldPath
    $output = & $svnExe --version 2>&1
    $exitCode = $LASTEXITCODE
  }
  finally {
    $env:PATH = $oldPath
  }

  if ($exitCode -ne 0) {
    throw "Staged svn.exe --version failed with exit code $exitCode."
  }

  $versionText = $output | Out-String
  $raSerfBlock = Get-SubversionRaSerfRegistrationBlock -VersionText $versionText
  foreach ($scheme in @("http", "https")) {
    if (-not $raSerfBlock.Contains("- handles '$scheme' scheme")) {
      throw "Staged svn.exe --version does not report ra_serf handling the '$scheme' scheme."
    }
  }

  Write-Host "Verified staged svn.exe reports ra_serf for http and https."
}

function Copy-BridgeRuntimeDependencies {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SubversionStageRoot,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [Parameter(Mandatory = $true)]
    [string]$SourceLockPath,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedArch,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedConfiguration
  )

  $stageRootResolved = Assert-SubversionStageForBridge -StageRoot $SubversionStageRoot -WorkspaceRoot $WorkspaceRoot -SourceLockPath $SourceLockPath -ExpectedArch $ExpectedArch -ExpectedConfiguration $ExpectedConfiguration
  $absoluteOutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
  $workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
  $allowedRoots = @(
    (Join-Path $workspace ".cache"),
    (Join-Path $workspace "target")
  )

  $isAllowed = $false
  foreach ($allowedRoot in $allowedRoots) {
    if (Test-NativePathWithinRoot -Path $absoluteOutputDirectory -Root $allowedRoot) {
      $isAllowed = $true
      break
    }
  }

  if (-not $isAllowed) {
    throw "Refusing to copy bridge runtime dependencies outside repository generated roots: $absoluteOutputDirectory"
  }

  if (Test-Path -LiteralPath $absoluteOutputDirectory -PathType Leaf) {
    throw "Bridge runtime output path is a file, not a directory: $absoluteOutputDirectory"
  }

  New-Item -ItemType Directory -Force -Path $absoluteOutputDirectory | Out-Null
  Copy-NativeDirectoryContents -SourceRoot (Join-Path $stageRootResolved "bin") -DestinationRoot $absoluteOutputDirectory

  return (Resolve-Path -LiteralPath $absoluteOutputDirectory).Path
}

function Copy-NativeDirectoryContents {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$DestinationRoot
  )

  if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
    throw "Native copy source root is missing: $SourceRoot"
  }

  New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null
  foreach ($child in Get-ChildItem -LiteralPath $SourceRoot -Force) {
    Copy-Item -LiteralPath $child.FullName -Destination $DestinationRoot -Recurse -Force
  }
}

function Copy-RequiredNativeFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$DestinationRoot,

    [Parameter(Mandatory = $true)]
    [string]$RelativePath
  )

  $sourcePath = Join-Path $SourceRoot $RelativePath
  if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Required native stage file is missing: $sourcePath"
  }

  $destinationPath = Join-Path $DestinationRoot $RelativePath
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destinationPath) | Out-Null
  Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
}

function Copy-RequiredNativeFilePattern {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$DestinationRoot,

    [Parameter(Mandatory = $true)]
    [string]$SourceRelativeDirectory,

    [Parameter(Mandatory = $true)]
    [string]$Pattern
  )

  $sourceDirectory = Join-Path $SourceRoot $SourceRelativeDirectory
  if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
    throw "Required native stage directory is missing: $sourceDirectory"
  }

  $files = @(Get-ChildItem -LiteralPath $sourceDirectory -File -Filter $Pattern)
  if ($files.Count -eq 0) {
    throw "Required native stage file matching $SourceRelativeDirectory\$Pattern is missing."
  }

  $destinationDirectory = Join-Path $DestinationRoot $SourceRelativeDirectory
  New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
  foreach ($file in $files) {
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $destinationDirectory $file.Name) -Force
  }
}

function Copy-SubversionDependencyStageForBridge {
  param(
    [Parameter(Mandatory = $true)]
    [string]$DependencyStageRoot,

    [Parameter(Mandatory = $true)]
    [string]$StageRoot
  )

  Assert-SubversionDependencyStage -StageRoot $DependencyStageRoot | Out-Null

  foreach ($header in Get-ChildItem -LiteralPath (Join-Path $DependencyStageRoot "include") -File) {
    Copy-Item -LiteralPath $header.FullName -Destination (Join-Path $StageRoot "include\$($header.Name)") -Force
  }
  foreach ($includeDirectory in @("openssl", "serf-1")) {
    Copy-NativeDirectoryContents `
      -SourceRoot (Join-Path $DependencyStageRoot "include\$includeDirectory") `
      -DestinationRoot (Join-Path $StageRoot "include\$includeDirectory")
  }

  foreach ($library in @(
    "lib\apr-1.lib",
    "lib\aprutil-1.lib",
    "lib\libapr-1.lib",
    "lib\libapriconv-1.lib",
    "lib\libaprutil-1.lib",
    "lib\libcrypto.lib",
    "lib\libexpat.lib",
    "lib\libssl.lib",
    "lib\serf-1.lib",
    "lib\sqlite3.lib",
    "lib\zlib.lib"
  )) {
    $sourcePath = Join-Path $DependencyStageRoot $library
    if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
      Copy-RequiredNativeFile -SourceRoot $DependencyStageRoot -DestinationRoot $StageRoot -RelativePath $library
    }
  }

  foreach ($runtime in @(
    "bin\apr_dbd_odbc-1.dll",
    "bin\apr_ldap-1.dll",
    "bin\libapr-1.dll",
    "bin\libapriconv-1.dll",
    "bin\libaprutil-1.dll",
    "bin\libexpat.dll"
  )) {
    $sourcePath = Join-Path $DependencyStageRoot $runtime
    if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
      Copy-RequiredNativeFile -SourceRoot $DependencyStageRoot -DestinationRoot $StageRoot -RelativePath $runtime
    }
  }
  Copy-RequiredNativeFilePattern -SourceRoot $DependencyStageRoot -DestinationRoot $StageRoot -SourceRelativeDirectory "bin" -Pattern "libcrypto-*.dll"
  Copy-RequiredNativeFilePattern -SourceRoot $DependencyStageRoot -DestinationRoot $StageRoot -SourceRelativeDirectory "bin" -Pattern "libssl-*.dll"

  $iconvSourceRoot = Join-Path $DependencyStageRoot "bin\iconv"
  if (-not (Test-Path -LiteralPath $iconvSourceRoot -PathType Container)) {
    throw "APR iconv runtime directory is missing: $iconvSourceRoot"
  }
  Copy-NativeDirectoryContents -SourceRoot $iconvSourceRoot -DestinationRoot (Join-Path $StageRoot "bin\iconv")
}

function Copy-SubversionBuildStage {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$DependencyStageRoot,

    [Parameter(Mandatory = $true)]
    [string]$StageRoot,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [Parameter(Mandatory = $true)]
    [string]$SourceLockPath,

    [Parameter(Mandatory = $true)]
    [ValidateSet("x64")]
    [string]$Arch,

    [Parameter(Mandatory = $true)]
    [ValidateSet("Release", "Debug")]
    [string]$Configuration
  )

  if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
    throw "Apache Subversion source root is missing: $SourceRoot"
  }
  if (-not (Test-Path -LiteralPath $DependencyStageRoot -PathType Container)) {
    throw "Subversion dependency stage root is missing: $DependencyStageRoot"
  }

  $publicIncludeRoot = Join-Path $SourceRoot "subversion\include"
  if (-not (Test-Path -LiteralPath $publicIncludeRoot -PathType Container)) {
    throw "Apache Subversion public include directory is missing: $publicIncludeRoot"
  }

  $releaseRoot = Join-Path $SourceRoot "$Configuration\subversion"
  if (-not (Test-Path -LiteralPath $releaseRoot -PathType Container)) {
    throw "Apache Subversion build output directory is missing: $releaseRoot"
  }
  if (-not (Test-NativePathUnderCacheRoot -Path $StageRoot -WorkspaceRoot $WorkspaceRoot)) {
    throw "Subversion bridge stage root must be under .cache: $StageRoot"
  }

  Clear-NativeGeneratedDirectory -Path $StageRoot -WorkspaceRoot $WorkspaceRoot -Description "Apache Subversion bridge stage root" | Out-Null
  $stageRootResolved = New-NativeStageLayout -Path $StageRoot
  Copy-SubversionDependencyStageForBridge -DependencyStageRoot $DependencyStageRoot -StageRoot $stageRootResolved

  $subversionIncludeStage = Join-Path $stageRootResolved "include\subversion-1"
  New-Item -ItemType Directory -Force -Path $subversionIncludeStage | Out-Null
  foreach ($header in Get-ChildItem -LiteralPath $publicIncludeRoot -File -Filter "*.h") {
    Copy-Item -LiteralPath $header.FullName -Destination (Join-Path $subversionIncludeStage $header.Name) -Force
  }

  foreach ($libraryDirectory in Get-ChildItem -LiteralPath $releaseRoot -Directory -Filter "libsvn_*") {
    foreach ($library in Get-ChildItem -LiteralPath $libraryDirectory.FullName -File -Filter "*.lib") {
      Copy-Item -LiteralPath $library.FullName -Destination (Join-Path $stageRootResolved "lib\$($library.Name)") -Force
    }
    foreach ($libraryDll in Get-ChildItem -LiteralPath $libraryDirectory.FullName -File -Filter "*.dll") {
      Copy-Item -LiteralPath $libraryDll.FullName -Destination (Join-Path $stageRootResolved "bin\$($libraryDll.Name)") -Force
    }
  }

  foreach ($tool in @("svn", "svnadmin", "svnserve")) {
    $toolPath = Join-Path $releaseRoot "$tool\$tool.exe"
    if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
      throw "Apache Subversion fixture tool is missing: $toolPath"
    }
    Copy-Item -LiteralPath $toolPath -Destination (Join-Path $stageRootResolved "bin\$tool.exe") -Force
  }

  New-SubversionStageManifest -StageRoot $stageRootResolved -SourceLockPath $SourceLockPath -Arch $Arch -Configuration $Configuration | Out-Null
  Assert-SubversionStageForBridge -StageRoot $stageRootResolved -WorkspaceRoot $WorkspaceRoot -SourceLockPath $SourceLockPath -ExpectedArch $Arch -ExpectedConfiguration $Configuration | Out-Null
  return $stageRootResolved
}

function Update-SubversionGeneratorForExpat272 {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot
  )

  $generatorPath = Join-Path $SourceRoot "build\generator\gen_win_dependencies.py"
  if (-not (Test-Path -LiteralPath $generatorPath -PathType Leaf)) {
    throw "Subversion Windows dependency generator is missing: $generatorPath"
  }

  $content = Get-Content -Raw -LiteralPath $generatorPath
  $patchedContent = $content

  foreach ($macro in @("XML_MAJOR_VERSION", "XML_MINOR_VERSION", "XML_MICRO_VERSION")) {
    $oldPattern = "#define\s+$macro"
    $newPattern = "#\s*define\s+$macro"
    if ($patchedContent.Contains($oldPattern)) {
      $patchedContent = $patchedContent.Replace($oldPattern, $newPattern)
    }
    elseif (-not $patchedContent.Contains($newPattern)) {
      throw "Subversion generator does not contain the expected Expat version regex for $macro."
    }
  }

  if ($patchedContent -ne $content) {
    Set-Content -LiteralPath $generatorPath -Value $patchedContent -NoNewline
  }
}

function Update-GeneratedVcxprojPlatformToolset {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$FromToolset,

    [Parameter(Mandatory = $true)]
    [string]$ToToolset
  )

  if ($FromToolset -eq $ToToolset) {
    throw "FromToolset and ToToolset must be different."
  }

  $projectDirectory = Join-Path $SourceRoot "build\win32\vcnet-vcproj"
  if (-not (Test-Path -LiteralPath $projectDirectory -PathType Container)) {
    throw "Generated Subversion vcxproj directory is missing: $projectDirectory"
  }

  $projects = @(Get-ChildItem -LiteralPath $projectDirectory -Filter "*.vcxproj" -File)
  if ($projects.Count -eq 0) {
    throw "Generated Subversion vcxproj directory does not contain any vcxproj files: $projectDirectory"
  }

  $fromElement = "<PlatformToolset>$FromToolset</PlatformToolset>"
  $toElement = "<PlatformToolset>$ToToolset</PlatformToolset>"
  $changedProjects = @()
  $recognizedProjects = 0

  foreach ($project in $projects) {
    $content = Get-Content -Raw -LiteralPath $project.FullName
    if ($content.Contains($fromElement)) {
      $content = $content.Replace($fromElement, $toElement)
      Set-Content -LiteralPath $project.FullName -Value $content -NoNewline
      $changedProjects += $project.FullName
      $recognizedProjects += 1
    }
    elseif ($content.Contains($toElement)) {
      $recognizedProjects += 1
    }
  }

  if ($recognizedProjects -eq 0) {
    throw "Generated Subversion vcxproj files do not contain PlatformToolset '$FromToolset' or '$ToToolset'."
  }

  return $changedProjects
}

function Assert-GeneratedVcxprojPlatformToolset {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedToolset
  )

  $projectDirectory = Join-Path $SourceRoot "build\win32\vcnet-vcproj"
  if (-not (Test-Path -LiteralPath $projectDirectory -PathType Container)) {
    throw "Generated Subversion vcxproj directory is missing: $projectDirectory"
  }

  $projects = @(Get-ChildItem -LiteralPath $projectDirectory -Filter "*.vcxproj" -File)
  if ($projects.Count -eq 0) {
    throw "Generated Subversion vcxproj directory does not contain any vcxproj files: $projectDirectory"
  }

  $toolsetErrors = @()
  foreach ($project in $projects) {
    $content = Get-Content -Raw -LiteralPath $project.FullName
    $toolsetMatches = [regex]::Matches($content, "<PlatformToolset>([^<]+)</PlatformToolset>")
    if ($toolsetMatches.Count -eq 0) {
      $toolsetErrors += "$($project.Name): missing PlatformToolset"
      continue
    }

    $toolsets = @()
    foreach ($match in $toolsetMatches) {
      $toolsets += $match.Groups[1].Value
    }

    $unexpectedToolsets = @($toolsets | Where-Object { $_ -ne $ExpectedToolset })
    if ($unexpectedToolsets.Count -ne 0) {
      $toolsetErrors += "$($project.Name): expected $ExpectedToolset, found $($toolsets -join ', ')"
    }
  }

  if ($toolsetErrors.Count -ne 0) {
    throw "Generated Subversion vcxproj PlatformToolset validation failed: $($toolsetErrors -join '; ')"
  }

  $solutionPath = Join-Path $SourceRoot "subversion_vcnet.sln"
  if (-not (Test-Path -LiteralPath $solutionPath -PathType Leaf)) {
    throw "Generated Subversion solution is missing: $solutionPath"
  }

  $solutionContent = Get-Content -Raw -LiteralPath $solutionPath
  $solutionProjectMatches = [regex]::Matches($solutionContent, '"([^"]+\.vcxproj)"')
  if ($solutionProjectMatches.Count -eq 0) {
    throw "Generated Subversion solution does not reference any vcxproj files: $solutionPath"
  }

  $missingReferences = @()
  foreach ($match in $solutionProjectMatches) {
    $projectReference = $match.Groups[1].Value
    if ([IO.Path]::IsPathRooted($projectReference)) {
      $projectPath = $projectReference
    }
    else {
      $projectPath = Join-Path $SourceRoot $projectReference
    }

    if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
      $missingReferences += $projectReference
    }
  }

  if ($missingReferences.Count -ne 0) {
    throw "Generated Subversion solution references missing vcxproj files: $($missingReferences -join ', ')"
  }

  return $projects.FullName
}

function Assert-GeneratedSubversionRaSerfProjectGraph {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot
  )

  $projectDirectory = Join-Path $SourceRoot "build\win32\vcnet-vcproj"
  if (-not (Test-Path -LiteralPath $projectDirectory -PathType Container)) {
    throw "Generated Subversion vcxproj directory is missing: $projectDirectory"
  }

  $raSerfProject = Join-Path $projectDirectory "libsvn_ra_serf.vcxproj"
  $raDllProject = Join-Path $projectDirectory "libsvn_ra_dll.vcxproj"
  foreach ($projectPath in @($raSerfProject, $raDllProject)) {
    if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
      throw "Generated Subversion ra_serf project graph is missing: $projectPath"
    }
  }

  $raSerfContent = Get-Content -Raw -LiteralPath $raSerfProject
  foreach ($requiredText in @(
    "<ConfigurationType>StaticLibrary</ConfigurationType>",
    "<TargetName>libsvn_ra_serf-1</TargetName>",
    "SVN_HAVE_SERF",
    "SVN_LIBSVN_RA_LINKS_RA_SERF"
  )) {
    if (-not $raSerfContent.Contains($requiredText)) {
      throw "Generated libsvn_ra_serf project does not contain required text: $requiredText"
    }
  }

  $raDllContent = Get-Content -Raw -LiteralPath $raDllProject
  foreach ($requiredText in @(
    "<ConfigurationType>DynamicLibrary</ConfigurationType>",
    "<TargetName>libsvn_ra-1</TargetName>",
    "SVN_HAVE_SERF",
    "SVN_LIBSVN_RA_LINKS_RA_SERF"
  )) {
    if (-not $raDllContent.Contains($requiredText)) {
      throw "Generated libsvn_ra DLL project does not contain required text: $requiredText"
    }
  }

  if (-not ($raDllContent -match "<ProjectReference\b[^>]*\bInclude=`"libsvn_ra_serf\.vcxproj`"")) {
    throw "Generated libsvn_ra DLL project does not reference libsvn_ra_serf.vcxproj."
  }

  foreach ($requiredLinkInput in @("serf-1.lib", "libssl.lib", "libcrypto.lib")) {
    if (-not ($raDllContent -match "<AdditionalDependencies>[^<]*$([regex]::Escape($requiredLinkInput))[^<]*</AdditionalDependencies>")) {
      throw "Generated libsvn_ra DLL project is missing required link input: $requiredLinkInput"
    }
  }

  Write-Host "Verified generated Subversion ra_serf MSBuild project graph."
}

function Assert-GeneratedSubversionApacheModuleProjectGraph {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot
  )

  $projectDirectory = Join-Path $SourceRoot "build\win32\vcnet-vcproj"
  if (-not (Test-Path -LiteralPath $projectDirectory -PathType Container)) {
    throw "Generated Subversion vcxproj directory is missing: $projectDirectory"
  }

  $modDavProject = Join-Path $projectDirectory "mod_dav_svn.vcxproj"
  $modAuthzProject = Join-Path $projectDirectory "mod_authz_svn.vcxproj"
  foreach ($projectPath in @($modDavProject, $modAuthzProject)) {
    if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
      throw "Generated Subversion Apache module project graph is missing: $projectPath"
    }
  }

  $modDavContent = Get-Content -Raw -LiteralPath $modDavProject
  foreach ($requiredText in @(
    "<ConfigurationType>DynamicLibrary</ConfigurationType>",
    "<TargetName>mod_dav_svn</TargetName>",
    "<TargetExt>.so</TargetExt>",
    "AP_DECLARE_EXPORT"
  )) {
    if (-not $modDavContent.Contains($requiredText)) {
      throw "Generated mod_dav_svn project does not contain required text: $requiredText"
    }
  }
  foreach ($requiredLinkInput in @("libhttpd.lib", "mod_dav.lib")) {
    if (-not ($modDavContent -match "<AdditionalDependencies>[^<]*$([regex]::Escape($requiredLinkInput))[^<]*</AdditionalDependencies>")) {
      throw "Generated mod_dav_svn project is missing required link input: $requiredLinkInput"
    }
  }
  foreach ($requiredProjectReference in @(
    "libsvn_delta_dll.vcxproj",
    "libsvn_fs_dll.vcxproj",
    "libsvn_repos_dll.vcxproj",
    "libsvn_subr_dll.vcxproj"
  )) {
    if (-not ($modDavContent -match "<ProjectReference\b[^>]*\bInclude=`"$([regex]::Escape($requiredProjectReference))`"")) {
      throw "Generated mod_dav_svn project is missing required project reference: $requiredProjectReference"
    }
  }

  $modAuthzContent = Get-Content -Raw -LiteralPath $modAuthzProject
  foreach ($requiredText in @(
    "<ConfigurationType>DynamicLibrary</ConfigurationType>",
    "<TargetName>mod_authz_svn</TargetName>",
    "<TargetExt>.so</TargetExt>",
    "AP_DECLARE_EXPORT"
  )) {
    if (-not $modAuthzContent.Contains($requiredText)) {
      throw "Generated mod_authz_svn project does not contain required text: $requiredText"
    }
  }
  if (-not ($modAuthzContent -match "<AdditionalDependencies>[^<]*$([regex]::Escape("libhttpd.lib"))[^<]*</AdditionalDependencies>")) {
    throw "Generated mod_authz_svn project is missing required link input: libhttpd.lib"
  }
  foreach ($requiredProjectReference in @(
    "mod_dav_svn.vcxproj",
    "libsvn_repos_dll.vcxproj",
    "libsvn_subr_dll.vcxproj"
  )) {
    if (-not ($modAuthzContent -match "<ProjectReference\b[^>]*\bInclude=`"$([regex]::Escape($requiredProjectReference))`"")) {
      throw "Generated mod_authz_svn project is missing required project reference: $requiredProjectReference"
    }
  }

  Write-Host "Verified generated Subversion Apache DAV module MSBuild project graph."
}

function Get-RequiredSourceDateEpoch {
  $value = [Environment]::GetEnvironmentVariable("SOURCE_DATE_EPOCH")
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "SOURCE_DATE_EPOCH is required for reproducible native release builds."
  }
  if ($value -notmatch '^[1-9][0-9]*$') {
    throw "SOURCE_DATE_EPOCH must be a positive integer Unix timestamp."
  }

  try {
    $seconds = [Int64]::Parse($value, [Globalization.CultureInfo]::InvariantCulture)
    return [DateTimeOffset]::FromUnixTimeSeconds($seconds).ToUniversalTime()
  }
  catch {
    throw "SOURCE_DATE_EPOCH must be a valid Unix timestamp: $value"
  }
}

function Set-SubversionReproducibleBuildTimestamp {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot
  )

  $sourceRootResolved = Resolve-Path -LiteralPath $SourceRoot -ErrorAction Stop
  $timestamp = Get-RequiredSourceDateEpoch
  $date = '{0} {1} {2}' -f `
    $timestamp.ToString("MMM", [Globalization.CultureInfo]::InvariantCulture), `
    $timestamp.Day.ToString([Globalization.CultureInfo]::InvariantCulture).PadLeft(2, ' '), `
    $timestamp.Year.ToString("0000", [Globalization.CultureInfo]::InvariantCulture)
  $time = $timestamp.ToString("HH:mm:ss", [Globalization.CultureInfo]::InvariantCulture)

  $patches = @(
    @{
      Path = "subversion\libsvn_subr\version.c"
      Replacements = @(
        @{ Expected = "info->build_date = __DATE__;"; Replacement = "info->build_date = `"$date`";" },
        @{ Expected = "info->build_time = __TIME__;"; Replacement = "info->build_time = `"$time`";" }
      )
    },
    @{
      Path = "subversion\libsvn_subr\win32_crashrpt.c"
      Replacements = @(
        @{ Expected = "SVN_VERSION, __DATE__, __TIME__);"; Replacement = "SVN_VERSION, `"$date`", `"$time`");" }
      )
    }
  )

  foreach ($patch in $patches) {
    $path = Join-Path $sourceRootResolved.Path $patch.Path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Apache Subversion reproducible timestamp source is missing: $path"
    }
    $content = [IO.File]::ReadAllText($path)
    foreach ($replacement in $patch.Replacements) {
      $count = ([regex]::Matches($content, [regex]::Escape($replacement.Expected))).Count
      if ($count -ne 1) {
        throw "Apache Subversion reproducible timestamp patch expected exactly one '$($replacement.Expected)' in $path; found $count."
      }
      $content = $content.Replace($replacement.Expected, $replacement.Replacement)
    }
    [IO.File]::WriteAllText($path, $content, [Text.UTF8Encoding]::new($false))
  }

  Write-Host "Pinned Apache Subversion build timestamp to $date $time UTC from SOURCE_DATE_EPOCH."
}

function Assert-DeterministicPeFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
  $stream = $null
  $reader = $null
  try {
    $stream = [System.IO.File]::OpenRead($resolved.Path)
    $reader = [System.Reflection.PortableExecutable.PEReader]::new($stream)
    $headers = $reader.PEHeaders
    if ($null -eq $headers -or $null -eq $headers.PEHeader) {
      throw [System.BadImageFormatException]::new("Missing PE header.")
    }
    $reproducibleType = [System.Reflection.PortableExecutable.DebugDirectoryEntryType]::Reproducible
    $reproducibleEntries = @($reader.ReadDebugDirectory() | Where-Object { $_.Type -eq $reproducibleType })
    if ($reproducibleEntries.Count -ne 1) {
      throw "$Path must contain exactly one IMAGE_DEBUG_TYPE_REPRO entry from deterministic PE/COFF linking."
    }
    return $resolved.Path
  }
  catch [System.BadImageFormatException] {
    throw "$Path is not a valid PE file."
  }
  finally {
    if ($null -ne $reader) {
      $reader.Dispose()
    }
    if ($null -ne $stream) {
      $stream.Dispose()
    }
  }
}

Export-ModuleMember -Function `
  Get-RequiredProperty, `
  Read-NativeSourceLock, `
  Get-NativeSourceEntry, `
  Get-NativeArchivePath, `
  Assert-NativeArchiveChecksum, `
  New-NativeStageLayout, `
  Clear-NativeGeneratedDirectory, `
  Assert-NativeIndependentDirectory, `
  Resolve-SqliteAmalgamationRoot, `
  Assert-ZlibStageForSubversion, `
  Assert-ExpatStageForAprUtil, `
  Assert-SqliteStageForSubversion, `
  Assert-AprStageForSubversion, `
  Assert-AprPrivateHeadersForHttpd, `
  Assert-OpenSslStageForSerf, `
  Assert-SerfStageForSubversion, `
  Assert-Pcre2StageForHttpd, `
  Get-ApacheHttpdStageManifestPath, `
  Get-ApacheHttpdVersionFromHeader, `
  New-ApacheHttpdStageManifest, `
  Assert-ApacheHttpdStageForDavFixture, `
  Get-ApacheHttpdSubversionDavStageManifestPath, `
  Get-SubversionDavModuleRuntimeFiles, `
  New-ApacheHttpdSubversionDavStageManifest, `
  Assert-ApacheHttpdSubversionDavStage, `
  Copy-ApacheHttpdSubversionDavStage, `
  Assert-SubversionDependencyStage, `
  Get-SubversionVersionFromHeader, `
  New-SubversionStageManifest, `
  Assert-SubversionStageForBridge, `
  Get-SubversionRaSerfRegistrationBlock, `
  Assert-SubversionRaSerfRegistration, `
  Copy-BridgeRuntimeDependencies, `
  Copy-SubversionBuildStage, `
  Update-SubversionGeneratorForExpat272, `
  Update-GeneratedVcxprojPlatformToolset, `
  Assert-GeneratedVcxprojPlatformToolset, `
  Assert-GeneratedSubversionRaSerfProjectGraph, `
  Assert-GeneratedSubversionApacheModuleProjectGraph, `
  Get-RequiredSourceDateEpoch, `
  Set-SubversionReproducibleBuildTimestamp, `
  Assert-DeterministicPeFile

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$modulePath = Join-Path $repoRoot "scripts\native\SubversionR.Native.psm1"
$buildDependenciesScript = Join-Path $repoRoot "scripts\native\build-dependencies.ps1"
$buildHttpdScript = Join-Path $repoRoot "scripts\native\build-httpd.ps1"
$buildSubversionScript = Join-Path $repoRoot "scripts\native\build-subversion.ps1"
$buildDavModulesScript = Join-Path $repoRoot "scripts\native\build-subversion-dav-modules.ps1"
$buildBridgeScript = Join-Path $repoRoot "scripts\native\build-bridge.ps1"
$smokeBridgeScript = Join-Path $repoRoot "scripts\native\smoke-bridge.ps1"
$smokeHttpdDavHttpsScript = Join-Path $repoRoot "scripts\native\smoke-httpd-dav-https.ps1"
$smokeMaliciousDavXmlScript = Join-Path $repoRoot "scripts\native\smoke-malicious-dav-xml.ps1"
$smokeMaliciousSvnServerResponseScript = Join-Path $repoRoot "scripts\native\smoke-malicious-svn-server-response.ps1"
$ciWorkflow = Join-Path $repoRoot ".github\workflows\ci.yml"
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

$tempRoot = Join-Path $repoRoot ".cache\tests\native-scripts\$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  Import-Module $modulePath -Force

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
  Assert-True ($buildSubversionText.Contains('[string]$SerfRoot')) "M6s Subversion build entrypoint should require an explicit Serf stage root."
  Assert-True ($buildSubversionText.Contains('[string]$OpenSslRoot')) "M6s Subversion build entrypoint should require an explicit OpenSSL stage root."
  Assert-True ($buildSubversionText.Contains('Assert-SerfStageForSubversion -StageRoot $serfRootResolved')) "M6s Subversion build should fail fast on invalid Serf staging."
  Assert-True ($buildSubversionText.Contains('Assert-OpenSslStageForSerf -StageRoot $openSslRootResolved')) "M6s Subversion build should fail fast on invalid OpenSSL staging."
  Assert-True ($buildSubversionText.Contains('--with-serf=$serfRootResolved')) "M6s Subversion generator should receive the staged Serf install root."
  Assert-True ($buildSubversionText.Contains('--with-openssl=$openSslRootResolved')) "M6s Subversion generator should receive the staged OpenSSL install root."
  Assert-True ($buildSubversionText.Contains('Assert-SameResolvedDirectory $dependencyRoot.Value $dependencyStageRootResolved $dependencyRoot.Name')) "M6s Subversion build should reject generator roots that differ from the packaged dependency stage."
  Assert-True ($buildSubversionText.Contains('Assert-GeneratedSubversionRaSerfProjectGraph -SourceRoot $sourceRoot')) "M6s Subversion build should verify the generated ra_serf MSBuild project graph."
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
}

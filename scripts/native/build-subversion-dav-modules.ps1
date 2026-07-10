[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$DependencyStageRoot,

  [Parameter(Mandatory = $true)]
  [string]$HttpdStageRoot,

  [Parameter(Mandatory = $true)]
  [string]$SubversionStageRoot,

  [Parameter(Mandatory = $true)]
  [string]$StageRoot,

  [string]$CacheRoot = ".cache\native\sources",

  [string]$WorkRoot = ".cache\native\work\subversion-dav-modules",

  [ValidateSet("Release", "Debug")]
  [string]$Configuration = "Release",

  [ValidateSet("x64")]
  [string]$Arch = "x64",

  [string]$VsNetVersion = "2019",

  [string]$GeneratedPlatformToolset = "v142",

  [string]$PlatformToolset = "v143",

  [string]$VsDevCmd,

  [switch]$SkipVerifySources
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$modulePath = Join-Path $PSScriptRoot "SubversionR.Native.psm1"
Import-Module $modulePath -Force

$lockPath = Join-Path $repoRoot "native\sources.lock.json"
$buildLog = Join-Path $repoRoot ".cache\native\subversion-dav-modules-build.log"

function Resolve-RepositoryPath([string]$Path, [string]$Name) {
  if (-not $Path) {
    throw "$Name is required."
  }

  if ([IO.Path]::IsPathRooted($Path)) {
    return [IO.Path]::GetFullPath($Path)
  }

  return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Resolve-RequiredDirectory([string]$Path, [string]$Name) {
  $absolutePath = Resolve-RepositoryPath $Path $Name
  if (-not (Test-Path -LiteralPath $absolutePath -PathType Container)) {
    throw "$Name must be a directory: $absolutePath"
  }

  return (Resolve-Path -LiteralPath $absolutePath -ErrorAction Stop).Path
}

function Assert-RequiredFile([string]$Path, [string]$Description) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Missing $Description`: $Path"
  }
}

function Quote-CmdArgument([string]$Value) {
  return '"' + $Value.Replace('"', '\"') + '"'
}

function ConvertTo-MsBuildPath([string]$Path) {
  return ([IO.Path]::GetFullPath($Path)).Replace("\", "/")
}

function Test-LocalPathWithinRoot([string]$Path, [string]$Root) {
  $absolutePath = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  $absoluteRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  return $absolutePath.StartsWith($absoluteRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-IndependentGeneratedRoot([string]$Candidate, [string]$ExistingRoot, [string]$CandidateName, [string]$ExistingName) {
  $candidateResolved = [IO.Path]::GetFullPath($Candidate).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  $existingResolved = [IO.Path]::GetFullPath($ExistingRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  if ([string]::Equals($candidateResolved, $existingResolved, [StringComparison]::OrdinalIgnoreCase) -or
      (Test-LocalPathWithinRoot -Path $candidateResolved -Root $existingResolved) -or
      (Test-LocalPathWithinRoot -Path $existingResolved -Root $candidateResolved)) {
    throw "$CandidateName must be independent from $ExistingName`: $candidateResolved"
  }
}

function Invoke-SubversionDavModuleLoadProbe {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StageRoot,

    [Parameter(Mandatory = $true)]
    [string]$ProbeRoot
  )

  $stageRootResolved = Resolve-Path -LiteralPath $StageRoot -ErrorAction Stop
  $probeRootResolved = New-Item -ItemType Directory -Force -Path $ProbeRoot
  $configPath = Join-Path $probeRootResolved.FullName "subversionr-dav-modules-load.conf"
  $serverRoot = (ConvertTo-MsBuildPath $stageRootResolved.Path)
  $config = @"
ServerRoot "$serverRoot"
ServerName 127.0.0.1
PidFile logs/subversionr-dav-modules.pid
ErrorLog logs/subversionr-dav-modules-error.log
LoadModule dav_module modules/mod_dav.so
LoadModule dav_svn_module modules/mod_dav_svn.so
LoadModule authz_svn_module modules/mod_authz_svn.so
"@

  foreach ($forbiddenDirective in @("SVNPath", "SVNParentPath", "SSLCertificateFile", "SSLCertificateKeyFile")) {
    if ($config -match "(?m)^\s*$([regex]::Escape($forbiddenDirective))\b") {
      throw "M6y load-only probe config must not contain repository-serving or HTTPS directive $forbiddenDirective."
    }
  }

  $config | Set-Content -LiteralPath $configPath -Encoding ascii -NoNewline
  $httpdExe = Join-Path $stageRootResolved.Path "bin\httpd.exe"
  Assert-RequiredFile $httpdExe "staged Apache HTTP Server executable"

  $oldPath = $env:PATH
  try {
    $probePath = (Join-Path $stageRootResolved.Path "bin") + [IO.Path]::PathSeparator + (Join-Path $stageRootResolved.Path "modules")
    $env:PATH = $probePath
    $moduleOutput = & $httpdExe -M -d $stageRootResolved.Path -f $configPath 2>&1
    $moduleExitCode = $LASTEXITCODE
    if ($moduleExitCode -ne 0) {
      throw "Apache HTTP Server DAV module load probe failed with exit code $moduleExitCode`: $($moduleOutput | Out-String)"
    }

    $moduleOutputText = $moduleOutput | Out-String
    foreach ($requiredModule in @("dav_svn_module", "authz_svn_module")) {
      if (-not $moduleOutputText.Contains($requiredModule)) {
        throw "Apache HTTP Server DAV module load probe did not report $requiredModule."
      }
    }

    $syntaxOutput = & $httpdExe -t -d $stageRootResolved.Path -f $configPath 2>&1
    $syntaxExitCode = $LASTEXITCODE
    if ($syntaxExitCode -ne 0) {
      throw "Apache HTTP Server DAV module syntax probe failed with exit code $syntaxExitCode`: $($syntaxOutput | Out-String)"
    }
  }
  finally {
    $env:PATH = $oldPath
  }

  Write-Host "Verified source-built mod_dav_svn and mod_authz_svn load in staged Apache HTTP Server."
}

if (-not $VsDevCmd) {
  throw "VsDevCmd is required."
}

$dependencyStageRootResolved = Resolve-RequiredDirectory $DependencyStageRoot "DependencyStageRoot"
$httpdStageRootResolved = Resolve-RequiredDirectory $HttpdStageRoot "HttpdStageRoot"
$subversionStageRootResolved = Resolve-RequiredDirectory $SubversionStageRoot "SubversionStageRoot"
$cacheRootResolved = Resolve-RequiredDirectory $CacheRoot "CacheRoot"
$workRootResolved = Resolve-RepositoryPath $WorkRoot "WorkRoot"
$stageRootResolved = Resolve-RepositoryPath $StageRoot "StageRoot"

foreach ($protectedRoot in @(
  @{ Name = "DependencyStageRoot"; Value = $dependencyStageRootResolved },
  @{ Name = "HttpdStageRoot"; Value = $httpdStageRootResolved },
  @{ Name = "SubversionStageRoot"; Value = $subversionStageRootResolved },
  @{ Name = "CacheRoot"; Value = $cacheRootResolved }
)) {
  Assert-IndependentGeneratedRoot -Candidate $stageRootResolved -ExistingRoot $protectedRoot.Value -CandidateName "StageRoot" -ExistingName $protectedRoot.Name
  Assert-IndependentGeneratedRoot -Candidate $workRootResolved -ExistingRoot $protectedRoot.Value -CandidateName "WorkRoot" -ExistingName $protectedRoot.Name
}
Assert-IndependentGeneratedRoot -Candidate $workRootResolved -ExistingRoot $stageRootResolved -CandidateName "WorkRoot" -ExistingName "StageRoot"
Assert-RequiredFile $VsDevCmd "Visual Studio developer command"
Get-Command uv -ErrorAction Stop | Out-Null

Assert-SubversionDependencyStage -StageRoot $dependencyStageRootResolved | Out-Null
Assert-ApacheHttpdStageForDavFixture -StageRoot $httpdStageRootResolved -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch $Arch -ExpectedConfiguration $Configuration | Out-Null
Assert-SubversionStageForBridge -StageRoot $subversionStageRootResolved -WorkspaceRoot $repoRoot -SourceLockPath $lockPath -ExpectedArch $Arch -ExpectedConfiguration $Configuration | Out-Null

if (-not $SkipVerifySources) {
  & (Join-Path $PSScriptRoot "verify-sources.ps1")
}

$lock = Read-NativeSourceLock -Path $lockPath
$source = Get-NativeSourceEntry -Lock $lock -Name "apache-subversion"
$archivePath = Get-NativeArchivePath -CacheRoot $cacheRootResolved -Source $source -RequireExisting

Clear-NativeGeneratedDirectory -Path $workRootResolved -WorkspaceRoot $repoRoot -Description "Apache Subversion DAV module source work root" | Out-Null
Expand-Archive -LiteralPath $archivePath -DestinationPath $workRootResolved -Force

$sourceRoot = Join-Path $workRootResolved "subversion-1.14.5"
Assert-RequiredFile (Join-Path $sourceRoot "gen-make.py") "Subversion generator"
Update-SubversionGeneratorForExpat272 -SourceRoot $sourceRoot

$genMakeArgs = @(
  "-t", "vcproj",
  "--vsnet-version=$VsNetVersion",
  "--with-apr=$dependencyStageRootResolved",
  "--with-apr-util=$dependencyStageRootResolved",
  "--with-sqlite=$dependencyStageRootResolved",
  "--with-zlib=$dependencyStageRootResolved",
  "--with-serf=$dependencyStageRootResolved",
  "--with-openssl=$dependencyStageRootResolved",
  "--with-apr-iconv=$dependencyStageRootResolved",
  "--with-httpd=$httpdStageRootResolved"
)

Push-Location $sourceRoot
try {
  & uv run --no-project python gen-make.py @genMakeArgs
  if ($LASTEXITCODE -ne 0) {
    throw "gen-make.py failed with exit code $LASTEXITCODE."
  }
}
finally {
  Pop-Location
}

if ($GeneratedPlatformToolset -ne $PlatformToolset) {
  $retargetedProjects = @(Update-GeneratedVcxprojPlatformToolset `
    -SourceRoot $sourceRoot `
    -FromToolset $GeneratedPlatformToolset `
    -ToToolset $PlatformToolset)
  Write-Host "Retargeted $($retargetedProjects.Count) generated Subversion vcxproj files from $GeneratedPlatformToolset to $PlatformToolset."
}
else {
  Write-Host "Using generated Subversion vcxproj PlatformToolset $PlatformToolset."
}

$validatedProjects = @(Assert-GeneratedVcxprojPlatformToolset -SourceRoot $sourceRoot -ExpectedToolset $PlatformToolset)
Write-Host "Validated $($validatedProjects.Count) generated Subversion vcxproj files for PlatformToolset $PlatformToolset."
Assert-GeneratedSubversionRaSerfProjectGraph -SourceRoot $sourceRoot
Assert-GeneratedSubversionApacheModuleProjectGraph -SourceRoot $sourceRoot

$moduleProject = Join-Path $sourceRoot "build\win32\vcnet-vcproj\mod_authz_svn.vcxproj"
Assert-RequiredFile $moduleProject "generated mod_authz_svn.vcxproj"
$solutionPath = Join-Path $sourceRoot "subversion_vcnet.sln"
Assert-RequiredFile $solutionPath "generated Subversion solution"

$solutionDir = (ConvertTo-MsBuildPath $sourceRoot).TrimEnd("/") + "/"
$solutionPathForMsBuild = ConvertTo-MsBuildPath $solutionPath
$quotedVsDevCmd = Quote-CmdArgument $VsDevCmd
$quotedSourceRoot = Quote-CmdArgument $sourceRoot
$quotedModuleProject = Quote-CmdArgument $moduleProject
$quotedBuildLog = Quote-CmdArgument $buildLog
$quotedSolutionDir = Quote-CmdArgument $solutionDir
$quotedSolutionPath = Quote-CmdArgument $solutionPathForMsBuild
$cmd = "call $quotedVsDevCmd -arch=$Arch -host_arch=$Arch && cd /d $quotedSourceRoot && msbuild $quotedModuleProject /m /p:Configuration=$Configuration /p:Platform=$Arch /p:SolutionDir=$quotedSolutionDir /p:SolutionPath=$quotedSolutionPath /p:SolutionName=subversion_vcnet /fileLogger /fileLoggerParameters:LogFile=$quotedBuildLog;Verbosity=normal"

cmd.exe /d /s /c $cmd
if ($LASTEXITCODE -ne 0) {
  throw "Subversion DAV module build failed with exit code $LASTEXITCODE. See $buildLog"
}

$davStageRoot = Copy-ApacheHttpdSubversionDavStage `
  -HttpdStageRoot $httpdStageRootResolved `
  -DependencyStageRoot $dependencyStageRootResolved `
  -SubversionStageRoot $subversionStageRootResolved `
  -SourceRoot $sourceRoot `
  -StageRoot $stageRootResolved `
  -WorkspaceRoot $repoRoot `
  -SourceLockPath $lockPath `
  -Arch $Arch `
  -Configuration $Configuration

Invoke-SubversionDavModuleLoadProbe -StageRoot $davStageRoot -ProbeRoot (Join-Path $workRootResolved "probe")

Write-Host "Built Apache Subversion 1.14.5 DAV modules with configuration $Configuration for $Arch."
Write-Host "Staged Apache HTTPD/Subversion DAV module runtime to $davStageRoot."

[CmdletBinding()]
param(
  [string]$AprRoot,

  [string]$AprUtilRoot,

  [string]$SqliteRoot,

  [string]$ZlibRoot,

  [string]$SerfRoot,

  [string]$OpenSslRoot,

  [string]$AprIconvRoot,

  [string]$DependencyStageRoot,

  [string]$StageRoot,

  [ValidateSet("Release", "Debug")]
  [string]$Configuration = "Release",

  [ValidateSet("x64")]
  [string]$Arch = "x64",

  [string]$VsNetVersion = "2019",

  [string]$GeneratedPlatformToolset = "v142",

  [string]$PlatformToolset = "v143",

  [string]$BuildTarget = "__ALL__",

  [string]$VsDevCmd
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$modulePath = Join-Path $PSScriptRoot "SubversionR.Native.psm1"
Import-Module $modulePath -Force

$sourceRoot = Join-Path $repoRoot ".cache\native\work\subversion-1.14.5"
$archivePath = Join-Path $repoRoot ".cache\native\sources\subversion-1.14.5.zip"
$buildLog = Join-Path $repoRoot ".cache\native\subversion-build.log"
$lockPath = Join-Path $repoRoot "native\sources.lock.json"

function Resolve-RequiredDirectory([string]$Path, [string]$Name) {
  if (-not $Path) {
    throw "$Name is required."
  }

  $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
  if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
    throw "$Name must be a directory: $Path"
  }

  return $resolved.Path
}

function Assert-RequiredFile([string]$Path, [string]$Description) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Missing $Description`: $Path"
  }
}

function Quote-CmdArgument([string]$Value) {
  return '"' + $Value.Replace('"', '\"') + '"'
}

function Assert-SameResolvedDirectory([string]$Actual, [string]$Expected, [string]$Name) {
  $actualNormalized = $Actual.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  $expectedNormalized = $Expected.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  if (-not [string]::Equals($actualNormalized, $expectedNormalized, [StringComparison]::OrdinalIgnoreCase)) {
    throw "$Name must resolve to DependencyStageRoot because the current Subversion bridge stage copies native dependencies from that single verified stage."
  }
}

$aprRootResolved = Resolve-RequiredDirectory $AprRoot "AprRoot"
$aprUtilRootResolved = Resolve-RequiredDirectory $AprUtilRoot "AprUtilRoot"
$sqliteRootResolved = Resolve-RequiredDirectory $SqliteRoot "SqliteRoot"
$zlibRootResolved = Resolve-RequiredDirectory $ZlibRoot "ZlibRoot"
$serfRootResolved = Resolve-RequiredDirectory $SerfRoot "SerfRoot"
$openSslRootResolved = Resolve-RequiredDirectory $OpenSslRoot "OpenSslRoot"
$aprIconvRootResolved = Resolve-RequiredDirectory $AprIconvRoot "AprIconvRoot"
$dependencyStageRootResolved = Resolve-RequiredDirectory $DependencyStageRoot "DependencyStageRoot"
if (-not $StageRoot) {
  throw "StageRoot is required."
}

foreach ($dependencyRoot in @(
  @{ Name = "AprRoot"; Value = $aprRootResolved },
  @{ Name = "AprUtilRoot"; Value = $aprUtilRootResolved },
  @{ Name = "AprIconvRoot"; Value = $aprIconvRootResolved },
  @{ Name = "SqliteRoot"; Value = $sqliteRootResolved },
  @{ Name = "ZlibRoot"; Value = $zlibRootResolved },
  @{ Name = "SerfRoot"; Value = $serfRootResolved },
  @{ Name = "OpenSslRoot"; Value = $openSslRootResolved }
)) {
  Assert-SameResolvedDirectory $dependencyRoot.Value $dependencyStageRootResolved $dependencyRoot.Name
}

if (-not $VsDevCmd) {
  throw "VsDevCmd is required."
}

Assert-SubversionDependencyStage -StageRoot $dependencyStageRootResolved | Out-Null
Assert-AprStageForSubversion -StageRoot $aprRootResolved | Out-Null
Assert-AprStageForSubversion -StageRoot $aprUtilRootResolved | Out-Null
Assert-AprStageForSubversion -StageRoot $aprIconvRootResolved | Out-Null
Assert-ZlibStageForSubversion -StageRoot $zlibRootResolved | Out-Null
Assert-SqliteStageForSubversion -StageRoot $sqliteRootResolved | Out-Null
Assert-SerfStageForSubversion -StageRoot $serfRootResolved -ExpectedVersion "1.3.10" | Out-Null
Assert-OpenSslStageForSerf -StageRoot $openSslRootResolved -ExpectedVersion "3.5.7" | Out-Null

Assert-RequiredFile $VsDevCmd "Visual Studio developer command"
Get-Command uv -ErrorAction Stop | Out-Null

$genMakeArgs = @(
  "-t", "vcproj",
  "--vsnet-version=$VsNetVersion",
  "--with-apr=$aprRootResolved",
  "--with-apr-util=$aprUtilRootResolved",
  "--with-sqlite=$sqliteRootResolved",
  "--with-zlib=$zlibRootResolved",
  "--with-serf=$serfRootResolved",
  "--with-openssl=$openSslRootResolved",
  "--with-apr-iconv=$aprIconvRootResolved"
)

& (Join-Path $PSScriptRoot "verify-sources.ps1")

if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
  throw "Verified source archive is missing: $archivePath"
}

$workRoot = Split-Path -Parent $sourceRoot
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
Clear-NativeGeneratedDirectory -Path $sourceRoot -WorkspaceRoot $repoRoot -Description "Apache Subversion source tree" | Out-Null
Expand-Archive -LiteralPath $archivePath -DestinationPath $workRoot -Force

Assert-RequiredFile (Join-Path $sourceRoot "gen-make.py") "Subversion generator"
Update-SubversionGeneratorForExpat272 -SourceRoot $sourceRoot

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

$quotedVsDevCmd = Quote-CmdArgument $VsDevCmd
$quotedSourceRoot = Quote-CmdArgument $sourceRoot
$quotedBuildLog = Quote-CmdArgument $buildLog
$cmd = "call $quotedVsDevCmd -arch=$Arch -host_arch=$Arch && cd /d $quotedSourceRoot && msbuild subversion_vcnet.sln /m /p:Configuration=$Configuration /p:Platform=$Arch /t:$BuildTarget /fileLogger /fileLoggerParameters:LogFile=$quotedBuildLog;Verbosity=normal"

cmd.exe /d /s /c $cmd
if ($LASTEXITCODE -ne 0) {
  throw "Subversion build failed with exit code $LASTEXITCODE. See $buildLog"
}

$subversionStageRoot = Copy-SubversionBuildStage `
  -SourceRoot $sourceRoot `
  -DependencyStageRoot $dependencyStageRootResolved `
  -StageRoot $StageRoot `
  -WorkspaceRoot $repoRoot `
  -SourceLockPath $lockPath `
  -Arch $Arch `
  -Configuration $Configuration

Assert-SubversionRaSerfRegistration -StageRoot $subversionStageRoot

Write-Host "Built Apache Subversion 1.14.5 with configuration $Configuration for $Arch."
Write-Host "Staged Apache Subversion 1.14.5 bridge runtime to $subversionStageRoot."

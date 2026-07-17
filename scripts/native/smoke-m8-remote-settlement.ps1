[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("cram", "basic", "ra-open", "proxy")]
  [string]$Mode,

  [Parameter(Mandatory = $true)]
  [string]$SubversionStageRoot,

  [Parameter(Mandatory = $true)]
  [string]$Url,

  [Parameter(Mandatory = $true)]
  [string]$VsDevCmd,

  [string]$Username,

  [string]$PasswordEnvironmentVariable,

  [string]$NextUsername,

  [string]$NextPasswordEnvironmentVariable,

  [string]$TlsAcceptedFailures,

  [ValidateSet("Release", "Debug")]
  [string]$Configuration = "Release",

  [ValidateSet("x64")]
  [string]$Arch = "x64"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..") -ErrorAction Stop).Path
$modulePath = Join-Path $PSScriptRoot "SubversionR.Native.psm1"
$sourceRoot = Join-Path $repoRoot "native\feasibility\m8-remote-settlement"
$sourceLockPath = Join-Path $repoRoot "native\sources.lock.json"
Import-Module $modulePath -Force

function Assert-RequiredFile([string]$Path, [string]$Description) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Missing $Description`: $Path"
  }
}

function Quote-CmdArgument([string]$Value) {
  return '"' + $Value.Replace('"', '\"') + '"'
}

function Assert-CredentialEnvironmentVariable([string]$Name) {
  if ($Name -notmatch '^SUBVERSIONR_M8_[A-Z0-9_]+$') {
    throw "Credential environment variable names must match SUBVERSIONR_M8_[A-Z0-9_]+."
  }
  if ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::Process))) {
    throw "A credential environment variable is missing or empty."
  }
}

$parsedUrl = $null
foreach ($character in $Url.ToCharArray()) {
  if ([char]::IsControl($character)) {
    throw "Url must not contain control characters."
  }
}
if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$parsedUrl)) {
  throw "Url must be an absolute URI."
}
if (-not [string]::IsNullOrEmpty($parsedUrl.UserInfo)) {
  throw "Url must not contain user information."
}

$scheme = $parsedUrl.Scheme.ToLowerInvariant()
if ($Mode -eq "cram" -and $scheme -ne "svn") {
  throw "CRAM mode requires an svn URL."
}
if (($Mode -eq "basic" -or $Mode -eq "proxy") -and $scheme -notin @("http", "https")) {
  throw "Mode '$Mode' requires an HTTP or HTTPS URL."
}
if ($Mode -eq "ra-open" -and $scheme -notin @("svn", "http", "https")) {
  throw "RA-open mode requires an svn, HTTP, or HTTPS URL."
}

$hasUsername = $PSBoundParameters.ContainsKey("Username") -and -not [string]::IsNullOrEmpty($Username)
$hasPasswordEnvironmentVariable = $PSBoundParameters.ContainsKey("PasswordEnvironmentVariable") -and -not [string]::IsNullOrEmpty($PasswordEnvironmentVariable)
$hasNextUsername = $PSBoundParameters.ContainsKey("NextUsername") -and -not [string]::IsNullOrEmpty($NextUsername)
$hasNextPasswordEnvironmentVariable = $PSBoundParameters.ContainsKey("NextPasswordEnvironmentVariable") -and -not [string]::IsNullOrEmpty($NextPasswordEnvironmentVariable)

if ($hasUsername -ne $hasPasswordEnvironmentVariable) {
  throw "Username and PasswordEnvironmentVariable must be supplied together."
}
if ($hasNextUsername -ne $hasNextPasswordEnvironmentVariable) {
  throw "NextUsername and NextPasswordEnvironmentVariable must be supplied together."
}
if ($hasNextUsername -and -not $hasUsername) {
  throw "The next credential requires the first credential."
}
if (($Mode -eq "cram" -or $Mode -eq "basic") -and -not $hasUsername) {
  throw "Mode '$Mode' requires Username and PasswordEnvironmentVariable."
}
if ($hasPasswordEnvironmentVariable) {
  Assert-CredentialEnvironmentVariable $PasswordEnvironmentVariable
}
if ($hasNextPasswordEnvironmentVariable) {
  Assert-CredentialEnvironmentVariable $NextPasswordEnvironmentVariable
}
if ($Mode -eq "cram" -and $PSBoundParameters.ContainsKey("TlsAcceptedFailures")) {
  throw "CRAM mode does not accept TLS failure decisions."
}

$parsedTlsFailures = [uint32]0
if ($PSBoundParameters.ContainsKey("TlsAcceptedFailures")) {
  $parsed = [uint32]::TryParse(
    $TlsAcceptedFailures,
    [Globalization.NumberStyles]::None,
    [Globalization.CultureInfo]::InvariantCulture,
    [ref]$parsedTlsFailures
  )
  if (-not $parsed -or $parsedTlsFailures -eq 0) {
    throw "TlsAcceptedFailures must be a positive uint32 decimal bit mask."
  }
  if ($scheme -ne "https") {
    throw "TlsAcceptedFailures requires an HTTPS URL."
  }
}

if ($Mode -eq "proxy") {
  Write-Output (@{
    event = "source.blocker"
    kind = "proxy-settlement"
    lockedSource = "serf-1.3.10/ssltunnel.c::handle_response"
    transition = "CONNECT-2xx-sets-SERF_CONN_CONNECTED"
    missingHook = "application-callback-with-proxy-authority-and-current-credential-attempt"
    controlledProxyMatrix = "not-executed"
  } | ConvertTo-Json -Compress)
  throw "Proxy settlement is blocked: locked Serf exposes no application callback for the accepted CONNECT transition, and the controlled proxy matrix has not run."
}

if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
  throw "cmake is required to build the M8 remote settlement probe."
}

Assert-RequiredFile $VsDevCmd "Visual Studio developer command"
Assert-RequiredFile (Join-Path $sourceRoot "CMakeLists.txt") "M8 probe CMake project"
Assert-RequiredFile (Join-Path $sourceRoot "probe.c") "M8 probe source"

$stageRootResolved = (Resolve-Path -LiteralPath $SubversionStageRoot -ErrorAction Stop).Path
Assert-SubversionStageForBridge `
  -StageRoot $stageRootResolved `
  -WorkspaceRoot $repoRoot `
  -SourceLockPath $sourceLockPath `
  -ExpectedArch $Arch `
  -ExpectedConfiguration $Configuration | Out-Null

$buildRoot = Join-Path $repoRoot "target\native\m8-remote-settlement\$Arch\$Configuration"
Clear-NativeGeneratedDirectory `
  -Path $buildRoot `
  -WorkspaceRoot $repoRoot `
  -Description "M8 remote settlement probe build directory" | Out-Null

$configureCommand = "call $(Quote-CmdArgument $VsDevCmd) -arch=$Arch -host_arch=$Arch && " +
  "cmake -S $(Quote-CmdArgument $sourceRoot) -B $(Quote-CmdArgument $buildRoot) " +
  "-G `"Visual Studio 17 2022`" -A $Arch " +
  "-DSVN_ROOT=$(Quote-CmdArgument $stageRootResolved)"
cmd.exe /d /s /c $configureCommand
if ($LASTEXITCODE -ne 0) {
  throw "M8 remote settlement probe configuration failed with exit code $LASTEXITCODE."
}

$buildCommand = "call $(Quote-CmdArgument $VsDevCmd) -arch=$Arch -host_arch=$Arch && " +
  "cmake --build $(Quote-CmdArgument $buildRoot) --config $Configuration --parallel"
cmd.exe /d /s /c $buildCommand
if ($LASTEXITCODE -ne 0) {
  throw "M8 remote settlement probe build failed with exit code $LASTEXITCODE."
}

$probeExe = Join-Path $buildRoot "$Configuration\m8_remote_settlement_probe.exe"
Assert-RequiredFile $probeExe "M8 remote settlement probe executable"

$probeArguments = @("--mode", $Mode, "--url", $Url)
if ($hasUsername) {
  $probeArguments += @("--credential-env", $Username, $PasswordEnvironmentVariable)
}
if ($hasNextUsername) {
  $probeArguments += @("--credential-env", $NextUsername, $NextPasswordEnvironmentVariable)
}
if ($parsedTlsFailures -ne 0) {
  $probeArguments += @("--accept-tls-failures", $parsedTlsFailures.ToString([Globalization.CultureInfo]::InvariantCulture))
}

$previousPath = $env:PATH
try {
  $env:PATH = "$(Join-Path $stageRootResolved 'bin');$previousPath"
  & $probeExe @probeArguments
  if ($LASTEXITCODE -ne 0) {
    throw "M8 remote settlement probe failed with exit code $LASTEXITCODE."
  }
}
finally {
  $env:PATH = $previousPath
}

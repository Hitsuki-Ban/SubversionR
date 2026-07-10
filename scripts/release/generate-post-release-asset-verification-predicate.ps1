[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$ContractPath,

  [Parameter(Mandatory = $true)]
  [string]$SubjectPath,

  [Parameter(Mandatory = $true)]
  [string]$ReleaseTag,

  [Parameter(Mandatory = $true)]
  [string]$OutputPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")

function Get-RepoAbsolutePath([string]$Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Get-RepoRelativePath([string]$Path) {
  [System.IO.Path]::GetRelativePath($repoRoot, $Path).Replace("\", "/")
}

function Test-IsPathWithin([string]$Path, [string]$Root) {
  $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  $pathFull = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  $pathFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-GeneratedPath([string]$Path, [string]$Name) {
  $absolute = Get-RepoAbsolutePath $Path
  foreach ($allowedRoot in @(
      [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-attestation")),
      [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-live-attestation-scripts"))
    )) {
    if (Test-IsPathWithin -Path $absolute -Root $allowedRoot) {
      return $absolute
    }
  }
  throw "$Name must resolve inside target/release-attestation or target/tests/release-live-attestation-scripts: $Path"
}

function Assert-File([string]$Path, [string]$Name) {
  $absolute = Get-RepoAbsolutePath $Path
  if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) {
    throw "$Name must be a file: $Path"
  }
  (Resolve-Path -LiteralPath $absolute -ErrorAction Stop).Path
}

function Get-Sha256([string]$Path) {
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-RequiredProperty([object]$Object, [string]$Name, [string]$Context) {
  if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) {
    throw "$Context must define $Name."
  }
  $Object.$Name
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
  if ($Expected -ne $Actual) {
    throw "$Message Expected '$Expected', got '$Actual'."
  }
}

$contractResolved = Assert-File $ContractPath "ContractPath"
$subjectResolved = Assert-GeneratedPath $SubjectPath "SubjectPath"
if (-not (Test-Path -LiteralPath $subjectResolved -PathType Leaf)) {
  throw "SubjectPath must be a file: $SubjectPath"
}
$outputResolved = Assert-GeneratedPath $OutputPath "OutputPath"

& (Join-Path $PSScriptRoot "verify-release-attestation-subject.ps1") `
  -Target $Target `
  -ContractPath $contractResolved `
  -SubjectPath $subjectResolved `
  -ReleaseTag $ReleaseTag

$contract = Get-Content -Raw -LiteralPath $contractResolved | ConvertFrom-Json
$subject = Get-RequiredProperty $contract "subject" "Attestation contract"
$predicate = [ordered]@{
  schemaVersion = 1
  schema = "subversionr.release.post-release-asset-verification-predicate.v1"
  claim = "post-release-asset-digest-verification"
  originalBuildProvenanceClaim = $false
  artifactSignatureClaim = $false
  release = [ordered]@{
    tag = $ReleaseTag
    url = [string](Get-RequiredProperty (Get-RequiredProperty $contract "release" "Attestation contract") "url" "Attestation contract release")
    assetName = [string](Get-RequiredProperty $subject "name" "Attestation contract subject")
    assetSize = [int64](Get-RequiredProperty $subject "size" "Attestation contract subject")
    assetSha256 = [string](Get-RequiredProperty $subject "sha256" "Attestation contract subject")
  }
  contract = [ordered]@{
    path = Get-RepoRelativePath $contractResolved
    sha256 = Get-Sha256 $contractResolved
  }
  verification = [ordered]@{
    assetDownloadedFromRelease = $true
    subjectNameMatched = $true
    subjectSizeMatched = $true
    subjectSha256Matched = $true
  }
}

Assert-Equal ([string]$subject.name) (Split-Path -Leaf $subjectResolved) "Predicate subject name must match current bytes."
Assert-Equal ([int64]$subject.size) ([int64](Get-Item -LiteralPath $subjectResolved).Length) "Predicate subject size must match current bytes."
Assert-Equal ([string]$subject.sha256) (Get-Sha256 $subjectResolved) "Predicate subject SHA256 must match current bytes."

$outputParent = Split-Path -Parent $outputResolved
New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
$predicate | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outputResolved -Encoding utf8

Write-Host "Generated SubversionR post-release asset verification predicate for $Target at $outputResolved."

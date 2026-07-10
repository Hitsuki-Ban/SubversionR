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
  [string]$BundlePath,

  [Parameter(Mandatory = $true)]
  [string]$VerificationResultPath,

  [Parameter(Mandatory = $true)]
  [string]$RunId,

  [Parameter(Mandatory = $true)]
  [int]$RunAttempt,

  [Parameter(Mandatory = $true)]
  [string]$RunUrl,

  [Parameter(Mandatory = $true)]
  [string]$HeadSha,

  [Parameter(Mandatory = $true)]
  [string]$SourceRef,

  [Parameter(Mandatory = $true)]
  [string]$EventName,

  [Parameter(Mandatory = $true)]
  [string]$AttestationId,

  [Parameter(Mandatory = $true)]
  [string]$AttestationUrl,

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

function Assert-GeneratedPath([string]$Path, [string]$Name, [string[]]$AllowedRoots, [string]$Description) {
  $absolute = Get-RepoAbsolutePath $Path
  foreach ($allowedRoot in $AllowedRoots) {
    if (Test-IsPathWithin -Path $absolute -Root $allowedRoot) {
      return $absolute
    }
  }
  throw "$Name must resolve inside $Description`: $Path"
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

function Assert-Equal($Expected, $Actual, [string]$Message) {
  if ($Expected -ne $Actual) {
    throw "$Message Expected '$Expected', got '$Actual'."
  }
}

$contractResolved = Assert-File $ContractPath "ContractPath"
$subjectResolved = Assert-GeneratedPath -Path $SubjectPath -Name "SubjectPath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-attestation")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-live-attestation-scripts"))
) -Description "target/release-attestation or target/tests/release-live-attestation-scripts"
if (-not (Test-Path -LiteralPath $subjectResolved -PathType Leaf)) {
  throw "SubjectPath must be a file: $SubjectPath"
}
$bundleResolved = Assert-File $BundlePath "BundlePath"
$verificationResolved = Assert-GeneratedPath -Path $VerificationResultPath -Name "VerificationResultPath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-live-attestation-scripts"))
) -Description "target/release-evidence or target/tests/release-live-attestation-scripts"
if (-not (Test-Path -LiteralPath $verificationResolved -PathType Leaf)) {
  throw "VerificationResultPath must be a file: $VerificationResultPath"
}
$outputResolved = Assert-GeneratedPath -Path $OutputPath -Name "OutputPath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-live-attestation-scripts"))
) -Description "target/release-evidence or target/tests/release-live-attestation-scripts"

& (Join-Path $PSScriptRoot "verify-release-attestation-subject.ps1") `
  -Target $Target `
  -ContractPath $contractResolved `
  -SubjectPath $subjectResolved `
  -ReleaseTag $ReleaseTag

$contract = Get-Content -Raw -LiteralPath $contractResolved | ConvertFrom-Json
$verificationResults = @(Get-Content -Raw -LiteralPath $verificationResolved | ConvertFrom-Json)
if ($verificationResults.Count -lt 1) {
  throw "Verification result must contain at least one verified attestation."
}
$matchingStatements = @(
  foreach ($result in $verificationResults) {
    $statement = $result.verificationResult.statement
    foreach ($verifiedSubject in @($statement.subject)) {
      if (
        [string]$statement.predicateType -eq [string]$contract.verificationPolicy.predicateType -and
        [string]$verifiedSubject.name -eq [string]$contract.subject.name -and
        [string]$verifiedSubject.digest.sha256 -eq [string]$contract.subject.sha256
      ) {
        $statement
      }
    }
  }
)
if ($matchingStatements.Count -lt 1) {
  throw "Verification result must bind the contracted subject and predicate type."
}

if ($RunId -notmatch '^[0-9]+$') {
  throw "RunId must contain only digits."
}
if ($RunAttempt -lt 1) {
  throw "RunAttempt must be positive."
}
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/$RunId" $RunUrl "RunUrl must match RunId."
if ($HeadSha -notmatch '^[a-f0-9]{40}$') {
  throw "HeadSha must be a full lowercase commit SHA."
}
if ([string]::IsNullOrWhiteSpace($SourceRef)) {
  throw "SourceRef must be recorded."
}
Assert-Equal "workflow_dispatch" $EventName "Live attestation must originate from workflow_dispatch."
if ($AttestationId -notmatch '^[0-9]+$') {
  throw "AttestationId must contain only digits."
}
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/attestations/$AttestationId" $AttestationUrl "AttestationUrl must match AttestationId."

$verificationCommand = "gh attestation verify $((Get-RepoRelativePath $subjectResolved)) -R $($contract.verificationPolicy.repository) --signer-workflow $($contract.verificationPolicy.signerWorkflow) --predicate-type $($contract.verificationPolicy.predicateType) --deny-self-hosted-runners --format json"
$evidence = [pscustomobject]@{
  schemaVersion = 1
  schema = "subversionr.release.live-github-attestation.win32-x64.v1"
  publicReadinessClaim = $false
  signingClaim = $false
  target = $Target
  status = "live-attestation-verified"
  generatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
  contract = [pscustomobject]@{
    path = Get-RepoRelativePath $contractResolved
    sha256 = Get-Sha256 $contractResolved
    schema = [string]$contract.schema
  }
  release = [pscustomobject]@{
    tag = $ReleaseTag
    url = [string]$contract.release.url
  }
  subject = [pscustomobject]@{
    name = [string]$contract.subject.name
    path = Get-RepoRelativePath $subjectResolved
    size = [int64](Get-Item -LiteralPath $subjectResolved).Length
    sha256 = Get-Sha256 $subjectResolved
  }
  workflow = [pscustomobject]@{
    path = [string]$contract.workflow.path
    event = $EventName
    runId = $RunId
    runAttempt = $RunAttempt
    runUrl = $RunUrl
    headSha = $HeadSha
    sourceRef = $SourceRef
  }
  attestation = [pscustomobject]@{
    provider = [string]$contract.attestation.provider
    action = [string]$contract.attestation.action
    predicateType = [string]$contract.attestation.predicateType
    id = $AttestationId
    url = $AttestationUrl
    bundleFileName = Split-Path -Leaf $bundleResolved
    bundleSha256 = Get-Sha256 $bundleResolved
  }
  verification = [pscustomobject]@{
    verified = $true
    repository = [string]$contract.verificationPolicy.repository
    signerWorkflow = [string]$contract.verificationPolicy.signerWorkflow
    predicateType = [string]$contract.verificationPolicy.predicateType
    denySelfHostedRunners = [bool]$contract.verificationPolicy.denySelfHostedRunners
    format = [string]$contract.verificationPolicy.format
    command = $verificationCommand
    resultPath = Get-RepoRelativePath $verificationResolved
    resultSha256 = Get-Sha256 $verificationResolved
  }
  nonClaims = @(
    "This evidence does not claim that the released VSIX is signed.",
    "This evidence does not claim Marketplace publication or public install.",
    "This evidence does not claim previous-stable rollback.",
    "This evidence does not claim public release readiness."
  )
}

$outputParent = Split-Path -Parent $outputResolved
New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
$evidence | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $outputResolved -Encoding utf8

Write-Host "Recorded SubversionR live GitHub attestation evidence for $Target at $outputResolved."

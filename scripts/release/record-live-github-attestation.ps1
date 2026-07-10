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

function Test-HasProperty([object]$Object, [string]$Name) {
  $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Get-RequiredProperty([object]$Object, [string]$Name, [string]$Context) {
  if (-not (Test-HasProperty $Object $Name)) {
    throw "$Context must define $Name."
  }
  $Object.$Name
}

function ConvertTo-CanonicalJson([object]$Value) {
  $Value | ConvertTo-Json -Depth 100 -Compress
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
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-live-attestation-scripts")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "docs\release"))
) -Description "target/release-evidence, target/tests/release-live-attestation-scripts, or docs/release"
if (-not (Test-Path -LiteralPath $verificationResolved -PathType Leaf)) {
  throw "VerificationResultPath must be a file: $VerificationResultPath"
}
$outputResolved = Assert-GeneratedPath -Path $OutputPath -Name "OutputPath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-live-attestation-scripts")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "docs\release"))
) -Description "target/release-evidence, target/tests/release-live-attestation-scripts, or docs/release"

& (Join-Path $PSScriptRoot "verify-release-attestation-subject.ps1") `
  -Target $Target `
  -ContractPath $contractResolved `
  -SubjectPath $subjectResolved `
  -ReleaseTag $ReleaseTag

$contract = Get-Content -Raw -LiteralPath $contractResolved | ConvertFrom-Json
$bundles = @(Get-Content -Raw -LiteralPath $bundleResolved | ConvertFrom-Json)
if ($bundles.Count -ne 1) {
  throw "BundlePath must contain exactly one attestation bundle."
}
$bundle = $bundles[0]
$verificationResults = @(Get-Content -Raw -LiteralPath $verificationResolved | ConvertFrom-Json)
if ($verificationResults.Count -ne 1) {
  throw "Verification result must contain exactly one verified attestation."
}
$verificationResult = $verificationResults[0]
$verifiedAttestation = Get-RequiredProperty $verificationResult "attestation" "Verification result"
$verifiedBundle = Get-RequiredProperty $verifiedAttestation "bundle" "Verification result attestation"
Assert-Equal (ConvertTo-CanonicalJson $bundle) (ConvertTo-CanonicalJson $verifiedBundle) "Verification result must contain the exact BundlePath attestation."
$verifiedDetails = Get-RequiredProperty $verificationResult "verificationResult" "Verification result"
$statement = Get-RequiredProperty $verifiedDetails "statement" "Verification result details"
$certificate = Get-RequiredProperty (Get-RequiredProperty $verifiedDetails "signature" "Verification result details") "certificate" "Verification result signature"
$expectedSignerIdentity = "https://github.com/$($contract.verificationPolicy.signerWorkflow)@$SourceRef"
Assert-Equal $expectedSignerIdentity ([string](Get-RequiredProperty $certificate "subjectAlternativeName" "Verification certificate")) "Verification certificate signer identity must match the contract and source ref."
Assert-Equal ([string]$contract.verificationPolicy.repository) ([string](Get-RequiredProperty $certificate "githubWorkflowRepository" "Verification certificate")) "Verification certificate repository must match the contract."
Assert-Equal "workflow_dispatch" ([string](Get-RequiredProperty $certificate "githubWorkflowTrigger" "Verification certificate")) "Verification certificate trigger must be workflow_dispatch."
Assert-Equal "github-hosted" ([string](Get-RequiredProperty $certificate "runnerEnvironment" "Verification certificate")) "Verification certificate runner must be GitHub-hosted."
Assert-Equal "public" ([string](Get-RequiredProperty $certificate "sourceRepositoryVisibilityAtSigning" "Verification certificate")) "Verification certificate must record public source visibility."
Assert-Equal $HeadSha ([string](Get-RequiredProperty $certificate "githubWorkflowSHA" "Verification certificate")) "Verification certificate workflow SHA must match HeadSha."
Assert-Equal $HeadSha ([string](Get-RequiredProperty $certificate "buildSignerDigest" "Verification certificate")) "Verification certificate signer digest must match HeadSha."
Assert-Equal $HeadSha ([string](Get-RequiredProperty $certificate "sourceRepositoryDigest" "Verification certificate")) "Verification certificate source digest must match HeadSha."
Assert-Equal $SourceRef ([string](Get-RequiredProperty $certificate "githubWorkflowRef" "Verification certificate")) "Verification certificate workflow ref must match SourceRef."
Assert-Equal "$RunUrl/attempts/$RunAttempt" ([string](Get-RequiredProperty $certificate "runInvocationURI" "Verification certificate")) "Verification certificate run URI must match the recorded run attempt."
if (@(Get-RequiredProperty $verifiedDetails "verifiedTimestamps" "Verification result details").Count -lt 1) {
  throw "Verification result must contain at least one verified timestamp."
}
$matchingStatements = @(
  foreach ($verifiedSubject in @($statement.subject)) {
    if (
      [string]$statement.predicateType -eq [string]$contract.verificationPolicy.predicateType -and
      [string]$verifiedSubject.name -eq [string]$contract.subject.name -and
      [string]$verifiedSubject.digest.sha256 -eq [string]$contract.subject.sha256
    ) {
      $statement
    }
  }
)
if ($matchingStatements.Count -ne 1) {
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

$verificationCommand = "gh attestation verify $((Get-RepoRelativePath $subjectResolved)) -R $($contract.verificationPolicy.repository) --bundle $((Get-RepoRelativePath $bundleResolved)) --signer-workflow $($contract.verificationPolicy.signerWorkflow) --signer-digest $HeadSha --source-ref $SourceRef --source-digest $HeadSha --predicate-type $($contract.verificationPolicy.predicateType) --deny-self-hosted-runners --format json"
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
    actionDigest = [string]$contract.attestation.actionDigest
    predicateType = [string]$contract.attestation.predicateType
    id = $AttestationId
    url = $AttestationUrl
    outputSource = "actions/attest-build-provenance outputs"
    bundlePath = Get-RepoRelativePath $bundleResolved
    bundleSha256 = Get-Sha256 $bundleResolved
  }
  verification = [pscustomobject]@{
    verified = $true
    repository = [string]$contract.verificationPolicy.repository
    signerWorkflow = [string]$contract.verificationPolicy.signerWorkflow
    predicateType = [string]$contract.verificationPolicy.predicateType
    denySelfHostedRunners = [bool]$contract.verificationPolicy.denySelfHostedRunners
    format = [string]$contract.verificationPolicy.format
    bundleMatched = $true
    command = $verificationCommand
    resultPath = Get-RepoRelativePath $verificationResolved
    resultSha256 = Get-Sha256 $verificationResolved
    certificate = [pscustomobject]@{
      signerIdentity = [string]$certificate.subjectAlternativeName
      workflowSha = [string]$certificate.githubWorkflowSHA
      workflowRef = [string]$certificate.githubWorkflowRef
      runnerEnvironment = [string]$certificate.runnerEnvironment
      runInvocationUrl = [string]$certificate.runInvocationURI
      sourceVisibility = [string]$certificate.sourceRepositoryVisibilityAtSigning
    }
  }
  nonClaims = @(
    "This evidence does not claim that the released VSIX is signed.",
    "This post-release attestation does not prove the original VSIX source-to-binary build provenance.",
    "This evidence does not claim Marketplace publication or public install.",
    "This evidence does not claim previous-stable rollback.",
    "This evidence does not claim public release readiness."
  )
}

$outputParent = Split-Path -Parent $outputResolved
New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
$evidence | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $outputResolved -Encoding utf8

Write-Host "Recorded SubversionR live GitHub attestation evidence for $Target at $outputResolved."

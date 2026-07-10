[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$ContractPath,

  [Parameter(Mandatory = $true)]
  [string]$LiveAttestationEvidencePath,

  [Parameter(Mandatory = $true)]
  [string]$AttestationVerificationResultPath,

  [Parameter(Mandatory = $true)]
  [string]$VsixPath,

  [Parameter(Mandatory = $true)]
  [string]$ReleaseTag,

  [Parameter(Mandatory = $true)]
  [string]$ExtensionId,

  [Parameter(Mandatory = $true)]
  [string]$ExtensionVersion,

  [Parameter(Mandatory = $true)]
  [string]$Repository,

  [Parameter(Mandatory = $true)]
  [string]$WorkflowPath,

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
  [string]$OutputPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$testRoot = Join-Path $repoRoot "target\tests\release-marketplace-publication-scripts"
$publicationRoot = Join-Path $repoRoot "target\marketplace-publication"
$evidenceRoot = Join-Path $repoRoot "target\release-evidence"

function Test-IsPathWithin([string]$Path, [string]$Root) {
  $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  $pathFull = [System.IO.Path]::GetFullPath($Path)
  $pathFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-RepoAbsolutePath([string]$Path, [string]$Name) {
  $absolute = if ([System.IO.Path]::IsPathRooted($Path)) {
    [System.IO.Path]::GetFullPath($Path)
  }
  else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
  }
  if (-not (Test-IsPathWithin -Path $absolute -Root $repoRoot)) {
    throw "$Name must resolve inside the repository: $Path"
  }
  $absolute
}

function Assert-InputFile([string]$Path, [string]$Name) {
  $absolute = Get-RepoAbsolutePath $Path $Name
  if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) {
    throw "$Name must be a file: $Path"
  }
  (Resolve-Path -LiteralPath $absolute).Path
}

function Assert-GeneratedInputFile([string]$Path, [string]$Name) {
  $absolute = Assert-InputFile $Path $Name
  if (-not (Test-IsPathWithin $absolute $publicationRoot) -and -not (Test-IsPathWithin $absolute $testRoot)) {
    throw "$Name must resolve inside target/marketplace-publication or target/tests/release-marketplace-publication-scripts: $Path"
  }
  $absolute
}

function Assert-OutputPath([string]$Path) {
  $absolute = Get-RepoAbsolutePath $Path "OutputPath"
  if (-not (Test-IsPathWithin $absolute $evidenceRoot) -and -not (Test-IsPathWithin $absolute $testRoot)) {
    throw "OutputPath must resolve inside target/release-evidence or target/tests/release-marketplace-publication-scripts: $Path"
  }
  $absolute
}

function Get-RepoRelativePath([string]$Path) {
  [System.IO.Path]::GetRelativePath($repoRoot, $Path).Replace("\", "/")
}

function Get-Sha256([string]$Path) {
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
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

function Assert-Equal($Expected, $Actual, [string]$Message) {
  if ($Expected -ne $Actual) {
    throw "$Message Expected '$Expected', got '$Actual'."
  }
}

function Assert-JsonBoolean([object]$Object, [string]$Name, [bool]$Expected, [string]$Context) {
  $value = Get-RequiredProperty $Object $Name $Context
  if ($value -isnot [bool]) {
    throw "$Context $Name must be a JSON boolean."
  }
  Assert-Equal $Expected ([bool]$value) "$Context $Name must match."
}

function Get-ZipEntryText([System.IO.Compression.ZipArchive]$Archive, [string]$EntryName) {
  $entries = @($Archive.Entries | Where-Object { $_.FullName -ceq $EntryName })
  if ($entries.Count -ne 1) {
    throw "VSIX must contain exactly one $EntryName."
  }
  $reader = [System.IO.StreamReader]::new($entries[0].Open())
  try {
    $reader.ReadToEnd()
  }
  finally {
    $reader.Dispose()
  }
}

$contractResolved = Assert-InputFile $ContractPath "ContractPath"
$liveEvidenceResolved = Assert-InputFile $LiveAttestationEvidencePath "LiveAttestationEvidencePath"
$verificationResolved = Assert-GeneratedInputFile $AttestationVerificationResultPath "AttestationVerificationResultPath"
$vsixResolved = Assert-GeneratedInputFile $VsixPath "VsixPath"
$outputResolved = Assert-OutputPath $OutputPath

& (Join-Path $PSScriptRoot "verify-release-attestation-subject.ps1") `
  -Target $Target `
  -ContractPath $contractResolved `
  -SubjectPath $vsixResolved `
  -ReleaseTag $ReleaseTag

$contract = Get-Content -Raw -LiteralPath $contractResolved | ConvertFrom-Json
$liveEvidence = Get-Content -Raw -LiteralPath $liveEvidenceResolved | ConvertFrom-Json

Assert-Equal "subversionr.release.live-github-attestation.win32-x64.v1" ([string](Get-RequiredProperty $liveEvidence "schema" "Live attestation evidence")) "Live attestation evidence schema must match."
Assert-JsonBoolean $liveEvidence "publicReadinessClaim" $false "Live attestation evidence"
Assert-JsonBoolean $liveEvidence "signingClaim" $false "Live attestation evidence"
Assert-Equal $Target ([string](Get-RequiredProperty $liveEvidence "target" "Live attestation evidence")) "Live attestation target must match."
Assert-Equal "live-attestation-verified" ([string](Get-RequiredProperty $liveEvidence "status" "Live attestation evidence")) "Live attestation status must be verified."

$liveContract = Get-RequiredProperty $liveEvidence "contract" "Live attestation evidence"
Assert-Equal (Get-RepoRelativePath $contractResolved) ([string](Get-RequiredProperty $liveContract "path" "Live attestation contract")) "Live attestation contract path must match."
Assert-Equal (Get-Sha256 $contractResolved) ([string](Get-RequiredProperty $liveContract "sha256" "Live attestation contract")) "Live attestation contract SHA256 must match current bytes."
Assert-Equal ([string]$contract.schema) ([string](Get-RequiredProperty $liveContract "schema" "Live attestation contract")) "Live attestation contract schema must match."

$liveRelease = Get-RequiredProperty $liveEvidence "release" "Live attestation evidence"
Assert-Equal $ReleaseTag ([string](Get-RequiredProperty $liveRelease "tag" "Live attestation release")) "Live attestation release tag must match."
Assert-Equal ([string]$contract.release.url) ([string](Get-RequiredProperty $liveRelease "url" "Live attestation release")) "Live attestation release URL must match."

$liveSubject = Get-RequiredProperty $liveEvidence "subject" "Live attestation evidence"
Assert-Equal ([string]$contract.subject.name) ([string](Get-RequiredProperty $liveSubject "name" "Live attestation subject")) "Live attestation subject name must match."
Assert-Equal ([int64]$contract.subject.size) ([int64](Get-RequiredProperty $liveSubject "size" "Live attestation subject")) "Live attestation subject size must match."
Assert-Equal ([string]$contract.subject.sha256) ([string](Get-RequiredProperty $liveSubject "sha256" "Live attestation subject")) "Live attestation subject SHA256 must match."

$liveWorkflow = Get-RequiredProperty $liveEvidence "workflow" "Live attestation evidence"
Assert-Equal ([string]$contract.workflow.path) ([string](Get-RequiredProperty $liveWorkflow "path" "Live attestation workflow")) "Live attestation workflow path must match."
Assert-Equal "workflow_dispatch" ([string](Get-RequiredProperty $liveWorkflow "event" "Live attestation workflow")) "Live attestation workflow event must match."
Assert-Equal "refs/heads/main" ([string](Get-RequiredProperty $liveWorkflow "sourceRef" "Live attestation workflow")) "Live attestation source ref must be public main."
$attestationSourceSha = [string](Get-RequiredProperty $liveWorkflow "headSha" "Live attestation workflow")
if ($attestationSourceSha -notmatch '^[a-f0-9]{40}$') {
  throw "Live attestation headSha must be a full lowercase commit SHA."
}

$liveAttestation = Get-RequiredProperty $liveEvidence "attestation" "Live attestation evidence"
Assert-Equal ([string]$contract.attestation.provider) ([string](Get-RequiredProperty $liveAttestation "provider" "Live attestation")) "Live attestation provider must match."
Assert-Equal ([string]$contract.attestation.action) ([string](Get-RequiredProperty $liveAttestation "action" "Live attestation")) "Live attestation action must match."
Assert-Equal ([string]$contract.attestation.actionDigest) ([string](Get-RequiredProperty $liveAttestation "actionDigest" "Live attestation")) "Live attestation action digest must match."
Assert-Equal ([string]$contract.attestation.predicateType) ([string](Get-RequiredProperty $liveAttestation "predicateType" "Live attestation")) "Live attestation predicate type must match."
Assert-JsonBoolean $liveAttestation "originalBuildProvenanceClaim" $false "Live attestation"
Assert-JsonBoolean $liveAttestation "artifactSignatureClaim" $false "Live attestation"
$liveBundleResolved = Assert-InputFile ([string](Get-RequiredProperty $liveAttestation "bundlePath" "Live attestation")) "Live attestation bundle"
Assert-Equal (Get-Sha256 $liveBundleResolved) ([string](Get-RequiredProperty $liveAttestation "bundleSha256" "Live attestation")) "Live attestation bundle SHA256 must match current bytes."

$liveVerification = Get-RequiredProperty $liveEvidence "verification" "Live attestation evidence"
Assert-JsonBoolean $liveVerification "verified" $true "Live attestation verification"
Assert-Equal ([string]$contract.verificationPolicy.repository) ([string](Get-RequiredProperty $liveVerification "repository" "Live attestation verification")) "Live attestation repository must match."
Assert-Equal ([string]$contract.verificationPolicy.signerWorkflow) ([string](Get-RequiredProperty $liveVerification "signerWorkflow" "Live attestation verification")) "Live attestation signer workflow must match."
Assert-Equal ([string]$contract.verificationPolicy.predicateType) ([string](Get-RequiredProperty $liveVerification "predicateType" "Live attestation verification")) "Live attestation predicate type must match."
$recordedVerificationResolved = Assert-InputFile ([string](Get-RequiredProperty $liveVerification "resultPath" "Live attestation verification")) "Recorded live attestation verification result"
Assert-Equal (Get-Sha256 $recordedVerificationResolved) ([string](Get-RequiredProperty $liveVerification "resultSha256" "Live attestation verification")) "Recorded live attestation verification result SHA256 must match current bytes."
$liveCertificate = Get-RequiredProperty $liveVerification "certificate" "Live attestation verification"
Assert-Equal "refs/heads/main" ([string](Get-RequiredProperty $liveCertificate "workflowRef" "Live attestation certificate")) "Live attestation certificate workflow ref must be public main."
Assert-Equal $attestationSourceSha ([string](Get-RequiredProperty $liveCertificate "workflowSha" "Live attestation certificate")) "Live attestation certificate workflow SHA must match."
Assert-Equal "github-hosted" ([string](Get-RequiredProperty $liveCertificate "runnerEnvironment" "Live attestation certificate")) "Live attestation certificate runner must be GitHub-hosted."
Assert-Equal "public" ([string](Get-RequiredProperty $liveCertificate "sourceVisibility" "Live attestation certificate")) "Live attestation certificate must record public source visibility."

$verificationResults = @(Get-Content -Raw -LiteralPath $verificationResolved | ConvertFrom-Json)
if ($verificationResults.Count -ne 1) {
  throw "AttestationVerificationResultPath must contain exactly one verified attestation."
}
$verifiedDetails = Get-RequiredProperty $verificationResults[0] "verificationResult" "Attestation verification result"
$verifiedTimestamps = @(Get-RequiredProperty $verifiedDetails "verifiedTimestamps" "Attestation verification result details")
if ($verifiedTimestamps.Count -lt 1) {
  throw "Attestation verification result must contain at least one verified timestamp."
}
$statement = Get-RequiredProperty $verifiedDetails "statement" "Attestation verification result details"
$matchingSubjects = @($statement.subject | Where-Object {
    [string]$_.name -eq [string]$contract.subject.name -and
    [string]$_.digest.sha256 -eq [string]$contract.subject.sha256
  })
if ($matchingSubjects.Count -ne 1) {
  throw "Attestation verification result must bind the contracted VSIX subject."
}
Assert-Equal ([string]$contract.verificationPolicy.predicateType) ([string](Get-RequiredProperty $statement "predicateType" "Attestation verification statement")) "Attestation verification predicate type must match."
$verificationCertificate = Get-RequiredProperty (Get-RequiredProperty $verifiedDetails "signature" "Attestation verification result details") "certificate" "Attestation verification signature"
Assert-Equal ([string]$contract.verificationPolicy.repository) ([string](Get-RequiredProperty $verificationCertificate "githubWorkflowRepository" "Attestation verification certificate")) "Attestation verification repository must match."
Assert-Equal "refs/heads/main" ([string](Get-RequiredProperty $verificationCertificate "githubWorkflowRef" "Attestation verification certificate")) "Attestation verification workflow ref must be public main."
Assert-Equal $attestationSourceSha ([string](Get-RequiredProperty $verificationCertificate "githubWorkflowSHA" "Attestation verification certificate")) "Attestation verification workflow SHA must match live evidence."
Assert-Equal "refs/heads/main" ([string](Get-RequiredProperty $verificationCertificate "sourceRepositoryRef" "Attestation verification certificate")) "Attestation verification source ref must be public main."
Assert-Equal $attestationSourceSha ([string](Get-RequiredProperty $verificationCertificate "sourceRepositoryDigest" "Attestation verification certificate")) "Attestation verification source digest must match live evidence."
Assert-Equal "public" ([string](Get-RequiredProperty $verificationCertificate "sourceRepositoryVisibilityAtSigning" "Attestation verification certificate")) "Attestation verification source visibility must be public."

$archive = [System.IO.Compression.ZipFile]::OpenRead($vsixResolved)
try {
  [xml]$vsixManifest = Get-ZipEntryText $archive "extension.vsixmanifest"
  $packageJson = Get-ZipEntryText $archive "extension/package.json" | ConvertFrom-Json
}
finally {
  $archive.Dispose()
}

$identityNodes = @($vsixManifest.SelectNodes("//*[local-name()='PackageManifest']/*[local-name()='Metadata']/*[local-name()='Identity']"))
if ($identityNodes.Count -ne 1) {
  throw "VSIX manifest must contain exactly one Identity node."
}
$identity = $identityNodes[0]
Assert-Equal "subversionr" ([string]$identity.Id) "VSIX manifest identity name must match."
Assert-Equal $ExtensionVersion ([string]$identity.Version) "VSIX manifest extension version must match."
Assert-Equal $Target ([string]$identity.TargetPlatform) "VSIX manifest target must match."
Assert-Equal "hitsuki-ban" ([string]$identity.Publisher) "VSIX manifest publisher must match."
Assert-Equal $ExtensionId "$($identity.Publisher).$($identity.Id)" "VSIX manifest extension id must match."
Assert-Equal "subversionr" ([string]$packageJson.name) "VSIX package name must match."
Assert-Equal "hitsuki-ban" ([string]$packageJson.publisher) "VSIX package publisher must match."
Assert-Equal $ExtensionVersion ([string]$packageJson.version) "VSIX package version must match."
Assert-Equal $ExtensionId "$($packageJson.publisher).$($packageJson.name)" "VSIX package extension id must match."

$preReleaseProperties = @($vsixManifest.SelectNodes("//*[local-name()='PackageManifest']/*[local-name()='Metadata']/*[local-name()='Properties']/*[local-name()='Property' and @Id='Microsoft.VisualStudio.Code.PreRelease']"))
if ($preReleaseProperties.Count -ne 1 -or [string]$preReleaseProperties[0].Value -cne "true") {
  throw "VSIX must contain exactly one Microsoft.VisualStudio.Code.PreRelease property with Value=true."
}

Assert-Equal "Hitsuki-Ban/SubversionR" $Repository "Publication repository must be the public repository."
Assert-Equal ".github/workflows/publish-marketplace.yml" $WorkflowPath "Publication workflow path must match."
Assert-Equal "workflow_dispatch" $EventName "Publication workflow event must be workflow_dispatch."
Assert-Equal "refs/heads/main" $SourceRef "Publication workflow source ref must be public main."
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

$vsixRelativePath = Get-RepoRelativePath $vsixResolved
$publishCommand = "pnpm exec vsce publish --packagePath $vsixRelativePath --pre-release --azure-credential"
$evidence = [pscustomobject]@{
  schemaVersion = 1
  schema = "subversionr.release.marketplace-publication.win32-x64.v1"
  target = $Target
  status = "marketplace-prerelease-published"
  generatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
  preReleaseClaim = $true
  publicReadinessClaim = $false
  publicInstallClaim = $false
  signingClaim = $false
  rollbackClaim = $false
  finalReviewClaim = $false
  release = [pscustomobject]@{
    tag = $ReleaseTag
    url = [string]$contract.release.url
  }
  extension = [pscustomobject]@{
    id = $ExtensionId
    version = $ExtensionVersion
    publisher = [string]$packageJson.publisher
    name = [string]$packageJson.name
    targetPlatform = [string]$identity.TargetPlatform
  }
  vsix = [pscustomobject]@{
    name = [string]$contract.subject.name
    path = $vsixRelativePath
    size = [int64](Get-Item -LiteralPath $vsixResolved).Length
    sha256 = Get-Sha256 $vsixResolved
    marketplacePreReleaseProperty = $true
  }
  attestation = [pscustomobject]@{
    verified = $true
    contractPath = Get-RepoRelativePath $contractResolved
    contractSha256 = Get-Sha256 $contractResolved
    liveEvidencePath = Get-RepoRelativePath $liveEvidenceResolved
    liveEvidenceSha256 = Get-Sha256 $liveEvidenceResolved
    bundlePath = Get-RepoRelativePath $liveBundleResolved
    bundleSha256 = Get-Sha256 $liveBundleResolved
    recordedVerificationResultPath = Get-RepoRelativePath $recordedVerificationResolved
    recordedVerificationResultSha256 = Get-Sha256 $recordedVerificationResolved
    verificationResultPath = Get-RepoRelativePath $verificationResolved
    verificationResultSha256 = Get-Sha256 $verificationResolved
    repository = [string]$contract.verificationPolicy.repository
    signerWorkflow = [string]$contract.verificationPolicy.signerWorkflow
    predicateType = [string]$contract.verificationPolicy.predicateType
    sourceRef = "refs/heads/main"
    sourceSha = $attestationSourceSha
  }
  workflow = [pscustomobject]@{
    repository = $Repository
    path = $WorkflowPath
    event = $EventName
    runId = $RunId
    runAttempt = $RunAttempt
    runUrl = $RunUrl
    headSha = $HeadSha
    sourceRef = $SourceRef
    environment = "marketplace"
  }
  publication = [pscustomobject]@{
    provider = "visual-studio-marketplace"
    channel = "pre-release"
    authentication = "microsoft-entra-id-workload-identity"
    command = $publishCommand
    published = $true
  }
  nonClaims = @(
    "This evidence does not claim public Marketplace install verification.",
    "This evidence does not claim that the VSIX is signed.",
    "This evidence does not claim previous-stable rollback verification.",
    "This evidence does not claim final release review or approval.",
    "This evidence does not claim public release readiness."
  )
}

$serialized = $evidence | ConvertTo-Json -Depth 20
if ($serialized -match '(?i)(client.?secret|access.?token|refresh.?token|authorization\s*header|VSCE_PAT)') {
  throw "Marketplace publication evidence must not contain credential values."
}
$outputParent = Split-Path -Parent $outputResolved
New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
Set-Content -LiteralPath $outputResolved -Value $serialized -Encoding utf8

Write-Host "Recorded SubversionR Marketplace prerelease publication evidence for $Target at $outputResolved."

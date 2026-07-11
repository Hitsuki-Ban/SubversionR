[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$ContractPath,

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
  [string]$OutputPath,

  [switch]$ValidateOnly
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
$verificationResolved = Assert-GeneratedInputFile $AttestationVerificationResultPath "AttestationVerificationResultPath"
$vsixResolved = Assert-GeneratedInputFile $VsixPath "VsixPath"
$outputResolved = Assert-OutputPath $OutputPath

& (Join-Path $PSScriptRoot "verify-release-attestation-subject.ps1") `
  -Target $Target `
  -ContractPath $contractResolved `
  -SubjectPath $vsixResolved `
  -ReleaseTag $ReleaseTag

$contract = Get-Content -Raw -LiteralPath $contractResolved | ConvertFrom-Json
$verificationResults = @(Get-Content -Raw -LiteralPath $verificationResolved | ConvertFrom-Json)
if ($verificationResults.Count -lt 1) {
  throw "AttestationVerificationResultPath must contain at least one verified attestation."
}
$expectedSignerIdentity = "https://github.com/$($contract.verificationPolicy.signerWorkflow)@refs/heads/main"
foreach ($verificationResult in $verificationResults) {
  $verifiedDetails = Get-RequiredProperty $verificationResult "verificationResult" "Attestation verification result"
  $verifiedTimestamps = @(Get-RequiredProperty $verifiedDetails "verifiedTimestamps" "Attestation verification result details")
  if ($verifiedTimestamps.Count -lt 1) {
    throw "Attestation verification result must contain at least one verified timestamp."
  }

  $statement = Get-RequiredProperty $verifiedDetails "statement" "Attestation verification result details"
  $verifiedSubjects = @(Get-RequiredProperty $statement "subject" "Attestation verification statement")
  if ($verifiedSubjects.Count -ne 1) {
    throw "Attestation verification result must contain exactly one subject."
  }
  $verifiedSubject = $verifiedSubjects[0]
  Assert-Equal ([string]$contract.subject.name) ([string](Get-RequiredProperty $verifiedSubject "name" "Attestation verification subject")) "Attestation verification subject name must match."
  $verifiedDigest = Get-RequiredProperty $verifiedSubject "digest" "Attestation verification subject"
  Assert-Equal ([string]$contract.subject.sha256) ([string](Get-RequiredProperty $verifiedDigest "sha256" "Attestation verification subject digest")) "Attestation verification subject SHA256 must match."
  Assert-Equal ([string]$contract.verificationPolicy.predicateType) ([string](Get-RequiredProperty $statement "predicateType" "Attestation verification statement")) "Attestation verification predicate type must match."

  $certificate = Get-RequiredProperty (Get-RequiredProperty $verifiedDetails "signature" "Attestation verification result details") "certificate" "Attestation verification signature"
  Assert-Equal $expectedSignerIdentity ([string](Get-RequiredProperty $certificate "subjectAlternativeName" "Attestation verification certificate")) "Attestation verification signer identity must match."
  Assert-Equal ([string]$contract.verificationPolicy.repository) ([string](Get-RequiredProperty $certificate "githubWorkflowRepository" "Attestation verification certificate")) "Attestation verification repository must match."
  Assert-Equal "workflow_dispatch" ([string](Get-RequiredProperty $certificate "githubWorkflowTrigger" "Attestation verification certificate")) "Attestation verification trigger must match."
  Assert-Equal "refs/heads/main" ([string](Get-RequiredProperty $certificate "githubWorkflowRef" "Attestation verification certificate")) "Attestation verification signer ref must be public main."
  Assert-Equal $HeadSha ([string](Get-RequiredProperty $certificate "githubWorkflowSHA" "Attestation verification certificate")) "Attestation verification signer SHA must match the publication commit."
  Assert-Equal $HeadSha ([string](Get-RequiredProperty $certificate "buildSignerDigest" "Attestation verification certificate")) "Attestation verification signer digest must match the publication commit."
  Assert-Equal "refs/heads/main" ([string](Get-RequiredProperty $certificate "sourceRepositoryRef" "Attestation verification certificate")) "Attestation verification source ref must be public main."
  Assert-Equal $HeadSha ([string](Get-RequiredProperty $certificate "sourceRepositoryDigest" "Attestation verification certificate")) "Attestation verification source digest must match the publication commit."
  Assert-Equal "github-hosted" ([string](Get-RequiredProperty $certificate "runnerEnvironment" "Attestation verification certificate")) "Attestation verification runner must be GitHub-hosted."
  Assert-Equal "public" ([string](Get-RequiredProperty $certificate "sourceRepositoryVisibilityAtSigning" "Attestation verification certificate")) "Attestation verification source visibility must be public."
}

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

$preReleaseProperties = @($vsixManifest.SelectNodes("//*[local-name()='PackageManifest']/*[local-name()='Metadata']/*[local-name()='Properties']/*[local-name()='Property' and @Id='Microsoft.VisualStudio.Code.PreRelease']"))
if ($preReleaseProperties.Count -ne 1 -or [string]$preReleaseProperties[0].Value -cne "true") {
  throw "VSIX must contain exactly one Microsoft.VisualStudio.Code.PreRelease property with Value=true."
}

Assert-Equal "Hitsuki-Ban/SubversionR" $Repository "Publication repository must be the public repository."
Assert-Equal ".github/workflows/publish-marketplace.yml" $WorkflowPath "Publication workflow path must match."
Assert-Equal "workflow_dispatch" $EventName "Publication workflow event must be workflow_dispatch."
Assert-Equal "refs/heads/main" $SourceRef "Publication workflow source ref must be public main."
if ($RunId -notmatch '^[0-9]+$') { throw "RunId must contain only digits." }
if ($RunAttempt -lt 1) { throw "RunAttempt must be positive." }
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/$RunId" $RunUrl "RunUrl must match RunId."
if ($HeadSha -notmatch '^[a-f0-9]{40}$') { throw "HeadSha must be a full lowercase commit SHA." }

$vsixRelativePath = Get-RepoRelativePath $vsixResolved
$verificationRelativePath = Get-RepoRelativePath $verificationResolved
$verificationCommand = "gh attestation verify $vsixRelativePath -R $($contract.verificationPolicy.repository) --signer-workflow $($contract.verificationPolicy.signerWorkflow) --signer-digest $HeadSha --source-ref refs/heads/main --source-digest $HeadSha --predicate-type $($contract.verificationPolicy.predicateType) --deny-self-hosted-runners --format json"
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
  release = [pscustomobject]@{ tag = $ReleaseTag; url = [string]$contract.release.url }
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
    verificationResultPath = $verificationRelativePath
    verificationResultSha256 = Get-Sha256 $verificationResolved
    verificationResultCount = $verificationResults.Count
    repository = [string]$contract.verificationPolicy.repository
    signerWorkflow = [string]$contract.verificationPolicy.signerWorkflow
    predicateType = [string]$contract.verificationPolicy.predicateType
    sourceRef = "refs/heads/main"
    sourceSha = $HeadSha
    denySelfHostedRunners = $true
    format = "json"
    command = $verificationCommand
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
if ($serialized -match '(?i)(client.?id|tenant.?id|client.?secret|access.?token|refresh.?token|authorization\s*header|azure.?credential\s*[:=]|VSCE_PAT)') {
  throw "Marketplace publication evidence must not contain identity or credential values."
}
if ($ValidateOnly) {
  Write-Host "Validated SubversionR Marketplace prerelease publication inputs for $Target without writing evidence."
  return
}
$outputParent = Split-Path -Parent $outputResolved
New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
Set-Content -LiteralPath $outputResolved -Value $serialized -Encoding utf8

Write-Host "Recorded SubversionR Marketplace prerelease publication evidence for $Target at $outputResolved."

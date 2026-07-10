[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$ExtensionPackagePath,

  [Parameter(Mandatory = $true)]
  [string]$RootPackagePath,

  [Parameter(Mandatory = $true)]
  [string]$ReadmePath,

  [Parameter(Mandatory = $true)]
  [string]$LicensePath,

  [Parameter(Mandatory = $true)]
  [string]$ChangelogPath,

  [Parameter(Mandatory = $true)]
  [string]$SupportPath,

  [Parameter(Mandatory = $true)]
  [string]$PublicCutoverRunbookPath,

  [Parameter(Mandatory = $true)]
  [string]$PublicCutoverEvidencePath,

  [Parameter(Mandatory = $true)]
  [string]$ProvenanceEvidencePath,

  [Parameter(Mandatory = $true)]
  [string]$VsixEvidencePath,

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

function Test-HasProperty([object]$Object, [string]$Name) {
  $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Get-RequiredProperty([object]$Object, [string]$Name, [string]$Context) {
  if (-not (Test-HasProperty $Object $Name) -or [string]::IsNullOrWhiteSpace([string]$Object.$Name)) {
    throw "$Context must define $Name."
  }
  $Object.$Name
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
  if ($Expected -ne $Actual) {
    throw "$Message Expected '$Expected', got '$Actual'."
  }
}

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw $Message
  }
}

function Assert-BooleanFalse([object]$Object, [string]$Name, [string]$Context) {
  if (-not (Test-HasProperty $Object $Name)) {
    throw "$Context must define $Name."
  }
  if ($Object.$Name -isnot [bool]) {
    throw "$Context $Name must be a JSON boolean."
  }
  Assert-Equal $false ([bool]$Object.$Name) "$Context $Name must remain false."
}

function Assert-BooleanTrue([object]$Object, [string]$Name, [string]$Context) {
  if (-not (Test-HasProperty $Object $Name)) {
    throw "$Context must define $Name."
  }
  if ($Object.$Name -isnot [bool]) {
    throw "$Context $Name must be a JSON boolean."
  }
  Assert-Equal $true ([bool]$Object.$Name) "$Context $Name must be true."
}

function Assert-NoForbiddenCutoverEvidenceText([string]$Text) {
  $patterns = @(
    'ghp_[A-Za-z0-9_]{20,}',
    'github_pat_[A-Za-z0-9_]+',
    '://[^/\s:@"]+:[^/\s:@"]+@',
    '(?i)Authorization:\s*Bearer\s+',
    '(?i)"tokenValue"\s*:',
    '(?i)"credential"\s*:',
    '(?i)"authorizationHeader"\s*:',
    'github\.com/Hitsuki-Ban/SubversionR-private',
    'repo_id',
    'repo_connection_uuid',
    'build_token_uuid',
    'trigger_uuid'
  )

  foreach ($pattern in $patterns) {
    if ($Text -match $pattern) {
      throw "Public cutover evidence must not record credentials, private repository URLs, or Cloudflare live IDs."
    }
  }
}

function Get-RequiredReleaseAsset([object[]]$Assets, [string]$Name) {
  $matches = @($Assets | Where-Object { [string]$_.name -eq $Name })
  if ($matches.Count -ne 1) {
    throw "Public cutover release must record asset '$Name' exactly once."
  }
  $matches[0]
}

function New-HashRecord([string]$Path) {
  [pscustomobject]@{
    path = Get-RepoRelativePath $Path
    sha256 = Get-Sha256 $Path
  }
}

$extensionPackageResolved = Assert-File $ExtensionPackagePath "ExtensionPackagePath"
$rootPackageResolved = Assert-File $RootPackagePath "RootPackagePath"
$readmeResolved = Assert-File $ReadmePath "ReadmePath"
$licenseResolved = Assert-File $LicensePath "LicensePath"
$changelogResolved = Assert-File $ChangelogPath "ChangelogPath"
$supportResolved = Assert-File $SupportPath "SupportPath"
$publicCutoverRunbookResolved = Assert-File $PublicCutoverRunbookPath "PublicCutoverRunbookPath"
$publicCutoverEvidenceResolved = Assert-File $PublicCutoverEvidencePath "PublicCutoverEvidencePath"
$provenanceResolved = Assert-File $ProvenanceEvidencePath "ProvenanceEvidencePath"
$vsixEvidenceResolved = Assert-File $VsixEvidencePath "VsixEvidencePath"
$outputResolved = Assert-GeneratedPath -Path $OutputPath -Name "OutputPath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-publication-gaps-scripts"))
) -Description "target/release-evidence or target/tests/release-publication-gaps-scripts"

$extensionPackage = Get-Content -Raw -LiteralPath $extensionPackageResolved | ConvertFrom-Json
$rootPackage = Get-Content -Raw -LiteralPath $rootPackageResolved | ConvertFrom-Json
$provenance = Get-Content -Raw -LiteralPath $provenanceResolved | ConvertFrom-Json
$vsixEvidence = Get-Content -Raw -LiteralPath $vsixEvidenceResolved | ConvertFrom-Json
$publicCutoverEvidenceRaw = Get-Content -Raw -LiteralPath $publicCutoverEvidenceResolved
Assert-NoForbiddenCutoverEvidenceText $publicCutoverEvidenceRaw
$publicCutoverEvidence = $publicCutoverEvidenceRaw | ConvertFrom-Json

$extensionName = [string](Get-RequiredProperty $extensionPackage "name" "Extension package")
$extensionPublisher = [string](Get-RequiredProperty $extensionPackage "publisher" "Extension package")
$extensionId = "$extensionPublisher.$extensionName"
Assert-Equal "hitsuki-ban.subversionr" $extensionId "Extension package identity must be hitsuki-ban.subversionr."
Assert-Equal "SubversionR" ([string](Get-RequiredProperty $extensionPackage "displayName" "Extension package")) "Extension display name should remain SubversionR."
Assert-True (-not ((Test-HasProperty $extensionPackage "private") -and [bool]$extensionPackage.private)) "Extension package must not be private for the public Marketplace identity."
Assert-True ((Test-HasProperty $rootPackage "private") -and [bool]$rootPackage.private) "Root package must remain private for this local publication gaps gate."

$repository = Get-RequiredProperty $extensionPackage "repository" "Extension package"
Assert-Equal "git" ([string](Get-RequiredProperty $repository "type" "Extension package repository")) "Extension package repository type must be git."
$repositoryUrl = [string](Get-RequiredProperty $repository "url" "Extension package repository")
$homepageUrl = [string](Get-RequiredProperty $extensionPackage "homepage" "Extension package")
$bugs = Get-RequiredProperty $extensionPackage "bugs" "Extension package"
$bugsUrl = [string](Get-RequiredProperty $bugs "url" "Extension package bugs")
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR.git" $repositoryUrl "Extension package repository URL must point to the public repository."
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR#readme" $homepageUrl "Extension package homepage URL must point to the public repository README."
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/issues" $bugsUrl "Extension package bugs URL must point to the public issue tracker."

$extensionVersion = [string](Get-RequiredProperty $extensionPackage "version" "Extension package")
$extensionLicense = [string](Get-RequiredProperty $extensionPackage "license" "Extension package")
$engines = Get-RequiredProperty $extensionPackage "engines" "Extension package"
$enginesVscode = [string](Get-RequiredProperty $engines "vscode" "Extension package engines")

Assert-Equal "subversionr.release.marketplace-provenance-preflight.win32-x64.v1" ([string]$provenance.schema) "Provenance evidence schema must match the Marketplace provenance preflight."
Assert-Equal $Target ([string]$provenance.target) "Provenance evidence target must match the requested target."
Assert-Equal "False" ([string]$provenance.publicReadinessClaim) "Provenance evidence publicReadinessClaim must remain false."
Assert-Equal "True" ([string]$provenance.localPreflightOnly) "Provenance evidence must remain local-preflight only."
Assert-Equal $extensionId ([string]$provenance.extension.id) "Provenance extension identity must match the extension package."
Assert-Equal $extensionVersion ([string]$provenance.extension.version) "Provenance extension version must match the extension package."
Assert-BooleanFalse $provenance.repository "remoteUrlRecorded" "Provenance repository"
Assert-Equal "not-published" ([string]$provenance.marketplace.status) "Provenance Marketplace status must remain not-published."
Assert-Equal "not-generated" ([string]$provenance.attestation.status) "Provenance attestation status must remain not-generated."
Assert-Equal "unsigned" ([string]$provenance.signing.status) "Provenance signing status must remain unsigned."
Assert-Equal "not-proven" ([string]$provenance.previousStableRollback.status) "Provenance previous-stable rollback status must remain not-proven."
Assert-Equal "False" ([string]$provenance.marketplaceMetadata.publicationReady) "Provenance Marketplace metadata must not claim publication readiness."

Assert-Equal "subversionr.release.vsix-package.win32-x64.v1" ([string]$vsixEvidence.schema) "VSIX evidence schema must match win32-x64 package evidence."
Assert-Equal $Target ([string]$vsixEvidence.target) "VSIX evidence target must match the requested target."
Assert-Equal "False" ([string]$vsixEvidence.publicReadinessClaim) "VSIX evidence publicReadinessClaim must remain false."
Assert-Equal $extensionId ([string]$vsixEvidence.extension.id) "VSIX evidence extension identity must match the extension package."
Assert-Equal $extensionVersion ([string]$vsixEvidence.extension.version) "VSIX evidence extension version must match the extension package."

$vsixPath = Assert-GeneratedPath -Path ([string]$provenance.artifacts.vsix.path) -Name "VSIX artifact" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\vsix")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-publication-gaps-scripts"))
) -Description "target/vsix or target/tests/release-publication-gaps-scripts"
if (-not (Test-Path -LiteralPath $vsixPath -PathType Leaf)) {
  throw "VSIX artifact must be a file: $($provenance.artifacts.vsix.path)"
}
$actualVsixSha256 = Get-Sha256 $vsixPath
Assert-Equal ([string]$provenance.artifacts.vsix.sha256) $actualVsixSha256 "VSIX SHA256 must match provenance evidence."
Assert-Equal ([string]$vsixEvidence.vsix.sha256) $actualVsixSha256 "VSIX SHA256 must match VSIX package evidence."

Assert-Equal 1 ([int]$publicCutoverEvidence.schemaVersion) "Public cutover evidence schemaVersion should be 1."
Assert-Equal "subversionr.release.public-cutover-evidence.v1" ([string]$publicCutoverEvidence.schema) "Public cutover evidence schema must match."
Assert-Equal "recorded-post-cutover" ([string]$publicCutoverEvidence.status) "Public cutover evidence must record the post-cutover state."

$cutoverRepository = Get-RequiredProperty $publicCutoverEvidence "repository" "Public cutover evidence"
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR" ([string](Get-RequiredProperty $cutoverRepository "url" "Public cutover repository")) "Public cutover repository URL must match."
Assert-Equal "main" ([string](Get-RequiredProperty $cutoverRepository "defaultBranch" "Public cutover repository")) "Public cutover default branch must be main."
$baselineCommit = [string](Get-RequiredProperty $cutoverRepository "baselineCommit" "Public cutover repository")
Assert-True ($baselineCommit -match '^[a-f0-9]{40}$') "Public cutover baselineCommit must be a full lowercase commit SHA."
$cutoverHeadCommit = [string](Get-RequiredProperty $cutoverRepository "cutoverHeadCommit" "Public cutover repository")
Assert-True ($cutoverHeadCommit -match '^[a-f0-9]{40}$') "Public cutover cutoverHeadCommit must be a full lowercase commit SHA."
Assert-True ($cutoverHeadCommit -ne $baselineCommit) "Public cutover cutoverHeadCommit must identify the post-baseline cutover head."
Assert-BooleanTrue $cutoverRepository "resolvesToPublic" "Public cutover repository"
Assert-Equal "PR Fast / windows" ([string](Get-RequiredProperty $cutoverRepository "branchProtectionRequiredCheck" "Public cutover repository")) "Public branch protection required check must match."
Assert-BooleanFalse $cutoverRepository "branchProtectionConfigured" "Public cutover repository"
Assert-BooleanTrue $cutoverRepository "privateVulnerabilityReportingEnabled" "Public cutover repository"
Assert-BooleanFalse $cutoverRepository "metadataVerified" "Public cutover repository"

$cutoverCi = Get-RequiredProperty $publicCutoverEvidence "ci" "Public cutover evidence"
Assert-Equal "green" ([string](Get-RequiredProperty $cutoverCi "status" "Public cutover CI")) "Public cutover CI status must be green."
Assert-Equal "PR Fast" ([string](Get-RequiredProperty $cutoverCi "workflow" "Public cutover CI")) "Public cutover CI workflow must be PR Fast."
Assert-Equal "PR Fast / windows" ([string](Get-RequiredProperty $cutoverCi "requiredCheck" "Public cutover CI")) "Public cutover CI required check must match."
$ciRunUrl = [string](Get-RequiredProperty $cutoverCi "runUrl" "Public cutover CI")
Assert-True ($ciRunUrl -match '^https://github\.com/Hitsuki-Ban/SubversionR/actions/runs/[0-9]+$') "Public cutover CI runUrl must identify a public repository Actions run."
Assert-Equal $cutoverHeadCommit ([string](Get-RequiredProperty $cutoverCi "headSha" "Public cutover CI")) "Public cutover CI headSha must match the recorded cutover head commit."
Assert-Equal "push" ([string](Get-RequiredProperty $cutoverCi "event" "Public cutover CI")) "Public cutover CI event must be push."
Assert-Equal "success" ([string](Get-RequiredProperty $cutoverCi "conclusion" "Public cutover CI")) "Public cutover CI conclusion must be success."
[void](Get-RequiredProperty $cutoverCi "startedAt" "Public cutover CI")
[void](Get-RequiredProperty $cutoverCi "completedAt" "Public cutover CI")
Assert-BooleanTrue $cutoverCi "publicPrFastFirstRunGreen" "Public cutover CI"
Assert-BooleanTrue $cutoverCi "publicHeavyWorkflowScheduleOnly" "Public cutover CI"
Assert-BooleanFalse $cutoverCi "privateWorkflowsDisabled" "Public cutover CI"
Assert-BooleanFalse $cutoverCi "privateWorkflowDisableDateRecorded" "Public cutover CI"

$cutoverCloudflare = Get-RequiredProperty $publicCutoverEvidence "cloudflareBridgeRetirement" "Public cutover evidence"
Assert-Equal "retired" ([string](Get-RequiredProperty $cutoverCloudflare "status" "Cloudflare bridge retirement")) "Cloudflare bridge status must be retired."
Assert-Equal "subversionr-pr-fast" ([string](Get-RequiredProperty $cutoverCloudflare "workerName" "Cloudflare bridge retirement")) "Cloudflare bridge worker name must match."
Assert-Equal "PR Fast / windows" ([string](Get-RequiredProperty $cutoverCloudflare "publicCiReplacement" "Cloudflare bridge retirement")) "Cloudflare bridge replacement check must match."
Assert-BooleanTrue $cutoverCloudflare "disconnected" "Cloudflare bridge retirement"
Assert-BooleanTrue $cutoverCloudflare "triggersDisabled" "Cloudflare bridge retirement"
$cloudflareRetirementDate = [string](Get-RequiredProperty $cutoverCloudflare "retirementDate" "Cloudflare bridge retirement")
Assert-True ($cloudflareRetirementDate -match '^20[0-9]{2}-[0-9]{2}-[0-9]{2}$') "Cloudflare retirementDate must use YYYY-MM-DD."

$cutoverRelease = Get-RequiredProperty $publicCutoverEvidence "release" "Public cutover evidence"
Assert-Equal "published" ([string](Get-RequiredProperty $cutoverRelease "status" "Public cutover release")) "Public cutover release status must be published."
Assert-Equal "v0.2.0-beta.1" ([string](Get-RequiredProperty $cutoverRelease "tag" "Public cutover release")) "Public cutover release tag must match."
Assert-Equal $cutoverHeadCommit ([string](Get-RequiredProperty $cutoverRelease "tagCommit" "Public cutover release")) "Public cutover release tagCommit must match the recorded cutover head commit."
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/releases/tag/v0.2.0-beta.1" ([string](Get-RequiredProperty $cutoverRelease "url" "Public cutover release")) "Public cutover release URL must match."
Assert-BooleanTrue $cutoverRelease "prerelease" "Public cutover release"
[void](Get-RequiredProperty $cutoverRelease "publishedAt" "Public cutover release")
Assert-BooleanFalse $cutoverRelease "artifactAttestationPublished" "Public cutover release"
$releaseAssets = @($cutoverRelease.assets)
Assert-Equal 4 $releaseAssets.Count "Public cutover release must record the four published assets."
foreach ($assetName in @(
    "subversionr-source-sbom.cdx.json",
    "subversionr-win32-x64-0.2.0.vsix",
    "subversionr-win32-x64-beta-candidate.zip",
    "THIRD-PARTY-NOTICES.md"
  )) {
  $asset = Get-RequiredReleaseAsset -Assets $releaseAssets -Name $assetName
  Assert-True ([int64]$asset.size -gt 0) "Public cutover release asset '$assetName' must record a positive size."
  Assert-True ([string]$asset.sha256 -match '^[a-f0-9]{64}$') "Public cutover release asset '$assetName' must record a lowercase SHA256."
  Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/releases/download/v0.2.0-beta.1/$assetName" ([string]$asset.url) "Public cutover release asset '$assetName' URL must match."
}
$releasedVsix = Get-RequiredReleaseAsset -Assets $releaseAssets -Name "subversionr-win32-x64-0.2.0.vsix"
Assert-Equal $actualVsixSha256 ([string]$releasedVsix.sha256) "Released VSIX SHA256 must match current VSIX bytes."
Assert-Equal ([int64](Get-Item -LiteralPath $vsixPath).Length) ([int64]$releasedVsix.size) "Released VSIX size must match current VSIX bytes."

$betaCandidateEvidence = Get-RequiredProperty $publicCutoverEvidence "betaCandidateEvidence" "Public cutover evidence"
Assert-Equal "blocked-published-bundle-inconsistent" ([string](Get-RequiredProperty $betaCandidateEvidence "status" "Beta candidate evidence")) "Published Beta candidate evidence must remain blocked on bundle inconsistency."
Assert-Equal "subversionr-win32-x64-beta-candidate.zip" ([string](Get-RequiredProperty $betaCandidateEvidence "publishedBundleAssetName" "Beta candidate evidence")) "Beta candidate evidence must bind the published bundle asset."
$publishedBundleAsset = Get-RequiredReleaseAsset -Assets $releaseAssets -Name "subversionr-win32-x64-beta-candidate.zip"
Assert-Equal ([string]$publishedBundleAsset.sha256) ([string](Get-RequiredProperty $betaCandidateEvidence "publishedBundleSha256" "Beta candidate evidence")) "Beta candidate evidence must bind the published bundle SHA256."
Assert-Equal "subversionr-win32-x64-0.2.0.vsix" ([string](Get-RequiredProperty $betaCandidateEvidence "expectedVsixName" "Beta candidate evidence")) "Beta candidate evidence must bind the expected released VSIX name."
Assert-Equal ([string]$releasedVsix.sha256) ([string](Get-RequiredProperty $betaCandidateEvidence "expectedVsixSha256" "Beta candidate evidence")) "Beta candidate evidence must bind the released VSIX SHA256."
Assert-Equal "svn-r-win32-x64-0.1.0.vsix" ([string](Get-RequiredProperty $betaCandidateEvidence "containedVsixName" "Beta candidate evidence")) "Beta candidate evidence must record the unexpected bundled VSIX name."
Assert-Equal "ff7094c02b27914351fde4d9ae9b09dd8a3cf4af00f983ddf085adb808a3167b" ([string](Get-RequiredProperty $betaCandidateEvidence "containedVsixSha256" "Beta candidate evidence")) "Beta candidate evidence must record the unexpected bundled VSIX SHA256."
Assert-Equal 1462 ([int](Get-RequiredProperty $betaCandidateEvidence "declaredPayloadCount" "Beta candidate evidence")) "Beta candidate evidence must record the manifest payload count."
Assert-Equal 29 ([int](Get-RequiredProperty $betaCandidateEvidence "missingPayloadCount" "Beta candidate evidence")) "Beta candidate evidence must record missing manifest payloads."
Assert-Equal 421 ([int](Get-RequiredProperty $betaCandidateEvidence "mismatchedPayloadCount" "Beta candidate evidence")) "Beta candidate evidence must record mismatched manifest payloads."
Assert-BooleanFalse $betaCandidateEvidence "consistencyVerified" "Beta candidate evidence"
Assert-BooleanFalse $betaCandidateEvidence "regenerationCompleted" "Beta candidate evidence"

$blockers = @(
  "Marketplace publisher authorization is not verified by this local gap report.",
  "Marketplace publish authentication is not configured by this local gap report.",
  "Marketplace publication is not run by this local gap report.",
  "Marketplace public install evidence is not generated by this local gap report.",
  "VSIX signing remains absent in the upstream provenance preflight.",
  "Public branch protection is not configured.",
  "Public repository homepage and social metadata are not fully verified.",
  "Private repository workflows are not disabled.",
  "Live GitHub artifact attestation is not published or verified.",
  "The published Beta candidate bundle is inconsistent with its manifest and cannot close the post-cutover Beta-G chain.",
  "Previous stable artifact rollback evidence is not generated by this local gap report."
)

$nonClaims = @(
  "This gate is a local publication gaps report, not a publication readiness certificate.",
  "This gate records public repository metadata and cutover state from hash-bound evidence without recording a private remote, credentialed URL, or Marketplace publication URL.",
  "This gate does not verify Marketplace publisher ownership, contributor access, or authorization.",
  "This gate does not configure or validate Microsoft Entra ID workload identity, managed identity, PAT, VSCE_PAT, or any other credential.",
  "This gate does not publish to Visual Studio Marketplace.",
  "This gate does not install from Visual Studio Marketplace or prove public acquisition.",
  "This gate does not configure public branch protection, disable private workflows, or publish and verify a live artifact attestation.",
  "This gate does not prove VSIX signing, live GitHub artifact attestation generation/publication/verification, previous-stable rollback, final SBOM/NOTICE review, or CVE review."
)

$report = [pscustomobject]@{
  schemaVersion = 1
  schema = "subversionr.release.publication-gaps.win32-x64.v1"
  publicReadinessClaim = $false
  localGapReportOnly = $true
  target = $Target
  traceIds = @("SEC-015", "MIG-009", "MIG-012", "TST-024")
  generatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
  extension = [pscustomobject]@{
    id = $extensionId
    name = $extensionName
    publisher = $extensionPublisher
    displayName = [string]$extensionPackage.displayName
    version = $extensionVersion
    license = $extensionLicense
    enginesVscode = $enginesVscode
    privatePackage = $false
  }
  rootPackage = [pscustomobject]@{
    name = [string](Get-RequiredProperty $rootPackage "name" "Root package")
    version = [string](Get-RequiredProperty $rootPackage "version" "Root package")
    privatePackage = $true
  }
  artifacts = [pscustomobject]@{
    vsix = [pscustomobject]@{
      path = [string]$provenance.artifacts.vsix.path
      relativePath = [string]$provenance.artifacts.vsix.relativePath
      size = (Get-Item -LiteralPath $vsixPath).Length
      sha256 = $actualVsixSha256
    }
  }
  evidence = [pscustomobject]@{
    extensionPackage = New-HashRecord $extensionPackageResolved
    rootPackage = New-HashRecord $rootPackageResolved
    readme = New-HashRecord $readmeResolved
    license = New-HashRecord $licenseResolved
    changelog = New-HashRecord $changelogResolved
    support = New-HashRecord $supportResolved
    publicCutoverRunbook = New-HashRecord $publicCutoverRunbookResolved
    publicCutoverEvidence = New-HashRecord $publicCutoverEvidenceResolved
    provenancePreflight = [pscustomobject]@{
      path = Get-RepoRelativePath $provenanceResolved
      sha256 = Get-Sha256 $provenanceResolved
      schema = [string]$provenance.schema
    }
    vsixPackage = [pscustomobject]@{
      path = Get-RepoRelativePath $vsixEvidenceResolved
      sha256 = Get-Sha256 $vsixEvidenceResolved
      schema = [string]$vsixEvidence.schema
    }
  }
  publicRepositoryMetadata = [pscustomobject]@{
    status = "configured"
    fieldPolicy = "configured-in-extension-manifest"
    claimAllowed = $true
    verifiedBy = "extension package manifest"
    repositoryFieldPresent = $true
    homepageFieldPresent = $true
    bugsFieldPresent = $true
    repositoryResolvesToPublic = [bool]$cutoverRepository.resolvesToPublic
    homepageResolvesToPublic = "not-verified-by-public-cutover-evidence"
    bugsResolvesToPublic = "not-verified-by-public-cutover-evidence"
    repositoryUrlRecorded = $true
    homepageUrlRecorded = $true
    bugsUrlRecorded = $true
    repositoryUrl = $repositoryUrl
    homepageUrl = $homepageUrl
    bugsUrl = $bugsUrl
    requiredFields = @("repository.url", "homepage", "bugs.url")
    blockers = @()
  }
  marketplacePublisherAuthorization = [pscustomobject]@{
    status = "not-verified"
    publisher = $extensionPublisher
    expectedExtensionId = $extensionId
    verificationMode = "Marketplace publisher management or vsce login with an authorized identity is required outside this local gate."
    ownerOrContributorVerified = $false
    credentialRecorded = $false
    claimAllowed = $false
    verifiedBy = $null
    blockers = @("Publisher ownership or contributor access for hitsuki-ban is not verified by this local gate.")
  }
  publishAuth = [pscustomobject]@{
    status = "not-configured"
    primaryMode = "microsoft-entra-id-workload-identity"
    requiredTool = "@vscode/vsce"
    minimumVsceForAzureCredential = "2.26.1"
    currentVsceDependency = [string]$rootPackage.devDependencies."@vscode/vsce"
    azureCredentialCommandShape = "vsce publish --azure-credential"
    legacyPatSecretName = "VSCE_PAT"
    legacyPatRetirementDate = "2026-12-01"
    environmentRead = $false
    azureCredentialConfigured = $false
    legacyPatConfigured = $false
    secretValueRecorded = $false
    claimAllowed = $false
    verifiedBy = $null
    blockers = @("Publish authentication must be configured and verified in the release publisher environment without recording credential values.")
  }
  marketplacePublicInstall = [pscustomobject]@{
    status = "not-run"
    expectedExtensionId = $extensionId
    expectedVersion = $extensionVersion
    installationSource = "Visual Studio Marketplace"
    installCommandShape = "code --install-extension hitsuki-ban.subversionr"
    installEvidenceRecorded = $false
    publicExtensionPageVerified = $false
    acquisitionEvidenceRecorded = $false
    claimAllowed = $false
    verifiedBy = $null
    blockers = @("Public Marketplace install evidence must be generated only after Marketplace publication.")
  }
  marketplace = [pscustomobject]@{
    status = "not-published"
    publicationEvidenceRecorded = $false
    claimAllowed = $false
  }
  publicCutover = [pscustomobject]@{
    status = "recorded-post-cutover"
    runbookPath = Get-RepoRelativePath $publicCutoverRunbookResolved
    evidencePath = Get-RepoRelativePath $publicCutoverEvidenceResolved
    cutoverIssue = 244
    publicationGapsIssue = 4
    baseline = [pscustomobject]@{
      status = "published"
      historyPolicy = "fresh-squash-baseline"
      privateHistoryAllowed = $false
      referenceDirectoryAllowed = $false
      secretsScanRequired = $true
      gitignoreVerificationRequired = $true
      publicPushRecorded = $true
      commit = $baselineCommit
      blockers = @()
    }
    publicRepository = [pscustomobject]@{
      status = "public"
      url = [string]$cutoverRepository.url
      resolvesToPublic = [bool]$cutoverRepository.resolvesToPublic
      defaultBranch = [string]$cutoverRepository.defaultBranch
      cutoverHeadCommit = $cutoverHeadCommit
      branchProtectionRequiredCheck = [string]$cutoverRepository.branchProtectionRequiredCheck
      branchProtectionConfigured = [bool]$cutoverRepository.branchProtectionConfigured
      privateVulnerabilityReportingEnabled = [bool]$cutoverRepository.privateVulnerabilityReportingEnabled
      metadataVerified = [bool]$cutoverRepository.metadataVerified
      topics = @("svn", "subversion", "vscode-extension", "scm")
      blockers = @(
        "Configure branch protection to require PR Fast / windows.",
        "Verify and complete public repository homepage and social metadata."
      )
    }
    ciHomeMigration = [pscustomobject]@{
      status = "public-pr-fast-green-owner-follow-up"
      workflow = [string]$cutoverCi.workflow
      requiredCheck = [string]$cutoverCi.requiredCheck
      runUrl = $ciRunUrl
      headSha = [string]$cutoverCi.headSha
      event = [string]$cutoverCi.event
      conclusion = [string]$cutoverCi.conclusion
      startedAt = [string]$cutoverCi.startedAt
      completedAt = [string]$cutoverCi.completedAt
      publicPrFastFirstRunGreen = [bool]$cutoverCi.publicPrFastFirstRunGreen
      publicHeavyWorkflowScheduleOnly = [bool]$cutoverCi.publicHeavyWorkflowScheduleOnly
      privateWorkflowsDisabled = [bool]$cutoverCi.privateWorkflowsDisabled
      privateWorkflowDisableDateRecorded = [bool]$cutoverCi.privateWorkflowDisableDateRecorded
      blockers = @("Disable private repository workflows and record the disablement date.")
    }
    cloudflareBridgeRetirement = [pscustomobject]@{
      status = [string]$cutoverCloudflare.status
      workerName = [string]$cutoverCloudflare.workerName
      publicCiReplacement = [string]$cutoverCloudflare.publicCiReplacement
      disconnected = [bool]$cutoverCloudflare.disconnected
      triggersDisabled = [bool]$cutoverCloudflare.triggersDisabled
      retirementDate = $cloudflareRetirementDate
      blockers = @()
    }
    release = [pscustomobject]@{
      status = [string]$cutoverRelease.status
      tag = [string]$cutoverRelease.tag
      tagCommit = [string]$cutoverRelease.tagCommit
      url = [string]$cutoverRelease.url
      prerelease = [bool]$cutoverRelease.prerelease
      publishedAt = [string]$cutoverRelease.publishedAt
      assets = $releaseAssets
      vsixAttached = $true
      sbomAttached = $true
      thirdPartyNoticesAttached = $true
      evidenceBundleAttached = $true
      artifactAttestationPublished = [bool]$cutoverRelease.artifactAttestationPublished
      blockers = @("Publish and verify live GitHub artifact attestation evidence in public issue #5.")
    }
    betaCandidateEvidence = $betaCandidateEvidence
    manualSteps = @(
      "Configure public branch protection for PR Fast / windows.",
      "Verify and complete public repository homepage and social metadata.",
      "Disable private repository workflows through GitHub Actions UI.",
      "Publish and verify the released VSIX GitHub artifact attestation through public issue #5.",
      "Regenerate a self-consistent Beta candidate bundle from the released VSIX and pass the unchanged Beta-G verifier."
    )
  }
  blockers = $blockers
  nonClaims = $nonClaims
  assertions = @(
    "publication gaps are bound to exact VSIX, VSIX package evidence, provenance preflight evidence, package manifests, README, LICENSE, CHANGELOG, SUPPORT, public cutover runbook, and public cutover evidence by SHA256",
    "public repository baseline, green public CI, Private Vulnerability Reporting, Cloudflare bridge retirement, public prerelease, and release asset records are recorded from hash-bound cutover evidence",
    "the published Beta candidate bundle is inconsistent, so post-cutover Beta-G regeneration remains blocked without weakening the consistency verifier",
    "publisher authorization, publish authentication, Marketplace publication, Marketplace public install, branch protection, private workflow disablement, live attestation, and previous-stable rollback remain blocked gaps"
  )
}

$outputParent = Split-Path -Parent $outputResolved
New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $outputResolved -Encoding utf8

Write-Host "Generated SubversionR publication gaps report for $Target at $outputResolved."

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

  [string]$PublicCutoverRunbookPath = "docs/release/public-cutover-runbook.md",

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
  Assert-Equal "False" ([string]$Object.$Name) "$Context $Name must remain false."
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

$blockers = @(
  "Marketplace publisher authorization is not verified by this local gap report.",
  "Marketplace publish authentication is not configured by this local gap report.",
  "Marketplace publication is not run by this local gap report.",
  "Marketplace public install evidence is not generated by this local gap report.",
  "Public repository baseline push and CI home migration are not performed by this local gap report.",
  "Private workflow disablement and Cloudflare bridge retirement remain manual cutover steps.",
  "Public GitHub release, artifact attestation publication, and PVR enablement are not performed by this local gap report.",
  "Previous stable artifact rollback evidence is not generated by this local gap report."
)

$nonClaims = @(
  "This gate is a local publication gaps report, not a publication readiness certificate.",
  "This gate records only public repository metadata from the extension manifest and no private remote, credentialed URL, or Marketplace publication URL.",
  "This gate does not verify Marketplace publisher ownership, contributor access, or authorization.",
  "This gate does not configure or validate Microsoft Entra ID workload identity, managed identity, PAT, VSCE_PAT, or any other credential.",
  "This gate does not publish to Visual Studio Marketplace.",
  "This gate does not install from Visual Studio Marketplace or prove public acquisition.",
  "This gate does not push the public repository baseline, enable branch protection or Private Vulnerability Reporting, disable private workflows, retire Cloudflare Workers Builds, create a public GitHub Release, or publish a live artifact attestation.",
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
    repositoryResolvesToPublic = "not-verified-by-local-gap-report"
    homepageResolvesToPublic = "not-verified-by-local-gap-report"
    bugsResolvesToPublic = "not-verified-by-local-gap-report"
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
    status = "blocked-pending-cutover"
    runbookPath = Get-RepoRelativePath $publicCutoverRunbookResolved
    issue = 244
    baseline = [pscustomobject]@{
      status = "not-created"
      historyPolicy = "fresh-squash-baseline"
      privateHistoryAllowed = $false
      referenceDirectoryAllowed = $false
      secretsScanRequired = $true
      gitignoreVerificationRequired = $true
      publicPushRecorded = $false
      blockers = @("Merge #236 and #243 before creating the public baseline.")
    }
    publicRepository = [pscustomobject]@{
      status = "not-verified-by-local-gap-report"
      url = "https://github.com/Hitsuki-Ban/SubversionR"
      defaultBranch = "main"
      branchProtectionRequiredCheck = "PR Fast / windows"
      branchProtectionConfigured = $false
      privateVulnerabilityReportingEnabled = $false
      metadataVerified = $false
      topics = @("svn", "subversion", "vscode-extension", "scm")
      blockers = @("Public repository settings require maintainer UI/API confirmation after baseline push.")
    }
    ciHomeMigration = [pscustomobject]@{
      status = "blocked-pending-public-baseline"
      publicPrFastFirstRunGreen = $false
      publicHeavyWorkflowScheduleOnly = $false
      privateWorkflowsDisabled = $false
      privateWorkflowDisableDateRecorded = $false
      blockers = @("Public PR Fast must be green and required before private workflows are disabled.")
    }
    cloudflareBridgeRetirement = [pscustomobject]@{
      status = "not-retired"
      workerName = "subversionr-pr-fast"
      publicCiReplacement = "PR Fast / windows"
      privateRepositoryConnectionExpectedBeforeCutover = $true
      triggersExpectedActiveBeforeCutover = $true
      disconnected = $false
      triggersDisabled = $false
      retirementDateRecorded = $false
      blockers = @("Retire only after public PR Fast is green and branch protection requires it.")
    }
    release = [pscustomobject]@{
      status = "not-created"
      tag = "v0.2.0-beta.1"
      prereleaseRequired = $true
      vsixAttached = $false
      sbomAttached = $false
      thirdPartyNoticesAttached = $false
      evidenceBundleAttached = $false
      artifactAttestationPublished = $false
      blockers = @("Public release waits for baseline, public CI, and final Beta evidence bundle.")
    }
    manualSteps = @(
      "Configure public branch protection for PR Fast / windows.",
      "Enable GitHub Private Vulnerability Reporting or document an equivalent private security reporting path.",
      "Disable private repository workflows through GitHub Actions UI.",
      "Retire the Cloudflare Workers Builds bridge through Cloudflare dashboard or API.",
      "Set public repository description, topics, homepage, and social preview."
    )
  }
  blockers = $blockers
  nonClaims = $nonClaims
  assertions = @(
    "publication gaps are bound to exact VSIX, VSIX package evidence, provenance preflight evidence, package manifests, README, LICENSE, CHANGELOG, SUPPORT, and the public cutover runbook by SHA256",
    "public repository metadata is recorded from the extension manifest; private remote URLs, credentialed URLs, and credential values are not recorded",
    "publisher authorization, publish authentication, Marketplace publication, Marketplace public install, public cutover, Cloudflare bridge retirement, and previous-stable rollback remain blocked local gaps"
  )
}

$outputParent = Split-Path -Parent $outputResolved
New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $outputResolved -Encoding utf8

Write-Host "Generated SubversionR publication gaps report for $Target at $outputResolved."

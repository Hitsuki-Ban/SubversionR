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
  [string]$SourceLockPath,

  [Parameter(Mandatory = $true)]
  [string]$PnpmLockPath,

  [Parameter(Mandatory = $true)]
  [string]$CargoLockPath,

  [Parameter(Mandatory = $true)]
  [string]$SbomPath,

  [Parameter(Mandatory = $true)]
  [string]$NoticePath,

  [Parameter(Mandatory = $true)]
  [string]$VsixEvidencePath,

  [Parameter(Mandatory = $true)]
  [string]$BackendManifestPath,

  [Parameter(Mandatory = $true)]
  [string]$CandidateAttestationContractPath,

  [Parameter(Mandatory = $true)]
  [string]$AttestationContractPath,

  [Parameter(Mandatory = $true)]
  [string]$LiveAttestationEvidencePath,

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

function Get-RequiredProperty([object]$Object, [string]$Name, [string]$Context) {
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
    throw "$Context must define $Name."
  }
  $property.Value
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

function Assert-JsonBoolean([object]$Object, [string]$Name, [bool]$Expected, [string]$Context) {
  $value = Get-RequiredProperty $Object $Name $Context
  if ($value -isnot [bool]) {
    throw "$Context $Name must be a JSON boolean."
  }
  Assert-Equal $Expected ([bool]$value) "$Context $Name must match the live attestation contract."
}

function ConvertTo-CanonicalJson([object]$Value) {
  $Value | ConvertTo-Json -Depth 100 -Compress
}

function Get-GitValue([string[]]$Arguments, [string]$Name) {
  $output = & git @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "git $Name failed with exit code $LASTEXITCODE."
  }
  [string]($output | Select-Object -First 1)
}

function Get-Categories([object]$PackageJson) {
  if ($null -eq $PackageJson.categories) {
    return @()
  }
  @($PackageJson.categories | ForEach-Object { [string]$_ })
}

function Get-Keywords([object]$PackageJson) {
  if ($null -eq $PackageJson.keywords) {
    return @()
  }
  @($PackageJson.keywords | ForEach-Object { [string]$_ })
}

function Assert-NormalizedPackageRelativePath([string]$Path, [string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "$Name must not be empty."
  }
  if ([System.IO.Path]::IsPathRooted($Path) -or $Path.Contains("\") -or $Path.Contains("../") -or $Path.Contains("/../") -or $Path -eq "." -or $Path.StartsWith("./")) {
    throw "$Name must be a normalized package-relative path: $Path"
  }
  foreach ($segment in $Path.Split("/")) {
    if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq "." -or $segment -eq "..") {
      throw "$Name must be a normalized package-relative path: $Path"
    }
  }
  $Path
}

function Get-PngDimensions([string]$Path, [string]$Name) {
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $signature = [byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
  if ($bytes.Length -lt 24) {
    throw "$Name must be a PNG file with an IHDR chunk: $Path"
  }
  for ($index = 0; $index -lt $signature.Length; $index++) {
    if ($bytes[$index] -ne $signature[$index]) {
      throw "$Name must be a PNG file: $Path"
    }
  }
  $chunkType = [System.Text.Encoding]::ASCII.GetString($bytes, 12, 4)
  if ($chunkType -ne "IHDR") {
    throw "$Name must start with a PNG IHDR chunk: $Path"
  }

  [pscustomobject]@{
    width = (([int]$bytes[16] -shl 24) -bor ([int]$bytes[17] -shl 16) -bor ([int]$bytes[18] -shl 8) -bor [int]$bytes[19])
    height = (([int]$bytes[20] -shl 24) -bor ([int]$bytes[21] -shl 16) -bor ([int]$bytes[22] -shl 8) -bor [int]$bytes[23])
  }
}

function Assert-MarketplaceIcon([string]$Path, [string]$Name) {
  if ([System.IO.Path]::GetExtension($Path) -ne ".png") {
    throw "$Name must be a PNG file: $Path"
  }
  $dimensions = Get-PngDimensions -Path $Path -Name $Name
  if ($dimensions.width -lt 128 -or $dimensions.height -lt 128) {
    throw "$Name must be at least 128x128 pixels for Marketplace presentation: $($dimensions.width)x$($dimensions.height)."
  }
  $dimensions
}

$extensionPackageResolved = Assert-File $ExtensionPackagePath "ExtensionPackagePath"
$rootPackageResolved = Assert-File $RootPackagePath "RootPackagePath"
$readmeResolved = Assert-File $ReadmePath "ReadmePath"
$licenseResolved = Assert-File $LicensePath "LicensePath"
$changelogResolved = Assert-File $ChangelogPath "ChangelogPath"
$supportResolved = Assert-File $SupportPath "SupportPath"
$sourceLockResolved = Assert-File $SourceLockPath "SourceLockPath"
$pnpmLockResolved = Assert-File $PnpmLockPath "PnpmLockPath"
$cargoLockResolved = Assert-File $CargoLockPath "CargoLockPath"
$sbomResolved = Assert-File $SbomPath "SbomPath"
$noticeResolved = Assert-File $NoticePath "NoticePath"
$vsixEvidenceResolved = Assert-File $VsixEvidencePath "VsixEvidencePath"
$backendManifestResolved = Assert-File $BackendManifestPath "BackendManifestPath"
$candidateAttestationContractResolved = Assert-File $CandidateAttestationContractPath "CandidateAttestationContractPath"
$attestationContractResolved = Assert-File $AttestationContractPath "AttestationContractPath"
$liveAttestationEvidenceResolved = Assert-File $LiveAttestationEvidencePath "LiveAttestationEvidencePath"
$outputResolved = Assert-GeneratedPath -Path $OutputPath -Name "OutputPath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-provenance-scripts"))
) -Description "target/release-evidence or target/tests/release-provenance-scripts"

$extensionPackage = Get-Content -Raw -LiteralPath $extensionPackageResolved | ConvertFrom-Json
$rootPackage = Get-Content -Raw -LiteralPath $rootPackageResolved | ConvertFrom-Json
$sbom = Get-Content -Raw -LiteralPath $sbomResolved | ConvertFrom-Json
$notice = Get-Content -Raw -LiteralPath $noticeResolved
$vsixEvidence = Get-Content -Raw -LiteralPath $vsixEvidenceResolved | ConvertFrom-Json
$backendManifest = Get-Content -Raw -LiteralPath $backendManifestResolved | ConvertFrom-Json
$candidateAttestationContract = Get-Content -Raw -LiteralPath $candidateAttestationContractResolved | ConvertFrom-Json
$attestationContract = Get-Content -Raw -LiteralPath $attestationContractResolved | ConvertFrom-Json
$liveAttestationEvidence = Get-Content -Raw -LiteralPath $liveAttestationEvidenceResolved | ConvertFrom-Json

$extensionName = [string](Get-RequiredProperty $extensionPackage "name" "Extension package")
$extensionPublisher = [string](Get-RequiredProperty $extensionPackage "publisher" "Extension package")
$extensionId = "$extensionPublisher.$extensionName"
Assert-Equal "hitsuki-ban.subversionr" $extensionId "Extension package identity must be hitsuki-ban.subversionr."
Assert-Equal "SubversionR" ([string](Get-RequiredProperty $extensionPackage "displayName" "Extension package")) "Extension display name should remain SubversionR."
Assert-Equal "MIT" ([string](Get-RequiredProperty $extensionPackage "license" "Extension package")) "Extension package license should remain MIT."
Assert-Equal "./dist/extension.js" ([string](Get-RequiredProperty $extensionPackage "main" "Extension package")) "Extension package main should point to the compiled entrypoint."

$extensionVersion = [string](Get-RequiredProperty $extensionPackage "version" "Extension package")
$extensionDescription = [string](Get-RequiredProperty $extensionPackage "description" "Extension package")
$engines = Get-RequiredProperty $extensionPackage "engines" "Extension package"
$enginesVscode = [string](Get-RequiredProperty $engines "vscode" "Extension package engines")
$categories = @(Get-Categories $extensionPackage)
Assert-True ($categories -contains "SCM Providers") "Extension package categories must include SCM Providers."
$keywords = @(Get-Keywords $extensionPackage)
$requiredKeywords = @("svn", "subversion", "source-control", "scm", "apache-subversion")
foreach ($requiredKeyword in $requiredKeywords) {
  Assert-True ($keywords -contains $requiredKeyword) "Extension package keywords must include $requiredKeyword."
}
$iconRelativePath = Assert-NormalizedPackageRelativePath -Path ([string](Get-RequiredProperty $extensionPackage "icon" "Extension package")) -Name "Extension package icon"
if (-not $iconRelativePath.EndsWith(".png", [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "Extension package icon must point to a PNG file: $iconRelativePath"
}
$extensionPackageRoot = Split-Path -Parent $extensionPackageResolved
$iconResolved = Assert-File (Join-Path $extensionPackageRoot $iconRelativePath.Replace("/", [System.IO.Path]::DirectorySeparatorChar)) "Extension package icon"
$iconDimensions = Assert-MarketplaceIcon -Path $iconResolved -Name "Extension package icon"
$iconSha256 = Get-Sha256 $iconResolved

Assert-Equal "subversionr.release.vsix-package.win32-x64.v1" ([string]$vsixEvidence.schema) "VsixEvidencePath must contain win32-x64 VSIX package evidence."
Assert-Equal $Target ([string]$vsixEvidence.target) "VSIX evidence target must match the requested target."
Assert-Equal "False" ([string]$vsixEvidence.publicReadinessClaim) "VSIX evidence publicReadinessClaim must remain false."
Assert-Equal $extensionId ([string]$vsixEvidence.extension.id) "VSIX evidence extension identity must match the package manifest."
Assert-Equal $extensionVersion ([string]$vsixEvidence.extension.version) "VSIX evidence extension version must match the package manifest."
Assert-JsonBoolean $vsixEvidence.extension "preRelease" $true "VSIX evidence extension"
$vsixEvidenceInputs = Get-RequiredProperty $vsixEvidence "inputs" "VSIX evidence"
$vsixEvidenceIcon = Get-RequiredProperty $vsixEvidenceInputs "marketplaceIcon" "VSIX evidence inputs"
Assert-Equal $iconRelativePath ([string](Get-RequiredProperty $vsixEvidenceIcon "path" "VSIX evidence Marketplace icon")) "VSIX evidence Marketplace icon path must match the package manifest."
Assert-Equal $iconSha256 ([string](Get-RequiredProperty $vsixEvidenceIcon "sha256" "VSIX evidence Marketplace icon")) "VSIX evidence Marketplace icon SHA256 must match the source package icon."
$vsixEvidenceVsix = Get-RequiredProperty $vsixEvidence "vsix" "VSIX evidence"
Assert-Equal $iconSha256 ([string](Get-RequiredProperty $vsixEvidenceVsix "marketplaceIconSha256" "VSIX evidence artifact")) "VSIX artifact Marketplace icon SHA256 must match the source package icon."

$vsixPath = Assert-GeneratedPath -Path ([string]$vsixEvidence.vsix.path) -Name "VSIX artifact" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\vsix")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-provenance-scripts"))
) -Description "target/vsix or target/tests/release-provenance-scripts"
if (-not (Test-Path -LiteralPath $vsixPath -PathType Leaf)) {
  throw "VSIX artifact must be a file: $($vsixEvidence.vsix.path)"
}
$actualVsixSha256 = Get-Sha256 $vsixPath
Assert-Equal ([string]$vsixEvidence.vsix.sha256) $actualVsixSha256 "VSIX artifact SHA256 must match VSIX package evidence."

& (Join-Path $PSScriptRoot "verify-release-attestation-subject.ps1") `
  -Target $Target `
  -ContractPath $candidateAttestationContractResolved `
  -SubjectPath $vsixPath `
  -ReleaseTag ([string]$candidateAttestationContract.release.tag)

Assert-Equal "pending-release-attestation" ([string](Get-RequiredProperty $candidateAttestationContract "status" "Candidate attestation contract")) "Candidate attestation contract status must remain pending before release."
Assert-JsonBoolean $candidateAttestationContract "publicReadinessClaim" $false "Candidate attestation contract"
Assert-JsonBoolean $candidateAttestationContract.subject "preReleaseProperty" $true "Candidate attestation contract subject"
Assert-Equal $actualVsixSha256 ([string]$candidateAttestationContract.subject.sha256) "Candidate attestation contract SHA256 must match current VSIX bytes."
Assert-Equal ([int64](Get-Item -LiteralPath $vsixPath).Length) ([int64]$candidateAttestationContract.subject.size) "Candidate attestation contract size must match current VSIX bytes."
Assert-Equal (Split-Path -Leaf $vsixPath) ([string]$candidateAttestationContract.subject.name) "Candidate attestation contract subject name must match current VSIX bytes."

Assert-Equal 1 ([int]$liveAttestationEvidence.schemaVersion) "Live attestation evidence schemaVersion should be 1."
Assert-Equal "subversionr.release.live-github-attestation.win32-x64.v1" ([string]$liveAttestationEvidence.schema) "Live attestation evidence schema must match."
Assert-JsonBoolean $liveAttestationEvidence "publicReadinessClaim" $false "Live attestation evidence"
Assert-JsonBoolean $liveAttestationEvidence "signingClaim" $false "Live attestation evidence"
Assert-Equal $Target ([string]$liveAttestationEvidence.target) "Live attestation evidence target must match."
Assert-Equal "live-attestation-verified" ([string]$liveAttestationEvidence.status) "Live attestation evidence status must be verified."
Assert-Equal (Get-RepoRelativePath $attestationContractResolved) ([string]$liveAttestationEvidence.contract.path) "Live attestation evidence must bind the attestation contract path."
Assert-Equal (Get-Sha256 $attestationContractResolved) ([string]$liveAttestationEvidence.contract.sha256) "Live attestation evidence must bind the current attestation contract bytes."
Assert-Equal ([string]$attestationContract.schema) ([string]$liveAttestationEvidence.contract.schema) "Live attestation evidence must bind the attestation contract schema."
Assert-Equal ([string]$attestationContract.release.tag) ([string]$liveAttestationEvidence.release.tag) "Live attestation release tag must match the contract."
Assert-Equal ([string]$attestationContract.release.url) ([string]$liveAttestationEvidence.release.url) "Live attestation release URL must match the contract."
Assert-Equal ([string]$attestationContract.subject.name) ([string]$liveAttestationEvidence.subject.name) "Live attestation subject name must match the contract."
Assert-Equal ([int64]$attestationContract.subject.size) ([int64]$liveAttestationEvidence.subject.size) "Live attestation subject size must match the contract."
Assert-Equal ([string]$attestationContract.subject.sha256) ([string]$liveAttestationEvidence.subject.sha256) "Historical live attestation subject SHA256 must match its contract."
Assert-Equal ([string]$attestationContract.workflow.path) ([string]$liveAttestationEvidence.workflow.path) "Live attestation workflow path must match the contract."
Assert-Equal "workflow_dispatch" ([string]$liveAttestationEvidence.workflow.event) "Live attestation workflow event must be workflow_dispatch."
Assert-True ([string]$liveAttestationEvidence.workflow.runId -match '^[0-9]+$') "Live attestation runId must contain only digits."
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/$($liveAttestationEvidence.workflow.runId)" ([string]$liveAttestationEvidence.workflow.runUrl) "Live attestation run URL must match runId."
Assert-True ([string]$liveAttestationEvidence.workflow.headSha -match '^[a-f0-9]{40}$') "Live attestation workflow headSha must be a full lowercase commit SHA."
Assert-Equal ([string]$attestationContract.attestation.provider) ([string]$liveAttestationEvidence.attestation.provider) "Live attestation provider must match the contract."
Assert-Equal ([string]$attestationContract.attestation.action) ([string]$liveAttestationEvidence.attestation.action) "Live attestation action must match the contract."
Assert-Equal ([string]$attestationContract.attestation.actionDigest) ([string]$liveAttestationEvidence.attestation.actionDigest) "Live attestation action digest must match the contract."
Assert-Equal ([string]$attestationContract.attestation.predicateType) ([string]$liveAttestationEvidence.attestation.predicateType) "Live attestation predicate type must match the contract."
Assert-Equal ([string]$attestationContract.attestation.predicateSchemaPath) ([string]$liveAttestationEvidence.attestation.predicateSchemaPath) "Live attestation predicate schema path must match the contract."
Assert-Equal "subversionr.release.post-release-asset-verification-predicate.v1" ([string]$liveAttestationEvidence.attestation.predicateSchema) "Live attestation signed predicate schema must match."
Assert-Equal "post-release-asset-digest-verification" ([string]$liveAttestationEvidence.attestation.predicateClaim) "Live attestation signed predicate claim must match."
Assert-JsonBoolean $liveAttestationEvidence.attestation "originalBuildProvenanceClaim" $false "Live attestation signed predicate"
Assert-JsonBoolean $liveAttestationEvidence.attestation "artifactSignatureClaim" $false "Live attestation signed predicate"
Assert-True ([string]$liveAttestationEvidence.attestation.id -match '^[0-9]+$') "Live attestation id must contain only digits."
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/attestations/$($liveAttestationEvidence.attestation.id)" ([string]$liveAttestationEvidence.attestation.url) "Live attestation URL must match id."
$attestationBundleResolved = Assert-File ([string](Get-RequiredProperty $liveAttestationEvidence.attestation "bundlePath" "Live attestation evidence attestation")) "Live attestation bundle"
Assert-Equal (Get-Sha256 $attestationBundleResolved) ([string]$liveAttestationEvidence.attestation.bundleSha256) "Live attestation bundle SHA256 must match current bytes."
Assert-JsonBoolean $liveAttestationEvidence.verification "verified" $true "Live attestation verification"
Assert-JsonBoolean $liveAttestationEvidence.verification "denySelfHostedRunners" $true "Live attestation verification"
Assert-JsonBoolean $liveAttestationEvidence.verification "bundleMatched" $true "Live attestation verification"
Assert-Equal ([string]$attestationContract.verificationPolicy.repository) ([string]$liveAttestationEvidence.verification.repository) "Live attestation verification repository must match the contract."
Assert-Equal ([string]$attestationContract.verificationPolicy.signerWorkflow) ([string]$liveAttestationEvidence.verification.signerWorkflow) "Live attestation signer workflow must match the contract."
Assert-Equal ([string]$attestationContract.verificationPolicy.predicateType) ([string]$liveAttestationEvidence.verification.predicateType) "Live attestation verification predicate type must match the contract."
Assert-Equal ([string]$attestationContract.verificationPolicy.format) ([string]$liveAttestationEvidence.verification.format) "Live attestation verification format must match the contract."
$attestationVerificationResolved = Assert-File ([string](Get-RequiredProperty $liveAttestationEvidence.verification "resultPath" "Live attestation verification")) "Live attestation verification result"
Assert-Equal (Get-Sha256 $attestationVerificationResolved) ([string]$liveAttestationEvidence.verification.resultSha256) "Live attestation verification result SHA256 must match current bytes."
$attestationBundles = @(Get-Content -Raw -LiteralPath $attestationBundleResolved | ConvertFrom-Json)
$attestationVerificationResults = @(Get-Content -Raw -LiteralPath $attestationVerificationResolved | ConvertFrom-Json)
Assert-Equal 1 $attestationBundles.Count "Source-controlled attestation bundle must contain exactly one bundle."
Assert-Equal 1 $attestationVerificationResults.Count "Source-controlled attestation verification must contain exactly one result."
Assert-Equal (ConvertTo-CanonicalJson $attestationBundles[0]) (ConvertTo-CanonicalJson $attestationVerificationResults[0].attestation.bundle) "Source-controlled verification result must contain the exact attestation bundle."
$expectedProductionAttestationPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "docs\release\github-attestation-evidence.win32-x64.json"))
if ($liveAttestationEvidenceResolved.Equals($expectedProductionAttestationPath, [System.StringComparison]::OrdinalIgnoreCase)) {
  Assert-Equal ([System.IO.Path]::GetFullPath((Join-Path $repoRoot "docs\release\github-attestation-bundle.win32-x64.json"))) $attestationBundleResolved "Production provenance must bind the source-controlled attestation bundle."
  Assert-Equal ([System.IO.Path]::GetFullPath((Join-Path $repoRoot "docs\release\github-attestation-verification.win32-x64.json"))) $attestationVerificationResolved "Production provenance must bind the source-controlled attestation verification result."
}

Assert-Equal "CycloneDX" ([string]$sbom.bomFormat) "SBOM evidence must use CycloneDX."
Assert-Equal "1.6" ([string]$sbom.specVersion) "SBOM evidence must use CycloneDX 1.6."
Assert-True ($notice.Contains("SubversionR Third-Party Notices")) "NOTICE evidence must identify SubversionR third-party notices."
Assert-True ($notice.Contains("This generated evidence is not a completed legal review")) "NOTICE evidence must preserve the legal-review non-claim."

Assert-Equal "subversionr.vscode.backend-package.win32-x64.v1" ([string]$backendManifest.schema) "Backend manifest schema must match win32-x64."
Assert-Equal $Target ([string]$backendManifest.target) "Backend manifest target must match the requested target."
Assert-Equal "subversionr" ([string]$backendManifest.extension.id) "Backend manifest must bind the extension id."
Assert-Equal $extensionVersion ([string]$backendManifest.extension.version) "Backend manifest version must match the package manifest."

$headCommit = Get-GitValue @("rev-parse", "HEAD") "rev-parse HEAD"
$branch = Get-GitValue @("branch", "--show-current") "branch --show-current"
$statusOutput = & git status --porcelain
if ($LASTEXITCODE -ne 0) {
  throw "git status --porcelain failed with exit code $LASTEXITCODE."
}
$dirtyWorkingTree = @($statusOutput).Count -gt 0

$requiredMetadata = [pscustomobject]@{
  hasPublisher = -not [string]::IsNullOrWhiteSpace($extensionPublisher)
  hasName = -not [string]::IsNullOrWhiteSpace($extensionName)
  hasDisplayName = -not [string]::IsNullOrWhiteSpace([string]$extensionPackage.displayName)
  hasDescription = -not [string]::IsNullOrWhiteSpace($extensionDescription)
  hasVersion = -not [string]::IsNullOrWhiteSpace($extensionVersion)
  hasLicense = -not [string]::IsNullOrWhiteSpace([string]$extensionPackage.license)
  hasEnginesVscode = -not [string]::IsNullOrWhiteSpace($enginesVscode)
  hasCategories = $categories.Count -gt 0
  hasKeywords = $keywords.Count -gt 0
  hasMain = -not [string]::IsNullOrWhiteSpace([string]$extensionPackage.main)
  hasIcon = -not [string]::IsNullOrWhiteSpace($iconRelativePath)
  hasReadme = Test-Path -LiteralPath $readmeResolved -PathType Leaf
  hasLicenseFile = Test-Path -LiteralPath $licenseResolved -PathType Leaf
}
$recommendedMetadata = [pscustomobject]@{
  hasChangelog = Test-Path -LiteralPath $changelogResolved -PathType Leaf
  hasSupport = Test-Path -LiteralPath $supportResolved -PathType Leaf
  hasGalleryBanner = $null -ne $extensionPackage.PSObject.Properties["galleryBanner"]
  hasRepository = $null -ne $extensionPackage.PSObject.Properties["repository"]
  hasHomepage = $null -ne $extensionPackage.PSObject.Properties["homepage"]
  hasBugs = $null -ne $extensionPackage.PSObject.Properties["bugs"]
  privatePackage = $null -ne $extensionPackage.PSObject.Properties["private"] -and [bool]$extensionPackage.private
  rootPrivatePackage = $null -ne $rootPackage.PSObject.Properties["private"] -and [bool]$rootPackage.private
}

$metadataBlockers = @()
foreach ($property in $requiredMetadata.PSObject.Properties) {
  if (-not [bool]$property.Value) {
    $metadataBlockers += "Missing required Marketplace metadata: $($property.Name)"
  }
}
if (-not $recommendedMetadata.hasGalleryBanner) {
  $metadataBlockers += "Marketplace gallery banner is not configured yet."
}
$metadataBlockers += "Marketplace publisher authorization is not verified by this local preflight."
$metadataBlockers += "Marketplace publish authentication is not configured by this local preflight."
$metadataBlockers += "Marketplace/public install evidence is not generated by this local preflight."
$metadataBlockers += "Previous stable artifact rollback evidence is not generated by this local preflight."

$nonClaims = @(
  "This gate does not prove VSIX signing.",
  "This gate records the current candidate attestation contract as pending; it does not claim current-candidate live attestation.",
  "This gate preserves historical GitHub artifact attestation publication and verification without applying it to the current candidate.",
  "The historical post-release attestation does not prove the current VSIX source-to-binary build provenance.",
  "This gate does not prove Marketplace publication or public install.",
  "This gate does not prove previous-stable upgrade or rollback.",
  "This gate does not prove installed Source Control DOM/accessibility-tree/pixel E2E.",
  "This gate does not prove final SBOM, NOTICE, or CVE review completion."
)

$vsixRelativePath = Get-RepoRelativePath $vsixPath
$vsixFileName = Split-Path -Leaf $vsixPath
$attestationWorkflowPath = [string]$attestationContract.workflow.path
$attestationRequiredPermissions = @($attestationContract.workflow.requiredPermissions | ForEach-Object { [string]$_ })
$attestationVerifyCommand = [string]$liveAttestationEvidence.verification.command

$report = [pscustomobject]@{
  schemaVersion = 1
  schema = "subversionr.release.marketplace-provenance-preflight.win32-x64.v1"
  publicReadinessClaim = $false
  localPreflightOnly = $true
  target = $Target
  traceIds = @("SEC-015", "MIG-009", "MIG-012")
  generatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
  extension = [pscustomobject]@{
    id = $extensionId
    name = $extensionName
    publisher = $extensionPublisher
    displayName = [string]$extensionPackage.displayName
    version = $extensionVersion
    preRelease = $true
    description = $extensionDescription
    license = [string]$extensionPackage.license
    enginesVscode = $enginesVscode
    categories = $categories
    keywords = $keywords
    icon = [pscustomobject]@{
      path = $iconRelativePath
      width = $iconDimensions.width
      height = $iconDimensions.height
      sha256 = $iconSha256
    }
    privatePackage = $recommendedMetadata.privatePackage
  }
  repository = [pscustomobject]@{
    headCommit = $headCommit
    branch = $branch
    dirtyWorkingTree = $dirtyWorkingTree
    remoteUrlRecorded = $false
  }
  artifacts = [pscustomobject]@{
    vsix = [pscustomobject]@{
      path = $vsixPath
      relativePath = $vsixRelativePath
      size = (Get-Item -LiteralPath $vsixPath).Length
      sha256 = $actualVsixSha256
      evidencePath = Get-RepoRelativePath $vsixEvidenceResolved
      evidenceSha256 = Get-Sha256 $vsixEvidenceResolved
    }
    backendManifest = [pscustomobject]@{
      path = Get-RepoRelativePath $backendManifestResolved
      sha256 = Get-Sha256 $backendManifestResolved
    }
  }
  evidence = [pscustomobject]@{
    extensionPackage = [pscustomobject]@{ path = Get-RepoRelativePath $extensionPackageResolved; sha256 = Get-Sha256 $extensionPackageResolved }
    rootPackage = [pscustomobject]@{ path = Get-RepoRelativePath $rootPackageResolved; sha256 = Get-Sha256 $rootPackageResolved }
    readme = [pscustomobject]@{ path = Get-RepoRelativePath $readmeResolved; sha256 = Get-Sha256 $readmeResolved }
    license = [pscustomobject]@{ path = Get-RepoRelativePath $licenseResolved; sha256 = Get-Sha256 $licenseResolved }
    changelog = [pscustomobject]@{ path = Get-RepoRelativePath $changelogResolved; sha256 = Get-Sha256 $changelogResolved }
    support = [pscustomobject]@{ path = Get-RepoRelativePath $supportResolved; sha256 = Get-Sha256 $supportResolved }
    marketplaceIcon = [pscustomobject]@{ path = Get-RepoRelativePath $iconResolved; sha256 = $iconSha256 }
    sourceLock = [pscustomobject]@{ path = Get-RepoRelativePath $sourceLockResolved; sha256 = Get-Sha256 $sourceLockResolved }
    pnpmLock = [pscustomobject]@{ path = Get-RepoRelativePath $pnpmLockResolved; sha256 = Get-Sha256 $pnpmLockResolved }
    cargoLock = [pscustomobject]@{ path = Get-RepoRelativePath $cargoLockResolved; sha256 = Get-Sha256 $cargoLockResolved }
    sbom = [pscustomobject]@{ path = Get-RepoRelativePath $sbomResolved; sha256 = Get-Sha256 $sbomResolved }
    notice = [pscustomobject]@{ path = Get-RepoRelativePath $noticeResolved; sha256 = Get-Sha256 $noticeResolved }
    candidateAttestationContract = [pscustomobject]@{ path = Get-RepoRelativePath $candidateAttestationContractResolved; sha256 = Get-Sha256 $candidateAttestationContractResolved; schema = [string]$candidateAttestationContract.schema }
    attestationContract = [pscustomobject]@{ path = Get-RepoRelativePath $attestationContractResolved; sha256 = Get-Sha256 $attestationContractResolved; schema = [string]$attestationContract.schema }
    liveAttestation = [pscustomobject]@{ path = Get-RepoRelativePath $liveAttestationEvidenceResolved; sha256 = Get-Sha256 $liveAttestationEvidenceResolved; schema = [string]$liveAttestationEvidence.schema }
    attestationBundle = [pscustomobject]@{ path = Get-RepoRelativePath $attestationBundleResolved; sha256 = Get-Sha256 $attestationBundleResolved; mediaType = [string]$attestationBundles[0].mediaType }
    attestationVerification = [pscustomobject]@{ path = Get-RepoRelativePath $attestationVerificationResolved; sha256 = Get-Sha256 $attestationVerificationResolved; mediaType = [string]$attestationVerificationResults[0].verificationResult.mediaType }
  }
  marketplaceMetadata = [pscustomobject]@{
    publicationReady = $false
    required = $requiredMetadata
    recommended = $recommendedMetadata
    icon = [pscustomobject]@{
      packagePath = $iconRelativePath
      width = $iconDimensions.width
      height = $iconDimensions.height
      sha256 = $iconSha256
      vsixEvidenceSha256 = [string]$vsixEvidence.vsix.marketplaceIconSha256
    }
    blockers = $metadataBlockers
  }
  signing = [pscustomobject]@{
    status = "unsigned"
    requiredNext = "Sign VSIX/native release artifacts with the approved release signing process."
  }
  candidateAttestation = [pscustomobject]@{
    status = "pending-release-attestation"
    scope = "current-candidate"
    contractPath = Get-RepoRelativePath $candidateAttestationContractResolved
    contractSha256 = Get-Sha256 $candidateAttestationContractResolved
    releaseTag = [string]$candidateAttestationContract.release.tag
    releaseUrl = [string]$candidateAttestationContract.release.url
    subjectName = $vsixFileName
    subjectSha256 = $actualVsixSha256
    subjectSize = (Get-Item -LiteralPath $vsixPath).Length
    preReleaseProperty = $true
    liveEvidenceRecorded = $false
    claimAllowed = $true
    blockers = @("Create the contracted GitHub release and publish its live artifact attestation.")
  }
  attestation = [pscustomobject]@{
    status = "verified"
    scope = "historical-public-cutover-release"
    reason = "The historical public-cutover VSIX has a post-release GitHub artifact attestation verified against the exact bundle, signer workflow, source ref, source digest, and run policy."
    readiness = [pscustomobject]@{
      readinessStatus = "live-attestation-verified"
      provider = [string]$attestationContract.attestation.provider
      action = [string]$attestationContract.attestation.action
      actionDigest = [string]$attestationContract.attestation.actionDigest
      predicateType = [string]$attestationContract.attestation.predicateType
      predicateSchemaPath = [string]$attestationContract.attestation.predicateSchemaPath
      predicateSchema = [string]$liveAttestationEvidence.attestation.predicateSchema
      predicateClaim = [string]$liveAttestationEvidence.attestation.predicateClaim
      originalBuildProvenanceClaim = [bool]$liveAttestationEvidence.attestation.originalBuildProvenanceClaim
      artifactSignatureClaim = [bool]$liveAttestationEvidence.attestation.artifactSignatureClaim
      subjectName = [string]$liveAttestationEvidence.subject.name
      subjectSha256 = [string]$liveAttestationEvidence.subject.sha256
      artifactPath = [string]$liveAttestationEvidence.subject.path
      artifactSize = [int64]$liveAttestationEvidence.subject.size
      workflowPath = $attestationWorkflowPath
      requiredPermissions = $attestationRequiredPermissions
      verificationCommand = $attestationVerifyCommand
      repoUrlRecorded = $true
      bundleRecorded = $true
      attestationUrlRecorded = $true
      verified = $true
      repositoryUrl = "https://github.com/Hitsuki-Ban/SubversionR"
      runUrl = [string]$liveAttestationEvidence.workflow.runUrl
      attestationUrl = [string]$liveAttestationEvidence.attestation.url
      bundleSha256 = [string]$liveAttestationEvidence.attestation.bundleSha256
      bundlePath = Get-RepoRelativePath $attestationBundleResolved
      verificationResultPath = Get-RepoRelativePath $attestationVerificationResolved
      verificationResultSha256 = Get-Sha256 $attestationVerificationResolved
      sourceRef = [string]$liveAttestationEvidence.workflow.sourceRef
      sourceDigest = [string]$liveAttestationEvidence.workflow.headSha
      signerDigest = [string]$liveAttestationEvidence.workflow.headSha
      evidencePath = Get-RepoRelativePath $liveAttestationEvidenceResolved
      evidenceSha256 = Get-Sha256 $liveAttestationEvidenceResolved
    }
  }
  marketplace = [pscustomobject]@{
    status = "not-published"
    reason = "This gate does not use Marketplace credentials or publish the extension."
  }
  previousStableRollback = [pscustomobject]@{
    status = "not-proven"
    reason = "No previous stable public SubversionR artifact exists for this preflight gate."
  }
  nonClaims = $nonClaims
  assertions = @(
    "exact VSIX bytes are bound by SHA256",
    "the current candidate is bound to an exact pending release-attestation contract without claiming live attestation",
    "historical GitHub artifact attestation evidence remains bound to its own released VSIX, workflow run, attestation URL, source ref/digest, verification policy, bundle bytes, and verification-result bytes",
    "Marketplace icon is present, at least 128x128 pixels, packaged into the VSIX, and bound by SHA256",
    "VSIX package evidence remains publicReadinessClaim false",
    "source lock, pnpm lock, Cargo lock, SBOM, NOTICE, package metadata, and backend manifest are bound by SHA256",
    "repository remote URL is not recorded",
    "signing, Marketplace publication, previous-stable rollback, DOM/accessibility/pixel E2E, final SBOM/NOTICE/CVE review, and public readiness remain explicit non-claims"
  )
}

$outputParent = Split-Path -Parent $outputResolved
New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $outputResolved -Encoding utf8

Write-Host "Generated SubversionR release provenance preflight for $Target at $outputResolved."

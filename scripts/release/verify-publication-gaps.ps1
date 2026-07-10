[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$EvidencePath
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

function Assert-RequiredString([object]$Object, [string]$Name, [string]$Context) {
  if (-not (Test-HasProperty $Object $Name) -or [string]::IsNullOrWhiteSpace([string]$Object.$Name)) {
    throw "$Context must define $Name."
  }
  [string]$Object.$Name
}

function Assert-RequiredBooleanFalse([object]$Object, [string]$Name, [string]$Context) {
  if (-not (Test-HasProperty $Object $Name)) {
    throw "$Context must define $Name."
  }
  Assert-Equal "False" ([string]$Object.$Name) "$Context $Name must remain false."
}

function Assert-NoProperty([object]$Object, [string]$Name, [string]$Context) {
  if (Test-HasProperty $Object $Name) {
    throw "$Context must not record $Name."
  }
}

function Assert-HashRecord([object]$Record, [string]$Name) {
  $path = [string]$Record.path
  $expectedSha256 = [string]$Record.sha256
  if ([string]::IsNullOrWhiteSpace($path) -or $expectedSha256 -notmatch '^[a-f0-9]{64}$') {
    throw "$Name must include path and SHA256."
  }
  $resolved = Assert-File $path $Name
  Assert-Equal $expectedSha256 (Get-Sha256 $resolved) "$Name SHA256 must match current bytes."
}

function Assert-ArrayContainsExactlyOnce([object[]]$Values, [string]$Expected, [string]$Context) {
  Assert-True (@($Values | Where-Object { [string]$_ -eq $Expected }).Count -eq 1) "$Context must include '$Expected'."
}

function Assert-NoForbiddenEvidenceText([string]$Text) {
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
    'trigger_uuid',
    'marketplace\.visualstudio\.com/items\?itemName=hitsuki-ban\.subversionr'
  )

  foreach ($pattern in $patterns) {
    if ($Text -match $pattern) {
      throw "Publication gaps evidence must not record credentials, private repository URLs, or public Marketplace publication URLs."
    }
  }
}

$evidenceResolved = Assert-GeneratedPath -Path $EvidencePath -Name "EvidencePath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-publication-gaps-scripts"))
) -Description "target/release-evidence or target/tests/release-publication-gaps-scripts"
$rawEvidence = Get-Content -Raw -LiteralPath $evidenceResolved
Assert-NoForbiddenEvidenceText $rawEvidence
$report = $rawEvidence | ConvertFrom-Json

Assert-Equal 1 ([int]$report.schemaVersion) "Publication gaps schemaVersion should be 1."
Assert-Equal "subversionr.release.publication-gaps.win32-x64.v1" ([string]$report.schema) "Publication gaps schema should match M7k2b."
Assert-Equal $Target ([string]$report.target) "Publication gaps target should match the requested target."
Assert-Equal "False" ([string]$report.publicReadinessClaim) "publicReadinessClaim must remain false."
Assert-Equal "True" ([string]$report.localGapReportOnly) "localGapReportOnly must remain true."
Assert-Equal "hitsuki-ban.subversionr" ([string]$report.extension.id) "Extension identity must remain hitsuki-ban.subversionr."
Assert-Equal "hitsuki-ban" ([string]$report.extension.publisher) "Extension publisher must remain hitsuki-ban."
Assert-Equal "False" ([string]$report.extension.privatePackage) "Extension package must not remain private in this gate."
Assert-Equal "True" ([string]$report.rootPackage.privatePackage) "Root package must remain private in this gate."

foreach ($traceId in @("SEC-015", "MIG-009", "MIG-012", "TST-024")) {
  Assert-ArrayContainsExactlyOnce -Values @($report.traceIds) -Expected $traceId -Context "Publication gaps trace IDs"
}

Assert-Equal "configured" ([string]$report.publicRepositoryMetadata.status) "Public repository metadata must be configured."
Assert-Equal "configured-in-extension-manifest" ([string]$report.publicRepositoryMetadata.fieldPolicy) "Public repository metadata field policy must bind the extension manifest."
Assert-Equal "True" ([string]$report.publicRepositoryMetadata.claimAllowed) "Public repository metadata claim should be allowed."
Assert-Equal "True" ([string]$report.publicRepositoryMetadata.repositoryFieldPresent) "Public repository metadata must record repository field presence."
Assert-Equal "True" ([string]$report.publicRepositoryMetadata.homepageFieldPresent) "Public repository metadata must record homepage field presence."
Assert-Equal "True" ([string]$report.publicRepositoryMetadata.bugsFieldPresent) "Public repository metadata must record bugs field presence."
Assert-Equal "True" ([string]$report.publicRepositoryMetadata.repositoryUrlRecorded) "Public repository metadata must record repository URL."
Assert-Equal "True" ([string]$report.publicRepositoryMetadata.homepageUrlRecorded) "Public repository metadata must record homepage URL."
Assert-Equal "True" ([string]$report.publicRepositoryMetadata.bugsUrlRecorded) "Public repository metadata must record bugs URL."
Assert-Equal "not-verified-by-local-gap-report" ([string]$report.publicRepositoryMetadata.repositoryResolvesToPublic) "Repository public resolution must remain a non-live local claim."
Assert-Equal "not-verified-by-local-gap-report" ([string]$report.publicRepositoryMetadata.homepageResolvesToPublic) "Homepage public resolution must remain a non-live local claim."
Assert-Equal "not-verified-by-local-gap-report" ([string]$report.publicRepositoryMetadata.bugsResolvesToPublic) "Issue tracker public resolution must remain a non-live local claim."
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR.git" ([string]$report.publicRepositoryMetadata.repositoryUrl) "Public repository URL must match the extension manifest."
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR#readme" ([string]$report.publicRepositoryMetadata.homepageUrl) "Public homepage URL must match the extension manifest."
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/issues" ([string]$report.publicRepositoryMetadata.bugsUrl) "Public issue tracker URL must match the extension manifest."

Assert-Equal "not-verified" ([string]$report.marketplacePublisherAuthorization.status) "Marketplace publisher authorization must remain not-verified."
Assert-Equal "hitsuki-ban" ([string]$report.marketplacePublisherAuthorization.publisher) "Marketplace publisher authorization must bind publisher hitsuki-ban."
Assert-Equal "hitsuki-ban.subversionr" ([string]$report.marketplacePublisherAuthorization.expectedExtensionId) "Marketplace publisher authorization must bind extension id."
Assert-RequiredBooleanFalse $report.marketplacePublisherAuthorization "ownerOrContributorVerified" "Marketplace publisher authorization"
Assert-RequiredBooleanFalse $report.marketplacePublisherAuthorization "credentialRecorded" "Marketplace publisher authorization"
Assert-RequiredBooleanFalse $report.marketplacePublisherAuthorization "claimAllowed" "Marketplace publisher authorization"
Assert-NoProperty $report.marketplacePublisherAuthorization "token" "Marketplace publisher authorization"
Assert-NoProperty $report.marketplacePublisherAuthorization "pat" "Marketplace publisher authorization"
Assert-NoProperty $report.marketplacePublisherAuthorization "authorizationHeader" "Marketplace publisher authorization"

Assert-Equal "not-configured" ([string]$report.publishAuth.status) "Publish auth must remain not-configured."
Assert-Equal "microsoft-entra-id-workload-identity" ([string]$report.publishAuth.primaryMode) "Publish auth primary mode should track the official Entra ID workload identity path."
Assert-Equal "@vscode/vsce" ([string]$report.publishAuth.requiredTool) "Publish auth must name @vscode/vsce."
Assert-Equal "2.26.1" ([string]$report.publishAuth.minimumVsceForAzureCredential) "Publish auth must record the documented minimum vsce version for --azure-credential."
Assert-Equal "VSCE_PAT" ([string]$report.publishAuth.legacyPatSecretName) "Publish auth must record only the legacy secret name contract."
Assert-Equal "2026-12-01" ([string]$report.publishAuth.legacyPatRetirementDate) "Publish auth must record the global PAT retirement date."
Assert-RequiredBooleanFalse $report.publishAuth "environmentRead" "Publish auth"
Assert-RequiredBooleanFalse $report.publishAuth "azureCredentialConfigured" "Publish auth"
Assert-RequiredBooleanFalse $report.publishAuth "legacyPatConfigured" "Publish auth"
Assert-RequiredBooleanFalse $report.publishAuth "secretValueRecorded" "Publish auth"
Assert-RequiredBooleanFalse $report.publishAuth "claimAllowed" "Publish auth"
Assert-NoProperty $report.publishAuth "tokenValue" "Publish auth"
Assert-NoProperty $report.publishAuth "secretValue" "Publish auth"
Assert-NoProperty $report.publishAuth "authorizationHeader" "Publish auth"

Assert-Equal "not-run" ([string]$report.marketplacePublicInstall.status) "Marketplace public install must remain not-run."
Assert-Equal "hitsuki-ban.subversionr" ([string]$report.marketplacePublicInstall.expectedExtensionId) "Marketplace public install must bind extension id."
Assert-Equal "Visual Studio Marketplace" ([string]$report.marketplacePublicInstall.installationSource) "Marketplace public install must name the Marketplace source."
Assert-RequiredBooleanFalse $report.marketplacePublicInstall "installEvidenceRecorded" "Marketplace public install"
Assert-RequiredBooleanFalse $report.marketplacePublicInstall "publicExtensionPageVerified" "Marketplace public install"
Assert-RequiredBooleanFalse $report.marketplacePublicInstall "acquisitionEvidenceRecorded" "Marketplace public install"
Assert-RequiredBooleanFalse $report.marketplacePublicInstall "claimAllowed" "Marketplace public install"
Assert-NoProperty $report.marketplacePublicInstall "marketplaceUrl" "Marketplace public install"
Assert-NoProperty $report.marketplacePublicInstall "installLog" "Marketplace public install"

Assert-Equal "not-published" ([string]$report.marketplace.status) "Marketplace status must remain not-published."
Assert-RequiredBooleanFalse $report.marketplace "publicationEvidenceRecorded" "Marketplace"
Assert-RequiredBooleanFalse $report.marketplace "claimAllowed" "Marketplace"

foreach ($blocker in @(
    "Marketplace publisher authorization is not verified by this local gap report.",
    "Marketplace publish authentication is not configured by this local gap report.",
    "Marketplace publication is not run by this local gap report.",
    "Marketplace public install evidence is not generated by this local gap report.",
    "Public repository baseline push and CI home migration are not performed by this local gap report.",
    "Private workflow disablement and Cloudflare bridge retirement remain manual cutover steps.",
    "Public GitHub release, artifact attestation publication, and PVR enablement are not performed by this local gap report.",
    "Previous stable artifact rollback evidence is not generated by this local gap report."
  )) {
  Assert-ArrayContainsExactlyOnce -Values @($report.blockers) -Expected $blocker -Context "Publication gaps blockers"
}

foreach ($nonClaim in @(
    "This gate is a local publication gaps report, not a publication readiness certificate.",
    "This gate records only public repository metadata from the extension manifest and no private remote, credentialed URL, or Marketplace publication URL.",
    "This gate does not verify Marketplace publisher ownership, contributor access, or authorization.",
    "This gate does not configure or validate Microsoft Entra ID workload identity, managed identity, PAT, VSCE_PAT, or any other credential.",
    "This gate does not publish to Visual Studio Marketplace.",
    "This gate does not install from Visual Studio Marketplace or prove public acquisition.",
    "This gate does not push the public repository baseline, enable branch protection or Private Vulnerability Reporting, disable private workflows, retire Cloudflare Workers Builds, create a public GitHub Release, or publish a live artifact attestation.",
    "This gate does not prove VSIX signing, live GitHub artifact attestation generation/publication/verification, previous-stable rollback, final SBOM/NOTICE review, or CVE review."
  )) {
  Assert-ArrayContainsExactlyOnce -Values @($report.nonClaims) -Expected $nonClaim -Context "Publication gaps nonClaims"
}

$vsixPath = Assert-GeneratedPath -Path ([string]$report.artifacts.vsix.path) -Name "VSIX artifact" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\vsix")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-publication-gaps-scripts"))
) -Description "target/vsix or target/tests/release-publication-gaps-scripts"
if (-not (Test-Path -LiteralPath $vsixPath -PathType Leaf)) {
  throw "VSIX artifact must be a file: $($report.artifacts.vsix.path)"
}
Assert-Equal ([string]$report.artifacts.vsix.sha256) (Get-Sha256 $vsixPath) "VSIX SHA256 must match current bytes."
Assert-Equal ([int64](Get-Item -LiteralPath $vsixPath).Length) ([int64]$report.artifacts.vsix.size) "VSIX size must match current bytes."

Assert-HashRecord $report.evidence.extensionPackage "Extension package"
Assert-HashRecord $report.evidence.rootPackage "Root package"
Assert-HashRecord $report.evidence.readme "README"
Assert-HashRecord $report.evidence.license "LICENSE"
Assert-HashRecord $report.evidence.changelog "CHANGELOG"
Assert-HashRecord $report.evidence.support "SUPPORT"
Assert-HashRecord $report.evidence.publicCutoverRunbook "Public cutover runbook"
Assert-HashRecord $report.evidence.provenancePreflight "Provenance preflight"
Assert-HashRecord $report.evidence.vsixPackage "VSIX package evidence"
Assert-Equal "subversionr.release.marketplace-provenance-preflight.win32-x64.v1" (Assert-RequiredString $report.evidence.provenancePreflight "schema" "Provenance preflight evidence") "Provenance preflight schema must be bound."
Assert-Equal "subversionr.release.vsix-package.win32-x64.v1" (Assert-RequiredString $report.evidence.vsixPackage "schema" "VSIX package evidence") "VSIX package evidence schema must be bound."

Assert-Equal "blocked-pending-cutover" ([string]$report.publicCutover.status) "Public cutover must remain blocked before the public baseline."
Assert-Equal "docs/release/public-cutover-runbook.md" ([string]$report.publicCutover.runbookPath) "Public cutover must bind the runbook path."
Assert-Equal 244 ([int]$report.publicCutover.issue) "Public cutover must bind issue #244."
Assert-Equal "not-created" ([string]$report.publicCutover.baseline.status) "Public cutover baseline must remain not-created."
Assert-Equal "fresh-squash-baseline" ([string]$report.publicCutover.baseline.historyPolicy) "Public cutover baseline must use the fresh baseline policy."
Assert-RequiredBooleanFalse $report.publicCutover.baseline "privateHistoryAllowed" "Public cutover baseline"
Assert-RequiredBooleanFalse $report.publicCutover.baseline "referenceDirectoryAllowed" "Public cutover baseline"
Assert-RequiredBooleanFalse $report.publicCutover.baseline "publicPushRecorded" "Public cutover baseline"
Assert-Equal "not-verified-by-local-gap-report" ([string]$report.publicCutover.publicRepository.status) "Public repository live state must remain unverified by this local gap report."
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR" ([string]$report.publicCutover.publicRepository.url) "Public repository URL must be recorded."
Assert-Equal "PR Fast / windows" ([string]$report.publicCutover.publicRepository.branchProtectionRequiredCheck) "Public branch protection required check must be recorded."
Assert-RequiredBooleanFalse $report.publicCutover.publicRepository "branchProtectionConfigured" "Public repository"
Assert-RequiredBooleanFalse $report.publicCutover.publicRepository "privateVulnerabilityReportingEnabled" "Public repository"
Assert-Equal "blocked-pending-public-baseline" ([string]$report.publicCutover.ciHomeMigration.status) "CI home migration must remain blocked before baseline."
Assert-RequiredBooleanFalse $report.publicCutover.ciHomeMigration "publicPrFastFirstRunGreen" "CI home migration"
Assert-RequiredBooleanFalse $report.publicCutover.ciHomeMigration "privateWorkflowsDisabled" "CI home migration"
Assert-Equal "not-retired" ([string]$report.publicCutover.cloudflareBridgeRetirement.status) "Cloudflare bridge retirement must remain not-retired."
Assert-Equal "subversionr-pr-fast" ([string]$report.publicCutover.cloudflareBridgeRetirement.workerName) "Cloudflare bridge retirement must bind the worker name."
Assert-RequiredBooleanFalse $report.publicCutover.cloudflareBridgeRetirement "disconnected" "Cloudflare bridge retirement"
Assert-RequiredBooleanFalse $report.publicCutover.cloudflareBridgeRetirement "triggersDisabled" "Cloudflare bridge retirement"
Assert-Equal "not-created" ([string]$report.publicCutover.release.status) "Public release must remain not-created."
Assert-Equal "v0.2.0-beta.1" ([string]$report.publicCutover.release.tag) "Public release tag must be recorded."
Assert-RequiredBooleanFalse $report.publicCutover.release "artifactAttestationPublished" "Public release"

Write-Host "Verified SubversionR publication gaps report for $Target at $evidenceResolved."

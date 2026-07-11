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
  if (-not (Test-IsPathWithin -Path $absolute -Root $repoRoot)) {
    throw "$Name must resolve inside the repository: $Path"
  }
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

function Assert-RequiredJsonString([object]$Object, [string]$Name, [string]$Context) {
  if (-not (Test-HasProperty $Object $Name)) {
    throw "$Context must define $Name."
  }
  if ($Object.$Name -isnot [string] -or [string]::IsNullOrWhiteSpace($Object.$Name)) {
    throw "$Context $Name must be a non-empty JSON string."
  }
  $Object.$Name
}

function Assert-OnlyProperties([object]$Object, [string[]]$Allowed, [string]$Context) {
  foreach ($property in @($Object.PSObject.Properties.Name)) {
    if ($property -notin $Allowed) {
      throw "$Context contains unexpected property '$property'."
    }
  }
}

function Get-RequiredProperty([object]$Object, [string]$Name, [string]$Context) {
  if (-not (Test-HasProperty $Object $Name)) {
    throw "$Context must define $Name."
  }
  $Object.$Name
}

function Assert-RequiredBooleanFalse([object]$Object, [string]$Name, [string]$Context) {
  if (-not (Test-HasProperty $Object $Name)) {
    throw "$Context must define $Name."
  }
  if ($Object.$Name -isnot [bool]) {
    throw "$Context $Name must be a JSON boolean."
  }
  Assert-Equal $false ([bool]$Object.$Name) "$Context $Name must remain false."
}

function Assert-RequiredBooleanTrue([object]$Object, [string]$Name, [string]$Context) {
  if (-not (Test-HasProperty $Object $Name)) {
    throw "$Context must define $Name."
  }
  if ($Object.$Name -isnot [bool]) {
    throw "$Context $Name must be a JSON boolean."
  }
  Assert-Equal $true ([bool]$Object.$Name) "$Context $Name must be true."
}

function Assert-RequiredInt64([object]$Object, [string]$Name, [int64]$Expected, [string]$Context) {
  if (-not (Test-HasProperty $Object $Name)) {
    throw "$Context must define $Name."
  }
  if ($Object.$Name -isnot [int64]) {
    throw "$Context $Name must be a JSON integer."
  }
  Assert-Equal $Expected ([int64]$Object.$Name) "$Context $Name must match."
}

function Get-RequiredUtcTimestamp([object]$Object, [string]$Name, [string]$Context) {
  $value = Get-RequiredProperty $Object $Name $Context
  if ($value -isnot [datetime] -or ([datetime]$value).Kind -eq [System.DateTimeKind]::Unspecified) {
    throw "$Context $Name must be an ISO-8601 timestamp with an explicit timezone."
  }
  ([datetime]$value).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ", [System.Globalization.CultureInfo]::InvariantCulture)
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
    'gh[pousr]_[A-Za-z0-9_]{20,}',
    'github_pat_[A-Za-z0-9_]+',
    '://[^/\s:@"]+:[^/\s:@"]+@',
    '(?i)Authorization:\s*Bearer\s+',
    '(?i)"tokenValue"\s*:',
    '(?i)"credential"\s*:',
    '(?i)"authorizationHeader"\s*:',
    '(?i)Hitsuki-Ban[/:]SubversionR-private(?:\.git)?',
    'repo_id',
    'repo_connection_uuid',
    'build_token_uuid',
    'trigger_uuid',
    '(?i)"(?:account_?id|zone_?id|worker_?id|script_?id|deploy_hook_uuid)"\s*:',
    'marketplace\.visualstudio\.com/items\?itemName=hitsuki-ban\.subversionr'
  )

  foreach ($pattern in $patterns) {
    if ($Text -match $pattern) {
      throw "Publication gaps evidence must not record credentials, private repository URLs, or public Marketplace publication URLs."
    }
  }
}

function Assert-NoForbiddenPublisherAuthorizationText([string]$Text) {
  $patterns = @(
    '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
    '(?i)"(?:tenantId|clientId|identityId|objectId|servicePrincipalId|principalId|credential|token|secret)"\s*:',
    '(?i)Authorization:\s*Bearer\s+'
  )

  foreach ($pattern in $patterns) {
    if ($Text -match $pattern) {
      throw "Marketplace publisher authorization evidence must not record identity or credential values."
    }
  }
}

$releaseEvidenceRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence"))
$scriptTestRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-publication-gaps-scripts"))
$evidenceResolved = Assert-GeneratedPath -Path $EvidencePath -Name "EvidencePath" -AllowedRoots @(
  $releaseEvidenceRoot,
  $scriptTestRoot
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
Assert-RequiredBooleanTrue $report.publicRepositoryMetadata "repositoryResolvesToPublic" "Public repository metadata"
Assert-Equal "not-verified-by-public-cutover-evidence" ([string]$report.publicRepositoryMetadata.homepageResolvesToPublic) "Public homepage resolution must remain unverified."
Assert-Equal "not-verified-by-public-cutover-evidence" ([string]$report.publicRepositoryMetadata.bugsResolvesToPublic) "Public issue tracker resolution must remain unverified."
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR.git" ([string]$report.publicRepositoryMetadata.repositoryUrl) "Public repository URL must match the extension manifest."
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR#readme" ([string]$report.publicRepositoryMetadata.homepageUrl) "Public homepage URL must match the extension manifest."
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/issues" ([string]$report.publicRepositoryMetadata.bugsUrl) "Public issue tracker URL must match the extension manifest."

Assert-OnlyProperties $report.marketplacePublisherAuthorization @("status", "publisher", "expectedExtensionId", "authorizationRole", "verificationMode", "ownerOrContributorVerified", "credentialRecorded", "identityValueRecorded", "claimAllowed", "verifiedBy", "blockers") "Marketplace publisher authorization"
Assert-Equal "verified" ([string]$report.marketplacePublisherAuthorization.status) "Marketplace publisher authorization must be verified."
Assert-Equal "hitsuki-ban" ([string]$report.marketplacePublisherAuthorization.publisher) "Marketplace publisher authorization must bind publisher hitsuki-ban."
Assert-Equal "hitsuki-ban.subversionr" ([string]$report.marketplacePublisherAuthorization.expectedExtensionId) "Marketplace publisher authorization must bind extension id."
Assert-Equal "Contributor" ([string]$report.marketplacePublisherAuthorization.authorizationRole) "Marketplace publisher authorization must bind the Contributor role."
Assert-Equal "owner-attestation" ([string]$report.marketplacePublisherAuthorization.verificationMode) "Marketplace publisher authorization must bind owner attestation."
Assert-RequiredBooleanTrue $report.marketplacePublisherAuthorization "ownerOrContributorVerified" "Marketplace publisher authorization"
Assert-RequiredBooleanFalse $report.marketplacePublisherAuthorization "credentialRecorded" "Marketplace publisher authorization"
Assert-RequiredBooleanFalse $report.marketplacePublisherAuthorization "identityValueRecorded" "Marketplace publisher authorization"
Assert-RequiredBooleanTrue $report.marketplacePublisherAuthorization "claimAllowed" "Marketplace publisher authorization"
Assert-Equal "marketplace-publisher-authorization-evidence" ([string]$report.marketplacePublisherAuthorization.verifiedBy) "Marketplace publisher authorization must bind its source evidence."
Assert-Equal 0 @($report.marketplacePublisherAuthorization.blockers).Count "Marketplace publisher authorization must not retain blockers."
Assert-NoProperty $report.marketplacePublisherAuthorization "token" "Marketplace publisher authorization"
Assert-NoProperty $report.marketplacePublisherAuthorization "pat" "Marketplace publisher authorization"
Assert-NoProperty $report.marketplacePublisherAuthorization "authorizationHeader" "Marketplace publisher authorization"

Assert-Equal "entra-federated-workflow-configured" ([string]$report.publishAuth.status) "Publish auth must record the source-controlled Entra workflow."
Assert-Equal "microsoft-entra-id-workload-identity" ([string]$report.publishAuth.primaryMode) "Publish auth primary mode should track the official Entra ID workload identity path."
Assert-Equal "@vscode/vsce" ([string]$report.publishAuth.requiredTool) "Publish auth must name @vscode/vsce."
Assert-Equal "2.26.1" ([string]$report.publishAuth.minimumVsceForAzureCredential) "Publish auth must record the documented minimum vsce version for --azure-credential."
Assert-Equal ".github/workflows/publish-marketplace.yml" ([string]$report.publishAuth.workflowPath) "Publish auth must bind the source-controlled Marketplace workflow."
Assert-Equal "marketplace" ([string]$report.publishAuth.githubEnvironment) "Publish auth must bind the protected marketplace environment."
Assert-Equal 2 @($report.publishAuth.requiredRepositoryVariables).Count "Publish auth must require exactly two repository variables."
Assert-ArrayContainsExactlyOnce -Values @($report.publishAuth.requiredRepositoryVariables) -Expected "AZURE_CLIENT_ID" -Context "Publish auth repository variables"
Assert-ArrayContainsExactlyOnce -Values @($report.publishAuth.requiredRepositoryVariables) -Expected "AZURE_TENANT_ID" -Context "Publish auth repository variables"
Assert-Equal 2 @($report.publishAuth.requiredPermissions).Count "Publish auth must require exactly two workflow permissions."
Assert-ArrayContainsExactlyOnce -Values @($report.publishAuth.requiredPermissions) -Expected "contents: read" -Context "Publish auth permissions"
Assert-ArrayContainsExactlyOnce -Values @($report.publishAuth.requiredPermissions) -Expected "id-token: write" -Context "Publish auth permissions"
Assert-Equal "vsce publish --packagePath <attested-vsix> --pre-release --azure-credential" ([string]$report.publishAuth.azureCredentialCommandShape) "Publish auth must bind the exact Entra publish command shape."
Assert-RequiredBooleanTrue $report.publishAuth "allowNoSubscriptions" "Publish auth"
Assert-RequiredBooleanFalse $report.publishAuth "environmentRead" "Publish auth"
Assert-RequiredBooleanTrue $report.publishAuth "azureCredentialConfigured" "Publish auth"
Assert-RequiredBooleanFalse $report.publishAuth "secretValueRecorded" "Publish auth"
Assert-RequiredBooleanTrue $report.publishAuth "claimAllowed" "Publish auth"
Assert-Equal "marketplace-identity-bootstrap-evidence" ([string]$report.publishAuth.verifiedBy) "Publish auth must bind the successful identity bootstrap evidence."
Assert-Equal "entra-federated-login-verified" ([string]$report.publishAuth.bootstrap.status) "Publish auth bootstrap must record successful federation."
Assert-Equal ".github/workflows/bootstrap-marketplace-identity.yml" ([string]$report.publishAuth.bootstrap.workflowPath) "Publish auth bootstrap workflow path must match."
Assert-True ([string]$report.publishAuth.bootstrap.runId -match '^[1-9][0-9]*$') "Publish auth bootstrap runId must be numeric."
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/$($report.publishAuth.bootstrap.runId)" ([string]$report.publishAuth.bootstrap.runUrl) "Publish auth bootstrap run URL must match."
Assert-True ([string]$report.publishAuth.bootstrap.headSha -match '^[a-f0-9]{40}$') "Publish auth bootstrap headSha must be a full lowercase commit SHA."
Assert-Equal "refs/heads/main" ([string]$report.publishAuth.bootstrap.sourceRef) "Publish auth bootstrap sourceRef must be public main."
Assert-Equal "repo:Hitsuki-Ban/SubversionR:environment:marketplace" ([string]$report.publishAuth.bootstrap.oidcSubject) "Publish auth bootstrap OIDC subject must match."
Assert-Equal 0 @($report.publishAuth.blockers).Count "Publish auth must have no source-configuration blocker."
Assert-NoProperty $report.publishAuth "legacyPatSecretName" "Publish auth"
Assert-NoProperty $report.publishAuth "legacyPatRetirementDate" "Publish auth"
Assert-NoProperty $report.publishAuth "legacyPatConfigured" "Publish auth"
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

Assert-Equal "current-candidate-not-published" ([string]$report.marketplace.status) "Marketplace status must remain not-published for the current candidate."
Assert-Equal "extension-version" ([string]$report.marketplace.scope) "Marketplace status must be scoped to the extension version."
Assert-Equal ([string]$report.extension.version) ([string]$report.marketplace.candidateVersion) "Marketplace candidate version must match the extension version."
Assert-Equal "pre-existing-manual-publication" ([string]$report.marketplace.existingListing.status) "Marketplace existing listing must remain distinguished from the Entra pipeline."
Assert-Equal "0.1.0" ([string]$report.marketplace.existingListing.version) "Marketplace existing listing must bind the observed version."
Assert-Equal "win32-x64" ([string]$report.marketplace.existingListing.targetPlatform) "Marketplace existing listing must bind win32-x64."
Assert-RequiredBooleanFalse $report.marketplace "publicationEvidenceRecorded" "Marketplace"
Assert-RequiredBooleanFalse $report.marketplace "claimAllowed" "Marketplace"

$expectedBlockers = @(
    "The current 0.2.2 candidate release and live GitHub attestation have not been published.",
    "Marketplace publication is not run by this local gap report.",
    "Marketplace public install evidence is not generated by this local gap report.",
    "VSIX signing remains absent in the upstream provenance preflight.",
    "Public repository homepage and social metadata are not fully verified.",
    "Previous stable artifact rollback evidence is not generated by this local gap report."
)
Assert-Equal $expectedBlockers.Count @($report.blockers).Count "Publication gaps blocker count must match the current unresolved set."
foreach ($blocker in $expectedBlockers) {
  Assert-ArrayContainsExactlyOnce -Values @($report.blockers) -Expected $blocker -Context "Publication gaps blockers"
}

$expectedNonClaims = @(
    "This gate is a local publication gaps report, not a publication readiness certificate.",
    "This gate records public repository metadata and cutover state from hash-bound evidence without recording a private remote, credentialed URL, or Marketplace publication URL.",
    "This gate records owner-attested Marketplace Contributor authorization without recording identity or credential values.",
    "This gate records the source-controlled Microsoft Entra ID workflow, hash-bound successful bootstrap run, and separate owner-attested publisher authorization without recording owner-managed variable or identity values.",
    "This gate records an exact pre-release-eligible 0.2.2 candidate contract, but does not claim its release or live attestation exists.",
    "This gate does not publish to Visual Studio Marketplace.",
    "This gate does not install from Visual Studio Marketplace or prove public acquisition.",
    "This gate records owner-managed branch protection and private workflow disablement from hash-bound evidence; it does not perform repository-owner API mutations.",
    "This gate preserves the historical 0.2.0 GitHub artifact attestation without applying it to the current 0.2.2 candidate or proving VSIX signing, previous-stable rollback, final SBOM/NOTICE review, or CVE review."
)
Assert-Equal $expectedNonClaims.Count @($report.nonClaims).Count "Publication gaps non-claim count must match the current contract."
foreach ($nonClaim in $expectedNonClaims) {
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
$currentCandidate = Get-RequiredProperty $report "currentCandidate" "Publication gaps"
Assert-Equal "pending-release-attestation" ([string]$currentCandidate.status) "Current candidate status must remain pending before release."
Assert-Equal "current-candidate" ([string]$currentCandidate.scope) "Current candidate scope must match."
Assert-Equal "v0.2.2-beta.1" ([string]$currentCandidate.releaseTag) "Current candidate release tag must match."
Assert-Equal "subversionr-win32-x64-0.2.2.vsix" ([string]$currentCandidate.subjectName) "Current candidate subject name must match."
Assert-Equal ([string]$report.artifacts.vsix.sha256) ([string]$currentCandidate.subjectSha256) "Current candidate SHA256 must match current VSIX bytes."
Assert-Equal ([int64]$report.artifacts.vsix.size) ([int64]$currentCandidate.subjectSize) "Current candidate size must match current VSIX bytes."
Assert-RequiredBooleanTrue $currentCandidate "preReleaseProperty" "Current candidate"
Assert-RequiredBooleanFalse $currentCandidate "liveEvidenceRecorded" "Current candidate"

Assert-HashRecord $report.evidence.extensionPackage "Extension package"
Assert-HashRecord $report.evidence.rootPackage "Root package"
Assert-HashRecord $report.evidence.readme "README"
Assert-HashRecord $report.evidence.license "LICENSE"
Assert-HashRecord $report.evidence.changelog "CHANGELOG"
Assert-HashRecord $report.evidence.support "SUPPORT"
Assert-HashRecord $report.evidence.publicCutoverRunbook "Public cutover runbook"
Assert-HashRecord $report.evidence.publicCutoverEvidence "Public cutover evidence"
Assert-HashRecord $report.evidence.provenancePreflight "Provenance preflight"
Assert-HashRecord $report.evidence.vsixPackage "VSIX package evidence"
Assert-HashRecord $report.evidence.marketplacePublishWorkflow "Marketplace publish workflow"
Assert-HashRecord $report.evidence.marketplaceIdentityBootstrap "Marketplace identity bootstrap evidence"
Assert-Equal "subversionr.release.marketplace-identity-bootstrap.v1" (Assert-RequiredString $report.evidence.marketplaceIdentityBootstrap "schema" "Marketplace identity bootstrap evidence") "Marketplace identity bootstrap schema must be bound."
Assert-HashRecord $report.evidence.marketplacePublisherAuthorization "Marketplace publisher authorization evidence"
Assert-Equal "subversionr.release.marketplace-publisher-authorization.v1" (Assert-RequiredString $report.evidence.marketplacePublisherAuthorization "schema" "Marketplace publisher authorization evidence") "Marketplace publisher authorization schema must be bound."
$marketplacePublisherAuthorizationEvidencePath = [string]$report.evidence.marketplacePublisherAuthorization.path
$marketplacePublisherAuthorizationEvidenceResolved = Assert-File $marketplacePublisherAuthorizationEvidencePath "Marketplace publisher authorization evidence"
$expectedMarketplacePublisherAuthorizationEvidencePath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "docs\release\marketplace-publisher-authorization-evidence.json"))
Assert-Equal $expectedMarketplacePublisherAuthorizationEvidencePath $marketplacePublisherAuthorizationEvidenceResolved "Marketplace publisher authorization evidence must bind the source-controlled contract."
$marketplacePublisherAuthorizationEvidenceRaw = Get-Content -Raw -LiteralPath $marketplacePublisherAuthorizationEvidenceResolved
Assert-NoForbiddenPublisherAuthorizationText $marketplacePublisherAuthorizationEvidenceRaw
$marketplacePublisherAuthorizationEvidence = $marketplacePublisherAuthorizationEvidenceRaw | ConvertFrom-Json
Assert-OnlyProperties $marketplacePublisherAuthorizationEvidence @("schemaVersion", "schema", "publicReadinessClaim", "status", "publisher", "expectedExtensionId", "authorization", "bootstrap", "dataHandling", "marketplacePublication", "nonClaims") "Marketplace publisher authorization source evidence"
Assert-Equal 1 ([int]$marketplacePublisherAuthorizationEvidence.schemaVersion) "Marketplace publisher authorization source schemaVersion must be 1."
Assert-Equal "subversionr.release.marketplace-publisher-authorization.v1" ([string]$marketplacePublisherAuthorizationEvidence.schema) "Marketplace publisher authorization source schema must match."
Assert-RequiredBooleanFalse $marketplacePublisherAuthorizationEvidence "publicReadinessClaim" "Marketplace publisher authorization source evidence"
Assert-Equal "verified" (Assert-RequiredJsonString $marketplacePublisherAuthorizationEvidence "status" "Marketplace publisher authorization source evidence") "Marketplace publisher authorization source status must be verified."
Assert-Equal "hitsuki-ban" (Assert-RequiredJsonString $marketplacePublisherAuthorizationEvidence "publisher" "Marketplace publisher authorization source evidence") "Marketplace publisher authorization source publisher must match."
Assert-Equal "hitsuki-ban.subversionr" (Assert-RequiredJsonString $marketplacePublisherAuthorizationEvidence "expectedExtensionId" "Marketplace publisher authorization source evidence") "Marketplace publisher authorization source extension id must match."
$publisherAuthorizationSource = Get-RequiredProperty $marketplacePublisherAuthorizationEvidence "authorization" "Marketplace publisher authorization source evidence"
Assert-OnlyProperties $publisherAuthorizationSource @("role", "verificationMode", "ownerOrContributorVerified", "verifiedAt", "issueUrl", "commentUrl") "Marketplace publisher authorization source"
Assert-Equal "Contributor" (Assert-RequiredJsonString $publisherAuthorizationSource "role" "Marketplace publisher authorization source") "Marketplace publisher authorization source role must be Contributor."
Assert-Equal "owner-attestation" (Assert-RequiredJsonString $publisherAuthorizationSource "verificationMode" "Marketplace publisher authorization source") "Marketplace publisher authorization source verification mode must match."
Assert-RequiredBooleanTrue $publisherAuthorizationSource "ownerOrContributorVerified" "Marketplace publisher authorization source"
Assert-Equal "2026-07-10T18:05:38.000Z" (Get-RequiredUtcTimestamp $publisherAuthorizationSource "verifiedAt" "Marketplace publisher authorization source") "Marketplace publisher authorization source timestamp must bind the owner attestation."
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/issues/14" (Assert-RequiredJsonString $publisherAuthorizationSource "issueUrl" "Marketplace publisher authorization source") "Marketplace publisher authorization source issue URL must match."
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/issues/14#issuecomment-4938167334" (Assert-RequiredJsonString $publisherAuthorizationSource "commentUrl" "Marketplace publisher authorization source") "Marketplace publisher authorization source comment URL must match."
$publisherAuthorizationBootstrapSource = Get-RequiredProperty $marketplacePublisherAuthorizationEvidence "bootstrap" "Marketplace publisher authorization source evidence"
Assert-OnlyProperties $publisherAuthorizationBootstrapSource @("runId", "runUrl") "Marketplace publisher authorization source bootstrap"
Assert-Equal "29107576798" (Assert-RequiredJsonString $publisherAuthorizationBootstrapSource "runId" "Marketplace publisher authorization source bootstrap") "Marketplace publisher authorization source bootstrap run id must match."
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/29107576798" (Assert-RequiredJsonString $publisherAuthorizationBootstrapSource "runUrl" "Marketplace publisher authorization source bootstrap") "Marketplace publisher authorization source bootstrap run URL must match."
$publisherAuthorizationDataHandlingSource = Get-RequiredProperty $marketplacePublisherAuthorizationEvidence "dataHandling" "Marketplace publisher authorization source evidence"
Assert-OnlyProperties $publisherAuthorizationDataHandlingSource @("credentialValuesRecorded", "identityValuesRecorded") "Marketplace publisher authorization source data handling"
Assert-RequiredBooleanFalse $publisherAuthorizationDataHandlingSource "credentialValuesRecorded" "Marketplace publisher authorization source data handling"
Assert-RequiredBooleanFalse $publisherAuthorizationDataHandlingSource "identityValuesRecorded" "Marketplace publisher authorization source data handling"
$publisherAuthorizationPublicationSource = Get-RequiredProperty $marketplacePublisherAuthorizationEvidence "marketplacePublication" "Marketplace publisher authorization source evidence"
Assert-OnlyProperties $publisherAuthorizationPublicationSource @("status", "publicationEvidenceRecorded") "Marketplace publisher authorization source publication"
Assert-Equal "not-run-by-entra-pipeline" (Assert-RequiredJsonString $publisherAuthorizationPublicationSource "status" "Marketplace publisher authorization source publication") "Marketplace publisher authorization source must not claim publication."
Assert-RequiredBooleanFalse $publisherAuthorizationPublicationSource "publicationEvidenceRecorded" "Marketplace publisher authorization source publication"
$expectedPublisherAuthorizationSourceNonClaims = @(
  "This evidence records only the repository owner's attestation that the resolved Entra identity has Marketplace Contributor authorization.",
  "This evidence does not record Azure tenant, application, Marketplace identity, or credential values.",
  "This evidence does not claim Marketplace publication, public install, artifact signing, previous-stable rollback, or public release readiness."
)
if ($marketplacePublisherAuthorizationEvidence.nonClaims -isnot [System.Array]) {
  throw "Marketplace publisher authorization source nonClaims must be a JSON array."
}
Assert-Equal $expectedPublisherAuthorizationSourceNonClaims.Count @($marketplacePublisherAuthorizationEvidence.nonClaims).Count "Marketplace publisher authorization source non-claim count must match."
foreach ($expectedNonClaim in $expectedPublisherAuthorizationSourceNonClaims) {
  Assert-ArrayContainsExactlyOnce -Values @($marketplacePublisherAuthorizationEvidence.nonClaims) -Expected $expectedNonClaim -Context "Marketplace publisher authorization source nonClaims"
}
Assert-HashRecord $report.evidence.marketplaceExistingListing "Marketplace existing-listing evidence"
Assert-Equal "subversionr.release.marketplace-existing-listing.v1" (Assert-RequiredString $report.evidence.marketplaceExistingListing "schema" "Marketplace existing-listing evidence") "Marketplace existing-listing schema must be bound."
Assert-Equal "subversionr.release.marketplace-provenance-preflight.win32-x64.v1" (Assert-RequiredString $report.evidence.provenancePreflight "schema" "Provenance preflight evidence") "Provenance preflight schema must be bound."
Assert-Equal "subversionr.release.vsix-package.win32-x64.v1" (Assert-RequiredString $report.evidence.vsixPackage "schema" "VSIX package evidence") "VSIX package evidence schema must be bound."
$provenance = Get-Content -Raw -LiteralPath (Assert-File ([string]$report.evidence.provenancePreflight.path) "Provenance preflight") | ConvertFrom-Json
Assert-Equal "verified" ([string]$provenance.attestation.status) "Provenance preflight must record live attestation verification."
Assert-Equal "historical-public-cutover-release" ([string]$provenance.attestation.scope) "Provenance verified attestation must remain historical."
$provenanceCandidate = Get-RequiredProperty $provenance "candidateAttestation" "Provenance"
Assert-Equal "pending-release-attestation" ([string]$provenanceCandidate.status) "Provenance current candidate attestation must remain pending."
Assert-Equal "current-candidate" ([string]$provenanceCandidate.scope) "Provenance current candidate scope must match."
Assert-RequiredBooleanTrue $provenanceCandidate "preReleaseProperty" "Provenance current candidate"
Assert-RequiredBooleanFalse $provenanceCandidate "liveEvidenceRecorded" "Provenance current candidate"
foreach ($field in @("status", "scope", "releaseTag", "releaseUrl", "subjectName", "subjectSha256", "subjectSize", "preReleaseProperty", "liveEvidenceRecorded", "contractPath", "contractSha256")) {
  Assert-Equal ([string]$provenanceCandidate.$field) ([string]$currentCandidate.$field) "Publication gaps current candidate $field must match provenance."
}
$provenanceAttestation = Get-RequiredProperty $provenance.attestation "readiness" "Provenance attestation"
Assert-Equal "live-attestation-verified" ([string]$provenanceAttestation.readinessStatus) "Provenance attestation readiness must record live verification."
Assert-RequiredBooleanTrue $provenanceAttestation "verified" "Provenance attestation readiness"
Assert-Equal "actions/attest@v4" ([string]$provenanceAttestation.action) "Provenance attestation action must match the post-release verification contract."
Assert-Equal "a1948c3f048ba23858d222213b7c278aabede763" ([string]$provenanceAttestation.actionDigest) "Provenance attestation action digest must remain pinned."
Assert-Equal "post-release-asset-digest-verification" ([string]$provenanceAttestation.predicateClaim) "Provenance attestation signed predicate claim must match."
Assert-RequiredBooleanFalse $provenanceAttestation "originalBuildProvenanceClaim" "Provenance attestation signed predicate"
Assert-RequiredBooleanFalse $provenanceAttestation "artifactSignatureClaim" "Provenance attestation signed predicate"

Assert-Equal "recorded-post-cutover" ([string]$report.publicCutover.status) "Public cutover must record the post-cutover state."
Assert-Equal "docs/release/public-cutover-runbook.md" ([string]$report.publicCutover.runbookPath) "Public cutover must bind the runbook path."
$publicCutoverEvidencePath = [string]$report.publicCutover.evidencePath
Assert-Equal ([string]$report.evidence.publicCutoverEvidence.path) $publicCutoverEvidencePath "Public cutover evidence path must match its hash record."
$publicCutoverEvidenceAbsolute = Get-RepoAbsolutePath $publicCutoverEvidencePath
if (Test-IsPathWithin -Path $evidenceResolved -Root $releaseEvidenceRoot) {
  $expectedPublicCutoverEvidenceAbsolute = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "docs\release\public-cutover-evidence.json"))
  Assert-Equal $expectedPublicCutoverEvidenceAbsolute $publicCutoverEvidenceAbsolute "Production publication gaps evidence must bind the source-controlled public cutover contract."
}
else {
  $relativeScriptTestPath = [System.IO.Path]::GetRelativePath($scriptTestRoot, $evidenceResolved)
  $fixtureId = $relativeScriptTestPath.Split([System.IO.Path]::DirectorySeparatorChar, [System.StringSplitOptions]::RemoveEmptyEntries)[0]
  Assert-True ($fixtureId -match '^[a-f0-9]{32}$') "Script-test publication gaps evidence must be inside a GUID-named isolated fixture directory."
  $fixtureRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptTestRoot $fixtureId))
  $expectedPublicCutoverEvidenceAbsolute = [System.IO.Path]::GetFullPath((Join-Path $fixtureRoot "public-cutover-evidence.json"))
  Assert-Equal $expectedPublicCutoverEvidenceAbsolute $publicCutoverEvidenceAbsolute "Script-test publication gaps evidence must bind its own isolated public cutover fixture."
}
$publicCutoverEvidenceResolved = Assert-File $publicCutoverEvidencePath "Public cutover evidence"
$publicCutoverEvidenceRaw = Get-Content -Raw -LiteralPath $publicCutoverEvidenceResolved
Assert-NoForbiddenEvidenceText $publicCutoverEvidenceRaw
$publicCutoverEvidence = $publicCutoverEvidenceRaw | ConvertFrom-Json
Assert-Equal 1 ([int]$publicCutoverEvidence.schemaVersion) "Public cutover source schemaVersion should be 1."
Assert-Equal "subversionr.release.public-cutover-evidence.v1" ([string]$publicCutoverEvidence.schema) "Public cutover source schema must match."
Assert-Equal ([string]$publicCutoverEvidence.status) ([string]$report.publicCutover.status) "Public cutover status must match public cutover evidence."
Assert-OnlyProperties $publicCutoverEvidence @("schemaVersion", "schema", "status", "repository", "ci", "cloudflareBridgeRetirement", "release", "betaCandidateEvidence") "Public cutover evidence"

$cutoverRepository = Get-RequiredProperty $publicCutoverEvidence "repository" "Public cutover evidence"
Assert-OnlyProperties $cutoverRepository @("url", "defaultBranch", "baselineCommit", "cutoverHeadCommit", "resolvesToPublic", "branchProtectionRequiredCheck", "branchProtectionConfigured", "branchProtection", "privateVulnerabilityReportingEnabled", "metadataVerified") "Public cutover source repository"
Assert-RequiredBooleanTrue $cutoverRepository "resolvesToPublic" "Public cutover source repository"
Assert-RequiredBooleanTrue $cutoverRepository "branchProtectionConfigured" "Public cutover source repository"
Assert-RequiredBooleanTrue $cutoverRepository "privateVulnerabilityReportingEnabled" "Public cutover source repository"
Assert-RequiredBooleanFalse $cutoverRepository "metadataVerified" "Public cutover source repository"
$sourceBranchProtection = Get-RequiredProperty $cutoverRepository "branchProtection" "Public cutover source repository"
Assert-OnlyProperties $sourceBranchProtection @("status", "provider", "rulesetId", "rulesetName", "target", "enforcement", "refIncludes", "refExcludes", "requiredStatusCheck", "pullRequestRequired", "requiredApprovingReviewCount", "nonFastForwardBlocked", "bypassActorCount", "updatedAt") "Public branch protection"
Assert-Equal "active" (Assert-RequiredJsonString $sourceBranchProtection "status" "Public branch protection") "Public branch protection status must be active."
Assert-Equal "github-repository-ruleset" (Assert-RequiredJsonString $sourceBranchProtection "provider" "Public branch protection") "Public branch protection provider must match."
Assert-RequiredInt64 $sourceBranchProtection "rulesetId" 18761017 "Public branch protection"
Assert-Equal "protect-main" (Assert-RequiredJsonString $sourceBranchProtection "rulesetName" "Public branch protection") "Public branch protection ruleset name must match."
Assert-Equal "branch" (Assert-RequiredJsonString $sourceBranchProtection "target" "Public branch protection") "Public branch protection target must match."
Assert-Equal "active" (Assert-RequiredJsonString $sourceBranchProtection "enforcement" "Public branch protection") "Public branch protection enforcement must be active."
if (-not (Test-HasProperty $sourceBranchProtection "refIncludes")) {
  throw "Public branch protection must define refIncludes."
}
$sourceRefIncludesValue = $sourceBranchProtection.refIncludes
if ($sourceRefIncludesValue -isnot [System.Array]) {
  throw "Public branch protection refIncludes must be a JSON array."
}
$sourceRefIncludes = @($sourceRefIncludesValue)
Assert-Equal 1 $sourceRefIncludes.Count "Public branch protection must target exactly one ref selector."
Assert-True ($sourceRefIncludes[0] -is [string]) "Public branch protection refIncludes entries must be JSON strings."
Assert-Equal "~DEFAULT_BRANCH" $sourceRefIncludes[0] "Public branch protection must target the default branch."
if (-not (Test-HasProperty $sourceBranchProtection "refExcludes")) {
  throw "Public branch protection must define refExcludes."
}
if ($sourceBranchProtection.refExcludes -isnot [System.Array]) {
  throw "Public branch protection refExcludes must be a JSON array."
}
$sourceRefExcludes = @($sourceBranchProtection.refExcludes)
Assert-Equal 0 $sourceRefExcludes.Count "Public branch protection must not exclude any refs."
$sourceRequiredStatusCheck = Get-RequiredProperty $sourceBranchProtection "requiredStatusCheck" "Public branch protection"
Assert-OnlyProperties $sourceRequiredStatusCheck @("displayName", "context", "integrationId", "strict") "Public branch protection required status check"
Assert-Equal "PR Fast / windows" (Assert-RequiredJsonString $sourceRequiredStatusCheck "displayName" "Public branch protection required status check") "Public branch protection display check must match."
Assert-Equal "windows" (Assert-RequiredJsonString $sourceRequiredStatusCheck "context" "Public branch protection required status check") "Public branch protection context must match."
Assert-RequiredInt64 $sourceRequiredStatusCheck "integrationId" 15368 "Public branch protection required status check"
Assert-RequiredBooleanFalse $sourceRequiredStatusCheck "strict" "Public branch protection required status check"
Assert-RequiredBooleanTrue $sourceBranchProtection "pullRequestRequired" "Public branch protection"
Assert-RequiredInt64 $sourceBranchProtection "requiredApprovingReviewCount" 0 "Public branch protection"
Assert-RequiredBooleanTrue $sourceBranchProtection "nonFastForwardBlocked" "Public branch protection"
Assert-RequiredInt64 $sourceBranchProtection "bypassActorCount" 0 "Public branch protection"
$sourceBranchProtectionUpdatedAt = Get-RequiredUtcTimestamp $sourceBranchProtection "updatedAt" "Public branch protection"
Assert-Equal ([bool]$cutoverRepository.resolvesToPublic) ([bool]$report.publicRepositoryMetadata.repositoryResolvesToPublic) "Public repository resolution must match public cutover evidence."
Assert-Equal 244 ([int]$report.publicCutover.cutoverIssue) "Public cutover must bind private cutover issue #244."
Assert-Equal 4 ([int]$report.publicCutover.publicationGapsIssue) "Public cutover must bind public publication-gaps issue #4."
Assert-Equal "published" ([string]$report.publicCutover.baseline.status) "Public cutover baseline must be recorded as published."
Assert-Equal "fresh-squash-baseline" ([string]$report.publicCutover.baseline.historyPolicy) "Public cutover baseline must use the fresh baseline policy."
Assert-RequiredBooleanFalse $report.publicCutover.baseline "privateHistoryAllowed" "Public cutover baseline"
Assert-RequiredBooleanFalse $report.publicCutover.baseline "referenceDirectoryAllowed" "Public cutover baseline"
Assert-RequiredBooleanTrue $report.publicCutover.baseline "secretsScanRequired" "Public cutover baseline"
Assert-RequiredBooleanTrue $report.publicCutover.baseline "gitignoreVerificationRequired" "Public cutover baseline"
Assert-RequiredBooleanTrue $report.publicCutover.baseline "publicPushRecorded" "Public cutover baseline"
$baselineCommit = Assert-RequiredString $report.publicCutover.baseline "commit" "Public cutover baseline"
Assert-True ($baselineCommit -match '^[a-f0-9]{40}$') "Public cutover baseline commit must be a full lowercase commit SHA."
Assert-Equal ([string]$cutoverRepository.baselineCommit) $baselineCommit "Public baseline commit must match public cutover evidence."
Assert-Equal "public" ([string]$report.publicCutover.publicRepository.status) "Public repository must be recorded as public."
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR" ([string]$report.publicCutover.publicRepository.url) "Public repository URL must be recorded."
Assert-RequiredBooleanTrue $report.publicCutover.publicRepository "resolvesToPublic" "Public repository"
Assert-Equal "main" ([string]$report.publicCutover.publicRepository.defaultBranch) "Public repository default branch must be main."
$cutoverHeadCommit = Assert-RequiredString $report.publicCutover.publicRepository "cutoverHeadCommit" "Public repository"
Assert-True ($cutoverHeadCommit -match '^[a-f0-9]{40}$') "Public repository cutover head commit must be a full lowercase commit SHA."
Assert-True ($cutoverHeadCommit -ne $baselineCommit) "Public repository cutover head commit must differ from the fresh baseline commit."
Assert-Equal ([string]$cutoverRepository.url) ([string]$report.publicCutover.publicRepository.url) "Public repository URL must match public cutover evidence."
Assert-Equal ([bool]$cutoverRepository.resolvesToPublic) ([bool]$report.publicCutover.publicRepository.resolvesToPublic) "Public repository resolution must match public cutover evidence."
Assert-Equal ([string]$cutoverRepository.defaultBranch) ([string]$report.publicCutover.publicRepository.defaultBranch) "Public repository default branch must match public cutover evidence."
Assert-Equal ([string]$cutoverRepository.cutoverHeadCommit) $cutoverHeadCommit "Public cutover head commit must match public cutover evidence."
$sourceBranchProtectionRequiredCheck = Assert-RequiredJsonString $cutoverRepository "branchProtectionRequiredCheck" "Public cutover source repository"
$reportBranchProtectionRequiredCheck = Assert-RequiredJsonString $report.publicCutover.publicRepository "branchProtectionRequiredCheck" "Public repository"
Assert-Equal $sourceBranchProtectionRequiredCheck $reportBranchProtectionRequiredCheck "Public branch-protection check must match public cutover evidence."
Assert-Equal ([bool]$cutoverRepository.branchProtectionConfigured) ([bool]$report.publicCutover.publicRepository.branchProtectionConfigured) "Public branch-protection state must match public cutover evidence."
Assert-Equal ([bool]$cutoverRepository.privateVulnerabilityReportingEnabled) ([bool]$report.publicCutover.publicRepository.privateVulnerabilityReportingEnabled) "PVR state must match public cutover evidence."
Assert-Equal ([bool]$cutoverRepository.metadataVerified) ([bool]$report.publicCutover.publicRepository.metadataVerified) "Public repository metadata state must match public cutover evidence."
Assert-Equal "PR Fast / windows" $reportBranchProtectionRequiredCheck "Public branch protection required check must be recorded."
Assert-RequiredBooleanTrue $report.publicCutover.publicRepository "branchProtectionConfigured" "Public repository"
Assert-RequiredBooleanTrue $report.publicCutover.publicRepository "privateVulnerabilityReportingEnabled" "Public repository"
Assert-RequiredBooleanFalse $report.publicCutover.publicRepository "metadataVerified" "Public repository"
if ($report.publicCutover.publicRepository.blockers -isnot [System.Array]) {
  throw "Public repository blockers must be a JSON array."
}
$publicRepositoryBlockers = @($report.publicCutover.publicRepository.blockers)
Assert-Equal 1 $publicRepositoryBlockers.Count "Public repository must retain only the metadata blocker."
Assert-True ($publicRepositoryBlockers[0] -is [string]) "Public repository blocker entries must be JSON strings."
Assert-Equal "Verify and complete public repository homepage and social metadata." $publicRepositoryBlockers[0] "Public repository blocker must match."
$reportBranchProtection = Get-RequiredProperty $report.publicCutover.publicRepository "branchProtection" "Public repository"
Assert-OnlyProperties $reportBranchProtection @("status", "provider", "rulesetId", "rulesetName", "target", "enforcement", "refIncludes", "refExcludes", "requiredStatusCheck", "pullRequestRequired", "requiredApprovingReviewCount", "nonFastForwardBlocked", "bypassActorCount", "updatedAt") "Public repository branch protection"
foreach ($field in @("status", "provider", "rulesetName", "target", "enforcement")) {
  Assert-Equal (Assert-RequiredJsonString $sourceBranchProtection $field "Public branch protection") (Assert-RequiredJsonString $reportBranchProtection $field "Public repository branch protection") "Public branch protection $field must match public cutover evidence."
}
Assert-RequiredInt64 $reportBranchProtection "rulesetId" 18761017 "Public repository branch protection"
Assert-RequiredInt64 $reportBranchProtection "requiredApprovingReviewCount" 0 "Public repository branch protection"
Assert-RequiredInt64 $reportBranchProtection "bypassActorCount" 0 "Public repository branch protection"
Assert-Equal $sourceBranchProtectionUpdatedAt (Get-RequiredUtcTimestamp $reportBranchProtection "updatedAt" "Public repository branch protection") "Public branch protection updatedAt must match public cutover evidence."
Assert-RequiredBooleanTrue $reportBranchProtection "pullRequestRequired" "Public repository branch protection"
Assert-RequiredBooleanTrue $reportBranchProtection "nonFastForwardBlocked" "Public repository branch protection"
if (-not (Test-HasProperty $reportBranchProtection "refIncludes")) {
  throw "Public repository branch protection must define refIncludes."
}
$reportRefIncludesValue = $reportBranchProtection.refIncludes
if ($reportRefIncludesValue -isnot [System.Array]) {
  throw "Public repository branch protection refIncludes must be a JSON array."
}
$reportRefIncludes = @($reportRefIncludesValue)
Assert-Equal $sourceRefIncludes.Count $reportRefIncludes.Count "Public branch protection ref selectors must match public cutover evidence."
Assert-True ($reportRefIncludes[0] -is [string]) "Public repository branch protection refIncludes entries must be JSON strings."
Assert-Equal $sourceRefIncludes[0] $reportRefIncludes[0] "Public branch protection ref selector must match public cutover evidence."
if (-not (Test-HasProperty $reportBranchProtection "refExcludes")) {
  throw "Public repository branch protection must define refExcludes."
}
if ($reportBranchProtection.refExcludes -isnot [System.Array]) {
  throw "Public repository branch protection refExcludes must be a JSON array."
}
$reportRefExcludes = @($reportBranchProtection.refExcludes)
Assert-Equal $sourceRefExcludes.Count $reportRefExcludes.Count "Public branch protection excluded refs must match public cutover evidence."
$reportRequiredStatusCheck = Get-RequiredProperty $reportBranchProtection "requiredStatusCheck" "Public repository branch protection"
Assert-OnlyProperties $reportRequiredStatusCheck @("displayName", "context", "integrationId", "strict") "Public repository branch protection required status check"
foreach ($field in @("displayName", "context", "integrationId")) {
  if ($field -ne "integrationId") {
    Assert-Equal (Assert-RequiredJsonString $sourceRequiredStatusCheck $field "Public branch protection required status check") (Assert-RequiredJsonString $reportRequiredStatusCheck $field "Public repository branch protection required status check") "Public branch protection required status check $field must match public cutover evidence."
  }
}
Assert-RequiredInt64 $reportRequiredStatusCheck "integrationId" 15368 "Public repository branch protection required status check"
Assert-RequiredBooleanFalse $reportRequiredStatusCheck "strict" "Public repository branch protection required status check"
Assert-Equal "complete" (Assert-RequiredJsonString $report.publicCutover.ciHomeMigration "status" "CI home migration") "CI home migration must record completed owner operations."
Assert-Equal "PR Fast" ([string]$report.publicCutover.ciHomeMigration.workflow) "CI home migration must bind the PR Fast workflow."
Assert-Equal "PR Fast / windows" ([string]$report.publicCutover.ciHomeMigration.requiredCheck) "CI home migration must bind the public required check."
$ciRunUrl = Assert-RequiredString $report.publicCutover.ciHomeMigration "runUrl" "CI home migration"
Assert-True ($ciRunUrl -match '^https://github\.com/Hitsuki-Ban/SubversionR/actions/runs/[0-9]+$') "CI home migration run URL must identify a public repository Actions run."
Assert-Equal $cutoverHeadCommit ([string]$report.publicCutover.ciHomeMigration.headSha) "CI home migration headSha must match the recorded cutover head commit."
Assert-Equal "push" ([string]$report.publicCutover.ciHomeMigration.event) "CI home migration event must be push."
Assert-Equal "success" ([string]$report.publicCutover.ciHomeMigration.conclusion) "CI home migration conclusion must be success."
[void](Assert-RequiredString $report.publicCutover.ciHomeMigration "startedAt" "CI home migration")
[void](Assert-RequiredString $report.publicCutover.ciHomeMigration "completedAt" "CI home migration")
Assert-RequiredBooleanTrue $report.publicCutover.ciHomeMigration "publicPrFastFirstRunGreen" "CI home migration"
Assert-RequiredBooleanTrue $report.publicCutover.ciHomeMigration "publicHeavyWorkflowScheduleOnly" "CI home migration"
Assert-RequiredBooleanTrue $report.publicCutover.ciHomeMigration "privateWorkflowsDisabled" "CI home migration"
Assert-RequiredBooleanTrue $report.publicCutover.ciHomeMigration "privateWorkflowDisableDateRecorded" "CI home migration"
Assert-Equal 0 @($report.publicCutover.ciHomeMigration.blockers).Count "Completed CI home migration must not retain blockers."
$cutoverCi = Get-RequiredProperty $publicCutoverEvidence "ci" "Public cutover evidence"
Assert-OnlyProperties $cutoverCi @("status", "workflow", "requiredCheck", "runUrl", "headSha", "event", "conclusion", "startedAt", "completedAt", "publicPrFastFirstRunGreen", "publicHeavyWorkflowScheduleOnly", "privateWorkflowsDisabled", "privateWorkflowDisableDateRecorded", "privateWorkflowDisablement") "Public cutover source CI"
Assert-RequiredBooleanTrue $cutoverCi "publicPrFastFirstRunGreen" "Public cutover source CI"
Assert-RequiredBooleanTrue $cutoverCi "publicHeavyWorkflowScheduleOnly" "Public cutover source CI"
Assert-RequiredBooleanTrue $cutoverCi "privateWorkflowsDisabled" "Public cutover source CI"
Assert-RequiredBooleanTrue $cutoverCi "privateWorkflowDisableDateRecorded" "Public cutover source CI"
foreach ($field in @("workflow", "requiredCheck", "runUrl", "headSha", "event", "conclusion", "startedAt", "completedAt")) {
  Assert-Equal ([string]$cutoverCi.$field) ([string]$report.publicCutover.ciHomeMigration.$field) "CI home migration $field must match public cutover evidence."
}
foreach ($field in @("publicPrFastFirstRunGreen", "publicHeavyWorkflowScheduleOnly", "privateWorkflowsDisabled", "privateWorkflowDisableDateRecorded")) {
  Assert-Equal ([bool]$cutoverCi.$field) ([bool]$report.publicCutover.ciHomeMigration.$field) "CI home migration $field must match public cutover evidence."
}
$sourcePrivateWorkflowDisablement = Get-RequiredProperty $cutoverCi "privateWorkflowDisablement" "Public cutover source CI"
$reportPrivateWorkflowDisablement = Get-RequiredProperty $report.publicCutover.ciHomeMigration "privateWorkflowDisablement" "CI home migration"
Assert-OnlyProperties $sourcePrivateWorkflowDisablement @("status", "disableDate", "workflows") "Private workflow disablement"
Assert-OnlyProperties $reportPrivateWorkflowDisablement @("status", "disableDate", "workflows") "CI home migration private workflow disablement"
Assert-Equal "complete" (Assert-RequiredJsonString $sourcePrivateWorkflowDisablement "status" "Private workflow disablement") "Private workflow disablement status must be complete."
Assert-Equal (Assert-RequiredJsonString $sourcePrivateWorkflowDisablement "status" "Private workflow disablement") (Assert-RequiredJsonString $reportPrivateWorkflowDisablement "status" "CI home migration private workflow disablement") "Private workflow disablement status must match public cutover evidence."
$privateWorkflowDisableDate = Assert-RequiredJsonString $sourcePrivateWorkflowDisablement "disableDate" "Private workflow disablement"
Assert-Equal "2026-07-10" $privateWorkflowDisableDate "Private workflow disableDate must match the owner operation date."
Assert-Equal $privateWorkflowDisableDate (Assert-RequiredJsonString $reportPrivateWorkflowDisablement "disableDate" "CI home migration private workflow disablement") "Private workflow disable date must match public cutover evidence."
if (-not (Test-HasProperty $sourcePrivateWorkflowDisablement "workflows")) {
  throw "Private workflow disablement must define workflows."
}
if (-not (Test-HasProperty $reportPrivateWorkflowDisablement "workflows")) {
  throw "CI home migration private workflow disablement must define workflows."
}
$sourcePrivateWorkflowsValue = $sourcePrivateWorkflowDisablement.workflows
$reportPrivateWorkflowsValue = $reportPrivateWorkflowDisablement.workflows
if ($sourcePrivateWorkflowsValue -isnot [System.Array]) {
  throw "Private workflow disablement workflows must be a JSON array."
}
if ($reportPrivateWorkflowsValue -isnot [System.Array]) {
  throw "CI home migration private workflow disablement workflows must be a JSON array."
}
$sourcePrivateWorkflows = @($sourcePrivateWorkflowsValue)
$reportPrivateWorkflows = @($reportPrivateWorkflowsValue)
Assert-Equal 2 $sourcePrivateWorkflows.Count "Private workflow disablement must record exactly two source workflows."
Assert-Equal 2 $reportPrivateWorkflows.Count "CI home migration must record exactly two disabled workflows."
$privateWorkflowContracts = @(
  [pscustomobject]@{ name = "CI"; workflowId = [int64]300115281; path = ".github/workflows/ci.yml" },
  [pscustomobject]@{ name = "PR Fast"; workflowId = [int64]303103620; path = ".github/workflows/pr-fast.yml" }
)
foreach ($contract in $privateWorkflowContracts) {
  $sourceMatches = @($sourcePrivateWorkflows | Where-Object { $_.name -is [string] -and $_.name -eq $contract.name })
  $reportMatches = @($reportPrivateWorkflows | Where-Object { $_.name -is [string] -and $_.name -eq $contract.name })
  Assert-Equal 1 $sourceMatches.Count "Private workflow '$($contract.name)' must be recorded exactly once in public cutover evidence."
  Assert-Equal 1 $reportMatches.Count "Private workflow '$($contract.name)' must be recorded exactly once in the publication gaps report."
  $sourceWorkflow = $sourceMatches[0]
  $reportWorkflow = $reportMatches[0]
  Assert-OnlyProperties $sourceWorkflow @("name", "workflowId", "path", "state") "Private workflow '$($contract.name)'"
  Assert-OnlyProperties $reportWorkflow @("name", "workflowId", "path", "state") "Publication gaps private workflow '$($contract.name)'"
  Assert-Equal $contract.name (Assert-RequiredJsonString $sourceWorkflow "name" "Private workflow '$($contract.name)'") "Private workflow '$($contract.name)' source name must match."
  Assert-Equal $contract.name (Assert-RequiredJsonString $reportWorkflow "name" "Publication gaps private workflow '$($contract.name)'") "Private workflow '$($contract.name)' report name must match."
  Assert-RequiredInt64 $sourceWorkflow "workflowId" $contract.workflowId "Private workflow '$($contract.name)'"
  Assert-RequiredInt64 $reportWorkflow "workflowId" $contract.workflowId "Publication gaps private workflow '$($contract.name)'"
  Assert-Equal $contract.path (Assert-RequiredString $sourceWorkflow "path" "Private workflow '$($contract.name)'") "Private workflow '$($contract.name)' path must match."
  Assert-Equal "disabled_manually" (Assert-RequiredString $sourceWorkflow "state" "Private workflow '$($contract.name)'") "Private workflow '$($contract.name)' source state must be disabled_manually."
  foreach ($field in @("path", "state")) {
    Assert-Equal (Assert-RequiredJsonString $sourceWorkflow $field "Private workflow '$($contract.name)'") (Assert-RequiredJsonString $reportWorkflow $field "Publication gaps private workflow '$($contract.name)'") "Private workflow '$($contract.name)' $field must match public cutover evidence."
  }
}
$expectedManualSteps = @(
  "Verify and complete public repository homepage and social metadata."
)
Assert-Equal $expectedManualSteps.Count @($report.publicCutover.manualSteps).Count "Public cutover manual-step count must match the remaining work."
foreach ($manualStep in $expectedManualSteps) {
  Assert-ArrayContainsExactlyOnce -Values @($report.publicCutover.manualSteps) -Expected $manualStep -Context "Public cutover manual steps"
}
Assert-Equal "retired" ([string]$report.publicCutover.cloudflareBridgeRetirement.status) "Cloudflare bridge retirement must be recorded as retired."
Assert-Equal "subversionr-pr-fast" ([string]$report.publicCutover.cloudflareBridgeRetirement.workerName) "Cloudflare bridge retirement must bind the worker name."
Assert-Equal "PR Fast / windows" ([string]$report.publicCutover.cloudflareBridgeRetirement.publicCiReplacement) "Cloudflare bridge retirement must bind the public replacement check."
Assert-RequiredBooleanTrue $report.publicCutover.cloudflareBridgeRetirement "disconnected" "Cloudflare bridge retirement"
Assert-RequiredBooleanTrue $report.publicCutover.cloudflareBridgeRetirement "triggersDisabled" "Cloudflare bridge retirement"
Assert-True ([string]$report.publicCutover.cloudflareBridgeRetirement.retirementDate -match '^20[0-9]{2}-[0-9]{2}-[0-9]{2}$') "Cloudflare bridge retirement date must use YYYY-MM-DD."
$cutoverCloudflare = Get-RequiredProperty $publicCutoverEvidence "cloudflareBridgeRetirement" "Public cutover evidence"
Assert-OnlyProperties $cutoverCloudflare @("status", "workerName", "publicCiReplacement", "disconnected", "triggersDisabled", "retirementDate") "Public cutover source Cloudflare retirement"
Assert-RequiredBooleanTrue $cutoverCloudflare "disconnected" "Public cutover source Cloudflare retirement"
Assert-RequiredBooleanTrue $cutoverCloudflare "triggersDisabled" "Public cutover source Cloudflare retirement"
foreach ($field in @("status", "workerName", "publicCiReplacement", "retirementDate")) {
  Assert-Equal ([string]$cutoverCloudflare.$field) ([string]$report.publicCutover.cloudflareBridgeRetirement.$field) "Cloudflare bridge retirement $field must match public cutover evidence."
}
foreach ($field in @("disconnected", "triggersDisabled")) {
  Assert-Equal ([bool]$cutoverCloudflare.$field) ([bool]$report.publicCutover.cloudflareBridgeRetirement.$field) "Cloudflare bridge retirement $field must match public cutover evidence."
}
Assert-Equal "published" ([string]$report.publicCutover.release.status) "Public release must be recorded as published."
Assert-Equal "v0.2.0-beta.1" ([string]$report.publicCutover.release.tag) "Public release tag must be recorded."
Assert-Equal $cutoverHeadCommit ([string]$report.publicCutover.release.tagCommit) "Public release tagCommit must match the recorded cutover head commit."
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/releases/tag/v0.2.0-beta.1" ([string]$report.publicCutover.release.url) "Public release URL must be recorded."
Assert-RequiredBooleanTrue $report.publicCutover.release "prerelease" "Public release"
[void](Assert-RequiredString $report.publicCutover.release "publishedAt" "Public release")
Assert-RequiredBooleanTrue $report.publicCutover.release "vsixAttached" "Public release"
Assert-RequiredBooleanTrue $report.publicCutover.release "sbomAttached" "Public release"
Assert-RequiredBooleanTrue $report.publicCutover.release "thirdPartyNoticesAttached" "Public release"
Assert-RequiredBooleanTrue $report.publicCutover.release "evidenceBundleAttached" "Public release"
Assert-RequiredBooleanTrue $report.publicCutover.release "artifactAttestationPublished" "Public release"
$cutoverRelease = Get-RequiredProperty $publicCutoverEvidence "release" "Public cutover evidence"
Assert-OnlyProperties $cutoverRelease @("status", "tag", "tagCommit", "url", "prerelease", "publishedAt", "artifactAttestationPublished", "assets") "Public cutover source release"
Assert-RequiredBooleanTrue $cutoverRelease "prerelease" "Public cutover source release"
Assert-RequiredBooleanTrue $cutoverRelease "artifactAttestationPublished" "Public cutover source release"
foreach ($field in @("status", "tag", "tagCommit", "url", "publishedAt")) {
  Assert-Equal ([string]$cutoverRelease.$field) ([string]$report.publicCutover.release.$field) "Public release $field must match public cutover evidence."
}
Assert-Equal ([bool]$cutoverRelease.prerelease) ([bool]$report.publicCutover.release.prerelease) "Public release prerelease must match public cutover evidence."
Assert-Equal ([bool]$cutoverRelease.artifactAttestationPublished) ([bool]$report.publicCutover.release.artifactAttestationPublished) "Public release artifactAttestationPublished must match public cutover evidence."
Assert-Equal ([string]$provenanceAttestation.runUrl) ([string]$report.publicCutover.release.attestationRunUrl) "Public release attestation run URL must match provenance evidence."
Assert-Equal ([string]$provenanceAttestation.attestationUrl) ([string]$report.publicCutover.release.attestationUrl) "Public release attestation URL must match provenance evidence."
Assert-Equal ([string]$provenanceAttestation.evidencePath) ([string]$report.publicCutover.release.attestationEvidencePath) "Public release attestation evidence path must match provenance evidence."
Assert-Equal ([string]$provenanceAttestation.evidenceSha256) ([string]$report.publicCutover.release.attestationEvidenceSha256) "Public release attestation evidence SHA256 must match provenance evidence."
$releaseAssets = @($report.publicCutover.release.assets)
$cutoverReleaseAssets = @($cutoverRelease.assets)
Assert-Equal 4 $releaseAssets.Count "Public release must record exactly four assets."
Assert-Equal 4 $cutoverReleaseAssets.Count "Public cutover source release must record exactly four assets."
foreach ($asset in $cutoverReleaseAssets) {
  Assert-OnlyProperties $asset @("name", "size", "sha256", "url") "Public cutover source release asset"
}
foreach ($assetName in @(
    "subversionr-source-sbom.cdx.json",
    "subversionr-win32-x64-0.2.0.vsix",
    "subversionr-win32-x64-beta-candidate.zip",
    "THIRD-PARTY-NOTICES.md"
  )) {
  $matches = @($releaseAssets | Where-Object { [string]$_.name -eq $assetName })
  Assert-Equal 1 $matches.Count "Public release asset '$assetName' must be recorded exactly once."
  $asset = $matches[0]
  $sourceMatches = @($cutoverReleaseAssets | Where-Object { [string]$_.name -eq $assetName })
  Assert-Equal 1 $sourceMatches.Count "Public cutover source release asset '$assetName' must be recorded exactly once."
  $sourceAsset = $sourceMatches[0]
  Assert-True ([int64]$asset.size -gt 0) "Public release asset '$assetName' must record a positive size."
  Assert-True ([string]$asset.sha256 -match '^[a-f0-9]{64}$') "Public release asset '$assetName' must record a lowercase SHA256."
  Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR/releases/download/v0.2.0-beta.1/$assetName" ([string]$asset.url) "Public release asset '$assetName' URL must match."
  foreach ($field in @("name", "size", "sha256", "url")) {
    Assert-Equal ([string]$sourceAsset.$field) ([string]$asset.$field) "Public release asset '$assetName' $field must match public cutover evidence."
  }
}
$releasedVsix = @($releaseAssets | Where-Object { [string]$_.name -eq "subversionr-win32-x64-0.2.0.vsix" })[0]
Assert-Equal ([string]$provenanceAttestation.subjectSha256) ([string]$releasedVsix.sha256) "Historical released VSIX SHA256 must match historical provenance attestation evidence."
Assert-Equal ([string]$provenanceAttestation.subjectName) ([string]$releasedVsix.name) "Historical released VSIX name must match historical provenance attestation evidence."
Assert-Equal ([int64]$provenanceAttestation.artifactSize) ([int64]$releasedVsix.size) "Historical released VSIX size must match historical provenance attestation evidence."

$betaCandidateEvidence = Get-RequiredProperty $publicCutoverEvidence "betaCandidateEvidence" "Public cutover evidence"
Assert-OnlyProperties $betaCandidateEvidence @("status", "publishedBundleAssetName", "publishedBundleSha256", "expectedVsixName", "expectedVsixSha256", "containedVsixName", "containedVsixSha256", "declaredPayloadCount", "missingPayloadCount", "mismatchedPayloadCount", "consistencyVerified", "regenerationCompleted") "Public cutover source Beta candidate evidence"
$reportedBetaCandidateEvidence = Get-RequiredProperty $report.publicCutover "betaCandidateEvidence" "Publication gaps public cutover"
Assert-RequiredBooleanTrue $betaCandidateEvidence "consistencyVerified" "Public cutover source Beta candidate evidence"
Assert-RequiredBooleanTrue $betaCandidateEvidence "regenerationCompleted" "Public cutover source Beta candidate evidence"
Assert-RequiredBooleanTrue $reportedBetaCandidateEvidence "consistencyVerified" "Publication gaps Beta candidate evidence"
Assert-RequiredBooleanTrue $reportedBetaCandidateEvidence "regenerationCompleted" "Publication gaps Beta candidate evidence"
foreach ($field in @(
    "status",
    "publishedBundleAssetName",
    "publishedBundleSha256",
    "expectedVsixName",
    "expectedVsixSha256",
    "containedVsixName",
    "containedVsixSha256",
    "declaredPayloadCount",
    "missingPayloadCount",
    "mismatchedPayloadCount",
    "consistencyVerified",
    "regenerationCompleted"
  )) {
  Assert-Equal ([string]$betaCandidateEvidence.$field) ([string]$reportedBetaCandidateEvidence.$field) "Beta candidate evidence $field must match public cutover evidence."
}
Assert-Equal "consistent" ([string]$reportedBetaCandidateEvidence.status) "Published Beta candidate evidence must record the verified consistent bundle."
Assert-Equal ([string]$releasedVsix.sha256) ([string]$reportedBetaCandidateEvidence.expectedVsixSha256) "Beta candidate evidence must bind the released VSIX SHA256."
Assert-Equal ([string]$releasedVsix.sha256) ([string]$reportedBetaCandidateEvidence.containedVsixSha256) "Beta candidate evidence must bind the bundled VSIX SHA256 to the released asset."
Assert-Equal 0 ([int]$reportedBetaCandidateEvidence.missingPayloadCount) "Published Beta candidate evidence must record no missing payloads."
Assert-Equal 0 ([int]$reportedBetaCandidateEvidence.mismatchedPayloadCount) "Published Beta candidate evidence must record no mismatched payloads."
$publishedBundle = @($releaseAssets | Where-Object { [string]$_.name -eq "subversionr-win32-x64-beta-candidate.zip" })[0]
Assert-Equal ([string]$publishedBundle.sha256) ([string]$reportedBetaCandidateEvidence.publishedBundleSha256) "Beta candidate evidence must bind the published bundle SHA256."

Write-Host "Verified SubversionR publication gaps report for $Target at $evidenceResolved."

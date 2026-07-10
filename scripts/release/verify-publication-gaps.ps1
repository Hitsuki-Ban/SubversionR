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
    "VSIX signing remains absent in the upstream provenance preflight.",
    "Public branch protection is not configured.",
    "Public repository homepage and social metadata are not fully verified.",
    "Private repository workflows are not disabled.",
    "The published Beta candidate bundle is inconsistent with its manifest and cannot close the post-cutover Beta-G chain.",
    "Previous stable artifact rollback evidence is not generated by this local gap report."
  )) {
  Assert-ArrayContainsExactlyOnce -Values @($report.blockers) -Expected $blocker -Context "Publication gaps blockers"
}

foreach ($nonClaim in @(
    "This gate is a local publication gaps report, not a publication readiness certificate.",
    "This gate records public repository metadata and cutover state from hash-bound evidence without recording a private remote, credentialed URL, or Marketplace publication URL.",
    "This gate does not verify Marketplace publisher ownership, contributor access, or authorization.",
    "This gate does not configure or validate Microsoft Entra ID workload identity, managed identity, PAT, VSCE_PAT, or any other credential.",
    "This gate does not publish to Visual Studio Marketplace.",
    "This gate does not install from Visual Studio Marketplace or prove public acquisition.",
    "This gate does not configure public branch protection or disable private workflows.",
    "This gate records live GitHub artifact attestation publication and verification but does not prove VSIX signing, previous-stable rollback, final SBOM/NOTICE review, or CVE review."
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
Assert-HashRecord $report.evidence.publicCutoverEvidence "Public cutover evidence"
Assert-HashRecord $report.evidence.provenancePreflight "Provenance preflight"
Assert-HashRecord $report.evidence.vsixPackage "VSIX package evidence"
Assert-Equal "subversionr.release.marketplace-provenance-preflight.win32-x64.v1" (Assert-RequiredString $report.evidence.provenancePreflight "schema" "Provenance preflight evidence") "Provenance preflight schema must be bound."
Assert-Equal "subversionr.release.vsix-package.win32-x64.v1" (Assert-RequiredString $report.evidence.vsixPackage "schema" "VSIX package evidence") "VSIX package evidence schema must be bound."
$provenance = Get-Content -Raw -LiteralPath (Assert-File ([string]$report.evidence.provenancePreflight.path) "Provenance preflight") | ConvertFrom-Json
Assert-Equal "verified" ([string]$provenance.attestation.status) "Provenance preflight must record live attestation verification."
$provenanceAttestation = Get-RequiredProperty $provenance.attestation "readiness" "Provenance attestation"
Assert-Equal "live-attestation-verified" ([string]$provenanceAttestation.readinessStatus) "Provenance attestation readiness must record live verification."
Assert-RequiredBooleanTrue $provenanceAttestation "verified" "Provenance attestation readiness"

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

$cutoverRepository = Get-RequiredProperty $publicCutoverEvidence "repository" "Public cutover evidence"
Assert-RequiredBooleanTrue $cutoverRepository "resolvesToPublic" "Public cutover source repository"
Assert-RequiredBooleanFalse $cutoverRepository "branchProtectionConfigured" "Public cutover source repository"
Assert-RequiredBooleanTrue $cutoverRepository "privateVulnerabilityReportingEnabled" "Public cutover source repository"
Assert-RequiredBooleanFalse $cutoverRepository "metadataVerified" "Public cutover source repository"
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
Assert-Equal ([string]$cutoverRepository.branchProtectionRequiredCheck) ([string]$report.publicCutover.publicRepository.branchProtectionRequiredCheck) "Public branch-protection check must match public cutover evidence."
Assert-Equal ([bool]$cutoverRepository.branchProtectionConfigured) ([bool]$report.publicCutover.publicRepository.branchProtectionConfigured) "Public branch-protection state must match public cutover evidence."
Assert-Equal ([bool]$cutoverRepository.privateVulnerabilityReportingEnabled) ([bool]$report.publicCutover.publicRepository.privateVulnerabilityReportingEnabled) "PVR state must match public cutover evidence."
Assert-Equal ([bool]$cutoverRepository.metadataVerified) ([bool]$report.publicCutover.publicRepository.metadataVerified) "Public repository metadata state must match public cutover evidence."
Assert-Equal "PR Fast / windows" ([string]$report.publicCutover.publicRepository.branchProtectionRequiredCheck) "Public branch protection required check must be recorded."
Assert-RequiredBooleanFalse $report.publicCutover.publicRepository "branchProtectionConfigured" "Public repository"
Assert-RequiredBooleanTrue $report.publicCutover.publicRepository "privateVulnerabilityReportingEnabled" "Public repository"
Assert-RequiredBooleanFalse $report.publicCutover.publicRepository "metadataVerified" "Public repository"
Assert-Equal "public-pr-fast-green-owner-follow-up" ([string]$report.publicCutover.ciHomeMigration.status) "CI home migration must record green public PR Fast with remaining owner follow-up."
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
Assert-RequiredBooleanFalse $report.publicCutover.ciHomeMigration "privateWorkflowsDisabled" "CI home migration"
Assert-RequiredBooleanFalse $report.publicCutover.ciHomeMigration "privateWorkflowDisableDateRecorded" "CI home migration"
$cutoverCi = Get-RequiredProperty $publicCutoverEvidence "ci" "Public cutover evidence"
Assert-RequiredBooleanTrue $cutoverCi "publicPrFastFirstRunGreen" "Public cutover source CI"
Assert-RequiredBooleanTrue $cutoverCi "publicHeavyWorkflowScheduleOnly" "Public cutover source CI"
Assert-RequiredBooleanFalse $cutoverCi "privateWorkflowsDisabled" "Public cutover source CI"
Assert-RequiredBooleanFalse $cutoverCi "privateWorkflowDisableDateRecorded" "Public cutover source CI"
foreach ($field in @("workflow", "requiredCheck", "runUrl", "headSha", "event", "conclusion", "startedAt", "completedAt")) {
  Assert-Equal ([string]$cutoverCi.$field) ([string]$report.publicCutover.ciHomeMigration.$field) "CI home migration $field must match public cutover evidence."
}
foreach ($field in @("publicPrFastFirstRunGreen", "publicHeavyWorkflowScheduleOnly", "privateWorkflowsDisabled", "privateWorkflowDisableDateRecorded")) {
  Assert-Equal ([bool]$cutoverCi.$field) ([bool]$report.publicCutover.ciHomeMigration.$field) "CI home migration $field must match public cutover evidence."
}
Assert-Equal "retired" ([string]$report.publicCutover.cloudflareBridgeRetirement.status) "Cloudflare bridge retirement must be recorded as retired."
Assert-Equal "subversionr-pr-fast" ([string]$report.publicCutover.cloudflareBridgeRetirement.workerName) "Cloudflare bridge retirement must bind the worker name."
Assert-Equal "PR Fast / windows" ([string]$report.publicCutover.cloudflareBridgeRetirement.publicCiReplacement) "Cloudflare bridge retirement must bind the public replacement check."
Assert-RequiredBooleanTrue $report.publicCutover.cloudflareBridgeRetirement "disconnected" "Cloudflare bridge retirement"
Assert-RequiredBooleanTrue $report.publicCutover.cloudflareBridgeRetirement "triggersDisabled" "Cloudflare bridge retirement"
Assert-True ([string]$report.publicCutover.cloudflareBridgeRetirement.retirementDate -match '^20[0-9]{2}-[0-9]{2}-[0-9]{2}$') "Cloudflare bridge retirement date must use YYYY-MM-DD."
$cutoverCloudflare = Get-RequiredProperty $publicCutoverEvidence "cloudflareBridgeRetirement" "Public cutover evidence"
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
Assert-Equal ([string]$report.artifacts.vsix.sha256) ([string]$releasedVsix.sha256) "Released VSIX SHA256 must match the current candidate."
Assert-Equal ([int64]$report.artifacts.vsix.size) ([int64]$releasedVsix.size) "Released VSIX size must match the current candidate."

$betaCandidateEvidence = Get-RequiredProperty $publicCutoverEvidence "betaCandidateEvidence" "Public cutover evidence"
$reportedBetaCandidateEvidence = Get-RequiredProperty $report.publicCutover "betaCandidateEvidence" "Publication gaps public cutover"
Assert-RequiredBooleanFalse $betaCandidateEvidence "consistencyVerified" "Public cutover source Beta candidate evidence"
Assert-RequiredBooleanFalse $betaCandidateEvidence "regenerationCompleted" "Public cutover source Beta candidate evidence"
Assert-RequiredBooleanFalse $reportedBetaCandidateEvidence "consistencyVerified" "Publication gaps Beta candidate evidence"
Assert-RequiredBooleanFalse $reportedBetaCandidateEvidence "regenerationCompleted" "Publication gaps Beta candidate evidence"
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
Assert-Equal "blocked-published-bundle-inconsistent" ([string]$reportedBetaCandidateEvidence.status) "Published Beta candidate evidence must remain blocked on bundle inconsistency."
Assert-Equal ([string]$releasedVsix.sha256) ([string]$reportedBetaCandidateEvidence.expectedVsixSha256) "Beta candidate evidence must bind the released VSIX SHA256."
$publishedBundle = @($releaseAssets | Where-Object { [string]$_.name -eq "subversionr-win32-x64-beta-candidate.zip" })[0]
Assert-Equal ([string]$publishedBundle.sha256) ([string]$reportedBetaCandidateEvidence.publishedBundleSha256) "Beta candidate evidence must bind the published bundle SHA256."

Write-Host "Verified SubversionR publication gaps report for $Target at $evidenceResolved."

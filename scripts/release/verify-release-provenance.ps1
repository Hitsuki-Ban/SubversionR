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

function ConvertTo-CanonicalJson([object]$Value) {
  $Value | ConvertTo-Json -Depth 100 -Compress
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

function Test-HasProperty([object]$Object, [string]$Name) {
  $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
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

function Assert-MarketplaceIcon([object]$IconRecord, [string]$IconPath) {
  Assert-Equal "resources/marketplace/icon.png" (Assert-RequiredString $IconRecord "path" "Marketplace icon") "Marketplace icon path must match the extension manifest."
  Assert-True ([int]$IconRecord.width -ge 128) "Marketplace icon width must be at least 128 pixels."
  Assert-True ([int]$IconRecord.height -ge 128) "Marketplace icon height must be at least 128 pixels."
  $dimensions = Get-PngDimensions -Path $IconPath -Name "Marketplace icon"
  Assert-Equal ([int]$IconRecord.width) $dimensions.width "Marketplace icon width must match the PNG IHDR."
  Assert-Equal ([int]$IconRecord.height) $dimensions.height "Marketplace icon height must match the PNG IHDR."
}

$releaseEvidenceRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence"))
$scriptTestRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-provenance-scripts"))
$evidenceResolved = Assert-GeneratedPath -Path $EvidencePath -Name "EvidencePath" -AllowedRoots @(
  $releaseEvidenceRoot,
  $scriptTestRoot
) -Description "target/release-evidence or target/tests/release-provenance-scripts"
$report = Get-Content -Raw -LiteralPath $evidenceResolved | ConvertFrom-Json

Assert-Equal 1 ([int]$report.schemaVersion) "Provenance schemaVersion should be 1."
Assert-Equal "subversionr.release.marketplace-provenance-preflight.win32-x64.v1" ([string]$report.schema) "Provenance schema should match M7j2a."
Assert-Equal $Target ([string]$report.target) "Provenance target should match the requested target."
Assert-Equal "False" ([string]$report.publicReadinessClaim) "publicReadinessClaim must remain false."
Assert-Equal "True" ([string]$report.localPreflightOnly) "localPreflightOnly must remain true."
Assert-Equal "hitsuki-ban.subversionr" ([string]$report.extension.id) "Extension identity must remain hitsuki-ban.subversionr."
Assert-Equal "SubversionR" ([string]$report.extension.displayName) "Extension display name should remain SubversionR."
Assert-Equal "False" ([string]$report.repository.remoteUrlRecorded) "Repository remote URL must not be recorded."
Assert-Equal "unsigned" ([string]$report.signing.status) "Signing status must remain unsigned in this gate."
Assert-Equal "verified" ([string]$report.attestation.status) "Attestation status must record live verification."
Assert-Equal "not-published" ([string]$report.marketplace.status) "Marketplace status must remain not-published in this gate."
Assert-Equal "not-proven" ([string]$report.previousStableRollback.status) "Previous-stable rollback status must remain not-proven in this gate."
Assert-Equal "False" ([string]$report.marketplaceMetadata.publicationReady) "Marketplace metadata preflight must not claim publication readiness."
Assert-Equal "True" ([string]$report.marketplaceMetadata.required.hasIcon) "Marketplace metadata preflight must require an icon."
Assert-Equal "True" ([string]$report.marketplaceMetadata.required.hasKeywords) "Marketplace metadata preflight must require keywords."
Assert-Equal "True" ([string]$report.marketplaceMetadata.recommended.hasChangelog) "Marketplace metadata preflight must record CHANGELOG presence."
Assert-Equal "True" ([string]$report.marketplaceMetadata.recommended.hasSupport) "Marketplace metadata preflight must record SUPPORT presence."
Assert-Equal "True" ([string]$report.marketplaceMetadata.recommended.hasRepository) "Marketplace metadata preflight must record repository metadata presence."
Assert-Equal "True" ([string]$report.marketplaceMetadata.recommended.hasHomepage) "Marketplace metadata preflight must record homepage metadata presence."
Assert-Equal "True" ([string]$report.marketplaceMetadata.recommended.hasBugs) "Marketplace metadata preflight must record issue tracker metadata presence."
Assert-Equal "False" ([string]$report.marketplaceMetadata.recommended.privatePackage) "Extension package must not remain private for the public Marketplace identity."

foreach ($requiredKeyword in @("svn", "subversion", "source-control", "scm", "apache-subversion")) {
  Assert-True (@($report.extension.keywords | Where-Object { $_ -eq $requiredKeyword }).Count -eq 1) "Extension Marketplace keywords must include $requiredKeyword."
}

foreach ($traceId in @("SEC-015", "MIG-009", "MIG-012")) {
  Assert-True (@($report.traceIds | Where-Object { $_ -eq $traceId }).Count -eq 1) "Provenance report must include trace ID $traceId."
}
foreach ($nonClaim in @(
    "This gate does not prove VSIX signing.",
    "This gate records live GitHub artifact attestation publication and verification but does not claim artifact signing.",
    "This post-release attestation does not prove the original VSIX source-to-binary build provenance.",
    "This gate does not prove Marketplace publication or public install.",
    "This gate does not prove previous-stable upgrade or rollback.",
    "This gate does not prove installed Source Control DOM/accessibility-tree/pixel E2E.",
    "This gate does not prove final SBOM, NOTICE, or CVE review completion."
  )) {
  Assert-True (@($report.nonClaims | Where-Object { $_ -eq $nonClaim }).Count -eq 1) "Provenance report nonClaims must include '$nonClaim'."
}
foreach ($blocker in @(
    "Marketplace publisher authorization is not verified by this local preflight.",
    "Marketplace publish authentication is not configured by this local preflight.",
    "Marketplace/public install evidence is not generated by this local preflight.",
    "Previous stable artifact rollback evidence is not generated by this local preflight."
  )) {
  Assert-True (@($report.marketplaceMetadata.blockers | Where-Object { $_ -eq $blocker }).Count -eq 1) "Marketplace metadata blockers must include '$blocker'."
}

$vsixPath = Assert-GeneratedPath -Path ([string]$report.artifacts.vsix.path) -Name "VSIX artifact" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\vsix")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-provenance-scripts"))
) -Description "target/vsix or target/tests/release-provenance-scripts"
if (-not (Test-Path -LiteralPath $vsixPath -PathType Leaf)) {
  throw "VSIX artifact must be a file: $($report.artifacts.vsix.path)"
}
Assert-Equal ([string]$report.artifacts.vsix.sha256) (Get-Sha256 $vsixPath) "VSIX SHA256 must match current bytes."
$vsixEvidencePath = Assert-File ([string]$report.artifacts.vsix.evidencePath) "VSIX evidence"
Assert-Equal ([string]$report.artifacts.vsix.evidenceSha256) (Get-Sha256 $vsixEvidencePath) "VSIX evidence SHA256 must match current bytes."

if (-not (Test-HasProperty $report.attestation "readiness")) {
  throw "Live attestation evidence contract must be present."
}
$attestationReadiness = $report.attestation.readiness
$vsixRelativePath = [string]$report.artifacts.vsix.relativePath
$vsixFileName = Split-Path -Leaf $vsixPath
$vsixSize = (Get-Item -LiteralPath $vsixPath).Length
Assert-Equal "live-attestation-verified" (Assert-RequiredString $attestationReadiness "readinessStatus" "Attestation readiness") "Attestation readiness status should record live verification."
Assert-Equal "github-artifact-attestations" (Assert-RequiredString $attestationReadiness "provider" "Attestation readiness") "Attestation readiness provider should be GitHub artifact attestations."
Assert-Equal "actions/attest@v4" (Assert-RequiredString $attestationReadiness "action" "Attestation readiness") "Attestation readiness action should match the issue #5 workflow contract."
Assert-Equal "a1948c3f048ba23858d222213b7c278aabede763" (Assert-RequiredString $attestationReadiness "actionDigest" "Attestation readiness") "Attestation readiness action digest should remain pinned."
$predicateType = "https://github.com/Hitsuki-Ban/SubversionR/attestations/post-release-asset/v1"
Assert-Equal $predicateType (Assert-RequiredString $attestationReadiness "predicateType" "Attestation readiness") "Attestation readiness predicate type should identify the post-release verification schema."
Assert-Equal "docs/release/post-release-asset-verification-predicate.v1.schema.json" (Assert-RequiredString $attestationReadiness "predicateSchemaPath" "Attestation readiness") "Attestation readiness predicate schema path should remain source-controlled."
Assert-Equal "subversionr.release.post-release-asset-verification-predicate.v1" (Assert-RequiredString $attestationReadiness "predicateSchema" "Attestation readiness") "Attestation readiness signed predicate schema should match."
Assert-Equal "post-release-asset-digest-verification" (Assert-RequiredString $attestationReadiness "predicateClaim" "Attestation readiness") "Attestation readiness signed predicate claim should match."
Assert-RequiredBooleanFalse $attestationReadiness "originalBuildProvenanceClaim" "Attestation readiness"
Assert-RequiredBooleanFalse $attestationReadiness "artifactSignatureClaim" "Attestation readiness"
Assert-Equal $vsixFileName (Assert-RequiredString $attestationReadiness "subjectName" "Attestation readiness") "Attestation readiness subjectName must match the VSIX file name."
Assert-Equal ([string]$report.artifacts.vsix.sha256) (Assert-RequiredString $attestationReadiness "subjectSha256" "Attestation readiness") "Attestation readiness subjectSha256 must match the exact VSIX SHA256."
Assert-Equal $vsixRelativePath (Assert-RequiredString $attestationReadiness "artifactPath" "Attestation readiness") "Attestation readiness artifactPath must match the VSIX relative path."
Assert-Equal $vsixSize ([int64]$attestationReadiness.artifactSize) "Attestation readiness artifactSize must match the exact VSIX size."
Assert-Equal ".github/workflows/attest-release-vsix.yml" (Assert-RequiredString $attestationReadiness "workflowPath" "Attestation readiness") "Attestation readiness workflowPath should name the live attestation workflow."
$verificationCommand = Assert-RequiredString $attestationReadiness "verificationCommand" "Attestation readiness"
Assert-True ($verificationCommand.Contains("--bundle $($attestationReadiness.bundlePath)")) "Attestation verificationCommand should verify the exact source-controlled bundle."
Assert-True ($verificationCommand.Contains("--signer-workflow Hitsuki-Ban/SubversionR/.github/workflows/attest-release-vsix.yml")) "Attestation verificationCommand should pin the live signer workflow."
Assert-True ($verificationCommand.Contains("--signer-digest $($attestationReadiness.signerDigest)")) "Attestation verificationCommand should pin the signer digest."
Assert-True ($verificationCommand.Contains("--source-ref $($attestationReadiness.sourceRef)")) "Attestation verificationCommand should pin the source ref."
Assert-True ($verificationCommand.Contains("--source-digest $($attestationReadiness.sourceDigest)")) "Attestation verificationCommand should pin the source digest."
Assert-RequiredBooleanTrue $attestationReadiness "repoUrlRecorded" "Attestation readiness"
Assert-RequiredBooleanTrue $attestationReadiness "bundleRecorded" "Attestation readiness"
Assert-RequiredBooleanTrue $attestationReadiness "attestationUrlRecorded" "Attestation readiness"
Assert-RequiredBooleanTrue $attestationReadiness "verified" "Attestation readiness"
Assert-Equal "https://github.com/Hitsuki-Ban/SubversionR" (Assert-RequiredString $attestationReadiness "repositoryUrl" "Attestation readiness") "Attestation repository URL must be recorded."
$runUrl = Assert-RequiredString $attestationReadiness "runUrl" "Attestation readiness"
Assert-True ($runUrl -match '^https://github\.com/Hitsuki-Ban/SubversionR/actions/runs/[0-9]+$') "Attestation run URL must identify a public repository Actions run."
$attestationUrl = Assert-RequiredString $attestationReadiness "attestationUrl" "Attestation readiness"
Assert-True ($attestationUrl -match '^https://github\.com/Hitsuki-Ban/SubversionR/attestations/[0-9]+$') "Attestation URL must identify a public repository attestation."
Assert-True ((Assert-RequiredString $attestationReadiness "bundleSha256" "Attestation readiness") -match '^[a-f0-9]{64}$') "Attestation bundle SHA256 must be recorded."
Assert-True ((Assert-RequiredString $attestationReadiness "evidenceSha256" "Attestation readiness") -match '^[a-f0-9]{64}$') "Live attestation evidence SHA256 must be recorded."

if (-not (Test-HasProperty $attestationReadiness "requiredPermissions")) {
  throw "Attestation readiness must define requiredPermissions."
}
$requiredPermissions = @($attestationReadiness.requiredPermissions | ForEach-Object { [string]$_ })
$expectedPermissions = @("id-token: write", "contents: read", "attestations: write")
Assert-Equal $expectedPermissions.Count $requiredPermissions.Count "Attestation readiness must record exactly the required GitHub Actions permissions."
foreach ($permission in $expectedPermissions) {
  Assert-True ($requiredPermissions -contains $permission) "Attestation readiness permissions must include $permission."
}

Assert-HashRecord $report.artifacts.backendManifest "Backend manifest"
Assert-HashRecord $report.evidence.extensionPackage "Extension package"
Assert-HashRecord $report.evidence.rootPackage "Root package"
Assert-HashRecord $report.evidence.readme "README"
Assert-HashRecord $report.evidence.license "LICENSE"
Assert-HashRecord $report.evidence.changelog "CHANGELOG"
Assert-HashRecord $report.evidence.support "SUPPORT"
Assert-HashRecord $report.evidence.marketplaceIcon "Marketplace icon"
Assert-HashRecord $report.evidence.sourceLock "Source lock"
Assert-HashRecord $report.evidence.pnpmLock "pnpm lock"
Assert-HashRecord $report.evidence.cargoLock "Cargo lock"
Assert-HashRecord $report.evidence.sbom "SBOM"
Assert-HashRecord $report.evidence.notice "NOTICE"
Assert-HashRecord $report.evidence.attestationContract "Attestation contract"
Assert-HashRecord $report.evidence.liveAttestation "Live attestation evidence"
Assert-HashRecord $report.evidence.attestationBundle "Attestation bundle"
Assert-HashRecord $report.evidence.attestationVerification "Attestation verification result"
Assert-Equal "subversionr.release.github-attestation-contract.win32-x64.v1" (Assert-RequiredString $report.evidence.attestationContract "schema" "Attestation contract evidence") "Attestation contract schema must be bound."
Assert-Equal "subversionr.release.live-github-attestation.win32-x64.v1" (Assert-RequiredString $report.evidence.liveAttestation "schema" "Live attestation evidence") "Live attestation schema must be bound."
Assert-Equal ([string]$report.evidence.liveAttestation.path) (Assert-RequiredString $attestationReadiness "evidencePath" "Attestation readiness") "Attestation readiness must bind the live evidence path."
Assert-Equal ([string]$report.evidence.liveAttestation.sha256) (Assert-RequiredString $attestationReadiness "evidenceSha256" "Attestation readiness") "Attestation readiness must bind the live evidence SHA256."

$attestationContractPath = [string]$report.evidence.attestationContract.path
$liveAttestationPath = [string]$report.evidence.liveAttestation.path
if (Test-IsPathWithin -Path $evidenceResolved -Root $releaseEvidenceRoot) {
  $expectedAttestationContractPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "docs\release\github-attestation-contract.win32-x64.json"))
  $expectedLiveAttestationPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "docs\release\github-attestation-evidence.win32-x64.json"))
  $expectedAttestationBundlePath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "docs\release\github-attestation-bundle.win32-x64.json"))
  $expectedAttestationVerificationPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "docs\release\github-attestation-verification.win32-x64.json"))
  Assert-Equal $expectedAttestationContractPath (Get-RepoAbsolutePath $attestationContractPath) "Production provenance must bind the source-controlled attestation contract."
  Assert-Equal $expectedLiveAttestationPath (Get-RepoAbsolutePath $liveAttestationPath) "Production provenance must bind the source-controlled live attestation evidence."
  Assert-Equal $expectedAttestationBundlePath (Get-RepoAbsolutePath ([string]$report.evidence.attestationBundle.path)) "Production provenance must bind the source-controlled attestation bundle."
  Assert-Equal $expectedAttestationVerificationPath (Get-RepoAbsolutePath ([string]$report.evidence.attestationVerification.path)) "Production provenance must bind the source-controlled attestation verification result."
}
else {
  $fixtureRoot = Split-Path -Parent (Split-Path -Parent $evidenceResolved)
  Assert-True (Test-IsPathWithin -Path (Get-RepoAbsolutePath $attestationContractPath) -Root $fixtureRoot) "Test provenance must bind its isolated attestation contract fixture."
  Assert-True (Test-IsPathWithin -Path (Get-RepoAbsolutePath $liveAttestationPath) -Root $fixtureRoot) "Test provenance must bind its isolated live attestation fixture."
  Assert-True (Test-IsPathWithin -Path (Get-RepoAbsolutePath ([string]$report.evidence.attestationBundle.path)) -Root $fixtureRoot) "Test provenance must bind its isolated attestation bundle fixture."
  Assert-True (Test-IsPathWithin -Path (Get-RepoAbsolutePath ([string]$report.evidence.attestationVerification.path)) -Root $fixtureRoot) "Test provenance must bind its isolated attestation verification fixture."
}
$liveAttestation = Get-Content -Raw -LiteralPath (Assert-File $liveAttestationPath "Live attestation source") | ConvertFrom-Json
Assert-Equal "live-attestation-verified" ([string]$liveAttestation.status) "Live attestation source must be verified."
Assert-RequiredBooleanFalse $liveAttestation "publicReadinessClaim" "Live attestation source"
Assert-RequiredBooleanFalse $liveAttestation "signingClaim" "Live attestation source"
Assert-RequiredBooleanTrue $liveAttestation.verification "verified" "Live attestation source verification"
Assert-RequiredBooleanTrue $liveAttestation.verification "denySelfHostedRunners" "Live attestation source verification"
Assert-Equal ([string]$liveAttestation.subject.name) ([string]$attestationReadiness.subjectName) "Attestation subject name must match live evidence."
Assert-Equal ([string]$liveAttestation.subject.sha256) ([string]$attestationReadiness.subjectSha256) "Attestation subject SHA256 must match live evidence."
Assert-Equal ([int64]$liveAttestation.subject.size) ([int64]$attestationReadiness.artifactSize) "Attestation subject size must match live evidence."
Assert-Equal ([string]$liveAttestation.workflow.path) ([string]$attestationReadiness.workflowPath) "Attestation workflow path must match live evidence."
Assert-Equal ([string]$liveAttestation.workflow.runUrl) ([string]$attestationReadiness.runUrl) "Attestation run URL must match live evidence."
Assert-Equal ([string]$liveAttestation.attestation.url) ([string]$attestationReadiness.attestationUrl) "Attestation URL must match live evidence."
Assert-Equal ([string]$liveAttestation.attestation.bundleSha256) ([string]$attestationReadiness.bundleSha256) "Attestation bundle SHA256 must match live evidence."
Assert-Equal ([string]$liveAttestation.verification.command) ([string]$attestationReadiness.verificationCommand) "Attestation verification command must match live evidence."
Assert-Equal ([string]$liveAttestation.attestation.bundlePath) ([string]$attestationReadiness.bundlePath) "Attestation bundle path must match live evidence."
Assert-Equal ([string]$liveAttestation.verification.resultPath) ([string]$attestationReadiness.verificationResultPath) "Attestation verification result path must match live evidence."
Assert-Equal ([string]$liveAttestation.verification.resultSha256) ([string]$attestationReadiness.verificationResultSha256) "Attestation verification result SHA256 must match live evidence."
Assert-Equal ([string]$liveAttestation.workflow.sourceRef) ([string]$attestationReadiness.sourceRef) "Attestation source ref must match live evidence."
Assert-Equal ([string]$liveAttestation.workflow.headSha) ([string]$attestationReadiness.sourceDigest) "Attestation source digest must match live evidence."
Assert-Equal ([string]$liveAttestation.workflow.headSha) ([string]$attestationReadiness.signerDigest) "Attestation signer digest must match live evidence."
Assert-Equal ([string]$liveAttestation.attestation.predicateSchemaPath) ([string]$attestationReadiness.predicateSchemaPath) "Attestation predicate schema path must match live evidence."
Assert-Equal ([string]$liveAttestation.attestation.predicateSchema) ([string]$attestationReadiness.predicateSchema) "Attestation signed predicate schema must match live evidence."
Assert-Equal ([string]$liveAttestation.attestation.predicateClaim) ([string]$attestationReadiness.predicateClaim) "Attestation signed predicate claim must match live evidence."
Assert-RequiredBooleanFalse $liveAttestation.attestation "originalBuildProvenanceClaim" "Live attestation signed predicate"
Assert-RequiredBooleanFalse $liveAttestation.attestation "artifactSignatureClaim" "Live attestation signed predicate"

$bundlePath = Assert-File ([string]$report.evidence.attestationBundle.path) "Attestation bundle"
$recordedVerificationPath = Assert-File ([string]$report.evidence.attestationVerification.path) "Attestation verification result"
Assert-Equal ([string]$liveAttestation.attestation.bundleSha256) (Get-Sha256 $bundlePath) "Live attestation bundle hash must match source-controlled bytes."
Assert-Equal ([string]$liveAttestation.verification.resultSha256) (Get-Sha256 $recordedVerificationPath) "Live attestation verification hash must match source-controlled bytes."
$bundleObjects = @(Get-Content -Raw -LiteralPath $bundlePath | ConvertFrom-Json)
$recordedVerificationResults = @(Get-Content -Raw -LiteralPath $recordedVerificationPath | ConvertFrom-Json)
Assert-Equal 1 $bundleObjects.Count "Attestation bundle must contain exactly one bundle."
Assert-Equal 1 $recordedVerificationResults.Count "Recorded attestation verification must contain exactly one result."
Assert-Equal (ConvertTo-CanonicalJson $bundleObjects[0]) (ConvertTo-CanonicalJson $recordedVerificationResults[0].attestation.bundle) "Recorded verification must contain the exact source-controlled bundle."

if ($null -eq (Get-Command gh -ErrorAction SilentlyContinue)) {
  throw "gh is required to cryptographically verify the source-controlled attestation bundle."
}
$liveVerificationOutput = @(
  & gh attestation verify $vsixPath `
    -R ([string]$liveAttestation.verification.repository) `
    --bundle $bundlePath `
    --signer-workflow ([string]$liveAttestation.verification.signerWorkflow) `
    --signer-digest ([string]$liveAttestation.workflow.headSha) `
    --source-ref ([string]$liveAttestation.workflow.sourceRef) `
    --source-digest ([string]$liveAttestation.workflow.headSha) `
    --predicate-type ([string]$liveAttestation.verification.predicateType) `
    --deny-self-hosted-runners `
    --format json
)
if ($LASTEXITCODE -ne 0) {
  throw "gh attestation verify failed for the source-controlled bundle with exit code $LASTEXITCODE."
}
$liveVerificationResults = @(($liveVerificationOutput -join [Environment]::NewLine) | ConvertFrom-Json)
Assert-Equal 1 $liveVerificationResults.Count "Live bundle verification must return exactly one result."
$verifiedResult = $liveVerificationResults[0]
Assert-Equal (ConvertTo-CanonicalJson $bundleObjects[0]) (ConvertTo-CanonicalJson $verifiedResult.attestation.bundle) "Live verification must return the exact source-controlled bundle."
$verifiedStatement = $verifiedResult.verificationResult.statement
$verifiedSubjects = @($verifiedStatement.subject | Where-Object { [string]$_.name -eq [string]$liveAttestation.subject.name -and [string]$_.digest.sha256 -eq [string]$liveAttestation.subject.sha256 })
Assert-Equal 1 $verifiedSubjects.Count "Live verification must bind the exact released VSIX subject."
Assert-Equal ([string]$liveAttestation.verification.predicateType) ([string]$verifiedStatement.predicateType) "Live verification predicate type must match the policy."
$verifiedPredicate = $verifiedStatement.predicate
Assert-Equal "subversionr.release.post-release-asset-verification-predicate.v1" ([string]$verifiedPredicate.schema) "Live verification signed predicate schema must match."
Assert-Equal "post-release-asset-digest-verification" ([string]$verifiedPredicate.claim) "Live verification signed predicate claim must match."
Assert-RequiredBooleanFalse $verifiedPredicate "originalBuildProvenanceClaim" "Live verification signed predicate"
Assert-RequiredBooleanFalse $verifiedPredicate "artifactSignatureClaim" "Live verification signed predicate"
Assert-Equal ([string]$liveAttestation.release.tag) ([string]$verifiedPredicate.release.tag) "Live verification signed predicate release tag must match."
Assert-Equal ([string]$liveAttestation.release.url) ([string]$verifiedPredicate.release.url) "Live verification signed predicate release URL must match."
Assert-Equal ([string]$liveAttestation.subject.name) ([string]$verifiedPredicate.release.assetName) "Live verification signed predicate asset name must match."
Assert-Equal ([int64]$liveAttestation.subject.size) ([int64]$verifiedPredicate.release.assetSize) "Live verification signed predicate asset size must match."
Assert-Equal ([string]$liveAttestation.subject.sha256) ([string]$verifiedPredicate.release.assetSha256) "Live verification signed predicate asset SHA256 must match."
Assert-Equal ([string]$liveAttestation.contract.path) ([string]$verifiedPredicate.contract.path) "Live verification signed predicate contract path must match."
Assert-Equal ([string]$liveAttestation.contract.sha256) ([string]$verifiedPredicate.contract.sha256) "Live verification signed predicate contract SHA256 must match."
foreach ($verificationFlag in @("assetDownloadedFromRelease", "subjectNameMatched", "subjectSizeMatched", "subjectSha256Matched")) {
  Assert-RequiredBooleanTrue $verifiedPredicate.verification $verificationFlag "Live verification signed predicate verification"
}
$verifiedCertificate = $verifiedResult.verificationResult.signature.certificate
Assert-Equal ([string]$liveAttestation.verification.certificate.signerIdentity) ([string]$verifiedCertificate.subjectAlternativeName) "Live verification signer identity must match the recorded certificate."
Assert-Equal ([string]$liveAttestation.workflow.headSha) ([string]$verifiedCertificate.buildSignerDigest) "Live verification signer digest must match the recorded workflow SHA."
Assert-Equal ([string]$liveAttestation.workflow.headSha) ([string]$verifiedCertificate.sourceRepositoryDigest) "Live verification source digest must match the recorded workflow SHA."
Assert-Equal ([string]$liveAttestation.workflow.sourceRef) ([string]$verifiedCertificate.githubWorkflowRef) "Live verification source ref must match the recorded workflow ref."
Assert-Equal "github-hosted" ([string]$verifiedCertificate.runnerEnvironment) "Live verification must use a GitHub-hosted runner."
Assert-Equal "public" ([string]$verifiedCertificate.sourceRepositoryVisibilityAtSigning) "Live verification must record public source visibility."
Assert-Equal "$($liveAttestation.workflow.runUrl)/attempts/$($liveAttestation.workflow.runAttempt)" ([string]$verifiedCertificate.runInvocationURI) "Live verification run URI must match the recorded run attempt."
Assert-True (@($verifiedResult.verificationResult.verifiedTimestamps).Count -gt 0) "Live verification must include a verified timestamp."

$iconPath = Assert-File ([string]$report.evidence.marketplaceIcon.path) "Marketplace icon"
Assert-Equal ([string]$report.evidence.marketplaceIcon.sha256) ([string]$report.extension.icon.sha256) "Extension icon SHA256 must match evidence."
Assert-Equal ([string]$report.evidence.marketplaceIcon.sha256) ([string]$report.marketplaceMetadata.icon.sha256) "Marketplace metadata icon SHA256 must match evidence."
Assert-Equal ([string]$report.evidence.marketplaceIcon.sha256) ([string]$report.marketplaceMetadata.icon.vsixEvidenceSha256) "Marketplace metadata icon SHA256 must match VSIX evidence."
Assert-MarketplaceIcon -IconRecord $report.extension.icon -IconPath $iconPath
Assert-Equal "resources/marketplace/icon.png" ([string]$report.marketplaceMetadata.icon.packagePath) "Marketplace metadata icon packagePath must match the extension manifest."

Write-Host "Verified SubversionR release provenance preflight for $Target at $evidenceResolved."

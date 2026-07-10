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
  Assert-Equal "False" ([string]$Object.$Name) "$Context $Name must remain false."
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

$evidenceResolved = Assert-GeneratedPath -Path $EvidencePath -Name "EvidencePath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-provenance-scripts"))
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
Assert-Equal "not-generated" ([string]$report.attestation.status) "Attestation status must remain not-generated in this gate."
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
    "This gate does not prove GitHub artifact attestation publication.",
    "This gate does not prove GitHub artifact attestation generation, publication, or verification.",
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
  throw "Attestation readiness input contract must be present."
}
$attestationReadiness = $report.attestation.readiness
$vsixRelativePath = [string]$report.artifacts.vsix.relativePath
$vsixFileName = Split-Path -Leaf $vsixPath
$vsixSize = (Get-Item -LiteralPath $vsixPath).Length
Assert-Equal "input-contract-ready" (Assert-RequiredString $attestationReadiness "readinessStatus" "Attestation readiness") "Attestation readiness status should be input-contract-ready."
Assert-Equal "github-artifact-attestations" (Assert-RequiredString $attestationReadiness "provider" "Attestation readiness") "Attestation readiness provider should be GitHub artifact attestations."
Assert-Equal "actions/attest@v4" (Assert-RequiredString $attestationReadiness "action" "Attestation readiness") "Attestation readiness action should match the documented GitHub action."
Assert-Equal "https://slsa.dev/provenance/v1" (Assert-RequiredString $attestationReadiness "predicateType" "Attestation readiness") "Attestation readiness predicate type should match GitHub CLI default provenance verification."
Assert-Equal $vsixFileName (Assert-RequiredString $attestationReadiness "subjectName" "Attestation readiness") "Attestation readiness subjectName must match the VSIX file name."
Assert-Equal ([string]$report.artifacts.vsix.sha256) (Assert-RequiredString $attestationReadiness "subjectSha256" "Attestation readiness") "Attestation readiness subjectSha256 must match the exact VSIX SHA256."
Assert-Equal $vsixRelativePath (Assert-RequiredString $attestationReadiness "artifactPath" "Attestation readiness") "Attestation readiness artifactPath must match the VSIX relative path."
Assert-Equal $vsixSize ([int64]$attestationReadiness.artifactSize) "Attestation readiness artifactSize must match the exact VSIX size."
Assert-Equal ".github/workflows/ci.yml" (Assert-RequiredString $attestationReadiness "workflowPath" "Attestation readiness") "Attestation readiness workflowPath should name the release-producing workflow."
Assert-Equal "gh attestation verify $vsixRelativePath -R Hitsuki-Ban/SubversionR --signer-workflow Hitsuki-Ban/SubversionR/.github/workflows/ci.yml --predicate-type https://slsa.dev/provenance/v1 --deny-self-hosted-runners --format json" (Assert-RequiredString $attestationReadiness "verificationCommand" "Attestation readiness") "Attestation readiness verificationCommand should pin repo, signer workflow, predicate type, and self-hosted runner policy."
Assert-RequiredBooleanFalse $attestationReadiness "repoUrlRecorded" "Attestation readiness"
Assert-RequiredBooleanFalse $attestationReadiness "bundleRecorded" "Attestation readiness"
Assert-RequiredBooleanFalse $attestationReadiness "attestationUrlRecorded" "Attestation readiness"
Assert-RequiredBooleanFalse $attestationReadiness "verified" "Attestation readiness"
Assert-NoProperty $attestationReadiness "bundlePath" "Attestation readiness"
Assert-NoProperty $attestationReadiness "attestationUrl" "Attestation readiness"
Assert-NoProperty $attestationReadiness "repositoryUrl" "Attestation readiness"

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

$iconPath = Assert-File ([string]$report.evidence.marketplaceIcon.path) "Marketplace icon"
Assert-Equal ([string]$report.evidence.marketplaceIcon.sha256) ([string]$report.extension.icon.sha256) "Extension icon SHA256 must match evidence."
Assert-Equal ([string]$report.evidence.marketplaceIcon.sha256) ([string]$report.marketplaceMetadata.icon.sha256) "Marketplace metadata icon SHA256 must match evidence."
Assert-Equal ([string]$report.evidence.marketplaceIcon.sha256) ([string]$report.marketplaceMetadata.icon.vsixEvidenceSha256) "Marketplace metadata icon SHA256 must match VSIX evidence."
Assert-MarketplaceIcon -IconRecord $report.extension.icon -IconPath $iconPath
Assert-Equal "resources/marketplace/icon.png" ([string]$report.marketplaceMetadata.icon.packagePath) "Marketplace metadata icon packagePath must match the extension manifest."

Write-Host "Verified SubversionR release provenance preflight for $Target at $evidenceResolved."

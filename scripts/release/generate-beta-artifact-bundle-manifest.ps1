[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$VsixPath,

  [Parameter(Mandatory = $true)]
  [string]$ReleaseEvidenceRoot,

  [Parameter(Mandatory = $true)]
  [string]$NoticePath,

  [Parameter(Mandatory = $true)]
  [string]$InstalledSourceControlUiE2eArtifactRoot,

  [Parameter(Mandatory = $true)]
  [string]$OutputPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).ProviderPath

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw $Message
  }
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
  if ($Expected -ne $Actual) {
    throw "$Message Expected '$Expected', got '$Actual'."
  }
}

function Get-RequiredProperty([object]$Object, [string]$Name, [string]$Context) {
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) {
    throw "$Context must define $Name."
  }
  $property.Value
}

function Assert-ExplicitPath([string]$Path, [string]$Name) {
  Assert-True (-not [string]::IsNullOrWhiteSpace($Path)) "$Name is required."
  Assert-True (-not $Path.Contains("%")) "$Name must be an explicit path, not an unresolved environment placeholder."
  Assert-True (-not $Path.Contains("$")) "$Name must be an explicit path, not an unresolved environment placeholder."
}

function Resolve-RepoPath([string]$Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Test-IsPathWithin([string]$Path, [string]$Root) {
  $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  )
  $pathFull = [System.IO.Path]::GetFullPath($Path).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  )
  $rootPrefix = "$rootFull$([System.IO.Path]::DirectorySeparatorChar)"
  $pathFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
    $pathFull.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-PathWithinRoot([string]$Path, [string]$Name, [string]$Root, [string]$Description) {
  Assert-ExplicitPath $Path $Name
  $resolved = Resolve-RepoPath $Path
  if (-not (Test-IsPathWithin -Path $resolved -Root $Root)) {
    throw "$Name must resolve inside $Description`: $resolved"
  }
  $resolved
}

function Assert-PathWithinAny([string]$Path, [string]$Name, [string[]]$AllowedRoots, [string]$Description) {
  Assert-ExplicitPath $Path $Name
  $resolved = Resolve-RepoPath $Path
  foreach ($allowedRoot in $AllowedRoots) {
    if (Test-IsPathWithin -Path $resolved -Root $allowedRoot) {
      return $resolved
    }
  }
  throw "$Name must resolve inside $Description`: $resolved"
}

function Assert-File([string]$Path, [string]$Name) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Name must be a file: $Path"
  }
  (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
}

function Assert-Directory([string]$Path, [string]$Name) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "$Name must be a directory: $Path"
  }
  (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
}

function Get-RepoRelativePath([string]$Path) {
  [System.IO.Path]::GetRelativePath($repoRoot, $Path).Replace("\", "/")
}

function Get-Sha256([string]$Path) {
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-FileRecord([string]$Path, [string]$Role) {
  $item = Get-Item -LiteralPath $Path
  [pscustomobject]@{
    role = $Role
    relativePath = Get-RepoRelativePath $item.FullName
    size = [int64]$item.Length
    sha256 = Get-Sha256 $item.FullName
  }
}

function Get-ExpectedUploadPaths([string]$Target) {
  @(
    "target/vsix/subversionr-win32-x64-0.2.3.vsix",
    "target/release-evidence/subversionr-source-sbom.cdx.json",
    "target/release-evidence/subversionr-vsix-package-$Target.json",
    "target/release-evidence/subversionr-vsix-cli-install-$Target.json",
    "target/release-evidence/subversionr-installed-extension-host-$Target.json",
    "target/release-evidence/subversionr-installed-core-workflow-$Target.json",
    "target/release-evidence/subversionr-installed-source-control-surface-$Target.json",
    "target/release-evidence/subversionr-installed-source-control-ui-e2e-$Target.json",
    "target/release-evidence/subversionr-install-rollback-fixture-$Target.json",
    "target/release-evidence/subversionr-native-artifact-map-preflight-$Target.json",
    "target/release-evidence/subversionr-marketplace-provenance-preflight-$Target.json",
    "target/release-evidence/subversionr-publication-gaps-$Target.json",
    "target/release-evidence/subversionr-state-engine-beta-performance-$Target.json",
    "target/release-evidence/subversionr-beta-artifact-bundle-manifest-$Target.json",
    "target/release-evidence/subversionr-beta-candidate-consistency-$Target.json",
    "target/release-evidence/THIRD-PARTY-NOTICES.md",
    "target/release-evidence/installed-source-control-ui-e2e/$Target/**/*.png",
    "target/release-evidence/installed-source-control-ui-e2e/$Target/**/*.txt",
    "target/release-evidence/installed-source-control-ui-e2e/$Target/**/*.json"
  )
}

$targetReleaseEvidenceRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence"))
$testReleaseEvidenceRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-beta-candidate-evidence-scripts"))
$targetVsixRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\vsix"))

$releaseEvidenceRootResolved = Assert-PathWithinAny `
  -Path $ReleaseEvidenceRoot `
  -Name "ReleaseEvidenceRoot" `
  -AllowedRoots @($targetReleaseEvidenceRoot, $testReleaseEvidenceRoot) `
  -Description "target/release-evidence or target/tests/release-beta-candidate-evidence-scripts"
$releaseEvidenceRootResolved = Assert-Directory $releaseEvidenceRootResolved "ReleaseEvidenceRoot"

$provenancePath = Assert-File `
  (Join-Path $releaseEvidenceRootResolved "subversionr-marketplace-provenance-preflight-$Target.json") `
  "Marketplace provenance preflight"
$provenance = Get-Content -Raw -LiteralPath $provenancePath | ConvertFrom-Json
Assert-Equal `
  "candidate-seal" `
  ([string](Get-RequiredProperty $provenance "mode" "Marketplace provenance preflight")) `
  "Beta candidate artifact bundle generation requires candidate-seal provenance mode."
$candidateAttestation = Get-RequiredProperty $provenance "candidateAttestation" "Marketplace provenance preflight"
Assert-Equal `
  "asserted-exact-match" `
  ([string](Get-RequiredProperty $candidateAttestation "subjectComparison" "Marketplace provenance candidateAttestation")) `
  "Beta candidate artifact bundle generation requires an exact frozen-contract subject comparison."

$vsixResolved = Assert-PathWithinAny `
  -Path $VsixPath `
  -Name "VsixPath" `
  -AllowedRoots @($targetVsixRoot, $testReleaseEvidenceRoot) `
  -Description "target/vsix or target/tests/release-beta-candidate-evidence-scripts"
$vsixResolved = Assert-File $vsixResolved "VsixPath"

$noticeResolved = Assert-PathWithinRoot `
  -Path $NoticePath `
  -Name "NoticePath" `
  -Root $releaseEvidenceRootResolved `
  -Description "ReleaseEvidenceRoot"
$noticeResolved = Assert-File $noticeResolved "NoticePath"

$artifactRootResolved = Assert-PathWithinRoot `
  -Path $InstalledSourceControlUiE2eArtifactRoot `
  -Name "InstalledSourceControlUiE2eArtifactRoot" `
  -Root $releaseEvidenceRootResolved `
  -Description "ReleaseEvidenceRoot"
$artifactRootResolved = Assert-Directory $artifactRootResolved "InstalledSourceControlUiE2eArtifactRoot"

$outputResolved = Assert-PathWithinRoot `
  -Path $OutputPath `
  -Name "OutputPath" `
  -Root $releaseEvidenceRootResolved `
  -Description "ReleaseEvidenceRoot"

$expectedOutput = Join-Path $releaseEvidenceRootResolved "subversionr-beta-artifact-bundle-manifest-$Target.json"
if (-not ([System.IO.Path]::GetFullPath($outputResolved).Equals([System.IO.Path]::GetFullPath($expectedOutput), [System.StringComparison]::OrdinalIgnoreCase))) {
  throw "OutputPath must be the target Beta artifact bundle manifest: $expectedOutput"
}

$candidateConsistencyPath = Join-Path $releaseEvidenceRootResolved "subversionr-beta-candidate-consistency-$Target.json"
if (Test-Path -LiteralPath $candidateConsistencyPath -PathType Leaf) {
  throw "Beta artifact bundle manifest must be generated before the final Beta candidate consistency report: $candidateConsistencyPath"
}

$topLevelEvidenceFiles = @(
  "subversionr-source-sbom.cdx.json",
  "subversionr-vsix-package-$Target.json",
  "subversionr-vsix-cli-install-$Target.json",
  "subversionr-installed-extension-host-$Target.json",
  "subversionr-installed-core-workflow-$Target.json",
  "subversionr-installed-source-control-surface-$Target.json",
  "subversionr-installed-source-control-ui-e2e-$Target.json",
  "subversionr-install-rollback-fixture-$Target.json",
  "subversionr-native-artifact-map-preflight-$Target.json",
  "subversionr-marketplace-provenance-preflight-$Target.json",
  "subversionr-publication-gaps-$Target.json",
  "subversionr-state-engine-beta-performance-$Target.json"
)

$files = [System.Collections.Generic.List[object]]::new()
$files.Add((New-FileRecord -Path $vsixResolved -Role "vsix")) | Out-Null
foreach ($fileName in $topLevelEvidenceFiles) {
  $files.Add((New-FileRecord -Path (Assert-File (Join-Path $releaseEvidenceRootResolved $fileName) $fileName) -Role "release-evidence-json")) | Out-Null
}
$files.Add((New-FileRecord -Path $noticeResolved -Role "third-party-notice")) | Out-Null

$uiArtifactFiles = @(Get-ChildItem -LiteralPath $artifactRootResolved -Recurse -File |
  Where-Object { $_.Extension -in @(".json", ".png", ".txt") } |
  Sort-Object FullName)
if ($uiArtifactFiles.Count -eq 0) {
  throw "InstalledSourceControlUiE2eArtifactRoot must contain renderer artifact files."
}
foreach ($file in $uiArtifactFiles) {
  $files.Add((New-FileRecord -Path $file.FullName -Role "installed-source-control-ui-e2e-artifact")) | Out-Null
}

$sortedFiles = @($files | Sort-Object relativePath)
$uniquePaths = @{}
foreach ($file in $sortedFiles) {
  if ($uniquePaths.ContainsKey($file.relativePath)) {
    throw "Beta artifact bundle manifest must not contain duplicate file path: $($file.relativePath)"
  }
  $uniquePaths[$file.relativePath] = $true
}

$totalSize = [int64]0
foreach ($file in $sortedFiles) {
  $totalSize += [int64]$file.size
}

$manifest = [pscustomobject]@{
  schemaVersion = 1
  schema = "subversionr.release.beta-artifact-bundle-manifest.$Target.v1"
  publicReadinessClaim = $false
  localCandidateOnly = $true
  target = $Target
  generatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
  candidateSeal = [pscustomobject]@{
    provenancePath = Get-RepoRelativePath $provenancePath
    mode = "candidate-seal"
    subjectComparison = "asserted-exact-match"
  }
  uploadContract = [pscustomobject]@{
    uploadAction = "actions/upload-artifact@v7"
    name = "subversionr-win32-x64-beta-candidate"
    condition = "`${{ env.SUBVERSIONR_RELEASE_CI_MODE == 'candidate-seal' }}"
    paths = @(Get-ExpectedUploadPaths -Target $Target)
    ifNoFilesFound = "error"
    retentionDays = 14
    includeHiddenFiles = $false
  }
  manifestSelf = [pscustomobject]@{
    relativePath = Get-RepoRelativePath $outputResolved
    sha256BoundBy = "subversionr.release.beta-candidate-consistency.$Target.v1"
  }
  fileCount = $sortedFiles.Count
  totalSize = $totalSize
  files = $sortedFiles
}

$parent = Split-Path -Parent $outputResolved
New-Item -ItemType Directory -Force -Path $parent | Out-Null
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outputResolved -Encoding utf8
Write-Host "Generated SubversionR Beta artifact bundle manifest for $Target at $outputResolved."

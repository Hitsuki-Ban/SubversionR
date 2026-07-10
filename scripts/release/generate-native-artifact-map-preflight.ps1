[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$SourceLockPath,

  [Parameter(Mandatory = $true)]
  [string]$ArtifactMapPath,

  [Parameter(Mandatory = $true)]
  [string]$BackendManifestPath,

  [Parameter(Mandatory = $true)]
  [string]$VsixEvidencePath,

  [Parameter(Mandatory = $true)]
  [string]$OutputPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$allowedPackageModes = @("packaged-runtime", "static-link-input", "fixture-runtime")
$evidenceBoundary = "This gate confirms that declared native source-lock entries are explicitly mapped to staged package artifacts or enumerated non-shipping roles and that staged artifact bytes match the backend package manifest. It does not attest reproducibility, the build environment, the compiler inputs used for each binary, signed attestations, or post-gate integrity."
$requiredNonClaims = @(
  "This gate does not prove reproducible builds.",
  "This gate does not prove the staged binaries were compiled from the locked source archives.",
  "This gate does not prove signing, notarization, or GitHub artifact attestation publication.",
  "This gate does not prove post-gate artifact integrity."
)

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

function Assert-Directory([string]$Path, [string]$Name) {
  $absolute = Get-RepoAbsolutePath $Path
  if (-not (Test-Path -LiteralPath $absolute -PathType Container)) {
    throw "$Name must be a directory: $Path"
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

function Get-OptionalStringArray([object]$Object, [string]$Name) {
  if (-not (Test-HasProperty $Object $Name) -or $null -eq $Object.$Name) {
    return @()
  }
  @($Object.$Name | ForEach-Object { [string]$_ })
}

function Assert-NormalizedPackagePath([string]$Path, [string]$Context) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "$Context must not be empty."
  }
  if ($Path.Contains("*")) {
    throw "$Context must be an exact normalized package path, not a pattern: $Path"
  }
  Assert-NormalizedPackagePattern -Pattern $Path -Context $Context
}

function Assert-NormalizedPackagePattern([string]$Pattern, [string]$Context) {
  if ([string]::IsNullOrWhiteSpace($Pattern)) {
    throw "$Context must not be empty."
  }
  if ([System.IO.Path]::IsPathRooted($Pattern) -or $Pattern.Contains("\") -or $Pattern.Contains("../") -or $Pattern.Contains("/../") -or $Pattern -eq "." -or $Pattern.StartsWith("./")) {
    throw "$Context must be a normalized package path or pattern: $Pattern"
  }
  foreach ($segment in $Pattern.Split("/")) {
    if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq "." -or $segment -eq "..") {
      throw "$Context must be a normalized package path or pattern: $Pattern"
    }
  }
  if (-not $Pattern.StartsWith("resources/backend/$Target/", [System.StringComparison]::Ordinal)) {
    throw "$Context must stay inside resources/backend/$Target`: $Pattern"
  }
}

function ConvertTo-SourceDigest([object]$Source) {
  $digest = [ordered]@{}
  foreach ($name in @("sha512", "sha256", "sha3_256")) {
    $property = $Source.PSObject.Properties[$name]
    if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
      $digest[$name] = [string]$property.Value
    }
  }
  Assert-True ($digest.Count -gt 0) "Source lock component '$($Source.name)' must define at least one source digest."
  [pscustomobject]$digest
}

function Assert-SourceCollection([object[]]$Sources) {
  Assert-True ($Sources.Count -gt 0) "SourceLockPath must contain a non-empty sources array."
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($source in $Sources) {
    $name = Assert-RequiredString $source "name" "Source lock component"
    Assert-True ($seen.Add($name)) "Source lock component '$name' is duplicated."
    Assert-RequiredString $source "version" "Source lock component '$name'" | Out-Null
    Assert-RequiredString $source "license" "Source lock component '$name'" | Out-Null
    ConvertTo-SourceDigest $source | Out-Null
  }
}

function Get-ArtifactRecord([object]$ArtifactByPath, [string]$Path, [string]$Context) {
  Assert-NormalizedPackagePath -Path $Path -Context $Context
  if (-not $ArtifactByPath.ContainsKey($Path)) {
    throw "$Context required artifact is not present in the backend manifest: $Path"
  }
  $ArtifactByPath[$Path]
}

function ConvertTo-ArtifactReport([object]$Artifact) {
  [pscustomobject]@{
    role = [string]$Artifact.role
    path = [string]$Artifact.path
    size = [int64]$Artifact.size
    sha256 = [string]$Artifact.sha256
  }
}

$sourceLockResolved = Assert-File $SourceLockPath "SourceLockPath"
$artifactMapResolved = Assert-File $ArtifactMapPath "ArtifactMapPath"
$backendManifestResolved = Assert-File $BackendManifestPath "BackendManifestPath"
$vsixEvidenceResolved = Assert-File $VsixEvidencePath "VsixEvidencePath"
$outputResolved = Assert-GeneratedPath -Path $OutputPath -Name "OutputPath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-native-artifact-map-scripts"))
) -Description "target/release-evidence or target/tests/release-native-artifact-map-scripts"

$sourceLock = Get-Content -Raw -LiteralPath $sourceLockResolved | ConvertFrom-Json
$artifactMap = Get-Content -Raw -LiteralPath $artifactMapResolved | ConvertFrom-Json
$backendManifest = Get-Content -Raw -LiteralPath $backendManifestResolved | ConvertFrom-Json
$vsixEvidence = Get-Content -Raw -LiteralPath $vsixEvidenceResolved | ConvertFrom-Json

$sources = @($sourceLock.sources)
Assert-SourceCollection $sources

Assert-Equal 1 ([int]$artifactMap.schemaVersion) "ArtifactMapPath schemaVersion must be stable."
Assert-Equal "subversionr.release.native-artifact-map.win32-x64.v1" ([string]$artifactMap.schema) "ArtifactMapPath schema must match the native artifact map contract."
Assert-Equal $Target ([string]$artifactMap.target) "ArtifactMapPath target must match the requested target."
$declaredModes = @(Get-OptionalStringArray $artifactMap "packageModes")
Assert-Equal $allowedPackageModes.Count $declaredModes.Count "ArtifactMapPath packageModes must declare the closed package-mode taxonomy."
foreach ($mode in $allowedPackageModes) {
  Assert-True (@($declaredModes | Where-Object { $_ -eq $mode }).Count -eq 1) "ArtifactMapPath packageModes must include '$mode'."
}

Assert-Equal 1 ([int]$backendManifest.schemaVersion) "Backend manifest schemaVersion must be stable."
Assert-Equal "subversionr.vscode.backend-package.win32-x64.v1" ([string]$backendManifest.schema) "Backend manifest schema must match win32-x64."
Assert-Equal $Target ([string]$backendManifest.target) "Backend manifest target must match the requested target."
Assert-Equal "subversionr" ([string]$backendManifest.extension.id) "Backend manifest must bind the extension id."
Assert-Equal "staged-vsix-layout" ([string]$backendManifest.layoutKind) "Backend manifest must be a staged VSIX layout."

Assert-Equal 1 ([int]$vsixEvidence.schemaVersion) "VSIX package evidence schemaVersion must be stable."
Assert-Equal "subversionr.release.vsix-package.win32-x64.v1" ([string]$vsixEvidence.schema) "VsixEvidencePath must contain win32-x64 VSIX package evidence."
Assert-Equal $Target ([string]$vsixEvidence.target) "VSIX package evidence target must match the requested target."
Assert-Equal "False" ([string]$vsixEvidence.publicReadinessClaim) "VSIX package evidence publicReadinessClaim must remain false."
$vsixInputs = if (Test-HasProperty $vsixEvidence "inputs") { $vsixEvidence.inputs } else { throw "VSIX package evidence must define inputs." }
$packageRoot = Assert-RequiredString $vsixInputs "packageRoot" "VSIX package evidence inputs"
$packageRootResolved = Assert-Directory $packageRoot "VSIX package evidence packageRoot"
Assert-True (Test-IsPathWithin -Path $backendManifestResolved -Root $packageRootResolved) "BackendManifestPath must resolve inside the VSIX package evidence packageRoot."

$sourceByName = @{}
foreach ($source in $sources) {
  $sourceByName[[string]$source.name] = $source
}

$manifestSourceLocks = @($backendManifest.sourceLocks)
Assert-Equal $sources.Count $manifestSourceLocks.Count "Backend manifest sourceLocks should match SourceLockPath component count."
foreach ($source in $sources) {
  $manifestSource = @($manifestSourceLocks | Where-Object { [string]$_.name -eq [string]$source.name })
  Assert-Equal 1 $manifestSource.Count "Backend manifest must include source-lock component '$($source.name)'."
  Assert-Equal ([string]$source.version) ([string]$manifestSource[0].version) "Backend manifest source-lock version must match SourceLockPath for '$($source.name)'."
  Assert-Equal ([string]$source.license) ([string]$manifestSource[0].license) "Backend manifest source-lock license must match SourceLockPath for '$($source.name)'."
  Assert-Equal ([string]$source.sha512) ([string]$manifestSource[0].sha512) "Backend manifest source-lock sha512 must match SourceLockPath for '$($source.name)'."
}

$artifacts = @($backendManifest.artifacts)
Assert-True ($artifacts.Count -gt 0) "Backend manifest must define artifacts."
$artifactByPath = @{}
foreach ($artifact in $artifacts) {
  $artifactPath = Assert-RequiredString $artifact "path" "Backend manifest artifact"
  Assert-NormalizedPackagePath -Path $artifactPath -Context "Backend manifest artifact path"
  Assert-True (-not $artifactByPath.ContainsKey($artifactPath)) "Backend manifest artifact '$artifactPath' is duplicated."
  $role = Assert-RequiredString $artifact "role" "Backend manifest artifact '$artifactPath'"
  if (@("sidecar", "bridge", "nativeDependency") -notcontains $role) {
    throw "Backend manifest artifact '$artifactPath' has unsupported role '$role'."
  }
  $artifactFile = Join-Path $packageRootResolved $artifactPath.Replace("/", [System.IO.Path]::DirectorySeparatorChar)
  if (-not (Test-Path -LiteralPath $artifactFile -PathType Leaf)) {
    throw "Backend manifest artifact must exist under packageRoot: $artifactPath"
  }
  $item = Get-Item -LiteralPath $artifactFile
  Assert-Equal ([int64]$artifact.size) ([int64]$item.Length) "Backend manifest artifact size must match current bytes for '$artifactPath'."
  Assert-Equal ([string]$artifact.sha256) (Get-Sha256 $artifactFile) "Backend manifest artifact sha256 must match current bytes for '$artifactPath'."
  $artifactByPath[$artifactPath] = $artifact
}

$mapComponents = @($artifactMap.components)
Assert-True ($mapComponents.Count -gt 0) "ArtifactMapPath must define a non-empty components array."
$mappedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($component in $mapComponents) {
  $sourceName = Assert-RequiredString $component "sourceName" "Artifact map component"
  Assert-True ($mappedNames.Add($sourceName)) "Artifact map component '$sourceName' is duplicated."
}

$sourceNames = @($sources | ForEach-Object { [string]$_.name })
$mapNames = @($mapComponents | ForEach-Object { [string]$_.sourceName })
$unmappedSources = @($sourceNames | Where-Object { $mapNames -notcontains $_ })
$extraMappedSources = @($mapNames | Where-Object { $sourceNames -notcontains $_ })
if ($unmappedSources.Count -gt 0) {
  throw "ArtifactMapPath has unmapped source-lock components: $($unmappedSources -join ', ')"
}
if ($extraMappedSources.Count -gt 0) {
  throw "ArtifactMapPath has extra mapped components not present in SourceLockPath: $($extraMappedSources -join ', ')"
}

$coveredNativeArtifactPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$componentReports = @()
foreach ($source in $sources) {
  $component = @($mapComponents | Where-Object { [string]$_.sourceName -eq [string]$source.name })[0]
  $sourceName = [string]$source.name
  $packageMode = Assert-RequiredString $component "packageMode" "Artifact map component '$sourceName'"
  if ($allowedPackageModes -notcontains $packageMode) {
    throw "Artifact map component '$sourceName' packageMode must be one of: $($allowedPackageModes -join ', ')."
  }
  Assert-Equal ([string]$source.version) (Assert-RequiredString $component "expectedVersion" "Artifact map component '$sourceName'") "Artifact map component '$sourceName' expectedVersion must match SourceLockPath."
  $rationale = Assert-RequiredString $component "rationale" "Artifact map component '$sourceName'"

  $requiredArtifactPaths = @(Get-OptionalStringArray $component "requiredArtifactPaths")
  $artifactPatterns = @(Get-OptionalStringArray $component "artifactPathPatterns")
  $carrierArtifactPaths = @(Get-OptionalStringArray $component "carrierArtifactPaths")
  $nonShippingReason = if (Test-HasProperty $component "nonShippingReason") { [string]$component.nonShippingReason } else { "" }
  $packagedArtifacts = @()
  $carrierArtifacts = @()

  if ($packageMode -eq "packaged-runtime") {
    Assert-True (($requiredArtifactPaths.Count + $artifactPatterns.Count) -gt 0) "Artifact map component '$sourceName' packaged-runtime must define requiredArtifactPaths or artifactPathPatterns."
    foreach ($requiredPath in $requiredArtifactPaths) {
      $artifact = Get-ArtifactRecord -ArtifactByPath $artifactByPath -Path $requiredPath -Context "Artifact map component '$sourceName'"
      Assert-Equal "nativeDependency" ([string]$artifact.role) "Artifact map component '$sourceName' required artifact must be a nativeDependency."
      $packagedArtifacts += $artifact
    }
    foreach ($pattern in $artifactPatterns) {
      Assert-NormalizedPackagePattern -Pattern $pattern -Context "Artifact map component '$sourceName' artifactPathPatterns"
      $wildcard = [System.Management.Automation.WildcardPattern]::new($pattern, [System.Management.Automation.WildcardOptions]::None)
      $matches = @($artifacts | Where-Object { [string]$_.role -eq "nativeDependency" -and $wildcard.IsMatch([string]$_.path) })
      Assert-True ($matches.Count -gt 0) "Artifact map component '$sourceName' artifactPathPatterns '$pattern' did not match any nativeDependency artifact."
      $packagedArtifacts += $matches
    }
    $dedup = @{}
    foreach ($artifact in $packagedArtifacts) {
      $dedup[[string]$artifact.path] = $artifact
      $coveredNativeArtifactPaths.Add([string]$artifact.path) | Out-Null
    }
    $packagedArtifacts = @($dedup.Keys | Sort-Object | ForEach-Object { $dedup[$_] })
  }
  elseif ($packageMode -eq "static-link-input") {
    Assert-True (-not [string]::IsNullOrWhiteSpace($nonShippingReason)) "Artifact map component '$sourceName' static-link-input must define nonShippingReason."
    Assert-True ($requiredArtifactPaths.Count -eq 0 -and $artifactPatterns.Count -eq 0) "Artifact map component '$sourceName' static-link-input must not define standalone packaged artifacts."
    Assert-True ($carrierArtifactPaths.Count -gt 0) "Artifact map component '$sourceName' static-link-input must define carrierArtifactPaths."
    foreach ($carrierPath in $carrierArtifactPaths) {
      $artifact = Get-ArtifactRecord -ArtifactByPath $artifactByPath -Path $carrierPath -Context "Artifact map component '$sourceName'"
      $carrierArtifacts += $artifact
      if ([string]$artifact.role -eq "nativeDependency") {
        $coveredNativeArtifactPaths.Add([string]$artifact.path) | Out-Null
      }
    }
  }
  elseif ($packageMode -eq "fixture-runtime") {
    Assert-True (-not [string]::IsNullOrWhiteSpace($nonShippingReason)) "Artifact map component '$sourceName' fixture-runtime must define nonShippingReason."
    Assert-True ($requiredArtifactPaths.Count -eq 0 -and $artifactPatterns.Count -eq 0 -and $carrierArtifactPaths.Count -eq 0) "Artifact map component '$sourceName' fixture-runtime must not define packaged artifact paths."
  }

  $componentReports += [pscustomobject]@{
    sourceName = $sourceName
    version = [string]$source.version
    license = [string]$source.license
    sourceDigest = ConvertTo-SourceDigest $source
    packageMode = $packageMode
    nonShippingReason = $nonShippingReason
    rationale = $rationale
    packagedArtifacts = @($packagedArtifacts | ForEach-Object { ConvertTo-ArtifactReport $_ })
    carrierArtifacts = @($carrierArtifacts | ForEach-Object { ConvertTo-ArtifactReport $_ })
  }
}

$nativeDependencyArtifacts = @($artifacts | Where-Object { [string]$_.role -eq "nativeDependency" })
$firstPartyArtifacts = @($artifacts | Where-Object { [string]$_.role -eq "sidecar" -or [string]$_.role -eq "bridge" })
$unmappedNativeDependencyArtifacts = @($nativeDependencyArtifacts |
  Where-Object { -not $coveredNativeArtifactPaths.Contains([string]$_.path) } |
  ForEach-Object { [string]$_.path } |
  Sort-Object)
if ($unmappedNativeDependencyArtifacts.Count -gt 0) {
  throw "ArtifactMapPath has unmapped nativeDependency artifacts: $($unmappedNativeDependencyArtifacts -join ', ')"
}

$report = [pscustomobject]@{
  schemaVersion = 1
  schema = "subversionr.release.native-artifact-map-preflight.win32-x64.v1"
  publicReadinessClaim = $false
  reproducibleBuildClaim = $false
  signedAttestationClaim = $false
  localPreflightOnly = $true
  target = $Target
  traceIds = @("SEC-015", "MIG-012", "TST-024")
  generatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
  evidenceBoundary = $evidenceBoundary
  packageModes = $allowedPackageModes
  packageRoot = [pscustomobject]@{
    path = Get-RepoRelativePath $packageRootResolved
  }
  inputs = [pscustomobject]@{
    sourceLock = [pscustomobject]@{ path = Get-RepoRelativePath $sourceLockResolved; sha256 = Get-Sha256 $sourceLockResolved }
    artifactMap = [pscustomobject]@{ path = Get-RepoRelativePath $artifactMapResolved; sha256 = Get-Sha256 $artifactMapResolved }
    backendManifest = [pscustomobject]@{ path = Get-RepoRelativePath $backendManifestResolved; sha256 = Get-Sha256 $backendManifestResolved; artifactCount = $artifacts.Count }
    vsixEvidence = [pscustomobject]@{ path = Get-RepoRelativePath $vsixEvidenceResolved; sha256 = Get-Sha256 $vsixEvidenceResolved }
  }
  coverage = [pscustomobject]@{
    sourceLockComponentCount = $sources.Count
    mappedComponentCount = $componentReports.Count
    manifestArtifactCount = $artifacts.Count
    nativeDependencyArtifactCount = $nativeDependencyArtifacts.Count
    mappedNativeDependencyArtifactCount = $coveredNativeArtifactPaths.Count
    firstPartyArtifactCount = $firstPartyArtifacts.Count
    unmappedSourceComponents = @()
    extraMappedComponents = @()
    unmappedNativeDependencyArtifacts = @()
  }
  firstPartyArtifacts = @($firstPartyArtifacts | ForEach-Object { ConvertTo-ArtifactReport $_ })
  componentMappings = $componentReports
  nonClaims = $requiredNonClaims
  assertions = @(
    "every native source-lock component has exactly one explicit artifact-map entry",
    "every nativeDependency artifact in the backend manifest is covered by an explicit packaged-runtime or static-link carrier mapping",
    "staged package artifact sizes and SHA256 values match the backend manifest",
    "VSIX package evidence remains publicReadinessClaim false",
    "reproducible builds, source-to-binary compilation proof, signing, attestation publication, and post-gate integrity remain explicit non-claims"
  )
}

$outputParent = Split-Path -Parent $outputResolved
New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $outputResolved -Encoding utf8

Write-Host "Generated SubversionR native artifact map preflight for $Target at $outputResolved."

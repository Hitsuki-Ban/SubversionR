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
$allowedEvidenceRoots = @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-native-artifact-map-scripts"))
)
$allowedPackageModes = @("packaged-runtime", "static-link-input", "fixture-runtime")
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

function Assert-RequiredBooleanFalse([object]$Object, [string]$Name, [string]$Context) {
  if (-not (Test-HasProperty $Object $Name)) {
    throw "$Context must define $Name."
  }
  Assert-Equal "False" ([string]$Object.$Name) "$Context $Name must remain false."
}

function Assert-RequiredBooleanTrue([object]$Object, [string]$Name, [string]$Context) {
  if (-not (Test-HasProperty $Object $Name)) {
    throw "$Context must define $Name."
  }
  Assert-Equal "True" ([string]$Object.$Name) "$Context $Name must be true."
}

function Assert-NormalizedPackagePath([string]$Path, [string]$Context) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "$Context must not be empty."
  }
  if ([System.IO.Path]::IsPathRooted($Path) -or $Path.Contains("\") -or $Path.Contains("../") -or $Path.Contains("/../") -or $Path -eq "." -or $Path.StartsWith("./") -or $Path.Contains("*")) {
    throw "$Context must be an exact normalized package path: $Path"
  }
  foreach ($segment in $Path.Split("/")) {
    if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq "." -or $segment -eq "..") {
      throw "$Context must be an exact normalized package path: $Path"
    }
  }
  if (-not $Path.StartsWith("resources/backend/$Target/", [System.StringComparison]::Ordinal)) {
    throw "$Context must stay inside resources/backend/$Target`: $Path"
  }
}

function Assert-HashRecord([object]$Record, [string]$Context) {
  $path = Assert-RequiredString $Record "path" $Context
  $sha256 = Assert-RequiredString $Record "sha256" $Context
  $resolved = Assert-File $path $Context
  Assert-Equal $sha256 (Get-Sha256 $resolved) "$Context sha256 should match current bytes."
  $resolved
}

function Assert-ArtifactRecords([object[]]$Artifacts, [string]$PackageRoot, [string]$Context) {
  foreach ($artifact in $Artifacts) {
    $path = Assert-RequiredString $artifact "path" "$Context artifact"
    Assert-NormalizedPackagePath -Path $path -Context "$Context artifact path"
    Assert-RequiredString $artifact "role" "$Context artifact '$path'" | Out-Null
    $sha256 = Assert-RequiredString $artifact "sha256" "$Context artifact '$path'"
    $artifactPath = Join-Path $PackageRoot $path.Replace("/", [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
      throw "$Context artifact must exist under packageRoot: $path"
    }
    $item = Get-Item -LiteralPath $artifactPath
    Assert-Equal ([int64]$artifact.size) ([int64]$item.Length) "$Context artifact '$path' size should match current bytes."
    Assert-Equal $sha256 (Get-Sha256 $artifactPath) "$Context artifact '$path' sha256 should match current bytes."
  }
}

function Assert-NoCredentialEvidenceText([string]$Text) {
  $patterns = @(
    'ghp_[A-Za-z0-9_]{20,}',
    'github_pat_[A-Za-z0-9_]+',
    '://[^/\s:@"]+:[^/\s:@"]+@',
    '(?i)Authorization:\s*Bearer\s+',
    '(?i)"token(Value)?"\s*:',
    '(?i)"credential"\s*:',
    '(?i)"password"\s*:',
    '(?i)"secret"\s*:'
  )
  foreach ($pattern in $patterns) {
    if ($Text -match $pattern) {
      throw "Native artifact map evidence must not record credentials, tokens, authorization headers, passwords, or secrets."
    }
  }
}

$evidenceResolved = Assert-GeneratedPath -Path $EvidencePath -Name "EvidencePath" -AllowedRoots $allowedEvidenceRoots -Description "target/release-evidence or target/tests/release-native-artifact-map-scripts"
$rawEvidence = Get-Content -Raw -LiteralPath $evidenceResolved
Assert-NoCredentialEvidenceText $rawEvidence
$report = $rawEvidence | ConvertFrom-Json

Assert-Equal 1 ([int]$report.schemaVersion) "Native artifact map preflight schemaVersion should be stable."
Assert-Equal "subversionr.release.native-artifact-map-preflight.win32-x64.v1" ([string]$report.schema) "Native artifact map preflight schema should match the M7 source-lock artifact map contract."
Assert-Equal $Target ([string]$report.target) "Native artifact map preflight target should match the requested target."
Assert-RequiredBooleanFalse $report "publicReadinessClaim" "Native artifact map preflight"
Assert-RequiredBooleanFalse $report "reproducibleBuildClaim" "Native artifact map preflight"
Assert-RequiredBooleanFalse $report "signedAttestationClaim" "Native artifact map preflight"
Assert-RequiredBooleanTrue $report "localPreflightOnly" "Native artifact map preflight"

$boundary = Assert-RequiredString $report "evidenceBoundary" "Native artifact map preflight"
Assert-True ($boundary.Contains("does not attest reproducibility")) "Native artifact map preflight evidenceBoundary must reject reproducible-build claims."
Assert-True ($boundary.Contains("post-gate integrity")) "Native artifact map preflight evidenceBoundary must reject post-gate integrity claims."
foreach ($mode in $allowedPackageModes) {
  Assert-True (@($report.packageModes | Where-Object { [string]$_ -eq $mode }).Count -eq 1) "Native artifact map preflight packageModes must include '$mode'."
}
foreach ($nonClaim in $requiredNonClaims) {
  Assert-True (@($report.nonClaims | Where-Object { [string]$_ -eq $nonClaim }).Count -eq 1) "Native artifact map preflight nonClaims must include '$nonClaim'."
}

$inputs = if (Test-HasProperty $report "inputs") { $report.inputs } else { throw "Native artifact map preflight must define inputs." }
$sourceLockResolved = Assert-HashRecord $inputs.sourceLock "Source lock input"
$artifactMapResolved = Assert-HashRecord $inputs.artifactMap "Artifact map input"
$backendManifestResolved = Assert-HashRecord $inputs.backendManifest "Backend manifest input"
$vsixEvidenceResolved = Assert-HashRecord $inputs.vsixEvidence "VSIX package evidence input"

$packageRootRecord = if (Test-HasProperty $report "packageRoot") { $report.packageRoot } else { throw "Native artifact map preflight must define packageRoot." }
$packageRoot = Assert-RequiredString $packageRootRecord "path" "Native artifact map preflight packageRoot"
$packageRootResolved = Assert-Directory $packageRoot "Native artifact map preflight packageRoot"
Assert-True (Test-IsPathWithin -Path $backendManifestResolved -Root $packageRootResolved) "Backend manifest input must stay inside the recorded packageRoot."

$sourceLock = Get-Content -Raw -LiteralPath $sourceLockResolved | ConvertFrom-Json
$artifactMap = Get-Content -Raw -LiteralPath $artifactMapResolved | ConvertFrom-Json
$backendManifest = Get-Content -Raw -LiteralPath $backendManifestResolved | ConvertFrom-Json
$vsixEvidence = Get-Content -Raw -LiteralPath $vsixEvidenceResolved | ConvertFrom-Json

Assert-Equal 1 ([int]$artifactMap.schemaVersion) "Artifact map input schemaVersion should be stable."
Assert-Equal "subversionr.release.native-artifact-map.win32-x64.v1" ([string]$artifactMap.schema) "Artifact map input schema should match."
Assert-Equal $Target ([string]$artifactMap.target) "Artifact map input target should match."
Assert-Equal 1 ([int]$backendManifest.schemaVersion) "Backend manifest schemaVersion should be stable."
Assert-Equal "subversionr.vscode.backend-package.win32-x64.v1" ([string]$backendManifest.schema) "Backend manifest schema should match."
Assert-Equal $Target ([string]$backendManifest.target) "Backend manifest target should match."
Assert-Equal 1 ([int]$vsixEvidence.schemaVersion) "VSIX package evidence schemaVersion should be stable."
Assert-Equal "subversionr.release.vsix-package.win32-x64.v1" ([string]$vsixEvidence.schema) "VSIX package evidence schema should match."
Assert-Equal $Target ([string]$vsixEvidence.target) "VSIX package evidence target should match."
Assert-RequiredBooleanFalse $vsixEvidence "publicReadinessClaim" "VSIX package evidence"

$sourceCount = @($sourceLock.sources).Count
$mapCount = @($artifactMap.components).Count
$artifactCount = @($backendManifest.artifacts).Count
$nativeArtifactCount = @($backendManifest.artifacts | Where-Object { [string]$_.role -eq "nativeDependency" }).Count
$firstPartyArtifactCount = @($backendManifest.artifacts | Where-Object { [string]$_.role -eq "sidecar" -or [string]$_.role -eq "bridge" }).Count

Assert-Equal $sourceCount ([int]$report.coverage.sourceLockComponentCount) "Coverage sourceLockComponentCount should match current SourceLockPath."
Assert-Equal $mapCount ([int]$report.coverage.mappedComponentCount) "Coverage mappedComponentCount should match current ArtifactMapPath."
Assert-Equal $artifactCount ([int]$report.coverage.manifestArtifactCount) "Coverage manifestArtifactCount should match current backend manifest."
Assert-Equal $nativeArtifactCount ([int]$report.coverage.nativeDependencyArtifactCount) "Coverage nativeDependencyArtifactCount should match current backend manifest."
Assert-Equal $firstPartyArtifactCount ([int]$report.coverage.firstPartyArtifactCount) "Coverage firstPartyArtifactCount should match current backend manifest."
Assert-Equal 0 (@($report.coverage.unmappedSourceComponents).Count) "Coverage must not contain unmapped source-lock components."
Assert-Equal 0 (@($report.coverage.extraMappedComponents).Count) "Coverage must not contain extra mapped components."
Assert-Equal 0 (@($report.coverage.unmappedNativeDependencyArtifacts).Count) "Coverage must not contain unmapped native dependency artifacts."

$componentMappings = @($report.componentMappings)
Assert-Equal $sourceCount $componentMappings.Count "Native artifact map preflight should report one component mapping for each source-lock component."
$seenComponents = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($component in $componentMappings) {
  $sourceName = Assert-RequiredString $component "sourceName" "Component mapping"
  Assert-True ($seenComponents.Add($sourceName)) "Component mapping '$sourceName' is duplicated."
  $packageMode = Assert-RequiredString $component "packageMode" "Component mapping '$sourceName'"
  if ($allowedPackageModes -notcontains $packageMode) {
    throw "Component mapping '$sourceName' packageMode must be one of: $($allowedPackageModes -join ', ')."
  }
  Assert-RequiredString $component "version" "Component mapping '$sourceName'" | Out-Null
  Assert-RequiredString $component "license" "Component mapping '$sourceName'" | Out-Null
  Assert-RequiredString $component "rationale" "Component mapping '$sourceName'" | Out-Null
  if ($packageMode -eq "packaged-runtime") {
    Assert-True (@($component.packagedArtifacts).Count -gt 0) "Component mapping '$sourceName' packaged-runtime should include packagedArtifacts."
  }
  elseif ($packageMode -eq "static-link-input") {
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$component.nonShippingReason)) "Component mapping '$sourceName' static-link-input should include nonShippingReason."
    Assert-True (@($component.carrierArtifacts).Count -gt 0) "Component mapping '$sourceName' static-link-input should include carrierArtifacts."
  }
  elseif ($packageMode -eq "fixture-runtime") {
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$component.nonShippingReason)) "Component mapping '$sourceName' fixture-runtime should include nonShippingReason."
    Assert-Equal 0 (@($component.packagedArtifacts).Count) "Component mapping '$sourceName' fixture-runtime should not include packagedArtifacts."
    Assert-Equal 0 (@($component.carrierArtifacts).Count) "Component mapping '$sourceName' fixture-runtime should not include carrierArtifacts."
  }
  Assert-ArtifactRecords -Artifacts @($component.packagedArtifacts) -PackageRoot $packageRootResolved -Context "Component mapping '$sourceName' packaged"
  Assert-ArtifactRecords -Artifacts @($component.carrierArtifacts) -PackageRoot $packageRootResolved -Context "Component mapping '$sourceName' carrier"
}
Assert-ArtifactRecords -Artifacts @($report.firstPartyArtifacts) -PackageRoot $packageRootResolved -Context "First-party"

Write-Host "Verified SubversionR native artifact map preflight for $Target at $evidenceResolved."

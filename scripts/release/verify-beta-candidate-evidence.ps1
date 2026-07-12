[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$VsixPath,

  [Parameter(Mandatory = $true)]
  [string]$VsixEvidencePath,

  [Parameter(Mandatory = $true)]
  [string]$CiWorkflowPath,

  [Parameter(Mandatory = $true)]
  [string]$ReleaseEvidenceRoot,

  [Parameter(Mandatory = $true)]
  [string]$ArtifactBundleManifestPath,

  [Parameter(Mandatory = $true)]
  [string]$OutputPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.IO.Compression.FileSystem

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

function Assert-RequiredBooleanTrue([object]$Object, [string]$Name, [string]$Context) {
  if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) {
    throw "$Context must define $Name."
  }
  if ($Object.$Name -isnot [bool]) {
    throw "$Context $Name must be a JSON boolean."
  }
  Assert-Equal $true ([bool]$Object.$Name) "$Context $Name must be true."
}

function Assert-RequiredBooleanFalse([object]$Object, [string]$Name, [string]$Context) {
  if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) {
    throw "$Context must define $Name."
  }
  if ($Object.$Name -isnot [bool]) {
    throw "$Context $Name must be a JSON boolean."
  }
  Assert-Equal $false ([bool]$Object.$Name) "$Context $Name must remain false."
}

function Assert-ExplicitPath([string]$Path, [string]$Name) {
  Assert-True (-not [string]::IsNullOrWhiteSpace($Path)) "$Name is required."
  Assert-True (-not $Path.Contains("%")) "$Name must be an explicit path, not an unresolved environment placeholder."
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

function Assert-PathWithinAny([string]$Path, [string]$Name, [string[]]$AllowedRoots, [string]$Description) {
  Assert-ExplicitPath $Path $Name
  $absolute = Resolve-RepoPath $Path
  foreach ($allowedRoot in $AllowedRoots) {
    if (Test-IsPathWithin -Path $absolute -Root $allowedRoot) {
      return $absolute
    }
  }
  throw "$Name must resolve inside $Description`: $absolute"
}

function Assert-PathWithinRoot([string]$Path, [string]$Name, [string]$Root, [string]$Description) {
  Assert-ExplicitPath $Path $Name
  $absolute = Resolve-RepoPath $Path
  if (-not (Test-IsPathWithin -Path $absolute -Root $Root)) {
    throw "$Name must resolve inside $Description`: $absolute"
  }
  $absolute
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

function ConvertTo-Hex([byte[]]$Bytes) {
  -join ($Bytes | ForEach-Object { $_.ToString("x2") })
}

function Get-ZipEntrySha256([string]$ZipPath, [string]$EntryName) {
  $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
  try {
    $entry = $archive.Entries | Where-Object { $_.FullName -eq $EntryName } | Select-Object -First 1
    if ($null -eq $entry) {
      throw "VSIX must contain $EntryName."
    }
    $stream = $entry.Open()
    try {
      $sha = [System.Security.Cryptography.SHA256]::Create()
      try {
        ConvertTo-Hex ($sha.ComputeHash($stream))
      }
      finally {
        $sha.Dispose()
      }
    }
    finally {
      $stream.Dispose()
    }
  }
  finally {
    $archive.Dispose()
  }
}

function Get-ZipEntryText([string]$ZipPath, [string]$EntryName) {
  $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
  try {
    $entry = $archive.Entries | Where-Object { $_.FullName -eq $EntryName } | Select-Object -First 1
    if ($null -eq $entry) {
      throw "VSIX must contain $EntryName."
    }
    $reader = [System.IO.StreamReader]::new($entry.Open())
    try {
      $reader.ReadToEnd()
    }
    finally {
      $reader.Dispose()
    }
  }
  finally {
    $archive.Dispose()
  }
}

function Get-ZipEntryInfo([string]$ZipPath, [string]$EntryName) {
  $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
  try {
    $entry = $archive.Entries | Where-Object { $_.FullName -eq $EntryName } | Select-Object -First 1
    if ($null -eq $entry) {
      throw "VSIX must contain $EntryName."
    }
    $stream = $entry.Open()
    try {
      $sha = [System.Security.Cryptography.SHA256]::Create()
      try {
        [pscustomobject]@{
          path = $EntryName
          size = [int64]$entry.Length
          sha256 = ConvertTo-Hex ($sha.ComputeHash($stream))
        }
      }
      finally {
        $sha.Dispose()
      }
    }
    finally {
      $stream.Dispose()
    }
  }
  finally {
    $archive.Dispose()
  }
}

function Get-VsixPackageJson([string]$ZipPath) {
  Get-ZipEntryText -ZipPath $ZipPath -EntryName "extension/package.json" | ConvertFrom-Json
}

function Get-VsixTargetPlatform([string]$ZipPath) {
  $manifestText = Get-ZipEntryText -ZipPath $ZipPath -EntryName "extension.vsixmanifest"
  $manifest = [xml]$manifestText
  $identityNodes = @($manifest.SelectNodes("//*[local-name()='PackageManifest']/*[local-name()='Metadata']/*[local-name()='Identity']"))
  if ($identityNodes.Count -ne 1 -or [string]::IsNullOrWhiteSpace($identityNodes[0].TargetPlatform)) {
    throw "VSIX manifest Identity must contain TargetPlatform."
  }
  [string]$identityNodes[0].TargetPlatform
}

function Assert-VsixPreReleaseProperty([string]$ZipPath) {
  $manifestText = Get-ZipEntryText -ZipPath $ZipPath -EntryName "extension.vsixmanifest"
  $manifest = [xml]$manifestText
  $properties = @($manifest.SelectNodes("//*[local-name()='PackageManifest']/*[local-name()='Metadata']/*[local-name()='Properties']/*[local-name()='Property' and @Id='Microsoft.VisualStudio.Code.PreRelease']"))
  Assert-Equal 1 $properties.Count "VSIX manifest must contain exactly one Microsoft.VisualStudio.Code.PreRelease property."
  Assert-Equal "true" ([string]$properties[0].Value) "VSIX manifest Microsoft.VisualStudio.Code.PreRelease Value must be exactly true."
}

function Test-HasProperty([object]$Object, [string]$Name) {
  $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Get-RequiredProperty([object]$Object, [string]$Name, [string]$Context) {
  if (-not (Test-HasProperty $Object $Name) -or $null -eq $Object.$Name) {
    throw "$Context must define $Name."
  }
  $Object.$Name
}

function Get-RequiredString([object]$Object, [string]$Name, [string]$Context) {
  $value = Get-RequiredProperty $Object $Name $Context
  if ([string]::IsNullOrWhiteSpace([string]$value)) {
    throw "$Context must define $Name."
  }
  [string]$value
}

function Assert-Sha256([string]$Value, [string]$Name) {
  if ($Value -notmatch "^[0-9a-f]{64}$") {
    throw "$Name must be a lowercase SHA256 hex digest."
  }
}

function Assert-SamePath([string]$Expected, [string]$Actual, [string]$Message) {
  $expectedFull = Resolve-RepoPath $Expected
  $actualFull = Resolve-RepoPath $Actual
  if (-not $expectedFull.Equals($actualFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "$Message Expected '$expectedFull', got '$actualFull'."
  }
}

function Read-JsonFile([string]$Path, [string]$Name) {
  try {
    Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
  }
  catch {
    throw "$Name must be valid JSON: $($_.Exception.Message)"
  }
}

function Read-EvidenceFile([string]$FileName, [string]$Name, [string]$ExpectedSchema) {
  $path = Join-Path $releaseEvidenceRootResolved $FileName
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Missing required evidence file: $FileName"
  }
  $resolved = Assert-File $path $Name
  $json = Read-JsonFile -Path $resolved -Name $Name
  Assert-Equal $ExpectedSchema (Get-RequiredString $json "schema" $Name) "$Name schema must match the Beta candidate contract."
  Assert-Equal $Target (Get-RequiredString $json "target" $Name) "$Name target must match the Beta candidate target."
  Assert-Equal "False" ([string](Get-RequiredProperty $json "publicReadinessClaim" $Name)) "$Name publicReadinessClaim must remain false."
  [pscustomobject]@{
    name = $Name
    fileName = $FileName
    path = $resolved
    json = $json
    sha256 = Get-Sha256 $resolved
    schema = $ExpectedSchema
  }
}

function Add-VerifiedEvidence([object]$Evidence, [string]$BindingPolicy) {
  $script:verifiedEvidenceFiles += [pscustomobject]@{
    name = $Evidence.name
    relativePath = Get-RepoRelativePath $Evidence.path
    sha256 = $Evidence.sha256
    schema = $Evidence.schema
    bindingPolicy = $BindingPolicy
  }
}

function New-BetaArtifactBundleFileRecord([string]$Path, [string]$Role) {
  $resolved = Assert-File $Path $Role
  $item = Get-Item -LiteralPath $resolved
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

function Get-ExpectedBetaArtifactPayloadFiles {
  $files = [System.Collections.Generic.List[object]]::new()
  $files.Add((New-BetaArtifactBundleFileRecord -Path $vsixResolved -Role "vsix")) | Out-Null

  foreach ($fileName in @(
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
    )) {
    $files.Add((New-BetaArtifactBundleFileRecord -Path (Join-Path $releaseEvidenceRootResolved $fileName) -Role "release-evidence-json")) | Out-Null
  }

  $files.Add((New-BetaArtifactBundleFileRecord -Path (Join-Path $releaseEvidenceRootResolved "THIRD-PARTY-NOTICES.md") -Role "third-party-notice")) | Out-Null

  $uiArtifactRoot = Join-Path $releaseEvidenceRootResolved "installed-source-control-ui-e2e\$Target"
  $uiArtifactRoot = Assert-Directory $uiArtifactRoot "installed Source Control UI E2E artifact root"
  $uiArtifactFiles = @(Get-ChildItem -LiteralPath $uiArtifactRoot -Recurse -File |
    Where-Object { $_.Extension -in @(".json", ".png", ".txt") } |
    Sort-Object FullName)
  if ($uiArtifactFiles.Count -eq 0) {
    throw "Beta artifact bundle manifest must bind installed Source Control UI E2E renderer artifacts."
  }
  foreach ($file in $uiArtifactFiles) {
    $files.Add((New-BetaArtifactBundleFileRecord -Path $file.FullName -Role "installed-source-control-ui-e2e-artifact")) | Out-Null
  }

  @($files | Sort-Object relativePath)
}

function Assert-BetaArtifactBundleManifest([object]$Manifest, [object]$ArtifactBundle) {
  $json = $Manifest.json
  Assert-Equal "True" ([string](Get-RequiredProperty $json "localCandidateOnly" "artifactBundleManifest")) "artifactBundleManifest localCandidateOnly must remain true."

  $uploadContract = Get-RequiredProperty $json "uploadContract" "artifactBundleManifest"
  Assert-Equal $ArtifactBundle.uploadAction (Get-RequiredString $uploadContract "uploadAction" "artifactBundleManifest.uploadContract") "artifactBundleManifest upload action must match CI."
  Assert-Equal $ArtifactBundle.name (Get-RequiredString $uploadContract "name" "artifactBundleManifest.uploadContract") "artifactBundleManifest upload name must match CI."
  Assert-Equal $ArtifactBundle.ifNoFilesFound (Get-RequiredString $uploadContract "ifNoFilesFound" "artifactBundleManifest.uploadContract") "artifactBundleManifest missing-file policy must match CI."
  Assert-Equal ([string]$ArtifactBundle.retentionDays) ([string](Get-RequiredProperty $uploadContract "retentionDays" "artifactBundleManifest.uploadContract")) "artifactBundleManifest retention must match CI."
  Assert-Equal ([string]$ArtifactBundle.includeHiddenFiles) ([string](Get-RequiredProperty $uploadContract "includeHiddenFiles" "artifactBundleManifest.uploadContract")) "artifactBundleManifest hidden-file policy must match CI."

  $manifestPaths = @($uploadContract.paths | ForEach-Object { [string]$_ })
  Assert-Equal ([string]$ArtifactBundle.paths.Count) ([string]$manifestPaths.Count) "artifactBundleManifest upload path list must match CI."
  for ($index = 0; $index -lt $ArtifactBundle.paths.Count; $index++) {
    Assert-Equal ([string]$ArtifactBundle.paths[$index]) ([string]$manifestPaths[$index]) "artifactBundleManifest upload path list must match CI."
  }

  $manifestSelf = Get-RequiredProperty $json "manifestSelf" "artifactBundleManifest"
  Assert-Equal (Get-RepoRelativePath $artifactBundleManifestResolved) (Get-RequiredString $manifestSelf "relativePath" "artifactBundleManifest.manifestSelf") "artifactBundleManifest self path must match ArtifactBundleManifestPath."
  Assert-Equal "subversionr.release.beta-candidate-consistency.$Target.v1" (Get-RequiredString $manifestSelf "sha256BoundBy" "artifactBundleManifest.manifestSelf") "artifactBundleManifest self hash must be bound by the final Beta candidate consistency report."

  $expectedFiles = @(Get-ExpectedBetaArtifactPayloadFiles)
  $manifestFiles = @($json.files)
  Assert-Equal ([string]$expectedFiles.Count) ([string]$manifestFiles.Count) "artifactBundleManifest file count must match the current Beta bundle payload."
  Assert-Equal ([string]$expectedFiles.Count) ([string](Get-RequiredProperty $json "fileCount" "artifactBundleManifest")) "artifactBundleManifest fileCount must match files."

  $totalSize = [int64]0
  $seenManifestPaths = @{}
  for ($index = 0; $index -lt $expectedFiles.Count; $index++) {
    $expected = $expectedFiles[$index]
    $actual = $manifestFiles[$index]
    $actualRelativePath = Get-RequiredString $actual "relativePath" "artifactBundleManifest.files[$index]"
    if ($seenManifestPaths.ContainsKey($actualRelativePath)) {
      throw "artifactBundleManifest must not contain duplicate file path: $actualRelativePath"
    }
    $seenManifestPaths[$actualRelativePath] = $true
    Assert-Equal $expected.role (Get-RequiredString $actual "role" "artifactBundleManifest.files[$index]") "artifactBundleManifest file role must match the current Beta bundle payload."
    Assert-Equal $expected.relativePath $actualRelativePath "artifactBundleManifest file path must match the current Beta bundle payload."
    Assert-Equal ([string]$expected.size) ([string](Get-RequiredProperty $actual "size" "artifactBundleManifest.files[$index]")) "artifactBundleManifest file size must match the current Beta bundle payload."
    Assert-Equal $expected.sha256 (Get-RequiredString $actual "sha256" "artifactBundleManifest.files[$index]") "artifactBundleManifest file SHA256 must match the current Beta bundle payload."
    $totalSize += [int64]$expected.size
  }
  Assert-Equal ([string]$totalSize) ([string](Get-RequiredProperty $json "totalSize" "artifactBundleManifest")) "artifactBundleManifest totalSize must match the current Beta bundle payload."

  [pscustomobject]@{
    path = $Manifest.path
    relativePath = Get-RepoRelativePath $Manifest.path
    size = [int64](Get-Item -LiteralPath $Manifest.path).Length
    sha256 = $Manifest.sha256
    schema = $Manifest.schema
    fileCount = $expectedFiles.Count
    totalSize = $totalSize
    files = $manifestFiles
  }
}

function Assert-VsixArtifactBinding([object]$Record, [string]$Name, [bool]$RequireSize) {
  $path = Get-RequiredString $Record "path" "$Name VSIX artifact"
  $relativePath = Get-RequiredString $Record "relativePath" "$Name VSIX artifact"
  $sha256 = Get-RequiredString $Record "sha256" "$Name VSIX artifact"
  Assert-Sha256 $sha256 "$Name VSIX SHA256"
  Assert-SamePath $vsixResolved $path "$Name VSIX path must match current VSIX."
  Assert-Equal $vsixRelativePath $relativePath "$Name VSIX relativePath must match current VSIX."
  Assert-Equal $vsixSha256 $sha256 "$Name VSIX SHA256 must match current VSIX."
  if ($RequireSize) {
    Assert-Equal ([string]$vsixSize) ([string](Get-RequiredProperty $Record "size" "$Name VSIX artifact")) "$Name VSIX size must match current VSIX."
  }
}

function Assert-ExtensionIdentity([object]$Record, [string]$Name, [bool]$RequireInstalledSource) {
  $extension = Get-RequiredProperty $Record "extension" $Name
  Assert-Equal $extensionId (Get-RequiredString $extension "id" "$Name extension") "$Name extension id must match current VSIX package identity."
  Assert-Equal $extensionVersion (Get-RequiredString $extension "version" "$Name extension") "$Name extension version must match current VSIX package identity."
  if ($RequireInstalledSource) {
    Assert-Equal "installed-vsix" (Get-RequiredString $extension "source" "$Name extension") "$Name extension source must record installed-vsix."
  }
}

function Assert-InstalledExtensionLine([object]$Record, [string]$Name) {
  if (-not (Test-HasProperty $Record "installedExtensions")) {
    throw "$Name must record installedExtensions."
  }
  $installedExtensions = @($Record.installedExtensions | ForEach-Object { [string]$_ })
  $expectedInstalledLine = "$extensionId@$extensionVersion"
  Assert-True ($installedExtensions -contains $expectedInstalledLine) "$Name installedExtensions must include $expectedInstalledLine."
}

function Assert-StringArrayContains([object]$Values, [string]$Expected, [string]$Context) {
  $actualValues = @($Values | ForEach-Object { [string]$_ })
  Assert-True ($actualValues -contains $Expected) "$Context must include $Expected."
}

function Assert-StringArrayContainsLike([object]$Values, [string]$Pattern, [string]$Context) {
  $actualValues = @($Values | ForEach-Object { [string]$_ })
  Assert-True (@($actualValues | Where-Object { $_ -like $Pattern }).Count -gt 0) "$Context must include a value matching $Pattern."
}

function Assert-TrueProperty([object]$Object, [string]$Name, [string]$Context) {
  Assert-Equal "True" ([string](Get-RequiredProperty $Object $Name $Context)) "$Context $Name must be true."
}

function Get-RequiredNestedProperty([object]$Object, [string]$Path, [string]$Context) {
  $current = $Object
  $currentContext = $Context
  foreach ($segment in $Path.Split(".")) {
    $current = Get-RequiredProperty $current $segment $currentContext
    $currentContext = "$currentContext.$segment"
  }
  $current
}

function Assert-NestedEqual([object]$Object, [string]$Path, $Expected, [string]$Context, [string]$Message) {
  $actual = Get-RequiredNestedProperty $Object $Path $Context
  Assert-Equal $Expected $actual $Message
}

function Assert-NestedTrue([object]$Object, [string]$Path, [string]$Context, [string]$Message) {
  $actual = Get-RequiredNestedProperty $Object $Path $Context
  Assert-Equal "True" ([string]$actual) $Message
}

function Assert-WorkflowKind([object]$Record, [string]$Name, [string]$ExpectedKind, [string]$Context) {
  $workflow = Get-RequiredProperty $Record $Name $Context
  Assert-Equal $ExpectedKind (Get-RequiredString $workflow "kind" "$Context.$Name") "$Context $Name kind must match the installed workflow evidence contract."
  $workflow
}

function Assert-ObjectKind([object]$Record, [string]$Name, [string]$ExpectedKind, [string]$Context) {
  $value = Get-RequiredProperty $Record $Name $Context
  Assert-Equal $ExpectedKind (Get-RequiredString $value "kind" "$Context.$Name") "$Context $Name kind must match the installed oracle evidence contract."
  $value
}

function Assert-InstalledSourceControlUiE2eSemantics([object]$Record) {
  $context = "installedSourceControlUiE2e"
  foreach ($traceId in @(
    "BRM-001",
    "BRM-005",
    "OPS-010",
    "OPS-011",
    "OPS-013",
    "STA-014",
    "TST-018",
    "TST-024",
    "UX-002"
  )) {
    Assert-StringArrayContains $Record.traceIds $traceId "$context traceIds"
  }

  foreach ($nonClaimPattern in @(
    "*Marketplace publication*",
    "*VSIX signing*",
    "*previous-stable upgrade or rollback*",
    "*svnserve, HTTP, HTTPS, auth, or certificate flows*",
    "*Checkout Repository happy path*",
    "*Update to Revision prompts*",
    "*Add to Ignore*",
    "*Lock and Unlock*",
    "*changelist set/clear*",
    "*Branch/Tag create and Switch*"
  )) {
    Assert-StringArrayContainsLike $Record.nonClaims $nonClaimPattern "$context nonClaims"
  }

  $extension = Get-RequiredProperty $Record "extension" $context
  foreach ($capability in @(
    "hasCheckoutRepositoryCommand",
    "hasUpdateToRevisionCommand",
    "hasAddToIgnoreResourceCommand",
    "hasLockResourceCommand",
    "hasUnlockResourceCommand",
    "hasSetResourceChangelistCommand",
    "hasClearResourceChangelistCommand",
    "hasCommitChangelistCommand",
    "hasRevertChangelistCommand",
    "hasBranchCreateRepositoryCommand",
    "hasSwitchRepositoryCommand"
  )) {
    Assert-TrueProperty $extension $capability "$context.extension"
  }

  $checkoutCancellation = Assert-WorkflowKind $Record "sourceControlUiCheckoutCancellationWorkflow" "subversionr.installedSourceControlUiE2eCheckoutCancellationWorkflow" $context
  Assert-NestedEqual $checkoutCancellation "command.command" "subversionr.checkoutRepository" "$context.sourceControlUiCheckoutCancellationWorkflow" "$context Checkout cancellation command must be checkoutRepository."
  Assert-NestedEqual $checkoutCancellation "prompt.cancelKey" "Escape" "$context.sourceControlUiCheckoutCancellationWorkflow" "$context Checkout cancellation must prove Escape cancellation."
  Assert-NestedEqual $checkoutCancellation "prompt.rendererCaptureExpectations.cancelSurface" "quickInput" "$context.sourceControlUiCheckoutCancellationWorkflow" "$context Checkout cancellation renderer surface must be QuickInput."
  foreach ($path in @(
    "currentSurfaceProbes.targetAfter.assertions.currentSessionMissing",
    "currentSurfaceProbes.targetAfter.assertions.sourceControlProjectionAbsent",
    "assertions.commandCancelled",
    "assertions.targetAbsentAfter",
    "assertions.svnMetadataAbsentAfter",
    "assertions.repositoryNotOpenedAfterCancellation",
    "assertions.sourceControlProjectionUnchanged"
  )) {
    Assert-NestedTrue $checkoutCancellation $path "$context.sourceControlUiCheckoutCancellationWorkflow" "$context Checkout cancellation must prove $path."
  }

  $checkoutExistingTargetFailure = Assert-WorkflowKind $Record "sourceControlUiCheckoutExistingTargetFailureWorkflow" "subversionr.installedSourceControlUiE2eCheckoutExistingTargetFailureWorkflow" $context
  Assert-NestedEqual $checkoutExistingTargetFailure "command.command" "subversionr.checkoutRepository" "$context.sourceControlUiCheckoutExistingTargetFailureWorkflow" "$context Checkout existing-target failure command must be checkoutRepository."
  Assert-NestedEqual $checkoutExistingTargetFailure "failure.code" "SVN_REPOSITORY_CHECKOUT_FAILED" "$context.sourceControlUiCheckoutExistingTargetFailureWorkflow" "$context Checkout existing-target failure must record the checkout failure code."
  Assert-NestedEqual $checkoutExistingTargetFailure "notification.cleanup.command" "notifications.clearAll" "$context.sourceControlUiCheckoutExistingTargetFailureWorkflow" "$context Checkout existing-target failure must clear the error notification after capture."
  foreach ($path in @(
    "notification.cleanup.cleared",
    "currentSurfaceProbes.targetAfter.assertions.currentSessionMissing",
    "currentSurfaceProbes.targetAfter.assertions.sourceControlProjectionAbsent",
    "assertions.commandFailed",
    "assertions.obstructingTargetFilePreserved",
    "assertions.svnMetadataAbsentAfter",
    "assertions.fixtureDirectoryUnchanged",
    "assertions.repositoryNotOpenedAfterFailure",
    "assertions.sourceControlProjectionUnchanged"
  )) {
    Assert-NestedTrue $checkoutExistingTargetFailure $path "$context.sourceControlUiCheckoutExistingTargetFailureWorkflow" "$context Checkout existing-target failure must prove $path."
  }

  $checkoutInvalidUrlFailure = Assert-WorkflowKind $Record "sourceControlUiCheckoutInvalidUrlFailureWorkflow" "subversionr.installedSourceControlUiE2eCheckoutInvalidUrlFailureWorkflow" $context
  Assert-NestedEqual $checkoutInvalidUrlFailure "command.command" "subversionr.checkoutRepository" "$context.sourceControlUiCheckoutInvalidUrlFailureWorkflow" "$context Checkout invalid-URL failure command must be checkoutRepository."
  Assert-NestedEqual $checkoutInvalidUrlFailure "failure.code" "SVN_REPOSITORY_CHECKOUT_FAILED" "$context.sourceControlUiCheckoutInvalidUrlFailureWorkflow" "$context Checkout invalid-URL failure must record the checkout failure code."
  Assert-NestedEqual $checkoutInvalidUrlFailure "notification.cleanup.command" "notifications.clearAll" "$context.sourceControlUiCheckoutInvalidUrlFailureWorkflow" "$context Checkout invalid-URL failure must clear the error notification after capture."
  foreach ($path in @(
    "notification.cleanup.cleared",
    "currentSurfaceProbes.targetAfter.assertions.currentSessionMissing",
    "currentSurfaceProbes.targetAfter.assertions.sourceControlProjectionAbsent",
    "assertions.commandFailed",
    "assertions.invalidUrlRejected",
    "assertions.targetAbsentAfter",
    "assertions.svnMetadataAbsentAfter",
    "assertions.parentDirectoryUnchanged",
    "assertions.repositoryNotOpenedAfterFailure",
    "assertions.sourceControlProjectionUnchanged"
  )) {
    Assert-NestedTrue $checkoutInvalidUrlFailure $path "$context.sourceControlUiCheckoutInvalidUrlFailureWorkflow" "$context Checkout invalid-URL failure must prove $path."
  }

  Assert-WorkflowKind $Record "sourceControlUiCheckoutExistingDirectoryWorkflow" "subversionr.installedSourceControlUiE2eCheckoutExistingDirectoryWorkflow" $context | Out-Null
  Assert-WorkflowKind $Record "sourceControlUiCheckoutExistingDirectoryObstructionWorkflow" "subversionr.installedSourceControlUiE2eCheckoutExistingDirectoryObstructionWorkflow" $context | Out-Null
  Assert-WorkflowKind $Record "sourceControlUiCheckoutWorkflow" "subversionr.installedSourceControlUiE2eCheckoutWorkflow" $context | Out-Null
  $updateCancellation = Assert-WorkflowKind $Record "sourceControlUiUpdateToRevisionCancellationWorkflow" "subversionr.installedSourceControlUiE2eUpdateToRevisionCancellationWorkflow" $context
  Assert-NestedEqual $updateCancellation "command.command" "subversionr.updateToRevision" "$context.sourceControlUiUpdateToRevisionCancellationWorkflow" "$context Update to Revision cancellation command must be updateToRevision."
  Assert-NestedEqual $updateCancellation "prompt.cancelKey" "Escape" "$context.sourceControlUiUpdateToRevisionCancellationWorkflow" "$context Update to Revision cancellation must prove Escape cancellation."
  foreach ($path in @(
    "closeReport.repositoryClosed",
    "assertions.commandCancelled",
    "assertions.targetContentUnchangedAfterCancellation",
    "assertions.requestedRevisionContentNotApplied",
    "assertions.sourceControlProjectionUnchanged"
  )) {
    Assert-NestedTrue $updateCancellation $path "$context.sourceControlUiUpdateToRevisionCancellationWorkflow" "$context Update to Revision cancellation must prove $path."
  }

  Assert-WorkflowKind $Record "sourceControlUiUpdateToRevisionWorkflow" "subversionr.installedSourceControlUiE2eUpdateToRevisionWorkflow" $context | Out-Null
  Assert-WorkflowKind $Record "sourceControlUiAddToIgnoreWorkflow" "subversionr.installedSourceControlUiE2eAddToIgnoreWorkflow" $context | Out-Null
  Assert-WorkflowKind $Record "sourceControlUiLockUnlockWorkflow" "subversionr.installedSourceControlUiE2eLockUnlockWorkflow" $context | Out-Null
  $lockMessageCancellation = Assert-WorkflowKind $Record "sourceControlUiLockMessageCancellationWorkflow" "subversionr.installedSourceControlUiE2eLockMessageCancellationWorkflow" $context
  Assert-NestedEqual $lockMessageCancellation "command.command" "subversionr.lockResource" "$context.sourceControlUiLockMessageCancellationWorkflow" "$context Lock message cancellation command must be lockResource."
  Assert-NestedEqual $lockMessageCancellation "resource.path" "src/needs-lock.txt" "$context.sourceControlUiLockMessageCancellationWorkflow" "$context Lock message cancellation resource path must match the needs-lock fixture."
  Assert-NestedEqual $lockMessageCancellation "prompt.cancelKey" "Escape" "$context.sourceControlUiLockMessageCancellationWorkflow" "$context Lock message cancellation must prove Escape cancellation."
  Assert-NestedEqual $lockMessageCancellation "prompt.rendererCaptureExpectations.cancelSurface" "quickInput" "$context.sourceControlUiLockMessageCancellationWorkflow" "$context Lock message cancellation renderer surface must be QuickInput."
  Assert-NestedEqual $lockMessageCancellation "currentSurfaceReport.kind" "subversionr.installedSourceControlUiE2eCurrentSurfaceReport" "$context.sourceControlUiLockMessageCancellationWorkflow" "$context Lock message cancellation must include a current Source Control surface report."
  foreach ($path in @(
    "assertions.commandCancelled",
    "assertions.sourceControlProjectionUnchanged",
    "assertions.repositoryClosedAfterEvidence"
  )) {
    Assert-NestedTrue $lockMessageCancellation $path "$context.sourceControlUiLockMessageCancellationWorkflow" "$context Lock message cancellation must prove $path."
  }

  $unlockModeCancellation = Assert-WorkflowKind $Record "sourceControlUiUnlockModeCancellationWorkflow" "subversionr.installedSourceControlUiE2eUnlockModeCancellationWorkflow" $context
  Assert-NestedEqual $unlockModeCancellation "command.command" "subversionr.unlockResource" "$context.sourceControlUiUnlockModeCancellationWorkflow" "$context Unlock mode cancellation command must be unlockResource."
  Assert-NestedEqual $unlockModeCancellation "resource.path" "src/needs-lock.txt" "$context.sourceControlUiUnlockModeCancellationWorkflow" "$context Unlock mode cancellation resource path must match the needs-lock fixture."
  Assert-NestedEqual $unlockModeCancellation "prompt.cancelKey" "Escape" "$context.sourceControlUiUnlockModeCancellationWorkflow" "$context Unlock mode cancellation must prove Escape cancellation."
  Assert-NestedEqual $unlockModeCancellation "prompt.rendererCaptureExpectations.cancelSurface" "quickInput" "$context.sourceControlUiUnlockModeCancellationWorkflow" "$context Unlock mode cancellation renderer surface must be QuickInput."
  Assert-NestedEqual $unlockModeCancellation "currentSurfaceReport.kind" "subversionr.installedSourceControlUiE2eCurrentSurfaceReport" "$context.sourceControlUiUnlockModeCancellationWorkflow" "$context Unlock mode cancellation must include a current Source Control surface report."
  foreach ($path in @(
    "assertions.commandCancelled",
    "assertions.sourceControlProjectionUnchanged",
    "assertions.repositoryClosedAfterEvidence"
  )) {
    Assert-NestedTrue $unlockModeCancellation $path "$context.sourceControlUiUnlockModeCancellationWorkflow" "$context Unlock mode cancellation must prove $path."
  }

  Assert-WorkflowKind $Record "sourceControlUiChangelistSetClearWorkflow" "subversionr.installedSourceControlUiE2eChangelistSetClearWorkflow" $context | Out-Null
  Assert-WorkflowKind $Record "sourceControlUiCommitChangelistWorkflow" "subversionr.installedSourceControlUiE2eCommitChangelistWorkflow" $context | Out-Null
  Assert-WorkflowKind $Record "sourceControlUiRevertChangelistWorkflow" "subversionr.installedSourceControlUiE2eRevertChangelistWorkflow" $context | Out-Null
  $branchCreate = Assert-WorkflowKind $Record "sourceControlUiBranchCreateWorkflow" "subversionr.installedSourceControlUiE2eBranchCreateWorkflow" $context
  Assert-NestedEqual $branchCreate "command.command" "subversionr.branchCreateRepository" "$context.sourceControlUiBranchCreateWorkflow" "$context Branch/Tag create command must be branchCreateRepository."
  Assert-NestedEqual $branchCreate "request.revision" "head" "$context.sourceControlUiBranchCreateWorkflow" "$context Branch/Tag create revision request must be HEAD."
  foreach ($path in @(
    "closeReport.repositoryClosed",
    "assertions.commandExecuted",
    "assertions.branchCreatedInRepository",
    "assertions.noLocalReconcileClaimed"
  )) {
    Assert-NestedTrue $branchCreate $path "$context.sourceControlUiBranchCreateWorkflow" "$context Branch/Tag create must prove $path."
  }
  Assert-NestedEqual $branchCreate "request.makeParents" $false "$context.sourceControlUiBranchCreateWorkflow" "$context Branch/Tag create makeParents request must remain false."
  Assert-NestedEqual $branchCreate "request.ignoreExternals" $true "$context.sourceControlUiBranchCreateWorkflow" "$context Branch/Tag create ignoreExternals request must remain true."

  $switchWorkflow = Assert-WorkflowKind $Record "sourceControlUiSwitchWorkflow" "subversionr.installedSourceControlUiE2eSwitchWorkflow" $context
  Assert-NestedEqual $switchWorkflow "command.command" "subversionr.switchRepository" "$context.sourceControlUiSwitchWorkflow" "$context Switch command must be switchRepository."
  Assert-NestedEqual $switchWorkflow "request.revision" "head" "$context.sourceControlUiSwitchWorkflow" "$context Switch revision request must be HEAD."
  Assert-NestedEqual $switchWorkflow "request.depth" "infinity" "$context.sourceControlUiSwitchWorkflow" "$context Switch depth request must be infinity."
  Assert-NestedEqual $switchWorkflow "currentSurfaceReport.kind" "subversionr.installedSourceControlUiE2eCurrentSurfaceReport" "$context.sourceControlUiSwitchWorkflow" "$context Switch workflow must include a current Source Control surface report."
  foreach ($path in @(
    "request.depthIsSticky",
    "request.ignoreExternals",
    "currentSurfaceReport.surfaceWorkflow.repositoryOpen",
    "currentSurfaceReport.surfaceWorkflow.scmProjection",
    "currentSurfaceReport.surfaceWorkflow.sourceControlSurface",
    "closeReport.repositoryClosed",
    "assertions.postSwitchReconcileCompleted",
    "assertions.postSwitchGenerationAdvanced",
    "assertions.postSwitchRepositoryIdentityPreserved",
    "assertions.sourceControlProjectionAvailable"
  )) {
    Assert-NestedTrue $switchWorkflow $path "$context.sourceControlUiSwitchWorkflow" "$context Switch workflow must prove $path."
  }
  Assert-NestedEqual $switchWorkflow "request.ignoreAncestry" $false "$context.sourceControlUiSwitchWorkflow" "$context Switch ignoreAncestry request must remain false."

  $checkoutRepositoryOracle = Assert-ObjectKind $Record "checkoutRepositoryOracle" "subversionr.installedSourceControlUiE2eCheckoutRepositoryOracle" $context
  Assert-NestedTrue $checkoutRepositoryOracle "checkedOutBaselineContentMatched" "$context.checkoutRepositoryOracle" "$context Checkout oracle must prove checked-out content matches repository baseline."
  $checkoutObstructionOracle = Assert-ObjectKind $Record "checkoutExistingDirectoryObstructionWorkingCopyOracle" "subversionr.installedSourceControlUiE2eCheckoutExistingDirectoryObstructionWorkingCopyOracle" $context
  Assert-NestedTrue $checkoutObstructionOracle "treeConflictPresent" "$context.checkoutExistingDirectoryObstructionWorkingCopyOracle" "$context Checkout obstruction oracle must prove tree conflict presence."
  Assert-NestedTrue $checkoutObstructionOracle "obstructionPreserved" "$context.checkoutExistingDirectoryObstructionWorkingCopyOracle" "$context Checkout obstruction oracle must prove local obstruction preservation."
  $updateOracle = Assert-ObjectKind $Record "updateToRevisionRepositoryOracle" "subversionr.installedSourceControlUiE2eUpdateToRevisionRepositoryOracle" $context
  Assert-NestedTrue $updateOracle "updatedRevisionContentMatched" "$context.updateToRevisionRepositoryOracle" "$context Update to Revision oracle must prove requested revision content matched."
  $addToIgnoreOracle = Assert-ObjectKind $Record "addToIgnoreWorkingCopyOracle" "subversionr.installedSourceControlUiE2eAddToIgnoreWorkingCopyOracle" $context
  Assert-NestedEqual $addToIgnoreOracle "propertyName" "svn:ignore" "$context.addToIgnoreWorkingCopyOracle" "$context Add to Ignore oracle must read svn:ignore."
  Assert-NestedTrue $addToIgnoreOracle "ignorePatternPresent" "$context.addToIgnoreWorkingCopyOracle" "$context Add to Ignore oracle must prove the ignore pattern is present."
  Assert-NestedTrue $addToIgnoreOracle "ignoredStatusPresent" "$context.addToIgnoreWorkingCopyOracle" "$context Add to Ignore oracle must prove ignored status."
  $lockHeldOracle = Assert-ObjectKind $Record "lockHeldWorkingCopyOracle" "subversionr.installedSourceControlUiE2eLockHeldWorkingCopyOracle" $context
  Assert-NestedTrue $lockHeldOracle "svnInfoContainsLockToken" "$context.lockHeldWorkingCopyOracle" "$context Lock-held oracle must prove svn info exposes a lock token."
  Assert-NestedTrue $lockHeldOracle "svnInfoContainsLockOwner" "$context.lockHeldWorkingCopyOracle" "$context Lock-held oracle must prove svn info exposes a lock owner."
  $lockUnlockOracle = Assert-ObjectKind $Record "lockUnlockWorkingCopyOracle" "subversionr.installedSourceControlUiE2eLockUnlockWorkingCopyOracle" $context
  Assert-NestedEqual $lockUnlockOracle "needsLockProperty" "*" "$context.lockUnlockWorkingCopyOracle" "$context Lock/unlock oracle must preserve svn:needs-lock."
  Assert-NestedTrue $lockUnlockOracle "svnInfoLockTokenAbsentAfterUnlock" "$context.lockUnlockWorkingCopyOracle" "$context Lock/unlock oracle must prove lock token absence after unlock."
  $commitChangelistOracle = Assert-ObjectKind $Record "commitChangelistRepositoryOracle" "subversionr.installedSourceControlUiE2eCommitChangelistRepositoryOracle" $context
  Assert-NestedTrue $commitChangelistOracle "latestLogContainsCommitMessage" "$context.commitChangelistRepositoryOracle" "$context Commit Changelist oracle must prove the changelist commit message reached the repository."
  $branchOracle = Assert-ObjectKind $Record "branchCreateRepositoryOracle" "subversionr.installedSourceControlUiE2eBranchCreateRepositoryOracle" $context
  foreach ($path in @(
    "branchContentMatched",
    "latestLogContainsBranchMessage",
    "copyFromPathMatched",
    "copyFromRevisionMatched"
  )) {
    Assert-NestedTrue $branchOracle $path "$context.branchCreateRepositoryOracle" "$context Branch/Tag oracle must prove $path."
  }
  $switchOracle = Assert-ObjectKind $Record "switchWorkingCopyOracle" "subversionr.installedSourceControlUiE2eSwitchWorkingCopyOracle" $context
  Assert-NestedTrue $switchOracle "workingCopyUrlMatched" "$context.switchWorkingCopyOracle" "$context Switch oracle must prove working-copy URL matched the switch target."
}

function Assert-StateEngineBetaPerformanceSemantics([object]$Record) {
  foreach ($traceId in @(
    "ARC-011",
    "DIR-002",
    "DIR-004",
    "DIR-006",
    "DIR-007",
    "DIR-012",
    "DIR-013",
    "DIR-020",
    "OBS-004",
    "TST-024"
  )) {
    Assert-StringArrayContains $Record.traceIds $traceId "stateEngineBetaPerformance traceIds"
  }

  $assertions = Get-RequiredProperty $Record "assertions" "stateEngineBetaPerformance"
  $singleFile = Get-RequiredProperty $assertions "singleFileSaveNoFullScan" "stateEngineBetaPerformance.assertions"
  Assert-Equal "0" ([string](Get-RequiredProperty $singleFile "rootInfinityTargetCount" "stateEngineBetaPerformance.assertions.singleFileSaveNoFullScan")) "stateEngineBetaPerformance single-file save must not trigger a root infinity full scan target."
  Assert-Equal "1" ([string](Get-RequiredProperty $singleFile "refreshRequestCount" "stateEngineBetaPerformance.assertions.singleFileSaveNoFullScan")) "stateEngineBetaPerformance single-file save must issue one targeted refresh request."

  $eventBurst = Get-RequiredProperty $assertions "eventBurstBounded" "stateEngineBetaPerformance.assertions"
  Assert-Equal "10000" ([string](Get-RequiredProperty $eventBurst "inputEventCount" "stateEngineBetaPerformance.assertions.eventBurstBounded")) "stateEngineBetaPerformance event burst must cover the 10k event baseline."
  Assert-True ([int](Get-RequiredProperty $eventBurst "actualRefreshTargets" "stateEngineBetaPerformance.assertions.eventBurstBounded") -le [int](Get-RequiredProperty $eventBurst "maxRefreshTargets" "stateEngineBetaPerformance.assertions.eventBurstBounded")) "stateEngineBetaPerformance event burst refresh targets must stay bounded."

  $boundary = Get-RequiredProperty $assertions "nestedExternalBoundaryIsolation" "stateEngineBetaPerformance.assertions"
  Assert-Equal "False" ([string](Get-RequiredProperty $boundary "boundaryAcceptedByParent" "stateEngineBetaPerformance.assertions.nestedExternalBoundaryIsolation")) "stateEngineBetaPerformance parent provider must reject nested/external boundary events."
  Assert-Equal "True" ([string](Get-RequiredProperty $boundary "boundaryAcceptedByChild" "stateEngineBetaPerformance.assertions.nestedExternalBoundaryIsolation")) "stateEngineBetaPerformance child provider must accept its own boundary event."

  $supersede = Get-RequiredProperty $assertions "dirtyGenerationSupersede" "stateEngineBetaPerformance.assertions"
  Assert-Equal "True" ([string](Get-RequiredProperty $supersede "firstSignalAborted" "stateEngineBetaPerformance.assertions.dirtyGenerationSupersede")) "stateEngineBetaPerformance dirty-generation supersede must abort the stale in-flight refresh."
  Assert-Equal "refreshCancelled" ([string](Get-RequiredProperty $supersede "staleMarkReason" "stateEngineBetaPerformance.assertions.dirtyGenerationSupersede")) "stateEngineBetaPerformance dirty-generation supersede must mark status stale before recovery."

  $restart = Get-RequiredProperty $assertions "sidecarRestartRecovery" "stateEngineBetaPerformance.assertions"
  Assert-Equal "stale" ([string](Get-RequiredProperty $restart "statusCompleteness" "stateEngineBetaPerformance.assertions.sidecarRestartRecovery")) "stateEngineBetaPerformance backend restart must mark canonical status stale when reopening sessions."
  Assert-Equal "1" ([string](Get-RequiredProperty $restart "reopenedCount" "stateEngineBetaPerformance.assertions.sidecarRestartRecovery")) "stateEngineBetaPerformance backend restart must record an explicit reopen result."

  $projection = Get-RequiredProperty $assertions "tenThousandWorkingCopyProjection" "stateEngineBetaPerformance.assertions"
  Assert-Equal "10000" ([string](Get-RequiredProperty $projection "localEntryCount" "stateEngineBetaPerformance.assertions.tenThousandWorkingCopyProjection")) "stateEngineBetaPerformance projection evidence must use the 10k local working-copy fixture."
  Assert-True ([double](Get-RequiredProperty $projection "elapsedMs" "stateEngineBetaPerformance.assertions.tenThousandWorkingCopyProjection") -le [double](Get-RequiredProperty $projection "maxProjectionMs" "stateEngineBetaPerformance.assertions.tenThousandWorkingCopyProjection")) "stateEngineBetaPerformance 10k projection elapsed time must stay inside the configured Beta baseline."

  Assert-StringArrayContainsLike $Record.nonClaims "*100k or 1M*" "stateEngineBetaPerformance nonClaims"
  Assert-StringArrayContainsLike $Record.nonClaims "*default background remote polling*" "stateEngineBetaPerformance nonClaims"
}

function Assert-HashRecordCurrent([object]$Record, [string]$Name, [string]$ExpectedPath, [string]$ExpectedSha256) {
  $pathValue = Get-RequiredString $Record "path" $Name
  $sha256 = Get-RequiredString $Record "sha256" $Name
  Assert-Sha256 $sha256 "$Name SHA256"

  $resolvedPath = Assert-File (Resolve-RepoPath $pathValue) "$Name path"
  Assert-True (Test-IsPathWithin -Path $resolvedPath -Root $repoRoot) "$Name path must resolve inside the repository: $resolvedPath"
  if (-not [string]::IsNullOrWhiteSpace($ExpectedPath)) {
    Assert-SamePath $ExpectedPath $resolvedPath "$Name path must match the expected evidence file."
  }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
    Assert-Equal $ExpectedSha256 $sha256 "$Name SHA256 must match the expected evidence SHA256."
  }

  $actualSha256 = Get-Sha256 $resolvedPath
  Assert-Equal $actualSha256 $sha256 "$Name SHA256 must match current file."

  [pscustomobject]@{
    name = $Name
    relativePath = Get-RepoRelativePath $resolvedPath
    sha256 = $sha256
  }
}

function ConvertTo-ArtifactKey([object]$Artifact) {
  Get-RequiredString $Artifact "path" "Backend manifest artifact"
}

function Assert-ArtifactRecordMatchesCurrentVsix([object]$Artifact, [hashtable]$ManifestArtifacts, [string]$Context) {
  $path = Get-RequiredString $Artifact "path" $Context
  $role = Get-RequiredString $Artifact "role" $Context
  $size = [int64](Get-RequiredProperty $Artifact "size" $Context)
  $sha256 = Get-RequiredString $Artifact "sha256" $Context
  Assert-Sha256 $sha256 "$Context SHA256"

  if (-not $ManifestArtifacts.ContainsKey($path)) {
    throw "$Context must exist in the current backend manifest: $path"
  }
  $manifestArtifact = $ManifestArtifacts[$path]
  Assert-Equal $role (Get-RequiredString $manifestArtifact "role" "Backend manifest artifact $path") "$Context role must match current backend manifest."
  Assert-Equal ([string]$size) ([string](Get-RequiredProperty $manifestArtifact "size" "Backend manifest artifact $path")) "$Context size must match current backend manifest."
  Assert-Equal $sha256 (Get-RequiredString $manifestArtifact "sha256" "Backend manifest artifact $path") "$Context SHA256 must match current backend manifest."

  $zipEntry = Get-ZipEntryInfo -ZipPath $vsixResolved -EntryName "extension/$path"
  Assert-Equal ([string]$size) ([string]$zipEntry.size) "$Context size must match the current VSIX ZIP entry."
  Assert-Equal $sha256 $zipEntry.sha256 "$Context SHA256 must match the current VSIX ZIP entry."
}

function Get-YamlIndent([string]$Line) {
  if ($Line -match "^(\s*)") {
    return $Matches[1].Length
  }
  0
}

function Get-CiBlockEnd([string[]]$Lines, [int]$Start, [int]$ParentIndent) {
  $end = $Lines.Count
  for ($index = $Start + 1; $index -lt $Lines.Count; $index++) {
    if ([string]::IsNullOrWhiteSpace($Lines[$index])) {
      continue
    }

    $indent = Get-YamlIndent $Lines[$index]
    if ($indent -le $ParentIndent) {
      $end = $index
      break
    }
  }
  $end
}

function Find-CiLine([string[]]$Lines, [int]$Start, [int]$End, [string]$Pattern, [string]$MissingMessage) {
  for ($index = $Start; $index -lt $End; $index++) {
    if ($Lines[$index] -match $Pattern) {
      return $index
    }
  }
  throw $MissingMessage
}

function Get-CiUploadStepLines([string[]]$Lines) {
  $jobsIndex = Find-CiLine `
    -Lines $Lines `
    -Start 0 `
    -End $Lines.Count `
    -Pattern "^jobs:\s*$" `
    -MissingMessage "CI workflow must define top-level jobs."
  $jobsEnd = Get-CiBlockEnd -Lines $Lines -Start $jobsIndex -ParentIndent 0

  $windowsJobIndex = Find-CiLine `
    -Lines $Lines `
    -Start ($jobsIndex + 1) `
    -End $jobsEnd `
    -Pattern "^\s{2}windows:\s*$" `
    -MissingMessage "CI workflow must define the windows job for Beta candidate uploads."
  $windowsJobEnd = Get-CiBlockEnd -Lines $Lines -Start $windowsJobIndex -ParentIndent 2

  $stepsIndex = Find-CiLine `
    -Lines $Lines `
    -Start ($windowsJobIndex + 1) `
    -End $windowsJobEnd `
    -Pattern "^\s{4}steps:\s*$" `
    -MissingMessage "CI workflow windows job must define steps."
  $stepsEnd = Get-CiBlockEnd -Lines $Lines -Start $stepsIndex -ParentIndent 4

  $uploadStepPattern = "^\s{6}-\s+(?:name|`"name`"|'name')\s*:\s*Upload Beta candidate VSIX and evidence bundle\s*$"
  $uploadStepIndexes = @()
  for ($index = $stepsIndex + 1; $index -lt $stepsEnd; $index++) {
    if ($Lines[$index] -match $uploadStepPattern) {
      $uploadStepIndexes += $index
    }
  }
  if ($uploadStepIndexes.Count -eq 0) {
    throw "CI workflow windows job must include Upload Beta candidate VSIX and evidence bundle step."
  }
  if ($uploadStepIndexes.Count -gt 1) {
    throw "CI workflow windows job must include exactly one Upload Beta candidate VSIX and evidence bundle step."
  }
  $start = $uploadStepIndexes[0]

  $end = $stepsEnd
  for ($index = $start + 1; $index -lt $stepsEnd; $index++) {
    if ($Lines[$index] -match "^\s{6}-\s") {
      $end = $index
      break
    }
  }

  $Lines[$start..($end - 1)]
}

function ConvertFrom-CiScalarInput([string]$Value) {
  $trimmed = $Value.Trim()
  if (
    ($trimmed.Length -ge 2) -and
    (
      (($trimmed.StartsWith("'")) -and ($trimmed.EndsWith("'"))) -or
      (($trimmed.StartsWith('"')) -and ($trimmed.EndsWith('"')))
    )
  ) {
    return $trimmed.Substring(1, $trimmed.Length - 2)
  }
  $trimmed
}

function Get-CiStepChildIndent([string[]]$StepLines) {
  if ($StepLines.Count -eq 0) {
    throw "CI workflow upload step must not be empty."
  }
  (Get-YamlIndent $StepLines[0]) + 2
}

function Get-CiStepScalarField([string[]]$StepLines, [string]$Name) {
  $childIndent = Get-CiStepChildIndent $StepLines
  $escapedName = [System.Text.RegularExpressions.Regex]::Escape($Name)
  $pattern = "^\s{$childIndent}(?:$escapedName|`"$escapedName`"|'$escapedName')\s*:\s*(.+?)\s*$"
  $valueFound = $false
  $value = $null
  foreach ($line in $StepLines) {
    if ($line -match $pattern) {
      if ($valueFound) {
        throw "CI Beta candidate artifact upload step must not repeat $Name."
      }
      $valueFound = $true
      $value = ConvertFrom-CiScalarInput $Matches[1]
    }
  }
  if (-not $valueFound) {
    throw "CI Beta candidate artifact upload step must define $Name."
  }
  $value
}

function Assert-CiUploadStepKeySet([string[]]$StepLines) {
  $childIndent = Get-CiStepChildIndent $StepLines
  $allowedKeys = @(
    "name",
    "uses",
    "with"
  )
  $seenKeys = @{
    name = $true
  }
  foreach ($line in $StepLines) {
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }
    $indent = Get-YamlIndent $line
    if ($indent -ne $childIndent) {
      continue
    }

    $pattern = "^\s{$childIndent}(?:([A-Za-z0-9_-]+)|`"([A-Za-z0-9_-]+)`"|'([A-Za-z0-9_-]+)')\s*:(?:\s|$)"
    if ($line -notmatch $pattern) {
      throw "CI Beta candidate artifact upload step keys must be bare or simple quoted keys."
    }

    $key = $Matches[1]
    if ([string]::IsNullOrEmpty($key)) {
      $key = $Matches[2]
    }
    if ([string]::IsNullOrEmpty($key)) {
      $key = $Matches[3]
    }
    Assert-True ($allowedKeys -contains $key) "CI Beta candidate artifact upload step must not define unsupported step key $key."
    if ($seenKeys.ContainsKey($key)) {
      throw "CI Beta candidate artifact upload step must not repeat $key."
    }
    $seenKeys[$key] = $true
  }
}

function Get-CiUploadWithInputs([string[]]$StepLines) {
  $childIndent = Get-CiStepChildIndent $StepLines
  $inputIndent = $childIndent + 2
  $withIndex = -1
  $withPattern = "^\s{$childIndent}(?:with|`"with`"|'with')\s*:\s*$"
  for ($index = 0; $index -lt $StepLines.Count; $index++) {
    if ($StepLines[$index] -match $withPattern) {
      if ($withIndex -ge 0) {
        throw "CI Beta candidate artifact upload step must not repeat with."
      }
      $withIndex = $index
    }
  }
  if ($withIndex -lt 0) {
    throw "CI Beta candidate artifact upload must define a with: input block."
  }

  $inputs = [ordered]@{}
  $index = $withIndex + 1
  while ($index -lt $StepLines.Count) {
    $line = $StepLines[$index]
    if ([string]::IsNullOrWhiteSpace($line)) {
      $index++
      continue
    }

    $indent = Get-YamlIndent $line
    if ($indent -le $childIndent) {
      break
    }

    $inputPattern = "^\s{$inputIndent}(?:([A-Za-z0-9_-]+)|`"([A-Za-z0-9_-]+)`"|'([A-Za-z0-9_-]+)')\s*:\s*(.*?)\s*$"
    if ($line -notmatch $inputPattern) {
      throw "CI Beta candidate artifact upload with: inputs must be scalar keys or the multiline path list."
    }

    $key = $Matches[1]
    if ([string]::IsNullOrEmpty($key)) {
      $key = $Matches[2]
    }
    if ([string]::IsNullOrEmpty($key)) {
      $key = $Matches[3]
    }
    $value = $Matches[4]
    if ($inputs.Contains($key)) {
      throw "CI Beta candidate artifact upload with: inputs must not repeat $key."
    }

    if ($value.Trim() -eq "|") {
      $blockValues = @()
      $index++
      while ($index -lt $StepLines.Count) {
        $blockLine = $StepLines[$index]
        if ([string]::IsNullOrWhiteSpace($blockLine)) {
          $index++
          continue
        }

        $blockIndent = Get-YamlIndent $blockLine
        if ($blockIndent -le $inputIndent) {
          break
        }

        $blockValues += $blockLine.Trim()
        $index++
      }
      if ($blockValues.Count -eq 0) {
        throw "CI Beta candidate artifact upload path list must not be empty."
      }
      $inputs[$key] = @($blockValues)
      continue
    }

    $inputs[$key] = ConvertFrom-CiScalarInput $value
    $index++
  }

  $inputs
}

function Assert-CiUploadInputSet([System.Collections.IDictionary]$Inputs) {
  $allowedInputs = @(
    "name",
    "path",
    "if-no-files-found",
    "retention-days",
    "include-hidden-files"
  )
  foreach ($key in $Inputs.Keys) {
    Assert-True ($allowedInputs -contains $key) "CI Beta candidate artifact upload must not define unsupported with: input $key."
  }
}

function Get-RequiredCiUploadInput([System.Collections.IDictionary]$Inputs, [string]$Name) {
  if (-not $Inputs.Contains($Name)) {
    throw "CI Beta candidate artifact upload must define $Name in with:."
  }
  $Inputs[$Name]
}

function Assert-CiUploadInputEquals([System.Collections.IDictionary]$Inputs, [string]$Name, [string]$Expected, [string]$Message) {
  $actual = Get-RequiredCiUploadInput -Inputs $Inputs -Name $Name
  Assert-Equal $Expected ([string]$actual) $Message
}

function Assert-CiArtifactUploadContract([string]$Path) {
  $ciWorkflowResolved = Assert-PathWithinAny `
    -Path $Path `
    -Name "CiWorkflowPath" `
    -AllowedRoots @($ciWorkflowRoot, $testReleaseEvidenceRoot) `
    -Description ".github/workflows or target/tests/release-beta-candidate-evidence-scripts"
  $ciWorkflowResolved = Assert-File $ciWorkflowResolved "CiWorkflowPath"
  $lines = @(Get-Content -LiteralPath $ciWorkflowResolved)
  $stepLines = @(Get-CiUploadStepLines -Lines $lines)
  $uploadInputs = Get-CiUploadWithInputs -StepLines $stepLines

  Assert-CiUploadStepKeySet -StepLines $stepLines
  Assert-Equal "actions/upload-artifact@v7" (Get-CiStepScalarField -StepLines $stepLines -Name "uses") "CI Beta candidate artifact upload must use actions/upload-artifact@v7."
  Assert-CiUploadInputSet -Inputs $uploadInputs
  Assert-CiUploadInputEquals -Inputs $uploadInputs -Name "name" -Expected "subversionr-win32-x64-beta-candidate" -Message "CI Beta candidate artifact upload name must be subversionr-win32-x64-beta-candidate."
  Assert-CiUploadInputEquals -Inputs $uploadInputs -Name "if-no-files-found" -Expected "error" -Message "CI Beta candidate artifact upload must fail when files are missing."
  Assert-CiUploadInputEquals -Inputs $uploadInputs -Name "retention-days" -Expected "14" -Message "CI Beta candidate artifact retention-days must be 14."
  if ($uploadInputs.Contains("include-hidden-files")) {
    Assert-Equal "false" ([string]$uploadInputs["include-hidden-files"]) "CI Beta candidate artifact upload must not include hidden files."
  }

  $pathsInput = Get-RequiredCiUploadInput -Inputs $uploadInputs -Name "path"
  Assert-True ($pathsInput -is [System.Array]) "CI Beta candidate artifact upload must define a multiline path list."
  $paths = @($pathsInput)
  Assert-Equal ([string]$script:expectedArtifactBundlePaths.Count) ([string]$paths.Count) "CI Beta candidate artifact upload path list must match the exact ordered Beta-G bundle contract."
  for ($index = 0; $index -lt $script:expectedArtifactBundlePaths.Count; $index++) {
    $expectedPath = $script:expectedArtifactBundlePaths[$index]
    $actualPath = $paths[$index]
    Assert-Equal $expectedPath $actualPath "CI Beta candidate artifact upload path list must match the exact ordered Beta-G bundle contract."
  }

  [pscustomobject]@{
    uploadAction = "actions/upload-artifact@v7"
    name = "subversionr-win32-x64-beta-candidate"
    paths = $paths
    ifNoFilesFound = "error"
    retentionDays = 14
    includeHiddenFiles = $false
    ciWorkflow = [pscustomobject]@{
      path = Get-RepoRelativePath $ciWorkflowResolved
      sha256 = Get-Sha256 $ciWorkflowResolved
    }
  }
}

$targetReleaseEvidenceRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence"))
$testReleaseEvidenceRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-beta-candidate-evidence-scripts"))
$targetVsixRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\vsix"))
$ciWorkflowRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot ".github\workflows"))

$script:expectedArtifactBundlePaths = @(Get-ExpectedUploadPaths -Target $Target)

$releaseEvidenceRootResolved = Assert-PathWithinAny `
  -Path $ReleaseEvidenceRoot `
  -Name "ReleaseEvidenceRoot" `
  -AllowedRoots @($targetReleaseEvidenceRoot, $testReleaseEvidenceRoot) `
  -Description "target/release-evidence or target/tests/release-beta-candidate-evidence-scripts"
$releaseEvidenceRootResolved = Assert-Directory $releaseEvidenceRootResolved "ReleaseEvidenceRoot"

$vsixResolved = Assert-PathWithinAny `
  -Path $VsixPath `
  -Name "VsixPath" `
  -AllowedRoots @($targetVsixRoot, $testReleaseEvidenceRoot) `
  -Description "target/vsix or target/tests/release-beta-candidate-evidence-scripts"
$vsixResolved = Assert-File $vsixResolved "VsixPath"

$vsixEvidenceResolved = Assert-PathWithinRoot `
  -Path $VsixEvidencePath `
  -Name "VsixEvidencePath" `
  -Root $releaseEvidenceRootResolved `
  -Description "ReleaseEvidenceRoot"
$vsixEvidenceResolved = Assert-File $vsixEvidenceResolved "VsixEvidencePath"

$artifactBundleManifestResolved = Assert-PathWithinRoot `
  -Path $ArtifactBundleManifestPath `
  -Name "ArtifactBundleManifestPath" `
  -Root $releaseEvidenceRootResolved `
  -Description "ReleaseEvidenceRoot"
$artifactBundleManifestResolved = Assert-File $artifactBundleManifestResolved "ArtifactBundleManifestPath"

$outputResolved = Assert-PathWithinRoot `
  -Path $OutputPath `
  -Name "OutputPath" `
  -Root $releaseEvidenceRootResolved `
  -Description "ReleaseEvidenceRoot"

$expectedVsixEvidencePath = Join-Path $releaseEvidenceRootResolved "subversionr-vsix-package-$Target.json"
Assert-SamePath $expectedVsixEvidencePath $vsixEvidenceResolved "VsixEvidencePath must be the target VSIX package evidence file."
$expectedArtifactBundleManifestPath = Join-Path $releaseEvidenceRootResolved "subversionr-beta-artifact-bundle-manifest-$Target.json"
Assert-SamePath $expectedArtifactBundleManifestPath $artifactBundleManifestResolved "ArtifactBundleManifestPath must be the target Beta artifact bundle manifest file."

$vsixItem = Get-Item -LiteralPath $vsixResolved
$vsixRelativePath = Get-RepoRelativePath $vsixResolved
$vsixSize = [int64]$vsixItem.Length
$vsixSha256 = Get-Sha256 $vsixResolved
$vsixEntrypointSha256 = Get-ZipEntrySha256 -ZipPath $vsixResolved -EntryName "extension/dist/extension.js"
$vsixPackageJson = Get-VsixPackageJson $vsixResolved
$vsixManifestTargetPlatform = Get-VsixTargetPlatform $vsixResolved
Assert-VsixPreReleaseProperty $vsixResolved
$extensionId = "$([string](Get-RequiredProperty $vsixPackageJson "publisher" "VSIX package.json")).$([string](Get-RequiredProperty $vsixPackageJson "name" "VSIX package.json"))"
$extensionVersion = [string](Get-RequiredProperty $vsixPackageJson "version" "VSIX package.json")
Assert-Equal $Target $vsixManifestTargetPlatform "VSIX manifest TargetPlatform must match the Beta candidate target."

$script:verifiedEvidenceFiles = @()
$script:hashBindings = @()

$artifactBundle = Assert-CiArtifactUploadContract -Path $CiWorkflowPath
$script:hashBindings += [pscustomobject]@{
  name = "ciWorkflow"
  relativePath = $artifactBundle.ciWorkflow.path
  sha256 = $artifactBundle.ciWorkflow.sha256
}

$vsixPackage = Read-EvidenceFile `
  -FileName "subversionr-vsix-package-$Target.json" `
  -Name "vsixPackage" `
  -ExpectedSchema "subversionr.release.vsix-package.$Target.v1"
$vsixPackageJson = $vsixPackage.json
Assert-SamePath $vsixEvidenceResolved $vsixPackage.path "VSIX package evidence path must match VsixEvidencePath."
Assert-VsixArtifactBinding (Get-RequiredProperty $vsixPackageJson "vsix" "vsixPackage") "vsixPackage" $true
Assert-Equal $vsixEntrypointSha256 (Get-RequiredString $vsixPackageJson.vsix "extensionEntrypointSha256" "vsixPackage.vsix") "vsixPackage VSIX entrypoint SHA256 must match current VSIX."
Assert-Equal $vsixEntrypointSha256 (Get-RequiredString $vsixPackageJson.inputs "extensionEntrypointSha256" "vsixPackage.inputs") "vsixPackage input entrypoint SHA256 must match current VSIX."
Assert-Equal $extensionId (Get-RequiredString $vsixPackageJson.extension "id" "vsixPackage.extension") "vsixPackage extension id must match current VSIX package.json."
Assert-Equal $extensionVersion (Get-RequiredString $vsixPackageJson.extension "version" "vsixPackage.extension") "vsixPackage extension version must match current VSIX package.json."
Assert-RequiredBooleanTrue $vsixPackageJson.extension "preRelease" "vsixPackage.extension"
$vsixPackageRootPath = Assert-Directory (Resolve-RepoPath (Get-RequiredString $vsixPackageJson.inputs "packageRoot" "vsixPackage.inputs")) "vsixPackage input packageRoot"
$vsixPackageBackendManifestPath = Assert-File (Join-Path $vsixPackageRootPath "resources\backend\$Target\subversionr-backend-package-manifest.json") "vsixPackage input backend manifest"
$vsixPackageBackendManifestSha256 = Get-Sha256 $vsixPackageBackendManifestPath
Add-VerifiedEvidence $vsixPackage "current-vsix-bytes-and-entrypoint"

$vsixCliInstall = Read-EvidenceFile `
  -FileName "subversionr-vsix-cli-install-$Target.json" `
  -Name "vsixCliInstall" `
  -ExpectedSchema "subversionr.release.vsix-cli-install.$Target.v1"
Assert-ExtensionIdentity $vsixCliInstall.json "vsixCliInstall" $false
Assert-InstalledExtensionLine $vsixCliInstall.json "vsixCliInstall"
Assert-VsixArtifactBinding (Get-RequiredProperty $vsixCliInstall.json "vsix" "vsixCliInstall") "vsixCliInstall" $true
Assert-Equal $Target (Get-RequiredString $vsixCliInstall.json.vsix "targetPlatform" "vsixCliInstall.vsix") "vsixCliInstall VSIX targetPlatform must match current target."
Assert-Equal $vsixEntrypointSha256 (Get-RequiredString $vsixCliInstall.json.hashes "vsixEntrypointSha256" "vsixCliInstall.hashes") "vsixCliInstall VSIX entrypoint SHA256 must match current VSIX."
Assert-Equal $vsixEntrypointSha256 (Get-RequiredString $vsixCliInstall.json.hashes "installedEntrypointSha256" "vsixCliInstall.hashes") "vsixCliInstall installed entrypoint SHA256 must match current VSIX."
Add-VerifiedEvidence $vsixCliInstall "cli-installed-vsix-sha256-and-entrypoint-match-current-vsix"

$installedEvidenceSpecs = @(
  @{ FileName = "subversionr-installed-extension-host-$Target.json"; Name = "installedExtensionHost"; Schema = "subversionr.release.installed-extension-host.$Target.v1" },
  @{ FileName = "subversionr-installed-core-workflow-$Target.json"; Name = "installedCoreWorkflow"; Schema = "subversionr.release.installed-core-workflow.$Target.v2" },
  @{ FileName = "subversionr-installed-source-control-surface-$Target.json"; Name = "installedSourceControlSurface"; Schema = "subversionr.release.installed-source-control-surface.$Target.v1" },
  @{ FileName = "subversionr-installed-source-control-ui-e2e-$Target.json"; Name = "installedSourceControlUiE2e"; Schema = "subversionr.release.installed-source-control-ui-e2e.$Target.v1" }
)

foreach ($spec in $installedEvidenceSpecs) {
  $installedEvidence = Read-EvidenceFile `
    -FileName $spec.FileName `
    -Name $spec.Name `
    -ExpectedSchema $spec.Schema
  Assert-VsixArtifactBinding (Get-RequiredProperty $installedEvidence.json "vsix" $spec.Name) $spec.Name $false
  Assert-Equal $Target (Get-RequiredString $installedEvidence.json.vsix "targetPlatform" "$($spec.Name).vsix") "$($spec.Name) VSIX targetPlatform must match current target."
  Assert-ExtensionIdentity $installedEvidence.json $spec.Name $true
  Assert-InstalledExtensionLine $installedEvidence.json $spec.Name
  if ($spec.Name -eq "installedSourceControlUiE2e") {
    Assert-InstalledSourceControlUiE2eSemantics $installedEvidence.json
    Add-VerifiedEvidence $installedEvidence "installed-source-control-ui-e2e-beta-workflows-and-vsix-hash-bound"
  }
  else {
    Add-VerifiedEvidence $installedEvidence "installed-vsix-sha256-matches-current-vsix"
  }
}

$installRollbackFixture = Read-EvidenceFile `
  -FileName "subversionr-install-rollback-fixture-$Target.json" `
  -Name "installRollbackFixture" `
  -ExpectedSchema "subversionr.release.install-rollback-fixture.$Target.v1"
$installRollbackExtension = Get-RequiredProperty $installRollbackFixture.json "extension" "installRollbackFixture"
Assert-Equal $extensionId (Get-RequiredString $installRollbackExtension "id" "installRollbackFixture.extension") "installRollbackFixture extension id must match current VSIX package identity."
Assert-Equal $extensionVersion (Get-RequiredString $installRollbackExtension "currentVersion" "installRollbackFixture.extension") "installRollbackFixture currentVersion must match current VSIX package identity."
$rollbackCurrentPackage = Get-RequiredProperty (Get-RequiredProperty $installRollbackFixture.json "packages" "installRollbackFixture") "current" "installRollbackFixture.packages"
Assert-SamePath $vsixPackageRootPath (Get-RequiredString $rollbackCurrentPackage "root" "installRollbackFixture.packages.current") "installRollbackFixture current package root must match VSIX package input packageRoot."
Assert-Equal $vsixPackageBackendManifestSha256 (Get-RequiredString $rollbackCurrentPackage "manifestSha256" "installRollbackFixture.packages.current") "installRollbackFixture current package manifest SHA256 must match current VSIX package backend manifest."
Assert-Equal "staged-package-layout" (Get-RequiredString $rollbackCurrentPackage "source" "installRollbackFixture.packages.current") "installRollbackFixture current package source must remain staged-package-layout."
$rollbackSentinel = Get-RequiredProperty $installRollbackFixture.json "workingCopySentinel" "installRollbackFixture"
Assert-Equal "none" (Get-RequiredString $rollbackSentinel "mutation" "installRollbackFixture.workingCopySentinel") "installRollbackFixture working-copy sentinel mutation must remain none."
Assert-Equal (Get-RequiredString $rollbackSentinel "beforeSha256" "installRollbackFixture.workingCopySentinel") (Get-RequiredString $rollbackSentinel "afterSha256" "installRollbackFixture.workingCopySentinel") "installRollbackFixture working-copy sentinel hash must remain unchanged."
$rollbackPhases = @($installRollbackFixture.json.phases)
Assert-True ($rollbackPhases.Count -gt 0) "installRollbackFixture must record install, upgrade, or rollback phases."
foreach ($phase in $rollbackPhases) {
  if (Test-HasProperty $phase "workingCopyMutation") {
    Assert-Equal "none" ([string]$phase.workingCopyMutation) "installRollbackFixture phase workingCopyMutation must remain none."
  }
}
Add-VerifiedEvidence $installRollbackFixture "install-upgrade-rollback-fixture-non-mutation-and-current-version"

$nativeArtifactMap = Read-EvidenceFile `
  -FileName "subversionr-native-artifact-map-preflight-$Target.json" `
  -Name "nativeArtifactMap" `
  -ExpectedSchema "subversionr.release.native-artifact-map-preflight.$Target.v1"
$nativeInputs = Get-RequiredProperty $nativeArtifactMap.json "inputs" "nativeArtifactMap"
$backendManifestBinding = $null
foreach ($inputName in @("sourceLock", "artifactMap", "backendManifest")) {
  $binding = Assert-HashRecordCurrent `
    -Record (Get-RequiredProperty $nativeInputs $inputName "nativeArtifactMap.inputs") `
    -Name "nativeArtifactMap input $inputName" `
    -ExpectedPath "" `
    -ExpectedSha256 ""
  $script:hashBindings += $binding
  if ($inputName -eq "backendManifest") {
    $backendManifestBinding = $binding
  }
}
$script:hashBindings += Assert-HashRecordCurrent `
  -Record (Get-RequiredProperty $nativeInputs "vsixEvidence" "nativeArtifactMap.inputs") `
  -Name "nativeArtifactMap input vsixEvidence" `
  -ExpectedPath $vsixEvidenceResolved `
  -ExpectedSha256 $vsixPackage.sha256
$backendManifest = Read-JsonFile -Path (Resolve-RepoPath $backendManifestBinding.relativePath) -Name "nativeArtifactMap backendManifest"
Assert-Equal $Target (Get-RequiredString $backendManifest "target" "nativeArtifactMap backendManifest") "nativeArtifactMap backendManifest target must match."
$backendArtifacts = @($backendManifest.artifacts)
Assert-Equal ([string]$backendArtifacts.Count) ([string](Get-RequiredProperty $nativeInputs.backendManifest "artifactCount" "nativeArtifactMap.inputs.backendManifest")) "nativeArtifactMap backendManifest artifactCount must match current backend manifest."
$backendArtifactByPath = @{}
foreach ($artifact in $backendArtifacts) {
  $backendArtifactByPath[(ConvertTo-ArtifactKey $artifact)] = $artifact
}
foreach ($artifact in @($nativeArtifactMap.json.firstPartyArtifacts)) {
  Assert-ArtifactRecordMatchesCurrentVsix -Artifact $artifact -ManifestArtifacts $backendArtifactByPath -Context "nativeArtifactMap first-party artifact"
}
foreach ($component in @($nativeArtifactMap.json.componentMappings)) {
  foreach ($artifact in @($component.packagedArtifacts)) {
    Assert-ArtifactRecordMatchesCurrentVsix -Artifact $artifact -ManifestArtifacts $backendArtifactByPath -Context "nativeArtifactMap packaged artifact"
  }
  foreach ($artifact in @($component.carrierArtifacts)) {
    Assert-ArtifactRecordMatchesCurrentVsix -Artifact $artifact -ManifestArtifacts $backendArtifactByPath -Context "nativeArtifactMap carrier artifact"
  }
}
Add-VerifiedEvidence $nativeArtifactMap "native-input-hashes-current-and-vsix-evidence-hash-bound"

$marketplaceProvenance = Read-EvidenceFile `
  -FileName "subversionr-marketplace-provenance-preflight-$Target.json" `
  -Name "marketplaceProvenance" `
  -ExpectedSchema "subversionr.release.marketplace-provenance-preflight.$Target.v1"
$provenanceVsix = Get-RequiredProperty (Get-RequiredProperty $marketplaceProvenance.json "artifacts" "marketplaceProvenance") "vsix" "marketplaceProvenance.artifacts"
Assert-VsixArtifactBinding $provenanceVsix "marketplaceProvenance" $true
Assert-Equal $vsixPackage.sha256 (Get-RequiredString $provenanceVsix "evidenceSha256" "marketplaceProvenance.artifacts.vsix") "marketplaceProvenance VSIX evidence SHA256 must match current VSIX package evidence."
Assert-SamePath $vsixEvidenceResolved (Get-RequiredString $provenanceVsix "evidencePath" "marketplaceProvenance.artifacts.vsix") "marketplaceProvenance VSIX evidence path must match VsixEvidencePath."
$provenanceEvidence = Get-RequiredProperty $marketplaceProvenance.json "evidence" "marketplaceProvenance"
$script:hashBindings += Assert-HashRecordCurrent (Get-RequiredProperty $provenanceEvidence "candidateAttestationContract" "marketplaceProvenance.evidence") "marketplaceProvenance candidateAttestationContract" $null $null
$script:hashBindings += Assert-HashRecordCurrent (Get-RequiredProperty $provenanceEvidence "liveAttestation" "marketplaceProvenance.evidence") "marketplaceProvenance liveAttestation" $null $null
$script:hashBindings += Assert-HashRecordCurrent (Get-RequiredProperty $provenanceEvidence "attestationBundle" "marketplaceProvenance.evidence") "marketplaceProvenance attestationBundle" $null $null
$script:hashBindings += Assert-HashRecordCurrent (Get-RequiredProperty $provenanceEvidence "attestationVerification" "marketplaceProvenance.evidence") "marketplaceProvenance attestationVerification" $null $null
$provenanceAttestation = Get-RequiredProperty $marketplaceProvenance.json "attestation" "marketplaceProvenance"
Assert-Equal "verified" (Get-RequiredString $provenanceAttestation "status" "marketplaceProvenance.attestation") "marketplaceProvenance attestation status must record live verification."
Assert-Equal "historical-public-cutover-release" (Get-RequiredString $provenanceAttestation "scope" "marketplaceProvenance.attestation") "marketplaceProvenance verified attestation must remain scoped to the historical public-cutover release."
$candidateAttestation = Get-RequiredProperty $marketplaceProvenance.json "candidateAttestation" "marketplaceProvenance"
Assert-Equal "pending-release-attestation" (Get-RequiredString $candidateAttestation "status" "marketplaceProvenance.candidateAttestation") "marketplaceProvenance current candidate attestation must remain pending before release."
Assert-Equal "current-candidate" (Get-RequiredString $candidateAttestation "scope" "marketplaceProvenance.candidateAttestation") "marketplaceProvenance candidate attestation scope must identify the current candidate."
Assert-Equal $vsixSha256 (Get-RequiredString $candidateAttestation "subjectSha256" "marketplaceProvenance.candidateAttestation") "marketplaceProvenance candidate attestation SHA256 must match current VSIX."
Assert-Equal (Split-Path -Leaf $vsixResolved) (Get-RequiredString $candidateAttestation "subjectName" "marketplaceProvenance.candidateAttestation") "marketplaceProvenance candidate attestation subject name must match current VSIX."
Assert-Equal ([string]$vsixSize) ([string](Get-RequiredProperty $candidateAttestation "subjectSize" "marketplaceProvenance.candidateAttestation")) "marketplaceProvenance candidate attestation size must match current VSIX."
Assert-RequiredBooleanTrue $candidateAttestation "preReleaseProperty" "marketplaceProvenance.candidateAttestation"
Assert-RequiredBooleanFalse $candidateAttestation "liveEvidenceRecorded" "marketplaceProvenance.candidateAttestation"
Assert-Equal "v0.2.3-beta.1" (Get-RequiredString $candidateAttestation "releaseTag" "marketplaceProvenance.candidateAttestation") "marketplaceProvenance candidate release tag must match."
$candidateContractEvidence = Get-RequiredProperty $provenanceEvidence "candidateAttestationContract" "marketplaceProvenance.evidence"
Assert-Equal (Get-RequiredString $candidateContractEvidence "path" "marketplaceProvenance.evidence.candidateAttestationContract") (Get-RequiredString $candidateAttestation "contractPath" "marketplaceProvenance.candidateAttestation") "marketplaceProvenance candidate contract path must match hash-bound evidence."
Assert-Equal (Get-RequiredString $candidateContractEvidence "sha256" "marketplaceProvenance.evidence.candidateAttestationContract") (Get-RequiredString $candidateAttestation "contractSha256" "marketplaceProvenance.candidateAttestation") "marketplaceProvenance candidate contract SHA256 must match hash-bound evidence."
$attestationReadiness = Get-RequiredProperty $provenanceAttestation "readiness" "marketplaceProvenance.attestation"
Assert-Equal "live-attestation-verified" (Get-RequiredString $attestationReadiness "readinessStatus" "marketplaceProvenance.attestation.readiness") "marketplaceProvenance attestation readiness must record live verification."
Assert-Equal "actions/attest@v4" (Get-RequiredString $attestationReadiness "action" "marketplaceProvenance.attestation.readiness") "marketplaceProvenance attestation action must match the live workflow contract."
Assert-Equal "a1948c3f048ba23858d222213b7c278aabede763" (Get-RequiredString $attestationReadiness "actionDigest" "marketplaceProvenance.attestation.readiness") "marketplaceProvenance attestation action digest must remain pinned."
Assert-Equal "post-release-asset-digest-verification" (Get-RequiredString $attestationReadiness "predicateClaim" "marketplaceProvenance.attestation.readiness") "marketplaceProvenance attestation signed predicate claim must match."
Assert-RequiredBooleanFalse $attestationReadiness "originalBuildProvenanceClaim" "marketplaceProvenance.attestation.readiness"
Assert-RequiredBooleanFalse $attestationReadiness "artifactSignatureClaim" "marketplaceProvenance.attestation.readiness"
Assert-Equal ".github/workflows/attest-release-vsix.yml" (Get-RequiredString $attestationReadiness "workflowPath" "marketplaceProvenance.attestation.readiness") "marketplaceProvenance attestation workflow path must match the live workflow contract."
$historicalAttestationSubjectName = Get-RequiredString $attestationReadiness "subjectName" "marketplaceProvenance.attestation.readiness"
$historicalAttestationSubjectSha256 = Get-RequiredString $attestationReadiness "subjectSha256" "marketplaceProvenance.attestation.readiness"
Assert-Equal "subversionr-win32-x64-0.2.0.vsix" $historicalAttestationSubjectName "marketplaceProvenance historical attestation subject name must remain the public-cutover VSIX."
Assert-Sha256 $historicalAttestationSubjectSha256 "marketplaceProvenance historical attestation subject SHA256"
Assert-True ([int64](Get-RequiredProperty $attestationReadiness "artifactSize" "marketplaceProvenance.attestation.readiness") -gt 0) "marketplaceProvenance historical attestation artifact size must be positive."
Assert-RequiredBooleanTrue $attestationReadiness "repoUrlRecorded" "marketplaceProvenance.attestation.readiness"
Assert-RequiredBooleanTrue $attestationReadiness "bundleRecorded" "marketplaceProvenance.attestation.readiness"
Assert-RequiredBooleanTrue $attestationReadiness "attestationUrlRecorded" "marketplaceProvenance.attestation.readiness"
Assert-RequiredBooleanTrue $attestationReadiness "verified" "marketplaceProvenance.attestation.readiness"
$attestationRunUrl = Get-RequiredString $attestationReadiness "runUrl" "marketplaceProvenance.attestation.readiness"
Assert-True ($attestationRunUrl -match '^https://github\.com/Hitsuki-Ban/SubversionR/actions/runs/[0-9]+$') "marketplaceProvenance attestation runUrl must identify a public repository Actions run."
$attestationUrl = Get-RequiredString $attestationReadiness "attestationUrl" "marketplaceProvenance.attestation.readiness"
Assert-True ($attestationUrl -match '^https://github\.com/Hitsuki-Ban/SubversionR/attestations/[0-9]+$') "marketplaceProvenance attestationUrl must identify a public repository attestation."
Assert-True ((Get-RequiredString $attestationReadiness "bundleSha256" "marketplaceProvenance.attestation.readiness") -match '^[a-f0-9]{64}$') "marketplaceProvenance attestation bundleSha256 must be recorded."
Assert-True ((Get-RequiredString $attestationReadiness "evidenceSha256" "marketplaceProvenance.attestation.readiness") -match '^[a-f0-9]{64}$') "marketplaceProvenance live attestation evidenceSha256 must be recorded."
Assert-Equal (Get-RequiredString (Get-RequiredProperty $provenanceEvidence "attestationBundle" "marketplaceProvenance.evidence") "path" "marketplaceProvenance.evidence.attestationBundle") (Get-RequiredString $attestationReadiness "bundlePath" "marketplaceProvenance.attestation.readiness") "marketplaceProvenance attestation bundlePath must match the hash-bound bundle evidence."
Assert-Equal (Get-RequiredString (Get-RequiredProperty $provenanceEvidence "attestationVerification" "marketplaceProvenance.evidence") "path" "marketplaceProvenance.evidence.attestationVerification") (Get-RequiredString $attestationReadiness "verificationResultPath" "marketplaceProvenance.attestation.readiness") "marketplaceProvenance verificationResultPath must match the hash-bound verification evidence."
Assert-Equal (Get-RequiredString (Get-RequiredProperty $provenanceEvidence "attestationVerification" "marketplaceProvenance.evidence") "sha256" "marketplaceProvenance.evidence.attestationVerification") (Get-RequiredString $attestationReadiness "verificationResultSha256" "marketplaceProvenance.attestation.readiness") "marketplaceProvenance verificationResultSha256 must match the hash-bound verification evidence."
Add-VerifiedEvidence $marketplaceProvenance "current-candidate-vsix-and-pending-contract-plus-historical-live-attestation-hash-bound"

$publicationGaps = Read-EvidenceFile `
  -FileName "subversionr-publication-gaps-$Target.json" `
  -Name "publicationGaps" `
  -ExpectedSchema "subversionr.release.publication-gaps.$Target.v1"
Assert-VsixArtifactBinding (Get-RequiredProperty (Get-RequiredProperty $publicationGaps.json "artifacts" "publicationGaps") "vsix" "publicationGaps.artifacts") "publicationGaps" $true
$publicationCandidate = Get-RequiredProperty $publicationGaps.json "currentCandidate" "publicationGaps"
foreach ($field in @("status", "scope", "releaseTag", "releaseUrl", "subjectName", "subjectSha256", "subjectSize", "preReleaseProperty", "liveEvidenceRecorded", "contractPath", "contractSha256")) {
  Assert-Equal ([string]$candidateAttestation.$field) ([string]$publicationCandidate.$field) "publicationGaps current candidate $field must match provenance."
}
$publicationEvidence = Get-RequiredProperty $publicationGaps.json "evidence" "publicationGaps"
$script:hashBindings += Assert-HashRecordCurrent `
  -Record (Get-RequiredProperty $publicationEvidence "vsixPackage" "publicationGaps.evidence") `
  -Name "publicationGaps evidence vsixPackage" `
  -ExpectedPath $vsixEvidenceResolved `
  -ExpectedSha256 $vsixPackage.sha256
$script:hashBindings += Assert-HashRecordCurrent `
  -Record (Get-RequiredProperty $publicationEvidence "provenancePreflight" "publicationGaps.evidence") `
  -Name "publicationGaps evidence provenancePreflight" `
  -ExpectedPath $marketplaceProvenance.path `
  -ExpectedSha256 $marketplaceProvenance.sha256
$publicationRelease = Get-RequiredProperty (Get-RequiredProperty $publicationGaps.json "publicCutover" "publicationGaps") "release" "publicationGaps.publicCutover"
Assert-RequiredBooleanTrue $publicationRelease "artifactAttestationPublished" "publicationGaps.publicCutover.release"
Assert-Equal $attestationRunUrl (Get-RequiredString $publicationRelease "attestationRunUrl" "publicationGaps.publicCutover.release") "publicationGaps attestationRunUrl must match provenance live attestation evidence."
Assert-Equal $attestationUrl (Get-RequiredString $publicationRelease "attestationUrl" "publicationGaps.publicCutover.release") "publicationGaps attestationUrl must match provenance live attestation evidence."
Assert-Equal (Get-RequiredString $attestationReadiness "evidencePath" "marketplaceProvenance.attestation.readiness") (Get-RequiredString $publicationRelease "attestationEvidencePath" "publicationGaps.publicCutover.release") "publicationGaps attestationEvidencePath must match provenance live attestation evidence."
Assert-Equal (Get-RequiredString $attestationReadiness "evidenceSha256" "marketplaceProvenance.attestation.readiness") (Get-RequiredString $publicationRelease "attestationEvidenceSha256" "publicationGaps.publicCutover.release") "publicationGaps attestationEvidenceSha256 must match provenance live attestation evidence."
Add-VerifiedEvidence $publicationGaps "current-candidate-vsix-provenance-contract-and-historical-cutover-attestation-separated"

$stateEngineBetaPerformance = Read-EvidenceFile `
  -FileName "subversionr-state-engine-beta-performance-$Target.json" `
  -Name "stateEngineBetaPerformance" `
  -ExpectedSchema "subversionr.release.state-engine-beta-performance.$Target.v1"
Assert-Equal "packages/vscode-extension/tests/stateEngineBetaPerformanceGate.test.ts" (Get-RequiredString $stateEngineBetaPerformance.json "source" "stateEngineBetaPerformance") "stateEngineBetaPerformance source must bind to the Beta performance TS gate."
Assert-Equal "none" (Get-RequiredString $stateEngineBetaPerformance.json "workingCopyMutation" "stateEngineBetaPerformance") "stateEngineBetaPerformance must not mutate a real working copy."
Assert-Equal "10000" ([string](Get-RequiredProperty $stateEngineBetaPerformance.json.thresholds "tenThousandLocalResourceCount" "stateEngineBetaPerformance.thresholds")) "stateEngineBetaPerformance must record the 10k local baseline."
Assert-StateEngineBetaPerformanceSemantics $stateEngineBetaPerformance.json
Add-VerifiedEvidence $stateEngineBetaPerformance "state-engine-beta-floor-scenario-assertions-and-non-mutation"

$artifactBundleManifest = Read-EvidenceFile `
  -FileName "subversionr-beta-artifact-bundle-manifest-$Target.json" `
  -Name "artifactBundleManifest" `
  -ExpectedSchema "subversionr.release.beta-artifact-bundle-manifest.$Target.v1"
Assert-SamePath $artifactBundleManifestResolved $artifactBundleManifest.path "ArtifactBundleManifestPath must match the required Beta artifact bundle manifest."
$artifactBundleManifestRecord = Assert-BetaArtifactBundleManifest `
  -Manifest $artifactBundleManifest `
  -ArtifactBundle $artifactBundle
Add-VerifiedEvidence $artifactBundleManifest "artifact-bundle-manifest-payload-hashes-and-upload-contract"
$script:hashBindings += [pscustomobject]@{
  name = "artifactBundleManifest"
  relativePath = $artifactBundleManifestRecord.relativePath
  sha256 = $artifactBundleManifestRecord.sha256
  bindingPolicy = "manifest-self-sha256-bound-by-beta-candidate-consistency-report"
}
$artifactBundle | Add-Member -NotePropertyName manifest -NotePropertyValue $artifactBundleManifestRecord

foreach ($evidence in $script:verifiedEvidenceFiles) {
  if ((Resolve-RepoPath $evidence.relativePath).Equals($outputResolved, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputPath must not overwrite required input evidence: $($evidence.relativePath)"
  }
}

$report = [pscustomobject]@{
  schemaVersion = 1
  schema = "subversionr.release.beta-candidate-consistency.$Target.v1"
  publicReadinessClaim = $false
  localCandidateOnly = $true
  target = $Target
  traceIds = @("SEC-015", "MIG-009", "MIG-012", "TST-024")
  generatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
  vsix = [pscustomobject]@{
    path = $vsixResolved
    relativePath = $vsixRelativePath
    size = $vsixSize
    sha256 = $vsixSha256
    extensionEntrypointSha256 = $vsixEntrypointSha256
    preRelease = $true
  }
  inputs = [pscustomobject]@{
    releaseEvidenceRoot = Get-RepoRelativePath $releaseEvidenceRootResolved
    vsixEvidence = [pscustomobject]@{
      path = Get-RepoRelativePath $vsixEvidenceResolved
      sha256 = $vsixPackage.sha256
      schema = $vsixPackage.schema
    }
  }
  requiredEvidenceFiles = $script:verifiedEvidenceFiles
  hashBindings = $script:hashBindings
  artifactBundle = $artifactBundle
  assertions = @(
    "current VSIX bytes match VSIX package evidence by path, size, SHA256, and entrypoint SHA256",
    "VS Code CLI install evidence records the current VSIX path, size, SHA256, target platform, and installed entrypoint hash",
    "installed VSIX evidence that records VSIX SHA256 matches the current VSIX bytes",
    "install, upgrade, and rollback fixture evidence records the current extension version and no working-copy mutation",
    "native artifact map, provenance, and publication gaps are bound to the current VSIX package evidence by SHA256",
    "provenance and publication gaps bind the pending current-candidate attestation contract while preserving historical public-cutover attestation evidence separately",
    "installed Source Control UI E2E evidence includes the Beta checkout, update, ignore, lock, changelist, branch, and switch workflow assertions",
    "state-engine Beta performance evidence includes the single-file, event burst, boundary, dirty-generation, restart, and 10k projection scenario assertions",
    "artifact bundle manifest binds the current VSIX, SBOM, NOTICE, release evidence, installed UI artifacts, and CI upload contract",
    "all required Beta candidate evidence files keep publicReadinessClaim false",
    "CI artifact upload action, name, path list, missing-file behavior, hidden-file policy, and retention match the Beta candidate bundle contract"
  )
  nonClaims = @(
    "This gate does not prove Marketplace/public install.",
    "This gate does not claim that the current-candidate release or live GitHub attestation exists.",
    "This gate does not prove VSIX signing.",
    "This gate does not prove previous-stable upgrade or rollback.",
    "This gate does not prove remote/auth/certificate SVN workflows.",
    "This gate does not prove coverage-guided fuzzing or public release readiness."
  )
}

$outputParent = Split-Path -Parent $outputResolved
New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $outputResolved -Encoding utf8

Write-Host "Verified SubversionR Beta candidate evidence consistency for $Target at $outputResolved."

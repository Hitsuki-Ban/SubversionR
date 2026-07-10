[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$SourceLockPath,

  [Parameter(Mandatory = $true)]
  [string]$ExtensionPackagePath,

  [Parameter(Mandatory = $true)]
  [string]$CargoWorkspacePath,

  [Parameter(Mandatory = $true)]
  [string]$CargoLockPath,

  [Parameter(Mandatory = $true)]
  [string]$PnpmLockPath,

  [Parameter(Mandatory = $true)]
  [string]$NativeBridgeCMakePath,

  [Parameter(Mandatory = $true)]
  [string]$SbomPath,

  [Parameter(Mandatory = $true)]
  [string]$NoticePath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-File([string]$Path, [string]$Name) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Name must be a file: $Path"
  }
  (Resolve-Path -LiteralPath $Path).Path
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

function Get-RequiredProperty([object]$Object, [string]$Name, [string]$Context) {
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
    throw "$Context must define $Name."
  }
  [string]$property.Value
}

function Get-OptionalProperty([object]$Object, [string]$Name) {
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
    return $null
  }
  [string]$property.Value
}

function Get-CargoWorkspaceField([string]$Path, [string]$Name) {
  $content = Get-Content -Raw -LiteralPath $Path
  $pattern = "(?m)^\s*$([regex]::Escape($Name))\s*=\s*""(?<value>[^""]+)"""
  $match = [regex]::Match($content, $pattern)
  if (-not $match.Success) {
    throw "Cargo workspace metadata must define $Name."
  }
  $match.Groups["value"].Value
}

function Get-CargoWorkspaceMembers([string]$Path) {
  $content = Get-Content -Raw -LiteralPath $Path
  $match = [regex]::Match($content, '(?ms)^\s*members\s*=\s*\[(?<members>.*?)\]')
  if (-not $match.Success) {
    throw "Cargo workspace metadata must define members."
  }

  $members = @([regex]::Matches($match.Groups["members"].Value, '"(?<member>[^"]+)"') | ForEach-Object { $_.Groups["member"].Value })
  if ($members.Count -eq 0) {
    throw "Cargo workspace metadata must define at least one member."
  }
  $members
}

function Get-TomlPackageName([string]$Path) {
  $content = Get-Content -Raw -LiteralPath $Path
  $match = [regex]::Match($content, '(?ms)^\[package\].*?^\s*name\s*=\s*"(?<name>[^"]+)"')
  if (-not $match.Success) {
    throw "Cargo manifest must define [package].name: $Path"
  }
  $match.Groups["name"].Value
}

function Get-CargoManifestDependencies([string]$Path) {
  $content = Get-Content -Raw -LiteralPath $Path
  $match = [regex]::Match($content, '(?ms)^\[dependencies\]\s*(?<body>.*?)(^\[|\z)')
  if (-not $match.Success) {
    return @()
  }

  $dependencies = @()
  foreach ($rawLine in $match.Groups["body"].Value -split "`r?`n") {
    $line = ($rawLine -replace '#.*$', '').Trim()
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }

    $simpleMatch = [regex]::Match($line, '^(?<name>[A-Za-z0-9_.-]+)\s*=\s*"(?<version>[^"]+)"')
    if ($simpleMatch.Success) {
      $dependencies += [pscustomobject]@{
        name = $simpleMatch.Groups["name"].Value
        version = $simpleMatch.Groups["version"].Value
      }
      continue
    }

    $inlineMatch = [regex]::Match($line, '^(?<name>[A-Za-z0-9_.-]+)\s*=\s*\{(?<body>.*)\}\s*$')
    if ($inlineMatch.Success) {
      $name = $inlineMatch.Groups["name"].Value
      $body = $inlineMatch.Groups["body"].Value
      if ($body -match 'path\s*=') {
        continue
      }
      $versionMatch = [regex]::Match($body, 'version\s*=\s*"(?<version>[^"]+)"')
      if (-not $versionMatch.Success) {
        throw "Cargo dependency '$name' in $Path must define a version or an explicit path."
      }
      $dependencies += [pscustomobject]@{
        name = $name
        version = $versionMatch.Groups["version"].Value
      }
      continue
    }

    throw "Unsupported Cargo dependency declaration in $Path`: $line"
  }
  $dependencies
}

function Get-NpmManifestDependencies([object]$PackageJson) {
  $dependencies = @()
  foreach ($sectionName in @("dependencies", "devDependencies")) {
    $section = $PackageJson.PSObject.Properties[$sectionName]
    if ($null -eq $section) {
      continue
    }
    foreach ($dependency in $section.Value.PSObject.Properties) {
      $dependencies += [pscustomobject]@{
        name = [string]$dependency.Name
        version = [string]$dependency.Value
        scope = "typescript-manifest-$sectionName"
      }
    }
  }
  $dependencies
}

function Get-CMakeProjectName([string]$Path) {
  $content = Get-Content -Raw -LiteralPath $Path
  $match = [regex]::Match($content, '(?m)^\s*project\((?<name>[A-Za-z0-9_.-]+)\s+LANGUAGES\s+C\)')
  if (-not $match.Success) {
    throw "Native bridge CMake project must define a C project name: $Path"
  }
  $match.Groups["name"].Value
}

function Get-CargoLockPackages([string]$Path) {
  $content = Get-Content -Raw -LiteralPath $Path
  $packages = @()
  foreach ($block in [regex]::Split($content, '(?m)^\[\[package\]\]\s*$')) {
    if ([string]::IsNullOrWhiteSpace($block) -or $block -match '^\s*#') {
      continue
    }
    $nameMatch = [regex]::Match($block, '(?m)^\s*name\s*=\s*"(?<name>[^"]+)"')
    $versionMatch = [regex]::Match($block, '(?m)^\s*version\s*=\s*"(?<version>[^"]+)"')
    if (-not $nameMatch.Success -or -not $versionMatch.Success) {
      continue
    }
    $sourceMatch = [regex]::Match($block, '(?m)^\s*source\s*=\s*"(?<source>[^"]+)"')
    if (-not $sourceMatch.Success) {
      continue
    }
    $checksumMatch = [regex]::Match($block, '(?m)^\s*checksum\s*=\s*"(?<checksum>[^"]+)"')
    if (-not $checksumMatch.Success) {
      throw "Cargo.lock registry package '$($nameMatch.Groups["name"].Value)' must include a checksum."
    }
    $packages += [pscustomobject]@{
      name = $nameMatch.Groups["name"].Value
      version = $versionMatch.Groups["version"].Value
      checksum = $checksumMatch.Groups["checksum"].Value
    }
  }
  if ($packages.Count -eq 0) {
    throw "Cargo.lock must contain registry package entries."
  }
  $packages
}

function Get-PnpmLockPackages([string]$Path) {
  $lines = Get-Content -LiteralPath $Path
  $inPackages = $false
  $current = $null
  $packages = @()

  foreach ($line in $lines) {
    if ($line -eq "packages:") {
      $inPackages = $true
      continue
    }
    if ($inPackages -and $line -match '^[A-Za-z]') {
      break
    }
    if (-not $inPackages) {
      continue
    }

    $packageMatch = [regex]::Match($line, "^  (?!\s)'?(?<key>[^']+?)'?:\s*$")
    if ($packageMatch.Success) {
      if ($null -ne $current) {
        $packages += $current
      }
      $key = $packageMatch.Groups["key"].Value
      $atIndex = $key.LastIndexOf("@", [System.StringComparison]::Ordinal)
      if ($atIndex -le 0) {
        throw "pnpm lock package key must include a name and version: $key"
      }
      $current = [pscustomobject]@{
        name = $key.Substring(0, $atIndex)
        version = $key.Substring($atIndex + 1)
        integrity = ""
      }
      continue
    }

    if ($null -ne $current) {
      $integrityMatch = [regex]::Match($line, '^\s+resolution:\s+\{integrity:\s+(?<integrity>[^}]+)\}')
      if ($integrityMatch.Success) {
        $current.integrity = $integrityMatch.Groups["integrity"].Value.Trim()
      }
    }
  }
  if ($null -ne $current) {
    $packages += $current
  }
  if ($packages.Count -eq 0) {
    throw "pnpm-lock.yaml must contain package entries."
  }
  foreach ($package in $packages) {
    if ([string]::IsNullOrWhiteSpace($package.integrity)) {
      throw "pnpm lock package '$($package.name)@$($package.version)' must include an integrity value."
    }
  }
  $packages
}

function Get-ComponentScope([object]$Component) {
  $scope = @($Component.properties | Where-Object { $_.name -eq "subversionr:componentScope" })
  if ($scope.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$scope[0].value)) {
    throw "SBOM component '$($Component.name)' must include subversionr:componentScope."
  }
  [string]$scope[0].value
}

function Get-ComponentProperty([object]$Component, [string]$Name) {
  $property = @($Component.properties | Where-Object { $_.name -eq $Name })
  if ($property.Count -ne 1) {
    throw "SBOM component '$($Component.name)' must include $Name."
  }
  [string]$property[0].value
}

function Get-MetadataProperty([object]$Sbom, [string]$Name) {
  $property = @($Sbom.metadata.properties | Where-Object { $_.name -eq $Name })
  if ($property.Count -ne 1) {
    throw "SBOM metadata must include $Name."
  }
  [string]$property[0].value
}

function Get-ComponentKey([object]$Component) {
  $scope = Get-ComponentScope $Component
  "$($Component.name)|$($Component.version)|$scope"
}

function Assert-HashRecord([object]$Component, [string]$Algorithm, [string]$ExpectedHash, [string]$ComponentName) {
  $matches = @($Component.hashes | Where-Object { $_.alg -eq $Algorithm -and $_.content -eq $ExpectedHash })
  if ($matches.Count -ne 1) {
    throw "SBOM component '$ComponentName' must include $Algorithm hash $ExpectedHash."
  }
}

function Assert-ExternalReference([object]$Component, [string]$Type, [string]$Url, [string]$ComponentName, [string]$Comment) {
  $matches = @($Component.externalReferences | Where-Object { $_.type -eq $Type -and $_.url -eq $Url })
  if ($matches.Count -ne 1) {
    throw "SBOM component '$ComponentName' must include external reference $Type $Url."
  }
  if (-not [string]::IsNullOrWhiteSpace($Comment) -and [string]$matches[0].comment -ne $Comment) {
    throw "SBOM component '$ComponentName' external reference $Type $Url must preserve comment '$Comment'."
  }
}

$sourceLockResolved = Assert-File $SourceLockPath "SourceLockPath"
$extensionPackageResolved = Assert-File $ExtensionPackagePath "ExtensionPackagePath"
$cargoWorkspaceResolved = Assert-File $CargoWorkspacePath "CargoWorkspacePath"
$cargoLockResolved = Assert-File $CargoLockPath "CargoLockPath"
$pnpmLockResolved = Assert-File $PnpmLockPath "PnpmLockPath"
$nativeBridgeCMakeResolved = Assert-File $NativeBridgeCMakePath "NativeBridgeCMakePath"
$sbomResolved = Assert-File $SbomPath "SbomPath"
$noticeResolved = Assert-File $NoticePath "NoticePath"

$lock = Get-Content -Raw -LiteralPath $sourceLockResolved | ConvertFrom-Json
if ($null -eq $lock.sources -or @($lock.sources).Count -eq 0) {
  throw "SourceLockPath must contain a non-empty sources array."
}
$sourceKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($source in @($lock.sources)) {
  $context = "Source lock entry '$($source.name)'"
  $name = Get-RequiredProperty $source "name" $context
  $version = Get-RequiredProperty $source "version" $context
  if (-not $sourceKeys.Add("$name|$version")) {
    throw "SourceLockPath must not contain duplicate source entries for $name $version."
  }
  $signatureUrl = Get-OptionalProperty $source "signatureUrl"
  $keysUrl = Get-OptionalProperty $source "keysUrl"
  if (($null -eq $signatureUrl) -ne ($null -eq $keysUrl)) {
    throw "$context must define signatureUrl and keysUrl together."
  }
}

$sbom = Get-Content -Raw -LiteralPath $sbomResolved | ConvertFrom-Json
$notice = Get-Content -Raw -LiteralPath $noticeResolved
$extensionPackage = Get-Content -Raw -LiteralPath $extensionPackageResolved | ConvertFrom-Json
$cargoWorkspaceRoot = Split-Path -Parent $cargoWorkspaceResolved
$workspaceVersion = Get-CargoWorkspaceField -Path $cargoWorkspaceResolved -Name "version"
$workspaceLicense = Get-CargoWorkspaceField -Path $cargoWorkspaceResolved -Name "license"

Assert-Equal "CycloneDX" $sbom.bomFormat "SBOM bomFormat should be CycloneDX."
Assert-Equal "1.6" $sbom.specVersion "SBOM specVersion should be 1.6."
Assert-Equal "SubversionR" $sbom.metadata.component.name "SBOM metadata component should be SubversionR."
Assert-Equal "application" $sbom.metadata.component.type "SBOM metadata component type should be application."
Assert-Equal "source-lock-sbom" (Get-MetadataProperty $sbom "subversionr:evidenceKind") "SBOM metadata should identify source-lock evidence."
Assert-Equal (Get-FileHash -LiteralPath $sourceLockResolved -Algorithm SHA256).Hash.ToLowerInvariant() (Get-MetadataProperty $sbom "subversionr:sourceLockSha256") "SBOM metadata should bind to the source lock hash."
Assert-True ($notice.Contains("SubversionR Third-Party Notices")) "NOTICE should identify SubversionR third-party notices."
Assert-True ($notice.Contains("This generated evidence is not a completed legal review")) "NOTICE should preserve the release-boundary non-claim."

$components = @($sbom.components)
$expectedComponentKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

$extensionId = Get-RequiredProperty $extensionPackage "name" "Extension package"
$extensionVersion = Get-RequiredProperty $extensionPackage "version" "Extension package"
$extensionLicense = Get-RequiredProperty $extensionPackage "license" "Extension package"
$extensionComponent = @($components | Where-Object { $_.name -eq $extensionId -and $_.version -eq $extensionVersion })
if ($extensionComponent.Count -ne 1) {
  throw "SBOM must contain exactly one component for VS Code extension $extensionId $extensionVersion."
}
Assert-Equal $extensionLicense $extensionComponent[0].licenses[0].expression "SBOM VS Code extension component should preserve the package license."
Assert-Equal "typescript-extension" (Get-ComponentScope $extensionComponent[0]) "SBOM VS Code extension component should have the TypeScript extension scope."
$expectedComponentKeys.Add((Get-ComponentKey $extensionComponent[0])) | Out-Null
foreach ($requiredNoticeText in @($extensionId, $extensionVersion, $extensionLicense)) {
  Assert-True ($notice.Contains($requiredNoticeText)) "NOTICE should include '$requiredNoticeText' for the VS Code extension."
}

foreach ($member in Get-CargoWorkspaceMembers $cargoWorkspaceResolved) {
  $crateManifest = Assert-File (Join-Path $cargoWorkspaceRoot "$member\Cargo.toml") "Cargo workspace member manifest"
  $crateName = Get-TomlPackageName $crateManifest
  $crateComponent = @($components | Where-Object { $_.name -eq $crateName -and $_.version -eq $workspaceVersion })
  if ($crateComponent.Count -ne 1) {
    throw "SBOM must contain exactly one component for Rust crate $crateName $workspaceVersion."
  }
  Assert-Equal $workspaceLicense $crateComponent[0].licenses[0].expression "SBOM Rust crate '$crateName' should preserve the workspace license."
  Assert-Equal "rust-workspace-crate" (Get-ComponentScope $crateComponent[0]) "SBOM Rust crate '$crateName' should have the Rust workspace crate scope."
  $expectedComponentKeys.Add((Get-ComponentKey $crateComponent[0])) | Out-Null
  Assert-True ($notice.Contains($crateName)) "NOTICE should include Rust crate $crateName."
}

$bridgeName = Get-CMakeProjectName $nativeBridgeCMakeResolved
$bridgeComponent = @($components | Where-Object { $_.name -eq $bridgeName -and $_.version -eq $workspaceVersion })
if ($bridgeComponent.Count -ne 1) {
  throw "SBOM must contain exactly one component for native C bridge $bridgeName $workspaceVersion."
}
Assert-Equal $workspaceLicense $bridgeComponent[0].licenses[0].expression "SBOM native C bridge component should preserve the workspace license."
Assert-Equal "native-c-bridge" (Get-ComponentScope $bridgeComponent[0]) "SBOM native C bridge component should have the native C bridge scope."
$expectedComponentKeys.Add((Get-ComponentKey $bridgeComponent[0])) | Out-Null
Assert-True ($notice.Contains($bridgeName)) "NOTICE should include native C bridge $bridgeName."

$directNpmNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($dependency in Get-NpmManifestDependencies $extensionPackage) {
  $directNpmNames.Add($dependency.name) | Out-Null
}
$pnpmLockPackages = @(Get-PnpmLockPackages $pnpmLockResolved)
$pnpmLockNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($dependency in $pnpmLockPackages) {
  $pnpmLockNames.Add($dependency.name) | Out-Null
}
foreach ($directDependency in $directNpmNames) {
  if (-not $pnpmLockNames.Contains($directDependency)) {
    throw "NPM manifest dependency '$directDependency' must appear in pnpm lockfile evidence."
  }
}
foreach ($dependency in $pnpmLockPackages) {
  $dependencyComponent = @($components | Where-Object { $_.name -eq $dependency.name -and $_.version -eq $dependency.version })
  if ($dependencyComponent.Count -ne 1) {
    throw "SBOM must contain exactly one component for pnpm lockfile dependency $($dependency.name) $($dependency.version)."
  }
  Assert-Equal "pnpm-lockfile-component" (Get-ComponentScope $dependencyComponent[0]) "SBOM pnpm dependency '$($dependency.name)' should preserve its lockfile scope."
  Assert-Equal $dependency.integrity (Get-ComponentProperty $dependencyComponent[0] "subversionr:lockfileIntegrity") "SBOM pnpm dependency '$($dependency.name)' should preserve lockfile integrity."
  $directDependency = ([string]$directNpmNames.Contains($dependency.name)).ToLowerInvariant()
  Assert-Equal $directDependency (Get-ComponentProperty $dependencyComponent[0] "subversionr:manifestDirectDependency") "SBOM pnpm dependency '$($dependency.name)' should preserve direct dependency status."
  $expectedComponentKeys.Add((Get-ComponentKey $dependencyComponent[0])) | Out-Null
  $expectedNoticeRow = "| npm | $($dependency.name) | $($dependency.version) | $directDependency | $($dependency.integrity) | unresolved by lockfile-only evidence |"
  Assert-True ($notice.Contains($expectedNoticeRow)) "NOTICE should include complete npm dependency evidence for $($dependency.name)."
}

$directCargoNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($member in Get-CargoWorkspaceMembers $cargoWorkspaceResolved) {
  $crateManifest = Assert-File (Join-Path $cargoWorkspaceRoot "$member\Cargo.toml") "Cargo workspace member manifest"
  foreach ($dependency in Get-CargoManifestDependencies $crateManifest) {
    $directCargoNames.Add($dependency.name) | Out-Null
  }
}
$cargoLockPackages = @(Get-CargoLockPackages $cargoLockResolved)
$cargoLockNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($dependency in $cargoLockPackages) {
  $cargoLockNames.Add($dependency.name) | Out-Null
}
foreach ($directDependency in $directCargoNames) {
  if (-not $cargoLockNames.Contains($directDependency)) {
    throw "Cargo manifest dependency '$directDependency' must appear in Cargo.lock evidence."
  }
}
foreach ($dependency in $cargoLockPackages) {
  $dependencyComponent = @($components | Where-Object { $_.name -eq $dependency.name -and $_.version -eq $dependency.version })
  if ($dependencyComponent.Count -ne 1) {
    throw "SBOM must contain exactly one component for Cargo.lock dependency $($dependency.name) $($dependency.version)."
  }
  Assert-Equal "cargo-lockfile-component" (Get-ComponentScope $dependencyComponent[0]) "SBOM Cargo dependency '$($dependency.name)' should preserve its lockfile scope."
  Assert-Equal "checksum:$($dependency.checksum)" (Get-ComponentProperty $dependencyComponent[0] "subversionr:lockfileIntegrity") "SBOM Cargo dependency '$($dependency.name)' should preserve lockfile checksum."
  $directDependency = ([string]$directCargoNames.Contains($dependency.name)).ToLowerInvariant()
  Assert-Equal $directDependency (Get-ComponentProperty $dependencyComponent[0] "subversionr:manifestDirectDependency") "SBOM Cargo dependency '$($dependency.name)' should preserve direct dependency status."
  $expectedComponentKeys.Add((Get-ComponentKey $dependencyComponent[0])) | Out-Null
  $expectedNoticeRow = "| cargo | $($dependency.name) | $($dependency.version) | $directDependency | checksum:$($dependency.checksum) | unresolved by lockfile-only evidence |"
  Assert-True ($notice.Contains($expectedNoticeRow)) "NOTICE should include complete Cargo dependency evidence for $($dependency.name)."
}

foreach ($source in @($lock.sources)) {
  $context = "Source lock entry '$($source.name)'"
  $name = Get-RequiredProperty $source "name" $context
  $version = Get-RequiredProperty $source "version" $context
  $license = Get-RequiredProperty $source "license" $context
  $licenseUrl = Get-RequiredProperty $source "licenseUrl" $context
  $url = Get-RequiredProperty $source "url" $context
  $sha512 = Get-RequiredProperty $source "sha512" $context

  $matches = @($components | Where-Object { $_.name -eq $name -and $_.version -eq $version })
  if ($matches.Count -ne 1) {
    throw "SBOM must contain exactly one component for locked source $name $version."
  }
  $component = $matches[0]
  Assert-Equal "library" $component.type "SBOM component '$name' type should be library."
  Assert-Equal "native-source-lock" (Get-ComponentScope $component) "SBOM component '$name' should have the native source-lock scope."
  Assert-Equal $license $component.licenses[0].expression "SBOM component '$name' should preserve the source-lock license expression."
  Assert-HashRecord -Component $component -Algorithm "SHA-512" -ExpectedHash $sha512 -ComponentName $name
  Assert-ExternalReference -Component $component -Type "distribution" -Url $url -ComponentName $name -Comment ""
  Assert-ExternalReference -Component $component -Type "license" -Url $licenseUrl -ComponentName $name -Comment ""

  $sha256 = Get-OptionalProperty $source "sha256"
  if ($null -ne $sha256) {
    Assert-HashRecord -Component $component -Algorithm "SHA-256" -ExpectedHash $sha256 -ComponentName $name
  }
  $sha3 = Get-OptionalProperty $source "sha3_256"
  if ($null -ne $sha3) {
    Assert-HashRecord -Component $component -Algorithm "SHA3-256" -ExpectedHash $sha3 -ComponentName $name
  }

  $signatureUrl = Get-OptionalProperty $source "signatureUrl"
  $keysUrl = Get-OptionalProperty $source "keysUrl"
  if ($null -ne $signatureUrl) {
    Assert-ExternalReference -Component $component -Type "other" -Url $signatureUrl -ComponentName $name -Comment "Upstream release signature"
    Assert-True ($notice.Contains($signatureUrl)) "NOTICE should include signature URL for locked source $name."
  }
  if ($null -ne $keysUrl) {
    Assert-ExternalReference -Component $component -Type "other" -Url $keysUrl -ComponentName $name -Comment "Upstream release signing keys"
    Assert-True ($notice.Contains($keysUrl)) "NOTICE should include keys URL for locked source $name."
  }

  foreach ($requiredNoticeText in @($name, $version, $license, $licenseUrl, $url, $sha512)) {
    Assert-True ($notice.Contains($requiredNoticeText)) "NOTICE should include '$requiredNoticeText' for locked source $name."
  }
  $expectedComponentKeys.Add((Get-ComponentKey $component)) | Out-Null
}

foreach ($component in $components) {
  $key = Get-ComponentKey $component
  if (-not $expectedComponentKeys.Contains($key)) {
    throw "SBOM contains a component that is not present in release evidence inputs: $key."
  }
}
Assert-Equal $expectedComponentKeys.Count $components.Count "SBOM should contain exactly one component for each expected release-evidence input."

Write-Host "Verified SubversionR release SBOM and third-party notice evidence."

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
  [string]$OutputPath
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

function Assert-File([string]$Path, [string]$Name) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Name must be a file: $Path"
  }
  (Resolve-Path -LiteralPath $Path).Path
}

function Assert-OutputPath([string]$Path) {
  $absolute = Get-RepoAbsolutePath $Path
  $targetRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target"))
  $targetRootWithSeparator = $targetRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  if (-not $absolute.StartsWith($targetRootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputPath must resolve inside the repository target directory: $Path"
  }
  $absolute
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

function Convert-ToPurlName([string]$Name) {
  $Name.ToLowerInvariant() -replace '[^a-z0-9._-]', '-'
}

function New-ComponentProperties([string]$Scope) {
  @(
    [pscustomobject]@{
      name = "subversionr:componentScope"
      value = $Scope
    }
  )
}

function New-InternalComponent([string]$BomRef, [string]$Type, [string]$Name, [string]$Version, [string]$License, [string]$Scope) {
  [pscustomobject][ordered]@{
    "bom-ref" = $BomRef
    type = $Type
    name = $Name
    version = $Version
    licenses = @(
      [pscustomobject]@{
        expression = $License
      }
    )
    properties = @(New-ComponentProperties $Scope)
  }
}

function New-LockfileDependencyComponent([string]$Ecosystem, [string]$Name, [string]$Version, [string]$Scope, [bool]$IsDirect, [string]$Integrity) {
  $purlName = if ($Ecosystem -eq "npm") {
    $Name.ToLowerInvariant().Replace("@", "%40")
  }
  else {
    Convert-ToPurlName $Name
  }

  [pscustomobject][ordered]@{
    "bom-ref" = "pkg:$Ecosystem/$purlName@$Version"
    type = "library"
    name = $Name
    version = $Version
    purl = "pkg:$Ecosystem/$purlName@$Version"
    properties = @(
      [pscustomobject]@{
        name = "subversionr:componentScope"
        value = $Scope
      },
      [pscustomobject]@{
        name = "subversionr:manifestDirectDependency"
        value = if ($IsDirect) { "true" } else { "false" }
      },
      [pscustomobject]@{
        name = "subversionr:lockfileIntegrity"
        value = $Integrity
      }
    )
  }
}

function New-HashRecords([object]$Source, [string]$Context) {
  $records = @(
    [pscustomobject]@{
      alg = "SHA-512"
      content = Get-RequiredProperty $Source "sha512" $Context
    }
  )

  $sha256 = Get-OptionalProperty $Source "sha256"
  if ($null -ne $sha256) {
    $records += [pscustomobject]@{
      alg = "SHA-256"
      content = $sha256
    }
  }

  $sha3 = Get-OptionalProperty $Source "sha3_256"
  if ($null -ne $sha3) {
    $records += [pscustomobject]@{
      alg = "SHA3-256"
      content = $sha3
    }
  }

  $records
}

function New-ExternalReferences([object]$Source, [string]$Context) {
  $references = @(
    [pscustomobject]@{
      type = "distribution"
      url = Get-RequiredProperty $Source "url" $Context
    },
    [pscustomobject]@{
      type = "license"
      url = Get-RequiredProperty $Source "licenseUrl" $Context
    }
  )

  $signatureUrl = Get-OptionalProperty $Source "signatureUrl"
  $keysUrl = Get-OptionalProperty $Source "keysUrl"
  if (($null -eq $signatureUrl) -ne ($null -eq $keysUrl)) {
    throw "$Context must define signatureUrl and keysUrl together."
  }
  if ($null -ne $signatureUrl) {
    $references += [pscustomobject]@{
      type = "other"
      url = $signatureUrl
      comment = "Upstream release signature"
    }
  }

  if ($null -ne $keysUrl) {
    $references += [pscustomobject]@{
      type = "other"
      url = $keysUrl
      comment = "Upstream release signing keys"
    }
  }

  $references
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

$sourceLockResolved = Assert-File $SourceLockPath "SourceLockPath"
$extensionPackageResolved = Assert-File $ExtensionPackagePath "ExtensionPackagePath"
$cargoWorkspaceResolved = Assert-File $CargoWorkspacePath "CargoWorkspacePath"
$cargoLockResolved = Assert-File $CargoLockPath "CargoLockPath"
$pnpmLockResolved = Assert-File $PnpmLockPath "PnpmLockPath"
$nativeBridgeCMakeResolved = Assert-File $NativeBridgeCMakePath "NativeBridgeCMakePath"
$outputResolved = Assert-OutputPath $OutputPath

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
}

$extensionPackage = Get-Content -Raw -LiteralPath $extensionPackageResolved | ConvertFrom-Json
$extensionDisplayName = Get-RequiredProperty $extensionPackage "displayName" "Extension package"
if ($extensionDisplayName -cne "SVN-R") {
  throw "Extension Marketplace displayName must be SVN-R."
}
$extensionName = "SubversionR"
$extensionVersion = Get-RequiredProperty $extensionPackage "version" "Extension package"
$extensionId = Get-RequiredProperty $extensionPackage "name" "Extension package"
$extensionLicense = Get-RequiredProperty $extensionPackage "license" "Extension package"
$cargoLicense = Get-CargoWorkspaceField -Path $cargoWorkspaceResolved -Name "license"
$cargoRepository = Get-CargoWorkspaceField -Path $cargoWorkspaceResolved -Name "repository"
$cargoVersion = Get-CargoWorkspaceField -Path $cargoWorkspaceResolved -Name "version"

$internalComponents = @()
$internalComponents += New-InternalComponent `
  -BomRef "pkg:vscode/$extensionId@$extensionVersion" `
  -Type "application" `
  -Name $extensionId `
  -Version $extensionVersion `
  -License $extensionLicense `
  -Scope "typescript-extension"

$cargoWorkspaceRoot = Split-Path -Parent $cargoWorkspaceResolved
foreach ($member in Get-CargoWorkspaceMembers $cargoWorkspaceResolved) {
  $crateManifest = Assert-File (Join-Path $cargoWorkspaceRoot "$member\Cargo.toml") "Cargo workspace member manifest"
  $crateName = Get-TomlPackageName $crateManifest
  $internalComponents += New-InternalComponent `
    -BomRef "pkg:cargo/$crateName@$cargoVersion" `
    -Type "application" `
    -Name $crateName `
    -Version $cargoVersion `
    -License $cargoLicense `
    -Scope "rust-workspace-crate"
}

$bridgeName = Get-CMakeProjectName $nativeBridgeCMakeResolved
$internalComponents += New-InternalComponent `
  -BomRef "pkg:generic/$bridgeName@$cargoVersion" `
  -Type "library" `
  -Name $bridgeName `
  -Version $cargoVersion `
  -License $cargoLicense `
  -Scope "native-c-bridge"

$directNpmNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($dependency in Get-NpmManifestDependencies $extensionPackage) {
  $directNpmNames.Add($dependency.name) | Out-Null
}
$directCargoNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($member in Get-CargoWorkspaceMembers $cargoWorkspaceResolved) {
  $crateManifest = Assert-File (Join-Path $cargoWorkspaceRoot "$member\Cargo.toml") "Cargo workspace member manifest"
  foreach ($dependency in Get-CargoManifestDependencies $crateManifest) {
    $directCargoNames.Add($dependency.name) | Out-Null
  }
}

$lockfileDependencyComponents = @()
foreach ($dependency in Get-CargoLockPackages $cargoLockResolved) {
  $lockfileDependencyComponents += New-LockfileDependencyComponent `
    -Ecosystem "cargo" `
    -Name $dependency.name `
    -Version $dependency.version `
    -Scope "cargo-lockfile-component" `
    -IsDirect ($directCargoNames.Contains($dependency.name)) `
    -Integrity "checksum:$($dependency.checksum)"
}
foreach ($dependency in Get-PnpmLockPackages $pnpmLockResolved) {
  $lockfileDependencyComponents += New-LockfileDependencyComponent `
    -Ecosystem "npm" `
    -Name $dependency.name `
    -Version $dependency.version `
    -Scope "pnpm-lockfile-component" `
    -IsDirect ($directNpmNames.Contains($dependency.name)) `
    -Integrity $dependency.integrity
}

$nativeSourceComponents = @($lock.sources | Sort-Object name | ForEach-Object {
  $context = "Source lock entry '$($_.name)'"
  $name = Get-RequiredProperty $_ "name" $context
  $version = Get-RequiredProperty $_ "version" $context
  $license = Get-RequiredProperty $_ "license" $context
  $licenseUrl = Get-RequiredProperty $_ "licenseUrl" $context

  [pscustomobject][ordered]@{
    "bom-ref" = "pkg:generic/$(Convert-ToPurlName $name)@$version"
    type = "library"
    name = $name
    version = $version
    purl = "pkg:generic/$(Convert-ToPurlName $name)@$version"
    licenses = @(
      [pscustomobject]@{
        expression = $license
      }
    )
    hashes = @(New-HashRecords -Source $_ -Context $context)
    externalReferences = @(New-ExternalReferences -Source $_ -Context $context)
    properties = @(
      [pscustomobject]@{
        name = "subversionr:sourceLock:licenseUrl"
        value = $licenseUrl
      },
      [pscustomobject]@{
        name = "subversionr:componentScope"
        value = "native-source-lock"
      }
    )
  }
})

$components = @($internalComponents + $lockfileDependencyComponents + $nativeSourceComponents | Sort-Object name, version, type)

$sbom = [pscustomobject][ordered]@{
  bomFormat = "CycloneDX"
  specVersion = "1.6"
  version = 1
  metadata = [pscustomobject][ordered]@{
    component = [pscustomobject][ordered]@{
      "bom-ref" = "pkg:github/Hitsuki-Ban/SubversionR@$extensionVersion"
      type = "application"
      name = $extensionName
      version = $extensionVersion
      licenses = @(
        [pscustomobject]@{
          expression = $cargoLicense
        }
      )
      externalReferences = @(
        [pscustomobject]@{
          type = "vcs"
          url = $cargoRepository
        }
      )
    }
    properties = @(
      [pscustomobject]@{
        name = "subversionr:evidenceKind"
        value = "source-lock-sbom"
      },
      [pscustomobject]@{
        name = "subversionr:sourceLockSha256"
        value = (Get-FileHash -LiteralPath $sourceLockResolved -Algorithm SHA256).Hash.ToLowerInvariant()
      }
    )
  }
  components = $components
}

$parent = Split-Path -Parent $outputResolved
New-Item -ItemType Directory -Force -Path $parent | Out-Null
$sbom | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $outputResolved -Encoding utf8
Write-Host "Generated SubversionR source-lock CycloneDX SBOM at $outputResolved."

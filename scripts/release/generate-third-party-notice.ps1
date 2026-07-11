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
        scope = $sectionName
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
$projectLicense = Get-CargoWorkspaceField -Path $cargoWorkspaceResolved -Name "license"
$projectRepository = Get-CargoWorkspaceField -Path $cargoWorkspaceResolved -Name "repository"
$projectVersion = Get-CargoWorkspaceField -Path $cargoWorkspaceResolved -Name "version"
$cargoWorkspaceRoot = Split-Path -Parent $cargoWorkspaceResolved

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# SubversionR Third-Party Notices")
$lines.Add("")
$lines.Add("Generated from native source locks for release evidence. This generated evidence is not a completed legal review and does not close the full public-release NOTICE, SBOM, CVE, signing, or provenance gates.")
$lines.Add("")
$lines.Add("## Internal Components")
$lines.Add("")
$lines.Add("| Component | Version | Kind | License | Source |")
$lines.Add("| --- | --- | --- | --- | --- |")
$lines.Add("| $extensionName | $extensionVersion | product | $projectLicense | $projectRepository |")
$lines.Add("| $extensionId | $extensionVersion | VS Code extension | $extensionLicense | packages/vscode-extension/package.json |")
foreach ($member in Get-CargoWorkspaceMembers $cargoWorkspaceResolved) {
  $crateManifest = Assert-File (Join-Path $cargoWorkspaceRoot "$member\Cargo.toml") "Cargo workspace member manifest"
  $crateName = Get-TomlPackageName $crateManifest
  $lines.Add("| $crateName | $projectVersion | Rust crate | $projectLicense | $member/Cargo.toml |")
}
$bridgeName = Get-CMakeProjectName $nativeBridgeCMakeResolved
$lines.Add("| $bridgeName | $projectVersion | C bridge | $projectLicense | native/svn-bridge/CMakeLists.txt |")
$lines.Add("")
$lines.Add("## Locked Native Sources")
$lines.Add("")
$lines.Add("| Component | Version | License | License URL | Source URL | SHA512 | Additional Hashes | Signature Evidence |")
$lines.Add("| --- | --- | --- | --- | --- | --- | --- | --- |")

foreach ($source in @($lock.sources | Sort-Object name)) {
  $context = "Source lock entry '$($source.name)'"
  $name = Get-RequiredProperty $source "name" $context
  $version = Get-RequiredProperty $source "version" $context
  $license = Get-RequiredProperty $source "license" $context
  $licenseUrl = Get-RequiredProperty $source "licenseUrl" $context
  $url = Get-RequiredProperty $source "url" $context
  $sha512 = Get-RequiredProperty $source "sha512" $context

  $additionalHashes = @()
  $sha256 = Get-OptionalProperty $source "sha256"
  if ($null -ne $sha256) {
    $additionalHashes += "SHA256=$sha256"
  }
  $sha3 = Get-OptionalProperty $source "sha3_256"
  if ($null -ne $sha3) {
    $additionalHashes += "SHA3-256=$sha3"
  }
  if ($additionalHashes.Count -eq 0) {
    $additionalHashes += "none"
  }

  $signatureEvidence = @()
  $signatureUrl = Get-OptionalProperty $source "signatureUrl"
  $keysUrl = Get-OptionalProperty $source "keysUrl"
  if (($null -eq $signatureUrl) -ne ($null -eq $keysUrl)) {
    throw "$context must define signatureUrl and keysUrl together."
  }
  if ($null -ne $signatureUrl) {
    $signatureEvidence += "signature=$signatureUrl"
  }
  if ($null -ne $keysUrl) {
    $signatureEvidence += "keys=$keysUrl"
  }
  if ($signatureEvidence.Count -eq 0) {
    $signatureEvidence += "none"
  }

  $lines.Add("| $name | $version | $license | $licenseUrl | $url | $sha512 | $($additionalHashes -join '<br>') | $($signatureEvidence -join '<br>') |")
}

$lines.Add("")
$lines.Add("## Manifest Dependency Evidence")
$lines.Add("")
$lines.Add("| Ecosystem | Component | Resolved Version | Direct Manifest Dependency | Integrity | License Review Status |")
$lines.Add("| --- | --- | --- | --- | --- | --- |")
$directNpmNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($dependency in Get-NpmManifestDependencies $extensionPackage) {
  $directNpmNames.Add($dependency.name) | Out-Null
}
foreach ($dependency in Get-PnpmLockPackages $pnpmLockResolved) {
  $isDirect = ([string]$directNpmNames.Contains($dependency.name)).ToLowerInvariant()
  $lines.Add("| npm | $($dependency.name) | $($dependency.version) | $isDirect | $($dependency.integrity) | unresolved by lockfile-only evidence |")
}

$directCargoNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($member in Get-CargoWorkspaceMembers $cargoWorkspaceResolved) {
  $crateManifest = Assert-File (Join-Path $cargoWorkspaceRoot "$member\Cargo.toml") "Cargo workspace member manifest"
  foreach ($dependency in Get-CargoManifestDependencies $crateManifest) {
    $directCargoNames.Add($dependency.name) | Out-Null
  }
}
foreach ($dependency in Get-CargoLockPackages $cargoLockResolved) {
  $isDirect = ([string]$directCargoNames.Contains($dependency.name)).ToLowerInvariant()
  $lines.Add("| cargo | $($dependency.name) | $($dependency.version) | $isDirect | checksum:$($dependency.checksum) | unresolved by lockfile-only evidence |")
}

$lines.Add("")
$lines.Add("## Release Boundary")
$lines.Add("")
$lines.Add("This file is generated evidence for `SEC-015` and `MIG-012`. It proves that locked native source metadata is present and reproducible enough for review; it does not replace a final third-party legal NOTICE, license text bundle, CVE review, binary signing, release provenance, or VSIX installation evidence.")

$parent = Split-Path -Parent $outputResolved
New-Item -ItemType Directory -Force -Path $parent | Out-Null
$lines -join "`n" | Set-Content -LiteralPath $outputResolved -Encoding utf8
Write-Host "Generated SubversionR third-party notice evidence at $outputResolved."

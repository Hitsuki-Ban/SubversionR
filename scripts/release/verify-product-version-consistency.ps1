[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$RootPackagePath,

  [Parameter(Mandatory = $true)]
  [string]$ExtensionPackagePath,

  [Parameter(Mandatory = $true)]
  [string]$CargoWorkspaceManifestPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-File([string]$Path, [string]$Name) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Name must be a file: $Path"
  }
  (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
}

function Read-PackageVersion([string]$Path, [string]$Name) {
  $resolved = Assert-File $Path $Name
  $document = $null
  try {
    $document = [System.Text.Json.JsonDocument]::Parse((Get-Content -Raw -LiteralPath $resolved))
  }
  catch {
    throw "$Name must contain valid JSON."
  }
  try {
    if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
      throw "$Name must contain a JSON object."
    }
    $versionLikeProperties = @($document.RootElement.EnumerateObject() | Where-Object { $_.Name -ieq "version" })
    $versionProperties = @($versionLikeProperties | Where-Object { $_.Name -ceq "version" })
    if ($versionLikeProperties.Count -ne 1 -or $versionProperties.Count -ne 1 -or $versionProperties[0].Value.ValueKind -ne [System.Text.Json.JsonValueKind]::String) {
      throw "$Name must declare exactly one string version property."
    }
    $versionProperties[0].Value.GetString()
  }
  finally {
    $document.Dispose()
  }
}

function Read-CargoWorkspaceVersion([string]$Path) {
  $resolved = Assert-File $Path "Cargo workspace manifest"
  $content = (Get-Content -Raw -LiteralPath $resolved).Replace("`r`n", "`n")
  $workspacePackageSections = [regex]::Matches(
    $content,
    '(?ms)^\[workspace\.package\][ \t]*\n(?<body>.*?)(?=^\[|\z)'
  )
  if ($workspacePackageSections.Count -ne 1) {
    throw "Cargo workspace manifest must contain exactly one [workspace.package] section."
  }
  $workspacePackageBody = $workspacePackageSections[0].Groups["body"].Value
  $allVersionDeclarations = [regex]::Matches($workspacePackageBody, '(?m)^[ \t]*version[ \t]*=')
  if ($allVersionDeclarations.Count -ne 1) {
    throw "Cargo [workspace.package] must contain exactly one string version declaration."
  }
  $versionDeclarations = [regex]::Matches(
    $workspacePackageBody,
    '(?m)^[ \t]*version[ \t]*=[ \t]*"(?<version>[^"]*)"[ \t]*(?:#[^\n]*)?$'
  )
  if ($versionDeclarations.Count -ne 1) {
    throw "Cargo [workspace.package] version declaration must be a double-quoted string."
  }
  $versionDeclarations[0].Groups["version"].Value
}

function Assert-SemVer([string]$Version, [string]$Name) {
  $prereleaseIdentifier = '(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
  $semVerPattern = "\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-$prereleaseIdentifier(?:\.$prereleaseIdentifier)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z"
  if ($Version -notmatch $semVerPattern) {
    throw "$Name must be a semantic version: $Version"
  }
}

$rootVersion = Read-PackageVersion $RootPackagePath "Root package.json"
$extensionVersion = Read-PackageVersion $ExtensionPackagePath "Extension package.json"
$cargoVersion = Read-CargoWorkspaceVersion $CargoWorkspaceManifestPath

Assert-SemVer $rootVersion "Root package version"
Assert-SemVer $extensionVersion "Extension package version"
Assert-SemVer $cargoVersion "Cargo workspace version"

if ($extensionVersion -cne $rootVersion) {
  throw "Extension package version must exactly match root product version $rootVersion; got $extensionVersion."
}
if ($cargoVersion -cne $rootVersion) {
  throw "Cargo workspace version must exactly match root product version $rootVersion; got $cargoVersion."
}

Write-Host "Verified SubversionR product, extension, and Cargo version consistency at $rootVersion."

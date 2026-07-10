[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$VsixPath,

  [Parameter(Mandatory = $true)]
  [string]$CodeCliPath,

  [Parameter(Mandatory = $true)]
  [string]$FixtureRoot,

  [Parameter(Mandatory = $true)]
  [string]$EvidencePath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")

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

function Test-IsSamePath([string]$Left, [string]$Right) {
  $leftFull = [System.IO.Path]::GetFullPath($Left).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  $rightFull = [System.IO.Path]::GetFullPath($Right).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  [string]::Equals($leftFull, $rightFull, [System.StringComparison]::OrdinalIgnoreCase)
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
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Name must be a file: $Path"
  }
  (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
}

function Assert-CodeCliPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains("%") -or $Path.Contains("$")) {
    throw "CodeCliPath must be an explicit file path."
  }
  if (-not [System.IO.Path]::IsPathRooted($Path)) {
    throw "CodeCliPath must be an explicit absolute file path: $Path"
  }
  $resolved = Assert-File $Path "CodeCliPath"
  $leaf = Split-Path -Leaf $resolved
  if ($leaf -notin @("code.cmd", "code.exe")) {
    throw "CodeCliPath must point to code.cmd or code.exe: $Path"
  }
  $resolved
}

function Get-VsixPackageJson([string]$Path) {
  $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
  try {
    $entry = $archive.Entries | Where-Object { $_.FullName -eq "extension/package.json" } | Select-Object -First 1
    if ($null -eq $entry) {
      throw "VSIX must contain extension/package.json."
    }
    $reader = [System.IO.StreamReader]::new($entry.Open())
    try {
      $reader.ReadToEnd() | ConvertFrom-Json
    }
    finally {
      $reader.Dispose()
    }
  }
  finally {
    $archive.Dispose()
  }
}

function Get-StreamSha256([System.IO.Stream]$Stream) {
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    ($sha256.ComputeHash($Stream) | ForEach-Object { $_.ToString("x2") }) -join ""
  }
  finally {
    $sha256.Dispose()
  }
}

function Get-BytesSha256([byte[]]$Bytes) {
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    ($sha256.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
  }
  finally {
    $sha256.Dispose()
  }
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
      Get-StreamSha256 $stream
    }
    finally {
      $stream.Dispose()
    }
  }
  finally {
    $archive.Dispose()
  }
}

function Get-VsixTargetPlatform([string]$Path) {
  $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
  try {
    $entry = $archive.Entries | Where-Object { $_.FullName -eq "extension.vsixmanifest" } | Select-Object -First 1
    if ($null -eq $entry) {
      throw "VSIX must contain extension.vsixmanifest."
    }
    $reader = [System.IO.StreamReader]::new($entry.Open())
    try {
      $manifestText = $reader.ReadToEnd()
    }
    finally {
      $reader.Dispose()
    }
  }
  finally {
    $archive.Dispose()
  }

  $manifest = [xml]$manifestText
  $identityNodes = @($manifest.SelectNodes("//*[local-name()='PackageManifest']/*[local-name()='Metadata']/*[local-name()='Identity']"))
  if ($identityNodes.Count -ne 1 -or [string]::IsNullOrWhiteSpace($identityNodes[0].TargetPlatform)) {
    throw "VSIX manifest Identity must contain TargetPlatform."
  }
  [string]$identityNodes[0].TargetPlatform
}

function Get-DirectoryTreeSha256([string]$Root) {
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    throw "Directory tree root must exist: $Root"
  }

  $records = @(Get-ChildItem -LiteralPath $Root -Recurse -Force |
    Sort-Object FullName |
    ForEach-Object {
      $relativePath = [System.IO.Path]::GetRelativePath($Root, $_.FullName).Replace("\", "/")
      if ($_.PSIsContainer) {
        "D|$relativePath"
      }
      else {
        $fileSha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "F|$relativePath|$($_.Length)|$fileSha256"
      }
    })
  $bytes = [System.Text.Encoding]::UTF8.GetBytes(($records -join "`n"))
  Get-BytesSha256 $bytes
}

function Get-CodeCliVersion([string]$CodeCliPath) {
  $versionOutput = @(& $CodeCliPath --version)
  if ($LASTEXITCODE -ne 0) {
    throw "VS Code CLI version probe failed with exit code $LASTEXITCODE."
  }
  if ($versionOutput.Count -eq 0) {
    throw "VS Code CLI version probe returned no output."
  }
  $versionOutput
}

function New-WorkingCopySentinel([string]$Root) {
  $workingCopyRoot = Join-Path $Root "working-copy-sentinel"
  $svnRoot = Join-Path $workingCopyRoot ".svn"
  New-Item -ItemType Directory -Force -Path $svnRoot | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $svnRoot "pristine\00") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $svnRoot "tmp") | Out-Null
  $wcDbPath = Join-Path $svnRoot "wc.db"
  [System.IO.File]::WriteAllBytes($wcDbPath, [System.Text.Encoding]::UTF8.GetBytes("SubversionR M7g VSIX CLI install working-copy non-mutation sentinel"))
  $pristinePath = Join-Path $svnRoot "pristine\00\sentinel.svn-base"
  [System.IO.File]::WriteAllBytes($pristinePath, [System.Text.Encoding]::UTF8.GetBytes("SubversionR M7g pristine sentinel"))
  [pscustomobject]@{
    root = $workingCopyRoot
    svnRoot = $svnRoot
    wcDbPath = $wcDbPath
    beforeSha256 = (Get-FileHash -LiteralPath $wcDbPath -Algorithm SHA256).Hash.ToLowerInvariant()
    beforeTreeSha256 = Get-DirectoryTreeSha256 $svnRoot
  }
}

function Assert-WorkingCopySentinelUnchanged([object]$Sentinel) {
  if (-not (Test-Path -LiteralPath $Sentinel.wcDbPath -PathType Leaf)) {
    throw "Working-copy sentinel wc.db was removed: $($Sentinel.wcDbPath)"
  }
  $afterSha256 = (Get-FileHash -LiteralPath $Sentinel.wcDbPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($afterSha256 -ne $Sentinel.beforeSha256) {
    throw "Working-copy sentinel wc.db changed during VSIX CLI install."
  }
  $afterTreeSha256 = Get-DirectoryTreeSha256 $Sentinel.svnRoot
  if ($afterTreeSha256 -ne $Sentinel.beforeTreeSha256) {
    throw "Working-copy sentinel .svn tree changed during VSIX CLI install."
  }
  [pscustomobject]@{
    wcDbSha256 = $afterSha256
    treeSha256 = $afterTreeSha256
  }
}

function Find-InstalledPackage([string]$ExtensionsRoot, [string]$Publisher, [string]$Name, [string]$Version) {
  $matches = @(Get-ChildItem -LiteralPath $ExtensionsRoot -Directory -Recurse -Depth 2 |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "package.json") -PathType Leaf } |
    ForEach-Object {
      $packageJson = Get-Content -Raw -LiteralPath (Join-Path $_.FullName "package.json") | ConvertFrom-Json
      if ($packageJson.publisher -eq $Publisher -and $packageJson.name -eq $Name -and $packageJson.version -eq $Version) {
        $_.FullName
      }
    })
  if ($matches.Count -ne 1) {
    throw "Expected exactly one installed extension package $Publisher.$Name@$Version; found $($matches.Count)."
  }
  $matches[0]
}

$vsixResolved = Assert-GeneratedPath -Path $VsixPath -Name "VsixPath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\vsix")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-vsix-scripts"))
) -Description "target/vsix or target/tests/release-vsix-scripts"
$vsixResolved = Assert-File $vsixResolved "VsixPath"
$codeCliResolved = Assert-CodeCliPath $CodeCliPath
$fixtureRootResolved = Assert-GeneratedPath -Path $FixtureRoot -Name "FixtureRoot" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence\vsix-cli-install")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-vsix-scripts"))
) -Description "the repository target directory (target/release-evidence/vsix-cli-install or target/tests/release-vsix-scripts)"
$aggregateFixtureRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence\vsix-cli-install"))
if (Test-IsSamePath -Left $fixtureRootResolved -Right $aggregateFixtureRoot) {
  throw "FixtureRoot must include a dedicated child directory below target/release-evidence/vsix-cli-install."
}
$evidencePathResolved = Assert-GeneratedPath -Path $EvidencePath -Name "EvidencePath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-vsix-scripts"))
) -Description "target/release-evidence or target/tests/release-vsix-scripts"

if (Test-Path -LiteralPath $fixtureRootResolved) {
  Remove-Item -LiteralPath $fixtureRootResolved -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $fixtureRootResolved | Out-Null

$userDataRoot = Join-Path $fixtureRootResolved "user-data"
$extensionsRoot = Join-Path $fixtureRootResolved "extensions"
New-Item -ItemType Directory -Force -Path $userDataRoot | Out-Null
New-Item -ItemType Directory -Force -Path $extensionsRoot | Out-Null
$sentinel = New-WorkingCopySentinel -Root $fixtureRootResolved

$packageJson = Get-VsixPackageJson $vsixResolved
if ($packageJson.publisher -ne "hitsuki-ban" -or $packageJson.name -ne "subversionr") {
  throw "VSIX extension identity must be hitsuki-ban.subversionr."
}
$manifestTargetPlatform = Get-VsixTargetPlatform $vsixResolved
if ($manifestTargetPlatform -ne $Target) {
  throw "VSIX target platform must be $Target."
}
$vsixEntrypointSha256 = Get-ZipEntrySha256 -ZipPath $vsixResolved -EntryName "extension/dist/extension.js"
$codeCliVersion = Get-CodeCliVersion $codeCliResolved
$codeCliSha256 = (Get-FileHash -LiteralPath $codeCliResolved -Algorithm SHA256).Hash.ToLowerInvariant()

& $codeCliResolved --user-data-dir $userDataRoot --extensions-dir $extensionsRoot --install-extension $vsixResolved --force
if ($LASTEXITCODE -ne 0) {
  throw "VS Code CLI install failed with exit code $LASTEXITCODE."
}

$installedExtensions = @(& $codeCliResolved --user-data-dir $userDataRoot --extensions-dir $extensionsRoot --list-extensions --show-versions)
if ($LASTEXITCODE -ne 0) {
  throw "VS Code CLI extension list failed with exit code $LASTEXITCODE."
}

$expectedInstalledLine = "$($packageJson.publisher).$($packageJson.name)@$($packageJson.version)"
if ($installedExtensions -notcontains $expectedInstalledLine) {
  throw "VS Code CLI installed extension list did not contain $expectedInstalledLine. Found: $($installedExtensions -join ', ')"
}

$installedPackageRoot = Find-InstalledPackage -ExtensionsRoot $extensionsRoot -Publisher $packageJson.publisher -Name $packageJson.name -Version $packageJson.version
$installedEntrypointPath = Assert-File (Join-Path $installedPackageRoot "dist\extension.js") "installed dist/extension.js"
$installedEntrypointSha256 = (Get-FileHash -LiteralPath $installedEntrypointPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($installedEntrypointSha256 -ne $vsixEntrypointSha256) {
  throw "Installed compiled extension entrypoint hash must match VSIX extension/dist/extension.js."
}
$sentinelAfter = Assert-WorkingCopySentinelUnchanged -Sentinel $sentinel

$report = [pscustomobject]@{
  schemaVersion = 1
  schema = "subversionr.release.vsix-cli-install.win32-x64.v1"
  publicReadinessClaim = $false
  target = $Target
  traceIds = @("MIG-009", "TST-024")
  extension = [pscustomobject]@{
    id = "$($packageJson.publisher).$($packageJson.name)"
    version = [string]$packageJson.version
    installedPackageRoot = Get-RepoRelativePath $installedPackageRoot
  }
  codeCli = [pscustomobject]@{
    path = $codeCliResolved
    sha256 = $codeCliSha256
    versionOutput = $codeCliVersion
  }
  vsix = [pscustomobject]@{
    path = $vsixResolved
    relativePath = Get-RepoRelativePath $vsixResolved
    size = (Get-Item -LiteralPath $vsixResolved).Length
    targetPlatform = $manifestTargetPlatform
    sha256 = (Get-FileHash -LiteralPath $vsixResolved -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  fixtureRoots = [pscustomobject]@{
    root = Get-RepoRelativePath $fixtureRootResolved
    userData = Get-RepoRelativePath $userDataRoot
    extensions = Get-RepoRelativePath $extensionsRoot
  }
  installedExtensions = $installedExtensions
  hashes = [pscustomobject]@{
    vsixEntrypointSha256 = $vsixEntrypointSha256
    installedEntrypointSha256 = $installedEntrypointSha256
  }
  workingCopySentinel = [pscustomobject]@{
    path = Get-RepoRelativePath $sentinel.wcDbPath
    beforeSha256 = $sentinel.beforeSha256
    afterSha256 = $sentinelAfter.wcDbSha256
    svnTreeBeforeSha256 = $sentinel.beforeTreeSha256
    svnTreeAfterSha256 = $sentinelAfter.treeSha256
    mutation = "none"
  }
  assertions = @(
    "VS Code CLI path was explicit",
    "VSIX install used isolated user-data and extensions directories under target",
    "installed extension id and version matched the VSIX package",
    "installed compiled extension entrypoint hash matches the VSIX artifact",
    "working-copy sentinel .svn tree hash was unchanged",
    "publicReadinessClaim remains false"
  )
}

$evidenceParent = Split-Path -Parent $evidencePathResolved
New-Item -ItemType Directory -Force -Path $evidenceParent | Out-Null
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $evidencePathResolved -Encoding utf8

Write-Host "Verified SubversionR VS Code CLI VSIX install for $Target at $fixtureRootResolved."

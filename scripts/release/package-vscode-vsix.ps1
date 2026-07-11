[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$PackageRoot,

  [Parameter(Mandatory = $true)]
  [string]$ExtensionDistDirectory,

  [Parameter(Mandatory = $true)]
  [string]$ReadmePath,

  [Parameter(Mandatory = $true)]
  [string]$LicensePath,

  [Parameter(Mandatory = $true)]
  [string]$ChangelogPath,

  [Parameter(Mandatory = $true)]
  [string]$SupportPath,

  [Parameter(Mandatory = $true)]
  [string]$WorkRoot,

  [Parameter(Mandatory = $true)]
  [string]$OutputRoot,

  [Parameter(Mandatory = $true)]
  [string]$EvidencePath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$verifyLayoutScript = Join-Path $PSScriptRoot "verify-vscode-package-layout.ps1"
$svnCliTools = @(
  "svn.exe",
  "svnadmin.exe",
  "svnbench.exe",
  "svndumpfilter.exe",
  "svnfsfs.exe",
  "svnlook.exe",
  "svnmucc.exe",
  "svnrdump.exe",
  "svnserve.exe",
  "svnsync.exe",
  "svnversion.exe"
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

function Assert-Directory([string]$Path, [string]$Name) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "$Name must be a directory: $Path"
  }
  (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
}

function Assert-File([string]$Path, [string]$Name) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Name must be a file: $Path"
  }
  (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
}

function Copy-DirectoryContents([string]$SourceRoot, [string]$DestinationRoot) {
  New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null
  Get-ChildItem -LiteralPath $SourceRoot -Force |
    Copy-Item -Destination $DestinationRoot -Recurse -Force
}

function Assert-NoCompiledTestArtifacts([string]$DistRoot) {
  $found = @(Get-ChildItem -LiteralPath $DistRoot -File -Recurse |
    Where-Object {
      $relativePath = [System.IO.Path]::GetRelativePath($DistRoot, $_.FullName)
      $relativePath -match '(^|[\\/])tests([\\/]|$)' -or
      $_.Name -like "*.test.js" -or
      $_.Name -like "*.test.d.ts" -or
      $_.Name -like "*.spec.js" -or
      $_.Name -like "*.spec.d.ts"
    } |
    Select-Object -ExpandProperty FullName)
  if ($found.Count -gt 0) {
    throw "ExtensionDistDirectory must not contain compiled test artifacts: $($found -join ', ')"
  }
}

function Get-ZipEntryNames([string]$ZipPath) {
  $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
  try {
    @($archive.Entries | ForEach-Object { $_.FullName })
  }
  finally {
    $archive.Dispose()
  }
}

function Set-DeterministicZipTimestamps([string]$ZipPath) {
  $bytes = [System.IO.File]::ReadAllBytes($ZipPath)
  $minimumEocdSize = 22
  $maximumCommentSize = 65535
  $eocdOffset = -1
  for ($offset = $bytes.Length - $minimumEocdSize; $offset -ge [Math]::Max(0, $bytes.Length - $minimumEocdSize - $maximumCommentSize); $offset--) {
    if ([System.BitConverter]::ToUInt32($bytes, $offset) -eq 0x06054b50) {
      $eocdOffset = $offset
      break
    }
  }
  if ($eocdOffset -lt 0) {
    throw "VSIX must contain an end-of-central-directory record."
  }

  $diskNumber = [System.BitConverter]::ToUInt16($bytes, $eocdOffset + 4)
  $centralDirectoryDisk = [System.BitConverter]::ToUInt16($bytes, $eocdOffset + 6)
  $entriesOnDisk = [System.BitConverter]::ToUInt16($bytes, $eocdOffset + 8)
  $entryCount = [System.BitConverter]::ToUInt16($bytes, $eocdOffset + 10)
  $centralDirectorySize = [System.BitConverter]::ToUInt32($bytes, $eocdOffset + 12)
  $centralDirectoryOffset = [System.BitConverter]::ToUInt32($bytes, $eocdOffset + 16)
  if ($diskNumber -ne 0 -or $centralDirectoryDisk -ne 0 -or $entriesOnDisk -ne $entryCount -or $entryCount -eq [uint16]::MaxValue -or $centralDirectorySize -eq [uint32]::MaxValue -or $centralDirectoryOffset -eq [uint32]::MaxValue) {
    throw "VSIX timestamp normalization supports only single-disk, non-ZIP64 archives."
  }
  if ([int64]$centralDirectoryOffset + [int64]$centralDirectorySize -ne $eocdOffset) {
    throw "VSIX central directory must end immediately before its end record."
  }

  [uint16]$fixedDosTime = 0
  [uint16]$fixedDosDate = (20 -shl 9) -bor (1 -shl 5) -bor 1
  $fixedTimeBytes = [System.BitConverter]::GetBytes($fixedDosTime)
  $fixedDateBytes = [System.BitConverter]::GetBytes($fixedDosDate)
  $centralOffset = [int64]$centralDirectoryOffset
  $records = [System.Collections.Generic.List[object]]::new()
  for ($index = 0; $index -lt $entryCount; $index++) {
    if ($centralOffset + 46 -gt $bytes.Length -or [System.BitConverter]::ToUInt32($bytes, [int]$centralOffset) -ne 0x02014b50) {
      throw "VSIX central directory entry $index is invalid."
    }
    [System.Array]::Copy($fixedTimeBytes, 0, $bytes, $centralOffset + 12, 2)
    [System.Array]::Copy($fixedDateBytes, 0, $bytes, $centralOffset + 14, 2)

    $localHeaderOffset = [System.BitConverter]::ToUInt32($bytes, [int]$centralOffset + 42)
    if ($localHeaderOffset -eq [uint32]::MaxValue -or $localHeaderOffset + 30 -gt $bytes.Length -or [System.BitConverter]::ToUInt32($bytes, [int]$localHeaderOffset) -ne 0x04034b50) {
      throw "VSIX local header for central directory entry $index is invalid or ZIP64."
    }
    [System.Array]::Copy($fixedTimeBytes, 0, $bytes, [int64]$localHeaderOffset + 10, 2)
    [System.Array]::Copy($fixedDateBytes, 0, $bytes, [int64]$localHeaderOffset + 12, 2)

    $fileNameLength = [System.BitConverter]::ToUInt16($bytes, [int]$centralOffset + 28)
    $extraLength = [System.BitConverter]::ToUInt16($bytes, [int]$centralOffset + 30)
    $commentLength = [System.BitConverter]::ToUInt16($bytes, [int]$centralOffset + 32)
    $centralRecordLength = 46 + $fileNameLength + $extraLength + $commentLength
    $centralRecord = [byte[]]::new($centralRecordLength)
    [System.Array]::Copy($bytes, $centralOffset, $centralRecord, 0, $centralRecordLength)
    $name = [System.Text.Encoding]::UTF8.GetString($bytes, [int]$centralOffset + 46, $fileNameLength)
    $records.Add([pscustomobject]@{
        name = $name
        localOffset = [int64]$localHeaderOffset
        centralRecord = $centralRecord
        localRecord = $null
      }) | Out-Null
    $centralOffset += $centralRecordLength
  }

  $recordsByLocalOffset = @($records | Sort-Object localOffset)
  for ($index = 0; $index -lt $recordsByLocalOffset.Count; $index++) {
    $record = $recordsByLocalOffset[$index]
    $nextOffset = if ($index + 1 -lt $recordsByLocalOffset.Count) { $recordsByLocalOffset[$index + 1].localOffset } else { [int64]$centralDirectoryOffset }
    $recordLength = $nextOffset - $record.localOffset
    if ($recordLength -le 0 -or $record.localOffset + $recordLength -gt $centralDirectoryOffset) {
      throw "VSIX local record layout is invalid for $($record.name)."
    }
    $localRecord = [byte[]]::new($recordLength)
    [System.Array]::Copy($bytes, $record.localOffset, $localRecord, 0, $recordLength)
    $record.localRecord = $localRecord
  }

  $orderedRecords = [object[]]$records.ToArray()
  $recordComparer = [System.Collections.Generic.Comparer[object]]::Create(
    [System.Comparison[object]] {
      param($left, $right)
      [System.StringComparer]::Ordinal.Compare([string]$left.name, [string]$right.name)
    }
  )
  [System.Array]::Sort($orderedRecords, $recordComparer)
  $output = [System.IO.MemoryStream]::new($bytes.Length)
  try {
    $firstLocalOffset = $recordsByLocalOffset[0].localOffset
    if ($firstLocalOffset -gt 0) {
      $output.Write($bytes, 0, $firstLocalOffset)
    }
    foreach ($record in $orderedRecords) {
      $newLocalOffset = $output.Position
      if ($newLocalOffset -gt [uint32]::MaxValue) {
        throw "VSIX normalized local offset requires ZIP64."
      }
      $newOffsetBytes = [System.BitConverter]::GetBytes([uint32]$newLocalOffset)
      [System.Array]::Copy($newOffsetBytes, 0, $record.centralRecord, 42, 4)
      $output.Write($record.localRecord, 0, $record.localRecord.Length)
    }

    $newCentralDirectoryOffset = $output.Position
    foreach ($record in $orderedRecords) {
      $output.Write($record.centralRecord, 0, $record.centralRecord.Length)
    }
    $newCentralDirectorySize = $output.Position - $newCentralDirectoryOffset
    if ($newCentralDirectoryOffset -gt [uint32]::MaxValue -or $newCentralDirectorySize -gt [uint32]::MaxValue) {
      throw "VSIX normalized central directory requires ZIP64."
    }

    $endRecord = [byte[]]::new($bytes.Length - $eocdOffset)
    [System.Array]::Copy($bytes, $eocdOffset, $endRecord, 0, $endRecord.Length)
    [System.Array]::Copy([System.BitConverter]::GetBytes([uint32]$newCentralDirectorySize), 0, $endRecord, 12, 4)
    [System.Array]::Copy([System.BitConverter]::GetBytes([uint32]$newCentralDirectoryOffset), 0, $endRecord, 16, 4)
    $output.Write($endRecord, 0, $endRecord.Length)
    [System.IO.File]::WriteAllBytes($ZipPath, $output.ToArray())
  }
  finally {
    $output.Dispose()
  }
}

function Assert-ZipContains([string[]]$Entries, [string]$EntryName) {
  if ($Entries -notcontains $EntryName) {
    throw "VSIX must contain $EntryName."
  }
}

function Assert-ZipDoesNotContain([string[]]$Entries, [string]$Pattern, [string]$Message) {
  $matches = @($Entries | Where-Object { $_ -like $Pattern })
  if ($matches.Count -gt 0) {
    throw "$Message Found: $($matches -join ', ')"
  }
}

function Assert-RelativePackagePath([string]$Path, [string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "$Name must not be empty."
  }
  if ([System.IO.Path]::IsPathRooted($Path) -or $Path.Contains("\") -or $Path.Contains("../") -or $Path.Contains("/../") -or $Path -eq "." -or $Path.StartsWith("./")) {
    throw "$Name must be a normalized package-relative path: $Path"
  }
  foreach ($segment in $Path.Split("/")) {
    if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq "." -or $segment -eq "..") {
      throw "$Name must be a normalized package-relative path: $Path"
    }
  }
  $Path
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

function Get-VsixPackageJson([string[]]$Entries, [string]$VsixPath) {
  Assert-ZipContains -Entries $Entries -EntryName "extension/package.json"
  $archive = [System.IO.Compression.ZipFile]::OpenRead($VsixPath)
  try {
    $entry = $archive.Entries | Where-Object { $_.FullName -eq "extension/package.json" } | Select-Object -First 1
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

function Get-VsixManifestMetadata([string[]]$Entries, [string]$VsixPath) {
  Assert-ZipContains -Entries $Entries -EntryName "extension.vsixmanifest"
  $archive = [System.IO.Compression.ZipFile]::OpenRead($VsixPath)
  try {
    $entry = $archive.Entries | Where-Object { $_.FullName -eq "extension.vsixmanifest" } | Select-Object -First 1
    $reader = [System.IO.StreamReader]::new($entry.Open())
    try {
      [xml]$manifest = $reader.ReadToEnd()
    }
    finally {
      $reader.Dispose()
    }
  }
  finally {
    $archive.Dispose()
  }

  $identityNodes = @($manifest.SelectNodes("//*[local-name()='PackageManifest']/*[local-name()='Metadata']/*[local-name()='Identity']"))
  if ($identityNodes.Count -ne 1) {
    throw "VSIX manifest must contain exactly one Identity node."
  }

  $preReleaseNodes = @($manifest.SelectNodes("//*[local-name()='PackageManifest']/*[local-name()='Metadata']/*[local-name()='Properties']/*[local-name()='Property' and @Id='Microsoft.VisualStudio.Code.PreRelease']"))
  if ($preReleaseNodes.Count -ne 1) {
    throw "VSIX manifest must contain exactly one Microsoft.VisualStudio.Code.PreRelease property."
  }
  if ([string]$preReleaseNodes[0].Value -cne "true") {
    throw "VSIX manifest Microsoft.VisualStudio.Code.PreRelease property Value must be exactly 'true'."
  }

  [pscustomobject]@{
    id = [string]$identityNodes[0].Id
    publisher = [string]$identityNodes[0].Publisher
    version = [string]$identityNodes[0].Version
    targetPlatform = [string]$identityNodes[0].TargetPlatform
    preRelease = $true
  }
}

function Assert-VsixContents([string]$VsixPath, [string]$Target) {
  $entries = Get-ZipEntryNames $VsixPath
  Assert-ZipContains -Entries $entries -EntryName "extension/package.json"
  Assert-ZipContains -Entries $entries -EntryName "extension.vsixmanifest"
  Assert-ZipContains -Entries $entries -EntryName "extension/dist/extension.js"
  Assert-ZipContains -Entries $entries -EntryName "extension/resources/backend/$Target/subversionr-daemon.exe"
  Assert-ZipContains -Entries $entries -EntryName "extension/resources/backend/$Target/subversionr_svn_bridge.dll"
  Assert-ZipContains -Entries $entries -EntryName "extension/resources/backend/$Target/subversionr-backend-package-manifest.json"
  Assert-ZipContains -Entries $entries -EntryName "extension/readme.md"
  Assert-ZipContains -Entries $entries -EntryName "extension/LICENSE.txt"
  Assert-ZipContains -Entries $entries -EntryName "extension/CHANGELOG.md"
  Assert-ZipContains -Entries $entries -EntryName "extension/SUPPORT.md"
  Assert-ZipDoesNotContain -Entries $entries -Pattern "extension/src/*" -Message "VSIX must not contain TypeScript source."
  Assert-ZipDoesNotContain -Entries $entries -Pattern "extension/tests/*" -Message "VSIX must not contain tests."
  Assert-ZipDoesNotContain -Entries $entries -Pattern "extension/node_modules/*" -Message "VSIX must not contain node_modules for the current dependency-free extension."
  foreach ($toolName in $svnCliTools) {
    Assert-ZipDoesNotContain -Entries $entries -Pattern "extension/**/$toolName" -Message "VSIX must not contain SVN CLI fixture tools."
  }

  $packageJson = Get-VsixPackageJson -Entries $entries -VsixPath $VsixPath
  if ($packageJson.name -ne "subversionr" -or $packageJson.publisher -ne "hitsuki-ban") {
    throw "VSIX package identity must be hitsuki-ban.subversionr."
  }
  $manifestMetadata = Get-VsixManifestMetadata -Entries $entries -VsixPath $VsixPath
  $expectedExtensionId = "$($packageJson.publisher).$($packageJson.name)"
  if ($manifestMetadata.id -ne $packageJson.name -or
    $manifestMetadata.publisher -ne $packageJson.publisher -or
    $manifestMetadata.version -ne $packageJson.version -or
    $manifestMetadata.targetPlatform -ne $Target) {
    throw "VSIX manifest identity must compose to $expectedExtensionId $($packageJson.version) for $Target."
  }
  if ($packageJson.main -ne "./dist/extension.js") {
    throw "VSIX package main must be ./dist/extension.js."
  }
  if ($packageJson.keywords -notcontains "svn" -or
    $packageJson.keywords -notcontains "subversion" -or
    $packageJson.keywords -notcontains "source-control" -or
    $packageJson.keywords -notcontains "scm" -or
    $packageJson.keywords -notcontains "apache-subversion") {
    throw "VSIX package must include SubversionR Marketplace keywords."
  }
  $iconRelativePath = Assert-RelativePackagePath -Path ([string]$packageJson.icon) -Name "VSIX package icon"
  if (-not $iconRelativePath.EndsWith(".png", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "VSIX package icon must point to a PNG file: $iconRelativePath"
  }
  Assert-ZipContains -Entries $entries -EntryName "extension/$iconRelativePath"
  [pscustomobject]@{
    packageJson = $packageJson
    manifestMetadata = $manifestMetadata
  }
}

$packageRootResolved = Assert-Directory $PackageRoot "PackageRoot"
$distRootResolved = Assert-Directory $ExtensionDistDirectory "ExtensionDistDirectory"
$readmeResolved = Assert-File $ReadmePath "ReadmePath"
$licenseResolved = Assert-File $LicensePath "LicensePath"
$changelogResolved = Assert-File $ChangelogPath "ChangelogPath"
$supportResolved = Assert-File $SupportPath "SupportPath"
$workRootResolved = Assert-GeneratedPath -Path $WorkRoot -Name "WorkRoot" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\vsix-package")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-vsix-scripts"))
) -Description "target/vsix-package or target/tests/release-vsix-scripts"
$outputRootResolved = Assert-GeneratedPath -Path $OutputRoot -Name "OutputRoot" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\vsix")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-vsix-scripts"))
) -Description "target/vsix or target/tests/release-vsix-scripts"
$evidencePathResolved = Assert-GeneratedPath -Path $EvidencePath -Name "EvidencePath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-vsix-scripts"))
) -Description "target/release-evidence or target/tests/release-vsix-scripts"

$extensionEntrypointPath = Assert-File (Join-Path $distRootResolved "extension.js") "dist/extension.js"
$extensionEntrypointSha256 = (Get-FileHash -LiteralPath $extensionEntrypointPath -Algorithm SHA256).Hash.ToLowerInvariant()
$readmeSha256 = (Get-FileHash -LiteralPath $readmeResolved -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-NoCompiledTestArtifacts $distRootResolved

& $verifyLayoutScript -Target $Target -PackageRoot $packageRootResolved

$packageJson = Get-Content -Raw -LiteralPath (Join-Path $packageRootResolved "package.json") | ConvertFrom-Json
if ($packageJson.name -ne "subversionr" -or $packageJson.publisher -ne "hitsuki-ban") {
  throw "PackageRoot extension identity must be hitsuki-ban.subversionr."
}
if ($packageJson.main -ne "./dist/extension.js") {
  throw "PackageRoot package.json main must be ./dist/extension.js."
}
$version = [string]$packageJson.version
if ([string]::IsNullOrWhiteSpace($version)) {
  throw "PackageRoot package.json version is required."
}

$workingPackageRoot = Join-Path $workRootResolved "subversionr-$Target"
if (Test-Path -LiteralPath $workingPackageRoot) {
  Remove-Item -LiteralPath $workingPackageRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $workingPackageRoot | Out-Null
Copy-DirectoryContents -SourceRoot $packageRootResolved -DestinationRoot $workingPackageRoot

$workingDistRoot = Join-Path $workingPackageRoot "dist"
if (Test-Path -LiteralPath $workingDistRoot) {
  Remove-Item -LiteralPath $workingDistRoot -Recurse -Force
}
Copy-Item -LiteralPath $distRootResolved -Destination $workingDistRoot -Recurse -Force
Copy-Item -LiteralPath $readmeResolved -Destination (Join-Path $workingPackageRoot "README.md") -Force
Copy-Item -LiteralPath $licenseResolved -Destination (Join-Path $workingPackageRoot "LICENSE") -Force
Copy-Item -LiteralPath $changelogResolved -Destination (Join-Path $workingPackageRoot "CHANGELOG.md") -Force
Copy-Item -LiteralPath $supportResolved -Destination (Join-Path $workingPackageRoot "SUPPORT.md") -Force

$vscodeIgnoreContent = @'
**/*.ts
**/*.map
src/**
tests/**
node_modules/**
target/**
.cache/**
*.vsix
'@
$vscodeIgnorePath = Join-Path $workingPackageRoot ".vscodeignore"
$vscodeIgnoreContent | Set-Content -LiteralPath $vscodeIgnorePath -NoNewline
$vscodeIgnoreSha256 = (Get-FileHash -LiteralPath $vscodeIgnorePath -Algorithm SHA256).Hash.ToLowerInvariant()

New-Item -ItemType Directory -Force -Path $outputRootResolved | Out-Null
$vsixPath = Join-Path $outputRootResolved "subversionr-$Target-$version.vsix"
if (Test-Path -LiteralPath $vsixPath) {
  Remove-Item -LiteralPath $vsixPath -Force
}

Push-Location $workingPackageRoot
try {
  & pnpm exec vsce package --target $Target --pre-release --ignore-other-target-folders --out $vsixPath --no-dependencies --allow-missing-repository --ignoreFile .vscodeignore
  if ($LASTEXITCODE -ne 0) {
    throw "vsce package failed with exit code $LASTEXITCODE."
  }
}
finally {
  Pop-Location
}

$vsixResolved = Assert-File $vsixPath "VSIX output"
Set-DeterministicZipTimestamps -ZipPath $vsixResolved
$vsixMetadata = Assert-VsixContents -VsixPath $vsixResolved -Target $Target
$vsixPackageJson = $vsixMetadata.packageJson
$vsixEntrypointSha256 = Get-ZipEntrySha256 -ZipPath $vsixResolved -EntryName "extension/dist/extension.js"
if ($vsixEntrypointSha256 -ne $extensionEntrypointSha256) {
  throw "VSIX compiled extension entrypoint hash must match ExtensionDistDirectory/dist/extension.js."
}
$vsixReadmeSha256 = Get-ZipEntrySha256 -ZipPath $vsixResolved -EntryName "extension/readme.md"
if ($vsixReadmeSha256 -ne $readmeSha256) {
  throw "VSIX Marketplace README hash must match the explicit ReadmePath input."
}
$iconRelativePath = Assert-RelativePackagePath -Path ([string]$vsixPackageJson.icon) -Name "VSIX package icon"
$inputIconPath = Assert-File (Join-Path $workingPackageRoot $iconRelativePath.Replace("/", [System.IO.Path]::DirectorySeparatorChar)) "Marketplace icon"
$inputIconSha256 = (Get-FileHash -LiteralPath $inputIconPath -Algorithm SHA256).Hash.ToLowerInvariant()
$vsixIconSha256 = Get-ZipEntrySha256 -ZipPath $vsixResolved -EntryName "extension/$iconRelativePath"
if ($vsixIconSha256 -ne $inputIconSha256) {
  throw "VSIX Marketplace icon hash must match the staged package icon."
}
$vsixItem = Get-Item -LiteralPath $vsixResolved

$report = [pscustomobject]@{
  schemaVersion = 1
  schema = "subversionr.release.vsix-package.win32-x64.v1"
  publicReadinessClaim = $false
  target = $Target
  traceIds = @("SEC-015", "MIG-009")
  extension = [pscustomobject]@{
    id = "$($vsixPackageJson.publisher).$($vsixPackageJson.name)"
    displayName = [string]$vsixPackageJson.displayName
    version = [string]$vsixPackageJson.version
    preRelease = [bool]$vsixMetadata.manifestMetadata.preRelease
  }
  inputs = [pscustomobject]@{
    packageRoot = Get-RepoRelativePath $packageRootResolved
    distRoot = Get-RepoRelativePath $distRootResolved
    extensionEntrypointSha256 = $extensionEntrypointSha256
    readmePath = Get-RepoRelativePath $readmeResolved
    readmeSha256 = $readmeSha256
    vscodeIgnoreSha256 = $vscodeIgnoreSha256
    changelogSha256 = (Get-FileHash -LiteralPath $changelogResolved -Algorithm SHA256).Hash.ToLowerInvariant()
    supportSha256 = (Get-FileHash -LiteralPath $supportResolved -Algorithm SHA256).Hash.ToLowerInvariant()
    marketplaceIcon = [pscustomobject]@{
      path = $iconRelativePath
      sha256 = $inputIconSha256
    }
  }
  vsix = [pscustomobject]@{
    path = $vsixResolved
    relativePath = Get-RepoRelativePath $vsixResolved
    size = $vsixItem.Length
    sha256 = (Get-FileHash -LiteralPath $vsixResolved -Algorithm SHA256).Hash.ToLowerInvariant()
    extensionEntrypointSha256 = $vsixEntrypointSha256
    readmeSha256 = $vsixReadmeSha256
    marketplaceIconSha256 = $vsixIconSha256
  }
  assertions = @(
    "vsce package ran with explicit target and no dependency detection",
    "compiled extension entrypoint is present",
    "compiled extension entrypoint hash matches the input dist artifact",
    "VSIX manifest declares Microsoft.VisualStudio.Code.PreRelease exactly once with Value=true",
    "all VSIX ZIP entry timestamps are normalized to 2000-01-01T00:00:00Z",
    "Marketplace listing README is present and hash-bound to the explicit ReadmePath input",
    "Marketplace icon is present and hash-bound in the VSIX",
    "packaged backend sidecar, bridge, and manifest are present",
    "TypeScript source, tests, node_modules, and SVN CLI fixture tools are absent",
    "publicReadinessClaim remains false"
  )
}

$evidenceParent = Split-Path -Parent $evidencePathResolved
New-Item -ItemType Directory -Force -Path $evidenceParent | Out-Null
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $evidencePathResolved -Encoding utf8

Write-Host "Packaged SubversionR VS Code VSIX for $Target at $vsixResolved."

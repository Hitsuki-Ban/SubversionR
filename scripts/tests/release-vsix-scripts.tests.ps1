$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$packageVsixScript = Join-Path $repoRoot "scripts\release\package-vscode-vsix.ps1"
$installVsixScript = Join-Path $repoRoot "scripts\release\test-vscode-cli-install-vsix.ps1"
$verifyLayoutScript = Join-Path $repoRoot "scripts\release\verify-vscode-package-layout.ps1"
$packageJsonPath = Join-Path $repoRoot "package.json"
$extensionPackageJsonPath = Join-Path $repoRoot "packages\vscode-extension\package.json"
$extensionReadmePath = Join-Path $repoRoot "packages\vscode-extension\README.md"
$extensionBuildTsconfigPath = Join-Path $repoRoot "packages\vscode-extension\tsconfig.build.json"
$ciWorkflowPath = Join-Path $repoRoot ".github\workflows\ci.yml"

Add-Type -AssemblyName System.IO.Compression.FileSystem

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

function Assert-NativeCommandFailsContaining([scriptblock]$Action, [string]$ExpectedText, [string]$Message) {
  $output = & $Action 2>&1
  $exitCode = $LASTEXITCODE
  Assert-True ($exitCode -ne 0) "$Message Expected native command to fail."
  $text = $output | Out-String
  Assert-True ($text.Contains($ExpectedText)) "$Message Expected output to contain '$ExpectedText', got '$text'."
}

function Assert-ZipContains([string]$ZipPath, [string]$EntryName, [string]$Message) {
  $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
  try {
    $match = @($archive.Entries | Where-Object { $_.FullName -eq $EntryName })
    Assert-True ($match.Count -eq 1) $Message
  }
  finally {
    $archive.Dispose()
  }
}

function Assert-ZipDoesNotContainPattern([string]$ZipPath, [string]$Pattern, [string]$Message) {
  $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
  try {
    $matches = @($archive.Entries | Where-Object { $_.FullName -like $Pattern } | Select-Object -ExpandProperty FullName)
    Assert-True ($matches.Count -eq 0) "$Message Found: $($matches -join ', ')"
  }
  finally {
    $archive.Dispose()
  }
}

function Get-ZipEntryText([string]$ZipPath, [string]$EntryName) {
  $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
  try {
    $entries = @($archive.Entries | Where-Object { $_.FullName -eq $EntryName })
    Assert-True ($entries.Count -eq 1) "VSIX should contain exactly one $EntryName entry."
    $reader = [System.IO.StreamReader]::new($entries[0].Open())
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

function New-VsixPreReleaseManifestVariant([string]$SourcePath, [string]$DestinationPath, [AllowEmptyCollection()][string[]]$Values) {
  $parent = Split-Path -Parent $DestinationPath
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force

  $archive = [System.IO.Compression.ZipFile]::Open($DestinationPath, [System.IO.Compression.ZipArchiveMode]::Update)
  try {
    $entries = @($archive.Entries | Where-Object { $_.FullName -eq "extension.vsixmanifest" })
    Assert-True ($entries.Count -eq 1) "VSIX fixture should contain exactly one extension.vsixmanifest entry."
    $reader = [System.IO.StreamReader]::new($entries[0].Open())
    try {
      [xml]$manifest = $reader.ReadToEnd()
    }
    finally {
      $reader.Dispose()
    }

    $propertiesNodes = @($manifest.SelectNodes("//*[local-name()='PackageManifest']/*[local-name()='Metadata']/*[local-name()='Properties']"))
    Assert-True ($propertiesNodes.Count -eq 1) "VSIX fixture should contain exactly one Properties node."
    $propertiesNode = $propertiesNodes[0]
    $existingNodes = @($propertiesNode.SelectNodes("./*[local-name()='Property' and @Id='Microsoft.VisualStudio.Code.PreRelease']"))
    foreach ($node in $existingNodes) {
      $propertiesNode.RemoveChild($node) | Out-Null
    }
    foreach ($value in $Values) {
      $property = $manifest.CreateElement("Property", $propertiesNode.NamespaceURI)
      $property.SetAttribute("Id", "Microsoft.VisualStudio.Code.PreRelease")
      $property.SetAttribute("Value", $value)
      $propertiesNode.AppendChild($property) | Out-Null
    }

    $entries[0].Delete()
    $entry = $archive.CreateEntry("extension.vsixmanifest")
    $writer = [System.IO.StreamWriter]::new($entry.Open(), [System.Text.UTF8Encoding]::new($false))
    try {
      $manifest.Save($writer)
    }
    finally {
      $writer.Dispose()
    }
  }
  finally {
    $archive.Dispose()
  }
}

function New-FakePnpm([string]$Root) {
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  $scriptPath = Join-Path $Root "fake-pnpm.ps1"
  @'
$ErrorActionPreference = "Stop"
$argsList = @($args)
if ($argsList.Count -lt 3 -or $argsList[0] -ne "exec" -or $argsList[1] -ne "vsce" -or $argsList[2] -ne "package") {
  throw "Unsupported fake pnpm invocation: $($argsList -join ' ')"
}
if ($argsList -notcontains "--pre-release") {
  throw "vsce package must receive --pre-release."
}
$outIndex = $argsList.IndexOf("--out")
if ($outIndex -lt 0 -or $outIndex + 1 -ge $argsList.Count) {
  throw "vsce package --out is required."
}
if ([string]::IsNullOrWhiteSpace($env:SUBVERSIONR_FAKE_VSIX_SOURCE)) {
  throw "SUBVERSIONR_FAKE_VSIX_SOURCE is required."
}
Copy-Item -LiteralPath $env:SUBVERSIONR_FAKE_VSIX_SOURCE -Destination $argsList[$outIndex + 1] -Force
'@ | Set-Content -LiteralPath $scriptPath -NoNewline
  "@pwsh -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" %*" | Set-Content -LiteralPath (Join-Path $Root "pnpm.cmd") -NoNewline
}

function Assert-InvalidPreReleaseManifestFails(
  [string]$CaseName,
  [AllowEmptyCollection()][string[]]$Values,
  [string]$ExpectedText,
  [string]$SourceVsix,
  [string]$TempRoot,
  [string]$PackageRoot,
  [string]$DistRoot,
  [string]$ReadmePath
) {
  $variantPath = Join-Path $TempRoot "$CaseName-source.vsix"
  New-VsixPreReleaseManifestVariant -SourcePath $SourceVsix -DestinationPath $variantPath -Values $Values
  $env:SUBVERSIONR_FAKE_VSIX_SOURCE = $variantPath
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $packageVsixScript `
      -Target win32-x64 `
      -PackageRoot $PackageRoot `
      -ExtensionDistDirectory $DistRoot `
      -ReadmePath $ReadmePath `
      -LicensePath LICENSE `
      -ChangelogPath CHANGELOG.md `
      -SupportPath SUPPORT.md `
      -WorkRoot (Join-Path $TempRoot "$CaseName-work") `
      -OutputRoot (Join-Path $TempRoot "$CaseName-output") `
      -EvidencePath (Join-Path $TempRoot "evidence\$CaseName.json")
  } $ExpectedText "VSIX packaging should reject the $CaseName pre-release manifest."
}

function Copy-TestFile([string]$Source, [string]$Destination) {
  $parent = Split-Path -Parent $Destination
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Write-TestPngIcon([string]$Path) {
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  Add-Type -AssemblyName System.Drawing
  $bitmap = [System.Drawing.Bitmap]::new(128, 128)
  try {
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
      $graphics.Clear([System.Drawing.Color]::FromArgb(47, 111, 115))
      $brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(245, 248, 250))
      try {
        $graphics.FillEllipse($brush, 30, 24, 68, 68)
        $graphics.FillRectangle($brush, 58, 58, 14, 42)
      }
      finally {
        $brush.Dispose()
      }
    }
    finally {
      $graphics.Dispose()
    }
    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  }
  finally {
    $bitmap.Dispose()
  }
}

function Get-ArtifactRecord([string]$PackageRoot, [string]$Path, [string]$Role) {
  $relativePath = [System.IO.Path]::GetRelativePath($PackageRoot, $Path).Replace("\", "/")
  $item = Get-Item -LiteralPath $Path
  [pscustomobject]@{
    role = $Role
    path = $relativePath
    size = $item.Length
    sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  }
}

function Write-PackageManifest([string]$PackageRoot, [string]$Target, [string]$Version) {
  $resourceRoot = Join-Path $PackageRoot "resources\backend\$Target"
  $artifacts = @()
  $artifacts += Get-ArtifactRecord -PackageRoot $PackageRoot -Path (Join-Path $resourceRoot "subversionr-daemon.exe") -Role "sidecar"
  $artifacts += Get-ArtifactRecord -PackageRoot $PackageRoot -Path (Join-Path $resourceRoot "subversionr_svn_bridge.dll") -Role "bridge"
  $artifacts += @(Get-ChildItem -LiteralPath $resourceRoot -File |
    Where-Object { $_.Name -notin @("subversionr-daemon.exe", "subversionr_svn_bridge.dll", "subversionr-backend-package-manifest.json") } |
    Sort-Object Name |
    ForEach-Object { Get-ArtifactRecord -PackageRoot $PackageRoot -Path $_.FullName -Role "nativeDependency" })
  $artifacts += @(Get-ChildItem -LiteralPath (Join-Path $resourceRoot "iconv") -File -Filter "*.so" |
    Sort-Object Name |
    ForEach-Object { Get-ArtifactRecord -PackageRoot $PackageRoot -Path $_.FullName -Role "nativeDependency" })

  [pscustomobject]@{
    schemaVersion = 1
    schema = "subversionr.vscode.backend-package.win32-x64.v1"
    layoutKind = "staged-vsix-layout"
    target = $Target
    vsceTarget = $Target
    architecture = "x64"
    configuration = "Release"
    extension = [pscustomobject]@{
      id = "subversionr"
      displayName = "SVN-R"
      version = $Version
    }
    resourceRoot = "resources/backend/$Target"
    artifacts = $artifacts
    sourceLocks = @(
      [pscustomobject]@{
        name = "apache-subversion"
        version = "1.14.5"
        license = "Apache-2.0"
        sha512 = "subversion-sha512"
      }
    )
    nonPackagedTools = @("svn.exe", "svnadmin.exe", "svnserve.exe", "svnversion.exe")
    ignoredNativeRuntimeFiles = @()
  } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $resourceRoot "subversionr-backend-package-manifest.json") -Encoding utf8
}

function New-StagedPackageFixture([string]$PackageRoot, [string]$Version) {
  $target = "win32-x64"
  $resourceRoot = Join-Path $PackageRoot "resources\backend\$target"
  New-Item -ItemType Directory -Force -Path (Join-Path $PackageRoot "l10n") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $resourceRoot "iconv") | Out-Null
  Write-TestPngIcon (Join-Path $PackageRoot "resources\marketplace\icon.png")

  @"
{
  "name": "subversionr",
  "displayName": "SVN-R",
  "description": "SubversionR test package",
  "version": "$Version",
  "publisher": "hitsuki-ban",
  "license": "MIT",
  "engines": {
    "vscode": "^1.101.0"
  },
  "categories": ["SCM Providers"],
  "keywords": ["svn", "subversion", "source-control", "scm", "apache-subversion"],
  "icon": "resources/marketplace/icon.png",
  "activationEvents": ["onCommand:subversionr.initialize"],
  "main": "./dist/extension.js",
  "l10n": "./l10n",
  "contributes": {
    "commands": [
      {
        "command": "subversionr.initialize",
        "title": "Initialize SubversionR"
      }
    ]
  },
  "scripts": {
    "check": "tsc -p tsconfig.json --noEmit"
  },
  "devDependencies": {}
}
"@ | Set-Content -LiteralPath (Join-Path $PackageRoot "package.json") -NoNewline
  "{}" | Set-Content -LiteralPath (Join-Path $PackageRoot "package.nls.json") -NoNewline
  "{}" | Set-Content -LiteralPath (Join-Path $PackageRoot "package.nls.ja.json") -NoNewline
  "{}" | Set-Content -LiteralPath (Join-Path $PackageRoot "package.nls.zh-cn.json") -NoNewline
  "{}" | Set-Content -LiteralPath (Join-Path $PackageRoot "l10n\bundle.l10n.json") -NoNewline
  "{}" | Set-Content -LiteralPath (Join-Path $PackageRoot "l10n\bundle.l10n.ja.json") -NoNewline
  "{}" | Set-Content -LiteralPath (Join-Path $PackageRoot "l10n\bundle.l10n.zh-cn.json") -NoNewline

  $peExeSource = Join-Path $env:WINDIR "System32\cmd.exe"
  $peDllSource = Join-Path $env:WINDIR "System32\kernel32.dll"
  Assert-True (Test-Path -LiteralPath $peExeSource -PathType Leaf) "Test fixture requires the Windows x64 cmd.exe PE file."
  Assert-True (Test-Path -LiteralPath $peDllSource -PathType Leaf) "Test fixture requires the Windows x64 kernel32.dll PE file."

  Copy-TestFile $peExeSource (Join-Path $resourceRoot "subversionr-daemon.exe")
  Copy-TestFile $peDllSource (Join-Path $resourceRoot "subversionr_svn_bridge.dll")
  foreach ($dependencyName in @(
    "libsvn_client-1.dll",
    "libsvn_delta-1.dll",
    "libsvn_diff-1.dll",
    "libsvn_fs-1.dll",
    "libsvn_fs_fs-1.dll",
    "libsvn_fs_util-1.dll",
    "libsvn_fs_x-1.dll",
    "libsvn_ra-1.dll",
    "libsvn_repos-1.dll",
    "libsvn_subr-1.dll",
    "libsvn_wc-1.dll",
    "libapr-1.dll",
    "libapriconv-1.dll",
    "libaprutil-1.dll",
    "libexpat.dll",
    "libcrypto-3-x64.dll",
    "libssl-3-x64.dll"
  )) {
    Copy-TestFile $peDllSource (Join-Path $resourceRoot $dependencyName)
  }
  Copy-TestFile $peDllSource (Join-Path $resourceRoot "iconv\utf-8.so")
  Write-PackageManifest -PackageRoot $PackageRoot -Target $target -Version $Version
}

function New-ExtensionDistFixture([string]$DistRoot) {
  New-Item -ItemType Directory -Force -Path $DistRoot | Out-Null
  @'
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.activate = activate;
exports.deactivate = deactivate;
function activate() {}
function deactivate() {}
'@ | Set-Content -LiteralPath (Join-Path $DistRoot "extension.js") -NoNewline
}

function New-FakeCodeCli([string]$Path) {
  $scriptPath = Join-Path (Split-Path -Parent $Path) "fake-code.ps1"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  @'
$ErrorActionPreference = "Stop"
$argsList = @($args)
if ($argsList -contains "--version") {
  "1.126.0"
  "subversionr-fixture-commit"
  "x64"
  exit 0
}
$extensionsDir = $argsList[($argsList.IndexOf("--extensions-dir") + 1)]
if ([string]::IsNullOrWhiteSpace($extensionsDir)) {
  throw "--extensions-dir is required by this fixture."
}
if ($argsList -contains "--install-extension") {
  $vsixPath = $argsList[($argsList.IndexOf("--install-extension") + 1)]
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [System.IO.Compression.ZipFile]::OpenRead($vsixPath)
  try {
    $packageEntry = $archive.Entries | Where-Object { $_.FullName -eq "extension/package.json" } | Select-Object -First 1
    $reader = [System.IO.StreamReader]::new($packageEntry.Open())
    try {
      $packageJson = $reader.ReadToEnd() | ConvertFrom-Json
    }
    finally {
      $reader.Dispose()
    }
  }
  finally {
    $archive.Dispose()
  }
  $extensionId = "$($packageJson.publisher).$($packageJson.name)"
  $destination = Join-Path $extensionsDir "$extensionId-$($packageJson.version)"
  New-Item -ItemType Directory -Force -Path $destination | Out-Null
  [System.IO.Compression.ZipFile]::ExtractToDirectory($vsixPath, $destination)
  $extensionRoot = Join-Path $destination "extension"
  Get-ChildItem -LiteralPath $extensionRoot -Force | Move-Item -Destination $destination
  Remove-Item -LiteralPath $extensionRoot -Recurse -Force
  exit 0
}
if ($argsList -contains "--list-extensions") {
  Get-ChildItem -LiteralPath $extensionsDir -Directory | ForEach-Object {
    $packageJson = Get-Content -Raw -LiteralPath (Join-Path $_.FullName "package.json") | ConvertFrom-Json
    "$($packageJson.publisher).$($packageJson.name)@$($packageJson.version)"
  }
  exit 0
}
throw "Unsupported fake code CLI invocation: $($argsList -join ' ')"
'@ | Set-Content -LiteralPath $scriptPath -NoNewline
  "@pwsh -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" %*" | Set-Content -LiteralPath $Path -NoNewline
}

$tempRoot = Join-Path $repoRoot "target\tests\release-vsix-scripts\$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  Assert-True (Test-Path -LiteralPath $packageVsixScript -PathType Leaf) "package-vscode-vsix.ps1 should exist."
  Assert-True (Test-Path -LiteralPath $installVsixScript -PathType Leaf) "test-vscode-cli-install-vsix.ps1 should exist."
  Assert-True (Test-Path -LiteralPath $extensionReadmePath -PathType Leaf) "VS Code extension Marketplace README should exist."
  Assert-True (Test-Path -LiteralPath $extensionBuildTsconfigPath -PathType Leaf) "VS Code extension build tsconfig should exist."

  $extensionReadme = Get-Content -Raw -LiteralPath $extensionReadmePath
  $extensionReadmeSha256 = (Get-FileHash -LiteralPath $extensionReadmePath -Algorithm SHA256).Hash.ToLowerInvariant()
  Assert-True ($extensionReadme.Contains('Windows x64 (`win32-x64`)')) "Marketplace README should state the Windows win32-x64 Beta boundary."
  Assert-True ($extensionReadme.Contains('local `file://` repositories')) "Marketplace README should state the local-file Beta boundary."
  Assert-True ($extensionReadme.Contains("Install Pre-Release Version")) "Marketplace README should explain pre-release installation."
  Assert-True ($extensionReadme.Contains("https://github.com/Hitsuki-Ban/SubversionR/issues")) "Marketplace README should link to GitHub support."
  Assert-True ($extensionReadme.Contains("https://github.com/Hitsuki-Ban/SubversionR/security/policy")) "Marketplace README should link to the GitHub security policy."
  Assert-True ($extensionReadme -notmatch '(?i)\.svg(?:\b|[?#])') "Marketplace README must not reference SVG content."
  Assert-True ($extensionReadme -notmatch '!\[') "Marketplace README must not contain images."

  $extensionPackage = Get-Content -Raw -LiteralPath $extensionPackageJsonPath | ConvertFrom-Json
  Assert-Equal "tsc -p tsconfig.build.json" $extensionPackage.scripts.build "VS Code extension should expose a release build script."

  $rootPackage = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  Assert-Equal "0.2.4" $rootPackage.version "Root package should declare the current 0.2.4 candidate version."
  Assert-True ($null -ne $rootPackage.devDependencies."@vscode/vsce") "Root devDependencies should pin @vscode/vsce."
  Assert-True ($rootPackage.scripts."release:test-vsix-scripts".Contains("release-vsix-scripts.tests.ps1")) "Root package should expose M7g VSIX script tests."
  Assert-True ($rootPackage.scripts."release:build-vscode-extension".Contains("--filter ./packages/vscode-extension build")) "Root package should expose the extension release build."
  Assert-True ($rootPackage.scripts."release:package-vsix:win32-x64".Contains("package-vscode-vsix.ps1")) "Root package should expose the win32-x64 VSIX package gate."
  Assert-True ($rootPackage.scripts."release:package-vsix:win32-x64".Contains("-ReadmePath packages/vscode-extension/README.md")) "Production VSIX packaging should use the dedicated Marketplace listing README."
  Assert-True ((Get-Content -Raw -LiteralPath $packageVsixScript).Contains("vsce package --target `$Target --pre-release")) "Production VSIX packaging should pass --pre-release to vsce."
  Assert-True ($rootPackage.scripts."release:test-vsix-cli-install:win32-x64".Contains("test-vscode-cli-install-vsix.ps1")) "Root package should expose the win32-x64 VSIX CLI install gate."
  Assert-True ($rootPackage.scripts."release:test-vsix-cli-install:win32-x64".Contains("%SUBVERSIONR_CODE_CLI%")) "VSIX CLI install gate should require an explicit Code CLI path."

  $packageRoot = Join-Path $tempRoot "staged-package"
  $distRoot = Join-Path $tempRoot "dist"
  $workRoot = Join-Path $tempRoot "vsix-work"
  $outputRoot = Join-Path $tempRoot "vsix"
  $evidencePath = Join-Path $tempRoot "evidence\vsix-package.json"
  New-StagedPackageFixture -PackageRoot $packageRoot -Version "0.2.0"
  New-ExtensionDistFixture -DistRoot $distRoot

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyLayoutScript -Target win32-x64 -PackageRoot $packageRoot
  if ($LASTEXITCODE -ne 0) {
    throw "verify-vscode-package-layout.ps1 failed for the VSIX package fixture."
  }

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $packageVsixScript `
    -Target win32-x64 `
    -PackageRoot $packageRoot `
    -ExtensionDistDirectory $distRoot `
    -ReadmePath $extensionReadmePath `
    -LicensePath LICENSE `
    -ChangelogPath CHANGELOG.md `
    -SupportPath SUPPORT.md `
    -WorkRoot $workRoot `
    -OutputRoot $outputRoot `
    -EvidencePath $evidencePath
  if ($LASTEXITCODE -ne 0) {
    throw "package-vscode-vsix.ps1 failed with exit code $LASTEXITCODE."
  }

  $report = Get-Content -Raw -LiteralPath $evidencePath | ConvertFrom-Json
  Assert-Equal "subversionr.release.vsix-package.win32-x64.v1" $report.schema "VSIX package evidence should use the M7g schema."
  Assert-Equal "False" ([string]$report.publicReadinessClaim) "VSIX package evidence must not claim public readiness."
  Assert-Equal "win32-x64" $report.target "VSIX package evidence should record the VS Code target."
  Assert-Equal "True" ([string]$report.extension.preRelease) "VSIX package evidence should record preRelease=true."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "MIG-009" }).Count -eq 1) "VSIX package evidence should trace MIG-009."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "SEC-015" }).Count -eq 1) "VSIX package evidence should trace SEC-015."
  Assert-True (Test-Path -LiteralPath $report.vsix.path -PathType Leaf) "VSIX package evidence should point to an existing VSIX."
  Assert-True ($report.vsix.sha256 -match '^[a-f0-9]{64}$') "VSIX package evidence should record a SHA256 hash."
  Assert-True ($report.inputs.extensionEntrypointSha256 -match '^[a-f0-9]{64}$') "VSIX package evidence should record the input entrypoint hash."
  Assert-Equal $report.inputs.extensionEntrypointSha256 $report.vsix.extensionEntrypointSha256 "VSIX package evidence should prove entrypoint hash continuity."
  Assert-Equal "packages/vscode-extension/README.md" $report.inputs.readmePath "VSIX package evidence should record the explicit Marketplace README input path."
  Assert-Equal $extensionReadmeSha256 $report.inputs.readmeSha256 "VSIX package evidence should record the Marketplace README input hash."
  Assert-Equal $extensionReadmeSha256 $report.vsix.readmeSha256 "VSIX package evidence should record the packaged Marketplace README hash."
  Assert-Equal $report.inputs.readmeSha256 $report.vsix.readmeSha256 "VSIX package evidence should prove Marketplace README hash continuity."
  Assert-True ($report.inputs.vscodeIgnoreSha256 -match '^[a-f0-9]{64}$') "VSIX package evidence should record the generated .vscodeignore hash."
  Assert-True ($report.inputs.changelogSha256 -match '^[a-f0-9]{64}$') "VSIX package evidence should record the CHANGELOG hash."
  Assert-True ($report.inputs.supportSha256 -match '^[a-f0-9]{64}$') "VSIX package evidence should record the SUPPORT hash."
  Assert-Equal "resources/marketplace/icon.png" $report.inputs.marketplaceIcon.path "VSIX package evidence should record the Marketplace icon path."
  Assert-True ($report.inputs.marketplaceIcon.sha256 -match '^[a-f0-9]{64}$') "VSIX package evidence should record the Marketplace icon hash."
  Assert-Equal $report.inputs.marketplaceIcon.sha256 $report.vsix.marketplaceIconSha256 "VSIX package evidence should prove Marketplace icon hash continuity."
  Assert-True (@($report.assertions | Where-Object { $_ -eq "VSIX manifest declares Microsoft.VisualStudio.Code.PreRelease exactly once with Value=true" }).Count -eq 1) "VSIX package evidence should assert the exact pre-release manifest property."
  Assert-True (@($report.assertions | Where-Object { $_ -eq "all VSIX ZIP entry timestamps are normalized to 2000-01-01T00:00:00Z" }).Count -eq 1) "VSIX package evidence should assert deterministic ZIP timestamps."

  $vsixPath = $report.vsix.path
  $firstVsixSha256 = (Get-FileHash -LiteralPath $vsixPath -Algorithm SHA256).Hash.ToLowerInvariant()
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $packageVsixScript `
    -Target win32-x64 `
    -PackageRoot $packageRoot `
    -ExtensionDistDirectory $distRoot `
    -ReadmePath $extensionReadmePath `
    -LicensePath LICENSE `
    -ChangelogPath CHANGELOG.md `
    -SupportPath SUPPORT.md `
    -WorkRoot $workRoot `
    -OutputRoot $outputRoot `
    -EvidencePath $evidencePath
  if ($LASTEXITCODE -ne 0) {
    throw "Second package-vscode-vsix.ps1 run failed with exit code $LASTEXITCODE."
  }
  Assert-Equal $firstVsixSha256 ((Get-FileHash -LiteralPath $vsixPath -Algorithm SHA256).Hash.ToLowerInvariant()) "Repeated VSIX packaging should produce identical bytes."

  Assert-ZipContains $vsixPath "extension/package.json" "VSIX should contain extension/package.json."
  Assert-ZipContains $vsixPath "extension.vsixmanifest" "VSIX should contain the VSIX manifest."
  Assert-ZipContains $vsixPath "extension/dist/extension.js" "VSIX should contain the compiled extension entrypoint."
  Assert-ZipContains $vsixPath "extension/resources/backend/win32-x64/subversionr-daemon.exe" "VSIX should contain the packaged sidecar."
  Assert-ZipContains $vsixPath "extension/resources/backend/win32-x64/subversionr_svn_bridge.dll" "VSIX should contain the packaged bridge."
  Assert-ZipContains $vsixPath "extension/resources/backend/win32-x64/subversionr-backend-package-manifest.json" "VSIX should contain the backend manifest."
  Assert-ZipContains $vsixPath "extension/readme.md" "VSIX should contain the normalized README."
  Assert-ZipContains $vsixPath "extension/LICENSE.txt" "VSIX should contain the normalized license."
  Assert-ZipContains $vsixPath "extension/CHANGELOG.md" "VSIX should contain the changelog."
  Assert-ZipContains $vsixPath "extension/SUPPORT.md" "VSIX should contain the support document."
  Assert-ZipContains $vsixPath "extension/resources/marketplace/icon.png" "VSIX should contain the Marketplace icon."
  [xml]$vsixManifest = Get-ZipEntryText -ZipPath $vsixPath -EntryName "extension.vsixmanifest"
  $preReleaseNodes = @($vsixManifest.SelectNodes("//*[local-name()='PackageManifest']/*[local-name()='Metadata']/*[local-name()='Properties']/*[local-name()='Property' and @Id='Microsoft.VisualStudio.Code.PreRelease']"))
  Assert-True ($preReleaseNodes.Count -eq 1) "VSIX manifest should contain exactly one Microsoft.VisualStudio.Code.PreRelease property."
  Assert-True ([string]$preReleaseNodes[0].Value -ceq "true") "VSIX manifest pre-release property Value should be exactly true."
  $packagedReadme = Get-ZipEntryText -ZipPath $vsixPath -EntryName "extension/readme.md"
  Assert-Equal $extensionReadme $packagedReadme "VSIX should contain the explicit Marketplace listing README content."
  Assert-True ($packagedReadme -notmatch '(?i)\.svg(?:\b|[?#])') "Packaged Marketplace README must not reference SVG content."
  Assert-ZipDoesNotContainPattern $vsixPath "extension/src/*" "VSIX must not package TypeScript source."
  Assert-ZipDoesNotContainPattern $vsixPath "extension/tests/*" "VSIX must not package tests."
  Assert-ZipDoesNotContainPattern $vsixPath "extension/node_modules/*" "VSIX must not package node_modules for the current dependency-free extension."
  Assert-ZipDoesNotContainPattern $vsixPath "extension/**/svn.exe" "VSIX must not package SVN CLI fixture tools."

  $installFixtureRoot = Join-Path $tempRoot "cli-install\win32-x64"
  $installEvidencePath = Join-Path $tempRoot "evidence\vsix-cli-install.json"
  $fakeCodeCliPath = Join-Path $tempRoot "fake-code\code.cmd"
  New-FakeCodeCli -Path $fakeCodeCliPath
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $installVsixScript `
    -Target win32-x64 `
    -VsixPath $vsixPath `
    -CodeCliPath $fakeCodeCliPath `
    -FixtureRoot $installFixtureRoot `
    -EvidencePath $installEvidencePath
  if ($LASTEXITCODE -ne 0) {
    throw "test-vscode-cli-install-vsix.ps1 failed with exit code $LASTEXITCODE."
  }
  $installReport = Get-Content -Raw -LiteralPath $installEvidencePath | ConvertFrom-Json
  Assert-Equal "subversionr.release.vsix-cli-install.win32-x64.v1" $installReport.schema "VSIX CLI install evidence should use the M7g schema."
  Assert-Equal "False" ([string]$installReport.publicReadinessClaim) "VSIX CLI install evidence must not claim public readiness."
  Assert-Equal "hitsuki-ban.subversionr" $installReport.extension.id "VSIX CLI install evidence should record the installed extension id."
  Assert-Equal "0.2.0" $installReport.extension.version "VSIX CLI install evidence should record the installed extension version."
  Assert-Equal $vsixPath $installReport.vsix.path "VSIX CLI install evidence should record the installed VSIX path."
  Assert-Equal "win32-x64" $installReport.vsix.targetPlatform "VSIX CLI install evidence should record the VSIX target platform."
  Assert-Equal ([string](Get-Item -LiteralPath $vsixPath).Length) ([string]$installReport.vsix.size) "VSIX CLI install evidence should record the installed VSIX size."
  Assert-Equal ((Get-FileHash -LiteralPath $vsixPath -Algorithm SHA256).Hash.ToLowerInvariant()) $installReport.vsix.sha256 "VSIX CLI install evidence should record the installed VSIX SHA256."
  Assert-Equal "none" $installReport.workingCopySentinel.mutation "VSIX CLI install should not mutate the working-copy sentinel."
  Assert-Equal $installReport.hashes.vsixEntrypointSha256 $installReport.hashes.installedEntrypointSha256 "VSIX CLI install should prove installed entrypoint hash continuity."
  Assert-Equal $installReport.workingCopySentinel.svnTreeBeforeSha256 $installReport.workingCopySentinel.svnTreeAfterSha256 "VSIX CLI install should prove recursive .svn tree non-mutation."
  Assert-True ($installReport.codeCli.sha256 -match '^[a-f0-9]{64}$') "VSIX CLI install evidence should record the Code CLI file hash."
  Assert-True (@($installReport.traceIds | Where-Object { $_ -eq "TST-024" }).Count -eq 1) "VSIX CLI install evidence should trace TST-024."
  Assert-True (@($installReport.installedExtensions | Where-Object { $_ -eq "hitsuki-ban.subversionr@0.2.0" }).Count -eq 1) "VSIX CLI install should list the installed extension."

  $fakePnpmRoot = Join-Path $tempRoot "fake-pnpm"
  New-FakePnpm -Root $fakePnpmRoot
  $originalPath = $env:PATH
  try {
    $env:PATH = "$fakePnpmRoot;$originalPath"
    Assert-InvalidPreReleaseManifestFails `
      -CaseName "missing-pre-release" `
      -Values @() `
      -ExpectedText "must contain exactly one Microsoft.VisualStudio.Code.PreRelease property" `
      -SourceVsix $vsixPath `
      -TempRoot $tempRoot `
      -PackageRoot $packageRoot `
      -DistRoot $distRoot `
      -ReadmePath $extensionReadmePath
    Assert-InvalidPreReleaseManifestFails `
      -CaseName "duplicate-pre-release" `
      -Values @("true", "true") `
      -ExpectedText "must contain exactly one Microsoft.VisualStudio.Code.PreRelease property" `
      -SourceVsix $vsixPath `
      -TempRoot $tempRoot `
      -PackageRoot $packageRoot `
      -DistRoot $distRoot `
      -ReadmePath $extensionReadmePath
    Assert-InvalidPreReleaseManifestFails `
      -CaseName "non-true-pre-release" `
      -Values @("True") `
      -ExpectedText "Value must be exactly 'true'" `
      -SourceVsix $vsixPath `
      -TempRoot $tempRoot `
      -PackageRoot $packageRoot `
      -DistRoot $distRoot `
      -ReadmePath $extensionReadmePath
  }
  finally {
    $env:PATH = $originalPath
    Remove-Item Env:SUBVERSIONR_FAKE_VSIX_SOURCE -ErrorAction SilentlyContinue
  }

  $missingDistRoot = Join-Path $tempRoot "missing-dist"
  New-Item -ItemType Directory -Force -Path $missingDistRoot | Out-Null
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $packageVsixScript `
      -Target win32-x64 `
      -PackageRoot $packageRoot `
      -ExtensionDistDirectory $missingDistRoot `
      -ReadmePath $extensionReadmePath `
      -LicensePath LICENSE `
      -ChangelogPath CHANGELOG.md `
      -SupportPath SUPPORT.md `
      -WorkRoot (Join-Path $tempRoot "missing-dist-work") `
      -OutputRoot (Join-Path $tempRoot "missing-dist-vsix") `
      -EvidencePath (Join-Path $tempRoot "evidence\missing-dist.json")
  } "dist/extension.js" "VSIX packaging should fail fast when the compiled extension entrypoint is missing."

  $distWithTests = Join-Path $tempRoot "dist-with-tests"
  New-ExtensionDistFixture -DistRoot $distWithTests
  New-Item -ItemType Directory -Force -Path (Join-Path $distWithTests "tests") | Out-Null
  "throw new Error('test artifact');" | Set-Content -LiteralPath (Join-Path $distWithTests "tests\leak.test.js") -NoNewline
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $packageVsixScript `
      -Target win32-x64 `
      -PackageRoot $packageRoot `
      -ExtensionDistDirectory $distWithTests `
      -ReadmePath $extensionReadmePath `
      -LicensePath LICENSE `
      -ChangelogPath CHANGELOG.md `
      -SupportPath SUPPORT.md `
      -WorkRoot (Join-Path $tempRoot "dist-tests-work") `
      -OutputRoot (Join-Path $tempRoot "dist-tests-vsix") `
      -EvidencePath (Join-Path $tempRoot "evidence\dist-tests.json")
  } "compiled test artifacts" "VSIX packaging should reject compiled test artifacts."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $installVsixScript `
      -Target win32-x64 `
      -VsixPath $vsixPath `
      -CodeCliPath "%SUBVERSIONR_CODE_CLI%" `
      -FixtureRoot (Join-Path $tempRoot "literal-code-cli") `
      -EvidencePath (Join-Path $tempRoot "evidence\literal-code-cli.json")
  } "CodeCliPath must be an explicit file path" "VSIX CLI install should reject unresolved environment placeholder paths."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $installVsixScript `
      -Target win32-x64 `
      -VsixPath $vsixPath `
      -CodeCliPath $fakeCodeCliPath `
      -FixtureRoot (Join-Path $env:TEMP "subversionr-vsix-cli-outside-target") `
      -EvidencePath (Join-Path $tempRoot "evidence\outside-target.json")
  } "FixtureRoot must resolve inside the repository target directory" "VSIX CLI install should refuse fixture roots outside target."

  $ciWorkflow = Get-Content -Raw -LiteralPath $ciWorkflowPath
  Assert-True ($ciWorkflow.Contains("Release VSIX script tests")) "CI should run M7g VSIX script tests."
  Assert-True ($ciWorkflow.Contains("Build VS Code extension JavaScript")) "CI should build extension JavaScript before VSIX packaging."
  Assert-True ($ciWorkflow.Contains("Package VS Code win32-x64 VSIX")) "CI should package the win32-x64 VSIX."
  Assert-True ($ciWorkflow.Contains("Locate VS Code CLI")) "CI should locate the VS Code CLI explicitly before install."
  Assert-True ($ciWorkflow.Contains("Test VS Code CLI VSIX install")) "CI should run the real VS Code CLI install gate."
  Assert-True ($ciWorkflow.Contains("target/vsix/subversionr-win32-x64-0.2.4.vsix")) "CI should upload the current 0.2.4 VSIX candidate."

  Write-Host "Release VSIX script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

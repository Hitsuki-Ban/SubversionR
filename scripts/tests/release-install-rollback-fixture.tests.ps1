$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$fixtureScript = Join-Path $repoRoot "scripts\release\test-vscode-install-rollback-fixture.ps1"
$packageJsonPath = Join-Path $repoRoot "package.json"
$ciWorkflowPath = Join-Path $repoRoot ".github\workflows\ci.yml"

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

function Assert-ContainsInOrder([string]$Text, [string[]]$Needles, [string]$Message) {
  $previousIndex = -1
  foreach ($needle in $Needles) {
    $currentIndex = $Text.IndexOf($needle, [System.StringComparison]::Ordinal)
    Assert-True ($currentIndex -ge 0) "$Message Missing '$needle'."
    Assert-True ($currentIndex -gt $previousIndex) "$Message '$needle' should appear after the previous checked step."
    $previousIndex = $currentIndex
  }
}

function Assert-NativeCommandFailsContaining([scriptblock]$Action, [string]$ExpectedText, [string]$Message) {
  $output = & $Action 2>&1
  $exitCode = $LASTEXITCODE
  Assert-True ($exitCode -ne 0) "$Message Expected native command to fail."
  $text = $output | Out-String
  Assert-True ($text.Contains($ExpectedText)) "$Message Expected output to contain '$ExpectedText', got '$text'."
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
  "version": "$Version",
  "publisher": "hitsuki-ban",
  "private": true,
  "keywords": ["svn", "subversion", "source-control", "scm", "apache-subversion"],
  "icon": "resources/marketplace/icon.png",
  "main": "./dist/extension.js"
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

$tempRoot = Join-Path $repoRoot "target\tests\release-install-rollback-fixture\$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  Assert-True (Test-Path -LiteralPath $fixtureScript -PathType Leaf) "test-vscode-install-rollback-fixture.ps1 should exist."

  $currentPackageRoot = Join-Path $tempRoot "packages\current"
  New-StagedPackageFixture -PackageRoot $currentPackageRoot -Version "0.2.0"
  $fixtureRoot = Join-Path $tempRoot "run"
  $evidencePath = Join-Path $tempRoot "evidence\install-rollback.json"

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $fixtureScript `
    -Target win32-x64 `
    -CurrentPackageRoot $currentPackageRoot `
    -SyntheticPreviousVersion "0.0.0-m7f.fixture" `
    -FixtureRoot $fixtureRoot `
    -EvidencePath $evidencePath
  if ($LASTEXITCODE -ne 0) {
    throw "test-vscode-install-rollback-fixture.ps1 failed with exit code $LASTEXITCODE."
  }

  Assert-True (Test-Path -LiteralPath $evidencePath -PathType Leaf) "Install rollback fixture should write an evidence report."
  $report = Get-Content -Raw -LiteralPath $evidencePath | ConvertFrom-Json
  Assert-Equal "subversionr.release.install-rollback-fixture.win32-x64.v1" $report.schema "Evidence schema should describe the M7f fixture."
  Assert-Equal "isolated-vscode-extension-directory" $report.fixtureKind "Evidence should name the isolated fixture type."
  Assert-Equal "False" ([string]$report.publicReadinessClaim) "Fixture evidence must not claim public readiness."
  Assert-Equal "win32-x64" $report.target "Evidence should record the VS Code platform target."
  Assert-Equal "hitsuki-ban.subversionr" $report.extension.id "Evidence should record the publisher-qualified extension id."
  Assert-Equal "0.2.0" $report.extension.currentVersion "Evidence should record the current package version."
  Assert-Equal "0.0.0-m7f.fixture" $report.extension.previousVersion "Evidence should record the synthetic previous version."
  foreach ($traceId in @("MIG-009", "MIG-010", "TST-024")) {
    Assert-True (@($report.traceIds | Where-Object { $_ -eq $traceId }).Count -eq 1) "Evidence should trace $traceId."
  }
  foreach ($phaseName in @("fresh-install", "upgrade", "rollback")) {
    $phase = @($report.phases | Where-Object { $_.name -eq $phaseName })
    Assert-True ($phase.Count -eq 1) "Evidence should contain phase $phaseName."
    Assert-Equal "passed" $phase[0].result "Phase $phaseName should pass."
    Assert-Equal "none" $phase[0].workingCopyMutation "Phase $phaseName should not mutate working copies."
  }
  $freshInstallPhase = @($report.phases | Where-Object { $_.name -eq "fresh-install" })[0]
  Assert-True ($null -eq $freshInstallPhase.fromVersion) "Fresh install evidence should record fromVersion as JSON null."
  Assert-Equal "none" $report.workingCopySentinel.mutation "Evidence should record working-copy sentinel non-mutation."
  Assert-Equal $report.workingCopySentinel.beforeSha256 $report.workingCopySentinel.afterSha256 "Working-copy sentinel hash should be unchanged."
  Assert-True ($report.workingCopySentinel.path.EndsWith("/.svn/wc.db", [System.StringComparison]::Ordinal)) "Evidence should identify the sentinel .svn/wc.db path."
  Assert-True ($report.assertions.Contains("no real VS Code user-data or extension directory was touched")) "Evidence should make the isolation assertion explicit."
  Assert-True ($report.assertions.Contains("working-copy sentinel .svn/wc.db hash was unchanged")) "Evidence should state working-copy non-mutation explicitly."
  Assert-True (Test-Path -LiteralPath (Join-Path $fixtureRoot "upgrade\extensions\hitsuki-ban.subversionr-0.0.0-m7f.fixture\package.json") -PathType Leaf) "Rollback should restore the synthetic previous extension directory."
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot "upgrade\extensions\hitsuki-ban.subversionr-0.2.0"))) "Rollback should remove the current extension directory from the upgrade fixture."

  $tamperedPackageRoot = Join-Path $tempRoot "packages\tampered"
  Copy-Item -LiteralPath $currentPackageRoot -Destination $tamperedPackageRoot -Recurse
  $daemonBytes = [System.IO.File]::ReadAllBytes((Join-Path $tamperedPackageRoot "resources\backend\win32-x64\subversionr-daemon.exe"))
  $daemonBytes[0] = $daemonBytes[0] -bxor 0xff
  [System.IO.File]::WriteAllBytes((Join-Path $tamperedPackageRoot "resources\backend\win32-x64\subversionr-daemon.exe"), $daemonBytes)
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $fixtureScript `
      -Target win32-x64 `
      -CurrentPackageRoot $tamperedPackageRoot `
      -SyntheticPreviousVersion "0.0.0-m7f.fixture" `
      -FixtureRoot (Join-Path $tempRoot "tampered-run") `
      -EvidencePath (Join-Path $tempRoot "evidence\tampered.json")
  } "sha256" "Fixture should fail when the current package manifest hash does not match the artifacts."

  $wrongPublisherPackageRoot = Join-Path $tempRoot "packages\wrong-publisher"
  Copy-Item -LiteralPath $currentPackageRoot -Destination $wrongPublisherPackageRoot -Recurse
  $wrongPublisherJsonPath = Join-Path $wrongPublisherPackageRoot "package.json"
  $wrongPublisherJson = Get-Content -Raw -LiteralPath $wrongPublisherJsonPath | ConvertFrom-Json
  $wrongPublisherJson.publisher = "other"
  $wrongPublisherJson | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $wrongPublisherJsonPath -Encoding utf8
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $fixtureScript `
      -Target win32-x64 `
      -CurrentPackageRoot $wrongPublisherPackageRoot `
      -SyntheticPreviousVersion "0.0.0-m7f.fixture" `
      -FixtureRoot (Join-Path $tempRoot "wrong-publisher-run") `
      -EvidencePath (Join-Path $tempRoot "evidence\wrong-publisher.json")
  } "Extension publisher must be hitsuki-ban" "Fixture should fail fast when the extension publisher does not match the release identity."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $fixtureScript `
      -Target win32-x64 `
      -CurrentPackageRoot $currentPackageRoot `
      -SyntheticPreviousVersion "0.2.0" `
      -FixtureRoot (Join-Path $tempRoot "same-version-run") `
      -EvidencePath (Join-Path $tempRoot "evidence\same-version.json")
  } "SyntheticPreviousVersion must differ" "Fixture should not treat the current package as an upgrade source."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $fixtureScript `
      -Target win32-x64 `
      -CurrentPackageRoot $currentPackageRoot `
      -SyntheticPreviousVersion "0.0.0-m7f.fixture" `
      -FixtureRoot (Join-Path $env:TEMP "subversionr-outside-target-fixture") `
      -EvidencePath (Join-Path $tempRoot "evidence\outside-target.json")
  } "FixtureRoot must resolve inside the repository target directory" "Fixture should refuse to delete or write outside target."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $fixtureScript `
      -Target win32-x64 `
      -CurrentPackageRoot $currentPackageRoot `
      -SyntheticPreviousVersion "0.0.0-m7f.fixture" `
      -FixtureRoot "target/vscode-package" `
      -EvidencePath (Join-Path $tempRoot "evidence\disallowed-fixture-root.json")
  } "target/release-evidence/install-rollback-fixture" "Fixture should refuse generated roots that are not dedicated install rollback fixture roots."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $fixtureScript `
      -Target win32-x64 `
      -CurrentPackageRoot $currentPackageRoot `
      -SyntheticPreviousVersion "0.0.0-m7f.fixture" `
      -FixtureRoot "target/release-evidence/install-rollback-fixture" `
      -EvidencePath (Join-Path $tempRoot "evidence\aggregate-fixture-root.json")
  } "dedicated child directory" "Fixture should refuse the aggregate release-evidence install rollback root."

  $embeddedFixtureRoot = Join-Path $tempRoot "embedded"
  $embeddedCurrentPackageRoot = Join-Path $embeddedFixtureRoot "current"
  New-Item -ItemType Directory -Force -Path $embeddedFixtureRoot | Out-Null
  Copy-Item -LiteralPath $currentPackageRoot -Destination $embeddedCurrentPackageRoot -Recurse
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $fixtureScript `
      -Target win32-x64 `
      -CurrentPackageRoot $embeddedCurrentPackageRoot `
      -SyntheticPreviousVersion "0.0.0-m7f.fixture" `
      -FixtureRoot $embeddedFixtureRoot `
      -EvidencePath (Join-Path $tempRoot "evidence\embedded-current.json")
  } "FixtureRoot must not contain CurrentPackageRoot" "Fixture should never clear a root containing the current package input."

  $missingManifestPackageRoot = Join-Path $tempRoot "packages\missing-manifest"
  Copy-Item -LiteralPath $currentPackageRoot -Destination $missingManifestPackageRoot -Recurse
  Remove-Item -LiteralPath (Join-Path $missingManifestPackageRoot "resources\backend\win32-x64\subversionr-backend-package-manifest.json") -Force
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $fixtureScript `
      -Target win32-x64 `
      -CurrentPackageRoot $missingManifestPackageRoot `
      -SyntheticPreviousVersion "0.0.0-m7f.fixture" `
      -FixtureRoot (Join-Path $tempRoot "missing-manifest-run") `
      -EvidencePath (Join-Path $tempRoot "evidence\missing-manifest.json")
  } "Backend package manifest" "Fixture should fail through the layout verifier when the backend manifest is missing."

  $packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  Assert-Equal "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/tests/release-install-rollback-fixture.tests.ps1" $packageJson.scripts."release:test-install-rollback-fixture" "Root package should expose the M7f fixture script tests."
  Assert-True ($packageJson.scripts."release:install-rollback:win32-x64".Contains("test-vscode-install-rollback-fixture.ps1")) "Root package should expose the win32-x64 install rollback fixture."
  Assert-True ($packageJson.scripts."release:install-rollback:win32-x64".Contains("-SyntheticPreviousVersion 0.0.0-m7f.fixture")) "Root package should make the synthetic previous fixture explicit."

  $ciWorkflow = Get-Content -Raw -LiteralPath $ciWorkflowPath
  Assert-True ($ciWorkflow.Contains("Release install rollback fixture tests")) "CI should run M7f script tests."
  Assert-True ($ciWorkflow.Contains("Test VS Code install upgrade rollback fixture")) "CI should run the M7f package fixture after staging."
  Assert-ContainsInOrder $ciWorkflow @(
    "Verify VS Code win32-x64 package layout",
    "Test VS Code install upgrade rollback fixture",
    "Rust native bridge integration test"
  ) "CI should run the install/upgrade/rollback fixture after package layout verification."

  Write-Host "Release install rollback fixture tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$workflowScript = Join-Path $repoRoot "scripts\release\test-vscode-installed-core-workflow.ps1"
$packageJsonPath = Join-Path $repoRoot "package.json"
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

function New-TestVsix([string]$Path, [string]$Version, [string]$TargetPlatform = "win32-x64") {
  $root = Join-Path (Split-Path -Parent $Path) "vsix-root"
  if (Test-Path -LiteralPath $root) {
    Remove-Item -LiteralPath $root -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path (Join-Path $root "extension\dist") | Out-Null
  @"
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Language="en-US" Id="hitsuki-ban.subversionr" Version="$Version" Publisher="hitsuki-ban" TargetPlatform="$TargetPlatform" />
    <DisplayName>SVN-R</DisplayName>
    <Description xml:space="preserve">SubversionR installed core workflow fixture</Description>
  </Metadata>
</PackageManifest>
"@ | Set-Content -LiteralPath (Join-Path $root "extension.vsixmanifest") -NoNewline
  @"
{
  "name": "subversionr",
  "publisher": "hitsuki-ban",
  "displayName": "SVN-R",
  "version": "$Version",
  "engines": { "vscode": "^1.101.0" },
  "main": "./dist/extension.js",
  "activationEvents": ["onCommand:subversionr.diagnostics.installedCoreWorkflowReport"]
}
"@ | Set-Content -LiteralPath (Join-Path $root "extension\package.json") -NoNewline
  "exports.activate = function() {}; exports.deactivate = function() {};" |
    Set-Content -LiteralPath (Join-Path $root "extension\dist\extension.js") -NoNewline
  [System.IO.Compression.ZipFile]::CreateFromDirectory($root, $Path)
}

function New-FakeCodeCli([string]$Path) {
  $scriptPath = Join-Path (Split-Path -Parent $Path) "fake-code.ps1"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  @'
$ErrorActionPreference = "Stop"
$argsList = @($args)
if ($argsList -contains "--version") {
  "1.126.0"
  "subversionr-installed-core-fixture"
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
$testArg = $argsList | Where-Object { $_ -eq "--extensionTestsPath" -or $_ -like "--extensionTestsPath=*" } | Select-Object -First 1
if ($null -eq $testArg) {
  throw "fake code CLI expected --extensionTestsPath for installed core workflow smoke."
}
if ($env:SUBVERSIONR_FAKE_CODE_HANG_EXTENSION_HOST -eq "1") {
  Start-Sleep -Seconds 60
}
$resultPath = $env:SUBVERSIONR_INSTALLED_CORE_RESULT
$extensionsRoot = $env:SUBVERSIONR_INSTALLED_CORE_EXTENSIONS_ROOT
$workingCopyRoot = $env:SUBVERSIONR_INSTALLED_CORE_WORKING_COPY
if ([string]::IsNullOrWhiteSpace($resultPath) -or [string]::IsNullOrWhiteSpace($extensionsRoot) -or [string]::IsNullOrWhiteSpace($workingCopyRoot)) {
  throw "required installed core workflow harness environment variables are missing."
}
$installedPackage = Get-ChildItem -LiteralPath $extensionsRoot -Directory |
  Where-Object { $_.Name -like "hitsuki-ban.subversionr-*" } |
  Select-Object -First 1
if ($null -eq $installedPackage) {
  throw "installed SubversionR package was not found by fake code CLI."
}
[pscustomobject]@{
  ok = $true
  phase = "complete"
  id = "hitsuki-ban.subversionr"
  version = "0.2.0"
  beforeActive = $true
  afterActive = $true
  extensionPath = $installedPackage.FullName
  source = "installed-vsix"
  invokedCommands = @(
    "subversionr.diagnostics.installedCoreWorkflowReport",
    "subversionr.diagnostics.versionReport"
  )
  hasInstalledCoreWorkflowReportCommand = $true
  workflowReport = [pscustomobject]@{
    kind = "subversionr.installedCoreWorkflowReport"
    generatedAt = "2026-06-25T00:00:00Z"
    extension = [pscustomobject]@{
      name = "subversionr"
      version = "0.2.0"
    }
    workspace = [pscustomobject]@{
      trusted = $true
      pathCase = "case-insensitive"
    }
    repository = [pscustomobject]@{
      repositoryId = "repo-uuid:$workingCopyRoot"
      epoch = 1
      identity = [pscustomobject]@{
        repositoryUuid = "fixture-repository-uuid"
        repositoryRootUrl = "file:///fixture/repo"
        workingCopyRoot = $workingCopyRoot
        workspaceScopeRoot = $workingCopyRoot
        format = 31
      }
    }
    backendWorkflow = [pscustomobject]@{
      repositoryOpen = $true
      statusSnapshot = $true
      scmProjection = $true
      sessionSource = "organic-activation"
      repositoryClosed = $false
    }
    projection = [pscustomobject]@{
      generation = 1
      count = 1
      groups = @(
        [pscustomobject]@{
          id = "changes"
          count = 1
          resources = @(
            [pscustomobject]@{
              path = "src/tracked.txt"
              source = "local"
              contextValue = "subversionr.changedFile"
              localStatus = "modified"
              nodeStatus = "modified"
            }
          )
        },
        [pscustomobject]@{
          id = "unversioned"
          count = 1
          resources = @(
            [pscustomobject]@{
              path = "scratch.txt"
              source = "local"
              contextValue = "subversionr.unversioned"
              localStatus = "unversioned"
              nodeStatus = "unversioned"
            }
          )
        }
      )
    }
  }
  versionReport = [pscustomobject]@{
    kind = "subversionr.versionReport"
    extension = [pscustomobject]@{
      name = "subversionr"
      version = "0.2.0"
    }
    backend = [pscustomobject]@{
      status = "initialized"
      libsvnVersion = "1.14.5"
      capabilities = [pscustomobject]@{
        repositoryOpen = $true
        statusSnapshot = $true
        statusRefresh = $true
        statusRemoteCheck = $true
        realLibsvnBridge = $true
      }
    }
  }
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resultPath -Encoding utf8
exit 0
'@ | Set-Content -LiteralPath $scriptPath -NoNewline
  "@pwsh -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" %*" | Set-Content -LiteralPath $Path -NoNewline
}

function New-FakeSvnTools([string]$Root, [string]$Version = "1.14.5") {
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  $cscCandidates = @(
    (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
    (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
  )
  $csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  if ([string]::IsNullOrWhiteSpace($csc)) {
    throw "release-installed-core-workflow-scripts.tests.ps1 requires csc.exe to build fake svn.exe and svnadmin.exe."
  }
  $source = @"
using System;
using System.IO;
using System.Linq;

public static class Program {
  public static int Main(string[] args) {
    try {
      var exe = Path.GetFileName(Environment.GetCommandLineArgs()[0]).ToLowerInvariant();
      if (args.Length >= 2 && args[0] == "--version" && args[1] == "--quiet") {
        Console.WriteLine("$Version");
        return 0;
      }
      if (exe == "svnadmin.exe" && args.Length >= 2 && args[0] == "create") {
        Directory.CreateDirectory(args[1]);
        File.WriteAllText(Path.Combine(args[1], "format"), "SubversionR fake fixture repository");
        return 0;
      }
      if (exe == "svn.exe" && args.Length >= 1 && args[0] == "import") {
        return 0;
      }
      if (exe == "svn.exe" && args.Length >= 3 && args[0] == "checkout") {
        var wcRoot = args[2];
        Directory.CreateDirectory(Path.Combine(wcRoot, "src"));
        Directory.CreateDirectory(Path.Combine(wcRoot, ".svn"));
        File.WriteAllText(Path.Combine(wcRoot, "src", "tracked.txt"), "initial\n");
        File.WriteAllText(Path.Combine(wcRoot, ".svn", "wc.db"), "SubversionR fake wc metadata\n");
        return 0;
      }
      Console.Error.WriteLine("Unsupported fake SVN invocation: " + exe + " " + string.Join(" ", args));
      return 2;
    } catch (Exception ex) {
      Console.Error.WriteLine(ex.ToString());
      return 1;
    }
  }
}
"@
  $toolAssembly = Join-Path $Root "fake-svn-tool.exe"
  $sourcePath = Join-Path $Root "fake-svn-tool.cs"
  Set-Content -LiteralPath $sourcePath -Value $source -Encoding utf8
  $compileOutput = @(& $csc /nologo /target:exe /out:$toolAssembly $sourcePath 2>&1)
  if ($LASTEXITCODE -ne 0) {
    $text = $compileOutput | Out-String
    throw "Failed to compile fake SVN tools. $text"
  }
  Copy-Item -LiteralPath $toolAssembly -Destination (Join-Path $Root "svn.exe") -Force
  Copy-Item -LiteralPath $toolAssembly -Destination (Join-Path $Root "svnadmin.exe") -Force
}

$tempRoot = Join-Path $repoRoot "target\tests\release-installed-core-workflow-scripts\space root $([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  Assert-True (Test-Path -LiteralPath $workflowScript -PathType Leaf) "test-vscode-installed-core-workflow.ps1 should exist."

  $rootPackage = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  Assert-True ($rootPackage.scripts."release:test-installed-core-workflow-scripts".Contains("release-installed-core-workflow-scripts.tests.ps1")) "Root package should expose M7i installed-core script tests."
  Assert-True ($rootPackage.scripts."release:test-installed-core-workflow:win32-x64".Contains("test-vscode-installed-core-workflow.ps1")) "Root package should expose the installed core workflow E2E gate."
  Assert-True ($rootPackage.scripts."release:test-installed-core-workflow:win32-x64".Contains("%SUBVERSIONR_CODE_CLI%")) "Installed core workflow gate should require an explicit Code CLI path."
  Assert-True ($rootPackage.scripts."release:test-installed-core-workflow:win32-x64".Contains(".cache/native/stage/subversion-win-x64/bin")) "Installed core workflow gate should require the source-built SVN fixture tools root."

  $vsixPath = Join-Path $tempRoot "subversionr-win32-x64-0.2.0.vsix"
  New-TestVsix -Path $vsixPath -Version "0.2.0"
  $fakeCodeCliPath = Join-Path $tempRoot "fake-code\code.cmd"
  New-FakeCodeCli -Path $fakeCodeCliPath
  $fakeSvnRoot = Join-Path $tempRoot "fake-svn"
  New-FakeSvnTools -Root $fakeSvnRoot
  $fixtureRoot = Join-Path $tempRoot "installed-core-workflow\win32-x64"
  $evidencePath = Join-Path $tempRoot "evidence\installed-core-workflow.json"

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $workflowScript `
    -Target win32-x64 `
    -VsixPath $vsixPath `
    -CodeCliPath $fakeCodeCliPath `
    -SvnToolsRoot $fakeSvnRoot `
    -FixtureRoot $fixtureRoot `
    -EvidencePath $evidencePath
  if ($LASTEXITCODE -ne 0) {
    throw "test-vscode-installed-core-workflow.ps1 failed with exit code $LASTEXITCODE."
  }

  $report = Get-Content -Raw -LiteralPath $evidencePath | ConvertFrom-Json
  Assert-Equal "subversionr.release.installed-core-workflow.win32-x64.v1" $report.schema "Installed core workflow evidence should use the M7i schema."
  Assert-Equal "False" ([string]$report.publicReadinessClaim) "Installed core workflow evidence must not claim public readiness."
  Assert-Equal "win32-x64" $report.target "Installed core workflow evidence should record the target."
  Assert-Equal "hitsuki-ban.subversionr" $report.extension.id "Installed core workflow evidence should record the extension id."
  Assert-Equal "complete" $report.extension.harnessPhase "Installed core workflow evidence should record a completed harness phase."
  Assert-Equal "0.2.0" $report.extension.version "Installed core workflow evidence should record the extension version."
  Assert-Equal "installed-vsix" $report.extension.source "Installed core workflow evidence should prove the installed VSIX source."
  Assert-Equal "True" ([string]$report.extension.afterActive) "Installed core workflow evidence should prove activation."
  Assert-Equal "True" ([string]$report.extension.hasInstalledCoreWorkflowReportCommand) "Installed core workflow evidence should prove hidden command registration."
  Assert-Equal "win32-x64" $report.vsix.targetPlatform "Installed core workflow evidence should bind to the VSIX manifest target platform."
  Assert-Equal "1.14.5" $report.fixtureTools.svn.version "Installed core workflow evidence should record source-built svn 1.14.5."
  Assert-Equal "1.14.5" $report.fixtureTools.svnadmin.version "Installed core workflow evidence should record source-built svnadmin 1.14.5."
  Assert-Equal "subversionr.installedCoreWorkflowReport" $report.workflowReport.kind "Installed core workflow evidence should include the workflow report."
  Assert-Equal "subversionr.versionReport" $report.versionReport.kind "Installed core workflow evidence should include a version report."
  Assert-Equal "initialized" $report.versionReport.backend.status "Installed core workflow evidence should require an initialized backend."
  Assert-Equal "1.14.5" $report.versionReport.backend.libsvnVersion "Installed core workflow evidence should require libsvn 1.14.5."
  Assert-Equal "organic-activation" $report.workflowReport.backendWorkflow.sessionSource "Installed core workflow evidence should prove organic-session reuse."
  Assert-Equal "False" ([string]$report.workflowReport.backendWorkflow.repositoryClosed) "Installed core workflow evidence should prove the organic session remains open."
  Assert-True (@($report.workflowReport.projection.groups | Where-Object { $_.id -eq "changes" }).Count -eq 1) "Installed core workflow evidence should include changes group."
  Assert-True (@($report.workflowReport.projection.groups | Where-Object { $_.id -eq "unversioned" }).Count -eq 1) "Installed core workflow evidence should include unversioned group."
  Assert-True ($report.codeCli.sha256 -match '^[a-f0-9]{64}$') "Installed core workflow evidence should record the Code CLI hash."
  Assert-True ($report.fixtureTools.svn.sha256 -match '^[a-f0-9]{64}$') "Installed core workflow evidence should record the svn tool hash."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "TST-024" }).Count -eq 1) "Installed core workflow evidence should trace TST-024."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "MIG-009" }).Count -eq 1) "Installed core workflow evidence should trace MIG-009."
  Assert-True (@($report.nonClaims | Where-Object { $_ -like "*Marketplace*" }).Count -gt 0) "Installed core workflow evidence should keep Marketplace non-claims explicit."
  Assert-True (@($report.nonClaims | Where-Object { $_ -like "*Source Control UI*" }).Count -gt 0) "Installed core workflow evidence should keep Source Control UI non-claims explicit."
  Assert-True ([string]$report.fixtureRoots.svnCliConfig -like "*svn-cli-config*") "Installed core workflow evidence should record the fixture-local SVN CLI config root."
  Assert-True ([string]$report.fixtureRoots.svnRuntimeAppData -like "*runtime-appdata*") "Installed core workflow evidence should record the fixture-local APPDATA root."
  Assert-True ([string]$report.fixtureRoots.svnRuntimeConfig -like "*runtime-appdata/Subversion*") "Installed core workflow evidence should record the fixture-local runtime Subversion config root."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $workflowScript `
      -Target win32-x64 `
      -VsixPath $vsixPath `
      -CodeCliPath "%SUBVERSIONR_CODE_CLI%" `
      -SvnToolsRoot $fakeSvnRoot `
      -FixtureRoot (Join-Path $tempRoot "literal-code-cli") `
      -EvidencePath (Join-Path $tempRoot "evidence\literal-code-cli.json")
  } "CodeCliPath must be an explicit file path" "Installed core workflow gate should reject unresolved Code CLI placeholders."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $workflowScript `
      -Target win32-x64 `
      -VsixPath $vsixPath `
      -CodeCliPath $fakeCodeCliPath `
      -SvnToolsRoot "%SUBVERSIONR_SVN_TOOLS_ROOT%" `
      -FixtureRoot (Join-Path $tempRoot "literal-svn-tools") `
      -EvidencePath (Join-Path $tempRoot "evidence\literal-svn-tools.json")
  } "SvnToolsRoot must be an explicit directory path" "Installed core workflow gate should reject unresolved SVN tools placeholders."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $workflowScript `
      -Target win32-x64 `
      -VsixPath $vsixPath `
      -CodeCliPath $fakeCodeCliPath `
      -SvnToolsRoot $fakeSvnRoot `
      -FixtureRoot (Join-Path $env:TEMP "subversionr-installed-core-outside-target") `
      -EvidencePath (Join-Path $tempRoot "evidence\outside-target.json")
  } "FixtureRoot must resolve inside the repository target directory" "Installed core workflow gate should reject fixture roots outside target."

  $wrongTargetVsixPath = Join-Path $tempRoot "subversionr-linux-x64-0.2.0.vsix"
  New-TestVsix -Path $wrongTargetVsixPath -Version "0.2.0" -TargetPlatform "linux-x64"
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $workflowScript `
      -Target win32-x64 `
      -VsixPath $wrongTargetVsixPath `
      -CodeCliPath $fakeCodeCliPath `
      -SvnToolsRoot $fakeSvnRoot `
      -FixtureRoot (Join-Path $tempRoot "wrong-target\win32-x64") `
      -EvidencePath (Join-Path $tempRoot "evidence\wrong-target.json")
  } "VSIX target platform must be win32-x64" "Installed core workflow gate should reject VSIX manifests for another target."

  $wrongSvnRoot = Join-Path $tempRoot "fake-svn-wrong-version"
  New-FakeSvnTools -Root $wrongSvnRoot -Version "1.14.4"
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $workflowScript `
      -Target win32-x64 `
      -VsixPath $vsixPath `
      -CodeCliPath $fakeCodeCliPath `
      -SvnToolsRoot $wrongSvnRoot `
      -FixtureRoot (Join-Path $tempRoot "wrong-svn-version\win32-x64") `
      -EvidencePath (Join-Path $tempRoot "evidence\wrong-svn-version.json")
  } "source-built Apache Subversion 1.14.5 fixture tools" "Installed core workflow gate should reject non-1.14.5 fixture tools."

  $env:SUBVERSIONR_FAKE_CODE_HANG_EXTENSION_HOST = "1"
  try {
    Assert-NativeCommandFailsContaining {
      & pwsh -NoProfile -ExecutionPolicy Bypass -File $workflowScript `
        -Target win32-x64 `
        -VsixPath $vsixPath `
        -CodeCliPath $fakeCodeCliPath `
        -SvnToolsRoot $fakeSvnRoot `
        -FixtureRoot (Join-Path $tempRoot "timeout\win32-x64") `
        -EvidencePath (Join-Path $tempRoot "evidence\timeout.json") `
        -ExtensionHostTimeoutSeconds 1
    } "VS Code installed Extension Host core workflow smoke timed out after 1 seconds" "Installed core workflow gate should fail fast when the Extension Host test runner hangs."
  }
  finally {
    Remove-Item Env:SUBVERSIONR_FAKE_CODE_HANG_EXTENSION_HOST -ErrorAction SilentlyContinue
  }

  $ciWorkflow = Get-Content -Raw -LiteralPath $ciWorkflowPath
  Assert-True ($ciWorkflow.Contains("Release installed core workflow script tests")) "CI should run M7i installed-core script tests."
  Assert-True ($ciWorkflow.Contains("Test installed VSIX core workflow E2E")) "CI should run the installed core workflow E2E gate."

  Write-Host "Release installed core workflow script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$installedHostScript = Join-Path $repoRoot "scripts\release\test-vscode-installed-extension-host.ps1"
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
    <Description xml:space="preserve">SubversionR installed host fixture</Description>
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
  "activationEvents": ["onCommand:subversionr.cache.clear"],
  "contributes": {
    "commands": [
      { "command": "subversionr.cache.clear", "title": "SubversionR: Clear Cache" }
    ]
  }
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
  "subversionr-installed-host-fixture"
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
  throw "fake code CLI expected --extensionTestsPath for installed host smoke."
}
if ($env:SUBVERSIONR_FAKE_CODE_HANG_EXTENSION_HOST -eq "1") {
  Start-Sleep -Seconds 60
}
$resultPath = $env:SUBVERSIONR_INSTALLED_E2E_RESULT
$extensionsRoot = $env:SUBVERSIONR_INSTALLED_E2E_EXTENSIONS_ROOT
if ([string]::IsNullOrWhiteSpace($resultPath) -or [string]::IsNullOrWhiteSpace($extensionsRoot)) {
  throw "required installed-host harness environment variables are missing."
}
if ([string]::IsNullOrWhiteSpace($env:SUBVERSIONR_INSTALLED_E2E_REDACTION_REPORT_TOKEN)) {
  throw "installed redaction report harness token was not set."
}
if ([string]::IsNullOrWhiteSpace($env:SUBVERSIONR_INSTALLED_E2E_REMOTE_WORKER_REPORT_TOKEN)) {
  throw "installed remote worker report harness token was not set."
}
$installedPackage = Get-ChildItem -LiteralPath $extensionsRoot -Directory |
  Where-Object { $_.Name -like "hitsuki-ban.subversionr-*" } |
  Select-Object -First 1
if ($null -eq $installedPackage) {
  throw "installed SubversionR package was not found by fake code CLI."
}
[pscustomobject]@{
  id = "hitsuki-ban.subversionr"
  version = "0.2.0"
  beforeActive = $false
  afterActive = $true
  extensionPath = $installedPackage.FullName
  invokedCommand = "subversionr.diagnostics.versionReport"
  redactionCommand = "subversionr.diagnostics.installedRedactionReport"
  remoteWorkerCommand = "subversionr.diagnostics.installedRemoteWorkerReport"
  hasVersionReportCommand = $true
  hasInstalledRedactionReportCommand = $true
  hasInstalledRemoteWorkerReportCommand = $true
  source = "installed-vsix"
  versionReport = [pscustomobject]@{
    kind = "subversionr.versionReport"
    extension = [pscustomobject]@{
      name = "subversionr"
      version = "0.2.0"
    }
    vscode = [pscustomobject]@{
      version = "1.126.0"
      appName = "Fake Code"
      uiKind = "desktop"
    }
    process = [pscustomobject]@{
      platform = "win32"
      arch = "x64"
    }
    workspace = [pscustomobject]@{
      trusted = $true
    }
    backend = [pscustomobject]@{
      status = "unavailable"
    }
  }
  installedRedactionReport = [pscustomobject]@{
    schemaVersion = 2
    kind = "subversionr.installedRedactionReport"
    diagnosticsBundle = [pscustomobject]@{
      kind = "subversionr.diagnosticsBundle"
      redaction = [pscustomobject]@{
        paths = "redacted"
        urls = "redacted"
        secrets = "redacted"
      }
      operationJournal = [pscustomobject]@{
        omittedFields = @("paths", "urls", "repositoryLogMessages", "sourceContent", "credentials")
      }
      metrics = [pscustomobject]@{
        watcher = [pscustomobject]@{
          overflowCount = 0
        }
      }
    }
    publicSupportFixture = [pscustomobject]@{
      status = "redacted"
      fixture = [pscustomobject]@{
        repositoryUrl = "[REDACTED:url:aaaaaaaa]"
        path = "[REDACTED:path:bbbbbbbb]"
        secret = "[REDACTED:secret]"
        repositoryLogMessage = "[REDACTED:repository-log]"
        sourceContent = "[REDACTED:source-content]"
      }
    }
    operationFailureFixture = [pscustomobject]@{
      status = "redacted"
      channel = "SubversionR"
      maxLines = 100
      maxLineLength = 4096
      showLogAction = "Show Log"
      lines = @('{"diagnostics":{"cause":"outOfDate","svn":{"entries":[{"code":155011,"name":"SVN_ERR_WC_NOT_UP_TO_DATE"}]}}}')
    }
  }
  installedRemoteWorkerReport = [pscustomobject]@{
    schemaVersion = 2
    kind = "subversionr.installedRemoteWorkerReport"
    protocol = [pscustomobject]@{ major = 1; minor = 33 }
    remoteWorkerIsolation = $true
    credentialLeaseSettlement = $true
    transportResult = "unsupportedAfterWorker"
    sameLaneSubsequent = $true
    subsequentDiagnostics = $true
    credentialLeaseReport = [pscustomobject]@{
      schemaVersion = 1
      kind = "subversionr.installedCredentialLeaseReport"
      legacyBackgroundBlocked = $true
      legacyForegroundCleared = $true
      fixedStoredReuse = $true
      chooserMultiAccount = $true
      promptSingleFlight = $true
      independentLeases = $true
      settlementOutcomes = @("accepted", "rejected", "unused", "cancelled", "timedOut")
      duplicateSettlementIdempotent = $true
      conflictingSettlementRejected = $true
      reloadDiscardedPendingLease = $true
      savedCredentialEntriesCleared = 2
      storageCleanup = $true
    }
  }
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $resultPath -Encoding utf8
exit 0
'@ | Set-Content -LiteralPath $scriptPath -NoNewline
  "@pwsh -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" %*" | Set-Content -LiteralPath $Path -NoNewline
}

$tempRoot = Join-Path $repoRoot "target\tests\release-installed-extension-host-scripts\space root $([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  Assert-True (Test-Path -LiteralPath $installedHostScript -PathType Leaf) "test-vscode-installed-extension-host.ps1 should exist."

  $rootPackage = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  Assert-True ($rootPackage.scripts."release:test-installed-extension-host-scripts".Contains("release-installed-extension-host-scripts.tests.ps1")) "Root package should expose M7h installed-host script tests."
  Assert-True ($rootPackage.scripts."release:test-installed-extension-host:win32-x64".Contains("test-vscode-installed-extension-host.ps1")) "Root package should expose the installed Extension Host E2E gate."
  Assert-True ($rootPackage.scripts."release:test-installed-extension-host:win32-x64".Contains("%SUBVERSIONR_CODE_CLI%")) "Installed-host gate should require an explicit Code CLI path."
  $extensionManifest = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "packages\vscode-extension\package.json") | ConvertFrom-Json
  Assert-True (@($extensionManifest.activationEvents | Where-Object { $_ -eq "onCommand:subversionr.diagnostics.installedRedactionReport" }).Count -eq 0) "Installed redaction report must not be directly command-activatable."
  Assert-True (@($extensionManifest.activationEvents | Where-Object { $_ -eq "onCommand:subversionr.diagnostics.installedRemoteWorkerReport" }).Count -eq 0) "Installed remote worker report must not be directly command-activatable."

  $vsixPath = Join-Path $tempRoot "subversionr-win32-x64-0.2.0.vsix"
  New-TestVsix -Path $vsixPath -Version "0.2.0"
  $fakeCodeCliPath = Join-Path $tempRoot "fake-code\code.cmd"
  New-FakeCodeCli -Path $fakeCodeCliPath
  $fixtureRoot = Join-Path $tempRoot "installed-host\win32-x64"
  $evidencePath = Join-Path $tempRoot "evidence\installed-host.json"

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $installedHostScript `
    -Target win32-x64 `
    -VsixPath $vsixPath `
    -CodeCliPath $fakeCodeCliPath `
    -FixtureRoot $fixtureRoot `
    -EvidencePath $evidencePath
  if ($LASTEXITCODE -ne 0) {
    throw "test-vscode-installed-extension-host.ps1 failed with exit code $LASTEXITCODE."
  }

  $report = Get-Content -Raw -LiteralPath $evidencePath | ConvertFrom-Json
  Assert-Equal "subversionr.release.installed-extension-host.win32-x64.v3" $report.schema "Installed-host evidence should use the I4 schema."
  Assert-Equal "3" ([string]$report.schemaVersion) "Installed-host evidence should use schema version 3."
  Assert-Equal "False" ([string]$report.publicReadinessClaim) "Installed-host evidence must not claim public readiness."
  Assert-Equal "win32-x64" $report.target "Installed-host evidence should record the target."
  Assert-Equal "hitsuki-ban.subversionr" $report.extension.id "Installed-host evidence should record the extension id."
  Assert-Equal "0.2.0" $report.extension.version "Installed-host evidence should record the extension version."
  Assert-Equal "installed-vsix" $report.extension.source "Installed-host evidence should prove the installed VSIX source."
  Assert-Equal "True" ([string]$report.extension.afterActive) "Installed-host evidence should prove activation."
  Assert-Equal "subversionr.diagnostics.versionReport" $report.extension.invokedCommand "Installed-host evidence should record the invoked command."
  Assert-Equal "subversionr.diagnostics.installedRedactionReport" $report.extension.redactionCommand "Installed-host evidence should record the installed redaction command."
  Assert-Equal "subversionr.diagnostics.installedRemoteWorkerReport" $report.extension.remoteWorkerCommand "Installed-host evidence should record the installed remote worker command."
  Assert-Equal "True" ([string]$report.extension.hasVersionReportCommand) "Installed-host evidence should prove version report command registration."
  Assert-Equal "True" ([string]$report.extension.hasInstalledRedactionReportCommand) "Installed-host evidence should prove installed redaction command registration."
  Assert-Equal "True" ([string]$report.extension.hasInstalledRemoteWorkerReportCommand) "Installed-host evidence should prove installed remote worker command registration."
  Assert-Equal "win32-x64" $report.vsix.targetPlatform "Installed-host evidence should bind to the VSIX manifest target platform."
  Assert-Equal "subversionr.versionReport" $report.versionReport.kind "Installed-host evidence should include a version report."
  Assert-True (@("initialized", "unavailable") -contains $report.versionReport.backend.status) "Installed-host evidence should include a supported backend status."
  Assert-Equal "subversionr.installedRedactionReport" $report.installedRedactionReport.kind "Installed-host evidence should include an installed redaction report."
  Assert-Equal "subversionr.diagnosticsBundle" $report.installedRedactionReport.diagnosticsBundle.kind "Installed redaction report should include a diagnostics bundle."
  Assert-Equal "redacted" $report.installedRedactionReport.diagnosticsBundle.redaction.paths "Installed diagnostics bundle should declare path redaction."
  Assert-Equal "redacted" $report.installedRedactionReport.diagnosticsBundle.redaction.urls "Installed diagnostics bundle should declare URL redaction."
  Assert-Equal "redacted" $report.installedRedactionReport.diagnosticsBundle.redaction.secrets "Installed diagnostics bundle should declare secret redaction."
  Assert-Equal "redacted" $report.installedRedactionReport.publicSupportFixture.status "Installed public support fixture should declare redacted status."
  Assert-Equal "2" ([string]$report.installedRedactionReport.schemaVersion) "Installed redaction report should use the failure-log schema."
  Assert-Equal "SubversionR" $report.installedRedactionReport.operationFailureFixture.channel "Installed redaction report should include the SubversionR log channel."
  Assert-True (($report.installedRedactionReport.operationFailureFixture.lines -join "`n").Contains("SVN_ERR_WC_NOT_UP_TO_DATE")) "Installed redaction report should preserve the safe libsvn cause."
  $installedRedactionJson = $report.installedRedactionReport | ConvertTo-Json -Depth 20
  Assert-True (-not $installedRedactionJson.Contains("hunter2")) "Installed redaction report must not contain synthetic fixture passwords."
  Assert-True (-not $installedRedactionJson.Contains("abc123")) "Installed redaction report must not contain synthetic fixture tokens."
  Assert-True (-not $installedRedactionJson.Contains("Alice")) "Installed redaction report must not contain synthetic fixture user paths."
  Assert-True (-not $installedRedactionJson.Contains("example.com")) "Installed redaction report must not contain synthetic fixture repository hosts."
  Assert-True (-not $installedRedactionJson.Contains(".svn/wc.db")) "Installed redaction report must not contain synthetic wc.db paths."
  Assert-True ($installedRedactionJson.Contains("[REDACTED:url:")) "Installed redaction report should include URL redaction markers."
  Assert-True ($installedRedactionJson.Contains("[REDACTED:path:")) "Installed redaction report should include path redaction markers."
  Assert-True ($installedRedactionJson.Contains("[REDACTED:secret]")) "Installed redaction report should include secret redaction markers."
  Assert-True ($installedRedactionJson.Contains("[REDACTED:repository-log]")) "Installed redaction report should include repository log redaction markers."
  Assert-True ($installedRedactionJson.Contains("[REDACTED:source-content]")) "Installed redaction report should include source content redaction markers."
  Assert-Equal "subversionr.installedRemoteWorkerReport" $report.installedRemoteWorkerReport.kind "Installed-host evidence should include the remote worker report."
  Assert-Equal "33" ([string]$report.installedRemoteWorkerReport.protocol.minor) "Installed remote worker evidence should bind protocol v1.33."
  Assert-Equal "True" ([string]$report.installedRemoteWorkerReport.remoteWorkerIsolation) "Installed remote worker evidence should prove the runtime capability."
  Assert-Equal "True" ([string]$report.installedRemoteWorkerReport.credentialLeaseSettlement) "Installed remote worker evidence should prove credential lease settlement."
  Assert-Equal "unsupportedAfterWorker" $report.installedRemoteWorkerReport.transportResult "Installed remote worker evidence should stop at the transport boundary."
  Assert-Equal "True" ([string]$report.installedRemoteWorkerReport.sameLaneSubsequent) "Installed remote worker evidence should prove the same lane is reusable after worker cleanup."
  Assert-Equal "True" ([string]$report.installedRemoteWorkerReport.subsequentDiagnostics) "Installed remote worker evidence should prove a subsequent diagnostics request."
  Assert-Equal "2" ([string]$report.installedRemoteWorkerReport.schemaVersion) "Installed remote worker evidence should use the credential lease schema."
  Assert-Equal "subversionr.installedCredentialLeaseReport" $report.installedRemoteWorkerReport.credentialLeaseReport.kind "Installed remote worker evidence should include the credential lease report."
  Assert-Equal "True" ([string]$report.installedRemoteWorkerReport.credentialLeaseReport.legacyBackgroundBlocked) "Installed credential evidence should block legacy state in the background."
  Assert-Equal "True" ([string]$report.installedRemoteWorkerReport.credentialLeaseReport.legacyForegroundCleared) "Installed credential evidence should clear legacy state in the foreground."
  Assert-Equal "True" ([string]$report.installedRemoteWorkerReport.credentialLeaseReport.fixedStoredReuse) "Installed credential evidence should prove stored fixed-account reuse."
  Assert-Equal "True" ([string]$report.installedRemoteWorkerReport.credentialLeaseReport.chooserMultiAccount) "Installed credential evidence should prove multi-account selection."
  Assert-Equal "True" ([string]$report.installedRemoteWorkerReport.credentialLeaseReport.promptSingleFlight) "Installed credential evidence should prove prompt single-flight."
  Assert-Equal "True" ([string]$report.installedRemoteWorkerReport.credentialLeaseReport.independentLeases) "Installed credential evidence should prove independent leases."
  Assert-Equal "accepted,rejected,unused,cancelled,timedOut" (@($report.installedRemoteWorkerReport.credentialLeaseReport.settlementOutcomes) -join ",") "Installed credential evidence should prove every settlement outcome."
  Assert-Equal "True" ([string]$report.installedRemoteWorkerReport.credentialLeaseReport.duplicateSettlementIdempotent) "Installed credential evidence should prove duplicate settlement idempotency."
  Assert-Equal "True" ([string]$report.installedRemoteWorkerReport.credentialLeaseReport.conflictingSettlementRejected) "Installed credential evidence should reject conflicting settlement."
  Assert-Equal "True" ([string]$report.installedRemoteWorkerReport.credentialLeaseReport.reloadDiscardedPendingLease) "Installed credential evidence should discard pending leases on reload."
  Assert-Equal "True" ([string]$report.installedRemoteWorkerReport.credentialLeaseReport.storageCleanup) "Installed credential evidence should clean its namespaced SecretStorage entries."
  Assert-Equal "none" $report.workingCopySentinel.mutation "Installed-host smoke should not mutate the working-copy sentinel."
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot "workspace\.svn"))) "Installed-host workspace must not contain .svn before command activation."
  Assert-Equal $report.workingCopySentinel.svnTreeBeforeSha256 $report.workingCopySentinel.svnTreeAfterSha256 "Installed-host smoke should prove recursive .svn tree non-mutation."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "TST-024" }).Count -eq 1) "Installed-host evidence should trace TST-024."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "MIG-009" }).Count -eq 1) "Installed-host evidence should trace MIG-009."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $installedHostScript `
      -Target win32-x64 `
      -VsixPath $vsixPath `
      -CodeCliPath "%SUBVERSIONR_CODE_CLI%" `
      -FixtureRoot (Join-Path $tempRoot "literal-code-cli") `
      -EvidencePath (Join-Path $tempRoot "evidence\literal-code-cli.json")
  } "CodeCliPath must be an explicit file path" "Installed-host gate should reject unresolved Code CLI placeholders."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $installedHostScript `
      -Target win32-x64 `
      -VsixPath $vsixPath `
      -CodeCliPath $fakeCodeCliPath `
      -FixtureRoot (Join-Path $env:TEMP "subversionr-installed-host-outside-target") `
      -EvidencePath (Join-Path $tempRoot "evidence\outside-target.json")
  } "FixtureRoot must resolve inside the repository target directory" "Installed-host gate should reject fixture roots outside target."

  $wrongTargetVsixPath = Join-Path $tempRoot "subversionr-linux-x64-0.2.0.vsix"
  New-TestVsix -Path $wrongTargetVsixPath -Version "0.2.0" -TargetPlatform "linux-x64"
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $installedHostScript `
      -Target win32-x64 `
      -VsixPath $wrongTargetVsixPath `
      -CodeCliPath $fakeCodeCliPath `
      -FixtureRoot (Join-Path $tempRoot "wrong-target\win32-x64") `
      -EvidencePath (Join-Path $tempRoot "evidence\wrong-target.json")
  } "VSIX target platform must be win32-x64" "Installed-host gate should reject VSIX manifests for another target."

  $env:SUBVERSIONR_FAKE_CODE_HANG_EXTENSION_HOST = "1"
  try {
    Assert-NativeCommandFailsContaining {
      & pwsh -NoProfile -ExecutionPolicy Bypass -File $installedHostScript `
        -Target win32-x64 `
        -VsixPath $vsixPath `
        -CodeCliPath $fakeCodeCliPath `
        -FixtureRoot (Join-Path $tempRoot "timeout\win32-x64") `
        -EvidencePath (Join-Path $tempRoot "evidence\timeout.json") `
        -ExtensionHostTimeoutSeconds 1
    } "VS Code installed Extension Host version-report smoke timed out after 1 seconds" "Installed-host gate should fail fast when the Extension Host test runner hangs."
  }
  finally {
    Remove-Item Env:SUBVERSIONR_FAKE_CODE_HANG_EXTENSION_HOST -ErrorAction SilentlyContinue
  }

  $ciWorkflow = Get-Content -Raw -LiteralPath $ciWorkflowPath
  Assert-True ($ciWorkflow.Contains("Release installed Extension Host script tests")) "CI should run M7h installed-host script tests."
  Assert-True ($ciWorkflow.Contains("Test installed VSIX Extension Host version report")) "CI should run the installed Extension Host version-report gate."

  Write-Host "Release installed Extension Host script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

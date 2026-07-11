$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$workflowScript = Join-Path $repoRoot "scripts\release\test-vscode-installed-source-control-ui-e2e.ps1"
$driverScript = Join-Path $repoRoot "scripts\release\capture-vscode-renderer-ui.mjs"
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
    <Description xml:space="preserve">SubversionR installed Source Control UI E2E fixture</Description>
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
  "activationEvents": [
    "onCommand:subversionr.diagnostics.installedSourceControlUiE2eOpenReport",
    "onCommand:subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport",
    "onCommand:subversionr.diagnostics.installedSourceControlUiE2eCloseReport",
    "onCommand:subversionr.diagnostics.installedSourceControlUiE2eLazyExternalProviderReport",
    "onCommand:subversionr.diagnostics.installedRepositoryLifecycleReport",
    "onCommand:subversionr.refreshRepository",
    "onCommand:subversionr.updateRepository",
    "onCommand:subversionr.updateToRevision",
    "onCommand:subversionr.deleteUnversionedResource",
    "onCommand:subversionr.deleteAllUnversionedResources",
    "onCommand:subversionr.addResource",
    "onCommand:subversionr.addToIgnoreResource",
    "onCommand:subversionr.lockResource",
    "onCommand:subversionr.unlockResource",
    "onCommand:subversionr.commitAll",
    "onCommand:subversionr.commitResource",
    "onCommand:subversionr.commitChangelist",
    "onCommand:subversionr.revertChangelist",
    "onCommand:subversionr.setResourceChangelist",
    "onCommand:subversionr.clearResourceChangelist",
    "onCommand:subversionr.branchCreateRepository",
    "onCommand:subversionr.switchRepository",
    "onCommand:subversionr.diagnostics.installedSourceControlUiE2eSetInputMessage",
    "onCommand:subversionr.moveResource",
    "onCommand:subversionr.removeResource",
    "onCommand:subversionr.removeResourceKeepLocal",
    "onCommand:subversionr.revertResource",
    "onCommand:subversionr.cleanupRepository"
  ]
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
  "subversionr-installed-source-control-ui-e2e-fixture"
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
  throw "fake code CLI expected --extensionTestsPath for installed Source Control UI E2E smoke."
}
if ($env:SUBVERSIONR_FAKE_CODE_HANG_EXTENSION_HOST -eq "1") {
  Start-Sleep -Seconds 60
}
$resultPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESULT
$readyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_READY
$donePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_DONE
$noRepositoryWelcomeRendererReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_NO_REPOSITORY_WELCOME_RENDERER_READY
$noRepositoryWelcomeRendererDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_NO_REPOSITORY_WELCOME_RENDERER_DONE
$partialFreshnessRendererReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_PARTIAL_FRESHNESS_RENDERER_READY
$partialFreshnessRendererDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_PARTIAL_FRESHNESS_RENDERER_DONE
$staleFreshnessRendererReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_STALE_FRESHNESS_RENDERER_READY
$staleFreshnessRendererDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_STALE_FRESHNESS_RENDERER_DONE
$fullReconcileCancellationReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_FULL_RECONCILE_CANCELLATION_READY
$fullReconcileCancellationDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_FULL_RECONCILE_CANCELLATION_DONE
$multiRepositoryRefreshPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MULTI_REPOSITORY_REFRESH_PROMPT_READY
$deletePromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_DELETE_PROMPT_READY
$deleteLoadPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_DELETE_LOAD_PROMPT_READY
$removePromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REMOVE_PROMPT_READY
$removeCancellationPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REMOVE_CANCELLATION_PROMPT_READY
$removeCancellationPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REMOVE_CANCELLATION_PROMPT_DONE
$removeKeepLocalPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REMOVE_KEEP_LOCAL_PROMPT_READY
$movePromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MOVE_PROMPT_READY
$moveCancellationPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MOVE_CANCELLATION_PROMPT_READY
$checkoutCancellationPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_CANCELLATION_PROMPT_READY
$checkoutCancellationPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_CANCELLATION_PROMPT_DONE
$checkoutExistingTargetFailureUrlPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_URL_PROMPT_READY
$checkoutExistingTargetFailureUrlPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_URL_PROMPT_DONE
$checkoutExistingTargetFailureTargetPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_TARGET_PROMPT_READY
$checkoutExistingTargetFailureTargetPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_TARGET_PROMPT_DONE
$checkoutExistingTargetFailureRevisionPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_REVISION_PROMPT_READY
$checkoutExistingTargetFailureRevisionPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_REVISION_PROMPT_DONE
$checkoutExistingTargetFailureDepthPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_DEPTH_PROMPT_READY
$checkoutExistingTargetFailureDepthPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_DEPTH_PROMPT_DONE
$checkoutExistingTargetFailureExternalsPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_EXTERNALS_PROMPT_READY
$checkoutExistingTargetFailureExternalsPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_EXTERNALS_PROMPT_DONE
$checkoutExistingTargetFailureNotificationReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_NOTIFICATION_READY
$checkoutExistingTargetFailureNotificationDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_NOTIFICATION_DONE
$checkoutInvalidUrlFailureUrlPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_URL_PROMPT_READY
$checkoutInvalidUrlFailureUrlPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_URL_PROMPT_DONE
$checkoutInvalidUrlFailureTargetPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_TARGET_PROMPT_READY
$checkoutInvalidUrlFailureTargetPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_TARGET_PROMPT_DONE
$checkoutInvalidUrlFailureRevisionPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_REVISION_PROMPT_READY
$checkoutInvalidUrlFailureRevisionPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_REVISION_PROMPT_DONE
$checkoutInvalidUrlFailureDepthPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_DEPTH_PROMPT_READY
$checkoutInvalidUrlFailureDepthPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_DEPTH_PROMPT_DONE
$checkoutInvalidUrlFailureExternalsPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_EXTERNALS_PROMPT_READY
$checkoutInvalidUrlFailureExternalsPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_EXTERNALS_PROMPT_DONE
$checkoutInvalidUrlFailureNotificationReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_NOTIFICATION_READY
$checkoutInvalidUrlFailureNotificationDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_NOTIFICATION_DONE
$checkoutExistingDirectoryUrlPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_URL_PROMPT_READY
$checkoutExistingDirectoryUrlPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_URL_PROMPT_DONE
$checkoutExistingDirectoryTargetPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_TARGET_PROMPT_READY
$checkoutExistingDirectoryTargetPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_TARGET_PROMPT_DONE
$checkoutExistingDirectoryRevisionPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_REVISION_PROMPT_READY
$checkoutExistingDirectoryRevisionPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_REVISION_PROMPT_DONE
$checkoutExistingDirectoryDepthPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_DEPTH_PROMPT_READY
$checkoutExistingDirectoryDepthPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_DEPTH_PROMPT_DONE
$checkoutExistingDirectoryExternalsPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_EXTERNALS_PROMPT_READY
$checkoutExistingDirectoryExternalsPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_EXTERNALS_PROMPT_DONE
$checkoutExistingDirectoryObstructionUrlPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_URL_PROMPT_READY
$checkoutExistingDirectoryObstructionUrlPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_URL_PROMPT_DONE
$checkoutExistingDirectoryObstructionTargetPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_TARGET_PROMPT_READY
$checkoutExistingDirectoryObstructionTargetPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_TARGET_PROMPT_DONE
$checkoutExistingDirectoryObstructionRevisionPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_REVISION_PROMPT_READY
$checkoutExistingDirectoryObstructionRevisionPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_REVISION_PROMPT_DONE
$checkoutExistingDirectoryObstructionDepthPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_DEPTH_PROMPT_READY
$checkoutExistingDirectoryObstructionDepthPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_DEPTH_PROMPT_DONE
$checkoutExistingDirectoryObstructionExternalsPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_EXTERNALS_PROMPT_READY
$checkoutExistingDirectoryObstructionExternalsPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_EXTERNALS_PROMPT_DONE
$checkoutUrlPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_URL_PROMPT_READY
$checkoutUrlPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_URL_PROMPT_DONE
$checkoutTargetPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_TARGET_PROMPT_READY
$checkoutTargetPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_TARGET_PROMPT_DONE
$checkoutRevisionPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_REVISION_PROMPT_READY
$checkoutRevisionPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_REVISION_PROMPT_DONE
$checkoutDepthPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_DEPTH_PROMPT_READY
$checkoutDepthPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_DEPTH_PROMPT_DONE
$checkoutExternalsPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXTERNALS_PROMPT_READY
$checkoutExternalsPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXTERNALS_PROMPT_DONE
$updateRevisionPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_REVISION_PROMPT_READY
$updateRevisionPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_REVISION_PROMPT_DONE
$updateCancellationRevisionPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_CANCELLATION_REVISION_PROMPT_READY
$updateCancellationRevisionPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_CANCELLATION_REVISION_PROMPT_DONE
$updateDepthPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_DEPTH_PROMPT_READY
$updateDepthPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_DEPTH_PROMPT_DONE
$updateStickyDepthPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_STICKY_DEPTH_PROMPT_READY
$updateStickyDepthPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_STICKY_DEPTH_PROMPT_DONE
$updateExternalsPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_EXTERNALS_PROMPT_READY
$updateExternalsPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_EXTERNALS_PROMPT_DONE
$branchCreateSourcePromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_SOURCE_PROMPT_READY
$branchCreateSourcePromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_SOURCE_PROMPT_DONE
$branchCreateDestinationPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_DESTINATION_PROMPT_READY
$branchCreateDestinationPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_DESTINATION_PROMPT_DONE
$branchCreateRevisionPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_REVISION_PROMPT_READY
$branchCreateRevisionPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_REVISION_PROMPT_DONE
$branchCreateMessagePromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_MESSAGE_PROMPT_READY
$branchCreateMessagePromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_MESSAGE_PROMPT_DONE
$branchCreateParentsPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_PARENTS_PROMPT_READY
$branchCreateParentsPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_PARENTS_PROMPT_DONE
$branchCreateExternalsPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_EXTERNALS_PROMPT_READY
$branchCreateExternalsPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_EXTERNALS_PROMPT_DONE
$branchCreateSwitchPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_SWITCH_PROMPT_READY
$branchCreateSwitchPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_SWITCH_PROMPT_DONE
$switchUrlPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_URL_PROMPT_READY
$switchUrlPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_URL_PROMPT_DONE
$switchRevisionPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_REVISION_PROMPT_READY
$switchRevisionPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_REVISION_PROMPT_DONE
$switchDepthPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_DEPTH_PROMPT_READY
$switchDepthPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_DEPTH_PROMPT_DONE
$switchStickyDepthPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_STICKY_DEPTH_PROMPT_READY
$switchStickyDepthPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_STICKY_DEPTH_PROMPT_DONE
$switchExternalsPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_EXTERNALS_PROMPT_READY
$switchExternalsPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_EXTERNALS_PROMPT_DONE
$switchAncestryPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_ANCESTRY_PROMPT_READY
$switchAncestryPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_ANCESTRY_PROMPT_DONE
$lockMessageCancellationPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MESSAGE_CANCELLATION_PROMPT_READY
$lockMessageCancellationPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MESSAGE_CANCELLATION_PROMPT_DONE
$lockMessagePromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MESSAGE_PROMPT_READY
$lockMessagePromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MESSAGE_PROMPT_DONE
$lockModePromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MODE_PROMPT_READY
$lockModePromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MODE_PROMPT_DONE
$lockHeldOracleReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_HELD_ORACLE_READY
$lockHeldOracleDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_HELD_ORACLE_DONE
$unlockModeCancellationPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UNLOCK_MODE_CANCELLATION_PROMPT_READY
$unlockModeCancellationPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UNLOCK_MODE_CANCELLATION_PROMPT_DONE
$unlockModePromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UNLOCK_MODE_PROMPT_READY
$unlockModePromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UNLOCK_MODE_PROMPT_DONE
$changelistSetPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHANGELIST_SET_PROMPT_READY
$changelistRevertPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHANGELIST_REVERT_PROMPT_READY
$revertPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_PROMPT_READY
$revertCancellationPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_CANCELLATION_PROMPT_READY
$revertCancellationPromptDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_CANCELLATION_PROMPT_DONE
$resolveUpdateWarningReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESOLVE_UPDATE_WARNING_READY
$resolveUpdateWarningDonePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESOLVE_UPDATE_WARNING_DONE
$resolvePromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESOLVE_PROMPT_READY
$resolveCancellationPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESOLVE_CANCELLATION_PROMPT_READY
$cleanupPromptReadyPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CLEANUP_PROMPT_READY
$extensionsRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_EXTENSIONS_ROOT
$workingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_WORKING_COPY
$multiRepositoryRefreshWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MULTI_REPOSITORY_REFRESH_WORKING_COPY
$lazyExternalProviderWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LAZY_EXTERNAL_PROVIDER_WORKING_COPY
$boundaryLoadWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BOUNDARY_LOAD_WORKING_COPY
$boundaryLoadParentModifiedItemCountText = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BOUNDARY_LOAD_PARENT_MODIFIED_ITEM_COUNT
$boundaryLoadBoundaryModifiedItemCountText = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BOUNDARY_LOAD_BOUNDARY_MODIFIED_ITEM_COUNT
$refreshLoadWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REFRESH_LOAD_WORKING_COPY
$refreshLoadItemCountText = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REFRESH_LOAD_ITEM_COUNT
$loadWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOAD_WORKING_COPY
$loadItemCountText = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOAD_ITEM_COUNT
$commitAllWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_COMMIT_ALL_WORKING_COPY
$commitSelectedWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_COMMIT_SELECTED_WORKING_COPY
$commitSelectedMultiSelectionWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_COMMIT_SELECTED_MULTI_SELECTION_WORKING_COPY
$checkoutRepositoryUrl = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_URL
$checkoutCancellationTargetWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_CANCELLATION_TARGET_WORKING_COPY
$checkoutExistingTargetFailureTargetPath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_TARGET_PATH
$checkoutInvalidUrlFailureRepositoryUrl = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_URL
$checkoutInvalidUrlFailureTargetWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_TARGET_WORKING_COPY
$checkoutExistingDirectoryTargetWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_TARGET_WORKING_COPY
$checkoutExistingDirectoryObstructionTargetWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_TARGET_WORKING_COPY
$checkoutTargetWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_TARGET_WORKING_COPY
$updateWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_WORKING_COPY
$updateRevisionText = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_REVISION
$updateTargetRelativePath = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_TARGET_RELATIVE_PATH
$branchCreateWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_WORKING_COPY
$branchCreateSourceUrl = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_SOURCE_URL
$branchCreateDestinationUrl = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_DESTINATION_URL
$branchCreateMessage = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_MESSAGE
$switchWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_WORKING_COPY
$switchTargetUrl = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_TARGET_URL
$addWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_ADD_WORKING_COPY
$addToIgnoreWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_ADD_TO_IGNORE_WORKING_COPY
$lockWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_WORKING_COPY
$changelistSetClearWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHANGELIST_SET_CLEAR_WORKING_COPY
$commitChangelistWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_COMMIT_CHANGELIST_WORKING_COPY
$revertChangelistWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_CHANGELIST_WORKING_COPY
$moveWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MOVE_WORKING_COPY
$moveCancellationWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MOVE_CANCELLATION_WORKING_COPY
$removeWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REMOVE_WORKING_COPY
$removeCancellationWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REMOVE_CANCELLATION_WORKING_COPY
$revertWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_WORKING_COPY
$revertCancellationWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_CANCELLATION_WORKING_COPY
$resolveWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESOLVE_WORKING_COPY
$resolveCancellationWorkingCopyRoot = $env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESOLVE_CANCELLATION_WORKING_COPY
if ([string]::IsNullOrWhiteSpace($resultPath) -or [string]::IsNullOrWhiteSpace($readyPath) -or [string]::IsNullOrWhiteSpace($donePath) -or [string]::IsNullOrWhiteSpace($noRepositoryWelcomeRendererReadyPath) -or [string]::IsNullOrWhiteSpace($noRepositoryWelcomeRendererDonePath) -or [string]::IsNullOrWhiteSpace($partialFreshnessRendererReadyPath) -or [string]::IsNullOrWhiteSpace($partialFreshnessRendererDonePath) -or [string]::IsNullOrWhiteSpace($staleFreshnessRendererReadyPath) -or [string]::IsNullOrWhiteSpace($staleFreshnessRendererDonePath) -or [string]::IsNullOrWhiteSpace($fullReconcileCancellationReadyPath) -or [string]::IsNullOrWhiteSpace($fullReconcileCancellationDonePath) -or [string]::IsNullOrWhiteSpace($multiRepositoryRefreshPromptReadyPath) -or [string]::IsNullOrWhiteSpace($deletePromptReadyPath) -or [string]::IsNullOrWhiteSpace($deleteLoadPromptReadyPath) -or [string]::IsNullOrWhiteSpace($removePromptReadyPath) -or [string]::IsNullOrWhiteSpace($removeCancellationPromptReadyPath) -or [string]::IsNullOrWhiteSpace($removeCancellationPromptDonePath) -or [string]::IsNullOrWhiteSpace($removeKeepLocalPromptReadyPath) -or [string]::IsNullOrWhiteSpace($movePromptReadyPath) -or [string]::IsNullOrWhiteSpace($moveCancellationPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutCancellationPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutCancellationPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutExistingTargetFailureUrlPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutExistingTargetFailureUrlPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutExistingTargetFailureTargetPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutExistingTargetFailureTargetPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutExistingTargetFailureRevisionPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutExistingTargetFailureRevisionPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutExistingTargetFailureDepthPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutExistingTargetFailureDepthPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutExistingTargetFailureExternalsPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutExistingTargetFailureExternalsPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutExistingTargetFailureNotificationReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutExistingTargetFailureNotificationDonePath) -or [string]::IsNullOrWhiteSpace($checkoutInvalidUrlFailureUrlPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutInvalidUrlFailureUrlPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutInvalidUrlFailureTargetPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutInvalidUrlFailureTargetPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutInvalidUrlFailureRevisionPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutInvalidUrlFailureRevisionPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutInvalidUrlFailureDepthPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutInvalidUrlFailureDepthPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutInvalidUrlFailureExternalsPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutInvalidUrlFailureExternalsPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutInvalidUrlFailureNotificationReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutInvalidUrlFailureNotificationDonePath) -or [string]::IsNullOrWhiteSpace($checkoutUrlPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutUrlPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutTargetPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutTargetPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutRevisionPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutRevisionPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutDepthPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutDepthPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutExternalsPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutExternalsPromptDonePath) -or [string]::IsNullOrWhiteSpace($updateRevisionPromptReadyPath) -or [string]::IsNullOrWhiteSpace($updateRevisionPromptDonePath) -or [string]::IsNullOrWhiteSpace($updateCancellationRevisionPromptReadyPath) -or [string]::IsNullOrWhiteSpace($updateCancellationRevisionPromptDonePath) -or [string]::IsNullOrWhiteSpace($updateDepthPromptReadyPath) -or [string]::IsNullOrWhiteSpace($updateDepthPromptDonePath) -or [string]::IsNullOrWhiteSpace($updateStickyDepthPromptReadyPath) -or [string]::IsNullOrWhiteSpace($updateStickyDepthPromptDonePath) -or [string]::IsNullOrWhiteSpace($updateExternalsPromptReadyPath) -or [string]::IsNullOrWhiteSpace($updateExternalsPromptDonePath) -or [string]::IsNullOrWhiteSpace($branchCreateSourcePromptReadyPath) -or [string]::IsNullOrWhiteSpace($branchCreateSourcePromptDonePath) -or [string]::IsNullOrWhiteSpace($branchCreateDestinationPromptReadyPath) -or [string]::IsNullOrWhiteSpace($branchCreateDestinationPromptDonePath) -or [string]::IsNullOrWhiteSpace($branchCreateRevisionPromptReadyPath) -or [string]::IsNullOrWhiteSpace($branchCreateRevisionPromptDonePath) -or [string]::IsNullOrWhiteSpace($branchCreateMessagePromptReadyPath) -or [string]::IsNullOrWhiteSpace($branchCreateMessagePromptDonePath) -or [string]::IsNullOrWhiteSpace($branchCreateParentsPromptReadyPath) -or [string]::IsNullOrWhiteSpace($branchCreateParentsPromptDonePath) -or [string]::IsNullOrWhiteSpace($branchCreateExternalsPromptReadyPath) -or [string]::IsNullOrWhiteSpace($branchCreateExternalsPromptDonePath) -or [string]::IsNullOrWhiteSpace($branchCreateSwitchPromptReadyPath) -or [string]::IsNullOrWhiteSpace($branchCreateSwitchPromptDonePath) -or [string]::IsNullOrWhiteSpace($switchUrlPromptReadyPath) -or [string]::IsNullOrWhiteSpace($switchUrlPromptDonePath) -or [string]::IsNullOrWhiteSpace($switchRevisionPromptReadyPath) -or [string]::IsNullOrWhiteSpace($switchRevisionPromptDonePath) -or [string]::IsNullOrWhiteSpace($switchDepthPromptReadyPath) -or [string]::IsNullOrWhiteSpace($switchDepthPromptDonePath) -or [string]::IsNullOrWhiteSpace($switchStickyDepthPromptReadyPath) -or [string]::IsNullOrWhiteSpace($switchStickyDepthPromptDonePath) -or [string]::IsNullOrWhiteSpace($switchExternalsPromptReadyPath) -or [string]::IsNullOrWhiteSpace($switchExternalsPromptDonePath) -or [string]::IsNullOrWhiteSpace($switchAncestryPromptReadyPath) -or [string]::IsNullOrWhiteSpace($switchAncestryPromptDonePath) -or [string]::IsNullOrWhiteSpace($lockMessageCancellationPromptReadyPath) -or [string]::IsNullOrWhiteSpace($lockMessageCancellationPromptDonePath) -or [string]::IsNullOrWhiteSpace($lockMessagePromptReadyPath) -or [string]::IsNullOrWhiteSpace($lockMessagePromptDonePath) -or [string]::IsNullOrWhiteSpace($lockModePromptReadyPath) -or [string]::IsNullOrWhiteSpace($lockModePromptDonePath) -or [string]::IsNullOrWhiteSpace($lockHeldOracleReadyPath) -or [string]::IsNullOrWhiteSpace($lockHeldOracleDonePath) -or [string]::IsNullOrWhiteSpace($unlockModeCancellationPromptReadyPath) -or [string]::IsNullOrWhiteSpace($unlockModeCancellationPromptDonePath) -or [string]::IsNullOrWhiteSpace($unlockModePromptReadyPath) -or [string]::IsNullOrWhiteSpace($unlockModePromptDonePath) -or [string]::IsNullOrWhiteSpace($changelistSetPromptReadyPath) -or [string]::IsNullOrWhiteSpace($changelistRevertPromptReadyPath) -or [string]::IsNullOrWhiteSpace($revertPromptReadyPath) -or [string]::IsNullOrWhiteSpace($revertCancellationPromptReadyPath) -or [string]::IsNullOrWhiteSpace($revertCancellationPromptDonePath) -or [string]::IsNullOrWhiteSpace($resolveUpdateWarningReadyPath) -or [string]::IsNullOrWhiteSpace($resolveUpdateWarningDonePath) -or [string]::IsNullOrWhiteSpace($resolvePromptReadyPath) -or [string]::IsNullOrWhiteSpace($resolveCancellationPromptReadyPath) -or [string]::IsNullOrWhiteSpace($extensionsRoot) -or [string]::IsNullOrWhiteSpace($workingCopyRoot) -or [string]::IsNullOrWhiteSpace($multiRepositoryRefreshWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($lazyExternalProviderWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($boundaryLoadWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($boundaryLoadParentModifiedItemCountText) -or [string]::IsNullOrWhiteSpace($boundaryLoadBoundaryModifiedItemCountText) -or [string]::IsNullOrWhiteSpace($refreshLoadWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($refreshLoadItemCountText) -or [string]::IsNullOrWhiteSpace($loadWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($loadItemCountText) -or [string]::IsNullOrWhiteSpace($commitAllWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($commitSelectedWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($commitSelectedMultiSelectionWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($checkoutRepositoryUrl) -or [string]::IsNullOrWhiteSpace($checkoutCancellationTargetWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($checkoutExistingTargetFailureTargetPath) -or [string]::IsNullOrWhiteSpace($checkoutInvalidUrlFailureRepositoryUrl) -or [string]::IsNullOrWhiteSpace($checkoutInvalidUrlFailureTargetWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($checkoutTargetWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($updateWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($updateRevisionText) -or [string]::IsNullOrWhiteSpace($updateTargetRelativePath) -or [string]::IsNullOrWhiteSpace($branchCreateWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($branchCreateSourceUrl) -or [string]::IsNullOrWhiteSpace($branchCreateDestinationUrl) -or [string]::IsNullOrWhiteSpace($branchCreateMessage) -or [string]::IsNullOrWhiteSpace($switchWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($switchTargetUrl) -or [string]::IsNullOrWhiteSpace($addWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($addToIgnoreWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($lockWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($changelistSetClearWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($commitChangelistWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($revertChangelistWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($moveWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($moveCancellationWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($removeWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($removeCancellationWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($revertWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($revertCancellationWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($resolveWorkingCopyRoot) -or [string]::IsNullOrWhiteSpace($resolveCancellationWorkingCopyRoot)) {
  throw "required installed Source Control UI E2E harness environment variables are missing."
}
if ([string]::IsNullOrWhiteSpace($checkoutExistingDirectoryUrlPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutExistingDirectoryUrlPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutExistingDirectoryTargetPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutExistingDirectoryTargetPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutExistingDirectoryRevisionPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutExistingDirectoryRevisionPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutExistingDirectoryDepthPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutExistingDirectoryDepthPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutExistingDirectoryExternalsPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutExistingDirectoryExternalsPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutExistingDirectoryTargetWorkingCopyRoot)) {
  throw "required installed Source Control UI E2E checkout existing-directory harness environment variables are missing."
}
if ([string]::IsNullOrWhiteSpace($checkoutExistingDirectoryObstructionUrlPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutExistingDirectoryObstructionUrlPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutExistingDirectoryObstructionTargetPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutExistingDirectoryObstructionTargetPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutExistingDirectoryObstructionRevisionPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutExistingDirectoryObstructionRevisionPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutExistingDirectoryObstructionDepthPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutExistingDirectoryObstructionDepthPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutExistingDirectoryObstructionExternalsPromptReadyPath) -or [string]::IsNullOrWhiteSpace($checkoutExistingDirectoryObstructionExternalsPromptDonePath) -or [string]::IsNullOrWhiteSpace($checkoutExistingDirectoryObstructionTargetWorkingCopyRoot)) {
  throw "required installed Source Control UI E2E checkout existing-directory obstruction harness environment variables are missing."
}
$boundaryLoadParentModifiedItemCount = [int]$boundaryLoadParentModifiedItemCountText
$boundaryLoadBoundaryModifiedItemCount = [int]$boundaryLoadBoundaryModifiedItemCountText
$refreshLoadItemCount = [int]$refreshLoadItemCountText
$loadItemCount = [int]$loadItemCountText
$updateRevision = [int]$updateRevisionText
$installedPackage = Get-ChildItem -LiteralPath $extensionsRoot -Directory |
  Where-Object { $_.Name -like "hitsuki-ban.subversionr-*" } |
  Select-Object -First 1
if ($null -eq $installedPackage) {
  throw "installed SubversionR package was not found by fake code CLI."
}
$openReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eOpenReport"
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
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$workingCopyRoot"
    epoch = 1
    workingCopyRoot = $workingCopyRoot
    generation = 1
    count = 1
    inputBox = [pscustomobject]@{
      placeholder = "SVN commit message"
      acceptInputCommand = "subversionr.commitAll"
      acceptInputCommandArguments = @("repo-uuid:$workingCopyRoot")
    }
    groups = @(
      [pscustomobject]@{
        id = "changes"
        contextValue = "subversionr.changes"
        hideWhenEmpty = $true
        count = 1
        resources = @(
          [pscustomobject]@{
            path = "src/tracked.txt"
            contextValue = "subversionr.changedFile.baseDiffable"
            kind = "file"
            generation = 1
          }
        )
      },
      [pscustomobject]@{
        id = "unversioned"
        contextValue = "subversionr.unversioned"
        hideWhenEmpty = $true
        count = 1
        resources = @(
          [pscustomobject]@{
            path = "scratch.txt"
            contextValue = "subversionr.unversioned"
            kind = "file"
            generation = 1
          }
        )
      }
    )
  }
  rendererCaptureExpectations = [pscustomobject]@{
    viewCommand = "workbench.view.scm"
    requiredDomTokens = @("SVN-R", "Changes", "Unversioned", "src", "tracked.txt", "scratch.txt")
    requiredAccessibilityTokens = @("SubversionR", "Changes", "Unversioned", "src", "tracked.txt", "scratch.txt")
    requiredScreenshot = $true
  }
  surfaceWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    scmProjection = $true
    sourceControlSurface = $true
    repositoryClosed = $false
  }
}
$ready = [pscustomobject]@{
  ok = $true
  phase = "focusingSourceControlView"
  openReport = $openReport
  rendererCaptureExpectations = $openReport.rendererCaptureExpectations
}
$ready | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $readyPath -Encoding utf8
$deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
while (-not (Test-Path -LiteralPath $donePath -PathType Leaf)) {
  if ([DateTimeOffset]::UtcNow -gt $deadline) {
    throw "fake code CLI timed out waiting for renderer completion sentinel."
  }
  Start-Sleep -Milliseconds 100
}
function Wait-FakeRendererDone([string]$Path, [string]$Description) {
  $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
  while (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    if ([DateTimeOffset]::UtcNow -gt $deadline) {
      throw "fake code CLI timed out waiting for $Description renderer completion sentinel."
    }
    Start-Sleep -Milliseconds 100
  }
}
$partialFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:02Z"
  scenario = "partial"
  repository = $openReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $openReport.sourceControl.repositoryId
    epoch = $openReport.sourceControl.epoch
    workingCopyRoot = $openReport.sourceControl.workingCopyRoot
    generation = $openReport.sourceControl.generation
    count = $openReport.sourceControl.count
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($openReport.repository.repositoryId)
      }
    )
    inputBox = $openReport.sourceControl.inputBox
    groups = $openReport.sourceControl.groups
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$partialFreshnessRendererExpectations = [pscustomobject]@{
  viewCommand = "workbench.view.scm"
  requiredDomTokens = @("SVN status partial", "Changes", "src", "tracked.txt")
  requiredAccessibilityTokens = @("SubversionR", "SVN status partial", "Changes", "src", "tracked.txt")
  requiredScreenshot = $true
}
[pscustomobject]@{
  ok = $true
  phase = "partialFreshnessRendererReady"
  scenario = "partial"
  repository = [pscustomobject]@{
    repositoryId = $partialFreshnessReport.repository.repositoryId
    epoch = $partialFreshnessReport.repository.epoch
    workingCopyRoot = $partialFreshnessReport.repository.identity.workingCopyRoot
  }
  rendererCaptureExpectations = $partialFreshnessRendererExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $partialFreshnessRendererReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $partialFreshnessRendererDonePath -Description "partial freshness"
$staleFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:03Z"
  scenario = "stale"
  repository = $openReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $openReport.sourceControl.repositoryId
    epoch = $openReport.sourceControl.epoch
    workingCopyRoot = $openReport.sourceControl.workingCopyRoot
    generation = $openReport.sourceControl.generation
    count = $openReport.sourceControl.count
    freshness = [pscustomobject]@{
      repositoryCompleteness = "stale"
      lastRefreshCompleteness = "stale"
      lastRefreshKind = "stale"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status stale"
        arguments = @($openReport.repository.repositoryId)
      }
    )
    inputBox = $openReport.sourceControl.inputBox
    groups = $openReport.sourceControl.groups
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$staleFreshnessRendererExpectations = [pscustomobject]@{
  viewCommand = "workbench.view.scm"
  requiredDomTokens = @("SVN status stale", "Changes", "src", "tracked.txt")
  requiredAccessibilityTokens = @("SubversionR", "SVN status stale", "Changes", "src", "tracked.txt")
  requiredScreenshot = $true
}
[pscustomobject]@{
  ok = $true
  phase = "staleFreshnessRendererReady"
  scenario = "stale"
  repository = [pscustomobject]@{
    repositoryId = $staleFreshnessReport.repository.repositoryId
    epoch = $staleFreshnessReport.repository.epoch
    workingCopyRoot = $staleFreshnessReport.repository.identity.workingCopyRoot
  }
  rendererCaptureExpectations = $staleFreshnessRendererExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $staleFreshnessRendererReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $staleFreshnessRendererDonePath -Description "stale freshness"
$fullReconcileCancellationExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN-R", "Reconciling SVN working copy status", "Cancel")
  requiredAccessibilityTokens = @("SVN-R", "Reconciling SVN working copy status", "Cancel")
  requiredScreenshot = $true
  clickButtonText = "Cancel"
}
$fullReconcileCancellationArmReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFullReconcileCancellationArmReport"
  generatedAt = "2026-06-25T00:00:03Z"
  holdId = "manual-full-reconcile-1"
  repositoryId = $openReport.repository.repositoryId
  epoch = $openReport.repository.epoch
  timeoutMs = 60000
  target = [pscustomobject]@{
    path = "."
    depth = "infinity"
    reason = "manualFullReconcile"
  }
  armed = $true
}
[pscustomobject]@{
  ok = $true
  phase = "fullReconcileCancellationProgressReady"
  command = "subversionr.fullReconcile"
  armReport = $fullReconcileCancellationArmReport
  rendererCaptureExpectations = $fullReconcileCancellationExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $fullReconcileCancellationReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $fullReconcileCancellationDonePath -Description "full reconcile cancellation"
$fullReconcileCancellationProbeReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFullReconcileCancellationReport"
  generatedAt = "2026-06-25T00:00:04Z"
  holdId = "manual-full-reconcile-1"
  repositoryId = $openReport.repository.repositoryId
  epoch = $openReport.repository.epoch
  target = [pscustomobject]@{
    path = "."
    depth = "infinity"
    reason = "manualFullReconcile"
  }
  observed = $true
  cancellationObserved = $true
  refreshStatusSignalProvided = $true
  signalAborted = $true
  assertions = [pscustomobject]@{
    matchedManualFullReconcile = $true
    signalProvided = $true
    signalAborted = $true
    cancellationObserved = $true
  }
}
$fullReconcileCancellationRecoveryFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:05Z"
  scenario = "partial"
  repository = $openReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $openReport.sourceControl.repositoryId
    epoch = $openReport.sourceControl.epoch
    workingCopyRoot = $openReport.sourceControl.workingCopyRoot
    generation = $openReport.sourceControl.generation
    count = $openReport.sourceControl.count
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($openReport.repository.repositoryId)
      }
    )
    inputBox = $openReport.sourceControl.inputBox
    groups = $openReport.sourceControl.groups
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$fullReconcileCancellationReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFullReconcileCancellationWorkflow"
  generatedAt = "2026-06-25T00:00:05Z"
  command = [pscustomobject]@{
    command = "subversionr.fullReconcile"
    arguments = @($openReport.repository.repositoryId)
  }
  repository = [pscustomobject]@{
    repositoryId = $openReport.repository.repositoryId
    epoch = $openReport.repository.epoch
    workingCopyRoot = $workingCopyRoot
  }
  armReport = $fullReconcileCancellationArmReport
  cancellationReport = $fullReconcileCancellationProbeReport
  commandResult = [pscustomobject]@{
    resolved = $true
  }
  prompt = [pscustomobject]@{
    clickButtonText = "Cancel"
    rendererCaptureExpectations = $fullReconcileCancellationExpectations
  }
  recoveryFreshnessReport = $fullReconcileCancellationRecoveryFreshnessReport
  assertions = [pscustomobject]@{
    commandResolvedAfterCancellation = $true
    cancellationObserved = $true
    signalProvided = $true
    signalAborted = $true
    cancellationReason = "userCancelled"
    recoveryFullReconcileExecuted = $true
    sourceControlSurfaceAfterRecovery = $true
  }
}
$postRefreshFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:03Z"
  scenario = "partial"
  repository = $openReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $openReport.sourceControl.repositoryId
    epoch = $openReport.sourceControl.epoch
    workingCopyRoot = $openReport.sourceControl.workingCopyRoot
    generation = $openReport.sourceControl.generation
    count = $openReport.sourceControl.count
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($openReport.repository.repositoryId)
      }
    )
    inputBox = $openReport.sourceControl.inputBox
    groups = $openReport.sourceControl.groups
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$refreshReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eRefreshWorkflow"
  generatedAt = "2026-06-25T00:00:03Z"
  command = [pscustomobject]@{
    command = "subversionr.refreshRepository"
  }
  repository = [pscustomobject]@{
    repositoryId = $openReport.repository.repositoryId
    epoch = $openReport.repository.epoch
    workingCopyRoot = $workingCopyRoot
  }
  postRefreshFreshnessReport = $postRefreshFreshnessReport
  assertions = [pscustomobject]@{
    commandExecuted = $true
    singleOpenRepositoryPath = $true
    repositoryOpenBefore = $true
    sourceControlSurfaceAfterRefresh = $true
  }
}
$refreshLoadResources = @(1..$refreshLoadItemCount | ForEach-Object {
  [pscustomobject]@{
    path = "load/modified-{0:D3}.txt" -f $_
    contextValue = "subversionr.changedFile.baseDiffable"
    kind = "file"
    generation = 1
  }
})
$refreshLoadOpenReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eOpenReport"
  generatedAt = "2026-06-25T00:00:03Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$refreshLoadWorkingCopyRoot"
    epoch = 4
    identity = [pscustomobject]@{
      repositoryUuid = "fixture-refresh-load-repository-uuid"
      repositoryRootUrl = "file:///fixture/refresh-load/repo"
      workingCopyRoot = $refreshLoadWorkingCopyRoot
      workspaceScopeRoot = $refreshLoadWorkingCopyRoot
      format = 31
    }
  }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$refreshLoadWorkingCopyRoot"
    epoch = 4
    workingCopyRoot = $refreshLoadWorkingCopyRoot
    generation = 1
    count = 1 + $refreshLoadItemCount
    inputBox = $openReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{
        id = "changes"
        contextValue = "subversionr.changes"
        hideWhenEmpty = $true
        count = 1 + $refreshLoadItemCount
        resources = @($openReport.sourceControl.groups[0].resources[0]) + $refreshLoadResources
      },
      $openReport.sourceControl.groups[1]
    )
  }
  rendererCaptureExpectations = $openReport.rendererCaptureExpectations
  surfaceWorkflow = $openReport.surfaceWorkflow
}
$refreshLoadPostRefreshFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:03Z"
  scenario = "partial"
  repository = $refreshLoadOpenReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $refreshLoadOpenReport.sourceControl.repositoryId
    epoch = $refreshLoadOpenReport.sourceControl.epoch
    workingCopyRoot = $refreshLoadOpenReport.sourceControl.workingCopyRoot
    generation = $refreshLoadOpenReport.sourceControl.generation
    count = $refreshLoadOpenReport.sourceControl.count
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($refreshLoadOpenReport.repository.repositoryId)
      }
    )
    inputBox = $refreshLoadOpenReport.sourceControl.inputBox
    groups = $refreshLoadOpenReport.sourceControl.groups
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$refreshLoadPostResourceRefreshResources = @($openReport.sourceControl.groups[0].resources[0]) + @($refreshLoadResources | Select-Object -Skip 1)
$refreshLoadResourceRefreshCoverage = [pscustomobject]@{
  repositoryId = $refreshLoadOpenReport.repository.repositoryId
  epoch = $refreshLoadOpenReport.repository.epoch
  generation = 2
  targets = @(
    [pscustomobject]@{
      path = "load/modified-001.txt"
      depth = "empty"
      reason = "resourceRefresh"
    }
  )
  coverage = @(
    [pscustomobject]@{
      path = "load/modified-001.txt"
      depth = "empty"
      generation = 2
      reason = "resourceRefresh"
    }
  )
  completeness = "partial"
  timestamp = "2026-06-25T00:00:04Z"
  source = "libsvn-local"
}
$refreshLoadPostResourceRefreshFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:04Z"
  scenario = "partial"
  repository = $refreshLoadOpenReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $refreshLoadOpenReport.sourceControl.repositoryId
    epoch = $refreshLoadOpenReport.sourceControl.epoch
    workingCopyRoot = $refreshLoadOpenReport.sourceControl.workingCopyRoot
    generation = 2
    count = $refreshLoadItemCount
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "delta"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($refreshLoadOpenReport.repository.repositoryId)
      }
    )
    inputBox = $refreshLoadOpenReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{
        id = "changes"
        contextValue = "subversionr.changes"
        hideWhenEmpty = $true
        count = $refreshLoadItemCount
        resources = $refreshLoadPostResourceRefreshResources
      },
      $openReport.sourceControl.groups[1]
    )
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
  lastCompletedRefresh = $refreshLoadResourceRefreshCoverage
}
$refreshLoadReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eRefreshLoadWorkflow"
  generatedAt = "2026-06-25T00:00:03Z"
  command = [pscustomobject]@{
    command = "subversionr.refreshRepository"
  }
  repository = [pscustomobject]@{
    repositoryId = $refreshLoadOpenReport.repository.repositoryId
    epoch = $refreshLoadOpenReport.repository.epoch
    workingCopyRoot = $refreshLoadWorkingCopyRoot
  }
  load = [pscustomobject]@{
    requestedModifiedItemCount = $refreshLoadItemCount
    projectedModifiedItemCountBefore = $refreshLoadItemCount
    projectedModifiedItemCountAfter = $refreshLoadItemCount
    modifiedPaths = @($refreshLoadResources | ForEach-Object { $_.path })
  }
  resourceRefresh = [pscustomobject]@{
    command = [pscustomobject]@{
      command = "subversionr.refreshResource"
    }
    restoredPath = "load/modified-001.txt"
    projectedModifiedItemCountBefore = $refreshLoadItemCount
    projectedModifiedItemCountAfter = $refreshLoadItemCount - 1
    projectedRestoredItemCountAfter = 0
    coverage = $refreshLoadResourceRefreshCoverage
    postRefreshFreshnessReport = $refreshLoadPostResourceRefreshFreshnessReport
  }
  openReport = $refreshLoadOpenReport
  postRefreshFreshnessReport = $refreshLoadPostRefreshFreshnessReport
  closeReport = [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eCloseReport"
    generatedAt = "2026-06-25T00:00:03Z"
    repositoryId = $refreshLoadOpenReport.repository.repositoryId
    epoch = $refreshLoadOpenReport.repository.epoch
    repositoryClosed = $true
  }
  assertions = [pscustomobject]@{
    commandExecuted = $true
    repositoryOpenBefore = $true
    allLoadResourcesProjectedBefore = $true
    allLoadResourcesProjectedAfter = $true
    sourceControlSurfaceAfterRefresh = $true
    restoredPathProjectedBefore = $true
    sourceControlProjectionRemovedRestoredPath = $true
    restoredPathCoverageMatched = $true
    restoredPathCoverageGenerationMatched = $true
    sourceControlSurfaceAfterResourceRefresh = $true
  }
}
$dirtyGenerationCancellationRecoveryCoverage = [pscustomobject]@{
  repositoryId = $refreshLoadOpenReport.repository.repositoryId
  epoch = $refreshLoadOpenReport.repository.epoch
  generation = 9
  targets = @(
    [pscustomobject]@{
      path = "load/modified-002.txt"
      depth = "empty"
      reason = "fileChanged"
    },
    [pscustomobject]@{
      path = "load/modified-003.txt"
      depth = "empty"
      reason = "fileChanged"
    }
  )
  coverage = @(
    [pscustomobject]@{
      path = "load/modified-002.txt"
      depth = "empty"
      generation = 9
      reason = "fileChanged"
    },
    [pscustomobject]@{
      path = "load/modified-003.txt"
      depth = "empty"
      generation = 9
      reason = "fileChanged"
    }
  )
  completeness = "partial"
  timestamp = "2026-06-25T00:00:04Z"
  source = "test"
}
$dirtyGenerationCancellationStaleFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:04Z"
  scenario = "stale"
  repository = $refreshLoadOpenReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $refreshLoadOpenReport.sourceControl.repositoryId
    epoch = $refreshLoadOpenReport.sourceControl.epoch
    workingCopyRoot = $refreshLoadOpenReport.sourceControl.workingCopyRoot
    generation = 8
    count = $refreshLoadItemCount
    freshness = [pscustomobject]@{
      repositoryCompleteness = "stale"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "delta"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status stale"
        arguments = @($refreshLoadOpenReport.repository.repositoryId)
      }
    )
    inputBox = $refreshLoadOpenReport.sourceControl.inputBox
    groups = $refreshLoadOpenReport.sourceControl.groups
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$dirtyGenerationCancellationRecoveryFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:05Z"
  scenario = "partial"
  repository = $refreshLoadOpenReport.repository
  sourceControl = $refreshLoadPostRefreshFreshnessReport.sourceControl
  freshnessWorkflow = $refreshLoadPostRefreshFreshnessReport.freshnessWorkflow
  lastCompletedRefresh = $dirtyGenerationCancellationRecoveryCoverage
}
$dirtyGenerationCancellationLoadWorkflow = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eDirtyGenerationCancellationLoadWorkflow"
  generatedAt = "2026-06-25T00:00:05Z"
  command = [pscustomobject]@{
    command = "subversionr.refreshRepository"
  }
  repository = [pscustomobject]@{
    repositoryId = $refreshLoadOpenReport.repository.repositoryId
    epoch = $refreshLoadOpenReport.repository.epoch
    workingCopyRoot = $refreshLoadWorkingCopyRoot
  }
  armReport = [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eDirtyGenerationCancellationArmReport"
    holdId = "dirty-generation-1"
    repositoryId = $refreshLoadOpenReport.repository.repositoryId
    epoch = $refreshLoadOpenReport.repository.epoch
    timeoutMs = 60000
    target = [pscustomobject]@{
      path = "load/modified-002.txt"
      depth = "empty"
      reason = "fileChanged"
    }
    armed = $true
  }
  firstDirtyEventReport = [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eDirtyEventReport"
    repositoryId = $refreshLoadOpenReport.repository.repositoryId
    accepted = $true
    event = [pscustomobject]@{
      fsPath = Join-Path $refreshLoadWorkingCopyRoot "load/modified-002.txt"
      kind = "changed"
    }
  }
  secondDirtyEventReport = [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eDirtyEventReport"
    repositoryId = $refreshLoadOpenReport.repository.repositoryId
    accepted = $true
    event = [pscustomobject]@{
      fsPath = Join-Path $refreshLoadWorkingCopyRoot "load/modified-003.txt"
      kind = "changed"
    }
  }
  cancellationReport = [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eDirtyGenerationCancellationReport"
    holdId = "dirty-generation-1"
    repositoryId = $refreshLoadOpenReport.repository.repositoryId
    epoch = $refreshLoadOpenReport.repository.epoch
    target = [pscustomobject]@{
      path = "load/modified-002.txt"
      depth = "empty"
      reason = "fileChanged"
    }
    observed = $true
    cancellationObserved = $true
    refreshStatusSignalProvided = $true
    signalAborted = $true
    assertions = [pscustomobject]@{
      matchedDirtyGenerationTarget = $true
      signalProvided = $true
      signalAborted = $true
      cancellationObserved = $true
    }
  }
  postCancellationFreshnessReport = $dirtyGenerationCancellationStaleFreshnessReport
  postCancellationRefreshResult = [pscustomobject]@{
    attempted = $true
    resolved = $true
  }
  postCancellationCompletionFreshnessReport = $dirtyGenerationCancellationRecoveryFreshnessReport
  postCancellationCompletionCoverage = $dirtyGenerationCancellationRecoveryCoverage
  assertions = [pscustomobject]@{
    firstDirtyEventAccepted = $true
    secondDirtyEventAccepted = $true
    firstRefreshObservedBeforeSupersede = $true
    cancellationReason = "dirtyGenerationSuperseded"
    cancellationObserved = $true
    signalAborted = $true
    postCancellationStaleCaptureAvailable = $true
    postCancellationRefreshAttempted = $true
    completedCoverageMatchedSupersededTargets = $true
    sourceControlSurfaceAfterCompletion = $true
  }
}
$multiRepositoryRefreshOpenReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eOpenReport"
  generatedAt = "2026-06-25T00:00:03Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$multiRepositoryRefreshWorkingCopyRoot"
    epoch = 5
    identity = [pscustomobject]@{
      repositoryUuid = "fixture-multi-repository-refresh-repository-uuid"
      repositoryRootUrl = "file:///fixture/multi-repository-refresh/repo"
      workingCopyRoot = $multiRepositoryRefreshWorkingCopyRoot
      workspaceScopeRoot = $multiRepositoryRefreshWorkingCopyRoot
      format = 31
    }
  }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$multiRepositoryRefreshWorkingCopyRoot"
    epoch = 5
    workingCopyRoot = $multiRepositoryRefreshWorkingCopyRoot
    generation = 1
    count = 1
    inputBox = $openReport.sourceControl.inputBox
    groups = $openReport.sourceControl.groups
  }
  rendererCaptureExpectations = $openReport.rendererCaptureExpectations
  surfaceWorkflow = $openReport.surfaceWorkflow
}
$multiRepositoryRefreshPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("svn-fixture", "multi-repository-refresh-fixture")
  requiredAccessibilityTokens = @("svn-fixture", "multi-repository-refresh-fixture")
  requiredScreenshot = $true
  quickPickItemText = $multiRepositoryRefreshWorkingCopyRoot
}
[pscustomobject]@{
  ok = $true
  phase = "multiRepositoryRefreshPromptReady"
  command = "subversionr.refreshRepository"
  firstRepository = [pscustomobject]@{
    repositoryId = $openReport.repository.repositoryId
    epoch = $openReport.repository.epoch
    workingCopyRoot = $workingCopyRoot
  }
  selectedRepository = [pscustomobject]@{
    repositoryId = $multiRepositoryRefreshOpenReport.repository.repositoryId
    epoch = $multiRepositoryRefreshOpenReport.repository.epoch
    workingCopyRoot = $multiRepositoryRefreshWorkingCopyRoot
  }
  rendererCaptureExpectations = $multiRepositoryRefreshPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $multiRepositoryRefreshPromptReadyPath -Encoding utf8
$multiRepositoryPostRefreshFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:03Z"
  scenario = "partial"
  repository = $multiRepositoryRefreshOpenReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $multiRepositoryRefreshOpenReport.sourceControl.repositoryId
    epoch = $multiRepositoryRefreshOpenReport.sourceControl.epoch
    workingCopyRoot = $multiRepositoryRefreshOpenReport.sourceControl.workingCopyRoot
    generation = $multiRepositoryRefreshOpenReport.sourceControl.generation
    count = $multiRepositoryRefreshOpenReport.sourceControl.count
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($multiRepositoryRefreshOpenReport.repository.repositoryId)
      }
    )
    inputBox = $multiRepositoryRefreshOpenReport.sourceControl.inputBox
    groups = $multiRepositoryRefreshOpenReport.sourceControl.groups
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$multiRepositoryRefreshReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eMultiRepositoryRefreshWorkflow"
  generatedAt = "2026-06-25T00:00:03Z"
  command = [pscustomobject]@{
    command = "subversionr.refreshRepository"
  }
  firstRepository = [pscustomobject]@{
    repositoryId = $openReport.repository.repositoryId
    epoch = $openReport.repository.epoch
    workingCopyRoot = $workingCopyRoot
  }
  selectedRepository = [pscustomobject]@{
    repositoryId = $multiRepositoryRefreshOpenReport.repository.repositoryId
    epoch = $multiRepositoryRefreshOpenReport.repository.epoch
    workingCopyRoot = $multiRepositoryRefreshWorkingCopyRoot
  }
  selectedRepositoryOpenReport = $multiRepositoryRefreshOpenReport
  selection = [pscustomobject]@{
    selectedRepositoryId = $multiRepositoryRefreshOpenReport.repository.repositoryId
    selectedWorkingCopyRoot = $multiRepositoryRefreshWorkingCopyRoot
    quickPickItemText = $multiRepositoryRefreshWorkingCopyRoot
  }
  prompt = [pscustomobject]@{
    rendererCaptureExpectations = $multiRepositoryRefreshPromptExpectations
  }
  postRefreshFreshnessReport = $multiRepositoryPostRefreshFreshnessReport
  firstRepositoryFreshnessReport = $postRefreshFreshnessReport
  selectedRepositoryCloseReport = [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eCloseReport"
    generatedAt = "2026-06-25T00:00:03Z"
    repositoryId = $multiRepositoryRefreshOpenReport.repository.repositoryId
    epoch = $multiRepositoryRefreshOpenReport.repository.epoch
    repositoryClosed = $true
  }
  assertions = [pscustomobject]@{
    commandExecuted = $true
    quickPickSelectionRequired = $true
    selectedRepositoryDistinct = $true
    selectedRepositoryRefreshed = $true
    firstRepositoryStayedOpen = $true
    sourceControlSurfaceAfterRefresh = $true
  }
}
$lazyExternalDirectoryRoot = Join-Path $lazyExternalProviderWorkingCopyRoot "externals\library"
$lazyExternalFileBoundary = Join-Path $lazyExternalProviderWorkingCopyRoot "externals\pinned.txt"
$lazyExternalProviderReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eLazyExternalProviderReport"
  generatedAt = "2026-06-25T00:00:04Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  request = [pscustomobject]@{
    path = $lazyExternalProviderWorkingCopyRoot
    discoveryDepth = 4
    externalsMode = "lazy"
  }
  discovery = [pscustomobject]@{
    candidates = @(
      [pscustomobject]@{
        identity = [pscustomobject]@{
          repositoryUuid = "fixture-lazy-external-parent-uuid"
          repositoryRootUrl = "file:///fixture/lazy-external/parent-repo"
          workingCopyRoot = $lazyExternalProviderWorkingCopyRoot
          workspaceScopeRoot = $lazyExternalProviderWorkingCopyRoot
          format = 31
        }
        isNested = $false
        isExternal = $false
      },
      [pscustomobject]@{
        identity = [pscustomobject]@{
          repositoryUuid = "fixture-lazy-external-directory-uuid"
          repositoryRootUrl = "file:///fixture/lazy-external/external-repo"
          workingCopyRoot = $lazyExternalDirectoryRoot
          workspaceScopeRoot = $lazyExternalDirectoryRoot
          format = 31
        }
        isNested = $false
        isExternal = $true
        parentWorkingCopyRoot = $lazyExternalProviderWorkingCopyRoot
      }
    )
    fileExternalBoundaries = @($lazyExternalFileBoundary)
  }
  parentProvider = [pscustomobject]@{
    repositoryId = "repo-uuid:$lazyExternalProviderWorkingCopyRoot"
    epoch = 1
    workingCopyRoot = $lazyExternalProviderWorkingCopyRoot
    boundaryRoots = @($lazyExternalDirectoryRoot, $lazyExternalFileBoundary)
    sourceControl = [pscustomobject]@{
      repositoryId = "repo-uuid:$lazyExternalProviderWorkingCopyRoot"
      epoch = 1
      workingCopyRoot = $lazyExternalProviderWorkingCopyRoot
      generation = 1
      count = 1
      inputBox = $openReport.sourceControl.inputBox
      groups = @(
        [pscustomobject]@{
          id = "changes"
          contextValue = "subversionr.changes"
          hideWhenEmpty = $true
          count = 1
          resources = @(
            [pscustomobject]@{
              path = "src/tracked.txt"
              contextValue = "subversionr.changedFile.baseDiffable"
              kind = "file"
              generation = 1
            }
          )
        }
      )
    }
  }
  externalProviders = @(
    [pscustomobject]@{
      repositoryId = "repo-uuid:$lazyExternalDirectoryRoot"
      epoch = 1
      workingCopyRoot = $lazyExternalDirectoryRoot
      parentWorkingCopyRoot = $lazyExternalProviderWorkingCopyRoot
      sourceControl = [pscustomobject]@{
        repositoryId = "repo-uuid:$lazyExternalDirectoryRoot"
        epoch = 1
        workingCopyRoot = $lazyExternalDirectoryRoot
        generation = 1
        count = 1
        inputBox = $openReport.sourceControl.inputBox
        groups = @(
          [pscustomobject]@{
            id = "changes"
            contextValue = "subversionr.changes"
            hideWhenEmpty = $true
            count = 1
            resources = @(
              [pscustomobject]@{
                path = "src/tracked.txt"
                contextValue = "subversionr.changedFile.baseDiffable"
                kind = "file"
                generation = 1
              }
            )
          }
        )
      }
    }
  )
  assertions = [pscustomobject]@{
    lazyDiscoveryRequested = $true
    directoryExternalDiscovered = $true
    fileExternalBoundariesDiscovered = $true
    parentBoundaryRootsIncludedDirectoryExternal = $true
    parentBoundaryRootsIncludedFileExternal = $true
    distinctExternalProviderOpened = $true
    parentSourceControlExcludedExternalBoundaries = $true
    providersClosed = $true
  }
}
$boundaryLoadParentResources = 1..$boundaryLoadParentModifiedItemCount | ForEach-Object {
  [pscustomobject]@{
    path = ("load/modified-{0:D3}.txt" -f $_)
    contextValue = "subversionr.changedFile.baseDiffable"
    kind = "file"
    generation = 1
  }
}
$boundaryLoadExternalResources = 1..$boundaryLoadBoundaryModifiedItemCount | ForEach-Object {
  [pscustomobject]@{
    path = ("load/modified-{0:D3}.txt" -f $_)
    contextValue = "subversionr.changedFile.baseDiffable"
    kind = "file"
    generation = 1
  }
}
$boundaryLoadDirectoryRoot = Join-Path $boundaryLoadWorkingCopyRoot "externals\library"
$boundaryLoadFileBoundary = Join-Path $boundaryLoadWorkingCopyRoot "externals\pinned.txt"
$boundaryLoadReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eBoundaryLoadWorkflow"
  generatedAt = "2026-06-25T00:00:05Z"
  command = [pscustomobject]@{
    command = "subversionr.diagnostics.installedSourceControlUiE2eLazyExternalProviderReport"
  }
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$boundaryLoadWorkingCopyRoot"
    epoch = 1
    workingCopyRoot = $boundaryLoadWorkingCopyRoot
    boundaryRoots = @($boundaryLoadDirectoryRoot, $boundaryLoadFileBoundary)
  }
  load = [pscustomobject]@{
    requestedParentModifiedItemCount = $boundaryLoadParentModifiedItemCount
    requestedBoundaryModifiedItemCount = $boundaryLoadBoundaryModifiedItemCount
    projectedParentModifiedItemCount = $boundaryLoadParentModifiedItemCount
    projectedBoundaryModifiedItemCount = 0
    projectedExternalModifiedItemCount = $boundaryLoadBoundaryModifiedItemCount
    parentModifiedPaths = @($boundaryLoadParentResources | ForEach-Object { $_.path })
    boundaryModifiedPaths = @($boundaryLoadExternalResources | ForEach-Object { "externals/library/$($_.path)" })
  }
  lazyExternalProviderReport = [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eLazyExternalProviderReport"
    parentProvider = [pscustomobject]@{
      repositoryId = "repo-uuid:$boundaryLoadWorkingCopyRoot"
      epoch = 1
      workingCopyRoot = $boundaryLoadWorkingCopyRoot
      boundaryRoots = @($boundaryLoadDirectoryRoot, $boundaryLoadFileBoundary)
      sourceControl = [pscustomobject]@{
        repositoryId = "repo-uuid:$boundaryLoadWorkingCopyRoot"
        epoch = 1
        workingCopyRoot = $boundaryLoadWorkingCopyRoot
        generation = 1
        count = 1
        inputBox = $openReport.sourceControl.inputBox
        groups = @(
          [pscustomobject]@{
            id = "changes"
            contextValue = "subversionr.changes"
            hideWhenEmpty = $true
            count = $boundaryLoadParentModifiedItemCount
            resources = $boundaryLoadParentResources
          }
        )
      }
    }
    externalProviders = @(
      [pscustomobject]@{
        repositoryId = "repo-uuid:$boundaryLoadDirectoryRoot"
        epoch = 1
        workingCopyRoot = $boundaryLoadDirectoryRoot
        parentWorkingCopyRoot = $boundaryLoadWorkingCopyRoot
        sourceControl = [pscustomobject]@{
          repositoryId = "repo-uuid:$boundaryLoadDirectoryRoot"
          epoch = 1
          workingCopyRoot = $boundaryLoadDirectoryRoot
          generation = 1
          count = 1
          inputBox = $openReport.sourceControl.inputBox
          groups = @(
            [pscustomobject]@{
              id = "changes"
              contextValue = "subversionr.changes"
              hideWhenEmpty = $true
              count = $boundaryLoadBoundaryModifiedItemCount
              resources = $boundaryLoadExternalResources
            }
          )
        }
      }
    )
  }
  assertions = [pscustomobject]@{
    boundaryRootsPresent = $true
    allParentLoadResourcesProjected = $true
    noBoundaryLoadResourcesProjected = $true
    allExternalLoadResourcesProjectedByExternalProvider = $true
    sourceControlSurfaceAvailable = $true
  }
}
$deleteUnversionedFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:04Z"
  scenario = "partial"
  repository = $openReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $openReport.sourceControl.repositoryId
    epoch = $openReport.sourceControl.epoch
    workingCopyRoot = $openReport.sourceControl.workingCopyRoot
    generation = 2
    count = 2
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($openReport.repository.repositoryId)
      }
    )
    inputBox = $openReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{
        id = "changes"
        contextValue = "subversionr.changes"
        hideWhenEmpty = $true
        count = 1
        resources = @(
          [pscustomobject]@{
            path = "src/tracked.txt"
            contextValue = "subversionr.changedFile.baseDiffable"
            kind = "file"
            generation = 2
          }
        )
      },
      [pscustomobject]@{
        id = "unversioned"
        contextValue = "subversionr.unversioned"
        hideWhenEmpty = $true
        count = 1
        resources = @(
          [pscustomobject]@{
            path = "scratch.txt"
            contextValue = "subversionr.unversioned"
            kind = "file"
            generation = 2
          }
        )
      }
    )
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$deletePromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Delete unversioned SVN item scratch.txt? This cannot be undone.", "Delete")
  requiredAccessibilityTokens = @("Delete unversioned SVN item scratch.txt? This cannot be undone.", "Delete")
  requiredScreenshot = $true
  clickButtonText = "Delete"
}
[pscustomobject]@{
  ok = $true
  phase = "deleteUnversionedPromptReady"
  command = "subversionr.deleteUnversionedResource"
  resource = [pscustomobject]@{
    path = "scratch.txt"
    contextValue = "subversionr.unversioned"
    kind = "file"
    generation = 2
  }
  rendererCaptureExpectations = $deletePromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $deletePromptReadyPath -Encoding utf8
$scratchPath = Join-Path $workingCopyRoot "scratch.txt"
$fileExistedBefore = Test-Path -LiteralPath $scratchPath -PathType Leaf
Remove-Item -LiteralPath $scratchPath -Force -ErrorAction SilentlyContinue
$postDeleteFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:04Z"
  scenario = "partial"
  repository = $openReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $openReport.sourceControl.repositoryId
    epoch = $openReport.sourceControl.epoch
    workingCopyRoot = $openReport.sourceControl.workingCopyRoot
    generation = 2
    count = 1
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($openReport.repository.repositoryId)
      }
    )
    inputBox = $openReport.sourceControl.inputBox
    groups = @(
      $openReport.sourceControl.groups[0],
      [pscustomobject]@{
        id = "changes"
        contextValue = "subversionr.changes"
        hideWhenEmpty = $true
        count = 1
        resources = @(
          [pscustomobject]@{
            path = "."
            contextValue = "subversionr.changedDirectory"
            kind = "dir"
            generation = 2
          }
        )
      },
      [pscustomobject]@{
        id = "unversioned"
        contextValue = "subversionr.unversioned"
        hideWhenEmpty = $true
        count = 0
        resources = @()
      }
    )
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$deleteUnversionedReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eDeleteUnversionedWorkflow"
  generatedAt = "2026-06-25T00:00:04Z"
  command = [pscustomobject]@{
    command = "subversionr.deleteUnversionedResource"
  }
  resource = [pscustomobject]@{
    path = "scratch.txt"
    contextValue = "subversionr.unversioned"
    kind = "file"
    generation = 2
  }
  prompt = [pscustomobject]@{
    confirmationButton = "Delete"
    rendererCaptureExpectations = $deletePromptExpectations
  }
  postDeleteFreshnessReport = $postDeleteFreshnessReport
  assertions = [pscustomobject]@{
    commandExecuted = $true
    fileExistedBefore = $fileExistedBefore
    fileExistsAfter = $false
    resourcePresentAfter = $false
    sourceControlProjectionRefreshed = $true
  }
}
$loadResources = 1..$loadItemCount | ForEach-Object {
  [pscustomobject]@{
    path = ("unversioned-load-{0:D3}.txt" -f $_)
    contextValue = "subversionr.unversioned"
    kind = "file"
    generation = 1
  }
}
$loadOpenReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eOpenReport"
  generatedAt = "2026-06-25T00:00:05Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$loadWorkingCopyRoot"
    epoch = 4
    identity = [pscustomobject]@{
      repositoryUuid = "fixture-load-repository-uuid"
      repositoryRootUrl = "file:///fixture/load/repo"
      workingCopyRoot = $loadWorkingCopyRoot
      workspaceScopeRoot = $loadWorkingCopyRoot
      format = 31
    }
  }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$loadWorkingCopyRoot"
    epoch = 4
    workingCopyRoot = $loadWorkingCopyRoot
    generation = 1
    count = 1
    inputBox = $openReport.sourceControl.inputBox
    groups = @(
      $openReport.sourceControl.groups[0],
      [pscustomobject]@{
        id = "unversioned"
        contextValue = "subversionr.unversioned"
        hideWhenEmpty = $true
        count = $loadItemCount
        resources = $loadResources
      }
    )
  }
  rendererCaptureExpectations = $openReport.rendererCaptureExpectations
  surfaceWorkflow = $openReport.surfaceWorkflow
}
$deleteLoadPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Delete $loadItemCount unversioned SVN items? This cannot be undone.", "Delete")
  requiredAccessibilityTokens = @("Delete $loadItemCount unversioned SVN items? This cannot be undone.", "Delete")
  requiredScreenshot = $true
  clickButtonText = "Delete"
}
[pscustomobject]@{
  ok = $true
  phase = "deleteUnversionedLoadPromptReady"
  command = "subversionr.deleteAllUnversionedResources"
  repositoryId = $loadOpenReport.repository.repositoryId
  loadItemCount = $loadItemCount
  rendererCaptureExpectations = $deleteLoadPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $deleteLoadPromptReadyPath -Encoding utf8
$loadPaths = @($loadResources | ForEach-Object { Join-Path $loadWorkingCopyRoot $_.path })
$allFilesExistedBefore = (@($loadPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -eq $loadItemCount)
foreach ($loadPath in $loadPaths) {
  Remove-Item -LiteralPath $loadPath -Force -ErrorAction SilentlyContinue
}
$anyLoadFileExistsAfter = (@($loadPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -gt 0)
$postDeleteLoadFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:06Z"
  scenario = "partial"
  repository = $loadOpenReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $loadOpenReport.sourceControl.repositoryId
    epoch = $loadOpenReport.sourceControl.epoch
    workingCopyRoot = $loadOpenReport.sourceControl.workingCopyRoot
    generation = 2
    count = 1
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($loadOpenReport.repository.repositoryId)
      }
    )
    inputBox = $loadOpenReport.sourceControl.inputBox
    groups = @(
      $loadOpenReport.sourceControl.groups[0],
      [pscustomobject]@{
        id = "unversioned"
        contextValue = "subversionr.unversioned"
        hideWhenEmpty = $true
        count = 0
        resources = @()
      }
    )
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$deleteUnversionedLoadReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eDeleteUnversionedLoadWorkflow"
  generatedAt = "2026-06-25T00:00:06Z"
  command = [pscustomobject]@{
    command = "subversionr.deleteAllUnversionedResources"
  }
  repository = [pscustomobject]@{
    repositoryId = $loadOpenReport.repository.repositoryId
    epoch = $loadOpenReport.repository.epoch
    workingCopyRoot = $loadWorkingCopyRoot
  }
  load = [pscustomobject]@{
    requestedItemCount = $loadItemCount
    projectedItemCountBefore = $loadItemCount
    projectedItemCountAfter = 0
  }
  prompt = [pscustomobject]@{
    confirmationButton = "Delete"
    rendererCaptureExpectations = $deleteLoadPromptExpectations
  }
  postDeleteFreshnessReport = $postDeleteLoadFreshnessReport
  closeReport = [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eCloseReport"
    generatedAt = "2026-06-25T00:00:07Z"
    repositoryId = $loadOpenReport.repository.repositoryId
    epoch = $loadOpenReport.repository.epoch
    repositoryClosed = $true
  }
  assertions = [pscustomobject]@{
    commandExecuted = $true
    allFilesExistedBefore = $allFilesExistedBefore
    anyFileExistsAfter = $anyLoadFileExistsAfter
    sourceControlProjectionCleared = $true
  }
}
$commitAllOpenReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eOpenReport"
  generatedAt = "2026-06-25T00:00:06Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$commitAllWorkingCopyRoot"
    epoch = 6
    identity = [pscustomobject]@{
      repositoryUuid = "fixture-commit-all-repository-uuid"
      repositoryRootUrl = "file:///fixture/commit-all/repo"
      workingCopyRoot = $commitAllWorkingCopyRoot
      workspaceScopeRoot = $commitAllWorkingCopyRoot
      format = 31
    }
  }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$commitAllWorkingCopyRoot"
    epoch = 6
    workingCopyRoot = $commitAllWorkingCopyRoot
    generation = 1
    count = 1
    inputBox = [pscustomobject]@{
      placeholder = "SVN commit message"
      acceptInputCommand = "subversionr.commitAll"
      acceptInputCommandArguments = @("repo-uuid:$commitAllWorkingCopyRoot")
    }
    groups = $openReport.sourceControl.groups
  }
  rendererCaptureExpectations = $openReport.rendererCaptureExpectations
  surfaceWorkflow = $openReport.surfaceWorkflow
}
$commitAllScratchPath = Join-Path $commitAllWorkingCopyRoot "scratch.txt"
$commitAllScratchExistsAfter = Test-Path -LiteralPath $commitAllScratchPath -PathType Leaf
$postCommitAllFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:06Z"
  scenario = "partial"
  repository = $commitAllOpenReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $commitAllOpenReport.sourceControl.repositoryId
    epoch = $commitAllOpenReport.sourceControl.epoch
    workingCopyRoot = $commitAllOpenReport.sourceControl.workingCopyRoot
    generation = 2
    count = 0
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($commitAllOpenReport.repository.repositoryId)
      }
    )
    inputBox = $commitAllOpenReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{
        id = "changes"
        contextValue = "subversionr.changes"
        hideWhenEmpty = $true
        count = 0
        resources = @()
      },
      $commitAllOpenReport.sourceControl.groups[1]
    )
  }
  lastCompletedRefresh = [pscustomobject]@{
    repositoryId = $commitAllOpenReport.repository.repositoryId
    epoch = $commitAllOpenReport.repository.epoch
    targets = @(
      [pscustomobject]@{
        path = "src/tracked.txt"
        depth = "empty"
        reason = "operationCommit"
      }
    )
    coverage = @(
      [pscustomobject]@{
        path = "src/tracked.txt"
        depth = "empty"
        reason = "operationCommit"
        generation = 2
      }
    )
    generation = 2
    completeness = "partial"
    timestamp = "2026-06-25T00:00:06Z"
    source = "libsvn-local"
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$commitAllReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCommitAllWorkflow"
  generatedAt = "2026-06-25T00:00:06Z"
  command = [pscustomobject]@{
    command = "subversionr.commitAll"
    sourceControlAcceptInputCommand = "subversionr.commitAll"
    arguments = @($commitAllOpenReport.repository.repositoryId)
  }
  repository = [pscustomobject]@{
    repositoryId = $commitAllOpenReport.repository.repositoryId
    epoch = $commitAllOpenReport.repository.epoch
    workingCopyRoot = $commitAllWorkingCopyRoot
  }
  input = [pscustomobject]@{
    messageLength = "commit all eligible changed file resources for the repository input message".Length
    setInputReport = [pscustomobject]@{
      kind = "subversionr.installedSourceControlUiE2eSetInputMessageReport"
      repositoryId = $commitAllOpenReport.repository.repositoryId
      previousMessageLength = 0
      messageLength = "commit all eligible changed file resources for the repository input message".Length
      inputMessageSet = $true
    }
    postCommitProbePreviousMessageLength = 0
  }
  targets = [pscustomobject]@{
    eligiblePaths = @("src/tracked.txt")
    excludedUnversionedPaths = @("scratch.txt")
  }
  postCommitFreshnessReport = $postCommitAllFreshnessReport
  closeReport = [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eCloseReport"
    generatedAt = "2026-06-25T00:00:06Z"
    repositoryId = $commitAllOpenReport.repository.repositoryId
    epoch = $commitAllOpenReport.repository.epoch
    repositoryClosed = $true
  }
  assertions = [pscustomobject]@{
    commandExecuted = $true
    inputMessageWasSet = $true
    inputMessageClearedAfterCommit = $true
    trackedFileCommitted = $true
    unversionedPathRemainedUnversioned = $commitAllScratchExistsAfter
    sourceControlProjectionClearedCommittedPath = $true
    targetedReconcileAfterCommit = $true
  }
}
$commitAllRepositoryOracle = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCommitAllRepositoryOracle"
  trackedFileUrl = "file:///fixture/commit-all/repo/trunk/src/tracked.txt"
  trackedFileContent = "modified by M7j3"
  latestLogContainsCommitMessage = $true
  unversionedScratchUrl = "file:///fixture/commit-all/repo/trunk/scratch.txt"
  unversionedScratchAbsentFromRepository = $true
}
$commitSelectedChangesGroup = [pscustomobject]@{
  id = "changes"
  contextValue = "subversionr.changes"
  hideWhenEmpty = $true
  count = 2
  resources = @(
    [pscustomobject]@{
      path = "src/tracked.txt"
      contextValue = "subversionr.changedFile.baseDiffable"
      kind = "file"
      generation = 1
    },
    [pscustomobject]@{
      path = "load/modified-001.txt"
      contextValue = "subversionr.changedFile.baseDiffable"
      kind = "file"
      generation = 1
    }
  )
}
$commitSelectedOpenReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eOpenReport"
  generatedAt = "2026-06-25T00:00:06Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$commitSelectedWorkingCopyRoot"
    epoch = 7
    identity = [pscustomobject]@{
      repositoryUuid = "fixture-commit-selected-repository-uuid"
      repositoryRootUrl = "file:///fixture/commit-selected/repo"
      workingCopyRoot = $commitSelectedWorkingCopyRoot
      workspaceScopeRoot = $commitSelectedWorkingCopyRoot
      format = 31
    }
  }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$commitSelectedWorkingCopyRoot"
    epoch = 7
    workingCopyRoot = $commitSelectedWorkingCopyRoot
    generation = 1
    count = 2
    inputBox = [pscustomobject]@{
      placeholder = "SVN commit message"
      acceptInputCommand = "subversionr.commitAll"
      acceptInputCommandArguments = @("repo-uuid:$commitSelectedWorkingCopyRoot")
    }
    groups = @(
      $commitSelectedChangesGroup,
      $openReport.sourceControl.groups[1]
    )
  }
  rendererCaptureExpectations = $openReport.rendererCaptureExpectations
  surfaceWorkflow = $openReport.surfaceWorkflow
}
$postCommitSelectedFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:06Z"
  scenario = "partial"
  repository = $commitSelectedOpenReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $commitSelectedOpenReport.sourceControl.repositoryId
    epoch = $commitSelectedOpenReport.sourceControl.epoch
    workingCopyRoot = $commitSelectedOpenReport.sourceControl.workingCopyRoot
    generation = 2
    count = 1
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($commitSelectedOpenReport.repository.repositoryId)
      }
    )
    inputBox = $commitSelectedOpenReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{
        id = "changes"
        contextValue = "subversionr.changes"
        hideWhenEmpty = $true
        count = 1
        resources = @($commitSelectedChangesGroup.resources[1])
      },
      $commitSelectedOpenReport.sourceControl.groups[1]
    )
  }
  lastCompletedRefresh = [pscustomobject]@{
    repositoryId = $commitSelectedOpenReport.repository.repositoryId
    epoch = $commitSelectedOpenReport.repository.epoch
    targets = @(
      [pscustomobject]@{
        path = "src/tracked.txt"
        depth = "empty"
        reason = "operationCommit"
      }
    )
    coverage = @(
      [pscustomobject]@{
        path = "src/tracked.txt"
        depth = "empty"
        reason = "operationCommit"
        generation = 2
      }
    )
    generation = 2
    completeness = "partial"
    timestamp = "2026-06-25T00:00:06Z"
    source = "libsvn-local"
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$commitSelectedReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCommitSelectedWorkflow"
  generatedAt = "2026-06-25T00:00:06Z"
  command = [pscustomobject]@{
    command = "subversionr.commitResource"
    argument = [pscustomobject]@{
      path = "src/tracked.txt"
      contextValue = "subversionr.changedFile.baseDiffable"
      kind = "file"
      generation = 1
    }
  }
  repository = [pscustomobject]@{
    repositoryId = $commitSelectedOpenReport.repository.repositoryId
    epoch = $commitSelectedOpenReport.repository.epoch
    workingCopyRoot = $commitSelectedWorkingCopyRoot
  }
  input = [pscustomobject]@{
    messageLength = "commit selected SCM resource from the repository input message".Length
    setInputReport = [pscustomobject]@{
      kind = "subversionr.installedSourceControlUiE2eSetInputMessageReport"
      repositoryId = $commitSelectedOpenReport.repository.repositoryId
      previousMessageLength = 0
      messageLength = "commit selected SCM resource from the repository input message".Length
      inputMessageSet = $true
    }
    postCommitProbePreviousMessageLength = 0
  }
  targets = [pscustomobject]@{
    selectedPaths = @("src/tracked.txt")
    unselectedChangedPaths = @("load/modified-001.txt")
  }
  postCommitFreshnessReport = $postCommitSelectedFreshnessReport
  closeReport = [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eCloseReport"
    generatedAt = "2026-06-25T00:00:06Z"
    repositoryId = $commitSelectedOpenReport.repository.repositoryId
    epoch = $commitSelectedOpenReport.repository.epoch
    repositoryClosed = $true
  }
  assertions = [pscustomobject]@{
    commandExecuted = $true
    inputMessageWasSet = $true
    inputMessageClearedAfterCommit = $true
    selectedFileCommitted = $true
    unselectedFileStillModified = $true
    sourceControlProjectionClearedCommittedPath = $true
    targetedReconcileAfterCommit = $true
  }
}
$commitSelectedRepositoryOracle = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCommitSelectedRepositoryOracle"
  trackedFileUrl = "file:///fixture/commit-selected/repo/trunk/src/tracked.txt"
  trackedFileContent = "modified by M7j3"
  unselectedFileUrl = "file:///fixture/commit-selected/repo/trunk/load/modified-001.txt"
  unselectedFileRepositoryContent = "initial load item 1"
  latestLogContainsCommitMessage = $true
  unselectedFileRemainedUncommitted = $true
}
$commitSelectedMultiSelectionChangesGroup = [pscustomobject]@{
  id = "changes"
  contextValue = "subversionr.changes"
  hideWhenEmpty = $true
  count = 2
  resources = @(
    [pscustomobject]@{
      path = "src/tracked.txt"
      contextValue = "subversionr.changedFile.baseDiffable"
      kind = "file"
      generation = 1
    },
    [pscustomobject]@{
      path = "load/modified-001.txt"
      contextValue = "subversionr.changedFile.baseDiffable"
      kind = "file"
      generation = 1
    }
  )
}
$commitSelectedMultiSelectionOpenReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eOpenReport"
  generatedAt = "2026-06-25T00:00:06Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$commitSelectedMultiSelectionWorkingCopyRoot"
    epoch = 8
    identity = [pscustomobject]@{
      repositoryUuid = "fixture-commit-selected-multi-selection-repository-uuid"
      repositoryRootUrl = "file:///fixture/commit-selected-multi-selection/repo"
      workingCopyRoot = $commitSelectedMultiSelectionWorkingCopyRoot
      workspaceScopeRoot = $commitSelectedMultiSelectionWorkingCopyRoot
      format = 31
    }
  }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$commitSelectedMultiSelectionWorkingCopyRoot"
    epoch = 8
    workingCopyRoot = $commitSelectedMultiSelectionWorkingCopyRoot
    generation = 1
    count = 2
    inputBox = [pscustomobject]@{
      placeholder = "SVN commit message"
      acceptInputCommand = "subversionr.commitAll"
      acceptInputCommandArguments = @("repo-uuid:$commitSelectedMultiSelectionWorkingCopyRoot")
    }
    groups = @(
      $commitSelectedMultiSelectionChangesGroup,
      $openReport.sourceControl.groups[1]
    )
  }
  rendererCaptureExpectations = $openReport.rendererCaptureExpectations
  surfaceWorkflow = $openReport.surfaceWorkflow
}
$postCommitSelectedMultiSelectionFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:06Z"
  scenario = "partial"
  repository = $commitSelectedMultiSelectionOpenReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $commitSelectedMultiSelectionOpenReport.sourceControl.repositoryId
    epoch = $commitSelectedMultiSelectionOpenReport.sourceControl.epoch
    workingCopyRoot = $commitSelectedMultiSelectionOpenReport.sourceControl.workingCopyRoot
    generation = 2
    count = 0
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($commitSelectedMultiSelectionOpenReport.repository.repositoryId)
      }
    )
    inputBox = $commitSelectedMultiSelectionOpenReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{
        id = "changes"
        contextValue = "subversionr.changes"
        hideWhenEmpty = $true
        count = 0
        resources = @()
      },
      $commitSelectedMultiSelectionOpenReport.sourceControl.groups[1]
    )
  }
  lastCompletedRefresh = [pscustomobject]@{
    repositoryId = $commitSelectedMultiSelectionOpenReport.repository.repositoryId
    epoch = $commitSelectedMultiSelectionOpenReport.repository.epoch
    targets = @(
      [pscustomobject]@{
        path = "src/tracked.txt"
        depth = "empty"
        reason = "operationCommit"
      },
      [pscustomobject]@{
        path = "load/modified-001.txt"
        depth = "empty"
        reason = "operationCommit"
      }
    )
    coverage = @(
      [pscustomobject]@{
        path = "src/tracked.txt"
        depth = "empty"
        reason = "operationCommit"
        generation = 2
      },
      [pscustomobject]@{
        path = "load/modified-001.txt"
        depth = "empty"
        reason = "operationCommit"
        generation = 2
      }
    )
    generation = 2
    completeness = "partial"
    timestamp = "2026-06-25T00:00:06Z"
    source = "libsvn-local"
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$commitSelectedMultiSelectionReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCommitSelectedMultiSelectionWorkflow"
  generatedAt = "2026-06-25T00:00:06Z"
  command = [pscustomobject]@{
    command = "subversionr.commitResource"
    argumentShape = "resourceStateArray"
    arguments = @(
      [pscustomobject]@{
        path = "src/tracked.txt"
        contextValue = "subversionr.changedFile.baseDiffable"
        kind = "file"
        generation = 1
      },
      [pscustomobject]@{
        path = "load/modified-001.txt"
        contextValue = "subversionr.changedFile.baseDiffable"
        kind = "file"
        generation = 1
      }
    )
  }
  repository = [pscustomobject]@{
    repositoryId = $commitSelectedMultiSelectionOpenReport.repository.repositoryId
    epoch = $commitSelectedMultiSelectionOpenReport.repository.epoch
    workingCopyRoot = $commitSelectedMultiSelectionWorkingCopyRoot
  }
  input = [pscustomobject]@{
    messageLength = "commit selected SCM resources from a Source Control multi-selection".Length
    setInputReport = [pscustomobject]@{
      kind = "subversionr.installedSourceControlUiE2eSetInputMessageReport"
      repositoryId = $commitSelectedMultiSelectionOpenReport.repository.repositoryId
      previousMessageLength = 0
      messageLength = "commit selected SCM resources from a Source Control multi-selection".Length
      inputMessageSet = $true
    }
    postCommitProbePreviousMessageLength = 0
  }
  targets = [pscustomobject]@{
    selectedPaths = @("src/tracked.txt", "load/modified-001.txt")
  }
  postCommitFreshnessReport = $postCommitSelectedMultiSelectionFreshnessReport
  closeReport = [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eCloseReport"
    generatedAt = "2026-06-25T00:00:06Z"
    repositoryId = $commitSelectedMultiSelectionOpenReport.repository.repositoryId
    epoch = $commitSelectedMultiSelectionOpenReport.repository.epoch
    repositoryClosed = $true
  }
  assertions = [pscustomobject]@{
    commandExecuted = $true
    inputMessageWasSet = $true
    inputMessageClearedAfterCommit = $true
    allSelectedFilesCommitted = $true
    sourceControlProjectionClearedSelectedPaths = $true
    targetedReconcileAfterCommit = $true
  }
}
$addToIgnoreOpenReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eOpenReport"
  generatedAt = "2026-06-25T00:00:07Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$addToIgnoreWorkingCopyRoot"
    epoch = 6
    identity = [pscustomobject]@{
      repositoryUuid = "fixture-add-to-ignore-repository-uuid"
      repositoryRootUrl = "file:///fixture/add-to-ignore/repo"
      workingCopyRoot = $addToIgnoreWorkingCopyRoot
      workspaceScopeRoot = $addToIgnoreWorkingCopyRoot
      format = 31
    }
  }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$addToIgnoreWorkingCopyRoot"
    epoch = 6
    workingCopyRoot = $addToIgnoreWorkingCopyRoot
    generation = 1
    count = 1
    inputBox = $openReport.sourceControl.inputBox
    groups = $openReport.sourceControl.groups
  }
  rendererCaptureExpectations = $openReport.rendererCaptureExpectations
  surfaceWorkflow = $openReport.surfaceWorkflow
}
$postAddToIgnoreFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:07Z"
  scenario = "partial"
  repository = $addToIgnoreOpenReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $addToIgnoreOpenReport.sourceControl.repositoryId
    epoch = $addToIgnoreOpenReport.sourceControl.epoch
    workingCopyRoot = $addToIgnoreOpenReport.sourceControl.workingCopyRoot
    generation = 2
    count = 1
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($addToIgnoreOpenReport.repository.repositoryId)
      }
    )
    inputBox = $addToIgnoreOpenReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{
        id = "changes"
        contextValue = "subversionr.changes"
        hideWhenEmpty = $true
        count = 1
        resources = @(
          [pscustomobject]@{
            path = "."
            contextValue = "subversionr.changedDirectory"
            kind = "dir"
            generation = 2
          }
        )
      },
      [pscustomobject]@{
        id = "unversioned"
        contextValue = "subversionr.unversioned"
        hideWhenEmpty = $true
        count = 0
        resources = @()
      }
    )
  }
  lastCompletedRefresh = [pscustomobject]@{
    repositoryId = $addToIgnoreOpenReport.repository.repositoryId
    epoch = $addToIgnoreOpenReport.repository.epoch
    targets = @(
      [pscustomobject]@{
        path = "scratch.txt"
        depth = "empty"
        reason = "operationPropertySet"
      }
    )
    coverage = @(
      [pscustomobject]@{
        path = "scratch.txt"
        depth = "empty"
        reason = "operationPropertySet"
        generation = 2
      }
    )
    generation = 2
    completeness = "partial"
    timestamp = "2026-06-25T00:00:07Z"
    source = "libsvn-local"
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$addToIgnoreReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eAddToIgnoreWorkflow"
  generatedAt = "2026-06-25T00:00:07Z"
  command = [pscustomobject]@{
    command = "subversionr.addToIgnoreResource"
  }
  repository = [pscustomobject]@{
    repositoryId = $addToIgnoreOpenReport.repository.repositoryId
    epoch = $addToIgnoreOpenReport.repository.epoch
    workingCopyRoot = $addToIgnoreWorkingCopyRoot
  }
  resource = [pscustomobject]@{
    path = "scratch.txt"
    contextValue = "subversionr.unversioned"
    kind = "file"
    generation = 1
  }
  rootPropertyResource = [pscustomobject]@{
    path = "."
    contextValue = "subversionr.changedDirectory"
    kind = "dir"
    generation = 2
  }
  property = [pscustomobject]@{
    parentPath = "."
    name = "svn:ignore"
    addedPatterns = @("scratch.txt")
  }
  postIgnoreFreshnessReport = $postAddToIgnoreFreshnessReport
  closeReport = [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eCloseReport"
    generatedAt = "2026-06-25T00:00:07Z"
    repositoryId = $addToIgnoreOpenReport.repository.repositoryId
    epoch = $addToIgnoreOpenReport.repository.epoch
    repositoryClosed = $true
  }
  assertions = [pscustomobject]@{
    commandExecuted = $true
    propertyListReadBeforeSet = $true
    propertySetExecuted = $true
    workingCopyIgnorePropertyUpdated = $true
    rootPropertyChangeProjected = $true
    unversionedProjectionCleared = $true
    targetedReconcileAfterPropertySet = $true
    repositoryClosedAfterEvidence = $true
  }
}
$lockOpenReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eOpenReport"
  generatedAt = "2026-06-25T00:00:07Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$lockWorkingCopyRoot"
    epoch = 6
    identity = [pscustomobject]@{
      repositoryUuid = "fixture-lock-repository-uuid"
      repositoryRootUrl = "file:///fixture/lock/repo"
      workingCopyRoot = $lockWorkingCopyRoot
      workspaceScopeRoot = $lockWorkingCopyRoot
      format = 31
    }
  }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$lockWorkingCopyRoot"
    epoch = 6
    workingCopyRoot = $lockWorkingCopyRoot
    generation = 1
    count = 1
    inputBox = $openReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{
        id = "changes"
        contextValue = "subversionr.changes"
        hideWhenEmpty = $true
        count = 1
        resources = @(
          [pscustomobject]@{
            path = "src/needs-lock.txt"
            contextValue = "subversionr.workingCopyMetadataFile"
            kind = "file"
            generation = 1
          }
        )
      }
    )
  }
  rendererCaptureExpectations = $openReport.rendererCaptureExpectations
  surfaceWorkflow = $openReport.surfaceWorkflow
}
$lockMessageCancellationPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Lock SVN resource", "Enter an SVN lock message for src/needs-lock.txt.")
  requiredAccessibilityTokens = @("Lock SVN resource", "Enter an SVN lock message for src/needs-lock.txt.", "Lock message")
  requiredScreenshot = $true
  cancelSurface = "quickInput"
  cancelKey = "Escape"
}
[pscustomobject]@{
  ok = $true
  phase = "lockMessageCancellationPromptReady"
  command = "subversionr.lockResource"
  resource = [pscustomobject]@{
    path = "src/needs-lock.txt"
    contextValue = "subversionr.workingCopyMetadataFile"
    kind = "file"
    generation = 1
  }
  prompt = [pscustomobject]@{
    cancelKey = "Escape"
    rendererCaptureExpectations = $lockMessageCancellationPromptExpectations
  }
  cancelKey = "Escape"
  rendererCaptureExpectations = $lockMessageCancellationPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $lockMessageCancellationPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $lockMessageCancellationPromptDonePath -Description "lock message cancellation"
$lockMessageCancellationSurfaceReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCurrentSurfaceReport"
  generatedAt = "2026-06-25T00:00:07Z"
  repository = $lockOpenReport.repository
  sourceControl = $lockOpenReport.sourceControl
  surfaceWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    scmProjection = $true
    sourceControlSurface = $true
    currentEpochMatched = $true
  }
}
$lockMessageCancellationReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eLockMessageCancellationWorkflow"
  generatedAt = "2026-06-25T00:00:07Z"
  command = [pscustomobject]@{ command = "subversionr.lockResource" }
  repository = [pscustomobject]@{ repositoryId = $lockOpenReport.repository.repositoryId; epoch = $lockOpenReport.repository.epoch; workingCopyRoot = $lockWorkingCopyRoot }
  resource = [pscustomobject]@{
    path = "src/needs-lock.txt"
    contextValue = "subversionr.workingCopyMetadataFile"
    kind = "file"
    generation = 1
  }
  prompt = [pscustomobject]@{
    cancelKey = "Escape"
    rendererCaptureExpectations = $lockMessageCancellationPromptExpectations
  }
  currentSurfaceReport = $lockMessageCancellationSurfaceReport
  closeReport = [pscustomobject]@{ kind = "subversionr.installedSourceControlUiE2eCloseReport"; generatedAt = "2026-06-25T00:00:07Z"; repositoryId = $lockOpenReport.repository.repositoryId; epoch = $lockOpenReport.repository.epoch; repositoryClosed = $true }
  assertions = [pscustomobject]@{
    commandCancelled = $true
    sourceControlProjectionUnchanged = $true
    repositoryClosedAfterEvidence = $true
  }
}
$lockMessagePromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Lock SVN resource", "Enter an SVN lock message for src/needs-lock.txt.")
  requiredAccessibilityTokens = @("Lock SVN resource", "Enter an SVN lock message for src/needs-lock.txt.", "Lock message")
  requiredScreenshot = $true
  inputText = "Beta-E installed lock evidence"
  submitKey = "Enter"
}
[pscustomobject]@{
  ok = $true
  phase = "lockMessagePromptReady"
  command = "subversionr.lockResource"
  resource = [pscustomobject]@{
    path = "src/needs-lock.txt"
    contextValue = "subversionr.workingCopyMetadataFile"
    kind = "file"
    generation = 1
  }
  prompt = [pscustomobject]@{
    comment = "Beta-E installed lock evidence"
    rendererCaptureExpectations = $lockMessagePromptExpectations
  }
  rendererCaptureExpectations = $lockMessagePromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $lockMessagePromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $lockMessagePromptDonePath -Description "lock message"
$lockModePromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN lock mode", "Lock", "Steal lock")
  requiredAccessibilityTokens = @("SVN lock mode", "Lock", "Steal lock")
  requiredScreenshot = $true
  quickPickItemText = "Lock"
}
[pscustomobject]@{
  ok = $true
  phase = "lockModePromptReady"
  command = "subversionr.lockResource"
  resource = [pscustomobject]@{
    path = "src/needs-lock.txt"
    contextValue = "subversionr.workingCopyMetadataFile"
    kind = "file"
    generation = 1
  }
  prompt = [pscustomobject]@{
    selected = "Lock"
    stealLock = $false
    rendererCaptureExpectations = $lockModePromptExpectations
  }
  rendererCaptureExpectations = $lockModePromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $lockModePromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $lockModePromptDonePath -Description "lock mode"
$postLockFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:07Z"
  scenario = "partial"
  repository = $lockOpenReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $lockOpenReport.sourceControl.repositoryId
    epoch = $lockOpenReport.sourceControl.epoch
    workingCopyRoot = $lockOpenReport.sourceControl.workingCopyRoot
    generation = 2
    count = 1
    freshness = [pscustomobject]@{ repositoryCompleteness = "partial"; lastRefreshCompleteness = "partial"; lastRefreshKind = "snapshot" }
    statusBarCommands = @([pscustomobject]@{ command = "subversionr.fullReconcile"; title = "SVN status partial"; arguments = @($lockOpenReport.repository.repositoryId) })
    inputBox = $lockOpenReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{
        id = "changes"
        contextValue = "subversionr.changes"
        hideWhenEmpty = $true
        count = 1
        resources = @(
          [pscustomobject]@{
            path = "src/needs-lock.txt"
            contextValue = "subversionr.workingCopyMetadataFile.locked"
            kind = "file"
            generation = 2
          }
        )
      }
    )
  }
  lastCompletedRefresh = [pscustomobject]@{
    repositoryId = $lockOpenReport.repository.repositoryId
    epoch = $lockOpenReport.repository.epoch
    targets = @([pscustomobject]@{ path = "src/needs-lock.txt"; depth = "empty"; reason = "operationLock" })
    coverage = @([pscustomobject]@{ path = "src/needs-lock.txt"; depth = "empty"; reason = "operationLock"; generation = 2 })
    generation = 2
    completeness = "partial"
    timestamp = "2026-06-25T00:00:07Z"
    source = "libsvn-local"
  }
  freshnessWorkflow = [pscustomobject]@{ repositoryOpen = $true; currentEpochMatched = $true; sourceControlSurface = $true }
}
New-Item -ItemType Directory -Force -Path (Join-Path $lockWorkingCopyRoot ".svn") | Out-Null
Set-Content -LiteralPath (Join-Path $lockWorkingCopyRoot ".svn\fake-lock-held") -Value "held`n" -NoNewline -Encoding utf8
[pscustomobject]@{
  ok = $true
  phase = "lockHeldOracleReady"
  command = "subversionr.lockResource"
  resource = [pscustomobject]@{
    path = "src/needs-lock.txt"
    contextValue = "subversionr.workingCopyMetadataFile"
    kind = "file"
    generation = 1
  }
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $lockHeldOracleReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $lockHeldOracleDonePath -Description "lock-held oracle"
Remove-Item -LiteralPath (Join-Path $lockWorkingCopyRoot ".svn\fake-lock-held") -Force
$unlockModeCancellationPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN unlock mode", "Unlock", "Force unlock")
  requiredAccessibilityTokens = @("SVN unlock mode", "Unlock", "Force unlock")
  requiredScreenshot = $true
  cancelSurface = "quickInput"
  cancelKey = "Escape"
}
[pscustomobject]@{
  ok = $true
  phase = "unlockModeCancellationPromptReady"
  command = "subversionr.unlockResource"
  resource = [pscustomobject]@{
    path = "src/needs-lock.txt"
    contextValue = "subversionr.workingCopyMetadataFile.locked"
    kind = "file"
    generation = 2
  }
  prompt = [pscustomobject]@{
    cancelKey = "Escape"
    rendererCaptureExpectations = $unlockModeCancellationPromptExpectations
  }
  cancelKey = "Escape"
  rendererCaptureExpectations = $unlockModeCancellationPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $unlockModeCancellationPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $unlockModeCancellationPromptDonePath -Description "unlock mode cancellation"
$unlockModeCancellationSurfaceReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCurrentSurfaceReport"
  generatedAt = "2026-06-25T00:00:07Z"
  repository = $lockOpenReport.repository
  sourceControl = $postLockFreshnessReport.sourceControl
  surfaceWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    scmProjection = $true
    sourceControlSurface = $true
    currentEpochMatched = $true
  }
}
$preUnlockSurfaceReport = $unlockModeCancellationSurfaceReport
$unlockModeCancellationReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eUnlockModeCancellationWorkflow"
  generatedAt = "2026-06-25T00:00:07Z"
  command = [pscustomobject]@{ command = "subversionr.unlockResource" }
  repository = [pscustomobject]@{ repositoryId = $lockOpenReport.repository.repositoryId; epoch = $lockOpenReport.repository.epoch; workingCopyRoot = $lockWorkingCopyRoot }
  resource = [pscustomobject]@{
    path = "src/needs-lock.txt"
    contextValue = "subversionr.workingCopyMetadataFile.locked"
    kind = "file"
    generation = 2
  }
  prompt = [pscustomobject]@{
    cancelKey = "Escape"
    rendererCaptureExpectations = $unlockModeCancellationPromptExpectations
  }
  currentSurfaceReport = $unlockModeCancellationSurfaceReport
  closeReport = [pscustomobject]@{ kind = "subversionr.installedSourceControlUiE2eCloseReport"; generatedAt = "2026-06-25T00:00:07Z"; repositoryId = $lockOpenReport.repository.repositoryId; epoch = $lockOpenReport.repository.epoch; repositoryClosed = $true }
  assertions = [pscustomobject]@{
    commandCancelled = $true
    sourceControlProjectionUnchanged = $true
    repositoryClosedAfterEvidence = $true
  }
}
$unlockModePromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN unlock mode", "Unlock", "Force unlock")
  requiredAccessibilityTokens = @("SVN unlock mode", "Unlock", "Force unlock")
  requiredScreenshot = $true
  quickPickItemText = "Unlock"
}
[pscustomobject]@{
  ok = $true
  phase = "unlockModePromptReady"
  command = "subversionr.unlockResource"
  resource = [pscustomobject]@{
    path = "src/needs-lock.txt"
    contextValue = "subversionr.workingCopyMetadataFile.locked"
    kind = "file"
    generation = 2
  }
  prompt = [pscustomobject]@{
    selected = "Unlock"
    breakLock = $false
    rendererCaptureExpectations = $unlockModePromptExpectations
  }
  rendererCaptureExpectations = $unlockModePromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $unlockModePromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $unlockModePromptDonePath -Description "unlock mode"
$postUnlockFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:07Z"
  scenario = "partial"
  repository = $lockOpenReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $lockOpenReport.sourceControl.repositoryId
    epoch = $lockOpenReport.sourceControl.epoch
    workingCopyRoot = $lockOpenReport.sourceControl.workingCopyRoot
    generation = 3
    count = 1
    freshness = [pscustomobject]@{ repositoryCompleteness = "partial"; lastRefreshCompleteness = "partial"; lastRefreshKind = "snapshot" }
    statusBarCommands = @([pscustomobject]@{ command = "subversionr.fullReconcile"; title = "SVN status partial"; arguments = @($lockOpenReport.repository.repositoryId) })
    inputBox = $lockOpenReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{
        id = "changes"
        contextValue = "subversionr.changes"
        hideWhenEmpty = $true
        count = 1
        resources = @(
          [pscustomobject]@{
            path = "src/needs-lock.txt"
            contextValue = "subversionr.workingCopyMetadataFile"
            kind = "file"
            generation = 3
          }
        )
      }
    )
  }
  lastCompletedRefresh = [pscustomobject]@{
    repositoryId = $lockOpenReport.repository.repositoryId
    epoch = $lockOpenReport.repository.epoch
    targets = @([pscustomobject]@{ path = "src/needs-lock.txt"; depth = "empty"; reason = "operationUnlock" })
    coverage = @([pscustomobject]@{ path = "src/needs-lock.txt"; depth = "empty"; reason = "operationUnlock"; generation = 3 })
    generation = 3
    completeness = "partial"
    timestamp = "2026-06-25T00:00:07Z"
    source = "libsvn-local"
  }
  freshnessWorkflow = [pscustomobject]@{ repositoryOpen = $true; currentEpochMatched = $true; sourceControlSurface = $true }
}
$lockUnlockReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eLockUnlockWorkflow"
  generatedAt = "2026-06-25T00:00:07Z"
  commands = [pscustomobject]@{ lock = "subversionr.lockResource"; unlock = "subversionr.unlockResource" }
  repository = [pscustomobject]@{ repositoryId = $lockOpenReport.repository.repositoryId; epoch = $lockOpenReport.repository.epoch; workingCopyRoot = $lockWorkingCopyRoot }
  resource = [pscustomobject]@{
    path = "src/needs-lock.txt"
    contextValueBefore = "subversionr.workingCopyMetadataFile"
    contextValueAfterLock = "subversionr.workingCopyMetadataFile.locked"
    contextValueAfterUnlock = "subversionr.workingCopyMetadataFile"
    kind = "file"
    generation = 1
  }
  request = [pscustomobject]@{
    comment = "Beta-E installed lock evidence"
    stealLock = $false
    breakLock = $false
  }
  prompts = [pscustomobject]@{
    lockMessage = [pscustomobject]@{ rendererCaptureExpectations = $lockMessagePromptExpectations }
    lockMode = [pscustomobject]@{ selected = "Lock"; rendererCaptureExpectations = $lockModePromptExpectations }
    unlockMode = [pscustomobject]@{ selected = "Unlock"; rendererCaptureExpectations = $unlockModePromptExpectations }
  }
  postLockFreshnessReport = $postLockFreshnessReport
  preUnlockSurfaceReport = $preUnlockSurfaceReport
  postUnlockFreshnessReport = $postUnlockFreshnessReport
  closeReport = [pscustomobject]@{ kind = "subversionr.installedSourceControlUiE2eCloseReport"; generatedAt = "2026-06-25T00:00:07Z"; repositoryId = $lockOpenReport.repository.repositoryId; epoch = $lockOpenReport.repository.epoch; repositoryClosed = $true }
  assertions = [pscustomobject]@{
    needsLockProjectedBefore = $true
    lockCommandExecuted = $true
    lockUsedNormalPolicy = $true
    lockHeldOracleHandshakeCompleted = $true
    unlockCommandExecuted = $true
    unlockUsedNormalPolicy = $true
    needsLockProjectionPreservedAfterLock = $true
    needsLockProjectionPreservedAfterUnlock = $true
    lockTargetedReconcile = $true
    unlockTargetedReconcile = $true
    repositoryClosedAfterEvidence = $true
  }
}
$changelistSetPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Set SVN changelist", "Enter the SVN changelist name for src/tracked.txt.")
  requiredAccessibilityTokens = @("Set SVN changelist", "Enter the SVN changelist name for src/tracked.txt.", "Changelist name")
  requiredScreenshot = $true
  inputText = "review"
  submitKey = "Enter"
}
[pscustomobject]@{
  ok = $true
  phase = "changelistSetPromptReady"
  command = "subversionr.setResourceChangelist"
  resource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.changedFile.baseDiffable"
    kind = "file"
    generation = 1
  }
  prompt = [pscustomobject]@{
    changelist = "review"
    rendererCaptureExpectations = $changelistSetPromptExpectations
  }
  rendererCaptureExpectations = $changelistSetPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $changelistSetPromptReadyPath -Encoding utf8
$changelistSetClearOpenReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eOpenReport"
  generatedAt = "2026-06-25T00:00:07Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$changelistSetClearWorkingCopyRoot"
    epoch = 6
    identity = [pscustomobject]@{
      repositoryUuid = "fixture-changelist-set-clear-repository-uuid"
      repositoryRootUrl = "file:///fixture/changelist-set-clear/repo"
      workingCopyRoot = $changelistSetClearWorkingCopyRoot
      workspaceScopeRoot = $changelistSetClearWorkingCopyRoot
      format = 31
    }
  }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$changelistSetClearWorkingCopyRoot"
    epoch = 6
    workingCopyRoot = $changelistSetClearWorkingCopyRoot
    generation = 1
    count = 1
    inputBox = $openReport.sourceControl.inputBox
    groups = $openReport.sourceControl.groups
  }
  rendererCaptureExpectations = $openReport.rendererCaptureExpectations
  surfaceWorkflow = $openReport.surfaceWorkflow
}
$postChangelistSetFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:07Z"
  scenario = "partial"
  repository = $changelistSetClearOpenReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $changelistSetClearOpenReport.sourceControl.repositoryId
    epoch = $changelistSetClearOpenReport.sourceControl.epoch
    workingCopyRoot = $changelistSetClearOpenReport.sourceControl.workingCopyRoot
    generation = 2
    count = 1
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($changelistSetClearOpenReport.repository.repositoryId)
      }
    )
    inputBox = $changelistSetClearOpenReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{
        id = "changelist:review"
        contextValue = "subversionr.changelist"
        hideWhenEmpty = $true
        count = 1
        resources = @(
          [pscustomobject]@{
            path = "src/tracked.txt"
            contextValue = "subversionr.changedFile.baseDiffable.changelisted"
            kind = "file"
            generation = 2
          }
        )
      },
      $openReport.sourceControl.groups[1]
    )
  }
  lastCompletedRefresh = [pscustomobject]@{
    repositoryId = $changelistSetClearOpenReport.repository.repositoryId
    epoch = $changelistSetClearOpenReport.repository.epoch
    targets = @([pscustomobject]@{ path = "src/tracked.txt"; depth = "empty"; reason = "operationChangelistSet" })
    coverage = @([pscustomobject]@{ path = "src/tracked.txt"; depth = "empty"; reason = "operationChangelistSet"; generation = 2 })
    generation = 2
    completeness = "partial"
    timestamp = "2026-06-25T00:00:07Z"
    source = "libsvn-local"
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$postChangelistClearFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:07Z"
  scenario = "partial"
  repository = $changelistSetClearOpenReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $changelistSetClearOpenReport.sourceControl.repositoryId
    epoch = $changelistSetClearOpenReport.sourceControl.epoch
    workingCopyRoot = $changelistSetClearOpenReport.sourceControl.workingCopyRoot
    generation = 3
    count = 1
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @([pscustomobject]@{ command = "subversionr.fullReconcile"; title = "SVN status partial"; arguments = @($changelistSetClearOpenReport.repository.repositoryId) })
    inputBox = $changelistSetClearOpenReport.sourceControl.inputBox
    groups = $changelistSetClearOpenReport.sourceControl.groups
  }
  lastCompletedRefresh = [pscustomobject]@{
    repositoryId = $changelistSetClearOpenReport.repository.repositoryId
    epoch = $changelistSetClearOpenReport.repository.epoch
    targets = @([pscustomobject]@{ path = "src/tracked.txt"; depth = "empty"; reason = "operationChangelistClear" })
    coverage = @([pscustomobject]@{ path = "src/tracked.txt"; depth = "empty"; reason = "operationChangelistClear"; generation = 3 })
    generation = 3
    completeness = "partial"
    timestamp = "2026-06-25T00:00:07Z"
    source = "libsvn-local"
  }
  freshnessWorkflow = [pscustomobject]@{ repositoryOpen = $true; currentEpochMatched = $true; sourceControlSurface = $true }
}
$changelistSetClearReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eChangelistSetClearWorkflow"
  generatedAt = "2026-06-25T00:00:07Z"
  commands = [pscustomobject]@{ set = "subversionr.setResourceChangelist"; clear = "subversionr.clearResourceChangelist" }
  repository = [pscustomobject]@{ repositoryId = $changelistSetClearOpenReport.repository.repositoryId; epoch = $changelistSetClearOpenReport.repository.epoch; workingCopyRoot = $changelistSetClearWorkingCopyRoot }
  changelist = "review"
  groupId = "changelist:review"
  resource = [pscustomobject]@{ path = "src/tracked.txt"; contextValueBefore = "subversionr.changedFile.baseDiffable"; contextValueAfterSet = "subversionr.changedFile.baseDiffable.changelisted"; contextValueAfterClear = "subversionr.changedFile.baseDiffable" }
  prompts = [pscustomobject]@{ set = [pscustomobject]@{ changelist = "review"; rendererCaptureExpectations = $changelistSetPromptExpectations } }
  postSetFreshnessReport = $postChangelistSetFreshnessReport
  postClearFreshnessReport = $postChangelistClearFreshnessReport
  closeReport = [pscustomobject]@{ kind = "subversionr.installedSourceControlUiE2eCloseReport"; generatedAt = "2026-06-25T00:00:07Z"; repositoryId = $changelistSetClearOpenReport.repository.repositoryId; epoch = $changelistSetClearOpenReport.repository.epoch; repositoryClosed = $true }
  assertions = [pscustomobject]@{
    setCommandExecuted = $true
    clearCommandExecuted = $true
    groupProjectedAfterSet = $true
    resourceProjectedInChangelistAfterSet = $true
    resourceReturnedToChangesAfterClear = $true
    changelistGroupRemovedAfterClear = $true
    setTargetedReconcile = $true
    clearTargetedReconcile = $true
    repositoryClosedAfterEvidence = $true
  }
}
$commitChangelistOpenReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eOpenReport"
  generatedAt = "2026-06-25T00:00:07Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{ repositoryId = "repo-uuid:$commitChangelistWorkingCopyRoot"; epoch = 6; identity = [pscustomobject]@{ repositoryUuid = "fixture-commit-changelist-repository-uuid"; repositoryRootUrl = "file:///fixture/commit-changelist/repo"; workingCopyRoot = $commitChangelistWorkingCopyRoot; workspaceScopeRoot = $commitChangelistWorkingCopyRoot; format = 31 } }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$commitChangelistWorkingCopyRoot"
    epoch = 6
    workingCopyRoot = $commitChangelistWorkingCopyRoot
    generation = 1
    count = 2
    inputBox = $openReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{ id = "changelist:review"; contextValue = "subversionr.changelist"; hideWhenEmpty = $true; count = 1; resources = @([pscustomobject]@{ path = "src/tracked.txt"; contextValue = "subversionr.changedFile.baseDiffable.changelisted"; kind = "file"; generation = 1 }) },
      [pscustomobject]@{ id = "changes"; contextValue = "subversionr.changes"; hideWhenEmpty = $true; count = 1; resources = @([pscustomobject]@{ path = "load/modified-001.txt"; contextValue = "subversionr.changedFile.baseDiffable"; kind = "file"; generation = 1 }) }
    )
  }
  rendererCaptureExpectations = $openReport.rendererCaptureExpectations
  surfaceWorkflow = $openReport.surfaceWorkflow
}
$postCommitChangelistFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:07Z"
  scenario = "partial"
  repository = $commitChangelistOpenReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $commitChangelistOpenReport.sourceControl.repositoryId
    epoch = $commitChangelistOpenReport.sourceControl.epoch
    workingCopyRoot = $commitChangelistOpenReport.sourceControl.workingCopyRoot
    generation = 2
    count = 1
    freshness = [pscustomobject]@{ repositoryCompleteness = "partial"; lastRefreshCompleteness = "partial"; lastRefreshKind = "snapshot" }
    statusBarCommands = @([pscustomobject]@{ command = "subversionr.fullReconcile"; title = "SVN status partial"; arguments = @($commitChangelistOpenReport.repository.repositoryId) })
    inputBox = $commitChangelistOpenReport.sourceControl.inputBox
    groups = @([pscustomobject]@{ id = "changes"; contextValue = "subversionr.changes"; hideWhenEmpty = $true; count = 1; resources = @([pscustomobject]@{ path = "load/modified-001.txt"; contextValue = "subversionr.changedFile.baseDiffable"; kind = "file"; generation = 2 }) })
  }
  lastCompletedRefresh = [pscustomobject]@{ repositoryId = $commitChangelistOpenReport.repository.repositoryId; epoch = $commitChangelistOpenReport.repository.epoch; targets = @([pscustomobject]@{ path = "src/tracked.txt"; depth = "empty"; reason = "operationCommit" }); coverage = @([pscustomobject]@{ path = "src/tracked.txt"; depth = "empty"; reason = "operationCommit"; generation = 2 }); generation = 2; completeness = "partial"; timestamp = "2026-06-25T00:00:07Z"; source = "libsvn-local" }
  freshnessWorkflow = [pscustomobject]@{ repositoryOpen = $true; currentEpochMatched = $true; sourceControlSurface = $true }
}
$commitChangelistReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCommitChangelistWorkflow"
  generatedAt = "2026-06-25T00:00:07Z"
  command = [pscustomobject]@{ command = "subversionr.commitChangelist"; changelist = "review"; argument = [pscustomobject]@{ subversionrRepositoryId = $commitChangelistOpenReport.repository.repositoryId; subversionrChangelistName = "review" } }
  repository = [pscustomobject]@{ repositoryId = $commitChangelistOpenReport.repository.repositoryId; epoch = $commitChangelistOpenReport.repository.epoch; workingCopyRoot = $commitChangelistWorkingCopyRoot }
  input = [pscustomobject]@{ messageLength = "commit selected SVN changelist from the repository input message".Length; postCommitProbePreviousMessageLength = 0 }
  targets = [pscustomobject]@{ selectedChangelistPaths = @("src/tracked.txt"); unselectedChangedPaths = @("load/modified-001.txt") }
  postCommitFreshnessReport = $postCommitChangelistFreshnessReport
  closeReport = [pscustomobject]@{ kind = "subversionr.installedSourceControlUiE2eCloseReport"; generatedAt = "2026-06-25T00:00:07Z"; repositoryId = $commitChangelistOpenReport.repository.repositoryId; epoch = $commitChangelistOpenReport.repository.epoch; repositoryClosed = $true }
  assertions = [pscustomobject]@{ commandExecuted = $true; commitUsedChangelistFilter = $true; inputMessageWasSet = $true; inputMessageClearedAfterCommit = $true; changelistProjectionClearedCommittedPath = $true; unselectedNonChangelistPathStillModified = $true; targetedReconcileAfterCommit = $true; repositoryClosedAfterEvidence = $true }
}
$changelistRevertPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Revert local SVN changes to src/tracked.txt? This cannot be undone.", "Revert")
  requiredAccessibilityTokens = @("Revert local SVN changes to src/tracked.txt? This cannot be undone.", "Revert")
  requiredScreenshot = $true
  clickButtonText = "Revert"
}
[pscustomobject]@{
  ok = $true
  phase = "revertChangelistPromptReady"
  command = "subversionr.revertChangelist"
  changelist = "review"
  resource = [pscustomobject]@{ path = "src/tracked.txt"; contextValue = "subversionr.changedFile.baseDiffable.changelisted"; kind = "file"; generation = 1 }
  prompt = [pscustomobject]@{ clickButtonText = "Revert"; rendererCaptureExpectations = $changelistRevertPromptExpectations }
  rendererCaptureExpectations = $changelistRevertPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $changelistRevertPromptReadyPath -Encoding utf8
$revertChangelistOpenReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eOpenReport"
  generatedAt = "2026-06-25T00:00:07Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{ repositoryId = "repo-uuid:$revertChangelistWorkingCopyRoot"; epoch = 6; identity = [pscustomobject]@{ repositoryUuid = "fixture-revert-changelist-repository-uuid"; repositoryRootUrl = "file:///fixture/revert-changelist/repo"; workingCopyRoot = $revertChangelistWorkingCopyRoot; workspaceScopeRoot = $revertChangelistWorkingCopyRoot; format = 31 } }
  sourceControl = [pscustomobject]@{ repositoryId = "repo-uuid:$revertChangelistWorkingCopyRoot"; epoch = 6; workingCopyRoot = $revertChangelistWorkingCopyRoot; generation = 1; count = 1; inputBox = $openReport.sourceControl.inputBox; groups = @([pscustomobject]@{ id = "changelist:review"; contextValue = "subversionr.changelist"; hideWhenEmpty = $true; count = 1; resources = @([pscustomobject]@{ path = "src/tracked.txt"; contextValue = "subversionr.changedFile.baseDiffable.changelisted"; kind = "file"; generation = 1 }) }) }
  rendererCaptureExpectations = $openReport.rendererCaptureExpectations
  surfaceWorkflow = $openReport.surfaceWorkflow
}
$postRevertChangelistFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:07Z"
  scenario = "partial"
  repository = $revertChangelistOpenReport.repository
  sourceControl = [pscustomobject]@{ repositoryId = $revertChangelistOpenReport.sourceControl.repositoryId; epoch = $revertChangelistOpenReport.sourceControl.epoch; workingCopyRoot = $revertChangelistOpenReport.sourceControl.workingCopyRoot; generation = 2; count = 0; freshness = [pscustomobject]@{ repositoryCompleteness = "partial"; lastRefreshCompleteness = "partial"; lastRefreshKind = "snapshot" }; statusBarCommands = @([pscustomobject]@{ command = "subversionr.fullReconcile"; title = "SVN status partial"; arguments = @($revertChangelistOpenReport.repository.repositoryId) }); inputBox = $revertChangelistOpenReport.sourceControl.inputBox; groups = @([pscustomobject]@{ id = "changes"; contextValue = "subversionr.changes"; hideWhenEmpty = $true; count = 0; resources = @() }) }
  lastCompletedRefresh = [pscustomobject]@{ repositoryId = $revertChangelistOpenReport.repository.repositoryId; epoch = $revertChangelistOpenReport.repository.epoch; targets = @([pscustomobject]@{ path = "src/tracked.txt"; depth = "empty"; reason = "operationRevert" }); coverage = @([pscustomobject]@{ path = "src/tracked.txt"; depth = "empty"; reason = "operationRevert"; generation = 2 }); generation = 2; completeness = "partial"; timestamp = "2026-06-25T00:00:07Z"; source = "libsvn-local" }
  freshnessWorkflow = [pscustomobject]@{ repositoryOpen = $true; currentEpochMatched = $true; sourceControlSurface = $true }
}
$revertChangelistReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eRevertChangelistWorkflow"
  generatedAt = "2026-06-25T00:00:07Z"
  command = [pscustomobject]@{ command = "subversionr.revertChangelist"; changelist = "review"; argument = [pscustomobject]@{ subversionrRepositoryId = $revertChangelistOpenReport.repository.repositoryId; subversionrChangelistName = "review" } }
  repository = [pscustomobject]@{ repositoryId = $revertChangelistOpenReport.repository.repositoryId; epoch = $revertChangelistOpenReport.repository.epoch; workingCopyRoot = $revertChangelistWorkingCopyRoot }
  resource = [pscustomobject]@{ path = "src/tracked.txt"; contextValue = "subversionr.changedFile.baseDiffable.changelisted"; kind = "file"; generation = 1 }
  prompt = [pscustomobject]@{ clickButtonText = "Revert"; rendererCaptureExpectations = $changelistRevertPromptExpectations }
  postRevertFreshnessReport = $postRevertChangelistFreshnessReport
  closeReport = [pscustomobject]@{ kind = "subversionr.installedSourceControlUiE2eCloseReport"; generatedAt = "2026-06-25T00:00:07Z"; repositoryId = $revertChangelistOpenReport.repository.repositoryId; epoch = $revertChangelistOpenReport.repository.epoch; repositoryClosed = $true }
  assertions = [pscustomobject]@{ commandExecuted = $true; revertUsedChangelistFilter = $true; workingCopyContentRestored = $true; changelistProjectionClearedRevertedPath = $true; targetedReconcileAfterRevert = $true; repositoryClosedAfterEvidence = $true }
}
$addOpenReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eOpenReport"
  generatedAt = "2026-06-25T00:00:07Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$addWorkingCopyRoot"
    epoch = 6
    identity = [pscustomobject]@{
      repositoryUuid = "fixture-add-repository-uuid"
      repositoryRootUrl = "file:///fixture/add/repo"
      workingCopyRoot = $addWorkingCopyRoot
      workspaceScopeRoot = $addWorkingCopyRoot
      format = 31
    }
  }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$addWorkingCopyRoot"
    epoch = 6
    workingCopyRoot = $addWorkingCopyRoot
    generation = 1
    count = 1
    inputBox = $openReport.sourceControl.inputBox
    groups = $openReport.sourceControl.groups
  }
  rendererCaptureExpectations = $openReport.rendererCaptureExpectations
  surfaceWorkflow = $openReport.surfaceWorkflow
}
$addScratchPath = Join-Path $addWorkingCopyRoot "scratch.txt"
$addFileExistedBefore = Test-Path -LiteralPath $addScratchPath -PathType Leaf
$addFileExistsAfter = Test-Path -LiteralPath $addScratchPath -PathType Leaf
$postAddFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:07Z"
  scenario = "partial"
  repository = $addOpenReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $addOpenReport.sourceControl.repositoryId
    epoch = $addOpenReport.sourceControl.epoch
    workingCopyRoot = $addOpenReport.sourceControl.workingCopyRoot
    generation = 2
    count = 2
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($addOpenReport.repository.repositoryId)
      }
    )
    inputBox = $addOpenReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{
        id = "changes"
        contextValue = "subversionr.changes"
        hideWhenEmpty = $true
        count = 2
        resources = @(
          $openReport.sourceControl.groups[0].resources[0],
          [pscustomobject]@{
            path = "scratch.txt"
            contextValue = "subversionr.changedFile"
            kind = "file"
            generation = 2
          }
        )
      },
      [pscustomobject]@{
        id = "unversioned"
        contextValue = "subversionr.unversioned"
        hideWhenEmpty = $true
        count = 0
        resources = @()
      }
    )
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$addReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eAddWorkflow"
  generatedAt = "2026-06-25T00:00:07Z"
  command = [pscustomobject]@{
    command = "subversionr.addResource"
  }
  repository = [pscustomobject]@{
    repositoryId = $addOpenReport.repository.repositoryId
    epoch = $addOpenReport.repository.epoch
    workingCopyRoot = $addWorkingCopyRoot
  }
  resource = [pscustomobject]@{
    path = "scratch.txt"
    contextValue = "subversionr.unversioned"
    kind = "file"
    generation = 1
  }
  postAddResource = [pscustomobject]@{
    path = "scratch.txt"
    contextValue = "subversionr.changedFile"
    kind = "file"
    generation = 2
  }
  postAddFreshnessReport = $postAddFreshnessReport
  closeReport = [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eCloseReport"
    generatedAt = "2026-06-25T00:00:07Z"
    repositoryId = $addOpenReport.repository.repositoryId
    epoch = $addOpenReport.repository.epoch
    repositoryClosed = $true
  }
  assertions = [pscustomobject]@{
    commandExecuted = $true
    fileExistedBefore = $addFileExistedBefore
    fileExistsAfter = $addFileExistsAfter
    sourceControlProjectionRefreshed = $true
  }
}
$moveOpenReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eOpenReport"
  generatedAt = "2026-06-25T00:00:07Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$moveWorkingCopyRoot"
    epoch = 7
    identity = [pscustomobject]@{
      repositoryUuid = "fixture-move-repository-uuid"
      repositoryRootUrl = "file:///fixture/move/repo"
      workingCopyRoot = $moveWorkingCopyRoot
      workspaceScopeRoot = $moveWorkingCopyRoot
      format = 31
    }
  }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$moveWorkingCopyRoot"
    epoch = 7
    workingCopyRoot = $moveWorkingCopyRoot
    generation = 1
    count = 1
    inputBox = $openReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{
        id = "changes"
        contextValue = "subversionr.changes"
        hideWhenEmpty = $true
        count = 1
        resources = @(
          [pscustomobject]@{
            path = "src/tracked.txt"
            contextValue = "subversionr.changedFile.baseDiffable"
            kind = "file"
            generation = 1
          }
        )
      },
      [pscustomobject]@{
        id = "unversioned"
        contextValue = "subversionr.unversioned"
        hideWhenEmpty = $true
        count = 1
        resources = @(
          [pscustomobject]@{
            path = "scratch.txt"
            contextValue = "subversionr.unversioned"
            kind = "file"
            generation = 1
          }
        )
      }
    )
  }
  rendererCaptureExpectations = $openReport.rendererCaptureExpectations
  surfaceWorkflow = $openReport.surfaceWorkflow
}
$movePromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Move SVN resource", "Enter the repository-relative destination path for src/tracked.txt.")
  requiredAccessibilityTokens = @("Move SVN resource", "Enter the repository-relative destination path for src/tracked.txt.")
  requiredScreenshot = $true
  inputText = "src/moved.txt"
  submitKey = "Enter"
}
[pscustomobject]@{
  ok = $true
  phase = "movePromptReady"
  command = "subversionr.moveResource"
  resource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.changedFile.baseDiffable"
    kind = "file"
    generation = 1
  }
  destinationPath = "src/moved.txt"
  rendererCaptureExpectations = $movePromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $movePromptReadyPath -Encoding utf8
$moveSourcePath = Join-Path $moveWorkingCopyRoot "src\tracked.txt"
$moveDestinationPath = Join-Path $moveWorkingCopyRoot "src\moved.txt"
$moveSourceFileExistedBefore = Test-Path -LiteralPath $moveSourcePath -PathType Leaf
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $moveDestinationPath) | Out-Null
if ($moveSourceFileExistedBefore) {
  Move-Item -LiteralPath $moveSourcePath -Destination $moveDestinationPath
}
$moveSourceFileExistsAfter = Test-Path -LiteralPath $moveSourcePath -PathType Leaf
$moveDestinationFileExistsAfter = Test-Path -LiteralPath $moveDestinationPath -PathType Leaf
$postMoveFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:07Z"
  scenario = "partial"
  repository = $moveOpenReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $moveOpenReport.sourceControl.repositoryId
    epoch = $moveOpenReport.sourceControl.epoch
    workingCopyRoot = $moveOpenReport.sourceControl.workingCopyRoot
    generation = 2
    count = 1
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($moveOpenReport.repository.repositoryId)
      }
    )
    inputBox = $moveOpenReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{
        id = "changes"
        contextValue = "subversionr.changes"
        hideWhenEmpty = $true
        count = 2
        resources = @(
          [pscustomobject]@{
            path = "src/tracked.txt"
            contextValue = "subversionr.changedFile"
            kind = "file"
            generation = 2
          },
          [pscustomobject]@{
            path = "src/moved.txt"
            contextValue = "subversionr.changedFile"
            kind = "file"
            generation = 2
          }
        )
      },
      [pscustomobject]@{
        id = "unversioned"
        contextValue = "subversionr.unversioned"
        hideWhenEmpty = $true
        count = 1
        resources = @(
          [pscustomobject]@{
            path = "scratch.txt"
            contextValue = "subversionr.unversioned"
            kind = "file"
            generation = 1
          }
        )
      }
    )
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$moveReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eMoveWorkflow"
  generatedAt = "2026-06-25T00:00:07Z"
  command = [pscustomobject]@{
    command = "subversionr.moveResource"
  }
  repository = [pscustomobject]@{
    repositoryId = $moveOpenReport.repository.repositoryId
    epoch = $moveOpenReport.repository.epoch
    workingCopyRoot = $moveWorkingCopyRoot
  }
  resource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.changedFile.baseDiffable"
    kind = "file"
    generation = 1
  }
  request = [pscustomobject]@{
    sourcePath = "src/tracked.txt"
    destinationPath = "src/moved.txt"
    makeParents = $false
  }
  postMoveSourceResource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.changedFile"
    kind = "file"
    generation = 2
  }
  postMoveDestinationResource = [pscustomobject]@{
    path = "src/moved.txt"
    contextValue = "subversionr.changedFile"
    kind = "file"
    generation = 2
  }
  prompt = [pscustomobject]@{
    inputText = "src/moved.txt"
    submitKey = "Enter"
    rendererCaptureExpectations = $movePromptExpectations
  }
  postMoveFreshnessReport = $postMoveFreshnessReport
  closeReport = [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eCloseReport"
    generatedAt = "2026-06-25T00:00:07Z"
    repositoryId = $moveOpenReport.repository.repositoryId
    epoch = $moveOpenReport.repository.epoch
    repositoryClosed = $true
  }
  assertions = [pscustomobject]@{
    commandExecuted = $true
    sourceFileExistedBefore = $moveSourceFileExistedBefore
    sourceFileExistsAfter = $moveSourceFileExistsAfter
    destinationFileExistsAfter = $moveDestinationFileExistsAfter
    sourceControlProjectionRefreshed = $true
  }
}
$moveCancellationOpenReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eOpenReport"
  generatedAt = "2026-06-25T00:00:07Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$moveCancellationWorkingCopyRoot"
    epoch = 8
    identity = [pscustomobject]@{
      repositoryUuid = "fixture-move-cancellation-repository-uuid"
      repositoryRootUrl = "file:///fixture/move-cancellation/repo"
      workingCopyRoot = $moveCancellationWorkingCopyRoot
      workspaceScopeRoot = $moveCancellationWorkingCopyRoot
      format = 31
    }
  }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$moveCancellationWorkingCopyRoot"
    epoch = 8
    workingCopyRoot = $moveCancellationWorkingCopyRoot
    generation = 1
    count = 1
    inputBox = $openReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{
        id = "changes"
        contextValue = "subversionr.changes"
        hideWhenEmpty = $true
        count = 1
        resources = @(
          [pscustomobject]@{
            path = "src/tracked.txt"
            contextValue = "subversionr.changedFile.baseDiffable"
            kind = "file"
            generation = 1
          }
        )
      },
      [pscustomobject]@{
        id = "unversioned"
        contextValue = "subversionr.unversioned"
        hideWhenEmpty = $true
        count = 1
        resources = @(
          [pscustomobject]@{
            path = "scratch.txt"
            contextValue = "subversionr.unversioned"
            kind = "file"
            generation = 1
          }
        )
      }
    )
  }
  rendererCaptureExpectations = $openReport.rendererCaptureExpectations
  surfaceWorkflow = $openReport.surfaceWorkflow
}
$moveCancellationPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Move SVN resource", "Enter the repository-relative destination path for src/tracked.txt.")
  requiredAccessibilityTokens = @("Move SVN resource", "Enter the repository-relative destination path for src/tracked.txt.")
  requiredScreenshot = $true
  cancelKey = "Escape"
}
[pscustomobject]@{
  ok = $true
  phase = "moveCancellationPromptReady"
  command = "subversionr.moveResource"
  resource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.changedFile.baseDiffable"
    kind = "file"
    generation = 1
  }
  cancelKey = "Escape"
  rendererCaptureExpectations = $moveCancellationPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $moveCancellationPromptReadyPath -Encoding utf8
$moveCancellationSourcePath = Join-Path $moveCancellationWorkingCopyRoot "src\tracked.txt"
$moveCancellationDestinationPath = Join-Path $moveCancellationWorkingCopyRoot "src\cancelled.txt"
$moveCancellationSourceFileExistedBefore = Test-Path -LiteralPath $moveCancellationSourcePath -PathType Leaf
$moveCancellationSourceFileExistsAfter = Test-Path -LiteralPath $moveCancellationSourcePath -PathType Leaf
$moveCancellationDestinationFileExistsAfter = Test-Path -LiteralPath $moveCancellationDestinationPath -PathType Leaf
$postMoveCancellationFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:07Z"
  scenario = "partial"
  repository = $moveCancellationOpenReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $moveCancellationOpenReport.sourceControl.repositoryId
    epoch = $moveCancellationOpenReport.sourceControl.epoch
    workingCopyRoot = $moveCancellationOpenReport.sourceControl.workingCopyRoot
    generation = 1
    count = 1
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($moveCancellationOpenReport.repository.repositoryId)
      }
    )
    inputBox = $moveCancellationOpenReport.sourceControl.inputBox
    groups = $moveCancellationOpenReport.sourceControl.groups
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$moveCancellationReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eMoveCancellationWorkflow"
  generatedAt = "2026-06-25T00:00:07Z"
  command = [pscustomobject]@{
    command = "subversionr.moveResource"
  }
  repository = [pscustomobject]@{
    repositoryId = $moveCancellationOpenReport.repository.repositoryId
    epoch = $moveCancellationOpenReport.repository.epoch
    workingCopyRoot = $moveCancellationWorkingCopyRoot
  }
  resource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.changedFile.baseDiffable"
    kind = "file"
    generation = 1
  }
  request = [pscustomobject]@{
    sourcePath = "src/tracked.txt"
    destinationPath = "src/cancelled.txt"
    makeParents = $false
  }
  postCancelSourceResource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.changedFile.baseDiffable"
    kind = "file"
    generation = 1
  }
  postCancelDestinationResourcePresent = $false
  prompt = [pscustomobject]@{
    cancelKey = "Escape"
    rendererCaptureExpectations = $moveCancellationPromptExpectations
  }
  postCancelFreshnessReport = $postMoveCancellationFreshnessReport
  closeReport = [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eCloseReport"
    generatedAt = "2026-06-25T00:00:07Z"
    repositoryId = $moveCancellationOpenReport.repository.repositoryId
    epoch = $moveCancellationOpenReport.repository.epoch
    repositoryClosed = $true
  }
  assertions = [pscustomobject]@{
    commandCancelled = $true
    sourceFileExistedBefore = $moveCancellationSourceFileExistedBefore
    sourceFileExistsAfter = $moveCancellationSourceFileExistsAfter
    destinationFileExistsAfter = $moveCancellationDestinationFileExistsAfter
    sourceControlProjectionUnchanged = $true
  }
}
$removePromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Remove SVN resource src/tracked.txt? The local item will be deleted and scheduled for commit.", "Remove")
  requiredAccessibilityTokens = @("Remove SVN resource src/tracked.txt? The local item will be deleted and scheduled for commit.", "Remove")
  requiredScreenshot = $true
  clickButtonText = "Remove"
}
[pscustomobject]@{
  ok = $true
  phase = "removePromptReady"
  command = "subversionr.removeResource"
  resource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.changedFile"
    kind = "file"
    generation = 1
  }
  rendererCaptureExpectations = $removePromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $removePromptReadyPath -Encoding utf8
$removeTrackedPath = Join-Path $removeWorkingCopyRoot "src\tracked.txt"
$removeFileExistedBefore = Test-Path -LiteralPath $removeTrackedPath -PathType Leaf
Remove-Item -LiteralPath $removeTrackedPath -Force -ErrorAction SilentlyContinue
$removeFileExistsAfter = Test-Path -LiteralPath $removeTrackedPath -PathType Leaf
$removeOpenReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eOpenReport"
  generatedAt = "2026-06-25T00:00:08Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$removeWorkingCopyRoot"
    epoch = 8
    identity = [pscustomobject]@{
      repositoryUuid = "fixture-remove-repository-uuid"
      repositoryRootUrl = "file:///fixture/remove/repo"
      workingCopyRoot = $removeWorkingCopyRoot
      workspaceScopeRoot = $removeWorkingCopyRoot
      format = 31
    }
  }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$removeWorkingCopyRoot"
    epoch = 8
    workingCopyRoot = $removeWorkingCopyRoot
    generation = 1
    count = 1
    inputBox = $openReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{
        id = "changes"
        contextValue = "subversionr.changes"
        hideWhenEmpty = $true
        count = 1
        resources = @(
          [pscustomobject]@{
            path = "src/tracked.txt"
            contextValue = "subversionr.changedFile"
            kind = "file"
            generation = 1
          }
        )
      },
      $openReport.sourceControl.groups[1]
    )
  }
  rendererCaptureExpectations = $openReport.rendererCaptureExpectations
  surfaceWorkflow = $openReport.surfaceWorkflow
}
$postRemoveCommandFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:08Z"
  scenario = "partial"
  repository = $removeOpenReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $removeOpenReport.sourceControl.repositoryId
    epoch = $removeOpenReport.sourceControl.epoch
    workingCopyRoot = $removeOpenReport.sourceControl.workingCopyRoot
    generation = 2
    count = 1
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($removeOpenReport.repository.repositoryId)
      }
    )
    inputBox = $removeOpenReport.sourceControl.inputBox
    groups = $removeOpenReport.sourceControl.groups
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$removeReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eRemoveWorkflow"
  generatedAt = "2026-06-25T00:00:08Z"
  command = [pscustomobject]@{
    command = "subversionr.removeResource"
  }
  repository = [pscustomobject]@{
    repositoryId = $removeOpenReport.repository.repositoryId
    epoch = $removeOpenReport.repository.epoch
    workingCopyRoot = $removeWorkingCopyRoot
  }
  resource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.changedFile"
    kind = "file"
    generation = 1
  }
  postRemoveResource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.changedFile"
    kind = "file"
    generation = 2
  }
  prompt = [pscustomobject]@{
    confirmationButton = "Remove"
    rendererCaptureExpectations = $removePromptExpectations
  }
  postRemoveFreshnessReport = $postRemoveCommandFreshnessReport
  closeReport = [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eCloseReport"
    generatedAt = "2026-06-25T00:00:08Z"
    repositoryId = $removeOpenReport.repository.repositoryId
    epoch = $removeOpenReport.repository.epoch
    repositoryClosed = $true
  }
  assertions = [pscustomobject]@{
    commandExecuted = $true
    fileExistedBefore = $removeFileExistedBefore
    fileExistsAfter = $removeFileExistsAfter
    sourceControlProjectionRefreshed = $true
  }
}
$removeCancellationPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Remove SVN resource src/tracked.txt? The local item will be deleted and scheduled for commit.", "Remove")
  requiredAccessibilityTokens = @("Remove SVN resource src/tracked.txt? The local item will be deleted and scheduled for commit.", "Remove")
  requiredScreenshot = $true
}
[pscustomobject]@{
  ok = $true
  phase = "removeCancellationPromptReady"
  command = "subversionr.removeResource"
  resource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.changedFile.baseDiffable"
    kind = "file"
    generation = 1
  }
  cancelAction = "notifications.clearAll"
  rendererCaptureExpectations = $removeCancellationPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $removeCancellationPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $removeCancellationPromptDonePath -Description "remove cancellation"
$removeCancellationTrackedPath = Join-Path $removeCancellationWorkingCopyRoot "src\tracked.txt"
$removeCancellationFileExistedBefore = Test-Path -LiteralPath $removeCancellationTrackedPath -PathType Leaf
$removeCancellationFileContentAfter = if (Test-Path -LiteralPath $removeCancellationTrackedPath -PathType Leaf) {
  Get-Content -Raw -LiteralPath $removeCancellationTrackedPath
}
else {
  $null
}
$removeCancellationOpenReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eOpenReport"
  generatedAt = "2026-06-25T00:00:08Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$removeCancellationWorkingCopyRoot"
    epoch = 9
    identity = [pscustomobject]@{
      repositoryUuid = "fixture-remove-cancellation-repository-uuid"
      repositoryRootUrl = "file:///fixture/remove-cancellation/repo"
      workingCopyRoot = $removeCancellationWorkingCopyRoot
      workspaceScopeRoot = $removeCancellationWorkingCopyRoot
      format = 31
    }
  }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$removeCancellationWorkingCopyRoot"
    epoch = 9
    workingCopyRoot = $removeCancellationWorkingCopyRoot
    generation = 1
    count = 1
    inputBox = $openReport.sourceControl.inputBox
    groups = $openReport.sourceControl.groups
  }
  rendererCaptureExpectations = $openReport.rendererCaptureExpectations
  surfaceWorkflow = $openReport.surfaceWorkflow
}
$postRemoveCancellationFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:08Z"
  scenario = "partial"
  repository = $removeCancellationOpenReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $removeCancellationOpenReport.sourceControl.repositoryId
    epoch = $removeCancellationOpenReport.sourceControl.epoch
    workingCopyRoot = $removeCancellationOpenReport.sourceControl.workingCopyRoot
    generation = 1
    count = 1
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($removeCancellationOpenReport.repository.repositoryId)
      }
    )
    inputBox = $removeCancellationOpenReport.sourceControl.inputBox
    groups = $removeCancellationOpenReport.sourceControl.groups
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$removeCancellationReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eRemoveCancellationWorkflow"
  generatedAt = "2026-06-25T00:00:08Z"
  command = [pscustomobject]@{
    command = "subversionr.removeResource"
  }
  repository = [pscustomobject]@{
    repositoryId = $removeCancellationOpenReport.repository.repositoryId
    epoch = $removeCancellationOpenReport.repository.epoch
    workingCopyRoot = $removeCancellationWorkingCopyRoot
  }
  resource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.changedFile.baseDiffable"
    kind = "file"
    generation = 1
  }
  postCancelResource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.changedFile.baseDiffable"
    kind = "file"
    generation = 1
  }
  prompt = [pscustomobject]@{
    cancelAction = "notifications.clearAll"
    rendererCaptureExpectations = $removeCancellationPromptExpectations
  }
  notificationCleanup = [pscustomobject]@{
    command = "notifications.clearAll"
    label = "removeCancellation"
    cleared = $true
  }
  postCancelFreshnessReport = $postRemoveCancellationFreshnessReport
  closeReport = [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eCloseReport"
    generatedAt = "2026-06-25T00:00:08Z"
    repositoryId = $removeCancellationOpenReport.repository.repositoryId
    epoch = $removeCancellationOpenReport.repository.epoch
    repositoryClosed = $true
  }
  assertions = [pscustomobject]@{
    commandCancelled = $true
    fileExistedBefore = $removeCancellationFileExistedBefore
    fileExistsAfter = $true
    fileContentAfter = $removeCancellationFileContentAfter
    sourceControlProjectionUnchanged = $true
  }
}
$resolveUpdateWarningExpectations = [pscustomobject]@{
  requiredDomTokens = @("SubversionR updated SVN working copy to revision", "The working copy has unresolved SVN conflicts (1): src/tracked.txt")
  requiredAccessibilityTokens = @("Warning", "SubversionR updated SVN working copy to revision", "The working copy has unresolved SVN conflicts (1): src/tracked.txt")
  requiredScreenshot = $true
}
[pscustomobject]@{
  ok = $true
  phase = "updateConflictWarningReady"
  command = "subversionr.updateRepository"
  conflictCount = 1
  conflictPaths = @("src/tracked.txt")
  updateNotificationCleanup = [pscustomobject]@{ command = "notifications.clearAll"; label = "updateRepositoryConflict"; cleared = $true }
  rendererCaptureExpectations = $resolveUpdateWarningExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolveUpdateWarningReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $resolveUpdateWarningDonePath -Description "resolve update warning"

$resolvePromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Resolve SVN conflict", "Working copy", "Use the current working copy file")
  requiredAccessibilityTokens = @("Resolve SVN conflict", "Working copy", "Use the current working copy file")
  requiredScreenshot = $true
  quickPickItemText = "Working copy"
}
[pscustomobject]@{
  ok = $true
  phase = "resolvePromptReady"
  command = "subversionr.resolveResource"
  resource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.conflicted"
    kind = "file"
    generation = 1
  }
  rendererCaptureExpectations = $resolvePromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolvePromptReadyPath -Encoding utf8
$resolveTrackedPath = Join-Path $resolveWorkingCopyRoot "src\tracked.txt"
$resolveFileExistedBefore = Test-Path -LiteralPath $resolveTrackedPath -PathType Leaf
$resolveContentBefore = "merged by M7j3 resolve`n"
Set-Content -LiteralPath $resolveTrackedPath -Value $resolveContentBefore -NoNewline -Encoding utf8
$resolveOpenReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eOpenReport"
  generatedAt = "2026-06-25T00:00:08Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$resolveWorkingCopyRoot"
    epoch = 9
    identity = [pscustomobject]@{
      repositoryUuid = "fixture-resolve-repository-uuid"
      repositoryRootUrl = "file:///fixture/resolve/repo"
      workingCopyRoot = $resolveWorkingCopyRoot
      workspaceScopeRoot = $resolveWorkingCopyRoot
      format = 31
    }
  }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$resolveWorkingCopyRoot"
    epoch = 9
    workingCopyRoot = $resolveWorkingCopyRoot
    generation = 1
    count = 1
    inputBox = $openReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{
        id = "conflicts"
        contextValue = "subversionr.conflicts"
        hideWhenEmpty = $true
        count = 1
        resources = @(
          [pscustomobject]@{
            path = "src/tracked.txt"
            contextValue = "subversionr.conflicted"
            kind = "file"
            generation = 1
          }
        )
      }
    )
  }
  rendererCaptureExpectations = $openReport.rendererCaptureExpectations
  surfaceWorkflow = $openReport.surfaceWorkflow
}
$postResolveFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:08Z"
  scenario = "partial"
  repository = $resolveOpenReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $resolveOpenReport.sourceControl.repositoryId
    epoch = $resolveOpenReport.sourceControl.epoch
    workingCopyRoot = $resolveOpenReport.sourceControl.workingCopyRoot
    generation = 2
    count = 1
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($resolveOpenReport.repository.repositoryId)
      }
    )
    inputBox = $resolveOpenReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{
        id = "changes"
        contextValue = "subversionr.changes"
        hideWhenEmpty = $true
        count = 1
        resources = @(
          [pscustomobject]@{
            path = "src/tracked.txt"
            contextValue = "subversionr.changedFile.baseDiffable"
            kind = "file"
            generation = 2
          }
        )
      }
    )
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$resolveReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eResolveWorkflow"
  generatedAt = "2026-06-25T00:00:08Z"
  command = [pscustomobject]@{
    command = "subversionr.resolveResource"
  }
  repository = [pscustomobject]@{
    repositoryId = $resolveOpenReport.repository.repositoryId
    epoch = $resolveOpenReport.repository.epoch
    workingCopyRoot = $resolveWorkingCopyRoot
  }
  resource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.conflicted"
    kind = "file"
    generation = 1
  }
  request = [pscustomobject]@{
    paths = @("src/tracked.txt")
    depth = "empty"
    choice = "working"
  }
  updateConflict = [pscustomobject]@{
    command = "subversionr.updateRepository"
    conflictCount = 1
    conflictPaths = @("src/tracked.txt")
    warning = [pscustomobject]@{
      rendererCaptureExpectations = $resolveUpdateWarningExpectations
      plainSuccessNotificationExpected = $false
    }
    notificationCleanup = [pscustomobject]@{ command = "notifications.clearAll"; label = "updateRepositoryConflict"; cleared = $true }
    postUpdateFreshnessReport = [pscustomobject]@{ kind = "subversionr.installedSourceControlUiE2eFreshnessReport" }
  }
  postResolveResource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.changedFile.baseDiffable"
    kind = "file"
    generation = 2
  }
  prompt = [pscustomobject]@{
    quickPickItemText = "Working copy"
    rendererCaptureExpectations = $resolvePromptExpectations
  }
  postResolveFreshnessReport = $postResolveFreshnessReport
  closeReport = [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eCloseReport"
    generatedAt = "2026-06-25T00:00:08Z"
    repositoryId = $resolveOpenReport.repository.repositoryId
    epoch = $resolveOpenReport.repository.epoch
    repositoryClosed = $true
  }
  assertions = [pscustomobject]@{
    commandExecuted = $true
    installedUpdateExecuted = $true
    installedUpdateCreatedConflict = $true
    updateWarningConflictCount = 1
    updateWarningNamedConflictPath = $true
    plainUpdateSuccessNotificationExpected = $false
    fileExistedBefore = $resolveFileExistedBefore
    conflictProjectedBefore = $true
    conflictProjectedAfter = $false
    fileContentBefore = $resolveContentBefore
    fileContentAfter = $resolveContentBefore
    fileContentPreservedAfter = $true
    sourceControlProjectionRefreshed = $true
  }
}
$resolveCancellationPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Resolve SVN conflict", "Working copy", "Use the current working copy file")
  requiredAccessibilityTokens = @("Resolve SVN conflict", "Working copy", "Use the current working copy file")
  requiredScreenshot = $true
  cancelKey = "Escape"
  cancelSurface = "quickInput"
}
[pscustomobject]@{
  ok = $true
  phase = "resolveCancellationPromptReady"
  command = "subversionr.resolveResource"
  resource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.conflicted"
    kind = "file"
    generation = 1
  }
  rendererCaptureExpectations = $resolveCancellationPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolveCancellationPromptReadyPath -Encoding utf8
$resolveCancellationTrackedPath = Join-Path $resolveCancellationWorkingCopyRoot "src\tracked.txt"
$resolveCancellationFileExistedBefore = Test-Path -LiteralPath $resolveCancellationTrackedPath -PathType Leaf
$resolveCancellationContentBefore = "merged by M7j3 resolve`n"
Set-Content -LiteralPath $resolveCancellationTrackedPath -Value $resolveCancellationContentBefore -NoNewline -Encoding utf8
$resolveCancellationContentAfter = Get-Content -Raw -LiteralPath $resolveCancellationTrackedPath
$resolveCancellationOpenReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eOpenReport"
  generatedAt = "2026-06-25T00:00:08Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$resolveCancellationWorkingCopyRoot"
    epoch = 10
    identity = [pscustomobject]@{
      repositoryUuid = "fixture-resolve-cancellation-repository-uuid"
      repositoryRootUrl = "file:///fixture/resolve-cancellation/repo"
      workingCopyRoot = $resolveCancellationWorkingCopyRoot
      workspaceScopeRoot = $resolveCancellationWorkingCopyRoot
      format = 31
    }
  }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$resolveCancellationWorkingCopyRoot"
    epoch = 10
    workingCopyRoot = $resolveCancellationWorkingCopyRoot
    generation = 1
    count = 1
    inputBox = $openReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{
        id = "conflicts"
        contextValue = "subversionr.conflicts"
        hideWhenEmpty = $true
        count = 1
        resources = @(
          [pscustomobject]@{
            path = "src/tracked.txt"
            contextValue = "subversionr.conflicted"
            kind = "file"
            generation = 1
          }
        )
      }
    )
  }
  rendererCaptureExpectations = $openReport.rendererCaptureExpectations
  surfaceWorkflow = $openReport.surfaceWorkflow
}
$postResolveCancellationFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:08Z"
  scenario = "partial"
  repository = $resolveCancellationOpenReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $resolveCancellationOpenReport.sourceControl.repositoryId
    epoch = $resolveCancellationOpenReport.sourceControl.epoch
    workingCopyRoot = $resolveCancellationOpenReport.sourceControl.workingCopyRoot
    generation = 1
    count = 1
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($resolveCancellationOpenReport.repository.repositoryId)
      }
    )
    inputBox = $resolveCancellationOpenReport.sourceControl.inputBox
    groups = $resolveCancellationOpenReport.sourceControl.groups
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$resolveCancellationReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eResolveCancellationWorkflow"
  generatedAt = "2026-06-25T00:00:08Z"
  command = [pscustomobject]@{
    command = "subversionr.resolveResource"
  }
  repository = [pscustomobject]@{
    repositoryId = $resolveCancellationOpenReport.repository.repositoryId
    epoch = $resolveCancellationOpenReport.repository.epoch
    workingCopyRoot = $resolveCancellationWorkingCopyRoot
  }
  resource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.conflicted"
    kind = "file"
    generation = 1
  }
  request = [pscustomobject]@{
    paths = @("src/tracked.txt")
    depth = "empty"
    choice = "working"
  }
  postCancelResource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.conflicted"
    kind = "file"
    generation = 1
  }
  prompt = [pscustomobject]@{
    cancelKey = "Escape"
    rendererCaptureExpectations = $resolveCancellationPromptExpectations
  }
  notificationCleanup = [pscustomobject]@{
    command = "notifications.clearAll"
    label = "resolveResourceCancellation"
    cleared = $true
  }
  postCancelFreshnessReport = $postResolveCancellationFreshnessReport
  closeReport = [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eCloseReport"
    generatedAt = "2026-06-25T00:00:08Z"
    repositoryId = $resolveCancellationOpenReport.repository.repositoryId
    epoch = $resolveCancellationOpenReport.repository.epoch
    repositoryClosed = $true
  }
  assertions = [pscustomobject]@{
    commandCancelled = $true
    fileExistedBefore = $resolveCancellationFileExistedBefore
    conflictProjectedBefore = $true
    conflictProjectedAfter = $true
    fileContentBefore = $resolveCancellationContentBefore
    fileContentAfter = $resolveCancellationContentAfter
    fileContentPreservedAfter = $true
    sourceControlProjectionUnchanged = $true
  }
}
$removeKeepLocalPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Remove SVN resource src/tracked.txt from version control but keep the local item?", "Remove")
  requiredAccessibilityTokens = @("Remove SVN resource src/tracked.txt from version control but keep the local item?", "Remove")
  requiredScreenshot = $true
  clickButtonText = "Remove"
}
[pscustomobject]@{
  ok = $true
  phase = "removeKeepLocalPromptReady"
  command = "subversionr.removeResourceKeepLocal"
  resource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.changedFile.baseDiffable"
    kind = "file"
    generation = 2
  }
  rendererCaptureExpectations = $removeKeepLocalPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $removeKeepLocalPromptReadyPath -Encoding utf8
$trackedPath = Join-Path $workingCopyRoot "src\tracked.txt"
$trackedFileExistedBefore = Test-Path -LiteralPath $trackedPath -PathType Leaf
$preRemoveKeepLocalFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:08Z"
  scenario = "partial"
  repository = $openReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $openReport.sourceControl.repositoryId
    epoch = $openReport.sourceControl.epoch
    workingCopyRoot = $openReport.sourceControl.workingCopyRoot
    generation = 2
    count = 1
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($openReport.repository.repositoryId)
      }
    )
    inputBox = $openReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{
        id = "changes"
        contextValue = "subversionr.changes"
        hideWhenEmpty = $true
        count = 1
        resources = @(
          [pscustomobject]@{
            path = "src/tracked.txt"
            contextValue = "subversionr.changedFile.baseDiffable"
            kind = "file"
            generation = 2
          }
        )
      },
      [pscustomobject]@{
        id = "unversioned"
        contextValue = "subversionr.unversioned"
        hideWhenEmpty = $true
        count = 0
        resources = @()
      }
    )
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$postRemoveFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:08Z"
  scenario = "partial"
  repository = $openReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $openReport.sourceControl.repositoryId
    epoch = $openReport.sourceControl.epoch
    workingCopyRoot = $openReport.sourceControl.workingCopyRoot
    generation = 3
    count = 1
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($openReport.repository.repositoryId)
      }
    )
    inputBox = $openReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{
        id = "changes"
        contextValue = "subversionr.changes"
        hideWhenEmpty = $true
        count = 1
        resources = @(
          [pscustomobject]@{
            path = "src/tracked.txt"
            contextValue = "subversionr.changedFile"
            kind = "file"
            generation = 3
          }
        )
      },
      [pscustomobject]@{
        id = "unversioned"
        contextValue = "subversionr.unversioned"
        hideWhenEmpty = $true
        count = 0
        resources = @()
      }
    )
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$removeKeepLocalReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eRemoveKeepLocalWorkflow"
  generatedAt = "2026-06-25T00:00:08Z"
  command = [pscustomobject]@{
    command = "subversionr.removeResourceKeepLocal"
  }
  resource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.changedFile.baseDiffable"
    kind = "file"
    generation = 2
  }
  postRemoveResource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.changedFile"
    kind = "file"
    generation = 3
  }
  prompt = [pscustomobject]@{
    confirmationButton = "Remove"
    rendererCaptureExpectations = $removeKeepLocalPromptExpectations
  }
  preRemoveFreshnessReport = $preRemoveKeepLocalFreshnessReport
  postRemoveFreshnessReport = $postRemoveFreshnessReport
  assertions = [pscustomobject]@{
    commandExecuted = $true
    fileExistedBefore = $trackedFileExistedBefore
    fileExistsAfter = (Test-Path -LiteralPath $trackedPath -PathType Leaf)
    sourceControlProjectionRefreshed = $true
  }
}
$revertPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Revert local SVN changes to src/tracked.txt? This cannot be undone.", "Revert")
  requiredAccessibilityTokens = @("Revert local SVN changes to src/tracked.txt? This cannot be undone.", "Revert")
  requiredScreenshot = $true
  clickButtonText = "Revert"
}
[pscustomobject]@{
  ok = $true
  phase = "revertPromptReady"
  command = "subversionr.revertResource"
  resource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.changedFile.baseDiffable"
    kind = "file"
    generation = 1
  }
  rendererCaptureExpectations = $revertPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $revertPromptReadyPath -Encoding utf8
$revertTrackedPath = Join-Path $revertWorkingCopyRoot "src\tracked.txt"
$revertFileExistedBefore = Test-Path -LiteralPath $revertTrackedPath -PathType Leaf
Set-Content -LiteralPath $revertTrackedPath -Value "initial`n" -NoNewline -Encoding utf8
$revertOpenReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eOpenReport"
  generatedAt = "2026-06-25T00:00:09Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$revertWorkingCopyRoot"
    epoch = 5
    identity = [pscustomobject]@{
      repositoryUuid = "fixture-revert-repository-uuid"
      repositoryRootUrl = "file:///fixture/revert/repo"
      workingCopyRoot = $revertWorkingCopyRoot
      workspaceScopeRoot = $revertWorkingCopyRoot
      format = 31
    }
  }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$revertWorkingCopyRoot"
    epoch = 5
    workingCopyRoot = $revertWorkingCopyRoot
    generation = 1
    count = 1
    inputBox = $openReport.sourceControl.inputBox
    groups = $openReport.sourceControl.groups
  }
  rendererCaptureExpectations = $openReport.rendererCaptureExpectations
  surfaceWorkflow = $openReport.surfaceWorkflow
}
$postRevertFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:09Z"
  scenario = "partial"
  repository = $revertOpenReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $revertOpenReport.sourceControl.repositoryId
    epoch = $revertOpenReport.sourceControl.epoch
    workingCopyRoot = $revertOpenReport.sourceControl.workingCopyRoot
    generation = 2
    count = 1
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($revertOpenReport.repository.repositoryId)
      }
    )
    inputBox = $revertOpenReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{
        id = "unversioned"
        contextValue = "subversionr.unversioned"
        hideWhenEmpty = $true
        count = 1
        resources = @(
          [pscustomobject]@{
            path = "scratch.txt"
            contextValue = "subversionr.unversioned"
            kind = "file"
            generation = 2
          }
        )
      }
    )
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$revertReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eRevertWorkflow"
  generatedAt = "2026-06-25T00:00:09Z"
  command = [pscustomobject]@{
    command = "subversionr.revertResource"
  }
  repository = [pscustomobject]@{
    repositoryId = $revertOpenReport.repository.repositoryId
    epoch = $revertOpenReport.repository.epoch
    workingCopyRoot = $revertWorkingCopyRoot
  }
  resource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.changedFile.baseDiffable"
    kind = "file"
    generation = 1
  }
  prompt = [pscustomobject]@{
    confirmationButton = "Revert"
    rendererCaptureExpectations = $revertPromptExpectations
  }
  postRevertFreshnessReport = $postRevertFreshnessReport
  closeReport = [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eCloseReport"
    generatedAt = "2026-06-25T00:00:09Z"
    repositoryId = $revertOpenReport.repository.repositoryId
    epoch = $revertOpenReport.repository.epoch
    repositoryClosed = $true
  }
  assertions = [pscustomobject]@{
    commandExecuted = $true
    fileExistedBefore = $revertFileExistedBefore
    fileContentAfter = "initial`n"
    resourcePresentAfter = $false
  }
}
$revertCancellationPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Revert local SVN changes to src/tracked.txt? This cannot be undone.", "Revert")
  requiredAccessibilityTokens = @("Revert local SVN changes to src/tracked.txt? This cannot be undone.", "Revert")
  requiredScreenshot = $true
}
[pscustomobject]@{
  ok = $true
  phase = "revertCancellationPromptReady"
  command = "subversionr.revertResource"
  resource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.changedFile.baseDiffable"
    kind = "file"
    generation = 1
  }
  cancelAction = "notifications.clearAll"
  rendererCaptureExpectations = $revertCancellationPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $revertCancellationPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $revertCancellationPromptDonePath -Description "revert cancellation"
$revertCancellationTrackedPath = Join-Path $revertCancellationWorkingCopyRoot "src\tracked.txt"
$revertCancellationFileExistedBefore = Test-Path -LiteralPath $revertCancellationTrackedPath -PathType Leaf
$revertCancellationFileContentAfter = if (Test-Path -LiteralPath $revertCancellationTrackedPath -PathType Leaf) {
  Get-Content -Raw -LiteralPath $revertCancellationTrackedPath
}
else {
  $null
}
$revertCancellationOpenReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eOpenReport"
  generatedAt = "2026-06-25T00:00:09Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$revertCancellationWorkingCopyRoot"
    epoch = 9
    identity = [pscustomobject]@{
      repositoryUuid = "fixture-revert-cancellation-repository-uuid"
      repositoryRootUrl = "file:///fixture/revert-cancellation/repo"
      workingCopyRoot = $revertCancellationWorkingCopyRoot
      workspaceScopeRoot = $revertCancellationWorkingCopyRoot
      format = 31
    }
  }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$revertCancellationWorkingCopyRoot"
    epoch = 9
    workingCopyRoot = $revertCancellationWorkingCopyRoot
    generation = 1
    count = 1
    inputBox = $openReport.sourceControl.inputBox
    groups = $openReport.sourceControl.groups
  }
  rendererCaptureExpectations = $openReport.rendererCaptureExpectations
  surfaceWorkflow = $openReport.surfaceWorkflow
}
$postRevertCancellationFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:09Z"
  scenario = "partial"
  repository = $revertCancellationOpenReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $revertCancellationOpenReport.sourceControl.repositoryId
    epoch = $revertCancellationOpenReport.sourceControl.epoch
    workingCopyRoot = $revertCancellationOpenReport.sourceControl.workingCopyRoot
    generation = 1
    count = 1
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($revertCancellationOpenReport.repository.repositoryId)
      }
    )
    inputBox = $revertCancellationOpenReport.sourceControl.inputBox
    groups = $revertCancellationOpenReport.sourceControl.groups
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$revertCancellationReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eRevertCancellationWorkflow"
  generatedAt = "2026-06-25T00:00:09Z"
  command = [pscustomobject]@{
    command = "subversionr.revertResource"
  }
  repository = [pscustomobject]@{
    repositoryId = $revertCancellationOpenReport.repository.repositoryId
    epoch = $revertCancellationOpenReport.repository.epoch
    workingCopyRoot = $revertCancellationWorkingCopyRoot
  }
  resource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.changedFile.baseDiffable"
    kind = "file"
    generation = 1
  }
  postCancelResource = [pscustomobject]@{
    path = "src/tracked.txt"
    contextValue = "subversionr.changedFile.baseDiffable"
    kind = "file"
    generation = 1
  }
  prompt = [pscustomobject]@{
    cancelAction = "notifications.clearAll"
    rendererCaptureExpectations = $revertCancellationPromptExpectations
  }
  notificationCleanup = [pscustomobject]@{
    command = "notifications.clearAll"
    label = "revertCancellation"
    cleared = $true
  }
  postCancelFreshnessReport = $postRevertCancellationFreshnessReport
  closeReport = [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eCloseReport"
    generatedAt = "2026-06-25T00:00:09Z"
    repositoryId = $revertCancellationOpenReport.repository.repositoryId
    epoch = $revertCancellationOpenReport.repository.epoch
    repositoryClosed = $true
  }
  assertions = [pscustomobject]@{
    commandCancelled = $true
    fileExistedBefore = $revertCancellationFileExistedBefore
    fileContentAfter = $revertCancellationFileContentAfter
    resourcePresentAfter = $true
    sourceControlProjectionUnchanged = $true
  }
}
$postCleanupFreshnessReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eFreshnessReport"
  generatedAt = "2026-06-25T00:00:10Z"
  scenario = "partial"
  repository = $openReport.repository
  sourceControl = [pscustomobject]@{
    repositoryId = $openReport.sourceControl.repositoryId
    epoch = $openReport.sourceControl.epoch
    workingCopyRoot = $openReport.sourceControl.workingCopyRoot
    generation = 4
    count = 1
    freshness = [pscustomobject]@{
      repositoryCompleteness = "partial"
      lastRefreshCompleteness = "partial"
      lastRefreshKind = "snapshot"
    }
    statusBarCommands = @(
      [pscustomobject]@{
        command = "subversionr.fullReconcile"
        title = "SVN status partial"
        arguments = @($openReport.repository.repositoryId)
      }
    )
    inputBox = $openReport.sourceControl.inputBox
    groups = $postRemoveFreshnessReport.sourceControl.groups
  }
  freshnessWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    currentEpochMatched = $true
    sourceControlSurface = $true
  }
}
$cleanupPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN cleanup options", "Break working-copy locks", "Release stale SVN working-copy locks before cleanup")
  requiredAccessibilityTokens = @("SVN cleanup options", "Break working-copy locks", "Release stale SVN working-copy locks before cleanup")
  requiredScreenshot = $true
  quickInputSubmitKey = "Enter"
}
[pscustomobject]@{
  ok = $true
  phase = "cleanupPromptReady"
  command = "subversionr.cleanupRepository"
  repositoryId = $openReport.repository.repositoryId
  rendererCaptureExpectations = $cleanupPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $cleanupPromptReadyPath -Encoding utf8
$cleanupReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCleanupWorkflow"
  generatedAt = "2026-06-25T00:00:10Z"
  command = [pscustomobject]@{
    command = "subversionr.cleanupRepository"
  }
  repository = [pscustomobject]@{
    repositoryId = $openReport.repository.repositoryId
    epoch = $openReport.repository.epoch
    workingCopyRoot = $workingCopyRoot
  }
  request = [pscustomobject]@{
    path = "."
    breakLocks = $true
    fixRecordedTimestamps = $false
    clearDavCache = $false
    vacuumPristines = $false
    includeExternals = $false
  }
  prompt = [pscustomobject]@{
    quickInputSubmitKey = "Enter"
    rendererCaptureExpectations = $cleanupPromptExpectations
  }
  postCleanupFreshnessReport = $postCleanupFreshnessReport
  assertions = [pscustomobject]@{
    commandExecuted = $true
    repositoryOpenBefore = $true
    fullReconcileAfterCleanup = $true
    sourceControlSurfaceAfterCleanup = $true
  }
}
$closeReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCloseReport"
  generatedAt = "2026-06-25T00:00:11Z"
  repositoryId = $openReport.repository.repositoryId
  epoch = $openReport.repository.epoch
  repositoryClosed = $true
}
$noRepositoryWelcomeRendererExpectations = [pscustomobject]@{
  viewCommand = "workbench.view.scm"
  requiredDomTokens = @("No SVN working copy was found in the workspace", "Scan for SVN Working Copies", "Checkout Repository URL")
  requiredAccessibilityTokens = @("No SVN working copy was found in the workspace", "Scan for SVN Working Copies", "Checkout Repository URL")
  requiredScreenshot = $true
}
[pscustomobject]@{
  ok = $true
  phase = "focusingNoRepositoryWelcome"
  claim = "UX-002 partial: localized no-repository Scan and Checkout Repository URL welcome entries"
  scanCommand = "subversionr.openRepository"
  checkoutCommand = "subversionr.checkoutRepository"
  nonClaims = @(
    "This installed UI evidence verifies the Checkout Repository URL no-repository welcome entry, URL prompt cancellation, covered local-file checkout failure/no-state-pollution flows, the local-file checkout happy path, the pre-existing local directory target success path, and the existing-directory obstruction tree-conflict projection path but does not cover repository browser, remote auth/certificate, or broader checkout failure matrices."
  )
  closeReport = [pscustomobject]@{
    repositoryId = $closeReport.repositoryId
    epoch = $closeReport.epoch
    repositoryClosed = $closeReport.repositoryClosed
  }
  rendererCaptureExpectations = $noRepositoryWelcomeRendererExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $noRepositoryWelcomeRendererReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $noRepositoryWelcomeRendererDonePath -Description "no-repository welcome"
$checkoutCancellationPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Checkout SVN repository", "Enter the SVN repository URL to checkout.")
  requiredAccessibilityTokens = @("Checkout SVN repository", "Enter the SVN repository URL to checkout.")
  requiredScreenshot = $true
  cancelSurface = "quickInput"
  cancelKey = "Escape"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutCancellationPromptReady"
  command = "subversionr.checkoutRepository"
  request = [pscustomobject]@{
    url = $checkoutRepositoryUrl
    targetPath = $checkoutCancellationTargetWorkingCopyRoot
    revision = "head"
    depth = "infinity"
    ignoreExternals = $true
  }
  prompt = [pscustomobject]@{
    kind = "url"
    cancelKey = "Escape"
    rendererCaptureExpectations = $checkoutCancellationPromptExpectations
  }
  rendererCaptureExpectations = $checkoutCancellationPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutCancellationPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutCancellationPromptDonePath -Description "checkout cancellation"
function New-FakeMissingCurrentSurfaceProbe([string]$Path) {
  [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eMissingCurrentSurfaceProbe"
    generatedAt = "2026-06-25T00:00:11Z"
    command = [pscustomobject]@{
      command = "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport"
    }
    request = [pscustomobject]@{
      path = $Path
    }
    error = [pscustomobject]@{
      message = "No installed Source Control UI E2E session is open for the requested path."
      code = "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CURRENT_SESSION_MISSING"
      category = "lifecycle"
      messageKey = "error.diagnostics.installedSourceControlUiE2eSessionMismatch"
    }
    assertions = [pscustomobject]@{
      currentSessionMissing = $true
      sourceControlProjectionAbsent = $true
    }
  }
}
$checkoutCancellationBaselineBeforeProbe = New-FakeMissingCurrentSurfaceProbe -Path $workingCopyRoot
$checkoutCancellationBaselineAfterProbe = New-FakeMissingCurrentSurfaceProbe -Path $workingCopyRoot
$checkoutCancellationTargetBeforeProbe = New-FakeMissingCurrentSurfaceProbe -Path $checkoutCancellationTargetWorkingCopyRoot
$checkoutCancellationTargetAfterProbe = New-FakeMissingCurrentSurfaceProbe -Path $checkoutCancellationTargetWorkingCopyRoot
$checkoutCancellationReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCheckoutCancellationWorkflow"
  generatedAt = "2026-06-25T00:00:11Z"
  command = [pscustomobject]@{
    command = "subversionr.checkoutRepository"
  }
  request = [pscustomobject]@{
    url = $checkoutRepositoryUrl
    baselineWorkingCopyRoot = $workingCopyRoot
    targetPath = $checkoutCancellationTargetWorkingCopyRoot
    revision = "head"
    depth = "infinity"
    ignoreExternals = $true
  }
  prompt = [pscustomobject]@{
    kind = "url"
    cancelKey = "Escape"
    rendererCaptureExpectations = $checkoutCancellationPromptExpectations
  }
  target = [pscustomobject]@{
    workingCopyRoot = $checkoutCancellationTargetWorkingCopyRoot
    svnMetadataPath = Join-Path $checkoutCancellationTargetWorkingCopyRoot ".svn"
  }
  currentSurfaceProbes = [pscustomobject]@{
    baselineBefore = $checkoutCancellationBaselineBeforeProbe
    baselineAfter = $checkoutCancellationBaselineAfterProbe
    targetBefore = $checkoutCancellationTargetBeforeProbe
    targetAfter = $checkoutCancellationTargetAfterProbe
  }
  assertions = [pscustomobject]@{
    commandCancelled = $true
    targetAbsentAfter = -not (Test-Path -LiteralPath $checkoutCancellationTargetWorkingCopyRoot)
    svnMetadataAbsentAfter = -not (Test-Path -LiteralPath (Join-Path $checkoutCancellationTargetWorkingCopyRoot ".svn"))
    repositoryNotOpenedAfterCancellation = $true
    sourceControlProjectionUnchanged = $true
  }
}
$checkoutExistingTargetFailureUrlPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Checkout SVN repository", "Enter the SVN repository URL to checkout.")
  requiredAccessibilityTokens = @("Checkout SVN repository", "Enter the SVN repository URL to checkout.")
  requiredScreenshot = $true
  inputText = $checkoutRepositoryUrl
  submitKey = "Enter"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutExistingTargetFailureUrlPromptReady"
  command = "subversionr.checkoutRepository"
  request = [pscustomobject]@{
    url = $checkoutRepositoryUrl
    targetPath = $checkoutExistingTargetFailureTargetPath
    revision = "head"
    depth = "infinity"
    ignoreExternals = $true
  }
  prompt = [pscustomobject]@{
    kind = "url"
    rendererCaptureExpectations = $checkoutExistingTargetFailureUrlPromptExpectations
  }
  rendererCaptureExpectations = $checkoutExistingTargetFailureUrlPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutExistingTargetFailureUrlPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutExistingTargetFailureUrlPromptDonePath -Description "checkout existing-target failure URL"
$checkoutExistingTargetFailureTargetPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN checkout target folder", "Enter the absolute local folder path for the checkout.")
  requiredAccessibilityTokens = @("SVN checkout target folder", "Enter the absolute local folder path for the checkout.")
  requiredScreenshot = $true
  inputText = $checkoutExistingTargetFailureTargetPath
  submitKey = "Enter"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutExistingTargetFailureTargetPromptReady"
  command = "subversionr.checkoutRepository"
  rendererCaptureExpectations = $checkoutExistingTargetFailureTargetPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutExistingTargetFailureTargetPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutExistingTargetFailureTargetPromptDonePath -Description "checkout existing-target failure target"
$checkoutExistingTargetFailureRevisionPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN checkout revision", "HEAD", "Revision number")
  requiredAccessibilityTokens = @("SVN checkout revision", "HEAD", "Revision number")
  requiredScreenshot = $true
  quickPickItemText = "HEAD"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutExistingTargetFailureRevisionPromptReady"
  command = "subversionr.checkoutRepository"
  rendererCaptureExpectations = $checkoutExistingTargetFailureRevisionPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutExistingTargetFailureRevisionPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutExistingTargetFailureRevisionPromptDonePath -Description "checkout existing-target failure revision"
$checkoutExistingTargetFailureDepthPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN checkout depth", "Empty", "Files", "Immediates", "Infinity")
  requiredAccessibilityTokens = @("SVN checkout depth", "Empty", "Files", "Immediates", "Infinity")
  requiredScreenshot = $true
  quickPickItemText = "Infinity"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutExistingTargetFailureDepthPromptReady"
  command = "subversionr.checkoutRepository"
  rendererCaptureExpectations = $checkoutExistingTargetFailureDepthPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutExistingTargetFailureDepthPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutExistingTargetFailureDepthPromptDonePath -Description "checkout existing-target failure depth"
$checkoutExistingTargetFailureExternalsPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN checkout externals", "Ignore externals", "Include externals")
  requiredAccessibilityTokens = @("SVN checkout externals", "Ignore externals", "Include externals")
  requiredScreenshot = $true
  quickPickItemText = "Ignore externals"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutExistingTargetFailureExternalsPromptReady"
  command = "subversionr.checkoutRepository"
  rendererCaptureExpectations = $checkoutExistingTargetFailureExternalsPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutExistingTargetFailureExternalsPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutExistingTargetFailureExternalsPromptDonePath -Description "checkout existing-target failure externals"
if (-not (Test-Path -LiteralPath $checkoutExistingTargetFailureTargetPath -PathType Leaf)) {
  throw "fake installed Checkout existing-target failure target path must be an existing file."
}
function Get-FakeDirectoryEntries([string]$Path) {
  @(Get-ChildItem -LiteralPath $Path -Force |
    Sort-Object -Property Name |
    ForEach-Object {
      [pscustomobject]@{
        name = $_.Name
        kind = $(if ($_.PSIsContainer) { "directory" } else { "file" })
      }
    })
}
$checkoutExistingTargetFailureParentPath = Split-Path -Parent $checkoutExistingTargetFailureTargetPath
$checkoutExistingTargetFailureParentEntriesBefore = Get-FakeDirectoryEntries -Path $checkoutExistingTargetFailureParentPath
$checkoutExistingTargetFailureHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $checkoutExistingTargetFailureTargetPath).Hash.ToLowerInvariant()
$checkoutExistingTargetFailureNotificationExpectations = [pscustomobject]@{
  requiredDomTokens = @("SubversionR repository command failed", "SUBVERSIONR_REPOSITORY_COMMAND_FAILED")
  requiredAccessibilityTokens = @("SubversionR repository command failed", "SUBVERSIONR_REPOSITORY_COMMAND_FAILED")
  requiredScreenshot = $true
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutExistingTargetFailureNotificationReady"
  command = "subversionr.checkoutRepository"
  request = [pscustomobject]@{
    url = $checkoutRepositoryUrl
    targetPath = $checkoutExistingTargetFailureTargetPath
    revision = "head"
    depth = "infinity"
    ignoreExternals = $true
  }
  failure = [pscustomobject]@{
    code = "SVN_REPOSITORY_CHECKOUT_FAILED"
    category = "native"
    notificationText = "SubversionR repository command failed: SUBVERSIONR_REPOSITORY_COMMAND_FAILED"
  }
  notification = [pscustomobject]@{
    rendererCaptureExpectations = $checkoutExistingTargetFailureNotificationExpectations
    cleanup = [pscustomobject]@{
      command = "notifications.clearAll"
      label = "checkoutExistingTargetFailureNotification"
      cleared = $true
    }
  }
  rendererCaptureExpectations = $checkoutExistingTargetFailureNotificationExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutExistingTargetFailureNotificationReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutExistingTargetFailureNotificationDonePath -Description "checkout existing-target failure notification"
$checkoutExistingTargetFailureHashAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $checkoutExistingTargetFailureTargetPath).Hash.ToLowerInvariant()
$checkoutExistingTargetFailureParentEntriesAfter = Get-FakeDirectoryEntries -Path $checkoutExistingTargetFailureParentPath
$checkoutExistingTargetFailureBaselineBeforeProbe = New-FakeMissingCurrentSurfaceProbe -Path $workingCopyRoot
$checkoutExistingTargetFailureBaselineAfterProbe = New-FakeMissingCurrentSurfaceProbe -Path $workingCopyRoot
$checkoutExistingTargetFailureTargetBeforeProbe = New-FakeMissingCurrentSurfaceProbe -Path $checkoutExistingTargetFailureTargetPath
$checkoutExistingTargetFailureTargetAfterProbe = New-FakeMissingCurrentSurfaceProbe -Path $checkoutExistingTargetFailureTargetPath
$checkoutExistingTargetFailureReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCheckoutExistingTargetFailureWorkflow"
  generatedAt = "2026-06-25T00:00:11Z"
  command = [pscustomobject]@{
    command = "subversionr.checkoutRepository"
  }
  request = [pscustomobject]@{
    url = $checkoutRepositoryUrl
    targetPath = $checkoutExistingTargetFailureTargetPath
    revision = "head"
    depth = "infinity"
    ignoreExternals = $true
  }
  prompts = [pscustomobject]@{
    url = [pscustomobject]@{ rendererCaptureExpectations = $checkoutExistingTargetFailureUrlPromptExpectations }
    targetPath = [pscustomobject]@{ rendererCaptureExpectations = $checkoutExistingTargetFailureTargetPromptExpectations }
    revision = [pscustomobject]@{ selected = "HEAD"; rendererCaptureExpectations = $checkoutExistingTargetFailureRevisionPromptExpectations }
    depth = [pscustomobject]@{ selected = "Infinity"; rendererCaptureExpectations = $checkoutExistingTargetFailureDepthPromptExpectations }
    externals = [pscustomobject]@{ selected = "Ignore externals"; rendererCaptureExpectations = $checkoutExistingTargetFailureExternalsPromptExpectations }
  }
  failure = [pscustomobject]@{
    code = "SVN_REPOSITORY_CHECKOUT_FAILED"
    category = "native"
    notificationText = "SubversionR repository command failed: SUBVERSIONR_REPOSITORY_COMMAND_FAILED"
  }
  notification = [pscustomobject]@{
    rendererCaptureExpectations = $checkoutExistingTargetFailureNotificationExpectations
    cleanup = [pscustomobject]@{
      command = "notifications.clearAll"
      label = "checkoutExistingTargetFailureNotification"
      cleared = $true
    }
  }
  target = [pscustomobject]@{
    obstructingFilePath = $checkoutExistingTargetFailureTargetPath
    parentDirectoryPath = $checkoutExistingTargetFailureParentPath
    sha256Before = $checkoutExistingTargetFailureHashBefore
    sha256After = $checkoutExistingTargetFailureHashAfter
    svnMetadataPath = Join-Path $checkoutExistingTargetFailureTargetPath ".svn"
    parentSvnMetadataPath = Join-Path $checkoutExistingTargetFailureParentPath ".svn"
    parentDirectoryEntriesBefore = $checkoutExistingTargetFailureParentEntriesBefore
    parentDirectoryEntriesAfter = $checkoutExistingTargetFailureParentEntriesAfter
  }
  currentSurfaceProbes = [pscustomobject]@{
    baselineBefore = $checkoutExistingTargetFailureBaselineBeforeProbe
    baselineAfter = $checkoutExistingTargetFailureBaselineAfterProbe
    targetBefore = $checkoutExistingTargetFailureTargetBeforeProbe
    targetAfter = $checkoutExistingTargetFailureTargetAfterProbe
  }
  assertions = [pscustomobject]@{
    commandFailed = $true
    obstructingTargetFilePreserved = $checkoutExistingTargetFailureHashAfter -eq $checkoutExistingTargetFailureHashBefore
    svnMetadataAbsentAfter = (-not (Test-Path -LiteralPath (Join-Path $checkoutExistingTargetFailureTargetPath ".svn"))) -and (-not (Test-Path -LiteralPath (Join-Path $checkoutExistingTargetFailureParentPath ".svn")))
    fixtureDirectoryUnchanged = ($checkoutExistingTargetFailureParentEntriesBefore | ConvertTo-Json -Depth 4 -Compress) -eq ($checkoutExistingTargetFailureParentEntriesAfter | ConvertTo-Json -Depth 4 -Compress)
    repositoryNotOpenedAfterFailure = $true
    sourceControlProjectionUnchanged = $true
  }
}
$checkoutInvalidUrlFailureUrlPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Checkout SVN repository", "Enter the SVN repository URL to checkout.")
  requiredAccessibilityTokens = @("Checkout SVN repository", "Enter the SVN repository URL to checkout.")
  requiredScreenshot = $true
  inputText = $checkoutInvalidUrlFailureRepositoryUrl
  submitKey = "Enter"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutInvalidUrlFailureUrlPromptReady"
  command = "subversionr.checkoutRepository"
  request = [pscustomobject]@{
    url = $checkoutInvalidUrlFailureRepositoryUrl
    targetPath = $checkoutInvalidUrlFailureTargetWorkingCopyRoot
    revision = "head"
    depth = "infinity"
    ignoreExternals = $true
  }
  prompt = [pscustomobject]@{
    kind = "url"
    rendererCaptureExpectations = $checkoutInvalidUrlFailureUrlPromptExpectations
  }
  rendererCaptureExpectations = $checkoutInvalidUrlFailureUrlPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutInvalidUrlFailureUrlPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutInvalidUrlFailureUrlPromptDonePath -Description "checkout invalid URL failure URL"
$checkoutInvalidUrlFailureTargetPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN checkout target folder", "Enter the absolute local folder path for the checkout.")
  requiredAccessibilityTokens = @("SVN checkout target folder", "Enter the absolute local folder path for the checkout.")
  requiredScreenshot = $true
  inputText = $checkoutInvalidUrlFailureTargetWorkingCopyRoot
  submitKey = "Enter"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutInvalidUrlFailureTargetPromptReady"
  command = "subversionr.checkoutRepository"
  rendererCaptureExpectations = $checkoutInvalidUrlFailureTargetPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutInvalidUrlFailureTargetPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutInvalidUrlFailureTargetPromptDonePath -Description "checkout invalid URL failure target"
$checkoutInvalidUrlFailureRevisionPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN checkout revision", "HEAD", "Revision number")
  requiredAccessibilityTokens = @("SVN checkout revision", "HEAD", "Revision number")
  requiredScreenshot = $true
  quickPickItemText = "HEAD"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutInvalidUrlFailureRevisionPromptReady"
  command = "subversionr.checkoutRepository"
  rendererCaptureExpectations = $checkoutInvalidUrlFailureRevisionPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutInvalidUrlFailureRevisionPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutInvalidUrlFailureRevisionPromptDonePath -Description "checkout invalid URL failure revision"
$checkoutInvalidUrlFailureDepthPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN checkout depth", "Empty", "Files", "Immediates", "Infinity")
  requiredAccessibilityTokens = @("SVN checkout depth", "Empty", "Files", "Immediates", "Infinity")
  requiredScreenshot = $true
  quickPickItemText = "Infinity"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutInvalidUrlFailureDepthPromptReady"
  command = "subversionr.checkoutRepository"
  rendererCaptureExpectations = $checkoutInvalidUrlFailureDepthPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutInvalidUrlFailureDepthPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutInvalidUrlFailureDepthPromptDonePath -Description "checkout invalid URL failure depth"
$checkoutInvalidUrlFailureExternalsPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN checkout externals", "Ignore externals", "Include externals")
  requiredAccessibilityTokens = @("SVN checkout externals", "Ignore externals", "Include externals")
  requiredScreenshot = $true
  quickPickItemText = "Ignore externals"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutInvalidUrlFailureExternalsPromptReady"
  command = "subversionr.checkoutRepository"
  rendererCaptureExpectations = $checkoutInvalidUrlFailureExternalsPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutInvalidUrlFailureExternalsPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutInvalidUrlFailureExternalsPromptDonePath -Description "checkout invalid URL failure externals"
if (Test-Path -LiteralPath $checkoutInvalidUrlFailureTargetWorkingCopyRoot) {
  throw "fake installed Checkout invalid URL failure target path must not exist before failure."
}
$checkoutInvalidUrlFailureParentPath = Split-Path -Parent $checkoutInvalidUrlFailureTargetWorkingCopyRoot
New-Item -ItemType Directory -Force -Path $checkoutInvalidUrlFailureParentPath | Out-Null
$checkoutInvalidUrlFailureParentEntriesBefore = Get-FakeDirectoryEntries -Path $checkoutInvalidUrlFailureParentPath
$checkoutInvalidUrlFailureNotificationExpectations = [pscustomobject]@{
  requiredDomTokens = @("SubversionR repository command failed", "SUBVERSIONR_REPOSITORY_COMMAND_FAILED")
  requiredAccessibilityTokens = @("SubversionR repository command failed", "SUBVERSIONR_REPOSITORY_COMMAND_FAILED")
  requiredScreenshot = $true
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutInvalidUrlFailureNotificationReady"
  command = "subversionr.checkoutRepository"
  request = [pscustomobject]@{
    url = $checkoutInvalidUrlFailureRepositoryUrl
    targetPath = $checkoutInvalidUrlFailureTargetWorkingCopyRoot
    revision = "head"
    depth = "infinity"
    ignoreExternals = $true
  }
  failure = [pscustomobject]@{
    code = "SVN_REPOSITORY_CHECKOUT_FAILED"
    category = "native"
    notificationText = "SubversionR repository command failed: SUBVERSIONR_REPOSITORY_COMMAND_FAILED"
  }
  notification = [pscustomobject]@{
    rendererCaptureExpectations = $checkoutInvalidUrlFailureNotificationExpectations
    cleanup = [pscustomobject]@{
      command = "notifications.clearAll"
      label = "checkoutInvalidUrlFailureNotification"
      cleared = $true
    }
  }
  rendererCaptureExpectations = $checkoutInvalidUrlFailureNotificationExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutInvalidUrlFailureNotificationReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutInvalidUrlFailureNotificationDonePath -Description "checkout invalid URL failure notification"
$checkoutInvalidUrlFailureParentEntriesAfter = Get-FakeDirectoryEntries -Path $checkoutInvalidUrlFailureParentPath
$checkoutInvalidUrlFailureBaselineBeforeProbe = New-FakeMissingCurrentSurfaceProbe -Path $workingCopyRoot
$checkoutInvalidUrlFailureBaselineAfterProbe = New-FakeMissingCurrentSurfaceProbe -Path $workingCopyRoot
$checkoutInvalidUrlFailureTargetBeforeProbe = New-FakeMissingCurrentSurfaceProbe -Path $checkoutInvalidUrlFailureTargetWorkingCopyRoot
$checkoutInvalidUrlFailureTargetAfterProbe = New-FakeMissingCurrentSurfaceProbe -Path $checkoutInvalidUrlFailureTargetWorkingCopyRoot
$checkoutInvalidUrlFailureReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCheckoutInvalidUrlFailureWorkflow"
  generatedAt = "2026-06-25T00:00:11Z"
  command = [pscustomobject]@{
    command = "subversionr.checkoutRepository"
  }
  request = [pscustomobject]@{
    url = $checkoutInvalidUrlFailureRepositoryUrl
    targetPath = $checkoutInvalidUrlFailureTargetWorkingCopyRoot
    revision = "head"
    depth = "infinity"
    ignoreExternals = $true
  }
  prompts = [pscustomobject]@{
    url = [pscustomobject]@{ rendererCaptureExpectations = $checkoutInvalidUrlFailureUrlPromptExpectations }
    targetPath = [pscustomobject]@{ rendererCaptureExpectations = $checkoutInvalidUrlFailureTargetPromptExpectations }
    revision = [pscustomobject]@{ selected = "HEAD"; rendererCaptureExpectations = $checkoutInvalidUrlFailureRevisionPromptExpectations }
    depth = [pscustomobject]@{ selected = "Infinity"; rendererCaptureExpectations = $checkoutInvalidUrlFailureDepthPromptExpectations }
    externals = [pscustomobject]@{ selected = "Ignore externals"; rendererCaptureExpectations = $checkoutInvalidUrlFailureExternalsPromptExpectations }
  }
  failure = [pscustomobject]@{
    code = "SVN_REPOSITORY_CHECKOUT_FAILED"
    category = "native"
    notificationText = "SubversionR repository command failed: SUBVERSIONR_REPOSITORY_COMMAND_FAILED"
  }
  notification = [pscustomobject]@{
    rendererCaptureExpectations = $checkoutInvalidUrlFailureNotificationExpectations
    cleanup = [pscustomobject]@{
      command = "notifications.clearAll"
      label = "checkoutInvalidUrlFailureNotification"
      cleared = $true
    }
  }
  target = [pscustomobject]@{
    workingCopyRoot = $checkoutInvalidUrlFailureTargetWorkingCopyRoot
    parentDirectoryPath = $checkoutInvalidUrlFailureParentPath
    svnMetadataPath = Join-Path $checkoutInvalidUrlFailureTargetWorkingCopyRoot ".svn"
    parentSvnMetadataPath = Join-Path $checkoutInvalidUrlFailureParentPath ".svn"
    parentDirectoryEntriesBefore = $checkoutInvalidUrlFailureParentEntriesBefore
    parentDirectoryEntriesAfter = $checkoutInvalidUrlFailureParentEntriesAfter
  }
  currentSurfaceProbes = [pscustomobject]@{
    baselineBefore = $checkoutInvalidUrlFailureBaselineBeforeProbe
    baselineAfter = $checkoutInvalidUrlFailureBaselineAfterProbe
    targetBefore = $checkoutInvalidUrlFailureTargetBeforeProbe
    targetAfter = $checkoutInvalidUrlFailureTargetAfterProbe
  }
  assertions = [pscustomobject]@{
    commandFailed = $true
    invalidUrlRejected = $true
    targetAbsentAfter = -not (Test-Path -LiteralPath $checkoutInvalidUrlFailureTargetWorkingCopyRoot)
    svnMetadataAbsentAfter = (-not (Test-Path -LiteralPath (Join-Path $checkoutInvalidUrlFailureTargetWorkingCopyRoot ".svn"))) -and (-not (Test-Path -LiteralPath (Join-Path $checkoutInvalidUrlFailureParentPath ".svn")))
    parentDirectoryUnchanged = ($checkoutInvalidUrlFailureParentEntriesBefore | ConvertTo-Json -Depth 4 -Compress) -eq ($checkoutInvalidUrlFailureParentEntriesAfter | ConvertTo-Json -Depth 4 -Compress)
    repositoryNotOpenedAfterFailure = $true
    sourceControlProjectionUnchanged = $true
  }
}
$checkoutExistingDirectoryLocalOnlyFileName = "local-only-before-checkout.txt"
$checkoutExistingDirectoryLocalOnlyPath = Join-Path $checkoutExistingDirectoryTargetWorkingCopyRoot $checkoutExistingDirectoryLocalOnlyFileName
$checkoutExistingDirectorySvnMetadataPath = Join-Path $checkoutExistingDirectoryTargetWorkingCopyRoot ".svn"
if (-not (Test-Path -LiteralPath $checkoutExistingDirectoryTargetWorkingCopyRoot -PathType Container)) {
  throw "fake installed Checkout existing-directory target must exist before checkout."
}
if (Test-Path -LiteralPath $checkoutExistingDirectorySvnMetadataPath) {
  throw "fake installed Checkout existing-directory target must not contain SVN metadata before checkout."
}
if (-not (Test-Path -LiteralPath $checkoutExistingDirectoryLocalOnlyPath -PathType Leaf)) {
  throw "fake installed Checkout existing-directory target must contain the local-only marker before checkout."
}
$checkoutExistingDirectoryHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $checkoutExistingDirectoryLocalOnlyPath).Hash.ToLowerInvariant()
$checkoutExistingDirectoryEntriesBefore = Get-FakeDirectoryEntries -Path $checkoutExistingDirectoryTargetWorkingCopyRoot
$checkoutExistingDirectoryUrlPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Checkout SVN repository", "Enter the SVN repository URL to checkout.")
  requiredAccessibilityTokens = @("Checkout SVN repository", "Enter the SVN repository URL to checkout.")
  requiredScreenshot = $true
  inputText = $checkoutRepositoryUrl
  submitKey = "Enter"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutExistingDirectoryUrlPromptReady"
  command = "subversionr.checkoutRepository"
  request = [pscustomobject]@{
    url = $checkoutRepositoryUrl
    targetPath = $checkoutExistingDirectoryTargetWorkingCopyRoot
    revision = "head"
    depth = "infinity"
    ignoreExternals = $true
  }
  prompt = [pscustomobject]@{
    kind = "url"
    rendererCaptureExpectations = $checkoutExistingDirectoryUrlPromptExpectations
  }
  rendererCaptureExpectations = $checkoutExistingDirectoryUrlPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutExistingDirectoryUrlPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutExistingDirectoryUrlPromptDonePath -Description "checkout existing-directory URL"
$checkoutExistingDirectoryTargetPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN checkout target folder", "Enter the absolute local folder path for the checkout.")
  requiredAccessibilityTokens = @("SVN checkout target folder", "Enter the absolute local folder path for the checkout.")
  requiredScreenshot = $true
  inputText = $checkoutExistingDirectoryTargetWorkingCopyRoot
  submitKey = "Enter"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutExistingDirectoryTargetPromptReady"
  command = "subversionr.checkoutRepository"
  rendererCaptureExpectations = $checkoutExistingDirectoryTargetPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutExistingDirectoryTargetPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutExistingDirectoryTargetPromptDonePath -Description "checkout existing-directory target"
$checkoutExistingDirectoryRevisionPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN checkout revision", "HEAD", "Revision number")
  requiredAccessibilityTokens = @("SVN checkout revision", "HEAD", "Revision number")
  requiredScreenshot = $true
  quickPickItemText = "HEAD"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutExistingDirectoryRevisionPromptReady"
  command = "subversionr.checkoutRepository"
  rendererCaptureExpectations = $checkoutExistingDirectoryRevisionPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutExistingDirectoryRevisionPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutExistingDirectoryRevisionPromptDonePath -Description "checkout existing-directory revision"
$checkoutExistingDirectoryDepthPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN checkout depth", "Empty", "Files", "Immediates", "Infinity")
  requiredAccessibilityTokens = @("SVN checkout depth", "Empty", "Files", "Immediates", "Infinity")
  requiredScreenshot = $true
  quickPickItemText = "Infinity"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutExistingDirectoryDepthPromptReady"
  command = "subversionr.checkoutRepository"
  rendererCaptureExpectations = $checkoutExistingDirectoryDepthPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutExistingDirectoryDepthPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutExistingDirectoryDepthPromptDonePath -Description "checkout existing-directory depth"
$checkoutExistingDirectoryExternalsPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN checkout externals", "Ignore externals", "Include externals")
  requiredAccessibilityTokens = @("SVN checkout externals", "Ignore externals", "Include externals")
  requiredScreenshot = $true
  quickPickItemText = "Ignore externals"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutExistingDirectoryExternalsPromptReady"
  command = "subversionr.checkoutRepository"
  rendererCaptureExpectations = $checkoutExistingDirectoryExternalsPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutExistingDirectoryExternalsPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutExistingDirectoryExternalsPromptDonePath -Description "checkout existing-directory externals"
$checkoutExistingDirectoryTrackedPath = Join-Path $checkoutExistingDirectoryTargetWorkingCopyRoot "src\tracked.txt"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $checkoutExistingDirectoryTrackedPath), $checkoutExistingDirectorySvnMetadataPath | Out-Null
Set-Content -LiteralPath $checkoutExistingDirectoryTrackedPath -Value "initial`n" -NoNewline -Encoding utf8
Set-Content -LiteralPath (Join-Path $checkoutExistingDirectorySvnMetadataPath "wc.db") -Value "SubversionR fake checkout existing-directory wc metadata`n" -NoNewline -Encoding utf8
$checkoutExistingDirectoryHashAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $checkoutExistingDirectoryLocalOnlyPath).Hash.ToLowerInvariant()
$checkoutExistingDirectoryEntriesAfter = Get-FakeDirectoryEntries -Path $checkoutExistingDirectoryTargetWorkingCopyRoot
$checkoutExistingDirectoryLocalOnlyResource = [pscustomobject]@{
  path = $checkoutExistingDirectoryLocalOnlyFileName
  contextValue = "subversionr.unversioned"
  kind = "file"
  generation = 1
}
$checkoutExistingDirectoryCurrentSurfaceReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCurrentSurfaceReport"
  generatedAt = "2026-06-25T00:00:11Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$checkoutExistingDirectoryTargetWorkingCopyRoot"
    epoch = 11
    identity = [pscustomobject]@{
      repositoryUuid = "fixture-checkout-existing-directory-repository-uuid"
      repositoryRootUrl = $checkoutRepositoryUrl
      workingCopyRoot = $checkoutExistingDirectoryTargetWorkingCopyRoot
      workspaceScopeRoot = $checkoutExistingDirectoryTargetWorkingCopyRoot
      format = 31
    }
  }
  openRequest = [pscustomobject]@{
    path = $checkoutExistingDirectoryTargetWorkingCopyRoot
    relationToWorkingCopyRoot = "workingCopyRoot"
  }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$checkoutExistingDirectoryTargetWorkingCopyRoot"
    epoch = 11
    workingCopyRoot = $checkoutExistingDirectoryTargetWorkingCopyRoot
    generation = 1
    count = 1
    inputBox = $openReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{
        id = "unversioned"
        contextValue = "subversionr.unversioned"
        hideWhenEmpty = $true
        count = 1
        resources = @($checkoutExistingDirectoryLocalOnlyResource)
      }
    )
  }
  surfaceWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    scmProjection = $true
    sourceControlSurface = $true
    repositoryClosed = $false
  }
}
$checkoutExistingDirectoryCloseReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCloseReport"
  generatedAt = "2026-06-25T00:00:11Z"
  repositoryId = $checkoutExistingDirectoryCurrentSurfaceReport.repository.repositoryId
  epoch = $checkoutExistingDirectoryCurrentSurfaceReport.repository.epoch
  repositoryClosed = $true
}
$checkoutExistingDirectoryReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCheckoutExistingDirectoryWorkflow"
  generatedAt = "2026-06-25T00:00:11Z"
  command = [pscustomobject]@{
    command = "subversionr.checkoutRepository"
  }
  request = [pscustomobject]@{
    url = $checkoutRepositoryUrl
    targetPath = $checkoutExistingDirectoryTargetWorkingCopyRoot
    revision = "head"
    depth = "infinity"
    ignoreExternals = $true
  }
  prompts = [pscustomobject]@{
    url = [pscustomobject]@{ rendererCaptureExpectations = $checkoutExistingDirectoryUrlPromptExpectations }
    targetPath = [pscustomobject]@{ rendererCaptureExpectations = $checkoutExistingDirectoryTargetPromptExpectations }
    revision = [pscustomobject]@{ selected = "HEAD"; rendererCaptureExpectations = $checkoutExistingDirectoryRevisionPromptExpectations }
    depth = [pscustomobject]@{ selected = "Infinity"; rendererCaptureExpectations = $checkoutExistingDirectoryDepthPromptExpectations }
    externals = [pscustomobject]@{ selected = "Ignore externals"; rendererCaptureExpectations = $checkoutExistingDirectoryExternalsPromptExpectations }
  }
  target = [pscustomobject]@{
    workingCopyRoot = $checkoutExistingDirectoryTargetWorkingCopyRoot
    trackedPath = $checkoutExistingDirectoryTrackedPath
    svnMetadataPath = $checkoutExistingDirectorySvnMetadataPath
    localOnlyPath = $checkoutExistingDirectoryLocalOnlyPath
    localOnlyFileName = $checkoutExistingDirectoryLocalOnlyFileName
    localOnlyHashBefore = $checkoutExistingDirectoryHashBefore
    localOnlyHashAfter = $checkoutExistingDirectoryHashAfter
    directoryEntriesBefore = $checkoutExistingDirectoryEntriesBefore
    directoryEntriesAfter = $checkoutExistingDirectoryEntriesAfter
  }
  localOnlyResource = $checkoutExistingDirectoryLocalOnlyResource
  currentSurfaceReport = $checkoutExistingDirectoryCurrentSurfaceReport
  closeReport = $checkoutExistingDirectoryCloseReport
  assertions = [pscustomobject]@{
    commandExecuted = $true
    targetDirectoryExistedBefore = $true
    targetDirectoryNonEmptyBefore = $checkoutExistingDirectoryEntriesBefore.Count -gt 0
    existingDirectoryTargetAccepted = [bool](@($checkoutExistingDirectoryEntriesBefore | Where-Object { $_.name -eq $checkoutExistingDirectoryLocalOnlyFileName -and $_.kind -eq "file" }).Count -gt 0)
    workingCopyCreated = (Test-Path -LiteralPath $checkoutExistingDirectoryTrackedPath -PathType Leaf) -and (Test-Path -LiteralPath $checkoutExistingDirectorySvnMetadataPath -PathType Container)
    localDirectoryEntryPreserved = (Test-Path -LiteralPath $checkoutExistingDirectoryLocalOnlyPath -PathType Leaf) -and $checkoutExistingDirectoryHashAfter -eq $checkoutExistingDirectoryHashBefore -and [bool](@($checkoutExistingDirectoryEntriesAfter | Where-Object { $_.name -eq $checkoutExistingDirectoryLocalOnlyFileName -and $_.kind -eq "file" }).Count -gt 0)
    repositoryOpenedAfterCheckout = $true
    sourceControlProjectionAvailable = $true
    localOnlyFileProjectedUnversioned = $true
    repositoryClosedAfterEvidence = $true
  }
}
$checkoutExistingDirectoryObstructionLocalOnlyFileName = "local-only-before-checkout.txt"
$checkoutExistingDirectoryObstructionLocalOnlyPath = Join-Path $checkoutExistingDirectoryObstructionTargetWorkingCopyRoot $checkoutExistingDirectoryObstructionLocalOnlyFileName
$checkoutExistingDirectoryObstructionPath = Join-Path $checkoutExistingDirectoryObstructionTargetWorkingCopyRoot "src"
$checkoutExistingDirectoryObstructionBlockedTrackedPath = Join-Path $checkoutExistingDirectoryObstructionTargetWorkingCopyRoot "src\tracked.txt"
$checkoutExistingDirectoryObstructionSvnMetadataPath = Join-Path $checkoutExistingDirectoryObstructionTargetWorkingCopyRoot ".svn"
if (-not (Test-Path -LiteralPath $checkoutExistingDirectoryObstructionTargetWorkingCopyRoot -PathType Container)) {
  throw "fake installed Checkout existing-directory obstruction target must exist before checkout."
}
if (Test-Path -LiteralPath $checkoutExistingDirectoryObstructionSvnMetadataPath) {
  throw "fake installed Checkout existing-directory obstruction target must not contain SVN metadata before checkout."
}
if (-not (Test-Path -LiteralPath $checkoutExistingDirectoryObstructionLocalOnlyPath -PathType Leaf)) {
  throw "fake installed Checkout existing-directory obstruction target must contain the local-only marker before checkout."
}
if (-not (Test-Path -LiteralPath $checkoutExistingDirectoryObstructionPath -PathType Leaf)) {
  throw "fake installed Checkout existing-directory obstruction target must contain the obstructing src file before checkout."
}
$checkoutExistingDirectoryObstructionHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $checkoutExistingDirectoryObstructionPath).Hash.ToLowerInvariant()
$checkoutExistingDirectoryObstructionEntriesBefore = Get-FakeDirectoryEntries -Path $checkoutExistingDirectoryObstructionTargetWorkingCopyRoot
$checkoutExistingDirectoryObstructionUrlPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Checkout SVN repository", "Enter the SVN repository URL to checkout.")
  requiredAccessibilityTokens = @("Checkout SVN repository", "Enter the SVN repository URL to checkout.")
  requiredScreenshot = $true
  inputText = $checkoutRepositoryUrl
  submitKey = "Enter"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutExistingDirectoryObstructionUrlPromptReady"
  command = "subversionr.checkoutRepository"
  request = [pscustomobject]@{
    url = $checkoutRepositoryUrl
    targetPath = $checkoutExistingDirectoryObstructionTargetWorkingCopyRoot
    revision = "head"
    depth = "infinity"
    ignoreExternals = $true
  }
  prompt = [pscustomobject]@{
    kind = "url"
    rendererCaptureExpectations = $checkoutExistingDirectoryObstructionUrlPromptExpectations
  }
  rendererCaptureExpectations = $checkoutExistingDirectoryObstructionUrlPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutExistingDirectoryObstructionUrlPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutExistingDirectoryObstructionUrlPromptDonePath -Description "checkout existing-directory obstruction URL"
$checkoutExistingDirectoryObstructionTargetPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN checkout target folder", "Enter the absolute local folder path for the checkout.")
  requiredAccessibilityTokens = @("SVN checkout target folder", "Enter the absolute local folder path for the checkout.")
  requiredScreenshot = $true
  inputText = $checkoutExistingDirectoryObstructionTargetWorkingCopyRoot
  submitKey = "Enter"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutExistingDirectoryObstructionTargetPromptReady"
  command = "subversionr.checkoutRepository"
  rendererCaptureExpectations = $checkoutExistingDirectoryObstructionTargetPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutExistingDirectoryObstructionTargetPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutExistingDirectoryObstructionTargetPromptDonePath -Description "checkout existing-directory obstruction target"
$checkoutExistingDirectoryObstructionRevisionPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN checkout revision", "HEAD", "Revision number")
  requiredAccessibilityTokens = @("SVN checkout revision", "HEAD", "Revision number")
  requiredScreenshot = $true
  quickPickItemText = "HEAD"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutExistingDirectoryObstructionRevisionPromptReady"
  command = "subversionr.checkoutRepository"
  rendererCaptureExpectations = $checkoutExistingDirectoryObstructionRevisionPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutExistingDirectoryObstructionRevisionPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutExistingDirectoryObstructionRevisionPromptDonePath -Description "checkout existing-directory obstruction revision"
$checkoutExistingDirectoryObstructionDepthPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN checkout depth", "Empty", "Files", "Immediates", "Infinity")
  requiredAccessibilityTokens = @("SVN checkout depth", "Empty", "Files", "Immediates", "Infinity")
  requiredScreenshot = $true
  quickPickItemText = "Infinity"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutExistingDirectoryObstructionDepthPromptReady"
  command = "subversionr.checkoutRepository"
  rendererCaptureExpectations = $checkoutExistingDirectoryObstructionDepthPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutExistingDirectoryObstructionDepthPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutExistingDirectoryObstructionDepthPromptDonePath -Description "checkout existing-directory obstruction depth"
$checkoutExistingDirectoryObstructionExternalsPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN checkout externals", "Ignore externals", "Include externals")
  requiredAccessibilityTokens = @("SVN checkout externals", "Ignore externals", "Include externals")
  requiredScreenshot = $true
  quickPickItemText = "Ignore externals"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutExistingDirectoryObstructionExternalsPromptReady"
  command = "subversionr.checkoutRepository"
  rendererCaptureExpectations = $checkoutExistingDirectoryObstructionExternalsPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutExistingDirectoryObstructionExternalsPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutExistingDirectoryObstructionExternalsPromptDonePath -Description "checkout existing-directory obstruction externals"
New-Item -ItemType Directory -Force -Path $checkoutExistingDirectoryObstructionSvnMetadataPath | Out-Null
Set-Content -LiteralPath (Join-Path $checkoutExistingDirectoryObstructionSvnMetadataPath "wc.db") -Value "SubversionR fake checkout existing-directory obstruction wc metadata`n" -NoNewline -Encoding utf8
$checkoutExistingDirectoryObstructionHashAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $checkoutExistingDirectoryObstructionPath).Hash.ToLowerInvariant()
$checkoutExistingDirectoryObstructionEntriesAfter = Get-FakeDirectoryEntries -Path $checkoutExistingDirectoryObstructionTargetWorkingCopyRoot
$checkoutExistingDirectoryObstructionConflictResource = [pscustomobject]@{
  path = "src"
  contextValue = "subversionr.conflicted"
  kind = "file"
  localStatus = "conflicted"
  nodeStatus = "conflicted"
  textStatus = "normal"
  propertyStatus = "normal"
  conflict = "tree"
  generation = 1
}
$checkoutExistingDirectoryObstructionLocalOnlyResource = [pscustomobject]@{
  path = $checkoutExistingDirectoryObstructionLocalOnlyFileName
  contextValue = "subversionr.unversioned"
  kind = "file"
  generation = 1
}
$checkoutExistingDirectoryObstructionCurrentSurfaceReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCurrentSurfaceReport"
  generatedAt = "2026-06-25T00:00:12Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$checkoutExistingDirectoryObstructionTargetWorkingCopyRoot"
    epoch = 12
    identity = [pscustomobject]@{
      repositoryUuid = "fixture-checkout-existing-directory-obstruction-repository-uuid"
      repositoryRootUrl = $checkoutRepositoryUrl
      workingCopyRoot = $checkoutExistingDirectoryObstructionTargetWorkingCopyRoot
      workspaceScopeRoot = $checkoutExistingDirectoryObstructionTargetWorkingCopyRoot
      format = 31
    }
  }
  openRequest = [pscustomobject]@{
    path = $checkoutExistingDirectoryObstructionTargetWorkingCopyRoot
    relationToWorkingCopyRoot = "workingCopyRoot"
  }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$checkoutExistingDirectoryObstructionTargetWorkingCopyRoot"
    epoch = 12
    workingCopyRoot = $checkoutExistingDirectoryObstructionTargetWorkingCopyRoot
    generation = 1
    count = 1
    inputBox = $openReport.sourceControl.inputBox
    groups = @(
      [pscustomobject]@{
        id = "conflicts"
        contextValue = "subversionr.conflicts"
        hideWhenEmpty = $true
        count = 1
        resources = @($checkoutExistingDirectoryObstructionConflictResource)
      },
      [pscustomobject]@{
        id = "unversioned"
        contextValue = "subversionr.unversioned"
        hideWhenEmpty = $true
        count = 1
        resources = @($checkoutExistingDirectoryObstructionLocalOnlyResource)
      }
    )
  }
  surfaceWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    scmProjection = $true
    sourceControlSurface = $true
    repositoryClosed = $false
  }
}
$checkoutExistingDirectoryObstructionCloseReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCloseReport"
  generatedAt = "2026-06-25T00:00:12Z"
  repositoryId = $checkoutExistingDirectoryObstructionCurrentSurfaceReport.repository.repositoryId
  epoch = $checkoutExistingDirectoryObstructionCurrentSurfaceReport.repository.epoch
  repositoryClosed = $true
}
$checkoutExistingDirectoryObstructionReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCheckoutExistingDirectoryObstructionWorkflow"
  generatedAt = "2026-06-25T00:00:12Z"
  command = [pscustomobject]@{
    command = "subversionr.checkoutRepository"
  }
  request = [pscustomobject]@{
    url = $checkoutRepositoryUrl
    targetPath = $checkoutExistingDirectoryObstructionTargetWorkingCopyRoot
    revision = "head"
    depth = "infinity"
    ignoreExternals = $true
  }
  prompts = [pscustomobject]@{
    url = [pscustomobject]@{ rendererCaptureExpectations = $checkoutExistingDirectoryObstructionUrlPromptExpectations }
    targetPath = [pscustomobject]@{ rendererCaptureExpectations = $checkoutExistingDirectoryObstructionTargetPromptExpectations }
    revision = [pscustomobject]@{ selected = "HEAD"; rendererCaptureExpectations = $checkoutExistingDirectoryObstructionRevisionPromptExpectations }
    depth = [pscustomobject]@{ selected = "Infinity"; rendererCaptureExpectations = $checkoutExistingDirectoryObstructionDepthPromptExpectations }
    externals = [pscustomobject]@{ selected = "Ignore externals"; rendererCaptureExpectations = $checkoutExistingDirectoryObstructionExternalsPromptExpectations }
  }
  target = [pscustomobject]@{
    workingCopyRoot = $checkoutExistingDirectoryObstructionTargetWorkingCopyRoot
    svnMetadataPath = $checkoutExistingDirectoryObstructionSvnMetadataPath
    obstructionPath = $checkoutExistingDirectoryObstructionPath
    obstructionHashBefore = $checkoutExistingDirectoryObstructionHashBefore
    obstructionHashAfter = $checkoutExistingDirectoryObstructionHashAfter
    blockedIncomingTrackedPath = $checkoutExistingDirectoryObstructionBlockedTrackedPath
    conflictPath = "src"
    localOnlyPath = $checkoutExistingDirectoryObstructionLocalOnlyPath
    localOnlyFileName = $checkoutExistingDirectoryObstructionLocalOnlyFileName
    directoryEntriesBefore = $checkoutExistingDirectoryObstructionEntriesBefore
    directoryEntriesAfter = $checkoutExistingDirectoryObstructionEntriesAfter
  }
  conflictResource = $checkoutExistingDirectoryObstructionConflictResource
  localOnlyResource = $checkoutExistingDirectoryObstructionLocalOnlyResource
  currentSurfaceReport = $checkoutExistingDirectoryObstructionCurrentSurfaceReport
  closeReport = $checkoutExistingDirectoryObstructionCloseReport
  assertions = [pscustomobject]@{
    commandExecuted = $true
    targetDirectoryExistedBefore = $true
    targetDirectoryNonEmptyBefore = $checkoutExistingDirectoryObstructionEntriesBefore.Count -gt 0
    obstructingFileExistedBefore = $true
    workingCopyCreated = Test-Path -LiteralPath $checkoutExistingDirectoryObstructionSvnMetadataPath -PathType Container
    obstructionPreserved = (Test-Path -LiteralPath $checkoutExistingDirectoryObstructionPath -PathType Leaf) -and $checkoutExistingDirectoryObstructionHashAfter -eq $checkoutExistingDirectoryObstructionHashBefore
    blockedIncomingTrackedPathAbsent = -not (Test-Path -LiteralPath $checkoutExistingDirectoryObstructionBlockedTrackedPath -PathType Leaf)
    localDirectoryEntryPreserved = Test-Path -LiteralPath $checkoutExistingDirectoryObstructionLocalOnlyPath -PathType Leaf
    repositoryOpenedAfterCheckout = $true
    sourceControlProjectionAvailable = $true
    treeConflictProjected = $true
    localOnlyFileProjectedUnversioned = $true
    repositoryClosedAfterEvidence = $true
  }
}
$checkoutUrlPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Checkout SVN repository", "Enter the SVN repository URL to checkout.")
  requiredAccessibilityTokens = @("Checkout SVN repository", "Enter the SVN repository URL to checkout.")
  requiredScreenshot = $true
  inputText = $checkoutRepositoryUrl
  submitKey = "Enter"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutUrlPromptReady"
  command = "subversionr.checkoutRepository"
  request = [pscustomobject]@{
    url = $checkoutRepositoryUrl
    targetPath = $checkoutTargetWorkingCopyRoot
    revision = "head"
    depth = "infinity"
    ignoreExternals = $true
  }
  prompt = [pscustomobject]@{
    kind = "url"
    rendererCaptureExpectations = $checkoutUrlPromptExpectations
  }
  rendererCaptureExpectations = $checkoutUrlPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutUrlPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutUrlPromptDonePath -Description "checkout URL"
$checkoutTargetPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN checkout target folder", "Enter the absolute local folder path for the checkout.")
  requiredAccessibilityTokens = @("SVN checkout target folder", "Enter the absolute local folder path for the checkout.")
  requiredScreenshot = $true
  inputText = $checkoutTargetWorkingCopyRoot
  submitKey = "Enter"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutTargetPromptReady"
  command = "subversionr.checkoutRepository"
  rendererCaptureExpectations = $checkoutTargetPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutTargetPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutTargetPromptDonePath -Description "checkout target"
$checkoutRevisionPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN checkout revision", "HEAD", "Revision number")
  requiredAccessibilityTokens = @("SVN checkout revision", "HEAD", "Revision number")
  requiredScreenshot = $true
  quickPickItemText = "HEAD"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutRevisionPromptReady"
  command = "subversionr.checkoutRepository"
  rendererCaptureExpectations = $checkoutRevisionPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutRevisionPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutRevisionPromptDonePath -Description "checkout revision"
$checkoutDepthPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN checkout depth", "Empty", "Files", "Immediates", "Infinity")
  requiredAccessibilityTokens = @("SVN checkout depth", "Empty", "Files", "Immediates", "Infinity")
  requiredScreenshot = $true
  quickPickItemText = "Infinity"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutDepthPromptReady"
  command = "subversionr.checkoutRepository"
  rendererCaptureExpectations = $checkoutDepthPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutDepthPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutDepthPromptDonePath -Description "checkout depth"
$checkoutExternalsPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN checkout externals", "Ignore externals", "Include externals")
  requiredAccessibilityTokens = @("SVN checkout externals", "Ignore externals", "Include externals")
  requiredScreenshot = $true
  quickPickItemText = "Ignore externals"
}
[pscustomobject]@{
  ok = $true
  phase = "checkoutExternalsPromptReady"
  command = "subversionr.checkoutRepository"
  rendererCaptureExpectations = $checkoutExternalsPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $checkoutExternalsPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $checkoutExternalsPromptDonePath -Description "checkout externals"
New-Item -ItemType Directory -Force -Path (Join-Path $checkoutTargetWorkingCopyRoot "src"), (Join-Path $checkoutTargetWorkingCopyRoot ".svn") | Out-Null
Set-Content -LiteralPath (Join-Path $checkoutTargetWorkingCopyRoot "src\tracked.txt") -Value "initial`n" -NoNewline -Encoding utf8
Set-Content -LiteralPath (Join-Path $checkoutTargetWorkingCopyRoot ".svn\wc.db") -Value "SubversionR fake checkout wc metadata`n" -NoNewline -Encoding utf8
$checkoutCurrentSurfaceReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCurrentSurfaceReport"
  generatedAt = "2026-06-25T00:00:11Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$checkoutTargetWorkingCopyRoot"
    epoch = 11
    identity = [pscustomobject]@{
      repositoryUuid = "fixture-checkout-repository-uuid"
      repositoryRootUrl = $checkoutRepositoryUrl
      workingCopyRoot = $checkoutTargetWorkingCopyRoot
      workspaceScopeRoot = $checkoutTargetWorkingCopyRoot
      format = 31
    }
  }
  openRequest = [pscustomobject]@{
    path = $checkoutTargetWorkingCopyRoot
    relationToWorkingCopyRoot = "workingCopyRoot"
  }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$checkoutTargetWorkingCopyRoot"
    epoch = 11
    workingCopyRoot = $checkoutTargetWorkingCopyRoot
    generation = 1
    count = 0
    inputBox = [pscustomobject]@{
      placeholder = "SVN commit message"
      acceptInputCommand = "subversionr.commitAll"
      acceptInputCommandArguments = @("repo-uuid:$checkoutTargetWorkingCopyRoot")
    }
    groups = @()
  }
  surfaceWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    scmProjection = $true
    sourceControlSurface = $true
    repositoryClosed = $false
  }
}
$checkoutCloseReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCloseReport"
  generatedAt = "2026-06-25T00:00:11Z"
  repositoryId = $checkoutCurrentSurfaceReport.repository.repositoryId
  epoch = $checkoutCurrentSurfaceReport.repository.epoch
  repositoryClosed = $true
}
$checkoutReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCheckoutWorkflow"
  generatedAt = "2026-06-25T00:00:11Z"
  command = [pscustomobject]@{
    command = "subversionr.checkoutRepository"
  }
  request = [pscustomobject]@{
    url = $checkoutRepositoryUrl
    targetPath = $checkoutTargetWorkingCopyRoot
    revision = "head"
    depth = "infinity"
    ignoreExternals = $true
  }
  prompts = [pscustomobject]@{
    url = [pscustomobject]@{
      rendererCaptureExpectations = $checkoutUrlPromptExpectations
    }
    targetPath = [pscustomobject]@{
      rendererCaptureExpectations = $checkoutTargetPromptExpectations
    }
    revision = [pscustomobject]@{
      selected = "HEAD"
      rendererCaptureExpectations = $checkoutRevisionPromptExpectations
    }
    depth = [pscustomobject]@{
      selected = "Infinity"
      rendererCaptureExpectations = $checkoutDepthPromptExpectations
    }
    externals = [pscustomobject]@{
      selected = "Ignore externals"
      rendererCaptureExpectations = $checkoutExternalsPromptExpectations
    }
  }
  target = [pscustomobject]@{
    workingCopyRoot = $checkoutTargetWorkingCopyRoot
    trackedPath = Join-Path $checkoutTargetWorkingCopyRoot "src\tracked.txt"
    svnMetadataPath = Join-Path $checkoutTargetWorkingCopyRoot ".svn"
  }
  currentSurfaceReport = $checkoutCurrentSurfaceReport
  closeReport = $checkoutCloseReport
  assertions = [pscustomobject]@{
    commandExecuted = $true
    workingCopyCreated = $true
    repositoryOpenedAfterCheckout = $true
    sourceControlProjectionAvailable = $true
    repositoryClosedAfterEvidence = $true
  }
}
$updateTargetPath = Join-Path $updateWorkingCopyRoot $updateTargetRelativePath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $updateTargetPath), (Join-Path $updateWorkingCopyRoot ".svn") | Out-Null
Set-Content -LiteralPath $updateTargetPath -Value "initial update root`n" -NoNewline -Encoding utf8
Set-Content -LiteralPath (Join-Path $updateWorkingCopyRoot ".svn\wc.db") -Value "SubversionR fake update wc metadata`n" -NoNewline -Encoding utf8
$updateCancellationRevisionPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Update SVN working copy to revision", "Enter the SVN revision number")
  requiredAccessibilityTokens = @("Update SVN working copy to revision", "Enter the SVN revision number", "Revision number")
  requiredScreenshot = $true
  cancelSurface = "quickInput"
  cancelKey = "Escape"
}
[pscustomobject]@{
  ok = $true
  phase = "updateCancellationRevisionPromptReady"
  command = "subversionr.updateToRevision"
  prompt = [pscustomobject]@{
    kind = "revision"
    cancelKey = "Escape"
    rendererCaptureExpectations = $updateCancellationRevisionPromptExpectations
  }
  cancelKey = "Escape"
  rendererCaptureExpectations = $updateCancellationRevisionPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $updateCancellationRevisionPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $updateCancellationRevisionPromptDonePath -Description "update cancellation revision"
$updateCancellationCurrentSurfaceReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCurrentSurfaceReport"
  generatedAt = "2026-06-25T00:00:11Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$updateWorkingCopyRoot"
    epoch = 11
    identity = [pscustomobject]@{
      repositoryUuid = "fixture-update-repository-uuid"
      repositoryRootUrl = "file:///fixture/update/repo"
      workingCopyRoot = $updateWorkingCopyRoot
      workspaceScopeRoot = $updateWorkingCopyRoot
      format = 31
    }
  }
  openRequest = [pscustomobject]@{
    path = $updateWorkingCopyRoot
    relationToWorkingCopyRoot = "workingCopyRoot"
  }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$updateWorkingCopyRoot"
    epoch = 11
    workingCopyRoot = $updateWorkingCopyRoot
    generation = 1
    count = 0
    inputBox = $openReport.sourceControl.inputBox
    groups = @()
  }
  surfaceWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    scmProjection = $true
    sourceControlSurface = $true
    repositoryClosed = $false
  }
}
$updateCancellationCloseReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCloseReport"
  generatedAt = "2026-06-25T00:00:11Z"
  repositoryId = $updateCancellationCurrentSurfaceReport.repository.repositoryId
  epoch = $updateCancellationCurrentSurfaceReport.repository.epoch
  repositoryClosed = $true
}
$updateToRevisionCancellationReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eUpdateToRevisionCancellationWorkflow"
  generatedAt = "2026-06-25T00:00:11Z"
  command = [pscustomobject]@{
    command = "subversionr.updateToRevision"
  }
  target = [pscustomobject]@{
    workingCopyRoot = $updateWorkingCopyRoot
    relativePath = $updateTargetRelativePath
    path = $updateTargetPath
    initialContent = "initial update root`n"
    contentAfterCancellation = "initial update root`n"
    expectedUpdatedContent = "updated by Beta-C r2`n"
  }
  prompt = [pscustomobject]@{
    cancelKey = "Escape"
    rendererCaptureExpectations = $updateCancellationRevisionPromptExpectations
  }
  currentSurfaceReport = $updateCancellationCurrentSurfaceReport
  closeReport = $updateCancellationCloseReport
  assertions = [pscustomobject]@{
    commandCancelled = $true
    targetContentUnchangedAfterCancellation = $true
    requestedRevisionContentNotApplied = $true
    sourceControlProjectionUnchanged = $true
    repositoryClosedAfterEvidence = $true
  }
}
$updateRevisionPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Update SVN working copy to revision", "Enter the SVN revision number")
  requiredAccessibilityTokens = @("Update SVN working copy to revision", "Enter the SVN revision number", "Revision number")
  requiredScreenshot = $true
  inputText = $updateRevisionText
  submitKey = "Enter"
}
[pscustomobject]@{
  ok = $true
  phase = "updateRevisionPromptReady"
  command = "subversionr.updateToRevision"
  request = [pscustomobject]@{
    revision = $updateRevision
    depth = "files"
    depthIsSticky = $true
    ignoreExternals = $false
  }
  prompt = [pscustomobject]@{
    kind = "revision"
    rendererCaptureExpectations = $updateRevisionPromptExpectations
  }
  rendererCaptureExpectations = $updateRevisionPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $updateRevisionPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $updateRevisionPromptDonePath -Description "update revision"
$updateDepthPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN update depth", "Working copy depth", "Empty", "Files", "Immediates", "Infinity")
  requiredAccessibilityTokens = @("SVN update depth", "Working copy depth", "Empty", "Files", "Immediates", "Infinity")
  requiredScreenshot = $true
  quickPickItemText = "Files"
}
[pscustomobject]@{
  ok = $true
  phase = "updateDepthPromptReady"
  command = "subversionr.updateToRevision"
  prompt = [pscustomobject]@{
    kind = "depth"
    rendererCaptureExpectations = $updateDepthPromptExpectations
  }
  rendererCaptureExpectations = $updateDepthPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $updateDepthPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $updateDepthPromptDonePath -Description "update depth"
$updateStickyDepthPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN update sticky depth", "Keep depth non-sticky", "Make depth sticky")
  requiredAccessibilityTokens = @("SVN update sticky depth", "Keep depth non-sticky", "Make depth sticky")
  requiredScreenshot = $true
  quickPickItemText = "Make depth sticky"
}
[pscustomobject]@{
  ok = $true
  phase = "updateStickyDepthPromptReady"
  command = "subversionr.updateToRevision"
  prompt = [pscustomobject]@{
    kind = "stickyDepth"
    rendererCaptureExpectations = $updateStickyDepthPromptExpectations
  }
  rendererCaptureExpectations = $updateStickyDepthPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $updateStickyDepthPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $updateStickyDepthPromptDonePath -Description "update sticky depth"
$updateExternalsPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN update externals", "Ignore externals", "Include externals")
  requiredAccessibilityTokens = @("SVN update externals", "Ignore externals", "Include externals")
  requiredScreenshot = $true
  quickPickItemText = "Include externals"
}
[pscustomobject]@{
  ok = $true
  phase = "updateExternalsPromptReady"
  command = "subversionr.updateToRevision"
  prompt = [pscustomobject]@{
    kind = "externals"
    rendererCaptureExpectations = $updateExternalsPromptExpectations
  }
  rendererCaptureExpectations = $updateExternalsPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $updateExternalsPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $updateExternalsPromptDonePath -Description "update externals"
$updateTargetPath = Join-Path $updateWorkingCopyRoot $updateTargetRelativePath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $updateTargetPath), (Join-Path $updateWorkingCopyRoot ".svn") | Out-Null
Set-Content -LiteralPath $updateTargetPath -Value "updated by Beta-C r2`n" -NoNewline -Encoding utf8
Set-Content -LiteralPath (Join-Path $updateWorkingCopyRoot ".svn\wc.db") -Value "SubversionR fake update wc metadata`n" -NoNewline -Encoding utf8
$updateCurrentSurfaceReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCurrentSurfaceReport"
  generatedAt = "2026-06-25T00:00:12Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$updateWorkingCopyRoot"
    epoch = 12
    identity = [pscustomobject]@{
      repositoryUuid = "fixture-update-repository-uuid"
      repositoryRootUrl = "file:///fixture/update/repo"
      workingCopyRoot = $updateWorkingCopyRoot
      workspaceScopeRoot = $updateWorkingCopyRoot
      format = 31
    }
  }
  openRequest = [pscustomobject]@{
    path = $updateWorkingCopyRoot
    relationToWorkingCopyRoot = "workingCopyRoot"
  }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$updateWorkingCopyRoot"
    epoch = 12
    workingCopyRoot = $updateWorkingCopyRoot
    generation = 2
    count = 0
    inputBox = [pscustomobject]@{
      placeholder = "SVN commit message"
      acceptInputCommand = "subversionr.commitAll"
      acceptInputCommandArguments = @("repo-uuid:$updateWorkingCopyRoot")
    }
    groups = @()
  }
  surfaceWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    scmProjection = $true
    sourceControlSurface = $true
    repositoryClosed = $false
  }
}
$updateCloseReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCloseReport"
  generatedAt = "2026-06-25T00:00:12Z"
  repositoryId = $updateCurrentSurfaceReport.repository.repositoryId
  epoch = $updateCurrentSurfaceReport.repository.epoch
  repositoryClosed = $true
}
$updateToRevisionReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eUpdateToRevisionWorkflow"
  generatedAt = "2026-06-25T00:00:12Z"
  command = [pscustomobject]@{
    command = "subversionr.updateToRevision"
  }
  request = [pscustomobject]@{
    revision = $updateRevision
    depth = "files"
    depthIsSticky = $true
    ignoreExternals = $false
  }
  prompts = [pscustomobject]@{
    revision = [pscustomobject]@{
      rendererCaptureExpectations = $updateRevisionPromptExpectations
    }
    depth = [pscustomobject]@{
      selected = "Files"
      rendererCaptureExpectations = $updateDepthPromptExpectations
    }
    stickyDepth = [pscustomobject]@{
      selected = "Make depth sticky"
      rendererCaptureExpectations = $updateStickyDepthPromptExpectations
    }
    externals = [pscustomobject]@{
      selected = "Include externals"
      rendererCaptureExpectations = $updateExternalsPromptExpectations
    }
  }
  target = [pscustomobject]@{
    workingCopyRoot = $updateWorkingCopyRoot
    relativePath = $updateTargetRelativePath
    fsPath = $updateTargetPath
  }
  currentSurfaceReport = $updateCurrentSurfaceReport
  closeReport = $updateCloseReport
  assertions = [pscustomobject]@{
    commandExecuted = $true
    updatedRevisionContentApplied = $true
    postUpdateReconcileCompleted = $true
    sourceControlProjectionAvailable = $true
    repositoryClosedAfterEvidence = $true
  }
}
$branchCreateSourcePromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Create SVN branch or tag", "Enter the SVN source URL")
  requiredAccessibilityTokens = @("Create SVN branch or tag", "Enter the SVN source URL")
  requiredScreenshot = $true
  inputText = $branchCreateSourceUrl
  submitKey = "Enter"
}
[pscustomobject]@{
  ok = $true
  phase = "branchCreateSourcePromptReady"
  command = "subversionr.branchCreateRepository"
  rendererCaptureExpectations = $branchCreateSourcePromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $branchCreateSourcePromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $branchCreateSourcePromptDonePath -Description "branch create source"
$branchCreateDestinationPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN branch or tag destination", "Enter the SVN destination URL.")
  requiredAccessibilityTokens = @("SVN branch or tag destination", "Enter the SVN destination URL.")
  requiredScreenshot = $true
  inputText = $branchCreateDestinationUrl
  submitKey = "Enter"
}
[pscustomobject]@{
  ok = $true
  phase = "branchCreateDestinationPromptReady"
  command = "subversionr.branchCreateRepository"
  rendererCaptureExpectations = $branchCreateDestinationPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $branchCreateDestinationPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $branchCreateDestinationPromptDonePath -Description "branch create destination"
$branchCreateRevisionPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN branch or tag source revision", "HEAD", "Revision number")
  requiredAccessibilityTokens = @("SVN branch or tag source revision", "HEAD", "Revision number")
  requiredScreenshot = $true
  quickPickItemText = "HEAD"
}
[pscustomobject]@{
  ok = $true
  phase = "branchCreateRevisionPromptReady"
  command = "subversionr.branchCreateRepository"
  rendererCaptureExpectations = $branchCreateRevisionPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $branchCreateRevisionPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $branchCreateRevisionPromptDonePath -Description "branch create revision"
$branchCreateMessagePromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN branch or tag log message", "Enter the SVN log message for the copy commit.")
  requiredAccessibilityTokens = @("SVN branch or tag log message", "Enter the SVN log message for the copy commit.")
  requiredScreenshot = $true
  inputText = $branchCreateMessage
  submitKey = "Enter"
}
[pscustomobject]@{
  ok = $true
  phase = "branchCreateMessagePromptReady"
  command = "subversionr.branchCreateRepository"
  rendererCaptureExpectations = $branchCreateMessagePromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $branchCreateMessagePromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $branchCreateMessagePromptDonePath -Description "branch create message"
$branchCreateParentsPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN branch or tag parents", "Require destination parent", "Create destination parents")
  requiredAccessibilityTokens = @("SVN branch or tag parents", "Require destination parent", "Create destination parents")
  requiredScreenshot = $true
  quickPickItemText = "Require destination parent"
}
[pscustomobject]@{
  ok = $true
  phase = "branchCreateParentsPromptReady"
  command = "subversionr.branchCreateRepository"
  rendererCaptureExpectations = $branchCreateParentsPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $branchCreateParentsPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $branchCreateParentsPromptDonePath -Description "branch create parents"
$branchCreateExternalsPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN branch or tag externals", "Ignore externals", "Include externals")
  requiredAccessibilityTokens = @("SVN branch or tag externals", "Ignore externals", "Include externals")
  requiredScreenshot = $true
  quickPickItemText = "Ignore externals"
}
[pscustomobject]@{
  ok = $true
  phase = "branchCreateExternalsPromptReady"
  command = "subversionr.branchCreateRepository"
  rendererCaptureExpectations = $branchCreateExternalsPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $branchCreateExternalsPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $branchCreateExternalsPromptDonePath -Description "branch create externals"
$branchCreateSwitchPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN branch/tag switch", "Stay on the current SVN URL", "Create the branch or tag without switching this working copy", "Switch this working copy to the new branch/tag")
  requiredAccessibilityTokens = @("SVN branch/tag switch", "Stay on the current SVN URL", "Create the branch or tag without switching this working copy", "Switch this working copy to the new branch/tag")
  requiredScreenshot = $true
  quickPickItemText = "Stay on the current SVN URL"
}
[pscustomobject]@{
  ok = $true
  phase = "branchCreateSwitchPromptReady"
  command = "subversionr.branchCreateRepository"
  rendererCaptureExpectations = $branchCreateSwitchPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $branchCreateSwitchPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $branchCreateSwitchPromptDonePath -Description "branch create switch"
$branchCreateSourcePath = ([Uri]$branchCreateSourceUrl).LocalPath
$branchCreateDestinationPath = ([Uri]$branchCreateDestinationUrl).LocalPath
if (Test-Path -LiteralPath $branchCreateDestinationPath) {
  Remove-Item -LiteralPath $branchCreateDestinationPath -Recurse -Force
}
Copy-Item -LiteralPath $branchCreateSourcePath -Destination $branchCreateDestinationPath -Recurse -Force
$branchCreateCloseReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCloseReport"
  generatedAt = "2026-06-25T00:00:13Z"
  repositoryId = "repo-uuid:$branchCreateWorkingCopyRoot"
  epoch = 13
  repositoryClosed = $true
}
$branchCreateReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eBranchCreateWorkflow"
  generatedAt = "2026-06-25T00:00:13Z"
  command = [pscustomobject]@{
    command = "subversionr.branchCreateRepository"
  }
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$branchCreateWorkingCopyRoot"
    epoch = 13
    workingCopyRoot = $branchCreateWorkingCopyRoot
  }
  request = [pscustomobject]@{
    sourceUrl = $branchCreateSourceUrl
    destinationUrl = $branchCreateDestinationUrl
    revision = "head"
    message = $branchCreateMessage
    makeParents = $false
    ignoreExternals = $true
  }
  prompts = [pscustomobject]@{
    sourceUrl = [pscustomobject]@{ rendererCaptureExpectations = $branchCreateSourcePromptExpectations }
    destinationUrl = [pscustomobject]@{ rendererCaptureExpectations = $branchCreateDestinationPromptExpectations }
    revision = [pscustomobject]@{ selected = "HEAD"; rendererCaptureExpectations = $branchCreateRevisionPromptExpectations }
    message = [pscustomobject]@{ rendererCaptureExpectations = $branchCreateMessagePromptExpectations }
    parents = [pscustomobject]@{ selected = "Require destination parent"; rendererCaptureExpectations = $branchCreateParentsPromptExpectations }
    externals = [pscustomobject]@{ selected = "Ignore externals"; rendererCaptureExpectations = $branchCreateExternalsPromptExpectations }
    switchAfterCreate = [pscustomobject]@{ selected = "Stay on the current SVN URL"; switchAfterCreate = $false; rendererCaptureExpectations = $branchCreateSwitchPromptExpectations }
  }
  closeReport = $branchCreateCloseReport
  assertions = [pscustomobject]@{
    commandExecuted = $true
    branchCreatedInRepository = $true
    noLocalReconcileClaimed = $true
    repositoryClosedAfterEvidence = $true
  }
}
$switchUrlPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("Switch SVN working copy", "Enter the SVN URL to switch")
  requiredAccessibilityTokens = @("Switch SVN working copy", "Enter the SVN URL to switch")
  requiredScreenshot = $true
  inputText = $switchTargetUrl
  submitKey = "Enter"
}
[pscustomobject]@{
  ok = $true
  phase = "switchUrlPromptReady"
  command = "subversionr.switchRepository"
  rendererCaptureExpectations = $switchUrlPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $switchUrlPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $switchUrlPromptDonePath -Description "switch URL"
$switchRevisionPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN switch revision", "HEAD", "Revision number")
  requiredAccessibilityTokens = @("SVN switch revision", "HEAD", "Revision number")
  requiredScreenshot = $true
  quickPickItemText = "HEAD"
}
[pscustomobject]@{
  ok = $true
  phase = "switchRevisionPromptReady"
  command = "subversionr.switchRepository"
  rendererCaptureExpectations = $switchRevisionPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $switchRevisionPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $switchRevisionPromptDonePath -Description "switch revision"
$switchDepthPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN switch depth", "Working copy depth", "Empty", "Files", "Immediates", "Infinity")
  requiredAccessibilityTokens = @("SVN switch depth", "Working copy depth", "Empty", "Files", "Immediates", "Infinity")
  requiredScreenshot = $true
  quickPickItemText = "Infinity"
}
[pscustomobject]@{
  ok = $true
  phase = "switchDepthPromptReady"
  command = "subversionr.switchRepository"
  rendererCaptureExpectations = $switchDepthPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $switchDepthPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $switchDepthPromptDonePath -Description "switch depth"
$switchStickyDepthPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN switch sticky depth", "Keep depth non-sticky", "Make depth sticky")
  requiredAccessibilityTokens = @("SVN switch sticky depth", "Keep depth non-sticky", "Make depth sticky")
  requiredScreenshot = $true
  quickPickItemText = "Make depth sticky"
}
[pscustomobject]@{
  ok = $true
  phase = "switchStickyDepthPromptReady"
  command = "subversionr.switchRepository"
  rendererCaptureExpectations = $switchStickyDepthPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $switchStickyDepthPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $switchStickyDepthPromptDonePath -Description "switch sticky depth"
$switchExternalsPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN switch externals", "Ignore externals", "Include externals")
  requiredAccessibilityTokens = @("SVN switch externals", "Ignore externals", "Include externals")
  requiredScreenshot = $true
  quickPickItemText = "Ignore externals"
}
[pscustomobject]@{
  ok = $true
  phase = "switchExternalsPromptReady"
  command = "subversionr.switchRepository"
  rendererCaptureExpectations = $switchExternalsPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $switchExternalsPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $switchExternalsPromptDonePath -Description "switch externals"
$switchAncestryPromptExpectations = [pscustomobject]@{
  requiredDomTokens = @("SVN switch ancestry", "Check ancestry", "Ignore ancestry")
  requiredAccessibilityTokens = @("SVN switch ancestry", "Check ancestry", "Ignore ancestry")
  requiredScreenshot = $true
  quickPickItemText = "Check ancestry"
}
[pscustomobject]@{
  ok = $true
  phase = "switchAncestryPromptReady"
  command = "subversionr.switchRepository"
  rendererCaptureExpectations = $switchAncestryPromptExpectations
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $switchAncestryPromptReadyPath -Encoding utf8
Wait-FakeRendererDone -Path $switchAncestryPromptDonePath -Description "switch ancestry"
New-Item -ItemType Directory -Force -Path (Join-Path $switchWorkingCopyRoot ".svn") | Out-Null
Set-Content -LiteralPath (Join-Path $switchWorkingCopyRoot ".svn\fake-switched-url.txt") -Value $switchTargetUrl -NoNewline -Encoding utf8
$switchCurrentSurfaceReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCurrentSurfaceReport"
  generatedAt = "2026-06-25T00:00:14Z"
  extension = $openReport.extension
  workspace = $openReport.workspace
  repository = [pscustomobject]@{
    repositoryId = "repo-uuid:$switchWorkingCopyRoot"
    epoch = 14
    identity = [pscustomobject]@{
      repositoryUuid = "fixture-switch-repository-uuid"
      repositoryRootUrl = "file:///fixture/switch/repo"
      workingCopyRoot = $switchWorkingCopyRoot
      workspaceScopeRoot = $switchWorkingCopyRoot
      format = 31
    }
  }
  sourceControl = [pscustomobject]@{
    repositoryId = "repo-uuid:$switchWorkingCopyRoot"
    epoch = 14
    workingCopyRoot = $switchWorkingCopyRoot
    generation = 2
    count = 0
    inputBox = $openReport.sourceControl.inputBox
    groups = @()
  }
  surfaceWorkflow = [pscustomobject]@{
    repositoryOpen = $true
    scmProjection = $true
    sourceControlSurface = $true
    repositoryClosed = $false
  }
}
$switchCloseReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eCloseReport"
  generatedAt = "2026-06-25T00:00:14Z"
  repositoryId = $switchCurrentSurfaceReport.repository.repositoryId
  epoch = $switchCurrentSurfaceReport.repository.epoch
  repositoryClosed = $true
}
$switchReport = [pscustomobject]@{
  kind = "subversionr.installedSourceControlUiE2eSwitchWorkflow"
  generatedAt = "2026-06-25T00:00:14Z"
  command = [pscustomobject]@{
    command = "subversionr.switchRepository"
  }
  repository = [pscustomobject]@{
    repositoryId = $switchCurrentSurfaceReport.repository.repositoryId
    epoch = $switchCurrentSurfaceReport.repository.epoch
    workingCopyRoot = $switchWorkingCopyRoot
  }
  request = [pscustomobject]@{
    url = $switchTargetUrl
    revision = "head"
    depth = "infinity"
    depthIsSticky = $true
    ignoreExternals = $true
    ignoreAncestry = $false
  }
  prompts = [pscustomobject]@{
    url = [pscustomobject]@{ rendererCaptureExpectations = $switchUrlPromptExpectations }
    revision = [pscustomobject]@{ selected = "HEAD"; rendererCaptureExpectations = $switchRevisionPromptExpectations }
    depth = [pscustomobject]@{ selected = "Infinity"; rendererCaptureExpectations = $switchDepthPromptExpectations }
    stickyDepth = [pscustomobject]@{ selected = "Make depth sticky"; rendererCaptureExpectations = $switchStickyDepthPromptExpectations }
    externals = [pscustomobject]@{ selected = "Ignore externals"; rendererCaptureExpectations = $switchExternalsPromptExpectations }
    ancestry = [pscustomobject]@{ selected = "Check ancestry"; rendererCaptureExpectations = $switchAncestryPromptExpectations }
  }
  currentSurfaceReport = $switchCurrentSurfaceReport
  closeReport = $switchCloseReport
  assertions = [pscustomobject]@{
    commandExecuted = $true
    postSwitchReconcileCompleted = $true
    postSwitchGenerationAdvanced = $true
    postSwitchRepositoryIdentityPreserved = $true
    sourceControlProjectionAvailable = $true
    repositoryClosedAfterEvidence = $true
  }
}
$lifecycleDeletionReport = [pscustomobject]@{
  kind = "subversionr.installedRepositoryLifecycleReport"
  generatedAt = "2026-06-25T00:00:06Z"
  request = [pscustomobject]@{
    scenario = "deletedWorkingCopy"
    trigger = "workspaceFolders"
    expectedRepositoryId = "repo-uuid:$workingCopyRoot-delete"
    expectedEpoch = 2
    expectedWorkingCopyRoot = "$workingCopyRoot-delete"
  }
  lifecycleWorkflow = [pscustomobject]@{
    movedRecovery = $true
    disappearedCleanup = $true
    automaticOpen = $true
  }
  assertions = [pscustomobject]@{
    missingWorkingCopyClosed = $true
    movedWorkingCopyRecovered = $false
  }
}
$lifecycleMoveReport = [pscustomobject]@{
  kind = "subversionr.installedRepositoryLifecycleReport"
  generatedAt = "2026-06-25T00:00:07Z"
  request = [pscustomobject]@{
    scenario = "movedWorkingCopy"
    trigger = "workspaceFolders"
    expectedRepositoryId = "repo-uuid:$workingCopyRoot-move-old"
    expectedEpoch = 3
    expectedWorkingCopyRoot = "$workingCopyRoot-move-old"
    expectedMovedWorkingCopyRoot = "$workingCopyRoot-move-new"
  }
  lifecycleWorkflow = [pscustomobject]@{
    movedRecovery = $true
    disappearedCleanup = $true
    automaticOpen = $true
  }
  assertions = [pscustomobject]@{
    missingWorkingCopyClosed = $false
    movedWorkingCopyRecovered = $true
  }
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
    "subversionr.diagnostics.installedSourceControlUiE2eOpenReport",
    "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport",
    "workbench.view.scm",
    "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport",
    "subversionr.diagnostics.installedSourceControlUiE2eArmDirtyGenerationCancellation",
    "subversionr.diagnostics.installedSourceControlUiE2eDirtyEvent",
    "subversionr.diagnostics.installedSourceControlUiE2eDirtyGenerationCancellationReport",
    "subversionr.refreshRepository",
    "subversionr.refreshResource",
    "subversionr.updateRepository",
    "subversionr.updateToRevision",
    "subversionr.deleteUnversionedResource",
    "subversionr.deleteAllUnversionedResources",
    "subversionr.diagnostics.installedSourceControlUiE2eSetInputMessage",
    "subversionr.commitAll",
    "subversionr.commitResource",
    "subversionr.addToIgnoreResource",
    "subversionr.lockResource",
    "subversionr.unlockResource",
    "subversionr.setResourceChangelist",
    "subversionr.clearResourceChangelist",
    "subversionr.commitChangelist",
    "subversionr.revertChangelist",
    "subversionr.checkoutRepository",
    "subversionr.branchCreateRepository",
    "subversionr.switchRepository",
    "subversionr.addResource",
    "subversionr.moveResource",
    "subversionr.removeResource",
    "subversionr.resolveResource",
    "subversionr.removeResourceKeepLocal",
    "subversionr.revertResource",
    "subversionr.cleanupRepository",
    "subversionr.diagnostics.installedSourceControlUiE2eCloseReport",
    "subversionr.diagnostics.installedSourceControlUiE2eLazyExternalProviderReport",
    "subversionr.diagnostics.installedRepositoryLifecycleReport",
    "subversionr.diagnostics.versionReport"
  )
  hasInstalledSourceControlUiE2eOpenReportCommand = $true
  hasInstalledSourceControlUiE2eCurrentSurfaceReportCommand = $true
  hasInstalledSourceControlUiE2eFreshnessReportCommand = $true
  hasInstalledSourceControlUiE2eArmFullReconcileCancellationCommand = $true
  hasInstalledSourceControlUiE2eFullReconcileCancellationReportCommand = $true
  hasInstalledSourceControlUiE2eArmDirtyGenerationCancellationCommand = $true
  hasInstalledSourceControlUiE2eDirtyGenerationCancellationReportCommand = $true
  hasInstalledSourceControlUiE2eDirtyEventCommand = $true
  hasInstalledSourceControlUiE2eCloseReportCommand = $true
  hasInstalledSourceControlUiE2eLazyExternalProviderReportCommand = $true
  hasInstalledRepositoryLifecycleReportCommand = $true
  hasRefreshRepositoryCommand = $true
  hasUpdateRepositoryCommand = $true
  hasUpdateToRevisionCommand = $true
  hasDeleteUnversionedResourceCommand = $true
  hasDeleteAllUnversionedResourcesCommand = $true
  hasCommitAllCommand = $true
  hasCommitResourceCommand = $true
  hasAddToIgnoreResourceCommand = $true
  hasLockResourceCommand = $true
  hasUnlockResourceCommand = $true
  hasSetResourceChangelistCommand = $true
  hasClearResourceChangelistCommand = $true
  hasCommitChangelistCommand = $true
  hasRevertChangelistCommand = $true
  hasCheckoutRepositoryCommand = $true
  hasBranchCreateRepositoryCommand = $true
  hasSwitchRepositoryCommand = $true
  hasInstalledSourceControlUiE2eSetInputMessageCommand = $true
  hasAddResourceCommand = $true
  hasMoveResourceCommand = $true
  hasRemoveResourceCommand = $true
  hasRemoveResourceKeepLocalCommand = $true
  hasRevertResourceCommand = $true
  hasResolveResourceCommand = $true
  hasCleanupRepositoryCommand = $true
  openReport = $openReport
  partialFreshnessReport = $partialFreshnessReport
  staleFreshnessReport = $staleFreshnessReport
  noRepositoryWelcomeRendererCaptureExpectations = $noRepositoryWelcomeRendererExpectations
  partialFreshnessRendererCaptureExpectations = $partialFreshnessRendererExpectations
  staleFreshnessRendererCaptureExpectations = $staleFreshnessRendererExpectations
  fullReconcileCancellationReport = $fullReconcileCancellationReport
  refreshReport = $refreshReport
  dirtyGenerationCancellationLoadReport = $dirtyGenerationCancellationLoadWorkflow
  refreshLoadReport = $refreshLoadReport
  multiRepositoryRefreshReport = $multiRepositoryRefreshReport
  lazyExternalProviderReport = $lazyExternalProviderReport
  boundaryLoadReport = $boundaryLoadReport
  deleteUnversionedFreshnessReport = $deleteUnversionedFreshnessReport
  deleteUnversionedReport = $deleteUnversionedReport
  deleteUnversionedLoadReport = $deleteUnversionedLoadReport
  commitAllReport = $commitAllReport
  commitSelectedReport = $commitSelectedReport
  commitSelectedMultiSelectionReport = $commitSelectedMultiSelectionReport
  addToIgnoreReport = $addToIgnoreReport
  lockUnlockReport = $lockUnlockReport
  lockMessageCancellationReport = $lockMessageCancellationReport
  unlockModeCancellationReport = $unlockModeCancellationReport
  changelistSetClearReport = $changelistSetClearReport
  commitChangelistReport = $commitChangelistReport
  revertChangelistReport = $revertChangelistReport
  checkoutCancellationReport = $checkoutCancellationReport
  checkoutExistingTargetFailureReport = $checkoutExistingTargetFailureReport
  checkoutInvalidUrlFailureReport = $checkoutInvalidUrlFailureReport
  checkoutExistingDirectoryReport = $checkoutExistingDirectoryReport
  checkoutExistingDirectoryObstructionReport = $checkoutExistingDirectoryObstructionReport
  checkoutReport = $checkoutReport
  updateToRevisionCancellationReport = $updateToRevisionCancellationReport
  updateToRevisionReport = $updateToRevisionReport
  branchCreateReport = $branchCreateReport
  switchReport = $switchReport
  addReport = $addReport
  moveReport = $moveReport
  moveCancellationReport = $moveCancellationReport
  removeReport = $removeReport
  removeCancellationReport = $removeCancellationReport
  resolveReport = $resolveReport
  resolveCancellationReport = $resolveCancellationReport
  removeKeepLocalReport = $removeKeepLocalReport
  revertReport = $revertReport
  revertCancellationReport = $revertCancellationReport
  cleanupReport = $cleanupReport
  closeReport = $closeReport
  repositoryLifecycleDeletionReport = $lifecycleDeletionReport
  repositoryLifecycleMoveReport = $lifecycleMoveReport
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

function New-FakeRendererCaptureDriver([string]$Path) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  @'
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";

const args = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  args.set(process.argv[index].slice(2), process.argv[index + 1]);
}
const outputRoot = args.get("output-root");
const expectationsPath = args.get("expectations-path");
const target = args.get("target");
if (!outputRoot || !expectationsPath || !target) {
  throw new Error("fake renderer capture driver requires output-root, expectations-path, and target.");
}
mkdirSync(outputRoot, { recursive: true });
const expectations = JSON.parse(readFileSync(expectationsPath, "utf8"));
const mode = process.env.SUBVERSIONR_FAKE_RENDERER_CAPTURE_MODE || "valid";
const domPath = path.join(outputRoot, "dom-text.txt");
const axPath = path.join(outputRoot, "accessibility-tree.json");
const pngPath = path.join(outputRoot, "screenshot.png");
const domText = mode === "missing-dom-token" || mode === "lying-dom-token" ? "SubversionR Changes" : expectations.requiredDomTokens.join("\n");
const axText = expectations.requiredAccessibilityTokens.join("\n");
writeFileSync(domPath, domText);
writeFileSync(axPath, JSON.stringify({ nodes: [{ name: { value: axText } }] }, null, 2));
const nonBlankPng = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAAOSURBVBhXY/jPwABC/wEP+QP98+IdQAAAAABJRU5ErkJggg==";
const blankPng = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAALSURBVBhXY/gPBQAj5Qf5Wr8b3QAAAABJRU5ErkJggg==";
writeFileSync(pngPath, Buffer.from(mode === "blank-screenshot" || mode === "blank-screenshot-lie" ? blankPng : nonBlankPng, "base64"));
const domMissing = expectations.requiredDomTokens.filter(token => !domText.includes(token));
const axMissing = expectations.requiredAccessibilityTokens.filter(token => !axText.includes(token));
const reportedDomMissing = mode === "lying-dom-token" ? [] : domMissing;
const reportedScreenshotNonBlank = mode === "blank-screenshot" ? false : true;
const cancelSurface = expectations.cancelSurface || "quickInput";
const report = {
  schemaVersion: 1,
  schema: "subversionr.release.installed-source-control-ui-renderer-capture.v1",
  target,
  capturedAt: "2026-06-25T00:00:10Z",
  remoteDebugging: {
    port: Number(args.get("remote-debugging-port")),
    selectedTarget: {
      id: "fake-workbench",
      type: "page",
      title: "Visual Studio Code - fake workbench",
      url: "vscode-file://fixture/workbench.html"
    }
  },
  artifacts: {
    dom: {
      status: mode === "partial-dom" ? "partial" : "captured",
      relativePath: "dom-text.txt",
      sha256: sha256(domPath),
      requiredTokens: expectations.requiredDomTokens,
      matchedTokens: expectations.requiredDomTokens.filter(token => domText.includes(token)),
      missingTokens: reportedDomMissing
    },
    accessibility: {
      status: mode === "partial-accessibility" ? "partial" : "captured",
      relativePath: "accessibility-tree.json",
      sha256: sha256(axPath),
      requiredTokens: expectations.requiredAccessibilityTokens,
      matchedTokens: expectations.requiredAccessibilityTokens.filter(token => axText.includes(token)),
      missingTokens: axMissing
    },
    screenshot: {
      status: "captured",
      relativePath: "screenshot.png",
      sha256: sha256(pngPath),
      width: 2,
      height: 1,
      bitDepth: 8,
      colorType: 6,
      nonBlank: reportedScreenshotNonBlank,
      uniqueColorSampleCount: reportedScreenshotNonBlank ? 2 : 1
    }
  },
  assertions: {
    domRequiredTokensPresent: mode === "lying-dom-token" ? true : domMissing.length === 0,
    accessibilityRequiredTokensPresent: axMissing.length === 0,
    screenshotCaptured: true,
    screenshotNonBlank: reportedScreenshotNonBlank,
    ...(expectations.clickButtonText ? { clickButtonCompleted: true } : {}),
    ...(expectations.inputText ? { inputTextSubmitted: true } : {}),
    ...(expectations.quickInputSubmitKey ? { quickInputSubmitted: true } : {}),
    ...(expectations.quickPickItemText ? { quickPickItemSelected: true } : {}),
    ...(expectations.cancelKey || expectations.cancelAction ? {
      interactionCancelled: true,
      ...(cancelSurface === "dialog"
        ? { dialogCancelled: true }
        : cancelSurface === "notification"
          ? { notificationCancelled: true }
          : { quickInputCancelled: true })
    } : {})
  },
  ...(expectations.clickButtonText ? {
    interaction: {
      clicked: true,
      clickedButtonText: expectations.clickButtonText,
      tagName: "A",
      className: "monaco-button monaco-text-button"
    }
  } : {}),
  ...(expectations.inputText ? {
    interaction: {
      submitted: true,
      enteredText: expectations.inputText,
      submittedKey: expectations.submitKey,
      tagName: "INPUT",
      className: "input",
      ariaLabel: "",
      placeholder: "",
      valueBefore: "src/tracked.txt"
    }
  } : {}),
  ...(expectations.quickInputSubmitKey ? {
    interaction: {
      submitted: true,
      submittedKey: expectations.quickInputSubmitKey,
      surface: "quickInput",
      tagName: "INPUT",
      className: "input",
      ariaLabel: "",
      placeholder: "",
      valueBefore: ""
    }
  } : {}),
  ...(expectations.quickPickItemText ? {
    interaction: {
      selected: true,
      surface: "quickPick",
      requestedText: expectations.quickPickItemText,
      selectedText: expectations.quickPickItemText,
      label: expectations.quickPickItemText,
      description: "file:///fixture/multi-repository-refresh/repo",
      tagName: "DIV",
      className: "monaco-list-row",
      ariaLabel: expectations.quickPickItemText
    }
  } : {}),
  ...(expectations.cancelKey ? {
    interaction: {
      cancelled: true,
      cancelledKey: expectations.cancelKey,
      surface: cancelSurface,
      tagName: cancelSurface === "dialog" || cancelSurface === "notification" ? "DIV" : "INPUT",
      className: cancelSurface === "dialog"
        ? "monaco-dialog-box"
        : cancelSurface === "notification"
          ? "notification-toast"
          : "input",
      ariaLabel: "",
      placeholder: "",
      valueBefore: "src/tracked.txt"
    }
  } : {}),
  ...(expectations.cancelAction ? {
    interaction: {
      cancelled: true,
      cancelledAction: expectations.cancelAction,
      surface: cancelSurface,
      tagName: "A",
      className: "action-label codicon codicon-close",
      ariaLabel: "Clear Notification",
      title: "Clear Notification"
    }
  } : {})
};
writeFileSync(path.join(outputRoot, "renderer-capture.json"), JSON.stringify(report, null, 2));
function sha256(filePath) {
  return createHash("sha256").update(readFileSync(filePath)).digest("hex");
}
'@ | Set-Content -LiteralPath $Path -NoNewline -Encoding utf8
}

function New-FakeSvnTools([string]$Root, [string]$Version = "1.14.5") {
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  $cscCandidates = @(
    (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
    (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
  )
  $csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  if ([string]::IsNullOrWhiteSpace($csc)) {
    throw "release-installed-source-control-ui-e2e-scripts.tests.ps1 requires csc.exe to build fake svn.exe and svnadmin.exe."
  }
  $source = @"
using System;
using System.IO;

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
      if (exe == "svn.exe" && args.Length >= 3 && args[0] == "import") {
        var importRoot = args[1];
        var repositoryPath = LocalPathFromFileUrl(args[2]);
        CopyDirectory(importRoot, repositoryPath);
        return 0;
      }
      if (exe == "svn.exe" && args.Length >= 3 && args[0] == "checkout") {
        var sourcePath = LocalPathFromFileUrl(args[1]);
        var wcRoot = args[2];
        if (Directory.Exists(sourcePath)) {
          CopyDirectory(sourcePath, wcRoot);
        } else {
          Directory.CreateDirectory(Path.Combine(wcRoot, "src"));
          File.WriteAllText(Path.Combine(wcRoot, "src", "tracked.txt"), "initial\n");
        }
        Directory.CreateDirectory(Path.Combine(wcRoot, ".svn"));
        File.WriteAllText(Path.Combine(wcRoot, ".svn", "wc.db"), "SubversionR fake wc metadata\n");
        return 0;
      }
      if (exe == "svn.exe" && args.Length >= 1 && args[0] == "add") {
        return 0;
      }
      if (exe == "svn.exe" && args.Length >= 1 && args[0] == "changelist") {
        return 0;
      }
      if (exe == "svn.exe" && args.Length >= 2 && args[0] == "mkdir") {
        var targetPath = LocalPathFromFileUrl(args[1]);
        Directory.CreateDirectory(targetPath);
        return 0;
      }
      if (exe == "svn.exe" && args.Length >= 3 && args[0] == "copy") {
        var sourcePath = LocalPathFromFileUrl(args[1]);
        var destinationPath = LocalPathFromFileUrl(args[2]);
        if (Directory.Exists(destinationPath)) {
          Directory.Delete(destinationPath, true);
        }
        CopyDirectory(sourcePath, destinationPath);
        return 0;
      }
      if (exe == "svn.exe" && args.Length >= 2 && args[0] == "propget" && args[1] == "svn:needs-lock") {
        Console.WriteLine("*");
        return 0;
      }
      if (exe == "svn.exe" && args.Length >= 2 && args[0] == "propget" && args[1] == "svn:ignore") {
        Console.WriteLine("scratch.txt");
        return 0;
      }
      if (exe == "svn.exe" && args.Length >= 1 && args[0] == "status") {
        var xmlRequested = Array.IndexOf(args, "--xml") >= 0;
        if (xmlRequested && args.Length >= 2 && args[1].IndexOf("resolve-fixture", StringComparison.OrdinalIgnoreCase) >= 0) {
          var conflictPath = Path.Combine(args[1], "src", "tracked.txt");
          Console.WriteLine("<?xml version=\"1.0\"?><status><target path=\"" + System.Security.SecurityElement.Escape(args[1]) + "\"><entry path=\"" + System.Security.SecurityElement.Escape(conflictPath) + "\"><wc-status item=\"conflicted\" props=\"none\" revision=\"1\" /></entry></target></status>");
          return 0;
        }
        foreach (var argument in args) {
          if (argument.IndexOf("checkout-existing-directory-obstruction", StringComparison.OrdinalIgnoreCase) >= 0) {
            Console.WriteLine("?       local-only-before-checkout.txt");
            Console.WriteLine("D     C src");
            Console.WriteLine("      >   local file unversioned, incoming dir add upon update");
            Console.WriteLine("Summary of conflicts:");
            Console.WriteLine("  Tree conflicts: 1");
            return 0;
          }
        }
        foreach (var argument in args) {
          if (argument == "--no-ignore") {
            Console.WriteLine("I       scratch.txt");
            return 0;
          }
        }
        return 0;
      }
      if (exe == "svn.exe" && args.Length >= 4 && args[0] == "propset" && args[1] == "svn:needs-lock") {
        var targetPath = args.Length >= 5 && args[2] == "--file" ? args[4] : args[3];
        var targetDirectory = Path.GetDirectoryName(targetPath);
        if (!String.IsNullOrWhiteSpace(targetDirectory)) {
          Directory.CreateDirectory(targetDirectory);
        }
        if (!File.Exists(targetPath)) {
          File.WriteAllText(targetPath, "needs lock\n");
        }
        return 0;
      }
      if (exe == "svn.exe" && args.Length >= 4 && args[0] == "propset" && args[1] == "svn:externals") {
        string targetRoot = null;
        foreach (var candidate in args) {
          if (candidate.Replace('/', Path.DirectorySeparatorChar).EndsWith(Path.DirectorySeparatorChar + "externals", StringComparison.OrdinalIgnoreCase)) {
            targetRoot = candidate;
            break;
          }
        }
        if (String.IsNullOrWhiteSpace(targetRoot)) {
          Console.Error.WriteLine("Unsupported fake SVN propset target: " + string.Join(" | ", args));
          return 2;
        }
        CreateDirectory(targetRoot);
        CreateDirectory(Path.Combine(targetRoot, "library", ".svn"));
        CreateDirectory(Path.Combine(targetRoot, "library", "src"));
        CreateDirectory(Path.Combine(targetRoot, "library", "load"));
        WriteText(Path.Combine(targetRoot, "library", "src", "tracked.txt"), "directory external source\n");
        for (var index = 1; index <= 256; index++) {
          WriteText(Path.Combine(targetRoot, "library", "load", "modified-" + index.ToString("D3") + ".txt"), "directory external load source\n");
        }
        WriteText(Path.Combine(targetRoot, "pinned.txt"), "file external source\n");
        return 0;
      }
      if (exe == "svn.exe" && args.Length >= 2 && args[0] == "info") {
        var targetPath = args[1];
        var workingCopyRoot = FindWorkingCopyRoot(targetPath);
        var switchedUrlPath = Path.Combine(workingCopyRoot, ".svn", "fake-switched-url.txt");
        var url = File.Exists(switchedUrlPath) ? File.ReadAllText(switchedUrlPath) : "file:///fixture/lock/trunk/src/needs-lock.txt";
        Console.WriteLine("Path: " + targetPath);
        Console.WriteLine("Working Copy Root Path: " + workingCopyRoot);
        Console.WriteLine("URL: " + url);
        Console.WriteLine("Relative URL: ^/trunk/src/needs-lock.txt");
        Console.WriteLine("Revision: 1");
        if (File.Exists(Path.Combine(workingCopyRoot, ".svn", "fake-lock-held"))) {
          Console.WriteLine("Lock Token: opaquelocktoken:subversionr-fake-lock");
          Console.WriteLine("Lock Owner: SubversionR fake");
        }
        return 0;
      }
      if (exe == "svn.exe" && args.Length >= 1 && (args[0] == "lock" || args[0] == "unlock")) {
        return 0;
      }
      if (exe == "svn.exe" && args.Length >= 2 && args[0] == "cat") {
        var normalizedUrl = args[1].Replace('\\', '/');
        if (normalizedUrl.IndexOf("commit-all-fixture", StringComparison.OrdinalIgnoreCase) >= 0 &&
            normalizedUrl.EndsWith("/trunk/src/tracked.txt", StringComparison.OrdinalIgnoreCase)) {
          Console.WriteLine("modified by M7j3");
          return 0;
        }
        if (normalizedUrl.IndexOf("commit-all-fixture", StringComparison.OrdinalIgnoreCase) >= 0 &&
            normalizedUrl.EndsWith("/trunk/scratch.txt", StringComparison.OrdinalIgnoreCase)) {
          Console.Error.WriteLine("svn: warning: W160013: path not found");
          return 1;
        }
        if (normalizedUrl.IndexOf("commit-selected-fixture", StringComparison.OrdinalIgnoreCase) >= 0 &&
            normalizedUrl.EndsWith("/trunk/src/tracked.txt", StringComparison.OrdinalIgnoreCase)) {
          Console.WriteLine("modified by M7j3");
          return 0;
        }
        if (normalizedUrl.IndexOf("commit-selected-fixture", StringComparison.OrdinalIgnoreCase) >= 0 &&
            normalizedUrl.EndsWith("/trunk/load/modified-001.txt", StringComparison.OrdinalIgnoreCase)) {
          Console.WriteLine("initial load item 1");
          return 0;
        }
        if (normalizedUrl.IndexOf("commit-selected-multi-selection-fixture", StringComparison.OrdinalIgnoreCase) >= 0 &&
            normalizedUrl.EndsWith("/trunk/src/tracked.txt", StringComparison.OrdinalIgnoreCase)) {
          Console.WriteLine("modified by M7j3");
          return 0;
        }
        if (normalizedUrl.IndexOf("commit-selected-multi-selection-fixture", StringComparison.OrdinalIgnoreCase) >= 0 &&
            normalizedUrl.EndsWith("/trunk/load/modified-001.txt", StringComparison.OrdinalIgnoreCase)) {
          Console.WriteLine("modified load item load/modified-001.txt by M7j3");
          return 0;
        }
        if (normalizedUrl.IndexOf("commit-changelist-fixture", StringComparison.OrdinalIgnoreCase) >= 0 &&
            normalizedUrl.EndsWith("/trunk/src/tracked.txt", StringComparison.OrdinalIgnoreCase)) {
          Console.WriteLine("modified by M7j3");
          return 0;
        }
        if (normalizedUrl.IndexOf("update-to-revision-fixture", StringComparison.OrdinalIgnoreCase) >= 0 &&
            normalizedUrl.EndsWith("/trunk/top-level.txt", StringComparison.OrdinalIgnoreCase)) {
          Console.WriteLine("updated by Beta-C r2");
          return 0;
        }
        var localPath = LocalPathFromFileUrl(args[1]);
        if (File.Exists(localPath)) {
          Console.Write(File.ReadAllText(localPath));
          return 0;
        }
        Console.Error.WriteLine("svn: warning: W160013: path not found");
        return 1;
      }
      if (exe == "svn.exe" && args.Length >= 4 && args[0] == "log") {
        var normalizedUrl = "";
        for (var i = 1; i < args.Length; i++) {
          if (args[i].StartsWith("file:", StringComparison.OrdinalIgnoreCase)) {
            normalizedUrl = args[i].Replace('\\', '/');
            break;
          }
        }
        if (normalizedUrl.Length == 0) {
          normalizedUrl = args[3].Replace('\\', '/');
        }
        if (normalizedUrl.IndexOf("commit-all-fixture", StringComparison.OrdinalIgnoreCase) >= 0 &&
            normalizedUrl.EndsWith("/trunk/src/tracked.txt", StringComparison.OrdinalIgnoreCase)) {
          Console.WriteLine("------------------------------------------------------------------------");
          Console.WriteLine("r2 | SubversionR fake | 2026-06-25 | 1 line");
          Console.WriteLine("");
          Console.WriteLine("commit all eligible changed file resources for the repository input message");
          Console.WriteLine("------------------------------------------------------------------------");
          return 0;
        }
        if (normalizedUrl.IndexOf("commit-selected-fixture", StringComparison.OrdinalIgnoreCase) >= 0 &&
            normalizedUrl.EndsWith("/trunk/src/tracked.txt", StringComparison.OrdinalIgnoreCase)) {
          Console.WriteLine("------------------------------------------------------------------------");
          Console.WriteLine("r2 | SubversionR fake | 2026-06-25 | 1 line");
          Console.WriteLine("");
          Console.WriteLine("commit selected SCM resource from the repository input message");
          Console.WriteLine("------------------------------------------------------------------------");
          return 0;
        }
        if (normalizedUrl.IndexOf("commit-selected-multi-selection-fixture", StringComparison.OrdinalIgnoreCase) >= 0 &&
            normalizedUrl.EndsWith("/trunk/src/tracked.txt", StringComparison.OrdinalIgnoreCase)) {
          Console.WriteLine("------------------------------------------------------------------------");
          Console.WriteLine("r2 | SubversionR fake | 2026-06-25 | 1 line");
          Console.WriteLine("");
          Console.WriteLine("commit selected SCM resources from a Source Control multi-selection");
          Console.WriteLine("------------------------------------------------------------------------");
          return 0;
        }
        if (normalizedUrl.IndexOf("commit-changelist-fixture", StringComparison.OrdinalIgnoreCase) >= 0 &&
            normalizedUrl.EndsWith("/trunk/src/tracked.txt", StringComparison.OrdinalIgnoreCase)) {
          Console.WriteLine("------------------------------------------------------------------------");
          Console.WriteLine("r2 | SubversionR fake | 2026-06-25 | 1 line");
          Console.WriteLine("");
          Console.WriteLine("commit selected SVN changelist from the repository input message");
          Console.WriteLine("------------------------------------------------------------------------");
          return 0;
        }
        if (normalizedUrl.IndexOf("branch-create-fixture", StringComparison.OrdinalIgnoreCase) >= 0 &&
            normalizedUrl.EndsWith("/branches/beta-installed-e2e", StringComparison.OrdinalIgnoreCase)) {
          Console.WriteLine("------------------------------------------------------------------------");
          Console.WriteLine("r2 | SubversionR fake | 2026-06-25 | 1 line");
          Console.WriteLine("Changed paths:");
          Console.WriteLine("   A /branches/beta-installed-e2e (from /trunk:1)");
          Console.WriteLine("");
          Console.WriteLine("Create installed Beta branch");
          Console.WriteLine("------------------------------------------------------------------------");
          return 0;
        }
        Console.WriteLine("------------------------------------------------------------------------");
        Console.WriteLine("r1 | SubversionR fake | 2026-06-25 | 1 line");
        Console.WriteLine("");
        Console.WriteLine("seed M7j3 fixture");
        Console.WriteLine("------------------------------------------------------------------------");
        return 0;
      }
      if (exe == "svn.exe" && args.Length >= 1 && args[0] == "commit") {
        return 0;
      }
      if (exe == "svn.exe" && args.Length >= 1 && args[0] == "update") {
        return 0;
      }
      Console.Error.WriteLine("Unsupported fake SVN invocation: " + exe + " " + string.Join(" ", args));
      return 2;
    } catch (Exception ex) {
      Console.Error.WriteLine(ex.ToString());
      return 1;
    }
  }

  private static string LocalPathFromFileUrl(string url) {
    if (!url.StartsWith("file:///", StringComparison.OrdinalIgnoreCase)) {
      return url;
    }
    return new Uri(url).LocalPath;
  }

  private static void CreateDirectory(string path) {
    Directory.CreateDirectory(path);
  }

  private static void WriteText(string path, string contents) {
    File.WriteAllText(path, contents);
  }

  private static string FindWorkingCopyRoot(string path) {
    var current = File.Exists(path) ? Path.GetDirectoryName(path) : path;
    while (!String.IsNullOrWhiteSpace(current)) {
      if (Directory.Exists(Path.Combine(current, ".svn"))) {
        return current;
      }
      current = Path.GetDirectoryName(current);
    }
    return Path.GetDirectoryName(path) ?? path;
  }

  private static void CopyDirectory(string sourceDirectory, string destinationDirectory) {
    Directory.CreateDirectory(destinationDirectory);
    foreach (var directory in Directory.GetDirectories(sourceDirectory, "*", SearchOption.AllDirectories)) {
      var relative = directory.Substring(sourceDirectory.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
      Directory.CreateDirectory(Path.Combine(destinationDirectory, relative));
    }
    foreach (var file in Directory.GetFiles(sourceDirectory, "*", SearchOption.AllDirectories)) {
      var relative = file.Substring(sourceDirectory.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
      var destination = Path.Combine(destinationDirectory, relative);
      Directory.CreateDirectory(Path.GetDirectoryName(destination));
      File.Copy(file, destination, true);
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

$tempRoot = Join-Path $repoRoot "target\tests\release-installed-source-control-ui-e2e-scripts\s $([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  Assert-True (Test-Path -LiteralPath $workflowScript -PathType Leaf) "test-vscode-installed-source-control-ui-e2e.ps1 should exist."
  Assert-True (Test-Path -LiteralPath $driverScript -PathType Leaf) "capture-vscode-renderer-ui.mjs should exist."

  $rootPackage = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  Assert-True ($rootPackage.scripts."release:test-installed-source-control-ui-e2e-scripts".Contains("release-installed-source-control-ui-e2e-scripts.tests.ps1")) "Root package should expose M7j3 installed Source Control UI E2E script tests."
  Assert-True ($rootPackage.scripts."release:test-installed-source-control-ui-e2e:win32-x64".Contains("test-vscode-installed-source-control-ui-e2e.ps1")) "Root package should expose the installed Source Control UI E2E gate."
  Assert-True ($rootPackage.scripts."release:test-installed-source-control-ui-e2e:win32-x64".Contains("capture-vscode-renderer-ui.mjs")) "Installed Source Control UI E2E gate should require the renderer capture driver."
  Assert-True ($rootPackage.scripts."release:test-installed-source-control-ui-e2e:win32-x64".Contains("%SUBVERSIONR_CODE_CLI%")) "Installed Source Control UI E2E gate should require an explicit Code CLI path."
  Assert-True ($rootPackage.scripts."release:test-installed-source-control-ui-e2e:win32-x64".Contains(".cache/native/stage/subversion-win-x64/bin")) "Installed Source Control UI E2E gate should require the source-built SVN fixture tools root."

  $vsixPath = Join-Path $tempRoot "subversionr-win32-x64-0.2.0.vsix"
  New-TestVsix -Path $vsixPath -Version "0.2.0"
  $fakeCodeCliPath = Join-Path $tempRoot "fake-code\code.cmd"
  New-FakeCodeCli -Path $fakeCodeCliPath
  $fakeDriverPath = Join-Path $tempRoot "fake-driver\fake-renderer-capture.mjs"
  New-FakeRendererCaptureDriver -Path $fakeDriverPath
  $fakeSvnRoot = Join-Path $tempRoot "fake-svn"
  New-FakeSvnTools -Root $fakeSvnRoot
  $fixtureRoot = Join-Path $tempRoot "installed-source-control-ui-e2e\win32-x64"
  $evidencePath = Join-Path $tempRoot "evidence\installed-source-control-ui-e2e.json"

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $workflowScript `
    -Target win32-x64 `
    -VsixPath $vsixPath `
    -CodeCliPath $fakeCodeCliPath `
    -SvnToolsRoot $fakeSvnRoot `
    -RendererCaptureDriverPath $fakeDriverPath `
    -FixtureRoot $fixtureRoot `
    -EvidencePath $evidencePath `
    -RemoteDebuggingPort 32146
  if ($LASTEXITCODE -ne 0) {
    throw "test-vscode-installed-source-control-ui-e2e.ps1 failed with exit code $LASTEXITCODE."
  }

  $report = Get-Content -Raw -LiteralPath $evidencePath | ConvertFrom-Json
  Assert-Equal "subversionr.release.installed-source-control-ui-e2e.win32-x64.v1" $report.schema "Installed Source Control UI E2E evidence should use the M7j3 schema."
  Assert-Equal "False" ([string]$report.publicReadinessClaim) "Installed Source Control UI E2E evidence must not claim public readiness."
  Assert-Equal "win32-x64" $report.target "Installed Source Control UI E2E evidence should record the target."
  Assert-Equal "hitsuki-ban.subversionr" $report.extension.id "Installed Source Control UI E2E evidence should record the extension id."
  Assert-Equal "complete" $report.extension.harnessPhase "Installed Source Control UI E2E evidence should record a completed harness phase."
  Assert-True (@($report.extension.invokedCommands | Where-Object { $_ -eq "subversionr.refreshResource" }).Count -eq 1) "Installed Source Control UI E2E evidence should record the restored-path Refresh Resource command invocation."
  Assert-True (@($report.extension.invokedCommands | Where-Object { $_ -eq "subversionr.lockResource" }).Count -eq 1) "Installed Source Control UI E2E evidence should record the Lock command invocation."
  Assert-True (@($report.extension.invokedCommands | Where-Object { $_ -eq "subversionr.unlockResource" }).Count -eq 1) "Installed Source Control UI E2E evidence should record the Unlock command invocation."
  Assert-True (@($report.extension.invokedCommands | Where-Object { $_ -eq "subversionr.branchCreateRepository" }).Count -eq 1) "Installed Source Control UI E2E evidence should record the Branch/Tag create command invocation."
  Assert-True (@($report.extension.invokedCommands | Where-Object { $_ -eq "subversionr.switchRepository" }).Count -eq 1) "Installed Source Control UI E2E evidence should record the Switch command invocation."
  Assert-Equal "True" ([string]$report.extension.afterActive) "Installed Source Control UI E2E evidence should prove SubversionR was active before UI validation."
  Assert-Equal "True" ([string]$report.extension.hasInstalledSourceControlUiE2eOpenReportCommand) "Installed Source Control UI E2E evidence should prove hidden open command registration."
  Assert-Equal "True" ([string]$report.extension.hasInstalledSourceControlUiE2eFreshnessReportCommand) "Installed Source Control UI E2E evidence should prove hidden freshness command registration."
  Assert-Equal "True" ([string]$report.extension.hasInstalledSourceControlUiE2eArmDirtyGenerationCancellationCommand) "Installed Source Control UI E2E evidence should prove hidden dirty-generation cancellation arm command registration."
  Assert-Equal "True" ([string]$report.extension.hasInstalledSourceControlUiE2eDirtyGenerationCancellationReportCommand) "Installed Source Control UI E2E evidence should prove hidden dirty-generation cancellation report command registration."
  Assert-Equal "True" ([string]$report.extension.hasInstalledSourceControlUiE2eDirtyEventCommand) "Installed Source Control UI E2E evidence should prove hidden dirty-event diagnostic command registration."
  Assert-Equal "True" ([string]$report.extension.hasInstalledSourceControlUiE2eCloseReportCommand) "Installed Source Control UI E2E evidence should prove hidden close command registration."
  Assert-Equal "True" ([string]$report.extension.hasInstalledRepositoryLifecycleReportCommand) "Installed Source Control UI E2E evidence should prove hidden lifecycle command registration."
  Assert-Equal "True" ([string]$report.extension.hasDeleteUnversionedResourceCommand) "Installed Source Control UI E2E evidence should prove Delete Unversioned command registration."
  Assert-Equal "True" ([string]$report.extension.hasDeleteAllUnversionedResourcesCommand) "Installed Source Control UI E2E evidence should prove Delete All Unversioned Items command registration."
  Assert-Equal "True" ([string]$report.extension.hasRemoveResourceCommand) "Installed Source Control UI E2E evidence should prove Remove command registration."
  Assert-Equal "True" ([string]$report.extension.hasRemoveResourceKeepLocalCommand) "Installed Source Control UI E2E evidence should prove Keep-local Remove command registration."
  Assert-Equal "True" ([string]$report.extension.hasMoveResourceCommand) "Installed Source Control UI E2E evidence should prove Move command registration."
  Assert-Equal "True" ([string]$report.extension.hasRevertResourceCommand) "Installed Source Control UI E2E evidence should prove Revert command registration."
  Assert-Equal "True" ([string]$report.extension.hasCleanupRepositoryCommand) "Installed Source Control UI E2E evidence should prove Cleanup command registration."
  Assert-Equal "True" ([string]$report.extension.hasRefreshRepositoryCommand) "Installed Source Control UI E2E evidence should prove Refresh command registration."
  Assert-Equal "True" ([string]$report.extension.hasUpdateRepositoryCommand) "Installed Source Control UI E2E evidence should prove Update command registration."
  Assert-Equal "True" ([string]$report.extension.hasUpdateToRevisionCommand) "Installed Source Control UI E2E evidence should prove Update to Revision command registration."
  Assert-Equal "True" ([string]$report.extension.hasAddResourceCommand) "Installed Source Control UI E2E evidence should prove Add command registration."
  Assert-Equal "True" ([string]$report.extension.hasResolveResourceCommand) "Installed Source Control UI E2E evidence should prove Resolve command registration."
  Assert-Equal "True" ([string]$report.extension.hasCommitAllCommand) "Installed Source Control UI E2E evidence should prove Commit All command registration."
  Assert-Equal "True" ([string]$report.extension.hasCommitResourceCommand) "Installed Source Control UI E2E evidence should prove Commit Selected command registration."
  Assert-Equal "True" ([string]$report.extension.hasAddToIgnoreResourceCommand) "Installed Source Control UI E2E evidence should prove Add to Ignore command registration."
  Assert-Equal "True" ([string]$report.extension.hasLockResourceCommand) "Installed Source Control UI E2E evidence should prove Lock command registration."
  Assert-Equal "True" ([string]$report.extension.hasUnlockResourceCommand) "Installed Source Control UI E2E evidence should prove Unlock command registration."
  Assert-Equal "True" ([string]$report.extension.hasSetResourceChangelistCommand) "Installed Source Control UI E2E evidence should prove Set Changelist command registration."
  Assert-Equal "True" ([string]$report.extension.hasClearResourceChangelistCommand) "Installed Source Control UI E2E evidence should prove Clear Changelist command registration."
  Assert-Equal "True" ([string]$report.extension.hasCommitChangelistCommand) "Installed Source Control UI E2E evidence should prove Commit Changelist command registration."
  Assert-Equal "True" ([string]$report.extension.hasRevertChangelistCommand) "Installed Source Control UI E2E evidence should prove Revert Changelist command registration."
  Assert-Equal "True" ([string]$report.extension.hasInstalledSourceControlUiE2eSetInputMessageCommand) "Installed Source Control UI E2E evidence should prove the hidden Commit All input-message diagnostic command registration."
  Assert-Equal "True" ([string]$report.extension.hasCheckoutRepositoryCommand) "Installed Source Control UI E2E evidence should prove Checkout Repository command registration."
  Assert-Equal "True" ([string]$report.extension.hasBranchCreateRepositoryCommand) "Installed Source Control UI E2E evidence should prove Branch/Tag create command registration."
  Assert-Equal "True" ([string]$report.extension.hasSwitchRepositoryCommand) "Installed Source Control UI E2E evidence should prove Switch command registration."
  Assert-Equal "subversionr.installedSourceControlUiE2eOpenReport" $report.sourceControlUiOpenReport.kind "Installed Source Control UI E2E evidence should include an open report."
  Assert-Equal "subversionr.commitAll" $report.sourceControlUiOpenReport.sourceControl.inputBox.acceptInputCommand "Open report should expose the SourceControl input accept command."
  Assert-Equal $report.sourceControlUiOpenReport.repository.repositoryId (@($report.sourceControlUiOpenReport.sourceControl.inputBox.acceptInputCommandArguments)[0]) "Open report should expose the repository-scoped SourceControl input accept command argument."
  Assert-Equal "subversionr.installedSourceControlUiE2eCheckoutWorkflow" $report.sourceControlUiCheckoutWorkflow.kind "Installed Source Control UI E2E evidence should include a Checkout Repository workflow report."
  Assert-Equal "subversionr.checkoutRepository" $report.sourceControlUiCheckoutWorkflow.command.command "Checkout workflow should execute the installed Checkout Repository command."
  Assert-Equal "head" $report.sourceControlUiCheckoutWorkflow.request.revision "Checkout workflow should request HEAD revision."
  Assert-Equal "infinity" $report.sourceControlUiCheckoutWorkflow.request.depth "Checkout workflow should request infinity depth."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutWorkflow.request.ignoreExternals) "Checkout workflow should explicitly ignore externals for the Beta installed happy path."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutWorkflow.assertions.workingCopyCreated) "Checkout workflow should prove the target working copy was created."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutWorkflow.assertions.repositoryOpenedAfterCheckout) "Checkout workflow should prove the checked-out working copy was opened."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutWorkflow.assertions.sourceControlProjectionAvailable) "Checkout workflow should prove Source Control projection is available after checkout."
  Assert-Equal "subversionr.installedSourceControlUiE2eCheckoutRepositoryOracle" $report.checkoutRepositoryOracle.kind "Checkout repository oracle should be published in final evidence."
  Assert-Equal "True" ([string]$report.checkoutRepositoryOracle.checkedOutBaselineContentMatched) "Checkout repository oracle should prove the checked-out file content matches the repository baseline."
  Assert-Equal "subversionr.installedSourceControlUiE2eCheckoutExistingDirectoryWorkflow" $report.sourceControlUiCheckoutExistingDirectoryWorkflow.kind "Installed Source Control UI E2E evidence should include a Checkout existing-directory workflow report."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutExistingDirectoryWorkflow.assertions.existingDirectoryTargetAccepted) "Checkout existing-directory workflow should prove a pre-existing target directory was accepted."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutExistingDirectoryWorkflow.assertions.localDirectoryEntryPreserved) "Checkout existing-directory workflow should prove the pre-existing local file stayed on disk after checkout."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutExistingDirectoryWorkflow.assertions.localOnlyFileProjectedUnversioned) "Checkout existing-directory workflow should prove the pre-existing local file was projected as unversioned after checkout."
  Assert-True ([string]$report.sourceControlUiCheckoutExistingDirectoryWorkflow.target.localOnlyPath -like "*local-only-before-checkout.txt") "Checkout existing-directory workflow should record the pre-existing local-only file path."
  Assert-Equal "local-only-before-checkout.txt" (@($report.sourceControlUiCheckoutExistingDirectoryWorkflow.target.directoryEntriesBefore | Where-Object { $_.name -eq "local-only-before-checkout.txt" })[0].name) "Checkout existing-directory workflow should record the local-only file before checkout."
  Assert-Equal "local-only-before-checkout.txt" (@($report.sourceControlUiCheckoutExistingDirectoryWorkflow.target.directoryEntriesAfter | Where-Object { $_.name -eq "local-only-before-checkout.txt" })[0].name) "Checkout existing-directory workflow should record the local-only file after checkout."
  Assert-Equal "subversionr.unversioned" $report.sourceControlUiCheckoutExistingDirectoryWorkflow.localOnlyResource.contextValue "Checkout existing-directory workflow should publish the local-only file as an unversioned Source Control resource."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.checkoutExistingDirectoryUrlPromptCapture.schema "Installed Source Control UI E2E evidence should include Checkout existing-directory URL prompt capture evidence."
  Assert-Equal "True" ([string]$report.checkoutExistingDirectoryUrlPromptCapture.assertions.inputTextSubmitted) "Checkout existing-directory URL prompt capture should submit the repository URL."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.checkoutExistingDirectoryTargetPromptCapture.schema "Installed Source Control UI E2E evidence should include Checkout existing-directory target prompt capture evidence."
  Assert-Equal "True" ([string]$report.checkoutExistingDirectoryTargetPromptCapture.assertions.inputTextSubmitted) "Checkout existing-directory target prompt capture should submit the pre-existing target directory path."
  Assert-Equal "True" ([string]$report.checkoutExistingDirectoryRevisionPromptCapture.assertions.quickPickItemSelected) "Checkout existing-directory revision prompt capture should choose HEAD."
  Assert-Equal "True" ([string]$report.checkoutExistingDirectoryDepthPromptCapture.assertions.quickPickItemSelected) "Checkout existing-directory depth prompt capture should choose Infinity."
  Assert-Equal "True" ([string]$report.checkoutExistingDirectoryExternalsPromptCapture.assertions.quickPickItemSelected) "Checkout existing-directory externals prompt capture should choose Ignore externals."
  Assert-Equal "subversionr.installedSourceControlUiE2eCheckoutExistingDirectoryObstructionWorkflow" $report.sourceControlUiCheckoutExistingDirectoryObstructionWorkflow.kind "Installed Source Control UI E2E evidence should include a Checkout existing-directory obstruction workflow report."
  Assert-Equal "subversionr.checkoutRepository" $report.sourceControlUiCheckoutExistingDirectoryObstructionWorkflow.command.command "Checkout existing-directory obstruction workflow should execute the installed Checkout Repository command."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutExistingDirectoryObstructionWorkflow.assertions.commandExecuted) "Checkout existing-directory obstruction workflow should prove the command completed under libsvn checkout semantics."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutExistingDirectoryObstructionWorkflow.assertions.workingCopyCreated) "Checkout existing-directory obstruction workflow should prove libsvn created working-copy metadata despite the obstruction."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutExistingDirectoryObstructionWorkflow.assertions.obstructionPreserved) "Checkout existing-directory obstruction workflow should prove the obstructing local file stayed intact."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutExistingDirectoryObstructionWorkflow.assertions.treeConflictProjected) "Checkout existing-directory obstruction workflow should prove the obstructing node was projected as an SVN conflict."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutExistingDirectoryObstructionWorkflow.assertions.localOnlyFileProjectedUnversioned) "Checkout existing-directory obstruction workflow should prove unrelated local-only files stay projected as unversioned."
  Assert-Equal "subversionr.conflicted" $report.sourceControlUiCheckoutExistingDirectoryObstructionWorkflow.conflictResource.contextValue "Checkout existing-directory obstruction workflow should publish the obstructing path as a conflicted Source Control resource."
  Assert-Equal "src" $report.sourceControlUiCheckoutExistingDirectoryObstructionWorkflow.conflictResource.path "Checkout existing-directory obstruction workflow should target the obstructing src path."
  Assert-Equal "subversionr.installedSourceControlUiE2eCheckoutExistingDirectoryObstructionWorkingCopyOracle" $report.checkoutExistingDirectoryObstructionWorkingCopyOracle.kind "Checkout existing-directory obstruction working-copy oracle should be published in final evidence."
  Assert-Equal "True" ([string]$report.checkoutExistingDirectoryObstructionWorkingCopyOracle.treeConflictPresent) "Checkout existing-directory obstruction working-copy oracle should prove SVN status reports the tree conflict."
  Assert-Equal "True" ([string]$report.checkoutExistingDirectoryObstructionWorkingCopyOracle.obstructionPreserved) "Checkout existing-directory obstruction working-copy oracle should prove the local obstruction was preserved."
  Assert-Equal "subversionr.installedSourceControlUiE2eCheckoutCancellationWorkflow" $report.sourceControlUiCheckoutCancellationWorkflow.kind "Installed Source Control UI E2E evidence should include a Checkout Repository cancellation workflow report."
  Assert-Equal "subversionr.checkoutRepository" $report.sourceControlUiCheckoutCancellationWorkflow.command.command "Checkout cancellation workflow should execute the installed Checkout Repository command."
  Assert-Equal "Escape" $report.sourceControlUiCheckoutCancellationWorkflow.prompt.cancelKey "Checkout cancellation workflow should record Escape as the QuickInput cancellation key."
  Assert-Equal "quickInput" $report.sourceControlUiCheckoutCancellationWorkflow.prompt.rendererCaptureExpectations.cancelSurface "Checkout cancellation workflow should require QuickInput renderer cancellation evidence."
  Assert-Equal "subversionr.installedSourceControlUiE2eMissingCurrentSurfaceProbe" $report.sourceControlUiCheckoutCancellationWorkflow.currentSurfaceProbes.baselineBefore.kind "Checkout cancellation workflow should prove the baseline repository stayed closed before cancellation."
  Assert-Equal "subversionr.installedSourceControlUiE2eMissingCurrentSurfaceProbe" $report.sourceControlUiCheckoutCancellationWorkflow.currentSurfaceProbes.baselineAfter.kind "Checkout cancellation workflow should prove the baseline repository stayed closed after cancellation."
  Assert-Equal "subversionr.installedSourceControlUiE2eMissingCurrentSurfaceProbe" $report.sourceControlUiCheckoutCancellationWorkflow.currentSurfaceProbes.targetBefore.kind "Checkout cancellation workflow should prove the checkout target had no Source Control surface before cancellation."
  Assert-Equal "subversionr.installedSourceControlUiE2eMissingCurrentSurfaceProbe" $report.sourceControlUiCheckoutCancellationWorkflow.currentSurfaceProbes.targetAfter.kind "Checkout cancellation workflow should prove the checkout target had no Source Control surface after cancellation."
  Assert-Equal "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CURRENT_SESSION_MISSING" $report.sourceControlUiCheckoutCancellationWorkflow.currentSurfaceProbes.targetAfter.error.code "Checkout cancellation workflow should prove the checkout target current-surface probe failed with the missing-session diagnostic."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutCancellationWorkflow.currentSurfaceProbes.targetAfter.assertions.currentSessionMissing) "Checkout cancellation workflow should prove no target repository session opened after cancellation."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutCancellationWorkflow.currentSurfaceProbes.targetAfter.assertions.sourceControlProjectionAbsent) "Checkout cancellation workflow should prove no target Source Control projection appeared after cancellation."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutCancellationWorkflow.assertions.commandCancelled) "Checkout cancellation workflow should prove the command returned through prompt cancellation."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutCancellationWorkflow.assertions.targetAbsentAfter) "Checkout cancellation workflow should prove the target working-copy root was not created."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutCancellationWorkflow.assertions.svnMetadataAbsentAfter) "Checkout cancellation workflow should prove no .svn metadata was created."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutCancellationWorkflow.assertions.repositoryNotOpenedAfterCancellation) "Checkout cancellation workflow should prove cancellation did not open a checkout repository."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutCancellationWorkflow.assertions.sourceControlProjectionUnchanged) "Checkout cancellation workflow should prove SourceControl projection stayed unchanged after cancellation."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.checkoutCancellationPromptCapture.schema "Installed Source Control UI E2E evidence should include Checkout cancellation prompt capture evidence."
  Assert-Equal "Escape" $report.checkoutCancellationPromptCapture.interaction.cancelledKey "Checkout cancellation prompt capture should cancel the URL QuickInput with Escape."
  Assert-Equal "quickInput" $report.checkoutCancellationPromptCapture.interaction.surface "Checkout cancellation prompt capture should prove the QuickInput surface was cancelled."
  Assert-Equal "True" ([string]$report.checkoutCancellationPromptCapture.assertions.quickInputCancelled) "Checkout cancellation prompt capture should prove QuickInput cancellation completed."
  Assert-Equal "subversionr.installedSourceControlUiE2eCheckoutExistingTargetFailureWorkflow" $report.sourceControlUiCheckoutExistingTargetFailureWorkflow.kind "Installed Source Control UI E2E evidence should include a Checkout existing-target failure workflow report."
  Assert-Equal "SVN_REPOSITORY_CHECKOUT_FAILED" $report.sourceControlUiCheckoutExistingTargetFailureWorkflow.failure.code "Checkout existing-target failure workflow should record the native checkout failure code."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutExistingTargetFailureWorkflow.assertions.commandFailed) "Checkout existing-target failure workflow should prove the checkout command failed."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutExistingTargetFailureWorkflow.assertions.obstructingTargetFilePreserved) "Checkout existing-target failure workflow should prove the obstructing target file stayed intact."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutExistingTargetFailureWorkflow.assertions.svnMetadataAbsentAfter) "Checkout existing-target failure workflow should prove no .svn metadata was created."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutExistingTargetFailureWorkflow.assertions.fixtureDirectoryUnchanged) "Checkout existing-target failure workflow should prove the parent fixture directory stayed unchanged."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutExistingTargetFailureWorkflow.assertions.repositoryNotOpenedAfterFailure) "Checkout existing-target failure workflow should prove the failed checkout did not open a repository."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutExistingTargetFailureWorkflow.assertions.sourceControlProjectionUnchanged) "Checkout existing-target failure workflow should prove SourceControl projection stayed unchanged after failure."
  Assert-True ($report.sourceControlUiCheckoutExistingTargetFailureWorkflow.target.sha256Before -match '^[a-f0-9]{64}$') "Checkout existing-target failure workflow should hash the obstructing file before checkout."
  Assert-Equal $report.sourceControlUiCheckoutExistingTargetFailureWorkflow.target.sha256Before $report.sourceControlUiCheckoutExistingTargetFailureWorkflow.target.sha256After "Checkout existing-target failure workflow should prove the obstructing file hash stayed unchanged."
  Assert-True ([string]$report.sourceControlUiCheckoutExistingTargetFailureWorkflow.target.parentSvnMetadataPath -like "*.svn") "Checkout existing-target failure workflow should record the parent fixture SVN metadata path."
  Assert-Equal "wc" (@($report.sourceControlUiCheckoutExistingTargetFailureWorkflow.target.parentDirectoryEntriesBefore)[0].name) "Checkout existing-target failure workflow should record the obstructing file as the only parent directory entry before checkout."
  Assert-Equal "wc" (@($report.sourceControlUiCheckoutExistingTargetFailureWorkflow.target.parentDirectoryEntriesAfter)[0].name) "Checkout existing-target failure workflow should record the obstructing file as the only parent directory entry after checkout."
  Assert-Equal "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CURRENT_SESSION_MISSING" $report.sourceControlUiCheckoutExistingTargetFailureWorkflow.currentSurfaceProbes.targetAfter.error.code "Checkout existing-target failure workflow should prove the failed target current-surface probe stayed missing."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.checkoutExistingTargetFailureUrlPromptCapture.schema "Installed Source Control UI E2E evidence should include Checkout existing-target failure URL prompt capture evidence."
  Assert-Equal "True" ([string]$report.checkoutExistingTargetFailureUrlPromptCapture.assertions.inputTextSubmitted) "Checkout existing-target failure URL prompt capture should submit the repository URL."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.checkoutExistingTargetFailureTargetPromptCapture.schema "Installed Source Control UI E2E evidence should include Checkout existing-target failure target prompt capture evidence."
  Assert-Equal "True" ([string]$report.checkoutExistingTargetFailureTargetPromptCapture.assertions.inputTextSubmitted) "Checkout existing-target failure target prompt capture should submit the obstructing target path."
  Assert-Equal "True" ([string]$report.checkoutExistingTargetFailureRevisionPromptCapture.assertions.quickPickItemSelected) "Checkout existing-target failure revision prompt capture should choose HEAD."
  Assert-Equal "True" ([string]$report.checkoutExistingTargetFailureDepthPromptCapture.assertions.quickPickItemSelected) "Checkout existing-target failure depth prompt capture should choose Infinity."
  Assert-Equal "True" ([string]$report.checkoutExistingTargetFailureExternalsPromptCapture.assertions.quickPickItemSelected) "Checkout existing-target failure externals prompt capture should choose Ignore externals."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.checkoutExistingTargetFailureNotificationCapture.schema "Installed Source Control UI E2E evidence should include Checkout existing-target failure notification capture evidence."
  Assert-Equal "True" ([string]$report.checkoutExistingTargetFailureNotificationCapture.assertions.domRequiredTokensPresent) "Checkout existing-target failure notification capture should prove the failure notification text rendered before cleanup."
  Assert-Equal "True" ([string]$report.checkoutExistingTargetFailureNotificationCapture.assertions.accessibilityRequiredTokensPresent) "Checkout existing-target failure notification capture should prove the failure notification was accessibility-visible before cleanup."
  Assert-Equal "notifications.clearAll" $report.sourceControlUiCheckoutExistingTargetFailureWorkflow.notification.cleanup.command "Checkout existing-target failure workflow should clear the failure notification through the explicit VS Code command."
  Assert-Equal "subversionr.installedSourceControlUiE2eCheckoutInvalidUrlFailureWorkflow" $report.sourceControlUiCheckoutInvalidUrlFailureWorkflow.kind "Installed Source Control UI E2E evidence should include a Checkout invalid URL failure workflow report."
  Assert-Equal "SVN_REPOSITORY_CHECKOUT_FAILED" $report.sourceControlUiCheckoutInvalidUrlFailureWorkflow.failure.code "Checkout invalid URL failure workflow should record the native checkout failure code."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutInvalidUrlFailureWorkflow.assertions.commandFailed) "Checkout invalid URL failure workflow should prove the checkout command failed."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutInvalidUrlFailureWorkflow.assertions.targetAbsentAfter) "Checkout invalid URL failure workflow should prove the target working-copy root was not created."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutInvalidUrlFailureWorkflow.assertions.svnMetadataAbsentAfter) "Checkout invalid URL failure workflow should prove no .svn metadata was created."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutInvalidUrlFailureWorkflow.assertions.parentDirectoryUnchanged) "Checkout invalid URL failure workflow should prove the target parent directory stayed unchanged."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutInvalidUrlFailureWorkflow.assertions.repositoryNotOpenedAfterFailure) "Checkout invalid URL failure workflow should prove the failed invalid URL checkout did not open a repository."
  Assert-Equal "True" ([string]$report.sourceControlUiCheckoutInvalidUrlFailureWorkflow.assertions.sourceControlProjectionUnchanged) "Checkout invalid URL failure workflow should prove SourceControl projection stayed unchanged after failure."
  Assert-Equal "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CURRENT_SESSION_MISSING" $report.sourceControlUiCheckoutInvalidUrlFailureWorkflow.currentSurfaceProbes.targetAfter.error.code "Checkout invalid URL failure workflow should prove the failed target current-surface probe stayed missing."
  Assert-True ([string]$report.sourceControlUiCheckoutInvalidUrlFailureWorkflow.request.url -like "file://*/does-not-exist") "Checkout invalid URL failure workflow should use a deterministic missing local-file URL fixture."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.checkoutInvalidUrlFailureUrlPromptCapture.schema "Installed Source Control UI E2E evidence should include Checkout invalid URL prompt capture evidence."
  Assert-Equal "True" ([string]$report.checkoutInvalidUrlFailureUrlPromptCapture.assertions.inputTextSubmitted) "Checkout invalid URL prompt capture should submit the invalid repository URL."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.checkoutInvalidUrlFailureTargetPromptCapture.schema "Installed Source Control UI E2E evidence should include Checkout invalid URL target prompt capture evidence."
  Assert-Equal "True" ([string]$report.checkoutInvalidUrlFailureTargetPromptCapture.assertions.inputTextSubmitted) "Checkout invalid URL target prompt capture should submit the target path."
  Assert-Equal "True" ([string]$report.checkoutInvalidUrlFailureRevisionPromptCapture.assertions.quickPickItemSelected) "Checkout invalid URL revision prompt capture should choose HEAD."
  Assert-Equal "True" ([string]$report.checkoutInvalidUrlFailureDepthPromptCapture.assertions.quickPickItemSelected) "Checkout invalid URL depth prompt capture should choose Infinity."
  Assert-Equal "True" ([string]$report.checkoutInvalidUrlFailureExternalsPromptCapture.assertions.quickPickItemSelected) "Checkout invalid URL externals prompt capture should choose Ignore externals."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.checkoutInvalidUrlFailureNotificationCapture.schema "Installed Source Control UI E2E evidence should include Checkout invalid URL notification capture evidence."
  Assert-Equal "True" ([string]$report.checkoutInvalidUrlFailureNotificationCapture.assertions.domRequiredTokensPresent) "Checkout invalid URL notification capture should prove the failure notification text rendered before cleanup."
  Assert-Equal "True" ([string]$report.checkoutInvalidUrlFailureNotificationCapture.assertions.accessibilityRequiredTokensPresent) "Checkout invalid URL notification capture should prove the failure notification was accessibility-visible before cleanup."
  Assert-Equal "notifications.clearAll" $report.sourceControlUiCheckoutInvalidUrlFailureWorkflow.notification.cleanup.command "Checkout invalid URL workflow should clear the failure notification through the explicit VS Code command."
  Assert-Equal "subversionr.installedSourceControlUiE2eUpdateToRevisionWorkflow" $report.sourceControlUiUpdateToRevisionWorkflow.kind "Installed Source Control UI E2E evidence should include an Update to Revision workflow report."
  Assert-Equal "subversionr.updateToRevision" $report.sourceControlUiUpdateToRevisionWorkflow.command.command "Update to Revision workflow should execute the installed Update to Revision command."
  Assert-Equal "2" ([string]$report.sourceControlUiUpdateToRevisionWorkflow.request.revision) "Update to Revision workflow should request the fixture r2 revision."
  Assert-Equal "files" $report.sourceControlUiUpdateToRevisionWorkflow.request.depth "Update to Revision workflow should request files depth."
  Assert-Equal "True" ([string]$report.sourceControlUiUpdateToRevisionWorkflow.request.depthIsSticky) "Update to Revision workflow should request sticky depth."
  Assert-Equal "False" ([string]$report.sourceControlUiUpdateToRevisionWorkflow.request.ignoreExternals) "Update to Revision workflow should request Include externals."
  Assert-Equal "True" ([string]$report.sourceControlUiUpdateToRevisionWorkflow.assertions.updatedRevisionContentApplied) "Update to Revision workflow should prove r2 content was applied."
  Assert-Equal "True" ([string]$report.sourceControlUiUpdateToRevisionWorkflow.assertions.postUpdateReconcileCompleted) "Update to Revision workflow should prove post-update Source Control reconciliation."
  Assert-Equal "True" ([string]$report.sourceControlUiUpdateToRevisionWorkflow.assertions.sourceControlProjectionAvailable) "Update to Revision workflow should prove Source Control projection is available after update."
  Assert-True (@($report.sourceControlUiUpdateToRevisionWorkflow.prompts.revision.rendererCaptureExpectations.requiredDomTokens | Where-Object { $_ -eq "Revision number" }).Count -eq 0) "Update to Revision revision prompt DOM expectations should not require the QuickInput placeholder because VS Code renderer text snapshots omit placeholder text."
  Assert-True (@($report.sourceControlUiUpdateToRevisionWorkflow.prompts.revision.rendererCaptureExpectations.requiredAccessibilityTokens | Where-Object { $_ -eq "Revision number" }).Count -eq 1) "Update to Revision revision prompt accessibility expectations should continue to require the QuickInput placeholder label."
  Assert-Equal "2" $report.updateRevisionPromptCapture.interaction.enteredText "Update to Revision revision prompt capture should type the requested revision."
  Assert-Equal "Enter" $report.updateRevisionPromptCapture.interaction.submittedKey "Update to Revision revision prompt capture should submit the revision input."
  Assert-Equal "Files" $report.updateDepthPromptCapture.interaction.selectedText "Update to Revision depth prompt capture should select Files depth."
  Assert-Equal "Make depth sticky" $report.updateStickyDepthPromptCapture.interaction.selectedText "Update to Revision sticky depth prompt capture should select sticky depth."
  Assert-Equal "Include externals" $report.updateExternalsPromptCapture.interaction.selectedText "Update to Revision externals prompt capture should select Include externals."
  Assert-Equal "subversionr.installedSourceControlUiE2eUpdateToRevisionCancellationWorkflow" $report.sourceControlUiUpdateToRevisionCancellationWorkflow.kind "Installed Source Control UI E2E evidence should include an Update to Revision cancellation workflow report."
  Assert-Equal "subversionr.updateToRevision" $report.sourceControlUiUpdateToRevisionCancellationWorkflow.command.command "Update to Revision cancellation workflow should execute the installed Update to Revision command."
  Assert-Equal "Escape" $report.sourceControlUiUpdateToRevisionCancellationWorkflow.prompt.cancelKey "Update to Revision cancellation workflow should report the Escape key used to dismiss the revision QuickInput."
  Assert-Equal "True" ([string]$report.sourceControlUiUpdateToRevisionCancellationWorkflow.assertions.commandCancelled) "Update to Revision cancellation workflow should prove the command returned through prompt cancellation."
  Assert-Equal "True" ([string]$report.sourceControlUiUpdateToRevisionCancellationWorkflow.assertions.targetContentUnchangedAfterCancellation) "Update to Revision cancellation workflow should prove the target file content stayed at the initial revision."
  Assert-Equal "True" ([string]$report.sourceControlUiUpdateToRevisionCancellationWorkflow.assertions.sourceControlProjectionUnchanged) "Update to Revision cancellation workflow should prove SourceControl projection stayed unchanged after cancellation."
  Assert-Equal "True" ([string]$report.sourceControlUiUpdateToRevisionCancellationWorkflow.assertions.repositoryClosedAfterEvidence) "Update to Revision cancellation workflow should close its evidence repository."
  Assert-True (@($report.sourceControlUiUpdateToRevisionCancellationWorkflow.prompt.rendererCaptureExpectations.requiredDomTokens | Where-Object { $_ -eq "Revision number" }).Count -eq 0) "Update to Revision cancellation DOM expectations should not require the QuickInput placeholder because VS Code renderer text snapshots omit placeholder text."
  Assert-True (@($report.sourceControlUiUpdateToRevisionCancellationWorkflow.prompt.rendererCaptureExpectations.requiredAccessibilityTokens | Where-Object { $_ -eq "Revision number" }).Count -eq 1) "Update to Revision cancellation accessibility expectations should continue to require the QuickInput placeholder label."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.updateCancellationRevisionPromptCapture.schema "Installed Source Control UI E2E evidence should include Update to Revision cancellation prompt capture evidence."
  Assert-Equal "Escape" $report.updateCancellationRevisionPromptCapture.interaction.cancelledKey "Update to Revision cancellation prompt capture should cancel the revision QuickInput with Escape."
  Assert-Equal "quickInput" $report.updateCancellationRevisionPromptCapture.interaction.surface "Update to Revision cancellation prompt capture should prove the QuickInput surface was cancelled."
  Assert-Equal "True" ([string]$report.updateCancellationRevisionPromptCapture.assertions.quickInputCancelled) "Update to Revision cancellation prompt capture should prove QuickInput cancellation completed."
  Assert-Equal "subversionr.installedSourceControlUiE2eUpdateToRevisionRepositoryOracle" $report.updateToRevisionRepositoryOracle.kind "Update to Revision repository oracle should be published in final evidence."
  Assert-Equal "True" ([string]$report.updateToRevisionRepositoryOracle.updatedRevisionContentMatched) "Update to Revision repository oracle should prove the updated working-copy file matches the requested repository revision."
  Assert-Equal "2" ([string]$report.updateWorkingCopy.requestedRevision) "Update evidence should publish the requested fixture revision."
  Assert-Equal "files" $report.updateWorkingCopy.requestedDepth "Update evidence should publish the requested fixture depth."
  Assert-Equal "True" ([string]$report.updateWorkingCopy.requestedStickyDepth) "Update evidence should publish the sticky-depth request."
  Assert-Equal "False" ([string]$report.updateWorkingCopy.requestedIgnoreExternals) "Update evidence should publish the include-externals request."
  Assert-Equal "subversionr.installedSourceControlUiE2eBranchCreateWorkflow" $report.sourceControlUiBranchCreateWorkflow.kind "Installed Source Control UI E2E evidence should include a Branch/Tag create workflow report."
  Assert-Equal "subversionr.branchCreateRepository" $report.sourceControlUiBranchCreateWorkflow.command.command "Branch/Tag create workflow should execute the installed Branch/Tag command."
  Assert-Equal "head" $report.sourceControlUiBranchCreateWorkflow.request.revision "Branch/Tag create workflow should request HEAD revision."
  Assert-Equal "False" ([string]$report.sourceControlUiBranchCreateWorkflow.request.makeParents) "Branch/Tag create workflow should require the destination parent to already exist."
  Assert-Equal "True" ([string]$report.sourceControlUiBranchCreateWorkflow.request.ignoreExternals) "Branch/Tag create workflow should explicitly ignore externals for the Beta installed happy path."
  Assert-Equal "Stay on the current SVN URL" $report.sourceControlUiBranchCreateWorkflow.prompts.switchAfterCreate.selected "Branch/Tag create workflow should record the stay-on-current-URL selection."
  Assert-Equal "False" ([string]$report.sourceControlUiBranchCreateWorkflow.prompts.switchAfterCreate.switchAfterCreate) "Branch/Tag create workflow should record that it did not switch the working copy after creation."
  Assert-Equal "True" ([string]$report.sourceControlUiBranchCreateWorkflow.assertions.branchCreatedInRepository) "Branch/Tag create workflow should prove the destination URL exists after creation."
  Assert-Equal "subversionr.installedSourceControlUiE2eBranchCreateRepositoryOracle" $report.branchCreateRepositoryOracle.kind "Branch/Tag repository oracle should be published in final evidence."
  Assert-Equal "True" ([string]$report.branchCreateRepositoryOracle.branchContentMatched) "Branch/Tag repository oracle should prove the destination branch content matches the trunk source."
  Assert-Equal "True" ([string]$report.branchCreateRepositoryOracle.latestLogContainsBranchMessage) "Branch/Tag repository oracle should prove the copy commit log contains the branch message."
  Assert-Equal "True" ([string]$report.branchCreateRepositoryOracle.copyFromPathMatched) "Branch/Tag repository oracle should prove the destination was created with SVN copyfrom metadata."
  Assert-Equal "True" ([string]$report.branchCreateRepositoryOracle.copyFromRevisionMatched) "Branch/Tag repository oracle should prove the destination copyfrom revision was recorded."
  Assert-Equal "subversionr.installedSourceControlUiE2eSwitchWorkflow" $report.sourceControlUiSwitchWorkflow.kind "Installed Source Control UI E2E evidence should include a Switch workflow report."
  Assert-Equal "subversionr.switchRepository" $report.sourceControlUiSwitchWorkflow.command.command "Switch workflow should execute the installed Switch command."
  Assert-Equal "head" $report.sourceControlUiSwitchWorkflow.request.revision "Switch workflow should request HEAD revision."
  Assert-Equal "infinity" $report.sourceControlUiSwitchWorkflow.request.depth "Switch workflow should request infinity depth."
  Assert-Equal "True" ([string]$report.sourceControlUiSwitchWorkflow.request.depthIsSticky) "Switch workflow should request sticky depth."
  Assert-Equal "True" ([string]$report.sourceControlUiSwitchWorkflow.request.ignoreExternals) "Switch workflow should explicitly ignore externals for the Beta installed happy path."
  Assert-Equal "False" ([string]$report.sourceControlUiSwitchWorkflow.request.ignoreAncestry) "Switch workflow should check ancestry."
  Assert-Equal "True" ([string]$report.sourceControlUiSwitchWorkflow.assertions.postSwitchReconcileCompleted) "Switch workflow should prove post-switch Source Control reconciliation."
  Assert-Equal "True" ([string]$report.sourceControlUiSwitchWorkflow.assertions.postSwitchGenerationAdvanced) "Switch workflow should prove the Source Control generation advanced after switch."
  Assert-Equal "True" ([string]$report.sourceControlUiSwitchWorkflow.assertions.postSwitchRepositoryIdentityPreserved) "Switch workflow should prove the switched Source Control surface still belongs to the opened repository session."
  Assert-Equal "subversionr.installedSourceControlUiE2eSwitchWorkingCopyOracle" $report.switchWorkingCopyOracle.kind "Switch working-copy oracle should be published in final evidence."
  Assert-Equal "True" ([string]$report.switchWorkingCopyOracle.workingCopyUrlMatched) "Switch working-copy oracle should prove the working copy URL changed to the branch URL."
  Assert-True ([string]$report.branchCreateSourcePromptCapture.interaction.enteredText -like "file://*/trunk") "Branch/Tag source prompt capture should type the trunk source URL."
  Assert-Equal "Enter" $report.branchCreateSourcePromptCapture.interaction.submittedKey "Branch/Tag source prompt capture should submit the source URL."
  Assert-True ([string]$report.branchCreateDestinationPromptCapture.interaction.enteredText -like "file://*/branches/beta-installed-e2e") "Branch/Tag destination prompt capture should type the destination branch URL."
  Assert-Equal "Enter" $report.branchCreateDestinationPromptCapture.interaction.submittedKey "Branch/Tag destination prompt capture should submit the destination URL."
  Assert-Equal "HEAD" $report.branchCreateRevisionPromptCapture.interaction.selectedText "Branch/Tag source revision prompt capture should select HEAD."
  Assert-Equal "Create installed Beta branch" $report.branchCreateMessagePromptCapture.interaction.enteredText "Branch/Tag log-message prompt capture should type the branch copy message."
  Assert-Equal "Enter" $report.branchCreateMessagePromptCapture.interaction.submittedKey "Branch/Tag log-message prompt capture should submit the branch copy message."
  Assert-Equal "Require destination parent" $report.branchCreateParentsPromptCapture.interaction.selectedText "Branch/Tag parents prompt capture should require an existing destination parent."
  Assert-Equal "Ignore externals" $report.branchCreateExternalsPromptCapture.interaction.selectedText "Branch/Tag externals prompt capture should select Ignore externals."
  Assert-Equal "Stay on the current SVN URL" $report.branchCreateSwitchPromptCapture.interaction.selectedText "Branch/Tag switch prompt capture should select Stay on the current SVN URL."
  Assert-True ([string]$report.switchUrlPromptCapture.interaction.enteredText -like "file://*/branches/beta-installed-switch") "Switch URL prompt capture should type the branch target URL."
  Assert-Equal "Enter" $report.switchUrlPromptCapture.interaction.submittedKey "Switch URL prompt capture should submit the branch target URL."
  Assert-Equal "HEAD" $report.switchRevisionPromptCapture.interaction.selectedText "Switch revision prompt capture should select HEAD."
  Assert-Equal "Infinity" $report.switchDepthPromptCapture.interaction.selectedText "Switch depth prompt capture should select Infinity."
  Assert-Equal "Make depth sticky" $report.switchStickyDepthPromptCapture.interaction.selectedText "Switch sticky-depth prompt capture should select sticky depth."
  Assert-Equal "Ignore externals" $report.switchExternalsPromptCapture.interaction.selectedText "Switch externals prompt capture should select Ignore externals."
  Assert-Equal "Check ancestry" $report.switchAncestryPromptCapture.interaction.selectedText "Switch ancestry prompt capture should select Check ancestry."
  Assert-Equal "subversionr.installedSourceControlUiE2eCommitAllWorkflow" $report.sourceControlUiCommitAllWorkflow.kind "Installed Source Control UI E2E evidence should include a Commit All workflow report."
  Assert-Equal "subversionr.commitAll" $report.sourceControlUiCommitAllWorkflow.command.command "Commit All workflow should execute the installed Commit All command."
  Assert-Equal "subversionr.commitAll" $report.sourceControlUiCommitAllWorkflow.command.sourceControlAcceptInputCommand "Commit All workflow should execute the command exposed by the SourceControl input box."
  Assert-Equal $report.sourceControlUiCommitAllWorkflow.repository.repositoryId (@($report.sourceControlUiCommitAllWorkflow.command.arguments)[0]) "Commit All workflow should pass the SourceControl input command's repository argument."
  Assert-Equal "src/tracked.txt" (@($report.sourceControlUiCommitAllWorkflow.targets.eligiblePaths)[0]) "Commit All workflow should commit the tracked modified file."
  Assert-Equal "scratch.txt" (@($report.sourceControlUiCommitAllWorkflow.targets.excludedUnversionedPaths)[0]) "Commit All workflow should record the excluded unversioned path."
  Assert-Equal "True" ([string]$report.sourceControlUiCommitAllWorkflow.assertions.inputMessageWasSet) "Commit All workflow should set the SourceControl input message before accepting it."
  Assert-Equal "True" ([string]$report.sourceControlUiCommitAllWorkflow.assertions.inputMessageClearedAfterCommit) "Commit All workflow should prove the repository input message was cleared after success."
  Assert-Equal "True" ([string]$report.sourceControlUiCommitAllWorkflow.assertions.trackedFileCommitted) "Commit All workflow should prove the tracked modified file was committed."
  Assert-Equal "True" ([string]$report.sourceControlUiCommitAllWorkflow.assertions.unversionedPathRemainedUnversioned) "Commit All workflow should prove the unversioned path was excluded from the commit."
  Assert-Equal "True" ([string]$report.sourceControlUiCommitAllWorkflow.assertions.sourceControlProjectionClearedCommittedPath) "Commit All workflow should prove the committed path left the SourceControl changes projection."
  Assert-Equal "True" ([string]$report.sourceControlUiCommitAllWorkflow.assertions.targetedReconcileAfterCommit) "Commit All workflow should prove targeted post-commit reconcile evidence."
  Assert-Equal "subversionr.installedSourceControlUiE2eCommitAllRepositoryOracle" $report.commitAllRepositoryOracle.kind "Commit All repository oracle should be published in final evidence."
  Assert-Equal "modified by M7j3" $report.commitAllRepositoryOracle.trackedFileContent "Commit All repository oracle should prove the repository contains the committed tracked content."
  Assert-Equal "True" ([string]$report.commitAllRepositoryOracle.latestLogContainsCommitMessage) "Commit All repository oracle should prove the latest SVN log contains the input message."
  Assert-Equal "True" ([string]$report.commitAllRepositoryOracle.unversionedScratchAbsentFromRepository) "Commit All repository oracle should prove scratch.txt was not committed."
  Assert-Equal "True" ([string]$report.commitAllWorkingCopy.repositoryOracle.unversionedScratchAbsentFromRepository) "Commit All working-copy evidence should link to the repository oracle."
  Assert-Equal "subversionr.installedSourceControlUiE2eCommitSelectedWorkflow" $report.sourceControlUiCommitSelectedWorkflow.kind "Installed Source Control UI E2E evidence should include a Commit Selected workflow report."
  Assert-Equal "subversionr.commitResource" $report.sourceControlUiCommitSelectedWorkflow.command.command "Commit Selected workflow should execute the installed Commit Selected command."
  Assert-Equal "src/tracked.txt" (@($report.sourceControlUiCommitSelectedWorkflow.targets.selectedPaths)[0]) "Commit Selected workflow should commit the selected tracked file."
  Assert-Equal "load/modified-001.txt" (@($report.sourceControlUiCommitSelectedWorkflow.targets.unselectedChangedPaths)[0]) "Commit Selected workflow should record the unselected changed file."
  Assert-Equal "True" ([string]$report.sourceControlUiCommitSelectedWorkflow.assertions.selectedFileCommitted) "Commit Selected workflow should prove the selected file was committed."
  Assert-Equal "True" ([string]$report.sourceControlUiCommitSelectedWorkflow.assertions.unselectedFileStillModified) "Commit Selected workflow should prove the unselected changed file remained uncommitted."
  Assert-Equal "True" ([string]$report.sourceControlUiCommitSelectedWorkflow.assertions.inputMessageClearedAfterCommit) "Commit Selected workflow should prove the repository input message was cleared after success."
  Assert-Equal "True" ([string]$report.sourceControlUiCommitSelectedWorkflow.assertions.targetedReconcileAfterCommit) "Commit Selected workflow should prove targeted post-commit reconcile evidence."
  Assert-Equal "subversionr.installedSourceControlUiE2eCommitSelectedRepositoryOracle" $report.commitSelectedRepositoryOracle.kind "Commit Selected repository oracle should be published in final evidence."
  Assert-Equal "modified by M7j3" $report.commitSelectedRepositoryOracle.trackedFileContent "Commit Selected repository oracle should prove the repository contains the committed selected content."
  Assert-Equal "initial load item 1" $report.commitSelectedRepositoryOracle.unselectedFileRepositoryContent "Commit Selected repository oracle should prove the unselected file was not committed."
  Assert-Equal "True" ([string]$report.commitSelectedRepositoryOracle.latestLogContainsCommitMessage) "Commit Selected repository oracle should prove the latest SVN log contains the selected commit message."
  Assert-Equal "True" ([string]$report.commitSelectedWorkingCopy.repositoryOracle.unselectedFileRemainedUncommitted) "Commit Selected working-copy evidence should link to the repository oracle."
  Assert-Equal "subversionr.installedSourceControlUiE2eCommitSelectedMultiSelectionWorkflow" $report.sourceControlUiCommitSelectedMultiSelectionWorkflow.kind "Installed Source Control UI E2E evidence should include a Commit Selected multi-selection workflow report."
  Assert-Equal "subversionr.commitResource" $report.sourceControlUiCommitSelectedMultiSelectionWorkflow.command.command "Commit Selected multi-selection workflow should execute the installed Commit Selected command."
  Assert-Equal "resourceStateArray" $report.sourceControlUiCommitSelectedMultiSelectionWorkflow.command.argumentShape "Commit Selected multi-selection workflow should use the VS Code SCM resource array command argument."
  Assert-Equal "src/tracked.txt" (@($report.sourceControlUiCommitSelectedMultiSelectionWorkflow.targets.selectedPaths)[0]) "Commit Selected multi-selection workflow should commit the first selected tracked file."
  Assert-Equal "load/modified-001.txt" (@($report.sourceControlUiCommitSelectedMultiSelectionWorkflow.targets.selectedPaths)[1]) "Commit Selected multi-selection workflow should commit the second selected tracked file."
  Assert-Equal "True" ([string]$report.sourceControlUiCommitSelectedMultiSelectionWorkflow.assertions.allSelectedFilesCommitted) "Commit Selected multi-selection workflow should prove every selected file was committed."
  Assert-Equal "True" ([string]$report.sourceControlUiCommitSelectedMultiSelectionWorkflow.assertions.sourceControlProjectionClearedSelectedPaths) "Commit Selected multi-selection workflow should prove selected paths left the SourceControl changes projection."
  Assert-Equal "True" ([string]$report.sourceControlUiCommitSelectedMultiSelectionWorkflow.assertions.inputMessageClearedAfterCommit) "Commit Selected multi-selection workflow should prove the repository input message was cleared after success."
  Assert-Equal "True" ([string]$report.sourceControlUiCommitSelectedMultiSelectionWorkflow.assertions.targetedReconcileAfterCommit) "Commit Selected multi-selection workflow should prove targeted post-commit reconcile evidence for both selected paths."
  Assert-Equal "subversionr.installedSourceControlUiE2eCommitSelectedMultiSelectionRepositoryOracle" $report.commitSelectedMultiSelectionRepositoryOracle.kind "Commit Selected multi-selection repository oracle should be published in final evidence."
  Assert-Equal "modified by M7j3" $report.commitSelectedMultiSelectionRepositoryOracle.trackedFileContent "Commit Selected multi-selection repository oracle should prove the first selected content was committed."
  Assert-Equal "modified load item load/modified-001.txt by M7j3" $report.commitSelectedMultiSelectionRepositoryOracle.loadFileContent "Commit Selected multi-selection repository oracle should prove the second selected content was committed."
  Assert-Equal "True" ([string]$report.commitSelectedMultiSelectionRepositoryOracle.latestLogContainsCommitMessage) "Commit Selected multi-selection repository oracle should prove the latest SVN log contains the selected multi-selection commit message."
  Assert-Equal "True" ([string]$report.commitSelectedMultiSelectionWorkingCopy.repositoryOracle.allSelectedFilesCommitted) "Commit Selected multi-selection working-copy evidence should link to the repository oracle."
  Assert-Equal "subversionr.installedSourceControlUiE2eAddToIgnoreWorkflow" $report.sourceControlUiAddToIgnoreWorkflow.kind "Installed Source Control UI E2E evidence should include an Add to Ignore workflow report."
  Assert-Equal "subversionr.addToIgnoreResource" $report.sourceControlUiAddToIgnoreWorkflow.command.command "Add to Ignore workflow should execute the installed Add to Ignore command."
  Assert-Equal "scratch.txt" $report.sourceControlUiAddToIgnoreWorkflow.resource.path "Add to Ignore workflow should target the unversioned fixture resource."
  Assert-Equal "." $report.sourceControlUiAddToIgnoreWorkflow.rootPropertyResource.path "Add to Ignore workflow should project the working-copy root property-only change."
  Assert-Equal "subversionr.changedDirectory" $report.sourceControlUiAddToIgnoreWorkflow.rootPropertyResource.contextValue "Add to Ignore workflow should expose the root svn:ignore change as a changed directory Source Control resource."
  Assert-Equal "dir" $report.sourceControlUiAddToIgnoreWorkflow.rootPropertyResource.kind "Add to Ignore workflow should report the root property-only projection as a directory resource."
  Assert-Equal "svn:ignore" $report.sourceControlUiAddToIgnoreWorkflow.property.name "Add to Ignore workflow should update svn:ignore."
  Assert-Equal "scratch.txt" (@($report.sourceControlUiAddToIgnoreWorkflow.property.addedPatterns)[0]) "Add to Ignore workflow should add the scratch.txt ignore pattern."
  Assert-Equal "True" ([string]$report.sourceControlUiAddToIgnoreWorkflow.assertions.propertyListReadBeforeSet) "Add to Ignore workflow should prove properties/list was read before propertySet."
  Assert-Equal "True" ([string]$report.sourceControlUiAddToIgnoreWorkflow.assertions.workingCopyIgnorePropertyUpdated) "Add to Ignore workflow should prove the working-copy svn:ignore property was updated."
  Assert-Equal "True" ([string]$report.sourceControlUiAddToIgnoreWorkflow.assertions.rootPropertyChangeProjected) "Add to Ignore workflow should prove the root svn:ignore property-only change survives SourceControl snapshot projection."
  Assert-Equal "True" ([string]$report.sourceControlUiAddToIgnoreWorkflow.assertions.unversionedProjectionCleared) "Add to Ignore workflow should prove the unversioned projection was cleared."
  Assert-Equal "subversionr.installedSourceControlUiE2eAddToIgnoreWorkingCopyOracle" $report.addToIgnoreWorkingCopyOracle.kind "Add to Ignore working-copy oracle should be published in final evidence."
  Assert-Equal "True" ([string]$report.addToIgnoreWorkingCopyOracle.ignorePatternPresent) "Add to Ignore working-copy oracle should prove svn:ignore contains scratch.txt."
  Assert-Equal "subversionr.installedSourceControlUiE2eLockUnlockWorkflow" $report.sourceControlUiLockUnlockWorkflow.kind "Installed Source Control UI E2E evidence should include a Lock/Unlock workflow report."
  Assert-Equal "subversionr.lockResource" $report.sourceControlUiLockUnlockWorkflow.commands.lock "Lock/Unlock workflow should execute the installed Lock command."
  Assert-Equal "subversionr.unlockResource" $report.sourceControlUiLockUnlockWorkflow.commands.unlock "Lock/Unlock workflow should execute the installed Unlock command."
  Assert-Equal "src/needs-lock.txt" $report.sourceControlUiLockUnlockWorkflow.resource.path "Lock/Unlock workflow should target the needs-lock fixture resource."
  Assert-Equal "subversionr.workingCopyMetadataFile" $report.sourceControlUiLockUnlockWorkflow.resource.contextValueBefore "Lock/Unlock workflow should start from the working-copy metadata file projection."
  Assert-Equal "Beta-E installed lock evidence" $report.sourceControlUiLockUnlockWorkflow.request.comment "Lock/Unlock workflow should record the lock comment."
  Assert-Equal "False" ([string]$report.sourceControlUiLockUnlockWorkflow.request.stealLock) "Lock/Unlock workflow should use the normal lock policy."
  Assert-Equal "False" ([string]$report.sourceControlUiLockUnlockWorkflow.request.breakLock) "Lock/Unlock workflow should use the normal unlock policy."
  Assert-Equal "operationLock" $report.sourceControlUiLockUnlockWorkflow.postLockFreshnessReport.lastCompletedRefresh.targets[0].reason "Lock/Unlock workflow should record operationLock targeted refresh evidence."
  Assert-Equal "subversionr.installedSourceControlUiE2eCurrentSurfaceReport" $report.sourceControlUiLockUnlockWorkflow.preUnlockSurfaceReport.kind "Lock/Unlock workflow should refresh the current Source Control surface before Unlock."
  Assert-Equal "operationUnlock" $report.sourceControlUiLockUnlockWorkflow.postUnlockFreshnessReport.lastCompletedRefresh.targets[0].reason "Lock/Unlock workflow should record operationUnlock targeted refresh evidence."
  Assert-Equal "True" ([string]$report.sourceControlUiLockUnlockWorkflow.assertions.needsLockProjectedBefore) "Lock/Unlock workflow should prove the svn:needs-lock metadata resource was projected before locking."
  Assert-Equal "True" ([string]$report.sourceControlUiLockUnlockWorkflow.assertions.lockTargetedReconcile) "Lock/Unlock workflow should prove targeted post-lock reconcile evidence."
  Assert-Equal "True" ([string]$report.sourceControlUiLockUnlockWorkflow.assertions.unlockTargetedReconcile) "Lock/Unlock workflow should prove targeted post-unlock reconcile evidence."
  Assert-Equal "True" ([string]$report.sourceControlUiLockUnlockWorkflow.assertions.lockHeldOracleHandshakeCompleted) "Lock/Unlock workflow should prove the held-lock oracle handshake completed before unlock."
  Assert-Equal "subversionr.installedSourceControlUiE2eLockHeldWorkingCopyOracle" $report.lockHeldWorkingCopyOracle.kind "Lock held working-copy oracle should be published in final evidence."
  Assert-Equal "True" ([string]$report.lockHeldWorkingCopyOracle.svnInfoContainsLockToken) "Lock held working-copy oracle should prove svn info exposed a Lock Token."
  Assert-Equal "True" ([string]$report.lockHeldWorkingCopyOracle.svnInfoContainsLockOwner) "Lock held working-copy oracle should prove svn info exposed a Lock Owner."
  Assert-Equal "subversionr.installedSourceControlUiE2eLockUnlockWorkingCopyOracle" $report.lockUnlockWorkingCopyOracle.kind "Lock/unlock working-copy oracle should be published in final evidence."
  Assert-Equal "*" $report.lockUnlockWorkingCopyOracle.needsLockProperty "Lock/unlock working-copy oracle should prove svn:needs-lock remains set."
  Assert-Equal "True" ([string]$report.lockUnlockWorkingCopyOracle.svnInfoLockTokenAbsentAfterUnlock) "Lock/unlock working-copy oracle should prove the lock token is absent after unlock."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.lockMessagePromptCapture.schema "Installed Source Control UI E2E evidence should include Lock message prompt capture evidence."
  Assert-True (@($report.sourceControlUiLockUnlockWorkflow.prompts.lockMessage.rendererCaptureExpectations.requiredDomTokens | Where-Object { $_ -eq "Lock message" }).Count -eq 0) "Lock message prompt DOM expectations should not require the QuickInput placeholder because VS Code renderer text snapshots omit placeholder text."
  Assert-True (@($report.sourceControlUiLockUnlockWorkflow.prompts.lockMessage.rendererCaptureExpectations.requiredAccessibilityTokens | Where-Object { $_ -eq "Lock message" }).Count -eq 1) "Lock message prompt accessibility expectations should continue to require the QuickInput placeholder label."
  Assert-Equal "Beta-E installed lock evidence" $report.lockMessagePromptCapture.interaction.enteredText "Lock message prompt capture should type the requested lock comment."
  Assert-Equal "Enter" $report.lockMessagePromptCapture.interaction.submittedKey "Lock message prompt capture should submit the lock comment."
  Assert-Equal "Lock" $report.lockModePromptCapture.interaction.selectedText "Lock mode prompt capture should select the normal Lock policy."
  Assert-Equal "Unlock" $report.unlockModePromptCapture.interaction.selectedText "Unlock mode prompt capture should select the normal Unlock policy."
  Assert-Equal "subversionr.installedSourceControlUiE2eLockMessageCancellationWorkflow" $report.sourceControlUiLockMessageCancellationWorkflow.kind "Installed Source Control UI E2E evidence should include a Lock message cancellation workflow report."
  Assert-Equal "subversionr.lockResource" $report.sourceControlUiLockMessageCancellationWorkflow.command.command "Lock message cancellation workflow should execute the installed Lock command."
  Assert-Equal "src/needs-lock.txt" $report.sourceControlUiLockMessageCancellationWorkflow.resource.path "Lock message cancellation workflow should target the needs-lock fixture resource."
  Assert-Equal "Escape" $report.sourceControlUiLockMessageCancellationWorkflow.prompt.cancelKey "Lock message cancellation workflow should cancel the message QuickInput with Escape."
  Assert-Equal "quickInput" $report.sourceControlUiLockMessageCancellationWorkflow.prompt.rendererCaptureExpectations.cancelSurface "Lock message cancellation workflow should require QuickInput cancellation evidence."
  Assert-True (@($report.sourceControlUiLockMessageCancellationWorkflow.prompt.rendererCaptureExpectations.requiredDomTokens | Where-Object { $_ -eq "Lock message" }).Count -eq 0) "Lock message cancellation DOM expectations should not require the QuickInput placeholder because VS Code renderer text snapshots omit placeholder text."
  Assert-True (@($report.sourceControlUiLockMessageCancellationWorkflow.prompt.rendererCaptureExpectations.requiredAccessibilityTokens | Where-Object { $_ -eq "Lock message" }).Count -eq 1) "Lock message cancellation accessibility expectations should continue to require the QuickInput placeholder label."
  Assert-Equal "True" ([string]$report.sourceControlUiLockMessageCancellationWorkflow.assertions.commandCancelled) "Lock message cancellation workflow should prove the command returned through cancellation."
  Assert-Equal "True" ([string]$report.sourceControlUiLockMessageCancellationWorkflow.assertions.sourceControlProjectionUnchanged) "Lock message cancellation workflow should prove Source Control projection stayed unchanged."
  Assert-Equal "True" ([string]$report.sourceControlUiLockMessageCancellationWorkflow.assertions.repositoryClosedAfterEvidence) "Lock message cancellation workflow should close its evidence repository."
  Assert-Equal "subversionr.installedSourceControlUiE2eUnlockModeCancellationWorkflow" $report.sourceControlUiUnlockModeCancellationWorkflow.kind "Installed Source Control UI E2E evidence should include an Unlock mode cancellation workflow report."
  Assert-Equal "subversionr.unlockResource" $report.sourceControlUiUnlockModeCancellationWorkflow.command.command "Unlock mode cancellation workflow should execute the installed Unlock command."
  Assert-Equal "src/needs-lock.txt" $report.sourceControlUiUnlockModeCancellationWorkflow.resource.path "Unlock mode cancellation workflow should target the needs-lock fixture resource."
  Assert-Equal "Escape" $report.sourceControlUiUnlockModeCancellationWorkflow.prompt.cancelKey "Unlock mode cancellation workflow should cancel the mode QuickPick with Escape."
  Assert-Equal "quickInput" $report.sourceControlUiUnlockModeCancellationWorkflow.prompt.rendererCaptureExpectations.cancelSurface "Unlock mode cancellation workflow should require QuickInput cancellation evidence."
  Assert-Equal "True" ([string]$report.sourceControlUiUnlockModeCancellationWorkflow.assertions.commandCancelled) "Unlock mode cancellation workflow should prove the command returned through cancellation."
  Assert-Equal "True" ([string]$report.sourceControlUiUnlockModeCancellationWorkflow.assertions.sourceControlProjectionUnchanged) "Unlock mode cancellation workflow should prove Source Control projection stayed unchanged."
  Assert-Equal "True" ([string]$report.sourceControlUiUnlockModeCancellationWorkflow.assertions.repositoryClosedAfterEvidence) "Unlock mode cancellation workflow should close its evidence repository."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.lockMessageCancellationPromptCapture.schema "Installed Source Control UI E2E evidence should include Lock message cancellation prompt capture evidence."
  Assert-Equal "Escape" $report.lockMessageCancellationPromptCapture.interaction.cancelledKey "Lock message cancellation prompt capture should press Escape."
  Assert-Equal "quickInput" $report.lockMessageCancellationPromptCapture.interaction.surface "Lock message cancellation prompt capture should cancel a QuickInput surface."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.unlockModeCancellationPromptCapture.schema "Installed Source Control UI E2E evidence should include Unlock mode cancellation prompt capture evidence."
  Assert-Equal "Escape" $report.unlockModeCancellationPromptCapture.interaction.cancelledKey "Unlock mode cancellation prompt capture should press Escape."
  Assert-Equal "quickInput" $report.unlockModeCancellationPromptCapture.interaction.surface "Unlock mode cancellation prompt capture should cancel a QuickInput surface."
  Assert-Equal "True" ([string]$report.lockWorkingCopy.heldWorkingCopyOracle.svnInfoContainsLockToken) "Lock working-copy evidence should link to the held-lock oracle."
  Assert-Equal "True" ([string]$report.lockWorkingCopy.workingCopyOracle.svnInfoLockTokenAbsentAfterUnlock) "Lock working-copy evidence should link to the final unlock oracle."
  Assert-Equal "subversionr.installedSourceControlUiE2eChangelistSetClearWorkflow" $report.sourceControlUiChangelistSetClearWorkflow.kind "Installed Source Control UI E2E evidence should include a Changelist set/clear workflow report."
  Assert-Equal "subversionr.setResourceChangelist" $report.sourceControlUiChangelistSetClearWorkflow.commands.set "Changelist set/clear workflow should execute Set Changelist."
  Assert-Equal "subversionr.clearResourceChangelist" $report.sourceControlUiChangelistSetClearWorkflow.commands.clear "Changelist set/clear workflow should execute Clear Changelist."
  Assert-Equal "review" $report.sourceControlUiChangelistSetClearWorkflow.changelist "Changelist set/clear workflow should use the review changelist."
  Assert-Equal "True" ([string]$report.sourceControlUiChangelistSetClearWorkflow.assertions.groupProjectedAfterSet) "Changelist set/clear workflow should prove the changelist group was projected."
  Assert-Equal "True" ([string]$report.sourceControlUiChangelistSetClearWorkflow.assertions.resourceReturnedToChangesAfterClear) "Changelist set/clear workflow should prove Clear moved the resource back to Changes."
  Assert-True (@($report.sourceControlUiChangelistSetClearWorkflow.prompts.set.rendererCaptureExpectations.requiredDomTokens | Where-Object { $_ -eq "Changelist name" }).Count -eq 0) "Set Changelist prompt DOM expectations should not require the QuickInput placeholder because VS Code renderer text snapshots omit placeholder text."
  Assert-True (@($report.sourceControlUiChangelistSetClearWorkflow.prompts.set.rendererCaptureExpectations.requiredAccessibilityTokens | Where-Object { $_ -eq "Changelist name" }).Count -eq 1) "Set Changelist prompt accessibility expectations should continue to require the QuickInput placeholder label."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.changelistSetPromptCapture.schema "Installed Source Control UI E2E evidence should include Set Changelist prompt capture evidence."
  Assert-Equal "review" $report.changelistSetPromptCapture.interaction.enteredText "Set Changelist prompt capture should type the review changelist."
  Assert-Equal "Enter" $report.changelistSetPromptCapture.interaction.submittedKey "Set Changelist prompt capture should submit the changelist input."
  Assert-Equal "subversionr.installedSourceControlUiE2eCommitChangelistWorkflow" $report.sourceControlUiCommitChangelistWorkflow.kind "Installed Source Control UI E2E evidence should include a Commit Changelist workflow report."
  Assert-Equal "subversionr.commitChangelist" $report.sourceControlUiCommitChangelistWorkflow.command.command "Commit Changelist workflow should execute the installed group command."
  Assert-Equal "review" $report.sourceControlUiCommitChangelistWorkflow.command.changelist "Commit Changelist workflow should target the review changelist."
  Assert-Equal "True" ([string]$report.sourceControlUiCommitChangelistWorkflow.assertions.commitUsedChangelistFilter) "Commit Changelist workflow should prove the changelist filter was applied."
  Assert-Equal "True" ([string]$report.sourceControlUiCommitChangelistWorkflow.assertions.changelistProjectionClearedCommittedPath) "Commit Changelist workflow should prove the committed changelist resource left Source Control."
  Assert-Equal "subversionr.installedSourceControlUiE2eCommitChangelistRepositoryOracle" $report.commitChangelistRepositoryOracle.kind "Commit Changelist repository oracle should be published in final evidence."
  Assert-Equal "True" ([string]$report.commitChangelistRepositoryOracle.latestLogContainsCommitMessage) "Commit Changelist repository oracle should prove the latest SVN log contains the changelist commit message."
  Assert-Equal "subversionr.installedSourceControlUiE2eRevertChangelistWorkflow" $report.sourceControlUiRevertChangelistWorkflow.kind "Installed Source Control UI E2E evidence should include a Revert Changelist workflow report."
  Assert-Equal "subversionr.revertChangelist" $report.sourceControlUiRevertChangelistWorkflow.command.command "Revert Changelist workflow should execute the installed group command."
  Assert-Equal "review" $report.sourceControlUiRevertChangelistWorkflow.command.changelist "Revert Changelist workflow should target the review changelist."
  Assert-Equal "True" ([string]$report.sourceControlUiRevertChangelistWorkflow.assertions.revertUsedChangelistFilter) "Revert Changelist workflow should prove the changelist filter was applied."
  Assert-Equal "True" ([string]$report.sourceControlUiRevertChangelistWorkflow.assertions.workingCopyContentRestored) "Revert Changelist workflow should prove the changelist resource content was restored."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.changelistRevertPromptCapture.schema "Installed Source Control UI E2E evidence should include Revert Changelist prompt capture evidence."
  Assert-Equal "Revert" $report.changelistRevertPromptCapture.interaction.clickedButtonText "Revert Changelist prompt capture should click Revert."
  Assert-Equal "subversionr.installedSourceControlUiE2eFreshnessReport" $report.sourceControlUiPartialFreshnessReport.kind "Installed Source Control UI E2E evidence should include a partial freshness report."
  Assert-Equal "partial" $report.sourceControlUiPartialFreshnessReport.scenario "Installed Source Control UI E2E partial freshness report should record the partial scenario."
  Assert-Equal "partial" $report.sourceControlUiPartialFreshnessReport.sourceControl.freshness.repositoryCompleteness "Installed Source Control UI E2E partial report should prove partial repository completeness."
  $partialStatusCommand = @($report.sourceControlUiPartialFreshnessReport.sourceControl.statusBarCommands)[0]
  Assert-Equal "subversionr.fullReconcile" $partialStatusCommand.command "Installed Source Control UI E2E partial report should expose the full reconcile command."
  Assert-Equal "SVN status partial" $partialStatusCommand.title "Installed Source Control UI E2E partial report should expose the partial status title."
  Assert-Equal $report.sourceControlUiOpenReport.repository.repositoryId (@($partialStatusCommand.arguments)[0]) "Installed Source Control UI E2E partial report should route full reconcile to the opened repository."
  Assert-Equal "subversionr.installedSourceControlUiE2eFreshnessReport" $report.sourceControlUiStaleFreshnessReport.kind "Installed Source Control UI E2E evidence should include a stale freshness report."
  Assert-Equal "stale" $report.sourceControlUiStaleFreshnessReport.scenario "Installed Source Control UI E2E stale freshness report should record the stale scenario."
  Assert-Equal "stale" $report.sourceControlUiStaleFreshnessReport.sourceControl.freshness.repositoryCompleteness "Installed Source Control UI E2E stale report should prove stale repository completeness."
  $staleStatusCommand = @($report.sourceControlUiStaleFreshnessReport.sourceControl.statusBarCommands)[0]
  Assert-Equal "subversionr.fullReconcile" $staleStatusCommand.command "Installed Source Control UI E2E stale report should expose the full reconcile command."
  Assert-Equal "SVN status stale" $staleStatusCommand.title "Installed Source Control UI E2E stale report should expose the stale status title."
  Assert-Equal $report.sourceControlUiOpenReport.repository.repositoryId (@($staleStatusCommand.arguments)[0]) "Installed Source Control UI E2E stale report should route full reconcile to the opened repository."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.partialFreshnessRendererCapture.schema "Installed Source Control UI E2E evidence should include partial freshness renderer capture evidence."
  Assert-Equal "captured" $report.partialFreshnessRendererCapture.artifacts.dom.status "Partial freshness renderer DOM artifact should be captured."
  Assert-Equal "captured" $report.partialFreshnessRendererCapture.artifacts.accessibility.status "Partial freshness renderer accessibility artifact should be captured."
  Assert-Equal "captured" $report.partialFreshnessRendererCapture.artifacts.screenshot.status "Partial freshness renderer screenshot artifact should be captured."
  Assert-Equal "True" ([string]$report.partialFreshnessRendererCapture.assertions.domRequiredTokensPresent) "Partial freshness renderer DOM assertions should pass."
  Assert-Equal "True" ([string]$report.partialFreshnessRendererCapture.assertions.accessibilityRequiredTokensPresent) "Partial freshness renderer accessibility assertions should pass."
  Assert-True (@($report.partialFreshnessRendererCapture.artifacts.dom.requiredTokens | Where-Object { $_ -eq "SVN status partial" }).Count -eq 1) "Partial freshness renderer DOM capture should require the partial status token."
  Assert-True (@($report.partialFreshnessRendererCapture.artifacts.accessibility.requiredTokens | Where-Object { $_ -eq "SVN status partial" }).Count -eq 1) "Partial freshness renderer accessibility capture should require the partial status token."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.staleFreshnessRendererCapture.schema "Installed Source Control UI E2E evidence should include stale freshness renderer capture evidence."
  Assert-Equal "captured" $report.staleFreshnessRendererCapture.artifacts.dom.status "Stale freshness renderer DOM artifact should be captured."
  Assert-Equal "captured" $report.staleFreshnessRendererCapture.artifacts.accessibility.status "Stale freshness renderer accessibility artifact should be captured."
  Assert-Equal "captured" $report.staleFreshnessRendererCapture.artifacts.screenshot.status "Stale freshness renderer screenshot artifact should be captured."
  Assert-Equal "True" ([string]$report.staleFreshnessRendererCapture.assertions.domRequiredTokensPresent) "Stale freshness renderer DOM assertions should pass."
  Assert-Equal "True" ([string]$report.staleFreshnessRendererCapture.assertions.accessibilityRequiredTokensPresent) "Stale freshness renderer accessibility assertions should pass."
  Assert-True (@($report.staleFreshnessRendererCapture.artifacts.dom.requiredTokens | Where-Object { $_ -eq "SVN status stale" }).Count -eq 1) "Stale freshness renderer DOM capture should require the stale status token."
  Assert-True (@($report.staleFreshnessRendererCapture.artifacts.accessibility.requiredTokens | Where-Object { $_ -eq "SVN status stale" }).Count -eq 1) "Stale freshness renderer accessibility capture should require the stale status token."
  Assert-Equal "subversionr.installedSourceControlUiE2eFullReconcileCancellationWorkflow" $report.sourceControlUiFullReconcileCancellationWorkflow.kind "Installed Source Control UI E2E evidence should include a Full Reconcile cancellation workflow report."
  Assert-Equal "subversionr.fullReconcile" $report.sourceControlUiFullReconcileCancellationWorkflow.command.command "Full Reconcile cancellation workflow should execute the installed Full Reconcile command."
  Assert-Equal "Cancel" $report.sourceControlUiFullReconcileCancellationWorkflow.prompt.clickButtonText "Full Reconcile cancellation workflow should click the progress Cancel button."
  Assert-Equal "subversionr.installedSourceControlUiE2eFullReconcileCancellationReport" $report.sourceControlUiFullReconcileCancellationWorkflow.cancellationReport.kind "Full Reconcile cancellation workflow should include the hidden probe report."
  Assert-Equal "True" ([string]$report.sourceControlUiFullReconcileCancellationWorkflow.cancellationReport.assertions.matchedManualFullReconcile) "Full Reconcile cancellation probe should match the manual full reconcile refresh target."
  Assert-Equal "True" ([string]$report.sourceControlUiFullReconcileCancellationWorkflow.cancellationReport.assertions.signalProvided) "Full Reconcile cancellation probe should prove a status refresh signal was provided."
  Assert-Equal "True" ([string]$report.sourceControlUiFullReconcileCancellationWorkflow.cancellationReport.assertions.signalAborted) "Full Reconcile cancellation probe should prove the status refresh signal was aborted."
  Assert-Equal "True" ([string]$report.sourceControlUiFullReconcileCancellationWorkflow.cancellationReport.assertions.cancellationObserved) "Full Reconcile cancellation probe should observe user cancellation."
  Assert-Equal "userCancelled" $report.sourceControlUiFullReconcileCancellationWorkflow.assertions.cancellationReason "Full Reconcile cancellation workflow should record the userCancelled reason."
  Assert-Equal "True" ([string]$report.sourceControlUiFullReconcileCancellationWorkflow.assertions.recoveryFullReconcileExecuted) "Full Reconcile cancellation workflow should execute a recovery full reconcile."
  Assert-Equal "True" ([string]$report.sourceControlUiFullReconcileCancellationWorkflow.assertions.sourceControlSurfaceAfterRecovery) "Full Reconcile cancellation workflow should preserve Source Control after recovery."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.fullReconcileCancellationProgressCapture.schema "Installed Source Control UI E2E evidence should include Full Reconcile cancellation progress capture evidence."
  Assert-Equal "Cancel" $report.fullReconcileCancellationProgressCapture.interaction.clickedButtonText "Full Reconcile cancellation progress capture should click Cancel."
  Assert-Equal "True" ([string]$report.fullReconcileCancellationProgressCapture.assertions.clickButtonCompleted) "Full Reconcile cancellation progress capture should prove the Cancel click completed."
  Assert-True (@($report.fullReconcileCancellationProgressCapture.artifacts.dom.requiredTokens | Where-Object { $_ -eq "Reconciling SVN working copy status" }).Count -eq 1) "Full Reconcile cancellation progress DOM capture should require the progress title."
  Assert-True (@($report.fullReconcileCancellationProgressCapture.artifacts.accessibility.requiredTokens | Where-Object { $_ -eq "Cancel" }).Count -eq 1) "Full Reconcile cancellation progress accessibility capture should require the Cancel token."
  Assert-Equal "subversionr.installedSourceControlUiE2eDirtyGenerationCancellationLoadWorkflow" $report.sourceControlUiDirtyGenerationCancellationLoadWorkflow.kind "Installed Source Control UI E2E evidence should include a dirty-generation cancellation load workflow report."
  Assert-Equal "subversionr.refreshRepository" $report.sourceControlUiDirtyGenerationCancellationLoadWorkflow.command.command "Dirty-generation cancellation workflow should execute the installed Refresh command."
  Assert-Equal "subversionr.installedSourceControlUiE2eDirtyGenerationCancellationArmReport" $report.sourceControlUiDirtyGenerationCancellationLoadWorkflow.armReport.kind "Dirty-generation cancellation workflow should include the hidden arm report."
  Assert-Equal "subversionr.installedSourceControlUiE2eDirtyEventReport" $report.sourceControlUiDirtyGenerationCancellationLoadWorkflow.firstDirtyEventReport.kind "Dirty-generation cancellation workflow should include the first dirty-event report."
  Assert-Equal "subversionr.installedSourceControlUiE2eDirtyEventReport" $report.sourceControlUiDirtyGenerationCancellationLoadWorkflow.secondDirtyEventReport.kind "Dirty-generation cancellation workflow should include the second dirty-event report."
  Assert-Equal "True" ([string]$report.sourceControlUiDirtyGenerationCancellationLoadWorkflow.firstDirtyEventReport.accepted) "Dirty-generation cancellation workflow should prove the first dirty event entered the pipeline."
  Assert-Equal "True" ([string]$report.sourceControlUiDirtyGenerationCancellationLoadWorkflow.secondDirtyEventReport.accepted) "Dirty-generation cancellation workflow should prove the superseding dirty event entered the pipeline."
  Assert-Equal "subversionr.installedSourceControlUiE2eDirtyGenerationCancellationReport" $report.sourceControlUiDirtyGenerationCancellationLoadWorkflow.cancellationReport.kind "Dirty-generation cancellation workflow should include the hidden cancellation probe report."
  Assert-Equal "load/modified-002.txt" $report.sourceControlUiDirtyGenerationCancellationLoadWorkflow.cancellationReport.target.path "Dirty-generation cancellation probe should hold the first load target."
  Assert-Equal "fileChanged" $report.sourceControlUiDirtyGenerationCancellationLoadWorkflow.cancellationReport.target.reason "Dirty-generation cancellation probe should use watcher fileChanged semantics."
  Assert-Equal "True" ([string]$report.sourceControlUiDirtyGenerationCancellationLoadWorkflow.cancellationReport.assertions.matchedDirtyGenerationTarget) "Dirty-generation cancellation probe should match the held load target."
  Assert-Equal "True" ([string]$report.sourceControlUiDirtyGenerationCancellationLoadWorkflow.cancellationReport.assertions.signalProvided) "Dirty-generation cancellation probe should prove a status refresh signal was provided."
  Assert-Equal "True" ([string]$report.sourceControlUiDirtyGenerationCancellationLoadWorkflow.cancellationReport.assertions.signalAborted) "Dirty-generation cancellation probe should prove the status refresh signal was aborted."
  Assert-Equal "True" ([string]$report.sourceControlUiDirtyGenerationCancellationLoadWorkflow.cancellationReport.assertions.cancellationObserved) "Dirty-generation cancellation probe should observe scheduler cancellation."
  Assert-Equal "dirtyGenerationSuperseded" $report.sourceControlUiDirtyGenerationCancellationLoadWorkflow.assertions.cancellationReason "Dirty-generation cancellation workflow should record the dirtyGenerationSuperseded reason."
  Assert-Equal "True" ([string]$report.sourceControlUiDirtyGenerationCancellationLoadWorkflow.assertions.firstRefreshObservedBeforeSupersede) "Dirty-generation cancellation workflow should prove the first refresh was in flight before supersede."
  Assert-Equal "True" ([string]$report.sourceControlUiDirtyGenerationCancellationLoadWorkflow.assertions.postCancellationStaleCaptureAvailable) "Dirty-generation cancellation workflow should capture stale Source Control state after the cancellation sequence."
  Assert-Equal "True" ([string]$report.sourceControlUiDirtyGenerationCancellationLoadWorkflow.assertions.postCancellationRefreshAttempted) "Dirty-generation cancellation workflow should attempt a post-cancellation installed Refresh."
  Assert-Equal "True" ([string]$report.sourceControlUiDirtyGenerationCancellationLoadWorkflow.assertions.completedCoverageMatchedSupersededTargets) "Dirty-generation cancellation workflow should prove completed coverage includes both superseded load targets."
  Assert-Equal "stale" $report.sourceControlUiDirtyGenerationCancellationLoadWorkflow.postCancellationFreshnessReport.scenario "Dirty-generation cancellation workflow should capture stale freshness after cancellation."
  Assert-Equal "partial" $report.sourceControlUiDirtyGenerationCancellationLoadWorkflow.postCancellationCompletionFreshnessReport.scenario "Dirty-generation cancellation workflow should capture partial freshness after post-cancellation completion."
  Assert-Equal "load/modified-002.txt" $report.sourceControlUiDirtyGenerationCancellationLoadWorkflow.postCancellationCompletionFreshnessReport.lastCompletedRefresh.targets[0].path "Dirty-generation cancellation completed coverage should include the held load target."
  Assert-Equal "load/modified-003.txt" $report.sourceControlUiDirtyGenerationCancellationLoadWorkflow.postCancellationCompletionFreshnessReport.lastCompletedRefresh.targets[1].path "Dirty-generation cancellation completed coverage should include the superseding load target."
  Assert-Equal "subversionr.installedSourceControlUiE2eCloseReport" $report.sourceControlUiCloseReport.kind "Installed Source Control UI E2E evidence should include a close report."
  Assert-Equal "subversionr.installedRepositoryLifecycleReport" $report.repositoryLifecycleDeletionReport.kind "Installed Source Control UI E2E evidence should include a deletion lifecycle report."
  Assert-Equal "deletedWorkingCopy" $report.repositoryLifecycleDeletionReport.request.scenario "Installed Source Control UI E2E deletion lifecycle report should prove the deleted-working-copy scenario."
  Assert-Equal "True" ([string]$report.repositoryLifecycleDeletionReport.assertions.missingWorkingCopyClosed) "Installed Source Control UI E2E deletion lifecycle report should prove missing working-copy closure."
  Assert-Equal "subversionr.installedRepositoryLifecycleReport" $report.repositoryLifecycleMoveReport.kind "Installed Source Control UI E2E evidence should include a move lifecycle report."
  Assert-Equal "movedWorkingCopy" $report.repositoryLifecycleMoveReport.request.scenario "Installed Source Control UI E2E move lifecycle report should prove the moved-working-copy scenario."
  Assert-Equal "True" ([string]$report.repositoryLifecycleMoveReport.assertions.movedWorkingCopyRecovered) "Installed Source Control UI E2E move lifecycle report should prove moved working-copy recovery."
  Assert-Equal "subversionr.installedSourceControlUiE2eDeleteUnversionedWorkflow" $report.sourceControlUiDeleteUnversionedWorkflow.kind "Installed Source Control UI E2E evidence should include a Delete Unversioned workflow report."
  Assert-Equal "subversionr.deleteUnversionedResource" $report.sourceControlUiDeleteUnversionedWorkflow.command.command "Delete Unversioned workflow should execute the installed command."
  Assert-Equal "scratch.txt" $report.sourceControlUiDeleteUnversionedWorkflow.resource.path "Delete Unversioned workflow should target the unversioned fixture resource."
  $deleteFreshnessUnversionedGroup = @($report.sourceControlUiDeleteUnversionedFreshnessReport.sourceControl.groups | Where-Object { $_.id -eq "unversioned" })[0]
  $deleteFreshnessScratch = @($deleteFreshnessUnversionedGroup.resources | Where-Object { $_.path -eq "scratch.txt" })[0]
  Assert-Equal ([string]$deleteFreshnessScratch.generation) ([string]$report.sourceControlUiDeleteUnversionedWorkflow.resource.generation) "Delete Unversioned workflow should use the just-in-time SourceControl generation."
  Assert-Equal "True" ([string]$report.sourceControlUiDeleteUnversionedWorkflow.assertions.fileExistedBefore) "Delete Unversioned workflow should prove the fixture file existed before deletion."
  Assert-Equal "False" ([string]$report.sourceControlUiDeleteUnversionedWorkflow.assertions.fileExistsAfter) "Delete Unversioned workflow should prove the fixture file was deleted."
  Assert-Equal "False" ([string]$report.sourceControlUiDeleteUnversionedWorkflow.assertions.resourcePresentAfter) "Delete Unversioned workflow should prove the SourceControl projection no longer includes the deleted unversioned resource."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.deleteUnversionedPromptCapture.schema "Installed Source Control UI E2E evidence should include Delete Unversioned prompt capture evidence."
  Assert-Equal "Delete" $report.deleteUnversionedPromptCapture.interaction.clickedButtonText "Delete Unversioned prompt capture should click the Delete confirmation."
  Assert-Equal "True" ([string]$report.deleteUnversionedPromptCapture.interaction.clicked) "Delete Unversioned prompt capture should prove the confirmation click completed."
  Assert-Equal "subversionr.installedSourceControlUiE2eDeleteUnversionedLoadWorkflow" $report.sourceControlUiDeleteUnversionedLoadWorkflow.kind "Installed Source Control UI E2E evidence should include a Delete Unversioned load workflow report."
  Assert-Equal "subversionr.deleteAllUnversionedResources" $report.sourceControlUiDeleteUnversionedLoadWorkflow.command.command "Delete Unversioned load workflow should execute the installed delete-all command."
  Assert-Equal "64" ([string]$report.sourceControlUiDeleteUnversionedLoadWorkflow.load.requestedItemCount) "Delete Unversioned load workflow should record the requested load item count."
  Assert-Equal "64" ([string]$report.sourceControlUiDeleteUnversionedLoadWorkflow.load.projectedItemCountBefore) "Delete Unversioned load workflow should prove every load item was projected before deletion."
  Assert-Equal "0" ([string]$report.sourceControlUiDeleteUnversionedLoadWorkflow.load.projectedItemCountAfter) "Delete Unversioned load workflow should prove no load item remains projected."
  Assert-Equal "False" ([string]$report.sourceControlUiDeleteUnversionedLoadWorkflow.assertions.anyFileExistsAfter) "Delete Unversioned load workflow should prove no load file remains on disk."
  Assert-Equal "True" ([string]$report.sourceControlUiDeleteUnversionedLoadWorkflow.assertions.sourceControlProjectionCleared) "Delete Unversioned load workflow should prove SourceControl projection cleared under load."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.deleteUnversionedLoadPromptCapture.schema "Installed Source Control UI E2E evidence should include Delete Unversioned load prompt capture evidence."
  Assert-Equal "Delete" $report.deleteUnversionedLoadPromptCapture.interaction.clickedButtonText "Delete Unversioned load prompt capture should click the Delete confirmation."
  Assert-Equal "True" ([string]$report.deleteUnversionedLoadPromptCapture.interaction.clicked) "Delete Unversioned load prompt capture should prove the confirmation click completed."
  Assert-Equal "subversionr.installedSourceControlUiE2eRemoveKeepLocalWorkflow" $report.sourceControlUiRemoveKeepLocalWorkflow.kind "Installed Source Control UI E2E evidence should include a Keep-local Remove workflow report."
  Assert-Equal "subversionr.removeResourceKeepLocal" $report.sourceControlUiRemoveKeepLocalWorkflow.command.command "Keep-local Remove workflow should execute the installed command."
  Assert-Equal "src/tracked.txt" $report.sourceControlUiRemoveKeepLocalWorkflow.resource.path "Keep-local Remove workflow should target the changed fixture resource."
  Assert-Equal "subversionr.installedSourceControlUiE2eFreshnessReport" $report.sourceControlUiRemoveKeepLocalWorkflow.preRemoveFreshnessReport.kind "Keep-local Remove workflow should include just-in-time SourceControl evidence before constructing the command argument."
  $keepLocalPreRemoveChangedGroup = @($report.sourceControlUiRemoveKeepLocalWorkflow.preRemoveFreshnessReport.sourceControl.groups | Where-Object { $_.id -eq "changes" })[0]
  $keepLocalPreRemoveResource = @($keepLocalPreRemoveChangedGroup.resources | Where-Object { $_.path -eq "src/tracked.txt" })[0]
  Assert-Equal ([string]$keepLocalPreRemoveResource.generation) ([string]$report.sourceControlUiRemoveKeepLocalWorkflow.resource.generation) "Keep-local Remove workflow should use the just-in-time SourceControl generation."
  Assert-Equal "True" ([string]$report.sourceControlUiRemoveKeepLocalWorkflow.assertions.fileExistedBefore) "Keep-local Remove workflow should prove the fixture file existed before removal."
  Assert-Equal "True" ([string]$report.sourceControlUiRemoveKeepLocalWorkflow.assertions.fileExistsAfter) "Keep-local Remove workflow should prove keep-local preserved the working-copy file."
  Assert-Equal "True" ([string]$report.sourceControlUiRemoveKeepLocalWorkflow.assertions.sourceControlProjectionRefreshed) "Keep-local Remove workflow should prove SourceControl projection refreshed after removal."
  Assert-Equal "subversionr.changedFile" $report.sourceControlUiRemoveKeepLocalWorkflow.postRemoveResource.contextValue "Keep-local Remove workflow should prove the resource is no longer base-diffable after scheduled deletion."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.removeKeepLocalPromptCapture.schema "Installed Source Control UI E2E evidence should include Keep-local Remove prompt capture evidence."
  Assert-Equal "Remove" $report.removeKeepLocalPromptCapture.interaction.clickedButtonText "Keep-local Remove prompt capture should click the Remove confirmation."
  Assert-Equal "True" ([string]$report.removeKeepLocalPromptCapture.interaction.clicked) "Keep-local Remove prompt capture should prove the confirmation click completed."
  Assert-Equal "subversionr.installedSourceControlUiE2eRevertWorkflow" $report.sourceControlUiRevertWorkflow.kind "Installed Source Control UI E2E evidence should include a Revert workflow report."
  Assert-Equal "subversionr.revertResource" $report.sourceControlUiRevertWorkflow.command.command "Revert workflow should execute the installed command."
  Assert-Equal "src/tracked.txt" $report.sourceControlUiRevertWorkflow.resource.path "Revert workflow should target the changed fixture resource."
  Assert-Equal "True" ([string]$report.sourceControlUiRevertWorkflow.assertions.fileExistedBefore) "Revert workflow should prove the fixture file existed before revert."
  Assert-Equal "initial`n" $report.sourceControlUiRevertWorkflow.assertions.fileContentAfter "Revert workflow should prove the file content returned to the repository baseline."
  Assert-Equal "False" ([string]$report.sourceControlUiRevertWorkflow.assertions.resourcePresentAfter) "Revert workflow should prove the reverted changed resource disappeared from SourceControl projection."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.revertPromptCapture.schema "Installed Source Control UI E2E evidence should include Revert prompt capture evidence."
  Assert-Equal "Revert" $report.revertPromptCapture.interaction.clickedButtonText "Revert prompt capture should click the Revert confirmation."
  Assert-Equal "True" ([string]$report.revertPromptCapture.interaction.clicked) "Revert prompt capture should prove the confirmation click completed."
  Assert-Equal "subversionr.installedSourceControlUiE2eRevertCancellationWorkflow" $report.sourceControlUiRevertCancellationWorkflow.kind "Installed Source Control UI E2E evidence should include a Revert cancellation workflow report."
  Assert-Equal "subversionr.revertResource" $report.sourceControlUiRevertCancellationWorkflow.command.command "Revert cancellation workflow should execute the installed Revert command."
  Assert-Equal "src/tracked.txt" $report.sourceControlUiRevertCancellationWorkflow.resource.path "Revert cancellation workflow should target the changed fixture resource."
  Assert-Equal "notifications.clearAll" $report.sourceControlUiRevertCancellationWorkflow.prompt.cancelAction "Revert cancellation workflow should record notification cleanup as the cancellation action."
  Assert-Equal "notifications.clearAll" $report.sourceControlUiRevertCancellationWorkflow.notificationCleanup.command "Revert cancellation workflow should clear the notification through the explicit VS Code command."
  Assert-Equal "revertCancellation" $report.sourceControlUiRevertCancellationWorkflow.notificationCleanup.label "Revert cancellation workflow should record its notification cleanup label."
  Assert-Equal "True" ([string]$report.sourceControlUiRevertCancellationWorkflow.notificationCleanup.cleared) "Revert cancellation workflow should prove notification cleanup completed."
  Assert-Equal "True" ([string]$report.sourceControlUiRevertCancellationWorkflow.assertions.fileExistedBefore) "Revert cancellation workflow should prove the fixture file existed before cancellation."
  Assert-Equal "True" ([string]$report.sourceControlUiRevertCancellationWorkflow.assertions.commandCancelled) "Revert cancellation workflow should prove the Revert command returned through cancellation."
  Assert-Equal "modified by M7j3`n" $report.sourceControlUiRevertCancellationWorkflow.assertions.fileContentAfter "Revert cancellation workflow should prove the file content stayed modified after cancellation."
  Assert-Equal "True" ([string]$report.sourceControlUiRevertCancellationWorkflow.assertions.resourcePresentAfter) "Revert cancellation workflow should prove the changed resource stayed projected after cancellation."
  Assert-Equal "True" ([string]$report.sourceControlUiRevertCancellationWorkflow.assertions.sourceControlProjectionUnchanged) "Revert cancellation workflow should prove SourceControl projection stayed unchanged after cancellation."
  Assert-Equal "subversionr.changedFile.baseDiffable" $report.sourceControlUiRevertCancellationWorkflow.postCancelResource.contextValue "Revert cancellation workflow should prove the resource remains base-diffable after cancellation."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.revertCancellationPromptCapture.schema "Installed Source Control UI E2E evidence should include Revert cancellation prompt capture evidence."
  Assert-Equal "True" ([string]$report.revertCancellationPromptCapture.assertions.domRequiredTokensPresent) "Revert cancellation prompt capture should prove the notification text rendered before cleanup."
  Assert-Equal "True" ([string]$report.revertCancellationPromptCapture.assertions.accessibilityRequiredTokensPresent) "Revert cancellation prompt capture should prove the notification was accessibility-visible before cleanup."
  Assert-Equal "subversionr.installedSourceControlUiE2eAddWorkflow" $report.sourceControlUiAddWorkflow.kind "Installed Source Control UI E2E evidence should include an Add workflow report."
  Assert-Equal "subversionr.addResource" $report.sourceControlUiAddWorkflow.command.command "Add workflow should execute the installed command."
  Assert-Equal "scratch.txt" $report.sourceControlUiAddWorkflow.resource.path "Add workflow should target the unversioned fixture resource."
  Assert-Equal "True" ([string]$report.sourceControlUiAddWorkflow.assertions.fileExistedBefore) "Add workflow should prove the fixture file existed before add."
  Assert-Equal "True" ([string]$report.sourceControlUiAddWorkflow.assertions.fileExistsAfter) "Add workflow should prove the working-copy file remains after add."
  Assert-Equal "True" ([string]$report.sourceControlUiAddWorkflow.assertions.sourceControlProjectionRefreshed) "Add workflow should prove SourceControl projection refreshed after add."
  Assert-Equal "subversionr.changedFile" $report.sourceControlUiAddWorkflow.postAddResource.contextValue "Add workflow should prove the resource moved from unversioned to local changes."
  Assert-Equal "subversionr.installedSourceControlUiE2eMoveWorkflow" $report.sourceControlUiMoveWorkflow.kind "Installed Source Control UI E2E evidence should include a Move workflow report."
  Assert-Equal "subversionr.moveResource" $report.sourceControlUiMoveWorkflow.command.command "Move workflow should execute the installed command."
  Assert-Equal "src/tracked.txt" $report.sourceControlUiMoveWorkflow.resource.path "Move workflow should target the changed fixture resource."
  Assert-Equal "src/moved.txt" $report.sourceControlUiMoveWorkflow.request.destinationPath "Move workflow should record the repository-relative destination path."
  Assert-Equal "True" ([string]$report.sourceControlUiMoveWorkflow.assertions.sourceFileExistedBefore) "Move workflow should prove the source file existed before move."
  Assert-Equal "False" ([string]$report.sourceControlUiMoveWorkflow.assertions.sourceFileExistsAfter) "Move workflow should prove the source path is gone after move."
  Assert-Equal "True" ([string]$report.sourceControlUiMoveWorkflow.assertions.destinationFileExistsAfter) "Move workflow should prove the destination file exists after move."
  Assert-Equal "True" ([string]$report.sourceControlUiMoveWorkflow.assertions.sourceControlProjectionRefreshed) "Move workflow should prove SourceControl projection refreshed after move."
  Assert-Equal "subversionr.changedFile" $report.sourceControlUiMoveWorkflow.postMoveSourceResource.contextValue "Move workflow should prove the source deletion is projected after move."
  Assert-Equal "subversionr.changedFile" $report.sourceControlUiMoveWorkflow.postMoveDestinationResource.contextValue "Move workflow should prove the destination addition is projected after move."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.movePromptCapture.schema "Installed Source Control UI E2E evidence should include Move prompt capture evidence."
  Assert-Equal "src/moved.txt" $report.movePromptCapture.interaction.enteredText "Move prompt capture should type the destination path into the QuickInput."
  Assert-Equal "Enter" $report.movePromptCapture.interaction.submittedKey "Move prompt capture should submit the destination path through Enter."
  Assert-Equal "subversionr.installedSourceControlUiE2eMoveCancellationWorkflow" $report.sourceControlUiMoveCancellationWorkflow.kind "Installed Source Control UI E2E evidence should include a Move cancellation workflow report."
  Assert-Equal "subversionr.moveResource" $report.sourceControlUiMoveCancellationWorkflow.command.command "Move cancellation workflow should execute the installed Move command."
  Assert-Equal "src/tracked.txt" $report.sourceControlUiMoveCancellationWorkflow.resource.path "Move cancellation workflow should target the changed fixture resource."
  Assert-Equal "Escape" $report.sourceControlUiMoveCancellationWorkflow.prompt.cancelKey "Move cancellation workflow should record Escape as the QuickInput cancellation key."
  Assert-Equal "True" ([string]$report.sourceControlUiMoveCancellationWorkflow.assertions.sourceFileExistedBefore) "Move cancellation workflow should prove the source file existed before cancellation."
  Assert-Equal "True" ([string]$report.sourceControlUiMoveCancellationWorkflow.assertions.commandCancelled) "Move cancellation workflow should prove the Move command returned through cancellation."
  Assert-Equal "True" ([string]$report.sourceControlUiMoveCancellationWorkflow.assertions.sourceFileExistsAfter) "Move cancellation workflow should prove the source path remains after cancellation."
  Assert-Equal "False" ([string]$report.sourceControlUiMoveCancellationWorkflow.assertions.destinationFileExistsAfter) "Move cancellation workflow should prove no destination file was created after cancellation."
  Assert-Equal "True" ([string]$report.sourceControlUiMoveCancellationWorkflow.assertions.sourceControlProjectionUnchanged) "Move cancellation workflow should prove SourceControl projection stayed unchanged after cancellation."
  Assert-Equal "subversionr.changedFile.baseDiffable" $report.sourceControlUiMoveCancellationWorkflow.postCancelSourceResource.contextValue "Move cancellation workflow should prove the source remains projected as the changed base-diffable resource."
  Assert-Equal "False" ([string]$report.sourceControlUiMoveCancellationWorkflow.postCancelDestinationResourcePresent) "Move cancellation workflow should prove no destination resource was projected after cancellation."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.moveCancellationPromptCapture.schema "Installed Source Control UI E2E evidence should include Move cancellation prompt capture evidence."
  Assert-Equal "Escape" $report.moveCancellationPromptCapture.interaction.cancelledKey "Move cancellation prompt capture should cancel the QuickInput with Escape."
  Assert-Equal "True" ([string]$report.moveCancellationPromptCapture.interaction.cancelled) "Move cancellation prompt capture should prove the cancellation completed."
  Assert-Equal "subversionr.installedSourceControlUiE2eRemoveWorkflow" $report.sourceControlUiRemoveWorkflow.kind "Installed Source Control UI E2E evidence should include a Remove workflow report."
  Assert-Equal "subversionr.removeResource" $report.sourceControlUiRemoveWorkflow.command.command "Remove workflow should execute the installed command."
  Assert-Equal "src/tracked.txt" $report.sourceControlUiRemoveWorkflow.resource.path "Remove workflow should target the missing versioned fixture resource."
  Assert-Equal "False" ([string]$report.sourceControlUiRemoveWorkflow.assertions.fileExistedBefore) "Remove workflow should prove the missing fixture file was absent before remove."
  Assert-Equal "False" ([string]$report.sourceControlUiRemoveWorkflow.assertions.fileExistsAfter) "Remove workflow should prove the file remained absent after scheduled removal."
  Assert-Equal "True" ([string]$report.sourceControlUiRemoveWorkflow.assertions.sourceControlProjectionRefreshed) "Remove workflow should prove SourceControl projection refreshed after remove."
  Assert-Equal "subversionr.changedFile" $report.sourceControlUiRemoveWorkflow.postRemoveResource.contextValue "Remove workflow should prove the resource is projected as a scheduled local deletion."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.removePromptCapture.schema "Installed Source Control UI E2E evidence should include Remove prompt capture evidence."
  Assert-Equal "Remove" $report.removePromptCapture.interaction.clickedButtonText "Remove prompt capture should click the Remove confirmation."
  Assert-Equal "True" ([string]$report.removePromptCapture.interaction.clicked) "Remove prompt capture should prove the confirmation click completed."
  Assert-Equal "subversionr.installedSourceControlUiE2eRemoveCancellationWorkflow" $report.sourceControlUiRemoveCancellationWorkflow.kind "Installed Source Control UI E2E evidence should include a Remove cancellation workflow report."
  Assert-Equal "subversionr.removeResource" $report.sourceControlUiRemoveCancellationWorkflow.command.command "Remove cancellation workflow should execute the installed Remove command."
  Assert-Equal "src/tracked.txt" $report.sourceControlUiRemoveCancellationWorkflow.resource.path "Remove cancellation workflow should target the changed fixture resource."
  Assert-Equal "subversionr.changedFile.baseDiffable" $report.sourceControlUiRemoveCancellationWorkflow.resource.contextValue "Remove cancellation workflow should start from the changed base-diffable SourceControl resource."
  Assert-Equal "notifications.clearAll" $report.sourceControlUiRemoveCancellationWorkflow.prompt.cancelAction "Remove cancellation workflow should record notification cleanup as the cancellation action."
  Assert-Equal "notifications.clearAll" $report.sourceControlUiRemoveCancellationWorkflow.notificationCleanup.command "Remove cancellation workflow should clear the notification through the explicit VS Code command."
  Assert-Equal "removeCancellation" $report.sourceControlUiRemoveCancellationWorkflow.notificationCleanup.label "Remove cancellation workflow should record its notification cleanup label."
  Assert-Equal "True" ([string]$report.sourceControlUiRemoveCancellationWorkflow.notificationCleanup.cleared) "Remove cancellation workflow should prove notification cleanup completed."
  Assert-Equal "True" ([string]$report.sourceControlUiRemoveCancellationWorkflow.assertions.commandCancelled) "Remove cancellation workflow should prove the Remove command returned through cancellation."
  Assert-Equal "True" ([string]$report.sourceControlUiRemoveCancellationWorkflow.assertions.fileExistedBefore) "Remove cancellation workflow should prove the fixture file existed before cancellation."
  Assert-Equal "True" ([string]$report.sourceControlUiRemoveCancellationWorkflow.assertions.fileExistsAfter) "Remove cancellation workflow should prove the fixture file stayed on disk after cancellation."
  Assert-Equal "modified by M7j3`n" $report.sourceControlUiRemoveCancellationWorkflow.assertions.fileContentAfter "Remove cancellation workflow should prove the file content stayed modified after cancellation."
  Assert-Equal "True" ([string]$report.sourceControlUiRemoveCancellationWorkflow.assertions.sourceControlProjectionUnchanged) "Remove cancellation workflow should prove SourceControl projection stayed unchanged after cancellation."
  Assert-Equal "subversionr.changedFile.baseDiffable" $report.sourceControlUiRemoveCancellationWorkflow.postCancelResource.contextValue "Remove cancellation workflow should prove the resource remains base-diffable after cancellation."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.removeCancellationPromptCapture.schema "Installed Source Control UI E2E evidence should include Remove cancellation prompt capture evidence."
  Assert-Equal "True" ([string]$report.removeCancellationPromptCapture.assertions.domRequiredTokensPresent) "Remove cancellation prompt capture should prove the notification text rendered before cleanup."
  Assert-Equal "True" ([string]$report.removeCancellationPromptCapture.assertions.accessibilityRequiredTokensPresent) "Remove cancellation prompt capture should prove the notification was accessibility-visible before cleanup."
  Assert-Equal "subversionr.installedSourceControlUiE2eResolveWorkflow" $report.sourceControlUiResolveWorkflow.kind "Installed Source Control UI E2E evidence should include a Resolve workflow report."
  Assert-Equal "subversionr.resolveResource" $report.sourceControlUiResolveWorkflow.command.command "Resolve workflow should execute the installed command."
  Assert-Equal "subversionr.updateRepository" $report.sourceControlUiResolveWorkflow.updateConflict.command "Resolve workflow should first create the conflict through installed Update."
  Assert-Equal "1" ([string]$report.sourceControlUiResolveWorkflow.updateConflict.conflictCount) "Installed Update warning should report one conflict."
  Assert-Equal "src/tracked.txt" @($report.sourceControlUiResolveWorkflow.updateConflict.conflictPaths)[0] "Installed Update warning should name src/tracked.txt."
  Assert-Equal "False" ([string]$report.sourceControlUiResolveWorkflow.updateConflict.warning.plainSuccessNotificationExpected) "Installed Update conflict workflow should forbid a separate plain-success notification."
  Assert-Equal "True" ([string]$report.sourceControlUiResolveWorkflow.assertions.installedUpdateCreatedConflict) "Installed Update should create the projected conflict."
  Assert-Equal "svn status --xml" $report.updateConflictWorkingCopyOracle.command "Installed Update conflict evidence should bind the SVN XML oracle."
  Assert-Equal "1" ([string]$report.updateConflictWorkingCopyOracle.conflictCount) "SVN XML oracle should report one conflict."
  Assert-Equal "src/tracked.txt" @($report.updateConflictWorkingCopyOracle.conflictPaths)[0] "SVN XML oracle should name src/tracked.txt."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.resolveUpdateWarningCapture.schema "Installed Update conflict evidence should include warning renderer capture."
  Assert-Equal "True" ([string]$report.resolveUpdateWarningCapture.assertions.domRequiredTokensPresent) "Installed Update conflict warning DOM tokens should be present."
  Assert-Equal "True" ([string]$report.resolveUpdateWarningCapture.assertions.accessibilityRequiredTokensPresent) "Installed Update conflict warning accessibility tokens should be present."
  Assert-Equal "True" ([string]$report.resolveUpdateWarningPlainSuccessAbsent) "Installed Update conflict evidence should prove no separate plain-success notification."
  Assert-Equal "src/tracked.txt" $report.sourceControlUiResolveWorkflow.resource.path "Resolve workflow should target the conflicted fixture resource."
  Assert-Equal "subversionr.conflicted" $report.sourceControlUiResolveWorkflow.resource.contextValue "Resolve workflow should start from a conflicted SourceControl resource."
  Assert-Equal "working" $report.sourceControlUiResolveWorkflow.request.choice "Resolve workflow should prove the working-copy resolve choice."
  Assert-Equal "empty" $report.sourceControlUiResolveWorkflow.request.depth "Resolve workflow should prove the single-resource empty depth."
  Assert-Equal "True" ([string]$report.sourceControlUiResolveWorkflow.assertions.conflictProjectedBefore) "Resolve workflow should prove the conflict was projected before resolve."
  Assert-Equal "True" ([string]$report.sourceControlUiResolveWorkflow.assertions.fileContentPreservedAfter) "Resolve workflow should prove merged resolve preserved working-copy content."
  Assert-Equal "False" ([string]$report.sourceControlUiResolveWorkflow.assertions.conflictProjectedAfter) "Resolve workflow should prove the conflict left SourceControl projection after resolve."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.resolvePromptCapture.schema "Installed Source Control UI E2E evidence should include Resolve prompt capture evidence."
  Assert-Equal "Working copy" $report.resolvePromptCapture.interaction.selectedText "Resolve prompt capture should select the Working copy QuickPick item."
  Assert-Equal "True" ([string]$report.resolvePromptCapture.assertions.quickPickItemSelected) "Resolve prompt capture should prove the QuickPick selection completed."
  Assert-Equal "subversionr.installedSourceControlUiE2eResolveCancellationWorkflow" $report.sourceControlUiResolveCancellationWorkflow.kind "Installed Source Control UI E2E evidence should include a Resolve cancellation workflow report."
  Assert-Equal "subversionr.resolveResource" $report.sourceControlUiResolveCancellationWorkflow.command.command "Resolve cancellation workflow should execute the installed Resolve command."
  Assert-Equal "src/tracked.txt" $report.sourceControlUiResolveCancellationWorkflow.resource.path "Resolve cancellation workflow should target the conflicted fixture resource."
  Assert-Equal "subversionr.conflicted" $report.sourceControlUiResolveCancellationWorkflow.resource.contextValue "Resolve cancellation workflow should start from a conflicted SourceControl resource."
  Assert-Equal "Escape" $report.sourceControlUiResolveCancellationWorkflow.prompt.cancelKey "Resolve cancellation workflow should record Escape as the cancellation key."
  Assert-Equal "notifications.clearAll" $report.sourceControlUiResolveCancellationWorkflow.notificationCleanup.command "Resolve cancellation workflow should clear stale notifications before exposing the QuickInput."
  Assert-Equal "resolveResourceCancellation" $report.sourceControlUiResolveCancellationWorkflow.notificationCleanup.label "Resolve cancellation workflow should record its notification cleanup label."
  Assert-Equal "True" ([string]$report.sourceControlUiResolveCancellationWorkflow.notificationCleanup.cleared) "Resolve cancellation workflow should prove stale notifications were cleared."
  Assert-Equal "True" ([string]$report.sourceControlUiResolveCancellationWorkflow.assertions.commandCancelled) "Resolve cancellation workflow should prove the Resolve command returned through cancellation."
  Assert-Equal "True" ([string]$report.sourceControlUiResolveCancellationWorkflow.assertions.conflictProjectedBefore) "Resolve cancellation workflow should prove the conflict was projected before cancellation."
  Assert-Equal "True" ([string]$report.sourceControlUiResolveCancellationWorkflow.assertions.conflictProjectedAfter) "Resolve cancellation workflow should prove the conflict stayed projected after cancellation."
  Assert-Equal "True" ([string]$report.sourceControlUiResolveCancellationWorkflow.assertions.fileContentPreservedAfter) "Resolve cancellation workflow should prove the working-copy conflict content stayed unchanged after cancellation."
  Assert-Equal "True" ([string]$report.sourceControlUiResolveCancellationWorkflow.assertions.sourceControlProjectionUnchanged) "Resolve cancellation workflow should prove SourceControl projection stayed unchanged after cancellation."
  Assert-Equal "subversionr.conflicted" $report.sourceControlUiResolveCancellationWorkflow.postCancelResource.contextValue "Resolve cancellation workflow should prove the resource remains conflicted after cancellation."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.resolveCancellationPromptCapture.schema "Installed Source Control UI E2E evidence should include Resolve cancellation prompt capture evidence."
  Assert-Equal "Escape" $report.resolveCancellationPromptCapture.interaction.cancelledKey "Resolve cancellation prompt capture should cancel the QuickInput with Escape."
  Assert-Equal "quickInput" $report.resolveCancellationPromptCapture.interaction.surface "Resolve cancellation prompt capture should prove the QuickInput surface was cancelled."
  Assert-Equal "True" ([string]$report.resolveCancellationPromptCapture.assertions.quickInputCancelled) "Resolve cancellation prompt capture should prove the QuickInput cancellation completed."
  Assert-Equal "True" ([string]$report.resolveCancellationPromptCapture.interaction.cancelled) "Resolve cancellation prompt capture should prove the cancellation completed."
  Assert-Equal "subversionr.installedSourceControlUiE2eCleanupWorkflow" $report.sourceControlUiCleanupWorkflow.kind "Installed Source Control UI E2E evidence should include a Cleanup workflow report."
  Assert-Equal "subversionr.cleanupRepository" $report.sourceControlUiCleanupWorkflow.command.command "Cleanup workflow should execute the installed repository command."
  Assert-Equal "." $report.sourceControlUiCleanupWorkflow.request.path "Cleanup workflow should target the working-copy root."
  Assert-Equal "True" ([string]$report.sourceControlUiCleanupWorkflow.request.breakLocks) "Cleanup workflow should use the conservative root cleanup lock break option."
  Assert-Equal "False" ([string]$report.sourceControlUiCleanupWorkflow.request.vacuumPristines) "Cleanup workflow should not enable vacuum cleanup."
  Assert-Equal "Enter" $report.sourceControlUiCleanupWorkflow.prompt.quickInputSubmitKey "Cleanup workflow should submit the installed cleanup options QuickInput with Enter."
  Assert-Equal "True" ([string]$report.sourceControlUiCleanupWorkflow.assertions.repositoryOpenBefore) "Cleanup workflow should prove the repository was open before cleanup."
  Assert-Equal "True" ([string]$report.sourceControlUiCleanupWorkflow.assertions.fullReconcileAfterCleanup) "Cleanup workflow should prove cleanup forced a full reconcile."
  Assert-Equal "True" ([string]$report.sourceControlUiCleanupWorkflow.assertions.sourceControlSurfaceAfterCleanup) "Cleanup workflow should prove SourceControl stayed available after cleanup."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.cleanupPromptCapture.schema "Installed Source Control UI E2E evidence should include Cleanup prompt capture evidence."
  Assert-Equal "Enter" $report.cleanupPromptCapture.interaction.submittedKey "Cleanup prompt capture should submit the QuickInput with Enter."
  Assert-Equal "quickInput" $report.cleanupPromptCapture.interaction.surface "Cleanup prompt capture should prove the QuickInput surface was submitted."
  Assert-Equal "True" ([string]$report.cleanupPromptCapture.assertions.quickInputSubmitted) "Cleanup prompt capture should prove QuickInput submission completed."
  Assert-Equal "subversionr.installedSourceControlUiE2eRefreshWorkflow" $report.sourceControlUiRefreshWorkflow.kind "Installed Source Control UI E2E evidence should include a Refresh workflow report."
  Assert-Equal "subversionr.refreshRepository" $report.sourceControlUiRefreshWorkflow.command.command "Refresh workflow should execute the installed repository refresh command."
  Assert-Equal $report.sourceControlUiOpenReport.repository.repositoryId $report.sourceControlUiRefreshWorkflow.repository.repositoryId "Refresh workflow should target the open repository."
  Assert-Equal "True" ([string]$report.sourceControlUiRefreshWorkflow.assertions.repositoryOpenBefore) "Refresh workflow should prove the repository was open before refresh."
  Assert-Equal "True" ([string]$report.sourceControlUiRefreshWorkflow.assertions.sourceControlSurfaceAfterRefresh) "Refresh workflow should prove SourceControl stayed available after refresh."
  Assert-Equal "partial" $report.sourceControlUiRefreshWorkflow.postRefreshFreshnessReport.scenario "Refresh workflow should record post-refresh partial SourceControl freshness evidence."
  Assert-Equal "subversionr.installedSourceControlUiE2eRefreshLoadWorkflow" $report.sourceControlUiRefreshLoadWorkflow.kind "Installed Source Control UI E2E evidence should include a Refresh load workflow report."
  Assert-Equal "subversionr.refreshRepository" $report.sourceControlUiRefreshLoadWorkflow.command.command "Refresh load workflow should execute the installed repository refresh command."
  Assert-Equal "64" ([string]$report.sourceControlUiRefreshLoadWorkflow.load.requestedModifiedItemCount) "Refresh load workflow should record the requested modified item count."
  Assert-Equal "64" ([string]$report.sourceControlUiRefreshLoadWorkflow.load.projectedModifiedItemCountBefore) "Refresh load workflow should prove every modified load item was projected before refresh."
  Assert-Equal "64" ([string]$report.sourceControlUiRefreshLoadWorkflow.load.projectedModifiedItemCountAfter) "Refresh load workflow should prove every modified load item remained projected after refresh."
  Assert-Equal "True" ([string]$report.sourceControlUiRefreshLoadWorkflow.assertions.allLoadResourcesProjectedBefore) "Refresh load workflow should prove all load resources were projected before refresh."
  Assert-Equal "True" ([string]$report.sourceControlUiRefreshLoadWorkflow.assertions.allLoadResourcesProjectedAfter) "Refresh load workflow should prove all load resources were projected after refresh."
  Assert-Equal "True" ([string]$report.sourceControlUiRefreshLoadWorkflow.assertions.sourceControlSurfaceAfterRefresh) "Refresh load workflow should prove SourceControl stayed available after refresh."
  Assert-Equal "subversionr.refreshResource" $report.sourceControlUiRefreshLoadWorkflow.resourceRefresh.command.command "Refresh load workflow should execute installed resource refresh for the restored load path."
  Assert-Equal "load/modified-001.txt" $report.sourceControlUiRefreshLoadWorkflow.resourceRefresh.restoredPath "Refresh load workflow should record the restored load path."
  Assert-Equal "64" ([string]$report.sourceControlUiRefreshLoadWorkflow.resourceRefresh.projectedModifiedItemCountBefore) "Refresh load workflow should record load projection before restored resource refresh."
  Assert-Equal "63" ([string]$report.sourceControlUiRefreshLoadWorkflow.resourceRefresh.projectedModifiedItemCountAfter) "Refresh load workflow should prove restored resource refresh removed exactly one normal load path."
  Assert-Equal "0" ([string]$report.sourceControlUiRefreshLoadWorkflow.resourceRefresh.projectedRestoredItemCountAfter) "Refresh load workflow should prove the restored normal path was removed from SourceControl."
  Assert-Equal "load/modified-001.txt" $report.sourceControlUiRefreshLoadWorkflow.resourceRefresh.coverage.targets[0].path "Refresh load workflow should record the restored resource refresh target path."
  Assert-Equal "empty" $report.sourceControlUiRefreshLoadWorkflow.resourceRefresh.coverage.targets[0].depth "Refresh load workflow should record empty-depth restored resource refresh target coverage."
  Assert-Equal "resourceRefresh" $report.sourceControlUiRefreshLoadWorkflow.resourceRefresh.coverage.targets[0].reason "Refresh load workflow should record resource-refresh target reason coverage."
  Assert-Equal "load/modified-001.txt" $report.sourceControlUiRefreshLoadWorkflow.resourceRefresh.coverage.coverage[0].path "Refresh load workflow should record returned restored resource coverage path."
  Assert-Equal "empty" $report.sourceControlUiRefreshLoadWorkflow.resourceRefresh.coverage.coverage[0].depth "Refresh load workflow should record returned restored resource coverage depth."
  Assert-Equal "resourceRefresh" $report.sourceControlUiRefreshLoadWorkflow.resourceRefresh.coverage.coverage[0].reason "Refresh load workflow should record returned restored resource coverage reason."
  Assert-Equal ([string]$report.sourceControlUiRefreshLoadWorkflow.resourceRefresh.coverage.generation) ([string]$report.sourceControlUiRefreshLoadWorkflow.resourceRefresh.coverage.coverage[0].generation) "Refresh load workflow should prove returned coverage generation matches the delta generation."
  Assert-Equal "True" ([string]$report.sourceControlUiRefreshLoadWorkflow.assertions.restoredPathProjectedBefore) "Refresh load workflow should prove the restored path was projected before resource refresh."
  Assert-Equal "True" ([string]$report.sourceControlUiRefreshLoadWorkflow.assertions.sourceControlProjectionRemovedRestoredPath) "Refresh load workflow should prove mark/sweep removed the restored path."
  Assert-Equal "True" ([string]$report.sourceControlUiRefreshLoadWorkflow.assertions.restoredPathCoverageMatched) "Refresh load workflow should prove the restored path coverage scope matched the resource refresh."
  Assert-Equal "True" ([string]$report.sourceControlUiRefreshLoadWorkflow.assertions.restoredPathCoverageGenerationMatched) "Refresh load workflow should prove restored path coverage generation matched the delta generation."
  Assert-Equal "True" ([string]$report.sourceControlUiRefreshLoadWorkflow.assertions.sourceControlSurfaceAfterResourceRefresh) "Refresh load workflow should prove SourceControl stayed available after restored resource refresh."
  Assert-Equal "subversionr.installedSourceControlUiE2eBoundaryLoadWorkflow" $report.sourceControlUiBoundaryLoadWorkflow.kind "Installed Source Control UI E2E evidence should include a boundary load workflow report."
  Assert-Equal "128" ([string]$report.sourceControlUiBoundaryLoadWorkflow.load.requestedParentModifiedItemCount) "Boundary load workflow should record the requested parent load item count."
  Assert-Equal "128" ([string]$report.sourceControlUiBoundaryLoadWorkflow.load.projectedParentModifiedItemCount) "Boundary load workflow should prove every parent load item was projected."
  Assert-Equal "128" ([string]$report.sourceControlUiBoundaryLoadWorkflow.load.requestedBoundaryModifiedItemCount) "Boundary load workflow should record the requested boundary load item count."
  Assert-Equal "0" ([string]$report.sourceControlUiBoundaryLoadWorkflow.load.projectedBoundaryModifiedItemCount) "Boundary load workflow should prove boundary load items were excluded from the parent provider."
  Assert-Equal "128" ([string]$report.sourceControlUiBoundaryLoadWorkflow.load.projectedExternalModifiedItemCount) "Boundary load workflow should prove boundary load items were projected by the external provider."
  Assert-True (@($report.sourceControlUiBoundaryLoadWorkflow.repository.boundaryRoots).Count -gt 0) "Boundary load workflow should record parent provider boundary roots."
  Assert-Equal "True" ([string]$report.sourceControlUiBoundaryLoadWorkflow.assertions.allParentLoadResourcesProjected) "Boundary load workflow should prove all parent load resources were projected."
  Assert-Equal "True" ([string]$report.sourceControlUiBoundaryLoadWorkflow.assertions.noBoundaryLoadResourcesProjected) "Boundary load workflow should prove boundary resources were excluded under load."
  Assert-Equal "True" ([string]$report.sourceControlUiBoundaryLoadWorkflow.assertions.allExternalLoadResourcesProjectedByExternalProvider) "Boundary load workflow should prove all external load resources were projected by the external provider."
  Assert-Equal "True" ([string]$report.sourceControlUiBoundaryLoadWorkflow.assertions.sourceControlSurfaceAvailable) "Boundary load workflow should prove SourceControl stayed available under boundary load."
  Assert-Equal "subversionr.installedSourceControlUiE2eMultiRepositoryRefreshWorkflow" $report.sourceControlUiMultiRepositoryRefreshWorkflow.kind "Installed Source Control UI E2E evidence should include a multi-repository Refresh workflow report."
  Assert-Equal "subversionr.refreshRepository" $report.sourceControlUiMultiRepositoryRefreshWorkflow.command.command "Multi-repository Refresh workflow should execute the installed repository refresh command."
  Assert-True ([string]$report.sourceControlUiMultiRepositoryRefreshWorkflow.selection.selectedWorkingCopyRoot -like "*multi-repository-refresh-fixture*") "Multi-repository Refresh workflow should select the second working-copy root."
  Assert-Equal "True" ([string]$report.sourceControlUiMultiRepositoryRefreshWorkflow.assertions.quickPickSelectionRequired) "Multi-repository Refresh workflow should prove the QuickPick selection path was required."
  Assert-Equal "True" ([string]$report.sourceControlUiMultiRepositoryRefreshWorkflow.assertions.selectedRepositoryDistinct) "Multi-repository Refresh workflow should prove the selected repository was distinct from the first repository."
  Assert-Equal "True" ([string]$report.sourceControlUiMultiRepositoryRefreshWorkflow.assertions.selectedRepositoryRefreshed) "Multi-repository Refresh workflow should prove the selected repository was refreshed."
  Assert-Equal "True" ([string]$report.sourceControlUiMultiRepositoryRefreshWorkflow.assertions.firstRepositoryStayedOpen) "Multi-repository Refresh workflow should prove the first repository remained open."
  Assert-Equal "partial" $report.sourceControlUiMultiRepositoryRefreshWorkflow.postRefreshFreshnessReport.scenario "Multi-repository Refresh workflow should record post-refresh partial SourceControl freshness evidence for the selected repository."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.multiRepositoryRefreshPromptCapture.schema "Installed Source Control UI E2E evidence should include multi-repository Refresh QuickPick capture evidence."
  Assert-True ([string]$report.multiRepositoryRefreshPromptCapture.interaction.selectedText -like "*multi-repository-refresh-fixture*") "Multi-repository Refresh prompt capture should select the second working-copy root."
  Assert-Equal "True" ([string]$report.multiRepositoryRefreshPromptCapture.assertions.domRequiredTokensPresent) "Multi-repository Refresh prompt DOM assertions should pass."
  Assert-Equal "True" ([string]$report.multiRepositoryRefreshPromptCapture.assertions.accessibilityRequiredTokensPresent) "Multi-repository Refresh prompt accessibility assertions should pass."
  Assert-Equal "True" ([string]$report.multiRepositoryRefreshPromptCapture.assertions.screenshotNonBlank) "Multi-repository Refresh prompt screenshot nonblank assertion should pass."
  Assert-Equal "True" ([string]$report.multiRepositoryRefreshPromptCapture.assertions.quickPickItemSelected) "Multi-repository Refresh prompt capture should prove the QuickPick item selection completed."
  Assert-Equal "subversionr.installedSourceControlUiE2eLazyExternalProviderReport" $report.sourceControlUiLazyExternalProviderWorkflow.kind "Installed Source Control UI E2E evidence should include a lazy external provider workflow report."
  Assert-Equal "lazy" $report.sourceControlUiLazyExternalProviderWorkflow.request.externalsMode "Lazy external provider workflow should request lazy externals discovery."
  Assert-Equal "4" ([string]$report.sourceControlUiLazyExternalProviderWorkflow.request.discoveryDepth) "Lazy external provider workflow should use the standard discovery depth."
  Assert-True (@($report.sourceControlUiLazyExternalProviderWorkflow.discovery.fileExternalBoundaries).Count -gt 0) "Lazy external provider workflow should record file external boundaries."
  Assert-True (@($report.sourceControlUiLazyExternalProviderWorkflow.parentProvider.boundaryRoots).Count -gt 0) "Lazy external provider workflow should record parent provider boundary roots."
  Assert-True (@($report.sourceControlUiLazyExternalProviderWorkflow.externalProviders.sourceControl.groups.resources | Where-Object { $_.path -eq "src/tracked.txt" }).Count -gt 0) "Lazy external provider workflow should prove the external provider projected the modified directory-external resource."
  Assert-Equal "True" ([string]$report.sourceControlUiLazyExternalProviderWorkflow.assertions.directoryExternalDiscovered) "Lazy external provider workflow should prove a directory external candidate was discovered."
  Assert-Equal "True" ([string]$report.sourceControlUiLazyExternalProviderWorkflow.assertions.fileExternalBoundariesDiscovered) "Lazy external provider workflow should prove file external boundaries were discovered."
  Assert-Equal "True" ([string]$report.sourceControlUiLazyExternalProviderWorkflow.assertions.parentBoundaryRootsIncludedDirectoryExternal) "Lazy external provider workflow should prove the directory external was included in parent boundary roots."
  Assert-Equal "True" ([string]$report.sourceControlUiLazyExternalProviderWorkflow.assertions.parentBoundaryRootsIncludedFileExternal) "Lazy external provider workflow should prove the file external was included in parent boundary roots."
  Assert-Equal "True" ([string]$report.sourceControlUiLazyExternalProviderWorkflow.assertions.distinctExternalProviderOpened) "Lazy external provider workflow should prove the directory external opened as a distinct provider."
  Assert-Equal "True" ([string]$report.sourceControlUiLazyExternalProviderWorkflow.assertions.parentSourceControlExcludedExternalBoundaries) "Lazy external provider workflow should prove parent SourceControl excluded external boundaries."
  Assert-Equal "True" ([string]$report.sourceControlUiLazyExternalProviderWorkflow.assertions.providersClosed) "Lazy external provider workflow should prove diagnostic providers were closed."
  Assert-Equal "subversionr.versionReport" $report.versionReport.kind "Installed Source Control UI E2E evidence should include a version report."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.rendererCapture.schema "Installed Source Control UI E2E evidence should include renderer capture evidence."
  Assert-Equal "captured" $report.rendererCapture.artifacts.dom.status "Renderer DOM artifact should be captured."
  Assert-Equal "captured" $report.rendererCapture.artifacts.accessibility.status "Renderer accessibility artifact should be captured."
  Assert-Equal "captured" $report.rendererCapture.artifacts.screenshot.status "Renderer screenshot artifact should be captured."
  Assert-Equal "True" ([string]$report.rendererCapture.assertions.domRequiredTokensPresent) "Renderer DOM assertions should pass."
  Assert-Equal "True" ([string]$report.rendererCapture.assertions.accessibilityRequiredTokensPresent) "Renderer accessibility assertions should pass."
  Assert-Equal "True" ([string]$report.rendererCapture.assertions.screenshotNonBlank) "Renderer screenshot nonblank assertion should pass."
  Assert-Equal "subversionr.release.installed-source-control-ui-renderer-capture.v1" $report.noRepositoryWelcomeRendererCapture.schema "Installed Source Control UI E2E evidence should include no-repository welcome renderer capture evidence."
  Assert-Equal "captured" $report.noRepositoryWelcomeRendererCapture.artifacts.dom.status "No-repository welcome DOM artifact should be captured."
  Assert-Equal "captured" $report.noRepositoryWelcomeRendererCapture.artifacts.accessibility.status "No-repository welcome accessibility artifact should be captured."
  Assert-Equal "captured" $report.noRepositoryWelcomeRendererCapture.artifacts.screenshot.status "No-repository welcome screenshot artifact should be captured."
  Assert-Equal "True" ([string]$report.noRepositoryWelcomeRendererCapture.assertions.domRequiredTokensPresent) "No-repository welcome DOM assertions should pass."
  Assert-Equal "True" ([string]$report.noRepositoryWelcomeRendererCapture.assertions.accessibilityRequiredTokensPresent) "No-repository welcome accessibility assertions should pass."
  Assert-Equal "True" ([string]$report.noRepositoryWelcomeRendererCapture.assertions.screenshotNonBlank) "No-repository welcome screenshot nonblank assertion should pass."
  Assert-True (@($report.noRepositoryWelcomeRendererCapture.artifacts.dom.requiredTokens | Where-Object { $_ -eq "No SVN working copy was found in the workspace" }).Count -eq 1) "No-repository welcome DOM capture should require the empty-state text."
  Assert-True (@($report.noRepositoryWelcomeRendererCapture.artifacts.dom.requiredTokens | Where-Object { $_ -eq "Scan for SVN Working Copies" }).Count -eq 1) "No-repository welcome DOM capture should require the Scan button text."
  Assert-True (@($report.noRepositoryWelcomeRendererCapture.artifacts.dom.requiredTokens | Where-Object { $_ -eq "Checkout Repository URL" }).Count -eq 1) "No-repository welcome DOM capture should require the Checkout button text."
  Assert-True (@($report.nonClaims | Where-Object { $_ -like "*full installed checkout command flow*" -or $_ -like "*does not execute the full checkout command flow*" }).Count -eq 0) "Installed Source Control UI E2E evidence should no longer keep the checkout-flow non-claim after executing Checkout Repository."
  Assert-True (@($report.nonClaims | Where-Object { $_ -like "*checkout cancellation*" }).Count -eq 0) "Installed Source Control UI E2E evidence should no longer keep checkout cancellation as a non-claim after the installed cancellation workflow."
  Assert-True (@($report.nonClaims | Where-Object { $_ -like "*obstructed/conflicting existing-directory variants*" }).Count -eq 0) "Installed Source Control UI E2E evidence should not keep existing-directory obstruction as a non-claim after proving the tree-conflict workflow."
  Assert-True (@($report.nonClaims | Where-Object { $_ -like "*repository browser, remote auth/certificate, or broader checkout failure matrices*" }).Count -eq 1) "Installed Source Control UI E2E evidence should keep the remaining checkout remote/browser/failure breadth as a non-claim."
  Assert-True (@($report.nonClaims | Where-Object { $_ -like "*invalid URL*" }).Count -eq 0) "Installed Source Control UI E2E evidence should not keep invalid URL checkout as a non-claim after proving the installed failure path."
  Assert-True (@($report.nonClaims | Where-Object { $_ -like "*failure-without-state-pollution flows*" -or $_ -like "*invalid URL, existing target,*" }).Count -eq 0) "Installed Source Control UI E2E evidence should not keep the old broad Checkout failure non-claim after proving the obstructing-file failure path."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "TST-018" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace TST-018."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "TST-024" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace TST-024."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "UX-001" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace UX-001."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "UX-002" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace UX-002."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "UX-007" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace UX-007."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "COM-001" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace COM-001."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "COM-002" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace COM-002."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "REP-002" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace REP-002."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "REP-004" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace REP-004."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "DIR-003" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace DIR-003."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "DIR-009" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace DIR-009."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "DIR-010" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace DIR-010."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "DIR-012" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace DIR-012."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "DIR-013" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace DIR-013."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "MIG-009" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace MIG-009."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "STA-009" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace STA-009."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "STA-013" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace STA-013."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "STA-014" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace STA-014."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "STA-016" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace STA-016."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "OPS-001" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace OPS-001."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "OPS-002" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace OPS-002."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "OPS-003" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace OPS-003."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "OPS-004" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace OPS-004."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "OPS-005" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace OPS-005."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "OPS-006" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace OPS-006."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "OPS-007" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace OPS-007."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "OPS-008" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace OPS-008."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "OPS-014" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace OPS-014."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "OPS-015" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace OPS-015."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "BRM-001" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace BRM-001."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "BRM-005" }).Count -eq 1) "Installed Source Control UI E2E evidence should trace BRM-005."
  Assert-True (@($report.traceIds | Where-Object { $_ -eq "BRM-004" }).Count -eq 0) "Installed Source Control UI E2E evidence should not trace BRM-004 switch-after-copy until that workflow is implemented."
  Assert-True (@($report.nonClaims | Where-Object { $_ -like "*DOM*" -or $_ -like "*accessibility*" -or $_ -like "*pixel*" }).Count -eq 0) "M7j3 evidence should not keep the old DOM/accessibility/pixel non-claim."
  Assert-True (@($report.nonClaims | Where-Object { $_ -like "*does not prove switch-after-copy*" }).Count -eq 1) "Installed Source Control UI E2E evidence should keep switch-after-copy as a non-claim."
  Assert-True (@($report.nonClaims | Where-Object { $_ -like "*target browsing*" }).Count -eq 1) "Installed Source Control UI E2E evidence should keep target browsing as a Branch/Switch non-claim."
  Assert-True (@($report.nonClaims | Where-Object { $_ -like "*broad remote/auth/certificate matrices*" }).Count -eq 1) "Installed Source Control UI E2E evidence should keep broad remote/auth/certificate matrices as a Branch/Switch non-claim."
  Assert-True (@($report.nonClaims | Where-Object { $_ -like "*repository-browser integration*" }).Count -eq 1) "Installed Source Control UI E2E evidence should keep repository-browser integration as a Branch/Switch non-claim."
  Assert-True (@($report.nonClaims | Where-Object { $_ -like "*merge workflows*" }).Count -eq 1) "Installed Source Control UI E2E evidence should keep merge workflows as a Branch/Switch non-claim."
  Assert-True (@($report.nonClaims | Where-Object { $_ -like "*switched working-copy edge/load behavior*" }).Count -eq 1) "Installed Source Control UI E2E evidence should keep switched working-copy edge/load behavior as a Branch/Switch non-claim."
  Assert-True ($report.rendererCaptureDriver.sha256 -match '^[a-f0-9]{64}$') "Installed Source Control UI E2E evidence should hash the renderer capture driver."
  Assert-True ($report.codeCli.sha256 -match '^[a-f0-9]{64}$') "Installed Source Control UI E2E evidence should record the Code CLI hash."
  Assert-True ([string]$report.fixtureRoots.rendererCapture -like "*renderer-capture*") "Installed Source Control UI E2E evidence should record the renderer capture root."
  Assert-True ([string]$report.fixtureRoots.noRepositoryWelcomeRendererCapture -like "*no-repository-welcome-renderer-capture*") "Installed Source Control UI E2E evidence should record the no-repository welcome renderer capture root."
  Assert-True ([string]$report.fixtureRoots.checkoutCancellationPromptCapture -like "*checkout-cancellation-prompt-capture*") "Installed Source Control UI E2E evidence should record the Checkout cancellation prompt capture root."
  Assert-True ([string]$report.fixtureRoots.checkoutCancellationTargetFixture -like "*checkout-cancellation-target*") "Installed Source Control UI E2E evidence should record the Checkout cancellation target fixture root."
  Assert-True ([string]$report.fixtureRoots.checkoutExistingTargetFailureTargetFixture -like "*checkout-existing-target-failure*") "Installed Source Control UI E2E evidence should record the Checkout existing-target failure target fixture."
  Assert-True ([string]$report.fixtureRoots.checkoutExistingTargetFailureUrlPromptCapture -like "*checkout-existing-target-failure-url-prompt-capture*") "Installed Source Control UI E2E evidence should record the Checkout existing-target failure URL prompt capture root."
  Assert-True ([string]$report.fixtureRoots.checkoutExistingTargetFailureTargetPromptCapture -like "*checkout-existing-target-failure-target-prompt-capture*") "Installed Source Control UI E2E evidence should record the Checkout existing-target failure target prompt capture root."
  Assert-True ([string]$report.fixtureRoots.checkoutExistingTargetFailureRevisionPromptCapture -like "*checkout-existing-target-failure-revision-prompt-capture*") "Installed Source Control UI E2E evidence should record the Checkout existing-target failure revision prompt capture root."
  Assert-True ([string]$report.fixtureRoots.checkoutExistingTargetFailureDepthPromptCapture -like "*checkout-existing-target-failure-depth-prompt-capture*") "Installed Source Control UI E2E evidence should record the Checkout existing-target failure depth prompt capture root."
  Assert-True ([string]$report.fixtureRoots.checkoutExistingTargetFailureExternalsPromptCapture -like "*checkout-existing-target-failure-externals-prompt-capture*") "Installed Source Control UI E2E evidence should record the Checkout existing-target failure externals prompt capture root."
  Assert-True ([string]$report.fixtureRoots.checkoutExistingTargetFailureNotificationCapture -like "*checkout-existing-target-failure-notification-capture*") "Installed Source Control UI E2E evidence should record the Checkout existing-target failure notification capture root."
  Assert-True ([string]$report.fixtureRoots.checkoutInvalidUrlFailureTargetFixture -like "*checkout-invalid-url-failure*") "Installed Source Control UI E2E evidence should record the Checkout invalid URL failure target fixture."
  Assert-True ([string]$report.fixtureRoots.checkoutInvalidUrlFailureUrlPromptCapture -like "*checkout-invalid-url-failure-url-prompt-capture*") "Installed Source Control UI E2E evidence should record the Checkout invalid URL URL prompt capture root."
  Assert-True ([string]$report.fixtureRoots.checkoutInvalidUrlFailureTargetPromptCapture -like "*checkout-invalid-url-failure-target-prompt-capture*") "Installed Source Control UI E2E evidence should record the Checkout invalid URL target prompt capture root."
  Assert-True ([string]$report.fixtureRoots.checkoutInvalidUrlFailureRevisionPromptCapture -like "*checkout-invalid-url-failure-revision-prompt-capture*") "Installed Source Control UI E2E evidence should record the Checkout invalid URL revision prompt capture root."
  Assert-True ([string]$report.fixtureRoots.checkoutInvalidUrlFailureDepthPromptCapture -like "*checkout-invalid-url-failure-depth-prompt-capture*") "Installed Source Control UI E2E evidence should record the Checkout invalid URL depth prompt capture root."
  Assert-True ([string]$report.fixtureRoots.checkoutInvalidUrlFailureExternalsPromptCapture -like "*checkout-invalid-url-failure-externals-prompt-capture*") "Installed Source Control UI E2E evidence should record the Checkout invalid URL externals prompt capture root."
  Assert-True ([string]$report.fixtureRoots.checkoutInvalidUrlFailureNotificationCapture -like "*checkout-invalid-url-failure-notification-capture*") "Installed Source Control UI E2E evidence should record the Checkout invalid URL notification capture root."
  Assert-True ([string]$report.fixtureRoots.checkoutExistingDirectoryTargetFixture -like "*checkout-existing-directory*") "Installed Source Control UI E2E evidence should record the Checkout existing-directory target fixture."
  Assert-True ([string]$report.fixtureRoots.checkoutExistingDirectoryUrlPromptCapture -like "*checkout-existing-directory-url-prompt-capture*") "Installed Source Control UI E2E evidence should record the Checkout existing-directory URL prompt capture root."
  Assert-True ([string]$report.fixtureRoots.checkoutExistingDirectoryTargetPromptCapture -like "*checkout-existing-directory-target-prompt-capture*") "Installed Source Control UI E2E evidence should record the Checkout existing-directory target prompt capture root."
  Assert-True ([string]$report.fixtureRoots.checkoutExistingDirectoryRevisionPromptCapture -like "*checkout-existing-directory-revision-prompt-capture*") "Installed Source Control UI E2E evidence should record the Checkout existing-directory revision prompt capture root."
  Assert-True ([string]$report.fixtureRoots.checkoutExistingDirectoryDepthPromptCapture -like "*checkout-existing-directory-depth-prompt-capture*") "Installed Source Control UI E2E evidence should record the Checkout existing-directory depth prompt capture root."
  Assert-True ([string]$report.fixtureRoots.checkoutExistingDirectoryExternalsPromptCapture -like "*checkout-existing-directory-externals-prompt-capture*") "Installed Source Control UI E2E evidence should record the Checkout existing-directory externals prompt capture root."
  Assert-True ([string]$report.fixtureRoots.checkoutExistingDirectoryObstructionTargetFixture -like "*checkout-existing-directory-obstruction*") "Installed Source Control UI E2E evidence should record the Checkout existing-directory obstruction target fixture."
  Assert-True ([string]$report.fixtureRoots.checkoutExistingDirectoryObstructionUrlPromptCapture -like "*checkout-existing-directory-obstruction-url-prompt-capture*") "Installed Source Control UI E2E evidence should record the Checkout existing-directory obstruction URL prompt capture root."
  Assert-True ([string]$report.fixtureRoots.checkoutExistingDirectoryObstructionTargetPromptCapture -like "*checkout-existing-directory-obstruction-target-prompt-capture*") "Installed Source Control UI E2E evidence should record the Checkout existing-directory obstruction target prompt capture root."
  Assert-True ([string]$report.fixtureRoots.checkoutExistingDirectoryObstructionRevisionPromptCapture -like "*checkout-existing-directory-obstruction-revision-prompt-capture*") "Installed Source Control UI E2E evidence should record the Checkout existing-directory obstruction revision prompt capture root."
  Assert-True ([string]$report.fixtureRoots.checkoutExistingDirectoryObstructionDepthPromptCapture -like "*checkout-existing-directory-obstruction-depth-prompt-capture*") "Installed Source Control UI E2E evidence should record the Checkout existing-directory obstruction depth prompt capture root."
  Assert-True ([string]$report.fixtureRoots.checkoutExistingDirectoryObstructionExternalsPromptCapture -like "*checkout-existing-directory-obstruction-externals-prompt-capture*") "Installed Source Control UI E2E evidence should record the Checkout existing-directory obstruction externals prompt capture root."
  Assert-True ([string]$report.fixtureRoots.partialFreshnessRendererCapture -like "*partial-freshness-renderer-capture*") "Installed Source Control UI E2E evidence should record the partial freshness renderer capture root."
  Assert-True ([string]$report.fixtureRoots.staleFreshnessRendererCapture -like "*stale-freshness-renderer-capture*") "Installed Source Control UI E2E evidence should record the stale freshness renderer capture root."
  Assert-True ([string]$report.fixtureRoots.fullReconcileCancellationProgressCapture -like "*full-reconcile-cancellation-progress-capture*") "Installed Source Control UI E2E evidence should record the Full Reconcile cancellation progress capture root."
  Assert-True ([string]$report.fixtureRoots.refreshLoadFixture -like "*refresh-load-fixture*") "Installed Source Control UI E2E evidence should record the Refresh load fixture root."
  Assert-True ([string]$report.fixtureRoots.boundaryLoadFixture -like "*boundary-load-fixture*") "Installed Source Control UI E2E evidence should record the boundary load fixture root."
  Assert-True ([string]$report.fixtureRoots.multiRepositoryRefreshFixture -like "*multi-repository-refresh-fixture*") "Installed Source Control UI E2E evidence should record the multi-repository Refresh fixture root."
  Assert-True ([string]$report.fixtureRoots.lazyExternalProviderFixture -like "*lazy-external-provider-fixture*") "Installed Source Control UI E2E evidence should record the lazy external provider fixture root."
  Assert-True ([string]$report.fixtureRoots.multiRepositoryRefreshPromptCapture -like "*multi-repository-refresh-prompt-capture*") "Installed Source Control UI E2E evidence should record the multi-repository Refresh prompt capture root."
  Assert-True ([string]$report.fixtureRoots.deleteUnversionedPromptCapture -like "*delete-unversioned-prompt-capture*") "Installed Source Control UI E2E evidence should record the Delete Unversioned prompt capture root."
  Assert-True ([string]$report.fixtureRoots.deleteUnversionedLoadPromptCapture -like "*delete-unversioned-load-prompt-capture*") "Installed Source Control UI E2E evidence should record the Delete Unversioned load prompt capture root."
  Assert-True ([string]$report.fixtureRoots.removePromptCapture -like "*remove-prompt-capture*") "Installed Source Control UI E2E evidence should record the Remove prompt capture root."
  Assert-True ([string]$report.fixtureRoots.removeCancellationPromptCapture -like "*remove-cancellation-prompt-capture*") "Installed Source Control UI E2E evidence should record the Remove cancellation prompt capture root."
  Assert-True ([string]$report.fixtureRoots.removeKeepLocalPromptCapture -like "*remove-keep-local-prompt-capture*") "Installed Source Control UI E2E evidence should record the Keep-local Remove prompt capture root."
  Assert-True ([string]$report.fixtureRoots.movePromptCapture -like "*move-prompt-capture*") "Installed Source Control UI E2E evidence should record the Move prompt capture root."
  Assert-True ([string]$report.fixtureRoots.moveCancellationPromptCapture -like "*move-cancellation-prompt-capture*") "Installed Source Control UI E2E evidence should record the Move cancellation prompt capture root."
  Assert-True ([string]$report.fixtureRoots.lockMessagePromptCapture -like "*lock-message-prompt-capture*") "Installed Source Control UI E2E evidence should record the Lock message prompt capture root."
  Assert-True ([string]$report.fixtureRoots.lockModePromptCapture -like "*lock-mode-prompt-capture*") "Installed Source Control UI E2E evidence should record the Lock mode prompt capture root."
  Assert-True ([string]$report.fixtureRoots.unlockModePromptCapture -like "*unlock-mode-prompt-capture*") "Installed Source Control UI E2E evidence should record the Unlock mode prompt capture root."
  Assert-True ([string]$report.fixtureRoots.lockMessageCancellationPromptCapture -like "*lock-message-cancellation-prompt-capture*") "Installed Source Control UI E2E evidence should record the Lock message cancellation prompt capture root."
  Assert-True ([string]$report.fixtureRoots.unlockModeCancellationPromptCapture -like "*unlock-mode-cancellation-prompt-capture*") "Installed Source Control UI E2E evidence should record the Unlock mode cancellation prompt capture root."
  Assert-True ([string]$report.fixtureRoots.revertPromptCapture -like "*revert-prompt-capture*") "Installed Source Control UI E2E evidence should record the Revert prompt capture root."
  Assert-True ([string]$report.fixtureRoots.revertCancellationPromptCapture -like "*revert-cancellation-prompt-capture*") "Installed Source Control UI E2E evidence should record the Revert cancellation prompt capture root."
  Assert-True ([string]$report.fixtureRoots.resolvePromptCapture -like "*resolve-prompt-capture*") "Installed Source Control UI E2E evidence should record the Resolve prompt capture root."
  Assert-True ([string]$report.fixtureRoots.resolveUpdateWarningCapture -like "*resolve-update-warning-capture*") "Installed Source Control UI E2E evidence should record the Update conflict warning capture root."
  Assert-True ([string]$report.fixtureRoots.resolveCancellationPromptCapture -like "*resolve-cancellation-prompt-capture*") "Installed Source Control UI E2E evidence should record the Resolve cancellation prompt capture root."
  Assert-True ([string]$report.fixtureRoots.cleanupPromptCapture -like "*cleanup-prompt-capture*") "Installed Source Control UI E2E evidence should record the Cleanup prompt capture root."
  Assert-True ([string]$report.fixtureRoots.addFixture -like "*add-fixture*") "Installed Source Control UI E2E evidence should record the Add workflow fixture root."
  Assert-True ([string]$report.fixtureRoots.lockFixture -like "*lock-fixture*") "Installed Source Control UI E2E evidence should record the Lock/Unlock workflow fixture root."
  Assert-True ([string]$report.fixtureRoots.branchCreateFixture -like "*branch-create-fixture*") "Installed Source Control UI E2E evidence should record the Branch/Tag create fixture root."
  Assert-True ([string]$report.fixtureRoots.switchFixture -like "*switch-fixture*") "Installed Source Control UI E2E evidence should record the Switch workflow fixture root."
  Assert-True ([string]$report.fixtureRoots.branchCreateSourcePromptCapture -like "*branch-create-source-prompt-capture*") "Installed Source Control UI E2E evidence should record the Branch/Tag source prompt capture root."
  Assert-True ([string]$report.fixtureRoots.branchCreateSwitchPromptCapture -like "*branch-create-switch-prompt-capture*") "Installed Source Control UI E2E evidence should record the Branch/Tag switch prompt capture root."
  Assert-True ([string]$report.fixtureRoots.switchAncestryPromptCapture -like "*switch-ancestry-prompt-capture*") "Installed Source Control UI E2E evidence should record the Switch ancestry prompt capture root."
  Assert-True ([string]$report.fixtureRoots.removeFixture -like "*remove-fixture*") "Installed Source Control UI E2E evidence should record the Remove workflow fixture root."
  Assert-True ([string]$report.fixtureRoots.removeCancellationFixture -like "*remove-cancellation-fixture*") "Installed Source Control UI E2E evidence should record the Remove cancellation workflow fixture root."
  Assert-True ([string]$report.fixtureRoots.moveFixture -like "*move-fixture*") "Installed Source Control UI E2E evidence should record the Move workflow fixture root."
  Assert-True ([string]$report.fixtureRoots.moveCancellationFixture -like "*move-cancellation-fixture*") "Installed Source Control UI E2E evidence should record the Move cancellation workflow fixture root."
  Assert-True ([string]$report.fixtureRoots.revertCancellationFixture -like "*revert-cancellation-fixture*") "Installed Source Control UI E2E evidence should record the Revert cancellation workflow fixture root."
  Assert-True ([string]$report.fixtureRoots.resolveFixture -like "*resolve-fixture*") "Installed Source Control UI E2E evidence should record the Resolve workflow fixture root."
  Assert-True ([string]$report.fixtureRoots.resolveCancellationFixture -like "*resolve-cancellation-fixture*") "Installed Source Control UI E2E evidence should record the Resolve cancellation workflow fixture root."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $workflowScript `
      -Target win32-x64 `
      -VsixPath $vsixPath `
      -CodeCliPath "%SUBVERSIONR_CODE_CLI%" `
      -SvnToolsRoot $fakeSvnRoot `
      -RendererCaptureDriverPath $fakeDriverPath `
      -FixtureRoot (Join-Path $tempRoot "literal-code-cli") `
      -EvidencePath (Join-Path $tempRoot "evidence\literal-code-cli.json") `
      -RemoteDebuggingPort 32147
  } "CodeCliPath must be an explicit file path" "Installed Source Control UI E2E gate should reject unresolved Code CLI placeholders."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $workflowScript `
      -Target win32-x64 `
      -VsixPath $vsixPath `
      -CodeCliPath $fakeCodeCliPath `
      -SvnToolsRoot $fakeSvnRoot `
      -RendererCaptureDriverPath "%SUBVERSIONR_RENDERER_DRIVER%" `
      -FixtureRoot (Join-Path $tempRoot "literal-driver") `
      -EvidencePath (Join-Path $tempRoot "evidence\literal-driver.json") `
      -RemoteDebuggingPort 32148
  } "RendererCaptureDriverPath must be an explicit file path" "Installed Source Control UI E2E gate should reject unresolved renderer driver placeholders."

  $env:SUBVERSIONR_FAKE_RENDERER_CAPTURE_MODE = "missing-dom-token"
  try {
    Assert-NativeCommandFailsContaining {
      & pwsh -NoProfile -ExecutionPolicy Bypass -File $workflowScript `
        -Target win32-x64 `
        -VsixPath $vsixPath `
        -CodeCliPath $fakeCodeCliPath `
        -SvnToolsRoot $fakeSvnRoot `
        -RendererCaptureDriverPath $fakeDriverPath `
        -FixtureRoot (Join-Path $tempRoot "missing-dom-token\win32-x64") `
        -EvidencePath (Join-Path $tempRoot "evidence\missing-dom-token.json") `
        -RemoteDebuggingPort 32149 `
        -ExtensionHostTimeoutSeconds 30 `
        -UiReadyTimeoutSeconds 10
    } "DOM artifact text is missing required tokens" "Installed Source Control UI E2E gate should reject renderer DOM captures missing required tokens."
  }
  finally {
    Remove-Item Env:SUBVERSIONR_FAKE_RENDERER_CAPTURE_MODE -ErrorAction SilentlyContinue
  }

  $env:SUBVERSIONR_FAKE_RENDERER_CAPTURE_MODE = "lying-dom-token"
  try {
    Assert-NativeCommandFailsContaining {
      & pwsh -NoProfile -ExecutionPolicy Bypass -File $workflowScript `
        -Target win32-x64 `
        -VsixPath $vsixPath `
        -CodeCliPath $fakeCodeCliPath `
        -SvnToolsRoot $fakeSvnRoot `
        -RendererCaptureDriverPath $fakeDriverPath `
        -FixtureRoot (Join-Path $tempRoot "lying-dom-token\win32-x64") `
        -EvidencePath (Join-Path $tempRoot "evidence\lying-dom-token.json") `
        -RemoteDebuggingPort 32151 `
        -ExtensionHostTimeoutSeconds 30 `
        -UiReadyTimeoutSeconds 10
    } "DOM artifact text is missing required tokens" "Installed Source Control UI E2E gate should read DOM artifacts instead of trusting renderer assertions."
  }
  finally {
    Remove-Item Env:SUBVERSIONR_FAKE_RENDERER_CAPTURE_MODE -ErrorAction SilentlyContinue
  }

  $env:SUBVERSIONR_FAKE_RENDERER_CAPTURE_MODE = "partial-accessibility"
  try {
    Assert-NativeCommandFailsContaining {
      & pwsh -NoProfile -ExecutionPolicy Bypass -File $workflowScript `
        -Target win32-x64 `
        -VsixPath $vsixPath `
        -CodeCliPath $fakeCodeCliPath `
        -SvnToolsRoot $fakeSvnRoot `
        -RendererCaptureDriverPath $fakeDriverPath `
        -FixtureRoot (Join-Path $tempRoot "partial-accessibility\win32-x64") `
        -EvidencePath (Join-Path $tempRoot "evidence\partial-accessibility.json") `
        -RemoteDebuggingPort 32150 `
        -ExtensionHostTimeoutSeconds 30 `
        -UiReadyTimeoutSeconds 10
    } "Renderer capture accessibility artifact status must be captured" "Installed Source Control UI E2E gate should reject partial accessibility captures."
  }
  finally {
    Remove-Item Env:SUBVERSIONR_FAKE_RENDERER_CAPTURE_MODE -ErrorAction SilentlyContinue
  }

  $env:SUBVERSIONR_FAKE_RENDERER_CAPTURE_MODE = "blank-screenshot-lie"
  try {
    Assert-NativeCommandFailsContaining {
      & pwsh -NoProfile -ExecutionPolicy Bypass -File $workflowScript `
        -Target win32-x64 `
        -VsixPath $vsixPath `
        -CodeCliPath $fakeCodeCliPath `
        -SvnToolsRoot $fakeSvnRoot `
        -RendererCaptureDriverPath $fakeDriverPath `
        -FixtureRoot (Join-Path $tempRoot "blank-screenshot-lie\win32-x64") `
        -EvidencePath (Join-Path $tempRoot "evidence\blank-screenshot-lie.json") `
        -RemoteDebuggingPort 32152 `
        -ExtensionHostTimeoutSeconds 30 `
        -UiReadyTimeoutSeconds 10
    } "Renderer capture screenshot PNG must contain nonblank pixel evidence" "Installed Source Control UI E2E gate should inspect screenshot pixels instead of trusting renderer assertions."
  }
  finally {
    Remove-Item Env:SUBVERSIONR_FAKE_RENDERER_CAPTURE_MODE -ErrorAction SilentlyContinue
  }

  $ciWorkflow = Get-Content -Raw -LiteralPath $ciWorkflowPath
  $workflowContent = Get-Content -Raw -LiteralPath $workflowScript
  $driverContent = Get-Content -Raw -LiteralPath $driverScript
  Assert-True ($driverContent -match "captureRequiredTokenState") "Renderer capture driver should retry DOM/accessibility token capture before writing artifacts."
  Assert-True ($driverContent -match "REQUIRED_TOKEN_CAPTURE_TIMEOUT_MS") "Renderer capture driver should use a bounded token capture retry timeout."
  Assert-True ($driverContent -match "clickNotificationAction") "Renderer capture driver should click notification actions when VS Code hides action button text from DOM snapshots."
  Assert-True ($driverContent -match "notificationMatchedByTokens") "Renderer capture driver notification action fallback should be anchored to the captured notification tokens."
  Assert-True ($driverContent -match "dismissUnmatchedVisibleNotification") "Renderer capture driver should clear unrelated visible notifications before clicking a token-matched confirmation notification."
  Assert-True ($driverContent -match "Last interaction state") "Renderer capture driver should include the last interaction state when a notification action button times out."
  Assert-True ($driverContent -match "hoverTarget") "Renderer capture driver should return a notification hover target when action buttons are hidden until hover."
  Assert-True ($driverContent -match '(?s)Input\.dispatchMouseEvent.*?type: "mouseMoved".*?result\.hoverTarget\.x.*?result\.hoverTarget\.y') "Renderer capture driver should move the real mouse to the matched notification before retrying hidden action buttons."
  Assert-True ($driverContent -match "window\.innerWidth") "Renderer capture driver should ignore offscreen notification accessibility mirrors when looking for clickable actions."
  Assert-True ($driverContent -match "selectedItemStillVisible") "Renderer capture driver should treat a multi-step QuickPick item as selected once the original item disappears."
  Assert-True ($driverContent -match "nextQuickInputVisible") "Renderer capture driver should record when a follow-up QuickInput remains visible after a QuickPick selection."
  Assert-True ($driverContent -match "targetTokens\.every") "Renderer capture driver should anchor notification cancellation to every required DOM token."
  Assert-True ($driverContent -match '(?s)async function closeNotification.*?deleteKeyEvent = \{ key: "Delete".*?Input\.dispatchKeyEvent') "Renderer capture driver should close notifications through the matched notification clear keybinding."
  $notificationCleanupHelper = [regex]::Match($workflowContent, '(?s)async function clearWorkbenchNotificationsBeforePrompt\(label\) \{.*?\r?\n\}\r?\n\r?\nfunction isTransientSourceControlSurfaceMismatch').Value
  Assert-True ($notificationCleanupHelper -ne "") "Installed Source Control UI E2E harness should define an explicit notification cleanup helper."
  Assert-True ($workflowContent -match 'const NOTIFICATION_CLEAR_COMMAND = "notifications\.clearAll";') "Installed Source Control UI E2E notification cleanup should name the explicit VS Code notification clear-all command."
  Assert-True ($workflowContent -match 'const NOTIFICATION_SHOW_LIST_COMMAND = "notifications\.showList";') "Installed Source Control UI E2E notification cleanup should name the explicit VS Code notification list command."
  Assert-True ($notificationCleanupHelper -match "NOTIFICATION_CLEAR_COMMAND") "Installed Source Control UI E2E notification cleanup should use the explicit VS Code notification clear-all command constant."
  Assert-True ($notificationCleanupHelper -match "NOTIFICATION_SHOW_LIST_COMMAND") "Installed Source Control UI E2E notification list opening should use the explicit VS Code notification show-list command constant."
  Assert-True ($notificationCleanupHelper -match "vscode\.commands\.getCommands\(true\)") "Installed Source Control UI E2E notification cleanup should fail fast if the VS Code clear-all command is not registered."
  Assert-True ($notificationCleanupHelper -match '(?s)withTimeout\(\s*vscode\.commands\.executeCommand\(NOTIFICATION_CLEAR_COMMAND\)') "Installed Source Control UI E2E notification cleanup should execute clear-all through the extension host command path."
  Assert-True ($notificationCleanupHelper -match '(?s)withTimeout\(\s*vscode\.commands\.executeCommand\(NOTIFICATION_SHOW_LIST_COMMAND\)') "Installed Source Control UI E2E notification list opening should execute show-list through the extension host command path."
  Assert-True (-not ($notificationCleanupHelper -match "\bcatch\b")) "Installed Source Control UI E2E notification cleanup should not silently fall back when VS Code clear-all fails."
  Assert-True ($workflowContent -match '(?s)async function runFullReconcileCancellationWorkflow.*?clearWorkbenchNotificationsBeforePrompt\("fullReconcileCancellation"\).*?executeCommand\("subversionr\.fullReconcile"') "Full reconcile cancellation should clear unrelated notifications before exposing the Cancel progress action."
  Assert-True ($workflowContent -match '(?s)async function runDeleteUnversionedWorkflow.*?clearWorkbenchNotificationsBeforePrompt\("deleteUnversioned"\).*?executeCommand\("subversionr\.deleteUnversionedResource"') "Delete Unversioned should clear unrelated notifications before exposing the Delete confirmation."
  Assert-True ($workflowContent -match '(?s)async function runDeleteUnversionedLoadWorkflow.*?clearWorkbenchNotificationsBeforePrompt\("deleteAllUnversionedResources"\).*?executeCommand\("subversionr\.deleteAllUnversionedResources"') "Delete All Unversioned should clear unrelated notifications before exposing the Delete confirmation."
  Assert-True ($workflowContent -match '(?s)async function runRemoveWorkflow.*?clearWorkbenchNotificationsBeforePrompt\("removeResource"\).*?executeCommand\("subversionr\.removeResource"') "Remove should clear unrelated notifications before exposing the Remove confirmation."
  Assert-True ($workflowContent -match '(?s)async function runRemoveKeepLocalWorkflow.*?clearWorkbenchNotificationsBeforePrompt\("removeResourceKeepLocal"\).*?executeCommand\("subversionr\.removeResourceKeepLocal"') "Keep-local Remove should clear unrelated notifications before exposing the Remove confirmation."
  Assert-True ($workflowContent -match '(?s)async function runRevertChangelistWorkflow.*?clearWorkbenchNotificationsBeforePrompt\("revertChangelist"\).*?executeCommand\("subversionr\.revertChangelist"') "Revert Changelist should clear unrelated notifications before exposing the Revert confirmation."
  Assert-True ($workflowContent -match '(?s)async function runRevertWorkflow.*?clearWorkbenchNotificationsBeforePrompt\("revertResource"\).*?executeCommand\("subversionr\.revertResource"') "Revert should clear unrelated notifications before exposing the Revert confirmation."
  Assert-True ($workflowContent -match '(?s)function resolvePromptCaptureExpectations.*?quickPickItemText: "Working copy".*?async function runResolveWorkflow.*?executeCommand\("subversionr\.resolveResource"') "Resolve should expose and select the Working copy QuickPick choice."
  Assert-True ($workflowContent -match '(?s)async function runResolveWorkflow.*?executeCommand\("subversionr\.updateRepository".*?updateConflictWarningReady.*?executeCommand\("subversionr\.resolveResource"') "Resolve evidence should create the conflict through installed Update, capture its warning, then execute Resolve."
  Assert-True ($workflowContent -match '(?s)beforeActive !== true.*?did not activate organically before any installed Source Control UI E2E command executed') "Installed Source Control UI E2E should fail before its first SubversionR command when organic activation did not occur."
  Assert-True ($workflowContent -match 'Get-UpdateConflictWorkingCopyOracle') "Installed Update conflict evidence should use the SVN status XML working-copy oracle."
  Assert-True ($workflowContent -match '(?s)async function runResolveCancellationWorkflow.*?clearWorkbenchNotificationsBeforePrompt\("resolveResourceCancellation"\).*?executeCommand\("subversionr\.resolveResource"') "Resolve cancellation should clear stale notifications before exposing the QuickInput cancellation prompt."
  Assert-True ($workflowContent -match '(?s)async function runFullReconcileCancellationWorkflow.*?executeCommand\("subversionr\.fullReconcile".*?showWorkbenchNotificationsForPrompt\("fullReconcileCancellation"\)') "Full reconcile cancellation should open the notification list after starting the cancellable progress."
  Assert-True ($workflowContent -match '(?s)async function runDeleteUnversionedWorkflow.*?executeCommand\("subversionr\.deleteUnversionedResource".*?showWorkbenchNotificationsForPrompt\("deleteUnversioned"\)') "Delete Unversioned should open the notification list after starting the confirmation prompt."
  Assert-True ($workflowContent -match '(?s)async function runDeleteUnversionedLoadWorkflow.*?executeCommand\("subversionr\.deleteAllUnversionedResources".*?showWorkbenchNotificationsForPrompt\("deleteAllUnversionedResources"\)') "Delete All Unversioned should open the notification list after starting the confirmation prompt."
  Assert-True ($workflowContent -match '(?s)async function runRemoveWorkflow.*?executeCommand\("subversionr\.removeResource".*?showWorkbenchNotificationsForPrompt\("removeResource"\)') "Remove should open the notification list after starting the confirmation prompt."
  Assert-True ($workflowContent -match '(?s)async function runRemoveKeepLocalWorkflow.*?executeCommand\("subversionr\.removeResourceKeepLocal".*?showWorkbenchNotificationsForPrompt\("removeResourceKeepLocal"\)') "Keep-local Remove should open the notification list after starting the confirmation prompt."
  Assert-True ($workflowContent -match '(?s)async function runRevertChangelistWorkflow.*?executeCommand\("subversionr\.revertChangelist".*?showWorkbenchNotificationsForPrompt\("revertChangelist"\)') "Revert Changelist should open the notification list after starting the confirmation prompt."
  Assert-True ($workflowContent -match '(?s)async function runRevertWorkflow.*?executeCommand\("subversionr\.revertResource".*?showWorkbenchNotificationsForPrompt\("revertResource"\)') "Revert should open the notification list after starting the confirmation prompt."
  Assert-True ($workflowContent -match '(?s)async function runResolveWorkflow.*?executeCommand\("subversionr\.resolveResource".*?showWorkbenchNotificationsForPrompt\("resolveResource"\)') "Resolve should open the notification list after starting the confirmation prompt."
  Assert-True ($workflowContent -match "(?s)deleteUnversionedFreshnessReport\s*=\s*await collectFreshnessReportWithSurfaceRetry") "Installed Source Control UI E2E harness should refresh SourceControl evidence with surface retry immediately before Delete Unversioned."
  Assert-True ($workflowContent -match "runDeleteUnversionedWorkflow\s*\(\s*deleteUnversionedFreshnessReport") "Installed Source Control UI E2E harness should delete using just-in-time SourceControl evidence, not an earlier report."
  Assert-True ($workflowContent -match "function isTransientSourceControlSurfaceMismatch") "Installed Source Control UI E2E harness should recognize transient SourceControl surface mismatch diagnostics."
  Assert-True ($workflowContent -match "async function collectFreshnessReportWithSurfaceRetry") "Installed Source Control UI E2E harness should wait for VS Code SourceControl surface updates before sampling freshness."
  Assert-True ($workflowContent -match "async function collectFreshnessReportUntilUnversionedCount") "Installed Source Control UI E2E harness should support condition-based freshness waits for unversioned projection counts."
  Assert-True ($workflowContent -match "function sourceControlResourceSummary") "Installed Source Control UI E2E harness should include SourceControl resources in projection assertion diagnostics."
  Assert-True ($workflowContent -match '(?s)async function runDeleteUnversionedLoadWorkflow.*?postDeleteFreshnessReport\s*=\s*await collectFreshnessReportUntilUnversionedCount\([\s\S]*?"subversionr\.diagnostics\.installedSourceControlUiE2eFreshnessReport/deleteLoad",\s*0,\s*30000') "Delete All Unversioned load workflow should wait until the unversioned SourceControl projection reaches zero after deletion."
  Assert-True ($workflowContent -match '(?s)async function runMoveWorkflow.*?postMoveFreshnessReport\s*=\s*await collectFreshnessReportWithSurfaceRetry') "Move workflow should collect post-move freshness through the surface retry helper."
  Assert-True ($workflowContent -match '(?s)Installed Move workflow did not project src/tracked\.txt.*?sourceControlResourceSummary\(postMoveFreshnessReport\)') "Move workflow should include SourceControl resources when source deletion projection is missing."
  Assert-True ($workflowContent -match '(?s)async function runCommitAllWorkflow.*?acceptInputCommandArguments.*?subversionr\.diagnostics\.installedSourceControlUiE2eSetInputMessage.*?executeCommand\(acceptInputCommand, \.\.\.acceptInputCommandArguments\)') "Installed Source Control UI E2E harness should run Commit All through the installed SourceControl input accept command path and arguments."
  Assert-True ($workflowContent -match "sourceControlUiCommitAllWorkflow") "Installed Source Control UI E2E evidence should publish the Commit All workflow report."
  Assert-True ($workflowContent -match "Get-CommitAllRepositoryOracle") "Installed Source Control UI E2E evidence should verify Commit All using an SVN repository oracle."
  Assert-True ($workflowContent -match '(?s)async function runCommitSelectedWorkflow.*?resourceStateArgument\(commitSelectedWorkingCopyRoot, selected\).*?executeCommand\("subversionr\.commitResource", commandArgument\)') "Installed Source Control UI E2E harness should run Commit Selected through the installed SCM resource command argument."
  Assert-True ($workflowContent -match "sourceControlUiCommitSelectedWorkflow") "Installed Source Control UI E2E evidence should publish the Commit Selected workflow report."
  Assert-True ($workflowContent -match "Get-CommitSelectedRepositoryOracle") "Installed Source Control UI E2E evidence should verify Commit Selected using an SVN repository oracle."
  Assert-True ($workflowContent -match '(?s)async function runCommitSelectedMultiSelectionWorkflow.*?resourceStateArgument\(commitSelectedMultiSelectionWorkingCopyRoot, firstSelected\).*?resourceStateArgument\(commitSelectedMultiSelectionWorkingCopyRoot, secondSelected\).*?executeCommand\("subversionr\.commitResource", commandArguments\)') "Installed Source Control UI E2E harness should run Commit Selected multi-selection through the installed SCM resource array command argument."
  Assert-True ($workflowContent -match "sourceControlUiCommitSelectedMultiSelectionWorkflow") "Installed Source Control UI E2E evidence should publish the Commit Selected multi-selection workflow report."
  Assert-True ($workflowContent -match "Get-CommitSelectedMultiSelectionRepositoryOracle") "Installed Source Control UI E2E evidence should verify Commit Selected multi-selection using an SVN repository oracle."
  Assert-True ($workflowContent -match '(?s)async function runLockUnlockWorkflow.*?findResource\(openReport, "changes", resourcePath, "subversionr\.workingCopyMetadataFile"\).*?executeCommand\("subversionr\.lockResource", resourceStateArgument\(lockWorkingCopyRoot, resource\)\).*?currentUnlockResource.*?findResource\(preUnlockSurfaceReport, "changes", resource\.path, "subversionr\.workingCopyMetadataFile\.locked"\).*?executeCommand\("subversionr\.unlockResource", resourceStateArgument\(lockWorkingCopyRoot, currentUnlockResource\)\)') "Installed Source Control UI E2E harness should refresh the installed SCM resource command argument before Unlock so the projection generation is current."
  Assert-True ($workflowContent -match "sourceControlUiLockUnlockWorkflow") "Installed Source Control UI E2E evidence should publish the Lock/Unlock workflow report."
  Assert-True ($workflowContent -match "Get-LockHeldWorkingCopyOracle") "Installed Source Control UI E2E evidence should verify the held lock using an SVN working-copy oracle."
  Assert-True ($workflowContent -match "Get-LockUnlockWorkingCopyOracle") "Installed Source Control UI E2E evidence should verify unlock and svn:needs-lock preservation using an SVN working-copy oracle."
  Assert-True ($workflowContent -match "operationLock") "Installed Source Control UI E2E evidence should publish post-lock targeted reconcile coverage."
  Assert-True ($workflowContent -match "operationUnlock") "Installed Source Control UI E2E evidence should publish post-unlock targeted reconcile coverage."
  Assert-True ($workflowContent -match "sourceControlUiLockMessageCancellationWorkflow") "Installed Source Control UI E2E evidence should publish the Lock message cancellation workflow report."
  Assert-True ($workflowContent -match "sourceControlUiUnlockModeCancellationWorkflow") "Installed Source Control UI E2E evidence should publish the Unlock mode cancellation workflow report."
  Assert-True ($workflowContent -match "lockMessageCancellationPromptCapture") "Installed Source Control UI E2E evidence should publish Lock message cancellation prompt renderer capture evidence."
  Assert-True ($workflowContent -match "unlockModeCancellationPromptCapture") "Installed Source Control UI E2E evidence should publish Unlock mode cancellation prompt renderer capture evidence."
  Assert-True ($workflowContent -match '(?s)async function runLockUnlockWorkflow.*?phase: "lockMessageCancellationPromptReady".*?cancelKey: "Escape".*?sourceControlProjectionUnchanged') "Installed Source Control UI E2E harness should cancel the Lock message QuickInput with Escape and prove no Source Control mutation."
  Assert-True ($workflowContent -match '(?s)async function runLockUnlockWorkflow.*?phase: "unlockModeCancellationPromptReady".*?cancelKey: "Escape".*?sourceControlProjectionUnchanged') "Installed Source Control UI E2E harness should cancel the Unlock mode QuickPick with Escape and prove no Source Control mutation."
  Assert-True ($workflowContent -notmatch 'JSON\.stringify\([^)]*sourceControl\.groups') "Installed Source Control UI E2E harness should compare stable Source Control projection fields instead of raw groups JSON because refresh generation metadata can change without resource mutation."
  Assert-True (-not ($workflowContent -match "resourceProjectionUnchanged")) "Installed Source Control UI E2E harness should not reduce cancellation evidence to a single-resource projection check."
  Assert-True ($workflowContent -match '(?s)function stableSourceControlGroups.*?filter\(group => group\.count !== 0 \|\| \(Array\.isArray\(group\.resources\) && group\.resources\.length !== 0\)\)') "Installed Source Control UI E2E stable projection comparison should normalize empty fixed SCM groups while preserving non-empty group mutations."
  Assert-True ($workflowContent -match '(?s)function sourceControlProjectionMatches.*?actualReport\.sourceControl\.count === expectedReport\.sourceControl\.count.*?stableSourceControlGroups\(actualReport\).*?stableSourceControlGroups\(expectedReport\)') "Installed Source Control UI E2E harness should compare stable full projection groups and counts."
  Assert-True ($workflowContent -match '(?s)lockMessageCancellationProjectionUnchanged\s*=.*?sourceControlProjectionMatches\(lockMessageCancellationSurfaceReport, openReport\)') "Lock message cancellation should compare the full Source Control projection with the pre-cancellation open report."
  Assert-True ($workflowContent -match '(?s)unlockModeCancellationProjectionUnchanged\s*=.*?sourceControlProjectionMatches\(unlockModeCancellationSurfaceReport, preUnlockSurfaceReport\)') "Unlock mode cancellation should compare the full Source Control projection with the pre-cancellation locked surface report."
  Assert-True ($workflowContent -match "sourceControlUiBranchCreateWorkflow") "Installed Source Control UI E2E evidence should publish the Branch/Tag create workflow report."
  Assert-True ($workflowContent -match "Get-BranchCreateRepositoryOracle") "Installed Source Control UI E2E evidence should verify Branch/Tag create using an SVN repository oracle."
  Assert-True ($workflowContent -match '(?s)async function runBranchCreateWorkflow.*?phase: "branchCreateSwitchPromptReady".*?selected: "Stay on the current SVN URL"') "Installed Source Control UI E2E Branch/Tag create workflow should capture the stay-on-current-URL QuickPick before waiting for the branch create command to finish."
  Assert-True ($workflowContent -match "sourceControlUiSwitchWorkflow") "Installed Source Control UI E2E evidence should publish the Switch workflow report."
  Assert-True ($workflowContent -match "Get-SwitchWorkingCopyOracle") "Installed Source Control UI E2E evidence should verify Switch using an SVN working-copy oracle."
  Assert-True ($workflowContent -match "sourceControlUiCheckoutCancellationWorkflow") "Installed Source Control UI E2E evidence should publish the Checkout cancellation workflow report."
  Assert-True ($workflowContent -match "checkoutCancellationPromptCapture") "Installed Source Control UI E2E evidence should publish Checkout cancellation prompt renderer capture evidence."
  Assert-True ($workflowContent -match '(?s)function checkoutCancellationPromptCaptureExpectations.*?cancelSurface: "quickInput".*?cancelKey: "Escape"') "Installed Source Control UI E2E harness should require the Checkout cancellation renderer capture to cancel a QuickInput with Escape."
  Assert-True ($workflowContent -match '(?s)async function runCheckoutCancellationWorkflow.*?collectMissingCurrentSurfaceProbe.*?executeCommand\("subversionr\.checkoutRepository"\).*?checkoutCancellationPromptCaptureExpectations\(\).*?currentSurfaceProbes.*?targetAbsentAfter.*?sourceControlProjectionUnchanged') "Installed Source Control UI E2E harness should execute Checkout Repository, cancel the URL QuickInput, and prove no checkout state pollution through current-surface probes."
  Assert-True ($workflowContent -match "sourceControlUiCheckoutInvalidUrlFailureWorkflow") "Installed Source Control UI E2E evidence should publish the Checkout invalid URL failure workflow report."
  Assert-True ($workflowContent -match "checkoutInvalidUrlFailureNotificationCapture") "Installed Source Control UI E2E evidence should publish Checkout invalid URL failure notification renderer capture evidence."
  Assert-True ($workflowContent -match '(?s)async function runCheckoutExistingTargetFailureWorkflow.*?checkoutFailureNotificationCaptureExpectations\(notificationCode\).*?clearWorkbenchNotificationsBeforePrompt\("checkoutExistingTargetFailureNotification"\).*?notificationCleanup') "Checkout existing-target failure should capture the notification and then clear it through the explicit VS Code notification cleanup command."
  Assert-True ($workflowContent -match '(?s)async function runCheckoutInvalidUrlFailureWorkflow.*?checkoutFailureNotificationCaptureExpectations\(notificationCode\).*?clearWorkbenchNotificationsBeforePrompt\("checkoutInvalidUrlFailureNotification"\).*?notificationCleanup') "Checkout invalid-url failure should capture the notification and then clear it through the explicit VS Code notification cleanup command."
  Assert-True ($workflowContent -match '(?s)writeResult\(\{\s*ok: true.*?checkoutExistingTargetFailureReport,\s*checkoutInvalidUrlFailureReport,\s*checkoutExistingDirectoryReport,\s*checkoutExistingDirectoryObstructionReport,\s*checkoutReport,') "Installed Source Control UI E2E final harness result should keep every Checkout workflow report required by the PowerShell evidence validator."
  Assert-True ($workflowContent -match '(?s)async function runCheckoutInvalidUrlFailureWorkflow.*?executeCommand\("subversionr\.checkoutRepository"\).*?SVN_REPOSITORY_CHECKOUT_FAILED.*?targetAbsentAfter.*?svnMetadataAbsentAfter.*?repositoryNotOpenedAfterFailure.*?sourceControlProjectionUnchanged') "Installed Source Control UI E2E harness should execute Checkout Repository with an invalid URL and prove failure without checkout state pollution."
  Assert-True ($workflowContent -match "sourceControlUiUpdateToRevisionCancellationWorkflow") "Installed Source Control UI E2E evidence should publish the Update to Revision cancellation workflow report."
  Assert-True ($workflowContent -match "updateCancellationRevisionPromptCapture") "Installed Source Control UI E2E evidence should publish Update to Revision cancellation prompt renderer capture evidence."
  Assert-True ($workflowContent -match '(?s)async function runUpdateToRevisionCancellationWorkflow.*?executeCommand\("subversionr\.updateToRevision"\).*?cancelKey: "Escape".*?targetContentUnchangedAfterCancellation.*?sourceControlProjectionUnchanged') "Installed Source Control UI E2E harness should execute Update to Revision, cancel the revision QuickInput, and prove no update state pollution."
  Assert-True ($workflowContent -match '(?s)async function runBranchCreateWorkflow.*?executeCommand\("subversionr\.branchCreateRepository"\)') "Installed Source Control UI E2E harness should execute the installed Branch/Tag create command."
  Assert-True ($workflowContent -match '(?s)async function runSwitchWorkflow.*?executeCommand\("subversionr\.switchRepository"\).*?sourceControlProjectionAvailable') "Installed Source Control UI E2E harness should execute installed Switch and prove Source Control projection after reconcile."
  Assert-True ($workflowContent -match "(?s)postDeleteFreshnessReport\s*=\s*await collectFreshnessReportWithSurfaceRetry") "Delete Unversioned workflow should collect post-delete freshness through the surface retry helper."
  Assert-True ($workflowContent -match '(?s)async function runRemoveKeepLocalWorkflow.*?preRemoveFreshnessReport\s*=\s*await collectFreshnessReportWithSurfaceRetry.*?validateFreshnessReport\(preRemoveFreshnessReport, "partial", openReport, \{\s*expectUnversionedScratch: false\s*\}\).*?findResource\(preRemoveFreshnessReport, "changes", "src/tracked\.txt", "subversionr\.changedFile\.baseDiffable"\).*?resourceStateArgument\(workingCopyRoot, resource\)') "Keep-local Remove workflow should build the command argument from just-in-time SourceControl evidence, not the initial open report."
  Assert-True ($workflowContent -match '(?s)async function runRemoveKeepLocalWorkflow.*?postRemoveFreshnessReport\s*=\s*await collectFreshnessReportWithSurfaceRetry') "Keep-local Remove workflow should collect post-remove freshness through the surface retry helper."
  Assert-True ($driverContent -match "async function closeNotification") "Renderer cancellation evidence should model notification close as an explicit cancellation action."
  Assert-True ($driverContent -match 'cancelledAction: "closeNotification"') "Renderer notification close evidence should not be reported as a keyboard cancellation."
  Assert-True ($driverContent -match "isTopRightCloseAffordance") "Renderer notification close evidence should constrain close-button clicks to the notification top-right affordance instead of matching action buttons."
  Assert-True ($driverContent -match '(?s)async function closeNotification.*?key: "Delete".*?windowsVirtualKeyCode: 46') "Renderer notification close evidence should activate the notification clear affordance through its Delete keybinding."
  Assert-True ($driverContent -match "captureScreenshotWithRetry") "Renderer capture should retry transient CDP Page.captureScreenshot timeouts before failing the evidence capture."
  Assert-True ($workflowContent -match "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MISSING_WORKING_COPY_ROOT") "Installed Source Control UI E2E harness should use an explicit E2E-only missing working-copy override for lifecycle deletion."
  Assert-True ($workflowContent -match "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_EXTRA_WORKSPACE_ROOT") "Installed Source Control UI E2E harness should use an explicit E2E-only extra workspace root for lifecycle move recovery."
  Assert-True ($workflowContent -match 'Copy-Item -LiteralPath \$moveFixture\.workingCopyRoot') "Installed Source Control UI E2E setup should pre-copy the moved working-copy destination fixture."
  Assert-True ($workflowContent -match '(?s)async function runMoveCancellationWorkflow.*?phase: "moveCancellationPromptReady".*?cancelKey: "Escape".*?prompt:\s*\{\s*cancelKey: "Escape"') "Installed Source Control UI E2E move cancellation workflow should report the same Escape key used to dismiss the QuickInput."
  Assert-True ($workflowContent -match '(?s)async function runRemoveCancellationWorkflow\(removeCancellationWorkingCopyRoot, removeCancellationPromptReadyPath, removeCancellationPromptDonePath\).*?phase: "removeCancellationPromptReady".*?cancelAction: "notifications\.clearAll".*?waitForFile\(removeCancellationPromptDonePath.*?clearWorkbenchNotificationsBeforePrompt\("removeCancellation"\).*?prompt:\s*\{\s*cancelAction: "notifications\.clearAll"') "Installed Source Control UI E2E remove cancellation workflow should wait for renderer evidence before clearing the notification through the explicit VS Code command."
  Assert-True ($workflowContent -match '(?s)async function runRevertCancellationWorkflow\(revertCancellationWorkingCopyRoot, revertCancellationPromptReadyPath, revertCancellationPromptDonePath\).*?phase: "revertCancellationPromptReady".*?cancelAction: "notifications\.clearAll".*?waitForFile\(revertCancellationPromptDonePath.*?clearWorkbenchNotificationsBeforePrompt\("revertCancellation"\).*?prompt:\s*\{\s*cancelAction: "notifications\.clearAll"') "Installed Source Control UI E2E revert cancellation workflow should wait for renderer evidence before clearing the notification through the explicit VS Code command."
  Assert-True ($workflowContent -match '(?s)async function runRemoveCancellationWorkflow.*?sourceControlProjectionUnchanged\s*=\s*sourceControlProjectionMatches\(\s*postCancelFreshnessReport,\s*removeCancellationOpenReport\s*\).*?sourceControlProjectionUnchanged') "Installed Source Control UI E2E remove cancellation workflow should compare the full stable Source Control projection after cancellation."
  Assert-True ($workflowContent -match '(?s)async function runRevertCancellationWorkflow.*?sourceControlProjectionUnchanged\s*=\s*sourceControlProjectionMatches\(\s*postCancelFreshnessReport,\s*revertCancellationOpenReport\s*\).*?sourceControlProjectionUnchanged') "Installed Source Control UI E2E revert cancellation workflow should compare the full stable Source Control projection after cancellation."
  Assert-True ($workflowContent -match '(?s)async function runResolveCancellationWorkflow.*?phase: "resolveCancellationPromptReady".*?prompt:\s*\{\s*cancelKey: "Escape"') "Installed Source Control UI E2E resolve cancellation workflow should report the Escape key used to cancel the Resolve QuickInput."
  Assert-True ($workflowContent -match '(?s)function cleanupPromptCaptureExpectations.*?quickInputSubmitKey: "Enter"') "Installed Source Control UI E2E cleanup prompt expectations should submit the cleanup options QuickInput with Enter."
  Assert-True ($workflowContent -match '(?s)async function runCleanupWorkflow.*?executeCommand\("subversionr\.cleanupRepository", openReport\.repository\.repositoryId\).*?phase: "cleanupPromptReady".*?prompt:\s*\{\s*quickInputSubmitKey: "Enter"') "Installed Source Control UI E2E cleanup workflow should expose and report the cleanup options QuickInput prompt."
  Assert-True ($workflowContent -match "cleanupPromptCapture") "Installed Source Control UI E2E evidence should publish Cleanup prompt renderer capture evidence."
  Assert-True (-not ($workflowContent -match "fs\.renameSync\(\s*deleteWorkingCopyRoot")) "Installed Source Control UI E2E harness should not rename an open Windows working copy for lifecycle deletion."
  Assert-True (-not ($workflowContent -match "fs\.rmSync\(\s*deleteWorkingCopyRoot")) "Installed Source Control UI E2E harness should not recursively delete an open Windows working copy for lifecycle deletion."
  Assert-True (-not ($workflowContent -match "fs\.renameSync\(\s*moveWorkingCopyRoot")) "Installed Source Control UI E2E harness should not rename an open Windows working copy for lifecycle move recovery."
  Assert-True ($ciWorkflow.Contains("Release installed Source Control UI E2E script tests")) "CI should run M7j3 installed Source Control UI E2E script tests."
  Assert-True ($ciWorkflow.Contains("Test installed VSIX Source Control UI E2E")) "CI should run the installed Source Control UI E2E gate."

  Write-Host "Release installed Source Control UI E2E script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

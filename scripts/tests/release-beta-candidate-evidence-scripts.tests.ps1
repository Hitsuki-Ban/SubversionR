$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).ProviderPath
$workflowScript = Join-Path $repoRoot "scripts\release\verify-beta-candidate-evidence.ps1"
$manifestScript = Join-Path $repoRoot "scripts\release\generate-beta-artifact-bundle-manifest.ps1"
$orchestrationScript = Join-Path $repoRoot "scripts\release\run-beta-candidate-evidence.ps1"
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

function Assert-ContainsInOrder([string]$Text, [string[]]$ExpectedTerms, [string]$Message) {
  $cursor = 0
  foreach ($term in $ExpectedTerms) {
    $index = $Text.IndexOf($term, $cursor, [System.StringComparison]::Ordinal)
    Assert-True ($index -ge 0) "$Message Expected to find '$term' after offset $cursor."
    $cursor = $index + $term.Length
  }
}

function Get-Sha256([string]$Path) {
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Convert-ToRepoRelativePath([string]$Path) {
  [System.IO.Path]::GetRelativePath($repoRoot, $Path).Replace("\", "/")
}

function Write-Json([string]$Path, [object]$Value, [int]$Depth = 20) {
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding utf8
}

function New-HashRecord([string]$Path) {
  [pscustomobject]@{
    path = Convert-ToRepoRelativePath $Path
    sha256 = Get-Sha256 $Path
  }
}

function New-FakeVsix([string]$Root, [string]$EntrypointContent) {
  $stagingRoot = Join-Path $Root "vsix-staging"
  $entrypointPath = Join-Path $stagingRoot "extension\dist\extension.js"
  $packageJsonPath = Join-Path $stagingRoot "extension\package.json"
  $manifestPath = Join-Path $stagingRoot "extension.vsixmanifest"
  $backendArtifactPath = Join-Path $stagingRoot "extension\resources\backend\win32-x64\subversionr-daemon.exe"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $entrypointPath) | Out-Null
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backendArtifactPath) | Out-Null
  Set-Content -LiteralPath $entrypointPath -Encoding utf8 -NoNewline -Value $EntrypointContent
  Set-Content -LiteralPath $packageJsonPath -Encoding utf8 -NoNewline -Value '{"name":"subversionr","publisher":"hitsuki-ban","version":"0.2.5","displayName":"SVN-R"}'
  Set-Content -LiteralPath $manifestPath -Encoding utf8 -NoNewline -Value @'
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Id="subversionr" Version="0.2.5" Language="en-US" Publisher="hitsuki-ban" TargetPlatform="win32-x64" />
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.PreRelease" Value="true" />
    </Properties>
  </Metadata>
</PackageManifest>
'@
  Set-Content -LiteralPath $backendArtifactPath -Encoding utf8 -NoNewline -Value "fake sidecar"

  $vsixPath = Join-Path $Root "vsix\subversionr-win32-x64-0.2.5.vsix"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $vsixPath) | Out-Null
  Remove-Item -LiteralPath $vsixPath -Force -ErrorAction SilentlyContinue
  [System.IO.Compression.ZipFile]::CreateFromDirectory($stagingRoot, $vsixPath)

  [pscustomobject]@{
    path = $vsixPath
    relativePath = Convert-ToRepoRelativePath $vsixPath
    size = (Get-Item -LiteralPath $vsixPath).Length
    sha256 = Get-Sha256 $vsixPath
    entrypointSha256 = Get-Sha256 $entrypointPath
    backendArtifact = [pscustomobject]@{
      role = "sidecar"
      path = "resources/backend/win32-x64/subversionr-daemon.exe"
      size = (Get-Item -LiteralPath $backendArtifactPath).Length
      sha256 = Get-Sha256 $backendArtifactPath
    }
  }
}

function New-EvidencePath([string]$EvidenceRoot, [string]$Name) {
  Join-Path $EvidenceRoot "subversionr-$Name-win32-x64.json"
}

function Get-BetaArtifactBundleUploadPaths {
  @(
    "target/vsix/subversionr-win32-x64-0.2.5.vsix",
    "target/release-evidence/subversionr-source-sbom.cdx.json",
    "target/release-evidence/subversionr-vsix-package-win32-x64.json",
    "target/release-evidence/subversionr-vsix-cli-install-win32-x64.json",
    "target/release-evidence/subversionr-installed-extension-host-win32-x64.json",
    "target/release-evidence/subversionr-installed-core-workflow-win32-x64.json",
    "target/release-evidence/subversionr-installed-source-control-surface-win32-x64.json",
    "target/release-evidence/subversionr-installed-source-control-ui-e2e-win32-x64.json",
    "target/release-evidence/subversionr-install-rollback-fixture-win32-x64.json",
    "target/release-evidence/subversionr-native-artifact-map-preflight-win32-x64.json",
    "target/release-evidence/subversionr-marketplace-provenance-preflight-win32-x64.json",
    "target/release-evidence/subversionr-publication-gaps-win32-x64.json",
    "target/release-evidence/subversionr-state-engine-beta-performance-win32-x64.json",
    "target/release-evidence/subversionr-beta-artifact-bundle-manifest-win32-x64.json",
    "target/release-evidence/subversionr-beta-candidate-consistency-win32-x64.json",
    "target/release-evidence/THIRD-PARTY-NOTICES.md",
    "target/release-evidence/installed-source-control-ui-e2e/win32-x64/**/*.png",
    "target/release-evidence/installed-source-control-ui-e2e/win32-x64/**/*.txt",
    "target/release-evidence/installed-source-control-ui-e2e/win32-x64/**/*.json"
  )
}

function Get-BetaArtifactBundleUploadPathBlock([string]$Indent) {
  (Get-BetaArtifactBundleUploadPaths | ForEach-Object { "$Indent$_" }) -join "`r`n"
}

function Invoke-BetaArtifactBundleManifest([object]$Fixture) {
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $manifestScript `
    -Target win32-x64 `
    -VsixPath $Fixture.vsix.path `
    -ReleaseEvidenceRoot $Fixture.evidenceRoot `
    -NoticePath $Fixture.noticePath `
    -InstalledSourceControlUiE2eArtifactRoot $Fixture.installedUiArtifactRoot `
    -OutputPath $Fixture.artifactBundleManifestPath
}

function New-BetaArtifactBundleManifest([object]$Fixture) {
  $output = Invoke-BetaArtifactBundleManifest $Fixture 2>&1
  if ($LASTEXITCODE -ne 0) {
    $text = $output | Out-String
    throw "generate-beta-artifact-bundle-manifest.ps1 failed with exit code $LASTEXITCODE. $text"
  }
}

function Write-InstalledEvidence([string]$EvidenceRoot, [string]$Name, [string]$SchemaName, [object]$Vsix, [int]$SchemaVersion = 1) {
  $evidence = [pscustomobject]@{
    schemaVersion = $SchemaVersion
    schema = "subversionr.release.$SchemaName.win32-x64.v$SchemaVersion"
    publicReadinessClaim = $false
    target = "win32-x64"
    extension = [pscustomobject]@{
      id = "hitsuki-ban.subversionr"
      version = "0.2.5"
      source = "installed-vsix"
    }
    installedExtensions = @("hitsuki-ban.subversionr@0.2.5")
    vsix = [pscustomobject]@{
      path = $Vsix.path
      relativePath = $Vsix.relativePath
      targetPlatform = "win32-x64"
      sha256 = $Vsix.sha256
    }
  }
  if ($Name -eq "installed-core-workflow") {
    $evidence | Add-Member -NotePropertyName versionReport -NotePropertyValue ([pscustomobject]@{
      kind = "subversionr.versionReport"
      extension = [pscustomobject]@{
        version = "0.2.5"
      }
      backend = [pscustomobject]@{
        status = "initialized"
        backendVersion = "0.2.5"
        bridgeVersion = "subversionr-svn-bridge/0.2.5"
        libsvnVersion = "1.14.5"
      }
    })
  }
  Write-Json (New-EvidencePath $EvidenceRoot $Name) $evidence
}

function New-Workflow([string]$Kind) {
  [pscustomobject]@{
    kind = $Kind
  }
}

function New-CancelPrompt() {
  [pscustomobject]@{
    cancelKey = "Escape"
    rendererCaptureExpectations = [pscustomobject]@{
      cancelSurface = "quickInput"
    }
  }
}

function New-MissingCurrentSurfaceProbe() {
  [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eMissingCurrentSurfaceProbe"
    assertions = [pscustomobject]@{
      currentSessionMissing = $true
      sourceControlProjectionAbsent = $true
    }
  }
}

function New-CurrentSurfaceReport() {
  [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eCurrentSurfaceReport"
    surfaceWorkflow = [pscustomobject]@{
      repositoryOpen = $true
      scmProjection = $true
      sourceControlSurface = $true
    }
  }
}

function New-CloseReport() {
  [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eCloseReport"
    repositoryClosed = $true
  }
}

function New-HistoryRendererCapture([switch]$Loaded, [switch]$Notification) {
  $selectedRowTexts = [System.Collections.Generic.List[string]]::new()
  if ($Loaded) {
    $selectedRowTexts.Add("C:/wc")
  }
  [pscustomobject]@{
    schema = "subversionr.release.installed-source-control-ui-renderer-capture.v1"
    assertions = [pscustomobject]@{
      domRequiredTokensPresent = $true
      accessibilityRequiredTokensPresent = $true
      screenshotNonBlank = $true
      treeViewVisible = $true
      treeViewExpanded = $true
      treeViewFocused = [bool]$Loaded
      treeViewSelectionMatched = [bool]$Loaded
      notificationCancelled = [bool]$Notification
    }
    interaction = [pscustomobject]@{
      kind = "treeViewState"
      found = $true
      visible = $true
      expanded = [bool]$Loaded
      focused = [bool]$Loaded
      selectedRowTexts = $selectedRowTexts
    }
  }
}

function Write-InstalledSourceControlUiE2eEvidence([string]$EvidenceRoot, [object]$Vsix) {
  Write-Json (New-EvidencePath $EvidenceRoot "installed-source-control-ui-e2e") ([pscustomobject]@{
    schemaVersion = 1
    schema = "subversionr.release.installed-source-control-ui-e2e.win32-x64.v1"
    publicReadinessClaim = $false
    target = "win32-x64"
    traceIds = @("BRM-001", "BRM-005", "HIS-001", "OPS-010", "OPS-011", "OPS-013", "STA-014", "TST-018", "TST-024", "UX-002")
    nonClaims = @(
      "This gate does not prove Marketplace publication.",
      "This gate does not prove VSIX signing or supply-chain provenance publication.",
      "This gate does not prove previous-stable upgrade or rollback behavior.",
      "This gate does not prove svnserve, HTTP, HTTPS, auth, or certificate flows.",
      "This gate proves the installed Checkout Repository happy path, pre-existing local directory target success path, existing-directory obstruction tree-conflict projection path, URL prompt cancellation, and covered local-file checkout failure/no-state-pollution flows but does not prove repository browser, remote auth/certificate, or broader checkout failure matrices.",
      "This gate proves installed Update to Revision prompts, local-file rN/depth/sticky-depth/externals execution, and revision prompt cancellation without working-copy or Source Control projection mutation but does not prove remote update failures, auth/certificate update flows, backend update failure UX, mixed-revision edge analysis, or load-scale update behavior.",
      "This gate proves installed Add to Ignore through svn:ignore property update but does not prove a full property editor, svn:externals editing, remote/auth/certificate property flows, property cancellation UX, or property load behavior.",
      "This gate proves installed Lock and Unlock plus Lock message and Unlock mode prompt cancellation for a local file-backed svn:needs-lock working copy item but does not prove broad remote lock-server matrices, auth/certificate lock prompts, break-lock policy, steal-lock policy, or lock load behavior.",
      "This gate proves installed changelist set/clear plus commit/revert by changelist happy paths but does not prove changelist load behavior, cancellation UX for all changelist commands, project-wide changelist policy UX, or commit template/message-history behavior.",
      "This gate proves installed Branch/Tag create and Switch local file-backed happy paths but does not prove switch-after-copy, target browsing, broad remote/auth/certificate matrices, repository-browser integration, merge workflows, or switched working-copy edge/load behavior.",
      "This gate proves installed local file-backed Repository Log targeting, history view reveal/focus, and missing-author presentation but does not prove remote history, repository browsing, merge history, or broad history load behavior."
    )
    extension = [pscustomobject]@{
      id = "hitsuki-ban.subversionr"
      version = "0.2.5"
      source = "installed-vsix"
      hasCheckoutRepositoryCommand = $true
      hasUpdateToRevisionCommand = $true
      hasAddToIgnoreResourceCommand = $true
      hasLockResourceCommand = $true
      hasUnlockResourceCommand = $true
      hasSetResourceChangelistCommand = $true
      hasClearResourceChangelistCommand = $true
      hasCommitChangelistCommand = $true
      hasRevertChangelistCommand = $true
      hasBranchCreateRepositoryCommand = $true
      hasSwitchRepositoryCommand = $true
      hasInstalledSourceControlUiE2eRepositoryHistoryReportCommand = $true
      hasShowRepositoryLogCommand = $true
    }
    trustedProfile = [pscustomobject]@{
      extensionHostTrusted = $true
      openReportTrusted = $true
    }
    installedExtensions = @("hitsuki-ban.subversionr@0.2.5")
    vsix = [pscustomobject]@{
      path = $Vsix.path
      relativePath = $Vsix.relativePath
      targetPlatform = "win32-x64"
      sha256 = $Vsix.sha256
    }
    sourceControlUiCheckoutCancellationWorkflow = [pscustomobject]@{
      kind = "subversionr.installedSourceControlUiE2eCheckoutCancellationWorkflow"
      command = [pscustomobject]@{ command = "subversionr.checkoutRepository" }
      prompt = New-CancelPrompt
      currentSurfaceProbes = [pscustomobject]@{ targetAfter = New-MissingCurrentSurfaceProbe }
      assertions = [pscustomobject]@{
        commandCancelled = $true
        targetAbsentAfter = $true
        svnMetadataAbsentAfter = $true
        repositoryNotOpenedAfterCancellation = $true
        sourceControlProjectionUnchanged = $true
      }
    }
    sourceControlUiRepositoryHistoryWorkflow = [pscustomobject]@{
      kind = "subversionr.installedSourceControlUiE2eRepositoryHistoryWorkflow"
      command = [pscustomobject]@{
        command = "subversionr.showRepositoryLog"
        target = [pscustomobject]@{ kind = "subversionr.repositoryHistoryTarget"; repositoryId = "repo-1"; epoch = 1 }
      }
      fixture = [pscustomobject]@{ missingAuthorRevision = 2; emptyAuthorRevision = 3 }
      staleReport = [pscustomobject]@{
        diagnostics = [pscustomobject]@{
          latestHistoryTargetingError = [pscustomobject]@{ code = "SUBVERSIONR_HISTORY_REPOSITORY_SESSION_STALE" }
        }
      }
      assertions = [pscustomobject]@{
        exactRepositorySessionTargeted = $true
        missingAuthorRenderedAsUnknown = $true
        emptyAuthorRenderedAsUnknown = $true
        historyViewInitiallyCollapsed = $true
        historyViewVisibleExpandedFocusedSelected = $true
        workingCopyRootLabelVisible = $true
        internalRepositoryIdHiddenFromRenderer = $true
        staleTargetRejectedWithStableCode = $true
        staleNotificationLocalizedAndActionable = $true
        diagnosticsBoundedAndRedacted = $true
        sourceControlProjectionUnchanged = $true
        lastCompletedRefreshUnchanged = $true
        statusRefreshNotRequested = $true
        reconcileNotRequested = $true
        remoteStatusPollingNotRequested = $true
      }
    }
    repositoryHistoryInitialRendererCapture = New-HistoryRendererCapture
    repositoryHistoryLoadedRendererCapture = New-HistoryRendererCapture -Loaded
    repositoryHistoryStaleNotificationRendererCapture = New-HistoryRendererCapture -Notification
    sourceControlUiCheckoutExistingTargetFailureWorkflow = [pscustomobject]@{
      kind = "subversionr.installedSourceControlUiE2eCheckoutExistingTargetFailureWorkflow"
      command = [pscustomobject]@{ command = "subversionr.checkoutRepository" }
      failure = [pscustomobject]@{ code = "SVN_REPOSITORY_CHECKOUT_FAILED" }
      notification = [pscustomobject]@{ cleanup = [pscustomobject]@{ command = "notifications.clearAll"; cleared = $true } }
      currentSurfaceProbes = [pscustomobject]@{ targetAfter = New-MissingCurrentSurfaceProbe }
      assertions = [pscustomobject]@{
        commandFailed = $true
        obstructingTargetFilePreserved = $true
        svnMetadataAbsentAfter = $true
        fixtureDirectoryUnchanged = $true
        repositoryNotOpenedAfterFailure = $true
        sourceControlProjectionUnchanged = $true
      }
    }
    sourceControlUiCheckoutInvalidUrlFailureWorkflow = [pscustomobject]@{
      kind = "subversionr.installedSourceControlUiE2eCheckoutInvalidUrlFailureWorkflow"
      command = [pscustomobject]@{ command = "subversionr.checkoutRepository" }
      failure = [pscustomobject]@{ code = "SVN_REPOSITORY_CHECKOUT_FAILED" }
      notification = [pscustomobject]@{ cleanup = [pscustomobject]@{ command = "notifications.clearAll"; cleared = $true } }
      currentSurfaceProbes = [pscustomobject]@{ targetAfter = New-MissingCurrentSurfaceProbe }
      assertions = [pscustomobject]@{
        commandFailed = $true
        invalidUrlRejected = $true
        targetAbsentAfter = $true
        svnMetadataAbsentAfter = $true
        parentDirectoryUnchanged = $true
        repositoryNotOpenedAfterFailure = $true
        sourceControlProjectionUnchanged = $true
      }
    }
    sourceControlUiCheckoutExistingDirectoryWorkflow = New-Workflow "subversionr.installedSourceControlUiE2eCheckoutExistingDirectoryWorkflow"
    sourceControlUiCheckoutExistingDirectoryObstructionWorkflow = New-Workflow "subversionr.installedSourceControlUiE2eCheckoutExistingDirectoryObstructionWorkflow"
    sourceControlUiCheckoutWorkflow = New-Workflow "subversionr.installedSourceControlUiE2eCheckoutWorkflow"
    sourceControlUiUpdateToRevisionCancellationWorkflow = [pscustomobject]@{
      kind = "subversionr.installedSourceControlUiE2eUpdateToRevisionCancellationWorkflow"
      command = [pscustomobject]@{ command = "subversionr.updateToRevision" }
      prompt = New-CancelPrompt
      closeReport = New-CloseReport
      assertions = [pscustomobject]@{
        commandCancelled = $true
        targetContentUnchangedAfterCancellation = $true
        requestedRevisionContentNotApplied = $true
        sourceControlProjectionUnchanged = $true
      }
    }
    sourceControlUiUpdateToRevisionWorkflow = New-Workflow "subversionr.installedSourceControlUiE2eUpdateToRevisionWorkflow"
    sourceControlUiAddToIgnoreWorkflow = New-Workflow "subversionr.installedSourceControlUiE2eAddToIgnoreWorkflow"
    sourceControlUiLockUnlockWorkflow = New-Workflow "subversionr.installedSourceControlUiE2eLockUnlockWorkflow"
    sourceControlUiLockMessageCancellationWorkflow = [pscustomobject]@{
      kind = "subversionr.installedSourceControlUiE2eLockMessageCancellationWorkflow"
      command = [pscustomobject]@{ command = "subversionr.lockResource" }
      resource = [pscustomobject]@{ path = "src/needs-lock.txt" }
      prompt = New-CancelPrompt
      currentSurfaceReport = New-CurrentSurfaceReport
      assertions = [pscustomobject]@{
        commandCancelled = $true
        sourceControlProjectionUnchanged = $true
        repositoryClosedAfterEvidence = $true
      }
    }
    sourceControlUiUnlockModeCancellationWorkflow = [pscustomobject]@{
      kind = "subversionr.installedSourceControlUiE2eUnlockModeCancellationWorkflow"
      command = [pscustomobject]@{ command = "subversionr.unlockResource" }
      resource = [pscustomobject]@{ path = "src/needs-lock.txt" }
      prompt = New-CancelPrompt
      currentSurfaceReport = New-CurrentSurfaceReport
      assertions = [pscustomobject]@{
        commandCancelled = $true
        sourceControlProjectionUnchanged = $true
        repositoryClosedAfterEvidence = $true
      }
    }
    sourceControlUiChangelistSetClearWorkflow = New-Workflow "subversionr.installedSourceControlUiE2eChangelistSetClearWorkflow"
    sourceControlUiCommitChangelistWorkflow = New-Workflow "subversionr.installedSourceControlUiE2eCommitChangelistWorkflow"
    sourceControlUiRevertChangelistWorkflow = New-Workflow "subversionr.installedSourceControlUiE2eRevertChangelistWorkflow"
    sourceControlUiBranchCreateWorkflow = [pscustomobject]@{
      kind = "subversionr.installedSourceControlUiE2eBranchCreateWorkflow"
      command = [pscustomobject]@{ command = "subversionr.branchCreateRepository" }
      request = [pscustomobject]@{ revision = "head"; makeParents = $false; ignoreExternals = $true }
      closeReport = New-CloseReport
      assertions = [pscustomobject]@{ commandExecuted = $true; branchCreatedInRepository = $true; noLocalReconcileClaimed = $true }
    }
    sourceControlUiSwitchWorkflow = [pscustomobject]@{
      kind = "subversionr.installedSourceControlUiE2eSwitchWorkflow"
      command = [pscustomobject]@{ command = "subversionr.switchRepository" }
      request = [pscustomobject]@{ revision = "head"; depth = "infinity"; depthIsSticky = $true; ignoreExternals = $true; ignoreAncestry = $false }
      currentSurfaceReport = New-CurrentSurfaceReport
      closeReport = New-CloseReport
      assertions = [pscustomobject]@{
        postSwitchReconcileCompleted = $true
        postSwitchGenerationAdvanced = $true
        postSwitchRepositoryIdentityPreserved = $true
        sourceControlProjectionAvailable = $true
      }
    }
    checkoutRepositoryOracle = [pscustomobject]@{ kind = "subversionr.installedSourceControlUiE2eCheckoutRepositoryOracle"; checkedOutBaselineContentMatched = $true }
    checkoutExistingDirectoryObstructionWorkingCopyOracle = [pscustomobject]@{ kind = "subversionr.installedSourceControlUiE2eCheckoutExistingDirectoryObstructionWorkingCopyOracle"; treeConflictPresent = $true; obstructionPreserved = $true }
    updateToRevisionRepositoryOracle = [pscustomobject]@{ kind = "subversionr.installedSourceControlUiE2eUpdateToRevisionRepositoryOracle"; updatedRevisionContentMatched = $true }
    addToIgnoreWorkingCopyOracle = [pscustomobject]@{ kind = "subversionr.installedSourceControlUiE2eAddToIgnoreWorkingCopyOracle"; propertyName = "svn:ignore"; ignorePatternPresent = $true; ignoredStatusPresent = $true }
    lockHeldWorkingCopyOracle = [pscustomobject]@{ kind = "subversionr.installedSourceControlUiE2eLockHeldWorkingCopyOracle"; svnInfoContainsLockToken = $true; svnInfoContainsLockOwner = $true }
    lockUnlockWorkingCopyOracle = [pscustomobject]@{ kind = "subversionr.installedSourceControlUiE2eLockUnlockWorkingCopyOracle"; needsLockProperty = "*"; svnInfoLockTokenAbsentAfterUnlock = $true }
    commitChangelistRepositoryOracle = [pscustomobject]@{ kind = "subversionr.installedSourceControlUiE2eCommitChangelistRepositoryOracle"; latestLogContainsCommitMessage = $true }
    branchCreateRepositoryOracle = [pscustomobject]@{ kind = "subversionr.installedSourceControlUiE2eBranchCreateRepositoryOracle"; branchContentMatched = $true; latestLogContainsBranchMessage = $true; copyFromPathMatched = $true; copyFromRevisionMatched = $true }
    switchWorkingCopyOracle = [pscustomobject]@{ kind = "subversionr.installedSourceControlUiE2eSwitchWorkingCopyOracle"; workingCopyUrlMatched = $true }
  })
}

function New-BetaCandidateFixture([string]$Root) {
  $evidenceRoot = Join-Path $Root "evidence"
  $inputRoot = Join-Path $Root "inputs"
  $packageRoot = Join-Path $Root "package\svn-r-win32-x64"
  New-Item -ItemType Directory -Force -Path $evidenceRoot, $inputRoot | Out-Null

  $vsix = New-FakeVsix -Root $Root -EntrypointContent "module.exports = 'beta candidate';"
  $backendManifestPath = Join-Path $packageRoot "resources\backend\win32-x64\subversionr-backend-package-manifest.json"
  Write-Json $backendManifestPath ([pscustomobject]@{
    schemaVersion = 1
    schema = "subversionr.vscode.backend-package.win32-x64.v1"
    target = "win32-x64"
    artifacts = @($vsix.backendArtifact)
  })

  $vsixEvidencePath = New-EvidencePath $evidenceRoot "vsix-package"
  Write-Json $vsixEvidencePath ([pscustomobject]@{
    schemaVersion = 1
    schema = "subversionr.release.vsix-package.win32-x64.v1"
    publicReadinessClaim = $false
    target = "win32-x64"
    extension = [pscustomobject]@{
      id = "hitsuki-ban.subversionr"
      displayName = "SVN-R"
      version = "0.2.5"
      preRelease = $true
    }
    nativeCompatibility = [pscustomobject]@{
      schema = "subversionr.release.packaged-native-version-evidence.v1"
      expectedProductVersion = "0.2.5"
      backendVersion = "0.2.5"
      bridgeVersion = "subversionr-svn-bridge/0.2.5"
      libsvnVersion = "1.14.5"
      protocol = [pscustomobject]@{
        major = 1
        minor = 30
      }
    }
    inputs = [pscustomobject]@{
      packageRoot = Convert-ToRepoRelativePath $packageRoot
      extensionEntrypointSha256 = $vsix.entrypointSha256
    }
    vsix = [pscustomobject]@{
      path = $vsix.path
      relativePath = $vsix.relativePath
      size = $vsix.size
      sha256 = $vsix.sha256
      extensionEntrypointSha256 = $vsix.entrypointSha256
    }
  })

  Write-Json (New-EvidencePath $evidenceRoot "vsix-cli-install") ([pscustomobject]@{
    schemaVersion = 1
    schema = "subversionr.release.vsix-cli-install.win32-x64.v1"
    publicReadinessClaim = $false
    target = "win32-x64"
    extension = [pscustomobject]@{
      id = "hitsuki-ban.subversionr"
      version = "0.2.5"
    }
    installedExtensions = @("hitsuki-ban.subversionr@0.2.5")
    vsix = [pscustomobject]@{
      path = $vsix.path
      relativePath = $vsix.relativePath
      size = $vsix.size
      targetPlatform = "win32-x64"
      sha256 = $vsix.sha256
    }
    hashes = [pscustomobject]@{
      vsixEntrypointSha256 = $vsix.entrypointSha256
      installedEntrypointSha256 = $vsix.entrypointSha256
    }
  })

  Write-InstalledEvidence $evidenceRoot "installed-extension-host" "installed-extension-host" $vsix
  Write-InstalledEvidence $evidenceRoot "installed-core-workflow" "installed-core-workflow" $vsix 2
  Write-InstalledEvidence $evidenceRoot "installed-source-control-surface" "installed-source-control-surface" $vsix
  Write-InstalledSourceControlUiE2eEvidence $evidenceRoot $vsix

  Write-Json (New-EvidencePath $evidenceRoot "install-rollback-fixture") ([pscustomobject]@{
    schemaVersion = 1
    schema = "subversionr.release.install-rollback-fixture.win32-x64.v1"
    fixtureKind = "isolated-vscode-extension-directory"
    publicReadinessClaim = $false
    target = "win32-x64"
    extension = [pscustomobject]@{
      id = "hitsuki-ban.subversionr"
      currentVersion = "0.2.5"
      previousVersion = "0.0.0-m7f.fixture"
    }
    packages = [pscustomobject]@{
      current = [pscustomobject]@{
        root = Convert-ToRepoRelativePath $packageRoot
        manifestSha256 = Get-Sha256 $backendManifestPath
        source = "staged-package-layout"
      }
    }
    workingCopySentinel = [pscustomobject]@{
      mutation = "none"
      beforeSha256 = "2222222222222222222222222222222222222222222222222222222222222222"
      afterSha256 = "2222222222222222222222222222222222222222222222222222222222222222"
    }
    phases = @(
      [pscustomobject]@{ name = "fresh-install"; workingCopyMutation = "none" },
      [pscustomobject]@{ name = "upgrade"; workingCopyMutation = "none" },
      [pscustomobject]@{ name = "rollback"; workingCopyMutation = "none" }
    )
  })

  $sourceLockPath = Join-Path $inputRoot "sources.lock.json"
  $artifactMapPath = Join-Path $inputRoot "native-artifact-map.win32-x64.json"
  Set-Content -LiteralPath $sourceLockPath -Encoding utf8 -NoNewline -Value '{"sources":[]}'
  Set-Content -LiteralPath $artifactMapPath -Encoding utf8 -NoNewline -Value '{"components":[]}'

  Write-Json (New-EvidencePath $evidenceRoot "native-artifact-map-preflight") ([pscustomobject]@{
    schemaVersion = 1
    schema = "subversionr.release.native-artifact-map-preflight.win32-x64.v1"
    publicReadinessClaim = $false
    target = "win32-x64"
    inputs = [pscustomobject]@{
      sourceLock = New-HashRecord $sourceLockPath
      artifactMap = New-HashRecord $artifactMapPath
      backendManifest = [pscustomobject]@{
        path = Convert-ToRepoRelativePath $backendManifestPath
        sha256 = Get-Sha256 $backendManifestPath
        artifactCount = 1
      }
      vsixEvidence = New-HashRecord $vsixEvidencePath
    }
    firstPartyArtifacts = @($vsix.backendArtifact)
    componentMappings = @()
  })

  $liveAttestationPath = Join-Path $inputRoot "github-attestation-evidence.win32-x64.json"
  $attestationBundlePath = Join-Path $inputRoot "github-attestation-bundle.win32-x64.json"
  $attestationVerificationPath = Join-Path $inputRoot "github-attestation-verification.win32-x64.json"
  $candidateAttestationContractPath = Join-Path $inputRoot "github-attestation-candidate-contract.win32-x64.json"
  Write-Json $candidateAttestationContractPath ([pscustomobject]@{
    schemaVersion = 1
    schema = "subversionr.release.github-attestation-contract.win32-x64.v1"
    status = "pending-release-attestation"
    publicReadinessClaim = $false
    target = "win32-x64"
    release = [pscustomobject]@{ tag = "v0.2.5-beta.1"; url = "https://github.com/Hitsuki-Ban/SubversionR/releases/tag/v0.2.5-beta.1" }
    subject = [pscustomobject]@{ name = (Split-Path -Leaf $vsix.path); size = $vsix.size; sha256 = $vsix.sha256; preReleaseProperty = $true }
  })
  Write-Json $liveAttestationPath ([pscustomobject]@{
    schema = "subversionr.release.live-github-attestation.win32-x64.v1"
    status = "live-attestation-verified"
  })
  Write-Json $attestationBundlePath ([pscustomobject]@{
    mediaType = "application/vnd.dev.sigstore.bundle.v0.3+json"
    verificationMaterial = [pscustomobject]@{ certificate = [pscustomobject]@{ rawBytes = "fixture" } }
  })
  Write-Json $attestationVerificationPath @(
    [pscustomobject]@{
      verificationResult = "success"
      attestation = [pscustomobject]@{
        bundle = Get-Content -Raw -LiteralPath $attestationBundlePath | ConvertFrom-Json
      }
    }
  )

  $provenancePath = New-EvidencePath $evidenceRoot "marketplace-provenance-preflight"
  Write-Json $provenancePath ([pscustomobject]@{
    schemaVersion = 1
    schema = "subversionr.release.marketplace-provenance-preflight.win32-x64.v1"
    publicReadinessClaim = $false
    target = "win32-x64"
    mode = "candidate-seal"
    artifacts = [pscustomobject]@{
      vsix = [pscustomobject]@{
        path = $vsix.path
        relativePath = $vsix.relativePath
        size = $vsix.size
        sha256 = $vsix.sha256
        evidencePath = Convert-ToRepoRelativePath $vsixEvidencePath
        evidenceSha256 = Get-Sha256 $vsixEvidencePath
      }
    }
    evidence = [pscustomobject]@{
      vsixPackage = [pscustomobject]@{
        path = Convert-ToRepoRelativePath $vsixEvidencePath
        sha256 = Get-Sha256 $vsixEvidencePath
        schema = "subversionr.release.vsix-package.win32-x64.v1"
      }
      candidateAttestationContract = [pscustomobject]@{
        path = Convert-ToRepoRelativePath $candidateAttestationContractPath
        sha256 = Get-Sha256 $candidateAttestationContractPath
        schema = "subversionr.release.github-attestation-contract.win32-x64.v1"
      }
      liveAttestation = New-HashRecord $liveAttestationPath
      attestationBundle = New-HashRecord $attestationBundlePath
      attestationVerification = New-HashRecord $attestationVerificationPath
    }
    attestation = [pscustomobject]@{
      status = "verified"
      scope = "historical-public-cutover-release"
      readiness = [pscustomobject]@{
        readinessStatus = "live-attestation-verified"
        action = "actions/attest@v4"
        actionDigest = "a1948c3f048ba23858d222213b7c278aabede763"
        predicateClaim = "post-release-asset-digest-verification"
        originalBuildProvenanceClaim = $false
        artifactSignatureClaim = $false
        workflowPath = ".github/workflows/attest-release-vsix.yml"
        subjectName = "subversionr-win32-x64-0.2.0.vsix"
        subjectSha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
        artifactPath = "target/release-attestation/win32-x64/subversionr-win32-x64-0.2.0.vsix"
        artifactSize = 12
        repoUrlRecorded = $true
        bundleRecorded = $true
        attestationUrlRecorded = $true
        verified = $true
        runUrl = "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/29104476735"
        attestationUrl = "https://github.com/Hitsuki-Ban/SubversionR/attestations/34774737"
        bundlePath = Convert-ToRepoRelativePath $attestationBundlePath
        bundleSha256 = Get-Sha256 $attestationBundlePath
        verificationResultPath = Convert-ToRepoRelativePath $attestationVerificationPath
        verificationResultSha256 = Get-Sha256 $attestationVerificationPath
        sourceRef = "refs/heads/main"
        sourceDigest = "720c92c3f1747a7e7dcf6143f2bf47171cfd9051"
        signerDigest = "720c92c3f1747a7e7dcf6143f2bf47171cfd9051"
        evidencePath = Convert-ToRepoRelativePath $liveAttestationPath
        evidenceSha256 = Get-Sha256 $liveAttestationPath
      }
    }
    candidateAttestation = [pscustomobject]@{
      status = "pending-release-attestation"
      scope = "current-candidate"
      contractPath = Convert-ToRepoRelativePath $candidateAttestationContractPath
      contractSha256 = Get-Sha256 $candidateAttestationContractPath
      releaseTag = "v0.2.5-beta.1"
      releaseUrl = "https://github.com/Hitsuki-Ban/SubversionR/releases/tag/v0.2.5-beta.1"
      subjectName = Split-Path -Leaf $vsix.path
      subjectSha256 = $vsix.sha256
      subjectSize = $vsix.size
      subjectComparison = "asserted-exact-match"
      preReleaseProperty = $true
      liveEvidenceRecorded = $false
    }
  })

  Write-Json (New-EvidencePath $evidenceRoot "publication-gaps") ([pscustomobject]@{
    schemaVersion = 1
    schema = "subversionr.release.publication-gaps.win32-x64.v1"
    publicReadinessClaim = $false
    target = "win32-x64"
    currentCandidate = [pscustomobject]@{
      status = "pending-release-attestation"
      scope = "current-candidate"
      contractPath = Convert-ToRepoRelativePath $candidateAttestationContractPath
      contractSha256 = Get-Sha256 $candidateAttestationContractPath
      releaseTag = "v0.2.5-beta.1"
      releaseUrl = "https://github.com/Hitsuki-Ban/SubversionR/releases/tag/v0.2.5-beta.1"
      subjectName = Split-Path -Leaf $vsix.path
      subjectSha256 = $vsix.sha256
      subjectSize = $vsix.size
      preReleaseProperty = $true
      liveEvidenceRecorded = $false
    }
    publicCutover = [pscustomobject]@{
      release = [pscustomobject]@{
        artifactAttestationPublished = $true
        attestationRunUrl = "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/29104476735"
        attestationUrl = "https://github.com/Hitsuki-Ban/SubversionR/attestations/34774737"
        attestationEvidencePath = Convert-ToRepoRelativePath $liveAttestationPath
        attestationEvidenceSha256 = Get-Sha256 $liveAttestationPath
      }
    }
    artifacts = [pscustomobject]@{
      vsix = [pscustomobject]@{
        path = $vsix.path
        relativePath = $vsix.relativePath
        size = $vsix.size
        sha256 = $vsix.sha256
      }
    }
    evidence = [pscustomobject]@{
      provenancePreflight = [pscustomobject]@{
        path = Convert-ToRepoRelativePath $provenancePath
        sha256 = Get-Sha256 $provenancePath
        schema = "subversionr.release.marketplace-provenance-preflight.win32-x64.v1"
      }
      vsixPackage = [pscustomobject]@{
        path = Convert-ToRepoRelativePath $vsixEvidencePath
        sha256 = Get-Sha256 $vsixEvidencePath
        schema = "subversionr.release.vsix-package.win32-x64.v1"
      }
    }
  })

  Write-Json (New-EvidencePath $evidenceRoot "state-engine-beta-performance") ([pscustomobject]@{
    schemaVersion = 1
    schema = "subversionr.release.state-engine-beta-performance.win32-x64.v1"
    publicReadinessClaim = $false
    target = "win32-x64"
    traceIds = @("ARC-011", "DIR-002", "DIR-004", "DIR-006", "DIR-007", "DIR-012", "DIR-013", "DIR-020", "OBS-004", "TST-024")
    nonClaims = @(
      "No 100k or 1M working-copy performance claim.",
      "No default background remote polling claim."
    )
    source = "packages/vscode-extension/tests/stateEngineBetaPerformanceGate.test.ts"
    workingCopyMutation = "none"
    thresholds = [pscustomobject]@{
      tenThousandLocalResourceCount = 10000
      maxProjectionMs = 10000
    }
    assertions = [pscustomobject]@{
      singleFileSaveNoFullScan = [pscustomobject]@{
        rootInfinityTargetCount = 0
        refreshRequestCount = 1
      }
      eventBurstBounded = [pscustomobject]@{
        inputEventCount = 10000
        maxRefreshTargets = 128
        actualRefreshTargets = 1
      }
      nestedExternalBoundaryIsolation = [pscustomobject]@{
        boundaryAcceptedByParent = $false
        boundaryAcceptedByChild = $true
      }
      dirtyGenerationSupersede = [pscustomobject]@{
        firstSignalAborted = $true
        staleMarkReason = "refreshCancelled"
      }
      sidecarRestartRecovery = [pscustomobject]@{
        statusCompleteness = "stale"
        reopenedCount = 1
      }
      tenThousandWorkingCopyProjection = [pscustomobject]@{
        localEntryCount = 10000
        elapsedMs = 1
        maxProjectionMs = 10000
      }
    }
  })

  $sourceSbomPath = Join-Path $evidenceRoot "subversionr-source-sbom.cdx.json"
  Write-Json $sourceSbomPath ([pscustomobject]@{
    bomFormat = "CycloneDX"
    specVersion = "1.6"
    version = 1
    metadata = [pscustomobject]@{
      component = [pscustomobject]@{
        name = "SubversionR"
        version = "0.2.5"
      }
    }
    components = @()
  })

  $noticePath = Join-Path $evidenceRoot "THIRD-PARTY-NOTICES.md"
  Set-Content -LiteralPath $noticePath -Encoding utf8 -NoNewline -Value "# Third-Party Notices`n`nFixture notices."

  $installedUiArtifactRoot = Join-Path $evidenceRoot "installed-source-control-ui-e2e\win32-x64"
  New-Item -ItemType Directory -Force -Path $installedUiArtifactRoot | Out-Null
  Write-Json (Join-Path $installedUiArtifactRoot "renderer-capture.json") ([pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eRendererCapture"
    surfaceReady = $true
  })
  Set-Content -LiteralPath (Join-Path $installedUiArtifactRoot "dom-text.txt") -Encoding utf8 -NoNewline -Value "SubversionR Source Control"
  Set-Content -LiteralPath (Join-Path $installedUiArtifactRoot "source-control.png") -Encoding utf8 -NoNewline -Value "fixture-png-bytes"
  Write-Json (Join-Path $evidenceRoot "subversionr-extra-local-debug-win32-x64.json") ([pscustomobject]@{
    schema = "subversionr.local-debug.win32-x64.v1"
    target = "win32-x64"
    publicReadinessClaim = $false
  })

  $ciWorkflowPath = Join-Path $inputRoot "ci.yml"
  $uploadPathBlock = Get-BetaArtifactBundleUploadPathBlock "            "
  Set-Content -LiteralPath $ciWorkflowPath -Encoding utf8 -NoNewline -Value @"
name: CI

on:
  workflow_dispatch:

jobs:
  windows:
    runs-on: windows-2022
    steps:
      - name: Upload Beta candidate VSIX and evidence bundle
        if: `${{ env.SUBVERSIONR_RELEASE_CI_MODE == 'candidate-seal' }}
        uses: actions/upload-artifact@v7
        with:
          name: subversionr-win32-x64-beta-candidate
          path: |
$uploadPathBlock
          if-no-files-found: error
          retention-days: 14
"@

  $artifactBundleManifestPath = New-EvidencePath $evidenceRoot "beta-artifact-bundle-manifest"
  $fixture = [pscustomobject]@{
    root = $Root
    evidenceRoot = $evidenceRoot
    outputPath = Join-Path $evidenceRoot "subversionr-beta-candidate-consistency-win32-x64.json"
    vsix = $vsix
    vsixEvidencePath = $vsixEvidencePath
    backendManifestPath = $backendManifestPath
    ciWorkflowPath = $ciWorkflowPath
    sourceSbomPath = $sourceSbomPath
    noticePath = $noticePath
    installedUiArtifactRoot = $installedUiArtifactRoot
    artifactBundleManifestPath = $artifactBundleManifestPath
    liveAttestationPath = $liveAttestationPath
    attestationBundlePath = $attestationBundlePath
    attestationVerificationPath = $attestationVerificationPath
    extraLocalDebugJsonPath = Join-Path $evidenceRoot "subversionr-extra-local-debug-win32-x64.json"
  }
  New-BetaArtifactBundleManifest $fixture

  $fixture
}

function Invoke-BetaCandidateVerifier([object]$Fixture) {
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $workflowScript `
    -Target win32-x64 `
    -VsixPath $Fixture.vsix.path `
    -VsixEvidencePath $Fixture.vsixEvidencePath `
    -CiWorkflowPath $Fixture.ciWorkflowPath `
    -ReleaseEvidenceRoot $Fixture.evidenceRoot `
    -ArtifactBundleManifestPath $Fixture.artifactBundleManifestPath `
    -OutputPath $Fixture.outputPath
}

$tempRoot = Join-Path $repoRoot "target\tests\release-beta-candidate-evidence-scripts\$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  Assert-True (Test-Path -LiteralPath $workflowScript -PathType Leaf) "verify-beta-candidate-evidence.ps1 should exist."
  Assert-True (Test-Path -LiteralPath $manifestScript -PathType Leaf) "generate-beta-artifact-bundle-manifest.ps1 should exist."
  Assert-True (Test-Path -LiteralPath $orchestrationScript -PathType Leaf) "run-beta-candidate-evidence.ps1 should exist."

  $fixture = New-BetaCandidateFixture (Join-Path $tempRoot "positive")
  Invoke-BetaCandidateVerifier $fixture
  if ($LASTEXITCODE -ne 0) {
    throw "verify-beta-candidate-evidence.ps1 failed with exit code $LASTEXITCODE."
  }

  $report = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  Assert-Equal "subversionr.release.beta-candidate-consistency.win32-x64.v1" $report.schema "Beta candidate consistency report should use the Beta-G schema."
  Assert-Equal "False" ([string]$report.publicReadinessClaim) "Beta candidate consistency report must not claim public readiness."
  Assert-Equal "win32-x64" $report.target "Beta candidate consistency report should record the target."
  Assert-Equal $fixture.vsix.sha256 $report.vsix.sha256 "Beta candidate consistency report should bind to current VSIX bytes."
  Assert-Equal "True" ([string]$report.vsix.preRelease) "Beta candidate consistency report should require the packaged pre-release property."
  Assert-True (@($report.requiredEvidenceFiles).Count -eq 12) "Beta candidate consistency report should verify all required Beta package evidence files."
  Assert-Equal "actions/upload-artifact@v7" $report.artifactBundle.uploadAction "Beta candidate consistency report should bind the upload action."
  Assert-Equal "subversionr-win32-x64-beta-candidate" $report.artifactBundle.name "Beta candidate consistency report should bind the upload artifact name."
  Assert-Equal "`${{ env.SUBVERSIONR_RELEASE_CI_MODE == 'candidate-seal' }}" $report.artifactBundle.condition "Beta candidate consistency report should bind the explicit candidate-seal upload condition."
  Assert-Equal "error" $report.artifactBundle.ifNoFilesFound "Beta candidate consistency report should bind upload missing-file behavior."
  Assert-Equal "14" ([string]$report.artifactBundle.retentionDays) "Beta candidate consistency report should bind artifact retention."
  Assert-Equal "False" ([string]$report.artifactBundle.includeHiddenFiles) "Beta candidate consistency report should not include hidden files in the bundle."
  Assert-Equal (Convert-ToRepoRelativePath $fixture.ciWorkflowPath) $report.artifactBundle.ciWorkflow.path "Beta candidate consistency report should bind the CI workflow upload contract path."
  Assert-Equal (Get-Sha256 $fixture.ciWorkflowPath) $report.artifactBundle.ciWorkflow.sha256 "Beta candidate consistency report should bind the CI workflow upload contract SHA256."
  Assert-True (@($report.hashBindings | Where-Object { $_.name -eq "ciWorkflow" -and $_.relativePath -eq (Convert-ToRepoRelativePath $fixture.ciWorkflowPath) -and $_.sha256 -eq (Get-Sha256 $fixture.ciWorkflowPath) }).Count -eq 1) "Beta candidate consistency report should include the CI workflow hash binding."
  Assert-Equal ((Get-BetaArtifactBundleUploadPaths) -join "|") (@($report.artifactBundle.paths) -join "|") "Beta candidate consistency report should bind the exact ordered upload path list."
  Assert-True (@($report.artifactBundle.paths | Where-Object { [string]$_ -eq "target/release-evidence/*.json" }).Count -eq 0) "Beta candidate consistency report should reject broad release evidence JSON globs in the upload bundle."
  Assert-True (@($report.artifactBundle.paths | Where-Object { [string]$_ -eq "target/release-evidence/subversionr-beta-artifact-bundle-manifest-win32-x64.json" }).Count -eq 1) "Beta candidate consistency report should include the artifact bundle manifest in the upload contract."
  Assert-True (@($report.artifactBundle.paths | Where-Object { [string]$_ -eq "target/release-evidence/subversionr-beta-candidate-consistency-win32-x64.json" }).Count -eq 1) "Beta candidate consistency report should include the final consistency report in the upload contract."
  Assert-True (@($report.artifactBundle.paths | Where-Object { [string]$_ -eq "target/release-evidence/installed-source-control-ui-e2e/win32-x64/**/*.png" }).Count -eq 1) "Beta candidate consistency report should include installed renderer screenshots in the upload bundle."
  Assert-Equal (Convert-ToRepoRelativePath $fixture.artifactBundleManifestPath) $report.artifactBundle.manifest.relativePath "Beta candidate consistency report should bind the artifact bundle manifest path."
  Assert-Equal (Get-Sha256 $fixture.artifactBundleManifestPath) $report.artifactBundle.manifest.sha256 "Beta candidate consistency report should bind the artifact bundle manifest SHA256."
  Assert-Equal "subversionr.release.beta-artifact-bundle-manifest.win32-x64.v1" $report.artifactBundle.manifest.schema "Beta candidate consistency report should bind the artifact bundle manifest schema."
  $artifactBundleManifest = Get-Content -Raw -LiteralPath $fixture.artifactBundleManifestPath | ConvertFrom-Json
  Assert-Equal "candidate-seal" $artifactBundleManifest.candidateSeal.mode "Beta artifact bundle manifest should require candidate-seal provenance."
  Assert-Equal "asserted-exact-match" $artifactBundleManifest.candidateSeal.subjectComparison "Beta artifact bundle manifest should require exact frozen-contract subject comparison."
  Assert-Equal (Convert-ToRepoRelativePath (New-EvidencePath $fixture.evidenceRoot "marketplace-provenance-preflight")) $artifactBundleManifest.candidateSeal.provenancePath "Beta artifact bundle manifest should bind the sealed provenance path."
  Assert-True (@($report.hashBindings | Where-Object { $_.name -eq "artifactBundleManifest" -and $_.relativePath -eq (Convert-ToRepoRelativePath $fixture.artifactBundleManifestPath) -and $_.sha256 -eq (Get-Sha256 $fixture.artifactBundleManifestPath) }).Count -eq 1) "Beta candidate consistency report should include the artifact bundle manifest hash binding."
  Assert-True (@($report.requiredEvidenceFiles | Where-Object { $_.name -eq "artifactBundleManifest" }).Count -eq 1) "Beta candidate consistency report should list the artifact bundle manifest as required evidence."
  $manifestFilePaths = @($report.artifactBundle.manifest.files | ForEach-Object { [string]$_.relativePath })
  Assert-True ($manifestFilePaths -contains $fixture.vsix.relativePath) "Artifact bundle manifest should bind the current VSIX bytes."
  Assert-True ($manifestFilePaths -contains (Convert-ToRepoRelativePath $fixture.sourceSbomPath)) "Artifact bundle manifest should bind source SBOM bytes."
  Assert-True ($manifestFilePaths -contains (Convert-ToRepoRelativePath $fixture.noticePath)) "Artifact bundle manifest should bind third-party notice bytes."
  Assert-True ($manifestFilePaths -contains (Convert-ToRepoRelativePath (Join-Path $fixture.installedUiArtifactRoot "renderer-capture.json"))) "Artifact bundle manifest should bind installed renderer JSON artifacts."
  Assert-True ($manifestFilePaths -contains (Convert-ToRepoRelativePath (Join-Path $fixture.installedUiArtifactRoot "source-control.png"))) "Artifact bundle manifest should bind installed renderer screenshot artifacts."
  Assert-True ($manifestFilePaths -notcontains (Convert-ToRepoRelativePath $fixture.extraLocalDebugJsonPath)) "Artifact bundle manifest should exclude extra local debug JSON evidence."
  Assert-True ($manifestFilePaths -notcontains (Convert-ToRepoRelativePath $fixture.artifactBundleManifestPath)) "Artifact bundle manifest should not self-hash."
  Assert-True ($manifestFilePaths -notcontains (Convert-ToRepoRelativePath $fixture.outputPath)) "Artifact bundle manifest should not include the final consistency report before it exists."
  Assert-True (@($report.nonClaims | Where-Object { [string]$_ -like "*Marketplace/public install*" }).Count -gt 0) "Beta candidate consistency report should keep public install non-claims explicit."
  Assert-True (@($report.assertions | Where-Object { [string]$_ -like "*pending current-candidate attestation contract*" }).Count -eq 1) "Beta candidate consistency report should distinguish the pending current candidate from historical attestation evidence."
  Assert-True (@($report.nonClaims | Where-Object { [string]$_ -like "*current-candidate release or live GitHub attestation*" }).Count -eq 1) "Beta candidate consistency report should retain the current-candidate attestation non-claim."
  Assert-True (@($report.nonClaims | Where-Object { [string]$_ -like "*artifact attestation generation*" }).Count -eq 0) "Beta candidate consistency report should not retain the obsolete live attestation non-claim."

  $continuousManifestFixture = New-BetaCandidateFixture (Join-Path $tempRoot "continuous-manifest")
  $continuousManifestProvenancePath = New-EvidencePath $continuousManifestFixture.evidenceRoot "marketplace-provenance-preflight"
  $continuousManifestProvenance = Get-Content -Raw -LiteralPath $continuousManifestProvenancePath | ConvertFrom-Json
  $continuousManifestProvenance.mode = "continuous-validation"
  $continuousManifestProvenance.candidateAttestation.subjectComparison = "not-asserted-continuous-validation"
  Write-Json $continuousManifestProvenancePath $continuousManifestProvenance
  Assert-NativeCommandFailsContaining {
    Invoke-BetaArtifactBundleManifest $continuousManifestFixture
  } "requires candidate-seal provenance mode" "Continuous validation must not generate a Beta candidate artifact bundle manifest."

  $continuousVerifierFixture = New-BetaCandidateFixture (Join-Path $tempRoot "continuous-verifier")
  $continuousVerifierProvenancePath = New-EvidencePath $continuousVerifierFixture.evidenceRoot "marketplace-provenance-preflight"
  $continuousVerifierProvenance = Get-Content -Raw -LiteralPath $continuousVerifierProvenancePath | ConvertFrom-Json
  $continuousVerifierProvenance.mode = "continuous-validation"
  $continuousVerifierProvenance.candidateAttestation.subjectComparison = "not-asserted-continuous-validation"
  Write-Json $continuousVerifierProvenancePath $continuousVerifierProvenance
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $continuousVerifierFixture
  } "requires candidate-seal provenance mode" "Continuous validation must not verify a Beta candidate consistency report."

  $unsealedComparisonFixture = New-BetaCandidateFixture (Join-Path $tempRoot "unsealed-subject-comparison")
  $unsealedComparisonPath = New-EvidencePath $unsealedComparisonFixture.evidenceRoot "marketplace-provenance-preflight"
  $unsealedComparison = Get-Content -Raw -LiteralPath $unsealedComparisonPath | ConvertFrom-Json
  $unsealedComparison.candidateAttestation.subjectComparison = "not-asserted-continuous-validation"
  Write-Json $unsealedComparisonPath $unsealedComparison
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $unsealedComparisonFixture
  } "requires an exact frozen-contract subject comparison" "Beta candidate consistency must reject provenance that did not assert the frozen subject match."

  $staleAttestationBundleFixture = New-BetaCandidateFixture (Join-Path $tempRoot "stale-attestation-bundle")
  Add-Content -LiteralPath $staleAttestationBundleFixture.attestationBundlePath -Encoding utf8 -NoNewline -Value " "
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $staleAttestationBundleFixture
  } "marketplaceProvenance attestationBundle SHA256 must match current file" "Beta candidate consistency should reject changed attestation bundle bytes."

  $staleAttestationFixture = New-BetaCandidateFixture (Join-Path $tempRoot "stale-attestation")
  $staleAttestationPath = New-EvidencePath $staleAttestationFixture.evidenceRoot "marketplace-provenance-preflight"
  $staleAttestation = Get-Content -Raw -LiteralPath $staleAttestationPath | ConvertFrom-Json
  $staleAttestation.attestation.readiness.readinessStatus = "input-contract-ready"
  Write-Json $staleAttestationPath $staleAttestation
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $staleAttestationFixture
  } "live verification" "Beta candidate consistency should reject obsolete input-only attestation evidence."

  $missingPublishedAttestationFixture = New-BetaCandidateFixture (Join-Path $tempRoot "missing-published-attestation")
  $missingPublishedAttestationPath = New-EvidencePath $missingPublishedAttestationFixture.evidenceRoot "publication-gaps"
  $missingPublishedAttestation = Get-Content -Raw -LiteralPath $missingPublishedAttestationPath | ConvertFrom-Json
  $missingPublishedAttestation.publicCutover.release.artifactAttestationPublished = $false
  Write-Json $missingPublishedAttestationPath $missingPublishedAttestation
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $missingPublishedAttestationFixture
  } "must be true" "Beta candidate consistency should require publication gaps to record the live attestation."

  $quotedUploadFixture = New-BetaCandidateFixture (Join-Path $tempRoot "quoted-upload-step")
  $quotedUploadCiWorkflow = Get-Content -Raw -LiteralPath $quotedUploadFixture.ciWorkflowPath
  $quotedUploadCiWorkflow = $quotedUploadCiWorkflow.Replace("- name: Upload Beta candidate VSIX and evidence bundle", '- "name": Upload Beta candidate VSIX and evidence bundle')
  $quotedUploadCiWorkflow = $quotedUploadCiWorkflow.Replace("        uses: actions/upload-artifact@v7", '        "uses": actions/upload-artifact@v7')
  $quotedUploadCiWorkflow = $quotedUploadCiWorkflow.Replace("        with:", '        "with":')
  $quotedUploadCiWorkflow = $quotedUploadCiWorkflow.Replace("          name: subversionr-win32-x64-beta-candidate", '          "name": subversionr-win32-x64-beta-candidate')
  $quotedUploadCiWorkflow = $quotedUploadCiWorkflow.Replace("          path: |", '          "path": |')
  $quotedUploadCiWorkflow = $quotedUploadCiWorkflow.Replace("          if-no-files-found: error", '          "if-no-files-found": error')
  $quotedUploadCiWorkflow = $quotedUploadCiWorkflow.Replace("          retention-days: 14", '          "retention-days": 14')
  Set-Content -LiteralPath $quotedUploadFixture.ciWorkflowPath -Encoding utf8 -NoNewline -Value $quotedUploadCiWorkflow
  Invoke-BetaCandidateVerifier $quotedUploadFixture
  if ($LASTEXITCODE -ne 0) {
    throw "verify-beta-candidate-evidence.ps1 should accept quoted upload step keys, got exit code $LASTEXITCODE."
  }

  $staleSbomManifestFixture = New-BetaCandidateFixture (Join-Path $tempRoot "stale-sbom-manifest")
  $staleSbomText = (Get-Content -Raw -LiteralPath $staleSbomManifestFixture.sourceSbomPath).Replace("SubversionR", "SubversionS")
  Set-Content -LiteralPath $staleSbomManifestFixture.sourceSbomPath -Encoding utf8 -NoNewline -Value $staleSbomText
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $staleSbomManifestFixture
  } "artifactBundleManifest file SHA256 must match the current Beta bundle payload" "Beta candidate consistency should reject stale artifact bundle manifest hashes for source SBOM payloads."

  $staleRendererManifestFixture = New-BetaCandidateFixture (Join-Path $tempRoot "stale-renderer-manifest")
  Set-Content -LiteralPath (Join-Path $staleRendererManifestFixture.installedUiArtifactRoot "dom-text.txt") -Encoding utf8 -NoNewline -Value "SubversionS Source Control"
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $staleRendererManifestFixture
  } "artifactBundleManifest file SHA256 must match the current Beta bundle payload" "Beta candidate consistency should reject stale artifact bundle manifest hashes for renderer payloads."

  $missingManifestFixture = New-BetaCandidateFixture (Join-Path $tempRoot "missing-artifact-bundle-manifest")
  Remove-Item -LiteralPath $missingManifestFixture.artifactBundleManifestPath -Force
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $missingManifestFixture
  } "ArtifactBundleManifestPath must be a file" "Beta candidate consistency should reject missing artifact bundle manifests."

  $staleVsixFixture = New-BetaCandidateFixture (Join-Path $tempRoot "stale-vsix")
  $installedCorePath = New-EvidencePath $staleVsixFixture.evidenceRoot "installed-core-workflow"
  $installedCore = Get-Content -Raw -LiteralPath $installedCorePath | ConvertFrom-Json
  $installedCore.vsix.sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
  Write-Json $installedCorePath $installedCore
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $staleVsixFixture
  } "installedCoreWorkflow VSIX SHA256 must match current VSIX" "Beta candidate consistency should reject stale installed VSIX evidence."

  foreach ($case in @(
    @{ Name = "stale-packaged-backend-version"; Property = "backendVersion"; Value = "0.2.4"; Expected = "vsixPackage native compatibility backendVersion must match current VSIX package.json" },
    @{ Name = "stale-packaged-bridge-version"; Property = "bridgeVersion"; Value = "subversionr-svn-bridge/0.2.4"; Expected = "vsixPackage native compatibility bridgeVersion must match current VSIX package.json" },
    @{ Name = "case-drift-packaged-bridge-version"; Property = "bridgeVersion"; Value = "SubversionR-svn-bridge/0.2.5"; Expected = "vsixPackage native compatibility bridgeVersion must match current VSIX package.json" }
  )) {
    $fixture = New-BetaCandidateFixture (Join-Path $tempRoot $case.Name)
    $path = New-EvidencePath $fixture.evidenceRoot "vsix-package"
    $evidence = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    $evidence.nativeCompatibility.($case.Property) = $case.Value
    Write-Json $path $evidence
    Assert-NativeCommandFailsContaining {
      Invoke-BetaCandidateVerifier $fixture
    } $case.Expected "Beta candidate consistency should reject stale packaged native $($case.Property) evidence."
  }

  foreach ($case in @(
    @{ Name = "stale-installed-backend-version"; Property = "backendVersion"; Value = "0.2.4"; Expected = "installedCoreWorkflow version report backendVersion must match current VSIX package.json" },
    @{ Name = "stale-installed-bridge-version"; Property = "bridgeVersion"; Value = "subversionr-svn-bridge/0.2.4"; Expected = "installedCoreWorkflow version report bridgeVersion must match current VSIX package.json" },
    @{ Name = "case-drift-installed-bridge-version"; Property = "bridgeVersion"; Value = "SubversionR-svn-bridge/0.2.5"; Expected = "installedCoreWorkflow version report bridgeVersion must match current VSIX package.json" }
  )) {
    $fixture = New-BetaCandidateFixture (Join-Path $tempRoot $case.Name)
    $path = New-EvidencePath $fixture.evidenceRoot "installed-core-workflow"
    $evidence = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    $evidence.versionReport.backend.($case.Property) = $case.Value
    Write-Json $path $evidence
    Assert-NativeCommandFailsContaining {
      Invoke-BetaCandidateVerifier $fixture
    } $case.Expected "Beta candidate consistency should reject stale installed native $($case.Property) evidence."
  }

  $staleCliVsixFixture = New-BetaCandidateFixture (Join-Path $tempRoot "stale-cli-vsix")
  $cliInstallPath = New-EvidencePath $staleCliVsixFixture.evidenceRoot "vsix-cli-install"
  $cliInstall = Get-Content -Raw -LiteralPath $cliInstallPath | ConvertFrom-Json
  $cliInstall.vsix.sha256 = "1111111111111111111111111111111111111111111111111111111111111111"
  Write-Json $cliInstallPath $cliInstall
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $staleCliVsixFixture
  } "vsixCliInstall VSIX SHA256 must match current VSIX" "Beta candidate consistency should reject stale CLI install VSIX evidence."

  $staleCliPathFixture = New-BetaCandidateFixture (Join-Path $tempRoot "stale-cli-path")
  $cliInstallPathEvidence = New-EvidencePath $staleCliPathFixture.evidenceRoot "vsix-cli-install"
  $cliInstallWithWrongPath = Get-Content -Raw -LiteralPath $cliInstallPathEvidence | ConvertFrom-Json
  $cliInstallWithWrongPath.vsix.path = "target/vsix/not-this-candidate.vsix"
  Write-Json $cliInstallPathEvidence $cliInstallWithWrongPath
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $staleCliPathFixture
  } "vsixCliInstall VSIX path must match current VSIX" "Beta candidate consistency should reject stale CLI install VSIX path evidence."

  $missingEvidenceFixture = New-BetaCandidateFixture (Join-Path $tempRoot "missing-evidence")
  Remove-Item -LiteralPath (New-EvidencePath $missingEvidenceFixture.evidenceRoot "state-engine-beta-performance") -Force
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $missingEvidenceFixture
  } "Missing required evidence file" "Beta candidate consistency should reject missing required evidence."

  $missingInstalledWorkflowFixture = New-BetaCandidateFixture (Join-Path $tempRoot "missing-installed-workflow")
  $installedUiPath = New-EvidencePath $missingInstalledWorkflowFixture.evidenceRoot "installed-source-control-ui-e2e"
  $installedUi = Get-Content -Raw -LiteralPath $installedUiPath | ConvertFrom-Json
  $installedUi.PSObject.Properties.Remove("sourceControlUiCheckoutWorkflow")
  Write-Json $installedUiPath $installedUi
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $missingInstalledWorkflowFixture
  } "installedSourceControlUiE2e must define sourceControlUiCheckoutWorkflow" "Beta candidate consistency should reject installed UI E2E evidence missing the Checkout workflow."

  $missingTrustedProfileFixture = New-BetaCandidateFixture (Join-Path $tempRoot "missing-trusted-profile")
  $missingTrustedProfilePath = New-EvidencePath $missingTrustedProfileFixture.evidenceRoot "installed-source-control-ui-e2e"
  $missingTrustedProfile = Get-Content -Raw -LiteralPath $missingTrustedProfilePath | ConvertFrom-Json
  $missingTrustedProfile.PSObject.Properties.Remove("trustedProfile")
  Write-Json $missingTrustedProfilePath $missingTrustedProfile
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $missingTrustedProfileFixture
  } "installedSourceControlUiE2e must define trustedProfile" "Beta candidate consistency should reject installed UI E2E evidence missing the trusted profile proof."

  foreach ($case in @(
    @{ Name = "extension-host-untrusted"; Property = "extensionHostTrusted" },
    @{ Name = "open-report-untrusted"; Property = "openReportTrusted" }
  )) {
    $untrustedProfileFixture = New-BetaCandidateFixture (Join-Path $tempRoot $case.Name)
    $untrustedProfilePath = New-EvidencePath $untrustedProfileFixture.evidenceRoot "installed-source-control-ui-e2e"
    $untrustedProfile = Get-Content -Raw -LiteralPath $untrustedProfilePath | ConvertFrom-Json
    $untrustedProfile.trustedProfile.($case.Property) = $false
    Write-Json $untrustedProfilePath $untrustedProfile
    Assert-NativeCommandFailsContaining {
      Invoke-BetaCandidateVerifier $untrustedProfileFixture
    } "$($case.Property) must be true" "Beta candidate consistency should reject installed UI E2E evidence where $($case.Property) is false."
  }

  $stringTrustedProfileFixture = New-BetaCandidateFixture (Join-Path $tempRoot "string-trusted-profile")
  $stringTrustedProfilePath = New-EvidencePath $stringTrustedProfileFixture.evidenceRoot "installed-source-control-ui-e2e"
  $stringTrustedProfile = Get-Content -Raw -LiteralPath $stringTrustedProfilePath | ConvertFrom-Json
  $stringTrustedProfile.trustedProfile.extensionHostTrusted = "True"
  Write-Json $stringTrustedProfilePath $stringTrustedProfile
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $stringTrustedProfileFixture
  } "extensionHostTrusted must be a JSON boolean" "Beta candidate consistency should reject stringified trusted profile proof."

  $staleInstalledOracleFixture = New-BetaCandidateFixture (Join-Path $tempRoot "stale-installed-oracle")
  $staleInstalledOraclePath = New-EvidencePath $staleInstalledOracleFixture.evidenceRoot "installed-source-control-ui-e2e"
  $staleInstalledOracle = Get-Content -Raw -LiteralPath $staleInstalledOraclePath | ConvertFrom-Json
  $staleInstalledOracle.branchCreateRepositoryOracle.kind = "fixture-oracle"
  Write-Json $staleInstalledOraclePath $staleInstalledOracle
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $staleInstalledOracleFixture
  } "installedSourceControlUiE2e branchCreateRepositoryOracle kind must match the installed oracle evidence contract" "Beta candidate consistency should reject installed UI E2E evidence with stale oracle kinds."

  $checkoutCancellationDriftFixture = New-BetaCandidateFixture (Join-Path $tempRoot "checkout-cancellation-drift")
  $checkoutCancellationDriftPath = New-EvidencePath $checkoutCancellationDriftFixture.evidenceRoot "installed-source-control-ui-e2e"
  $checkoutCancellationDrift = Get-Content -Raw -LiteralPath $checkoutCancellationDriftPath | ConvertFrom-Json
  $checkoutCancellationDrift.sourceControlUiCheckoutCancellationWorkflow.assertions.targetAbsentAfter = $false
  Write-Json $checkoutCancellationDriftPath $checkoutCancellationDrift
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $checkoutCancellationDriftFixture
  } "targetAbsentAfter" "Beta candidate consistency should reject Checkout cancellation evidence that no longer proves no-state-pollution."

  $checkoutFailureCodeDriftFixture = New-BetaCandidateFixture (Join-Path $tempRoot "checkout-failure-code-drift")
  $checkoutFailureCodeDriftPath = New-EvidencePath $checkoutFailureCodeDriftFixture.evidenceRoot "installed-source-control-ui-e2e"
  $checkoutFailureCodeDrift = Get-Content -Raw -LiteralPath $checkoutFailureCodeDriftPath | ConvertFrom-Json
  $checkoutFailureCodeDrift.sourceControlUiCheckoutExistingTargetFailureWorkflow.failure.code = "SUBVERSIONR_UNKNOWN"
  Write-Json $checkoutFailureCodeDriftPath $checkoutFailureCodeDrift
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $checkoutFailureCodeDriftFixture
  } "SVN_REPOSITORY_CHECKOUT_FAILED" "Beta candidate consistency should reject Checkout failure evidence with a stale failure code."

  $historyStaleCodeDriftFixture = New-BetaCandidateFixture (Join-Path $tempRoot "history-stale-code-drift")
  $historyStaleCodeDriftPath = New-EvidencePath $historyStaleCodeDriftFixture.evidenceRoot "installed-source-control-ui-e2e"
  $historyStaleCodeDrift = Get-Content -Raw -LiteralPath $historyStaleCodeDriftPath | ConvertFrom-Json
  $historyStaleCodeDrift.sourceControlUiRepositoryHistoryWorkflow.staleReport.diagnostics.latestHistoryTargetingError.code = "SUBVERSIONR_UNKNOWN"
  Write-Json $historyStaleCodeDriftPath $historyStaleCodeDrift
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $historyStaleCodeDriftFixture
  } "SUBVERSIONR_HISTORY_REPOSITORY_SESSION_STALE" "Beta candidate consistency should reject Repository Log evidence with a stale targeting error code."

  $historyFocusDriftFixture = New-BetaCandidateFixture (Join-Path $tempRoot "history-focus-drift")
  $historyFocusDriftPath = New-EvidencePath $historyFocusDriftFixture.evidenceRoot "installed-source-control-ui-e2e"
  $historyFocusDrift = Get-Content -Raw -LiteralPath $historyFocusDriftPath | ConvertFrom-Json
  $historyFocusDrift.repositoryHistoryLoadedRendererCapture.assertions.treeViewFocused = $false
  Write-Json $historyFocusDriftPath $historyFocusDrift
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $historyFocusDriftFixture
  } "treeViewFocused" "Beta candidate consistency should reject Repository Log renderer evidence without History view focus."

  $historyInitialExpandedDriftFixture = New-BetaCandidateFixture (Join-Path $tempRoot "history-initial-expanded-drift")
  $historyInitialExpandedDriftPath = New-EvidencePath $historyInitialExpandedDriftFixture.evidenceRoot "installed-source-control-ui-e2e"
  $historyInitialExpandedDrift = Get-Content -Raw -LiteralPath $historyInitialExpandedDriftPath | ConvertFrom-Json
  $historyInitialExpandedDrift.repositoryHistoryInitialRendererCapture.interaction.expanded = $true
  Write-Json $historyInitialExpandedDriftPath $historyInitialExpandedDrift
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $historyInitialExpandedDriftFixture
  } "expanded must remain false" "Beta candidate consistency should reject a derived initial-collapse assertion backed by an expanded TreeView interaction."

  $historyLoadedSelectionDriftFixture = New-BetaCandidateFixture (Join-Path $tempRoot "history-loaded-selection-drift")
  $historyLoadedSelectionDriftPath = New-EvidencePath $historyLoadedSelectionDriftFixture.evidenceRoot "installed-source-control-ui-e2e"
  $historyLoadedSelectionDrift = Get-Content -Raw -LiteralPath $historyLoadedSelectionDriftPath | ConvertFrom-Json
  $historyLoadedSelectionDrift.repositoryHistoryLoadedRendererCapture.interaction.selectedRowTexts = @()
  Write-Json $historyLoadedSelectionDriftPath $historyLoadedSelectionDrift
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $historyLoadedSelectionDriftFixture
  } "non-empty selectedRowTexts string values" "Beta candidate consistency should reject a derived loaded-selection assertion without an actual selected row."

  $historyRemotePollDriftFixture = New-BetaCandidateFixture (Join-Path $tempRoot "history-remote-poll-drift")
  $historyRemotePollDriftPath = New-EvidencePath $historyRemotePollDriftFixture.evidenceRoot "installed-source-control-ui-e2e"
  $historyRemotePollDrift = Get-Content -Raw -LiteralPath $historyRemotePollDriftPath | ConvertFrom-Json
  $historyRemotePollDrift.sourceControlUiRepositoryHistoryWorkflow.assertions.remoteStatusPollingNotRequested = $false
  Write-Json $historyRemotePollDriftPath $historyRemotePollDrift
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $historyRemotePollDriftFixture
  } "remoteStatusPollingNotRequested" "Beta candidate consistency should reject Repository Log evidence that no longer proves remote polling stayed idle."

  $updateCancellationDriftFixture = New-BetaCandidateFixture (Join-Path $tempRoot "update-cancellation-drift")
  $updateCancellationDriftPath = New-EvidencePath $updateCancellationDriftFixture.evidenceRoot "installed-source-control-ui-e2e"
  $updateCancellationDrift = Get-Content -Raw -LiteralPath $updateCancellationDriftPath | ConvertFrom-Json
  $updateCancellationDrift.sourceControlUiUpdateToRevisionCancellationWorkflow.assertions.sourceControlProjectionUnchanged = $false
  Write-Json $updateCancellationDriftPath $updateCancellationDrift
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $updateCancellationDriftFixture
  } "sourceControlProjectionUnchanged" "Beta candidate consistency should reject Update cancellation evidence that no longer proves projection stability."

  $lockCancellationDriftFixture = New-BetaCandidateFixture (Join-Path $tempRoot "lock-cancellation-drift")
  $lockCancellationDriftPath = New-EvidencePath $lockCancellationDriftFixture.evidenceRoot "installed-source-control-ui-e2e"
  $lockCancellationDrift = Get-Content -Raw -LiteralPath $lockCancellationDriftPath | ConvertFrom-Json
  $lockCancellationDrift.sourceControlUiLockMessageCancellationWorkflow.assertions.sourceControlProjectionUnchanged = $false
  Write-Json $lockCancellationDriftPath $lockCancellationDrift
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $lockCancellationDriftFixture
  } "sourceControlProjectionUnchanged" "Beta candidate consistency should reject Lock cancellation evidence that no longer proves projection stability."

  $addToIgnoreOracleDriftFixture = New-BetaCandidateFixture (Join-Path $tempRoot "add-to-ignore-oracle-drift")
  $addToIgnoreOracleDriftPath = New-EvidencePath $addToIgnoreOracleDriftFixture.evidenceRoot "installed-source-control-ui-e2e"
  $addToIgnoreOracleDrift = Get-Content -Raw -LiteralPath $addToIgnoreOracleDriftPath | ConvertFrom-Json
  $addToIgnoreOracleDrift.addToIgnoreWorkingCopyOracle.ignoredStatusPresent = $false
  Write-Json $addToIgnoreOracleDriftPath $addToIgnoreOracleDrift
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $addToIgnoreOracleDriftFixture
  } "ignored status" "Beta candidate consistency should reject Add to Ignore oracle evidence that no longer proves ignored status."

  $branchOracleDriftFixture = New-BetaCandidateFixture (Join-Path $tempRoot "branch-oracle-drift")
  $branchOracleDriftPath = New-EvidencePath $branchOracleDriftFixture.evidenceRoot "installed-source-control-ui-e2e"
  $branchOracleDrift = Get-Content -Raw -LiteralPath $branchOracleDriftPath | ConvertFrom-Json
  $branchOracleDrift.branchCreateRepositoryOracle.branchContentMatched = $false
  Write-Json $branchOracleDriftPath $branchOracleDrift
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $branchOracleDriftFixture
  } "branchContentMatched" "Beta candidate consistency should reject Branch/Tag oracle evidence that no longer proves copied repository content."

  $switchWorkflowDriftFixture = New-BetaCandidateFixture (Join-Path $tempRoot "switch-workflow-drift")
  $switchWorkflowDriftPath = New-EvidencePath $switchWorkflowDriftFixture.evidenceRoot "installed-source-control-ui-e2e"
  $switchWorkflowDrift = Get-Content -Raw -LiteralPath $switchWorkflowDriftPath | ConvertFrom-Json
  $switchWorkflowDrift.sourceControlUiSwitchWorkflow.request.depthIsSticky = $false
  Write-Json $switchWorkflowDriftPath $switchWorkflowDrift
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $switchWorkflowDriftFixture
  } "request.depthIsSticky" "Beta candidate consistency should reject Switch evidence that no longer proves sticky-depth request semantics."

  $staleStateScenarioFixture = New-BetaCandidateFixture (Join-Path $tempRoot "stale-state-scenario")
  $stateScenarioPath = New-EvidencePath $staleStateScenarioFixture.evidenceRoot "state-engine-beta-performance"
  $stateScenario = Get-Content -Raw -LiteralPath $stateScenarioPath | ConvertFrom-Json
  $stateScenario.assertions.singleFileSaveNoFullScan.rootInfinityTargetCount = 1
  Write-Json $stateScenarioPath $stateScenario
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $staleStateScenarioFixture
  } "stateEngineBetaPerformance single-file save must not trigger a root infinity full scan target" "Beta candidate consistency should reject degraded state-engine single-file save evidence."

  $staleRollbackFixture = New-BetaCandidateFixture (Join-Path $tempRoot "stale-rollback")
  $rollbackPath = New-EvidencePath $staleRollbackFixture.evidenceRoot "install-rollback-fixture"
  $rollback = Get-Content -Raw -LiteralPath $rollbackPath | ConvertFrom-Json
  $rollback.workingCopySentinel.mutation = "modified"
  Write-Json $rollbackPath $rollback
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $staleRollbackFixture
  } "installRollbackFixture working-copy sentinel mutation must remain none" "Beta candidate consistency should reject rollback fixture mutation overclaims."

  $staleRollbackManifestFixture = New-BetaCandidateFixture (Join-Path $tempRoot "stale-rollback-manifest")
  $rollbackManifestPath = New-EvidencePath $staleRollbackManifestFixture.evidenceRoot "install-rollback-fixture"
  $rollbackWithStaleManifest = Get-Content -Raw -LiteralPath $rollbackManifestPath | ConvertFrom-Json
  $rollbackWithStaleManifest.packages.current.manifestSha256 = "3333333333333333333333333333333333333333333333333333333333333333"
  Write-Json $rollbackManifestPath $rollbackWithStaleManifest
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $staleRollbackManifestFixture
  } "installRollbackFixture current package manifest SHA256 must match current VSIX package backend manifest" "Beta candidate consistency should reject stale rollback fixture package evidence."

  $publicClaimFixture = New-BetaCandidateFixture (Join-Path $tempRoot "public-claim")
  $provenancePath = New-EvidencePath $publicClaimFixture.evidenceRoot "marketplace-provenance-preflight"
  $provenance = Get-Content -Raw -LiteralPath $provenancePath | ConvertFrom-Json
  $provenance.publicReadinessClaim = $true
  Write-Json $provenancePath $provenance
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $publicClaimFixture
  } "marketplaceProvenance publicReadinessClaim must remain false" "Beta candidate consistency should reject public-readiness overclaims."

  $staleNativeInputFixture = New-BetaCandidateFixture (Join-Path $tempRoot "stale-native-input")
  Set-Content -LiteralPath $staleNativeInputFixture.backendManifestPath -Encoding utf8 -NoNewline -Value '{"artifacts":[{"path":"changed"}]}'
  $staleNativeRollbackPath = New-EvidencePath $staleNativeInputFixture.evidenceRoot "install-rollback-fixture"
  $staleNativeRollback = Get-Content -Raw -LiteralPath $staleNativeRollbackPath | ConvertFrom-Json
  $staleNativeRollback.packages.current.manifestSha256 = Get-Sha256 $staleNativeInputFixture.backendManifestPath
  Write-Json $staleNativeRollbackPath $staleNativeRollback
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $staleNativeInputFixture
  } "nativeArtifactMap input backendManifest SHA256 must match current file" "Beta candidate consistency should reject stale native artifact map input hashes."

  $missingJsonBundleFixture = New-BetaCandidateFixture (Join-Path $tempRoot "missing-json-bundle")
  $badCiWorkflow = (Get-Content -Raw -LiteralPath $missingJsonBundleFixture.ciWorkflowPath).Replace("target/release-evidence/subversionr-source-sbom.cdx.json", "target/release-evidence/subversionr-vsix-package-win32-x64.json")
  Set-Content -LiteralPath $missingJsonBundleFixture.ciWorkflowPath -Encoding utf8 -NoNewline -Value $badCiWorkflow
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $missingJsonBundleFixture
  } "CI Beta candidate artifact upload path list must match the exact ordered Beta-G bundle contract" "Beta candidate consistency should reject CI upload bundles that omit explicit release evidence JSONs."

  $reorderedBundleFixture = New-BetaCandidateFixture (Join-Path $tempRoot "reordered-upload-paths")
  $reorderedCiWorkflowLines = [System.Collections.Generic.List[string]]::new()
  $reorderedCiWorkflowLines.AddRange([string[]](Get-Content -LiteralPath $reorderedBundleFixture.ciWorkflowPath))
  $vsixLineIndex = $reorderedCiWorkflowLines.IndexOf("            target/vsix/subversionr-win32-x64-0.2.5.vsix")
  $sbomLineIndex = $reorderedCiWorkflowLines.IndexOf("            target/release-evidence/subversionr-source-sbom.cdx.json")
  Assert-True ($vsixLineIndex -ge 0 -and $sbomLineIndex -eq ($vsixLineIndex + 1)) "Reordered bundle fixture should contain adjacent VSIX and source SBOM path lines."
  $reorderedCiWorkflowLines[$vsixLineIndex] = "            target/release-evidence/subversionr-source-sbom.cdx.json"
  $reorderedCiWorkflowLines[$sbomLineIndex] = "            target/vsix/subversionr-win32-x64-0.2.5.vsix"
  Set-Content -LiteralPath $reorderedBundleFixture.ciWorkflowPath -Encoding utf8 -Value $reorderedCiWorkflowLines
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $reorderedBundleFixture
  } "CI Beta candidate artifact upload path list must match the exact ordered Beta-G bundle contract" "Beta candidate consistency should reject reordered upload path lists."

  $envOnlyUploadFixture = New-BetaCandidateFixture (Join-Path $tempRoot "env-only-upload-inputs")
  $uploadPathBlock = Get-BetaArtifactBundleUploadPathBlock "            "
  $envOnlyCiWorkflow = @"
name: CI

on:
  workflow_dispatch:

jobs:
  windows:
    runs-on: windows-2022
    steps:
      - name: Upload Beta candidate VSIX and evidence bundle
        if: `${{ env.SUBVERSIONR_RELEASE_CI_MODE == 'candidate-seal' }}
        uses: actions/upload-artifact@v7
        env:
          name: subversionr-win32-x64-beta-candidate
          if-no-files-found: error
          retention-days: 14
          path: |
$uploadPathBlock
"@
  Set-Content -LiteralPath $envOnlyUploadFixture.ciWorkflowPath -Encoding utf8 -NoNewline -Value $envOnlyCiWorkflow
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $envOnlyUploadFixture
  } "CI Beta candidate artifact upload must define a with: input block." "Beta candidate consistency should reject upload inputs outside the action with block."

  $hiddenStringUploadFixture = New-BetaCandidateFixture (Join-Path $tempRoot "hidden-string-upload")
  $hiddenStringCiWorkflow = (Get-Content -Raw -LiteralPath $hiddenStringUploadFixture.ciWorkflowPath).Replace("          retention-days: 14", "          retention-days: 14`r`n          include-hidden-files: 'true'")
  Set-Content -LiteralPath $hiddenStringUploadFixture.ciWorkflowPath -Encoding utf8 -NoNewline -Value $hiddenStringCiWorkflow
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $hiddenStringUploadFixture
  } "CI Beta candidate artifact upload must not include hidden files." "Beta candidate consistency should reject quoted true hidden-file uploads."

  $extraInputUploadFixture = New-BetaCandidateFixture (Join-Path $tempRoot "extra-upload-input")
  $extraInputCiWorkflow = (Get-Content -Raw -LiteralPath $extraInputUploadFixture.ciWorkflowPath).Replace("          retention-days: 14", "          retention-days: 14`r`n          overwrite: true")
  Set-Content -LiteralPath $extraInputUploadFixture.ciWorkflowPath -Encoding utf8 -NoNewline -Value $extraInputCiWorkflow
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $extraInputUploadFixture
  } "CI Beta candidate artifact upload must not define unsupported with: input overwrite" "Beta candidate consistency should reject extra upload-artifact inputs outside the bundle contract."

  $otherJobUploadFixture = New-BetaCandidateFixture (Join-Path $tempRoot "other-job-upload")
  $otherJobCiWorkflow = @"
name: CI

on:
  workflow_dispatch:

jobs:
  setup:
    runs-on: windows-2022
    steps:
      - name: Upload Beta candidate VSIX and evidence bundle
        if: `${{ env.SUBVERSIONR_RELEASE_CI_MODE == 'candidate-seal' }}
        uses: actions/upload-artifact@v7
        with:
          name: subversionr-win32-x64-beta-candidate
          path: |
$uploadPathBlock
          if-no-files-found: error
          retention-days: 14
  windows:
    runs-on: windows-2022
    steps:
      - name: Upload Beta candidate VSIX and evidence bundle
        if: `${{ env.SUBVERSIONR_RELEASE_CI_MODE == 'candidate-seal' }}
        uses: actions/upload-artifact@v7
        with:
          name: subversionr-win32-x64-beta-candidate
          path: |
            target/vsix/subversionr-win32-x64-0.2.5.vsix
            target/release-evidence/subversionr-source-sbom.cdx.json
            target/release-evidence/THIRD-PARTY-NOTICES.md
            target/release-evidence/installed-source-control-ui-e2e/win32-x64/**/*.png
            target/release-evidence/installed-source-control-ui-e2e/win32-x64/**/*.txt
            target/release-evidence/installed-source-control-ui-e2e/win32-x64/**/*.json
          if-no-files-found: error
          retention-days: 14
"@
  Set-Content -LiteralPath $otherJobUploadFixture.ciWorkflowPath -Encoding utf8 -NoNewline -Value $otherJobCiWorkflow
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $otherJobUploadFixture
  } "CI Beta candidate artifact upload path list must match the exact ordered Beta-G bundle contract" "Beta candidate consistency should bind the Windows job upload step, not another job."

  $runBlockUploadFixture = New-BetaCandidateFixture (Join-Path $tempRoot "run-block-upload")
  $uploadPathBlock16 = Get-BetaArtifactBundleUploadPathBlock "                "
  $runBlockCiWorkflow = @"
name: CI

on:
  workflow_dispatch:

jobs:
  windows:
    runs-on: windows-2022
    steps:
      - name: Print fixture
        run: |
          - name: Upload Beta candidate VSIX and evidence bundle
            uses: actions/upload-artifact@v7
            with:
              name: subversionr-win32-x64-beta-candidate
              path: |
$uploadPathBlock16
              if-no-files-found: error
              retention-days: 14
      - name: Upload Beta candidate VSIX and evidence bundle
        if: `${{ env.SUBVERSIONR_RELEASE_CI_MODE == 'candidate-seal' }}
        uses: actions/upload-artifact@v7
        with:
          name: subversionr-win32-x64-beta-candidate
          path: |
            target/vsix/subversionr-win32-x64-0.2.5.vsix
            target/release-evidence/subversionr-source-sbom.cdx.json
            target/release-evidence/THIRD-PARTY-NOTICES.md
            target/release-evidence/installed-source-control-ui-e2e/win32-x64/**/*.png
            target/release-evidence/installed-source-control-ui-e2e/win32-x64/**/*.txt
            target/release-evidence/installed-source-control-ui-e2e/win32-x64/**/*.json
          if-no-files-found: error
          retention-days: 14
"@
  Set-Content -LiteralPath $runBlockUploadFixture.ciWorkflowPath -Encoding utf8 -NoNewline -Value $runBlockCiWorkflow
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $runBlockUploadFixture
  } "CI Beta candidate artifact upload path list must match the exact ordered Beta-G bundle contract" "Beta candidate consistency should ignore upload-shaped text inside run blocks."

  $duplicateWindowsUploadFixture = New-BetaCandidateFixture (Join-Path $tempRoot "duplicate-windows-upload")
  $duplicateWindowsCiWorkflow = (Get-Content -Raw -LiteralPath $duplicateWindowsUploadFixture.ciWorkflowPath) + @"

      - name: Upload Beta candidate VSIX and evidence bundle
        uses: actions/upload-artifact@v7
        with:
          name: subversionr-win32-x64-beta-candidate
          path: |
$uploadPathBlock
          if-no-files-found: error
          retention-days: 14
"@
  Set-Content -LiteralPath $duplicateWindowsUploadFixture.ciWorkflowPath -Encoding utf8 -NoNewline -Value $duplicateWindowsCiWorkflow
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $duplicateWindowsUploadFixture
  } "CI workflow windows job must include exactly one Upload Beta candidate VSIX and evidence bundle step" "Beta candidate consistency should reject duplicate Windows upload steps."

  $duplicateWithUploadFixture = New-BetaCandidateFixture (Join-Path $tempRoot "duplicate-with-upload")
  $duplicateWithCiWorkflow = (Get-Content -Raw -LiteralPath $duplicateWithUploadFixture.ciWorkflowPath) + @"

        with:
          name: subversionr-win32-x64-beta-candidate
          path: |
$uploadPathBlock
          if-no-files-found: error
          retention-days: 14
"@
  Set-Content -LiteralPath $duplicateWithUploadFixture.ciWorkflowPath -Encoding utf8 -NoNewline -Value $duplicateWithCiWorkflow
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $duplicateWithUploadFixture
  } "CI Beta candidate artifact upload step must not repeat with" "Beta candidate consistency should reject duplicate upload step with blocks."

  $duplicateUsesUploadFixture = New-BetaCandidateFixture (Join-Path $tempRoot "duplicate-uses-upload")
  $duplicateUsesCiWorkflow = (Get-Content -Raw -LiteralPath $duplicateUsesUploadFixture.ciWorkflowPath).Replace("        uses: actions/upload-artifact@v7", "        uses: actions/upload-artifact@v7`r`n        uses: actions/download-artifact@v7")
  Set-Content -LiteralPath $duplicateUsesUploadFixture.ciWorkflowPath -Encoding utf8 -NoNewline -Value $duplicateUsesCiWorkflow
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $duplicateUsesUploadFixture
  } "CI Beta candidate artifact upload step must not repeat uses" "Beta candidate consistency should reject duplicate upload step uses keys."

  $duplicateNameUploadFixture = New-BetaCandidateFixture (Join-Path $tempRoot "duplicate-name-upload")
  $duplicateNameCiWorkflow = (Get-Content -Raw -LiteralPath $duplicateNameUploadFixture.ciWorkflowPath).Replace("        uses: actions/upload-artifact@v7", "        name: Shadow upload name`r`n        uses: actions/upload-artifact@v7")
  Set-Content -LiteralPath $duplicateNameUploadFixture.ciWorkflowPath -Encoding utf8 -NoNewline -Value $duplicateNameCiWorkflow
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $duplicateNameUploadFixture
  } "CI Beta candidate artifact upload step must not repeat name" "Beta candidate consistency should reject duplicate upload step name keys."

  $conditionalUploadFixture = New-BetaCandidateFixture (Join-Path $tempRoot "conditional-upload")
  $conditionalCiWorkflow = (Get-Content -Raw -LiteralPath $conditionalUploadFixture.ciWorkflowPath).Replace("        if: `${{ env.SUBVERSIONR_RELEASE_CI_MODE == 'candidate-seal' }}", "        if: `${{ false }}")
  Set-Content -LiteralPath $conditionalUploadFixture.ciWorkflowPath -Encoding utf8 -NoNewline -Value $conditionalCiWorkflow
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $conditionalUploadFixture
  } "must run only for explicit candidate-seal mode" "Beta candidate consistency should reject upload conditions other than the explicit candidate-seal boundary."

  $continueOnErrorUploadFixture = New-BetaCandidateFixture (Join-Path $tempRoot "continue-on-error-upload")
  $continueOnErrorCiWorkflow = (Get-Content -Raw -LiteralPath $continueOnErrorUploadFixture.ciWorkflowPath).Replace("        uses: actions/upload-artifact@v7", "        uses: actions/upload-artifact@v7`r`n        continue-on-error: true")
  Set-Content -LiteralPath $continueOnErrorUploadFixture.ciWorkflowPath -Encoding utf8 -NoNewline -Value $continueOnErrorCiWorkflow
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $continueOnErrorUploadFixture
  } "CI Beta candidate artifact upload step must not define unsupported step key continue-on-error" "Beta candidate consistency should reject upload steps that can mask upload failures."

  $quotedConditionalUploadFixture = New-BetaCandidateFixture (Join-Path $tempRoot "quoted-conditional-upload")
  $quotedConditionalCiWorkflow = (Get-Content -Raw -LiteralPath $quotedConditionalUploadFixture.ciWorkflowPath).Replace("        if: `${{ env.SUBVERSIONR_RELEASE_CI_MODE == 'candidate-seal' }}", "        `"if`": `${{ false }}")
  Set-Content -LiteralPath $quotedConditionalUploadFixture.ciWorkflowPath -Encoding utf8 -NoNewline -Value $quotedConditionalCiWorkflow
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $quotedConditionalUploadFixture
  } "must run only for explicit candidate-seal mode" "Beta candidate consistency should reject quoted upload conditions that weaken the candidate-seal boundary."

  $spacedQuotedConditionalUploadFixture = New-BetaCandidateFixture (Join-Path $tempRoot "spaced-quoted-conditional-upload")
  $spacedQuotedConditionalCiWorkflow = (Get-Content -Raw -LiteralPath $spacedQuotedConditionalUploadFixture.ciWorkflowPath).Replace("        if: `${{ env.SUBVERSIONR_RELEASE_CI_MODE == 'candidate-seal' }}", "        `"if`" : `${{ false }}")
  Set-Content -LiteralPath $spacedQuotedConditionalUploadFixture.ciWorkflowPath -Encoding utf8 -NoNewline -Value $spacedQuotedConditionalCiWorkflow
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $spacedQuotedConditionalUploadFixture
  } "must run only for explicit candidate-seal mode" "Beta candidate consistency should reject spaced quoted upload conditions that weaken the candidate-seal boundary."

  $escapedQuotedConditionalUploadFixture = New-BetaCandidateFixture (Join-Path $tempRoot "escaped-quoted-conditional-upload")
  $escapedQuotedConditionalCiWorkflow = (Get-Content -Raw -LiteralPath $escapedQuotedConditionalUploadFixture.ciWorkflowPath).Replace("        if: `${{ env.SUBVERSIONR_RELEASE_CI_MODE == 'candidate-seal' }}", '        "i\x66": ${{ false }}')
  Set-Content -LiteralPath $escapedQuotedConditionalUploadFixture.ciWorkflowPath -Encoding utf8 -NoNewline -Value $escapedQuotedConditionalCiWorkflow
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $escapedQuotedConditionalUploadFixture
  } "CI Beta candidate artifact upload step keys must be bare or simple quoted keys." "Beta candidate consistency should reject escaped quoted upload step keys."

  $quotedContinueOnErrorUploadFixture = New-BetaCandidateFixture (Join-Path $tempRoot "quoted-continue-on-error-upload")
  $quotedContinueOnErrorCiWorkflow = (Get-Content -Raw -LiteralPath $quotedContinueOnErrorUploadFixture.ciWorkflowPath).Replace("        uses: actions/upload-artifact@v7", "        uses: actions/upload-artifact@v7`r`n        `"continue-on-error`": true")
  Set-Content -LiteralPath $quotedContinueOnErrorUploadFixture.ciWorkflowPath -Encoding utf8 -NoNewline -Value $quotedContinueOnErrorCiWorkflow
  Assert-NativeCommandFailsContaining {
    Invoke-BetaCandidateVerifier $quotedContinueOnErrorUploadFixture
  } "CI Beta candidate artifact upload step must not define unsupported step key continue-on-error" "Beta candidate consistency should reject quoted upload steps that can mask upload failures."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $workflowScript `
      -Target win32-x64 `
      -VsixPath "%SUBVERSIONR_BETA_CANDIDATE_VSIX%" `
      -VsixEvidencePath $fixture.vsixEvidencePath `
      -CiWorkflowPath $fixture.ciWorkflowPath `
      -ReleaseEvidenceRoot $fixture.evidenceRoot `
      -ArtifactBundleManifestPath $fixture.artifactBundleManifestPath `
      -OutputPath $fixture.outputPath
  } "VsixPath must be an explicit path" "Beta candidate consistency should reject unresolved placeholders."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $orchestrationScript `
      -Target win32-x64 `
      -CodeCliPath "%SUBVERSIONR_CODE_CLI%" `
      -SvnToolsRoot ".cache/native/stage/subversion-win-x64/bin" `
      -RendererCaptureDriverPath "scripts/release/capture-vscode-renderer-ui.mjs" `
      -WindowNormalizerPath "scripts/release/normalize-vscode-window.ps1"
  } "CodeCliPath must be an explicit path" "Beta candidate orchestration should reject unresolved Code CLI placeholders before running release gates."

  $orchestration = Get-Content -Raw -LiteralPath $orchestrationScript
  Assert-ContainsInOrder $orchestration @(
    'Remove-Item -LiteralPath $artifactBundleManifestOutputPath -Force',
    'Remove-Item -LiteralPath $candidateConsistencyOutputPath -Force',
    'Invoke-PnpmScript "Run Beta candidate evidence script tests" "release:test-beta-candidate-evidence-scripts"',
    'Invoke-PnpmScript "Generate source SBOM evidence" "release:generate-source-sbom"',
    'Invoke-PnpmScript "Generate third-party notice evidence" "release:generate-third-party-notice"',
    'Invoke-PnpmScript "Verify source SBOM and third-party notice evidence" "release:verify-evidence"',
    'Invoke-PnpmScript "Stage VS Code $Target package layout" "release:stage-vscode:$Target"',
    'Invoke-PnpmScript "Verify VS Code $Target package layout" "release:verify-vscode:$Target"',
    'Invoke-PnpmScript "Package VS Code $Target VSIX" "release:package-vsix:$Target"',
    'Invoke-PnpmScript "Generate native artifact map preflight" "release:generate-native-artifact-map:$Target"',
    'Invoke-PnpmScript "Verify native artifact map preflight" "release:verify-native-artifact-map:$Target"',
    'Invoke-PnpmScript "Generate release provenance preflight" "release:generate-provenance:$Target"',
    'Invoke-PnpmScript "Verify release provenance preflight" "release:verify-provenance:$Target"',
    'Invoke-PnpmScript "Generate publication gaps preflight" "release:generate-publication-gaps:$Target"',
    'Invoke-PnpmScript "Verify publication gaps preflight" "release:verify-publication-gaps:$Target"',
    'ScriptName "test-vscode-cli-install-vsix.ps1"',
    'ScriptName "test-vscode-installed-extension-host.ps1"',
    'ScriptName "test-vscode-installed-core-workflow.ps1"',
    'ScriptName "test-vscode-installed-source-control-surface.ps1"',
    'ScriptName "test-vscode-installed-source-control-ui-e2e.ps1"',
    'ScriptName "test-vscode-install-rollback-fixture.ps1"',
    '"-BackendModulePath", $backendModulePath',
    'Invoke-PnpmScript "Test state-engine Beta performance" "release:test-state-engine-beta-performance:$Target"',
    'Invoke-PnpmScript "Generate Beta artifact bundle manifest" "release:generate-beta-artifact-bundle-manifest:$Target"',
    'Invoke-PnpmScript "Verify Beta candidate evidence consistency" "release:verify-beta-candidate:$Target"'
  ) "Beta candidate orchestration should regenerate candidate evidence in dependency order."
  Assert-True ($orchestration.Contains('subversionr-beta-artifact-bundle-manifest-$Target.json')) "Beta candidate orchestration should name the artifact bundle manifest output explicitly before running release gates."
  Assert-True ($orchestration.Contains('subversionr-beta-candidate-consistency-$Target.json')) "Beta candidate orchestration should name the final consistency output explicitly before running release gates."
  Assert-True ($orchestration.Contains('Assert-CodeCliPath $CodeCliPath')) "Beta candidate orchestration should validate CodeCliPath before running release gates."
  Assert-True ($orchestration.Contains('Assert-RepoDirectory') -and $orchestration.Contains('.cache\native\stage\subversion-win-x64\bin')) "Beta candidate orchestration should require the explicit staged SVN tools root."
  Assert-True ($orchestration.Contains('Assert-RepoFile') -and $orchestration.Contains('scripts\release')) "Beta candidate orchestration should require an explicit renderer capture driver path."
  Assert-True ($orchestration.Contains('(Resolve-RepoPath "packages/vscode-extension/dist/backend/backendProcess.js")')) "Beta candidate orchestration should bind install rollback verification to the exact compiled package backend module."

  $packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  Assert-True ($packageJson.scripts."release:test-beta-candidate-evidence-scripts".Contains("release-beta-candidate-evidence-scripts.tests.ps1")) "Root package should expose Beta candidate evidence script tests."
  Assert-True ($packageJson.scripts."release:prepare-beta-candidate:win32-x64".Contains("run-beta-candidate-evidence.ps1")) "Root package should expose the Beta candidate evidence orchestration gate."
  Assert-True ($packageJson.scripts."release:prepare-beta-candidate:win32-x64".Contains("%SUBVERSIONR_CODE_CLI%")) "Beta candidate evidence orchestration should require an explicit Code CLI path."
  Assert-True ($packageJson.scripts."release:prepare-beta-candidate:win32-x64".Contains(".cache/native/stage/subversion-win-x64/bin")) "Beta candidate evidence orchestration should require the staged SVN tools root."
  Assert-True ($packageJson.scripts."release:prepare-beta-candidate:win32-x64".Contains("scripts/release/capture-vscode-renderer-ui.mjs")) "Beta candidate evidence orchestration should use the renderer capture driver."
  Assert-True ($packageJson.scripts."release:prepare-beta-candidate:win32-x64".Contains("scripts/release/normalize-vscode-window.ps1")) "Beta candidate evidence orchestration should use the production native window normalizer."
  Assert-True ($packageJson.scripts."release:generate-beta-artifact-bundle-manifest:win32-x64".Contains("generate-beta-artifact-bundle-manifest.ps1")) "Root package should expose the Beta artifact bundle manifest generator."
  Assert-True ($packageJson.scripts."release:generate-beta-artifact-bundle-manifest:win32-x64".Contains("target/release-evidence/subversionr-beta-artifact-bundle-manifest-win32-x64.json")) "Beta artifact bundle manifest generator should write target release evidence."
  Assert-True ($packageJson.scripts."release:verify-beta-candidate:win32-x64".Contains("verify-beta-candidate-evidence.ps1")) "Root package should expose the Beta candidate consistency gate."
  Assert-True ($packageJson.scripts."release:verify-beta-candidate:win32-x64".Contains("-ArtifactBundleManifestPath target/release-evidence/subversionr-beta-artifact-bundle-manifest-win32-x64.json")) "Beta candidate consistency gate should require the artifact bundle manifest path."
  Assert-True ($packageJson.scripts."release:verify-beta-candidate:win32-x64".Contains("target/release-evidence/subversionr-beta-candidate-consistency-win32-x64.json")) "Beta candidate consistency gate should write target release evidence."

  $ciWorkflow = Get-Content -Raw -LiteralPath $ciWorkflowPath
  Assert-True ($ciWorkflow.Contains("Release Beta candidate evidence script tests")) "CI should run Beta candidate evidence script tests."
  Assert-True ($ciWorkflow.Contains("Generate Beta artifact bundle manifest")) "CI should generate the Beta artifact bundle manifest before final verification."
  Assert-True ($ciWorkflow.Contains("pnpm release:generate-beta-artifact-bundle-manifest:win32-x64")) "CI should run the Beta artifact bundle manifest generator."
  Assert-True ($ciWorkflow.Contains("Verify Beta candidate evidence consistency")) "CI should run the Beta candidate consistency gate."
  Assert-True ($ciWorkflow.Contains("actions/upload-artifact@v7")) "CI should use the current upload-artifact major for the Beta candidate bundle."
  Assert-True ($ciWorkflow.Contains("subversionr-win32-x64-beta-candidate")) "CI should name the Beta candidate artifact bundle."
  $candidateSealStepCondition = "if: `${{ env.SUBVERSIONR_RELEASE_CI_MODE == 'candidate-seal' }}"
  Assert-Equal 3 ([regex]::Matches($ciWorkflow, [regex]::Escape($candidateSealStepCondition))).Count "CI should apply the explicit candidate-seal condition only to candidate manifest, verification, and upload steps."
  Assert-ContainsInOrder $ciWorkflow @(
    "Test installed VSIX Source Control UI E2E",
    "Generate Beta artifact bundle manifest",
    "Verify Beta candidate evidence consistency",
    "Rust native bridge integration test",
    "Upload Beta candidate VSIX and evidence bundle"
  ) "CI continuous validation should retain installed/native gates while candidate-only steps share the explicit seal boundary."
  Assert-True (-not $ciWorkflow.Contains("target/release-evidence/*.json")) "CI artifact upload should not use a broad release evidence JSON glob."
  Assert-True ($ciWorkflow.Contains("target/release-evidence/subversionr-source-sbom.cdx.json")) "CI artifact upload should include the source SBOM explicitly."
  Assert-True ($ciWorkflow.Contains("target/release-evidence/subversionr-beta-artifact-bundle-manifest-win32-x64.json")) "CI artifact upload should include the artifact bundle manifest explicitly."
  Assert-True ($ciWorkflow.Contains("target/release-evidence/subversionr-beta-candidate-consistency-win32-x64.json")) "CI artifact upload should include the final consistency report explicitly."
  Assert-True ($ciWorkflow.Contains("if-no-files-found: error")) "CI artifact upload should fail when the Beta candidate bundle is missing."
  Assert-True ($ciWorkflow.Contains("retention-days: 14")) "CI artifact upload should retain the Beta candidate bundle for review."

  Write-Host "Release Beta candidate evidence script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

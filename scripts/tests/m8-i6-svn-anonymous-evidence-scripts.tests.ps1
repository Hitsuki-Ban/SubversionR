$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$verifyScript = Join-Path $repoRoot "scripts\release\verify-m8-i6-svn-anonymous-evidence.ps1"
$runScript = Join-Path $repoRoot "scripts\release\run-m8-i6-svn-anonymous-evidence.ps1"
$contractPath = Join-Path $repoRoot "docs\release\m8-i6-svn-anonymous-evidence-contract.md"
$schemaPath = Join-Path $repoRoot "docs\release\m8-i6-svn-anonymous-evidence.v1.schema.json"
$probeDriverPath = Join-Path $repoRoot "scripts\release\probe-m8-i6-svn-anonymous.ps1"
$packagedNativeProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-packaged-native.mjs"
$packagedNegativeProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-packaged-negative.mjs"
$packagedAuthzDeniedProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-packaged-authz-denied.mjs"
$packagedStalledReadProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-packaged-stalled-read.mjs"
$packagedDeadlineProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-packaged-deadline.mjs"
$packagedCancellationProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-packaged-cancellation.mjs"
$packagedTrustRevokedProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-packaged-trust-revoked.mjs"
$packagedRecoveryBlockedProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-packaged-recovery-blocked.mjs"
$packagedRecoverySafeProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-packaged-recovery-safe.mjs"
$packagedRecoveryIndeterminateProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-packaged-recovery-indeterminate.mjs"
$packagedRedactionProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-packaged-redaction.mjs"
$raSvnFaultFixturePath = Join-Path $repoRoot "scripts\release\serve-m8-i6-ra-svn-fault-fixture.mjs"
$countingProxyPath = Join-Path $repoRoot "scripts\release\serve-m8-i6-counting-proxy.mjs"
$installedStressProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-stress.ps1"
$installedNegativeProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-negative.ps1"
$installedAuthzDeniedProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-authz-denied.ps1"
$installedStalledReadProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-stalled-read.ps1"
$installedDeadlineProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-deadline.ps1"
$installedCancellationProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-cancellation.ps1"
$installedTrustRevokedProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-trust-revoked.ps1"
$installedRecoveryBlockedProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-recovery-blocked.ps1"
$installedRecoverySafeProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-recovery-safe.ps1"
$installedRecoveryIndeterminateProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-recovery-indeterminate.ps1"
$installedRedactionProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-redaction.ps1"
$installedLocalEventProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-local-event-zero-network.ps1"
$installedVsixProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-vsix.ps1"
$packagedCompatibilityProbePath = Join-Path $repoRoot "scripts\release\probe-vscode-packaged-native.mjs"
$installedExtensionHostProbePath = Join-Path $repoRoot "scripts\release\test-vscode-installed-extension-host.ps1"
$patchPath = Join-Path $repoRoot "native\patches\subversion-1.14.5\ra-svn-authority.patch"
$patchContractPath = Join-Path $repoRoot "native\patches\subversion-1.14.5\ra-svn-authority.contract.json"
$sourceLockPath = Join-Path $repoRoot "native\sources.lock.json"
$tempRoot = Join-Path $repoRoot "target\tests\m8-i6-svn-anonymous-evidence\$([Guid]::NewGuid().ToString('N'))"
$fakeStageRoot = Join-Path $repoRoot ".cache\tests\m8-i6-svn-anonymous-evidence\$([Guid]::NewGuid().ToString('N'))"
$allowedRunnerRoot = Join-Path $repoRoot "target\i6-evidence"
$runnerFixtureRoot = Join-Path $repoRoot "target\i6-evidence\t-$PID"

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

function Assert-ScriptThrowsContaining([scriptblock]$Action, [string]$ExpectedText, [string]$Message) {
  $thrown = $null
  try {
    & $Action
  }
  catch {
    $thrown = $_
  }
  Assert-True ($null -ne $thrown) "$Message Expected the script block to throw."
  Assert-True ($thrown.Exception.Message.Contains($ExpectedText)) "$Message Expected '$ExpectedText', got '$($thrown.Exception.Message)'."
}

function Get-Sha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-ArtifactBinding([string]$Kind, [string]$Path) {
  return [ordered]@{
    kind = $Kind
    sha256 = Get-Sha256 $Path
    sizeBytes = [int64](Get-Item -LiteralPath $Path).Length
  }
}

function New-MissingArtifactBinding([string]$Kind) {
  return [ordered]@{
    kind = $Kind
    sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
    sizeBytes = 1
  }
}

function New-OperationCell([string]$Operation) {
  return [ordered]@{
    operation = $Operation
    status = "passed"
    serverAuth = "anonymous"
    promptCount = 0
    credentialSettlement = "none"
    reconcile = "fresh"
    workerDescendantsAfter = 0
    temporaryRootsAfter = 0
    nativeLaneReleased = $true
    diagnosticsRedacted = $true
  }
}

function New-Surface([string]$Kind, [string]$ArtifactSha256) {
  $operations = @(
    "checkoutOpen",
    "remoteStatus",
    "content",
    "historyLog",
    "historyBlame",
    "update",
    "commit",
    "branchCopy",
    "switch",
    "lock",
    "unlock"
  ) | ForEach-Object { New-OperationCell $_ }
  return [ordered]@{
    kind = $Kind
    artifactSha256 = $ArtifactSha256
    protocol = [ordered]@{ major = 1; minor = 35 }
    remoteSvnAnonymous = $true
    fixtureCliInvocations = 0
    operations = @($operations)
  }
}

function New-NegativeSurfaceObservation(
  [string]$Surface,
  [string]$OriginCode,
  [string]$OriginReason,
  [string]$NetworkProgress,
  [int]$NetworkAttempts,
  [int]$NetworkConnections,
  [string]$SettlementCode = $OriginCode,
  [string]$SettlementReason = $OriginReason
) {
  return [ordered]@{
    surface = $Surface
    originCode = $OriginCode
    originReason = $OriginReason
    settlementCode = $SettlementCode
    settlementReason = $SettlementReason
    networkProgress = $NetworkProgress
    networkAttempts = $NetworkAttempts
    networkConnections = $NetworkConnections
    fixtureCliInvocations = 0
    credentialRequests = 0
    credentialSettlements = 0
    followupNetworkContacts = 0
    workerDescendantsAfter = 0
    temporaryRootsAfter = 0
    diagnosticsRedacted = $true
  }
}

function New-NegativeCell(
  [string]$Cell,
  [string]$OriginCode,
  [string]$OriginReason,
  [string]$NetworkProgress,
  [int]$NetworkAttempts,
  [int]$NetworkConnections,
  [bool]$InstalledOnly = $false,
  [string]$SettlementCode = $OriginCode,
  [string]$SettlementReason = $OriginReason
) {
  [object[]]$surfaceObservations = if ($InstalledOnly) {
    @((New-NegativeSurfaceObservation "installed-vsix-extension-host" $OriginCode $OriginReason $NetworkProgress $NetworkAttempts $NetworkConnections $SettlementCode $SettlementReason))
  }
  else {
    @(
      (New-NegativeSurfaceObservation "packaged-native" $OriginCode $OriginReason $NetworkProgress $NetworkAttempts $NetworkConnections $SettlementCode $SettlementReason),
      (New-NegativeSurfaceObservation "installed-vsix-extension-host" $OriginCode $OriginReason $NetworkProgress $NetworkAttempts $NetworkConnections $SettlementCode $SettlementReason)
    )
  }
  if ($Cell -ceq "deadline") {
    foreach ($observation in $surfaceObservations) {
      $observation["deadlineTiming"] = [ordered]@{
        clock = "monotonic"
        timeoutMs = 500
        elapsedMs = 500
        cleanupSlackMs = 5000
      }
    }
  }
  if ($Cell -ceq "cancellation") {
    foreach ($observation in $surfaceObservations) {
      $observation["cancellationSettlement"] = [ordered]@{
        trigger = "abort-signal-after-greeting"
        localCode = "JSON_RPC_REQUEST_CANCELLED"
        wireCode = "SUBVERSIONR_REMOTE_WORKER_CANCELLED"
        wireReason = "operationCancelled"
        wireSettlementObserved = $true
      }
    }
  }
  if ($Cell -ceq "trustRevoked") {
    foreach ($observation in $surfaceObservations) {
      $observation["trustTransition"] = [ordered]@{
        fromEpoch = 1
        toEpoch = 2
        staleEnvelopeEpoch = 1
        remoteSubmissionEnabledAfter = $false
      }
    }
  }
  return [ordered]@{
    cell = $Cell
    status = "passed"
    stableCode = $OriginCode
    reason = $OriginReason
    surfaceObservations = $surfaceObservations
  }
}

function New-RecoverySurfaceObservation([string]$Surface) {
  return [ordered]@{
    surface = $Surface
    safe = [ordered]@{
      outcome = "Safe"
      freshReconcile = $true
      nativeLaneReleased = $true
      subsequentRequestPassed = $true
    }
    indeterminate = [ordered]@{
      outcome = "Indeterminate"
      stableCode = "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE"
      reason = "remoteOperationIndeterminate"
      nativeLaneBlocked = $true
      explicitRecoveryRequired = $true
    }
    blocked = [ordered]@{
      outcome = "Blocked"
      stableCode = "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED"
      reason = "remoteRecoveryBlocked"
      restartRestoredBlocked = $true
      automaticClear = $false
      requiredConfirmation = "reviewedAndResolved"
      armedTargetPathSha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
      confirmedTargetPathSha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
      armedOriginOperationIdSha256 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
      confirmedOriginOperationIdSha256 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
      confirmedEntryRemoved = $true
      subsequentCheckoutPassed = $true
    }
  }
}

function New-StressCycleObservation([int]$Cycle) {
  return [ordered]@{
    cycle = $Cycle
    operationIdSha256 = ("{0:x64}" -f [uint64]$Cycle)
    targetPathSha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    extensionHostSessionSha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    operation = "checkoutOpen"
    faultMode = "none"
    status = "passed"
    checkoutRevision = 2
    fixtureCliInvocations = 0
    credentialRequests = 0
    credentialSettlements = 0
    workerDescendantsAfter = 0
    temporaryRootsAfter = 0
    fixtureServerChildrenAfter = 0
    checkoutJournalEntriesAfter = 0
    diagnosticsRedacted = $true
  }
}

function Write-Report([object]$Report, [string]$Path) {
  $Report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Copy-Report([object]$Report) {
  return ($Report | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
}

function Copy-ArgumentsWithValue([object[]]$Arguments, [string]$Name, [string]$Value) {
  $copy = @($Arguments)
  $index = [Array]::IndexOf($copy, $Name)
  Assert-True ($index -ge 0 -and $index + 1 -lt $copy.Count) "Argument $Name must exist in the test invocation."
  $copy[$index + 1] = $Value
  return $copy
}

function New-FakeSubversionStage([string]$Root, [string]$NativeModulePath, [string]$SourceLockPath) {
  $requiredFiles = @(
    "include\subversion-1\svn_client.h",
    "include\subversion-1\svn_wc.h",
    "include\subversion-1\svn_version.h",
    "include\apr.h",
    "include\apu.h",
    "include\apr_pools.h",
    "lib\libsvn_client-1.lib",
    "lib\libsvn_ra-1.lib",
    "lib\libsvn_ra_serf-1.lib",
    "lib\libsvn_wc-1.lib",
    "lib\libsvn_subr-1.lib",
    "lib\libapr-1.lib",
    "lib\libaprutil-1.lib",
    "lib\libcrypto.lib",
    "lib\libssl.lib",
    "lib\serf-1.lib",
    "include\openssl\opensslv.h",
    "include\openssl\ssl.h",
    "include\openssl\crypto.h",
    "include\serf-1\serf.h",
    "include\serf-1\serf_bucket_types.h",
    "include\serf-1\serf_bucket_util.h",
    "bin\libapr-1.dll",
    "bin\libapriconv-1.dll",
    "bin\libaprutil-1.dll",
    "bin\libexpat.dll",
    "bin\libsvn_client-1.dll",
    "bin\libsvn_delta-1.dll",
    "bin\libsvn_diff-1.dll",
    "bin\libsvn_fs-1.dll",
    "bin\libsvn_fs_fs-1.dll",
    "bin\libsvn_fs_util-1.dll",
    "bin\libsvn_fs_x-1.dll",
    "bin\libsvn_ra-1.dll",
    "bin\libsvn_repos-1.dll",
    "bin\libsvn_subr-1.dll",
    "bin\libsvn_wc-1.dll",
    "bin\svn.exe",
    "bin\svnadmin.exe",
    "bin\svnserve.exe",
    "bin\libssl-3-x64.dll",
    "bin\libcrypto-3-x64.dll",
    "bin\iconv\utf8.so"
  )
  foreach ($relativePath in $requiredFiles) {
    $path = Join-Path $Root $relativePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    Set-Content -LiteralPath $path -Value "fixture" -NoNewline
  }
  Set-Content -LiteralPath (Join-Path $Root "include\subversion-1\svn_version.h") -Value "#define SVN_VER_MAJOR 1`n#define SVN_VER_MINOR 14`n#define SVN_VER_PATCH 5`n" -NoNewline
  Set-Content -LiteralPath (Join-Path $Root "include\openssl\opensslv.h") -Value '#define OPENSSL_VERSION_STR "3.5.7"' -NoNewline
  Set-Content -LiteralPath (Join-Path $Root "include\serf-1\serf.h") -Value "#define SERF_MAJOR_VERSION 1`n#define SERF_MINOR_VERSION 3`n#define SERF_PATCH_VERSION 10`n" -NoNewline
  Import-Module $NativeModulePath -Force
  New-SubversionStageManifest -StageRoot $Root -SourceLockPath $SourceLockPath -Arch "x64" -Configuration "Release" | Out-Null
}

New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
try {
  foreach ($path in @($verifyScript, $runScript, $probeDriverPath, $packagedNativeProbePath, $packagedNegativeProbePath, $packagedAuthzDeniedProbePath, $packagedStalledReadProbePath, $packagedDeadlineProbePath, $packagedCancellationProbePath, $packagedTrustRevokedProbePath, $packagedRecoveryBlockedProbePath, $packagedRecoverySafeProbePath, $packagedRecoveryIndeterminateProbePath, $packagedRedactionProbePath, $raSvnFaultFixturePath, $countingProxyPath, $installedStressProbePath, $installedNegativeProbePath, $installedAuthzDeniedProbePath, $installedStalledReadProbePath, $installedDeadlineProbePath, $installedCancellationProbePath, $installedTrustRevokedProbePath, $installedRecoveryBlockedProbePath, $installedRecoverySafeProbePath, $installedRecoveryIndeterminateProbePath, $installedRedactionProbePath, $installedLocalEventProbePath, $installedVsixProbePath, $packagedCompatibilityProbePath, $installedExtensionHostProbePath, $contractPath, $schemaPath, $patchPath, $patchContractPath, $sourceLockPath)) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Required I6 evidence-chain file is missing: $path"
  }

  $artifactsRoot = Join-Path $tempRoot "artifacts"
  New-Item -ItemType Directory -Force -Path $artifactsRoot | Out-Null
  $vsixPath = Join-Path $artifactsRoot "subversionr-win32-x64-0.3.0.vsix"
  $daemonPath = Join-Path $artifactsRoot "subversionr-daemon.exe"
  $bridgePath = Join-Path $artifactsRoot "subversionr_svn_bridge.dll"
  $codeCliPath = Join-Path $artifactsRoot "code.cmd"
  $stageManifestPath = Join-Path $artifactsRoot "subversionr-stage-manifest.json"
  $svnPath = Join-Path $artifactsRoot "svn.exe"
  $svnadminPath = Join-Path $artifactsRoot "svnadmin.exe"
  $svnservePath = Join-Path $artifactsRoot "svnserve.exe"
  $fixtureConfigPath = Join-Path $artifactsRoot "svnserve.conf"
  $fixtureAuthzPath = Join-Path $artifactsRoot "authz"
  $fixtureLogPath = Join-Path $artifactsRoot "svnserve.log"
  Set-Content -LiteralPath $vsixPath -Value "vsix-I6-fixture" -NoNewline
  Set-Content -LiteralPath $daemonPath -Value "daemon-I6-fixture" -NoNewline
  Set-Content -LiteralPath $bridgePath -Value "bridge-I6-fixture" -NoNewline
  Set-Content -LiteralPath $codeCliPath -Value "@exit /b 0" -NoNewline
  Set-Content -LiteralPath $stageManifestPath -Value '{"subversion":"1.14.5"}' -NoNewline
  Set-Content -LiteralPath $svnPath -Value "svn-I6-fixture" -NoNewline
  Set-Content -LiteralPath $svnadminPath -Value "svnadmin-I6-fixture" -NoNewline
  Set-Content -LiteralPath $svnservePath -Value "svnserve-I6-fixture" -NoNewline
  Set-Content -LiteralPath $fixtureConfigPath -Value "[general]`nanon-access = write`nauth-access = none`nauthz-db = authz`n[sasl]`nuse-sasl = false`n" -NoNewline
  Set-Content -LiteralPath $fixtureAuthzPath -Value "[repo:/]`n* = rw`n" -NoNewline
  Set-Content -LiteralPath $fixtureLogPath -Value "fixture svnserve log`n" -NoNewline

  $artifactBindings = [ordered]@{
    vsix = New-ArtifactBinding "vsix" $vsixPath
    daemon = New-ArtifactBinding "daemon" $daemonPath
    bridge = New-ArtifactBinding "bridge" $bridgePath
    stageManifest = New-ArtifactBinding "subversion-stage-manifest" $stageManifestPath
    probeDriver = New-ArtifactBinding "i6-probe-driver" $probeDriverPath
    packagedNativeProbe = New-ArtifactBinding "i6-packaged-native-probe" $packagedNativeProbePath
    packagedNegativeProbe = New-ArtifactBinding "i6-packaged-negative-probe" $packagedNegativeProbePath
    packagedAuthzDeniedProbe = New-ArtifactBinding "i6-packaged-authz-denied-probe" $packagedAuthzDeniedProbePath
    packagedStalledReadProbe = New-ArtifactBinding "i6-packaged-stalled-read-probe" $packagedStalledReadProbePath
    packagedDeadlineProbe = New-ArtifactBinding "i6-packaged-deadline-probe" $packagedDeadlineProbePath
    packagedCancellationProbe = New-ArtifactBinding "i6-packaged-cancellation-probe" $packagedCancellationProbePath
    packagedTrustRevokedProbe = New-ArtifactBinding "i6-packaged-trust-revoked-probe" $packagedTrustRevokedProbePath
    packagedRecoveryBlockedProbe = New-ArtifactBinding "i6-packaged-recovery-blocked-probe" $packagedRecoveryBlockedProbePath
    packagedRecoverySafeProbe = New-ArtifactBinding "i6-packaged-recovery-safe-probe" $packagedRecoverySafeProbePath
    packagedRecoveryIndeterminateProbe = New-ArtifactBinding "i6-packaged-recovery-indeterminate-probe" $packagedRecoveryIndeterminateProbePath
    packagedRedactionProbe = New-ArtifactBinding "i6-packaged-redaction-probe" $packagedRedactionProbePath
    raSvnFaultFixture = New-ArtifactBinding "i6-ra-svn-fault-fixture" $raSvnFaultFixturePath
    countingProxy = New-ArtifactBinding "i6-counting-proxy" $countingProxyPath
    installedStressProbe = New-ArtifactBinding "i6-installed-stress-probe" $installedStressProbePath
    installedNegativeProbe = New-ArtifactBinding "i6-installed-negative-probe" $installedNegativeProbePath
    installedAuthzDeniedProbe = New-ArtifactBinding "i6-installed-authz-denied-probe" $installedAuthzDeniedProbePath
    installedStalledReadProbe = New-ArtifactBinding "i6-installed-stalled-read-probe" $installedStalledReadProbePath
    installedDeadlineProbe = New-ArtifactBinding "i6-installed-deadline-probe" $installedDeadlineProbePath
    installedCancellationProbe = New-ArtifactBinding "i6-installed-cancellation-probe" $installedCancellationProbePath
    installedTrustRevokedProbe = New-ArtifactBinding "i6-installed-trust-revoked-probe" $installedTrustRevokedProbePath
    installedRecoveryBlockedProbe = New-ArtifactBinding "i6-installed-recovery-blocked-probe" $installedRecoveryBlockedProbePath
    installedRecoverySafeProbe = New-ArtifactBinding "i6-installed-recovery-safe-probe" $installedRecoverySafeProbePath
    installedRecoveryIndeterminateProbe = New-ArtifactBinding "i6-installed-recovery-indeterminate-probe" $installedRecoveryIndeterminateProbePath
    installedRedactionProbe = New-ArtifactBinding "i6-installed-redaction-probe" $installedRedactionProbePath
    installedLocalEventProbe = New-ArtifactBinding "i6-installed-local-event-zero-network-probe" $installedLocalEventProbePath
    installedVsixProbe = New-ArtifactBinding "i6-installed-vsix-probe" $installedVsixProbePath
    packagedCompatibilityProbe = New-ArtifactBinding "packaged-native-compatibility-probe" $packagedCompatibilityProbePath
    installedExtensionHostProbe = New-ArtifactBinding "installed-extension-host-probe" $installedExtensionHostProbePath
    raSvnOriginPatch = New-ArtifactBinding "ra-svn-origin-patch" $patchPath
    raSvnOriginContract = New-ArtifactBinding "ra-svn-origin-contract" $patchContractPath
    nativeSourceLock = New-ArtifactBinding "native-source-lock" $sourceLockPath
    svn = New-ArtifactBinding "fixture-svn" $svnPath
    svnadmin = New-ArtifactBinding "fixture-svnadmin" $svnadminPath
    svnserve = New-ArtifactBinding "fixture-svnserve" $svnservePath
    svnserveLog = New-ArtifactBinding "fixture-svnserve-log" $fixtureLogPath
  }
  $report = [ordered]@{
    schema = "subversionr.release.m8-i6-svn-anonymous.win32-x64.v1"
    schemaVersion = 1
    contract = [ordered]@{
      path = "docs/release/m8-i6-svn-anonymous-evidence.v1.schema.json"
      sha256 = Get-Sha256 $schemaPath
    }
    target = "win32-x64"
    productVersion = "0.3.0"
    publicClaimEligible = $true
    artifactBindings = $artifactBindings
    fixture = [ordered]@{
      transport = "direct-svn"
      serverKind = "svnserve"
      serverVersion = "1.14.5"
      listenHost = "127.0.0.1"
      configurationSha256 = Get-Sha256 $fixtureConfigPath
      authzSha256 = Get-Sha256 $fixtureAuthzPath
      sourceBuilt = $true
      fixtureCliOnly = $true
      ambientConfigExcluded = $true
      saslEnabled = $false
    }
    surfaces = @(
      (New-Surface "packaged-native" $artifactBindings.daemon.sha256),
      (New-Surface "installed-vsix-extension-host" $artifactBindings.vsix.sha256)
    )
    negativeCells = @(
      (New-NegativeCell "maliciousRoot" "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH" "crossAuthorityRejected" "authenticated" 1 1),
      (New-NegativeCell "saslOnly" "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED" "remoteCapabilityUnsupported" "greeting" 1 1),
      (New-NegativeCell "authzDenied" "SVN_REMOTE_STATUS_AUTH_FAILED" "authorizationDenied" "command" 1 1),
      (New-NegativeCell "blackholeConnect" "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT" "operationDeadlineExceeded" "none" 1 0),
      (New-NegativeCell "stalledMidRead" "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT" "operationDeadlineExceeded" "greeting" 1 1),
      (New-NegativeCell "deadline" "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT" "operationDeadlineExceeded" "greeting" 1 1),
      (New-NegativeCell "cancellation" "SUBVERSIONR_REMOTE_WORKER_CANCELLED" "operationCancelled" "greeting" 1 1),
      (New-NegativeCell "workerCrash" "SUBVERSIONR_REMOTE_WORKER_CRASHED" "workerContainmentFailed" "greeting" 1 1),
      (New-NegativeCell "daemonDisconnect" "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED" "workerContainmentFailed" "greeting" 1 1),
      (New-NegativeCell "trustRevoked" "SUBVERSIONR_REMOTE_TRUST_EPOCH_MISMATCH" "remoteConfigurationInvalid" "none" 0 0),
      (New-NegativeCell "recoverySafe" "none" "none" "command" 1 1),
      (New-NegativeCell "recoveryIndeterminate" "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE" "remoteOperationIndeterminate" "command" 1 1),
      (New-NegativeCell "recoveryBlocked" "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT" "operationDeadlineExceeded" "command" 1 1 $false "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED" "remoteRecoveryBlocked"),
      (New-NegativeCell "unrelatedRepository" "none" "none" "command" 1 1),
      (New-NegativeCell "localEventZeroNetwork" "none" "none" "none" 0 0 $true),
      (New-NegativeCell "redaction" "none" "none" "command" 1 1)
    )
    recoverySettlements = [ordered]@{
      surfaceObservations = @(
        (New-RecoverySurfaceObservation "packaged-native"),
        (New-RecoverySurfaceObservation "installed-vsix-extension-host")
      )
    }
    stress = [ordered]@{
      surface = "installed-vsix-extension-host"
      cycles = 100
      status = "passed"
      cycleObservations = @(1..100 | ForEach-Object { New-StressCycleObservation $_ })
      subsequentObservation = (New-StressCycleObservation 101)
      maxWorkerDescendantsAfterCycle = 0
      maxTemporaryRootsAfterCycle = 0
      maxFixtureServerChildrenAfterCycle = 0
      subsequentRequestPassed = $true
    }
    privacy = [ordered]@{
      rawUrlCount = 0
      rawPathCount = 0
      secretTokenCount = 0
      maxDiagnosticBytes = 4096
      boundedDiagnostics = $true
    }
    verdict = [ordered]@{
      status = "verified"
      claim = "win32-x64-direct-svn-anonymous"
      allOperationCellsPassed = $true
      allNegativeCellsPassed = $true
      artifactHashesMatched = $true
      installedProductProved = $true
      sourceBuiltFixtureProved = $true
    }
  }
  $evidencePath = Join-Path $tempRoot "evidence.json"
  Write-Report $report $evidencePath

  $verifyArguments = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $verifyScript,
    "-EvidencePath", $evidencePath,
    "-VsixPath", $vsixPath,
    "-DaemonPath", $daemonPath,
    "-BridgePath", $bridgePath,
    "-StageManifestPath", $stageManifestPath,
    "-ProbeDriverPath", $probeDriverPath,
    "-RaSvnOriginPatchPath", $patchPath,
    "-RaSvnOriginContractPath", $patchContractPath,
    "-NativeSourceLockPath", $sourceLockPath,
    "-SvnPath", $svnPath,
    "-SvnadminPath", $svnadminPath,
    "-SvnservePath", $svnservePath,
    "-FixtureConfigPath", $fixtureConfigPath,
    "-FixtureAuthzPath", $fixtureAuthzPath,
    "-FixtureLogPath", $fixtureLogPath,
    "-ExpectedProductVersion", "0.3.0"
  )
  Assert-Equal ([string]$report.negativeCells[0].surfaceObservations[0].originCode) ([string]$report.negativeCells[0].surfaceObservations[0].settlementCode) "Ordinary negative-cell fixtures must default settlement code to the controlled origin code."
  Assert-Equal ([string]$report.negativeCells[0].surfaceObservations[0].originReason) ([string]$report.negativeCells[0].surfaceObservations[0].settlementReason) "Ordinary negative-cell fixtures must default settlement reason to the controlled origin reason."
  Assert-Equal "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT" ([string]$report.negativeCells[12].surfaceObservations[0].originCode) "Blocked recovery fixture must retain the real timeout origin."
  Assert-Equal "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED" ([string]$report.negativeCells[12].surfaceObservations[0].settlementCode) "Blocked recovery fixture must record the distinct product settlement."
  $rawReport = Get-Content -Raw -LiteralPath $evidencePath
  Assert-True (Test-Json -Json $rawReport -SchemaFile $schemaPath) "Complete I6 evidence fixture should satisfy the strict JSON schema."
  $verifiedOutput = & pwsh @verifyArguments 2>&1
  Assert-Equal 0 $LASTEXITCODE "Complete hash-bound I6 evidence fixture should pass the executable verifier. Output: $($verifiedOutput | Out-String)"

  $tampered = Copy-Report $report
  $tampered.surfaces[1].operations = @($tampered.surfaces[1].operations | Select-Object -Skip 1)
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject an incomplete installed operation matrix."

  $tampered = Copy-Report $report
  $tampered.surfaces[0].operations[0].promptCount = 1
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject anonymous credential prompting."

  $tampered = Copy-Report $report
  $tampered.negativeCells[0].surfaceObservations[0].followupNetworkContacts = 1
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject malicious-root follow-up contact."

  $tampered = Copy-Report $report
  $tampered.negativeCells[3].surfaceObservations[0].networkAttempts = 0
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "network attempt count must match" "I6 verification must reject a blackhole record without a measured connection attempt."

  $tampered = Copy-Report $report
  $tampered.negativeCells[14].surfaceObservations[0].networkAttempts = 1
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "network attempt count must match" "I6 verification must reject local-event evidence that attempted remote contact."

  $tampered = Copy-Report $report
  $tampered.negativeCells[2].reason = "authenticationRequired"
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "authorizationDenied" "I6 verification must reject generic authentication classification for authz denial."

  $tampered = Copy-Report $report
  $tampered.negativeCells[5].surfaceObservations[0].deadlineTiming.elapsedMs = 499
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject a deadline observation that settled before its owned timeout."

  $tampered = Copy-Report $report
  $tampered.negativeCells[5].surfaceObservations[1].deadlineTiming.elapsedMs = 5501
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject deadline cleanup outside the reviewed slack."

  $tampered = Copy-Report $report
  $tampered.negativeCells[5].surfaceObservations[0].PSObject.Properties.Remove("deadlineTiming")
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject deadline evidence without an independent monotonic timing observation."

  $tampered = Copy-Report $report
  $tampered.negativeCells[4].surfaceObservations[0] | Add-Member -NotePropertyName deadlineTiming -NotePropertyValue ([pscustomobject]@{ clock = "monotonic"; timeoutMs = 500; elapsedMs = 500; cleanupSlackMs = 5000 })
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "must contain exactly the required fields" "I6 verification must not relabel stalled-mid-read evidence as the independent deadline cell."

  $tampered = Copy-Report $report
  $tampered.negativeCells[6].surfaceObservations[0].cancellationSettlement.wireSettlementObserved = $false
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject cancellation evidence without the daemon wire settlement."

  $tampered = Copy-Report $report
  $tampered.negativeCells[6].surfaceObservations[1].cancellationSettlement.localCode = "SUBVERSIONR_REMOTE_WORKER_CANCELLED"
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must preserve the distinct immediate local cancellation result."

  $tampered = Copy-Report $report
  $tampered.negativeCells[6].surfaceObservations[0].PSObject.Properties.Remove("cancellationSettlement")
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject cancellation evidence without the explicit settlement hand-off."

  $tampered = Copy-Report $report
  $tampered.negativeCells[5].surfaceObservations[0] | Add-Member -NotePropertyName cancellationSettlement -NotePropertyValue ([pscustomobject]@{ trigger = "abort-signal-after-greeting"; localCode = "JSON_RPC_REQUEST_CANCELLED"; wireCode = "SUBVERSIONR_REMOTE_WORKER_CANCELLED"; wireReason = "operationCancelled"; wireSettlementObserved = $true })
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "must contain exactly the required fields" "I6 verification must not relabel deadline evidence as the independent cancellation cell."

  $tampered = Copy-Report $report
  $tampered.negativeCells[9].surfaceObservations[0].PSObject.Properties.Remove("trustTransition")
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject trust-revoked evidence without the exact epoch transition."

  foreach ($trustTamper in @(
      @("fromEpoch", 2),
      @("toEpoch", 3),
      @("staleEnvelopeEpoch", 2),
      @("remoteSubmissionEnabledAfter", $true)
    )) {
    $tampered = Copy-Report $report
    $tampered.negativeCells[9].surfaceObservations[1].trustTransition.($trustTamper[0]) = $trustTamper[1]
    Write-Report $tampered $evidencePath
    Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject a non-exact trust transition field $($trustTamper[0])."
  }

  $tampered = Copy-Report $report
  $tampered.negativeCells[8].surfaceObservations[0] | Add-Member -NotePropertyName trustTransition -NotePropertyValue ([pscustomobject]@{ fromEpoch = 1; toEpoch = 2; staleEnvelopeEpoch = 1; remoteSubmissionEnabledAfter = $false })
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "must contain exactly the required fields" "I6 verification must reject trust-transition evidence injected into daemon-disconnect."

  $tampered = Copy-Report $report
  $tampered.negativeCells[2].surfaceObservations[1].originCode = "SUBVERSIONR_REMOTE_WORKER_CRASHED"
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "origin code must match" "I6 verification must reject an observation origin that diverges from its cell."

  $tampered = Copy-Report $report
  $tampered.negativeCells[12].surfaceObservations[0].settlementCode = "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT"
  $tampered.negativeCells[12].surfaceObservations[0].settlementReason = "operationDeadlineExceeded"
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "settlement code must match" "I6 verification must reject timeout origin substituted for the controlled recovery-blocked settlement."

  $tampered = Copy-Report $report
  $tampered.negativeCells[0].surfaceObservations[0].PSObject.Properties.Remove("settlementReason")
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject a missing settlement field without inference or fallback."

  $tampered = Copy-Report $report
  $tampered.negativeCells[14].surfaceObservations = @($tampered.negativeCells[13].surfaceObservations)
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "installed product observation exactly once" "I6 local-event evidence must be installed-surface only."

  foreach ($requiredNegative in @(
      "blackholeConnect",
      "stalledMidRead",
      "daemonDisconnect",
      "recoverySafe",
      "recoveryIndeterminate",
      "recoveryBlocked"
    )) {
    $tampered = Copy-Report $report
    $tampered.negativeCells = @($tampered.negativeCells | Where-Object { $_.cell -ne $requiredNegative })
    Write-Report $tampered $evidencePath
    Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject evidence missing $requiredNegative."
  }

  $tampered = Copy-Report $report
  $tampered.stress.cycles = 99
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject shortened residue stress evidence."

  $tampered = Copy-Report $report
  $tampered.stress.cycleObservations = @($tampered.stress.cycleObservations | Where-Object { [int]$_.cycle -ne 50 })
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject a missing stress cycle."

  $tampered = Copy-Report $report
  $firstCycle = $tampered.stress.cycleObservations[0]
  $tampered.stress.cycleObservations[0] = $tampered.stress.cycleObservations[1]
  $tampered.stress.cycleObservations[1] = $firstCycle
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "cycle must be exact and ordered" "I6 verification must reject out-of-order stress observations."

  $tampered = Copy-Report $report
  $tampered.stress.cycleObservations[1].operationIdSha256 = $tampered.stress.cycleObservations[0].operationIdSha256
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "operation hashes must be unique" "I6 verification must reject duplicate stress operation hashes."

  $tampered = Copy-Report $report
  $tampered.stress.cycleObservations[50].targetPathSha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "one exact checkout target hash" "I6 verification must reject stress target drift."

  $tampered = Copy-Report $report
  $tampered.stress.cycleObservations[50].extensionHostSessionSha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "one exact installed Extension Host session" "I6 verification must reject stress execution split across Extension Host sessions."

  $tampered = Copy-Report $report
  $tampered.stress.subsequentObservation.extensionHostSessionSha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "same installed Extension Host session" "I6 verification must reject a cycle 101 observation from another Extension Host session."

  $tampered = Copy-Report $report
  $tampered.stress.cycleObservations[0].fixtureCliInvocations = 1
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject fixture CLI use during native checkout stress."

  $tampered = Copy-Report $report
  $tampered.stress.cycleObservations[49].workerDescendantsAfter = 1
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "workerDescendantsAfter must be zero" "I6 verification must reject a nonzero per-cycle worker count."

  $tampered = Copy-Report $report
  $tampered.stress.maxWorkerDescendantsAfterCycle = 1
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "aggregate must be recomputed" "I6 verification must reject a fabricated stress aggregate."

  $tampered = Copy-Report $report
  $tampered.stress.PSObject.Properties.Remove("subsequentObservation")
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject a missing subsequent stress observation."

  $tampered = Copy-Report $report
  $tampered.recoverySettlements.surfaceObservations[0].blocked.automaticClear = $true
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject automatic checkout-target recovery clearing."

  $tampered = Copy-Report $report
  $tampered.recoverySettlements.surfaceObservations[0].blocked.confirmedTargetPathSha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "target-path hash" "I6 verification must reject recovery confirmation for a different target."

  $tampered = Copy-Report $report
  $tampered.recoverySettlements.surfaceObservations[1].blocked.confirmedOriginOperationIdSha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "origin-operation-ID hash" "I6 verification must reject recovery confirmation for a different origin operation."

  $tampered = Copy-Report $report
  $tampered.recoverySettlements.surfaceObservations = @($tampered.recoverySettlements.surfaceObservations | Select-Object -First 1)
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject recovery evidence missing the installed surface."

  $tampered = Copy-Report $report
  $tampered.recoverySettlements.surfaceObservations[0].safe.freshReconcile = $false
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject Safe recovery without fresh reconcile."

  $tampered = Copy-Report $report
  $tampered.recoverySettlements.surfaceObservations[0].indeterminate.stableCode = "SUBVERSIONR_REMOTE_WORKER_CRASHED"
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must not substitute worker crash for Indeterminate recovery."

  $tampered = Copy-Report $report
  $tampered.surfaces[1].remoteSvnAnonymous = $false
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject an installed surface without the runtime capability."

  $tampered = Copy-Report $report
  $tampered | Add-Member -NotePropertyName provisional -NotePropertyValue $true
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject compatibility or provisional evidence fields."

  $tampered = Copy-Report $report
  $tampered.verdict.claim = "svn://127.0.0.1/repo"
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject raw URL substitution for the exact claim."

  Write-Report $report $evidencePath
  Set-Content -LiteralPath $daemonPath -Value "tampered-daemon" -NoNewline
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "bind the exact file bytes" "I6 verification must reject candidate artifact tampering."

  Set-Content -LiteralPath $daemonPath -Value "daemon-I6-fixture" -NoNewline
  foreach ($toolBinding in @(
      @("svn", $svnPath, "svn-I6-fixture"),
      @("svnadmin", $svnadminPath, "svnadmin-I6-fixture"),
      @("svnserve", $svnservePath, "svnserve-I6-fixture"),
      @("svnserveLog", $fixtureLogPath, "fixture svnserve log`n")
    )) {
    Set-Content -LiteralPath $toolBinding[1] -Value "tampered-$($toolBinding[0])" -NoNewline
    Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "artifactBindings.$($toolBinding[0]) must bind the exact file bytes" "I6 verification must reject $($toolBinding[0]) hash drift."
    Set-Content -LiteralPath $toolBinding[1] -Value $toolBinding[2] -NoNewline
  }

  foreach ($probeBinding in @(
      @("packagedNativeProbe", $packagedNativeProbePath),
      @("packagedNegativeProbe", $packagedNegativeProbePath),
      @("packagedAuthzDeniedProbe", $packagedAuthzDeniedProbePath),
      @("packagedTrustRevokedProbe", $packagedTrustRevokedProbePath),
      @("packagedRecoveryBlockedProbe", $packagedRecoveryBlockedProbePath),
      @("packagedRecoverySafeProbe", $packagedRecoverySafeProbePath),
      @("packagedRecoveryIndeterminateProbe", $packagedRecoveryIndeterminateProbePath),
      @("packagedRedactionProbe", $packagedRedactionProbePath),
      @("raSvnFaultFixture", $raSvnFaultFixturePath),
      @("countingProxy", $countingProxyPath),
      @("installedStressProbe", $installedStressProbePath),
      @("installedNegativeProbe", $installedNegativeProbePath),
      @("installedAuthzDeniedProbe", $installedAuthzDeniedProbePath),
      @("installedTrustRevokedProbe", $installedTrustRevokedProbePath),
      @("installedRecoveryBlockedProbe", $installedRecoveryBlockedProbePath),
      @("installedRecoverySafeProbe", $installedRecoverySafeProbePath),
      @("installedRecoveryIndeterminateProbe", $installedRecoveryIndeterminateProbePath),
      @("installedRedactionProbe", $installedRedactionProbePath),
      @("installedLocalEventProbe", $installedLocalEventProbePath),
      @("installedVsixProbe", $installedVsixProbePath),
      @("packagedCompatibilityProbe", $packagedCompatibilityProbePath),
      @("installedExtensionHostProbe", $installedExtensionHostProbePath)
    )) {
    $tampered = Copy-Report $report
    $tampered.artifactBindings.($probeBinding[0]).sha256 = "0" * 64
    Write-Report $tampered $evidencePath
    Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "artifactBindings.$($probeBinding[0]) must bind the exact file bytes" "I6 verification must reject $($probeBinding[0]) hash drift."
  }

  Write-Report $report $evidencePath

  $externalDriverPath = Join-Path $artifactsRoot "external-probe.ps1"
  $externalPatchPath = Join-Path $artifactsRoot "external-ra-svn.patch"
  $externalPatchContractPath = Join-Path $artifactsRoot "external-ra-svn.contract.json"
  $externalSourceLockPath = Join-Path $artifactsRoot "external-sources.lock.json"
  Set-Content -LiteralPath $externalDriverPath -Value "throw 'external driver must never execute'" -NoNewline
  Set-Content -LiteralPath $externalPatchPath -Value "external patch" -NoNewline
  Set-Content -LiteralPath $externalPatchContractPath -Value '{"schemaVersion":1}' -NoNewline
  Set-Content -LiteralPath $externalSourceLockPath -Value '{"sources":[]}' -NoNewline
  $externalDriverArguments = Copy-ArgumentsWithValue $verifyArguments "-ProbeDriverPath" $externalDriverPath
  Assert-NativeCommandFailsContaining { & pwsh @externalDriverArguments } "exact source-controlled path" "I6 verification must reject an arbitrary external probe driver."
  $externalPatchArguments = Copy-ArgumentsWithValue $verifyArguments "-RaSvnOriginPatchPath" $externalPatchPath
  Assert-NativeCommandFailsContaining { & pwsh @externalPatchArguments } "exact source-controlled path" "I6 verification must reject an arbitrary external ra_svn patch."
  $externalPatchContractArguments = Copy-ArgumentsWithValue $verifyArguments "-RaSvnOriginContractPath" $externalPatchContractPath
  Assert-NativeCommandFailsContaining { & pwsh @externalPatchContractArguments } "exact source-controlled path" "I6 verification must reject an arbitrary external ra_svn patch contract."
  $externalSourceLockArguments = Copy-ArgumentsWithValue $verifyArguments "-NativeSourceLockPath" $externalSourceLockPath
  Assert-NativeCommandFailsContaining { & pwsh @externalSourceLockArguments } "exact source-controlled path" "I6 verification must reject an arbitrary native source lock."

  $runnerEvidencePath = Join-Path $runnerFixtureRoot "evidence.json"
  $runnerArguments = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $runScript,
    "-SubversionStageRoot", $artifactsRoot,
    "-VsixPath", $vsixPath,
    "-DaemonPath", $daemonPath,
    "-BridgePath", $bridgePath,
    "-CodeCliPath", $codeCliPath,
    "-ProbeDriverPath", $probeDriverPath,
    "-RaSvnOriginPatchPath", $patchPath,
    "-RaSvnOriginContractPath", $patchContractPath,
    "-NativeSourceLockPath", $sourceLockPath,
    "-ExpectedProductVersion", "0.3.0",
    "-FixtureRoot", $runnerFixtureRoot,
    "-EvidencePath", $runnerEvidencePath
  )
  $runnerExternalDriverArguments = Copy-ArgumentsWithValue $runnerArguments "-ProbeDriverPath" $externalDriverPath
  Assert-NativeCommandFailsContaining { & pwsh @runnerExternalDriverArguments } "exact source-controlled path" "I6 runner must reject an arbitrary external probe driver before execution."
  $runnerExternalPatchArguments = Copy-ArgumentsWithValue $runnerArguments "-RaSvnOriginPatchPath" $externalPatchPath
  Assert-NativeCommandFailsContaining { & pwsh @runnerExternalPatchArguments } "exact source-controlled path" "I6 runner must reject an arbitrary external ra_svn patch."
  $runnerExternalPatchContractArguments = Copy-ArgumentsWithValue $runnerArguments "-RaSvnOriginContractPath" $externalPatchContractPath
  Assert-NativeCommandFailsContaining { & pwsh @runnerExternalPatchContractArguments } "exact source-controlled path" "I6 runner must reject an arbitrary external ra_svn patch contract."
  $runnerExternalSourceLockArguments = Copy-ArgumentsWithValue $runnerArguments "-NativeSourceLockPath" $externalSourceLockPath
  Assert-NativeCommandFailsContaining { & pwsh @runnerExternalSourceLockArguments } "exact source-controlled path" "I6 runner must reject an arbitrary native source lock."

  $longRunnerFixtureRoot = Join-Path $allowedRunnerRoot ("x" * 120)
  $runnerLongFixtureArguments = Copy-ArgumentsWithValue $runnerArguments "-FixtureRoot" $longRunnerFixtureRoot
  Assert-NativeCommandFailsContaining {
    & pwsh @runnerLongFixtureArguments
  } "110-character Windows path budget" "I6 runner must reject a fixture root that exceeds the reviewed Windows path budget before fixture creation."

  New-FakeSubversionStage -Root $fakeStageRoot -NativeModulePath (Join-Path $repoRoot "scripts\native\SubversionR.Native.psm1") -SourceLockPath $sourceLockPath
  $fakeManifestPath = Join-Path $fakeStageRoot "subversionr-stage-manifest.json"
  $fakeManifest = Get-Content -Raw -LiteralPath $fakeManifestPath | ConvertFrom-Json
  $fakeManifest.arch = "arm64"
  $fakeManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fakeManifestPath -Encoding ascii
  $runnerFakeStageArguments = Copy-ArgumentsWithValue $runnerArguments "-SubversionStageRoot" $fakeStageRoot
  Assert-NativeCommandFailsContaining { & pwsh @runnerFakeStageArguments } "manifest architecture must be x64" "I6 runner must reject a false stage manifest before probe execution."

  $driverFixtureRoot = Join-Path $tempRoot "driver-fixture"
  New-Item -ItemType Directory -Force -Path $driverFixtureRoot | Out-Null
  $driverConfigPath = Join-Path $driverFixtureRoot "svnserve.conf"
  $driverAuthzPath = Join-Path $driverFixtureRoot "authz"
  $driverLogPath = Join-Path $driverFixtureRoot "svnserve.log"
  $driverPackagedAuthzWorkingCopyPath = Join-Path $driverFixtureRoot "packaged-authz-wc"
  $driverInstalledAuthzWorkingCopyPath = Join-Path $driverFixtureRoot "installed-authz-wc"
  New-Item -ItemType Directory -Force -Path $driverPackagedAuthzWorkingCopyPath, $driverInstalledAuthzWorkingCopyPath | Out-Null
  Set-Content -LiteralPath $driverConfigPath -Value "[general]`nanon-access = write`nauth-access = none`nauthz-db = authz`nrealm = SubversionR I6 Controlled Anonymous`n[sasl]`nuse-sasl = false" -NoNewline
  Set-Content -LiteralPath $driverAuthzPath -Value "[repo:/]`n* = rw" -NoNewline
  Set-Content -LiteralPath $driverLogPath -Value "fixture`n" -NoNewline
  $driverOutputPath = Join-Path $driverFixtureRoot "evidence.json"
  Set-Content -LiteralPath $driverOutputPath -Value '{"stale":true}' -NoNewline
  $driverArguments = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $probeDriverPath,
    "-RepositoryUrl", "svn://127.0.0.1:3690/repo/trunk",
    "-UnrelatedRepositoryUrl", "svn://127.0.0.1:3690/unrelated/trunk",
    "-FixtureRoot", $driverFixtureRoot,
    "-FixtureConfigPath", $driverConfigPath,
    "-FixtureAuthzPath", $driverAuthzPath,
    "-FixtureLogPath", $driverLogPath,
    "-PackagedAuthzWorkingCopyPath", $driverPackagedAuthzWorkingCopyPath,
    "-InstalledAuthzWorkingCopyPath", $driverInstalledAuthzWorkingCopyPath,
    "-SvnPath", $svnPath,
    "-SvnadminPath", $svnadminPath,
    "-SvnservePath", $svnservePath,
    "-SvnservePid", "12345",
    "-SvnserveStartTimeUtc", "2026-07-18T00:00:00.0000000Z",
    "-VsixPath", $vsixPath,
    "-DaemonPath", $daemonPath,
    "-BridgePath", $bridgePath,
    "-CodeCliPath", $codeCliPath,
    "-StageManifestPath", $stageManifestPath,
    "-RaSvnOriginPatchPath", $patchPath,
    "-RaSvnOriginContractPath", $patchContractPath,
    "-NativeSourceLockPath", $sourceLockPath,
    "-ExpectedProductVersion", "0.3.0",
    "-OutputPath", $driverOutputPath
  )
  Assert-NativeCommandFailsContaining { & pwsh @driverArguments } "VsixPath must be a valid VSIX ZIP archive" "I6 probe driver must reject a non-VSIX artifact before product execution."
  Assert-True (-not (Test-Path -LiteralPath $driverOutputPath)) "I6 probe driver must remove stale output before validation and must not write evidence on failure."

  $runnerText = Get-Content -Raw -LiteralPath $runScript
  foreach ($requiredText in @(
      'bin\svn.exe',
      'bin\svnadmin.exe',
      'bin\svnserve.exe',
      'source-built Apache Subversion 1.14.5',
      '--no-auth-cache',
      'anon-access = write',
      'auth-access = none',
      'use-sasl = false',
      'Create I6 unrelated fixture repository',
      'The I6 unrelated fixture must have a distinct repository UUID.',
      '-UnrelatedRepositoryUrl $unrelatedRepositoryUrl',
      '[string]$ProbeDriverPath',
      'Assert-SubversionStageForBridge',
      '-ExpectedArch "x64"',
      '-ExpectedConfiguration "Release"',
      'scripts\release\probe-m8-i6-svn-anonymous.ps1',
      'native\patches\subversion-1.14.5\ra-svn-authority.patch',
      'native\sources.lock.json',
      'verify-m8-i6-svn-anonymous-evidence.ps1'
    )) {
    Assert-True ($runnerText.Contains($requiredText)) "I6 runner must retain controlled fixture/probe contract text '$requiredText'."
  }
  Assert-True (-not $runnerText.Contains("unsupportedAfterWorker")) "I6 runner must not accept the I3-I5 transport-boundary result."

  $driverText = Get-Content -Raw -LiteralPath $probeDriverPath
  foreach ($requiredText in @(
      'probe-vscode-packaged-native.mjs',
      'probe-m8-i6-packaged-native.mjs',
      'probe-m8-i6-packaged-negative.mjs',
      'probe-m8-i6-packaged-authz-denied.mjs',
      'probe-m8-i6-packaged-stalled-read.mjs',
      'probe-m8-i6-packaged-deadline.mjs',
      'probe-m8-i6-packaged-cancellation.mjs',
      'probe-m8-i6-packaged-recovery-blocked.mjs',
      'serve-m8-i6-ra-svn-fault-fixture.mjs',
      'serve-m8-i6-counting-proxy.mjs',
      'probe-m8-i6-installed-stress.ps1',
      'probe-m8-i6-installed-negative.ps1',
      'probe-m8-i6-installed-authz-denied.ps1',
      'probe-m8-i6-installed-stalled-read.ps1',
      'probe-m8-i6-installed-deadline.ps1',
      'probe-m8-i6-installed-cancellation.ps1',
      'probe-m8-i6-installed-recovery-blocked.ps1',
      'probe-m8-i6-installed-local-event-zero-network.ps1',
      'probe-m8-i6-installed-vsix.ps1',
      'test-vscode-installed-extension-host.ps1',
      'extension/resources/backend/win32-x64/subversionr-daemon.exe',
      'extension/resources/backend/win32-x64/subversionr_svn_bridge.dll',
      '$packagedVsixDaemonPath = Resolve-RequiredFile',
      '$packagedVsixBridgePath = Resolve-RequiredFile',
      '"--daemon-path", $surfaceDaemonPath',
      '"--bridge-path", $surfaceBridgePath',
      '"--expected-revision", "3"',
      '"-ExpectedRevision", "3"',
      '[int]$cellReport.checkoutRevision -eq 3',
      'The extracted packaged VSIX daemon must match DaemonPath.',
      'The extracted packaged VSIX bridge must match BridgePath.',
      'SUBVERSIONR_M8_I6_OBSERVATION_BLOCKED',
      'the four packaged-native fault cells',
      'four installed malicious-root/SASL-only/greeting-stall/connected-stall fault cells',
      'packaged/installed authz-denied, stalled-mid-read, absolute-deadline, explicit-cancellation, trust-revoked, Safe recovery, Indeterminate recovery, durable recovery-blocked, blocked-lane unrelated-repository, and real checkout-bound redaction cells',
      'installed real-watcher local-event zero-network cell',
      'installed 100+1 single-Extension-Host residue stress',
      'remaining cross-surface blackhole-connect, worker-crash, and daemon-disconnect cells',
      'issue #136',
      'Remove-Item -LiteralPath $outputResolved -Force'
    )) {
    Assert-True ($driverText.Contains($requiredText)) "I6 probe driver must retain real-artifact/fail-closed contract text '$requiredText'."
  }
  Assert-True (-not $driverText.Contains('publicClaimEligible = $true')) "I6 probe driver must not synthesize a passing public claim while the installed operation harness is absent."
  foreach ($requiredObservationText in @(
      'Register-CimIndicationEvent',
      'Get-EventSubscriber',
      'Win32_ProcessStartTrace',
      'TIME_CREATED',
      'Complete-ProcessStartEventDrain',
      'Get-PackagedNegativeProcessObservation',
      'Get-InstalledNegativeProcessObservation',
      '"i6n\$([Guid]',
      'installedNegativeWorkRoot.Length -le 120',
      '"-FixtureRoot", $scenarioWorkRoot',
      '"-CheckoutPath", (Join-Path $scenarioWorkRoot "checkout")',
      'The installed-negative short work root remained after cleanup.',
      'Stop-ControlledSvnserve',
      'The controlled svnserve identity changed before the stalled-mid-read phase.',
      'ra_svn fault fixture did not bind the required port.',
      'The packaged-native and installed VSIX stalled-mid-read observation set was incomplete.',
      'The stalled-mid-read short work root remained after cleanup.',
      'The packaged-native and installed VSIX cancellation observation set was incomplete.',
      'The cancellation short work root remained after cleanup.',
      'abort-signal-after-greeting',
      'wireSettlementObserved',
      'Get-ZeroWorkerProcessObservation',
      'Start-CountingProxy',
      'The unrelated repository must have a distinct repository UUID.',
      'blockedJournalBytesSha256BeforeUnrelated',
      'unrelatedCheckoutRevision -eq 2',
      'The packaged-native and installed VSIX unrelated-repository observation set was incomplete.',
      'probe-m8-i6-packaged-redaction.mjs',
      'probe-m8-i6-installed-redaction.ps1',
      'inputContainedRawUrl',
      'function Get-TextSha256',
      'rawUrlCount',
      'maxDiagnosticBytes',
      'The packaged-native and installed VSIX redaction observation set was incomplete.',
      'The packaged-native and installed VSIX redaction privacy set was incomplete.',
      'probe-m8-i6-packaged-recovery-indeterminate.mjs',
      'probe-m8-i6-installed-recovery-indeterminate.ps1',
      'Invoke-BoundedProcessWithWorkingCopyReadFault',
      'Get-RecoveryIndeterminateProcessObservation',
      'SetFileSecurity',
      'fixture file must be owned by the current Windows identity.',
      '[System.Security.AccessControl.FileSystemRights]::ReadData',
      '[System.Security.AccessControl.FileSystemRights]::ReadAttributes',
      '[System.Security.AccessControl.FileSystemRights]::ReadExtendedAttributes',
      'working-copy database security descriptor was not restored byte-for-byte.',
      'The packaged-native and installed VSIX recovery-indeterminate observation set was incomplete.',
      'The packaged-native and installed VSIX Indeterminate settlement set was incomplete.',
      '$proxyFinalState = Stop-CountingProxy $countingProxy',
      'The stopped installed local-event counting proxy changed final counter',
      'Get-CimProcessSnapshot',
      'A packaged-negative probe/daemon/worker identity remained alive at settlement.',
      'The exited packaged-negative worker retained live orphan descendants.',
      'networkAttempts = $networkAttempts',
      'networkConnections = $networkConnections',
      'workerDescendantsAfter = [int]$processObservation.workerDescendantsAfter',
      'fixtureCliInvocations = [int]$processObservation.fixtureCliInvocations',
      'product surface invoked a fixture CLI',
      'Unregister-Event',
      'Remove-Event'
    )) {
    Assert-True ($driverText.Contains($requiredObservationText)) "Packaged-negative evidence must retain measured process/network observation text '$requiredObservationText'."
  }
  Assert-True (
    $driverText -cmatch '(?s)try\s*\{\s*if \(\$null -ne \$unrelatedProxy\).*?\}\s*finally\s*\{\s*if \(\$null -ne \$faultFixture\) \{ Stop-FaultFixture'
  ) "The unrelated counting proxy cleanup must not prevent command-stall fixture cleanup."
  foreach ($forbiddenObservationText in @(
      'Get-WmiObject',
      'networkAttempts = 1',
      '"-FixtureRoot", (Join-Path $scenarioRoot "extension-host")',
      'workerDescendantsAfter = 0'
    )) {
    Assert-True (-not $driverText.Contains($forbiddenObservationText)) "Packaged-negative evidence must not contain synthetic/fallback observation '$forbiddenObservationText'."
  }
  $negativeSubscriptionIndex = $driverText.IndexOf('Register-CimIndicationEvent', [System.StringComparison]::Ordinal)
  $negativeSubscriberLookupIndex = $driverText.IndexOf('$matchingSubscribers = @(Get-EventSubscriber', $negativeSubscriptionIndex, [System.StringComparison]::Ordinal)
  $negativeProbeLaunchIndex = $driverText.IndexOf('$negativeResult = Invoke-BoundedProcess', [System.StringComparison]::Ordinal)
  $negativeFinalDrainIndex = $driverText.IndexOf('Complete-ProcessStartEventDrain', $negativeProbeLaunchIndex, [System.StringComparison]::Ordinal)
  $negativeUnregisterIndex = $driverText.IndexOf('Unregister-Event', $negativeFinalDrainIndex, [System.StringComparison]::Ordinal)
  Assert-True (
    $negativeSubscriptionIndex -ge 0 -and
    $negativeSubscriberLookupIndex -gt $negativeSubscriptionIndex -and
    $negativeProbeLaunchIndex -gt $negativeSubscriberLookupIndex -and
    $negativeFinalDrainIndex -gt $negativeProbeLaunchIndex -and
    $negativeUnregisterIndex -gt $negativeFinalDrainIndex
  ) "Packaged-negative process observation must subscribe before launch, drain after completion, and then unregister."
  $installedNegativeLaunchIndex = $driverText.IndexOf('$installedNegativeResult = Invoke-BoundedProcess', [System.StringComparison]::Ordinal)
  $installedNegativeSubscriptionIndex = $driverText.LastIndexOf('Register-CimIndicationEvent', $installedNegativeLaunchIndex, [System.StringComparison]::Ordinal)
  $installedNegativeDrainIndex = $driverText.IndexOf('Complete-ProcessStartEventDrain', $installedNegativeLaunchIndex, [System.StringComparison]::Ordinal)
  $installedNegativeObservationIndex = $driverText.IndexOf('Get-InstalledNegativeProcessObservation', $installedNegativeDrainIndex, [System.StringComparison]::Ordinal)
  $installedNegativeUnregisterIndex = $driverText.IndexOf('Unregister-Event', $installedNegativeObservationIndex, [System.StringComparison]::Ordinal)
  Assert-True (
    $installedNegativeSubscriptionIndex -ge 0 -and
    $installedNegativeLaunchIndex -gt $installedNegativeSubscriptionIndex -and
    $installedNegativeDrainIndex -gt $installedNegativeLaunchIndex -and
    $installedNegativeObservationIndex -gt $installedNegativeDrainIndex -and
    $installedNegativeUnregisterIndex -gt $installedNegativeObservationIndex
  ) "Installed-negative process observation must subscribe before launch, drain and measure after completion, and then unregister."

  $driverTokens = $null
  $driverParseErrors = $null
  $driverAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $probeDriverPath,
    [ref]$driverTokens,
    [ref]$driverParseErrors
  )
  Assert-True ($driverParseErrors.Count -eq 0) "I6 probe driver must parse after packaged-negative observation changes."
  $observationHelpers = @(
    "Get-DescendantProcessIds",
    "Get-ProcessSnapshotStartFileTime",
    "Get-RecordedProcessDescendantStarts",
    "Get-PackagedNegativeProcessObservation",
    "Get-InstalledNegativeProcessObservation",
    "Set-ExactAuthzAtomically",
    "Get-SvnserveAuthzObservation",
    "Get-ExactFileSecurityDescriptor",
    "Set-ExactCurrentUserReadDeny",
    "Restore-ExactFileDacl",
    "Wait-CommandBarrier",
    "Invoke-BoundedProcessWithWorkingCopyReadFault",
    "Get-RecoveryIndeterminateProcessObservation"
  )
  $observationHelperSources = foreach ($functionName in $observationHelpers) {
    $matches = @($driverAst.FindAll({
          param($node)
          $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -ceq $functionName
        }, $true))
    Assert-True ($matches.Count -eq 1) "I6 probe driver must define exactly one $functionName helper."
    $matches[0].Extent.Text
  }
  $readFaultHelper = $observationHelperSources[[Array]::IndexOf($observationHelpers, "Invoke-BoundedProcessWithWorkingCopyReadFault")]
  $faultFlagIndex = $readFaultHelper.IndexOf('$faultApplied = $true', [System.StringComparison]::Ordinal)
  $faultMutationIndex = $readFaultHelper.IndexOf('Set-ExactCurrentUserReadDeny $descriptor $Context', [System.StringComparison]::Ordinal)
  Assert-True ($faultFlagIndex -ge 0 -and $faultMutationIndex -gt $faultFlagIndex) "Packaged recovery-indeterminate cleanup flag must be armed before the DACL mutation."
  Invoke-Expression ($observationHelperSources -join "`n`n")

  $authzAtomicPath = Join-Path $tempRoot "authz-atomic"
  Set-Content -LiteralPath $authzAtomicPath -Value "old" -NoNewline
  Set-ExactAuthzAtomically $authzAtomicPath "[repo:/]`n* = rw"
  Assert-Equal "[repo:/]`n* = rw" (Get-Content -Raw -LiteralPath $authzAtomicPath) "Authz control must settle exact UTF-8 bytes."
  Assert-Equal 0 @(Get-ChildItem -LiteralPath $tempRoot -Filter ".subversionr-authz-*.tmp" -File).Count "Authz control must leave no replacement residue."

  $authzLogPath = Join-Path $tempRoot "svnserve-authz.log"
  Set-Content -LiteralPath $authzLogPath -Value @(
    "1 2026-07-18T00:00:00Z 127.0.0.1 - repo open 2 cap=(depth) /denied SVN/1.14.5 -",
    "1 2026-07-18T00:00:00Z 127.0.0.1 - repo ERR - 0 170001 Authorization failed"
  )
  $authzNetwork = Get-SvnserveAuthzObservation $authzLogPath 0 "Controlled authz test"
  Assert-Equal 1 $authzNetwork.networkAttempts "Authz log observation must derive one denial attempt from the actual line count."
  Assert-Equal 1 $authzNetwork.networkConnections "Authz log observation must derive one connection from the actual open-line count."
  Assert-Equal "command" $authzNetwork.networkProgress "Authz log observation must prove command-stage progress."

  $probeStart = [pscustomobject]@{
    processId = 100L; parentProcessId = 10L; processName = "Code.exe"; eventFileTime = 1000L
  }
  $daemonStart = [pscustomobject]@{
    processId = 200L; parentProcessId = 100L; processName = "subversionr-daemon.exe"; eventFileTime = 2000L
  }
  $workerStart = [pscustomobject]@{
    processId = 300L; parentProcessId = 200L; processName = "subversionr-daemon.exe"; eventFileTime = 3000L
  }
  $measuredBaseline = Get-PackagedNegativeProcessObservation `
    @($probeStart, $daemonStart, $workerStart) 100L "Code.exe" "subversionr-daemon.exe" @()
  Assert-Equal 0 $measuredBaseline.workerDescendantsAfter "Packaged-negative baseline must derive zero descendants from an empty settlement snapshot."
  Assert-Equal 0 $measuredBaseline.fixtureCliInvocations "Packaged-negative baseline must derive zero fixture CLI starts from subscribed process events."

  foreach ($fixtureCliStart in @(
      [pscustomobject]@{ processId = 350L; parentProcessId = 100L; processName = "svn.exe"; eventFileTime = 3500L },
      [pscustomobject]@{ processId = 351L; parentProcessId = 200L; processName = "svnadmin.exe"; eventFileTime = 3501L },
      [pscustomobject]@{ processId = 352L; parentProcessId = 300L; processName = "svnserve.exe"; eventFileTime = 3502L }
    )) {
    $measuredFixtureCli = Get-PackagedNegativeProcessObservation `
      @($probeStart, $daemonStart, $workerStart, $fixtureCliStart) `
      100L "Code.exe" "subversionr-daemon.exe" @()
    Assert-Equal 1 $measuredFixtureCli.fixtureCliInvocations "Packaged-negative process evidence must count fixture CLI starts under every product ancestor."
  }

  $unexpectedDescendant = [pscustomobject]@{
    processId = 400L; parentProcessId = 300L; processName = "unexpected.exe"; eventFileTime = 4000L
  }
  $unexpectedGrandchild = [pscustomobject]@{
    processId = 401L; parentProcessId = 400L; processName = "unexpected-grandchild.exe"; eventFileTime = 4001L
  }
  Assert-Equal 2 @(
    Get-RecordedProcessDescendantStarts `
      @($probeStart, $daemonStart, $workerStart, $unexpectedDescendant, $unexpectedGrandchild) `
      300L
  ).Count "Packaged-negative event ancestry must traverse child and grandchild starts."
  $settledDescendantObservation = Get-PackagedNegativeProcessObservation `
    @($probeStart, $daemonStart, $workerStart, $unexpectedDescendant, $unexpectedGrandchild) `
    100L "Code.exe" "subversionr-daemon.exe" `
    @()
  Assert-Equal 0 $settledDescendantObservation.workerDescendantsAfter "Exited Windows helper descendants must not be reported as settlement residue."

  $reusedWorkerPid = [pscustomobject]@{
    processId = 300L; parentProcessId = 999L; processName = "reused.exe"; eventFileTime = 5000L
  }
  Assert-ScriptThrowsContaining {
    Get-PackagedNegativeProcessObservation `
      @($probeStart, $daemonStart, $workerStart, $reusedWorkerPid) `
      100L "Code.exe" "subversionr-daemon.exe" `
      @()
  } "worker PID was reused" "Packaged-negative observation must reject worker PID reuse."

  Assert-ScriptThrowsContaining {
    Get-PackagedNegativeProcessObservation `
      @($probeStart, $daemonStart, $workerStart) `
      100L "Code.exe" "subversionr-daemon.exe" `
      @([pscustomobject]@{
          ProcessId = 300L; ParentProcessId = 200L; CreationDate = [DateTime]::FromFileTimeUtc(2900L)
        })
  } "worker identity remained alive" "Packaged-negative settlement must reject the live recorded worker identity."

  $reusedSettlement = Get-PackagedNegativeProcessObservation `
    @($probeStart, $daemonStart, $workerStart) `
    100L "Code.exe" "subversionr-daemon.exe" `
    @([pscustomobject]@{
        ProcessId = 300L; ParentProcessId = 999L; CreationDate = [DateTime]::FromFileTimeUtc(3100L)
      })
  Assert-Equal 0 $reusedSettlement.workerDescendantsAfter "Packaged-negative settlement must allow a later process to reuse the recorded worker PID."

  $orphanSnapshot = @([pscustomobject]@{
      ProcessId = 401L; ParentProcessId = 400L; CreationDate = [DateTime]::FromFileTimeUtc(3900L)
    })
  Assert-ScriptThrowsContaining {
    Get-PackagedNegativeProcessObservation `
      @($probeStart, $daemonStart, $workerStart, $unexpectedDescendant, $unexpectedGrandchild) `
      100L "Code.exe" "subversionr-daemon.exe" `
      $orphanSnapshot
  } "live orphan descendants" "Packaged-negative settlement must bind a live orphan to recorded start ancestry."

  $reusedDescendantSettlement = Get-PackagedNegativeProcessObservation `
    @($probeStart, $daemonStart, $workerStart, $unexpectedDescendant, $unexpectedGrandchild) `
    100L "Code.exe" "subversionr-daemon.exe" `
    @([pscustomobject]@{
        ProcessId = 401L; ParentProcessId = 999L; CreationDate = [DateTime]::FromFileTimeUtc(4100L)
      })
  Assert-Equal 0 $reusedDescendantSettlement.workerDescendantsAfter "Packaged-negative settlement must allow a later process to reuse a recorded descendant PID."

  $installedProbeStart = [pscustomobject]@{
    processId = 500L; parentProcessId = 10L; processName = "pwsh.exe"; eventFileTime = 5000L
  }
  $codeStart = [pscustomobject]@{
    processId = 501L; parentProcessId = 500L; processName = "Code.exe"; eventFileTime = 5100L
  }
  $extensionHostStart = [pscustomobject]@{
    processId = 502L; parentProcessId = 501L; processName = "Code.exe"; eventFileTime = 5200L
  }
  $installedDaemonStart = [pscustomobject]@{
    processId = 503L; parentProcessId = 502L; processName = "subversionr-daemon.exe"; eventFileTime = 5300L
  }
  $installedWorkerStart = [pscustomobject]@{
    processId = 504L; parentProcessId = 503L; processName = "subversionr-daemon.exe"; eventFileTime = 5400L
  }
  $installedMeasuredBaseline = Get-InstalledNegativeProcessObservation `
    -AllEvents @($installedProbeStart, $codeStart, $extensionHostStart, $installedDaemonStart, $installedWorkerStart) `
    -ProbePid 500L -ExpectedProbeProcessName "pwsh.exe" -ExpectedDaemonProcessName "subversionr-daemon.exe" `
    -ForbiddenFixtureProcessNames @("svn.exe", "svnadmin.exe", "svnserve.exe") -SettlementSnapshot @()
  Assert-Equal 0 $installedMeasuredBaseline.workerDescendantsAfter "Installed-negative baseline must derive zero descendants from the settlement snapshot."
  Assert-Equal 0 $installedMeasuredBaseline.fixtureCliInvocations "Installed-negative baseline must derive zero fixture CLI invocations from process events."
  Assert-ScriptThrowsContaining {
    Get-InstalledNegativeProcessObservation `
      -AllEvents @($installedProbeStart, $codeStart, $extensionHostStart, $installedDaemonStart, $installedWorkerStart) `
      -ProbePid 500L -ExpectedProbeProcessName "pwsh.exe" -ExpectedDaemonProcessName "subversionr-daemon.exe" `
      -ForbiddenFixtureProcessNames @("svn.exe", "svnadmin.exe", "svnserve.exe") `
      -SettlementSnapshot @([pscustomobject]@{
          ProcessId = 504L; ParentProcessId = 503L; CreationDate = [DateTime]::FromFileTimeUtc(5350L)
        })
  } "remained alive at settlement" "Installed-negative settlement must reject the live recorded worker identity."
  $installedReusedSettlement = Get-InstalledNegativeProcessObservation `
    -AllEvents @($installedProbeStart, $codeStart, $extensionHostStart, $installedDaemonStart, $installedWorkerStart) `
    -ProbePid 500L -ExpectedProbeProcessName "pwsh.exe" -ExpectedDaemonProcessName "subversionr-daemon.exe" `
    -ForbiddenFixtureProcessNames @("svn.exe", "svnadmin.exe", "svnserve.exe") `
    -SettlementSnapshot @([pscustomobject]@{
        ProcessId = 504L; ParentProcessId = 999L; CreationDate = [DateTime]::FromFileTimeUtc(5450L)
      })
  Assert-Equal 0 $installedReusedSettlement.workerDescendantsAfter "Installed-negative settlement must allow later PID reuse."

  foreach ($fixtureCliStart in @(
      [pscustomobject]@{ processId = 505L; parentProcessId = 502L; processName = "svn.exe"; eventFileTime = 5500L },
      [pscustomobject]@{ processId = 506L; parentProcessId = 503L; processName = "svnadmin.exe"; eventFileTime = 5501L },
      [pscustomobject]@{ processId = 507L; parentProcessId = 504L; processName = "svnserve.exe"; eventFileTime = 5502L }
    )) {
    $measuredFixtureCli = Get-InstalledNegativeProcessObservation `
      -AllEvents @($installedProbeStart, $codeStart, $extensionHostStart, $installedDaemonStart, $installedWorkerStart, $fixtureCliStart) `
      -ProbePid 500L -ExpectedProbeProcessName "pwsh.exe" -ExpectedDaemonProcessName "subversionr-daemon.exe" `
      -ForbiddenFixtureProcessNames @("svn.exe", "svnadmin.exe", "svnserve.exe") -SettlementSnapshot @()
    Assert-Equal 1 $measuredFixtureCli.fixtureCliInvocations "Installed-negative process evidence must count fixture CLI starts under every product ancestor."
  }

  $installedNegativeProbeText = Get-Content -Raw -LiteralPath $installedNegativeProbePath
  foreach ($requiredText in @(
      'subversionr.diagnostics.installedSvnAnonymousNegativeReport',
      'SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_NEGATIVE_REPORT_TOKEN',
      'maliciousRoot',
      'saslOnly',
      'greetingStall',
      'connectedStall',
      'SUBVERSIONR_INSTALLED_I6_NEGATIVE_OPERATION_ID',
      'SUBVERSIONR_REMOTE_WORKER_TIMED_OUT',
      'SUBVERSIONR_REMOTE_RECOVERY_BLOCKED',
      'operationDeadlineExceeded',
      'remoteRecoveryBlocked',
      'Get-Sha256 $installedDaemonPath',
      'Get-Sha256 $installedBridgePath',
      'Get-TemporaryRootCount $remoteWorkersRoot',
      'Read-CheckoutJournal $remoteStateRoot',
      'Get-StringSha256 $checkoutResolved',
      'installed checkout stall recovery entry',
      'Wait-CandidateProcessAbsent $installedDaemonPath'
    )) {
    Assert-True ($installedNegativeProbeText.Contains($requiredText)) "Installed-negative probe must retain real-candidate contract text '$requiredText'."
  }
  foreach ($forbiddenText in @('workerDescendantsAfter = 0', 'Get-WmiObject')) {
    Assert-True (-not $installedNegativeProbeText.Contains($forbiddenText)) "Installed-negative probe must not synthesize or fall back through '$forbiddenText'."
  }
  $installedNegativeTokens = $null
  $installedNegativeParseErrors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile(
    $installedNegativeProbePath,
    [ref]$installedNegativeTokens,
    [ref]$installedNegativeParseErrors
  )
  Assert-True ($installedNegativeParseErrors.Count -eq 0) "Installed-negative probe must parse."

  $contractText = Get-Content -Raw -LiteralPath $contractPath
  Assert-True ($contractText.Contains('under `target/i6-evidence`')) "I6 contract must document the reviewed short Windows fixture root."
  Assert-True ($contractText.Contains('baseline by PID plus creation time')) "I6 contract must document exact fixture-server baseline identity binding."
  Assert-True ($contractText.Contains('later Windows PID reuse is not reported as residue')) "I6 contract must distinguish PID reuse from live process residue."
  foreach ($requiredText in @(
      "Fixture startup or a direct bridge/unit probe does not satisfy the",
      "SVN_REMOTE_STATUS_AUTH_FAILED",
      "positive operation matrix",
      "separate, ordered",
      "localEventZeroNetwork",
      "100 checkout cycles",
      "checkout-stall probes establish only",
      "They do not satisfy the",
      "same-session local snapshot",
      "target/i6r",
      "monotonic clock",
      "target/i6d",
      "command-stall",
      "may not be represented as"
    )) {
    Assert-True ($contractText.Contains($requiredText)) "I6 evidence contract must retain fail-closed boundary '$requiredText'."
  }
  $schema = Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Json
  Assert-Equal "subversionr.release.m8-i6-svn-anonymous.win32-x64.v1" $schema.properties.schema.const "I6 JSON schema must bind the exact evidence schema."
  Assert-Equal "False" ([string]$schema.additionalProperties) "I6 JSON schema must reject unknown top-level fields."
  $packageJson = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "package.json") | ConvertFrom-Json
  Assert-True ($packageJson.scripts."release:test-m8-i6-svn-anonymous-evidence-scripts".Contains("m8-i6-ra-svn-fault-fixture.tests.mjs")) "PR Fast I6 script tests must execute the controlled ra_svn fault fixture tests."
  Assert-True ($packageJson.scripts."release:test-m8-i6-svn-anonymous-evidence-scripts".Contains("m8-i6-counting-proxy.tests.mjs")) "PR Fast I6 script tests must execute the transparent counting proxy tests."
  Assert-True ($packageJson.scripts."release:test-m8-i6-svn-anonymous-evidence-scripts".Contains("m8-i6-packaged-negative.tests.mjs")) "PR Fast I6 script tests must execute the packaged-native negative probe tests."
  Assert-True ($packageJson.scripts."release:test-m8-i6-svn-anonymous-evidence-scripts".Contains("m8-i6-packaged-authz-denied.tests.mjs")) "PR Fast I6 script tests must execute the packaged-native authz-denied probe tests."
  Assert-True ($packageJson.scripts."release:test-m8-i6-svn-anonymous-evidence-scripts".Contains("m8-i6-packaged-stalled-read.tests.mjs")) "PR Fast I6 script tests must execute the packaged-native stalled-mid-read probe tests."
  Assert-True ($packageJson.scripts."release:test-m8-i6-svn-anonymous-evidence-scripts".Contains("m8-i6-packaged-deadline.tests.mjs")) "PR Fast I6 script tests must execute the packaged-native deadline probe tests."
  Assert-True ($packageJson.scripts."release:test-m8-i6-svn-anonymous-evidence-scripts".Contains("m8-i6-packaged-cancellation.tests.mjs")) "PR Fast I6 script tests must execute the packaged-native cancellation probe tests."
  Assert-True ($packageJson.scripts."release:test-m8-i6-svn-anonymous-evidence-scripts".Contains("m8-i6-packaged-trust-revoked.tests.mjs")) "PR Fast I6 script tests must execute the packaged-native trust-revoked probe tests."
  Assert-True ($packageJson.scripts."release:test-m8-i6-svn-anonymous-evidence-scripts".Contains("m8-i6-packaged-recovery-blocked.tests.mjs")) "PR Fast I6 script tests must execute the packaged-native recovery-blocked probe tests."
  Assert-True ($packageJson.scripts."release:test-m8-i6-svn-anonymous-evidence-scripts".Contains("m8-i6-packaged-redaction.tests.mjs")) "PR Fast I6 script tests must execute the packaged-native redaction probe tests."
  Assert-True ($packageJson.scripts."release:test-m8-i6-svn-anonymous-evidence-scripts".Contains("m8-i6-installed-stress-scripts.tests.ps1")) "PR Fast I6 script tests must execute the installed 100+1 stress probe tests."
  Assert-True ($packageJson.scripts."release:test-m8-i6-svn-anonymous-evidence-scripts".Contains("m8-i6-installed-authz-denied-scripts.tests.ps1")) "PR Fast I6 script tests must execute the installed authz-denied probe contract tests."
  Assert-True ($packageJson.scripts."release:test-m8-i6-svn-anonymous-evidence-scripts".Contains("m8-i6-installed-stalled-read-scripts.tests.ps1")) "PR Fast I6 script tests must execute the installed stalled-mid-read probe contract tests."
  Assert-True ($packageJson.scripts."release:test-m8-i6-svn-anonymous-evidence-scripts".Contains("m8-i6-installed-deadline-scripts.tests.ps1")) "PR Fast I6 script tests must execute the installed deadline probe contract tests."
  Assert-True ($packageJson.scripts."release:test-m8-i6-svn-anonymous-evidence-scripts".Contains("m8-i6-installed-cancellation-scripts.tests.ps1")) "PR Fast I6 script tests must execute the installed cancellation probe contract tests."
  Assert-True ($packageJson.scripts."release:test-m8-i6-svn-anonymous-evidence-scripts".Contains("m8-i6-installed-trust-revoked-scripts.tests.ps1")) "PR Fast I6 script tests must execute the installed trust-revoked probe contract tests."
  Assert-True ($packageJson.scripts."release:test-m8-i6-svn-anonymous-evidence-scripts".Contains("m8-i6-installed-recovery-blocked-scripts.tests.ps1")) "PR Fast I6 script tests must execute the installed recovery-blocked probe contract tests."
  Assert-True ($packageJson.scripts."release:test-m8-i6-svn-anonymous-evidence-scripts".Contains("m8-i6-installed-redaction-scripts.tests.ps1")) "PR Fast I6 script tests must execute the installed redaction probe contract tests."
  Assert-True ($packageJson.scripts."release:test-m8-i6-svn-anonymous-evidence-scripts".Contains("m8-i6-installed-local-event-zero-network-scripts.tests.ps1")) "PR Fast I6 script tests must execute the installed local-event zero-network probe contract tests."

  Write-Host "M8 I6 svn anonymous evidence script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $fakeStageRoot -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $runnerFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

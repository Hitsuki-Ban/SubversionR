$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$verifyScript = Join-Path $repoRoot "scripts\release\verify-m8-i6-svn-anonymous-evidence.ps1"
$runScript = Join-Path $repoRoot "scripts\release\run-m8-i6-svn-anonymous-evidence.ps1"
$contractPath = Join-Path $repoRoot "docs\release\m8-i6-svn-anonymous-evidence-contract.md"
$schemaPath = Join-Path $repoRoot "docs\release\m8-i6-svn-anonymous-evidence.v1.schema.json"
$probeDriverPath = Join-Path $repoRoot "scripts\release\probe-m8-i6-svn-anonymous.ps1"
$packagedNativeProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-packaged-native.mjs"
$installedVsixProbePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-vsix.ps1"
$packagedCompatibilityProbePath = Join-Path $repoRoot "scripts\release\probe-vscode-packaged-native.mjs"
$installedExtensionHostProbePath = Join-Path $repoRoot "scripts\release\test-vscode-installed-extension-host.ps1"
$patchPath = Join-Path $repoRoot "native\patches\subversion-1.14.5\ra-svn-authority.patch"
$patchContractPath = Join-Path $repoRoot "native\patches\subversion-1.14.5\ra-svn-authority.contract.json"
$sourceLockPath = Join-Path $repoRoot "native\sources.lock.json"
$tempRoot = Join-Path $repoRoot "target\tests\m8-i6-svn-anonymous-evidence\$([Guid]::NewGuid().ToString('N'))"
$fakeStageRoot = Join-Path $repoRoot ".cache\tests\m8-i6-svn-anonymous-evidence\$([Guid]::NewGuid().ToString('N'))"
$runnerFixtureRoot = Join-Path $repoRoot "target\release-evidence\m8-i6-svn-anonymous\script-test-$([Guid]::NewGuid().ToString('N'))"

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

function New-NegativeCell([string]$Cell, [string]$StableCode, [string]$Reason) {
  return [ordered]@{
    cell = $Cell
    status = "passed"
    stableCode = $StableCode
    reason = $Reason
    surfaces = @("packaged-native", "installed-vsix-extension-host")
    followupNetworkContacts = 0
    workerDescendantsAfter = 0
    temporaryRootsAfter = 0
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
  foreach ($path in @($verifyScript, $runScript, $probeDriverPath, $packagedNativeProbePath, $installedVsixProbePath, $packagedCompatibilityProbePath, $installedExtensionHostProbePath, $contractPath, $schemaPath, $patchPath, $patchContractPath, $sourceLockPath)) {
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

  $artifactBindings = [ordered]@{
    vsix = New-ArtifactBinding "vsix" $vsixPath
    daemon = New-ArtifactBinding "daemon" $daemonPath
    bridge = New-ArtifactBinding "bridge" $bridgePath
    stageManifest = New-ArtifactBinding "subversion-stage-manifest" $stageManifestPath
    probeDriver = New-ArtifactBinding "i6-probe-driver" $probeDriverPath
    packagedNativeProbe = New-ArtifactBinding "i6-packaged-native-probe" $packagedNativeProbePath
    installedVsixProbe = New-ArtifactBinding "i6-installed-vsix-probe" $installedVsixProbePath
    packagedCompatibilityProbe = New-ArtifactBinding "packaged-native-compatibility-probe" $packagedCompatibilityProbePath
    installedExtensionHostProbe = New-ArtifactBinding "installed-extension-host-probe" $installedExtensionHostProbePath
    raSvnOriginPatch = New-ArtifactBinding "ra-svn-origin-patch" $patchPath
    raSvnOriginContract = New-ArtifactBinding "ra-svn-origin-contract" $patchContractPath
    nativeSourceLock = New-ArtifactBinding "native-source-lock" $sourceLockPath
    svn = New-ArtifactBinding "fixture-svn" $svnPath
    svnadmin = New-ArtifactBinding "fixture-svnadmin" $svnadminPath
    svnserve = New-ArtifactBinding "fixture-svnserve" $svnservePath
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
      (New-NegativeCell "maliciousRoot" "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH" "crossAuthorityRejected"),
      (New-NegativeCell "saslOnly" "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED" "remoteCapabilityUnsupported"),
      (New-NegativeCell "authzDenied" "SVN_REMOTE_STATUS_AUTH_FAILED" "authorizationDenied"),
      (New-NegativeCell "blackholeConnect" "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT" "operationDeadlineExceeded"),
      (New-NegativeCell "stalledMidRead" "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT" "operationDeadlineExceeded"),
      (New-NegativeCell "deadline" "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT" "operationDeadlineExceeded"),
      (New-NegativeCell "cancellation" "SUBVERSIONR_REMOTE_WORKER_CANCELLED" "operationCancelled"),
      (New-NegativeCell "workerCrash" "SUBVERSIONR_REMOTE_WORKER_CRASHED" "workerContainmentFailed"),
      (New-NegativeCell "daemonDisconnect" "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED" "workerContainmentFailed"),
      (New-NegativeCell "trustRevoked" "SUBVERSIONR_REMOTE_TRUST_EPOCH_MISMATCH" "remoteConfigurationInvalid"),
      (New-NegativeCell "recoverySafe" "none" "none"),
      (New-NegativeCell "recoveryIndeterminate" "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE" "remoteOperationIndeterminate"),
      (New-NegativeCell "recoveryBlocked" "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED" "remoteRecoveryBlocked"),
      (New-NegativeCell "unrelatedRepository" "none" "none"),
      (New-NegativeCell "localEventZeroNetwork" "none" "none"),
      (New-NegativeCell "redaction" "none" "none")
    )
    recoverySettlements = [ordered]@{
      surfaces = @("packaged-native", "installed-vsix-extension-host")
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
        exactTargetPathHashMatched = $true
        exactOriginMatched = $true
        confirmedEntryRemoved = $true
        subsequentCheckoutPassed = $true
      }
    }
    stress = [ordered]@{
      surface = "installed-vsix-extension-host"
      cycles = 100
      status = "passed"
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
    "-ExpectedProductVersion", "0.3.0"
  )
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
  $tampered.negativeCells[0].followupNetworkContacts = 1
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject malicious-root follow-up contact."

  $tampered = Copy-Report $report
  $tampered.negativeCells[2].reason = "authenticationRequired"
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "authorizationDenied" "I6 verification must reject generic authentication classification for authz denial."

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
  $tampered.recoverySettlements.blocked.automaticClear = $true
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject automatic checkout-target recovery clearing."

  $tampered = Copy-Report $report
  $tampered.recoverySettlements.safe.freshReconcile = $false
  Write-Report $tampered $evidencePath
  Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "I6 JSON schema" "I6 verification must reject Safe recovery without fresh reconcile."

  $tampered = Copy-Report $report
  $tampered.recoverySettlements.indeterminate.stableCode = "SUBVERSIONR_REMOTE_WORKER_CRASHED"
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
      @("svnserve", $svnservePath, "svnserve-I6-fixture")
    )) {
    Set-Content -LiteralPath $toolBinding[1] -Value "tampered-$($toolBinding[0])" -NoNewline
    Assert-NativeCommandFailsContaining { & pwsh @verifyArguments } "artifactBindings.$($toolBinding[0]) must bind the exact file bytes" "I6 verification must reject $($toolBinding[0]) hash drift."
    Set-Content -LiteralPath $toolBinding[1] -Value $toolBinding[2] -NoNewline
  }

  foreach ($probeBinding in @(
      @("packagedNativeProbe", $packagedNativeProbePath),
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
  Set-Content -LiteralPath $driverConfigPath -Value "[general]`nanon-access = write`nauth-access = none`nauthz-db = authz`nrealm = SubversionR I6 Controlled Anonymous`n[sasl]`nuse-sasl = false" -NoNewline
  Set-Content -LiteralPath $driverAuthzPath -Value "[repo:/]`n* = rw" -NoNewline
  $driverOutputPath = Join-Path $driverFixtureRoot "evidence.json"
  Set-Content -LiteralPath $driverOutputPath -Value '{"stale":true}' -NoNewline
  $driverArguments = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $probeDriverPath,
    "-RepositoryUrl", "svn://127.0.0.1:3690/repo/trunk",
    "-FixtureRoot", $driverFixtureRoot,
    "-FixtureConfigPath", $driverConfigPath,
    "-FixtureAuthzPath", $driverAuthzPath,
    "-SvnPath", $svnPath,
    "-SvnadminPath", $svnadminPath,
    "-SvnservePath", $svnservePath,
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
      'probe-m8-i6-installed-vsix.ps1',
      'test-vscode-installed-extension-host.ps1',
      'extension/resources/backend/win32-x64/subversionr-daemon.exe',
      'extension/resources/backend/win32-x64/subversionr_svn_bridge.dll',
      'SUBVERSIONR_M8_I6_OBSERVATION_BLOCKED',
      'sixteen cross-surface negative/recovery cells',
      'Remove-Item -LiteralPath $outputResolved -Force'
    )) {
    Assert-True ($driverText.Contains($requiredText)) "I6 probe driver must retain real-artifact/fail-closed contract text '$requiredText'."
  }
  Assert-True (-not $driverText.Contains('publicClaimEligible = $true')) "I6 probe driver must not synthesize a passing public claim while the installed operation harness is absent."

  $contractText = Get-Content -Raw -LiteralPath $contractPath
  foreach ($requiredText in @(
      "Fixture startup or a direct bridge/unit probe does not satisfy the",
      "SVN_REMOTE_STATUS_AUTH_FAILED",
      "positive operation matrix",
      "sixteen cross-surface negative/recovery cells",
      "may not be represented as"
    )) {
    Assert-True ($contractText.Contains($requiredText)) "I6 evidence contract must retain fail-closed boundary '$requiredText'."
  }
  $schema = Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Json
  Assert-Equal "subversionr.release.m8-i6-svn-anonymous.win32-x64.v1" $schema.properties.schema.const "I6 JSON schema must bind the exact evidence schema."
  Assert-Equal "False" ([string]$schema.additionalProperties) "I6 JSON schema must reject unknown top-level fields."

  Write-Host "M8 I6 svn anonymous evidence script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $fakeStageRoot -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $runnerFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

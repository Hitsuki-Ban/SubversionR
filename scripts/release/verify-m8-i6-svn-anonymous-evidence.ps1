[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$EvidencePath,

  [Parameter(Mandatory = $true)]
  [string]$VsixPath,

  [Parameter(Mandatory = $true)]
  [string]$DaemonPath,

  [Parameter(Mandatory = $true)]
  [string]$BridgePath,

  [Parameter(Mandatory = $true)]
  [string]$StageManifestPath,

  [Parameter(Mandatory = $true)]
  [string]$ProbeDriverPath,

  [Parameter(Mandatory = $true)]
  [string]$RaSvnOriginPatchPath,

  [Parameter(Mandatory = $true)]
  [string]$RaSvnOriginContractPath,

  [Parameter(Mandatory = $true)]
  [string]$NativeSourceLockPath,

  [Parameter(Mandatory = $true)]
  [string]$SvnPath,

  [Parameter(Mandatory = $true)]
  [string]$SvnadminPath,

  [Parameter(Mandatory = $true)]
  [string]$SvnservePath,

  [Parameter(Mandatory = $true)]
  [string]$FixtureConfigPath,

  [Parameter(Mandatory = $true)]
  [string]$FixtureAuthzPath,

  [Parameter(Mandatory = $true)]
  [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
  [string]$ExpectedProductVersion
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ExpectedOperations = @(
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
)

$ExpectedNegativeCells = @(
  "maliciousRoot",
  "saslOnly",
  "authzDenied",
  "blackholeConnect",
  "stalledMidRead",
  "deadline",
  "cancellation",
  "workerCrash",
  "daemonDisconnect",
  "trustRevoked",
  "recoverySafe",
  "recoveryIndeterminate",
  "recoveryBlocked",
  "unrelatedRepository",
  "localEventZeroNetwork",
  "redaction"
)

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$contractRelativePath = "docs/release/m8-i6-svn-anonymous-evidence.v1.schema.json"
$contractPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $contractRelativePath))
$expectedProbeDriverPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "scripts\release\probe-m8-i6-svn-anonymous.ps1"))
$expectedPackagedNativeProbePath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "scripts\release\probe-m8-i6-packaged-native.mjs"))
$expectedPackagedNegativeProbePath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "scripts\release\probe-m8-i6-packaged-negative.mjs"))
$expectedRaSvnFaultFixturePath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "scripts\release\serve-m8-i6-ra-svn-fault-fixture.mjs"))
$expectedInstalledStressProbePath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-stress.ps1"))
$expectedInstalledNegativeProbePath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-negative.ps1"))
$expectedInstalledVsixProbePath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-vsix.ps1"))
$expectedPackagedCompatibilityProbePath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "scripts\release\probe-vscode-packaged-native.mjs"))
$expectedInstalledExtensionHostProbePath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "scripts\release\test-vscode-installed-extension-host.ps1"))
$expectedRaSvnOriginPatchPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "native\patches\subversion-1.14.5\ra-svn-authority.patch"))
$expectedRaSvnOriginContractPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "native\patches\subversion-1.14.5\ra-svn-authority.contract.json"))
$expectedNativeSourceLockPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "native\sources.lock.json"))

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

function Assert-ExactProperties([object]$Value, [string[]]$Expected, [string]$Context) {
  Assert-True ($null -ne $Value) "$Context must be present."
  $actual = @($Value.PSObject.Properties.Name | Sort-Object)
  $sortedExpected = @($Expected | Sort-Object)
  Assert-Equal ($sortedExpected -join ",") ($actual -join ",") "$Context must contain exactly the required fields."
}

function Resolve-RequiredFile([string]$Path, [string]$Name) {
  Assert-True (-not [string]::IsNullOrWhiteSpace($Path)) "$Name is required."
  Assert-True ([System.IO.Path]::IsPathFullyQualified($Path)) "$Name must be an absolute path."
  $resolved = [System.IO.Path]::GetFullPath($Path)
  Assert-True (Test-Path -LiteralPath $resolved -PathType Leaf) "$Name must be an existing file: $resolved"
  return $resolved
}

function Assert-ExactSourcePath([string]$Path, [string]$ExpectedPath, [string]$Name) {
  Assert-True ([System.IO.Path]::IsPathFullyQualified($Path)) "$Name must be an absolute path."
  $resolved = [System.IO.Path]::GetFullPath($Path)
  Assert-True ($resolved.Equals($ExpectedPath, [System.StringComparison]::OrdinalIgnoreCase)) "$Name must be the exact source-controlled path: $ExpectedPath"
  return $resolved
}

function Get-Sha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-Hash([string]$Value, [string]$Context) {
  Assert-True ($Value -cmatch '^[0-9a-f]{64}$') "$Context must be a lowercase SHA-256 digest."
}

function Assert-ArtifactBinding(
  [object]$Binding,
  [string]$Kind,
  [string]$Path,
  [string]$Context
) {
  Assert-ExactProperties $Binding @("kind", "sha256", "sizeBytes") $Context
  Assert-Equal $Kind ([string]$Binding.kind) "$Context kind must match."
  Assert-Hash ([string]$Binding.sha256) "$Context.sha256"
  Assert-Equal (Get-Sha256 $Path) ([string]$Binding.sha256) "$Context must bind the exact file bytes."
  Assert-Equal ([int64](Get-Item -LiteralPath $Path).Length) ([int64]$Binding.sizeBytes) "$Context size must match the exact file bytes."
}

function Assert-OperationCell([object]$Cell, [string]$ExpectedOperation, [string]$Context) {
  Assert-ExactProperties $Cell @(
    "operation",
    "status",
    "serverAuth",
    "promptCount",
    "credentialSettlement",
    "reconcile",
    "workerDescendantsAfter",
    "temporaryRootsAfter",
    "nativeLaneReleased",
    "diagnosticsRedacted"
  ) $Context
  Assert-Equal $ExpectedOperation ([string]$Cell.operation) "$Context operation must match its matrix slot."
  Assert-Equal "passed" ([string]$Cell.status) "$Context must pass."
  Assert-Equal "anonymous" ([string]$Cell.serverAuth) "$Context must prove anonymous server access."
  Assert-Equal 0 ([int]$Cell.promptCount) "$Context must not prompt for credentials."
  Assert-Equal "none" ([string]$Cell.credentialSettlement) "$Context must not settle credentials."
  Assert-Equal "fresh" ([string]$Cell.reconcile) "$Context must finish with fresh reconciled state."
  Assert-Equal 0 ([int]$Cell.workerDescendantsAfter) "$Context must leave zero worker descendants."
  Assert-Equal 0 ([int]$Cell.temporaryRootsAfter) "$Context must leave zero operation temporary roots."
  Assert-Equal $true ([bool]$Cell.nativeLaneReleased) "$Context must release the native lane only after cleanup."
  Assert-Equal $true ([bool]$Cell.diagnosticsRedacted) "$Context diagnostics must be redacted."
}

function Assert-Surface([object]$Surface, [string]$ExpectedKind, [string]$ExpectedBindingHash, [string]$Context) {
  Assert-ExactProperties $Surface @(
    "kind",
    "artifactSha256",
    "protocol",
    "remoteSvnAnonymous",
    "fixtureCliInvocations",
    "operations"
  ) $Context
  Assert-Equal $ExpectedKind ([string]$Surface.kind) "$Context kind must match."
  Assert-Equal $ExpectedBindingHash ([string]$Surface.artifactSha256) "$Context must bind the product artifact used by this surface."
  Assert-ExactProperties $Surface.protocol @("major", "minor") "$Context.protocol"
  Assert-Equal 1 ([int]$Surface.protocol.major) "$Context protocol major must be exact."
  Assert-Equal 35 ([int]$Surface.protocol.minor) "$Context protocol minor must be exact."
  Assert-Equal $true ([bool]$Surface.remoteSvnAnonymous) "$Context must prove the runtime remoteSvnAnonymous capability."
  Assert-Equal 0 ([int]$Surface.fixtureCliInvocations) "$Context product actions must not invoke svn fixture tools."

  $operations = @($Surface.operations)
  Assert-Equal $ExpectedOperations.Count $operations.Count "$Context must contain every anonymous operation cell exactly once."
  for ($index = 0; $index -lt $ExpectedOperations.Count; $index += 1) {
    Assert-OperationCell $operations[$index] $ExpectedOperations[$index] "$Context.operations[$index]"
  }
}

function Assert-NegativeSurfaceObservation(
  [object]$Observation,
  [string]$ExpectedSurface,
  [string]$ExpectedOriginCode,
  [string]$ExpectedOriginReason,
  [string]$ExpectedSettlementCode,
  [string]$ExpectedSettlementReason,
  [string]$ExpectedNetworkProgress,
  [int]$ExpectedNetworkAttempts,
  [int]$ExpectedNetworkConnections,
  [string]$Context
) {
  Assert-ExactProperties $Observation @(
    "surface",
    "originCode",
    "originReason",
    "settlementCode",
    "settlementReason",
    "networkProgress",
    "networkAttempts",
    "networkConnections",
    "fixtureCliInvocations",
    "credentialRequests",
    "credentialSettlements",
    "followupNetworkContacts",
    "workerDescendantsAfter",
    "temporaryRootsAfter",
    "diagnosticsRedacted"
  ) $Context
  Assert-Equal $ExpectedSurface ([string]$Observation.surface) "$Context surface must match."
  Assert-Equal $ExpectedOriginCode ([string]$Observation.originCode) "$Context origin code must match the controlled cell origin."
  Assert-Equal $ExpectedOriginReason ([string]$Observation.originReason) "$Context origin reason must match the controlled cell origin."
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$Observation.settlementCode)) "$Context settlement code must be non-empty."
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$Observation.settlementReason)) "$Context settlement reason must be non-empty."
  Assert-Equal $ExpectedSettlementCode ([string]$Observation.settlementCode) "$Context settlement code must match the controlled product settlement."
  Assert-Equal $ExpectedSettlementReason ([string]$Observation.settlementReason) "$Context settlement reason must match the controlled product settlement."
  Assert-Equal $ExpectedNetworkProgress ([string]$Observation.networkProgress) "$Context network progress must match the controlled fixture stage."
  Assert-Equal $ExpectedNetworkAttempts ([int]$Observation.networkAttempts) "$Context network attempt count must match the controlled fixture."
  Assert-Equal $ExpectedNetworkConnections ([int]$Observation.networkConnections) "$Context successful connection count must match the controlled fixture."
  foreach ($field in @(
      "fixtureCliInvocations",
      "credentialRequests",
      "credentialSettlements",
      "followupNetworkContacts",
      "workerDescendantsAfter",
      "temporaryRootsAfter"
    )) {
    Assert-Equal 0 ([int]$Observation.$field) "$Context.$field must be zero."
  }
  Assert-Equal $true ([bool]$Observation.diagnosticsRedacted) "$Context diagnostics must be redacted."
}

function Assert-NegativeCell(
  [object]$Cell,
  [string]$ExpectedCell,
  [string]$ExpectedOriginCode,
  [string]$ExpectedOriginReason,
  [string]$ExpectedSettlementCode,
  [string]$ExpectedSettlementReason,
  [string]$ExpectedNetworkProgress,
  [int]$ExpectedNetworkAttempts,
  [int]$ExpectedNetworkConnections,
  [bool]$InstalledOnly,
  [string]$Context
) {
  Assert-ExactProperties $Cell @(
    "cell",
    "status",
    "stableCode",
    "reason",
    "surfaceObservations"
  ) $Context
  Assert-Equal $ExpectedCell ([string]$Cell.cell) "$Context cell must match its matrix slot."
  Assert-Equal "passed" ([string]$Cell.status) "$Context must pass."
  Assert-Equal $ExpectedOriginCode ([string]$Cell.stableCode) "$Context stable code must define the controlled origin."
  Assert-Equal $ExpectedOriginReason ([string]$Cell.reason) "$Context reason must define the controlled origin."
  $observations = @($Cell.surfaceObservations)
  if ($InstalledOnly) {
    Assert-Equal 1 $observations.Count "$Context must contain the installed product observation exactly once."
    Assert-NegativeSurfaceObservation $observations[0] "installed-vsix-extension-host" $ExpectedOriginCode $ExpectedOriginReason $ExpectedSettlementCode $ExpectedSettlementReason $ExpectedNetworkProgress $ExpectedNetworkAttempts $ExpectedNetworkConnections "$Context.surfaceObservations[0]"
  }
  else {
    Assert-Equal 2 $observations.Count "$Context must contain packaged and installed product observations exactly once."
    Assert-NegativeSurfaceObservation $observations[0] "packaged-native" $ExpectedOriginCode $ExpectedOriginReason $ExpectedSettlementCode $ExpectedSettlementReason $ExpectedNetworkProgress $ExpectedNetworkAttempts $ExpectedNetworkConnections "$Context.surfaceObservations[0]"
    Assert-NegativeSurfaceObservation $observations[1] "installed-vsix-extension-host" $ExpectedOriginCode $ExpectedOriginReason $ExpectedSettlementCode $ExpectedSettlementReason $ExpectedNetworkProgress $ExpectedNetworkAttempts $ExpectedNetworkConnections "$Context.surfaceObservations[1]"
  }
}

function Assert-RecoverySurfaceObservation([object]$Observation, [string]$ExpectedSurface, [string]$Context) {
  Assert-ExactProperties $Observation @("surface", "safe", "indeterminate", "blocked") $Context
  Assert-Equal $ExpectedSurface ([string]$Observation.surface) "$Context surface must match."
  Assert-ExactProperties $Observation.safe @("outcome", "freshReconcile", "nativeLaneReleased", "subsequentRequestPassed") "$Context.safe"
  Assert-Equal "Safe" ([string]$Observation.safe.outcome) "$Context Safe outcome must be exact."
  foreach ($field in @("freshReconcile", "nativeLaneReleased", "subsequentRequestPassed")) {
    Assert-Equal $true ([bool]$Observation.safe.$field) "$Context.safe.$field must be true."
  }
  Assert-ExactProperties $Observation.indeterminate @("outcome", "stableCode", "reason", "nativeLaneBlocked", "explicitRecoveryRequired") "$Context.indeterminate"
  Assert-Equal "Indeterminate" ([string]$Observation.indeterminate.outcome) "$Context Indeterminate outcome must be exact."
  Assert-Equal "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE" ([string]$Observation.indeterminate.stableCode) "$Context Indeterminate code must be exact."
  Assert-Equal "remoteOperationIndeterminate" ([string]$Observation.indeterminate.reason) "$Context Indeterminate reason must be exact."
  Assert-Equal $true ([bool]$Observation.indeterminate.nativeLaneBlocked) "$Context Indeterminate recovery must block the native lane."
  Assert-Equal $true ([bool]$Observation.indeterminate.explicitRecoveryRequired) "$Context Indeterminate recovery must require explicit recovery."
  Assert-ExactProperties $Observation.blocked @("outcome", "stableCode", "reason", "restartRestoredBlocked", "automaticClear", "requiredConfirmation", "armedTargetPathSha256", "confirmedTargetPathSha256", "armedOriginOperationIdSha256", "confirmedOriginOperationIdSha256", "confirmedEntryRemoved", "subsequentCheckoutPassed") "$Context.blocked"
  Assert-Equal "Blocked" ([string]$Observation.blocked.outcome) "$Context Blocked outcome must be exact."
  Assert-Equal "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED" ([string]$Observation.blocked.stableCode) "$Context Blocked code must be exact."
  Assert-Equal "remoteRecoveryBlocked" ([string]$Observation.blocked.reason) "$Context Blocked reason must be exact."
  Assert-Equal $true ([bool]$Observation.blocked.restartRestoredBlocked) "$Context checkout recovery must restore armed targets as blocked after restart."
  Assert-Equal $false ([bool]$Observation.blocked.automaticClear) "$Context checkout recovery must never clear automatically."
  Assert-Equal "reviewedAndResolved" ([string]$Observation.blocked.requiredConfirmation) "$Context checkout recovery must require exact explicit confirmation."
  foreach ($field in @("armedTargetPathSha256", "confirmedTargetPathSha256", "armedOriginOperationIdSha256", "confirmedOriginOperationIdSha256")) {
    Assert-Hash ([string]$Observation.blocked.$field) "$Context.blocked.$field"
  }
  Assert-Equal ([string]$Observation.blocked.armedTargetPathSha256) ([string]$Observation.blocked.confirmedTargetPathSha256) "$Context blocked confirmation must match the exact armed target-path hash."
  Assert-Equal ([string]$Observation.blocked.armedOriginOperationIdSha256) ([string]$Observation.blocked.confirmedOriginOperationIdSha256) "$Context blocked confirmation must match the exact armed origin-operation-ID hash."
  foreach ($field in @("confirmedEntryRemoved", "subsequentCheckoutPassed")) {
    Assert-Equal $true ([bool]$Observation.blocked.$field) "$Context.blocked.$field must be true."
  }
}

function Assert-StressCycleObservation([object]$Observation, [int]$ExpectedCycle, [string]$Context) {
  Assert-ExactProperties $Observation @(
    "cycle",
    "operationIdSha256",
    "targetPathSha256",
    "extensionHostSessionSha256",
    "operation",
    "faultMode",
    "status",
    "checkoutRevision",
    "fixtureCliInvocations",
    "credentialRequests",
    "credentialSettlements",
    "workerDescendantsAfter",
    "temporaryRootsAfter",
    "fixtureServerChildrenAfter",
    "checkoutJournalEntriesAfter",
    "diagnosticsRedacted"
  ) $Context
  Assert-Equal $ExpectedCycle ([int]$Observation.cycle) "$Context cycle must be exact and ordered."
  Assert-Hash ([string]$Observation.operationIdSha256) "$Context.operationIdSha256"
  Assert-Hash ([string]$Observation.targetPathSha256) "$Context.targetPathSha256"
  Assert-Hash ([string]$Observation.extensionHostSessionSha256) "$Context.extensionHostSessionSha256"
  Assert-Equal "checkoutOpen" ([string]$Observation.operation) "$Context must execute the reviewed native checkout operation."
  Assert-Equal "none" ([string]$Observation.faultMode) "$Context must use the reviewed no-fault stress mode."
  Assert-Equal "passed" ([string]$Observation.status) "$Context must pass."
  Assert-True ([int]$Observation.checkoutRevision -ge 0) "$Context checkout revision must be non-negative."
  foreach ($field in @("fixtureCliInvocations", "credentialRequests", "credentialSettlements", "workerDescendantsAfter", "temporaryRootsAfter", "fixtureServerChildrenAfter", "checkoutJournalEntriesAfter")) {
    Assert-Equal 0 ([int]$Observation.$field) "$Context.$field must be zero."
  }
  Assert-Equal $true ([bool]$Observation.diagnosticsRedacted) "$Context diagnostics must be redacted."
}

$evidenceResolved = Resolve-RequiredFile $EvidencePath "EvidencePath"
$vsixResolved = Resolve-RequiredFile $VsixPath "VsixPath"
$daemonResolved = Resolve-RequiredFile $DaemonPath "DaemonPath"
$bridgeResolved = Resolve-RequiredFile $BridgePath "BridgePath"
$stageManifestResolved = Resolve-RequiredFile $StageManifestPath "StageManifestPath"
$probeDriverSourcePath = Assert-ExactSourcePath $ProbeDriverPath $expectedProbeDriverPath "ProbeDriverPath"
$packagedNativeProbeResolved = Resolve-RequiredFile $expectedPackagedNativeProbePath "packaged-native I6 probe"
$packagedNegativeProbeResolved = Resolve-RequiredFile $expectedPackagedNegativeProbePath "packaged-native I6 negative probe"
$raSvnFaultFixtureResolved = Resolve-RequiredFile $expectedRaSvnFaultFixturePath "I6 ra_svn fault fixture"
$installedStressProbeResolved = Resolve-RequiredFile $expectedInstalledStressProbePath "installed VSIX I6 stress probe"
$installedNegativeProbeResolved = Resolve-RequiredFile $expectedInstalledNegativeProbePath "installed VSIX I6 negative probe"
$installedVsixProbeResolved = Resolve-RequiredFile $expectedInstalledVsixProbePath "installed VSIX I6 probe"
$packagedCompatibilityProbeResolved = Resolve-RequiredFile $expectedPackagedCompatibilityProbePath "packaged-native compatibility probe"
$installedExtensionHostProbeResolved = Resolve-RequiredFile $expectedInstalledExtensionHostProbePath "installed Extension Host probe"
$raSvnOriginPatchSourcePath = Assert-ExactSourcePath $RaSvnOriginPatchPath $expectedRaSvnOriginPatchPath "RaSvnOriginPatchPath"
$raSvnOriginContractSourcePath = Assert-ExactSourcePath $RaSvnOriginContractPath $expectedRaSvnOriginContractPath "RaSvnOriginContractPath"
$nativeSourceLockSourcePath = Assert-ExactSourcePath $NativeSourceLockPath $expectedNativeSourceLockPath "NativeSourceLockPath"
$raSvnOriginPatchResolved = Resolve-RequiredFile $raSvnOriginPatchSourcePath "RaSvnOriginPatchPath"
$raSvnOriginContractResolved = Resolve-RequiredFile $raSvnOriginContractSourcePath "RaSvnOriginContractPath"
$nativeSourceLockResolved = Resolve-RequiredFile $nativeSourceLockSourcePath "NativeSourceLockPath"
$svnResolved = Resolve-RequiredFile $SvnPath "SvnPath"
$svnadminResolved = Resolve-RequiredFile $SvnadminPath "SvnadminPath"
$svnserveResolved = Resolve-RequiredFile $SvnservePath "SvnservePath"
$fixtureConfigResolved = Resolve-RequiredFile $FixtureConfigPath "FixtureConfigPath"
$fixtureAuthzResolved = Resolve-RequiredFile $FixtureAuthzPath "FixtureAuthzPath"

$rawEvidence = Get-Content -Raw -LiteralPath $evidenceResolved
try {
  Assert-True (Test-Json -Json $rawEvidence -SchemaFile $contractPath -ErrorAction Stop) "EvidencePath must satisfy the source-controlled I6 JSON schema."
}
catch {
  throw "EvidencePath must satisfy the source-controlled I6 JSON schema: $($_.Exception.Message)"
}

try {
  $report = $rawEvidence | ConvertFrom-Json
}
catch {
  throw "EvidencePath must contain valid JSON: $($_.Exception.Message)"
}

Assert-ExactProperties $report @(
  "schema",
  "schemaVersion",
  "contract",
  "target",
  "productVersion",
  "publicClaimEligible",
  "artifactBindings",
  "fixture",
  "surfaces",
  "negativeCells",
  "recoverySettlements",
  "stress",
  "privacy",
  "verdict"
) "I6 evidence"
Assert-Equal "subversionr.release.m8-i6-svn-anonymous.win32-x64.v1" ([string]$report.schema) "I6 evidence schema must match."
Assert-Equal 1 ([int]$report.schemaVersion) "I6 evidence schema version must match."
Assert-True (Test-Path -LiteralPath $contractPath -PathType Leaf) "I6 source-controlled JSON schema is missing."
Assert-ExactProperties $report.contract @("path", "sha256") "I6 evidence.contract"
Assert-Equal $contractRelativePath ([string]$report.contract.path) "I6 evidence must bind the source-controlled JSON schema path."
Assert-Equal (Get-Sha256 $contractPath) ([string]$report.contract.sha256) "I6 evidence must bind the exact source-controlled JSON schema bytes."
Assert-Equal "win32-x64" ([string]$report.target) "I6 evidence target must match."
Assert-Equal $ExpectedProductVersion ([string]$report.productVersion) "I6 evidence product version must match."
Assert-Equal $true ([bool]$report.publicClaimEligible) "I6 evidence must not be used as a partial or provisional claim."

Assert-ExactProperties $report.artifactBindings @(
  "vsix",
  "daemon",
  "bridge",
  "stageManifest",
  "probeDriver",
  "packagedNativeProbe",
  "packagedNegativeProbe",
  "raSvnFaultFixture",
  "installedStressProbe",
  "installedNegativeProbe",
  "installedVsixProbe",
  "packagedCompatibilityProbe",
  "installedExtensionHostProbe",
  "raSvnOriginPatch",
  "raSvnOriginContract",
  "nativeSourceLock",
  "svn",
  "svnadmin",
  "svnserve"
) "I6 evidence.artifactBindings"
Assert-ArtifactBinding $report.artifactBindings.vsix "vsix" $vsixResolved "I6 evidence.artifactBindings.vsix"
Assert-ArtifactBinding $report.artifactBindings.daemon "daemon" $daemonResolved "I6 evidence.artifactBindings.daemon"
Assert-ArtifactBinding $report.artifactBindings.bridge "bridge" $bridgeResolved "I6 evidence.artifactBindings.bridge"
Assert-ArtifactBinding $report.artifactBindings.stageManifest "subversion-stage-manifest" $stageManifestResolved "I6 evidence.artifactBindings.stageManifest"
Assert-ArtifactBinding $report.artifactBindings.raSvnOriginPatch "ra-svn-origin-patch" $raSvnOriginPatchResolved "I6 evidence.artifactBindings.raSvnOriginPatch"
Assert-ArtifactBinding $report.artifactBindings.raSvnOriginContract "ra-svn-origin-contract" $raSvnOriginContractResolved "I6 evidence.artifactBindings.raSvnOriginContract"
Assert-ArtifactBinding $report.artifactBindings.nativeSourceLock "native-source-lock" $nativeSourceLockResolved "I6 evidence.artifactBindings.nativeSourceLock"
Assert-ArtifactBinding $report.artifactBindings.svn "fixture-svn" $svnResolved "I6 evidence.artifactBindings.svn"
Assert-ArtifactBinding $report.artifactBindings.svnadmin "fixture-svnadmin" $svnadminResolved "I6 evidence.artifactBindings.svnadmin"
Assert-ArtifactBinding $report.artifactBindings.svnserve "fixture-svnserve" $svnserveResolved "I6 evidence.artifactBindings.svnserve"
$probeDriverResolved = Resolve-RequiredFile $probeDriverSourcePath "ProbeDriverPath"
Assert-ArtifactBinding $report.artifactBindings.probeDriver "i6-probe-driver" $probeDriverResolved "I6 evidence.artifactBindings.probeDriver"
Assert-ArtifactBinding $report.artifactBindings.packagedNativeProbe "i6-packaged-native-probe" $packagedNativeProbeResolved "I6 evidence.artifactBindings.packagedNativeProbe"
Assert-ArtifactBinding $report.artifactBindings.packagedNegativeProbe "i6-packaged-negative-probe" $packagedNegativeProbeResolved "I6 evidence.artifactBindings.packagedNegativeProbe"
Assert-ArtifactBinding $report.artifactBindings.raSvnFaultFixture "i6-ra-svn-fault-fixture" $raSvnFaultFixtureResolved "I6 evidence.artifactBindings.raSvnFaultFixture"
Assert-ArtifactBinding $report.artifactBindings.installedStressProbe "i6-installed-stress-probe" $installedStressProbeResolved "I6 evidence.artifactBindings.installedStressProbe"
Assert-ArtifactBinding $report.artifactBindings.installedNegativeProbe "i6-installed-negative-probe" $installedNegativeProbeResolved "I6 evidence.artifactBindings.installedNegativeProbe"
Assert-ArtifactBinding $report.artifactBindings.installedVsixProbe "i6-installed-vsix-probe" $installedVsixProbeResolved "I6 evidence.artifactBindings.installedVsixProbe"
Assert-ArtifactBinding $report.artifactBindings.packagedCompatibilityProbe "packaged-native-compatibility-probe" $packagedCompatibilityProbeResolved "I6 evidence.artifactBindings.packagedCompatibilityProbe"
Assert-ArtifactBinding $report.artifactBindings.installedExtensionHostProbe "installed-extension-host-probe" $installedExtensionHostProbeResolved "I6 evidence.artifactBindings.installedExtensionHostProbe"

Assert-ExactProperties $report.fixture @(
  "transport",
  "serverKind",
  "serverVersion",
  "listenHost",
  "configurationSha256",
  "authzSha256",
  "sourceBuilt",
  "fixtureCliOnly",
  "ambientConfigExcluded",
  "saslEnabled"
) "I6 evidence.fixture"
Assert-Equal "direct-svn" ([string]$report.fixture.transport) "I6 fixture transport must match."
Assert-Equal "svnserve" ([string]$report.fixture.serverKind) "I6 fixture server kind must match."
Assert-Equal "1.14.5" ([string]$report.fixture.serverVersion) "I6 fixture must use the locked Apache Subversion version."
Assert-Equal "127.0.0.1" ([string]$report.fixture.listenHost) "I6 fixture must bind loopback only."
Assert-Equal (Get-Sha256 $fixtureConfigResolved) ([string]$report.fixture.configurationSha256) "I6 fixture config hash must match."
Assert-Equal (Get-Sha256 $fixtureAuthzResolved) ([string]$report.fixture.authzSha256) "I6 fixture authz hash must match."
Assert-Equal $true ([bool]$report.fixture.sourceBuilt) "I6 fixture must use source-built svnserve."
Assert-Equal $true ([bool]$report.fixture.fixtureCliOnly) "I6 SVN CLI use must be fixture-only."
Assert-Equal $true ([bool]$report.fixture.ambientConfigExcluded) "I6 fixture must prove ambient config/cache exclusion."
Assert-Equal $false ([bool]$report.fixture.saslEnabled) "I6 anonymous positive fixture must not enable SASL."

$surfaces = @($report.surfaces)
Assert-Equal 2 $surfaces.Count "I6 evidence must contain packaged-native and installed-VSIX surfaces."
Assert-Surface $surfaces[0] "packaged-native" ([string]$report.artifactBindings.daemon.sha256) "I6 evidence.surfaces[0]"
Assert-Surface $surfaces[1] "installed-vsix-extension-host" ([string]$report.artifactBindings.vsix.sha256) "I6 evidence.surfaces[1]"

$negativeCells = @($report.negativeCells)
Assert-Equal $ExpectedNegativeCells.Count $negativeCells.Count "I6 evidence must contain every negative cell exactly once."
$negativeContracts = @(
  @("maliciousRoot", "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH", "crossAuthorityRejected", "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH", "crossAuthorityRejected", "authenticated", 1, 1, $false),
  @("saslOnly", "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED", "remoteCapabilityUnsupported", "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED", "remoteCapabilityUnsupported", "greeting", 1, 1, $false),
  @("authzDenied", "SVN_REMOTE_STATUS_AUTH_FAILED", "authorizationDenied", "SVN_REMOTE_STATUS_AUTH_FAILED", "authorizationDenied", "command", 1, 1, $false),
  @("blackholeConnect", "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT", "operationDeadlineExceeded", "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT", "operationDeadlineExceeded", "none", 1, 0, $false),
  @("stalledMidRead", "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT", "operationDeadlineExceeded", "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT", "operationDeadlineExceeded", "greeting", 1, 1, $false),
  @("deadline", "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT", "operationDeadlineExceeded", "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT", "operationDeadlineExceeded", "greeting", 1, 1, $false),
  @("cancellation", "SUBVERSIONR_REMOTE_WORKER_CANCELLED", "operationCancelled", "SUBVERSIONR_REMOTE_WORKER_CANCELLED", "operationCancelled", "greeting", 1, 1, $false),
  @("workerCrash", "SUBVERSIONR_REMOTE_WORKER_CRASHED", "workerContainmentFailed", "SUBVERSIONR_REMOTE_WORKER_CRASHED", "workerContainmentFailed", "greeting", 1, 1, $false),
  @("daemonDisconnect", "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED", "workerContainmentFailed", "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED", "workerContainmentFailed", "greeting", 1, 1, $false),
  @("trustRevoked", "SUBVERSIONR_REMOTE_TRUST_EPOCH_MISMATCH", "remoteConfigurationInvalid", "SUBVERSIONR_REMOTE_TRUST_EPOCH_MISMATCH", "remoteConfigurationInvalid", "none", 0, 0, $false),
  @("recoverySafe", "none", "none", "none", "none", "command", 1, 1, $false),
  @("recoveryIndeterminate", "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE", "remoteOperationIndeterminate", "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE", "remoteOperationIndeterminate", "command", 1, 1, $false),
  @("recoveryBlocked", "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT", "operationDeadlineExceeded", "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED", "remoteRecoveryBlocked", "command", 1, 1, $false),
  @("unrelatedRepository", "none", "none", "none", "none", "command", 1, 1, $false),
  @("localEventZeroNetwork", "none", "none", "none", "none", "none", 0, 0, $true),
  @("redaction", "none", "none", "none", "none", "command", 1, 1, $false)
)
for ($index = 0; $index -lt $negativeContracts.Count; $index += 1) {
  $contract = $negativeContracts[$index]
  Assert-NegativeCell $negativeCells[$index] $contract[0] $contract[1] $contract[2] $contract[3] $contract[4] $contract[5] $contract[6] $contract[7] $contract[8] "I6 evidence.negativeCells[$index]"
}

Assert-ExactProperties $report.recoverySettlements @("surfaceObservations") "I6 evidence.recoverySettlements"
$recoveryObservations = @($report.recoverySettlements.surfaceObservations)
Assert-Equal 2 $recoveryObservations.Count "I6 recovery settlements must contain packaged and installed product observations."
Assert-RecoverySurfaceObservation $recoveryObservations[0] "packaged-native" "I6 evidence.recoverySettlements.surfaceObservations[0]"
Assert-RecoverySurfaceObservation $recoveryObservations[1] "installed-vsix-extension-host" "I6 evidence.recoverySettlements.surfaceObservations[1]"

Assert-ExactProperties $report.stress @(
  "surface",
  "cycles",
  "status",
  "cycleObservations",
  "subsequentObservation",
  "maxWorkerDescendantsAfterCycle",
  "maxTemporaryRootsAfterCycle",
  "maxFixtureServerChildrenAfterCycle",
  "subsequentRequestPassed"
) "I6 evidence.stress"
Assert-Equal "installed-vsix-extension-host" ([string]$report.stress.surface) "I6 stress evidence must exercise the installed product."
Assert-Equal 100 ([int]$report.stress.cycles) "I6 stress evidence must run exactly 100 cycles."
Assert-Equal "passed" ([string]$report.stress.status) "I6 stress evidence must pass."
$cycleObservations = @($report.stress.cycleObservations)
Assert-Equal 100 $cycleObservations.Count "I6 stress evidence must contain exactly 100 per-cycle observations."
$operationHashes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$targetHashes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$extensionHostSessionHashes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$workerCounts = @()
$temporaryRootCounts = @()
$fixtureChildCounts = @()
for ($index = 0; $index -lt $cycleObservations.Count; $index += 1) {
  $observation = $cycleObservations[$index]
  Assert-StressCycleObservation $observation ($index + 1) "I6 evidence.stress.cycleObservations[$index]"
  Assert-True ($operationHashes.Add([string]$observation.operationIdSha256)) "I6 stress operation hashes must be unique."
  [void]$targetHashes.Add([string]$observation.targetPathSha256)
  [void]$extensionHostSessionHashes.Add([string]$observation.extensionHostSessionSha256)
  $workerCounts += [int]$observation.workerDescendantsAfter
  $temporaryRootCounts += [int]$observation.temporaryRootsAfter
  $fixtureChildCounts += [int]$observation.fixtureServerChildrenAfter
}
Assert-Equal 1 $targetHashes.Count "I6 stress cycles must reuse one exact checkout target hash."
Assert-Equal 1 $extensionHostSessionHashes.Count "I6 stress cycles must run in one exact installed Extension Host session."
Assert-StressCycleObservation $report.stress.subsequentObservation 101 "I6 evidence.stress.subsequentObservation"
Assert-True (-not $operationHashes.Contains([string]$report.stress.subsequentObservation.operationIdSha256)) "I6 stress subsequent request must use an independent operation hash."
Assert-True ($targetHashes.Contains([string]$report.stress.subsequentObservation.targetPathSha256)) "I6 stress subsequent request must reuse the exact checkout target hash."
Assert-True ($extensionHostSessionHashes.Contains([string]$report.stress.subsequentObservation.extensionHostSessionSha256)) "I6 stress subsequent request must run in the same installed Extension Host session."
$maxWorkers = ($workerCounts | Measure-Object -Maximum).Maximum
$maxTemporaryRoots = ($temporaryRootCounts | Measure-Object -Maximum).Maximum
$maxFixtureChildren = ($fixtureChildCounts | Measure-Object -Maximum).Maximum
Assert-Equal $maxWorkers ([int]$report.stress.maxWorkerDescendantsAfterCycle) "I6 stress worker aggregate must be recomputed from per-cycle observations."
Assert-Equal $maxTemporaryRoots ([int]$report.stress.maxTemporaryRootsAfterCycle) "I6 stress temporary-root aggregate must be recomputed from per-cycle observations."
Assert-Equal $maxFixtureChildren ([int]$report.stress.maxFixtureServerChildrenAfterCycle) "I6 stress fixture-child aggregate must be recomputed from per-cycle observations."
Assert-Equal 0 $maxWorkers "I6 stress evidence must leave zero worker descendants after every cycle."
Assert-Equal 0 $maxTemporaryRoots "I6 stress evidence must leave zero temporary roots after every cycle."
Assert-Equal 0 $maxFixtureChildren "I6 stress evidence must leave zero fixture server children after every cycle."
Assert-Equal $true ([bool]$report.stress.subsequentRequestPassed) "I6 stress evidence must prove a subsequent request."

Assert-ExactProperties $report.privacy @(
  "rawUrlCount",
  "rawPathCount",
  "secretTokenCount",
  "maxDiagnosticBytes",
  "boundedDiagnostics"
) "I6 evidence.privacy"
Assert-Equal 0 ([int]$report.privacy.rawUrlCount) "I6 evidence must record zero raw URLs."
Assert-Equal 0 ([int]$report.privacy.rawPathCount) "I6 evidence must record zero raw paths."
Assert-Equal 0 ([int]$report.privacy.secretTokenCount) "I6 evidence must record zero secret tokens."
Assert-True ([int]$report.privacy.maxDiagnosticBytes -le 32768) "I6 evidence diagnostics must remain within 32 KiB."
Assert-Equal $true ([bool]$report.privacy.boundedDiagnostics) "I6 evidence must prove bounded diagnostics."

Assert-ExactProperties $report.verdict @(
  "status",
  "claim",
  "allOperationCellsPassed",
  "allNegativeCellsPassed",
  "artifactHashesMatched",
  "installedProductProved",
  "sourceBuiltFixtureProved"
) "I6 evidence.verdict"
Assert-Equal "verified" ([string]$report.verdict.status) "I6 verdict must be verified."
Assert-Equal "win32-x64-direct-svn-anonymous" ([string]$report.verdict.claim) "I6 verdict claim must remain exact."
foreach ($field in @(
    "allOperationCellsPassed",
    "allNegativeCellsPassed",
    "artifactHashesMatched",
    "installedProductProved",
    "sourceBuiltFixtureProved"
  )) {
  Assert-Equal $true ([bool]$report.verdict.$field) "I6 evidence.verdict.$field must be true."
}

Assert-True (-not [regex]::IsMatch($rawEvidence, '(?i)(?:svn|https?|svn\+ssh)://')) "I6 evidence must not contain raw repository URLs."
Assert-True (-not [regex]::IsMatch($rawEvidence, '(?i)(?:^|[\\/])\.svn(?:[\\/]|$)')) "I6 evidence must not contain raw working-copy metadata paths."

Write-Host "Verified complete M8 I6 direct svn:// anonymous evidence for win32-x64."

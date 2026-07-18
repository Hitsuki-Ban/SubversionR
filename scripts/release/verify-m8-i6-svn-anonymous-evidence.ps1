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

function Assert-NegativeCell([object]$Cell, [string]$ExpectedCell, [string]$ExpectedCode, [string]$ExpectedReason, [string]$Context) {
  Assert-ExactProperties $Cell @(
    "cell",
    "status",
    "stableCode",
    "reason",
    "surfaces",
    "followupNetworkContacts",
    "workerDescendantsAfter",
    "temporaryRootsAfter",
    "diagnosticsRedacted"
  ) $Context
  Assert-Equal $ExpectedCell ([string]$Cell.cell) "$Context cell must match its matrix slot."
  Assert-Equal "passed" ([string]$Cell.status) "$Context must pass."
  Assert-Equal $ExpectedCode ([string]$Cell.stableCode) "$Context stable code must match the controlled failure."
  Assert-Equal $ExpectedReason ([string]$Cell.reason) "$Context stable failure reason must match."
  Assert-Equal "packaged-native,installed-vsix-extension-host" (@($Cell.surfaces) -join ",") "$Context must pass on both packaged and installed product surfaces."
  Assert-Equal 0 ([int]$Cell.followupNetworkContacts) "$Context must make zero forbidden follow-up contacts."
  Assert-Equal 0 ([int]$Cell.workerDescendantsAfter) "$Context must leave zero worker descendants."
  Assert-Equal 0 ([int]$Cell.temporaryRootsAfter) "$Context must leave zero operation temporary roots."
  Assert-Equal $true ([bool]$Cell.diagnosticsRedacted) "$Context diagnostics must be redacted."
}

$evidenceResolved = Resolve-RequiredFile $EvidencePath "EvidencePath"
$vsixResolved = Resolve-RequiredFile $VsixPath "VsixPath"
$daemonResolved = Resolve-RequiredFile $DaemonPath "DaemonPath"
$bridgeResolved = Resolve-RequiredFile $BridgePath "BridgePath"
$stageManifestResolved = Resolve-RequiredFile $StageManifestPath "StageManifestPath"
$probeDriverSourcePath = Assert-ExactSourcePath $ProbeDriverPath $expectedProbeDriverPath "ProbeDriverPath"
$packagedNativeProbeResolved = Resolve-RequiredFile $expectedPackagedNativeProbePath "packaged-native I6 probe"
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
  @("maliciousRoot", "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH", "crossAuthorityRejected"),
  @("saslOnly", "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED", "remoteCapabilityUnsupported"),
  @("authzDenied", "SVN_REMOTE_STATUS_AUTH_FAILED", "authorizationDenied"),
  @("blackholeConnect", "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT", "operationDeadlineExceeded"),
  @("stalledMidRead", "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT", "operationDeadlineExceeded"),
  @("deadline", "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT", "operationDeadlineExceeded"),
  @("cancellation", "SUBVERSIONR_REMOTE_WORKER_CANCELLED", "operationCancelled"),
  @("workerCrash", "SUBVERSIONR_REMOTE_WORKER_CRASHED", "workerContainmentFailed"),
  @("daemonDisconnect", "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED", "workerContainmentFailed"),
  @("trustRevoked", "SUBVERSIONR_REMOTE_TRUST_EPOCH_MISMATCH", "remoteConfigurationInvalid"),
  @("recoverySafe", "none", "none"),
  @("recoveryIndeterminate", "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE", "remoteOperationIndeterminate"),
  @("recoveryBlocked", "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED", "remoteRecoveryBlocked"),
  @("unrelatedRepository", "none", "none"),
  @("localEventZeroNetwork", "none", "none"),
  @("redaction", "none", "none")
)
for ($index = 0; $index -lt $negativeContracts.Count; $index += 1) {
  $contract = $negativeContracts[$index]
  Assert-NegativeCell $negativeCells[$index] $contract[0] $contract[1] $contract[2] "I6 evidence.negativeCells[$index]"
}

Assert-ExactProperties $report.recoverySettlements @(
  "surfaces",
  "safe",
  "indeterminate",
  "blocked"
) "I6 evidence.recoverySettlements"
Assert-Equal "packaged-native,installed-vsix-extension-host" (@($report.recoverySettlements.surfaces) -join ",") "I6 recovery settlements must pass on both product surfaces."
Assert-ExactProperties $report.recoverySettlements.safe @("outcome", "freshReconcile", "nativeLaneReleased", "subsequentRequestPassed") "I6 evidence.recoverySettlements.safe"
Assert-Equal "Safe" ([string]$report.recoverySettlements.safe.outcome) "I6 Safe recovery outcome must be exact."
foreach ($field in @("freshReconcile", "nativeLaneReleased", "subsequentRequestPassed")) {
  Assert-Equal $true ([bool]$report.recoverySettlements.safe.$field) "I6 evidence.recoverySettlements.safe.$field must be true."
}
Assert-ExactProperties $report.recoverySettlements.indeterminate @("outcome", "stableCode", "reason", "nativeLaneBlocked", "explicitRecoveryRequired") "I6 evidence.recoverySettlements.indeterminate"
Assert-Equal "Indeterminate" ([string]$report.recoverySettlements.indeterminate.outcome) "I6 Indeterminate recovery outcome must be exact."
Assert-Equal "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE" ([string]$report.recoverySettlements.indeterminate.stableCode) "I6 Indeterminate recovery code must be exact."
Assert-Equal "remoteOperationIndeterminate" ([string]$report.recoverySettlements.indeterminate.reason) "I6 Indeterminate recovery reason must be exact."
Assert-Equal $true ([bool]$report.recoverySettlements.indeterminate.nativeLaneBlocked) "I6 Indeterminate recovery must block the native lane."
Assert-Equal $true ([bool]$report.recoverySettlements.indeterminate.explicitRecoveryRequired) "I6 Indeterminate recovery must require explicit recovery."
Assert-ExactProperties $report.recoverySettlements.blocked @("outcome", "stableCode", "reason", "restartRestoredBlocked", "automaticClear", "requiredConfirmation", "exactTargetPathHashMatched", "exactOriginMatched", "confirmedEntryRemoved", "subsequentCheckoutPassed") "I6 evidence.recoverySettlements.blocked"
Assert-Equal "Blocked" ([string]$report.recoverySettlements.blocked.outcome) "I6 Blocked recovery outcome must be exact."
Assert-Equal "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED" ([string]$report.recoverySettlements.blocked.stableCode) "I6 Blocked recovery code must be exact."
Assert-Equal "remoteRecoveryBlocked" ([string]$report.recoverySettlements.blocked.reason) "I6 Blocked recovery reason must be exact."
Assert-Equal $true ([bool]$report.recoverySettlements.blocked.restartRestoredBlocked) "I6 checkout recovery must restore armed targets as blocked after restart."
Assert-Equal $false ([bool]$report.recoverySettlements.blocked.automaticClear) "I6 checkout recovery must never clear automatically."
Assert-Equal "reviewedAndResolved" ([string]$report.recoverySettlements.blocked.requiredConfirmation) "I6 checkout recovery must require the exact explicit confirmation contract."
foreach ($field in @("exactTargetPathHashMatched", "exactOriginMatched", "confirmedEntryRemoved", "subsequentCheckoutPassed")) {
  Assert-Equal $true ([bool]$report.recoverySettlements.blocked.$field) "I6 evidence.recoverySettlements.blocked.$field must be true."
}

Assert-ExactProperties $report.stress @(
  "surface",
  "cycles",
  "status",
  "maxWorkerDescendantsAfterCycle",
  "maxTemporaryRootsAfterCycle",
  "maxFixtureServerChildrenAfterCycle",
  "subsequentRequestPassed"
) "I6 evidence.stress"
Assert-Equal "installed-vsix-extension-host" ([string]$report.stress.surface) "I6 stress evidence must exercise the installed product."
Assert-Equal 100 ([int]$report.stress.cycles) "I6 stress evidence must run exactly 100 cycles."
Assert-Equal "passed" ([string]$report.stress.status) "I6 stress evidence must pass."
Assert-Equal 0 ([int]$report.stress.maxWorkerDescendantsAfterCycle) "I6 stress evidence must leave zero worker descendants after every cycle."
Assert-Equal 0 ([int]$report.stress.maxTemporaryRootsAfterCycle) "I6 stress evidence must leave zero temporary roots after every cycle."
Assert-Equal 0 ([int]$report.stress.maxFixtureServerChildrenAfterCycle) "I6 stress evidence must leave zero fixture server children after every cycle."
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

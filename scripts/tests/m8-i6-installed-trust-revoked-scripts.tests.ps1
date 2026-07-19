$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$probePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-trust-revoked.ps1"
$testBase = Join-Path $repoRoot "target\t\i6itr"
$testId = [Guid]::NewGuid().ToString("N").Substring(0, 8)
$tempRoot = Join-Path $testBase $testId

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Assert-ExactProperties([object]$Value, [string[]]$Expected, [string]$Context) {
  Assert-True ($null -ne $Value) "$Context must be present."
  $actual = @($Value.PSObject.Properties.Name | Sort-Object)
  $expectedSorted = @($Expected | Sort-Object)
  Assert-True (($actual -join ",") -ceq ($expectedSorted -join ",")) "$Context must contain exactly the required fields."
}

function Assert-ScriptThrowsContaining([scriptblock]$Action, [string]$ExpectedText, [string]$Message) {
  $thrown = $null
  try { & $Action }
  catch { $thrown = $_ }
  Assert-True ($null -ne $thrown) "$Message Expected the script block to throw."
  Assert-True ($thrown.Exception.Message.Contains($ExpectedText)) "$Message Expected '$ExpectedText', got '$($thrown.Exception.Message)'."
}

function Assert-NativeCommandFailsContaining([scriptblock]$Action, [string]$ExpectedText, [string]$Message) {
  $output = & $Action 2>&1
  $exitCode = $LASTEXITCODE
  Assert-True ($exitCode -ne 0) "$Message Expected the native command to fail."
  $text = $output | Out-String
  Assert-True ($text.Contains($ExpectedText)) "$Message Expected '$ExpectedText', got '$text'."
}

Assert-True (Test-Path -LiteralPath $probePath -PathType Leaf) "Installed trust-revoked probe must exist."
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($probePath, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) "Installed trust-revoked probe must parse without PowerShell errors."

$parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
$expectedParameters = @(
  "VsixPath", "CodeCliPath", "FixtureRoot", "WorkingCopyPath", "RepositoryUrl",
  "FixtureStatePath", "OperationId", "ExpectedProductVersion", "DaemonPath", "BridgePath", "TimeoutSeconds"
)
Assert-True (($parameterNames -join ",") -ceq ($expectedParameters -join ",")) "Installed trust-revoked probe must expose only the exact required parameters."

$source = Get-Content -Raw -LiteralPath $probePath
foreach ($required in @(
    'subversionr.diagnostics.installedSvnAnonymousTrustRevokedReport',
    'SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_REPORT_TOKEN',
    'SUBVERSIONR_INSTALLED_I6_TRUST_REVOKED_OPERATION_ID',
    'SUBVERSIONR_INSTALLED_I6_TRUST_REVOKED_FIXTURE_STATE_PATH',
    'externally supplied canonical UUID',
    'token, repositoryUrl, workingCopyPath, operationId, fixtureStatePath',
    'subversionr.release.m8-i6-installed-vsix-trust-revoked.v1',
    'Assert-ExactProperties $report.trust @("initialAcknowledgedEpoch", "revokedAcknowledgedEpoch", "submissionEnabled", "consistent")',
    'SUBVERSIONR_REMOTE_TRUST_EPOCH_MISMATCH',
    'remoteConfigurationInvalid',
    'remoteSubmissionDisabled',
    'localSnapshotAfterTrustRevocation',
    'JSON.stringify(value).slice(1, -1)',
    'serializedSensitiveRepresentations(value)',
    'Get-SerializedSensitiveRepresentations',
    'Assert-NoSerializedSensitiveValue',
    'Get-ControlledFixtureState',
    'Get-Sha256 $installedDaemonPath',
    'Get-Sha256 $installedBridgePath',
    'Get-TemporaryRootCount',
    'Assert-EmptyCheckoutJournal',
    'Get-WorkingCopyContentSnapshot',
    'Get-WorkingCopyDatabaseProof',
    'Assert-WorkingCopyPreserved',
    'Wait-CandidateProcessAbsent',
    '$workingCopyDatabaseBefore.sizeBytes',
    '$workingCopyDatabaseBefore.sha256',
    '"u"', '"x"', '"w"', '"h"', '"e"'
  )) {
  Assert-True ($source.Contains($required)) "Installed trust-revoked probe is missing the contract lock: $required"
}
foreach ($forbidden in @(
    'SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_REPORT_TOKEN',
    'installedSvnAnonymousCancellationReport',
    'SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_AUTHZ_DENIED_REPORT_TOKEN',
    'installedSvnAnonymousAuthzDeniedReport',
    'crypto.randomUUID',
    'OperationTimeoutMilliseconds',
    'SUBVERSIONR_INSTALLED_I6_TRUST_REVOKED_TIMEOUT_MS',
    'Get-WmiObject',
    'Register-WmiEvent',
    'svn.exe',
    'svnadmin.exe',
    'synthetic',
    'fallback',
    'Remove-Item -LiteralPath $WorkingCopyPath',
    'Remove-Item -LiteralPath $workingCopyResolved'
  )) {
  Assert-True (-not $source.Contains($forbidden)) "Installed trust-revoked probe must not contain the forbidden fallback/destructive route: $forbidden"
}

$helperNames = @(
  "Get-Sha256", "Get-WorkingCopyContentSnapshot", "Get-WorkingCopyDatabaseProof", "Assert-WorkingCopyPreserved",
  "Get-SerializedSensitiveRepresentations", "Assert-NoSerializedSensitiveValue"
)
$helperSources = foreach ($functionName in $helperNames) {
  $matches = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName
      }, $true))
  Assert-True ($matches.Count -eq 1) "Installed trust-revoked probe must define exactly one $functionName helper."
  $matches[0].Extent.Text
}
Invoke-Expression ($helperSources -join "`n`n")

$windowsSensitivePath = 'C:\Evidence\I6\working-copy'
$escapedWindowsReport = [ordered]@{ diagnostics = $windowsSensitivePath } | ConvertTo-Json -Compress
Assert-True ($escapedWindowsReport.Contains('C:\\Evidence\\I6\\working-copy')) "PowerShell JSON must reproduce the escaped-backslash leak fixture."
Assert-ScriptThrowsContaining {
  Assert-NoSerializedSensitiveValue $escapedWindowsReport @($windowsSensitivePath) "escaped Windows path leak"
} "escaped Windows path leak" "Installed trust-revoked serialized redaction must reject escaped Windows paths."
Assert-NoSerializedSensitiveValue '{"diagnostics":null}' @($windowsSensitivePath) "clean report must not fail"

$harnessHelperMatch = [regex]::Match(
  $source,
  'function serializedSensitiveRepresentations\(value\) \{[\s\S]*?^\}',
  [System.Text.RegularExpressions.RegexOptions]::Multiline
)
Assert-True ($harnessHelperMatch.Success) "Installed trust-revoked harness redaction helper must be extractable."
$nodeProbe = @"
$($harnessHelperMatch.Value)
const value = process.argv[2];
const serialized = JSON.stringify({ diagnostics: value }).toLowerCase();
if (!serializedSensitiveRepresentations(value).some((entry) => serialized.includes(entry.toLowerCase()))) process.exit(9);
"@
$nodeProbe | & node - $windowsSensitivePath
Assert-True ($LASTEXITCODE -eq 0) "Installed trust-revoked harness helper must detect an escaped Windows path in JSON output."

New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
try {
  $workingCopyRoot = Join-Path $tempRoot "wc"
  $metadataRoot = Join-Path $workingCopyRoot ".svn"
  New-Item -ItemType Directory -Force -Path $metadataRoot | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $metadataRoot "wc.db"), "controlled-wc-database", [System.Text.UTF8Encoding]::new($false))

  $sentinelPath = Join-Path $workingCopyRoot "sentinel.txt"
  [System.IO.File]::WriteAllText($sentinelPath, "controlled sentinel`n", [System.Text.UTF8Encoding]::new($false))
  $emptyDirectoryPath = Join-Path $workingCopyRoot "empty-directory"
  New-Item -ItemType Directory -Path $emptyDirectoryPath | Out-Null
  $contentBefore = Get-WorkingCopyContentSnapshot $workingCopyRoot
  $databaseBefore = Get-WorkingCopyDatabaseProof $workingCopyRoot
  $contentEntries = @($contentBefore | ConvertFrom-Json)
  Assert-True ($contentEntries.Count -eq 2) "Installed trust-revoked content snapshot must record the complete non-metadata topology."
  $directoryEntry = @($contentEntries | Where-Object { $_.kind -ceq "directory" })
  Assert-True ($directoryEntry.Count -eq 1) "Installed trust-revoked content snapshot must record the empty directory."
  Assert-ExactProperties $directoryEntry[0] @("kind", "path") "installed trust-revoked directory snapshot entry"
  Assert-True ([string]$directoryEntry[0].path -ceq "empty-directory") "Installed trust-revoked directory snapshot path was invalid."
  $fileEntry = @($contentEntries | Where-Object { $_.kind -ceq "file" })
  Assert-True ($fileEntry.Count -eq 1) "Installed trust-revoked content snapshot must record the sentinel file."
  Assert-ExactProperties $fileEntry[0] @("kind", "path", "sha256", "sizeBytes") "installed trust-revoked file snapshot entry"
  Assert-True (
    [string]$fileEntry[0].path -ceq "sentinel.txt" -and
    [string]$fileEntry[0].sha256 -ceq (Get-Sha256 $sentinelPath) -and
    [int64]$fileEntry[0].sizeBytes -eq (Get-Item -LiteralPath $sentinelPath).Length
  ) "Installed trust-revoked file snapshot proof was invalid."
  Assert-WorkingCopyPreserved $workingCopyRoot $contentBefore $databaseBefore.sizeBytes $databaseBefore.sha256

  Remove-Item -LiteralPath $emptyDirectoryPath
  Assert-ScriptThrowsContaining {
    Assert-WorkingCopyPreserved $workingCopyRoot $contentBefore $databaseBefore.sizeBytes $databaseBefore.sha256
  } "changed working-copy user content" "Installed trust-revoked preservation must reject directory deletion."
  New-Item -ItemType Directory -Path $emptyDirectoryPath | Out-Null

  $addedDirectoryPath = Join-Path $workingCopyRoot "added-directory"
  New-Item -ItemType Directory -Path $addedDirectoryPath | Out-Null
  Assert-ScriptThrowsContaining {
    Assert-WorkingCopyPreserved $workingCopyRoot $contentBefore $databaseBefore.sizeBytes $databaseBefore.sha256
  } "changed working-copy user content" "Installed trust-revoked preservation must reject directory addition."
  Remove-Item -LiteralPath $addedDirectoryPath

  [System.IO.File]::AppendAllText($sentinelPath, "mutation", [System.Text.UTF8Encoding]::new($false))
  Assert-ScriptThrowsContaining {
    Assert-WorkingCopyPreserved $workingCopyRoot $contentBefore $databaseBefore.sizeBytes $databaseBefore.sha256
  } "changed working-copy user content" "Installed trust-revoked preservation must reject user-content mutation."
  [System.IO.File]::WriteAllText($sentinelPath, "controlled sentinel`n", [System.Text.UTF8Encoding]::new($false))

  [System.IO.File]::AppendAllText((Join-Path $metadataRoot "wc.db"), "mutation", [System.Text.UTF8Encoding]::new($false))
  Assert-ScriptThrowsContaining {
    Assert-WorkingCopyPreserved $workingCopyRoot $contentBefore $databaseBefore.sizeBytes $databaseBefore.sha256
  } "database size changed" "Installed trust-revoked preservation must reject working-copy database mutation."
  [System.IO.File]::WriteAllText((Join-Path $metadataRoot "wc.db"), "controlled-wc-database", [System.Text.UTF8Encoding]::new($false))

  [System.IO.File]::WriteAllText((Join-Path $metadataRoot "wc.db"), "controlled-wc-databasf", [System.Text.UTF8Encoding]::new($false))
  Assert-ScriptThrowsContaining {
    Assert-WorkingCopyPreserved $workingCopyRoot $contentBefore $databaseBefore.sizeBytes $databaseBefore.sha256
  } "database hash changed" "Installed trust-revoked preservation must reject same-size working-copy database mutation."
  [System.IO.File]::WriteAllText((Join-Path $metadataRoot "wc.db"), "controlled-wc-database", [System.Text.UTF8Encoding]::new($false))

  $binRoot = Join-Path $tempRoot "b"
  New-Item -ItemType Directory -Path $binRoot | Out-Null
  $codePath = Join-Path $binRoot "code.cmd"
  $fakeCodeScript = Join-Path $binRoot "fake-code.ps1"
  $vsixPath = Join-Path $binRoot "candidate.vsix"
  $daemonPath = Join-Path $binRoot "subversionr-daemon.exe"
  $bridgePath = Join-Path $binRoot "subversionr_svn_bridge.dll"
  $fixtureStatePath = Join-Path $tempRoot "greeting-stall-state.json"
  [System.IO.File]::WriteAllText($vsixPath, "controlled-vsix", [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText($daemonPath, "controlled-daemon", [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText($bridgePath, "controlled-bridge", [System.Text.UTF8Encoding]::new($false))
  [ordered]@{
    schema = "subversionr.release.m8-i6-ra-svn-fault-fixture.v1"; pid = 1234; port = 3690; suppliedAuthorityPort = 0
    scenario = "greeting-stall"; status = "ready"; connections = 0; suppliedAuthorityConnections = 0
    greetingSent = 0; clientResponseReceived = 0; authRequestSent = 0; reposInfoSent = 0; commandsReceived = 0; followupContacts = 0
  } | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $fixtureStatePath -Encoding utf8 -NoNewline
  $pwshPath = (Get-Process -Id $PID).Path
  $fakeCommand = @"
@set "SUBVERSIONR_FAKE_HARNESS_TEMP=%TEMP%"
@set "TEMP=%SUBVERSIONR_FAKE_ORIGINAL_TEMP%"
@set "TMP=%SUBVERSIONR_FAKE_ORIGINAL_TMP%"
@set "APPDATA=%SUBVERSIONR_FAKE_ORIGINAL_APPDATA%"
@set "LOCALAPPDATA=%SUBVERSIONR_FAKE_ORIGINAL_LOCALAPPDATA%"
@set "USERPROFILE=%SUBVERSIONR_FAKE_ORIGINAL_USERPROFILE%"
@set "HOME=%SUBVERSIONR_FAKE_ORIGINAL_HOME%"
@"$pwshPath" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0fake-code.ps1" %*
"@
  [System.IO.File]::WriteAllText($codePath, $fakeCommand, [System.Text.ASCIIEncoding]::new())
  @'
$ErrorActionPreference = "Stop"
$arguments = @($args)
function Required-Argument([string]$Name) {
  $index = [Array]::IndexOf($arguments, $Name)
  if ($index -lt 0 -or $index + 1 -ge $arguments.Count) { throw "Missing fake Code argument: $Name" }
  return [string]$arguments[$index + 1]
}
$extensionsRoot = Required-Argument "--extensions-dir"
$packageRoot = Join-Path $extensionsRoot "hitsuki-ban.subversionr-0.2.5"
if ($arguments -contains "--install-extension") {
  $backendRoot = Join-Path $packageRoot "resources\backend\win32-x64"
  New-Item -ItemType Directory -Force -Path $backendRoot | Out-Null
  '{"publisher":"hitsuki-ban","name":"subversionr","version":"0.2.5"}' | Set-Content -LiteralPath (Join-Path $packageRoot "package.json") -Encoding utf8 -NoNewline
  Copy-Item -LiteralPath $env:SUBVERSIONR_FAKE_DAEMON -Destination (Join-Path $backendRoot "subversionr-daemon.exe")
  Copy-Item -LiteralPath $env:SUBVERSIONR_FAKE_BRIDGE -Destination (Join-Path $backendRoot "subversionr_svn_bridge.dll")
  exit 0
}
if ($arguments -contains "--list-extensions") {
  Write-Output "hitsuki-ban.subversionr@0.2.5"
  exit 0
}
if (@($arguments | Where-Object { $_ -like "--extensionTestsPath=*" }).Count -eq 1) {
  New-Item -ItemType Directory -Force -Path (Join-Path $env:SUBVERSIONR_FAKE_HARNESS_TEMP "SubversionR\remote-workers") | Out-Null
  $report = [ordered]@{
    schema = "subversionr.release.m8-i6-installed-vsix-trust-revoked.v1"
    schemaVersion = 1
    kind = "subversionr.installedSvnAnonymousTrustRevokedReport"
    scenario = "trustRevoked"
    settlement = [ordered]@{
      code = "SUBVERSIONR_REMOTE_TRUST_EPOCH_MISMATCH"; category = "state"; messageKey = "error.remote.trustEpochMismatch"; retryable = $false
      remoteFailure = [ordered]@{ category = "configuration"; reason = "remoteConfigurationInvalid"; cleanupAppropriate = $false }
    }
    diagnostics = $null
    remoteSubmissionDisabled = $true
    localSnapshotAfterTrustRevocation = $true
    protocol = [ordered]@{ major = 1; minor = 35 }
    trust = [ordered]@{ initialAcknowledgedEpoch = 1; revokedAcknowledgedEpoch = 2; submissionEnabled = $false; consistent = $true }
    authActivity = [ordered]@{ credentialRequests = 0; credentialSettlements = 0; certificateRequests = 0 }
    repositorySession = [ordered]@{ opened = $true; closed = $true }
    diagnosticsRedacted = $true
    redaction = [ordered]@{ rawUrls = $false; rawPaths = $false; rawContent = $false }
  }
  [ordered]@{ extensionId = "hitsuki-ban.subversionr"; extensionVersion = "0.2.5"; extensionPath = $packageRoot; report = $report } |
    ConvertTo-Json -Depth 16 -Compress | Set-Content -LiteralPath $env:SUBVERSIONR_INSTALLED_I6_TRUST_REVOKED_RESULT -Encoding utf8 -NoNewline
  exit 0
}
throw "Unexpected fake Code invocation: $($arguments -join ' ')"
'@ | Set-Content -LiteralPath $fakeCodeScript -Encoding utf8 -NoNewline

  $badFixtureRoot = Join-Path $tempRoot "bad"
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probePath `
      -VsixPath "relative.vsix" -CodeCliPath $codePath -FixtureRoot $badFixtureRoot -WorkingCopyPath $workingCopyRoot `
      -RepositoryUrl "svn://127.0.0.1:3690/repo/trunk" -FixtureStatePath $fixtureStatePath -OperationId "50000000-0000-4000-8000-000000000002" `
      -ExpectedProductVersion "0.2.5" -DaemonPath $daemonPath -BridgePath $bridgePath -TimeoutSeconds 60
  } "VsixPath must be an absolute path" "Installed trust-revoked probe must fail before creating its harness for a relative VSIX path."
  Assert-True (-not (Test-Path -LiteralPath $badFixtureRoot)) "Installed trust-revoked argument failure must not create the harness root."

  $invalidStateFixtureRoot = Join-Path $tempRoot "bad-state"
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probePath `
      -VsixPath $vsixPath -CodeCliPath $codePath -FixtureRoot $invalidStateFixtureRoot -WorkingCopyPath $workingCopyRoot `
      -RepositoryUrl "svn://127.0.0.1:3690/repo/trunk" -FixtureStatePath "relative-state.json" -OperationId "50000000-0000-4000-8000-000000000002" `
      -ExpectedProductVersion "0.2.5" -DaemonPath $daemonPath -BridgePath $bridgePath -TimeoutSeconds 60
  } "FixtureStatePath must be an absolute path" "Installed trust-revoked probe must reject a relative fixture state path."
  Assert-True (-not (Test-Path -LiteralPath $invalidStateFixtureRoot)) "Installed trust-revoked fixture-state rejection must not create the harness root."

  $contactState = Get-Content -Raw -LiteralPath $fixtureStatePath | ConvertFrom-Json
  $contactState.connections = 1
  $contactState | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $fixtureStatePath -Encoding utf8 -NoNewline
  $contactFixtureRoot = Join-Path $tempRoot "bad-contact"
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probePath `
      -VsixPath $vsixPath -CodeCliPath $codePath -FixtureRoot $contactFixtureRoot -WorkingCopyPath $workingCopyRoot `
      -RepositoryUrl "svn://127.0.0.1:3690/repo/trunk" -FixtureStatePath $fixtureStatePath -OperationId "50000000-0000-4000-8000-000000000002" `
      -ExpectedProductVersion "0.2.5" -DaemonPath $daemonPath -BridgePath $bridgePath -TimeoutSeconds 60
  } "counter connections must remain zero" "Installed trust-revoked probe must reject any pre-existing fixture contact."
  Assert-True (-not (Test-Path -LiteralPath $contactFixtureRoot)) "Installed trust-revoked fixture-contact rejection must not create the harness root."
  $contactState.connections = 0
  $contactState | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $fixtureStatePath -Encoding utf8 -NoNewline

  $fixtureParent = Join-Path $tempRoot "f"
  New-Item -ItemType Directory -Path $fixtureParent | Out-Null
  $fixtureRoot = Join-Path $fixtureParent "r"
  $previousDaemon = $env:SUBVERSIONR_FAKE_DAEMON
  $previousBridge = $env:SUBVERSIONR_FAKE_BRIDGE
  $fakeOriginalNames = @("TEMP", "TMP", "APPDATA", "LOCALAPPDATA", "USERPROFILE", "HOME")
  $previousOriginals = @{}
  foreach ($name in $fakeOriginalNames) { $previousOriginals[$name] = [System.Environment]::GetEnvironmentVariable("SUBVERSIONR_FAKE_ORIGINAL_$name", "Process") }
  try {
    $env:SUBVERSIONR_FAKE_DAEMON = $daemonPath
    $env:SUBVERSIONR_FAKE_BRIDGE = $bridgePath
    foreach ($name in $fakeOriginalNames) {
      [System.Environment]::SetEnvironmentVariable("SUBVERSIONR_FAKE_ORIGINAL_$name", [System.Environment]::GetEnvironmentVariable($name, "Process"), "Process")
    }
    $output = & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probePath `
      -VsixPath $vsixPath -CodeCliPath $codePath -FixtureRoot $fixtureRoot -WorkingCopyPath $workingCopyRoot `
      -RepositoryUrl "svn://127.0.0.1:3690/repo/trunk" -FixtureStatePath $fixtureStatePath -OperationId "50000000-0000-4000-8000-000000000002" `
      -ExpectedProductVersion "0.2.5" -DaemonPath $daemonPath -BridgePath $bridgePath -TimeoutSeconds 60
    Assert-True ($LASTEXITCODE -eq 0) "Installed trust-revoked fake Code CLI probe must pass."
  }
  finally {
    if ($null -eq $previousDaemon) { Remove-Item Env:SUBVERSIONR_FAKE_DAEMON -ErrorAction SilentlyContinue } else { $env:SUBVERSIONR_FAKE_DAEMON = $previousDaemon }
    if ($null -eq $previousBridge) { Remove-Item Env:SUBVERSIONR_FAKE_BRIDGE -ErrorAction SilentlyContinue } else { $env:SUBVERSIONR_FAKE_BRIDGE = $previousBridge }
    foreach ($name in $fakeOriginalNames) {
      [System.Environment]::SetEnvironmentVariable("SUBVERSIONR_FAKE_ORIGINAL_$name", $previousOriginals[$name], "Process")
    }
  }
  $wrapper = ($output | Where-Object { $_ -is [string] -and $_.StartsWith("{") } | Select-Object -Last 1) | ConvertFrom-Json
  Assert-True ([string]$wrapper.schema -ceq "subversionr.release.m8-i6-installed-vsix-trust-revoked.v1") "Installed trust-revoked wrapper schema was invalid."
  Assert-True ([string]$wrapper.cell -ceq "trustRevoked" -and [string]$wrapper.status -ceq "passed") "Installed trust-revoked wrapper identity was invalid."
  Assert-True (
    [string]$wrapper.stableCode -ceq "SUBVERSIONR_REMOTE_TRUST_EPOCH_MISMATCH" -and
    [string]$wrapper.reason -ceq "remoteConfigurationInvalid" -and
    [int]$wrapper.trust.initialAcknowledgedEpoch -eq 1 -and
    [int]$wrapper.trust.revokedAcknowledgedEpoch -eq 2 -and
    $wrapper.trust.submissionEnabled -eq $false -and
    $wrapper.remoteSubmissionDisabled -eq $true -and
    $wrapper.localSnapshotAfterTrustRevocation -eq $true -and
    [int]$wrapper.fixtureContactsAfter -eq 0
  ) "Installed trust-revoked wrapper trust proof was invalid."
  Assert-True ($wrapper.workingCopyPreserved -eq $true -and [int]$wrapper.temporaryRootsAfter -eq 0 -and [int]$wrapper.checkoutJournalEntriesAfter -eq 0) "Installed trust-revoked wrapper cleanup proof was invalid."
  Assert-WorkingCopyPreserved $workingCopyRoot $contentBefore $databaseBefore.sizeBytes $databaseBefore.sha256
}
finally {
  if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

Write-Host "M8 I6 installed trust-revoked probe script tests passed."

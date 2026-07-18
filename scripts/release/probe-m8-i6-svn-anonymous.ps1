[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string]$RepositoryUrl,
  [Parameter(Mandatory = $true)] [string]$FixtureRoot,
  [Parameter(Mandatory = $true)] [string]$FixtureConfigPath,
  [Parameter(Mandatory = $true)] [string]$FixtureAuthzPath,
  [Parameter(Mandatory = $true)] [string]$FixtureLogPath,
  [Parameter(Mandatory = $true)] [string]$PackagedAuthzWorkingCopyPath,
  [Parameter(Mandatory = $true)] [string]$InstalledAuthzWorkingCopyPath,
  [Parameter(Mandatory = $true)] [string]$SvnPath,
  [Parameter(Mandatory = $true)] [string]$SvnadminPath,
  [Parameter(Mandatory = $true)] [string]$SvnservePath,
  [Parameter(Mandatory = $true)] [ValidateRange(1, 4294967295)] [long]$SvnservePid,
  [Parameter(Mandatory = $true)] [string]$SvnserveStartTimeUtc,
  [Parameter(Mandatory = $true)] [string]$VsixPath,
  [Parameter(Mandatory = $true)] [string]$DaemonPath,
  [Parameter(Mandatory = $true)] [string]$BridgePath,
  [Parameter(Mandatory = $true)] [string]$CodeCliPath,
  [Parameter(Mandatory = $true)] [string]$StageManifestPath,
  [Parameter(Mandatory = $true)] [string]$RaSvnOriginPatchPath,
  [Parameter(Mandatory = $true)] [string]$RaSvnOriginContractPath,
  [Parameter(Mandatory = $true)] [string]$NativeSourceLockPath,
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
  [string]$ExpectedProductVersion,
  [Parameter(Mandatory = $true)] [string]$OutputPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$packagedProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-vscode-packaged-native.mjs"))
$installedHarnessPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "test-vscode-installed-extension-host.ps1"))
$installedI6ProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-installed-vsix.ps1"))
$installedStressProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-installed-stress.ps1"))
$installedNegativeProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-installed-negative.ps1"))
$packagedAuthzDeniedProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-packaged-authz-denied.mjs"))
$installedAuthzDeniedProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-installed-authz-denied.ps1"))
$installedLocalEventProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-installed-local-event-zero-network.ps1"))
$countingProxyPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "serve-m8-i6-counting-proxy.mjs"))
$faultFixturePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "serve-m8-i6-ra-svn-fault-fixture.mjs"))
$packagedNegativeProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-packaged-negative.mjs"))
$installedHarnessRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence\installed-extension-host"))
$ProcessStartEventSettlementMilliseconds = 2000

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw $Message
  }
}

function Resolve-RequiredFile([string]$Path, [string]$Name) {
  Assert-True ([System.IO.Path]::IsPathFullyQualified($Path)) "$Name must be an absolute path."
  $resolved = [System.IO.Path]::GetFullPath($Path)
  Assert-True (Test-Path -LiteralPath $resolved -PathType Leaf) "$Name must be an existing file."
  return $resolved
}

function Resolve-RequiredDirectory([string]$Path, [string]$Name) {
  Assert-True ([System.IO.Path]::IsPathFullyQualified($Path)) "$Name must be an absolute path."
  $resolved = [System.IO.Path]::GetFullPath($Path)
  Assert-True (Test-Path -LiteralPath $resolved -PathType Container) "$Name must be an existing directory."
  return $resolved
}

function Test-PathWithin([string]$Path, [string]$Root) {
  $pathResolved = [System.IO.Path]::GetFullPath($Path)
  $rootResolved = [System.IO.Path]::GetFullPath($Root).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  ) + [System.IO.Path]::DirectorySeparatorChar
  return $pathResolved.StartsWith($rootResolved, [System.StringComparison]::OrdinalIgnoreCase)
}

function Resolve-FixtureFile([string]$Path, [string]$Name, [string]$Root) {
  $resolved = Resolve-RequiredFile $Path $Name
  Assert-True (Test-PathWithin $resolved $Root) "$Name must be below FixtureRoot."
  return $resolved
}

function Get-Sha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ZipEntry([System.IO.Compression.ZipArchive]$Archive, [string]$Name) {
  $entries = @($Archive.Entries | Where-Object { $_.FullName -ceq $Name })
  Assert-True ($entries.Count -eq 1) "VsixPath must contain exactly one '$Name' entry."
  return $entries[0]
}

function Get-ZipEntrySha256([System.IO.Compression.ZipArchiveEntry]$Entry) {
  $stream = $Entry.Open()
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = $sha.ComputeHash($stream)
    return [Convert]::ToHexString($bytes).ToLowerInvariant()
  }
  finally {
    $sha.Dispose()
    $stream.Dispose()
  }
}

function Read-ZipEntryText([System.IO.Compression.ZipArchiveEntry]$Entry) {
  $stream = $Entry.Open()
  $reader = [System.IO.StreamReader]::new(
    $stream,
    [System.Text.UTF8Encoding]::new($false, $true),
    $true,
    4096,
    $false
  )
  try {
    return $reader.ReadToEnd()
  }
  finally {
    $reader.Dispose()
  }
}

function Invoke-BoundedProcess(
  [string]$FilePath,
  [string[]]$Arguments,
  [int]$TimeoutSeconds,
  [hashtable]$Environment = @{}
) {
  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FilePath
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  foreach ($argument in $Arguments) {
    $startInfo.ArgumentList.Add($argument)
  }
  foreach ($entry in $Environment.GetEnumerator()) {
    $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
  }

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  try {
    Assert-True $process.Start() "Failed to start the controlled probe process."
    $processId = $process.Id
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      $process.Kill($true)
      $process.WaitForExit()
      throw "Controlled probe process exceeded its absolute deadline."
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    Assert-True ($stdout.Length -le 65536) "Controlled probe stdout exceeded 65536 bytes."
    Assert-True ($stderr.Length -le 32768) "Controlled probe stderr exceeded 32768 bytes."
    return [pscustomobject]@{
      ProcessId = $processId
      ExitCode = $process.ExitCode
      Stdout = $stdout
      Stderr = $stderr
    }
  }
  finally {
    $process.Dispose()
  }
}

function Get-CimProcessSnapshot {
  try {
    return @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
  }
  catch {
    throw "Process settlement observation through Win32_Process failed."
  }
}

function Get-ProcessSnapshotStartFileTime([object]$Process) {
  Assert-True ($null -ne $Process.CreationDate) "CIM did not expose a process creation time."
  return ([DateTime]$Process.CreationDate).ToUniversalTime().ToFileTimeUtc()
}

function Get-DescendantProcessIds([object[]]$Snapshot, [long]$RootPid) {
  $pending = [System.Collections.Generic.Queue[long]]::new()
  $pending.Enqueue($RootPid)
  $descendants = [System.Collections.Generic.List[long]]::new()
  while ($pending.Count -gt 0) {
    $parentPid = $pending.Dequeue()
    foreach ($child in @($Snapshot | Where-Object { [long]$_.ParentProcessId -eq $parentPid })) {
      $childPid = [long]$child.ProcessId
      if (-not $descendants.Contains($childPid)) {
        $descendants.Add($childPid)
        $pending.Enqueue($childPid)
      }
    }
  }
  return @($descendants)
}

function Receive-ProcessStartEvents(
  [string]$SourceIdentifier,
  [System.Collections.Generic.List[object]]$AllEvents,
  [System.Collections.Generic.HashSet[string]]$EventKeys
) {
  foreach ($queuedEvent in @(Get-Event -SourceIdentifier $SourceIdentifier -ErrorAction SilentlyContinue)) {
    try {
      $newEvent = $queuedEvent.SourceEventArgs.NewEvent
      Assert-True ($null -ne $newEvent) "The packaged-negative process-start subscription delivered an empty event."
      $processId = [long]$newEvent.ProcessID
      $parentProcessId = [long]$newEvent.ParentProcessID
      $processName = [string]$newEvent.ProcessName
      $eventFileTime = [long]$newEvent.TIME_CREATED
      Assert-True ($processId -gt 0 -and $parentProcessId -ge 0) "A packaged-negative process-start event contained invalid process identity."
      Assert-True (-not [string]::IsNullOrWhiteSpace($processName)) "A packaged-negative process-start event omitted its process name."
      Assert-True ($eventFileTime -gt 0) "A packaged-negative process-start event omitted its event time."
      $eventKey = "$processId`:$eventFileTime"
      Assert-True ($EventKeys.Add($eventKey)) "The packaged-negative process-start subscription delivered a duplicate event identity."
      $AllEvents.Add([pscustomobject]@{
          processId = $processId
          parentProcessId = $parentProcessId
          processName = $processName
          eventFileTime = $eventFileTime
        })
    }
    finally {
      Remove-Event -EventIdentifier $queuedEvent.EventIdentifier -ErrorAction SilentlyContinue
    }
  }
}

function Complete-ProcessStartEventDrain(
  [string]$SourceIdentifier,
  [System.Collections.Generic.List[object]]$AllEvents,
  [System.Collections.Generic.HashSet[string]]$EventKeys,
  [int]$SettlementMilliseconds
) {
  $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($SettlementMilliseconds)
  do {
    Receive-ProcessStartEvents $SourceIdentifier $AllEvents $EventKeys
    Start-Sleep -Milliseconds 25
  } while ([DateTimeOffset]::UtcNow -lt $deadline)
  Receive-ProcessStartEvents $SourceIdentifier $AllEvents $EventKeys
}

function Get-RecordedProcessDescendantStarts([object[]]$AllEvents, [long]$RootPid) {
  $pending = [System.Collections.Generic.Queue[long]]::new()
  $pending.Enqueue($RootPid)
  $descendants = [System.Collections.Generic.List[object]]::new()
  $descendantPids = [System.Collections.Generic.HashSet[long]]::new()
  while ($pending.Count -gt 0) {
    $parentPid = $pending.Dequeue()
    foreach ($child in @($AllEvents | Where-Object { [long]$_.parentProcessId -eq $parentPid })) {
      $childPid = [long]$child.processId
      Assert-True ($childPid -ne $RootPid) "A packaged-negative worker PID was reused in its recorded ancestry."
      if ($descendantPids.Add($childPid)) {
        $descendants.Add($child)
        $pending.Enqueue($childPid)
      }
    }
  }
  return @($descendants)
}

function Get-PackagedNegativeProcessObservation(
  [object[]]$AllEvents,
  [long]$ProbePid,
  [string]$ExpectedProbeProcessName,
  [string]$ExpectedDaemonProcessName,
  [object[]]$SettlementSnapshot,
  [string[]]$ForbiddenFixtureProcessNames = @("svn.exe", "svnadmin.exe", "svnserve.exe")
) {
  $probeStarts = @($AllEvents | Where-Object {
      [long]$_.processId -eq $ProbePid -and
      ([string]$_.processName).Equals($ExpectedProbeProcessName, [System.StringComparison]::OrdinalIgnoreCase)
    })
  Assert-True ($probeStarts.Count -eq 1) "The packaged-negative probe PID must have exactly one subscribed start identity."
  Assert-True (
    @($AllEvents | Where-Object { [long]$_.processId -eq $ProbePid }).Count -eq 1
  ) "The packaged-negative probe PID was reused during its subscribed observation."

  $daemonStarts = @($AllEvents | Where-Object {
      [long]$_.parentProcessId -eq $ProbePid -and
      ([string]$_.processName).Equals($ExpectedDaemonProcessName, [System.StringComparison]::OrdinalIgnoreCase)
    })
  $probeChildSummary = @($AllEvents | Where-Object { [long]$_.parentProcessId -eq $ProbePid } |
      Select-Object -First 8 | ForEach-Object { "$([string]$_.processName):$([long]$_.processId)" }) -join ","
  Assert-True ($daemonStarts.Count -eq 1) "The exact packaged-negative probe must start exactly one candidate daemon; observed $($daemonStarts.Count) candidate starts and children $probeChildSummary."
  $daemonStart = $daemonStarts[0]
  Assert-True (
    @($AllEvents | Where-Object { [long]$_.processId -eq [long]$daemonStart.processId }).Count -eq 1
  ) "The packaged-negative candidate daemon PID was reused."

  $workerStarts = @($AllEvents | Where-Object {
      [long]$_.parentProcessId -eq [long]$daemonStart.processId -and
      ([string]$_.processName).Equals($ExpectedDaemonProcessName, [System.StringComparison]::OrdinalIgnoreCase)
    })
  $daemonChildSummary = @($AllEvents | Where-Object { [long]$_.parentProcessId -eq [long]$daemonStart.processId } |
      Select-Object -First 8 | ForEach-Object { "$([string]$_.processName):$([long]$_.processId)" }) -join ","
  Assert-True ($workerStarts.Count -eq 1) "The packaged-negative candidate daemon must start exactly one worker; observed $($workerStarts.Count) candidate starts and children $daemonChildSummary."
  $workerStart = $workerStarts[0]
  Assert-True (
    [long]$probeStarts[0].eventFileTime -lt [long]$daemonStart.eventFileTime -and
    [long]$daemonStart.eventFileTime -lt [long]$workerStart.eventFileTime
  ) "The packaged-negative probe, daemon, and worker start identities are not strictly ordered."
  Assert-True (
    @($AllEvents | Where-Object { [long]$_.processId -eq [long]$workerStart.processId }).Count -eq 1
  ) "The packaged-negative worker PID was reused."
  $descendantStarts = @(Get-RecordedProcessDescendantStarts $AllEvents ([long]$workerStart.processId))
  $allProbeDescendants = @(Get-RecordedProcessDescendantStarts $AllEvents $ProbePid)
  $forbiddenFixtureProcessNameSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
  )
  foreach ($processName in $ForbiddenFixtureProcessNames) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($processName)) "A packaged-negative forbidden fixture process name was invalid."
    $null = $forbiddenFixtureProcessNameSet.Add($processName)
  }
  Assert-True ($forbiddenFixtureProcessNameSet.Count -eq $ForbiddenFixtureProcessNames.Count) "Packaged-negative forbidden fixture process names must be unique."
  $fixtureCliStarts = @($allProbeDescendants | Where-Object {
      $forbiddenFixtureProcessNameSet.Contains([string]$_.processName)
    })
  foreach ($settledStart in @($probeStarts[0], $daemonStart, $workerStart)) {
    $liveSettledIdentity = @(
      $SettlementSnapshot | Where-Object {
        [long]$_.ProcessId -eq [long]$settledStart.processId -and
        (Get-ProcessSnapshotStartFileTime $_) -le [long]$settledStart.eventFileTime
      }
    )
    Assert-True ($liveSettledIdentity.Count -eq 0) "A packaged-negative probe/daemon/worker identity remained alive at settlement."
  }
  $liveDescendantIds = [System.Collections.Generic.HashSet[long]]::new()
  foreach ($descendantStart in $descendantStarts) {
    $liveDescendantIdentity = @(
      $SettlementSnapshot | Where-Object {
        [long]$_.ProcessId -eq [long]$descendantStart.processId -and
        (Get-ProcessSnapshotStartFileTime $_) -le [long]$descendantStart.eventFileTime
      }
    )
    if ($liveDescendantIdentity.Count -gt 0) {
      $null = $liveDescendantIds.Add([long]$descendantStart.processId)
    }
  }
  $liveDescendants = @($liveDescendantIds)
  Assert-True ($liveDescendants.Count -eq 0) "The exited packaged-negative worker retained live orphan descendants."
  return [pscustomobject]@{
    daemonProcessId = [long]$daemonStart.processId
    workerProcessId = [long]$workerStart.processId
    workerDescendantsAfter = $liveDescendants.Count
    fixtureCliInvocations = $fixtureCliStarts.Count
  }
}

function Set-ExactAuthzAtomically([string]$Path, [string]$Content) {
  $temporaryPath = Join-Path (Split-Path -Parent $Path) ".subversionr-authz-$([Guid]::NewGuid().ToString('N')).tmp"
  try {
    [System.IO.File]::WriteAllText($temporaryPath, $Content, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Move($temporaryPath, $Path, $true)
    $actual = (Get-Content -Raw -LiteralPath $Path).Replace("`r`n", "`n")
    Assert-True ($actual -ceq $Content) "The controlled authz bytes did not settle exactly."
  }
  finally {
    if (Test-Path -LiteralPath $temporaryPath) {
      Remove-Item -LiteralPath $temporaryPath -Force
    }
  }
  $residue = @(Get-ChildItem -LiteralPath (Split-Path -Parent $Path) -Filter ".subversionr-authz-*.tmp" -File)
  Assert-True ($residue.Count -eq 0) "The controlled authz atomic replacement left temporary files."
}

function Get-SvnserveAuthzObservation([string]$LogPath, [long]$Offset, [string]$Context) {
  $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
  do {
    $stream = [System.IO.FileStream]::new(
      $LogPath,
      [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::Read,
      [System.IO.FileShare]::ReadWrite
    )
    try {
      Assert-True ($Offset -ge 0 -and $Offset -le $stream.Length) "$Context svnserve log offset was invalid."
      $null = $stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
      $reader = [System.IO.StreamReader]::new($stream, [System.Text.UTF8Encoding]::new($false, $true), $true, 4096, $true)
      try { $delta = $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
    $lines = @($delta -split '\r?\n' | Where-Object { $_.Length -gt 0 })
    if ($lines.Count -eq 2) {
      break
    }
    Start-Sleep -Milliseconds 50
  } while ([DateTimeOffset]::UtcNow -lt $deadline)
  Assert-True ($lines.Count -eq 2) "$Context must append exactly two svnserve command-log lines."
  $openLines = @($lines | Where-Object { $_ -match '\brepo open\b' -and $_ -match '/denied\b' })
  $deniedLines = @($lines | Where-Object { $_ -match '\brepo ERR - 0 170001 Authorization failed$' })
  Assert-True ($openLines.Count -eq 1) "$Context must contain exactly one denied repository open."
  Assert-True ($deniedLines.Count -eq 1) "$Context must contain exactly one SVN authz denial."
  return [pscustomobject]@{
    networkAttempts = $deniedLines.Count
    networkConnections = $openLines.Count
    networkProgress = "command"
  }
}

function Get-InstalledNegativeProcessObservation(
  [object[]]$AllEvents,
  [long]$ProbePid,
  [string]$ExpectedProbeProcessName,
  [string]$ExpectedDaemonProcessName,
  [string[]]$ForbiddenFixtureProcessNames,
  [object[]]$SettlementSnapshot
) {
  $probeStarts = @($AllEvents | Where-Object {
      [long]$_.processId -eq $ProbePid -and
      ([string]$_.processName).Equals($ExpectedProbeProcessName, [System.StringComparison]::OrdinalIgnoreCase)
    })
  Assert-True ($probeStarts.Count -eq 1) "The installed-negative probe PID must have exactly one subscribed start identity."
  Assert-True (
    @($AllEvents | Where-Object { [long]$_.processId -eq $ProbePid }).Count -eq 1
  ) "The installed-negative probe PID was reused during its subscribed observation."

  $recordedDescendants = @(Get-RecordedProcessDescendantStarts $AllEvents $ProbePid)
  $forbiddenFixtureProcessNameSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
  )
  foreach ($processName in $ForbiddenFixtureProcessNames) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($processName)) "An installed-negative forbidden fixture process name was invalid."
    $null = $forbiddenFixtureProcessNameSet.Add($processName)
  }
  Assert-True ($forbiddenFixtureProcessNameSet.Count -eq $ForbiddenFixtureProcessNames.Count) "Installed-negative forbidden fixture process names must be unique."
  $fixtureCliStarts = @($recordedDescendants | Where-Object {
      $forbiddenFixtureProcessNameSet.Contains([string]$_.processName)
    })
  $candidateStarts = @($recordedDescendants | Where-Object {
      ([string]$_.processName).Equals($ExpectedDaemonProcessName, [System.StringComparison]::OrdinalIgnoreCase)
    })
  Assert-True ($candidateStarts.Count -eq 2) "The installed-negative Extension Host must start exactly one candidate daemon and one worker."
  foreach ($candidateStart in $candidateStarts) {
    Assert-True (
      @($AllEvents | Where-Object { [long]$_.processId -eq [long]$candidateStart.processId }).Count -eq 1
    ) "An installed-negative candidate process PID was reused."
  }

  $candidatePids = [System.Collections.Generic.HashSet[long]]::new()
  foreach ($candidateStart in $candidateStarts) {
    $null = $candidatePids.Add([long]$candidateStart.processId)
  }
  $daemonStarts = @($candidateStarts | Where-Object {
      -not $candidatePids.Contains([long]$_.parentProcessId)
    })
  Assert-True ($daemonStarts.Count -eq 1) "The installed-negative candidate daemon ancestry was ambiguous."
  $daemonStart = $daemonStarts[0]
  $workerStarts = @($candidateStarts | Where-Object {
      [long]$_.parentProcessId -eq [long]$daemonStart.processId
    })
  Assert-True ($workerStarts.Count -eq 1) "The installed-negative candidate daemon must start exactly one direct worker."
  $workerStart = $workerStarts[0]
  Assert-True (
    [long]$probeStarts[0].eventFileTime -lt [long]$daemonStart.eventFileTime -and
    [long]$daemonStart.eventFileTime -lt [long]$workerStart.eventFileTime
  ) "The installed-negative probe, daemon, and worker start identities are not strictly ordered."

  $workerDescendantStarts = @(Get-RecordedProcessDescendantStarts $AllEvents ([long]$workerStart.processId))
  $settledIdentities = @($daemonStart, $workerStart) + $workerDescendantStarts
  $liveSettledIds = [System.Collections.Generic.HashSet[long]]::new()
  foreach ($settledStart in $settledIdentities) {
    $liveSettledIdentity = @($SettlementSnapshot | Where-Object {
        [long]$_.ProcessId -eq [long]$settledStart.processId -and
        (Get-ProcessSnapshotStartFileTime $_) -le [long]$settledStart.eventFileTime
      })
    if ($liveSettledIdentity.Count -gt 0) {
      $null = $liveSettledIds.Add([long]$settledStart.processId)
    }
  }
  Assert-True ($liveSettledIds.Count -eq 0) "The installed-negative daemon, worker, or worker descendant remained alive at settlement."
  return [pscustomobject]@{
    daemonProcessId = [long]$daemonStart.processId
    workerProcessId = [long]$workerStart.processId
    workerDescendantsAfter = $liveSettledIds.Count
    fixtureCliInvocations = $fixtureCliStarts.Count
  }
}

function Get-InstalledLocalEventProcessObservation(
  [object[]]$AllEvents,
  [long]$ProbePid,
  [string]$ExpectedProbeProcessName,
  [string]$ExpectedDaemonProcessName,
  [string[]]$ForbiddenFixtureProcessNames,
  [object[]]$SettlementSnapshot
) {
  $probeStarts = @($AllEvents | Where-Object {
      [long]$_.processId -eq $ProbePid -and
      ([string]$_.processName).Equals($ExpectedProbeProcessName, [System.StringComparison]::OrdinalIgnoreCase)
    })
  Assert-True ($probeStarts.Count -eq 1) "The installed local-event probe PID must have exactly one subscribed start identity."
  Assert-True (
    @($AllEvents | Where-Object { [long]$_.processId -eq $ProbePid }).Count -eq 1
  ) "The installed local-event probe PID was reused during its subscribed observation."

  $recordedDescendants = @(Get-RecordedProcessDescendantStarts $AllEvents $ProbePid)
  $candidateStarts = @($recordedDescendants | Where-Object {
      ([string]$_.processName).Equals($ExpectedDaemonProcessName, [System.StringComparison]::OrdinalIgnoreCase)
    })
  Assert-True ($candidateStarts.Count -eq 1) "The installed local-event surface must start exactly one candidate daemon and no remote worker."
  $daemonStart = $candidateStarts[0]
  Assert-True (
    [long]$probeStarts[0].eventFileTime -lt [long]$daemonStart.eventFileTime -and
    @($AllEvents | Where-Object { [long]$_.processId -eq [long]$daemonStart.processId }).Count -eq 1
  ) "The installed local-event candidate daemon start identity was invalid or reused."
  $daemonDescendantStarts = @(Get-RecordedProcessDescendantStarts $AllEvents ([long]$daemonStart.processId))
  Assert-True ($daemonDescendantStarts.Count -eq 0) "The installed local-event status refresh started a remote worker or another daemon descendant."

  $forbiddenNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($processName in $ForbiddenFixtureProcessNames) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($processName)) "An installed local-event forbidden fixture process name was invalid."
    $null = $forbiddenNames.Add($processName)
  }
  Assert-True ($forbiddenNames.Count -eq $ForbiddenFixtureProcessNames.Count) "Installed local-event forbidden fixture process names must be unique."
  $fixtureCliStarts = @($recordedDescendants | Where-Object { $forbiddenNames.Contains([string]$_.processName) })

  $liveDaemon = @($SettlementSnapshot | Where-Object {
      [long]$_.ProcessId -eq [long]$daemonStart.processId -and
      (Get-ProcessSnapshotStartFileTime $_) -le [long]$daemonStart.eventFileTime
    })
  Assert-True ($liveDaemon.Count -eq 0) "The installed local-event candidate daemon remained alive at settlement."
  return [pscustomobject]@{
    daemonProcessId = [long]$daemonStart.processId
    workerStarts = $daemonDescendantStarts.Count
    workerDescendantsAfter = $liveDaemon.Count
    fixtureCliInvocations = $fixtureCliStarts.Count
  }
}

function Get-CandidateProcessIds([string]$ExecutablePath) {
  try {
    return @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
      Where-Object {
        -not [string]::IsNullOrEmpty([string]$_.ExecutablePath) -and
        ([System.IO.Path]::GetFullPath([string]$_.ExecutablePath)).Equals(
          $ExecutablePath,
          [System.StringComparison]::OrdinalIgnoreCase
        )
      } |
      ForEach-Object { [int]$_.ProcessId })
  }
  catch {
    throw "Candidate process observation through Win32_Process failed."
  }
}

function Assert-CandidateProcessAbsent([string]$ExecutablePath, [string]$Context, [int]$DeadlineMilliseconds = 0) {
  $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($DeadlineMilliseconds)
  do {
    $processIds = @(Get-CandidateProcessIds $ExecutablePath)
    if ($processIds.Count -eq 0) {
      return
    }
    if ([DateTimeOffset]::UtcNow -ge $deadline) {
      throw "$Context left candidate daemon/worker processes: $($processIds -join ',')."
    }
    Start-Sleep -Milliseconds 50
  } while ($true)
}

function Read-FaultFixtureState([string]$StatePath, [string]$Scenario, [System.Diagnostics.Process]$Process) {
  $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
  while ([DateTimeOffset]::UtcNow -lt $deadline) {
    if ($Process.HasExited) {
      throw "The $Scenario ra_svn fault fixture exited before readiness."
    }
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
      try {
        $state = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json -Depth 16
        if ([string]$state.status -ceq "ready") {
          $expectedProperties = @(
            "schema", "pid", "port", "suppliedAuthorityPort", "scenario", "connections",
            "suppliedAuthorityConnections", "greetingSent", "clientResponseReceived",
            "authRequestSent", "reposInfoSent", "commandsReceived", "followupContacts", "status"
          ) | Sort-Object
          $actualProperties = @($state.PSObject.Properties.Name | Sort-Object)
          Assert-True (($actualProperties -join ",") -ceq ($expectedProperties -join ",")) "The $Scenario ra_svn fault fixture state shape was invalid."
          Assert-True ([string]$state.schema -ceq "subversionr.release.m8-i6-ra-svn-fault-fixture.v1") "The $Scenario ra_svn fault fixture schema was invalid."
          Assert-True ([int]$state.pid -eq $Process.Id -and [string]$state.scenario -ceq $Scenario) "The $Scenario ra_svn fault fixture identity was invalid."
          Assert-True ([int]$state.port -ge 1 -and [int]$state.port -le 65535) "The $Scenario ra_svn fault fixture port was invalid."
          return $state
        }
      }
      catch {
        if ([DateTimeOffset]::UtcNow -ge $deadline) {
          throw
        }
      }
    }
    Start-Sleep -Milliseconds 25
  }
  throw "The $Scenario ra_svn fault fixture did not become ready before its deadline."
}

function Start-FaultFixture(
  [string]$NodeHost,
  [string]$FixtureScript,
  [string]$Scenario,
  [string]$StatePath
) {
  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $NodeHost
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.Environment["ELECTRON_RUN_AS_NODE"] = "1"
  foreach ($argument in @(
      $FixtureScript,
      "--scenario", $Scenario,
      "--listen-host", "127.0.0.1",
      "--port", "0",
      "--state-path", $StatePath
    )) {
    $startInfo.ArgumentList.Add($argument)
  }
  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  Assert-True $process.Start() "Failed to start the $Scenario ra_svn fault fixture."
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()
  try {
    $state = Read-FaultFixtureState $StatePath $Scenario $process
    return [pscustomobject]@{
      Process = $process
      State = $state
      StatePath = $StatePath
      StdoutTask = $stdoutTask
      StderrTask = $stderrTask
    }
  }
  catch {
    if (-not $process.HasExited) {
      $process.Kill($true)
      $process.WaitForExit()
    }
    $process.Dispose()
    throw
  }
}

function Stop-FaultFixture([object]$Fixture, [string]$Scenario) {
  $process = [System.Diagnostics.Process]$Fixture.Process
  try {
    if (-not $process.HasExited) {
      $process.StandardInput.Write("stop`n")
      $process.StandardInput.Flush()
      $process.StandardInput.Close()
      if (-not $process.WaitForExit(10000)) {
        $process.Kill($true)
        $process.WaitForExit()
        throw "The $Scenario ra_svn fault fixture exceeded its shutdown deadline."
      }
    }
    $stdout = $Fixture.StdoutTask.GetAwaiter().GetResult()
    $stderr = $Fixture.StderrTask.GetAwaiter().GetResult()
    Assert-True ($process.ExitCode -eq 0 -and $stdout.Length -eq 0 -and $stderr.Length -eq 0) "The $Scenario ra_svn fault fixture did not stop cleanly."
    $finalState = Get-Content -Raw -LiteralPath $Fixture.StatePath | ConvertFrom-Json -Depth 16
    Assert-True ([string]$finalState.status -ceq "stopped") "The $Scenario ra_svn fault fixture final state was invalid."
  }
  finally {
    $process.Dispose()
  }
}

function Read-CountingProxyState(
  [string]$StatePath,
  [System.Diagnostics.Process]$Process,
  [bool]$RequireIdle = $false
) {
  $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
  while ([DateTimeOffset]::UtcNow -lt $deadline) {
    if ($Process.HasExited) {
      throw "The I6 counting proxy exited before its state was ready."
    }
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
      $state = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json -Depth 8
      $expectedProperties = @(
        "schema", "pid", "listenHost", "port", "upstreamHost", "upstreamPort",
          "acceptedConnections", "upstreamAttempts", "upstreamConnections",
          "clientToUpstreamBytes", "upstreamToClientBytes",
        "activeConnections", "upstreamConnectFailures", "status"
      ) | Sort-Object
      $actualProperties = @($state.PSObject.Properties.Name | Sort-Object)
      Assert-True (($actualProperties -join ",") -ceq ($expectedProperties -join ",")) "The I6 counting proxy state shape was invalid."
      Assert-True (
        [string]$state.schema -ceq "subversionr.release.m8-i6-counting-proxy.v1" -and
        [int]$state.pid -eq $Process.Id -and
        [string]$state.listenHost -ceq "127.0.0.1" -and
        [string]$state.upstreamHost -ceq "127.0.0.1" -and
        [int]$state.port -ge 1 -and [int]$state.port -le 65535 -and
        [int]$state.upstreamPort -ge 1 -and [int]$state.upstreamPort -le 65535 -and
        [int64]$state.acceptedConnections -ge 0 -and [int64]$state.upstreamAttempts -ge 0 -and
        [int64]$state.upstreamConnections -ge 0 -and
        [int64]$state.clientToUpstreamBytes -ge 0 -and [int64]$state.upstreamToClientBytes -ge 0 -and
        [int]$state.activeConnections -ge 0 -and [int]$state.upstreamConnectFailures -ge 0
      ) "The I6 counting proxy state values were invalid."
      if ([string]$state.status -ceq "ready" -and (-not $RequireIdle -or [int]$state.activeConnections -eq 0)) {
        return $state
      }
    }
    Start-Sleep -Milliseconds 25
  }
  throw "The I6 counting proxy did not reach its required state before the deadline."
}

function Start-CountingProxy(
  [string]$NodeHost,
  [string]$ProxyScript,
  [int]$UpstreamPort,
  [string]$StatePath
) {
  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $NodeHost
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.Environment["ELECTRON_RUN_AS_NODE"] = "1"
  foreach ($argument in @(
      $ProxyScript,
      "--listen-host", "127.0.0.1",
      "--port", "0",
      "--upstream-host", "127.0.0.1",
      "--upstream-port", ([string]$UpstreamPort),
      "--state-path", $StatePath
    )) {
    $startInfo.ArgumentList.Add($argument)
  }
  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  Assert-True $process.Start() "Failed to start the I6 transparent counting proxy."
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()
  try {
    $state = Read-CountingProxyState $StatePath $process
    return [pscustomobject]@{
      Process = $process; State = $state; StatePath = $StatePath
      StdoutTask = $stdoutTask; StderrTask = $stderrTask
    }
  }
  catch {
    if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
    $process.Dispose()
    throw
  }
}

function Stop-CountingProxy([object]$Proxy) {
  $process = [System.Diagnostics.Process]$Proxy.Process
  try {
    if (-not $process.HasExited) {
      $process.StandardInput.Write("stop`n")
      $process.StandardInput.Flush()
      $process.StandardInput.Close()
      if (-not $process.WaitForExit(10000)) {
        $process.Kill($true)
        $process.WaitForExit()
        throw "The I6 counting proxy exceeded its shutdown deadline."
      }
    }
    $stdout = $Proxy.StdoutTask.GetAwaiter().GetResult()
    $stderr = $Proxy.StderrTask.GetAwaiter().GetResult()
    Assert-True ($process.ExitCode -eq 0 -and $stdout.Length -eq 0 -and $stderr.Length -eq 0) "The I6 counting proxy did not stop cleanly."
    $finalState = Get-Content -Raw -LiteralPath $Proxy.StatePath | ConvertFrom-Json -Depth 8
    Assert-True ([string]$finalState.status -ceq "stopped" -and [int]$finalState.activeConnections -eq 0) "The I6 counting proxy final state was invalid."
    return $finalState
  }
  finally {
    $process.Dispose()
  }
}

function Resolve-CodeNodeHost([string]$CodePath) {
  $leaf = [System.IO.Path]::GetFileName($CodePath)
  if ($leaf.Equals("code.exe", [System.StringComparison]::OrdinalIgnoreCase)) {
    return $CodePath
  }
  Assert-True ($leaf.Equals("code.cmd", [System.StringComparison]::OrdinalIgnoreCase)) "CodeCliPath must point to code.cmd or code.exe."
  $candidate = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $CodePath) "..\Code.exe"))
  Assert-True (Test-Path -LiteralPath $candidate -PathType Leaf) "CodeCliPath must identify a VS Code installation with an adjacent Code.exe Node host."
  return $candidate
}

function Assert-ToolVersion([string]$ToolPath, [string]$Name) {
  $result = Invoke-BoundedProcess $ToolPath @("--version", "--quiet") 15
  Assert-True ($result.ExitCode -eq 0) "$Name version check failed."
  $lines = @($result.Stdout.Trim() -split '\r?\n')
  Assert-True ($lines.Count -ge 1 -and $lines[0] -ceq "1.14.5") "$Name must be source-built Apache Subversion 1.14.5."
}

function Convert-JsonObject([string]$Text, [string]$Name) {
  try {
    $value = $Text | ConvertFrom-Json -Depth 64
  }
  catch {
    throw "$Name must contain one valid JSON document."
  }
  Assert-True ($null -ne $value) "$Name must contain one valid JSON document."
  return $value
}

$fixtureRootResolved = Resolve-RequiredDirectory $FixtureRoot "FixtureRoot"
Assert-True ([System.IO.Path]::IsPathFullyQualified($OutputPath)) "OutputPath must be an absolute path."
$outputResolved = [System.IO.Path]::GetFullPath($OutputPath)
Assert-True (Test-PathWithin $outputResolved $fixtureRootResolved) "OutputPath must be below FixtureRoot."
Assert-True (-not $outputResolved.Equals($fixtureRootResolved, [System.StringComparison]::OrdinalIgnoreCase)) "OutputPath must name a file below FixtureRoot."
if (Test-Path -LiteralPath $outputResolved) {
  Assert-True (Test-Path -LiteralPath $outputResolved -PathType Leaf) "OutputPath must not be an existing directory."
  Remove-Item -LiteralPath $outputResolved -Force
}

$fixtureConfigResolved = Resolve-FixtureFile $FixtureConfigPath "FixtureConfigPath" $fixtureRootResolved
$fixtureAuthzResolved = Resolve-FixtureFile $FixtureAuthzPath "FixtureAuthzPath" $fixtureRootResolved
$fixtureLogResolved = Resolve-FixtureFile $FixtureLogPath "FixtureLogPath" $fixtureRootResolved
$packagedAuthzWorkingCopyResolved = Resolve-RequiredDirectory $PackagedAuthzWorkingCopyPath "PackagedAuthzWorkingCopyPath"
$installedAuthzWorkingCopyResolved = Resolve-RequiredDirectory $InstalledAuthzWorkingCopyPath "InstalledAuthzWorkingCopyPath"
Assert-True (Test-PathWithin $packagedAuthzWorkingCopyResolved $fixtureRootResolved) "PackagedAuthzWorkingCopyPath must be below FixtureRoot."
Assert-True (Test-PathWithin $installedAuthzWorkingCopyResolved $fixtureRootResolved) "InstalledAuthzWorkingCopyPath must be below FixtureRoot."
Assert-True (-not $packagedAuthzWorkingCopyResolved.Equals($installedAuthzWorkingCopyResolved, [System.StringComparison]::OrdinalIgnoreCase)) "The authz-denied surfaces require distinct working copies."
$svnResolved = Resolve-RequiredFile $SvnPath "SvnPath"
$svnadminResolved = Resolve-RequiredFile $SvnadminPath "SvnadminPath"
$svnserveResolved = Resolve-RequiredFile $SvnservePath "SvnservePath"
$vsixResolved = Resolve-RequiredFile $VsixPath "VsixPath"
$daemonResolved = Resolve-RequiredFile $DaemonPath "DaemonPath"
$bridgeResolved = Resolve-RequiredFile $BridgePath "BridgePath"
$codeCliResolved = Resolve-RequiredFile $CodeCliPath "CodeCliPath"
$stageManifestResolved = Resolve-RequiredFile $StageManifestPath "StageManifestPath"
$patchResolved = Resolve-RequiredFile $RaSvnOriginPatchPath "RaSvnOriginPatchPath"
$patchContractResolved = Resolve-RequiredFile $RaSvnOriginContractPath "RaSvnOriginContractPath"
$sourceLockResolved = Resolve-RequiredFile $NativeSourceLockPath "NativeSourceLockPath"
$packagedProbeResolved = Resolve-RequiredFile $packagedProbePath "packaged native probe"
$installedHarnessResolved = Resolve-RequiredFile $installedHarnessPath "installed Extension Host harness"
$installedI6ProbeResolved = Resolve-RequiredFile $installedI6ProbePath "installed I6 Extension Host probe"
$installedStressProbeResolved = Resolve-RequiredFile $installedStressProbePath "installed I6 100+1 stress probe"
$installedNegativeProbeResolved = Resolve-RequiredFile $installedNegativeProbePath "installed I6 negative Extension Host probe"
$packagedAuthzDeniedProbeResolved = Resolve-RequiredFile $packagedAuthzDeniedProbePath "packaged-native I6 authz-denied probe"
$installedAuthzDeniedProbeResolved = Resolve-RequiredFile $installedAuthzDeniedProbePath "installed VSIX I6 authz-denied probe"
$installedLocalEventProbeResolved = Resolve-RequiredFile $installedLocalEventProbePath "installed VSIX I6 local-event zero-network probe"
$countingProxyResolved = Resolve-RequiredFile $countingProxyPath "I6 transparent counting proxy"
$faultFixtureResolved = Resolve-RequiredFile $faultFixturePath "I6 ra_svn fault fixture"
$packagedNegativeProbeResolved = Resolve-RequiredFile $packagedNegativeProbePath "packaged-native I6 negative probe"

try {
  $repositoryUri = [System.Uri]::new($RepositoryUrl, [System.UriKind]::Absolute)
}
catch {
  throw "RepositoryUrl must be an absolute direct svn:// URL."
}
Assert-True ($repositoryUri.Scheme -ceq "svn") "RepositoryUrl must use direct svn:// transport."
Assert-True ($repositoryUri.Host -ceq "127.0.0.1") "RepositoryUrl must use the controlled IPv4 loopback host."
Assert-True ([string]::IsNullOrEmpty($repositoryUri.UserInfo)) "RepositoryUrl must not contain user information."
Assert-True ([string]::IsNullOrEmpty($repositoryUri.Query) -and [string]::IsNullOrEmpty($repositoryUri.Fragment)) "RepositoryUrl must not contain a query or fragment."

$expectedConfig = "[general]`nanon-access = write`nauth-access = none`nauthz-db = authz`nrealm = SubversionR I6 Controlled Anonymous`n[sasl]`nuse-sasl = false"
$actualConfig = (Get-Content -Raw -LiteralPath $fixtureConfigResolved).Replace("`r`n", "`n")
Assert-True ($actualConfig -ceq $expectedConfig) "FixtureConfigPath must contain the exact controlled anonymous svnserve configuration."
$expectedAuthz = "[repo:/]`n* = rw"
$actualAuthz = (Get-Content -Raw -LiteralPath $fixtureAuthzResolved).Replace("`r`n", "`n")
Assert-True ($actualAuthz -ceq $expectedAuthz) "FixtureAuthzPath must contain the exact controlled anonymous write authz."

$null = Convert-JsonObject (Get-Content -Raw -LiteralPath $stageManifestResolved) "StageManifestPath"
$null = Convert-JsonObject (Get-Content -Raw -LiteralPath $sourceLockResolved) "NativeSourceLockPath"
$patchContract = Convert-JsonObject (Get-Content -Raw -LiteralPath $patchContractResolved) "RaSvnOriginContractPath"
Assert-True ([int]$patchContract.schemaVersion -eq 1) "RaSvnOriginContractPath schemaVersion must be 1."
Assert-True ([string]$patchContract.source.version -ceq "1.14.5") "RaSvnOriginContractPath must bind Apache Subversion 1.14.5."
Assert-True ([string]$patchContract.patch.sha256 -ceq (Get-Sha256 $patchResolved)) "RaSvnOriginContractPath must bind the exact ra_svn patch bytes."

$archive = $null
try {
  try {
    $archive = [System.IO.Compression.ZipFile]::OpenRead($vsixResolved)
  }
  catch {
    throw "VsixPath must be a valid VSIX ZIP archive."
  }
  $packageEntry = Get-ZipEntry $archive "extension/package.json"
  $backendModuleEntry = Get-ZipEntry $archive "extension/dist/backend/backendProcess.js"
  $daemonEntry = Get-ZipEntry $archive "extension/resources/backend/win32-x64/subversionr-daemon.exe"
  $bridgeEntry = Get-ZipEntry $archive "extension/resources/backend/win32-x64/subversionr_svn_bridge.dll"
  $package = Convert-JsonObject (Read-ZipEntryText $packageEntry) "VSIX extension/package.json"
  Assert-True ([string]$package.version -ceq $ExpectedProductVersion) "VSIX product version must match ExpectedProductVersion."
  Assert-True ((Get-ZipEntrySha256 $daemonEntry) -ceq (Get-Sha256 $daemonResolved)) "DaemonPath must match the daemon embedded in VsixPath."
  Assert-True ((Get-ZipEntrySha256 $bridgeEntry) -ceq (Get-Sha256 $bridgeResolved)) "BridgePath must match the bridge embedded in VsixPath."
  Assert-True ($backendModuleEntry.Length -gt 0) "VSIX packaged backend module must not be empty."
}
finally {
  if ($null -ne $archive) {
    $archive.Dispose()
  }
}

Assert-ToolVersion $svnResolved "SvnPath"
Assert-ToolVersion $svnadminResolved "SvnadminPath"
Assert-ToolVersion $svnserveResolved "SvnservePath"

$probeRoot = Join-Path $fixtureRootResolved "product-probe"
$extractedVsixRoot = Join-Path $probeRoot "vsix"
$packagedWorkspaceRoot = Join-Path $probeRoot "packaged-workspace"
$packagedCacheRoot = Join-Path $probeRoot "packaged-cache"
$packagedProfileRoot = Join-Path $probeRoot "packaged-profile"
$compatWorkspaceRoot = Join-Path $probeRoot "compat-workspace"
$compatCacheRoot = Join-Path $probeRoot "compat-cache"
$compatProfileRoot = Join-Path $probeRoot "compat-profile"
foreach ($path in @(
    $probeRoot,
    $extractedVsixRoot,
    $packagedWorkspaceRoot,
    $packagedCacheRoot,
    $packagedProfileRoot,
    $compatWorkspaceRoot,
    $compatCacheRoot,
    $compatProfileRoot
  )) {
  if ($path -eq $probeRoot -and (Test-Path -LiteralPath $path)) {
    Remove-Item -LiteralPath $path -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $path | Out-Null
}
[System.IO.Compression.ZipFile]::ExtractToDirectory($vsixResolved, $extractedVsixRoot)
$backendModulePath = Resolve-RequiredFile (Join-Path $extractedVsixRoot "extension\dist\backend\backendProcess.js") "packaged VSIX backend module"
$nodeHost = Resolve-CodeNodeHost $codeCliResolved
Assert-True ($null -ne (Get-Command Get-CimInstance -CommandType Cmdlet -ErrorAction Stop)) "Get-CimInstance is required."
Assert-True ($null -ne (Get-Command Register-CimIndicationEvent -CommandType Cmdlet -ErrorAction Stop)) "Register-CimIndicationEvent is required."

$packagedI6ProbeResolved = Resolve-RequiredFile (Join-Path $PSScriptRoot "probe-m8-i6-packaged-native.mjs") "packaged-native I6 positive probe"
$seedWorkingCopy = Resolve-RequiredDirectory (Join-Path $fixtureRootResolved "seed-wc") "I6 seed working copy"
$oracleConfigRoot = Resolve-RequiredDirectory (Join-Path $fixtureRootResolved "fixture-cli-config") "I6 fixture CLI configuration"
Add-Content -LiteralPath (Join-Path $seedWorkingCopy "tracked.txt") -Value "SubversionR I6 controlled r3 update fixture"
$seedCommitResult = Invoke-BoundedProcess $svnResolved @(
  "commit", $seedWorkingCopy,
  "-m", "advance I6 controlled fixture to r3",
  "--non-interactive", "--no-auth-cache", "--config-dir", $oracleConfigRoot
) 30
Assert-True ($seedCommitResult.ExitCode -eq 0) "The controlled fixture could not advance to r3 for the packaged update observation."

$packagedNegativeContracts = @(
  [pscustomobject]@{
    Scenario = "malicious-root"
    Code = "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH"
    Reason = "crossAuthorityRejected"
    SettlementCode = "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH"
    SettlementReason = "crossAuthorityRejected"
    TimeoutMs = 30000
    GreetingSent = 1
    ClientResponseReceived = 1
    AuthRequestSent = 1
    ReposInfoSent = 1
  },
  [pscustomobject]@{
    Scenario = "sasl-only"
    Code = "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED"
    Reason = "remoteCapabilityUnsupported"
    SettlementCode = "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED"
    SettlementReason = "remoteCapabilityUnsupported"
    TimeoutMs = 30000
    GreetingSent = 1
    ClientResponseReceived = 1
    AuthRequestSent = 1
    ReposInfoSent = 0
  },
  [pscustomobject]@{
    Scenario = "greeting-stall"
    Code = "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT"
    Reason = "operationDeadlineExceeded"
    SettlementCode = "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED"
    SettlementReason = "remoteRecoveryBlocked"
    TimeoutMs = 2000
    GreetingSent = 1
    ClientResponseReceived = 1
    AuthRequestSent = 0
    ReposInfoSent = 0
  },
  [pscustomobject]@{
    Scenario = "connected-stall"
    Code = "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT"
    Reason = "operationDeadlineExceeded"
    SettlementCode = "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED"
    SettlementReason = "remoteRecoveryBlocked"
    TimeoutMs = 2000
    GreetingSent = 0
    ClientResponseReceived = 0
    AuthRequestSent = 0
    ReposInfoSent = 0
  }
)
$packagedNegativeObservations = @()
foreach ($contract in $packagedNegativeContracts) {
  $scenarioRoot = Join-Path $probeRoot "packaged-negative-$($contract.Scenario)"
  $scenarioProfileRoot = Join-Path $scenarioRoot "profile"
  $scenarioWorkspaceRoot = Join-Path $scenarioRoot "workspace"
  $scenarioStatePath = Join-Path $scenarioRoot "fixture-state.json"
  New-Item -ItemType Directory -Force -Path $scenarioProfileRoot, $scenarioWorkspaceRoot | Out-Null
  Assert-CandidateProcessAbsent $daemonResolved "The $($contract.Scenario) packaged-negative preflight"
  $faultFixture = Start-FaultFixture $nodeHost $faultFixtureResolved $contract.Scenario $scenarioStatePath
  $processStartSourceIdentifier = "subversionr-m8-i6-packaged-negative-$([Guid]::NewGuid().ToString('N'))"
  $processStartSubscriber = $null
  $processStartEvents = [System.Collections.Generic.List[object]]::new()
  $processStartEventKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  try {
    try {
      Register-CimIndicationEvent `
        -ClassName Win32_ProcessStartTrace `
        -SourceIdentifier $processStartSourceIdentifier `
        -ErrorAction Stop | Out-Null
    }
    catch {
      throw "Win32_ProcessStartTrace is required for the $($contract.Scenario) packaged-negative process observation: $($_.Exception.Message)"
    }
    $matchingSubscribers = @(Get-EventSubscriber -SourceIdentifier $processStartSourceIdentifier -ErrorAction Stop)
    Assert-True ($matchingSubscribers.Count -eq 1) "The $($contract.Scenario) packaged-negative process-start subscription was not created exactly once."
    $processStartSubscriber = $matchingSubscribers[0]
    Start-Sleep -Milliseconds $ProcessStartEventSettlementMilliseconds
    $negativeRepositoryUrl = "svn://127.0.0.1:$([int]$faultFixture.State.port)/repo/trunk"
    $negativeResult = Invoke-BoundedProcess $nodeHost @(
      $packagedNegativeProbeResolved,
      "--backend-module", $backendModulePath,
      "--daemon", $daemonResolved,
      "--bridge", $bridgeResolved,
      "--profile-root", $scenarioProfileRoot,
      "--checkout-target", (Join-Path $scenarioWorkspaceRoot "checkout"),
      "--repository-url", $negativeRepositoryUrl,
      "--scenario", $contract.Scenario,
      "--timeout-ms", ([string]$contract.TimeoutMs)
    ) 45 @{ ELECTRON_RUN_AS_NODE = "1" }
    $negativeReport = Convert-JsonObject $negativeResult.Stdout.Trim() "packaged-native $($contract.Scenario) negative probe stdout"
    $negativeFailure = if ($null -ne $negativeReport.PSObject.Properties["error"]) { [string]$negativeReport.error.code }
    else { "unknown" }
    Assert-True ($negativeResult.ExitCode -eq 0 -and $negativeResult.Stderr.Length -eq 0) "The packaged-native $($contract.Scenario) negative probe failed: $negativeFailure."
    Assert-True (
      [string]$negativeReport.schema -ceq "subversionr.release.m8-i6-packaged-native-negative.v1" -and
      [string]$negativeReport.status -ceq "passed" -and
      [string]$negativeReport.scenario -ceq [string]$contract.Scenario -and
      [string]$negativeReport.code -ceq [string]$contract.Code -and
      [string]$negativeReport.reason -ceq [string]$contract.Reason -and
      [string]$negativeReport.settlementCode -ceq [string]$contract.SettlementCode -and
      [string]$negativeReport.settlementReason -ceq [string]$contract.SettlementReason -and
      [int]$negativeReport.protocol.major -eq 1 -and
      [int]$negativeReport.protocol.minor -eq 35 -and
      $negativeReport.remoteSvnAnonymous -eq $true -and
      [int]$negativeReport.temporaryRootsAfter -eq 0 -and
      [int]$negativeReport.credentialRequests -eq 0 -and
      [int]$negativeReport.credentialSettlements -eq 0 -and
      [int]$negativeReport.fixtureCliInvocations -eq 0 -and
      $negativeReport.diagnosticsRedacted -eq $true
    ) "The packaged-native $($contract.Scenario) negative observation was incomplete."
    $faultState = Get-Content -Raw -LiteralPath $scenarioStatePath | ConvertFrom-Json -Depth 16
    Assert-True (
      [int]$faultState.connections -eq 1 -and
      [int]$faultState.greetingSent -eq [int]$contract.GreetingSent -and
      [int]$faultState.clientResponseReceived -eq [int]$contract.ClientResponseReceived -and
      [int]$faultState.authRequestSent -eq [int]$contract.AuthRequestSent -and
      [int]$faultState.reposInfoSent -eq [int]$contract.ReposInfoSent -and
      [int]$faultState.commandsReceived -eq 0 -and
      [int]$faultState.followupContacts -eq 0 -and
      [int]$faultState.suppliedAuthorityConnections -eq 0
    ) "The packaged-native $($contract.Scenario) network-stage observation was invalid."
    Assert-CandidateProcessAbsent $daemonResolved "The $($contract.Scenario) packaged-negative probe" 5000
    Complete-ProcessStartEventDrain `
      $processStartSourceIdentifier `
      $processStartEvents `
      $processStartEventKeys `
      $ProcessStartEventSettlementMilliseconds
    $settlementSnapshot = Get-CimProcessSnapshot
    $processObservation = Get-PackagedNegativeProcessObservation `
      @($processStartEvents) `
      ([long]$negativeResult.ProcessId) `
      ([System.IO.Path]::GetFileName($nodeHost)) `
      ([System.IO.Path]::GetFileName($daemonResolved)) `
      $settlementSnapshot `
      @(
        [System.IO.Path]::GetFileName($svnResolved),
        [System.IO.Path]::GetFileName($svnadminResolved),
        [System.IO.Path]::GetFileName($svnserveResolved)
      )
    Assert-True ([int]$processObservation.fixtureCliInvocations -eq 0) "The packaged-native $($contract.Scenario) product surface invoked a fixture CLI."
    $networkConnections = [int]$faultState.connections
    $networkAttempts = $networkConnections
    Assert-True ($networkAttempts -gt 0) "The packaged-native $($contract.Scenario) fixture measured no network attempt."
    $packagedNegativeObservations += [pscustomobject]@{
      scenario = [string]$contract.Scenario
      code = [string]$negativeReport.code
      reason = [string]$negativeReport.reason
      settlementCode = [string]$negativeReport.settlementCode
      settlementReason = [string]$negativeReport.settlementReason
      networkAttempts = $networkAttempts
      networkConnections = $networkConnections
      followupNetworkContacts = [int]$faultState.followupContacts
      workerDescendantsAfter = [int]$processObservation.workerDescendantsAfter
      temporaryRootsAfter = [int]$negativeReport.temporaryRootsAfter
      diagnosticsRedacted = [bool]$negativeReport.diagnosticsRedacted
    }
  }
  finally {
    if ($null -ne $processStartSubscriber) {
      Unregister-Event -SubscriptionId $processStartSubscriber.SubscriptionId -ErrorAction SilentlyContinue
    }
    Get-Event -SourceIdentifier $processStartSourceIdentifier -ErrorAction SilentlyContinue |
      Remove-Event -ErrorAction SilentlyContinue
    Stop-FaultFixture $faultFixture $contract.Scenario
  }
}
Assert-True ($packagedNegativeObservations.Count -eq 4) "The packaged-native controlled negative probe set was incomplete."

$installedNegativeContracts = @(
  [pscustomobject]@{
    Scenario = "maliciousRoot"
    FaultScenario = "malicious-root"
    WorkRoot = "m"
    Code = "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH"
    Reason = "crossAuthorityRejected"
    SettlementCode = "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH"
    SettlementReason = "crossAuthorityRejected"
    JournalEntriesAfter = 0
    TimeoutMs = 30000
    GreetingSent = 1
    ClientResponseReceived = 1
    AuthRequestSent = 1
    ReposInfoSent = 1
  },
  [pscustomobject]@{
    Scenario = "saslOnly"
    FaultScenario = "sasl-only"
    WorkRoot = "s"
    Code = "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED"
    Reason = "remoteCapabilityUnsupported"
    SettlementCode = "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED"
    SettlementReason = "remoteCapabilityUnsupported"
    JournalEntriesAfter = 0
    TimeoutMs = 30000
    GreetingSent = 1
    ClientResponseReceived = 1
    AuthRequestSent = 1
    ReposInfoSent = 0
  },
  [pscustomobject]@{
    Scenario = "greetingStall"
    FaultScenario = "greeting-stall"
    WorkRoot = "g"
    Code = "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT"
    Reason = "operationDeadlineExceeded"
    SettlementCode = "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED"
    SettlementReason = "remoteRecoveryBlocked"
    JournalEntriesAfter = 1
    TimeoutMs = 2000
    GreetingSent = 1
    ClientResponseReceived = 1
    AuthRequestSent = 0
    ReposInfoSent = 0
  },
  [pscustomobject]@{
    Scenario = "connectedStall"
    FaultScenario = "connected-stall"
    WorkRoot = "c"
    Code = "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT"
    Reason = "operationDeadlineExceeded"
    SettlementCode = "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED"
    SettlementReason = "remoteRecoveryBlocked"
    JournalEntriesAfter = 1
    TimeoutMs = 2000
    GreetingSent = 0
    ClientResponseReceived = 0
    AuthRequestSent = 0
    ReposInfoSent = 0
  }
)
$repoTargetRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target"))
$installedNegativeWorkRoot = [System.IO.Path]::GetFullPath((Join-Path $repoTargetRoot "i6n\$([Guid]::NewGuid().ToString('N').Substring(0, 8))"))
Assert-True (Test-PathWithin $installedNegativeWorkRoot $repoTargetRoot) "The installed-negative short work root escaped repo target."
Assert-True ($installedNegativeWorkRoot.Length -le 120) "The installed-negative short work root exceeds the reviewed 120-character budget."
Assert-True (-not (Test-Path -LiteralPath $installedNegativeWorkRoot)) "The installed-negative short work root already exists."
New-Item -ItemType Directory -Path $installedNegativeWorkRoot | Out-Null
$installedNegativeObservations = @()
try {
  foreach ($contract in $installedNegativeContracts) {
    $scenarioRoot = Join-Path $probeRoot "installed-negative-$($contract.FaultScenario)"
    $scenarioWorkRoot = Join-Path $installedNegativeWorkRoot ([string]$contract.WorkRoot)
    $scenarioStatePath = Join-Path $scenarioRoot "fixture-state.json"
    New-Item -ItemType Directory -Force -Path $scenarioRoot, $scenarioWorkRoot | Out-Null
    Assert-CandidateProcessAbsent $daemonResolved "The $($contract.FaultScenario) installed-negative preflight"
    $faultFixture = Start-FaultFixture $nodeHost $faultFixtureResolved $contract.FaultScenario $scenarioStatePath
    $processStartSourceIdentifier = "subversionr-m8-i6-installed-negative-$([Guid]::NewGuid().ToString('N'))"
    $processStartSubscriber = $null
    $processStartEvents = [System.Collections.Generic.List[object]]::new()
    $processStartEventKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    try {
      try {
        Register-CimIndicationEvent `
          -ClassName Win32_ProcessStartTrace `
          -SourceIdentifier $processStartSourceIdentifier `
          -ErrorAction Stop | Out-Null
      }
      catch {
        throw "Win32_ProcessStartTrace is required for the $($contract.FaultScenario) installed-negative process observation: $($_.Exception.Message)"
      }
      $matchingSubscribers = @(Get-EventSubscriber -SourceIdentifier $processStartSourceIdentifier -ErrorAction Stop)
      Assert-True ($matchingSubscribers.Count -eq 1) "The $($contract.FaultScenario) installed-negative process-start subscription was not created exactly once."
      $processStartSubscriber = $matchingSubscribers[0]
      Start-Sleep -Milliseconds $ProcessStartEventSettlementMilliseconds

      $negativeRepositoryUrl = "svn://127.0.0.1:$([int]$faultFixture.State.port)/repo/trunk"
      $installedNegativeResult = Invoke-BoundedProcess (Get-Process -Id $PID).Path @(
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy", "Bypass",
        "-File", $installedNegativeProbeResolved,
        "-VsixPath", $vsixResolved,
        "-CodeCliPath", $codeCliResolved,
        "-FixtureRoot", $scenarioWorkRoot,
        "-RepositoryUrl", $negativeRepositoryUrl,
        "-CheckoutPath", (Join-Path $scenarioWorkRoot "checkout"),
        "-Scenario", ([string]$contract.Scenario),
        "-OperationTimeoutMilliseconds", ([string]$contract.TimeoutMs),
        "-ExpectedProductVersion", $ExpectedProductVersion,
        "-DaemonPath", $daemonResolved,
        "-BridgePath", $bridgeResolved,
        "-TimeoutSeconds", "180"
      ) 240
      $installedNegativeFailure = $installedNegativeResult.Stderr.Trim()
      Assert-True (
        $installedNegativeResult.ExitCode -eq 0 -and
        $installedNegativeResult.Stderr.Length -eq 0
      ) "The installed VSIX $($contract.FaultScenario) negative probe failed: $installedNegativeFailure"
      $installedNegativeReport = Convert-JsonObject $installedNegativeResult.Stdout.Trim() "installed VSIX $($contract.FaultScenario) negative probe stdout"
      Assert-True (
        [string]$installedNegativeReport.schema -ceq "subversionr.release.m8-i6-installed-vsix-negative.v1" -and
        [string]$installedNegativeReport.status -ceq "passed" -and
        [string]$installedNegativeReport.surface -ceq "installed-vsix-extension-host" -and
        [string]$installedNegativeReport.scenario -ceq [string]$contract.Scenario -and
        [string]$installedNegativeReport.originCode -ceq [string]$contract.Code -and
        [string]$installedNegativeReport.originReason -ceq [string]$contract.Reason -and
        [string]$installedNegativeReport.settlementCode -ceq [string]$contract.SettlementCode -and
        [string]$installedNegativeReport.settlementReason -ceq [string]$contract.SettlementReason -and
        [int]$installedNegativeReport.protocol.major -eq 1 -and
        [int]$installedNegativeReport.protocol.minor -eq 35 -and
        [int]$installedNegativeReport.authActivity.credentialRequests -eq 0 -and
        [int]$installedNegativeReport.authActivity.credentialSettlements -eq 0 -and
        [int]$installedNegativeReport.authActivity.certificateRequests -eq 0 -and
        [int]$installedNegativeReport.temporaryRootsAfter -eq 0 -and
        [int]$installedNegativeReport.checkoutJournalEntriesAfter -eq [int]$contract.JournalEntriesAfter -and
        $installedNegativeReport.diagnosticsRedacted -eq $true -and
        $installedNegativeReport.candidateDaemonExitedAfter -eq $true
      ) "The installed VSIX $($contract.FaultScenario) negative observation was incomplete."

      $faultState = Get-Content -Raw -LiteralPath $scenarioStatePath | ConvertFrom-Json -Depth 16
      Assert-True (
        [int]$faultState.connections -eq 1 -and
        [int]$faultState.greetingSent -eq [int]$contract.GreetingSent -and
        [int]$faultState.clientResponseReceived -eq [int]$contract.ClientResponseReceived -and
        [int]$faultState.authRequestSent -eq [int]$contract.AuthRequestSent -and
        [int]$faultState.reposInfoSent -eq [int]$contract.ReposInfoSent -and
        [int]$faultState.commandsReceived -eq 0 -and
        [int]$faultState.followupContacts -eq 0 -and
        [int]$faultState.suppliedAuthorityConnections -eq 0
      ) "The installed VSIX $($contract.FaultScenario) network-stage observation was invalid."
      Complete-ProcessStartEventDrain `
        $processStartSourceIdentifier `
        $processStartEvents `
        $processStartEventKeys `
        $ProcessStartEventSettlementMilliseconds
      $processObservation = Get-InstalledNegativeProcessObservation `
        -AllEvents @($processStartEvents) `
        -ProbePid ([long]$installedNegativeResult.ProcessId) `
        -ExpectedProbeProcessName ([System.IO.Path]::GetFileName((Get-Process -Id $PID).Path)) `
        -ExpectedDaemonProcessName ([System.IO.Path]::GetFileName($daemonResolved)) `
        -ForbiddenFixtureProcessNames @(
          [System.IO.Path]::GetFileName($svnResolved),
          [System.IO.Path]::GetFileName($svnadminResolved),
          [System.IO.Path]::GetFileName($svnserveResolved)
        ) `
        -SettlementSnapshot (Get-CimProcessSnapshot)
      Assert-True ([int]$processObservation.fixtureCliInvocations -eq 0) "The installed VSIX $($contract.FaultScenario) product surface invoked a fixture CLI."
      $installedNegativeObservations += [pscustomobject]@{
        scenario = [string]$contract.Scenario
        code = [string]$installedNegativeReport.originCode
        reason = [string]$installedNegativeReport.originReason
        settlementCode = [string]$installedNegativeReport.settlementCode
        settlementReason = [string]$installedNegativeReport.settlementReason
        networkAttempts = [int]$faultState.connections
        networkConnections = [int]$faultState.connections
        followupNetworkContacts = [int]$faultState.followupContacts
        workerDescendantsAfter = [int]$processObservation.workerDescendantsAfter
        temporaryRootsAfter = [int]$installedNegativeReport.temporaryRootsAfter
        checkoutJournalEntriesAfter = [int]$installedNegativeReport.checkoutJournalEntriesAfter
        diagnosticsRedacted = [bool]$installedNegativeReport.diagnosticsRedacted
        fixtureCliInvocations = [int]$processObservation.fixtureCliInvocations
      }
    }
    finally {
      if ($null -ne $processStartSubscriber) {
        Unregister-Event -SubscriptionId $processStartSubscriber.SubscriptionId -ErrorAction SilentlyContinue
      }
      Get-Event -SourceIdentifier $processStartSourceIdentifier -ErrorAction SilentlyContinue |
        Remove-Event -ErrorAction SilentlyContinue
      Stop-FaultFixture $faultFixture $contract.FaultScenario
    }
  }
}
finally {
  if (Test-Path -LiteralPath $installedNegativeWorkRoot) {
    Assert-True (Test-PathWithin $installedNegativeWorkRoot $repoTargetRoot) "The installed-negative cleanup root escaped repo target."
    Remove-Item -LiteralPath $installedNegativeWorkRoot -Recurse -Force
  }
  Assert-True (-not (Test-Path -LiteralPath $installedNegativeWorkRoot)) "The installed-negative short work root remained after cleanup."
}
Assert-True ($installedNegativeObservations.Count -eq 4) "The installed VSIX malicious-root, SASL-only, greeting-stall, and connected-stall negative probe set was incomplete."

$deniedAuthz = "[repo:/]`n* = rw`n`n[repo:/denied]`n* ="
$rootWriteAuthz = "[repo:/]`n* = rw"
$deniedRepositoryUri = [System.UriBuilder]::new($repositoryUri)
Assert-True ($deniedRepositoryUri.Path.EndsWith("/trunk", [System.StringComparison]::Ordinal)) "RepositoryUrl must end in /trunk."
$deniedRepositoryUri.Path = $deniedRepositoryUri.Path.Substring(0, $deniedRepositoryUri.Path.Length - 6) + "/denied"
$deniedRepositoryUrl = $deniedRepositoryUri.Uri.AbsoluteUri
$authzDeniedObservations = @()
try {
  Set-ExactAuthzAtomically $fixtureAuthzResolved $deniedAuthz
  $denialControl = Invoke-BoundedProcess $svnResolved @(
    "status", "-u", $packagedAuthzWorkingCopyResolved,
    "--non-interactive", "--no-auth-cache", "--config-dir", $oracleConfigRoot
  ) 30
  Assert-True ($denialControl.ExitCode -ne 0) "The controlled fixture CLI authz-denial control unexpectedly succeeded."

  $packagedAuthzRoot = Join-Path $probeRoot "packaged-authz-denied"
  $packagedAuthzProfileRoot = Join-Path $packagedAuthzRoot "profile"
  New-Item -ItemType Directory -Force -Path $packagedAuthzProfileRoot | Out-Null
  Assert-CandidateProcessAbsent $daemonResolved "The packaged authz-denied preflight"
  $packagedLogOffset = (Get-Item -LiteralPath $fixtureLogResolved).Length
  $packagedSourceIdentifier = "subversionr-m8-i6-packaged-authz-$([Guid]::NewGuid().ToString('N'))"
  $packagedSubscriber = $null
  $packagedEvents = [System.Collections.Generic.List[object]]::new()
  $packagedEventKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  try {
    try {
      Register-CimIndicationEvent -ClassName Win32_ProcessStartTrace -SourceIdentifier $packagedSourceIdentifier -ErrorAction Stop | Out-Null
    }
    catch {
      throw "Win32_ProcessStartTrace is required for the packaged authz-denied process observation: $($_.Exception.Message)"
    }
    $matchingSubscribers = @(Get-EventSubscriber -SourceIdentifier $packagedSourceIdentifier -ErrorAction Stop)
    Assert-True ($matchingSubscribers.Count -eq 1) "The packaged authz-denied process-start subscription was not created exactly once."
    $packagedSubscriber = $matchingSubscribers[0]
    Start-Sleep -Milliseconds $ProcessStartEventSettlementMilliseconds
    $packagedAuthzResult = Invoke-BoundedProcess $nodeHost @(
      $packagedAuthzDeniedProbeResolved,
      "--backend-module", $backendModulePath,
      "--daemon", $daemonResolved,
      "--bridge", $bridgeResolved,
      "--profile-root", $packagedAuthzProfileRoot,
      "--working-copy-path", $packagedAuthzWorkingCopyResolved,
      "--repository-url", $deniedRepositoryUrl,
      "--timeout-ms", "30000"
    ) 60 @{ ELECTRON_RUN_AS_NODE = "1" }
    $packagedAuthzReport = Convert-JsonObject $packagedAuthzResult.Stdout.Trim() "packaged-native authz-denied probe stdout"
    Assert-True ($packagedAuthzResult.ExitCode -eq 0 -and $packagedAuthzResult.Stderr.Length -eq 0) "The packaged-native authz-denied probe failed."
    Assert-True (
      [string]$packagedAuthzReport.schema -ceq "subversionr.release.m8-i6-packaged-native-authz-denied.v1" -and
      [string]$packagedAuthzReport.status -ceq "passed" -and
      [string]$packagedAuthzReport.cell -ceq "authzDenied" -and
      [string]$packagedAuthzReport.stableCode -ceq "SVN_REMOTE_STATUS_AUTH_FAILED" -and
      [string]$packagedAuthzReport.reason -ceq "authorizationDenied" -and
      [int]$packagedAuthzReport.protocol.major -eq 1 -and [int]$packagedAuthzReport.protocol.minor -eq 35 -and
      [int]$packagedAuthzReport.temporaryRootsAfter -eq 0 -and
      [int]$packagedAuthzReport.credentialRequests -eq 0 -and
      [int]$packagedAuthzReport.credentialSettlements -eq 0 -and
      $packagedAuthzReport.diagnosticsRedacted -eq $true
    ) "The packaged-native authz-denied report was incomplete."
    Complete-ProcessStartEventDrain $packagedSourceIdentifier $packagedEvents $packagedEventKeys $ProcessStartEventSettlementMilliseconds
    $packagedProcess = Get-PackagedNegativeProcessObservation `
      @($packagedEvents) `
      ([long]$packagedAuthzResult.ProcessId) `
      ([System.IO.Path]::GetFileName($nodeHost)) `
      ([System.IO.Path]::GetFileName($daemonResolved)) `
      (Get-CimProcessSnapshot) `
      @(
        [System.IO.Path]::GetFileName($svnResolved),
        [System.IO.Path]::GetFileName($svnadminResolved),
        [System.IO.Path]::GetFileName($svnserveResolved)
      )
    Assert-True ([int]$packagedProcess.fixtureCliInvocations -eq 0) "The packaged authz-denied product surface invoked a fixture CLI."
    $packagedNetwork = Get-SvnserveAuthzObservation $fixtureLogResolved $packagedLogOffset "The packaged authz-denied surface"
    $authzDeniedObservations += [pscustomobject]@{
      surface = "packaged-native"; stableCode = [string]$packagedAuthzReport.stableCode; reason = [string]$packagedAuthzReport.reason
      networkProgress = [string]$packagedNetwork.networkProgress; networkAttempts = [int]$packagedNetwork.networkAttempts
      networkConnections = [int]$packagedNetwork.networkConnections; workerDescendantsAfter = [int]$packagedProcess.workerDescendantsAfter
      temporaryRootsAfter = [int]$packagedAuthzReport.temporaryRootsAfter; fixtureCliInvocations = [int]$packagedProcess.fixtureCliInvocations
      diagnosticsRedacted = [bool]$packagedAuthzReport.diagnosticsRedacted
    }
  }
  finally {
    if ($null -ne $packagedSubscriber) { Unregister-Event -SubscriptionId $packagedSubscriber.SubscriptionId -ErrorAction SilentlyContinue }
    Get-Event -SourceIdentifier $packagedSourceIdentifier -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
  }

  $installedAuthzRoot = Join-Path $probeRoot "installed-authz-denied"
  Assert-CandidateProcessAbsent $daemonResolved "The installed authz-denied preflight"
  $installedLogOffset = (Get-Item -LiteralPath $fixtureLogResolved).Length
  $installedSourceIdentifier = "subversionr-m8-i6-installed-authz-$([Guid]::NewGuid().ToString('N'))"
  $installedSubscriber = $null
  $installedEvents = [System.Collections.Generic.List[object]]::new()
  $installedEventKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  try {
    try {
      Register-CimIndicationEvent -ClassName Win32_ProcessStartTrace -SourceIdentifier $installedSourceIdentifier -ErrorAction Stop | Out-Null
    }
    catch {
      throw "Win32_ProcessStartTrace is required for the installed authz-denied process observation: $($_.Exception.Message)"
    }
    $matchingSubscribers = @(Get-EventSubscriber -SourceIdentifier $installedSourceIdentifier -ErrorAction Stop)
    Assert-True ($matchingSubscribers.Count -eq 1) "The installed authz-denied process-start subscription was not created exactly once."
    $installedSubscriber = $matchingSubscribers[0]
    Start-Sleep -Milliseconds $ProcessStartEventSettlementMilliseconds
    $installedAuthzResult = Invoke-BoundedProcess (Get-Process -Id $PID).Path @(
      "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
      "-File", $installedAuthzDeniedProbeResolved,
      "-VsixPath", $vsixResolved,
      "-CodeCliPath", $codeCliResolved,
      "-FixtureRoot", $installedAuthzRoot,
      "-WorkingCopyPath", $installedAuthzWorkingCopyResolved,
      "-RepositoryUrl", $deniedRepositoryUrl,
      "-ExpectedProductVersion", $ExpectedProductVersion,
      "-DaemonPath", $daemonResolved,
      "-BridgePath", $bridgeResolved,
      "-OperationTimeoutMilliseconds", "30000",
      "-TimeoutSeconds", "180"
    ) 240
    $installedAuthzReport = Convert-JsonObject $installedAuthzResult.Stdout.Trim() "installed VSIX authz-denied probe stdout"
    Assert-True ($installedAuthzResult.ExitCode -eq 0 -and $installedAuthzResult.Stderr.Length -eq 0) "The installed VSIX authz-denied probe failed."
    Assert-True (
      [string]$installedAuthzReport.schema -ceq "subversionr.release.m8-i6-installed-vsix-authz-denied.v1" -and
      [string]$installedAuthzReport.status -ceq "passed" -and
      [string]$installedAuthzReport.surface -ceq "installed-vsix-extension-host" -and
      [string]$installedAuthzReport.cell -ceq "authzDenied" -and
      [string]$installedAuthzReport.stableCode -ceq "SVN_REMOTE_STATUS_AUTH_FAILED" -and
      [string]$installedAuthzReport.reason -ceq "authorizationDenied" -and
      [int]$installedAuthzReport.protocol.major -eq 1 -and [int]$installedAuthzReport.protocol.minor -eq 35 -and
      [int]$installedAuthzReport.authActivity.credentialRequests -eq 0 -and
      [int]$installedAuthzReport.authActivity.credentialSettlements -eq 0 -and
      [int]$installedAuthzReport.authActivity.certificateRequests -eq 0 -and
      [int]$installedAuthzReport.temporaryRootsAfter -eq 0 -and
      $installedAuthzReport.diagnosticsRedacted -eq $true -and
      $installedAuthzReport.candidateDaemonExitedAfter -eq $true
    ) "The installed VSIX authz-denied report was incomplete."
    Complete-ProcessStartEventDrain $installedSourceIdentifier $installedEvents $installedEventKeys $ProcessStartEventSettlementMilliseconds
    $installedProcess = Get-InstalledNegativeProcessObservation `
      -AllEvents @($installedEvents) `
      -ProbePid ([long]$installedAuthzResult.ProcessId) `
      -ExpectedProbeProcessName ([System.IO.Path]::GetFileName((Get-Process -Id $PID).Path)) `
      -ExpectedDaemonProcessName ([System.IO.Path]::GetFileName($daemonResolved)) `
      -ForbiddenFixtureProcessNames @(
        [System.IO.Path]::GetFileName($svnResolved),
        [System.IO.Path]::GetFileName($svnadminResolved),
        [System.IO.Path]::GetFileName($svnserveResolved)
      ) `
      -SettlementSnapshot (Get-CimProcessSnapshot)
    Assert-True ([int]$installedProcess.fixtureCliInvocations -eq 0) "The installed authz-denied product surface invoked a fixture CLI."
    $installedNetwork = Get-SvnserveAuthzObservation $fixtureLogResolved $installedLogOffset "The installed authz-denied surface"
    $authzDeniedObservations += [pscustomobject]@{
      surface = "installed-vsix-extension-host"; stableCode = [string]$installedAuthzReport.stableCode; reason = [string]$installedAuthzReport.reason
      networkProgress = [string]$installedNetwork.networkProgress; networkAttempts = [int]$installedNetwork.networkAttempts
      networkConnections = [int]$installedNetwork.networkConnections; workerDescendantsAfter = [int]$installedProcess.workerDescendantsAfter
      temporaryRootsAfter = [int]$installedAuthzReport.temporaryRootsAfter; fixtureCliInvocations = [int]$installedProcess.fixtureCliInvocations
      diagnosticsRedacted = [bool]$installedAuthzReport.diagnosticsRedacted
    }
  }
  finally {
    if ($null -ne $installedSubscriber) { Unregister-Event -SubscriptionId $installedSubscriber.SubscriptionId -ErrorAction SilentlyContinue }
    Get-Event -SourceIdentifier $installedSourceIdentifier -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
  }
  Assert-True ($authzDeniedObservations.Count -eq 2) "The packaged and installed authz-denied surface observations were incomplete."
}
finally {
  Set-ExactAuthzAtomically $fixtureAuthzResolved $rootWriteAuthz
  foreach ($restoredWorkingCopy in @($packagedAuthzWorkingCopyResolved, $installedAuthzWorkingCopyResolved)) {
    $restoreControl = Invoke-BoundedProcess $svnResolved @(
      "status", "-u", $restoredWorkingCopy,
      "--non-interactive", "--no-auth-cache", "--config-dir", $oracleConfigRoot
    ) 30
    Assert-True ($restoreControl.ExitCode -eq 0) "The controlled fixture CLI authz restore control failed for a surface working copy."
  }
}

$localEventWorkingCopy = Join-Path $fixtureRootResolved "local-event-zero-network-wc"
$localEventProbeRoot = Join-Path $probeRoot "installed-local-event-zero-network"
$localEventProxyRoot = Join-Path $probeRoot "local-event-counting-proxy"
$localEventProxyStatePath = Join-Path $localEventProxyRoot "state.json"
Assert-True (-not (Test-Path -LiteralPath $localEventWorkingCopy)) "The installed local-event working-copy path must not exist before checkout."
Assert-True (-not (Test-Path -LiteralPath $localEventProbeRoot)) "The installed local-event probe root must not exist before execution."
New-Item -ItemType Directory -Path $localEventProxyRoot | Out-Null
$countingProxy = Start-CountingProxy $nodeHost $countingProxyResolved $repositoryUri.Port $localEventProxyStatePath
$localEventProcessSourceIdentifier = "subversionr-m8-i6-installed-local-event-$([Guid]::NewGuid().ToString('N'))"
$localEventProcessSubscriber = $null
$localEventProcessEvents = [System.Collections.Generic.List[object]]::new()
$localEventProcessEventKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$proxyBaseline = $null
try {
  $proxyRepositoryUri = [System.UriBuilder]::new($repositoryUri)
  $proxyRepositoryUri.Host = "127.0.0.1"
  $proxyRepositoryUri.Port = [int]$countingProxy.State.port
  $localEventCheckout = Invoke-BoundedProcess $svnResolved @(
    "checkout", $proxyRepositoryUri.Uri.AbsoluteUri, $localEventWorkingCopy,
    "--revision", "2", "--ignore-externals",
    "--non-interactive", "--no-auth-cache", "--config-dir", $oracleConfigRoot
  ) 60
  Assert-True ($localEventCheckout.ExitCode -eq 0) "The controlled fixture CLI could not create the proxy-bound local-event working copy."
  $localEventTarget = Resolve-RequiredFile (Join-Path $localEventWorkingCopy "tracked.txt") "installed local-event target"
  Assert-True ((Get-Item -LiteralPath $localEventTarget).Length -gt 0) "The installed local-event target must be non-empty."

  $proxyBaseline = Read-CountingProxyState $localEventProxyStatePath $countingProxy.Process $true
  Assert-True (
    [int64]$proxyBaseline.acceptedConnections -gt 0 -and
    [int64]$proxyBaseline.acceptedConnections -eq [int64]$proxyBaseline.upstreamAttempts -and
    [int64]$proxyBaseline.acceptedConnections -eq [int64]$proxyBaseline.upstreamConnections -and
    [int64]$proxyBaseline.clientToUpstreamBytes -gt 0 -and
    [int64]$proxyBaseline.upstreamToClientBytes -gt 0 -and
    [int]$proxyBaseline.activeConnections -eq 0 -and
    [int]$proxyBaseline.upstreamConnectFailures -eq 0
  ) "The installed local-event counting-proxy checkout baseline was invalid."
  $localEventLogOffset = (Get-Item -LiteralPath $fixtureLogResolved).Length
  Assert-CandidateProcessAbsent $daemonResolved "The installed local-event preflight"

  try {
    try {
      Register-CimIndicationEvent -ClassName Win32_ProcessStartTrace -SourceIdentifier $localEventProcessSourceIdentifier -ErrorAction Stop | Out-Null
    }
    catch {
      throw "Win32_ProcessStartTrace is required for the installed local-event process observation: $($_.Exception.Message)"
    }
    $matchingSubscribers = @(Get-EventSubscriber -SourceIdentifier $localEventProcessSourceIdentifier -ErrorAction Stop)
    Assert-True ($matchingSubscribers.Count -eq 1) "The installed local-event process-start subscription was not created exactly once."
    $localEventProcessSubscriber = $matchingSubscribers[0]
    Start-Sleep -Milliseconds $ProcessStartEventSettlementMilliseconds
    $installedLocalEventResult = Invoke-BoundedProcess (Get-Process -Id $PID).Path @(
      "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
      "-File", $installedLocalEventProbeResolved,
      "-VsixPath", $vsixResolved,
      "-CodeCliPath", $codeCliResolved,
      "-FixtureRoot", $localEventProbeRoot,
      "-WorkingCopyPath", $localEventWorkingCopy,
      "-RelativePath", "tracked.txt",
      "-ExpectedProductVersion", $ExpectedProductVersion,
      "-DaemonPath", $daemonResolved,
      "-BridgePath", $bridgeResolved,
      "-ObservationTimeoutMilliseconds", "30000",
      "-TimeoutSeconds", "180"
    ) 240
    $installedLocalEventFailure = $installedLocalEventResult.Stderr.Trim()
    Assert-True (
      $installedLocalEventResult.ExitCode -eq 0 -and $installedLocalEventResult.Stderr.Length -eq 0
    ) "The installed VSIX local-event zero-network probe failed: $installedLocalEventFailure"
    $installedLocalEventReport = Convert-JsonObject $installedLocalEventResult.Stdout.Trim() "installed VSIX local-event zero-network probe stdout"
    Assert-True (
      [string]$installedLocalEventReport.schema -ceq "subversionr.release.m8-i6-installed-vsix-local-event-zero-network.v1" -and
      [string]$installedLocalEventReport.status -ceq "passed" -and
      [string]$installedLocalEventReport.surface -ceq "installed-vsix-extension-host" -and
      [string]$installedLocalEventReport.cell -ceq "localEventZeroNetwork" -and
      $installedLocalEventReport.watcherObserved -eq $true -and
      [string]$installedLocalEventReport.target.path -ceq "tracked.txt" -and
      [string]$installedLocalEventReport.target.depth -ceq "empty" -and
      [string]$installedLocalEventReport.target.reason -ceq "fileChanged" -and
      [int64]$installedLocalEventReport.statusRefreshRequestDelta -ge 1 -and
      [int64]$installedLocalEventReport.remoteStatusRequestDelta -eq 0 -and
      [int64]$installedLocalEventReport.reconcileRequestDelta -eq 0 -and
      $installedLocalEventReport.projectionObserved -eq $true -and
      [int64]$installedLocalEventReport.credentialRequests -eq 0 -and
      [int64]$installedLocalEventReport.credentialSettlements -eq 0 -and
      [int64]$installedLocalEventReport.certificateRequests -eq 0 -and
      $installedLocalEventReport.diagnosticsRedacted -eq $true -and
      [int]$installedLocalEventReport.temporaryRootsAfter -eq 0 -and
      $installedLocalEventReport.candidateDaemonExitedAfter -eq $true
    ) "The installed VSIX local-event zero-network observation was incomplete."

    $proxyAfterObservation = Read-CountingProxyState $localEventProxyStatePath $countingProxy.Process $true
    foreach ($counterName in @(
        "acceptedConnections", "upstreamAttempts", "upstreamConnections",
        "clientToUpstreamBytes", "upstreamToClientBytes", "upstreamConnectFailures"
      )) {
      Assert-True (
        [int64]$proxyAfterObservation.$counterName -eq [int64]$proxyBaseline.$counterName
      ) "The installed local-event surface changed counting-proxy counter '$counterName'."
    }
    Assert-True ([int]$proxyAfterObservation.activeConnections -eq 0) "The installed local-event surface left an active proxy connection."
    Assert-True ((Get-Item -LiteralPath $fixtureLogResolved).Length -eq $localEventLogOffset) "The installed local-event surface produced a high-level svnserve operation."

    Complete-ProcessStartEventDrain `
      $localEventProcessSourceIdentifier `
      $localEventProcessEvents `
      $localEventProcessEventKeys `
      $ProcessStartEventSettlementMilliseconds
    $localEventProcessObservation = Get-InstalledLocalEventProcessObservation `
      -AllEvents @($localEventProcessEvents) `
      -ProbePid ([long]$installedLocalEventResult.ProcessId) `
      -ExpectedProbeProcessName ([System.IO.Path]::GetFileName((Get-Process -Id $PID).Path)) `
      -ExpectedDaemonProcessName ([System.IO.Path]::GetFileName($daemonResolved)) `
      -ForbiddenFixtureProcessNames @(
        [System.IO.Path]::GetFileName($svnResolved),
        [System.IO.Path]::GetFileName($svnadminResolved),
        [System.IO.Path]::GetFileName($svnserveResolved)
      ) `
      -SettlementSnapshot (Get-CimProcessSnapshot)
    Assert-True ([int]$localEventProcessObservation.fixtureCliInvocations -eq 0) "The installed local-event product surface invoked a fixture CLI."
    Assert-True ([int]$localEventProcessObservation.workerStarts -eq 0) "The installed local-event product surface started a remote worker."

    $localEventZeroNetworkObservation = [pscustomobject]@{
      surface = "installed-vsix-extension-host"
      stableCode = "none"; reason = "none"
      originCode = "none"; originReason = "none"
      settlementCode = "none"; settlementReason = "none"
      networkProgress = "none"; networkAttempts = 0; networkConnections = 0
      fixtureCliInvocations = [int]$localEventProcessObservation.fixtureCliInvocations
      credentialRequests = [int]$installedLocalEventReport.credentialRequests
      credentialSettlements = [int]$installedLocalEventReport.credentialSettlements
      followupNetworkContacts = 0
      workerDescendantsAfter = [int]$localEventProcessObservation.workerDescendantsAfter
      temporaryRootsAfter = [int]$installedLocalEventReport.temporaryRootsAfter
      diagnosticsRedacted = [bool]$installedLocalEventReport.diagnosticsRedacted
    }
  }
  finally {
    if ($null -ne $localEventProcessSubscriber) {
      Unregister-Event -SubscriptionId $localEventProcessSubscriber.SubscriptionId -ErrorAction SilentlyContinue
    }
    Get-Event -SourceIdentifier $localEventProcessSourceIdentifier -ErrorAction SilentlyContinue |
      Remove-Event -ErrorAction SilentlyContinue
  }
}
finally {
  $proxyFinalState = Stop-CountingProxy $countingProxy
  if ($null -ne $proxyBaseline) {
    foreach ($counterName in @(
        "acceptedConnections", "upstreamAttempts", "upstreamConnections",
        "clientToUpstreamBytes", "upstreamToClientBytes", "upstreamConnectFailures"
      )) {
      Assert-True (
        [int64]$proxyFinalState.$counterName -eq [int64]$proxyBaseline.$counterName
      ) "The stopped installed local-event counting proxy changed final counter '$counterName'."
    }
    Assert-True ([int]$proxyFinalState.activeConnections -eq 0) "The stopped installed local-event counting proxy retained an active connection."
  }
}

$installedStressRoot = Join-Path $probeRoot "installed-stress"
$installedStressResult = Invoke-BoundedProcess (Get-Process -Id $PID).Path @(
  "-NoProfile",
  "-NonInteractive",
  "-ExecutionPolicy", "Bypass",
  "-File", $installedStressProbeResolved,
  "-VsixPath", $vsixResolved,
  "-CodeCliPath", $codeCliResolved,
  "-FixtureRoot", $installedStressRoot,
  "-RepositoryUrl", $RepositoryUrl,
  "-CheckoutPath", (Join-Path $installedStressRoot "checkout"),
  "-CheckoutRevision", "2",
  "-ExpectedProductVersion", $ExpectedProductVersion,
  "-DaemonPath", $daemonResolved,
  "-BridgePath", $bridgeResolved,
  "-SvnservePath", $svnserveResolved,
  "-SvnservePid", ([string]$SvnservePid),
  "-SvnserveStartTimeUtc", $SvnserveStartTimeUtc,
  "-TimeoutSeconds", "7200"
) 7260
$installedStressFailure = $installedStressResult.Stderr.Trim()
Assert-True ($installedStressResult.ExitCode -eq 0 -and $installedStressResult.Stderr.Length -eq 0) "The installed VSIX 100+1 stress probe failed: $installedStressFailure"
$installedStressReport = Convert-JsonObject $installedStressResult.Stdout.Trim() "installed VSIX 100+1 stress probe stdout"
Assert-True (
  [string]$installedStressReport.schema -ceq "subversionr.release.m8-i6-installed-vsix-stress.v1" -and
  [string]$installedStressReport.surface -ceq "installed-vsix-extension-host" -and
  [string]$installedStressReport.status -ceq "passed" -and
  [int]$installedStressReport.cycles -eq 100 -and
  @($installedStressReport.observations).Count -eq 100 -and
  [int]$installedStressReport.subsequentRequest.cycle -eq 101 -and
  $installedStressReport.operationIdHashesUnique -eq $true -and
  $installedStressReport.singleExtensionHostSession -eq $true -and
  $installedStressReport.subsequentRequestPassed -eq $true -and
  $installedStressReport.candidateDaemonExitedAfter -eq $true
) "The installed VSIX 100+1 stress observation was incomplete."

$positiveTargetPath = Join-Path $packagedWorkspaceRoot "packaged-i6-wc"
$positiveResult = Invoke-BoundedProcess $nodeHost @(
  $packagedI6ProbeResolved,
  "--backend-module", $backendModulePath,
  "--daemon", $daemonResolved,
  "--bridge", $bridgeResolved,
  "--profile-root", (Join-Path $packagedProfileRoot "i6-positive"),
  "--checkout-target", $positiveTargetPath,
  "--repository-url", $RepositoryUrl,
  "--checkout-revision", "2"
) 300 @{ ELECTRON_RUN_AS_NODE = "1" }
$positiveReport = Convert-JsonObject $positiveResult.Stdout.Trim() "packaged-native I6 positive probe stdout"
$positiveFailure = if ($null -ne $positiveReport.error -and $null -ne $positiveReport.error.diagnostics) {
  "$([string]$positiveReport.error.code) / $([string]$positiveReport.error.diagnostics.cause) / $(@($positiveReport.error.diagnostics.names) -join ',')"
}
elseif ($null -ne $positiveReport.error) {
  [string]$positiveReport.error.code
}
else {
  "unknown"
}
Assert-True ($positiveResult.ExitCode -eq 0) "The packaged-native I6 positive operation matrix failed against the candidate artifacts: $positiveFailure."
$expectedPositiveOperations = @("checkoutOpen", "remoteStatus", "content", "historyLog", "historyBlame", "update", "commit", "branchCopy", "switch", "lock", "unlock")
Assert-True ([string]$positiveReport.schema -ceq "subversionr.release.m8-i6-packaged-native-positive.v1") "The packaged-native I6 positive probe returned an unexpected schema."
Assert-True ([string]$positiveReport.status -ceq "passed") "The packaged-native I6 positive probe did not pass."
Assert-True ((@($positiveReport.operations.operation) -join ",") -ceq ($expectedPositiveOperations -join ",")) "The packaged-native I6 positive probe did not execute the exact operation matrix."
Assert-True ($positiveReport.remoteSvnAnonymous -eq $true -and [int]$positiveReport.fixtureCliInvocations -eq 0) "The packaged-native I6 positive probe did not preserve anonymous native-only execution."
foreach ($operation in @($positiveReport.operations)) {
  Assert-True (
    [string]$operation.status -ceq "passed" -and
    [string]$operation.serverAuth -ceq "anonymous" -and
    [int]$operation.promptCount -eq 0 -and
    [string]$operation.credentialSettlement -ceq "none" -and
    [string]$operation.reconcile -ceq "fresh" -and
    [int]$operation.workerDescendantsAfter -eq 0 -and
    [int]$operation.temporaryRootsAfter -eq 0 -and
    $operation.nativeLaneReleased -eq $true -and
    $operation.diagnosticsRedacted -eq $true
  ) "The packaged-native I6 positive probe returned an incomplete operation observation."
}
$packagedResult = Invoke-BoundedProcess $nodeHost @(
  $packagedProbeResolved,
  "--backend-module", $backendModulePath,
  "--daemon", $daemonResolved,
  "--bridge", $bridgeResolved,
  "--cache-root", $compatCacheRoot,
  "--workspace-root", $compatWorkspaceRoot,
  "--profile-root", $compatProfileRoot
) 180 @{ ELECTRON_RUN_AS_NODE = "1" }
Assert-True ($packagedResult.ExitCode -eq 0) "The packaged-native candidate probe failed before it could establish its current boundary."
$packagedReport = Convert-JsonObject $packagedResult.Stdout.Trim() "packaged-native probe stdout"
Assert-True ([string]$packagedReport.schema -ceq "subversionr.release.packaged-native-compatibility.v2") "The packaged-native probe returned an unexpected schema."
Assert-True ([string]$packagedReport.status -ceq "passed") "The packaged-native probe did not pass its current contract."
Assert-True ([int]$packagedReport.protocol.major -eq 1 -and [int]$packagedReport.protocol.minor -eq 35) "The packaged-native probe did not execute protocol 1.35."
Assert-True ([string]$packagedReport.workerIsolation.resultCode -ceq "SUBVERSIONR_REMOTE_TRANSPORT_UNSUPPORTED") "The packaged-native probe did not produce the expected current transport-boundary observation."
Assert-True ([int]$packagedReport.workerIsolation.tempRootCleanup.residualEntryCount -eq 0) "The packaged-native failure observation left worker temporary roots."
Assert-True ([string]$packagedReport.workerIsolation.sameLaneSubsequent.resultCode -ceq "SUBVERSIONR_REMOTE_TRANSPORT_UNSUPPORTED") "The packaged-native failure observation did not release its native lane."

$installedRunId = "m8-i6-$([Guid]::NewGuid().ToString('N'))"
$installedFixtureRoot = Join-Path $installedHarnessRoot $installedRunId
$installedEvidencePath = Join-Path $installedFixtureRoot "evidence.json"
try {
  New-Item -ItemType Directory -Force -Path $installedFixtureRoot | Out-Null
  $installedPositiveRoot = Join-Path $installedFixtureRoot "i6-positive"
  $installedPositive = Invoke-BoundedProcess (Get-Process -Id $PID).Path @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $installedI6ProbeResolved,
    "-VsixPath", $vsixResolved,
    "-CodeCliPath", $codeCliResolved,
    "-FixtureRoot", $installedPositiveRoot,
    "-RepositoryUrl", $RepositoryUrl,
    "-CheckoutPath", (Join-Path $installedPositiveRoot "installed-i6-wc"),
    "-CheckoutRevision", "2",
    "-ExpectedProductVersion", $ExpectedProductVersion,
    "-TimeoutSeconds", "600"
  ) 720
  Assert-True ($installedPositive.ExitCode -eq 0) "The installed Extension Host I6 positive operation matrix failed against the installed candidate."
  $installedPositiveReport = Convert-JsonObject $installedPositive.Stdout.Trim() "installed Extension Host I6 positive probe stdout"
  Assert-True ([string]$installedPositiveReport.schema -ceq "subversionr.release.m8-i6-installed-vsix-positive.v1") "The installed Extension Host I6 positive probe returned an unexpected schema."
  Assert-True ([string]$installedPositiveReport.status -ceq "passed") "The installed Extension Host I6 positive probe did not pass."
  Assert-True ((@($installedPositiveReport.operations.operation) -join ",") -ceq ($expectedPositiveOperations -join ",")) "The installed Extension Host I6 positive probe did not execute the exact operation matrix."
  foreach ($operation in @($installedPositiveReport.operations)) {
    Assert-True (
      [string]$operation.status -ceq "passed" -and
      [string]$operation.serverAuth -ceq "anonymous" -and
      [int]$operation.promptCount -eq 0 -and
      [string]$operation.credentialSettlement -ceq "none" -and
      [string]$operation.reconcile -ceq "fresh" -and
      [int]$operation.workerDescendantsAfter -eq 0 -and
      [int]$operation.temporaryRootsAfter -eq 0 -and
      $operation.nativeLaneReleased -eq $true -and
      $operation.diagnosticsRedacted -eq $true
    ) "The installed Extension Host I6 positive probe returned an incomplete operation observation."
  }

  $installedResult = Invoke-BoundedProcess (Get-Process -Id $PID).Path @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $installedHarnessResolved,
    "-Target", "win32-x64",
    "-VsixPath", $vsixResolved,
    "-CodeCliPath", $codeCliResolved,
    "-FixtureRoot", $installedFixtureRoot,
    "-EvidencePath", $installedEvidencePath,
    "-ExtensionHostTimeoutSeconds", "180"
  ) 300
  Assert-True ($installedResult.ExitCode -eq 0) "The installed Extension Host candidate probe failed before it could establish its current boundary."
  $installedReport = Convert-JsonObject (Get-Content -Raw -LiteralPath $installedEvidencePath) "installed Extension Host evidence"
  Assert-True ([string]$installedReport.extension.version -ceq $ExpectedProductVersion) "Installed Extension Host product version must match ExpectedProductVersion."
  Assert-True ([int]$installedReport.installedRemoteWorkerReport.protocol.major -eq 1 -and [int]$installedReport.installedRemoteWorkerReport.protocol.minor -eq 35) "Installed Extension Host did not execute protocol 1.35."
  Assert-True ([string]$installedReport.installedRemoteWorkerReport.transportResult -ceq "unsupportedAfterWorker") "Installed Extension Host did not produce the expected current transport-boundary observation."
  Assert-True ($installedReport.installedRemoteWorkerReport.remoteConnectionState.separateRecoveryOperation -eq $true) "Installed Extension Host did not prove the current recovery-operation boundary."
}
finally {
  if (Test-Path -LiteralPath $installedFixtureRoot) {
    Remove-Item -LiteralPath $installedFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Assert-True (-not (Test-Path -LiteralPath $outputResolved)) "OutputPath must remain absent until every I6 observation is complete."
throw "SUBVERSIONR_M8_I6_OBSERVATION_BLOCKED: the candidate passed the real packaged-native and installed Extension Host eleven-operation svn:// matrices, the four packaged-native fault cells, the four installed malicious-root/SASL-only/greeting-stall/connected-stall fault cells, the packaged/installed authz-denied remote-status cell, the installed real-watcher local-event zero-network cell, the installed 100+1 single-Extension-Host residue stress, and the existing packaged/installed recovery-cleanup probes. The remaining cross-surface negative/recovery cells and the reviewed lock/unlock matrix decision in issue #136 are incomplete; therefore no I6 evidence was written."

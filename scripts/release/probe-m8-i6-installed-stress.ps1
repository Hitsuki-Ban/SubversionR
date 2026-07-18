[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string]$VsixPath,
  [Parameter(Mandatory = $true)] [string]$CodeCliPath,
  [Parameter(Mandatory = $true)] [string]$FixtureRoot,
  [Parameter(Mandatory = $true)] [string]$RepositoryUrl,
  [Parameter(Mandatory = $true)] [string]$CheckoutPath,
  [Parameter(Mandatory = $true)] [ValidateRange(0, 2147483647)] [int]$CheckoutRevision,
  [Parameter(Mandatory = $true)] [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')] [string]$ExpectedProductVersion,
  [Parameter(Mandatory = $true)] [string]$DaemonPath,
  [Parameter(Mandatory = $true)] [string]$BridgePath,
  [Parameter(Mandatory = $true)] [string]$SvnservePath,
  [Parameter(Mandatory = $true)] [ValidateRange(1, 4294967295)] [long]$SvnservePid,
  [Parameter(Mandatory = $true)] [string]$SvnserveStartTimeUtc,
  [Parameter(Mandatory = $true)] [ValidateRange(60, 7200)] [int]$TimeoutSeconds
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$CycleCount = 100
$SubsequentCycle = 101
$ProcessStartEventSettlementMilliseconds = 500
$WorkerArgument = "--subversionr-private-remote-worker-v1"
$JournalFileName = "subversionr-remote-checkout-mutations-v1.json"
$JournalTemporaryFileName = ".subversionr-remote-checkout-mutations-v1.tmp"
$StressCommand = "subversionr.diagnostics.installedSvnAnonymousStressCheckout"
$StressTokenEnvironment = "SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_STRESS_CHECKOUT_TOKEN"

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw $Message
  }
}

function Assert-ExactProperties([object]$Value, [string[]]$Expected, [string]$Context) {
  Assert-True ($null -ne $Value) "$Context must be present."
  $actual = @($Value.PSObject.Properties.Name | Sort-Object)
  $expectedSorted = @($Expected | Sort-Object)
  Assert-True (($actual -join ",") -ceq ($expectedSorted -join ",")) "$Context must contain exactly the required fields."
}

function Resolve-RequiredFile([string]$Path, [string]$Name) {
  Assert-True (-not [string]::IsNullOrWhiteSpace($Path)) "$Name is required."
  Assert-True ([System.IO.Path]::IsPathFullyQualified($Path)) "$Name must be an absolute path."
  $resolved = [System.IO.Path]::GetFullPath($Path)
  Assert-True (Test-Path -LiteralPath $resolved -PathType Leaf) "$Name must be an existing file: $resolved"
  return $resolved
}

function Resolve-GeneratedPath([string]$Path, [string]$Name) {
  Assert-True (-not [string]::IsNullOrWhiteSpace($Path)) "$Name is required."
  Assert-True ([System.IO.Path]::IsPathFullyQualified($Path)) "$Name must be an absolute path."
  return [System.IO.Path]::GetFullPath($Path)
}

function Test-PathWithin([string]$Path, [string]$Root) {
  $rootPrefix = $Root.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  return $Path.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-Sha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-StringSha256([string]$Value) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
  return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function ConvertTo-ProcessArgument([string]$Value) {
  if ($Value.Length -eq 0) {
    return '""'
  }
  if ($Value -notmatch '[\s"]') {
    return $Value
  }
  return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Get-ProcessEnvironmentValue([string]$Name) {
  return [System.Environment]::GetEnvironmentVariable($Name, "Process")
}

function Restore-ProcessEnvironmentValue([string]$Name, [string]$Value) {
  if ($null -eq $Value) {
    Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue
  }
  else {
    Set-Item -LiteralPath "Env:$Name" -Value $Value
  }
}

function Get-ZipEntry([System.IO.Compression.ZipArchive]$Archive, [string]$Name) {
  $matches = @($Archive.Entries | Where-Object { $_.FullName -ceq $Name })
  Assert-True ($matches.Count -eq 1) "VSIX must contain exactly one $Name entry."
  return $matches[0]
}

function Read-ZipEntryText([System.IO.Compression.ZipArchiveEntry]$Entry) {
  $reader = [System.IO.StreamReader]::new($Entry.Open(), [System.Text.UTF8Encoding]::new($false), $true)
  try {
    return $reader.ReadToEnd()
  }
  finally {
    $reader.Dispose()
  }
}

function Get-ZipEntrySha256([System.IO.Compression.ZipArchiveEntry]$Entry) {
  $stream = $Entry.Open()
  $algorithm = [System.Security.Cryptography.SHA256]::Create()
  try {
    return [Convert]::ToHexString($algorithm.ComputeHash($stream)).ToLowerInvariant()
  }
  finally {
    $algorithm.Dispose()
    $stream.Dispose()
  }
}

function Find-InstalledPackage([string]$ExtensionsRoot, [string]$Version) {
  $matches = @(Get-ChildItem -LiteralPath $ExtensionsRoot -Directory -Recurse -Depth 2 |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "package.json") -PathType Leaf } |
    ForEach-Object {
      $manifest = Get-Content -Raw -LiteralPath (Join-Path $_.FullName "package.json") | ConvertFrom-Json
      if ($manifest.publisher -ceq "hitsuki-ban" -and $manifest.name -ceq "subversionr" -and $manifest.version -ceq $Version) {
        $_.FullName
      }
    })
  Assert-True ($matches.Count -eq 1) "Expected exactly one installed hitsuki-ban.subversionr package."
  return [System.IO.Path]::GetFullPath($matches[0])
}

function Get-CimProcessSnapshot {
  try {
    return @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
  }
  catch {
    throw "CIM Win32_Process observation is required for installed stress evidence: $($_.Exception.Message)"
  }
}

function Receive-ProcessStartEvents(
  [string]$SourceIdentifier,
  [System.Collections.Generic.List[object]]$AllEvents,
  [System.Collections.Generic.HashSet[string]]$EventKeys
) {
  $received = 0
  foreach ($queuedEvent in @(Get-Event -SourceIdentifier $SourceIdentifier -ErrorAction SilentlyContinue)) {
    try {
      $newEvent = $queuedEvent.SourceEventArgs.NewEvent
      Assert-True ($null -ne $newEvent) "The process-start subscription delivered an empty event."
      $processId = [long]$newEvent.ProcessID
      $parentProcessId = [long]$newEvent.ParentProcessID
      $processName = [string]$newEvent.ProcessName
      $eventFileTime = [long]$newEvent.TIME_CREATED
      Assert-True ($processId -gt 0 -and $parentProcessId -ge 0) "The process-start event contains invalid process identity."
      Assert-True (-not [string]::IsNullOrWhiteSpace($processName)) "The process-start event does not contain a process name."
      Assert-True ($eventFileTime -gt 0) "The process-start event does not contain a valid event time."
      $eventTimeUtc = [DateTime]::FromFileTimeUtc($eventFileTime).ToString("O", [Globalization.CultureInfo]::InvariantCulture)
      $key = "$processId`:$eventFileTime"
      Assert-True ($EventKeys.Add($key)) "The process-start subscription delivered a duplicate process identity and event time."
      $AllEvents.Add([pscustomobject]@{
          processId = $processId
          parentProcessId = $parentProcessId
          processName = $processName
          eventFileTime = $eventFileTime
          eventTimeUtc = $eventTimeUtc
        })
      $received += 1
    }
    finally {
      Remove-Event -EventIdentifier $queuedEvent.EventIdentifier -ErrorAction SilentlyContinue
    }
  }
  return $received
}

function Get-NextRecordedProcessStartFileTime(
  [object[]]$AllEvents,
  [long]$ProcessId,
  [long]$AfterFileTime
) {
  $next = @($AllEvents | Where-Object {
      [long]$_.processId -eq $ProcessId -and [long]$_.eventFileTime -gt $AfterFileTime
    } | Sort-Object { [long]$_.eventFileTime } | Select-Object -First 1)
  if ($next.Count -eq 0) {
    return [long]::MaxValue
  }
  return [long]$next[0].eventFileTime
}

function Get-RecordedWorkerDescendantStartEvents([object[]]$AllEvents, [object]$WorkerStart) {
  $pending = [System.Collections.Generic.Queue[object]]::new()
  $pending.Enqueue([pscustomobject]@{
      processId = [long]$WorkerStart.processId
      eventFileTime = [long]$WorkerStart.eventFileTime
    })
  $descendants = [System.Collections.Generic.List[object]]::new()
  $descendantIdentities = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  while ($pending.Count -gt 0) {
    $parent = $pending.Dequeue()
    $parentPid = [long]$parent.processId
    $parentStart = [long]$parent.eventFileTime
    $parentEnd = Get-NextRecordedProcessStartFileTime $AllEvents $parentPid $parentStart
    foreach ($child in @($AllEvents | Where-Object {
          [long]$_.parentProcessId -eq $parentPid -and
          [long]$_.eventFileTime -gt $parentStart -and
          [long]$_.eventFileTime -lt $parentEnd
        })) {
      $childPid = [long]$child.processId
      $identity = "$childPid`:$([long]$child.eventFileTime)"
      if ($descendantIdentities.Add($identity)) {
        $descendants.Add($child)
        $pending.Enqueue([pscustomobject]@{
            processId = $childPid
            eventFileTime = [long]$child.eventFileTime
          })
      }
    }
  }
  return @($descendants)
}

function Assert-WorkerStartIdentityUnique([object[]]$AllEvents, [object]$WorkerStart) {
  $sameIdentity = @($AllEvents | Where-Object {
      [long]$_.processId -eq [long]$WorkerStart.processId -and
      [long]$_.eventFileTime -eq [long]$WorkerStart.eventFileTime
    })
  Assert-True ($sameIdentity.Count -eq 1) "The recorded worker start identity is not unique."
}

function Assert-RecordedWorkerIdentitiesClean([object[]]$AllEvents, [object[]]$WorkerStarts) {
  foreach ($workerStart in $WorkerStarts) {
    Assert-WorkerStartIdentityUnique $AllEvents $workerStart
  }
}

function Wait-ForExactWorkerStart(
  [string]$SourceIdentifier,
  [System.Collections.Generic.List[object]]$AllEvents,
  [System.Collections.Generic.HashSet[string]]$EventKeys,
  [int]$StartIndex,
  [long]$DaemonPid,
  [string]$ExpectedProcessName,
  [System.Diagnostics.Stopwatch]$Stopwatch,
  [int]$DeadlineSeconds,
  [int]$SettlementMilliseconds
) {
  $firstWorkerArrivalMilliseconds = $null
  while ($true) {
    $null = Receive-ProcessStartEvents $SourceIdentifier $AllEvents $EventKeys
    $roundEvents = if ($AllEvents.Count -gt $StartIndex) {
      @($AllEvents.GetRange($StartIndex, $AllEvents.Count - $StartIndex))
    }
    else {
      @()
    }
    $workerStarts = @($roundEvents | Where-Object {
        [long]$_.parentProcessId -eq $DaemonPid -and
        ([string]$_.processName).Equals($ExpectedProcessName, [System.StringComparison]::OrdinalIgnoreCase)
      })
    Assert-True ($workerStarts.Count -le 1) "A checkout cycle started more than one exact candidate worker."
    if ($workerStarts.Count -eq 1 -and $null -eq $firstWorkerArrivalMilliseconds) {
      $firstWorkerArrivalMilliseconds = $Stopwatch.ElapsedMilliseconds
    }
    if (
      $workerStarts.Count -eq 1 -and
      ($Stopwatch.ElapsedMilliseconds - [long]$firstWorkerArrivalMilliseconds) -ge $SettlementMilliseconds
    ) {
      $null = Receive-ProcessStartEvents $SourceIdentifier $AllEvents $EventKeys
      $roundEvents = @($AllEvents.GetRange($StartIndex, $AllEvents.Count - $StartIndex))
      $workerStarts = @($roundEvents | Where-Object {
          [long]$_.parentProcessId -eq $DaemonPid -and
          ([string]$_.processName).Equals($ExpectedProcessName, [System.StringComparison]::OrdinalIgnoreCase)
        })
      Assert-True ($workerStarts.Count -eq 1) "A checkout cycle must produce exactly one candidate worker start event."
      return $workerStarts[0]
    }
    Assert-True ($Stopwatch.Elapsed.TotalSeconds -lt $DeadlineSeconds) "The exact candidate worker start event did not settle before the absolute deadline."
    Start-Sleep -Milliseconds 25
  }
}

function Complete-ProcessStartEventDrain(
  [string]$SourceIdentifier,
  [System.Collections.Generic.List[object]]$AllEvents,
  [System.Collections.Generic.HashSet[string]]$EventKeys,
  [System.Diagnostics.Stopwatch]$Stopwatch,
  [int]$DeadlineSeconds,
  [int]$SettlementMilliseconds
) {
  $settlementStart = $Stopwatch.ElapsedMilliseconds
  while (($Stopwatch.ElapsedMilliseconds - $settlementStart) -lt $SettlementMilliseconds) {
    $null = Receive-ProcessStartEvents $SourceIdentifier $AllEvents $EventKeys
    Assert-True ($Stopwatch.Elapsed.TotalSeconds -lt $DeadlineSeconds) "The final process-start event stream did not settle before the absolute deadline."
    Start-Sleep -Milliseconds 25
  }
  $null = Receive-ProcessStartEvents $SourceIdentifier $AllEvents $EventKeys
}

function Get-LiveRecordedWorkerDescendantProcessIds(
  [object[]]$Snapshot,
  [object[]]$AllEvents,
  [object]$WorkerStart
) {
  $workerPid = [long]$WorkerStart.processId
  $liveWorkerIdentity = @(
    $Snapshot | Where-Object {
      [long]$_.ProcessId -eq $WorkerPid -and
      (Get-ProcessSnapshotStartFileTime $_) -le [long]$WorkerStart.eventFileTime
    }
  )
  Assert-True ($liveWorkerIdentity.Count -eq 0) "A recorded worker identity is still alive after checkout settlement."
  $live = [System.Collections.Generic.HashSet[long]]::new()
  foreach ($descendantStart in @(Get-RecordedWorkerDescendantStartEvents $AllEvents $WorkerStart)) {
    $liveDescendantIdentity = @(
      $Snapshot | Where-Object {
        [long]$_.ProcessId -eq [long]$descendantStart.processId -and
        (Get-ProcessSnapshotStartFileTime $_) -le [long]$descendantStart.eventFileTime
      }
    )
    if ($liveDescendantIdentity.Count -gt 0) {
      $null = $live.Add([long]$descendantStart.processId)
    }
  }
  return @($live)
}

function Get-DescendantProcessIds([object[]]$Snapshot, [long]$RootPid) {
  $pending = [System.Collections.Generic.Queue[long]]::new()
  $pending.Enqueue($RootPid)
  $descendants = [System.Collections.Generic.List[long]]::new()
  while ($pending.Count -gt 0) {
    $parent = $pending.Dequeue()
    foreach ($child in @($Snapshot | Where-Object { [long]$_.ParentProcessId -eq $parent })) {
      $childPid = [long]$child.ProcessId
      if (-not $descendants.Contains($childPid)) {
        $descendants.Add($childPid)
        $pending.Enqueue($childPid)
      }
    }
  }
  return @($descendants)
}

function Get-ProcessSnapshotStartFileTime([object]$Process) {
  Assert-True ($null -ne $Process.CreationDate) "CIM did not expose a process creation time."
  return ([DateTime]$Process.CreationDate).ToUniversalTime().ToFileTimeUtc()
}

function Get-ProcessSnapshotIdentityKey([object]$Process) {
  return "$([long]$Process.ProcessId):$(Get-ProcessSnapshotStartFileTime $Process)"
}

function Get-AdditionalDescendantProcessIds(
  [object[]]$Snapshot,
  [long]$RootPid,
  [System.Collections.Generic.HashSet[string]]$BaselineIdentities
) {
  $additional = [System.Collections.Generic.List[long]]::new()
  foreach ($processId in @(Get-DescendantProcessIds $Snapshot $RootPid)) {
    $matches = @($Snapshot | Where-Object { [long]$_.ProcessId -eq [long]$processId })
    Assert-True ($matches.Count -eq 1) "A descendant process identity changed during CIM observation."
    if (-not $BaselineIdentities.Contains((Get-ProcessSnapshotIdentityKey $matches[0]))) {
      $additional.Add([long]$processId)
    }
  }
  return @($additional)
}

function Wait-ForStableZeroAdditionalDescendants(
  [long]$RootPid,
  [System.Collections.Generic.HashSet[string]]$BaselineIdentities,
  [System.Diagnostics.Stopwatch]$Stopwatch,
  [int]$DeadlineSeconds,
  [int]$SettlementMilliseconds
) {
  $zeroSince = $null
  while ($Stopwatch.Elapsed.TotalSeconds -lt $DeadlineSeconds) {
    $snapshot = Get-CimProcessSnapshot
    $descendantCount = @(
      Get-AdditionalDescendantProcessIds $snapshot $RootPid $BaselineIdentities
    ).Count
    if ($descendantCount -eq 0) {
      if ($null -eq $zeroSince) {
        $zeroSince = $Stopwatch.ElapsedMilliseconds
      }
      if (($Stopwatch.ElapsedMilliseconds - [long]$zeroSince) -ge $SettlementMilliseconds) {
        return $snapshot
      }
    }
    else {
      $zeroSince = $null
    }
    Start-Sleep -Milliseconds 25
  }
  throw "The controlled svnserve additional descendants did not settle to zero before the absolute deadline."
}

function Assert-SvnserveIdentity(
  [object[]]$Snapshot,
  [long]$ExpectedPid,
  [DateTimeOffset]$ExpectedStartTime,
  [string]$ExpectedPath,
  [int]$ExpectedPort
) {
  $matches = @($Snapshot | Where-Object { [long]$_.ProcessId -eq $ExpectedPid })
  Assert-True ($matches.Count -eq 1) "The exact controlled svnserve PID is not alive."
  $server = $matches[0]
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$server.ExecutablePath)) "CIM did not expose the controlled svnserve executable path."
  Assert-True (([System.IO.Path]::GetFullPath([string]$server.ExecutablePath)).Equals(
      $ExpectedPath,
      [System.StringComparison]::OrdinalIgnoreCase
    )) "The controlled svnserve PID does not execute the required svnserve bytes."
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$server.CommandLine)) "CIM did not expose the controlled svnserve command line."
  $commandLine = [string]$server.CommandLine
  Assert-True ($commandLine.Contains("--foreground", [System.StringComparison]::Ordinal)) "The controlled svnserve must run in foreground mode."
  $portPattern = '--listen-port\s+"?{0}(?:"|\s|$)' -f [regex]::Escape(
    $ExpectedPort.ToString([Globalization.CultureInfo]::InvariantCulture)
  )
  Assert-True ($commandLine -match $portPattern) "The controlled svnserve command line does not bind the repository URL port."
  $live = $null
  try {
    $live = Get-Process -Id $ExpectedPid -ErrorAction Stop
    $actualStartTime = [DateTimeOffset]$live.StartTime.ToUniversalTime()
  }
  catch {
    throw "The exact controlled svnserve process could not be inspected: $($_.Exception.Message)"
  }
  finally {
    if ($null -ne $live) {
      $live.Dispose()
    }
  }
  Assert-True ($actualStartTime.UtcDateTime.Ticks -eq $ExpectedStartTime.UtcDateTime.Ticks) "The controlled svnserve PID start time changed."
  return $server
}

function Get-CandidateProcessObservation(
  [object[]]$Snapshot,
  [string]$InstalledDaemonPath,
  [Nullable[long]]$ExpectedDaemonPid
) {
  $candidate = @($Snapshot | Where-Object {
      -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
      ([System.IO.Path]::GetFullPath([string]$_.ExecutablePath)).Equals(
        $InstalledDaemonPath,
        [System.StringComparison]::OrdinalIgnoreCase
      )
    })
  Assert-True ($candidate.Count -ge 1) "CIM did not observe the installed candidate daemon."
  foreach ($process in $candidate) {
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$process.CommandLine)) "CIM did not expose a candidate daemon command line."
  }
  $workers = @($candidate | Where-Object { ([string]$_.CommandLine).Contains($WorkerArgument, [System.StringComparison]::Ordinal) })
  $daemons = @($candidate | Where-Object { -not ([string]$_.CommandLine).Contains($WorkerArgument, [System.StringComparison]::Ordinal) })
  Assert-True ($workers.Count -eq 0) "An installed candidate worker remained after the checkout response."
  Assert-True ($daemons.Count -eq 1) "Exactly one installed candidate daemon must own all stress cycles."
  $daemon = $daemons[0]
  $plainPath = [string]$daemon.CommandLine
  Assert-True (
    $plainPath.Equals($InstalledDaemonPath, [System.StringComparison]::OrdinalIgnoreCase) -or
    $plainPath.Equals(('"' + $InstalledDaemonPath + '"'), [System.StringComparison]::OrdinalIgnoreCase)
  ) "The installed candidate daemon command line must contain no arguments."
  if ($null -ne $ExpectedDaemonPid) {
    Assert-True ([long]$daemon.ProcessId -eq [long]$ExpectedDaemonPid) "The installed candidate daemon changed during the stress session."
  }
  return [pscustomobject]@{
    daemonPid = [long]$daemon.ProcessId
  }
}

function Get-TemporaryRootCount([string]$RemoteWorkersRoot) {
  Assert-True (Test-Path -LiteralPath $RemoteWorkersRoot -PathType Container) "The dedicated remote-workers root was not created."
  return @(Get-ChildItem -LiteralPath $RemoteWorkersRoot -Force).Count
}

function Get-CheckoutJournalEntryCount([string]$RemoteStateRoot) {
  Assert-True (Test-Path -LiteralPath $RemoteStateRoot -PathType Container) "The installed candidate remote-state root was not created."
  $temporary = Join-Path $RemoteStateRoot $JournalTemporaryFileName
  Assert-True (-not (Test-Path -LiteralPath $temporary)) "The checkout journal left an orphaned atomic-write temporary file."
  $journalPath = Join-Path $RemoteStateRoot $JournalFileName
  Assert-True (Test-Path -LiteralPath $journalPath -PathType Leaf) "The durable checkout journal was not created."
  try {
    $journal = Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json
  }
  catch {
    throw "The durable checkout journal is not valid JSON: $($_.Exception.Message)"
  }
  Assert-ExactProperties $journal @("schemaVersion", "entries") "checkout journal"
  Assert-True ([int]$journal.schemaVersion -eq 1) "The checkout journal schema must be v1."
  return @($journal.entries).Count
}

function Wait-ForReadyFile(
  [string]$Path,
  [System.Diagnostics.Process]$Process,
  [System.Diagnostics.Stopwatch]$Stopwatch,
  [int]$DeadlineSeconds
) {
  while (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    if ($Process.HasExited) {
      throw "The installed Extension Host exited before writing $([System.IO.Path]::GetFileName($Path))."
    }
    Assert-True ($Stopwatch.Elapsed.TotalSeconds -lt $DeadlineSeconds) "The installed stress probe exceeded its absolute deadline."
    Start-Sleep -Milliseconds 25
  }
}

function Write-AtomicJson([string]$Path, [object]$Value) {
  $temporary = "$Path.tmp"
  Assert-True (-not (Test-Path -LiteralPath $temporary)) "Atomic JSON temporary path already exists."
  $json = $Value | ConvertTo-Json -Depth 16 -Compress
  [System.IO.File]::WriteAllText($temporary, $json, [System.Text.UTF8Encoding]::new($false))
  Move-Item -LiteralPath $temporary -Destination $Path
}

function Read-And-ValidateReadyReport(
  [string]$Path,
  [int]$ExpectedCycle,
  [string]$ExpectedSessionHash,
  [string]$ExpectedRepositoryUrl,
  [string]$ExpectedCheckoutPath,
  [int]$ExpectedRevision
) {
  try {
    $ready = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -Depth 32
  }
  catch {
    throw "The installed Extension Host ready report is not valid JSON: $($_.Exception.Message)"
  }
  Assert-ExactProperties $ready @("cycle", "extensionHostSessionSha256", "report") "cycle ready report"
  Assert-True ([int]$ready.cycle -eq $ExpectedCycle) "The ready report cycle index is invalid."
  Assert-True ([string]$ready.extensionHostSessionSha256 -cmatch '^[0-9a-f]{64}$') "The Extension Host session hash is invalid."
  if (-not [string]::IsNullOrEmpty($ExpectedSessionHash)) {
    Assert-True ([string]$ready.extensionHostSessionSha256 -ceq $ExpectedSessionHash) "The Extension Host session changed during stress."
  }
  $report = $ready.report
  Assert-ExactProperties $report @(
    "schema", "schemaVersion", "kind", "operationId", "extensionHostSessionSha256", "revision", "protocol", "trust", "authActivity", "redaction"
  ) "installed stress checkout report"
  Assert-True ([string]$report.schema -ceq "subversionr.release.m8-i6-installed-svn-anonymous-stress-checkout.v1") "The installed stress checkout schema is invalid."
  Assert-True ([int]$report.schemaVersion -eq 1) "The installed stress checkout schema version is invalid."
  Assert-True ([string]$report.kind -ceq "subversionr.installedSvnAnonymousStressCheckout") "The installed stress checkout kind is invalid."
  Assert-True ([string]$report.operationId -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') "The installed stress checkout operation ID is invalid."
  Assert-True ([string]$report.operationId -cne "00000000-0000-0000-0000-000000000000") "The installed stress checkout operation ID must not be nil."
  Assert-True ([string]$report.extensionHostSessionSha256 -ceq [string]$ready.extensionHostSessionSha256) "The installed candidate and harness did not execute in the same Extension Host process."
  Assert-True ([int]$report.revision -eq $ExpectedRevision) "The installed stress checkout returned an unexpected revision."
  Assert-ExactProperties $report.protocol @("major", "minor") "installed stress protocol"
  Assert-True ([int]$report.protocol.major -eq 1 -and [int]$report.protocol.minor -eq 35) "The installed stress checkout must use protocol 1.35."
  Assert-ExactProperties $report.trust @("acknowledgedEpoch", "consistent") "installed stress trust"
  Assert-True ([int]$report.trust.acknowledgedEpoch -ge 1 -and $report.trust.consistent -eq $true) "The installed stress checkout trust epoch is invalid."
  Assert-ExactProperties $report.authActivity @("credentialRequests", "credentialSettlements", "certificateRequests") "installed stress auth activity"
  Assert-True (
    [int]$report.authActivity.credentialRequests -eq 0 -and
    [int]$report.authActivity.credentialSettlements -eq 0 -and
    [int]$report.authActivity.certificateRequests -eq 0
  ) "The installed anonymous stress checkout produced authentication activity."
  Assert-ExactProperties $report.redaction @("rawUrls", "rawPaths", "rawContent") "installed stress redaction"
  Assert-True (
    $report.redaction.rawUrls -eq $false -and
    $report.redaction.rawPaths -eq $false -and
    $report.redaction.rawContent -eq $false
  ) "The installed stress checkout redaction contract is invalid."
  $serialized = $report | ConvertTo-Json -Depth 16 -Compress
  Assert-True (-not $serialized.Contains($ExpectedRepositoryUrl)) "The installed stress checkout report leaked the repository URL."
  Assert-True (-not $serialized.Contains($ExpectedCheckoutPath)) "The installed stress checkout report leaked the checkout path."
  return $ready
}

function Remove-ObservedCheckout([string]$Path) {
  Assert-True (Test-Path -LiteralPath $Path -PathType Container) "The successful installed checkout target is missing."
  Assert-True (Test-Path -LiteralPath (Join-Path $Path ".svn\wc.db") -PathType Leaf) "The installed checkout target does not contain a working-copy database."
  $rootItem = Get-Item -LiteralPath $Path -Force
  Assert-True (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) "The installed checkout target is an unexpected reparse point."
  $reparsePoints = @(Get-ChildItem -LiteralPath $Path -Recurse -Force | Where-Object {
      ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    })
  Assert-True ($reparsePoints.Count -eq 0) "The installed checkout target contains an unexpected reparse point."
  Remove-Item -LiteralPath $Path -Recurse -Force
  Assert-True (-not (Test-Path -LiteralPath $Path)) "The installed checkout target cleanup did not complete."
}

function Stop-ProcessTree([System.Diagnostics.Process]$Process) {
  if ($null -eq $Process -or $Process.HasExited) {
    return
  }
  $taskkill = Join-Path $env:SystemRoot "System32\taskkill.exe"
  Assert-True (Test-Path -LiteralPath $taskkill -PathType Leaf) "taskkill.exe is required to terminate a timed-out Extension Host tree."
  & $taskkill /PID $Process.Id /T /F 2>$null | Out-Null
  [void]$Process.WaitForExit(10000)
}

function Wait-ForCandidateExit(
  [string]$InstalledDaemonPath,
  [System.Diagnostics.Stopwatch]$Stopwatch,
  [int]$DeadlineSeconds
) {
  while ($true) {
    $snapshot = Get-CimProcessSnapshot
    $remaining = @($snapshot | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([System.IO.Path]::GetFullPath([string]$_.ExecutablePath)).Equals(
          $InstalledDaemonPath,
          [System.StringComparison]::OrdinalIgnoreCase
        )
      })
    if ($remaining.Count -eq 0) {
      return
    }
    Assert-True ($Stopwatch.Elapsed.TotalSeconds -lt $DeadlineSeconds) "The installed candidate daemon did not exit before the absolute deadline."
    Start-Sleep -Milliseconds 25
  }
}

$vsixResolved = Resolve-RequiredFile $VsixPath "VsixPath"
$codeResolved = Resolve-RequiredFile $CodeCliPath "CodeCliPath"
Assert-True ((Split-Path -Leaf $codeResolved) -in @("code.cmd", "code.exe")) "CodeCliPath must point to code.cmd or code.exe."
$daemonResolved = Resolve-RequiredFile $DaemonPath "DaemonPath"
$bridgeResolved = Resolve-RequiredFile $BridgePath "BridgePath"
$svnserveResolved = Resolve-RequiredFile $SvnservePath "SvnservePath"
$fixtureResolved = Resolve-GeneratedPath $FixtureRoot "FixtureRoot"
$checkoutResolved = Resolve-GeneratedPath $CheckoutPath "CheckoutPath"
Assert-True (Test-PathWithin $checkoutResolved $fixtureResolved) "CheckoutPath must be strictly below FixtureRoot."
Assert-True (-not $checkoutResolved.Equals($fixtureResolved, [System.StringComparison]::OrdinalIgnoreCase)) "CheckoutPath must not equal FixtureRoot."

try {
  $repositoryUri = [System.Uri]::new($RepositoryUrl, [System.UriKind]::Absolute)
}
catch {
  throw "RepositoryUrl must be an absolute direct svn:// URL."
}
Assert-True (
  $repositoryUri.Scheme -ceq "svn" -and
  $repositoryUri.Host -ceq "127.0.0.1" -and
  $repositoryUri.Port -gt 0 -and
  [string]::IsNullOrEmpty($repositoryUri.UserInfo) -and
  [string]::IsNullOrEmpty($repositoryUri.Query) -and
  [string]::IsNullOrEmpty($repositoryUri.Fragment) -and
  $repositoryUri.AbsolutePath -cne "/"
) "RepositoryUrl must use the controlled direct svn:// IPv4 loopback endpoint without user info, query, or fragment."

try {
  $expectedServerStartTime = [DateTimeOffset]::ParseExact(
    $SvnserveStartTimeUtc,
    "O",
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::RoundtripKind
  ).ToUniversalTime()
}
catch {
  throw "SvnserveStartTimeUtc must be an exact round-trip timestamp."
}
Assert-True ($SvnserveStartTimeUtc.EndsWith("Z", [System.StringComparison]::Ordinal)) "SvnserveStartTimeUtc must be normalized to UTC with a Z suffix."
Assert-True ($null -ne (Get-Command Get-CimInstance -CommandType Cmdlet -ErrorAction Stop)) "Get-CimInstance is required."
Assert-True ($null -ne (Get-Command Register-CimIndicationEvent -CommandType Cmdlet -ErrorAction Stop)) "Register-CimIndicationEvent is required."
$initialSnapshot = Get-CimProcessSnapshot
$null = Assert-SvnserveIdentity $initialSnapshot $SvnservePid $expectedServerStartTime $svnserveResolved $repositoryUri.Port

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = $null
try {
  try {
    $archive = [System.IO.Compression.ZipFile]::OpenRead($vsixResolved)
  }
  catch {
    throw "VsixPath must be a valid VSIX ZIP archive."
  }
  $packageEntry = Get-ZipEntry $archive "extension/package.json"
  $manifestEntry = Get-ZipEntry $archive "extension.vsixmanifest"
  $daemonEntry = Get-ZipEntry $archive "extension/resources/backend/win32-x64/subversionr-daemon.exe"
  $bridgeEntry = Get-ZipEntry $archive "extension/resources/backend/win32-x64/subversionr_svn_bridge.dll"
  $package = Read-ZipEntryText $packageEntry | ConvertFrom-Json
  Assert-True ([string]$package.publisher -ceq "hitsuki-ban" -and [string]$package.name -ceq "subversionr") "VSIX extension identity must be hitsuki-ban.subversionr."
  Assert-True ([string]$package.version -ceq $ExpectedProductVersion) "VSIX product version must match ExpectedProductVersion."
  Assert-True (@($package.activationEvents | Where-Object { $_ -ceq "onCommand:$StressCommand" }).Count -eq 1) "VSIX must activate on the installed stress checkout command."
  $manifest = [xml](Read-ZipEntryText $manifestEntry)
  $identities = @($manifest.SelectNodes("//*[local-name()='PackageManifest']/*[local-name()='Metadata']/*[local-name()='Identity']"))
  Assert-True ($identities.Count -eq 1 -and [string]$identities[0].TargetPlatform -ceq "win32-x64") "VSIX target platform must be win32-x64."
  Assert-True ((Get-ZipEntrySha256 $daemonEntry) -ceq (Get-Sha256 $daemonResolved)) "DaemonPath must match the daemon embedded in VsixPath."
  Assert-True ((Get-ZipEntrySha256 $bridgeEntry) -ceq (Get-Sha256 $bridgeResolved)) "BridgePath must match the bridge embedded in VsixPath."
}
finally {
  if ($null -ne $archive) {
    $archive.Dispose()
  }
}

if (Test-Path -LiteralPath $fixtureResolved) {
  Remove-Item -LiteralPath $fixtureResolved -Recurse -Force
}
$userDataRoot = Join-Path $fixtureResolved "user-data"
$extensionsRoot = Join-Path $fixtureResolved "extensions"
$workspaceRoot = Join-Path $fixtureResolved "workspace"
$harnessRoot = Join-Path $fixtureResolved "harness"
$harnessDistRoot = Join-Path $harnessRoot "dist"
$handshakeRoot = Join-Path $fixtureResolved "handshake"
$resultPath = Join-Path $fixtureResolved "extension-host-result.json"
$codeStdoutPath = Join-Path $fixtureResolved "extension-host.stdout.log"
$codeStderrPath = Join-Path $fixtureResolved "extension-host.stderr.log"
$environmentRoot = Join-Path $fixtureResolved "environment"
$tempRoot = Join-Path $environmentRoot "temp"
$appDataRoot = Join-Path $environmentRoot "appdata"
$localAppDataRoot = Join-Path $environmentRoot "localappdata"
$profileRoot = Join-Path $environmentRoot "profile"
$remoteWorkersRoot = Join-Path $tempRoot "SubversionR\remote-workers"
$remoteStateRoot = Join-Path $userDataRoot "User\globalStorage\hitsuki-ban.subversionr\remote-state"
foreach ($directory in @(
    $userDataRoot, $extensionsRoot, $workspaceRoot, $harnessDistRoot, $handshakeRoot,
    $tempRoot, $appDataRoot, $localAppDataRoot, $profileRoot, (Split-Path -Parent $checkoutResolved)
  )) {
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
}

@'
{
  "name": "subversionr-m8-i6-installed-stress-harness",
  "displayName": "SubversionR M8 I6 Installed Stress Harness",
  "version": "0.0.0",
  "publisher": "hitsuki-ban-test",
  "private": true,
  "engines": { "vscode": "^1.101.0" },
  "main": "./dist/extension.js",
  "activationEvents": []
}
'@ | Set-Content -LiteralPath (Join-Path $harnessRoot "package.json") -Encoding utf8 -NoNewline
"exports.activate = function () {}; exports.deactivate = function () {};" |
  Set-Content -LiteralPath (Join-Path $harnessDistRoot "extension.js") -Encoding utf8 -NoNewline

@'
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const vscode = require("vscode");

const COMMAND = "subversionr.diagnostics.installedSvnAnonymousStressCheckout";
const CYCLES = 101;

function requiredEnvironment(name) {
  const value = process.env[name];
  if (typeof value !== "string" || value.length === 0) throw new Error(`Missing required stress environment: ${name}`);
  return value;
}

function remainingMilliseconds(deadline) {
  const remaining = deadline - Date.now();
  if (!Number.isSafeInteger(remaining) || remaining < 1) throw new Error("Installed stress harness exceeded its absolute deadline.");
  return remaining;
}

async function withDeadline(promise, label, deadline) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(`${label} exceeded the absolute deadline.`)), remainingMilliseconds(deadline));
      }),
    ]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

function atomicWriteJson(filePath, value) {
  const temporaryPath = `${filePath}.tmp`;
  fs.writeFileSync(temporaryPath, JSON.stringify(value), { encoding: "utf8", flag: "wx" });
  fs.renameSync(temporaryPath, filePath);
}

async function waitForAck(filePath, cycle, deadline) {
  while (!fs.existsSync(filePath)) {
    remainingMilliseconds(deadline);
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  const ack = JSON.parse(fs.readFileSync(filePath, "utf8"));
  if (JSON.stringify(Object.keys(ack).sort()) !== JSON.stringify(["accepted", "cycle"])) {
    throw new Error("Installed stress acknowledgement fields are invalid.");
  }
  if (ack.cycle !== cycle || ack.accepted !== true) throw new Error("Installed stress acknowledgement is invalid.");
}

async function run() {
  const resultPath = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_STRESS_RESULT");
  const extensionsRoot = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_STRESS_EXTENSIONS_ROOT");
  const handshakeRoot = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_STRESS_HANDSHAKE_ROOT");
  const repositoryUrl = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_STRESS_REPOSITORY_URL");
  const checkoutPath = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_STRESS_CHECKOUT_PATH");
  const revisionText = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_STRESS_CHECKOUT_REVISION");
  const token = requiredEnvironment("SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_STRESS_CHECKOUT_TOKEN");
  const deadlineText = requiredEnvironment("SUBVERSIONR_INSTALLED_I6_STRESS_DEADLINE_EPOCH_MS");
  const checkoutRevision = Number(revisionText);
  const deadline = Number(deadlineText);
  if (!Number.isSafeInteger(checkoutRevision) || checkoutRevision < 0 || checkoutRevision > 2147483647) {
    throw new Error("Installed stress checkout revision is invalid.");
  }
  if (!Number.isSafeInteger(deadline) || deadline <= Date.now()) throw new Error("Installed stress deadline is invalid.");

  const extension = vscode.extensions.getExtension("hitsuki-ban.subversionr");
  if (!extension) throw new Error("Installed SubversionR extension was not visible.");
  if (extension.isActive) throw new Error("Installed SubversionR extension activated before the stress command.");
  const normalizedExtension = path.resolve(extension.extensionPath).toLowerCase();
  const normalizedRoot = path.resolve(extensionsRoot).toLowerCase();
  if (!normalizedExtension.startsWith(normalizedRoot + path.sep)) {
    throw new Error("SubversionR was not loaded from the isolated installed extensions root.");
  }
  const sessionSha256 = crypto.createHash("sha256").update(`${token}:${process.pid}`, "utf8").digest("hex");
  const operationIds = new Set();

  for (let cycle = 1; cycle <= CYCLES; cycle += 1) {
    const operationId = crypto.randomUUID();
    if (operationIds.has(operationId)) throw new Error("Installed stress operation IDs must be unique.");
    operationIds.add(operationId);
    const report = await withDeadline(vscode.commands.executeCommand(COMMAND, {
      token,
      repositoryUrl,
      checkoutPath,
      checkoutRevision,
      operationId,
    }), `installed stress checkout ${cycle}`, deadline);
    const active = vscode.extensions.getExtension("hitsuki-ban.subversionr");
    if (!active?.isActive || active.extensionPath !== extension.extensionPath) {
      throw new Error("Installed SubversionR extension identity changed during stress.");
    }
    const stem = `cycle-${String(cycle).padStart(3, "0")}`;
    const readyPath = path.join(handshakeRoot, `${stem}.ready`);
    const ackPath = path.join(handshakeRoot, `${stem}.ack`);
    atomicWriteJson(readyPath, { cycle, extensionHostSessionSha256: sessionSha256, report });
    await waitForAck(ackPath, cycle, deadline);
    fs.unlinkSync(readyPath);
    fs.unlinkSync(ackPath);
  }

  atomicWriteJson(resultPath, {
    schema: "subversionr.release.m8-i6-installed-stress-extension-host.v1",
    extensionId: extension.id,
    extensionVersion: extension.packageJSON.version,
    extensionHostSessionSha256: sessionSha256,
    completedCycles: CYCLES,
    uniqueOperationIds: operationIds.size === CYCLES,
  });
}

exports.run = run;
'@ | Set-Content -LiteralPath (Join-Path $harnessDistRoot "run-tests.js") -Encoding utf8 -NoNewline

$environmentNames = @(
  "TEMP", "TMP", "APPDATA", "LOCALAPPDATA", "USERPROFILE", "HOME",
  "SUBVERSIONR_INSTALLED_I6_STRESS_RESULT",
  "SUBVERSIONR_INSTALLED_I6_STRESS_EXTENSIONS_ROOT",
  "SUBVERSIONR_INSTALLED_I6_STRESS_HANDSHAKE_ROOT",
  "SUBVERSIONR_INSTALLED_I6_STRESS_REPOSITORY_URL",
  "SUBVERSIONR_INSTALLED_I6_STRESS_CHECKOUT_PATH",
  "SUBVERSIONR_INSTALLED_I6_STRESS_CHECKOUT_REVISION",
  "SUBVERSIONR_INSTALLED_I6_STRESS_DEADLINE_EPOCH_MS",
  $StressTokenEnvironment
)
$previousEnvironment = @{}
foreach ($name in $environmentNames) {
  $previousEnvironment[$name] = Get-ProcessEnvironmentValue $name
}

$codeProcess = $null
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$observations = [System.Collections.Generic.List[object]]::new()
$operationIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$operationIdHashes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$svnserveBaselineDescendantIdentities = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$processStartEvents = [System.Collections.Generic.List[object]]::new()
$processStartEventKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$workerStarts = [System.Collections.Generic.List[object]]::new()
$processStartSourceIdentifier = "subversionr-m8-i6-process-start-$([Guid]::NewGuid().ToString('N'))"
$processStartSubscriber = $null
$processEventCursor = 0
$previousWorkerStartFileTime = 0L
$candidateDaemonStartFileTime = 0L
$expectedSessionHash = ""
$candidateDaemonPid = $null
try {
  $env:TEMP = $tempRoot
  $env:TMP = $tempRoot
  $env:APPDATA = $appDataRoot
  $env:LOCALAPPDATA = $localAppDataRoot
  $env:USERPROFILE = $profileRoot
  $env:HOME = $profileRoot

  $installOutput = @(& $codeResolved --user-data-dir $userDataRoot --extensions-dir $extensionsRoot --install-extension $vsixResolved --force 2>&1)
  Assert-True ($LASTEXITCODE -eq 0) "VS Code CLI install failed."
  $installed = @(& $codeResolved --user-data-dir $userDataRoot --extensions-dir $extensionsRoot --list-extensions --show-versions)
  Assert-True ($LASTEXITCODE -eq 0) "VS Code CLI extension listing failed."
  Assert-True ($installed -contains "hitsuki-ban.subversionr@$ExpectedProductVersion") "Installed extension version did not match ExpectedProductVersion."
  $installedPackageRoot = Find-InstalledPackage $extensionsRoot $ExpectedProductVersion
  $installedDaemonPath = Resolve-RequiredFile (Join-Path $installedPackageRoot "resources\backend\win32-x64\subversionr-daemon.exe") "installed daemon"
  $installedBridgePath = Resolve-RequiredFile (Join-Path $installedPackageRoot "resources\backend\win32-x64\subversionr_svn_bridge.dll") "installed bridge"
  Assert-True ((Get-Sha256 $installedDaemonPath) -ceq (Get-Sha256 $daemonResolved)) "Installed daemon bytes do not match DaemonPath."
  Assert-True ((Get-Sha256 $installedBridgePath) -ceq (Get-Sha256 $bridgeResolved)) "Installed bridge bytes do not match BridgePath."

  $svnserveBaselineSnapshot = Get-CimProcessSnapshot
  $null = Assert-SvnserveIdentity `
    $svnserveBaselineSnapshot $SvnservePid $expectedServerStartTime $svnserveResolved $repositoryUri.Port
  $svnserveBaselineDescendantIds = @(
    Get-DescendantProcessIds $svnserveBaselineSnapshot $SvnservePid
  )
  Assert-True ($svnserveBaselineDescendantIds.Count -le 1) "The controlled svnserve baseline contained an unexpected process tree."
  foreach ($baselineProcessId in $svnserveBaselineDescendantIds) {
    $baselineMatches = @($svnserveBaselineSnapshot | Where-Object {
        [long]$_.ProcessId -eq [long]$baselineProcessId
      })
    Assert-True ($baselineMatches.Count -eq 1) "The controlled svnserve baseline descendant identity changed."
    Assert-True (
      ([string]$baselineMatches[0].Name).Equals("conhost.exe", [System.StringComparison]::OrdinalIgnoreCase)
    ) "The controlled svnserve baseline may contain only its Windows console host."
    Assert-True (
      $svnserveBaselineDescendantIdentities.Add((Get-ProcessSnapshotIdentityKey $baselineMatches[0]))
    ) "The controlled svnserve baseline descendant identity was duplicated."
  }

  try {
    Register-CimIndicationEvent `
      -ClassName Win32_ProcessStartTrace `
      -SourceIdentifier $processStartSourceIdentifier `
      -ErrorAction Stop | Out-Null
  }
  catch {
    throw "Win32_ProcessStartTrace subscription is required for installed worker evidence: $($_.Exception.Message)"
  }
  $matchingSubscribers = @(Get-EventSubscriber -SourceIdentifier $processStartSourceIdentifier -ErrorAction Stop)
  Assert-True ($matchingSubscribers.Count -eq 1) "The process-start event subscription was not created exactly once."
  $processStartSubscriber = $matchingSubscribers[0]
  Start-Sleep -Milliseconds $ProcessStartEventSettlementMilliseconds

  $deadlineEpochMs = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds).ToUnixTimeMilliseconds()
  $env:SUBVERSIONR_INSTALLED_I6_STRESS_RESULT = $resultPath
  $env:SUBVERSIONR_INSTALLED_I6_STRESS_EXTENSIONS_ROOT = $extensionsRoot
  $env:SUBVERSIONR_INSTALLED_I6_STRESS_HANDSHAKE_ROOT = $handshakeRoot
  $env:SUBVERSIONR_INSTALLED_I6_STRESS_REPOSITORY_URL = $RepositoryUrl
  $env:SUBVERSIONR_INSTALLED_I6_STRESS_CHECKOUT_PATH = $checkoutResolved
  $env:SUBVERSIONR_INSTALLED_I6_STRESS_CHECKOUT_REVISION = $CheckoutRevision.ToString([Globalization.CultureInfo]::InvariantCulture)
  $env:SUBVERSIONR_INSTALLED_I6_STRESS_DEADLINE_EPOCH_MS = $deadlineEpochMs.ToString([Globalization.CultureInfo]::InvariantCulture)
  Set-Item -LiteralPath "Env:$StressTokenEnvironment" -Value ([Guid]::NewGuid().ToString("N"))

  $arguments = @(
    "--user-data-dir", $userDataRoot,
    "--extensions-dir", $extensionsRoot,
    "--disable-workspace-trust",
    "--new-window",
    "--extensionDevelopmentPath=$harnessRoot",
    "--extensionTestsPath=$(Join-Path $harnessDistRoot 'run-tests.js')",
    "--log", "trace",
    "--wait",
    $workspaceRoot
  )
  $argumentLine = @($arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join " "
  $codeProcess = Start-Process `
    -FilePath $codeResolved `
    -ArgumentList $argumentLine `
    -WindowStyle Hidden `
    -RedirectStandardOutput $codeStdoutPath `
    -RedirectStandardError $codeStderrPath `
    -PassThru
  Assert-True ($null -ne $codeProcess) "VS Code installed stress Extension Host failed to start."

  for ($cycle = 1; $cycle -le $SubsequentCycle; $cycle += 1) {
    $stem = "cycle-$($cycle.ToString('000', [Globalization.CultureInfo]::InvariantCulture))"
    $readyPath = Join-Path $handshakeRoot "$stem.ready"
    $ackPath = Join-Path $handshakeRoot "$stem.ack"
    Wait-ForReadyFile $readyPath $codeProcess $stopwatch $TimeoutSeconds
    $ready = Read-And-ValidateReadyReport `
      $readyPath $cycle $expectedSessionHash $RepositoryUrl $checkoutResolved $CheckoutRevision
    if ([string]::IsNullOrEmpty($expectedSessionHash)) {
      $expectedSessionHash = [string]$ready.extensionHostSessionSha256
    }
    $operationId = [string]$ready.report.operationId
    Assert-True ($operationIds.Add($operationId)) "The installed stress operation ID was reused."
    $operationIdSha256 = Get-StringSha256 $operationId
    Assert-True ($operationIdHashes.Add($operationIdSha256)) "The installed stress operation ID hash was reused."

    $discoverySnapshot = Get-CimProcessSnapshot
    $candidateObservation = Get-CandidateProcessObservation $discoverySnapshot $installedDaemonPath $candidateDaemonPid
    if ($null -eq $candidateDaemonPid) {
      $candidateDaemonPid = [long]$candidateObservation.daemonPid
    }
    $workerStart = Wait-ForExactWorkerStart `
      $processStartSourceIdentifier `
      $processStartEvents `
      $processStartEventKeys `
      $processEventCursor `
      $candidateDaemonPid `
      ([System.IO.Path]::GetFileName($installedDaemonPath)) `
      $stopwatch `
      $TimeoutSeconds `
      $ProcessStartEventSettlementMilliseconds
    $candidateDaemonStarts = @($processStartEvents | Where-Object {
        [long]$_.processId -eq $candidateDaemonPid -and
        ([string]$_.processName).Equals(
          [System.IO.Path]::GetFileName($installedDaemonPath),
          [System.StringComparison]::OrdinalIgnoreCase
        )
      })
    Assert-True ($candidateDaemonStarts.Count -eq 1) "The exact installed candidate daemon PID must have one subscribed start identity."
    if ($candidateDaemonStartFileTime -eq 0L) {
      $candidateDaemonStartFileTime = [long]$candidateDaemonStarts[0].eventFileTime
    }
    Assert-True (
      [long]$candidateDaemonStarts[0].eventFileTime -eq $candidateDaemonStartFileTime
    ) "The installed candidate daemon PID was reused during the stress session."
    Assert-True (
      [long]$workerStart.parentProcessId -eq $candidateDaemonPid -and
      [long]$workerStart.processId -ne $candidateDaemonPid -and
      [long]$workerStart.eventFileTime -gt $candidateDaemonStartFileTime
    ) "The candidate worker start identity is not a child created after the exact installed daemon start."
    Assert-True (
      [long]$workerStart.eventFileTime -gt $previousWorkerStartFileTime
    ) "Candidate worker start events must be strictly ordered across stress cycles."
    $previousWorkerStartFileTime = [long]$workerStart.eventFileTime
    $workerStarts.Add($workerStart)
    $processEventCursor = $processStartEvents.Count
    Assert-RecordedWorkerIdentitiesClean @($processStartEvents) @($workerStarts)

    $snapshot = Wait-ForStableZeroAdditionalDescendants `
      $SvnservePid `
      $svnserveBaselineDescendantIdentities `
      $stopwatch `
      $TimeoutSeconds `
      $ProcessStartEventSettlementMilliseconds
    $null = Assert-SvnserveIdentity $snapshot $SvnservePid $expectedServerStartTime $svnserveResolved $repositoryUri.Port
    $fixtureServerChildren = @(
      Get-AdditionalDescendantProcessIds $snapshot $SvnservePid $svnserveBaselineDescendantIdentities
    ).Count
    Assert-True ($fixtureServerChildren -eq 0) "The controlled svnserve retained child processes after a stress cycle."
    $settledCandidate = Get-CandidateProcessObservation $snapshot $installedDaemonPath $candidateDaemonPid
    Assert-True ([long]$settledCandidate.daemonPid -eq $candidateDaemonPid) "The installed candidate daemon changed after worker event settlement."
    $liveWorkerDescendants = @(
      Get-LiveRecordedWorkerDescendantProcessIds $snapshot @($processStartEvents) $workerStart
    )
    Assert-True ($liveWorkerDescendants.Count -eq 0) "A recorded exited worker retained live orphan descendants after checkout settlement."
    $temporaryRootCount = Get-TemporaryRootCount $remoteWorkersRoot
    Assert-True ($temporaryRootCount -eq 0) "The installed checkout left operation temporary roots."
    $journalEntryCount = Get-CheckoutJournalEntryCount $remoteStateRoot
    Assert-True ($journalEntryCount -eq 0) "The installed checkout left durable journal entries."

    $observation = [pscustomobject]@{
      cycle = $cycle
      operation = "checkout"
      status = "passed"
      revision = [int]$ready.report.revision
      operationIdSha256 = $operationIdSha256
      extensionHostSessionSha256 = $expectedSessionHash
      candidateDaemonProcessId = $candidateDaemonPid
      workerProcessId = [long]$workerStart.processId
      workerParentProcessId = [long]$workerStart.parentProcessId
      workerStartTimeUtc = [string]$workerStart.eventTimeUtc
      workerStartEventObserved = $true
      workerDescendantsAfter = $liveWorkerDescendants.Count
      temporaryRootsAfter = $temporaryRootCount
      fixtureServerChildrenAfter = $fixtureServerChildren
      checkoutJournalEntriesAfter = $journalEntryCount
      diagnosticsRedacted = $true
    }
    $observations.Add($observation)

    Remove-ObservedCheckout $checkoutResolved
    Write-AtomicJson $ackPath ([ordered]@{ cycle = $cycle; accepted = $true })
  }

  Assert-True ($codeProcess.WaitForExit([Math]::Max(1, [int](($TimeoutSeconds - $stopwatch.Elapsed.TotalSeconds) * 1000)))) "The installed Extension Host did not exit before the absolute deadline."
  Assert-True ($codeProcess.ExitCode -eq 0) "The installed Extension Host failed with exit code $($codeProcess.ExitCode)."
  Assert-True (Test-Path -LiteralPath $resultPath -PathType Leaf) "The installed Extension Host did not write its final bounded result."
  $extensionHostResult = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json
  Assert-ExactProperties $extensionHostResult @(
    "schema", "extensionId", "extensionVersion", "extensionHostSessionSha256", "completedCycles", "uniqueOperationIds"
  ) "installed Extension Host stress result"
  Assert-True ([string]$extensionHostResult.schema -ceq "subversionr.release.m8-i6-installed-stress-extension-host.v1") "The installed Extension Host result schema is invalid."
  Assert-True ([string]$extensionHostResult.extensionId -ceq "hitsuki-ban.subversionr") "The installed Extension Host extension ID is invalid."
  Assert-True ([string]$extensionHostResult.extensionVersion -ceq $ExpectedProductVersion) "The installed Extension Host extension version is invalid."
  Assert-True ([string]$extensionHostResult.extensionHostSessionSha256 -ceq $expectedSessionHash) "The installed Extension Host final session hash changed."
  Assert-True ([int]$extensionHostResult.completedCycles -eq $SubsequentCycle -and $extensionHostResult.uniqueOperationIds -eq $true) "The installed Extension Host did not complete 101 unique requests."
  Assert-True ($operationIds.Count -eq $SubsequentCycle) "The outer stress controller did not observe 101 unique operation IDs."

  Wait-ForCandidateExit $installedDaemonPath $stopwatch $TimeoutSeconds
  Complete-ProcessStartEventDrain `
    $processStartSourceIdentifier `
    $processStartEvents `
    $processStartEventKeys `
    $stopwatch `
    $TimeoutSeconds `
    $ProcessStartEventSettlementMilliseconds
  Assert-RecordedWorkerIdentitiesClean @($processStartEvents) @($workerStarts)
  $finalSnapshot = Wait-ForStableZeroAdditionalDescendants `
    $SvnservePid `
    $svnserveBaselineDescendantIdentities `
    $stopwatch `
    $TimeoutSeconds `
    $ProcessStartEventSettlementMilliseconds
  $null = Assert-SvnserveIdentity $finalSnapshot $SvnservePid $expectedServerStartTime $svnserveResolved $repositoryUri.Port
  Assert-True (
    @(Get-AdditionalDescendantProcessIds $finalSnapshot $SvnservePid $svnserveBaselineDescendantIdentities).Count -eq 0
  ) "The controlled svnserve retained additional children after Extension Host shutdown."
  foreach ($workerStart in $workerStarts) {
    Assert-True (
      @(
        Get-LiveRecordedWorkerDescendantProcessIds $finalSnapshot @($processStartEvents) $workerStart
      ).Count -eq 0
    ) "A recorded exited worker retained live orphan descendants after Extension Host shutdown."
  }
  Assert-True ((Get-TemporaryRootCount $remoteWorkersRoot) -eq 0) "Operation temporary roots remained after Extension Host shutdown."
  Assert-True ((Get-CheckoutJournalEntryCount $remoteStateRoot) -eq 0) "Checkout journal entries remained after Extension Host shutdown."
  Assert-True (@(Get-ChildItem -LiteralPath $handshakeRoot -Force).Count -eq 0) "The ready/ack handshake directory was not cleared."

  $cycleObservations = @($observations | Select-Object -First $CycleCount)
  $subsequentObservation = $observations[$CycleCount]
  Assert-True ($cycleObservations.Count -eq $CycleCount -and [int]$subsequentObservation.cycle -eq $SubsequentCycle) "Stress observations must contain exact cycles 1 through 101."
  $maxWorker = [int](($cycleObservations | Measure-Object -Property workerDescendantsAfter -Maximum).Maximum)
  $maxTemporary = [int](($cycleObservations | Measure-Object -Property temporaryRootsAfter -Maximum).Maximum)
  $maxServerChildren = [int](($cycleObservations | Measure-Object -Property fixtureServerChildrenAfter -Maximum).Maximum)
  $maxJournal = [int](($cycleObservations | Measure-Object -Property checkoutJournalEntriesAfter -Maximum).Maximum)
  Assert-True ($maxWorker -eq 0 -and $maxTemporary -eq 0 -and $maxServerChildren -eq 0 -and $maxJournal -eq 0) "Installed stress maxima must be zero."

  [pscustomobject]@{
    schema = "subversionr.release.m8-i6-installed-vsix-stress.v1"
    schemaVersion = 1
    surface = "installed-vsix-extension-host"
    status = "passed"
    cycles = $CycleCount
    targetPathSha256 = Get-StringSha256 ($checkoutResolved.ToLowerInvariant())
    extensionHostSessionSha256 = $expectedSessionHash
    operationIdHashesUnique = ($operationIdHashes.Count -eq $SubsequentCycle)
    singleExtensionHostSession = $true
    artifactBindings = [pscustomobject]@{
      vsixSha256 = Get-Sha256 $vsixResolved
      daemonSha256 = Get-Sha256 $daemonResolved
      bridgeSha256 = Get-Sha256 $bridgeResolved
      svnserveSha256 = Get-Sha256 $svnserveResolved
    }
    observations = $cycleObservations
    subsequentRequest = $subsequentObservation
    maxWorkerDescendantsAfterCycle = $maxWorker
    maxTemporaryRootsAfterCycle = $maxTemporary
    maxFixtureServerChildrenAfterCycle = $maxServerChildren
    maxCheckoutJournalEntriesAfterCycle = $maxJournal
    subsequentRequestPassed = $true
    candidateDaemonExitedAfter = $true
  } | ConvertTo-Json -Depth 16 -Compress
}
finally {
  if ($null -ne $codeProcess -and -not $codeProcess.HasExited) {
    Stop-ProcessTree $codeProcess
  }
  if ($null -ne $codeProcess) {
    $codeProcess.Dispose()
  }
  if ($null -ne $processStartSubscriber) {
    Unregister-Event -SubscriptionId $processStartSubscriber.SubscriptionId -ErrorAction SilentlyContinue
  }
  Get-Event -SourceIdentifier $processStartSourceIdentifier -ErrorAction SilentlyContinue |
    Remove-Event -ErrorAction SilentlyContinue
  foreach ($name in $environmentNames) {
    Restore-ProcessEnvironmentValue $name $previousEnvironment[$name]
  }
  $stopwatch.Stop()
}

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$fixtureScript = Join-Path $repoRoot "scripts\release\serve-m8-i6-blackhole-connect.ps1"
$probeDriverScript = Join-Path $repoRoot "scripts\release\probe-m8-i6-svn-anonymous.ps1"
$tempRoot = Join-Path $repoRoot "target\tests\m8-i6-blackhole-connect-fixture\$([Guid]::NewGuid().ToString('N'))"
$pwshPath = (Get-Command pwsh -ErrorAction Stop).Source

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

function Start-FixtureProcess([string]$ScriptPath, [object[]]$Arguments) {
  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $pwshPath
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
  foreach ($argument in @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath) + $Arguments) {
    $startInfo.ArgumentList.Add([string]$argument)
  }
  return [System.Diagnostics.Process]::Start($startInfo)
}

function Wait-ForState([System.Diagnostics.Process]$Process, [string]$StatePath, [scriptblock]$Predicate) {
  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  while ([DateTime]::UtcNow -lt $deadline) {
    if ($Process.HasExited) {
      throw "Fixture exited before the expected state: $($Process.StandardError.ReadToEnd())"
    }
    if ([System.IO.File]::Exists($StatePath)) {
      try {
        $state = [System.IO.File]::ReadAllText($StatePath) | ConvertFrom-Json
        if (& $Predicate $state) {
          return $state
        }
      }
      catch [System.Management.Automation.PSInvalidCastException] {
      }
      catch [System.ArgumentException] {
      }
    }
    Start-Sleep -Milliseconds 20
  }
  throw "Fixture state deadline expired for $StatePath."
}

function Complete-FixtureProcess(
  [System.Diagnostics.Process]$Process,
  [string]$StopBytes,
  [int]$ExpectedExitCode,
  [string]$ExpectedError = ""
) {
  $Process.StandardInput.Write($StopBytes)
  $Process.StandardInput.Close()
  if (-not $Process.WaitForExit(10000)) {
    $Process.Kill($true)
    throw "Fixture did not stop within the bounded test deadline."
  }
  $stdout = $Process.StandardOutput.ReadToEnd()
  $stderr = $Process.StandardError.ReadToEnd()
  Assert-Equal $ExpectedExitCode $Process.ExitCode "Fixture exit code should match; stderr was '$stderr'."
  Assert-Equal "" $stdout "Fixture must not emit stdout."
  if ($ExpectedError.Length -gt 0) {
    Assert-True $stderr.Contains($ExpectedError, [System.StringComparison]::Ordinal) "Fixture stderr should contain $ExpectedError; got '$stderr'."
  }
  return $stderr
}

function Invoke-FixtureFailure([string]$ScriptPath, [object[]]$Arguments, [string]$ExpectedError) {
  $process = Start-FixtureProcess $ScriptPath $Arguments
  $process.StandardInput.Close()
  if (-not $process.WaitForExit(15000)) {
    $process.Kill($true)
    throw "Invalid fixture invocation did not exit within the bounded test deadline."
  }
  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $process.StandardError.ReadToEnd()
  Assert-True ($process.ExitCode -ne 0) "Invalid fixture invocation should fail."
  Assert-Equal "" $stdout "Invalid fixture invocation must not emit stdout."
  Assert-True $stderr.Contains($ExpectedError, [System.StringComparison]::Ordinal) "Invalid fixture invocation should contain $ExpectedError; got '$stderr'."
}

function Assert-ReadyShape([object]$State, [int]$ExpectedPid) {
  Assert-Equal "subversionr.release.m8-i6-blackhole-connect-fixture.v1" $State.schema "Fixture schema should be exact."
  Assert-Equal "ready" $State.status "Fixture should publish ready status."
  Assert-Equal "True" ([string]$State.conditionalAcceptEnabled) "Conditional accept should be enabled and verified."
  Assert-True ($State.port -ge 1 -and $State.port -le 65535) "Fixture port should be bounded."
  Assert-Equal $ExpectedPid $State.pid "Fixture state should bind the child PID."
  Assert-Equal 0 $State.acceptInvocations "Fixture must never invoke accept."
  Assert-Equal 0 $State.acceptedConnections "Fixture must never accept a connection."
  Assert-Equal 5000 $State.bounds.preflightRowTimeoutMilliseconds "Preflight row timeout should be explicit."
  Assert-Equal 750 $State.bounds.preflightObservationMilliseconds "Preflight SYN_SENT observation should be explicit."
  Assert-Equal 5 $State.bounds.stopProtocolBytes "Stop protocol byte count should be explicit."
  Assert-Equal "schema,status,conditionalAcceptEnabled,port,pid,acceptInvocations,acceptedConnections,bounds" (($State.PSObject.Properties.Name) -join ",") "Fixture state fields should be exact."
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net;
using System.Runtime.InteropServices;

public static class SubversionRBlackholeTcpTableTest
{
    [DllImport("Iphlpapi.dll", SetLastError = true)]
    private static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool order, int family, int tableClass, uint reserved);

    public static int[] GetLocalPorts(int ownerPid, int remotePort, int state)
    {
        int size = 0;
        if (GetExtendedTcpTable(IntPtr.Zero, ref size, false, 2, 5, 0) != 122 || size < 4)
            throw new InvalidOperationException("TCP table size query failed.");
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try
        {
            if (GetExtendedTcpTable(buffer, ref size, false, 2, 5, 0) != 0)
                throw new InvalidOperationException("TCP table query failed.");
            int count = Marshal.ReadInt32(buffer);
            if (count < 0 || count > (size - 4) / 24)
                throw new InvalidOperationException("TCP table shape is invalid.");
            List<int> ports = new List<int>();
            long address = buffer.ToInt64() + 4;
            for (int index = 0; index < count; index++, address += 24)
            {
                IntPtr row = new IntPtr(address);
                uint localAddress = unchecked((uint)Marshal.ReadInt32(row, 4));
                uint localPort = unchecked((uint)Marshal.ReadInt32(row, 8));
                uint remoteAddress = unchecked((uint)Marshal.ReadInt32(row, 12));
                uint remotePortValue = unchecked((uint)Marshal.ReadInt32(row, 16));
                if (Marshal.ReadInt32(row, 20) == ownerPid && Marshal.ReadInt32(row, 0) == state &&
                    localAddress == 0x0100007fU && remoteAddress == 0x0100007fU && DecodePort(remotePortValue) == remotePort)
                    ports.Add(DecodePort(localPort));
            }
            return ports.ToArray();
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    private static int DecodePort(uint value)
    {
        return (ushort)IPAddress.NetworkToHostOrder(unchecked((short)(value & 0xffffU)));
    }
}
'@

$probeDriverSource = [System.IO.File]::ReadAllText($probeDriverScript)
$driverCSharpBlocks = [regex]::Matches(
  $probeDriverSource,
  "Add-Type -TypeDefinition @'\r?\n(?<code>.*?)\r?\n'@",
  [System.Text.RegularExpressions.RegexOptions]::Singleline
)
Assert-True ($driverCSharpBlocks.Count -ge 2) "Aggregate probe must retain the TCP observer C# block."
Add-Type -TypeDefinition $driverCSharpBlocks[1].Groups["code"].Value

[System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null
try {
  Assert-True ([System.IO.File]::Exists($fixtureScript)) "Blackhole-connect fixture script should exist."
  $source = [System.IO.File]::ReadAllText($fixtureScript)
  Assert-True ($source.IndexOf("setsockopt(listener.Handle, SolSocket, SoConditionalAccept", [System.StringComparison]::Ordinal) -lt $source.IndexOf("listener.Listen(1);", [System.StringComparison]::Ordinal)) "SO_CONDITIONAL_ACCEPT must be set before listen."
  Assert-True $source.Contains("IPAddress.Loopback", [System.StringComparison]::Ordinal) "Fixture should bind only loopback."
  Assert-True $source.Contains("GetExtendedTcpTable", [System.StringComparison]::Ordinal) "Preflight should inspect the owner-PID TCP table."
  Assert-True (-not $source.Contains("WSAAccept", [System.StringComparison]::Ordinal)) "Fixture must never call conditional or ordinary accept."
  Assert-True (-not $source.Contains(".Accept(", [System.StringComparison]::Ordinal)) "Fixture must never invoke a managed accept path."
  foreach ($forbidden in @("IPAddress.Any", "0.0.0.0", "New-NetFirewallRule", "Remove-NetFirewallRule", "http://", "https://")) {
    Assert-True (-not $source.Contains($forbidden, [System.StringComparison]::OrdinalIgnoreCase)) "Fixture must not contain fallback route '$forbidden'."
  }

  $positiveRoot = Join-Path $tempRoot "positive"
  [System.IO.Directory]::CreateDirectory($positiveRoot) | Out-Null
  $positiveStatePath = Join-Path $positiveRoot "state.json"
  $positive = Start-FixtureProcess $fixtureScript @("--state-path", $positiveStatePath)
  $client = $null
  $observer = $null
  try {
    $ready = Wait-ForState $positive $positiveStatePath { param($state) $state.status -ceq "ready" }
    Assert-ReadyShape $ready $positive.Id

    $observer = [SubversionRM8I6BlackholeTcpObserver]::new([int]$ready.port)
    $client = [System.Net.Sockets.TcpClient]::new()
    $connectTask = $client.ConnectAsync("127.0.0.1", [int]$ready.port)
    $synSentDeadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
      [int[]]$synSentPorts = [SubversionRBlackholeTcpTableTest]::GetLocalPorts($PID, [int]$ready.port, 3)
      [int[]]$establishedPorts = [SubversionRBlackholeTcpTableTest]::GetLocalPorts($PID, [int]$ready.port, 5)
      if ($connectTask.IsCompleted) { throw "Production ConnectAsync completed before SYN_SENT evidence was observed." }
      Start-Sleep -Milliseconds 10
    } until ($synSentPorts.Count -eq 1 -or [DateTime]::UtcNow -ge $synSentDeadline)
    Assert-Equal 1 $synSentPorts.Count "Production connection should expose exactly one owner-PID SYN_SENT row."
    Assert-Equal 0 $establishedPorts.Count "Production connection must never become ESTABLISHED."
    $observedLocalPort = $synSentPorts[0]
    $stableDeadline = [DateTime]::UtcNow.AddMilliseconds(300)
    while ([DateTime]::UtcNow -lt $stableDeadline) {
      [int[]]$synSentPorts = [SubversionRBlackholeTcpTableTest]::GetLocalPorts($PID, [int]$ready.port, 3)
      [int[]]$establishedPorts = [SubversionRBlackholeTcpTableTest]::GetLocalPorts($PID, [int]$ready.port, 5)
      Assert-Equal 1 $synSentPorts.Count "Production connection should retain one SYN_SENT row."
      Assert-Equal $observedLocalPort $synSentPorts[0] "Production connection should retain the same SYN_SENT TCB."
      Assert-Equal 0 $establishedPorts.Count "Production connection must not become ESTABLISHED."
      Assert-True (-not $connectTask.IsCompleted) "Production ConnectAsync should remain pending without any accept invocation."
      Start-Sleep -Milliseconds 25
    }

    $observer.BindWorker([uint32]$PID)
    $client.Dispose()
    $client = $null
    $cleanupDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while (
      [SubversionRM8I6TcpOwnerTable]::GetByRemotePort([int]$ready.port).Length -ne 0 -and
      [DateTime]::UtcNow -lt $cleanupDeadline
    ) {
      Start-Sleep -Milliseconds 10
    }
    $observation = $observer.Complete([uint32]$PID, $true)
    Assert-Equal 1 $observation.DistinctTcbAttempts "Pre-launch observer must retain the exact pre-bind TCB attempt."
    Assert-Equal 0 $observation.EstablishedTcbConnections "Pre-launch observer must retain zero established TCBs."
    Assert-Equal $observedLocalPort $observation.LocalPort "Pre-launch observer must bind the observed local ephemeral port."
    Assert-True ($observation.StableSynSentSamples -ge 3) "Pre-launch observer must retain stable SYN_SENT samples."
    Assert-True ($observation.StableSynSentMilliseconds -ge 25) "Pre-launch observer must retain the real stable SYN_SENT span."
    $observer.Dispose()
    $observer = $null

    Complete-FixtureProcess $positive "stop`n" 0 | Out-Null
    $stopped = [System.IO.File]::ReadAllText($positiveStatePath) | ConvertFrom-Json
    Assert-Equal "stopped" $stopped.status "Exact stop should atomically publish stopped status."
    Assert-Equal 0 $stopped.acceptInvocations "Stopped state should retain zero accept invocations."
    Assert-Equal 0 $stopped.acceptedConnections "Stopped state must record zero accepted connections."
  }
  finally {
    if ($null -ne $observer) { $observer.Dispose() }
    if ($null -ne $client) { $client.Dispose() }
    if (-not $positive.HasExited) { $positive.Kill($true) }
    $positive.Dispose()
  }

  $argumentRoot = Join-Path $tempRoot "arguments"
  [System.IO.Directory]::CreateDirectory($argumentRoot) | Out-Null
  $argumentCases = @(
    [pscustomobject]@{ arguments = [object[]]@() },
    [pscustomobject]@{ arguments = [object[]]@("--state-path", "relative.json") },
    [pscustomobject]@{ arguments = [object[]]@("--state-path", (Join-Path $argumentRoot "extra.json"), "--extra", "value") },
    [pscustomobject]@{ arguments = [object[]]@("--state-path", (Join-Path $argumentRoot "duplicate-a.json"), "--state-path", (Join-Path $argumentRoot "duplicate-b.json")) },
    [pscustomobject]@{ arguments = [object[]]@("--State-Path", (Join-Path $argumentRoot "wrong-case.json")) }
  )
  foreach ($case in $argumentCases) {
    Invoke-FixtureFailure $fixtureScript $case.arguments "SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_ARGUMENT_INVALID"
  }

  $existingState = Join-Path $argumentRoot "existing.json"
  [System.IO.File]::WriteAllText($existingState, "existing")
  Invoke-FixtureFailure $fixtureScript @("--state-path", $existingState) "SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_ARGUMENT_INVALID"
  $reservedState = Join-Path $argumentRoot "reserved.json"
  [System.IO.File]::WriteAllText("$reservedState.tmp", "existing")
  Invoke-FixtureFailure $fixtureScript @("--state-path", $reservedState) "SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_ARGUMENT_INVALID"

  $tamperRoot = Join-Path $tempRoot "tamper"
  [System.IO.Directory]::CreateDirectory($tamperRoot) | Out-Null
  $tamperStatePath = Join-Path $tamperRoot "state.json"
  $tamperProcess = Start-FixtureProcess $fixtureScript @("--state-path", $tamperStatePath)
  try {
    $null = Wait-ForState $tamperProcess $tamperStatePath { param($state) $state.status -ceq "ready" }
    [System.IO.File]::WriteAllText($tamperStatePath, '{"tampered":true}')
    Complete-FixtureProcess $tamperProcess "stop`n" 1 "SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_STATE_TAMPERED" | Out-Null
    Assert-Equal '{"tampered":true}' ([System.IO.File]::ReadAllText($tamperStatePath)) "Fixture must not overwrite a tampered artifact."
  }
  finally {
    if (-not $tamperProcess.HasExited) { $tamperProcess.Kill($true) }
    $tamperProcess.Dispose()
  }

  $stopRoot = Join-Path $tempRoot "invalid-stop"
  [System.IO.Directory]::CreateDirectory($stopRoot) | Out-Null
  $stopStatePath = Join-Path $stopRoot "state.json"
  $stopProcess = Start-FixtureProcess $fixtureScript @("--state-path", $stopStatePath)
  try {
    $null = Wait-ForState $stopProcess $stopStatePath { param($state) $state.status -ceq "ready" }
    Complete-FixtureProcess $stopProcess "stop`r`n" 1 "SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_STOP_INVALID" | Out-Null
    $unchanged = [System.IO.File]::ReadAllText($stopStatePath) | ConvertFrom-Json
    Assert-Equal "ready" $unchanged.status "Invalid stop bytes must not claim stopped status."
  }
  finally {
    if (-not $stopProcess.HasExited) { $stopProcess.Kill($true) }
    $stopProcess.Dispose()
  }

  $providerCaveatScript = Join-Path $tempRoot "provider-caveat.ps1"
  $providerCaveatSource = $source.Replace("if (connectTask.IsCompleted)", "if (connectTask != null)")
  Assert-True ($providerCaveatSource -cne $source) "Provider caveat test should modify the exact calibration decision."
  [System.IO.File]::WriteAllText($providerCaveatScript, $providerCaveatSource, [System.Text.UTF8Encoding]::new($false))
  $providerCaveatState = Join-Path $tempRoot "provider-caveat.json"
  Invoke-FixtureFailure $providerCaveatScript @("--state-path", $providerCaveatState) "SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_PROVIDER_CAVEAT"
  Assert-True (-not [System.IO.File]::Exists($providerCaveatState)) "Provider calibration caveats must fail before publishing a usable endpoint."

  Write-Host "M8 I6 blackhole-connect fixture tests passed."
}
finally {
  $resolvedTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
  $allowedRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\m8-i6-blackhole-connect-fixture"))
  Assert-True $resolvedTempRoot.StartsWith("$allowedRoot\", [System.StringComparison]::OrdinalIgnoreCase) "Test cleanup root must stay inside the dedicated target directory."
  Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$argumentError = "SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_ARGUMENT_INVALID"

try {
  if ($args.Count -ne 2 -or $args[0] -cne "--state-path") {
    throw $argumentError
  }

  [string]$statePath = $args[1]
  if ([string]::IsNullOrWhiteSpace($statePath) -or
      $statePath.IndexOfAny([char[]]@([char]0, "`r", "`n")) -ge 0 -or
      -not [System.IO.Path]::IsPathFullyQualified($statePath)) {
    throw $argumentError
  }
  $statePath = [System.IO.Path]::GetFullPath($statePath)
  $stateDirectory = [System.IO.Path]::GetDirectoryName($statePath)
  if ([string]::IsNullOrEmpty($stateDirectory) -or
      -not [System.IO.Directory]::Exists($stateDirectory) -or
      [System.IO.File]::Exists($statePath) -or
      [System.IO.Directory]::Exists($statePath) -or
      [System.IO.File]::Exists("$statePath.tmp") -or
      [System.IO.Directory]::Exists("$statePath.tmp")) {
    throw $argumentError
  }
  if (-not [System.OperatingSystem]::IsWindows()) {
    throw "SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_WINDOWS_REQUIRED"
  }

  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public static class SubversionRBlackholeConnectFixture
{
    private const int SolSocket = 0xffff;
    private const int SoConditionalAccept = 0x3002;
    private const int AddressFamilyInet = 2;
    private const int TcpTableOwnerPidAll = 5;
    private const int TcpStateEstablished = 5;
    private const int TcpStateSynSent = 3;
    private const int PreflightObservationMilliseconds = 750;
    private const int PreflightRowTimeoutMilliseconds = 5000;
    private const string Schema = "subversionr.release.m8-i6-blackhole-connect-fixture.v1";

    [DllImport("Ws2_32.dll", SetLastError = true)]
    private static extern int setsockopt(
        IntPtr socket,
        int level,
        int optionName,
        ref int optionValue,
        int optionLength);

    [DllImport("Ws2_32.dll", SetLastError = true)]
    private static extern int getsockopt(
        IntPtr socket,
        int level,
        int optionName,
        out int optionValue,
        ref int optionLength);

    [DllImport("Iphlpapi.dll", SetLastError = true)]
    private static extern uint GetExtendedTcpTable(
        IntPtr table,
        ref int size,
        bool order,
        int addressFamily,
        int tableClass,
        uint reserved);

    public static void Run(string statePath)
    {
        CalibrateProvider();

        using (ConditionalListener listener = new ConditionalListener())
        {
            StateArtifact state = new StateArtifact(statePath, listener.Port);
            state.Write("ready", true);
            ReadExactStopProtocol();
            state.RequireUnmodified();
            listener.DisposeListener();
            state.Write("stopped", false);
        }
    }

    private static void CalibrateProvider()
    {
        using (ConditionalListener calibration = new ConditionalListener())
        using (Socket client = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp))
        {
            Task connectTask = client.ConnectAsync(IPAddress.Loopback, calibration.Port);
            Stopwatch discovery = Stopwatch.StartNew();
            TcpRow? observed = null;
            while (discovery.ElapsedMilliseconds < PreflightRowTimeoutMilliseconds)
            {
                if (connectTask.IsCompleted)
                {
                    throw new FixtureException("SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_PROVIDER_CAVEAT");
                }
                List<TcpRow> rows = GetMatchingRows(Process.GetCurrentProcess().Id, calibration.Port);
                RequireNoEstablished(rows);
                List<TcpRow> synSent = rows.FindAll(row => row.State == TcpStateSynSent);
                if (synSent.Count == 1)
                {
                    observed = synSent[0];
                    break;
                }
                if (synSent.Count > 1)
                {
                    throw new FixtureException("SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_PROVIDER_CAVEAT");
                }
                Thread.Sleep(10);
            }
            if (!observed.HasValue)
            {
                throw new FixtureException("SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_CALIBRATION_TIMEOUT");
            }

            Stopwatch stable = Stopwatch.StartNew();
            while (stable.ElapsedMilliseconds < PreflightObservationMilliseconds)
            {
                if (connectTask.IsCompleted)
                {
                    throw new FixtureException("SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_PROVIDER_CAVEAT");
                }
                List<TcpRow> rows = GetMatchingRows(Process.GetCurrentProcess().Id, calibration.Port);
                RequireNoEstablished(rows);
                List<TcpRow> synSent = rows.FindAll(row => row.State == TcpStateSynSent);
                if (synSent.Count != 1 || synSent[0].LocalPort != observed.Value.LocalPort)
                {
                    throw new FixtureException("SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_PROVIDER_CAVEAT");
                }
                Thread.Sleep(25);
            }
            if (connectTask.IsCompleted)
            {
                throw new FixtureException("SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_PROVIDER_CAVEAT");
            }
        }
    }

    private static void RequireNoEstablished(List<TcpRow> rows)
    {
        if (rows.Exists(row => row.State == TcpStateEstablished))
        {
            throw new FixtureException("SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_PROVIDER_CAVEAT");
        }
    }

    private static List<TcpRow> GetMatchingRows(int ownerPid, int remotePort)
    {
        int size = 0;
        uint result = GetExtendedTcpTable(IntPtr.Zero, ref size, false, AddressFamilyInet, TcpTableOwnerPidAll, 0);
        if (result != 122 || size < sizeof(int))
        {
            throw new FixtureException("SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_TCP_TABLE_UNAVAILABLE");
        }

        IntPtr buffer = Marshal.AllocHGlobal(size);
        try
        {
            result = GetExtendedTcpTable(buffer, ref size, false, AddressFamilyInet, TcpTableOwnerPidAll, 0);
            if (result != 0)
            {
                throw new FixtureException("SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_TCP_TABLE_UNAVAILABLE");
            }
            int count = Marshal.ReadInt32(buffer);
            const int rowSize = 24;
            if (count < 0 || count > (size - sizeof(int)) / rowSize)
            {
                throw new FixtureException("SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_TCP_TABLE_INVALID");
            }
            List<TcpRow> matching = new List<TcpRow>();
            long rowAddress = buffer.ToInt64() + sizeof(int);
            for (int index = 0; index < count; index++, rowAddress += rowSize)
            {
                IntPtr row = new IntPtr(rowAddress);
                int state = Marshal.ReadInt32(row, 0);
                uint localAddress = unchecked((uint)Marshal.ReadInt32(row, 4));
                uint localPortValue = unchecked((uint)Marshal.ReadInt32(row, 8));
                uint remoteAddress = unchecked((uint)Marshal.ReadInt32(row, 12));
                uint remotePortValue = unchecked((uint)Marshal.ReadInt32(row, 16));
                int pid = Marshal.ReadInt32(row, 20);
                if (pid == ownerPid &&
                    IsLoopback(localAddress) &&
                    IsLoopback(remoteAddress) &&
                    DecodePort(remotePortValue) == remotePort)
                {
                    matching.Add(new TcpRow(state, DecodePort(localPortValue)));
                }
            }
            return matching;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    private static bool IsLoopback(uint address)
    {
        return address == 0x0100007fU;
    }

    private static int DecodePort(uint value)
    {
        return (ushort)IPAddress.NetworkToHostOrder(unchecked((short)(value & 0xffffU)));
    }

    private static void ReadExactStopProtocol()
    {
        string input = Console.In.ReadToEnd();
        if (!string.Equals(input, "stop\n", StringComparison.Ordinal))
        {
            throw new FixtureException("SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_STOP_INVALID");
        }
    }

    private struct TcpRow
    {
        public TcpRow(int state, int localPort)
        {
            State = state;
            LocalPort = localPort;
        }

        public int State;
        public int LocalPort;
    }

    private sealed class ConditionalListener : IDisposable
    {
        private readonly Socket listener;
        private bool listenerDisposed;

        public ConditionalListener()
        {
            listener = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            listener.ExclusiveAddressUse = true;

            int enabled = 1;
            if (setsockopt(listener.Handle, SolSocket, SoConditionalAccept, ref enabled, sizeof(int)) != 0)
            {
                throw new FixtureException("SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_CONDITIONAL_ACCEPT_UNAVAILABLE");
            }
            int observed;
            int observedSize = sizeof(int);
            if (getsockopt(listener.Handle, SolSocket, SoConditionalAccept, out observed, ref observedSize) != 0 ||
                observedSize != sizeof(int) || observed == 0)
            {
                throw new FixtureException("SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_CONDITIONAL_ACCEPT_UNAVAILABLE");
            }

            listener.Bind(new IPEndPoint(IPAddress.Loopback, 0));
            listener.Listen(1);
            IPEndPoint endpoint = listener.LocalEndPoint as IPEndPoint;
            if (endpoint == null || !IPAddress.Loopback.Equals(endpoint.Address) || endpoint.Port <= 0)
            {
                throw new FixtureException("SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_LISTEN_INVALID");
            }
            Port = endpoint.Port;
        }

        public int Port { get; private set; }

        public void DisposeListener()
        {
            if (!listenerDisposed)
            {
                listenerDisposed = true;
                listener.Dispose();
            }
        }

        public void Dispose()
        {
            DisposeListener();
        }
    }

    private sealed class StateArtifact
    {
        private readonly string path;
        private readonly string temporaryPath;
        private readonly int port;
        private byte[] expectedHash;

        public StateArtifact(string path, int port)
        {
            this.path = path;
            temporaryPath = path + ".tmp";
            this.port = port;
        }

        public void Write(string status, bool firstWrite)
        {
            if (!firstWrite)
            {
                RequireUnmodified();
            }
            string json = "{" +
                "\"schema\":\"" + Schema + "\"," +
                "\"status\":\"" + status + "\"," +
                "\"conditionalAcceptEnabled\":true," +
                "\"port\":" + port.ToString(System.Globalization.CultureInfo.InvariantCulture) + "," +
                "\"pid\":" + Process.GetCurrentProcess().Id.ToString(System.Globalization.CultureInfo.InvariantCulture) + "," +
                "\"acceptInvocations\":0," +
                "\"acceptedConnections\":0," +
                "\"bounds\":{" +
                    "\"preflightRowTimeoutMilliseconds\":" + PreflightRowTimeoutMilliseconds.ToString(System.Globalization.CultureInfo.InvariantCulture) + "," +
                    "\"preflightObservationMilliseconds\":" + PreflightObservationMilliseconds.ToString(System.Globalization.CultureInfo.InvariantCulture) + "," +
                    "\"stopProtocolBytes\":5" +
                "}}\n";
            byte[] bytes = new UTF8Encoding(false, true).GetBytes(json);

            using (FileStream output = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                output.Write(bytes, 0, bytes.Length);
                output.Flush(true);
            }
            if (firstWrite)
            {
                File.Move(temporaryPath, path);
            }
            else
            {
                File.Move(temporaryPath, path, true);
            }
            expectedHash = Hash(bytes);
        }

        public void RequireUnmodified()
        {
            if (expectedHash == null || !File.Exists(path) || File.Exists(temporaryPath))
            {
                throw new FixtureException("SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_STATE_TAMPERED");
            }
            byte[] actualHash = Hash(File.ReadAllBytes(path));
            if (!CryptographicOperations.FixedTimeEquals(expectedHash, actualHash))
            {
                throw new FixtureException("SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_STATE_TAMPERED");
            }
        }

        private static byte[] Hash(byte[] bytes)
        {
            using (SHA256 sha256 = SHA256.Create())
            {
                return sha256.ComputeHash(bytes);
            }
        }
    }

    private sealed class FixtureException : Exception
    {
        public FixtureException(string code) : base(code) { }
    }
}
'@

  [SubversionRBlackholeConnectFixture]::Run($statePath)
}
catch {
  $message = [string]$_.Exception.Message
  $match = [regex]::Match($message, "SUBVERSIONR_[A-Z0-9_]+")
  $code = if ($match.Success) { $match.Value } else { "SUBVERSIONR_M8_I6_BLACKHOLE_CONNECT_FAILED" }
  [Console]::Error.WriteLine($code)
  exit 1
}

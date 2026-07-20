[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string]$RepositoryUrl,
  [Parameter(Mandatory = $true)] [string]$UnrelatedRepositoryUrl,
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
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;

public static class SubversionRM8I6FileSecurity {
  [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  public static extern bool SetFileSecurity(
    string fileName,
    uint securityInformation,
    byte[] securityDescriptor
  );
}
'@

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class SubversionRM8I6ExactFileIdentity {
  private const uint FILE_SHARE_READ = 0x00000001;
  private const uint FILE_SHARE_WRITE = 0x00000002;
  private const uint FILE_SHARE_DELETE = 0x00000004;
  private const uint OPEN_EXISTING = 3;

  [StructLayout(LayoutKind.Sequential)]
  private struct FileTime {
    public uint Low;
    public uint High;
  }

  [StructLayout(LayoutKind.Sequential)]
  private struct ByHandleFileInformation {
    public uint FileAttributes;
    public FileTime CreationTime;
    public FileTime LastAccessTime;
    public FileTime LastWriteTime;
    public uint VolumeSerialNumber;
    public uint FileSizeHigh;
    public uint FileSizeLow;
    public uint NumberOfLinks;
    public uint FileIndexHigh;
    public uint FileIndexLow;
  }

  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern SafeFileHandle CreateFileW(
    string fileName,
    uint desiredAccess,
    uint shareMode,
    IntPtr securityAttributes,
    uint creationDisposition,
    uint flagsAndAttributes,
    IntPtr templateFile
  );

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool GetFileInformationByHandle(
    SafeFileHandle file,
    out ByHandleFileInformation information
  );

  public static string Get(string path) {
    if (String.IsNullOrWhiteSpace(path)) throw new ArgumentException("File identity path is required.", "path");
    using (SafeFileHandle file = CreateFileW(
      path,
      0,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      IntPtr.Zero,
      OPEN_EXISTING,
      0,
      IntPtr.Zero
    )) {
      if (file.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not open the exact file identity.");
      ByHandleFileInformation information;
      if (!GetFileInformationByHandle(file, out information)) {
        throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read the exact file identity.");
      }
      return String.Format(
        System.Globalization.CultureInfo.InvariantCulture,
        "{0:X8}:{1:X8}:{2:X8}",
        information.VolumeSerialNumber,
        information.FileIndexHigh,
        information.FileIndexLow
      );
    }
  }
}
'@

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

public sealed class SubversionRM8I6TcpOwnerRow {
  public uint State { get; private set; }
  public string LocalAddress { get; private set; }
  public int LocalPort { get; private set; }
  public string RemoteAddress { get; private set; }
  public int RemotePort { get; private set; }
  public uint ProcessId { get; private set; }
  public string TcbKey { get; private set; }

  internal SubversionRM8I6TcpOwnerRow(
    uint state,
    uint localAddress,
    int localPort,
    uint remoteAddress,
    int remotePort,
    uint processId
  ) {
    State = state;
    LocalAddress = FormatIpv4(localAddress);
    LocalPort = localPort;
    RemoteAddress = FormatIpv4(remoteAddress);
    RemotePort = remotePort;
    ProcessId = processId;
    TcbKey = processId + "|" + LocalAddress + ":" + localPort + "->" + RemoteAddress + ":" + remotePort;
  }

  private static string FormatIpv4(uint address) {
    return String.Format(
      "{0}.{1}.{2}.{3}",
      address & 0xffU,
      (address >> 8) & 0xffU,
      (address >> 16) & 0xffU,
      (address >> 24) & 0xffU
    );
  }
}

public static class SubversionRM8I6TcpOwnerTable {
  private const int AF_INET = 2;
  private const int TCP_TABLE_OWNER_PID_ALL = 5;
  private const int ERROR_INSUFFICIENT_BUFFER = 122;

  [DllImport("iphlpapi.dll", SetLastError = true)]
  private static extern uint GetExtendedTcpTable(
    IntPtr table,
    ref int size,
    bool order,
    int ipVersion,
    int tableClass,
    uint reserved
  );

  private static SubversionRM8I6TcpOwnerRow[] GetMatching(uint? processId, int remotePort) {
    if ((processId.HasValue && processId.Value == 0) || remotePort < 1 || remotePort > 65535) {
      throw new ArgumentOutOfRangeException();
    }
    int size = 0;
    uint first = GetExtendedTcpTable(IntPtr.Zero, ref size, false, AF_INET, TCP_TABLE_OWNER_PID_ALL, 0);
    if (first != ERROR_INSUFFICIENT_BUFFER || size < 4) {
      throw new Win32Exception((int)first, "GetExtendedTcpTable size query failed");
    }
    IntPtr buffer = Marshal.AllocHGlobal(size);
    try {
      uint result = GetExtendedTcpTable(buffer, ref size, false, AF_INET, TCP_TABLE_OWNER_PID_ALL, 0);
      if (result != 0) throw new Win32Exception((int)result, "GetExtendedTcpTable failed");
      int rows = Marshal.ReadInt32(buffer);
      List<SubversionRM8I6TcpOwnerRow> matching = new List<SubversionRM8I6TcpOwnerRow>();
      IntPtr cursor = IntPtr.Add(buffer, 4);
      for (int index = 0; index < rows; index += 1, cursor = IntPtr.Add(cursor, 24)) {
        uint observedState = unchecked((uint)Marshal.ReadInt32(cursor, 0));
        uint localAddress = unchecked((uint)Marshal.ReadInt32(cursor, 4));
        uint encodedLocalPort = unchecked((uint)Marshal.ReadInt32(cursor, 8));
        uint remoteAddress = unchecked((uint)Marshal.ReadInt32(cursor, 12));
        uint encodedRemotePort = unchecked((uint)Marshal.ReadInt32(cursor, 16));
        uint observedProcessId = unchecked((uint)Marshal.ReadInt32(cursor, 20));
        int observedLocalPort = (int)(((encodedLocalPort & 0x000000ffU) << 8) | ((encodedLocalPort & 0x0000ff00U) >> 8));
        int observedRemotePort = (int)(((encodedRemotePort & 0x000000ffU) << 8) | ((encodedRemotePort & 0x0000ff00U) >> 8));
        if ((!processId.HasValue || observedProcessId == processId.Value) && localAddress == 0x0100007fU && remoteAddress == 0x0100007fU && observedRemotePort == remotePort) {
          matching.Add(new SubversionRM8I6TcpOwnerRow(
            observedState,
            localAddress,
            observedLocalPort,
            remoteAddress,
            observedRemotePort,
            observedProcessId
          ));
        }
      }
      return matching.ToArray();
    }
    finally {
      Marshal.FreeHGlobal(buffer);
    }
  }

  public static SubversionRM8I6TcpOwnerRow[] Get(uint processId, int remotePort) {
    return GetMatching(processId, remotePort);
  }

  public static SubversionRM8I6TcpOwnerRow[] GetByRemotePort(int remotePort) {
    return GetMatching(null, remotePort);
  }

  public static int Count(uint processId, int remotePort, uint state) {
    int count = 0;
    foreach (SubversionRM8I6TcpOwnerRow row in Get(processId, remotePort)) {
      if (row.State == state) count += 1;
    }
    return count;
  }

  public static int CountAny(uint processId, int remotePort) {
    return Get(processId, remotePort).Length;
  }
}

public sealed class SubversionRM8I6BlackholeTcpObservation {
  public string LocalAddress { get; private set; }
  public int LocalPort { get; private set; }
  public string RemoteAddress { get; private set; }
  public int RemotePort { get; private set; }
  public int DistinctTcbAttempts { get; private set; }
  public int EstablishedTcbConnections { get; private set; }
  public int StableSynSentSamples { get; private set; }
  public long StableSynSentMilliseconds { get; private set; }
  public long ObservationMilliseconds { get; private set; }

  internal SubversionRM8I6BlackholeTcpObservation(
    string localAddress,
    int localPort,
    string remoteAddress,
    int remotePort,
    int distinctTcbAttempts,
    int establishedTcbConnections,
    int stableSynSentSamples,
    long stableSynSentMilliseconds,
    long observationMilliseconds
  ) {
    LocalAddress = localAddress;
    LocalPort = localPort;
    RemoteAddress = remoteAddress;
    RemotePort = remotePort;
    DistinctTcbAttempts = distinctTcbAttempts;
    EstablishedTcbConnections = establishedTcbConnections;
    StableSynSentSamples = stableSynSentSamples;
    StableSynSentMilliseconds = stableSynSentMilliseconds;
    ObservationMilliseconds = observationMilliseconds;
  }
}

public sealed class SubversionRM8I6BlackholeTcpObserver : IDisposable {
  private const uint SYN_SENT = 3;
  private const uint ESTABLISHED = 5;
  private readonly object gate = new object();
  private readonly int remotePort;
  private readonly Stopwatch clock;
  private readonly Thread thread;
  private readonly ManualResetEventSlim started = new ManualResetEventSlim(false);
  private readonly HashSet<string> attemptTcbs = new HashSet<string>(StringComparer.Ordinal);
  private readonly HashSet<string> establishedTcbs = new HashSet<string>(StringComparer.Ordinal);
  private readonly HashSet<uint> ownerProcessIds = new HashSet<uint>();
  private volatile bool stopRequested;
  private Exception failure;
  private bool workerBound;
  private uint boundWorkerProcessId;
  private string lockedTcbKey;
  private string lockedLocalAddress;
  private int lockedLocalPort;
  private string lockedRemoteAddress;
  private bool synSentRetired;
  private int stableSynSentSamples;
  private long firstSynSentMilliseconds = -1;
  private long lastSynSentMilliseconds = -1;
  private int latestRows;
  private bool disposed;

  public SubversionRM8I6BlackholeTcpObserver(int remotePort) {
    if (remotePort < 1 || remotePort > 65535) throw new ArgumentOutOfRangeException("remotePort");
    this.remotePort = remotePort;
    clock = Stopwatch.StartNew();
    thread = new Thread(Run);
    thread.IsBackground = true;
    thread.Name = "SubversionR M8 I6 blackhole TCP observer";
    thread.Start();
    if (!started.Wait(10000)) {
      stopRequested = true;
      thread.Join(10000);
      throw new TimeoutException("The blackhole TCP observer did not publish its pre-launch sampling barrier.");
    }
    lock (gate) { ThrowIfFailed(); }
  }

  public void BindWorker(uint workerProcessId) {
    if (workerProcessId == 0) throw new ArgumentOutOfRangeException("workerProcessId");
    lock (gate) {
      ThrowIfFailed();
      if (workerBound) throw new InvalidOperationException("The blackhole TCP observer worker is already bound.");
      foreach (uint observedProcessId in ownerProcessIds) {
        if (observedProcessId != workerProcessId) {
          throw new InvalidOperationException("A pre-bind TCP attempt was owned by a process other than the exact worker.");
        }
      }
      boundWorkerProcessId = workerProcessId;
      workerBound = true;
    }
  }

  public SubversionRM8I6BlackholeTcpObservation Complete(uint workerProcessId, bool probeExited) {
    if (!probeExited) throw new InvalidOperationException("The probe must exit before TCP observation completes.");
    StopThread();
    SubversionRM8I6TcpOwnerRow[] finalRows = SubversionRM8I6TcpOwnerTable.GetByRemotePort(remotePort);
    lock (gate) {
      ThrowIfFailed();
      if (!workerBound || boundWorkerProcessId != workerProcessId) {
        throw new InvalidOperationException("The blackhole TCP observer is not bound to the exact worker.");
      }
      ObserveRows(finalRows, clock.ElapsedMilliseconds);
      ThrowIfFailed();
      if (latestRows != 0) throw new InvalidOperationException("A TCP row remained after probe settlement.");
      if (lockedTcbKey == null || attemptTcbs.Count != 1) {
        throw new InvalidOperationException("The blackhole TCP observer did not see exactly one TCB attempt.");
      }
      if (establishedTcbs.Count != 0) {
        throw new InvalidOperationException("The blackhole TCP observer saw an established connection.");
      }
      if (stableSynSentSamples < 3 || lastSynSentMilliseconds - firstSynSentMilliseconds < 25) {
        throw new InvalidOperationException("The blackhole TCP observer did not see a stable SYN_SENT TCB.");
      }
      return new SubversionRM8I6BlackholeTcpObservation(
        lockedLocalAddress,
        lockedLocalPort,
        lockedRemoteAddress,
        remotePort,
        attemptTcbs.Count,
        establishedTcbs.Count,
        stableSynSentSamples,
        lastSynSentMilliseconds - firstSynSentMilliseconds,
        clock.ElapsedMilliseconds
      );
    }
  }

  private void Run() {
    try {
      while (!stopRequested) {
        SubversionRM8I6TcpOwnerRow[] rows = SubversionRM8I6TcpOwnerTable.GetByRemotePort(remotePort);
        lock (gate) {
          ObserveRows(rows, clock.ElapsedMilliseconds);
          started.Set();
          if (failure != null) return;
        }
        Thread.Sleep(2);
      }
    }
    catch (Exception error) {
      lock (gate) {
        if (failure == null) failure = error;
        started.Set();
      }
    }
  }

  private void ObserveRows(SubversionRM8I6TcpOwnerRow[] rows, long elapsedMilliseconds) {
    if (failure != null) return;
    if (rows.Length > 1) {
      failure = new InvalidOperationException("Multiple simultaneous TCP rows targeted the blackhole fixture.");
      return;
    }
    foreach (SubversionRM8I6TcpOwnerRow row in rows) {
      ownerProcessIds.Add(row.ProcessId);
      if (workerBound && row.ProcessId != boundWorkerProcessId) {
        failure = new InvalidOperationException("A TCP attempt was owned by a process other than the exact worker.");
        return;
      }
      attemptTcbs.Add(row.TcbKey);
      if (row.State == ESTABLISHED) establishedTcbs.Add(row.TcbKey);
      if (row.State != SYN_SENT) {
        failure = new InvalidOperationException("The blackhole TCP attempt reached a state other than SYN_SENT.");
        return;
      }
      if (lockedTcbKey == null) {
        lockedTcbKey = row.TcbKey;
        lockedLocalAddress = row.LocalAddress;
        lockedLocalPort = row.LocalPort;
        lockedRemoteAddress = row.RemoteAddress;
        firstSynSentMilliseconds = elapsedMilliseconds;
      }
      if (!String.Equals(row.TcbKey, lockedTcbKey, StringComparison.Ordinal)) {
        failure = new InvalidOperationException("The exact blackhole TCP TCB was replaced.");
        return;
      }
      if (synSentRetired) {
        failure = new InvalidOperationException("A TCP TCB appeared after the exact blackhole TCB retired.");
        return;
      }
      stableSynSentSamples += 1;
      lastSynSentMilliseconds = elapsedMilliseconds;
    }
    if (rows.Length == 0 && lockedTcbKey != null) synSentRetired = true;
    latestRows = rows.Length;
  }

  private void ThrowIfFailed() {
    if (failure != null) throw new InvalidOperationException("Blackhole TCP observation failed.", failure);
  }

  private void StopThread() {
    stopRequested = true;
    if (!thread.Join(10000)) throw new TimeoutException("The blackhole TCP observer did not stop.");
  }

  public void Dispose() {
    if (disposed) return;
    disposed = true;
    stopRequested = true;
    thread.Join(10000);
    started.Dispose();
  }
}
'@

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public sealed class SubversionRM8I6WorkerCrashBinding : IDisposable {
  internal readonly string ExpectedPath;
  internal readonly uint ParentPid;
  internal readonly long ParentCreationFileTime;
  internal readonly SafeProcessHandle ParentHandle;
  internal readonly uint WorkerPid;
  internal readonly long WorkerCreationFileTime;
  internal readonly SafeProcessHandle WorkerHandle;

  internal SubversionRM8I6WorkerCrashBinding(
    string expectedPath,
    uint parentPid,
    long parentCreationFileTime,
    SafeProcessHandle parentHandle,
    uint workerPid,
    long workerCreationFileTime,
    SafeProcessHandle workerHandle
  ) {
    ExpectedPath = expectedPath;
    ParentPid = parentPid;
    ParentCreationFileTime = parentCreationFileTime;
    ParentHandle = parentHandle;
    WorkerPid = workerPid;
    WorkerCreationFileTime = workerCreationFileTime;
    WorkerHandle = workerHandle;
  }

  public uint ParentProcessId { get { return ParentPid; } }
  public long ParentStartFileTime { get { return ParentCreationFileTime; } }
  public uint WorkerProcessId { get { return WorkerPid; } }
  public long WorkerStartFileTime { get { return WorkerCreationFileTime; } }

  public void Dispose() {
    WorkerHandle.Dispose();
    ParentHandle.Dispose();
  }
}

public static class SubversionRM8I6WorkerCrashNative {
  private const uint TH32CS_SNAPPROCESS = 0x00000002;
  private const uint PROCESS_TERMINATE = 0x0001;
  private const uint SYNCHRONIZE = 0x00100000;
  private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
  private const uint WAIT_OBJECT_0 = 0x00000000;
  private const uint WAIT_TIMEOUT = 0x00000102;
  private const uint WAIT_FAILED = 0xFFFFFFFF;
  private static readonly IntPtr InvalidHandleValue = new IntPtr(-1);

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  private struct PROCESSENTRY32W {
    public uint dwSize;
    public uint cntUsage;
    public uint th32ProcessID;
    public IntPtr th32DefaultHeapID;
    public uint th32ModuleID;
    public uint cntThreads;
    public uint th32ParentProcessID;
    public int pcPriClassBase;
    public uint dwFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
    public string szExeFile;
  }

  private sealed class Candidate : IDisposable {
    internal readonly uint ProcessId;
    internal readonly uint ParentProcessId;
    internal readonly long CreationFileTime;
    internal readonly string Path;
    internal readonly SafeProcessHandle Handle;

    internal Candidate(uint processId, uint parentProcessId, long creationFileTime, string path, SafeProcessHandle handle) {
      ProcessId = processId;
      ParentProcessId = parentProcessId;
      CreationFileTime = creationFileTime;
      Path = path;
      Handle = handle;
    }

    public void Dispose() { Handle.Dispose(); }
  }

  private sealed class ProcessLink {
    internal readonly uint ProcessId;
    internal readonly uint ParentProcessId;
    internal ProcessLink(uint processId, uint parentProcessId) {
      ProcessId = processId;
      ParentProcessId = parentProcessId;
    }
  }

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);

  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern bool Process32FirstW(IntPtr snapshot, ref PROCESSENTRY32W entry);

  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern bool Process32NextW(IntPtr snapshot, ref PROCESSENTRY32W entry);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool CloseHandle(IntPtr handle);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern SafeProcessHandle OpenProcess(uint desiredAccess, bool inheritHandle, uint processId);

  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern bool QueryFullProcessImageNameW(SafeProcessHandle process, uint flags, StringBuilder path, ref uint size);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool GetProcessTimes(
    SafeProcessHandle process,
    out long creationTime,
    out long exitTime,
    out long kernelTime,
    out long userTime
  );

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern uint GetProcessId(SafeProcessHandle process);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool TerminateProcess(SafeProcessHandle process, uint exitCode);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern uint WaitForSingleObject(SafeProcessHandle handle, uint milliseconds);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool GetExitCodeProcess(SafeProcessHandle process, out uint exitCode);

  public static int GetExactCandidateCount(string executablePath) {
    List<Candidate> candidates = EnumerateCandidates(executablePath);
    try { return candidates.Count; }
    finally { DisposeCandidates(candidates); }
  }

  public static int GetBoundDescendantCount(SubversionRM8I6WorkerCrashBinding binding) {
    if (binding == null) throw new ArgumentNullException("binding");
    List<ProcessLink> links = EnumerateProcessLinks();
    HashSet<uint> ancestors = new HashSet<uint>();
    ancestors.Add(binding.ParentPid);
    ancestors.Add(binding.WorkerPid);
    HashSet<uint> descendants = new HashSet<uint>();
    bool changed;
    do {
      changed = false;
      foreach (ProcessLink link in links) {
        if (ancestors.Contains(link.ParentProcessId) &&
            link.ProcessId != binding.ParentPid && link.ProcessId != binding.WorkerPid &&
            descendants.Add(link.ProcessId)) {
          ancestors.Add(link.ProcessId);
          changed = true;
        }
      }
    } while (changed);
    return descendants.Count;
  }

  public static SubversionRM8I6WorkerCrashBinding BindExactParentWorker(string executablePath) {
    string expectedPath = Canonicalize(executablePath);
    List<Candidate> candidates = EnumerateCandidates(expectedPath);
    try {
      if (candidates.Count != 2) {
        throw new InvalidOperationException("Worker-crash barrier must expose exactly two daemon-path candidates.");
      }
      Candidate parent = null;
      Candidate worker = null;
      foreach (Candidate possibleWorker in candidates) {
        foreach (Candidate possibleParent in candidates) {
          if (possibleWorker.ProcessId != possibleParent.ProcessId && possibleWorker.ParentProcessId == possibleParent.ProcessId) {
            if (parent != null || worker != null) {
              throw new InvalidOperationException("Worker-crash candidate ancestry was not unique.");
            }
            parent = possibleParent;
            worker = possibleWorker;
          }
        }
      }
      if (parent == null || worker == null || parent.ParentProcessId == worker.ProcessId) {
        throw new InvalidOperationException("Worker-crash candidate ancestry did not contain one unique parent-to-child edge.");
      }

      SafeProcessHandle retainedParent = OpenRequired(parent.ProcessId, PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, "parent");
      SafeProcessHandle retainedWorker = null;
      try {
        retainedWorker = OpenRequired(worker.ProcessId, PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE | PROCESS_TERMINATE, "worker");
        RequireIdentity(retainedParent, parent.ProcessId, expectedPath, parent.CreationFileTime, "parent");
        RequireIdentity(retainedWorker, worker.ProcessId, expectedPath, worker.CreationFileTime, "worker");
        return new SubversionRM8I6WorkerCrashBinding(
          expectedPath,
          parent.ProcessId,
          parent.CreationFileTime,
          retainedParent,
          worker.ProcessId,
          worker.CreationFileTime,
          retainedWorker
        );
      } catch {
        if (retainedWorker != null) retainedWorker.Dispose();
        retainedParent.Dispose();
        throw;
      }
    } finally {
      DisposeCandidates(candidates);
    }
  }

  public static uint TerminateBoundWorker(SubversionRM8I6WorkerCrashBinding binding, uint exitCode, uint waitMilliseconds) {
    if (binding == null) throw new ArgumentNullException("binding");
    List<Candidate> candidates = EnumerateCandidates(binding.ExpectedPath);
    try {
      if (candidates.Count != 2) {
        throw new InvalidOperationException("Worker-crash candidate set changed before termination.");
      }
      Candidate parent = FindExact(candidates, binding.ParentPid, binding.ParentCreationFileTime, binding.ExpectedPath, "parent");
      Candidate worker = FindExact(candidates, binding.WorkerPid, binding.WorkerCreationFileTime, binding.ExpectedPath, "worker");
      if (worker.ParentProcessId != parent.ProcessId) {
        throw new InvalidOperationException("Worker-crash parent-to-child relationship changed before termination.");
      }
      RequireIdentity(binding.ParentHandle, binding.ParentPid, binding.ExpectedPath, binding.ParentCreationFileTime, "retained parent");
      RequireIdentity(binding.WorkerHandle, binding.WorkerPid, binding.ExpectedPath, binding.WorkerCreationFileTime, "retained worker");
      RequireWait(binding.ParentHandle, WAIT_TIMEOUT, "parent must be alive before worker termination");
      RequireWait(binding.WorkerHandle, WAIT_TIMEOUT, "worker must be alive before worker termination");
      if (!TerminateProcess(binding.WorkerHandle, exitCode)) ThrowWin32("TerminateProcess(worker) failed");
      RequireWait(binding.WorkerHandle, WAIT_OBJECT_0, waitMilliseconds, "worker termination did not settle");
      uint observedExitCode;
      if (!GetExitCodeProcess(binding.WorkerHandle, out observedExitCode)) ThrowWin32("GetExitCodeProcess(worker) failed");
      if (observedExitCode != exitCode) {
        throw new InvalidOperationException("Worker termination exit code was not exact.");
      }
      RequireWait(binding.ParentHandle, WAIT_TIMEOUT, "parent exited during worker termination");
      return observedExitCode;
    } finally {
      DisposeCandidates(candidates);
    }
  }

  private static Candidate FindExact(List<Candidate> candidates, uint pid, long creationFileTime, string expectedPath, string context) {
    Candidate match = null;
    foreach (Candidate candidate in candidates) {
      if (candidate.ProcessId == pid && candidate.CreationFileTime == creationFileTime && SamePath(candidate.Path, expectedPath)) {
        if (match != null) throw new InvalidOperationException("Duplicate exact " + context + " candidate identity.");
        match = candidate;
      }
    }
    if (match == null) throw new InvalidOperationException("Bound " + context + " identity changed before termination.");
    return match;
  }

  private static List<Candidate> EnumerateCandidates(string executablePath) {
    string expectedPath = Canonicalize(executablePath);
    string expectedName = Path.GetFileName(expectedPath);
    IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == InvalidHandleValue) ThrowWin32("CreateToolhelp32Snapshot failed");
    List<Candidate> candidates = new List<Candidate>();
    try {
      PROCESSENTRY32W entry = new PROCESSENTRY32W();
      entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
      if (!Process32FirstW(snapshot, ref entry)) ThrowWin32("Process32FirstW failed");
      do {
        if (string.Equals(entry.szExeFile, expectedName, StringComparison.OrdinalIgnoreCase)) {
          SafeProcessHandle handle = OpenRequired(entry.th32ProcessID, PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, "candidate");
          try {
            string observedPath = QueryPath(handle);
            if (SamePath(observedPath, expectedPath)) {
              candidates.Add(new Candidate(
                entry.th32ProcessID,
                entry.th32ParentProcessID,
                QueryCreationFileTime(handle),
                observedPath,
                handle
              ));
              handle = null;
            }
          } finally {
            if (handle != null) handle.Dispose();
          }
        }
        entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
      } while (Process32NextW(snapshot, ref entry));
      int error = Marshal.GetLastWin32Error();
      if (error != 18) throw new Win32Exception(error, "Process32NextW failed");
      return candidates;
    } catch {
      DisposeCandidates(candidates);
      throw;
    } finally {
      if (!CloseHandle(snapshot)) ThrowWin32("CloseHandle(process snapshot) failed");
    }
  }

  private static List<ProcessLink> EnumerateProcessLinks() {
    IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == InvalidHandleValue) ThrowWin32("CreateToolhelp32Snapshot failed");
    try {
      List<ProcessLink> links = new List<ProcessLink>();
      PROCESSENTRY32W entry = new PROCESSENTRY32W();
      entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
      if (!Process32FirstW(snapshot, ref entry)) ThrowWin32("Process32FirstW failed");
      do {
        if (entry.th32ProcessID != 0) links.Add(new ProcessLink(entry.th32ProcessID, entry.th32ParentProcessID));
        entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
      } while (Process32NextW(snapshot, ref entry));
      int error = Marshal.GetLastWin32Error();
      if (error != 18) throw new Win32Exception(error, "Process32NextW failed");
      return links;
    } finally {
      if (!CloseHandle(snapshot)) ThrowWin32("CloseHandle(process snapshot) failed");
    }
  }

  private static SafeProcessHandle OpenRequired(uint pid, uint access, string context) {
    SafeProcessHandle handle = OpenProcess(access, false, pid);
    if (handle == null || handle.IsInvalid) {
      if (handle != null) handle.Dispose();
      ThrowWin32("OpenProcess(" + context + ") failed");
    }
    return handle;
  }

  private static void RequireIdentity(SafeProcessHandle handle, uint pid, string path, long creationFileTime, string context) {
    uint observedPid = GetProcessId(handle);
    if (observedPid == 0) ThrowWin32("GetProcessId(" + context + ") failed");
    if (observedPid != pid || !SamePath(QueryPath(handle), path) || QueryCreationFileTime(handle) != creationFileTime) {
      throw new InvalidOperationException("Bound " + context + " process identity changed.");
    }
  }

  private static string QueryPath(SafeProcessHandle handle) {
    StringBuilder value = new StringBuilder(32768);
    uint length = (uint)value.Capacity;
    if (!QueryFullProcessImageNameW(handle, 0, value, ref length)) ThrowWin32("QueryFullProcessImageNameW failed");
    if (length == 0 || length >= value.Capacity) throw new InvalidOperationException("Process image path was invalid.");
    return Canonicalize(value.ToString());
  }

  private static long QueryCreationFileTime(SafeProcessHandle handle) {
    long creation;
    long exit;
    long kernel;
    long user;
    if (!GetProcessTimes(handle, out creation, out exit, out kernel, out user)) ThrowWin32("GetProcessTimes failed");
    if (creation <= 0) throw new InvalidOperationException("Process creation FILETIME was invalid.");
    return creation;
  }

  private static void RequireWait(SafeProcessHandle handle, uint expected, string context) {
    RequireWait(handle, expected, 0, context);
  }

  private static void RequireWait(SafeProcessHandle handle, uint expected, uint milliseconds, string context) {
    uint observed = WaitForSingleObject(handle, milliseconds);
    if (observed == WAIT_FAILED) ThrowWin32("WaitForSingleObject failed");
    if (observed != expected) throw new InvalidOperationException(context + ".");
  }

  private static string Canonicalize(string value) {
    if (string.IsNullOrWhiteSpace(value) || !Path.IsPathRooted(value)) {
      throw new ArgumentException("Executable path must be absolute.", "value");
    }
    return Path.GetFullPath(value);
  }

  private static bool SamePath(string left, string right) {
    return string.Equals(Canonicalize(left), Canonicalize(right), StringComparison.OrdinalIgnoreCase);
  }

  private static void DisposeCandidates(List<Candidate> candidates) {
    foreach (Candidate candidate in candidates) candidate.Dispose();
  }

  private static void ThrowWin32(string message) {
    throw new Win32Exception(Marshal.GetLastWin32Error(), message);
  }
}
'@

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$packagedProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-vscode-packaged-native.mjs"))
$installedHarnessPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "test-vscode-installed-extension-host.ps1"))
$installedI6ProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-installed-vsix.ps1"))
$installedStressProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-installed-stress.ps1"))
$installedNegativeProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-installed-negative.ps1"))
$packagedAuthzDeniedProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-packaged-authz-denied.mjs"))
$installedAuthzDeniedProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-installed-authz-denied.ps1"))
$packagedStalledReadProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-packaged-stalled-read.mjs"))
$installedStalledReadProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-installed-stalled-read.ps1"))
$packagedDeadlineProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-packaged-deadline.mjs"))
$installedDeadlineProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-installed-deadline.ps1"))
$packagedCancellationProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-packaged-cancellation.mjs"))
$installedCancellationProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-installed-cancellation.ps1"))
$packagedTrustRevokedProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-packaged-trust-revoked.mjs"))
$installedTrustRevokedProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-installed-trust-revoked.ps1"))
$packagedRecoveryBlockedProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-packaged-recovery-blocked.mjs"))
$installedRecoveryBlockedProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-installed-recovery-blocked.ps1"))
$packagedRecoverySafeProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-packaged-recovery-safe.mjs"))
$installedRecoverySafeProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-installed-recovery-safe.ps1"))
$packagedRecoveryIndeterminateProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-packaged-recovery-indeterminate.mjs"))
$installedRecoveryIndeterminateProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-installed-recovery-indeterminate.ps1"))
$packagedRedactionProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-packaged-redaction.mjs"))
$installedRedactionProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-installed-redaction.ps1"))
$packagedWorkerCrashProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-packaged-worker-crash.mjs"))
$installedWorkerCrashProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-installed-worker-crash.ps1"))
$packagedBlackholeConnectProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-packaged-blackholeConnect.mjs"))
$installedBlackholeConnectProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-installed-blackholeConnect.ps1"))
$packagedDaemonDisconnectProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-packaged-daemon-disconnect.mjs"))
$installedDaemonDisconnectProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-installed-daemon-disconnect.ps1"))
$installedLocalEventProbePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "probe-m8-i6-installed-local-event-zero-network.ps1"))
$countingProxyPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "serve-m8-i6-counting-proxy.mjs"))
$faultFixturePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "serve-m8-i6-ra-svn-fault-fixture.mjs"))
$blackholeConnectFixturePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "serve-m8-i6-blackhole-connect.ps1"))
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

function Get-TextSha256([string]$Value) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return [Convert]::ToHexString($sha.ComputeHash($bytes)).ToLowerInvariant()
  }
  finally {
    $sha.Dispose()
  }
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

function Start-WorkerCrashProbeProcess(
  [string]$FilePath,
  [string[]]$Arguments,
  [hashtable]$Environment = @{}
) {
  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FilePath
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
  foreach ($entry in $Environment.GetEnumerator()) {
    $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
  }
  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  try {
    Assert-True $process.Start() "Failed to start the controlled worker-crash probe process."
    return [pscustomobject]@{
      Process = $process
      ProcessId = [long]$process.Id
      StdoutTask = $process.StandardOutput.ReadToEndAsync()
      StderrTask = $process.StandardError.ReadToEndAsync()
    }
  }
  catch {
    $process.Dispose()
    throw
  }
}

function Complete-WorkerCrashProbeProcess([object]$Started, [int]$TimeoutSeconds, [string]$Context) {
  $process = [System.Diagnostics.Process]$Started.Process
  try {
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      $process.Kill($true)
      $process.WaitForExit()
      throw "$Context probe exceeded its absolute deadline."
    }
    $stdout = $Started.StdoutTask.GetAwaiter().GetResult()
    $stderr = $Started.StderrTask.GetAwaiter().GetResult()
    Assert-True ($stdout.Length -le 65536) "$Context probe stdout exceeded 65536 bytes."
    Assert-True ($stderr.Length -le 32768) "$Context probe stderr exceeded 32768 bytes."
    return [pscustomobject]@{
      ProcessId = [long]$Started.ProcessId
      ExitCode = [int]$process.ExitCode
      Stdout = [string]$stdout
      Stderr = [string]$stderr
    }
  }
  finally {
    if (-not $process.HasExited) {
      $process.Kill($true)
      $process.WaitForExit()
    }
    $process.Dispose()
  }
}

function Start-BlackholeConnectFixture([string]$PowerShellPath, [string]$ScriptPath, [string]$StatePath) {
  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $PowerShellPath
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  foreach ($argument in @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath, "--state-path", $StatePath)) {
    $startInfo.ArgumentList.Add($argument)
  }
  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  try {
    Assert-True $process.Start() "Failed to start the loopback blackhole-connect fixture."
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
    do {
      Assert-True (-not $process.HasExited) "The loopback blackhole-connect fixture exited before publishing ready state."
      if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        try {
          $state = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json -Depth 8
          Assert-ExactProperties $state @("schema", "status", "conditionalAcceptEnabled", "port", "pid", "acceptInvocations", "acceptedConnections", "bounds") "blackhole-connect fixture state"
          Assert-ExactProperties $state.bounds @("preflightRowTimeoutMilliseconds", "preflightObservationMilliseconds", "stopProtocolBytes") "blackhole-connect fixture bounds"
          if (
            [string]$state.schema -ceq "subversionr.release.m8-i6-blackhole-connect-fixture.v1" -and
            [string]$state.status -ceq "ready" -and $state.conditionalAcceptEnabled -eq $true -and
            [int]$state.port -ge 1 -and [int]$state.port -le 65535 -and [int]$state.pid -eq $process.Id -and
            [int]$state.acceptInvocations -eq 0 -and [int]$state.acceptedConnections -eq 0 -and
            [int]$state.bounds.preflightObservationMilliseconds -eq 750 -and [int]$state.bounds.stopProtocolBytes -eq 5
          ) {
            return [pscustomobject]@{ Process = $process; State = $state; StdoutTask = $stdoutTask; StderrTask = $stderrTask }
          }
          throw "The loopback blackhole-connect fixture published an invalid ready state."
        }
        catch [System.Management.Automation.RuntimeException] {
          if ([DateTimeOffset]::UtcNow -ge $deadline) { throw }
        }
      }
      Start-Sleep -Milliseconds 10
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "The loopback blackhole-connect fixture did not publish ready state before its deadline."
  }
  catch {
    if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
    $process.Dispose()
    throw
  }
}

function Stop-BlackholeConnectFixture([object]$Fixture, [string]$StatePath) {
  $process = [System.Diagnostics.Process]$Fixture.Process
  try {
    Assert-True (-not $process.HasExited) "The loopback blackhole-connect fixture exited before the exact stop protocol."
    $process.StandardInput.Write("stop`n")
    $process.StandardInput.Close()
    Assert-True ($process.WaitForExit(30000)) "The loopback blackhole-connect fixture did not stop before its deadline."
    $stdout = $Fixture.StdoutTask.GetAwaiter().GetResult()
    $stderr = $Fixture.StderrTask.GetAwaiter().GetResult()
    Assert-True ($process.ExitCode -eq 0 -and $stdout.Length -eq 0 -and $stderr.Length -eq 0) "The loopback blackhole-connect fixture did not stop cleanly."
    $state = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json -Depth 8
    Assert-True (
      [string]$state.status -ceq "stopped" -and $state.conditionalAcceptEnabled -eq $true -and
      [int]$state.pid -eq $process.Id -and [int]$state.acceptInvocations -eq 0 -and [int]$state.acceptedConnections -eq 0
    ) "The loopback blackhole-connect fixture final state was invalid."
    Assert-True (-not (Test-Path -LiteralPath "$StatePath.tmp")) "The loopback blackhole-connect fixture left a state temporary file."
    return $state
  }
  finally {
    if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
    $process.Dispose()
  }
}

function Complete-BlackholeConnectObservation(
  [SubversionRM8I6BlackholeTcpObserver]$Observer,
  [SubversionRM8I6WorkerCrashBinding]$Binding,
  [bool]$ProbeExited,
  [string]$Context
) {
  Assert-True $ProbeExited "$Context probe must exit before TCP observation completes."
  $result = $Observer.Complete([uint32]$Binding.WorkerProcessId, $ProbeExited)
  return [pscustomobject]@{
    provider = "GetExtendedTcpTable/TCP_TABLE_OWNER_PID_ALL"
    workerProcessBound = $true
    observationStartedBeforeProbeLaunch = $true
    localAddress = [string]$result.LocalAddress
    localPort = [int]$result.LocalPort
    remoteAddress = [string]$result.RemoteAddress
    remotePort = [int]$result.RemotePort
    distinctTcbAttempts = [int]$result.DistinctTcbAttempts
    establishedTcbConnections = [int]$result.EstablishedTcbConnections
    stableSynSentSamples = [int]$result.StableSynSentSamples
    stableSynSentMilliseconds = [int64]$result.StableSynSentMilliseconds
    observationMilliseconds = [int64]$result.ObservationMilliseconds
    observationCompletedAfterProbeExit = $true
    synSentRows = 1
    establishedRows = 0
    finalRows = 0
  }
}

function Wait-WorkerCrashGreetingBarrier(
  [string]$FixtureStatePath,
  [int]$ExpectedPort,
  [System.Diagnostics.Process]$ProbeProcess,
  [string]$Context
) {
  $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
  do {
    Assert-True (-not $ProbeProcess.HasExited) "$Context probe exited before the greeting barrier."
    $state = $null
    try {
      $state = Get-Content -Raw -LiteralPath $FixtureStatePath | ConvertFrom-Json -Depth 16
    }
    catch {
      $state = $null
    }
    if ($null -ne $state) {
      $actualProperties = @($state.PSObject.Properties.Name | Sort-Object)
      $expectedProperties = @(
        "schema", "pid", "port", "suppliedAuthorityPort", "scenario", "connections",
        "suppliedAuthorityConnections", "greetingSent", "clientResponseReceived",
        "authRequestSent", "reposInfoSent", "commandsReceived", "followupContacts", "status"
      ) | Sort-Object
      Assert-True (($actualProperties -join ",") -ceq ($expectedProperties -join ",")) "$Context fixture state shape was invalid."
      Assert-True (
        [string]$state.schema -ceq "subversionr.release.m8-i6-ra-svn-fault-fixture.v1" -and
        [string]$state.status -ceq "ready" -and [string]$state.scenario -ceq "greeting-stall" -and
        [int]$state.port -eq $ExpectedPort -and [int]$state.suppliedAuthorityPort -eq 0 -and
        [int]$state.connections -ge 0 -and [int]$state.greetingSent -ge 0 -and
        [int]$state.clientResponseReceived -ge 0 -and [int]$state.authRequestSent -eq 0 -and
        [int]$state.reposInfoSent -eq 0 -and [int]$state.commandsReceived -eq 0 -and
        [int]$state.followupContacts -eq 0 -and [int]$state.suppliedAuthorityConnections -eq 0
      ) "$Context fixture state violated the greeting-stall contract."
      if (
        [int]$state.connections -eq 1 -and [int]$state.greetingSent -eq 1 -and
        [int]$state.clientResponseReceived -eq 1
      ) {
        return $state
      }
      Assert-True (
        [int]$state.connections -le 1 -and [int]$state.greetingSent -le 1 -and
        [int]$state.clientResponseReceived -le 1
      ) "$Context exceeded the exact greeting barrier before worker termination."
    }
    Start-Sleep -Milliseconds 10
  } while ([DateTimeOffset]::UtcNow -lt $deadline)
  throw "$Context did not reach the exact greeting barrier before its deadline."
}

function Assert-WorkerCrashCandidateCount([string]$ExecutablePath, [int]$ExpectedCount, [string]$Context) {
  $count = [SubversionRM8I6WorkerCrashNative]::GetExactCandidateCount($ExecutablePath)
  Assert-True ($count -eq $ExpectedCount) "$Context expected exactly $ExpectedCount daemon-path candidates, observed $count."
}

function Wait-WorkerCrashCandidateCount(
  [string]$ExecutablePath,
  [int]$ExpectedCount,
  [int]$TimeoutMilliseconds,
  [string]$Context
) {
  $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
  do {
    $count = [SubversionRM8I6WorkerCrashNative]::GetExactCandidateCount($ExecutablePath)
    if ($count -eq $ExpectedCount) { return }
    if ([DateTimeOffset]::UtcNow -ge $deadline) {
      throw "$Context expected exactly $ExpectedCount daemon-path candidates, observed $count."
    }
    Start-Sleep -Milliseconds 25
  } while ($true)
}

function Get-ExactFileSecurityDescriptor([string]$Path, [string]$Context) {
  $resolved = Resolve-RequiredFile $Path "$Context file"
  $security = Get-Acl -LiteralPath $resolved -ErrorAction Stop
  $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  Assert-True ($null -ne $currentIdentity.User) "$Context current Windows identity did not expose a SID."
  Assert-True ($null -ne $security.Owner) "$Context file owner was missing."
  $ownerSid = [System.Security.Principal.SecurityIdentifier]$security.GetOwner(
    [System.Security.Principal.SecurityIdentifier]
  )
  Assert-True ($ownerSid.Equals($currentIdentity.User)) "$Context fixture file must be owned by the current Windows identity."
  $binary = $security.GetSecurityDescriptorBinaryForm()
  Assert-True ($binary.Length -gt 0 -and $binary.Length -le 65536) "$Context security descriptor was invalid."
  return [pscustomobject]@{
    path = $resolved
    ownerSid = $ownerSid.Value
    sddl = $security.Sddl
    binaryBase64 = [Convert]::ToBase64String($binary)
  }
}

function Set-ExactCurrentUserReadDeny([object]$Descriptor, [string]$Context) {
  $security = Get-Acl -LiteralPath ([string]$Descriptor.path) -ErrorAction Stop
  Assert-True ([string]$security.Sddl -ceq [string]$Descriptor.sddl) "$Context file security changed before fault injection."
  $sid = [System.Security.Principal.SecurityIdentifier]::new([string]$Descriptor.ownerSid)
  $rights = `
    [System.Security.AccessControl.FileSystemRights]::ReadData -bor `
    [System.Security.AccessControl.FileSystemRights]::ReadAttributes -bor `
    [System.Security.AccessControl.FileSystemRights]::ReadExtendedAttributes
  $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
    $sid,
    $rights,
    [System.Security.AccessControl.AccessControlType]::Deny
  )
  $security.AddAccessRule($rule) | Out-Null
  Set-Acl -LiteralPath ([string]$Descriptor.path) -AclObject $security -ErrorAction Stop
  $readDenied = $false
  try {
    $stream = [System.IO.File]::OpenRead([string]$Descriptor.path)
    $stream.Dispose()
  }
  catch [System.UnauthorizedAccessException] {
    $readDenied = $true
  }
  Assert-True $readDenied "$Context did not deny a fresh working-copy database read."
}

function Restore-ExactFileDacl([object]$Descriptor, [string]$Context) {
  $binary = [Convert]::FromBase64String([string]$Descriptor.binaryBase64)
  $DaclSecurityInformation = [uint32]4
  $restored = [SubversionRM8I6FileSecurity]::SetFileSecurity(
    [string]$Descriptor.path,
    $DaclSecurityInformation,
    $binary
  )
  if (-not $restored) {
    $nativeError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "$Context failed to restore the exact working-copy database DACL (Win32 $nativeError)."
  }
  $security = Get-Acl -LiteralPath ([string]$Descriptor.path) -ErrorAction Stop
  Assert-True (
    [Convert]::ToBase64String($security.GetSecurityDescriptorBinaryForm()) -ceq [string]$Descriptor.binaryBase64
  ) "$Context working-copy database security descriptor was not restored byte-for-byte."
  Assert-True ([string]$security.Sddl -ceq [string]$Descriptor.sddl) "$Context working-copy database SDDL was not restored exactly."
  $stream = [System.IO.File]::OpenRead([string]$Descriptor.path)
  try {
    Assert-True ($stream.Length -gt 0) "$Context restored working-copy database was empty."
  }
  finally {
    $stream.Dispose()
  }
  return [pscustomobject]@{
    securityDescriptorSha256 = Get-TextSha256 ([string]$Descriptor.binaryBase64)
    currentUserSidSha256 = Get-TextSha256 ([string]$Descriptor.ownerSid)
    readFaultObserved = $true
    daclRestoredExactly = $true
  }
}

function Wait-CommandBarrier([string]$FixtureStatePath, [int]$ExpectedPort, [System.Diagnostics.Process]$Process, [string]$Context) {
  $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
  do {
    Assert-True (-not $Process.HasExited) "$Context probe exited before the command barrier."
    try {
      $state = Get-Content -Raw -LiteralPath $FixtureStatePath | ConvertFrom-Json -Depth 16
      if (
        [int]$state.port -eq $ExpectedPort -and [string]$state.scenario -ceq "command-stall" -and
        [int]$state.connections -eq 1 -and [int]$state.greetingSent -eq 1 -and
        [int]$state.clientResponseReceived -eq 1 -and [int]$state.authRequestSent -eq 1 -and
        [int]$state.reposInfoSent -eq 1 -and [int]$state.commandsReceived -eq 1 -and
        [int]$state.followupContacts -eq 0 -and [int]$state.suppliedAuthorityConnections -eq 0
      ) {
        return
      }
    }
    catch {
      # The fixture publishes with an atomic replacement; retry only malformed/intermediate reads inside the deadline.
    }
    Start-Sleep -Milliseconds 10
  } while ([DateTimeOffset]::UtcNow -lt $deadline)
  throw "$Context did not reach the exact command barrier before its deadline."
}

function Invoke-BoundedProcessWithWorkingCopyReadFault(
  [string]$FilePath,
  [string[]]$Arguments,
  [int]$TimeoutSeconds,
  [hashtable]$Environment,
  [string]$FixtureStatePath,
  [int]$ExpectedPort,
  [string]$WorkingCopyDatabasePath,
  [string]$Context
) {
  $descriptor = Get-ExactFileSecurityDescriptor $WorkingCopyDatabasePath $Context
  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FilePath
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
  foreach ($entry in $Environment.GetEnumerator()) {
    $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
  }
  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  $faultApplied = $false
  $processStarted = $false
  try {
    Assert-True $process.Start() "Failed to start the $Context probe process."
    $processStarted = $true
    $processId = $process.Id
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    Wait-CommandBarrier $FixtureStatePath $ExpectedPort $process $Context
    $faultApplied = $true
    Set-ExactCurrentUserReadDeny $descriptor $Context
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      $process.Kill($true)
      $process.WaitForExit()
      throw "$Context probe exceeded its absolute deadline."
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    Assert-True ($stdout.Length -le 65536) "$Context probe stdout exceeded 65536 bytes."
    Assert-True ($stderr.Length -le 32768) "$Context probe stderr exceeded 32768 bytes."
    $restoreProof = Restore-ExactFileDacl $descriptor $Context
    $faultApplied = $false
    return [pscustomobject]@{
      ProcessId = $processId
      ExitCode = $process.ExitCode
      Stdout = $stdout
      Stderr = $stderr
      securityDescriptorSha256 = [string]$restoreProof.securityDescriptorSha256
      currentUserSidSha256 = [string]$restoreProof.currentUserSidSha256
      readFaultObserved = [bool]$restoreProof.readFaultObserved
      daclRestoredExactly = [bool]$restoreProof.daclRestoredExactly
    }
  }
  finally {
    if ($faultApplied) {
      Restore-ExactFileDacl $descriptor $Context
    }
    if ($processStarted -and -not $process.HasExited) {
      $process.Kill($true)
      $process.WaitForExit()
    }
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
  [System.Collections.Generic.HashSet[string]]$EventKeys,
  [string[]]$CaptureProcessNames = @()
) {
  $captureNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($captureName in $CaptureProcessNames) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($captureName)) "A process-start image-capture name was invalid."
    $null = $captureNames.Add($captureName)
  }
  Assert-True ($captureNames.Count -eq $CaptureProcessNames.Count) "Process-start image-capture names must be unique."
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
      $imagePath = ""
      $imageStartFileTime = 0L
      $sessionId = -1L
      if ($captureNames.Contains($processName)) {
        $liveIdentity = @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $processId" -ErrorAction Stop)
        if ($liveIdentity.Count -eq 1) {
          $capturedStartFileTime = Get-ProcessSnapshotStartFileTime $liveIdentity[0]
          if ($capturedStartFileTime -le $eventFileTime) {
            Assert-True (-not [string]::IsNullOrWhiteSpace([string]$liveIdentity[0].ExecutablePath)) "A live process-start image capture omitted its executable path."
            $imagePath = [System.IO.Path]::GetFullPath([string]$liveIdentity[0].ExecutablePath)
            $imageFileIdentity = [SubversionRM8I6ExactFileIdentity]::Get($imagePath)
            $imageStartFileTime = $capturedStartFileTime
            $sessionId = [long]$liveIdentity[0].SessionId
          }
        }
      }
      $AllEvents.Add([pscustomobject]@{
          processId = $processId
          parentProcessId = $parentProcessId
          processName = $processName
          eventFileTime = $eventFileTime
          imagePath = $imagePath
          imageFileIdentity = $(if ([string]::IsNullOrEmpty($imagePath)) { "" } else { $imageFileIdentity })
          imageStartFileTime = $imageStartFileTime
          sessionId = $sessionId
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
  [int]$SettlementMilliseconds,
  [string[]]$CaptureProcessNames = @()
) {
  $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($SettlementMilliseconds)
  do {
    Receive-ProcessStartEvents $SourceIdentifier $AllEvents $EventKeys $CaptureProcessNames
    Start-Sleep -Milliseconds 25
  } while ([DateTimeOffset]::UtcNow -lt $deadline)
  Receive-ProcessStartEvents $SourceIdentifier $AllEvents $EventKeys $CaptureProcessNames
}

function Invoke-BoundedProcessWithStartEventCapture(
  [string]$FilePath,
  [string[]]$Arguments,
  [int]$TimeoutSeconds,
  [string]$SourceIdentifier,
  [System.Collections.Generic.List[object]]$AllEvents,
  [System.Collections.Generic.HashSet[string]]$EventKeys,
  [string[]]$CaptureProcessNames,
  [hashtable]$Environment = @{}
) {
  $started = Start-WorkerCrashProbeProcess $FilePath $Arguments $Environment
  $process = [System.Diagnostics.Process]$started.Process
  $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
  $completionStarted = $false
  try {
    while (-not $process.HasExited) {
      Receive-ProcessStartEvents $SourceIdentifier $AllEvents $EventKeys $CaptureProcessNames
      if ([DateTimeOffset]::UtcNow -ge $deadline) {
        $process.Kill($true)
        $process.WaitForExit()
        throw "Controlled process with start-event capture exceeded its absolute deadline."
      }
      Start-Sleep -Milliseconds 25
    }
    Receive-ProcessStartEvents $SourceIdentifier $AllEvents $EventKeys $CaptureProcessNames
    $completionStarted = $true
    return Complete-WorkerCrashProbeProcess $started $TimeoutSeconds "Controlled start-event capture"
  }
  catch {
    if (-not $completionStarted) {
      if (-not $process.HasExited) {
        $process.Kill($true)
        $process.WaitForExit()
      }
      $process.Dispose()
    }
    throw
  }
}

function Get-NextRecordedProcessStartFileTime(
  [object[]]$AllEvents,
  [long]$ProcessId,
  [long]$AfterFileTime
) {
  $next = @($AllEvents | Where-Object {
      [long]$_.processId -eq $ProcessId -and
      [long]$_.eventFileTime -gt $AfterFileTime
    } | Sort-Object -Property eventFileTime | Select-Object -First 1)
  if ($next.Count -eq 0) {
    return [long]::MaxValue
  }
  return [long]$next[0].eventFileTime
}

function Get-RecordedProcessDescendantStarts([object[]]$AllEvents, [long]$RootPid) {
  $rootStarts = @($AllEvents | Where-Object { [long]$_.processId -eq $RootPid })
  Assert-True ($rootStarts.Count -eq 1) "A recorded ancestry root PID must have exactly one subscribed start identity."
  $pending = [System.Collections.Generic.Queue[object]]::new()
  $pending.Enqueue($rootStarts[0])
  $descendants = [System.Collections.Generic.List[object]]::new()
  $descendantIdentities = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  while ($pending.Count -gt 0) {
    $parent = $pending.Dequeue()
    $parentPid = [long]$parent.processId
    $parentEventFileTime = [long]$parent.eventFileTime
    $parentEndFileTime = Get-NextRecordedProcessStartFileTime $AllEvents $parentPid $parentEventFileTime
    foreach ($child in @($AllEvents | Where-Object {
          [long]$_.parentProcessId -eq $parentPid -and
          [long]$_.eventFileTime -gt $parentEventFileTime -and
          [long]$_.eventFileTime -lt $parentEndFileTime
        } | Sort-Object -Property eventFileTime)) {
      $childPid = [long]$child.processId
      Assert-True ($childPid -ne $RootPid) "A packaged-negative worker PID was reused in its recorded ancestry."
      $childIdentity = "$childPid`:$([long]$child.eventFileTime)"
      if ($descendantIdentities.Add($childIdentity)) {
        $descendants.Add($child)
        $pending.Enqueue($child)
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

  $allProbeDescendants = @(Get-RecordedProcessDescendantStarts $AllEvents $ProbePid)
  $daemonStarts = @($allProbeDescendants | Where-Object {
      [long]$_.parentProcessId -eq $ProbePid -and
      ([string]$_.processName).Equals($ExpectedDaemonProcessName, [System.StringComparison]::OrdinalIgnoreCase)
    })
  $probeChildSummary = @($allProbeDescendants | Where-Object { [long]$_.parentProcessId -eq $ProbePid } |
      Select-Object -First 8 | ForEach-Object { "$([string]$_.processName):$([long]$_.processId)" }) -join ","
  Assert-True ($daemonStarts.Count -eq 1) "The exact packaged-negative probe must start exactly one candidate daemon; observed $($daemonStarts.Count) candidate starts and children $probeChildSummary."
  $daemonStart = $daemonStarts[0]
  Assert-True (
    @($AllEvents | Where-Object { [long]$_.processId -eq [long]$daemonStart.processId }).Count -eq 1
  ) "The packaged-negative candidate daemon PID was reused."

  $daemonDescendants = @(Get-RecordedProcessDescendantStarts $AllEvents ([long]$daemonStart.processId))
  $workerStarts = @($daemonDescendants | Where-Object {
      [long]$_.parentProcessId -eq [long]$daemonStart.processId -and
      ([string]$_.processName).Equals($ExpectedDaemonProcessName, [System.StringComparison]::OrdinalIgnoreCase)
    })
  $daemonChildSummary = @($daemonDescendants | Where-Object { [long]$_.parentProcessId -eq [long]$daemonStart.processId } |
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

function Get-RecoveryBlockedProcessObservation(
  [object[]]$AllEvents,
  [long]$ProbePid,
  [string]$ExpectedProbeProcessName,
  [string]$ExpectedDaemonProcessName,
  [string[]]$ForbiddenFixtureProcessNames,
  [object[]]$SettlementSnapshot,
  [string]$Context
) {
  $probeStarts = @($AllEvents | Where-Object {
      [long]$_.processId -eq $ProbePid -and
      ([string]$_.processName).Equals($ExpectedProbeProcessName, [System.StringComparison]::OrdinalIgnoreCase)
    })
  Assert-True ($probeStarts.Count -eq 1) "The $Context probe PID must have exactly one subscribed start identity."
  Assert-True (
    @($AllEvents | Where-Object { [long]$_.processId -eq $ProbePid }).Count -eq 1
  ) "The $Context probe PID was reused during its subscribed observation."

  $recordedDescendants = @(Get-RecordedProcessDescendantStarts $AllEvents $ProbePid)
  $forbiddenNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($processName in $ForbiddenFixtureProcessNames) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($processName)) "A $Context forbidden fixture process name was invalid."
    $null = $forbiddenNames.Add($processName)
  }
  Assert-True ($forbiddenNames.Count -eq $ForbiddenFixtureProcessNames.Count) "$Context forbidden fixture process names must be unique."
  $fixtureCliStarts = @($recordedDescendants | Where-Object { $forbiddenNames.Contains([string]$_.processName) })

  $candidateStarts = @($recordedDescendants | Where-Object {
      ([string]$_.processName).Equals($ExpectedDaemonProcessName, [System.StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object -Property eventFileTime)
  Assert-True ($candidateStarts.Count -eq 5) "The $Context surface must start exactly two candidate daemons and three direct workers."
  $candidatePids = [System.Collections.Generic.HashSet[long]]::new()
  foreach ($candidateStart in $candidateStarts) {
    Assert-True (
      @($AllEvents | Where-Object { [long]$_.processId -eq [long]$candidateStart.processId }).Count -eq 1
    ) "A $Context candidate process PID was reused."
    $null = $candidatePids.Add([long]$candidateStart.processId)
  }
  $daemonStarts = @($candidateStarts | Where-Object {
      -not $candidatePids.Contains([long]$_.parentProcessId)
    } | Sort-Object -Property eventFileTime)
  Assert-True ($daemonStarts.Count -eq 2) "The $Context candidate daemon ancestry was ambiguous."
  $workerStarts = @($candidateStarts | Where-Object {
      $candidatePids.Contains([long]$_.parentProcessId)
    } | Sort-Object -Property eventFileTime)
  Assert-True ($workerStarts.Count -eq 3) "The $Context surface must start exactly three direct workers."
  for ($index = 0; $index -lt 2; $index += 1) {
    $daemonStart = $daemonStarts[$index]
    $directWorkers = @($workerStarts | Where-Object {
        [long]$_.parentProcessId -eq [long]$daemonStart.processId
      })
    $expectedWorkerCount = if ($index -eq 0) { 1 } else { 2 }
    Assert-True ($directWorkers.Count -eq $expectedWorkerCount) "The $Context candidate daemon owned an unexpected number of direct workers."
    foreach ($directWorker in $directWorkers) {
      Assert-True (
        [long]$daemonStart.eventFileTime -lt [long]$directWorker.eventFileTime
      ) "The $Context daemon/worker start ordering was invalid."
    }
  }
  Assert-True (
    [long]$probeStarts[0].eventFileTime -lt [long]$daemonStarts[0].eventFileTime -and
    [long]$workerStarts[0].eventFileTime -lt [long]$daemonStarts[1].eventFileTime
  ) "The $Context restart boundary was not strictly ordered."

  $settledStarts = [System.Collections.Generic.List[object]]::new()
  foreach ($candidateStart in $candidateStarts) {
    $settledStarts.Add($candidateStart)
    foreach ($descendant in @(Get-RecordedProcessDescendantStarts $AllEvents ([long]$candidateStart.processId))) {
      $settledStarts.Add($descendant)
    }
  }
  $liveSettledIds = [System.Collections.Generic.HashSet[long]]::new()
  foreach ($settledStart in $settledStarts) {
    if (@($SettlementSnapshot | Where-Object {
          [long]$_.ProcessId -eq [long]$settledStart.processId -and
          (Get-ProcessSnapshotStartFileTime $_) -le [long]$settledStart.eventFileTime
        }).Count -gt 0) {
      $null = $liveSettledIds.Add([long]$settledStart.processId)
    }
  }
  Assert-True ($liveSettledIds.Count -eq 0) "The $Context daemon, worker, or descendant remained alive at settlement."
  return [pscustomobject]@{
    daemonStarts = $daemonStarts.Count
    workerStarts = $workerStarts.Count
    workerDescendantsAfter = $liveSettledIds.Count
    fixtureCliInvocations = $fixtureCliStarts.Count
  }
}

function Get-RecoverySafeProcessObservation(
  [object[]]$AllEvents,
  [long]$ProbePid,
  [string]$ExpectedProbeProcessName,
  [string]$ExpectedDaemonProcessName,
  [string[]]$ForbiddenFixtureProcessNames,
  [object[]]$SettlementSnapshot,
  [string]$Context
) {
  $probeStarts = @($AllEvents | Where-Object {
      [long]$_.processId -eq $ProbePid -and
      ([string]$_.processName).Equals($ExpectedProbeProcessName, [System.StringComparison]::OrdinalIgnoreCase)
    })
  Assert-True ($probeStarts.Count -eq 1) "The $Context probe PID must have exactly one subscribed start identity."
  Assert-True (@($AllEvents | Where-Object { [long]$_.processId -eq $ProbePid }).Count -eq 1) "The $Context probe PID was reused."

  $recordedDescendants = @(Get-RecordedProcessDescendantStarts $AllEvents $ProbePid)
  $forbiddenNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($processName in $ForbiddenFixtureProcessNames) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($processName)) "A $Context forbidden fixture process name was invalid."
    $null = $forbiddenNames.Add($processName)
  }
  Assert-True ($forbiddenNames.Count -eq $ForbiddenFixtureProcessNames.Count) "$Context forbidden fixture process names must be unique."
  $fixtureCliStarts = @($recordedDescendants | Where-Object { $forbiddenNames.Contains([string]$_.processName) })

  $candidateStarts = @($recordedDescendants | Where-Object {
      ([string]$_.processName).Equals($ExpectedDaemonProcessName, [System.StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object -Property eventFileTime)
  Assert-True ($candidateStarts.Count -eq 4) "The $Context surface must start exactly one candidate daemon and three direct workers."
  $candidatePids = [System.Collections.Generic.HashSet[long]]::new()
  foreach ($candidateStart in $candidateStarts) {
    Assert-True (@($AllEvents | Where-Object { [long]$_.processId -eq [long]$candidateStart.processId }).Count -eq 1) "A $Context candidate PID was reused."
    $null = $candidatePids.Add([long]$candidateStart.processId)
  }
  $daemonStarts = @($candidateStarts | Where-Object { -not $candidatePids.Contains([long]$_.parentProcessId) })
  Assert-True ($daemonStarts.Count -eq 1) "The $Context candidate daemon ancestry was ambiguous."
  $daemonStart = $daemonStarts[0]
  $workerStarts = @($candidateStarts | Where-Object { [long]$_.parentProcessId -eq [long]$daemonStart.processId })
  Assert-True ($workerStarts.Count -eq 3) "The $Context candidate daemon must start exactly three direct workers."
  Assert-True ([long]$probeStarts[0].eventFileTime -lt [long]$daemonStart.eventFileTime) "The $Context probe/daemon ordering was invalid."
  foreach ($workerStart in $workerStarts) {
    Assert-True ([long]$daemonStart.eventFileTime -lt [long]$workerStart.eventFileTime) "The $Context daemon/worker ordering was invalid."
  }

  $settledStarts = [System.Collections.Generic.List[object]]::new()
  foreach ($candidateStart in $candidateStarts) {
    $settledStarts.Add($candidateStart)
    foreach ($descendant in @(Get-RecordedProcessDescendantStarts $AllEvents ([long]$candidateStart.processId))) {
      $settledStarts.Add($descendant)
    }
  }
  $liveSettledIds = [System.Collections.Generic.HashSet[long]]::new()
  foreach ($settledStart in $settledStarts) {
    if (@($SettlementSnapshot | Where-Object {
          [long]$_.ProcessId -eq [long]$settledStart.processId -and
          (Get-ProcessSnapshotStartFileTime $_) -le [long]$settledStart.eventFileTime
        }).Count -gt 0) {
      $null = $liveSettledIds.Add([long]$settledStart.processId)
    }
  }
  Assert-True ($liveSettledIds.Count -eq 0) "The $Context daemon, worker, or descendant remained alive at settlement."
  return [pscustomobject]@{
    daemonStarts = $daemonStarts.Count
    workerStarts = $workerStarts.Count
    workerDescendantsAfter = $liveSettledIds.Count
    fixtureCliInvocations = $fixtureCliStarts.Count
  }
}

function Get-RecoveryIndeterminateProcessObservation(
  [object[]]$AllEvents,
  [long]$ProbePid,
  [string]$ExpectedProbeProcessName,
  [string]$ExpectedDaemonProcessName,
  [string[]]$ForbiddenFixtureProcessNames,
  [object[]]$SettlementSnapshot,
  [string]$Context
) {
  $probeStarts = @($AllEvents | Where-Object {
      [long]$_.processId -eq $ProbePid -and
      ([string]$_.processName).Equals($ExpectedProbeProcessName, [System.StringComparison]::OrdinalIgnoreCase)
    })
  Assert-True ($probeStarts.Count -eq 1) "The $Context probe PID must have exactly one subscribed start identity."
  Assert-True (@($AllEvents | Where-Object { [long]$_.processId -eq $ProbePid }).Count -eq 1) "The $Context probe PID was reused."

  $recordedDescendants = @(Get-RecordedProcessDescendantStarts $AllEvents $ProbePid)
  $forbiddenNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($processName in $ForbiddenFixtureProcessNames) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($processName)) "A $Context forbidden fixture process name was invalid."
    $null = $forbiddenNames.Add($processName)
  }
  Assert-True ($forbiddenNames.Count -eq $ForbiddenFixtureProcessNames.Count) "$Context forbidden fixture process names must be unique."
  $fixtureCliStarts = @($recordedDescendants | Where-Object { $forbiddenNames.Contains([string]$_.processName) })

  $candidateStarts = @($recordedDescendants | Where-Object {
      ([string]$_.processName).Equals($ExpectedDaemonProcessName, [System.StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object -Property eventFileTime)
  Assert-True ($candidateStarts.Count -eq 3) "The $Context surface must start exactly one candidate daemon and two direct workers."
  $candidatePids = [System.Collections.Generic.HashSet[long]]::new()
  foreach ($candidateStart in $candidateStarts) {
    Assert-True (@($AllEvents | Where-Object { [long]$_.processId -eq [long]$candidateStart.processId }).Count -eq 1) "A $Context candidate PID was reused."
    $null = $candidatePids.Add([long]$candidateStart.processId)
  }
  $daemonStarts = @($candidateStarts | Where-Object { -not $candidatePids.Contains([long]$_.parentProcessId) })
  Assert-True ($daemonStarts.Count -eq 1) "The $Context candidate daemon ancestry was ambiguous."
  $daemonStart = $daemonStarts[0]
  $workerStarts = @($candidateStarts | Where-Object { [long]$_.parentProcessId -eq [long]$daemonStart.processId })
  Assert-True ($workerStarts.Count -eq 2) "The $Context candidate daemon must start exactly two direct workers."
  Assert-True ([long]$probeStarts[0].eventFileTime -lt [long]$daemonStart.eventFileTime) "The $Context probe/daemon ordering was invalid."
  foreach ($workerStart in $workerStarts) {
    Assert-True ([long]$daemonStart.eventFileTime -lt [long]$workerStart.eventFileTime) "The $Context daemon/worker ordering was invalid."
  }

  $settledStarts = [System.Collections.Generic.List[object]]::new()
  foreach ($candidateStart in $candidateStarts) {
    $settledStarts.Add($candidateStart)
    foreach ($descendant in @(Get-RecordedProcessDescendantStarts $AllEvents ([long]$candidateStart.processId))) {
      $settledStarts.Add($descendant)
    }
  }
  $liveSettledIds = [System.Collections.Generic.HashSet[long]]::new()
  foreach ($settledStart in $settledStarts) {
    if (@($SettlementSnapshot | Where-Object {
          [long]$_.ProcessId -eq [long]$settledStart.processId -and
          (Get-ProcessSnapshotStartFileTime $_) -le [long]$settledStart.eventFileTime
        }).Count -gt 0) {
      $null = $liveSettledIds.Add([long]$settledStart.processId)
    }
  }
  Assert-True ($liveSettledIds.Count -eq 0) "The $Context daemon, worker, or descendant remained alive at settlement."
  return [pscustomobject]@{
    daemonStarts = $daemonStarts.Count
    workerStarts = $workerStarts.Count
    workerDescendantsAfter = $liveSettledIds.Count
    fixtureCliInvocations = $fixtureCliStarts.Count
  }
}

function Get-ZeroWorkerProcessObservation(
  [object[]]$AllEvents,
  [long]$ProbePid,
  [string]$ExpectedProbeProcessName,
  [string]$ExpectedDaemonProcessName,
  [string]$ExpectedDaemonFileIdentity,
  [string]$ExpectedConsoleHostFileIdentity,
  [string[]]$ForbiddenFixtureProcessNames,
  [object[]]$SettlementSnapshot,
  [string]$Context
) {
  Assert-True (-not [string]::IsNullOrWhiteSpace($ExpectedDaemonFileIdentity)) "The expected candidate daemon file identity was invalid."
  Assert-True (-not [string]::IsNullOrWhiteSpace($ExpectedConsoleHostFileIdentity)) "The expected Windows console-host file identity was invalid."
  $probeStarts = @($AllEvents | Where-Object {
      [long]$_.processId -eq $ProbePid -and
      ([string]$_.processName).Equals($ExpectedProbeProcessName, [System.StringComparison]::OrdinalIgnoreCase)
    })
  Assert-True ($probeStarts.Count -eq 1) "The $Context probe PID must have exactly one subscribed start identity."
  Assert-True (
    @($AllEvents | Where-Object { [long]$_.processId -eq $ProbePid }).Count -eq 1
  ) "The $Context probe PID was reused during its subscribed observation."

  $recordedDescendants = @(Get-RecordedProcessDescendantStarts $AllEvents $ProbePid)
  $candidateStarts = @($recordedDescendants | Where-Object {
      ([string]$_.processName).Equals($ExpectedDaemonProcessName, [System.StringComparison]::OrdinalIgnoreCase)
    })
  Assert-True ($candidateStarts.Count -eq 1) "The $Context surface must start exactly one candidate daemon and no remote worker."
  $daemonStart = $candidateStarts[0]
  Assert-True (
    [long]$probeStarts[0].eventFileTime -lt [long]$daemonStart.eventFileTime -and
    @($AllEvents | Where-Object { [long]$_.processId -eq [long]$daemonStart.processId }).Count -eq 1 -and
    [long]$daemonStart.imageStartFileTime -gt 0 -and
    [long]$daemonStart.imageStartFileTime -le [long]$daemonStart.eventFileTime -and
    [long]$daemonStart.sessionId -ge 0 -and
    [string]$daemonStart.imageFileIdentity -ceq $ExpectedDaemonFileIdentity
  ) "The $Context candidate daemon start identity was invalid or reused."
  $daemonDescendantStarts = @(Get-RecordedProcessDescendantStarts $AllEvents ([long]$daemonStart.processId))
  $consoleHostStarts = @($daemonDescendantStarts | Where-Object {
      [long]$_.parentProcessId -eq [long]$daemonStart.processId -and
      ([string]$_.processName).Equals("conhost.exe", [System.StringComparison]::OrdinalIgnoreCase)
    })
  Assert-True ($consoleHostStarts.Count -le 1) "The $Context candidate daemon may own at most one direct Windows console host."
  if ($consoleHostStarts.Count -eq 1) {
    $consoleHostStart = $consoleHostStarts[0]
    Assert-True (
      @($AllEvents | Where-Object {
          [long]$_.processId -eq [long]$consoleHostStart.processId -and
          [long]$_.eventFileTime -eq [long]$consoleHostStart.eventFileTime
        }).Count -eq 1 -and
      [long]$consoleHostStart.imageStartFileTime -gt 0 -and
      [long]$consoleHostStart.imageStartFileTime -le [long]$consoleHostStart.eventFileTime -and
      [long]$consoleHostStart.sessionId -eq [long]$daemonStart.sessionId -and
      [string]$consoleHostStart.imageFileIdentity -ceq $ExpectedConsoleHostFileIdentity
    ) "The $Context Windows console-host start identity was ambiguous."
  }
  $unexpectedDaemonDescendantStarts = @($daemonDescendantStarts | Where-Object {
      -not (
        [long]$_.parentProcessId -eq [long]$daemonStart.processId -and
        ([string]$_.processName).Equals("conhost.exe", [System.StringComparison]::OrdinalIgnoreCase)
      )
    })
  $daemonDescendantSummary = @($unexpectedDaemonDescendantStarts | Select-Object -First 8 | ForEach-Object {
      "$([string]$_.processName):pid=$([long]$_.processId):parent=$([long]$_.parentProcessId):time=$([long]$_.eventFileTime)"
    }) -join ","
  Assert-True ($unexpectedDaemonDescendantStarts.Count -eq 0) "The $Context surface started a remote worker or another daemon descendant: $daemonDescendantSummary."

  $forbiddenNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($processName in $ForbiddenFixtureProcessNames) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($processName)) "A $Context forbidden fixture process name was invalid."
    $null = $forbiddenNames.Add($processName)
  }
  Assert-True ($forbiddenNames.Count -eq $ForbiddenFixtureProcessNames.Count) "$Context forbidden fixture process names must be unique."
  $fixtureCliStarts = @($recordedDescendants | Where-Object { $forbiddenNames.Contains([string]$_.processName) })

  $settledIdentities = @($daemonStart) + $consoleHostStarts
  $liveSettledIds = [System.Collections.Generic.HashSet[long]]::new()
  foreach ($settledIdentity in $settledIdentities) {
    if (@($SettlementSnapshot | Where-Object {
          [long]$_.ProcessId -eq [long]$settledIdentity.processId -and
          (Get-ProcessSnapshotStartFileTime $_) -le [long]$settledIdentity.eventFileTime
        }).Count -gt 0) {
      $null = $liveSettledIds.Add([long]$settledIdentity.processId)
    }
  }
  Assert-True ($liveSettledIds.Count -eq 0) "The $Context candidate daemon or Windows console host remained alive at settlement."
  return [pscustomobject]@{
    daemonProcessId = [long]$daemonStart.processId
    consoleHostStarts = $consoleHostStarts.Count
    workerStarts = $unexpectedDaemonDescendantStarts.Count
    workerDescendantsAfter = $liveSettledIds.Count
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

function Stop-ControlledSvnserve(
  [string]$ExecutablePath,
  [long]$ProcessId,
  [string]$ExpectedStartTimeUtc
) {
  $candidateProcessIds = @(Get-CandidateProcessIds $ExecutablePath)
  Assert-True (
    $candidateProcessIds.Count -eq 1 -and [long]$candidateProcessIds[0] -eq $ProcessId
  ) "The controlled svnserve identity changed before the stalled-mid-read phase."
  $process = Get-Process -Id $ProcessId -ErrorAction Stop
  Assert-True (
    $process.StartTime.ToUniversalTime().ToString("O", [Globalization.CultureInfo]::InvariantCulture) -ceq $ExpectedStartTimeUtc
  ) "The controlled svnserve start time changed before the stalled-mid-read phase."
  Stop-Process -Id $ProcessId -Force -ErrorAction Stop
  $process.WaitForExit()
  Assert-CandidateProcessAbsent $ExecutablePath "The stalled-mid-read svnserve handoff" 10000
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
  [string]$StatePath,
  [int]$Port = 0
) {
  Assert-True ($Port -ge 0 -and $Port -le 65535) "The $Scenario ra_svn fault fixture port was invalid."
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
      "--port", ([string]$Port),
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
    if ($Port -ne 0) {
      Assert-True ([int]$state.port -eq $Port) "The $Scenario ra_svn fault fixture did not bind the required port."
    }
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

function Assert-AnonymousIdentityRequiredObservation(
  [object]$Observation,
  [string]$ExpectedOperation,
  [string]$ExpectedCode,
  [string]$ExpectedCauseName,
  [string]$ExpectedSurface,
  [string]$Context
) {
  $properties = @(
    "operation", "anonymousIdentityRequired", "stableCode", "diagnosticsCause", "mayHaveMutated",
    "remoteFailure", "promptCount", "credentialSettlement", "laneReleaseProof",
    "nativeLaneReleased", "diagnosticsRedacted", "svnCauseNames"
  )
  if ($ExpectedSurface -ceq "packaged-native") {
    $properties += "temporaryRootsAfter"
  }
  Assert-ExactProperties $Observation $properties $Context
  Assert-ExactProperties $Observation.remoteFailure @("category", "reason", "cleanupAppropriate") "$Context remote failure"
  Assert-ExactProperties $Observation.laneReleaseProof @("method", "reconcile") "$Context lane-release proof"
  Assert-True (
    [string]$Observation.operation -ceq $ExpectedOperation -and
    $Observation.anonymousIdentityRequired -eq $true -and
    [string]$Observation.stableCode -ceq $ExpectedCode -and
    [string]$Observation.diagnosticsCause -ceq "authenticationFailed" -and
    $Observation.mayHaveMutated -eq $false -and
    [string]$Observation.remoteFailure.category -ceq "authentication" -and
    [string]$Observation.remoteFailure.reason -ceq "authenticationRequired" -and
    $Observation.remoteFailure.cleanupAppropriate -eq $false -and
    [int]$Observation.promptCount -eq 0 -and
    [string]$Observation.credentialSettlement -ceq "none" -and
    [string]$Observation.laneReleaseProof.method -ceq "status/refresh" -and
    [string]$Observation.laneReleaseProof.reconcile -ceq "fresh" -and
    $Observation.nativeLaneReleased -eq $true -and
    $Observation.diagnosticsRedacted -eq $true
  ) "$Context did not prove the exact anonymous identity boundary."
  if ($ExpectedSurface -ceq "packaged-native") {
    Assert-True ([int]$Observation.temporaryRootsAfter -eq 0) "$Context left an observed worker temporary root."
  }
  $causeNames = @($Observation.svnCauseNames)
  Assert-True ($causeNames.Count -ge 1 -and $causeNames.Count -le 8) "$Context did not preserve a bounded libsvn cause chain."
  $uniqueCauseNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($causeName in $causeNames) {
    Assert-True ([string]$causeName -cmatch '^SVN_ERR_[A-Z0-9_]+$') "$Context contained an invalid libsvn cause name."
    Assert-True ($uniqueCauseNames.Add([string]$causeName)) "$Context contained a duplicate libsvn cause name."
  }
  $observedIdentityCauseNames = @($causeNames | Where-Object {
      [string]$_ -ceq "SVN_ERR_RA_NOT_AUTHORIZED" -or [string]$_ -ceq "SVN_ERR_FS_NO_USER"
    })
  Assert-True (
    $observedIdentityCauseNames.Count -eq 1 -and
    [string]$observedIdentityCauseNames[0] -ceq $ExpectedCauseName
  ) "$Context did not retain the operation-specific upstream anonymous-identity cause."
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
$consoleHostResolved = Resolve-RequiredFile (Join-Path ([Environment]::SystemDirectory) "conhost.exe") "Windows console host"
$daemonFileIdentity = [SubversionRM8I6ExactFileIdentity]::Get($daemonResolved)
$consoleHostFileIdentity = [SubversionRM8I6ExactFileIdentity]::Get($consoleHostResolved)
$zeroWorkerCaptureProcessNames = @(
  [System.IO.Path]::GetFileName($daemonResolved),
  [System.IO.Path]::GetFileName($consoleHostResolved)
)
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
$packagedStalledReadProbeResolved = Resolve-RequiredFile $packagedStalledReadProbePath "packaged-native I6 stalled-mid-read probe"
$installedStalledReadProbeResolved = Resolve-RequiredFile $installedStalledReadProbePath "installed VSIX I6 stalled-mid-read probe"
$packagedDeadlineProbeResolved = Resolve-RequiredFile $packagedDeadlineProbePath "packaged-native I6 deadline probe"
$installedDeadlineProbeResolved = Resolve-RequiredFile $installedDeadlineProbePath "installed VSIX I6 deadline probe"
$packagedCancellationProbeResolved = Resolve-RequiredFile $packagedCancellationProbePath "packaged-native I6 cancellation probe"
$installedCancellationProbeResolved = Resolve-RequiredFile $installedCancellationProbePath "installed VSIX I6 cancellation probe"
$packagedTrustRevokedProbeResolved = Resolve-RequiredFile $packagedTrustRevokedProbePath "packaged-native I6 trust-revoked probe"
$installedTrustRevokedProbeResolved = Resolve-RequiredFile $installedTrustRevokedProbePath "installed VSIX I6 trust-revoked probe"
$packagedRecoveryBlockedProbeResolved = Resolve-RequiredFile $packagedRecoveryBlockedProbePath "packaged-native I6 recovery-blocked probe"
$installedRecoveryBlockedProbeResolved = Resolve-RequiredFile $installedRecoveryBlockedProbePath "installed VSIX I6 recovery-blocked probe"
$packagedRecoverySafeProbeResolved = Resolve-RequiredFile $packagedRecoverySafeProbePath "packaged-native I6 recovery-safe probe"
$installedRecoverySafeProbeResolved = Resolve-RequiredFile $installedRecoverySafeProbePath "installed VSIX I6 recovery-safe probe"
$packagedRecoveryIndeterminateProbeResolved = Resolve-RequiredFile $packagedRecoveryIndeterminateProbePath "packaged-native I6 recovery-indeterminate probe"
$installedRecoveryIndeterminateProbeResolved = Resolve-RequiredFile $installedRecoveryIndeterminateProbePath "installed VSIX I6 recovery-indeterminate probe"
$packagedRedactionProbeResolved = Resolve-RequiredFile $packagedRedactionProbePath "packaged-native I6 redaction probe"
$installedRedactionProbeResolved = Resolve-RequiredFile $installedRedactionProbePath "installed VSIX I6 redaction probe"
$packagedWorkerCrashProbeResolved = Resolve-RequiredFile $packagedWorkerCrashProbePath "packaged-native I6 worker-crash probe"
$installedWorkerCrashProbeResolved = Resolve-RequiredFile $installedWorkerCrashProbePath "installed VSIX I6 worker-crash probe"
$packagedBlackholeConnectProbeResolved = Resolve-RequiredFile $packagedBlackholeConnectProbePath "packaged-native I6 blackhole-connect probe"
$installedBlackholeConnectProbeResolved = Resolve-RequiredFile $installedBlackholeConnectProbePath "installed VSIX I6 blackhole-connect probe"
$packagedDaemonDisconnectProbeResolved = Resolve-RequiredFile $packagedDaemonDisconnectProbePath "packaged-native I6 daemon-disconnect probe"
$installedDaemonDisconnectProbeResolved = Resolve-RequiredFile $installedDaemonDisconnectProbePath "installed VSIX I6 daemon-disconnect probe"
$installedLocalEventProbeResolved = Resolve-RequiredFile $installedLocalEventProbePath "installed VSIX I6 local-event zero-network probe"
$countingProxyResolved = Resolve-RequiredFile $countingProxyPath "I6 transparent counting proxy"
$faultFixtureResolved = Resolve-RequiredFile $faultFixturePath "I6 ra_svn fault fixture"
$blackholeConnectFixtureResolved = Resolve-RequiredFile $blackholeConnectFixturePath "I6 loopback blackhole-connect fixture"
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
try {
  $unrelatedRepositoryUri = [System.Uri]::new($UnrelatedRepositoryUrl, [System.UriKind]::Absolute)
}
catch {
  throw "UnrelatedRepositoryUrl must be an absolute direct svn:// URL."
}
Assert-True ($unrelatedRepositoryUri.Scheme -ceq "svn") "UnrelatedRepositoryUrl must use direct svn:// transport."
Assert-True ($unrelatedRepositoryUri.Host -ceq "127.0.0.1") "UnrelatedRepositoryUrl must use the controlled IPv4 loopback host."
Assert-True ([string]::IsNullOrEmpty($unrelatedRepositoryUri.UserInfo)) "UnrelatedRepositoryUrl must not contain user information."
Assert-True ([string]::IsNullOrEmpty($unrelatedRepositoryUri.Query) -and [string]::IsNullOrEmpty($unrelatedRepositoryUri.Fragment)) "UnrelatedRepositoryUrl must not contain a query or fragment."
Assert-True ($unrelatedRepositoryUri.Port -eq $repositoryUri.Port) "UnrelatedRepositoryUrl must use the controlled source-built svnserve port."
Assert-True ($unrelatedRepositoryUri.AbsolutePath -ceq "/unrelated/trunk") "UnrelatedRepositoryUrl must identify the separately created unrelated repository trunk."
Assert-True (-not $unrelatedRepositoryUri.AbsoluteUri.Equals($repositoryUri.AbsoluteUri, [System.StringComparison]::Ordinal)) "UnrelatedRepositoryUrl must differ from RepositoryUrl."

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
$packagedVsixDaemonPath = Resolve-RequiredFile (Join-Path $extractedVsixRoot "extension\resources\backend\win32-x64\subversionr-daemon.exe") "packaged VSIX daemon"
$packagedVsixBridgePath = Resolve-RequiredFile (Join-Path $extractedVsixRoot "extension\resources\backend\win32-x64\subversionr_svn_bridge.dll") "packaged VSIX bridge"
Assert-True ((Get-Sha256 $packagedVsixDaemonPath) -ceq (Get-Sha256 $daemonResolved)) "The extracted packaged VSIX daemon must match DaemonPath."
Assert-True ((Get-Sha256 $packagedVsixBridgePath) -ceq (Get-Sha256 $bridgeResolved)) "The extracted packaged VSIX bridge must match BridgePath."
$nodeHost = Resolve-CodeNodeHost $codeCliResolved
Assert-True ($null -ne (Get-Command Get-CimInstance -CommandType Cmdlet -ErrorAction Stop)) "Get-CimInstance is required."
Assert-True ($null -ne (Get-Command Register-CimIndicationEvent -CommandType Cmdlet -ErrorAction Stop)) "Register-CimIndicationEvent is required."

$packagedI6ProbeResolved = Resolve-RequiredFile (Join-Path $PSScriptRoot "probe-m8-i6-packaged-native.mjs") "packaged-native I6 positive probe"
$seedWorkingCopy = Resolve-RequiredDirectory (Join-Path $fixtureRootResolved "seed-wc") "I6 seed working copy"
$oracleConfigRoot = Resolve-RequiredDirectory (Join-Path $fixtureRootResolved "fixture-cli-config") "I6 fixture CLI configuration"
$repositoryUuidResult = Invoke-BoundedProcess $svnResolved @(
  "info", "--show-item", "repos-uuid", $RepositoryUrl,
  "--non-interactive", "--no-auth-cache", "--config-dir", $oracleConfigRoot
) 30
$unrelatedRepositoryUuidResult = Invoke-BoundedProcess $svnResolved @(
  "info", "--show-item", "repos-uuid", $UnrelatedRepositoryUrl,
  "--non-interactive", "--no-auth-cache", "--config-dir", $oracleConfigRoot
) 30
Assert-True ($repositoryUuidResult.ExitCode -eq 0 -and $repositoryUuidResult.Stderr.Length -eq 0) "The driver could not read the controlled repository UUID."
Assert-True ($unrelatedRepositoryUuidResult.ExitCode -eq 0 -and $unrelatedRepositoryUuidResult.Stderr.Length -eq 0) "The driver could not read the controlled unrelated repository UUID."
$repositoryUuid = $repositoryUuidResult.Stdout.Trim()
$unrelatedRepositoryUuid = $unrelatedRepositoryUuidResult.Stdout.Trim()
Assert-True ($repositoryUuid -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') "The controlled repository UUID was invalid."
Assert-True ($unrelatedRepositoryUuid -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') "The controlled unrelated repository UUID was invalid."
Assert-True (-not $repositoryUuid.Equals($unrelatedRepositoryUuid, [System.StringComparison]::OrdinalIgnoreCase)) "The unrelated repository must have a distinct repository UUID."
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
    $installedLocalEventResult = Invoke-BoundedProcessWithStartEventCapture (Get-Process -Id $PID).Path @(
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
    ) 240 `
      $localEventProcessSourceIdentifier `
      $localEventProcessEvents `
      $localEventProcessEventKeys `
      $zeroWorkerCaptureProcessNames
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
      $ProcessStartEventSettlementMilliseconds `
      $zeroWorkerCaptureProcessNames
    $localEventProcessObservation = Get-ZeroWorkerProcessObservation `
      -AllEvents @($localEventProcessEvents) `
      -ProbePid ([long]$installedLocalEventResult.ProcessId) `
      -ExpectedProbeProcessName ([System.IO.Path]::GetFileName((Get-Process -Id $PID).Path)) `
      -ExpectedDaemonProcessName ([System.IO.Path]::GetFileName($daemonResolved)) `
      -ExpectedDaemonFileIdentity $daemonFileIdentity `
      -ExpectedConsoleHostFileIdentity $consoleHostFileIdentity `
      -ForbiddenFixtureProcessNames @(
        [System.IO.Path]::GetFileName($svnResolved),
        [System.IO.Path]::GetFileName($svnadminResolved),
        [System.IO.Path]::GetFileName($svnserveResolved)
      ) `
      -SettlementSnapshot (Get-CimProcessSnapshot) `
      -Context "installed local-event"
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
$expectedPositiveOperations = @("checkoutOpen", "remoteStatus", "content", "historyLog", "historyBlame", "update", "commit", "branchCopy", "switch")
Assert-True ([string]$positiveReport.schema -ceq "subversionr.release.m8-i6-packaged-native-positive.v1") "The packaged-native I6 positive probe returned an unexpected schema."
Assert-True ([string]$positiveReport.status -ceq "passed") "The packaged-native I6 positive probe did not pass."
Assert-True ((@($positiveReport.operations.operation) -join ",") -ceq ($expectedPositiveOperations -join ",")) "The packaged-native I6 positive probe did not execute the exact operation matrix."
Assert-True (
  [int]$positiveReport.positiveOperationCount -eq 9 -and
  [int]$positiveReport.identityRequiredOperationCount -eq 2 -and
  [int]$positiveReport.remoteOperationCount -eq 11 -and
  $positiveReport.uniqueOperationIds -eq $true
) "The packaged-native I6 report did not prove nine positive and two identity-required operations with unique IDs."
Assert-ExactProperties $positiveReport.anonymousIdentityRequired @("lock", "unlock") "The packaged-native anonymous identity boundary"
Assert-AnonymousIdentityRequiredObservation $positiveReport.anonymousIdentityRequired.lock "lock" "SVN_OPERATION_LOCK_FAILED" "SVN_ERR_RA_NOT_AUTHORIZED" "packaged-native" "The packaged-native anonymous lock observation"
Assert-AnonymousIdentityRequiredObservation $positiveReport.anonymousIdentityRequired.unlock "unlock" "SVN_OPERATION_UNLOCK_FAILED" "SVN_ERR_FS_NO_USER" "packaged-native" "The packaged-native anonymous unlock observation"
Assert-True ($positiveReport.remoteSvnAnonymous -eq $true -and [int]$positiveReport.fixtureCliInvocations -eq 0) "The packaged-native I6 positive probe did not preserve anonymous native-only execution."
foreach ($operation in @($positiveReport.operations)) {
  Assert-True (
    [string]$operation.status -ceq "passed" -and
    [string]$operation.serverAuth -ceq "anonymous" -and
    [int]$operation.promptCount -eq 0 -and
    [string]$operation.credentialSettlement -ceq "none" -and
    [string]$operation.reconcile -ceq "fresh" -and
    [int]$operation.temporaryRootsAfter -eq 0 -and
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
  Assert-True (
    [int]$installedPositiveReport.positiveOperationCount -eq 9 -and
    [int]$installedPositiveReport.identityRequiredOperationCount -eq 2 -and
    [int]$installedPositiveReport.remoteOperationCount -eq 11 -and
    $installedPositiveReport.uniqueOperationIds -eq $true
  ) "The installed Extension Host I6 report did not prove nine positive and two identity-required operations with unique IDs."
  Assert-ExactProperties $installedPositiveReport.anonymousIdentityRequired @("lock", "unlock") "The installed anonymous identity boundary"
  Assert-AnonymousIdentityRequiredObservation $installedPositiveReport.anonymousIdentityRequired.lock "lock" "SVN_OPERATION_LOCK_FAILED" "SVN_ERR_RA_NOT_AUTHORIZED" "installed-vsix-extension-host" "The installed anonymous lock observation"
  Assert-AnonymousIdentityRequiredObservation $installedPositiveReport.anonymousIdentityRequired.unlock "unlock" "SVN_OPERATION_UNLOCK_FAILED" "SVN_ERR_FS_NO_USER" "installed-vsix-extension-host" "The installed anonymous unlock observation"
  foreach ($operation in @($installedPositiveReport.operations)) {
    Assert-True (
      [string]$operation.status -ceq "passed" -and
      [string]$operation.serverAuth -ceq "anonymous" -and
      [int]$operation.promptCount -eq 0 -and
      [string]$operation.credentialSettlement -ceq "none" -and
      [string]$operation.reconcile -ceq "fresh" -and
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

$recoveryBlockedWorkRoot = [System.IO.Path]::GetFullPath((Join-Path $repoTargetRoot "i6b\$([Guid]::NewGuid().ToString('N').Substring(0, 8))"))
Assert-True (Test-PathWithin $recoveryBlockedWorkRoot $repoTargetRoot) "The recovery-blocked short work root escaped repo target."
Assert-True ($recoveryBlockedWorkRoot.Length -le 120) "The recovery-blocked short work root exceeds the reviewed 120-character budget."
Assert-True (-not (Test-Path -LiteralPath $recoveryBlockedWorkRoot)) "The recovery-blocked short work root already exists."
New-Item -ItemType Directory -Path $recoveryBlockedWorkRoot | Out-Null
$recoveryBlockedObservations = @()
$recoveryBlockedSettlementObservations = @()
$unrelatedRepositoryObservations = @()
try {
  $recoveryBlockedContracts = @(
    [pscustomobject]@{ Surface = "packaged-native"; WorkRoot = "p" },
    [pscustomobject]@{ Surface = "installed-vsix-extension-host"; WorkRoot = "i" }
  )
  foreach ($contract in $recoveryBlockedContracts) {
    $surfaceName = [string]$contract.Surface
    $surfaceRoot = Join-Path $probeRoot "recovery-blocked-$surfaceName"
    $surfaceWorkRoot = Join-Path $recoveryBlockedWorkRoot ([string]$contract.WorkRoot)
    $fixtureStatePath = Join-Path $surfaceRoot "fixture-state.json"
    $unrelatedProxyStatePath = Join-Path $surfaceRoot "unrelated-proxy-state.json"
    $unrelatedCheckoutTarget = Join-Path $surfaceWorkRoot "u"
    New-Item -ItemType Directory -Force -Path $surfaceRoot, $surfaceWorkRoot | Out-Null
    Assert-True ($unrelatedCheckoutTarget.Length -le 120) "The $surfaceName unrelated checkout target exceeds the reviewed 120-character budget."
    Assert-True (-not (Test-Path -LiteralPath $unrelatedCheckoutTarget)) "The $surfaceName unrelated checkout target already existed."
    $faultFixture = $null
    $unrelatedProxy = $null
    $unrelatedProxyAfter = $null
    $processStartSourceIdentifier = "subversionr-m8-i6-recovery-blocked-$([Guid]::NewGuid().ToString('N'))"
    $processStartSubscriber = $null
    $processStartEvents = [System.Collections.Generic.List[object]]::new()
    $processStartEventKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    try {
      Assert-CandidateProcessAbsent $daemonResolved "The $surfaceName recovery-blocked preflight"
      $faultFixture = Start-FaultFixture $nodeHost $faultFixtureResolved "command-stall" $fixtureStatePath
      $faultRepositoryUrl = "svn://127.0.0.1:$([int]$faultFixture.State.port)/repo/trunk"
      $unrelatedProxy = Start-CountingProxy $nodeHost $countingProxyResolved $repositoryUri.Port $unrelatedProxyStatePath
      $unrelatedProxyBaseline = Read-CountingProxyState $unrelatedProxyStatePath $unrelatedProxy.Process $true
      foreach ($counterName in @(
          "acceptedConnections", "upstreamAttempts", "upstreamConnections",
          "clientToUpstreamBytes", "upstreamToClientBytes", "activeConnections", "upstreamConnectFailures"
        )) {
        Assert-True ([int64]$unrelatedProxyBaseline.$counterName -eq 0) "The $surfaceName unrelated counting proxy did not begin at zero for '$counterName'."
      }
      $unrelatedProxyUriBuilder = [System.UriBuilder]::new($unrelatedRepositoryUri)
      $unrelatedProxyUriBuilder.Port = [int]$unrelatedProxy.State.port
      $proxiedUnrelatedRepositoryUrl = $unrelatedProxyUriBuilder.Uri.AbsoluteUri
      try {
        Register-CimIndicationEvent `
          -ClassName Win32_ProcessStartTrace `
          -SourceIdentifier $processStartSourceIdentifier `
          -ErrorAction Stop | Out-Null
      }
      catch {
        throw "Win32_ProcessStartTrace is required for the $surfaceName recovery-blocked process observation: $($_.Exception.Message)"
      }
      $matchingSubscribers = @(Get-EventSubscriber -SourceIdentifier $processStartSourceIdentifier -ErrorAction Stop)
      Assert-True ($matchingSubscribers.Count -eq 1) "The $surfaceName recovery-blocked process-start subscription was not created exactly once."
      $processStartSubscriber = $matchingSubscribers[0]
      Start-Sleep -Milliseconds $ProcessStartEventSettlementMilliseconds

      if ($surfaceName -ceq "packaged-native") {
        $profileRoot = Join-Path $surfaceWorkRoot "profile"
        $workspaceRoot = Join-Path $surfaceWorkRoot "workspace"
        New-Item -ItemType Directory -Path $profileRoot, $workspaceRoot | Out-Null
        $probeResult = Invoke-BoundedProcess $nodeHost @(
          $packagedRecoveryBlockedProbeResolved,
          "--backend-module", $backendModulePath,
          "--daemon", $daemonResolved,
          "--bridge", $bridgeResolved,
          "--profile-root", $profileRoot,
          "--checkout-target", (Join-Path $workspaceRoot "checkout"),
          "--fault-repository-url", $faultRepositoryUrl,
          "--healthy-repository-url", $RepositoryUrl,
          "--unrelated-repository-url", $proxiedUnrelatedRepositoryUrl,
          "--unrelated-checkout-target", $unrelatedCheckoutTarget,
          "--fault-state-path", $fixtureStatePath,
          "--origin-operation-id", ([Guid]::NewGuid().ToString("D")),
          "--origin-timeout-ms", "5000",
          "--healthy-timeout-ms", "300000",
          "--checkout-revision", "3"
        ) 360 @{ ELECTRON_RUN_AS_NODE = "1" }
      }
      else {
        $installedFixtureRoot = Join-Path $surfaceWorkRoot "e"
        $probeResult = Invoke-BoundedProcess (Get-Process -Id $PID).Path @(
          "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
          "-File", $installedRecoveryBlockedProbeResolved,
          "-VsixPath", $vsixResolved,
          "-CodeCliPath", $codeCliResolved,
          "-FixtureRoot", $installedFixtureRoot,
          "-FaultRepositoryUrl", $faultRepositoryUrl,
          "-HealthyRepositoryUrl", $RepositoryUrl,
          "-UnrelatedRepositoryUrl", $proxiedUnrelatedRepositoryUrl,
          "-UnrelatedTargetPath", $unrelatedCheckoutTarget,
          "-FaultFixtureStatePath", $fixtureStatePath,
          "-OriginOperationId", ([Guid]::NewGuid().ToString("D")),
          "-RetryOperationId", ([Guid]::NewGuid().ToString("D")),
          "-FreshOperationId", ([Guid]::NewGuid().ToString("D")),
          "-OperationTimeoutMilliseconds", "5000",
          "-ExpectedProductVersion", $ExpectedProductVersion,
          "-DaemonPath", $daemonResolved,
          "-BridgePath", $bridgeResolved,
          "-TimeoutSeconds", "300"
        ) 420
      }
      $probeFailure = $probeResult.Stderr.Trim()
      Assert-True (
        $probeResult.ExitCode -eq 0 -and $probeResult.Stderr.Length -eq 0
      ) "The $surfaceName recovery-blocked probe failed: $probeFailure"
      $probeReport = Convert-JsonObject $probeResult.Stdout.Trim() "$surfaceName recovery-blocked probe stdout"
      Assert-True (
        [string]$probeReport.status -ceq "passed" -and
        [string]$probeReport.cell -ceq "recoveryBlocked" -and
        [string]$probeReport.originCode -ceq "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT" -and
        [string]$probeReport.originReason -ceq "operationDeadlineExceeded" -and
        [string]$probeReport.settlementCode -ceq "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED" -and
        [string]$probeReport.settlementReason -ceq "remoteRecoveryBlocked" -and
        [int]$probeReport.protocol.major -eq 1 -and [int]$probeReport.protocol.minor -eq 35 -and
        $probeReport.armedWindowObserved -eq $true -and
        $probeReport.unrelatedRepositoryServed -eq $true -and
        $probeReport.blockedEntryUnchangedAfterUnrelated -eq $true -and
        $probeReport.blockedJournalUnchangedAfterUnrelated -eq $true -and
        [string]$probeReport.blockedJournalBytesSha256BeforeUnrelated -cmatch '^[0-9a-f]{64}$' -and
        [string]$probeReport.blockedJournalBytesSha256AfterUnrelated -ceq [string]$probeReport.blockedJournalBytesSha256BeforeUnrelated -and
        [int]$probeReport.unrelatedCheckoutRevision -eq 2 -and
        [string]$probeReport.unrelatedTargetPathSha256 -ceq (Get-TextSha256 $unrelatedCheckoutTarget) -and
        $probeReport.fixtureCountersUnchangedOnBlockedRetry -eq $true -and
        [string]$probeReport.targetDisposition -ceq "confirmedAbsent" -and
        [int]$probeReport.temporaryRootsAfter -eq 0 -and
        $probeReport.diagnosticsRedacted -eq $true
      ) "The $surfaceName recovery-blocked report was incomplete."
      if ($surfaceName -ceq "packaged-native") {
        Assert-True (
          [string]$probeReport.schema -ceq "subversionr.release.m8-i6-packaged-native-recovery-blocked.v1" -and
          $probeReport.remoteSvnAnonymous -eq $true -and
          [int]$probeReport.credentialRequests -eq 0 -and [int]$probeReport.credentialSettlements -eq 0 -and
          [int]$probeReport.fixtureCliInvocations -eq 0
        ) "The packaged-native recovery-blocked report identity was invalid."
      }
      else {
        Assert-True (
          [string]$probeReport.schema -ceq "subversionr.release.m8-i6-installed-vsix-recovery-blocked.v1" -and
          [string]$probeReport.surface -ceq "installed-vsix-extension-host" -and
          [int]$probeReport.authActivity.credentialRequests -eq 0 -and
          [int]$probeReport.authActivity.credentialSettlements -eq 0 -and
          [int]$probeReport.authActivity.certificateRequests -eq 0 -and
          [int]$probeReport.checkoutJournalEntriesAfter -eq 0 -and
          $probeReport.candidateDaemonExitedAfter -eq $true
        ) "The installed VSIX recovery-blocked report identity was invalid."
      }
      Assert-ExactProperties $probeReport.blocked @(
        "outcome", "stableCode", "reason", "restartRestoredBlocked", "automaticClear",
        "requiredConfirmation", "armedTargetPathSha256", "confirmedTargetPathSha256",
        "armedOriginOperationIdSha256", "confirmedOriginOperationIdSha256",
        "confirmedEntryRemoved", "subsequentCheckoutPassed"
      ) "$surfaceName candidate recovery-blocked observation"
      Assert-True (
        [string]$probeReport.blocked.outcome -ceq "Blocked" -and
        [string]$probeReport.blocked.stableCode -ceq "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED" -and
        [string]$probeReport.blocked.reason -ceq "remoteRecoveryBlocked" -and
        $probeReport.blocked.restartRestoredBlocked -eq $true -and
        $probeReport.blocked.automaticClear -eq $false -and
        [string]$probeReport.blocked.requiredConfirmation -ceq "reviewedAndResolved" -and
        [string]$probeReport.blocked.armedTargetPathSha256 -cmatch '^[0-9a-f]{64}$' -and
        [string]$probeReport.blocked.confirmedTargetPathSha256 -ceq [string]$probeReport.blocked.armedTargetPathSha256 -and
        [string]$probeReport.blocked.armedOriginOperationIdSha256 -cmatch '^[0-9a-f]{64}$' -and
        [string]$probeReport.blocked.confirmedOriginOperationIdSha256 -ceq [string]$probeReport.blocked.armedOriginOperationIdSha256 -and
        $probeReport.blocked.confirmedEntryRemoved -eq $true -and
        $probeReport.blocked.subsequentCheckoutPassed -eq $true
      ) "The $surfaceName recovery-blocked settlement was incomplete or cross-attributed."

      $faultState = Get-Content -Raw -LiteralPath $fixtureStatePath | ConvertFrom-Json -Depth 16
      Assert-True (
        [int]$faultState.port -eq $faultFixture.State.port -and
        [string]$faultState.scenario -ceq "command-stall" -and
        [int]$faultState.connections -eq 1 -and [int]$faultState.greetingSent -eq 1 -and
        [int]$faultState.clientResponseReceived -eq 1 -and [int]$faultState.authRequestSent -eq 1 -and
        [int]$faultState.reposInfoSent -eq 1 -and [int]$faultState.commandsReceived -eq 1 -and
        [int]$faultState.followupContacts -eq 0 -and [int]$faultState.suppliedAuthorityConnections -eq 0
      ) "The $surfaceName recovery-blocked command-stage network observation was invalid."
      $unrelatedProxyAfter = Read-CountingProxyState $unrelatedProxyStatePath $unrelatedProxy.Process $true
      Assert-True (
        [int64]$unrelatedProxyAfter.acceptedConnections -eq 1 -and
        [int64]$unrelatedProxyAfter.upstreamAttempts -eq 1 -and
        [int64]$unrelatedProxyAfter.upstreamConnections -eq 1 -and
        [int64]$unrelatedProxyAfter.clientToUpstreamBytes -gt 0 -and
        [int64]$unrelatedProxyAfter.upstreamToClientBytes -gt 0 -and
        [int]$unrelatedProxyAfter.activeConnections -eq 0 -and
        [int]$unrelatedProxyAfter.upstreamConnectFailures -eq 0
      ) "The $surfaceName unrelated repository proxy observation was invalid."
      Complete-ProcessStartEventDrain $processStartSourceIdentifier $processStartEvents $processStartEventKeys $ProcessStartEventSettlementMilliseconds
      $processObservation = Get-RecoveryBlockedProcessObservation `
        -AllEvents @($processStartEvents) `
        -ProbePid ([long]$probeResult.ProcessId) `
        -ExpectedProbeProcessName $(if ($surfaceName -ceq "packaged-native") { [System.IO.Path]::GetFileName($nodeHost) } else { [System.IO.Path]::GetFileName((Get-Process -Id $PID).Path) }) `
        -ExpectedDaemonProcessName ([System.IO.Path]::GetFileName($daemonResolved)) `
        -ForbiddenFixtureProcessNames @(
          [System.IO.Path]::GetFileName($svnResolved),
          [System.IO.Path]::GetFileName($svnadminResolved),
          [System.IO.Path]::GetFileName($svnserveResolved)
        ) `
        -SettlementSnapshot (Get-CimProcessSnapshot) `
        -Context "$surfaceName recovery-blocked"
      Assert-True ([int]$processObservation.fixtureCliInvocations -eq 0) "The $surfaceName recovery-blocked product surface invoked a fixture CLI."
      $recoveryBlockedObservations += [pscustomobject]@{
        surface = $surfaceName
        originCode = [string]$probeReport.originCode
        originReason = [string]$probeReport.originReason
        settlementCode = [string]$probeReport.settlementCode
        settlementReason = [string]$probeReport.settlementReason
        networkProgress = "command"
        networkAttempts = [int]$faultState.connections
        networkConnections = [int]$faultState.connections
        fixtureCliInvocations = [int]$processObservation.fixtureCliInvocations
        credentialRequests = if ($surfaceName -ceq "packaged-native") { [int]$probeReport.credentialRequests } else { [int]$probeReport.authActivity.credentialRequests }
        credentialSettlements = if ($surfaceName -ceq "packaged-native") { [int]$probeReport.credentialSettlements } else { [int]$probeReport.authActivity.credentialSettlements }
        followupNetworkContacts = [int]$faultState.followupContacts
        workerDescendantsAfter = [int]$processObservation.workerDescendantsAfter
        temporaryRootsAfter = [int]$probeReport.temporaryRootsAfter
        diagnosticsRedacted = [bool]$probeReport.diagnosticsRedacted
      }
      $recoveryBlockedSettlementObservations += [pscustomobject]@{
        surface = $surfaceName
        blocked = $probeReport.blocked
      }
      $unrelatedRepositoryObservations += [pscustomobject]@{
        surface = $surfaceName
        originCode = "none"
        originReason = "none"
        settlementCode = "none"
        settlementReason = "none"
        networkProgress = "command"
        networkAttempts = [int]$unrelatedProxyAfter.upstreamAttempts
        networkConnections = [int]$unrelatedProxyAfter.upstreamConnections
        fixtureCliInvocations = [int]$processObservation.fixtureCliInvocations
        credentialRequests = if ($surfaceName -ceq "packaged-native") { [int]$probeReport.credentialRequests } else { [int]$probeReport.authActivity.credentialRequests }
        credentialSettlements = if ($surfaceName -ceq "packaged-native") { [int]$probeReport.credentialSettlements } else { [int]$probeReport.authActivity.credentialSettlements }
        followupNetworkContacts = 0
        workerDescendantsAfter = [int]$processObservation.workerDescendantsAfter
        temporaryRootsAfter = [int]$probeReport.temporaryRootsAfter
        diagnosticsRedacted = [bool]$probeReport.diagnosticsRedacted
      }
    }
    finally {
      if ($null -ne $processStartSubscriber) {
        Unregister-Event -SubscriptionId $processStartSubscriber.SubscriptionId -ErrorAction SilentlyContinue
      }
      Get-Event -SourceIdentifier $processStartSourceIdentifier -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
      try {
        if ($null -ne $unrelatedProxy) {
          $unrelatedProxyFinal = Stop-CountingProxy $unrelatedProxy
          if ($null -ne $unrelatedProxyAfter) {
            foreach ($counterName in @(
                "acceptedConnections", "upstreamAttempts", "upstreamConnections",
                "clientToUpstreamBytes", "upstreamToClientBytes", "upstreamConnectFailures"
              )) {
              Assert-True ([int64]$unrelatedProxyFinal.$counterName -eq [int64]$unrelatedProxyAfter.$counterName) "The stopped $surfaceName unrelated counting proxy changed final counter '$counterName'."
            }
          }
          Assert-True ([int]$unrelatedProxyFinal.activeConnections -eq 0) "The stopped $surfaceName unrelated counting proxy retained an active connection."
        }
      }
      finally {
        if ($null -ne $faultFixture) { Stop-FaultFixture $faultFixture "command-stall" }
      }
    }
  }
}
finally {
  if (Test-Path -LiteralPath $recoveryBlockedWorkRoot) {
    Assert-True (Test-PathWithin $recoveryBlockedWorkRoot $repoTargetRoot) "The recovery-blocked cleanup root escaped repo target."
    Remove-Item -LiteralPath $recoveryBlockedWorkRoot -Recurse -Force
  }
  Assert-True (-not (Test-Path -LiteralPath $recoveryBlockedWorkRoot)) "The recovery-blocked short work root remained after cleanup."
}
Assert-True ($recoveryBlockedObservations.Count -eq 2) "The packaged-native and installed VSIX recovery-blocked observation set was incomplete."
Assert-True ($recoveryBlockedSettlementObservations.Count -eq 2) "The packaged-native and installed VSIX blocked settlement set was incomplete."
Assert-True ($unrelatedRepositoryObservations.Count -eq 2) "The packaged-native and installed VSIX unrelated-repository observation set was incomplete."

$redactionWorkRoot = [System.IO.Path]::GetFullPath((Join-Path $repoTargetRoot "i6x\$([Guid]::NewGuid().ToString('N').Substring(0, 8))"))
Assert-True (Test-PathWithin $redactionWorkRoot $repoTargetRoot) "The redaction short work root escaped repo target."
Assert-True ($redactionWorkRoot.Length -le 120) "The redaction short work root exceeds the reviewed 120-character budget."
Assert-True (-not (Test-Path -LiteralPath $redactionWorkRoot)) "The redaction short work root already exists."
New-Item -ItemType Directory -Path $redactionWorkRoot | Out-Null
$redactionObservations = @()
$redactionPrivacyObservations = @()
try {
  $redactionContracts = @(
    [pscustomobject]@{ Surface = "packaged-native"; WorkRoot = "p" },
    [pscustomobject]@{ Surface = "installed-vsix-extension-host"; WorkRoot = "i" }
  )
  foreach ($contract in $redactionContracts) {
    $surfaceName = [string]$contract.Surface
    $surfaceWorkRoot = Join-Path $redactionWorkRoot ([string]$contract.WorkRoot)
    $surfaceProbeRoot = Join-Path $probeRoot "redaction-$surfaceName"
    $profileRoot = Join-Path $surfaceWorkRoot "profile"
    $checkoutTarget = Join-Path $surfaceWorkRoot "checkout"
    $proxyStatePath = Join-Path $surfaceProbeRoot "proxy-state.json"
    New-Item -ItemType Directory -Force -Path $surfaceWorkRoot, $surfaceProbeRoot | Out-Null
    Assert-True ($checkoutTarget.Length -le 120) "The $surfaceName redaction checkout target exceeds the reviewed 120-character budget."
    Assert-True (-not (Test-Path -LiteralPath $profileRoot)) "The $surfaceName redaction profile root already existed."
    Assert-True (-not (Test-Path -LiteralPath $checkoutTarget)) "The $surfaceName redaction checkout target already existed."
    $proxy = $null
    $proxyAfter = $null
    $processStartSourceIdentifier = "subversionr-m8-i6-redaction-$([Guid]::NewGuid().ToString('N'))"
    $processStartSubscriber = $null
    $processStartEvents = [System.Collections.Generic.List[object]]::new()
    $processStartEventKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    try {
      $surfaceDaemonPath = if ($surfaceName -ceq "packaged-native") { $packagedVsixDaemonPath } else { $daemonResolved }
      $surfaceBridgePath = if ($surfaceName -ceq "packaged-native") { $packagedVsixBridgePath } else { $bridgeResolved }
      Assert-CandidateProcessAbsent $surfaceDaemonPath "The $surfaceName redaction preflight"
      $proxy = Start-CountingProxy $nodeHost $countingProxyResolved $repositoryUri.Port $proxyStatePath
      $proxyBaseline = Read-CountingProxyState $proxyStatePath $proxy.Process $true
      foreach ($counterName in @(
          "acceptedConnections", "upstreamAttempts", "upstreamConnections",
          "clientToUpstreamBytes", "upstreamToClientBytes", "activeConnections", "upstreamConnectFailures"
        )) {
        Assert-True ([int64]$proxyBaseline.$counterName -eq 0) "The $surfaceName redaction counting proxy did not begin at zero for '$counterName'."
      }
      $proxyUriBuilder = [System.UriBuilder]::new($repositoryUri)
      $proxyUriBuilder.Port = [int]$proxy.State.port
      $proxiedRepositoryUrl = $proxyUriBuilder.Uri.AbsoluteUri
      try {
        Register-CimIndicationEvent `
          -ClassName Win32_ProcessStartTrace `
          -SourceIdentifier $processStartSourceIdentifier `
          -ErrorAction Stop | Out-Null
      }
      catch {
        throw "Win32_ProcessStartTrace is required for the $surfaceName redaction process observation: $($_.Exception.Message)"
      }
      $matchingSubscribers = @(Get-EventSubscriber -SourceIdentifier $processStartSourceIdentifier -ErrorAction Stop)
      Assert-True ($matchingSubscribers.Count -eq 1) "The $surfaceName redaction process-start subscription was not created exactly once."
      $processStartSubscriber = $matchingSubscribers[0]
      Start-Sleep -Milliseconds $ProcessStartEventSettlementMilliseconds

      if ($surfaceName -ceq "packaged-native") {
        $diagnosticToken = [Guid]::NewGuid().ToString("D")
        $probeResult = Invoke-BoundedProcess $nodeHost @(
          $packagedRedactionProbeResolved,
          "--daemon-path", $surfaceDaemonPath,
          "--bridge-path", $surfaceBridgePath,
          "--profile-root", $profileRoot,
          "--repository-url", $proxiedRepositoryUrl,
          "--checkout-target", $checkoutTarget,
          "--diagnostic-token", $diagnosticToken,
          "--expected-revision", "3",
          "--expected-product-version", $ExpectedProductVersion
        ) 360 @{ ELECTRON_RUN_AS_NODE = "1" }
      }
      else {
        $diagnosticToken = Get-TextSha256 ([Guid]::NewGuid().ToString("D"))
        $probeResult = Invoke-BoundedProcess (Get-Process -Id $PID).Path @(
          "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
          "-File", $installedRedactionProbeResolved,
          "-VsixPath", $vsixResolved,
          "-CodeCliPath", $codeCliResolved,
          "-FixtureRoot", $profileRoot,
          "-RepositoryUrl", $proxiedRepositoryUrl,
          "-CheckoutTarget", $checkoutTarget,
          "-DiagnosticToken", $diagnosticToken,
          "-ExpectedRevision", "3",
          "-ExpectedProductVersion", $ExpectedProductVersion,
          "-DaemonPath", $daemonResolved,
          "-BridgePath", $bridgeResolved,
          "-TimeoutSeconds", "300"
        ) 420
      }
      $probeFailure = $probeResult.Stderr.Trim()
      Assert-True (
        $probeResult.ExitCode -eq 0 -and $probeResult.Stderr.Length -eq 0
      ) "The $surfaceName redaction probe failed: $probeFailure"
      $probeReport = Convert-JsonObject $probeResult.Stdout.Trim() "$surfaceName redaction probe stdout"
      if ($surfaceName -ceq "packaged-native") {
        $cellReport = $probeReport
        $credentialRequests = [int]$cellReport.credentialRequests
        $credentialSettlements = [int]$cellReport.credentialSettlements
        $temporaryRootsAfter = [int]$cellReport.temporaryRootsAfter
        Assert-True (
          [string]$cellReport.schema -ceq "subversionr.release.m8-i6-packaged-redaction.v1" -and
          [string]$cellReport.surface -ceq $surfaceName -and
          $cellReport.remoteSvnAnonymous -eq $true -and
          [int]$cellReport.certificateRequests -eq 0
        ) "The packaged-native redaction report identity was invalid."
      }
      else {
        Assert-ExactProperties $probeReport @(
          "schema", "status", "report", "workingCopyDatabaseBytes", "candidateProcessesAfter",
          "temporaryRootsAfter", "checkoutJournalEntriesAfter", "journalTemporaryFilesAfter",
          "extensionInstalledAfterCleanup", "fixtureRemovedAfterCleanup", "diagnosticsRedacted"
        ) "installed VSIX redaction wrapper report"
        Assert-True (
          [string]$probeReport.schema -ceq "subversionr.release.m8-i6-installed-vsix-redaction-wrapper.v1" -and
          [string]$probeReport.status -ceq "passed" -and
          [int64]$probeReport.workingCopyDatabaseBytes -gt 0 -and
          [int]$probeReport.candidateProcessesAfter -eq 0 -and
          [int]$probeReport.temporaryRootsAfter -eq 0 -and
          [int]$probeReport.checkoutJournalEntriesAfter -eq 0 -and
          [int]$probeReport.journalTemporaryFilesAfter -eq 0 -and
          $probeReport.extensionInstalledAfterCleanup -eq $false -and
          $probeReport.fixtureRemovedAfterCleanup -eq $true -and
          $probeReport.diagnosticsRedacted -eq $true
        ) "The installed VSIX redaction wrapper report was invalid."
        $cellReport = $probeReport.report
        $credentialRequests = [int]$cellReport.authActivity.credentialRequests
        $credentialSettlements = [int]$cellReport.authActivity.credentialSettlements
        $temporaryRootsAfter = [int]$probeReport.temporaryRootsAfter
        Assert-True (
          [string]$cellReport.schema -ceq "subversionr.release.m8-i6-installed-vsix-redaction.v1" -and
          [int]$cellReport.schemaVersion -eq 1 -and
          [string]$cellReport.kind -ceq "subversionr.installedSvnAnonymousRedactionReport" -and
          [string]$cellReport.surface -ceq $surfaceName -and
          [int]$cellReport.authActivity.certificateRequests -eq 0 -and
          [string]$cellReport.redaction.paths -ceq "redacted" -and
          [string]$cellReport.redaction.urls -ceq "redacted" -and
          [string]$cellReport.redaction.secrets -ceq "redacted"
        ) "The installed VSIX redaction product report identity was invalid."
      }
      Assert-True (
        [string]$cellReport.status -ceq "passed" -and
        [string]$cellReport.cell -ceq "redaction" -and
        [int]$cellReport.protocol.major -eq 1 -and [int]$cellReport.protocol.minor -eq 35 -and
        [int]$cellReport.checkoutRevision -eq 3 -and
        [string]$cellReport.targetPathSha256 -ceq (Get-TextSha256 $checkoutTarget) -and
        $cellReport.inputContainedRawUrl -eq $true -and
        $cellReport.inputContainedRawPath -eq $true -and
        $cellReport.inputContainedRawToken -eq $true -and
        [int]$cellReport.rawUrlCount -eq 0 -and
        [int]$cellReport.rawPathCount -eq 0 -and
        [int]$cellReport.secretTokenCount -eq 0 -and
        [int]$cellReport.urlMarkerCount -ge 1 -and
        [int]$cellReport.pathMarkerCount -ge 1 -and
        [int]$cellReport.secretMarkerCount -ge 1 -and
        [int]$cellReport.maxDiagnosticBytes -gt 0 -and
        [int]$cellReport.maxDiagnosticBytes -le 32768 -and
        $cellReport.boundedDiagnostics -eq $true -and
        $cellReport.diagnosticsRedacted -eq $true -and
        $credentialRequests -eq 0 -and $credentialSettlements -eq 0 -and
        $temporaryRootsAfter -eq 0
      ) "The $surfaceName redaction report was incomplete."
      $wcDbPath = Join-Path $checkoutTarget ".svn\wc.db"
      Assert-True (Test-Path -LiteralPath $wcDbPath -PathType Leaf) "The $surfaceName redaction checkout did not create a working-copy database."
      Assert-True ((Get-Item -LiteralPath $wcDbPath).Length -gt 0) "The $surfaceName redaction working-copy database was empty."

      $proxyAfter = Read-CountingProxyState $proxyStatePath $proxy.Process $true
      Assert-True (
        [int64]$proxyAfter.acceptedConnections -eq 1 -and
        [int64]$proxyAfter.upstreamAttempts -eq 1 -and
        [int64]$proxyAfter.upstreamConnections -eq 1 -and
        [int64]$proxyAfter.clientToUpstreamBytes -gt 0 -and
        [int64]$proxyAfter.upstreamToClientBytes -gt 0 -and
        [int]$proxyAfter.activeConnections -eq 0 -and
        [int]$proxyAfter.upstreamConnectFailures -eq 0
      ) "The $surfaceName redaction counting proxy observation was invalid."
      Complete-ProcessStartEventDrain $processStartSourceIdentifier $processStartEvents $processStartEventKeys $ProcessStartEventSettlementMilliseconds
      if ($surfaceName -ceq "packaged-native") {
        $processObservation = Get-PackagedNegativeProcessObservation `
          -AllEvents @($processStartEvents) `
          -ProbePid ([long]$probeResult.ProcessId) `
          -ExpectedProbeProcessName ([System.IO.Path]::GetFileName($nodeHost)) `
          -ExpectedDaemonProcessName ([System.IO.Path]::GetFileName($surfaceDaemonPath)) `
          -ForbiddenFixtureProcessNames @(
            [System.IO.Path]::GetFileName($svnResolved),
            [System.IO.Path]::GetFileName($svnadminResolved),
            [System.IO.Path]::GetFileName($svnserveResolved)
          ) `
          -SettlementSnapshot (Get-CimProcessSnapshot)
      }
      else {
        $processObservation = Get-InstalledNegativeProcessObservation `
          -AllEvents @($processStartEvents) `
          -ProbePid ([long]$probeResult.ProcessId) `
          -ExpectedProbeProcessName ([System.IO.Path]::GetFileName((Get-Process -Id $PID).Path)) `
          -ExpectedDaemonProcessName ([System.IO.Path]::GetFileName($surfaceDaemonPath)) `
          -ForbiddenFixtureProcessNames @(
            [System.IO.Path]::GetFileName($svnResolved),
            [System.IO.Path]::GetFileName($svnadminResolved),
            [System.IO.Path]::GetFileName($svnserveResolved)
          ) `
          -SettlementSnapshot (Get-CimProcessSnapshot)
      }
      Assert-True ([int]$processObservation.fixtureCliInvocations -eq 0) "The $surfaceName redaction product surface invoked a fixture CLI."
      $redactionObservations += [pscustomobject]@{
        surface = $surfaceName
        originCode = "none"
        originReason = "none"
        settlementCode = "none"
        settlementReason = "none"
        networkProgress = "command"
        networkAttempts = [int]$proxyAfter.upstreamAttempts
        networkConnections = [int]$proxyAfter.upstreamConnections
        fixtureCliInvocations = [int]$processObservation.fixtureCliInvocations
        credentialRequests = $credentialRequests
        credentialSettlements = $credentialSettlements
        followupNetworkContacts = 0
        workerDescendantsAfter = [int]$processObservation.workerDescendantsAfter
        temporaryRootsAfter = $temporaryRootsAfter
        diagnosticsRedacted = [bool]$cellReport.diagnosticsRedacted
      }
      $redactionPrivacyObservations += [pscustomobject]@{
        surface = $surfaceName
        rawUrlCount = [int]$cellReport.rawUrlCount
        rawPathCount = [int]$cellReport.rawPathCount
        secretTokenCount = [int]$cellReport.secretTokenCount
        maxDiagnosticBytes = [int]$cellReport.maxDiagnosticBytes
        boundedDiagnostics = [bool]$cellReport.boundedDiagnostics
      }
    }
    finally {
      if ($null -ne $processStartSubscriber) {
        Unregister-Event -SubscriptionId $processStartSubscriber.SubscriptionId -ErrorAction SilentlyContinue
      }
      Get-Event -SourceIdentifier $processStartSourceIdentifier -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
      if ($null -ne $proxy) {
        $proxyFinal = Stop-CountingProxy $proxy
        if ($null -ne $proxyAfter) {
          foreach ($counterName in @(
              "acceptedConnections", "upstreamAttempts", "upstreamConnections",
              "clientToUpstreamBytes", "upstreamToClientBytes", "upstreamConnectFailures"
            )) {
            Assert-True ([int64]$proxyFinal.$counterName -eq [int64]$proxyAfter.$counterName) "The stopped $surfaceName redaction counting proxy changed final counter '$counterName'."
          }
        }
        Assert-True ([int]$proxyFinal.activeConnections -eq 0) "The stopped $surfaceName redaction counting proxy retained an active connection."
      }
    }
  }
}
finally {
  if (Test-Path -LiteralPath $redactionWorkRoot) {
    Assert-True (Test-PathWithin $redactionWorkRoot $repoTargetRoot) "The redaction cleanup root escaped repo target."
    Remove-Item -LiteralPath $redactionWorkRoot -Recurse -Force
  }
  Assert-True (-not (Test-Path -LiteralPath $redactionWorkRoot)) "The redaction short work root remained after cleanup."
}
Assert-True ($redactionObservations.Count -eq 2) "The packaged-native and installed VSIX redaction observation set was incomplete."
Assert-True ($redactionPrivacyObservations.Count -eq 2) "The packaged-native and installed VSIX redaction privacy set was incomplete."

$recoverySafeWorkRoot = [System.IO.Path]::GetFullPath((Join-Path $repoTargetRoot "i6s\$([Guid]::NewGuid().ToString('N').Substring(0, 8))"))
Assert-True (Test-PathWithin $recoverySafeWorkRoot $repoTargetRoot) "The recovery-safe short work root escaped repo target."
Assert-True ($recoverySafeWorkRoot.Length -le 120) "The recovery-safe short work root exceeds the reviewed 120-character budget."
Assert-True (-not (Test-Path -LiteralPath $recoverySafeWorkRoot)) "The recovery-safe short work root already exists."
New-Item -ItemType Directory -Path $recoverySafeWorkRoot | Out-Null
$recoverySafeObservations = @()
$recoverySafeSettlementObservations = @()
try {
  Stop-ControlledSvnserve $svnserveResolved $SvnservePid $SvnserveStartTimeUtc
  $recoverySafeContracts = @(
    [pscustomobject]@{ Surface = "packaged-native"; WorkRoot = "p"; WorkingCopy = $packagedAuthzWorkingCopyResolved },
    [pscustomobject]@{ Surface = "installed-vsix-extension-host"; WorkRoot = "i"; WorkingCopy = $installedAuthzWorkingCopyResolved }
  )
  foreach ($contract in $recoverySafeContracts) {
    $surfaceName = [string]$contract.Surface
    $surfaceRoot = Join-Path $probeRoot "recovery-safe-$surfaceName"
    $surfaceWorkRoot = Join-Path $recoverySafeWorkRoot ([string]$contract.WorkRoot)
    $fixtureStatePath = Join-Path $surfaceRoot "fixture-state.json"
    $originOperationId = [Guid]::NewGuid().ToString("D")
    $recoveryOperationId = [Guid]::NewGuid().ToString("D")
    Assert-True (-not $originOperationId.Equals($recoveryOperationId, [System.StringComparison]::Ordinal)) "The $surfaceName recovery-safe operation IDs must be distinct."
    New-Item -ItemType Directory -Force -Path $surfaceRoot | Out-Null
    if ($surfaceName -ceq "packaged-native") {
      New-Item -ItemType Directory -Path $surfaceWorkRoot | Out-Null
    }
    else {
      Assert-True (-not (Test-Path -LiteralPath $surfaceWorkRoot)) "The installed recovery-safe fixture root already existed."
    }
    Assert-CandidateProcessAbsent $daemonResolved "The $surfaceName recovery-safe preflight"
    $faultFixture = $null
    $processStartSourceIdentifier = "subversionr-m8-i6-recovery-safe-$([Guid]::NewGuid().ToString('N'))"
    $processStartSubscriber = $null
    $processStartEvents = [System.Collections.Generic.List[object]]::new()
    $processStartEventKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    try {
      $faultFixture = Start-FaultFixture $nodeHost $faultFixtureResolved "command-stall" $fixtureStatePath $repositoryUri.Port
      try {
        Register-CimIndicationEvent `
          -ClassName Win32_ProcessStartTrace `
          -SourceIdentifier $processStartSourceIdentifier `
          -ErrorAction Stop | Out-Null
      }
      catch {
        throw "Win32_ProcessStartTrace is required for the $surfaceName recovery-safe process observation: $($_.Exception.Message)"
      }
      $matchingSubscribers = @(Get-EventSubscriber -SourceIdentifier $processStartSourceIdentifier -ErrorAction Stop)
      Assert-True ($matchingSubscribers.Count -eq 1) "The $surfaceName recovery-safe process-start subscription was not created exactly once."
      $processStartSubscriber = $matchingSubscribers[0]
      Start-Sleep -Milliseconds $ProcessStartEventSettlementMilliseconds

      if ($surfaceName -ceq "packaged-native") {
        $probeResult = Invoke-BoundedProcess $nodeHost @(
          $packagedRecoverySafeProbeResolved,
          "--backend-module", $backendModulePath,
          "--daemon", $daemonResolved,
          "--bridge", $bridgeResolved,
          "--profile-root", $surfaceWorkRoot,
          "--working-copy-path", ([string]$contract.WorkingCopy),
          "--repository-url", $RepositoryUrl,
          "--fixture-state-path", $fixtureStatePath,
          "--origin-operation-id", $originOperationId,
          "--recovery-operation-id", $recoveryOperationId,
          "--origin-timeout-ms", "500",
          "--recovery-timeout-ms", "300000"
        ) 360 @{ ELECTRON_RUN_AS_NODE = "1" }
        $probeFailure = $probeResult.Stderr.Trim()
        Assert-True ($probeResult.ExitCode -eq 0 -and $probeResult.Stderr.Length -eq 0) "The packaged-native recovery-safe probe failed: $probeFailure"
        $probeReport = Convert-JsonObject $probeResult.Stdout.Trim() "packaged-native recovery-safe probe stdout"
        Assert-True (
          [string]$probeReport.schema -ceq "subversionr.release.m8-i6-packaged-native-recovery-safe.v1" -and
          [string]$probeReport.status -ceq "passed" -and [string]$probeReport.cell -ceq "recoverySafe" -and
          [string]$probeReport.surface -ceq "packaged-native" -and
          [string]$probeReport.stableCode -ceq "none" -and [string]$probeReport.reason -ceq "none" -and
          [string]$probeReport.settlementCode -ceq "none" -and [string]$probeReport.settlementReason -ceq "none" -and
          [int]$probeReport.protocol.major -eq 1 -and [int]$probeReport.protocol.minor -eq 35 -and
          $probeReport.remoteSvnAnonymous -eq $true -and [int]$probeReport.networkAttempts -eq 1 -and
          [int]$probeReport.networkConnections -eq 1 -and [int]$probeReport.followupNetworkContacts -eq 0 -and
          [int]$probeReport.temporaryRootsAfter -eq 0 -and [int]$probeReport.journalEntriesAfter -eq 0 -and
          [int]$probeReport.journalTemporaryFilesAfter -eq 0 -and $probeReport.workingCopyContentPreserved -eq $true -and
          [int64]$probeReport.workingCopyDatabaseBytes -gt 0 -and $probeReport.diagnosticsRedacted -eq $true
        ) "The packaged-native recovery-safe report was incomplete."
        Assert-True ((@($probeReport.transitions) -join ",") -ceq "pending,safe,unchecked") "The packaged-native recovery-safe transitions were invalid."
      }
      else {
        $probeResult = Invoke-BoundedProcess (Get-Process -Id $PID).Path @(
          "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
          "-File", $installedRecoverySafeProbeResolved,
          "-VsixPath", $vsixResolved,
          "-CodeCliPath", $codeCliResolved,
          "-FixtureRoot", $surfaceWorkRoot,
          "-WorkingCopyPath", ([string]$contract.WorkingCopy),
          "-RepositoryUrl", $RepositoryUrl,
          "-FixtureStatePath", $fixtureStatePath,
          "-OperationId", $originOperationId,
          "-OperationTimeoutMilliseconds", "500",
          "-ExpectedProductVersion", $ExpectedProductVersion,
          "-DaemonPath", $daemonResolved,
          "-BridgePath", $bridgeResolved,
          "-TimeoutSeconds", "300"
        ) 360
        $probeFailure = $probeResult.Stderr.Trim()
        Assert-True ($probeResult.ExitCode -eq 0 -and $probeResult.Stderr.Length -eq 0) "The installed VSIX recovery-safe probe failed: $probeFailure"
        $probeReport = Convert-JsonObject $probeResult.Stdout.Trim() "installed VSIX recovery-safe probe stdout"
        Assert-True (
          [string]$probeReport.schema -ceq "subversionr.release.m8-i6-installed-vsix-recovery-safe-wrapper.v1" -and
          [string]$probeReport.status -ceq "passed" -and [string]$probeReport.cell -ceq "recoverySafe" -and
          [string]$probeReport.surface -ceq "installed-vsix-extension-host" -and
          [int]$probeReport.protocol.major -eq 1 -and [int]$probeReport.protocol.minor -eq 35 -and
          [int]$probeReport.authActivity.credentialRequests -eq 0 -and [int]$probeReport.authActivity.credentialSettlements -eq 0 -and
          [int]$probeReport.authActivity.certificateRequests -eq 0 -and [int]$probeReport.temporaryRootsAfter -eq 0 -and
          [int]$probeReport.checkoutJournalEntriesAfter -eq 0 -and $probeReport.workingCopyContentPreserved -eq $true -and
          [int64]$probeReport.workingCopyDatabaseBytes -gt 0 -and $probeReport.candidateDaemonExitedAfter -eq $true -and
          $probeReport.extensionInstalledAfterCleanup -eq $false -and $probeReport.fixtureRemovedAfterCleanup -eq $true -and
          $probeReport.diagnosticsRedacted -eq $true
        ) "The installed VSIX recovery-safe report was incomplete."
        Assert-True ((@($probeReport.transitions) -join ",") -ceq "required,checking,safe") "The installed VSIX recovery-safe store transitions were invalid."
      }

      Assert-ExactProperties $probeReport.prerequisite @("code", "reason", "recovery") "$surfaceName recovery-safe prerequisite"
      Assert-True (
        [string]$probeReport.prerequisite.code -ceq "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT" -and
        [string]$probeReport.prerequisite.reason -ceq "operationDeadlineExceeded" -and
        [string]$probeReport.prerequisite.recovery -ceq "pending"
      ) "The $surfaceName recovery-safe prerequisite was invalid."
      Assert-ExactProperties $probeReport.safe @("outcome", "freshReconcile", "nativeLaneReleased", "subsequentRequestPassed") "$surfaceName recovery-safe settlement"
      Assert-True (
        [string]$probeReport.safe.outcome -ceq "Safe" -and $probeReport.safe.freshReconcile -eq $true -and
        $probeReport.safe.nativeLaneReleased -eq $true -and $probeReport.safe.subsequentRequestPassed -eq $true -and
        [string]$probeReport.statusStaleReason -ceq "remoteRecoverySafeRequiresFullReconcile"
      ) "The $surfaceName recovery-safe settlement proof was invalid."

      $faultState = Get-Content -Raw -LiteralPath $fixtureStatePath | ConvertFrom-Json -Depth 16
      Assert-True (
        [int]$faultState.port -eq $repositoryUri.Port -and [string]$faultState.scenario -ceq "command-stall" -and
        [int]$faultState.connections -eq 1 -and [int]$faultState.greetingSent -eq 1 -and
        [int]$faultState.clientResponseReceived -eq 1 -and [int]$faultState.authRequestSent -eq 1 -and
        [int]$faultState.reposInfoSent -eq 1 -and [int]$faultState.commandsReceived -eq 1 -and
        [int]$faultState.followupContacts -eq 0 -and [int]$faultState.suppliedAuthorityConnections -eq 0
      ) "The $surfaceName recovery-safe command-stage observation was invalid."
      Complete-ProcessStartEventDrain $processStartSourceIdentifier $processStartEvents $processStartEventKeys $ProcessStartEventSettlementMilliseconds
      $processObservation = Get-RecoverySafeProcessObservation `
        -AllEvents @($processStartEvents) `
        -ProbePid ([long]$probeResult.ProcessId) `
        -ExpectedProbeProcessName $(if ($surfaceName -ceq "packaged-native") { [System.IO.Path]::GetFileName($nodeHost) } else { [System.IO.Path]::GetFileName((Get-Process -Id $PID).Path) }) `
        -ExpectedDaemonProcessName ([System.IO.Path]::GetFileName($daemonResolved)) `
        -ForbiddenFixtureProcessNames @([System.IO.Path]::GetFileName($svnResolved), [System.IO.Path]::GetFileName($svnadminResolved), [System.IO.Path]::GetFileName($svnserveResolved)) `
        -SettlementSnapshot (Get-CimProcessSnapshot) `
        -Context "$surfaceName recovery-safe"
      Assert-True ([int]$processObservation.fixtureCliInvocations -eq 0) "The $surfaceName recovery-safe product surface invoked a fixture CLI."

      $recoverySafeObservations += [pscustomobject]@{
        surface = $surfaceName
        stableCode = "none"
        reason = "none"
        originCode = "none"
        originReason = "none"
        settlementCode = "none"
        settlementReason = "none"
        networkProgress = "command"
        networkAttempts = [int]$faultState.connections
        networkConnections = [int]$faultState.connections
        fixtureCliInvocations = [int]$processObservation.fixtureCliInvocations
        credentialRequests = if ($surfaceName -ceq "packaged-native") { [int]$probeReport.credentialRequests } else { [int]$probeReport.authActivity.credentialRequests }
        credentialSettlements = if ($surfaceName -ceq "packaged-native") { [int]$probeReport.credentialSettlements } else { [int]$probeReport.authActivity.credentialSettlements }
        followupNetworkContacts = [int]$faultState.followupContacts
        workerDescendantsAfter = [int]$processObservation.workerDescendantsAfter
        temporaryRootsAfter = [int]$probeReport.temporaryRootsAfter
        diagnosticsRedacted = [bool]$probeReport.diagnosticsRedacted
      }
      $recoverySafeSettlementObservations += [pscustomobject]@{
        surface = $surfaceName
        safe = $probeReport.safe
      }
    }
    finally {
      if ($null -ne $processStartSubscriber) {
        Unregister-Event -SubscriptionId $processStartSubscriber.SubscriptionId -ErrorAction SilentlyContinue
      }
      Get-Event -SourceIdentifier $processStartSourceIdentifier -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
      if ($null -ne $faultFixture) { Stop-FaultFixture $faultFixture "command-stall" }
    }
  }
}
finally {
  if (Test-Path -LiteralPath $recoverySafeWorkRoot) {
    Assert-True (Test-PathWithin $recoverySafeWorkRoot $repoTargetRoot) "The recovery-safe cleanup root escaped repo target."
    Remove-Item -LiteralPath $recoverySafeWorkRoot -Recurse -Force
  }
  Assert-True (-not (Test-Path -LiteralPath $recoverySafeWorkRoot)) "The recovery-safe short work root remained after cleanup."
}
Assert-True ($recoverySafeObservations.Count -eq 2) "The packaged-native and installed VSIX recovery-safe observation set was incomplete."
Assert-True ($recoverySafeSettlementObservations.Count -eq 2) "The packaged-native and installed VSIX Safe settlement set was incomplete."

$recoveryIndeterminateWorkRoot = [System.IO.Path]::GetFullPath((Join-Path $repoTargetRoot "i6i\$([Guid]::NewGuid().ToString('N').Substring(0, 8))"))
Assert-True (Test-PathWithin $recoveryIndeterminateWorkRoot $repoTargetRoot) "The recovery-indeterminate short work root escaped repo target."
Assert-True ($recoveryIndeterminateWorkRoot.Length -le 120) "The recovery-indeterminate short work root exceeds the reviewed 120-character budget."
Assert-True (-not (Test-Path -LiteralPath $recoveryIndeterminateWorkRoot)) "The recovery-indeterminate short work root already exists."
New-Item -ItemType Directory -Path $recoveryIndeterminateWorkRoot | Out-Null
$recoveryIndeterminateObservations = @()
$recoveryIndeterminateSettlementObservations = @()
try {
  $recoveryIndeterminateContracts = @(
    [pscustomobject]@{ Surface = "packaged-native"; WorkRoot = "p"; WorkingCopy = $packagedAuthzWorkingCopyResolved },
    [pscustomobject]@{ Surface = "installed-vsix-extension-host"; WorkRoot = "i"; WorkingCopy = $installedAuthzWorkingCopyResolved }
  )
  foreach ($contract in $recoveryIndeterminateContracts) {
    $surfaceName = [string]$contract.Surface
    $surfaceRoot = Join-Path $probeRoot "recovery-indeterminate-$surfaceName"
    $surfaceWorkRoot = Join-Path $recoveryIndeterminateWorkRoot ([string]$contract.WorkRoot)
    $workingCopyDatabasePath = Resolve-RequiredFile (Join-Path ([string]$contract.WorkingCopy) ".svn\wc.db") "$surfaceName recovery-indeterminate working-copy database"
    $workingCopyDatabaseBytesBefore = [int64](Get-Item -LiteralPath $workingCopyDatabasePath).Length
    Assert-True ($workingCopyDatabaseBytesBefore -gt 0) "The $surfaceName recovery-indeterminate working-copy database was empty before the probe."
    $fixtureStatePath = Join-Path $surfaceRoot "fixture-state.json"
    $originOperationId = [Guid]::NewGuid().ToString("D")
    $recoveryOperationId = [Guid]::NewGuid().ToString("D")
    Assert-True (-not $originOperationId.Equals($recoveryOperationId, [System.StringComparison]::Ordinal)) "The $surfaceName recovery-indeterminate operation IDs must be distinct."
    New-Item -ItemType Directory -Force -Path $surfaceRoot | Out-Null
    if ($surfaceName -ceq "packaged-native") {
      New-Item -ItemType Directory -Path $surfaceWorkRoot | Out-Null
    }
    else {
      Assert-True (-not (Test-Path -LiteralPath $surfaceWorkRoot)) "The installed recovery-indeterminate fixture root already existed."
    }
    Assert-CandidateProcessAbsent $daemonResolved "The $surfaceName recovery-indeterminate preflight"
    $faultFixture = $null
    $processStartSourceIdentifier = "subversionr-m8-i6-recovery-indeterminate-$([Guid]::NewGuid().ToString('N'))"
    $processStartSubscriber = $null
    $processStartEvents = [System.Collections.Generic.List[object]]::new()
    $processStartEventKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    try {
      $faultFixture = Start-FaultFixture $nodeHost $faultFixtureResolved "command-stall" $fixtureStatePath $repositoryUri.Port
      try {
        Register-CimIndicationEvent `
          -ClassName Win32_ProcessStartTrace `
          -SourceIdentifier $processStartSourceIdentifier `
          -ErrorAction Stop | Out-Null
      }
      catch {
        throw "Win32_ProcessStartTrace is required for the $surfaceName recovery-indeterminate process observation: $($_.Exception.Message)"
      }
      $matchingSubscribers = @(Get-EventSubscriber -SourceIdentifier $processStartSourceIdentifier -ErrorAction Stop)
      Assert-True ($matchingSubscribers.Count -eq 1) "The $surfaceName recovery-indeterminate process-start subscription was not created exactly once."
      $processStartSubscriber = $matchingSubscribers[0]
      Start-Sleep -Milliseconds $ProcessStartEventSettlementMilliseconds

      if ($surfaceName -ceq "packaged-native") {
        $probeResult = Invoke-BoundedProcessWithWorkingCopyReadFault `
          $nodeHost `
          @(
            $packagedRecoveryIndeterminateProbeResolved,
            "--backend-module", $backendModulePath,
            "--daemon", $daemonResolved,
            "--bridge", $bridgeResolved,
            "--profile-root", $surfaceWorkRoot,
            "--working-copy-path", ([string]$contract.WorkingCopy),
            "--repository-url", $RepositoryUrl,
            "--fixture-state-path", $fixtureStatePath,
            "--origin-operation-id", $originOperationId,
            "--recovery-operation-id", $recoveryOperationId,
            "--origin-timeout-ms", "5000",
            "--recovery-timeout-ms", "300000"
          ) `
          360 `
          @{ ELECTRON_RUN_AS_NODE = "1" } `
          $fixtureStatePath `
          $repositoryUri.Port `
          $workingCopyDatabasePath `
          "$surfaceName recovery-indeterminate"
        $probeFailure = $probeResult.Stderr.Trim()
        Assert-True ($probeResult.ExitCode -eq 0 -and $probeResult.Stderr.Length -eq 0) "The packaged-native recovery-indeterminate probe failed: $probeFailure"
        Assert-True (
          $probeResult.readFaultObserved -eq $true -and $probeResult.daclRestoredExactly -eq $true -and
          ([string]$probeResult.securityDescriptorSha256) -match '^[0-9a-f]{64}$' -and
          ([string]$probeResult.currentUserSidSha256) -match '^[0-9a-f]{64}$'
        ) "The packaged-native recovery-indeterminate DACL fault proof was invalid."
        $probeReport = Convert-JsonObject $probeResult.Stdout.Trim() "packaged-native recovery-indeterminate probe stdout"
        Assert-True (
          [string]$probeReport.schema -ceq "subversionr.release.m8-i6-packaged-native-recovery-indeterminate.v1" -and
          [string]$probeReport.status -ceq "passed" -and [string]$probeReport.cell -ceq "recoveryIndeterminate" -and
          [string]$probeReport.surface -ceq "packaged-native" -and
          [int]$probeReport.protocol.major -eq 1 -and [int]$probeReport.protocol.minor -eq 35 -and
          $probeReport.remoteSvnAnonymous -eq $true -and $probeReport.baselineGenerationObserved -eq $true -and
          [int]$probeReport.recoveryNotificationsObserved -eq 2 -and
          [int]$probeReport.journalEntriesAfter -eq 0 -and [int]$probeReport.journalTemporaryFilesAfter -eq 0 -and
          [int]$probeReport.temporaryRootsAfter -eq 0 -and $probeReport.workingCopyContentPreserved -eq $true -and
          $probeReport.diagnosticsRedacted -eq $true
        ) "The packaged-native recovery-indeterminate report was incomplete."
        $credentialRequests = [int]$probeReport.credentialRequests
        $credentialSettlements = [int]$probeReport.credentialSettlements
      }
      else {
        $probeResult = Invoke-BoundedProcess (Get-Process -Id $PID).Path @(
          "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
          "-File", $installedRecoveryIndeterminateProbeResolved,
          "-VsixPath", $vsixResolved,
          "-CodeCliPath", $codeCliResolved,
          "-FixtureRoot", $surfaceWorkRoot,
          "-WorkingCopyPath", ([string]$contract.WorkingCopy),
          "-RepositoryUrl", $RepositoryUrl,
          "-FixtureStatePath", $fixtureStatePath,
          "-OperationId", $originOperationId,
          "-OperationTimeoutMilliseconds", "5000",
          "-ExpectedProductVersion", $ExpectedProductVersion,
          "-DaemonPath", $daemonResolved,
          "-BridgePath", $bridgeResolved,
          "-TimeoutSeconds", "300"
        ) 360
        $probeFailure = $probeResult.Stderr.Trim()
        Assert-True ($probeResult.ExitCode -eq 0 -and $probeResult.Stderr.Length -eq 0) "The installed VSIX recovery-indeterminate probe failed: $probeFailure"
        $probeReport = Convert-JsonObject $probeResult.Stdout.Trim() "installed VSIX recovery-indeterminate probe stdout"
        Assert-True (
          [string]$probeReport.schema -ceq "subversionr.release.m8-i6-installed-vsix-recovery-indeterminate-wrapper.v1" -and
          [string]$probeReport.status -ceq "passed" -and [string]$probeReport.cell -ceq "recoveryIndeterminate" -and
          [string]$probeReport.surface -ceq "installed-vsix-extension-host" -and
          [int]$probeReport.protocol.major -eq 1 -and [int]$probeReport.protocol.minor -eq 35 -and
          $probeReport.commandBarrierObserved -eq $true -and $probeReport.workingCopyDatabaseDenyApplied -eq $true -and
          $probeReport.workingCopyDatabaseAclRestored -eq $true -and $probeReport.readFaultObserved -eq $true -and
          $probeReport.daclRestoredExactly -eq $true -and ([string]$probeReport.securityDescriptorSha256) -match '^[0-9a-f]{64}$' -and
          ([string]$probeReport.currentUserSidSha256) -match '^[0-9a-f]{64}$' -and $probeReport.workingCopyContentPreserved -eq $true -and
          [int64]$probeReport.workingCopyDatabaseBytes -gt 0 -and [int]$probeReport.checkoutJournalEntriesAfter -eq 0 -and
          [int]$probeReport.temporaryRootsAfter -eq 0 -and $probeReport.candidateDaemonExitedAfter -eq $true -and
          $probeReport.extensionInstalledAfterCleanup -eq $false -and $probeReport.fixtureRemovedAfterCleanup -eq $true -and
          $probeReport.diagnosticsRedacted -eq $true
        ) "The installed VSIX recovery-indeterminate report was incomplete."
        $credentialRequests = [int]$probeReport.authActivity.credentialRequests
        $credentialSettlements = [int]$probeReport.authActivity.credentialSettlements
      }

      foreach ($property in @("stableCode", "originCode", "settlementCode")) {
        Assert-True ([string]$probeReport.$property -ceq "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE") "The $surfaceName recovery-indeterminate stable code pair was invalid."
      }
      foreach ($property in @("reason", "originReason", "settlementReason")) {
        Assert-True ([string]$probeReport.$property -ceq "remoteOperationIndeterminate") "The $surfaceName recovery-indeterminate reason pair was invalid."
      }
      Assert-ExactProperties $probeReport.prerequisite @("code", "reason", "recovery") "$surfaceName recovery-indeterminate prerequisite"
      Assert-True (
        [string]$probeReport.prerequisite.code -ceq "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT" -and
        [string]$probeReport.prerequisite.reason -ceq "operationDeadlineExceeded" -and
        [string]$probeReport.prerequisite.recovery -ceq "pending"
      ) "The $surfaceName recovery-indeterminate prerequisite was invalid."
      Assert-ExactProperties $probeReport.indeterminate @("outcome", "stableCode", "reason", "nativeLaneBlocked", "explicitRecoveryRequired") "$surfaceName recovery-indeterminate settlement"
      Assert-True (
        [string]$probeReport.indeterminate.outcome -ceq "Indeterminate" -and
        [string]$probeReport.indeterminate.stableCode -ceq "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE" -and
        [string]$probeReport.indeterminate.reason -ceq "remoteOperationIndeterminate" -and
        $probeReport.indeterminate.nativeLaneBlocked -eq $true -and $probeReport.indeterminate.explicitRecoveryRequired -eq $true
      ) "The $surfaceName recovery-indeterminate settlement proof was invalid."
      Assert-True (
        [string]$probeReport.networkProgress -ceq "command" -and [int]$probeReport.networkAttempts -eq 1 -and
        [int]$probeReport.networkConnections -eq 1 -and [int]$probeReport.followupNetworkContacts -eq 0 -and
        $credentialRequests -eq 0 -and $credentialSettlements -eq 0
      ) "The $surfaceName recovery-indeterminate network or authentication proof was invalid."

      $workingCopyDatabaseBytesAfter = [int64](Get-Item -LiteralPath $workingCopyDatabasePath).Length
      Assert-True ($workingCopyDatabaseBytesAfter -gt 0) "The $surfaceName recovery-indeterminate flow left an empty working-copy database."
      $faultState = Get-Content -Raw -LiteralPath $fixtureStatePath | ConvertFrom-Json -Depth 16
      Assert-True (
        [int]$faultState.port -eq $repositoryUri.Port -and [string]$faultState.scenario -ceq "command-stall" -and
        [int]$faultState.connections -eq 1 -and [int]$faultState.greetingSent -eq 1 -and
        [int]$faultState.clientResponseReceived -eq 1 -and [int]$faultState.authRequestSent -eq 1 -and
        [int]$faultState.reposInfoSent -eq 1 -and [int]$faultState.commandsReceived -eq 1 -and
        [int]$faultState.followupContacts -eq 0 -and [int]$faultState.suppliedAuthorityConnections -eq 0
      ) "The $surfaceName recovery-indeterminate command-stage observation was invalid."
      Complete-ProcessStartEventDrain $processStartSourceIdentifier $processStartEvents $processStartEventKeys $ProcessStartEventSettlementMilliseconds
      $processObservation = Get-RecoveryIndeterminateProcessObservation `
        -AllEvents @($processStartEvents) `
        -ProbePid ([long]$probeResult.ProcessId) `
        -ExpectedProbeProcessName $(if ($surfaceName -ceq "packaged-native") { [System.IO.Path]::GetFileName($nodeHost) } else { [System.IO.Path]::GetFileName((Get-Process -Id $PID).Path) }) `
        -ExpectedDaemonProcessName ([System.IO.Path]::GetFileName($daemonResolved)) `
        -ForbiddenFixtureProcessNames @([System.IO.Path]::GetFileName($svnResolved), [System.IO.Path]::GetFileName($svnadminResolved), [System.IO.Path]::GetFileName($svnserveResolved)) `
        -SettlementSnapshot (Get-CimProcessSnapshot) `
        -Context "$surfaceName recovery-indeterminate"
      Assert-True ([int]$processObservation.fixtureCliInvocations -eq 0) "The $surfaceName recovery-indeterminate product surface invoked a fixture CLI."

      $recoveryIndeterminateObservations += [pscustomobject]@{
        surface = $surfaceName
        stableCode = [string]$probeReport.stableCode
        reason = [string]$probeReport.reason
        originCode = [string]$probeReport.originCode
        originReason = [string]$probeReport.originReason
        settlementCode = [string]$probeReport.settlementCode
        settlementReason = [string]$probeReport.settlementReason
        networkProgress = [string]$probeReport.networkProgress
        networkAttempts = [int]$faultState.connections
        networkConnections = [int]$faultState.connections
        fixtureCliInvocations = [int]$processObservation.fixtureCliInvocations
        credentialRequests = $credentialRequests
        credentialSettlements = $credentialSettlements
        followupNetworkContacts = [int]$faultState.followupContacts
        workerDescendantsAfter = [int]$processObservation.workerDescendantsAfter
        temporaryRootsAfter = [int]$probeReport.temporaryRootsAfter
        diagnosticsRedacted = [bool]$probeReport.diagnosticsRedacted
      }
      $recoveryIndeterminateSettlementObservations += [pscustomobject]@{
        surface = $surfaceName
        indeterminate = $probeReport.indeterminate
      }
    }
    finally {
      if ($null -ne $processStartSubscriber) {
        Unregister-Event -SubscriptionId $processStartSubscriber.SubscriptionId -ErrorAction SilentlyContinue
      }
      Get-Event -SourceIdentifier $processStartSourceIdentifier -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
      if ($null -ne $faultFixture) { Stop-FaultFixture $faultFixture "command-stall" }
    }
  }
}
finally {
  if (Test-Path -LiteralPath $recoveryIndeterminateWorkRoot) {
    Assert-True (Test-PathWithin $recoveryIndeterminateWorkRoot $repoTargetRoot) "The recovery-indeterminate cleanup root escaped repo target."
    Remove-Item -LiteralPath $recoveryIndeterminateWorkRoot -Recurse -Force
  }
  Assert-True (-not (Test-Path -LiteralPath $recoveryIndeterminateWorkRoot)) "The recovery-indeterminate short work root remained after cleanup."
}
Assert-True ($recoveryIndeterminateObservations.Count -eq 2) "The packaged-native and installed VSIX recovery-indeterminate observation set was incomplete."
Assert-True ($recoveryIndeterminateSettlementObservations.Count -eq 2) "The packaged-native and installed VSIX Indeterminate settlement set was incomplete."

$stalledReadWorkRoot = [System.IO.Path]::GetFullPath((Join-Path $repoTargetRoot "i6r\$([Guid]::NewGuid().ToString('N').Substring(0, 8))"))
Assert-True (Test-PathWithin $stalledReadWorkRoot $repoTargetRoot) "The stalled-mid-read short work root escaped repo target."
Assert-True ($stalledReadWorkRoot.Length -le 120) "The stalled-mid-read short work root exceeds the reviewed 120-character budget."
Assert-True (-not (Test-Path -LiteralPath $stalledReadWorkRoot)) "The stalled-mid-read short work root already exists."
New-Item -ItemType Directory -Path $stalledReadWorkRoot | Out-Null
$stalledReadObservations = @()
try {
  $stalledReadContracts = @(
    [pscustomobject]@{
      Surface = "packaged-native"
      WorkRoot = "p"
      WorkingCopy = $packagedAuthzWorkingCopyResolved
    },
    [pscustomobject]@{
      Surface = "installed-vsix-extension-host"
      WorkRoot = "i"
      WorkingCopy = $installedAuthzWorkingCopyResolved
    }
  )
  foreach ($contract in $stalledReadContracts) {
    $surfaceName = [string]$contract.Surface
    $surfaceRoot = Join-Path $probeRoot "stalled-mid-read-$surfaceName"
    $surfaceWorkRoot = Join-Path $stalledReadWorkRoot ([string]$contract.WorkRoot)
    $fixtureStatePath = Join-Path $surfaceRoot "fixture-state.json"
    New-Item -ItemType Directory -Force -Path $surfaceRoot, $surfaceWorkRoot | Out-Null
    Assert-CandidateProcessAbsent $daemonResolved "The $surfaceName stalled-mid-read preflight"
    $faultFixture = $null
    $processStartSourceIdentifier = "subversionr-m8-i6-stalled-read-$([Guid]::NewGuid().ToString('N'))"
    $processStartSubscriber = $null
    $processStartEvents = [System.Collections.Generic.List[object]]::new()
    $processStartEventKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    try {
      $faultFixture = Start-FaultFixture `
        $nodeHost `
        $faultFixtureResolved `
        "greeting-stall" `
        $fixtureStatePath `
        $repositoryUri.Port
      try {
        Register-CimIndicationEvent `
          -ClassName Win32_ProcessStartTrace `
          -SourceIdentifier $processStartSourceIdentifier `
          -ErrorAction Stop | Out-Null
      }
      catch {
        throw "Win32_ProcessStartTrace is required for the $surfaceName stalled-mid-read process observation: $($_.Exception.Message)"
      }
      $matchingSubscribers = @(Get-EventSubscriber -SourceIdentifier $processStartSourceIdentifier -ErrorAction Stop)
      Assert-True ($matchingSubscribers.Count -eq 1) "The $surfaceName stalled-mid-read process-start subscription was not created exactly once."
      $processStartSubscriber = $matchingSubscribers[0]
      Start-Sleep -Milliseconds $ProcessStartEventSettlementMilliseconds

      if ($surfaceName -ceq "packaged-native") {
        $probeResult = Invoke-BoundedProcess $nodeHost @(
          $packagedStalledReadProbeResolved,
          "--backend-module", $backendModulePath,
          "--daemon", $daemonResolved,
          "--bridge", $bridgeResolved,
          "--profile-root", $surfaceWorkRoot,
          "--working-copy-path", ([string]$contract.WorkingCopy),
          "--repository-url", $deniedRepositoryUrl,
          "--operation-id", ([Guid]::NewGuid().ToString("D")),
          "--timeout-ms", "1500"
        ) 90 @{ ELECTRON_RUN_AS_NODE = "1" }
        $probeFailure = $probeResult.Stderr.Trim()
        Assert-True (
          $probeResult.ExitCode -eq 0 -and $probeResult.Stderr.Length -eq 0
        ) "The packaged-native stalled-mid-read probe failed: $probeFailure"
        $probeReport = Convert-JsonObject $probeResult.Stdout.Trim() "packaged-native stalled-mid-read probe stdout"
        Assert-True (
          [string]$probeReport.schema -ceq "subversionr.release.m8-i6-packaged-native-stalled-read.v1" -and
          [string]$probeReport.status -ceq "passed" -and
          [string]$probeReport.cell -ceq "stalledMidRead" -and
          [string]$probeReport.stableCode -ceq "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT" -and
          [string]$probeReport.reason -ceq "operationDeadlineExceeded" -and
          [int]$probeReport.protocol.major -eq 1 -and [int]$probeReport.protocol.minor -eq 35 -and
          $probeReport.remoteSvnAnonymous -eq $true -and
          $probeReport.nativeLaneReleased -eq $true -and $probeReport.localSnapshotAfterTimeout -eq $true -and
          $probeReport.workingCopyPreserved -eq $true -and
          [int]$probeReport.temporaryRootsAfter -eq 0 -and
          [int]$probeReport.credentialRequests -eq 0 -and [int]$probeReport.credentialSettlements -eq 0 -and
          $probeReport.diagnosticsRedacted -eq $true -and [int]$probeReport.fixtureCliInvocations -eq 0
        ) "The packaged-native stalled-mid-read report was incomplete."
      }
      else {
        $installedFixtureRoot = Join-Path $surfaceWorkRoot "e"
        $probeResult = Invoke-BoundedProcess (Get-Process -Id $PID).Path @(
          "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
          "-File", $installedStalledReadProbeResolved,
          "-VsixPath", $vsixResolved,
          "-CodeCliPath", $codeCliResolved,
          "-FixtureRoot", $installedFixtureRoot,
          "-WorkingCopyPath", ([string]$contract.WorkingCopy),
          "-RepositoryUrl", $deniedRepositoryUrl,
          "-OperationTimeoutMilliseconds", "1500",
          "-ExpectedProductVersion", $ExpectedProductVersion,
          "-DaemonPath", $daemonResolved,
          "-BridgePath", $bridgeResolved,
          "-TimeoutSeconds", "180"
        ) 240
        $probeFailure = $probeResult.Stderr.Trim()
        Assert-True (
          $probeResult.ExitCode -eq 0 -and $probeResult.Stderr.Length -eq 0
        ) "The installed VSIX stalled-mid-read probe failed: $probeFailure"
        $probeReport = Convert-JsonObject $probeResult.Stdout.Trim() "installed VSIX stalled-mid-read probe stdout"
        Assert-True (
          [string]$probeReport.schema -ceq "subversionr.release.m8-i6-installed-vsix-stalled-read.v1" -and
          [string]$probeReport.status -ceq "passed" -and
          [string]$probeReport.surface -ceq "installed-vsix-extension-host" -and
          [string]$probeReport.cell -ceq "stalledMidRead" -and
          [string]$probeReport.stableCode -ceq "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT" -and
          [string]$probeReport.reason -ceq "operationDeadlineExceeded" -and
          [int]$probeReport.protocol.major -eq 1 -and [int]$probeReport.protocol.minor -eq 35 -and
          [int]$probeReport.authActivity.credentialRequests -eq 0 -and
          [int]$probeReport.authActivity.credentialSettlements -eq 0 -and
          [int]$probeReport.authActivity.certificateRequests -eq 0 -and
          $probeReport.nativeLaneReleased -eq $true -and $probeReport.localSnapshotAfterTimeout -eq $true -and
          $probeReport.workingCopyPreserved -eq $true -and
          [int]$probeReport.temporaryRootsAfter -eq 0 -and [int]$probeReport.checkoutJournalEntriesAfter -eq 0 -and
          $probeReport.diagnosticsRedacted -eq $true -and $probeReport.candidateDaemonExitedAfter -eq $true
        ) "The installed VSIX stalled-mid-read report was incomplete."
      }

      $faultState = Get-Content -Raw -LiteralPath $fixtureStatePath | ConvertFrom-Json -Depth 16
      Assert-True (
        [int]$faultState.port -eq $repositoryUri.Port -and
        [int]$faultState.connections -eq 1 -and
        [int]$faultState.greetingSent -eq 1 -and
        [int]$faultState.clientResponseReceived -eq 1 -and
        [int]$faultState.authRequestSent -eq 0 -and
        [int]$faultState.reposInfoSent -eq 0 -and
        [int]$faultState.commandsReceived -eq 0 -and
        [int]$faultState.followupContacts -eq 0 -and
        [int]$faultState.suppliedAuthorityConnections -eq 0
      ) "The $surfaceName stalled-mid-read network-stage observation was invalid."
      Complete-ProcessStartEventDrain `
        $processStartSourceIdentifier `
        $processStartEvents `
        $processStartEventKeys `
        $ProcessStartEventSettlementMilliseconds
      if ($surfaceName -ceq "packaged-native") {
        $processObservation = Get-PackagedNegativeProcessObservation `
          @($processStartEvents) `
          ([long]$probeResult.ProcessId) `
          ([System.IO.Path]::GetFileName($nodeHost)) `
          ([System.IO.Path]::GetFileName($daemonResolved)) `
          (Get-CimProcessSnapshot) `
          @(
            [System.IO.Path]::GetFileName($svnResolved),
            [System.IO.Path]::GetFileName($svnadminResolved),
            [System.IO.Path]::GetFileName($svnserveResolved)
          )
      }
      else {
        $processObservation = Get-InstalledNegativeProcessObservation `
          -AllEvents @($processStartEvents) `
          -ProbePid ([long]$probeResult.ProcessId) `
          -ExpectedProbeProcessName ([System.IO.Path]::GetFileName((Get-Process -Id $PID).Path)) `
          -ExpectedDaemonProcessName ([System.IO.Path]::GetFileName($daemonResolved)) `
          -ForbiddenFixtureProcessNames @(
            [System.IO.Path]::GetFileName($svnResolved),
            [System.IO.Path]::GetFileName($svnadminResolved),
            [System.IO.Path]::GetFileName($svnserveResolved)
          ) `
          -SettlementSnapshot (Get-CimProcessSnapshot)
      }
      Assert-True ([int]$processObservation.fixtureCliInvocations -eq 0) "The $surfaceName stalled-mid-read product surface invoked a fixture CLI."
      $stalledReadObservations += [pscustomobject]@{
        surface = $surfaceName
        stableCode = [string]$probeReport.stableCode
        reason = [string]$probeReport.reason
        originCode = [string]$probeReport.stableCode
        originReason = [string]$probeReport.reason
        settlementCode = [string]$probeReport.stableCode
        settlementReason = [string]$probeReport.reason
        networkProgress = "greeting"
        networkAttempts = [int]$faultState.connections
        networkConnections = [int]$faultState.connections
        fixtureCliInvocations = [int]$processObservation.fixtureCliInvocations
        credentialRequests = if ($surfaceName -ceq "packaged-native") { [int]$probeReport.credentialRequests } else { [int]$probeReport.authActivity.credentialRequests }
        credentialSettlements = if ($surfaceName -ceq "packaged-native") { [int]$probeReport.credentialSettlements } else { [int]$probeReport.authActivity.credentialSettlements }
        followupNetworkContacts = [int]$faultState.followupContacts
        workerDescendantsAfter = [int]$processObservation.workerDescendantsAfter
        temporaryRootsAfter = [int]$probeReport.temporaryRootsAfter
        diagnosticsRedacted = [bool]$probeReport.diagnosticsRedacted
      }
    }
    finally {
      if ($null -ne $processStartSubscriber) {
        Unregister-Event -SubscriptionId $processStartSubscriber.SubscriptionId -ErrorAction SilentlyContinue
      }
      Get-Event -SourceIdentifier $processStartSourceIdentifier -ErrorAction SilentlyContinue |
        Remove-Event -ErrorAction SilentlyContinue
      if ($null -ne $faultFixture) {
        Stop-FaultFixture $faultFixture "greeting-stall"
      }
    }
  }
}
finally {
  if (Test-Path -LiteralPath $stalledReadWorkRoot) {
    Assert-True (Test-PathWithin $stalledReadWorkRoot $repoTargetRoot) "The stalled-mid-read cleanup root escaped repo target."
    Remove-Item -LiteralPath $stalledReadWorkRoot -Recurse -Force
  }
  Assert-True (-not (Test-Path -LiteralPath $stalledReadWorkRoot)) "The stalled-mid-read short work root remained after cleanup."
}
Assert-True ($stalledReadObservations.Count -eq 2) "The packaged-native and installed VSIX stalled-mid-read observation set was incomplete."

$deadlineWorkRoot = [System.IO.Path]::GetFullPath((Join-Path $repoTargetRoot "i6d\$([Guid]::NewGuid().ToString('N').Substring(0, 8))"))
Assert-True (Test-PathWithin $deadlineWorkRoot $repoTargetRoot) "The absolute-deadline short work root escaped repo target."
Assert-True ($deadlineWorkRoot.Length -le 120) "The absolute-deadline short work root exceeds the reviewed 120-character budget."
Assert-True (-not (Test-Path -LiteralPath $deadlineWorkRoot)) "The absolute-deadline short work root already exists."
New-Item -ItemType Directory -Path $deadlineWorkRoot | Out-Null
$deadlineObservations = @()
try {
  $deadlineContracts = @(
    [pscustomobject]@{ Surface = "packaged-native"; WorkRoot = "p"; WorkingCopy = $packagedAuthzWorkingCopyResolved },
    [pscustomobject]@{ Surface = "installed-vsix-extension-host"; WorkRoot = "i"; WorkingCopy = $installedAuthzWorkingCopyResolved }
  )
  foreach ($contract in $deadlineContracts) {
    $surfaceName = [string]$contract.Surface
    $surfaceRoot = Join-Path $probeRoot "absolute-deadline-$surfaceName"
    $surfaceWorkRoot = Join-Path $deadlineWorkRoot ([string]$contract.WorkRoot)
    $fixtureStatePath = Join-Path $surfaceRoot "fixture-state.json"
    $operationId = [Guid]::NewGuid().ToString("D")
    New-Item -ItemType Directory -Force -Path $surfaceRoot, $surfaceWorkRoot | Out-Null
    Assert-CandidateProcessAbsent $daemonResolved "The $surfaceName absolute-deadline preflight"
    $faultFixture = $null
    $processStartSourceIdentifier = "subversionr-m8-i6-deadline-$([Guid]::NewGuid().ToString('N'))"
    $processStartSubscriber = $null
    $processStartEvents = [System.Collections.Generic.List[object]]::new()
    $processStartEventKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    try {
      $faultFixture = Start-FaultFixture $nodeHost $faultFixtureResolved "greeting-stall" $fixtureStatePath $repositoryUri.Port
      try {
        Register-CimIndicationEvent `
          -ClassName Win32_ProcessStartTrace `
          -SourceIdentifier $processStartSourceIdentifier `
          -ErrorAction Stop | Out-Null
      }
      catch {
        throw "Win32_ProcessStartTrace is required for the $surfaceName absolute-deadline process observation: $($_.Exception.Message)"
      }
      $matchingSubscribers = @(Get-EventSubscriber -SourceIdentifier $processStartSourceIdentifier -ErrorAction Stop)
      Assert-True ($matchingSubscribers.Count -eq 1) "The $surfaceName absolute-deadline process-start subscription was not created exactly once."
      $processStartSubscriber = $matchingSubscribers[0]
      Start-Sleep -Milliseconds $ProcessStartEventSettlementMilliseconds

      if ($surfaceName -ceq "packaged-native") {
        $probeResult = Invoke-BoundedProcess $nodeHost @(
          $packagedDeadlineProbeResolved,
          "--backend-module", $backendModulePath,
          "--daemon", $daemonResolved,
          "--bridge", $bridgeResolved,
          "--profile-root", $surfaceWorkRoot,
          "--working-copy-path", ([string]$contract.WorkingCopy),
          "--repository-url", $deniedRepositoryUrl,
          "--operation-id", $operationId,
          "--timeout-ms", "500"
        ) 90 @{ ELECTRON_RUN_AS_NODE = "1" }
        $probeFailure = $probeResult.Stderr.Trim()
        Assert-True ($probeResult.ExitCode -eq 0 -and $probeResult.Stderr.Length -eq 0) "The packaged-native absolute-deadline probe failed: $probeFailure"
        $probeReport = Convert-JsonObject $probeResult.Stdout.Trim() "packaged-native absolute-deadline probe stdout"
        Assert-True (
          [string]$probeReport.schema -ceq "subversionr.release.m8-i6-packaged-native-deadline.v1" -and
          [string]$probeReport.status -ceq "passed" -and [string]$probeReport.cell -ceq "deadline" -and
          [string]$probeReport.stableCode -ceq "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT" -and
          [string]$probeReport.reason -ceq "operationDeadlineExceeded" -and
          [int]$probeReport.protocol.major -eq 1 -and [int]$probeReport.protocol.minor -eq 35 -and
          $probeReport.remoteSvnAnonymous -eq $true -and
          $probeReport.nativeLaneReleased -eq $true -and $probeReport.localSnapshotAfterTimeout -eq $true -and
          $probeReport.workingCopyPreserved -eq $true -and [int]$probeReport.temporaryRootsAfter -eq 0 -and
          [int]$probeReport.credentialRequests -eq 0 -and [int]$probeReport.credentialSettlements -eq 0 -and
          $probeReport.diagnosticsRedacted -eq $true -and [int]$probeReport.fixtureCliInvocations -eq 0
        ) "The packaged-native absolute-deadline report was incomplete."
      }
      else {
        $installedFixtureRoot = Join-Path $surfaceWorkRoot "e"
        $probeResult = Invoke-BoundedProcess (Get-Process -Id $PID).Path @(
          "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
          "-File", $installedDeadlineProbeResolved,
          "-VsixPath", $vsixResolved,
          "-CodeCliPath", $codeCliResolved,
          "-FixtureRoot", $installedFixtureRoot,
          "-WorkingCopyPath", ([string]$contract.WorkingCopy),
          "-RepositoryUrl", $deniedRepositoryUrl,
          "-OperationId", $operationId,
          "-OperationTimeoutMilliseconds", "500",
          "-ExpectedProductVersion", $ExpectedProductVersion,
          "-DaemonPath", $daemonResolved,
          "-BridgePath", $bridgeResolved,
          "-TimeoutSeconds", "180"
        ) 240
        $probeFailure = $probeResult.Stderr.Trim()
        Assert-True ($probeResult.ExitCode -eq 0 -and $probeResult.Stderr.Length -eq 0) "The installed VSIX absolute-deadline probe failed: $probeFailure"
        $probeReport = Convert-JsonObject $probeResult.Stdout.Trim() "installed VSIX absolute-deadline probe stdout"
        Assert-True (
          [string]$probeReport.schema -ceq "subversionr.release.m8-i6-installed-vsix-deadline.v1" -and
          [string]$probeReport.status -ceq "passed" -and
          [string]$probeReport.surface -ceq "installed-vsix-extension-host" -and [string]$probeReport.cell -ceq "deadline" -and
          [string]$probeReport.stableCode -ceq "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT" -and
          [string]$probeReport.reason -ceq "operationDeadlineExceeded" -and
          [int]$probeReport.protocol.major -eq 1 -and [int]$probeReport.protocol.minor -eq 35 -and
          [int]$probeReport.authActivity.credentialRequests -eq 0 -and
          [int]$probeReport.authActivity.credentialSettlements -eq 0 -and
          [int]$probeReport.authActivity.certificateRequests -eq 0 -and
          $probeReport.nativeLaneReleased -eq $true -and $probeReport.localSnapshotAfterTimeout -eq $true -and
          $probeReport.workingCopyPreserved -eq $true -and
          [int]$probeReport.temporaryRootsAfter -eq 0 -and [int]$probeReport.checkoutJournalEntriesAfter -eq 0 -and
          $probeReport.diagnosticsRedacted -eq $true -and $probeReport.candidateDaemonExitedAfter -eq $true
        ) "The installed VSIX absolute-deadline report was incomplete."
      }

      Assert-ExactProperties $probeReport.timing @("clock", "timeoutMs", "elapsedMs", "cleanupSlackMs") "$surfaceName absolute-deadline timing"
      $elapsedMs = [double]$probeReport.timing.elapsedMs
      Assert-True (
        [string]$probeReport.timing.clock -ceq "monotonic" -and
        [int]$probeReport.timing.timeoutMs -eq 500 -and [int]$probeReport.timing.cleanupSlackMs -eq 5000 -and
        -not [double]::IsNaN($elapsedMs) -and -not [double]::IsInfinity($elapsedMs) -and
        $elapsedMs -ge 500 -and $elapsedMs -le 5500
      ) "The $surfaceName absolute-deadline timing escaped the reviewed owned timeout and cleanup bound."

      $faultState = Get-Content -Raw -LiteralPath $fixtureStatePath | ConvertFrom-Json -Depth 16
      Assert-True (
        [int]$faultState.port -eq $repositoryUri.Port -and [int]$faultState.connections -eq 1 -and
        [int]$faultState.greetingSent -eq 1 -and [int]$faultState.clientResponseReceived -eq 1 -and
        [int]$faultState.authRequestSent -eq 0 -and [int]$faultState.reposInfoSent -eq 0 -and
        [int]$faultState.commandsReceived -eq 0 -and [int]$faultState.followupContacts -eq 0 -and
        [int]$faultState.suppliedAuthorityConnections -eq 0
      ) "The $surfaceName absolute-deadline network-stage observation was invalid."
      Complete-ProcessStartEventDrain $processStartSourceIdentifier $processStartEvents $processStartEventKeys $ProcessStartEventSettlementMilliseconds
      if ($surfaceName -ceq "packaged-native") {
        $processObservation = Get-PackagedNegativeProcessObservation `
          @($processStartEvents) ([long]$probeResult.ProcessId) `
          ([System.IO.Path]::GetFileName($nodeHost)) ([System.IO.Path]::GetFileName($daemonResolved)) `
          (Get-CimProcessSnapshot) @(
            [System.IO.Path]::GetFileName($svnResolved),
            [System.IO.Path]::GetFileName($svnadminResolved),
            [System.IO.Path]::GetFileName($svnserveResolved)
          )
      }
      else {
        $processObservation = Get-InstalledNegativeProcessObservation `
          -AllEvents @($processStartEvents) `
          -ProbePid ([long]$probeResult.ProcessId) `
          -ExpectedProbeProcessName ([System.IO.Path]::GetFileName((Get-Process -Id $PID).Path)) `
          -ExpectedDaemonProcessName ([System.IO.Path]::GetFileName($daemonResolved)) `
          -ForbiddenFixtureProcessNames @(
            [System.IO.Path]::GetFileName($svnResolved),
            [System.IO.Path]::GetFileName($svnadminResolved),
            [System.IO.Path]::GetFileName($svnserveResolved)
          ) `
          -SettlementSnapshot (Get-CimProcessSnapshot)
      }
      Assert-True ([int]$processObservation.fixtureCliInvocations -eq 0) "The $surfaceName absolute-deadline product surface invoked a fixture CLI."
      $deadlineObservations += [pscustomobject]@{
        surface = $surfaceName
        stableCode = [string]$probeReport.stableCode
        reason = [string]$probeReport.reason
        originCode = [string]$probeReport.stableCode
        originReason = [string]$probeReport.reason
        settlementCode = [string]$probeReport.stableCode
        settlementReason = [string]$probeReport.reason
        networkProgress = "greeting"
        networkAttempts = [int]$faultState.connections
        networkConnections = [int]$faultState.connections
        fixtureCliInvocations = [int]$processObservation.fixtureCliInvocations
        credentialRequests = if ($surfaceName -ceq "packaged-native") { [int]$probeReport.credentialRequests } else { [int]$probeReport.authActivity.credentialRequests }
        credentialSettlements = if ($surfaceName -ceq "packaged-native") { [int]$probeReport.credentialSettlements } else { [int]$probeReport.authActivity.credentialSettlements }
        followupNetworkContacts = [int]$faultState.followupContacts
        workerDescendantsAfter = [int]$processObservation.workerDescendantsAfter
        temporaryRootsAfter = [int]$probeReport.temporaryRootsAfter
        diagnosticsRedacted = [bool]$probeReport.diagnosticsRedacted
        deadlineTiming = [pscustomobject]@{
          clock = [string]$probeReport.timing.clock
          timeoutMs = [int]$probeReport.timing.timeoutMs
          elapsedMs = $elapsedMs
          cleanupSlackMs = [int]$probeReport.timing.cleanupSlackMs
        }
      }
    }
    finally {
      if ($null -ne $processStartSubscriber) {
        Unregister-Event -SubscriptionId $processStartSubscriber.SubscriptionId -ErrorAction SilentlyContinue
      }
      Get-Event -SourceIdentifier $processStartSourceIdentifier -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
      if ($null -ne $faultFixture) { Stop-FaultFixture $faultFixture "greeting-stall" }
    }
  }
}
finally {
  if (Test-Path -LiteralPath $deadlineWorkRoot) {
    Assert-True (Test-PathWithin $deadlineWorkRoot $repoTargetRoot) "The absolute-deadline cleanup root escaped repo target."
    Remove-Item -LiteralPath $deadlineWorkRoot -Recurse -Force
  }
  Assert-True (-not (Test-Path -LiteralPath $deadlineWorkRoot)) "The absolute-deadline short work root remained after cleanup."
}
Assert-True ($deadlineObservations.Count -eq 2) "The packaged-native and installed VSIX absolute-deadline observation set was incomplete."

$cancellationWorkRoot = [System.IO.Path]::GetFullPath((Join-Path $repoTargetRoot "i6c\$([Guid]::NewGuid().ToString('N').Substring(0, 8))"))
Assert-True (Test-PathWithin $cancellationWorkRoot $repoTargetRoot) "The cancellation short work root escaped repo target."
Assert-True ($cancellationWorkRoot.Length -le 120) "The cancellation short work root exceeds the reviewed 120-character budget."
Assert-True (-not (Test-Path -LiteralPath $cancellationWorkRoot)) "The cancellation short work root already exists."
New-Item -ItemType Directory -Path $cancellationWorkRoot | Out-Null
$cancellationObservations = @()
try {
  $cancellationContracts = @(
    [pscustomobject]@{ Surface = "packaged-native"; WorkRoot = "p"; WorkingCopy = $packagedAuthzWorkingCopyResolved },
    [pscustomobject]@{ Surface = "installed-vsix-extension-host"; WorkRoot = "i"; WorkingCopy = $installedAuthzWorkingCopyResolved }
  )
  foreach ($contract in $cancellationContracts) {
    $surfaceName = [string]$contract.Surface
    $surfaceRoot = Join-Path $probeRoot "cancellation-$surfaceName"
    $surfaceWorkRoot = Join-Path $cancellationWorkRoot ([string]$contract.WorkRoot)
    $fixtureStatePath = Join-Path $surfaceRoot "fixture-state.json"
    $operationId = [Guid]::NewGuid().ToString("D")
    New-Item -ItemType Directory -Force -Path $surfaceRoot, $surfaceWorkRoot | Out-Null
    Assert-CandidateProcessAbsent $daemonResolved "The $surfaceName cancellation preflight"
    $faultFixture = $null
    $processStartSourceIdentifier = "subversionr-m8-i6-cancellation-$([Guid]::NewGuid().ToString('N'))"
    $processStartSubscriber = $null
    $processStartEvents = [System.Collections.Generic.List[object]]::new()
    $processStartEventKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    try {
      $faultFixture = Start-FaultFixture $nodeHost $faultFixtureResolved "greeting-stall" $fixtureStatePath $repositoryUri.Port
      try {
        Register-CimIndicationEvent `
          -ClassName Win32_ProcessStartTrace `
          -SourceIdentifier $processStartSourceIdentifier `
          -ErrorAction Stop | Out-Null
      }
      catch {
        throw "Win32_ProcessStartTrace is required for the $surfaceName cancellation process observation: $($_.Exception.Message)"
      }
      $matchingSubscribers = @(Get-EventSubscriber -SourceIdentifier $processStartSourceIdentifier -ErrorAction Stop)
      Assert-True ($matchingSubscribers.Count -eq 1) "The $surfaceName cancellation process-start subscription was not created exactly once."
      $processStartSubscriber = $matchingSubscribers[0]
      Start-Sleep -Milliseconds $ProcessStartEventSettlementMilliseconds

      if ($surfaceName -ceq "packaged-native") {
        $probeResult = Invoke-BoundedProcess $nodeHost @(
          $packagedCancellationProbeResolved,
          "--backend-module", $backendModulePath,
          "--daemon", $daemonResolved,
          "--bridge", $bridgeResolved,
          "--profile-root", $surfaceWorkRoot,
          "--working-copy-path", ([string]$contract.WorkingCopy),
          "--repository-url", $deniedRepositoryUrl,
          "--operation-id", $operationId,
          "--fixture-state-path", $fixtureStatePath
        ) 90 @{ ELECTRON_RUN_AS_NODE = "1" }
        $probeFailure = $probeResult.Stderr.Trim()
        Assert-True ($probeResult.ExitCode -eq 0 -and $probeResult.Stderr.Length -eq 0) "The packaged-native cancellation probe failed: $probeFailure"
        $probeReport = Convert-JsonObject $probeResult.Stdout.Trim() "packaged-native cancellation probe stdout"
        Assert-True (
          [string]$probeReport.schema -ceq "subversionr.release.m8-i6-packaged-native-cancellation.v1" -and
          [string]$probeReport.status -ceq "passed" -and [string]$probeReport.cell -ceq "cancellation" -and
          [string]$probeReport.stableCode -ceq "SUBVERSIONR_REMOTE_WORKER_CANCELLED" -and
          [string]$probeReport.reason -ceq "operationCancelled" -and
          [int]$probeReport.protocol.major -eq 1 -and [int]$probeReport.protocol.minor -eq 35 -and
          $probeReport.remoteSvnAnonymous -eq $true -and
          $probeReport.nativeLaneReleased -eq $true -and $probeReport.localSnapshotAfterCancellation -eq $true -and
          $probeReport.workingCopyPreserved -eq $true -and [int]$probeReport.temporaryRootsAfter -eq 0 -and
          [int]$probeReport.credentialRequests -eq 0 -and [int]$probeReport.credentialSettlements -eq 0 -and
          $probeReport.diagnosticsRedacted -eq $true -and [int]$probeReport.fixtureCliInvocations -eq 0
        ) "The packaged-native cancellation report was incomplete."
      }
      else {
        $installedFixtureRoot = Join-Path $surfaceWorkRoot "e"
        $probeResult = Invoke-BoundedProcess (Get-Process -Id $PID).Path @(
          "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
          "-File", $installedCancellationProbeResolved,
          "-VsixPath", $vsixResolved,
          "-CodeCliPath", $codeCliResolved,
          "-FixtureRoot", $installedFixtureRoot,
          "-WorkingCopyPath", ([string]$contract.WorkingCopy),
          "-RepositoryUrl", $deniedRepositoryUrl,
          "-OperationId", $operationId,
          "-FixtureStatePath", $fixtureStatePath,
          "-ExpectedProductVersion", $ExpectedProductVersion,
          "-DaemonPath", $daemonResolved,
          "-BridgePath", $bridgeResolved,
          "-TimeoutSeconds", "180"
        ) 240
        $probeFailure = $probeResult.Stderr.Trim()
        Assert-True ($probeResult.ExitCode -eq 0 -and $probeResult.Stderr.Length -eq 0) "The installed VSIX cancellation probe failed: $probeFailure"
        $probeReport = Convert-JsonObject $probeResult.Stdout.Trim() "installed VSIX cancellation probe stdout"
        Assert-True (
          [string]$probeReport.schema -ceq "subversionr.release.m8-i6-installed-vsix-cancellation.v1" -and
          [string]$probeReport.status -ceq "passed" -and
          [string]$probeReport.surface -ceq "installed-vsix-extension-host" -and [string]$probeReport.cell -ceq "cancellation" -and
          [string]$probeReport.stableCode -ceq "SUBVERSIONR_REMOTE_WORKER_CANCELLED" -and
          [string]$probeReport.reason -ceq "operationCancelled" -and
          [int]$probeReport.protocol.major -eq 1 -and [int]$probeReport.protocol.minor -eq 35 -and
          [int]$probeReport.authActivity.credentialRequests -eq 0 -and
          [int]$probeReport.authActivity.credentialSettlements -eq 0 -and
          [int]$probeReport.authActivity.certificateRequests -eq 0 -and
          $probeReport.nativeLaneReleased -eq $true -and $probeReport.localSnapshotAfterCancellation -eq $true -and
          $probeReport.workingCopyPreserved -eq $true -and
          [int]$probeReport.temporaryRootsAfter -eq 0 -and [int]$probeReport.checkoutJournalEntriesAfter -eq 0 -and
          $probeReport.diagnosticsRedacted -eq $true -and $probeReport.candidateDaemonExitedAfter -eq $true
        ) "The installed VSIX cancellation report was incomplete."
      }

      Assert-ExactProperties $probeReport.cancellationSettlement @("trigger", "localCode", "wireCode", "wireReason", "wireSettlementObserved") "$surfaceName cancellation settlement"
      Assert-True (
        [string]$probeReport.cancellationSettlement.trigger -ceq "abort-signal-after-greeting" -and
        [string]$probeReport.cancellationSettlement.localCode -ceq "JSON_RPC_REQUEST_CANCELLED" -and
        [string]$probeReport.cancellationSettlement.wireCode -ceq "SUBVERSIONR_REMOTE_WORKER_CANCELLED" -and
        [string]$probeReport.cancellationSettlement.wireReason -ceq "operationCancelled" -and
        $probeReport.cancellationSettlement.wireSettlementObserved -eq $true
      ) "The $surfaceName cancellation did not preserve the distinct local and daemon wire settlements."

      $faultState = Get-Content -Raw -LiteralPath $fixtureStatePath | ConvertFrom-Json -Depth 16
      Assert-True (
        [int]$faultState.port -eq $repositoryUri.Port -and [int]$faultState.connections -eq 1 -and
        [int]$faultState.greetingSent -eq 1 -and [int]$faultState.clientResponseReceived -eq 1 -and
        [int]$faultState.authRequestSent -eq 0 -and [int]$faultState.reposInfoSent -eq 0 -and
        [int]$faultState.commandsReceived -eq 0 -and [int]$faultState.followupContacts -eq 0 -and
        [int]$faultState.suppliedAuthorityConnections -eq 0
      ) "The $surfaceName cancellation network-stage observation was invalid."
      Complete-ProcessStartEventDrain $processStartSourceIdentifier $processStartEvents $processStartEventKeys $ProcessStartEventSettlementMilliseconds
      if ($surfaceName -ceq "packaged-native") {
        $processObservation = Get-PackagedNegativeProcessObservation `
          @($processStartEvents) ([long]$probeResult.ProcessId) `
          ([System.IO.Path]::GetFileName($nodeHost)) ([System.IO.Path]::GetFileName($daemonResolved)) `
          (Get-CimProcessSnapshot) @(
            [System.IO.Path]::GetFileName($svnResolved),
            [System.IO.Path]::GetFileName($svnadminResolved),
            [System.IO.Path]::GetFileName($svnserveResolved)
          )
      }
      else {
        $processObservation = Get-InstalledNegativeProcessObservation `
          -AllEvents @($processStartEvents) `
          -ProbePid ([long]$probeResult.ProcessId) `
          -ExpectedProbeProcessName ([System.IO.Path]::GetFileName((Get-Process -Id $PID).Path)) `
          -ExpectedDaemonProcessName ([System.IO.Path]::GetFileName($daemonResolved)) `
          -ForbiddenFixtureProcessNames @(
            [System.IO.Path]::GetFileName($svnResolved),
            [System.IO.Path]::GetFileName($svnadminResolved),
            [System.IO.Path]::GetFileName($svnserveResolved)
          ) `
          -SettlementSnapshot (Get-CimProcessSnapshot)
      }
      Assert-True ([int]$processObservation.fixtureCliInvocations -eq 0) "The $surfaceName cancellation product surface invoked a fixture CLI."
      $cancellationObservations += [pscustomobject]@{
        surface = $surfaceName
        stableCode = [string]$probeReport.stableCode
        reason = [string]$probeReport.reason
        originCode = [string]$probeReport.stableCode
        originReason = [string]$probeReport.reason
        settlementCode = [string]$probeReport.stableCode
        settlementReason = [string]$probeReport.reason
        networkProgress = "greeting"
        networkAttempts = [int]$faultState.connections
        networkConnections = [int]$faultState.connections
        fixtureCliInvocations = [int]$processObservation.fixtureCliInvocations
        credentialRequests = if ($surfaceName -ceq "packaged-native") { [int]$probeReport.credentialRequests } else { [int]$probeReport.authActivity.credentialRequests }
        credentialSettlements = if ($surfaceName -ceq "packaged-native") { [int]$probeReport.credentialSettlements } else { [int]$probeReport.authActivity.credentialSettlements }
        followupNetworkContacts = [int]$faultState.followupContacts
        workerDescendantsAfter = [int]$processObservation.workerDescendantsAfter
        temporaryRootsAfter = [int]$probeReport.temporaryRootsAfter
        diagnosticsRedacted = [bool]$probeReport.diagnosticsRedacted
        cancellationSettlement = [pscustomobject]@{
          trigger = [string]$probeReport.cancellationSettlement.trigger
          localCode = [string]$probeReport.cancellationSettlement.localCode
          wireCode = [string]$probeReport.cancellationSettlement.wireCode
          wireReason = [string]$probeReport.cancellationSettlement.wireReason
          wireSettlementObserved = [bool]$probeReport.cancellationSettlement.wireSettlementObserved
        }
      }
    }
    finally {
      if ($null -ne $processStartSubscriber) {
        Unregister-Event -SubscriptionId $processStartSubscriber.SubscriptionId -ErrorAction SilentlyContinue
      }
      Get-Event -SourceIdentifier $processStartSourceIdentifier -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
      if ($null -ne $faultFixture) { Stop-FaultFixture $faultFixture "greeting-stall" }
    }
  }
}
finally {
  if (Test-Path -LiteralPath $cancellationWorkRoot) {
    Assert-True (Test-PathWithin $cancellationWorkRoot $repoTargetRoot) "The cancellation cleanup root escaped repo target."
    Remove-Item -LiteralPath $cancellationWorkRoot -Recurse -Force
  }
  Assert-True (-not (Test-Path -LiteralPath $cancellationWorkRoot)) "The cancellation short work root remained after cleanup."
}
Assert-True ($cancellationObservations.Count -eq 2) "The packaged-native and installed VSIX cancellation observation set was incomplete."

$trustRevokedWorkRoot = [System.IO.Path]::GetFullPath((Join-Path $repoTargetRoot "i6t\$([Guid]::NewGuid().ToString('N').Substring(0, 8))"))
Assert-True (Test-PathWithin $trustRevokedWorkRoot $repoTargetRoot) "The trust-revoked short work root escaped repo target."
Assert-True ($trustRevokedWorkRoot.Length -le 120) "The trust-revoked short work root exceeds the reviewed 120-character budget."
Assert-True (-not (Test-Path -LiteralPath $trustRevokedWorkRoot)) "The trust-revoked short work root already exists."
New-Item -ItemType Directory -Path $trustRevokedWorkRoot | Out-Null
$trustRevokedObservations = @()
try {
  $trustRevokedContracts = @(
    [pscustomobject]@{ Surface = "packaged-native"; WorkRoot = "p"; WorkingCopy = $packagedAuthzWorkingCopyResolved },
    [pscustomobject]@{ Surface = "installed-vsix-extension-host"; WorkRoot = "i"; WorkingCopy = $installedAuthzWorkingCopyResolved }
  )
  foreach ($contract in $trustRevokedContracts) {
    $surfaceName = [string]$contract.Surface
    $surfaceRoot = Join-Path $probeRoot "trust-revoked-$surfaceName"
    $surfaceWorkRoot = Join-Path $trustRevokedWorkRoot ([string]$contract.WorkRoot)
    $fixtureStatePath = Join-Path $surfaceRoot "fixture-state.json"
    $operationId = [Guid]::NewGuid().ToString("D")
    New-Item -ItemType Directory -Force -Path $surfaceRoot, $surfaceWorkRoot | Out-Null
    Assert-CandidateProcessAbsent $daemonResolved "The $surfaceName trust-revoked preflight"
    $faultFixture = $null
    $processStartSourceIdentifier = "subversionr-m8-i6-trust-revoked-$([Guid]::NewGuid().ToString('N'))"
    $processStartSubscriber = $null
    $processStartEvents = [System.Collections.Generic.List[object]]::new()
    $processStartEventKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    try {
      $faultFixture = Start-FaultFixture $nodeHost $faultFixtureResolved "greeting-stall" $fixtureStatePath $repositoryUri.Port
      try {
        Register-CimIndicationEvent `
          -ClassName Win32_ProcessStartTrace `
          -SourceIdentifier $processStartSourceIdentifier `
          -ErrorAction Stop | Out-Null
      }
      catch {
        throw "Win32_ProcessStartTrace is required for the $surfaceName trust-revoked process observation: $($_.Exception.Message)"
      }
      $matchingSubscribers = @(Get-EventSubscriber -SourceIdentifier $processStartSourceIdentifier -ErrorAction Stop)
      Assert-True ($matchingSubscribers.Count -eq 1) "The $surfaceName trust-revoked process-start subscription was not created exactly once."
      $processStartSubscriber = $matchingSubscribers[0]
      Start-Sleep -Milliseconds $ProcessStartEventSettlementMilliseconds

      if ($surfaceName -ceq "packaged-native") {
        $probeResult = Invoke-BoundedProcessWithStartEventCapture $nodeHost @(
          $packagedTrustRevokedProbeResolved,
          "--backend-module", $backendModulePath,
          "--daemon", $daemonResolved,
          "--bridge", $bridgeResolved,
          "--profile-root", $surfaceWorkRoot,
          "--working-copy-path", ([string]$contract.WorkingCopy),
          "--repository-url", $deniedRepositoryUrl,
          "--operation-id", $operationId,
          "--fixture-state-path", $fixtureStatePath
        ) 90 `
          $processStartSourceIdentifier `
          $processStartEvents `
          $processStartEventKeys `
          $zeroWorkerCaptureProcessNames `
          @{ ELECTRON_RUN_AS_NODE = "1" }
        $probeFailure = $probeResult.Stderr.Trim()
        Assert-True ($probeResult.ExitCode -eq 0 -and $probeResult.Stderr.Length -eq 0) "The packaged-native trust-revoked probe failed: $probeFailure"
        $probeReport = Convert-JsonObject $probeResult.Stdout.Trim() "packaged-native trust-revoked probe stdout"
        Assert-True (
          [string]$probeReport.schema -ceq "subversionr.release.m8-i6-packaged-native-trust-revoked.v1" -and
          [string]$probeReport.status -ceq "passed" -and [string]$probeReport.cell -ceq "trustRevoked" -and
          [string]$probeReport.stableCode -ceq "SUBVERSIONR_REMOTE_TRUST_EPOCH_MISMATCH" -and
          [string]$probeReport.reason -ceq "remoteConfigurationInvalid" -and
          [int]$probeReport.protocol.major -eq 1 -and [int]$probeReport.protocol.minor -eq 35 -and
          $probeReport.remoteSvnAnonymous -eq $true -and
          $probeReport.nativeLaneReleased -eq $true -and $probeReport.localSnapshotAfterTrustRevocation -eq $true -and
          $probeReport.workingCopyPreserved -eq $true -and [int]$probeReport.networkAttempts -eq 0 -and
          [int]$probeReport.temporaryRootsAfter -eq 0 -and [int]$probeReport.credentialRootsAfter -eq 0 -and
          [int]$probeReport.credentialRequests -eq 0 -and [int]$probeReport.credentialSettlements -eq 0 -and
          $probeReport.diagnosticsRedacted -eq $true -and [int]$probeReport.fixtureCliInvocations -eq 0
        ) "The packaged-native trust-revoked report was incomplete."
      }
      else {
        $installedFixtureRoot = Join-Path $surfaceWorkRoot "e"
        $probeResult = Invoke-BoundedProcessWithStartEventCapture (Get-Process -Id $PID).Path @(
          "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
          "-File", $installedTrustRevokedProbeResolved,
          "-VsixPath", $vsixResolved,
          "-CodeCliPath", $codeCliResolved,
          "-FixtureRoot", $installedFixtureRoot,
          "-WorkingCopyPath", ([string]$contract.WorkingCopy),
          "-RepositoryUrl", $deniedRepositoryUrl,
          "-OperationId", $operationId,
          "-FixtureStatePath", $fixtureStatePath,
          "-ExpectedProductVersion", $ExpectedProductVersion,
          "-DaemonPath", $daemonResolved,
          "-BridgePath", $bridgeResolved,
          "-TimeoutSeconds", "180"
        ) 240 `
          $processStartSourceIdentifier `
          $processStartEvents `
          $processStartEventKeys `
          $zeroWorkerCaptureProcessNames
        $probeFailure = $probeResult.Stderr.Trim()
        Assert-True ($probeResult.ExitCode -eq 0 -and $probeResult.Stderr.Length -eq 0) "The installed VSIX trust-revoked probe failed: $probeFailure"
        $probeReport = Convert-JsonObject $probeResult.Stdout.Trim() "installed VSIX trust-revoked probe stdout"
        Assert-True (
          [string]$probeReport.schema -ceq "subversionr.release.m8-i6-installed-vsix-trust-revoked.v1" -and
          [string]$probeReport.status -ceq "passed" -and
          [string]$probeReport.surface -ceq "installed-vsix-extension-host" -and [string]$probeReport.cell -ceq "trustRevoked" -and
          [string]$probeReport.stableCode -ceq "SUBVERSIONR_REMOTE_TRUST_EPOCH_MISMATCH" -and
          [string]$probeReport.reason -ceq "remoteConfigurationInvalid" -and
          [int]$probeReport.protocol.major -eq 1 -and [int]$probeReport.protocol.minor -eq 35 -and
          [int]$probeReport.authActivity.credentialRequests -eq 0 -and
          [int]$probeReport.authActivity.credentialSettlements -eq 0 -and
          [int]$probeReport.authActivity.certificateRequests -eq 0 -and
          $probeReport.remoteSubmissionDisabled -eq $true -and $probeReport.localSnapshotAfterTrustRevocation -eq $true -and
          $probeReport.workingCopyPreserved -eq $true -and [int]$probeReport.fixtureContactsAfter -eq 0 -and
          [int]$probeReport.temporaryRootsAfter -eq 0 -and [int]$probeReport.checkoutJournalEntriesAfter -eq 0 -and
          $probeReport.diagnosticsRedacted -eq $true -and $probeReport.candidateDaemonExitedAfter -eq $true
        ) "The installed VSIX trust-revoked report was incomplete."
      }

      $trustTransition = if ($surfaceName -ceq "packaged-native") {
        $probeReport.trustTransition
      }
      else {
        [pscustomobject]@{
          fromEpoch = [int]$probeReport.trust.initialAcknowledgedEpoch
          toEpoch = [int]$probeReport.trust.revokedAcknowledgedEpoch
          staleEnvelopeEpoch = [int]$probeReport.trust.initialAcknowledgedEpoch
          remoteSubmissionEnabledAfter = [bool]$probeReport.trust.submissionEnabled
        }
      }
      Assert-ExactProperties $trustTransition @("fromEpoch", "toEpoch", "staleEnvelopeEpoch", "remoteSubmissionEnabledAfter") "$surfaceName trust transition"
      Assert-True (
        [int]$trustTransition.fromEpoch -eq 1 -and
        [int]$trustTransition.toEpoch -eq 2 -and
        [int]$trustTransition.staleEnvelopeEpoch -eq 1 -and
        $trustTransition.remoteSubmissionEnabledAfter -eq $false
      ) "The $surfaceName trust-revoked observation did not bind the exact defensive trust transition."

      $faultState = Get-Content -Raw -LiteralPath $fixtureStatePath | ConvertFrom-Json -Depth 16
      Assert-True (
        [int]$faultState.port -eq $repositoryUri.Port -and [string]$faultState.scenario -ceq "greeting-stall" -and
        [int]$faultState.connections -eq 0 -and [int]$faultState.greetingSent -eq 0 -and
        [int]$faultState.clientResponseReceived -eq 0 -and [int]$faultState.authRequestSent -eq 0 -and
        [int]$faultState.reposInfoSent -eq 0 -and [int]$faultState.commandsReceived -eq 0 -and
        [int]$faultState.followupContacts -eq 0 -and [int]$faultState.suppliedAuthorityConnections -eq 0
      ) "The $surfaceName trust-revoked network observation was not exactly zero."
      Complete-ProcessStartEventDrain `
        $processStartSourceIdentifier `
        $processStartEvents `
        $processStartEventKeys `
        $ProcessStartEventSettlementMilliseconds `
        $zeroWorkerCaptureProcessNames
      $processObservation = Get-ZeroWorkerProcessObservation `
        -AllEvents @($processStartEvents) `
        -ProbePid ([long]$probeResult.ProcessId) `
        -ExpectedProbeProcessName $(if ($surfaceName -ceq "packaged-native") { [System.IO.Path]::GetFileName($nodeHost) } else { [System.IO.Path]::GetFileName((Get-Process -Id $PID).Path) }) `
        -ExpectedDaemonProcessName ([System.IO.Path]::GetFileName($daemonResolved)) `
        -ExpectedDaemonFileIdentity $daemonFileIdentity `
        -ExpectedConsoleHostFileIdentity $consoleHostFileIdentity `
        -ForbiddenFixtureProcessNames @(
          [System.IO.Path]::GetFileName($svnResolved),
          [System.IO.Path]::GetFileName($svnadminResolved),
          [System.IO.Path]::GetFileName($svnserveResolved)
        ) `
        -SettlementSnapshot (Get-CimProcessSnapshot) `
        -Context "$surfaceName trust-revoked"
      Assert-True ([int]$processObservation.fixtureCliInvocations -eq 0) "The $surfaceName trust-revoked product surface invoked a fixture CLI."
      Assert-True ([int]$processObservation.workerStarts -eq 0) "The $surfaceName trust-revoked product surface started a remote worker."
      $trustRevokedObservations += [pscustomobject]@{
        surface = $surfaceName
        stableCode = [string]$probeReport.stableCode
        reason = [string]$probeReport.reason
        originCode = [string]$probeReport.stableCode
        originReason = [string]$probeReport.reason
        settlementCode = [string]$probeReport.stableCode
        settlementReason = [string]$probeReport.reason
        networkProgress = "none"
        networkAttempts = 0
        networkConnections = 0
        fixtureCliInvocations = [int]$processObservation.fixtureCliInvocations
        credentialRequests = if ($surfaceName -ceq "packaged-native") { [int]$probeReport.credentialRequests } else { [int]$probeReport.authActivity.credentialRequests }
        credentialSettlements = if ($surfaceName -ceq "packaged-native") { [int]$probeReport.credentialSettlements } else { [int]$probeReport.authActivity.credentialSettlements }
        followupNetworkContacts = 0
        workerDescendantsAfter = [int]$processObservation.workerDescendantsAfter
        temporaryRootsAfter = [int]$probeReport.temporaryRootsAfter
        diagnosticsRedacted = [bool]$probeReport.diagnosticsRedacted
        trustTransition = [pscustomobject]@{
          fromEpoch = [int]$trustTransition.fromEpoch
          toEpoch = [int]$trustTransition.toEpoch
          staleEnvelopeEpoch = [int]$trustTransition.staleEnvelopeEpoch
          remoteSubmissionEnabledAfter = [bool]$trustTransition.remoteSubmissionEnabledAfter
        }
      }
    }
    finally {
      if ($null -ne $processStartSubscriber) {
        Unregister-Event -SubscriptionId $processStartSubscriber.SubscriptionId -ErrorAction SilentlyContinue
      }
      Get-Event -SourceIdentifier $processStartSourceIdentifier -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
      if ($null -ne $faultFixture) { Stop-FaultFixture $faultFixture "greeting-stall" }
    }
  }
}
finally {
  if (Test-Path -LiteralPath $trustRevokedWorkRoot) {
    Assert-True (Test-PathWithin $trustRevokedWorkRoot $repoTargetRoot) "The trust-revoked cleanup root escaped repo target."
    Remove-Item -LiteralPath $trustRevokedWorkRoot -Recurse -Force
  }
  Assert-True (-not (Test-Path -LiteralPath $trustRevokedWorkRoot)) "The trust-revoked short work root remained after cleanup."
}
Assert-True ($trustRevokedObservations.Count -eq 2) "The packaged-native and installed VSIX trust-revoked observation set was incomplete."

$workerCrashWorkRoot = [System.IO.Path]::GetFullPath((Join-Path $repoTargetRoot "i6w\$([Guid]::NewGuid().ToString('N').Substring(0, 8))"))
Assert-True (Test-PathWithin $workerCrashWorkRoot $repoTargetRoot) "The worker-crash short work root escaped repo target."
Assert-True ($workerCrashWorkRoot.Length -le 120) "The worker-crash short work root exceeds the reviewed 120-character budget."
Assert-True (-not (Test-Path -LiteralPath $workerCrashWorkRoot)) "The worker-crash short work root already exists."
New-Item -ItemType Directory -Path $workerCrashWorkRoot | Out-Null
$workerCrashObservations = @()
try {
  $workerCrashContracts = @(
    [pscustomobject]@{ Surface = "packaged-native"; WorkRoot = "p"; WorkingCopy = $packagedAuthzWorkingCopyResolved },
    [pscustomobject]@{ Surface = "installed-vsix-extension-host"; WorkRoot = "i"; WorkingCopy = $installedAuthzWorkingCopyResolved }
  )
  foreach ($contract in $workerCrashContracts) {
    $surfaceName = [string]$contract.Surface
    $surfaceRoot = Join-Path $probeRoot "worker-crash-$surfaceName"
    $surfaceWorkRoot = Join-Path $workerCrashWorkRoot ([string]$contract.WorkRoot)
    $fixtureStatePath = Join-Path $surfaceRoot "fixture-state.json"
    $operationId = [Guid]::NewGuid().ToString("D")
    New-Item -ItemType Directory -Force -Path $surfaceRoot, $surfaceWorkRoot | Out-Null
    Assert-WorkerCrashCandidateCount $daemonResolved 0 "The $surfaceName worker-crash preflight"
    $faultFixture = $null
    $startedProbe = $null
    $probeCompleted = $false
    $binding = $null
    $tcpObserver = $null
    try {
      $faultFixture = Start-FaultFixture $nodeHost $faultFixtureResolved "greeting-stall" $fixtureStatePath $repositoryUri.Port
      $workerCrashRepositoryUrl = "svn://127.0.0.1:$($repositoryUri.Port)/repo/trunk"
      if ($surfaceName -ceq "packaged-native") {
        $startedProbe = Start-WorkerCrashProbeProcess $nodeHost @(
          $packagedWorkerCrashProbeResolved,
          "--backend-module", $backendModulePath,
          "--daemon", $daemonResolved,
          "--bridge", $bridgeResolved,
          "--profile-root", $surfaceWorkRoot,
          "--working-copy-path", ([string]$contract.WorkingCopy),
          "--repository-url", $workerCrashRepositoryUrl,
          "--operation-id", $operationId,
          "--fixture-state-path", $fixtureStatePath
        ) @{ ELECTRON_RUN_AS_NODE = "1" }
      }
      else {
        $installedFixtureRoot = Join-Path $surfaceWorkRoot "e"
        $startedProbe = Start-WorkerCrashProbeProcess (Get-Process -Id $PID).Path @(
          "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
          "-File", $installedWorkerCrashProbeResolved,
          "-VsixPath", $vsixResolved,
          "-CodeCliPath", $codeCliResolved,
          "-FixtureRoot", $installedFixtureRoot,
          "-WorkingCopyPath", ([string]$contract.WorkingCopy),
          "-RepositoryUrl", $workerCrashRepositoryUrl,
          "-FixtureStatePath", $fixtureStatePath,
          "-OperationId", $operationId,
          "-ExpectedProductVersion", $ExpectedProductVersion,
          "-DaemonPath", $daemonResolved,
          "-BridgePath", $bridgeResolved,
          "-TimeoutSeconds", "180"
        )
      }

      $barrierState = Wait-WorkerCrashGreetingBarrier `
        $fixtureStatePath `
        $repositoryUri.Port `
        ([System.Diagnostics.Process]$startedProbe.Process) `
        "$surfaceName worker-crash"
      $binding = [SubversionRM8I6WorkerCrashNative]::BindExactParentWorker($daemonResolved)
      Assert-True (
        [long]$binding.ParentProcessId -gt 0 -and [long]$binding.WorkerProcessId -gt 0 -and
        [long]$binding.ParentProcessId -ne [long]$binding.WorkerProcessId -and
        [long]$binding.ParentStartFileTime -gt 0 -and [long]$binding.WorkerStartFileTime -gt 0
      ) "The $surfaceName worker-crash process identity binding was invalid."
      $workerDescendantsAtBarrier = [SubversionRM8I6WorkerCrashNative]::GetBoundDescendantCount($binding)
      $terminationExitCode = [SubversionRM8I6WorkerCrashNative]::TerminateBoundWorker(
        $binding,
        [uint32]1398166083,
        [uint32]10000
      )
      Assert-True ([uint32]$terminationExitCode -eq [uint32]1398166083) "The $surfaceName worker termination exit code was not exact."
      try {
        $probeResult = Complete-WorkerCrashProbeProcess $startedProbe $(if ($surfaceName -ceq "packaged-native") { 90 } else { 240 }) "$surfaceName worker-crash"
      }
      finally {
        $probeCompleted = $true
      }
      $probeFailure = $probeResult.Stderr.Trim()
      Assert-True ($probeResult.ExitCode -eq 0 -and $probeResult.Stderr.Length -eq 0) "The $surfaceName worker-crash probe failed: $probeFailure"
      $probeReport = Convert-JsonObject $probeResult.Stdout.Trim() "$surfaceName worker-crash probe stdout"

      if ($surfaceName -ceq "packaged-native") {
        Assert-ExactProperties $probeReport @(
          "schema", "status", "cell", "surface", "stableCode", "reason", "protocol", "settlement",
          "daemonState", "workerCrashSettlement", "remoteSvnAnonymous", "credentialRequests",
          "credentialSettlements", "certificateRequests", "temporaryRootsAfter", "diagnosticsRedacted",
          "fixtureCliInvocations"
        ) "packaged-native worker-crash report"
        Assert-True (
          [string]$probeReport.schema -ceq "subversionr.release.m8-i6-packaged-native-worker-crash.v1" -and
          [string]$probeReport.status -ceq "passed" -and [string]$probeReport.cell -ceq "workerCrash" -and
          [string]$probeReport.surface -ceq "packaged-native" -and
          [int]$probeReport.protocol.major -eq 1 -and [int]$probeReport.protocol.minor -eq 35 -and
          $probeReport.remoteSvnAnonymous -eq $true -and [int]$probeReport.credentialRequests -eq 0 -and
          [int]$probeReport.credentialSettlements -eq 0 -and [int]$probeReport.certificateRequests -eq 0 -and
          [int]$probeReport.temporaryRootsAfter -eq 0 -and $probeReport.diagnosticsRedacted -eq $true -and
          [int]$probeReport.fixtureCliInvocations -eq 0
        ) "The packaged-native worker-crash report was incomplete."
        $credentialRequests = [int]$probeReport.credentialRequests
        $credentialSettlements = [int]$probeReport.credentialSettlements
      }
      else {
        Assert-ExactProperties $probeReport @(
          "schema", "status", "surface", "cell", "stableCode", "reason", "settlement", "daemonState",
          "workerCrashSettlement", "protocol", "trust", "authActivity", "diagnosticsRedacted",
          "temporaryRootsAfter", "checkoutJournalEntriesAfter", "workingCopyPreserved"
        ) "installed VSIX worker-crash report"
        Assert-True (
          [string]$probeReport.schema -ceq "subversionr.release.m8-i6-installed-vsix-worker-crash.v1" -and
          [string]$probeReport.status -ceq "passed" -and [string]$probeReport.surface -ceq "installed-vsix-extension-host" -and
          [string]$probeReport.cell -ceq "workerCrash" -and
          [int]$probeReport.protocol.major -eq 1 -and [int]$probeReport.protocol.minor -eq 35 -and
          [int]$probeReport.authActivity.credentialRequests -eq 0 -and
          [int]$probeReport.authActivity.credentialSettlements -eq 0 -and
          [int]$probeReport.authActivity.certificateRequests -eq 0 -and
          [int]$probeReport.temporaryRootsAfter -eq 0 -and [int]$probeReport.checkoutJournalEntriesAfter -eq 0 -and
          $probeReport.workingCopyPreserved -eq $true -and $probeReport.diagnosticsRedacted -eq $true
        ) "The installed VSIX worker-crash report was incomplete."
        $credentialRequests = [int]$probeReport.authActivity.credentialRequests
        $credentialSettlements = [int]$probeReport.authActivity.credentialSettlements
      }

      Assert-True (
        [string]$probeReport.stableCode -ceq "SUBVERSIONR_REMOTE_WORKER_CRASHED" -and
        [string]$probeReport.reason -ceq "workerContainmentFailed"
      ) "The $surfaceName worker-crash origin was invalid."
      Assert-ExactProperties $probeReport.settlement @("code", "category", "messageKey", "retryable", "safeArgs", "diagnostics") "$surfaceName worker-crash settlement"
      Assert-ExactProperties $probeReport.settlement.safeArgs @("stage", "remoteFailure") "$surfaceName worker-crash safe args"
      Assert-ExactProperties $probeReport.settlement.safeArgs.remoteFailure @("category", "reason", "cleanupAppropriate") "$surfaceName worker-crash remote failure"
      Assert-True (
        [string]$probeReport.settlement.code -ceq "SUBVERSIONR_REMOTE_WORKER_CRASHED" -and
        [string]$probeReport.settlement.category -ceq "process" -and
        [string]$probeReport.settlement.messageKey -ceq "error.remote.workerCrashed" -and
        $probeReport.settlement.retryable -eq $false -and $null -eq $probeReport.settlement.diagnostics -and
        [string]$probeReport.settlement.safeArgs.stage -ceq "workerProcess" -and
        [string]$probeReport.settlement.safeArgs.remoteFailure.category -ceq "process" -and
        [string]$probeReport.settlement.safeArgs.remoteFailure.reason -ceq "workerContainmentFailed" -and
        $probeReport.settlement.safeArgs.remoteFailure.cleanupAppropriate -eq $false
      ) "The $surfaceName worker-crash settlement was invalid."

      $expectedDaemonStateProperties = if ($surfaceName -ceq "packaged-native") {
        @("kind", "reason", "originOperationIdMatched", "recovery", "cleanupAppropriate")
      }
      else {
        @("kind", "reason", "originOperationIdMatched", "recovery", "cleanupAppropriate", "repositoryIdMatched", "epochMatched")
      }
      Assert-ExactProperties $probeReport.daemonState $expectedDaemonStateProperties "$surfaceName worker-crash daemon state"
      Assert-True (
        [string]$probeReport.daemonState.kind -ceq "indeterminate" -and
        [string]$probeReport.daemonState.reason -ceq "workerTerminated" -and
        [string]$probeReport.daemonState.recovery -ceq "notRequired" -and
        $probeReport.daemonState.cleanupAppropriate -eq $false -and
        $probeReport.daemonState.originOperationIdMatched -eq $true
      ) "The $surfaceName worker-crash daemon state was invalid."
      if ($surfaceName -ceq "installed-vsix-extension-host") {
        Assert-True (
          $probeReport.daemonState.repositoryIdMatched -eq $true -and $probeReport.daemonState.epochMatched -eq $true
        ) "The installed VSIX worker-crash daemon state did not bind the repository session."
      }
      Assert-ExactProperties $probeReport.workerCrashSettlement @(
        "trigger", "terminationExitCode", "workerIdentityBound", "workerTerminationObserved",
        "wireSettlementObserved", "daemonSurvived", "nativeLaneReleased", "localSnapshotAfterCrash",
        "workingCopyPreserved"
      ) "$surfaceName worker-crash proof"
      Assert-True (
        [string]$probeReport.workerCrashSettlement.trigger -ceq "external-worker-termination-after-greeting" -and
        [uint32]$probeReport.workerCrashSettlement.terminationExitCode -eq [uint32]$terminationExitCode
      ) "The $surfaceName worker-crash trigger or exit code was invalid."
      foreach ($field in @(
          "workerIdentityBound", "workerTerminationObserved", "wireSettlementObserved", "daemonSurvived",
          "nativeLaneReleased", "localSnapshotAfterCrash", "workingCopyPreserved"
        )) {
        Assert-True ($probeReport.workerCrashSettlement.$field -eq $true) "The $surfaceName worker-crash proof $field was invalid."
      }

      $finalFixtureState = Get-Content -Raw -LiteralPath $fixtureStatePath | ConvertFrom-Json -Depth 16
      Assert-True (
        [string]$finalFixtureState.scenario -ceq "greeting-stall" -and
        [int]$finalFixtureState.port -eq $repositoryUri.Port -and
        [int]$finalFixtureState.connections -eq 1 -and [int]$finalFixtureState.greetingSent -eq 1 -and
        [int]$finalFixtureState.clientResponseReceived -eq 1 -and [int]$finalFixtureState.authRequestSent -eq 0 -and
        [int]$finalFixtureState.reposInfoSent -eq 0 -and [int]$finalFixtureState.commandsReceived -eq 0 -and
        [int]$finalFixtureState.followupContacts -eq 0 -and [int]$finalFixtureState.suppliedAuthorityConnections -eq 0
      ) "The $surfaceName worker-crash fixture did not remain at the exact greeting barrier."
      Wait-WorkerCrashCandidateCount $daemonResolved 0 10000 "The $surfaceName worker-crash settlement"
      $workerDescendantsAfter = [SubversionRM8I6WorkerCrashNative]::GetBoundDescendantCount($binding)
      Assert-True ($workerDescendantsAfter -eq 0) "The $surfaceName worker-crash settlement left bound daemon/worker descendants."

      $workerCrashObservations += [pscustomobject]@{
        surface = $surfaceName
        originCode = [string]$probeReport.stableCode
        originReason = [string]$probeReport.reason
        settlementCode = [string]$probeReport.settlement.code
        settlementReason = [string]$probeReport.settlement.safeArgs.remoteFailure.reason
        networkProgress = "greeting"
        networkAttempts = [int]$finalFixtureState.connections
        networkConnections = [int]$finalFixtureState.connections
        fixtureCliInvocations = 0
        credentialRequests = $credentialRequests
        credentialSettlements = $credentialSettlements
        followupNetworkContacts = [int]$finalFixtureState.followupContacts
        workerDescendantsAtBarrier = [int]$workerDescendantsAtBarrier
        workerDescendantsAfter = [int]$workerDescendantsAfter
        temporaryRootsAfter = [int]$probeReport.temporaryRootsAfter
        diagnosticsRedacted = [bool]$probeReport.diagnosticsRedacted
        workerCrashSettlement = [pscustomobject]@{
          trigger = [string]$probeReport.workerCrashSettlement.trigger
          terminationExitCode = [uint32]$probeReport.workerCrashSettlement.terminationExitCode
          workerIdentityBound = [bool]$probeReport.workerCrashSettlement.workerIdentityBound
          workerTerminationObserved = [bool]$probeReport.workerCrashSettlement.workerTerminationObserved
          wireSettlementObserved = [bool]$probeReport.workerCrashSettlement.wireSettlementObserved
          daemonSurvived = [bool]$probeReport.workerCrashSettlement.daemonSurvived
          nativeLaneReleased = [bool]$probeReport.workerCrashSettlement.nativeLaneReleased
          localSnapshotAfterCrash = [bool]$probeReport.workerCrashSettlement.localSnapshotAfterCrash
          workingCopyPreserved = [bool]$probeReport.workerCrashSettlement.workingCopyPreserved
        }
        daemonState = [pscustomobject]@{
          kind = [string]$probeReport.daemonState.kind
          reason = [string]$probeReport.daemonState.reason
          recovery = [string]$probeReport.daemonState.recovery
          cleanupAppropriate = [bool]$probeReport.daemonState.cleanupAppropriate
        }
      }
    }
    finally {
      if ($null -ne $binding) { $binding.Dispose() }
      if ($null -ne $startedProbe -and -not $probeCompleted) {
        $probeProcess = [System.Diagnostics.Process]$startedProbe.Process
        try {
          if (-not $probeProcess.HasExited) {
            $probeProcess.Kill($true)
            $probeProcess.WaitForExit()
          }
        }
        finally {
          $probeProcess.Dispose()
        }
      }
      if ($null -ne $faultFixture) { Stop-FaultFixture $faultFixture "greeting-stall" }
    }
  }
}
finally {
  if (Test-Path -LiteralPath $workerCrashWorkRoot) {
    Assert-True (Test-PathWithin $workerCrashWorkRoot $repoTargetRoot) "The worker-crash cleanup root escaped repo target."
    Remove-Item -LiteralPath $workerCrashWorkRoot -Recurse -Force
  }
  Assert-True (-not (Test-Path -LiteralPath $workerCrashWorkRoot)) "The worker-crash short work root remained after cleanup."
}
Assert-True ($workerCrashObservations.Count -eq 2) "The packaged-native and installed VSIX worker-crash observation set was incomplete."

Assert-True (-not (Test-Path -LiteralPath $outputResolved)) "OutputPath must remain absent until every I6 observation is complete."

$blackholeConnectWorkRoot = [System.IO.Path]::GetFullPath((Join-Path $repoTargetRoot "i6h\$([Guid]::NewGuid().ToString('N').Substring(0, 8))"))
Assert-True (Test-PathWithin $blackholeConnectWorkRoot $repoTargetRoot) "The blackhole-connect short work root escaped repo target."
Assert-True (-not (Test-Path -LiteralPath $blackholeConnectWorkRoot)) "The blackhole-connect short work root already exists."
New-Item -ItemType Directory -Path $blackholeConnectWorkRoot | Out-Null
$blackholeConnectObservations = @()
try {
  foreach ($contract in @(
      [pscustomobject]@{ Surface = "packaged-native"; WorkRoot = "p"; WorkingCopy = $packagedAuthzWorkingCopyResolved },
      [pscustomobject]@{ Surface = "installed-vsix-extension-host"; WorkRoot = "i"; WorkingCopy = $installedAuthzWorkingCopyResolved }
    )) {
    $surfaceName = [string]$contract.Surface
    $surfaceRoot = Join-Path $blackholeConnectWorkRoot ([string]$contract.WorkRoot)
    $profileRoot = Join-Path $surfaceRoot "profile"
    $fixtureStatePath = Join-Path $surfaceRoot "blackhole-state.json"
    New-Item -ItemType Directory -Path $surfaceRoot, $profileRoot | Out-Null
    Assert-WorkerCrashCandidateCount $daemonResolved 0 "The $surfaceName blackhole-connect preflight"
    $fixture = $null
    $startedProbe = $null
    $probeCompleted = $false
    $binding = $null
    try {
      $fixture = Start-BlackholeConnectFixture (Get-Process -Id $PID).Path $blackholeConnectFixtureResolved $fixtureStatePath
      $blackholePort = [int]$fixture.State.port
      $blackholeUrl = "svn://127.0.0.1:$blackholePort/repo/trunk"
      $operationId = [Guid]::NewGuid().ToString("D")
      $tcpObserver = [SubversionRM8I6BlackholeTcpObserver]::new($blackholePort)
      if ($surfaceName -ceq "packaged-native") {
        $startedProbe = Start-WorkerCrashProbeProcess $nodeHost @(
          $packagedBlackholeConnectProbeResolved,
          "--backend-module", $backendModulePath,
          "--daemon", $daemonResolved,
          "--bridge", $bridgeResolved,
          "--profile-root", $profileRoot,
          "--working-copy-path", ([string]$contract.WorkingCopy),
          "--repository-url", $blackholeUrl,
          "--operation-id", $operationId,
          "--timeout-ms", "5000"
        ) @{ ELECTRON_RUN_AS_NODE = "1" }
      }
      else {
        $installedRoot = Join-Path $surfaceRoot "extension-host"
        $startedProbe = Start-WorkerCrashProbeProcess (Get-Process -Id $PID).Path @(
          "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
          "-File", $installedBlackholeConnectProbeResolved,
          "-VsixPath", $vsixResolved,
          "-CodeCliPath", $codeCliResolved,
          "-FixtureRoot", $installedRoot,
          "-WorkingCopyPath", ([string]$contract.WorkingCopy),
          "-RepositoryUrl", $blackholeUrl,
          "-OperationId", $operationId,
          "-OperationTimeoutMilliseconds", "5000",
          "-ExpectedProductVersion", $ExpectedProductVersion,
          "-DaemonPath", $daemonResolved,
          "-BridgePath", $bridgeResolved,
          "-TimeoutSeconds", "180"
        )
      }
      Wait-WorkerCrashCandidateCount $daemonResolved 2 30000 "The $surfaceName blackhole-connect barrier"
      $binding = [SubversionRM8I6WorkerCrashNative]::BindExactParentWorker($daemonResolved)
      $tcpObserver.BindWorker([uint32]$binding.WorkerProcessId)
      $probeResult = Complete-WorkerCrashProbeProcess $startedProbe 180 "$surfaceName blackhole-connect"
      $probeCompleted = $true
      $probeReport = Convert-JsonObject $probeResult.Stdout.Trim() "$surfaceName blackhole-connect probe stdout"
      Assert-True ($probeResult.ExitCode -eq 0 -and $probeResult.Stderr.Length -eq 0) "The $surfaceName blackhole-connect probe failed."
      Assert-True (
        [string]$probeReport.status -ceq "passed" -and [string]$probeReport.cell -ceq "blackholeConnect" -and
        [string]$probeReport.stableCode -ceq "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT" -and
        [string]$probeReport.reason -ceq "operationDeadlineExceeded" -and
        [int]$probeReport.protocol.major -eq 1 -and [int]$probeReport.protocol.minor -eq 35 -and
        [int]$probeReport.timing.timeoutMs -eq 5000 -and [double]$probeReport.timing.elapsedMs -ge 5000 -and
        [double]$probeReport.timing.elapsedMs -le 10000 -and [int]$probeReport.timing.cleanupSlackMs -eq 5000 -and
        [int]$probeReport.temporaryRootsAfter -eq 0 -and [int]$probeReport.checkoutJournalEntriesAfter -eq 0 -and
        $probeReport.workingCopyPreserved -eq $true -and $probeReport.diagnosticsRedacted -eq $true
      ) "The $surfaceName blackhole-connect product report was incomplete."
      Wait-WorkerCrashCandidateCount $daemonResolved 0 10000 "The $surfaceName blackhole-connect settlement"
      $workerDescendantsAfter = [SubversionRM8I6WorkerCrashNative]::GetBoundDescendantCount($binding)
      Assert-True ($workerDescendantsAfter -eq 0) "The $surfaceName blackhole-connect settlement left bound daemon descendants."
      Assert-True ([SubversionRM8I6TcpOwnerTable]::Count([uint32]$binding.WorkerProcessId, $blackholePort, [uint32]3) -eq 0) "The $surfaceName blackhole-connect settlement left a SYN_SENT row."
      Assert-True ([SubversionRM8I6TcpOwnerTable]::CountAny([uint32]$binding.WorkerProcessId, $blackholePort) -eq 0) "The $surfaceName blackhole-connect settlement left a worker-owned TCP row."
      Assert-True ([SubversionRM8I6TcpOwnerTable]::GetByRemotePort($blackholePort).Length -eq 0) "The $surfaceName blackhole-connect settlement left a TCP row owned by another process."
      $tcpObservation = Complete-BlackholeConnectObservation $tcpObserver $binding $probeCompleted "$surfaceName blackhole-connect"
      $tcpObserver.Dispose()
      $tcpObserver = $null
      $finalFixtureState = Stop-BlackholeConnectFixture $fixture $fixtureStatePath
      $fixture = $null
      $credentialRequests = if ($surfaceName -ceq "packaged-native") { [int]$probeReport.credentialRequests } else { [int]$probeReport.authActivity.credentialRequests }
      $credentialSettlements = if ($surfaceName -ceq "packaged-native") { [int]$probeReport.credentialSettlements } else { [int]$probeReport.authActivity.credentialSettlements }
      $blackholeConnectObservations += [pscustomobject]@{
        surface = $surfaceName
        originCode = "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT"; originReason = "operationDeadlineExceeded"
        settlementCode = "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT"; settlementReason = "operationDeadlineExceeded"
        networkProgress = "none"; networkAttempts = [int]$tcpObservation.distinctTcbAttempts; networkConnections = [int]$tcpObservation.establishedTcbConnections
        fixtureCliInvocations = 0; credentialRequests = $credentialRequests; credentialSettlements = $credentialSettlements
        followupNetworkContacts = 0; workerDescendantsAfter = [int]$workerDescendantsAfter
        workerProcessesAfter = 0; temporaryRootsAfter = [int]$probeReport.temporaryRootsAfter
        checkoutJournalEntriesAfter = [int]$probeReport.checkoutJournalEntriesAfter
        workingCopyPreserved = [bool]$probeReport.workingCopyPreserved; diagnosticsRedacted = [bool]$probeReport.diagnosticsRedacted
        blackholeTiming = [pscustomobject]@{ clock = "monotonic"; timeoutMs = 5000; elapsedMs = [double]$probeReport.timing.elapsedMs; cleanupSlackMs = 5000 }
        daemonState = [pscustomobject]@{ kind = "unreachable"; reason = "timeout"; recovery = "notRequired"; cleanupAppropriate = $false }
        blackholeConnectSettlement = [pscustomobject]@{
          trigger = "conditional-accept-loopback-no-accept"
          operationIdSha256 = [string]$probeReport.blackholeSettlement.operationIdSha256
          wireSettlementObserved = [bool]$probeReport.blackholeSettlement.wireSettlementObserved
          daemonTerminalStateObserved = [bool]$probeReport.blackholeSettlement.daemonTerminalStateObserved
          nativeLaneReleased = [bool]$probeReport.nativeLaneReleased
          localSnapshotAfterTimeout = [bool]$probeReport.localSnapshotAfterTimeout
          conditionalAcceptEnabled = [bool]$finalFixtureState.conditionalAcceptEnabled
          listenerProcessBound = ([int]$finalFixtureState.pid -gt 0)
          acceptInvocations = [int]$finalFixtureState.acceptInvocations
          acceptedConnections = [int]$finalFixtureState.acceptedConnections
          stateArtifactUntampered = $true
          finalFixtureStatus = [string]$finalFixtureState.status
          tcp = $tcpObservation
        }
      }
    }
    finally {
      if ($null -ne $tcpObserver) { $tcpObserver.Dispose() }
      if ($null -ne $binding) { $binding.Dispose() }
      if ($null -ne $startedProbe -and -not $probeCompleted) {
        $probeProcess = [System.Diagnostics.Process]$startedProbe.Process
        if (-not $probeProcess.HasExited) { $probeProcess.Kill($true); $probeProcess.WaitForExit() }
        $probeProcess.Dispose()
      }
      if ($null -ne $fixture) {
        try { Stop-BlackholeConnectFixture $fixture $fixtureStatePath | Out-Null } catch { }
      }
    }
  }
}
finally {
  if (Test-Path -LiteralPath $blackholeConnectWorkRoot) { Remove-Item -LiteralPath $blackholeConnectWorkRoot -Recurse -Force }
  Assert-True (-not (Test-Path -LiteralPath $blackholeConnectWorkRoot)) "The blackhole-connect short work root remained after cleanup."
}
Assert-True ($blackholeConnectObservations.Count -eq 2) "The packaged-native and installed VSIX blackhole-connect observation set was incomplete."

$daemonDisconnectWorkRoot = [System.IO.Path]::GetFullPath((Join-Path $repoTargetRoot "i6z\$([Guid]::NewGuid().ToString('N').Substring(0, 8))"))
Assert-True (Test-PathWithin $daemonDisconnectWorkRoot $repoTargetRoot) "The daemon-disconnect short work root escaped repo target."
New-Item -ItemType Directory -Path $daemonDisconnectWorkRoot | Out-Null
$daemonDisconnectObservations = @()
try {
  foreach ($contract in @(
      [pscustomobject]@{ Surface = "packaged-native"; WorkRoot = "p"; WorkingCopy = $packagedAuthzWorkingCopyResolved },
      [pscustomobject]@{ Surface = "installed-vsix-extension-host"; WorkRoot = "i"; WorkingCopy = $installedAuthzWorkingCopyResolved }
    )) {
    $surfaceName = [string]$contract.Surface
    $surfaceRoot = Join-Path $daemonDisconnectWorkRoot ([string]$contract.WorkRoot)
    $profileRoot = Join-Path $surfaceRoot "profile"
    $fixtureStatePath = Join-Path $surfaceRoot "fixture-state.json"
    $shutdownTriggerPath = Join-Path $surfaceRoot "shutdown.trigger"
    New-Item -ItemType Directory -Path $surfaceRoot, $profileRoot | Out-Null
    Assert-WorkerCrashCandidateCount $daemonResolved 0 "The $surfaceName daemon-disconnect preflight"
    $faultFixture = $null; $startedProbe = $null; $probeCompleted = $false; $binding = $null
    try {
      $faultFixture = Start-FaultFixture $nodeHost $faultFixtureResolved "greeting-stall" $fixtureStatePath $repositoryUri.Port
      $operationId = [Guid]::NewGuid().ToString("D")
      $disconnectUrl = "svn://127.0.0.1:$($repositoryUri.Port)/repo/trunk"
      if ($surfaceName -ceq "packaged-native") {
        $startedProbe = Start-WorkerCrashProbeProcess $nodeHost @(
          $packagedDaemonDisconnectProbeResolved,
          "--backend-module", $backendModulePath, "--daemon", $daemonResolved, "--bridge", $bridgeResolved,
          "--profile-root", $profileRoot, "--working-copy-path", ([string]$contract.WorkingCopy),
          "--repository-url", $disconnectUrl, "--operation-id", $operationId,
          "--fixture-state-path", $fixtureStatePath, "--shutdown-trigger-path", $shutdownTriggerPath
        ) @{ ELECTRON_RUN_AS_NODE = "1" }
      }
      else {
        $startedProbe = Start-WorkerCrashProbeProcess (Get-Process -Id $PID).Path @(
          "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $installedDaemonDisconnectProbeResolved,
          "-VsixPath", $vsixResolved, "-CodeCliPath", $codeCliResolved, "-FixtureRoot", (Join-Path $surfaceRoot "extension-host"),
          "-WorkingCopyPath", ([string]$contract.WorkingCopy), "-RepositoryUrl", $disconnectUrl,
          "-FixtureStatePath", $fixtureStatePath, "-ShutdownTriggerPath", $shutdownTriggerPath,
          "-OperationId", $operationId, "-ExpectedProductVersion", $ExpectedProductVersion,
          "-DaemonPath", $daemonResolved, "-BridgePath", $bridgeResolved, "-TimeoutSeconds", "180"
        )
      }
      $barrierState = Wait-WorkerCrashGreetingBarrier $fixtureStatePath $repositoryUri.Port ([System.Diagnostics.Process]$startedProbe.Process) "$surfaceName daemon-disconnect"
      $binding = [SubversionRM8I6WorkerCrashNative]::BindExactParentWorker($daemonResolved)
      $workerDescendantsAtBarrier = [SubversionRM8I6WorkerCrashNative]::GetBoundDescendantCount($binding)
      $triggerStream = [System.IO.File]::Open($shutdownTriggerPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
      $triggerStream.Dispose()
      $probeResult = Complete-WorkerCrashProbeProcess $startedProbe 180 "$surfaceName daemon-disconnect"
      $probeCompleted = $true
      $probeReport = Convert-JsonObject $probeResult.Stdout.Trim() "$surfaceName daemon-disconnect probe stdout"
      Assert-True ($probeResult.ExitCode -eq 0 -and $probeResult.Stderr.Length -eq 0) "The $surfaceName daemon-disconnect probe failed."
      Assert-True (
        [string]$probeReport.status -ceq "passed" -and [string]$probeReport.cell -ceq "daemonDisconnect" -and
        [string]$probeReport.stableCode -ceq "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED" -and
        [string]$probeReport.reason -ceq "workerContainmentFailed" -and
        [int]$probeReport.protocol.major -eq 1 -and [int]$probeReport.protocol.minor -eq 35 -and
        [string]$probeReport.daemonDisconnectSettlement.trigger -ceq "graceful-client-shutdown-after-greeting" -and
        $probeReport.daemonDisconnectSettlement.activeRequestSettlementObserved -eq $true -and
        $probeReport.daemonDisconnectSettlement.daemonStateObserved -eq $true -and
        $probeReport.daemonDisconnectSettlement.settlementBeforeShutdownAck -eq $true -and
        $probeReport.daemonDisconnectSettlement.shutdownAcknowledged -eq $true -and
        $probeReport.daemonDisconnectSettlement.workingCopyPreserved -eq $true -and
        [int]$probeReport.temporaryRootsAfter -eq 0 -and $probeReport.diagnosticsRedacted -eq $true
      ) "The $surfaceName daemon-disconnect product report was incomplete."
      Wait-WorkerCrashCandidateCount $daemonResolved 0 10000 "The $surfaceName daemon-disconnect settlement"
      $workerDescendantsAfter = [SubversionRM8I6WorkerCrashNative]::GetBoundDescendantCount($binding)
      Assert-True ($workerDescendantsAfter -eq 0) "The $surfaceName daemon-disconnect settlement left bound descendants."
      $finalFixtureState = Get-Content -Raw -LiteralPath $fixtureStatePath | ConvertFrom-Json -Depth 16
      Assert-True ([int]$finalFixtureState.followupContacts -eq 0 -and [int]$finalFixtureState.connections -eq 1) "The $surfaceName daemon-disconnect fixture crossed its greeting barrier."
      Stop-FaultFixture $faultFixture "greeting-stall"
      $faultFixture = $null
      $credentialRequests = if ($surfaceName -ceq "packaged-native") { [int]$probeReport.credentialRequests } else { [int]$probeReport.authActivity.credentialRequests }
      $credentialSettlements = if ($surfaceName -ceq "packaged-native") { [int]$probeReport.credentialSettlements } else { [int]$probeReport.authActivity.credentialSettlements }
      $checkoutJournalEntriesAfter = if ($surfaceName -ceq "packaged-native") { 0 } else { [int]$probeReport.checkoutJournalEntriesAfter }
      $daemonDisconnectObservations += [pscustomobject]@{
        surface = $surfaceName
        originCode = "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED"; originReason = "workerContainmentFailed"
        settlementCode = "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED"; settlementReason = "workerContainmentFailed"
        networkProgress = "greeting"; networkAttempts = 1; networkConnections = 1
        fixtureCliInvocations = 0; credentialRequests = $credentialRequests; credentialSettlements = $credentialSettlements
        followupNetworkContacts = [int]$finalFixtureState.followupContacts
        workerDescendantsAtBarrier = [int]$workerDescendantsAtBarrier; workerDescendantsAfter = [int]$workerDescendantsAfter
        workerProcessesAfter = 0; temporaryRootsAfter = [int]$probeReport.temporaryRootsAfter
        checkoutJournalEntriesAfter = $checkoutJournalEntriesAfter; workingCopyPreserved = $true
        diagnosticsRedacted = [bool]$probeReport.diagnosticsRedacted
        daemonState = [pscustomobject]@{ kind = "indeterminate"; reason = "workerTerminated"; recovery = "notRequired"; cleanupAppropriate = $false }
        daemonDisconnectSettlement = [pscustomobject]@{
          trigger = [string]$probeReport.daemonDisconnectSettlement.trigger
          activeRequestSettlementObserved = [bool]$probeReport.daemonDisconnectSettlement.activeRequestSettlementObserved
          daemonStateObserved = [bool]$probeReport.daemonDisconnectSettlement.daemonStateObserved
          settlementBeforeShutdownAck = [bool]$probeReport.daemonDisconnectSettlement.settlementBeforeShutdownAck
          shutdownAcknowledged = [bool]$probeReport.daemonDisconnectSettlement.shutdownAcknowledged
          workingCopyPreserved = [bool]$probeReport.daemonDisconnectSettlement.workingCopyPreserved
          fixtureGreetingBarrierObserved = $true
          shutdownTriggerExternallyCreated = $true
          fixtureFollowupContacts = [int]$finalFixtureState.followupContacts
        }
      }
    }
    finally {
      if ($null -ne $binding) { $binding.Dispose() }
      if ($null -ne $startedProbe -and -not $probeCompleted) {
        $probeProcess = [System.Diagnostics.Process]$startedProbe.Process
        if (-not $probeProcess.HasExited) { $probeProcess.Kill($true); $probeProcess.WaitForExit() }
        $probeProcess.Dispose()
      }
      if ($null -ne $faultFixture) { try { Stop-FaultFixture $faultFixture "greeting-stall" } catch { } }
    }
  }
}
finally {
  if (Test-Path -LiteralPath $daemonDisconnectWorkRoot) { Remove-Item -LiteralPath $daemonDisconnectWorkRoot -Recurse -Force }
  Assert-True (-not (Test-Path -LiteralPath $daemonDisconnectWorkRoot)) "The daemon-disconnect short work root remained after cleanup."
}
Assert-True ($daemonDisconnectObservations.Count -eq 2) "The packaged-native and installed VSIX daemon-disconnect observation set was incomplete."

function New-I6ArtifactBinding([string]$Kind, [string]$Path) {
  return [pscustomobject]@{
    kind = $Kind
    sha256 = Get-Sha256 $Path
    sizeBytes = [int64](Get-Item -LiteralPath $Path).Length
  }
}

function New-I6NegativeObservation(
  [string]$Surface,
  [string]$OriginCode,
  [string]$OriginReason,
  [string]$SettlementCode,
  [string]$SettlementReason,
  [string]$NetworkProgress,
  [int]$NetworkAttempts,
  [int]$NetworkConnections,
  [int]$FixtureCliInvocations,
  [int]$CredentialRequests,
  [int]$CredentialSettlements,
  [int]$FollowupNetworkContacts,
  [int]$WorkerDescendantsAfter,
  [int]$TemporaryRootsAfter,
  [bool]$DiagnosticsRedacted
) {
  return [pscustomobject]@{
    surface = $Surface
    originCode = $OriginCode; originReason = $OriginReason
    settlementCode = $SettlementCode; settlementReason = $SettlementReason
    networkProgress = $NetworkProgress; networkAttempts = $NetworkAttempts; networkConnections = $NetworkConnections
    fixtureCliInvocations = $FixtureCliInvocations; credentialRequests = $CredentialRequests; credentialSettlements = $CredentialSettlements
    followupNetworkContacts = $FollowupNetworkContacts; workerDescendantsAfter = $WorkerDescendantsAfter
    temporaryRootsAfter = $TemporaryRootsAfter; diagnosticsRedacted = $DiagnosticsRedacted
  }
}

function Get-ExactlyOne([object[]]$Values, [scriptblock]$Predicate, [string]$Context) {
  $matches = @($Values | Where-Object $Predicate)
  Assert-True ($matches.Count -eq 1) "$Context must contain exactly one observation."
  return $matches[0]
}

$packagedMalicious = Get-ExactlyOne $packagedNegativeObservations { $_.scenario -ceq "malicious-root" } "packaged malicious-root"
$installedMalicious = Get-ExactlyOne $installedNegativeObservations { $_.scenario -ceq "maliciousRoot" } "installed malicious-root"
$packagedSasl = Get-ExactlyOne $packagedNegativeObservations { $_.scenario -ceq "sasl-only" } "packaged SASL-only"
$installedSasl = Get-ExactlyOne $installedNegativeObservations { $_.scenario -ceq "saslOnly" } "installed SASL-only"
$maliciousRootObservations = @(
  (New-I6NegativeObservation "packaged-native" $packagedMalicious.code $packagedMalicious.reason $packagedMalicious.settlementCode $packagedMalicious.settlementReason "authenticated" $packagedMalicious.networkAttempts $packagedMalicious.networkConnections 0 0 0 $packagedMalicious.followupNetworkContacts $packagedMalicious.workerDescendantsAfter $packagedMalicious.temporaryRootsAfter $packagedMalicious.diagnosticsRedacted),
  (New-I6NegativeObservation "installed-vsix-extension-host" $installedMalicious.code $installedMalicious.reason $installedMalicious.settlementCode $installedMalicious.settlementReason "authenticated" $installedMalicious.networkAttempts $installedMalicious.networkConnections $installedMalicious.fixtureCliInvocations 0 0 $installedMalicious.followupNetworkContacts $installedMalicious.workerDescendantsAfter $installedMalicious.temporaryRootsAfter $installedMalicious.diagnosticsRedacted)
)
$saslOnlyObservations = @(
  (New-I6NegativeObservation "packaged-native" $packagedSasl.code $packagedSasl.reason $packagedSasl.settlementCode $packagedSasl.settlementReason "greeting" $packagedSasl.networkAttempts $packagedSasl.networkConnections 0 0 0 $packagedSasl.followupNetworkContacts $packagedSasl.workerDescendantsAfter $packagedSasl.temporaryRootsAfter $packagedSasl.diagnosticsRedacted),
  (New-I6NegativeObservation "installed-vsix-extension-host" $installedSasl.code $installedSasl.reason $installedSasl.settlementCode $installedSasl.settlementReason "greeting" $installedSasl.networkAttempts $installedSasl.networkConnections $installedSasl.fixtureCliInvocations 0 0 $installedSasl.followupNetworkContacts $installedSasl.workerDescendantsAfter $installedSasl.temporaryRootsAfter $installedSasl.diagnosticsRedacted)
)
$normalizedAuthzDeniedObservations = @($authzDeniedObservations | ForEach-Object {
    New-I6NegativeObservation $_.surface $_.stableCode $_.reason $_.stableCode $_.reason "command" $_.networkAttempts $_.networkConnections $_.fixtureCliInvocations 0 0 0 $_.workerDescendantsAfter $_.temporaryRootsAfter $_.diagnosticsRedacted
  })

$artifactBindings = [ordered]@{
  vsix = New-I6ArtifactBinding "vsix" $vsixResolved
  daemon = New-I6ArtifactBinding "daemon" $daemonResolved
  bridge = New-I6ArtifactBinding "bridge" $bridgeResolved
  stageManifest = New-I6ArtifactBinding "subversion-stage-manifest" $stageManifestResolved
  probeDriver = New-I6ArtifactBinding "i6-probe-driver" $MyInvocation.MyCommand.Path
  packagedNativeProbe = New-I6ArtifactBinding "i6-packaged-native-probe" $packagedI6ProbeResolved
  packagedNegativeProbe = New-I6ArtifactBinding "i6-packaged-negative-probe" $packagedNegativeProbeResolved
  packagedAuthzDeniedProbe = New-I6ArtifactBinding "i6-packaged-authz-denied-probe" $packagedAuthzDeniedProbeResolved
  packagedStalledReadProbe = New-I6ArtifactBinding "i6-packaged-stalled-read-probe" $packagedStalledReadProbeResolved
  packagedDeadlineProbe = New-I6ArtifactBinding "i6-packaged-deadline-probe" $packagedDeadlineProbeResolved
  packagedCancellationProbe = New-I6ArtifactBinding "i6-packaged-cancellation-probe" $packagedCancellationProbeResolved
  packagedTrustRevokedProbe = New-I6ArtifactBinding "i6-packaged-trust-revoked-probe" $packagedTrustRevokedProbeResolved
  packagedRecoveryBlockedProbe = New-I6ArtifactBinding "i6-packaged-recovery-blocked-probe" $packagedRecoveryBlockedProbeResolved
  packagedRecoverySafeProbe = New-I6ArtifactBinding "i6-packaged-recovery-safe-probe" $packagedRecoverySafeProbeResolved
  packagedRecoveryIndeterminateProbe = New-I6ArtifactBinding "i6-packaged-recovery-indeterminate-probe" $packagedRecoveryIndeterminateProbeResolved
  packagedRedactionProbe = New-I6ArtifactBinding "i6-packaged-redaction-probe" $packagedRedactionProbeResolved
  packagedWorkerCrashProbe = New-I6ArtifactBinding "i6-packaged-worker-crash-probe" $packagedWorkerCrashProbeResolved
  packagedBlackholeConnectProbe = New-I6ArtifactBinding "i6-packaged-blackhole-connect-probe" $packagedBlackholeConnectProbeResolved
  packagedDaemonDisconnectProbe = New-I6ArtifactBinding "i6-packaged-daemon-disconnect-probe" $packagedDaemonDisconnectProbeResolved
  raSvnFaultFixture = New-I6ArtifactBinding "i6-ra-svn-fault-fixture" $faultFixtureResolved
  blackholeConnectFixture = New-I6ArtifactBinding "i6-blackhole-connect-fixture" $blackholeConnectFixtureResolved
  countingProxy = New-I6ArtifactBinding "i6-counting-proxy" $countingProxyResolved
  installedStressProbe = New-I6ArtifactBinding "i6-installed-stress-probe" $installedStressProbeResolved
  installedNegativeProbe = New-I6ArtifactBinding "i6-installed-negative-probe" $installedNegativeProbeResolved
  installedAuthzDeniedProbe = New-I6ArtifactBinding "i6-installed-authz-denied-probe" $installedAuthzDeniedProbeResolved
  installedStalledReadProbe = New-I6ArtifactBinding "i6-installed-stalled-read-probe" $installedStalledReadProbeResolved
  installedDeadlineProbe = New-I6ArtifactBinding "i6-installed-deadline-probe" $installedDeadlineProbeResolved
  installedCancellationProbe = New-I6ArtifactBinding "i6-installed-cancellation-probe" $installedCancellationProbeResolved
  installedTrustRevokedProbe = New-I6ArtifactBinding "i6-installed-trust-revoked-probe" $installedTrustRevokedProbeResolved
  installedRecoveryBlockedProbe = New-I6ArtifactBinding "i6-installed-recovery-blocked-probe" $installedRecoveryBlockedProbeResolved
  installedRecoverySafeProbe = New-I6ArtifactBinding "i6-installed-recovery-safe-probe" $installedRecoverySafeProbeResolved
  installedRecoveryIndeterminateProbe = New-I6ArtifactBinding "i6-installed-recovery-indeterminate-probe" $installedRecoveryIndeterminateProbeResolved
  installedRedactionProbe = New-I6ArtifactBinding "i6-installed-redaction-probe" $installedRedactionProbeResolved
  installedWorkerCrashProbe = New-I6ArtifactBinding "i6-installed-worker-crash-probe" $installedWorkerCrashProbeResolved
  installedBlackholeConnectProbe = New-I6ArtifactBinding "i6-installed-blackhole-connect-probe" $installedBlackholeConnectProbeResolved
  installedDaemonDisconnectProbe = New-I6ArtifactBinding "i6-installed-daemon-disconnect-probe" $installedDaemonDisconnectProbeResolved
  installedLocalEventProbe = New-I6ArtifactBinding "i6-installed-local-event-zero-network-probe" $installedLocalEventProbeResolved
  installedVsixProbe = New-I6ArtifactBinding "i6-installed-vsix-probe" $installedI6ProbeResolved
  packagedCompatibilityProbe = New-I6ArtifactBinding "packaged-native-compatibility-probe" $packagedProbeResolved
  installedExtensionHostProbe = New-I6ArtifactBinding "installed-extension-host-probe" $installedHarnessResolved
  raSvnOriginPatch = New-I6ArtifactBinding "ra-svn-origin-patch" $patchResolved
  raSvnOriginContract = New-I6ArtifactBinding "ra-svn-origin-contract" $patchContractResolved
  nativeSourceLock = New-I6ArtifactBinding "native-source-lock" $sourceLockResolved
  svn = New-I6ArtifactBinding "fixture-svn" $svnResolved
  svnadmin = New-I6ArtifactBinding "fixture-svnadmin" $svnadminResolved
  svnserve = New-I6ArtifactBinding "fixture-svnserve" $svnserveResolved
  svnserveLog = New-I6ArtifactBinding "fixture-svnserve-log" $fixtureLogResolved
}

$schemaPath = Resolve-RequiredFile (Join-Path $repoRoot "docs\release\m8-i6-svn-anonymous-evidence.v1.schema.json") "I6 evidence schema"
$surfaceReports = @(
  [pscustomobject]@{
    kind = "packaged-native"; artifactSha256 = [string]$artifactBindings.daemon.sha256; protocol = $positiveReport.protocol
    remoteSvnAnonymous = [bool]$positiveReport.remoteSvnAnonymous; fixtureCliInvocations = [int]$positiveReport.fixtureCliInvocations
    positiveOperationCount = [int]$positiveReport.positiveOperationCount; identityRequiredOperationCount = [int]$positiveReport.identityRequiredOperationCount
    remoteOperationCount = [int]$positiveReport.remoteOperationCount; uniqueOperationIds = [bool]$positiveReport.uniqueOperationIds
    operations = @($positiveReport.operations); anonymousIdentityRequired = $positiveReport.anonymousIdentityRequired
  },
  [pscustomobject]@{
    kind = "installed-vsix-extension-host"; artifactSha256 = [string]$artifactBindings.vsix.sha256; protocol = $installedPositiveReport.protocol
    remoteSvnAnonymous = [bool]$installedPositiveReport.remoteSvnAnonymous; fixtureCliInvocations = [int]$installedPositiveReport.fixtureCliInvocations
    positiveOperationCount = [int]$installedPositiveReport.positiveOperationCount; identityRequiredOperationCount = [int]$installedPositiveReport.identityRequiredOperationCount
    remoteOperationCount = [int]$installedPositiveReport.remoteOperationCount; uniqueOperationIds = [bool]$installedPositiveReport.uniqueOperationIds
    operations = @($installedPositiveReport.operations); anonymousIdentityRequired = $installedPositiveReport.anonymousIdentityRequired
  }
)

$recoverySettlementObservations = @()
foreach ($surface in @("packaged-native", "installed-vsix-extension-host")) {
  $safe = Get-ExactlyOne $recoverySafeSettlementObservations { $_.surface -ceq $surface } "$surface Safe settlement"
  $indeterminate = Get-ExactlyOne $recoveryIndeterminateSettlementObservations { $_.surface -ceq $surface } "$surface Indeterminate settlement"
  $blocked = Get-ExactlyOne $recoveryBlockedSettlementObservations { $_.surface -ceq $surface } "$surface Blocked settlement"
  $recoverySettlementObservations += [pscustomobject]@{ surface = $surface; safe = $safe.safe; indeterminate = $indeterminate.indeterminate; blocked = $blocked.blocked }
}

$stressCycles = @($installedStressReport.observations)
$stressSubsequent = $installedStressReport.subsequentRequest
$maxWorkers = [int](($stressCycles.workerDescendantsAfter | Measure-Object -Maximum).Maximum)
$maxTemporaryRoots = [int](($stressCycles.temporaryRootsAfter | Measure-Object -Maximum).Maximum)
$maxFixtureChildren = [int](($stressCycles.fixtureServerChildrenAfter | Measure-Object -Maximum).Maximum)
$maxDiagnosticBytes = [int](($redactionPrivacyObservations.maxDiagnosticBytes | Measure-Object -Maximum).Maximum)
$rawUrlCount = [int](($redactionPrivacyObservations.rawUrlCount | Measure-Object -Sum).Sum)
$rawPathCount = [int](($redactionPrivacyObservations.rawPathCount | Measure-Object -Sum).Sum)
$secretTokenCount = [int](($redactionPrivacyObservations.secretTokenCount | Measure-Object -Sum).Sum)
$boundedDiagnostics = @($redactionPrivacyObservations | Where-Object { $_.boundedDiagnostics -ne $true }).Count -eq 0
Assert-True ($rawUrlCount -eq 0 -and $rawPathCount -eq 0 -and $secretTokenCount -eq 0 -and $boundedDiagnostics) "The I6 privacy aggregate did not recompute to a redacted bounded result."

$evidence = [ordered]@{
  schema = "subversionr.release.m8-i6-svn-anonymous.win32-x64.v1"
  schemaVersion = 1
  contract = [ordered]@{ path = "docs/release/m8-i6-svn-anonymous-evidence.v1.schema.json"; sha256 = Get-Sha256 $schemaPath }
  target = "win32-x64"
  productVersion = $ExpectedProductVersion
  publicClaimEligible = $true
  artifactBindings = $artifactBindings
  fixture = [ordered]@{
    transport = "direct-svn"; serverKind = "svnserve"; serverVersion = "1.14.5"; listenHost = "127.0.0.1"
    configurationSha256 = Get-Sha256 $fixtureConfigResolved; authzSha256 = Get-Sha256 $fixtureAuthzResolved
    sourceBuilt = $true; fixtureCliOnly = $true; ambientConfigExcluded = $true; saslEnabled = $false
  }
  surfaces = $surfaceReports
  negativeCells = @(
    [pscustomobject]@{ cell = "maliciousRoot"; status = "passed"; stableCode = "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH"; reason = "crossAuthorityRejected"; surfaceObservations = $maliciousRootObservations },
    [pscustomobject]@{ cell = "saslOnly"; status = "passed"; stableCode = "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED"; reason = "remoteCapabilityUnsupported"; surfaceObservations = $saslOnlyObservations },
    [pscustomobject]@{ cell = "authzDenied"; status = "passed"; stableCode = "SVN_REMOTE_STATUS_AUTH_FAILED"; reason = "authorizationDenied"; surfaceObservations = $normalizedAuthzDeniedObservations },
    [pscustomobject]@{ cell = "blackholeConnect"; status = "passed"; stableCode = "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT"; reason = "operationDeadlineExceeded"; surfaceObservations = $blackholeConnectObservations },
    [pscustomobject]@{ cell = "stalledMidRead"; status = "passed"; stableCode = "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT"; reason = "operationDeadlineExceeded"; surfaceObservations = $stalledReadObservations },
    [pscustomobject]@{ cell = "deadline"; status = "passed"; stableCode = "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT"; reason = "operationDeadlineExceeded"; surfaceObservations = $deadlineObservations },
    [pscustomobject]@{ cell = "cancellation"; status = "passed"; stableCode = "SUBVERSIONR_REMOTE_WORKER_CANCELLED"; reason = "operationCancelled"; surfaceObservations = $cancellationObservations },
    [pscustomobject]@{ cell = "workerCrash"; status = "passed"; stableCode = "SUBVERSIONR_REMOTE_WORKER_CRASHED"; reason = "workerContainmentFailed"; surfaceObservations = $workerCrashObservations },
    [pscustomobject]@{ cell = "daemonDisconnect"; status = "passed"; stableCode = "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED"; reason = "workerContainmentFailed"; surfaceObservations = $daemonDisconnectObservations },
    [pscustomobject]@{ cell = "trustRevoked"; status = "passed"; stableCode = "SUBVERSIONR_REMOTE_TRUST_EPOCH_MISMATCH"; reason = "remoteConfigurationInvalid"; surfaceObservations = $trustRevokedObservations },
    [pscustomobject]@{ cell = "recoverySafe"; status = "passed"; stableCode = "none"; reason = "none"; surfaceObservations = $recoverySafeObservations },
    [pscustomobject]@{ cell = "recoveryIndeterminate"; status = "passed"; stableCode = "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE"; reason = "remoteOperationIndeterminate"; surfaceObservations = $recoveryIndeterminateObservations },
    [pscustomobject]@{ cell = "recoveryBlocked"; status = "passed"; stableCode = "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT"; reason = "operationDeadlineExceeded"; surfaceObservations = $recoveryBlockedObservations },
    [pscustomobject]@{ cell = "unrelatedRepository"; status = "passed"; stableCode = "none"; reason = "none"; surfaceObservations = $unrelatedRepositoryObservations },
    [pscustomobject]@{ cell = "localEventZeroNetwork"; status = "passed"; stableCode = "none"; reason = "none"; surfaceObservations = @($localEventZeroNetworkObservation) },
    [pscustomobject]@{ cell = "redaction"; status = "passed"; stableCode = "none"; reason = "none"; surfaceObservations = $redactionObservations }
  )
  recoverySettlements = [ordered]@{ surfaceObservations = $recoverySettlementObservations }
  stress = [ordered]@{
    surface = "installed-vsix-extension-host"; cycles = 100; status = "passed"
    cycleObservations = $stressCycles; subsequentObservation = $stressSubsequent
    maxWorkerDescendantsAfterCycle = $maxWorkers; maxTemporaryRootsAfterCycle = $maxTemporaryRoots
    maxFixtureServerChildrenAfterCycle = $maxFixtureChildren; subsequentRequestPassed = [bool]$installedStressReport.subsequentRequestPassed
  }
  privacy = [ordered]@{ rawUrlCount = $rawUrlCount; rawPathCount = $rawPathCount; secretTokenCount = $secretTokenCount; maxDiagnosticBytes = $maxDiagnosticBytes; boundedDiagnostics = $boundedDiagnostics }
  verdict = [ordered]@{
    status = "verified"; claim = "win32-x64-direct-svn-anonymous"; allOperationCellsPassed = $true
    allNegativeCellsPassed = $true; artifactHashesMatched = $true; installedProductProved = $true; sourceBuiltFixtureProved = $true
  }
}

$serializedEvidence = $evidence | ConvertTo-Json -Depth 32
$temporaryOutputPath = "$outputResolved.tmp"
Assert-True (-not (Test-Path -LiteralPath $temporaryOutputPath)) "The I6 evidence temporary output already exists."
[System.IO.File]::WriteAllText($temporaryOutputPath, $serializedEvidence + "`n", [System.Text.UTF8Encoding]::new($false, $true))
[System.IO.File]::Move($temporaryOutputPath, $outputResolved)
Assert-True (Test-Path -LiteralPath $outputResolved -PathType Leaf) "The complete I6 evidence was not written."

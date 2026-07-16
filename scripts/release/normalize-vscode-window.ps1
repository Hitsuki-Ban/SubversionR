[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$UserDataRoot,

  [Parameter(Mandatory = $true)]
  [string]$EvidencePath,

  [Parameter(Mandatory = $true)]
  [string]$CodeExecutablePath,

  [Parameter(Mandatory = $true)]
  [ValidateRange(1024, 65535)]
  [int]$RemoteDebuggingPort,

  [Parameter(Mandatory = $true)]
  [string]$LaunchStartedAtUtc
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class SubversionRWindowNativeMethods
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsZoomed(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr hWnd);

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    public static IntPtr[] GetRootCodeWindows(uint processId)
    {
        const uint GW_OWNER = 4;
        var windows = new List<IntPtr>();
        EnumWindows((hWnd, lParam) =>
        {
            uint ownerProcessId;
            GetWindowThreadProcessId(hWnd, out ownerProcessId);
            if (ownerProcessId != processId || !IsWindowVisible(hWnd) || GetWindow(hWnd, GW_OWNER) != IntPtr.Zero)
            {
                return true;
            }
            var className = new StringBuilder(256);
            if (GetClassNameW(hWnd, className, className.Capacity) > 0 && className.ToString() == "Chrome_WidgetWin_1")
            {
                windows.Add(hWnd);
            }
            return true;
        }, IntPtr.Zero);
        return windows.ToArray();
    }
}
"@

$expectedWidth = 1600
$expectedHeight = 1000
$expectedDpi = 96
$swRestore = 9
$swpNoMove = 0x0002
$swpNoZOrder = 0x0004
$swpNoActivate = 0x0010
$swpNoSendChanging = 0x0400
$setWindowPosFlags = $swpNoMove -bor $swpNoZOrder -bor $swpNoActivate -bor $swpNoSendChanging
$observationTimeout = [TimeSpan]::FromSeconds(10)

function Assert-CanonicalLocalPath([string]$Path, [string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:\\') {
    throw "$Name must be a canonical local-drive absolute path: $Path"
  }
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  if (-not [string]::Equals($Path, $fullPath, [System.StringComparison]::Ordinal)) {
    throw "$Name must be a canonical local-drive absolute path: $Path"
  }
  $fullPath
}

function Get-WindowState([IntPtr]$Handle) {
  $rect = [SubversionRWindowNativeMethods+RECT]::new()
  if (-not [SubversionRWindowNativeMethods]::GetWindowRect($Handle, [ref]$rect)) {
    $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw [System.ComponentModel.Win32Exception]::new($errorCode)
  }
  [pscustomobject]@{
    left = $rect.Left
    top = $rect.Top
    right = $rect.Right
    bottom = $rect.Bottom
    width = $rect.Right - $rect.Left
    height = $rect.Bottom - $rect.Top
    maximized = [SubversionRWindowNativeMethods]::IsZoomed($Handle)
    minimized = [SubversionRWindowNativeMethods]::IsIconic($Handle)
    dpi = [int][SubversionRWindowNativeMethods]::GetDpiForWindow($Handle)
  }
}

function Select-CodeWindow(
  [string]$CanonicalUserDataRoot,
  [string]$CanonicalCodeExecutablePath,
  [DateTimeOffset]$LaunchStarted,
  [int]$Port
) {
  $deadline = [DateTimeOffset]::UtcNow.Add($observationTimeout)
  $lastDiagnostics = "not sampled"
  do {
    $listenerOwnerIds = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
      ForEach-Object { [int]$_.OwningProcess } |
      Sort-Object -Unique)
    if ($listenerOwnerIds.Count -gt 1) {
      throw "RemoteDebuggingPort $Port must have exactly one listening owner process; found $($listenerOwnerIds.Count): $($listenerOwnerIds -join ', ')."
    }
    if ($listenerOwnerIds.Count -eq 1) {
      $processId = $listenerOwnerIds[0]
      $cimProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $processId"
      $process = Get-Process -Id $processId -ErrorAction Stop
      $commandLine = [string]$cimProcess.CommandLine
      $executablePath = [string]$cimProcess.ExecutablePath
      $startTimeUtc = $process.StartTime.ToUniversalTime()
      $userDataMatches = @([regex]::Matches(
          $commandLine,
          '(?:^|\s)--user-data-dir(?:=|\s+)(?:"(?<quoted>[^"]+)"|(?<bare>\S+))',
          [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        ))
      if ($userDataMatches.Count -ne 1) {
        throw "Remote debugging owner PID $processId must expose exactly one --user-data-dir argument; found $($userDataMatches.Count)."
      }
      $parsedUserDataRoot = if ($userDataMatches[0].Groups["quoted"].Success) {
        $userDataMatches[0].Groups["quoted"].Value
      }
      else {
        $userDataMatches[0].Groups["bare"].Value
      }
      $parsedUserDataRoot = [System.IO.Path]::GetFullPath($parsedUserDataRoot)
      if (-not [string]::Equals($executablePath, $CanonicalCodeExecutablePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Remote debugging owner PID $processId executable must be $CanonicalCodeExecutablePath; observed $executablePath."
      }
      if ($startTimeUtc -lt $LaunchStarted.UtcDateTime) {
        throw "Remote debugging owner PID $processId started before this launch: $($startTimeUtc.ToString('o')) < $($LaunchStarted.ToString('o'))."
      }
      if ($commandLine -match '(?:^|\s)--type=') {
        throw "Remote debugging owner PID $processId must be the root Code.exe process without --type=."
      }
      if (-not [string]::Equals($parsedUserDataRoot, $CanonicalUserDataRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Remote debugging owner PID $processId --user-data-dir must equal $CanonicalUserDataRoot; observed $parsedUserDataRoot."
      }
      $windows = @([SubversionRWindowNativeMethods]::GetRootCodeWindows([uint32]$processId))
      if ($windows.Count -gt 1) {
        $handles = @($windows | ForEach-Object { "0x$('{0:X}' -f $_.ToInt64())" }) -join ", "
        throw "Remote debugging owner PID $processId must have exactly one visible ownerless Chrome_WidgetWin_1 window; found $($windows.Count): $handles."
      }
      if ($windows.Count -eq 1) {
        return [pscustomobject]@{
          processId = $processId
          handle = $windows[0]
          executablePath = $executablePath
          processStartedAtUtc = $startTimeUtc.ToString("o")
          parsedUserDataRoot = $parsedUserDataRoot
          listenerOwnerProcessId = $processId
        }
      }
      $lastDiagnostics = "listener owner PID=$processId passed process identity but exposed 0 matching top-level windows"
    }
    else {
      $lastDiagnostics = "RemoteDebuggingPort $Port exposed 0 listening owner processes"
    }
    Start-Sleep -Milliseconds 100
  } while ([DateTimeOffset]::UtcNow -lt $deadline)
  throw "VS Code window normalization did not find its unique native window after $([int]$observationTimeout.TotalSeconds)s: $lastDiagnostics."
}

$canonicalUserDataRoot = Assert-CanonicalLocalPath -Path $UserDataRoot -Name "UserDataRoot"
if (-not (Test-Path -LiteralPath $canonicalUserDataRoot -PathType Container)) {
  throw "UserDataRoot must be an existing directory: $canonicalUserDataRoot"
}
$canonicalEvidencePath = Assert-CanonicalLocalPath -Path $EvidencePath -Name "EvidencePath"
$evidenceParent = Split-Path -Parent $canonicalEvidencePath
if (-not (Test-Path -LiteralPath $evidenceParent -PathType Container)) {
  throw "EvidencePath parent must be an existing directory: $evidenceParent"
}
$canonicalCodeExecutablePath = Assert-CanonicalLocalPath -Path $CodeExecutablePath -Name "CodeExecutablePath"
if (-not (Test-Path -LiteralPath $canonicalCodeExecutablePath -PathType Leaf) -or (Split-Path -Leaf $canonicalCodeExecutablePath) -cne "Code.exe") {
  throw "CodeExecutablePath must be the exact Code.exe file: $canonicalCodeExecutablePath"
}
$launchStarted = [DateTimeOffset]::ParseExact(
  $LaunchStartedAtUtc,
  "o",
  [System.Globalization.CultureInfo]::InvariantCulture,
  [System.Globalization.DateTimeStyles]::RoundtripKind
)

$selected = Select-CodeWindow `
  -CanonicalUserDataRoot $canonicalUserDataRoot `
  -CanonicalCodeExecutablePath $canonicalCodeExecutablePath `
  -LaunchStarted $launchStarted `
  -Port $RemoteDebuggingPort
$handle = [IntPtr]$selected.handle
$prior = Get-WindowState -Handle $handle
if ($prior.dpi -ne $expectedDpi) {
  throw "VS Code window normalization requires DPI $expectedDpi; observed $($prior.dpi) for PID $($selected.processId)."
}

[void][SubversionRWindowNativeMethods]::ShowWindow($handle, $swRestore)
$restoreDeadline = [DateTimeOffset]::UtcNow.Add($observationTimeout)
do {
  $restored = Get-WindowState -Handle $handle
  if (-not $restored.maximized -and -not $restored.minimized) {
    break
  }
  Start-Sleep -Milliseconds 100
} while ([DateTimeOffset]::UtcNow -lt $restoreDeadline)
if ($restored.maximized -or $restored.minimized) {
  throw "VS Code window must be restored before SetWindowPos; observed maximized=$($restored.maximized), minimized=$($restored.minimized)."
}
if ($restored.dpi -ne $expectedDpi) {
  throw "VS Code restored window requires DPI $expectedDpi; observed $($restored.dpi)."
}

if (-not [SubversionRWindowNativeMethods]::SetWindowPos(
    $handle,
    [IntPtr]::Zero,
    0,
    0,
    $expectedWidth,
    $expectedHeight,
    [uint32]$setWindowPosFlags
  )) {
  $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
  throw [System.ComponentModel.Win32Exception]::new($errorCode)
}

$boundsDeadline = [DateTimeOffset]::UtcNow.Add($observationTimeout)
do {
  $observed = Get-WindowState -Handle $handle
  if (
    $observed.width -eq $expectedWidth -and
    $observed.height -eq $expectedHeight -and
    -not $observed.maximized -and
    -not $observed.minimized -and
    $observed.dpi -eq $expectedDpi
  ) {
    break
  }
  Start-Sleep -Milliseconds 100
} while ([DateTimeOffset]::UtcNow -lt $boundsDeadline)
if (
  $observed.width -ne $expectedWidth -or
  $observed.height -ne $expectedHeight -or
  $observed.maximized -or
  $observed.minimized -or
  $observed.dpi -ne $expectedDpi
) {
  throw "VS Code native window observation did not reach restored ${expectedWidth}x${expectedHeight} at DPI $expectedDpi after the single SetWindowPos call: $($observed | ConvertTo-Json -Compress)."
}

$report = [pscustomobject]@{
  schemaVersion = 1
  schema = "subversionr.release.vscode-window-normalization.v1"
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  method = "win32.SetWindowPos(SWP_NOSENDCHANGING)"
  identity = [pscustomobject]@{
    userDataRoot = $canonicalUserDataRoot
    processId = $selected.processId
    hwnd = "0x$('{0:X}' -f $handle.ToInt64())"
    executablePath = $selected.executablePath
    parsedUserDataRoot = $selected.parsedUserDataRoot
    remoteDebuggingPort = $RemoteDebuggingPort
    listenerOwnerProcessId = $selected.listenerOwnerProcessId
    launchStartedAtUtc = $launchStarted.ToString("o")
    processStartedAtUtc = $selected.processStartedAtUtc
  }
  prior = $prior
  restored = $restored
  requested = [pscustomobject]@{
    width = $expectedWidth
    height = $expectedHeight
    dpi = $expectedDpi
    setWindowPosFlags = $setWindowPosFlags
    setWindowPosFlagsHex = "0x0416"
  }
  observed = $observed
  assertions = [pscustomobject]@{
    uniqueRootProcessWindow = $true
    uniqueRemoteDebuggingListenerOwner = $true
    executablePathMatched = $true
    processStartedAfterLaunch = $true
    rootProcessHasNoTypeArgument = $true
    uniqueUserDataDirArgument = $true
    userDataRootMatched = $true
    restoredBeforeResize = $true
    singleSetWindowPosCall = $true
    exactOuterBounds = $true
    dpi96 = $true
  }
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $canonicalEvidencePath -NoNewline -Encoding utf8

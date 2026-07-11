[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$VsixPath,

  [Parameter(Mandatory = $true)]
  [string]$CodeCliPath,

  [Parameter(Mandatory = $true)]
  [string]$SvnToolsRoot,

  [Parameter(Mandatory = $true)]
  [string]$RendererCaptureDriverPath,

  [Parameter(Mandatory = $true)]
  [string]$FixtureRoot,

  [Parameter(Mandatory = $true)]
  [string]$EvidencePath,

  [ValidateRange(1024, 65535)]
  [int]$RemoteDebuggingPort = 32145,

  [ValidateRange(1, 1800)]
  [int]$ExtensionHostTimeoutSeconds = 180,

  [ValidateRange(1, 600)]
  [int]$UiReadyTimeoutSeconds = 90
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")

function Get-RepoAbsolutePath([string]$Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Get-RepoRelativePath([string]$Path) {
  [System.IO.Path]::GetRelativePath($repoRoot, $Path).Replace("\", "/")
}

function Test-IsPathWithin([string]$Path, [string]$Root) {
  $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  $pathFull = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  $pathFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-IsSamePath([string]$Left, [string]$Right) {
  $leftFull = [System.IO.Path]::GetFullPath($Left).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  $rightFull = [System.IO.Path]::GetFullPath($Right).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  [string]::Equals($leftFull, $rightFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-GeneratedPath([string]$Path, [string]$Name, [string[]]$AllowedRoots, [string]$Description) {
  $absolute = Get-RepoAbsolutePath $Path
  foreach ($allowedRoot in $AllowedRoots) {
    if (Test-IsPathWithin -Path $absolute -Root $allowedRoot) {
      return $absolute
    }
  }
  throw "$Name must resolve inside $Description`: $Path"
}

function Assert-File([string]$Path, [string]$Name) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Name must be a file: $Path"
  }
  (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
}

function Assert-CodeCliPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains("%") -or $Path.Contains("$")) {
    throw "CodeCliPath must be an explicit file path."
  }
  if (-not [System.IO.Path]::IsPathRooted($Path)) {
    throw "CodeCliPath must be an explicit absolute file path: $Path"
  }
  $resolved = Assert-File $Path "CodeCliPath"
  $leaf = Split-Path -Leaf $resolved
  if ($leaf -notin @("code.cmd", "code.exe")) {
    throw "CodeCliPath must point to code.cmd or code.exe: $Path"
  }
  $resolved
}

function Assert-SvnToolsRoot([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains("%") -or $Path.Contains("$")) {
    throw "SvnToolsRoot must be an explicit directory path."
  }
  $allowedRoots = @(
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot ".cache\native\stage\subversion-win-x64\bin")),
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-installed-source-control-ui-e2e-scripts"))
  )
  $resolved = Assert-GeneratedPath -Path $Path -Name "SvnToolsRoot" -AllowedRoots $allowedRoots -Description ".cache/native/stage/subversion-win-x64/bin or target/tests/release-installed-source-control-ui-e2e-scripts"
  if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
    throw "SvnToolsRoot must be a directory: $Path"
  }
  (Resolve-Path -LiteralPath $resolved -ErrorAction Stop).Path
}

function Assert-RendererCaptureDriverPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains("%") -or $Path.Contains("$")) {
    throw "RendererCaptureDriverPath must be an explicit file path."
  }
  $allowedRoots = @(
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot "scripts\release")),
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-installed-source-control-ui-e2e-scripts"))
  )
  $resolved = Assert-GeneratedPath -Path $Path -Name "RendererCaptureDriverPath" -AllowedRoots $allowedRoots -Description "scripts/release or target/tests/release-installed-source-control-ui-e2e-scripts"
  Assert-File $resolved "RendererCaptureDriverPath"
}

function Assert-TcpPortAvailable([int]$Port) {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse("127.0.0.1"), $Port)
  try {
    $listener.Start()
  }
  catch {
    throw "RemoteDebuggingPort must be available before launching VS Code: $Port"
  }
  finally {
    $listener.Stop()
  }
}

function Get-VsixPackageJson([string]$Path) {
  $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
  try {
    $entry = $archive.Entries | Where-Object { $_.FullName -eq "extension/package.json" } | Select-Object -First 1
    if ($null -eq $entry) {
      throw "VSIX must contain extension/package.json."
    }
    $reader = [System.IO.StreamReader]::new($entry.Open())
    try {
      $reader.ReadToEnd() | ConvertFrom-Json
    }
    finally {
      $reader.Dispose()
    }
  }
  finally {
    $archive.Dispose()
  }
}

function Get-VsixTargetPlatform([string]$Path) {
  $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
  try {
    $entry = $archive.Entries | Where-Object { $_.FullName -eq "extension.vsixmanifest" } | Select-Object -First 1
    if ($null -eq $entry) {
      throw "VSIX must contain extension.vsixmanifest."
    }
    $reader = [System.IO.StreamReader]::new($entry.Open())
    try {
      $manifestText = $reader.ReadToEnd()
    }
    finally {
      $reader.Dispose()
    }
  }
  finally {
    $archive.Dispose()
  }

  $manifest = [xml]$manifestText
  $identityNodes = @($manifest.SelectNodes("//*[local-name()='PackageManifest']/*[local-name()='Metadata']/*[local-name()='Identity']"))
  if ($identityNodes.Count -ne 1 -or [string]::IsNullOrWhiteSpace($identityNodes[0].TargetPlatform)) {
    throw "VSIX manifest Identity must contain TargetPlatform."
  }
  [string]$identityNodes[0].TargetPlatform
}

function ConvertTo-ProcessArgument([string]$Argument) {
  if ($null -eq $Argument -or $Argument.Length -eq 0) {
    return '""'
  }
  if ($Argument.Contains('"')) {
    throw "Command arguments must not contain double quotes."
  }
  if ($Argument -match '[\s&()^|<>]') {
    return '"' + $Argument + '"'
  }
  $Argument
}

function Start-CodeCliProcess([string]$Path, [string[]]$Arguments, [string]$Description) {
  $argumentLine = @($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join " "
  $process = Start-Process -FilePath $Path -ArgumentList $argumentLine -NoNewWindow -PassThru
  if ($null -eq $process) {
    throw "$Description failed to start."
  }
  $process
}

function Wait-ProcessOrKill([System.Diagnostics.Process]$Process, [int]$TimeoutSeconds, [string]$Description) {
  try {
    if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
      & taskkill.exe /PID $Process.Id /T /F | Out-Null
      [void]$Process.WaitForExit(10000)
      throw "$Description timed out after $TimeoutSeconds seconds."
    }
    if ($Process.ExitCode -ne 0) {
      throw "$Description failed with exit code $($Process.ExitCode)."
    }
  }
  finally {
    $Process.Dispose()
  }
}

function Stop-ProcessTreeBestEffort([System.Diagnostics.Process]$Process) {
  if ($null -eq $Process -or $Process.HasExited) {
    return
  }
  & taskkill.exe /PID $Process.Id /T /F | Out-Null
  [void]$Process.WaitForExit(10000)
}

function Invoke-CheckedTool([string]$Path, [string[]]$Arguments, [string]$Description) {
  $output = @(& $Path @Arguments 2>&1)
  if ($LASTEXITCODE -ne 0) {
    $text = $output | Out-String
    throw "$Description failed with exit code $LASTEXITCODE. $text"
  }
  $output
}

function Invoke-ToolProbe([string]$Path, [string[]]$Arguments) {
  $output = @(& $Path @Arguments 2>&1)
  [pscustomobject]@{
    exitCode = $LASTEXITCODE
    output = $output
  }
}

function Invoke-RendererCaptureDriver([string]$DriverPath, [int]$Port, [string]$CaptureRoot, [string]$ExpectationsPath, [string]$Target) {
  $output = @(& pnpm exec node $DriverPath `
      --remote-debugging-port "$Port" `
      --output-root $CaptureRoot `
      --expectations-path $ExpectationsPath `
      --target $Target 2>&1)
  if ($LASTEXITCODE -ne 0) {
    $text = $output | Out-String
    throw "Renderer capture driver failed with exit code $LASTEXITCODE. $text"
  }
}

function Get-CodeCliVersion([string]$Path) {
  $versionOutput = @(& $Path --version)
  if ($LASTEXITCODE -ne 0) {
    throw "VS Code CLI version probe failed with exit code $LASTEXITCODE."
  }
  if ($versionOutput.Count -eq 0) {
    throw "VS Code CLI version probe returned no output."
  }
  $versionOutput
}

function Get-DirectoryTreeSha256([string]$Root) {
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    throw "Directory tree root must exist: $Root"
  }

  $records = @(Get-ChildItem -LiteralPath $Root -Recurse -Force |
    Sort-Object FullName |
    ForEach-Object {
      $relativePath = [System.IO.Path]::GetRelativePath($Root, $_.FullName).Replace("\", "/")
      if ($_.PSIsContainer) {
        "D|$relativePath"
      }
      else {
        $fileSha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "F|$relativePath|$($_.Length)|$fileSha256"
      }
    })
  $bytes = [System.Text.Encoding]::UTF8.GetBytes(($records -join "`n"))
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    ($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
  }
  finally {
    $sha256.Dispose()
  }
}

function Find-InstalledPackage([string]$ExtensionsRoot, [string]$Publisher, [string]$Name, [string]$Version) {
  $matches = @(Get-ChildItem -LiteralPath $ExtensionsRoot -Directory -Recurse -Depth 2 |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "package.json") -PathType Leaf } |
    ForEach-Object {
      $packageJson = Get-Content -Raw -LiteralPath (Join-Path $_.FullName "package.json") | ConvertFrom-Json
      if ($packageJson.publisher -eq $Publisher -and $packageJson.name -eq $Name -and $packageJson.version -eq $Version) {
        $_.FullName
      }
    })
  if ($matches.Count -ne 1) {
    throw "Expected exactly one installed extension package $Publisher.$Name@$Version; found $($matches.Count)."
  }
  $matches[0]
}

function New-SourceControlUiFixture(
  [string]$Root,
  [string]$SvnExe,
  [string]$SvnAdminExe,
  [ValidateRange(1, 4096)]
  [int]$UnversionedItemCount = 1,
  [ValidateRange(0, 4096)]
  [int]$ModifiedLoadItemCount = 0
) {
  $repoPath = Join-Path $Root "repo"
  $importRoot = Join-Path $Root "import"
  $wcRoot = Join-Path $Root "workspace\wc"
  $svnCliConfigRoot = Join-Path $Root "svn-cli-config"
  $svnRuntimeAppDataRoot = Join-Path $Root "runtime-appdata"
  $svnRuntimeConfigRoot = Join-Path $svnRuntimeAppDataRoot "Subversion"
  New-Item -ItemType Directory -Force -Path (Join-Path $importRoot "trunk\src"), $svnCliConfigRoot, $svnRuntimeConfigRoot | Out-Null
  @'
[miscellany]
global-ignores =
enable-auto-props = no
'@ | Set-Content -LiteralPath (Join-Path $svnRuntimeConfigRoot "config") -NoNewline -Encoding utf8
  @'
[global]
store-passwords = no
store-auth-creds = no
'@ | Set-Content -LiteralPath (Join-Path $svnRuntimeConfigRoot "servers") -NoNewline -Encoding utf8
  Set-Content -LiteralPath (Join-Path $importRoot "trunk\src\tracked.txt") -Value "initial`n" -NoNewline -Encoding utf8
  $modifiedLoadPaths = @()
  if ($ModifiedLoadItemCount -gt 0) {
    New-Item -ItemType Directory -Force -Path (Join-Path $importRoot "trunk\load") | Out-Null
    foreach ($index in 1..$ModifiedLoadItemCount) {
      $relativePath = "load/modified-{0:D3}.txt" -f $index
      Set-Content -LiteralPath (Join-Path $importRoot ("trunk\" + $relativePath.Replace("/", "\"))) -Value "initial load item $index`n" -NoNewline -Encoding utf8
      $modifiedLoadPaths += $relativePath
    }
  }

  Invoke-CheckedTool -Path $SvnAdminExe -Arguments @("create", $repoPath) -Description "svnadmin create fixture repository" | Out-Null
  $repoUrl = "file:///" + $repoPath.Replace("\", "/")
  Invoke-CheckedTool -Path $SvnExe -Arguments @(
    "import",
    $importRoot,
    $repoUrl,
    "-m",
    "seed M7j3 fixture",
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $svnCliConfigRoot
  ) -Description "svn import fixture content" | Out-Null
  Invoke-CheckedTool -Path $SvnExe -Arguments @(
    "checkout",
    "$repoUrl/trunk",
    $wcRoot,
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $svnCliConfigRoot
  ) -Description "svn checkout fixture working copy" | Out-Null

  Set-Content -LiteralPath (Join-Path $wcRoot "src\tracked.txt") -Value "modified by M7j3`n" -NoNewline -Encoding utf8
  foreach ($relativePath in $modifiedLoadPaths) {
    Set-Content -LiteralPath (Join-Path $wcRoot $relativePath.Replace("/", "\")) -Value "modified load item $relativePath by M7j3`n" -NoNewline -Encoding utf8
  }
  $unversionedPaths = @()
  if ($UnversionedItemCount -eq 1) {
    Set-Content -LiteralPath (Join-Path $wcRoot "scratch.txt") -Value "unversioned by M7j3`n" -NoNewline -Encoding utf8
    $unversionedPaths = @("scratch.txt")
  }
  else {
    foreach ($index in 1..$UnversionedItemCount) {
      $relativePath = "unversioned-load-{0:D3}.txt" -f $index
      Set-Content -LiteralPath (Join-Path $wcRoot $relativePath.Replace("/", "\")) -Value "unversioned load item $index by M7j3`n" -NoNewline -Encoding utf8
      $unversionedPaths += $relativePath
    }
  }

  $svnRoot = Join-Path $wcRoot ".svn"
  [pscustomobject]@{
    repoPath = $repoPath
    repoUrl = $repoUrl
    importRoot = $importRoot
    workingCopyRoot = $wcRoot
    svnCliConfigRoot = $svnCliConfigRoot
    svnRuntimeAppDataRoot = $svnRuntimeAppDataRoot
    svnRuntimeConfigRoot = $svnRuntimeConfigRoot
    svnRoot = $svnRoot
    unversionedItemCount = $UnversionedItemCount
    unversionedPaths = $unversionedPaths
    modifiedLoadItemCount = $ModifiedLoadItemCount
    modifiedLoadPaths = $modifiedLoadPaths
    svnTreeBeforeSha256 = Get-DirectoryTreeSha256 $svnRoot
  }
}

function New-SourceControlUiChangelistFixture(
  [string]$Root,
  [string]$SvnExe,
  [string]$SvnAdminExe,
  [ValidateRange(0, 4096)]
  [int]$ModifiedLoadItemCount = 0,
  [string]$Changelist = "review"
) {
  $fixture = New-SourceControlUiFixture -Root $Root -SvnExe $SvnExe -SvnAdminExe $SvnAdminExe -ModifiedLoadItemCount $ModifiedLoadItemCount
  Invoke-CheckedTool -Path $SvnExe -Arguments @(
    "changelist",
    $Changelist,
    (Join-Path $fixture.workingCopyRoot "src\tracked.txt"),
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $fixture.svnCliConfigRoot
  ) -Description "svn changelist fixture tracked file" | Out-Null
  $fixture | Add-Member -NotePropertyName changelist -NotePropertyValue $Changelist
  $fixture
}

function New-SourceControlUiLockFixture(
  [string]$Root,
  [string]$SvnExe,
  [string]$SvnAdminExe
) {
  $fixture = New-SourceControlUiFixture -Root $Root -SvnExe $SvnExe -SvnAdminExe $SvnAdminExe
  $relativePath = "src/needs-lock.txt"
  $workingCopyPath = Join-Path $fixture.workingCopyRoot $relativePath.Replace("/", "\")
  $needsLockPropertyValuePath = Join-Path $Root "needs-lock-property-value.txt"
  Set-Content -LiteralPath $workingCopyPath -Value "needs lock baseline`n" -NoNewline -Encoding utf8
  Set-Content -LiteralPath $needsLockPropertyValuePath -Value "*" -NoNewline -Encoding utf8
  Invoke-CheckedTool -Path $SvnExe -Arguments @(
    "add",
    $workingCopyPath,
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $fixture.svnCliConfigRoot
  ) -Description "svn add needs-lock fixture file" | Out-Null
  Invoke-CheckedTool -Path $SvnExe -Arguments @(
    "propset",
    "svn:needs-lock",
    "--file",
    $needsLockPropertyValuePath,
    $workingCopyPath,
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $fixture.svnCliConfigRoot
  ) -Description "svn propset needs-lock fixture file" | Out-Null
  Invoke-CheckedTool -Path $SvnExe -Arguments @(
    "commit",
    $workingCopyPath,
    "-m",
    "seed needs-lock fixture",
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $fixture.svnCliConfigRoot
  ) -Description "svn commit needs-lock fixture file" | Out-Null
  $fixture | Add-Member -NotePropertyName lockRelativePath -NotePropertyValue $relativePath
  $fixture | Add-Member -NotePropertyName lockWorkingCopyPath -NotePropertyValue $workingCopyPath
  $fixture | Add-Member -NotePropertyName lockComment -NotePropertyValue "Beta-E installed lock evidence"
  $fixture
}

function New-SourceControlUiBranchCreateFixture(
  [string]$Root,
  [string]$SvnExe,
  [string]$SvnAdminExe
) {
  $fixture = New-SourceControlUiFixture -Root $Root -SvnExe $SvnExe -SvnAdminExe $SvnAdminExe
  $commonArguments = @(
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $fixture.svnCliConfigRoot
  )
  Invoke-CheckedTool -Path $SvnExe -Arguments (@(
        "mkdir",
        "$($fixture.repoUrl)/branches",
        "-m",
        "seed branch parent"
      ) + $commonArguments) -Description "svn mkdir Branch/Tag create fixture branches parent" | Out-Null
  $fixture | Add-Member -NotePropertyName branchSourceUrl -NotePropertyValue "$($fixture.repoUrl)/trunk"
  $fixture | Add-Member -NotePropertyName branchDestinationUrl -NotePropertyValue "$($fixture.repoUrl)/branches/beta-installed-e2e"
  $fixture | Add-Member -NotePropertyName branchMessage -NotePropertyValue "Create installed Beta branch"
  $fixture
}

function New-SourceControlUiSwitchFixture(
  [string]$Root,
  [string]$SvnExe,
  [string]$SvnAdminExe
) {
  $fixture = New-SourceControlUiFixture -Root $Root -SvnExe $SvnExe -SvnAdminExe $SvnAdminExe
  $commonArguments = @(
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $fixture.svnCliConfigRoot
  )
  $branchUrl = "$($fixture.repoUrl)/branches/beta-installed-switch"
  Invoke-CheckedTool -Path $SvnExe -Arguments (@(
        "mkdir",
        "$($fixture.repoUrl)/branches",
        "-m",
        "seed switch branch parent"
      ) + $commonArguments) -Description "svn mkdir Switch fixture branches parent" | Out-Null
  Invoke-CheckedTool -Path $SvnExe -Arguments (@(
        "copy",
        "$($fixture.repoUrl)/trunk",
        $branchUrl,
        "-m",
        "seed switch branch"
      ) + $commonArguments) -Description "svn copy Switch fixture branch" | Out-Null
  $fixture | Add-Member -NotePropertyName switchTargetUrl -NotePropertyValue $branchUrl
  $fixture
}

function New-SourceControlUiUpdateFixture(
  [string]$Root,
  [string]$SvnExe,
  [string]$SvnAdminExe
) {
  $repoPath = Join-Path $Root "repo"
  $importRoot = Join-Path $Root "import"
  $wcRoot = Join-Path $Root "workspace\wc"
  $peerWcRoot = Join-Path $Root "peer\wc"
  $svnCliConfigRoot = Join-Path $Root "svn-cli-config"
  $svnRuntimeAppDataRoot = Join-Path $Root "runtime-appdata"
  $svnRuntimeConfigRoot = Join-Path $svnRuntimeAppDataRoot "Subversion"
  New-Item -ItemType Directory -Force -Path (Join-Path $importRoot "trunk\src"), $svnCliConfigRoot, $svnRuntimeConfigRoot | Out-Null
  @'
[miscellany]
global-ignores =
enable-auto-props = no
'@ | Set-Content -LiteralPath (Join-Path $svnRuntimeConfigRoot "config") -NoNewline -Encoding utf8
  @'
[global]
store-passwords = no
store-auth-creds = no
'@ | Set-Content -LiteralPath (Join-Path $svnRuntimeConfigRoot "servers") -NoNewline -Encoding utf8
  Set-Content -LiteralPath (Join-Path $importRoot "trunk\top-level.txt") -Value "initial update root`n" -NoNewline -Encoding utf8
  Set-Content -LiteralPath (Join-Path $importRoot "trunk\src\tracked.txt") -Value "initial update child`n" -NoNewline -Encoding utf8

  $commonArguments = @(
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $svnCliConfigRoot
  )
  Invoke-CheckedTool -Path $SvnAdminExe -Arguments @("create", $repoPath) -Description "svnadmin create update fixture repository" | Out-Null
  $repoUrl = "file:///" + $repoPath.Replace("\", "/")
  Invoke-CheckedTool -Path $SvnExe -Arguments (@(
        "import",
        $importRoot,
        $repoUrl,
        "-m",
        "seed update fixture"
      ) + $commonArguments) -Description "svn import update fixture content" | Out-Null
  Invoke-CheckedTool -Path $SvnExe -Arguments (@(
        "checkout",
        "$repoUrl/trunk",
        $wcRoot
      ) + $commonArguments) -Description "svn checkout update fixture working copy" | Out-Null
  Invoke-CheckedTool -Path $SvnExe -Arguments (@(
        "checkout",
        "$repoUrl/trunk",
        $peerWcRoot
      ) + $commonArguments) -Description "svn checkout update fixture peer working copy" | Out-Null
  Set-Content -LiteralPath (Join-Path $peerWcRoot "top-level.txt") -Value "updated by Beta-C r2`n" -NoNewline -Encoding utf8
  Set-Content -LiteralPath (Join-Path $peerWcRoot "src\tracked.txt") -Value "updated child by Beta-C r2`n" -NoNewline -Encoding utf8
  Invoke-CheckedTool -Path $SvnExe -Arguments (@(
        "commit",
        (Join-Path $peerWcRoot "top-level.txt"),
        (Join-Path $peerWcRoot "src\tracked.txt"),
        "-m",
        "prepare update to revision fixture"
      ) + $commonArguments) -Description "svn commit update fixture revision 2" | Out-Null

  [pscustomobject]@{
    repoPath = $repoPath
    repoUrl = $repoUrl
    importRoot = $importRoot
    workingCopyRoot = $wcRoot
    peerWorkingCopyRoot = $peerWcRoot
    svnCliConfigRoot = $svnCliConfigRoot
    svnRuntimeAppDataRoot = $svnRuntimeAppDataRoot
    svnRuntimeConfigRoot = $svnRuntimeConfigRoot
    svnRoot = Join-Path $wcRoot ".svn"
    targetRelativePath = "top-level.txt"
    expectedRevision = 2
    expectedUpdatedContent = "updated by Beta-C r2`n"
    svnTreeBeforeSha256 = Get-DirectoryTreeSha256 (Join-Path $wcRoot ".svn")
  }
}

function Get-CommitAllRepositoryOracle(
  [string]$SvnExe,
  [pscustomobject]$Fixture,
  [string]$ExpectedCommitMessage,
  [string]$ExpectedTrackedContent
) {
  $trackedFileUrl = "$($Fixture.repoUrl)/trunk/src/tracked.txt"
  $unversionedScratchUrl = "$($Fixture.repoUrl)/trunk/scratch.txt"
  $commonArguments = @(
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $Fixture.svnCliConfigRoot
  )

  $trackedContent = (Invoke-CheckedTool -Path $SvnExe -Arguments (@("cat", $trackedFileUrl) + $commonArguments) -Description "svn cat Commit All committed tracked file") -join "`n"
  if ($trackedContent -ne $ExpectedTrackedContent) {
    throw "Commit All repository oracle expected '$ExpectedTrackedContent' at $trackedFileUrl, got '$trackedContent'."
  }

  $latestLog = (Invoke-CheckedTool -Path $SvnExe -Arguments (@("log", "-l", "1", $trackedFileUrl) + $commonArguments) -Description "svn log Commit All committed tracked file") -join "`n"
  if (-not $latestLog.Contains($ExpectedCommitMessage)) {
    throw "Commit All repository oracle did not find the expected commit message in the latest repository log for $trackedFileUrl."
  }

  $scratchProbe = Invoke-ToolProbe -Path $SvnExe -Arguments (@("cat", $unversionedScratchUrl) + $commonArguments)
  if ($scratchProbe.exitCode -eq 0) {
    throw "Commit All repository oracle unexpectedly found unversioned scratch.txt in the repository."
  }

  [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eCommitAllRepositoryOracle"
    trackedFileUrl = $trackedFileUrl
    trackedFileContent = $trackedContent
    latestLogContainsCommitMessage = $true
    unversionedScratchUrl = $unversionedScratchUrl
    unversionedScratchAbsentFromRepository = $true
  }
}

function Get-CheckoutRepositoryOracle(
  [string]$SvnExe,
  [pscustomobject]$Fixture,
  [string]$CheckoutTargetRoot
) {
  $trackedFileUrl = "$($Fixture.repoUrl)/trunk/src/tracked.txt"
  $checkedOutTrackedPath = Join-Path $CheckoutTargetRoot "src\tracked.txt"
  $commonArguments = @(
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $Fixture.svnCliConfigRoot
  )

  $repositoryContent = (Invoke-CheckedTool -Path $SvnExe -Arguments (@("cat", $trackedFileUrl) + $commonArguments) -Description "svn cat Checkout Repository baseline file") -join "`n"
  if (-not (Test-Path -LiteralPath $checkedOutTrackedPath -PathType Leaf)) {
    throw "Checkout Repository oracle expected checked-out file at $checkedOutTrackedPath."
  }
  $checkedOutContent = (Get-Content -LiteralPath $checkedOutTrackedPath) -join "`n"
  if ($checkedOutContent -ne $repositoryContent) {
    throw "Checkout Repository oracle expected checked-out content '$repositoryContent' at $checkedOutTrackedPath, got '$checkedOutContent'."
  }

  [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eCheckoutRepositoryOracle"
    trackedFileUrl = $trackedFileUrl
    checkedOutTrackedPath = Get-RepoRelativePath $checkedOutTrackedPath
    repositoryBaselineContent = $repositoryContent
    checkedOutFileContent = $checkedOutContent
    checkedOutBaselineContentMatched = $true
  }
}

function Get-CheckoutExistingDirectoryObstructionWorkingCopyOracle(
  [string]$SvnExe,
  [pscustomobject]$Workflow
) {
  $workingCopyRoot = [string]$Workflow.target.workingCopyRoot
  $obstructionPath = [string]$Workflow.target.obstructionPath
  $expectedConflictDetail = "local file unversioned, incoming dir add upon update"

  if ([string]::IsNullOrWhiteSpace($workingCopyRoot) -or -not (Test-Path -LiteralPath (Join-Path $workingCopyRoot ".svn") -PathType Container)) {
    throw "Checkout existing-directory obstruction oracle expected working-copy metadata at $workingCopyRoot."
  }
  if ([string]::IsNullOrWhiteSpace($obstructionPath) -or -not (Test-Path -LiteralPath $obstructionPath -PathType Leaf)) {
    throw "Checkout existing-directory obstruction oracle expected the obstructing local file to remain at $obstructionPath."
  }

  $statusOutput = Invoke-CheckedTool `
    -Path $SvnExe `
    -Arguments @("status", $workingCopyRoot, "--non-interactive", "--no-auth-cache") `
    -Description "svn status Checkout existing-directory obstruction working copy"
  $statusText = ($statusOutput | ForEach-Object { [string]$_ }) -join "`n"
  if (-not $statusText.Contains($expectedConflictDetail) -or -not $statusText.Contains("Tree conflicts: 1")) {
    throw "Checkout existing-directory obstruction oracle expected SVN status to report one tree conflict for the obstructing file. Status output: $statusText"
  }

  $obstructionHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $obstructionPath).Hash.ToLowerInvariant()
  if ($obstructionHash -ne ([string]$Workflow.target.obstructionHashBefore)) {
    throw "Checkout existing-directory obstruction oracle expected the obstructing file hash to stay $($Workflow.target.obstructionHashBefore), got $obstructionHash."
  }

  [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eCheckoutExistingDirectoryObstructionWorkingCopyOracle"
    statusText = $statusText
    conflictPath = [string]$Workflow.target.conflictPath
    obstructionPath = Get-RepoRelativePath $obstructionPath
    obstructionSha256 = $obstructionHash
    expectedConflictDetail = $expectedConflictDetail
    treeConflictPresent = $true
    obstructionPreserved = $true
  }
}

function Get-UpdateToRevisionRepositoryOracle(
  [string]$SvnExe,
  [pscustomobject]$Fixture
) {
  $updatedFileUrl = "$($Fixture.repoUrl)/trunk/$($Fixture.targetRelativePath)"
  $updatedFilePath = Join-Path $Fixture.workingCopyRoot $Fixture.targetRelativePath
  $commonArguments = @(
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $Fixture.svnCliConfigRoot
  )

  $repositoryContent = (Invoke-CheckedTool -Path $SvnExe -Arguments (@("cat", $updatedFileUrl, "-r", ([string]$Fixture.expectedRevision)) + $commonArguments) -Description "svn cat Update to Revision requested revision file") -join "`n"
  if (-not (Test-Path -LiteralPath $updatedFilePath -PathType Leaf)) {
    throw "Update to Revision oracle expected updated file at $updatedFilePath."
  }
  $workingCopyContent = (Get-Content -LiteralPath $updatedFilePath) -join "`n"
  if ($workingCopyContent -ne $repositoryContent) {
    throw "Update to Revision oracle expected working-copy content '$repositoryContent' at $updatedFilePath, got '$workingCopyContent'."
  }

  [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eUpdateToRevisionRepositoryOracle"
    updatedFileUrl = $updatedFileUrl
    requestedRevision = $Fixture.expectedRevision
    updatedFilePath = Get-RepoRelativePath $updatedFilePath
    repositoryRevisionContent = $repositoryContent
    workingCopyFileContent = $workingCopyContent
    updatedRevisionContentMatched = $true
  }
}

function Get-BranchCreateRepositoryOracle(
  [string]$SvnExe,
  [pscustomobject]$Fixture
) {
  $sourceTrackedUrl = "$($Fixture.branchSourceUrl)/src/tracked.txt"
  $branchTrackedUrl = "$($Fixture.branchDestinationUrl)/src/tracked.txt"
  $commonArguments = @(
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $Fixture.svnCliConfigRoot
  )

  $sourceContent = (Invoke-CheckedTool -Path $SvnExe -Arguments (@("cat", $sourceTrackedUrl) + $commonArguments) -Description "svn cat Branch/Tag source tracked file") -join "`n"
  $branchContent = (Invoke-CheckedTool -Path $SvnExe -Arguments (@("cat", $branchTrackedUrl) + $commonArguments) -Description "svn cat Branch/Tag created branch tracked file") -join "`n"
  if ($branchContent -ne $sourceContent) {
    throw "Branch/Tag repository oracle expected destination content '$sourceContent' at $branchTrackedUrl, got '$branchContent'."
  }

  $latestLog = (Invoke-CheckedTool -Path $SvnExe -Arguments (@("log", "-v", "-l", "1", $Fixture.branchDestinationUrl) + $commonArguments) -Description "svn log Branch/Tag created branch") -join "`n"
  if (-not $latestLog.Contains($Fixture.branchMessage)) {
    throw "Branch/Tag repository oracle did not find the expected branch message in the latest repository log for $($Fixture.branchDestinationUrl)."
  }
  if (-not ($latestLog -match "\bA\s+/branches/beta-installed-e2e\s+\(from /trunk:(?<revision>[0-9]+)\)")) {
    throw "Branch/Tag repository oracle did not find SVN copyfrom metadata for $($Fixture.branchDestinationUrl) in the latest repository log."
  }
  $copyFromRevision = [int]$Matches.revision
  if ($copyFromRevision -le 0) {
    throw "Branch/Tag repository oracle found invalid SVN copyfrom revision '$copyFromRevision' for $($Fixture.branchDestinationUrl)."
  }

  [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eBranchCreateRepositoryOracle"
    sourceUrl = $Fixture.branchSourceUrl
    destinationUrl = $Fixture.branchDestinationUrl
    sourceTrackedUrl = $sourceTrackedUrl
    branchTrackedUrl = $branchTrackedUrl
    sourceContent = $sourceContent
    branchContent = $branchContent
    branchContentMatched = $true
    latestLogContainsBranchMessage = $true
    copyFromPath = "/trunk"
    copyFromRevision = $copyFromRevision
    copyFromPathMatched = $true
    copyFromRevisionMatched = $copyFromRevision -gt 0
  }
}

function Get-SwitchWorkingCopyOracle(
  [string]$SvnExe,
  [pscustomobject]$Fixture
) {
  $commonArguments = @(
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $Fixture.svnCliConfigRoot
  )
  $workingCopyInfo = (Invoke-CheckedTool -Path $SvnExe -Arguments (@("info", $Fixture.workingCopyRoot) + $commonArguments) -Description "svn info switched working copy") -join "`n"
  if (-not $workingCopyInfo.Contains("URL: $($Fixture.switchTargetUrl)")) {
    throw "Switch working-copy oracle expected working copy URL '$($Fixture.switchTargetUrl)' in svn info output."
  }

  [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eSwitchWorkingCopyOracle"
    workingCopyRoot = Get-RepoRelativePath $Fixture.workingCopyRoot
    expectedUrl = $Fixture.switchTargetUrl
    infoOutput = $workingCopyInfo
    workingCopyUrlMatched = $true
  }
}

function Get-CommitSelectedRepositoryOracle(
  [string]$SvnExe,
  [pscustomobject]$Fixture,
  [string]$ExpectedCommitMessage,
  [string]$ExpectedTrackedContent,
  [string]$ExpectedUnselectedRepositoryContent
) {
  $trackedFileUrl = "$($Fixture.repoUrl)/trunk/src/tracked.txt"
  $unselectedFileUrl = "$($Fixture.repoUrl)/trunk/load/modified-001.txt"
  $commonArguments = @(
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $Fixture.svnCliConfigRoot
  )

  $trackedContent = (Invoke-CheckedTool -Path $SvnExe -Arguments (@("cat", $trackedFileUrl) + $commonArguments) -Description "svn cat Commit Selected committed tracked file") -join "`n"
  if ($trackedContent -ne $ExpectedTrackedContent) {
    throw "Commit Selected repository oracle expected '$ExpectedTrackedContent' at $trackedFileUrl, got '$trackedContent'."
  }

  $unselectedContent = (Invoke-CheckedTool -Path $SvnExe -Arguments (@("cat", $unselectedFileUrl) + $commonArguments) -Description "svn cat Commit Selected unselected file") -join "`n"
  if ($unselectedContent -ne $ExpectedUnselectedRepositoryContent) {
    throw "Commit Selected repository oracle expected '$ExpectedUnselectedRepositoryContent' at $unselectedFileUrl, got '$unselectedContent'."
  }

  $latestLog = (Invoke-CheckedTool -Path $SvnExe -Arguments (@("log", "-l", "1", $trackedFileUrl) + $commonArguments) -Description "svn log Commit Selected committed tracked file") -join "`n"
  if (-not $latestLog.Contains($ExpectedCommitMessage)) {
    throw "Commit Selected repository oracle did not find the expected commit message in the latest repository log for $trackedFileUrl."
  }

  [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eCommitSelectedRepositoryOracle"
    trackedFileUrl = $trackedFileUrl
    trackedFileContent = $trackedContent
    unselectedFileUrl = $unselectedFileUrl
    unselectedFileRepositoryContent = $unselectedContent
    latestLogContainsCommitMessage = $true
    unselectedFileRemainedUncommitted = $true
  }
}

function Get-AddToIgnoreWorkingCopyOracle(
  [string]$SvnExe,
  [pscustomobject]$Fixture,
  [string]$ExpectedPattern
) {
  $commonArguments = @(
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $Fixture.svnCliConfigRoot
  )
  $propertyValue = @(Invoke-CheckedTool -Path $SvnExe -Arguments (@("propget", "svn:ignore", $Fixture.workingCopyRoot) + $commonArguments) -Description "svn propget Add to Ignore working-copy property")
  $patterns = @($propertyValue | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_.Length -gt 0 })
  if ($patterns -notcontains $ExpectedPattern) {
    throw "Add to Ignore oracle expected svn:ignore pattern '$ExpectedPattern', got '$($patterns -join ', ')'."
  }

  $status = @(Invoke-CheckedTool -Path $SvnExe -Arguments (@("status", "--no-ignore", $Fixture.workingCopyRoot) + $commonArguments) -Description "svn status --no-ignore Add to Ignore working copy")
  $ignoredStatusPresent = @($status | Where-Object {
      $line = $_.ToString()
      $line.Length -gt 0 -and $line[0] -eq "I" -and $line.Replace("\", "/").Contains($ExpectedPattern)
    }).Count -gt 0
  if (-not $ignoredStatusPresent) {
    throw "Add to Ignore oracle expected svn status --no-ignore to report ignored pattern '$ExpectedPattern'."
  }

  [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eAddToIgnoreWorkingCopyOracle"
    workingCopyRoot = Get-RepoRelativePath $Fixture.workingCopyRoot
    propertyName = "svn:ignore"
    expectedPattern = $ExpectedPattern
    patterns = $patterns
    ignorePatternPresent = $true
    ignoredStatusPresent = $ignoredStatusPresent
  }
}

function Get-CommitChangelistRepositoryOracle(
  [string]$SvnExe,
  [pscustomobject]$Fixture,
  [string]$ExpectedCommitMessage,
  [string]$ExpectedTrackedContent
) {
  $trackedFileUrl = "$($Fixture.repoUrl)/trunk/src/tracked.txt"
  $commonArguments = @(
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $Fixture.svnCliConfigRoot
  )
  $trackedContent = (Invoke-CheckedTool -Path $SvnExe -Arguments (@("cat", $trackedFileUrl) + $commonArguments) -Description "svn cat Commit Changelist committed tracked file") -join "`n"
  if ($trackedContent -ne $ExpectedTrackedContent) {
    throw "Commit Changelist repository oracle expected '$ExpectedTrackedContent' at $trackedFileUrl, got '$trackedContent'."
  }

  $latestLog = (Invoke-CheckedTool -Path $SvnExe -Arguments (@("log", "-l", "1", $trackedFileUrl) + $commonArguments) -Description "svn log Commit Changelist committed tracked file") -join "`n"
  if (-not $latestLog.Contains($ExpectedCommitMessage)) {
    throw "Commit Changelist repository oracle did not find the expected commit message in the latest repository log for $trackedFileUrl."
  }

  [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eCommitChangelistRepositoryOracle"
    trackedFileUrl = $trackedFileUrl
    trackedFileContent = $trackedContent
    latestLogContainsCommitMessage = $true
  }
}

function Get-LockHeldWorkingCopyOracle(
  [string]$SvnExe,
  [pscustomobject]$Fixture
) {
  $commonArguments = @(
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $Fixture.svnCliConfigRoot
  )
  $info = (Invoke-CheckedTool -Path $SvnExe -Arguments (@("info", $Fixture.lockWorkingCopyPath) + $commonArguments) -Description "svn info locked needs-lock fixture file") -join "`n"
  if ($info -notlike "*Lock Token:*") {
    throw "Lock held oracle expected svn info to expose a Lock Token for $($Fixture.lockRelativePath)."
  }
  if ($info -notlike "*Lock Owner:*") {
    throw "Lock held oracle expected svn info to expose a Lock Owner for $($Fixture.lockRelativePath)."
  }
  [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eLockHeldWorkingCopyOracle"
    generatedAt = (Get-Date).ToUniversalTime().ToString("o")
    path = $Fixture.lockRelativePath
    svnInfoContainsLockToken = $true
    svnInfoContainsLockOwner = $true
  }
}

function Get-LockUnlockWorkingCopyOracle(
  [string]$SvnExe,
  [pscustomobject]$Fixture
) {
  $commonArguments = @(
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $Fixture.svnCliConfigRoot
  )
  $needsLock = (Invoke-CheckedTool -Path $SvnExe -Arguments (@("propget", "svn:needs-lock", $Fixture.lockWorkingCopyPath) + $commonArguments) -Description "svn propget needs-lock fixture file after unlock") -join "`n"
  if ($needsLock.Trim() -ne "*") {
    throw "Lock/unlock working-copy oracle expected svn:needs-lock to remain '*', got '$needsLock'."
  }
  $info = (Invoke-CheckedTool -Path $SvnExe -Arguments (@("info", $Fixture.lockWorkingCopyPath) + $commonArguments) -Description "svn info unlocked needs-lock fixture file") -join "`n"
  if ($info -like "*Lock Token:*") {
    throw "Lock/unlock working-copy oracle expected svn info to omit Lock Token after unlock."
  }
  [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eLockUnlockWorkingCopyOracle"
    generatedAt = (Get-Date).ToUniversalTime().ToString("o")
    path = $Fixture.lockRelativePath
    needsLockProperty = $needsLock.Trim()
    svnInfoLockTokenAbsentAfterUnlock = $true
  }
}

function Get-CommitSelectedMultiSelectionRepositoryOracle(
  [string]$SvnExe,
  [pscustomobject]$Fixture,
  [string]$ExpectedCommitMessage,
  [string]$ExpectedTrackedContent,
  [string]$ExpectedLoadContent
) {
  $trackedFileUrl = "$($Fixture.repoUrl)/trunk/src/tracked.txt"
  $loadFileUrl = "$($Fixture.repoUrl)/trunk/load/modified-001.txt"
  $commonArguments = @(
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $Fixture.svnCliConfigRoot
  )

  $trackedContent = (Invoke-CheckedTool -Path $SvnExe -Arguments (@("cat", $trackedFileUrl) + $commonArguments) -Description "svn cat Commit Selected multi-selection committed tracked file") -join "`n"
  if ($trackedContent -ne $ExpectedTrackedContent) {
    throw "Commit Selected multi-selection repository oracle expected '$ExpectedTrackedContent' at $trackedFileUrl, got '$trackedContent'."
  }

  $loadContent = (Invoke-CheckedTool -Path $SvnExe -Arguments (@("cat", $loadFileUrl) + $commonArguments) -Description "svn cat Commit Selected multi-selection committed load file") -join "`n"
  if ($loadContent -ne $ExpectedLoadContent) {
    throw "Commit Selected multi-selection repository oracle expected '$ExpectedLoadContent' at $loadFileUrl, got '$loadContent'."
  }

  $latestLog = (Invoke-CheckedTool -Path $SvnExe -Arguments (@("log", "-l", "1", $trackedFileUrl) + $commonArguments) -Description "svn log Commit Selected multi-selection committed tracked file") -join "`n"
  if (-not $latestLog.Contains($ExpectedCommitMessage)) {
    throw "Commit Selected multi-selection repository oracle did not find the expected commit message in the latest repository log for $trackedFileUrl."
  }

  [pscustomobject]@{
    kind = "subversionr.installedSourceControlUiE2eCommitSelectedMultiSelectionRepositoryOracle"
    trackedFileUrl = $trackedFileUrl
    trackedFileContent = $trackedContent
    loadFileUrl = $loadFileUrl
    loadFileContent = $loadContent
    latestLogContainsCommitMessage = $true
    allSelectedFilesCommitted = $true
  }
}

function New-SourceControlUiLazyExternalProviderFixture(
  [string]$Root,
  [string]$SvnExe,
  [string]$SvnAdminExe,
  [ValidateRange(0, 4096)]
  [int]$ParentModifiedLoadItemCount = 0,
  [ValidateRange(0, 4096)]
  [int]$ExternalModifiedLoadItemCount = 0
) {
  $parentFixture = New-SourceControlUiFixture -Root (Join-Path $Root "parent") -SvnExe $SvnExe -SvnAdminExe $SvnAdminExe -ModifiedLoadItemCount $ParentModifiedLoadItemCount
  $directoryExternalFixture = New-SourceControlUiFixture -Root (Join-Path $Root "directory-external") -SvnExe $SvnExe -SvnAdminExe $SvnAdminExe -ModifiedLoadItemCount $ExternalModifiedLoadItemCount
  $externalParent = Join-Path $parentFixture.workingCopyRoot "externals"
  $fileExternalSource = Join-Path $parentFixture.workingCopyRoot "external-source.txt"
  New-Item -ItemType Directory -Force -Path $externalParent | Out-Null
  Set-Content -LiteralPath $fileExternalSource -Value "file external source`n" -NoNewline -Encoding utf8
  Invoke-CheckedTool -Path $SvnExe -Arguments @(
    "add",
    $externalParent,
    $fileExternalSource,
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $parentFixture.svnCliConfigRoot
  ) -Description "svn add lazy external fixture parent paths" | Out-Null
  Invoke-CheckedTool -Path $SvnExe -Arguments @(
    "commit",
    $externalParent,
    $fileExternalSource,
    "-m",
    "seed lazy external fixture parent paths",
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $parentFixture.svnCliConfigRoot
  ) -Description "svn commit lazy external fixture parent paths" | Out-Null

  $externalsDefinition = "$($directoryExternalFixture.repoUrl)/trunk library`n^/trunk/external-source.txt pinned.txt"
  Invoke-CheckedTool -Path $SvnExe -Arguments @(
    "propset",
    "svn:externals",
    $externalsDefinition,
    $externalParent,
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $parentFixture.svnCliConfigRoot
  ) -Description "svn propset lazy external definitions" | Out-Null
  Invoke-CheckedTool -Path $SvnExe -Arguments @(
    "commit",
    $externalParent,
    "-m",
    "add lazy external definitions",
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $parentFixture.svnCliConfigRoot
  ) -Description "svn commit lazy external definitions" | Out-Null
  Invoke-CheckedTool -Path $SvnExe -Arguments @(
    "update",
    $parentFixture.workingCopyRoot,
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $parentFixture.svnCliConfigRoot
  ) -Description "svn update lazy external fixture" | Out-Null

  $directoryExternalTrackedFile = Join-Path $externalParent "library\src\tracked.txt"
  $fileExternalWorkingFile = Join-Path $externalParent "pinned.txt"
  if (-not (Test-Path -LiteralPath $directoryExternalTrackedFile -PathType Leaf)) {
    throw "Lazy external fixture did not materialize the directory external tracked file."
  }
  if (-not (Test-Path -LiteralPath $fileExternalWorkingFile -PathType Leaf)) {
    throw "Lazy external fixture did not materialize the file external boundary."
  }
  Set-Content -LiteralPath $directoryExternalTrackedFile -Value "modified directory external by M7j3`n" -NoNewline -Encoding utf8
  foreach ($relativePath in $directoryExternalFixture.modifiedLoadPaths) {
    $externalLoadPath = Join-Path (Join-Path $externalParent "library") $relativePath.Replace("/", "\")
    if (-not (Test-Path -LiteralPath $externalLoadPath -PathType Leaf)) {
      throw "Lazy external fixture did not materialize the directory external load file '$relativePath'."
    }
    Set-Content -LiteralPath $externalLoadPath -Value "modified directory external load item $relativePath by M7j3`n" -NoNewline -Encoding utf8
  }
  Set-Content -LiteralPath $fileExternalWorkingFile -Value "modified file external by M7j3`n" -NoNewline -Encoding utf8

  [pscustomobject]@{
    parent = $parentFixture
    directoryExternal = $directoryExternalFixture
    workingCopyRoot = $parentFixture.workingCopyRoot
    directoryExternalRoot = Join-Path $externalParent "library"
    fileExternalBoundary = Join-Path $externalParent "pinned.txt"
    parentModifiedLoadItemCount = $ParentModifiedLoadItemCount
    parentModifiedLoadPaths = $parentFixture.modifiedLoadPaths
    externalModifiedLoadItemCount = $ExternalModifiedLoadItemCount
    externalModifiedLoadPaths = $directoryExternalFixture.modifiedLoadPaths
    svnTreeBeforeSha256 = Get-DirectoryTreeSha256 $parentFixture.svnRoot
  }
}

function New-SourceControlUiResolveFixture(
  [string]$Root,
  [string]$SvnExe,
  [string]$SvnAdminExe
) {
  $repoPath = Join-Path $Root "repo"
  $importRoot = Join-Path $Root "import"
  $wcRoot = Join-Path $Root "workspace\wc"
  $peerWcRoot = Join-Path $Root "peer\wc"
  $svnCliConfigRoot = Join-Path $Root "svn-cli-config"
  New-Item -ItemType Directory -Force -Path (Join-Path $importRoot "trunk\src"), $svnCliConfigRoot | Out-Null
  Set-Content -LiteralPath (Join-Path $importRoot "trunk\src\tracked.txt") -Value "initial`n" -NoNewline -Encoding utf8

  Invoke-CheckedTool -Path $SvnAdminExe -Arguments @("create", $repoPath) -Description "svnadmin create resolve fixture repository" | Out-Null
  $repoUrl = "file:///" + $repoPath.Replace("\", "/")
  Invoke-CheckedTool -Path $SvnExe -Arguments @(
    "import",
    $importRoot,
    $repoUrl,
    "-m",
    "seed M7j3 resolve fixture",
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $svnCliConfigRoot
  ) -Description "svn import resolve fixture content" | Out-Null
  Invoke-CheckedTool -Path $SvnExe -Arguments @(
    "checkout",
    "$repoUrl/trunk",
    $wcRoot,
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $svnCliConfigRoot
  ) -Description "svn checkout resolve fixture working copy" | Out-Null
  Invoke-CheckedTool -Path $SvnExe -Arguments @(
    "checkout",
    "$repoUrl/trunk",
    $peerWcRoot,
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $svnCliConfigRoot
  ) -Description "svn checkout resolve fixture peer working copy" | Out-Null

  Set-Content -LiteralPath (Join-Path $peerWcRoot "src\tracked.txt") -Value "incoming by M7j3 resolve`n" -NoNewline -Encoding utf8
  Invoke-CheckedTool -Path $SvnExe -Arguments @(
    "commit",
    (Join-Path $peerWcRoot "src\tracked.txt"),
    "-m",
    "create M7j3 resolve incoming change",
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $svnCliConfigRoot
  ) -Description "svn commit resolve fixture incoming change" | Out-Null

  Set-Content -LiteralPath (Join-Path $wcRoot "src\tracked.txt") -Value "local by M7j3 resolve`n" -NoNewline -Encoding utf8
  Invoke-CheckedTool -Path $SvnExe -Arguments @(
    "update",
    (Join-Path $wcRoot "src\tracked.txt"),
    "--accept",
    "postpone",
    "--non-interactive",
    "--no-auth-cache",
    "--config-dir",
    $svnCliConfigRoot
  ) -Description "svn update resolve fixture to postponed conflict" | Out-Null

  $mergedContent = "merged by M7j3 resolve`n"
  Set-Content -LiteralPath (Join-Path $wcRoot "src\tracked.txt") -Value $mergedContent -NoNewline -Encoding utf8
  $svnRoot = Join-Path $wcRoot ".svn"
  [pscustomobject]@{
    repoPath = $repoPath
    repoUrl = $repoUrl
    importRoot = $importRoot
    workingCopyRoot = $wcRoot
    peerWorkingCopyRoot = $peerWcRoot
    svnCliConfigRoot = $svnCliConfigRoot
    svnRoot = $svnRoot
    conflictPath = "src/tracked.txt"
    mergedContent = $mergedContent
    svnTreeBeforeSha256 = Get-DirectoryTreeSha256 $svnRoot
  }
}

function Write-HarnessPackage(
  [string]$HarnessRoot,
  [string]$ResultPath,
  [string]$ReadyPath,
  [string]$DonePath,
  [string]$NoRepositoryWelcomeRendererReadyPath,
  [string]$NoRepositoryWelcomeRendererDonePath,
  [string]$PartialFreshnessRendererReadyPath,
  [string]$PartialFreshnessRendererDonePath,
  [string]$StaleFreshnessRendererReadyPath,
  [string]$StaleFreshnessRendererDonePath,
  [string]$FullReconcileCancellationReadyPath,
  [string]$FullReconcileCancellationDonePath,
  [string]$MultiRepositoryRefreshPromptReadyPath,
  [string]$DeletePromptReadyPath,
  [string]$DeleteLoadPromptReadyPath,
  [string]$RemovePromptReadyPath,
  [string]$RemoveCancellationPromptReadyPath,
  [string]$RemoveCancellationPromptDonePath,
  [string]$RemoveKeepLocalPromptReadyPath,
  [string]$MovePromptReadyPath,
  [string]$MoveCancellationPromptReadyPath,
  [string]$CheckoutCancellationPromptReadyPath,
  [string]$CheckoutCancellationPromptDonePath,
  [string]$CheckoutExistingTargetFailureUrlPromptReadyPath,
  [string]$CheckoutExistingTargetFailureUrlPromptDonePath,
  [string]$CheckoutExistingTargetFailureTargetPromptReadyPath,
  [string]$CheckoutExistingTargetFailureTargetPromptDonePath,
  [string]$CheckoutExistingTargetFailureRevisionPromptReadyPath,
  [string]$CheckoutExistingTargetFailureRevisionPromptDonePath,
  [string]$CheckoutExistingTargetFailureDepthPromptReadyPath,
  [string]$CheckoutExistingTargetFailureDepthPromptDonePath,
  [string]$CheckoutExistingTargetFailureExternalsPromptReadyPath,
  [string]$CheckoutExistingTargetFailureExternalsPromptDonePath,
  [string]$CheckoutExistingTargetFailureNotificationReadyPath,
  [string]$CheckoutExistingTargetFailureNotificationDonePath,
  [string]$CheckoutInvalidUrlFailureUrlPromptReadyPath,
  [string]$CheckoutInvalidUrlFailureUrlPromptDonePath,
  [string]$CheckoutInvalidUrlFailureTargetPromptReadyPath,
  [string]$CheckoutInvalidUrlFailureTargetPromptDonePath,
  [string]$CheckoutInvalidUrlFailureRevisionPromptReadyPath,
  [string]$CheckoutInvalidUrlFailureRevisionPromptDonePath,
  [string]$CheckoutInvalidUrlFailureDepthPromptReadyPath,
  [string]$CheckoutInvalidUrlFailureDepthPromptDonePath,
  [string]$CheckoutInvalidUrlFailureExternalsPromptReadyPath,
  [string]$CheckoutInvalidUrlFailureExternalsPromptDonePath,
  [string]$CheckoutInvalidUrlFailureNotificationReadyPath,
  [string]$CheckoutInvalidUrlFailureNotificationDonePath,
  [string]$CheckoutExistingDirectoryUrlPromptReadyPath,
  [string]$CheckoutExistingDirectoryUrlPromptDonePath,
  [string]$CheckoutExistingDirectoryTargetPromptReadyPath,
  [string]$CheckoutExistingDirectoryTargetPromptDonePath,
  [string]$CheckoutExistingDirectoryRevisionPromptReadyPath,
  [string]$CheckoutExistingDirectoryRevisionPromptDonePath,
  [string]$CheckoutExistingDirectoryDepthPromptReadyPath,
  [string]$CheckoutExistingDirectoryDepthPromptDonePath,
  [string]$CheckoutExistingDirectoryExternalsPromptReadyPath,
  [string]$CheckoutExistingDirectoryExternalsPromptDonePath,
  [string]$CheckoutExistingDirectoryObstructionUrlPromptReadyPath,
  [string]$CheckoutExistingDirectoryObstructionUrlPromptDonePath,
  [string]$CheckoutExistingDirectoryObstructionTargetPromptReadyPath,
  [string]$CheckoutExistingDirectoryObstructionTargetPromptDonePath,
  [string]$CheckoutExistingDirectoryObstructionRevisionPromptReadyPath,
  [string]$CheckoutExistingDirectoryObstructionRevisionPromptDonePath,
  [string]$CheckoutExistingDirectoryObstructionDepthPromptReadyPath,
  [string]$CheckoutExistingDirectoryObstructionDepthPromptDonePath,
  [string]$CheckoutExistingDirectoryObstructionExternalsPromptReadyPath,
  [string]$CheckoutExistingDirectoryObstructionExternalsPromptDonePath,
  [string]$CheckoutUrlPromptReadyPath,
  [string]$CheckoutUrlPromptDonePath,
  [string]$CheckoutTargetPromptReadyPath,
  [string]$CheckoutTargetPromptDonePath,
  [string]$CheckoutRevisionPromptReadyPath,
  [string]$CheckoutRevisionPromptDonePath,
  [string]$CheckoutDepthPromptReadyPath,
  [string]$CheckoutDepthPromptDonePath,
  [string]$CheckoutExternalsPromptReadyPath,
  [string]$CheckoutExternalsPromptDonePath,
  [string]$UpdateRevisionPromptReadyPath,
  [string]$UpdateRevisionPromptDonePath,
  [string]$UpdateCancellationRevisionPromptReadyPath,
  [string]$UpdateCancellationRevisionPromptDonePath,
  [string]$UpdateDepthPromptReadyPath,
  [string]$UpdateDepthPromptDonePath,
  [string]$UpdateStickyDepthPromptReadyPath,
  [string]$UpdateStickyDepthPromptDonePath,
  [string]$UpdateExternalsPromptReadyPath,
  [string]$UpdateExternalsPromptDonePath,
  [string]$BranchCreateSourcePromptReadyPath,
  [string]$BranchCreateSourcePromptDonePath,
  [string]$BranchCreateDestinationPromptReadyPath,
  [string]$BranchCreateDestinationPromptDonePath,
  [string]$BranchCreateRevisionPromptReadyPath,
  [string]$BranchCreateRevisionPromptDonePath,
  [string]$BranchCreateMessagePromptReadyPath,
  [string]$BranchCreateMessagePromptDonePath,
  [string]$BranchCreateParentsPromptReadyPath,
  [string]$BranchCreateParentsPromptDonePath,
  [string]$BranchCreateExternalsPromptReadyPath,
  [string]$BranchCreateExternalsPromptDonePath,
  [string]$BranchCreateSwitchPromptReadyPath,
  [string]$BranchCreateSwitchPromptDonePath,
  [string]$SwitchUrlPromptReadyPath,
  [string]$SwitchUrlPromptDonePath,
  [string]$SwitchRevisionPromptReadyPath,
  [string]$SwitchRevisionPromptDonePath,
  [string]$SwitchDepthPromptReadyPath,
  [string]$SwitchDepthPromptDonePath,
  [string]$SwitchStickyDepthPromptReadyPath,
  [string]$SwitchStickyDepthPromptDonePath,
  [string]$SwitchExternalsPromptReadyPath,
  [string]$SwitchExternalsPromptDonePath,
  [string]$SwitchAncestryPromptReadyPath,
  [string]$SwitchAncestryPromptDonePath,
  [string]$LockMessageCancellationPromptReadyPath,
  [string]$LockMessageCancellationPromptDonePath,
  [string]$LockMessagePromptReadyPath,
  [string]$LockMessagePromptDonePath,
  [string]$LockModePromptReadyPath,
  [string]$LockModePromptDonePath,
  [string]$LockHeldOracleReadyPath,
  [string]$LockHeldOracleDonePath,
  [string]$UnlockModeCancellationPromptReadyPath,
  [string]$UnlockModeCancellationPromptDonePath,
  [string]$UnlockModePromptReadyPath,
  [string]$UnlockModePromptDonePath,
  [string]$ChangelistSetPromptReadyPath,
  [string]$ChangelistRevertPromptReadyPath,
  [string]$RevertPromptReadyPath,
  [string]$RevertCancellationPromptReadyPath,
  [string]$RevertCancellationPromptDonePath,
  [string]$ResolvePromptReadyPath,
  [string]$ResolveCancellationPromptReadyPath,
  [string]$CleanupPromptReadyPath,
  [string]$ExtensionsRoot,
  [string]$WorkingCopyRoot,
  [string]$MultiRepositoryRefreshWorkingCopyRoot,
  [string]$LazyExternalProviderWorkingCopyRoot,
  [string]$BoundaryLoadWorkingCopyRoot,
  [int]$BoundaryLoadParentModifiedItemCount,
  [int]$BoundaryLoadBoundaryModifiedItemCount,
  [string]$RefreshLoadWorkingCopyRoot,
  [int]$RefreshLoadItemCount,
  [string]$LoadWorkingCopyRoot,
  [int]$LoadItemCount,
  [string]$CommitAllWorkingCopyRoot,
  [string]$CommitSelectedWorkingCopyRoot,
  [string]$CommitSelectedMultiSelectionWorkingCopyRoot,
  [string]$CheckoutRepositoryUrl,
  [string]$CheckoutCancellationTargetWorkingCopyRoot,
  [string]$CheckoutExistingTargetFailureTargetPath,
  [string]$CheckoutInvalidUrlFailureRepositoryUrl,
  [string]$CheckoutInvalidUrlFailureTargetWorkingCopyRoot,
  [string]$CheckoutExistingDirectoryTargetWorkingCopyRoot,
  [string]$CheckoutExistingDirectoryObstructionTargetWorkingCopyRoot,
  [string]$CheckoutTargetWorkingCopyRoot,
  [string]$UpdateWorkingCopyRoot,
  [int]$UpdateRevision,
  [string]$UpdateTargetRelativePath,
  [string]$BranchCreateWorkingCopyRoot,
  [string]$BranchCreateSourceUrl,
  [string]$BranchCreateDestinationUrl,
  [string]$BranchCreateMessage,
  [string]$SwitchWorkingCopyRoot,
  [string]$SwitchTargetUrl,
  [string]$AddWorkingCopyRoot,
  [string]$AddToIgnoreWorkingCopyRoot,
  [string]$LockWorkingCopyRoot,
  [string]$ChangelistSetClearWorkingCopyRoot,
  [string]$CommitChangelistWorkingCopyRoot,
  [string]$RevertChangelistWorkingCopyRoot,
  [string]$MoveResourceWorkingCopyRoot,
  [string]$MoveCancellationWorkingCopyRoot,
  [string]$RemoveWorkingCopyRoot,
  [string]$RemoveCancellationWorkingCopyRoot,
  [string]$RevertWorkingCopyRoot,
  [string]$RevertCancellationWorkingCopyRoot,
  [string]$ResolveWorkingCopyRoot,
  [string]$ResolveCancellationWorkingCopyRoot,
  [string]$DeleteWorkingCopyRoot,
  [string]$MoveWorkingCopyRoot,
  [string]$MoveDestinationRoot
) {
  $distRoot = Join-Path $HarnessRoot "dist"
  New-Item -ItemType Directory -Force -Path $distRoot | Out-Null
  @'
{
  "name": "subversionr-installed-source-control-ui-e2e-harness",
  "displayName": "SubversionR Installed Source Control UI E2E Harness",
  "version": "0.0.0",
  "publisher": "hitsuki-ban-test",
  "private": true,
  "engines": {
    "vscode": "^1.101.0"
  },
  "main": "./dist/extension.js",
  "activationEvents": []
}
'@ | Set-Content -LiteralPath (Join-Path $HarnessRoot "package.json") -NoNewline

  @'
exports.activate = function () {};
exports.deactivate = function () {};
'@ | Set-Content -LiteralPath (Join-Path $distRoot "extension.js") -NoNewline

  $runner = @'
const fs = require("node:fs");
const crypto = require("node:crypto");
const path = require("node:path");
const vscode = require("vscode");

const NOTIFICATION_CLEAR_COMMAND = "notifications.clearAll";
const NOTIFICATION_SHOW_LIST_COMMAND = "notifications.showList";

function withTimeout(promise, label, timeoutMs) {
  return Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error(`${label} timed out.`)), timeoutMs))
  ]);
}

async function clearWorkbenchNotificationsBeforePrompt(label) {
  const commands = await vscode.commands.getCommands(true);
  if (!commands.includes(NOTIFICATION_CLEAR_COMMAND)) {
    throw new Error(`VS Code command ${NOTIFICATION_CLEAR_COMMAND} was not registered before ${label}.`);
  }
  await withTimeout(
    vscode.commands.executeCommand(NOTIFICATION_CLEAR_COMMAND),
    `${NOTIFICATION_CLEAR_COMMAND}/${label}`,
    5000
  );
  await new Promise(resolve => setTimeout(resolve, 250));
  return {
    command: NOTIFICATION_CLEAR_COMMAND,
    label,
    cleared: true
  };
}

async function showWorkbenchNotificationsForPrompt(label) {
  const commands = await vscode.commands.getCommands(true);
  if (!commands.includes(NOTIFICATION_SHOW_LIST_COMMAND)) {
    throw new Error(`VS Code command ${NOTIFICATION_SHOW_LIST_COMMAND} was not registered before ${label}.`);
  }
  await withTimeout(
    vscode.commands.executeCommand(NOTIFICATION_SHOW_LIST_COMMAND),
    `${NOTIFICATION_SHOW_LIST_COMMAND}/${label}`,
    5000
  );
  await new Promise(resolve => setTimeout(resolve, 250));
  return {
    command: NOTIFICATION_SHOW_LIST_COMMAND,
    label,
    shown: true
  };
}

function isTransientSourceControlSurfaceMismatch(error) {
  const message = error && typeof error.message === "string" ? error.message : String(error);
  return message.includes("SUBVERSIONR_INSTALLED_SOURCE_CONTROL_SURFACE_MISMATCH");
}

function serializeError(error) {
  if (!error || typeof error !== "object") {
    return {
      message: String(error)
    };
  }
  return {
    message: typeof error.message === "string" ? error.message : String(error),
    stack: typeof error.stack === "string" ? error.stack : undefined,
    ...(typeof error.code === "string" ? { code: error.code } : {}),
    ...(typeof error.category === "string" ? { category: error.category } : {}),
    ...(typeof error.messageKey === "string" ? { messageKey: error.messageKey } : {}),
    ...(error.safeArgs && typeof error.safeArgs === "object" ? { safeArgs: error.safeArgs } : {})
  };
}

function sha256File(filePath) {
  return crypto.createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
}

function directoryEntries(directoryPath) {
  return fs.readdirSync(directoryPath, { withFileTypes: true })
    .map(entry => ({
      name: entry.name,
      kind: entry.isDirectory() ? "directory" : entry.isFile() ? "file" : entry.isSymbolicLink() ? "symlink" : "other"
    }))
    .sort((left, right) => left.name.localeCompare(right.name) || left.kind.localeCompare(right.kind));
}

function directoryEntriesEqual(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

async function collectFreshnessReportWithSurfaceRetry(request, label, timeoutMs = 30000) {
  const started = Date.now();
  let lastMismatch;
  while (Date.now() - started < timeoutMs) {
    const remainingMs = timeoutMs - (Date.now() - started);
    try {
      return await withTimeout(
        vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport", request),
        label,
        Math.max(1, remainingMs)
      );
    } catch (error) {
      if (!isTransientSourceControlSurfaceMismatch(error)) {
        throw error;
      }
      lastMismatch = error;
      await new Promise(resolve => setTimeout(resolve, Math.min(250, Math.max(1, remainingMs))));
    }
  }
  throw lastMismatch || new Error(`${label} timed out waiting for SourceControl surface freshness.`);
}

async function collectFreshnessReportUntilUnversionedCount(request, label, expectedCount, timeoutMs = 30000) {
  const started = Date.now();
  let lastReport;
  let lastTransientError;
  while (Date.now() - started < timeoutMs) {
    const remainingMs = timeoutMs - (Date.now() - started);
    try {
      const report = await collectFreshnessReportWithSurfaceRetry(
        request,
        label,
        Math.min(5000, Math.max(1, remainingMs))
      );
      lastReport = report;
      if (unversionedResources(report).length === expectedCount) {
        return report;
      }
    } catch (error) {
      if (!isTransientSourceControlSurfaceMismatch(error)) {
        throw error;
      }
      lastTransientError = error;
    }
    await new Promise(resolve => setTimeout(resolve, Math.min(250, Math.max(1, remainingMs))));
  }
  if (lastReport) {
    throw new Error(`${label} timed out waiting for ${expectedCount} unversioned resources; last projection had ${unversionedResources(lastReport).length}: ${sourceControlResourceSummary(lastReport)}`);
  }
  throw lastTransientError || new Error(`${label} timed out waiting for ${expectedCount} unversioned resources.`);
}

function waitForFile(filePath, timeoutMs) {
  const started = Date.now();
  return new Promise((resolve, reject) => {
    const interval = setInterval(() => {
      if (fs.existsSync(filePath)) {
        clearInterval(interval);
        resolve();
        return;
      }
      if (Date.now() - started > timeoutMs) {
        clearInterval(interval);
        reject(new Error(`Timed out waiting for sentinel: ${filePath}`));
      }
    }, 250);
  });
}

function findResource(report, groupId, resourcePath, contextValue) {
  const normalized = resourcePath.replace(/\\/g, "/");
  const group = report.sourceControl.groups.find(candidate => candidate.id === groupId);
  if (!group) {
    return undefined;
  }
  return group.resources.find(resource =>
    resource.path.replace(/\\/g, "/") === normalized &&
    resource.contextValue === contextValue
  );
}

function findGroup(report, groupId) {
  const groups = report && report.sourceControl && Array.isArray(report.sourceControl.groups)
    ? report.sourceControl.groups
    : [];
  return groups.find(candidate => candidate.id === groupId);
}

function sourceControlResourceSummary(report) {
  if (!report || !report.sourceControl || !Array.isArray(report.sourceControl.groups)) {
    return "<missing SourceControl groups>";
  }
  return report.sourceControl.groups
    .flatMap(group => (Array.isArray(group.resources) ? group.resources : [])
      .map(resource => `${group.id}:${resource.path}:${resource.contextValue}:${resource.kind}:g${resource.generation}`))
    .join(" | ");
}

function stableSourceControlGroups(report) {
  if (!report || !report.sourceControl || !Array.isArray(report.sourceControl.groups)) {
    return [];
  }
  return report.sourceControl.groups
    .filter(group => group.count !== 0 || (Array.isArray(group.resources) && group.resources.length !== 0))
    .map(group => ({
      id: group.id,
      contextValue: group.contextValue,
      hideWhenEmpty: group.hideWhenEmpty === true,
      count: group.count,
      resources: Array.isArray(group.resources)
        ? group.resources
          .map(resource => ({
            path: typeof resource.path === "string" ? resource.path.replace(/\\/g, "/") : resource.path,
            contextValue: resource.contextValue,
            kind: resource.kind
          }))
          .sort((left, right) => `${left.path}\u0000${left.contextValue}\u0000${left.kind}`.localeCompare(`${right.path}\u0000${right.contextValue}\u0000${right.kind}`))
        : []
    }))
    .sort((left, right) => `${left.id}\u0000${left.contextValue}`.localeCompare(`${right.id}\u0000${right.contextValue}`));
}

function sourceControlProjectionMatches(actualReport, expectedReport) {
  if (!actualReport || !expectedReport || !actualReport.sourceControl || !expectedReport.sourceControl) {
    return false;
  }
  return actualReport.sourceControl.count === expectedReport.sourceControl.count &&
    JSON.stringify(stableSourceControlGroups(actualReport)) === JSON.stringify(stableSourceControlGroups(expectedReport));
}

function findAnyResource(report, resourcePath) {
  const normalized = resourcePath.replace(/\\/g, "/");
  const groups = report && report.sourceControl && Array.isArray(report.sourceControl.groups)
    ? report.sourceControl.groups
    : [];
  for (const group of groups) {
    const match = group.resources.find(resource => resource.path.replace(/\\/g, "/") === normalized);
    if (match) {
      return match;
    }
  }
  return undefined;
}

function findStatusCommand(report, scenario, repositoryId) {
  const expectedTitle = scenario === "partial" ? "SVN status partial" : "SVN status stale";
  const commands = (report && report.sourceControl && report.sourceControl.statusBarCommands) || [];
  return commands.find(command =>
    command.command === "subversionr.fullReconcile" &&
    command.title === expectedTitle &&
    Array.isArray(command.arguments) &&
    command.arguments.length === 1 &&
    command.arguments[0] === repositoryId
  );
}

function validateFreshnessReport(report, scenario, openReport, options = {}) {
  const expectUnversionedScratch = options.expectUnversionedScratch !== false;
  const expectedTrackedContextValue = options.expectedTrackedContextValue || "subversionr.changedFile.baseDiffable";
  if (!report || report.kind !== "subversionr.installedSourceControlUiE2eFreshnessReport") {
    throw new Error(`Unexpected installed Source Control UI E2E ${scenario} freshness report kind: ${report && report.kind}`);
  }
  if (report.scenario !== scenario) {
    throw new Error(`Installed Source Control UI E2E freshness report scenario mismatch: expected ${scenario}, got ${report.scenario}.`);
  }
  if (
    report.repository.repositoryId !== openReport.repository.repositoryId ||
    report.repository.epoch !== openReport.repository.epoch
  ) {
    throw new Error(`Installed Source Control UI E2E ${scenario} freshness report repository identity mismatch.`);
  }
  if (
    !report.freshnessWorkflow ||
    report.freshnessWorkflow.repositoryOpen !== true ||
    report.freshnessWorkflow.currentEpochMatched !== true ||
    report.freshnessWorkflow.sourceControlSurface !== true
  ) {
    throw new Error(`Installed Source Control UI E2E ${scenario} freshness report must prove the live SourceControl surface.`);
  }
  if (
    !report.sourceControl ||
    !report.sourceControl.freshness ||
    report.sourceControl.freshness.repositoryCompleteness !== scenario
  ) {
    throw new Error(`Installed Source Control UI E2E ${scenario} freshness report did not expose ${scenario} repository completeness.`);
  }
  if (!findStatusCommand(report, scenario, openReport.repository.repositoryId)) {
    throw new Error(`Installed Source Control UI E2E ${scenario} freshness report did not expose the full reconcile status bar command.`);
  }
  if (!findResource(report, "changes", "src/tracked.txt", expectedTrackedContextValue)) {
    throw new Error(`Installed Source Control UI E2E ${scenario} freshness report did not preserve the expected tracked resource projection.`);
  }
  const scratch = findResource(report, "unversioned", "scratch.txt", "subversionr.unversioned");
  if (expectUnversionedScratch && !scratch) {
    throw new Error(`Installed Source Control UI E2E ${scenario} freshness report did not preserve unversioned resources.`);
  }
  if (!expectUnversionedScratch && scratch) {
    throw new Error(`Installed Source Control UI E2E ${scenario} freshness report still exposed deleted unversioned resources.`);
  }
}

function validateLastCompletedRefreshCoverageSet(report, openReport, expectedTargets) {
  const coverageReport = report && report.lastCompletedRefresh;
  if (!coverageReport) {
    throw new Error("Installed Source Control UI E2E freshness report did not record completed refresh coverage.");
  }
  if (
    coverageReport.repositoryId !== openReport.repository.repositoryId ||
    coverageReport.epoch !== openReport.repository.epoch
  ) {
    throw new Error("Installed Source Control UI E2E completed refresh coverage repository identity mismatch.");
  }
  if (!Array.isArray(expectedTargets) || expectedTargets.length === 0) {
    throw new Error("Installed Source Control UI E2E completed refresh coverage expected targets were not provided.");
  }
  if (!Array.isArray(coverageReport.targets) || coverageReport.targets.length !== expectedTargets.length) {
    throw new Error(`Installed Source Control UI E2E completed refresh coverage must record ${expectedTargets.length} requested target(s).`);
  }
  if (!Array.isArray(coverageReport.coverage) || coverageReport.coverage.length !== expectedTargets.length) {
    throw new Error(`Installed Source Control UI E2E completed refresh coverage must record ${expectedTargets.length} returned coverage scope(s).`);
  }
  for (let index = 0; index < expectedTargets.length; index += 1) {
    const expected = expectedTargets[index];
    const target = coverageReport.targets[index];
    const coverage = coverageReport.coverage[index];
    if (target.path !== expected.path || target.depth !== expected.depth || target.reason !== expected.reason) {
      throw new Error(`Installed Source Control UI E2E completed refresh target mismatch for ${expected.path}.`);
    }
    if (
      coverage.path !== expected.path ||
      coverage.depth !== expected.depth ||
      coverage.reason !== expected.reason ||
      coverage.generation !== coverageReport.generation
    ) {
      throw new Error(`Installed Source Control UI E2E returned coverage mismatch for ${expected.path}.`);
    }
  }
  return coverageReport;
}

function validateLastCompletedRefreshCoverage(report, openReport, expected) {
  return validateLastCompletedRefreshCoverageSet(report, openReport, [expected]);
}

function freshnessRendererCaptureExpectations(report, scenario) {
  const statusCommand = findStatusCommand(report, scenario, report.repository.repositoryId);
  if (!statusCommand) {
    throw new Error(`Installed Source Control UI E2E ${scenario} renderer capture cannot find the freshness status command.`);
  }
  const requiredDomTokens = [
    statusCommand.title,
    "Changes",
    "src",
    "tracked.txt"
  ];
  return {
    viewCommand: "workbench.view.scm",
    requiredDomTokens,
    requiredAccessibilityTokens: ["SubversionR", ...requiredDomTokens],
    requiredScreenshot: true
  };
}

function createNoRepositoryWelcomeRendererCaptureExpectations() {
  const requiredTokens = [
    "No SVN working copy was found in the workspace",
    "Scan for SVN Working Copies",
    "Checkout Repository URL"
  ];
  return {
    viewCommand: "workbench.view.scm",
    requiredDomTokens: requiredTokens,
    requiredAccessibilityTokens: requiredTokens,
    requiredScreenshot: true
  };
}

async function captureFreshnessRendererScenario(report, scenario, readyPath, donePath) {
  const rendererCaptureExpectations = freshnessRendererCaptureExpectations(report, scenario);
  await withTimeout(
    vscode.commands.executeCommand(rendererCaptureExpectations.viewCommand),
    `${rendererCaptureExpectations.viewCommand}/${scenario}`,
    30000
  );
  await new Promise(resolve => setTimeout(resolve, 1500));
  fs.writeFileSync(readyPath, JSON.stringify({
    ok: true,
    phase: `${scenario}FreshnessRendererReady`,
    scenario,
    repository: {
      repositoryId: report.repository.repositoryId,
      epoch: report.repository.epoch,
      workingCopyRoot: report.repository.identity.workingCopyRoot
    },
    rendererCaptureExpectations
  }, null, 2));
  await waitForFile(donePath, 120000);
  return rendererCaptureExpectations;
}

function fullReconcileCancellationRendererCaptureExpectations() {
  const requiredTokens = [
    "SVN-R",
    "Reconciling SVN working copy status",
    "Cancel"
  ];
  return {
    requiredDomTokens: requiredTokens,
    requiredAccessibilityTokens: requiredTokens,
    requiredScreenshot: true,
    clickButtonText: "Cancel"
  };
}

async function runFullReconcileCancellationWorkflow(openReport, readyPath, donePath) {
  const armReport = await withTimeout(
    vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eArmFullReconcileCancellation", {
      repositoryId: openReport.repository.repositoryId,
      epoch: openReport.repository.epoch,
      timeoutMs: 60000
    }),
    "subversionr.diagnostics.installedSourceControlUiE2eArmFullReconcileCancellation",
    30000
  );
  if (!armReport || armReport.armed !== true || armReport.repositoryId !== openReport.repository.repositoryId || armReport.epoch !== openReport.repository.epoch) {
    throw new Error("Installed Source Control UI E2E full reconcile cancellation arm report did not match the open repository.");
  }
  const rendererCaptureExpectations = fullReconcileCancellationRendererCaptureExpectations();
  const notificationCleanup = await clearWorkbenchNotificationsBeforePrompt("fullReconcileCancellation");
  const commandResult = {
    resolved: false,
    errorMessage: undefined
  };
  const commandPromise = withTimeout(
    vscode.commands.executeCommand("subversionr.fullReconcile", openReport.repository.repositoryId)
      .then(() => {
        commandResult.resolved = true;
      }, (error) => {
        commandResult.errorMessage = error instanceof Error ? error.message : String(error);
      }),
    "subversionr.fullReconcile/cancel",
    120000
  );
  const notificationList = await showWorkbenchNotificationsForPrompt("fullReconcileCancellation");
  await new Promise(resolve => setTimeout(resolve, 1500));
  fs.writeFileSync(readyPath, JSON.stringify({
    ok: true,
    phase: "fullReconcileCancellationProgressReady",
    command: "subversionr.fullReconcile",
    armReport,
    notificationCleanup,
    notificationList,
    rendererCaptureExpectations
  }, null, 2));
  await waitForFile(donePath, 120000);
  await commandPromise;
  const cancellationReport = await withTimeout(
    vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eFullReconcileCancellationReport", {
      holdId: armReport.holdId
    }),
    "subversionr.diagnostics.installedSourceControlUiE2eFullReconcileCancellationReport",
    30000
  );
  if (!cancellationReport || cancellationReport.cancellationObserved !== true || cancellationReport.signalAborted !== true) {
    throw new Error("Installed Source Control UI E2E full reconcile cancellation report did not prove user cancellation.");
  }
  await withTimeout(
    vscode.commands.executeCommand("subversionr.fullReconcile", openReport.repository.repositoryId),
    "subversionr.fullReconcile/recovery",
    60000
  );
  const recoveryFreshnessReport = await withTimeout(
    vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport", {
      repositoryId: openReport.repository.repositoryId,
      epoch: openReport.repository.epoch,
      scenario: "partial"
    }),
    "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/full-reconcile-recovery",
    30000
  );
  validateFreshnessReport(recoveryFreshnessReport, "partial", openReport);

  return {
    kind: "subversionr.installedSourceControlUiE2eFullReconcileCancellationWorkflow",
    generatedAt: new Date().toISOString(),
    command: {
      command: "subversionr.fullReconcile",
      arguments: [openReport.repository.repositoryId]
    },
    repository: {
      repositoryId: openReport.repository.repositoryId,
      epoch: openReport.repository.epoch,
      workingCopyRoot: openReport.repository.identity.workingCopyRoot
    },
    armReport,
    cancellationReport,
    commandResult,
    notificationCleanup,
    notificationList,
    prompt: {
      clickButtonText: "Cancel",
      rendererCaptureExpectations
    },
    recoveryFreshnessReport,
    assertions: {
      commandResolvedAfterCancellation: commandResult.resolved === true,
      cancellationObserved: cancellationReport.cancellationObserved === true,
      signalProvided: cancellationReport.refreshStatusSignalProvided === true,
      signalAborted: cancellationReport.signalAborted === true,
      cancellationReason: "userCancelled",
      recoveryFullReconcileExecuted: true,
      sourceControlSurfaceAfterRecovery: recoveryFreshnessReport.freshnessWorkflow.sourceControlSurface === true
    }
  };
}

async function runRefreshWorkflow(openReport) {
  await withTimeout(
    vscode.commands.executeCommand("subversionr.refreshRepository"),
    "subversionr.refreshRepository",
    60000
  );

  const postRefreshFreshnessReport = await withTimeout(
    vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport", {
      repositoryId: openReport.repository.repositoryId,
      epoch: openReport.repository.epoch,
      scenario: "partial"
    }),
    "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/refresh",
    30000
  );
  validateFreshnessReport(postRefreshFreshnessReport, "partial", openReport);

  return {
    kind: "subversionr.installedSourceControlUiE2eRefreshWorkflow",
    generatedAt: new Date().toISOString(),
    command: {
      command: "subversionr.refreshRepository"
    },
    repository: {
      repositoryId: openReport.repository.repositoryId,
      epoch: openReport.repository.epoch,
      workingCopyRoot: openReport.repository.identity.workingCopyRoot
    },
    postRefreshFreshnessReport,
    assertions: {
      commandExecuted: true,
      singleOpenRepositoryPath: true,
      repositoryOpenBefore: openReport.surfaceWorkflow.repositoryOpen === true,
      sourceControlSurfaceAfterRefresh: postRefreshFreshnessReport.freshnessWorkflow.sourceControlSurface === true
    }
  };
}

async function runMultiRepositoryRefreshWorkflow(openReport, multiRepositoryRefreshWorkingCopyRoot, promptReadyPath) {
  let secondOpenReport;
  let secondCloseReport;
  try {
    secondOpenReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: multiRepositoryRefreshWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/multiRepositoryRefresh",
      60000
    );
    if (!secondOpenReport || secondOpenReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected multi-repository Refresh open report kind: ${secondOpenReport && secondOpenReport.kind}`);
    }
    if (path.resolve(secondOpenReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(multiRepositoryRefreshWorkingCopyRoot).toLowerCase()) {
      throw new Error("Multi-repository Refresh open report workingCopyRoot did not match the fixture working copy.");
    }
    if (secondOpenReport.repository.repositoryId === openReport.repository.repositoryId) {
      throw new Error("Multi-repository Refresh fixture must open a distinct repository identity.");
    }

    const rendererCaptureExpectations = {
      requiredDomTokens: [
        "svn-fixture",
        "multi-repository-refresh-fixture"
      ],
      requiredAccessibilityTokens: [
        "svn-fixture",
        "multi-repository-refresh-fixture"
      ],
      requiredScreenshot: true,
      quickPickItemText: secondOpenReport.repository.identity.workingCopyRoot
    };
    const refreshPromise = withTimeout(
      vscode.commands.executeCommand("subversionr.refreshRepository"),
      "subversionr.refreshRepository/multiRepository",
      60000
    );
    await new Promise(resolve => setTimeout(resolve, 500));
    fs.writeFileSync(promptReadyPath, JSON.stringify({
      ok: true,
      phase: "multiRepositoryRefreshPromptReady",
      command: "subversionr.refreshRepository",
      firstRepository: {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        workingCopyRoot: openReport.repository.identity.workingCopyRoot
      },
      selectedRepository: {
        repositoryId: secondOpenReport.repository.repositoryId,
        epoch: secondOpenReport.repository.epoch,
        workingCopyRoot: secondOpenReport.repository.identity.workingCopyRoot
      },
      rendererCaptureExpectations
    }, null, 2));
    await refreshPromise;

    const postRefreshFreshnessReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport", {
        repositoryId: secondOpenReport.repository.repositoryId,
        epoch: secondOpenReport.repository.epoch,
        scenario: "partial"
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/multiRepositoryRefresh",
      30000
    );
    validateFreshnessReport(postRefreshFreshnessReport, "partial", secondOpenReport);

    const firstRepositoryFreshnessReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport", {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        scenario: "partial"
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/multiRepositoryRefreshFirstRepository",
      30000
    );
    validateFreshnessReport(firstRepositoryFreshnessReport, "partial", openReport);

    secondCloseReport = await closeOpenReport(secondOpenReport);
    if (!secondCloseReport || secondCloseReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || secondCloseReport.repositoryClosed !== true) {
      throw new Error("Multi-repository Refresh close report did not prove selected repository closure.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eMultiRepositoryRefreshWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.refreshRepository"
      },
      firstRepository: {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        workingCopyRoot: openReport.repository.identity.workingCopyRoot
      },
      selectedRepository: {
        repositoryId: secondOpenReport.repository.repositoryId,
        epoch: secondOpenReport.repository.epoch,
        workingCopyRoot: secondOpenReport.repository.identity.workingCopyRoot
      },
      selectedRepositoryOpenReport: secondOpenReport,
      selection: {
        selectedRepositoryId: secondOpenReport.repository.repositoryId,
        selectedWorkingCopyRoot: secondOpenReport.repository.identity.workingCopyRoot,
        quickPickItemText: secondOpenReport.repository.identity.workingCopyRoot
      },
      prompt: {
        rendererCaptureExpectations
      },
      postRefreshFreshnessReport,
      firstRepositoryFreshnessReport,
      selectedRepositoryCloseReport: secondCloseReport,
      assertions: {
        commandExecuted: true,
        quickPickSelectionRequired: true,
        selectedRepositoryDistinct: secondOpenReport.repository.repositoryId !== openReport.repository.repositoryId,
        selectedRepositoryRefreshed: postRefreshFreshnessReport.repository.repositoryId === secondOpenReport.repository.repositoryId,
        firstRepositoryStayedOpen: firstRepositoryFreshnessReport.freshnessWorkflow.repositoryOpen === true,
        sourceControlSurfaceAfterRefresh: postRefreshFreshnessReport.freshnessWorkflow.sourceControlSurface === true
      }
    };
  } catch (error) {
    if (secondOpenReport && !secondCloseReport) {
      try {
        secondCloseReport = await closeOpenReport(secondOpenReport);
      } catch {
        // Preserve the original workflow failure.
      }
    }
    throw error;
  }
}

async function runLazyExternalProviderWorkflow(lazyExternalProviderWorkingCopyRoot) {
  const report = await withTimeout(
    vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eLazyExternalProviderReport", {
      path: lazyExternalProviderWorkingCopyRoot
    }),
    "subversionr.diagnostics.installedSourceControlUiE2eLazyExternalProviderReport",
    60000
  );
  if (!report || report.kind !== "subversionr.installedSourceControlUiE2eLazyExternalProviderReport") {
    throw new Error(`Unexpected lazy external provider report kind: ${report && report.kind}`);
  }
  if (path.resolve(report.parentProvider.workingCopyRoot).toLowerCase() !== path.resolve(lazyExternalProviderWorkingCopyRoot).toLowerCase()) {
    throw new Error("Lazy external provider report workingCopyRoot did not match the fixture working copy.");
  }
  if (
    report.request.externalsMode !== "lazy" ||
    report.request.discoveryDepth !== 4 ||
    report.discovery.fileExternalBoundaries.length === 0 ||
    report.parentProvider.boundaryRoots.length === 0 ||
    report.externalProviders.length === 0 ||
    !report.externalProviders.some(provider =>
      provider.sourceControl.groups.some(group => group.resources.some(resource => resource.path === "src/tracked.txt"))
    ) ||
    report.assertions.directoryExternalDiscovered !== true ||
    report.assertions.fileExternalBoundariesDiscovered !== true ||
    report.assertions.parentBoundaryRootsIncludedDirectoryExternal !== true ||
    report.assertions.parentBoundaryRootsIncludedFileExternal !== true ||
    report.assertions.distinctExternalProviderOpened !== true ||
    report.assertions.parentSourceControlExcludedExternalBoundaries !== true ||
    report.assertions.providersClosed !== true
  ) {
    throw new Error("Lazy external provider report did not prove installed lazy discovery, boundary planning, provider split, and cleanup.");
  }
  return report;
}

function refreshLoadPaths(itemCount) {
  return Array.from({ length: itemCount }, (_value, index) =>
    `load/modified-${String(index + 1).padStart(3, "0")}.txt`
  );
}

function projectedChangedLoadResourceCount(report, paths) {
  return paths.filter(path => findResource(report, "changes", path, "subversionr.changedFile.baseDiffable")).length;
}

function projectedChangedLoadResourceCountInSourceControl(sourceControl, paths) {
  return projectedChangedLoadResourceCount({ sourceControl }, paths);
}

function externalBoundaryLoadPaths(paths) {
  return paths.map(path => `externals/library/${path}`);
}

async function runBoundaryLoadWorkflow(boundaryLoadWorkingCopyRoot, parentModifiedItemCount, boundaryModifiedItemCount) {
  const parentLoadPaths = refreshLoadPaths(parentModifiedItemCount);
  const boundaryLoadPaths = externalBoundaryLoadPaths(refreshLoadPaths(boundaryModifiedItemCount));
  const report = await runLazyExternalProviderWorkflow(boundaryLoadWorkingCopyRoot);
  const projectedParentModifiedItemCount = projectedChangedLoadResourceCountInSourceControl(
    report.parentProvider.sourceControl,
    parentLoadPaths
  );
  const projectedBoundaryModifiedItemCount = projectedChangedLoadResourceCountInSourceControl(
    report.parentProvider.sourceControl,
    boundaryLoadPaths
  );
  const projectedExternalModifiedItemCount = report.externalProviders.reduce(
    (total, provider) =>
      total + projectedChangedLoadResourceCountInSourceControl(provider.sourceControl, refreshLoadPaths(boundaryModifiedItemCount)),
    0
  );
  if (projectedParentModifiedItemCount !== parentModifiedItemCount) {
    throw new Error(`Boundary load report projected ${projectedParentModifiedItemCount} parent modified load resources; expected ${parentModifiedItemCount}.`);
  }
  if (projectedBoundaryModifiedItemCount !== 0) {
    throw new Error(`Boundary load report projected ${projectedBoundaryModifiedItemCount} boundary resources in the parent provider; expected 0.`);
  }
  if (projectedExternalModifiedItemCount !== boundaryModifiedItemCount) {
    throw new Error(`Boundary load report projected ${projectedExternalModifiedItemCount} external provider modified load resources; expected ${boundaryModifiedItemCount}.`);
  }

  return {
    kind: "subversionr.installedSourceControlUiE2eBoundaryLoadWorkflow",
    generatedAt: new Date().toISOString(),
    command: {
      command: "subversionr.diagnostics.installedSourceControlUiE2eLazyExternalProviderReport"
    },
    repository: {
      repositoryId: report.parentProvider.repositoryId,
      epoch: report.parentProvider.epoch,
      workingCopyRoot: report.parentProvider.workingCopyRoot,
      boundaryRoots: report.parentProvider.boundaryRoots
    },
    load: {
      requestedParentModifiedItemCount: parentModifiedItemCount,
      requestedBoundaryModifiedItemCount: boundaryModifiedItemCount,
      projectedParentModifiedItemCount,
      projectedBoundaryModifiedItemCount,
      projectedExternalModifiedItemCount,
      parentModifiedPaths: parentLoadPaths,
      boundaryModifiedPaths: boundaryLoadPaths
    },
    lazyExternalProviderReport: report,
    assertions: {
      boundaryRootsPresent: report.parentProvider.boundaryRoots.length > 0,
      allParentLoadResourcesProjected: projectedParentModifiedItemCount === parentModifiedItemCount,
      noBoundaryLoadResourcesProjected: projectedBoundaryModifiedItemCount === 0,
      allExternalLoadResourcesProjectedByExternalProvider: projectedExternalModifiedItemCount === boundaryModifiedItemCount,
      sourceControlSurfaceAvailable: report.parentProvider.sourceControl.groups.some(group => group.resources.length > 0)
    }
  };
}

async function runRefreshLoadWorkflow(refreshLoadWorkingCopyRoot, refreshLoadItemCount) {
  let refreshLoadOpenReport;
  let refreshLoadCloseReport;
  const loadPaths = refreshLoadPaths(refreshLoadItemCount);
  const restoredPath = loadPaths[0];
  const restoredPathIndex = 1;
  const restoredFsPath = path.join(refreshLoadWorkingCopyRoot, ...restoredPath.split("/"));
  try {
    refreshLoadOpenReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: refreshLoadWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/refreshLoad",
      60000
    );
    if (!refreshLoadOpenReport || refreshLoadOpenReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected Refresh load open report kind: ${refreshLoadOpenReport && refreshLoadOpenReport.kind}`);
    }
    if (path.resolve(refreshLoadOpenReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(refreshLoadWorkingCopyRoot).toLowerCase()) {
      throw new Error("Refresh load open report workingCopyRoot did not match the fixture working copy.");
    }
    const projectedModifiedItemCountBefore = projectedChangedLoadResourceCount(refreshLoadOpenReport, loadPaths);
    if (projectedModifiedItemCountBefore !== refreshLoadItemCount) {
      throw new Error(`Refresh load open report projected ${projectedModifiedItemCountBefore} modified load resources; expected ${refreshLoadItemCount}.`);
    }

    await withTimeout(
      vscode.commands.executeCommand("subversionr.refreshRepository"),
      "subversionr.refreshRepository/refreshLoad",
      60000
    );

    const postRefreshFreshnessReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport", {
        repositoryId: refreshLoadOpenReport.repository.repositoryId,
        epoch: refreshLoadOpenReport.repository.epoch,
        scenario: "partial"
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/refreshLoad",
      30000
    );
    validateFreshnessReport(postRefreshFreshnessReport, "partial", refreshLoadOpenReport);
    const projectedModifiedItemCountAfter = projectedChangedLoadResourceCount(postRefreshFreshnessReport, loadPaths);
    if (projectedModifiedItemCountAfter !== refreshLoadItemCount) {
      throw new Error(`Refresh load post-refresh report projected ${projectedModifiedItemCountAfter} modified load resources; expected ${refreshLoadItemCount}.`);
    }

    fs.writeFileSync(restoredFsPath, `initial load item ${restoredPathIndex}\n`, "utf8");
    await withTimeout(
      vscode.commands.executeCommand("subversionr.refreshResource", {
        contextValue: "subversionr.changedFile.baseDiffable",
        resourceUri: vscode.Uri.file(restoredFsPath)
      }),
      "subversionr.refreshResource/refreshLoadRestoredPath",
      60000
    );

    const postResourceRefreshFreshnessReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport", {
        repositoryId: refreshLoadOpenReport.repository.repositoryId,
        epoch: refreshLoadOpenReport.repository.epoch,
        scenario: "partial"
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/refreshLoadRestoredPath",
      30000
    );
    validateFreshnessReport(postResourceRefreshFreshnessReport, "partial", refreshLoadOpenReport);
    const resourceRefreshCoverage = validateLastCompletedRefreshCoverage(
      postResourceRefreshFreshnessReport,
      refreshLoadOpenReport,
      { path: restoredPath, depth: "empty", reason: "resourceRefresh" }
    );
    const projectedModifiedItemCountAfterResourceRefresh = projectedChangedLoadResourceCount(postResourceRefreshFreshnessReport, loadPaths);
    const projectedRestoredItemCountAfter = projectedChangedLoadResourceCount(postResourceRefreshFreshnessReport, [restoredPath]);
    if (projectedModifiedItemCountAfterResourceRefresh !== refreshLoadItemCount - 1) {
      throw new Error(`Refresh resource restored-path report projected ${projectedModifiedItemCountAfterResourceRefresh} modified load resources; expected ${refreshLoadItemCount - 1}.`);
    }
    if (projectedRestoredItemCountAfter !== 0) {
      throw new Error(`Refresh resource restored-path report still projected ${restoredPath}.`);
    }

    refreshLoadCloseReport = await closeOpenReport(refreshLoadOpenReport);
    if (!refreshLoadCloseReport || refreshLoadCloseReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || refreshLoadCloseReport.repositoryClosed !== true) {
      throw new Error("Refresh load close report did not prove repository closure.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eRefreshLoadWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.refreshRepository"
      },
      repository: {
        repositoryId: refreshLoadOpenReport.repository.repositoryId,
        epoch: refreshLoadOpenReport.repository.epoch,
        workingCopyRoot: refreshLoadOpenReport.repository.identity.workingCopyRoot
      },
      load: {
        requestedModifiedItemCount: refreshLoadItemCount,
        projectedModifiedItemCountBefore,
        projectedModifiedItemCountAfter,
        modifiedPaths: loadPaths
      },
      resourceRefresh: {
        command: {
          command: "subversionr.refreshResource"
        },
        restoredPath,
        projectedModifiedItemCountBefore: projectedModifiedItemCountAfter,
        projectedModifiedItemCountAfter: projectedModifiedItemCountAfterResourceRefresh,
        projectedRestoredItemCountAfter,
        coverage: resourceRefreshCoverage,
        postRefreshFreshnessReport: postResourceRefreshFreshnessReport
      },
      openReport: refreshLoadOpenReport,
      postRefreshFreshnessReport,
      closeReport: refreshLoadCloseReport,
      assertions: {
        commandExecuted: true,
        repositoryOpenBefore: refreshLoadOpenReport.surfaceWorkflow.repositoryOpen === true,
        allLoadResourcesProjectedBefore: projectedModifiedItemCountBefore === refreshLoadItemCount,
        allLoadResourcesProjectedAfter: projectedModifiedItemCountAfter === refreshLoadItemCount,
        sourceControlSurfaceAfterRefresh: postRefreshFreshnessReport.freshnessWorkflow.sourceControlSurface === true,
        restoredPathProjectedBefore: projectedChangedLoadResourceCount(refreshLoadOpenReport, [restoredPath]) === 1,
        sourceControlProjectionRemovedRestoredPath: projectedRestoredItemCountAfter === 0 &&
          projectedModifiedItemCountAfterResourceRefresh === refreshLoadItemCount - 1,
        restoredPathCoverageMatched: resourceRefreshCoverage.coverage[0].path === restoredPath &&
          resourceRefreshCoverage.coverage[0].depth === "empty" &&
          resourceRefreshCoverage.coverage[0].reason === "resourceRefresh",
        restoredPathCoverageGenerationMatched: resourceRefreshCoverage.coverage[0].generation === resourceRefreshCoverage.generation,
        sourceControlSurfaceAfterResourceRefresh: postResourceRefreshFreshnessReport.freshnessWorkflow.sourceControlSurface === true
      }
    };
  } catch (error) {
    if (refreshLoadOpenReport && !refreshLoadCloseReport) {
      try {
        await closeOpenReport(refreshLoadOpenReport);
      } catch {
      }
    }
    throw error;
  }
}

async function waitForDirtyGenerationReport(holdId, predicate, label, timeoutMs = 30000) {
  const started = Date.now();
  let lastReport;
  let lastError;
  while (Date.now() - started < timeoutMs) {
    try {
      lastReport = await withTimeout(
        vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eDirtyGenerationCancellationReport", { holdId }),
        label,
        Math.max(1, timeoutMs - (Date.now() - started))
      );
      if (predicate(lastReport)) {
        return lastReport;
      }
    } catch (error) {
      lastError = error;
    }
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  if (lastReport) {
    throw new Error(`${label} timed out with report ${JSON.stringify(lastReport)}.`);
  }
  throw lastError || new Error(`${label} timed out waiting for dirty-generation cancellation report.`);
}

function validateMultiTargetCompletedRefreshCoverage(report, openReport, expectedTargets) {
  const coverageReport = report && report.lastCompletedRefresh;
  if (!coverageReport) {
    throw new Error("Installed Source Control UI E2E dirty-generation completion did not record completed refresh coverage.");
  }
  if (
    coverageReport.repositoryId !== openReport.repository.repositoryId ||
    coverageReport.epoch !== openReport.repository.epoch
  ) {
    throw new Error("Installed Source Control UI E2E dirty-generation completed coverage repository identity mismatch.");
  }
  if (!Array.isArray(coverageReport.targets) || coverageReport.targets.length !== expectedTargets.length) {
    throw new Error(`Installed Source Control UI E2E dirty-generation completed coverage must record ${expectedTargets.length} requested targets.`);
  }
  if (!Array.isArray(coverageReport.coverage) || coverageReport.coverage.length !== expectedTargets.length) {
    throw new Error(`Installed Source Control UI E2E dirty-generation completed coverage must record ${expectedTargets.length} returned coverage scopes.`);
  }
  for (const expected of expectedTargets) {
    const target = coverageReport.targets.find(candidate =>
      candidate.path === expected.path &&
      candidate.depth === expected.depth &&
      candidate.reason === expected.reason
    );
    const coverage = coverageReport.coverage.find(candidate =>
      candidate.path === expected.path &&
      candidate.depth === expected.depth &&
      candidate.reason === expected.reason &&
      candidate.generation === coverageReport.generation
    );
    if (!target || !coverage) {
      throw new Error(`Installed Source Control UI E2E dirty-generation completed coverage missing ${expected.path}.`);
    }
  }
  return coverageReport;
}

async function runDirtyGenerationCancellationLoadWorkflow(refreshLoadWorkingCopyRoot, refreshLoadItemCount) {
  let refreshLoadOpenReport;
  let refreshLoadCloseReport;
  const loadPaths = refreshLoadPaths(refreshLoadItemCount);
  const firstPath = loadPaths[1];
  const secondPath = loadPaths[2];
  if (!firstPath || !secondPath) {
    throw new Error("Installed Source Control UI E2E dirty-generation cancellation requires at least three load paths.");
  }
  const firstFsPath = path.join(refreshLoadWorkingCopyRoot, ...firstPath.split("/"));
  const secondFsPath = path.join(refreshLoadWorkingCopyRoot, ...secondPath.split("/"));
  const firstTarget = { path: firstPath, depth: "empty", reason: "fileChanged" };
  const secondTarget = { path: secondPath, depth: "empty", reason: "fileChanged" };
  try {
    refreshLoadOpenReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: refreshLoadWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/dirtyGenerationCancellationLoad",
      60000
    );
    if (!refreshLoadOpenReport || refreshLoadOpenReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected dirty-generation cancellation load open report kind: ${refreshLoadOpenReport && refreshLoadOpenReport.kind}`);
    }
    if (path.resolve(refreshLoadOpenReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(refreshLoadWorkingCopyRoot).toLowerCase()) {
      throw new Error("Dirty-generation cancellation load open report workingCopyRoot did not match the fixture working copy.");
    }
    const projectedModifiedItemCountBefore = projectedChangedLoadResourceCount(refreshLoadOpenReport, loadPaths);
    if (projectedModifiedItemCountBefore !== refreshLoadItemCount) {
      throw new Error(`Dirty-generation cancellation load open report projected ${projectedModifiedItemCountBefore} modified load resources; expected ${refreshLoadItemCount}.`);
    }

    const armReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eArmDirtyGenerationCancellation", {
        repositoryId: refreshLoadOpenReport.repository.repositoryId,
        epoch: refreshLoadOpenReport.repository.epoch,
        timeoutMs: 60000,
        target: firstTarget
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eArmDirtyGenerationCancellation",
      30000
    );
    if (!armReport || armReport.armed !== true || armReport.target.path !== firstPath || armReport.target.reason !== "fileChanged") {
      throw new Error("Installed Source Control UI E2E dirty-generation cancellation arm report did not match the first load target.");
    }

    const firstDirtyEventReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eDirtyEvent", {
        repositoryId: refreshLoadOpenReport.repository.repositoryId,
        fsPath: firstFsPath,
        kind: "changed",
        timestamp: Date.now()
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eDirtyEvent/first",
      30000
    );
    if (!firstDirtyEventReport || firstDirtyEventReport.accepted !== true) {
      throw new Error("Installed Source Control UI E2E dirty-generation first load dirty event was not accepted.");
    }

    const commandResult = {
      resolved: false,
      errorMessage: undefined
    };
    const commandPromise = withTimeout(
      vscode.commands.executeCommand("subversionr.refreshRepository")
        .then(() => {
          commandResult.resolved = true;
        }, (error) => {
          commandResult.errorMessage = error instanceof Error ? error.message : String(error);
        }),
      "subversionr.refreshRepository/dirtyGenerationCancellation",
      120000
    );
    const observedReport = await waitForDirtyGenerationReport(
      armReport.holdId,
      report => report && report.observed === true && report.cancellationObserved === false,
      "subversionr.diagnostics.installedSourceControlUiE2eDirtyGenerationCancellationReport/observed",
      30000
    );

    const secondDirtyEventReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eDirtyEvent", {
        repositoryId: refreshLoadOpenReport.repository.repositoryId,
        fsPath: secondFsPath,
        kind: "changed",
        timestamp: Math.max(Date.now(), firstDirtyEventReport.event.timestamp + 1)
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eDirtyEvent/second",
      30000
    );
    if (!secondDirtyEventReport || secondDirtyEventReport.accepted !== true) {
      throw new Error("Installed Source Control UI E2E dirty-generation superseding load dirty event was not accepted.");
    }

    const postCancellationFreshnessReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport", {
        repositoryId: refreshLoadOpenReport.repository.repositoryId,
        epoch: refreshLoadOpenReport.repository.epoch,
        scenario: "stale"
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/dirty-generation-cancelled",
      30000
    );
    validateFreshnessReport(postCancellationFreshnessReport, "stale", refreshLoadOpenReport);

    const cancellationReport = await waitForDirtyGenerationReport(
      armReport.holdId,
      report => report && report.cancellationObserved === true && report.signalAborted === true,
      "subversionr.diagnostics.installedSourceControlUiE2eDirtyGenerationCancellationReport/cancelled",
      30000
    );
    await commandPromise;

    const postCancellationRefreshResult = {
      attempted: true,
      resolved: false,
      errorMessage: undefined
    };
    await withTimeout(
      vscode.commands.executeCommand("subversionr.refreshRepository")
        .then(() => {
          postCancellationRefreshResult.resolved = true;
        }, (error) => {
          postCancellationRefreshResult.errorMessage = error instanceof Error ? error.message : String(error);
        }),
      "subversionr.refreshRepository/dirtyGenerationCancellationPostCancellation",
      60000
    );
    const postCancellationCompletionFreshnessReport = await collectFreshnessReportWithSurfaceRetry(
      {
        repositoryId: refreshLoadOpenReport.repository.repositoryId,
        epoch: refreshLoadOpenReport.repository.epoch,
        scenario: "partial"
      },
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/dirty-generation-completion",
      30000
    );
    validateFreshnessReport(postCancellationCompletionFreshnessReport, "partial", refreshLoadOpenReport);
    const postCancellationCompletionCoverage = validateMultiTargetCompletedRefreshCoverage(
      postCancellationCompletionFreshnessReport,
      refreshLoadOpenReport,
      [firstTarget, secondTarget]
    );

    refreshLoadCloseReport = await closeOpenReport(refreshLoadOpenReport);
    if (!refreshLoadCloseReport || refreshLoadCloseReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || refreshLoadCloseReport.repositoryClosed !== true) {
      throw new Error("Dirty-generation cancellation load close report did not prove repository closure.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eDirtyGenerationCancellationLoadWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.refreshRepository"
      },
      repository: {
        repositoryId: refreshLoadOpenReport.repository.repositoryId,
        epoch: refreshLoadOpenReport.repository.epoch,
        workingCopyRoot: refreshLoadOpenReport.repository.identity.workingCopyRoot
      },
      load: {
        requestedModifiedItemCount: refreshLoadItemCount,
        projectedModifiedItemCountBefore,
        heldPath: firstPath,
        supersedingPath: secondPath,
        modifiedPaths: loadPaths
      },
      armReport,
      firstDirtyEventReport,
      observedReport,
      secondDirtyEventReport,
      cancellationReport,
      commandResult,
      postCancellationFreshnessReport,
      postCancellationRefreshResult,
      postCancellationCompletionFreshnessReport,
      postCancellationCompletionCoverage,
      closeReport: refreshLoadCloseReport,
      assertions: {
        firstDirtyEventAccepted: firstDirtyEventReport.accepted === true,
        secondDirtyEventAccepted: secondDirtyEventReport.accepted === true,
        firstRefreshObservedBeforeSupersede: observedReport.observed === true && observedReport.cancellationObserved === false,
        cancellationReason: "dirtyGenerationSuperseded",
        cancellationObserved: cancellationReport.cancellationObserved === true,
        signalAborted: cancellationReport.signalAborted === true,
        postCancellationStaleCaptureAvailable: postCancellationFreshnessReport.freshnessWorkflow.sourceControlSurface === true &&
          postCancellationFreshnessReport.sourceControl.freshness.repositoryCompleteness === "stale",
        postCancellationRefreshAttempted: postCancellationRefreshResult.attempted === true,
        completedCoverageMatchedSupersededTargets: postCancellationCompletionCoverage.targets.length === 2 &&
          postCancellationCompletionCoverage.coverage.length === 2,
        sourceControlSurfaceAfterCompletion: postCancellationCompletionFreshnessReport.freshnessWorkflow.sourceControlSurface === true
      }
    };
  } catch (error) {
    if (refreshLoadOpenReport && !refreshLoadCloseReport) {
      try {
        await closeOpenReport(refreshLoadOpenReport);
      } catch {
      }
    }
    throw error;
  }
}

function unversionedResources(report) {
  const group = report && report.sourceControl && report.sourceControl.groups
    ? report.sourceControl.groups.find(candidate => candidate.id === "unversioned")
    : undefined;
  if (!group || !Array.isArray(group.resources)) {
    return [];
  }
  return group.resources.filter(resource => resource.contextValue === "subversionr.unversioned");
}

function requireUnversionedProjectionCount(report, expectedCount, label) {
  const resources = unversionedResources(report);
  if (resources.length !== expectedCount) {
    throw new Error(`${label} expected ${expectedCount} unversioned resources, got ${resources.length}.`);
  }
  return resources;
}

function resourceFsPath(workingCopyRoot, resourcePath) {
  return path.join(workingCopyRoot, ...resourcePath.split(/[\\/]/).filter(segment => segment.length > 0));
}

function resourceStateArgument(workingCopyRoot, resource) {
  return {
    contextValue: resource.contextValue,
    subversionrResourceKind: resource.kind,
    subversionrProjectionGeneration: resource.generation,
    resourceUri: vscode.Uri.file(resourceFsPath(workingCopyRoot, resource.path))
  };
}

function deletePromptCaptureExpectations(resourcePath) {
  const message = `Delete unversioned SVN item ${resourcePath}? This cannot be undone.`;
  return {
    requiredDomTokens: [message, "Delete"],
    requiredAccessibilityTokens: [message, "Delete"],
    requiredScreenshot: true,
    clickButtonText: "Delete"
  };
}

function deleteAllPromptCaptureExpectations(itemCount) {
  const message = `Delete ${itemCount} unversioned SVN items? This cannot be undone.`;
  return {
    requiredDomTokens: [message, "Delete"],
    requiredAccessibilityTokens: [message, "Delete"],
    requiredScreenshot: true,
    clickButtonText: "Delete"
  };
}

function removeKeepLocalPromptCaptureExpectations(resourcePath) {
  const message = `Remove SVN resource ${resourcePath} from version control but keep the local item?`;
  return {
    requiredDomTokens: [message, "Remove"],
    requiredAccessibilityTokens: [message, "Remove"],
    requiredScreenshot: true,
    clickButtonText: "Remove"
  };
}

function removePromptCaptureExpectations(resourcePath) {
  const message = `Remove SVN resource ${resourcePath}? The local item will be deleted and scheduled for commit.`;
  return {
    requiredDomTokens: [message, "Remove"],
    requiredAccessibilityTokens: [message, "Remove"],
    requiredScreenshot: true,
    clickButtonText: "Remove"
  };
}

function removeCancellationPromptCaptureExpectations(resourcePath) {
  const message = `Remove SVN resource ${resourcePath}? The local item will be deleted and scheduled for commit.`;
  return {
    requiredDomTokens: [message, "Remove"],
    requiredAccessibilityTokens: [message, "Remove"],
    requiredScreenshot: true
  };
}

function revertPromptCaptureExpectations(resourcePath) {
  const message = `Revert local SVN changes to ${resourcePath}? This cannot be undone.`;
  return {
    requiredDomTokens: [message, "Revert"],
    requiredAccessibilityTokens: [message, "Revert"],
    requiredScreenshot: true,
    clickButtonText: "Revert"
  };
}

function revertCancellationPromptCaptureExpectations(resourcePath) {
  const message = `Revert local SVN changes to ${resourcePath}? This cannot be undone.`;
  return {
    requiredDomTokens: [message, "Revert"],
    requiredAccessibilityTokens: [message, "Revert"],
    requiredScreenshot: true
  };
}

function resolvePromptCaptureExpectations(resourcePath) {
  return {
    requiredDomTokens: ["Resolve SVN conflict", "Working copy", "Use the current working copy file"],
    requiredAccessibilityTokens: ["Resolve SVN conflict", "Working copy", "Use the current working copy file"],
    requiredScreenshot: true,
    quickPickItemText: "Working copy"
  };
}

function resolveCancellationPromptCaptureExpectations(resourcePath) {
  return {
    requiredDomTokens: ["Resolve SVN conflict", "Working copy", "Use the current working copy file"],
    requiredAccessibilityTokens: ["Resolve SVN conflict", "Working copy", "Use the current working copy file"],
    requiredScreenshot: true,
    cancelKey: "Escape",
    cancelSurface: "quickInput"
  };
}

function cleanupPromptCaptureExpectations(workingCopyRoot) {
  return {
    requiredDomTokens: ["SVN cleanup options", "Break working-copy locks", "Release stale SVN working-copy locks before cleanup"],
    requiredAccessibilityTokens: ["SVN cleanup options", "Break working-copy locks", "Release stale SVN working-copy locks before cleanup"],
    requiredScreenshot: true,
    quickInputSubmitKey: "Enter"
  };
}

function movePromptCaptureExpectations(sourcePath, destinationPath) {
  const prompt = `Enter the repository-relative destination path for ${sourcePath}.`;
  return {
    requiredDomTokens: ["Move SVN resource", prompt],
    requiredAccessibilityTokens: ["Move SVN resource", prompt],
    requiredScreenshot: true,
    inputText: destinationPath,
    submitKey: "Enter"
  };
}

function moveCancellationPromptCaptureExpectations(sourcePath) {
  const prompt = `Enter the repository-relative destination path for ${sourcePath}.`;
  return {
    requiredDomTokens: ["Move SVN resource", prompt],
    requiredAccessibilityTokens: ["Move SVN resource", prompt],
    requiredScreenshot: true,
    cancelKey: "Escape"
  };
}

async function runDeleteUnversionedWorkflow(openReport, workingCopyRoot, deletePromptReadyPath) {
  const resource = findResource(openReport, "unversioned", "scratch.txt", "subversionr.unversioned");
  if (!resource || resource.kind !== "file" || typeof resource.generation !== "number") {
    throw new Error("Installed Delete Unversioned workflow could not find the unversioned scratch.txt resource.");
  }

  const fsPath = resourceFsPath(workingCopyRoot, resource.path);
  const fileExistedBefore = fs.existsSync(fsPath);
  if (!fileExistedBefore) {
    throw new Error(`Installed Delete Unversioned workflow fixture file was missing before deletion: ${fsPath}`);
  }

  const promptExpectations = deletePromptCaptureExpectations(resource.path);
  const commandArgument = resourceStateArgument(workingCopyRoot, resource);
  const notificationCleanup = await clearWorkbenchNotificationsBeforePrompt("deleteUnversioned");
  const deleteCommand = withTimeout(
    vscode.commands.executeCommand("subversionr.deleteUnversionedResource", commandArgument),
    "subversionr.deleteUnversionedResource",
    60000
  );
  const notificationList = await showWorkbenchNotificationsForPrompt("deleteUnversioned");
  fs.writeFileSync(deletePromptReadyPath, JSON.stringify({
    ok: true,
    phase: "deleteUnversionedPromptReady",
    command: "subversionr.deleteUnversionedResource",
    resource: {
      path: resource.path,
      contextValue: resource.contextValue,
      kind: resource.kind,
      generation: resource.generation
    },
    notificationCleanup,
    notificationList,
    rendererCaptureExpectations: promptExpectations
  }, null, 2));
  await deleteCommand;

  const fileExistsAfter = fs.existsSync(fsPath);
  if (fileExistsAfter) {
    throw new Error(`Installed Delete Unversioned workflow did not delete fixture file: ${fsPath}`);
  }

  const postDeleteFreshnessReport = await collectFreshnessReportWithSurfaceRetry(
    {
      repositoryId: openReport.repository.repositoryId,
      epoch: openReport.repository.epoch,
      scenario: "partial"
    },
    "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/postDelete",
    30000
  );
  validateFreshnessReport(postDeleteFreshnessReport, "partial", openReport, { expectUnversionedScratch: false });
  const resourcePresentAfter = Boolean(findResource(postDeleteFreshnessReport, "unversioned", resource.path, resource.contextValue));

  return {
    kind: "subversionr.installedSourceControlUiE2eDeleteUnversionedWorkflow",
    generatedAt: new Date().toISOString(),
    command: {
      command: "subversionr.deleteUnversionedResource"
    },
    resource: {
      path: resource.path,
      contextValue: resource.contextValue,
      kind: resource.kind,
      generation: resource.generation
    },
    prompt: {
      confirmationButton: "Delete",
      rendererCaptureExpectations: promptExpectations
    },
    notificationCleanup,
    notificationList,
    postDeleteFreshnessReport,
    assertions: {
      commandExecuted: true,
      fileExistedBefore,
      fileExistsAfter,
      resourcePresentAfter,
      sourceControlProjectionRefreshed: !resourcePresentAfter
    }
  };
}

async function runCommitAllWorkflow(commitAllWorkingCopyRoot) {
  let commitAllOpenReport;
  try {
    commitAllOpenReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: commitAllWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/commitAll",
      60000
    );
    if (!commitAllOpenReport || commitAllOpenReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected installed Source Control UI E2E Commit All open report kind: ${commitAllOpenReport && commitAllOpenReport.kind}`);
    }
    if (path.resolve(commitAllOpenReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(commitAllWorkingCopyRoot).toLowerCase()) {
      throw new Error("Installed Commit All workflow workingCopyRoot did not match the commit-all fixture.");
    }
    if (commitAllOpenReport.sourceControl.inputBox.acceptInputCommand !== "subversionr.commitAll") {
      throw new Error("Installed Commit All workflow open report did not expose the commit-all input accept command.");
    }
    const acceptInputCommand = commitAllOpenReport.sourceControl.inputBox.acceptInputCommand;
    const acceptInputCommandArguments = commitAllOpenReport.sourceControl.inputBox.acceptInputCommandArguments;
    if (
      !Array.isArray(acceptInputCommandArguments) ||
      acceptInputCommandArguments.length !== 1 ||
      acceptInputCommandArguments[0] !== commitAllOpenReport.repository.repositoryId
    ) {
      throw new Error("Installed Commit All workflow open report did not expose the repository-scoped input accept command arguments.");
    }

    const tracked = findResource(commitAllOpenReport, "changes", "src/tracked.txt", "subversionr.changedFile.baseDiffable");
    if (!tracked || tracked.kind !== "file" || typeof tracked.generation !== "number") {
      throw new Error("Installed Commit All workflow could not find the modified tracked resource.");
    }
    const scratch = findResource(commitAllOpenReport, "unversioned", "scratch.txt", "subversionr.unversioned");
    if (!scratch || scratch.kind !== "file" || typeof scratch.generation !== "number") {
      throw new Error("Installed Commit All workflow could not find the excluded unversioned resource.");
    }

    const commitMessage = "commit all eligible changed file resources for the repository input message";
    const setInputReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eSetInputMessage", {
        repositoryId: commitAllOpenReport.repository.repositoryId,
        message: commitMessage
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eSetInputMessage/commitAll",
      30000
    );
    if (
      !setInputReport ||
      setInputReport.kind !== "subversionr.installedSourceControlUiE2eSetInputMessageReport" ||
      setInputReport.repositoryId !== commitAllOpenReport.repository.repositoryId ||
      setInputReport.previousMessageLength !== 0 ||
      setInputReport.messageLength !== commitMessage.length ||
      setInputReport.inputMessageSet !== true
    ) {
      throw new Error("Installed Commit All workflow did not set the repository SourceControl input message.");
    }

    await withTimeout(
      vscode.commands.executeCommand(acceptInputCommand, ...acceptInputCommandArguments),
      "subversionr.commitAll",
      60000
    );

    const postCommitFreshnessReport = await collectFreshnessReportWithSurfaceRetry(
      {
        repositoryId: commitAllOpenReport.repository.repositoryId,
        epoch: commitAllOpenReport.repository.epoch,
        scenario: "partial"
      },
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/commitAll",
      30000
    );
    if (!postCommitFreshnessReport || postCommitFreshnessReport.kind !== "subversionr.installedSourceControlUiE2eFreshnessReport") {
      throw new Error(`Unexpected installed Source Control UI E2E Commit All freshness report kind: ${postCommitFreshnessReport && postCommitFreshnessReport.kind}`);
    }
    const trackedResourceAfter = findAnyResource(postCommitFreshnessReport, tracked.path);
    const unversionedResourceAfter = findResource(postCommitFreshnessReport, "unversioned", scratch.path, scratch.contextValue);
    const coverageReport = validateLastCompletedRefreshCoverage(postCommitFreshnessReport, commitAllOpenReport, {
      path: tracked.path,
      depth: "empty",
      reason: "operationCommit"
    });
    const scratchFileExistsAfter = fs.existsSync(resourceFsPath(commitAllWorkingCopyRoot, scratch.path));

    const inputProbeAfterCommit = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eSetInputMessage", {
        repositoryId: commitAllOpenReport.repository.repositoryId,
        message: "post-commit input clear probe"
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eSetInputMessage/postCommitProbe",
      30000
    );
    if (
      !inputProbeAfterCommit ||
      inputProbeAfterCommit.kind !== "subversionr.installedSourceControlUiE2eSetInputMessageReport" ||
      inputProbeAfterCommit.repositoryId !== commitAllOpenReport.repository.repositoryId
    ) {
      throw new Error("Installed Commit All workflow could not probe the post-commit SourceControl input message.");
    }

    const commitAllCloseReport = await closeOpenReport(commitAllOpenReport);
    if (!commitAllCloseReport || commitAllCloseReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || commitAllCloseReport.repositoryClosed !== true) {
      throw new Error("Installed Commit All workflow did not close the commit-all repository.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eCommitAllWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.commitAll",
        sourceControlAcceptInputCommand: acceptInputCommand,
        arguments: acceptInputCommandArguments
      },
      repository: {
        repositoryId: commitAllOpenReport.repository.repositoryId,
        epoch: commitAllOpenReport.repository.epoch,
        workingCopyRoot: commitAllOpenReport.repository.identity.workingCopyRoot
      },
      input: {
        messageLength: commitMessage.length,
        setInputReport,
        postCommitProbePreviousMessageLength: inputProbeAfterCommit.previousMessageLength
      },
      targets: {
        eligiblePaths: [tracked.path],
        excludedUnversionedPaths: [scratch.path]
      },
      postCommitFreshnessReport,
      closeReport: commitAllCloseReport,
      assertions: {
        commandExecuted: true,
        inputMessageWasSet: setInputReport.inputMessageSet === true,
        inputMessageClearedAfterCommit: inputProbeAfterCommit.previousMessageLength === 0,
        trackedFileCommitted: !trackedResourceAfter,
        unversionedPathRemainedUnversioned: Boolean(unversionedResourceAfter) && scratchFileExistsAfter,
        sourceControlProjectionClearedCommittedPath: !trackedResourceAfter,
        targetedReconcileAfterCommit: coverageReport.targets[0].path === tracked.path &&
          coverageReport.targets[0].reason === "operationCommit" &&
          coverageReport.coverage[0].path === tracked.path
      }
    };
  } catch (error) {
    if (commitAllOpenReport) {
      try {
        await closeOpenReport(commitAllOpenReport);
      } catch {
      }
    }
    throw error;
  }
}

async function runCommitSelectedWorkflow(commitSelectedWorkingCopyRoot) {
  let commitSelectedOpenReport;
  try {
    commitSelectedOpenReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: commitSelectedWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/commitSelected",
      60000
    );
    if (!commitSelectedOpenReport || commitSelectedOpenReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected installed Source Control UI E2E Commit Selected open report kind: ${commitSelectedOpenReport && commitSelectedOpenReport.kind}`);
    }
    if (path.resolve(commitSelectedOpenReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(commitSelectedWorkingCopyRoot).toLowerCase()) {
      throw new Error("Installed Commit Selected workflow workingCopyRoot did not match the commit-selected fixture.");
    }

    const selected = findResource(commitSelectedOpenReport, "changes", "src/tracked.txt", "subversionr.changedFile.baseDiffable");
    if (!selected || selected.kind !== "file" || typeof selected.generation !== "number") {
      throw new Error("Installed Commit Selected workflow could not find the selected modified tracked resource.");
    }
    const unselected = findResource(commitSelectedOpenReport, "changes", "load/modified-001.txt", "subversionr.changedFile.baseDiffable");
    if (!unselected || unselected.kind !== "file" || typeof unselected.generation !== "number") {
      throw new Error("Installed Commit Selected workflow could not find the unselected modified tracked resource.");
    }

    const commitMessage = "commit selected SCM resource from the repository input message";
    const setInputReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eSetInputMessage", {
        repositoryId: commitSelectedOpenReport.repository.repositoryId,
        message: commitMessage
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eSetInputMessage/commitSelected",
      30000
    );
    if (
      !setInputReport ||
      setInputReport.kind !== "subversionr.installedSourceControlUiE2eSetInputMessageReport" ||
      setInputReport.repositoryId !== commitSelectedOpenReport.repository.repositoryId ||
      setInputReport.previousMessageLength !== 0 ||
      setInputReport.messageLength !== commitMessage.length ||
      setInputReport.inputMessageSet !== true
    ) {
      throw new Error("Installed Commit Selected workflow did not set the repository SourceControl input message.");
    }

    const commandArgument = resourceStateArgument(commitSelectedWorkingCopyRoot, selected);
    await withTimeout(
      vscode.commands.executeCommand("subversionr.commitResource", commandArgument),
      "subversionr.commitResource",
      60000
    );

    const postCommitFreshnessReport = await collectFreshnessReportWithSurfaceRetry(
      {
        repositoryId: commitSelectedOpenReport.repository.repositoryId,
        epoch: commitSelectedOpenReport.repository.epoch,
        scenario: "partial"
      },
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/commitSelected",
      30000
    );
    if (!postCommitFreshnessReport || postCommitFreshnessReport.kind !== "subversionr.installedSourceControlUiE2eFreshnessReport") {
      throw new Error(`Unexpected installed Source Control UI E2E Commit Selected freshness report kind: ${postCommitFreshnessReport && postCommitFreshnessReport.kind}`);
    }
    const selectedResourceAfter = findAnyResource(postCommitFreshnessReport, selected.path);
    const unselectedResourceAfter = findResource(postCommitFreshnessReport, "changes", unselected.path, unselected.contextValue);
    const coverageReport = validateLastCompletedRefreshCoverage(postCommitFreshnessReport, commitSelectedOpenReport, {
      path: selected.path,
      depth: "empty",
      reason: "operationCommit"
    });

    const inputProbeAfterCommit = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eSetInputMessage", {
        repositoryId: commitSelectedOpenReport.repository.repositoryId,
        message: "post-commit-selected input clear probe"
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eSetInputMessage/postCommitSelectedProbe",
      30000
    );
    if (
      !inputProbeAfterCommit ||
      inputProbeAfterCommit.kind !== "subversionr.installedSourceControlUiE2eSetInputMessageReport" ||
      inputProbeAfterCommit.repositoryId !== commitSelectedOpenReport.repository.repositoryId
    ) {
      throw new Error("Installed Commit Selected workflow could not probe the post-commit SourceControl input message.");
    }

    const commitSelectedCloseReport = await closeOpenReport(commitSelectedOpenReport);
    if (!commitSelectedCloseReport || commitSelectedCloseReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || commitSelectedCloseReport.repositoryClosed !== true) {
      throw new Error("Installed Commit Selected workflow did not close the commit-selected repository.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eCommitSelectedWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.commitResource",
        argument: {
          path: selected.path,
          contextValue: selected.contextValue,
          kind: selected.kind,
          generation: selected.generation
        }
      },
      repository: {
        repositoryId: commitSelectedOpenReport.repository.repositoryId,
        epoch: commitSelectedOpenReport.repository.epoch,
        workingCopyRoot: commitSelectedOpenReport.repository.identity.workingCopyRoot
      },
      input: {
        messageLength: commitMessage.length,
        setInputReport,
        postCommitProbePreviousMessageLength: inputProbeAfterCommit.previousMessageLength
      },
      targets: {
        selectedPaths: [selected.path],
        unselectedChangedPaths: [unselected.path]
      },
      postCommitFreshnessReport,
      closeReport: commitSelectedCloseReport,
      assertions: {
        commandExecuted: true,
        inputMessageWasSet: setInputReport.inputMessageSet === true,
        inputMessageClearedAfterCommit: inputProbeAfterCommit.previousMessageLength === 0,
        selectedFileCommitted: !selectedResourceAfter,
        unselectedFileStillModified: Boolean(unselectedResourceAfter),
        sourceControlProjectionClearedCommittedPath: !selectedResourceAfter,
        targetedReconcileAfterCommit: coverageReport.targets[0].path === selected.path &&
          coverageReport.targets[0].reason === "operationCommit" &&
          coverageReport.coverage[0].path === selected.path
      }
    };
  } catch (error) {
    if (commitSelectedOpenReport) {
      try {
        await closeOpenReport(commitSelectedOpenReport);
      } catch {
      }
    }
    throw error;
  }
}

async function runCommitSelectedMultiSelectionWorkflow(commitSelectedMultiSelectionWorkingCopyRoot) {
  let commitSelectedMultiSelectionOpenReport;
  try {
    commitSelectedMultiSelectionOpenReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: commitSelectedMultiSelectionWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/commitSelectedMultiSelection",
      60000
    );
    if (!commitSelectedMultiSelectionOpenReport || commitSelectedMultiSelectionOpenReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected installed Source Control UI E2E Commit Selected multi-selection open report kind: ${commitSelectedMultiSelectionOpenReport && commitSelectedMultiSelectionOpenReport.kind}`);
    }
    if (path.resolve(commitSelectedMultiSelectionOpenReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(commitSelectedMultiSelectionWorkingCopyRoot).toLowerCase()) {
      throw new Error("Installed Commit Selected multi-selection workflow workingCopyRoot did not match the multi-selection fixture.");
    }

    const firstSelected = findResource(commitSelectedMultiSelectionOpenReport, "changes", "src/tracked.txt", "subversionr.changedFile.baseDiffable");
    if (!firstSelected || firstSelected.kind !== "file" || typeof firstSelected.generation !== "number") {
      throw new Error("Installed Commit Selected multi-selection workflow could not find the first selected modified tracked resource.");
    }
    const secondSelected = findResource(commitSelectedMultiSelectionOpenReport, "changes", "load/modified-001.txt", "subversionr.changedFile.baseDiffable");
    if (!secondSelected || secondSelected.kind !== "file" || typeof secondSelected.generation !== "number") {
      throw new Error("Installed Commit Selected multi-selection workflow could not find the second selected modified tracked resource.");
    }

    const commitMessage = "commit selected SCM resources from a Source Control multi-selection";
    const setInputReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eSetInputMessage", {
        repositoryId: commitSelectedMultiSelectionOpenReport.repository.repositoryId,
        message: commitMessage
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eSetInputMessage/commitSelectedMultiSelection",
      30000
    );
    if (
      !setInputReport ||
      setInputReport.kind !== "subversionr.installedSourceControlUiE2eSetInputMessageReport" ||
      setInputReport.repositoryId !== commitSelectedMultiSelectionOpenReport.repository.repositoryId ||
      setInputReport.previousMessageLength !== 0 ||
      setInputReport.messageLength !== commitMessage.length ||
      setInputReport.inputMessageSet !== true
    ) {
      throw new Error("Installed Commit Selected multi-selection workflow did not set the repository SourceControl input message.");
    }

    const commandArguments = [
      resourceStateArgument(commitSelectedMultiSelectionWorkingCopyRoot, firstSelected),
      resourceStateArgument(commitSelectedMultiSelectionWorkingCopyRoot, secondSelected)
    ];
    await withTimeout(
      vscode.commands.executeCommand("subversionr.commitResource", commandArguments),
      "subversionr.commitResource/multiSelection",
      60000
    );

    const postCommitFreshnessReport = await collectFreshnessReportWithSurfaceRetry(
      {
        repositoryId: commitSelectedMultiSelectionOpenReport.repository.repositoryId,
        epoch: commitSelectedMultiSelectionOpenReport.repository.epoch,
        scenario: "partial"
      },
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/commitSelectedMultiSelection",
      30000
    );
    if (!postCommitFreshnessReport || postCommitFreshnessReport.kind !== "subversionr.installedSourceControlUiE2eFreshnessReport") {
      throw new Error(`Unexpected installed Source Control UI E2E Commit Selected multi-selection freshness report kind: ${postCommitFreshnessReport && postCommitFreshnessReport.kind}`);
    }
    const firstSelectedResourceAfter = findAnyResource(postCommitFreshnessReport, firstSelected.path);
    const secondSelectedResourceAfter = findAnyResource(postCommitFreshnessReport, secondSelected.path);
    const coverageReport = validateLastCompletedRefreshCoverageSet(postCommitFreshnessReport, commitSelectedMultiSelectionOpenReport, [
      {
        path: firstSelected.path,
        depth: "empty",
        reason: "operationCommit"
      },
      {
        path: secondSelected.path,
        depth: "empty",
        reason: "operationCommit"
      }
    ]);

    const inputProbeAfterCommit = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eSetInputMessage", {
        repositoryId: commitSelectedMultiSelectionOpenReport.repository.repositoryId,
        message: "post-commit-selected-multi-selection input clear probe"
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eSetInputMessage/postCommitSelectedMultiSelectionProbe",
      30000
    );
    if (
      !inputProbeAfterCommit ||
      inputProbeAfterCommit.kind !== "subversionr.installedSourceControlUiE2eSetInputMessageReport" ||
      inputProbeAfterCommit.repositoryId !== commitSelectedMultiSelectionOpenReport.repository.repositoryId
    ) {
      throw new Error("Installed Commit Selected multi-selection workflow could not probe the post-commit SourceControl input message.");
    }

    const commitSelectedMultiSelectionCloseReport = await closeOpenReport(commitSelectedMultiSelectionOpenReport);
    if (!commitSelectedMultiSelectionCloseReport || commitSelectedMultiSelectionCloseReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || commitSelectedMultiSelectionCloseReport.repositoryClosed !== true) {
      throw new Error("Installed Commit Selected multi-selection workflow did not close the commit-selected multi-selection repository.");
    }

    const selectedPathsCleared = !firstSelectedResourceAfter && !secondSelectedResourceAfter;
    const targetedReconcileMatched = coverageReport.targets[0].path === firstSelected.path &&
      coverageReport.targets[0].reason === "operationCommit" &&
      coverageReport.coverage[0].path === firstSelected.path &&
      coverageReport.targets[1].path === secondSelected.path &&
      coverageReport.targets[1].reason === "operationCommit" &&
      coverageReport.coverage[1].path === secondSelected.path;

    return {
      kind: "subversionr.installedSourceControlUiE2eCommitSelectedMultiSelectionWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.commitResource",
        argumentShape: "resourceStateArray",
        arguments: [firstSelected, secondSelected].map(resource => ({
          path: resource.path,
          contextValue: resource.contextValue,
          kind: resource.kind,
          generation: resource.generation
        }))
      },
      repository: {
        repositoryId: commitSelectedMultiSelectionOpenReport.repository.repositoryId,
        epoch: commitSelectedMultiSelectionOpenReport.repository.epoch,
        workingCopyRoot: commitSelectedMultiSelectionOpenReport.repository.identity.workingCopyRoot
      },
      input: {
        messageLength: commitMessage.length,
        setInputReport,
        postCommitProbePreviousMessageLength: inputProbeAfterCommit.previousMessageLength
      },
      targets: {
        selectedPaths: [firstSelected.path, secondSelected.path]
      },
      postCommitFreshnessReport,
      closeReport: commitSelectedMultiSelectionCloseReport,
      assertions: {
        commandExecuted: true,
        inputMessageWasSet: setInputReport.inputMessageSet === true,
        inputMessageClearedAfterCommit: inputProbeAfterCommit.previousMessageLength === 0,
        allSelectedFilesCommitted: selectedPathsCleared,
        sourceControlProjectionClearedSelectedPaths: selectedPathsCleared,
        targetedReconcileAfterCommit: targetedReconcileMatched
      }
    };
  } catch (error) {
    if (commitSelectedMultiSelectionOpenReport) {
      try {
        await closeOpenReport(commitSelectedMultiSelectionOpenReport);
      } catch {
      }
    }
    throw error;
  }
}

async function runAddToIgnoreWorkflow(addToIgnoreWorkingCopyRoot) {
  let openReport;
  let closeReport;
  try {
    openReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: addToIgnoreWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/addToIgnore",
      60000
    );
    if (!openReport || openReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected installed Add to Ignore open report kind: ${openReport && openReport.kind}`);
    }
    const scratch = findResource(openReport, "unversioned", "scratch.txt", "subversionr.unversioned");
    if (!scratch || scratch.kind !== "file" || typeof scratch.generation !== "number") {
      throw new Error("Installed Add to Ignore workflow could not find the unversioned scratch.txt resource.");
    }

    await withTimeout(
      vscode.commands.executeCommand("subversionr.addToIgnoreResource", resourceStateArgument(addToIgnoreWorkingCopyRoot, scratch)),
      "subversionr.addToIgnoreResource",
      60000
    );

    const postIgnoreFreshnessReport = await collectFreshnessReportWithSurfaceRetry(
      {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        scenario: "partial"
      },
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/addToIgnore",
      30000
    );
    validateFreshnessReport(postIgnoreFreshnessReport, "partial", openReport, { expectUnversionedScratch: false });
    const coverageReport = validateLastCompletedRefreshCoverage(postIgnoreFreshnessReport, openReport, {
      path: scratch.path,
      depth: "empty",
      reason: "operationPropertySet"
    });
    const scratchAfter = findResource(postIgnoreFreshnessReport, "unversioned", scratch.path, scratch.contextValue);
    const rootPropertyResource = findResource(postIgnoreFreshnessReport, "changes", ".", "subversionr.changedDirectory");
    if (!rootPropertyResource || rootPropertyResource.kind !== "dir" || typeof rootPropertyResource.generation !== "number") {
      throw new Error("Installed Add to Ignore workflow did not project the working-copy root svn:ignore property-only change.");
    }

    closeReport = await closeOpenReport(openReport);
    if (!closeReport || closeReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || closeReport.repositoryClosed !== true) {
      throw new Error("Installed Add to Ignore workflow did not close the add-to-ignore repository.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eAddToIgnoreWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.addToIgnoreResource",
        argument: {
          path: scratch.path,
          contextValue: scratch.contextValue,
          kind: scratch.kind,
          generation: scratch.generation
        }
      },
      repository: {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        workingCopyRoot: openReport.repository.identity.workingCopyRoot
      },
      resource: {
        path: scratch.path,
        contextValue: scratch.contextValue,
        kind: scratch.kind,
        generation: scratch.generation
      },
      rootPropertyResource: {
        path: rootPropertyResource.path,
        contextValue: rootPropertyResource.contextValue,
        kind: rootPropertyResource.kind,
        generation: rootPropertyResource.generation
      },
      property: {
        parentPath: ".",
        name: "svn:ignore",
        addedPatterns: ["scratch.txt"]
      },
      postIgnoreFreshnessReport,
      closeReport,
      assertions: {
        commandExecuted: true,
        propertyListReadBeforeSet: true,
        propertySetExecuted: true,
        workingCopyIgnorePropertyUpdated: true,
        rootPropertyChangeProjected: true,
        unversionedProjectionCleared: !scratchAfter,
        targetedReconcileAfterPropertySet:
          coverageReport.targets[0].path === scratch.path &&
          coverageReport.targets[0].reason === "operationPropertySet" &&
          coverageReport.coverage[0].path === scratch.path,
        repositoryClosedAfterEvidence: closeReport.repositoryClosed === true
      }
    };
  } catch (error) {
    if (openReport && !closeReport) {
      try {
        await closeOpenReport(openReport);
      } catch (closeError) {
        const combined = new Error(`Installed Add to Ignore workflow failed at ${error.message}; cleanup close also failed: ${serializeError(closeError).message}`);
        combined.primaryError = serializeError(error);
        combined.cleanupError = serializeError(closeError);
        throw combined;
      }
    }
    throw error;
  }
}

function lockMessagePromptCaptureExpectations(comment, resourcePath) {
  return {
    requiredDomTokens: ["Lock SVN resource", `Enter an SVN lock message for ${resourcePath}.`],
    requiredAccessibilityTokens: ["Lock SVN resource", `Enter an SVN lock message for ${resourcePath}.`, "Lock message"],
    requiredScreenshot: true,
    inputText: comment,
    submitKey: "Enter"
  };
}

function lockMessageCancellationPromptCaptureExpectations(resourcePath) {
  return {
    requiredDomTokens: ["Lock SVN resource", `Enter an SVN lock message for ${resourcePath}.`],
    requiredAccessibilityTokens: ["Lock SVN resource", `Enter an SVN lock message for ${resourcePath}.`, "Lock message"],
    requiredScreenshot: true,
    cancelSurface: "quickInput",
    cancelKey: "Escape"
  };
}

function lockModePromptCaptureExpectations() {
  return {
    requiredDomTokens: ["SVN lock mode", "Lock", "Steal lock"],
    requiredAccessibilityTokens: ["SVN lock mode", "Lock", "Steal lock"],
    requiredScreenshot: true,
    quickPickItemText: "Lock"
  };
}

function unlockModePromptCaptureExpectations() {
  return {
    requiredDomTokens: ["SVN unlock mode", "Unlock", "Force unlock"],
    requiredAccessibilityTokens: ["SVN unlock mode", "Unlock", "Force unlock"],
    requiredScreenshot: true,
    quickPickItemText: "Unlock"
  };
}

function unlockModeCancellationPromptCaptureExpectations() {
  return {
    requiredDomTokens: ["SVN unlock mode", "Unlock", "Force unlock"],
    requiredAccessibilityTokens: ["SVN unlock mode", "Unlock", "Force unlock"],
    requiredScreenshot: true,
    cancelSurface: "quickInput",
    cancelKey: "Escape"
  };
}

async function runLockUnlockWorkflow(lockWorkingCopyRoot, promptPaths) {
  let openReport;
  let closeReport;
  let lockMessageCancellationPrompt;
  let lockMessageCancellationSurfaceReport;
  let lockMessageCancellationProjectionUnchanged = false;
  let unlockModeCancellationPrompt;
  let preUnlockSurfaceReport;
  let unlockModeCancellationSurfaceReport;
  let unlockModeCancellationProjectionUnchanged = false;
  const lockComment = "Beta-E installed lock evidence";
  const resourcePath = "src/needs-lock.txt";
  try {
    openReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: lockWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/lockUnlock",
      60000
    );
    if (!openReport || openReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected installed Lock/Unlock open report kind: ${openReport && openReport.kind}`);
    }
    const resource = findResource(openReport, "changes", resourcePath, "subversionr.workingCopyMetadataFile");
    if (!resource || resource.kind !== "file" || typeof resource.generation !== "number") {
      throw new Error("Installed Lock/Unlock workflow could not find the clean svn:needs-lock metadata resource.");
    }

    const lockCancellationCommand = withTimeout(
      vscode.commands.executeCommand("subversionr.lockResource", resourceStateArgument(lockWorkingCopyRoot, resource)),
      "subversionr.lockResource/messageCancellation",
      60000
    );
    await new Promise(resolve => setTimeout(resolve, 500));

    lockMessageCancellationPrompt = lockMessageCancellationPromptCaptureExpectations(resource.path);
    await publishCheckoutPromptReadyAndWait(promptPaths.lockMessageCancellationReady, promptPaths.lockMessageCancellationDone, {
      ok: true,
      phase: "lockMessageCancellationPromptReady",
      command: "subversionr.lockResource",
      resource,
      prompt: {
        cancelKey: "Escape",
        rendererCaptureExpectations: lockMessageCancellationPrompt
      },
      cancelKey: "Escape",
      rendererCaptureExpectations: lockMessageCancellationPrompt
    });
    await lockCancellationCommand;

    lockMessageCancellationSurfaceReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport", { path: lockWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport/lockMessageCancellation",
      30000
    );
    if (
      !lockMessageCancellationSurfaceReport ||
      lockMessageCancellationSurfaceReport.kind !== "subversionr.installedSourceControlUiE2eCurrentSurfaceReport" ||
      path.resolve(lockMessageCancellationSurfaceReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(lockWorkingCopyRoot).toLowerCase()
    ) {
      throw new Error(`Unexpected installed Lock message cancellation current surface report kind: ${lockMessageCancellationSurfaceReport && lockMessageCancellationSurfaceReport.kind}`);
    }
    lockMessageCancellationProjectionUnchanged =
      lockMessageCancellationSurfaceReport.surfaceWorkflow.scmProjection === true &&
      lockMessageCancellationSurfaceReport.surfaceWorkflow.sourceControlSurface === true &&
      sourceControlProjectionMatches(lockMessageCancellationSurfaceReport, openReport);
    if (!lockMessageCancellationProjectionUnchanged) {
      throw new Error("Installed Lock message cancellation workflow changed the Source Control projection after cancellation.");
    }

    const lockCommand = withTimeout(
      vscode.commands.executeCommand("subversionr.lockResource", resourceStateArgument(lockWorkingCopyRoot, resource)),
      "subversionr.lockResource",
      60000
    );
    await new Promise(resolve => setTimeout(resolve, 500));

    const lockMessagePrompt = lockMessagePromptCaptureExpectations(lockComment, resource.path);
    await publishCheckoutPromptReadyAndWait(promptPaths.lockMessageReady, promptPaths.lockMessageDone, {
      ok: true,
      phase: "lockMessagePromptReady",
      command: "subversionr.lockResource",
      resource,
      prompt: {
        comment: lockComment,
        rendererCaptureExpectations: lockMessagePrompt
      },
      rendererCaptureExpectations: lockMessagePrompt
    });

    const lockModePrompt = lockModePromptCaptureExpectations();
    await publishCheckoutPromptReadyAndWait(promptPaths.lockModeReady, promptPaths.lockModeDone, {
      ok: true,
      phase: "lockModePromptReady",
      command: "subversionr.lockResource",
      resource,
      prompt: {
        selected: "Lock",
        stealLock: false,
        rendererCaptureExpectations: lockModePrompt
      },
      rendererCaptureExpectations: lockModePrompt
    });

    await lockCommand;

    const postLockFreshnessReport = await collectFreshnessReportWithSurfaceRetry(
      {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        scenario: "partial"
      },
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/lock",
      30000
    );
    const lockedResource = findResource(postLockFreshnessReport, "changes", resource.path, "subversionr.workingCopyMetadataFile.locked");
    if (!lockedResource) {
      throw new Error("Installed Lock workflow did not preserve the needs-lock metadata resource projection after locking.");
    }
    const lockCoverage = validateLastCompletedRefreshCoverage(postLockFreshnessReport, openReport, {
      path: resource.path,
      depth: "empty",
      reason: "operationLock"
    });

    fs.writeFileSync(promptPaths.lockHeldOracleReady, JSON.stringify({
      ok: true,
      phase: "lockHeldOracleReady",
      command: "subversionr.lockResource",
      resource: {
        path: resource.path,
        contextValue: resource.contextValue,
        kind: resource.kind,
        generation: resource.generation
      }
    }, null, 2));
    await waitForFile(promptPaths.lockHeldOracleDone, 120000);

    preUnlockSurfaceReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport", { path: lockWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport/preUnlock",
      30000
    );
    if (
      !preUnlockSurfaceReport ||
      preUnlockSurfaceReport.kind !== "subversionr.installedSourceControlUiE2eCurrentSurfaceReport" ||
      path.resolve(preUnlockSurfaceReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(lockWorkingCopyRoot).toLowerCase()
    ) {
      throw new Error(`Unexpected installed pre-Unlock current surface report kind: ${preUnlockSurfaceReport && preUnlockSurfaceReport.kind}`);
    }
    const currentUnlockResource = findResource(preUnlockSurfaceReport, "changes", resource.path, "subversionr.workingCopyMetadataFile.locked");
    if (!currentUnlockResource || currentUnlockResource.kind !== "file" || typeof currentUnlockResource.generation !== "number") {
      throw new Error("Installed Lock/Unlock workflow could not find the current locked resource before Unlock cancellation.");
    }

    const unlockCancellationCommand = withTimeout(
      vscode.commands.executeCommand("subversionr.unlockResource", resourceStateArgument(lockWorkingCopyRoot, currentUnlockResource)),
      "subversionr.unlockResource/modeCancellation",
      60000
    );
    await new Promise(resolve => setTimeout(resolve, 500));

    unlockModeCancellationPrompt = unlockModeCancellationPromptCaptureExpectations();
    await publishCheckoutPromptReadyAndWait(promptPaths.unlockModeCancellationReady, promptPaths.unlockModeCancellationDone, {
      ok: true,
      phase: "unlockModeCancellationPromptReady",
      command: "subversionr.unlockResource",
      resource: lockedResource,
      prompt: {
        cancelKey: "Escape",
        rendererCaptureExpectations: unlockModeCancellationPrompt
      },
      cancelKey: "Escape",
      rendererCaptureExpectations: unlockModeCancellationPrompt
    });
    await unlockCancellationCommand;

    unlockModeCancellationSurfaceReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport", { path: lockWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport/unlockModeCancellation",
      30000
    );
    if (
      !unlockModeCancellationSurfaceReport ||
      unlockModeCancellationSurfaceReport.kind !== "subversionr.installedSourceControlUiE2eCurrentSurfaceReport" ||
      path.resolve(unlockModeCancellationSurfaceReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(lockWorkingCopyRoot).toLowerCase()
    ) {
      throw new Error(`Unexpected installed Unlock mode cancellation current surface report kind: ${unlockModeCancellationSurfaceReport && unlockModeCancellationSurfaceReport.kind}`);
    }
    unlockModeCancellationProjectionUnchanged =
      unlockModeCancellationSurfaceReport.surfaceWorkflow.scmProjection === true &&
      unlockModeCancellationSurfaceReport.surfaceWorkflow.sourceControlSurface === true &&
      sourceControlProjectionMatches(unlockModeCancellationSurfaceReport, preUnlockSurfaceReport);
    if (!unlockModeCancellationProjectionUnchanged) {
      throw new Error("Installed Unlock mode cancellation workflow changed the Source Control projection after cancellation.");
    }
    const currentUnlockResourceAfterCancellation = findResource(unlockModeCancellationSurfaceReport, "changes", resource.path, "subversionr.workingCopyMetadataFile.locked");
    if (!currentUnlockResourceAfterCancellation || currentUnlockResourceAfterCancellation.kind !== "file" || typeof currentUnlockResourceAfterCancellation.generation !== "number") {
      throw new Error("Installed Lock/Unlock workflow could not find the current locked resource after Unlock cancellation.");
    }

    const unlockCommand = withTimeout(
      vscode.commands.executeCommand("subversionr.unlockResource", resourceStateArgument(lockWorkingCopyRoot, currentUnlockResourceAfterCancellation)),
      "subversionr.unlockResource",
      60000
    );
    await new Promise(resolve => setTimeout(resolve, 500));

    const unlockModePrompt = unlockModePromptCaptureExpectations();
    await publishCheckoutPromptReadyAndWait(promptPaths.unlockModeReady, promptPaths.unlockModeDone, {
      ok: true,
      phase: "unlockModePromptReady",
      command: "subversionr.unlockResource",
      resource: lockedResource,
      prompt: {
        selected: "Unlock",
        breakLock: false,
        rendererCaptureExpectations: unlockModePrompt
      },
      rendererCaptureExpectations: unlockModePrompt
    });

    await unlockCommand;

    const postUnlockFreshnessReport = await collectFreshnessReportWithSurfaceRetry(
      {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        scenario: "partial"
      },
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/unlock",
      30000
    );
    const unlockedResource = findResource(postUnlockFreshnessReport, "changes", resource.path, "subversionr.workingCopyMetadataFile");
    if (!unlockedResource) {
      throw new Error("Installed Unlock workflow did not preserve the svn:needs-lock metadata projection after unlocking.");
    }
    const unlockCoverage = validateLastCompletedRefreshCoverage(postUnlockFreshnessReport, openReport, {
      path: resource.path,
      depth: "empty",
      reason: "operationUnlock"
    });

    closeReport = await closeOpenReport(openReport);
    if (!closeReport || closeReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || closeReport.repositoryClosed !== true) {
      throw new Error("Installed Lock/Unlock workflow did not close the lock repository.");
    }

    const lockUnlockReport = {
      kind: "subversionr.installedSourceControlUiE2eLockUnlockWorkflow",
      generatedAt: new Date().toISOString(),
      commands: {
        lock: "subversionr.lockResource",
        unlock: "subversionr.unlockResource"
      },
      repository: {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        workingCopyRoot: openReport.repository.identity.workingCopyRoot
      },
      resource: {
        path: resource.path,
        contextValueBefore: resource.contextValue,
        contextValueAfterLock: lockedResource.contextValue,
        contextValueAfterUnlock: unlockedResource.contextValue,
        kind: resource.kind,
        generation: resource.generation
      },
      request: {
        comment: lockComment,
        stealLock: false,
        breakLock: false
      },
      prompts: {
        lockMessage: {
          rendererCaptureExpectations: lockMessagePrompt
        },
        lockMode: {
          selected: "Lock",
          rendererCaptureExpectations: lockModePrompt
        },
        unlockMode: {
          selected: "Unlock",
          rendererCaptureExpectations: unlockModePrompt
        }
      },
      postLockFreshnessReport,
      preUnlockSurfaceReport,
      postUnlockFreshnessReport,
      closeReport,
      assertions: {
        needsLockProjectedBefore: true,
        lockCommandExecuted: true,
        lockUsedNormalPolicy: true,
        lockHeldOracleHandshakeCompleted: true,
        unlockCommandExecuted: true,
        unlockUsedNormalPolicy: true,
        needsLockProjectionPreservedAfterLock: Boolean(lockedResource),
        needsLockProjectionPreservedAfterUnlock: Boolean(unlockedResource),
        lockTargetedReconcile:
          lockCoverage.targets[0].path === resource.path &&
          lockCoverage.targets[0].reason === "operationLock" &&
          lockCoverage.coverage[0].path === resource.path,
        unlockTargetedReconcile:
          unlockCoverage.targets[0].path === resource.path &&
          unlockCoverage.targets[0].reason === "operationUnlock" &&
          unlockCoverage.coverage[0].path === resource.path,
        repositoryClosedAfterEvidence: closeReport.repositoryClosed === true
      }
    };
    const lockMessageCancellationReport = {
      kind: "subversionr.installedSourceControlUiE2eLockMessageCancellationWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.lockResource"
      },
      repository: {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        workingCopyRoot: openReport.repository.identity.workingCopyRoot
      },
      resource: {
        path: resource.path,
        contextValue: resource.contextValue,
        kind: resource.kind,
        generation: resource.generation
      },
      prompt: {
        cancelKey: "Escape",
        rendererCaptureExpectations: lockMessageCancellationPrompt
      },
      currentSurfaceReport: lockMessageCancellationSurfaceReport,
      closeReport,
      assertions: {
        commandCancelled: true,
        sourceControlProjectionUnchanged: lockMessageCancellationProjectionUnchanged,
        repositoryClosedAfterEvidence: closeReport.repositoryClosed === true
      }
    };
    const unlockModeCancellationReport = {
      kind: "subversionr.installedSourceControlUiE2eUnlockModeCancellationWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.unlockResource"
      },
      repository: {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        workingCopyRoot: openReport.repository.identity.workingCopyRoot
      },
      resource: {
        path: currentUnlockResource.path,
        contextValue: currentUnlockResource.contextValue,
        kind: currentUnlockResource.kind,
        generation: currentUnlockResource.generation
      },
      prompt: {
        cancelKey: "Escape",
        rendererCaptureExpectations: unlockModeCancellationPrompt
      },
      currentSurfaceReport: unlockModeCancellationSurfaceReport,
      closeReport,
      assertions: {
        commandCancelled: true,
        sourceControlProjectionUnchanged: unlockModeCancellationProjectionUnchanged,
        repositoryClosedAfterEvidence: closeReport.repositoryClosed === true
      }
    };
    return {
      lockUnlockReport,
      lockMessageCancellationReport,
      unlockModeCancellationReport
    };
  } catch (error) {
    if (openReport && !closeReport) {
      try {
        await closeOpenReport(openReport);
      } catch (closeError) {
        const combined = new Error(`Installed Lock/Unlock workflow failed at ${error.message}; cleanup close also failed: ${serializeError(closeError).message}`);
        combined.primaryError = serializeError(error);
        combined.cleanupError = serializeError(closeError);
        throw combined;
      }
    }
    throw error;
  }
}

function changelistSetPromptCaptureExpectations(changelist, resourcePath) {
  const prompt = `Enter the SVN changelist name for ${resourcePath}.`;
  return {
    requiredDomTokens: ["Set SVN changelist", prompt],
    requiredAccessibilityTokens: ["Set SVN changelist", prompt, "Changelist name"],
    requiredScreenshot: true,
    inputText: changelist,
    submitKey: "Enter"
  };
}

function changelistGroupId(changelist) {
  return `changelist:${encodeURIComponent(changelist)}`;
}

function changelistGroupCommandArgument(openReport, changelist) {
  return {
    subversionrRepositoryId: openReport.repository.repositoryId,
    subversionrChangelistName: changelist
  };
}

async function runChangelistSetClearWorkflow(changelistWorkingCopyRoot, changelistSetPromptReadyPath) {
  let openReport;
  let closeReport;
  const changelist = "review";
  const groupId = changelistGroupId(changelist);
  try {
    openReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: changelistWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/changelistSetClear",
      60000
    );
    if (!openReport || openReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected installed Changelist set/clear open report kind: ${openReport && openReport.kind}`);
    }
    const resource = findResource(openReport, "changes", "src/tracked.txt", "subversionr.changedFile.baseDiffable");
    if (!resource || resource.kind !== "file" || typeof resource.generation !== "number") {
      throw new Error("Installed Changelist set/clear workflow could not find the modified tracked resource.");
    }

    const setCommand = withTimeout(
      vscode.commands.executeCommand("subversionr.setResourceChangelist", resourceStateArgument(changelistWorkingCopyRoot, resource)),
      "subversionr.setResourceChangelist",
      60000
    );
    await new Promise(resolve => setTimeout(resolve, 500));
    const setPrompt = changelistSetPromptCaptureExpectations(changelist, resource.path);
    fs.writeFileSync(changelistSetPromptReadyPath, JSON.stringify({
      ok: true,
      phase: "changelistSetPromptReady",
      command: "subversionr.setResourceChangelist",
      resource: {
        path: resource.path,
        contextValue: resource.contextValue,
        kind: resource.kind,
        generation: resource.generation
      },
      prompt: {
        changelist,
        rendererCaptureExpectations: setPrompt
      },
      rendererCaptureExpectations: setPrompt
    }, null, 2));
    await setCommand;

    const postSetFreshnessReport = await collectFreshnessReportWithSurfaceRetry(
      {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        scenario: "partial"
      },
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/changelistSet",
      30000
    );
    const groupAfterSet = findGroup(postSetFreshnessReport, groupId);
    const changelistedResource = findResource(postSetFreshnessReport, groupId, resource.path, "subversionr.changedFile.baseDiffable.changelisted");
    if (!groupAfterSet || !changelistedResource) {
      throw new Error("Installed Changelist set workflow did not project the review changelist group and resource.");
    }
    const setCoverage = validateLastCompletedRefreshCoverage(postSetFreshnessReport, openReport, {
      path: resource.path,
      depth: "empty",
      reason: "operationChangelistSet"
    });

    await withTimeout(
      vscode.commands.executeCommand("subversionr.clearResourceChangelist", resourceStateArgument(changelistWorkingCopyRoot, changelistedResource)),
      "subversionr.clearResourceChangelist",
      60000
    );

    const postClearFreshnessReport = await collectFreshnessReportWithSurfaceRetry(
      {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        scenario: "partial"
      },
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/changelistClear",
      30000
    );
    const groupAfterClear = findGroup(postClearFreshnessReport, groupId);
    const clearedResource = findResource(postClearFreshnessReport, "changes", resource.path, "subversionr.changedFile.baseDiffable");
    const clearCoverage = validateLastCompletedRefreshCoverage(postClearFreshnessReport, openReport, {
      path: resource.path,
      depth: "empty",
      reason: "operationChangelistClear"
    });

    closeReport = await closeOpenReport(openReport);
    if (!closeReport || closeReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || closeReport.repositoryClosed !== true) {
      throw new Error("Installed Changelist set/clear workflow did not close the changelist repository.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eChangelistSetClearWorkflow",
      generatedAt: new Date().toISOString(),
      commands: {
        set: "subversionr.setResourceChangelist",
        clear: "subversionr.clearResourceChangelist"
      },
      repository: {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        workingCopyRoot: openReport.repository.identity.workingCopyRoot
      },
      changelist,
      groupId,
      resource: {
        path: resource.path,
        contextValueBefore: resource.contextValue,
        contextValueAfterSet: changelistedResource.contextValue,
        contextValueAfterClear: clearedResource && clearedResource.contextValue
      },
      prompts: {
        set: {
          changelist,
          rendererCaptureExpectations: setPrompt
        }
      },
      postSetFreshnessReport,
      postClearFreshnessReport,
      closeReport,
      assertions: {
        setCommandExecuted: true,
        clearCommandExecuted: true,
        groupProjectedAfterSet: Boolean(groupAfterSet),
        resourceProjectedInChangelistAfterSet: Boolean(changelistedResource),
        resourceReturnedToChangesAfterClear: Boolean(clearedResource),
        changelistGroupRemovedAfterClear: !groupAfterClear,
        setTargetedReconcile:
          setCoverage.targets[0].path === resource.path &&
          setCoverage.targets[0].reason === "operationChangelistSet",
        clearTargetedReconcile:
          clearCoverage.targets[0].path === resource.path &&
          clearCoverage.targets[0].reason === "operationChangelistClear",
        repositoryClosedAfterEvidence: closeReport.repositoryClosed === true
      }
    };
  } catch (error) {
    if (openReport && !closeReport) {
      try {
        await closeOpenReport(openReport);
      } catch (closeError) {
        const combined = new Error(`Installed Changelist set/clear workflow failed at ${error.message}; cleanup close also failed: ${serializeError(closeError).message}`);
        combined.primaryError = serializeError(error);
        combined.cleanupError = serializeError(closeError);
        throw combined;
      }
    }
    throw error;
  }
}

async function runCommitChangelistWorkflow(commitChangelistWorkingCopyRoot) {
  let openReport;
  let closeReport;
  const changelist = "review";
  const groupId = changelistGroupId(changelist);
  try {
    openReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: commitChangelistWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/commitChangelist",
      60000
    );
    if (!openReport || openReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected installed Commit Changelist open report kind: ${openReport && openReport.kind}`);
    }
    const group = findGroup(openReport, groupId);
    const selected = findResource(openReport, groupId, "src/tracked.txt", "subversionr.changedFile.baseDiffable.changelisted");
    const unselected = findResource(openReport, "changes", "load/modified-001.txt", "subversionr.changedFile.baseDiffable");
    if (!group || !selected || selected.kind !== "file" || typeof selected.generation !== "number") {
      throw new Error("Installed Commit Changelist workflow could not find the review changelist group resource.");
    }
    if (!unselected || unselected.kind !== "file") {
      throw new Error("Installed Commit Changelist workflow could not find the unselected non-changelist modified resource.");
    }

    const commitMessage = "commit selected SVN changelist from the repository input message";
    const setInputReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eSetInputMessage", {
        repositoryId: openReport.repository.repositoryId,
        message: commitMessage
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eSetInputMessage/commitChangelist",
      30000
    );
    if (
      !setInputReport ||
      setInputReport.kind !== "subversionr.installedSourceControlUiE2eSetInputMessageReport" ||
      setInputReport.repositoryId !== openReport.repository.repositoryId ||
      setInputReport.previousMessageLength !== 0 ||
      setInputReport.messageLength !== commitMessage.length ||
      setInputReport.inputMessageSet !== true
    ) {
      throw new Error("Installed Commit Changelist workflow did not set the repository SourceControl input message.");
    }

    await withTimeout(
      vscode.commands.executeCommand("subversionr.commitChangelist", changelistGroupCommandArgument(openReport, changelist)),
      "subversionr.commitChangelist",
      60000
    );

    const postCommitFreshnessReport = await collectFreshnessReportWithSurfaceRetry(
      {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        scenario: "partial"
      },
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/commitChangelist",
      30000
    );
    const selectedAfter = findAnyResource(postCommitFreshnessReport, selected.path);
    const unselectedAfter = findResource(postCommitFreshnessReport, "changes", unselected.path, unselected.contextValue);
    const coverageReport = validateLastCompletedRefreshCoverage(postCommitFreshnessReport, openReport, {
      path: selected.path,
      depth: "empty",
      reason: "operationCommit"
    });

    const inputProbeAfterCommit = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eSetInputMessage", {
        repositoryId: openReport.repository.repositoryId,
        message: "post-commit-changelist input clear probe"
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eSetInputMessage/postCommitChangelistProbe",
      30000
    );

    closeReport = await closeOpenReport(openReport);
    if (!closeReport || closeReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || closeReport.repositoryClosed !== true) {
      throw new Error("Installed Commit Changelist workflow did not close the commit-changelist repository.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eCommitChangelistWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.commitChangelist",
        changelist,
        argument: changelistGroupCommandArgument(openReport, changelist)
      },
      repository: {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        workingCopyRoot: openReport.repository.identity.workingCopyRoot
      },
      input: {
        messageLength: commitMessage.length,
        setInputReport,
        postCommitProbePreviousMessageLength: inputProbeAfterCommit.previousMessageLength
      },
      targets: {
        selectedChangelistPaths: [selected.path],
        unselectedChangedPaths: [unselected.path]
      },
      postCommitFreshnessReport,
      closeReport,
      assertions: {
        commandExecuted: true,
        commitUsedChangelistFilter: true,
        inputMessageWasSet: setInputReport.inputMessageSet === true,
        inputMessageClearedAfterCommit: inputProbeAfterCommit.previousMessageLength === 0,
        changelistProjectionClearedCommittedPath: !selectedAfter,
        unselectedNonChangelistPathStillModified: Boolean(unselectedAfter),
        targetedReconcileAfterCommit:
          coverageReport.targets[0].path === selected.path &&
          coverageReport.targets[0].reason === "operationCommit" &&
          coverageReport.coverage[0].path === selected.path,
        repositoryClosedAfterEvidence: closeReport.repositoryClosed === true
      }
    };
  } catch (error) {
    if (openReport && !closeReport) {
      try {
        await closeOpenReport(openReport);
      } catch (closeError) {
        const combined = new Error(`Installed Commit Changelist workflow failed at ${error.message}; cleanup close also failed: ${serializeError(closeError).message}`);
        combined.primaryError = serializeError(error);
        combined.cleanupError = serializeError(closeError);
        throw combined;
      }
    }
    throw error;
  }
}

async function runRevertChangelistWorkflow(revertChangelistWorkingCopyRoot, revertChangelistPromptReadyPath) {
  let openReport;
  let closeReport;
  const changelist = "review";
  const groupId = changelistGroupId(changelist);
  try {
    openReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: revertChangelistWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/revertChangelist",
      60000
    );
    if (!openReport || openReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected installed Revert Changelist open report kind: ${openReport && openReport.kind}`);
    }
    const group = findGroup(openReport, groupId);
    const selected = findResource(openReport, groupId, "src/tracked.txt", "subversionr.changedFile.baseDiffable.changelisted");
    if (!group || !selected || selected.kind !== "file" || typeof selected.generation !== "number") {
      throw new Error("Installed Revert Changelist workflow could not find the review changelist group resource.");
    }
    const fsPath = resourceFsPath(revertChangelistWorkingCopyRoot, selected.path);
    const contentBefore = fs.readFileSync(fsPath, "utf8");
    if (contentBefore === "initial\n") {
      throw new Error("Installed Revert Changelist fixture was already at repository baseline before revert.");
    }

    const promptExpectations = revertPromptCaptureExpectations(selected.path);
    const notificationCleanup = await clearWorkbenchNotificationsBeforePrompt("revertChangelist");
    const commandPromise = withTimeout(
      vscode.commands.executeCommand("subversionr.revertChangelist", changelistGroupCommandArgument(openReport, changelist)),
      "subversionr.revertChangelist",
      60000
    );
    const notificationList = await showWorkbenchNotificationsForPrompt("revertChangelist");
    fs.writeFileSync(revertChangelistPromptReadyPath, JSON.stringify({
      ok: true,
      phase: "revertChangelistPromptReady",
      command: "subversionr.revertChangelist",
      changelist,
      resource: {
        path: selected.path,
        contextValue: selected.contextValue,
        kind: selected.kind,
        generation: selected.generation
      },
      prompt: {
        clickButtonText: "Revert",
        rendererCaptureExpectations: promptExpectations
      },
      notificationCleanup,
      notificationList,
      rendererCaptureExpectations: promptExpectations
    }, null, 2));
    await commandPromise;

    const postRevertFreshnessReport = await collectFreshnessReportWithSurfaceRetry(
      {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        scenario: "partial"
      },
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/revertChangelist",
      30000
    );
    const selectedAfter = findAnyResource(postRevertFreshnessReport, selected.path);
    const coverageReport = validateLastCompletedRefreshCoverage(postRevertFreshnessReport, openReport, {
      path: selected.path,
      depth: "empty",
      reason: "operationRevert"
    });
    const contentAfter = fs.readFileSync(fsPath, "utf8");

    closeReport = await closeOpenReport(openReport);
    if (!closeReport || closeReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || closeReport.repositoryClosed !== true) {
      throw new Error("Installed Revert Changelist workflow did not close the revert-changelist repository.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eRevertChangelistWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.revertChangelist",
        changelist,
        argument: changelistGroupCommandArgument(openReport, changelist)
      },
      repository: {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        workingCopyRoot: openReport.repository.identity.workingCopyRoot
      },
      resource: {
        path: selected.path,
        contextValue: selected.contextValue,
        kind: selected.kind,
        generation: selected.generation
      },
      prompt: {
        clickButtonText: "Revert",
        rendererCaptureExpectations: promptExpectations
      },
      notificationCleanup,
      notificationList,
      postRevertFreshnessReport,
      closeReport,
      assertions: {
        commandExecuted: true,
        revertUsedChangelistFilter: true,
        workingCopyContentRestored: contentAfter === "initial\n",
        changelistProjectionClearedRevertedPath: !selectedAfter,
        targetedReconcileAfterRevert:
          coverageReport.targets[0].path === selected.path &&
          coverageReport.targets[0].reason === "operationRevert" &&
          coverageReport.coverage[0].path === selected.path,
        repositoryClosedAfterEvidence: closeReport.repositoryClosed === true
      }
    };
  } catch (error) {
    if (openReport && !closeReport) {
      try {
        await closeOpenReport(openReport);
      } catch (closeError) {
        const combined = new Error(`Installed Revert Changelist workflow failed at ${error.message}; cleanup close also failed: ${serializeError(closeError).message}`);
        combined.primaryError = serializeError(error);
        combined.cleanupError = serializeError(closeError);
        throw combined;
      }
    }
    throw error;
  }
}

async function runAddWorkflow(addWorkingCopyRoot) {
  let addOpenReport;
  try {
    addOpenReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: addWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/add",
      60000
    );
    if (!addOpenReport || addOpenReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected installed Source Control UI E2E add open report kind: ${addOpenReport && addOpenReport.kind}`);
    }
    const resource = findResource(addOpenReport, "unversioned", "scratch.txt", "subversionr.unversioned");
    if (!resource || resource.kind !== "file" || typeof resource.generation !== "number") {
      throw new Error("Installed Add workflow could not find the unversioned scratch.txt resource.");
    }

    const fsPath = resourceFsPath(addWorkingCopyRoot, resource.path);
    const fileExistedBefore = fs.existsSync(fsPath);
    if (!fileExistedBefore) {
      throw new Error(`Installed Add workflow fixture file was missing before add: ${fsPath}`);
    }

    const commandArgument = resourceStateArgument(addWorkingCopyRoot, resource);
    await withTimeout(
      vscode.commands.executeCommand("subversionr.addResource", commandArgument),
      "subversionr.addResource",
      60000
    );
    const fileExistsAfter = fs.existsSync(fsPath);
    if (!fileExistsAfter) {
      throw new Error("Installed Add workflow removed the fixture file from disk.");
    }

    const postAddFreshnessReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport", {
        repositoryId: addOpenReport.repository.repositoryId,
        epoch: addOpenReport.repository.epoch,
        scenario: "partial"
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/add",
      30000
    );
    if (!postAddFreshnessReport || postAddFreshnessReport.kind !== "subversionr.installedSourceControlUiE2eFreshnessReport") {
      throw new Error(`Unexpected installed Source Control UI E2E add freshness report kind: ${postAddFreshnessReport && postAddFreshnessReport.kind}`);
    }
    const postAddResource = findResource(postAddFreshnessReport, "changes", resource.path, "subversionr.changedFile");
    if (!postAddResource || postAddResource.kind !== "file") {
      throw new Error("Installed Add workflow did not project scratch.txt as a local changed file after add.");
    }
    if (findResource(postAddFreshnessReport, "unversioned", resource.path, "subversionr.unversioned")) {
      throw new Error("Installed Add workflow still exposed scratch.txt as unversioned after add.");
    }

    const addCloseReport = await closeOpenReport(addOpenReport);
    if (!addCloseReport || addCloseReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || addCloseReport.repositoryClosed !== true) {
      throw new Error("Installed Add workflow did not close the add repository.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eAddWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.addResource"
      },
      repository: {
        repositoryId: addOpenReport.repository.repositoryId,
        epoch: addOpenReport.repository.epoch,
        workingCopyRoot: addOpenReport.repository.identity.workingCopyRoot
      },
      resource: {
        path: resource.path,
        contextValue: resource.contextValue,
        kind: resource.kind,
        generation: resource.generation
      },
      postAddResource: {
        path: postAddResource.path,
        contextValue: postAddResource.contextValue,
        kind: postAddResource.kind,
        generation: postAddResource.generation
      },
      postAddFreshnessReport,
      closeReport: addCloseReport,
      assertions: {
        commandExecuted: true,
        fileExistedBefore,
        fileExistsAfter,
        sourceControlProjectionRefreshed: postAddResource.contextValue === "subversionr.changedFile"
      }
    };
  } catch (error) {
    if (addOpenReport) {
      try {
        await closeOpenReport(addOpenReport);
      } catch {
      }
    }
    throw error;
  }
}

async function runMoveWorkflow(moveWorkingCopyRoot, movePromptReadyPath) {
  let moveOpenReport;
  try {
    moveOpenReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: moveWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/moveResource",
      60000
    );
    if (!moveOpenReport || moveOpenReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected installed Source Control UI E2E move open report kind: ${moveOpenReport && moveOpenReport.kind}`);
    }
    const resource = findResource(moveOpenReport, "changes", "src/tracked.txt", "subversionr.changedFile.baseDiffable");
    if (!resource || resource.kind !== "file" || typeof resource.generation !== "number") {
      throw new Error("Installed Move workflow could not find the modified src/tracked.txt resource.");
    }

    const destinationPath = "src/moved.txt";
    const sourceFsPath = resourceFsPath(moveWorkingCopyRoot, resource.path);
    const destinationFsPath = resourceFsPath(moveWorkingCopyRoot, destinationPath);
    const sourceFileExistedBefore = fs.existsSync(sourceFsPath);
    if (!sourceFileExistedBefore) {
      throw new Error(`Installed Move workflow source file was missing before move: ${sourceFsPath}`);
    }
    if (fs.existsSync(destinationFsPath)) {
      throw new Error(`Installed Move workflow destination file existed before move: ${destinationFsPath}`);
    }

    const promptExpectations = movePromptCaptureExpectations(resource.path, destinationPath);
    const commandArgument = resourceStateArgument(moveWorkingCopyRoot, resource);
    const moveCommand = withTimeout(
      vscode.commands.executeCommand("subversionr.moveResource", commandArgument),
      "subversionr.moveResource",
      60000
    );
    fs.writeFileSync(movePromptReadyPath, JSON.stringify({
      ok: true,
      phase: "movePromptReady",
      command: "subversionr.moveResource",
      resource: {
        path: resource.path,
        contextValue: resource.contextValue,
        kind: resource.kind,
        generation: resource.generation
      },
      destinationPath,
      rendererCaptureExpectations: promptExpectations
    }, null, 2));
    await moveCommand;

    const sourceFileExistsAfter = fs.existsSync(sourceFsPath);
    const destinationFileExistsAfter = fs.existsSync(destinationFsPath);
    if (sourceFileExistsAfter) {
      throw new Error("Installed Move workflow left the source file on disk after move.");
    }
    if (!destinationFileExistsAfter) {
      throw new Error("Installed Move workflow did not create the destination file after move.");
    }

    const postMoveFreshnessReport = await collectFreshnessReportWithSurfaceRetry(
      {
        repositoryId: moveOpenReport.repository.repositoryId,
        epoch: moveOpenReport.repository.epoch,
        scenario: "partial"
      },
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/moveResource",
      30000
    );
    if (!postMoveFreshnessReport || postMoveFreshnessReport.kind !== "subversionr.installedSourceControlUiE2eFreshnessReport") {
      throw new Error(`Unexpected installed Source Control UI E2E move freshness report kind: ${postMoveFreshnessReport && postMoveFreshnessReport.kind}`);
    }
    const postMoveSourceResource = findResource(postMoveFreshnessReport, "changes", resource.path, "subversionr.changedFile");
    if (!postMoveSourceResource || postMoveSourceResource.kind !== "file") {
      throw new Error(`Installed Move workflow did not project src/tracked.txt as a scheduled source deletion after move. SourceControl resources: ${sourceControlResourceSummary(postMoveFreshnessReport)}`);
    }
    const postMoveDestinationResource = findResource(postMoveFreshnessReport, "changes", destinationPath, "subversionr.changedFile");
    if (!postMoveDestinationResource || postMoveDestinationResource.kind !== "file") {
      throw new Error(`Installed Move workflow did not project src/moved.txt as a scheduled destination addition after move. SourceControl resources: ${sourceControlResourceSummary(postMoveFreshnessReport)}`);
    }

    const moveCloseReport = await closeOpenReport(moveOpenReport);
    if (!moveCloseReport || moveCloseReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || moveCloseReport.repositoryClosed !== true) {
      throw new Error("Installed Move workflow did not close the move repository.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eMoveWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.moveResource"
      },
      repository: {
        repositoryId: moveOpenReport.repository.repositoryId,
        epoch: moveOpenReport.repository.epoch,
        workingCopyRoot: moveOpenReport.repository.identity.workingCopyRoot
      },
      resource: {
        path: resource.path,
        contextValue: resource.contextValue,
        kind: resource.kind,
        generation: resource.generation
      },
      request: {
        sourcePath: resource.path,
        destinationPath,
        makeParents: false
      },
      postMoveSourceResource: {
        path: postMoveSourceResource.path,
        contextValue: postMoveSourceResource.contextValue,
        kind: postMoveSourceResource.kind,
        generation: postMoveSourceResource.generation
      },
      postMoveDestinationResource: {
        path: postMoveDestinationResource.path,
        contextValue: postMoveDestinationResource.contextValue,
        kind: postMoveDestinationResource.kind,
        generation: postMoveDestinationResource.generation
      },
      prompt: {
        inputText: destinationPath,
        submitKey: "Enter",
        rendererCaptureExpectations: promptExpectations
      },
      postMoveFreshnessReport,
      closeReport: moveCloseReport,
      assertions: {
        commandExecuted: true,
        sourceFileExistedBefore,
        sourceFileExistsAfter,
        destinationFileExistsAfter,
        sourceControlProjectionRefreshed: Boolean(postMoveSourceResource && postMoveDestinationResource)
      }
    };
  } catch (error) {
    if (moveOpenReport) {
      try {
        await closeOpenReport(moveOpenReport);
      } catch {
      }
    }
    throw error;
  }
}

async function runMoveCancellationWorkflow(moveCancellationWorkingCopyRoot, moveCancellationPromptReadyPath) {
  let moveCancellationOpenReport;
  try {
    moveCancellationOpenReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: moveCancellationWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/moveResourceCancellation",
      60000
    );
    if (!moveCancellationOpenReport || moveCancellationOpenReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected installed Source Control UI E2E move cancellation open report kind: ${moveCancellationOpenReport && moveCancellationOpenReport.kind}`);
    }
    const resource = findResource(moveCancellationOpenReport, "changes", "src/tracked.txt", "subversionr.changedFile.baseDiffable");
    if (!resource || resource.kind !== "file" || typeof resource.generation !== "number") {
      throw new Error("Installed Move cancellation workflow could not find the modified src/tracked.txt resource.");
    }

    const destinationPath = "src/cancelled.txt";
    const sourceFsPath = resourceFsPath(moveCancellationWorkingCopyRoot, resource.path);
    const destinationFsPath = resourceFsPath(moveCancellationWorkingCopyRoot, destinationPath);
    const sourceFileExistedBefore = fs.existsSync(sourceFsPath);
    if (!sourceFileExistedBefore) {
      throw new Error(`Installed Move cancellation workflow source file was missing before cancellation: ${sourceFsPath}`);
    }
    if (fs.existsSync(destinationFsPath)) {
      throw new Error(`Installed Move cancellation workflow destination file existed before cancellation: ${destinationFsPath}`);
    }

    const promptExpectations = moveCancellationPromptCaptureExpectations(resource.path);
    const commandArgument = resourceStateArgument(moveCancellationWorkingCopyRoot, resource);
    const moveCommand = withTimeout(
      vscode.commands.executeCommand("subversionr.moveResource", commandArgument),
      "subversionr.moveResource/cancelled",
      60000
    );
    fs.writeFileSync(moveCancellationPromptReadyPath, JSON.stringify({
      ok: true,
      phase: "moveCancellationPromptReady",
      command: "subversionr.moveResource",
      resource: {
        path: resource.path,
        contextValue: resource.contextValue,
        kind: resource.kind,
        generation: resource.generation
      },
      cancelKey: "Escape",
      rendererCaptureExpectations: promptExpectations
    }, null, 2));
    await moveCommand;

    const sourceFileExistsAfter = fs.existsSync(sourceFsPath);
    const destinationFileExistsAfter = fs.existsSync(destinationFsPath);
    if (!sourceFileExistsAfter) {
      throw new Error("Installed Move cancellation workflow removed the source file after cancellation.");
    }
    if (destinationFileExistsAfter) {
      throw new Error("Installed Move cancellation workflow created a destination file after cancellation.");
    }

    const postCancelFreshnessReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport", {
        repositoryId: moveCancellationOpenReport.repository.repositoryId,
        epoch: moveCancellationOpenReport.repository.epoch,
        scenario: "partial"
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/moveResourceCancellation",
      30000
    );
    if (!postCancelFreshnessReport || postCancelFreshnessReport.kind !== "subversionr.installedSourceControlUiE2eFreshnessReport") {
      throw new Error(`Unexpected installed Source Control UI E2E move cancellation freshness report kind: ${postCancelFreshnessReport && postCancelFreshnessReport.kind}`);
    }
    const postCancelSourceResource = findResource(postCancelFreshnessReport, "changes", resource.path, "subversionr.changedFile.baseDiffable");
    if (!postCancelSourceResource || postCancelSourceResource.kind !== "file") {
      throw new Error("Installed Move cancellation workflow did not preserve src/tracked.txt as the changed source resource.");
    }
    const postCancelDestinationResource = findAnyResource(postCancelFreshnessReport, destinationPath);
    if (postCancelDestinationResource) {
      throw new Error("Installed Move cancellation workflow projected a destination resource after cancellation.");
    }

    const moveCancellationCloseReport = await closeOpenReport(moveCancellationOpenReport);
    if (!moveCancellationCloseReport || moveCancellationCloseReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || moveCancellationCloseReport.repositoryClosed !== true) {
      throw new Error("Installed Move cancellation workflow did not close the move cancellation repository.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eMoveCancellationWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.moveResource"
      },
      repository: {
        repositoryId: moveCancellationOpenReport.repository.repositoryId,
        epoch: moveCancellationOpenReport.repository.epoch,
        workingCopyRoot: moveCancellationOpenReport.repository.identity.workingCopyRoot
      },
      resource: {
        path: resource.path,
        contextValue: resource.contextValue,
        kind: resource.kind,
        generation: resource.generation
      },
      request: {
        sourcePath: resource.path,
        destinationPath,
        makeParents: false
      },
      postCancelSourceResource: {
        path: postCancelSourceResource.path,
        contextValue: postCancelSourceResource.contextValue,
        kind: postCancelSourceResource.kind,
        generation: postCancelSourceResource.generation
      },
      postCancelDestinationResourcePresent: Boolean(postCancelDestinationResource),
      prompt: {
        cancelKey: "Escape",
        rendererCaptureExpectations: promptExpectations
      },
      postCancelFreshnessReport,
      closeReport: moveCancellationCloseReport,
      assertions: {
        commandCancelled: true,
        sourceFileExistedBefore,
        sourceFileExistsAfter,
        destinationFileExistsAfter,
        sourceControlProjectionUnchanged: postCancelSourceResource.contextValue === resource.contextValue && !postCancelDestinationResource
      }
    };
  } catch (error) {
    if (moveCancellationOpenReport) {
      try {
        await closeOpenReport(moveCancellationOpenReport);
      } catch {
      }
    }
    throw error;
  }
}

async function runRemoveWorkflow(removeWorkingCopyRoot, removePromptReadyPath) {
  let removeOpenReport;
  try {
    removeOpenReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: removeWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/remove",
      60000
    );
    if (!removeOpenReport || removeOpenReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected installed Source Control UI E2E remove open report kind: ${removeOpenReport && removeOpenReport.kind}`);
    }
    const resource = findResource(removeOpenReport, "changes", "src/tracked.txt", "subversionr.changedFile");
    if (!resource || resource.kind !== "file" || typeof resource.generation !== "number") {
      throw new Error("Installed Remove workflow could not find the missing src/tracked.txt resource.");
    }

    const fsPath = resourceFsPath(removeWorkingCopyRoot, resource.path);
    const fileExistedBefore = fs.existsSync(fsPath);
    if (fileExistedBefore) {
      throw new Error(`Installed Remove workflow fixture file must be missing before remove: ${fsPath}`);
    }

    const promptExpectations = removePromptCaptureExpectations(resource.path);
    const commandArgument = resourceStateArgument(removeWorkingCopyRoot, resource);
    const notificationCleanup = await clearWorkbenchNotificationsBeforePrompt("removeResource");
    const removeCommand = withTimeout(
      vscode.commands.executeCommand("subversionr.removeResource", commandArgument),
      "subversionr.removeResource",
      60000
    );
    const notificationList = await showWorkbenchNotificationsForPrompt("removeResource");
    fs.writeFileSync(removePromptReadyPath, JSON.stringify({
      ok: true,
      phase: "removePromptReady",
      command: "subversionr.removeResource",
      resource: {
        path: resource.path,
        contextValue: resource.contextValue,
        kind: resource.kind,
        generation: resource.generation
      },
      notificationCleanup,
      notificationList,
      rendererCaptureExpectations: promptExpectations
    }, null, 2));
    await removeCommand;

    const fileExistsAfter = fs.existsSync(fsPath);
    if (fileExistsAfter) {
      throw new Error("Installed Remove workflow unexpectedly recreated the missing fixture file.");
    }

    const postRemoveFreshnessReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport", {
        repositoryId: removeOpenReport.repository.repositoryId,
        epoch: removeOpenReport.repository.epoch,
        scenario: "partial"
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/remove",
      30000
    );
    if (!postRemoveFreshnessReport || postRemoveFreshnessReport.kind !== "subversionr.installedSourceControlUiE2eFreshnessReport") {
      throw new Error(`Unexpected installed Source Control UI E2E remove freshness report kind: ${postRemoveFreshnessReport && postRemoveFreshnessReport.kind}`);
    }
    const postRemoveResource = findResource(postRemoveFreshnessReport, "changes", resource.path, "subversionr.changedFile");
    if (!postRemoveResource || postRemoveResource.kind !== "file") {
      throw new Error("Installed Remove workflow did not project src/tracked.txt as a scheduled local deletion after remove.");
    }

    const removeCloseReport = await closeOpenReport(removeOpenReport);
    if (!removeCloseReport || removeCloseReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || removeCloseReport.repositoryClosed !== true) {
      throw new Error("Installed Remove workflow did not close the remove repository.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eRemoveWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.removeResource"
      },
      repository: {
        repositoryId: removeOpenReport.repository.repositoryId,
        epoch: removeOpenReport.repository.epoch,
        workingCopyRoot: removeOpenReport.repository.identity.workingCopyRoot
      },
      resource: {
        path: resource.path,
        contextValue: resource.contextValue,
        kind: resource.kind,
        generation: resource.generation
      },
      postRemoveResource: {
        path: postRemoveResource.path,
        contextValue: postRemoveResource.contextValue,
        kind: postRemoveResource.kind,
        generation: postRemoveResource.generation
      },
      prompt: {
        confirmationButton: "Remove",
        rendererCaptureExpectations: promptExpectations
      },
      notificationCleanup,
      notificationList,
      postRemoveFreshnessReport,
      closeReport: removeCloseReport,
      assertions: {
        commandExecuted: true,
        fileExistedBefore,
        fileExistsAfter,
        sourceControlProjectionRefreshed: postRemoveResource.contextValue === "subversionr.changedFile"
      }
    };
  } catch (error) {
    if (removeOpenReport) {
      try {
        await closeOpenReport(removeOpenReport);
      } catch {
      }
    }
    throw error;
  }
}

async function runRemoveCancellationWorkflow(removeCancellationWorkingCopyRoot, removeCancellationPromptReadyPath, removeCancellationPromptDonePath) {
  let removeCancellationOpenReport;
  try {
    removeCancellationOpenReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: removeCancellationWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/removeCancellation",
      60000
    );
    if (!removeCancellationOpenReport || removeCancellationOpenReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected installed Source Control UI E2E remove cancellation open report kind: ${removeCancellationOpenReport && removeCancellationOpenReport.kind}`);
    }
    const resource = findResource(removeCancellationOpenReport, "changes", "src/tracked.txt", "subversionr.changedFile.baseDiffable");
    if (!resource || resource.kind !== "file" || typeof resource.generation !== "number") {
      throw new Error("Installed Remove cancellation workflow could not find the modified src/tracked.txt resource.");
    }

    const fsPath = resourceFsPath(removeCancellationWorkingCopyRoot, resource.path);
    const fileExistedBefore = fs.existsSync(fsPath);
    if (!fileExistedBefore) {
      throw new Error(`Installed Remove cancellation workflow fixture file was missing before cancellation: ${fsPath}`);
    }

    const promptExpectations = removeCancellationPromptCaptureExpectations(resource.path);
    const commandArgument = resourceStateArgument(removeCancellationWorkingCopyRoot, resource);
    const removeCommand = withTimeout(
      vscode.commands.executeCommand("subversionr.removeResource", commandArgument),
      "subversionr.removeResource/cancelled",
      60000
    );
    fs.writeFileSync(removeCancellationPromptReadyPath, JSON.stringify({
      ok: true,
      phase: "removeCancellationPromptReady",
      command: "subversionr.removeResource",
      resource: {
        path: resource.path,
        contextValue: resource.contextValue,
        kind: resource.kind,
        generation: resource.generation
      },
      cancelAction: "notifications.clearAll",
      rendererCaptureExpectations: promptExpectations
    }, null, 2));
    await waitForFile(removeCancellationPromptDonePath, 120000);
    const notificationCleanup = await clearWorkbenchNotificationsBeforePrompt("removeCancellation");
    await removeCommand;

    const fileExistsAfter = fs.existsSync(fsPath);
    if (!fileExistsAfter) {
      throw new Error("Installed Remove cancellation workflow removed the fixture file after cancellation.");
    }
    const fileContentAfter = fs.readFileSync(fsPath, "utf8");
    if (fileContentAfter !== "modified by M7j3\n") {
      throw new Error(`Installed Remove cancellation workflow changed the fixture file content; got ${JSON.stringify(fileContentAfter)}.`);
    }

    const postCancelFreshnessReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport", {
        repositoryId: removeCancellationOpenReport.repository.repositoryId,
        epoch: removeCancellationOpenReport.repository.epoch,
        scenario: "partial"
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/removeCancellation",
      30000
    );
    if (!postCancelFreshnessReport || postCancelFreshnessReport.kind !== "subversionr.installedSourceControlUiE2eFreshnessReport") {
      throw new Error(`Unexpected installed Source Control UI E2E remove cancellation freshness report kind: ${postCancelFreshnessReport && postCancelFreshnessReport.kind}`);
    }
    const postCancelResource = findResource(postCancelFreshnessReport, "changes", resource.path, "subversionr.changedFile.baseDiffable");
    if (!postCancelResource || postCancelResource.kind !== "file") {
      throw new Error("Installed Remove cancellation workflow did not preserve src/tracked.txt as a changed SourceControl resource.");
    }
    const sourceControlProjectionUnchanged = sourceControlProjectionMatches(
      postCancelFreshnessReport,
      removeCancellationOpenReport
    );
    if (!sourceControlProjectionUnchanged) {
      throw new Error(`Installed Remove cancellation workflow changed the Source Control projection after cancellation: ${sourceControlResourceSummary(postCancelFreshnessReport)}`);
    }

    const removeCancellationCloseReport = await closeOpenReport(removeCancellationOpenReport);
    if (!removeCancellationCloseReport || removeCancellationCloseReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || removeCancellationCloseReport.repositoryClosed !== true) {
      throw new Error("Installed Remove cancellation workflow did not close the remove cancellation repository.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eRemoveCancellationWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.removeResource"
      },
      repository: {
        repositoryId: removeCancellationOpenReport.repository.repositoryId,
        epoch: removeCancellationOpenReport.repository.epoch,
        workingCopyRoot: removeCancellationOpenReport.repository.identity.workingCopyRoot
      },
      resource: {
        path: resource.path,
        contextValue: resource.contextValue,
        kind: resource.kind,
        generation: resource.generation
      },
      postCancelResource: {
        path: postCancelResource.path,
        contextValue: postCancelResource.contextValue,
        kind: postCancelResource.kind,
        generation: postCancelResource.generation
      },
      prompt: {
        cancelAction: "notifications.clearAll",
        rendererCaptureExpectations: promptExpectations
      },
      notificationCleanup,
      postCancelFreshnessReport,
      closeReport: removeCancellationCloseReport,
      assertions: {
        commandCancelled: true,
        fileExistedBefore,
        fileExistsAfter,
        fileContentAfter,
        sourceControlProjectionUnchanged
      }
    };
  } catch (error) {
    if (removeCancellationOpenReport) {
      try {
        await closeOpenReport(removeCancellationOpenReport);
      } catch {
      }
    }
    throw error;
  }
}

async function runResolveWorkflow(resolveWorkingCopyRoot, resolvePromptReadyPath) {
  let resolveOpenReport;
  try {
    resolveOpenReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: resolveWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/resolve",
      60000
    );
    if (!resolveOpenReport || resolveOpenReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected installed Source Control UI E2E resolve open report kind: ${resolveOpenReport && resolveOpenReport.kind}`);
    }
    if (path.resolve(resolveOpenReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(resolveWorkingCopyRoot).toLowerCase()) {
      throw new Error("Installed Resolve workflow workingCopyRoot did not match the resolve fixture.");
    }
    const resource = findResource(resolveOpenReport, "conflicts", "src/tracked.txt", "subversionr.conflicted");
    if (!resource || resource.kind !== "file" || typeof resource.generation !== "number") {
      throw new Error("Installed Resolve workflow could not find the conflicted src/tracked.txt resource.");
    }

    const fsPath = resourceFsPath(resolveWorkingCopyRoot, resource.path);
    const fileExistedBefore = fs.existsSync(fsPath);
    if (!fileExistedBefore) {
      throw new Error(`Installed Resolve workflow fixture file was missing before resolve: ${fsPath}`);
    }
    const fileContentBefore = fs.readFileSync(fsPath, "utf8");

    const promptExpectations = resolvePromptCaptureExpectations(resource.path);
    const commandArgument = resourceStateArgument(resolveWorkingCopyRoot, resource);
    const notificationCleanup = await clearWorkbenchNotificationsBeforePrompt("resolveResource");
    const resolveCommand = withTimeout(
      vscode.commands.executeCommand("subversionr.resolveResource", commandArgument),
      "subversionr.resolveResource",
      60000
    );
    const notificationList = await showWorkbenchNotificationsForPrompt("resolveResource");
    fs.writeFileSync(resolvePromptReadyPath, JSON.stringify({
      ok: true,
      phase: "resolvePromptReady",
      command: "subversionr.resolveResource",
      resource: {
        path: resource.path,
        contextValue: resource.contextValue,
        kind: resource.kind,
        generation: resource.generation
      },
      notificationCleanup,
      notificationList,
      rendererCaptureExpectations: promptExpectations
    }, null, 2));
    await resolveCommand;

    const fileContentAfter = fs.readFileSync(fsPath, "utf8");
    const postResolveFreshnessReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport", {
        repositoryId: resolveOpenReport.repository.repositoryId,
        epoch: resolveOpenReport.repository.epoch,
        scenario: "partial"
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/resolve",
      30000
    );
    if (!postResolveFreshnessReport || postResolveFreshnessReport.kind !== "subversionr.installedSourceControlUiE2eFreshnessReport") {
      throw new Error(`Unexpected installed Source Control UI E2E resolve freshness report kind: ${postResolveFreshnessReport && postResolveFreshnessReport.kind}`);
    }
    if (!findStatusCommand(postResolveFreshnessReport, "partial", resolveOpenReport.repository.repositoryId)) {
      throw new Error("Installed Resolve workflow did not expose post-resolve partial full reconcile status command.");
    }
    const conflictProjectedAfter = Boolean(findResource(postResolveFreshnessReport, "conflicts", resource.path, "subversionr.conflicted"));
    const postResolveResource = findResource(postResolveFreshnessReport, "changes", resource.path, "subversionr.changedFile.baseDiffable");
    if (conflictProjectedAfter || !postResolveResource || postResolveResource.kind !== "file") {
      throw new Error("Installed Resolve workflow did not clear the conflict and project src/tracked.txt as a changed file after resolve.");
    }

    const resolveCloseReport = await closeOpenReport(resolveOpenReport);
    if (!resolveCloseReport || resolveCloseReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || resolveCloseReport.repositoryClosed !== true) {
      throw new Error("Installed Resolve workflow did not close the resolve repository.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eResolveWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.resolveResource"
      },
      repository: {
        repositoryId: resolveOpenReport.repository.repositoryId,
        epoch: resolveOpenReport.repository.epoch,
        workingCopyRoot: resolveOpenReport.repository.identity.workingCopyRoot
      },
      resource: {
        path: resource.path,
        contextValue: resource.contextValue,
        kind: resource.kind,
        generation: resource.generation
      },
      request: {
        paths: [resource.path],
        depth: "empty",
        choice: "working"
      },
      postResolveResource: {
        path: postResolveResource.path,
        contextValue: postResolveResource.contextValue,
        kind: postResolveResource.kind,
        generation: postResolveResource.generation
      },
      prompt: {
        quickPickItemText: "Working copy",
        rendererCaptureExpectations: promptExpectations
      },
      notificationCleanup,
      notificationList,
      postResolveFreshnessReport,
      closeReport: resolveCloseReport,
      assertions: {
        commandExecuted: true,
        fileExistedBefore,
        conflictProjectedBefore: true,
        conflictProjectedAfter,
        fileContentBefore,
        fileContentAfter,
        fileContentPreservedAfter: fileContentAfter === fileContentBefore,
        sourceControlProjectionRefreshed: postResolveResource.contextValue === "subversionr.changedFile.baseDiffable"
      }
    };
  } catch (error) {
    if (resolveOpenReport) {
      try {
        await closeOpenReport(resolveOpenReport);
      } catch {
      }
    }
    throw error;
  }
}

async function runResolveCancellationWorkflow(resolveCancellationWorkingCopyRoot, resolveCancellationPromptReadyPath) {
  let resolveCancellationOpenReport;
  try {
    resolveCancellationOpenReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: resolveCancellationWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/resolveCancellation",
      60000
    );
    if (!resolveCancellationOpenReport || resolveCancellationOpenReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected installed Source Control UI E2E resolve cancellation open report kind: ${resolveCancellationOpenReport && resolveCancellationOpenReport.kind}`);
    }
    if (path.resolve(resolveCancellationOpenReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(resolveCancellationWorkingCopyRoot).toLowerCase()) {
      throw new Error("Installed Resolve cancellation workflow workingCopyRoot did not match the resolve cancellation fixture.");
    }
    const resource = findResource(resolveCancellationOpenReport, "conflicts", "src/tracked.txt", "subversionr.conflicted");
    if (!resource || resource.kind !== "file" || typeof resource.generation !== "number") {
      throw new Error("Installed Resolve cancellation workflow could not find the conflicted src/tracked.txt resource.");
    }

    const fsPath = resourceFsPath(resolveCancellationWorkingCopyRoot, resource.path);
    const fileExistedBefore = fs.existsSync(fsPath);
    if (!fileExistedBefore) {
      throw new Error(`Installed Resolve cancellation workflow fixture file was missing before cancellation: ${fsPath}`);
    }
    const fileContentBefore = fs.readFileSync(fsPath, "utf8");

    const promptExpectations = resolveCancellationPromptCaptureExpectations(resource.path);
    const commandArgument = resourceStateArgument(resolveCancellationWorkingCopyRoot, resource);
    const notificationCleanup = await clearWorkbenchNotificationsBeforePrompt("resolveResourceCancellation");
    const resolveCommand = withTimeout(
      vscode.commands.executeCommand("subversionr.resolveResource", commandArgument),
      "subversionr.resolveResource/cancelled",
      60000
    );
    fs.writeFileSync(resolveCancellationPromptReadyPath, JSON.stringify({
      ok: true,
      phase: "resolveCancellationPromptReady",
      command: "subversionr.resolveResource",
      resource: {
        path: resource.path,
        contextValue: resource.contextValue,
        kind: resource.kind,
        generation: resource.generation
      },
      notificationCleanup,
      rendererCaptureExpectations: promptExpectations
    }, null, 2));
    await resolveCommand;

    const fileContentAfter = fs.existsSync(fsPath) ? fs.readFileSync(fsPath, "utf8") : undefined;
    if (fileContentAfter !== fileContentBefore) {
      throw new Error(`Installed Resolve cancellation workflow changed the fixture file content; got ${JSON.stringify(fileContentAfter)}.`);
    }

    const postCancelFreshnessReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport", {
        repositoryId: resolveCancellationOpenReport.repository.repositoryId,
        epoch: resolveCancellationOpenReport.repository.epoch,
        scenario: "partial"
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/resolveCancellation",
      30000
    );
    if (!postCancelFreshnessReport || postCancelFreshnessReport.kind !== "subversionr.installedSourceControlUiE2eFreshnessReport") {
      throw new Error(`Unexpected installed Source Control UI E2E resolve cancellation freshness report kind: ${postCancelFreshnessReport && postCancelFreshnessReport.kind}`);
    }
    if (!findStatusCommand(postCancelFreshnessReport, "partial", resolveCancellationOpenReport.repository.repositoryId)) {
      throw new Error("Installed Resolve cancellation workflow did not expose post-cancel partial full reconcile status command.");
    }
    const postCancelResource = findResource(postCancelFreshnessReport, "conflicts", resource.path, "subversionr.conflicted");
    if (!postCancelResource || postCancelResource.kind !== "file") {
      throw new Error("Installed Resolve cancellation workflow did not preserve src/tracked.txt as a conflicted SourceControl resource.");
    }
    const postCancelChangedResource = findResource(postCancelFreshnessReport, "changes", resource.path, "subversionr.changedFile.baseDiffable");
    if (postCancelChangedResource) {
      throw new Error("Installed Resolve cancellation workflow projected src/tracked.txt as changed after cancellation.");
    }

    const resolveCancellationCloseReport = await closeOpenReport(resolveCancellationOpenReport);
    if (!resolveCancellationCloseReport || resolveCancellationCloseReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || resolveCancellationCloseReport.repositoryClosed !== true) {
      throw new Error("Installed Resolve cancellation workflow did not close the resolve cancellation repository.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eResolveCancellationWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.resolveResource"
      },
      repository: {
        repositoryId: resolveCancellationOpenReport.repository.repositoryId,
        epoch: resolveCancellationOpenReport.repository.epoch,
        workingCopyRoot: resolveCancellationOpenReport.repository.identity.workingCopyRoot
      },
      resource: {
        path: resource.path,
        contextValue: resource.contextValue,
        kind: resource.kind,
        generation: resource.generation
      },
      request: {
        paths: [resource.path],
        depth: "empty",
        choice: "working"
      },
      postCancelResource: {
        path: postCancelResource.path,
        contextValue: postCancelResource.contextValue,
        kind: postCancelResource.kind,
        generation: postCancelResource.generation
      },
      prompt: {
        cancelKey: "Escape",
        rendererCaptureExpectations: promptExpectations
      },
      notificationCleanup,
      postCancelFreshnessReport,
      closeReport: resolveCancellationCloseReport,
      assertions: {
        commandCancelled: true,
        fileExistedBefore,
        conflictProjectedBefore: true,
        conflictProjectedAfter: Boolean(postCancelResource),
        fileContentBefore,
        fileContentAfter,
        fileContentPreservedAfter: fileContentAfter === fileContentBefore,
        sourceControlProjectionUnchanged: postCancelResource.contextValue === resource.contextValue && !postCancelChangedResource
      }
    };
  } catch (error) {
    if (resolveCancellationOpenReport) {
      try {
        await closeOpenReport(resolveCancellationOpenReport);
      } catch {
      }
    }
    throw error;
  }
}

async function runRemoveKeepLocalWorkflow(openReport, workingCopyRoot, removeKeepLocalPromptReadyPath) {
  const preRemoveFreshnessReport = await collectFreshnessReportWithSurfaceRetry(
    {
      repositoryId: openReport.repository.repositoryId,
      epoch: openReport.repository.epoch,
      scenario: "partial"
    },
    "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/removeKeepLocalPre",
    30000
  );
  validateFreshnessReport(preRemoveFreshnessReport, "partial", openReport, {
    expectUnversionedScratch: false
  });
  const resource = findResource(preRemoveFreshnessReport, "changes", "src/tracked.txt", "subversionr.changedFile.baseDiffable");
  if (!resource || resource.kind !== "file" || typeof resource.generation !== "number") {
    throw new Error("Installed Keep-local Remove workflow could not find the modified src/tracked.txt resource.");
  }

  const fsPath = resourceFsPath(workingCopyRoot, resource.path);
  const fileExistedBefore = fs.existsSync(fsPath);
  if (!fileExistedBefore) {
    throw new Error(`Installed Keep-local Remove workflow fixture file was missing before removal: ${fsPath}`);
  }

  const promptExpectations = removeKeepLocalPromptCaptureExpectations(resource.path);
  const commandArgument = resourceStateArgument(workingCopyRoot, resource);
  const notificationCleanup = await clearWorkbenchNotificationsBeforePrompt("removeResourceKeepLocal");
  const removeCommand = withTimeout(
    vscode.commands.executeCommand("subversionr.removeResourceKeepLocal", commandArgument),
    "subversionr.removeResourceKeepLocal",
    60000
  );
  const notificationList = await showWorkbenchNotificationsForPrompt("removeResourceKeepLocal");
  fs.writeFileSync(removeKeepLocalPromptReadyPath, JSON.stringify({
    ok: true,
    phase: "removeKeepLocalPromptReady",
    command: "subversionr.removeResourceKeepLocal",
    resource: {
      path: resource.path,
      contextValue: resource.contextValue,
      kind: resource.kind,
      generation: resource.generation
    },
    notificationCleanup,
    notificationList,
    rendererCaptureExpectations: promptExpectations
  }, null, 2));
  await removeCommand;

  const fileExistsAfter = fs.existsSync(fsPath);
  if (!fileExistsAfter) {
    throw new Error(`Installed Keep-local Remove workflow did not keep the local fixture file: ${fsPath}`);
  }

  const postRemoveFreshnessReport = await collectFreshnessReportWithSurfaceRetry(
    {
      repositoryId: openReport.repository.repositoryId,
      epoch: openReport.repository.epoch,
      scenario: "partial"
    },
    "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/removeKeepLocal",
    30000
  );
  validateFreshnessReport(postRemoveFreshnessReport, "partial", openReport, {
    expectUnversionedScratch: false,
    expectedTrackedContextValue: "subversionr.changedFile"
  });
  const postRemoveResource = findResource(postRemoveFreshnessReport, "changes", resource.path, "subversionr.changedFile");

  return {
    kind: "subversionr.installedSourceControlUiE2eRemoveKeepLocalWorkflow",
    generatedAt: new Date().toISOString(),
    command: {
      command: "subversionr.removeResourceKeepLocal"
    },
    resource: {
      path: resource.path,
      contextValue: resource.contextValue,
      kind: resource.kind,
      generation: resource.generation
    },
    postRemoveResource,
    preRemoveFreshnessReport,
    prompt: {
      confirmationButton: "Remove",
      rendererCaptureExpectations: promptExpectations
    },
    notificationCleanup,
    notificationList,
    postRemoveFreshnessReport,
    assertions: {
      commandExecuted: true,
      fileExistedBefore,
      fileExistsAfter,
      sourceControlProjectionRefreshed: Boolean(postRemoveResource)
    }
  };
}

async function runRevertWorkflow(revertWorkingCopyRoot, revertPromptReadyPath) {
  let revertOpenReport;
  try {
    revertOpenReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: revertWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/revert",
      60000
    );
    if (!revertOpenReport || revertOpenReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected installed Source Control UI E2E revert open report kind: ${revertOpenReport && revertOpenReport.kind}`);
    }
    const resource = findResource(revertOpenReport, "changes", "src/tracked.txt", "subversionr.changedFile.baseDiffable");
    if (!resource || resource.kind !== "file" || typeof resource.generation !== "number") {
      throw new Error("Installed Revert workflow could not find the modified src/tracked.txt resource.");
    }

    const fsPath = resourceFsPath(revertWorkingCopyRoot, resource.path);
    const fileExistedBefore = fs.existsSync(fsPath);
    if (!fileExistedBefore) {
      throw new Error(`Installed Revert workflow fixture file was missing before revert: ${fsPath}`);
    }

    const promptExpectations = revertPromptCaptureExpectations(resource.path);
    const commandArgument = resourceStateArgument(revertWorkingCopyRoot, resource);
    const notificationCleanup = await clearWorkbenchNotificationsBeforePrompt("revertResource");
    const revertCommand = withTimeout(
      vscode.commands.executeCommand("subversionr.revertResource", commandArgument),
      "subversionr.revertResource",
      60000
    );
    const notificationList = await showWorkbenchNotificationsForPrompt("revertResource");
    fs.writeFileSync(revertPromptReadyPath, JSON.stringify({
      ok: true,
      phase: "revertPromptReady",
      command: "subversionr.revertResource",
      resource: {
        path: resource.path,
        contextValue: resource.contextValue,
        kind: resource.kind,
        generation: resource.generation
      },
      notificationCleanup,
      notificationList,
      rendererCaptureExpectations: promptExpectations
    }, null, 2));
    await revertCommand;

    const fileContentAfter = fs.existsSync(fsPath) ? fs.readFileSync(fsPath, "utf8") : undefined;
    if (fileContentAfter !== "initial\n") {
      throw new Error(`Installed Revert workflow did not restore the fixture file content; got ${JSON.stringify(fileContentAfter)}.`);
    }

    const postRevertFreshnessReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport", {
        repositoryId: revertOpenReport.repository.repositoryId,
        epoch: revertOpenReport.repository.epoch,
        scenario: "partial"
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/revert",
      30000
    );
    if (!postRevertFreshnessReport || postRevertFreshnessReport.kind !== "subversionr.installedSourceControlUiE2eFreshnessReport") {
      throw new Error(`Unexpected installed Source Control UI E2E revert freshness report kind: ${postRevertFreshnessReport && postRevertFreshnessReport.kind}`);
    }
    if (!findResource(postRevertFreshnessReport, "unversioned", "scratch.txt", "subversionr.unversioned")) {
      throw new Error("Installed Revert workflow did not preserve the fixture unversioned resource projection.");
    }
    const resourcePresentAfter = Boolean(findAnyResource(postRevertFreshnessReport, resource.path));
    if (resourcePresentAfter) {
      throw new Error("Installed Revert workflow still exposed the reverted changed resource in SourceControl.");
    }

    const revertCloseReport = await closeOpenReport(revertOpenReport);
    if (!revertCloseReport || revertCloseReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || revertCloseReport.repositoryClosed !== true) {
      throw new Error("Installed Revert workflow did not close the revert repository.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eRevertWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.revertResource"
      },
      repository: {
        repositoryId: revertOpenReport.repository.repositoryId,
        epoch: revertOpenReport.repository.epoch,
        workingCopyRoot: revertOpenReport.repository.identity.workingCopyRoot
      },
      resource: {
        path: resource.path,
        contextValue: resource.contextValue,
        kind: resource.kind,
        generation: resource.generation
      },
      prompt: {
        confirmationButton: "Revert",
        rendererCaptureExpectations: promptExpectations
      },
      notificationCleanup,
      notificationList,
      postRevertFreshnessReport,
      closeReport: revertCloseReport,
      assertions: {
        commandExecuted: true,
        fileExistedBefore,
        fileContentAfter,
        resourcePresentAfter
      }
    };
  } catch (error) {
    if (revertOpenReport) {
      try {
        await closeOpenReport(revertOpenReport);
      } catch {
      }
    }
    throw error;
  }
}

async function runRevertCancellationWorkflow(revertCancellationWorkingCopyRoot, revertCancellationPromptReadyPath, revertCancellationPromptDonePath) {
  let revertCancellationOpenReport;
  try {
    revertCancellationOpenReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: revertCancellationWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/revertCancellation",
      60000
    );
    if (!revertCancellationOpenReport || revertCancellationOpenReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected installed Source Control UI E2E revert cancellation open report kind: ${revertCancellationOpenReport && revertCancellationOpenReport.kind}`);
    }
    const resource = findResource(revertCancellationOpenReport, "changes", "src/tracked.txt", "subversionr.changedFile.baseDiffable");
    if (!resource || resource.kind !== "file" || typeof resource.generation !== "number") {
      throw new Error("Installed Revert cancellation workflow could not find the modified src/tracked.txt resource.");
    }

    const fsPath = resourceFsPath(revertCancellationWorkingCopyRoot, resource.path);
    const fileExistedBefore = fs.existsSync(fsPath);
    if (!fileExistedBefore) {
      throw new Error(`Installed Revert cancellation workflow fixture file was missing before cancellation: ${fsPath}`);
    }

    const promptExpectations = revertCancellationPromptCaptureExpectations(resource.path);
    const commandArgument = resourceStateArgument(revertCancellationWorkingCopyRoot, resource);
    const revertCommand = withTimeout(
      vscode.commands.executeCommand("subversionr.revertResource", commandArgument),
      "subversionr.revertResource/cancelled",
      60000
    );
    fs.writeFileSync(revertCancellationPromptReadyPath, JSON.stringify({
      ok: true,
      phase: "revertCancellationPromptReady",
      command: "subversionr.revertResource",
      resource: {
        path: resource.path,
        contextValue: resource.contextValue,
        kind: resource.kind,
        generation: resource.generation
      },
      cancelAction: "notifications.clearAll",
      rendererCaptureExpectations: promptExpectations
    }, null, 2));
    await waitForFile(revertCancellationPromptDonePath, 120000);
    const notificationCleanup = await clearWorkbenchNotificationsBeforePrompt("revertCancellation");
    await revertCommand;

    const fileContentAfter = fs.existsSync(fsPath) ? fs.readFileSync(fsPath, "utf8") : undefined;
    if (fileContentAfter !== "modified by M7j3\n") {
      throw new Error(`Installed Revert cancellation workflow changed the fixture file content; got ${JSON.stringify(fileContentAfter)}.`);
    }

    const postCancelFreshnessReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport", {
        repositoryId: revertCancellationOpenReport.repository.repositoryId,
        epoch: revertCancellationOpenReport.repository.epoch,
        scenario: "partial"
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/revertCancellation",
      30000
    );
    if (!postCancelFreshnessReport || postCancelFreshnessReport.kind !== "subversionr.installedSourceControlUiE2eFreshnessReport") {
      throw new Error(`Unexpected installed Source Control UI E2E revert cancellation freshness report kind: ${postCancelFreshnessReport && postCancelFreshnessReport.kind}`);
    }
    const postCancelResource = findResource(postCancelFreshnessReport, "changes", resource.path, "subversionr.changedFile.baseDiffable");
    if (!postCancelResource || postCancelResource.kind !== "file") {
      throw new Error("Installed Revert cancellation workflow did not preserve src/tracked.txt as a changed SourceControl resource.");
    }
    const sourceControlProjectionUnchanged = sourceControlProjectionMatches(
      postCancelFreshnessReport,
      revertCancellationOpenReport
    );
    if (!sourceControlProjectionUnchanged) {
      throw new Error(`Installed Revert cancellation workflow changed the Source Control projection after cancellation: ${sourceControlResourceSummary(postCancelFreshnessReport)}`);
    }

    const revertCancellationCloseReport = await closeOpenReport(revertCancellationOpenReport);
    if (!revertCancellationCloseReport || revertCancellationCloseReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || revertCancellationCloseReport.repositoryClosed !== true) {
      throw new Error("Installed Revert cancellation workflow did not close the revert cancellation repository.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eRevertCancellationWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.revertResource"
      },
      repository: {
        repositoryId: revertCancellationOpenReport.repository.repositoryId,
        epoch: revertCancellationOpenReport.repository.epoch,
        workingCopyRoot: revertCancellationOpenReport.repository.identity.workingCopyRoot
      },
      resource: {
        path: resource.path,
        contextValue: resource.contextValue,
        kind: resource.kind,
        generation: resource.generation
      },
      postCancelResource: {
        path: postCancelResource.path,
        contextValue: postCancelResource.contextValue,
        kind: postCancelResource.kind,
        generation: postCancelResource.generation
      },
      prompt: {
        cancelAction: "notifications.clearAll",
        rendererCaptureExpectations: promptExpectations
      },
      notificationCleanup,
      postCancelFreshnessReport,
      closeReport: revertCancellationCloseReport,
      assertions: {
        commandCancelled: true,
        fileExistedBefore,
        fileContentAfter,
        resourcePresentAfter: Boolean(postCancelResource),
        sourceControlProjectionUnchanged
      }
    };
  } catch (error) {
    if (revertCancellationOpenReport) {
      try {
        await closeOpenReport(revertCancellationOpenReport);
      } catch {
      }
    }
    throw error;
  }
}

async function runCleanupWorkflow(openReport, cleanupPromptReadyPath) {
  const promptExpectations = cleanupPromptCaptureExpectations(openReport.repository.identity.workingCopyRoot);
  const cleanupCommand = withTimeout(
    vscode.commands.executeCommand("subversionr.cleanupRepository", openReport.repository.repositoryId),
    "subversionr.cleanupRepository",
    60000
  );
  fs.writeFileSync(cleanupPromptReadyPath, JSON.stringify({
    ok: true,
    phase: "cleanupPromptReady",
    command: "subversionr.cleanupRepository",
    repositoryId: openReport.repository.repositoryId,
    rendererCaptureExpectations: promptExpectations
  }, null, 2));
  await cleanupCommand;

  const postCleanupFreshnessReport = await withTimeout(
    vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport", {
      repositoryId: openReport.repository.repositoryId,
      epoch: openReport.repository.epoch,
      scenario: "partial"
    }),
    "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/cleanup",
    30000
  );
  validateFreshnessReport(postCleanupFreshnessReport, "partial", openReport, {
    expectUnversionedScratch: false,
    expectedTrackedContextValue: "subversionr.changedFile"
  });
  const cleanupFullReconcileCommand = findStatusCommand(
    postCleanupFreshnessReport,
    "partial",
    openReport.repository.repositoryId
  );

  return {
    kind: "subversionr.installedSourceControlUiE2eCleanupWorkflow",
    generatedAt: new Date().toISOString(),
    command: {
      command: "subversionr.cleanupRepository"
    },
    repository: {
      repositoryId: openReport.repository.repositoryId,
      epoch: openReport.repository.epoch,
      workingCopyRoot: openReport.repository.identity.workingCopyRoot
    },
    request: {
      path: ".",
      breakLocks: true,
      fixRecordedTimestamps: false,
      clearDavCache: false,
      vacuumPristines: false,
      includeExternals: false
    },
    prompt: {
      quickInputSubmitKey: "Enter",
      rendererCaptureExpectations: promptExpectations
    },
    postCleanupFreshnessReport,
    assertions: {
      commandExecuted: true,
      repositoryOpenBefore: openReport.surfaceWorkflow.repositoryOpen === true,
      fullReconcileAfterCleanup: Boolean(cleanupFullReconcileCommand),
      sourceControlSurfaceAfterCleanup: postCleanupFreshnessReport.freshnessWorkflow.sourceControlSurface === true
    }
  };
}

async function runDeleteUnversionedLoadWorkflow(loadWorkingCopyRoot, loadItemCount, deleteLoadPromptReadyPath) {
  let loadOpenReport;
  try {
    loadOpenReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: loadWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/deleteLoad",
      60000
    );
    if (!loadOpenReport || loadOpenReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected installed Source Control UI E2E load open report kind: ${loadOpenReport && loadOpenReport.kind}`);
    }
    if (path.resolve(loadOpenReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(loadWorkingCopyRoot).toLowerCase()) {
      throw new Error("Installed Delete Unversioned load workflow workingCopyRoot did not match the load fixture.");
    }
    const unversionedBefore = requireUnversionedProjectionCount(loadOpenReport, loadItemCount, "Installed Delete Unversioned load workflow");
    const deleteTargetPaths = unversionedBefore.map(resource => resourceFsPath(loadWorkingCopyRoot, resource.path));
    const allFilesExistedBefore = deleteTargetPaths.every(fs.existsSync);
    if (!allFilesExistedBefore) {
      const missing = deleteTargetPaths.filter(fsPath => !fs.existsSync(fsPath));
      throw new Error(`Installed Delete Unversioned load workflow fixture files were missing before deletion: ${missing.join(", ")}`);
    }

    const promptExpectations = deleteAllPromptCaptureExpectations(loadItemCount);
    const notificationCleanup = await clearWorkbenchNotificationsBeforePrompt("deleteAllUnversionedResources");
    const deleteCommand = withTimeout(
      vscode.commands.executeCommand("subversionr.deleteAllUnversionedResources", loadOpenReport.repository.repositoryId),
      "subversionr.deleteAllUnversionedResources",
      60000
    );
    const notificationList = await showWorkbenchNotificationsForPrompt("deleteAllUnversionedResources");
    fs.writeFileSync(deleteLoadPromptReadyPath, JSON.stringify({
      ok: true,
      phase: "deleteUnversionedLoadPromptReady",
      command: "subversionr.deleteAllUnversionedResources",
      repositoryId: loadOpenReport.repository.repositoryId,
      loadItemCount,
      notificationCleanup,
      notificationList,
      rendererCaptureExpectations: promptExpectations
    }, null, 2));
    await deleteCommand;

    const anyFileExistsAfter = deleteTargetPaths.some(fs.existsSync);
    if (anyFileExistsAfter) {
      const remaining = deleteTargetPaths.filter(fs.existsSync);
      throw new Error(`Installed Delete Unversioned load workflow did not delete every fixture file: ${remaining.join(", ")}`);
    }

    const postDeleteFreshnessReport = await collectFreshnessReportUntilUnversionedCount(
      {
        repositoryId: loadOpenReport.repository.repositoryId,
        epoch: loadOpenReport.repository.epoch,
        scenario: "partial"
      },
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/deleteLoad",
      0,
      30000
    );
    validateFreshnessReport(postDeleteFreshnessReport, "partial", loadOpenReport, { expectUnversionedScratch: false });
    const projectedItemCountAfter = unversionedResources(postDeleteFreshnessReport).length;
    if (projectedItemCountAfter !== 0) {
      throw new Error(`Installed Delete Unversioned load workflow left ${projectedItemCountAfter} unversioned resources projected after deletion.`);
    }

    const loadCloseReport = await closeOpenReport(loadOpenReport);
    if (!loadCloseReport || loadCloseReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || loadCloseReport.repositoryClosed !== true) {
      throw new Error("Installed Delete Unversioned load workflow did not close the load repository.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eDeleteUnversionedLoadWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.deleteAllUnversionedResources"
      },
      repository: {
        repositoryId: loadOpenReport.repository.repositoryId,
        epoch: loadOpenReport.repository.epoch,
        workingCopyRoot: loadOpenReport.repository.identity.workingCopyRoot
      },
      load: {
        requestedItemCount: loadItemCount,
        projectedItemCountBefore: unversionedBefore.length,
        projectedItemCountAfter
      },
      prompt: {
        confirmationButton: "Delete",
        rendererCaptureExpectations: promptExpectations
      },
      notificationCleanup,
      notificationList,
      postDeleteFreshnessReport,
      closeReport: loadCloseReport,
      assertions: {
        commandExecuted: true,
        allFilesExistedBefore,
        anyFileExistsAfter,
        sourceControlProjectionCleared: projectedItemCountAfter === 0
      }
    };
  } catch (error) {
    if (loadOpenReport) {
      try {
        await closeOpenReport(loadOpenReport);
      } catch {
      }
    }
    throw error;
  }
}

function checkoutUrlPromptCaptureExpectations(repositoryUrl) {
  return {
    requiredDomTokens: ["Checkout SVN repository", "Enter the SVN repository URL to checkout."],
    requiredAccessibilityTokens: ["Checkout SVN repository", "Enter the SVN repository URL to checkout."],
    requiredScreenshot: true,
    inputText: repositoryUrl,
    submitKey: "Enter"
  };
}

function checkoutCancellationPromptCaptureExpectations() {
  return {
    requiredDomTokens: ["Checkout SVN repository", "Enter the SVN repository URL to checkout."],
    requiredAccessibilityTokens: ["Checkout SVN repository", "Enter the SVN repository URL to checkout."],
    requiredScreenshot: true,
    cancelSurface: "quickInput",
    cancelKey: "Escape"
  };
}

function checkoutFailureNotificationCaptureExpectations(errorCode) {
  return {
    requiredDomTokens: ["SubversionR repository command failed", errorCode],
    requiredAccessibilityTokens: ["SubversionR repository command failed", errorCode],
    requiredScreenshot: true
  };
}

function checkoutTargetPromptCaptureExpectations(targetWorkingCopyRoot) {
  return {
    requiredDomTokens: ["SVN checkout target folder", "Enter the absolute local folder path for the checkout."],
    requiredAccessibilityTokens: ["SVN checkout target folder", "Enter the absolute local folder path for the checkout."],
    requiredScreenshot: true,
    inputText: targetWorkingCopyRoot,
    submitKey: "Enter"
  };
}

function checkoutQuickPickPromptCaptureExpectations(title, selectedText, requiredItems) {
  return {
    requiredDomTokens: [title, ...requiredItems],
    requiredAccessibilityTokens: [title, ...requiredItems],
    requiredScreenshot: true,
    quickPickItemText: selectedText
  };
}

async function publishCheckoutPromptReadyAndWait(readyPath, donePath, payload) {
  fs.writeFileSync(readyPath, JSON.stringify(payload, null, 2));
  await waitForFile(donePath, 120000);
}

async function collectMissingCurrentSurfaceProbe(requestPath, label) {
  try {
    const surfaceReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport", { path: requestPath }),
      label,
      30000
    );
    throw new Error(`${label} unexpectedly resolved an open SourceControl surface: ${JSON.stringify(surfaceReport)}`);
  } catch (error) {
    if (
      error &&
      error.code === "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CURRENT_SESSION_MISSING" &&
      error.messageKey === "error.diagnostics.installedSourceControlUiE2eSessionMismatch"
    ) {
      return {
        kind: "subversionr.installedSourceControlUiE2eMissingCurrentSurfaceProbe",
        generatedAt: new Date().toISOString(),
        command: {
          command: "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport"
        },
        request: {
          path: requestPath
        },
        error: serializeError(error),
        assertions: {
          currentSessionMissing: true,
          sourceControlProjectionAbsent: true
        }
      };
    }
    throw error;
  }
}

async function runCheckoutCancellationWorkflow(repositoryUrl, baselineWorkingCopyRoot, targetWorkingCopyRoot, promptPaths) {
  if (fs.existsSync(targetWorkingCopyRoot)) {
    throw new Error(`Installed Checkout cancellation target already existed before cancellation: ${targetWorkingCopyRoot}`);
  }
  const baselineBeforeProbe = await collectMissingCurrentSurfaceProbe(
    baselineWorkingCopyRoot,
    "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport/checkoutCancellationBaselineBefore"
  );
  const targetBeforeProbe = await collectMissingCurrentSurfaceProbe(
    targetWorkingCopyRoot,
    "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport/checkoutCancellationTargetBefore"
  );
  const commandPromise = withTimeout(
    vscode.commands.executeCommand("subversionr.checkoutRepository"),
    "subversionr.checkoutRepository/cancellation",
    120000
  );
  await new Promise(resolve => setTimeout(resolve, 500));

  const prompt = checkoutCancellationPromptCaptureExpectations();
  await publishCheckoutPromptReadyAndWait(promptPaths.urlReady, promptPaths.urlDone, {
    ok: true,
    phase: "checkoutCancellationPromptReady",
    command: "subversionr.checkoutRepository",
    request: {
      url: repositoryUrl,
      targetPath: targetWorkingCopyRoot,
      revision: "head",
      depth: "infinity",
      ignoreExternals: true
    },
    prompt: {
      kind: "url",
      cancelKey: "Escape",
      rendererCaptureExpectations: prompt
    },
    rendererCaptureExpectations: prompt
  });

  await commandPromise;
  const svnMetadataPath = path.join(targetWorkingCopyRoot, ".svn");
  const targetExistsAfter = fs.existsSync(targetWorkingCopyRoot);
  const svnMetadataExistsAfter = fs.existsSync(svnMetadataPath);
  const baselineAfterProbe = await collectMissingCurrentSurfaceProbe(
    baselineWorkingCopyRoot,
    "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport/checkoutCancellationBaselineAfter"
  );
  const targetAfterProbe = await collectMissingCurrentSurfaceProbe(
    targetWorkingCopyRoot,
    "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport/checkoutCancellationTargetAfter"
  );
  const baselineSurfaceUnchanged =
    baselineBeforeProbe.assertions.currentSessionMissing === true &&
    baselineAfterProbe.assertions.currentSessionMissing === true &&
    baselineBeforeProbe.assertions.sourceControlProjectionAbsent === true &&
    baselineAfterProbe.assertions.sourceControlProjectionAbsent === true;
  const targetSurfaceAbsent =
    targetBeforeProbe.assertions.currentSessionMissing === true &&
    targetAfterProbe.assertions.currentSessionMissing === true &&
    targetBeforeProbe.assertions.sourceControlProjectionAbsent === true &&
    targetAfterProbe.assertions.sourceControlProjectionAbsent === true;

  return {
    kind: "subversionr.installedSourceControlUiE2eCheckoutCancellationWorkflow",
    generatedAt: new Date().toISOString(),
    command: {
      command: "subversionr.checkoutRepository"
    },
    request: {
      url: repositoryUrl,
      baselineWorkingCopyRoot,
      targetPath: targetWorkingCopyRoot,
      revision: "head",
      depth: "infinity",
      ignoreExternals: true
    },
    prompt: {
      kind: "url",
      cancelKey: "Escape",
      rendererCaptureExpectations: prompt
    },
    target: {
      workingCopyRoot: targetWorkingCopyRoot,
      svnMetadataPath
    },
    currentSurfaceProbes: {
      baselineBefore: baselineBeforeProbe,
      baselineAfter: baselineAfterProbe,
      targetBefore: targetBeforeProbe,
      targetAfter: targetAfterProbe
    },
    assertions: {
      commandCancelled: true,
      targetAbsentAfter: !targetExistsAfter,
      svnMetadataAbsentAfter: !svnMetadataExistsAfter,
      repositoryNotOpenedAfterCancellation: targetAfterProbe.assertions.currentSessionMissing === true,
      sourceControlProjectionUnchanged: baselineSurfaceUnchanged && targetSurfaceAbsent
    }
  };
}

async function runCheckoutExistingTargetFailureWorkflow(repositoryUrl, baselineWorkingCopyRoot, targetPath, promptPaths) {
  if (!fs.existsSync(targetPath) || !fs.statSync(targetPath).isFile()) {
    throw new Error(`Installed Checkout existing-target failure fixture must be an existing obstructing file: ${targetPath}`);
  }
  const targetParentPath = path.dirname(targetPath);
  const targetHashBefore = sha256File(targetPath);
  const svnMetadataPath = path.join(targetPath, ".svn");
  const parentSvnMetadataPath = path.join(targetParentPath, ".svn");
  if (fs.existsSync(svnMetadataPath)) {
    throw new Error(`Installed Checkout existing-target failure fixture must not start with SVN metadata: ${svnMetadataPath}`);
  }
  if (fs.existsSync(parentSvnMetadataPath)) {
    throw new Error(`Installed Checkout existing-target failure fixture parent must not start with SVN metadata: ${parentSvnMetadataPath}`);
  }
  const parentDirectoryEntriesBefore = directoryEntries(targetParentPath);
  const baselineBeforeProbe = await collectMissingCurrentSurfaceProbe(
    baselineWorkingCopyRoot,
    "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport/checkoutExistingTargetFailureBaselineBefore"
  );
  const targetBeforeProbe = await collectMissingCurrentSurfaceProbe(
    targetPath,
    "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport/checkoutExistingTargetFailureTargetBefore"
  );

  const request = {
    url: repositoryUrl,
    targetPath,
    revision: "head",
    depth: "infinity",
    ignoreExternals: true
  };
  const commandPromise = withTimeout(
    vscode.commands.executeCommand("subversionr.checkoutRepository"),
    "subversionr.checkoutRepository/existing-target-failure",
    120000
  );
  await new Promise(resolve => setTimeout(resolve, 500));

  const urlPrompt = checkoutUrlPromptCaptureExpectations(repositoryUrl);
  await publishCheckoutPromptReadyAndWait(promptPaths.urlReady, promptPaths.urlDone, {
    ok: true,
    phase: "checkoutExistingTargetFailureUrlPromptReady",
    command: "subversionr.checkoutRepository",
    request,
    prompt: {
      kind: "url",
      rendererCaptureExpectations: urlPrompt
    },
    rendererCaptureExpectations: urlPrompt
  });

  const targetPrompt = checkoutTargetPromptCaptureExpectations(targetPath);
  await publishCheckoutPromptReadyAndWait(promptPaths.targetReady, promptPaths.targetDone, {
    ok: true,
    phase: "checkoutExistingTargetFailureTargetPromptReady",
    command: "subversionr.checkoutRepository",
    request,
    prompt: {
      kind: "targetPath",
      rendererCaptureExpectations: targetPrompt
    },
    rendererCaptureExpectations: targetPrompt
  });

  const revisionPrompt = checkoutQuickPickPromptCaptureExpectations("SVN checkout revision", "HEAD", ["HEAD", "Revision"]);
  await publishCheckoutPromptReadyAndWait(promptPaths.revisionReady, promptPaths.revisionDone, {
    ok: true,
    phase: "checkoutExistingTargetFailureRevisionPromptReady",
    command: "subversionr.checkoutRepository",
    request,
    prompt: {
      kind: "revision",
      selected: "HEAD",
      rendererCaptureExpectations: revisionPrompt
    },
    rendererCaptureExpectations: revisionPrompt
  });

  const depthPrompt = checkoutQuickPickPromptCaptureExpectations("SVN checkout depth", "Infinity", ["Empty", "Files", "Immediates", "Infinity"]);
  await publishCheckoutPromptReadyAndWait(promptPaths.depthReady, promptPaths.depthDone, {
    ok: true,
    phase: "checkoutExistingTargetFailureDepthPromptReady",
    command: "subversionr.checkoutRepository",
    request,
    prompt: {
      kind: "depth",
      selected: "Infinity",
      rendererCaptureExpectations: depthPrompt
    },
    rendererCaptureExpectations: depthPrompt
  });

  const externalsPrompt = checkoutQuickPickPromptCaptureExpectations("SVN checkout externals", "Ignore externals", ["Ignore externals", "Include externals"]);
  await publishCheckoutPromptReadyAndWait(promptPaths.externalsReady, promptPaths.externalsDone, {
    ok: true,
    phase: "checkoutExistingTargetFailureExternalsPromptReady",
    command: "subversionr.checkoutRepository",
    request,
    prompt: {
      kind: "externals",
      selected: "Ignore externals",
      rendererCaptureExpectations: externalsPrompt
    },
    rendererCaptureExpectations: externalsPrompt
  });

  await commandPromise;

  const failureCode = "SVN_REPOSITORY_CHECKOUT_FAILED";
  const notificationCode = "SUBVERSIONR_REPOSITORY_COMMAND_FAILED";
  const notificationPrompt = checkoutFailureNotificationCaptureExpectations(notificationCode);
  await publishCheckoutPromptReadyAndWait(promptPaths.notificationReady, promptPaths.notificationDone, {
    ok: true,
    phase: "checkoutExistingTargetFailureNotificationReady",
    command: "subversionr.checkoutRepository",
    request,
    failure: {
      code: failureCode,
      category: "native",
      notificationText: `SubversionR repository command failed: ${notificationCode}`
    },
    notification: {
      rendererCaptureExpectations: notificationPrompt
    },
    rendererCaptureExpectations: notificationPrompt
  });
  const notificationCleanup = await clearWorkbenchNotificationsBeforePrompt("checkoutExistingTargetFailureNotification");

  const targetStillFileAfter = fs.existsSync(targetPath) && fs.statSync(targetPath).isFile();
  const targetHashAfter = targetStillFileAfter ? sha256File(targetPath) : null;
  const parentDirectoryEntriesAfter = directoryEntries(targetParentPath);
  const svnMetadataExistsAfter = fs.existsSync(svnMetadataPath) || fs.existsSync(parentSvnMetadataPath);
  const baselineAfterProbe = await collectMissingCurrentSurfaceProbe(
    baselineWorkingCopyRoot,
    "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport/checkoutExistingTargetFailureBaselineAfter"
  );
  const targetAfterProbe = await collectMissingCurrentSurfaceProbe(
    targetPath,
    "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport/checkoutExistingTargetFailureTargetAfter"
  );
  const baselineSurfaceUnchanged =
    baselineBeforeProbe.assertions.currentSessionMissing === true &&
    baselineAfterProbe.assertions.currentSessionMissing === true &&
    baselineBeforeProbe.assertions.sourceControlProjectionAbsent === true &&
    baselineAfterProbe.assertions.sourceControlProjectionAbsent === true;
  const targetSurfaceAbsent =
    targetBeforeProbe.assertions.currentSessionMissing === true &&
    targetAfterProbe.assertions.currentSessionMissing === true &&
    targetBeforeProbe.assertions.sourceControlProjectionAbsent === true &&
    targetAfterProbe.assertions.sourceControlProjectionAbsent === true;

  return {
    kind: "subversionr.installedSourceControlUiE2eCheckoutExistingTargetFailureWorkflow",
    generatedAt: new Date().toISOString(),
    command: {
      command: "subversionr.checkoutRepository"
    },
    request,
    prompts: {
      url: {
        rendererCaptureExpectations: urlPrompt
      },
      targetPath: {
        rendererCaptureExpectations: targetPrompt
      },
      revision: {
        selected: "HEAD",
        rendererCaptureExpectations: revisionPrompt
      },
      depth: {
        selected: "Infinity",
        rendererCaptureExpectations: depthPrompt
      },
      externals: {
        selected: "Ignore externals",
        rendererCaptureExpectations: externalsPrompt
      }
    },
    failure: {
      code: failureCode,
      category: "native",
      notificationText: `SubversionR repository command failed: ${notificationCode}`
    },
    notification: {
      rendererCaptureExpectations: notificationPrompt,
      cleanup: notificationCleanup
    },
    target: {
      obstructingFilePath: targetPath,
      parentDirectoryPath: targetParentPath,
      sha256Before: targetHashBefore,
      sha256After: targetHashAfter,
      svnMetadataPath,
      parentSvnMetadataPath,
      parentDirectoryEntriesBefore,
      parentDirectoryEntriesAfter
    },
    currentSurfaceProbes: {
      baselineBefore: baselineBeforeProbe,
      baselineAfter: baselineAfterProbe,
      targetBefore: targetBeforeProbe,
      targetAfter: targetAfterProbe
    },
    assertions: {
      commandFailed: true,
      obstructingTargetFilePreserved: targetStillFileAfter && targetHashAfter === targetHashBefore,
      svnMetadataAbsentAfter: !svnMetadataExistsAfter,
      fixtureDirectoryUnchanged: directoryEntriesEqual(parentDirectoryEntriesBefore, parentDirectoryEntriesAfter),
      repositoryNotOpenedAfterFailure: targetAfterProbe.assertions.currentSessionMissing === true,
      sourceControlProjectionUnchanged: baselineSurfaceUnchanged && targetSurfaceAbsent
    }
  };
}

async function runCheckoutInvalidUrlFailureWorkflow(repositoryUrl, baselineWorkingCopyRoot, targetWorkingCopyRoot, promptPaths) {
  if (fs.existsSync(targetWorkingCopyRoot)) {
    throw new Error(`Installed Checkout invalid URL failure target already existed before failure: ${targetWorkingCopyRoot}`);
  }
  const targetParentPath = path.dirname(targetWorkingCopyRoot);
  if (!fs.existsSync(targetParentPath) || !fs.statSync(targetParentPath).isDirectory()) {
    throw new Error(`Installed Checkout invalid URL failure target parent must exist before failure: ${targetParentPath}`);
  }
  const svnMetadataPath = path.join(targetWorkingCopyRoot, ".svn");
  const parentSvnMetadataPath = path.join(targetParentPath, ".svn");
  if (fs.existsSync(parentSvnMetadataPath)) {
    throw new Error(`Installed Checkout invalid URL failure fixture parent must not start with SVN metadata: ${parentSvnMetadataPath}`);
  }
  const parentDirectoryEntriesBefore = directoryEntries(targetParentPath);
  const baselineBeforeProbe = await collectMissingCurrentSurfaceProbe(
    baselineWorkingCopyRoot,
    "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport/checkoutInvalidUrlFailureBaselineBefore"
  );
  const targetBeforeProbe = await collectMissingCurrentSurfaceProbe(
    targetWorkingCopyRoot,
    "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport/checkoutInvalidUrlFailureTargetBefore"
  );

  const request = {
    url: repositoryUrl,
    targetPath: targetWorkingCopyRoot,
    revision: "head",
    depth: "infinity",
    ignoreExternals: true
  };
  const commandPromise = withTimeout(
    vscode.commands.executeCommand("subversionr.checkoutRepository"),
    "subversionr.checkoutRepository/invalid-url-failure",
    120000
  );
  await new Promise(resolve => setTimeout(resolve, 500));

  const urlPrompt = checkoutUrlPromptCaptureExpectations(repositoryUrl);
  await publishCheckoutPromptReadyAndWait(promptPaths.urlReady, promptPaths.urlDone, {
    ok: true,
    phase: "checkoutInvalidUrlFailureUrlPromptReady",
    command: "subversionr.checkoutRepository",
    request,
    prompt: {
      kind: "url",
      rendererCaptureExpectations: urlPrompt
    },
    rendererCaptureExpectations: urlPrompt
  });

  const targetPrompt = checkoutTargetPromptCaptureExpectations(targetWorkingCopyRoot);
  await publishCheckoutPromptReadyAndWait(promptPaths.targetReady, promptPaths.targetDone, {
    ok: true,
    phase: "checkoutInvalidUrlFailureTargetPromptReady",
    command: "subversionr.checkoutRepository",
    request,
    prompt: {
      kind: "targetPath",
      rendererCaptureExpectations: targetPrompt
    },
    rendererCaptureExpectations: targetPrompt
  });

  const revisionPrompt = checkoutQuickPickPromptCaptureExpectations("SVN checkout revision", "HEAD", ["HEAD", "Revision number"]);
  await publishCheckoutPromptReadyAndWait(promptPaths.revisionReady, promptPaths.revisionDone, {
    ok: true,
    phase: "checkoutInvalidUrlFailureRevisionPromptReady",
    command: "subversionr.checkoutRepository",
    request,
    prompt: {
      kind: "revision",
      selected: "HEAD",
      rendererCaptureExpectations: revisionPrompt
    },
    rendererCaptureExpectations: revisionPrompt
  });

  const depthPrompt = checkoutQuickPickPromptCaptureExpectations("SVN checkout depth", "Infinity", ["Empty", "Files", "Immediates", "Infinity"]);
  await publishCheckoutPromptReadyAndWait(promptPaths.depthReady, promptPaths.depthDone, {
    ok: true,
    phase: "checkoutInvalidUrlFailureDepthPromptReady",
    command: "subversionr.checkoutRepository",
    request,
    prompt: {
      kind: "depth",
      selected: "Infinity",
      rendererCaptureExpectations: depthPrompt
    },
    rendererCaptureExpectations: depthPrompt
  });

  const externalsPrompt = checkoutQuickPickPromptCaptureExpectations("SVN checkout externals", "Ignore externals", ["Ignore externals", "Include externals"]);
  await publishCheckoutPromptReadyAndWait(promptPaths.externalsReady, promptPaths.externalsDone, {
    ok: true,
    phase: "checkoutInvalidUrlFailureExternalsPromptReady",
    command: "subversionr.checkoutRepository",
    request,
    prompt: {
      kind: "externals",
      selected: "Ignore externals",
      rendererCaptureExpectations: externalsPrompt
    },
    rendererCaptureExpectations: externalsPrompt
  });

  await commandPromise;

  const failureCode = "SVN_REPOSITORY_CHECKOUT_FAILED";
  const notificationCode = "SUBVERSIONR_REPOSITORY_COMMAND_FAILED";
  const notificationPrompt = checkoutFailureNotificationCaptureExpectations(notificationCode);
  await publishCheckoutPromptReadyAndWait(promptPaths.notificationReady, promptPaths.notificationDone, {
    ok: true,
    phase: "checkoutInvalidUrlFailureNotificationReady",
    command: "subversionr.checkoutRepository",
    request,
    failure: {
      code: failureCode,
      category: "native",
      notificationText: `SubversionR repository command failed: ${notificationCode}`
    },
    notification: {
      rendererCaptureExpectations: notificationPrompt
    },
    rendererCaptureExpectations: notificationPrompt
  });
  const notificationCleanup = await clearWorkbenchNotificationsBeforePrompt("checkoutInvalidUrlFailureNotification");

  const targetExistsAfter = fs.existsSync(targetWorkingCopyRoot);
  const parentDirectoryEntriesAfter = directoryEntries(targetParentPath);
  const svnMetadataExistsAfter = fs.existsSync(svnMetadataPath) || fs.existsSync(parentSvnMetadataPath);
  const baselineAfterProbe = await collectMissingCurrentSurfaceProbe(
    baselineWorkingCopyRoot,
    "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport/checkoutInvalidUrlFailureBaselineAfter"
  );
  const targetAfterProbe = await collectMissingCurrentSurfaceProbe(
    targetWorkingCopyRoot,
    "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport/checkoutInvalidUrlFailureTargetAfter"
  );
  const baselineSurfaceUnchanged =
    baselineBeforeProbe.assertions.currentSessionMissing === true &&
    baselineAfterProbe.assertions.currentSessionMissing === true &&
    baselineBeforeProbe.assertions.sourceControlProjectionAbsent === true &&
    baselineAfterProbe.assertions.sourceControlProjectionAbsent === true;
  const targetSurfaceAbsent =
    targetBeforeProbe.assertions.currentSessionMissing === true &&
    targetAfterProbe.assertions.currentSessionMissing === true &&
    targetBeforeProbe.assertions.sourceControlProjectionAbsent === true &&
    targetAfterProbe.assertions.sourceControlProjectionAbsent === true;

  return {
    kind: "subversionr.installedSourceControlUiE2eCheckoutInvalidUrlFailureWorkflow",
    generatedAt: new Date().toISOString(),
    command: {
      command: "subversionr.checkoutRepository"
    },
    request,
    prompts: {
      url: {
        rendererCaptureExpectations: urlPrompt
      },
      targetPath: {
        rendererCaptureExpectations: targetPrompt
      },
      revision: {
        selected: "HEAD",
        rendererCaptureExpectations: revisionPrompt
      },
      depth: {
        selected: "Infinity",
        rendererCaptureExpectations: depthPrompt
      },
      externals: {
        selected: "Ignore externals",
        rendererCaptureExpectations: externalsPrompt
      }
    },
    failure: {
      code: failureCode,
      category: "native",
      notificationText: `SubversionR repository command failed: ${notificationCode}`
    },
    notification: {
      rendererCaptureExpectations: notificationPrompt,
      cleanup: notificationCleanup
    },
    target: {
      workingCopyRoot: targetWorkingCopyRoot,
      parentDirectoryPath: targetParentPath,
      svnMetadataPath,
      parentSvnMetadataPath,
      parentDirectoryEntriesBefore,
      parentDirectoryEntriesAfter
    },
    currentSurfaceProbes: {
      baselineBefore: baselineBeforeProbe,
      baselineAfter: baselineAfterProbe,
      targetBefore: targetBeforeProbe,
      targetAfter: targetAfterProbe
    },
    assertions: {
      commandFailed: true,
      invalidUrlRejected: true,
      targetAbsentAfter: !targetExistsAfter,
      svnMetadataAbsentAfter: !svnMetadataExistsAfter,
      parentDirectoryUnchanged: directoryEntriesEqual(parentDirectoryEntriesBefore, parentDirectoryEntriesAfter),
      repositoryNotOpenedAfterFailure: targetAfterProbe.assertions.currentSessionMissing === true,
      sourceControlProjectionUnchanged: baselineSurfaceUnchanged && targetSurfaceAbsent
    }
  };
}

async function runCheckoutExistingDirectoryWorkflow(repositoryUrl, targetWorkingCopyRoot, promptPaths) {
  let currentSurfaceReport;
  let closeReport;
  const localOnlyFileName = "local-only-before-checkout.txt";
  const localOnlyPath = path.join(targetWorkingCopyRoot, localOnlyFileName);
  const svnMetadataPath = path.join(targetWorkingCopyRoot, ".svn");
  const request = {
    url: repositoryUrl,
    targetPath: targetWorkingCopyRoot,
    revision: "head",
    depth: "infinity",
    ignoreExternals: true
  };
  try {
    if (!fs.existsSync(targetWorkingCopyRoot) || !fs.statSync(targetWorkingCopyRoot).isDirectory()) {
      throw new Error(`Installed Checkout existing-directory workflow target must be a directory before checkout: ${targetWorkingCopyRoot}`);
    }
    if (fs.existsSync(svnMetadataPath)) {
      throw new Error(`Installed Checkout existing-directory workflow target must not contain SVN metadata before checkout: ${svnMetadataPath}`);
    }
    if (!fs.existsSync(localOnlyPath) || !fs.statSync(localOnlyPath).isFile()) {
      throw new Error(`Installed Checkout existing-directory workflow target must contain the local-only marker before checkout: ${localOnlyPath}`);
    }
    const localOnlyHashBefore = sha256File(localOnlyPath);
    const directoryEntriesBefore = directoryEntries(targetWorkingCopyRoot);

    const commandPromise = withTimeout(
      vscode.commands.executeCommand("subversionr.checkoutRepository"),
      "subversionr.checkoutRepository/existing-directory",
      120000
    );
    await new Promise(resolve => setTimeout(resolve, 500));

    const urlPrompt = checkoutUrlPromptCaptureExpectations(repositoryUrl);
    await publishCheckoutPromptReadyAndWait(promptPaths.urlReady, promptPaths.urlDone, {
      ok: true,
      phase: "checkoutExistingDirectoryUrlPromptReady",
      command: "subversionr.checkoutRepository",
      request,
      prompt: {
        kind: "url",
        rendererCaptureExpectations: urlPrompt
      },
      rendererCaptureExpectations: urlPrompt
    });

    const targetPrompt = checkoutTargetPromptCaptureExpectations(targetWorkingCopyRoot);
    await publishCheckoutPromptReadyAndWait(promptPaths.targetReady, promptPaths.targetDone, {
      ok: true,
      phase: "checkoutExistingDirectoryTargetPromptReady",
      command: "subversionr.checkoutRepository",
      request,
      prompt: {
        kind: "targetPath",
        rendererCaptureExpectations: targetPrompt
      },
      rendererCaptureExpectations: targetPrompt
    });

    const revisionPrompt = checkoutQuickPickPromptCaptureExpectations("SVN checkout revision", "HEAD", ["HEAD", "Revision number"]);
    await publishCheckoutPromptReadyAndWait(promptPaths.revisionReady, promptPaths.revisionDone, {
      ok: true,
      phase: "checkoutExistingDirectoryRevisionPromptReady",
      command: "subversionr.checkoutRepository",
      request,
      prompt: {
        kind: "revision",
        selected: "HEAD",
        rendererCaptureExpectations: revisionPrompt
      },
      rendererCaptureExpectations: revisionPrompt
    });

    const depthPrompt = checkoutQuickPickPromptCaptureExpectations("SVN checkout depth", "Infinity", ["Empty", "Files", "Immediates", "Infinity"]);
    await publishCheckoutPromptReadyAndWait(promptPaths.depthReady, promptPaths.depthDone, {
      ok: true,
      phase: "checkoutExistingDirectoryDepthPromptReady",
      command: "subversionr.checkoutRepository",
      request,
      prompt: {
        kind: "depth",
        selected: "Infinity",
        rendererCaptureExpectations: depthPrompt
      },
      rendererCaptureExpectations: depthPrompt
    });

    const externalsPrompt = checkoutQuickPickPromptCaptureExpectations("SVN checkout externals", "Ignore externals", ["Ignore externals", "Include externals"]);
    await publishCheckoutPromptReadyAndWait(promptPaths.externalsReady, promptPaths.externalsDone, {
      ok: true,
      phase: "checkoutExistingDirectoryExternalsPromptReady",
      command: "subversionr.checkoutRepository",
      request,
      prompt: {
        kind: "externals",
        selected: "Ignore externals",
        rendererCaptureExpectations: externalsPrompt
      },
      rendererCaptureExpectations: externalsPrompt
    });

    await commandPromise;

    const trackedPath = path.join(targetWorkingCopyRoot, "src", "tracked.txt");
    const trackedFileExists = fs.existsSync(trackedPath);
    const svnMetadataExists = fs.existsSync(svnMetadataPath);
    if (!trackedFileExists || !svnMetadataExists) {
      throw new Error("Installed Checkout existing-directory workflow did not create the expected working-copy content and metadata.");
    }
    const localOnlyFileExistsAfter = fs.existsSync(localOnlyPath) && fs.statSync(localOnlyPath).isFile();
    const localOnlyHashAfter = localOnlyFileExistsAfter ? sha256File(localOnlyPath) : null;
    const directoryEntriesAfter = directoryEntries(targetWorkingCopyRoot);

    currentSurfaceReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport", { path: targetWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport/checkoutExistingDirectory",
      30000
    );
    if (
      !currentSurfaceReport ||
      currentSurfaceReport.kind !== "subversionr.installedSourceControlUiE2eCurrentSurfaceReport" ||
      path.resolve(currentSurfaceReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(targetWorkingCopyRoot).toLowerCase()
    ) {
      throw new Error(`Unexpected installed Checkout existing-directory current surface report kind: ${currentSurfaceReport && currentSurfaceReport.kind}`);
    }
    const localOnlyResource = findResource(
      currentSurfaceReport,
      "unversioned",
      localOnlyFileName,
      "subversionr.unversioned"
    );
    closeReport = await closeOpenReport({
      repository: {
        repositoryId: currentSurfaceReport.repository.repositoryId,
        epoch: currentSurfaceReport.repository.epoch
      }
    });
    if (!closeReport || closeReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || closeReport.repositoryClosed !== true) {
      throw new Error("Installed Checkout existing-directory workflow did not close the checked-out repository after evidence collection.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eCheckoutExistingDirectoryWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.checkoutRepository"
      },
      request,
      prompts: {
        url: {
          rendererCaptureExpectations: urlPrompt
        },
        targetPath: {
          rendererCaptureExpectations: targetPrompt
        },
        revision: {
          selected: "HEAD",
          rendererCaptureExpectations: revisionPrompt
        },
        depth: {
          selected: "Infinity",
          rendererCaptureExpectations: depthPrompt
        },
        externals: {
          selected: "Ignore externals",
          rendererCaptureExpectations: externalsPrompt
        }
      },
      target: {
        workingCopyRoot: targetWorkingCopyRoot,
        trackedPath,
        svnMetadataPath,
        localOnlyPath,
        localOnlyFileName,
        localOnlyHashBefore,
        localOnlyHashAfter,
        directoryEntriesBefore,
        directoryEntriesAfter
      },
      localOnlyResource,
      currentSurfaceReport,
      closeReport,
      assertions: {
        commandExecuted: true,
        targetDirectoryExistedBefore: true,
        targetDirectoryNonEmptyBefore: directoryEntriesBefore.length > 0,
        existingDirectoryTargetAccepted: directoryEntriesBefore.some(entry => entry.name === localOnlyFileName && entry.kind === "file"),
        workingCopyCreated: trackedFileExists && svnMetadataExists,
        localDirectoryEntryPreserved:
          localOnlyFileExistsAfter &&
          localOnlyHashAfter === localOnlyHashBefore &&
          directoryEntriesAfter.some(entry => entry.name === localOnlyFileName && entry.kind === "file"),
        repositoryOpenedAfterCheckout: currentSurfaceReport.surfaceWorkflow.repositoryOpen === true,
        sourceControlProjectionAvailable:
          currentSurfaceReport.surfaceWorkflow.scmProjection === true &&
          currentSurfaceReport.surfaceWorkflow.sourceControlSurface === true,
        localOnlyFileProjectedUnversioned: Boolean(localOnlyResource),
        repositoryClosedAfterEvidence: closeReport.repositoryClosed === true
      }
    };
  } catch (error) {
    if (currentSurfaceReport && !closeReport) {
      try {
        await closeOpenReport({
          repository: {
            repositoryId: currentSurfaceReport.repository.repositoryId,
            epoch: currentSurfaceReport.repository.epoch
          }
        });
      } catch {
      }
    }
    throw error;
  }
}

async function runCheckoutExistingDirectoryObstructionWorkflow(repositoryUrl, targetWorkingCopyRoot, promptPaths) {
  let currentSurfaceReport;
  let closeReport;
  const localOnlyFileName = "local-only-before-checkout.txt";
  const conflictPath = "src";
  const localOnlyPath = path.join(targetWorkingCopyRoot, localOnlyFileName);
  const obstructionPath = path.join(targetWorkingCopyRoot, conflictPath);
  const svnMetadataPath = path.join(targetWorkingCopyRoot, ".svn");
  const blockedIncomingTrackedPath = path.join(targetWorkingCopyRoot, "src", "tracked.txt");
  const request = {
    url: repositoryUrl,
    targetPath: targetWorkingCopyRoot,
    revision: "head",
    depth: "infinity",
    ignoreExternals: true
  };
  try {
    if (!fs.existsSync(targetWorkingCopyRoot) || !fs.statSync(targetWorkingCopyRoot).isDirectory()) {
      throw new Error(`Installed Checkout existing-directory obstruction workflow target must be a directory before checkout: ${targetWorkingCopyRoot}`);
    }
    if (fs.existsSync(svnMetadataPath)) {
      throw new Error(`Installed Checkout existing-directory obstruction workflow target must not contain SVN metadata before checkout: ${svnMetadataPath}`);
    }
    if (!fs.existsSync(localOnlyPath) || !fs.statSync(localOnlyPath).isFile()) {
      throw new Error(`Installed Checkout existing-directory obstruction workflow target must contain the local-only marker before checkout: ${localOnlyPath}`);
    }
    if (!fs.existsSync(obstructionPath) || !fs.statSync(obstructionPath).isFile()) {
      throw new Error(`Installed Checkout existing-directory obstruction workflow target must contain the obstructing local file before checkout: ${obstructionPath}`);
    }
    const localOnlyHashBefore = sha256File(localOnlyPath);
    const obstructionHashBefore = sha256File(obstructionPath);
    const directoryEntriesBefore = directoryEntries(targetWorkingCopyRoot);

    const commandPromise = withTimeout(
      vscode.commands.executeCommand("subversionr.checkoutRepository"),
      "subversionr.checkoutRepository/existing-directory-obstruction",
      120000
    );
    await new Promise(resolve => setTimeout(resolve, 500));

    const urlPrompt = checkoutUrlPromptCaptureExpectations(repositoryUrl);
    await publishCheckoutPromptReadyAndWait(promptPaths.urlReady, promptPaths.urlDone, {
      ok: true,
      phase: "checkoutExistingDirectoryObstructionUrlPromptReady",
      command: "subversionr.checkoutRepository",
      request,
      prompt: {
        kind: "url",
        rendererCaptureExpectations: urlPrompt
      },
      rendererCaptureExpectations: urlPrompt
    });

    const targetPrompt = checkoutTargetPromptCaptureExpectations(targetWorkingCopyRoot);
    await publishCheckoutPromptReadyAndWait(promptPaths.targetReady, promptPaths.targetDone, {
      ok: true,
      phase: "checkoutExistingDirectoryObstructionTargetPromptReady",
      command: "subversionr.checkoutRepository",
      request,
      prompt: {
        kind: "targetPath",
        rendererCaptureExpectations: targetPrompt
      },
      rendererCaptureExpectations: targetPrompt
    });

    const revisionPrompt = checkoutQuickPickPromptCaptureExpectations("SVN checkout revision", "HEAD", ["HEAD", "Revision number"]);
    await publishCheckoutPromptReadyAndWait(promptPaths.revisionReady, promptPaths.revisionDone, {
      ok: true,
      phase: "checkoutExistingDirectoryObstructionRevisionPromptReady",
      command: "subversionr.checkoutRepository",
      request,
      prompt: {
        kind: "revision",
        selected: "HEAD",
        rendererCaptureExpectations: revisionPrompt
      },
      rendererCaptureExpectations: revisionPrompt
    });

    const depthPrompt = checkoutQuickPickPromptCaptureExpectations("SVN checkout depth", "Infinity", ["Empty", "Files", "Immediates", "Infinity"]);
    await publishCheckoutPromptReadyAndWait(promptPaths.depthReady, promptPaths.depthDone, {
      ok: true,
      phase: "checkoutExistingDirectoryObstructionDepthPromptReady",
      command: "subversionr.checkoutRepository",
      request,
      prompt: {
        kind: "depth",
        selected: "Infinity",
        rendererCaptureExpectations: depthPrompt
      },
      rendererCaptureExpectations: depthPrompt
    });

    const externalsPrompt = checkoutQuickPickPromptCaptureExpectations("SVN checkout externals", "Ignore externals", ["Ignore externals", "Include externals"]);
    await publishCheckoutPromptReadyAndWait(promptPaths.externalsReady, promptPaths.externalsDone, {
      ok: true,
      phase: "checkoutExistingDirectoryObstructionExternalsPromptReady",
      command: "subversionr.checkoutRepository",
      request,
      prompt: {
        kind: "externals",
        selected: "Ignore externals",
        rendererCaptureExpectations: externalsPrompt
      },
      rendererCaptureExpectations: externalsPrompt
    });

    await commandPromise;

    const svnMetadataExists = fs.existsSync(svnMetadataPath);
    const localOnlyFileExistsAfter = fs.existsSync(localOnlyPath) && fs.statSync(localOnlyPath).isFile();
    const obstructionFileExistsAfter = fs.existsSync(obstructionPath) && fs.statSync(obstructionPath).isFile();
    const blockedIncomingTrackedExists = fs.existsSync(blockedIncomingTrackedPath);
    const localOnlyHashAfter = localOnlyFileExistsAfter ? sha256File(localOnlyPath) : null;
    const obstructionHashAfter = obstructionFileExistsAfter ? sha256File(obstructionPath) : null;
    const directoryEntriesAfter = directoryEntries(targetWorkingCopyRoot);
    if (!svnMetadataExists || !obstructionFileExistsAfter || blockedIncomingTrackedExists) {
      throw new Error("Installed Checkout existing-directory obstruction workflow did not preserve the expected libsvn obstruction state.");
    }

    currentSurfaceReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport", { path: targetWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport/checkoutExistingDirectoryObstruction",
      30000
    );
    if (
      !currentSurfaceReport ||
      currentSurfaceReport.kind !== "subversionr.installedSourceControlUiE2eCurrentSurfaceReport" ||
      path.resolve(currentSurfaceReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(targetWorkingCopyRoot).toLowerCase()
    ) {
      throw new Error(`Unexpected installed Checkout existing-directory obstruction current surface report kind: ${currentSurfaceReport && currentSurfaceReport.kind}`);
    }
    const conflictResource = findResource(
      currentSurfaceReport,
      "conflicts",
      conflictPath,
      "subversionr.conflicted"
    );
    if (!conflictResource) {
      throw new Error("Installed Checkout existing-directory obstruction workflow did not project the obstructing src node as an SVN conflict.");
    }
    const localOnlyResource = findResource(
      currentSurfaceReport,
      "unversioned",
      localOnlyFileName,
      "subversionr.unversioned"
    );
    closeReport = await closeOpenReport({
      repository: {
        repositoryId: currentSurfaceReport.repository.repositoryId,
        epoch: currentSurfaceReport.repository.epoch
      }
    });
    if (!closeReport || closeReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || closeReport.repositoryClosed !== true) {
      throw new Error("Installed Checkout existing-directory obstruction workflow did not close the checked-out repository after evidence collection.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eCheckoutExistingDirectoryObstructionWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.checkoutRepository"
      },
      request,
      prompts: {
        url: {
          rendererCaptureExpectations: urlPrompt
        },
        targetPath: {
          rendererCaptureExpectations: targetPrompt
        },
        revision: {
          selected: "HEAD",
          rendererCaptureExpectations: revisionPrompt
        },
        depth: {
          selected: "Infinity",
          rendererCaptureExpectations: depthPrompt
        },
        externals: {
          selected: "Ignore externals",
          rendererCaptureExpectations: externalsPrompt
        }
      },
      target: {
        workingCopyRoot: targetWorkingCopyRoot,
        conflictPath,
        obstructionPath,
        blockedIncomingTrackedPath,
        svnMetadataPath,
        localOnlyPath,
        localOnlyFileName,
        localOnlyHashBefore,
        localOnlyHashAfter,
        obstructionHashBefore,
        obstructionHashAfter,
        directoryEntriesBefore,
        directoryEntriesAfter
      },
      conflictResource,
      localOnlyResource,
      currentSurfaceReport,
      closeReport,
      assertions: {
        commandExecuted: true,
        targetDirectoryExistedBefore: true,
        targetDirectoryNonEmptyBefore: directoryEntriesBefore.length > 0,
        obstructingFileExistedBefore: directoryEntriesBefore.some(entry => entry.name === conflictPath && entry.kind === "file"),
        workingCopyCreated: svnMetadataExists,
        obstructionPreserved: obstructionFileExistsAfter && obstructionHashAfter === obstructionHashBefore,
        blockedIncomingTrackedPathAbsent: !blockedIncomingTrackedExists,
        localDirectoryEntryPreserved:
          localOnlyFileExistsAfter &&
          localOnlyHashAfter === localOnlyHashBefore &&
          directoryEntriesAfter.some(entry => entry.name === localOnlyFileName && entry.kind === "file"),
        repositoryOpenedAfterCheckout: currentSurfaceReport.surfaceWorkflow.repositoryOpen === true,
        sourceControlProjectionAvailable:
          currentSurfaceReport.surfaceWorkflow.scmProjection === true &&
          currentSurfaceReport.surfaceWorkflow.sourceControlSurface === true,
        treeConflictProjected: Boolean(conflictResource),
        localOnlyFileProjectedUnversioned: Boolean(localOnlyResource),
        repositoryClosedAfterEvidence: closeReport.repositoryClosed === true
      }
    };
  } catch (error) {
    if (currentSurfaceReport && !closeReport) {
      try {
        await closeOpenReport({
          repository: {
            repositoryId: currentSurfaceReport.repository.repositoryId,
            epoch: currentSurfaceReport.repository.epoch
          }
        });
      } catch {
      }
    }
    throw error;
  }
}

async function runCheckoutWorkflow(repositoryUrl, targetWorkingCopyRoot, promptPaths) {
  let currentSurfaceReport;
  let closeReport;
  const request = {
    url: repositoryUrl,
    targetPath: targetWorkingCopyRoot,
    revision: "head",
    depth: "infinity",
    ignoreExternals: true
  };
  try {
    if (fs.existsSync(targetWorkingCopyRoot)) {
      throw new Error(`Installed Checkout workflow target already existed before checkout: ${targetWorkingCopyRoot}`);
    }
    const commandPromise = withTimeout(
      vscode.commands.executeCommand("subversionr.checkoutRepository"),
      "subversionr.checkoutRepository",
      120000
    );
    await new Promise(resolve => setTimeout(resolve, 500));

    const urlPrompt = checkoutUrlPromptCaptureExpectations(repositoryUrl);
    await publishCheckoutPromptReadyAndWait(promptPaths.urlReady, promptPaths.urlDone, {
      ok: true,
      phase: "checkoutUrlPromptReady",
      command: "subversionr.checkoutRepository",
      request,
      prompt: {
        kind: "url",
        rendererCaptureExpectations: urlPrompt
      },
      rendererCaptureExpectations: urlPrompt
    });

    const targetPrompt = checkoutTargetPromptCaptureExpectations(targetWorkingCopyRoot);
    await publishCheckoutPromptReadyAndWait(promptPaths.targetReady, promptPaths.targetDone, {
      ok: true,
      phase: "checkoutTargetPromptReady",
      command: "subversionr.checkoutRepository",
      request,
      prompt: {
        kind: "targetPath",
        rendererCaptureExpectations: targetPrompt
      },
      rendererCaptureExpectations: targetPrompt
    });

    const revisionPrompt = checkoutQuickPickPromptCaptureExpectations("SVN checkout revision", "HEAD", ["HEAD", "Revision number"]);
    await publishCheckoutPromptReadyAndWait(promptPaths.revisionReady, promptPaths.revisionDone, {
      ok: true,
      phase: "checkoutRevisionPromptReady",
      command: "subversionr.checkoutRepository",
      request,
      prompt: {
        kind: "revision",
        selected: "HEAD",
        rendererCaptureExpectations: revisionPrompt
      },
      rendererCaptureExpectations: revisionPrompt
    });

    const depthPrompt = checkoutQuickPickPromptCaptureExpectations("SVN checkout depth", "Infinity", ["Empty", "Files", "Immediates", "Infinity"]);
    await publishCheckoutPromptReadyAndWait(promptPaths.depthReady, promptPaths.depthDone, {
      ok: true,
      phase: "checkoutDepthPromptReady",
      command: "subversionr.checkoutRepository",
      request,
      prompt: {
        kind: "depth",
        selected: "Infinity",
        rendererCaptureExpectations: depthPrompt
      },
      rendererCaptureExpectations: depthPrompt
    });

    const externalsPrompt = checkoutQuickPickPromptCaptureExpectations("SVN checkout externals", "Ignore externals", ["Ignore externals", "Include externals"]);
    await publishCheckoutPromptReadyAndWait(promptPaths.externalsReady, promptPaths.externalsDone, {
      ok: true,
      phase: "checkoutExternalsPromptReady",
      command: "subversionr.checkoutRepository",
      request,
      prompt: {
        kind: "externals",
        selected: "Ignore externals",
        rendererCaptureExpectations: externalsPrompt
      },
      rendererCaptureExpectations: externalsPrompt
    });

    await commandPromise;

    const trackedPath = path.join(targetWorkingCopyRoot, "src", "tracked.txt");
    const svnMetadataPath = path.join(targetWorkingCopyRoot, ".svn");
    const trackedFileExists = fs.existsSync(trackedPath);
    const svnMetadataExists = fs.existsSync(svnMetadataPath);
    if (!trackedFileExists || !svnMetadataExists) {
      throw new Error("Installed Checkout workflow did not create the expected working-copy content and metadata.");
    }

    currentSurfaceReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport", { path: targetWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport/checkout",
      30000
    );
    if (
      !currentSurfaceReport ||
      currentSurfaceReport.kind !== "subversionr.installedSourceControlUiE2eCurrentSurfaceReport" ||
      path.resolve(currentSurfaceReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(targetWorkingCopyRoot).toLowerCase()
    ) {
      throw new Error(`Unexpected installed Checkout current surface report kind: ${currentSurfaceReport && currentSurfaceReport.kind}`);
    }
    closeReport = await closeOpenReport({
      repository: {
        repositoryId: currentSurfaceReport.repository.repositoryId,
        epoch: currentSurfaceReport.repository.epoch
      }
    });
    if (!closeReport || closeReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || closeReport.repositoryClosed !== true) {
      throw new Error("Installed Checkout workflow did not close the checked-out repository after evidence collection.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eCheckoutWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.checkoutRepository"
      },
      request,
      prompts: {
        url: {
          rendererCaptureExpectations: urlPrompt
        },
        targetPath: {
          rendererCaptureExpectations: targetPrompt
        },
        revision: {
          selected: "HEAD",
          rendererCaptureExpectations: revisionPrompt
        },
        depth: {
          selected: "Infinity",
          rendererCaptureExpectations: depthPrompt
        },
        externals: {
          selected: "Ignore externals",
          rendererCaptureExpectations: externalsPrompt
        }
      },
      target: {
        workingCopyRoot: targetWorkingCopyRoot,
        trackedPath,
        svnMetadataPath
      },
      currentSurfaceReport,
      closeReport,
      assertions: {
        commandExecuted: true,
        workingCopyCreated: trackedFileExists && svnMetadataExists,
        repositoryOpenedAfterCheckout: currentSurfaceReport.surfaceWorkflow.repositoryOpen === true,
        sourceControlProjectionAvailable:
          currentSurfaceReport.surfaceWorkflow.scmProjection === true &&
          currentSurfaceReport.surfaceWorkflow.sourceControlSurface === true,
        repositoryClosedAfterEvidence: closeReport.repositoryClosed === true
      }
    };
  } catch (error) {
    if (currentSurfaceReport && !closeReport) {
      try {
        await closeOpenReport({
          repository: {
            repositoryId: currentSurfaceReport.repository.repositoryId,
            epoch: currentSurfaceReport.repository.epoch
          }
        });
      } catch {
      }
    }
    throw error;
  }
}

function updateRevisionPromptCaptureExpectations(updateRevision, workingCopyRoot) {
  return {
    requiredDomTokens: ["Update SVN working copy to revision", "Enter the SVN revision number"],
    requiredAccessibilityTokens: ["Update SVN working copy to revision", "Enter the SVN revision number", "Revision number"],
    requiredScreenshot: true,
    inputText: String(updateRevision),
    submitKey: "Enter"
  };
}

function updateRevisionCancellationPromptCaptureExpectations() {
  return {
    requiredDomTokens: ["Update SVN working copy to revision", "Enter the SVN revision number"],
    requiredAccessibilityTokens: ["Update SVN working copy to revision", "Enter the SVN revision number", "Revision number"],
    requiredScreenshot: true,
    cancelSurface: "quickInput",
    cancelKey: "Escape"
  };
}

function updateQuickPickPromptCaptureExpectations(title, selectedText, requiredItems) {
  return {
    requiredDomTokens: [title, ...requiredItems],
    requiredAccessibilityTokens: [title, ...requiredItems],
    requiredScreenshot: true,
    quickPickItemText: selectedText
  };
}

function updateTargetFsPath(workingCopyRoot, relativePath) {
  return path.join(workingCopyRoot, ...relativePath.replace(/\\/g, "/").split("/").filter(segment => segment.length > 0));
}

async function runUpdateToRevisionCancellationWorkflow(updateWorkingCopyRoot, updateTargetRelativePath, promptPaths) {
  let openReport;
  let currentSurfaceReport;
  let closeReport;
  const targetPath = updateTargetFsPath(updateWorkingCopyRoot, updateTargetRelativePath);
  const expectedUpdatedContent = "updated by Beta-C r2\n";
  try {
    openReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: updateWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/updateToRevisionCancellation",
      60000
    );
    if (!openReport || openReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected installed Update to Revision cancellation open report kind: ${openReport && openReport.kind}`);
    }
    if (path.resolve(openReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(updateWorkingCopyRoot).toLowerCase()) {
      throw new Error("Installed Update to Revision cancellation open report workingCopyRoot did not match the fixture working copy.");
    }
    const initialContent = fs.readFileSync(targetPath, "utf8");
    if (initialContent === expectedUpdatedContent) {
      throw new Error("Installed Update to Revision cancellation fixture already contained the requested revision content before cancellation.");
    }

    const commandPromise = withTimeout(
      vscode.commands.executeCommand("subversionr.updateToRevision"),
      "subversionr.updateToRevision/cancelled",
      60000
    );
    await new Promise(resolve => setTimeout(resolve, 500));

    const revisionPrompt = updateRevisionCancellationPromptCaptureExpectations();
    await publishCheckoutPromptReadyAndWait(promptPaths.revisionReady, promptPaths.revisionDone, {
      ok: true,
      phase: "updateCancellationRevisionPromptReady",
      command: "subversionr.updateToRevision",
      repository: {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        workingCopyRoot: openReport.repository.identity.workingCopyRoot
      },
      prompt: {
        kind: "revision",
        cancelKey: "Escape",
        rendererCaptureExpectations: revisionPrompt
      },
      cancelKey: "Escape",
      rendererCaptureExpectations: revisionPrompt
    });

    await commandPromise;

    const contentAfterCancellation = fs.readFileSync(targetPath, "utf8");
    if (contentAfterCancellation !== initialContent) {
      throw new Error("Installed Update to Revision cancellation workflow changed the target file content after cancellation.");
    }

    currentSurfaceReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport", { path: updateWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport/updateToRevisionCancellation",
      30000
    );
    if (
      !currentSurfaceReport ||
      currentSurfaceReport.kind !== "subversionr.installedSourceControlUiE2eCurrentSurfaceReport" ||
      path.resolve(currentSurfaceReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(updateWorkingCopyRoot).toLowerCase()
    ) {
      throw new Error(`Unexpected installed Update to Revision cancellation current surface report kind: ${currentSurfaceReport && currentSurfaceReport.kind}`);
    }
    const sourceControlProjectionUnchanged =
      currentSurfaceReport.surfaceWorkflow.scmProjection === true &&
      currentSurfaceReport.surfaceWorkflow.sourceControlSurface === true &&
      sourceControlProjectionMatches(currentSurfaceReport, openReport);
    if (!sourceControlProjectionUnchanged) {
      throw new Error("Installed Update to Revision cancellation workflow changed the Source Control projection after cancellation.");
    }

    closeReport = await closeOpenReport(openReport);
    if (!closeReport || closeReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || closeReport.repositoryClosed !== true) {
      throw new Error("Installed Update to Revision cancellation workflow did not close the update cancellation repository.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eUpdateToRevisionCancellationWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.updateToRevision"
      },
      repository: {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        workingCopyRoot: openReport.repository.identity.workingCopyRoot
      },
      target: {
        workingCopyRoot: updateWorkingCopyRoot,
        relativePath: updateTargetRelativePath,
        path: targetPath,
        initialContent,
        contentAfterCancellation,
        expectedUpdatedContent
      },
      prompt: {
        cancelKey: "Escape",
        rendererCaptureExpectations: revisionPrompt
      },
      openReport,
      currentSurfaceReport,
      closeReport,
      assertions: {
        commandCancelled: true,
        targetContentUnchangedAfterCancellation: contentAfterCancellation === initialContent,
        requestedRevisionContentNotApplied: contentAfterCancellation !== expectedUpdatedContent,
        sourceControlProjectionUnchanged,
        repositoryClosedAfterEvidence: closeReport.repositoryClosed === true
      }
    };
  } catch (error) {
    if (openReport && !closeReport) {
      try {
        await closeOpenReport(openReport);
      } catch (closeError) {
        const primaryError = serializeError(error);
        const cleanupError = serializeError(closeError);
        const combinedError = new Error(`Installed Update to Revision cancellation workflow failed at ${primaryError.message}; cleanup close also failed: ${cleanupError.message}`);
        combinedError.primaryError = primaryError;
        combinedError.cleanupError = cleanupError;
        throw combinedError;
      }
    }
    throw error;
  }
}

async function runUpdateToRevisionWorkflow(updateWorkingCopyRoot, updateRevision, updateTargetRelativePath, promptPaths) {
  let openReport;
  let currentSurfaceReport;
  let closeReport;
  const request = {
    revision: updateRevision,
    depth: "files",
    depthIsSticky: true,
    ignoreExternals: false
  };
  const expectedUpdatedContent = "updated by Beta-C r2\n";
  const targetPath = updateTargetFsPath(updateWorkingCopyRoot, updateTargetRelativePath);
  try {
    openReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: updateWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/updateToRevision",
      60000
    );
    if (!openReport || openReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected installed Update to Revision open report kind: ${openReport && openReport.kind}`);
    }
    if (path.resolve(openReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(updateWorkingCopyRoot).toLowerCase()) {
      throw new Error("Installed Update to Revision open report workingCopyRoot did not match the fixture working copy.");
    }
    const initialContent = fs.readFileSync(targetPath, "utf8");
    if (initialContent === expectedUpdatedContent) {
      throw new Error("Installed Update to Revision fixture already contained the requested revision content before update.");
    }

    const commandPromise = withTimeout(
      vscode.commands.executeCommand("subversionr.updateToRevision"),
      "subversionr.updateToRevision",
      120000
    );
    await new Promise(resolve => setTimeout(resolve, 500));

    const revisionPrompt = updateRevisionPromptCaptureExpectations(updateRevision, updateWorkingCopyRoot);
    await publishCheckoutPromptReadyAndWait(promptPaths.revisionReady, promptPaths.revisionDone, {
      ok: true,
      phase: "updateRevisionPromptReady",
      command: "subversionr.updateToRevision",
      request,
      repository: {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        workingCopyRoot: openReport.repository.identity.workingCopyRoot
      },
      prompt: {
        kind: "revision",
        rendererCaptureExpectations: revisionPrompt
      },
      rendererCaptureExpectations: revisionPrompt
    });

    const depthPrompt = updateQuickPickPromptCaptureExpectations("SVN update depth", "Files", ["Working copy depth", "Empty", "Files", "Immediates", "Infinity"]);
    await publishCheckoutPromptReadyAndWait(promptPaths.depthReady, promptPaths.depthDone, {
      ok: true,
      phase: "updateDepthPromptReady",
      command: "subversionr.updateToRevision",
      request,
      prompt: {
        kind: "depth",
        selected: "Files",
        rendererCaptureExpectations: depthPrompt
      },
      rendererCaptureExpectations: depthPrompt
    });

    const stickyDepthPrompt = updateQuickPickPromptCaptureExpectations("SVN update sticky depth", "Make depth sticky", ["Keep depth non-sticky", "Make depth sticky"]);
    await publishCheckoutPromptReadyAndWait(promptPaths.stickyDepthReady, promptPaths.stickyDepthDone, {
      ok: true,
      phase: "updateStickyDepthPromptReady",
      command: "subversionr.updateToRevision",
      request,
      prompt: {
        kind: "stickyDepth",
        selected: "Make depth sticky",
        rendererCaptureExpectations: stickyDepthPrompt
      },
      rendererCaptureExpectations: stickyDepthPrompt
    });

    const externalsPrompt = updateQuickPickPromptCaptureExpectations("SVN update externals", "Include externals", ["Ignore externals", "Include externals"]);
    await publishCheckoutPromptReadyAndWait(promptPaths.externalsReady, promptPaths.externalsDone, {
      ok: true,
      phase: "updateExternalsPromptReady",
      command: "subversionr.updateToRevision",
      request,
      prompt: {
        kind: "externals",
        selected: "Include externals",
        rendererCaptureExpectations: externalsPrompt
      },
      rendererCaptureExpectations: externalsPrompt
    });

    await commandPromise;

    const updatedContent = fs.readFileSync(targetPath, "utf8");
    if (updatedContent !== expectedUpdatedContent) {
      throw new Error(`Installed Update to Revision workflow expected ${targetPath} to contain requested r${updateRevision} content.`);
    }
    currentSurfaceReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport", { path: updateWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport/updateToRevision",
      30000
    );
    if (
      !currentSurfaceReport ||
      currentSurfaceReport.kind !== "subversionr.installedSourceControlUiE2eCurrentSurfaceReport" ||
      path.resolve(currentSurfaceReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(updateWorkingCopyRoot).toLowerCase()
    ) {
      throw new Error(`Unexpected installed Update to Revision current surface report kind: ${currentSurfaceReport && currentSurfaceReport.kind}`);
    }
    closeReport = await closeOpenReport(openReport);
    if (!closeReport || closeReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || closeReport.repositoryClosed !== true) {
      throw new Error("Installed Update to Revision workflow did not close the updated repository after evidence collection.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eUpdateToRevisionWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.updateToRevision"
      },
      repository: {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        workingCopyRoot: openReport.repository.identity.workingCopyRoot
      },
      request,
      prompts: {
        revision: {
          rendererCaptureExpectations: revisionPrompt
        },
        depth: {
          selected: "Files",
          rendererCaptureExpectations: depthPrompt
        },
        stickyDepth: {
          selected: "Make depth sticky",
          rendererCaptureExpectations: stickyDepthPrompt
        },
        externals: {
          selected: "Include externals",
          rendererCaptureExpectations: externalsPrompt
        }
      },
      target: {
        workingCopyRoot: updateWorkingCopyRoot,
        relativePath: updateTargetRelativePath,
        path: targetPath,
        expectedUpdatedContent,
        initialContent,
        updatedContent
      },
      openReport,
      currentSurfaceReport,
      closeReport,
      assertions: {
        commandExecuted: true,
        updatedRevisionContentApplied: updatedContent === expectedUpdatedContent,
        sparseStickyDepthRequested: request.depth === "files" && request.depthIsSticky === true,
        externalsIncluded: request.ignoreExternals === false,
        postUpdateReconcileCompleted: typeof currentSurfaceReport.sourceControl.generation === "number",
        sourceControlProjectionAvailable:
          currentSurfaceReport.surfaceWorkflow.scmProjection === true &&
          currentSurfaceReport.surfaceWorkflow.sourceControlSurface === true,
        repositoryClosedAfterEvidence: closeReport.repositoryClosed === true
      }
    };
  } catch (error) {
    if (openReport && !closeReport) {
      try {
        await closeOpenReport(openReport);
      } catch (closeError) {
        const primaryError = serializeError(error);
        const cleanupError = serializeError(closeError);
        const combinedError = new Error(`Installed Update to Revision workflow failed at ${primaryError.message}; cleanup close also failed: ${cleanupError.message}`);
        combinedError.primaryError = primaryError;
        combinedError.cleanupError = cleanupError;
        throw combinedError;
      }
    }
    throw error;
  }
}

function branchCreateInputPromptCaptureExpectations(title, promptToken, inputText) {
  return {
    requiredDomTokens: [title, promptToken],
    requiredAccessibilityTokens: [title, promptToken],
    requiredScreenshot: true,
    inputText,
    submitKey: "Enter"
  };
}

function branchCreateQuickPickPromptCaptureExpectations(title, selectedText, requiredItems) {
  return {
    requiredDomTokens: [title, ...requiredItems],
    requiredAccessibilityTokens: [title, ...requiredItems],
    requiredScreenshot: true,
    quickPickItemText: selectedText
  };
}

async function runBranchCreateWorkflow(branchCreateWorkingCopyRoot, sourceUrl, destinationUrl, message, promptPaths) {
  let openReport;
  let closeReport;
  const request = {
    sourceUrl,
    destinationUrl,
    revision: "head",
    message,
    makeParents: false,
    ignoreExternals: true
  };
  try {
    openReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: branchCreateWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/branchCreate",
      60000
    );
    if (!openReport || openReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected installed Branch/Tag create open report kind: ${openReport && openReport.kind}`);
    }
    if (path.resolve(openReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(branchCreateWorkingCopyRoot).toLowerCase()) {
      throw new Error("Installed Branch/Tag create open report workingCopyRoot did not match the fixture working copy.");
    }

    const commandPromise = withTimeout(
      vscode.commands.executeCommand("subversionr.branchCreateRepository"),
      "subversionr.branchCreateRepository",
      120000
    );
    await new Promise(resolve => setTimeout(resolve, 500));

    const sourcePrompt = branchCreateInputPromptCaptureExpectations("Create SVN branch or tag", "Enter the SVN source URL", sourceUrl);
    await publishCheckoutPromptReadyAndWait(promptPaths.sourceReady, promptPaths.sourceDone, {
      ok: true,
      phase: "branchCreateSourcePromptReady",
      command: "subversionr.branchCreateRepository",
      request,
      prompt: {
        kind: "sourceUrl",
        rendererCaptureExpectations: sourcePrompt
      },
      rendererCaptureExpectations: sourcePrompt
    });

    const destinationPrompt = branchCreateInputPromptCaptureExpectations("SVN branch or tag destination", "Enter the SVN destination URL.", destinationUrl);
    await publishCheckoutPromptReadyAndWait(promptPaths.destinationReady, promptPaths.destinationDone, {
      ok: true,
      phase: "branchCreateDestinationPromptReady",
      command: "subversionr.branchCreateRepository",
      request,
      prompt: {
        kind: "destinationUrl",
        rendererCaptureExpectations: destinationPrompt
      },
      rendererCaptureExpectations: destinationPrompt
    });

    const revisionPrompt = branchCreateQuickPickPromptCaptureExpectations("SVN branch or tag source revision", "HEAD", ["HEAD", "Revision number"]);
    await publishCheckoutPromptReadyAndWait(promptPaths.revisionReady, promptPaths.revisionDone, {
      ok: true,
      phase: "branchCreateRevisionPromptReady",
      command: "subversionr.branchCreateRepository",
      request,
      prompt: {
        kind: "revision",
        selected: "HEAD",
        rendererCaptureExpectations: revisionPrompt
      },
      rendererCaptureExpectations: revisionPrompt
    });

    const messagePrompt = branchCreateInputPromptCaptureExpectations("SVN branch or tag log message", "Enter the SVN log message for the copy commit.", message);
    await publishCheckoutPromptReadyAndWait(promptPaths.messageReady, promptPaths.messageDone, {
      ok: true,
      phase: "branchCreateMessagePromptReady",
      command: "subversionr.branchCreateRepository",
      request,
      prompt: {
        kind: "message",
        rendererCaptureExpectations: messagePrompt
      },
      rendererCaptureExpectations: messagePrompt
    });

    const parentsPrompt = branchCreateQuickPickPromptCaptureExpectations("SVN branch or tag parents", "Require destination parent", ["Require destination parent", "Create destination parents"]);
    await publishCheckoutPromptReadyAndWait(promptPaths.parentsReady, promptPaths.parentsDone, {
      ok: true,
      phase: "branchCreateParentsPromptReady",
      command: "subversionr.branchCreateRepository",
      request,
      prompt: {
        kind: "parents",
        selected: "Require destination parent",
        rendererCaptureExpectations: parentsPrompt
      },
      rendererCaptureExpectations: parentsPrompt
    });

    const externalsPrompt = branchCreateQuickPickPromptCaptureExpectations("SVN branch or tag externals", "Ignore externals", ["Ignore externals", "Include externals"]);
    await publishCheckoutPromptReadyAndWait(promptPaths.externalsReady, promptPaths.externalsDone, {
      ok: true,
      phase: "branchCreateExternalsPromptReady",
      command: "subversionr.branchCreateRepository",
      request,
      prompt: {
        kind: "externals",
        selected: "Ignore externals",
        rendererCaptureExpectations: externalsPrompt
      },
      rendererCaptureExpectations: externalsPrompt
    });

    const switchPrompt = branchCreateQuickPickPromptCaptureExpectations("SVN branch/tag switch", "Stay on the current SVN URL", ["Stay on the current SVN URL", "Create the branch or tag without switching this working copy", "Switch this working copy to the new branch/tag"]);
    await publishCheckoutPromptReadyAndWait(promptPaths.switchReady, promptPaths.switchDone, {
      ok: true,
      phase: "branchCreateSwitchPromptReady",
      command: "subversionr.branchCreateRepository",
      request,
      prompt: {
        kind: "switchAfterCreate",
        selected: "Stay on the current SVN URL",
        switchAfterCreate: false,
        rendererCaptureExpectations: switchPrompt
      },
      rendererCaptureExpectations: switchPrompt
    });

    await commandPromise;

    closeReport = await closeOpenReport(openReport);
    if (!closeReport || closeReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || closeReport.repositoryClosed !== true) {
      throw new Error("Installed Branch/Tag create workflow did not close the repository after evidence collection.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eBranchCreateWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.branchCreateRepository"
      },
      repository: {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        workingCopyRoot: openReport.repository.identity.workingCopyRoot
      },
      request,
      prompts: {
        sourceUrl: {
          rendererCaptureExpectations: sourcePrompt
        },
        destinationUrl: {
          rendererCaptureExpectations: destinationPrompt
        },
        revision: {
          selected: "HEAD",
          rendererCaptureExpectations: revisionPrompt
        },
        message: {
          rendererCaptureExpectations: messagePrompt
        },
        parents: {
          selected: "Require destination parent",
          rendererCaptureExpectations: parentsPrompt
        },
        externals: {
          selected: "Ignore externals",
          rendererCaptureExpectations: externalsPrompt
        },
        switchAfterCreate: {
          selected: "Stay on the current SVN URL",
          switchAfterCreate: false,
          rendererCaptureExpectations: switchPrompt
        }
      },
      openReport,
      closeReport,
      assertions: {
        commandExecuted: true,
        branchCreatedInRepository: true,
        noLocalReconcileClaimed: true,
        repositoryClosedAfterEvidence: closeReport.repositoryClosed === true
      }
    };
  } catch (error) {
    if (openReport && !closeReport) {
      try {
        await closeOpenReport(openReport);
      } catch {
      }
    }
    throw error;
  }
}

function switchInputPromptCaptureExpectations(targetUrl) {
  return {
    requiredDomTokens: ["Switch SVN working copy", "Enter the SVN URL to switch"],
    requiredAccessibilityTokens: ["Switch SVN working copy", "Enter the SVN URL to switch"],
    requiredScreenshot: true,
    inputText: targetUrl,
    submitKey: "Enter"
  };
}

function switchQuickPickPromptCaptureExpectations(title, selectedText, requiredItems) {
  return {
    requiredDomTokens: [title, ...requiredItems],
    requiredAccessibilityTokens: [title, ...requiredItems],
    requiredScreenshot: true,
    quickPickItemText: selectedText
  };
}

async function runSwitchWorkflow(switchWorkingCopyRoot, targetUrl, promptPaths) {
  let openReport;
  let currentSurfaceReport;
  let closeReport;
  const request = {
    url: targetUrl,
    revision: "head",
    depth: "infinity",
    depthIsSticky: true,
    ignoreExternals: true,
    ignoreAncestry: false
  };
  try {
    openReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: switchWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/switch",
      60000
    );
    if (!openReport || openReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected installed Switch open report kind: ${openReport && openReport.kind}`);
    }
    if (path.resolve(openReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(switchWorkingCopyRoot).toLowerCase()) {
      throw new Error("Installed Switch open report workingCopyRoot did not match the fixture working copy.");
    }

    const commandPromise = withTimeout(
      vscode.commands.executeCommand("subversionr.switchRepository"),
      "subversionr.switchRepository",
      120000
    );
    await new Promise(resolve => setTimeout(resolve, 500));

    const urlPrompt = switchInputPromptCaptureExpectations(targetUrl);
    await publishCheckoutPromptReadyAndWait(promptPaths.urlReady, promptPaths.urlDone, {
      ok: true,
      phase: "switchUrlPromptReady",
      command: "subversionr.switchRepository",
      request,
      prompt: {
        kind: "url",
        rendererCaptureExpectations: urlPrompt
      },
      rendererCaptureExpectations: urlPrompt
    });

    const revisionPrompt = switchQuickPickPromptCaptureExpectations("SVN switch revision", "HEAD", ["HEAD", "Revision number"]);
    await publishCheckoutPromptReadyAndWait(promptPaths.revisionReady, promptPaths.revisionDone, {
      ok: true,
      phase: "switchRevisionPromptReady",
      command: "subversionr.switchRepository",
      request,
      prompt: {
        kind: "revision",
        selected: "HEAD",
        rendererCaptureExpectations: revisionPrompt
      },
      rendererCaptureExpectations: revisionPrompt
    });

    const depthPrompt = switchQuickPickPromptCaptureExpectations("SVN switch depth", "Infinity", ["Working copy depth", "Empty", "Files", "Immediates", "Infinity"]);
    await publishCheckoutPromptReadyAndWait(promptPaths.depthReady, promptPaths.depthDone, {
      ok: true,
      phase: "switchDepthPromptReady",
      command: "subversionr.switchRepository",
      request,
      prompt: {
        kind: "depth",
        selected: "Infinity",
        rendererCaptureExpectations: depthPrompt
      },
      rendererCaptureExpectations: depthPrompt
    });

    const stickyDepthPrompt = switchQuickPickPromptCaptureExpectations("SVN switch sticky depth", "Make depth sticky", ["Keep depth non-sticky", "Make depth sticky"]);
    await publishCheckoutPromptReadyAndWait(promptPaths.stickyDepthReady, promptPaths.stickyDepthDone, {
      ok: true,
      phase: "switchStickyDepthPromptReady",
      command: "subversionr.switchRepository",
      request,
      prompt: {
        kind: "stickyDepth",
        selected: "Make depth sticky",
        rendererCaptureExpectations: stickyDepthPrompt
      },
      rendererCaptureExpectations: stickyDepthPrompt
    });

    const externalsPrompt = switchQuickPickPromptCaptureExpectations("SVN switch externals", "Ignore externals", ["Ignore externals", "Include externals"]);
    await publishCheckoutPromptReadyAndWait(promptPaths.externalsReady, promptPaths.externalsDone, {
      ok: true,
      phase: "switchExternalsPromptReady",
      command: "subversionr.switchRepository",
      request,
      prompt: {
        kind: "externals",
        selected: "Ignore externals",
        rendererCaptureExpectations: externalsPrompt
      },
      rendererCaptureExpectations: externalsPrompt
    });

    const ancestryPrompt = switchQuickPickPromptCaptureExpectations("SVN switch ancestry", "Check ancestry", ["Check ancestry", "Ignore ancestry"]);
    await publishCheckoutPromptReadyAndWait(promptPaths.ancestryReady, promptPaths.ancestryDone, {
      ok: true,
      phase: "switchAncestryPromptReady",
      command: "subversionr.switchRepository",
      request,
      prompt: {
        kind: "ancestry",
        selected: "Check ancestry",
        rendererCaptureExpectations: ancestryPrompt
      },
      rendererCaptureExpectations: ancestryPrompt
    });

    await commandPromise;

    currentSurfaceReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport", { path: switchWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport/switch",
      30000
    );
    if (
      !currentSurfaceReport ||
      currentSurfaceReport.kind !== "subversionr.installedSourceControlUiE2eCurrentSurfaceReport" ||
      path.resolve(currentSurfaceReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(switchWorkingCopyRoot).toLowerCase()
    ) {
      throw new Error(`Unexpected installed Switch current surface report kind: ${currentSurfaceReport && currentSurfaceReport.kind}`);
    }
    const postSwitchGenerationAdvanced =
      typeof openReport.sourceControl.generation === "number" &&
      typeof currentSurfaceReport.sourceControl.generation === "number" &&
      currentSurfaceReport.sourceControl.generation > openReport.sourceControl.generation;
    if (!postSwitchGenerationAdvanced) {
      throw new Error(
        `Installed Switch workflow expected Source Control generation to advance after switch, got before=${openReport.sourceControl.generation}, after=${currentSurfaceReport.sourceControl.generation}.`
      );
    }
    const postSwitchRepositoryIdentityPreserved =
      currentSurfaceReport.repository.repositoryId === openReport.repository.repositoryId &&
      currentSurfaceReport.repository.epoch === openReport.repository.epoch;
    if (!postSwitchRepositoryIdentityPreserved) {
      throw new Error("Installed Switch workflow current surface report did not preserve the opened repository identity after switch.");
    }
    closeReport = await closeOpenReport(openReport);
    if (!closeReport || closeReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || closeReport.repositoryClosed !== true) {
      throw new Error("Installed Switch workflow did not close the switched repository after evidence collection.");
    }

    return {
      kind: "subversionr.installedSourceControlUiE2eSwitchWorkflow",
      generatedAt: new Date().toISOString(),
      command: {
        command: "subversionr.switchRepository"
      },
      repository: {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        workingCopyRoot: openReport.repository.identity.workingCopyRoot
      },
      request,
      prompts: {
        url: {
          rendererCaptureExpectations: urlPrompt
        },
        revision: {
          selected: "HEAD",
          rendererCaptureExpectations: revisionPrompt
        },
        depth: {
          selected: "Infinity",
          rendererCaptureExpectations: depthPrompt
        },
        stickyDepth: {
          selected: "Make depth sticky",
          rendererCaptureExpectations: stickyDepthPrompt
        },
        externals: {
          selected: "Ignore externals",
          rendererCaptureExpectations: externalsPrompt
        },
        ancestry: {
          selected: "Check ancestry",
          rendererCaptureExpectations: ancestryPrompt
        }
      },
      openReport,
      currentSurfaceReport,
      closeReport,
      assertions: {
        commandExecuted: true,
        postSwitchReconcileCompleted: typeof currentSurfaceReport.sourceControl.generation === "number",
        postSwitchGenerationAdvanced,
        postSwitchRepositoryIdentityPreserved,
        sourceControlProjectionAvailable:
          currentSurfaceReport.surfaceWorkflow.scmProjection === true &&
          currentSurfaceReport.surfaceWorkflow.sourceControlSurface === true,
        repositoryClosedAfterEvidence: closeReport.repositoryClosed === true
      }
    };
  } catch (error) {
    if (openReport && !closeReport) {
      try {
        await closeOpenReport(openReport);
      } catch {
      }
    }
    throw error;
  }
}

async function closeOpenReport(openReport) {
  if (!openReport) {
    return undefined;
  }
  return withTimeout(
    vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eCloseReport", {
      repositoryId: openReport.repository.repositoryId,
      epoch: openReport.repository.epoch
    }),
    "subversionr.diagnostics.installedSourceControlUiE2eCloseReport",
    30000
  );
}

async function run() {
  const resultPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESULT;
  const readyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_READY;
  const donePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_DONE;
  const noRepositoryWelcomeRendererReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_NO_REPOSITORY_WELCOME_RENDERER_READY;
  const noRepositoryWelcomeRendererDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_NO_REPOSITORY_WELCOME_RENDERER_DONE;
  const partialFreshnessRendererReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_PARTIAL_FRESHNESS_RENDERER_READY;
  const partialFreshnessRendererDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_PARTIAL_FRESHNESS_RENDERER_DONE;
  const staleFreshnessRendererReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_STALE_FRESHNESS_RENDERER_READY;
  const staleFreshnessRendererDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_STALE_FRESHNESS_RENDERER_DONE;
  const fullReconcileCancellationReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_FULL_RECONCILE_CANCELLATION_READY;
  const fullReconcileCancellationDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_FULL_RECONCILE_CANCELLATION_DONE;
  const multiRepositoryRefreshPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MULTI_REPOSITORY_REFRESH_PROMPT_READY;
  const deletePromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_DELETE_PROMPT_READY;
  const deleteLoadPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_DELETE_LOAD_PROMPT_READY;
  const removePromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REMOVE_PROMPT_READY;
  const removeCancellationPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REMOVE_CANCELLATION_PROMPT_READY;
  const removeCancellationPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REMOVE_CANCELLATION_PROMPT_DONE;
  const removeKeepLocalPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REMOVE_KEEP_LOCAL_PROMPT_READY;
  const movePromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MOVE_PROMPT_READY;
  const moveCancellationPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MOVE_CANCELLATION_PROMPT_READY;
  const checkoutCancellationPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_CANCELLATION_PROMPT_READY;
  const checkoutCancellationPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_CANCELLATION_PROMPT_DONE;
  const checkoutExistingTargetFailureUrlPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_URL_PROMPT_READY;
  const checkoutExistingTargetFailureUrlPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_URL_PROMPT_DONE;
  const checkoutExistingTargetFailureTargetPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_TARGET_PROMPT_READY;
  const checkoutExistingTargetFailureTargetPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_TARGET_PROMPT_DONE;
  const checkoutExistingTargetFailureRevisionPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_REVISION_PROMPT_READY;
  const checkoutExistingTargetFailureRevisionPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_REVISION_PROMPT_DONE;
  const checkoutExistingTargetFailureDepthPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_DEPTH_PROMPT_READY;
  const checkoutExistingTargetFailureDepthPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_DEPTH_PROMPT_DONE;
  const checkoutExistingTargetFailureExternalsPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_EXTERNALS_PROMPT_READY;
  const checkoutExistingTargetFailureExternalsPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_EXTERNALS_PROMPT_DONE;
  const checkoutExistingTargetFailureNotificationReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_NOTIFICATION_READY;
  const checkoutExistingTargetFailureNotificationDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_NOTIFICATION_DONE;
  const checkoutInvalidUrlFailureUrlPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_URL_PROMPT_READY;
  const checkoutInvalidUrlFailureUrlPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_URL_PROMPT_DONE;
  const checkoutInvalidUrlFailureTargetPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_TARGET_PROMPT_READY;
  const checkoutInvalidUrlFailureTargetPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_TARGET_PROMPT_DONE;
  const checkoutInvalidUrlFailureRevisionPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_REVISION_PROMPT_READY;
  const checkoutInvalidUrlFailureRevisionPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_REVISION_PROMPT_DONE;
  const checkoutInvalidUrlFailureDepthPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_DEPTH_PROMPT_READY;
  const checkoutInvalidUrlFailureDepthPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_DEPTH_PROMPT_DONE;
  const checkoutInvalidUrlFailureExternalsPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_EXTERNALS_PROMPT_READY;
  const checkoutInvalidUrlFailureExternalsPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_EXTERNALS_PROMPT_DONE;
  const checkoutInvalidUrlFailureNotificationReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_NOTIFICATION_READY;
  const checkoutInvalidUrlFailureNotificationDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_NOTIFICATION_DONE;
  const checkoutExistingDirectoryUrlPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_URL_PROMPT_READY;
  const checkoutExistingDirectoryUrlPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_URL_PROMPT_DONE;
  const checkoutExistingDirectoryTargetPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_TARGET_PROMPT_READY;
  const checkoutExistingDirectoryTargetPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_TARGET_PROMPT_DONE;
  const checkoutExistingDirectoryRevisionPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_REVISION_PROMPT_READY;
  const checkoutExistingDirectoryRevisionPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_REVISION_PROMPT_DONE;
  const checkoutExistingDirectoryDepthPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_DEPTH_PROMPT_READY;
  const checkoutExistingDirectoryDepthPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_DEPTH_PROMPT_DONE;
  const checkoutExistingDirectoryExternalsPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_EXTERNALS_PROMPT_READY;
  const checkoutExistingDirectoryExternalsPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_EXTERNALS_PROMPT_DONE;
  const checkoutExistingDirectoryObstructionUrlPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_URL_PROMPT_READY;
  const checkoutExistingDirectoryObstructionUrlPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_URL_PROMPT_DONE;
  const checkoutExistingDirectoryObstructionTargetPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_TARGET_PROMPT_READY;
  const checkoutExistingDirectoryObstructionTargetPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_TARGET_PROMPT_DONE;
  const checkoutExistingDirectoryObstructionRevisionPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_REVISION_PROMPT_READY;
  const checkoutExistingDirectoryObstructionRevisionPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_REVISION_PROMPT_DONE;
  const checkoutExistingDirectoryObstructionDepthPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_DEPTH_PROMPT_READY;
  const checkoutExistingDirectoryObstructionDepthPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_DEPTH_PROMPT_DONE;
  const checkoutExistingDirectoryObstructionExternalsPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_EXTERNALS_PROMPT_READY;
  const checkoutExistingDirectoryObstructionExternalsPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_EXTERNALS_PROMPT_DONE;
  const checkoutUrlPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_URL_PROMPT_READY;
  const checkoutUrlPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_URL_PROMPT_DONE;
  const checkoutTargetPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_TARGET_PROMPT_READY;
  const checkoutTargetPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_TARGET_PROMPT_DONE;
  const checkoutRevisionPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_REVISION_PROMPT_READY;
  const checkoutRevisionPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_REVISION_PROMPT_DONE;
  const checkoutDepthPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_DEPTH_PROMPT_READY;
  const checkoutDepthPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_DEPTH_PROMPT_DONE;
  const checkoutExternalsPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXTERNALS_PROMPT_READY;
  const checkoutExternalsPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXTERNALS_PROMPT_DONE;
  const updateRevisionPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_REVISION_PROMPT_READY;
  const updateRevisionPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_REVISION_PROMPT_DONE;
  const updateCancellationRevisionPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_CANCELLATION_REVISION_PROMPT_READY;
  const updateCancellationRevisionPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_CANCELLATION_REVISION_PROMPT_DONE;
  const updateDepthPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_DEPTH_PROMPT_READY;
  const updateDepthPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_DEPTH_PROMPT_DONE;
  const updateStickyDepthPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_STICKY_DEPTH_PROMPT_READY;
  const updateStickyDepthPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_STICKY_DEPTH_PROMPT_DONE;
  const updateExternalsPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_EXTERNALS_PROMPT_READY;
  const updateExternalsPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_EXTERNALS_PROMPT_DONE;
  const branchCreateSourcePromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_SOURCE_PROMPT_READY;
  const branchCreateSourcePromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_SOURCE_PROMPT_DONE;
  const branchCreateDestinationPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_DESTINATION_PROMPT_READY;
  const branchCreateDestinationPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_DESTINATION_PROMPT_DONE;
  const branchCreateRevisionPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_REVISION_PROMPT_READY;
  const branchCreateRevisionPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_REVISION_PROMPT_DONE;
  const branchCreateMessagePromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_MESSAGE_PROMPT_READY;
  const branchCreateMessagePromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_MESSAGE_PROMPT_DONE;
  const branchCreateParentsPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_PARENTS_PROMPT_READY;
  const branchCreateParentsPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_PARENTS_PROMPT_DONE;
  const branchCreateExternalsPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_EXTERNALS_PROMPT_READY;
  const branchCreateExternalsPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_EXTERNALS_PROMPT_DONE;
  const branchCreateSwitchPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_SWITCH_PROMPT_READY;
  const branchCreateSwitchPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_SWITCH_PROMPT_DONE;
  const switchUrlPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_URL_PROMPT_READY;
  const switchUrlPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_URL_PROMPT_DONE;
  const switchRevisionPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_REVISION_PROMPT_READY;
  const switchRevisionPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_REVISION_PROMPT_DONE;
  const switchDepthPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_DEPTH_PROMPT_READY;
  const switchDepthPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_DEPTH_PROMPT_DONE;
  const switchStickyDepthPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_STICKY_DEPTH_PROMPT_READY;
  const switchStickyDepthPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_STICKY_DEPTH_PROMPT_DONE;
  const switchExternalsPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_EXTERNALS_PROMPT_READY;
  const switchExternalsPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_EXTERNALS_PROMPT_DONE;
  const switchAncestryPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_ANCESTRY_PROMPT_READY;
  const switchAncestryPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_ANCESTRY_PROMPT_DONE;
  const lockMessageCancellationPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MESSAGE_CANCELLATION_PROMPT_READY;
  const lockMessageCancellationPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MESSAGE_CANCELLATION_PROMPT_DONE;
  const lockMessagePromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MESSAGE_PROMPT_READY;
  const lockMessagePromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MESSAGE_PROMPT_DONE;
  const lockModePromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MODE_PROMPT_READY;
  const lockModePromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MODE_PROMPT_DONE;
  const lockHeldOracleReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_HELD_ORACLE_READY;
  const lockHeldOracleDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_HELD_ORACLE_DONE;
  const unlockModeCancellationPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UNLOCK_MODE_CANCELLATION_PROMPT_READY;
  const unlockModeCancellationPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UNLOCK_MODE_CANCELLATION_PROMPT_DONE;
  const unlockModePromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UNLOCK_MODE_PROMPT_READY;
  const unlockModePromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UNLOCK_MODE_PROMPT_DONE;
  const changelistSetPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHANGELIST_SET_PROMPT_READY;
  const changelistRevertPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHANGELIST_REVERT_PROMPT_READY;
  const revertPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_PROMPT_READY;
  const revertCancellationPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_CANCELLATION_PROMPT_READY;
  const revertCancellationPromptDonePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_CANCELLATION_PROMPT_DONE;
  const resolvePromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESOLVE_PROMPT_READY;
  const resolveCancellationPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESOLVE_CANCELLATION_PROMPT_READY;
  const cleanupPromptReadyPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CLEANUP_PROMPT_READY;
  const extensionsRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_EXTENSIONS_ROOT;
  const workingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_WORKING_COPY;
  const multiRepositoryRefreshWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MULTI_REPOSITORY_REFRESH_WORKING_COPY;
  const lazyExternalProviderWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LAZY_EXTERNAL_PROVIDER_WORKING_COPY;
  const boundaryLoadWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BOUNDARY_LOAD_WORKING_COPY;
  const boundaryLoadParentModifiedItemCount = Number.parseInt(process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BOUNDARY_LOAD_PARENT_MODIFIED_ITEM_COUNT || "", 10);
  const boundaryLoadBoundaryModifiedItemCount = Number.parseInt(process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BOUNDARY_LOAD_BOUNDARY_MODIFIED_ITEM_COUNT || "", 10);
  const refreshLoadWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REFRESH_LOAD_WORKING_COPY;
  const refreshLoadItemCount = Number.parseInt(process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REFRESH_LOAD_ITEM_COUNT || "", 10);
  const loadWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOAD_WORKING_COPY;
  const loadItemCount = Number.parseInt(process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOAD_ITEM_COUNT || "", 10);
  const commitAllWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_COMMIT_ALL_WORKING_COPY;
  const commitSelectedWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_COMMIT_SELECTED_WORKING_COPY;
  const commitSelectedMultiSelectionWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_COMMIT_SELECTED_MULTI_SELECTION_WORKING_COPY;
  const checkoutRepositoryUrl = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_URL;
  const checkoutCancellationTargetWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_CANCELLATION_TARGET_WORKING_COPY;
  const checkoutExistingTargetFailureTargetPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_TARGET_PATH;
  const checkoutInvalidUrlFailureRepositoryUrl = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_URL;
  const checkoutInvalidUrlFailureTargetWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_TARGET_WORKING_COPY;
  const checkoutExistingDirectoryTargetWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_TARGET_WORKING_COPY;
  const checkoutExistingDirectoryObstructionTargetWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_TARGET_WORKING_COPY;
  const checkoutTargetWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_TARGET_WORKING_COPY;
  const updateWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_WORKING_COPY;
  const updateRevisionText = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_REVISION;
  const updateTargetRelativePath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_TARGET_RELATIVE_PATH;
  const branchCreateWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_WORKING_COPY;
  const branchCreateSourceUrl = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_SOURCE_URL;
  const branchCreateDestinationUrl = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_DESTINATION_URL;
  const branchCreateMessage = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_MESSAGE;
  const switchWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_WORKING_COPY;
  const switchTargetUrl = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_TARGET_URL;
  const addWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_ADD_WORKING_COPY;
  const addToIgnoreWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_ADD_TO_IGNORE_WORKING_COPY;
  const lockWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_WORKING_COPY;
  const changelistSetClearWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHANGELIST_SET_CLEAR_WORKING_COPY;
  const commitChangelistWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_COMMIT_CHANGELIST_WORKING_COPY;
  const revertChangelistWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_CHANGELIST_WORKING_COPY;
  const moveResourceWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MOVE_WORKING_COPY;
  const moveCancellationWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MOVE_CANCELLATION_WORKING_COPY;
  const removeWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REMOVE_WORKING_COPY;
  const removeCancellationWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REMOVE_CANCELLATION_WORKING_COPY;
  const revertWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_WORKING_COPY;
  const revertCancellationWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_CANCELLATION_WORKING_COPY;
  const resolveWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESOLVE_WORKING_COPY;
  const resolveCancellationWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESOLVE_CANCELLATION_WORKING_COPY;
  const deleteWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_REPOSITORY_LIFECYCLE_DELETE_WORKING_COPY;
  const moveWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_REPOSITORY_LIFECYCLE_MOVE_WORKING_COPY;
  const moveDestinationRoot = process.env.SUBVERSIONR_INSTALLED_REPOSITORY_LIFECYCLE_MOVE_DESTINATION;
  if (
    !resultPath ||
    !readyPath ||
    !donePath ||
    !noRepositoryWelcomeRendererReadyPath ||
    !noRepositoryWelcomeRendererDonePath ||
    !partialFreshnessRendererReadyPath ||
    !partialFreshnessRendererDonePath ||
    !staleFreshnessRendererReadyPath ||
    !staleFreshnessRendererDonePath ||
    !fullReconcileCancellationReadyPath ||
    !fullReconcileCancellationDonePath ||
    !multiRepositoryRefreshPromptReadyPath ||
    !deletePromptReadyPath ||
    !deleteLoadPromptReadyPath ||
    !removePromptReadyPath ||
    !removeCancellationPromptReadyPath ||
    !removeCancellationPromptDonePath ||
    !removeKeepLocalPromptReadyPath ||
    !movePromptReadyPath ||
    !moveCancellationPromptReadyPath ||
    !checkoutCancellationPromptReadyPath ||
    !checkoutCancellationPromptDonePath ||
    !checkoutExistingTargetFailureUrlPromptReadyPath ||
    !checkoutExistingTargetFailureUrlPromptDonePath ||
    !checkoutExistingTargetFailureTargetPromptReadyPath ||
    !checkoutExistingTargetFailureTargetPromptDonePath ||
    !checkoutExistingTargetFailureRevisionPromptReadyPath ||
    !checkoutExistingTargetFailureRevisionPromptDonePath ||
    !checkoutExistingTargetFailureDepthPromptReadyPath ||
    !checkoutExistingTargetFailureDepthPromptDonePath ||
    !checkoutExistingTargetFailureExternalsPromptReadyPath ||
    !checkoutExistingTargetFailureExternalsPromptDonePath ||
    !checkoutExistingTargetFailureNotificationReadyPath ||
    !checkoutExistingTargetFailureNotificationDonePath ||
    !checkoutInvalidUrlFailureUrlPromptReadyPath ||
    !checkoutInvalidUrlFailureUrlPromptDonePath ||
    !checkoutInvalidUrlFailureTargetPromptReadyPath ||
    !checkoutInvalidUrlFailureTargetPromptDonePath ||
    !checkoutInvalidUrlFailureRevisionPromptReadyPath ||
    !checkoutInvalidUrlFailureRevisionPromptDonePath ||
    !checkoutInvalidUrlFailureDepthPromptReadyPath ||
    !checkoutInvalidUrlFailureDepthPromptDonePath ||
    !checkoutInvalidUrlFailureExternalsPromptReadyPath ||
    !checkoutInvalidUrlFailureExternalsPromptDonePath ||
    !checkoutInvalidUrlFailureNotificationReadyPath ||
    !checkoutInvalidUrlFailureNotificationDonePath ||
    !checkoutExistingDirectoryUrlPromptReadyPath ||
    !checkoutExistingDirectoryUrlPromptDonePath ||
    !checkoutExistingDirectoryTargetPromptReadyPath ||
    !checkoutExistingDirectoryTargetPromptDonePath ||
    !checkoutExistingDirectoryRevisionPromptReadyPath ||
    !checkoutExistingDirectoryRevisionPromptDonePath ||
    !checkoutExistingDirectoryDepthPromptReadyPath ||
    !checkoutExistingDirectoryDepthPromptDonePath ||
    !checkoutExistingDirectoryExternalsPromptReadyPath ||
    !checkoutExistingDirectoryExternalsPromptDonePath ||
    !checkoutExistingDirectoryObstructionUrlPromptReadyPath ||
    !checkoutExistingDirectoryObstructionUrlPromptDonePath ||
    !checkoutExistingDirectoryObstructionTargetPromptReadyPath ||
    !checkoutExistingDirectoryObstructionTargetPromptDonePath ||
    !checkoutExistingDirectoryObstructionRevisionPromptReadyPath ||
    !checkoutExistingDirectoryObstructionRevisionPromptDonePath ||
    !checkoutExistingDirectoryObstructionDepthPromptReadyPath ||
    !checkoutExistingDirectoryObstructionDepthPromptDonePath ||
    !checkoutExistingDirectoryObstructionExternalsPromptReadyPath ||
    !checkoutExistingDirectoryObstructionExternalsPromptDonePath ||
    !checkoutUrlPromptReadyPath ||
    !checkoutUrlPromptDonePath ||
    !checkoutTargetPromptReadyPath ||
    !checkoutTargetPromptDonePath ||
    !checkoutRevisionPromptReadyPath ||
    !checkoutRevisionPromptDonePath ||
    !checkoutDepthPromptReadyPath ||
    !checkoutDepthPromptDonePath ||
    !checkoutExternalsPromptReadyPath ||
    !checkoutExternalsPromptDonePath ||
    !updateRevisionPromptReadyPath ||
    !updateRevisionPromptDonePath ||
    !updateCancellationRevisionPromptReadyPath ||
    !updateCancellationRevisionPromptDonePath ||
    !updateDepthPromptReadyPath ||
    !updateDepthPromptDonePath ||
    !updateStickyDepthPromptReadyPath ||
    !updateStickyDepthPromptDonePath ||
    !updateExternalsPromptReadyPath ||
    !updateExternalsPromptDonePath ||
    !branchCreateSourcePromptReadyPath ||
    !branchCreateSourcePromptDonePath ||
    !branchCreateDestinationPromptReadyPath ||
    !branchCreateDestinationPromptDonePath ||
    !branchCreateRevisionPromptReadyPath ||
    !branchCreateRevisionPromptDonePath ||
    !branchCreateMessagePromptReadyPath ||
    !branchCreateMessagePromptDonePath ||
    !branchCreateParentsPromptReadyPath ||
    !branchCreateParentsPromptDonePath ||
    !branchCreateExternalsPromptReadyPath ||
    !branchCreateExternalsPromptDonePath ||
    !branchCreateSwitchPromptReadyPath ||
    !branchCreateSwitchPromptDonePath ||
    !switchUrlPromptReadyPath ||
    !switchUrlPromptDonePath ||
    !switchRevisionPromptReadyPath ||
    !switchRevisionPromptDonePath ||
    !switchDepthPromptReadyPath ||
    !switchDepthPromptDonePath ||
    !switchStickyDepthPromptReadyPath ||
    !switchStickyDepthPromptDonePath ||
    !switchExternalsPromptReadyPath ||
    !switchExternalsPromptDonePath ||
    !switchAncestryPromptReadyPath ||
    !switchAncestryPromptDonePath ||
    !lockMessageCancellationPromptReadyPath ||
    !lockMessageCancellationPromptDonePath ||
    !lockMessagePromptReadyPath ||
    !lockMessagePromptDonePath ||
    !lockModePromptReadyPath ||
    !lockModePromptDonePath ||
    !lockHeldOracleReadyPath ||
    !lockHeldOracleDonePath ||
    !unlockModeCancellationPromptReadyPath ||
    !unlockModeCancellationPromptDonePath ||
    !unlockModePromptReadyPath ||
    !unlockModePromptDonePath ||
    !changelistSetPromptReadyPath ||
    !changelistRevertPromptReadyPath ||
    !revertPromptReadyPath ||
    !revertCancellationPromptReadyPath ||
    !revertCancellationPromptDonePath ||
    !resolvePromptReadyPath ||
    !resolveCancellationPromptReadyPath ||
    !cleanupPromptReadyPath ||
    !extensionsRoot ||
    !workingCopyRoot ||
    !multiRepositoryRefreshWorkingCopyRoot ||
    !lazyExternalProviderWorkingCopyRoot ||
    !boundaryLoadWorkingCopyRoot ||
    !Number.isSafeInteger(boundaryLoadParentModifiedItemCount) ||
    boundaryLoadParentModifiedItemCount < 1 ||
    !Number.isSafeInteger(boundaryLoadBoundaryModifiedItemCount) ||
    boundaryLoadBoundaryModifiedItemCount < 1 ||
    !refreshLoadWorkingCopyRoot ||
    !Number.isSafeInteger(refreshLoadItemCount) ||
    refreshLoadItemCount < 1 ||
    !loadWorkingCopyRoot ||
    !commitAllWorkingCopyRoot ||
    !commitSelectedWorkingCopyRoot ||
    !commitSelectedMultiSelectionWorkingCopyRoot ||
    !checkoutRepositoryUrl ||
    !checkoutCancellationTargetWorkingCopyRoot ||
    !checkoutExistingTargetFailureTargetPath ||
    !checkoutInvalidUrlFailureRepositoryUrl ||
    !checkoutInvalidUrlFailureTargetWorkingCopyRoot ||
    !checkoutExistingDirectoryTargetWorkingCopyRoot ||
    !checkoutExistingDirectoryObstructionTargetWorkingCopyRoot ||
    !checkoutTargetWorkingCopyRoot ||
    !updateWorkingCopyRoot ||
    !updateRevisionText ||
    !updateTargetRelativePath ||
    !branchCreateWorkingCopyRoot ||
    !branchCreateSourceUrl ||
    !branchCreateDestinationUrl ||
    !branchCreateMessage ||
    !switchWorkingCopyRoot ||
    !switchTargetUrl ||
    !addWorkingCopyRoot ||
    !addToIgnoreWorkingCopyRoot ||
    !lockWorkingCopyRoot ||
    !changelistSetClearWorkingCopyRoot ||
    !commitChangelistWorkingCopyRoot ||
    !revertChangelistWorkingCopyRoot ||
    !moveResourceWorkingCopyRoot ||
    !moveCancellationWorkingCopyRoot ||
    !removeWorkingCopyRoot ||
    !removeCancellationWorkingCopyRoot ||
    !revertWorkingCopyRoot ||
    !revertCancellationWorkingCopyRoot ||
    !resolveWorkingCopyRoot ||
    !resolveCancellationWorkingCopyRoot ||
    !Number.isSafeInteger(loadItemCount) ||
    loadItemCount < 1 ||
    !deleteWorkingCopyRoot ||
    !moveWorkingCopyRoot ||
    !moveDestinationRoot
  ) {
    throw new Error("Required installed Source Control UI E2E harness environment variables are missing.");
  }
  const updateRevision = Number.parseInt(updateRevisionText, 10);
  if (!Number.isSafeInteger(updateRevision) || updateRevision < 0 || String(updateRevision) !== updateRevisionText) {
    throw new Error(`Installed Source Control UI E2E update revision must be a canonical integer string: ${updateRevisionText}`);
  }

  let phase = "started";
  let extension;
  let extensionAfterCommand;
  let beforeActive;
  let openReport;
  let partialFreshnessReport;
  let staleFreshnessReport;
  let noRepositoryWelcomeRendererCaptureExpectations;
  let partialFreshnessRendererCaptureExpectations;
  let staleFreshnessRendererCaptureExpectations;
  let fullReconcileCancellationReport;
  let refreshReport;
  let multiRepositoryRefreshReport;
  let lazyExternalProviderReport;
  let boundaryLoadReport;
  let dirtyGenerationCancellationLoadReport;
  let refreshLoadReport;
  let deleteUnversionedFreshnessReport;
  let deleteUnversionedReport;
  let deleteUnversionedLoadReport;
  let commitAllReport;
  let commitSelectedReport;
  let commitSelectedMultiSelectionReport;
  let addToIgnoreReport;
  let lockUnlockReport;
  let lockMessageCancellationReport;
  let unlockModeCancellationReport;
  let changelistSetClearReport;
  let commitChangelistReport;
  let revertChangelistReport;
  let checkoutCancellationReport;
  let checkoutExistingTargetFailureReport;
  let checkoutInvalidUrlFailureReport;
  let checkoutExistingDirectoryReport;
  let checkoutExistingDirectoryObstructionReport;
  let checkoutReport;
  let updateToRevisionCancellationReport;
  let updateToRevisionReport;
  let branchCreateReport;
  let switchReport;
  let addReport;
  let moveReport;
  let moveCancellationReport;
  let removeReport;
  let removeCancellationReport;
  let removeKeepLocalReport;
  let revertReport;
  let revertCancellationReport;
  let resolveReport;
  let resolveCancellationReport;
  let cleanupReport;
  let closeReport;
  let repositoryLifecycleDeletionReport;
  let repositoryLifecycleMoveReport;
  let versionReport;
  function writeResult(payload) {
    fs.writeFileSync(resultPath, JSON.stringify(payload, null, 2));
  }
  function partialResult(extra = {}) {
    return {
      ok: false,
      phase,
      workingCopyRoot,
      openReport,
      partialFreshnessReport,
      staleFreshnessReport,
      noRepositoryWelcomeRendererCaptureExpectations,
      partialFreshnessRendererCaptureExpectations,
      staleFreshnessRendererCaptureExpectations,
      fullReconcileCancellationReport,
      refreshReport,
      multiRepositoryRefreshReport,
      lazyExternalProviderReport,
      boundaryLoadReport,
      dirtyGenerationCancellationLoadReport,
      refreshLoadReport,
      deleteUnversionedFreshnessReport,
      deleteUnversionedReport,
      deleteUnversionedLoadReport,
      commitAllReport,
      commitSelectedReport,
      commitSelectedMultiSelectionReport,
      addToIgnoreReport,
      lockUnlockReport,
      lockMessageCancellationReport,
      unlockModeCancellationReport,
      changelistSetClearReport,
      commitChangelistReport,
      revertChangelistReport,
      checkoutCancellationReport,
      checkoutExistingTargetFailureReport,
      checkoutInvalidUrlFailureReport,
      checkoutExistingDirectoryReport,
      checkoutExistingDirectoryObstructionReport,
      checkoutReport,
      updateToRevisionCancellationReport,
      updateToRevisionReport,
      branchCreateReport,
      switchReport,
      addReport,
      moveReport,
      moveCancellationReport,
      removeReport,
      removeCancellationReport,
      removeKeepLocalReport,
      revertReport,
      revertCancellationReport,
      resolveReport,
      resolveCancellationReport,
      cleanupReport,
      closeReport,
      repositoryLifecycleDeletionReport,
      repositoryLifecycleMoveReport,
      versionReport,
      ...extra
    };
  }

  try {
    writeResult(partialResult());
    extension = vscode.extensions.getExtension("hitsuki-ban.subversionr");
    if (!extension) {
      throw new Error("Installed SubversionR extension was not visible to Extension Host.");
    }
    beforeActive = extension.isActive;

    phase = "executingInstalledSourceControlUiE2eOpenReport";
    openReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: workingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport",
      60000
    );
    writeResult(partialResult());

    phase = "validatingInstalledSourceControlUiE2eOpenReport";
    const commands = await vscode.commands.getCommands(true);
    extensionAfterCommand = vscode.extensions.getExtension("hitsuki-ban.subversionr");
    if (!extensionAfterCommand || !extensionAfterCommand.isActive) {
      throw new Error("SubversionR did not report active after installed Source Control UI E2E open command execution.");
    }
    const normalizedExtensionPath = path.resolve(extension.extensionPath).toLowerCase();
    const normalizedRoot = path.resolve(extensionsRoot).toLowerCase();
    if (!normalizedExtensionPath.startsWith(normalizedRoot + path.sep)) {
      throw new Error(`Installed extension path is outside isolated extensions root: ${extension.extensionPath}`);
    }
    if (normalizedExtensionPath.includes("prototype-harness") || normalizedExtensionPath.includes("installed-source-control-ui-e2e-harness")) {
      throw new Error(`SubversionR must not be loaded from the harness path: ${extension.extensionPath}`);
    }
    for (const command of [
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport",
      "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport",
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport",
      "subversionr.diagnostics.installedSourceControlUiE2eArmDirtyGenerationCancellation",
      "subversionr.diagnostics.installedSourceControlUiE2eDirtyGenerationCancellationReport",
      "subversionr.diagnostics.installedSourceControlUiE2eDirtyEvent",
      "subversionr.diagnostics.installedSourceControlUiE2eCloseReport",
      "subversionr.diagnostics.installedSourceControlUiE2eLazyExternalProviderReport",
      "subversionr.diagnostics.installedRepositoryLifecycleReport",
      "subversionr.refreshRepository",
      "subversionr.updateRepository",
      "subversionr.updateToRevision",
      "subversionr.deleteUnversionedResource",
      "subversionr.deleteAllUnversionedResources",
      "subversionr.addToIgnoreResource",
      "subversionr.lockResource",
      "subversionr.unlockResource",
      "subversionr.setResourceChangelist",
      "subversionr.clearResourceChangelist",
      "subversionr.addResource",
      "subversionr.commitAll",
      "subversionr.commitResource",
      "subversionr.commitChangelist",
      "subversionr.revertChangelist",
      "subversionr.checkoutRepository",
      "subversionr.branchCreateRepository",
      "subversionr.switchRepository",
      "subversionr.diagnostics.installedSourceControlUiE2eSetInputMessage",
      "subversionr.moveResource",
      "subversionr.removeResource",
      "subversionr.removeResourceKeepLocal",
      "subversionr.revertResource",
      "subversionr.resolveResource",
      "subversionr.cleanupRepository"
    ]) {
      if (!commands.includes(command)) {
        throw new Error(`Installed SubversionR command ${command} was not registered after activation.`);
      }
    }
    if (!openReport || openReport.kind !== "subversionr.installedSourceControlUiE2eOpenReport") {
      throw new Error(`Unexpected installed Source Control UI E2E open report kind: ${openReport && openReport.kind}`);
    }
    if (openReport.extension.version !== extension.packageJSON.version) {
      throw new Error("Installed Source Control UI E2E open report extension version did not match installed package version.");
    }
    if (path.resolve(openReport.repository.identity.workingCopyRoot).toLowerCase() !== path.resolve(workingCopyRoot).toLowerCase()) {
      throw new Error("Installed Source Control UI E2E open report workingCopyRoot did not match the fixture working copy.");
    }
    if (
      openReport.surfaceWorkflow.repositoryOpen !== true ||
      openReport.surfaceWorkflow.scmProjection !== true ||
      openReport.surfaceWorkflow.sourceControlSurface !== true ||
      openReport.surfaceWorkflow.repositoryClosed !== false
    ) {
      throw new Error("Installed Source Control UI E2E open report must keep the repository open for renderer capture.");
    }
    if (openReport.sourceControl.count !== 1) {
      throw new Error(`Installed Source Control UI E2E SourceControl count must be 1 with unversioned paths excluded from the SourceControl count; got ${openReport.sourceControl.count}.`);
    }
    if (openReport.sourceControl.inputBox.acceptInputCommand !== "subversionr.commitAll") {
      throw new Error("Installed Source Control UI E2E input box must expose the commit-all command.");
    }
    if (
      !Array.isArray(openReport.sourceControl.inputBox.acceptInputCommandArguments) ||
      openReport.sourceControl.inputBox.acceptInputCommandArguments.length !== 1 ||
      openReport.sourceControl.inputBox.acceptInputCommandArguments[0] !== openReport.repository.repositoryId
    ) {
      throw new Error("Installed Source Control UI E2E input box must expose the opened repository id as the commit-all argument.");
    }
    const tracked = findResource(openReport, "changes", "src/tracked.txt", "subversionr.changedFile.baseDiffable");
    if (!tracked || tracked.kind !== "file" || typeof tracked.generation !== "number") {
      throw new Error("Installed Source Control UI E2E open report did not include modified src/tracked.txt.");
    }
    const scratch = findResource(openReport, "unversioned", "scratch.txt", "subversionr.unversioned");
    if (!scratch || typeof scratch.kind !== "string" || typeof scratch.generation !== "number") {
      throw new Error("Installed Source Control UI E2E open report did not include unversioned scratch.txt.");
    }
    if (openReport.sourceControl.groups.length !== 2) {
      throw new Error(`Installed Source Control UI E2E open report must contain exactly two non-empty SCM groups; got ${openReport.sourceControl.groups.length}.`);
    }
    if (!openReport.rendererCaptureExpectations || openReport.rendererCaptureExpectations.viewCommand !== "workbench.view.scm") {
      throw new Error("Installed Source Control UI E2E open report must include renderer capture expectations for the SCM view.");
    }

    phase = "focusingSourceControlView";
    await withTimeout(
      vscode.commands.executeCommand(openReport.rendererCaptureExpectations.viewCommand),
      openReport.rendererCaptureExpectations.viewCommand,
      30000
    );
    await new Promise(resolve => setTimeout(resolve, 1500));
    fs.writeFileSync(readyPath, JSON.stringify({
      ok: true,
      phase,
      openReport,
      rendererCaptureExpectations: openReport.rendererCaptureExpectations
    }, null, 2));

    phase = "waitingForRendererCapture";
    await waitForFile(donePath, 120000);

    phase = "executingInstalledSourceControlUiE2ePartialFreshnessReport";
    partialFreshnessReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport", {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        scenario: "partial"
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/partial",
      30000
    );
    validateFreshnessReport(partialFreshnessReport, "partial", openReport);
    writeResult(partialResult());

    phase = "capturingInstalledSourceControlUiE2ePartialFreshnessRenderer";
    partialFreshnessRendererCaptureExpectations = await captureFreshnessRendererScenario(
      partialFreshnessReport,
      "partial",
      partialFreshnessRendererReadyPath,
      partialFreshnessRendererDonePath
    );
    writeResult(partialResult());

    phase = "executingInstalledSourceControlUiE2eStaleFreshnessReport";
    staleFreshnessReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport", {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        scenario: "stale"
      }),
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/stale",
      30000
    );
    validateFreshnessReport(staleFreshnessReport, "stale", openReport);
    writeResult(partialResult());

    phase = "capturingInstalledSourceControlUiE2eStaleFreshnessRenderer";
    staleFreshnessRendererCaptureExpectations = await captureFreshnessRendererScenario(
      staleFreshnessReport,
      "stale",
      staleFreshnessRendererReadyPath,
      staleFreshnessRendererDonePath
    );
    writeResult(partialResult());

    phase = "executingFullReconcileCancellationWorkflow";
    fullReconcileCancellationReport = await runFullReconcileCancellationWorkflow(
      openReport,
      fullReconcileCancellationReadyPath,
      fullReconcileCancellationDonePath
    );
    writeResult(partialResult());

    phase = "executingRefreshRepository";
    refreshReport = await runRefreshWorkflow(openReport);
    writeResult(partialResult());

    phase = "executingMultiRepositoryRefreshRepository";
    multiRepositoryRefreshReport = await runMultiRepositoryRefreshWorkflow(openReport, multiRepositoryRefreshWorkingCopyRoot, multiRepositoryRefreshPromptReadyPath);
    writeResult(partialResult());

    phase = "executingLazyExternalProviderWorkflow";
    lazyExternalProviderReport = await runLazyExternalProviderWorkflow(lazyExternalProviderWorkingCopyRoot);
    writeResult(partialResult());

    phase = "executingBoundaryLoadWorkflow";
    boundaryLoadReport = await runBoundaryLoadWorkflow(
      boundaryLoadWorkingCopyRoot,
      boundaryLoadParentModifiedItemCount,
      boundaryLoadBoundaryModifiedItemCount
    );
    writeResult(partialResult());

    phase = "executingDeleteUnversionedResource";
    deleteUnversionedFreshnessReport = await collectFreshnessReportWithSurfaceRetry(
      {
        repositoryId: openReport.repository.repositoryId,
        epoch: openReport.repository.epoch,
        scenario: "partial"
      },
      "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport/deleteUnversioned",
      30000
    );
    validateFreshnessReport(deleteUnversionedFreshnessReport, "partial", openReport);
    deleteUnversionedReport = await runDeleteUnversionedWorkflow(
      deleteUnversionedFreshnessReport,
      workingCopyRoot,
      deletePromptReadyPath
    );
    writeResult(partialResult());

    phase = "executingDeleteAllUnversionedResources";
    deleteUnversionedLoadReport = await runDeleteUnversionedLoadWorkflow(loadWorkingCopyRoot, loadItemCount, deleteLoadPromptReadyPath);
    writeResult(partialResult());

    phase = "executingCommitAll";
    commitAllReport = await runCommitAllWorkflow(commitAllWorkingCopyRoot);
    writeResult(partialResult());

    phase = "executingCommitSelected";
    commitSelectedReport = await runCommitSelectedWorkflow(commitSelectedWorkingCopyRoot);
    writeResult(partialResult());

    phase = "executingCommitSelectedMultiSelection";
    commitSelectedMultiSelectionReport = await runCommitSelectedMultiSelectionWorkflow(commitSelectedMultiSelectionWorkingCopyRoot);
    writeResult(partialResult());

    phase = "executingAddToIgnore";
    addToIgnoreReport = await runAddToIgnoreWorkflow(addToIgnoreWorkingCopyRoot);
    writeResult(partialResult());

    phase = "executingLockUnlock";
    const lockWorkflowReports = await runLockUnlockWorkflow(lockWorkingCopyRoot, {
      lockMessageCancellationReady: lockMessageCancellationPromptReadyPath,
      lockMessageCancellationDone: lockMessageCancellationPromptDonePath,
      lockMessageReady: lockMessagePromptReadyPath,
      lockMessageDone: lockMessagePromptDonePath,
      lockModeReady: lockModePromptReadyPath,
      lockModeDone: lockModePromptDonePath,
      lockHeldOracleReady: lockHeldOracleReadyPath,
      lockHeldOracleDone: lockHeldOracleDonePath,
      unlockModeCancellationReady: unlockModeCancellationPromptReadyPath,
      unlockModeCancellationDone: unlockModeCancellationPromptDonePath,
      unlockModeReady: unlockModePromptReadyPath,
      unlockModeDone: unlockModePromptDonePath
    });
    lockUnlockReport = lockWorkflowReports.lockUnlockReport;
    lockMessageCancellationReport = lockWorkflowReports.lockMessageCancellationReport;
    unlockModeCancellationReport = lockWorkflowReports.unlockModeCancellationReport;
    writeResult(partialResult());

    phase = "executingChangelistSetClear";
    changelistSetClearReport = await runChangelistSetClearWorkflow(changelistSetClearWorkingCopyRoot, changelistSetPromptReadyPath);
    writeResult(partialResult());

    phase = "executingCommitChangelist";
    commitChangelistReport = await runCommitChangelistWorkflow(commitChangelistWorkingCopyRoot);
    writeResult(partialResult());

    phase = "executingRevertChangelist";
    revertChangelistReport = await runRevertChangelistWorkflow(revertChangelistWorkingCopyRoot, changelistRevertPromptReadyPath);
    writeResult(partialResult());

    phase = "executingAddResource";
    addReport = await runAddWorkflow(addWorkingCopyRoot);
    writeResult(partialResult());

    phase = "executingMoveResource";
    moveReport = await runMoveWorkflow(moveResourceWorkingCopyRoot, movePromptReadyPath);
    writeResult(partialResult());

    phase = "executingMoveResourceCancellation";
    moveCancellationReport = await runMoveCancellationWorkflow(moveCancellationWorkingCopyRoot, moveCancellationPromptReadyPath);
    writeResult(partialResult());

    phase = "executingRemoveResource";
    removeReport = await runRemoveWorkflow(removeWorkingCopyRoot, removePromptReadyPath);
    writeResult(partialResult());

    phase = "executingRemoveResourceCancellation";
    removeCancellationReport = await runRemoveCancellationWorkflow(removeCancellationWorkingCopyRoot, removeCancellationPromptReadyPath, removeCancellationPromptDonePath);
    writeResult(partialResult());

    phase = "executingResolveResource";
    resolveReport = await runResolveWorkflow(resolveWorkingCopyRoot, resolvePromptReadyPath);
    writeResult(partialResult());

    phase = "executingResolveResourceCancellation";
    resolveCancellationReport = await runResolveCancellationWorkflow(resolveCancellationWorkingCopyRoot, resolveCancellationPromptReadyPath);
    writeResult(partialResult());

    phase = "executingRemoveResourceKeepLocal";
    removeKeepLocalReport = await runRemoveKeepLocalWorkflow(openReport, workingCopyRoot, removeKeepLocalPromptReadyPath);
    writeResult(partialResult());

    phase = "executingRevertResource";
    revertReport = await runRevertWorkflow(revertWorkingCopyRoot, revertPromptReadyPath);
    writeResult(partialResult());

    phase = "executingRevertResourceCancellation";
    revertCancellationReport = await runRevertCancellationWorkflow(revertCancellationWorkingCopyRoot, revertCancellationPromptReadyPath, revertCancellationPromptDonePath);
    writeResult(partialResult());

    phase = "executingCleanupRepository";
    cleanupReport = await runCleanupWorkflow(openReport, cleanupPromptReadyPath);
    writeResult(partialResult());

    phase = "executingInstalledSourceControlUiE2eCloseReport";
    closeReport = await closeOpenReport(openReport);
    if (!closeReport || closeReport.kind !== "subversionr.installedSourceControlUiE2eCloseReport" || closeReport.repositoryClosed !== true) {
      throw new Error("Installed Source Control UI E2E close report did not prove repository closure.");
    }
    if (closeReport.repositoryId !== openReport.repository.repositoryId || closeReport.epoch !== openReport.repository.epoch) {
      throw new Error("Installed Source Control UI E2E close report did not match the opened repository identity.");
    }
    writeResult(partialResult());

    phase = "focusingNoRepositoryWelcome";
    noRepositoryWelcomeRendererCaptureExpectations = createNoRepositoryWelcomeRendererCaptureExpectations();
    await withTimeout(
      vscode.commands.executeCommand(noRepositoryWelcomeRendererCaptureExpectations.viewCommand),
      `${noRepositoryWelcomeRendererCaptureExpectations.viewCommand}/noRepositoryWelcome`,
      30000
    );
    await new Promise(resolve => setTimeout(resolve, 1500));
    fs.writeFileSync(noRepositoryWelcomeRendererReadyPath, JSON.stringify({
      ok: true,
      phase,
      claim: "UX-002 partial: localized no-repository Scan and Checkout Repository URL welcome entries",
      scanCommand: "subversionr.openRepository",
      checkoutCommand: "subversionr.checkoutRepository",
      nonClaims: [
        "This installed UI evidence verifies the Checkout Repository URL no-repository welcome entry, URL prompt cancellation, local-file checkout happy path, pre-existing local directory target success path, existing-directory obstruction tree-conflict projection path, and covered local-file checkout failure/no-state-pollution flows but does not cover repository browser, remote auth/certificate, or broader checkout failure matrices."
      ],
      closeReport: {
        repositoryId: closeReport.repositoryId,
        epoch: closeReport.epoch,
        repositoryClosed: closeReport.repositoryClosed
      },
      rendererCaptureExpectations: noRepositoryWelcomeRendererCaptureExpectations
    }, null, 2));

    phase = "waitingForNoRepositoryWelcomeRendererCapture";
    await waitForFile(noRepositoryWelcomeRendererDonePath, 120000);
    writeResult(partialResult());

    phase = "executingCheckoutRepositoryCancellation";
    checkoutCancellationReport = await runCheckoutCancellationWorkflow(
      checkoutRepositoryUrl,
      workingCopyRoot,
      checkoutCancellationTargetWorkingCopyRoot,
      {
        urlReady: checkoutCancellationPromptReadyPath,
        urlDone: checkoutCancellationPromptDonePath
      }
    );
    writeResult(partialResult());

    phase = "executingCheckoutRepositoryExistingTargetFailure";
    checkoutExistingTargetFailureReport = await runCheckoutExistingTargetFailureWorkflow(
      checkoutRepositoryUrl,
      workingCopyRoot,
      checkoutExistingTargetFailureTargetPath,
      {
        urlReady: checkoutExistingTargetFailureUrlPromptReadyPath,
        urlDone: checkoutExistingTargetFailureUrlPromptDonePath,
        targetReady: checkoutExistingTargetFailureTargetPromptReadyPath,
        targetDone: checkoutExistingTargetFailureTargetPromptDonePath,
        revisionReady: checkoutExistingTargetFailureRevisionPromptReadyPath,
        revisionDone: checkoutExistingTargetFailureRevisionPromptDonePath,
        depthReady: checkoutExistingTargetFailureDepthPromptReadyPath,
        depthDone: checkoutExistingTargetFailureDepthPromptDonePath,
        externalsReady: checkoutExistingTargetFailureExternalsPromptReadyPath,
        externalsDone: checkoutExistingTargetFailureExternalsPromptDonePath,
        notificationReady: checkoutExistingTargetFailureNotificationReadyPath,
        notificationDone: checkoutExistingTargetFailureNotificationDonePath
      }
    );
    writeResult(partialResult());

    phase = "executingCheckoutRepositoryInvalidUrlFailure";
    checkoutInvalidUrlFailureReport = await runCheckoutInvalidUrlFailureWorkflow(
      checkoutInvalidUrlFailureRepositoryUrl,
      workingCopyRoot,
      checkoutInvalidUrlFailureTargetWorkingCopyRoot,
      {
        urlReady: checkoutInvalidUrlFailureUrlPromptReadyPath,
        urlDone: checkoutInvalidUrlFailureUrlPromptDonePath,
        targetReady: checkoutInvalidUrlFailureTargetPromptReadyPath,
        targetDone: checkoutInvalidUrlFailureTargetPromptDonePath,
        revisionReady: checkoutInvalidUrlFailureRevisionPromptReadyPath,
        revisionDone: checkoutInvalidUrlFailureRevisionPromptDonePath,
        depthReady: checkoutInvalidUrlFailureDepthPromptReadyPath,
        depthDone: checkoutInvalidUrlFailureDepthPromptDonePath,
        externalsReady: checkoutInvalidUrlFailureExternalsPromptReadyPath,
        externalsDone: checkoutInvalidUrlFailureExternalsPromptDonePath,
        notificationReady: checkoutInvalidUrlFailureNotificationReadyPath,
        notificationDone: checkoutInvalidUrlFailureNotificationDonePath
      }
    );
    writeResult(partialResult());

    phase = "executingCheckoutRepositoryExistingDirectory";
    checkoutExistingDirectoryReport = await runCheckoutExistingDirectoryWorkflow(checkoutRepositoryUrl, checkoutExistingDirectoryTargetWorkingCopyRoot, {
      urlReady: checkoutExistingDirectoryUrlPromptReadyPath,
      urlDone: checkoutExistingDirectoryUrlPromptDonePath,
      targetReady: checkoutExistingDirectoryTargetPromptReadyPath,
      targetDone: checkoutExistingDirectoryTargetPromptDonePath,
      revisionReady: checkoutExistingDirectoryRevisionPromptReadyPath,
      revisionDone: checkoutExistingDirectoryRevisionPromptDonePath,
      depthReady: checkoutExistingDirectoryDepthPromptReadyPath,
      depthDone: checkoutExistingDirectoryDepthPromptDonePath,
      externalsReady: checkoutExistingDirectoryExternalsPromptReadyPath,
      externalsDone: checkoutExistingDirectoryExternalsPromptDonePath
    });
    writeResult(partialResult());

    phase = "executingCheckoutRepositoryExistingDirectoryObstruction";
    checkoutExistingDirectoryObstructionReport = await runCheckoutExistingDirectoryObstructionWorkflow(checkoutRepositoryUrl, checkoutExistingDirectoryObstructionTargetWorkingCopyRoot, {
      urlReady: checkoutExistingDirectoryObstructionUrlPromptReadyPath,
      urlDone: checkoutExistingDirectoryObstructionUrlPromptDonePath,
      targetReady: checkoutExistingDirectoryObstructionTargetPromptReadyPath,
      targetDone: checkoutExistingDirectoryObstructionTargetPromptDonePath,
      revisionReady: checkoutExistingDirectoryObstructionRevisionPromptReadyPath,
      revisionDone: checkoutExistingDirectoryObstructionRevisionPromptDonePath,
      depthReady: checkoutExistingDirectoryObstructionDepthPromptReadyPath,
      depthDone: checkoutExistingDirectoryObstructionDepthPromptDonePath,
      externalsReady: checkoutExistingDirectoryObstructionExternalsPromptReadyPath,
      externalsDone: checkoutExistingDirectoryObstructionExternalsPromptDonePath
    });
    writeResult(partialResult());

    phase = "executingCheckoutRepository";
    checkoutReport = await runCheckoutWorkflow(checkoutRepositoryUrl, checkoutTargetWorkingCopyRoot, {
      urlReady: checkoutUrlPromptReadyPath,
      urlDone: checkoutUrlPromptDonePath,
      targetReady: checkoutTargetPromptReadyPath,
      targetDone: checkoutTargetPromptDonePath,
      revisionReady: checkoutRevisionPromptReadyPath,
      revisionDone: checkoutRevisionPromptDonePath,
      depthReady: checkoutDepthPromptReadyPath,
      depthDone: checkoutDepthPromptDonePath,
      externalsReady: checkoutExternalsPromptReadyPath,
      externalsDone: checkoutExternalsPromptDonePath
    });
    writeResult(partialResult());

    phase = "executingUpdateToRevisionCancellation";
    updateToRevisionCancellationReport = await runUpdateToRevisionCancellationWorkflow(updateWorkingCopyRoot, updateTargetRelativePath, {
      revisionReady: updateCancellationRevisionPromptReadyPath,
      revisionDone: updateCancellationRevisionPromptDonePath
    });
    writeResult(partialResult());

    phase = "executingUpdateToRevision";
    updateToRevisionReport = await runUpdateToRevisionWorkflow(updateWorkingCopyRoot, updateRevision, updateTargetRelativePath, {
      revisionReady: updateRevisionPromptReadyPath,
      revisionDone: updateRevisionPromptDonePath,
      depthReady: updateDepthPromptReadyPath,
      depthDone: updateDepthPromptDonePath,
      stickyDepthReady: updateStickyDepthPromptReadyPath,
      stickyDepthDone: updateStickyDepthPromptDonePath,
      externalsReady: updateExternalsPromptReadyPath,
      externalsDone: updateExternalsPromptDonePath
    });
    writeResult(partialResult());

    phase = "executingBranchCreateRepository";
    branchCreateReport = await runBranchCreateWorkflow(branchCreateWorkingCopyRoot, branchCreateSourceUrl, branchCreateDestinationUrl, branchCreateMessage, {
      sourceReady: branchCreateSourcePromptReadyPath,
      sourceDone: branchCreateSourcePromptDonePath,
      destinationReady: branchCreateDestinationPromptReadyPath,
      destinationDone: branchCreateDestinationPromptDonePath,
      revisionReady: branchCreateRevisionPromptReadyPath,
      revisionDone: branchCreateRevisionPromptDonePath,
      messageReady: branchCreateMessagePromptReadyPath,
      messageDone: branchCreateMessagePromptDonePath,
      parentsReady: branchCreateParentsPromptReadyPath,
      parentsDone: branchCreateParentsPromptDonePath,
      externalsReady: branchCreateExternalsPromptReadyPath,
      externalsDone: branchCreateExternalsPromptDonePath,
      switchReady: branchCreateSwitchPromptReadyPath,
      switchDone: branchCreateSwitchPromptDonePath
    });
    writeResult(partialResult());

    phase = "executingSwitchRepository";
    switchReport = await runSwitchWorkflow(switchWorkingCopyRoot, switchTargetUrl, {
      urlReady: switchUrlPromptReadyPath,
      urlDone: switchUrlPromptDonePath,
      revisionReady: switchRevisionPromptReadyPath,
      revisionDone: switchRevisionPromptDonePath,
      depthReady: switchDepthPromptReadyPath,
      depthDone: switchDepthPromptDonePath,
      stickyDepthReady: switchStickyDepthPromptReadyPath,
      stickyDepthDone: switchStickyDepthPromptDonePath,
      externalsReady: switchExternalsPromptReadyPath,
      externalsDone: switchExternalsPromptDonePath,
      ancestryReady: switchAncestryPromptReadyPath,
      ancestryDone: switchAncestryPromptDonePath
    });
    writeResult(partialResult());

    phase = "executingDirtyGenerationCancellationLoad";
    dirtyGenerationCancellationLoadReport = await runDirtyGenerationCancellationLoadWorkflow(refreshLoadWorkingCopyRoot, refreshLoadItemCount);
    writeResult(partialResult());

    phase = "executingRefreshLoadRepository";
    refreshLoadReport = await runRefreshLoadWorkflow(refreshLoadWorkingCopyRoot, refreshLoadItemCount);
    writeResult(partialResult());

    phase = "executingInstalledRepositoryLifecycleDeletionReport";
    const deleteOpenReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: deleteWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/delete",
      60000
    );
    process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MISSING_WORKING_COPY_ROOT = deleteOpenReport.repository.identity.workingCopyRoot;
    try {
      repositoryLifecycleDeletionReport = await withTimeout(
        vscode.commands.executeCommand("subversionr.diagnostics.installedRepositoryLifecycleReport", {
          scenario: "deletedWorkingCopy",
          trigger: "workspaceFolders",
          expectedRepositoryId: deleteOpenReport.repository.repositoryId,
          expectedEpoch: deleteOpenReport.repository.epoch,
          expectedWorkingCopyRoot: deleteOpenReport.repository.identity.workingCopyRoot
        }),
        "subversionr.diagnostics.installedRepositoryLifecycleReport/delete",
        60000
      );
    } finally {
      delete process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MISSING_WORKING_COPY_ROOT;
    }
    if (
      !repositoryLifecycleDeletionReport ||
      repositoryLifecycleDeletionReport.kind !== "subversionr.installedRepositoryLifecycleReport" ||
      repositoryLifecycleDeletionReport.request.scenario !== "deletedWorkingCopy" ||
      repositoryLifecycleDeletionReport.assertions.missingWorkingCopyClosed !== true
    ) {
      throw new Error("Installed repository lifecycle deletion report did not prove missing working-copy closure.");
    }

    phase = "executingInstalledRepositoryLifecycleMoveReport";
    const moveOpenReport = await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.installedSourceControlUiE2eOpenReport", { path: moveWorkingCopyRoot }),
      "subversionr.diagnostics.installedSourceControlUiE2eOpenReport/move",
      60000
    );
    if (!fs.existsSync(moveDestinationRoot)) {
      throw new Error(`Installed repository lifecycle move destination fixture was missing: ${moveDestinationRoot}`);
    }
    process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MISSING_WORKING_COPY_ROOT = moveOpenReport.repository.identity.workingCopyRoot;
    process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_EXTRA_WORKSPACE_ROOT = path.dirname(moveDestinationRoot);
    try {
      repositoryLifecycleMoveReport = await withTimeout(
        vscode.commands.executeCommand("subversionr.diagnostics.installedRepositoryLifecycleReport", {
          scenario: "movedWorkingCopy",
          trigger: "workspaceFolders",
          expectedRepositoryId: moveOpenReport.repository.repositoryId,
          expectedEpoch: moveOpenReport.repository.epoch,
          expectedWorkingCopyRoot: moveOpenReport.repository.identity.workingCopyRoot,
          expectedMovedWorkingCopyRoot: moveDestinationRoot
        }),
        "subversionr.diagnostics.installedRepositoryLifecycleReport/move",
        60000
      );
    } finally {
      delete process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MISSING_WORKING_COPY_ROOT;
      delete process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_EXTRA_WORKSPACE_ROOT;
    }
    if (
      !repositoryLifecycleMoveReport ||
      repositoryLifecycleMoveReport.kind !== "subversionr.installedRepositoryLifecycleReport" ||
      repositoryLifecycleMoveReport.request.scenario !== "movedWorkingCopy" ||
      repositoryLifecycleMoveReport.assertions.movedWorkingCopyRecovered !== true
    ) {
      throw new Error("Installed repository lifecycle move report did not prove moved working-copy recovery.");
    }

    phase = "executingVersionReport";
    await withTimeout(
      vscode.commands.executeCommand("subversionr.diagnostics.versionReport"),
      "subversionr.diagnostics.versionReport",
      30000
    );
    phase = "validatingVersionReport";
    const versionReportDocument = vscode.workspace.textDocuments.find(document => document.uri.scheme === "svn-r-diagnostics");
    if (!versionReportDocument) {
      throw new Error("SubversionR version report readonly document was not opened.");
    }
    versionReport = JSON.parse(versionReportDocument.getText());
    if (versionReport.kind !== "subversionr.versionReport") {
      throw new Error(`Unexpected version report kind: ${versionReport.kind}`);
    }
    if (!versionReport.backend || versionReport.backend.status !== "initialized") {
      throw new Error(`Installed Source Control UI E2E requires initialized backend status; got ${versionReport.backend && versionReport.backend.status}`);
    }
    const backend = versionReport.backend;
    const capabilities = backend.capabilities || {};
    for (const capability of ["repositoryOpen", "statusSnapshot", "statusRefresh", "realLibsvnBridge"]) {
      if (capabilities[capability] !== true) {
        throw new Error(`Version report backend capability ${capability} must be true.`);
      }
    }
    if (typeof backend.libsvnVersion !== "string" || !backend.libsvnVersion.startsWith("1.14.5")) {
      throw new Error(`Version report backend libsvnVersion must be 1.14.5; got ${backend.libsvnVersion}`);
    }

    writeResult({
      ok: true,
      phase: "complete",
      id: extension.id,
      version: extension.packageJSON.version,
      beforeActive,
      afterActive: extensionAfterCommand.isActive,
      extensionPath: extension.extensionPath,
      source: "installed-vsix",
      invokedCommands: [
        "subversionr.diagnostics.installedSourceControlUiE2eOpenReport",
        "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport",
        "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport",
      "subversionr.diagnostics.installedSourceControlUiE2eArmFullReconcileCancellation",
      "subversionr.diagnostics.installedSourceControlUiE2eFullReconcileCancellationReport",
      "subversionr.diagnostics.installedSourceControlUiE2eArmDirtyGenerationCancellation",
      "subversionr.diagnostics.installedSourceControlUiE2eDirtyGenerationCancellationReport",
      "subversionr.diagnostics.installedSourceControlUiE2eDirtyEvent",
      openReport.rendererCaptureExpectations.viewCommand,
      noRepositoryWelcomeRendererCaptureExpectations.viewCommand,
        "subversionr.fullReconcile",
        "subversionr.refreshRepository",
        "subversionr.refreshResource",
        "subversionr.updateRepository",
        "subversionr.updateToRevision",
        "subversionr.diagnostics.installedSourceControlUiE2eLazyExternalProviderReport",
        "subversionr.deleteUnversionedResource",
        "subversionr.deleteAllUnversionedResources",
      "subversionr.addToIgnoreResource",
      "subversionr.lockResource",
      "subversionr.unlockResource",
      "subversionr.setResourceChangelist",
        "subversionr.clearResourceChangelist",
        "subversionr.diagnostics.installedSourceControlUiE2eSetInputMessage",
        "subversionr.commitAll",
        "subversionr.commitResource",
        "subversionr.commitChangelist",
        "subversionr.revertChangelist",
        "subversionr.checkoutRepository",
        "subversionr.branchCreateRepository",
        "subversionr.switchRepository",
        "subversionr.addResource",
        "subversionr.moveResource",
        "subversionr.removeResource",
        "subversionr.removeResourceKeepLocal",
        "subversionr.revertResource",
        "subversionr.cleanupRepository",
        "subversionr.diagnostics.installedSourceControlUiE2eCloseReport",
        "subversionr.diagnostics.installedRepositoryLifecycleReport",
        "subversionr.diagnostics.versionReport"
      ],
      hasInstalledSourceControlUiE2eOpenReportCommand: true,
      hasInstalledSourceControlUiE2eCurrentSurfaceReportCommand: true,
      hasInstalledSourceControlUiE2eFreshnessReportCommand: true,
      hasInstalledSourceControlUiE2eArmFullReconcileCancellationCommand: true,
      hasInstalledSourceControlUiE2eFullReconcileCancellationReportCommand: true,
      hasInstalledSourceControlUiE2eArmDirtyGenerationCancellationCommand: true,
      hasInstalledSourceControlUiE2eDirtyGenerationCancellationReportCommand: true,
      hasInstalledSourceControlUiE2eDirtyEventCommand: true,
      hasInstalledSourceControlUiE2eCloseReportCommand: true,
      hasInstalledSourceControlUiE2eLazyExternalProviderReportCommand: true,
      hasInstalledRepositoryLifecycleReportCommand: true,
      hasRefreshRepositoryCommand: true,
      hasUpdateRepositoryCommand: true,
      hasUpdateToRevisionCommand: true,
      hasDeleteUnversionedResourceCommand: true,
      hasDeleteAllUnversionedResourcesCommand: true,
      hasAddToIgnoreResourceCommand: true,
      hasLockResourceCommand: true,
      hasUnlockResourceCommand: true,
      hasSetResourceChangelistCommand: true,
      hasClearResourceChangelistCommand: true,
      hasCommitAllCommand: true,
      hasCommitResourceCommand: true,
      hasCommitChangelistCommand: true,
      hasRevertChangelistCommand: true,
      hasCheckoutRepositoryCommand: true,
      hasBranchCreateRepositoryCommand: true,
      hasSwitchRepositoryCommand: true,
      hasInstalledSourceControlUiE2eSetInputMessageCommand: true,
      hasAddResourceCommand: true,
      hasMoveResourceCommand: true,
      hasRemoveResourceCommand: true,
      hasRemoveResourceKeepLocalCommand: true,
      hasRevertResourceCommand: true,
      hasResolveResourceCommand: true,
      hasCleanupRepositoryCommand: true,
      openReport,
      partialFreshnessReport,
      staleFreshnessReport,
      noRepositoryWelcomeRendererCaptureExpectations,
      partialFreshnessRendererCaptureExpectations,
      staleFreshnessRendererCaptureExpectations,
      fullReconcileCancellationReport,
      refreshReport,
      multiRepositoryRefreshReport,
      lazyExternalProviderReport,
      boundaryLoadReport,
      dirtyGenerationCancellationLoadReport,
      refreshLoadReport,
      deleteUnversionedFreshnessReport,
      deleteUnversionedReport,
      deleteUnversionedLoadReport,
      commitAllReport,
      commitSelectedReport,
      commitSelectedMultiSelectionReport,
      addToIgnoreReport,
      lockUnlockReport,
      lockMessageCancellationReport,
      unlockModeCancellationReport,
      changelistSetClearReport,
      commitChangelistReport,
      revertChangelistReport,
      checkoutCancellationReport,
      checkoutExistingTargetFailureReport,
      checkoutInvalidUrlFailureReport,
      checkoutExistingDirectoryReport,
      checkoutExistingDirectoryObstructionReport,
      checkoutReport,
      updateToRevisionCancellationReport,
      updateToRevisionReport,
      branchCreateReport,
      switchReport,
      addReport,
      moveReport,
      moveCancellationReport,
      removeReport,
      removeCancellationReport,
      removeKeepLocalReport,
      revertReport,
      revertCancellationReport,
      resolveReport,
      resolveCancellationReport,
      cleanupReport,
      closeReport,
      repositoryLifecycleDeletionReport,
      repositoryLifecycleMoveReport,
      versionReport
    });
  } catch (error) {
    if (openReport && !closeReport) {
      try {
        closeReport = await closeOpenReport(openReport);
      } catch (closeError) {
        closeReport = {
          ok: false,
          error: serializeError(closeError)
        };
      }
    }
    writeResult(partialResult({
      error: serializeError(error)
    }));
    throw error;
  }
}

exports.run = run;
'@
  $runnerPath = Join-Path $distRoot "run-tests.js"
  $runner | Set-Content -LiteralPath $runnerPath -NoNewline

  [pscustomobject]@{
    Root = $HarnessRoot
    TestsPath = $runnerPath
    ResultPath = $ResultPath
    ReadyPath = $ReadyPath
    DonePath = $DonePath
    NoRepositoryWelcomeRendererReadyPath = $NoRepositoryWelcomeRendererReadyPath
    NoRepositoryWelcomeRendererDonePath = $NoRepositoryWelcomeRendererDonePath
    PartialFreshnessRendererReadyPath = $PartialFreshnessRendererReadyPath
    PartialFreshnessRendererDonePath = $PartialFreshnessRendererDonePath
    StaleFreshnessRendererReadyPath = $StaleFreshnessRendererReadyPath
    StaleFreshnessRendererDonePath = $StaleFreshnessRendererDonePath
    FullReconcileCancellationReadyPath = $FullReconcileCancellationReadyPath
    FullReconcileCancellationDonePath = $FullReconcileCancellationDonePath
    MultiRepositoryRefreshPromptReadyPath = $MultiRepositoryRefreshPromptReadyPath
    DeletePromptReadyPath = $DeletePromptReadyPath
    DeleteLoadPromptReadyPath = $DeleteLoadPromptReadyPath
    RemovePromptReadyPath = $RemovePromptReadyPath
    RemoveCancellationPromptReadyPath = $RemoveCancellationPromptReadyPath
    RemoveCancellationPromptDonePath = $RemoveCancellationPromptDonePath
    RemoveKeepLocalPromptReadyPath = $RemoveKeepLocalPromptReadyPath
    MovePromptReadyPath = $MovePromptReadyPath
    MoveCancellationPromptReadyPath = $MoveCancellationPromptReadyPath
    CheckoutCancellationPromptReadyPath = $CheckoutCancellationPromptReadyPath
    CheckoutCancellationPromptDonePath = $CheckoutCancellationPromptDonePath
    CheckoutExistingTargetFailureUrlPromptReadyPath = $CheckoutExistingTargetFailureUrlPromptReadyPath
    CheckoutExistingTargetFailureUrlPromptDonePath = $CheckoutExistingTargetFailureUrlPromptDonePath
    CheckoutExistingTargetFailureTargetPromptReadyPath = $CheckoutExistingTargetFailureTargetPromptReadyPath
    CheckoutExistingTargetFailureTargetPromptDonePath = $CheckoutExistingTargetFailureTargetPromptDonePath
    CheckoutExistingTargetFailureRevisionPromptReadyPath = $CheckoutExistingTargetFailureRevisionPromptReadyPath
    CheckoutExistingTargetFailureRevisionPromptDonePath = $CheckoutExistingTargetFailureRevisionPromptDonePath
    CheckoutExistingTargetFailureDepthPromptReadyPath = $CheckoutExistingTargetFailureDepthPromptReadyPath
    CheckoutExistingTargetFailureDepthPromptDonePath = $CheckoutExistingTargetFailureDepthPromptDonePath
    CheckoutExistingTargetFailureExternalsPromptReadyPath = $CheckoutExistingTargetFailureExternalsPromptReadyPath
    CheckoutExistingTargetFailureExternalsPromptDonePath = $CheckoutExistingTargetFailureExternalsPromptDonePath
    CheckoutExistingTargetFailureNotificationReadyPath = $CheckoutExistingTargetFailureNotificationReadyPath
    CheckoutExistingTargetFailureNotificationDonePath = $CheckoutExistingTargetFailureNotificationDonePath
    CheckoutInvalidUrlFailureUrlPromptReadyPath = $CheckoutInvalidUrlFailureUrlPromptReadyPath
    CheckoutInvalidUrlFailureUrlPromptDonePath = $CheckoutInvalidUrlFailureUrlPromptDonePath
    CheckoutInvalidUrlFailureTargetPromptReadyPath = $CheckoutInvalidUrlFailureTargetPromptReadyPath
    CheckoutInvalidUrlFailureTargetPromptDonePath = $CheckoutInvalidUrlFailureTargetPromptDonePath
    CheckoutInvalidUrlFailureRevisionPromptReadyPath = $CheckoutInvalidUrlFailureRevisionPromptReadyPath
    CheckoutInvalidUrlFailureRevisionPromptDonePath = $CheckoutInvalidUrlFailureRevisionPromptDonePath
    CheckoutInvalidUrlFailureDepthPromptReadyPath = $CheckoutInvalidUrlFailureDepthPromptReadyPath
    CheckoutInvalidUrlFailureDepthPromptDonePath = $CheckoutInvalidUrlFailureDepthPromptDonePath
    CheckoutInvalidUrlFailureExternalsPromptReadyPath = $CheckoutInvalidUrlFailureExternalsPromptReadyPath
    CheckoutInvalidUrlFailureExternalsPromptDonePath = $CheckoutInvalidUrlFailureExternalsPromptDonePath
    CheckoutInvalidUrlFailureNotificationReadyPath = $CheckoutInvalidUrlFailureNotificationReadyPath
    CheckoutInvalidUrlFailureNotificationDonePath = $CheckoutInvalidUrlFailureNotificationDonePath
    CheckoutExistingDirectoryUrlPromptReadyPath = $CheckoutExistingDirectoryUrlPromptReadyPath
    CheckoutExistingDirectoryUrlPromptDonePath = $CheckoutExistingDirectoryUrlPromptDonePath
    CheckoutExistingDirectoryTargetPromptReadyPath = $CheckoutExistingDirectoryTargetPromptReadyPath
    CheckoutExistingDirectoryTargetPromptDonePath = $CheckoutExistingDirectoryTargetPromptDonePath
    CheckoutExistingDirectoryRevisionPromptReadyPath = $CheckoutExistingDirectoryRevisionPromptReadyPath
    CheckoutExistingDirectoryRevisionPromptDonePath = $CheckoutExistingDirectoryRevisionPromptDonePath
    CheckoutExistingDirectoryDepthPromptReadyPath = $CheckoutExistingDirectoryDepthPromptReadyPath
    CheckoutExistingDirectoryDepthPromptDonePath = $CheckoutExistingDirectoryDepthPromptDonePath
    CheckoutExistingDirectoryExternalsPromptReadyPath = $CheckoutExistingDirectoryExternalsPromptReadyPath
    CheckoutExistingDirectoryExternalsPromptDonePath = $CheckoutExistingDirectoryExternalsPromptDonePath
    CheckoutExistingDirectoryObstructionUrlPromptReadyPath = $CheckoutExistingDirectoryObstructionUrlPromptReadyPath
    CheckoutExistingDirectoryObstructionUrlPromptDonePath = $CheckoutExistingDirectoryObstructionUrlPromptDonePath
    CheckoutExistingDirectoryObstructionTargetPromptReadyPath = $CheckoutExistingDirectoryObstructionTargetPromptReadyPath
    CheckoutExistingDirectoryObstructionTargetPromptDonePath = $CheckoutExistingDirectoryObstructionTargetPromptDonePath
    CheckoutExistingDirectoryObstructionRevisionPromptReadyPath = $CheckoutExistingDirectoryObstructionRevisionPromptReadyPath
    CheckoutExistingDirectoryObstructionRevisionPromptDonePath = $CheckoutExistingDirectoryObstructionRevisionPromptDonePath
    CheckoutExistingDirectoryObstructionDepthPromptReadyPath = $CheckoutExistingDirectoryObstructionDepthPromptReadyPath
    CheckoutExistingDirectoryObstructionDepthPromptDonePath = $CheckoutExistingDirectoryObstructionDepthPromptDonePath
    CheckoutExistingDirectoryObstructionExternalsPromptReadyPath = $CheckoutExistingDirectoryObstructionExternalsPromptReadyPath
    CheckoutExistingDirectoryObstructionExternalsPromptDonePath = $CheckoutExistingDirectoryObstructionExternalsPromptDonePath
    CheckoutUrlPromptReadyPath = $CheckoutUrlPromptReadyPath
    CheckoutUrlPromptDonePath = $CheckoutUrlPromptDonePath
    CheckoutTargetPromptReadyPath = $CheckoutTargetPromptReadyPath
    CheckoutTargetPromptDonePath = $CheckoutTargetPromptDonePath
    CheckoutRevisionPromptReadyPath = $CheckoutRevisionPromptReadyPath
    CheckoutRevisionPromptDonePath = $CheckoutRevisionPromptDonePath
    CheckoutDepthPromptReadyPath = $CheckoutDepthPromptReadyPath
    CheckoutDepthPromptDonePath = $CheckoutDepthPromptDonePath
    CheckoutExternalsPromptReadyPath = $CheckoutExternalsPromptReadyPath
    CheckoutExternalsPromptDonePath = $CheckoutExternalsPromptDonePath
    UpdateRevisionPromptReadyPath = $UpdateRevisionPromptReadyPath
    UpdateRevisionPromptDonePath = $UpdateRevisionPromptDonePath
    UpdateCancellationRevisionPromptReadyPath = $UpdateCancellationRevisionPromptReadyPath
    UpdateCancellationRevisionPromptDonePath = $UpdateCancellationRevisionPromptDonePath
    UpdateDepthPromptReadyPath = $UpdateDepthPromptReadyPath
    UpdateDepthPromptDonePath = $UpdateDepthPromptDonePath
    UpdateStickyDepthPromptReadyPath = $UpdateStickyDepthPromptReadyPath
    UpdateStickyDepthPromptDonePath = $UpdateStickyDepthPromptDonePath
    UpdateExternalsPromptReadyPath = $UpdateExternalsPromptReadyPath
    UpdateExternalsPromptDonePath = $UpdateExternalsPromptDonePath
    BranchCreateSourcePromptReadyPath = $BranchCreateSourcePromptReadyPath
    BranchCreateSourcePromptDonePath = $BranchCreateSourcePromptDonePath
    BranchCreateDestinationPromptReadyPath = $BranchCreateDestinationPromptReadyPath
    BranchCreateDestinationPromptDonePath = $BranchCreateDestinationPromptDonePath
    BranchCreateRevisionPromptReadyPath = $BranchCreateRevisionPromptReadyPath
    BranchCreateRevisionPromptDonePath = $BranchCreateRevisionPromptDonePath
    BranchCreateMessagePromptReadyPath = $BranchCreateMessagePromptReadyPath
    BranchCreateMessagePromptDonePath = $BranchCreateMessagePromptDonePath
    BranchCreateParentsPromptReadyPath = $BranchCreateParentsPromptReadyPath
    BranchCreateParentsPromptDonePath = $BranchCreateParentsPromptDonePath
    BranchCreateExternalsPromptReadyPath = $BranchCreateExternalsPromptReadyPath
    BranchCreateExternalsPromptDonePath = $BranchCreateExternalsPromptDonePath
    BranchCreateSwitchPromptReadyPath = $BranchCreateSwitchPromptReadyPath
    BranchCreateSwitchPromptDonePath = $BranchCreateSwitchPromptDonePath
    SwitchUrlPromptReadyPath = $SwitchUrlPromptReadyPath
    SwitchUrlPromptDonePath = $SwitchUrlPromptDonePath
    SwitchRevisionPromptReadyPath = $SwitchRevisionPromptReadyPath
    SwitchRevisionPromptDonePath = $SwitchRevisionPromptDonePath
    SwitchDepthPromptReadyPath = $SwitchDepthPromptReadyPath
    SwitchDepthPromptDonePath = $SwitchDepthPromptDonePath
    SwitchStickyDepthPromptReadyPath = $SwitchStickyDepthPromptReadyPath
    SwitchStickyDepthPromptDonePath = $SwitchStickyDepthPromptDonePath
    SwitchExternalsPromptReadyPath = $SwitchExternalsPromptReadyPath
    SwitchExternalsPromptDonePath = $SwitchExternalsPromptDonePath
    SwitchAncestryPromptReadyPath = $SwitchAncestryPromptReadyPath
    SwitchAncestryPromptDonePath = $SwitchAncestryPromptDonePath
    LockMessageCancellationPromptReadyPath = $LockMessageCancellationPromptReadyPath
    LockMessageCancellationPromptDonePath = $LockMessageCancellationPromptDonePath
    LockMessagePromptReadyPath = $LockMessagePromptReadyPath
    LockMessagePromptDonePath = $LockMessagePromptDonePath
    LockModePromptReadyPath = $LockModePromptReadyPath
    LockModePromptDonePath = $LockModePromptDonePath
    LockHeldOracleReadyPath = $LockHeldOracleReadyPath
    LockHeldOracleDonePath = $LockHeldOracleDonePath
    UnlockModeCancellationPromptReadyPath = $UnlockModeCancellationPromptReadyPath
    UnlockModeCancellationPromptDonePath = $UnlockModeCancellationPromptDonePath
    UnlockModePromptReadyPath = $UnlockModePromptReadyPath
    UnlockModePromptDonePath = $UnlockModePromptDonePath
    ChangelistSetPromptReadyPath = $ChangelistSetPromptReadyPath
    ChangelistRevertPromptReadyPath = $ChangelistRevertPromptReadyPath
    RevertPromptReadyPath = $RevertPromptReadyPath
    RevertCancellationPromptReadyPath = $RevertCancellationPromptReadyPath
    RevertCancellationPromptDonePath = $RevertCancellationPromptDonePath
    ResolvePromptReadyPath = $ResolvePromptReadyPath
    ResolveCancellationPromptReadyPath = $ResolveCancellationPromptReadyPath
    CleanupPromptReadyPath = $CleanupPromptReadyPath
    ExtensionsRoot = $ExtensionsRoot
    WorkingCopyRoot = $WorkingCopyRoot
    MultiRepositoryRefreshWorkingCopyRoot = $MultiRepositoryRefreshWorkingCopyRoot
    LazyExternalProviderWorkingCopyRoot = $LazyExternalProviderWorkingCopyRoot
    BoundaryLoadWorkingCopyRoot = $BoundaryLoadWorkingCopyRoot
    BoundaryLoadParentModifiedItemCount = $BoundaryLoadParentModifiedItemCount
    BoundaryLoadBoundaryModifiedItemCount = $BoundaryLoadBoundaryModifiedItemCount
    RefreshLoadWorkingCopyRoot = $RefreshLoadWorkingCopyRoot
    RefreshLoadItemCount = $RefreshLoadItemCount
    LoadWorkingCopyRoot = $LoadWorkingCopyRoot
    LoadItemCount = $LoadItemCount
    CommitAllWorkingCopyRoot = $CommitAllWorkingCopyRoot
    CommitSelectedWorkingCopyRoot = $CommitSelectedWorkingCopyRoot
    CommitSelectedMultiSelectionWorkingCopyRoot = $CommitSelectedMultiSelectionWorkingCopyRoot
    CheckoutRepositoryUrl = $CheckoutRepositoryUrl
    CheckoutCancellationTargetWorkingCopyRoot = $CheckoutCancellationTargetWorkingCopyRoot
    CheckoutExistingTargetFailureTargetPath = $CheckoutExistingTargetFailureTargetPath
    CheckoutInvalidUrlFailureRepositoryUrl = $CheckoutInvalidUrlFailureRepositoryUrl
    CheckoutInvalidUrlFailureTargetWorkingCopyRoot = $CheckoutInvalidUrlFailureTargetWorkingCopyRoot
    CheckoutExistingDirectoryTargetWorkingCopyRoot = $CheckoutExistingDirectoryTargetWorkingCopyRoot
    CheckoutExistingDirectoryObstructionTargetWorkingCopyRoot = $CheckoutExistingDirectoryObstructionTargetWorkingCopyRoot
    CheckoutTargetWorkingCopyRoot = $CheckoutTargetWorkingCopyRoot
    UpdateWorkingCopyRoot = $UpdateWorkingCopyRoot
    UpdateRevision = $UpdateRevision
    UpdateTargetRelativePath = $UpdateTargetRelativePath
    BranchCreateWorkingCopyRoot = $BranchCreateWorkingCopyRoot
    BranchCreateSourceUrl = $BranchCreateSourceUrl
    BranchCreateDestinationUrl = $BranchCreateDestinationUrl
    BranchCreateMessage = $BranchCreateMessage
    SwitchWorkingCopyRoot = $SwitchWorkingCopyRoot
    SwitchTargetUrl = $SwitchTargetUrl
    AddWorkingCopyRoot = $AddWorkingCopyRoot
    AddToIgnoreWorkingCopyRoot = $AddToIgnoreWorkingCopyRoot
    LockWorkingCopyRoot = $LockWorkingCopyRoot
    ChangelistSetClearWorkingCopyRoot = $ChangelistSetClearWorkingCopyRoot
    CommitChangelistWorkingCopyRoot = $CommitChangelistWorkingCopyRoot
    RevertChangelistWorkingCopyRoot = $RevertChangelistWorkingCopyRoot
    MoveResourceWorkingCopyRoot = $MoveResourceWorkingCopyRoot
    MoveCancellationWorkingCopyRoot = $MoveCancellationWorkingCopyRoot
    RemoveWorkingCopyRoot = $RemoveWorkingCopyRoot
    RemoveCancellationWorkingCopyRoot = $RemoveCancellationWorkingCopyRoot
    RevertWorkingCopyRoot = $RevertWorkingCopyRoot
    RevertCancellationWorkingCopyRoot = $RevertCancellationWorkingCopyRoot
    ResolveWorkingCopyRoot = $ResolveWorkingCopyRoot
    ResolveCancellationWorkingCopyRoot = $ResolveCancellationWorkingCopyRoot
    DeleteWorkingCopyRoot = $DeleteWorkingCopyRoot
    MoveWorkingCopyRoot = $MoveWorkingCopyRoot
    MoveDestinationRoot = $MoveDestinationRoot
  }
}

function Wait-File([string]$Path, [int]$TimeoutSeconds, [string]$Description) {
  $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
  while ([DateTimeOffset]::UtcNow -lt $deadline) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
      return
    }
    Start-Sleep -Milliseconds 250
  }
  throw "$Description timed out after $TimeoutSeconds seconds."
}

function Assert-ResourcePresent([object]$OpenReport, [string]$GroupId, [string]$Path, [string]$ContextValue) {
  $groups = @($OpenReport.sourceControl.groups | Where-Object { $_.id -eq $GroupId })
  if ($groups.Count -ne 1) {
    throw "Installed Source Control UI E2E open report must include exactly one $GroupId group."
  }
  $resources = @($groups[0].resources | Where-Object { $_.path -eq $Path -and $_.contextValue -eq $ContextValue })
  if ($resources.Count -ne 1) {
    throw "Installed Source Control UI E2E open report must include $Path in $GroupId with context $ContextValue."
  }
}

function Assert-HarnessResult(
  [object]$Result,
  [string]$ExpectedVersion,
  [string]$ExtensionsRoot,
  [string]$InstalledPackageRoot,
  [string]$WorkingCopyRoot
) {
  if ($Result.PSObject.Properties.Name -contains "ok" -and $Result.ok -ne $true) {
    $message = "Installed Source Control UI E2E harness did not complete successfully at phase '$($Result.phase)'."
    if ($Result.PSObject.Properties.Name -contains "error" -and $null -ne $Result.error) {
      $message = "$message $($Result.error.message)"
    }
    throw $message
  }
  if ($Result.id -ne "hitsuki-ban.subversionr") {
    throw "Installed Source Control UI E2E result extension id must be hitsuki-ban.subversionr."
  }
  if ($Result.version -ne $ExpectedVersion) {
    throw "Installed Source Control UI E2E result extension version must be $ExpectedVersion."
  }
  if ($Result.source -ne "installed-vsix") {
    throw "Installed Source Control UI E2E result source must be installed-vsix."
  }
  if ($Result.afterActive -ne $true) {
    throw "Installed Source Control UI E2E result must prove SubversionR is active before UI validation."
  }
  if (
    $Result.hasInstalledSourceControlUiE2eOpenReportCommand -ne $true -or
    $Result.hasInstalledSourceControlUiE2eCurrentSurfaceReportCommand -ne $true -or
    $Result.hasInstalledSourceControlUiE2eFreshnessReportCommand -ne $true -or
    $Result.hasInstalledSourceControlUiE2eArmFullReconcileCancellationCommand -ne $true -or
    $Result.hasInstalledSourceControlUiE2eFullReconcileCancellationReportCommand -ne $true -or
    $Result.hasInstalledSourceControlUiE2eArmDirtyGenerationCancellationCommand -ne $true -or
    $Result.hasInstalledSourceControlUiE2eDirtyGenerationCancellationReportCommand -ne $true -or
    $Result.hasInstalledSourceControlUiE2eDirtyEventCommand -ne $true -or
    $Result.hasInstalledSourceControlUiE2eCloseReportCommand -ne $true -or
    $Result.hasInstalledSourceControlUiE2eLazyExternalProviderReportCommand -ne $true -or
    $Result.hasInstalledRepositoryLifecycleReportCommand -ne $true -or
    $Result.hasRefreshRepositoryCommand -ne $true -or
    $Result.hasUpdateRepositoryCommand -ne $true -or
    $Result.hasUpdateToRevisionCommand -ne $true -or
    $Result.hasDeleteUnversionedResourceCommand -ne $true -or
    $Result.hasDeleteAllUnversionedResourcesCommand -ne $true -or
    $Result.hasAddToIgnoreResourceCommand -ne $true -or
    $Result.hasSetResourceChangelistCommand -ne $true -or
    $Result.hasClearResourceChangelistCommand -ne $true -or
    $Result.hasCommitAllCommand -ne $true -or
    $Result.hasCommitResourceCommand -ne $true -or
    $Result.hasCommitChangelistCommand -ne $true -or
    $Result.hasRevertChangelistCommand -ne $true -or
    $Result.hasCheckoutRepositoryCommand -ne $true -or
    $Result.hasBranchCreateRepositoryCommand -ne $true -or
    $Result.hasSwitchRepositoryCommand -ne $true -or
    $Result.hasInstalledSourceControlUiE2eSetInputMessageCommand -ne $true -or
    $Result.hasAddResourceCommand -ne $true -or
    $Result.hasMoveResourceCommand -ne $true -or
    $Result.hasRemoveResourceCommand -ne $true -or
    $Result.hasRemoveResourceKeepLocalCommand -ne $true -or
    $Result.hasRevertResourceCommand -ne $true -or
    $Result.hasResolveResourceCommand -ne $true -or
    $Result.hasCleanupRepositoryCommand -ne $true
  ) {
    throw "Installed Source Control UI E2E result must prove hidden open/freshness/close/lifecycle diagnostic command and core workflow command registration."
  }
  if ($Result.openReport.kind -ne "subversionr.installedSourceControlUiE2eOpenReport") {
    throw "Installed Source Control UI E2E result must include an open report."
  }
  if (@($Result.openReport.sourceControl.inputBox.acceptInputCommandArguments)[0] -ne $Result.openReport.repository.repositoryId) {
    throw "Installed Source Control UI E2E open report must expose the repository id through SourceControl accept input command arguments."
  }
  Assert-FreshnessReport -Report $Result.partialFreshnessReport -Scenario "partial" -OpenReport $Result.openReport
  Assert-FreshnessReport -Report $Result.staleFreshnessReport -Scenario "stale" -OpenReport $Result.openReport
  if (
    $Result.noRepositoryWelcomeRendererCaptureExpectations.viewCommand -ne "workbench.view.scm" -or
    @($Result.noRepositoryWelcomeRendererCaptureExpectations.requiredDomTokens | Where-Object { $_ -eq "No SVN working copy was found in the workspace" }).Count -ne 1 -or
    @($Result.noRepositoryWelcomeRendererCaptureExpectations.requiredDomTokens | Where-Object { $_ -eq "Scan for SVN Working Copies" }).Count -ne 1 -or
    @($Result.noRepositoryWelcomeRendererCaptureExpectations.requiredDomTokens | Where-Object { $_ -eq "Checkout Repository URL" }).Count -ne 1 -or
    @($Result.noRepositoryWelcomeRendererCaptureExpectations.requiredAccessibilityTokens | Where-Object { $_ -eq "No SVN working copy was found in the workspace" }).Count -ne 1 -or
    @($Result.noRepositoryWelcomeRendererCaptureExpectations.requiredAccessibilityTokens | Where-Object { $_ -eq "Scan for SVN Working Copies" }).Count -ne 1 -or
    @($Result.noRepositoryWelcomeRendererCaptureExpectations.requiredAccessibilityTokens | Where-Object { $_ -eq "Checkout Repository URL" }).Count -ne 1
  ) {
    throw "Installed Source Control UI E2E result must include no-repository welcome renderer expectations for the localized Scan and Checkout affordances."
  }
  if ($Result.checkoutReport.kind -ne "subversionr.installedSourceControlUiE2eCheckoutWorkflow" -or
    $Result.checkoutReport.command.command -ne "subversionr.checkoutRepository" -or
    $Result.checkoutReport.request.revision -ne "head" -or
    $Result.checkoutReport.request.depth -ne "infinity" -or
    $Result.checkoutReport.request.ignoreExternals -ne $true -or
    $Result.checkoutReport.currentSurfaceReport.kind -ne "subversionr.installedSourceControlUiE2eCurrentSurfaceReport" -or
    $Result.checkoutReport.currentSurfaceReport.surfaceWorkflow.repositoryOpen -ne $true -or
    $Result.checkoutReport.currentSurfaceReport.surfaceWorkflow.scmProjection -ne $true -or
    $Result.checkoutReport.currentSurfaceReport.surfaceWorkflow.sourceControlSurface -ne $true -or
    $Result.checkoutReport.closeReport.repositoryClosed -ne $true -or
    $Result.checkoutReport.assertions.workingCopyCreated -ne $true -or
    $Result.checkoutReport.assertions.repositoryOpenedAfterCheckout -ne $true -or
    $Result.checkoutReport.assertions.sourceControlProjectionAvailable -ne $true) {
    throw "Installed Source Control UI E2E result must include a Checkout Repository workflow proving prompt execution, working-copy creation, automatic open, SourceControl projection, and evidence cleanup."
  }
  if ($Result.checkoutExistingDirectoryReport.kind -ne "subversionr.installedSourceControlUiE2eCheckoutExistingDirectoryWorkflow" -or
    $Result.checkoutExistingDirectoryReport.command.command -ne "subversionr.checkoutRepository" -or
    $Result.checkoutExistingDirectoryReport.request.revision -ne "head" -or
    $Result.checkoutExistingDirectoryReport.request.depth -ne "infinity" -or
    $Result.checkoutExistingDirectoryReport.request.ignoreExternals -ne $true -or
    $Result.checkoutExistingDirectoryReport.currentSurfaceReport.kind -ne "subversionr.installedSourceControlUiE2eCurrentSurfaceReport" -or
    $Result.checkoutExistingDirectoryReport.currentSurfaceReport.surfaceWorkflow.repositoryOpen -ne $true -or
    $Result.checkoutExistingDirectoryReport.currentSurfaceReport.surfaceWorkflow.scmProjection -ne $true -or
    $Result.checkoutExistingDirectoryReport.currentSurfaceReport.surfaceWorkflow.sourceControlSurface -ne $true -or
    $Result.checkoutExistingDirectoryReport.closeReport.repositoryClosed -ne $true -or
    $Result.checkoutExistingDirectoryReport.assertions.targetDirectoryExistedBefore -ne $true -or
    $Result.checkoutExistingDirectoryReport.assertions.targetDirectoryNonEmptyBefore -ne $true -or
    $Result.checkoutExistingDirectoryReport.assertions.existingDirectoryTargetAccepted -ne $true -or
    $Result.checkoutExistingDirectoryReport.assertions.workingCopyCreated -ne $true -or
    $Result.checkoutExistingDirectoryReport.assertions.localDirectoryEntryPreserved -ne $true -or
    $Result.checkoutExistingDirectoryReport.assertions.repositoryOpenedAfterCheckout -ne $true -or
    $Result.checkoutExistingDirectoryReport.assertions.sourceControlProjectionAvailable -ne $true -or
    $Result.checkoutExistingDirectoryReport.assertions.localOnlyFileProjectedUnversioned -ne $true) {
    throw "Installed Source Control UI E2E result must include a Checkout Repository existing-directory workflow proving libsvn checkout, local file preservation, unversioned projection, automatic open, and evidence cleanup."
  }
  if ($Result.checkoutExistingDirectoryObstructionReport.kind -ne "subversionr.installedSourceControlUiE2eCheckoutExistingDirectoryObstructionWorkflow" -or
    $Result.checkoutExistingDirectoryObstructionReport.command.command -ne "subversionr.checkoutRepository" -or
    $Result.checkoutExistingDirectoryObstructionReport.request.revision -ne "head" -or
    $Result.checkoutExistingDirectoryObstructionReport.request.depth -ne "infinity" -or
    $Result.checkoutExistingDirectoryObstructionReport.request.ignoreExternals -ne $true -or
    $Result.checkoutExistingDirectoryObstructionReport.currentSurfaceReport.kind -ne "subversionr.installedSourceControlUiE2eCurrentSurfaceReport" -or
    $Result.checkoutExistingDirectoryObstructionReport.currentSurfaceReport.surfaceWorkflow.repositoryOpen -ne $true -or
    $Result.checkoutExistingDirectoryObstructionReport.currentSurfaceReport.surfaceWorkflow.scmProjection -ne $true -or
    $Result.checkoutExistingDirectoryObstructionReport.currentSurfaceReport.surfaceWorkflow.sourceControlSurface -ne $true -or
    $Result.checkoutExistingDirectoryObstructionReport.closeReport.repositoryClosed -ne $true -or
    $Result.checkoutExistingDirectoryObstructionReport.conflictResource.path -ne "src" -or
    $Result.checkoutExistingDirectoryObstructionReport.conflictResource.contextValue -ne "subversionr.conflicted" -or
    $Result.checkoutExistingDirectoryObstructionReport.assertions.targetDirectoryExistedBefore -ne $true -or
    $Result.checkoutExistingDirectoryObstructionReport.assertions.targetDirectoryNonEmptyBefore -ne $true -or
    $Result.checkoutExistingDirectoryObstructionReport.assertions.obstructingFileExistedBefore -ne $true -or
    $Result.checkoutExistingDirectoryObstructionReport.assertions.workingCopyCreated -ne $true -or
    $Result.checkoutExistingDirectoryObstructionReport.assertions.obstructionPreserved -ne $true -or
    $Result.checkoutExistingDirectoryObstructionReport.assertions.blockedIncomingTrackedPathAbsent -ne $true -or
    $Result.checkoutExistingDirectoryObstructionReport.assertions.localDirectoryEntryPreserved -ne $true -or
    $Result.checkoutExistingDirectoryObstructionReport.assertions.repositoryOpenedAfterCheckout -ne $true -or
    $Result.checkoutExistingDirectoryObstructionReport.assertions.sourceControlProjectionAvailable -ne $true -or
    $Result.checkoutExistingDirectoryObstructionReport.assertions.treeConflictProjected -ne $true -or
    $Result.checkoutExistingDirectoryObstructionReport.assertions.localOnlyFileProjectedUnversioned -ne $true) {
    throw "Installed Source Control UI E2E result must include a Checkout Repository existing-directory obstruction workflow proving libsvn tree-conflict semantics, local file preservation, conflict projection, automatic open, and evidence cleanup."
  }
  if ($Result.checkoutCancellationReport.kind -ne "subversionr.installedSourceControlUiE2eCheckoutCancellationWorkflow" -or
    $Result.checkoutCancellationReport.command.command -ne "subversionr.checkoutRepository" -or
    $Result.checkoutCancellationReport.prompt.cancelKey -ne "Escape" -or
    $Result.checkoutCancellationReport.prompt.rendererCaptureExpectations.cancelSurface -ne "quickInput" -or
    $Result.checkoutCancellationReport.currentSurfaceProbes.baselineBefore.kind -ne "subversionr.installedSourceControlUiE2eMissingCurrentSurfaceProbe" -or
    $Result.checkoutCancellationReport.currentSurfaceProbes.baselineAfter.kind -ne "subversionr.installedSourceControlUiE2eMissingCurrentSurfaceProbe" -or
    $Result.checkoutCancellationReport.currentSurfaceProbes.targetBefore.kind -ne "subversionr.installedSourceControlUiE2eMissingCurrentSurfaceProbe" -or
    $Result.checkoutCancellationReport.currentSurfaceProbes.targetAfter.kind -ne "subversionr.installedSourceControlUiE2eMissingCurrentSurfaceProbe" -or
    $Result.checkoutCancellationReport.currentSurfaceProbes.targetAfter.assertions.currentSessionMissing -ne $true -or
    $Result.checkoutCancellationReport.currentSurfaceProbes.targetAfter.assertions.sourceControlProjectionAbsent -ne $true -or
    $Result.checkoutCancellationReport.assertions.commandCancelled -ne $true -or
    $Result.checkoutCancellationReport.assertions.targetAbsentAfter -ne $true -or
    $Result.checkoutCancellationReport.assertions.svnMetadataAbsentAfter -ne $true -or
    $Result.checkoutCancellationReport.assertions.repositoryNotOpenedAfterCancellation -ne $true -or
    $Result.checkoutCancellationReport.assertions.sourceControlProjectionUnchanged -ne $true) {
    throw "Installed Source Control UI E2E result must include a Checkout Repository cancellation workflow proving Escape cancellation did not create checkout state."
  }
  if ($Result.checkoutExistingTargetFailureReport.kind -ne "subversionr.installedSourceControlUiE2eCheckoutExistingTargetFailureWorkflow" -or
    $Result.checkoutExistingTargetFailureReport.command.command -ne "subversionr.checkoutRepository" -or
    $Result.checkoutExistingTargetFailureReport.failure.code -ne "SVN_REPOSITORY_CHECKOUT_FAILED" -or
    $Result.checkoutExistingTargetFailureReport.notification.cleanup.command -ne "notifications.clearAll" -or
    $Result.checkoutExistingTargetFailureReport.notification.cleanup.cleared -ne $true -or
    $Result.checkoutExistingTargetFailureReport.currentSurfaceProbes.baselineBefore.kind -ne "subversionr.installedSourceControlUiE2eMissingCurrentSurfaceProbe" -or
    $Result.checkoutExistingTargetFailureReport.currentSurfaceProbes.baselineAfter.kind -ne "subversionr.installedSourceControlUiE2eMissingCurrentSurfaceProbe" -or
    $Result.checkoutExistingTargetFailureReport.currentSurfaceProbes.targetBefore.kind -ne "subversionr.installedSourceControlUiE2eMissingCurrentSurfaceProbe" -or
    $Result.checkoutExistingTargetFailureReport.currentSurfaceProbes.targetAfter.kind -ne "subversionr.installedSourceControlUiE2eMissingCurrentSurfaceProbe" -or
    $Result.checkoutExistingTargetFailureReport.currentSurfaceProbes.targetAfter.assertions.currentSessionMissing -ne $true -or
    $Result.checkoutExistingTargetFailureReport.currentSurfaceProbes.targetAfter.assertions.sourceControlProjectionAbsent -ne $true -or
    $Result.checkoutExistingTargetFailureReport.assertions.commandFailed -ne $true -or
    $Result.checkoutExistingTargetFailureReport.assertions.obstructingTargetFilePreserved -ne $true -or
    $Result.checkoutExistingTargetFailureReport.assertions.svnMetadataAbsentAfter -ne $true -or
    $Result.checkoutExistingTargetFailureReport.assertions.fixtureDirectoryUnchanged -ne $true -or
    $Result.checkoutExistingTargetFailureReport.assertions.repositoryNotOpenedAfterFailure -ne $true -or
    $Result.checkoutExistingTargetFailureReport.assertions.sourceControlProjectionUnchanged -ne $true) {
    throw "Installed Source Control UI E2E result must include a Checkout Repository existing obstructing target failure workflow proving checkout failure did not create repository state."
  }
  if ($Result.checkoutInvalidUrlFailureReport.kind -ne "subversionr.installedSourceControlUiE2eCheckoutInvalidUrlFailureWorkflow" -or
    $Result.checkoutInvalidUrlFailureReport.command.command -ne "subversionr.checkoutRepository" -or
    $Result.checkoutInvalidUrlFailureReport.failure.code -ne "SVN_REPOSITORY_CHECKOUT_FAILED" -or
    $Result.checkoutInvalidUrlFailureReport.notification.cleanup.command -ne "notifications.clearAll" -or
    $Result.checkoutInvalidUrlFailureReport.notification.cleanup.cleared -ne $true -or
    $Result.checkoutInvalidUrlFailureReport.currentSurfaceProbes.baselineBefore.kind -ne "subversionr.installedSourceControlUiE2eMissingCurrentSurfaceProbe" -or
    $Result.checkoutInvalidUrlFailureReport.currentSurfaceProbes.baselineAfter.kind -ne "subversionr.installedSourceControlUiE2eMissingCurrentSurfaceProbe" -or
    $Result.checkoutInvalidUrlFailureReport.currentSurfaceProbes.targetBefore.kind -ne "subversionr.installedSourceControlUiE2eMissingCurrentSurfaceProbe" -or
    $Result.checkoutInvalidUrlFailureReport.currentSurfaceProbes.targetAfter.kind -ne "subversionr.installedSourceControlUiE2eMissingCurrentSurfaceProbe" -or
    $Result.checkoutInvalidUrlFailureReport.currentSurfaceProbes.targetAfter.assertions.currentSessionMissing -ne $true -or
    $Result.checkoutInvalidUrlFailureReport.currentSurfaceProbes.targetAfter.assertions.sourceControlProjectionAbsent -ne $true -or
    $Result.checkoutInvalidUrlFailureReport.assertions.commandFailed -ne $true -or
    $Result.checkoutInvalidUrlFailureReport.assertions.invalidUrlRejected -ne $true -or
    $Result.checkoutInvalidUrlFailureReport.assertions.targetAbsentAfter -ne $true -or
    $Result.checkoutInvalidUrlFailureReport.assertions.svnMetadataAbsentAfter -ne $true -or
    $Result.checkoutInvalidUrlFailureReport.assertions.parentDirectoryUnchanged -ne $true -or
    $Result.checkoutInvalidUrlFailureReport.assertions.repositoryNotOpenedAfterFailure -ne $true -or
    $Result.checkoutInvalidUrlFailureReport.assertions.sourceControlProjectionUnchanged -ne $true) {
    throw "Installed Source Control UI E2E result must include a Checkout Repository invalid URL failure workflow proving checkout failure did not create repository state."
  }
  if ($Result.updateToRevisionReport.kind -ne "subversionr.installedSourceControlUiE2eUpdateToRevisionWorkflow" -or
    $Result.updateToRevisionReport.command.command -ne "subversionr.updateToRevision" -or
    $Result.updateToRevisionReport.request.revision -ne 2 -or
    $Result.updateToRevisionReport.request.depth -ne "files" -or
    $Result.updateToRevisionReport.request.depthIsSticky -ne $true -or
    $Result.updateToRevisionReport.request.ignoreExternals -ne $false -or
    $Result.updateToRevisionReport.currentSurfaceReport.kind -ne "subversionr.installedSourceControlUiE2eCurrentSurfaceReport" -or
    $Result.updateToRevisionReport.currentSurfaceReport.surfaceWorkflow.repositoryOpen -ne $true -or
    $Result.updateToRevisionReport.currentSurfaceReport.surfaceWorkflow.scmProjection -ne $true -or
    $Result.updateToRevisionReport.currentSurfaceReport.surfaceWorkflow.sourceControlSurface -ne $true -or
    $Result.updateToRevisionReport.closeReport.repositoryClosed -ne $true -or
    $Result.updateToRevisionReport.assertions.updatedRevisionContentApplied -ne $true -or
    $Result.updateToRevisionReport.assertions.postUpdateReconcileCompleted -ne $true -or
    $Result.updateToRevisionReport.assertions.sourceControlProjectionAvailable -ne $true) {
    throw "Installed Source Control UI E2E result must include an Update to Revision workflow proving prompt execution, rN/depth/sticky/externals request shape, post-update reconcile, and evidence cleanup."
  }
  if ($Result.updateToRevisionCancellationReport.kind -ne "subversionr.installedSourceControlUiE2eUpdateToRevisionCancellationWorkflow" -or
    $Result.updateToRevisionCancellationReport.command.command -ne "subversionr.updateToRevision" -or
    $Result.updateToRevisionCancellationReport.prompt.cancelKey -ne "Escape" -or
    $Result.updateToRevisionCancellationReport.closeReport.repositoryClosed -ne $true -or
    $Result.updateToRevisionCancellationReport.assertions.commandCancelled -ne $true -or
    $Result.updateToRevisionCancellationReport.assertions.targetContentUnchangedAfterCancellation -ne $true -or
    $Result.updateToRevisionCancellationReport.assertions.requestedRevisionContentNotApplied -ne $true -or
    $Result.updateToRevisionCancellationReport.assertions.sourceControlProjectionUnchanged -ne $true) {
    throw "Installed Source Control UI E2E result must include an Update to Revision cancellation workflow proving the revision QuickInput cancellation did not mutate the working copy or Source Control projection."
  }
  if ($Result.branchCreateReport.kind -ne "subversionr.installedSourceControlUiE2eBranchCreateWorkflow" -or
    $Result.branchCreateReport.command.command -ne "subversionr.branchCreateRepository" -or
    $Result.branchCreateReport.request.revision -ne "head" -or
    $Result.branchCreateReport.request.makeParents -ne $false -or
    $Result.branchCreateReport.request.ignoreExternals -ne $true -or
    $Result.branchCreateReport.prompts.switchAfterCreate.switchAfterCreate -ne $false -or
    $Result.branchCreateReport.prompts.switchAfterCreate.selected -ne "Stay on the current SVN URL" -or
    $Result.branchCreateReport.closeReport.repositoryClosed -ne $true -or
    $Result.branchCreateReport.assertions.commandExecuted -ne $true -or
    $Result.branchCreateReport.assertions.branchCreatedInRepository -ne $true -or
    $Result.branchCreateReport.assertions.noLocalReconcileClaimed -ne $true) {
    throw "Installed Source Control UI E2E result must include a Branch/Tag create workflow proving prompt execution, request shape, remote-only command completion, and evidence cleanup."
  }
  if ($Result.switchReport.kind -ne "subversionr.installedSourceControlUiE2eSwitchWorkflow" -or
    $Result.switchReport.command.command -ne "subversionr.switchRepository" -or
    $Result.switchReport.request.revision -ne "head" -or
    $Result.switchReport.request.depth -ne "infinity" -or
    $Result.switchReport.request.depthIsSticky -ne $true -or
    $Result.switchReport.request.ignoreExternals -ne $true -or
    $Result.switchReport.request.ignoreAncestry -ne $false -or
    $Result.switchReport.currentSurfaceReport.kind -ne "subversionr.installedSourceControlUiE2eCurrentSurfaceReport" -or
    $Result.switchReport.currentSurfaceReport.surfaceWorkflow.repositoryOpen -ne $true -or
    $Result.switchReport.currentSurfaceReport.surfaceWorkflow.scmProjection -ne $true -or
    $Result.switchReport.currentSurfaceReport.surfaceWorkflow.sourceControlSurface -ne $true -or
    $Result.switchReport.closeReport.repositoryClosed -ne $true -or
    $Result.switchReport.assertions.postSwitchReconcileCompleted -ne $true -or
    $Result.switchReport.assertions.postSwitchGenerationAdvanced -ne $true -or
    $Result.switchReport.assertions.postSwitchRepositoryIdentityPreserved -ne $true -or
    $Result.switchReport.assertions.sourceControlProjectionAvailable -ne $true) {
    throw "Installed Source Control UI E2E result must include a Switch workflow proving prompt execution, request shape, post-switch full reconcile, SourceControl projection, and evidence cleanup."
  }
  if ($Result.commitAllReport.kind -ne "subversionr.installedSourceControlUiE2eCommitAllWorkflow" -or
    $Result.commitAllReport.command.command -ne "subversionr.commitAll" -or
    $Result.commitAllReport.command.sourceControlAcceptInputCommand -ne "subversionr.commitAll" -or
    @($Result.commitAllReport.command.arguments)[0] -ne $Result.commitAllReport.repository.repositoryId -or
    @($Result.commitAllReport.targets.eligiblePaths)[0] -ne "src/tracked.txt" -or
    @($Result.commitAllReport.targets.excludedUnversionedPaths)[0] -ne "scratch.txt" -or
    $Result.commitAllReport.assertions.inputMessageWasSet -ne $true -or
    $Result.commitAllReport.assertions.inputMessageClearedAfterCommit -ne $true -or
    $Result.commitAllReport.assertions.trackedFileCommitted -ne $true -or
    $Result.commitAllReport.assertions.unversionedPathRemainedUnversioned -ne $true -or
    $Result.commitAllReport.assertions.sourceControlProjectionClearedCommittedPath -ne $true -or
    $Result.commitAllReport.assertions.targetedReconcileAfterCommit -ne $true) {
    throw "Installed Source Control UI E2E result must include a Commit All workflow proving input accept command execution, input clearing, target exclusion, and targeted post-commit reconcile."
  }
  if ($Result.commitSelectedReport.kind -ne "subversionr.installedSourceControlUiE2eCommitSelectedWorkflow" -or
    $Result.commitSelectedReport.command.command -ne "subversionr.commitResource" -or
    @($Result.commitSelectedReport.targets.selectedPaths)[0] -ne "src/tracked.txt" -or
    @($Result.commitSelectedReport.targets.unselectedChangedPaths)[0] -ne "load/modified-001.txt" -or
    $Result.commitSelectedReport.assertions.inputMessageWasSet -ne $true -or
    $Result.commitSelectedReport.assertions.inputMessageClearedAfterCommit -ne $true -or
    $Result.commitSelectedReport.assertions.selectedFileCommitted -ne $true -or
    $Result.commitSelectedReport.assertions.unselectedFileStillModified -ne $true -or
    $Result.commitSelectedReport.assertions.sourceControlProjectionClearedCommittedPath -ne $true -or
    $Result.commitSelectedReport.assertions.targetedReconcileAfterCommit -ne $true) {
    throw "Installed Source Control UI E2E result must include a Commit Selected workflow proving SCM resource command execution, input clearing, target isolation, and targeted post-commit reconcile."
  }
  if ($Result.commitSelectedMultiSelectionReport.kind -ne "subversionr.installedSourceControlUiE2eCommitSelectedMultiSelectionWorkflow" -or
    $Result.commitSelectedMultiSelectionReport.command.command -ne "subversionr.commitResource" -or
    $Result.commitSelectedMultiSelectionReport.command.argumentShape -ne "resourceStateArray" -or
    @($Result.commitSelectedMultiSelectionReport.targets.selectedPaths).Count -ne 2 -or
    @($Result.commitSelectedMultiSelectionReport.targets.selectedPaths)[0] -ne "src/tracked.txt" -or
    @($Result.commitSelectedMultiSelectionReport.targets.selectedPaths)[1] -ne "load/modified-001.txt" -or
    $Result.commitSelectedMultiSelectionReport.assertions.inputMessageWasSet -ne $true -or
    $Result.commitSelectedMultiSelectionReport.assertions.inputMessageClearedAfterCommit -ne $true -or
    $Result.commitSelectedMultiSelectionReport.assertions.allSelectedFilesCommitted -ne $true -or
    $Result.commitSelectedMultiSelectionReport.assertions.sourceControlProjectionClearedSelectedPaths -ne $true -or
    $Result.commitSelectedMultiSelectionReport.assertions.targetedReconcileAfterCommit -ne $true) {
    throw "Installed Source Control UI E2E result must include a Commit Selected multi-selection workflow proving SCM resource array execution, input clearing, selected-path commit, and targeted post-commit reconcile."
  }
  if ($Result.addToIgnoreReport.kind -ne "subversionr.installedSourceControlUiE2eAddToIgnoreWorkflow" -or
    $Result.addToIgnoreReport.command.command -ne "subversionr.addToIgnoreResource" -or
    $Result.addToIgnoreReport.resource.path -ne "scratch.txt" -or
    $Result.addToIgnoreReport.rootPropertyResource.path -ne "." -or
    $Result.addToIgnoreReport.rootPropertyResource.contextValue -ne "subversionr.changedDirectory" -or
    $Result.addToIgnoreReport.rootPropertyResource.kind -ne "dir" -or
    $Result.addToIgnoreReport.property.name -ne "svn:ignore" -or
    @($Result.addToIgnoreReport.property.addedPatterns)[0] -ne "scratch.txt" -or
    $Result.addToIgnoreReport.assertions.propertyListReadBeforeSet -ne $true -or
    $Result.addToIgnoreReport.assertions.workingCopyIgnorePropertyUpdated -ne $true -or
    $Result.addToIgnoreReport.assertions.rootPropertyChangeProjected -ne $true -or
    $Result.addToIgnoreReport.assertions.unversionedProjectionCleared -ne $true -or
    $Result.addToIgnoreReport.closeReport.repositoryClosed -ne $true) {
    throw "Installed Source Control UI E2E result must include an Add to Ignore workflow proving properties/list, svn:ignore propertySet, projection refresh, and evidence cleanup."
  }
  if ($Result.lockMessageCancellationReport.kind -ne "subversionr.installedSourceControlUiE2eLockMessageCancellationWorkflow" -or
    $Result.lockMessageCancellationReport.command.command -ne "subversionr.lockResource" -or
    $Result.lockMessageCancellationReport.resource.path -ne "src/needs-lock.txt" -or
    $Result.lockMessageCancellationReport.prompt.cancelKey -ne "Escape" -or
    $Result.lockMessageCancellationReport.prompt.rendererCaptureExpectations.cancelSurface -ne "quickInput" -or
    $Result.lockMessageCancellationReport.currentSurfaceReport.kind -ne "subversionr.installedSourceControlUiE2eCurrentSurfaceReport" -or
    $Result.lockMessageCancellationReport.assertions.commandCancelled -ne $true -or
    $Result.lockMessageCancellationReport.assertions.sourceControlProjectionUnchanged -ne $true -or
    $Result.lockMessageCancellationReport.assertions.repositoryClosedAfterEvidence -ne $true) {
    throw "Installed Source Control UI E2E result must include a Lock message cancellation workflow proving Escape cancellation preserved Source Control projection."
  }
  if ($Result.unlockModeCancellationReport.kind -ne "subversionr.installedSourceControlUiE2eUnlockModeCancellationWorkflow" -or
    $Result.unlockModeCancellationReport.command.command -ne "subversionr.unlockResource" -or
    $Result.unlockModeCancellationReport.resource.path -ne "src/needs-lock.txt" -or
    $Result.unlockModeCancellationReport.prompt.cancelKey -ne "Escape" -or
    $Result.unlockModeCancellationReport.prompt.rendererCaptureExpectations.cancelSurface -ne "quickInput" -or
    $Result.unlockModeCancellationReport.currentSurfaceReport.kind -ne "subversionr.installedSourceControlUiE2eCurrentSurfaceReport" -or
    $Result.unlockModeCancellationReport.assertions.commandCancelled -ne $true -or
    $Result.unlockModeCancellationReport.assertions.sourceControlProjectionUnchanged -ne $true -or
    $Result.unlockModeCancellationReport.assertions.repositoryClosedAfterEvidence -ne $true) {
    throw "Installed Source Control UI E2E result must include an Unlock mode cancellation workflow proving Escape cancellation preserved Source Control projection."
  }
  if ($Result.changelistSetClearReport.kind -ne "subversionr.installedSourceControlUiE2eChangelistSetClearWorkflow" -or
    $Result.changelistSetClearReport.commands.set -ne "subversionr.setResourceChangelist" -or
    $Result.changelistSetClearReport.commands.clear -ne "subversionr.clearResourceChangelist" -or
    $Result.changelistSetClearReport.changelist -ne "review" -or
    $Result.changelistSetClearReport.assertions.groupProjectedAfterSet -ne $true -or
    $Result.changelistSetClearReport.assertions.resourceReturnedToChangesAfterClear -ne $true -or
    $Result.changelistSetClearReport.closeReport.repositoryClosed -ne $true) {
    throw "Installed Source Control UI E2E result must include a Changelist set/clear workflow proving prompt entry, group projection, clear, and evidence cleanup."
  }
  if ($Result.commitChangelistReport.kind -ne "subversionr.installedSourceControlUiE2eCommitChangelistWorkflow" -or
    $Result.commitChangelistReport.command.command -ne "subversionr.commitChangelist" -or
    $Result.commitChangelistReport.command.changelist -ne "review" -or
    $Result.commitChangelistReport.assertions.commitUsedChangelistFilter -ne $true -or
    $Result.commitChangelistReport.assertions.changelistProjectionClearedCommittedPath -ne $true -or
    $Result.commitChangelistReport.assertions.unselectedNonChangelistPathStillModified -ne $true -or
    $Result.commitChangelistReport.closeReport.repositoryClosed -ne $true) {
    throw "Installed Source Control UI E2E result must include a Commit Changelist workflow proving group command execution, changelist filtering, projection refresh, and evidence cleanup."
  }
  if ($Result.revertChangelistReport.kind -ne "subversionr.installedSourceControlUiE2eRevertChangelistWorkflow" -or
    $Result.revertChangelistReport.command.command -ne "subversionr.revertChangelist" -or
    $Result.revertChangelistReport.command.changelist -ne "review" -or
    $Result.revertChangelistReport.prompt.clickButtonText -ne "Revert" -or
    $Result.revertChangelistReport.assertions.revertUsedChangelistFilter -ne $true -or
    $Result.revertChangelistReport.assertions.workingCopyContentRestored -ne $true -or
    $Result.revertChangelistReport.closeReport.repositoryClosed -ne $true) {
    throw "Installed Source Control UI E2E result must include a Revert Changelist workflow proving group command execution, confirmation, changelist filtering, revert, and evidence cleanup."
  }
  if ($Result.fullReconcileCancellationReport.kind -ne "subversionr.installedSourceControlUiE2eFullReconcileCancellationWorkflow" -or
    $Result.fullReconcileCancellationReport.command.command -ne "subversionr.fullReconcile" -or
    $Result.fullReconcileCancellationReport.prompt.clickButtonText -ne "Cancel" -or
    $Result.fullReconcileCancellationReport.cancellationReport.kind -ne "subversionr.installedSourceControlUiE2eFullReconcileCancellationReport" -or
    $Result.fullReconcileCancellationReport.cancellationReport.assertions.cancellationObserved -ne $true -or
    $Result.fullReconcileCancellationReport.cancellationReport.assertions.signalProvided -ne $true -or
    $Result.fullReconcileCancellationReport.cancellationReport.assertions.signalAborted -ne $true -or
    $Result.fullReconcileCancellationReport.cancellationReport.assertions.matchedManualFullReconcile -ne $true -or
    $Result.fullReconcileCancellationReport.assertions.cancellationReason -ne "userCancelled" -or
    $Result.fullReconcileCancellationReport.assertions.recoveryFullReconcileExecuted -ne $true -or
    $Result.fullReconcileCancellationReport.assertions.sourceControlSurfaceAfterRecovery -ne $true) {
    throw "Installed Source Control UI E2E result must include a Full Reconcile cancellation workflow proving progress cancellation, userCancelled propagation, and recovery."
  }
  Assert-FreshnessReport -Report $Result.fullReconcileCancellationReport.recoveryFreshnessReport -Scenario "partial" -OpenReport $Result.openReport
  if ($Result.dirtyGenerationCancellationLoadReport.kind -ne "subversionr.installedSourceControlUiE2eDirtyGenerationCancellationLoadWorkflow" -or
    $Result.dirtyGenerationCancellationLoadReport.command.command -ne "subversionr.refreshRepository" -or
    $Result.dirtyGenerationCancellationLoadReport.armReport.kind -ne "subversionr.installedSourceControlUiE2eDirtyGenerationCancellationArmReport" -or
    $Result.dirtyGenerationCancellationLoadReport.firstDirtyEventReport.kind -ne "subversionr.installedSourceControlUiE2eDirtyEventReport" -or
    $Result.dirtyGenerationCancellationLoadReport.secondDirtyEventReport.kind -ne "subversionr.installedSourceControlUiE2eDirtyEventReport" -or
    $Result.dirtyGenerationCancellationLoadReport.firstDirtyEventReport.accepted -ne $true -or
    $Result.dirtyGenerationCancellationLoadReport.secondDirtyEventReport.accepted -ne $true -or
    $Result.dirtyGenerationCancellationLoadReport.cancellationReport.kind -ne "subversionr.installedSourceControlUiE2eDirtyGenerationCancellationReport" -or
    $Result.dirtyGenerationCancellationLoadReport.cancellationReport.target.path -ne "load/modified-002.txt" -or
    $Result.dirtyGenerationCancellationLoadReport.cancellationReport.target.reason -ne "fileChanged" -or
    $Result.dirtyGenerationCancellationLoadReport.cancellationReport.assertions.matchedDirtyGenerationTarget -ne $true -or
    $Result.dirtyGenerationCancellationLoadReport.cancellationReport.assertions.signalProvided -ne $true -or
    $Result.dirtyGenerationCancellationLoadReport.cancellationReport.assertions.signalAborted -ne $true -or
    $Result.dirtyGenerationCancellationLoadReport.cancellationReport.assertions.cancellationObserved -ne $true -or
    $Result.dirtyGenerationCancellationLoadReport.assertions.firstRefreshObservedBeforeSupersede -ne $true -or
    $Result.dirtyGenerationCancellationLoadReport.assertions.cancellationReason -ne "dirtyGenerationSuperseded" -or
    $Result.dirtyGenerationCancellationLoadReport.assertions.postCancellationStaleCaptureAvailable -ne $true -or
    $Result.dirtyGenerationCancellationLoadReport.assertions.postCancellationRefreshAttempted -ne $true -or
    $Result.dirtyGenerationCancellationLoadReport.assertions.completedCoverageMatchedSupersededTargets -ne $true -or
    $Result.dirtyGenerationCancellationLoadReport.assertions.sourceControlSurfaceAfterCompletion -ne $true) {
    throw "Installed Source Control UI E2E result must include a dirty-generation cancellation load workflow proving superseded dirty refresh cancellation and completed post-cancellation coverage."
  }
  Assert-FreshnessReport -Report $Result.dirtyGenerationCancellationLoadReport.postCancellationFreshnessReport -Scenario "stale" -OpenReport $Result.dirtyGenerationCancellationLoadReport
  Assert-FreshnessReport -Report $Result.dirtyGenerationCancellationLoadReport.postCancellationCompletionFreshnessReport -Scenario "partial" -OpenReport $Result.dirtyGenerationCancellationLoadReport
  if ($Result.dirtyGenerationCancellationLoadReport.postCancellationCompletionFreshnessReport.lastCompletedRefresh.targets[0].path -ne "load/modified-002.txt" -or
    $Result.dirtyGenerationCancellationLoadReport.postCancellationCompletionFreshnessReport.lastCompletedRefresh.targets[1].path -ne "load/modified-003.txt") {
    throw "Installed Source Control UI E2E dirty-generation cancellation completed coverage must include both superseded load targets."
  }
  if ($Result.refreshReport.kind -ne "subversionr.installedSourceControlUiE2eRefreshWorkflow" -or
    $Result.refreshReport.command.command -ne "subversionr.refreshRepository" -or
    $Result.refreshReport.repository.repositoryId -ne $Result.openReport.repository.repositoryId -or
    $Result.refreshReport.assertions.singleOpenRepositoryPath -ne $true -or
    $Result.refreshReport.assertions.repositoryOpenBefore -ne $true -or
    $Result.refreshReport.assertions.sourceControlSurfaceAfterRefresh -ne $true) {
    throw "Installed Source Control UI E2E result must include a Refresh workflow proving single-repository command execution and post-refresh SourceControl availability."
  }
  Assert-FreshnessReport -Report $Result.refreshReport.postRefreshFreshnessReport -Scenario "partial" -OpenReport $Result.openReport
  if ($Result.refreshLoadReport.kind -ne "subversionr.installedSourceControlUiE2eRefreshLoadWorkflow" -or
    $Result.refreshLoadReport.command.command -ne "subversionr.refreshRepository" -or
    $Result.refreshLoadReport.load.requestedModifiedItemCount -ne 64 -or
    $Result.refreshLoadReport.load.projectedModifiedItemCountBefore -ne 64 -or
    $Result.refreshLoadReport.load.projectedModifiedItemCountAfter -ne 64 -or
    $Result.refreshLoadReport.resourceRefresh.command.command -ne "subversionr.refreshResource" -or
    $Result.refreshLoadReport.resourceRefresh.restoredPath -ne "load/modified-001.txt" -or
    $Result.refreshLoadReport.resourceRefresh.projectedModifiedItemCountBefore -ne 64 -or
    $Result.refreshLoadReport.resourceRefresh.projectedModifiedItemCountAfter -ne 63 -or
    $Result.refreshLoadReport.resourceRefresh.projectedRestoredItemCountAfter -ne 0 -or
    $Result.refreshLoadReport.resourceRefresh.coverage.targets[0].path -ne "load/modified-001.txt" -or
    $Result.refreshLoadReport.resourceRefresh.coverage.targets[0].depth -ne "empty" -or
    $Result.refreshLoadReport.resourceRefresh.coverage.targets[0].reason -ne "resourceRefresh" -or
    $Result.refreshLoadReport.resourceRefresh.coverage.coverage[0].path -ne "load/modified-001.txt" -or
    $Result.refreshLoadReport.resourceRefresh.coverage.coverage[0].depth -ne "empty" -or
    $Result.refreshLoadReport.resourceRefresh.coverage.coverage[0].reason -ne "resourceRefresh" -or
    $Result.refreshLoadReport.resourceRefresh.coverage.coverage[0].generation -ne $Result.refreshLoadReport.resourceRefresh.coverage.generation -or
    $Result.refreshLoadReport.assertions.repositoryOpenBefore -ne $true -or
    $Result.refreshLoadReport.assertions.allLoadResourcesProjectedBefore -ne $true -or
    $Result.refreshLoadReport.assertions.allLoadResourcesProjectedAfter -ne $true -or
    $Result.refreshLoadReport.assertions.sourceControlSurfaceAfterRefresh -ne $true -or
    $Result.refreshLoadReport.assertions.restoredPathProjectedBefore -ne $true -or
    $Result.refreshLoadReport.assertions.sourceControlProjectionRemovedRestoredPath -ne $true -or
    $Result.refreshLoadReport.assertions.restoredPathCoverageMatched -ne $true -or
    $Result.refreshLoadReport.assertions.restoredPathCoverageGenerationMatched -ne $true -or
    $Result.refreshLoadReport.assertions.sourceControlSurfaceAfterResourceRefresh -ne $true) {
    throw "Installed Source Control UI E2E result must include a Refresh load workflow proving modified load-resource projection and restored-path mark/sweep removal."
  }
  Assert-FreshnessReport -Report $Result.refreshLoadReport.postRefreshFreshnessReport -Scenario "partial" -OpenReport $Result.refreshLoadReport.openReport
  Assert-FreshnessReport -Report $Result.refreshLoadReport.resourceRefresh.postRefreshFreshnessReport -Scenario "partial" -OpenReport $Result.refreshLoadReport.openReport
  if ($Result.boundaryLoadReport.kind -ne "subversionr.installedSourceControlUiE2eBoundaryLoadWorkflow" -or
    $Result.boundaryLoadReport.command.command -ne "subversionr.diagnostics.installedSourceControlUiE2eLazyExternalProviderReport" -or
    $Result.boundaryLoadReport.load.requestedParentModifiedItemCount -ne 128 -or
    $Result.boundaryLoadReport.load.projectedParentModifiedItemCount -ne 128 -or
    $Result.boundaryLoadReport.load.requestedBoundaryModifiedItemCount -ne 128 -or
    $Result.boundaryLoadReport.load.projectedBoundaryModifiedItemCount -ne 0 -or
    $Result.boundaryLoadReport.load.projectedExternalModifiedItemCount -ne 128 -or
    @($Result.boundaryLoadReport.repository.boundaryRoots).Count -eq 0 -or
    $Result.boundaryLoadReport.assertions.boundaryRootsPresent -ne $true -or
    $Result.boundaryLoadReport.assertions.allParentLoadResourcesProjected -ne $true -or
    $Result.boundaryLoadReport.assertions.noBoundaryLoadResourcesProjected -ne $true -or
    $Result.boundaryLoadReport.assertions.allExternalLoadResourcesProjectedByExternalProvider -ne $true -or
    $Result.boundaryLoadReport.assertions.sourceControlSurfaceAvailable -ne $true) {
    throw "Installed Source Control UI E2E result must include a boundary load workflow proving parent load projection and boundary exclusion under load."
  }
  if ($Result.multiRepositoryRefreshReport.kind -ne "subversionr.installedSourceControlUiE2eMultiRepositoryRefreshWorkflow" -or
    $Result.multiRepositoryRefreshReport.command.command -ne "subversionr.refreshRepository" -or
    $Result.multiRepositoryRefreshReport.selectedRepository.repositoryId -eq $Result.openReport.repository.repositoryId -or
    $Result.multiRepositoryRefreshReport.selection.selectedRepositoryId -ne $Result.multiRepositoryRefreshReport.selectedRepository.repositoryId -or
    $Result.multiRepositoryRefreshReport.assertions.quickPickSelectionRequired -ne $true -or
    $Result.multiRepositoryRefreshReport.assertions.selectedRepositoryDistinct -ne $true -or
    $Result.multiRepositoryRefreshReport.assertions.selectedRepositoryRefreshed -ne $true -or
    $Result.multiRepositoryRefreshReport.assertions.firstRepositoryStayedOpen -ne $true -or
    $Result.multiRepositoryRefreshReport.assertions.sourceControlSurfaceAfterRefresh -ne $true) {
    throw "Installed Source Control UI E2E result must include a multi-repository Refresh workflow proving QuickPick selection and selected-repository refresh."
  }
  Assert-FreshnessReport -Report $Result.multiRepositoryRefreshReport.postRefreshFreshnessReport -Scenario "partial" -OpenReport $Result.multiRepositoryRefreshReport.selectedRepositoryOpenReport
  if ($Result.lazyExternalProviderReport.kind -ne "subversionr.installedSourceControlUiE2eLazyExternalProviderReport" -or
    $Result.lazyExternalProviderReport.request.externalsMode -ne "lazy" -or
    $Result.lazyExternalProviderReport.request.discoveryDepth -ne 4 -or
    @($Result.lazyExternalProviderReport.discovery.fileExternalBoundaries).Count -eq 0 -or
    @($Result.lazyExternalProviderReport.parentProvider.boundaryRoots).Count -eq 0 -or
    @($Result.lazyExternalProviderReport.externalProviders).Count -eq 0 -or
    @($Result.lazyExternalProviderReport.externalProviders.sourceControl.groups.resources | Where-Object { $_.path -eq "src/tracked.txt" }).Count -eq 0 -or
    $Result.lazyExternalProviderReport.assertions.directoryExternalDiscovered -ne $true -or
    $Result.lazyExternalProviderReport.assertions.fileExternalBoundariesDiscovered -ne $true -or
    $Result.lazyExternalProviderReport.assertions.parentBoundaryRootsIncludedDirectoryExternal -ne $true -or
    $Result.lazyExternalProviderReport.assertions.parentBoundaryRootsIncludedFileExternal -ne $true -or
    $Result.lazyExternalProviderReport.assertions.distinctExternalProviderOpened -ne $true -or
    $Result.lazyExternalProviderReport.assertions.parentSourceControlExcludedExternalBoundaries -ne $true -or
    $Result.lazyExternalProviderReport.assertions.providersClosed -ne $true) {
    throw "Installed Source Control UI E2E result must include a lazy external provider workflow proving lazy discovery, boundary propagation, provider split, and cleanup."
  }
  if ($Result.closeReport.kind -ne "subversionr.installedSourceControlUiE2eCloseReport" -or $Result.closeReport.repositoryClosed -ne $true) {
    throw "Installed Source Control UI E2E result must include a close report."
  }
  if ($Result.openReport.repository.repositoryId -ne $Result.closeReport.repositoryId -or $Result.openReport.repository.epoch -ne $Result.closeReport.epoch) {
    throw "Installed Source Control UI E2E close report must match the open report repository identity."
  }
  if ($Result.repositoryLifecycleDeletionReport.kind -ne "subversionr.installedRepositoryLifecycleReport" -or
    $Result.repositoryLifecycleDeletionReport.request.scenario -ne "deletedWorkingCopy" -or
    $Result.repositoryLifecycleDeletionReport.assertions.missingWorkingCopyClosed -ne $true) {
    throw "Installed Source Control UI E2E result must include a deletion lifecycle report proving missing working-copy closure."
  }
  if ($Result.repositoryLifecycleMoveReport.kind -ne "subversionr.installedRepositoryLifecycleReport" -or
    $Result.repositoryLifecycleMoveReport.request.scenario -ne "movedWorkingCopy" -or
    $Result.repositoryLifecycleMoveReport.assertions.movedWorkingCopyRecovered -ne $true) {
    throw "Installed Source Control UI E2E result must include a move lifecycle report proving moved working-copy recovery."
  }
  if ($Result.deleteUnversionedReport.kind -ne "subversionr.installedSourceControlUiE2eDeleteUnversionedWorkflow" -or
    $Result.deleteUnversionedReport.command.command -ne "subversionr.deleteUnversionedResource" -or
    $Result.deleteUnversionedReport.resource.path -ne "scratch.txt" -or
    $Result.deleteUnversionedReport.assertions.fileExistedBefore -ne $true -or
    $Result.deleteUnversionedReport.assertions.fileExistsAfter -ne $false -or
    $Result.deleteUnversionedReport.assertions.resourcePresentAfter -ne $false) {
    throw "Installed Source Control UI E2E result must include a Delete Unversioned workflow proving command execution and projection refresh."
  }
  if ($Result.deleteUnversionedLoadReport.kind -ne "subversionr.installedSourceControlUiE2eDeleteUnversionedLoadWorkflow" -or
    $Result.deleteUnversionedLoadReport.command.command -ne "subversionr.deleteAllUnversionedResources" -or
    $Result.deleteUnversionedLoadReport.load.requestedItemCount -ne 64 -or
    $Result.deleteUnversionedLoadReport.load.projectedItemCountBefore -ne 64 -or
    $Result.deleteUnversionedLoadReport.load.projectedItemCountAfter -ne 0 -or
    $Result.deleteUnversionedLoadReport.assertions.allFilesExistedBefore -ne $true -or
    $Result.deleteUnversionedLoadReport.assertions.anyFileExistsAfter -ne $false -or
    $Result.deleteUnversionedLoadReport.assertions.sourceControlProjectionCleared -ne $true) {
    throw "Installed Source Control UI E2E result must include a Delete Unversioned load workflow proving delete-all command execution and projection clearing."
  }
  if ($Result.addReport.kind -ne "subversionr.installedSourceControlUiE2eAddWorkflow" -or
    $Result.addReport.command.command -ne "subversionr.addResource" -or
    $Result.addReport.resource.path -ne "scratch.txt" -or
    $Result.addReport.resource.contextValue -ne "subversionr.unversioned" -or
    $Result.addReport.postAddResource.contextValue -ne "subversionr.changedFile" -or
    $Result.addReport.assertions.fileExistedBefore -ne $true -or
    $Result.addReport.assertions.fileExistsAfter -ne $true -or
    $Result.addReport.assertions.sourceControlProjectionRefreshed -ne $true) {
    throw "Installed Source Control UI E2E result must include an Add workflow proving command execution, file preservation, and projection refresh."
  }
  if ($Result.moveReport.kind -ne "subversionr.installedSourceControlUiE2eMoveWorkflow" -or
    $Result.moveReport.command.command -ne "subversionr.moveResource" -or
    $Result.moveReport.resource.path -ne "src/tracked.txt" -or
    $Result.moveReport.resource.contextValue -ne "subversionr.changedFile.baseDiffable" -or
    $Result.moveReport.request.destinationPath -ne "src/moved.txt" -or
    $Result.moveReport.request.makeParents -ne $false -or
    $Result.moveReport.postMoveSourceResource.contextValue -ne "subversionr.changedFile" -or
    $Result.moveReport.postMoveDestinationResource.contextValue -ne "subversionr.changedFile" -or
    $Result.moveReport.assertions.sourceFileExistedBefore -ne $true -or
    $Result.moveReport.assertions.sourceFileExistsAfter -ne $false -or
    $Result.moveReport.assertions.destinationFileExistsAfter -ne $true -or
    $Result.moveReport.assertions.sourceControlProjectionRefreshed -ne $true) {
    throw "Installed Source Control UI E2E result must include a Move workflow proving command execution, QuickInput destination, filesystem move, and projection refresh."
  }
  if ($Result.moveCancellationReport.kind -ne "subversionr.installedSourceControlUiE2eMoveCancellationWorkflow" -or
    $Result.moveCancellationReport.command.command -ne "subversionr.moveResource" -or
    $Result.moveCancellationReport.resource.path -ne "src/tracked.txt" -or
    $Result.moveCancellationReport.resource.contextValue -ne "subversionr.changedFile.baseDiffable" -or
    $Result.moveCancellationReport.prompt.cancelKey -ne "Escape" -or
    $Result.moveCancellationReport.postCancelSourceResource.contextValue -ne "subversionr.changedFile.baseDiffable" -or
    $Result.moveCancellationReport.postCancelDestinationResourcePresent -ne $false -or
    $Result.moveCancellationReport.assertions.commandCancelled -ne $true -or
    $Result.moveCancellationReport.assertions.sourceFileExistedBefore -ne $true -or
    $Result.moveCancellationReport.assertions.sourceFileExistsAfter -ne $true -or
    $Result.moveCancellationReport.assertions.destinationFileExistsAfter -ne $false -or
    $Result.moveCancellationReport.assertions.sourceControlProjectionUnchanged -ne $true) {
    throw "Installed Source Control UI E2E result must include a Move cancellation workflow proving Escape cancellation preserved filesystem and SourceControl projection."
  }
  if ($Result.removeReport.kind -ne "subversionr.installedSourceControlUiE2eRemoveWorkflow" -or
    $Result.removeReport.command.command -ne "subversionr.removeResource" -or
    $Result.removeReport.resource.path -ne "src/tracked.txt" -or
    $Result.removeReport.resource.contextValue -ne "subversionr.changedFile" -or
    $Result.removeReport.postRemoveResource.contextValue -ne "subversionr.changedFile" -or
    $Result.removeReport.assertions.fileExistedBefore -ne $false -or
    $Result.removeReport.assertions.fileExistsAfter -ne $false -or
    $Result.removeReport.assertions.sourceControlProjectionRefreshed -ne $true) {
    throw "Installed Source Control UI E2E result must include a Remove workflow proving command execution, scheduled deletion, and projection refresh."
  }
  if ($Result.removeCancellationReport.kind -ne "subversionr.installedSourceControlUiE2eRemoveCancellationWorkflow" -or
    $Result.removeCancellationReport.command.command -ne "subversionr.removeResource" -or
    $Result.removeCancellationReport.resource.path -ne "src/tracked.txt" -or
    $Result.removeCancellationReport.resource.contextValue -ne "subversionr.changedFile.baseDiffable" -or
    $Result.removeCancellationReport.prompt.cancelAction -ne "notifications.clearAll" -or
    $Result.removeCancellationReport.notificationCleanup.command -ne "notifications.clearAll" -or
    $Result.removeCancellationReport.notificationCleanup.label -ne "removeCancellation" -or
    $Result.removeCancellationReport.notificationCleanup.cleared -ne $true -or
    $Result.removeCancellationReport.postCancelResource.contextValue -ne "subversionr.changedFile.baseDiffable" -or
    $Result.removeCancellationReport.assertions.commandCancelled -ne $true -or
    $Result.removeCancellationReport.assertions.fileExistedBefore -ne $true -or
    $Result.removeCancellationReport.assertions.fileExistsAfter -ne $true -or
    $Result.removeCancellationReport.assertions.fileContentAfter -ne "modified by M7j3`n" -or
    $Result.removeCancellationReport.assertions.sourceControlProjectionUnchanged -ne $true) {
    throw "Installed Source Control UI E2E result must include a Remove cancellation workflow proving notification cleanup cancellation preserved file content and SourceControl projection."
  }
  if ($Result.removeKeepLocalReport.kind -ne "subversionr.installedSourceControlUiE2eRemoveKeepLocalWorkflow" -or
    $Result.removeKeepLocalReport.command.command -ne "subversionr.removeResourceKeepLocal" -or
    $Result.removeKeepLocalReport.resource.path -ne "src/tracked.txt" -or
    $Result.removeKeepLocalReport.assertions.fileExistedBefore -ne $true -or
    $Result.removeKeepLocalReport.assertions.fileExistsAfter -ne $true -or
    $Result.removeKeepLocalReport.assertions.sourceControlProjectionRefreshed -ne $true -or
    $Result.removeKeepLocalReport.postRemoveResource.contextValue -ne "subversionr.changedFile") {
    throw "Installed Source Control UI E2E result must include a Keep-local Remove workflow proving command execution, local-file preservation, and projection refresh."
  }
  if ($Result.revertReport.kind -ne "subversionr.installedSourceControlUiE2eRevertWorkflow" -or
    $Result.revertReport.command.command -ne "subversionr.revertResource" -or
    $Result.revertReport.resource.path -ne "src/tracked.txt" -or
    $Result.revertReport.assertions.fileExistedBefore -ne $true -or
    $Result.revertReport.assertions.fileContentAfter -ne "initial`n" -or
    $Result.revertReport.assertions.resourcePresentAfter -ne $false) {
    throw "Installed Source Control UI E2E result must include a Revert workflow proving command execution, baseline restoration, and projection clearing."
  }
  if ($Result.revertCancellationReport.kind -ne "subversionr.installedSourceControlUiE2eRevertCancellationWorkflow" -or
    $Result.revertCancellationReport.command.command -ne "subversionr.revertResource" -or
    $Result.revertCancellationReport.resource.path -ne "src/tracked.txt" -or
    $Result.revertCancellationReport.resource.contextValue -ne "subversionr.changedFile.baseDiffable" -or
    $Result.revertCancellationReport.prompt.cancelAction -ne "notifications.clearAll" -or
    $Result.revertCancellationReport.notificationCleanup.command -ne "notifications.clearAll" -or
    $Result.revertCancellationReport.notificationCleanup.label -ne "revertCancellation" -or
    $Result.revertCancellationReport.notificationCleanup.cleared -ne $true -or
    $Result.revertCancellationReport.postCancelResource.contextValue -ne "subversionr.changedFile.baseDiffable" -or
    $Result.revertCancellationReport.assertions.commandCancelled -ne $true -or
    $Result.revertCancellationReport.assertions.fileExistedBefore -ne $true -or
    $Result.revertCancellationReport.assertions.fileContentAfter -ne "modified by M7j3`n" -or
    $Result.revertCancellationReport.assertions.resourcePresentAfter -ne $true -or
    $Result.revertCancellationReport.assertions.sourceControlProjectionUnchanged -ne $true) {
    throw "Installed Source Control UI E2E result must include a Revert cancellation workflow proving notification cleanup cancellation preserved file content and SourceControl projection."
  }
  if ($Result.resolveReport.kind -ne "subversionr.installedSourceControlUiE2eResolveWorkflow" -or
    $Result.resolveReport.command.command -ne "subversionr.resolveResource" -or
    $Result.resolveReport.resource.path -ne "src/tracked.txt" -or
    $Result.resolveReport.resource.contextValue -ne "subversionr.conflicted" -or
    $Result.resolveReport.request.choice -ne "working" -or
    $Result.resolveReport.request.depth -ne "empty" -or
    $Result.resolveReport.postResolveResource.contextValue -ne "subversionr.changedFile.baseDiffable" -or
    $Result.resolveReport.assertions.conflictProjectedBefore -ne $true -or
    $Result.resolveReport.assertions.conflictProjectedAfter -ne $false -or
    $Result.resolveReport.assertions.fileContentPreservedAfter -ne $true -or
    $Result.resolveReport.assertions.sourceControlProjectionRefreshed -ne $true) {
    throw "Installed Source Control UI E2E result must include a Resolve workflow proving merged conflict resolution, working-copy content preservation, and projection refresh."
  }
  if ($Result.resolveCancellationReport.kind -ne "subversionr.installedSourceControlUiE2eResolveCancellationWorkflow" -or
    $Result.resolveCancellationReport.command.command -ne "subversionr.resolveResource" -or
    $Result.resolveCancellationReport.resource.path -ne "src/tracked.txt" -or
    $Result.resolveCancellationReport.resource.contextValue -ne "subversionr.conflicted" -or
    $Result.resolveCancellationReport.prompt.cancelKey -ne "Escape" -or
    $Result.resolveCancellationReport.notificationCleanup.command -ne "notifications.clearAll" -or
    $Result.resolveCancellationReport.notificationCleanup.label -ne "resolveResourceCancellation" -or
    $Result.resolveCancellationReport.notificationCleanup.cleared -ne $true -or
    $Result.resolveCancellationReport.postCancelResource.contextValue -ne "subversionr.conflicted" -or
    $Result.resolveCancellationReport.assertions.commandCancelled -ne $true -or
    $Result.resolveCancellationReport.assertions.conflictProjectedBefore -ne $true -or
    $Result.resolveCancellationReport.assertions.conflictProjectedAfter -ne $true -or
    $Result.resolveCancellationReport.assertions.fileContentPreservedAfter -ne $true -or
    $Result.resolveCancellationReport.assertions.sourceControlProjectionUnchanged -ne $true) {
    throw "Installed Source Control UI E2E result must include a Resolve cancellation workflow proving QuickInput cancellation preserved conflict content and SourceControl projection."
  }
  if ($Result.cleanupReport.kind -ne "subversionr.installedSourceControlUiE2eCleanupWorkflow" -or
    $Result.cleanupReport.command.command -ne "subversionr.cleanupRepository" -or
    $Result.cleanupReport.request.path -ne "." -or
    $Result.cleanupReport.request.breakLocks -ne $true -or
    $Result.cleanupReport.request.vacuumPristines -ne $false -or
    $Result.cleanupReport.prompt.quickInputSubmitKey -ne "Enter" -or
    $Result.cleanupReport.assertions.repositoryOpenBefore -ne $true -or
    $Result.cleanupReport.assertions.fullReconcileAfterCleanup -ne $true -or
    $Result.cleanupReport.assertions.sourceControlSurfaceAfterCleanup -ne $true) {
    throw "Installed Source Control UI E2E result must include a Cleanup workflow proving command execution, conservative root cleanup options, and post-cleanup SourceControl reconciliation."
  }
  if ($Result.openReport.surfaceWorkflow.repositoryOpen -ne $true -or
    $Result.openReport.surfaceWorkflow.scmProjection -ne $true -or
    $Result.openReport.surfaceWorkflow.sourceControlSurface -ne $true -or
    $Result.openReport.surfaceWorkflow.repositoryClosed -ne $false) {
    throw "Installed Source Control UI E2E open report must prove open, SCM projection, SourceControl surface, and live repository state."
  }
  if (-not (Test-IsSamePath -Left ([string]$Result.openReport.repository.identity.workingCopyRoot) -Right $WorkingCopyRoot)) {
    throw "Installed Source Control UI E2E open report workingCopyRoot must match the fixture working copy."
  }
  Assert-ResourcePresent -OpenReport $Result.openReport -GroupId "changes" -Path "src/tracked.txt" -ContextValue "subversionr.changedFile.baseDiffable"
  Assert-ResourcePresent -OpenReport $Result.openReport -GroupId "unversioned" -Path "scratch.txt" -ContextValue "subversionr.unversioned"
  if ($Result.versionReport.kind -ne "subversionr.versionReport") {
    throw "Installed Source Control UI E2E result must include a SubversionR version report."
  }
  if ($Result.versionReport.backend.status -ne "initialized") {
    throw "Installed Source Control UI E2E version report backend status must be initialized."
  }
  if (-not ([string]$Result.versionReport.backend.libsvnVersion).StartsWith("1.14.5", [System.StringComparison]::Ordinal)) {
    throw "Installed Source Control UI E2E version report libsvnVersion must start with 1.14.5."
  }
  foreach ($capability in @("repositoryOpen", "statusSnapshot", "statusRefresh", "realLibsvnBridge")) {
    if ($Result.versionReport.backend.capabilities.$capability -ne $true) {
      throw "Installed Source Control UI E2E backend capability $capability must be true."
    }
  }
  $extensionPath = [string]$Result.extensionPath
  if (-not (Test-IsPathWithin -Path $extensionPath -Root $ExtensionsRoot)) {
    throw "Installed Source Control UI E2E result extension path must be under the isolated extensions root."
  }
  if (-not (Test-IsSamePath -Left $extensionPath -Right $InstalledPackageRoot)) {
    throw "Installed Source Control UI E2E result extension path must match the installed VSIX package root."
  }
}

function Assert-FreshnessReport([object]$Report, [string]$Scenario, [object]$OpenReport) {
  if ($Report.kind -ne "subversionr.installedSourceControlUiE2eFreshnessReport") {
    throw "Installed Source Control UI E2E result must include a $Scenario freshness report."
  }
  if ($Report.scenario -ne $Scenario) {
    throw "Installed Source Control UI E2E $Scenario freshness report scenario mismatch."
  }
  if ($Report.repository.repositoryId -ne $OpenReport.repository.repositoryId -or $Report.repository.epoch -ne $OpenReport.repository.epoch) {
    throw "Installed Source Control UI E2E $Scenario freshness report must match the open report repository identity."
  }
  if ($Report.freshnessWorkflow.repositoryOpen -ne $true -or
    $Report.freshnessWorkflow.currentEpochMatched -ne $true -or
    $Report.freshnessWorkflow.sourceControlSurface -ne $true) {
    throw "Installed Source Control UI E2E $Scenario freshness report must prove the live SourceControl surface."
  }
  if ($Report.sourceControl.freshness.repositoryCompleteness -ne $Scenario) {
    throw "Installed Source Control UI E2E $Scenario freshness report must expose $Scenario repository completeness."
  }
  $commands = @($Report.sourceControl.statusBarCommands)
  if ($commands.Count -ne 1) {
    throw "Installed Source Control UI E2E $Scenario freshness report must expose exactly one SourceControl status bar command."
  }
  $expectedTitle = $(if ($Scenario -eq "partial") { "SVN status partial" } else { "SVN status stale" })
  if ($commands[0].command -ne "subversionr.fullReconcile" -or $commands[0].title -ne $expectedTitle) {
    throw "Installed Source Control UI E2E $Scenario freshness report must expose the full reconcile status command."
  }
  $arguments = @($commands[0].arguments)
  if ($arguments.Count -ne 1 -or $arguments[0] -ne $OpenReport.repository.repositoryId) {
    throw "Installed Source Control UI E2E $Scenario freshness report full reconcile command must target the open repository."
  }
  Assert-ResourcePresent -OpenReport $Report -GroupId "changes" -Path "src/tracked.txt" -ContextValue "subversionr.changedFile.baseDiffable"
  Assert-ResourcePresent -OpenReport $Report -GroupId "unversioned" -Path "scratch.txt" -ContextValue "subversionr.unversioned"
}

function Assert-ArtifactHash([string]$CaptureRoot, [object]$Artifact, [string]$Name) {
  if ($Artifact.status -ne "captured") {
    throw "Renderer capture $Name artifact status must be captured."
  }
  if ([string]::IsNullOrWhiteSpace([string]$Artifact.relativePath)) {
    throw "Renderer capture $Name artifact relativePath is required."
  }
  $artifactPath = [System.IO.Path]::GetFullPath((Join-Path $CaptureRoot ([string]$Artifact.relativePath)))
  if (-not (Test-IsPathWithin -Path $artifactPath -Root $CaptureRoot)) {
    throw "Renderer capture $Name artifact must stay inside the capture root."
  }
  if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
    throw "Renderer capture $Name artifact file is missing: $artifactPath"
  }
  $actualHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualHash -ne [string]$Artifact.sha256) {
    throw "Renderer capture $Name artifact hash mismatch."
  }
  return $artifactPath
}

function Assert-TokenArray([object]$Tokens, [string]$Name) {
  $values = @($Tokens)
  if ($values.Count -eq 0) {
    throw "$Name must contain at least one token."
  }
  foreach ($value in $values) {
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
      throw "$Name must contain only non-empty string tokens."
    }
  }
  $values | ForEach-Object { [string]$_ }
}

function Assert-TokenListsEqual([string[]]$Expected, [object]$Actual, [string]$Name) {
  $actualValues = @($Actual | ForEach-Object { [string]$_ })
  if ($Expected.Count -ne $actualValues.Count) {
    throw "$Name token count mismatch."
  }
  for ($index = 0; $index -lt $Expected.Count; $index++) {
    if ($Expected[$index] -ne $actualValues[$index]) {
      throw "$Name token mismatch at index $index."
    }
  }
}

function Assert-TextContainsTokens([string]$Text, [string[]]$Tokens, [string]$Name) {
  $missing = @($Tokens | Where-Object { -not $Text.Contains($_) })
  if ($missing.Count -gt 0) {
    throw "$Name artifact text is missing required tokens: $($missing -join ', ')"
  }
}

function Get-PngPixelEvidence([string]$Path) {
  Add-Type -AssemblyName System.Drawing
  $bitmap = [System.Drawing.Bitmap]::new($Path)
  try {
    $sampledColors = [System.Collections.Generic.HashSet[string]]::new()
    $xStep = [Math]::Max(1, [Math]::Floor($bitmap.Width / 64))
    $yStep = [Math]::Max(1, [Math]::Floor($bitmap.Height / 64))
    for ($y = 0; $y -lt $bitmap.Height; $y += $yStep) {
      for ($x = 0; $x -lt $bitmap.Width; $x += $xStep) {
        $color = $bitmap.GetPixel($x, $y)
        [void]$sampledColors.Add("$($color.A),$($color.R),$($color.G),$($color.B)")
      }
    }
    [pscustomobject]@{
      width = $bitmap.Width
      height = $bitmap.Height
      nonBlank = $sampledColors.Count -gt 1
      uniqueColorSampleCount = $sampledColors.Count
    }
  }
  finally {
    $bitmap.Dispose()
  }
}

function Assert-RendererCaptureReport([object]$Capture, [string]$CaptureRoot, [string]$Target, [object]$OpenReport) {
  if ($Capture.schema -ne "subversionr.release.installed-source-control-ui-renderer-capture.v1") {
    throw "Renderer capture schema is unexpected: $($Capture.schema)"
  }
  if ($Capture.target -ne $Target) {
    throw "Renderer capture target must be $Target."
  }
  $captureExpectations = $OpenReport.rendererCaptureExpectations
  $expectedDomTokens = Assert-TokenArray -Tokens $captureExpectations.requiredDomTokens -Name "Open report DOM expectations"
  $expectedAccessibilityTokens = Assert-TokenArray -Tokens $captureExpectations.requiredAccessibilityTokens -Name "Open report accessibility expectations"
  $domPath = Assert-ArtifactHash -CaptureRoot $CaptureRoot -Artifact $Capture.artifacts.dom -Name "DOM"
  $accessibilityPath = Assert-ArtifactHash -CaptureRoot $CaptureRoot -Artifact $Capture.artifacts.accessibility -Name "accessibility"
  $screenshotPath = Assert-ArtifactHash -CaptureRoot $CaptureRoot -Artifact $Capture.artifacts.screenshot -Name "screenshot"
  Assert-TokenListsEqual -Expected $expectedDomTokens -Actual $Capture.artifacts.dom.requiredTokens -Name "Renderer capture DOM requiredTokens"
  Assert-TokenListsEqual -Expected $expectedAccessibilityTokens -Actual $Capture.artifacts.accessibility.requiredTokens -Name "Renderer capture accessibility requiredTokens"
  $domText = Get-Content -Raw -LiteralPath $domPath
  $accessibilityText = Get-Content -Raw -LiteralPath $accessibilityPath
  Assert-TextContainsTokens -Text $domText -Tokens $expectedDomTokens -Name "DOM"
  Assert-TextContainsTokens -Text $accessibilityText -Tokens $expectedAccessibilityTokens -Name "Accessibility"
  if (@($Capture.artifacts.dom.missingTokens).Count -ne 0) {
    throw "Renderer capture DOM report must not list missing tokens."
  }
  if (@($Capture.artifacts.accessibility.missingTokens).Count -ne 0) {
    throw "Renderer capture accessibility report must not list missing tokens."
  }
  if ($Capture.assertions.domRequiredTokensPresent -ne $true -or $Capture.assertions.accessibilityRequiredTokensPresent -ne $true) {
    throw "Renderer capture token assertions must prove required DOM and accessibility tokens."
  }
  if ($Capture.assertions.screenshotCaptured -ne $true -or $Capture.assertions.screenshotNonBlank -ne $true) {
    throw "Renderer capture screenshot assertions must prove captured nonblank pixels."
  }
  $pngEvidence = Get-PngPixelEvidence -Path $screenshotPath
  if ($pngEvidence.width -ne [int]$Capture.artifacts.screenshot.width -or $pngEvidence.height -ne [int]$Capture.artifacts.screenshot.height) {
    throw "Renderer capture screenshot dimensions must match the PNG artifact."
  }
  if ($pngEvidence.nonBlank -ne $true) {
    throw "Renderer capture screenshot PNG must contain nonblank pixel evidence."
  }
  if ($captureExpectations.PSObject.Properties.Name -contains "clickButtonText") {
    if ($Capture.interaction.clicked -ne $true -or $Capture.interaction.clickedButtonText -ne $captureExpectations.clickButtonText) {
      throw "Renderer capture interaction must click the expected VS Code button."
    }
    if ($Capture.assertions.clickButtonCompleted -ne $true) {
      throw "Renderer capture interaction assertion must prove the button click completed."
    }
  }
  if ($captureExpectations.PSObject.Properties.Name -contains "inputText") {
    if (-not ($captureExpectations.PSObject.Properties.Name -contains "submitKey")) {
      throw "Renderer capture input expectations must include submitKey."
    }
    if ($Capture.interaction.enteredText -ne $captureExpectations.inputText -or $Capture.interaction.submittedKey -ne $captureExpectations.submitKey) {
      throw "Renderer capture interaction must enter and submit the expected VS Code QuickInput text."
    }
    if ($Capture.assertions.inputTextSubmitted -ne $true) {
      throw "Renderer capture interaction assertion must prove the QuickInput submit completed."
    }
  }
  if ($captureExpectations.PSObject.Properties.Name -contains "quickPickItemText") {
    $expectedQuickPickItemText = [string]$captureExpectations.quickPickItemText
    if ([string]::IsNullOrWhiteSpace([string]$Capture.interaction.selectedText) -or -not ([string]$Capture.interaction.selectedText).Contains($expectedQuickPickItemText)) {
      throw "Renderer capture interaction must select the expected VS Code QuickPick item."
    }
    if ($Capture.assertions.quickPickItemSelected -ne $true) {
      throw "Renderer capture interaction assertion must prove the QuickPick item selection completed."
    }
  }
  if ($captureExpectations.PSObject.Properties.Name -contains "quickInputSubmitKey") {
    if ($Capture.interaction.submitted -ne $true -or $Capture.interaction.submittedKey -ne $captureExpectations.quickInputSubmitKey -or $Capture.interaction.surface -ne "quickInput") {
      throw "Renderer capture interaction must submit the expected VS Code QuickInput surface."
    }
    if ($Capture.assertions.quickInputSubmitted -ne $true) {
      throw "Renderer capture interaction assertion must prove the VS Code QuickInput submission completed."
    }
  }
  if ($captureExpectations.PSObject.Properties.Name -contains "cancelKey") {
    if ($Capture.interaction.cancelled -ne $true -or $Capture.interaction.cancelledKey -ne $captureExpectations.cancelKey) {
      throw "Renderer capture interaction must cancel the expected VS Code renderer surface."
    }
    $expectedCancelSurface = $null
    if ($captureExpectations.PSObject.Properties.Name -contains "cancelSurface") {
      $expectedCancelSurface = $captureExpectations.cancelSurface
    }
    if ($null -ne $expectedCancelSurface -and $Capture.interaction.surface -ne $expectedCancelSurface) {
      throw "Renderer capture interaction must record the expected cancelled surface."
    }
    if ($expectedCancelSurface -eq "dialog" -and $Capture.assertions.dialogCancelled -ne $true) {
      throw "Renderer capture interaction assertion must prove the VS Code dialog cancellation completed."
    }
    if ($expectedCancelSurface -eq "notification" -and $Capture.assertions.notificationCancelled -ne $true) {
      throw "Renderer capture interaction assertion must prove the VS Code notification cancellation completed."
    }
    if ($expectedCancelSurface -eq "quickInput" -and $Capture.assertions.quickInputCancelled -ne $true) {
      throw "Renderer capture interaction assertion must prove the VS Code QuickInput cancellation completed."
    }
    if ($Capture.assertions.interactionCancelled -ne $true) {
      throw "Renderer capture interaction assertion must prove the renderer cancellation completed."
    }
  }
  if ($captureExpectations.PSObject.Properties.Name -contains "cancelAction") {
    if ($Capture.interaction.cancelled -ne $true -or $Capture.interaction.cancelledAction -ne $captureExpectations.cancelAction) {
      throw "Renderer capture interaction must perform the expected VS Code renderer cancellation action."
    }
    $expectedCancelSurface = $null
    if ($captureExpectations.PSObject.Properties.Name -contains "cancelSurface") {
      $expectedCancelSurface = $captureExpectations.cancelSurface
    }
    if ($null -ne $expectedCancelSurface -and $Capture.interaction.surface -ne $expectedCancelSurface) {
      throw "Renderer capture interaction must record the expected cancelled surface."
    }
    if ($expectedCancelSurface -eq "notification" -and $Capture.assertions.notificationCancelled -ne $true) {
      throw "Renderer capture interaction assertion must prove the VS Code notification cancellation completed."
    }
    if ($Capture.assertions.interactionCancelled -ne $true) {
      throw "Renderer capture interaction assertion must prove the renderer cancellation completed."
    }
  }
}

function Invoke-HarnessPromptCapture(
  [string]$ReadyPath,
  [string]$DonePath,
  [string]$ExpectationsPath,
  [string]$CaptureRoot,
  [string]$Description,
  [string]$ExpectedCommand,
  [string]$DriverPath,
  [int]$Port,
  [string]$Target
) {
  Wait-File -Path $ReadyPath -TimeoutSeconds $UiReadyTimeoutSeconds -Description $Description
  $promptReady = Get-Content -Raw -LiteralPath $ReadyPath | ConvertFrom-Json
  if ($promptReady.ok -ne $true -or $promptReady.command -ne $ExpectedCommand) {
    throw "$Description sentinel did not include the expected command $ExpectedCommand."
  }
  $promptReady.rendererCaptureExpectations | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ExpectationsPath -Encoding utf8
  $driverError = $null
  try {
    Invoke-RendererCaptureDriver `
      -DriverPath $DriverPath `
      -Port $Port `
      -CaptureRoot $CaptureRoot `
      -ExpectationsPath $ExpectationsPath `
      -Target $Target
  }
  catch {
    $driverError = $_
  }
  finally {
    [pscustomobject]@{
      ok = $null -eq $driverError
      completedAt = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $DonePath -Encoding utf8
  }
  if ($null -ne $driverError) {
    throw $driverError
  }
}

$vsixResolved = Assert-GeneratedPath -Path $VsixPath -Name "VsixPath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\vsix")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-installed-source-control-ui-e2e-scripts"))
) -Description "target/vsix or target/tests/release-installed-source-control-ui-e2e-scripts"
$vsixResolved = Assert-File $vsixResolved "VsixPath"
$codeCliResolved = Assert-CodeCliPath $CodeCliPath
$svnToolsRootResolved = Assert-SvnToolsRoot $SvnToolsRoot
$rendererCaptureDriverResolved = Assert-RendererCaptureDriverPath $RendererCaptureDriverPath
$svnExeResolved = Assert-File (Join-Path $svnToolsRootResolved "svn.exe") "svn.exe"
$svnAdminExeResolved = Assert-File (Join-Path $svnToolsRootResolved "svnadmin.exe") "svnadmin.exe"
Assert-TcpPortAvailable $RemoteDebuggingPort

$svnVersion = (Invoke-CheckedTool -Path $svnExeResolved -Arguments @("--version", "--quiet") -Description "svn version probe" | Select-Object -First 1).ToString().Trim()
if ($svnVersion -ne "1.14.5") {
  throw "SvnToolsRoot must provide source-built Apache Subversion 1.14.5 fixture tools; got svn $svnVersion."
}
$svnAdminVersion = (Invoke-CheckedTool -Path $svnAdminExeResolved -Arguments @("--version", "--quiet") -Description "svnadmin version probe" | Select-Object -First 1).ToString().Trim()
if ($svnAdminVersion -ne "1.14.5") {
  throw "SvnToolsRoot must provide source-built Apache Subversion 1.14.5 fixture tools; got svnadmin $svnAdminVersion."
}

$fixtureRootResolved = Assert-GeneratedPath -Path $FixtureRoot -Name "FixtureRoot" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence\installed-source-control-ui-e2e")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-installed-source-control-ui-e2e-scripts"))
) -Description "the repository target directory (target/release-evidence/installed-source-control-ui-e2e or target/tests/release-installed-source-control-ui-e2e-scripts)"
$aggregateFixtureRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence\installed-source-control-ui-e2e"))
if (Test-IsSamePath -Left $fixtureRootResolved -Right $aggregateFixtureRoot) {
  throw "FixtureRoot must include a dedicated child directory below target/release-evidence/installed-source-control-ui-e2e."
}
$evidencePathResolved = Assert-GeneratedPath -Path $EvidencePath -Name "EvidencePath" -AllowedRoots @(
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release-evidence")),
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\tests\release-installed-source-control-ui-e2e-scripts"))
) -Description "target/release-evidence or target/tests/release-installed-source-control-ui-e2e-scripts"

if (Test-Path -LiteralPath $fixtureRootResolved) {
  Remove-Item -LiteralPath $fixtureRootResolved -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $fixtureRootResolved | Out-Null

$packageJson = Get-VsixPackageJson $vsixResolved
if ($packageJson.publisher -ne "hitsuki-ban" -or $packageJson.name -ne "subversionr") {
  throw "VSIX extension identity must be hitsuki-ban.subversionr."
}
$manifestTargetPlatform = Get-VsixTargetPlatform $vsixResolved
if ($manifestTargetPlatform -ne $Target) {
  throw "VSIX target platform must be $Target."
}
$extensionVersion = [string]$packageJson.version
if ([string]::IsNullOrWhiteSpace($extensionVersion)) {
  throw "VSIX package version is required."
}

$codeCliVersion = Get-CodeCliVersion $codeCliResolved
$codeCliSha256 = (Get-FileHash -LiteralPath $codeCliResolved -Algorithm SHA256).Hash.ToLowerInvariant()
$commitAllCommitMessage = "commit all eligible changed file resources for the repository input message"
$commitAllExpectedTrackedContent = "modified by M7j3"
$commitSelectedCommitMessage = "commit selected SCM resource from the repository input message"
$commitSelectedExpectedTrackedContent = "modified by M7j3"
$commitSelectedExpectedUnselectedContent = "initial load item 1"
$commitSelectedMultiSelectionCommitMessage = "commit selected SCM resources from a Source Control multi-selection"
$commitSelectedMultiSelectionExpectedTrackedContent = "modified by M7j3"
$commitSelectedMultiSelectionExpectedLoadContent = "modified load item load/modified-001.txt by M7j3"
$commitChangelistCommitMessage = "commit selected SVN changelist from the repository input message"
$commitChangelistExpectedTrackedContent = "modified by M7j3"
$deleteUnversionedLoadItemCount = 64
$refreshLoadModifiedItemCount = 64
$boundaryLoadParentModifiedItemCount = 128
$boundaryLoadBoundaryModifiedItemCount = 128
$fixture = New-SourceControlUiFixture -Root (Join-Path $fixtureRootResolved "svn-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
$multiRepositoryRefreshFixture = New-SourceControlUiFixture -Root (Join-Path $fixtureRootResolved "multi-repository-refresh-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
$lazyExternalProviderFixture = New-SourceControlUiLazyExternalProviderFixture -Root (Join-Path $fixtureRootResolved "lazy-external-provider-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
$boundaryLoadFixture = New-SourceControlUiLazyExternalProviderFixture -Root (Join-Path $fixtureRootResolved "boundary-load-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved -ParentModifiedLoadItemCount $boundaryLoadParentModifiedItemCount -ExternalModifiedLoadItemCount $boundaryLoadBoundaryModifiedItemCount
$refreshLoadFixture = New-SourceControlUiFixture -Root (Join-Path $fixtureRootResolved "refresh-load-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved -ModifiedLoadItemCount $refreshLoadModifiedItemCount
$loadFixture = New-SourceControlUiFixture -Root (Join-Path $fixtureRootResolved "delete-unversioned-load-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved -UnversionedItemCount $deleteUnversionedLoadItemCount
$commitAllFixture = New-SourceControlUiFixture -Root (Join-Path $fixtureRootResolved "commit-all-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
$commitSelectedFixture = New-SourceControlUiFixture -Root (Join-Path $fixtureRootResolved "commit-selected-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved -ModifiedLoadItemCount 1
$commitSelectedMultiSelectionFixture = New-SourceControlUiFixture -Root (Join-Path $fixtureRootResolved "commit-selected-multi-selection-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved -ModifiedLoadItemCount 1
$addToIgnoreFixture = New-SourceControlUiFixture -Root (Join-Path $fixtureRootResolved "add-to-ignore-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
$lockFixture = New-SourceControlUiLockFixture -Root (Join-Path $fixtureRootResolved "lock-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
$changelistSetClearFixture = New-SourceControlUiFixture -Root (Join-Path $fixtureRootResolved "changelist-set-clear-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
$commitChangelistFixture = New-SourceControlUiChangelistFixture -Root (Join-Path $fixtureRootResolved "commit-changelist-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved -ModifiedLoadItemCount 1
$revertChangelistFixture = New-SourceControlUiChangelistFixture -Root (Join-Path $fixtureRootResolved "revert-changelist-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
$checkoutSourceFixture = New-SourceControlUiFixture -Root (Join-Path $fixtureRootResolved "checkout-source-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
$checkoutRepositoryUrl = "$($checkoutSourceFixture.repoUrl)/trunk"
$checkoutCancellationTargetRoot = Join-Path $fixtureRootResolved "checkout-cancellation-target\wc"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $checkoutCancellationTargetRoot) | Out-Null
if (Test-Path -LiteralPath $checkoutCancellationTargetRoot) {
  throw "Checkout Repository cancellation target fixture must not exist before the installed cancellation workflow: $checkoutCancellationTargetRoot"
}
$checkoutExistingTargetFailureTargetPath = Join-Path $fixtureRootResolved "checkout-existing-target-failure\wc"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $checkoutExistingTargetFailureTargetPath) | Out-Null
Set-Content -LiteralPath $checkoutExistingTargetFailureTargetPath -Value "SubversionR obstructing checkout target sentinel`n" -NoNewline -Encoding utf8
if (-not (Test-Path -LiteralPath $checkoutExistingTargetFailureTargetPath -PathType Leaf)) {
  throw "Checkout Repository existing-target failure fixture must be an obstructing file: $checkoutExistingTargetFailureTargetPath"
}
if (Test-Path -LiteralPath (Join-Path $checkoutExistingTargetFailureTargetPath ".svn")) {
  throw "Checkout Repository existing-target failure fixture must not contain SVN metadata before the installed failure workflow: $checkoutExistingTargetFailureTargetPath"
}
if (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $checkoutExistingTargetFailureTargetPath) ".svn")) {
  throw "Checkout Repository existing-target failure parent fixture must not contain SVN metadata before the installed failure workflow: $checkoutExistingTargetFailureTargetPath"
}
$checkoutInvalidUrlFailureRepositoryUrl = "$($checkoutSourceFixture.repoUrl)/does-not-exist"
$checkoutInvalidUrlFailureTargetRoot = Join-Path $fixtureRootResolved "checkout-invalid-url-failure\wc"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $checkoutInvalidUrlFailureTargetRoot) | Out-Null
if (Test-Path -LiteralPath $checkoutInvalidUrlFailureTargetRoot) {
  throw "Checkout Repository invalid URL failure target fixture must not exist before the installed failure workflow: $checkoutInvalidUrlFailureTargetRoot"
}
if (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $checkoutInvalidUrlFailureTargetRoot) ".svn")) {
  throw "Checkout Repository invalid URL failure parent fixture must not contain SVN metadata before the installed failure workflow: $checkoutInvalidUrlFailureTargetRoot"
}
$checkoutExistingDirectoryTargetRoot = Join-Path $fixtureRootResolved "checkout-existing-directory\wc"
New-Item -ItemType Directory -Force -Path $checkoutExistingDirectoryTargetRoot | Out-Null
$checkoutExistingDirectoryLocalOnlyPath = Join-Path $checkoutExistingDirectoryTargetRoot "local-only-before-checkout.txt"
Set-Content -LiteralPath $checkoutExistingDirectoryLocalOnlyPath -Value "SubversionR local-only checkout marker`n" -NoNewline -Encoding utf8
if (-not (Test-Path -LiteralPath $checkoutExistingDirectoryTargetRoot -PathType Container)) {
  throw "Checkout Repository existing-directory target fixture must exist before the installed checkout workflow: $checkoutExistingDirectoryTargetRoot"
}
if (-not (Test-Path -LiteralPath $checkoutExistingDirectoryLocalOnlyPath -PathType Leaf)) {
  throw "Checkout Repository existing-directory target fixture must contain the local-only marker before checkout: $checkoutExistingDirectoryLocalOnlyPath"
}
if (Test-Path -LiteralPath (Join-Path $checkoutExistingDirectoryTargetRoot ".svn")) {
  throw "Checkout Repository existing-directory target fixture must not contain SVN metadata before the installed checkout workflow: $checkoutExistingDirectoryTargetRoot"
}
$checkoutExistingDirectoryObstructionTargetRoot = Join-Path $fixtureRootResolved "checkout-existing-directory-obstruction\wc"
New-Item -ItemType Directory -Force -Path $checkoutExistingDirectoryObstructionTargetRoot | Out-Null
$checkoutExistingDirectoryObstructionLocalOnlyPath = Join-Path $checkoutExistingDirectoryObstructionTargetRoot "local-only-before-checkout.txt"
$checkoutExistingDirectoryObstructionPath = Join-Path $checkoutExistingDirectoryObstructionTargetRoot "src"
Set-Content -LiteralPath $checkoutExistingDirectoryObstructionLocalOnlyPath -Value "SubversionR local-only checkout obstruction marker`n" -NoNewline -Encoding utf8
Set-Content -LiteralPath $checkoutExistingDirectoryObstructionPath -Value "SubversionR obstructing checkout source file`n" -NoNewline -Encoding utf8
if (-not (Test-Path -LiteralPath $checkoutExistingDirectoryObstructionTargetRoot -PathType Container)) {
  throw "Checkout Repository existing-directory obstruction target fixture must exist before the installed checkout workflow: $checkoutExistingDirectoryObstructionTargetRoot"
}
if (-not (Test-Path -LiteralPath $checkoutExistingDirectoryObstructionLocalOnlyPath -PathType Leaf)) {
  throw "Checkout Repository existing-directory obstruction target fixture must contain the local-only marker before checkout: $checkoutExistingDirectoryObstructionLocalOnlyPath"
}
if (-not (Test-Path -LiteralPath $checkoutExistingDirectoryObstructionPath -PathType Leaf)) {
  throw "Checkout Repository existing-directory obstruction target fixture must contain the obstructing local file before checkout: $checkoutExistingDirectoryObstructionPath"
}
if (Test-Path -LiteralPath (Join-Path $checkoutExistingDirectoryObstructionTargetRoot ".svn")) {
  throw "Checkout Repository existing-directory obstruction target fixture must not contain SVN metadata before the installed checkout workflow: $checkoutExistingDirectoryObstructionTargetRoot"
}
$checkoutTargetRoot = Join-Path $fixtureRootResolved "checkout-target\wc"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $checkoutTargetRoot) | Out-Null
if (Test-Path -LiteralPath $checkoutTargetRoot) {
  throw "Checkout Repository target fixture must not exist before the installed checkout workflow: $checkoutTargetRoot"
}
$updateFixture = New-SourceControlUiUpdateFixture -Root (Join-Path $fixtureRootResolved "update-to-revision-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
$branchCreateFixture = New-SourceControlUiBranchCreateFixture -Root (Join-Path $fixtureRootResolved "branch-create-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
$switchFixture = New-SourceControlUiSwitchFixture -Root (Join-Path $fixtureRootResolved "switch-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
$addFixture = New-SourceControlUiFixture -Root (Join-Path $fixtureRootResolved "add-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
$moveResourceFixture = New-SourceControlUiFixture -Root (Join-Path $fixtureRootResolved "move-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
$moveCancellationFixture = New-SourceControlUiFixture -Root (Join-Path $fixtureRootResolved "move-cancellation-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
$removeFixture = New-SourceControlUiFixture -Root (Join-Path $fixtureRootResolved "remove-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
Remove-Item -LiteralPath (Join-Path $removeFixture.workingCopyRoot "src\tracked.txt") -Force
$removeCancellationFixture = New-SourceControlUiFixture -Root (Join-Path $fixtureRootResolved "remove-cancellation-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
$revertFixture = New-SourceControlUiFixture -Root (Join-Path $fixtureRootResolved "revert-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
$revertCancellationFixture = New-SourceControlUiFixture -Root (Join-Path $fixtureRootResolved "revert-cancellation-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
$resolveFixture = New-SourceControlUiResolveFixture -Root (Join-Path $fixtureRootResolved "resolve-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
$resolveCancellationFixture = New-SourceControlUiResolveFixture -Root (Join-Path $fixtureRootResolved "resolve-cancellation-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
$deleteFixture = New-SourceControlUiFixture -Root (Join-Path $fixtureRootResolved "repository-lifecycle-delete-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
$moveFixture = New-SourceControlUiFixture -Root (Join-Path $fixtureRootResolved "repository-lifecycle-move-fixture") -SvnExe $svnExeResolved -SvnAdminExe $svnAdminExeResolved
$moveDestinationRoot = Join-Path $fixtureRootResolved "repository-lifecycle-move-destination\wc"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $moveDestinationRoot) | Out-Null
Copy-Item -LiteralPath $moveFixture.workingCopyRoot -Destination $moveDestinationRoot -Recurse -Force
$userDataRoot = Join-Path $fixtureRootResolved "user-data"
$extensionsRoot = Join-Path $fixtureRootResolved "extensions"
$harnessRoot = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-harness"
$harnessResultPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-result.json"
$harnessReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-ready.json"
$harnessDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-done.json"
$harnessNoRepositoryWelcomeRendererReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-no-repository-welcome-renderer-ready.json"
$harnessNoRepositoryWelcomeRendererDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-no-repository-welcome-renderer-done.json"
$harnessPartialFreshnessRendererReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-partial-freshness-renderer-ready.json"
$harnessPartialFreshnessRendererDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-partial-freshness-renderer-done.json"
$harnessStaleFreshnessRendererReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-stale-freshness-renderer-ready.json"
$harnessStaleFreshnessRendererDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-stale-freshness-renderer-done.json"
$harnessFullReconcileCancellationReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-full-reconcile-cancellation-ready.json"
$harnessFullReconcileCancellationDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-full-reconcile-cancellation-done.json"
$harnessMultiRepositoryRefreshPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-multi-repository-refresh-prompt-ready.json"
$harnessDeletePromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-delete-prompt-ready.json"
$harnessDeleteLoadPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-delete-load-prompt-ready.json"
$harnessRemovePromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-remove-prompt-ready.json"
$harnessRemoveCancellationPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-remove-cancellation-prompt-ready.json"
$harnessRemoveCancellationPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-remove-cancellation-prompt-done.json"
$harnessRemoveKeepLocalPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-remove-keep-local-prompt-ready.json"
$harnessMovePromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-move-prompt-ready.json"
$harnessMoveCancellationPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-move-cancellation-prompt-ready.json"
$harnessCheckoutCancellationPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-cancellation-prompt-ready.json"
$harnessCheckoutCancellationPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-cancellation-prompt-done.json"
$harnessCheckoutExistingTargetFailureUrlPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-target-failure-url-prompt-ready.json"
$harnessCheckoutExistingTargetFailureUrlPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-target-failure-url-prompt-done.json"
$harnessCheckoutExistingTargetFailureTargetPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-target-failure-target-prompt-ready.json"
$harnessCheckoutExistingTargetFailureTargetPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-target-failure-target-prompt-done.json"
$harnessCheckoutExistingTargetFailureRevisionPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-target-failure-revision-prompt-ready.json"
$harnessCheckoutExistingTargetFailureRevisionPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-target-failure-revision-prompt-done.json"
$harnessCheckoutExistingTargetFailureDepthPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-target-failure-depth-prompt-ready.json"
$harnessCheckoutExistingTargetFailureDepthPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-target-failure-depth-prompt-done.json"
$harnessCheckoutExistingTargetFailureExternalsPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-target-failure-externals-prompt-ready.json"
$harnessCheckoutExistingTargetFailureExternalsPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-target-failure-externals-prompt-done.json"
$harnessCheckoutExistingTargetFailureNotificationReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-target-failure-notification-ready.json"
$harnessCheckoutExistingTargetFailureNotificationDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-target-failure-notification-done.json"
$harnessCheckoutInvalidUrlFailureUrlPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-invalid-url-failure-url-prompt-ready.json"
$harnessCheckoutInvalidUrlFailureUrlPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-invalid-url-failure-url-prompt-done.json"
$harnessCheckoutInvalidUrlFailureTargetPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-invalid-url-failure-target-prompt-ready.json"
$harnessCheckoutInvalidUrlFailureTargetPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-invalid-url-failure-target-prompt-done.json"
$harnessCheckoutInvalidUrlFailureRevisionPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-invalid-url-failure-revision-prompt-ready.json"
$harnessCheckoutInvalidUrlFailureRevisionPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-invalid-url-failure-revision-prompt-done.json"
$harnessCheckoutInvalidUrlFailureDepthPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-invalid-url-failure-depth-prompt-ready.json"
$harnessCheckoutInvalidUrlFailureDepthPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-invalid-url-failure-depth-prompt-done.json"
$harnessCheckoutInvalidUrlFailureExternalsPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-invalid-url-failure-externals-prompt-ready.json"
$harnessCheckoutInvalidUrlFailureExternalsPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-invalid-url-failure-externals-prompt-done.json"
$harnessCheckoutInvalidUrlFailureNotificationReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-invalid-url-failure-notification-ready.json"
$harnessCheckoutInvalidUrlFailureNotificationDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-invalid-url-failure-notification-done.json"
$harnessCheckoutExistingDirectoryUrlPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-directory-url-prompt-ready.json"
$harnessCheckoutExistingDirectoryUrlPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-directory-url-prompt-done.json"
$harnessCheckoutExistingDirectoryTargetPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-directory-target-prompt-ready.json"
$harnessCheckoutExistingDirectoryTargetPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-directory-target-prompt-done.json"
$harnessCheckoutExistingDirectoryRevisionPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-directory-revision-prompt-ready.json"
$harnessCheckoutExistingDirectoryRevisionPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-directory-revision-prompt-done.json"
$harnessCheckoutExistingDirectoryDepthPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-directory-depth-prompt-ready.json"
$harnessCheckoutExistingDirectoryDepthPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-directory-depth-prompt-done.json"
$harnessCheckoutExistingDirectoryExternalsPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-directory-externals-prompt-ready.json"
$harnessCheckoutExistingDirectoryExternalsPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-directory-externals-prompt-done.json"
$harnessCheckoutExistingDirectoryObstructionUrlPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-directory-obstruction-url-prompt-ready.json"
$harnessCheckoutExistingDirectoryObstructionUrlPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-directory-obstruction-url-prompt-done.json"
$harnessCheckoutExistingDirectoryObstructionTargetPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-directory-obstruction-target-prompt-ready.json"
$harnessCheckoutExistingDirectoryObstructionTargetPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-directory-obstruction-target-prompt-done.json"
$harnessCheckoutExistingDirectoryObstructionRevisionPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-directory-obstruction-revision-prompt-ready.json"
$harnessCheckoutExistingDirectoryObstructionRevisionPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-directory-obstruction-revision-prompt-done.json"
$harnessCheckoutExistingDirectoryObstructionDepthPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-directory-obstruction-depth-prompt-ready.json"
$harnessCheckoutExistingDirectoryObstructionDepthPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-directory-obstruction-depth-prompt-done.json"
$harnessCheckoutExistingDirectoryObstructionExternalsPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-directory-obstruction-externals-prompt-ready.json"
$harnessCheckoutExistingDirectoryObstructionExternalsPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-existing-directory-obstruction-externals-prompt-done.json"
$harnessCheckoutUrlPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-url-prompt-ready.json"
$harnessCheckoutUrlPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-url-prompt-done.json"
$harnessCheckoutTargetPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-target-prompt-ready.json"
$harnessCheckoutTargetPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-target-prompt-done.json"
$harnessCheckoutRevisionPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-revision-prompt-ready.json"
$harnessCheckoutRevisionPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-revision-prompt-done.json"
$harnessCheckoutDepthPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-depth-prompt-ready.json"
$harnessCheckoutDepthPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-depth-prompt-done.json"
$harnessCheckoutExternalsPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-externals-prompt-ready.json"
$harnessCheckoutExternalsPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-checkout-externals-prompt-done.json"
$harnessUpdateRevisionPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-update-revision-prompt-ready.json"
$harnessUpdateRevisionPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-update-revision-prompt-done.json"
$harnessUpdateCancellationRevisionPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-update-cancellation-revision-prompt-ready.json"
$harnessUpdateCancellationRevisionPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-update-cancellation-revision-prompt-done.json"
$harnessUpdateDepthPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-update-depth-prompt-ready.json"
$harnessUpdateDepthPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-update-depth-prompt-done.json"
$harnessUpdateStickyDepthPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-update-sticky-depth-prompt-ready.json"
$harnessUpdateStickyDepthPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-update-sticky-depth-prompt-done.json"
$harnessUpdateExternalsPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-update-externals-prompt-ready.json"
$harnessUpdateExternalsPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-update-externals-prompt-done.json"
$harnessBranchCreateSourcePromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-branch-create-source-prompt-ready.json"
$harnessBranchCreateSourcePromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-branch-create-source-prompt-done.json"
$harnessBranchCreateDestinationPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-branch-create-destination-prompt-ready.json"
$harnessBranchCreateDestinationPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-branch-create-destination-prompt-done.json"
$harnessBranchCreateRevisionPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-branch-create-revision-prompt-ready.json"
$harnessBranchCreateRevisionPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-branch-create-revision-prompt-done.json"
$harnessBranchCreateMessagePromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-branch-create-message-prompt-ready.json"
$harnessBranchCreateMessagePromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-branch-create-message-prompt-done.json"
$harnessBranchCreateParentsPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-branch-create-parents-prompt-ready.json"
$harnessBranchCreateParentsPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-branch-create-parents-prompt-done.json"
$harnessBranchCreateExternalsPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-branch-create-externals-prompt-ready.json"
$harnessBranchCreateExternalsPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-branch-create-externals-prompt-done.json"
$harnessBranchCreateSwitchPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-branch-create-switch-prompt-ready.json"
$harnessBranchCreateSwitchPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-branch-create-switch-prompt-done.json"
$harnessSwitchUrlPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-switch-url-prompt-ready.json"
$harnessSwitchUrlPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-switch-url-prompt-done.json"
$harnessSwitchRevisionPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-switch-revision-prompt-ready.json"
$harnessSwitchRevisionPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-switch-revision-prompt-done.json"
$harnessSwitchDepthPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-switch-depth-prompt-ready.json"
$harnessSwitchDepthPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-switch-depth-prompt-done.json"
$harnessSwitchStickyDepthPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-switch-sticky-depth-prompt-ready.json"
$harnessSwitchStickyDepthPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-switch-sticky-depth-prompt-done.json"
$harnessSwitchExternalsPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-switch-externals-prompt-ready.json"
$harnessSwitchExternalsPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-switch-externals-prompt-done.json"
$harnessSwitchAncestryPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-switch-ancestry-prompt-ready.json"
$harnessSwitchAncestryPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-switch-ancestry-prompt-done.json"
$harnessLockMessageCancellationPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-lock-message-cancellation-prompt-ready.json"
$harnessLockMessageCancellationPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-lock-message-cancellation-prompt-done.json"
$harnessLockMessagePromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-lock-message-prompt-ready.json"
$harnessLockMessagePromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-lock-message-prompt-done.json"
$harnessLockModePromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-lock-mode-prompt-ready.json"
$harnessLockModePromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-lock-mode-prompt-done.json"
$harnessLockHeldOracleReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-lock-held-oracle-ready.json"
$harnessLockHeldOracleDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-lock-held-oracle-done.json"
$harnessUnlockModeCancellationPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-unlock-mode-cancellation-prompt-ready.json"
$harnessUnlockModeCancellationPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-unlock-mode-cancellation-prompt-done.json"
$harnessUnlockModePromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-unlock-mode-prompt-ready.json"
$harnessUnlockModePromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-unlock-mode-prompt-done.json"
$harnessChangelistSetPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-changelist-set-prompt-ready.json"
$harnessChangelistRevertPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-changelist-revert-prompt-ready.json"
$harnessRevertPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-revert-prompt-ready.json"
$harnessRevertCancellationPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-revert-cancellation-prompt-ready.json"
$harnessRevertCancellationPromptDonePath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-revert-cancellation-prompt-done.json"
$harnessResolvePromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-resolve-prompt-ready.json"
$harnessResolveCancellationPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-resolve-cancellation-prompt-ready.json"
$harnessCleanupPromptReadyPath = Join-Path $fixtureRootResolved "installed-source-control-ui-e2e-cleanup-prompt-ready.json"
$captureRoot = Join-Path $fixtureRootResolved "renderer-capture"
$expectationsPath = Join-Path $fixtureRootResolved "renderer-capture-expectations.json"
$noRepositoryWelcomeRendererCaptureRoot = Join-Path $fixtureRootResolved "no-repository-welcome-renderer-capture"
$noRepositoryWelcomeRendererExpectationsPath = Join-Path $fixtureRootResolved "no-repository-welcome-renderer-capture-expectations.json"
$partialFreshnessRendererCaptureRoot = Join-Path $fixtureRootResolved "partial-freshness-renderer-capture"
$partialFreshnessRendererExpectationsPath = Join-Path $fixtureRootResolved "partial-freshness-renderer-capture-expectations.json"
$staleFreshnessRendererCaptureRoot = Join-Path $fixtureRootResolved "stale-freshness-renderer-capture"
$staleFreshnessRendererExpectationsPath = Join-Path $fixtureRootResolved "stale-freshness-renderer-capture-expectations.json"
$fullReconcileCancellationCaptureRoot = Join-Path $fixtureRootResolved "full-reconcile-cancellation-progress-capture"
$fullReconcileCancellationExpectationsPath = Join-Path $fixtureRootResolved "full-reconcile-cancellation-progress-capture-expectations.json"
$multiRepositoryRefreshPromptCaptureRoot = Join-Path $fixtureRootResolved "multi-repository-refresh-prompt-capture"
$multiRepositoryRefreshPromptExpectationsPath = Join-Path $fixtureRootResolved "multi-repository-refresh-prompt-capture-expectations.json"
$deletePromptCaptureRoot = Join-Path $fixtureRootResolved "delete-unversioned-prompt-capture"
$deletePromptExpectationsPath = Join-Path $fixtureRootResolved "delete-unversioned-prompt-capture-expectations.json"
$deleteLoadPromptCaptureRoot = Join-Path $fixtureRootResolved "delete-unversioned-load-prompt-capture"
$deleteLoadPromptExpectationsPath = Join-Path $fixtureRootResolved "delete-unversioned-load-prompt-capture-expectations.json"
$removePromptCaptureRoot = Join-Path $fixtureRootResolved "remove-prompt-capture"
$removePromptExpectationsPath = Join-Path $fixtureRootResolved "remove-prompt-capture-expectations.json"
$removeCancellationPromptCaptureRoot = Join-Path $fixtureRootResolved "remove-cancellation-prompt-capture"
$removeCancellationPromptExpectationsPath = Join-Path $fixtureRootResolved "remove-cancellation-prompt-capture-expectations.json"
$removeKeepLocalPromptCaptureRoot = Join-Path $fixtureRootResolved "remove-keep-local-prompt-capture"
$removeKeepLocalPromptExpectationsPath = Join-Path $fixtureRootResolved "remove-keep-local-prompt-capture-expectations.json"
$movePromptCaptureRoot = Join-Path $fixtureRootResolved "move-prompt-capture"
$movePromptExpectationsPath = Join-Path $fixtureRootResolved "move-prompt-capture-expectations.json"
$moveCancellationPromptCaptureRoot = Join-Path $fixtureRootResolved "move-cancellation-prompt-capture"
$moveCancellationPromptExpectationsPath = Join-Path $fixtureRootResolved "move-cancellation-prompt-capture-expectations.json"
$checkoutCancellationPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-cancellation-prompt-capture"
$checkoutCancellationPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-cancellation-prompt-capture-expectations.json"
$checkoutExistingTargetFailureUrlPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-existing-target-failure-url-prompt-capture"
$checkoutExistingTargetFailureUrlPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-existing-target-failure-url-prompt-capture-expectations.json"
$checkoutExistingTargetFailureTargetPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-existing-target-failure-target-prompt-capture"
$checkoutExistingTargetFailureTargetPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-existing-target-failure-target-prompt-capture-expectations.json"
$checkoutExistingTargetFailureRevisionPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-existing-target-failure-revision-prompt-capture"
$checkoutExistingTargetFailureRevisionPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-existing-target-failure-revision-prompt-capture-expectations.json"
$checkoutExistingTargetFailureDepthPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-existing-target-failure-depth-prompt-capture"
$checkoutExistingTargetFailureDepthPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-existing-target-failure-depth-prompt-capture-expectations.json"
$checkoutExistingTargetFailureExternalsPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-existing-target-failure-externals-prompt-capture"
$checkoutExistingTargetFailureExternalsPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-existing-target-failure-externals-prompt-capture-expectations.json"
$checkoutExistingTargetFailureNotificationCaptureRoot = Join-Path $fixtureRootResolved "checkout-existing-target-failure-notification-capture"
$checkoutExistingTargetFailureNotificationExpectationsPath = Join-Path $fixtureRootResolved "checkout-existing-target-failure-notification-capture-expectations.json"
$checkoutInvalidUrlFailureUrlPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-invalid-url-failure-url-prompt-capture"
$checkoutInvalidUrlFailureUrlPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-invalid-url-failure-url-prompt-capture-expectations.json"
$checkoutInvalidUrlFailureTargetPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-invalid-url-failure-target-prompt-capture"
$checkoutInvalidUrlFailureTargetPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-invalid-url-failure-target-prompt-capture-expectations.json"
$checkoutInvalidUrlFailureRevisionPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-invalid-url-failure-revision-prompt-capture"
$checkoutInvalidUrlFailureRevisionPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-invalid-url-failure-revision-prompt-capture-expectations.json"
$checkoutInvalidUrlFailureDepthPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-invalid-url-failure-depth-prompt-capture"
$checkoutInvalidUrlFailureDepthPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-invalid-url-failure-depth-prompt-capture-expectations.json"
$checkoutInvalidUrlFailureExternalsPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-invalid-url-failure-externals-prompt-capture"
$checkoutInvalidUrlFailureExternalsPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-invalid-url-failure-externals-prompt-capture-expectations.json"
$checkoutInvalidUrlFailureNotificationCaptureRoot = Join-Path $fixtureRootResolved "checkout-invalid-url-failure-notification-capture"
$checkoutInvalidUrlFailureNotificationExpectationsPath = Join-Path $fixtureRootResolved "checkout-invalid-url-failure-notification-capture-expectations.json"
$checkoutExistingDirectoryUrlPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-existing-directory-url-prompt-capture"
$checkoutExistingDirectoryUrlPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-existing-directory-url-prompt-capture-expectations.json"
$checkoutExistingDirectoryTargetPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-existing-directory-target-prompt-capture"
$checkoutExistingDirectoryTargetPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-existing-directory-target-prompt-capture-expectations.json"
$checkoutExistingDirectoryRevisionPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-existing-directory-revision-prompt-capture"
$checkoutExistingDirectoryRevisionPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-existing-directory-revision-prompt-capture-expectations.json"
$checkoutExistingDirectoryDepthPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-existing-directory-depth-prompt-capture"
$checkoutExistingDirectoryDepthPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-existing-directory-depth-prompt-capture-expectations.json"
$checkoutExistingDirectoryExternalsPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-existing-directory-externals-prompt-capture"
$checkoutExistingDirectoryExternalsPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-existing-directory-externals-prompt-capture-expectations.json"
$checkoutExistingDirectoryObstructionUrlPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-existing-directory-obstruction-url-prompt-capture"
$checkoutExistingDirectoryObstructionUrlPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-existing-directory-obstruction-url-prompt-capture-expectations.json"
$checkoutExistingDirectoryObstructionTargetPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-existing-directory-obstruction-target-prompt-capture"
$checkoutExistingDirectoryObstructionTargetPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-existing-directory-obstruction-target-prompt-capture-expectations.json"
$checkoutExistingDirectoryObstructionRevisionPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-existing-directory-obstruction-revision-prompt-capture"
$checkoutExistingDirectoryObstructionRevisionPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-existing-directory-obstruction-revision-prompt-capture-expectations.json"
$checkoutExistingDirectoryObstructionDepthPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-existing-directory-obstruction-depth-prompt-capture"
$checkoutExistingDirectoryObstructionDepthPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-existing-directory-obstruction-depth-prompt-capture-expectations.json"
$checkoutExistingDirectoryObstructionExternalsPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-existing-directory-obstruction-externals-prompt-capture"
$checkoutExistingDirectoryObstructionExternalsPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-existing-directory-obstruction-externals-prompt-capture-expectations.json"
$checkoutUrlPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-url-prompt-capture"
$checkoutUrlPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-url-prompt-capture-expectations.json"
$checkoutTargetPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-target-prompt-capture"
$checkoutTargetPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-target-prompt-capture-expectations.json"
$checkoutRevisionPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-revision-prompt-capture"
$checkoutRevisionPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-revision-prompt-capture-expectations.json"
$checkoutDepthPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-depth-prompt-capture"
$checkoutDepthPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-depth-prompt-capture-expectations.json"
$checkoutExternalsPromptCaptureRoot = Join-Path $fixtureRootResolved "checkout-externals-prompt-capture"
$checkoutExternalsPromptExpectationsPath = Join-Path $fixtureRootResolved "checkout-externals-prompt-capture-expectations.json"
$updateRevisionPromptCaptureRoot = Join-Path $fixtureRootResolved "update-revision-prompt-capture"
$updateRevisionPromptExpectationsPath = Join-Path $fixtureRootResolved "update-revision-prompt-capture-expectations.json"
$updateCancellationRevisionPromptCaptureRoot = Join-Path $fixtureRootResolved "update-cancellation-revision-prompt-capture"
$updateCancellationRevisionPromptExpectationsPath = Join-Path $fixtureRootResolved "update-cancellation-revision-prompt-capture-expectations.json"
$updateDepthPromptCaptureRoot = Join-Path $fixtureRootResolved "update-depth-prompt-capture"
$updateDepthPromptExpectationsPath = Join-Path $fixtureRootResolved "update-depth-prompt-capture-expectations.json"
$updateStickyDepthPromptCaptureRoot = Join-Path $fixtureRootResolved "update-sticky-depth-prompt-capture"
$updateStickyDepthPromptExpectationsPath = Join-Path $fixtureRootResolved "update-sticky-depth-prompt-capture-expectations.json"
$updateExternalsPromptCaptureRoot = Join-Path $fixtureRootResolved "update-externals-prompt-capture"
$updateExternalsPromptExpectationsPath = Join-Path $fixtureRootResolved "update-externals-prompt-capture-expectations.json"
$branchCreateSourcePromptCaptureRoot = Join-Path $fixtureRootResolved "branch-create-source-prompt-capture"
$branchCreateSourcePromptExpectationsPath = Join-Path $fixtureRootResolved "branch-create-source-prompt-capture-expectations.json"
$branchCreateDestinationPromptCaptureRoot = Join-Path $fixtureRootResolved "branch-create-destination-prompt-capture"
$branchCreateDestinationPromptExpectationsPath = Join-Path $fixtureRootResolved "branch-create-destination-prompt-capture-expectations.json"
$branchCreateRevisionPromptCaptureRoot = Join-Path $fixtureRootResolved "branch-create-revision-prompt-capture"
$branchCreateRevisionPromptExpectationsPath = Join-Path $fixtureRootResolved "branch-create-revision-prompt-capture-expectations.json"
$branchCreateMessagePromptCaptureRoot = Join-Path $fixtureRootResolved "branch-create-message-prompt-capture"
$branchCreateMessagePromptExpectationsPath = Join-Path $fixtureRootResolved "branch-create-message-prompt-capture-expectations.json"
$branchCreateParentsPromptCaptureRoot = Join-Path $fixtureRootResolved "branch-create-parents-prompt-capture"
$branchCreateParentsPromptExpectationsPath = Join-Path $fixtureRootResolved "branch-create-parents-prompt-capture-expectations.json"
$branchCreateExternalsPromptCaptureRoot = Join-Path $fixtureRootResolved "branch-create-externals-prompt-capture"
$branchCreateExternalsPromptExpectationsPath = Join-Path $fixtureRootResolved "branch-create-externals-prompt-capture-expectations.json"
$branchCreateSwitchPromptCaptureRoot = Join-Path $fixtureRootResolved "branch-create-switch-prompt-capture"
$branchCreateSwitchPromptExpectationsPath = Join-Path $fixtureRootResolved "branch-create-switch-prompt-capture-expectations.json"
$switchUrlPromptCaptureRoot = Join-Path $fixtureRootResolved "switch-url-prompt-capture"
$switchUrlPromptExpectationsPath = Join-Path $fixtureRootResolved "switch-url-prompt-capture-expectations.json"
$switchRevisionPromptCaptureRoot = Join-Path $fixtureRootResolved "switch-revision-prompt-capture"
$switchRevisionPromptExpectationsPath = Join-Path $fixtureRootResolved "switch-revision-prompt-capture-expectations.json"
$switchDepthPromptCaptureRoot = Join-Path $fixtureRootResolved "switch-depth-prompt-capture"
$switchDepthPromptExpectationsPath = Join-Path $fixtureRootResolved "switch-depth-prompt-capture-expectations.json"
$switchStickyDepthPromptCaptureRoot = Join-Path $fixtureRootResolved "switch-sticky-depth-prompt-capture"
$switchStickyDepthPromptExpectationsPath = Join-Path $fixtureRootResolved "switch-sticky-depth-prompt-capture-expectations.json"
$switchExternalsPromptCaptureRoot = Join-Path $fixtureRootResolved "switch-externals-prompt-capture"
$switchExternalsPromptExpectationsPath = Join-Path $fixtureRootResolved "switch-externals-prompt-capture-expectations.json"
$switchAncestryPromptCaptureRoot = Join-Path $fixtureRootResolved "switch-ancestry-prompt-capture"
$switchAncestryPromptExpectationsPath = Join-Path $fixtureRootResolved "switch-ancestry-prompt-capture-expectations.json"
$lockMessageCancellationPromptCaptureRoot = Join-Path $fixtureRootResolved "lock-message-cancellation-prompt-capture"
$lockMessageCancellationPromptExpectationsPath = Join-Path $fixtureRootResolved "lock-message-cancellation-prompt-capture-expectations.json"
$lockMessagePromptCaptureRoot = Join-Path $fixtureRootResolved "lock-message-prompt-capture"
$lockMessagePromptExpectationsPath = Join-Path $fixtureRootResolved "lock-message-prompt-capture-expectations.json"
$lockModePromptCaptureRoot = Join-Path $fixtureRootResolved "lock-mode-prompt-capture"
$lockModePromptExpectationsPath = Join-Path $fixtureRootResolved "lock-mode-prompt-capture-expectations.json"
$unlockModeCancellationPromptCaptureRoot = Join-Path $fixtureRootResolved "unlock-mode-cancellation-prompt-capture"
$unlockModeCancellationPromptExpectationsPath = Join-Path $fixtureRootResolved "unlock-mode-cancellation-prompt-capture-expectations.json"
$unlockModePromptCaptureRoot = Join-Path $fixtureRootResolved "unlock-mode-prompt-capture"
$unlockModePromptExpectationsPath = Join-Path $fixtureRootResolved "unlock-mode-prompt-capture-expectations.json"
$changelistSetPromptCaptureRoot = Join-Path $fixtureRootResolved "changelist-set-prompt-capture"
$changelistSetPromptExpectationsPath = Join-Path $fixtureRootResolved "changelist-set-prompt-capture-expectations.json"
$changelistRevertPromptCaptureRoot = Join-Path $fixtureRootResolved "changelist-revert-prompt-capture"
$changelistRevertPromptExpectationsPath = Join-Path $fixtureRootResolved "changelist-revert-prompt-capture-expectations.json"
$revertPromptCaptureRoot = Join-Path $fixtureRootResolved "revert-prompt-capture"
$revertPromptExpectationsPath = Join-Path $fixtureRootResolved "revert-prompt-capture-expectations.json"
$revertCancellationPromptCaptureRoot = Join-Path $fixtureRootResolved "revert-cancellation-prompt-capture"
$revertCancellationPromptExpectationsPath = Join-Path $fixtureRootResolved "revert-cancellation-prompt-capture-expectations.json"
$resolvePromptCaptureRoot = Join-Path $fixtureRootResolved "resolve-prompt-capture"
$resolvePromptExpectationsPath = Join-Path $fixtureRootResolved "resolve-prompt-capture-expectations.json"
$resolveCancellationPromptCaptureRoot = Join-Path $fixtureRootResolved "resolve-cancellation-prompt-capture"
$resolveCancellationPromptExpectationsPath = Join-Path $fixtureRootResolved "resolve-cancellation-prompt-capture-expectations.json"
$cleanupPromptCaptureRoot = Join-Path $fixtureRootResolved "cleanup-prompt-capture"
$cleanupPromptExpectationsPath = Join-Path $fixtureRootResolved "cleanup-prompt-capture-expectations.json"
New-Item -ItemType Directory -Force -Path $userDataRoot, $extensionsRoot, $captureRoot, $noRepositoryWelcomeRendererCaptureRoot, $partialFreshnessRendererCaptureRoot, $staleFreshnessRendererCaptureRoot, $fullReconcileCancellationCaptureRoot, $multiRepositoryRefreshPromptCaptureRoot, $deletePromptCaptureRoot, $deleteLoadPromptCaptureRoot, $removePromptCaptureRoot, $removeCancellationPromptCaptureRoot, $removeKeepLocalPromptCaptureRoot, $movePromptCaptureRoot, $moveCancellationPromptCaptureRoot, $checkoutCancellationPromptCaptureRoot, $checkoutExistingTargetFailureUrlPromptCaptureRoot, $checkoutExistingTargetFailureTargetPromptCaptureRoot, $checkoutExistingTargetFailureRevisionPromptCaptureRoot, $checkoutExistingTargetFailureDepthPromptCaptureRoot, $checkoutExistingTargetFailureExternalsPromptCaptureRoot, $checkoutExistingTargetFailureNotificationCaptureRoot, $checkoutInvalidUrlFailureUrlPromptCaptureRoot, $checkoutInvalidUrlFailureTargetPromptCaptureRoot, $checkoutInvalidUrlFailureRevisionPromptCaptureRoot, $checkoutInvalidUrlFailureDepthPromptCaptureRoot, $checkoutInvalidUrlFailureExternalsPromptCaptureRoot, $checkoutInvalidUrlFailureNotificationCaptureRoot, $checkoutExistingDirectoryUrlPromptCaptureRoot, $checkoutExistingDirectoryTargetPromptCaptureRoot, $checkoutExistingDirectoryRevisionPromptCaptureRoot, $checkoutExistingDirectoryDepthPromptCaptureRoot, $checkoutExistingDirectoryExternalsPromptCaptureRoot, $checkoutExistingDirectoryObstructionUrlPromptCaptureRoot, $checkoutExistingDirectoryObstructionTargetPromptCaptureRoot, $checkoutExistingDirectoryObstructionRevisionPromptCaptureRoot, $checkoutExistingDirectoryObstructionDepthPromptCaptureRoot, $checkoutExistingDirectoryObstructionExternalsPromptCaptureRoot, $checkoutUrlPromptCaptureRoot, $checkoutTargetPromptCaptureRoot, $checkoutRevisionPromptCaptureRoot, $checkoutDepthPromptCaptureRoot, $checkoutExternalsPromptCaptureRoot, $updateRevisionPromptCaptureRoot, $updateCancellationRevisionPromptCaptureRoot, $updateDepthPromptCaptureRoot, $updateStickyDepthPromptCaptureRoot, $updateExternalsPromptCaptureRoot, $branchCreateSourcePromptCaptureRoot, $branchCreateDestinationPromptCaptureRoot, $branchCreateRevisionPromptCaptureRoot, $branchCreateMessagePromptCaptureRoot, $branchCreateParentsPromptCaptureRoot, $branchCreateExternalsPromptCaptureRoot, $branchCreateSwitchPromptCaptureRoot, $switchUrlPromptCaptureRoot, $switchRevisionPromptCaptureRoot, $switchDepthPromptCaptureRoot, $switchStickyDepthPromptCaptureRoot, $switchExternalsPromptCaptureRoot, $switchAncestryPromptCaptureRoot, $lockMessageCancellationPromptCaptureRoot, $lockMessagePromptCaptureRoot, $lockModePromptCaptureRoot, $unlockModeCancellationPromptCaptureRoot, $unlockModePromptCaptureRoot, $changelistSetPromptCaptureRoot, $changelistRevertPromptCaptureRoot, $revertPromptCaptureRoot, $revertCancellationPromptCaptureRoot, $resolvePromptCaptureRoot, $resolveCancellationPromptCaptureRoot, $cleanupPromptCaptureRoot, (Join-Path $userDataRoot "User") | Out-Null
@'
{
  "workbench.startupEditor": "none",
  "workbench.colorTheme": "Default Light Modern",
  "window.zoomLevel": 0,
  "telemetry.telemetryLevel": "off",
  "extensions.autoCheckUpdates": false,
  "extensions.autoUpdate": false,
  "workbench.scm.alwaysShowRepositories": true
}
'@ | Set-Content -LiteralPath (Join-Path $userDataRoot "User\settings.json") -NoNewline -Encoding utf8

& $codeCliResolved --user-data-dir $userDataRoot --extensions-dir $extensionsRoot --install-extension $vsixResolved --force
if ($LASTEXITCODE -ne 0) {
  throw "VS Code CLI install failed with exit code $LASTEXITCODE."
}

$installedExtensions = @(& $codeCliResolved --user-data-dir $userDataRoot --extensions-dir $extensionsRoot --list-extensions --show-versions)
if ($LASTEXITCODE -ne 0) {
  throw "VS Code CLI extension list failed with exit code $LASTEXITCODE."
}
$expectedInstalledLine = "hitsuki-ban.subversionr@$extensionVersion"
if ($installedExtensions -notcontains $expectedInstalledLine) {
  throw "VS Code CLI installed extension list did not contain $expectedInstalledLine. Found: $($installedExtensions -join ', ')"
}
$installedPackageRoot = Find-InstalledPackage -ExtensionsRoot $extensionsRoot -Publisher "hitsuki-ban" -Name "subversionr" -Version $extensionVersion

$harness = Write-HarnessPackage `
  -HarnessRoot $harnessRoot `
  -ResultPath $harnessResultPath `
  -ReadyPath $harnessReadyPath `
  -DonePath $harnessDonePath `
  -NoRepositoryWelcomeRendererReadyPath $harnessNoRepositoryWelcomeRendererReadyPath `
  -NoRepositoryWelcomeRendererDonePath $harnessNoRepositoryWelcomeRendererDonePath `
  -PartialFreshnessRendererReadyPath $harnessPartialFreshnessRendererReadyPath `
  -PartialFreshnessRendererDonePath $harnessPartialFreshnessRendererDonePath `
  -StaleFreshnessRendererReadyPath $harnessStaleFreshnessRendererReadyPath `
  -StaleFreshnessRendererDonePath $harnessStaleFreshnessRendererDonePath `
  -FullReconcileCancellationReadyPath $harnessFullReconcileCancellationReadyPath `
  -FullReconcileCancellationDonePath $harnessFullReconcileCancellationDonePath `
  -MultiRepositoryRefreshPromptReadyPath $harnessMultiRepositoryRefreshPromptReadyPath `
  -DeletePromptReadyPath $harnessDeletePromptReadyPath `
  -DeleteLoadPromptReadyPath $harnessDeleteLoadPromptReadyPath `
  -RemovePromptReadyPath $harnessRemovePromptReadyPath `
  -RemoveCancellationPromptReadyPath $harnessRemoveCancellationPromptReadyPath `
  -RemoveCancellationPromptDonePath $harnessRemoveCancellationPromptDonePath `
  -RemoveKeepLocalPromptReadyPath $harnessRemoveKeepLocalPromptReadyPath `
  -MovePromptReadyPath $harnessMovePromptReadyPath `
  -MoveCancellationPromptReadyPath $harnessMoveCancellationPromptReadyPath `
  -CheckoutCancellationPromptReadyPath $harnessCheckoutCancellationPromptReadyPath `
  -CheckoutCancellationPromptDonePath $harnessCheckoutCancellationPromptDonePath `
  -CheckoutExistingTargetFailureUrlPromptReadyPath $harnessCheckoutExistingTargetFailureUrlPromptReadyPath `
  -CheckoutExistingTargetFailureUrlPromptDonePath $harnessCheckoutExistingTargetFailureUrlPromptDonePath `
  -CheckoutExistingTargetFailureTargetPromptReadyPath $harnessCheckoutExistingTargetFailureTargetPromptReadyPath `
  -CheckoutExistingTargetFailureTargetPromptDonePath $harnessCheckoutExistingTargetFailureTargetPromptDonePath `
  -CheckoutExistingTargetFailureRevisionPromptReadyPath $harnessCheckoutExistingTargetFailureRevisionPromptReadyPath `
  -CheckoutExistingTargetFailureRevisionPromptDonePath $harnessCheckoutExistingTargetFailureRevisionPromptDonePath `
  -CheckoutExistingTargetFailureDepthPromptReadyPath $harnessCheckoutExistingTargetFailureDepthPromptReadyPath `
  -CheckoutExistingTargetFailureDepthPromptDonePath $harnessCheckoutExistingTargetFailureDepthPromptDonePath `
  -CheckoutExistingTargetFailureExternalsPromptReadyPath $harnessCheckoutExistingTargetFailureExternalsPromptReadyPath `
  -CheckoutExistingTargetFailureExternalsPromptDonePath $harnessCheckoutExistingTargetFailureExternalsPromptDonePath `
  -CheckoutExistingTargetFailureNotificationReadyPath $harnessCheckoutExistingTargetFailureNotificationReadyPath `
  -CheckoutExistingTargetFailureNotificationDonePath $harnessCheckoutExistingTargetFailureNotificationDonePath `
  -CheckoutInvalidUrlFailureUrlPromptReadyPath $harnessCheckoutInvalidUrlFailureUrlPromptReadyPath `
  -CheckoutInvalidUrlFailureUrlPromptDonePath $harnessCheckoutInvalidUrlFailureUrlPromptDonePath `
  -CheckoutInvalidUrlFailureTargetPromptReadyPath $harnessCheckoutInvalidUrlFailureTargetPromptReadyPath `
  -CheckoutInvalidUrlFailureTargetPromptDonePath $harnessCheckoutInvalidUrlFailureTargetPromptDonePath `
  -CheckoutInvalidUrlFailureRevisionPromptReadyPath $harnessCheckoutInvalidUrlFailureRevisionPromptReadyPath `
  -CheckoutInvalidUrlFailureRevisionPromptDonePath $harnessCheckoutInvalidUrlFailureRevisionPromptDonePath `
  -CheckoutInvalidUrlFailureDepthPromptReadyPath $harnessCheckoutInvalidUrlFailureDepthPromptReadyPath `
  -CheckoutInvalidUrlFailureDepthPromptDonePath $harnessCheckoutInvalidUrlFailureDepthPromptDonePath `
  -CheckoutInvalidUrlFailureExternalsPromptReadyPath $harnessCheckoutInvalidUrlFailureExternalsPromptReadyPath `
  -CheckoutInvalidUrlFailureExternalsPromptDonePath $harnessCheckoutInvalidUrlFailureExternalsPromptDonePath `
  -CheckoutInvalidUrlFailureNotificationReadyPath $harnessCheckoutInvalidUrlFailureNotificationReadyPath `
  -CheckoutInvalidUrlFailureNotificationDonePath $harnessCheckoutInvalidUrlFailureNotificationDonePath `
  -CheckoutExistingDirectoryUrlPromptReadyPath $harnessCheckoutExistingDirectoryUrlPromptReadyPath `
  -CheckoutExistingDirectoryUrlPromptDonePath $harnessCheckoutExistingDirectoryUrlPromptDonePath `
  -CheckoutExistingDirectoryTargetPromptReadyPath $harnessCheckoutExistingDirectoryTargetPromptReadyPath `
  -CheckoutExistingDirectoryTargetPromptDonePath $harnessCheckoutExistingDirectoryTargetPromptDonePath `
  -CheckoutExistingDirectoryRevisionPromptReadyPath $harnessCheckoutExistingDirectoryRevisionPromptReadyPath `
  -CheckoutExistingDirectoryRevisionPromptDonePath $harnessCheckoutExistingDirectoryRevisionPromptDonePath `
  -CheckoutExistingDirectoryDepthPromptReadyPath $harnessCheckoutExistingDirectoryDepthPromptReadyPath `
  -CheckoutExistingDirectoryDepthPromptDonePath $harnessCheckoutExistingDirectoryDepthPromptDonePath `
  -CheckoutExistingDirectoryExternalsPromptReadyPath $harnessCheckoutExistingDirectoryExternalsPromptReadyPath `
  -CheckoutExistingDirectoryExternalsPromptDonePath $harnessCheckoutExistingDirectoryExternalsPromptDonePath `
  -CheckoutExistingDirectoryObstructionUrlPromptReadyPath $harnessCheckoutExistingDirectoryObstructionUrlPromptReadyPath `
  -CheckoutExistingDirectoryObstructionUrlPromptDonePath $harnessCheckoutExistingDirectoryObstructionUrlPromptDonePath `
  -CheckoutExistingDirectoryObstructionTargetPromptReadyPath $harnessCheckoutExistingDirectoryObstructionTargetPromptReadyPath `
  -CheckoutExistingDirectoryObstructionTargetPromptDonePath $harnessCheckoutExistingDirectoryObstructionTargetPromptDonePath `
  -CheckoutExistingDirectoryObstructionRevisionPromptReadyPath $harnessCheckoutExistingDirectoryObstructionRevisionPromptReadyPath `
  -CheckoutExistingDirectoryObstructionRevisionPromptDonePath $harnessCheckoutExistingDirectoryObstructionRevisionPromptDonePath `
  -CheckoutExistingDirectoryObstructionDepthPromptReadyPath $harnessCheckoutExistingDirectoryObstructionDepthPromptReadyPath `
  -CheckoutExistingDirectoryObstructionDepthPromptDonePath $harnessCheckoutExistingDirectoryObstructionDepthPromptDonePath `
  -CheckoutExistingDirectoryObstructionExternalsPromptReadyPath $harnessCheckoutExistingDirectoryObstructionExternalsPromptReadyPath `
  -CheckoutExistingDirectoryObstructionExternalsPromptDonePath $harnessCheckoutExistingDirectoryObstructionExternalsPromptDonePath `
  -CheckoutUrlPromptReadyPath $harnessCheckoutUrlPromptReadyPath `
  -CheckoutUrlPromptDonePath $harnessCheckoutUrlPromptDonePath `
  -CheckoutTargetPromptReadyPath $harnessCheckoutTargetPromptReadyPath `
  -CheckoutTargetPromptDonePath $harnessCheckoutTargetPromptDonePath `
  -CheckoutRevisionPromptReadyPath $harnessCheckoutRevisionPromptReadyPath `
  -CheckoutRevisionPromptDonePath $harnessCheckoutRevisionPromptDonePath `
  -CheckoutDepthPromptReadyPath $harnessCheckoutDepthPromptReadyPath `
  -CheckoutDepthPromptDonePath $harnessCheckoutDepthPromptDonePath `
  -CheckoutExternalsPromptReadyPath $harnessCheckoutExternalsPromptReadyPath `
  -CheckoutExternalsPromptDonePath $harnessCheckoutExternalsPromptDonePath `
  -UpdateRevisionPromptReadyPath $harnessUpdateRevisionPromptReadyPath `
  -UpdateRevisionPromptDonePath $harnessUpdateRevisionPromptDonePath `
  -UpdateCancellationRevisionPromptReadyPath $harnessUpdateCancellationRevisionPromptReadyPath `
  -UpdateCancellationRevisionPromptDonePath $harnessUpdateCancellationRevisionPromptDonePath `
  -UpdateDepthPromptReadyPath $harnessUpdateDepthPromptReadyPath `
  -UpdateDepthPromptDonePath $harnessUpdateDepthPromptDonePath `
  -UpdateStickyDepthPromptReadyPath $harnessUpdateStickyDepthPromptReadyPath `
  -UpdateStickyDepthPromptDonePath $harnessUpdateStickyDepthPromptDonePath `
  -UpdateExternalsPromptReadyPath $harnessUpdateExternalsPromptReadyPath `
  -UpdateExternalsPromptDonePath $harnessUpdateExternalsPromptDonePath `
  -BranchCreateSourcePromptReadyPath $harnessBranchCreateSourcePromptReadyPath `
  -BranchCreateSourcePromptDonePath $harnessBranchCreateSourcePromptDonePath `
  -BranchCreateDestinationPromptReadyPath $harnessBranchCreateDestinationPromptReadyPath `
  -BranchCreateDestinationPromptDonePath $harnessBranchCreateDestinationPromptDonePath `
  -BranchCreateRevisionPromptReadyPath $harnessBranchCreateRevisionPromptReadyPath `
  -BranchCreateRevisionPromptDonePath $harnessBranchCreateRevisionPromptDonePath `
  -BranchCreateMessagePromptReadyPath $harnessBranchCreateMessagePromptReadyPath `
  -BranchCreateMessagePromptDonePath $harnessBranchCreateMessagePromptDonePath `
  -BranchCreateParentsPromptReadyPath $harnessBranchCreateParentsPromptReadyPath `
  -BranchCreateParentsPromptDonePath $harnessBranchCreateParentsPromptDonePath `
  -BranchCreateExternalsPromptReadyPath $harnessBranchCreateExternalsPromptReadyPath `
  -BranchCreateExternalsPromptDonePath $harnessBranchCreateExternalsPromptDonePath `
  -BranchCreateSwitchPromptReadyPath $harnessBranchCreateSwitchPromptReadyPath `
  -BranchCreateSwitchPromptDonePath $harnessBranchCreateSwitchPromptDonePath `
  -SwitchUrlPromptReadyPath $harnessSwitchUrlPromptReadyPath `
  -SwitchUrlPromptDonePath $harnessSwitchUrlPromptDonePath `
  -SwitchRevisionPromptReadyPath $harnessSwitchRevisionPromptReadyPath `
  -SwitchRevisionPromptDonePath $harnessSwitchRevisionPromptDonePath `
  -SwitchDepthPromptReadyPath $harnessSwitchDepthPromptReadyPath `
  -SwitchDepthPromptDonePath $harnessSwitchDepthPromptDonePath `
  -SwitchStickyDepthPromptReadyPath $harnessSwitchStickyDepthPromptReadyPath `
  -SwitchStickyDepthPromptDonePath $harnessSwitchStickyDepthPromptDonePath `
  -SwitchExternalsPromptReadyPath $harnessSwitchExternalsPromptReadyPath `
  -SwitchExternalsPromptDonePath $harnessSwitchExternalsPromptDonePath `
  -SwitchAncestryPromptReadyPath $harnessSwitchAncestryPromptReadyPath `
  -SwitchAncestryPromptDonePath $harnessSwitchAncestryPromptDonePath `
  -LockMessageCancellationPromptReadyPath $harnessLockMessageCancellationPromptReadyPath `
  -LockMessageCancellationPromptDonePath $harnessLockMessageCancellationPromptDonePath `
  -LockMessagePromptReadyPath $harnessLockMessagePromptReadyPath `
  -LockMessagePromptDonePath $harnessLockMessagePromptDonePath `
  -LockModePromptReadyPath $harnessLockModePromptReadyPath `
  -LockModePromptDonePath $harnessLockModePromptDonePath `
  -LockHeldOracleReadyPath $harnessLockHeldOracleReadyPath `
  -LockHeldOracleDonePath $harnessLockHeldOracleDonePath `
  -UnlockModeCancellationPromptReadyPath $harnessUnlockModeCancellationPromptReadyPath `
  -UnlockModeCancellationPromptDonePath $harnessUnlockModeCancellationPromptDonePath `
  -UnlockModePromptReadyPath $harnessUnlockModePromptReadyPath `
  -UnlockModePromptDonePath $harnessUnlockModePromptDonePath `
  -ChangelistSetPromptReadyPath $harnessChangelistSetPromptReadyPath `
  -ChangelistRevertPromptReadyPath $harnessChangelistRevertPromptReadyPath `
  -RevertPromptReadyPath $harnessRevertPromptReadyPath `
  -RevertCancellationPromptReadyPath $harnessRevertCancellationPromptReadyPath `
  -RevertCancellationPromptDonePath $harnessRevertCancellationPromptDonePath `
  -ResolvePromptReadyPath $harnessResolvePromptReadyPath `
  -ResolveCancellationPromptReadyPath $harnessResolveCancellationPromptReadyPath `
  -CleanupPromptReadyPath $harnessCleanupPromptReadyPath `
  -ExtensionsRoot $extensionsRoot `
  -WorkingCopyRoot $fixture.workingCopyRoot `
  -MultiRepositoryRefreshWorkingCopyRoot $multiRepositoryRefreshFixture.workingCopyRoot `
  -LazyExternalProviderWorkingCopyRoot $lazyExternalProviderFixture.workingCopyRoot `
  -BoundaryLoadWorkingCopyRoot $boundaryLoadFixture.workingCopyRoot `
  -BoundaryLoadParentModifiedItemCount $boundaryLoadParentModifiedItemCount `
  -BoundaryLoadBoundaryModifiedItemCount $boundaryLoadBoundaryModifiedItemCount `
  -RefreshLoadWorkingCopyRoot $refreshLoadFixture.workingCopyRoot `
  -RefreshLoadItemCount $refreshLoadModifiedItemCount `
  -LoadWorkingCopyRoot $loadFixture.workingCopyRoot `
  -LoadItemCount $deleteUnversionedLoadItemCount `
  -CommitAllWorkingCopyRoot $commitAllFixture.workingCopyRoot `
  -CommitSelectedWorkingCopyRoot $commitSelectedFixture.workingCopyRoot `
  -CommitSelectedMultiSelectionWorkingCopyRoot $commitSelectedMultiSelectionFixture.workingCopyRoot `
  -CheckoutRepositoryUrl $checkoutRepositoryUrl `
  -CheckoutCancellationTargetWorkingCopyRoot $checkoutCancellationTargetRoot `
  -CheckoutExistingTargetFailureTargetPath $checkoutExistingTargetFailureTargetPath `
  -CheckoutInvalidUrlFailureRepositoryUrl $checkoutInvalidUrlFailureRepositoryUrl `
  -CheckoutInvalidUrlFailureTargetWorkingCopyRoot $checkoutInvalidUrlFailureTargetRoot `
  -CheckoutExistingDirectoryTargetWorkingCopyRoot $checkoutExistingDirectoryTargetRoot `
  -CheckoutExistingDirectoryObstructionTargetWorkingCopyRoot $checkoutExistingDirectoryObstructionTargetRoot `
  -CheckoutTargetWorkingCopyRoot $checkoutTargetRoot `
  -UpdateWorkingCopyRoot $updateFixture.workingCopyRoot `
  -UpdateRevision $updateFixture.expectedRevision `
  -UpdateTargetRelativePath $updateFixture.targetRelativePath `
  -BranchCreateWorkingCopyRoot $branchCreateFixture.workingCopyRoot `
  -BranchCreateSourceUrl $branchCreateFixture.branchSourceUrl `
  -BranchCreateDestinationUrl $branchCreateFixture.branchDestinationUrl `
  -BranchCreateMessage $branchCreateFixture.branchMessage `
  -SwitchWorkingCopyRoot $switchFixture.workingCopyRoot `
  -SwitchTargetUrl $switchFixture.switchTargetUrl `
  -AddWorkingCopyRoot $addFixture.workingCopyRoot `
  -AddToIgnoreWorkingCopyRoot $addToIgnoreFixture.workingCopyRoot `
  -LockWorkingCopyRoot $lockFixture.workingCopyRoot `
  -ChangelistSetClearWorkingCopyRoot $changelistSetClearFixture.workingCopyRoot `
  -CommitChangelistWorkingCopyRoot $commitChangelistFixture.workingCopyRoot `
  -RevertChangelistWorkingCopyRoot $revertChangelistFixture.workingCopyRoot `
  -MoveResourceWorkingCopyRoot $moveResourceFixture.workingCopyRoot `
  -MoveCancellationWorkingCopyRoot $moveCancellationFixture.workingCopyRoot `
  -RemoveWorkingCopyRoot $removeFixture.workingCopyRoot `
  -RemoveCancellationWorkingCopyRoot $removeCancellationFixture.workingCopyRoot `
  -RevertWorkingCopyRoot $revertFixture.workingCopyRoot `
  -RevertCancellationWorkingCopyRoot $revertCancellationFixture.workingCopyRoot `
  -ResolveWorkingCopyRoot $resolveFixture.workingCopyRoot `
  -ResolveCancellationWorkingCopyRoot $resolveCancellationFixture.workingCopyRoot `
  -DeleteWorkingCopyRoot $deleteFixture.workingCopyRoot `
  -MoveWorkingCopyRoot $moveFixture.workingCopyRoot `
  -MoveDestinationRoot $moveDestinationRoot
$originalAppData = [Environment]::GetEnvironmentVariable("APPDATA", "Process")
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESULT = $harness.ResultPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_READY = $harness.ReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_DONE = $harness.DonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_NO_REPOSITORY_WELCOME_RENDERER_READY = $harness.NoRepositoryWelcomeRendererReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_NO_REPOSITORY_WELCOME_RENDERER_DONE = $harness.NoRepositoryWelcomeRendererDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_PARTIAL_FRESHNESS_RENDERER_READY = $harness.PartialFreshnessRendererReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_PARTIAL_FRESHNESS_RENDERER_DONE = $harness.PartialFreshnessRendererDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_STALE_FRESHNESS_RENDERER_READY = $harness.StaleFreshnessRendererReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_STALE_FRESHNESS_RENDERER_DONE = $harness.StaleFreshnessRendererDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_FULL_RECONCILE_CANCELLATION_READY = $harness.FullReconcileCancellationReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_FULL_RECONCILE_CANCELLATION_DONE = $harness.FullReconcileCancellationDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MULTI_REPOSITORY_REFRESH_PROMPT_READY = $harness.MultiRepositoryRefreshPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_DELETE_PROMPT_READY = $harness.DeletePromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_DELETE_LOAD_PROMPT_READY = $harness.DeleteLoadPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REMOVE_PROMPT_READY = $harness.RemovePromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REMOVE_CANCELLATION_PROMPT_READY = $harness.RemoveCancellationPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REMOVE_CANCELLATION_PROMPT_DONE = $harness.RemoveCancellationPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REMOVE_KEEP_LOCAL_PROMPT_READY = $harness.RemoveKeepLocalPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MOVE_PROMPT_READY = $harness.MovePromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MOVE_CANCELLATION_PROMPT_READY = $harness.MoveCancellationPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_CANCELLATION_PROMPT_READY = $harness.CheckoutCancellationPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_CANCELLATION_PROMPT_DONE = $harness.CheckoutCancellationPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_URL_PROMPT_READY = $harness.CheckoutExistingTargetFailureUrlPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_URL_PROMPT_DONE = $harness.CheckoutExistingTargetFailureUrlPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_TARGET_PROMPT_READY = $harness.CheckoutExistingTargetFailureTargetPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_TARGET_PROMPT_DONE = $harness.CheckoutExistingTargetFailureTargetPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_REVISION_PROMPT_READY = $harness.CheckoutExistingTargetFailureRevisionPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_REVISION_PROMPT_DONE = $harness.CheckoutExistingTargetFailureRevisionPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_DEPTH_PROMPT_READY = $harness.CheckoutExistingTargetFailureDepthPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_DEPTH_PROMPT_DONE = $harness.CheckoutExistingTargetFailureDepthPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_EXTERNALS_PROMPT_READY = $harness.CheckoutExistingTargetFailureExternalsPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_EXTERNALS_PROMPT_DONE = $harness.CheckoutExistingTargetFailureExternalsPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_NOTIFICATION_READY = $harness.CheckoutExistingTargetFailureNotificationReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_NOTIFICATION_DONE = $harness.CheckoutExistingTargetFailureNotificationDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_URL_PROMPT_READY = $harness.CheckoutInvalidUrlFailureUrlPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_URL_PROMPT_DONE = $harness.CheckoutInvalidUrlFailureUrlPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_TARGET_PROMPT_READY = $harness.CheckoutInvalidUrlFailureTargetPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_TARGET_PROMPT_DONE = $harness.CheckoutInvalidUrlFailureTargetPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_REVISION_PROMPT_READY = $harness.CheckoutInvalidUrlFailureRevisionPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_REVISION_PROMPT_DONE = $harness.CheckoutInvalidUrlFailureRevisionPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_DEPTH_PROMPT_READY = $harness.CheckoutInvalidUrlFailureDepthPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_DEPTH_PROMPT_DONE = $harness.CheckoutInvalidUrlFailureDepthPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_EXTERNALS_PROMPT_READY = $harness.CheckoutInvalidUrlFailureExternalsPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_EXTERNALS_PROMPT_DONE = $harness.CheckoutInvalidUrlFailureExternalsPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_NOTIFICATION_READY = $harness.CheckoutInvalidUrlFailureNotificationReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_NOTIFICATION_DONE = $harness.CheckoutInvalidUrlFailureNotificationDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_URL_PROMPT_READY = $harness.CheckoutExistingDirectoryUrlPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_URL_PROMPT_DONE = $harness.CheckoutExistingDirectoryUrlPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_TARGET_PROMPT_READY = $harness.CheckoutExistingDirectoryTargetPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_TARGET_PROMPT_DONE = $harness.CheckoutExistingDirectoryTargetPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_REVISION_PROMPT_READY = $harness.CheckoutExistingDirectoryRevisionPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_REVISION_PROMPT_DONE = $harness.CheckoutExistingDirectoryRevisionPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_DEPTH_PROMPT_READY = $harness.CheckoutExistingDirectoryDepthPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_DEPTH_PROMPT_DONE = $harness.CheckoutExistingDirectoryDepthPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_EXTERNALS_PROMPT_READY = $harness.CheckoutExistingDirectoryExternalsPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_EXTERNALS_PROMPT_DONE = $harness.CheckoutExistingDirectoryExternalsPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_URL_PROMPT_READY = $harness.CheckoutExistingDirectoryObstructionUrlPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_URL_PROMPT_DONE = $harness.CheckoutExistingDirectoryObstructionUrlPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_TARGET_PROMPT_READY = $harness.CheckoutExistingDirectoryObstructionTargetPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_TARGET_PROMPT_DONE = $harness.CheckoutExistingDirectoryObstructionTargetPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_REVISION_PROMPT_READY = $harness.CheckoutExistingDirectoryObstructionRevisionPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_REVISION_PROMPT_DONE = $harness.CheckoutExistingDirectoryObstructionRevisionPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_DEPTH_PROMPT_READY = $harness.CheckoutExistingDirectoryObstructionDepthPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_DEPTH_PROMPT_DONE = $harness.CheckoutExistingDirectoryObstructionDepthPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_EXTERNALS_PROMPT_READY = $harness.CheckoutExistingDirectoryObstructionExternalsPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_EXTERNALS_PROMPT_DONE = $harness.CheckoutExistingDirectoryObstructionExternalsPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_URL_PROMPT_READY = $harness.CheckoutUrlPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_URL_PROMPT_DONE = $harness.CheckoutUrlPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_TARGET_PROMPT_READY = $harness.CheckoutTargetPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_TARGET_PROMPT_DONE = $harness.CheckoutTargetPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_REVISION_PROMPT_READY = $harness.CheckoutRevisionPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_REVISION_PROMPT_DONE = $harness.CheckoutRevisionPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_DEPTH_PROMPT_READY = $harness.CheckoutDepthPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_DEPTH_PROMPT_DONE = $harness.CheckoutDepthPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXTERNALS_PROMPT_READY = $harness.CheckoutExternalsPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXTERNALS_PROMPT_DONE = $harness.CheckoutExternalsPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_REVISION_PROMPT_READY = $harness.UpdateRevisionPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_REVISION_PROMPT_DONE = $harness.UpdateRevisionPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_CANCELLATION_REVISION_PROMPT_READY = $harness.UpdateCancellationRevisionPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_CANCELLATION_REVISION_PROMPT_DONE = $harness.UpdateCancellationRevisionPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_DEPTH_PROMPT_READY = $harness.UpdateDepthPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_DEPTH_PROMPT_DONE = $harness.UpdateDepthPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_STICKY_DEPTH_PROMPT_READY = $harness.UpdateStickyDepthPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_STICKY_DEPTH_PROMPT_DONE = $harness.UpdateStickyDepthPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_EXTERNALS_PROMPT_READY = $harness.UpdateExternalsPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_EXTERNALS_PROMPT_DONE = $harness.UpdateExternalsPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_SOURCE_PROMPT_READY = $harness.BranchCreateSourcePromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_SOURCE_PROMPT_DONE = $harness.BranchCreateSourcePromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_DESTINATION_PROMPT_READY = $harness.BranchCreateDestinationPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_DESTINATION_PROMPT_DONE = $harness.BranchCreateDestinationPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_REVISION_PROMPT_READY = $harness.BranchCreateRevisionPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_REVISION_PROMPT_DONE = $harness.BranchCreateRevisionPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_MESSAGE_PROMPT_READY = $harness.BranchCreateMessagePromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_MESSAGE_PROMPT_DONE = $harness.BranchCreateMessagePromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_PARENTS_PROMPT_READY = $harness.BranchCreateParentsPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_PARENTS_PROMPT_DONE = $harness.BranchCreateParentsPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_EXTERNALS_PROMPT_READY = $harness.BranchCreateExternalsPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_EXTERNALS_PROMPT_DONE = $harness.BranchCreateExternalsPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_SWITCH_PROMPT_READY = $harness.BranchCreateSwitchPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_SWITCH_PROMPT_DONE = $harness.BranchCreateSwitchPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_URL_PROMPT_READY = $harness.SwitchUrlPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_URL_PROMPT_DONE = $harness.SwitchUrlPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_REVISION_PROMPT_READY = $harness.SwitchRevisionPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_REVISION_PROMPT_DONE = $harness.SwitchRevisionPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_DEPTH_PROMPT_READY = $harness.SwitchDepthPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_DEPTH_PROMPT_DONE = $harness.SwitchDepthPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_STICKY_DEPTH_PROMPT_READY = $harness.SwitchStickyDepthPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_STICKY_DEPTH_PROMPT_DONE = $harness.SwitchStickyDepthPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_EXTERNALS_PROMPT_READY = $harness.SwitchExternalsPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_EXTERNALS_PROMPT_DONE = $harness.SwitchExternalsPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_ANCESTRY_PROMPT_READY = $harness.SwitchAncestryPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_ANCESTRY_PROMPT_DONE = $harness.SwitchAncestryPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MESSAGE_CANCELLATION_PROMPT_READY = $harness.LockMessageCancellationPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MESSAGE_CANCELLATION_PROMPT_DONE = $harness.LockMessageCancellationPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MESSAGE_PROMPT_READY = $harness.LockMessagePromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MESSAGE_PROMPT_DONE = $harness.LockMessagePromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MODE_PROMPT_READY = $harness.LockModePromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MODE_PROMPT_DONE = $harness.LockModePromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_HELD_ORACLE_READY = $harness.LockHeldOracleReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_HELD_ORACLE_DONE = $harness.LockHeldOracleDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UNLOCK_MODE_CANCELLATION_PROMPT_READY = $harness.UnlockModeCancellationPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UNLOCK_MODE_CANCELLATION_PROMPT_DONE = $harness.UnlockModeCancellationPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UNLOCK_MODE_PROMPT_READY = $harness.UnlockModePromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UNLOCK_MODE_PROMPT_DONE = $harness.UnlockModePromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHANGELIST_SET_PROMPT_READY = $harness.ChangelistSetPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHANGELIST_REVERT_PROMPT_READY = $harness.ChangelistRevertPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_PROMPT_READY = $harness.RevertPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_CANCELLATION_PROMPT_READY = $harness.RevertCancellationPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_CANCELLATION_PROMPT_DONE = $harness.RevertCancellationPromptDonePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESOLVE_PROMPT_READY = $harness.ResolvePromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESOLVE_CANCELLATION_PROMPT_READY = $harness.ResolveCancellationPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CLEANUP_PROMPT_READY = $harness.CleanupPromptReadyPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_EXTENSIONS_ROOT = $harness.ExtensionsRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_WORKING_COPY = $harness.WorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MULTI_REPOSITORY_REFRESH_WORKING_COPY = $harness.MultiRepositoryRefreshWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LAZY_EXTERNAL_PROVIDER_WORKING_COPY = $harness.LazyExternalProviderWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BOUNDARY_LOAD_WORKING_COPY = $harness.BoundaryLoadWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BOUNDARY_LOAD_PARENT_MODIFIED_ITEM_COUNT = [string]$harness.BoundaryLoadParentModifiedItemCount
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BOUNDARY_LOAD_BOUNDARY_MODIFIED_ITEM_COUNT = [string]$harness.BoundaryLoadBoundaryModifiedItemCount
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REFRESH_LOAD_WORKING_COPY = $harness.RefreshLoadWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REFRESH_LOAD_ITEM_COUNT = [string]$harness.RefreshLoadItemCount
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOAD_WORKING_COPY = $harness.LoadWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOAD_ITEM_COUNT = [string]$harness.LoadItemCount
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_COMMIT_ALL_WORKING_COPY = $harness.CommitAllWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_COMMIT_SELECTED_WORKING_COPY = $harness.CommitSelectedWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_COMMIT_SELECTED_MULTI_SELECTION_WORKING_COPY = $harness.CommitSelectedMultiSelectionWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_URL = $harness.CheckoutRepositoryUrl
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_CANCELLATION_TARGET_WORKING_COPY = $harness.CheckoutCancellationTargetWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_TARGET_PATH = $harness.CheckoutExistingTargetFailureTargetPath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_URL = $harness.CheckoutInvalidUrlFailureRepositoryUrl
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_TARGET_WORKING_COPY = $harness.CheckoutInvalidUrlFailureTargetWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_TARGET_WORKING_COPY = $harness.CheckoutExistingDirectoryTargetWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_TARGET_WORKING_COPY = $harness.CheckoutExistingDirectoryObstructionTargetWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_TARGET_WORKING_COPY = $harness.CheckoutTargetWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_WORKING_COPY = $harness.UpdateWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_REVISION = [string]$harness.UpdateRevision
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_TARGET_RELATIVE_PATH = $harness.UpdateTargetRelativePath
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_WORKING_COPY = $harness.BranchCreateWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_SOURCE_URL = $harness.BranchCreateSourceUrl
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_DESTINATION_URL = $harness.BranchCreateDestinationUrl
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_MESSAGE = $harness.BranchCreateMessage
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_WORKING_COPY = $harness.SwitchWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_TARGET_URL = $harness.SwitchTargetUrl
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_ADD_WORKING_COPY = $harness.AddWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_ADD_TO_IGNORE_WORKING_COPY = $harness.AddToIgnoreWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_WORKING_COPY = $harness.LockWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHANGELIST_SET_CLEAR_WORKING_COPY = $harness.ChangelistSetClearWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_COMMIT_CHANGELIST_WORKING_COPY = $harness.CommitChangelistWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_CHANGELIST_WORKING_COPY = $harness.RevertChangelistWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MOVE_WORKING_COPY = $harness.MoveResourceWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MOVE_CANCELLATION_WORKING_COPY = $harness.MoveCancellationWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REMOVE_WORKING_COPY = $harness.RemoveWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REMOVE_CANCELLATION_WORKING_COPY = $harness.RemoveCancellationWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_WORKING_COPY = $harness.RevertWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_CANCELLATION_WORKING_COPY = $harness.RevertCancellationWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESOLVE_WORKING_COPY = $harness.ResolveWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESOLVE_CANCELLATION_WORKING_COPY = $harness.ResolveCancellationWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_REPOSITORY_LIFECYCLE_DELETE_WORKING_COPY = $harness.DeleteWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_REPOSITORY_LIFECYCLE_MOVE_WORKING_COPY = $harness.MoveWorkingCopyRoot
$env:SUBVERSIONR_INSTALLED_REPOSITORY_LIFECYCLE_MOVE_DESTINATION = $harness.MoveDestinationRoot
$env:APPDATA = $fixture.svnRuntimeAppDataRoot
$codeProcess = $null
$driverError = $null
$noRepositoryWelcomeRendererDriverError = $null
$partialFreshnessRendererDriverError = $null
$staleFreshnessRendererDriverError = $null
$fullReconcileCancellationDriverError = $null
$multiRepositoryRefreshPromptDriverError = $null
$deletePromptDriverError = $null
$deleteLoadPromptDriverError = $null
$removePromptDriverError = $null
$removeCancellationPromptDriverError = $null
$removeKeepLocalPromptDriverError = $null
$movePromptDriverError = $null
$moveCancellationPromptDriverError = $null
$updateRevisionPromptDriverError = $null
$updateDepthPromptDriverError = $null
$updateStickyDepthPromptDriverError = $null
$updateExternalsPromptDriverError = $null
$branchCreateSourcePromptDriverError = $null
$branchCreateDestinationPromptDriverError = $null
$branchCreateRevisionPromptDriverError = $null
$branchCreateMessagePromptDriverError = $null
$branchCreateParentsPromptDriverError = $null
$branchCreateExternalsPromptDriverError = $null
$branchCreateSwitchPromptDriverError = $null
$switchUrlPromptDriverError = $null
$switchRevisionPromptDriverError = $null
$switchDepthPromptDriverError = $null
$switchStickyDepthPromptDriverError = $null
$switchExternalsPromptDriverError = $null
$switchAncestryPromptDriverError = $null
$lockMessagePromptDriverError = $null
$lockModePromptDriverError = $null
$unlockModePromptDriverError = $null
$lockHeldWorkingCopyOracle = $null
$changelistSetPromptDriverError = $null
$changelistRevertPromptDriverError = $null
$revertPromptDriverError = $null
$revertCancellationPromptDriverError = $null
$resolvePromptDriverError = $null
$resolveCancellationPromptDriverError = $null
$cleanupPromptDriverError = $null
try {
  $codeProcess = Start-CodeCliProcess -Path $codeCliResolved -Arguments @(
    "--user-data-dir",
    $userDataRoot,
    "--extensions-dir",
    $extensionsRoot,
    "--disable-workspace-trust",
    "--disable-updates",
    "--disable-telemetry",
    "--skip-welcome",
    "--skip-release-notes",
    "--new-window",
    "--locale",
    "en",
    "--remote-debugging-port=$RemoteDebuggingPort",
    "--extensionDevelopmentPath=$($harness.Root)",
    "--extensionTestsPath=$($harness.TestsPath)",
    "--log",
    "trace",
    "--wait",
    $fixture.workingCopyRoot
  ) -Description "VS Code installed Source Control UI E2E smoke"

  Wait-File -Path $harness.ReadyPath -TimeoutSeconds $UiReadyTimeoutSeconds -Description "Installed Source Control UI E2E ready sentinel"
  $ready = Get-Content -Raw -LiteralPath $harness.ReadyPath | ConvertFrom-Json
  if ($ready.ok -ne $true -or $ready.openReport.kind -ne "subversionr.installedSourceControlUiE2eOpenReport") {
    throw "Installed Source Control UI E2E ready sentinel did not include an open report."
  }
  $ready.rendererCaptureExpectations | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $expectationsPath -Encoding utf8

  try {
    Invoke-RendererCaptureDriver `
      -DriverPath $rendererCaptureDriverResolved `
      -Port $RemoteDebuggingPort `
      -CaptureRoot $captureRoot `
      -ExpectationsPath $expectationsPath `
      -Target $Target
  }
  catch {
    $driverError = $_
  }
  finally {
    [pscustomobject]@{
      ok = $null -eq $driverError
      completedAt = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $harness.DonePath -Encoding utf8
  }
  if ($null -ne $driverError) {
    throw $driverError
  }
  $rendererCapture = Get-Content -Raw -LiteralPath (Join-Path $captureRoot "renderer-capture.json") | ConvertFrom-Json
  Assert-RendererCaptureReport -Capture $rendererCapture -CaptureRoot $captureRoot -Target $Target -OpenReport $ready.openReport

  Wait-File -Path $harness.PartialFreshnessRendererReadyPath -TimeoutSeconds $UiReadyTimeoutSeconds -Description "Installed Source Control UI E2E partial freshness renderer ready sentinel"
  $partialFreshnessRendererReady = Get-Content -Raw -LiteralPath $harness.PartialFreshnessRendererReadyPath | ConvertFrom-Json
  if ($partialFreshnessRendererReady.ok -ne $true -or $partialFreshnessRendererReady.scenario -ne "partial") {
    throw "Installed Source Control UI E2E partial freshness renderer sentinel did not include the partial scenario."
  }
  $partialFreshnessRendererReady.rendererCaptureExpectations | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $partialFreshnessRendererExpectationsPath -Encoding utf8
  try {
    Invoke-RendererCaptureDriver `
      -DriverPath $rendererCaptureDriverResolved `
      -Port $RemoteDebuggingPort `
      -CaptureRoot $partialFreshnessRendererCaptureRoot `
      -ExpectationsPath $partialFreshnessRendererExpectationsPath `
      -Target $Target
  }
  catch {
    $partialFreshnessRendererDriverError = $_
  }
  finally {
    [pscustomobject]@{
      ok = $null -eq $partialFreshnessRendererDriverError
      completedAt = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $harness.PartialFreshnessRendererDonePath -Encoding utf8
  }

  Wait-File -Path $harness.StaleFreshnessRendererReadyPath -TimeoutSeconds $UiReadyTimeoutSeconds -Description "Installed Source Control UI E2E stale freshness renderer ready sentinel"
  $staleFreshnessRendererReady = Get-Content -Raw -LiteralPath $harness.StaleFreshnessRendererReadyPath | ConvertFrom-Json
  if ($staleFreshnessRendererReady.ok -ne $true -or $staleFreshnessRendererReady.scenario -ne "stale") {
    throw "Installed Source Control UI E2E stale freshness renderer sentinel did not include the stale scenario."
  }
  $staleFreshnessRendererReady.rendererCaptureExpectations | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $staleFreshnessRendererExpectationsPath -Encoding utf8
  try {
    Invoke-RendererCaptureDriver `
      -DriverPath $rendererCaptureDriverResolved `
      -Port $RemoteDebuggingPort `
      -CaptureRoot $staleFreshnessRendererCaptureRoot `
      -ExpectationsPath $staleFreshnessRendererExpectationsPath `
      -Target $Target
  }
  catch {
    $staleFreshnessRendererDriverError = $_
  }
  finally {
    [pscustomobject]@{
      ok = $null -eq $staleFreshnessRendererDriverError
      completedAt = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $harness.StaleFreshnessRendererDonePath -Encoding utf8
  }

  Wait-File -Path $harness.FullReconcileCancellationReadyPath -TimeoutSeconds $UiReadyTimeoutSeconds -Description "Installed Source Control UI E2E full reconcile cancellation progress ready sentinel"
  $fullReconcileCancellationReady = Get-Content -Raw -LiteralPath $harness.FullReconcileCancellationReadyPath | ConvertFrom-Json
  if ($fullReconcileCancellationReady.ok -ne $true -or $fullReconcileCancellationReady.command -ne "subversionr.fullReconcile") {
    throw "Installed Source Control UI E2E full reconcile cancellation sentinel did not include the full reconcile command."
  }
  $fullReconcileCancellationReady.rendererCaptureExpectations | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fullReconcileCancellationExpectationsPath -Encoding utf8
  try {
    Invoke-RendererCaptureDriver `
      -DriverPath $rendererCaptureDriverResolved `
      -Port $RemoteDebuggingPort `
      -CaptureRoot $fullReconcileCancellationCaptureRoot `
      -ExpectationsPath $fullReconcileCancellationExpectationsPath `
      -Target $Target
  }
  catch {
    $fullReconcileCancellationDriverError = $_
  }
  finally {
    [pscustomobject]@{
      ok = $null -eq $fullReconcileCancellationDriverError
      completedAt = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $harness.FullReconcileCancellationDonePath -Encoding utf8
  }

  Wait-File -Path $harness.MultiRepositoryRefreshPromptReadyPath -TimeoutSeconds $UiReadyTimeoutSeconds -Description "Installed Source Control UI E2E multi-repository Refresh prompt ready sentinel"
  $multiRepositoryRefreshPromptReady = Get-Content -Raw -LiteralPath $harness.MultiRepositoryRefreshPromptReadyPath | ConvertFrom-Json
  if ($multiRepositoryRefreshPromptReady.ok -ne $true -or $multiRepositoryRefreshPromptReady.command -ne "subversionr.refreshRepository") {
    throw "Installed Source Control UI E2E multi-repository Refresh prompt sentinel did not include the refresh command."
  }
  $multiRepositoryRefreshPromptReady.rendererCaptureExpectations | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $multiRepositoryRefreshPromptExpectationsPath -Encoding utf8
  try {
    Invoke-RendererCaptureDriver `
      -DriverPath $rendererCaptureDriverResolved `
      -Port $RemoteDebuggingPort `
      -CaptureRoot $multiRepositoryRefreshPromptCaptureRoot `
      -ExpectationsPath $multiRepositoryRefreshPromptExpectationsPath `
      -Target $Target
  }
  catch {
    $multiRepositoryRefreshPromptDriverError = $_
  }

  Wait-File -Path $harness.DeletePromptReadyPath -TimeoutSeconds $UiReadyTimeoutSeconds -Description "Installed Source Control UI E2E Delete Unversioned prompt ready sentinel"
  $deletePromptReady = Get-Content -Raw -LiteralPath $harness.DeletePromptReadyPath | ConvertFrom-Json
  if ($deletePromptReady.ok -ne $true -or $deletePromptReady.command -ne "subversionr.deleteUnversionedResource") {
    throw "Installed Source Control UI E2E Delete Unversioned prompt sentinel did not include the delete command."
  }
  $deletePromptReady.rendererCaptureExpectations | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $deletePromptExpectationsPath -Encoding utf8
  try {
    Invoke-RendererCaptureDriver `
      -DriverPath $rendererCaptureDriverResolved `
      -Port $RemoteDebuggingPort `
      -CaptureRoot $deletePromptCaptureRoot `
      -ExpectationsPath $deletePromptExpectationsPath `
      -Target $Target
  }
  catch {
    $deletePromptDriverError = $_
  }

  Wait-File -Path $harness.DeleteLoadPromptReadyPath -TimeoutSeconds $UiReadyTimeoutSeconds -Description "Installed Source Control UI E2E Delete Unversioned load prompt ready sentinel"
  $deleteLoadPromptReady = Get-Content -Raw -LiteralPath $harness.DeleteLoadPromptReadyPath | ConvertFrom-Json
  if ($deleteLoadPromptReady.ok -ne $true -or $deleteLoadPromptReady.command -ne "subversionr.deleteAllUnversionedResources") {
    throw "Installed Source Control UI E2E Delete Unversioned load prompt sentinel did not include the delete-all command."
  }
  $deleteLoadPromptReady.rendererCaptureExpectations | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $deleteLoadPromptExpectationsPath -Encoding utf8
  try {
    Invoke-RendererCaptureDriver `
      -DriverPath $rendererCaptureDriverResolved `
      -Port $RemoteDebuggingPort `
      -CaptureRoot $deleteLoadPromptCaptureRoot `
      -ExpectationsPath $deleteLoadPromptExpectationsPath `
      -Target $Target
  }
  catch {
    $deleteLoadPromptDriverError = $_
  }

  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.LockMessageCancellationPromptReadyPath `
    -DonePath $harness.LockMessageCancellationPromptDonePath `
    -ExpectationsPath $lockMessageCancellationPromptExpectationsPath `
    -CaptureRoot $lockMessageCancellationPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Lock message cancellation prompt ready sentinel" `
    -ExpectedCommand "subversionr.lockResource" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.LockMessagePromptReadyPath `
    -DonePath $harness.LockMessagePromptDonePath `
    -ExpectationsPath $lockMessagePromptExpectationsPath `
    -CaptureRoot $lockMessagePromptCaptureRoot `
    -Description "Installed Source Control UI E2E Lock message prompt ready sentinel" `
    -ExpectedCommand "subversionr.lockResource" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.LockModePromptReadyPath `
    -DonePath $harness.LockModePromptDonePath `
    -ExpectationsPath $lockModePromptExpectationsPath `
    -CaptureRoot $lockModePromptCaptureRoot `
    -Description "Installed Source Control UI E2E Lock mode prompt ready sentinel" `
    -ExpectedCommand "subversionr.lockResource" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target

  Wait-File -Path $harness.LockHeldOracleReadyPath -TimeoutSeconds $UiReadyTimeoutSeconds -Description "Installed Source Control UI E2E lock-held oracle ready sentinel"
  $lockHeldOracleReady = Get-Content -Raw -LiteralPath $harness.LockHeldOracleReadyPath | ConvertFrom-Json
  if ($lockHeldOracleReady.ok -ne $true -or $lockHeldOracleReady.command -ne "subversionr.lockResource") {
    throw "Installed Source Control UI E2E lock-held oracle sentinel did not include the lock command."
  }
  $lockHeldWorkingCopyOracle = Get-LockHeldWorkingCopyOracle -SvnExe $svnExeResolved -Fixture $lockFixture
  [pscustomobject]@{
    ok = $true
    completedAt = (Get-Date).ToUniversalTime().ToString("o")
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $harness.LockHeldOracleDonePath -Encoding utf8

  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.UnlockModeCancellationPromptReadyPath `
    -DonePath $harness.UnlockModeCancellationPromptDonePath `
    -ExpectationsPath $unlockModeCancellationPromptExpectationsPath `
    -CaptureRoot $unlockModeCancellationPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Unlock mode cancellation prompt ready sentinel" `
    -ExpectedCommand "subversionr.unlockResource" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.UnlockModePromptReadyPath `
    -DonePath $harness.UnlockModePromptDonePath `
    -ExpectationsPath $unlockModePromptExpectationsPath `
    -CaptureRoot $unlockModePromptCaptureRoot `
    -Description "Installed Source Control UI E2E Unlock mode prompt ready sentinel" `
    -ExpectedCommand "subversionr.unlockResource" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target

  Wait-File -Path $harness.ChangelistSetPromptReadyPath -TimeoutSeconds $UiReadyTimeoutSeconds -Description "Installed Source Control UI E2E Set Changelist prompt ready sentinel"
  $changelistSetPromptReady = Get-Content -Raw -LiteralPath $harness.ChangelistSetPromptReadyPath | ConvertFrom-Json
  if ($changelistSetPromptReady.ok -ne $true -or $changelistSetPromptReady.command -ne "subversionr.setResourceChangelist") {
    throw "Installed Source Control UI E2E Set Changelist prompt sentinel did not include the set changelist command."
  }
  $changelistSetPromptReady.rendererCaptureExpectations | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $changelistSetPromptExpectationsPath -Encoding utf8
  try {
    Invoke-RendererCaptureDriver `
      -DriverPath $rendererCaptureDriverResolved `
      -Port $RemoteDebuggingPort `
      -CaptureRoot $changelistSetPromptCaptureRoot `
      -ExpectationsPath $changelistSetPromptExpectationsPath `
      -Target $Target
  }
  catch {
    $changelistSetPromptDriverError = $_
  }

  Wait-File -Path $harness.ChangelistRevertPromptReadyPath -TimeoutSeconds $UiReadyTimeoutSeconds -Description "Installed Source Control UI E2E Revert Changelist prompt ready sentinel"
  $changelistRevertPromptReady = Get-Content -Raw -LiteralPath $harness.ChangelistRevertPromptReadyPath | ConvertFrom-Json
  if ($changelistRevertPromptReady.ok -ne $true -or $changelistRevertPromptReady.command -ne "subversionr.revertChangelist") {
    throw "Installed Source Control UI E2E Revert Changelist prompt sentinel did not include the revert changelist command."
  }
  $changelistRevertPromptReady.rendererCaptureExpectations | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $changelistRevertPromptExpectationsPath -Encoding utf8
  try {
    Invoke-RendererCaptureDriver `
      -DriverPath $rendererCaptureDriverResolved `
      -Port $RemoteDebuggingPort `
      -CaptureRoot $changelistRevertPromptCaptureRoot `
      -ExpectationsPath $changelistRevertPromptExpectationsPath `
      -Target $Target
  }
  catch {
    $changelistRevertPromptDriverError = $_
  }

  Wait-File -Path $harness.MovePromptReadyPath -TimeoutSeconds $UiReadyTimeoutSeconds -Description "Installed Source Control UI E2E Move prompt ready sentinel"
  $movePromptReady = Get-Content -Raw -LiteralPath $harness.MovePromptReadyPath | ConvertFrom-Json
  if ($movePromptReady.ok -ne $true -or $movePromptReady.command -ne "subversionr.moveResource") {
    throw "Installed Source Control UI E2E Move prompt sentinel did not include the move command."
  }
  $movePromptReady.rendererCaptureExpectations | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $movePromptExpectationsPath -Encoding utf8
  try {
    Invoke-RendererCaptureDriver `
      -DriverPath $rendererCaptureDriverResolved `
      -Port $RemoteDebuggingPort `
      -CaptureRoot $movePromptCaptureRoot `
      -ExpectationsPath $movePromptExpectationsPath `
      -Target $Target
  }
  catch {
    $movePromptDriverError = $_
  }

  Wait-File -Path $harness.MoveCancellationPromptReadyPath -TimeoutSeconds $UiReadyTimeoutSeconds -Description "Installed Source Control UI E2E Move cancellation prompt ready sentinel"
  $moveCancellationPromptReady = Get-Content -Raw -LiteralPath $harness.MoveCancellationPromptReadyPath | ConvertFrom-Json
  if ($moveCancellationPromptReady.ok -ne $true -or $moveCancellationPromptReady.command -ne "subversionr.moveResource") {
    throw "Installed Source Control UI E2E Move cancellation prompt sentinel did not include the move command."
  }
  $moveCancellationPromptReady.rendererCaptureExpectations | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $moveCancellationPromptExpectationsPath -Encoding utf8
  try {
    Invoke-RendererCaptureDriver `
      -DriverPath $rendererCaptureDriverResolved `
      -Port $RemoteDebuggingPort `
      -CaptureRoot $moveCancellationPromptCaptureRoot `
      -ExpectationsPath $moveCancellationPromptExpectationsPath `
      -Target $Target
  }
  catch {
    $moveCancellationPromptDriverError = $_
  }

  Wait-File -Path $harness.RemovePromptReadyPath -TimeoutSeconds $UiReadyTimeoutSeconds -Description "Installed Source Control UI E2E Remove prompt ready sentinel"
  $removePromptReady = Get-Content -Raw -LiteralPath $harness.RemovePromptReadyPath | ConvertFrom-Json
  if ($removePromptReady.ok -ne $true -or $removePromptReady.command -ne "subversionr.removeResource") {
    throw "Installed Source Control UI E2E Remove prompt sentinel did not include the remove command."
  }
  $removePromptReady.rendererCaptureExpectations | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $removePromptExpectationsPath -Encoding utf8
  try {
    Invoke-RendererCaptureDriver `
      -DriverPath $rendererCaptureDriverResolved `
      -Port $RemoteDebuggingPort `
      -CaptureRoot $removePromptCaptureRoot `
      -ExpectationsPath $removePromptExpectationsPath `
      -Target $Target
  }
  catch {
    $removePromptDriverError = $_
  }

  Wait-File -Path $harness.RemoveCancellationPromptReadyPath -TimeoutSeconds $UiReadyTimeoutSeconds -Description "Installed Source Control UI E2E Remove cancellation prompt ready sentinel"
  $removeCancellationPromptReady = Get-Content -Raw -LiteralPath $harness.RemoveCancellationPromptReadyPath | ConvertFrom-Json
  if ($removeCancellationPromptReady.ok -ne $true -or $removeCancellationPromptReady.command -ne "subversionr.removeResource") {
    throw "Installed Source Control UI E2E Remove cancellation prompt sentinel did not include the remove command."
  }
  $removeCancellationPromptReady.rendererCaptureExpectations | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $removeCancellationPromptExpectationsPath -Encoding utf8
  try {
    Invoke-RendererCaptureDriver `
      -DriverPath $rendererCaptureDriverResolved `
      -Port $RemoteDebuggingPort `
      -CaptureRoot $removeCancellationPromptCaptureRoot `
      -ExpectationsPath $removeCancellationPromptExpectationsPath `
      -Target $Target
  }
  catch {
    $removeCancellationPromptDriverError = $_
  }
  finally {
    [pscustomobject]@{
      ok = $null -eq $removeCancellationPromptDriverError
      completedAt = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $harness.RemoveCancellationPromptDonePath -Encoding utf8
  }

  Wait-File -Path $harness.ResolvePromptReadyPath -TimeoutSeconds $UiReadyTimeoutSeconds -Description "Installed Source Control UI E2E Resolve prompt ready sentinel"
  $resolvePromptReady = Get-Content -Raw -LiteralPath $harness.ResolvePromptReadyPath | ConvertFrom-Json
  if ($resolvePromptReady.ok -ne $true -or $resolvePromptReady.command -ne "subversionr.resolveResource") {
    throw "Installed Source Control UI E2E Resolve prompt sentinel did not include the resolve command."
  }
  $resolvePromptReady.rendererCaptureExpectations | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvePromptExpectationsPath -Encoding utf8
  try {
    Invoke-RendererCaptureDriver `
      -DriverPath $rendererCaptureDriverResolved `
      -Port $RemoteDebuggingPort `
      -CaptureRoot $resolvePromptCaptureRoot `
      -ExpectationsPath $resolvePromptExpectationsPath `
      -Target $Target
  }
  catch {
    $resolvePromptDriverError = $_
  }

  Wait-File -Path $harness.ResolveCancellationPromptReadyPath -TimeoutSeconds $UiReadyTimeoutSeconds -Description "Installed Source Control UI E2E Resolve cancellation prompt ready sentinel"
  $resolveCancellationPromptReady = Get-Content -Raw -LiteralPath $harness.ResolveCancellationPromptReadyPath | ConvertFrom-Json
  if ($resolveCancellationPromptReady.ok -ne $true -or $resolveCancellationPromptReady.command -ne "subversionr.resolveResource") {
    throw "Installed Source Control UI E2E Resolve cancellation prompt sentinel did not include the resolve command."
  }
  $resolveCancellationPromptReady.rendererCaptureExpectations | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolveCancellationPromptExpectationsPath -Encoding utf8
  try {
    Invoke-RendererCaptureDriver `
      -DriverPath $rendererCaptureDriverResolved `
      -Port $RemoteDebuggingPort `
      -CaptureRoot $resolveCancellationPromptCaptureRoot `
      -ExpectationsPath $resolveCancellationPromptExpectationsPath `
      -Target $Target
  }
  catch {
    $resolveCancellationPromptDriverError = $_
  }

  Wait-File -Path $harness.RemoveKeepLocalPromptReadyPath -TimeoutSeconds $UiReadyTimeoutSeconds -Description "Installed Source Control UI E2E Keep-local Remove prompt ready sentinel"
  $removeKeepLocalPromptReady = Get-Content -Raw -LiteralPath $harness.RemoveKeepLocalPromptReadyPath | ConvertFrom-Json
  if ($removeKeepLocalPromptReady.ok -ne $true -or $removeKeepLocalPromptReady.command -ne "subversionr.removeResourceKeepLocal") {
    throw "Installed Source Control UI E2E Keep-local Remove prompt sentinel did not include the keep-local remove command."
  }
  $removeKeepLocalPromptReady.rendererCaptureExpectations | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $removeKeepLocalPromptExpectationsPath -Encoding utf8
  try {
    Invoke-RendererCaptureDriver `
      -DriverPath $rendererCaptureDriverResolved `
      -Port $RemoteDebuggingPort `
      -CaptureRoot $removeKeepLocalPromptCaptureRoot `
      -ExpectationsPath $removeKeepLocalPromptExpectationsPath `
      -Target $Target
  }
  catch {
    $removeKeepLocalPromptDriverError = $_
  }

  Wait-File -Path $harness.RevertPromptReadyPath -TimeoutSeconds $UiReadyTimeoutSeconds -Description "Installed Source Control UI E2E Revert prompt ready sentinel"
  $revertPromptReady = Get-Content -Raw -LiteralPath $harness.RevertPromptReadyPath | ConvertFrom-Json
  if ($revertPromptReady.ok -ne $true -or $revertPromptReady.command -ne "subversionr.revertResource") {
    throw "Installed Source Control UI E2E Revert prompt sentinel did not include the revert command."
  }
  $revertPromptReady.rendererCaptureExpectations | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $revertPromptExpectationsPath -Encoding utf8
  try {
    Invoke-RendererCaptureDriver `
      -DriverPath $rendererCaptureDriverResolved `
      -Port $RemoteDebuggingPort `
      -CaptureRoot $revertPromptCaptureRoot `
      -ExpectationsPath $revertPromptExpectationsPath `
      -Target $Target
  }
  catch {
    $revertPromptDriverError = $_
  }

  Wait-File -Path $harness.RevertCancellationPromptReadyPath -TimeoutSeconds $UiReadyTimeoutSeconds -Description "Installed Source Control UI E2E Revert cancellation prompt ready sentinel"
  $revertCancellationPromptReady = Get-Content -Raw -LiteralPath $harness.RevertCancellationPromptReadyPath | ConvertFrom-Json
  if ($revertCancellationPromptReady.ok -ne $true -or $revertCancellationPromptReady.command -ne "subversionr.revertResource") {
    throw "Installed Source Control UI E2E Revert cancellation prompt sentinel did not include the revert command."
  }
  $revertCancellationPromptReady.rendererCaptureExpectations | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $revertCancellationPromptExpectationsPath -Encoding utf8
  try {
    Invoke-RendererCaptureDriver `
      -DriverPath $rendererCaptureDriverResolved `
      -Port $RemoteDebuggingPort `
      -CaptureRoot $revertCancellationPromptCaptureRoot `
      -ExpectationsPath $revertCancellationPromptExpectationsPath `
      -Target $Target
  }
  catch {
    $revertCancellationPromptDriverError = $_
  }
  finally {
    [pscustomobject]@{
      ok = $null -eq $revertCancellationPromptDriverError
      completedAt = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $harness.RevertCancellationPromptDonePath -Encoding utf8
  }

  Wait-File -Path $harness.CleanupPromptReadyPath -TimeoutSeconds $UiReadyTimeoutSeconds -Description "Installed Source Control UI E2E Cleanup prompt ready sentinel"
  $cleanupPromptReady = Get-Content -Raw -LiteralPath $harness.CleanupPromptReadyPath | ConvertFrom-Json
  if ($cleanupPromptReady.ok -ne $true -or $cleanupPromptReady.command -ne "subversionr.cleanupRepository") {
    throw "Installed Source Control UI E2E Cleanup prompt sentinel did not include the cleanup command."
  }
  $cleanupPromptReady.rendererCaptureExpectations | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $cleanupPromptExpectationsPath -Encoding utf8
  try {
    Invoke-RendererCaptureDriver `
      -DriverPath $rendererCaptureDriverResolved `
      -Port $RemoteDebuggingPort `
      -CaptureRoot $cleanupPromptCaptureRoot `
      -ExpectationsPath $cleanupPromptExpectationsPath `
      -Target $Target
  }
  catch {
    $cleanupPromptDriverError = $_
  }

  Wait-File -Path $harness.NoRepositoryWelcomeRendererReadyPath -TimeoutSeconds $UiReadyTimeoutSeconds -Description "Installed Source Control UI E2E no-repository welcome renderer ready sentinel"
  $noRepositoryWelcomeRendererReady = Get-Content -Raw -LiteralPath $harness.NoRepositoryWelcomeRendererReadyPath | ConvertFrom-Json
  if ($noRepositoryWelcomeRendererReady.ok -ne $true -or $noRepositoryWelcomeRendererReady.scanCommand -ne "subversionr.openRepository") {
    throw "Installed Source Control UI E2E no-repository welcome renderer sentinel did not include the Scan command."
  }
  $noRepositoryWelcomeRendererReady.rendererCaptureExpectations | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $noRepositoryWelcomeRendererExpectationsPath -Encoding utf8
  try {
    Invoke-RendererCaptureDriver `
      -DriverPath $rendererCaptureDriverResolved `
      -Port $RemoteDebuggingPort `
      -CaptureRoot $noRepositoryWelcomeRendererCaptureRoot `
      -ExpectationsPath $noRepositoryWelcomeRendererExpectationsPath `
      -Target $Target
  }
  catch {
    $noRepositoryWelcomeRendererDriverError = $_
  }
  finally {
    [pscustomobject]@{
      ok = $null -eq $noRepositoryWelcomeRendererDriverError
      completedAt = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $harness.NoRepositoryWelcomeRendererDonePath -Encoding utf8
  }

  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutCancellationPromptReadyPath `
    -DonePath $harness.CheckoutCancellationPromptDonePath `
    -ExpectationsPath $checkoutCancellationPromptExpectationsPath `
    -CaptureRoot $checkoutCancellationPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout cancellation prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutExistingTargetFailureUrlPromptReadyPath `
    -DonePath $harness.CheckoutExistingTargetFailureUrlPromptDonePath `
    -ExpectationsPath $checkoutExistingTargetFailureUrlPromptExpectationsPath `
    -CaptureRoot $checkoutExistingTargetFailureUrlPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout existing-target failure URL prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutExistingTargetFailureTargetPromptReadyPath `
    -DonePath $harness.CheckoutExistingTargetFailureTargetPromptDonePath `
    -ExpectationsPath $checkoutExistingTargetFailureTargetPromptExpectationsPath `
    -CaptureRoot $checkoutExistingTargetFailureTargetPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout existing-target failure target prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutExistingTargetFailureRevisionPromptReadyPath `
    -DonePath $harness.CheckoutExistingTargetFailureRevisionPromptDonePath `
    -ExpectationsPath $checkoutExistingTargetFailureRevisionPromptExpectationsPath `
    -CaptureRoot $checkoutExistingTargetFailureRevisionPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout existing-target failure revision prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutExistingTargetFailureDepthPromptReadyPath `
    -DonePath $harness.CheckoutExistingTargetFailureDepthPromptDonePath `
    -ExpectationsPath $checkoutExistingTargetFailureDepthPromptExpectationsPath `
    -CaptureRoot $checkoutExistingTargetFailureDepthPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout existing-target failure depth prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutExistingTargetFailureExternalsPromptReadyPath `
    -DonePath $harness.CheckoutExistingTargetFailureExternalsPromptDonePath `
    -ExpectationsPath $checkoutExistingTargetFailureExternalsPromptExpectationsPath `
    -CaptureRoot $checkoutExistingTargetFailureExternalsPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout existing-target failure externals prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutExistingTargetFailureNotificationReadyPath `
    -DonePath $harness.CheckoutExistingTargetFailureNotificationDonePath `
    -ExpectationsPath $checkoutExistingTargetFailureNotificationExpectationsPath `
    -CaptureRoot $checkoutExistingTargetFailureNotificationCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout existing-target failure notification ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutInvalidUrlFailureUrlPromptReadyPath `
    -DonePath $harness.CheckoutInvalidUrlFailureUrlPromptDonePath `
    -ExpectationsPath $checkoutInvalidUrlFailureUrlPromptExpectationsPath `
    -CaptureRoot $checkoutInvalidUrlFailureUrlPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout invalid URL failure URL prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutInvalidUrlFailureTargetPromptReadyPath `
    -DonePath $harness.CheckoutInvalidUrlFailureTargetPromptDonePath `
    -ExpectationsPath $checkoutInvalidUrlFailureTargetPromptExpectationsPath `
    -CaptureRoot $checkoutInvalidUrlFailureTargetPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout invalid URL failure target prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutInvalidUrlFailureRevisionPromptReadyPath `
    -DonePath $harness.CheckoutInvalidUrlFailureRevisionPromptDonePath `
    -ExpectationsPath $checkoutInvalidUrlFailureRevisionPromptExpectationsPath `
    -CaptureRoot $checkoutInvalidUrlFailureRevisionPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout invalid URL failure revision prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutInvalidUrlFailureDepthPromptReadyPath `
    -DonePath $harness.CheckoutInvalidUrlFailureDepthPromptDonePath `
    -ExpectationsPath $checkoutInvalidUrlFailureDepthPromptExpectationsPath `
    -CaptureRoot $checkoutInvalidUrlFailureDepthPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout invalid URL failure depth prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutInvalidUrlFailureExternalsPromptReadyPath `
    -DonePath $harness.CheckoutInvalidUrlFailureExternalsPromptDonePath `
    -ExpectationsPath $checkoutInvalidUrlFailureExternalsPromptExpectationsPath `
    -CaptureRoot $checkoutInvalidUrlFailureExternalsPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout invalid URL failure externals prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutInvalidUrlFailureNotificationReadyPath `
    -DonePath $harness.CheckoutInvalidUrlFailureNotificationDonePath `
    -ExpectationsPath $checkoutInvalidUrlFailureNotificationExpectationsPath `
    -CaptureRoot $checkoutInvalidUrlFailureNotificationCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout invalid URL failure notification ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutExistingDirectoryUrlPromptReadyPath `
    -DonePath $harness.CheckoutExistingDirectoryUrlPromptDonePath `
    -ExpectationsPath $checkoutExistingDirectoryUrlPromptExpectationsPath `
    -CaptureRoot $checkoutExistingDirectoryUrlPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout existing-directory URL prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutExistingDirectoryTargetPromptReadyPath `
    -DonePath $harness.CheckoutExistingDirectoryTargetPromptDonePath `
    -ExpectationsPath $checkoutExistingDirectoryTargetPromptExpectationsPath `
    -CaptureRoot $checkoutExistingDirectoryTargetPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout existing-directory target prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutExistingDirectoryRevisionPromptReadyPath `
    -DonePath $harness.CheckoutExistingDirectoryRevisionPromptDonePath `
    -ExpectationsPath $checkoutExistingDirectoryRevisionPromptExpectationsPath `
    -CaptureRoot $checkoutExistingDirectoryRevisionPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout existing-directory revision prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutExistingDirectoryDepthPromptReadyPath `
    -DonePath $harness.CheckoutExistingDirectoryDepthPromptDonePath `
    -ExpectationsPath $checkoutExistingDirectoryDepthPromptExpectationsPath `
    -CaptureRoot $checkoutExistingDirectoryDepthPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout existing-directory depth prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutExistingDirectoryExternalsPromptReadyPath `
    -DonePath $harness.CheckoutExistingDirectoryExternalsPromptDonePath `
    -ExpectationsPath $checkoutExistingDirectoryExternalsPromptExpectationsPath `
    -CaptureRoot $checkoutExistingDirectoryExternalsPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout existing-directory externals prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutExistingDirectoryObstructionUrlPromptReadyPath `
    -DonePath $harness.CheckoutExistingDirectoryObstructionUrlPromptDonePath `
    -ExpectationsPath $checkoutExistingDirectoryObstructionUrlPromptExpectationsPath `
    -CaptureRoot $checkoutExistingDirectoryObstructionUrlPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout existing-directory obstruction URL prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutExistingDirectoryObstructionTargetPromptReadyPath `
    -DonePath $harness.CheckoutExistingDirectoryObstructionTargetPromptDonePath `
    -ExpectationsPath $checkoutExistingDirectoryObstructionTargetPromptExpectationsPath `
    -CaptureRoot $checkoutExistingDirectoryObstructionTargetPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout existing-directory obstruction target prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutExistingDirectoryObstructionRevisionPromptReadyPath `
    -DonePath $harness.CheckoutExistingDirectoryObstructionRevisionPromptDonePath `
    -ExpectationsPath $checkoutExistingDirectoryObstructionRevisionPromptExpectationsPath `
    -CaptureRoot $checkoutExistingDirectoryObstructionRevisionPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout existing-directory obstruction revision prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutExistingDirectoryObstructionDepthPromptReadyPath `
    -DonePath $harness.CheckoutExistingDirectoryObstructionDepthPromptDonePath `
    -ExpectationsPath $checkoutExistingDirectoryObstructionDepthPromptExpectationsPath `
    -CaptureRoot $checkoutExistingDirectoryObstructionDepthPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout existing-directory obstruction depth prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutExistingDirectoryObstructionExternalsPromptReadyPath `
    -DonePath $harness.CheckoutExistingDirectoryObstructionExternalsPromptDonePath `
    -ExpectationsPath $checkoutExistingDirectoryObstructionExternalsPromptExpectationsPath `
    -CaptureRoot $checkoutExistingDirectoryObstructionExternalsPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout existing-directory obstruction externals prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutUrlPromptReadyPath `
    -DonePath $harness.CheckoutUrlPromptDonePath `
    -ExpectationsPath $checkoutUrlPromptExpectationsPath `
    -CaptureRoot $checkoutUrlPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout URL prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutTargetPromptReadyPath `
    -DonePath $harness.CheckoutTargetPromptDonePath `
    -ExpectationsPath $checkoutTargetPromptExpectationsPath `
    -CaptureRoot $checkoutTargetPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout target prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutRevisionPromptReadyPath `
    -DonePath $harness.CheckoutRevisionPromptDonePath `
    -ExpectationsPath $checkoutRevisionPromptExpectationsPath `
    -CaptureRoot $checkoutRevisionPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout revision prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutDepthPromptReadyPath `
    -DonePath $harness.CheckoutDepthPromptDonePath `
    -ExpectationsPath $checkoutDepthPromptExpectationsPath `
    -CaptureRoot $checkoutDepthPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout depth prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.CheckoutExternalsPromptReadyPath `
    -DonePath $harness.CheckoutExternalsPromptDonePath `
    -ExpectationsPath $checkoutExternalsPromptExpectationsPath `
    -CaptureRoot $checkoutExternalsPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Checkout externals prompt ready sentinel" `
    -ExpectedCommand "subversionr.checkoutRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.UpdateCancellationRevisionPromptReadyPath `
    -DonePath $harness.UpdateCancellationRevisionPromptDonePath `
    -ExpectationsPath $updateCancellationRevisionPromptExpectationsPath `
    -CaptureRoot $updateCancellationRevisionPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Update to Revision cancellation revision prompt ready sentinel" `
    -ExpectedCommand "subversionr.updateToRevision" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.UpdateRevisionPromptReadyPath `
    -DonePath $harness.UpdateRevisionPromptDonePath `
    -ExpectationsPath $updateRevisionPromptExpectationsPath `
    -CaptureRoot $updateRevisionPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Update to Revision revision prompt ready sentinel" `
    -ExpectedCommand "subversionr.updateToRevision" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.UpdateDepthPromptReadyPath `
    -DonePath $harness.UpdateDepthPromptDonePath `
    -ExpectationsPath $updateDepthPromptExpectationsPath `
    -CaptureRoot $updateDepthPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Update to Revision depth prompt ready sentinel" `
    -ExpectedCommand "subversionr.updateToRevision" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.UpdateStickyDepthPromptReadyPath `
    -DonePath $harness.UpdateStickyDepthPromptDonePath `
    -ExpectationsPath $updateStickyDepthPromptExpectationsPath `
    -CaptureRoot $updateStickyDepthPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Update to Revision sticky depth prompt ready sentinel" `
    -ExpectedCommand "subversionr.updateToRevision" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.UpdateExternalsPromptReadyPath `
    -DonePath $harness.UpdateExternalsPromptDonePath `
    -ExpectationsPath $updateExternalsPromptExpectationsPath `
    -CaptureRoot $updateExternalsPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Update to Revision externals prompt ready sentinel" `
    -ExpectedCommand "subversionr.updateToRevision" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.BranchCreateSourcePromptReadyPath `
    -DonePath $harness.BranchCreateSourcePromptDonePath `
    -ExpectationsPath $branchCreateSourcePromptExpectationsPath `
    -CaptureRoot $branchCreateSourcePromptCaptureRoot `
    -Description "Installed Source Control UI E2E Branch/Tag source prompt ready sentinel" `
    -ExpectedCommand "subversionr.branchCreateRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.BranchCreateDestinationPromptReadyPath `
    -DonePath $harness.BranchCreateDestinationPromptDonePath `
    -ExpectationsPath $branchCreateDestinationPromptExpectationsPath `
    -CaptureRoot $branchCreateDestinationPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Branch/Tag destination prompt ready sentinel" `
    -ExpectedCommand "subversionr.branchCreateRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.BranchCreateRevisionPromptReadyPath `
    -DonePath $harness.BranchCreateRevisionPromptDonePath `
    -ExpectationsPath $branchCreateRevisionPromptExpectationsPath `
    -CaptureRoot $branchCreateRevisionPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Branch/Tag revision prompt ready sentinel" `
    -ExpectedCommand "subversionr.branchCreateRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.BranchCreateMessagePromptReadyPath `
    -DonePath $harness.BranchCreateMessagePromptDonePath `
    -ExpectationsPath $branchCreateMessagePromptExpectationsPath `
    -CaptureRoot $branchCreateMessagePromptCaptureRoot `
    -Description "Installed Source Control UI E2E Branch/Tag message prompt ready sentinel" `
    -ExpectedCommand "subversionr.branchCreateRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.BranchCreateParentsPromptReadyPath `
    -DonePath $harness.BranchCreateParentsPromptDonePath `
    -ExpectationsPath $branchCreateParentsPromptExpectationsPath `
    -CaptureRoot $branchCreateParentsPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Branch/Tag parents prompt ready sentinel" `
    -ExpectedCommand "subversionr.branchCreateRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.BranchCreateExternalsPromptReadyPath `
    -DonePath $harness.BranchCreateExternalsPromptDonePath `
    -ExpectationsPath $branchCreateExternalsPromptExpectationsPath `
    -CaptureRoot $branchCreateExternalsPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Branch/Tag externals prompt ready sentinel" `
    -ExpectedCommand "subversionr.branchCreateRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.BranchCreateSwitchPromptReadyPath `
    -DonePath $harness.BranchCreateSwitchPromptDonePath `
    -ExpectationsPath $branchCreateSwitchPromptExpectationsPath `
    -CaptureRoot $branchCreateSwitchPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Branch/Tag switch prompt ready sentinel" `
    -ExpectedCommand "subversionr.branchCreateRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.SwitchUrlPromptReadyPath `
    -DonePath $harness.SwitchUrlPromptDonePath `
    -ExpectationsPath $switchUrlPromptExpectationsPath `
    -CaptureRoot $switchUrlPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Switch URL prompt ready sentinel" `
    -ExpectedCommand "subversionr.switchRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.SwitchRevisionPromptReadyPath `
    -DonePath $harness.SwitchRevisionPromptDonePath `
    -ExpectationsPath $switchRevisionPromptExpectationsPath `
    -CaptureRoot $switchRevisionPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Switch revision prompt ready sentinel" `
    -ExpectedCommand "subversionr.switchRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.SwitchDepthPromptReadyPath `
    -DonePath $harness.SwitchDepthPromptDonePath `
    -ExpectationsPath $switchDepthPromptExpectationsPath `
    -CaptureRoot $switchDepthPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Switch depth prompt ready sentinel" `
    -ExpectedCommand "subversionr.switchRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.SwitchStickyDepthPromptReadyPath `
    -DonePath $harness.SwitchStickyDepthPromptDonePath `
    -ExpectationsPath $switchStickyDepthPromptExpectationsPath `
    -CaptureRoot $switchStickyDepthPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Switch sticky-depth prompt ready sentinel" `
    -ExpectedCommand "subversionr.switchRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.SwitchExternalsPromptReadyPath `
    -DonePath $harness.SwitchExternalsPromptDonePath `
    -ExpectationsPath $switchExternalsPromptExpectationsPath `
    -CaptureRoot $switchExternalsPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Switch externals prompt ready sentinel" `
    -ExpectedCommand "subversionr.switchRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target
  Invoke-HarnessPromptCapture `
    -ReadyPath $harness.SwitchAncestryPromptReadyPath `
    -DonePath $harness.SwitchAncestryPromptDonePath `
    -ExpectationsPath $switchAncestryPromptExpectationsPath `
    -CaptureRoot $switchAncestryPromptCaptureRoot `
    -Description "Installed Source Control UI E2E Switch ancestry prompt ready sentinel" `
    -ExpectedCommand "subversionr.switchRepository" `
    -DriverPath $rendererCaptureDriverResolved `
    -Port $RemoteDebuggingPort `
    -Target $Target

  Wait-ProcessOrKill -Process $codeProcess -TimeoutSeconds $ExtensionHostTimeoutSeconds -Description "VS Code installed Source Control UI E2E smoke"
  $codeProcess = $null
  if ($null -ne $driverError) {
    throw $driverError
  }
  if ($null -ne $noRepositoryWelcomeRendererDriverError) {
    throw $noRepositoryWelcomeRendererDriverError
  }
  if ($null -ne $partialFreshnessRendererDriverError) {
    throw $partialFreshnessRendererDriverError
  }
  if ($null -ne $staleFreshnessRendererDriverError) {
    throw $staleFreshnessRendererDriverError
  }
  if ($null -ne $fullReconcileCancellationDriverError) {
    throw $fullReconcileCancellationDriverError
  }
  if ($null -ne $multiRepositoryRefreshPromptDriverError) {
    throw $multiRepositoryRefreshPromptDriverError
  }
  if ($null -ne $deletePromptDriverError) {
    throw $deletePromptDriverError
  }
  if ($null -ne $deleteLoadPromptDriverError) {
    throw $deleteLoadPromptDriverError
  }
  if ($null -ne $removePromptDriverError) {
    throw $removePromptDriverError
  }
  if ($null -ne $removeCancellationPromptDriverError) {
    throw $removeCancellationPromptDriverError
  }
  if ($null -ne $removeKeepLocalPromptDriverError) {
    throw $removeKeepLocalPromptDriverError
  }
  if ($null -ne $movePromptDriverError) {
    throw $movePromptDriverError
  }
  if ($null -ne $moveCancellationPromptDriverError) {
    throw $moveCancellationPromptDriverError
  }
  if ($null -ne $updateRevisionPromptDriverError) {
    throw $updateRevisionPromptDriverError
  }
  if ($null -ne $updateDepthPromptDriverError) {
    throw $updateDepthPromptDriverError
  }
  if ($null -ne $updateStickyDepthPromptDriverError) {
    throw $updateStickyDepthPromptDriverError
  }
  if ($null -ne $updateExternalsPromptDriverError) {
    throw $updateExternalsPromptDriverError
  }
  if ($null -ne $changelistSetPromptDriverError) {
    throw $changelistSetPromptDriverError
  }
  if ($null -ne $changelistRevertPromptDriverError) {
    throw $changelistRevertPromptDriverError
  }
  if ($null -ne $revertPromptDriverError) {
    throw $revertPromptDriverError
  }
  if ($null -ne $revertCancellationPromptDriverError) {
    throw $revertCancellationPromptDriverError
  }
  if ($null -ne $resolvePromptDriverError) {
    throw $resolvePromptDriverError
  }
  if ($null -ne $resolveCancellationPromptDriverError) {
    throw $resolveCancellationPromptDriverError
  }
  if ($null -ne $cleanupPromptDriverError) {
    throw $cleanupPromptDriverError
  }
}
finally {
  if ($null -ne $codeProcess) {
    Stop-ProcessTreeBestEffort $codeProcess
  }
  if ($null -eq $originalAppData) {
    Remove-Item Env:APPDATA -ErrorAction SilentlyContinue
  }
  else {
    $env:APPDATA = $originalAppData
  }
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESULT -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_NO_REPOSITORY_WELCOME_RENDERER_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_NO_REPOSITORY_WELCOME_RENDERER_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_PARTIAL_FRESHNESS_RENDERER_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_PARTIAL_FRESHNESS_RENDERER_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_STALE_FRESHNESS_RENDERER_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_STALE_FRESHNESS_RENDERER_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_FULL_RECONCILE_CANCELLATION_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_FULL_RECONCILE_CANCELLATION_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MULTI_REPOSITORY_REFRESH_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_DELETE_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_DELETE_LOAD_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REMOVE_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REMOVE_CANCELLATION_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REMOVE_CANCELLATION_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REMOVE_KEEP_LOCAL_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MOVE_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MOVE_CANCELLATION_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_CANCELLATION_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_CANCELLATION_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_URL_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_URL_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_TARGET_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_TARGET_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_REVISION_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_REVISION_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_DEPTH_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_DEPTH_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_EXTERNALS_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_EXTERNALS_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_NOTIFICATION_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_NOTIFICATION_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_URL_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_URL_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_TARGET_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_TARGET_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_REVISION_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_REVISION_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_DEPTH_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_DEPTH_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_EXTERNALS_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_EXTERNALS_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_NOTIFICATION_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_NOTIFICATION_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_URL_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_URL_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_TARGET_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_TARGET_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_REVISION_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_REVISION_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_DEPTH_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_DEPTH_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_EXTERNALS_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_EXTERNALS_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_URL_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_URL_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_TARGET_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_TARGET_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_REVISION_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_REVISION_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_DEPTH_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_DEPTH_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_EXTERNALS_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_EXTERNALS_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_URL_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_URL_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_TARGET_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_TARGET_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_REVISION_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_REVISION_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_DEPTH_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_DEPTH_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXTERNALS_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXTERNALS_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_REVISION_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_REVISION_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_CANCELLATION_REVISION_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_CANCELLATION_REVISION_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_DEPTH_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_DEPTH_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_STICKY_DEPTH_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_STICKY_DEPTH_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_EXTERNALS_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_EXTERNALS_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_SOURCE_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_SOURCE_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_DESTINATION_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_DESTINATION_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_REVISION_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_REVISION_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_MESSAGE_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_MESSAGE_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_PARENTS_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_PARENTS_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_EXTERNALS_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_EXTERNALS_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_SWITCH_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_SWITCH_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_URL_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_URL_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_REVISION_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_REVISION_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_DEPTH_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_DEPTH_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_STICKY_DEPTH_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_STICKY_DEPTH_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_EXTERNALS_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_EXTERNALS_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_ANCESTRY_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_ANCESTRY_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MESSAGE_CANCELLATION_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MESSAGE_CANCELLATION_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MESSAGE_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MESSAGE_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MODE_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MODE_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_HELD_ORACLE_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_HELD_ORACLE_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UNLOCK_MODE_CANCELLATION_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UNLOCK_MODE_CANCELLATION_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UNLOCK_MODE_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UNLOCK_MODE_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHANGELIST_SET_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHANGELIST_REVERT_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_CANCELLATION_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_CANCELLATION_PROMPT_DONE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESOLVE_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESOLVE_CANCELLATION_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CLEANUP_PROMPT_READY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_EXTENSIONS_ROOT -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MULTI_REPOSITORY_REFRESH_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LAZY_EXTERNAL_PROVIDER_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BOUNDARY_LOAD_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BOUNDARY_LOAD_PARENT_MODIFIED_ITEM_COUNT -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BOUNDARY_LOAD_BOUNDARY_MODIFIED_ITEM_COUNT -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REFRESH_LOAD_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REFRESH_LOAD_ITEM_COUNT -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOAD_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOAD_ITEM_COUNT -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_COMMIT_ALL_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_COMMIT_SELECTED_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_COMMIT_SELECTED_MULTI_SELECTION_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_URL -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_CANCELLATION_TARGET_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_TARGET_FAILURE_TARGET_PATH -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_URL -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_INVALID_URL_FAILURE_TARGET_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_TARGET_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_EXISTING_DIRECTORY_OBSTRUCTION_TARGET_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHECKOUT_TARGET_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_REVISION -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UPDATE_TARGET_RELATIVE_PATH -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_SOURCE_URL -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_DESTINATION_URL -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_MESSAGE -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_TARGET_URL -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_ADD_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_ADD_TO_IGNORE_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHANGELIST_SET_CLEAR_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_COMMIT_CHANGELIST_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_CHANGELIST_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MOVE_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MOVE_CANCELLATION_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REMOVE_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REMOVE_CANCELLATION_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_CANCELLATION_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESOLVE_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESOLVE_CANCELLATION_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_REPOSITORY_LIFECYCLE_DELETE_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_REPOSITORY_LIFECYCLE_MOVE_WORKING_COPY -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_INSTALLED_REPOSITORY_LIFECYCLE_MOVE_DESTINATION -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $harnessResultPath -PathType Leaf)) {
  throw "Installed Source Control UI E2E harness did not write the expected result file."
}
if (-not (Test-Path -LiteralPath (Join-Path $captureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $noRepositoryWelcomeRendererCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "No-repository welcome renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $partialFreshnessRendererCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Partial freshness renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $staleFreshnessRendererCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Stale freshness renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $fullReconcileCancellationCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Full reconcile cancellation progress renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $multiRepositoryRefreshPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Multi-repository Refresh prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $deletePromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Delete Unversioned prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $deleteLoadPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Delete Unversioned load prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $removePromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Remove prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $removeCancellationPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Remove cancellation prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $removeKeepLocalPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Keep-local Remove prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $movePromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Move prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $moveCancellationPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Move cancellation prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutCancellationPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout cancellation prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutExistingTargetFailureUrlPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout existing-target failure URL prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutExistingTargetFailureTargetPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout existing-target failure target prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutExistingTargetFailureRevisionPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout existing-target failure revision prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutExistingTargetFailureDepthPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout existing-target failure depth prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutExistingTargetFailureExternalsPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout existing-target failure externals prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutExistingTargetFailureNotificationCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout existing-target failure notification renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutInvalidUrlFailureUrlPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout invalid URL failure URL prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutInvalidUrlFailureTargetPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout invalid URL failure target prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutInvalidUrlFailureRevisionPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout invalid URL failure revision prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutInvalidUrlFailureDepthPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout invalid URL failure depth prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutInvalidUrlFailureExternalsPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout invalid URL failure externals prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutInvalidUrlFailureNotificationCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout invalid URL failure notification renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutExistingDirectoryUrlPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout existing-directory URL prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutExistingDirectoryTargetPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout existing-directory target prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutExistingDirectoryRevisionPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout existing-directory revision prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutExistingDirectoryDepthPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout existing-directory depth prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutExistingDirectoryExternalsPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout existing-directory externals prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutExistingDirectoryObstructionUrlPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout existing-directory obstruction URL prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutExistingDirectoryObstructionTargetPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout existing-directory obstruction target prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutExistingDirectoryObstructionRevisionPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout existing-directory obstruction revision prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutExistingDirectoryObstructionDepthPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout existing-directory obstruction depth prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutExistingDirectoryObstructionExternalsPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout existing-directory obstruction externals prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutUrlPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout URL prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutTargetPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout target prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutRevisionPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout revision prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutDepthPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout depth prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $checkoutExternalsPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Checkout externals prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $updateRevisionPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Update to Revision revision prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $updateCancellationRevisionPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Update to Revision cancellation revision prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $updateDepthPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Update to Revision depth prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $updateStickyDepthPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Update to Revision sticky depth prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $updateExternalsPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Update to Revision externals prompt renderer capture driver did not write the expected capture report."
}
foreach ($capture in @(
    @{ root = $branchCreateSourcePromptCaptureRoot; description = "Branch/Tag source prompt" },
    @{ root = $branchCreateDestinationPromptCaptureRoot; description = "Branch/Tag destination prompt" },
    @{ root = $branchCreateRevisionPromptCaptureRoot; description = "Branch/Tag source revision prompt" },
    @{ root = $branchCreateMessagePromptCaptureRoot; description = "Branch/Tag log message prompt" },
    @{ root = $branchCreateParentsPromptCaptureRoot; description = "Branch/Tag parents prompt" },
    @{ root = $branchCreateExternalsPromptCaptureRoot; description = "Branch/Tag externals prompt" },
    @{ root = $branchCreateSwitchPromptCaptureRoot; description = "Branch/Tag switch prompt" },
    @{ root = $switchUrlPromptCaptureRoot; description = "Switch URL prompt" },
    @{ root = $switchRevisionPromptCaptureRoot; description = "Switch revision prompt" },
    @{ root = $switchDepthPromptCaptureRoot; description = "Switch depth prompt" },
    @{ root = $switchStickyDepthPromptCaptureRoot; description = "Switch sticky-depth prompt" },
    @{ root = $switchExternalsPromptCaptureRoot; description = "Switch externals prompt" },
    @{ root = $switchAncestryPromptCaptureRoot; description = "Switch ancestry prompt" }
  )) {
  if (-not (Test-Path -LiteralPath (Join-Path $capture.root "renderer-capture.json") -PathType Leaf)) {
    throw "$($capture.description) renderer capture driver did not write the expected capture report."
  }
}
if (-not (Test-Path -LiteralPath (Join-Path $lockMessagePromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Lock message prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $lockMessageCancellationPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Lock message cancellation prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $lockModePromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Lock mode prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $unlockModePromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Unlock mode prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $unlockModeCancellationPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Unlock mode cancellation prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $changelistSetPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Set Changelist prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $changelistRevertPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Revert Changelist prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $revertPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Revert prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $revertCancellationPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Revert cancellation prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $resolvePromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Resolve prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $resolveCancellationPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Resolve cancellation prompt renderer capture driver did not write the expected capture report."
}
if (-not (Test-Path -LiteralPath (Join-Path $cleanupPromptCaptureRoot "renderer-capture.json") -PathType Leaf)) {
  throw "Cleanup prompt renderer capture driver did not write the expected capture report."
}
$harnessResult = Get-Content -Raw -LiteralPath $harnessResultPath | ConvertFrom-Json
Assert-HarnessResult -Result $harnessResult -ExpectedVersion $extensionVersion -ExtensionsRoot $extensionsRoot -InstalledPackageRoot $installedPackageRoot -WorkingCopyRoot $fixture.workingCopyRoot
$rendererCapture = Get-Content -Raw -LiteralPath (Join-Path $captureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $rendererCapture -CaptureRoot $captureRoot -Target $Target -OpenReport $harnessResult.openReport
$noRepositoryWelcomeRendererCapture = Get-Content -Raw -LiteralPath (Join-Path $noRepositoryWelcomeRendererCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $noRepositoryWelcomeRendererCapture -CaptureRoot $noRepositoryWelcomeRendererCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.noRepositoryWelcomeRendererCaptureExpectations
})
$partialFreshnessRendererCapture = Get-Content -Raw -LiteralPath (Join-Path $partialFreshnessRendererCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $partialFreshnessRendererCapture -CaptureRoot $partialFreshnessRendererCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.partialFreshnessRendererCaptureExpectations
})
$staleFreshnessRendererCapture = Get-Content -Raw -LiteralPath (Join-Path $staleFreshnessRendererCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $staleFreshnessRendererCapture -CaptureRoot $staleFreshnessRendererCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.staleFreshnessRendererCaptureExpectations
})
$fullReconcileCancellationCapture = Get-Content -Raw -LiteralPath (Join-Path $fullReconcileCancellationCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $fullReconcileCancellationCapture -CaptureRoot $fullReconcileCancellationCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.fullReconcileCancellationReport.prompt.rendererCaptureExpectations
})
$multiRepositoryRefreshPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $multiRepositoryRefreshPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $multiRepositoryRefreshPromptCapture -CaptureRoot $multiRepositoryRefreshPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.multiRepositoryRefreshReport.prompt.rendererCaptureExpectations
})
$deletePromptCapture = Get-Content -Raw -LiteralPath (Join-Path $deletePromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $deletePromptCapture -CaptureRoot $deletePromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.deleteUnversionedReport.prompt.rendererCaptureExpectations
})
$deleteLoadPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $deleteLoadPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $deleteLoadPromptCapture -CaptureRoot $deleteLoadPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.deleteUnversionedLoadReport.prompt.rendererCaptureExpectations
})
$removePromptCapture = Get-Content -Raw -LiteralPath (Join-Path $removePromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $removePromptCapture -CaptureRoot $removePromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.removeReport.prompt.rendererCaptureExpectations
})
$removeCancellationPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $removeCancellationPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $removeCancellationPromptCapture -CaptureRoot $removeCancellationPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.removeCancellationReport.prompt.rendererCaptureExpectations
})
$removeKeepLocalPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $removeKeepLocalPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $removeKeepLocalPromptCapture -CaptureRoot $removeKeepLocalPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.removeKeepLocalReport.prompt.rendererCaptureExpectations
})
$movePromptCapture = Get-Content -Raw -LiteralPath (Join-Path $movePromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $movePromptCapture -CaptureRoot $movePromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.moveReport.prompt.rendererCaptureExpectations
})
$moveCancellationPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $moveCancellationPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $moveCancellationPromptCapture -CaptureRoot $moveCancellationPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.moveCancellationReport.prompt.rendererCaptureExpectations
})
$checkoutCancellationPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutCancellationPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutCancellationPromptCapture -CaptureRoot $checkoutCancellationPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutCancellationReport.prompt.rendererCaptureExpectations
})
$checkoutExistingTargetFailureUrlPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutExistingTargetFailureUrlPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutExistingTargetFailureUrlPromptCapture -CaptureRoot $checkoutExistingTargetFailureUrlPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutExistingTargetFailureReport.prompts.url.rendererCaptureExpectations
})
$checkoutExistingTargetFailureTargetPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutExistingTargetFailureTargetPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutExistingTargetFailureTargetPromptCapture -CaptureRoot $checkoutExistingTargetFailureTargetPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutExistingTargetFailureReport.prompts.targetPath.rendererCaptureExpectations
})
$checkoutExistingTargetFailureRevisionPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutExistingTargetFailureRevisionPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutExistingTargetFailureRevisionPromptCapture -CaptureRoot $checkoutExistingTargetFailureRevisionPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutExistingTargetFailureReport.prompts.revision.rendererCaptureExpectations
})
$checkoutExistingTargetFailureDepthPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutExistingTargetFailureDepthPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutExistingTargetFailureDepthPromptCapture -CaptureRoot $checkoutExistingTargetFailureDepthPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutExistingTargetFailureReport.prompts.depth.rendererCaptureExpectations
})
$checkoutExistingTargetFailureExternalsPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutExistingTargetFailureExternalsPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutExistingTargetFailureExternalsPromptCapture -CaptureRoot $checkoutExistingTargetFailureExternalsPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutExistingTargetFailureReport.prompts.externals.rendererCaptureExpectations
})
$checkoutExistingTargetFailureNotificationCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutExistingTargetFailureNotificationCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutExistingTargetFailureNotificationCapture -CaptureRoot $checkoutExistingTargetFailureNotificationCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutExistingTargetFailureReport.notification.rendererCaptureExpectations
})
$checkoutInvalidUrlFailureUrlPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutInvalidUrlFailureUrlPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutInvalidUrlFailureUrlPromptCapture -CaptureRoot $checkoutInvalidUrlFailureUrlPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutInvalidUrlFailureReport.prompts.url.rendererCaptureExpectations
})
$checkoutInvalidUrlFailureTargetPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutInvalidUrlFailureTargetPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutInvalidUrlFailureTargetPromptCapture -CaptureRoot $checkoutInvalidUrlFailureTargetPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutInvalidUrlFailureReport.prompts.targetPath.rendererCaptureExpectations
})
$checkoutInvalidUrlFailureRevisionPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutInvalidUrlFailureRevisionPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutInvalidUrlFailureRevisionPromptCapture -CaptureRoot $checkoutInvalidUrlFailureRevisionPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutInvalidUrlFailureReport.prompts.revision.rendererCaptureExpectations
})
$checkoutInvalidUrlFailureDepthPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutInvalidUrlFailureDepthPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutInvalidUrlFailureDepthPromptCapture -CaptureRoot $checkoutInvalidUrlFailureDepthPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutInvalidUrlFailureReport.prompts.depth.rendererCaptureExpectations
})
$checkoutInvalidUrlFailureExternalsPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutInvalidUrlFailureExternalsPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutInvalidUrlFailureExternalsPromptCapture -CaptureRoot $checkoutInvalidUrlFailureExternalsPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutInvalidUrlFailureReport.prompts.externals.rendererCaptureExpectations
})
$checkoutInvalidUrlFailureNotificationCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutInvalidUrlFailureNotificationCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutInvalidUrlFailureNotificationCapture -CaptureRoot $checkoutInvalidUrlFailureNotificationCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutInvalidUrlFailureReport.notification.rendererCaptureExpectations
})
$checkoutExistingDirectoryUrlPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutExistingDirectoryUrlPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutExistingDirectoryUrlPromptCapture -CaptureRoot $checkoutExistingDirectoryUrlPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutExistingDirectoryReport.prompts.url.rendererCaptureExpectations
})
$checkoutExistingDirectoryTargetPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutExistingDirectoryTargetPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutExistingDirectoryTargetPromptCapture -CaptureRoot $checkoutExistingDirectoryTargetPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutExistingDirectoryReport.prompts.targetPath.rendererCaptureExpectations
})
$checkoutExistingDirectoryRevisionPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutExistingDirectoryRevisionPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutExistingDirectoryRevisionPromptCapture -CaptureRoot $checkoutExistingDirectoryRevisionPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutExistingDirectoryReport.prompts.revision.rendererCaptureExpectations
})
$checkoutExistingDirectoryDepthPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutExistingDirectoryDepthPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutExistingDirectoryDepthPromptCapture -CaptureRoot $checkoutExistingDirectoryDepthPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutExistingDirectoryReport.prompts.depth.rendererCaptureExpectations
})
$checkoutExistingDirectoryExternalsPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutExistingDirectoryExternalsPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutExistingDirectoryExternalsPromptCapture -CaptureRoot $checkoutExistingDirectoryExternalsPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutExistingDirectoryReport.prompts.externals.rendererCaptureExpectations
})
$checkoutExistingDirectoryObstructionUrlPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutExistingDirectoryObstructionUrlPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutExistingDirectoryObstructionUrlPromptCapture -CaptureRoot $checkoutExistingDirectoryObstructionUrlPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutExistingDirectoryObstructionReport.prompts.url.rendererCaptureExpectations
})
$checkoutExistingDirectoryObstructionTargetPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutExistingDirectoryObstructionTargetPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutExistingDirectoryObstructionTargetPromptCapture -CaptureRoot $checkoutExistingDirectoryObstructionTargetPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutExistingDirectoryObstructionReport.prompts.targetPath.rendererCaptureExpectations
})
$checkoutExistingDirectoryObstructionRevisionPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutExistingDirectoryObstructionRevisionPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutExistingDirectoryObstructionRevisionPromptCapture -CaptureRoot $checkoutExistingDirectoryObstructionRevisionPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutExistingDirectoryObstructionReport.prompts.revision.rendererCaptureExpectations
})
$checkoutExistingDirectoryObstructionDepthPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutExistingDirectoryObstructionDepthPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutExistingDirectoryObstructionDepthPromptCapture -CaptureRoot $checkoutExistingDirectoryObstructionDepthPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutExistingDirectoryObstructionReport.prompts.depth.rendererCaptureExpectations
})
$checkoutExistingDirectoryObstructionExternalsPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutExistingDirectoryObstructionExternalsPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutExistingDirectoryObstructionExternalsPromptCapture -CaptureRoot $checkoutExistingDirectoryObstructionExternalsPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutExistingDirectoryObstructionReport.prompts.externals.rendererCaptureExpectations
})
$checkoutUrlPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutUrlPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutUrlPromptCapture -CaptureRoot $checkoutUrlPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutReport.prompts.url.rendererCaptureExpectations
})
$checkoutTargetPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutTargetPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutTargetPromptCapture -CaptureRoot $checkoutTargetPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutReport.prompts.targetPath.rendererCaptureExpectations
})
$checkoutRevisionPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutRevisionPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutRevisionPromptCapture -CaptureRoot $checkoutRevisionPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutReport.prompts.revision.rendererCaptureExpectations
})
$checkoutDepthPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutDepthPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutDepthPromptCapture -CaptureRoot $checkoutDepthPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutReport.prompts.depth.rendererCaptureExpectations
})
$checkoutExternalsPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $checkoutExternalsPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $checkoutExternalsPromptCapture -CaptureRoot $checkoutExternalsPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.checkoutReport.prompts.externals.rendererCaptureExpectations
})
$updateRevisionPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $updateRevisionPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $updateRevisionPromptCapture -CaptureRoot $updateRevisionPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.updateToRevisionReport.prompts.revision.rendererCaptureExpectations
})
$updateCancellationRevisionPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $updateCancellationRevisionPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $updateCancellationRevisionPromptCapture -CaptureRoot $updateCancellationRevisionPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.updateToRevisionCancellationReport.prompt.rendererCaptureExpectations
})
$updateDepthPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $updateDepthPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $updateDepthPromptCapture -CaptureRoot $updateDepthPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.updateToRevisionReport.prompts.depth.rendererCaptureExpectations
})
$updateStickyDepthPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $updateStickyDepthPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $updateStickyDepthPromptCapture -CaptureRoot $updateStickyDepthPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.updateToRevisionReport.prompts.stickyDepth.rendererCaptureExpectations
})
$updateExternalsPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $updateExternalsPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $updateExternalsPromptCapture -CaptureRoot $updateExternalsPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.updateToRevisionReport.prompts.externals.rendererCaptureExpectations
})
$branchCreateSourcePromptCapture = Get-Content -Raw -LiteralPath (Join-Path $branchCreateSourcePromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $branchCreateSourcePromptCapture -CaptureRoot $branchCreateSourcePromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.branchCreateReport.prompts.sourceUrl.rendererCaptureExpectations
})
$branchCreateDestinationPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $branchCreateDestinationPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $branchCreateDestinationPromptCapture -CaptureRoot $branchCreateDestinationPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.branchCreateReport.prompts.destinationUrl.rendererCaptureExpectations
})
$branchCreateRevisionPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $branchCreateRevisionPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $branchCreateRevisionPromptCapture -CaptureRoot $branchCreateRevisionPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.branchCreateReport.prompts.revision.rendererCaptureExpectations
})
$branchCreateMessagePromptCapture = Get-Content -Raw -LiteralPath (Join-Path $branchCreateMessagePromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $branchCreateMessagePromptCapture -CaptureRoot $branchCreateMessagePromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.branchCreateReport.prompts.message.rendererCaptureExpectations
})
$branchCreateParentsPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $branchCreateParentsPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $branchCreateParentsPromptCapture -CaptureRoot $branchCreateParentsPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.branchCreateReport.prompts.parents.rendererCaptureExpectations
})
$branchCreateExternalsPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $branchCreateExternalsPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $branchCreateExternalsPromptCapture -CaptureRoot $branchCreateExternalsPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.branchCreateReport.prompts.externals.rendererCaptureExpectations
})
$branchCreateSwitchPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $branchCreateSwitchPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $branchCreateSwitchPromptCapture -CaptureRoot $branchCreateSwitchPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.branchCreateReport.prompts.switchAfterCreate.rendererCaptureExpectations
})
$switchUrlPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $switchUrlPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $switchUrlPromptCapture -CaptureRoot $switchUrlPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.switchReport.prompts.url.rendererCaptureExpectations
})
$switchRevisionPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $switchRevisionPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $switchRevisionPromptCapture -CaptureRoot $switchRevisionPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.switchReport.prompts.revision.rendererCaptureExpectations
})
$switchDepthPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $switchDepthPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $switchDepthPromptCapture -CaptureRoot $switchDepthPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.switchReport.prompts.depth.rendererCaptureExpectations
})
$switchStickyDepthPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $switchStickyDepthPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $switchStickyDepthPromptCapture -CaptureRoot $switchStickyDepthPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.switchReport.prompts.stickyDepth.rendererCaptureExpectations
})
$switchExternalsPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $switchExternalsPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $switchExternalsPromptCapture -CaptureRoot $switchExternalsPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.switchReport.prompts.externals.rendererCaptureExpectations
})
$switchAncestryPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $switchAncestryPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $switchAncestryPromptCapture -CaptureRoot $switchAncestryPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.switchReport.prompts.ancestry.rendererCaptureExpectations
})
$lockMessagePromptCapture = Get-Content -Raw -LiteralPath (Join-Path $lockMessagePromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $lockMessagePromptCapture -CaptureRoot $lockMessagePromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.lockUnlockReport.prompts.lockMessage.rendererCaptureExpectations
})
$lockMessageCancellationPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $lockMessageCancellationPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $lockMessageCancellationPromptCapture -CaptureRoot $lockMessageCancellationPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.lockMessageCancellationReport.prompt.rendererCaptureExpectations
})
$lockModePromptCapture = Get-Content -Raw -LiteralPath (Join-Path $lockModePromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $lockModePromptCapture -CaptureRoot $lockModePromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.lockUnlockReport.prompts.lockMode.rendererCaptureExpectations
})
$unlockModePromptCapture = Get-Content -Raw -LiteralPath (Join-Path $unlockModePromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $unlockModePromptCapture -CaptureRoot $unlockModePromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.lockUnlockReport.prompts.unlockMode.rendererCaptureExpectations
})
$unlockModeCancellationPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $unlockModeCancellationPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $unlockModeCancellationPromptCapture -CaptureRoot $unlockModeCancellationPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.unlockModeCancellationReport.prompt.rendererCaptureExpectations
})
$changelistSetPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $changelistSetPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $changelistSetPromptCapture -CaptureRoot $changelistSetPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.changelistSetClearReport.prompts.set.rendererCaptureExpectations
})
$changelistRevertPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $changelistRevertPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $changelistRevertPromptCapture -CaptureRoot $changelistRevertPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.revertChangelistReport.prompt.rendererCaptureExpectations
})
$revertPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $revertPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $revertPromptCapture -CaptureRoot $revertPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.revertReport.prompt.rendererCaptureExpectations
})
$revertCancellationPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $revertCancellationPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $revertCancellationPromptCapture -CaptureRoot $revertCancellationPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.revertCancellationReport.prompt.rendererCaptureExpectations
})
$resolvePromptCapture = Get-Content -Raw -LiteralPath (Join-Path $resolvePromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $resolvePromptCapture -CaptureRoot $resolvePromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.resolveReport.prompt.rendererCaptureExpectations
})
$resolveCancellationPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $resolveCancellationPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $resolveCancellationPromptCapture -CaptureRoot $resolveCancellationPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.resolveCancellationReport.prompt.rendererCaptureExpectations
})
$cleanupPromptCapture = Get-Content -Raw -LiteralPath (Join-Path $cleanupPromptCaptureRoot "renderer-capture.json") | ConvertFrom-Json
Assert-RendererCaptureReport -Capture $cleanupPromptCapture -CaptureRoot $cleanupPromptCaptureRoot -Target $Target -OpenReport ([pscustomobject]@{
  rendererCaptureExpectations = $harnessResult.cleanupReport.prompt.rendererCaptureExpectations
})
$svnTreeAfterSha256 = Get-DirectoryTreeSha256 $fixture.svnRoot
$commitAllRepositoryOracle = Get-CommitAllRepositoryOracle `
  -SvnExe $svnExeResolved `
  -Fixture $commitAllFixture `
  -ExpectedCommitMessage $commitAllCommitMessage `
  -ExpectedTrackedContent $commitAllExpectedTrackedContent
$commitSelectedRepositoryOracle = Get-CommitSelectedRepositoryOracle `
  -SvnExe $svnExeResolved `
  -Fixture $commitSelectedFixture `
  -ExpectedCommitMessage $commitSelectedCommitMessage `
  -ExpectedTrackedContent $commitSelectedExpectedTrackedContent `
  -ExpectedUnselectedRepositoryContent $commitSelectedExpectedUnselectedContent
$commitSelectedMultiSelectionRepositoryOracle = Get-CommitSelectedMultiSelectionRepositoryOracle `
  -SvnExe $svnExeResolved `
  -Fixture $commitSelectedMultiSelectionFixture `
  -ExpectedCommitMessage $commitSelectedMultiSelectionCommitMessage `
  -ExpectedTrackedContent $commitSelectedMultiSelectionExpectedTrackedContent `
  -ExpectedLoadContent $commitSelectedMultiSelectionExpectedLoadContent
$checkoutRepositoryOracle = Get-CheckoutRepositoryOracle `
  -SvnExe $svnExeResolved `
  -Fixture $checkoutSourceFixture `
  -CheckoutTargetRoot $checkoutTargetRoot
$checkoutExistingDirectoryObstructionWorkingCopyOracle = Get-CheckoutExistingDirectoryObstructionWorkingCopyOracle `
  -SvnExe $svnExeResolved `
  -Workflow $harnessResult.checkoutExistingDirectoryObstructionReport
$updateToRevisionRepositoryOracle = Get-UpdateToRevisionRepositoryOracle `
  -SvnExe $svnExeResolved `
  -Fixture $updateFixture
$branchCreateRepositoryOracle = Get-BranchCreateRepositoryOracle `
  -SvnExe $svnExeResolved `
  -Fixture $branchCreateFixture
$switchWorkingCopyOracle = Get-SwitchWorkingCopyOracle `
  -SvnExe $svnExeResolved `
  -Fixture $switchFixture
$addToIgnoreWorkingCopyOracle = Get-AddToIgnoreWorkingCopyOracle `
  -SvnExe $svnExeResolved `
  -Fixture $addToIgnoreFixture `
  -ExpectedPattern "scratch.txt"
$lockUnlockWorkingCopyOracle = Get-LockUnlockWorkingCopyOracle `
  -SvnExe $svnExeResolved `
  -Fixture $lockFixture
$commitChangelistRepositoryOracle = Get-CommitChangelistRepositoryOracle `
  -SvnExe $svnExeResolved `
  -Fixture $commitChangelistFixture `
  -ExpectedCommitMessage $commitChangelistCommitMessage `
  -ExpectedTrackedContent $commitChangelistExpectedTrackedContent

$report = [pscustomObject]@{
  schemaVersion = 1
  schema = "subversionr.release.installed-source-control-ui-e2e.win32-x64.v1"
  publicReadinessClaim = $false
  target = $Target
  traceIds = @("BRM-001", "BRM-005", "COM-001", "COM-002", "COM-003", "DIR-003", "DIR-009", "DIR-010", "DIR-012", "DIR-013", "REP-002", "REP-004", "MIG-009", "OPS-001", "OPS-002", "OPS-003", "OPS-004", "OPS-005", "OPS-006", "OPS-007", "OPS-008", "OPS-010", "OPS-011", "OPS-013", "OPS-014", "OPS-015", "STA-003", "STA-009", "STA-013", "STA-014", "STA-016", "SYN-003", "SYN-004", "SYN-005", "TST-018", "TST-024", "UX-001", "UX-002", "UX-007")
  nonClaims = @(
    "This gate does not prove Marketplace publication.",
    "This gate does not prove VSIX signing or supply-chain provenance publication.",
    "This gate does not prove previous-stable upgrade or rollback behavior.",
    "This gate does not prove svnserve, HTTP, HTTPS, auth, or certificate flows.",
    "This gate proves the installed Checkout Repository happy path, pre-existing local directory target success path, existing-directory obstruction tree-conflict projection path, URL prompt cancellation, and covered local-file checkout failure/no-state-pollution flows but does not prove repository browser, remote auth/certificate, or broader checkout failure matrices.",
    "This gate proves installed Update to Revision prompts, local-file rN/depth/sticky-depth/externals execution, and revision prompt cancellation without working-copy or Source Control projection mutation but does not prove remote update failures, auth/certificate update flows, backend update failure UX, mixed-revision edge analysis, or load-scale update behavior.",
    "This gate proves installed Add to Ignore through svn:ignore property update but does not prove a full property editor, svn:externals editing, remote/auth/certificate property flows, property cancellation UX, or property load behavior.",
    "This gate proves installed Lock and Unlock plus Lock message and Unlock mode prompt cancellation for a local file-backed svn:needs-lock working copy item but does not prove broad remote lock-server matrices, auth/certificate lock prompts, break-lock policy, steal-lock policy, or lock load behavior.",
    "This gate proves installed changelist set/clear plus commit/revert by changelist happy paths but does not prove changelist load behavior, cancellation UX for all changelist commands, project-wide changelist policy UX, or commit template/message-history behavior.",
    "This gate proves installed Branch/Tag create and Switch local file-backed happy paths but does not prove switch-after-copy, target browsing, broad remote/auth/certificate matrices, repository-browser integration, merge workflows, or switched working-copy edge/load behavior."
  )
  extension = [pscustomobject]@{
    id = "hitsuki-ban.subversionr"
    version = $extensionVersion
    source = "installed-vsix"
    harnessPhase = [string]$harnessResult.phase
    installedPackageRoot = Get-RepoRelativePath $installedPackageRoot
    extensionHostPath = Get-RepoRelativePath ([string]$harnessResult.extensionPath)
    beforeActive = [bool]$harnessResult.beforeActive
    afterActive = [bool]$harnessResult.afterActive
    invokedCommands = $harnessResult.invokedCommands
    hasInstalledSourceControlUiE2eOpenReportCommand = [bool]$harnessResult.hasInstalledSourceControlUiE2eOpenReportCommand
    hasInstalledSourceControlUiE2eCurrentSurfaceReportCommand = [bool]$harnessResult.hasInstalledSourceControlUiE2eCurrentSurfaceReportCommand
    hasInstalledSourceControlUiE2eFreshnessReportCommand = [bool]$harnessResult.hasInstalledSourceControlUiE2eFreshnessReportCommand
    hasInstalledSourceControlUiE2eArmDirtyGenerationCancellationCommand = [bool]$harnessResult.hasInstalledSourceControlUiE2eArmDirtyGenerationCancellationCommand
    hasInstalledSourceControlUiE2eDirtyGenerationCancellationReportCommand = [bool]$harnessResult.hasInstalledSourceControlUiE2eDirtyGenerationCancellationReportCommand
    hasInstalledSourceControlUiE2eDirtyEventCommand = [bool]$harnessResult.hasInstalledSourceControlUiE2eDirtyEventCommand
    hasInstalledSourceControlUiE2eCloseReportCommand = [bool]$harnessResult.hasInstalledSourceControlUiE2eCloseReportCommand
    hasInstalledSourceControlUiE2eLazyExternalProviderReportCommand = [bool]$harnessResult.hasInstalledSourceControlUiE2eLazyExternalProviderReportCommand
    hasInstalledRepositoryLifecycleReportCommand = [bool]$harnessResult.hasInstalledRepositoryLifecycleReportCommand
    hasRefreshRepositoryCommand = [bool]$harnessResult.hasRefreshRepositoryCommand
    hasUpdateRepositoryCommand = [bool]$harnessResult.hasUpdateRepositoryCommand
    hasUpdateToRevisionCommand = [bool]$harnessResult.hasUpdateToRevisionCommand
    hasDeleteUnversionedResourceCommand = [bool]$harnessResult.hasDeleteUnversionedResourceCommand
    hasDeleteAllUnversionedResourcesCommand = [bool]$harnessResult.hasDeleteAllUnversionedResourcesCommand
    hasAddToIgnoreResourceCommand = [bool]$harnessResult.hasAddToIgnoreResourceCommand
    hasLockResourceCommand = [bool]$harnessResult.hasLockResourceCommand
    hasUnlockResourceCommand = [bool]$harnessResult.hasUnlockResourceCommand
    hasSetResourceChangelistCommand = [bool]$harnessResult.hasSetResourceChangelistCommand
    hasClearResourceChangelistCommand = [bool]$harnessResult.hasClearResourceChangelistCommand
    hasCommitAllCommand = [bool]$harnessResult.hasCommitAllCommand
    hasCommitResourceCommand = [bool]$harnessResult.hasCommitResourceCommand
    hasCommitChangelistCommand = [bool]$harnessResult.hasCommitChangelistCommand
    hasRevertChangelistCommand = [bool]$harnessResult.hasRevertChangelistCommand
    hasCheckoutRepositoryCommand = [bool]$harnessResult.hasCheckoutRepositoryCommand
    hasBranchCreateRepositoryCommand = [bool]$harnessResult.hasBranchCreateRepositoryCommand
    hasSwitchRepositoryCommand = [bool]$harnessResult.hasSwitchRepositoryCommand
    hasInstalledSourceControlUiE2eSetInputMessageCommand = [bool]$harnessResult.hasInstalledSourceControlUiE2eSetInputMessageCommand
    hasAddResourceCommand = [bool]$harnessResult.hasAddResourceCommand
    hasMoveResourceCommand = [bool]$harnessResult.hasMoveResourceCommand
    hasRemoveResourceCommand = [bool]$harnessResult.hasRemoveResourceCommand
    hasRemoveResourceKeepLocalCommand = [bool]$harnessResult.hasRemoveResourceKeepLocalCommand
    hasRevertResourceCommand = [bool]$harnessResult.hasRevertResourceCommand
    hasResolveResourceCommand = [bool]$harnessResult.hasResolveResourceCommand
    hasCleanupRepositoryCommand = [bool]$harnessResult.hasCleanupRepositoryCommand
  }
  sourceControlUiOpenReport = $harnessResult.openReport
  sourceControlUiPartialFreshnessReport = $harnessResult.partialFreshnessReport
  sourceControlUiStaleFreshnessReport = $harnessResult.staleFreshnessReport
  partialFreshnessRendererCapture = $partialFreshnessRendererCapture
  staleFreshnessRendererCapture = $staleFreshnessRendererCapture
  sourceControlUiFullReconcileCancellationWorkflow = $harnessResult.fullReconcileCancellationReport
  fullReconcileCancellationProgressCapture = $fullReconcileCancellationCapture
  sourceControlUiDirtyGenerationCancellationLoadWorkflow = $harnessResult.dirtyGenerationCancellationLoadReport
  sourceControlUiRefreshWorkflow = $harnessResult.refreshReport
  sourceControlUiRefreshLoadWorkflow = $harnessResult.refreshLoadReport
  sourceControlUiBoundaryLoadWorkflow = $harnessResult.boundaryLoadReport
  sourceControlUiMultiRepositoryRefreshWorkflow = $harnessResult.multiRepositoryRefreshReport
  sourceControlUiLazyExternalProviderWorkflow = $harnessResult.lazyExternalProviderReport
  sourceControlUiCloseReport = $harnessResult.closeReport
  sourceControlUiDeleteUnversionedFreshnessReport = $harnessResult.deleteUnversionedFreshnessReport
  sourceControlUiDeleteUnversionedWorkflow = $harnessResult.deleteUnversionedReport
  sourceControlUiDeleteUnversionedLoadWorkflow = $harnessResult.deleteUnversionedLoadReport
  sourceControlUiCommitAllWorkflow = $harnessResult.commitAllReport
  commitAllRepositoryOracle = $commitAllRepositoryOracle
  sourceControlUiCommitSelectedWorkflow = $harnessResult.commitSelectedReport
  commitSelectedRepositoryOracle = $commitSelectedRepositoryOracle
  sourceControlUiCommitSelectedMultiSelectionWorkflow = $harnessResult.commitSelectedMultiSelectionReport
  commitSelectedMultiSelectionRepositoryOracle = $commitSelectedMultiSelectionRepositoryOracle
  sourceControlUiAddToIgnoreWorkflow = $harnessResult.addToIgnoreReport
  addToIgnoreWorkingCopyOracle = $addToIgnoreWorkingCopyOracle
  sourceControlUiLockUnlockWorkflow = $harnessResult.lockUnlockReport
  sourceControlUiLockMessageCancellationWorkflow = $harnessResult.lockMessageCancellationReport
  sourceControlUiUnlockModeCancellationWorkflow = $harnessResult.unlockModeCancellationReport
  lockHeldWorkingCopyOracle = $lockHeldWorkingCopyOracle
  lockUnlockWorkingCopyOracle = $lockUnlockWorkingCopyOracle
  sourceControlUiChangelistSetClearWorkflow = $harnessResult.changelistSetClearReport
  sourceControlUiCommitChangelistWorkflow = $harnessResult.commitChangelistReport
  commitChangelistRepositoryOracle = $commitChangelistRepositoryOracle
  sourceControlUiRevertChangelistWorkflow = $harnessResult.revertChangelistReport
  sourceControlUiCheckoutCancellationWorkflow = $harnessResult.checkoutCancellationReport
  sourceControlUiCheckoutExistingTargetFailureWorkflow = $harnessResult.checkoutExistingTargetFailureReport
  sourceControlUiCheckoutInvalidUrlFailureWorkflow = $harnessResult.checkoutInvalidUrlFailureReport
  sourceControlUiCheckoutExistingDirectoryWorkflow = $harnessResult.checkoutExistingDirectoryReport
  sourceControlUiCheckoutExistingDirectoryObstructionWorkflow = $harnessResult.checkoutExistingDirectoryObstructionReport
  sourceControlUiCheckoutWorkflow = $harnessResult.checkoutReport
  checkoutRepositoryOracle = $checkoutRepositoryOracle
  checkoutExistingDirectoryObstructionWorkingCopyOracle = $checkoutExistingDirectoryObstructionWorkingCopyOracle
  sourceControlUiUpdateToRevisionCancellationWorkflow = $harnessResult.updateToRevisionCancellationReport
  sourceControlUiUpdateToRevisionWorkflow = $harnessResult.updateToRevisionReport
  updateToRevisionRepositoryOracle = $updateToRevisionRepositoryOracle
  sourceControlUiBranchCreateWorkflow = $harnessResult.branchCreateReport
  branchCreateRepositoryOracle = $branchCreateRepositoryOracle
  sourceControlUiSwitchWorkflow = $harnessResult.switchReport
  switchWorkingCopyOracle = $switchWorkingCopyOracle
  sourceControlUiAddWorkflow = $harnessResult.addReport
  sourceControlUiMoveWorkflow = $harnessResult.moveReport
  sourceControlUiMoveCancellationWorkflow = $harnessResult.moveCancellationReport
  sourceControlUiRemoveWorkflow = $harnessResult.removeReport
  sourceControlUiRemoveCancellationWorkflow = $harnessResult.removeCancellationReport
  sourceControlUiRemoveKeepLocalWorkflow = $harnessResult.removeKeepLocalReport
  sourceControlUiRevertWorkflow = $harnessResult.revertReport
  sourceControlUiRevertCancellationWorkflow = $harnessResult.revertCancellationReport
  sourceControlUiResolveWorkflow = $harnessResult.resolveReport
  sourceControlUiResolveCancellationWorkflow = $harnessResult.resolveCancellationReport
  sourceControlUiCleanupWorkflow = $harnessResult.cleanupReport
  cleanupPromptCapture = $cleanupPromptCapture
  repositoryLifecycleDeletionReport = $harnessResult.repositoryLifecycleDeletionReport
  repositoryLifecycleMoveReport = $harnessResult.repositoryLifecycleMoveReport
  versionReport = $harnessResult.versionReport
  rendererCapture = $rendererCapture
  noRepositoryWelcomeRendererCapture = $noRepositoryWelcomeRendererCapture
  multiRepositoryRefreshPromptCapture = $multiRepositoryRefreshPromptCapture
  deleteUnversionedPromptCapture = $deletePromptCapture
  deleteUnversionedLoadPromptCapture = $deleteLoadPromptCapture
  removePromptCapture = $removePromptCapture
  removeCancellationPromptCapture = $removeCancellationPromptCapture
  removeKeepLocalPromptCapture = $removeKeepLocalPromptCapture
  movePromptCapture = $movePromptCapture
  moveCancellationPromptCapture = $moveCancellationPromptCapture
  checkoutCancellationPromptCapture = $checkoutCancellationPromptCapture
  checkoutExistingTargetFailureUrlPromptCapture = $checkoutExistingTargetFailureUrlPromptCapture
  checkoutExistingTargetFailureTargetPromptCapture = $checkoutExistingTargetFailureTargetPromptCapture
  checkoutExistingTargetFailureRevisionPromptCapture = $checkoutExistingTargetFailureRevisionPromptCapture
  checkoutExistingTargetFailureDepthPromptCapture = $checkoutExistingTargetFailureDepthPromptCapture
  checkoutExistingTargetFailureExternalsPromptCapture = $checkoutExistingTargetFailureExternalsPromptCapture
  checkoutExistingTargetFailureNotificationCapture = $checkoutExistingTargetFailureNotificationCapture
  checkoutInvalidUrlFailureUrlPromptCapture = $checkoutInvalidUrlFailureUrlPromptCapture
  checkoutInvalidUrlFailureTargetPromptCapture = $checkoutInvalidUrlFailureTargetPromptCapture
  checkoutInvalidUrlFailureRevisionPromptCapture = $checkoutInvalidUrlFailureRevisionPromptCapture
  checkoutInvalidUrlFailureDepthPromptCapture = $checkoutInvalidUrlFailureDepthPromptCapture
  checkoutInvalidUrlFailureExternalsPromptCapture = $checkoutInvalidUrlFailureExternalsPromptCapture
  checkoutInvalidUrlFailureNotificationCapture = $checkoutInvalidUrlFailureNotificationCapture
  checkoutExistingDirectoryUrlPromptCapture = $checkoutExistingDirectoryUrlPromptCapture
  checkoutExistingDirectoryTargetPromptCapture = $checkoutExistingDirectoryTargetPromptCapture
  checkoutExistingDirectoryRevisionPromptCapture = $checkoutExistingDirectoryRevisionPromptCapture
  checkoutExistingDirectoryDepthPromptCapture = $checkoutExistingDirectoryDepthPromptCapture
  checkoutExistingDirectoryExternalsPromptCapture = $checkoutExistingDirectoryExternalsPromptCapture
  checkoutExistingDirectoryObstructionUrlPromptCapture = $checkoutExistingDirectoryObstructionUrlPromptCapture
  checkoutExistingDirectoryObstructionTargetPromptCapture = $checkoutExistingDirectoryObstructionTargetPromptCapture
  checkoutExistingDirectoryObstructionRevisionPromptCapture = $checkoutExistingDirectoryObstructionRevisionPromptCapture
  checkoutExistingDirectoryObstructionDepthPromptCapture = $checkoutExistingDirectoryObstructionDepthPromptCapture
  checkoutExistingDirectoryObstructionExternalsPromptCapture = $checkoutExistingDirectoryObstructionExternalsPromptCapture
  checkoutUrlPromptCapture = $checkoutUrlPromptCapture
  checkoutTargetPromptCapture = $checkoutTargetPromptCapture
  checkoutRevisionPromptCapture = $checkoutRevisionPromptCapture
  checkoutDepthPromptCapture = $checkoutDepthPromptCapture
  checkoutExternalsPromptCapture = $checkoutExternalsPromptCapture
  updateCancellationRevisionPromptCapture = $updateCancellationRevisionPromptCapture
  updateRevisionPromptCapture = $updateRevisionPromptCapture
  updateDepthPromptCapture = $updateDepthPromptCapture
  updateStickyDepthPromptCapture = $updateStickyDepthPromptCapture
  updateExternalsPromptCapture = $updateExternalsPromptCapture
  branchCreateRevisionPromptCapture = $branchCreateRevisionPromptCapture
  branchCreateSourcePromptCapture = $branchCreateSourcePromptCapture
  branchCreateDestinationPromptCapture = $branchCreateDestinationPromptCapture
  branchCreateMessagePromptCapture = $branchCreateMessagePromptCapture
  branchCreateParentsPromptCapture = $branchCreateParentsPromptCapture
  branchCreateExternalsPromptCapture = $branchCreateExternalsPromptCapture
  branchCreateSwitchPromptCapture = $branchCreateSwitchPromptCapture
  switchUrlPromptCapture = $switchUrlPromptCapture
  switchRevisionPromptCapture = $switchRevisionPromptCapture
  switchDepthPromptCapture = $switchDepthPromptCapture
  switchStickyDepthPromptCapture = $switchStickyDepthPromptCapture
  switchExternalsPromptCapture = $switchExternalsPromptCapture
  switchAncestryPromptCapture = $switchAncestryPromptCapture
  lockMessagePromptCapture = $lockMessagePromptCapture
  lockModePromptCapture = $lockModePromptCapture
  unlockModePromptCapture = $unlockModePromptCapture
  lockMessageCancellationPromptCapture = $lockMessageCancellationPromptCapture
  unlockModeCancellationPromptCapture = $unlockModeCancellationPromptCapture
  changelistSetPromptCapture = $changelistSetPromptCapture
  changelistRevertPromptCapture = $changelistRevertPromptCapture
  revertPromptCapture = $revertPromptCapture
  revertCancellationPromptCapture = $revertCancellationPromptCapture
  resolvePromptCapture = $resolvePromptCapture
  resolveCancellationPromptCapture = $resolveCancellationPromptCapture
  codeCli = [pscustomobject]@{
    path = $codeCliResolved
    sha256 = $codeCliSha256
    versionOutput = $codeCliVersion
    remoteDebuggingPort = $RemoteDebuggingPort
  }
  rendererCaptureDriver = [pscustomobject]@{
    path = Get-RepoRelativePath $rendererCaptureDriverResolved
    sha256 = (Get-FileHash -LiteralPath $rendererCaptureDriverResolved -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  fixtureTools = [pscustomobject]@{
    root = Get-RepoRelativePath $svnToolsRootResolved
    svn = [pscustomobject]@{
      path = Get-RepoRelativePath $svnExeResolved
      version = $svnVersion
      sha256 = (Get-FileHash -LiteralPath $svnExeResolved -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    svnadmin = [pscustomobject]@{
      path = Get-RepoRelativePath $svnAdminExeResolved
      version = $svnAdminVersion
      sha256 = (Get-FileHash -LiteralPath $svnAdminExeResolved -Algorithm SHA256).Hash.ToLowerInvariant()
    }
  }
  vsix = [pscustomobject]@{
    path = $vsixResolved
    relativePath = Get-RepoRelativePath $vsixResolved
    targetPlatform = $manifestTargetPlatform
    sha256 = (Get-FileHash -LiteralPath $vsixResolved -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  fixtureRoots = [pscustomobject]@{
    root = Get-RepoRelativePath $fixtureRootResolved
    repository = Get-RepoRelativePath $fixture.repoPath
    import = Get-RepoRelativePath $fixture.importRoot
    workingCopy = Get-RepoRelativePath $fixture.workingCopyRoot
    refreshLoadFixture = Get-RepoRelativePath $refreshLoadFixture.workingCopyRoot
    boundaryLoadFixture = Get-RepoRelativePath $boundaryLoadFixture.workingCopyRoot
    multiRepositoryRefreshFixture = Get-RepoRelativePath $multiRepositoryRefreshFixture.workingCopyRoot
    lazyExternalProviderFixture = Get-RepoRelativePath $lazyExternalProviderFixture.workingCopyRoot
    deleteUnversionedLoadFixture = Get-RepoRelativePath $loadFixture.workingCopyRoot
    commitAllFixture = Get-RepoRelativePath $commitAllFixture.workingCopyRoot
    commitSelectedFixture = Get-RepoRelativePath $commitSelectedFixture.workingCopyRoot
    commitSelectedMultiSelectionFixture = Get-RepoRelativePath $commitSelectedMultiSelectionFixture.workingCopyRoot
    checkoutSourceFixture = Get-RepoRelativePath $checkoutSourceFixture.workingCopyRoot
    checkoutCancellationTargetFixture = Get-RepoRelativePath $checkoutCancellationTargetRoot
    checkoutExistingTargetFailureTargetFixture = Get-RepoRelativePath $checkoutExistingTargetFailureTargetPath
    checkoutInvalidUrlFailureTargetFixture = Get-RepoRelativePath $checkoutInvalidUrlFailureTargetRoot
    checkoutExistingDirectoryTargetFixture = Get-RepoRelativePath $checkoutExistingDirectoryTargetRoot
    checkoutExistingDirectoryObstructionTargetFixture = Get-RepoRelativePath $checkoutExistingDirectoryObstructionTargetRoot
    checkoutTargetFixture = Get-RepoRelativePath $checkoutTargetRoot
    updateFixture = Get-RepoRelativePath $updateFixture.workingCopyRoot
    branchCreateFixture = Get-RepoRelativePath $branchCreateFixture.workingCopyRoot
    switchFixture = Get-RepoRelativePath $switchFixture.workingCopyRoot
    lockFixture = Get-RepoRelativePath $lockFixture.workingCopyRoot
    addFixture = Get-RepoRelativePath $addFixture.workingCopyRoot
    moveFixture = Get-RepoRelativePath $moveResourceFixture.workingCopyRoot
    moveCancellationFixture = Get-RepoRelativePath $moveCancellationFixture.workingCopyRoot
    removeFixture = Get-RepoRelativePath $removeFixture.workingCopyRoot
    removeCancellationFixture = Get-RepoRelativePath $removeCancellationFixture.workingCopyRoot
    revertFixture = Get-RepoRelativePath $revertFixture.workingCopyRoot
    revertCancellationFixture = Get-RepoRelativePath $revertCancellationFixture.workingCopyRoot
    resolveFixture = Get-RepoRelativePath $resolveFixture.workingCopyRoot
    resolveCancellationFixture = Get-RepoRelativePath $resolveCancellationFixture.workingCopyRoot
    deletedWorkingCopyFixture = Get-RepoRelativePath $deleteFixture.workingCopyRoot
    movedWorkingCopyOriginalFixture = Get-RepoRelativePath $moveFixture.workingCopyRoot
    movedWorkingCopyDestinationFixture = Get-RepoRelativePath $moveDestinationRoot
    svnCliConfig = Get-RepoRelativePath $fixture.svnCliConfigRoot
    svnRuntimeAppData = Get-RepoRelativePath $fixture.svnRuntimeAppDataRoot
    svnRuntimeConfig = Get-RepoRelativePath $fixture.svnRuntimeConfigRoot
    userData = Get-RepoRelativePath $userDataRoot
    extensions = Get-RepoRelativePath $extensionsRoot
    harness = Get-RepoRelativePath $harnessRoot
    rendererCapture = Get-RepoRelativePath $captureRoot
    noRepositoryWelcomeRendererCapture = Get-RepoRelativePath $noRepositoryWelcomeRendererCaptureRoot
    partialFreshnessRendererCapture = Get-RepoRelativePath $partialFreshnessRendererCaptureRoot
    staleFreshnessRendererCapture = Get-RepoRelativePath $staleFreshnessRendererCaptureRoot
    fullReconcileCancellationProgressCapture = Get-RepoRelativePath $fullReconcileCancellationCaptureRoot
    multiRepositoryRefreshPromptCapture = Get-RepoRelativePath $multiRepositoryRefreshPromptCaptureRoot
    deleteUnversionedPromptCapture = Get-RepoRelativePath $deletePromptCaptureRoot
    deleteUnversionedLoadPromptCapture = Get-RepoRelativePath $deleteLoadPromptCaptureRoot
    removePromptCapture = Get-RepoRelativePath $removePromptCaptureRoot
    removeCancellationPromptCapture = Get-RepoRelativePath $removeCancellationPromptCaptureRoot
    removeKeepLocalPromptCapture = Get-RepoRelativePath $removeKeepLocalPromptCaptureRoot
    movePromptCapture = Get-RepoRelativePath $movePromptCaptureRoot
    moveCancellationPromptCapture = Get-RepoRelativePath $moveCancellationPromptCaptureRoot
    checkoutCancellationPromptCapture = Get-RepoRelativePath $checkoutCancellationPromptCaptureRoot
    checkoutExistingTargetFailureUrlPromptCapture = Get-RepoRelativePath $checkoutExistingTargetFailureUrlPromptCaptureRoot
    checkoutExistingTargetFailureTargetPromptCapture = Get-RepoRelativePath $checkoutExistingTargetFailureTargetPromptCaptureRoot
    checkoutExistingTargetFailureRevisionPromptCapture = Get-RepoRelativePath $checkoutExistingTargetFailureRevisionPromptCaptureRoot
    checkoutExistingTargetFailureDepthPromptCapture = Get-RepoRelativePath $checkoutExistingTargetFailureDepthPromptCaptureRoot
    checkoutExistingTargetFailureExternalsPromptCapture = Get-RepoRelativePath $checkoutExistingTargetFailureExternalsPromptCaptureRoot
    checkoutExistingTargetFailureNotificationCapture = Get-RepoRelativePath $checkoutExistingTargetFailureNotificationCaptureRoot
    checkoutInvalidUrlFailureUrlPromptCapture = Get-RepoRelativePath $checkoutInvalidUrlFailureUrlPromptCaptureRoot
    checkoutInvalidUrlFailureTargetPromptCapture = Get-RepoRelativePath $checkoutInvalidUrlFailureTargetPromptCaptureRoot
    checkoutInvalidUrlFailureRevisionPromptCapture = Get-RepoRelativePath $checkoutInvalidUrlFailureRevisionPromptCaptureRoot
    checkoutInvalidUrlFailureDepthPromptCapture = Get-RepoRelativePath $checkoutInvalidUrlFailureDepthPromptCaptureRoot
    checkoutInvalidUrlFailureExternalsPromptCapture = Get-RepoRelativePath $checkoutInvalidUrlFailureExternalsPromptCaptureRoot
    checkoutInvalidUrlFailureNotificationCapture = Get-RepoRelativePath $checkoutInvalidUrlFailureNotificationCaptureRoot
    checkoutExistingDirectoryUrlPromptCapture = Get-RepoRelativePath $checkoutExistingDirectoryUrlPromptCaptureRoot
    checkoutExistingDirectoryTargetPromptCapture = Get-RepoRelativePath $checkoutExistingDirectoryTargetPromptCaptureRoot
    checkoutExistingDirectoryRevisionPromptCapture = Get-RepoRelativePath $checkoutExistingDirectoryRevisionPromptCaptureRoot
    checkoutExistingDirectoryDepthPromptCapture = Get-RepoRelativePath $checkoutExistingDirectoryDepthPromptCaptureRoot
    checkoutExistingDirectoryExternalsPromptCapture = Get-RepoRelativePath $checkoutExistingDirectoryExternalsPromptCaptureRoot
    checkoutExistingDirectoryObstructionUrlPromptCapture = Get-RepoRelativePath $checkoutExistingDirectoryObstructionUrlPromptCaptureRoot
    checkoutExistingDirectoryObstructionTargetPromptCapture = Get-RepoRelativePath $checkoutExistingDirectoryObstructionTargetPromptCaptureRoot
    checkoutExistingDirectoryObstructionRevisionPromptCapture = Get-RepoRelativePath $checkoutExistingDirectoryObstructionRevisionPromptCaptureRoot
    checkoutExistingDirectoryObstructionDepthPromptCapture = Get-RepoRelativePath $checkoutExistingDirectoryObstructionDepthPromptCaptureRoot
    checkoutExistingDirectoryObstructionExternalsPromptCapture = Get-RepoRelativePath $checkoutExistingDirectoryObstructionExternalsPromptCaptureRoot
    checkoutUrlPromptCapture = Get-RepoRelativePath $checkoutUrlPromptCaptureRoot
    checkoutTargetPromptCapture = Get-RepoRelativePath $checkoutTargetPromptCaptureRoot
    checkoutRevisionPromptCapture = Get-RepoRelativePath $checkoutRevisionPromptCaptureRoot
    checkoutDepthPromptCapture = Get-RepoRelativePath $checkoutDepthPromptCaptureRoot
    checkoutExternalsPromptCapture = Get-RepoRelativePath $checkoutExternalsPromptCaptureRoot
    updateCancellationRevisionPromptCapture = Get-RepoRelativePath $updateCancellationRevisionPromptCaptureRoot
    updateRevisionPromptCapture = Get-RepoRelativePath $updateRevisionPromptCaptureRoot
    updateDepthPromptCapture = Get-RepoRelativePath $updateDepthPromptCaptureRoot
    updateStickyDepthPromptCapture = Get-RepoRelativePath $updateStickyDepthPromptCaptureRoot
    updateExternalsPromptCapture = Get-RepoRelativePath $updateExternalsPromptCaptureRoot
    branchCreateSourcePromptCapture = Get-RepoRelativePath $branchCreateSourcePromptCaptureRoot
    branchCreateDestinationPromptCapture = Get-RepoRelativePath $branchCreateDestinationPromptCaptureRoot
    branchCreateRevisionPromptCapture = Get-RepoRelativePath $branchCreateRevisionPromptCaptureRoot
    branchCreateMessagePromptCapture = Get-RepoRelativePath $branchCreateMessagePromptCaptureRoot
    branchCreateParentsPromptCapture = Get-RepoRelativePath $branchCreateParentsPromptCaptureRoot
    branchCreateExternalsPromptCapture = Get-RepoRelativePath $branchCreateExternalsPromptCaptureRoot
    branchCreateSwitchPromptCapture = Get-RepoRelativePath $branchCreateSwitchPromptCaptureRoot
    switchUrlPromptCapture = Get-RepoRelativePath $switchUrlPromptCaptureRoot
    switchRevisionPromptCapture = Get-RepoRelativePath $switchRevisionPromptCaptureRoot
    switchDepthPromptCapture = Get-RepoRelativePath $switchDepthPromptCaptureRoot
    switchStickyDepthPromptCapture = Get-RepoRelativePath $switchStickyDepthPromptCaptureRoot
    switchExternalsPromptCapture = Get-RepoRelativePath $switchExternalsPromptCaptureRoot
    switchAncestryPromptCapture = Get-RepoRelativePath $switchAncestryPromptCaptureRoot
    lockMessageCancellationPromptCapture = Get-RepoRelativePath $lockMessageCancellationPromptCaptureRoot
    lockMessagePromptCapture = Get-RepoRelativePath $lockMessagePromptCaptureRoot
    lockModePromptCapture = Get-RepoRelativePath $lockModePromptCaptureRoot
    unlockModeCancellationPromptCapture = Get-RepoRelativePath $unlockModeCancellationPromptCaptureRoot
    unlockModePromptCapture = Get-RepoRelativePath $unlockModePromptCaptureRoot
    changelistSetPromptCapture = Get-RepoRelativePath $changelistSetPromptCaptureRoot
    changelistRevertPromptCapture = Get-RepoRelativePath $changelistRevertPromptCaptureRoot
    revertPromptCapture = Get-RepoRelativePath $revertPromptCaptureRoot
    revertCancellationPromptCapture = Get-RepoRelativePath $revertCancellationPromptCaptureRoot
    resolvePromptCapture = Get-RepoRelativePath $resolvePromptCaptureRoot
    resolveCancellationPromptCapture = Get-RepoRelativePath $resolveCancellationPromptCaptureRoot
    cleanupPromptCapture = Get-RepoRelativePath $cleanupPromptCaptureRoot
  }
  installedExtensions = $installedExtensions
  workingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $fixture.workingCopyRoot
    repositoryUrl = $fixture.repoUrl
    svnTreeBeforeSha256 = $fixture.svnTreeBeforeSha256
    svnTreeAfterSha256 = $svnTreeAfterSha256
    svnMetadataMutation = $(if ($svnTreeAfterSha256 -eq $fixture.svnTreeBeforeSha256) { "none" } else { "metadata-refreshed" })
    expectedResources = @(
      [pscustomobject]@{
        path = "src/tracked.txt"
        group = "changes"
        contextValue = "subversionr.changedFile.baseDiffable"
        localStatus = "modified"
        removedFromVersionControlByInstalledKeepLocalWorkflow = $true
        localFilePreservedByInstalledKeepLocalWorkflow = $true
      },
      [pscustomobject]@{
        path = "scratch.txt"
        group = "unversioned"
        contextValue = "subversionr.unversioned"
        localStatus = "unversioned"
        deletedByInstalledDeleteUnversionedWorkflow = $true
      }
    )
  }
  refreshLoadWorkingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $refreshLoadFixture.workingCopyRoot
    repositoryUrl = $refreshLoadFixture.repoUrl
    requestedModifiedItemCount = $refreshLoadModifiedItemCount
    modifiedPaths = $refreshLoadFixture.modifiedLoadPaths
    workflow = $harnessResult.refreshLoadReport
    dirtyGenerationCancellationWorkflow = $harnessResult.dirtyGenerationCancellationLoadReport
  }
  boundaryLoadWorkingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $boundaryLoadFixture.workingCopyRoot
    repositoryUrl = $boundaryLoadFixture.parent.repoUrl
    directoryExternalRoot = Get-RepoRelativePath $boundaryLoadFixture.directoryExternalRoot
    directoryExternalRepositoryUrl = $boundaryLoadFixture.directoryExternal.repoUrl
    fileExternalBoundary = Get-RepoRelativePath $boundaryLoadFixture.fileExternalBoundary
    requestedParentModifiedItemCount = $boundaryLoadParentModifiedItemCount
    requestedBoundaryModifiedItemCount = $boundaryLoadBoundaryModifiedItemCount
    parentModifiedPaths = $boundaryLoadFixture.parentModifiedLoadPaths
    externalModifiedPaths = $boundaryLoadFixture.externalModifiedLoadPaths
    workflow = $harnessResult.boundaryLoadReport
  }
  multiRepositoryRefreshWorkingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $multiRepositoryRefreshFixture.workingCopyRoot
    repositoryUrl = $multiRepositoryRefreshFixture.repoUrl
    workflow = $harnessResult.multiRepositoryRefreshReport
  }
  deleteUnversionedLoadWorkingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $loadFixture.workingCopyRoot
    repositoryUrl = $loadFixture.repoUrl
    requestedUnversionedItemCount = $deleteUnversionedLoadItemCount
    unversionedPaths = $loadFixture.unversionedPaths
    workflow = $harnessResult.deleteUnversionedLoadReport
  }
  commitAllWorkingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $commitAllFixture.workingCopyRoot
    repositoryUrl = $commitAllFixture.repoUrl
    eligiblePaths = @("src/tracked.txt")
    excludedUnversionedPaths = $commitAllFixture.unversionedPaths
    workflow = $harnessResult.commitAllReport
    repositoryOracle = $commitAllRepositoryOracle
  }
  commitSelectedWorkingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $commitSelectedFixture.workingCopyRoot
    repositoryUrl = $commitSelectedFixture.repoUrl
    selectedPaths = @("src/tracked.txt")
    unselectedChangedPaths = $commitSelectedFixture.modifiedLoadPaths
    workflow = $harnessResult.commitSelectedReport
    repositoryOracle = $commitSelectedRepositoryOracle
  }
  commitSelectedMultiSelectionWorkingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $commitSelectedMultiSelectionFixture.workingCopyRoot
    repositoryUrl = $commitSelectedMultiSelectionFixture.repoUrl
    selectedPaths = @("src/tracked.txt", "load/modified-001.txt")
    workflow = $harnessResult.commitSelectedMultiSelectionReport
    repositoryOracle = $commitSelectedMultiSelectionRepositoryOracle
  }
  addToIgnoreWorkingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $addToIgnoreFixture.workingCopyRoot
    repositoryUrl = $addToIgnoreFixture.repoUrl
    ignoredPattern = "scratch.txt"
    workflow = $harnessResult.addToIgnoreReport
    workingCopyOracle = $addToIgnoreWorkingCopyOracle
  }
  lockWorkingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $lockFixture.workingCopyRoot
    repositoryUrl = $lockFixture.repoUrl
    needsLockRelativePath = $lockFixture.lockRelativePath
    workflow = $harnessResult.lockUnlockReport
    lockMessageCancellationWorkflow = $harnessResult.lockMessageCancellationReport
    unlockModeCancellationWorkflow = $harnessResult.unlockModeCancellationReport
    heldWorkingCopyOracle = $lockHeldWorkingCopyOracle
    workingCopyOracle = $lockUnlockWorkingCopyOracle
  }
  changelistSetClearWorkingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $changelistSetClearFixture.workingCopyRoot
    repositoryUrl = $changelistSetClearFixture.repoUrl
    changelist = "review"
    workflow = $harnessResult.changelistSetClearReport
  }
  commitChangelistWorkingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $commitChangelistFixture.workingCopyRoot
    repositoryUrl = $commitChangelistFixture.repoUrl
    changelist = $commitChangelistFixture.changelist
    selectedPaths = @("src/tracked.txt")
    unselectedChangedPaths = $commitChangelistFixture.modifiedLoadPaths
    workflow = $harnessResult.commitChangelistReport
    repositoryOracle = $commitChangelistRepositoryOracle
  }
  revertChangelistWorkingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $revertChangelistFixture.workingCopyRoot
    repositoryUrl = $revertChangelistFixture.repoUrl
    changelist = $revertChangelistFixture.changelist
    workflow = $harnessResult.revertChangelistReport
  }
  updateWorkingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $updateFixture.workingCopyRoot
    peerRoot = Get-RepoRelativePath $updateFixture.peerWorkingCopyRoot
    repositoryUrl = $updateFixture.repoUrl
    requestedRevision = $updateFixture.expectedRevision
    requestedDepth = "files"
    requestedStickyDepth = $true
    requestedIgnoreExternals = $false
    targetRelativePath = $updateFixture.targetRelativePath
    expectedUpdatedContent = $updateFixture.expectedUpdatedContent
    cancellationWorkflow = $harnessResult.updateToRevisionCancellationReport
    workflow = $harnessResult.updateToRevisionReport
    repositoryOracle = $updateToRevisionRepositoryOracle
  }
  branchCreateWorkingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $branchCreateFixture.workingCopyRoot
    repositoryUrl = $branchCreateFixture.repoUrl
    sourceUrl = $branchCreateFixture.branchSourceUrl
    destinationUrl = $branchCreateFixture.branchDestinationUrl
    message = $branchCreateFixture.branchMessage
    requestedRevision = "head"
    requestedMakeParents = $false
    requestedIgnoreExternals = $true
    workflow = $harnessResult.branchCreateReport
    repositoryOracle = $branchCreateRepositoryOracle
  }
  switchWorkingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $switchFixture.workingCopyRoot
    repositoryUrl = $switchFixture.repoUrl
    targetUrl = $switchFixture.switchTargetUrl
    requestedRevision = "head"
    requestedDepth = "infinity"
    requestedStickyDepth = $true
    requestedIgnoreExternals = $true
    requestedIgnoreAncestry = $false
    workflow = $harnessResult.switchReport
    workingCopyOracle = $switchWorkingCopyOracle
  }
  addWorkingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $addFixture.workingCopyRoot
    repositoryUrl = $addFixture.repoUrl
    workflow = $harnessResult.addReport
  }
  moveWorkingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $moveResourceFixture.workingCopyRoot
    repositoryUrl = $moveResourceFixture.repoUrl
    workflow = $harnessResult.moveReport
  }
  moveCancellationWorkingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $moveCancellationFixture.workingCopyRoot
    repositoryUrl = $moveCancellationFixture.repoUrl
    workflow = $harnessResult.moveCancellationReport
  }
  removeWorkingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $removeFixture.workingCopyRoot
    repositoryUrl = $removeFixture.repoUrl
    workflow = $harnessResult.removeReport
  }
  removeCancellationWorkingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $removeCancellationFixture.workingCopyRoot
    repositoryUrl = $removeCancellationFixture.repoUrl
    workflow = $harnessResult.removeCancellationReport
  }
  revertWorkingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $revertFixture.workingCopyRoot
    repositoryUrl = $revertFixture.repoUrl
    workflow = $harnessResult.revertReport
  }
  revertCancellationWorkingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $revertCancellationFixture.workingCopyRoot
    repositoryUrl = $revertCancellationFixture.repoUrl
    workflow = $harnessResult.revertCancellationReport
  }
  resolveWorkingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $resolveFixture.workingCopyRoot
    peerRoot = Get-RepoRelativePath $resolveFixture.peerWorkingCopyRoot
    repositoryUrl = $resolveFixture.repoUrl
    conflictPath = $resolveFixture.conflictPath
    expectedMergedContent = $resolveFixture.mergedContent
    svnTreeBeforeSha256 = $resolveFixture.svnTreeBeforeSha256
    workflow = $harnessResult.resolveReport
  }
  resolveCancellationWorkingCopy = [pscustomobject]@{
    root = Get-RepoRelativePath $resolveCancellationFixture.workingCopyRoot
    peerRoot = Get-RepoRelativePath $resolveCancellationFixture.peerWorkingCopyRoot
    repositoryUrl = $resolveCancellationFixture.repoUrl
    conflictPath = $resolveCancellationFixture.conflictPath
    expectedMergedContent = $resolveCancellationFixture.mergedContent
    svnTreeBeforeSha256 = $resolveCancellationFixture.svnTreeBeforeSha256
    workflow = $harnessResult.resolveCancellationReport
  }
  assertions = @(
    "VSIX was installed into an isolated extensions directory",
    "VSIX manifest TargetPlatform matched the requested release target",
    "Fixture repository and working copy were created with source-built Apache Subversion 1.14.5 CLI tools",
    "Installed VSIX and sidecar ran with fixture-local APPDATA/Subversion config isolation",
    "SubversionR was loaded from the installed VSIX package root, not from the harness extension",
    "SubversionR was active before installed Source Control UI E2E validation",
    "SubversionR opened the real fixture working copy through its Rust sidecar and libsvn bridge",
    "SubversionR kept the repository open while the VS Code renderer Source Control UI was captured",
    "SubversionR exposed the installed partial SourceControl status bar full-reconcile affordance",
    "VS Code renderer DOM, accessibility, and screenshot evidence confirmed the installed partial SourceControl status affordance",
    "SubversionR exposed the installed stale SourceControl status bar full-reconcile affordance",
    "VS Code renderer DOM, accessibility, and screenshot evidence confirmed the installed stale SourceControl status affordance",
    "SubversionR exposed installed Full Reconcile through cancellable VS Code progress and observed user cancellation",
    "SubversionR recovered the installed SourceControl surface after Full Reconcile cancellation",
    "SubversionR executed the installed Refresh command against the single open fixture repository",
    "SubversionR kept the SourceControl surface available after installed Refresh command execution",
    "SubversionR executed the installed Refresh command against a 64-item modified source-built load fixture",
    "SubversionR preserved SourceControl projection for every modified load fixture resource after installed Refresh command execution",
    "SubversionR projected 128 parent modified resources while excluding 128 modified resources below an external boundary",
    "SubversionR executed the installed Refresh command from a multi-repository QuickPick selection",
    "VS Code renderer DOM, accessibility, screenshot, and QuickPick selection evidence confirmed the multi-repository Refresh prompt",
    "UX-007 repository picker evidence is limited to the installed multi-repository QuickPick selection path",
    "SubversionR executed the installed Delete Unversioned command against the fixture unversioned resource",
    "VS Code renderer DOM, accessibility, screenshot, and click evidence confirmed the Delete Unversioned modal",
    "SubversionR refreshed SourceControl projection after Delete Unversioned removed the fixture file",
    "SubversionR executed the installed Delete All Unversioned Items command against a 64-item unversioned load fixture",
    "VS Code renderer DOM, accessibility, screenshot, and click evidence confirmed the Delete All Unversioned Items modal",
    "SubversionR cleared SourceControl unversioned projection after Delete All Unversioned Items removed every load fixture file",
    "SubversionR executed the installed Commit All command from the SourceControl input accept command against an independent changed fixture",
    "SubversionR cleared the matching repository input message and applied targeted post-commit reconcile after Commit All",
    "SubversionR excluded unversioned resources from Commit All while committing eligible changed file resources",
    "Source-built SVN repository oracle confirmed Commit All persisted tracked content and did not add the unversioned scratch resource",
    "SubversionR executed the installed Commit Selected command with an SCM resource command argument against an independent changed fixture",
    "SubversionR cleared the matching repository input message and applied targeted post-commit reconcile after Commit Selected",
    "SubversionR committed only the selected changed file while preserving an unselected changed file in SourceControl",
    "Source-built SVN repository oracle confirmed Commit Selected persisted selected tracked content while leaving the unselected file at repository baseline",
    "SubversionR executed the installed Add to Ignore command against an independent unversioned fixture resource",
    "SubversionR read the parent svn:ignore property, wrote scratch.txt, and refreshed SourceControl projection",
    "Source-built SVN working-copy oracle confirmed svn:ignore contains scratch.txt and status reports the file as ignored",
    "SubversionR executed installed Set Changelist and Clear Changelist commands against an independent changed fixture",
    "VS Code renderer DOM, accessibility, screenshot, and QuickInput submission evidence confirmed the Set Changelist prompt",
    "SubversionR projected the review changelist group after set and returned the resource to Changes after clear",
    "SubversionR executed the installed Commit Changelist group command with a restrictive review changelist filter",
    "Source-built SVN repository oracle confirmed Commit Changelist persisted selected changelist content and log message",
    "SubversionR executed the installed Revert Changelist group command with a restrictive review changelist filter",
    "VS Code renderer DOM, accessibility, screenshot, and click evidence confirmed the Revert Changelist modal",
    "SubversionR executed the installed Update to Revision command against an independent fixture at r2",
    "VS Code renderer DOM, accessibility, screenshot, QuickInput, and QuickPick evidence confirmed the Update to Revision revision/depth/sticky-depth/externals prompts",
    "SubversionR applied the requested r2 file content after installed Update to Revision",
    "SubversionR completed post-update SourceControl reconciliation and kept projection available",
    "Source-built SVN repository oracle confirmed the updated working-copy file matched the requested repository revision",
    "SubversionR executed the installed Branch/Tag create command against an independent local-file fixture",
    "VS Code renderer DOM, accessibility, screenshot, QuickInput, and QuickPick evidence confirmed the Branch/Tag source, destination, revision, message, parent-policy, and externals prompts",
    "Source-built SVN repository oracle confirmed Branch/Tag create produced copyfrom metadata, matched source content, and recorded the expected copy log message",
    "SubversionR executed the installed Switch command against an independent local-file fixture",
    "VS Code renderer DOM, accessibility, screenshot, QuickInput, and QuickPick evidence confirmed the Switch URL, revision, depth, sticky-depth, externals, and ancestry prompts",
    "SubversionR advanced SourceControl generation, preserved repository identity, and kept projection available after Switch",
    "Source-built SVN working-copy oracle confirmed the switched working-copy URL matched the requested branch URL",
    "SubversionR executed the installed Add command against an independent unversioned fixture resource",
    "SubversionR preserved the added file on disk and refreshed SourceControl projection from unversioned to local changes",
    "SubversionR executed the installed Move command against an independent changed fixture resource",
    "VS Code renderer DOM, accessibility, screenshot, and QuickInput submission evidence confirmed the Move destination prompt",
    "SubversionR moved the fixture file on disk and refreshed SourceControl projection for the source deletion and destination addition",
    "SubversionR executed the installed Move command cancellation path against an independent changed fixture resource",
    "VS Code renderer DOM, accessibility, screenshot, and QuickInput Escape evidence confirmed the Move destination prompt cancellation",
    "SubversionR preserved the fixture file on disk and kept SourceControl projection unchanged after cancelled Move",
    "SubversionR executed the installed Remove command against an independent missing versioned fixture resource",
    "VS Code renderer DOM, accessibility, screenshot, and click evidence confirmed the Remove modal",
    "SubversionR scheduled the missing versioned file for local deletion and refreshed SourceControl projection",
    "SubversionR executed the installed Remove command cancellation path against an independent changed fixture resource",
    "VS Code renderer DOM, accessibility, screenshot, and Escape evidence confirmed the Remove modal cancellation",
    "SubversionR preserved the modified fixture file and kept SourceControl projection unchanged after cancelled Remove",
    "SubversionR executed the installed Keep-local Remove command against the fixture changed resource",
    "VS Code renderer DOM, accessibility, screenshot, and click evidence confirmed the Keep-local Remove modal",
    "SubversionR refreshed SourceControl projection after Keep-local Remove scheduled versioned removal while preserving the local file",
    "SubversionR executed the installed Revert command against an independent changed fixture resource",
    "VS Code renderer DOM, accessibility, screenshot, and click evidence confirmed the Revert modal",
    "SubversionR restored the changed file to the repository baseline and cleared it from SourceControl projection after Revert",
    "SubversionR executed the installed Revert command cancellation path against an independent changed fixture resource",
    "VS Code renderer DOM, accessibility, screenshot, and Escape evidence confirmed the Revert modal cancellation",
    "SubversionR preserved the modified fixture file and kept SourceControl projection unchanged after cancelled Revert",
    "SubversionR executed the installed Resolve command against an independent text-conflict fixture resource",
    "VS Code renderer DOM, accessibility, screenshot, and click evidence confirmed the Resolve modal",
    "SubversionR used the merged conflict choice, preserved the working-copy file content, and cleared the conflict projection after Resolve",
    "SubversionR executed the installed Resolve command cancellation path against an independent text-conflict fixture resource",
    "VS Code renderer DOM, accessibility, screenshot, and Escape evidence confirmed the Resolve modal cancellation",
    "SubversionR preserved the conflicted fixture file and kept SourceControl conflict projection unchanged after cancelled Resolve",
    "SubversionR executed the installed Cleanup command against the live fixture repository",
    "SubversionR completed a post-cleanup full reconcile and kept the SourceControl surface available",
    "VS Code renderer DOM text contained required SubversionR Source Control tokens",
    "VS Code renderer accessibility tree contained required SubversionR Source Control tokens",
    "VS Code renderer screenshot was captured as a nonblank PNG with verified SHA256",
    "SubversionR closed the repository after renderer capture",
    "SubversionR closed a deleted installed working-copy session through repository lifecycle reconciliation",
    "SubversionR recovered a moved installed working-copy session through repository lifecycle reconciliation",
    "SubversionR version report backend status was initialized with libsvn 1.14.5",
    "publicReadinessClaim remains false"
  )
}

$evidenceParent = Split-Path -Parent $evidencePathResolved
New-Item -ItemType Directory -Force -Path $evidenceParent | Out-Null
$report | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $evidencePathResolved -Encoding utf8

Write-Host "Verified SubversionR installed VSIX Source Control UI E2E evidence for $Target at $fixtureRootResolved."

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("Run", "VerifyEvidence")]
  [string]$Mode,

  [Parameter(Mandatory = $true)]
  [string]$EvidencePath,

  [string]$CodeCliPath,

  [string]$WorkRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$schema = "subversionr.research.descendant-wc-activation.v1"
$expectedVersion = "1.129.0"
$expectedCommit = "125df4672b8a6a34975303c6b0baa124e560a4f7"
$expectedArchitecture = "x64"
$maximumOutputBytes = 262144
$maximumEvidenceBytes = 65536
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$evidenceRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot "docs\research\evidence"))
$workRootBoundary = [IO.Path]::GetFullPath((Join-Path $repoRoot ".cache\research"))

$probes = @(
  [ordered]@{ id = "subversionr-research.descendant-wc-exact"; event = "workspaceContains:.svn/wc.db" },
  [ordered]@{ id = "subversionr-research.descendant-wc-glob-file"; event = "workspaceContains:**/.svn/wc.db" },
  [ordered]@{ id = "subversionr-research.descendant-wc-glob-directory"; event = "workspaceContains:**/.svn" },
  [ordered]@{ id = "subversionr-research.descendant-wc-one-level"; event = "workspaceContains:*/.svn" },
  [ordered]@{ id = "subversionr-research.descendant-wc-two-level"; event = "workspaceContains:*/*/.svn" }
)

$fixtureDefinitions = @(
  [ordered]@{ id = "wc-root"; sentinel = ".svn/wc.db" },
  [ordered]@{ id = "parent-ws"; sentinel = "child/.svn/wc.db" },
  [ordered]@{ id = "no-svn"; sentinel = "plain.txt" }
)

$requiredNonClaims = @(
  "doesNotChangeProductActivationEvents",
  "doesNotEstablishDescendantWorkingCopySupport",
  "doesNotCoverRemoteOrUntrustedWorkspaces"
)

function Resolve-RepoPath([string]$Path) {
  if ([IO.Path]::IsPathRooted($Path)) {
    return [IO.Path]::GetFullPath($Path)
  }
  return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Assert-ContainedPath([string]$Path, [string]$Boundary, [string]$Label) {
  $fullPath = [IO.Path]::GetFullPath($Path)
  $fullBoundary = [IO.Path]::GetFullPath($Boundary).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  $prefix = $fullBoundary + [IO.Path]::DirectorySeparatorChar
  if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "$Label must be contained by '$fullBoundary'; got '$fullPath'."
  }
}

function Get-ObjectProperty([object]$Object, [string]$Name, [string]$Context) {
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    throw "$Context is missing required property '$Name'."
  }
  return $property.Value
}

function Assert-Equal([object]$Expected, [object]$Actual, [string]$Context) {
  if ([string]$Expected -ne [string]$Actual) {
    throw "$Context expected '$Expected', got '$Actual'."
  }
}

function Assert-StringArray([object]$Actual, [string[]]$Expected, [string]$Context) {
  $actualValues = @(if ($null -ne $Actual) { $Actual | ForEach-Object { [string]$_ } })
  $expectedValues = @(if ($null -ne $Expected) { $Expected | ForEach-Object { [string]$_ } })
  if ($actualValues.Count -ne $expectedValues.Count) {
    throw "$Context expected $($expectedValues.Count) entries, got $($actualValues.Count)."
  }
  for ($index = 0; $index -lt $expectedValues.Count; $index++) {
    Assert-Equal $expectedValues[$index] $actualValues[$index] "$Context[$index]"
  }
}

function Get-Sha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TextSha256([string]$Text) {
  $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))
  return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function Get-ProbePackage([object]$Probe) {
  $name = ([string]$Probe.id).Split(".")[-1]
  return [ordered]@{
    name = $name
    displayName = "SubversionR descendant WC research probe $name"
    publisher = "subversionr-research"
    version = "0.0.1"
    engines = [ordered]@{ vscode = "^1.85.0" }
    main = "./extension.js"
    activationEvents = @([string]$Probe.event)
    capabilities = [ordered]@{ untrustedWorkspaces = [ordered]@{ supported = $true } }
  }
}

function Get-ProbeSource([object]$Probe) {
  $template = @'
const fs = require('fs');
const path = require('path');
function activate() {
  const markerRoot = process.env.SUBVERSIONR_ACTIVATION_MARKER_ROOT;
  if (!markerRoot) throw new Error('SUBVERSIONR_ACTIVATION_MARKER_ROOT is required');
  fs.mkdirSync(markerRoot, { recursive: true });
  const markerPath = path.join(markerRoot, '__PROBE_ID__.json');
  fs.writeFileSync(markerPath, JSON.stringify({ id: '__PROBE_ID__', activationEvent: '__ACTIVATION_EVENT__' }), { flag: 'wx' });
}
exports.activate = activate;
'@
  return $template.Replace("__PROBE_ID__", [string]$Probe.id).Replace("__ACTIVATION_EVENT__", [string]$Probe.event)
}

function Get-ProbeDefinitionMaterial([object]$Probe, [string]$ExtensionJsSha256) {
  $package = Get-ProbePackage $Probe
  return @(
    [string]$Probe.id,
    [string]$package.publisher,
    [string]$package.name,
    [string]$package.version,
    [string]$package.main,
    [string]$Probe.event,
    $ExtensionJsSha256
  ) -join "`n"
}

function Get-ExpectedProbeEvidence([object]$Probe) {
  $extensionJsSha256 = Get-TextSha256 (Get-ProbeSource $Probe)
  return [ordered]@{
    id = [string]$Probe.id
    activationEvent = [string]$Probe.event
    definitionSha256 = Get-TextSha256 (Get-ProbeDefinitionMaterial $Probe $extensionJsSha256)
    extensionJsSha256 = $extensionJsSha256
  }
}

function Get-FixtureHash([string]$FixturePath, [string]$Sentinel) {
  $sentinelPath = Join-Path $FixturePath ($Sentinel.Replace("/", [IO.Path]::DirectorySeparatorChar))
  $material = "$Sentinel`n$(Get-Sha256 $sentinelPath)"
  $bytes = [Text.Encoding]::UTF8.GetBytes($material)
  $hash = [Security.Cryptography.SHA256]::HashData($bytes)
  return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function Get-ExpectedFixtureHash([string]$Sentinel) {
  $fixtureContent = "subversionr descendant working-copy activation research fixture`n"
  $contentHashBytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($fixtureContent))
  $contentHash = [Convert]::ToHexString($contentHashBytes).ToLowerInvariant()
  $material = "$Sentinel`n$contentHash"
  $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($material))
  return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function Write-AtomicJson([object]$Value, [string]$Path, [int]$MaximumBytes) {
  $json = $Value | ConvertTo-Json -Depth 20
  $bytes = [Text.Encoding]::UTF8.GetBytes($json + "`n")
  if ($bytes.Length -gt $MaximumBytes) {
    throw "JSON output exceeds the $MaximumBytes byte limit: $($bytes.Length)."
  }
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $temporaryPath = Join-Path $parent (".$([IO.Path]::GetFileName($Path)).$([Guid]::NewGuid().ToString('N')).tmp")
  try {
    [IO.File]::WriteAllBytes($temporaryPath, $bytes)
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
  }
  finally {
    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
  }
}

function Stop-ProcessTree([Diagnostics.Process]$Process) {
  if ($Process.HasExited) {
    return
  }
  $taskkill = Join-Path $env:SystemRoot "System32\taskkill.exe"
  & $taskkill /PID $Process.Id /T /F 2>$null | Out-Null
  try { $Process.WaitForExit(5000) | Out-Null } catch { }
}

function Invoke-BoundedProcess(
  [string]$FilePath,
  [string[]]$Arguments,
  [hashtable]$Environment,
  [string]$OutputPath,
  [string]$ErrorPath,
  [int]$TimeoutSeconds,
  [DateTime]$GlobalDeadline,
  [string]$Context
) {
  $remainingMilliseconds = [int][Math]::Floor(($GlobalDeadline - [DateTime]::UtcNow).TotalMilliseconds)
  if ($remainingMilliseconds -le 0) {
    throw "Global descendant-WC activation probe deadline expired before $Context."
  }
  $timeoutMilliseconds = [Math]::Min($TimeoutSeconds * 1000, $remainingMilliseconds)
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FilePath
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  foreach ($argument in $Arguments) {
    [void]$startInfo.ArgumentList.Add($argument)
  }
  foreach ($entry in $Environment.GetEnumerator()) {
    $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
  }

  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo

  try {
    if (-not $process.Start()) {
      throw "Failed to start $Context."
    }
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $outputTooLarge = $false
    while (-not $process.HasExited -and $stopwatch.ElapsedMilliseconds -lt $timeoutMilliseconds -and -not $outputTooLarge) {
      $outputLength = if (Test-Path -LiteralPath $OutputPath -PathType Leaf) { (Get-Item -LiteralPath $OutputPath).Length } else { 0 }
      $errorLength = if (Test-Path -LiteralPath $ErrorPath -PathType Leaf) { (Get-Item -LiteralPath $ErrorPath).Length } else { 0 }
      $outputTooLarge = ($outputLength + $errorLength) -gt $maximumOutputBytes
      Start-Sleep -Milliseconds 50
    }
    if ($outputTooLarge) {
      Stop-ProcessTree $process
      throw "$Context exceeded the $maximumOutputBytes byte output limit."
    }
    if (-not $process.HasExited) {
      Stop-ProcessTree $process
      throw "$Context timed out after $([Math]::Round($timeoutMilliseconds / 1000, 1)) seconds."
    }
    $process.WaitForExit()
    $outputLength = if (Test-Path -LiteralPath $OutputPath -PathType Leaf) { (Get-Item -LiteralPath $OutputPath).Length } else { 0 }
    $errorLength = if (Test-Path -LiteralPath $ErrorPath -PathType Leaf) { (Get-Item -LiteralPath $ErrorPath).Length } else { 0 }
    if (($outputLength + $errorLength) -gt $maximumOutputBytes) {
      throw "$Context exceeded the $maximumOutputBytes byte output limit."
    }
    $stdout = if (Test-Path -LiteralPath $OutputPath -PathType Leaf) { Get-Content -Raw -LiteralPath $OutputPath } else { "" }
    $stderr = if (Test-Path -LiteralPath $ErrorPath -PathType Leaf) { Get-Content -Raw -LiteralPath $ErrorPath } else { "" }
    return [pscustomobject]@{
      exitCode = $process.ExitCode
      stdout = $stdout
      stderr = $stderr
    }
  }
  finally {
    if (-not $process.HasExited) {
      Stop-ProcessTree $process
    }
    $process.Dispose()
  }
}

function Invoke-CodeCli(
  [string]$CliPath,
  [string[]]$Arguments,
  [hashtable]$Environment,
  [int]$TimeoutSeconds,
  [DateTime]$GlobalDeadline,
  [string]$Context
) {
  $pwsh = @((Get-Command pwsh -CommandType Application -ErrorAction Stop))[0].Source
  $wrapperPath = Join-Path $script:resolvedWorkRoot "invoke-code-cli.ps1"
  $argumentPath = Join-Path $script:resolvedWorkRoot ("arguments-$([Guid]::NewGuid().ToString('N')).json")
  $outputPath = Join-Path $script:resolvedWorkRoot ("stdout-$([Guid]::NewGuid().ToString('N')).txt")
  $errorPath = Join-Path $script:resolvedWorkRoot ("stderr-$([Guid]::NewGuid().ToString('N')).txt")
  Write-AtomicJson -Value $Arguments -Path $argumentPath -MaximumBytes 32768
  try {
    return Invoke-BoundedProcess -FilePath $pwsh -Arguments @(
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", $wrapperPath,
      "-CodeCliPath", $CliPath,
      "-ArgumentPath", $argumentPath,
      "-OutputPath", $outputPath,
      "-ErrorPath", $errorPath
    ) -Environment $Environment -OutputPath $outputPath -ErrorPath $errorPath -TimeoutSeconds $TimeoutSeconds -GlobalDeadline $GlobalDeadline -Context $Context
  }
  finally {
    Remove-Item -LiteralPath $argumentPath, $outputPath, $errorPath -Force -ErrorAction SilentlyContinue
  }
}

function Get-ExpectedCase([string]$FixtureId) {
  $exactId = [string]$probes[0].id
  switch ($FixtureId) {
    "wc-root" {
      return [ordered]@{
        fixture = "wc-root"
        active = @($exactId)
        markers = @($exactId)
        findFiles = [ordered]@{
          defaultWcDb = @()
          noExcludeWcDb = @(".svn/wc.db")
          defaultSvnDirectory = @()
          noExcludeSvnDirectory = @()
        }
      }
    }
    "parent-ws" {
      return [ordered]@{
        fixture = "parent-ws"
        active = @()
        markers = @()
        findFiles = [ordered]@{
          defaultWcDb = @()
          noExcludeWcDb = @("child/.svn/wc.db")
          defaultSvnDirectory = @()
          noExcludeSvnDirectory = @()
        }
      }
    }
    "no-svn" {
      return [ordered]@{
        fixture = "no-svn"
        active = @()
        markers = @()
        findFiles = [ordered]@{
          defaultWcDb = @()
          noExcludeWcDb = @()
          defaultSvnDirectory = @()
          noExcludeSvnDirectory = @()
        }
      }
    }
    default { throw "Unknown fixture '$FixtureId'." }
  }
}

function Assert-InstalledProbes([object]$Actual, [string]$Context) {
  $installedProbes = @($Actual)
  Assert-Equal $probes.Count $installedProbes.Count "$Context count"
  for ($index = 0; $index -lt $probes.Count; $index++) {
    $expected = Get-ExpectedProbeEvidence $probes[$index]
    Assert-Equal $expected.id (Get-ObjectProperty $installedProbes[$index] "id" "$Context[$index]") "$Context[$index].id"
    Assert-Equal "extensions-dir" (Get-ObjectProperty $installedProbes[$index] "source" "$Context[$index]") "$Context[$index].source"
    Assert-Equal $expected.definitionSha256 (Get-ObjectProperty $installedProbes[$index] "definitionSha256" "$Context[$index]") "$Context[$index].definitionSha256"
    Assert-Equal $expected.extensionJsSha256 (Get-ObjectProperty $installedProbes[$index] "extensionJsSha256" "$Context[$index]") "$Context[$index].extensionJsSha256"
  }
}

function Assert-Case([object]$Case, [string]$Context) {
  $fixtureId = [string](Get-ObjectProperty $Case "fixture" $Context)
  $expected = Get-ExpectedCase $fixtureId
  Assert-StringArray (Get-ObjectProperty $Case "active" $Context) @($expected.active) "$Context.active"
  Assert-StringArray (Get-ObjectProperty $Case "markers" $Context) @($expected.markers) "$Context.markers"
  Assert-InstalledProbes (Get-ObjectProperty $Case "installedProbes" $Context) "$Context.installedProbes"
  $findFiles = Get-ObjectProperty $Case "findFiles" $Context
  foreach ($name in @("defaultWcDb", "noExcludeWcDb", "defaultSvnDirectory", "noExcludeSvnDirectory")) {
    Assert-StringArray (Get-ObjectProperty $findFiles $name "$Context.findFiles") @($expected.findFiles[$name]) "$Context.findFiles.$name"
  }
}

function Assert-Evidence([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Evidence file does not exist: '$Path'."
  }
  $file = Get-Item -LiteralPath $Path
  if ($file.Length -gt $maximumEvidenceBytes) {
    throw "Evidence exceeds the $maximumEvidenceBytes byte limit: $($file.Length)."
  }
  $evidence = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
  Assert-Equal $schema (Get-ObjectProperty $evidence "schema" "evidence") "evidence.schema"
  Assert-Equal "False" ([string](Get-ObjectProperty $evidence "productClaim" "evidence")) "evidence.productClaim"
  Assert-Equal "installed-vsix-extension-host" (Get-ObjectProperty $evidence "source" "evidence") "evidence.source"
  [DateTimeOffset]::Parse([string](Get-ObjectProperty $evidence "generatedAt" "evidence"), [Globalization.CultureInfo]::InvariantCulture) | Out-Null

  $environment = Get-ObjectProperty $evidence "environment" "evidence"
  Assert-Equal "win32" (Get-ObjectProperty $environment "platform" "evidence.environment") "evidence.environment.platform"
  Assert-Equal $expectedArchitecture (Get-ObjectProperty $environment "architecture" "evidence.environment") "evidence.environment.architecture"
  Assert-Equal $expectedVersion (Get-ObjectProperty $environment "vscodeVersion" "evidence.environment") "evidence.environment.vscodeVersion"
  Assert-Equal $expectedCommit (Get-ObjectProperty $environment "vscodeCommit" "evidence.environment") "evidence.environment.vscodeCommit"
  Assert-Equal $expectedArchitecture (Get-ObjectProperty $environment "vscodeArchitecture" "evidence.environment") "evidence.environment.vscodeArchitecture"

  $evidenceProbes = @(Get-ObjectProperty $evidence "probes" "evidence")
  Assert-Equal $probes.Count $evidenceProbes.Count "evidence.probes count"
  for ($index = 0; $index -lt $probes.Count; $index++) {
    $expectedProbe = Get-ExpectedProbeEvidence $probes[$index]
    Assert-Equal $expectedProbe.id (Get-ObjectProperty $evidenceProbes[$index] "id" "evidence.probes[$index]") "evidence.probes[$index].id"
    Assert-Equal $expectedProbe.activationEvent (Get-ObjectProperty $evidenceProbes[$index] "activationEvent" "evidence.probes[$index]") "evidence.probes[$index].activationEvent"
    Assert-Equal $expectedProbe.definitionSha256 (Get-ObjectProperty $evidenceProbes[$index] "definitionSha256" "evidence.probes[$index]") "evidence.probes[$index].definitionSha256"
    Assert-Equal $expectedProbe.extensionJsSha256 (Get-ObjectProperty $evidenceProbes[$index] "extensionJsSha256" "evidence.probes[$index]") "evidence.probes[$index].extensionJsSha256"
  }

  $fixtures = @(Get-ObjectProperty $evidence "fixtures" "evidence")
  Assert-Equal $fixtureDefinitions.Count $fixtures.Count "evidence.fixtures count"
  for ($index = 0; $index -lt $fixtureDefinitions.Count; $index++) {
    Assert-Equal $fixtureDefinitions[$index].id (Get-ObjectProperty $fixtures[$index] "id" "evidence.fixtures[$index]") "evidence.fixtures[$index].id"
    Assert-Equal $fixtureDefinitions[$index].sentinel (Get-ObjectProperty $fixtures[$index] "sentinel" "evidence.fixtures[$index]") "evidence.fixtures[$index].sentinel"
    $sha256 = [string](Get-ObjectProperty $fixtures[$index] "treeSha256" "evidence.fixtures[$index]")
    Assert-Equal (Get-ExpectedFixtureHash ([string]$fixtureDefinitions[$index].sentinel)) $sha256 "evidence.fixtures[$index].treeSha256"
  }

  Assert-StringArray (Get-ObjectProperty $evidence "nonClaims" "evidence") $requiredNonClaims "evidence.nonClaims"
  $runs = @(Get-ObjectProperty $evidence "runs" "evidence")
  Assert-Equal 3 $runs.Count "evidence.runs count"
  $firstCanonical = $null
  for ($runIndex = 0; $runIndex -lt $runs.Count; $runIndex++) {
    Assert-Equal ($runIndex + 1) (Get-ObjectProperty $runs[$runIndex] "run" "evidence.runs[$runIndex]") "evidence.runs[$runIndex].run"
    $cases = @(Get-ObjectProperty $runs[$runIndex] "cases" "evidence.runs[$runIndex]")
    Assert-Equal $fixtureDefinitions.Count $cases.Count "evidence.runs[$runIndex].cases count"
    for ($caseIndex = 0; $caseIndex -lt $cases.Count; $caseIndex++) {
      Assert-Equal $fixtureDefinitions[$caseIndex].id (Get-ObjectProperty $cases[$caseIndex] "fixture" "evidence.runs[$runIndex].cases[$caseIndex]") "evidence.runs[$runIndex].cases[$caseIndex].fixture"
      Assert-Case $cases[$caseIndex] "evidence.runs[$runIndex].cases[$caseIndex]"
    }
    $canonical = $cases | ConvertTo-Json -Depth 10 -Compress
    if ($null -eq $firstCanonical) { $firstCanonical = $canonical }
    else { Assert-Equal $firstCanonical $canonical "evidence run canonical result" }
  }
  return $evidence
}

$resolvedEvidencePath = Resolve-RepoPath $EvidencePath
Assert-ContainedPath $resolvedEvidencePath $evidenceRoot "EvidencePath"

if ($Mode -eq "VerifyEvidence") {
  Assert-Evidence $resolvedEvidencePath | Out-Null
  Write-Host "Descendant working-copy activation evidence verified: $resolvedEvidencePath"
  exit 0
}

if ($env:OS -ne "Windows_NT" -or [Environment]::Is64BitOperatingSystem -ne $true) {
  throw "Run mode requires 64-bit Windows."
}
if ([string]::IsNullOrWhiteSpace($CodeCliPath)) {
  throw "CodeCliPath is required in Run mode."
}
if ([string]::IsNullOrWhiteSpace($WorkRoot)) {
  throw "WorkRoot is required in Run mode."
}
$resolvedCodeCliPath = [IO.Path]::GetFullPath($CodeCliPath)
if (-not [IO.Path]::IsPathRooted($CodeCliPath) -or -not (Test-Path -LiteralPath $resolvedCodeCliPath -PathType Leaf)) {
  throw "CodeCliPath must be an existing absolute file: '$CodeCliPath'."
}
$script:resolvedWorkRoot = Resolve-RepoPath $WorkRoot
Assert-ContainedPath $script:resolvedWorkRoot $workRootBoundary "WorkRoot"

if (Test-Path -LiteralPath $script:resolvedWorkRoot) {
  Remove-Item -LiteralPath $script:resolvedWorkRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $script:resolvedWorkRoot | Out-Null

$wrapper = @'
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$CodeCliPath,
  [Parameter(Mandatory = $true)][string]$ArgumentPath,
  [Parameter(Mandatory = $true)][string]$OutputPath,
  [Parameter(Mandatory = $true)][string]$ErrorPath
)
$ErrorActionPreference = "Stop"
$arguments = @(Get-Content -Raw -LiteralPath $ArgumentPath | ConvertFrom-Json | ForEach-Object { [string]$_ })
try {
  & $CodeCliPath @arguments 1> $OutputPath 2> $ErrorPath
  exit $LASTEXITCODE
}
catch {
  [IO.File]::AppendAllText($ErrorPath, $_.Exception.ToString())
  exit 1
}
'@
[IO.File]::WriteAllText((Join-Path $script:resolvedWorkRoot "invoke-code-cli.ps1"), $wrapper, [Text.UTF8Encoding]::new($false))

$globalDeadline = [DateTime]::UtcNow.AddMinutes(6)
$versionResult = Invoke-CodeCli -CliPath $resolvedCodeCliPath -Arguments @("--version") -Environment @{} -TimeoutSeconds 15 -GlobalDeadline $globalDeadline -Context "VS Code version probe"
if ($versionResult.exitCode -ne 0) {
  throw "VS Code version probe failed: $($versionResult.stderr.Trim())"
}
$versionLines = @($versionResult.stdout -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($versionLines.Count -ne 3) {
  throw "VS Code version probe expected three lines, got $($versionLines.Count): $($versionResult.stdout.Trim())"
}
Assert-Equal $expectedVersion $versionLines[0].Trim() "VS Code version"
Assert-Equal $expectedCommit $versionLines[1].Trim() "VS Code commit"
Assert-Equal $expectedArchitecture $versionLines[2].Trim() "VS Code architecture"

$contentTypes = @'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="json" ContentType="application/json" />
  <Default Extension="js" ContentType="application/javascript" />
  <Default Extension="vsixmanifest" ContentType="text/xml" />
</Types>
'@

$extensionsRoot = Join-Path $script:resolvedWorkRoot "extensions"
$packagesRoot = Join-Path $script:resolvedWorkRoot "packages"
$installUserDataRoot = Join-Path $script:resolvedWorkRoot "install-user-data"
New-Item -ItemType Directory -Force -Path $extensionsRoot, $packagesRoot, $installUserDataRoot | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$probeEvidence = @()
foreach ($probe in $probes) {
  $name = ([string]$probe.id).Split(".")[-1]
  $packageRoot = Join-Path $packagesRoot $name
  $extensionRoot = Join-Path $packageRoot "extension"
  New-Item -ItemType Directory -Force -Path $extensionRoot | Out-Null
  $package = Get-ProbePackage $probe
  Write-AtomicJson $package (Join-Path $extensionRoot "package.json") 16384
  $source = Get-ProbeSource $probe
  [IO.File]::WriteAllText((Join-Path $extensionRoot "extension.js"), $source, [Text.UTF8Encoding]::new($false))
  $expectedProbeEvidence = Get-ExpectedProbeEvidence $probe
  Assert-Equal $expectedProbeEvidence.extensionJsSha256 (Get-Sha256 (Join-Path $extensionRoot "extension.js")) "generated probe extension.js hash"
  [IO.File]::WriteAllText((Join-Path $packageRoot "[Content_Types].xml"), $contentTypes, [Text.UTF8Encoding]::new($false))
  $manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Language="en-US" Id="$name" Version="0.0.1" Publisher="subversionr-research" />
    <DisplayName>SubversionR descendant WC research probe $name</DisplayName>
    <Description xml:space="preserve">Isolated activation-event research probe.</Description>
    <Tags>research</Tags>
    <Categories>Other</Categories>
    <GalleryFlags>Public</GalleryFlags>
    <Properties><Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.85.0" /></Properties>
  </Metadata>
  <Installation><InstallationTarget Id="Microsoft.VisualStudio.Code" /></Installation>
  <Dependencies />
  <Assets><Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true" /></Assets>
</PackageManifest>
"@
  [IO.File]::WriteAllText((Join-Path $packageRoot "extension.vsixmanifest"), $manifest, [Text.UTF8Encoding]::new($false))
  $vsixPath = Join-Path $packagesRoot "$name.vsix"
  [IO.Compression.ZipFile]::CreateFromDirectory($packageRoot, $vsixPath, [IO.Compression.CompressionLevel]::Optimal, $false)
  $installResult = Invoke-CodeCli -CliPath $resolvedCodeCliPath -Arguments @(
    "--user-data-dir", $installUserDataRoot,
    "--extensions-dir", $extensionsRoot,
    "--install-extension", $vsixPath,
    "--force"
  ) -Environment @{} -TimeoutSeconds 15 -GlobalDeadline $globalDeadline -Context "installing probe $($probe.id)"
  if ($installResult.exitCode -ne 0) {
    throw "Probe installation failed for $($probe.id): $($installResult.stderr.Trim()) $($installResult.stdout.Trim())"
  }
  $probeEvidence += $expectedProbeEvidence
}

$controllerRoot = Join-Path $script:resolvedWorkRoot "controller"
New-Item -ItemType Directory -Force -Path $controllerRoot | Out-Null
$controllerPackage = [ordered]@{
  name = "descendant-wc-controller"
  displayName = "SubversionR descendant WC research controller"
  publisher = "subversionr-research"
  version = "0.0.1"
  engines = [ordered]@{ vscode = "^1.85.0" }
  main = "./extension.js"
  activationEvents = @("*")
}
Write-AtomicJson $controllerPackage (Join-Path $controllerRoot "package.json") 16384
[IO.File]::WriteAllText((Join-Path $controllerRoot "extension.js"), "exports.activate = function () {};`n", [Text.UTF8Encoding]::new($false))
$controllerTests = @'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const vscode = require('vscode');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const relative = uri => vscode.workspace.asRelativePath(uri, false).replace(/\\/g, '/');
const sorted = values => [...values].sort((a, b) => a.localeCompare(b));
async function run() {
  const outputPath = process.env.SUBVERSIONR_ACTIVATION_SESSION_OUTPUT;
  const markerRoot = process.env.SUBVERSIONR_ACTIVATION_MARKER_ROOT;
  const extensionsRoot = process.env.SUBVERSIONR_ACTIVATION_EXTENSIONS_ROOT;
  const fixture = process.env.SUBVERSIONR_ACTIVATION_FIXTURE_ID;
  const probeIds = JSON.parse(process.env.SUBVERSIONR_ACTIVATION_PROBE_IDS);
  if (!outputPath || !markerRoot || !extensionsRoot || !fixture || !Array.isArray(probeIds)) throw new Error('research controller environment is incomplete');
  await delay(8500);
  const active = [];
  const markers = [];
  const installedProbes = [];
  const installedRootPrefix = `${path.resolve(extensionsRoot)}${path.sep}`.toLowerCase();
  const sha256 = filePath => crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
  for (const id of probeIds) {
    const extension = vscode.extensions.getExtension(id);
    if (!extension) throw new Error(`installed research probe is missing from the Extension Host: ${id}`);
    const extensionPath = path.resolve(extension.extensionPath);
    if (!extensionPath.toLowerCase().startsWith(installedRootPrefix)) throw new Error(`research probe did not load from --extensions-dir: ${id}`);
    const manifest = JSON.parse(fs.readFileSync(path.join(extensionPath, 'package.json'), 'utf8'));
    if (`${manifest.publisher}.${manifest.name}` !== id || manifest.version !== '0.0.1' || manifest.main !== './extension.js') {
      throw new Error(`installed research probe manifest identity is invalid: ${id}`);
    }
    if (!Array.isArray(manifest.activationEvents) || manifest.activationEvents.length !== 1) {
      throw new Error(`installed research probe must have one activation event: ${id}`);
    }
    const extensionJsSha256 = sha256(path.join(extensionPath, 'extension.js'));
    const definitionMaterial = [id, manifest.publisher, manifest.name, manifest.version, manifest.main, manifest.activationEvents[0], extensionJsSha256].join('\n');
    installedProbes.push({
      id,
      source: 'extensions-dir',
      definitionSha256: crypto.createHash('sha256').update(definitionMaterial, 'utf8').digest('hex'),
      extensionJsSha256
    });
    if (extension.isActive) active.push(id);
    if (fs.existsSync(path.join(markerRoot, `${id}.json`))) markers.push(id);
  }
  const find = async (include, exclude) => sorted((await vscode.workspace.findFiles(include, exclude, 10)).map(relative));
  const report = {
    fixture,
    active: sorted(active),
    markers: sorted(markers),
    installedProbes,
    findFiles: {
      defaultWcDb: await find('**/.svn/wc.db', undefined),
      noExcludeWcDb: await find('**/.svn/wc.db', null),
      defaultSvnDirectory: await find('**/.svn', undefined),
      noExcludeSvnDirectory: await find('**/.svn', null)
    }
  };
  const temporaryPath = `${outputPath}.${process.pid}.tmp`;
  fs.writeFileSync(temporaryPath, `${JSON.stringify(report, null, 2)}\n`, { encoding: 'utf8', flag: 'wx' });
  fs.renameSync(temporaryPath, outputPath);
}
exports.run = run;
'@
[IO.File]::WriteAllText((Join-Path $controllerRoot "tests.js"), $controllerTests, [Text.UTF8Encoding]::new($false))

$fixturesRoot = Join-Path $script:resolvedWorkRoot "fixtures"
$fixtureEvidence = @()
foreach ($fixture in $fixtureDefinitions) {
  $fixturePath = Join-Path $fixturesRoot ([string]$fixture.id)
  $sentinelPath = Join-Path $fixturePath (([string]$fixture.sentinel).Replace("/", [IO.Path]::DirectorySeparatorChar))
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sentinelPath) | Out-Null
  [IO.File]::WriteAllText($sentinelPath, "subversionr descendant working-copy activation research fixture`n", [Text.UTF8Encoding]::new($false))
  $fixtureEvidence += [ordered]@{
    id = [string]$fixture.id
    sentinel = [string]$fixture.sentinel
    treeSha256 = Get-FixtureHash $fixturePath ([string]$fixture.sentinel)
  }
}

$runs = @()
$probeIdsJson = @($probes | ForEach-Object { [string]$_.id }) | ConvertTo-Json -Compress
for ($runNumber = 1; $runNumber -le 3; $runNumber++) {
  $cases = @()
  foreach ($fixture in $fixtureDefinitions) {
    $fixtureId = [string]$fixture.id
    $fixturePath = Join-Path $fixturesRoot $fixtureId
    $sessionRoot = Join-Path $script:resolvedWorkRoot "sessions\run-$runNumber\$fixtureId"
    $userDataRoot = Join-Path $sessionRoot "user-data"
    $markerRoot = Join-Path $sessionRoot "markers"
    $sessionOutput = Join-Path $sessionRoot "result.json"
    New-Item -ItemType Directory -Force -Path $userDataRoot, $markerRoot | Out-Null
    $sessionEnvironment = @{
      SUBVERSIONR_ACTIVATION_SESSION_OUTPUT = $sessionOutput
      SUBVERSIONR_ACTIVATION_MARKER_ROOT = $markerRoot
      SUBVERSIONR_ACTIVATION_EXTENSIONS_ROOT = $extensionsRoot
      SUBVERSIONR_ACTIVATION_FIXTURE_ID = $fixtureId
      SUBVERSIONR_ACTIVATION_PROBE_IDS = $probeIdsJson
    }
    $sessionResult = Invoke-CodeCli -CliPath $resolvedCodeCliPath -Arguments @(
      "--user-data-dir", $userDataRoot,
      "--extensions-dir", $extensionsRoot,
      "--disable-workspace-trust",
      "--skip-welcome",
      "--skip-release-notes",
      "--disable-telemetry",
      "--disable-gpu",
      "--new-window",
      "--extensionDevelopmentPath=$controllerRoot",
      "--extensionTestsPath=$(Join-Path $controllerRoot 'tests.js')",
      "--wait",
      $fixturePath
    ) -Environment $sessionEnvironment -TimeoutSeconds 30 -GlobalDeadline $globalDeadline -Context "run $runNumber fixture $fixtureId"
    if ($sessionResult.exitCode -ne 0) {
      throw "VS Code Extension Host failed for run $runNumber fixture $fixtureId`: $($sessionResult.stderr.Trim()) $($sessionResult.stdout.Trim())"
    }
    $resultDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath $sessionOutput -PathType Leaf) -and [DateTime]::UtcNow -lt $resultDeadline -and [DateTime]::UtcNow -lt $globalDeadline) {
      Start-Sleep -Milliseconds 50
    }
    if (-not (Test-Path -LiteralPath $sessionOutput -PathType Leaf)) {
      throw "VS Code Extension Host produced no controller result for run $runNumber fixture $fixtureId."
    }
    if ((Get-Item -LiteralPath $sessionOutput).Length -gt 16384) {
      throw "VS Code Extension Host controller result exceeded 16384 bytes for run $runNumber fixture $fixtureId."
    }
    $case = Get-Content -Raw -LiteralPath $sessionOutput | ConvertFrom-Json
    Assert-Case $case "run $runNumber fixture $fixtureId"
    $cases += [ordered]@{
      fixture = $fixtureId
      active = @((Get-ObjectProperty $case "active" "session result") | ForEach-Object { [string]$_ })
      markers = @((Get-ObjectProperty $case "markers" "session result") | ForEach-Object { [string]$_ })
      installedProbes = @((Get-ObjectProperty $case "installedProbes" "session result") | ForEach-Object {
        [ordered]@{
          id = [string](Get-ObjectProperty $_ "id" "session result.installedProbes")
          source = [string](Get-ObjectProperty $_ "source" "session result.installedProbes")
          definitionSha256 = [string](Get-ObjectProperty $_ "definitionSha256" "session result.installedProbes")
          extensionJsSha256 = [string](Get-ObjectProperty $_ "extensionJsSha256" "session result.installedProbes")
        }
      })
      findFiles = [ordered]@{
        defaultWcDb = @((Get-ObjectProperty $case.findFiles "defaultWcDb" "session result.findFiles") | ForEach-Object { [string]$_ })
        noExcludeWcDb = @((Get-ObjectProperty $case.findFiles "noExcludeWcDb" "session result.findFiles") | ForEach-Object { [string]$_ })
        defaultSvnDirectory = @((Get-ObjectProperty $case.findFiles "defaultSvnDirectory" "session result.findFiles") | ForEach-Object { [string]$_ })
        noExcludeSvnDirectory = @((Get-ObjectProperty $case.findFiles "noExcludeSvnDirectory" "session result.findFiles") | ForEach-Object { [string]$_ })
      }
    }
  }
  $runs += [ordered]@{ run = $runNumber; cases = $cases }
}

$evidence = [ordered]@{
  schema = $schema
  generatedAt = [DateTimeOffset]::UtcNow.ToString("O", [Globalization.CultureInfo]::InvariantCulture)
  productClaim = $false
  source = "installed-vsix-extension-host"
  environment = [ordered]@{
    platform = "win32"
    architecture = $expectedArchitecture
    vscodeVersion = $expectedVersion
    vscodeCommit = $expectedCommit
    vscodeArchitecture = $expectedArchitecture
  }
  probes = $probeEvidence
  fixtures = $fixtureEvidence
  runs = $runs
  nonClaims = $requiredNonClaims
}
Write-AtomicJson $evidence $resolvedEvidencePath $maximumEvidenceBytes
Assert-Evidence $resolvedEvidencePath | Out-Null
Write-Host "Descendant working-copy activation evidence generated and verified: $resolvedEvidencePath"

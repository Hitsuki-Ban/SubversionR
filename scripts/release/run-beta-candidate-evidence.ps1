[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("win32-x64")]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [string]$CodeCliPath,

  [Parameter(Mandatory = $true)]
  [string]$SvnToolsRoot,

  [Parameter(Mandatory = $true)]
  [string]$RendererCaptureDriverPath,

  [ValidateRange(1024, 65535)]
  [int]$RemoteDebuggingPort = 32145
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).ProviderPath

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw $Message
  }
}

function Resolve-RepoPath([string]$Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Test-IsPathWithin([string]$Path, [string]$Root) {
  $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  )
  $pathFull = [System.IO.Path]::GetFullPath($Path).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  )
  $rootPrefix = "$rootFull$([System.IO.Path]::DirectorySeparatorChar)"
  $pathFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
    $pathFull.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-ExplicitPath([string]$Path, [string]$Name) {
  Assert-True (-not [string]::IsNullOrWhiteSpace($Path)) "$Name is required."
  Assert-True (-not $Path.Contains("%")) "$Name must be an explicit path, not an unresolved environment placeholder."
  Assert-True (-not $Path.Contains("$")) "$Name must be an explicit path, not an unresolved environment placeholder."
}

function Assert-File([string]$Path, [string]$Name) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Name must be a file: $Path"
  }
  (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
}

function Assert-Directory([string]$Path, [string]$Name) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "$Name must be a directory: $Path"
  }
  (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
}

function Assert-CodeCliPath([string]$Path) {
  Assert-ExplicitPath $Path "CodeCliPath"
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

function Assert-RepoDirectory([string]$Path, [string]$Name, [string]$AllowedRoot, [string]$Description) {
  Assert-ExplicitPath $Path $Name
  $resolved = Resolve-RepoPath $Path
  if (-not (Test-IsPathWithin -Path $resolved -Root $AllowedRoot)) {
    throw "$Name must resolve inside $Description`: $Path"
  }
  Assert-Directory $resolved $Name
}

function Assert-RepoFile([string]$Path, [string]$Name, [string]$AllowedRoot, [string]$Description) {
  Assert-ExplicitPath $Path $Name
  $resolved = Resolve-RepoPath $Path
  if (-not (Test-IsPathWithin -Path $resolved -Root $AllowedRoot)) {
    throw "$Name must resolve inside $Description`: $Path"
  }
  Assert-File $resolved $Name
}

function Invoke-External([string]$Description, [string]$FilePath, [string[]]$Arguments) {
  Write-Host "==> $Description"
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$Description failed with exit code $LASTEXITCODE."
  }
}

function Invoke-PnpmScript([string]$Description, [string]$ScriptName) {
  Invoke-External -Description $Description -FilePath "pnpm" -Arguments @($ScriptName)
}

function Invoke-ReleaseScript([string]$Description, [string]$ScriptName, [string[]]$Arguments) {
  $scriptPath = Assert-File (Join-Path $PSScriptRoot $ScriptName) $ScriptName
  Invoke-External `
    -Description $Description `
    -FilePath "pwsh" `
    -Arguments (@("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath) + $Arguments)
}

$codeCliResolved = Assert-CodeCliPath $CodeCliPath
$svnToolsResolved = Assert-RepoDirectory `
  -Path $SvnToolsRoot `
  -Name "SvnToolsRoot" `
  -AllowedRoot ([System.IO.Path]::GetFullPath((Join-Path $repoRoot ".cache\native\stage\subversion-win-x64\bin"))) `
  -Description ".cache/native/stage/subversion-win-x64/bin"
$rendererCaptureResolved = Assert-RepoFile `
  -Path $RendererCaptureDriverPath `
  -Name "RendererCaptureDriverPath" `
  -AllowedRoot ([System.IO.Path]::GetFullPath((Join-Path $repoRoot "scripts\release"))) `
  -Description "scripts/release"

$vsixPath = "target/vsix/subversionr-win32-x64-0.2.1.vsix"
$packageRoot = "target/vscode-package/subversionr-$Target"
$releaseEvidenceRoot = "target/release-evidence"
$artifactBundleManifestOutputPath = Resolve-RepoPath "$releaseEvidenceRoot/subversionr-beta-artifact-bundle-manifest-$Target.json"
$candidateConsistencyOutputPath = Resolve-RepoPath "$releaseEvidenceRoot/subversionr-beta-candidate-consistency-$Target.json"
if (Test-Path -LiteralPath $artifactBundleManifestOutputPath) {
  Remove-Item -LiteralPath $artifactBundleManifestOutputPath -Force
}
if (Test-Path -LiteralPath $candidateConsistencyOutputPath) {
  Remove-Item -LiteralPath $candidateConsistencyOutputPath -Force
}

Invoke-PnpmScript "Run Beta candidate evidence script tests" "release:test-beta-candidate-evidence-scripts"
Invoke-PnpmScript "Generate source SBOM evidence" "release:generate-source-sbom"
Invoke-PnpmScript "Generate third-party notice evidence" "release:generate-third-party-notice"
Invoke-PnpmScript "Verify source SBOM and third-party notice evidence" "release:verify-evidence"
Invoke-PnpmScript "Stage VS Code $Target package layout" "release:stage-vscode:$Target"
Invoke-PnpmScript "Verify VS Code $Target package layout" "release:verify-vscode:$Target"
Invoke-PnpmScript "Package VS Code $Target VSIX" "release:package-vsix:$Target"
Invoke-PnpmScript "Generate native artifact map preflight" "release:generate-native-artifact-map:$Target"
Invoke-PnpmScript "Verify native artifact map preflight" "release:verify-native-artifact-map:$Target"
Invoke-PnpmScript "Generate release provenance preflight" "release:generate-provenance:$Target"
Invoke-PnpmScript "Verify release provenance preflight" "release:verify-provenance:$Target"
Invoke-PnpmScript "Generate publication gaps preflight" "release:generate-publication-gaps:$Target"
Invoke-PnpmScript "Verify publication gaps preflight" "release:verify-publication-gaps:$Target"

Invoke-ReleaseScript `
  -Description "Test VS Code CLI VSIX install" `
  -ScriptName "test-vscode-cli-install-vsix.ps1" `
  -Arguments @(
    "-Target", $Target,
    "-VsixPath", $vsixPath,
    "-CodeCliPath", $codeCliResolved,
    "-FixtureRoot", "$releaseEvidenceRoot/vsix-cli-install/$Target",
    "-EvidencePath", "$releaseEvidenceRoot/subversionr-vsix-cli-install-$Target.json"
  )

Invoke-ReleaseScript `
  -Description "Test installed VSIX Extension Host version report" `
  -ScriptName "test-vscode-installed-extension-host.ps1" `
  -Arguments @(
    "-Target", $Target,
    "-VsixPath", $vsixPath,
    "-CodeCliPath", $codeCliResolved,
    "-FixtureRoot", "$releaseEvidenceRoot/installed-extension-host/$Target",
    "-EvidencePath", "$releaseEvidenceRoot/subversionr-installed-extension-host-$Target.json"
  )

Invoke-ReleaseScript `
  -Description "Test installed VSIX core workflow E2E" `
  -ScriptName "test-vscode-installed-core-workflow.ps1" `
  -Arguments @(
    "-Target", $Target,
    "-VsixPath", $vsixPath,
    "-CodeCliPath", $codeCliResolved,
    "-SvnToolsRoot", $svnToolsResolved,
    "-FixtureRoot", "$releaseEvidenceRoot/installed-core-workflow/$Target",
    "-EvidencePath", "$releaseEvidenceRoot/subversionr-installed-core-workflow-$Target.json"
  )

Invoke-ReleaseScript `
  -Description "Test installed VSIX Source Control surface" `
  -ScriptName "test-vscode-installed-source-control-surface.ps1" `
  -Arguments @(
    "-Target", $Target,
    "-VsixPath", $vsixPath,
    "-CodeCliPath", $codeCliResolved,
    "-SvnToolsRoot", $svnToolsResolved,
    "-FixtureRoot", "$releaseEvidenceRoot/installed-source-control-surface/$Target",
    "-EvidencePath", "$releaseEvidenceRoot/subversionr-installed-source-control-surface-$Target.json"
  )

Invoke-ReleaseScript `
  -Description "Test installed VSIX Source Control UI E2E" `
  -ScriptName "test-vscode-installed-source-control-ui-e2e.ps1" `
  -Arguments @(
    "-Target", $Target,
    "-VsixPath", $vsixPath,
    "-CodeCliPath", $codeCliResolved,
    "-SvnToolsRoot", $svnToolsResolved,
    "-RendererCaptureDriverPath", $rendererCaptureResolved,
    "-FixtureRoot", "$releaseEvidenceRoot/installed-source-control-ui-e2e/$Target",
    "-EvidencePath", "$releaseEvidenceRoot/subversionr-installed-source-control-ui-e2e-$Target.json",
    "-RemoteDebuggingPort", ([string]$RemoteDebuggingPort)
  )

Invoke-ReleaseScript `
  -Description "Test VS Code install upgrade rollback fixture" `
  -ScriptName "test-vscode-install-rollback-fixture.ps1" `
  -Arguments @(
    "-Target", $Target,
    "-CurrentPackageRoot", $packageRoot,
    "-SyntheticPreviousVersion", "0.0.0-m7f.fixture",
    "-FixtureRoot", "$releaseEvidenceRoot/install-rollback-fixture/$Target",
    "-EvidencePath", "$releaseEvidenceRoot/subversionr-install-rollback-fixture-$Target.json"
  )

Invoke-PnpmScript "Test state-engine Beta performance" "release:test-state-engine-beta-performance:$Target"
Invoke-PnpmScript "Generate Beta artifact bundle manifest" "release:generate-beta-artifact-bundle-manifest:$Target"
Invoke-PnpmScript "Verify Beta candidate evidence consistency" "release:verify-beta-candidate:$Target"

Write-Host "Prepared SubversionR Beta candidate evidence for $Target."

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$probePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-authz-denied.ps1"
$tempRoot = Join-Path $repoRoot "target\tests\m8-i6-installed-authz-denied\$([Guid]::NewGuid().ToString('N'))"

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw $Message
  }
}

function Assert-ScriptThrowsContaining([scriptblock]$Action, [string]$ExpectedText, [string]$Message) {
  $thrown = $null
  try {
    & $Action
  }
  catch {
    $thrown = $_
  }
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

Assert-True (Test-Path -LiteralPath $probePath -PathType Leaf) "Installed authz-denied probe must exist."
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
  $probePath,
  [ref]$tokens,
  [ref]$parseErrors
)
Assert-True ($parseErrors.Count -eq 0) "Installed authz-denied probe must parse without PowerShell errors."

$parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
$expectedParameters = @(
  "VsixPath", "CodeCliPath", "FixtureRoot", "WorkingCopyPath", "RepositoryUrl",
  "OperationTimeoutMilliseconds", "ExpectedProductVersion", "DaemonPath", "BridgePath", "TimeoutSeconds"
)
Assert-True (($parameterNames -join ",") -ceq ($expectedParameters -join ",")) "Installed authz-denied probe must expose only the exact required parameters."

$source = Get-Content -Raw -LiteralPath $probePath
foreach ($required in @(
    'subversionr.diagnostics.installedSvnAnonymousAuthzDeniedReport',
    'SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_AUTHZ_DENIED_REPORT_TOKEN',
    'Get-Sha256 $installedDaemonPath',
    'Get-Sha256 $installedBridgePath',
    'Get-TemporaryRootCount',
    'Assert-EmptyCheckoutJournal',
    'Get-WorkingCopyContentSnapshot',
    'Assert-WorkingCopyPreserved',
    'Wait-CandidateProcessAbsent',
    'WorkingCopyPath must contain an existing working-copy database.',
    'The installed authz-denied read-only operation changed working-copy user content.'
  )) {
  Assert-True ($source.Contains($required)) "Installed authz-denied probe is missing the contract lock: $required"
}
foreach ($forbidden in @(
    'Get-WmiObject',
    'Register-WmiEvent',
    'workerDescendantsAfter = 0',
    'svn.exe',
    'Remove-Item -LiteralPath $WorkingCopyPath',
    'Remove-Item -LiteralPath $workingCopyResolved'
  )) {
  Assert-True (-not $source.Contains($forbidden)) "Installed authz-denied probe must not contain the forbidden fallback/destructive route: $forbidden"
}

$helperNames = @(
  "Get-Sha256",
  "Get-WorkingCopyContentSnapshot",
  "Assert-WorkingCopyPreserved"
)
$helperSources = foreach ($functionName in $helperNames) {
  $matches = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq $functionName
      }, $true))
  Assert-True ($matches.Count -eq 1) "Installed authz-denied probe must define exactly one $functionName helper."
  $matches[0].Extent.Text
}
Invoke-Expression ($helperSources -join "`n`n")

New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
try {
  $workingCopyRoot = Join-Path $tempRoot "working-copy"
  $metadataRoot = Join-Path $workingCopyRoot ".svn"
  New-Item -ItemType Directory -Force -Path $metadataRoot | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $metadataRoot "wc.db"), "controlled-wc-database", [System.Text.UTF8Encoding]::new($false))
  $sentinelPath = Join-Path $workingCopyRoot ".subversionr-authz-readonly-sentinel"
  [System.IO.File]::WriteAllText($sentinelPath, "controlled sentinel`n", [System.Text.UTF8Encoding]::new($false))
  $nestedRoot = Join-Path $workingCopyRoot "nested"
  New-Item -ItemType Directory -Path $nestedRoot | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $nestedRoot "payload.txt"), "controlled payload`n", [System.Text.UTF8Encoding]::new($false))

  $before = Get-WorkingCopyContentSnapshot $workingCopyRoot
  Assert-WorkingCopyPreserved $workingCopyRoot $before
  [System.IO.File]::AppendAllText($sentinelPath, "mutation", [System.Text.UTF8Encoding]::new($false))
  Assert-ScriptThrowsContaining {
    Assert-WorkingCopyPreserved $workingCopyRoot $before
  } "changed working-copy user content" "Installed authz-denied preservation must reject user-content mutation."
  [System.IO.File]::WriteAllText($sentinelPath, "controlled sentinel`n", [System.Text.UTF8Encoding]::new($false))
  Remove-Item -LiteralPath (Join-Path $metadataRoot "wc.db")
  Assert-ScriptThrowsContaining {
    Assert-WorkingCopyPreserved $workingCopyRoot $before
  } "database was removed" "Installed authz-denied preservation must reject missing working-copy metadata."

  $argumentRoot = Join-Path $tempRoot "arguments"
  New-Item -ItemType Directory -Path $argumentRoot | Out-Null
  $codePath = Join-Path $argumentRoot "code.cmd"
  $daemonPath = Join-Path $argumentRoot "subversionr-daemon.exe"
  $bridgePath = Join-Path $argumentRoot "subversionr_svn_bridge.dll"
  foreach ($path in @($codePath, $daemonPath, $bridgePath)) {
    [System.IO.File]::WriteAllText($path, "fixture", [System.Text.UTF8Encoding]::new($false))
  }
  $newHarnessRoot = Join-Path $argumentRoot "new-harness"
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probePath `
      -VsixPath "relative.vsix" `
      -CodeCliPath $codePath `
      -FixtureRoot $newHarnessRoot `
      -WorkingCopyPath $workingCopyRoot `
      -RepositoryUrl "svn://127.0.0.1:3690/repo/denied" `
      -OperationTimeoutMilliseconds 30000 `
      -ExpectedProductVersion "0.2.5" `
      -DaemonPath $daemonPath `
      -BridgePath $bridgePath `
      -TimeoutSeconds 180
  } "VsixPath must be an absolute path" "Installed authz-denied probe must fail before creating its harness for a relative VSIX path."
  Assert-True (-not (Test-Path -LiteralPath $newHarnessRoot)) "Installed authz-denied argument failure must not create the harness root."
  Assert-True ((Get-Content -Raw -LiteralPath $sentinelPath) -ceq "controlled sentinel`n") "Installed authz-denied argument failure must not change working-copy user content."
}
finally {
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}

Write-Host "M8 I6 installed authz-denied probe script tests passed."

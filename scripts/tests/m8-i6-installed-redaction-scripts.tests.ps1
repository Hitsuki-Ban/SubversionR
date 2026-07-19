$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$probePath = Join-Path $repoRoot "scripts\release\probe-m8-i6-installed-redaction.ps1"
$tempRoot = Join-Path $repoRoot "target\tests\m8-i6-installed-redaction\$([Guid]::NewGuid().ToString('N'))"

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

Assert-True (Test-Path -LiteralPath $probePath -PathType Leaf) "Installed redaction probe must exist."
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
  $probePath,
  [ref]$tokens,
  [ref]$parseErrors
)
Assert-True ($parseErrors.Count -eq 0) "Installed redaction probe must parse without PowerShell errors."

$parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
$expectedParameters = @(
  "VsixPath", "CodeCliPath", "FixtureRoot", "RepositoryUrl", "CheckoutTarget", "DiagnosticToken",
  "ExpectedRevision", "ExpectedProductVersion", "DaemonPath", "BridgePath", "TimeoutSeconds"
)
Assert-True (($parameterNames -join ",") -ceq ($expectedParameters -join ",")) "Installed redaction probe must expose only the exact required parameters."

$source = Get-Content -Raw -LiteralPath $probePath
foreach ($required in @(
    'subversionr.diagnostics.installedSvnAnonymousRedactionReport',
    'SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_REPORT_TOKEN',
    'SUBVERSIONR_INSTALLED_I6_REDACTION_DIAGNOSTIC_TOKEN',
    'SUBVERSIONR_INSTALLED_I6_REDACTION_EXPECTED_REVISION',
    '[ValidateRange(1, 2147483647)] [int]$ExpectedRevision',
    'timeoutMs: 300000',
    'secretToken,',
    'expectedRevision,',
    'Number.isSafeInteger(expectedRevision)',
    '[int]$report.checkoutRevision -eq $ExpectedRevision',
    'crypto.randomUUID()',
    '^[0-9a-f]{64}$',
    'svn://127.0.0.1:$($repositoryUri.Port)/repo/trunk',
    'Get-FileSha256 $installedDaemonPath',
    'Get-FileSha256 $installedBridgePath',
    'Wait-CandidateProcessAbsent',
    'Get-TemporaryRootCount',
    'Get-CheckoutJournalObservation',
    'Assert-CodeStderr',
    '\[DEP0169\] DeprecationWarning',
    'Code --trace-deprecation',
    'Assert-WorkingCopyDatabase',
    '--uninstall-extension',
    'Remove-Item -LiteralPath $fixtureResolved -Recurse -Force',
    'subversionr.release.m8-i6-installed-vsix-redaction-wrapper.v1',
    'subversionr.release.m8-i6-installed-vsix-redaction.v1',
    'fixtureRemovedAfterCleanup = $true',
    'extensionInstalledAfterCleanup = $false',
    'candidateProcessesAfter = $candidateProcessesAfter',
    'journalTemporaryFilesAfter = [int]$journalObservation.temporaryFileCount'
  )) {
  Assert-True ($source.Contains($required)) "Installed redaction probe is missing the contract lock: $required"
}

Assert-True (([regex]::Matches($source, 'vscode\.commands\.executeCommand\(COMMAND,')).Count -eq 1) "Installed redaction harness must execute exactly one product command."
Assert-True (([regex]::Matches($source, 'const operationId = crypto\.randomUUID\(\);')).Count -eq 1) "Installed redaction harness must generate exactly one fresh operation ID."
Assert-True (([regex]::Matches($source, '"--extensionTestsPath=')).Count -eq 1) "Installed redaction probe must launch exactly one Extension Host test session."

foreach ($forbidden in @(
    'Get-WmiObject',
    'Register-WmiEvent',
    'svn.exe',
    'SUBVERSIONR_INSTALLED_E2E_REDACTION_REPORT_TOKEN',
    'SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_REPORT_TOKEN',
    'Remove-Item -LiteralPath $checkoutResolved',
    'Remove-Item -LiteralPath $CheckoutTarget',
    'checkoutPath',
    'OperationTimeoutMilliseconds',
    'fallback',
    'alias'
  )) {
  Assert-True (-not $source.Contains($forbidden)) "Installed redaction probe must not contain the forbidden fallback, alias, or destructive route: $forbidden"
}

$finallyBlocks = @($ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.TrapStatementAst]
    }, $true))
Assert-True ($source.Contains("finally {")) "Installed redaction probe must clean up through finally."
Assert-True ($finallyBlocks.Count -eq 0) "Installed redaction probe must not use trap-based alternate cleanup."

$helperNames = @(
  "Assert-True",
  "Assert-ExactProperties",
  "Resolve-NewDirectoryPath",
  "Test-PathsOverlap",
  "Assert-CodeStderr",
  "Get-CheckoutJournalObservation",
  "Assert-ReportDoesNotContain"
)
$helperSources = foreach ($functionName in $helperNames) {
  $matches = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq $functionName
      }, $true))
  Assert-True ($matches.Count -eq 1) "Installed redaction probe must define exactly one $functionName helper."
  $matches[0].Extent.Text
}
Invoke-Expression ($helperSources -join "`n`n")
$JournalFileName = "subversionr-remote-checkout-mutations-v1.json"
$JournalTemporaryFileName = ".subversionr-remote-checkout-mutations-v1.tmp"

New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
try {
  $left = Join-Path $tempRoot "left"
  $right = Join-Path $tempRoot "right"
  $nested = Join-Path $left "nested"
  Assert-True (-not (Test-PathsOverlap $left $right)) "Installed redaction path guard rejected distinct sibling paths."
  Assert-True (Test-PathsOverlap $left $left) "Installed redaction path guard must reject identical paths."
  Assert-True (Test-PathsOverlap $left $nested) "Installed redaction path guard must reject nested paths."

  $newPath = Resolve-NewDirectoryPath $left "FixtureRoot"
  Assert-True ($newPath -ceq [System.IO.Path]::GetFullPath($left)) "Installed redaction new-path guard returned a different path."
  New-Item -ItemType Directory -Path $left | Out-Null
  Assert-ScriptThrowsContaining {
    Resolve-NewDirectoryPath $left "FixtureRoot"
  } "must not exist before the probe" "Installed redaction new-path guard must reject reuse."

  Assert-ReportDoesNotContain '{"safe":true}' @("svn://127.0.0.1:3691/repo/trunk")
  Assert-ScriptThrowsContaining {
    Assert-ReportDoesNotContain '{"leak":"svn://127.0.0.1:3691/repo/trunk"}' @("svn://127.0.0.1:3691/repo/trunk")
  } "leaked request identity" "Installed redaction leak guard must reject raw URLs."

  Assert-CodeStderr "" "empty stderr"
  Assert-CodeStderr @'
(node:12345) [DEP0169] DeprecationWarning: `url.parse()` behavior is not standardized and prone to errors that have security implications. Use the WHATWG URL API instead. CVEs are not issued for `url.parse()` vulnerabilities.
(Use `Code --trace-deprecation ...` to show where the warning was created)
'@ "known VS Code warning"
  Assert-ScriptThrowsContaining {
    Assert-CodeStderr "unexpected warning" "unknown VS Code warning"
  } "wrote unexpected stderr" "Installed redaction stderr guard must reject unknown output."

  $missingJournalRoot = Join-Path $tempRoot "missing-remote-state"
  $missingObservation = Get-CheckoutJournalObservation $missingJournalRoot
  Assert-True ($missingObservation.entryCount -eq 0 -and $missingObservation.temporaryFileCount -eq 0) "Installed redaction journal observation must accept an uncreated remote-state root as zero residue."
  New-Item -ItemType Directory -Path $missingJournalRoot | Out-Null
  $emptyObservation = Get-CheckoutJournalObservation $missingJournalRoot
  Assert-True ($emptyObservation.entryCount -eq 0 -and $emptyObservation.temporaryFileCount -eq 0) "Installed redaction journal observation must accept an absent journal as zero residue."
  [System.IO.File]::WriteAllText((Join-Path $missingJournalRoot $JournalTemporaryFileName), "residue", [System.Text.UTF8Encoding]::new($false))
  $temporaryObservation = Get-CheckoutJournalObservation $missingJournalRoot
  Assert-True ($temporaryObservation.temporaryFileCount -eq 1) "Installed redaction journal observation must expose temporary-file residue."
  Remove-Item -LiteralPath (Join-Path $missingJournalRoot $JournalTemporaryFileName)
  [System.IO.File]::WriteAllText(
    (Join-Path $missingJournalRoot $JournalFileName),
    '{"schemaVersion":1,"entries":[]}',
    [System.Text.UTF8Encoding]::new($false)
  )
  $journalObservation = Get-CheckoutJournalObservation $missingJournalRoot
  Assert-True ($journalObservation.entryCount -eq 0 -and $journalObservation.temporaryFileCount -eq 0) "Installed redaction journal observation must strictly parse an empty v1 journal."

  $argumentRoot = Join-Path $tempRoot "arguments"
  New-Item -ItemType Directory -Path $argumentRoot | Out-Null
  $codePath = Join-Path $argumentRoot "code.cmd"
  $daemonPath = Join-Path $argumentRoot "subversionr-daemon.exe"
  $bridgePath = Join-Path $argumentRoot "subversionr_svn_bridge.dll"
  foreach ($path in @($codePath, $daemonPath, $bridgePath)) {
    [System.IO.File]::WriteAllText($path, "fixture", [System.Text.UTF8Encoding]::new($false))
  }
  $fixturePath = Join-Path $argumentRoot "new-fixture"
  $checkoutPath = Join-Path $argumentRoot "new-checkout"
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probePath `
      -VsixPath "relative.vsix" `
      -CodeCliPath $codePath `
      -FixtureRoot $fixturePath `
      -RepositoryUrl "svn://127.0.0.1:3691/repo/trunk" `
      -CheckoutTarget $checkoutPath `
      -DiagnosticToken ("a" * 64) `
      -ExpectedRevision 3 `
      -ExpectedProductVersion "0.2.5" `
      -DaemonPath $daemonPath `
      -BridgePath $bridgePath `
      -TimeoutSeconds 180
  } "VsixPath must be an absolute path" "Installed redaction probe must reject a relative VSIX before creating output paths."
  Assert-True (-not (Test-Path -LiteralPath $fixturePath)) "Installed redaction argument failure must not create FixtureRoot."
  Assert-True (-not (Test-Path -LiteralPath $checkoutPath)) "Installed redaction argument failure must not create CheckoutTarget."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probePath `
      -VsixPath "relative.vsix" `
      -CodeCliPath $codePath `
      -FixtureRoot $fixturePath `
      -RepositoryUrl "svn://127.0.0.1:3691/repo/trunk" `
      -CheckoutTarget $checkoutPath `
      -DiagnosticToken "ABCDEF" `
      -ExpectedRevision 3 `
      -ExpectedProductVersion "0.2.5" `
      -DaemonPath $daemonPath `
      -BridgePath $bridgePath `
      -TimeoutSeconds 180
  } "does not match the" "Installed redaction probe must reject non-64-lowercase-hex diagnostic tokens at parameter binding."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probePath `
      -VsixPath "relative.vsix" `
      -CodeCliPath $codePath `
      -FixtureRoot $fixturePath `
      -RepositoryUrl "svn://127.0.0.1:3691/repo/trunk" `
      -CheckoutTarget $checkoutPath `
      -DiagnosticToken ("a" * 64) `
      -ExpectedRevision 0 `
      -ExpectedProductVersion "0.2.5" `
      -DaemonPath $daemonPath `
      -BridgePath $bridgePath `
      -TimeoutSeconds 180
  } "ExpectedRevision" "Installed redaction probe must reject a non-positive expected revision at parameter binding."
}
finally {
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}

Write-Host "M8 I6 installed redaction probe script tests passed."

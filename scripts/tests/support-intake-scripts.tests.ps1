$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$verifySupportIntakeScript = Join-Path $repoRoot "scripts\verify-support-intake.ps1"

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw $Message
  }
}

function Assert-NativeCommandFailsContaining([scriptblock]$Action, [string]$ExpectedText, [string]$Message) {
  $output = & $Action 2>&1
  $exitCode = $LASTEXITCODE
  Assert-True ($exitCode -ne 0) "$Message Expected native command to fail."
  $text = $output | Out-String
  Assert-True ($text.Contains($ExpectedText)) "$Message Expected output to contain '$ExpectedText', got '$text'."
}

function Copy-SupportIntakeFixture([string]$DestinationRoot) {
  $paths = @(
    "SECURITY.md",
    "SUPPORT.md",
    "package.json",
    ".github\workflows\ci.yml",
    ".github\ISSUE_TEMPLATE\config.yml",
    ".github\ISSUE_TEMPLATE\01_bug_report.yml",
    ".github\ISSUE_TEMPLATE\02_support_request.yml",
    "docs\security\support-handling.md",
    "docs\security\support-redaction-checklist.md",
    "packages\vscode-extension\tests\diagnosticsRedaction.test.ts"
  )

  foreach ($relativePath in $paths) {
    $source = Join-Path $repoRoot $relativePath
    $destination = Join-Path $DestinationRoot $relativePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Force
  }
}

$tempRoot = Join-Path $repoRoot "target\tests\support-intake-scripts\$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  Assert-True (Test-Path -LiteralPath $verifySupportIntakeScript -PathType Leaf) "verify-support-intake.ps1 should exist."

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifySupportIntakeScript -RepoRoot $repoRoot
  if ($LASTEXITCODE -ne 0) {
    throw "verify-support-intake.ps1 failed against the repository with exit code $LASTEXITCODE."
  }

  $validFixture = Join-Path $tempRoot "valid"
  Copy-SupportIntakeFixture $validFixture
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifySupportIntakeScript -RepoRoot $validFixture
  if ($LASTEXITCODE -ne 0) {
    throw "verify-support-intake.ps1 failed against a copied valid fixture with exit code $LASTEXITCODE."
  }

  $blankIssueFixture = Join-Path $tempRoot "blank-issues"
  Copy-SupportIntakeFixture $blankIssueFixture
  $configPath = Join-Path $blankIssueFixture ".github\ISSUE_TEMPLATE\config.yml"
  (Get-Content -Raw -LiteralPath $configPath).Replace("blank_issues_enabled: false", "blank_issues_enabled: true") |
    Set-Content -LiteralPath $configPath -NoNewline
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifySupportIntakeScript -RepoRoot $blankIssueFixture
  } "blank_issues_enabled: false" "Support intake verification should reject blank public issues."

  $securityRoutingFixture = Join-Path $tempRoot "security-routing"
  Copy-SupportIntakeFixture $securityRoutingFixture
  $bugFormPath = Join-Path $securityRoutingFixture ".github\ISSUE_TEMPLATE\01_bug_report.yml"
  (Get-Content -Raw -LiteralPath $bugFormPath).Replace("SECURITY.md", "the private security policy") |
    Set-Content -LiteralPath $bugFormPath -NoNewline
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifySupportIntakeScript -RepoRoot $securityRoutingFixture
  } "SECURITY.md" "Support intake verification should reject forms that do not route security reports to SECURITY.md."

  $checklistFixture = Join-Path $tempRoot "checklist"
  Copy-SupportIntakeFixture $checklistFixture
  $checklistPath = Join-Path $checklistFixture "docs\security\support-redaction-checklist.md"
  (Get-Content -Raw -LiteralPath $checklistPath).Replace(".svn/wc.db", ".svn database") |
    Set-Content -LiteralPath $checklistPath -NoNewline
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifySupportIntakeScript -RepoRoot $checklistFixture
  } ".svn/wc.db" "Support intake verification should reject checklists that omit SVN working-copy database handling."

  $diagnosticsChecklistFixture = Join-Path $tempRoot "diagnostics-checklist"
  Copy-SupportIntakeFixture $diagnosticsChecklistFixture
  $diagnosticsChecklistPath = Join-Path $diagnosticsChecklistFixture "docs\security\support-redaction-checklist.md"
  (Get-Content -Raw -LiteralPath $diagnosticsChecklistPath).Replace("operation journal", "operation summary") |
    Set-Content -LiteralPath $diagnosticsChecklistPath -NoNewline
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifySupportIntakeScript -RepoRoot $diagnosticsChecklistFixture
  } "operation journal" "Support intake verification should reject checklists that omit operation journal redaction coverage."

  $redactionFixture = Join-Path $tempRoot "redaction-fixture"
  Copy-SupportIntakeFixture $redactionFixture
  $redactionTestPath = Join-Path $redactionFixture "packages\vscode-extension\tests\diagnosticsRedaction.test.ts"
  (Get-Content -Raw -LiteralPath $redactionTestPath).Replace("public support redaction fixture", "public support fixture") |
    Set-Content -LiteralPath $redactionTestPath -NoNewline
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifySupportIntakeScript -RepoRoot $redactionFixture
  } "public support redaction fixture" "Support intake verification should reject missing automated redaction fixture evidence."

  $diagnosticsRedactionFixture = Join-Path $tempRoot "diagnostics-redaction-fixture"
  Copy-SupportIntakeFixture $diagnosticsRedactionFixture
  $diagnosticsRedactionTestPath = Join-Path $diagnosticsRedactionFixture "packages\vscode-extension\tests\diagnosticsRedaction.test.ts"
  (Get-Content -Raw -LiteralPath $diagnosticsRedactionTestPath).Replace("watcherOverflowDiagnostics", "watcherDiagnostics") |
    Set-Content -LiteralPath $diagnosticsRedactionTestPath -NoNewline
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifySupportIntakeScript -RepoRoot $diagnosticsRedactionFixture
  } "watcherOverflowDiagnostics" "Support intake verification should reject redaction fixtures that omit watcher diagnostics coverage."

  $ciFixture = Join-Path $tempRoot "ci"
  Copy-SupportIntakeFixture $ciFixture
  $ciPath = Join-Path $ciFixture ".github\workflows\ci.yml"
  (Get-Content -Raw -LiteralPath $ciPath).Replace("pnpm docs:verify-support-intake", "pnpm docs:verify-security") |
    Set-Content -LiteralPath $ciPath -NoNewline
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifySupportIntakeScript -RepoRoot $ciFixture
  } "docs:verify-support-intake" "Support intake verification should reject CI that does not run the support intake gate."

  Write-Host "Support intake script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

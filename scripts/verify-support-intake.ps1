param(
  [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot ".."))
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRootPath = Resolve-Path -LiteralPath $RepoRoot

function Read-RequiredFile([string]$RelativePath) {
  $path = Join-Path $repoRootPath $RelativePath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Missing required support intake file: $RelativePath"
  }

  $content = Get-Content -Raw -LiteralPath $path
  if ([string]::IsNullOrWhiteSpace($content)) {
    throw "Required support intake file is empty: $RelativePath"
  }

  [pscustomobject]@{
    RelativePath = $RelativePath
    Content = $content
  }
}

function Assert-Contains([object]$Document, [string]$Needle, [string]$Requirement) {
  if (-not $Document.Content.Contains($Needle)) {
    throw "$($Document.RelativePath): missing '$Needle' required by $Requirement."
  }
}

function Assert-NotContainsPattern([object]$Document, [string]$Pattern, [string]$Requirement) {
  if ($Document.Content -match $Pattern) {
    throw "$($Document.RelativePath): contains forbidden pattern '$Pattern' blocked by $Requirement."
  }
}

function Assert-Terms([object]$Document, [string[]]$Terms, [string]$Requirement) {
  foreach ($term in $Terms) {
    Assert-Contains $Document $term $Requirement
  }
}

function Assert-ContainsInOrder([object]$Document, [string[]]$Needles, [string]$Requirement) {
  $previousIndex = -1
  foreach ($needle in $Needles) {
    $currentIndex = $Document.Content.IndexOf($needle, [System.StringComparison]::Ordinal)
    if ($currentIndex -lt 0) {
      throw "$($Document.RelativePath): missing '$needle' required by $Requirement."
    }
    if ($currentIndex -le $previousIndex) {
      throw "$($Document.RelativePath): '$needle' must appear after the previous checked term required by $Requirement."
    }
    $previousIndex = $currentIndex
  }
}

function Assert-IssueForm([object]$Document, [string]$Requirement) {
  Assert-Terms $Document @(
    "name:",
    "description:",
    "title:",
    "labels:",
    "body:",
    "SECURITY.md",
    "Security / セキュリティ / 安全",
    "Do not include / 含めないでください / 请勿包含",
    "credentials",
    "tokens",
    "cookies",
    "private repository URLs",
    "client certificate private keys",
    ".svn/wc.db",
    "raw logs",
    "source content",
    "redacted diagnostics",
    "support-redaction-checklist.md"
  ) $Requirement

  Assert-Terms $Document @(
    "type: checkboxes",
    "required: true",
    'I have not included credentials, tokens, cookies, private repository URLs, client certificate private keys, `.svn/wc.db`, raw logs, or source content.',
    'Security vulnerabilities must be reported through `SECURITY.md`, not this public issue form.'
  ) "$Requirement mandatory sensitive-data acknowledgement"
}

$config = Read-RequiredFile ".github/ISSUE_TEMPLATE/config.yml"
$bugReport = Read-RequiredFile ".github/ISSUE_TEMPLATE/01_bug_report.yml"
$supportRequest = Read-RequiredFile ".github/ISSUE_TEMPLATE/02_support_request.yml"
$securityPolicy = Read-RequiredFile "SECURITY.md"
$supportDoc = Read-RequiredFile "SUPPORT.md"
$supportHandling = Read-RequiredFile "docs/security/support-handling.md"
$supportChecklist = Read-RequiredFile "docs/security/support-redaction-checklist.md"
$redactionTests = Read-RequiredFile "packages/vscode-extension/tests/diagnosticsRedaction.test.ts"
$packageJsonDocument = Read-RequiredFile "package.json"
$ciWorkflow = Read-RequiredFile ".github/workflows/ci.yml"

Assert-Terms $config @(
  "blank_issues_enabled: false"
) "GitHub public issue intake hardening"
Assert-NotContainsPattern $config "(?m)^\s*blank_issues_enabled:\s*true\s*$" "GitHub public issue intake hardening"

Assert-IssueForm $bugReport "bug report issue form"
Assert-IssueForm $supportRequest "support request issue form"
Assert-ContainsInOrder $bugReport @(
  "Security / セキュリティ / 安全",
  "SECURITY.md",
  "Do not include / 含めないでください / 请勿包含"
) "bug report security routing before evidence collection"
Assert-ContainsInOrder $supportRequest @(
  "Security / セキュリティ / 安全",
  "SECURITY.md",
  "Do not include / 含めないでください / 请勿包含"
) "support request security routing before evidence collection"

Assert-Terms $securityPolicy @(
  "Do not report security vulnerabilities through a public issue",
  "Private Vulnerability Reporting",
  "credentials",
  "private keys",
  "SecretStorage",
  "Unredacted diagnostics bundles"
) "security policy public issue routing"
Assert-NotContainsPattern $securityPolicy "(?im)^\s*report security vulnerabilities through a public issue" "security policy must not route vulnerabilities to public issues"

Assert-Terms $supportDoc @(
  "SECURITY.md",
  "Do not include secrets, credentials, private repository URLs, cookies, certificate private keys, or sensitive working-copy data in public reports.",
  "sanitized diagnostics evidence"
) "top-level support metadata"

Assert-Terms $supportHandling @(
  "docs/security/support-redaction-checklist.md",
  "public issue templates",
  "maintainer redaction checklist",
  "operation journal",
  "watcher metrics",
  "SEC-002",
  "SEC-014",
  "OBS-005",
  "OBS-007",
  "PRD-010",
  "PRD-012"
) "support handling linkage to public intake gate"

Assert-Terms $supportChecklist @(
  "# Support Redaction Checklist",
  "SEC-002",
  "SEC-014",
  "OBS-005",
  "OBS-007",
  "PRD-010",
  "PRD-012",
  "credentials",
  "auth tokens",
  "cookies",
  "Authorization",
  "private repository URLs",
  'credentialed `svn://`',
  'credentialed `http://`',
  'credentialed `https://`',
  ".svn/wc.db",
  "working-copy absolute paths",
  "operation journal",
  "watcher overflow metrics",
  "stack traces",
  "client certificate private keys",
  "source content",
  "raw logs",
  "Do not paste redacted bundles into public comments",
  "If any required category is unreviewed, stop normal public triage"
) "maintainer support redaction checklist"

Assert-Terms $redactionTests @(
  "public support redaction fixture",
  "https://alice:hunter2@example.com/repos/private?token=abc123",
  "svn://bob:secret@example.net/repos/project",
  ".svn/wc.db",
  "Authorization: Basic",
  "Cookie:",
  "C:\\Users\\Alice\\workspace\\project\\.svn\\wc.db",
  "Stack trace at C:\\Users\\Alice\\workspace\\project\\src\\main.ts",
  "operationJournal",
  "watcherOverflowDiagnostics",
  "[REDACTED:url:",
  "[REDACTED:path:",
  "[REDACTED:secret]"
) "automated public support redaction fixture"

Assert-Terms $packageJsonDocument @(
  '"docs:verify-support-intake"',
  "scripts/verify-support-intake.ps1",
  '"release:test-support-intake-scripts"',
  "scripts/tests/support-intake-scripts.tests.ps1"
) "root package support intake scripts"

Assert-Terms $ciWorkflow @(
  "Support intake checks",
  "pnpm docs:verify-support-intake",
  "Support intake script tests",
  "pnpm release:test-support-intake-scripts"
) "CI support intake wiring"
Assert-ContainsInOrder $ciWorkflow @(
  "Public security documentation checks",
  "Support intake checks",
  "Release readiness checks"
) "CI support intake check order"

Write-Host "Support intake checks passed."

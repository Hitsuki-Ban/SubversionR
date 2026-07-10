$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

function Read-RequiredDocument([string]$RelativePath) {
  $path = Join-Path $repoRoot $RelativePath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Missing required public security document: $RelativePath"
  }

  $content = Get-Content -Raw -LiteralPath $path
  if ([string]::IsNullOrWhiteSpace($content)) {
    throw "Required public security document is empty: $RelativePath"
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

function Assert-TraceIds([string]$Content, [string[]]$Ids, [string]$Scope) {
  foreach ($id in $Ids) {
    if (-not $Content.Contains($id)) {
      throw "$Scope must trace requirement id $id."
    }
  }
}

function Assert-Terms([object]$Document, [string[]]$Terms, [string]$Requirement) {
  foreach ($term in $Terms) {
    Assert-Contains $Document $term $Requirement
  }
}

$threatModel = Read-RequiredDocument "docs/security/threat-model.md"
$supportHandling = Read-RequiredDocument "docs/security/support-handling.md"
$supportChecklist = Read-RequiredDocument "docs/security/support-redaction-checklist.md"
$m6ToM7Decision = Read-RequiredDocument "docs/security/m6-to-m7-security-decision.md"
$m6Plan = Read-RequiredDocument "docs/plans/m6-auth-security-trust.md"
$roadmap = Read-RequiredDocument "docs/roadmap/README.md"

foreach ($section in @(
  "# SubversionR Public Security Threat Model",
  "## Scope",
  "## Assets",
  "## Trust Boundaries",
  "## Threats And Controls",
  "## Security Acceptance Matrix",
  "## Deferred Risks",
  "## M7 Release Gates"
)) {
  Assert-Contains $threatModel $section "M6aa public threat-model coverage"
}

foreach ($section in @(
  "# SubversionR Security Support Handling",
  "## Security Vulnerability Reports",
  "## Support Bundle Handling",
  "## Do Not Request",
  "## Redaction",
  "## Retention",
  "## Telemetry"
)) {
  Assert-Contains $supportHandling $section "M6aa support-handling coverage"
}

foreach ($section in @(
  "# Support Redaction Checklist",
  "## Public Issue Intake",
  "## Diagnostics Evidence",
  "## Maintainer Stop Conditions"
)) {
  Assert-Contains $supportChecklist $section "M7k1 support redaction checklist coverage"
}

foreach ($section in @(
  "# M6aa To M7 Security Decision",
  "## Required Before M7 Packaging",
  "## Deferred After M6aa",
  "## Requirement Traceability",
  "## Non-Claims"
)) {
  Assert-Contains $m6ToM7Decision $section "M6aa release decision coverage"
}

$securityIds = @(
  "SEC-001", "SEC-002", "SEC-003", "SEC-004",
  "SEC-005", "SEC-006", "SEC-007", "SEC-008",
  "SEC-009", "SEC-010", "SEC-011", "SEC-012",
  "SEC-013", "SEC-014", "SEC-015", "SEC-016"
)
$observabilityIds = @("OBS-005", "OBS-006", "OBS-007", "OBS-008")
$migrationIds = @("MIG-008", "MIG-009", "MIG-010", "MIG-011", "MIG-012")

$combinedSecurityDocs = @(
  $threatModel.Content,
  $supportHandling.Content,
  $supportChecklist.Content,
  $m6ToM7Decision.Content
) -join "`n"

Assert-TraceIds $combinedSecurityDocs $securityIds "Public security documentation"
Assert-TraceIds $combinedSecurityDocs $observabilityIds "Public security documentation"
Assert-TraceIds $combinedSecurityDocs $migrationIds "Public security documentation"

Assert-TraceIds $threatModel.Content $securityIds $threatModel.RelativePath
Assert-TraceIds $supportHandling.Content @("SEC-002", "SEC-014", "OBS-005", "OBS-006", "OBS-007", "OBS-008") $supportHandling.RelativePath
Assert-TraceIds $supportChecklist.Content @("SEC-002", "SEC-014", "OBS-005", "OBS-007", "PRD-010", "PRD-012") $supportChecklist.RelativePath
Assert-TraceIds $m6ToM7Decision.Content @("SEC-015", "MIG-008", "MIG-009", "MIG-010", "MIG-011", "MIG-012") $m6ToM7Decision.RelativePath

Assert-Terms $threatModel @(
  "not a final security certification",
  "arbitrary HTTPS SVN servers",
  "source-built localhost DAV fixture",
  "standard SVN credential-store opt-in",
  "proxy authentication",
  "client certificates",
  "svn+ssh",
  "Kerberos/NTLM",
  "SASL",
  "non-localhost TLS",
  "M7 signing, SBOM, NOTICE, CVE"
) "public threat model non-claim and deferred-risk coverage"

Assert-Terms $supportHandling @(
  "SECURITY.md",
  "docs/security/support-redaction-checklist.md",
  "supported versions",
  "private vulnerability reporting path",
  "user-initiated local JSON files",
  "not uploaded automatically",
  "must not request",
  "VS Code SecretStorage content",
  "standard SVN credential-store files",
  "telemetry disabled by default"
) "security support handling release and privacy coverage"

Assert-Terms $supportChecklist @(
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
  "stack traces",
  "client certificate private keys",
  "source content",
  "raw logs",
  "Do not paste redacted bundles into public comments",
  "If any required category is unreviewed"
) "support redaction checklist release and privacy coverage"

Assert-Terms $m6ToM7Decision @(
  "SECURITY.md",
  "supported versions",
  "private vulnerability reporting path",
  "SBOM",
  "NOTICE",
  "CVE",
  "signing",
  "hash verification",
  "packaged resource manifest",
  "platform-specific VSIX",
  "cache schema rollback",
  "extension rollback",
  "migration report",
  "security acceptance evidence matrix",
  "diagnostics redaction fixture",
  "hard-fail behavior",
  "SecretStorage",
  "sidecar crash",
  "auth timeout",
  "arbitrary remote HTTPS SVN servers",
  "standard SVN credential-store persistence",
  "proxy auth",
  "client certificates",
  "svn+ssh",
  "Kerberos/NTLM",
  "SASL",
  "custom tunnels"
) "M6aa to M7 release blocker and non-claim coverage"

Assert-Contains $m6Plan "## M6aa Implemented Slice" "M6 plan M6aa status"
Assert-Contains $m6Plan "docs/security/threat-model.md" "M6 plan public security doc trace"
Assert-Contains $m6Plan "docs/security/support-handling.md" "M6 plan public security doc trace"
Assert-Contains $m6Plan "docs/security/m6-to-m7-security-decision.md" "M6 plan public security doc trace"
Assert-Contains $roadmap "public-readiness security documentation" "roadmap M6aa status"

Write-Host "Public security documentation checks passed."

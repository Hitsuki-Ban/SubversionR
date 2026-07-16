[CmdletBinding()]
param(
  [string]$RepoRoot = (Join-Path $PSScriptRoot "..\.."),

  [string]$RequirementsEvidencePath,

  [ValidateSet("full", "smoke", "rule")]
  [string]$Mode = "full"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$modelModule = Join-Path $PSScriptRoot "lib\ReadinessModel.psm1"
$rulesModule = Join-Path $PSScriptRoot "lib\ReadinessRules.psm1"
Import-Module $modelModule -Force
Import-Module $rulesModule -Force

$repoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
$supportIntakeVerifier = Join-Path $repoRoot "scripts\verify-support-intake.ps1"

function Read-RequiredDocument([string]$RelativePath) {
  $path = Join-Path $repoRoot $RelativePath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Missing required release-readiness document: $RelativePath"
  }

  $content = Get-Content -Raw -LiteralPath $path
  if ([string]::IsNullOrWhiteSpace($content)) {
    throw "Required release-readiness document is empty: $RelativePath"
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

function Assert-DoesNotContain([object]$Document, [string]$Needle, [string]$Requirement) {
  if ($Document.Content.Contains($Needle)) {
    throw "$($Document.RelativePath): must not contain '$Needle' prohibited by $Requirement."
  }
}

function Assert-Terms([object]$Document, [string[]]$Terms, [string]$Requirement) {
  foreach ($term in $Terms) {
    Assert-Contains $Document $term $Requirement
  }
}

function Assert-NoTerms([object]$Document, [string[]]$Terms, [string]$Requirement) {
  foreach ($term in $Terms) {
    Assert-DoesNotContain $Document $term $Requirement
  }
}

function Assert-DirectoryFilesDoNotContain(
  [string]$RelativeRoot,
  [string[]]$Extensions,
  [string[]]$ForbiddenTerms,
  [string]$Requirement
) {
  $root = Join-Path $repoRoot $RelativeRoot
  if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw "Missing required release-readiness source directory: $RelativeRoot"
  }

  $files = @(
    Get-ChildItem -LiteralPath $root -Recurse -File |
      Where-Object { $Extensions -contains $_.Extension }
  )
  if ($files.Count -eq 0) {
    throw "${RelativeRoot}: no files matched extensions '$($Extensions -join ', ')' for $Requirement."
  }

  foreach ($file in $files) {
    $content = Get-Content -Raw -LiteralPath $file.FullName
    foreach ($term in $ForbiddenTerms) {
      if ($content.Contains($term)) {
        $relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $file.FullName).Replace("\", "/")
        throw "${relativePath}: must not contain '$term' prohibited by $Requirement."
      }
    }
  }
}

function Assert-TraceIds([string]$Content, [string[]]$Ids, [string]$Scope) {
  foreach ($id in $Ids) {
    if (-not $Content.Contains($id)) {
      throw "$Scope must trace requirement id $id."
    }
  }
}

function Get-MarkdownTableRow([object]$Document, [string]$Key) {
  $escapedKey = [regex]::Escape($Key)
  $pattern = "(?m)^\|\s*(?:``)?$escapedKey(?:``)?\s*\|(?<rest>.+)$"
  $match = [regex]::Match($Document.Content, $pattern)
  if (-not $match.Success) {
    throw "$($Document.RelativePath): missing Markdown table row for '$Key'."
  }

  $cells = @($match.Value.Trim().Trim("|").Split("|") | ForEach-Object { $_.Trim() })
  if ($cells.Count -lt 2) {
    throw "$($Document.RelativePath): malformed Markdown table row for '$Key'."
  }

  $cells
}

function Assert-TableStatus([object]$Document, [string]$Key, [string]$ExpectedStatus) {
  $cells = Get-MarkdownTableRow $Document $Key
  if ($cells[1] -ne $ExpectedStatus) {
    throw "$($Document.RelativePath): '$Key' must have status '$ExpectedStatus', got '$($cells[1])'."
  }
}

function Assert-TableStatusIn([object]$Document, [string]$Key, [string[]]$AllowedStatuses) {
  $cells = Get-MarkdownTableRow $Document $Key
  if ($AllowedStatuses -notcontains $cells[1]) {
    throw "$($Document.RelativePath): '$Key' must have one of statuses '$($AllowedStatuses -join ', ')', got '$($cells[1])'."
  }
}

function Assert-PrFastWorkflow([object]$Workflow) {
  Assert-Terms $Workflow @(
    "pull_request:",
    "push:",
    "branches:",
    "- main",
    "workflow_dispatch:",
    "actions/checkout@v7",
    "pnpm/action-setup@v6",
    "actions/setup-node@v5",
    "pnpm install --frozen-lockfile",
    "pnpm check",
    "pnpm test",
    "pnpm release:test-state-engine-beta-performance:win32-x64",
    "pnpm i18n:verify",
    "pnpm docs:verify-security",
    "pnpm docs:verify-support-intake",
    "pnpm release:test-marketplace-publication-scripts",
    "pnpm release:verify-readiness:smoke",
    "pnpm release:test-native-remote-fuzz-target-preflight-scripts",
    "pnpm release:generate-native-remote-fuzz-target-preflight:win32-x64",
    "pnpm release:verify-native-remote-fuzz-target-preflight:win32-x64",
    "cargo fmt --all -- --check",
    "cargo test --workspace",
    "pnpm native:test-scripts"
  ) "automatic GitHub Actions PR Fast gate coverage"
  Assert-NoTerms $Workflow @(
    "actions/checkout@v4",
    "pnpm/action-setup@v4"
  ) "automatic GitHub Actions PR Fast gate must not use Node 20 action runtimes"
  if ($Workflow.Content -match "(?m)^\s*run:\s*pnpm release:verify-readiness\s*$") {
    throw ".github/workflows/pr-fast.yml: PR Fast gate must use release:verify-readiness:smoke instead of full release readiness."
  }
  if ($Workflow.Content -match "native:build-deps|native:build-subversion|native:build-bridge|native:smoke-bridge|release:package-vsix|release:test-vsix|release:test-installed|release:install-rollback|release:generate-live-osv-review|release:verify-live-osv-review|release:generate-native-remote-fuzz-fixed-seed-smoke|release:verify-native-remote-fuzz-fixed-seed-smoke|release:test-native-remote-fuzz-fixed-seed-smoke-scripts|cargo\s+\+nightly\s+fuzz") {
    throw ".github/workflows/pr-fast.yml: PR Fast gate must not run heavy native build, VSIX packaging, installed VS Code, live vulnerability review, or fixed-seed fuzz build/run flows."
  }
}

function Assert-RetiredCloudflareBridgeDoc([object]$Document) {
  Assert-Terms $Document @(
    "# Retired Cloudflare PR Fast Bridge",
    'Retirement date: `2026-07-10`',
    "zero build triggers",
    "repository connection was removed",
    'no longer has a build configuration associated with `subversionr-pr-fast`',
    ".github/workflows/pr-fast.yml",
    "Git history preserves the exact implementation",
    "No Cloudflare live identifiers"
  ) "retired Cloudflare PR Fast bridge record"
  $forbiddenPatterns = [ordered]@{
    "private repository identifier" = 'Hitsuki-Ban[\\/]+SubversionR-private'
    "retired bridge source path" = 'cloudflare-pr-fast-(?:bridge|worker)\.mjs|cloudflare-pr-fast\.wrangler\.jsonc'
    "Wrangler deployment command" = '\bwrangler(?:@[^\s`]+)?\b.{0,80}\b(?:deploy|versions\s+upload)\b'
    "GitHub integration reconnection instruction" = '(?:\b(?:reconnect|reinstall)\b.{0,80}\b(?:github\s+(?:integration|app)|git\s+integration)\b)|(?:\b(?:github\s+(?:integration|app)|git\s+integration)\b.{0,80}\b(?:reconnect|reinstall)\b)'
    "webhook signature relay instruction" = '\b(?:x[- ]?hub[- ]?signature[- ]?256|webhook.{0,40}signature|signature.{0,40}webhook)\b'
  }
  foreach ($category in $forbiddenPatterns.Keys) {
    if ([regex]::IsMatch($Document.Content, [string]$forbiddenPatterns[$category], [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
      throw "$($Document.RelativePath): retired bridge record must not contain $category."
    }
  }
}

function Read-AndAssertArchitectureDecisionRecords() {
  $contracts = [ordered]@{
    "docs/adr/ADR-001-typescript-rust-libsvn-architecture.md" = @(
      "# ADR-001: TypeScript UI, Rust Sidecar, and libsvn",
      "The VS Code UI and adapter are implemented in TypeScript.",
      "Native and long-running work runs in a Rust sidecar",
      "libsvn is authoritative for SVN semantics."
    )
    "docs/adr/ADR-002-stdio-rpc-transport.md" = @(
      "# ADR-002: Stdio RPC Transport",
      "framed RPC over the child process's standard input and output",
      "The sidecar does not open a listening port."
    )
    "docs/adr/ADR-003-bundled-libsvn-runtime.md" = @(
      "# ADR-003: Bundled libsvn Runtime",
      "The bundled libsvn and its packaged native dependencies are the default production runtime.",
      "Core workflows do not depend on a system"
    )
    "docs/adr/ADR-004-working-copy-database-integrity.md" = @(
      "# ADR-004: Working Copy Database Integrity",
      "SubversionR never writes",
      "any read-only optimization must not replace libsvn confirmation where correctness matters."
    )
    "docs/adr/ADR-005-dirty-path-status-refresh.md" = @(
      "# ADR-005: Dirty-Path Status Refresh",
      "Ordinary local status refresh targets the dirty paths",
      "Low-frequency full reconciliation is a separate repair mechanism"
    )
    "docs/adr/ADR-006-local-and-remote-status-scheduling.md" = @(
      "# ADR-006: Local and Remote Status Scheduling",
      "Local and remote status are scheduled independently.",
      "Remote status is manual-first, with no default background remote polling."
    )
    "docs/adr/ADR-007-sidecar-process-lifetime.md" = @(
      "# ADR-007: Sidecar Process Lifetime",
      "Each Extension Host starts one Rust sidecar",
      "shares it across all repositories managed by that host."
    )
    "docs/adr/ADR-008-stable-vscode-apis.md" = @(
      "# ADR-008: Stable VS Code APIs",
      "Core functionality uses stable VS Code APIs and does not depend on proposed APIs."
    )
    "docs/adr/ADR-009-optional-tortoisesvn-adapter.md" = @(
      "# ADR-009: Optional TortoiseSVN Adapter",
      "TortoiseSVN is an optional adapter integration, not a core dependency.",
      "Missing TortoiseSVN does not break or weaken native core workflows."
    )
    "docs/adr/ADR-010-credential-storage.md" = @(
      "# ADR-010: Credential Storage",
      "Persistent credentials are stored only in VS Code SecretStorage.",
      "credential persistence fails closed",
      "does not fall back to settings, extension caches, sidecar storage, diagnostics, or the standard SVN auth cache"
    )
    "docs/adr/ADR-011-cache-source-of-truth.md" = @(
      "# ADR-011: Cache Source of Truth",
      "All SubversionR caches are discardable.",
      "The working copy, interpreted through libsvn, is the external source of truth."
    )
    "docs/adr/ADR-012-svn-terminology.md" = @(
      "# ADR-012: SVN Terminology",
      "SubversionR uses SVN terminology and semantics.",
      "It does not invent staging, push/pull, Git commit graphs, or other fake Git equivalents."
    )
  }

  $index = Read-RequiredDocument "docs/adr/README.md"
  Assert-Terms $index @(
    "# Architecture Decision Records",
    "## Governance",
    "ADR numbers are stable and are never reused or renumbered.",
    "requires a new ADR and product, architecture, security, and QA review",
    "each superseded record must link to its replacement"
  ) "public architecture decision governance coverage"

  $records = [ordered]@{}
  foreach ($path in $contracts.Keys) {
    $record = Read-RequiredDocument $path
    $title = ([string]$contracts[$path][0]).Substring(2)
    Assert-Terms $index @("[$title]($(Split-Path -Leaf $path))") "public architecture decision index entry"
    Assert-Terms $record (@(
        "Status: Accepted",
        "## Context",
        "## Decision",
        "## Consequences"
      ) + @($contracts[$path])) "public architecture decision contract"
    $records[$path] = $record
  }
  $records
}

function Assert-GithubActionsRestorationDoc([object]$Document) {
  Assert-Terms $Document @(
    "# GitHub Actions Restoration",
    "pull_request",
    "push",
    "workflow_dispatch",
    "weekly schedule",
    "PR Fast / windows",
    "## Cutover State",
    'were both set to `disabled_manually` on 2026-07-10',
    "scheduled/manual",
    "not part of automatic PR validation"
  ) "GitHub Actions restoration documentation"
}

function Assert-PublicCutoverRunbook([object]$Document) {
  Assert-Terms $Document @(
    "# Public Cutover Runbook",
    "fresh squash-style baseline commit",
    'Reference/` remains private',
    "PR Fast / windows",
    "GitHub Private Vulnerability Reporting",
    "subversionr-pr-fast",
    "v0.2.0-beta.1",
    "docs/release/github-attestation-evidence.win32-x64.json",
    "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/29104476735",
    "https://github.com/Hitsuki-Ban/SubversionR/attestations/34774737",
    "superseded",
    "publicReadinessClaim=false"
  ) "public cutover runbook"
}

function Invoke-SupportIntakeChecks() {
  if (-not (Test-Path -LiteralPath $supportIntakeVerifier -PathType Leaf)) {
    throw "Missing required support intake verifier: scripts/verify-support-intake.ps1"
  }

  & $supportIntakeVerifier -RepoRoot $repoRoot
}

function Assert-RequirementOwnerException([object]$EvidenceCsv, [string]$Id, [string]$ExpectedRef) {
  Assert-RequirementEvidenceStatus $EvidenceCsv $Id "exception"
  $row = Get-RequirementEvidenceRow $EvidenceCsv $Id
  if ($row.exception_ref -ne $ExpectedRef) {
    throw "$($EvidenceCsv.RelativePath): '$Id' exception_ref must be '$ExpectedRef', got '$($row.exception_ref)'."
  }
  $exceptionPath = Join-Path $repoRoot $ExpectedRef
  if (-not (Test-Path -LiteralPath $exceptionPath -PathType Leaf)) {
    throw "$($EvidenceCsv.RelativePath): '$Id' exception_ref does not exist: '$ExpectedRef'."
  }
}

function Invoke-RequirementEvidenceRuleChecks() {
  # The requirements catalog lives in the private planning archive since the
  # public cutover. The public gate verifies the release evidence CSV's own
  # integrity; catalog alignment runs as the explicit maintainer-side gate
  # scripts/release/verify-requirement-catalog-alignment.ps1 against the
  # archived catalog.
  $requirementsEvidence = Read-RequiredCsv -RepoRoot $repoRoot -RelativePath "docs/release/requirements-release-evidence.csv" -Path $RequirementsEvidencePath

  Assert-RequirementReleaseEvidenceIntegrity $requirementsEvidence
  Assert-RequirementEvidenceRefsResolve -EvidenceCsv $requirementsEvidence -RepoRoot $repoRoot

  foreach ($id in @(
    "PRD-002",
    "PRD-003",
    "STA-003",
    "STA-006",
    "STA-011",
    "STA-013",
    "STA-015",
    "STA-016",
    "UX-001",
    "UX-007",
    "REP-013",
    "REP-014",
    "PRD-012",
    "SEC-001",
    "SEC-002",
    "SEC-003",
    "SEC-004",
    "SEC-005",
    "SEC-006",
    "SEC-007",
    "SEC-008",
    "SEC-009",
    "SEC-010",
    "SEC-011",
    "SEC-014",
    "OBS-005",
    "OBS-006",
    "OBS-007",
    "PRD-014",
    "COM-001",
    "COM-002",
    "OPS-004",
    "REP-001",
    "REP-002",
    "REP-003",
    "REP-004",
    "REP-006",
    "REP-007",
    "REP-008",
    "DIR-003",
    "DIR-009",
    "DIR-010",
    "DIR-012",
    "DIR-013",
    "DIR-019"
  )) {
    Assert-RequirementEvidenceStatus $requirementsEvidence $id "verified"
  }
  foreach ($id in @(
    "PRD-004",
    "PRD-006",
    "SEC-013",
    "STA-001",
    "STA-005",
    "STA-007",
    "STA-010",
    "STA-012",
    "STA-014",
    "ARC-011",
    "SYN-001",
    "OPS-001",
    "OPS-002",
    "OPS-003",
    "OPS-006",
    "OPS-007",
    "OPS-008",
    "DIF-001",
    "DIF-002",
    "DIF-003",
    "DIF-004",
    "HIS-001",
    "HIS-002",
    "HIS-003",
    "HIS-004",
    "HIS-005",
    "HIS-006",
    "HIS-007",
    "HIS-008",
    "HIS-009",
    "HIS-010",
    "DIR-002",
    "DIR-004",
    "DIR-005",
    "DIR-006",
    "DIR-007",
    "DIR-008",
    "DIR-011",
    "DIR-015",
    "DIR-020",
    "REP-005",
    "TOR-001",
    "TOR-002",
    "UX-002",
    "MIG-008",
    "MIG-011",
    "OBS-004",
    "BRM-001",
    "BRM-005"
  )) {
    Assert-RequirementEvidenceStatus $requirementsEvidence $id "partial"
  }
  foreach ($id in @(
    "BRM-004",
    "BRM-006",
    "BRM-008",
    "BRM-009",
    "SEC-012",
    "SEC-016",
    "TST-024"
  )) {
    Assert-RequirementEvidenceStatus $requirementsEvidence $id "blocked"
  }
  foreach ($id in @("SEC-015", "MIG-010", "MIG-012")) {
    Assert-RequirementOwnerException $requirementsEvidence $id "docs/release/marketplace-pre-release-owner-exception-0.2.4.md"
  }
  $marketplaceOwnerException = Read-RequiredDocument "docs/release/marketplace-pre-release-owner-exception-0.2.4.md"
  Assert-Terms $marketplaceOwnerException @(
    "# Marketplace 0.2.4 Pre-release Owner Exception",
    "public issues [#14]",
    "[#56]",
    'release tag: `v0.2.4-beta.1`',
    'asset name: `subversionr-win32-x64-0.2.4.vsix`',
    "880e7937423695ca772436f01e2419498463ebd7cc25ba8a283a135530418249",
    '`SEC-015`, `MIG-010`, and `MIG-012`',
    "It cannot transfer to different bytes, another tag, or a later version",
    "does not claim public release readiness"
  ) "Marketplace pre-release owner exception scope"

  [pscustomobject]@{
    RequirementsEvidence = $requirementsEvidence
  }
}

if ($Mode -eq "rule") {
  Invoke-RequirementEvidenceRuleChecks | Out-Null
  Write-Host "Release readiness rule checks passed."
  return
}

if ($Mode -eq "smoke") {
  Assert-PrFastWorkflow (Read-RequiredDocument ".github/workflows/pr-fast.yml")
  Assert-RetiredCloudflareBridgeDoc (Read-RequiredDocument "docs/ci/cloudflare-pr-fast-bridge.md")
  $null = Read-AndAssertArchitectureDecisionRecords
  Assert-GithubActionsRestorationDoc `
    (Read-RequiredDocument "docs/ci/github-actions-restoration.md")
  Assert-PublicCutoverRunbook `
    (Read-RequiredDocument "docs/release/public-cutover-runbook.md")
  [void](Read-RequiredDocument "docs/release/public-cutover-evidence.json")
  Invoke-SupportIntakeChecks
  Invoke-RequirementEvidenceRuleChecks | Out-Null
  Write-Host "Release readiness smoke checks passed."
  return
}

Invoke-SupportIntakeChecks

& (Join-Path $repoRoot "scripts\release\verify-product-version-consistency.ps1") `
  -RootPackagePath (Join-Path $repoRoot "package.json") `
  -ExtensionPackagePath (Join-Path $repoRoot "packages\vscode-extension\package.json") `
  -CargoWorkspaceManifestPath (Join-Path $repoRoot "Cargo.toml")

$rootPackageJson = Read-RequiredDocument "package.json"
$securityPolicy = Read-RequiredDocument "SECURITY.md"
$releaseGates = Read-RequiredDocument "docs/release/m7-release-readiness-gates.md"
$evidenceMatrix = Read-RequiredDocument "docs/release/security-evidence-matrix.md"
$publicClaimMatrix = Read-RequiredDocument "docs/release/public-claim-matrix.md"
$publicCutoverRunbook = Read-RequiredDocument "docs/release/public-cutover-runbook.md"
$publicCutoverEvidence = Read-RequiredDocument "docs/release/public-cutover-evidence.json"
$marketplaceIdentityBootstrapWorkflow = Read-RequiredDocument ".github/workflows/bootstrap-marketplace-identity.yml"
$attestationWorkflow = Read-RequiredDocument ".github/workflows/attest-release-vsix.yml"
$attestationContract = Read-RequiredDocument "docs/release/github-attestation-contract.win32-x64.json"
$attestationPredicateSchema = Read-RequiredDocument "docs/release/post-release-asset-verification-predicate.v1.schema.json"
$attestationBundle = Read-RequiredDocument "docs/release/github-attestation-bundle.win32-x64.json"
$attestationVerification = Read-RequiredDocument "docs/release/github-attestation-verification.win32-x64.json"
$liveAttestationEvidence = Read-RequiredDocument "docs/release/github-attestation-evidence.win32-x64.json"
$attestationSubjectVerifier = Read-RequiredDocument "scripts/release/verify-release-attestation-subject.ps1"
$attestationPredicateGenerator = Read-RequiredDocument "scripts/release/generate-post-release-asset-verification-predicate.ps1"
$liveAttestationRecorder = Read-RequiredDocument "scripts/release/record-live-github-attestation.ps1"
$liveAttestationScriptTests = Read-RequiredDocument "scripts/tests/release-live-attestation-scripts.tests.ps1"
$projectReadme = Read-RequiredDocument "README.md"
$publication023Evidence = Read-RequiredDocument "docs/release/0.2.3-publication-evidence.md"
$publication024Evidence = Read-RequiredDocument "docs/release/0.2.4-publication-evidence.md"
$engineeringHandoff = Read-RequiredDocument "docs/onboarding/ENGINEERING_HANDOFF.md"
$architectureDecisions = Read-AndAssertArchitectureDecisionRecords
$stableVsCodeApiAdr = $architectureDecisions["docs/adr/ADR-008-stable-vscode-apis.md"]
$credentialStorageAdr = $architectureDecisions["docs/adr/ADR-010-credential-storage.md"]
$m2Plan = Read-RequiredDocument "docs/plans/m2-repository-status-snapshot.md"
$m3Plan = Read-RequiredDocument "docs/plans/m3-dirty-path-status-engine.md"
$m4Plan = Read-RequiredDocument "docs/plans/m4-core-scm-operations.md"
$m5Plan = Read-RequiredDocument "docs/plans/m5-content-diff-history.md"
$m7Plan = Read-RequiredDocument "docs/plans/m7-release-publication.md"
$roadmap = Read-RequiredDocument "docs/roadmap/README.md"
$m6ToM7Decision = Read-RequiredDocument "docs/security/m6-to-m7-security-decision.md"
$supportChecklist = Read-RequiredDocument "docs/security/support-redaction-checklist.md"
$installedSourceControlSurfaceScript = Read-RequiredDocument "scripts/release/test-vscode-installed-source-control-surface.ps1"
$installedSourceControlSurfaceScriptTests = Read-RequiredDocument "scripts/tests/release-installed-source-control-surface-scripts.tests.ps1"
$installedSourceControlUiE2eScript = Read-RequiredDocument "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1"
$installedSourceControlUiE2eScriptTests = Read-RequiredDocument "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1"
$stateEngineBetaPerformanceScript = Read-RequiredDocument "scripts/release/test-state-engine-beta-performance.ps1"
$stateEngineBetaPerformanceScriptTests = Read-RequiredDocument "scripts/tests/release-state-engine-beta-performance-scripts.tests.ps1"
$stateEngineBetaPerformanceGateTests = Read-RequiredDocument "packages/vscode-extension/tests/stateEngineBetaPerformanceGate.test.ts"
$betaArtifactBundleManifestScript = Read-RequiredDocument "scripts/release/generate-beta-artifact-bundle-manifest.ps1"
$betaCandidateEvidenceScript = Read-RequiredDocument "scripts/release/verify-beta-candidate-evidence.ps1"
$betaCandidateEvidenceScriptTests = Read-RequiredDocument "scripts/tests/release-beta-candidate-evidence-scripts.tests.ps1"
$installRollbackFixtureScript = Read-RequiredDocument "scripts/release/test-vscode-install-rollback-fixture.ps1"
$installRollbackFixtureScriptTests = Read-RequiredDocument "scripts/tests/release-install-rollback-fixture.tests.ps1"
$extensionPackageJson = Read-RequiredDocument "packages/vscode-extension/package.json"
$extensionPackageNls = Read-RequiredDocument "packages/vscode-extension/package.nls.json"
$extensionPackageNlsJa = Read-RequiredDocument "packages/vscode-extension/package.nls.ja.json"
$extensionPackageNlsZhCn = Read-RequiredDocument "packages/vscode-extension/package.nls.zh-cn.json"
$extensionTsconfig = Read-RequiredDocument "packages/vscode-extension/tsconfig.json"
$extensionBundleL10n = Read-RequiredDocument "packages/vscode-extension/l10n/bundle.l10n.json"
$extensionBundleL10nJa = Read-RequiredDocument "packages/vscode-extension/l10n/bundle.l10n.ja.json"
$extensionBundleL10nZhCn = Read-RequiredDocument "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json"
$extensionEntrypoint = Read-RequiredDocument "packages/vscode-extension/src/extension.ts"
$extensionManifestTests = Read-RequiredDocument "packages/vscode-extension/tests/extensionManifest.test.ts"
$externalToolConfigurationSource = Read-RequiredDocument "packages/vscode-extension/src/security/externalToolConfiguration.ts"
$externalToolConfigurationTests = Read-RequiredDocument "packages/vscode-extension/tests/externalToolConfiguration.test.ts"
$tortoiseDetectorSource = Read-RequiredDocument "packages/vscode-extension/src/tortoise/tortoiseDetector.ts"
$tortoiseDetectorTests = Read-RequiredDocument "packages/vscode-extension/tests/tortoiseDetector.test.ts"
$tortoiseLauncherSource = Read-RequiredDocument "packages/vscode-extension/src/tortoise/tortoiseLauncher.ts"
$tortoiseLauncherTests = Read-RequiredDocument "packages/vscode-extension/tests/tortoiseLauncher.test.ts"
$tortoiseCommandControllerSource = Read-RequiredDocument "packages/vscode-extension/src/tortoise/tortoiseCommandController.ts"
$tortoiseCommandControllerTests = Read-RequiredDocument "packages/vscode-extension/tests/tortoiseCommandController.test.ts"
$installedSourceControlSurfaceReportSource = Read-RequiredDocument "packages/vscode-extension/src/diagnostics/installedSourceControlSurfaceReport.ts"
$installedSourceControlSurfaceReportTests = Read-RequiredDocument "packages/vscode-extension/tests/installedSourceControlSurfaceReport.test.ts"
$operationDiagnosticsSource = Read-RequiredDocument "packages/vscode-extension/src/diagnostics/operationDiagnostics.ts"
$operationDiagnosticsTests = Read-RequiredDocument "packages/vscode-extension/tests/operationDiagnostics.test.ts"
$installedRedactionReportTests = Read-RequiredDocument "packages/vscode-extension/tests/installedRedactionReport.test.ts"
$nativeBridgeTests = Read-RequiredDocument "crates/subversionr-daemon/tests/native_bridge.rs"
$nativeBridgeSource = Read-RequiredDocument "native/svn-bridge/src/subversionr_bridge.c"
$nativeBridgeRustSource = Read-RequiredDocument "crates/subversionr-daemon/src/native.rs"
$bridgeSource = Read-RequiredDocument "crates/subversionr-daemon/src/bridge.rs"
$daemonStateSource = Read-RequiredDocument "crates/subversionr-daemon/src/state.rs"
$protocolSource = Read-RequiredDocument "crates/subversionr-protocol/src/lib.rs"
$nativeBridgeHeader = Read-RequiredDocument "native/svn-bridge/include/subversionr_bridge.h"
$statusSnapshotRpcClientSource = Read-RequiredDocument "packages/vscode-extension/src/status/statusSnapshotRpcClient.ts"
$statusRefreshRpcClientSource = Read-RequiredDocument "packages/vscode-extension/src/status/statusRefreshRpcClient.ts"
$statusSnapshotStoreSource = Read-RequiredDocument "packages/vscode-extension/src/status/statusSnapshotStore.ts"
$watcherEventsSource = Read-RequiredDocument "packages/vscode-extension/src/status/watcherEvents.ts"
$dirtyPathSetSource = Read-RequiredDocument "packages/vscode-extension/src/status/dirtyPathSet.ts"
$statusRefreshSchedulerSource = Read-RequiredDocument "packages/vscode-extension/src/status/statusRefreshScheduler.ts"
$resourceStateClassifierSource = Read-RequiredDocument "packages/vscode-extension/src/scm/resourceStateClassifier.ts"
$sourceControlResourceStoreSource = Read-RequiredDocument "packages/vscode-extension/src/scm/sourceControlResourceStore.ts"
$sourceControlProjectionServiceSource = Read-RequiredDocument "packages/vscode-extension/src/scm/sourceControlProjectionService.ts"
$contentGetRpcClientSource = Read-RequiredDocument "packages/vscode-extension/src/content/contentGetRpcClient.ts"
$baseContentUriSource = Read-RequiredDocument "packages/vscode-extension/src/content/baseContentUri.ts"
$baseContentDocumentProviderSource = Read-RequiredDocument "packages/vscode-extension/src/content/baseContentDocumentProvider.ts"
$headContentUriSource = Read-RequiredDocument "packages/vscode-extension/src/content/headContentUri.ts"
$headContentDocumentProviderSource = Read-RequiredDocument "packages/vscode-extension/src/content/headContentDocumentProvider.ts"
$revisionContentUriSource = Read-RequiredDocument "packages/vscode-extension/src/content/revisionContentUri.ts"
$revisionContentDocumentProviderSource = Read-RequiredDocument "packages/vscode-extension/src/content/revisionContentDocumentProvider.ts"
$baseDiffResourceSource = Read-RequiredDocument "packages/vscode-extension/src/scm/baseDiffResource.ts"
$vscodeSourceControlPresenterSource = Read-RequiredDocument "packages/vscode-extension/src/scm/vscodeSourceControlPresenter.ts"
$repositoryCommandControllerSource = Read-RequiredDocument "packages/vscode-extension/src/repository/repositoryCommandController.ts"
$activeEditorContextServiceSource = Read-RequiredDocument "packages/vscode-extension/src/editor/activeEditorContextService.ts"
$historyTreeDataProviderSource = Read-RequiredDocument "packages/vscode-extension/src/history/historyTreeDataProvider.ts"
$historyLogRpcClientSource = Read-RequiredDocument "packages/vscode-extension/src/history/historyLogRpcClient.ts"
$historyBlameRpcClientSource = Read-RequiredDocument "packages/vscode-extension/src/history/historyBlameRpcClient.ts"
$historyBlameDocumentSource = Read-RequiredDocument "packages/vscode-extension/src/history/historyBlameDocument.ts"
$lineHistoryCommandControllerSource = Read-RequiredDocument "packages/vscode-extension/src/history/lineHistoryCommandController.ts"
$historySettingsSource = Read-RequiredDocument "packages/vscode-extension/src/history/historySettings.ts"
$historyOpenRevisionCommandSource = Read-RequiredDocument "packages/vscode-extension/src/history/historyOpenRevisionCommand.ts"
$historyCompareRevisionCommandSource = Read-RequiredDocument "packages/vscode-extension/src/history/historyCompareRevisionCommand.ts"
$historyRevisionDetailsDocumentSource = Read-RequiredDocument "packages/vscode-extension/src/history/historyRevisionDetailsDocument.ts"
$lensSettingsSource = Read-RequiredDocument "packages/vscode-extension/src/lens/lensSettings.ts"
$currentLineBlameStatusBarSource = Read-RequiredDocument "packages/vscode-extension/src/lens/currentLineBlameStatusBarService.ts"
$currentLineBlameHoverProviderSource = Read-RequiredDocument "packages/vscode-extension/src/lens/currentLineBlameHoverProvider.ts"
$symbolHistoryCodeLensProviderSource = Read-RequiredDocument "packages/vscode-extension/src/lens/symbolHistoryCodeLensProvider.ts"
$fileHeaderCodeLensProviderSource = Read-RequiredDocument "packages/vscode-extension/src/lens/fileHeaderCodeLensProvider.ts"
$rpcDispatchTests = Read-RequiredDocument "crates/subversionr-daemon/tests/rpc_dispatch.rs"
$stdioRpcTests = Read-RequiredDocument "crates/subversionr-daemon/tests/stdio_rpc.rs"
$protocolContractTests = Read-RequiredDocument "crates/subversionr-protocol/tests/protocol_contract.rs"
$statusSnapshotRpcClientTests = Read-RequiredDocument "packages/vscode-extension/tests/statusSnapshotRpcClient.test.ts"
$statusRefreshRpcClientTests = Read-RequiredDocument "packages/vscode-extension/tests/statusRefreshRpcClient.test.ts"
$statusSnapshotStoreTests = Read-RequiredDocument "packages/vscode-extension/tests/statusSnapshotStore.test.ts"
$watcherEventsTests = Read-RequiredDocument "packages/vscode-extension/tests/watcherEvents.test.ts"
$dirtyPathSetTests = Read-RequiredDocument "packages/vscode-extension/tests/dirtyPathSet.test.ts"
$dirtyPathPipelineTests = Read-RequiredDocument "packages/vscode-extension/tests/dirtyPathPipeline.test.ts"
$statusRefreshSchedulerTests = Read-RequiredDocument "packages/vscode-extension/tests/statusRefreshScheduler.test.ts"
$repositoryWatcherServiceTests = Read-RequiredDocument "packages/vscode-extension/tests/repositoryWatcherService.test.ts"
$resourceStateClassifierTests = Read-RequiredDocument "packages/vscode-extension/tests/scmResourceStateClassifier.test.ts"
$sourceControlResourceStoreTests = Read-RequiredDocument "packages/vscode-extension/tests/sourceControlResourceStore.test.ts"
$sourceControlProjectionServiceTests = Read-RequiredDocument "packages/vscode-extension/tests/sourceControlProjectionService.test.ts"
$contentGetRpcClientTests = Read-RequiredDocument "packages/vscode-extension/tests/contentGetRpcClient.test.ts"
$baseContentUriTests = Read-RequiredDocument "packages/vscode-extension/tests/baseContentUri.test.ts"
$baseContentDocumentProviderTests = Read-RequiredDocument "packages/vscode-extension/tests/baseContentDocumentProvider.test.ts"
$headContentUriTests = Read-RequiredDocument "packages/vscode-extension/tests/headContentUri.test.ts"
$headContentDocumentProviderTests = Read-RequiredDocument "packages/vscode-extension/tests/headContentDocumentProvider.test.ts"
$revisionContentUriTests = Read-RequiredDocument "packages/vscode-extension/tests/revisionContentUri.test.ts"
$revisionContentDocumentProviderTests = Read-RequiredDocument "packages/vscode-extension/tests/revisionContentDocumentProvider.test.ts"
$baseDiffResourceTests = Read-RequiredDocument "packages/vscode-extension/tests/baseDiffResource.test.ts"
$vscodeSourceControlPresenterTests = Read-RequiredDocument "packages/vscode-extension/tests/vscodeSourceControlPresenter.test.ts"
$activeEditorContextServiceTests = Read-RequiredDocument "packages/vscode-extension/tests/activeEditorContextService.test.ts"
$historyTreeDataProviderTests = Read-RequiredDocument "packages/vscode-extension/tests/historyTreeDataProvider.test.ts"
$historyLogRpcClientTests = Read-RequiredDocument "packages/vscode-extension/tests/historyLogRpcClient.test.ts"
$historyBlameRpcClientTests = Read-RequiredDocument "packages/vscode-extension/tests/historyBlameRpcClient.test.ts"
$historyBlameDocumentTests = Read-RequiredDocument "packages/vscode-extension/tests/historyBlameDocument.test.ts"
$lineHistoryCommandControllerTests = Read-RequiredDocument "packages/vscode-extension/tests/lineHistoryCommandController.test.ts"
$historySettingsTests = Read-RequiredDocument "packages/vscode-extension/tests/historySettings.test.ts"
$historyOpenRevisionCommandTests = Read-RequiredDocument "packages/vscode-extension/tests/historyOpenRevisionCommand.test.ts"
$historyCompareRevisionCommandTests = Read-RequiredDocument "packages/vscode-extension/tests/historyCompareRevisionCommand.test.ts"
$historyRevisionDetailsDocumentTests = Read-RequiredDocument "packages/vscode-extension/tests/historyRevisionDetailsDocument.test.ts"
$lensSettingsTests = Read-RequiredDocument "packages/vscode-extension/tests/lensSettings.test.ts"
$currentLineBlameStatusBarTests = Read-RequiredDocument "packages/vscode-extension/tests/currentLineBlameStatusBarService.test.ts"
$currentLineBlameHoverProviderTests = Read-RequiredDocument "packages/vscode-extension/tests/currentLineBlameHoverProvider.test.ts"
$symbolHistoryCodeLensProviderTests = Read-RequiredDocument "packages/vscode-extension/tests/symbolHistoryCodeLensProvider.test.ts"
$fileHeaderCodeLensProviderTests = Read-RequiredDocument "packages/vscode-extension/tests/fileHeaderCodeLensProvider.test.ts"
$backendProcessSource = Read-RequiredDocument "packages/vscode-extension/src/backend/backendProcess.ts"
$packagedNativeProbe = Read-RequiredDocument "scripts/release/probe-vscode-packaged-native.mjs"
$packagedNativeProbeVerifier = Read-RequiredDocument "scripts/release/verify-packaged-native-compatibility.ps1"
$stageVscodePackageLayout = Read-RequiredDocument "scripts/release/stage-vscode-package-layout.ps1"
$verifyVscodePackageLayout = Read-RequiredDocument "scripts/release/verify-vscode-package-layout.ps1"
$packageVscodeVsix = Read-RequiredDocument "scripts/release/package-vscode-vsix.ps1"
$releaseScriptTests = Read-RequiredDocument "scripts/tests/release-scripts.tests.ps1"
$releaseVsixScriptTests = Read-RequiredDocument "scripts/tests/release-vsix-scripts.tests.ps1"
$betaCandidateOrchestration = Read-RequiredDocument "scripts/release/run-beta-candidate-evidence.ps1"
$productVersionVerifier = Read-RequiredDocument "scripts/release/verify-product-version-consistency.ps1"
$backendProcessTests = Read-RequiredDocument "packages/vscode-extension/tests/backendProcess.test.ts"
$cacheLifecycleSource = Read-RequiredDocument "packages/vscode-extension/src/cache/cacheLifecycleService.ts"
$cacheLifecycleTests = Read-RequiredDocument "packages/vscode-extension/tests/cacheLifecycleService.test.ts"
$cacheCommandControllerSource = Read-RequiredDocument "packages/vscode-extension/src/cache/cacheCommandController.ts"
$cacheCommandControllerTests = Read-RequiredDocument "packages/vscode-extension/tests/cacheCommandController.test.ts"
$operationRunRpcClientSource = Read-RequiredDocument "packages/vscode-extension/src/operations/operationRunRpcClient.ts"
$operationRunRpcClientTests = Read-RequiredDocument "packages/vscode-extension/tests/operationRunRpcClient.test.ts"
$repositoryCommandControllerTests = Read-RequiredDocument "packages/vscode-extension/tests/repositoryCommandController.test.ts"
$repositoryDiscoveryServiceTests = Read-RequiredDocument "packages/vscode-extension/tests/repositoryDiscoveryService.test.ts"
$repositoryLifecycleSource = Read-RequiredDocument "packages/vscode-extension/src/repository/repositoryLifecycleService.ts"
$repositorySessionSource = Read-RequiredDocument "packages/vscode-extension/src/repository/repositorySessionService.ts"
$repositoryLifecycleServiceTests = Read-RequiredDocument "packages/vscode-extension/tests/repositoryLifecycleService.test.ts"
$repositoryLifecycleTests = Read-RequiredDocument "packages/vscode-extension/tests/repositoryLifecycleService.test.ts"
$repositorySessionTests = Read-RequiredDocument "packages/vscode-extension/tests/repositorySessionService.test.ts"
$ciWorkflow = Read-RequiredDocument ".github/workflows/ci.yml"
$releaseBuildEpoch = Read-RequiredDocument "native/release-build-epoch.txt"
$fastPrWorkflow = Read-RequiredDocument ".github/workflows/pr-fast.yml"
$cloudflarePrFastBridgeDoc = Read-RequiredDocument "docs/ci/cloudflare-pr-fast-bridge.md"
$githubActionsRestorationDoc = Read-RequiredDocument "docs/ci/github-actions-restoration.md"
$readinessRules = Invoke-RequirementEvidenceRuleChecks
$requirementsEvidence = $readinessRules.RequirementsEvidence
Assert-RequirementEvidenceRefs $requirementsEvidence "COM-001" @(
  "docs/plans/m4-core-scm-operations.md",
  "packages/vscode-extension/src/scm/sourceControlResourceStore.ts",
  "packages/vscode-extension/tests/sourceControlResourceStore.test.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "packages/vscode-extension/src/scm/vscodeSourceControlPresenter.ts",
  "packages/vscode-extension/tests/vscodeSourceControlPresenter.test.ts",
  "packages/vscode-extension/src/repository/commitAllCommandArgument.ts",
  "packages/vscode-extension/tests/commitAllCommandArgument.test.ts",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1"
)
Assert-Terms $m4Plan @(
  "M4l Implemented Slice",
  "subversionr.commitAll",
  "acceptInputCommand",
  "Commit All derives its targets",
  "Successful Commit All clears only the matching repository input box"
) "COM-001 M4l product plan coverage"
Assert-Terms $sourceControlResourceStoreSource @(
  "commitAllTargetsFromState",
  "isCommitAllCandidate",
  "ignoredChangelists",
  "hasConflicts"
) "COM-001 SourceControl target derivation coverage"
Assert-Terms $repositoryCommandControllerTests @(
  "commits all eligible changed file resources for the repository input message",
  "blocks Commit All when the current projection contains unresolved conflicts",
  "warns and preserves the message when Commit All has no eligible changed file resources"
) "COM-001 repository command behavior coverage"
Assert-Terms $installedSourceControlUiE2eScript @(
  "runCommitAllWorkflow",
  "sourceControlUiCommitAllWorkflow",
  "subversionr.installedSourceControlUiE2eCommitAllWorkflow",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_COMMIT_ALL_WORKING_COPY",
  "acceptInputCommandArguments",
  "Get-CommitAllRepositoryOracle",
  "commitAllRepositoryOracle",
  "subversionr.installedSourceControlUiE2eCommitAllRepositoryOracle",
  "initialCliRevisionAuthorNonEmpty",
  "committedRevisionAuthorNonEmpty",
  "committedRevisionAuthorMatchedInitialCliRevision",
  "inputMessageClearedAfterCommit",
  "targetedReconcileAfterCommit"
) "COM-001 installed Commit All E2E evidence fields"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "sourceControlUiCommitAllWorkflow",
  "hasCommitAllCommand",
  "hasInstalledSourceControlUiE2eSetInputMessageCommand",
  "acceptInputCommandArguments",
  "commitAllRepositoryOracle",
  "initialCliRevisionAuthorNonEmpty",
  "committedRevisionAuthorNonEmpty",
  "committedRevisionAuthorMatchedInitialCliRevision",
  "unversionedScratchAbsentFromRepository",
  "inputMessageClearedAfterCommit",
  "targetedReconcileAfterCommit"
) "COM-001 installed Commit All E2E script-test evidence"
Assert-RequirementEvidenceRefs $requirementsEvidence "COM-002" @(
  "docs/plans/m4-core-scm-operations.md",
  "crates/subversionr-protocol/tests/protocol_contract.rs",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/src/bridge.rs",
  "crates/subversionr-daemon/src/native.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "native/svn-bridge/include/subversionr_bridge.h",
  "native/svn-bridge/src/subversionr_bridge.c",
  "packages/vscode-extension/src/operations/operationRunRpcClient.ts",
  "packages/vscode-extension/tests/operationRunRpcClient.test.ts",
  "packages/vscode-extension/src/operations/backendOperationClient.ts",
  "packages/vscode-extension/tests/backendOperationClient.test.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1"
)
Assert-Terms $m4Plan @(
  "M4j Implemented Slice",
  "M4k Implemented Slice",
  "subversionr.commitResource",
  "Commit Selected command",
  "multiple selected file targets"
) "COM-002 M4j/M4k product plan coverage"
Assert-Terms $extensionPackageJson @(
  "onCommand:subversionr.commitResource",
  "command.commitResource.title",
  "scmProvider == svn-r && isWorkspaceTrusted && scmResourceState =~ /^subversionr\\.changedFile(\\.changelisted)?(\\.locked)?$/",
  "scmProvider == svn-r && isWorkspaceTrusted && scmResourceState =~ /^subversionr\\.changedFile\\.baseDiffable(\\.changelisted)?(\\.locked)?$/"
) "COM-002 extension manifest command coverage"
Assert-Terms $extensionManifestTests @(
  "onCommand:subversionr.commitResource",
  "command.commitResource.title",
  "subversionr.commitResource",
  'resourceStateWhenMatches(entry.when ?? "", "subversionr.changedFile.baseDiffable")',
  ').toContain("subversionr.commitResource")'
) "COM-002 extension manifest test coverage"
Assert-Terms $protocolContractTests @(
  "operation_run_commit",
  "operation_run_commit_multi_path",
  "operation_run_response_serializes_commit_result_contract",
  "src/main.c"
) "COM-002 protocol commit contract coverage"
Assert-Terms $operationRunRpcClientTests @(
  "sends operation/run commit with multiple explicit file paths and returns targeted reconcile hints",
  "fails fast on invalid commit request field",
  "touchedPaths: [""src/main.c"", ""src/other.c""]",
  "paths: [""src/main.c"", ""src/other.c""]"
) "COM-002 TypeScript operation/run commit coverage"
Assert-Terms $rpcDispatchTests @(
  "operation_run_commit_accepts_multiple_file_paths_and_returns_targeted_reconcile_hints",
  "commit selected files",
  '"paths":["src/main.c","src/other.c"]',
  "operation_run_commit_forwards_single_file_options_to_bridge"
) "COM-002 daemon commit dispatch coverage"
Assert-Terms $repositoryCommandControllerTests @(
  "commits a selected changed SCM resource with the repository input message",
  "commits multiple selected changed file resources from one repository with the repository input message",
  "rejects selected commit resources that span open repositories",
  "rejects duplicate selected commit resources using the repository path case policy"
) "COM-002 repository command behavior coverage"
Assert-Terms $installedSourceControlUiE2eScript @(
  "runCommitSelectedWorkflow",
  "sourceControlUiCommitSelectedWorkflow",
  "subversionr.installedSourceControlUiE2eCommitSelectedWorkflow",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_COMMIT_SELECTED_WORKING_COPY",
  "Get-CommitSelectedRepositoryOracle",
  "commitSelectedRepositoryOracle",
  "subversionr.installedSourceControlUiE2eCommitSelectedRepositoryOracle",
  "unselectedFileStillModified",
  "targetedReconcileAfterCommit"
) "COM-002 installed Commit Selected E2E evidence fields"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "sourceControlUiCommitSelectedWorkflow",
  "hasCommitResourceCommand",
  "commitSelectedRepositoryOracle",
  "unselectedFileStillModified",
  "Get-CommitSelectedRepositoryOracle",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_COMMIT_SELECTED_WORKING_COPY"
) "COM-002 installed Commit Selected E2E script-test evidence"
Assert-RequirementEvidenceRefs $requirementsEvidence "SYN-001" @(
  "docs/plans/m4-core-scm-operations.md",
  "packages/vscode-extension/src/extension.ts",
  "crates/subversionr-protocol/src/lib.rs",
  "crates/subversionr-protocol/tests/protocol_contract.rs",
  "crates/subversionr-daemon/src/bridge.rs",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/src/native.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/tests/stdio_rpc.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "native/svn-bridge/include/subversionr_bridge.h",
  "native/svn-bridge/src/subversionr_bridge.c",
  "packages/vscode-extension/src/operations/operationRunRpcClient.ts",
  "packages/vscode-extension/tests/operationRunRpcClient.test.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/package.nls.json",
  "packages/vscode-extension/package.nls.ja.json",
  "packages/vscode-extension/package.nls.zh-cn.json",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "SYN-003" @(
  "crates/subversionr-protocol/src/lib.rs",
  "crates/subversionr-protocol/tests/protocol_contract.rs",
  "crates/subversionr-daemon/src/bridge.rs",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/src/native.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "native/svn-bridge/include/subversionr_bridge.h",
  "native/svn-bridge/src/subversionr_bridge.c",
  "packages/vscode-extension/src/operations/operationRunRpcClient.ts",
  "packages/vscode-extension/tests/operationRunRpcClient.test.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "packages/vscode-extension/src/repository/updateRevisionInput.ts",
  "packages/vscode-extension/tests/updateRevisionInput.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "SYN-004" @(
  "crates/subversionr-protocol/src/lib.rs",
  "crates/subversionr-protocol/tests/protocol_contract.rs",
  "crates/subversionr-daemon/src/bridge.rs",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/src/native.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "native/svn-bridge/include/subversionr_bridge.h",
  "native/svn-bridge/src/subversionr_bridge.c",
  "packages/vscode-extension/src/operations/operationRunRpcClient.ts",
  "packages/vscode-extension/tests/operationRunRpcClient.test.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "packages/vscode-extension/src/repository/updateRevisionInput.ts",
  "packages/vscode-extension/tests/updateRevisionInput.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "SYN-005" @(
  "crates/subversionr-protocol/src/lib.rs",
  "crates/subversionr-protocol/tests/protocol_contract.rs",
  "crates/subversionr-daemon/src/bridge.rs",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/src/native.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "native/svn-bridge/include/subversionr_bridge.h",
  "native/svn-bridge/src/subversionr_bridge.c",
  "packages/vscode-extension/src/operations/operationRunRpcClient.ts",
  "packages/vscode-extension/tests/operationRunRpcClient.test.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "packages/vscode-extension/src/repository/updateRevisionInput.ts",
  "packages/vscode-extension/tests/updateRevisionInput.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1"
)
Assert-Terms $m4Plan @(
  "M4g Implemented Slice",
  'path = "."',
  'revision = "head"',
  'depth = "workingCopy"',
  "ignoreExternals = true",
  "operationRunUpdate",
  "subversionr_bridge_operation_update",
  "svn_client_update4",
  "always returns a full-reconcile hint",
  "subversionr.updateRepository"
) "SYN-001 M4g root update plan coverage"
Assert-Terms $protocolSource @(
  "operation_run_update: true",
  "operation_run_update_to_revision: true",
  "operation_run_update_depth: true",
  "operation_run_update_externals_policy: true"
) "SYN-001 protocol root update capability"
Assert-Terms $protocolContractTests @(
  "operation_run_update",
  "operation_run_update_to_revision",
  'assert_eq!(json["capabilities"]["operationRunUpdate"], true)',
  'assert_eq!(json["capabilities"]["operationRunUpdateToRevision"], true)',
  'assert_eq!(json["capabilities"]["operationRunUpdateDepth"], true)',
  "operationRunUpdateExternalsPolicy"
) "SYN-001 protocol root update capability tests"
Assert-Terms $daemonStateSource @(
  "ParsedOperation::Update(update_request)",
  "operation_update_with_cancellation",
  "operationUpdateRequiresFullReconcile",
  "operationUpdateFailed",
  "fn update_options",
  '"version" | "path" | "revision" | "depth" | "depthIsSticky" | "ignoreExternals"',
  "update_revision_value",
  "valid_update_depth",
  'depth == "workingCopy" && depth_is_sticky',
  "ignore_externals"
) "SYN-001 daemon root update parsing and dispatch coverage"
Assert-Terms $bridgeSource @(
  "pub struct UpdateOperationRequest",
  "pub struct UpdateOperationResult",
  "fn operation_update(",
  "fn operation_update_with_cancellation",
  "Result<UpdateOperationResult, BridgeFailure>"
) "SYN-001 daemon bridge update abstraction"
Assert-Terms $rpcDispatchTests @(
  "operation_run_update_returns_revision_and_full_reconcile_hint",
  "operation_run_update_forwards_head_working_copy_options_to_bridge",
  "operation_run_update_forwards_revision_depth_and_externals_options_to_bridge",
  '"path":"src","revision":42,"depth":"files","depthIsSticky":true,"ignoreExternals":false',
  '"path":".","revision":"head","depth":"workingCopy","depthIsSticky":false,"ignoreExternals":true',
  "operationUpdateRequiresFullReconcile",
  "operation_run_update_maps_bridge_failure_to_structured_error"
) "SYN-001 daemon root update dispatch tests"
Assert-Terms $stdioRpcTests @(
  "stdio_loop_routes_update_operation_through_credential_broker",
  "operationUpdateRequiresFullReconcile",
  "stdio_loop_marks_status_stale_after_update_operation_failure",
  "operationUpdateFailed",
  "credential challenges"
) "SYN-001 stdio root update credential and failure routing tests"
Assert-Terms $nativeBridgeHeader @(
  "subversionr_bridge_operation_update",
  "result_revision"
) "SYN-001 native update ABI"
Assert-Terms $nativeBridgeSource @(
  "subversionr_bridge_operation_update",
  "svn_client_update4",
  "svn_opt_revision_head",
  "svn_opt_revision_number",
  "bridge_update_revision",
  "bridge_update_depth_from_word",
  "bridge_operation_notify",
  "result_revision"
) "SYN-001 libsvn root update implementation"
Assert-Terms $nativeBridgeRustSource @(
  "fn operation_update_with_cancellation",
  "valid_update_revision(&request.revision)",
  "valid_update_depth(&request.depth)",
  'request.depth == "workingCopy" && request.depth_is_sticky',
  "update_scan_path(&identity.working_copy_root, &request.path)",
  "operation_update_failure"
) "SYN-001 Rust native update bridge"
Assert-Terms $nativeBridgeTests @(
  "native_bridge_update_root_to_head_applies_remote_change_and_reports_revision",
  "native_bridge_update_root_to_numbered_revision_restores_historical_content",
  "native_bridge_update_with_sparse_sticky_depth_keeps_children_absent",
  "native_bridge_update_includes_externals_when_requested",
  'revision: "2".to_string()',
  'depth: "empty".to_string()',
  "depth_is_sticky: true",
  "ignore_externals: false",
  "operation_update(",
  'path: ".".to_string()',
  'revision: "head".to_string()',
  'depth: "workingCopy".to_string()',
  "ignore_externals: true",
  'fixture.read_file("tracked.txt"), "remote\n"'
) "SYN-001 native root update fixture"
Assert-Terms $operationRunRpcClientSource @(
  "export interface UpdateOperationRequest",
  'export type UpdateOperationRevision = "head" | number',
  'export type UpdateOperationDepth = "workingCopy" | StatusRefreshDepth',
  "depthIsSticky: boolean",
  "ignoreExternals: boolean",
  "public async update",
  'kind: "update"',
  "requireUpdateRevision",
  "requireUpdateDepth",
  "requireOperationMatchesRequest(response, validatedRequest, `"update`")",
  "invalidOperationResponse(`"reconcile.requiresFullReconcile`")",
  "invalidOperationResponse(`"revision`")"
) "SYN-001 TypeScript operation/run update client source"
Assert-Terms $operationRunRpcClientTests @(
  "sends operation/run update with explicit root options and returns the parsed full-reconcile result",
  "passes cancellation signals to update operation/run requests",
  "sends operation/run update with numeric revision, sparse depth, sticky depth, and externals policy",
  'path: "."',
  'revision: "head"',
  "revision: 42",
  'depth: "workingCopy"',
  'depth: "files"',
  "depthIsSticky: false",
  "depthIsSticky: true",
  "ignoreExternals: true",
  "ignoreExternals: false",
  "fails fast on invalid update request field: %s",
  "rejects update responses without a resolved revision"
) "SYN-001 TypeScript operation/run update client tests"
Assert-Terms $repositoryCommandControllerSource @(
  "public async updateRepository(repositoryId?: unknown): Promise<void>",
  "public async updateToRevision(repositoryId?: unknown): Promise<void>",
  "this.requireTrustedWorkspace()",
  "HEAD_WORKING_COPY_UPDATE_OPTIONS",
  "validateRepositoryUpdateOptions(updateOptions)",
  "childWorkingCopySessions",
  "!updateOptions.ignoreExternals",
  "refreshService.fullReconcileRepository",
  "SubversionR updated SVN working copy to revision {0}: {1}"
) "SYN-001 VS Code root update command source"
Assert-Terms $repositoryCommandControllerTests @(
  "runs update for the selected repository session and performs a full reconcile",
  "runs repository update through cancellable operation progress and forwards the progress signal",
  "always runs full reconcile after update even if the backend returns targeted update hints",
  "runs update to a revision with explicit depth and externals options",
  "fully reconciles opened child working copies after including externals in an update",
  "requires an explicit repository choice before update with multiple open sessions",
  "records a successful repository update in the sanitized operation journal",
  "records a cancelled repository update in the sanitized operation journal",
  "SubversionR updated SVN working copy to revision 8: C:\\workspace"
) "SYN-001 VS Code root update command tests"
Assert-Terms $extensionEntrypoint @(
  'registerCommand("subversionr.updateRepository"',
  'registerCommand("subversionr.updateToRevision"',
  "repositoryCommandController.updateRepository("
) "SYN-001 extension command registration"
Assert-Terms $extensionPackageJson @(
  "onCommand:subversionr.updateRepository",
  "onCommand:subversionr.updateToRevision",
  "command.updateRepository.title",
  "command.updateToRevision.title",
  '"command": "subversionr.updateRepository"'
) "SYN-001 extension manifest root update command"
Assert-Terms $extensionManifestTests @(
  "onCommand:subversionr.updateRepository",
  "onCommand:subversionr.updateToRevision",
  "command.updateRepository.title",
  "command.updateToRevision.title",
  "subversionr.updateRepository",
  "subversionr.updateToRevision",
  "Updating SVN working copy"
) "SYN-001 extension manifest root update tests"
Assert-Terms $installedSourceControlUiE2eScript @(
  "sourceControlUiUpdateToRevisionWorkflow",
  "subversionr.installedSourceControlUiE2eUpdateToRevisionWorkflow",
  "updateToRevisionRepositoryOracle",
  "subversionr.installedSourceControlUiE2eUpdateToRevisionRepositoryOracle",
  "subversionr.updateToRevision",
  "hasUpdateRepositoryCommand",
  "hasUpdateToRevisionCommand",
  "updateRevisionPromptCapture",
  "updateDepthPromptCapture",
  "updateStickyDepthPromptCapture",
  "updateExternalsPromptCapture",
  "sourceControlUiUpdateToRevisionCancellationWorkflow",
  "subversionr.installedSourceControlUiE2eUpdateToRevisionCancellationWorkflow",
  "updateCancellationRevisionPromptCapture",
  "requestedRevision",
  "requestedDepth",
  "requestedStickyDepth",
  "requestedIgnoreExternals",
  "updatedRevisionContentApplied",
  "postUpdateReconcileCompleted",
  "sourceControlProjectionAvailable",
  "targetContentUnchangedAfterCancellation",
  "requestedRevisionContentNotApplied",
  "does not prove remote update failures, auth/certificate update flows, backend update failure UX, mixed-revision edge analysis, or load-scale update behavior"
) "SYN-001/SYN-003/SYN-004/SYN-005 installed Update to Revision UI E2E evidence"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "sourceControlUiUpdateToRevisionWorkflow",
  "subversionr.installedSourceControlUiE2eUpdateToRevisionWorkflow",
  "sourceControlUiUpdateToRevisionCancellationWorkflow",
  "subversionr.installedSourceControlUiE2eUpdateToRevisionCancellationWorkflow",
  "updateToRevisionRepositoryOracle",
  "subversionr.installedSourceControlUiE2eUpdateToRevisionRepositoryOracle",
  "subversionr.updateToRevision",
  "hasUpdateRepositoryCommand",
  "hasUpdateToRevisionCommand",
  "updateRevisionPromptCapture",
  "updateCancellationRevisionPromptCapture",
  "updateDepthPromptCapture",
  "updateStickyDepthPromptCapture",
  "updateExternalsPromptCapture",
  "updatedRevisionContentApplied",
  "targetContentUnchangedAfterCancellation",
  "postUpdateReconcileCompleted",
  "Update to Revision revision prompt capture should type the requested revision",
  "Update to Revision cancellation prompt capture should cancel the revision QuickInput with Escape",
  "Update to Revision depth prompt capture should select Files depth",
  "Update to Revision sticky depth prompt capture should select sticky depth",
  "Update to Revision externals prompt capture should select Include externals"
) "SYN-001/SYN-003/SYN-004/SYN-005 installed Update to Revision UI E2E script-test evidence"
Assert-Terms $extensionPackageNls @(
  '"command.updateRepository.title": "SubversionR: Update Working Copy"'
) "SYN-001 English package NLS root update title"
Assert-Terms $extensionPackageNlsJa @(
  '"command.updateRepository.title": "SubversionR: 作業コピーを更新"'
) "SYN-001 Japanese package NLS root update title"
Assert-Terms $extensionPackageNlsZhCn @(
  '"command.updateRepository.title": "SubversionR: 更新工作副本"'
) "SYN-001 Chinese package NLS root update title"
Assert-Terms $extensionBundleL10n @(
  '"Updating SVN working copy": "Updating SVN working copy"',
  '"SubversionR updated SVN working copy to revision {0}: {1}": "SubversionR updated SVN working copy to revision {0}: {1}"'
) "SYN-001 English runtime localization"
Assert-Terms $extensionBundleL10nJa @(
  '"Updating SVN working copy": "SVN 作業コピーを更新しています"'
) "SYN-001 Japanese runtime localization"
Assert-Terms $extensionBundleL10nZhCn @(
  '"Updating SVN working copy": "正在更新 SVN 工作副本"'
) "SYN-001 Chinese runtime localization"
Assert-RequirementEvidenceRefs $requirementsEvidence "STA-016" @(
  "docs/plans/m4-core-scm-operations.md",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1"
)
Assert-Terms $m4Plan @(
  "The command accepts VS Code SCM single-resource and multi-selection argument shapes for selected resources in one open working copy.",
  'The SCM resource command accepts VS Code multi-selection arguments for `subversionr.commitResource`',
  "Add, Remove, Keep-local Remove, and Revert also accept selected multi-resource arguments",
  "Repository command tests cover SCM multi-selection commit"
) "STA-016 product plan multi-selection coverage"
Assert-Terms $extensionEntrypoint @(
  "commitResource(...resourceStates)",
  "addResource(...resourceStates)",
  "removeResource(...resourceStates)",
  "removeResourceKeepLocal(...resourceStates)",
  "revertResource(...resourceStates)"
) "STA-016 extension resource command multi-selection argument forwarding"
Assert-Terms $extensionPackageJson @(
  "onCommand:subversionr.commitResource",
  "onCommand:subversionr.addResource",
  "onCommand:subversionr.removeResource",
  "onCommand:subversionr.removeResourceKeepLocal",
  "onCommand:subversionr.revertResource"
) "STA-016 extension manifest resource command activation coverage"
Assert-Terms $extensionManifestTests @(
  "subversionr.commitResource",
  "subversionr.addResource",
  "subversionr.removeResource",
  "subversionr.removeResourceKeepLocal",
  "subversionr.revertResource"
) "STA-016 extension manifest test resource command coverage"
Assert-Terms $repositoryCommandControllerTests @(
  "commits multiple selected changed file resources from one repository with the repository input message",
  "adds selected unversioned files and directories with SVN-appropriate depths",
  "confirms and removes multiple selected changed SCM resources through one operation/run request",
  "confirms and removes multiple selected changed SCM resources while keeping local content",
  "confirms and reverts multiple selected changed SCM resources through one operation/run request",
  "rejects duplicate selected paths for `$label before confirmation or operation/run",
  "rejects mixed repository selected paths for `$label before confirmation or operation/run",
  "rejects stale projection generations for `$label before confirmation or operation/run"
) "STA-016 repository command multi-selection behavior and validation coverage"
Assert-Terms $installedSourceControlUiE2eScript @(
  "runCommitSelectedMultiSelectionWorkflow",
  "sourceControlUiCommitSelectedMultiSelectionWorkflow",
  "subversionr.installedSourceControlUiE2eCommitSelectedMultiSelectionWorkflow",
  "resourceStateArray",
  "Get-CommitSelectedMultiSelectionRepositoryOracle",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_COMMIT_SELECTED_MULTI_SELECTION_WORKING_COPY",
  "allSelectedFilesCommitted",
  "sourceControlProjectionClearedSelectedPaths",
  "targetedReconcileAfterCommit",
  "STA-016"
) "STA-016 installed SCM multi-selection E2E evidence fields"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "sourceControlUiCommitSelectedMultiSelectionWorkflow",
  "resourceStateArray",
  "Get-CommitSelectedMultiSelectionRepositoryOracle",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_COMMIT_SELECTED_MULTI_SELECTION_WORKING_COPY",
  "allSelectedFilesCommitted",
  "Commit Selected multi-selection"
) "STA-016 installed SCM multi-selection E2E script-test evidence"
Assert-RequirementEvidenceRefs $requirementsEvidence "PRD-002" @(
  "packages/vscode-extension/tests/statusRefreshScheduler.test.ts",
  "packages/vscode-extension/tests/dirtyPathPipeline.test.ts",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "PRD-003" @(
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/l10n/bundle.l10n.json"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "PRD-004" @(
  "docs/release/m7-release-readiness-gates.md",
  "docs/release/public-claim-matrix.md",
  "packages/vscode-extension/src/security/externalToolConfiguration.ts",
  "packages/vscode-extension/tests/externalToolConfiguration.test.ts",
  "packages/vscode-extension/src/tortoise/tortoiseDetector.ts",
  "packages/vscode-extension/tests/tortoiseDetector.test.ts",
  "packages/vscode-extension/src/tortoise/tortoiseCommandController.ts",
  "packages/vscode-extension/tests/tortoiseCommandController.test.ts",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "TOR-001" @(
  "packages/vscode-extension/src/security/externalToolConfiguration.ts",
  "packages/vscode-extension/tests/externalToolConfiguration.test.ts",
  "packages/vscode-extension/src/tortoise/tortoiseDetector.ts",
  "packages/vscode-extension/tests/tortoiseDetector.test.ts",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "TOR-002" @(
  "docs/release/m7-release-readiness-gates.md",
  "docs/release/public-claim-matrix.md",
  "docs/release/security-evidence-matrix.md",
  "packages/vscode-extension/src/security/externalToolConfiguration.ts",
  "packages/vscode-extension/tests/externalToolConfiguration.test.ts",
  "packages/vscode-extension/src/tortoise/tortoiseDetector.ts",
  "packages/vscode-extension/tests/tortoiseDetector.test.ts",
  "packages/vscode-extension/src/tortoise/tortoiseLauncher.ts",
  "packages/vscode-extension/tests/tortoiseLauncher.test.ts",
  "packages/vscode-extension/src/tortoise/tortoiseCommandController.ts",
  "packages/vscode-extension/tests/tortoiseCommandController.test.ts",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "packages/vscode-extension/l10n/bundle.l10n.json"
)
Assert-Terms $m7Plan @(
  "The fifth M7 slice implements the first optional TortoiseSVN GUI handoff without changing core SVN semantics",
  'Core SubversionR workflows continue to use the packaged Rust sidecar and source-built `libsvn`.',
  'Missing TortoiseSVN reports capability unavailable, hides contributed Tortoise menus through `subversionr.tortoiseAvailable`',
  'The launch adapter maps structured read-only intents to allowlisted `TortoiseProc.exe` arguments'
) "TortoiseSVN public integration plan coverage"
Assert-Terms $externalToolConfigurationSource @(
  "subversionr.tortoise.executablePath",
  "subversionr.tortoise.configDirectory",
  "requireExternalToolExecutionTrusted",
  "assertExternalToolSettingsTrusted"
) "TortoiseSVN external tool trust source coverage"
Assert-Terms $externalToolConfigurationTests @(
  "keeps optional Tortoise settings unconfigured without failing native core workflows",
  "blocks all external tool execution in an untrusted workspace before settings are used",
  "blocks workspace-provided external tool settings in an untrusted workspace without leaking values",
  "accepts absolute executable and config paths without expanding them"
) "TortoiseSVN external tool trust test coverage"
Assert-Terms $tortoiseDetectorSource @(
  'const TORTOISE_PROC_EXE = "TortoiseProc.exe";',
  'requireExternalToolExecutionTrusted(host.workspaceTrusted, "tortoise")',
  "assertExternalToolSettingsTrusted(configuration, host.workspaceTrusted)",
  'return { status: "unavailable", reason: "unsupportedPlatform" };',
  'return { status: "unavailable", reason: "notFound" };'
) "TortoiseSVN detector source coverage"
Assert-Terms $tortoiseDetectorTests @(
  "requires trusted workspace execution before reading Tortoise settings",
  "uses an explicit configured TortoiseProc.exe path and does not probe lower-priority sources",
  "fails fast for a configured missing executable instead of falling back to registry or PATH",
  "detects TortoiseProc.exe from registry before common directories and PATH",
  "detects TortoiseProc.exe from common directories before PATH",
  "detects TortoiseProc.exe from PATH as the last optional source",
  "ignores registry, common-directory, and PATH candidates that are not Windows-shaped executable paths",
  "reports unavailable without failing native workflows when TortoiseSVN is absent"
) "TortoiseSVN detector test coverage"
Assert-Terms $tortoiseLauncherSource @(
  'export type TortoiseIntent = "log" | "diff" | "revisiongraph" | "repobrowser" | "blame";',
  "const COMMANDS: Record<TortoiseIntent, string>",
  '"/ignoreprops"',
  "shell: false",
  'stdio: "ignore"',
  'value.includes("*")'
) "TortoiseSVN launcher source coverage"
Assert-Terms $tortoiseLauncherTests @(
  "builds allowlisted log arguments with separate path and configdir parameters",
  "builds read-only file intent arguments without output or log-message switches",
  "rejects unsupported mutating Tortoise commands",
  "rejects path separators that would be interpreted as multi-path command syntax",
  "spawns TortoiseProc.exe with shell disabled and no command-line string concatenation"
) "TortoiseSVN launcher test coverage"
Assert-Terms $tortoiseCommandControllerSource @(
  "openRepositoryLog",
  "openRepositoryRevisionGraph",
  "diffResource",
  "blameResource",
  'requireExternalToolExecutionTrusted(this.options.ui.workspaceTrusted(), "tortoise")',
  'if (detection.status === "unavailable")',
  "isSvnInternalPath"
) "TortoiseSVN command-controller source coverage"
Assert-Terms $tortoiseCommandControllerTests @(
  "blocks repository log launch in untrusted workspaces before detection or process spawn",
  "silently skips unavailable TortoiseSVN without launching while keeping repository sessions intact",
  "silently skips unavailable TortoiseSVN resource commands without launching",
  "launches repository log with the selected working-copy root and configured Tortoise config directory",
  "launches resource diff only for a single open repository resource under the working-copy root",
  "accepts file URI command arguments from editor context menus",
  "rejects dot-segment resource paths before detection or launch",
  "rejects .svn internal paths before launching TortoiseSVN"
) "TortoiseSVN command-controller test coverage"
Assert-Terms $extensionEntrypoint @(
  "detectTortoiseSvn(",
  "createNodeTortoiseDetectionHost(vscode.workspace.isTrusted)",
  "subversionr.tortoiseAvailable",
  "refreshTortoiseAvailability();",
  "const tortoiseOpenRepositoryLogCommand = vscode.commands.registerCommand(",
  '"subversionr.tortoise.openRepositoryLog",',
  '"subversionr.tortoise.openRepositoryBrowser",',
  '"subversionr.tortoise.blameResource"'
) "TortoiseSVN extension integration coverage"
Assert-Terms $extensionPackageJson @(
  '"subversionr.tortoise.openRepositoryLog"',
  '"subversionr.tortoise.openResourceLog"',
  '"subversionr.tortoise.diffResource"',
  '"subversionr.tortoise.openRevisionGraph"',
  '"subversionr.tortoise.openRepositoryBrowser"',
  '"subversionr.tortoise.blameResource"',
  "subversionr.tortoiseAvailable",
  '"subversionr.tortoise.executablePath"',
  '"subversionr.tortoise.configDirectory"'
) "TortoiseSVN manifest contribution coverage"
Assert-Terms $extensionManifestTests @(
  "declares limited Workspace Trust support for trust-sensitive SVN operations and external tool config paths",
  "contributes external tool and SVN runtime config settings behind Workspace Trust without defaults",
  'not.toHaveProperty("No TortoiseSVN executable is configured or detected.")',
  "SubversionR TortoiseSVN command failed: {0}",
  "subversionr.tortoiseAvailable"
) "TortoiseSVN manifest test coverage"
Assert-RequirementEvidenceRefs $requirementsEvidence "SEC-013" @(
  "docs/plans/m7-release-publication.md",
  "docs/release/security-evidence-matrix.md",
  "packages/vscode-extension/src/cache/cacheLifecycleService.ts",
  "packages/vscode-extension/tests/cacheLifecycleService.test.ts",
  "packages/vscode-extension/src/cache/cacheCommandController.ts",
  "packages/vscode-extension/tests/cacheCommandController.test.ts",
  "packages/vscode-extension/src/extension.ts",
  "scripts/release/test-vscode-install-rollback-fixture.ps1",
  "scripts/tests/release-install-rollback-fixture.tests.ps1"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "MIG-008" @(
  "docs/plans/m7-release-publication.md",
  "docs/release/m7-release-readiness-gates.md",
  "docs/release/security-evidence-matrix.md",
  "crates/subversionr-protocol/tests/protocol_contract.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "packages/vscode-extension/src/backend/backendProcess.ts",
  "packages/vscode-extension/tests/backendProcess.test.ts",
  "packages/vscode-extension/src/cache/cacheLifecycleService.ts",
  "packages/vscode-extension/tests/cacheLifecycleService.test.ts",
  "scripts/release/test-vscode-install-rollback-fixture.ps1",
  "scripts/tests/release-install-rollback-fixture.tests.ps1"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "MIG-011" @(
  "docs/plans/m7-release-publication.md",
  "docs/release/security-evidence-matrix.md",
  "packages/vscode-extension/src/cache/cacheLifecycleService.ts",
  "packages/vscode-extension/tests/cacheLifecycleService.test.ts",
  "packages/vscode-extension/src/cache/cacheCommandController.ts",
  "packages/vscode-extension/tests/cacheCommandController.test.ts",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "packages/vscode-extension/l10n/bundle.l10n.json"
)
Assert-Terms $m7Plan @(
  "## M7d Implemented Slice",
  'Protocol v1.20 includes `cacheSchema`',
  'cacheSchema',
  "subversionr.cache.v1",
  "delete-and-reconcile",
  "subversionr.cacheMigrationReport",
  'workingCopyMutation: "none"',
  '`subversionr.cache.clear` deletes extension-owned cache roots idempotently',
  '`subversionr.migration.showReport` opens the last cache migration report',
  "protocol v1.20 cache schema assertions",
  "without claiming release install/upgrade/rollback completion"
) "M7d cache schema and migration-report plan coverage"
Assert-Terms $releaseGates @(
  "Versioned cache schema with an explicit delete-and-reconcile rollback policy",
  "never mutates a working copy during rollback",
  "stores a user-visible cache migration report",
  "not sufficient by itself to claim full release upgrade/rollback completion"
) "M7d cache release gate non-claim coverage"
Assert-Terms $evidenceMatrix @(
  '| `SEC-013` | release-blocker |',
  "M7d extension-owned cache clear tests",
  '`subversionr.cacheMigrationReport` evidence',
  "Public release still needs install/upgrade/rollback cache privacy evidence",
  '| `MIG-008` | release-blocker |',
  'M7d protocol v1.20 `cacheSchema`',
  "delete-and-reconcile cache reset tests",
  '| `MIG-011` | release-blocker |',
  'M7d `subversionr.migration.showReport` foundation',
  "Full imported-settings and command-behavior migration report evidence is not complete"
) "M7d cache security evidence matrix release-blocker coverage"
Assert-Terms $backendProcessSource @(
  'const EXPECTED_CACHE_SCHEMA_ID = "subversionr.cache.v1";',
  "const EXPECTED_CACHE_SCHEMA_VERSION = 1;",
  'const EXPECTED_CACHE_SCHEMA_ROLLBACK = "delete-and-reconcile";',
  "requireSupportedCacheSchema(cacheSchema)",
  "SUBVERSIONR_CACHE_SCHEMA_UNSUPPORTED"
) "MIG-008 backend cache schema validation source coverage"
Assert-Terms $backendProcessTests @(
  "rejects initialize and terminates the sidecar when cache schema is missing",
  "rejects initialize and terminates the sidecar when cache schema is unsupported",
  "SUBVERSIONR_CACHE_SCHEMA_UNSUPPORTED",
  "error.backend.cacheSchemaUnsupported"
) "MIG-008 backend cache schema validation test coverage"
Assert-Terms $packagedNativeProbe @(
  "startBackendProcess",
  'connection.sendRequest("repository/discover"',
  "workspaceRoots",
  "connection.shutdown()",
  "subversionr.release.packaged-native-compatibility.v1",
  "APPDATA: options.profileRoot",
  "LOCALAPPDATA: options.profileRoot",
  "USERPROFILE: options.profileRoot",
  "HOME: options.profileRoot"
) "packaged native startup, protocol, ABI, and read-only bridge probe coverage"
Assert-Terms $packagedNativeProbeVerifier @(
  "backendProcess.js",
  "WaitForExit(30000)",
  '"--profile-root", $profileRoot',
  "SUBVERSIONR_PACKAGED_NATIVE_PROBE_TIMEOUT",
  "ExpectedProductVersion",
  "SUBVERSIONR_PACKAGED_NATIVE_BACKEND_VERSION_MISMATCH",
  "SUBVERSIONR_PACKAGED_NATIVE_BRIDGE_VERSION_MISMATCH"
) "fail-closed packaged native probe process isolation coverage"
Assert-Terms $stageVscodePackageLayout @(
  "verify-packaged-native-compatibility.ps1",
  "verify-product-version-consistency.ps1",
  "ExpectedProductVersion"
) "staged package native compatibility gate coverage"
Assert-Terms $verifyVscodePackageLayout @(
  "verify-packaged-native-compatibility.ps1",
  "verify-product-version-consistency.ps1",
  "BackendModulePath",
  "ExpectedProductVersion"
) "verified package native compatibility gate coverage"
Assert-Terms $productVersionVerifier @(
  "System.Text.Json.JsonDocument",
  "[workspace.package]",
  "exactly one string version property",
  "exactly one string version declaration",
  "must exactly match root product version",
  "prereleaseIdentifier"
) "fail-closed product, extension, and Cargo version declaration coverage"
Assert-Terms $packageVscodeVsix @(
  'Join-Path $distRootResolved "backend\backendProcess.js"',
  "dist/backend/backendProcess.js",
  '& $verifyLayoutScript',
  "-BackendModulePath `$backendModulePath"
) "VSIX packaging exact extension contract and native compatibility gate coverage"
Assert-Terms $backendProcessSource @(
  "subversionr.daemon.startup-error.v1",
  "parseDaemonStartupError",
  "backendExitedDuringInitialize"
) "stable daemon startup error propagation coverage"
Assert-Terms $nativeBridgeRustSource @(
  "SUBVERSIONR_NATIVE_BRIDGE_SYMBOL_MISSING",
  "subversionr.daemon.startup-error.v1",
  "startup_error"
) "stable native bridge loader startup error coverage"
Assert-Terms $releaseScriptTests @(
  "SUBVERSIONR_PROTOCOL_MINOR_UNSUPPORTED",
  "SUBVERSIONR_NATIVE_BRIDGE_SYMBOL_MISSING",
  "staleProtocolDaemon",
  "missingSymbolBridge",
  "Assert-ProductVersionVerifierContract",
  "missing root version",
  "malformed extension version",
  "numeric prerelease identifiers with leading zeros",
  "Cargo mismatch"
) "packaged native negative release script coverage"
Assert-Terms $releaseVsixScriptTests @(
  "stale-protocol-package",
  "missing-symbol-package",
  "SUBVERSIONR_PROTOCOL_MINOR_UNSUPPORTED",
  "SUBVERSIONR_NATIVE_BRIDGE_SYMBOL_MISSING",
  "must not create a VSIX output directory"
) "VSIX packaging native compatibility negative coverage"
Assert-Terms $betaCandidateOrchestration @(
  '(Resolve-RepoPath "packages/vscode-extension/dist/backend/backendProcess.js")',
  '"-BackendModulePath", $backendModulePath'
) "Beta candidate install rollback exact extension contract coverage"
Assert-Terms $releaseGates @(
  "fail-closed packaged-native startup probe",
  "read-only libsvn-backed discovery operation",
  "reject stale protocol daemons",
  "no probe skip switch or compatibility fallback"
) "packaged native compatibility release gate documentation"
Assert-Terms $protocolContractTests @(
  'json["cacheSchema"]["schemaId"], "subversionr.cache.v1"',
  'json["cacheSchema"]["version"], 1',
  'json["cacheSchema"]["rollback"], "delete-and-reconcile"'
) "MIG-008 protocol cache schema contract coverage"
Assert-Terms $rpcDispatchTests @(
  'outcome.response()["result"]["cacheSchema"]["schemaId"]',
  '"subversionr.cache.v1"',
  'outcome.response()["result"]["cacheSchema"]["version"], 1',
  '"delete-and-reconcile"'
) "MIG-008 daemon cache schema dispatch coverage"
Assert-Terms $cacheLifecycleSource @(
  "CURRENT_CACHE_SCHEMA_VERSION = 1",
  "subversionr.cache.schemaVersion",
  "subversionr.cache.lastMigrationReport",
  "kind: `"subversionr.cacheMigrationReport`"",
  "workingCopyMutation: `"none`"",
  'releaseTraceIds: ["MIG-008", "MIG-010", "MIG-011", "SEC-013"]',
  "deleteCacheRoots",
  "SUBVERSIONR_CACHE_SCHEMA_METADATA_INVALID"
) "M7d cache lifecycle source coverage"
Assert-Terms $cacheLifecycleTests @(
  "initializes missing cache schema metadata without deleting storage",
  "clears only extension-owned cache roots for stale schema metadata",
  "/workspace/.svn/wc.db",
  "expect(files.exists(`"/workspace/.svn/wc.db`")).toBe(true)",
  "expect(JSON.stringify(report)).not.toContain(`".svn`")",
  "manually clears cache idempotently and stores a user-visible report",
  "fails fast when persisted schema metadata is not numeric"
) "M7d cache lifecycle test coverage"
Assert-Terms $cacheCommandControllerSource @(
  'clearCache(reason: "manual-clear")',
  "SubversionR extension cache cleared. SVN working copies were not modified.",
  "No SubversionR migration report is available.",
  "jsonString(report)"
) "MIG-011 cache command source coverage"
Assert-Terms $cacheCommandControllerTests @(
  "clears cache and reports that SVN working copies were not modified",
  "opens the last migration report as a readonly document",
  '"kind": "subversionr.cacheMigrationReport"',
  'releaseTraceIds: ["MIG-008", "MIG-010", "MIG-011", "SEC-013"]'
) "MIG-011 cache command test coverage"
Assert-Terms $extensionEntrypoint @(
  "new CacheLifecycleService",
  "workspaceState: context.workspaceState",
  "storageRoots: cacheStorageRoots(context)",
  "deleteTree: deleteCacheTree",
  "cacheLifecycle.ensureCurrentSchema()",
  'vscode.commands.registerCommand("subversionr.cache.clear"',
  'vscode.commands.registerCommand("subversionr.migration.showReport"'
) "M7d extension cache lifecycle integration coverage"
Assert-Terms $extensionPackageJson @(
  "onCommand:subversionr.cache.clear",
  "onCommand:subversionr.migration.showReport",
  '"command": "subversionr.cache.clear"',
  '"command": "subversionr.migration.showReport"'
) "MIG-011 cache command manifest coverage"
Assert-Terms $extensionManifestTests @(
  "command.cache.clear.title",
  "command.migration.showReport.title",
  "SubversionR extension cache cleared. SVN working copies were not modified.",
  "SubversionR cache migration failed: {0}",
  "No SubversionR migration report is available.",
  "SubversionR migration report failed: {0}",
  "SubversionR backend cache schema is unsupported: {0} version {1} rollback {2}."
) "MIG-011 cache localization manifest test coverage"
Assert-Terms $installRollbackFixtureScript @(
  "publicReadinessClaim = `$false",
  "workingCopyMutation = `"none`"",
  "workingCopySentinel",
  ".svn",
  "wc.db",
  "working-copy sentinel .svn/wc.db hash was unchanged"
) "SEC-013/MIG-008 install rollback fixture non-mutation source coverage"
Assert-Terms $installRollbackFixtureScriptTests @(
  'Assert-Equal "False" ([string]$report.publicReadinessClaim)',
  'Assert-Equal "none" $phase[0].workingCopyMutation',
  'Assert-Equal "none" $report.workingCopySentinel.mutation',
  'EndsWith("/.svn/wc.db"',
  "working-copy sentinel .svn/wc.db hash was unchanged"
) "SEC-013/MIG-008 install rollback fixture non-mutation test coverage"
Assert-RequirementEvidenceRefs $requirementsEvidence "PRD-014" @(
  "docs/adr/ADR-008-stable-vscode-apis.md",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/tsconfig.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "package.json"
)
Assert-Terms $stableVsCodeApiAdr @(
  "# ADR-008: Stable VS Code APIs",
  "Core functionality uses stable VS Code APIs and does not depend on proposed APIs."
) "PRD-014 public stable VS Code API architecture coverage"
Assert-Terms $credentialStorageAdr @(
  "# ADR-010: Credential Storage",
  "Persistent credentials are stored only in VS Code SecretStorage.",
  "credential persistence fails closed",
  "does not fall back to settings, extension caches, sidecar storage, diagnostics, or the standard SVN auth cache"
) "fail-closed credential storage architecture coverage"
Assert-Terms $engineeringHandoff @(
  "# SubversionR Engineering Guide",
  "## Public Fact Sources",
  "docs/adr/README.md",
  "docs/roadmap/README.md",
  "docs/release/public-claim-matrix.md",
  "The extension uses only stable VS Code APIs for core functionality",
  "pnpm install --frozen-lockfile",
  "cargo test --workspace"
) "public engineering guide coverage"
$privateArchivePrefix = "Refer" + "ence/"
foreach ($forbiddenTerm in @(
    $privateArchivePrefix,
    "Review Estimate",
    "Completion percentages",
    "PR #157",
    "Cloudflare PR Fast",
    "Windows runner coverage is unavailable"
  )) {
  if ($engineeringHandoff.Content.Contains($forbiddenTerm, [System.StringComparison]::Ordinal)) {
    throw "docs/onboarding/ENGINEERING_HANDOFF.md: public engineering guide must not contain stale or private-only term '$forbiddenTerm'."
  }
}
Assert-Terms $extensionTsconfig @(
  '"types": ["node", "vscode", "vitest"]'
) "PRD-014 stable VS Code API type definition coverage"
Assert-Terms $extensionManifestTests @(
  "does not request proposed VS Code APIs",
  "enabledApiProposals",
  "vscode.proposed",
  "enable-proposed-api"
) "PRD-014 stable VS Code API manifest/API audit test coverage"
Assert-NoTerms $extensionPackageJson @(
  "enabledApiProposals",
  "apiProposals",
  "enable-proposed-api",
  "vscode.proposed"
) "PRD-014 stable VS Code API manifest coverage"
Assert-NoTerms $rootPackageJson @(
  "enable-proposed-api"
) "PRD-014 stable VS Code API root script coverage"
Assert-DirectoryFilesDoNotContain "packages/vscode-extension/src" @(".ts") @(
  "enabledApiProposals",
  "apiProposals",
  "enable-proposed-api",
  "vscode.proposed"
) "PRD-014 stable VS Code API source coverage"
Assert-RequirementEvidenceRefs $requirementsEvidence "PRD-006" @(
  "packages/vscode-extension/tests/statusRefreshScheduler.test.ts",
  "packages/vscode-extension/tests/statusStaleNotificationHandler.test.ts",
  "packages/vscode-extension/tests/backendLifecycleUiService.test.ts"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "REP-001" @(
  "docs/plans/m2-repository-status-snapshot.md",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "packages/vscode-extension/src/diagnostics/installedSourceControlSurfaceReport.ts",
  "packages/vscode-extension/tests/installedSourceControlSurfaceReport.test.ts",
  "scripts/release/test-vscode-installed-source-control-surface.ps1",
  "scripts/tests/release-installed-source-control-surface-scripts.tests.ps1",
  "packages/vscode-extension/src/repository/repositorySessionService.ts",
  "packages/vscode-extension/tests/repositoryDiscoveryService.test.ts",
  "packages/vscode-extension/tests/repositoryLifecycleService.test.ts",
  "packages/vscode-extension/tests/repositorySessionService.test.ts"
)
Assert-Terms $nativeBridgeTests @(
  "native_bridge_opens_subdirectory_created_by_staged_subversion_tools",
  "open_working_copy(&subdirectory_path)",
  "workspace_scope_root",
  "working_copy_root"
) "REP-001 native subdirectory-open fixture"
Assert-Terms $installedSourceControlSurfaceScript @(
  "sourceControlSubdirectoryOpenReport",
  "relationToWorkingCopyRoot",
  "subdirectoryOpenResolvedToWorkingCopyRoot",
  "workspaceScopeRootMatchedRequest",
  "REP-001"
) "REP-001 installed Source Control subdirectory-open gate"
Assert-Terms $installedSourceControlSurfaceScriptTests @(
  "sourceControlSubdirectoryOpenReport",
  "relationToWorkingCopyRoot",
  "subdirectoryOpenResolvedToWorkingCopyRoot",
  "workspaceScopeRootMatchedRequest",
  "REP-001"
) "REP-001 installed Source Control subdirectory-open gate tests"
Assert-RequirementEvidenceRefs $requirementsEvidence "REP-005" @(
  "docs/plans/m2-repository-status-snapshot.md",
  "crates/subversionr-protocol/src/lib.rs",
  "crates/subversionr-protocol/tests/protocol_contract.rs",
  "crates/subversionr-daemon/src/native.rs",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "packages/vscode-extension/src/repository/repositorySessionService.ts",
  "packages/vscode-extension/tests/repositorySessionService.test.ts",
  "packages/vscode-extension/src/scm/vscodeSourceControlPresenter.ts",
  "packages/vscode-extension/tests/vscodeSourceControlPresenter.test.ts",
  "packages/vscode-extension/src/diagnostics/installedSourceControlSurfaceReport.ts",
  "packages/vscode-extension/tests/installedSourceControlSurfaceReport.test.ts",
  "scripts/release/test-vscode-installed-source-control-surface.ps1",
  "scripts/tests/release-installed-source-control-surface-scripts.tests.ps1"
)
Assert-Terms $m2Plan @(
  "workspace_scope_root",
  "remains the requested subdirectory",
  "working_copy_root",
  "resolves to the parent",
  "InstalledSourceControlSurfaceReport",
  "records the original open request",
  "sourceControlSubdirectoryOpenReport"
) "REP-005 workspace scope handoff evidence"
Assert-Terms $protocolSource @(
  "pub workspace_scope_root: String"
) "REP-005 protocol workspace scope identity field"
Assert-Terms $protocolContractTests @(
  'workspace_scope_root: "C:/workspace".to_string()',
  'assert_eq!(json["workspaceScopeRoot"], "C:/workspace")',
  'assert_eq!(json["identity"]["workspaceScopeRoot"], "C:/workspace")'
) "REP-005 protocol workspace scope serialization coverage"
Assert-Terms $nativeBridgeRustSource @(
  "repository_identity_from_raw",
  "working_copy_root",
  "workspace_scope_root: path.to_string()"
) "REP-005 native identity maps requested path as workspace scope"
Assert-Terms $nativeBridgeTests @(
  "native_bridge_opens_subdirectory_created_by_staged_subversion_tools",
  "open_working_copy(&subdirectory_path)",
  "assert_eq!(identity.workspace_scope_root, subdirectory_path)",
  "subdirectory open must resolve provider root to the parent working copy root"
) "REP-005 native subdirectory-open fixture"
Assert-Terms $rpcDispatchTests @(
  "repository_open_returns_identity_from_loaded_bridge",
  'outcome.response()["result"]["identity"]["workspaceScopeRoot"]',
  "status_get_snapshot_returns_local_snapshot_for_open_repository"
) "REP-005 daemon workspace scope identity dispatch coverage"
Assert-Terms $daemonStateSource @(
  "bridge.status_snapshot_with_cancellation(&session.identity, generation, cancellation)",
  "snapshot.identity = session.identity.clone()"
) "REP-005 daemon snapshot preserves session identity"
Assert-Terms $repositorySessionSource @(
  "watchScopeFromResponse",
  "validateBoundaryRootScope",
  "workingCopyRoot: response.identity.workingCopyRoot",
  "workspaceScopeRoot: session.identity.workspaceScopeRoot"
) "REP-005 extension session keeps workspace scope identity separate from watch root"
Assert-Terms $repositorySessionTests @(
  "opens a working copy through the backend and registers a watcher scope from the backend identity",
  'path: "C:\\wc\\src"',
  'workingCopyRoot: "C:\\wc"',
  'workspaceScopeRoot: "C:\\wc"'
) "REP-005 repository session subdirectory request coverage"
Assert-Terms $vscodeSourceControlPresenterSource @(
  "createSourceControl",
  "this.api.uriFile(repository.workingCopyRoot)",
  "workingCopyRoot: repository.workingCopyRoot",
  "repositoryRelativePath(registered.workingCopyRoot, fsPath)"
) "REP-005 SourceControl provider roots at working-copy root"
Assert-Terms $vscodeSourceControlPresenterTests @(
  "creates fixed SCM groups and assigns projected resource states",
  "expect(api.createSourceControl).toHaveBeenCalledWith",
  'workingCopyRoot: "C:/wc"'
) "REP-005 SourceControl presenter root URI coverage"
Assert-Terms $installedSourceControlSurfaceReportSource @(
  "relationToWorkingCopyRoot",
  "workspaceScopeRootMatchedRequest",
  "sourceControlRootMatchedWorkingCopyRoot",
  "subdirectoryOpenResolvedToWorkingCopyRoot"
) "REP-005 installed Source Control provider-resolution diagnostics"
Assert-Terms $installedSourceControlSurfaceReportTests @(
  "reports subdirectory opens resolving to the parent working copy provider",
  'workspaceScopeRoot: "C:\\fixture\\wc\\src"',
  'relationToWorkingCopyRoot: "subdirectory"',
  "sourceControlRootMatchedWorkingCopyRoot: true"
) "REP-005 installed Source Control subdirectory-open unit coverage"
Assert-Terms $installedSourceControlSurfaceScript @(
  "sourceControlSubdirectoryOpenReport",
  'sourceSubdirectoryPath = path.join(workingCopyRoot, "src")',
  "workspaceScopeRoot did not match the requested source subdirectory",
  "subdirectoryOpenResolvedToWorkingCopyRoot",
  "src/tracked.txt"
) "REP-005 installed Source Control subdirectory-open gate"
Assert-Terms $installedSourceControlSurfaceScriptTests @(
  "sourceControlSubdirectoryOpenReport",
  "workspaceScopeRootMatchedRequest",
  "sourceControlRootMatchedWorkingCopyRoot",
  "subdirectoryOpenResolvedToWorkingCopyRoot",
  "provider rooted at the same working copy"
) "REP-005 installed Source Control subdirectory-open script tests"
Assert-RequirementEvidenceRefs $requirementsEvidence "REP-002" @(
  "docs/plans/m2-repository-status-snapshot.md",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/src/repository/repositoryLifecycleService.ts",
  "packages/vscode-extension/src/scm/sourceControlProjectionService.ts",
  "packages/vscode-extension/src/scm/vscodeSourceControlPresenter.ts",
  "packages/vscode-extension/tests/repositorySessionService.test.ts",
  "packages/vscode-extension/tests/repositoryLifecycleService.test.ts",
  "packages/vscode-extension/tests/sourceControlProjectionService.test.ts",
  "packages/vscode-extension/tests/vscodeSourceControlPresenter.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1"
)
Assert-Terms $nativeBridgeTests @(
  "native_stdio_rpc_discovers_multiple_working_copy_roots_with_real_bridge",
  "repository/discover",
  "workspaceRoots",
  "candidates"
) "REP-002 native multi-root discovery fixture"
Assert-RequirementEvidenceRefs $requirementsEvidence "REP-003" @(
  "docs/plans/m3-dirty-path-status-engine.md",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/src/repository/repositoryLifecycleService.ts",
  "packages/vscode-extension/src/repository/repositorySessionService.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "packages/vscode-extension/tests/repositoryLifecycleService.test.ts",
  "packages/vscode-extension/tests/repositorySessionService.test.ts",
  "packages/vscode-extension/tests/repositoryWatcherService.test.ts",
  "packages/vscode-extension/tests/dirtyPathPipeline.test.ts"
)
Assert-Terms $rpcDispatchTests @(
  "repository_discover_with_nested_enabled_returns_parent_and_nested_candidates",
  "repository_discover_respects_nested_depth_ignore_patterns_and_ignored_roots",
  "repository_discover_scans_nested_children_under_ignored_workspace_roots",
  "repository_discover_matches_ignore_patterns_case_insensitively_on_windows",
  "repository_discover_rejects_unbounded_nested_discovery_depth",
  "discoverNested",
  "parentWorkingCopyRoot"
) "REP-003 daemon nested discovery unit coverage"
Assert-Terms $nativeBridgeTests @(
  "native_stdio_rpc_discovers_nested_working_copy_roots_with_real_bridge",
  "native_stdio_rpc_parent_status_excludes_nested_working_copy_changes_with_boundaries",
  "discoverNested",
  "boundaryRoots",
  "status/getSnapshot",
  "isNested",
  "parentWorkingCopyRoot"
) "REP-003 native nested boundary fixtures"
Assert-Terms $repositoryLifecycleTests @(
  "opens a parent automatic candidate with discovered nested roots as watcher boundaries",
  "opens a parent automatic candidate with already open child sessions as watcher boundaries",
  "opens only the nearest unopened nested parent when automatic discovery returns nested descendants",
  "discoverNested: true",
  "boundaryRoots"
) "REP-003 lifecycle nested boundary planning"
Assert-Terms $repositorySessionTests @(
  "repository/open",
  "reopenOpenSessions",
  "boundaryRoots"
) "REP-003 session boundary open propagation"
Assert-Terms $rpcDispatchTests @(
  "repository_open_rejects_boundary_roots_outside_or_equal_to_working_copy_root",
  "status_get_snapshot_filters_entries_inside_repository_boundaries",
  "status_refresh_filters_boundary_entries_and_skips_boundary_targets",
  "boundaryRoots",
  "vendor/nested/src/lib.c"
) "REP-003 daemon status boundary propagation"
Assert-RequirementEvidenceRefs $requirementsEvidence "REP-006" @(
  "packages/vscode-extension/src/repository/repositorySessionService.ts",
  "packages/vscode-extension/src/repository/repositoryLifecycleService.ts",
  "packages/vscode-extension/tests/repositorySessionService.test.ts",
  "packages/vscode-extension/tests/repositoryLifecycleService.test.ts",
  "crates/subversionr-daemon/src/native.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs"
)
Assert-Terms $repositorySessionSource @(
  "export interface RepositoryIdentity",
  "repositoryUuid: string",
  "repositoryRootUrl: string",
  "workingCopyRoot: string",
  "validateReopenResponse",
  "response.identity.repositoryUuid === session.identity.repositoryUuid",
  "response.identity.repositoryRootUrl === session.identity.repositoryRootUrl",
  "normalizeAbsolutePath(response.identity.workingCopyRoot)"
) "REP-006 repository session identity source coverage"
Assert-Terms $repositoryLifecycleSource @(
  "movedCandidateMatchesSession",
  "candidate.identity.repositoryUuid === session.identity.repositoryUuid",
  "candidate.identity.repositoryRootUrl === session.identity.repositoryRootUrl",
  "repositoryRootKey(candidate.identity.workingCopyRoot, pathCase) !=="
) "REP-006 moved working-copy identity matching source coverage"
Assert-Terms $repositorySessionTests @(
  "opens a working copy through the backend and registers a watcher scope from the backend identity",
  "reopens stale sessions on a replacement backend connection with a new epoch",
  "keeps stale session state when backend reopen fails",
  "keeps stale session state when backend reopen returns a different repository identity for the same path",
  "SUBVERSIONR_REPOSITORY_REOPEN_IDENTITY_MISMATCH",
  "repositoryUuid:",
  "repositoryRootUrl:",
  "workingCopyRoot:"
) "REP-006 repository session identity test coverage"
Assert-Terms $repositoryLifecycleTests @(
  "recovers a missing open session from a moved working copy with the same repository identity",
  "does not recover a moved working copy when UUID matches but repository root URL differs",
  "repo-uuid:C:/old-wc",
  "repo-uuid:C:/new-wc",
  "file:///D:/other-repo",
  "previousWorkingCopyRoot",
  "workingCopyRoot"
) "REP-006 moved working-copy recovery test coverage"
Assert-Terms $nativeBridgeRustSource @(
  "repository_identity_from_raw",
  'c_string_to_owned(info.repository_uuid, "repository_uuid")',
  'c_string_to_owned(info.repository_root_url, "repository_root_url")',
  'c_string_to_owned(info.working_copy_root, "working_copy_root")'
) "REP-006 native identity extraction source coverage"
Assert-Terms $nativeBridgeTests @(
  "native_bridge_opens_working_copy_created_by_staged_subversion_tools",
  "native_bridge_opens_subdirectory_created_by_staged_subversion_tools",
  "assert!(!identity.repository_uuid.trim().is_empty())",
  "assert_eq!(identity.repository_root_url, fixture.repo_url)",
  "identity.working_copy_root.ends_with",
  "subdirectory open must resolve provider root to the parent working copy root"
) "REP-006 native UUID root URL and working-copy root fixture coverage"
Assert-RequirementEvidenceRefs $requirementsEvidence "REP-007" @(
  "crates/subversionr-protocol/src/lib.rs",
  "native/svn-bridge/include/subversionr_bridge.h",
  "native/svn-bridge/src/subversionr_bridge.c",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/src/native.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "packages/vscode-extension/src/status/statusSnapshotRpcClient.ts",
  "packages/vscode-extension/tests/statusSnapshotRpcClient.test.ts",
  "packages/vscode-extension/src/scm/resourceStateClassifier.ts",
  "packages/vscode-extension/tests/scmResourceStateClassifier.test.ts",
  "packages/vscode-extension/src/scm/sourceControlResourceStore.ts",
  "packages/vscode-extension/tests/sourceControlResourceStore.test.ts",
  "packages/vscode-extension/src/scm/vscodeSourceControlPresenter.ts",
  "packages/vscode-extension/tests/vscodeSourceControlPresenter.test.ts"
)
Assert-Terms $protocolSource @(
  "pub depth: String"
) "REP-007 protocol sparse depth field"
Assert-Terms $nativeBridgeHeader @(
  "const char *depth;"
) "REP-007 native status ABI depth field"
Assert-Terms $nativeBridgeSource @(
  "bridge_status_should_emit",
  "bridge_depth_is_sparse",
  "bridge_depth_is_sparse(status->depth)",
  "entry->depth = svn_depth_to_word(status->depth);",
  "svn_boolean_t get_all,"
) "REP-007 libsvn sparse depth status filtering"
Assert-Terms $nativeBridgeRustSource @(
  'c_string_to_owned(raw_entry.depth, "status.depth")',
  "depth,"
) "REP-007 Rust native sparse depth mapping"
Assert-Terms $daemonStateSource @(
  "is_projectable_status",
  "entry.switched",
  "is_sparse_status_depth(&entry.depth)",
  'matches!(depth, "empty" | "files" | "immediates")',
  "if is_interesting_status(entry)"
) "REP-007 daemon sparse metadata cache and summary split"
Assert-Terms $rpcDispatchTests @(
  "status_refresh_upserts_sparse_metadata_without_counting_local_changes",
  "status_refresh_removes_cached_sparse_metadata_when_full_reconcile_restores_depth",
  "sparse_metadata_status_entry",
  "sparse_metadata_snapshot_entry",
  'summaryDelta"]["localChanges"]',
  '"sparse-dir"'
) "REP-007 daemon sparse metadata delta coverage"
Assert-Terms $nativeBridgeTests @(
  "native_bridge_status_snapshot_preserves_sparse_depth_and_excluded_semantics",
  "--set-depth",
  "exclude",
  'assert_eq!(sparse_dir.depth, "files")',
  'assert!(!entries.contains_key("excluded-dir/inside.txt"))',
  "ordinary present children must not be promoted as metadata-only status entries",
  "excluded sparse target must stay absent from status projection"
) "REP-007 native sparse and excluded working-copy fixture coverage"
Assert-Terms $statusSnapshotRpcClientTests @(
  "preserves switched and sparse depth metadata from status entries",
  "depth: `"files`""
) "REP-007 TypeScript sparse depth parser tests"
Assert-Terms $resourceStateClassifierTests @(
  "sparse metadata-only node",
  "subversionr.workingCopyMetadata"
) "REP-007 SCM sparse metadata classifier tests"
Assert-Terms $sourceControlResourceStoreTests @(
  "projects clean working-copy metadata into its own non-committable group",
  "expect(projection.count).toBe(0)"
) "REP-007 SCM sparse metadata projection tests"
Assert-Terms $vscodeSourceControlPresenterTests @(
  "adds switched and sparse depth metadata to SourceControl resource tooltips",
  "l10n:SVN sparse depth: files"
) "REP-007 Source Control sparse depth tooltip tests"
Assert-RequirementEvidenceRefs $requirementsEvidence "REP-008" @(
  "native/svn-bridge/include/subversionr_bridge.h",
  "native/svn-bridge/src/subversionr_bridge.c",
  "crates/subversionr-daemon/src/native.rs",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "packages/vscode-extension/src/status/statusSnapshotRpcClient.ts",
  "packages/vscode-extension/tests/statusSnapshotRpcClient.test.ts",
  "packages/vscode-extension/src/status/statusRefreshRpcClient.ts",
  "packages/vscode-extension/tests/statusRefreshRpcClient.test.ts",
  "packages/vscode-extension/src/scm/resourceStateClassifier.ts",
  "packages/vscode-extension/tests/scmResourceStateClassifier.test.ts",
  "packages/vscode-extension/src/scm/sourceControlResourceStore.ts",
  "packages/vscode-extension/tests/sourceControlResourceStore.test.ts",
  "packages/vscode-extension/src/scm/vscodeSourceControlPresenter.ts",
  "packages/vscode-extension/tests/vscodeSourceControlPresenter.test.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts"
)
Assert-Terms $nativeBridgeHeader @(
  "int switched;"
) "REP-008 native status ABI switched field"
Assert-Terms $nativeBridgeSource @(
  "status->switched",
  "entry->switched = status->switched ? 1 : 0;"
) "REP-008 libsvn switched status mapping"
Assert-Terms $nativeBridgeRustSource @(
  "switched: raw_entry.switched != 0"
) "REP-008 Rust native switched mapping"
Assert-Terms $daemonStateSource @(
  "is_projectable_status",
  "entry.switched",
  "is_sparse_status_depth(&entry.depth)"
) "REP-008 daemon switched metadata cache"
Assert-Terms $rpcDispatchTests @(
  "status_refresh_upserts_switched_metadata_without_counting_local_changes",
  "switched_metadata_status_entry",
  '"branches/feature-src"',
  'outcome.response()["result"]["upsert"][0]["switched"]',
  'summaryDelta"]["localChanges"]'
) "REP-008 daemon switched metadata delta coverage"
Assert-Terms $nativeBridgeTests @(
  "native_bridge_status_snapshot_reports_switched_directory_and_branch_history",
  "svn switch",
  "branches/feature-src",
  'assert!(switched_dir.switched)',
  'assert_eq!(switched_dir.local_status, "normal")',
  'assert_eq!(snapshot.summary.local_changes, 0)',
  "native bridge should query switched branch history",
  "edit feature src",
  "/branches/feature-src/feature-only.c"
) "REP-008 native switched status and branch history fixture coverage"
Assert-Terms $statusSnapshotRpcClientTests @(
  "preserves switched and sparse depth metadata from status entries",
  "switched: true"
) "REP-008 snapshot parser switched coverage"
Assert-Terms $statusRefreshRpcClientTests @(
  "preserves switched metadata from refresh delta upserts",
  "switched: true",
  '"branches/feature-src"'
) "REP-008 refresh parser switched coverage"
Assert-Terms $resourceStateClassifierTests @(
  "switched metadata-only node",
  "subversionr.workingCopyMetadata"
) "REP-008 SCM switched metadata classifier tests"
Assert-Terms $sourceControlResourceStoreTests @(
  "projects clean working-copy metadata into its own non-committable group",
  "keeps changed switched sparse and needs-lock files committable instead of downgrading them"
) "REP-008 SCM switched metadata projection tests"
Assert-Terms $vscodeSourceControlPresenterTests @(
  "adds switched and sparse depth metadata to SourceControl resource tooltips",
  "l10n:SVN switched node"
) "REP-008 Source Control switched tooltip tests"
Assert-Terms $repositoryCommandControllerTests @(
  "opens file history for a switched projected SVN file using the switched branch path",
  "showFileHistoryResource",
  '"src/feature-only.c"',
  "switched: true"
) "REP-008 history command uses switched projection canonical path"
Assert-RequirementEvidenceRefs $requirementsEvidence "DIR-002" @(
  "docs/plans/m3-dirty-path-status-engine.md",
  "packages/vscode-extension/src/status/watcherEvents.ts",
  "packages/vscode-extension/tests/watcherEvents.test.ts",
  "packages/vscode-extension/src/status/dirtyPathSet.ts",
  "packages/vscode-extension/tests/dirtyPathSet.test.ts",
  "packages/vscode-extension/tests/dirtyPathPipeline.test.ts",
  "packages/vscode-extension/tests/repositoryWatcherService.test.ts",
  "packages/vscode-extension/src/scm/sourceControlResourceStore.ts",
  "packages/vscode-extension/tests/sourceControlResourceStore.test.ts",
  "packages/vscode-extension/src/status/statusRemoteCheckRpcClient.ts",
  "packages/vscode-extension/tests/statusRemoteCheckRpcClient.test.ts",
  "packages/vscode-extension/src/status/remoteStatusCheckService.ts",
  "packages/vscode-extension/tests/remoteStatusCheckService.test.ts",
  "scripts/release/test-vscode-installed-source-control-surface.ps1",
  "scripts/tests/release-installed-source-control-surface-scripts.tests.ps1"
)
Assert-Terms $m3Plan @(
  '`watcherEvents` normalizes raw watcher paths',
  '`DirtyPathSet` stores dirty paths with explicit case policy',
  "Boundary filtering still happens before dirty-path folding"
) "DIR-002 dirty-path normalization plan coverage"
Assert-Terms $watcherEventsSource @(
  "export function normalizeWatcherEvent",
  "normalizePath(scope.workingCopyRoot)",
  "path.replaceAll",
  "isSvnInternal",
  "boundaryRoots"
) "DIR-002 watcher event normalization source coverage"
Assert-Terms $watcherEventsTests @(
  "normalizes Windows separators and maps raw event kinds",
  "accepts POSIX absolute paths",
  "accepts UNC absolute paths",
  "drops repository-external and .svn internal paths",
  "drops paths containing dot or parent traversal segments",
  "drops configured repository boundaries"
) "DIR-002 watcher event normalization test coverage"
Assert-Terms $dirtyPathSetSource @(
  "repositoryRelativePath",
  "normalizeAbsolutePath",
  "comparisonKey",
  "isSvnInternal",
  "boundaryRoots"
) "DIR-002 dirty-path set normalization source coverage"
Assert-Terms $dirtyPathSetTests @(
  "does not use case-insensitive keys for case-sensitive repositories",
  "ignores .svn internals, paths outside the working copy, and configured boundaries",
  "preserves display casing when subtree folding case-insensitive paths",
  "does not use boundary descendants when deciding subtree folds"
) "DIR-002 dirty-path set normalization test coverage"
Assert-Terms $sourceControlResourceStoreTests @(
  "updates the case-insensitive projected resource index as local resources change",
  "SRC/MAIN.C",
  "LIB/MAIN.C"
) "DIR-002 SCM projection case-normalization test coverage"
Assert-RequirementEvidenceRefs $requirementsEvidence "DIR-019" @(
  "docs/plans/m3-dirty-path-status-engine.md",
  "crates/subversionr-protocol/tests/protocol_contract.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "packages/vscode-extension/src/status/statusSnapshotStore.ts",
  "packages/vscode-extension/tests/statusSnapshotStore.test.ts",
  "packages/vscode-extension/src/scm/sourceControlResourceStore.ts",
  "packages/vscode-extension/tests/sourceControlResourceStore.test.ts"
)
Assert-Terms $m3Plan @(
  'Remote status remains separate. `status/refresh` does not perform remote checks',
  'Incoming resources are projected only from `remoteEntries`; ordinary local refresh deltas do not alter incoming resources',
  'Full reconcile remains a local status operation. It does not run remote status',
  '`status/checkRemote`',
  '`check_out_of_date = TRUE`',
  'does not add default remote polling'
) "DIR-019 remote status separation plan coverage"
Assert-Terms $protocolContractTests @(
  "status_snapshot_serializes_local_and_remote_dimensions_separately",
  'json["localEntries"][0]["remoteStatus"], "notChecked"',
  'json["remoteEntries"]',
  "remote entries array"
) "DIR-019 protocol local/remote separation coverage"
Assert-Terms $rpcDispatchTests @(
  "status_refresh_upserts_targeted_entry_without_remote_status",
  'outcome.response()["result"]["upsert"][0]["remoteStatus"]',
  '"notChecked"',
  "status_check_remote_upserts_authoritative_remote_entries",
  "status_check_remote_removes_cached_entries_absent_from_authoritative_result",
  "status_check_remote_failure_preserves_cache_and_generation"
) "DIR-019 daemon local refresh remote-status separation coverage"
Assert-Terms $statusSnapshotStoreSource @(
  "remoteEntries: Map<string, StatusEntry>",
  "getRemoteEntry",
  "remoteChanges: applySummaryValue"
) "DIR-019 canonical status-store remote separation source coverage"
Assert-Terms $statusSnapshotStoreTests @(
  "keeps local and remote status dimensions independent for the same path",
  "applies refresh deltas by upserting and removing explicit local paths",
  "applies signed summary deltas without touching remote entries"
) "DIR-019 canonical status-store remote separation test coverage"
Assert-Terms $sourceControlResourceStoreSource @(
  'source: "local" | "remote"',
  "remoteResourcesByPath",
  "remoteEntries"
) "DIR-019 Source Control remote projection source coverage"
Assert-Terms $sourceControlResourceStoreTests @(
  "applies local refresh deltas without changing incoming remote resources",
  "src/incoming.c",
  "remoteStatus: `"modified`""
) "DIR-019 Source Control incoming preservation test coverage"
Assert-Terms $installedSourceControlSurfaceScript @(
  'subversionr.checkRemoteChanges',
  'src/incoming-only.txt',
  'svn remote-status XML oracle',
  'remoteStatusSurfaceReport',
  'DIR-019'
) "DIR-019 installed on-demand remote status coverage"
Assert-Terms $installedSourceControlSurfaceScriptTests @(
  'subversionr.checkRemoteChanges',
  'statusRemoteCheck',
  'two Incoming resources',
  'DIR-019'
) "DIR-019 installed on-demand remote status script-test coverage"
Assert-RequirementEvidenceRefs $requirementsEvidence "DIR-006" @(
  "docs/plans/m3-dirty-path-status-engine.md",
  "packages/vscode-extension/src/status/dirtyPathSet.ts",
  "packages/vscode-extension/src/status/statusRefreshScheduler.ts",
  "packages/vscode-extension/tests/dirtyPathSet.test.ts",
  "packages/vscode-extension/tests/dirtyPathPipeline.test.ts",
  "packages/vscode-extension/tests/statusRefreshScheduler.test.ts",
  "packages/vscode-extension/tests/repositoryWatcherService.test.ts"
)
Assert-Terms $m3Plan @(
  "deterministic dirty-path sibling folding before root overflow",
  '`DirtyPathSet` now folds same-parent dirty path storms',
  "deterministic subtree folding for nested dirty-path storms",
  "The planner prefers the deepest common non-root ancestor",
  "Adaptive ScanPlanner cost feedback beyond deterministic sibling/subtree budget folding"
) "DIR-006 deterministic planner plan coverage"
Assert-Terms $dirtyPathSetSource @(
  "foldSiblingRecordsIntoTargets",
  "foldSubtreeRecordsIntoTargets",
  "queueSizeAfterSubtreeFold",
  "dirtyPathFold",
  "dirtyPathSubtreeFold",
  "watcherOverflow"
) "DIR-006 dirty-path folding source coverage"
Assert-Terms $dirtyPathSetTests @(
  "folds a sibling change storm into one directory files refresh target before root overflow",
  "folds a sibling create and delete storm into one directory immediates refresh target",
  "folds a nested directory storm into one subtree refresh target before root overflow",
  "prefers the deepest subtree fold that brings the dirty queue within budget",
  "folds unrelated dirty path storms into a root full refresh target"
) "DIR-006 dirty-path folding test coverage"
Assert-Terms $dirtyPathPipelineTests @(
  "folds a same-directory watcher storm before sending the refresh request",
  "folds a nested watcher storm into a subtree refresh request",
  "dirtyPathFold",
  "dirtyPathSubtreeFold"
) "DIR-006 pipeline folding test coverage"
Assert-Terms $statusRefreshSchedulerSource @(
  "watcherOverflow",
  "markOverflowStaleIfInitialized",
  "markStaleIfInitialized",
  "flushRepository"
) "DIR-006 scheduler overflow backpressure source coverage"
Assert-Terms $statusRefreshSchedulerTests @(
  "marks initialized status state stale when watcher dirty paths overflow",
  "rejects watcher overflow stale marking before mutating when visible status state is incomplete",
  "watcherOverflow"
) "DIR-006 scheduler overflow backpressure test coverage"
Assert-Terms $repositoryWatcherServiceTests @(
  "folds watcher event storms through the dirty-path overflow target",
  "watcherOverflow"
) "DIR-006 watcher service storm backpressure test coverage"
Assert-RequirementEvidenceRefs $requirementsEvidence "DIR-003" @(
  "docs/plans/m3-dirty-path-status-engine.md",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "packages/vscode-extension/src/repository/repositorySessionService.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "packages/vscode-extension/tests/repositoryLifecycleService.test.ts",
  "packages/vscode-extension/tests/repositorySessionService.test.ts",
  "packages/vscode-extension/tests/repositoryWatcherService.test.ts",
  "packages/vscode-extension/tests/dirtyPathPipeline.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "DIR-004" @(
  "docs/plans/m3-dirty-path-status-engine.md",
  "packages/vscode-extension/src/status/dirtyPathSet.ts",
  "packages/vscode-extension/tests/dirtyPathSet.test.ts",
  "packages/vscode-extension/tests/dirtyPathPipeline.test.ts",
  "packages/vscode-extension/tests/statusRefreshScheduler.test.ts",
  "packages/vscode-extension/tests/repositoryWatcherService.test.ts"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "DIR-005" @(
  "docs/plans/m3-dirty-path-status-engine.md",
  "packages/vscode-extension/src/status/dirtyPathSet.ts",
  "packages/vscode-extension/tests/dirtyPathSet.test.ts",
  "packages/vscode-extension/tests/dirtyPathPipeline.test.ts",
  "packages/vscode-extension/tests/statusRefreshScheduler.test.ts"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "DIR-007" @(
  "docs/plans/m3-dirty-path-status-engine.md",
  "packages/vscode-extension/src/status/dirtyPathSet.ts",
  "packages/vscode-extension/src/status/statusRefreshScheduler.ts",
  "packages/vscode-extension/src/status/statusRefreshRpcClient.ts",
  "packages/vscode-extension/tests/dirtyPathSet.test.ts",
  "packages/vscode-extension/tests/statusRefreshScheduler.test.ts",
  "packages/vscode-extension/tests/statusRefreshRpcClient.test.ts",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "DIR-008" @(
  "docs/plans/m3-dirty-path-status-engine.md",
  "packages/vscode-extension/src/status/dirtyPathSet.ts",
  "packages/vscode-extension/tests/dirtyPathSet.test.ts",
  "packages/vscode-extension/tests/dirtyPathPipeline.test.ts"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "DIR-009" @(
  "docs/plans/m3-dirty-path-status-engine.md",
  "packages/vscode-extension/src/status/statusRefreshRpcClient.ts",
  "packages/vscode-extension/src/status/statusRefreshScheduler.ts",
  "packages/vscode-extension/src/status/statusRefreshCoverageStore.ts",
  "packages/vscode-extension/src/diagnostics/installedSourceControlSurfaceReport.ts",
  "packages/vscode-extension/tests/statusRefreshRpcClient.test.ts",
  "packages/vscode-extension/tests/statusRefreshScheduler.test.ts",
  "packages/vscode-extension/tests/statusRefreshCoverageStore.test.ts",
  "packages/vscode-extension/tests/installedSourceControlSurfaceReport.test.ts",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1"
)
Assert-Terms $installedSourceControlUiE2eScript @(
  "sourceControlUiRefreshLoadWorkflow",
  "validateLastCompletedRefreshCoverage",
  "lastCompletedRefresh",
  "resourceRefresh",
  "coverage",
  "load/modified-001.txt",
  "resourceRefresh",
  "restoredPathCoverageMatched",
  "DIR-009"
) "DIR-009 installed restored-path coverage load workflow"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "sourceControlUiRefreshLoadWorkflow",
  "lastCompletedRefresh",
  "resourceRefresh",
  "coverage",
  "load/modified-001.txt",
  "resourceRefresh",
  "restoredPathCoverageGenerationMatched",
  "DIR-009"
) "DIR-009 installed restored-path coverage load workflow tests"
Assert-RequirementEvidenceRefs $requirementsEvidence "DIR-010" @(
  "docs/plans/m3-dirty-path-status-engine.md",
  "packages/vscode-extension/src/status/statusSnapshotStore.ts",
  "packages/vscode-extension/tests/statusSnapshotStore.test.ts",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1"
)
Assert-Terms $installedSourceControlUiE2eScript @(
  "sourceControlUiRefreshLoadWorkflow",
  "subversionr.refreshResource",
  "load/modified-001.txt",
  "projectedRestoredItemCountAfter",
  "sourceControlProjectionRemovedRestoredPath",
  "DIR-010"
) "DIR-010 installed restored-path mark/sweep load workflow"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "sourceControlUiRefreshLoadWorkflow",
  "subversionr.refreshResource",
  "load/modified-001.txt",
  "projectedRestoredItemCountAfter",
  "sourceControlProjectionRemovedRestoredPath",
  "DIR-010"
) "DIR-010 installed restored-path mark/sweep load workflow tests"
Assert-RequirementEvidenceRefs $requirementsEvidence "DIR-011" @(
  "docs/plans/m3-dirty-path-status-engine.md",
  "packages/vscode-extension/src/status/dirtyPathSet.ts",
  "packages/vscode-extension/src/status/statusRefreshScheduler.ts",
  "packages/vscode-extension/tests/dirtyPathSet.test.ts",
  "packages/vscode-extension/tests/statusRefreshScheduler.test.ts",
  "packages/vscode-extension/tests/repositoryWatcherService.test.ts"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "DIR-012" @(
  "docs/plans/m3-dirty-path-status-engine.md",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/src/diagnostics/installedSourceControlUiE2eDirtyEvent.ts",
  "packages/vscode-extension/src/diagnostics/installedSourceControlUiE2eStatusRefreshProbe.ts",
  "packages/vscode-extension/src/status/statusSnapshotStore.ts",
  "packages/vscode-extension/src/status/statusRefreshScheduler.ts",
  "packages/vscode-extension/src/status/statusRefreshRpcClient.ts",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "packages/vscode-extension/tests/installedSourceControlUiE2eStatusRefreshProbe.test.ts",
  "packages/vscode-extension/tests/statusSnapshotStore.test.ts",
  "packages/vscode-extension/tests/statusRefreshScheduler.test.ts",
  "packages/vscode-extension/tests/statusRefreshRpcClient.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs"
)
Assert-Terms $installedSourceControlUiE2eScript @(
  "sourceControlUiDirtyGenerationCancellationLoadWorkflow",
  "subversionr.installedSourceControlUiE2eDirtyGenerationCancellationLoadWorkflow",
  "DIR-012",
  "firstRefreshObservedBeforeSupersede",
  "dirtyGenerationSuperseded",
  "completedCoverageMatchedSupersededTargets",
  "load/modified-002.txt",
  "load/modified-003.txt"
) "DIR-012 installed dirty-generation supersede load evidence fields"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "sourceControlUiDirtyGenerationCancellationLoadWorkflow",
  "subversionr.installedSourceControlUiE2eDirtyGenerationCancellationLoadWorkflow",
  "DIR-012",
  "firstRefreshObservedBeforeSupersede",
  "dirtyGenerationSuperseded",
  "completedCoverageMatchedSupersededTargets",
  "load/modified-002.txt",
  "load/modified-003.txt"
) "DIR-012 installed dirty-generation supersede load script-test evidence"
Assert-RequirementEvidenceRefs $requirementsEvidence "DIR-013" @(
  "docs/plans/m3-dirty-path-status-engine.md",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/src/diagnostics/installedSourceControlUiE2eDirtyEvent.ts",
  "packages/vscode-extension/src/diagnostics/installedSourceControlUiE2eStatusRefreshProbe.ts",
  "packages/vscode-extension/src/status/statusRefreshScheduler.ts",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "packages/vscode-extension/tests/installedSourceControlUiE2eStatusRefreshProbe.test.ts",
  "packages/vscode-extension/tests/statusRefreshScheduler.test.ts",
  "packages/vscode-extension/tests/jsonRpcStreamClient.test.ts",
  "packages/vscode-extension/tests/statusRefreshRpcClient.test.ts",
  "packages/vscode-extension/tests/backendStatusRefreshClient.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/src/native.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/tests/stdio_rpc.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "native/svn-bridge/include/subversionr_bridge.h",
  "native/svn-bridge/src/subversionr_bridge.c"
)
Assert-Terms $extensionPackageJson @(
  "onCommand:subversionr.diagnostics.installedSourceControlUiE2eArmDirtyGenerationCancellation",
  "onCommand:subversionr.diagnostics.installedSourceControlUiE2eDirtyGenerationCancellationReport",
  "onCommand:subversionr.diagnostics.installedSourceControlUiE2eDirtyEvent"
) "DIR-013 installed dirty-generation diagnostic activation events"
Assert-Terms $extensionEntrypoint @(
  "subversionr.diagnostics.installedSourceControlUiE2eArmDirtyGenerationCancellation",
  "subversionr.diagnostics.installedSourceControlUiE2eDirtyGenerationCancellationReport",
  "subversionr.diagnostics.installedSourceControlUiE2eDirtyEvent",
  "recordInstalledSourceControlUiE2eDirtyEvent"
) "DIR-013 installed dirty-generation diagnostic command registration"
Assert-Terms $installedSourceControlUiE2eScript @(
  "sourceControlUiDirtyGenerationCancellationLoadWorkflow",
  "subversionr.installedSourceControlUiE2eDirtyGenerationCancellationLoadWorkflow",
  "subversionr.diagnostics.installedSourceControlUiE2eArmDirtyGenerationCancellation",
  "subversionr.diagnostics.installedSourceControlUiE2eDirtyGenerationCancellationReport",
  "subversionr.diagnostics.installedSourceControlUiE2eDirtyEvent",
  "DIR-013",
  "dirtyGenerationSuperseded",
  "load/modified-002.txt",
  "load/modified-003.txt",
  "postCancellationStaleCaptureAvailable",
  "completedCoverageMatchedSupersededTargets"
) "DIR-013 installed dirty-generation cancellation load evidence fields"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "sourceControlUiDirtyGenerationCancellationLoadWorkflow",
  "subversionr.installedSourceControlUiE2eDirtyGenerationCancellationLoadWorkflow",
  "subversionr.diagnostics.installedSourceControlUiE2eArmDirtyGenerationCancellation",
  "subversionr.diagnostics.installedSourceControlUiE2eDirtyGenerationCancellationReport",
  "subversionr.diagnostics.installedSourceControlUiE2eDirtyEvent",
  "DIR-013",
  "dirtyGenerationSuperseded",
  "load/modified-002.txt",
  "load/modified-003.txt",
  "postCancellationStaleCaptureAvailable",
  "completedCoverageMatchedSupersededTargets"
) "DIR-013 installed dirty-generation cancellation load script-test evidence"
Assert-RequirementEvidenceRefs $requirementsEvidence "DIR-020" @(
  "docs/plans/m3-dirty-path-status-engine.md",
  "packages/vscode-extension/src/status/dirtyPathSet.ts",
  "packages/vscode-extension/src/status/statusRefreshScheduler.ts",
  "packages/vscode-extension/tests/dirtyPathSet.test.ts",
  "packages/vscode-extension/tests/dirtyPathPipeline.test.ts",
  "packages/vscode-extension/tests/statusRefreshScheduler.test.ts",
  "packages/vscode-extension/tests/repositoryWatcherService.test.ts"
)
Assert-Terms $installedSourceControlUiE2eScript @(
  "sourceControlUiBoundaryLoadWorkflow",
  "subversionr.installedSourceControlUiE2eBoundaryLoadWorkflow",
  "requestedParentModifiedItemCount",
  "projectedParentModifiedItemCount",
  "projectedBoundaryModifiedItemCount",
  "projectedExternalModifiedItemCount",
  "noBoundaryLoadResourcesProjected",
  "DIR-003"
) "DIR-003 installed large-workspace boundary load evidence fields"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "sourceControlUiBoundaryLoadWorkflow",
  "requestedParentModifiedItemCount",
  "requestedBoundaryModifiedItemCount",
  "projectedParentModifiedItemCount",
  "projectedBoundaryModifiedItemCount",
  "projectedExternalModifiedItemCount",
  "noBoundaryLoadResourcesProjected",
  "allExternalLoadResourcesProjectedByExternalProvider",
  "boundary-load-fixture",
  "DIR-003"
) "DIR-003 installed large-workspace boundary load script-test evidence"
Assert-RequirementEvidenceRefs $requirementsEvidence "REP-004" @(
  "docs/plans/m3-dirty-path-status-engine.md",
  "crates/subversionr-protocol/src/lib.rs",
  "crates/subversionr-protocol/tests/protocol_contract.rs",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "packages/vscode-extension/src/backend/backendProcess.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/src/repository/repositoryDiscoveryPlanning.ts",
  "packages/vscode-extension/src/repository/repositoryDiscoveryService.ts",
  "packages/vscode-extension/src/repository/repositoryLifecycleService.ts",
  "packages/vscode-extension/src/diagnostics/installedSourceControlSurfaceReport.ts",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/tests/backendProcess.test.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "packages/vscode-extension/tests/repositoryDiscoveryService.test.ts",
  "packages/vscode-extension/tests/repositoryLifecycleService.test.ts",
  "packages/vscode-extension/tests/repositorySessionService.test.ts",
  "packages/vscode-extension/tests/installedSourceControlSurfaceReport.test.ts",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1"
)
Assert-Terms $rpcDispatchTests @(
  "repository_discover_lazy_externals_returns_directory_external_candidates",
  "externalsMode",
  "isExternal",
  "status_entry_with_kind"
) "REP-004 daemon directory external discovery unit coverage"
Assert-Terms $nativeBridgeTests @(
  "native_stdio_rpc_discovers_directory_external_with_real_bridge",
  "svn:externals",
  "externalsMode",
  "isExternal",
  "parentWorkingCopyRoot"
) "REP-004 native directory external discovery fixture"
Assert-Terms $protocolContractTests @(
  "repository_discover_response_serializes_file_external_boundaries",
  "fileExternalBoundaries",
  "RepositoryDiscoverResponse"
) "REP-004 protocol file external boundary contract"
Assert-Terms $backendProcessTests @(
  "rejects initialize and terminates the sidecar when protocol minor is too old for failure diagnostics",
  "SUBVERSIONR_PROTOCOL_MINOR_UNSUPPORTED",
  "expectedMinimum: 29"
) "REP-004 protocol v1.29 startup gate"
Assert-Terms $protocolSource @(
  "OperationFailureDiagnostics",
  "OperationFailureCause",
  "SvnErrorDiagnostics"
) "OBS-007 protocol failure diagnostics contract"
Assert-Terms $nativeBridgeHeader @(
  "SUBVERSIONR_BRIDGE_ERROR_ENTRY_LIMIT = 8",
  "subversionr_bridge_last_error_diagnostics"
) "OBS-007 bounded native failure diagnostics ABI"
Assert-Terms $operationDiagnosticsSource @(
  "MAX_DIAGNOSTIC_LINE_BYTES = 4096",
  "MAX_DIAGNOSTIC_LINES = 100",
  "redactDiagnosticValue",
  "recordRpcFailure"
) "OBS-007 bounded redacted SubversionR operation log"
Assert-Terms $operationDiagnosticsTests @(
  "writes bounded redacted structured failures",
  "keeps at most one hundred rendered records",
  "reveals the SubversionR channel without taking editor focus"
) "OBS-007 operation log unit coverage"
Assert-Terms $repositoryCommandControllerTests @(
  "preserves the reviewed selection and commit message after a failed commit",
  "SVN_ERR_WC_NOT_UP_TO_DATE",
  "Show Log"
) "OBS-007 actionable failure and commit form-state coverage"
Assert-Terms $installedRedactionReportTests @(
  "operationFailureFixture",
  "SVN_ERR_FS_TXN_OUT_OF_DATE",
  "[REDACTED:url:"
) "OBS-007 installed operation failure redaction coverage"
Assert-Terms $rpcDispatchTests @(
  "repository_discover_lazy_externals_returns_file_external_boundaries",
  "fileExternalBoundaries",
  "status_entry_with_kind",
  "externals/pinned.txt"
) "REP-004 daemon file external boundary discovery unit coverage"
Assert-Terms $nativeBridgeTests @(
  "native_stdio_rpc_discovers_and_excludes_file_external_boundaries_with_real_bridge",
  "svn:externals",
  "fileExternalBoundaries",
  "boundaryRoots",
  "pinned.txt"
) "REP-004 native file external boundary fixture"
Assert-Terms $repositoryDiscoveryServiceTests @(
  "rejects repository/discover responses without explicit file external boundaries",
  "fileExternalBoundaries",
  "SUBVERSIONR_REPOSITORY_DISCOVERY_RESPONSE_INVALID"
) "REP-004 TypeScript file external discovery response validation"
Assert-Terms $repositoryCommandControllerTests @(
  "opens a parent working copy with discovered file external paths as watcher boundaries",
  "fileExternalBoundaries",
  "boundaryRoots"
) "REP-004 manual open file external boundary propagation"
Assert-Terms $repositoryLifecycleServiceTests @(
  "opens a parent automatic candidate with discovered file external paths as watcher boundaries",
  "fileExternalBoundaries",
  "boundaryRoots"
) "REP-004 automatic open file external boundary propagation"
Assert-Terms $installedSourceControlSurfaceReportSource @(
  "collectInstalledSourceControlUiE2eLazyExternalProviderReport",
  "externalsMode: `"lazy`"",
  "discoveryBoundaryRoots",
  "fileExternalBoundaries",
  "parentSourceControlExcludedExternalBoundaries"
) "REP-004 installed lazy external provider diagnostic implementation"
Assert-Terms $installedSourceControlSurfaceReportTests @(
  "collectInstalledSourceControlUiE2eLazyExternalProviderReport",
  "externalsMode: `"lazy`"",
  "fileExternalBoundaries",
  "parentBoundaryRootsIncludedFileExternal"
) "REP-004 installed lazy external provider diagnostic tests"
Assert-Terms $extensionEntrypoint @(
  "subversionr.diagnostics.installedSourceControlUiE2eLazyExternalProviderReport",
  "collectInstalledSourceControlUiE2eLazyExternalProviderReport"
) "REP-004 installed lazy external provider command registration"
Assert-Terms $extensionPackageJson @(
  "onCommand:subversionr.diagnostics.installedSourceControlUiE2eLazyExternalProviderReport"
) "REP-004 installed lazy external provider activation event"
Assert-Terms $extensionManifestTests @(
  "onCommand:subversionr.diagnostics.installedSourceControlUiE2eLazyExternalProviderReport"
) "REP-004 installed lazy external provider manifest tests"
Assert-Terms $installedSourceControlUiE2eScript @(
  "runLazyExternalProviderWorkflow",
  "subversionr.diagnostics.installedSourceControlUiE2eLazyExternalProviderReport",
  "sourceControlUiLazyExternalProviderWorkflow",
  "parentBoundaryRootsIncludedDirectoryExternal",
  "parentBoundaryRootsIncludedFileExternal",
  "REP-004"
) "REP-004 installed lazy external provider workflow"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "sourceControlUiLazyExternalProviderWorkflow",
  "subversionr.installedSourceControlUiE2eLazyExternalProviderReport",
  "lazy-external-provider-fixture",
  "parentBoundaryRootsIncludedDirectoryExternal",
  "parentBoundaryRootsIncludedFileExternal",
  "REP-004"
) "REP-004 installed lazy external provider workflow tests"
Assert-Terms $installedSourceControlUiE2eScript @(
  "runMultiRepositoryRefreshWorkflow",
  "installedSourceControlUiE2eOpenReport/multiRepositoryRefresh",
  "sourceControlUiMultiRepositoryRefreshWorkflow",
  "selectedRepositoryDistinct",
  "firstRepositoryStayedOpen",
  "REP-002"
) "REP-002 installed multi-repository provider workflow"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "sourceControlUiMultiRepositoryRefreshWorkflow",
  "multiRepositoryRefreshPromptCapture",
  "selectedRepositoryDistinct",
  "firstRepositoryStayedOpen",
  "multi-repository-refresh-fixture",
  "REP-002"
) "REP-002 installed multi-repository provider workflow tests"
Assert-RequirementEvidenceRefs $requirementsEvidence "UX-007" @(
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1",
  "scripts/release/capture-vscode-renderer-ui.mjs"
)
Assert-Terms $extensionEntrypoint @(
  "pickOpenRepository",
  "showQuickPick",
  "Select an SVN repository"
) "UX-007 VS Code repository picker host evidence"
Assert-Terms $extensionManifestTests @(
  "Select an SVN repository",
  "runtimeLocalizationKeys"
) "UX-007 repository picker localization evidence"
Assert-Terms $repositoryCommandControllerTests @(
  "requires an explicit repository choice before closing multiple open sessions",
  "requires an explicit repository choice before refreshing multiple open sessions",
  "requires an explicit repository choice before full reconcile with multiple open sessions",
  "requires an explicit repository choice before update with multiple open sessions",
  "pickOpenRepository"
) "UX-007 repository picker behavior evidence"
Assert-Terms $installedSourceControlUiE2eScript @(
  "runMultiRepositoryRefreshWorkflow",
  "sourceControlUiMultiRepositoryRefreshWorkflow",
  "multiRepositoryRefreshPromptCapture",
  "quickPickSelectionRequired",
  "quickPickItemSelected",
  "accessibilityRequiredTokensPresent",
  "UX-007"
) "UX-007 installed repository picker verified evidence"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "sourceControlUiMultiRepositoryRefreshWorkflow",
  "multiRepositoryRefreshPromptCapture",
  "quickPickSelectionRequired",
  "quickPickItemSelected",
  "accessibilityRequiredTokensPresent",
  "UX-007"
) "UX-007 installed repository picker script-test evidence"
Assert-RequirementEvidenceRefs $requirementsEvidence "UX-002" @(
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/package.nls.json",
  "packages/vscode-extension/package.nls.ja.json",
  "packages/vscode-extension/package.nls.zh-cn.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1",
  "scripts/release/capture-vscode-renderer-ui.mjs"
)
Assert-Terms $extensionPackageJson @(
  "viewsWelcome",
  '"view": "scm"',
  "%view.scm.emptyState.content%",
  "command.openRepository.title",
  "command.checkoutRepository.title",
  "onCommand:subversionr.checkoutRepository"
) "UX-002 no-repository empty-state manifest evidence"
Assert-Terms $extensionPackageNls @(
  "view.scm.emptyState.content",
  "No SVN working copy was found in the workspace",
  "Open SVN Working Copy…",
  "Checkout SVN Repository…",
  "command:subversionr.openRepository",
  "command:subversionr.checkoutRepository"
) "UX-002 no-repository empty-state English localization evidence"
Assert-Terms $extensionPackageNlsJa @(
  "view.scm.emptyState.content",
  "SVN",
  "command:subversionr.openRepository",
  "command:subversionr.checkoutRepository"
) "UX-002 no-repository empty-state Japanese localization evidence"
Assert-Terms $extensionPackageNlsZhCn @(
  "view.scm.emptyState.content",
  "SVN",
  "command:subversionr.openRepository",
  "command:subversionr.checkoutRepository"
) "UX-002 no-repository empty-state Chinese localization evidence"
Assert-Terms $extensionManifestTests @(
  "contributes localized SCM empty-state open and checkout welcome content",
  "viewsWelcome",
  "view.scm.emptyState.content",
  "subversionr.openRepository",
  "subversionr.checkoutRepository",
  "Open SVN Working Copy…",
  "Checkout SVN Repository…",
  "not.toContain(`"Open Repository URL`")"
) "UX-002 no-repository empty-state manifest test evidence"
Assert-Terms $extensionPackageJson @(
  '"subversionr.scm.commit"',
  '"subversionr.scm.update"',
  '"subversionr.scm.repository"',
  '"subversionr.scm.history"',
  '"group": "navigation@1"',
  '"group": "navigation@2"',
  '"group": "navigation@3"',
  '"icon": "$(refresh)"',
  '"icon": "$(check)"',
  '"icon": "$(diff)"'
) "SCM title icon and overflow submenu presentation contract"
Assert-Terms $extensionManifestTests @(
  "keeps only Refresh, Commit, and Review as SCM title navigation icons",
  "keeps every former SCM title action reachable through the title or one overflow submenu",
  "limits each SCM resource state to at most three icon-backed inline actions",
  "keeps deferred merge commands registered but hidden from every user-facing menu",
  "uses Unicode ellipsis exactly for command titles that collect user input",
  "logs successful backend initialization without showing an information toast"
) "SCM action reachability, inline limit, deferred boundary, ellipsis, and activation logging tests"
Assert-Terms $extensionEntrypoint @(
  "operationLogChannel.info(",
  "SubversionR backend ready. libsvn: {0}"
) "Backend-ready success log contract"
Assert-NoTerms $extensionPackageNls @(
  "Scan for SVN Working Copies",
  "Checkout Repository URL"
) "Retired English no-repository welcome labels"
Assert-Terms $installedSourceControlUiE2eScript @(
  "noRepositoryWelcomeRendererCapture",
  "no-repository-welcome-renderer-capture",
  "No SVN working copy was found in the workspace",
  "Open SVN Working Copy…",
  "Checkout SVN Repository…",
  "subversionr.openRepository",
  "subversionr.checkoutRepository",
  "sourceControlUiCheckoutWorkflow",
  "subversionr.installedSourceControlUiE2eCheckoutWorkflow",
  "sourceControlUiCheckoutCancellationWorkflow",
  "subversionr.installedSourceControlUiE2eCheckoutCancellationWorkflow",
  "sourceControlUiCheckoutExistingTargetFailureWorkflow",
  "subversionr.installedSourceControlUiE2eCheckoutExistingTargetFailureWorkflow",
  "sourceControlUiCheckoutInvalidUrlFailureWorkflow",
  "subversionr.installedSourceControlUiE2eCheckoutInvalidUrlFailureWorkflow",
  "sourceControlUiCheckoutExistingDirectoryWorkflow",
  "subversionr.installedSourceControlUiE2eCheckoutExistingDirectoryWorkflow",
  "sourceControlUiCheckoutExistingDirectoryObstructionWorkflow",
  "subversionr.installedSourceControlUiE2eCheckoutExistingDirectoryObstructionWorkflow",
  "checkoutExistingDirectoryObstructionWorkingCopyOracle",
  "subversionr.installedSourceControlUiE2eCheckoutExistingDirectoryObstructionWorkingCopyOracle",
  "SVN_REPOSITORY_CHECKOUT_FAILED",
  "obstructingTargetFilePreserved",
  "fixtureDirectoryUnchanged",
  "repositoryNotOpenedAfterFailure",
  "checkoutExistingTargetFailureNotificationCapture",
  "invalidUrlRejected",
  "parentDirectoryUnchanged",
  "checkoutInvalidUrlFailureUrlPromptCapture",
  "checkoutInvalidUrlFailureTargetPromptCapture",
  "checkoutInvalidUrlFailureRevisionPromptCapture",
  "checkoutInvalidUrlFailureDepthPromptCapture",
  "checkoutInvalidUrlFailureExternalsPromptCapture",
  "checkoutInvalidUrlFailureNotificationCapture",
  "checkoutExistingDirectoryUrlPromptCapture",
  "checkoutExistingDirectoryTargetPromptCapture",
  "checkoutExistingDirectoryRevisionPromptCapture",
  "checkoutExistingDirectoryDepthPromptCapture",
  "checkoutExistingDirectoryExternalsPromptCapture",
  "checkoutExistingDirectoryObstructionUrlPromptCapture",
  "checkoutExistingDirectoryObstructionTargetPromptCapture",
  "checkoutExistingDirectoryObstructionRevisionPromptCapture",
  "checkoutExistingDirectoryObstructionDepthPromptCapture",
  "checkoutExistingDirectoryObstructionExternalsPromptCapture",
  "targetDirectoryExistedBefore",
  "targetDirectoryNonEmptyBefore",
  "existingDirectoryTargetAccepted",
  "localDirectoryEntryPreserved",
  "localOnlyFileProjectedUnversioned",
  "obstructionPreserved",
  "treeConflictProjected",
  "treeConflictPresent",
  "conflictResource",
  "subversionr.conflicted",
  "local-only-before-checkout.txt",
  "subversionr.unversioned",
  "currentSurfaceProbes",
  "subversionr.installedSourceControlUiE2eMissingCurrentSurfaceProbe",
  "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CURRENT_SESSION_MISSING",
  "checkoutRepositoryOracle",
  "subversionr.installedSourceControlUiE2eCheckoutRepositoryOracle",
  "workingCopyCreated",
  "repositoryOpenedAfterCheckout",
  "sourceControlProjectionAvailable",
  "commandCancelled",
  "currentSessionMissing",
  "sourceControlProjectionAbsent",
  "targetAbsentAfter",
  "svnMetadataAbsentAfter",
  "repositoryNotOpenedAfterCancellation",
  "sourceControlProjectionUnchanged",
  "checkoutCancellationPromptCapture",
  "checkoutUrlPromptCapture",
  "checkoutTargetPromptCapture",
  "checkoutRevisionPromptCapture",
  "checkoutDepthPromptCapture",
  "checkoutExternalsPromptCapture",
  "cancelSurface",
  "quickInput",
  "cancelKey",
  "Escape",
  "domRequiredTokensPresent",
  "accessibilityRequiredTokensPresent",
  "screenshotNonBlank",
  "repository browser, remote auth/certificate, or broader checkout failure matrices",
  "UX-002"
) "UX-002 no-repository empty-state plus installed local-file checkout happy-path, existing-directory success, existing-directory obstruction tree-conflict projection, URL prompt cancellation, obstructing-file failure, and invalid-URL failure evidence"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "noRepositoryWelcomeRendererCapture",
  "No SVN working copy was found in the workspace",
  "Open SVN Working Copy…",
  "Checkout SVN Repository…",
  "subversionr.checkoutRepository",
  "sourceControlUiCheckoutWorkflow",
  "subversionr.installedSourceControlUiE2eCheckoutWorkflow",
  "sourceControlUiCheckoutCancellationWorkflow",
  "subversionr.installedSourceControlUiE2eCheckoutCancellationWorkflow",
  "sourceControlUiCheckoutExistingTargetFailureWorkflow",
  "subversionr.installedSourceControlUiE2eCheckoutExistingTargetFailureWorkflow",
  "sourceControlUiCheckoutInvalidUrlFailureWorkflow",
  "subversionr.installedSourceControlUiE2eCheckoutInvalidUrlFailureWorkflow",
  "sourceControlUiCheckoutExistingDirectoryWorkflow",
  "subversionr.installedSourceControlUiE2eCheckoutExistingDirectoryWorkflow",
  "sourceControlUiCheckoutExistingDirectoryObstructionWorkflow",
  "subversionr.installedSourceControlUiE2eCheckoutExistingDirectoryObstructionWorkflow",
  "checkoutExistingDirectoryObstructionWorkingCopyOracle",
  "subversionr.installedSourceControlUiE2eCheckoutExistingDirectoryObstructionWorkingCopyOracle",
  "SVN_REPOSITORY_CHECKOUT_FAILED",
  "obstructingTargetFilePreserved",
  "fixtureDirectoryUnchanged",
  "repositoryNotOpenedAfterFailure",
  "checkoutExistingTargetFailureNotificationCapture",
  "invalidUrlRejected",
  "parentDirectoryUnchanged",
  "checkoutInvalidUrlFailureUrlPromptCapture",
  "checkoutInvalidUrlFailureTargetPromptCapture",
  "checkoutInvalidUrlFailureRevisionPromptCapture",
  "checkoutInvalidUrlFailureDepthPromptCapture",
  "checkoutInvalidUrlFailureExternalsPromptCapture",
  "checkoutInvalidUrlFailureNotificationCapture",
  "checkoutExistingDirectoryUrlPromptCapture",
  "checkoutExistingDirectoryTargetPromptCapture",
  "checkoutExistingDirectoryRevisionPromptCapture",
  "checkoutExistingDirectoryDepthPromptCapture",
  "checkoutExistingDirectoryExternalsPromptCapture",
  "checkoutExistingDirectoryObstructionUrlPromptCapture",
  "checkoutExistingDirectoryObstructionTargetPromptCapture",
  "checkoutExistingDirectoryObstructionRevisionPromptCapture",
  "checkoutExistingDirectoryObstructionDepthPromptCapture",
  "checkoutExistingDirectoryObstructionExternalsPromptCapture",
  "targetDirectoryExistedBefore",
  "targetDirectoryNonEmptyBefore",
  "existingDirectoryTargetAccepted",
  "localDirectoryEntryPreserved",
  "localOnlyFileProjectedUnversioned",
  "obstructionPreserved",
  "treeConflictProjected",
  "treeConflictPresent",
  "conflictResource",
  "subversionr.conflicted",
  "local-only-before-checkout.txt",
  "subversionr.unversioned",
  "currentSurfaceProbes",
  "subversionr.installedSourceControlUiE2eMissingCurrentSurfaceProbe",
  "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CURRENT_SESSION_MISSING",
  "checkoutRepositoryOracle",
  "subversionr.installedSourceControlUiE2eCheckoutRepositoryOracle",
  "workingCopyCreated",
  "repositoryOpenedAfterCheckout",
  "sourceControlProjectionAvailable",
  "commandCancelled",
  "currentSessionMissing",
  "sourceControlProjectionAbsent",
  "targetAbsentAfter",
  "svnMetadataAbsentAfter",
  "repositoryNotOpenedAfterCancellation",
  "sourceControlProjectionUnchanged",
  "checkoutCancellationPromptCapture",
  "checkout-cancellation-prompt-capture",
  "cancelSurface",
  "quickInput",
  "cancelKey",
  "Escape",
  "domRequiredTokensPresent",
  "accessibilityRequiredTokensPresent",
  "screenshotNonBlank",
  "UX-002"
) "UX-002 no-repository empty-state plus installed local-file checkout happy-path, existing-directory success, existing-directory obstruction tree-conflict projection, URL prompt cancellation, obstructing-file failure, and invalid-URL failure script-test evidence"
Assert-RequirementEvidenceRefs $requirementsEvidence "UX-001" @(
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "packages/vscode-extension/tests/repositoryLifecycleService.test.ts",
  "scripts/release/test-vscode-installed-source-control-surface.ps1",
  "scripts/tests/release-installed-source-control-surface-scripts.tests.ps1",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1",
  "scripts/release/capture-vscode-renderer-ui.mjs"
)
Assert-Terms $extensionManifestTests @(
  "activationEvents",
  'not.toContain("*")',
  'not.toContain("onStartupFinished")',
  "workspaceContains:.svn/wc.db",
  "workspaceContains:../../../../.svn/wc.db"
) "UX-001 manifest on-demand activation evidence"
Assert-Terms $installedSourceControlSurfaceScript @(
  "beforeActive",
  "afterOrganicActivation",
  "afterActive",
  "commandsBeforeOrganicActivation",
  "SubversionR activated organically after the installed SVN working copy opened without executing a SubversionR command",
  "UX-001"
) "UX-001 installed Source Control surface activation evidence"
Assert-Terms $installedSourceControlSurfaceScriptTests @(
  "beforeActive",
  "afterOrganicActivation",
  "afterActive",
  "commandsBeforeOrganicActivation",
  "should prove organic activation",
  "UX-001"
) "UX-001 installed Source Control surface activation script-test evidence"
Assert-Terms $installedSourceControlUiE2eScript @(
  "beforeActive",
  "afterActive",
  "workbench.view.scm",
  "renderer DOM text contained required SubversionR Source Control tokens",
  "renderer accessibility tree contained required SubversionR Source Control tokens",
  "renderer screenshot was captured as a nonblank PNG",
  "UX-001"
) "UX-001 installed SCM view activation and accessibility evidence"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "beforeActive",
  "afterActive",
  "Renderer DOM artifact should be captured",
  "Renderer accessibility artifact should be captured",
  "Renderer screenshot nonblank assertion should pass",
  "UX-001"
) "UX-001 installed SCM view activation and accessibility script-test evidence"
Assert-Terms $installedSourceControlUiE2eScript @(
  "renderer accessibility tree contained required SubversionR Source Control tokens",
  "renderer screenshot was captured as a nonblank PNG"
) "UX-001 installed activation and accessibility verified evidence"
Assert-RequirementEvidenceRefs $requirementsEvidence "STA-003" @(
  "packages/vscode-extension/tests/sourceControlResourceStore.test.ts",
  "packages/vscode-extension/tests/sourceControlProjectionService.test.ts",
  "packages/vscode-extension/tests/vscodeSourceControlPresenter.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "OPS-010" @(
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "packages/vscode-extension/tests/propertiesListRpcClient.test.ts",
  "packages/vscode-extension/tests/operationRunRpcClient.test.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "OPS-011" @(
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "OPS-013" @(
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "packages/vscode-extension/tests/operationRunRpcClient.test.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "packages/vscode-extension/tests/vscodeSourceControlPresenter.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "STA-009" @(
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "OPS-014" @(
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "OPS-015" @(
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "COM-003" @(
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "packages/vscode-extension/tests/operationRunRpcClient.test.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "BRM-001" @(
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "BRM-005" @(
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1"
)
foreach ($id in @("BRM-006", "BRM-008", "BRM-009")) {
  Assert-RequirementEvidenceRefs $requirementsEvidence $id @(
    "docs/release/public-claim-matrix.md",
    "README.md",
    "packages/vscode-extension/package.json",
    "packages/vscode-extension/tests/extensionManifest.test.ts"
  )
}
Assert-Terms $extensionManifestTests @(
  "keeps deferred merge commands registered but hidden from every user-facing menu",
  "subversionr.mergeRangeRepository",
  "subversionr.previewMergeRangeRepository",
  "subversionr.showRepositoryMergeinfo",
  "subversionr.showResourceMergeinfo",
  "visibleEntries",
  'when: "false"'
) "BRM-006/BRM-008/BRM-009 deferred merge command boundary"
Assert-Terms $installedSourceControlUiE2eScript @(
  "runAddToIgnoreWorkflow",
  "sourceControlUiAddToIgnoreWorkflow",
  "subversionr.installedSourceControlUiE2eAddToIgnoreWorkflow",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_ADD_TO_IGNORE_WORKING_COPY",
  "subversionr.addToIgnoreResource",
  "svn:ignore",
  "propertyListReadBeforeSet",
  "workingCopyIgnorePropertyUpdated",
  "unversionedProjectionCleared",
  "Get-AddToIgnoreWorkingCopyOracle",
  "addToIgnoreWorkingCopyOracle"
) "OPS-010/OPS-011 installed Add to Ignore and svn:ignore UI E2E evidence"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "sourceControlUiAddToIgnoreWorkflow",
  "subversionr.installedSourceControlUiE2eAddToIgnoreWorkflow",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_ADD_TO_IGNORE_WORKING_COPY",
  "hasAddToIgnoreResourceCommand",
  "subversionr.addToIgnoreResource",
  "svn:ignore",
  "propertyListReadBeforeSet",
  "workingCopyIgnorePropertyUpdated",
  "unversionedProjectionCleared",
  "addToIgnoreWorkingCopyOracle"
) "OPS-010/OPS-011 installed Add to Ignore script-test evidence"
Assert-Terms $installedSourceControlUiE2eScript @(
  "runLockUnlockWorkflow",
  "sourceControlUiLockUnlockWorkflow",
  "sourceControlUiLockMessageCancellationWorkflow",
  "sourceControlUiUnlockModeCancellationWorkflow",
  "subversionr.installedSourceControlUiE2eLockUnlockWorkflow",
  "subversionr.installedSourceControlUiE2eLockMessageCancellationWorkflow",
  "subversionr.installedSourceControlUiE2eUnlockModeCancellationWorkflow",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_WORKING_COPY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MESSAGE_CANCELLATION_PROMPT_READY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MESSAGE_PROMPT_READY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MODE_PROMPT_READY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_HELD_ORACLE_READY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UNLOCK_MODE_CANCELLATION_PROMPT_READY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UNLOCK_MODE_PROMPT_READY",
  "subversionr.lockResource",
  "subversionr.unlockResource",
  "lockMessageCancellationPromptCapture",
  "unlockModeCancellationPromptCapture",
  "commandCancelled",
  "sourceControlProjectionUnchanged",
  "svn:needs-lock",
  "Get-LockHeldWorkingCopyOracle",
  "Get-LockUnlockWorkingCopyOracle",
  "lockHeldWorkingCopyOracle",
  "lockUnlockWorkingCopyOracle",
  "operationLock",
  "operationUnlock",
  "subversionr.workingCopyMetadata"
) "STA-009/OPS-014/OPS-015 installed Lock/Unlock and needs-lock UI E2E evidence"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "sourceControlUiLockUnlockWorkflow",
  "sourceControlUiLockMessageCancellationWorkflow",
  "sourceControlUiUnlockModeCancellationWorkflow",
  "subversionr.installedSourceControlUiE2eLockUnlockWorkflow",
  "subversionr.installedSourceControlUiE2eLockMessageCancellationWorkflow",
  "subversionr.installedSourceControlUiE2eUnlockModeCancellationWorkflow",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_WORKING_COPY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MESSAGE_CANCELLATION_PROMPT_READY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MESSAGE_PROMPT_READY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_MODE_PROMPT_READY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_LOCK_HELD_ORACLE_READY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UNLOCK_MODE_CANCELLATION_PROMPT_READY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_UNLOCK_MODE_PROMPT_READY",
  "subversionr.lockResource",
  "subversionr.unlockResource",
  "lockMessageCancellationPromptCapture",
  "unlockModeCancellationPromptCapture",
  "commandCancelled",
  "sourceControlProjectionUnchanged",
  "svn:needs-lock",
  "lockHeldWorkingCopyOracle",
  "lockUnlockWorkingCopyOracle",
  "operationLock",
  "operationUnlock",
  "subversionr.workingCopyMetadata"
) "STA-009/OPS-014/OPS-015 installed Lock/Unlock and needs-lock script-test evidence"
Assert-Terms $installedSourceControlUiE2eScript @(
  "runBranchCreateWorkflow",
  "sourceControlUiBranchCreateWorkflow",
  "subversionr.installedSourceControlUiE2eBranchCreateWorkflow",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_WORKING_COPY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_SOURCE_PROMPT_READY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_DESTINATION_PROMPT_READY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_REVISION_PROMPT_READY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_MESSAGE_PROMPT_READY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_PARENTS_PROMPT_READY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_EXTERNALS_PROMPT_READY",
  "subversionr.branchCreateRepository",
  "branchCreateSourcePromptCapture",
  "branchCreateDestinationPromptCapture",
  "branchCreateRevisionPromptCapture",
  "branchCreateMessagePromptCapture",
  "branchCreateParentsPromptCapture",
  "branchCreateExternalsPromptCapture",
  "branchCreatedInRepository",
  "Get-BranchCreateRepositoryOracle",
  "branchCreateRepositoryOracle",
  "latestLogContainsBranchMessage",
  "copyFromPathMatched",
  "copyFromRevisionMatched",
  "runSwitchWorkflow",
  "sourceControlUiSwitchWorkflow",
  "subversionr.installedSourceControlUiE2eSwitchWorkflow",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_WORKING_COPY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_URL_PROMPT_READY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_REVISION_PROMPT_READY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_DEPTH_PROMPT_READY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_STICKY_DEPTH_PROMPT_READY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_EXTERNALS_PROMPT_READY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_ANCESTRY_PROMPT_READY",
  "subversionr.switchRepository",
  "switchUrlPromptCapture",
  "switchRevisionPromptCapture",
  "switchDepthPromptCapture",
  "switchStickyDepthPromptCapture",
  "switchExternalsPromptCapture",
  "switchAncestryPromptCapture",
  "postSwitchReconcileCompleted",
  "postSwitchGenerationAdvanced",
  "postSwitchRepositoryIdentityPreserved",
  "Get-SwitchWorkingCopyOracle",
  "switchWorkingCopyOracle",
  "workingCopyUrlMatched",
  "BRM-001",
  "BRM-005",
  "does not prove switch-after-copy",
  "target browsing",
  "broad remote/auth/certificate matrices",
  "repository-browser integration",
  "merge workflows",
  "switched working-copy edge/load behavior"
) "BRM-001/BRM-005 installed Branch/Tag create and Switch UI E2E evidence"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "sourceControlUiBranchCreateWorkflow",
  "subversionr.installedSourceControlUiE2eBranchCreateWorkflow",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_WORKING_COPY",
  "hasBranchCreateRepositoryCommand",
  "subversionr.branchCreateRepository",
  "branchCreateSourcePromptCapture",
  "branchCreateDestinationPromptCapture",
  "branchCreateRevisionPromptCapture",
  "branchCreateMessagePromptCapture",
  "branchCreateParentsPromptCapture",
  "branchCreateExternalsPromptCapture",
  "switchUrlPromptCapture",
  "branchCreatedInRepository",
  "branchCreateRepositoryOracle",
  "latestLogContainsBranchMessage",
  "copyFromPathMatched",
  "copyFromRevisionMatched",
  "sourceControlUiSwitchWorkflow",
  "subversionr.installedSourceControlUiE2eSwitchWorkflow",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SWITCH_WORKING_COPY",
  "hasSwitchRepositoryCommand",
  "subversionr.switchRepository",
  "switchRevisionPromptCapture",
  "switchDepthPromptCapture",
  "switchStickyDepthPromptCapture",
  "switchExternalsPromptCapture",
  "switchAncestryPromptCapture",
  "postSwitchReconcileCompleted",
  "postSwitchGenerationAdvanced",
  "postSwitchRepositoryIdentityPreserved",
  "switchWorkingCopyOracle",
  "workingCopyUrlMatched",
  "BRM-001",
  "BRM-005",
  "BRM-004",
  "does not prove switch-after-copy",
  "target browsing",
  "broad remote/auth/certificate matrices",
  "repository-browser integration",
  "merge workflows",
  "switched working-copy edge/load behavior"
) "BRM-001/BRM-005 installed Branch/Tag create and Switch script-test evidence"
Assert-Terms $installedSourceControlUiE2eScript @(
  "runChangelistSetClearWorkflow",
  "sourceControlUiChangelistSetClearWorkflow",
  "subversionr.installedSourceControlUiE2eChangelistSetClearWorkflow",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHANGELIST_SET_CLEAR_WORKING_COPY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHANGELIST_SET_PROMPT_READY",
  "subversionr.setResourceChangelist",
  "subversionr.clearResourceChangelist",
  "changelistSetPromptCapture",
  "groupProjectedAfterSet",
  "resourceReturnedToChangesAfterClear"
) "OPS-013/STA-003 installed changelist set and clear UI E2E evidence"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "sourceControlUiChangelistSetClearWorkflow",
  "subversionr.installedSourceControlUiE2eChangelistSetClearWorkflow",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHANGELIST_SET_CLEAR_WORKING_COPY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHANGELIST_SET_PROMPT_READY",
  "hasSetResourceChangelistCommand",
  "hasClearResourceChangelistCommand",
  "subversionr.setResourceChangelist",
  "subversionr.clearResourceChangelist",
  "changelistSetPromptCapture",
  "groupProjectedAfterSet",
  "resourceReturnedToChangesAfterClear"
) "OPS-013/STA-003 installed changelist set and clear script-test evidence"
Assert-Terms $installedSourceControlUiE2eScript @(
  "runCommitChangelistWorkflow",
  "sourceControlUiCommitChangelistWorkflow",
  "subversionr.installedSourceControlUiE2eCommitChangelistWorkflow",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_COMMIT_CHANGELIST_WORKING_COPY",
  "subversionr.commitChangelist",
  "commitUsedChangelistFilter",
  "changelistProjectionClearedCommittedPath",
  "unselectedNonChangelistPathStillModified",
  "Get-CommitChangelistRepositoryOracle",
  "commitChangelistRepositoryOracle"
) "COM-003 installed commit by changelist UI E2E evidence"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "sourceControlUiCommitChangelistWorkflow",
  "subversionr.installedSourceControlUiE2eCommitChangelistWorkflow",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_COMMIT_CHANGELIST_WORKING_COPY",
  "hasCommitChangelistCommand",
  "subversionr.commitChangelist",
  "commitUsedChangelistFilter",
  "changelistProjectionClearedCommittedPath",
  "unselectedNonChangelistPathStillModified",
  "commitChangelistRepositoryOracle"
) "COM-003 installed commit by changelist script-test evidence"
Assert-Terms $repositoryCommandControllerTests @(
  "prompts once and cancels without side effects when the repository input message is whitespace-only",
  "commits a selected resource with one explicitly prompted message",
  "commits all resources with one explicitly prompted message",
  "reviews and commits the selected resources with one explicitly prompted message",
  "preserves the reviewed selection when commit-message prompting is cancelled",
  "rejects Commit Changelist when its exact path membership changes after message prompting",
  "rejects a prompted Commit All when the",
  "revalidates prompted Commit All after progress starts and immediately before RPC dispatch"
) "COM-003 missing-message prompt and stale-selection unit coverage"
Assert-Terms $installedSourceControlUiE2eScript @(
  "commitMessagePromptCaptureExpectations",
  "reviewCommitSelectionCaptureExpectations",
  "commitPromptRendererCaptures",
  "runReviewCommitPromptWorkflow",
  "sourceControlUiReviewCommitPromptWorkflow",
  "reviewCommitPromptRepositoryOracle",
  "subversionr.installedSourceControlUiE2eReviewCommitPromptRepositoryOracle",
  "emptyInputPrompted",
  "promptCancellationBytesUnchanged",
  "promptCancellationProjectionUnchanged",
  "promptCancellationRefreshUnchanged",
  "promptCancellationJournalUnchanged",
  "promptCancellationHistoryUnchanged",
  "reviewedSelectionRetainedAfterCancellation",
  "reviewedSelectionRetainedAfterFailure",
  "forcedCommitFailureObserved",
  "exactlyReviewedPathsCommitted",
  "unselectedProbeRemainedUncommitted"
) "COM-003 installed missing-message and Review & Commit retention evidence"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "subversionr.reviewCommit",
  "sourceControlUiReviewCommitPromptWorkflow",
  "reviewCommitPromptRepositoryOracle",
  "subversionr.installedSourceControlUiE2eReviewCommitPromptRepositoryOracle",
  "commitPromptRendererCaptures",
  "emptyInputPrompted",
  "promptCancellationJournalUnchanged",
  "reviewedSelectionRetainedAfterCancellation",
  "reviewedSelectionRetainedAfterFailure",
  "forcedCommitFailureObserved",
  "exactlyReviewedPathsCommitted",
  "unselectedProbeRemainedUncommitted"
) "COM-003 installed missing-message script-test evidence"
Assert-Terms $installedSourceControlUiE2eScript @(
  "runRevertChangelistWorkflow",
  "sourceControlUiRevertChangelistWorkflow",
  "subversionr.installedSourceControlUiE2eRevertChangelistWorkflow",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_CHANGELIST_WORKING_COPY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHANGELIST_REVERT_PROMPT_READY",
  "subversionr.revertChangelist",
  "changelistRevertPromptCapture",
  "revertUsedChangelistFilter",
  "workingCopyContentRestored"
) "OPS-013 installed revert by changelist UI E2E evidence"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "sourceControlUiRevertChangelistWorkflow",
  "subversionr.installedSourceControlUiE2eRevertChangelistWorkflow",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_CHANGELIST_WORKING_COPY",
  "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHANGELIST_REVERT_PROMPT_READY",
  "hasRevertChangelistCommand",
  "subversionr.revertChangelist",
  "changelistRevertPromptCapture",
  "revertUsedChangelistFilter",
  "workingCopyContentRestored"
) "OPS-013 installed revert by changelist script-test evidence"
Assert-RequirementEvidenceRefs $requirementsEvidence "STA-006" @(
  "packages/vscode-extension/tests/statusSnapshotStore.test.ts",
  "packages/vscode-extension/tests/sourceControlResourceStore.test.ts",
  "packages/vscode-extension/tests/sourceControlProjectionService.test.ts"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "STA-005" @(
  "docs/plans/m3-dirty-path-status-engine.md",
  "crates/subversionr-protocol/src/lib.rs",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/src/native.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "native/svn-bridge/src/subversionr_bridge.c",
  "packages/vscode-extension/src/status/statusRefreshRpcClient.ts"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "DIR-015" @(
  "docs/plans/m3-dirty-path-status-engine.md",
  "crates/subversionr-protocol/src/lib.rs",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/src/native.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "native/svn-bridge/src/subversionr_bridge.c",
  "packages/vscode-extension/src/status/statusRefreshRpcClient.ts"
)
Assert-Terms $nativeBridgeTests @(
  "native_bridge_status_snapshot_excludes_ignored_items_by_default",
  "svn:ignore",
  "ignored.log",
  "default status must not force ignored item discovery"
) "STA-005/DIR-015 native ignored default fixture"
Assert-Terms $nativeBridgeSource @(
  "svn_client_status6",
  "const svn_boolean_t no_ignore = FALSE;",
  "svn_wc_status_ignored",
  'return "ignored";'
) "STA-005/DIR-015 native ignored status policy"
Assert-Terms $protocolSource @(
  "pub struct StatusRefreshTarget",
  "pub path: String",
  "pub depth: String",
  "pub reason: String"
) "STA-005/DIR-015 status refresh target contract"
Assert-Terms $daemonStateSource @(
  "status_refresh_targets(request)",
  "bridge.status_scan_with_cancellation",
  "&target.path",
  "&target.depth"
) "STA-005/DIR-015 daemon status refresh path"
Assert-Terms $nativeBridgeRustSource @(
  "fn status_scan_with_cancellation",
  "path: &str",
  "depth: &str",
  "self.symbols.status_snapshot"
) "STA-005/DIR-015 Rust native status bridge path"
Assert-Terms $statusRefreshRpcClientSource @(
  "requireExactRequestKeys(targetRecord, field, [`"path`", `"depth`", `"reason`"]);",
  "status/refresh",
  "validateRefreshTarget"
) "STA-005/DIR-015 TypeScript status refresh request validation"
Assert-RequirementEvidenceRefs $requirementsEvidence "STA-007" @(
  "docs/plans/m3-dirty-path-status-engine.md",
  "crates/subversionr-daemon/src/native.rs",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "packages/vscode-extension/src/scm/sourceControlResourceStore.ts",
  "packages/vscode-extension/src/scm/vscodeSourceControlPresenter.ts",
  "packages/vscode-extension/tests/sourceControlResourceStore.test.ts",
  "packages/vscode-extension/tests/vscodeSourceControlPresenter.test.ts"
)
Assert-Terms $nativeBridgeRustSource @(
  "status_summary_counts_property_only_changes_as_local_changes",
  "is_local_status_change",
  "property_status"
) "STA-007 native property-only summary coverage"
Assert-Terms $daemonStateSource @(
  "fn is_interesting_status",
  "is_actionable_local_status(&entry.property_status)"
) "STA-007 daemon property-only session classification"
Assert-Terms $rpcDispatchTests @(
  "status_get_snapshot_preserves_property_only_changes",
  "status_refresh_upserts_property_only_changes",
  "property_only_status_entry",
  "summaryDelta`"][`"localChanges`"]"
) "STA-007 daemon property-only cache and delta coverage"
Assert-Terms $nativeBridgeTests @(
  "native_bridge_targeted_status_scan_reports_property_only_change",
  "subversionr:test",
  "property-only change should be reported",
  "property_status, `"modified`""
) "STA-007 native property-only fixture"
Assert-RequirementEvidenceRefs $requirementsEvidence "DIF-001" @(
  "docs/plans/m5-content-diff-history.md",
  "crates/subversionr-protocol/src/lib.rs",
  "crates/subversionr-protocol/tests/protocol_contract.rs",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/src/native.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "native/svn-bridge/include/subversionr_bridge.h",
  "native/svn-bridge/src/subversionr_bridge.c",
  "packages/vscode-extension/src/content/contentGetRpcClient.ts",
  "packages/vscode-extension/tests/contentGetRpcClient.test.ts",
  "packages/vscode-extension/src/content/baseContentUri.ts",
  "packages/vscode-extension/tests/baseContentUri.test.ts",
  "packages/vscode-extension/src/content/baseContentDocumentProvider.ts",
  "packages/vscode-extension/tests/baseContentDocumentProvider.test.ts",
  "packages/vscode-extension/src/scm/baseDiffResource.ts",
  "packages/vscode-extension/tests/baseDiffResource.test.ts",
  "packages/vscode-extension/src/scm/vscodeSourceControlPresenter.ts",
  "packages/vscode-extension/tests/vscodeSourceControlPresenter.test.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/package.nls.json",
  "packages/vscode-extension/package.nls.ja.json",
  "packages/vscode-extension/package.nls.zh-cn.json",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1",
  "scripts/release/capture-vscode-renderer-ui.mjs"
)
Assert-Terms $m5Plan @(
  "The first M5 slice adds the native and protocol foundation for BASE content retrieval",
  "The second M5 slice wires the BASE content RPC into VS Code QuickDiff",
  'Each registered Source Control instance receives a `quickDiffProvider`',
  '`subversionr.diffWithBase` opens a VS Code diff editor',
  '`subversionr.openBase` is contributed for local `subversionr.changedFile.baseDiffable` SCM resources',
  'This slice advances `DIF-001`'
) "DIF-001 M5 Working-Base scope"
Assert-Terms $protocolSource @(
  "pub struct ContentGetResponse",
  "pub content_base64: String",
  "pub is_binary: bool",
  "pub source: String",
  "pub content_get: bool"
) "DIF-001 protocol BASE content contract"
Assert-Terms $daemonStateSource @(
  "`"content/get`" => self.dispatch_content_get",
  "fn dispatch_content_get",
  "bridge.content_get(&session.identity, path, revision, auth)",
  "ContentGetResponse"
) "DIF-001 daemon content/get dispatch"
Assert-Terms $nativeBridgeRustSource @(
  "subversionr_bridge_content_get_with_auth",
  "fn content_get",
  "`"base`" => `"libsvn-base`""
) "DIF-001 Rust native BASE content bridge"
Assert-Terms $nativeBridgeSource @(
  "bridge_content_get_impl",
  "svn_client_cat3",
  "svn_mime_type_is_binary",
  "subversionr_bridge_content_get_with_auth"
) "DIF-001 native libsvn BASE content bridge"
Assert-Terms $rpcDispatchTests @(
  "content_get_returns_base_content_for_open_repository",
  "content_get_rejects_invalid_revisions_before_bridge_call",
  "content_get_rejects_absolute_or_parent_relative_path",
  "content_get_requires_matching_open_repository_epoch"
) "DIF-001 daemon BASE content RPC coverage"
Assert-Terms $nativeBridgeTests @(
  "native_bridge_content_get_returns_base_text_not_modified_working_file",
  "native_bridge_content_get_reports_base_mime_type_and_binary_flag",
  "content_get(&identity, `"tracked.txt`", `"base`"",
  "`"libsvn-base`""
) "DIF-001 native BASE content fixtures"
Assert-Terms $contentGetRpcClientSource @(
  "sendRequest<unknown>(`"content/get`", validatedRequest)",
  "requireContentMatchesRequest",
  "if (revision === `"base`")",
  "return `"libsvn-base`";"
) "DIF-001 TypeScript content/get client"
Assert-Terms $contentGetRpcClientTests @(
  "sends BASE content/get and decodes binary-safe response bytes",
  "rejects invalid request paths before sending",
  "accepts an empty BASE file response",
  "rejects response sources that do not match the requested revision"
) "DIF-001 TypeScript BASE content client tests"
Assert-Terms $baseContentUriSource @(
  "BASE_CONTENT_URI_SCHEME = `"svn-r-base`"",
  "createBaseContentUriComponents",
  "parseBaseContentUri",
  "revision !== `"base`""
) "DIF-001 BASE virtual URI contract"
Assert-Terms $baseContentUriTests @(
  "encodes BASE content identity into a custom URI without exposing local filesystem paths",
  "parses a BASE content URI into a content/get request",
  "rejects non-BASE revisions in BASE content URIs"
) "DIF-001 BASE virtual URI tests"
Assert-Terms $baseContentDocumentProviderSource @(
  "parseBaseContentUri(uri)",
  "contentClient.getContent",
  "Binary SVN BASE content is not displayed in the text editor."
) "DIF-001 BASE document provider"
Assert-Terms $baseContentDocumentProviderTests @(
  "loads BASE content through content/get and returns readonly text",
  "returns localized placeholder text for binary BASE content"
) "DIF-001 BASE document provider tests"
Assert-Terms $baseDiffResourceSource @(
  "BASE_DIFFABLE_FILE_CONTEXT_VALUE",
  "isBaseDiffableProjectedResource",
  "BASE_DIFF_SUPPORTED_STATUS_TOKENS",
  "BASE_DIFF_UNSUPPORTED_STATUS_TOKENS"
) "DIF-001 BASE-diffable SCM classifier"
Assert-Terms $baseDiffResourceTests @(
  "allows %s file changes with BASE content",
  "allows the libsvn property-only file shape for BASE text content",
  "rejects non-local files, directories, externals, and non-changed contexts"
) "DIF-001 BASE-diffable SCM classifier tests"
Assert-Terms $vscodeSourceControlPresenterSource @(
  "quickDiffProvider",
  "provideOriginalResource",
  "createBaseContentUriComponents",
  "quickDiffPathsFromProjection"
) "DIF-001 VS Code QuickDiff provider"
Assert-Terms $vscodeSourceControlPresenterTests @(
  "provides BASE virtual document URIs for QuickDiff without scanning repository state",
  "does not provide QuickDiff originals for unversioned ignored external or remote resources",
  "does not provide QuickDiff originals for conflicted ignored or external files"
) "DIF-001 VS Code QuickDiff provider tests"
Assert-Terms $repositoryCommandControllerTests @(
  "opens a BASE diff for a selected changed SVN file using the projection canonical path",
  "opens BASE content for a selected changed SVN file using the projection canonical path",
  "opens a BASE diff for the libsvn property-only file shape",
  "rejects added SVN files for BASE diff until added-file rendering is supported",
  "rejects %s SVN files for BASE diff until safe rendering is supported"
) "DIF-001 explicit BASE diff/open command tests"
Assert-Terms $extensionEntrypoint @(
  "registerTextDocumentContentProvider",
  "BASE_CONTENT_URI_SCHEME",
  "subversionr.diffWithBase",
  "subversionr.openBase"
) "DIF-001 extension activation and command registration"
Assert-Terms $extensionPackageJson @(
  "onCommand:subversionr.diffWithBase",
  "onCommand:subversionr.openBase",
  "scmProvider == svn-r && scmResourceState =~ /^subversionr\\.changedFile\\.baseDiffable(\\.changelisted)?(\\.locked)?$/",
  "resourceScheme == file && subversionr.activeEditorBaseDiffable"
) "DIF-001 command contribution and SCM/editor placement"
Assert-Terms $extensionPackageNls @(
  '"command.diffWithBase.title"',
  '"command.openBase.title"',
  "SubversionR: Diff with BASE",
  "SubversionR: Open BASE"
) "DIF-001 English package localization"
Assert-Terms $extensionPackageNlsJa @(
  '"command.diffWithBase.title"',
  '"command.openBase.title"'
) "DIF-001 Japanese package localization"
Assert-Terms $extensionPackageNlsZhCn @(
  '"command.diffWithBase.title"',
  '"command.openBase.title"'
) "DIF-001 Chinese package localization"
Assert-Terms $extensionBundleL10n @(
  '"Binary SVN BASE content is not displayed in the text editor."',
  "Binary SVN BASE content is not displayed in the text editor."
) "DIF-001 English runtime localization"
Assert-Terms $extensionBundleL10nJa @(
  '"Binary SVN BASE content is not displayed in the text editor."'
) "DIF-001 Japanese runtime localization"
Assert-Terms $extensionBundleL10nZhCn @(
  '"Binary SVN BASE content is not displayed in the text editor."'
) "DIF-001 Chinese runtime localization"
Assert-Terms $extensionManifestTests @(
  "onCommand:subversionr.diffWithBase",
  "onCommand:subversionr.openBase",
  "command.diffWithBase.title",
  "command.openBase.title",
  'resourceStateWhenMatches(entry.when ?? "", "subversionr.changedFile.baseDiffable")',
  'expect.arrayContaining(["subversionr.diffWithBase", "subversionr.openBase"])'
) "DIF-001 extension manifest tests"
Assert-RequirementEvidenceRefs $requirementsEvidence "DIF-002" @(
  "docs/plans/m5-content-diff-history.md",
  "crates/subversionr-protocol/src/lib.rs",
  "crates/subversionr-protocol/tests/protocol_contract.rs",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/src/native.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "native/svn-bridge/include/subversionr_bridge.h",
  "native/svn-bridge/src/subversionr_bridge.c",
  "packages/vscode-extension/src/content/contentGetRpcClient.ts",
  "packages/vscode-extension/tests/contentGetRpcClient.test.ts",
  "packages/vscode-extension/src/content/headContentUri.ts",
  "packages/vscode-extension/tests/headContentUri.test.ts",
  "packages/vscode-extension/src/content/headContentDocumentProvider.ts",
  "packages/vscode-extension/tests/headContentDocumentProvider.test.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/package.nls.json",
  "packages/vscode-extension/package.nls.ja.json",
  "packages/vscode-extension/package.nls.zh-cn.json",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1",
  "scripts/release/capture-vscode-renderer-ui.mjs"
)
Assert-Terms $m5Plan @(
  "The fourteenth M5 slice exposes user-triggered HEAD content and Working Copy versus HEAD comparison",
  '`subversionr.openHead` and `subversionr.diffWithHead` are contributed for local `subversionr.changedFile.baseDiffable` SCM resources',
  'HEAD content uses a separate mutable `svn-r-head` virtual document scheme',
  "Each HEAD command invocation creates a strict HEAD URI",
  'This slice advances `DIF-002`',
  'Targeted extension tests pass for `headContentUri`, `headContentDocumentProvider`, `repositoryCommandController`, and `extensionManifest`'
) "DIF-002 M5 Working-HEAD scope"
Assert-Terms $protocolSource @(
  "pub struct ContentGetResponse",
  "pub revision: String",
  "pub source: String",
  "content_get_revision: true"
) "DIF-002 protocol HEAD content contract"
Assert-Terms $protocolContractTests @(
  "content_get_response_serializes_binary_safe_wire_fields",
  "revision: `"base`".to_string()",
  "source: `"libsvn-base`".to_string()"
) "DIF-002 protocol binary-safe content/get serialization"
Assert-Terms $daemonStateSource @(
  "`"content/get`" => self.dispatch_content_get",
  "fn dispatch_content_get",
  'revision == "base" || revision == "head"'
) "DIF-002 daemon HEAD content/get dispatch"
Assert-Terms $nativeBridgeRustSource @(
  "subversionr_bridge_content_get_with_auth",
  "fn content_get",
  'revision == "base" || revision == "head"',
  'revision == "head" || valid_numbered_revision(revision)',
  '"head" => "libsvn-head"'
) "DIF-002 Rust native HEAD content bridge"
Assert-Terms $nativeBridgeSource @(
  "bridge_content_revision",
  'strcmp(revision, "head") == 0',
  "operative_revision->kind = svn_opt_revision_head",
  "svn_client_cat3",
  "subversionr_bridge_content_get_with_auth"
) "DIF-002 native libsvn HEAD content bridge"
Assert-Terms $rpcDispatchTests @(
  "content_get_returns_head_content_for_open_repository",
  '"revision":"head"',
  "libsvn-head"
) "DIF-002 daemon HEAD content RPC coverage"
Assert-Terms $nativeBridgeTests @(
  "native_bridge_content_get_returns_head_and_explicit_revision_text",
  "remote head",
  'content_get(&identity, "tracked.txt", "head"',
  "libsvn-head"
) "DIF-002 native HEAD content fixtures"
Assert-Terms $contentGetRpcClientSource @(
  'revision === "head"',
  'return "libsvn-head";',
  "sendRequest<unknown>(`"content/get`", validatedRequest)",
  "requireContentMatchesRequest"
) "DIF-002 TypeScript content/get HEAD client"
Assert-Terms $contentGetRpcClientTests @(
  "sends HEAD content/get and accepts the matching response identity",
  'source: "libsvn-head"',
  'revision: "head"',
  "rejects response sources that do not match the requested revision"
) "DIF-002 TypeScript content/get HEAD tests"
Assert-Terms $headContentUriSource @(
  "HEAD_CONTENT_URI_SCHEME = `"svn-r-head`"",
  "createHeadContentUriComponents",
  "parseHeadContentUri",
  'revision !== "head"',
  "requestId"
) "DIF-002 HEAD virtual URI contract"
Assert-Terms $headContentUriTests @(
  "encodes mutable HEAD content identity with a per-request id",
  "parses a HEAD content URI into its strict request identity",
  "rejects duplicated identity query keys",
  "rejects unsupported HEAD revision identity"
) "DIF-002 HEAD virtual URI tests"
Assert-Terms $headContentDocumentProviderSource @(
  "parseHeadContentUri(uri)",
  "contentClient.getContent",
  'revision: request.revision',
  "Binary SVN HEAD content is not displayed in the text editor: {0}"
) "DIF-002 HEAD document provider"
Assert-Terms $headContentDocumentProviderTests @(
  "loads HEAD content through content/get and returns readonly text",
  "returns localized placeholder text for binary HEAD content",
  "rejects HEAD content in untrusted workspaces before content/get"
) "DIF-002 HEAD document provider tests"
Assert-Terms $repositoryCommandControllerSource @(
  "public async diffWithHeadResource",
  "public async openHeadResource",
  "createHeadContentUriComponents",
  "this.options.createRequestId()",
  "SVN HEAD <-> Working Copy: {0}",
  "SVN HEAD: {0}"
) "DIF-002 repository HEAD command implementation"
Assert-Terms $repositoryCommandControllerTests @(
  "opens a HEAD diff for a selected changed SVN file using a fresh request identity",
  "opens HEAD content for a selected changed SVN file using the projection canonical path",
  "fails fast when HEAD diff state is unavailable",
  "fails fast when HEAD content state is stale",
  "rejects added and directory SCM resources for HEAD commands"
) "DIF-002 repository HEAD command tests"
Assert-Terms $extensionEntrypoint @(
  "registerTextDocumentContentProvider",
  "HEAD_CONTENT_URI_SCHEME",
  "subversionr.diffWithHead",
  "subversionr.openHead",
  "svn.openHEADFile",
  "svn.openChangeHead"
) "DIF-002 extension activation, command registration, and legacy aliases"
Assert-Terms $extensionPackageJson @(
  "onCommand:subversionr.diffWithHead",
  "onCommand:subversionr.openHead",
  "scmProvider == svn-r && isWorkspaceTrusted && scmResourceState =~ /^subversionr\\.changedFile\\.baseDiffable(\\.changelisted)?(\\.locked)?$/",
  "resourceScheme == file && subversionr.activeEditorBaseDiffable"
) "DIF-002 command contribution and SCM/editor placement"
Assert-Terms $extensionPackageNls @(
  '"command.diffWithHead.title"',
  '"command.openHead.title"',
  "SubversionR: Diff with HEAD",
  "SubversionR: Open HEAD"
) "DIF-002 English package localization"
Assert-Terms $extensionPackageNlsJa @(
  '"command.diffWithHead.title"',
  '"command.openHead.title"'
) "DIF-002 Japanese package localization"
Assert-Terms $extensionPackageNlsZhCn @(
  '"command.diffWithHead.title"',
  '"command.openHead.title"'
) "DIF-002 Chinese package localization"
Assert-Terms $extensionBundleL10n @(
  '"Binary SVN HEAD content is not displayed in the text editor: {0}"',
  "Binary SVN HEAD content is not displayed in the text editor: {0}"
) "DIF-002 English runtime localization"
Assert-Terms $extensionBundleL10nJa @(
  '"Binary SVN HEAD content is not displayed in the text editor: {0}"'
) "DIF-002 Japanese runtime localization"
Assert-Terms $extensionBundleL10nZhCn @(
  '"Binary SVN HEAD content is not displayed in the text editor: {0}"'
) "DIF-002 Chinese runtime localization"
Assert-Terms $extensionManifestTests @(
  "onCommand:subversionr.diffWithHead",
  "onCommand:subversionr.openHead",
  "command.diffWithHead.title",
  "command.openHead.title",
  "svn.openHEADFile",
  "svn.openChangeHead",
  "Binary SVN HEAD content is not displayed in the text editor: {0}"
) "DIF-002 extension manifest tests"
Assert-RequirementEvidenceRefs $requirementsEvidence "HIS-009" @(
  "docs/plans/m5-content-diff-history.md",
  "crates/subversionr-protocol/src/lib.rs",
  "crates/subversionr-protocol/tests/protocol_contract.rs",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/src/native.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "native/svn-bridge/include/subversionr_bridge.h",
  "native/svn-bridge/src/subversionr_bridge.c",
  "packages/vscode-extension/src/content/contentGetRpcClient.ts",
  "packages/vscode-extension/tests/contentGetRpcClient.test.ts",
  "packages/vscode-extension/src/content/revisionContentUri.ts",
  "packages/vscode-extension/tests/revisionContentUri.test.ts",
  "packages/vscode-extension/src/content/revisionContentDocumentProvider.ts",
  "packages/vscode-extension/tests/revisionContentDocumentProvider.test.ts",
  "packages/vscode-extension/src/history/historyTreeDataProvider.ts",
  "packages/vscode-extension/tests/historyTreeDataProvider.test.ts",
  "packages/vscode-extension/src/history/historyOpenRevisionCommand.ts",
  "packages/vscode-extension/tests/historyOpenRevisionCommand.test.ts",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/package.nls.json",
  "packages/vscode-extension/package.nls.ja.json",
  "packages/vscode-extension/package.nls.zh-cn.json",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts"
)
Assert-Terms $m5Plan @(
  "The eighth M5 slice exposes explicit revision content from file history revision rows",
  'The extension registers a readonly `svn-r-revision` virtual document provider backed by the existing `content/get` revision-capable RPC',
  '`svn-r-revision` URIs carry only `repositoryId`, `epoch`, repository-relative `path`, and an explicit numeric `revision = r<N>`',
  "Binary revision content returns a localized placeholder instead of writing binary bytes into a VS Code text editor",
  'File history revision rows receive an `subversionr.history.openRevision` command with a validated target',
  "Repository-log revision rows remain display-only for this slice because they do not carry a single working-copy file path",
  "This slice intentionally does not implement Revision Details webviews, Compare PREV, arbitrary two-revision compare, repository changed-path open by repository URL"
) "HIS-009 M5 bounded Open Revision scope"
Assert-Terms $protocolSource @(
  "pub struct ContentGetResponse",
  "pub revision: String",
  "pub content_base64: String",
  "content_get_revision: true"
) "HIS-009 protocol explicit revision content contract"
Assert-Terms $rpcDispatchTests @(
  "content_get_returns_explicit_revision_content_for_open_repository",
  '"revision":"r7"',
  "libsvn-revision"
) "HIS-009 daemon explicit revision content RPC coverage"
Assert-Terms $nativeBridgeTests @(
  "native_bridge_content_get_returns_head_and_explicit_revision_text",
  'content_get(&identity, "tracked.txt", "r2"',
  'content_get(&identity, "tracked.txt", "r3"',
  "libsvn-revision"
) "HIS-009 native explicit revision content fixtures"
Assert-Terms $contentGetRpcClientSource @(
  'return "libsvn-revision";',
  "sendRequest<unknown>(`"content/get`", validatedRequest)",
  "requireContentMatchesRequest"
) "HIS-009 TypeScript explicit revision content client"
Assert-Terms $contentGetRpcClientTests @(
  "sends explicit revision content/get and accepts the matching response identity",
  'source: "libsvn-revision"',
  "rejects response sources that do not match the requested revision"
) "HIS-009 TypeScript explicit revision content client tests"
Assert-Terms $revisionContentUriSource @(
  "REVISION_CONTENT_URI_SCHEME = `"svn-r-revision`"",
  "createRevisionContentUriComponents",
  "parseRevisionContentUri",
  "isExplicitRevision"
) "HIS-009 strict revision URI contract"
Assert-Terms $revisionContentUriTests @(
  "encodes explicit revision content identity into a custom URI without exposing local filesystem paths",
  "parses an explicit revision content URI into a content/get request",
  "rejects duplicated identity query keys",
  "rejects invalid revision content path %j",
  "rejects unsupported revision identity %j"
) "HIS-009 strict revision URI tests"
Assert-Terms $revisionContentDocumentProviderSource @(
  "parseRevisionContentUri(uri)",
  "contentClient.getContent",
  "Binary SVN revision content is not displayed in the text editor: {0}@{1}"
) "HIS-009 revision content document provider"
Assert-Terms $revisionContentDocumentProviderTests @(
  "loads explicit revision content through content/get and returns readonly text",
  "returns localized placeholder text for binary explicit revision content",
  "rejects explicit revision content in untrusted workspaces before content/get"
) "HIS-009 revision content document provider tests"
Assert-Terms $historyTreeDataProviderSource @(
  "openRevisionTarget(element: unknown)",
  "requireCurrentFileRevisionNode(element, invalidOpenRevisionTarget)",
  "revision: revisionId",
  'label: `${target.path}@${revisionId}`',
  "SUBVERSIONR_HISTORY_OPEN_REVISION_TARGET_INVALID"
) "HIS-009 history TreeView Open Revision targets"
Assert-Terms $historyTreeDataProviderTests @(
  "adds an Open Revision command to file history revision rows",
  "subversionr.history.openRevision",
  "l10n:Open Revision",
  "src/main.c@r8",
  "blocks remote history loading and revision content targets in untrusted workspaces"
) "HIS-009 history TreeView Open Revision tests"
Assert-Terms $historyOpenRevisionCommandSource @(
  "historyOpenRevisionUriComponents",
  "createRevisionContentUriComponents",
  "requireHistoryOpenRevisionTarget",
  "SUBVERSIONR_HISTORY_OPEN_REVISION_TARGET_INVALID"
) "HIS-009 Open Revision command helper"
Assert-Terms $historyOpenRevisionCommandTests @(
  "creates revision content URI components from a file-history revision command target",
  "rejects spoofed %s",
  "base revision",
  "bare revision"
) "HIS-009 Open Revision command helper tests"
Assert-Terms $extensionEntrypoint @(
  "RevisionContentDocumentProvider",
  "REVISION_CONTENT_URI_SCHEME",
  "registerTextDocumentContentProvider",
  "subversionr.history.openRevision",
  "historyOpenRevisionUriComponents",
  "openRevisionContent",
  "vscode.workspace.openTextDocument(uri)",
  "vscode.window.showTextDocument(document, { preview: false })"
) "HIS-009 extension activation, provider, and command execution"
Assert-Terms $extensionPackageJson @(
  "onCommand:subversionr.history.openRevision",
  "subversionr.history.openRevision",
  "%command.history.openRevision.title%",
  "viewItem == subversionr.history.fileRevision || viewItem == subversionr.history.fileRevision.previousDiffable) && !listMultiSelection",
  '"when": "false"'
) "HIS-009 command contribution and surface placement"
Assert-Terms $extensionPackageNls @(
  '"command.history.openRevision.title"',
  "SubversionR: Open Revision"
) "HIS-009 English package localization"
Assert-Terms $extensionPackageNlsJa @(
  '"command.history.openRevision.title"'
) "HIS-009 Japanese package localization"
Assert-Terms $extensionPackageNlsZhCn @(
  '"command.history.openRevision.title"'
) "HIS-009 Chinese package localization"
Assert-Terms $extensionBundleL10n @(
  '"Open Revision"',
  "Open Revision",
  "Binary SVN revision content is not displayed in the text editor: {0}@{1}"
) "HIS-009 English runtime localization"
Assert-Terms $extensionBundleL10nJa @(
  '"Open Revision"'
) "HIS-009 Japanese runtime localization"
Assert-Terms $extensionBundleL10nZhCn @(
  '"Open Revision"'
) "HIS-009 Chinese runtime localization"
Assert-Terms $extensionManifestTests @(
  "onCommand:subversionr.history.openRevision",
  "command.history.openRevision.title",
  "subversionr.history.openRevision",
  "viewItem == subversionr.history.fileRevision || viewItem == subversionr.history.fileRevision.previousDiffable) && !listMultiSelection",
  "Open Revision",
  "Binary SVN revision content is not displayed in the text editor: {0}@{1}"
) "HIS-009 extension manifest tests"
Assert-RequirementEvidenceRefs $requirementsEvidence "HIS-008" @(
  "docs/plans/m5-content-diff-history.md",
  "packages/vscode-extension/src/history/historyLogRpcClient.ts",
  "packages/vscode-extension/tests/historyLogRpcClient.test.ts",
  "packages/vscode-extension/src/history/historyTreeDataProvider.ts",
  "packages/vscode-extension/tests/historyTreeDataProvider.test.ts",
  "packages/vscode-extension/src/history/historyRevisionDetailsDocument.ts",
  "packages/vscode-extension/tests/historyRevisionDetailsDocument.test.ts",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/package.nls.json",
  "packages/vscode-extension/package.nls.ja.json",
  "packages/vscode-extension/package.nls.zh-cn.json",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts"
)
Assert-Terms $m5Plan @(
  "The tenth M5 slice adds a readonly Revision Details document for already loaded history rows",
  '`subversionr.history.openRevisionDetails` is contributed for repository and file revision rows and hidden from the Command Palette',
  "Repository revision rows use Open Revision Details as their default command",
  'Revision Details documents are served by a strict in-memory `svn-r-revision-details` virtual document provider',
  'The document renders only metadata already loaded by `history/log`',
  'The slice partially advances `HIS-008` for the existing history surfaces',
  'This slice intentionally does not implement full revprop retrieval beyond `svn:author`, `svn:date`, and `svn:log`'
) "HIS-008 M5 bounded Revision Details scope"
Assert-Terms $historyLogRpcClientSource @(
  "sendRequest<unknown>(`"history/log`", validatedRequest)",
  "requireHistoryLogMatchesRequest",
  "changedPaths"
) "HIS-008 history/log metadata source"
Assert-Terms $historyLogRpcClientTests @(
  "sends history/log and parses changed-path metadata",
  "rejects malformed changed path metadata"
) "HIS-008 history/log metadata tests"
Assert-Terms $historyTreeDataProviderSource @(
  "revisionDetailsTarget(element: unknown)",
  "requireCurrentRevisionNode(element, invalidRevisionDetailsTarget)",
  "targetKind: revisionNode.target.kind",
  "changedPaths: revisionNode.entry.changedPaths",
  "SUBVERSIONR_HISTORY_REVISION_DETAILS_TARGET_INVALID"
) "HIS-008 history TreeView Revision Details targets"
Assert-Terms $historyTreeDataProviderTests @(
  "creates revision details targets from current repository revision rows",
  "revisionDetailsTarget(revision)",
  "Open Revision Details",
  "rejects structurally cloned history revision command nodes",
  "SUBVERSIONR_HISTORY_REVISION_DETAILS_TARGET_INVALID"
) "HIS-008 history TreeView Revision Details tests"
Assert-Terms $historyRevisionDetailsDocumentSource @(
  "REVISION_DETAILS_URI_SCHEME = `"svn-r-revision-details`"",
  "HistoryRevisionDetailsDocumentStore",
  "createDocumentUri(target: HistoryRevisionDetailsTarget)",
  "parseRevisionDetailsUri",
  "releaseDocument(uri: RevisionDetailsUriComponents)",
  "renderRevisionDetails",
  "renderUntrustedHistoryText",
  "Copy From: {0}@r{1}"
) "HIS-008 Revision Details document provider"
Assert-Terms $historyRevisionDetailsDocumentTests @(
  "renders loaded history metadata as a readonly revision details document",
  "renders explicit placeholders for nullable loaded history metadata",
  "renders malicious log messages as escaped text without synthetic section breaks",
  "rejects malformed or unknown revision details URIs",
  "rejects revision details URIs whose display revision does not match the stored document",
  "rejects malformed changed-path metadata before creating a document URI",
  "releases stored details documents when the backing document is closed"
) "HIS-008 Revision Details document tests"
Assert-Terms $extensionEntrypoint @(
  "REVISION_DETAILS_URI_SCHEME",
  "HistoryRevisionDetailsDocumentStore",
  "HistoryRevisionDetailsDocumentProvider",
  "registerTextDocumentContentProvider",
  "onDidCloseTextDocument",
  "revisionDetailsStore.releaseDocument(document.uri)",
  "subversionr.history.openRevisionDetails",
  "openRevisionDetails",
  "revisionDetailsStore.createDocumentUri(target)",
  "vscode.open",
  "SVN Revision Details: {0}"
) "HIS-008 extension provider lifecycle and command execution"
Assert-Terms $extensionPackageJson @(
  "onCommand:subversionr.history.openRevisionDetails",
  "subversionr.history.openRevisionDetails",
  "%command.history.openRevisionDetails.title%",
  "viewItem == subversionr.history.repositoryRevision || viewItem == subversionr.history.fileRevision || viewItem == subversionr.history.fileRevision.previousDiffable || viewItem == subversionr.history.lineRevision) && !listMultiSelection",
  '"when": "false"'
) "HIS-008 command contribution and surface placement"
Assert-Terms $extensionPackageNls @(
  '"command.history.openRevisionDetails.title"',
  "SubversionR: Open Revision Details"
) "HIS-008 English package localization"
Assert-Terms $extensionPackageNlsJa @(
  '"command.history.openRevisionDetails.title"'
) "HIS-008 Japanese package localization"
Assert-Terms $extensionPackageNlsZhCn @(
  '"command.history.openRevisionDetails.title"'
) "HIS-008 Chinese package localization"
Assert-Terms $extensionBundleL10n @(
  '"Open Revision Details"',
  '"SVN Revision Details: {0}"',
  "Changed Paths:",
  "Copy From: {0}@r{1}"
) "HIS-008 English runtime localization"
Assert-Terms $extensionBundleL10nJa @(
  '"Open Revision Details"',
  '"SVN Revision Details: {0}"'
) "HIS-008 Japanese runtime localization"
Assert-Terms $extensionBundleL10nZhCn @(
  '"Open Revision Details"',
  '"SVN Revision Details: {0}"'
) "HIS-008 Chinese runtime localization"
Assert-Terms $extensionManifestTests @(
  "onCommand:subversionr.history.openRevisionDetails",
  "command.history.openRevisionDetails.title",
  "subversionr.history.openRevisionDetails",
  "viewItem == subversionr.history.repositoryRevision || viewItem == subversionr.history.fileRevision || viewItem == subversionr.history.fileRevision.previousDiffable || viewItem == subversionr.history.lineRevision) && !listMultiSelection",
  "Open Revision Details",
  "SVN Revision Details: {0}"
) "HIS-008 extension manifest tests"
Assert-RequirementEvidenceRefs $requirementsEvidence "HIS-001" @(
  "docs/plans/m5-content-diff-history.md",
  "crates/subversionr-protocol/src/lib.rs",
  "crates/subversionr-protocol/tests/protocol_contract.rs",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/src/native.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "native/svn-bridge/include/subversionr_bridge.h",
  "native/svn-bridge/src/subversionr_bridge.c",
  "packages/vscode-extension/src/history/historyLogRpcClient.ts",
  "packages/vscode-extension/tests/historyLogRpcClient.test.ts",
  "packages/vscode-extension/src/history/historySettings.ts",
  "packages/vscode-extension/tests/historySettings.test.ts",
  "packages/vscode-extension/src/history/historyTreeDataProvider.ts",
  "packages/vscode-extension/tests/historyTreeDataProvider.test.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/package.nls.json",
  "packages/vscode-extension/package.nls.ja.json",
  "packages/vscode-extension/package.nls.zh-cn.json",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts"
)
Assert-Terms $m5Plan @(
  'The fifth M5 slice adds the backend-only `history/log` foundation on top of libsvn log semantics',
  '`history/log` requires an open `repositoryId`, matching `epoch`, repository-relative `path`, explicit `startRevision`, explicit `endRevision`, explicit `limit`, and explicit boolean log options.',
  'Extra `history/log` request fields are rejected by both the Rust daemon and TypeScript client.',
  'The response echoes repository identity, epoch, path, revision range, and limit, returns revision entries plus changed-path metadata, and labels the source as `libsvn-log`.',
  'The seventh M5 slice turns the backend-only `history/log` foundation into a native VS Code history surface',
  'The extension contributes a native `SVN History` TreeView under the Source Control view container.',
  '`subversionr.showRepositoryLog` opens repository-root history for an explicitly selected open repository and requests `path = "."`.',
  "History requests use explicit bounded parameters",
  'Load More continues below the oldest loaded revision by requesting `r<N-1>` down to `r0`',
  "This slice intentionally does not implement revision detail panes"
) "HIS-001 M5 Repository Log scope"
Assert-Terms $protocolSource @(
  "pub struct HistoryLogChangedPath",
  "pub struct HistoryLogEntry",
  "pub struct HistoryLogResponse",
  "history_log: true"
) "HIS-001 protocol history/log contract"
Assert-Terms $protocolContractTests @(
  "history_log_response_serializes_stable_wire_fields",
  'source: "libsvn-log".to_string()',
  'history/log response must serialize'
) "HIS-001 protocol history/log tests"
Assert-Terms $daemonStateSource @(
  '"history/log" => self.dispatch_history_log',
  "fn dispatch_history_log",
  "match bridge.history_log",
  "fn history_log_request"
) "HIS-001 daemon history/log dispatch"
Assert-Terms $rpcDispatchTests @(
  "history_log_returns_entries_for_open_repository",
  "history_log_accepts_root_history_path",
  "history_log_rejects_invalid_params_before_bridge_call",
  "history_log_requires_matching_open_repository_epoch",
  "history_log_reports_auth_broker_unavailable_on_non_stdio_dispatch"
) "HIS-001 daemon history/log tests"
Assert-Terms $nativeBridgeHeader @(
  "subversionr_bridge_history_log_with_auth"
) "HIS-001 native history/log header"
Assert-Terms $nativeBridgeSource @(
  "bridge_history_log_impl",
  "svn_client_log5",
  "subversionr_bridge_history_log_with_auth"
) "HIS-001 libsvn log bridge"
Assert-Terms $nativeBridgeRustSource @(
  "history_log: HistoryLogFn",
  "subversionr_bridge_history_log_with_auth",
  'source: "libsvn-log".to_string()'
) "HIS-001 native bridge Rust adapter"
Assert-Terms $nativeBridgeTests @(
  "native_bridge_history_log_against_svnserve_routes_credentials_through_broker",
  "native_bridge_history_log_returns_file_revision_entries",
  'assert_eq!(log.source, "libsvn-log")'
) "HIS-001 native bridge tests"
Assert-Terms $historyLogRpcClientSource @(
  "export class HistoryLogRpcClient",
  'sendRequest<unknown>("history/log", validatedRequest)',
  "requireHistoryLogMatchesRequest",
  "MAX_HISTORY_LIMIT = 500"
) "HIS-001 TypeScript history/log client"
Assert-Terms $historyLogRpcClientTests @(
  "sends history/log and parses changed-path metadata",
  "accepts root history requests with an empty response",
  "rejects invalid history request path %j before sending",
  "rejects invalid history limit %j before sending",
  "rejects extra request fields before sending",
  "rejects history responses with mismatched identity fields",
  "rejects history responses from an unexpected source",
  "initializes the backend lazily and forwards history/log"
) "HIS-001 TypeScript history/log tests"
Assert-Terms $historySettingsSource @(
  "readHistorySettings",
  'configuration.get<number>("history.pageSize")',
  'configuration.get<boolean>("history.includeMergedRevisions")',
  "SUBVERSIONR_HISTORY_CONFIG_INVALID"
) "HIS-001 History settings implementation"
Assert-Terms $historySettingsTests @(
  "reads bounded history view settings from the SubversionR configuration section",
  "fails fast for invalid history page size %j",
  "fails fast when includeMergedRevisions is missing or invalid"
) "HIS-001 History settings tests"
Assert-Terms $historyTreeDataProviderSource @(
  "export class HistoryTreeDataProvider",
  "public async showHistory",
  "public async loadMore",
  "public getParent",
  "createRequest",
  "nextStartRevision",
  'path: target.path',
  "startRevision,",
  'endRevision: "r0"',
  "discoverChangedPaths: true",
  "strictNodeHistory: false",
  "includeMergedRevisions: this.settings.includeMergedRevisions",
  'case "repository":',
  "return target.label;",
  '"subversionr.history.repositoryRevision"'
) "HIS-001 native History TreeView implementation"
Assert-Terms $historyTreeDataProviderTests @(
  "loads repository history through bounded explicit history/log parameters",
  "path: `".`"",
  "startRevision: `"head`"",
  "endRevision: `"r0`"",
  "limit: 2",
  "discoverChangedPaths: true",
  "strictNodeHistory: false",
  "includeMergedRevisions: true",
  'label: "C:/wc"',
  'not.toHaveProperty("description")',
  "provides the exact parent chain required by the VS Code reveal API",
  "subversionr.history.repositoryRevision",
  "subversionr.history.loadMore"
) "HIS-001 native History TreeView tests"
Assert-Terms $repositoryCommandControllerSource @(
  "public async showRepositoryLog",
  "selectHistoryRepositorySession",
  "requireRepositoryHistoryCommandTarget",
  "SUBVERSIONR_HISTORY_REPOSITORY_SESSION_STALE",
  'kind: "repository"',
  'path: "."',
  "session.identity.workingCopyRoot"
) "HIS-001 repository command implementation"
Assert-Terms $repositoryCommandControllerTests @(
  "opens repository history for the selected open repository",
  'kind: "subversionr.repositoryHistoryTarget"',
  'repositoryId: "repo-uuid:C:/workspace"',
  "rejects a stale explicit repository history epoch without upgrading it by id",
  "kind: `"repository`"",
  "path: `".`""
) "HIS-001 repository command tests"
Assert-Terms $extensionEntrypoint @(
  "new HistoryTreeDataProvider",
  "new HistoryTreeViewController",
  'vscode.window.createTreeView("subversionr.history"',
  "historyTreeViewController.showHistory(target)",
  "repositoryHistoryCommandArgument(commandArgument, sourceControlRepositoryHistoryTargets)",
  'vscode.commands.registerCommand("subversionr.showRepositoryLog"',
  'vscode.commands.registerCommand("subversionr.history.loadMore"'
) "HIS-001 extension activation"
Assert-Terms $extensionPackageJson @(
  "onCommand:subversionr.showRepositoryLog",
  '"subversionr.showRepositoryLog"',
  '"subversionr.history.loadMore"',
  '"views"',
  '"scm"',
  '"id": "subversionr.history"',
  "%view.history.name%",
  "%command.showRepositoryLog.title%",
  "%command.history.loadMore.title%",
  '"subversionr.history.pageSize"',
  '"subversionr.history.includeMergedRevisions"'
) "HIS-001 package command, view, and settings contribution"
Assert-Terms $extensionPackageNls @(
  '"command.showRepositoryLog.title"',
  '"command.history.loadMore.title"',
  '"view.history.name"',
  '"configuration.history.pageSize.description"',
  '"configuration.history.includeMergedRevisions.description"'
) "HIS-001 English package localization"
Assert-Terms $extensionPackageNlsJa @(
  '"command.showRepositoryLog.title"',
  '"command.history.loadMore.title"',
  '"view.history.name"',
  '"configuration.history.pageSize.description"',
  '"configuration.history.includeMergedRevisions.description"'
) "HIS-001 Japanese package localization"
Assert-Terms $extensionPackageNlsZhCn @(
  '"command.showRepositoryLog.title"',
  '"command.history.loadMore.title"',
  '"view.history.name"',
  '"configuration.history.pageSize.description"',
  '"configuration.history.includeMergedRevisions.description"'
) "HIS-001 Chinese package localization"
Assert-Terms $extensionBundleL10n @(
  '"Load More"',
  '"Open an SVN file or repository history."',
  '"No SVN history entries found."'
) "HIS-001 English runtime localization"
Assert-Terms $extensionBundleL10nJa @(
  '"Load More"'
) "HIS-001 Japanese runtime localization"
Assert-Terms $extensionBundleL10nZhCn @(
  '"Load More"'
) "HIS-001 Chinese runtime localization"
Assert-Terms $extensionManifestTests @(
  "onCommand:subversionr.showRepositoryLog",
  "contributes a native SCM history view",
  "command.showRepositoryLog.title",
  "subversionr.showRepositoryLog",
  "subversionr.history.loadMore",
  'id: "subversionr.history"',
  'name: "%view.history.name%"',
  "subversionr.history.pageSize",
  "subversionr.history.includeMergedRevisions",
  "localizes runtime extension strings in %s",
  "Load More"
) "HIS-001 extension manifest tests"
Assert-RequirementEvidenceRefs $requirementsEvidence "HIS-002" @(
  "docs/plans/m5-content-diff-history.md",
  "crates/subversionr-protocol/src/lib.rs",
  "crates/subversionr-protocol/tests/protocol_contract.rs",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/src/native.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "native/svn-bridge/include/subversionr_bridge.h",
  "native/svn-bridge/src/subversionr_bridge.c",
  "packages/vscode-extension/src/history/historyLogRpcClient.ts",
  "packages/vscode-extension/tests/historyLogRpcClient.test.ts",
  "packages/vscode-extension/src/history/historySettings.ts",
  "packages/vscode-extension/tests/historySettings.test.ts",
  "packages/vscode-extension/src/history/historyTreeDataProvider.ts",
  "packages/vscode-extension/tests/historyTreeDataProvider.test.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/package.nls.json",
  "packages/vscode-extension/package.nls.ja.json",
  "packages/vscode-extension/package.nls.zh-cn.json",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1",
  "scripts/release/capture-vscode-renderer-ui.mjs"
)
Assert-Terms $m5Plan @(
  'The seventh M5 slice turns the backend-only `history/log` foundation into a native VS Code history surface',
  '`subversionr.showFileHistory` opens file history only from concrete SubversionR SCM resource states for versioned local files and conflicts.',
  "File history rejects unversioned, ignored, external, incoming, directory, repository-root, and spoofed resource states with stable command error codes.",
  "File history validates the current Source Control projection before opening the view and uses the projection-canonical repository-relative path rather than untrusted command-argument casing.",
  'History requests use explicit bounded parameters: `startRevision = "head"` for the first page, `endRevision = "r0"`, `discoverChangedPaths = true`, `strictNodeHistory = false`, and a configured `limit` constrained to `1..=500`.',
  '`strictNodeHistory = false` is used deliberately so default file history follows SVN copy history rather than presenting a Git-style file identity.',
  "The view renders a target root, revision rows, changed-path children, copy-from metadata, localized empty/placeholder rows, refresh, and a foreground-only Load More command.",
  'Load More continues below the oldest loaded revision by requesting `r<N-1>` down to `r0`'
) "HIS-002 M5 File History copy-following scope"
Assert-Terms $m5Plan @(
  'The request exposes libsvn-aligned options as explicit booleans: `discoverChangedPaths`, `strictNodeHistory`, and `includeMergedRevisions`.',
  '`strictNodeHistory = false` is used deliberately so default file history follows SVN copy history rather than presenting a Git-style file identity.'
) "HIS-002 public file-history requirement coverage"
Assert-Terms $protocolSource @(
  "pub struct HistoryLogChangedPath",
  "pub copy_from_path: Option<String>",
  "pub copy_from_revision: Option<i64>",
  "pub changed_paths: Vec<HistoryLogChangedPath>"
) "HIS-002 protocol changed-path copy metadata"
Assert-Terms $protocolContractTests @(
  "history_log_response_serializes_stable_wire_fields",
  'json["entries"][0]["changedPaths"][0]["copyFromPath"]',
  'json["entries"][0]["changedPaths"][0]["copyFromRevision"]'
) "HIS-002 protocol copy metadata tests"
Assert-Terms $daemonStateSource @(
  '"history/log" => self.dispatch_history_log',
  "strictNodeHistory",
  "discoverChangedPaths"
) "HIS-002 daemon history/log options"
Assert-Terms $rpcDispatchTests @(
  "history_log_returns_entries_for_open_repository",
  '"path":"src/main.c"',
  '"discoverChangedPaths":true',
  '"strictNodeHistory":true'
) "HIS-002 daemon file history/log dispatch tests"
Assert-Terms $nativeBridgeHeader @(
  "subversionr_bridge_history_log_with_auth"
) "HIS-002 native history/log header"
Assert-Terms $nativeBridgeSource @(
  "svn_client_log5",
  "discover_changed_paths ? TRUE : FALSE",
  "strict_node_history ? TRUE : FALSE",
  "bridge_log_receiver"
) "HIS-002 libsvn log bridge options"
Assert-Terms $nativeBridgeRustSource @(
  "history_log: HistoryLogFn",
  "copy_from_path",
  "copy_from_revision"
) "HIS-002 native bridge copy metadata adapter"
Assert-Terms $nativeBridgeTests @(
  "native_bridge_history_log_returns_file_revision_entries",
  "native_bridge_history_log_against_svnserve_routes_credentials_through_broker"
) "HIS-002 native bridge file history tests"
Assert-Terms $historyLogRpcClientSource @(
  "export class HistoryLogRpcClient",
  "strictNodeHistory",
  "copyFromPath",
  "copyFromRevision",
  'if ((copyFromPath === null) !== (copyFromRevision === null))'
) "HIS-002 TypeScript history/log copy metadata client"
Assert-Terms $historyLogRpcClientTests @(
  "sends history/log and parses changed-path metadata",
  "copyFromPath: null",
  "copyFromRevision: null",
  "strictNodeHistory: false"
) "HIS-002 TypeScript history/log copy metadata tests"
Assert-Terms $historySettingsSource @(
  "readHistorySettings",
  'configuration.get<number>("history.pageSize")',
  'configuration.get<boolean>("history.includeMergedRevisions")'
) "HIS-002 History settings dependency"
Assert-Terms $historySettingsTests @(
  "reads bounded history view settings from the SubversionR configuration section",
  "fails fast for invalid history page size %j"
) "HIS-002 History settings tests"
Assert-Terms $historyTreeDataProviderSource @(
  "export class HistoryTreeDataProvider",
  "public async showHistory",
  "public async loadMore",
  "createRequest",
  'path: target.path',
  "startRevision,",
  'endRevision: "r0"',
  "discoverChangedPaths: true",
  "strictNodeHistory: false",
  'this.options.localize("from {0}@r{1}", changedPath.copyFromPath, changedPath.copyFromRevision)',
  "changedPath.copyFromPath",
  "changedPath.copyFromRevision"
) "HIS-002 native File History TreeView implementation"
Assert-Terms $historyTreeDataProviderTests @(
  "loads file history with copy-following SVN semantics and appends older pages",
  'path: "src/main.c"',
  'startRevision: "head"',
  'startRevision: "r7"',
  "discoverChangedPaths: true",
  "strictNodeHistory: false",
  "includeMergedRevisions: false",
  "renders changed paths under revision entries without doing extra backend work",
  "copyFromPath: `"/branches/feature/src/copied.c`"",
  "copyFromRevision: 4",
  "l10n:from /branches/feature/src/copied.c@r4"
) "HIS-002 native File History TreeView tests"
Assert-Terms $repositoryCommandControllerSource @(
  "public async showFileHistoryResource",
  "contexts: LOCAL_HISTORY_FILE_CONTEXT_VALUES",
  "allowEditorUri: true",
  'target.path === "."',
  "findProjectionResource(projection, target)",
  'kind: "file"',
  "path: resource.path",
  "label: resource.path"
) "HIS-002 file history command implementation"
Assert-Terms $repositoryCommandControllerTests @(
  "opens file history for a selected versioned SVN file using the projection canonical path",
  "showFileHistoryResource",
  'contextValue: "subversionr.changedFile.baseDiffable"',
  'subversionrResourceKind: "file"',
  'path: "src/main.c"',
  'label: "src/main.c"',
  "rejects %s SCM resources for file history",
  "fails fast when file history state is unavailable"
) "HIS-002 file history command tests"
Assert-Terms $extensionEntrypoint @(
  'vscode.commands.registerCommand("subversionr.showFileHistory"',
  "repositoryCommandController.showFileHistoryResource(...resourceStates)"
) "HIS-002 extension command registration"
Assert-Terms $extensionPackageJson @(
  "onCommand:subversionr.showFileHistory",
  '"subversionr.showFileHistory"',
  "%command.showFileHistory.title%"
) "HIS-002 package command contribution"
Assert-Terms $extensionPackageNls @(
  '"command.showFileHistory.title"'
) "HIS-002 English package localization"
Assert-Terms $extensionPackageNlsJa @(
  '"command.showFileHistory.title"'
) "HIS-002 Japanese package localization"
Assert-Terms $extensionPackageNlsZhCn @(
  '"command.showFileHistory.title"'
) "HIS-002 Chinese package localization"
Assert-Terms $extensionBundleL10n @(
  '"File History"',
  '"from {0}@r{1}"'
) "HIS-002 English runtime localization"
Assert-Terms $extensionBundleL10nJa @(
  '"File History"',
  '"from {0}@r{1}"'
) "HIS-002 Japanese runtime localization"
Assert-Terms $extensionBundleL10nZhCn @(
  '"File History"',
  '"from {0}@r{1}"'
) "HIS-002 Chinese runtime localization"
Assert-Terms $extensionManifestTests @(
  "onCommand:subversionr.showFileHistory",
  "command.showFileHistory.title",
  "subversionr.showFileHistory",
  "File History",
  "from {0}@r{1}"
) "HIS-002 extension manifest tests"
Assert-RequirementEvidenceRefs $requirementsEvidence "HIS-003" @(
  "docs/plans/m5-content-diff-history.md",
  "packages/vscode-extension/src/history/lineHistoryCommandController.ts",
  "packages/vscode-extension/tests/lineHistoryCommandController.test.ts",
  "packages/vscode-extension/src/history/historyBlameRpcClient.ts",
  "packages/vscode-extension/tests/historyBlameRpcClient.test.ts",
  "packages/vscode-extension/src/history/historyLogRpcClient.ts",
  "packages/vscode-extension/tests/historyLogRpcClient.test.ts",
  "packages/vscode-extension/src/editor/activeEditorContextService.ts",
  "packages/vscode-extension/tests/activeEditorContextService.test.ts",
  "packages/vscode-extension/src/history/historyTreeDataProvider.ts",
  "packages/vscode-extension/tests/historyTreeDataProvider.test.ts",
  "packages/vscode-extension/src/history/historyRevisionDetailsDocument.ts",
  "packages/vscode-extension/tests/historyRevisionDetailsDocument.test.ts",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/package.nls.json",
  "packages/vscode-extension/package.nls.ja.json",
  "packages/vscode-extension/package.nls.zh-cn.json",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts"
)
Assert-Terms $m5Plan @(
  "The twenty-sixth M5 slice adds a conservative active-editor Line History command",
  '`subversionr.showLineHistory` is contributed to the editor context menu only when `subversionr.activeEditorLineHistoryFile` is true',
  "VS Code's 0-based inclusive selection lines are normalized to a 1-based BASE blame window",
  'The command requests one foreground `history/blame` window',
  "Unique concrete line revisions are capped at 500",
  'then each revision is resolved through exactly one bounded `history/log` request',
  'The native `SVN History` TreeView accepts a preloaded `line` target for this command',
  'This slice intentionally does not implement a backend `history/line` RPC'
) "HIS-003 M5 Line History scope"
Assert-Terms $lineHistoryCommandControllerSource @(
  "export class LineHistoryCommandController",
  "public async showLineHistory",
  "selectionLineRange",
  "concreteLineRevisions",
  "lineHistoryViewTarget",
  'pegRevision: "base"',
  'startRevision: "r0"',
  'endRevision: "base"',
  'ignoreWhitespace: "none"',
  "includeMergedRevisions(): boolean;",
  "const includeMergedRevisions = this.options.includeMergedRevisions();",
  "includeMergedRevisions,",
  "MAX_LINE_HISTORY_LINE_LIMIT = 5_000",
  "MAX_LINE_HISTORY_REVISION_COUNT = 500",
  "startRevision: revisionId",
  "endRevision: revisionId",
  "discoverChangedPaths: false",
  "strictNodeHistory: false",
  "SUBVERSIONR_LINE_HISTORY_TARGET_INVALID",
  "SUBVERSIONR_LINE_HISTORY_SELECTION_INVALID",
  "SUBVERSIONR_LINE_HISTORY_BLAME_INCOMPLETE",
  "SUBVERSIONR_LINE_HISTORY_LOG_INCOMPLETE",
  "SUBVERSIONR_LINE_HISTORY_REVISION_LIMIT_EXCEEDED",
  'recordFailure("Line History", error)',
  'localize("Show Log")',
  "SVN {0} failed. Open the SubversionR log for details."
) "HIS-003 Line History command implementation"
Assert-Terms $lineHistoryCommandControllerTests @(
  "opens preloaded line history for a safe active editor selection",
  "records failures and offers the redacted log without blocking on the notification",
  "includes merged revisions in line blame and revision log requests when history settings enable them",
  "uses the current line for an empty selection and normalizes reversed selections",
  "blocks line history in untrusted workspaces before blame or log side effects",
  "does not query history for unsafe line-history target: %s",
  "does not query history when line history is disabled",
  "does not query history for invalid selection: %s",
  "does not show partial line history when blame rows are local, unknown, incomplete, or non-contiguous",
  "does not show partial line history when any single-revision log lookup is missing or mismatched",
  "fails before log fanout when the selected lines exceed the unique revision cap",
  "lineStart: 3",
  "lineLimit: 3",
  "startRevision: `"r9`"",
  "endRevision: `"r9`"",
  "discoverChangedPaths: false",
  "strictNodeHistory: false",
  "kind: `"line`""
) "HIS-003 Line History command tests"
Assert-Terms $historyBlameRpcClientSource @(
  'sendRequest<unknown>("history/blame", validatedRequest)',
  "requireHistoryBlameMatchesRequest"
) "HIS-003 blame RPC dependency"
Assert-Terms $historyBlameRpcClientTests @(
  "sends history/blame and parses line attribution metadata",
  "rejects response lines outside the requested contiguous window"
) "HIS-003 blame RPC tests"
Assert-Terms $historyLogRpcClientSource @(
  'sendRequest<unknown>("history/log", validatedRequest)',
  "requireHistoryLogMatchesRequest"
) "HIS-003 log RPC dependency"
Assert-Terms $historyLogRpcClientTests @(
  "sends history/log and parses changed-path metadata",
  "rejects history responses with mismatched identity fields"
) "HIS-003 log RPC tests"
Assert-Terms $activeEditorContextServiceSource @(
  "ACTIVE_EDITOR_LINE_HISTORY_FILE_CONTEXT",
  "subversionr.activeEditorLineHistoryFile",
  "isLineHistoryFileProjectedResource",
  "settings.enabled",
  "document.lineCount <= settings.maxFileLines",
  'resource.contextValue === "subversionr.changedFile"',
  'resource.entry.textStatus === "normal"'
) "HIS-003 active-editor context implementation"
Assert-Terms $activeEditorContextServiceTests @(
  "sets only history context for projected files that are not base-diffable",
  "keeps line history context false for %s",
  "subversionr.activeEditorLineHistoryFile"
) "HIS-003 active-editor context tests"
Assert-Terms $historyTreeDataProviderSource @(
  "public showLineHistory",
  'target.kind === "line"',
  '"subversionr.history.lineRevision"',
  'localize("Line History: {0}", target.label)'
) "HIS-003 History TreeView preloaded line target"
Assert-Terms $historyTreeDataProviderTests @(
  "renders preloaded line history without backend pagination or file compare actions",
  "provider.showLineHistory",
  "historyClient.getLog).not.toHaveBeenCalled",
  "l10n:Line History: src/main.c:3-5",
  "subversionr.history.lineRevision"
) "HIS-003 History TreeView tests"
Assert-Terms $historyRevisionDetailsDocumentSource @(
  '"line"',
  "Line"
) "HIS-003 Revision Details line target rendering"
Assert-Terms $historyRevisionDetailsDocumentTests @(
  "renders line history revision details targets",
  'targetKind: "line"',
  "l10n:History Target: Line src/main.c:3-5"
) "HIS-003 Revision Details line target tests"
Assert-Terms $extensionEntrypoint @(
  "new LineHistoryCommandController",
  "showLineHistory: async (target, entries)",
  "historyTreeViewController.showLineHistory(target, entries)",
  'vscode.commands.registerCommand("subversionr.showLineHistory"',
  "lineHistoryCommandController.showLineHistory()"
) "HIS-003 extension activation"
Assert-Terms $extensionPackageJson @(
  "onCommand:subversionr.showLineHistory",
  '"subversionr.showLineHistory"',
  "%command.showLineHistory.title%",
  "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorLineHistoryFile",
  '"when": "false"'
) "HIS-003 package command and menu contribution"
Assert-Terms $extensionPackageNls @(
  '"command.showLineHistory.title"'
) "HIS-003 English package localization"
Assert-Terms $extensionPackageNlsJa @(
  '"command.showLineHistory.title"'
) "HIS-003 Japanese package localization"
Assert-Terms $extensionPackageNlsZhCn @(
  '"command.showLineHistory.title"'
) "HIS-003 Chinese package localization"
Assert-Terms $extensionBundleL10n @(
  '"Line History: {0}"',
  '"Show Log"',
  '"SVN {0} failed. Open the SubversionR log for details."'
) "HIS-003 English runtime localization"
Assert-Terms $extensionBundleL10nJa @(
  '"Line History: {0}"',
  '"Show Log"',
  '"SVN {0} failed. Open the SubversionR log for details."'
) "HIS-003 Japanese runtime localization"
Assert-Terms $extensionBundleL10nZhCn @(
  '"Line History: {0}"',
  '"Show Log"',
  '"SVN {0} failed. Open the SubversionR log for details."'
) "HIS-003 Chinese runtime localization"
Assert-Terms $extensionManifestTests @(
  "onCommand:subversionr.showLineHistory",
  "command.showLineHistory.title",
  "subversionr.showLineHistory",
  "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorLineHistoryFile",
  "Line History: {0}",
  "Show Log",
  "SVN {0} failed. Open the SubversionR log for details."
) "HIS-003 extension manifest tests"
Assert-Terms $m5Plan @(
  "The twenty-seventh M5 slice exposes the six existing active-file inspection commands through the Command Palette",
  'Exactly `subversionr.diffWithBase`, `subversionr.diffWithHead`, `subversionr.diffWithPrevious`, `subversionr.showFileHistory`, `subversionr.showLineHistory`, and `subversionr.showBlame`',
  "Nested working copies use the most-specific open working-copy root and never fall back to a parent projection",
  "A property-only modified projected file remains text-stable and is eligible for all six commands",
  "they do not render the property delta",
  "A separate installed Restricted Mode window proves BASE remains visible and executable",
  "It does not request status refresh, full reconciliation, or remote-status polling"
) "HIS-003/HIS-004 M5 active-editor Command Palette scope"
Assert-Terms $roadmap @(
  "exact active-editor Command Palette access to the six canonical BASE/HEAD/PREV/File History/Line History/Blame commands",
  "active-editor Command Palette trusted/Restricted Mode behavior for the six canonical inspection commands"
) "HIS-003/HIS-004 roadmap active-editor Command Palette scope"
Assert-Terms $releaseGates @(
  "sourceControlUiActiveEditorPaletteWorkflow",
  "distinct second local-file working copy whose active projected file is property-only modified",
  "captures renderer DOM/accessibility/screenshot evidence for every selection",
  "SUBVERSIONR_WORKSPACE_UNTRUSTED_OPERATION"
) "HIS-003/HIS-004 installed active-editor Command Palette release gate"
Assert-Terms $publicClaimMatrix @(
  "Active-editor diff, history, and blame Command Palette",
  'Claimed only for eligible files already present in the current local Windows `win32-x64` Source Control projection',
  "property-delta rendering is not claimed",
  "Normal unmodified files absent from the projection",
  "the other five operations require Workspace Trust"
) "HIS-003/HIS-004 public active-editor Command Palette claim boundary"
Assert-Terms $extensionPackageJson @(
  '"command": "subversionr.diffWithBase"',
  '"when": "resourceScheme == file && subversionr.activeEditorBaseDiffable"',
  '"when": "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorBaseDiffable"',
  '"when": "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorPreviousDiffable"',
  '"when": "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorHistoryFile"',
  '"when": "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorLineHistoryFile"'
) "HIS-003/HIS-004 exact active-editor Command Palette clauses"
Assert-Terms $extensionManifestTests @(
  "exposes exactly the six active-editor inspection commands through bounded Command Palette contexts",
  "paletteEntries",
  'expected.get(command) ?? "false"'
) "HIS-003/HIS-004 exact active-editor Command Palette manifest tests"
Assert-Terms $activeEditorContextServiceSource @(
  "export interface ActiveEditorCommandTarget",
  "public commandTarget()",
  "subversionrProjectionGeneration",
  'projection.freshness.repositoryCompleteness !== "stale"',
  "hasTextStableNodeStatus"
) "HIS-003/HIS-004 active-editor validated command target"
Assert-Terms $activeEditorContextServiceTests @(
  "does not expose an active-editor command target for %s",
  "rejects a projected resource from a stale generation",
  "clears active-editor command contexts for a stale projection",
  "targets the most specific projected working copy when repositories are nested",
  "does not fall back to a parent projection when the most specific working copy has no resource",
  "serializes overlapping refreshes so the newest active editor state wins",
  "sets all inspection contexts for a text-stable property-only active file"
) "HIS-003/HIS-004 active-editor command target tests"
Assert-Terms $repositoryCommandControllerSource @(
  "activeEditorResource(): unknown | undefined;",
  "this.activeEditorResourceArgs(resourceStates)",
  "return resourceStates.length === 0 ? [this.options.ui.activeEditorResource()] : resourceStates;",
  "requireOptionalProjectionGeneration(uri, invalid)",
  "activeEditorInvocation",
  "validateEditorProjectionGeneration",
  "isCurrentActiveEditorProjection"
) "HIS-003/HIS-004 canonical zero-argument active-editor routing"
Assert-Terms $repositoryCommandControllerTests @(
  "runs the five resource-backed palette commands against the current active file without arguments",
  "rejects stale active-editor generations for all five resource-backed palette commands",
  "preserves explicit editor URI behavior without applying active-editor freshness metadata"
) "HIS-003/HIS-004 canonical active-editor controller tests"
Assert-Terms $lineHistoryCommandControllerTests @(
  "opens line history for a text-stable property-only active file",
  "does not query line history from a stale projection",
  "does not fall back to a parent repository when a nested working copy projection is missing"
) "HIS-003 active-editor line-history validation tests"
Assert-Terms $installedSourceControlUiE2eScript @(
  "PropertyOnlyTracked",
  "paletteTrackedChangedRevision",
  "runActiveEditorPaletteWorkflow",
  "sourceControlUiActiveEditorPaletteWorkflow",
  "activeEditorPaletteCaptures",
  "runRestrictedActiveEditorPaletteEvidence",
  "restrictedActiveEditorPaletteEvidence",
  "restrictedActiveEditorPaletteCaptures",
  "quickPickAbsentItemText",
  "quickPickItemAbsent",
  "failures.length !== 1",
  "Restricted direct-call cardinality invalid",
  '"DIF-001"',
  '"DIF-002"',
  '"DIF-003"',
  '"HIS-002"',
  '"HIS-003"',
  '"HIS-004"',
  "SUBVERSIONR_WORKSPACE_UNTRUSTED_OPERATION",
  "statusRefreshRequestCountUnchanged",
  "remoteStatusRequestCountUnchanged"
) "HIS-003/HIS-004 installed active-editor Command Palette evidence"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "sourceControlUiActiveEditorPaletteWorkflow",
  "activeEditorPaletteCaptures",
  "restrictedActiveEditorPaletteEvidence",
  "restrictedActiveEditorPaletteCaptures",
  "Trusted active-editor palette evidence should preserve the exact canonical command set and order",
  "Restricted zero-argument direct calls should all record the stable workspace trust code",
  "Installed Source Control UI E2E evidence should trace DIF-001.",
  "Installed Source Control UI E2E evidence should trace HIS-004.",
  "SUBVERSIONR_FAKE_RESTRICTED_EXTRA_FAILURE"
) "HIS-003/HIS-004 installed active-editor Command Palette script tests"
Assert-RequirementEvidenceRefs $requirementsEvidence "HIS-004" @(
  "docs/plans/m5-content-diff-history.md",
  "crates/subversionr-protocol/src/lib.rs",
  "crates/subversionr-protocol/tests/protocol_contract.rs",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/src/native.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "native/svn-bridge/include/subversionr_bridge.h",
  "native/svn-bridge/src/subversionr_bridge.c",
  "packages/vscode-extension/src/history/historyBlameRpcClient.ts",
  "packages/vscode-extension/tests/historyBlameRpcClient.test.ts",
  "packages/vscode-extension/src/history/historyBlameDocument.ts",
  "packages/vscode-extension/tests/historyBlameDocument.test.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/package.nls.json",
  "packages/vscode-extension/package.nls.ja.json",
  "packages/vscode-extension/package.nls.zh-cn.json",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1",
  "scripts/release/capture-vscode-renderer-ui.mjs"
)
Assert-Terms $m5Plan @(
  'The eleventh M5 slice exposes file blame through a readonly VS Code document backed by the existing `history/blame` RPC',
  '`subversionr.showBlame` is contributed for local versioned file SCM resources',
  'The command opens a strict `svn-r-blame` virtual document using fixed explicit BASE blame parameters',
  '`pegRevision = base`',
  '`lineLimit = 5000`',
  'The document provider calls `history/blame`, renders localized metadata, line attribution, uncommitted lines, nullable author/date placeholders, merged-revision markers, and line text decoded from the binary-safe blame payload.',
  'This slice advances `HIS-004` and `PRD-009`',
  "This slice intentionally does not implement active-editor blame"
) "HIS-004 M5 Blame scope"
Assert-Terms $protocolSource @(
  "pub struct HistoryBlameLine",
  "pub struct HistoryBlameResponse",
  "history_blame: true"
) "HIS-004 protocol blame contract"
Assert-Terms $protocolContractTests @(
  "history_blame_response_serializes_stable_wire_fields",
  'source: "libsvn-blame".to_string()',
  'history/blame response must serialize'
) "HIS-004 protocol contract tests"
Assert-Terms $daemonStateSource @(
  '"history/blame" => self.dispatch_history_blame',
  "fn dispatch_history_blame",
  "match bridge.history_blame",
  "fn history_blame_request"
) "HIS-004 daemon dispatch"
Assert-Terms $rpcDispatchTests @(
  "history_blame_returns_windowed_lines_for_open_repository",
  "history_blame_rejects_invalid_params_before_bridge_call",
  "history_blame_requires_matching_open_repository_epoch",
  "history_blame_reports_auth_broker_unavailable_on_non_stdio_dispatch"
) "HIS-004 daemon dispatch tests"
Assert-Terms $nativeBridgeHeader @(
  "subversionr_bridge_blame_line",
  "subversionr_bridge_blame_info",
  "subversionr_bridge_history_blame_with_auth"
) "HIS-004 native bridge header"
Assert-Terms $nativeBridgeSource @(
  "bridge_history_blame_impl",
  "svn_client_blame6",
  "subversionr_bridge_history_blame_with_auth"
) "HIS-004 libsvn blame bridge"
Assert-Terms $nativeBridgeRustSource @(
  "history_blame: HistoryBlameFn",
  "subversionr_bridge_history_blame_with_auth",
  "raw_history_blame_line_to_protocol",
  'source: "libsvn-blame".to_string()'
) "HIS-004 native bridge Rust adapter"
Assert-Terms $nativeBridgeTests @(
  "native_bridge_history_blame_against_svnserve_routes_credentials_through_broker",
  "native_bridge_history_blame_returns_line_revision_entries",
  'assert_eq!(blame.source, "libsvn-blame")',
  "history blame should include lines from the remote svnserve file"
) "HIS-004 native bridge tests"
Assert-Terms $historyBlameRpcClientSource @(
  "export class HistoryBlameRpcClient",
  'sendRequest<unknown>("history/blame", validatedRequest)',
  "requireHistoryBlameMatchesRequest",
  "MAX_BLAME_LINE_LIMIT = 5_000"
) "HIS-004 extension blame RPC client"
Assert-Terms $historyBlameRpcClientTests @(
  "sends history/blame and parses line attribution metadata",
  "accepts an explicit one-line window with alternate blame options",
  "rejects invalid blame request path %j before sending",
  "rejects response lines outside the requested contiguous window",
  "initializes the backend lazily and forwards history/blame"
) "HIS-004 extension blame RPC tests"
Assert-Terms $historyBlameDocumentSource @(
  "BLAME_DOCUMENT_URI_SCHEME",
  "export class HistoryBlameDocumentProvider",
  "createBlameDocumentUriComponents",
  "parseBlameDocumentUri",
  "requireFixedBlameContract",
  'pegRevision !== "base"',
  'startRevision !== "r0"',
  'endRevision !== "base"',
  "MAX_BLAME_LINE_LIMIT = 5_000",
  "renderBlameDocument",
  "decodeLine",
  "SVN Blame: {0}",
  "Merged from r{0}"
) "HIS-004 readonly blame document implementation"
Assert-Terms $historyBlameDocumentTests @(
  "encodes blame request identity into a custom URI with generation-based invalidation",
  "parses a blame document URI into a strict history/blame request",
  "rejects malformed blame document URIs and duplicate query keys",
  "rejects blame document URI parameters outside the fixed M5k BASE blame contract",
  "loads file blame through history/blame and renders a localized readonly document",
  "renders nullable non-local blame revisions as unknown instead of uncommitted",
  "rejects blame documents in untrusted workspaces before history/blame"
) "HIS-004 readonly blame document tests"
Assert-Terms $repositoryCommandControllerSource @(
  "public async showBlameResource",
  "showBlame(target",
  'pegRevision: "base"',
  'startRevision: "r0"',
  'endRevision: "base"',
  "lineLimit: 5000",
  'ignoreWhitespace: "none"',
  "includeMergedRevisions: this.options.includeMergedRevisions()"
) "HIS-004 repository command target implementation"
Assert-Terms $repositoryCommandControllerTests @(
  "opens file blame for a selected versioned SVN file using the projection canonical path",
  "includes merged revisions in explicit blame documents when history settings enable them",
  "rejects unversioned and directory SCM resources for file blame"
) "HIS-004 repository command target tests"
Assert-Terms $extensionEntrypoint @(
  "HistoryBlameDocumentProvider",
  "BLAME_DOCUMENT_URI_SCHEME",
  "vscode.workspace.registerTextDocumentContentProvider",
  "createBlameDocumentUriComponents(target)",
  "vscode.l10n.t(`"SVN Blame: {0}`", target.path)",
  "subversionr.showBlame"
) "HIS-004 extension activation and command"
Assert-Terms $extensionPackageJson @(
  "onCommand:subversionr.showBlame",
  '"subversionr.showBlame"',
  "%command.showBlame.title%"
) "HIS-004 package command contribution"
Assert-Terms $extensionPackageNls @(
  '"command.showBlame.title"'
) "HIS-004 English package localization"
Assert-Terms $extensionPackageNlsJa @(
  '"command.showBlame.title"'
) "HIS-004 Japanese package localization"
Assert-Terms $extensionPackageNlsZhCn @(
  '"command.showBlame.title"'
) "HIS-004 Chinese package localization"
Assert-Terms $extensionBundleL10n @(
  '"SVN Blame: {0}"',
  '"Repository ID: {0}"',
  '"Resolved Revision Range: r{0} - r{1}"',
  '"Merged from r{0}"',
  '"Uncommitted"',
  '"Unknown author"'
) "HIS-004 English runtime localization"
Assert-Terms $extensionBundleL10nJa @(
  '"SVN Blame: {0}"',
  '"Repository ID: {0}"',
  '"Merged from r{0}"'
) "HIS-004 Japanese runtime localization"
Assert-Terms $extensionBundleL10nZhCn @(
  '"SVN Blame: {0}"',
  '"Repository ID: {0}"',
  '"Merged from r{0}"'
) "HIS-004 Chinese runtime localization"
Assert-Terms $extensionManifestTests @(
  "onCommand:subversionr.showBlame",
  "command.showBlame.title",
  "subversionr.showBlame",
  'for (const state of ["subversionr.conflicted", "subversionr.changedFile"])',
  ').toContain("subversionr.showBlame")',
  "SVN Blame: {0}",
  "Merged from r{0}"
) "HIS-004 extension manifest tests"
Assert-RequirementEvidenceRefs $requirementsEvidence "HIS-005" @(
  "docs/plans/m5-content-diff-history.md",
  "packages/vscode-extension/src/history/historyBlameRpcClient.ts",
  "packages/vscode-extension/tests/historyBlameRpcClient.test.ts",
  "packages/vscode-extension/src/history/historyLogRpcClient.ts",
  "packages/vscode-extension/tests/historyLogRpcClient.test.ts",
  "packages/vscode-extension/src/lens/lensSettings.ts",
  "packages/vscode-extension/tests/lensSettings.test.ts",
  "packages/vscode-extension/src/lens/currentLineBlameStatusBarService.ts",
  "packages/vscode-extension/tests/currentLineBlameStatusBarService.test.ts",
  "packages/vscode-extension/src/lens/currentLineBlameHoverProvider.ts",
  "packages/vscode-extension/tests/currentLineBlameHoverProvider.test.ts",
  "packages/vscode-extension/src/scm/sourceControlResourceStore.ts",
  "packages/vscode-extension/tests/sourceControlResourceStore.test.ts",
  "packages/vscode-extension/src/scm/sourceControlProjectionService.ts",
  "packages/vscode-extension/tests/sourceControlProjectionService.test.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/package.nls.json",
  "packages/vscode-extension/package.nls.ja.json",
  "packages/vscode-extension/package.nls.zh-cn.json",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts"
)
Assert-Terms $m5Plan @(
  "The twenty-second M5 slice adds a conservative current-line blame status bar baseline",
  'The extension creates one contextual status bar item with a stable VS Code item id',
  'The status bar requests exactly one foreground `history/blame` line',
  "lineStart = active editor line + 1",
  "lineLimit = 1",
  'This slice advances `HIS-005`, `PRD-009`, and `PER-011`',
  "The twenty-third M5 slice adds a conservative current-line blame hover baseline",
  'The extension registers one `file`-scheme VS Code `HoverProvider` for `subversionr.lens.hover`',
  'For eligible files, the provider requests exactly one `history/blame` line',
  'The hover displays localized `SVN Blame`, revision, author, and date metadata',
  'This slice advances `HIS-005`, `HIS-007`, `PRD-009`, and `PER-011`',
  "The twenty-fifth M5 slice enriches the conservative current-line blame hover with a bounded SVN log summary",
  'requests exactly one `history/log` entry for the same projected path and revision',
  'The hover now displays localized `Log Message:` metadata with the first non-empty trimmed log-message line',
  "This slice intentionally does not implement BASE-to-WORKING diff line mapping"
) "HIS-005 M5 current-line blame scope"
Assert-Terms $historyBlameRpcClientSource @(
  "export class HistoryBlameRpcClient",
  'sendRequest<unknown>("history/blame", validatedRequest)',
  "requireHistoryBlameMatchesRequest",
  "MAX_BLAME_LINE_LIMIT = 5_000"
) "HIS-005 blame RPC client contract"
Assert-Terms $historyBlameRpcClientTests @(
  "sends history/blame and parses line attribution metadata",
  "accepts an explicit one-line window with alternate blame options",
  "rejects invalid blame request path %j before sending",
  "rejects response lines outside the requested contiguous window",
  "initializes the backend lazily and forwards history/blame"
) "HIS-005 blame RPC client tests"
Assert-Terms $historyLogRpcClientSource @(
  'sendRequest<unknown>("history/log", validatedRequest)',
  "requireHistoryLogMatchesRequest"
) "HIS-005 hover log RPC client contract"
Assert-Terms $historyLogRpcClientTests @(
  "sends history/log and parses changed-path metadata",
  "rejects invalid history limit %j before sending",
  "rejects history responses with mismatched identity fields",
  "rejects history responses from an unexpected source"
) "HIS-005 hover log RPC client tests"
Assert-Terms $lensSettingsSource @(
  "currentLine: boolean;",
  "hover: boolean;",
  'configuration.get("lens.currentLine", true)',
  'configuration.get("lens.hover", true)'
) "HIS-005 Lens settings implementation"
Assert-Terms $lensSettingsTests @(
  "reads explicit SVN Lens defaults from the SubversionR configuration namespace",
  "fails fast on malformed SVN Lens settings",
  "does not read legacy or svnNative setting aliases",
  '"svnNative.lens.currentLine": false',
  '"svn.lens.currentLine": false'
) "HIS-005 Lens settings tests"
Assert-Terms $currentLineBlameStatusBarSource @(
  "export class CurrentLineBlameStatusBarService",
  "DEBOUNCE_MS = 250",
  "targetForActiveEditor",
  "getProjectedResource(",
  'pegRevision: "base"',
  'startRevision: "r0"',
  'endRevision: "base"',
  "lineLimit: 1",
  'ignoreWhitespace: "none"',
  "includeMergedRevisions: this.options.includeMergedRevisions()",
  "settings.currentLine",
  "settings.maxFileLines",
  "showBlameLine",
  "subversionr.showBlame",
  "SVN blame",
  "SVN r{0} {1}",
  "SVN blame for {0}:{1}"
) "HIS-005 current-line status bar implementation"
Assert-Terms $currentLineBlameStatusBarTests @(
  "shows a localized single-line blame status for a projected text-stable SVN file",
  "includes merged revisions in current-line blame status requests when history settings enable them",
  "does not request blame in untrusted workspaces",
  "does not request blame for %s resources until working-copy line mapping exists",
  "hides without projection lookup when current-line blame is disabled or the editor is outside open repositories",
  "does not request blame for dirty editors until working-copy line mapping exists",
  "hides previously shown blame immediately when the active editor becomes dirty",
  "discards stale blame results when the active editor changes during an in-flight request",
  "hides the status item when foreground one-line blame fails"
) "HIS-005 current-line status bar tests"
Assert-Terms $currentLineBlameHoverProviderSource @(
  "export class CurrentLineBlameHoverProvider",
  "public async provideHover",
  "targetForDocument",
  "getProjectedResource(",
  'pegRevision: "base"',
  'startRevision: "r0"',
  'endRevision: "base"',
  "lineLimit: 1",
  "const includeMergedRevisions = this.options.includeMergedRevisions();",
  "includeMergedRevisions,",
  "getLog({",
  "startRevision: revision",
  "endRevision: revision",
  "limit: 1",
  "renderHoverMarkdown",
  "escapeMarkdown",
  "firstLogMessageLine",
  "SVN Blame: {0}",
  "Revision {0}",
  "Author: {0}",
  "Date: {0}",
  "Log Message:",
  "No log message"
) "HIS-005 current-line hover implementation"
Assert-Terms $currentLineBlameHoverProviderTests @(
  "returns localized one-line SVN blame hover with the first log-message line",
  "includes merged revisions in current-line blame hover requests when history settings enable them",
  "does not request blame or log in untrusted workspaces",
  "returns a localized empty-log summary for %s log messages",
  "does not request blame when hover Lens is disabled or the file is outside open repositories",
  "does not request blame for %s",
  "does not return a hover when cancellation happens before or after the blame request",
  "does not return a hover when cancellation happens after the log request",
  "hides %s blame rows without requesting log summaries",
  "returns no hover when projection lookup, blame, or log request fails",
  "returns no hover when the single-revision log entry is missing or mismatched"
) "HIS-005 current-line hover tests"
Assert-Terms $sourceControlResourceStoreSource @(
  "public getProjectedResource",
  "localResourcesByCaseInsensitivePath.get(caseInsensitivePath(path))"
) "HIS-005 projection-backed current-line lookup"
Assert-Terms $sourceControlProjectionServiceSource @(
  "public getProjectedResource",
  "return this.store.getProjectedResource(repositoryId, path, pathCase);"
) "HIS-005 projection service current-line lookup"
Assert-Terms $repositoryCommandControllerSource @(
  "public async showBlameResource",
  "showBlame(target"
) "HIS-005 status command target implementation"
Assert-Terms $repositoryCommandControllerTests @(
  "opens file blame for a selected versioned SVN file using the projection canonical path"
) "HIS-005 status command target tests"
Assert-Terms $extensionEntrypoint @(
  "new CurrentLineBlameHoverProvider<vscode.Hover, vscode.MarkdownString>",
  "vscode.languages.registerHoverProvider",
  "new CurrentLineBlameStatusBarService",
  "vscode.window.createStatusBarItem",
  '"subversionr.currentLineBlame"',
  "vscode.StatusBarAlignment.Right",
  "refreshCurrentLineBlame",
  "onDidChangeTextEditorSelection",
  "onDidChangeTextDocument",
  "projectionCurrentLineBlameRefresh",
  "sessionCurrentLineBlameRefresh"
) "HIS-005 extension activation and refresh"
Assert-Terms $extensionPackageJson @(
  '"subversionr.lens.currentLine"',
  '"subversionr.lens.hover"',
  "%configuration.lens.currentLine.description%",
  "%configuration.lens.hover.description%"
) "HIS-005 package setting contributions"
Assert-Terms $extensionPackageNls @(
  '"configuration.lens.currentLine.description"',
  '"configuration.lens.hover.description"'
) "HIS-005 English package localization"
Assert-Terms $extensionPackageNlsJa @(
  '"configuration.lens.currentLine.description"',
  '"configuration.lens.hover.description"'
) "HIS-005 Japanese package localization"
Assert-Terms $extensionPackageNlsZhCn @(
  '"configuration.lens.currentLine.description"',
  '"configuration.lens.hover.description"'
) "HIS-005 Chinese package localization"
Assert-Terms $extensionBundleL10n @(
  '"SVN blame"',
  '"Loading SVN blame for {0}:{1}"',
  '"SVN r{0} {1}"',
  '"SVN blame for {0}:{1}"',
  '"SVN Blame: {0}"',
  '"Revision {0}"',
  '"Author: {0}"',
  '"Date: {0}"',
  '"Log Message:"',
  '"No log message"'
) "HIS-005 English runtime localization"
Assert-Terms $extensionBundleL10nJa @(
  '"SVN blame"',
  '"Loading SVN blame for {0}:{1}"',
  '"SVN r{0} {1}"',
  '"SVN blame for {0}:{1}"',
  '"SVN Blame: {0}"',
  '"Revision {0}"',
  '"Author: {0}"',
  '"Date: {0}"',
  '"Log Message:"',
  '"No log message"'
) "HIS-005 Japanese runtime localization"
Assert-Terms $extensionBundleL10nZhCn @(
  '"SVN blame"',
  '"Loading SVN blame for {0}:{1}"',
  '"SVN r{0} {1}"',
  '"SVN blame for {0}:{1}"',
  '"SVN Blame: {0}"',
  '"Revision {0}"',
  '"Author: {0}"',
  '"Date: {0}"',
  '"Log Message:"',
  '"No log message"'
) "HIS-005 Chinese runtime localization"
Assert-Terms $extensionManifestTests @(
  "subversionr.lens.currentLine",
  "subversionr.lens.hover",
  "configuration.lens.currentLine.description",
  "configuration.lens.hover.description",
  "SVN blame",
  "Loading SVN blame for {0}:{1}",
  "SVN r{0} {1}",
  "SVN blame for {0}:{1}",
  "SVN Blame: {0}",
  "Revision {0}",
  "Author: {0}",
  "Date: {0}",
  "Log Message:",
  "No log message"
) "HIS-005 extension manifest tests"
Assert-RequirementEvidenceRefs $requirementsEvidence "HIS-007" @(
  "docs/plans/m5-content-diff-history.md",
  "packages/vscode-extension/src/history/historyBlameRpcClient.ts",
  "packages/vscode-extension/tests/historyBlameRpcClient.test.ts",
  "packages/vscode-extension/src/lens/lensSettings.ts",
  "packages/vscode-extension/tests/lensSettings.test.ts",
  "packages/vscode-extension/src/lens/symbolHistoryCodeLensProvider.ts",
  "packages/vscode-extension/tests/symbolHistoryCodeLensProvider.test.ts",
  "packages/vscode-extension/src/scm/sourceControlResourceStore.ts",
  "packages/vscode-extension/tests/sourceControlResourceStore.test.ts",
  "packages/vscode-extension/src/scm/sourceControlProjectionService.ts",
  "packages/vscode-extension/tests/sourceControlProjectionService.test.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/package.nls.json",
  "packages/vscode-extension/package.nls.ja.json",
  "packages/vscode-extension/package.nls.zh-cn.json",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts"
)
Assert-Terms $m5Plan @(
  "The twenty-fourth M5 slice adds the optional symbol history CodeLens baseline",
  'The extension registers a second `file`-scheme VS Code `CodeLensProvider` for `subversionr.lens.symbols`',
  '`provideCodeLenses` performs only local eligibility checks plus `vscode.executeDocumentSymbolProvider`',
  "It returns unresolved lenses and does not call libsvn, Rust RPC, the SVN CLI, wc.db, or background history prefetch",
  'Document symbols from VS Code `DocumentSymbol` trees and current-document `SymbolInformation` results are flattened into bounded symbol ranges',
  '`resolveCodeLens` is the only stage that requests `history/blame`',
  'A resolved symbol lens binds to the existing `subversionr.showBlame` command',
  'This slice advances `HIS-007`, `PRD-009`, and `PER-011`',
  "This slice intentionally does not implement symbol history cache policy"
) "HIS-007 M5 symbol lens scope"
Assert-Terms $historyBlameRpcClientSource @(
  "export class HistoryBlameRpcClient",
  'sendRequest<unknown>("history/blame", validatedRequest)',
  "MAX_BLAME_LINE_LIMIT = 5_000"
) "HIS-007 blame RPC client contract"
Assert-Terms $historyBlameRpcClientTests @(
  "sends history/blame and parses line attribution metadata",
  "accepts an explicit one-line window with alternate blame options",
  "rejects response lines outside the requested contiguous window"
) "HIS-007 blame RPC client tests"
Assert-Terms $lensSettingsSource @(
  "symbols: boolean;",
  'configuration.get("lens.symbols", false)'
) "HIS-007 Lens settings implementation"
Assert-Terms $lensSettingsTests @(
  "reads explicit SVN Lens defaults from the SubversionR configuration namespace",
  "fails fast on malformed SVN Lens settings",
  "does not read legacy or svnNative setting aliases",
  '"svnNative.lens.symbols": true',
  '"svn.lens.symbols": true'
) "HIS-007 Lens settings tests"
Assert-Terms $symbolHistoryCodeLensProviderSource @(
  "export class SymbolHistoryCodeLensProvider",
  "public async provideCodeLenses",
  "public async resolveCodeLens",
  "executeDocumentSymbols(document.uri)",
  "flattenSymbols(document, symbols)",
  "lensSymbolFromSymbol",
  "MAX_SYMBOL_BLAME_LINES = 5000",
  "resolveAggregate",
  'pegRevision: "base"',
  'startRevision: "r0"',
  'endRevision: "base"',
  'ignoreWhitespace: "none"',
  "includeMergedRevisions: this.options.includeMergedRevisions()",
  "blame.hasMore",
  "aggregateBlameWindow",
  "line.localChange",
  "line.revision === null",
  "subversionr.showBlame",
  "SVN r{0} - Authors {1}, Revisions {2}",
  "settings.symbols",
  "settings.maxFileLines",
  "getProjectedResource("
) "HIS-007 Symbol History CodeLens implementation"
Assert-Terms $symbolHistoryCodeLensProviderTests @(
  "provides unresolved symbol lenses for projected text-stable SVN files without requesting blame",
  "resolves a visible symbol lens with BASE blame revision, author, and revision counts",
  "includes merged revisions in symbol history blame requests when history settings enable them",
  "does not provide or resolve symbol history lenses in untrusted workspaces",
  "supports SymbolInformation ranges from the current document",
  "does not provide lenses for missing symbols, invalid ranges, or oversized symbol ranges",
  "does not query symbols when disabled, outside open repositories, dirty, oversized, or unsafe",
  "does not resolve a command when blame is cancelled, incomplete, local-only, or fails",
  "executeDocumentSymbols",
  "documentSymbol(",
  "symbolInformation("
) "HIS-007 Symbol History CodeLens tests"
Assert-Terms $sourceControlResourceStoreSource @(
  "public getProjectedResource",
  "localResourcesByCaseInsensitivePath.get(caseInsensitivePath(path))"
) "HIS-007 projection-backed symbol lookup"
Assert-Terms $sourceControlProjectionServiceSource @(
  "public getProjectedResource",
  "return this.store.getProjectedResource(repositoryId, path, pathCase);"
) "HIS-007 projection service symbol lookup"
Assert-Terms $repositoryCommandControllerSource @(
  "public async showBlameResource",
  "showBlame(target"
) "HIS-007 symbol command target implementation"
Assert-Terms $repositoryCommandControllerTests @(
  "opens file blame for a selected versioned SVN file using the projection canonical path"
) "HIS-007 symbol command target tests"
Assert-Terms $extensionEntrypoint @(
  "new SymbolHistoryCodeLensProvider<vscode.CodeLens>",
  "vscode.commands.executeCommand(`"vscode.executeDocumentSymbolProvider`", uri as vscode.Uri)",
  "vscode.languages.registerCodeLensProvider",
  "symbolHistoryCodeLensProvider.refresh()",
  "symbolHistoryCodeLensRegistration"
) "HIS-007 extension activation and refresh"
Assert-Terms $extensionPackageJson @(
  '"subversionr.lens.symbols"',
  "%configuration.lens.symbols.description%"
) "HIS-007 package setting contribution"
Assert-Terms $extensionPackageNls @(
  '"configuration.lens.symbols.description"'
) "HIS-007 English package localization"
Assert-Terms $extensionPackageNlsJa @(
  '"configuration.lens.symbols.description"'
) "HIS-007 Japanese package localization"
Assert-Terms $extensionPackageNlsZhCn @(
  '"configuration.lens.symbols.description"'
) "HIS-007 Chinese package localization"
Assert-Terms $extensionBundleL10n @(
  '"SVN r{0} - Authors {1}, Revisions {2}"'
) "HIS-007 English runtime localization"
Assert-Terms $extensionBundleL10nJa @(
  '"SVN r{0} - Authors {1}, Revisions {2}"'
) "HIS-007 Japanese runtime localization"
Assert-Terms $extensionBundleL10nZhCn @(
  '"SVN r{0} - Authors {1}, Revisions {2}"'
) "HIS-007 Chinese runtime localization"
Assert-Terms $extensionManifestTests @(
  "subversionr.lens.symbols",
  "configuration.lens.symbols.description",
  "SVN r{0} - Authors {1}, Revisions {2}"
) "HIS-007 extension manifest tests"
Assert-RequirementEvidenceRefs $requirementsEvidence "HIS-006" @(
  "docs/plans/m5-content-diff-history.md",
  "packages/vscode-extension/src/lens/lensSettings.ts",
  "packages/vscode-extension/tests/lensSettings.test.ts",
  "packages/vscode-extension/src/lens/fileHeaderCodeLensProvider.ts",
  "packages/vscode-extension/tests/fileHeaderCodeLensProvider.test.ts",
  "packages/vscode-extension/src/scm/sourceControlResourceStore.ts",
  "packages/vscode-extension/tests/sourceControlResourceStore.test.ts",
  "packages/vscode-extension/src/scm/sourceControlProjectionService.ts",
  "packages/vscode-extension/tests/sourceControlProjectionService.test.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/package.nls.json",
  "packages/vscode-extension/package.nls.ja.json",
  "packages/vscode-extension/package.nls.zh-cn.json",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts"
)
Assert-Terms $m5Plan @(
  "The fifteenth M5 slice adds a projection-backed File Header CodeLens foundation for editor-visible SVN history actions",
  'The extension registers a `file`-scheme CodeLens provider after repository session state is available',
  '`provideCodeLenses` returns unresolved CodeLens entries on line 0 for projected local versioned text documents only',
  '`resolveCodeLens` binds visible lenses to localized commands',
  "The Source Control resource store maintains an exact path map plus a case-insensitive path index",
  'New settings `subversionr.lens.enabled`, `subversionr.lens.fileHeader`, and `subversionr.lens.maxFileLines` are manifest-backed',
  'This slice advances `HIS-006`, `PRD-009`, and `PER-011`',
  "The sixteenth M5 slice extends the File Header CodeLens surface with BASE and HEAD comparison actions for projected base-diffable files",
  'Base-diffable editor-visible files receive additional `Compare BASE` and `Compare HEAD` CodeLens entries',
  '`subversionr.diffWithBase` and `subversionr.diffWithHead`',
  "The eighteenth M5 slice adds a projection-backed Compare PREV command for editor-visible local SVN files",
  'File Header CodeLens now shows `Compare PREV`',
  'This slice advances `DIF-003`, `HIS-006`, and command-catalog row `svnNative.file.comparePrev`',
  "This slice intentionally does not implement CodeLens for normal unmodified versioned files"
) "HIS-006 M5 File Header Lens scope"
Assert-Terms $lensSettingsSource @(
  "fileHeader: boolean;",
  "maxFileLines: number;",
  'configuration.get("lens.fileHeader", true)',
  'configuration.get("lens.maxFileLines", 20000)',
  "SUBVERSIONR_LENS_SETTING_INVALID"
) "HIS-006 Lens settings implementation"
Assert-Terms $lensSettingsTests @(
  "reads explicit SVN Lens defaults from the SubversionR configuration namespace",
  "fails fast on malformed SVN Lens settings",
  "does not read legacy or svnNative setting aliases",
  '"svnNative.lens.enabled": false',
  '"svn.lens.enabled": false'
) "HIS-006 Lens settings tests"
Assert-Terms $fileHeaderCodeLensProviderSource @(
  "export class FileHeaderCodeLensProvider",
  "public provideCodeLenses",
  "public resolveCodeLens",
  "options.api.createRange(0, 0, 0, 0)",
  "settings.fileHeader",
  "settings.maxFileLines",
  "listOpenSessions()",
  "getProjectedResource(",
  "match.lookup.epoch !== match.session.epoch",
  "isFileHeaderResource",
  "isPreviousDiffableRevision",
  "subversionr.showFileHistory",
  "subversionr.diffWithBase",
  "subversionr.diffWithPrevious",
  "subversionr.diffWithHead",
  "subversionr.showBlame",
  "subversionr.showRepositoryLog",
  "Compare BASE",
  "Compare PREV",
  "Compare HEAD",
  "File History",
  "Blame",
  "Open Log"
) "HIS-006 File Header CodeLens implementation"
Assert-Terms $fileHeaderCodeLensProviderTests @(
  "provides unresolved file-header lenses for a projected local base-diffable text file",
  "resolves file-header lenses to summary, PREV/BASE/HEAD compare, file history, blame, and repository log commands",
  "only exposes BASE comparison from file-header lenses in untrusted workspaces",
  "uses the most specific open repository and projection for nested working copies",
  "exposes BASE and HEAD compare lenses for the libsvn property-only file shape",
  "does not expose BASE/HEAD compare lenses for %s",
  "does not expose Compare PREV when the projected file has no previous revision candidate",
  "checks the file path against open sessions before requesting a projected resource",
  "does not provide lenses when disabled, file-header lenses are off, or the file is over the threshold",
  "does not provide lenses for %s resources"
) "HIS-006 File Header CodeLens tests"
Assert-Terms $sourceControlResourceStoreSource @(
  "public getProjectedResource",
  "localResourcesByPath.get(path)",
  "localResourcesByCaseInsensitivePath.get(caseInsensitivePath(path))",
  "localResourcesByCaseInsensitivePath.set(caseInsensitivePath(entry.path), resource)",
  "localResourcesByCaseInsensitivePath.delete(caseInsensitivePath(existing.path))"
) "HIS-006 lightweight projection resource lookup"
Assert-Terms $sourceControlResourceStoreTests @(
  "returns a single projected local resource without building a full projection",
  "updates the case-insensitive projected resource index as local resources change",
  '"SRC/MAIN.C", "case-insensitive"',
  '"LIB/MAIN.C", "case-sensitive"'
) "HIS-006 lightweight projection resource lookup tests"
Assert-Terms $sourceControlProjectionServiceSource @(
  "public onDidChangeProjection",
  "public getProjectedResource",
  "return this.store.getProjectedResource(repositoryId, path, pathCase);"
) "HIS-006 projection service lookup and refresh"
Assert-Terms $sourceControlProjectionServiceTests @(
  "emits lightweight projection change events after successful updates",
  'kind: "registered"',
  'kind: "updated"',
  'kind: "unregistered"'
) "HIS-006 projection service refresh tests"
Assert-Terms $repositoryCommandControllerSource @(
  "public async diffWithPreviousResource",
  "public async showRepositoryLog",
  "public async showFileHistoryResource",
  "public async showBlameResource"
) "HIS-006 existing command targets"
Assert-Terms $repositoryCommandControllerTests @(
  "opens repository history for the selected open repository",
  "opens file history for a selected versioned SVN file using the projection canonical path",
  "opens file blame for a selected versioned SVN file using the projection canonical path",
  "opens a PREV comparison for an SCM resource using projection generation"
) "HIS-006 existing command target tests"
Assert-Terms $extensionEntrypoint @(
  "new FileHeaderCodeLensProvider<vscode.CodeLens>",
  "vscode.languages.registerCodeLensProvider",
  "fileHeaderCodeLensProvider.refresh()",
  'event.affectsConfiguration("subversionr.lens")'
) "HIS-006 extension activation and refresh"
Assert-Terms $extensionPackageJson @(
  "onCommand:subversionr.showRepositoryLog",
  "onCommand:subversionr.showFileHistory",
  "onCommand:subversionr.showBlame",
  "onCommand:subversionr.diffWithBase",
  "onCommand:subversionr.diffWithHead",
  "onCommand:subversionr.diffWithPrevious",
  '"subversionr.lens.fileHeader"',
  '"subversionr.lens.maxFileLines"',
  "%command.diffWithBase.title%",
  "%command.diffWithHead.title%",
  "%command.diffWithPrevious.title%",
  "%command.showFileHistory.title%",
  "%command.showBlame.title%",
  "%command.showRepositoryLog.title%"
) "HIS-006 package command and setting contributions"
Assert-Terms $extensionPackageNls @(
  '"configuration.lens.fileHeader.description"',
  '"configuration.lens.maxFileLines.description"',
  '"command.diffWithBase.title"',
  '"command.diffWithHead.title"',
  '"command.diffWithPrevious.title"',
  '"command.showFileHistory.title"',
  '"command.showBlame.title"',
  '"command.showRepositoryLog.title"'
) "HIS-006 English package localization"
Assert-Terms $extensionPackageNlsJa @(
  '"configuration.lens.fileHeader.description"',
  '"configuration.lens.maxFileLines.description"',
  '"command.diffWithBase.title"',
  '"command.diffWithHead.title"',
  '"command.diffWithPrevious.title"',
  '"command.showFileHistory.title"',
  '"command.showBlame.title"',
  '"command.showRepositoryLog.title"'
) "HIS-006 Japanese package localization"
Assert-Terms $extensionPackageNlsZhCn @(
  '"configuration.lens.fileHeader.description"',
  '"configuration.lens.maxFileLines.description"',
  '"command.diffWithBase.title"',
  '"command.diffWithHead.title"',
  '"command.diffWithPrevious.title"',
  '"command.showFileHistory.title"',
  '"command.showBlame.title"',
  '"command.showRepositoryLog.title"'
) "HIS-006 Chinese package localization"
Assert-Terms $extensionBundleL10n @(
  '"Compare BASE"',
  '"Compare HEAD"',
  '"Compare PREV"',
  '"File History"',
  '"Blame"',
  '"Open Log"'
) "HIS-006 English runtime localization"
Assert-Terms $extensionBundleL10nJa @(
  '"Compare BASE"',
  '"Compare HEAD"',
  '"Compare PREV"',
  '"File History"',
  '"Blame"',
  '"Open Log"'
) "HIS-006 Japanese runtime localization"
Assert-Terms $extensionBundleL10nZhCn @(
  '"Compare BASE"',
  '"Compare HEAD"',
  '"Compare PREV"',
  '"File History"',
  '"Blame"',
  '"Open Log"'
) "HIS-006 Chinese runtime localization"
Assert-Terms $extensionManifestTests @(
  "onCommand:subversionr.showRepositoryLog",
  "onCommand:subversionr.showFileHistory",
  "onCommand:subversionr.showBlame",
  "onCommand:subversionr.diffWithBase",
  "onCommand:subversionr.diffWithHead",
  "onCommand:subversionr.diffWithPrevious",
  "subversionr.lens.fileHeader",
  "subversionr.lens.maxFileLines",
  "configuration.lens.fileHeader.description",
  "configuration.lens.maxFileLines.description",
  "Compare BASE",
  "Compare HEAD",
  "Compare PREV",
  "File History",
  "Blame",
  "Open Log"
) "HIS-006 extension manifest tests"
Assert-RequirementEvidenceRefs $requirementsEvidence "DIF-003" @(
  "docs/plans/m5-content-diff-history.md",
  "crates/subversionr-protocol/src/lib.rs",
  "crates/subversionr-protocol/tests/protocol_contract.rs",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/src/native.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "native/svn-bridge/include/subversionr_bridge.h",
  "native/svn-bridge/src/subversionr_bridge.c",
  "packages/vscode-extension/src/content/contentGetRpcClient.ts",
  "packages/vscode-extension/tests/contentGetRpcClient.test.ts",
  "packages/vscode-extension/src/content/revisionContentUri.ts",
  "packages/vscode-extension/tests/revisionContentUri.test.ts",
  "packages/vscode-extension/src/content/revisionContentDocumentProvider.ts",
  "packages/vscode-extension/tests/revisionContentDocumentProvider.test.ts",
  "packages/vscode-extension/src/history/historyLogRpcClient.ts",
  "packages/vscode-extension/tests/historyLogRpcClient.test.ts",
  "packages/vscode-extension/src/history/historyTreeDataProvider.ts",
  "packages/vscode-extension/tests/historyTreeDataProvider.test.ts",
  "packages/vscode-extension/src/history/historyCompareRevisionCommand.ts",
  "packages/vscode-extension/tests/historyCompareRevisionCommand.test.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "packages/vscode-extension/src/editor/activeEditorContextService.ts",
  "packages/vscode-extension/tests/activeEditorContextService.test.ts",
  "packages/vscode-extension/src/lens/fileHeaderCodeLensProvider.ts",
  "packages/vscode-extension/tests/fileHeaderCodeLensProvider.test.ts",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/package.nls.json",
  "packages/vscode-extension/package.nls.ja.json",
  "packages/vscode-extension/package.nls.zh-cn.json",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1",
  "scripts/release/capture-vscode-renderer-ui.mjs"
)
Assert-Terms $m5Plan @(
  "The ninth M5 slice adds a foreground file-history action that compares a selected file revision against the previous already loaded file-history revision",
  '`subversionr.history.compareWithPrevious` is contributed only for `subversionr.history.fileRevision.previousDiffable` TreeView items',
  'both revisions are strict explicit `r<N>` values and `leftRevision < rightRevision`',
  'This slice advances `DIF-003` and `HIS-010`',
  "The eighteenth M5 slice adds a projection-backed Compare PREV command for editor-visible local SVN files",
  '`subversionr.diffWithPrevious` is contributed as a hidden canonical command',
  "Compare PREV performs no background prefetch",
  "startRevision = r<changedRevision>",
  'This slice advances `DIF-003`, `HIS-006`, and command-catalog row `svnNative.file.comparePrev`',
  "This slice intentionally does not implement full peg-aware PREV across rename/copy boundaries"
) "DIF-003 M5 PREV scope"
Assert-Terms $protocolSource @(
  "pub struct ContentGetResponse",
  "pub revision: String",
  "pub content_base64: String",
  "content_get_revision: true"
) "DIF-003 protocol explicit revision content contract"
Assert-Terms $rpcDispatchTests @(
  "content_get_returns_explicit_revision_content_for_open_repository",
  '"revision":"r7"',
  "libsvn-revision"
) "DIF-003 daemon explicit revision content RPC coverage"
Assert-Terms $nativeBridgeTests @(
  "native_bridge_content_get_returns_head_and_explicit_revision_text",
  'content_get(&identity, "tracked.txt", "r2"',
  'content_get(&identity, "tracked.txt", "r3"',
  "libsvn-revision"
) "DIF-003 native explicit revision content fixtures"
Assert-Terms $contentGetRpcClientSource @(
  'return "libsvn-revision";',
  "sendRequest<unknown>(`"content/get`", validatedRequest)",
  "requireContentMatchesRequest"
) "DIF-003 TypeScript explicit revision content client"
Assert-Terms $contentGetRpcClientTests @(
  "sends explicit revision content/get and accepts the matching response identity",
  'source: "libsvn-revision"',
  "rejects response sources that do not match the requested revision"
) "DIF-003 TypeScript explicit revision content client tests"
Assert-Terms $revisionContentUriSource @(
  "REVISION_CONTENT_URI_SCHEME = `"svn-r-revision`"",
  "createRevisionContentUriComponents",
  "parseRevisionContentUri",
  "isExplicitRevision"
) "DIF-003 strict revision URI contract"
Assert-Terms $revisionContentUriTests @(
  "encodes explicit revision content identity into a custom URI without exposing local filesystem paths",
  "parses an explicit revision content URI into a content/get request",
  "rejects malformed revision content URIs"
) "DIF-003 strict revision URI tests"
Assert-Terms $revisionContentDocumentProviderSource @(
  "parseRevisionContentUri(uri)",
  "contentClient.getContent",
  "Binary SVN revision content is not displayed in the text editor: {0}@{1}"
) "DIF-003 revision content document provider"
Assert-Terms $revisionContentDocumentProviderTests @(
  "loads explicit revision content through content/get and returns readonly text",
  "returns localized placeholder text for binary explicit revision content",
  "rejects explicit revision content in untrusted workspaces before content/get"
) "DIF-003 revision content document provider tests"
Assert-Terms $historyLogRpcClientSource @(
  "sendRequest<unknown>(`"history/log`", validatedRequest)",
  "isHistoryStartRevision",
  "isHistoryNumberedRevision",
  "requireHistoryLogMatchesRequest"
) "DIF-003 history/log client contract"
Assert-Terms $historyLogRpcClientTests @(
  "sends history/log and parses changed-path metadata",
  'safeArgs: { field: "startRevision" }',
  'safeArgs: { field: "endRevision" }',
  "rejects invalid history limit %j before sending"
) "DIF-003 history/log client tests"
Assert-Terms $historyTreeDataProviderSource @(
  "compareRevisionTarget(element: unknown)",
  "previousRevision",
  "subversionr.history.fileRevision.previousDiffable",
  "canCompareWithPrevious",
  "element.previousRevision < element.entry.revision"
) "DIF-003 history TreeView PREV targets"
Assert-Terms $historyTreeDataProviderTests @(
  "exposes compare-with-previous targets only when a file revision has an older loaded history entry",
  "subversionr.history.fileRevision.previousDiffable",
  "leftRevision: `"r5`"",
  "rightRevision: `"r8`""
) "DIF-003 history TreeView PREV tests"
Assert-Terms $historyCompareRevisionCommandSource @(
  "historyCompareRevisionUriComponents",
  "createRevisionContentUriComponents",
  "leftRevisionNumber >= rightRevisionNumber",
  "SUBVERSIONR_HISTORY_COMPARE_PREVIOUS_TARGET_INVALID"
) "DIF-003 history compare command helper"
Assert-Terms $historyCompareRevisionCommandTests @(
  "creates revision content URI components for a file-history previous comparison target",
  "rejects spoofed %s",
  "base left revision",
  "newer left revision"
) "DIF-003 history compare command helper tests"
Assert-Terms $repositoryCommandControllerSource @(
  "public async diffWithPreviousResource",
  "LOCAL_HISTORY_FILE_CONTEXT_VALUES",
  'startRevision: `r${changedRevision}`',
  'endRevision: "r0"',
  "limit: 2",
  "discoverChangedPaths: false",
  "strictNodeHistory: false",
  "includeMergedRevisions: false",
  "historyCompareRevisionUriComponents",
  "SVN PREV <-> Revision: {0}"
) "DIF-003 repository Compare PREV command implementation"
Assert-Terms $repositoryCommandControllerTests @(
  "opens a PREV comparison for an SCM resource using projection generation",
  "rejects stale PREV comparison projection generations before history requests",
  "fails fast when no previous revision is available for PREV comparison",
  "rejects PREV comparison targets with invalid changed revisions before history requests"
) "DIF-003 repository Compare PREV command tests"
Assert-Terms $activeEditorContextServiceSource @(
  "ACTIVE_EDITOR_PREVIOUS_DIFFABLE_CONTEXT",
  "subversionr.activeEditorPreviousDiffable",
  "isPreviousDiffableRevision"
) "DIF-003 active editor PREV context"
Assert-Terms $activeEditorContextServiceTests @(
  "sets history, base-diffable, and previous-diffable context keys for a projected active file",
  "clears only previous-diffable context when a projected file has no previous revision candidate"
) "DIF-003 active editor PREV context tests"
Assert-Terms $fileHeaderCodeLensProviderSource @(
  "previousDiffable",
  "subversionr.diffWithPrevious",
  "Compare PREV"
) "DIF-003 File Header CodeLens PREV action"
Assert-Terms $fileHeaderCodeLensProviderTests @(
  "resolves file-header lenses to summary, PREV/BASE/HEAD compare, file history, blame, and repository log commands",
  "does not expose Compare PREV when the projected file has no previous revision candidate"
) "DIF-003 File Header CodeLens PREV tests"
Assert-Terms $extensionEntrypoint @(
  "subversionr.history.compareWithPrevious",
  "subversionr.diffWithPrevious",
  "svn.openChangePrev",
  "historyCompareRevisionUriComponents"
) "DIF-003 extension activation, command registration, and legacy alias"
Assert-Terms $extensionPackageJson @(
  "onCommand:subversionr.history.compareWithPrevious",
  "onCommand:subversionr.diffWithPrevious",
  "onCommand:svn.openChangePrev",
  "viewItem == subversionr.history.fileRevision.previousDiffable",
  "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorPreviousDiffable"
) "DIF-003 command contribution and surface placement"
Assert-Terms $extensionPackageNls @(
  '"command.diffWithPrevious.title"',
  '"command.history.compareWithPrevious.title"',
  "SubversionR: Compare with PREV",
  "SubversionR: Compare with Previous"
) "DIF-003 English package localization"
Assert-Terms $extensionPackageNlsJa @(
  '"command.diffWithPrevious.title"',
  '"command.history.compareWithPrevious.title"'
) "DIF-003 Japanese package localization"
Assert-Terms $extensionPackageNlsZhCn @(
  '"command.diffWithPrevious.title"',
  '"command.history.compareWithPrevious.title"'
) "DIF-003 Chinese package localization"
Assert-Terms $extensionBundleL10n @(
  '"SVN PREV <-> Revision: {0}"',
  '"Compare PREV"',
  "Binary SVN revision content is not displayed in the text editor: {0}@{1}"
) "DIF-003 English runtime localization"
Assert-Terms $extensionBundleL10nJa @(
  '"SVN PREV <-> Revision: {0}"',
  '"Compare PREV"'
) "DIF-003 Japanese runtime localization"
Assert-Terms $extensionBundleL10nZhCn @(
  '"SVN PREV <-> Revision: {0}"',
  '"Compare PREV"'
) "DIF-003 Chinese runtime localization"
Assert-Terms $extensionManifestTests @(
  "onCommand:subversionr.history.compareWithPrevious",
  "onCommand:subversionr.diffWithPrevious",
  "onCommand:svn.openChangePrev",
  "command.diffWithPrevious.title",
  "command.history.compareWithPrevious.title",
  "viewItem == subversionr.history.fileRevision.previousDiffable",
  "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorPreviousDiffable",
  "SVN PREV <-> Revision: {0}",
  "Compare PREV"
) "DIF-003 extension manifest tests"
Assert-RequirementEvidenceRefs $requirementsEvidence "DIF-004" @(
  "docs/plans/m5-content-diff-history.md",
  "crates/subversionr-protocol/src/lib.rs",
  "crates/subversionr-protocol/tests/protocol_contract.rs",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/src/native.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "native/svn-bridge/include/subversionr_bridge.h",
  "native/svn-bridge/src/subversionr_bridge.c",
  "packages/vscode-extension/src/content/contentGetRpcClient.ts",
  "packages/vscode-extension/tests/contentGetRpcClient.test.ts",
  "packages/vscode-extension/src/content/revisionContentUri.ts",
  "packages/vscode-extension/tests/revisionContentUri.test.ts",
  "packages/vscode-extension/src/content/revisionContentDocumentProvider.ts",
  "packages/vscode-extension/tests/revisionContentDocumentProvider.test.ts",
  "packages/vscode-extension/src/history/historyTreeDataProvider.ts",
  "packages/vscode-extension/tests/historyTreeDataProvider.test.ts",
  "packages/vscode-extension/src/history/historyCompareRevisionCommand.ts",
  "packages/vscode-extension/tests/historyCompareRevisionCommand.test.ts",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/package.nls.json",
  "packages/vscode-extension/package.nls.ja.json",
  "packages/vscode-extension/package.nls.zh-cn.json",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts"
)
Assert-Terms $m5Plan @(
  "The nineteenth M5 slice adds loaded-row Compare Revisions for file history",
  '`subversionr.history.compareRevisions` is contributed for multi-selected file revision rows in the native `SVN History` TreeView',
  "Command execution validates exactly two current provider-owned file revision nodes from the same loaded file-history target",
  'opens a VS Code diff between strict immutable `svn-r-revision` URIs',
  'This slice advances `HIS-010`, `DIF-004`, and command-catalog row `svnNative.history.compare`',
  "without claiming full arbitrary revision/URL diff semantics",
  "This slice intentionally does not implement repository revision comparison, changed-path open/compare by repository URL"
) "DIF-004 M5 bounded Compare Revisions scope"
Assert-Terms $protocolSource @(
  "pub struct ContentGetResponse",
  "pub revision: String",
  "pub content_base64: String",
  "content_get_revision: true"
) "DIF-004 protocol explicit revision content contract"
Assert-Terms $rpcDispatchTests @(
  "content_get_returns_explicit_revision_content_for_open_repository",
  '"revision":"r7"',
  "libsvn-revision"
) "DIF-004 daemon explicit revision content RPC coverage"
Assert-Terms $nativeBridgeTests @(
  "native_bridge_content_get_returns_head_and_explicit_revision_text",
  'content_get(&identity, "tracked.txt", "r2"',
  'content_get(&identity, "tracked.txt", "r3"',
  "libsvn-revision"
) "DIF-004 native explicit revision content fixtures"
Assert-Terms $contentGetRpcClientSource @(
  'return "libsvn-revision";',
  "sendRequest<unknown>(`"content/get`", validatedRequest)",
  "requireContentMatchesRequest"
) "DIF-004 TypeScript explicit revision content client"
Assert-Terms $contentGetRpcClientTests @(
  "sends explicit revision content/get and accepts the matching response identity",
  'source: "libsvn-revision"',
  "rejects response sources that do not match the requested revision"
) "DIF-004 TypeScript explicit revision content client tests"
Assert-Terms $revisionContentUriSource @(
  "REVISION_CONTENT_URI_SCHEME = `"svn-r-revision`"",
  "createRevisionContentUriComponents",
  "parseRevisionContentUri",
  "isExplicitRevision"
) "DIF-004 strict revision URI contract"
Assert-Terms $revisionContentUriTests @(
  "encodes explicit revision content identity into a custom URI without exposing local filesystem paths",
  "parses an explicit revision content URI into a content/get request",
  "rejects malformed revision content URIs"
) "DIF-004 strict revision URI tests"
Assert-Terms $revisionContentDocumentProviderSource @(
  "parseRevisionContentUri(uri)",
  "contentClient.getContent",
  "Binary SVN revision content is not displayed in the text editor: {0}@{1}"
) "DIF-004 revision content document provider"
Assert-Terms $revisionContentDocumentProviderTests @(
  "loads explicit revision content through content/get and returns readonly text",
  "returns localized placeholder text for binary explicit revision content",
  "rejects explicit revision content in untrusted workspaces before content/get"
) "DIF-004 revision content document provider tests"
Assert-Terms $historyTreeDataProviderSource @(
  "compareRevisionsTarget(element: unknown, selectedElements: unknown)",
  "selectedElements.length !== 2",
  "!selectedElements.includes(element)",
  "first.state !== focused.state",
  "first.node.target !== second.node.target",
  "leftRevisionNumber = Math.min(firstRevision, secondRevision)",
  'label: `${focused.node.target.path} ${leftRevision}..${rightRevision}`',
  "SUBVERSIONR_HISTORY_COMPARE_REVISIONS_TARGET_INVALID"
) "DIF-004 history TreeView Compare Revisions targets"
Assert-Terms $historyTreeDataProviderTests @(
  "creates compare targets from exactly two current loaded file revision rows",
  "src/main.c r3..r8",
  "clonedRevision",
  "SUBVERSIONR_HISTORY_COMPARE_REVISIONS_TARGET_INVALID",
  "rejects structurally cloned history revision command nodes"
) "DIF-004 history TreeView Compare Revisions tests"
Assert-Terms $historyCompareRevisionCommandSource @(
  "historyCompareRevisionUriComponents",
  "createRevisionContentUriComponents",
  "leftRevisionNumber >= rightRevisionNumber",
  "SUBVERSIONR_HISTORY_COMPARE_PREVIOUS_TARGET_INVALID"
) "DIF-004 immutable revision diff URI helper"
Assert-Terms $historyCompareRevisionCommandTests @(
  "creates revision content URI components for a file-history previous comparison target",
  "rejects spoofed %s",
  "base left revision",
  "newer left revision"
) "DIF-004 immutable revision diff URI helper tests"
Assert-Terms $extensionEntrypoint @(
  "HISTORY_COMPARE_REVISIONS_LEGACY_ALIASES",
  "subversionr.history.compareRevisions",
  "svn.itemlog.openDiff",
  "svn.repolog.openDiff",
  "compareHistoryRevisions",
  "historyTreeDataProvider.compareRevisionsTarget(element, selectedElements)",
  "vscode.diff",
  "SVN Revision Compare: {0}"
) "DIF-004 extension activation, command registration, legacy aliases, and diff execution"
Assert-Terms $extensionPackageJson @(
  "onCommand:subversionr.history.compareRevisions",
  "onCommand:svn.itemlog.openDiff",
  "onCommand:svn.repolog.openDiff",
  "subversionr.history.compareRevisions",
  "%command.history.compareRevisions.title%",
  "viewItem == subversionr.history.fileRevision || viewItem == subversionr.history.fileRevision.previousDiffable) && listMultiSelection",
  "listMultiSelection",
  '"when": "false"'
) "DIF-004 command contribution and multi-select placement"
Assert-Terms $extensionPackageNls @(
  '"command.history.compareRevisions.title"',
  "SubversionR: Compare Revisions"
) "DIF-004 English package localization"
Assert-Terms $extensionPackageNlsJa @(
  '"command.history.compareRevisions.title"'
) "DIF-004 Japanese package localization"
Assert-Terms $extensionPackageNlsZhCn @(
  '"command.history.compareRevisions.title"'
) "DIF-004 Chinese package localization"
Assert-Terms $extensionBundleL10n @(
  '"SVN Revision Compare: {0}"',
  "SVN Revision Compare: {0}",
  "Binary SVN revision content is not displayed in the text editor: {0}@{1}"
) "DIF-004 English runtime localization"
Assert-Terms $extensionBundleL10nJa @(
  '"SVN Revision Compare: {0}"'
) "DIF-004 Japanese runtime localization"
Assert-Terms $extensionBundleL10nZhCn @(
  '"SVN Revision Compare: {0}"'
) "DIF-004 Chinese runtime localization"
Assert-Terms $extensionManifestTests @(
  "onCommand:subversionr.history.compareRevisions",
  "onCommand:svn.itemlog.openDiff",
  "onCommand:svn.repolog.openDiff",
  "command.history.compareRevisions.title",
  "subversionr.history.compareRevisions",
  "viewItem == subversionr.history.fileRevision || viewItem == subversionr.history.fileRevision.previousDiffable) && listMultiSelection",
  "SVN Revision Compare: {0}",
  "Binary SVN revision content is not displayed in the text editor: {0}@{1}"
) "DIF-004 extension manifest tests"
Assert-RequirementEvidenceRefs $requirementsEvidence "HIS-010" @(
  "docs/plans/m5-content-diff-history.md",
  "crates/subversionr-protocol/src/lib.rs",
  "crates/subversionr-protocol/tests/protocol_contract.rs",
  "crates/subversionr-daemon/src/state.rs",
  "crates/subversionr-daemon/src/native.rs",
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "native/svn-bridge/include/subversionr_bridge.h",
  "native/svn-bridge/src/subversionr_bridge.c",
  "packages/vscode-extension/src/content/contentGetRpcClient.ts",
  "packages/vscode-extension/tests/contentGetRpcClient.test.ts",
  "packages/vscode-extension/src/content/revisionContentUri.ts",
  "packages/vscode-extension/tests/revisionContentUri.test.ts",
  "packages/vscode-extension/src/content/revisionContentDocumentProvider.ts",
  "packages/vscode-extension/tests/revisionContentDocumentProvider.test.ts",
  "packages/vscode-extension/src/history/historyLogRpcClient.ts",
  "packages/vscode-extension/tests/historyLogRpcClient.test.ts",
  "packages/vscode-extension/src/history/historyTreeDataProvider.ts",
  "packages/vscode-extension/tests/historyTreeDataProvider.test.ts",
  "packages/vscode-extension/src/history/historyCompareRevisionCommand.ts",
  "packages/vscode-extension/tests/historyCompareRevisionCommand.test.ts",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/package.nls.json",
  "packages/vscode-extension/package.nls.ja.json",
  "packages/vscode-extension/package.nls.zh-cn.json",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts"
)
Assert-Terms $m5Plan @(
  "The nineteenth M5 slice adds loaded-row Compare Revisions for file history",
  '`subversionr.history.compareRevisions` is contributed for multi-selected file revision rows in the native `SVN History` TreeView',
  'The `SVN History` TreeView enables multi-selection',
  "Command execution validates exactly two current provider-owned file revision nodes from the same loaded file-history target",
  'opens a VS Code diff between strict immutable `svn-r-revision` URIs',
  'This slice advances `HIS-010`, `DIF-004`, and command-catalog row `svnNative.history.compare`',
  "without claiming full arbitrary revision/URL diff semantics",
  "This slice intentionally does not implement repository revision comparison, changed-path open/compare by repository URL"
) "HIS-010 M5 bounded Compare Revisions scope"
Assert-Terms $historyLogRpcClientSource @(
  "sendRequest<unknown>(`"history/log`", validatedRequest)",
  "isHistoryStartRevision",
  "isHistoryNumberedRevision",
  "requireHistoryLogMatchesRequest"
) "HIS-010 history/log client contract"
Assert-Terms $historyLogRpcClientTests @(
  "sends history/log and parses changed-path metadata",
  "accepts root history requests with an empty response",
  "rejects invalid history limit %j before sending",
  "rejects history responses from an unexpected source"
) "HIS-010 history/log client tests"
Assert-Terms $contentGetRpcClientSource @(
  'return "libsvn-revision";',
  "sendRequest<unknown>(`"content/get`", validatedRequest)",
  "requireContentMatchesRequest"
) "HIS-010 TypeScript explicit revision content client"
Assert-Terms $contentGetRpcClientTests @(
  "sends explicit revision content/get and accepts the matching response identity",
  'source: "libsvn-revision"',
  "rejects response sources that do not match the requested revision"
) "HIS-010 TypeScript explicit revision content client tests"
Assert-Terms $revisionContentUriSource @(
  "REVISION_CONTENT_URI_SCHEME = `"svn-r-revision`"",
  "createRevisionContentUriComponents",
  "parseRevisionContentUri",
  "isExplicitRevision"
) "HIS-010 strict revision URI contract"
Assert-Terms $revisionContentUriTests @(
  "encodes explicit revision content identity into a custom URI without exposing local filesystem paths",
  "parses an explicit revision content URI into a content/get request",
  "rejects malformed revision content URIs"
) "HIS-010 strict revision URI tests"
Assert-Terms $revisionContentDocumentProviderSource @(
  "parseRevisionContentUri(uri)",
  "contentClient.getContent",
  "Binary SVN revision content is not displayed in the text editor: {0}@{1}"
) "HIS-010 revision content document provider"
Assert-Terms $revisionContentDocumentProviderTests @(
  "loads explicit revision content through content/get and returns readonly text",
  "returns localized placeholder text for binary explicit revision content",
  "rejects explicit revision content in untrusted workspaces before content/get"
) "HIS-010 revision content document provider tests"
Assert-Terms $historyTreeDataProviderSource @(
  "compareRevisionsTarget(element: unknown, selectedElements: unknown)",
  "selectedElements.length !== 2",
  "!selectedElements.includes(element)",
  "first.state !== focused.state",
  "first.node.target !== second.node.target",
  "leftRevisionNumber = Math.min(firstRevision, secondRevision)",
  'label: `${focused.node.target.path} ${leftRevision}..${rightRevision}`',
  "SUBVERSIONR_HISTORY_COMPARE_REVISIONS_TARGET_INVALID"
) "HIS-010 history TreeView Compare Revisions targets"
Assert-Terms $historyTreeDataProviderTests @(
  "creates compare targets from exactly two current loaded file revision rows",
  "src/main.c r3..r8",
  "clonedRevision",
  "SUBVERSIONR_HISTORY_COMPARE_REVISIONS_TARGET_INVALID",
  "rejects structurally cloned history revision command nodes"
) "HIS-010 history TreeView Compare Revisions tests"
Assert-Terms $historyCompareRevisionCommandSource @(
  "historyCompareRevisionUriComponents",
  "createRevisionContentUriComponents",
  "leftRevisionNumber >= rightRevisionNumber",
  "SUBVERSIONR_HISTORY_COMPARE_PREVIOUS_TARGET_INVALID"
) "HIS-010 immutable revision diff URI helper"
Assert-Terms $historyCompareRevisionCommandTests @(
  "creates revision content URI components for a file-history previous comparison target",
  "rejects spoofed %s",
  "base left revision",
  "newer left revision"
) "HIS-010 immutable revision diff URI helper tests"
Assert-Terms $extensionEntrypoint @(
  "HISTORY_COMPARE_REVISIONS_LEGACY_ALIASES",
  "subversionr.history.compareRevisions",
  "svn.itemlog.openDiff",
  "svn.repolog.openDiff",
  "compareHistoryRevisions",
  "historyTreeDataProvider.compareRevisionsTarget(element, selectedElements)",
  "vscode.diff",
  "SVN Revision Compare: {0}"
) "HIS-010 extension activation, command registration, legacy aliases, and diff execution"
Assert-Terms $extensionPackageJson @(
  "onCommand:subversionr.history.compareRevisions",
  "onCommand:svn.itemlog.openDiff",
  "onCommand:svn.repolog.openDiff",
  "subversionr.history.compareRevisions",
  "%command.history.compareRevisions.title%",
  "viewItem == subversionr.history.fileRevision || viewItem == subversionr.history.fileRevision.previousDiffable) && listMultiSelection",
  "listMultiSelection",
  '"when": "false"'
) "HIS-010 command contribution and multi-select placement"
Assert-Terms $extensionPackageNls @(
  '"command.history.compareRevisions.title"',
  "SubversionR: Compare Revisions"
) "HIS-010 English package localization"
Assert-Terms $extensionPackageNlsJa @(
  '"command.history.compareRevisions.title"'
) "HIS-010 Japanese package localization"
Assert-Terms $extensionPackageNlsZhCn @(
  '"command.history.compareRevisions.title"'
) "HIS-010 Chinese package localization"
Assert-Terms $extensionBundleL10n @(
  '"SVN Revision Compare: {0}"',
  "SVN Revision Compare: {0}",
  "Binary SVN revision content is not displayed in the text editor: {0}@{1}"
) "HIS-010 English runtime localization"
Assert-Terms $extensionBundleL10nJa @(
  '"SVN Revision Compare: {0}"'
) "HIS-010 Japanese runtime localization"
Assert-Terms $extensionBundleL10nZhCn @(
  '"SVN Revision Compare: {0}"'
) "HIS-010 Chinese runtime localization"
Assert-Terms $extensionManifestTests @(
  "onCommand:subversionr.history.compareRevisions",
  "onCommand:svn.itemlog.openDiff",
  "onCommand:svn.repolog.openDiff",
  "command.history.compareRevisions.title",
  "subversionr.history.compareRevisions",
  "viewItem == subversionr.history.fileRevision || viewItem == subversionr.history.fileRevision.previousDiffable) && listMultiSelection",
  "SVN Revision Compare: {0}",
  "Binary SVN revision content is not displayed in the text editor: {0}@{1}"
) "HIS-010 extension manifest tests"
Assert-RequirementEvidenceRefs $requirementsEvidence "STA-010" @(
  "crates/subversionr-protocol/src/lib.rs",
  "crates/subversionr-protocol/tests/protocol_contract.rs",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "crates/subversionr-daemon/src/native.rs",
  "native/svn-bridge/include/subversionr_bridge.h",
  "native/svn-bridge/src/subversionr_bridge.c",
  "packages/vscode-extension/src/status/statusSnapshotRpcClient.ts",
  "packages/vscode-extension/tests/statusSnapshotRpcClient.test.ts",
  "packages/vscode-extension/src/status/statusSnapshotStore.ts",
  "packages/vscode-extension/tests/statusSnapshotStore.test.ts",
  "packages/vscode-extension/src/scm/resourceStateClassifier.ts",
  "packages/vscode-extension/tests/scmResourceStateClassifier.test.ts",
  "packages/vscode-extension/src/scm/sourceControlResourceStore.ts",
  "packages/vscode-extension/tests/sourceControlResourceStore.test.ts",
  "packages/vscode-extension/src/scm/sourceControlProjectionService.ts",
  "packages/vscode-extension/tests/sourceControlProjectionService.test.ts",
  "packages/vscode-extension/src/scm/vscodeSourceControlPresenter.ts",
  "packages/vscode-extension/tests/vscodeSourceControlPresenter.test.ts",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/tests/extensionManifest.test.ts"
)
Assert-Terms $protocolSource @(
  "pub switched: bool",
  "pub depth: String"
) "STA-010 protocol switched/sparse fields"
Assert-Terms $nativeBridgeHeader @(
  "const char *depth;",
  "int switched;"
) "STA-010 native bridge status ABI fields"
Assert-Terms $nativeBridgeSource @(
  "entry->depth = svn_depth_to_word(status->depth);",
  "entry->switched = status->switched ? 1 : 0;"
) "STA-010 libsvn switched/sparse status mapping"
Assert-Terms $nativeBridgeRustSource @(
  'c_string_to_owned(raw_entry.depth, "status.depth")',
  "switched: raw_entry.switched != 0",
  "depth,"
) "STA-010 Rust native switched/sparse status mapping"
Assert-Terms $nativeBridgeTests @(
  "native_bridge_status_snapshot_preserves_sparse_depth_and_excluded_semantics",
  "native_bridge_status_snapshot_reports_switched_directory_and_branch_history",
  'assert_eq!(sparse_dir.depth, "files")',
  'assert!(switched_dir.switched)'
) "STA-010 native switched/sparse working-copy fixtures"
Assert-Terms $statusSnapshotRpcClientSource @(
  "switched: boolean;",
  "depth: string;",
  '"switched"',
  '"depth"',
  "requireBoolean(entry.switched",
  "requireString(entry.depth"
) "STA-010 TypeScript status parser metadata fields"
Assert-Terms $statusSnapshotRpcClientTests @(
  "preserves switched and sparse depth metadata from status entries",
  "switched: true",
  "depth: `"files`"",
  "depth: `"future-depth`"",
  "switched: false",
  "depth: `"infinity`""
) "STA-010 TypeScript status parser tests"
Assert-Terms $statusSnapshotStoreSource @(
  "localEntries",
  "entry"
) "STA-010 status snapshot store preserves full status entries"
Assert-Terms $resourceStateClassifierSource @(
  "hasWorkingCopyMetadataStatus",
  "entry.switched",
  "entry.lock !== null",
  "entry.needsLock",
  "isSparseStatusDepth(entry.depth)",
  'return classification("metadata", "workingCopyMetadata");',
  'depth === "empty" || depth === "files" || depth === "immediates"'
) "STA-010 SCM metadata classifier"
Assert-Terms $resourceStateClassifierTests @(
  "switched metadata-only node",
  "sparse metadata-only node",
  "subversionr.workingCopyMetadata",
  "scm.resource.workingCopyMetadata"
) "STA-010 SCM metadata classifier tests"
Assert-Terms $sourceControlResourceStoreSource @(
  "entry: cloneStatusEntry(entry)",
  "function cloneStatusEntry(entry: StatusEntry): StatusEntry",
  "lock: entry.lock ? { ...entry.lock } : null",
  "isCountedLocalChangeResource",
  'resource.contextValue !== "subversionr.workingCopyMetadata"'
) "STA-010 SCM projection store metadata preservation"
Assert-Terms $sourceControlResourceStoreTests @(
  "projects clean working-copy metadata into its own non-committable group",
  "keeps changed switched sparse and needs-lock files committable instead of downgrading them",
  "subversionr.workingCopyMetadata",
  "expect(projection.count).toBe(0)"
) "STA-010 SCM projection store tests"
Assert-Terms $sourceControlProjectionServiceSource @(
  "this.presenter.updateRepository(projection)",
  "applySnapshot(snapshot: StatusSnapshot)"
) "STA-010 SCM projection service forwards projected metadata"
Assert-Terms $sourceControlProjectionServiceTests @(
  "registers a repository and publishes projection updates for snapshots and deltas",
  "expect(presenter.updateRepository).toHaveBeenCalledTimes(2)"
) "STA-010 SCM projection service tests"
Assert-Terms $vscodeSourceControlPresenterSource @(
  '"scm.resource.workingCopyMetadata": "SVN working copy metadata"',
  "resourceTooltip(api, resource)",
  'api.localize("SVN switched node")',
  'api.localize("SVN sparse depth")',
  "isSparseStatusDepth(resource.entry.depth)"
) "STA-010 Source Control switched/sparse tooltip"
Assert-Terms $vscodeSourceControlPresenterTests @(
  "adds switched and sparse depth metadata to SourceControl resource tooltips",
  "l10n:SVN working copy metadata",
  "l10n:SVN switched node",
  "l10n:SVN sparse depth: files"
) "STA-010 Source Control tooltip tests"
Assert-Terms $extensionBundleL10n @(
  '"SVN working copy metadata"',
  '"SVN switched node"',
  '"SVN sparse depth"'
) "STA-010 English runtime localization"
Assert-Terms $extensionBundleL10nJa @(
  '"SVN working copy metadata"',
  '"SVN switched node"',
  '"SVN sparse depth"'
) "STA-010 Japanese runtime localization"
Assert-Terms $extensionBundleL10nZhCn @(
  '"SVN working copy metadata"',
  '"SVN switched node"',
  '"SVN sparse depth"'
) "STA-010 Chinese runtime localization"
Assert-Terms $extensionManifestTests @(
  "SVN working copy metadata",
  "SVN switched node",
  "SVN sparse depth"
) "STA-010 extension localization tests"
Assert-RequirementEvidenceRefs $requirementsEvidence "STA-011" @(
  "packages/vscode-extension/tests/statusSettings.test.ts",
  "packages/vscode-extension/tests/sourceControlResourceStore.test.ts",
  "packages/vscode-extension/tests/vscodeSourceControlPresenter.test.ts"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "STA-013" @(
  "docs/plans/m3-dirty-path-status-engine.md",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/src/status/repositoryRefreshService.ts",
  "packages/vscode-extension/src/diagnostics/installedSourceControlUiE2eStatusRefreshProbe.ts",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "packages/vscode-extension/tests/repositoryRefreshService.test.ts",
  "packages/vscode-extension/tests/installedSourceControlUiE2eStatusRefreshProbe.test.ts",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/release/capture-vscode-renderer-ui.mjs"
)
Assert-Terms $installedSourceControlUiE2eScript @(
  "sourceControlUiRefreshLoadWorkflow",
  "subversionr.installedSourceControlUiE2eRefreshLoadWorkflow",
  "requestedModifiedItemCount",
  "projectedModifiedItemCountBefore",
  "projectedModifiedItemCountAfter",
  "allLoadResourcesProjectedBefore",
  "allLoadResourcesProjectedAfter"
) "STA-013 installed manual Refresh load evidence fields"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "sourceControlUiRefreshLoadWorkflow",
  "requestedModifiedItemCount",
  "projectedModifiedItemCountBefore",
  "projectedModifiedItemCountAfter",
  "allLoadResourcesProjectedAfter"
) "STA-013 installed manual Refresh load script-test evidence"
Assert-Terms $installedSourceControlUiE2eScript @(
  "sourceControlUiFullReconcileCancellationWorkflow",
  "fullReconcileCancellationProgressCapture",
  "subversionr.installedSourceControlUiE2eFullReconcileCancellationWorkflow",
  "userCancelled",
  "full-reconcile-cancellation-progress-capture",
  "Reconciling SVN working copy status"
) "STA-013 installed Full Reconcile cancellation evidence fields"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "sourceControlUiFullReconcileCancellationWorkflow",
  "fullReconcileCancellationProgressCapture",
  "subversionr.installedSourceControlUiE2eFullReconcileCancellationWorkflow",
  "userCancelled",
  "full-reconcile-cancellation-progress-capture",
  "Reconciling SVN working copy status"
) "STA-013 installed Full Reconcile cancellation script-test evidence"
Assert-RequirementEvidenceRefs $requirementsEvidence "STA-015" @(
  "crates/subversionr-daemon/tests/rpc_dispatch.rs",
  "packages/vscode-extension/tests/statusSnapshotStore.test.ts",
  "packages/vscode-extension/tests/dirtyPathPipeline.test.ts"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "OPS-001" @(
  "docs/plans/m4-core-scm-operations.md",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/release/capture-vscode-renderer-ui.mjs"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "OPS-002" @(
  "docs/plans/m4-core-scm-operations.md",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/release/capture-vscode-renderer-ui.mjs"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "OPS-003" @(
  "docs/plans/m4-core-scm-operations.md",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/release/capture-vscode-renderer-ui.mjs"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "OPS-004" @(
  "docs/plans/m4-core-scm-operations.md",
  "docs/release/delete-unversioned-trash-policy.md",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/release/capture-vscode-renderer-ui.mjs"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "OPS-006" @(
  "docs/plans/m4-core-scm-operations.md",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/release/capture-vscode-renderer-ui.mjs"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "OPS-007" @(
  "docs/plans/m4-core-scm-operations.md",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/release/capture-vscode-renderer-ui.mjs"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "OPS-008" @(
  "docs/plans/m4-core-scm-operations.md",
  "packages/vscode-extension/package.json",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/src/repository/repositoryCommandController.ts",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
  "scripts/release/capture-vscode-renderer-ui.mjs"
)
Assert-Terms $rpcDispatchTests @(
  "operation_run_add_rejects_multiple_paths_to_preserve_failure_reconcile_safety",
  "operation_run_remove_accepts_multiple_paths_and_returns_targeted_reconcile_hints",
  '"paths":["scratch-a.txt","scratch-b.txt"]',
  '"paths":["src/old.c","src/other.c"]'
) "OPS selected Add safety and Remove daemon multi-path coverage"
Assert-Terms $operationRunRpcClientTests @(
  "fails fast on invalid add request field: %s",
  "sends operation/run remove with multiple explicit paths and returns targeted reconcile hints",
  "paths: [`"scratch-a.txt`", `"scratch-b.txt`"]",
  "paths: [`"src/old.c`", `"src/other.c`"]"
) "OPS selected Add safety and Remove TypeScript RPC multi-path coverage"
Assert-Terms $repositoryCommandControllerTests @(
  "adds selected unversioned files and directories with SVN-appropriate depths",
  "confirms and removes multiple selected changed SCM resources through one operation/run request",
  "confirms and removes multiple selected changed SCM resources while keeping local content",
  "confirms and reverts multiple selected changed SCM resources through one operation/run request",
  "reconciles a successful selected add before reporting a later selected add failure",
  "rejects duplicate selected paths for `$label before confirmation or operation/run",
  "rejects mixed repository selected paths for `$label before confirmation or operation/run",
  "rejects repository root selected paths for `$label before confirmation or operation/run",
  "rejects stale projection generations for `$label before confirmation or operation/run",
  "rejects selected paths no longer authorized by the current projection for `$label",
  "SubversionR added 2 SVN resources",
  "SubversionR removed 2 SVN resources",
  "SubversionR reverted 2 SVN resources"
) "OPS selected Add/Remove/Revert SCM multi-selection and validation coverage"
Assert-RequirementEvidenceRefs $requirementsEvidence "REP-013" @(
  "packages/vscode-extension/tests/repositoryCommandController.test.ts",
  "packages/vscode-extension/tests/repositoryLifecycleService.test.ts",
  "packages/vscode-extension/tests/repositorySessionService.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "REP-014" @(
  "packages/vscode-extension/tests/repositoryLifecycleService.test.ts",
  "packages/vscode-extension/tests/repositoryLifecycleNotificationService.test.ts",
  "packages/vscode-extension/tests/installedRepositoryLifecycleReport.test.ts",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "PRD-012" @(
  "packages/vscode-extension/tests/diagnosticsCommandController.test.ts",
  "packages/vscode-extension/tests/diagnosticsReportService.test.ts",
  "packages/vscode-extension/tests/diagnosticsRedaction.test.ts",
  "docs/security/support-redaction-checklist.md",
  "scripts/verify-support-intake.ps1"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "SEC-001" @(
  "packages/vscode-extension/tests/credentialController.test.ts",
  "packages/vscode-extension/src/auth/credentialController.ts",
  "docs/release/security-evidence-matrix.md"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "SEC-002" @(
  "packages/vscode-extension/tests/diagnosticsRedaction.test.ts",
  "packages/vscode-extension/tests/diagnosticsReportService.test.ts",
  "docs/security/support-redaction-checklist.md",
  "scripts/verify-support-intake.ps1"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "SEC-003" @(
  "packages/vscode-extension/tests/credentialController.test.ts",
  "packages/vscode-extension/tests/certificateTrustController.test.ts",
  "packages/vscode-extension/src/auth/credentialController.ts",
  "packages/vscode-extension/src/auth/certificateTrustController.ts"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "SEC-004" @(
  "packages/vscode-extension/tests/certificateTrustController.test.ts",
  "packages/vscode-extension/src/auth/certificateTrustController.ts",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "docs/release/security-evidence-matrix.md"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "SEC-005" @(
  "packages/vscode-extension/tests/certificateTrustController.test.ts",
  "packages/vscode-extension/src/auth/certificateTrustController.ts",
  "docs/release/security-evidence-matrix.md"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "SEC-006" @(
  "packages/vscode-extension/tests/credentialController.test.ts",
  "packages/vscode-extension/tests/certificateTrustController.test.ts",
  "packages/vscode-extension/src/auth/credentialController.ts",
  "packages/vscode-extension/src/auth/certificateTrustController.ts",
  "docs/release/security-evidence-matrix.md"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "SEC-007" @(
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "packages/vscode-extension/tests/credentialController.test.ts",
  "packages/vscode-extension/tests/certificateTrustController.test.ts",
  "packages/vscode-extension/src/security/workspaceTrust.ts"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "SEC-008" @(
  "packages/vscode-extension/tests/externalToolConfiguration.test.ts",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "packages/vscode-extension/src/security/externalToolConfiguration.ts",
  "packages/vscode-extension/package.json"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "SEC-009" @(
  "packages/vscode-extension/tests/backendProcess.test.ts",
  "packages/vscode-extension/src/backend/backendProcess.ts",
  "crates/subversionr-daemon/src/stdio.rs",
  "crates/subversionr-daemon/tests/stdio_rpc.rs"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "SEC-010" @(
  "packages/vscode-extension/tests/jsonRpcStreamClient.test.ts",
  "packages/vscode-extension/tests/backendProcess.test.ts",
  "crates/subversionr-daemon/src/stdio.rs",
  "crates/subversionr-daemon/tests/stdio_rpc.rs"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "SEC-011" @(
  "packages/vscode-extension/src/security/externalToolConfiguration.ts",
  "packages/vscode-extension/tests/externalToolConfiguration.test.ts",
  "packages/vscode-extension/src/tortoise/tortoiseDetector.ts",
  "packages/vscode-extension/tests/tortoiseDetector.test.ts",
  "packages/vscode-extension/src/tortoise/tortoiseLauncher.ts",
  "packages/vscode-extension/tests/tortoiseLauncher.test.ts",
  "packages/vscode-extension/src/tortoise/tortoiseCommandController.ts",
  "packages/vscode-extension/tests/tortoiseCommandController.test.ts",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "packages/vscode-extension/package.json",
  "docs/release/security-evidence-matrix.md"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "SEC-012" @(
  "docs/release/security-evidence-matrix.md",
  "docs/plans/m7-release-publication.md",
  "docs/release/m7-release-readiness-gates.md",
  "scripts/release/test-vscode-install-rollback-fixture.ps1",
  "scripts/tests/release-install-rollback-fixture.tests.ps1",
  "scripts/release/test-vscode-cli-install-vsix.ps1",
  "scripts/tests/release-vsix-scripts.tests.ps1",
  "scripts/release/run-beta-candidate-evidence.ps1",
  "scripts/tests/release-beta-candidate-evidence-scripts.tests.ps1"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "SEC-014" @(
  "packages/vscode-extension/tests/diagnosticsRedaction.test.ts",
  "docs/security/support-redaction-checklist.md",
  "scripts/verify-support-intake.ps1"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "SEC-016" @(
  "docs/release/security-evidence-matrix.md",
  "docs/release/m7-release-readiness-gates.md",
  "docs/plans/m7-release-publication.md",
  "docs/security/malicious-input-corpus.win32-x64.json",
  "docs/security/native-remote-fuzz-contract.win32-x64.json",
  "crates/subversionr-daemon/tests/native_bridge.rs",
  "scripts/release/generate-malicious-input-corpus.ps1",
  "scripts/release/verify-malicious-input-corpus.ps1",
  "scripts/tests/release-malicious-input-corpus-scripts.tests.ps1",
  "scripts/release/generate-native-remote-fuzz-contract.ps1",
  "scripts/release/verify-native-remote-fuzz-contract.ps1",
  "scripts/tests/release-native-remote-fuzz-contract-scripts.tests.ps1",
  "scripts/release/generate-native-remote-fuzz-target-preflight.ps1",
  "scripts/release/verify-native-remote-fuzz-target-preflight.ps1",
  "scripts/tests/release-native-remote-fuzz-target-preflight-scripts.tests.ps1",
  "fuzz/Cargo.toml",
  "fuzz/fuzz_targets/svn_server_response_history_log.rs",
  "fuzz/corpus/svn_server_response_history_log/manifest.json",
  "scripts/release/generate-native-remote-fuzz-fixed-seed-smoke.ps1",
  "scripts/release/verify-native-remote-fuzz-fixed-seed-smoke.ps1",
  "scripts/tests/release-native-remote-fuzz-fixed-seed-smoke-scripts.tests.ps1"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "OBS-005" @(
  "packages/vscode-extension/tests/diagnosticsCommandController.test.ts",
  "packages/vscode-extension/tests/diagnosticsReportService.test.ts",
  "packages/vscode-extension/src/diagnostics/diagnosticsReportService.ts"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "OBS-006" @(
  "packages/vscode-extension/tests/diagnosticsCommandController.test.ts",
  "packages/vscode-extension/tests/diagnosticsReportService.test.ts",
  "packages/vscode-extension/src/diagnostics/diagnosticsReportService.ts",
  "packages/vscode-extension/src/extension.ts"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "OBS-007" @(
  "packages/vscode-extension/tests/diagnosticsReportService.test.ts",
  "packages/vscode-extension/tests/diagnosticsRedaction.test.ts",
  "packages/vscode-extension/tests/repositoryOperationJournal.test.ts",
  "packages/vscode-extension/src/diagnostics/diagnosticsRedaction.ts",
  "packages/vscode-extension/src/diagnostics/installedRedactionReport.ts",
  "packages/vscode-extension/tests/installedRedactionReport.test.ts",
  "packages/vscode-extension/src/operations/repositoryOperationJournal.ts",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "scripts/release/test-vscode-installed-extension-host.ps1",
  "scripts/tests/release-installed-extension-host-scripts.tests.ps1"
)
Assert-RequirementEvidenceRefs $requirementsEvidence "STA-014" @(
  "packages/vscode-extension/tests/vscodeSourceControlPresenter.test.ts",
  "packages/vscode-extension/src/scm/vscodeSourceControlPresenter.ts",
  "packages/vscode-extension/tests/installedSourceControlSurfaceReport.test.ts",
  "packages/vscode-extension/src/diagnostics/installedSourceControlSurfaceReport.ts",
  "packages/vscode-extension/tests/backendProcess.test.ts",
  "packages/vscode-extension/tests/backendService.test.ts",
  "packages/vscode-extension/src/backend/backendService.ts",
  "packages/vscode-extension/tests/backendLifecycleUiService.test.ts",
  "packages/vscode-extension/src/backend/backendLifecycleUiService.ts",
  "packages/vscode-extension/tests/extensionManifest.test.ts",
  "packages/vscode-extension/l10n/bundle.l10n.json",
  "packages/vscode-extension/l10n/bundle.l10n.ja.json",
  "packages/vscode-extension/l10n/bundle.l10n.zh-cn.json",
  "packages/vscode-extension/src/extension.ts",
  "packages/vscode-extension/package.json",
  "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1",
  "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1"
)
Assert-Terms $installedSourceControlUiE2eScript @(
  "partialFreshnessRendererCapture",
  "staleFreshnessRendererCapture",
  "partial-freshness-renderer-capture",
  "stale-freshness-renderer-capture",
  "SVN status partial",
  "SVN status stale"
) "STA-014 installed stale/partial renderer capture evidence fields"
Assert-Terms $installedSourceControlUiE2eScriptTests @(
  "partialFreshnessRendererCapture",
  "staleFreshnessRendererCapture",
  "partial-freshness-renderer-capture",
  "stale-freshness-renderer-capture",
  "SVN status partial",
  "SVN status stale"
) "STA-014 installed stale/partial renderer capture script-test evidence"

foreach ($id in @(
  "PRD-006",
  "REP-005",
  "STA-001",
  "STA-012",
  "STA-014",
  "ARC-011",
  "DIR-002",
  "DIR-004",
  "DIR-006",
  "DIR-007",
  "DIR-009",
  "DIR-010",
  "DIR-011",
  "DIR-012",
  "DIR-013",
  "DIR-020",
  "OBS-004",
  "TST-024"
)) {
  Assert-RequirementEvidenceRefs $requirementsEvidence $id @(
    "packages/vscode-extension/tests/stateEngineBetaPerformanceGate.test.ts",
    "scripts/release/test-state-engine-beta-performance.ps1",
    "scripts/tests/release-state-engine-beta-performance-scripts.tests.ps1"
  )
}
Assert-Terms $stateEngineBetaPerformanceGateTests @(
  "state engine Beta performance gate",
  "single-file save",
  "event burst",
  "nested working-copy and external boundary",
  "dirty-generation refreshes",
  "sidecar restart",
  "10k local working-copy snapshot",
  "TEN_THOUSAND_LOCAL_RESOURCES",
  "rootInfinityTargetCount",
  "workingCopyMutation",
  "publicReadinessClaim: false",
  "No 100k or 1M working-copy performance claim.",
  "No default background remote polling claim."
) "Beta-F state-engine performance TS gate coverage"
Assert-Terms $stateEngineBetaPerformanceScript @(
  "subversionr.release.state-engine-beta-performance.`$Target.v1",
  "MaxProjectionMs",
  "must resolve inside the repository target directory",
  "SUBVERSIONR_STATE_ENGINE_BETA_PERFORMANCE_EVIDENCE_PATH",
  'Join-Path (Join-Path $repoRoot "packages") "vscode-extension"',
  '--dir $extensionWorkspacePath',
  "singleFileSaveNoFullScan",
  "eventBurstBounded",
  "nestedExternalBoundaryIsolation",
  "dirtyGenerationSupersede",
  "sidecarRestartRecovery",
  "tenThousandWorkingCopyProjection",
  "State-engine Beta performance gate passed."
) "Beta-F state-engine performance release gate coverage"
Assert-NoTerms $stateEngineBetaPerformanceScript @(
  "--filter svn-r"
) "Beta-F state-engine performance release gate must not bind to the mutable extension package name"
Assert-Terms $stateEngineBetaPerformanceScriptTests @(
  "release-state-engine-beta-performance-scripts.tests.ps1",
  "subversionr.release.state-engine-beta-performance.win32-x64.v1",
  '--dir $extensionWorkspacePath',
  '--filter svn-r',
  "rootInfinityTargetCount",
  "actualRefreshTargets",
  "boundaryAcceptedByParent",
  "firstSignalAborted",
  "statusCompleteness",
  "localEntryCount",
  "100k/1M",
  "default background remote polling",
  "FixtureRoot must be an explicit path",
  "FixtureRoot must resolve inside the repository target directory",
  "MaxProjectionMs must be positive"
) "Beta-F state-engine performance release gate script-test coverage"
Assert-Terms $rootPackageJson @(
  "release:test-state-engine-beta-performance-scripts",
  "release:test-state-engine-beta-performance:win32-x64",
  "scripts/release/test-state-engine-beta-performance.ps1",
  "target/release-evidence/state-engine-beta-performance/win32-x64",
  "target/release-evidence/subversionr-state-engine-beta-performance-win32-x64.json"
) "Beta-F state-engine performance package script coverage"
Assert-Terms $ciWorkflow @(
  "Release state-engine Beta performance script tests",
  "pnpm release:test-state-engine-beta-performance-scripts",
  "Test state-engine Beta performance",
  "pnpm release:test-state-engine-beta-performance:win32-x64"
) "Beta-F state-engine performance CI coverage"
Assert-Terms $fastPrWorkflow @(
  "Test state-engine Beta performance",
  "pnpm release:test-state-engine-beta-performance:win32-x64"
) "Beta-F state-engine performance PR Fast coverage"
Assert-Terms $releaseGates @(
  "state-engine performance baseline",
  "subversionr.release.state-engine-beta-performance.win32-x64.v1",
  "single-file save",
  "bounded event bursts",
  "nested working copies and externals",
  "dirty-generation supersede",
  "sidecar restart",
  "10k local working-copy",
  "100k or 1M",
  "default background remote polling"
) "Beta-F state-engine performance release gate documentation"
Assert-Terms $roadmap @(
  "State-engine floor",
  "single-file saves must not trigger full scans",
  "event bursts must stay bounded",
  "nested working copies and externals must remain isolated",
  "dirty-generation supersede must not publish stale results",
  "sidecar restart must recover or mark stale",
  "10k local working copy must have a recorded baseline"
) "Beta-F state-engine performance roadmap coverage"

Assert-Terms $betaCandidateEvidenceScript @(
  "subversionr.release.beta-candidate-consistency.`$Target.v1",
  "VsixPath",
  "VsixEvidencePath",
  "CiWorkflowPath",
  "ReleaseEvidenceRoot",
  "ArtifactBundleManifestPath",
  "OutputPath",
  "extension/package.json",
  "extension.vsixmanifest",
  "extension/dist/extension.js",
  "TargetPlatform",
  "installed-vsix",
  "installRollbackFixture",
  "attestation",
  "live-attestation-verified",
  "actions/attest@v4",
  "post-release-asset-digest-verification",
  "originalBuildProvenanceClaim",
  "provenance and publication gaps bind the pending current-candidate attestation contract while preserving historical public-cutover attestation evidence separately",
  "artifactBundle",
  "artifactBundleManifest",
  "Beta candidate consistency requires candidate-seal provenance mode",
  "Beta candidate consistency requires an exact frozen-contract subject comparison",
  "subversionr.release.beta-artifact-bundle-manifest.`$Target.v1",
  "manifest-self-sha256-bound-by-beta-candidate-consistency-report",
  "artifact bundle manifest binds the current VSIX, SBOM, NOTICE, release evidence, installed UI artifacts, and CI upload contract",
  "ciWorkflow",
  "includeHiddenFiles",
  "CI Beta candidate artifact upload path list must match the exact ordered Beta-G bundle contract",
  "target/release-evidence/subversionr-source-sbom.cdx.json",
  "target/release-evidence/subversionr-beta-artifact-bundle-manifest-`$Target.json",
  "target/release-evidence/subversionr-beta-candidate-consistency-`$Target.json",
  "firstPartyArtifacts",
  "componentMappings",
  "publicReadinessClaim",
  "Marketplace/public install",
  "coverage-guided fuzzing",
  "Verified SubversionR Beta candidate evidence consistency"
) "Beta-G candidate evidence consistency gate coverage"
Assert-Terms $attestationWorkflow @(
  "workflow_dispatch:",
  "release_tag:",
  "contents: read",
  "id-token: write",
  "attestations: write",
  "artifact-metadata: write",
  'group: release-vsix-attestation-${{ inputs.release_tag }}',
  "cancel-in-progress: false",
  "actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0",
  "gh release download",
  "scripts/release/verify-release-attestation-subject.ps1",
  "scripts/release/generate-post-release-asset-verification-predicate.ps1",
  "actions/attest@a1948c3f048ba23858d222213b7c278aabede763",
  "predicate-type: https://github.com/Hitsuki-Ban/SubversionR/attestations/post-release-asset/v1",
  "predicate-path: target/release-attestation/win32-x64/post-release-asset-verification-predicate.json",
  "gh attestation verify",
  "--bundle",
  "--signer-workflow Hitsuki-Ban/SubversionR/.github/workflows/attest-release-vsix.yml",
  "--signer-digest",
  "--source-ref",
  "--source-digest",
  "--predicate-type https://github.com/Hitsuki-Ban/SubversionR/attestations/post-release-asset/v1",
  "--deny-self-hosted-runners",
  "scripts/release/record-live-github-attestation.ps1",
  "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
) "live GitHub artifact attestation workflow coverage"
Assert-Terms $marketplaceIdentityBootstrapWorkflow @(
  "workflow_dispatch:",
  "contents: read",
  "id-token: write",
  "environment: marketplace",
  "azure/login@532459ea530d8321f2fb9bb10d1e0bcf23869a43",
  "client-id:",
  "tenant-id:",
  "allow-no-subscriptions: true"
) "Marketplace identity bootstrap Node 24 action and OIDC workflow coverage"
Assert-NoTerms $marketplaceIdentityBootstrapWorkflow @(
  "azure/login@a457da9ea143d694b1b9c7c869ebb04ebe844ef5"
) "Marketplace identity bootstrap must not use the Node 20 azure/login revision"
Assert-Terms $publication023Evidence @(
  "# 0.2.3 Beta Publication Evidence",
  "v0.2.3-beta.1",
  "a92b04d689bb8a624391f0f2ce5d970b9568dc02",
  "subversionr-win32-x64-0.2.3.vsix",
  "8292661",
  "991199a1cd874b76e10dd8ca383edac766b169d638e0b42253022507c435b12b",
  "aaad65fd21de301397f25cfad0a30f3ff26b7ce1a2826dac451682fac6272889",
  "29215241333",
  "34984195",
  "29215282438",
  "Microsoft.VisualStudio.Code.PreRelease=true",
  "does not claim that the public install flow was exercised",
  "does not claim original source-to-binary build provenance or artifact signing",
  "public-install verification",
  "overall public release readiness"
) "0.2.3 publication evidence coverage"
Assert-Terms $publication024Evidence @(
  '# 0.2.4 Beta Publication Evidence',
  'shipped on 2026-07-15 JST (2026-07-14 UTC)',
  '- Release: [`v0.2.4-beta.1`](https://github.com/Hitsuki-Ban/SubversionR/releases/tag/v0.2.4-beta.1)',
  '- Release ID: `354129040`',
  '- Published at: `2026-07-14T23:37:44Z` (`2026-07-15T08:37:44+09:00`)',
  '- Source commit: `22e6645067e64f3b403392c4648a8b23bdca1b09`',
  '- VSIX asset: `subversionr-win32-x64-0.2.4.vsix`, `8295021` bytes, SHA256 `880e7937423695ca772436f01e2419498463ebd7cc25ba8a283a135530418249`',
  '- Candidate evidence bundle: `subversionr-win32-x64-beta-candidate.zip`, `15991871` bytes, SHA256 `16ef3415f28de609874ce3b775feb9b756beccd813ff4f0511d15444cadf50b3`',
  '- Source SBOM: `subversionr-source-sbom.cdx.json`, `272845` bytes, SHA256 `780010d7b0c36ab07986bd17868a2da15cf3f8ef088305efbffb43fb1e0e603e`',
  '- Third-party notices: `THIRD-PARTY-NOTICES.md`, `75300` bytes, SHA256 `d034ba2756b7e555f582f29ed5a2bf1fe29df6980c8593cbc480a432dfb14edf`',
  '1,469 manifest-verified payloads plus the manifest and final consistency JSON, for 1,471 ZIP entries',
  '- Workflow run: [`29376755227`](https://github.com/Hitsuki-Ban/SubversionR/actions/runs/29376755227)',
  '- Attestation: [`35359353`](https://github.com/Hitsuki-Ban/SubversionR/attestations/35359353)',
  '- Subject: `subversionr-win32-x64-0.2.4.vsix`',
  '- Subject SHA256: `880e7937423695ca772436f01e2419498463ebd7cc25ba8a283a135530418249`',
  '- Predicate type: `https://github.com/Hitsuki-Ban/SubversionR/attestations/post-release-asset/v1`',
  '- Publish workflow run: [`29376825168`](https://github.com/Hitsuki-Ban/SubversionR/actions/runs/29376825168)',
  '- Gallery entry: [`hitsuki-ban.subversionr`](https://marketplace.visualstudio.com/items?itemName=hitsuki-ban.subversionr)',
  '- Display name: `SVN-R`',
  '- Version and target: `0.2.4`, `win32-x64`',
  '- Gallery flags: `validated`',
  '- VS Code pre-release property: `Microsoft.VisualStudio.Code.PreRelease=true`',
  '- Extension/version `lastUpdated`: `2026-07-14T23:47:33.967Z`',
  '- Gallery `VsixSha256` property: `880e7937423695ca772436f01e2419498463ebd7cc25ba8a283a135530418249`',
  '- Gallery VSIX asset: [`Microsoft.VisualStudio.Services.VSIXPackage`](https://hitsuki-ban.gallerycdn.vsassets.io/extensions/hitsuki-ban/subversionr/0.2.4/1784072476933/Microsoft.VisualStudio.Services.VSIXPackage)',
  '- Gallery VSIX size: `8295021` bytes',
  '- Gallery VSIX SHA256: `880e7937423695ca772436f01e2419498463ebd7cc25ba8a283a135530418249`',
  '- Independent verification time: `2026-07-14T23:48:23.1547110Z`',
  "does not claim that the public install flow was exercised",
  "does not claim original source-to-binary build provenance or artifact signing",
  'This evidence does not claim a stable-channel release, artifact signing, signed source-to-binary provenance, public-install verification, previous-stable upgrade or rollback, cross-platform support, final SBOM/NOTICE/legal approval, final vulnerability approval, or overall public release readiness.'
) "0.2.4 publication evidence coverage"
Assert-NoTerms $publication024Evidence @(
  "__GALLERY_",
  "__PENDING_"
) "0.2.4 publication evidence must contain final Gallery facts"
Assert-Terms $attestationContract @(
  "subversionr.release.github-attestation-contract.win32-x64.v1",
  "subversionr-win32-x64-0.2.0.vsix",
  "d8ea4bfc187598a80ef0131f6345a60b8f3dcba2c9b22b992ea370f12eaa85cb",
  "actions/attest@v4",
  "a1948c3f048ba23858d222213b7c278aabede763",
  "https://github.com/Hitsuki-Ban/SubversionR/attestations/post-release-asset/v1",
  "docs/release/post-release-asset-verification-predicate.v1.schema.json",
  ".github/workflows/attest-release-vsix.yml",
  '"bundleRequired": true',
  '"sourceRefRequired": true',
  '"sourceDigestRequired": true',
  '"signerDigestRequired": true',
  '"denySelfHostedRunners": true'
) "live GitHub artifact attestation subject contract coverage"
Assert-Terms $attestationPredicateSchema @(
  "subversionr.release.post-release-asset-verification-predicate.v1",
  "post-release-asset-digest-verification",
  '"originalBuildProvenanceClaim"',
  '"artifactSignatureClaim"',
  '"const": false',
  '"assetDownloadedFromRelease"',
  '"subjectSha256Matched"'
) "post-release asset verification predicate schema coverage"
Assert-Terms $attestationPredicateGenerator @(
  "verify-release-attestation-subject.ps1",
  "post-release-asset-digest-verification",
  "originalBuildProvenanceClaim = `$false",
  "artifactSignatureClaim = `$false",
  "assetDownloadedFromRelease = `$true",
  "subjectSha256Matched = `$true"
) "post-release asset verification predicate generation coverage"
Assert-Terms $attestationBundle @(
  "application/vnd.dev.sigstore.bundle.v0.3+json",
  '"tlogEntries"',
  '"dsseEnvelope"',
  '"payloadType":"application/vnd.in-toto+json"'
) "source-controlled exact GitHub attestation bundle coverage"
Assert-Terms $attestationVerification @(
  '"verificationResult":{',
  "application/vnd.dev.sigstore.verificationresult+json;version=0.1",
  '"verifiedTimestamps"',
  "application/vnd.dev.sigstore.bundle.v0.3+json",
  "Hitsuki-Ban/SubversionR",
  "subversionr-win32-x64-0.2.0.vsix",
  "d8ea4bfc187598a80ef0131f6345a60b8f3dcba2c9b22b992ea370f12eaa85cb",
  "https://github.com/Hitsuki-Ban/SubversionR/attestations/post-release-asset/v1",
  '"claim":"post-release-asset-digest-verification"',
  '"originalBuildProvenanceClaim":false',
  '"artifactSignatureClaim":false',
  "refs/heads/main",
  "720c92c3f1747a7e7dcf6143f2bf47171cfd9051"
) "source-controlled exact GitHub attestation verification coverage"
Assert-Terms $liveAttestationEvidence @(
  "subversionr.release.live-github-attestation.win32-x64.v1",
  '"publicReadinessClaim": false',
  '"signingClaim": false',
  '"status": "live-attestation-verified"',
  "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/29104476735",
  "https://github.com/Hitsuki-Ban/SubversionR/attestations/34774737",
  "50916ecb09fc175b6f1745ba56ff67e9c2a25a779cdd5f64e6dada175aba0a55",
  "dacdabab706d5bec6870d40d9c8b655ea178d645940960876abb78604bd1f9d0",
  "refs/heads/main",
  "720c92c3f1747a7e7dcf6143f2bf47171cfd9051",
  "--bundle docs/release/github-attestation-bundle.win32-x64.json",
  '"predicateClaim": "post-release-asset-digest-verification"',
  '"originalBuildProvenanceClaim": false',
  '"artifactSignatureClaim": false',
  "This post-release attestation does not prove the original VSIX source-to-binary build provenance.",
  '"verified": true'
) "source-controlled live GitHub artifact attestation evidence coverage"
Assert-Terms $attestationSubjectVerifier @(
  "subversionr.release.github-attestation-contract.win32-x64.v1",
  "Attestation subject SHA256",
  "Attestation subject size",
  "Release tag must match the attestation contract"
) "released attestation subject verification coverage"
Assert-Terms $liveAttestationRecorder @(
  "subversionr.release.live-github-attestation.win32-x64.v1",
  "ConvertTo-CanonicalJson",
  "Verification result must contain the exact BundlePath attestation.",
  "post-release-asset-digest-verification",
  "originalBuildProvenanceClaim",
  "artifactSignatureClaim",
  "bundleSha256",
  "resultSha256",
  "denySelfHostedRunners",
  "publicReadinessClaim = `$false",
  "signingClaim = `$false"
) "live GitHub artifact attestation evidence recorder coverage"
Assert-Terms $liveAttestationScriptTests @(
  "verify-release-attestation-subject.ps1",
  "generate-post-release-asset-verification-predicate.ps1",
  "record-live-github-attestation.ps1",
  "actions/attest@a1948c3f048ba23858d222213b7c278aabede763",
  "Evidence recording should reject signed build provenance overclaims.",
  "Evidence recording should reject a verification result for a different bundle.",
  "Release live GitHub attestation script tests passed"
) "live GitHub artifact attestation script fixture coverage"
Assert-Terms $ciWorkflow @(
  "pnpm native:build-daemon:release",
  "Live GitHub attestation script tests",
  "pnpm release:test-live-attestation-scripts"
) "live GitHub artifact attestation CI coverage"
Assert-Terms $fastPrWorkflow @(
  "Live GitHub attestation script tests",
  "pnpm release:test-live-attestation-scripts"
) "live GitHub artifact attestation PR Fast coverage"
Assert-Terms $betaArtifactBundleManifestScript @(
  "subversionr.release.beta-artifact-bundle-manifest.`$Target.v1",
  "Beta candidate artifact bundle generation requires candidate-seal provenance mode",
  "Beta candidate artifact bundle generation requires an exact frozen-contract subject comparison",
  "candidateSeal",
  "asserted-exact-match",
  "env.SUBVERSIONR_RELEASE_CI_MODE == 'candidate-seal'",
  "Beta artifact bundle manifest must be generated before the final Beta candidate consistency report",
  "subversionr-source-sbom.cdx.json",
  "subversionr-beta-artifact-bundle-manifest-`$Target.json",
  "subversionr-beta-candidate-consistency-`$Target.json",
  "target/release-evidence/installed-source-control-ui-e2e/`$Target/**/*.png",
  "target/release-evidence/installed-source-control-ui-e2e/`$Target/**/*.txt",
  "target/release-evidence/installed-source-control-ui-e2e/`$Target/**/*.json",
  "Generated SubversionR Beta artifact bundle manifest"
) "Beta-G artifact bundle manifest generator coverage"
Assert-Terms $betaCandidateEvidenceScriptTests @(
  "release-beta-candidate-evidence-scripts.tests.ps1",
  "subversionr.release.beta-candidate-consistency.win32-x64.v1",
  "generate-beta-artifact-bundle-manifest.ps1",
  "subversionr.release.beta-artifact-bundle-manifest.win32-x64.v1",
  "target\tests\release-beta-candidate-evidence-scripts",
  "Artifact bundle manifest should exclude extra local debug JSON evidence",
  "Beta candidate consistency should reject stale artifact bundle manifest hashes for source SBOM payloads",
  "Beta candidate consistency should reject stale artifact bundle manifest hashes for renderer payloads",
  "Beta candidate consistency should reject missing artifact bundle manifests",
  "stale installed VSIX evidence",
  "stale CLI install VSIX evidence",
  "stale CLI install VSIX path evidence",
  "Beta candidate consistency report should bind the upload action",
  "Continuous validation must not generate a Beta candidate artifact bundle manifest",
  "Continuous validation must not verify a Beta candidate consistency report",
  "Beta candidate consistency must reject provenance that did not assert the frozen subject match",
  "Beta candidate consistency report should bind the explicit candidate-seal upload condition",
  "Beta candidate consistency report should bind the CI workflow upload contract SHA256",
  "Beta candidate consistency report should include the CI workflow hash binding",
  "Beta candidate consistency report should include the artifact bundle manifest hash binding",
  "quoted upload step keys",
  "CI Beta candidate artifact upload path list must match the exact ordered Beta-G bundle contract",
  "exact ordered upload path list",
  "reordered upload path lists",
  "upload inputs outside the action with block",
  "quoted true hidden-file uploads",
  "unsupported with: input overwrite",
  "not another job",
  "upload-shaped text inside run blocks",
  "duplicate Windows upload steps",
  "duplicate upload step with blocks",
  "duplicate upload step uses keys",
  "duplicate upload step name keys",
  "upload conditions other than the explicit candidate-seal boundary",
  "quoted upload conditions that weaken the candidate-seal boundary",
  "spaced quoted upload conditions that weaken the candidate-seal boundary",
  "escaped quoted upload step keys",
  "mask upload failures",
  "quoted upload steps that can mask upload failures",
  "rollback fixture mutation overclaims",
  "stale rollback fixture package evidence",
  "public-readiness overclaims",
  "stale native artifact map input hashes",
  "VsixPath must be an explicit path",
  "actions/upload-artifact@v7",
  "target/release-evidence/subversionr-source-sbom.cdx.json",
  "target/release-evidence/subversionr-beta-artifact-bundle-manifest-win32-x64.json",
  "target/release-evidence/subversionr-beta-candidate-consistency-win32-x64.json",
  "if-no-files-found: error",
  "retention-days: 14"
) "Beta-G candidate evidence consistency script-test coverage"
Assert-Terms $rootPackageJson @(
  "release:test-beta-candidate-evidence-scripts",
  "release:prepare-beta-candidate:win32-x64",
  "release:generate-beta-artifact-bundle-manifest:win32-x64",
  "release:verify-beta-candidate:win32-x64",
  "scripts/release/run-beta-candidate-evidence.ps1",
  "scripts/release/generate-beta-artifact-bundle-manifest.ps1",
  "scripts/release/verify-beta-candidate-evidence.ps1",
  "%SUBVERSIONR_CODE_CLI%",
  ".cache/native/stage/subversion-win-x64/bin",
  "scripts/release/capture-vscode-renderer-ui.mjs",
  "-ArtifactBundleManifestPath target/release-evidence/subversionr-beta-artifact-bundle-manifest-win32-x64.json",
  "-CiWorkflowPath .github/workflows/ci.yml",
  "target/release-evidence/subversionr-beta-artifact-bundle-manifest-win32-x64.json",
  "target/release-evidence/subversionr-beta-candidate-consistency-win32-x64.json"
) "Beta-G candidate evidence package script coverage"
Assert-Terms $ciWorkflow @(
  "LINK: /Brepro",
  "Set reproducible source date epoch",
  'SOURCE_DATE_EPOCH=$epoch',
  "Release Beta candidate evidence script tests",
  "pnpm release:test-beta-candidate-evidence-scripts",
  "Generate Beta artifact bundle manifest",
  "pnpm release:generate-beta-artifact-bundle-manifest:win32-x64",
  "Verify Beta candidate evidence consistency",
  "pnpm release:verify-beta-candidate:win32-x64",
  "Rust native bridge integration test",
  "Validate native build entrypoints fail fast",
  "Upload Beta candidate VSIX and evidence bundle",
  "actions/upload-artifact@v7",
  "subversionr-win32-x64-beta-candidate",
  "target/release-evidence/subversionr-source-sbom.cdx.json",
  "target/release-evidence/subversionr-beta-artifact-bundle-manifest-win32-x64.json",
  "target/release-evidence/subversionr-beta-candidate-consistency-win32-x64.json",
  "if-no-files-found: error",
  "retention-days: 14"
) "Beta-G candidate evidence CI coverage"
$candidateSealStepCondition = "if: `${{ env.SUBVERSIONR_RELEASE_CI_MODE == 'candidate-seal' }}"
if (([regex]::Matches($ciWorkflow.Content, [regex]::Escape($candidateSealStepCondition))).Count -ne 3) {
  throw "Beta-G candidate evidence CI coverage must apply the explicit candidate-seal condition exactly to manifest generation, candidate verification, and candidate upload."
}
if ($releaseBuildEpoch.Content.Replace("`r`n", "`n") -ne "1783993493`n") {
  throw "native/release-build-epoch.txt: 0.2.4 release epoch must remain bound to the public release-slice base commit timestamp 1783993493."
}
Assert-DoesNotContain $ciWorkflow "target/release-evidence/*.json" "Beta-G candidate evidence CI coverage should not use broad release evidence JSON globs"
Assert-Terms $releaseGates @(
  "Beta-G candidate evidence consistency gate",
  "Beta artifact bundle manifest",
  "pnpm release:prepare-beta-candidate:win32-x64",
  "pnpm release:generate-beta-artifact-bundle-manifest:win32-x64",
  "subversionr.release.beta-candidate-consistency.win32-x64.v1",
  "subversionr.release.beta-artifact-bundle-manifest.win32-x64.v1",
  "current VSIX bytes",
  "Microsoft.VisualStudio.Code.PreRelease=true",
  "pending candidate attestation contract",
  'Historical `0.2.0` public-cutover attestation evidence',
  "explicit CI upload allowlist",
  "subversionr-win32-x64-beta-candidate",
  "actions/upload-artifact@v7",
  "Continuous-validation runs never enter this candidate-only sequence",
  'does not claim the `0.2.4` release or live attestation exists',
  "coverage-guided fuzzing"
) "Beta-G candidate evidence release gate documentation"
Assert-Terms $m7Plan @(
  'Beta-G: covered by `pnpm release:verify-beta-candidate:win32-x64`',
  "subversionr.release.beta-candidate-consistency.win32-x64.v1",
  "native artifact map",
  "provenance",
  "publication gaps",
  "installed VSIX gates",
  "artifact bundle manifest",
  "explicit CI upload allowlist",
  "subversionr-win32-x64-beta-candidate",
  "actions/upload-artifact@v7"
) "Beta-G candidate evidence M7 plan coverage"
Assert-Terms $roadmap @(
  "Candidate bundle consistency",
  'pnpm release:prepare-beta-candidate:win32-x64',
  'pnpm release:generate-beta-artifact-bundle-manifest:win32-x64',
  'Beta-G records `pnpm release:verify-beta-candidate:win32-x64`',
  "same-run Beta candidate consistency gate",
  "artifact bundle manifest",
  "explicit CI upload allowlist",
  "subversionr-win32-x64-beta-candidate",
  "actions/upload-artifact@v7"
) "Beta-G candidate evidence roadmap coverage"
Assert-Terms $roadmap @(
  "pnpm release:prepare-beta-candidate:win32-x64",
  "artifact bundle manifest",
  "same-run Beta candidate consistency gate",
  "explicit CI upload allowlist",
  "installed VSIX negative/failure-flow breadth"
) "Beta-G candidate evidence roadmap status"
Assert-Terms $projectReadme @(
  "Install From Releases",
  "Current Limits",
  "public-claim-matrix.md",
  "SECURITY.md",
  "sanitized diagnostics evidence"
) "public README support and claim-boundary surface"
Assert-Terms $ciWorkflow @(
  "workflow_dispatch:",
  "schedule:",
  "cron:",
  "concurrency:",
  "actions/checkout@v7",
  "pnpm/action-setup@v6",
  "actions/setup-node@v5",
  "astral-sh/setup-uv@v8.2.0",
  "actions/upload-artifact@v7"
) "scheduled/manual release workflow trigger while heavy native and publication gates remain explicit"
Assert-NoTerms $ciWorkflow @(
  "actions/checkout@v4",
  "pnpm/action-setup@v4"
) "scheduled/manual CI must not use Node 20 action runtimes"
if ($ciWorkflow.Content -match "(?m)^\s*(push|pull_request):\s*$") {
  throw ".github/workflows/ci.yml: heavy release workflow must not run on pull_request or push; keep it scheduled/manual while PR Fast owns automatic PR checks."
}

Assert-PrFastWorkflow $fastPrWorkflow
Assert-RetiredCloudflareBridgeDoc $cloudflarePrFastBridgeDoc

Assert-GithubActionsRestorationDoc $githubActionsRestorationDoc
Assert-PublicCutoverRunbook $publicCutoverRunbook
Assert-Terms $publicCutoverEvidence @(
  "subversionr.release.public-cutover-evidence.v1",
  "recorded-post-cutover",
  '"branchProtectionConfigured": true',
  '"rulesetId": 18761017',
  '"rulesetName": "protect-main"',
  '"integrationId": 15368',
  '"privateWorkflowsDisabled": true',
  '"workflowId": 300115281',
  '"workflowId": 303103620',
  '"state": "disabled_manually"',
  "https://github.com/Hitsuki-Ban/SubversionR/actions/runs/",
  "https://github.com/Hitsuki-Ban/SubversionR/releases/tag/v0.2.0-beta.1",
  "d8ea4bfc187598a80ef0131f6345a60b8f3dcba2c9b22b992ea370f12eaa85cb",
  "ca79f8cd2716caadc9c6e1e6c712c6904770a05e3660835b0ab58ce75bbbb266",
  '"status": "consistent"',
  '"missingPayloadCount": 0',
  '"mismatchedPayloadCount": 0',
  '"consistencyVerified": true',
  '"regenerationCompleted": true'
) "public cutover evidence contract"

Assert-Terms $securityPolicy @(
  "# Security Policy",
  "Supported Versions",
  "Reporting a Vulnerability",
  "Private Vulnerability Reporting",
  "Do Not Include",
  "Response Expectations",
  "public issue",
  "credentials",
  "private keys",
  "SecretStorage"
) "repository security policy coverage"

Assert-Terms $releaseGates @(
  "# M7 Release Readiness Gates",
  "## Release Channels",
  "## Blocking Gates",
  "## Platform Packaging Gates",
  "## Supply Chain Gates",
  "## Migration And Rollback Gates",
  "## Security And Support Gates",
  "## Non-Claims",
  "platform-specific VSIX",
  "SBOM",
  "NOTICE",
  "CVE",
  "signing",
  "rollback",
  "M7f isolated extension-directory fixture",
  "does not close the real VSIX package/install/upgrade/rollback gate",
  "M7g real VSIX package and isolated VS Code CLI install gate",
  "does not close Marketplace/public install",
  "M7h installed Extension Host command smoke gate",
  "subversionr.diagnostics.versionReport",
  "M7i installed core workflow gate",
  "subversionr.diagnostics.installedCoreWorkflowReport",
  "M7j1 installed Source Control surface gate",
  "subversionr.diagnostics.installedSourceControlSurfaceReport",
  "M7j2a unsigned provenance and Marketplace metadata preflight gate",
  "subversionr.release.marketplace-provenance-preflight.win32-x64.v1",
  "M7j2b live post-release GitHub artifact attestation evidence gate",
  "subversionr.release.live-github-attestation.win32-x64.v1",
  "M7j3 installed Source Control UI E2E gate",
  "subversionr.release.installed-source-control-ui-e2e.win32-x64.v1",
  "subversionr.updateToRevision",
  "update backend failure flows",
  "M7k1 public support intake and redaction preflight gate",
  "docs/security/support-redaction-checklist.md",
  "pnpm docs:verify-support-intake",
  "M7k2a Marketplace listing metadata and icon preflight",
  "M7k2b publication gaps and publish-auth contract preflight",
  "subversionr.release.publication-gaps.win32-x64.v1",
  "M7l1 vulnerability review input-contract preflight",
  "subversionr.release.vulnerability-review-preflight.win32-x64.v1",
  "M7l2a live OSV vulnerability review evidence gate",
  "subversionr.release.vulnerability-review-osv.win32-x64.v1",
  "M7l2b native advisory review evidence gate",
  "subversionr.release.native-advisory-review.win32-x64.v1",
  "M7l2c native advisory triage input-contract gate",
  "subversionr.release.native-advisory-triage-input.win32-x64.v1",
  "M7l2d vulnerability decision evidence gate",
  "subversionr.release.vulnerability-decision-evidence.win32-x64.v1",
  "M7l2e vulnerability decision input terminal-progress gate",
  "M7l2f manual native advisory terminal-review gate",
  "M7l2g Expat terminal CVE-2026-45186 decision gate",
  "native:expat@2.8.1",
  "CVE-2026-45186",
  "pnpm release:test-expat-terminal-decision-scripts",
  "M7l2h zlib terminal CVE-2026-22184 decision gate",
  "native:zlib@1.3.2",
  "CVE-2026-22184",
  "pnpm release:test-zlib-terminal-decision-scripts",
  "M7l2i APR terminal CVE decision gate",
  "native:apr@1.7.6",
  "CVE-2023-49582",
  "CVE-2022-24963",
  "CVE-2022-28331",
  "CVE-2021-35940",
  "pnpm release:test-apr-terminal-decision-scripts",
  "M7l2j APR-util terminal CVE decision gate",
  "native:apr-util@1.6.3",
  "CVE-2022-25147",
  "CVE-2017-12618",
  "pnpm release:test-apr-util-terminal-decision-scripts",
  "M7l2k Serf terminal CVE-2014-3504 decision gate",
  "native:serf@1.3.10",
  "CVE-2014-3504",
  "pnpm release:test-serf-terminal-decision-scripts",
  "M7l2l APR-iconv terminal named security finding decision gate",
  "native:apr-iconv@1.2.2",
  "APR-ICONV-1.2.2-NO-PUBLISHED-ADVISORY",
  "pnpm release:test-apr-iconv-terminal-decision-scripts",
  "subversionr.security.native-manual-advisory-review.win32-x64.v1",
  "M7l3 native artifact map preflight gate",
  "subversionr.release.native-artifact-map-preflight.win32-x64.v1",
  "M7l4 malicious input corpus preflight gate",
  "subversionr.release.malicious-input-corpus.win32-x64.v1",
  "M7l7 native remote-protocol fuzz readiness contract",
  "subversionr.release.native-remote-fuzz-contract.win32-x64.v1",
  "M7l8 native remote-protocol fuzz target source preflight",
  "subversionr.release.native-remote-fuzz-target-preflight.win32-x64.v1",
  "M7l9 native remote-protocol fixed seed harness smoke",
  "subversionr.release.native-remote-fuzz-fixed-seed-smoke.win32-x64.v1",
  "fuzz/Cargo.toml",
  "fuzz/Cargo.lock",
  "fuzz/fuzz_targets/svn_server_response_history_log.rs",
  "fuzz/corpus/svn_server_response_history_log/manifest.json",
  "pnpm release:test-native-remote-fuzz-target-preflight-scripts",
  "pnpm release:test-native-remote-fuzz-fixed-seed-smoke-scripts",
  "pnpm release:generate-native-remote-fuzz-fixed-seed-smoke:win32-x64",
  "pnpm release:verify-native-remote-fuzz-fixed-seed-smoke:win32-x64",
  "Marketplace publisher authorization",
  "publish authentication",
  "TST-018",
  "TortoiseSVN is optional"
) "M7 release gate coverage"

Assert-Terms $evidenceMatrix @(
  "# Security Evidence Matrix",
  "## Status Vocabulary",
  "## SEC Evidence",
  "## OBS Evidence",
  "## MIG Evidence",
  "## PRD Evidence",
  "## TST Evidence",
  "doc-gated",
  "blocked",
  "verified",
  "release-blocker"
) "security evidence matrix coverage"

Assert-Terms $publicClaimMatrix @(
  "# Public Claim Matrix",
  "## Status Vocabulary",
  "## Repository Transports",
  "## Authentication Modes",
  "## Optional External Integrations",
  "## Release Installation",
  "## Public Repository Preparation",
  "## Release Supply Chain Preparation",
  "claimed",
  "fixture-only",
  "deferred",
  "unsupported",
  "arbitrary HTTPS SVN servers",
  "localhost HTTPS DAV",
  "svn+ssh",
  "proxy auth",
  "client certificates",
  "Kerberos/NTLM",
  "SASL",
  "TortoiseSVN",
  "Isolated extension-directory install/upgrade/rollback",
  "Real VSIX package and isolated VS Code CLI install",
  "Installed VSIX Extension Host version-report smoke",
  "Installed VSIX core workflow E2E",
  "Installed VSIX Source Control surface",
  "Installed VSIX Source Control UI E2E",
  "Lock message and Unlock mode prompt cancellation/no-projection-mutation evidence",
  "Does not claim broad remote lock-server matrices",
  "break/steal policy coverage beyond implemented inputs",
  "load-scale lock behavior",
  "installed auth/certificate breadth",
  "Unsigned provenance and Marketplace metadata preflight",
  "Live GitHub artifact attestation",
  "Signed Marketplace/public install and previous-stable rollback",
  "Public support intake and redaction preflight",
  "Marketplace listing metadata and icon preflight",
  "Publication gaps and publish-auth contract preflight",
  "live-recorded",
  "Vulnerability review input-contract preflight",
  "Live OSV vulnerability review evidence",
  "Native advisory review evidence",
  "Native advisory triage input contract",
  "Vulnerability decision evidence",
  "Vulnerability decision input terminal-progress gate",
  "Manual native advisory terminal review",
  "Expat terminal CVE-2026-45186 decision gate",
  "APR-iconv terminal named security finding decision gate",
  "Native artifact map preflight",
  "Malicious input corpus preflight",
  "Native remote-protocol fuzz readiness contract",
  "Native remote-protocol fuzz target source preflight",
  "Native remote-protocol fixed seed harness smoke",
  'keeps `subversionr.mergeRangeRepository`',
  "hides all four from the Command Palette",
  "contributes none to user-facing menus",
  "FBL-06 deferral repro",
  "No SVN repository is open."
) "public claim matrix coverage"

Assert-Terms $m7Plan @(
  "# M7 Release, Packaging, Migration, and Public Publication Plan",
  "## M7a Implemented Slice",
  "## M7a Gates",
  "## M7c Implemented Slice",
  "## M7d Implemented Slice",
  "## M7d Gates",
  "## M7f Implemented Slice",
  "## M7f Gates",
  "## M7g Implemented Slice",
  "## M7g Gates",
  "## M7h Implemented Slice",
  "## M7h Gates",
  "## M7i Implemented Slice",
  "## M7i Gates",
  "## M7j1 Implemented Slice",
  "## M7j1 Gates",
  "## M7j2a Implemented Slice",
  "## M7j2a Gates",
  "## M7j2b Implemented Slice",
  "## M7j2b Gates",
  "## M7j3 Implemented Slice",
  "## M7j3 Gates",
  "STA-014",
  "partial/stale SourceControl status bar command and renderer capture evidence, Full Reconcile cancellation and recovery evidence",
  "sourceControlUiUpdateToRevisionWorkflow",
  "updateToRevisionRepositoryOracle",
  "sourceControlUiReadonlyPropertyReportWorkflow",
  "deterministic repository/resource report identity",
  "Beta-C: covered by M7j3 installed VSIX E2E evidence",
  "sourceControlUiLockMessageCancellationWorkflow",
  "sourceControlUiUnlockModeCancellationWorkflow",
  "lockMessageCancellationPromptCapture",
  "unlockModeCancellationPromptCapture",
  "local Lock message and Unlock mode prompt cancellation only",
  "broad remote lock-server matrices",
  "break/steal policy breadth",
  "load-scale lock behavior",
  "## M7k1 Implemented Slice",
  "## M7k1 Gates",
  "## M7k2a Implemented Slice",
  "## M7k2a Gates",
  "## M7k2b Implemented Slice",
  "## M7k2b Gates",
  "## M7k2c Implemented Slice",
  "## M7k2c Gates",
  "## M7l1 Implemented Slice",
  "## M7l1 Gates",
  "## M7l2a Implemented Slice",
  "## M7l2a Gates",
  "## M7l2b Implemented Slice",
  "## M7l2b Gates",
  "## M7l2c Implemented Slice",
  "## M7l2c Gates",
  "## M7l2d Implemented Slice",
  "## M7l2d Gates",
  "## M7l2e Implemented Slice",
  "## M7l2e Gates",
  "## M7l2f Implemented Slice",
  "## M7l2f Gates",
  "## M7l2g Implemented Slice",
  "## M7l2g Gates",
  "## M7l2h Implemented Slice",
  "## M7l2h Gates",
  "## M7l2i Implemented Slice",
  "## M7l2i Gates",
  "## M7l2j Implemented Slice",
  "## M7l2j Gates",
  "## M7l2k Implemented Slice",
  "## M7l2k Gates",
  "## M7l2l Implemented Slice",
  "## M7l2l Gates",
  "## M7l3 Implemented Slice",
  "## M7l3 Gates",
  "## M7l4 Implemented Slice",
  "## M7l4 Gates",
  "## M7l5 Implemented Slice",
  "## M7l5 Gates",
  "## M7l6 Implemented Slice",
  "## M7l6 Gates",
  "## M7l7 Implemented Slice",
  "## M7l7 Gates",
  "## M7l8 Implemented Slice",
  "## M7l8 Gates",
  "## M7l9 Implemented Slice",
  "## M7l9 Gates",
  "subversionr.cache.v1",
  "delete-and-reconcile",
  "subversionr.cache.clear",
  "subversionr.migration.showReport",
  "subversionr.diagnostics.versionReport",
  "pnpm release:test-install-rollback-fixture",
  "pnpm release:install-rollback:win32-x64",
  "pnpm release:test-vsix-scripts",
  "pnpm release:package-vsix:win32-x64",
  "pnpm release:test-vsix-cli-install:win32-x64",
  "pnpm release:test-installed-extension-host-scripts",
  "pnpm release:test-installed-extension-host:win32-x64",
  "pnpm release:test-installed-core-workflow-scripts",
  "pnpm release:test-installed-core-workflow:win32-x64",
  "pnpm release:test-installed-source-control-surface-scripts",
  "pnpm release:test-installed-source-control-surface:win32-x64",
  "pnpm release:test-installed-source-control-ui-e2e-scripts",
  "pnpm release:test-installed-source-control-ui-e2e:win32-x64",
  "pnpm release:test-provenance-scripts",
  "pnpm release:generate-provenance:win32-x64",
  "pnpm release:verify-provenance:win32-x64",
  "attestation.status",
  "live-attestation-verified",
  "pnpm docs:verify-support-intake",
  "pnpm release:test-support-intake-scripts",
  "resources/marketplace/icon.png",
  "Marketplace icon",
  "subversionr.release.publication-gaps.win32-x64.v1",
  "pnpm release:test-publication-gaps-scripts",
  "pnpm release:generate-publication-gaps:win32-x64",
  "pnpm release:verify-publication-gaps:win32-x64",
  "pnpm release:test-marketplace-publication-scripts",
  "subversionr.release.marketplace-publication.win32-x64.v1",
  "docs/release/marketplace-pre-release-owner-exception-0.2.4.md",
  "docs/release/github-attestation-candidate-contract.win32-x64.json",
  "docs/release/marketplace-identity-bootstrap-evidence.json",
  "docs/release/marketplace-publisher-authorization-evidence.json",
  "docs/release/marketplace-existing-listing-evidence.json",
  "subversionr.release.vulnerability-review-preflight.win32-x64.v1",
  "pnpm release:test-vulnerability-review-scripts",
  "pnpm release:generate-vulnerability-review:win32-x64",
  "pnpm release:verify-vulnerability-review:win32-x64",
  "subversionr.release.vulnerability-review-osv.win32-x64.v1",
  "pnpm release:test-live-osv-review-scripts",
  "pnpm release:generate-live-osv-review:win32-x64",
  "pnpm release:verify-live-osv-review:win32-x64",
  "subversionr.release.native-advisory-review.win32-x64.v1",
  "pnpm release:test-native-advisory-review-scripts",
  "pnpm release:generate-native-advisory-review:win32-x64",
  "pnpm release:verify-native-advisory-review:win32-x64",
  "subversionr.release.native-advisory-triage-input.win32-x64.v1",
  "pnpm release:test-native-advisory-triage-input-scripts",
  "pnpm release:generate-native-advisory-triage-input:win32-x64",
  "pnpm release:verify-native-advisory-triage-input:win32-x64",
  "subversionr.release.vulnerability-decision-evidence.win32-x64.v1",
  "pnpm release:test-vulnerability-decision-evidence-scripts",
  "M7l2e vulnerability decision input terminal-progress gate",
  "pnpm release:test-vulnerability-decision-input-scripts",
  "M7l2f manual native advisory terminal-review gate",
  "subversionr.security.native-manual-advisory-review.win32-x64.v1",
  "pnpm release:test-native-manual-advisory-review-scripts",
  "pnpm release:verify-native-manual-advisory-review:win32-x64",
  "M7l2g Expat terminal CVE-2026-45186 decision gate",
  "native:expat@2.8.1",
  "CVE-2026-45186",
  "pnpm release:test-expat-terminal-decision-scripts",
  "M7l2h zlib terminal CVE-2026-22184 decision gate",
  "native:zlib@1.3.2",
  "CVE-2026-22184",
  "pnpm release:test-zlib-terminal-decision-scripts",
  "M7l2i APR terminal CVE decision gate",
  "native:apr@1.7.6",
  "CVE-2023-49582",
  "CVE-2022-24963",
  "CVE-2022-28331",
  "CVE-2021-35940",
  "pnpm release:test-apr-terminal-decision-scripts",
  "M7l2j APR-util terminal CVE decision gate",
  "native:apr-util@1.6.3",
  "CVE-2022-25147",
  "CVE-2017-12618",
  "pnpm release:test-apr-util-terminal-decision-scripts",
  "M7l2k Serf terminal CVE-2014-3504 decision gate",
  "native:serf@1.3.10",
  "CVE-2014-3504",
  "pnpm release:test-serf-terminal-decision-scripts",
  "M7l2l APR-iconv terminal named security finding decision gate",
  "native:apr-iconv@1.2.2",
  "APR-ICONV-1.2.2-NO-PUBLISHED-ADVISORY",
  "Apache APR download metadata",
  "APR-iconv 1.2 CHANGES",
  "apache/apr-iconv GitHub advisories",
  "NVD keyword-search evidence",
  "OSV query evidence",
  "pnpm release:test-apr-iconv-terminal-decision-scripts",
  "pnpm release:verify-vulnerability-decision-input:win32-x64",
  "pnpm release:generate-vulnerability-decision-evidence:win32-x64",
  "pnpm release:verify-vulnerability-decision-evidence:win32-x64",
  "subversionr.release.native-artifact-map-preflight.win32-x64.v1",
  "docs/release/native-artifact-map.win32-x64.json",
  "pnpm release:test-native-artifact-map-scripts",
  "pnpm release:generate-native-artifact-map:win32-x64",
  "pnpm release:verify-native-artifact-map:win32-x64",
  "subversionr.release.malicious-input-corpus.win32-x64.v1",
  "docs/security/malicious-input-corpus.win32-x64.json",
  "pnpm release:test-malicious-input-corpus-scripts",
  "pnpm release:generate-malicious-input-corpus:win32-x64",
  "pnpm release:verify-malicious-input-corpus:win32-x64",
  "subversionr.release.native-remote-fuzz-contract.win32-x64.v1",
  "docs/security/native-remote-fuzz-contract.win32-x64.json",
  "pnpm release:test-native-remote-fuzz-contract-scripts",
  "pnpm release:generate-native-remote-fuzz-contract:win32-x64",
  "pnpm release:verify-native-remote-fuzz-contract:win32-x64",
  "subversionr.release.native-remote-fuzz-target-preflight.win32-x64.v1",
  "fuzz/Cargo.toml",
  "fuzz/Cargo.lock",
  "fuzz/fuzz_targets/svn_server_response_history_log.rs",
  "fuzz/corpus/svn_server_response_history_log/manifest.json",
  "pnpm release:test-native-remote-fuzz-target-preflight-scripts",
  "pnpm release:generate-native-remote-fuzz-target-preflight:win32-x64",
  "pnpm release:verify-native-remote-fuzz-target-preflight:win32-x64",
  "subversionr.release.native-remote-fuzz-fixed-seed-smoke.win32-x64.v1",
  "pnpm release:test-native-remote-fuzz-fixed-seed-smoke-scripts",
  "pnpm release:generate-native-remote-fuzz-fixed-seed-smoke:win32-x64",
  "pnpm release:verify-native-remote-fuzz-fixed-seed-smoke:win32-x64",
  "pnpm native:smoke-malicious-dav-xml:staged",
  "pnpm native:smoke-malicious-svn-server-response:staged",
  "pnpm release:test-vsix-scripts",
  "pnpm release:test-provenance-scripts",
  "publicReadinessClaim: false",
  "pnpm release:test-evidence-scripts",
  "pnpm release:verify-evidence",
  "SECURITY.md",
  "docs/release/m7-release-readiness-gates.md",
  "docs/release/security-evidence-matrix.md",
  "docs/release/public-claim-matrix.md",
  "pnpm release:verify-readiness"
) "M7 plan M7a coverage"

Assert-Terms $supportChecklist @(
  "# Support Redaction Checklist",
  "SEC-002",
  "SEC-014",
  "OBS-005",
  "OBS-007",
  "PRD-010",
  "PRD-012",
  ".svn/wc.db",
  "Do not paste redacted bundles into public comments"
) "support intake redaction checklist release coverage"

$productIds = @("PRD-010", "PRD-012", "PRD-015")
$securityIds = @(
  "SEC-001", "SEC-002", "SEC-003", "SEC-004",
  "SEC-005", "SEC-006", "SEC-007", "SEC-008",
  "SEC-009", "SEC-010", "SEC-011", "SEC-012",
  "SEC-013", "SEC-014", "SEC-015", "SEC-016"
)
$observabilityIds = @("OBS-005", "OBS-006", "OBS-007", "OBS-008")
$migrationIds = @("MIG-008", "MIG-009", "MIG-010", "MIG-011", "MIG-012")
$testIds = @("TST-018", "TST-020", "TST-022", "TST-024")

Assert-TraceIds $evidenceMatrix.Content $productIds $evidenceMatrix.RelativePath
Assert-TraceIds $evidenceMatrix.Content $securityIds $evidenceMatrix.RelativePath
Assert-TraceIds $evidenceMatrix.Content $observabilityIds $evidenceMatrix.RelativePath
Assert-TraceIds $evidenceMatrix.Content $migrationIds $evidenceMatrix.RelativePath
Assert-TraceIds $evidenceMatrix.Content $testIds $evidenceMatrix.RelativePath

foreach ($verifiedSecurityEvidenceId in @(
  "SEC-001",
  "SEC-004",
  "SEC-005",
  "SEC-006",
  "SEC-011"
)) {
  Assert-TableStatus $evidenceMatrix $verifiedSecurityEvidenceId "verified"
}
Assert-TableStatus $evidenceMatrix "SEC-012" "release-blocker"
Assert-TableStatus $evidenceMatrix "SEC-015" "release-blocker"
Assert-TableStatus $evidenceMatrix "MIG-008" "release-blocker"
Assert-TableStatus $evidenceMatrix "MIG-009" "release-blocker"
Assert-TableStatus $evidenceMatrix "MIG-010" "release-blocker"
Assert-TableStatus $evidenceMatrix "MIG-011" "release-blocker"
Assert-TableStatus $evidenceMatrix "MIG-012" "release-blocker"
Assert-TableStatus $evidenceMatrix "SEC-016" "release-blocker"
Assert-TableStatus $evidenceMatrix "TST-018" "release-blocker"
Assert-TableStatus $evidenceMatrix "TST-020" "release-blocker"
Assert-TableStatus $evidenceMatrix "TST-024" "release-blocker"

Assert-TableStatusIn $publicClaimMatrix "Arbitrary HTTPS SVN servers" @("deferred", "unsupported")
Assert-TableStatusIn $publicClaimMatrix "svn+ssh" @("deferred", "unsupported")
Assert-TableStatusIn $publicClaimMatrix "proxy auth" @("deferred", "unsupported")
Assert-TableStatusIn $publicClaimMatrix "client certificates" @("deferred", "unsupported")
Assert-TableStatusIn $publicClaimMatrix "Kerberos/NTLM" @("deferred", "unsupported")
Assert-TableStatusIn $publicClaimMatrix "SASL" @("deferred", "unsupported")
Assert-TableStatusIn $publicClaimMatrix "TortoiseSVN" @("deferred", "unsupported")
Assert-TableStatusIn $publicClaimMatrix "Merge, merge preview, and mergeinfo" @("deferred")
Assert-TableStatusIn $publicClaimMatrix "localhost HTTPS DAV" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "System ``svn`` CLI" @("unsupported")
Assert-TableStatusIn $publicClaimMatrix '`win32-x64` staged package layout' @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "Isolated extension-directory install/upgrade/rollback" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "Real VSIX package and isolated VS Code CLI install" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "Installed VSIX Extension Host version-report smoke" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "Installed VSIX core workflow E2E" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "Installed VSIX Source Control surface" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "Installed VSIX Source Control UI E2E" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "Unsigned provenance and Marketplace metadata preflight" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "Live GitHub artifact attestation" @("live-recorded")
Assert-TableStatusIn $publicClaimMatrix "Signed Marketplace/public install and previous-stable rollback" @("deferred")
Assert-TableStatusIn $publicClaimMatrix "Public support intake and redaction preflight" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "Marketplace listing metadata and icon preflight" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "Publication gaps and publish-auth contract preflight" @("live-recorded")
Assert-TableStatusIn $publicClaimMatrix "Vulnerability review input-contract preflight" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "Live OSV vulnerability review evidence" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "Native advisory review evidence" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "Native advisory triage input contract" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "Vulnerability decision evidence" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "Vulnerability decision input terminal-progress gate" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "Manual native advisory terminal review" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "Expat terminal CVE-2026-45186 decision gate" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "zlib terminal CVE-2026-22184 decision gate" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "APR terminal CVE decision gate" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "Native artifact map preflight" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "Malicious input corpus preflight" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "Native malicious DAV/XML fixture" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "Native malicious svn:// server-response fixture" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "Native remote-protocol fuzz readiness contract" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "Native remote-protocol fuzz target source preflight" @("fixture-only")
Assert-TableStatusIn $publicClaimMatrix "Native remote-protocol fixed seed harness smoke" @("fixture-only")

Assert-Contains $roadmap "M7a release-readiness gates" "roadmap M7a status"
Assert-Contains $roadmap "M7c generated CycloneDX source SBOM" "roadmap M7c status"
Assert-Contains $roadmap "M7d cache schema and migration report foundation with protocol v1.20 ``cacheSchema``" "roadmap M7d status"
Assert-Contains $roadmap "M7f isolated release install/upgrade/rollback fixture" "roadmap M7f status"
Assert-Contains $roadmap "M7g real ``win32-x64`` VSIX package" "roadmap M7g status"
Assert-Contains $roadmap "M7h installed VSIX Extension Host version-report command smoke gate" "roadmap M7h status"
Assert-Contains $roadmap "M7i installed VSIX core workflow E2E gate" "roadmap M7i status"
Assert-Contains $roadmap "M7j1 installed VSIX Source Control surface gate" "roadmap M7j1 status"
Assert-Contains $roadmap "M7j2a unsigned provenance and Marketplace metadata preflight gate" "roadmap M7j2a status"
Assert-Contains $roadmap "M7j2b live post-release GitHub artifact attestation evidence gate" "roadmap M7j2b status"
Assert-Contains $roadmap "M7j3 installed VSIX Source Control UI E2E gate" "roadmap M7j3 status"
Assert-Contains $roadmap "M7k1 public support intake and redaction preflight gate" "roadmap M7k1 status"
Assert-Contains $roadmap "M7k2a Marketplace listing metadata and icon preflight" "roadmap M7k2a status"
Assert-Contains $roadmap "M7k2b publication gaps and publish-auth contract preflight" "roadmap M7k2b status"
Assert-Contains $roadmap "M7l1 vulnerability review input-contract preflight" "roadmap M7l1 status"
Assert-Contains $roadmap "M7l2a live OSV vulnerability review evidence gate" "roadmap M7l2a status"
Assert-Contains $roadmap "M7l2b native advisory review evidence gate" "roadmap M7l2b status"
Assert-Contains $roadmap "M7l2c native advisory triage input-contract gate" "roadmap M7l2c status"
Assert-Contains $roadmap "M7l2d vulnerability decision evidence gate" "roadmap M7l2d status"
Assert-Contains $roadmap "M7l2e vulnerability decision input terminal-progress gate" "roadmap M7l2e status"
Assert-Contains $roadmap "M7l2f manual native advisory terminal-review gate" "roadmap M7l2f status"
Assert-Contains $roadmap "M7l2g Expat terminal CVE-2026-45186 decision gate" "roadmap M7l2g status"
Assert-Contains $roadmap "M7l2h zlib terminal CVE-2026-22184 decision gate" "roadmap M7l2h status"
Assert-Contains $roadmap "M7l2i APR terminal CVE decision gate" "roadmap M7l2i status"
Assert-Contains $roadmap "M7l2j APR-util terminal CVE decision gate" "roadmap M7l2j status"
Assert-Contains $roadmap "M7l2k Serf terminal CVE-2014-3504 decision gate" "roadmap M7l2k status"
Assert-Contains $roadmap "M7l2l APR-iconv named security finding decision gate" "roadmap M7l2l status"
Assert-Contains $roadmap "M7l3 native artifact map preflight gate" "roadmap M7l3 status"
Assert-Contains $roadmap "M7l4 malicious input corpus preflight" "roadmap M7l4 status"
Assert-Contains $roadmap "M7l5 native malicious DAV/XML fixture" "roadmap M7l5 status"
Assert-Contains $roadmap "M7l6 native malicious ``svn://`` server-response fixture" "roadmap M7l6 status"
Assert-Contains $roadmap "M7l7 native remote-protocol fuzz readiness contract" "roadmap M7l7 status"
Assert-Contains $roadmap "M7l8 native remote-protocol fuzz target source preflight" "roadmap M7l8 status"
Assert-Contains $roadmap "M7l9 native remote-protocol fixed seed harness smoke" "roadmap M7l9 status"
Assert-Contains $m6ToM7Decision "docs/release/m7-release-readiness-gates.md" "M6-to-M7 release gate linkage"
Assert-Contains $m6ToM7Decision "docs/release/security-evidence-matrix.md" "M6-to-M7 evidence matrix linkage"
Assert-Contains $m6ToM7Decision "docs/release/public-claim-matrix.md" "M6-to-M7 public claim matrix linkage"

Write-Host "Release readiness checks passed."

<#
.SYNOPSIS
Maintainer-side gate: cross-check the public release evidence CSV against the
requirements catalog in the private planning archive.

.DESCRIPTION
Since the public cutover the requirements catalog (requirements.csv) lives in
the private planning archive and is not part of the public repository. The
public readiness smoke gate verifies the release evidence CSV's own integrity;
this script performs the catalog alignment (P0/P1 coverage, priority and
approval-status mirroring) and must be run by a maintainer with access to the
archive before release approval.

.EXAMPLE
pwsh -NoProfile -File scripts/release/verify-requirement-catalog-alignment.ps1 `
  -RequirementsCatalogPath F:\Archive\SubversionR-private\Reference\requirements.csv
#>
param(
  [Parameter(Mandatory = $true)]
  [string]$RequirementsCatalogPath,

  [string]$RequirementsEvidencePath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).ProviderPath

Import-Module (Join-Path $PSScriptRoot "lib\ReadinessModel.psm1")
Import-Module (Join-Path $PSScriptRoot "lib\ReadinessRules.psm1")

if (-not (Test-Path -LiteralPath $RequirementsCatalogPath -PathType Leaf)) {
  throw "Requirements catalog not found at '$RequirementsCatalogPath'. This gate requires access to the private planning archive."
}

$requirementsCatalog = Read-RequiredCsv -RepoRoot $repoRoot -RelativePath "requirements.csv (archive)" -Path $RequirementsCatalogPath
$requirementsEvidence = Read-RequiredCsv -RepoRoot $repoRoot -RelativePath "docs/release/requirements-release-evidence.csv" -Path $RequirementsEvidencePath

Assert-RequirementReleaseEvidenceIntegrity $requirementsEvidence
Assert-RequirementReleaseEvidenceCoverage $requirementsCatalog $requirementsEvidence

# These archive bindings are release requirements, not public-repository
# existence checks. Keep them explicit here so removing or retargeting a
# private source cannot silently weaken catalog alignment.
$requiredArchiveEvidenceRefs = [ordered]@{
  "SYN-001" = @("Reference/requirements.csv")
  "SYN-003" = @("Reference/requirements.csv")
  "SYN-004" = @("Reference/requirements.csv")
  "SYN-005" = @("Reference/requirements.csv")
  "PRD-004" = @("Reference/12_TortoiseSVN_Integration.md")
  "TOR-001" = @("Reference/12_TortoiseSVN_Integration.md")
  "TOR-002" = @("Reference/12_TortoiseSVN_Integration.md")
  "PRD-014" = @(
    "Reference/01_Project_Charter_and_Scope.md",
    "Reference/05_System_Architecture.md",
    "Reference/18_Governance_Decisions_and_Glossary.md"
  )
  "REP-005" = @("Reference/requirements.csv")
  "REP-006" = @("Reference/requirements.csv")
  "REP-007" = @("Reference/requirements.csv")
  "REP-008" = @("Reference/requirements.csv")
  "UX-007" = @("Reference/02_Product_Requirements_and_UX.md", "Reference/requirements.csv")
  "UX-002" = @("Reference/02_Product_Requirements_and_UX.md", "Reference/requirements.csv")
  "UX-001" = @("Reference/02_Product_Requirements_and_UX.md", "Reference/requirements.csv")
  "DIF-002" = @("Reference/command_catalog.csv", "Reference/legacy_migration.csv")
  "HIS-008" = @("Reference/command_catalog.csv")
  "HIS-001" = @("Reference/11_SVN_Lens_History_and_Diff.md")
  "HIS-002" = @("Reference/11_SVN_Lens_History_and_Diff.md", "Reference/command_catalog.csv")
  "HIS-003" = @("Reference/11_SVN_Lens_History_and_Diff.md")
  "HIS-004" = @("Reference/11_SVN_Lens_History_and_Diff.md")
  "HIS-005" = @("Reference/11_SVN_Lens_History_and_Diff.md")
  "HIS-007" = @("Reference/11_SVN_Lens_History_and_Diff.md")
  "HIS-006" = @("Reference/11_SVN_Lens_History_and_Diff.md")
  "DIF-003" = @("Reference/command_catalog.csv", "Reference/legacy_migration.csv")
  "DIF-004" = @("Reference/command_catalog.csv", "Reference/legacy_migration.csv")
  "HIS-010" = @("Reference/command_catalog.csv", "Reference/legacy_migration.csv")
  "STA-010" = @("Reference/02_Product_Requirements_and_UX.md", "Reference/03_Functional_Specification.md")
}
foreach ($requirementId in $requiredArchiveEvidenceRefs.Keys) {
  Assert-RequirementEvidenceRefs $requirementsEvidence $requirementId $requiredArchiveEvidenceRefs[$requirementId]
}

# Archive refs (Reference/...) are skipped by the public existence check in
# Assert-RequirementEvidenceRefsResolve; verify them here against the archive.
$archiveRoot = Split-Path -Parent (Split-Path -Parent (Resolve-Path -LiteralPath $RequirementsCatalogPath).ProviderPath)
$archiveRefCount = 0
foreach ($evidence in $requirementsEvidence.Rows) {
  if ($evidence.release_evidence_status -notin @("partial", "verified")) {
    continue
  }
  foreach ($rawEvidenceRef in ($evidence.evidence_refs -split ";")) {
    $evidenceRef = $rawEvidenceRef.Trim()
    if ($evidenceRef -notmatch '^Reference[/\\]') {
      continue
    }
    $archivePath = Join-Path $archiveRoot $evidenceRef
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
      throw "docs/release/requirements-release-evidence.csv: '$($evidence.id)' archive evidence ref does not exist under '$archiveRoot': '$evidenceRef'."
    }
    $archiveRefCount++
  }
}

Write-Host "Requirement catalog alignment passed: $($requirementsEvidence.Rows.Count) evidence rows verified against the archived catalog ($archiveRefCount archive refs resolved)."

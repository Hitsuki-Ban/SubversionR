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

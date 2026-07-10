$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "ReadinessModel.psm1")

function Assert-RequirementReleaseEvidenceCoverage([object]$RequirementsCsv, [object]$EvidenceCsv) {
  Assert-RequiredCsvColumns $RequirementsCsv @("id", "priority", "status")
  Assert-RequiredCsvColumns $EvidenceCsv @(
    "id",
    "priority",
    "requirement_status",
    "release_evidence_status",
    "evidence_refs",
    "exception_ref",
    "blocker_reason"
  )

  $requirementsById = @{}
  foreach ($requirement in $RequirementsCsv.Rows) {
    if ($requirement.priority -notin @("P0", "P1")) {
      continue
    }
    if ([string]::IsNullOrWhiteSpace($requirement.id)) {
      throw "$($RequirementsCsv.RelativePath): P0/P1 requirement has an empty id."
    }
    if ($requirementsById.ContainsKey($requirement.id)) {
      throw "$($RequirementsCsv.RelativePath): duplicate P0/P1 requirement id '$($requirement.id)'."
    }
    $requirementsById[$requirement.id] = $requirement
  }
  if ($requirementsById.Count -eq 0) {
    throw "$($RequirementsCsv.RelativePath): no P0/P1 requirements were found."
  }

  $allowedEvidenceStatuses = @("blocked", "partial", "verified", "exception")
  $evidenceById = @{}
  foreach ($evidence in $EvidenceCsv.Rows) {
    if ([string]::IsNullOrWhiteSpace($evidence.id)) {
      throw "$($EvidenceCsv.RelativePath): evidence row has an empty id."
    }
    if ($evidenceById.ContainsKey($evidence.id)) {
      throw "$($EvidenceCsv.RelativePath): duplicate evidence row for '$($evidence.id)'."
    }
    if (-not $requirementsById.ContainsKey($evidence.id)) {
      throw "$($EvidenceCsv.RelativePath): evidence row '$($evidence.id)' does not match a P0/P1 requirement."
    }

    $requirement = $requirementsById[$evidence.id]
    if ($evidence.priority -ne $requirement.priority) {
      throw "$($EvidenceCsv.RelativePath): '$($evidence.id)' priority must be '$($requirement.priority)', got '$($evidence.priority)'."
    }
    if ($evidence.requirement_status -ne $requirement.status) {
      throw "$($EvidenceCsv.RelativePath): '$($evidence.id)' requirement_status must mirror '$($requirement.status)', got '$($evidence.requirement_status)'."
    }
    if ($allowedEvidenceStatuses -notcontains $evidence.release_evidence_status) {
      throw "$($EvidenceCsv.RelativePath): '$($evidence.id)' has unsupported release_evidence_status '$($evidence.release_evidence_status)'."
    }
    if (
      $evidence.release_evidence_status -eq "blocked" -and
      ([string]::IsNullOrWhiteSpace($evidence.blocker_reason) -or $evidence.blocker_reason -eq "none")
    ) {
      throw "$($EvidenceCsv.RelativePath): blocked row '$($evidence.id)' must record blocker_reason."
    }
    if (
      $evidence.release_evidence_status -eq "exception" -and
      ([string]::IsNullOrWhiteSpace($evidence.exception_ref) -or $evidence.exception_ref -eq "none")
    ) {
      throw "$($EvidenceCsv.RelativePath): exception row '$($evidence.id)' must record exception_ref."
    }
    if (
      $evidence.release_evidence_status -in @("partial", "verified") -and
      ([string]::IsNullOrWhiteSpace($evidence.evidence_refs) -or $evidence.evidence_refs -eq "none")
    ) {
      throw "$($EvidenceCsv.RelativePath): '$($evidence.id)' must record evidence_refs before it can be partial or verified."
    }

    $evidenceById[$evidence.id] = $evidence
  }

  foreach ($requirementId in $requirementsById.Keys) {
    if (-not $evidenceById.ContainsKey($requirementId)) {
      throw "$($EvidenceCsv.RelativePath): missing release evidence row for P0/P1 requirement '$requirementId'."
    }
  }
}

function Assert-EvidenceRefHasNoReparsePointSegments(
  [Parameter(Mandatory = $true)]
  [string]$RepoRoot,
  [object]$EvidenceCsv,
  [object]$Evidence,
  [string]$EvidenceRef
) {
  $repoRootPath = Resolve-ReadinessRepoRoot $RepoRoot
  $currentPath = $repoRootPath
  foreach ($pathSegment in @($EvidenceRef -split "[/\\]" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    $currentPath = Join-Path $currentPath $pathSegment
    $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "$($EvidenceCsv.RelativePath): '$($Evidence.id)' evidence ref must not traverse a reparse point: '$EvidenceRef'."
    }
  }
}

function Assert-RequirementEvidenceRefsResolve(
  [object]$EvidenceCsv,

  [Parameter(Mandatory = $true)]
  [string]$RepoRoot
) {
  $repoRootPath = Get-NormalizedFullPath (Resolve-ReadinessRepoRoot $RepoRoot)
  $repoRootPrefix = "$repoRootPath$([System.IO.Path]::DirectorySeparatorChar)"

  foreach ($evidence in $EvidenceCsv.Rows) {
    if ($evidence.release_evidence_status -notin @("partial", "verified")) {
      continue
    }

    foreach ($rawEvidenceRef in ($evidence.evidence_refs -split ";")) {
      $evidenceRef = $rawEvidenceRef.Trim()
      if ([string]::IsNullOrWhiteSpace($evidenceRef)) {
        throw "$($EvidenceCsv.RelativePath): '$($evidence.id)' has an empty evidence ref."
      }

      if (
        [System.IO.Path]::IsPathRooted($evidenceRef) -or
        $evidenceRef -match "^[A-Za-z]:" -or
        $evidenceRef -match "^[/\\]"
      ) {
        throw "$($EvidenceCsv.RelativePath): '$($evidence.id)' evidence ref must be repo-relative: '$evidenceRef'."
      }

      $pathSegments = @($evidenceRef -split "[/\\]")
      if ($pathSegments -contains "..") {
        throw "$($EvidenceCsv.RelativePath): '$($evidence.id)' evidence ref must be repo-relative without parent segments: '$evidenceRef'."
      }

      $candidatePath = Join-Path $repoRootPath $evidenceRef
      if (
        -not (Test-Path -LiteralPath $candidatePath -PathType Leaf) -and
        -not (Test-Path -LiteralPath $candidatePath -PathType Container)
      ) {
        throw "$($EvidenceCsv.RelativePath): '$($evidence.id)' evidence ref does not exist: '$evidenceRef'."
      }

      Assert-EvidenceRefHasNoReparsePointSegments -RepoRoot $repoRootPath -EvidenceCsv $EvidenceCsv -Evidence $evidence -EvidenceRef $evidenceRef

      $resolvedPath = Get-NormalizedFullPath (Resolve-Path -LiteralPath $candidatePath).ProviderPath
      if (
        -not $resolvedPath.Equals($repoRootPath, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $resolvedPath.StartsWith($repoRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
      ) {
        throw "$($EvidenceCsv.RelativePath): '$($evidence.id)' evidence ref resolves outside the repository: '$evidenceRef'."
      }
    }
  }
}

function Assert-RequirementEvidenceStatus([object]$EvidenceCsv, [string]$Id, [string]$ExpectedStatus) {
  $row = Get-RequirementEvidenceRow $EvidenceCsv $Id
  if ($row.release_evidence_status -ne $ExpectedStatus) {
    throw "$($EvidenceCsv.RelativePath): '$Id' must have release_evidence_status '$ExpectedStatus', got '$($row.release_evidence_status)'."
  }
  if ($ExpectedStatus -eq "verified" -and $row.blocker_reason -ne "none") {
    throw "$($EvidenceCsv.RelativePath): verified row '$Id' must record blocker_reason 'none', got '$($row.blocker_reason)'."
  }
}

function Assert-RequirementEvidenceRefs([object]$EvidenceCsv, [string]$Id, [string[]]$ExpectedRefs) {
  $row = Get-RequirementEvidenceRow $EvidenceCsv $Id
  $evidenceRefs = Get-RequirementEvidenceRefTokens $row
  foreach ($expectedRef in $ExpectedRefs) {
    if ($evidenceRefs -notcontains $expectedRef) {
      throw "$($EvidenceCsv.RelativePath): '$Id' evidence_refs must include '$expectedRef'."
    }
  }
}

Export-ModuleMember -Function `
  Assert-RequirementReleaseEvidenceCoverage, `
  Assert-EvidenceRefHasNoReparsePointSegments, `
  Assert-RequirementEvidenceRefsResolve, `
  Assert-RequirementEvidenceStatus, `
  Assert-RequirementEvidenceRefs

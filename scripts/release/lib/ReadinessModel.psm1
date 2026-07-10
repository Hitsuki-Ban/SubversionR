$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-ReadinessRepoRoot([string]$RepoRoot) {
  if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    throw "RepoRoot is required."
  }

  $resolved = Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop
  if (-not (Test-Path -LiteralPath $resolved.ProviderPath -PathType Container)) {
    throw "RepoRoot must be a directory: $RepoRoot"
  }

  $resolved.ProviderPath
}

function Read-RequiredCsv(
  [Parameter(Mandatory = $true)]
  [string]$RepoRoot,

  [Parameter(Mandatory = $true)]
  [string]$RelativePath,

  [string]$Path
) {
  $repoRootPath = Resolve-ReadinessRepoRoot $RepoRoot
  $pathToRead = if ([string]::IsNullOrWhiteSpace($Path)) { $RelativePath } else { $Path }
  $absolutePath = if ([System.IO.Path]::IsPathRooted($pathToRead)) {
    [System.IO.Path]::GetFullPath($pathToRead)
  }
  else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRootPath $pathToRead))
  }

  if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
    throw "Missing required release-readiness CSV: $RelativePath"
  }

  $rows = @(Import-Csv -LiteralPath $absolutePath)
  if ($rows.Count -eq 0) {
    throw "Required release-readiness CSV is empty: $RelativePath"
  }

  [pscustomobject]@{
    RelativePath = $RelativePath
    Rows = $rows
  }
}

function New-ReadinessCsvModel([string]$RelativePath, [object[]]$Rows) {
  if ([string]::IsNullOrWhiteSpace($RelativePath)) {
    throw "RelativePath is required."
  }
  if ($null -eq $Rows -or $Rows.Count -eq 0) {
    throw "Rows are required for $RelativePath."
  }

  [pscustomobject]@{
    RelativePath = $RelativePath
    Rows = @($Rows)
  }
}

function Copy-ReadinessCsvRows([object[]]$Rows) {
  @(
    foreach ($row in $Rows) {
      $copy = [ordered]@{}
      foreach ($property in $row.PSObject.Properties) {
        $copy[$property.Name] = [string]$property.Value
      }
      [pscustomobject]$copy
    }
  )
}

function Assert-RequiredCsvColumns([object]$Csv, [string[]]$Columns) {
  $properties = @($Csv.Rows[0].PSObject.Properties.Name)
  foreach ($column in $Columns) {
    if ($properties -notcontains $column) {
      throw "$($Csv.RelativePath): missing required column '$column'."
    }
  }
}

function Get-NormalizedFullPath([string]$Path) {
  [System.IO.Path]::GetFullPath($Path).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  )
}

function Get-RequirementEvidenceRefTokens([object]$Evidence) {
  @($Evidence.evidence_refs -split ";" | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-RequirementEvidenceRow([object]$EvidenceCsv, [string]$Id) {
  $rows = @($EvidenceCsv.Rows | Where-Object { $_.id -eq $Id })
  if ($rows.Count -ne 1) {
    throw "$($EvidenceCsv.RelativePath): expected exactly one release evidence row for '$Id', got $($rows.Count)."
  }

  $rows[0]
}

Export-ModuleMember -Function `
  Resolve-ReadinessRepoRoot, `
  Read-RequiredCsv, `
  New-ReadinessCsvModel, `
  Copy-ReadinessCsvRows, `
  Assert-RequiredCsvColumns, `
  Get-NormalizedFullPath, `
  Get-RequirementEvidenceRefTokens, `
  Get-RequirementEvidenceRow

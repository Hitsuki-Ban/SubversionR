$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).ProviderPath
$stageScript = Join-Path $repoRoot "scripts\release\stage-vscode-package-layout.ps1"
$verifyLayoutScript = Join-Path $repoRoot "scripts\release\verify-vscode-package-layout.ps1"
$verifyReadinessScript = Join-Path $repoRoot "scripts\release\verify-readiness.ps1"
$verifyRequirementCatalogAlignmentScript = Join-Path $repoRoot "scripts\release\verify-requirement-catalog-alignment.ps1"
$requirementsEvidencePath = Join-Path $repoRoot "docs\release\requirements-release-evidence.csv"
$deleteUnversionedTrashPolicyPath = Join-Path $repoRoot "docs\release\delete-unversioned-trash-policy.md"
$packageJsonPath = Join-Path $repoRoot "package.json"
$ciWorkflowPath = Join-Path $repoRoot ".github\workflows\ci.yml"
$prFastWorkflowPath = Join-Path $repoRoot ".github\workflows\pr-fast.yml"
$githubActionsRestorationPath = Join-Path $repoRoot "docs\ci\github-actions-restoration.md"
$roadmapPath = Join-Path $repoRoot "docs\roadmap\README.md"
$engineeringHandoffPath = Join-Path $repoRoot "docs\onboarding\ENGINEERING_HANDOFF.md"
$adrIndexPath = Join-Path $repoRoot "docs\adr\README.md"
$stableVsCodeApiAdrPath = Join-Path $repoRoot "docs\adr\ADR-008-stable-vscode-apis.md"
$credentialStorageAdrPath = Join-Path $repoRoot "docs\adr\ADR-010-credential-storage.md"
$architectureDecisionPaths = @(
  "docs\adr\ADR-001-typescript-rust-libsvn-architecture.md",
  "docs\adr\ADR-002-stdio-rpc-transport.md",
  "docs\adr\ADR-003-bundled-libsvn-runtime.md",
  "docs\adr\ADR-004-working-copy-database-integrity.md",
  "docs\adr\ADR-005-dirty-path-status-refresh.md",
  "docs\adr\ADR-006-local-and-remote-status-scheduling.md",
  "docs\adr\ADR-007-sidecar-process-lifetime.md",
  "docs\adr\ADR-008-stable-vscode-apis.md",
  "docs\adr\ADR-009-optional-tortoisesvn-adapter.md",
  "docs\adr\ADR-010-credential-storage.md",
  "docs\adr\ADR-011-cache-source-of-truth.md",
  "docs\adr\ADR-012-svn-terminology.md"
)

Import-Module (Join-Path $repoRoot "scripts\release\lib\ReadinessModel.psm1") -Force -Global
Import-Module (Join-Path $repoRoot "scripts\release\lib\ReadinessRules.psm1") -Force -Global

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw $Message
  }
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
  if ($Expected -ne $Actual) {
    throw "$Message Expected '$Expected', got '$Actual'."
  }
}

function Assert-ThrowsContaining([scriptblock]$Action, [string]$ExpectedText, [string]$Message) {
  $errorMessage = $null
  try {
    & $Action
  }
  catch {
    $errorMessage = $_.Exception.Message
  }

  Assert-True ($null -ne $errorMessage) "$Message Expected command to throw."
  Assert-True ($errorMessage.Contains($ExpectedText)) "$Message Expected error to contain '$ExpectedText', got '$errorMessage'."
}

function Assert-NativeCommandFailsContaining([scriptblock]$Action, [string]$ExpectedText, [string]$Message) {
  $output = & $Action 2>&1
  $exitCode = $LASTEXITCODE
  Assert-True ($exitCode -ne 0) "$Message Expected native command to fail."
  $text = $output | Out-String
  Assert-True ($text.Contains($ExpectedText)) "$Message Expected output to contain '$ExpectedText', got '$text'."
}

function Assert-NativeCommandSucceedsContaining([scriptblock]$Action, [string]$ExpectedText, [string]$Message) {
  $output = & $Action 2>&1
  $exitCode = $LASTEXITCODE
  Assert-True ($exitCode -eq 0) "$Message Expected native command to succeed, got exit code $exitCode."
  $text = $output | Out-String
  Assert-True ($text.Contains($ExpectedText)) "$Message Expected output to contain '$ExpectedText', got '$text'."
}

function Assert-ContainsInOrder([string]$Text, [string[]]$Needles, [string]$Message) {
  $previousIndex = -1
  foreach ($needle in $Needles) {
    $currentIndex = $Text.IndexOf($needle, [System.StringComparison]::Ordinal)
    Assert-True ($currentIndex -ge 0) "$Message Missing '$needle'."
    Assert-True ($currentIndex -gt $previousIndex) "$Message '$needle' should appear after the previous checked step."
    $previousIndex = $currentIndex
  }
}

function Assert-TextFileContainsTokens([string]$Path, [string[]]$Tokens, [string]$Message) {
  Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "$Message File is missing: $Path"
  $text = Get-Content -Raw -LiteralPath $Path
  foreach ($token in $Tokens) {
    Assert-True ($text.Contains($token)) "$Message Missing '$token'."
  }
}

function Assert-TextFileMatches([string]$Path, [string]$Pattern, [string]$Message) {
  Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "$Message File is missing: $Path"
  $text = Get-Content -Raw -LiteralPath $Path
  Assert-True ($text -match $Pattern) $Message
}

function Assert-ReleaseScriptTestsDoNotMutateSourceControlledFixtures() {
  $scriptText = Get-Content -Raw -LiteralPath $PSCommandPath
  $forbiddenTokens = @(
    ("Write-" + "RequirementsEvidenceRows"),
    ("Restore-TextFile -Path `$" + "requirementsEvidencePath"),
    ("scripts/verify-support-intake.ps1" + ".extra"),
    ("scripts\verify-support-intake.ps1" + ".extra")
  )

  foreach ($token in $forbiddenTokens) {
    Assert-True (-not $scriptText.Contains($token)) "Release script tests must not mutate source-controlled fixtures or create source-tree temporary evidence: $token"
  }
}

function New-RequirementsEvidenceFixture() {
  $evidence = Read-RequiredCsv -RepoRoot $repoRoot -RelativePath "docs/release/requirements-release-evidence.csv"
  New-ReadinessCsvModel -RelativePath $evidence.RelativePath -Rows (Copy-ReadinessCsvRows $evidence.Rows)
}

function New-RequirementsCatalogFixture() {
  New-ReadinessCsvModel -RelativePath "synthetic/requirements.csv" -Rows @(
    [pscustomobject][ordered]@{
      id = "SYNTHETIC-001"
      priority = "P0"
      status = "Approved"
    }
  )
}

function New-RequirementsCoverageEvidenceFixture() {
  New-ReadinessCsvModel -RelativePath "synthetic/requirements-release-evidence.csv" -Rows @(
    [pscustomobject][ordered]@{
      id = "SYNTHETIC-001"
      priority = "P0"
      requirement_status = "Approved"
      release_evidence_status = "blocked"
      evidence_refs = "none"
      exception_ref = "none"
      blocker_reason = "synthetic-release-blocker"
    }
  )
}

function Assert-RequirementCoverageUsesSyntheticFixtures() {
  $requirements = New-RequirementsCatalogFixture
  $evidence = New-RequirementsCoverageEvidenceFixture
  Assert-RequirementReleaseEvidenceCoverage -RequirementsCsv $requirements -EvidenceCsv $evidence

  $evidence.Rows[0].priority = "P1"
  Assert-ThrowsContaining {
    Assert-RequirementReleaseEvidenceCoverage -RequirementsCsv $requirements -EvidenceCsv $evidence
  } "priority must be 'P0'" "Synthetic requirement coverage should reject catalog/evidence priority drift."
}

function Assert-RequirementCatalogAlignmentUsesSyntheticArchive([string]$TempRoot) {
  $fixtureRoot = Join-Path $TempRoot "catalog-alignment"
  $archiveRoot = Join-Path $fixtureRoot "archive"
  $referenceRoot = Join-Path $archiveRoot "Reference"
  $catalogPath = Join-Path $referenceRoot "requirements.csv"
  $evidencePath = Join-Path $fixtureRoot "requirements-release-evidence.csv"
  New-Item -ItemType Directory -Force -Path $referenceRoot | Out-Null

  $sourceEvidence = New-RequirementsEvidenceFixture
  $catalogRows = @(
    foreach ($row in $sourceEvidence.Rows) {
      [pscustomobject][ordered]@{
        id = [string]$row.id
        priority = [string]$row.priority
        status = [string]$row.requirement_status
      }
    }
  )
  $catalogRows | Export-Csv -LiteralPath $catalogPath -NoTypeInformation
  $sourceEvidence.Rows | Export-Csv -LiteralPath $evidencePath -NoTypeInformation

  $archiveRefs = @(
    $sourceEvidence.Rows |
      ForEach-Object { Get-RequirementEvidenceRefTokens $_ } |
      Where-Object { $_ -match '^Reference[/\\]' } |
      Sort-Object -Unique
  )
  foreach ($archiveRef in $archiveRefs) {
    if ($archiveRef -eq "Reference/requirements.csv") {
      continue
    }
    $archivePath = Join-Path $archiveRoot $archiveRef
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $archivePath) | Out-Null
    Set-Content -LiteralPath $archivePath -Value "synthetic private archive evidence" -NoNewline
  }

  Assert-NativeCommandSucceedsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyRequirementCatalogAlignmentScript `
      -RequirementsCatalogPath $catalogPath `
      -RequirementsEvidencePath $evidencePath
  } "Requirement catalog alignment passed:" "Catalog alignment should accept complete synthetic archive fixtures."

  $missingBindingRows = Copy-ReadinessCsvRows $sourceEvidence.Rows
  $missingBindingRow = @($missingBindingRows | Where-Object { $_.id -eq "SYN-001" })[0]
  $missingBindingRow.evidence_refs = @(
    Get-RequirementEvidenceRefTokens $missingBindingRow |
      Where-Object { $_ -ne "Reference/requirements.csv" }
  ) -join "; "
  $missingBindingRows | Export-Csv -LiteralPath $evidencePath -NoTypeInformation
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyRequirementCatalogAlignmentScript `
      -RequirementsCatalogPath $catalogPath `
      -RequirementsEvidencePath $evidencePath
  } "'SYN-001' evidence_refs must include 'Reference/requirements.csv'" "Catalog alignment should reject a missing explicit private archive binding."

  $sourceEvidence.Rows | Export-Csv -LiteralPath $evidencePath -NoTypeInformation
  $missingArchivePath = Join-Path $archiveRoot "Reference/12_TortoiseSVN_Integration.md"
  Remove-Item -LiteralPath $missingArchivePath -Force
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyRequirementCatalogAlignmentScript `
      -RequirementsCatalogPath $catalogPath `
      -RequirementsEvidencePath $evidencePath
  } "archive evidence ref does not exist" "Catalog alignment should reject a missing private archive file."
  Set-Content -LiteralPath $missingArchivePath -Value "synthetic private archive evidence" -NoNewline

  $driftedCatalogRows = Copy-ReadinessCsvRows $catalogRows
  $driftedCatalogRow = @($driftedCatalogRows | Where-Object { $_.id -eq "PRD-002" })[0]
  $driftedCatalogRow.priority = "P1"
  $driftedCatalogRows | Export-Csv -LiteralPath $catalogPath -NoTypeInformation
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyRequirementCatalogAlignmentScript `
      -RequirementsCatalogPath $catalogPath `
      -RequirementsEvidencePath $evidencePath
  } "'PRD-002' priority must be 'P1', got 'P0'" "Catalog alignment should reject catalog/evidence priority drift."
}

function Replace-RequirementsEvidenceRef([object]$EvidenceCsv, [string]$ExistingRef, [string]$ReplacementRef) {
  $changed = $false
  foreach ($row in $EvidenceCsv.Rows) {
    if ([string]$row.evidence_refs -like "*$ExistingRef*") {
      $row.evidence_refs = ([string]$row.evidence_refs).Replace($ExistingRef, $ReplacementRef)
      $changed = $true
    }
  }
  Assert-True $changed "Release evidence fixture should contain the tamper target ref."
}

function Assert-ReleaseReadinessRejectsTamperedEvidenceRef([string]$ReplacementRef, [string]$ExpectedText, [string]$Message) {
  $existingEvidenceRef = "packages/vscode-extension/src/diagnostics/diagnosticsRedaction.ts"
  $evidence = New-RequirementsEvidenceFixture
  Replace-RequirementsEvidenceRef -EvidenceCsv $evidence -ExistingRef $existingEvidenceRef -ReplacementRef $ReplacementRef

  Assert-ThrowsContaining {
    Assert-RequirementEvidenceRefsResolve -EvidenceCsv $evidence -RepoRoot $repoRoot
  } $ExpectedText $Message
}

function Assert-ReleaseReadinessRejectsRequirementEvidenceStatus(
  [string]$RequirementId,
  [string]$ReplacementStatus,
  [string]$ReplacementBlockerReason,
  [string]$ExpectedText,
  [string]$Message
) {
  $evidence = New-RequirementsEvidenceFixture
  $row = Get-RequirementEvidenceRow $evidence $RequirementId
  $expectedStatus = $row.release_evidence_status
  $row.release_evidence_status = $ReplacementStatus
  $row.blocker_reason = $ReplacementBlockerReason

  Assert-ThrowsContaining {
    Assert-RequirementEvidenceStatus -EvidenceCsv $evidence -Id $RequirementId -ExpectedStatus $expectedStatus
  } $ExpectedText $Message
}

function Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef(
  [string]$RequirementId,
  [string]$EvidenceRef,
  [string]$ExpectedText,
  [string]$Message
) {
  $evidence = New-RequirementsEvidenceFixture
  $row = Get-RequirementEvidenceRow $evidence $RequirementId
  $refs = Get-RequirementEvidenceRefTokens $row
  Assert-True ($refs -contains $EvidenceRef) "Release evidence fixture should contain $EvidenceRef for $RequirementId."
  $remainingRefs = @($refs | Where-Object { $_ -ne $EvidenceRef })
  $row.evidence_refs = $remainingRefs -join "; "

  Assert-ThrowsContaining {
    Assert-RequirementEvidenceRefs -EvidenceCsv $evidence -Id $RequirementId -ExpectedRefs @($EvidenceRef)
  } $ExpectedText $Message
}

function Convert-ToRepoRelativePath([string]$Path) {
  $repoRootPath = [System.IO.Path]::GetFullPath($repoRoot).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  )
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $repoPrefix = "$repoRootPath$([System.IO.Path]::DirectorySeparatorChar)"
  Assert-True ($fullPath.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) "Test fixture path must live under the repository: $Path"

  $fullPath.Substring($repoPrefix.Length).Replace("\", "/")
}

function Assert-ReleaseReadinessRejectsSubstringOnlyEvidenceRef() {
  $expectedEvidenceRef = "scripts/verify-support-intake.ps1"
  $substringEvidenceRef = "scripts/verify-support-intake.ps1" + ".extra"
  $evidence = New-RequirementsEvidenceFixture
  $row = Get-RequirementEvidenceRow $evidence "SEC-014"
  Assert-True ((Get-RequirementEvidenceRefTokens $row) -contains $expectedEvidenceRef) "Release evidence fixture should contain the exact-match tamper target ref."
  $row.evidence_refs = ([string]$row.evidence_refs).Replace($expectedEvidenceRef, $substringEvidenceRef)

  Assert-ThrowsContaining {
    Assert-RequirementEvidenceRefs -EvidenceCsv $evidence -Id "SEC-014" -ExpectedRefs @($expectedEvidenceRef)
  } "evidence_refs must include" "Release readiness should require exact evidence ref tokens, not substring matches."
}

function Assert-ReleaseReadinessRejectsReparseEvidenceRef([string]$TempRoot) {
  $existingEvidenceRef = "packages/vscode-extension/src/diagnostics/diagnosticsRedaction.ts"
  $outsideEvidenceRoot = Join-Path ([System.IO.Path]::GetTempPath()) "subversionr-release-evidence-$([Guid]::NewGuid().ToString('N'))"
  $linkRoot = Join-Path $TempRoot "evidence-reparse-link"
  try {
    New-Item -ItemType Directory -Force -Path $outsideEvidenceRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $outsideEvidenceRoot "outside-evidence.txt") -Value "temporary release evidence reparse fixture" -NoNewline
    New-Item -ItemType Junction -Path $linkRoot -Target $outsideEvidenceRoot | Out-Null
    $replacementRef = Convert-ToRepoRelativePath (Join-Path $linkRoot "outside-evidence.txt")
    $evidence = New-RequirementsEvidenceFixture
    Replace-RequirementsEvidenceRef -EvidenceCsv $evidence -ExistingRef $existingEvidenceRef -ReplacementRef $replacementRef

    Assert-ThrowsContaining {
      Assert-RequirementEvidenceRefsResolve -EvidenceCsv $evidence -RepoRoot $repoRoot
    } "evidence ref must not traverse a reparse point" "Release readiness should reject evidence refs that traverse a junction or symlink."
  }
  finally {
    Remove-Item -LiteralPath $linkRoot -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $outsideEvidenceRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Assert-ReleaseReadinessUsesCustomRequirementsEvidencePath([string]$TempRoot) {
  $sentinelStatus = "custom-path-sentinel"
  $customEvidencePath = Join-Path $TempRoot "custom-requirements-release-evidence.csv"
  $evidence = New-RequirementsEvidenceFixture
  $row = Get-RequirementEvidenceRow $evidence "PRD-002"
  $row.release_evidence_status = $sentinelStatus
  $evidence.Rows | Export-Csv -LiteralPath $customEvidencePath -NoTypeInformation

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyReadinessScript -Mode rule -RequirementsEvidencePath $customEvidencePath
  } $sentinelStatus "verify-readiness should read the explicit requirements evidence path."
}

function Add-RetiredCloudflareBridgeFixture([string]$FixtureRoot) {
  $docPath = Join-Path $FixtureRoot "docs\ci\cloudflare-pr-fast-bridge.md"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $docPath) | Out-Null
  Set-Content -LiteralPath $docPath -Encoding utf8 -Value @'
# Retired Cloudflare PR Fast Bridge

Retirement date: `2026-07-10`.

- The final state has zero build triggers.
- The repository connection was removed.
- The account no longer has a build configuration associated with `subversionr-pr-fast`.
- The current gate is `.github/workflows/pr-fast.yml`.
- Git history preserves the exact implementation.

No Cloudflare live identifiers are recorded here.
'@
}

function Assert-ReleaseReadinessSmokeRejectsRetiredCloudflareDocTerm(
  [string]$TempRoot,
  [string]$ForbiddenContent,
  [string]$ExpectedText
) {
  $fixtureRoot = Join-Path $TempRoot "smoke-retired-cloudflare-$([Guid]::NewGuid().ToString('N'))"
  $workflowPath = Join-Path $fixtureRoot ".github\workflows\pr-fast.yml"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $workflowPath) | Out-Null
  Copy-Item -LiteralPath $prFastWorkflowPath -Destination $workflowPath
  Add-RetiredCloudflareBridgeFixture $fixtureRoot
  Add-Content -LiteralPath (Join-Path $fixtureRoot "docs\ci\cloudflare-pr-fast-bridge.md") -Encoding utf8 -Value $ForbiddenContent

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyReadinessScript -Mode smoke -RepoRoot $fixtureRoot
  } $ExpectedText "verify-readiness smoke should reject retired deployment and private infrastructure details."
}

function Assert-ReleaseReadinessSmokeRejectsHeavyPrFastGate(
  [string]$TempRoot,
  [string]$ForbiddenCommand,
  [string]$ExpectedText
) {
  $fixtureName = "smoke-heavy-pr-fast-$([Guid]::NewGuid().ToString('N'))"
  $fixtureRoot = Join-Path $TempRoot $fixtureName
  $workflowPath = Join-Path $fixtureRoot ".github\workflows\pr-fast.yml"
  $parent = Split-Path -Parent $workflowPath
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  Add-RetiredCloudflareBridgeFixture $fixtureRoot
  Set-Content -LiteralPath $workflowPath -Encoding utf8 -Value @"
name: PR Fast
on:
  pull_request:
  push:
    branches:
      - main
  workflow_dispatch:
jobs:
  windows:
    steps:
      - run: pnpm install --frozen-lockfile
      - run: pnpm check
      - run: pnpm test
      - run: pnpm release:test-state-engine-beta-performance:win32-x64
      - run: pnpm i18n:verify
      - run: pnpm docs:verify-security
      - run: pnpm docs:verify-support-intake
      - run: pnpm release:test-marketplace-publication-scripts
      - run: pnpm release:verify-readiness:smoke
      - run: pnpm release:test-native-remote-fuzz-target-preflight-scripts
      - run: pnpm release:generate-native-remote-fuzz-target-preflight:win32-x64
      - run: pnpm release:verify-native-remote-fuzz-target-preflight:win32-x64
      - run: cargo fmt --all -- --check
      - run: cargo test --workspace
      - run: pnpm native:test-scripts
      - run: $ForbiddenCommand
"@

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyReadinessScript -Mode smoke -RepoRoot $fixtureRoot
  } $ExpectedText "verify-readiness smoke should reject heavy PR Fast gates before support or evidence checks."
}

function Write-Bytes([string]$Path, [byte[]]$Bytes) {
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  [System.IO.File]::WriteAllBytes($Path, $Bytes)
}

function Write-TestPngIcon([string]$Path) {
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  Add-Type -AssemblyName System.Drawing
  $bitmap = [System.Drawing.Bitmap]::new(128, 128)
  try {
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
      $graphics.Clear([System.Drawing.Color]::FromArgb(47, 111, 115))
      $brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(245, 248, 250))
      try {
        $graphics.FillEllipse($brush, 30, 24, 68, 68)
        $graphics.FillRectangle($brush, 58, 58, 14, 42)
      }
      finally {
        $brush.Dispose()
      }
    }
    finally {
      $graphics.Dispose()
    }
    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  }
  finally {
    $bitmap.Dispose()
  }
}

function Copy-TestFile([string]$Source, [string]$Destination) {
  $parent = Split-Path -Parent $Destination
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

$svnCliTools = @(
  "svn.exe",
  "svnadmin.exe",
  "svnbench.exe",
  "svndumpfilter.exe",
  "svnfsfs.exe",
  "svnlook.exe",
  "svnmucc.exe",
  "svnrdump.exe",
  "svnserve.exe",
  "svnsync.exe",
  "svnversion.exe"
)
$requiredNativeDependencyNames = @(
  "libsvn_client-1.dll",
  "libsvn_delta-1.dll",
  "libsvn_diff-1.dll",
  "libsvn_fs-1.dll",
  "libsvn_fs_fs-1.dll",
  "libsvn_fs_util-1.dll",
  "libsvn_fs_x-1.dll",
  "libsvn_ra-1.dll",
  "libsvn_repos-1.dll",
  "libsvn_subr-1.dll",
  "libsvn_wc-1.dll",
  "libapr-1.dll",
  "libapriconv-1.dll",
  "libaprutil-1.dll",
  "libexpat.dll"
)
$opensslDependencyNames = @(
  "libcrypto-3-x64.dll",
  "libssl-3-x64.dll"
)

$tempRoot = Join-Path $repoRoot "target\tests\release-scripts\$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  Assert-ReleaseScriptTestsDoNotMutateSourceControlledFixtures
  Assert-RequirementCoverageUsesSyntheticFixtures
  Assert-RequirementCatalogAlignmentUsesSyntheticArchive $tempRoot
  Assert-True (Test-Path -LiteralPath $stageScript -PathType Leaf) "stage-vscode-package-layout.ps1 should exist."
  Assert-True (Test-Path -LiteralPath $verifyLayoutScript -PathType Leaf) "verify-vscode-package-layout.ps1 should exist."
  Assert-True (Test-Path -LiteralPath $verifyReadinessScript -PathType Leaf) "verify-readiness.ps1 should exist."
  Assert-True (Test-Path -LiteralPath $verifyRequirementCatalogAlignmentScript -PathType Leaf) "verify-requirement-catalog-alignment.ps1 should exist."
  Assert-True (Test-Path -LiteralPath $requirementsEvidencePath -PathType Leaf) "Requirements release evidence CSV should exist."
  Assert-True (Test-Path -LiteralPath $githubActionsRestorationPath -PathType Leaf) "GitHub Actions restoration note should exist."
  $verifyReadinessText = Get-Content -Raw -LiteralPath $verifyReadinessScript
  $privateArchiveDocumentRead = 'Read-RequiredDocument "Refer' + 'ence/'
  Assert-True (-not $verifyReadinessText.Contains($privateArchiveDocumentRead)) "Full release readiness must not read documents from the private Reference archive."
  $privateArchiveEvidenceMember = '  "Refer' + 'ence/'
  Assert-True (-not $verifyReadinessText.Contains($privateArchiveEvidenceMember)) "Full release readiness must not require private Reference archive members."
  Assert-TextFileContainsTokens $verifyRequirementCatalogAlignmentScript @(
    "Assert-RequirementReleaseEvidenceCoverage",
    "`$requiredArchiveEvidenceRefs",
    "Assert-RequirementEvidenceRefs",
    "archive evidence ref does not exist"
  ) "The maintainer alignment gate should own catalog coverage and explicit private archive bindings."
  Assert-TextFileContainsTokens $packageJsonPath @(
    '"release:verify-readiness:smoke"',
    "-Mode smoke"
  ) "Package scripts should expose the readiness smoke gate."
  Assert-TextFileContainsTokens $prFastWorkflowPath @(
    "pull_request:",
    "push:",
    "- main",
    "pnpm release:test-marketplace-publication-scripts",
    "pnpm release:verify-readiness:smoke",
    "pnpm release:test-state-engine-beta-performance:win32-x64"
  ) "PR Fast should use the release readiness smoke gate."
  Assert-TextFileContainsTokens $ciWorkflowPath @(
    "workflow_dispatch:",
    "schedule:",
    "cron:",
    "concurrency:"
  ) "CI should remain scheduled/manual while carrying a concurrency group."
  Assert-TextFileContainsTokens $githubActionsRestorationPath @(
    "PR Fast / windows",
    "pull_request",
    "push",
    "workflow_dispatch",
    "scheduled/manual"
  ) "GitHub Actions restoration note should document public-repo trigger design and branch-protection check naming."
  $prFastWorkflowText = Get-Content -Raw -LiteralPath $prFastWorkflowPath
  Assert-True (-not ($prFastWorkflowText -match "(?m)^\s*run:\s*pnpm release:verify-readiness\s*$")) "PR Fast must not run the full release readiness gate."
  Assert-NativeCommandSucceedsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyReadinessScript -Mode rule
  } "Release readiness rule checks passed." "verify-readiness rule mode should run only reusable readiness rules."
  Assert-NativeCommandSucceedsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyReadinessScript -Mode smoke
  } "Release readiness smoke checks passed." "verify-readiness smoke mode should run the PR-fast readiness gate."
  Assert-TextFileMatches `
    $verifyReadinessScript `
    '(?s)Assert-Terms \$roadmap @\(.+?"artifact bundle manifest".+?"explicit CI upload allowlist".+?\) "Beta-G candidate evidence roadmap coverage"' `
    "Release readiness should require roadmap Beta-G artifact bundle manifest coverage."
  Assert-TextFileContainsTokens $roadmapPath @(
    "Candidate bundle consistency",
    "artifact bundle manifest",
    "explicit CI upload allowlist",
    "subversionr-win32-x64-beta-candidate",
    "actions/upload-artifact@v7"
  ) "Roadmap should describe the Beta-G artifact bundle manifest."
  Assert-TextFileContainsTokens $engineeringHandoffPath @(
    "# SubversionR Engineering Guide",
    "Public Fact Sources",
    "docs/adr/README.md",
    "docs/roadmap/README.md",
    "docs/release/public-claim-matrix.md",
    "pnpm install --frozen-lockfile",
    "cargo test --workspace"
  ) "Public engineering guide should contain stable onboarding and architecture entry points."
  $engineeringHandoffText = Get-Content -Raw -LiteralPath $engineeringHandoffPath
  foreach ($forbiddenTerm in @(
      "Reference/",
      "Review Estimate",
      "Completion percentages",
      "PR #157",
      "Cloudflare PR Fast",
      "Windows runner coverage is unavailable"
    )) {
    Assert-True (-not $engineeringHandoffText.Contains($forbiddenTerm, [System.StringComparison]::Ordinal)) "Public engineering guide should not contain stale or private-only term '$forbiddenTerm'."
  }
  Assert-TextFileContainsTokens $adrIndexPath @(
    "## Governance",
    "ADR numbers are stable and are never reused or renumbered.",
    "requires a new ADR and product, architecture, security, and QA review",
    "each superseded record must link to its replacement",
    "ADR-001: TypeScript UI, Rust Sidecar, and libsvn",
    "ADR-008: Stable VS Code APIs",
    "ADR-012: SVN Terminology"
  ) "Public ADR index should expose the accepted architecture decisions."
  foreach ($relativePath in $architectureDecisionPaths) {
    $decisionPath = Join-Path $repoRoot $relativePath
    Assert-True (Test-Path -LiteralPath $decisionPath -PathType Leaf) "Public ADR should exist: $relativePath"
    Assert-TextFileContainsTokens $decisionPath @(
      "Status: Accepted",
      "## Context",
      "## Decision",
      "## Consequences"
    ) "Public ADR should retain the required record structure: $relativePath"
  }
  Assert-TextFileMatches `
    $verifyReadinessScript `
    '(?s)if \(\$Mode -eq "smoke"\).+?Read-AndAssertArchitectureDecisionRecords' `
    "PR Fast readiness smoke should verify all public ADR contracts."
  Assert-TextFileContainsTokens $stableVsCodeApiAdrPath @(
    "Status: Accepted",
    "Core functionality uses stable VS Code APIs and does not depend on proposed APIs.",
    "## Consequences"
  ) "Stable VS Code API ADR should record the accepted public decision."
  Assert-TextFileContainsTokens $credentialStorageAdrPath @(
    "Status: Accepted",
    "Persistent credentials are stored only in VS Code SecretStorage.",
    "credential persistence fails closed",
    "does not fall back to settings, extension caches, sidecar storage, diagnostics, or the standard SVN auth cache"
  ) "Credential storage ADR should require fail-closed SecretStorage persistence."
  Assert-ReleaseReadinessUsesCustomRequirementsEvidencePath $tempRoot
  Assert-ReleaseReadinessSmokeRejectsHeavyPrFastGate $tempRoot "pnpm release:generate-native-remote-fuzz-fixed-seed-smoke:win32-x64" "fixed-seed fuzz build/run"
  Assert-ReleaseReadinessSmokeRejectsHeavyPrFastGate $tempRoot "pnpm release:verify-live-osv-review:win32-x64" "live vulnerability review"
  Assert-ReleaseReadinessSmokeRejectsRetiredCloudflareDocTerm $tempRoot "Hitsuki-Ban/SubversionR-private" "private repository identifier"
  Assert-ReleaseReadinessSmokeRejectsRetiredCloudflareDocTerm $tempRoot "wrangler deploy --config retired.jsonc" "Wrangler deployment command"
  Assert-ReleaseReadinessSmokeRejectsRetiredCloudflareDocTerm $tempRoot "Reconnect the GitHub integration for this repository." "GitHub integration reconnection"
  Assert-ReleaseReadinessSmokeRejectsRetiredCloudflareDocTerm $tempRoot "Verify the webhook signature before relaying status." "webhook signature relay"
  Assert-TextFileContainsTokens $deleteUnversionedTrashPolicyPath @(
    "OPS-004",
    "subversionr.deleteUnversionedResource",
    "vscode.workspace.fs.delete",
    "useTrash: false",
    "This cannot be undone",
    "No trash-mode fallback"
  ) "Delete Unversioned trash policy evidence should define the release policy."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "sourceControlUiRefreshLoadWorkflow",
    "requestedModifiedItemCount",
    "projectedModifiedItemCountBefore",
    "projectedModifiedItemCountAfter",
    "allLoadResourcesProjectedAfter"
  ) "Release readiness should verify installed manual Refresh load evidence fields."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "sourceControlUiFullReconcileCancellationWorkflow",
    "fullReconcileCancellationProgressCapture",
    "subversionr.installedSourceControlUiE2eFullReconcileCancellationWorkflow",
    "userCancelled",
    "full-reconcile-cancellation-progress-capture",
    "Reconciling SVN working copy status"
  ) "Release readiness should verify installed Full Reconcile cancellation evidence fields."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "sourceControlUiDirtyGenerationCancellationLoadWorkflow",
    "subversionr.installedSourceControlUiE2eDirtyGenerationCancellationLoadWorkflow",
    "subversionr.diagnostics.installedSourceControlUiE2eArmDirtyGenerationCancellation",
    "subversionr.diagnostics.installedSourceControlUiE2eDirtyGenerationCancellationReport",
    "subversionr.diagnostics.installedSourceControlUiE2eDirtyEvent",
    "DIR-012",
    "DIR-013",
    "dirtyGenerationSuperseded",
    "postCancellationStaleCaptureAvailable",
    "completedCoverageMatchedSupersededTargets"
  ) "Release readiness should verify installed dirty-generation supersede and cancellation load evidence fields."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "UX-001 installed activation and accessibility verified evidence",
    "activationEvents",
    "not.toContain(`"*`")",
    "not.toContain(`"onStartupFinished`")",
    "beforeActive",
    "afterActive",
    "renderer accessibility tree contained required SubversionR Source Control tokens",
    "Renderer screenshot nonblank assertion should pass"
  ) "Release readiness should verify UX-001 installed on-demand activation and accessibility evidence as a verified claim."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "UX-007 installed repository picker verified evidence",
    "pickOpenRepository",
    "Select an SVN repository",
    "sourceControlUiMultiRepositoryRefreshWorkflow",
    "multiRepositoryRefreshPromptCapture",
    "quickPickSelectionRequired",
    "quickPickItemSelected",
    "accessibilityRequiredTokensPresent",
    "UX-007"
  ) "Release readiness should verify UX-007 installed repository picker and accessibility evidence as a verified claim."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "UX-002 no-repository empty-state plus installed local-file checkout happy-path, existing-directory success, existing-directory obstruction tree-conflict projection, URL prompt cancellation, obstructing-file failure, and invalid-URL failure evidence",
    "viewsWelcome",
    "view.scm.emptyState.content",
    "subversionr.openRepository",
    "subversionr.checkoutRepository",
    "Scan for SVN Working Copies",
    "Checkout Repository URL",
    "No SVN working copy was found in the workspace",
    "noRepositoryWelcomeRendererCapture",
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
  ) "Release readiness should verify UX-002 installed no-repository Scan and Checkout welcome plus local-file checkout happy-path, existing-directory success, existing-directory obstruction tree-conflict projection, URL prompt cancellation, obstructing-file failure, and invalid-URL failure evidence as a partial claim."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "partialFreshnessRendererCapture",
    "staleFreshnessRendererCapture",
    "partial-freshness-renderer-capture",
    "stale-freshness-renderer-capture",
    "SVN status partial",
    "SVN status stale"
  ) "Release readiness should verify installed stale/partial renderer capture evidence fields."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "operation_run_add_rejects_multiple_paths_to_preserve_failure_reconcile_safety",
    "operation_run_remove_accepts_multiple_paths_and_returns_targeted_reconcile_hints",
    "fails fast on invalid add request field",
    "sends operation/run remove with multiple explicit paths",
    "adds selected unversioned files and directories with SVN-appropriate depths",
    "reconciles a successful selected add before reporting a later selected add failure",
    "confirms and removes multiple selected changed SCM resources through one operation/run request",
    "confirms and reverts multiple selected changed SCM resources through one operation/run request",
    "rejects stale projection generations"
  ) "Release readiness should verify selected Add/Remove/Revert multi-selection and validation coverage."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "STA-016",
    "runCommitSelectedMultiSelectionWorkflow",
    "sourceControlUiCommitSelectedMultiSelectionWorkflow",
    "subversionr.installedSourceControlUiE2eCommitSelectedMultiSelectionWorkflow",
    "resourceStateArray",
    "Get-CommitSelectedMultiSelectionRepositoryOracle",
    "commits multiple selected changed file resources from one repository with the repository input message",
    "commitResource(...resourceStates)",
    "removeResourceKeepLocal(...resourceStates)"
  ) "Release readiness should verify SCM row multi-selection installed E2E and command-surface coverage."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "STA-005",
    "DIR-015",
    "crates/subversionr-protocol/src/lib.rs",
    "packages/vscode-extension/src/status/statusRefreshRpcClient.ts",
    "native_bridge_status_snapshot_excludes_ignored_items_by_default",
    "const svn_boolean_t no_ignore = FALSE;",
    "default status must not force ignored item discovery",
    "bridge.status_scan_with_cancellation",
    "validateRefreshTarget"
  ) "Release readiness should verify default ignored-item status evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "STA-007",
    "status_summary_counts_property_only_changes_as_local_changes",
    "status_get_snapshot_preserves_property_only_changes",
    "status_refresh_upserts_property_only_changes",
    "native_bridge_targeted_status_scan_reports_property_only_change",
    "is_actionable_local_status(&entry.property_status)"
  ) "Release readiness should verify property-only status evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "DIF-001",
    "native_bridge_content_get_returns_base_text_not_modified_working_file",
    "content_get_returns_base_content_for_open_repository",
    "provides BASE virtual document URIs for QuickDiff without scanning repository state",
    "opens a BASE diff for a selected changed SVN file using the projection canonical path",
    "registerTextDocumentContentProvider",
    "quickDiffProvider",
    "subversionr.diffWithBase",
    "subversionr.openBase",
    "packages/vscode-extension/package.nls.json",
    "packages/vscode-extension/l10n/bundle.l10n.json",
    "command.diffWithBase.title",
    "command.openBase.title",
    "Binary SVN BASE content is not displayed in the text editor."
  ) "Release readiness should verify Working-Base QuickDiff and BASE content evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "DIF-002",
    "content_get_returns_head_content_for_open_repository",
    "native_bridge_content_get_returns_head_and_explicit_revision_text",
    "HEAD_CONTENT_URI_SCHEME",
    "createHeadContentUriComponents",
    "loads HEAD content through content/get and returns readonly text",
    "opens a HEAD diff for a selected changed SVN file using a fresh request identity",
    "subversionr.diffWithHead",
    "subversionr.openHead",
    "svn.openHEADFile",
    "svn.openChangeHead",
    "command.diffWithHead.title",
    "command.openHead.title",
    "Binary SVN HEAD content is not displayed in the text editor: {0}"
  ) "Release readiness should verify Working-HEAD content and diff evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "HIS-009",
    "The eighth M5 slice exposes explicit revision content from file history revision rows",
    "historyOpenRevisionUriComponents",
    "creates revision content URI components from a file-history revision command target",
    "adds an Open Revision command to file history revision rows",
    "openRevisionTarget(element: unknown)",
    "registerTextDocumentContentProvider",
    "subversionr.history.openRevision",
    "command.history.openRevision.title",
    "Open Revision",
    "Binary SVN revision content is not displayed in the text editor: {0}@{1}"
  ) "Release readiness should verify Open Revision evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "HIS-008",
    "The tenth M5 slice adds a readonly Revision Details document for already loaded history rows",
    "HistoryRevisionDetailsDocumentStore",
    "REVISION_DETAILS_URI_SCHEME",
    "revisionDetailsTarget(element: unknown)",
    "renders loaded history metadata as a readonly revision details document",
    "creates revision details targets from current repository revision rows",
    "subversionr.history.openRevisionDetails",
    "command.history.openRevisionDetails.title",
    "Open Revision Details",
    "SVN Revision Details: {0}",
    "Copy From: {0}@r{1}"
  ) "Release readiness should verify Revision Details evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "HIS-004",
    "The eleventh M5 slice exposes file blame through a readonly VS Code document backed by the existing ``history/blame`` RPC",
    "BLAME_DOCUMENT_URI_SCHEME",
    "HistoryBlameDocumentProvider",
    "createBlameDocumentUriComponents",
    "parseBlameDocumentUri",
    "requireFixedBlameContract",
    "loads file blame through history/blame and renders a localized readonly document",
    "rejects blame document URI parameters outside the fixed M5k BASE blame contract",
    "opens file blame for a selected versioned SVN file using the projection canonical path",
    "subversionr.showBlame",
    "command.showBlame.title",
    "SVN Blame: {0}",
    "Merged from r{0}"
  ) "Release readiness should verify Blame document evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "HIS-003",
    "The twenty-sixth M5 slice adds a conservative active-editor Line History command",
    "LineHistoryCommandController",
    "selectionLineRange",
    "concreteLineRevisions",
    "opens preloaded line history for a safe active editor selection",
    "uses the current line for an empty selection and normalizes reversed selections",
    "does not show partial line history when blame rows are local, unknown, incomplete, or non-contiguous",
    "renders preloaded line history without backend pagination or file compare actions",
    "subversionr.activeEditorLineHistoryFile",
    "subversionr.showLineHistory",
    "command.showLineHistory.title",
    "Line History: {0}",
    "SubversionR line history command failed: {0}"
  ) "Release readiness should verify Line History evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "HIS-001",
    "The fifth M5 slice adds the backend-only ``history/log`` foundation on top of libsvn log semantics",
    "The seventh M5 slice turns the backend-only ``history/log`` foundation into a native VS Code history surface",
    "HistoryLogRpcClient",
    "HistoryTreeDataProvider",
    "loads repository history through bounded explicit history/log parameters",
    "opens repository history for the selected open repository",
    "history_log_returns_entries_for_open_repository",
    "history_log_response_serializes_stable_wire_fields",
    "subversionr.history.pageSize",
    "subversionr.history.includeMergedRevisions",
    "subversionr.showRepositoryLog",
    "subversionr.history.loadMore",
    "command.showRepositoryLog.title",
    "Repository: {0}",
    "Load More"
  ) "Release readiness should verify Repository Log evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "HIS-002",
    "``subversionr.showFileHistory`` opens file history only from concrete SubversionR SCM resource states for versioned local files and conflicts.",
    "``strictNodeHistory = false`` is used deliberately so default file history follows SVN copy history rather than presenting a Git-style file identity.",
    "HistoryLogChangedPath",
    "copyFromPath",
    "copyFromRevision",
    "loads file history with copy-following SVN semantics and appends older pages",
    "renders changed paths under revision entries without doing extra backend work",
    "l10n:from /branches/feature/src/copied.c@r4",
    "opens file history for a selected versioned SVN file using the projection canonical path",
    "showFileHistoryResource",
    "strictNodeHistory: false",
    "subversionr.showFileHistory",
    "command.showFileHistory.title",
    "File History",
    "from {0}@r{1}",
    "svn_client_log5"
  ) "Release readiness should verify File History evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "DIF-003",
    "historyCompareRevisionUriComponents",
    "exposes compare-with-previous targets only when a file revision has an older loaded history entry",
    "opens a PREV comparison for an SCM resource using projection generation",
    "startRevision: ``r`${changedRevision}``",
    "SVN PREV <-> Revision: {0}",
    "subversionr.history.compareWithPrevious",
    "subversionr.diffWithPrevious",
    "svn.openChangePrev",
    "subversionr.history.fileRevision.previousDiffable",
    "subversionr.activeEditorPreviousDiffable",
    "Compare PREV",
    "command.diffWithPrevious.title",
    "Binary SVN revision content is not displayed in the text editor: {0}@{1}"
  ) "Release readiness should verify PREV comparison evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "HIS-006",
    "The fifteenth M5 slice adds a projection-backed File Header CodeLens foundation for editor-visible SVN history actions",
    "The sixteenth M5 slice extends the File Header CodeLens surface with BASE and HEAD comparison actions for projected base-diffable files",
    "The eighteenth M5 slice adds a projection-backed Compare PREV command for editor-visible local SVN files",
    "FileHeaderCodeLensProvider",
    "provideCodeLenses",
    "resolveCodeLens",
    "subversionr.lens.fileHeader",
    "subversionr.lens.maxFileLines",
    "resolves file-header lenses to summary, PREV/BASE/HEAD compare, file history, blame, and repository log commands",
    "does not expose BASE/HEAD compare lenses for %s",
    "does not expose Compare PREV when the projected file has no previous revision candidate",
    "registerCodeLensProvider",
    "subversionr.showFileHistory",
    "subversionr.showBlame",
    "subversionr.showRepositoryLog",
    "subversionr.diffWithBase",
    "subversionr.diffWithHead",
    "subversionr.diffWithPrevious",
    "command.showFileHistory.title",
    "command.showBlame.title",
    "command.showRepositoryLog.title",
    "command.diffWithBase.title",
    "command.diffWithHead.title",
    "command.diffWithPrevious.title",
    "Compare PREV"
  ) "Release readiness should verify File Header Lens evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "HIS-005",
    "The twenty-second M5 slice adds a conservative current-line blame status bar baseline",
    "The twenty-third M5 slice adds a conservative current-line blame hover baseline",
    "The twenty-fifth M5 slice enriches the conservative current-line blame hover with a bounded SVN log summary",
    "CurrentLineBlameStatusBarService",
    "CurrentLineBlameHoverProvider",
    "createStatusBarItem",
    "registerHoverProvider",
    "subversionr.currentLineBlame",
    "subversionr.lens.currentLine",
    "subversionr.lens.hover",
    "shows a localized single-line blame status for a projected text-stable SVN file",
    "returns localized one-line SVN blame hover with the first log-message line",
    "does not request blame for dirty editors until working-copy line mapping exists",
    "does not request blame or log in untrusted workspaces",
    "lineLimit: 1",
    'pegRevision: "base"',
    "SVN blame",
    "SVN Blame: {0}",
    "Log Message:",
    "No log message"
  ) "Release readiness should verify Current Line blame evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "HIS-007",
    "The twenty-fourth M5 slice adds the optional symbol history CodeLens baseline",
    "SymbolHistoryCodeLensProvider",
    "provideCodeLenses",
    "resolveCodeLens",
    "executeDocumentSymbolProvider",
    "executeDocumentSymbols",
    "subversionr.lens.symbols",
    "provides unresolved symbol lenses for projected text-stable SVN files without requesting blame",
    "resolves a visible symbol lens with BASE blame revision, author, and revision counts",
    "supports SymbolInformation ranges from the current document",
    "does not query symbols when disabled, outside open repositories, dirty, oversized, or unsafe",
    "does not resolve a command when blame is cancelled, incomplete, local-only, or fails",
    "SVN r{0} - Authors {1}, Revisions {2}",
    "command.showBlame.title"
  ) "Release readiness should verify Symbol Lens evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "DIF-004",
    "The nineteenth M5 slice adds loaded-row Compare Revisions for file history",
    "compareRevisionsTarget(element: unknown, selectedElements: unknown)",
    "creates compare targets from exactly two current loaded file revision rows",
    "historyCompareRevisionUriComponents",
    "subversionr.history.compareRevisions",
    "svn.itemlog.openDiff",
    "svn.repolog.openDiff",
    "subversionr.history.fileRevision.previousDiffable",
    "viewItem == subversionr.history.fileRevision || viewItem == subversionr.history.fileRevision.previousDiffable) && listMultiSelection",
    "command.history.compareRevisions.title",
    "SubversionR: Compare Revisions",
    "Binary SVN revision content is not displayed in the text editor: {0}@{1}"
  ) "Release readiness should verify bounded arbitrary revision comparison evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "HIS-010",
    "HIS-010 M5 bounded Compare Revisions scope",
    "The nineteenth M5 slice adds loaded-row Compare Revisions for file history",
    "compareRevisionsTarget(element: unknown, selectedElements: unknown)",
    "creates compare targets from exactly two current loaded file revision rows",
    "historyCompareRevisionUriComponents",
    "subversionr.history.compareRevisions",
    "svn.itemlog.openDiff",
    "svn.repolog.openDiff",
    "command.history.compareRevisions.title",
    "SVN Revision Compare: {0}"
  ) "Release readiness should verify History Compare Revisions evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "STA-010",
    "subversionr.workingCopyMetadata",
    "SVN working copy metadata",
    "SVN switched node",
    "SVN sparse depth",
    "projects switched and sparse metadata-only nodes without counting them as committable changes",
    "adds switched and sparse depth metadata to SourceControl resource tooltips"
  ) "Release readiness should verify switched and sparse status metadata evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "PRD-004",
    "TOR-001",
    "TOR-002",
    "docs/plans/m7-release-publication.md",
    "TortoiseSVN public integration plan coverage",
    "packages/vscode-extension/src/security/externalToolConfiguration.ts",
    "packages/vscode-extension/tests/externalToolConfiguration.test.ts",
    "packages/vscode-extension/src/tortoise/tortoiseDetector.ts",
    "packages/vscode-extension/tests/tortoiseDetector.test.ts",
    "packages/vscode-extension/src/tortoise/tortoiseLauncher.ts",
    "packages/vscode-extension/tests/tortoiseLauncher.test.ts",
    "packages/vscode-extension/src/tortoise/tortoiseCommandController.ts",
    "packages/vscode-extension/tests/tortoiseCommandController.test.ts",
    "requires trusted workspace execution before reading Tortoise settings",
    "reports unavailable without failing native workflows when TortoiseSVN is absent",
    "builds read-only file intent arguments without output or log-message switches",
    "rejects unsupported mutating Tortoise commands",
    "spawns TortoiseProc.exe with shell disabled and no command-line string concatenation",
    "blocks repository log launch in untrusted workspaces before detection or process spawn",
    "silently skips unavailable TortoiseSVN without launching while keeping repository sessions intact",
    "silently skips unavailable TortoiseSVN resource commands without launching",
    "subversionr.tortoiseAvailable"
  ) "Release readiness should verify optional TortoiseSVN evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "SEC-013",
    "MIG-008",
    "MIG-011",
    "packages/vscode-extension/src/cache/cacheLifecycleService.ts",
    "packages/vscode-extension/tests/cacheLifecycleService.test.ts",
    "packages/vscode-extension/src/cache/cacheCommandController.ts",
    "packages/vscode-extension/tests/cacheCommandController.test.ts",
    "packages/vscode-extension/tests/backendProcess.test.ts",
    "crates/subversionr-protocol/tests/protocol_contract.rs",
    "crates/subversionr-daemon/tests/rpc_dispatch.rs",
    "M7d protocol v1.20",
    "protocol v1.20 cache schema assertions",
    "subversionr.cacheMigrationReport",
    "workingCopyMutation",
    "releaseTraceIds",
    "delete-and-reconcile"
  ) "Release readiness should verify M7d cache schema, privacy, and migration report evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "PRD-014",
    "docs/adr/ADR-008-stable-vscode-apis.md",
    "Core functionality uses stable VS Code APIs and does not depend on proposed APIs.",
    "packages/vscode-extension/tsconfig.json",
    "does not request proposed VS Code APIs",
    "enabledApiProposals",
    "vscode.proposed",
    "enable-proposed-api"
  ) "Release readiness should verify stable VS Code API evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "REP-006",
    "packages/vscode-extension/src/repository/repositorySessionService.ts",
    "packages/vscode-extension/src/repository/repositoryLifecycleService.ts",
    "packages/vscode-extension/tests/repositorySessionService.test.ts",
    "packages/vscode-extension/tests/repositoryLifecycleService.test.ts",
    "crates/subversionr-daemon/src/native.rs",
    "crates/subversionr-daemon/tests/native_bridge.rs",
    "repositoryUuid",
    "repositoryRootUrl",
    "workingCopyRoot",
    "validateReopenResponse",
    "movedCandidateMatchesSession",
    "recovers a missing open session from a moved working copy with the same repository identity",
    "keeps stale session state when backend reopen returns a different repository identity for the same path",
    "SUBVERSIONR_REPOSITORY_REOPEN_IDENTITY_MISMATCH",
    "does not recover a moved working copy when UUID matches but repository root URL differs",
    "file:///D:/other-repo"
  ) "Release readiness should verify repository identity evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "REP-005",
    "docs/plans/m2-repository-status-snapshot.md",
    "crates/subversionr-protocol/src/lib.rs",
    "crates/subversionr-daemon/tests/native_bridge.rs",
    "packages/vscode-extension/src/diagnostics/installedSourceControlSurfaceReport.ts",
    "packages/vscode-extension/tests/installedSourceControlSurfaceReport.test.ts",
    "scripts/release/test-vscode-installed-source-control-surface.ps1",
    "scripts/tests/release-installed-source-control-surface-scripts.tests.ps1",
    "workspace_scope_root: path.to_string()",
    "reports subdirectory opens resolving to the parent working copy provider",
    "workspaceScopeRootMatchedRequest",
    "sourceControlRootMatchedWorkingCopyRoot",
    "subdirectoryOpenResolvedToWorkingCopyRoot",
    "sourceControlSubdirectoryOpenReport",
    "createSourceControl"
  ) "Release readiness should verify workspace scope partial evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "SYN-001",
    "docs/plans/m4-core-scm-operations.md",
    "packages/vscode-extension/src/extension.ts",
    "packages/vscode-extension/src/repository/repositoryCommandController.ts",
    "packages/vscode-extension/tests/repositoryCommandController.test.ts",
    "packages/vscode-extension/tests/operationRunRpcClient.test.ts",
    "crates/subversionr-daemon/src/bridge.rs",
    "crates/subversionr-daemon/tests/rpc_dispatch.rs",
    "crates/subversionr-daemon/tests/stdio_rpc.rs",
    "crates/subversionr-daemon/tests/native_bridge.rs",
    "native/svn-bridge/src/subversionr_bridge.c",
    "operationRunUpdate",
    "operation_run_update_returns_revision_and_full_reconcile_hint",
    "operation_run_update_forwards_head_working_copy_options_to_bridge",
    "native_bridge_update_root_to_head_applies_remote_change_and_reports_revision",
    "subversionr.updateRepository",
    "sourceControlUiUpdateToRevisionWorkflow",
    "subversionr.installedSourceControlUiE2eUpdateToRevisionWorkflow",
    "sourceControlUiUpdateToRevisionCancellationWorkflow",
    "subversionr.installedSourceControlUiE2eUpdateToRevisionCancellationWorkflow",
    "updateToRevisionRepositoryOracle",
    "updateRevisionPromptCapture",
    "updateCancellationRevisionPromptCapture",
    "updateDepthPromptCapture",
    "updateStickyDepthPromptCapture",
    "updateExternalsPromptCapture",
    "targetContentUnchangedAfterCancellation",
    "postUpdateReconcileCompleted",
    "SubversionR updated SVN working copy to revision {0}: {1}",
    "Updating SVN working copy"
  ) "Release readiness should verify root update partial evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "OPS-010",
    "OPS-011",
    "OPS-013",
    "OPS-014",
    "OPS-015",
    "COM-003",
    "STA-003",
    "STA-009",
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
    "addToIgnoreWorkingCopyOracle",
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
    "Lock message and Unlock mode prompt cancellation/no-projection-mutation evidence",
    "local Lock message and Unlock mode prompt cancellation only",
    "Does not claim broad remote lock-server matrices",
    "break/steal policy coverage beyond implemented inputs",
    "break/steal policy breadth",
    "load-scale lock behavior",
    "installed auth/certificate breadth",
    "svn:needs-lock",
    "Get-LockHeldWorkingCopyOracle",
    "Get-LockUnlockWorkingCopyOracle",
    "lockHeldWorkingCopyOracle",
    "lockUnlockWorkingCopyOracle",
    "operationLock",
    "operationUnlock",
    "subversionr.workingCopyMetadata",
    "runChangelistSetClearWorkflow",
    "sourceControlUiChangelistSetClearWorkflow",
    "subversionr.installedSourceControlUiE2eChangelistSetClearWorkflow",
    "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHANGELIST_SET_CLEAR_WORKING_COPY",
    "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHANGELIST_SET_PROMPT_READY",
    "subversionr.setResourceChangelist",
    "subversionr.clearResourceChangelist",
    "changelistSetPromptCapture",
    "groupProjectedAfterSet",
    "resourceReturnedToChangesAfterClear",
    "runCommitChangelistWorkflow",
    "sourceControlUiCommitChangelistWorkflow",
    "subversionr.installedSourceControlUiE2eCommitChangelistWorkflow",
    "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_COMMIT_CHANGELIST_WORKING_COPY",
    "subversionr.commitChangelist",
    "commitUsedChangelistFilter",
    "changelistProjectionClearedCommittedPath",
    "unselectedNonChangelistPathStillModified",
    "Get-CommitChangelistRepositoryOracle",
    "commitChangelistRepositoryOracle",
    "runRevertChangelistWorkflow",
    "sourceControlUiRevertChangelistWorkflow",
    "subversionr.installedSourceControlUiE2eRevertChangelistWorkflow",
    "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REVERT_CHANGELIST_WORKING_COPY",
    "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CHANGELIST_REVERT_PROMPT_READY",
    "subversionr.revertChangelist",
    "changelistRevertPromptCapture",
    "revertUsedChangelistFilter",
    "workingCopyContentRestored"
  ) "Release readiness should verify installed Add to Ignore, Lock/Unlock, and changelist Beta-D/Beta-E evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "BRM-001",
    "BRM-005",
    "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1",
    "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1",
    "runBranchCreateWorkflow",
    "sourceControlUiBranchCreateWorkflow",
    "subversionr.installedSourceControlUiE2eBranchCreateWorkflow",
    "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_BRANCH_CREATE_WORKING_COPY",
    "subversionr.branchCreateRepository",
    "branchCreateSourcePromptCapture",
    "branchCreateDestinationPromptCapture",
    "branchCreateRevisionPromptCapture",
    "branchCreateMessagePromptCapture",
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
    "subversionr.switchRepository",
    "switchUrlPromptCapture",
    "switchDepthPromptCapture",
    "switchStickyDepthPromptCapture",
    "switchAncestryPromptCapture",
    "postSwitchReconcileCompleted",
    "postSwitchGenerationAdvanced",
    "postSwitchRepositoryIdentityPreserved",
    "Get-SwitchWorkingCopyOracle",
    "switchWorkingCopyOracle",
    "workingCopyUrlMatched",
    "does not prove switch-after-copy",
    "target browsing",
    "broad remote/auth/certificate matrices",
    "repository-browser integration",
    "merge workflows",
    "switched working-copy edge/load behavior"
  ) "Release readiness should verify installed Branch/Tag create and Switch Beta-E evidence without closing switch-after-copy."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "REP-007",
    "crates/subversionr-daemon/tests/rpc_dispatch.rs",
    "crates/subversionr-daemon/tests/native_bridge.rs",
    "status_refresh_upserts_sparse_metadata_without_counting_local_changes",
    "status_refresh_removes_cached_sparse_metadata_when_full_reconcile_restores_depth",
    "native_bridge_status_snapshot_preserves_sparse_depth_and_excluded_semantics",
    "--set-depth",
    "exclude",
    'assert_eq!(sparse_dir.depth, "files")',
    'assert!(!entries.contains_key("excluded-dir/inside.txt"))'
  ) "Release readiness should verify sparse working-copy evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "REP-008",
    "crates/subversionr-daemon/tests/native_bridge.rs",
    "packages/vscode-extension/tests/repositoryCommandController.test.ts",
    "native_bridge_status_snapshot_reports_switched_directory_and_branch_history",
    "opens file history for a switched projected SVN file using the switched branch path",
    "svn switch",
    "branches/feature-src",
    "src/feature-only.c",
    'assert!(switched_dir.switched)',
    'assert_eq!(switched_dir.local_status, "normal")',
    'assert_eq!(snapshot.summary.local_changes, 0)',
    "native bridge should query switched branch history",
    "edit feature src"
  ) "Release readiness should verify switched working-copy evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "DIR-002",
    "DIR-019",
    "packages/vscode-extension/src/status/watcherEvents.ts",
    "packages/vscode-extension/tests/watcherEvents.test.ts",
    "packages/vscode-extension/src/status/dirtyPathSet.ts",
    "packages/vscode-extension/tests/dirtyPathSet.test.ts",
    "packages/vscode-extension/src/status/statusSnapshotStore.ts",
    "packages/vscode-extension/tests/statusSnapshotStore.test.ts",
    "packages/vscode-extension/src/scm/sourceControlResourceStore.ts",
    "packages/vscode-extension/tests/sourceControlResourceStore.test.ts",
    "normalizes Windows separators and maps raw event kinds",
    "accepts UNC absolute paths",
    "drops paths containing dot or parent traversal segments",
    "keeps local and remote status dimensions independent for the same path",
    "applies signed summary deltas without touching remote entries",
    "applies local refresh deltas without changing incoming remote resources"
  ) "Release readiness should verify dirty-path normalization and remote-separate status evidence."
  Assert-TextFileContainsTokens $verifyReadinessScript @(
    "DIR-006",
    "packages/vscode-extension/src/status/dirtyPathSet.ts",
    "packages/vscode-extension/tests/dirtyPathSet.test.ts",
    "packages/vscode-extension/tests/dirtyPathPipeline.test.ts",
    "packages/vscode-extension/tests/statusRefreshScheduler.test.ts",
    "packages/vscode-extension/tests/repositoryWatcherService.test.ts",
    "dirtyPathFold",
    "dirtyPathSubtreeFold",
    "watcherOverflow",
    "folds a sibling change storm into one directory files refresh target before root overflow",
    "folds a nested directory storm into one subtree refresh target before root overflow",
    "prefers the deepest subtree fold that brings the dirty queue within budget",
    "folds watcher event storms through the dirty-path overflow target"
  ) "Release readiness should verify deterministic adaptive-planner partial evidence."

  Assert-ReleaseReadinessRejectsTamperedEvidenceRef `
    "missing/evidence-ref.test.ts" `
    "evidence ref does not exist" `
    "Release readiness should reject partial or verified evidence refs that do not exist."
  Assert-ReleaseReadinessRejectsTamperedEvidenceRef `
    "../outside/evidence-ref.test.ts" `
    "evidence ref must be repo-relative without parent" `
    "Release readiness should reject evidence refs that escape the repository."
  Assert-ReleaseReadinessRejectsSubstringOnlyEvidenceRef
  Assert-ReleaseReadinessRejectsReparseEvidenceRef $tempRoot
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "PRD-003" `
    "partial" `
    "SVN terminology audit intentionally tampered" `
    "PRD-003" `
    "Release readiness should require the SVN terminology audit evidence to remain verified."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "STA-011" `
    "packages/vscode-extension/tests/statusSettings.test.ts" `
    "STA-011" `
    "Release readiness should require status badge evidence to include the status settings test."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "STA-005" `
    "blocked" `
    "Ignored default evidence intentionally tampered" `
    "STA-005" `
    "Release readiness should require ignored default status evidence to remain partial."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "STA-005" `
    "crates/subversionr-daemon/tests/native_bridge.rs" `
    "STA-005" `
    "Release readiness should require ignored default status evidence to include the native fixture."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "STA-005" `
    "packages/vscode-extension/src/status/statusRefreshRpcClient.ts" `
    "STA-005" `
    "Release readiness should require ignored default status evidence to include the strict TypeScript refresh request validation."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "REP-005" `
    "blocked" `
    "Workspace scope evidence intentionally tampered" `
    "REP-005" `
    "Release readiness should require workspace scope evidence to remain partial."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "REP-005" `
    "crates/subversionr-daemon/tests/native_bridge.rs" `
    "REP-005" `
    "Release readiness should require workspace scope evidence to include the native subdirectory-open fixture."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "REP-005" `
    "packages/vscode-extension/tests/installedSourceControlSurfaceReport.test.ts" `
    "REP-005" `
    "Release readiness should require workspace scope evidence to include installed Source Control subdirectory-open unit coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "REP-005" `
    "scripts/release/test-vscode-installed-source-control-surface.ps1" `
    "REP-005" `
    "Release readiness should require workspace scope evidence to include the installed Source Control surface gate."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "SYN-001" `
    "blocked" `
    "Root update evidence intentionally tampered" `
    "SYN-001" `
    "Release readiness should require root update evidence to remain partial."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "BRM-001" `
    "verified" `
    "Branch create evidence intentionally overclaimed" `
    "BRM-001" `
    "Release readiness should require Branch/Tag create evidence to remain partial."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "BRM-005" `
    "verified" `
    "Switch evidence intentionally overclaimed" `
    "BRM-005" `
    "Release readiness should require Switch evidence to remain partial."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "BRM-004" `
    "partial" `
    "Switch-after-copy evidence intentionally overclaimed" `
    "BRM-004" `
    "Release readiness should require switch-after-copy to remain blocked as a post-Beta non-claim."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "SYN-001" `
    "crates/subversionr-daemon/tests/rpc_dispatch.rs" `
    "SYN-001" `
    "Release readiness should require root update evidence to include daemon operation dispatch coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "SYN-001" `
    "packages/vscode-extension/tests/repositoryCommandController.test.ts" `
    "SYN-001" `
    "Release readiness should require root update evidence to include VS Code command controller coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "SYN-001" `
    "crates/subversionr-daemon/tests/native_bridge.rs" `
    "SYN-001" `
    "Release readiness should require root update evidence to include the native root update fixture."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "SYN-001" `
    "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1" `
    "SYN-001" `
    "Release readiness should require root update evidence to include installed Source Control UI E2E coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "SYN-003" `
    "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1" `
    "SYN-003" `
    "Release readiness should require update-to-revision evidence to include installed Source Control UI E2E coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "SYN-004" `
    "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1" `
    "SYN-004" `
    "Release readiness should require sparse-depth/sticky-depth update evidence to include installed Source Control UI E2E coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "SYN-005" `
    "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1" `
    "SYN-005" `
    "Release readiness should require externals-policy update evidence to include installed Source Control UI E2E coverage."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "STA-007" `
    "blocked" `
    "Property-only evidence intentionally tampered" `
    "STA-007" `
    "Release readiness should require property-only status evidence to remain partial."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "STA-007" `
    "crates/subversionr-daemon/tests/rpc_dispatch.rs" `
    "STA-007" `
    "Release readiness should require property-only status evidence to include daemon cache and delta coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "STA-007" `
    "crates/subversionr-daemon/tests/native_bridge.rs" `
    "STA-007" `
    "Release readiness should require property-only status evidence to include the native fixture."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "DIF-001" `
    "blocked" `
    "Working-Base evidence intentionally tampered" `
    "DIF-001" `
    "Release readiness should require Working-Base evidence to remain partial."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIF-001" `
    "packages/vscode-extension/tests/vscodeSourceControlPresenter.test.ts" `
    "DIF-001" `
    "Release readiness should require Working-Base evidence to include QuickDiff provider coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIF-001" `
    "crates/subversionr-daemon/tests/native_bridge.rs" `
    "DIF-001" `
    "Release readiness should require Working-Base evidence to include native BASE content coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIF-001" `
    "packages/vscode-extension/package.nls.json" `
    "DIF-001" `
    "Release readiness should require Working-Base evidence to include package localization coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIF-001" `
    "packages/vscode-extension/l10n/bundle.l10n.json" `
    "DIF-001" `
    "Release readiness should require Working-Base evidence to include runtime localization coverage."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "DIF-002" `
    "blocked" `
    "Working-HEAD evidence intentionally tampered" `
    "DIF-002" `
    "Release readiness should require Working-HEAD evidence to remain partial."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIF-002" `
    "packages/vscode-extension/tests/headContentDocumentProvider.test.ts" `
    "DIF-002" `
    "Release readiness should require Working-HEAD evidence to include HEAD content provider coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIF-002" `
    "packages/vscode-extension/tests/repositoryCommandController.test.ts" `
    "DIF-002" `
    "Release readiness should require Working-HEAD evidence to include repository command coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIF-002" `
    "crates/subversionr-daemon/tests/rpc_dispatch.rs" `
    "DIF-002" `
    "Release readiness should require Working-HEAD evidence to include daemon HEAD content dispatch coverage."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "HIS-009" `
    "blocked" `
    "Open Revision evidence intentionally tampered" `
    "HIS-009" `
    "Release readiness should require Open Revision evidence to remain partial."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-009" `
    "packages/vscode-extension/tests/historyOpenRevisionCommand.test.ts" `
    "HIS-009" `
    "Release readiness should require Open Revision evidence to include strict command target URI coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-009" `
    "packages/vscode-extension/tests/historyTreeDataProvider.test.ts" `
    "HIS-009" `
    "Release readiness should require Open Revision evidence to include History TreeView command target coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-009" `
    "packages/vscode-extension/tests/revisionContentDocumentProvider.test.ts" `
    "HIS-009" `
    "Release readiness should require Open Revision evidence to include readonly revision document provider coverage."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "HIS-008" `
    "blocked" `
    "Revision Details evidence intentionally tampered" `
    "HIS-008" `
    "Release readiness should require Revision Details evidence to remain partial."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-008" `
    "packages/vscode-extension/tests/historyRevisionDetailsDocument.test.ts" `
    "HIS-008" `
    "Release readiness should require Revision Details evidence to include readonly document provider coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-008" `
    "packages/vscode-extension/tests/historyTreeDataProvider.test.ts" `
    "HIS-008" `
    "Release readiness should require Revision Details evidence to include History TreeView target coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-008" `
    "packages/vscode-extension/tests/extensionManifest.test.ts" `
    "HIS-008" `
    "Release readiness should require Revision Details evidence to include command contribution and localization coverage."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "HIS-004" `
    "blocked" `
    "Blame evidence intentionally tampered" `
    "HIS-004" `
    "Release readiness should require Blame document evidence to remain partial."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-004" `
    "packages/vscode-extension/tests/historyBlameDocument.test.ts" `
    "HIS-004" `
    "Release readiness should require Blame evidence to include readonly document provider coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-004" `
    "packages/vscode-extension/tests/repositoryCommandController.test.ts" `
    "HIS-004" `
    "Release readiness should require Blame evidence to include repository command coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-004" `
    "packages/vscode-extension/tests/extensionManifest.test.ts" `
    "HIS-004" `
    "Release readiness should require Blame evidence to include command contribution and localization coverage."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "HIS-003" `
    "blocked" `
    "Line History evidence intentionally tampered" `
    "HIS-003" `
    "Release readiness should require Line History evidence to remain partial."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-003" `
    "packages/vscode-extension/tests/lineHistoryCommandController.test.ts" `
    "HIS-003" `
    "Release readiness should require Line History evidence to include active-editor command coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-003" `
    "packages/vscode-extension/tests/activeEditorContextService.test.ts" `
    "HIS-003" `
    "Release readiness should require Line History evidence to include active-editor context coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-003" `
    "packages/vscode-extension/tests/historyTreeDataProvider.test.ts" `
    "HIS-003" `
    "Release readiness should require Line History evidence to include preloaded History TreeView coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-003" `
    "packages/vscode-extension/tests/extensionManifest.test.ts" `
    "HIS-003" `
    "Release readiness should require Line History evidence to include command contribution and localization coverage."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "HIS-001" `
    "blocked" `
    "Repository Log evidence intentionally tampered" `
    "HIS-001" `
    "Release readiness should require Repository Log evidence to remain partial."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-001" `
    "crates/subversionr-daemon/tests/rpc_dispatch.rs" `
    "HIS-001" `
    "Release readiness should require Repository Log evidence to include daemon history/log dispatch coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-001" `
    "packages/vscode-extension/tests/historyLogRpcClient.test.ts" `
    "HIS-001" `
    "Release readiness should require Repository Log evidence to include TypeScript history/log client coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-001" `
    "packages/vscode-extension/tests/historyTreeDataProvider.test.ts" `
    "HIS-001" `
    "Release readiness should require Repository Log evidence to include native History TreeView coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-001" `
    "packages/vscode-extension/tests/repositoryCommandController.test.ts" `
    "HIS-001" `
    "Release readiness should require Repository Log evidence to include repository command coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-001" `
    "packages/vscode-extension/tests/extensionManifest.test.ts" `
    "HIS-001" `
    "Release readiness should require Repository Log evidence to include command, view, settings, and localization coverage."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "HIS-002" `
    "blocked" `
    "File History evidence intentionally tampered" `
    "HIS-002" `
    "Release readiness should require File History evidence to remain partial."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-002" `
    "packages/vscode-extension/tests/historyTreeDataProvider.test.ts" `
    "HIS-002" `
    "Release readiness should require File History evidence to include copy-following History TreeView coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-002" `
    "packages/vscode-extension/tests/repositoryCommandController.test.ts" `
    "HIS-002" `
    "Release readiness should require File History evidence to include canonical file history command coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-002" `
    "packages/vscode-extension/tests/historyLogRpcClient.test.ts" `
    "HIS-002" `
    "Release readiness should require File History evidence to include copy-from metadata parsing coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-002" `
    "crates/subversionr-protocol/tests/protocol_contract.rs" `
    "HIS-002" `
    "Release readiness should require File History evidence to include stable changed-path wire metadata coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-002" `
    "native/svn-bridge/src/subversionr_bridge.c" `
    "HIS-002" `
    "Release readiness should require File History evidence to include libsvn log bridge coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-002" `
    "packages/vscode-extension/tests/extensionManifest.test.ts" `
    "HIS-002" `
    "Release readiness should require File History evidence to include command and localization coverage."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "DIF-003" `
    "blocked" `
    "PREV evidence intentionally tampered" `
    "DIF-003" `
    "Release readiness should require PREV evidence to remain partial."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIF-003" `
    "packages/vscode-extension/tests/historyTreeDataProvider.test.ts" `
    "DIF-003" `
    "Release readiness should require PREV evidence to include history TreeView compare target coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIF-003" `
    "packages/vscode-extension/tests/repositoryCommandController.test.ts" `
    "DIF-003" `
    "Release readiness should require PREV evidence to include repository command coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIF-003" `
    "packages/vscode-extension/tests/fileHeaderCodeLensProvider.test.ts" `
    "DIF-003" `
    "Release readiness should require PREV evidence to include File Header CodeLens coverage."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "HIS-006" `
    "blocked" `
    "File Header Lens evidence intentionally tampered" `
    "HIS-006" `
    "Release readiness should require File Header Lens evidence to remain partial."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-006" `
    "packages/vscode-extension/tests/fileHeaderCodeLensProvider.test.ts" `
    "HIS-006" `
    "Release readiness should require File Header Lens evidence to include CodeLens provider coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-006" `
    "packages/vscode-extension/tests/lensSettings.test.ts" `
    "HIS-006" `
    "Release readiness should require File Header Lens evidence to include Lens settings coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-006" `
    "packages/vscode-extension/tests/sourceControlResourceStore.test.ts" `
    "HIS-006" `
    "Release readiness should require File Header Lens evidence to include projection lookup coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-006" `
    "packages/vscode-extension/tests/extensionManifest.test.ts" `
    "HIS-006" `
    "Release readiness should require File Header Lens evidence to include command contribution and localization coverage."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "HIS-005" `
    "blocked" `
    "Current Line evidence intentionally tampered" `
    "HIS-005" `
    "Release readiness should require Current Line evidence to remain partial."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-005" `
    "packages/vscode-extension/tests/currentLineBlameStatusBarService.test.ts" `
    "HIS-005" `
    "Release readiness should require Current Line evidence to include status bar coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-005" `
    "packages/vscode-extension/tests/currentLineBlameHoverProvider.test.ts" `
    "HIS-005" `
    "Release readiness should require Current Line evidence to include hover coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-005" `
    "packages/vscode-extension/tests/historyBlameRpcClient.test.ts" `
    "HIS-005" `
    "Release readiness should require Current Line evidence to include blame RPC coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-005" `
    "packages/vscode-extension/tests/extensionManifest.test.ts" `
    "HIS-005" `
    "Release readiness should require Current Line evidence to include settings and localization coverage."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "HIS-007" `
    "blocked" `
    "Symbol Lens evidence intentionally tampered" `
    "HIS-007" `
    "Release readiness should require Symbol Lens evidence to remain partial."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-007" `
    "packages/vscode-extension/tests/symbolHistoryCodeLensProvider.test.ts" `
    "HIS-007" `
    "Release readiness should require Symbol Lens evidence to include symbol CodeLens provider coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-007" `
    "packages/vscode-extension/tests/historyBlameRpcClient.test.ts" `
    "HIS-007" `
    "Release readiness should require Symbol Lens evidence to include blame RPC coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-007" `
    "packages/vscode-extension/tests/lensSettings.test.ts" `
    "HIS-007" `
    "Release readiness should require Symbol Lens evidence to include Lens settings coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-007" `
    "packages/vscode-extension/tests/extensionManifest.test.ts" `
    "HIS-007" `
    "Release readiness should require Symbol Lens evidence to include settings and localization coverage."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "DIF-004" `
    "blocked" `
    "Arbitrary revision evidence intentionally tampered" `
    "DIF-004" `
    "Release readiness should require bounded arbitrary revision comparison evidence to remain partial."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIF-004" `
    "packages/vscode-extension/tests/historyTreeDataProvider.test.ts" `
    "DIF-004" `
    "Release readiness should require bounded arbitrary revision comparison evidence to include History TreeView multi-select coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIF-004" `
    "packages/vscode-extension/tests/historyCompareRevisionCommand.test.ts" `
    "DIF-004" `
    "Release readiness should require bounded arbitrary revision comparison evidence to include immutable revision diff URI coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIF-004" `
    "packages/vscode-extension/tests/extensionManifest.test.ts" `
    "DIF-004" `
    "Release readiness should require bounded arbitrary revision comparison evidence to include command contribution and localization coverage."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "HIS-010" `
    "blocked" `
    "History Compare Revisions evidence intentionally tampered" `
    "HIS-010" `
    "Release readiness should require History Compare Revisions evidence to remain partial."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-010" `
    "packages/vscode-extension/tests/historyTreeDataProvider.test.ts" `
    "HIS-010" `
    "Release readiness should require History Compare Revisions evidence to include History TreeView multi-select coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-010" `
    "packages/vscode-extension/tests/historyCompareRevisionCommand.test.ts" `
    "HIS-010" `
    "Release readiness should require History Compare Revisions evidence to include immutable revision diff URI coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "HIS-010" `
    "packages/vscode-extension/tests/extensionManifest.test.ts" `
    "HIS-010" `
    "Release readiness should require History Compare Revisions evidence to include command contribution and localization coverage."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "STA-010" `
    "blocked" `
    "Switched/Sparse evidence intentionally tampered" `
    "STA-010" `
    "Release readiness should require Switched/Sparse evidence to remain partial."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "STA-010" `
    "packages/vscode-extension/tests/vscodeSourceControlPresenter.test.ts" `
    "STA-010" `
    "Release readiness should require Switched/Sparse evidence to include Source Control tooltip coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "STA-010" `
    "packages/vscode-extension/l10n/bundle.l10n.json" `
    "STA-010" `
    "Release readiness should require Switched/Sparse evidence to include runtime localization coverage."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "PRD-004" `
    "blocked" `
    "Optional Tortoise evidence intentionally tampered" `
    "PRD-004" `
    "Release readiness should require optional Tortoise core-workflow evidence to remain partial."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "TOR-001" `
    "blocked" `
    "Tortoise detection evidence intentionally tampered" `
    "TOR-001" `
    "Release readiness should require Tortoise detection evidence to remain partial."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "TOR-002" `
    "blocked" `
    "Tortoise optional evidence intentionally tampered" `
    "TOR-002" `
    "Release readiness should require missing-Tortoise optional evidence to remain partial."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "PRD-004" `
    "packages/vscode-extension/tests/externalToolConfiguration.test.ts" `
    "PRD-004" `
    "Release readiness should require optional Tortoise evidence to include external tool trust policy tests."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "TOR-001" `
    "packages/vscode-extension/tests/tortoiseDetector.test.ts" `
    "TOR-001" `
    "Release readiness should require Tortoise detection evidence to include detector tests."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "TOR-002" `
    "packages/vscode-extension/tests/tortoiseCommandController.test.ts" `
    "TOR-002" `
    "Release readiness should require missing-Tortoise optional evidence to include command-controller tests."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "SEC-001" `
    "blocked" `
    "Credential storage evidence intentionally tampered" `
    "SEC-001" `
    "Release readiness should require credential storage evidence to remain verified."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "SEC-004" `
    "blocked" `
    "TLS certificate evidence intentionally tampered" `
    "SEC-004" `
    "Release readiness should require TLS certificate evidence to remain verified."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "SEC-005" `
    "blocked" `
    "Changed certificate evidence intentionally tampered" `
    "SEC-005" `
    "Release readiness should require changed-certificate evidence to remain verified."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "SEC-006" `
    "blocked" `
    "Background prompt evidence intentionally tampered" `
    "SEC-006" `
    "Release readiness should require background prompt evidence to remain verified."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "SEC-011" `
    "blocked" `
    "Tortoise security evidence intentionally tampered" `
    "SEC-011" `
    "Release readiness should require Tortoise security evidence to remain verified."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "SEC-012" `
    "verified" `
    "none" `
    "SEC-012" `
    "Release readiness should require install/rollback evidence to remain blocked until public release blockers close."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "SEC-016" `
    "verified" `
    "none" `
    "SEC-016" `
    "Release readiness should require remote-protocol fuzz evidence to remain blocked until coverage-guided fuzzing closes."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "SEC-001" `
    "packages/vscode-extension/tests/credentialController.test.ts" `
    "SEC-001" `
    "Release readiness should require credential storage evidence to include controller tests."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "SEC-004" `
    "crates/subversionr-daemon/tests/native_bridge.rs" `
    "SEC-004" `
    "Release readiness should require TLS certificate evidence to include native HTTPS DAV fixture coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "SEC-005" `
    "packages/vscode-extension/tests/certificateTrustController.test.ts" `
    "SEC-005" `
    "Release readiness should require changed-certificate evidence to include trust controller tests."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "SEC-006" `
    "packages/vscode-extension/tests/certificateTrustController.test.ts" `
    "SEC-006" `
    "Release readiness should require background prompt evidence to include certificate controller tests."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "SEC-011" `
    "packages/vscode-extension/tests/tortoiseLauncher.test.ts" `
    "SEC-011" `
    "Release readiness should require Tortoise security evidence to include launcher tests."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "SEC-012" `
    "scripts/release/test-vscode-cli-install-vsix.ps1" `
    "SEC-012" `
    "Release readiness should require install/rollback evidence to include the isolated VS Code CLI install gate."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "SEC-016" `
    "fuzz/fuzz_targets/svn_server_response_history_log.rs" `
    "SEC-016" `
    "Release readiness should require remote-protocol fuzz evidence to include the source-controlled fuzz target."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "SEC-013" `
    "blocked" `
    "Cache privacy evidence intentionally tampered" `
    "SEC-013" `
    "Release readiness should require cache privacy evidence to remain partial."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "MIG-008" `
    "blocked" `
    "Cache schema evidence intentionally tampered" `
    "MIG-008" `
    "Release readiness should require cache schema evidence to remain partial."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "MIG-011" `
    "blocked" `
    "Cache migration report evidence intentionally tampered" `
    "MIG-011" `
    "Release readiness should require cache migration report evidence to remain partial."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "SEC-013" `
    "packages/vscode-extension/tests/cacheLifecycleService.test.ts" `
    "SEC-013" `
    "Release readiness should require cache privacy evidence to include cache lifecycle tests."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "MIG-008" `
    "crates/subversionr-protocol/tests/protocol_contract.rs" `
    "MIG-008" `
    "Release readiness should require cache schema evidence to include protocol contract tests."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "MIG-011" `
    "packages/vscode-extension/tests/cacheCommandController.test.ts" `
    "MIG-011" `
    "Release readiness should require cache migration report evidence to include command-controller tests."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "PRD-014" `
    "blocked" `
    "Stable API evidence intentionally tampered" `
    "PRD-014" `
    "Release readiness should require stable VS Code API evidence to remain verified."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "PRD-014" `
    "packages/vscode-extension/tests/extensionManifest.test.ts" `
    "PRD-014" `
    "Release readiness should require stable VS Code API evidence to include manifest/API audit tests."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "REP-006" `
    "blocked" `
    "Repository identity evidence intentionally tampered" `
    "REP-006" `
    "Release readiness should require repository identity evidence to remain verified."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "REP-006" `
    "packages/vscode-extension/tests/repositorySessionService.test.ts" `
    "REP-006" `
    "Release readiness should require repository identity evidence to include same-path identity mismatch coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "REP-006" `
    "packages/vscode-extension/tests/repositoryLifecycleService.test.ts" `
    "REP-006" `
    "Release readiness should require repository identity evidence to include moved-working-copy recovery coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "REP-006" `
    "crates/subversionr-daemon/tests/native_bridge.rs" `
    "REP-006" `
    "Release readiness should require repository identity evidence to include native UUID/root URL/WC root fixtures."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "REP-007" `
    "blocked" `
    "Sparse working-copy evidence intentionally tampered" `
    "REP-007" `
    "Release readiness should require sparse working-copy evidence to remain verified."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "REP-007" `
    "crates/subversionr-daemon/tests/rpc_dispatch.rs" `
    "REP-007" `
    "Release readiness should require sparse working-copy evidence to include daemon cache/delta coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "REP-007" `
    "crates/subversionr-daemon/tests/native_bridge.rs" `
    "REP-007" `
    "Release readiness should require sparse working-copy evidence to include native sparse/excluded fixtures."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "REP-008" `
    "blocked" `
    "Switched working-copy evidence intentionally tampered" `
    "REP-008" `
    "Release readiness should require switched working-copy evidence to remain verified."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "REP-008" `
    "crates/subversionr-daemon/tests/native_bridge.rs" `
    "REP-008" `
    "Release readiness should require switched working-copy evidence to include native switched status and history fixtures."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "DIR-002" `
    "blocked" `
    "Dirty-path normalization evidence intentionally tampered" `
    "DIR-002" `
    "Release readiness should require dirty-path normalization evidence to remain partial."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIR-002" `
    "packages/vscode-extension/tests/watcherEvents.test.ts" `
    "DIR-002" `
    "Release readiness should require dirty-path normalization evidence to include watcher event normalization tests."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIR-002" `
    "packages/vscode-extension/tests/dirtyPathSet.test.ts" `
    "DIR-002" `
    "Release readiness should require dirty-path normalization evidence to include dirty-path set normalization tests."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "DIR-019" `
    "blocked" `
    "Remote-separate dirty status evidence intentionally tampered" `
    "DIR-019" `
    "Release readiness should require remote-separate dirty status evidence to remain partial."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIR-019" `
    "packages/vscode-extension/tests/statusSnapshotStore.test.ts" `
    "DIR-019" `
    "Release readiness should require remote-separate evidence to include canonical status-store tests."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIR-019" `
    "packages/vscode-extension/tests/sourceControlResourceStore.test.ts" `
    "DIR-019" `
    "Release readiness should require remote-separate evidence to include Source Control projection tests."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "DIR-006" `
    "blocked" `
    "Adaptive planner evidence intentionally tampered" `
    "DIR-006" `
    "Release readiness should require deterministic adaptive-planner evidence to remain partial."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIR-006" `
    "packages/vscode-extension/tests/dirtyPathSet.test.ts" `
    "DIR-006" `
    "Release readiness should require adaptive-planner evidence to include dirty-path folding tests."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIR-006" `
    "packages/vscode-extension/tests/statusRefreshScheduler.test.ts" `
    "DIR-006" `
    "Release readiness should require adaptive-planner evidence to include scheduler overflow backpressure tests."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "OPS-004" `
    "partial" `
    "Delete Unversioned evidence intentionally tampered" `
    "OPS-004" `
    "Release readiness should require Delete Unversioned evidence to remain verified after installed load evidence closes."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "OPS-004" `
    "packages/vscode-extension/tests/repositoryCommandController.test.ts" `
    "OPS-004" `
    "Release readiness should require Delete Unversioned evidence to include the repository command coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "OPS-004" `
    "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1" `
    "OPS-004" `
    "Release readiness should require Delete Unversioned evidence to include installed Source Control UI E2E coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "OPS-004" `
    "docs/release/delete-unversioned-trash-policy.md" `
    "OPS-004" `
    "Release readiness should require Delete Unversioned evidence to include the trash-mode policy."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "OPS-003" `
    "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1" `
    "OPS-003" `
    "Release readiness should require Keep-local Remove evidence to include installed Source Control UI E2E coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "OPS-001" `
    "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1" `
    "OPS-001" `
    "Release readiness should require Add evidence to include installed Source Control UI E2E coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "OPS-002" `
    "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1" `
    "OPS-002" `
    "Release readiness should require Remove evidence to include installed Source Control UI E2E coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "OPS-006" `
    "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1" `
    "OPS-006" `
    "Release readiness should require Revert evidence to include installed Source Control UI E2E coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "OPS-007" `
    "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1" `
    "OPS-007" `
    "Release readiness should require Resolve evidence to include installed Source Control UI E2E coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "OPS-008" `
    "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1" `
    "OPS-008" `
    "Release readiness should require Cleanup evidence to include installed Source Control UI E2E coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "STA-013" `
    "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1" `
    "STA-013" `
    "Release readiness should require manual refresh evidence to include installed Source Control UI E2E coverage."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "COM-001" `
    "blocked" `
    "Commit All evidence intentionally tampered" `
    "COM-001" `
    "Release readiness should require Commit All evidence to remain verified."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "COM-001" `
    "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1" `
    "COM-001" `
    "Release readiness should require Commit All evidence to include installed Source Control UI E2E coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "COM-001" `
    "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1" `
    "COM-001" `
    "Release readiness should require Commit All evidence to include installed Source Control UI E2E script coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "COM-001" `
    "packages/vscode-extension/tests/sourceControlResourceStore.test.ts" `
    "COM-001" `
    "Release readiness should require Commit All evidence to include SourceControl target derivation tests."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "COM-001" `
    "packages/vscode-extension/tests/repositoryCommandController.test.ts" `
    "COM-001" `
    "Release readiness should require Commit All evidence to include repository command behavior tests."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "COM-002" `
    "blocked" `
    "Commit Selected evidence intentionally tampered" `
    "COM-002" `
    "Release readiness should require Commit Selected evidence to remain verified."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "COM-002" `
    "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1" `
    "COM-002" `
    "Release readiness should require Commit Selected evidence to include installed Source Control UI E2E coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "COM-002" `
    "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1" `
    "COM-002" `
    "Release readiness should require Commit Selected evidence to include installed Source Control UI E2E script coverage."
  foreach ($requirementId in @("OPS-010", "OPS-011", "OPS-013", "OPS-014", "OPS-015", "COM-003", "STA-009")) {
    Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
      $requirementId `
      "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1" `
      $requirementId `
      "Release readiness should require $requirementId evidence to include installed Source Control UI E2E coverage."
    Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
      $requirementId `
      "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1" `
      $requirementId `
      "Release readiness should require $requirementId evidence to include installed Source Control UI E2E script coverage."
  }
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "COM-002" `
    "packages/vscode-extension/tests/repositoryCommandController.test.ts" `
    "COM-002" `
    "Release readiness should require Commit Selected evidence to include repository command behavior tests."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "COM-002" `
    "packages/vscode-extension/tests/operationRunRpcClient.test.ts" `
    "COM-002" `
    "Release readiness should require Commit Selected evidence to include operation/run RPC client tests."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "COM-002" `
    "crates/subversionr-daemon/tests/rpc_dispatch.rs" `
    "COM-002" `
    "Release readiness should require Commit Selected evidence to include daemon RPC dispatch tests."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "COM-002" `
    "packages/vscode-extension/package.json" `
    "COM-002" `
    "Release readiness should require Commit Selected evidence to include manifest command registration."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "STA-016" `
    "blocked" `
    "SCM multi-selection evidence intentionally tampered" `
    "STA-016" `
    "Release readiness should require SCM multi-selection evidence to remain verified."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "STA-016" `
    "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1" `
    "STA-016" `
    "Release readiness should require SCM multi-selection evidence to include installed Source Control UI E2E coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "STA-016" `
    "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1" `
    "STA-016" `
    "Release readiness should require SCM multi-selection evidence to include installed Source Control UI E2E script coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "STA-016" `
    "packages/vscode-extension/src/extension.ts" `
    "STA-016" `
    "Release readiness should require SCM multi-selection evidence to include extension command spreading."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "STA-016" `
    "packages/vscode-extension/tests/repositoryCommandController.test.ts" `
    "STA-016" `
    "Release readiness should require SCM multi-selection evidence to include repository command behavior tests."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "UX-001" `
    "partial" `
    "UX activation evidence intentionally tampered" `
    "UX-001" `
    "Release readiness should require UX-001 activation/accessibility evidence to remain verified."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "UX-001" `
    "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1" `
    "UX-001" `
    "Release readiness should require UX-001 evidence to include installed Source Control UI E2E coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "UX-001" `
    "scripts/release/capture-vscode-renderer-ui.mjs" `
    "UX-001" `
    "Release readiness should require UX-001 evidence to include renderer accessibility and screenshot capture coverage."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "UX-007" `
    "partial" `
    "UX repository picker evidence intentionally tampered" `
    "UX-007" `
    "Release readiness should require UX-007 repository picker evidence to remain verified."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "UX-007" `
    "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1" `
    "UX-007" `
    "Release readiness should require UX-007 evidence to include installed Source Control UI E2E coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "UX-007" `
    "scripts/release/capture-vscode-renderer-ui.mjs" `
    "UX-007" `
    "Release readiness should require UX-007 evidence to include renderer QuickPick accessibility and screenshot capture coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "UX-007" `
    "packages/vscode-extension/src/extension.ts" `
    "UX-007" `
    "Release readiness should require UX-007 evidence to include the VS Code QuickPick host implementation."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "UX-007" `
    "packages/vscode-extension/tests/repositoryCommandController.test.ts" `
    "UX-007" `
    "Release readiness should require UX-007 evidence to include repository picker behavior tests."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "UX-002" `
    "blocked" `
    "No-repository empty-state evidence intentionally tampered" `
    "UX-002" `
    "Release readiness should require UX-002 empty-state Scan and Checkout welcome evidence to remain partial until remaining checkout remote/auth/browser/failure flows and broader no-repository UX/a11y evidence are covered."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "UX-002" `
    "packages/vscode-extension/package.json" `
    "UX-002" `
    "Release readiness should require UX-002 evidence to include the VS Code manifest welcome contribution."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "UX-002" `
    "packages/vscode-extension/package.nls.json" `
    "UX-002" `
    "Release readiness should require UX-002 evidence to include English package localization."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "UX-002" `
    "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1" `
    "UX-002" `
    "Release readiness should require UX-002 evidence to include installed no-repository Source Control UI E2E coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "UX-002" `
    "scripts/release/capture-vscode-renderer-ui.mjs" `
    "UX-002" `
    "Release readiness should require UX-002 evidence to include renderer DOM, accessibility, and screenshot capture coverage."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "DIR-007" `
    "blocked" `
    "Dirty-path file-target evidence intentionally tampered" `
    "DIR-007" `
    "Release readiness should require dirty-path file-target evidence to remain partial."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "DIR-009" `
    "partial" `
    "Dirty-path coverage evidence intentionally tampered" `
    "DIR-009" `
    "Release readiness should require dirty-path coverage evidence to remain verified."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "DIR-010" `
    "partial" `
    "Dirty-path mark-sweep evidence intentionally tampered" `
    "DIR-010" `
    "Release readiness should require dirty-path mark-sweep evidence to remain verified."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "DIR-012" `
    "partial" `
    "Dirty-path generation-supersede evidence intentionally tampered" `
    "DIR-012" `
    "Release readiness should require dirty-path generation-supersede evidence to remain verified."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "DIR-013" `
    "partial" `
    "Dirty-path cancellation evidence intentionally tampered" `
    "DIR-013" `
    "Release readiness should require dirty-path cancellation evidence to remain verified."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIR-007" `
    "packages/vscode-extension/src/status/statusRefreshScheduler.ts" `
    "DIR-007" `
    "Release readiness should require dirty-path file-target evidence to include scheduler coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIR-009" `
    "packages/vscode-extension/src/status/statusRefreshRpcClient.ts" `
    "DIR-009" `
    "Release readiness should require dirty-path coverage evidence to include the refresh RPC parser."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIR-009" `
    "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1" `
    "DIR-009" `
    "Release readiness should require dirty-path coverage evidence to include installed Source Control UI E2E coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIR-009" `
    "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1" `
    "DIR-009" `
    "Release readiness should require dirty-path coverage evidence to include installed Source Control UI E2E script coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIR-010" `
    "packages/vscode-extension/src/status/statusSnapshotStore.ts" `
    "DIR-010" `
    "Release readiness should require dirty-path mark-sweep evidence to include the canonical snapshot store."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIR-010" `
    "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1" `
    "DIR-010" `
    "Release readiness should require dirty-path mark-sweep evidence to include installed Source Control UI E2E coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIR-010" `
    "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1" `
    "DIR-010" `
    "Release readiness should require dirty-path mark-sweep evidence to include installed Source Control UI E2E script coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIR-012" `
    "packages/vscode-extension/tests/statusSnapshotStore.test.ts" `
    "DIR-012" `
    "Release readiness should require dirty-path generation-supersede evidence to include store stale-generation tests."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIR-012" `
    "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1" `
    "DIR-012" `
    "Release readiness should require dirty-path generation-supersede evidence to include installed Source Control UI E2E coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIR-012" `
    "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1" `
    "DIR-012" `
    "Release readiness should require dirty-path generation-supersede evidence to include installed Source Control UI E2E script coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIR-013" `
    "packages/vscode-extension/tests/jsonRpcStreamClient.test.ts" `
    "DIR-013" `
    "Release readiness should require dirty-path cancellation evidence to include JSON-RPC cancel transport tests."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIR-013" `
    "scripts/release/test-vscode-installed-source-control-ui-e2e.ps1" `
    "DIR-013" `
    "Release readiness should require dirty-path cancellation evidence to include installed Source Control UI E2E coverage."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIR-013" `
    "scripts/tests/release-installed-source-control-ui-e2e-scripts.tests.ps1" `
    "DIR-013" `
    "Release readiness should require dirty-path cancellation evidence to include installed Source Control UI E2E script coverage."
  Assert-ReleaseReadinessRejectsRequirementEvidenceStatus `
    "DIR-015" `
    "blocked" `
    "Ignored-on-demand evidence intentionally tampered" `
    "DIR-015" `
    "Release readiness should require ignored-on-demand evidence to remain partial."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIR-015" `
    "native/svn-bridge/src/subversionr_bridge.c" `
    "DIR-015" `
    "Release readiness should require ignored-on-demand evidence to include the native status policy."
  Assert-ReleaseReadinessRejectsMissingRequirementEvidenceRef `
    "DIR-015" `
    "crates/subversionr-protocol/src/lib.rs" `
    "DIR-015" `
    "Release readiness should require ignored-on-demand evidence to include the refresh target protocol contract."

  $fixtureExtensionRoot = Join-Path $tempRoot "extension"
  New-Item -ItemType Directory -Force -Path (Join-Path $fixtureExtensionRoot "l10n") | Out-Null
  @'
{
  "name": "subversionr",
  "displayName": "SubversionR",
  "version": "0.2.0",
  "publisher": "hitsuki-ban",
  "main": "./dist/extension.js",
  "keywords": ["svn", "subversion", "source-control", "scm", "apache-subversion"],
  "icon": "resources/marketplace/icon.png"
}
'@ | Set-Content -LiteralPath (Join-Path $fixtureExtensionRoot "package.json") -NoNewline
  Write-TestPngIcon (Join-Path $fixtureExtensionRoot "resources\marketplace\icon.png")
  "{}" | Set-Content -LiteralPath (Join-Path $fixtureExtensionRoot "package.nls.json") -NoNewline
  "{}" | Set-Content -LiteralPath (Join-Path $fixtureExtensionRoot "package.nls.ja.json") -NoNewline
  "{}" | Set-Content -LiteralPath (Join-Path $fixtureExtensionRoot "package.nls.zh-cn.json") -NoNewline
  "{}" | Set-Content -LiteralPath (Join-Path $fixtureExtensionRoot "l10n\bundle.l10n.json") -NoNewline
  "{}" | Set-Content -LiteralPath (Join-Path $fixtureExtensionRoot "l10n\bundle.l10n.ja.json") -NoNewline
  "{}" | Set-Content -LiteralPath (Join-Path $fixtureExtensionRoot "l10n\bundle.l10n.zh-cn.json") -NoNewline

  $peExeSource = Join-Path $env:WINDIR "System32\cmd.exe"
  $peDllSource = Join-Path $env:WINDIR "System32\kernel32.dll"
  Assert-True (Test-Path -LiteralPath $peExeSource -PathType Leaf) "Test fixture requires the Windows x64 cmd.exe PE file."
  Assert-True (Test-Path -LiteralPath $peDllSource -PathType Leaf) "Test fixture requires the Windows x64 kernel32.dll PE file."

  $daemonExe = Join-Path $tempRoot "daemon\subversionr-daemon.exe"
  Copy-TestFile $peExeSource $daemonExe

  $bridgeRuntime = Join-Path $tempRoot "bridge-runtime"
  Copy-TestFile $peDllSource (Join-Path $bridgeRuntime "subversionr_svn_bridge.dll")
  foreach ($dependencyName in @($requiredNativeDependencyNames + $opensslDependencyNames)) {
    Copy-TestFile $peDllSource (Join-Path $bridgeRuntime $dependencyName)
  }
  Copy-TestFile $peDllSource (Join-Path $bridgeRuntime "unexpected-stale.dll")
  Copy-TestFile $peDllSource (Join-Path $bridgeRuntime "iconv\utf-8.so")
  Copy-TestFile $peDllSource (Join-Path $bridgeRuntime "iconv\utf-8.pdb")
  foreach ($toolName in $svnCliTools) {
    Copy-TestFile $peExeSource (Join-Path $bridgeRuntime $toolName)
  }

  $sourceLock = Join-Path $tempRoot "sources.lock.json"
  @'
{
  "sources": [
    {
      "name": "apache-subversion",
      "version": "1.14.5",
      "license": "Apache-2.0",
      "sha512": "subversion-sha512"
    },
    {
      "name": "openssl",
      "version": "3.5.7",
      "license": "Apache-2.0",
      "sha512": "openssl-sha512"
    }
  ]
}
'@ | Set-Content -LiteralPath $sourceLock -NoNewline

  $outputRoot = Join-Path $tempRoot "stage"
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $stageScript `
    -Target win32-x64 `
    -ExtensionRoot $fixtureExtensionRoot `
    -DaemonExe $daemonExe `
    -BridgeRuntimeDirectory $bridgeRuntime `
    -SourceLockPath $sourceLock `
    -OutputRoot $outputRoot
  if ($LASTEXITCODE -ne 0) {
    throw "stage-vscode-package-layout.ps1 failed with exit code $LASTEXITCODE."
  }

  $stagedRoot = Join-Path $outputRoot "subversionr-win32-x64"
  $resourceRoot = Join-Path $stagedRoot "resources\backend\win32-x64"
  $marketplaceIcon = Join-Path $stagedRoot "resources\marketplace\icon.png"
  Assert-True (Test-Path -LiteralPath (Join-Path $stagedRoot "package.json") -PathType Leaf) "Staged package should include package.json."
  Assert-True (Test-Path -LiteralPath $marketplaceIcon -PathType Leaf) "Staged package should include the Marketplace icon."
  Assert-True (Test-Path -LiteralPath (Join-Path $resourceRoot "subversionr-daemon.exe") -PathType Leaf) "Staged resources should include the sidecar executable."
  Assert-True (Test-Path -LiteralPath (Join-Path $resourceRoot "subversionr_svn_bridge.dll") -PathType Leaf) "Staged resources should include the bridge DLL."
  foreach ($dependencyName in @($requiredNativeDependencyNames + $opensslDependencyNames)) {
    Assert-True (Test-Path -LiteralPath (Join-Path $resourceRoot $dependencyName) -PathType Leaf) "Staged resources should include $dependencyName."
  }
  Assert-True (Test-Path -LiteralPath (Join-Path $resourceRoot "iconv\utf-8.so") -PathType Leaf) "Staged resources should include APR iconv converter modules."
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $resourceRoot "iconv\utf-8.pdb"))) "Staged resources must not include APR iconv PDB files."
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $resourceRoot "unexpected-stale.dll"))) "Staged resources must not include stale DLLs outside the runtime allowlist."
  foreach ($toolName in $svnCliTools) {
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $resourceRoot $toolName))) "Staged resources must not include $toolName."
  }

  $manifestPath = Join-Path $resourceRoot "subversionr-backend-package-manifest.json"
  Assert-True (Test-Path -LiteralPath $manifestPath -PathType Leaf) "Staged resources should include a package manifest."
  $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  Assert-Equal "1" ([string]$manifest.schemaVersion) "Package manifest schema version should be stable."
  Assert-Equal "subversionr.vscode.backend-package.win32-x64.v1" $manifest.schema "Package manifest schema should describe the staged backend package layout."
  Assert-Equal "staged-vsix-layout" $manifest.layoutKind "Package manifest should describe a staged VSIX layout."
  Assert-Equal "win32-x64" $manifest.target "Package manifest should record the VS Code target."
  Assert-Equal "win32-x64" $manifest.vsceTarget "Package manifest should record the vsce target."
  Assert-Equal "x64" $manifest.architecture "Package manifest should record the architecture."
  Assert-Equal "Release" $manifest.configuration "Package manifest should record the native configuration."
  Assert-Equal "subversionr" $manifest.extension.id "Package manifest should record the extension id."
  Assert-Equal "SubversionR" $manifest.extension.displayName "Package manifest should record the display name."
  Assert-True (@($manifest.artifacts | Where-Object { $_.role -eq "sidecar" -and $_.path -eq "resources/backend/win32-x64/subversionr-daemon.exe" }).Count -eq 1) "Manifest should include the sidecar artifact with a relative path."
  Assert-True (@($manifest.artifacts | Where-Object { $_.role -eq "bridge" -and $_.path -eq "resources/backend/win32-x64/subversionr_svn_bridge.dll" }).Count -eq 1) "Manifest should include the bridge artifact with a relative path."
  foreach ($dependencyName in @($requiredNativeDependencyNames + $opensslDependencyNames)) {
    $requiredDependencyPath = "resources/backend/win32-x64/$dependencyName"
    Assert-True (@($manifest.artifacts | Where-Object { $_.role -eq "nativeDependency" -and $_.path -eq $requiredDependencyPath }).Count -eq 1) "Manifest should include required native dependency $requiredDependencyPath."
  }
  Assert-True (@($manifest.artifacts | Where-Object { $_.role -eq "nativeDependency" -and $_.path -eq "resources/backend/win32-x64/iconv/utf-8.so" }).Count -eq 1) "Manifest should include APR iconv modules as native dependencies."
  Assert-True (@($manifest.artifacts | Where-Object { $_.path -eq "resources/backend/win32-x64/unexpected-stale.dll" }).Count -eq 0) "Manifest must not authorize stale DLLs outside the runtime allowlist."
  foreach ($artifact in $manifest.artifacts) {
    Assert-True ($artifact.path -notmatch '^[A-Za-z]:[\\/]' -and $artifact.path -notmatch '^[/\\]') "Manifest artifact paths must be relative: $($artifact.path)"
    Assert-True ($artifact.sha256 -match '^[a-f0-9]{64}$') "Manifest artifact hash should be SHA256 hex: $($artifact.path)"
    Assert-True ([int64]$artifact.size -gt 0) "Manifest artifact size should be positive: $($artifact.path)"
  }
  Assert-True (@($manifest.sourceLocks | Where-Object { $_.name -eq "apache-subversion" -and $_.version -eq "1.14.5" }).Count -eq 1) "Manifest should include source-lock metadata."

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyLayoutScript `
    -Target win32-x64 `
    -PackageRoot $stagedRoot
  if ($LASTEXITCODE -ne 0) {
    throw "verify-vscode-package-layout.ps1 failed with exit code $LASTEXITCODE."
  }

  Remove-Item -LiteralPath $marketplaceIcon -Force
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyLayoutScript `
      -Target win32-x64 `
      -PackageRoot $stagedRoot
  } "Marketplace icon" "Layout verification should fail when the staged Marketplace icon is missing."
  Write-TestPngIcon $marketplaceIcon

  $badIconPathPackageJson = Get-Content -Raw -LiteralPath (Join-Path $fixtureExtensionRoot "package.json") | ConvertFrom-Json
  $badIconPathCases = @(
    [pscustomobject]@{ value = "../icon.png"; name = "parent-relative" },
    [pscustomobject]@{ value = "C:/SubversionR/icon.png"; name = "absolute" },
    [pscustomobject]@{ value = "resources\marketplace\icon.png"; name = "backslash" },
    [pscustomobject]@{ value = "./resources/marketplace/icon.png"; name = "dot-relative" }
  )
  foreach ($badIconPathCase in $badIconPathCases) {
    $badIconPathPackageJson.icon = $badIconPathCase.value
    $badIconPathPackageJson | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $fixtureExtensionRoot "package.json") -Encoding utf8
    Assert-NativeCommandFailsContaining {
      & pwsh -NoProfile -ExecutionPolicy Bypass -File $stageScript `
        -Target win32-x64 `
        -ExtensionRoot $fixtureExtensionRoot `
        -DaemonExe $daemonExe `
        -BridgeRuntimeDirectory $bridgeRuntime `
        -SourceLockPath $sourceLock `
        -OutputRoot (Join-Path $tempRoot "bad-icon-path-$($badIconPathCase.name)-stage")
    } "normalized package-relative path" "Staging should reject $($badIconPathCase.name) Marketplace icon paths."
  }
  $badIconPathPackageJson.icon = "resources/marketplace/icon.png"
  $badIconPathPackageJson | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $fixtureExtensionRoot "package.json") -Encoding utf8

  $tinyIconExtensionRoot = Join-Path $tempRoot "tiny-icon-extension"
  Copy-Item -LiteralPath $fixtureExtensionRoot -Destination $tinyIconExtensionRoot -Recurse
  Add-Type -AssemblyName System.Drawing
  $tinyBitmap = [System.Drawing.Bitmap]::new(64, 64)
  try {
    $tinyBitmap.Save((Join-Path $tinyIconExtensionRoot "resources\marketplace\icon.png"), [System.Drawing.Imaging.ImageFormat]::Png)
  }
  finally {
    $tinyBitmap.Dispose()
  }
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $stageScript `
      -Target win32-x64 `
      -ExtensionRoot $tinyIconExtensionRoot `
      -DaemonExe $daemonExe `
      -BridgeRuntimeDirectory $bridgeRuntime `
      -SourceLockPath $sourceLock `
      -OutputRoot (Join-Path $tempRoot "tiny-icon-stage")
  } "at least 128x128" "Staging should reject undersized Marketplace icons."

  $invalidIconPath = Join-Path $stagedRoot "resources\marketplace\icon.png"
  [System.IO.File]::WriteAllBytes($invalidIconPath, [byte[]](0x6e, 0x6f, 0x74, 0x70, 0x6e, 0x67))
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyLayoutScript `
      -Target win32-x64 `
      -PackageRoot $stagedRoot
  } "PNG file" "Layout verification should reject invalid Marketplace icon PNG bytes."
  Write-TestPngIcon $invalidIconPath

  Copy-TestFile $peExeSource (Join-Path $stagedRoot "l10n\svn.exe")
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyLayoutScript `
      -Target win32-x64 `
      -PackageRoot $stagedRoot
  } "svn.exe" "Layout verification should reject SVN CLI tools anywhere in the staged package."
  Remove-Item -LiteralPath (Join-Path $stagedRoot "l10n\svn.exe") -Force

  Copy-TestFile $peExeSource (Join-Path $resourceRoot "svnversion.exe")
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyLayoutScript `
      -Target win32-x64 `
      -PackageRoot $stagedRoot
  } "svnversion.exe" "Layout verification should reject staged SVN CLI tools beyond svn.exe."
  Remove-Item -LiteralPath (Join-Path $resourceRoot "svnversion.exe") -Force

  Copy-TestFile $peExeSource (Join-Path $resourceRoot "unexpected-helper.exe")
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyLayoutScript `
      -Target win32-x64 `
      -PackageRoot $stagedRoot
  } "unexpected resource file" "Layout verification should fail on files outside the manifest allowlist."
  Remove-Item -LiteralPath (Join-Path $resourceRoot "unexpected-helper.exe") -Force

  $daemonBytes = [System.IO.File]::ReadAllBytes((Join-Path $resourceRoot "subversionr-daemon.exe"))
  $daemonBytes[0] = $daemonBytes[0] -bxor 0xff
  [System.IO.File]::WriteAllBytes((Join-Path $resourceRoot "subversionr-daemon.exe"), $daemonBytes)
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyLayoutScript `
      -Target win32-x64 `
      -PackageRoot $stagedRoot
  } "sha256" "Layout verification should fail when a staged artifact hash changes."

  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $stageScript `
      -Target win32-x64 `
      -ExtensionRoot $fixtureExtensionRoot `
      -DaemonExe (Join-Path $tempRoot "missing\subversionr-daemon.exe") `
      -BridgeRuntimeDirectory $bridgeRuntime `
      -SourceLockPath $sourceLock `
      -OutputRoot (Join-Path $tempRoot "missing-daemon-stage")
  } "DaemonExe" "Staging should fail fast when the sidecar executable is missing."

  $missingDependencyRuntime = Join-Path $tempRoot "bridge-runtime-missing-dependency"
  Copy-TestFile $peDllSource (Join-Path $missingDependencyRuntime "subversionr_svn_bridge.dll")
  foreach ($dependencyName in (@($requiredNativeDependencyNames + $opensslDependencyNames) | Where-Object { $_ -ne "libsvn_delta-1.dll" })) {
    Copy-TestFile $peDllSource (Join-Path $missingDependencyRuntime $dependencyName)
  }
  Copy-TestFile $peDllSource (Join-Path $missingDependencyRuntime "iconv\utf-8.so")
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $stageScript `
      -Target win32-x64 `
      -ExtensionRoot $fixtureExtensionRoot `
      -DaemonExe $daemonExe `
      -BridgeRuntimeDirectory $missingDependencyRuntime `
      -SourceLockPath $sourceLock `
      -OutputRoot (Join-Path $tempRoot "missing-dependency-stage")
  } "Required native dependency" "Staging should fail fast when a required native dependency is missing."

  $packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  Assert-Equal "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/tests/release-scripts.tests.ps1" $packageJson.scripts."release:test-scripts" "Root package should expose release script tests."
  Assert-True ($packageJson.scripts."release:stage-vscode:win32-x64".Contains("-Target win32-x64")) "Root package should expose explicit win32-x64 staging."
  Assert-True ($packageJson.scripts."release:stage-vscode:win32-x64".Contains("-DaemonExe target/release/subversionr-daemon.exe")) "Staging script should require the release sidecar path."
  Assert-True ($packageJson.scripts."release:verify-vscode:win32-x64".Contains("-Target win32-x64")) "Root package should expose explicit win32-x64 layout verification."
  Assert-ContainsInOrder $packageJson.scripts."release:package-vsix:win32-x64" @(
    "pnpm release:build-vscode-extension",
    "scripts/release/package-vscode-vsix.ps1"
  ) "VSIX packaging should rebuild the compiled extension before packaging so installed evidence cannot use stale dist artifacts."
  Assert-True ($packageJson.scripts."release:test-marketplace-publication-scripts".Contains("release-marketplace-publication-scripts.tests.ps1")) "Root package should expose Marketplace publication script tests."
  Assert-True ($packageJson.scripts."release:generate-publication-gaps:win32-x64".Contains("-MarketplacePublishWorkflowPath .github/workflows/publish-marketplace.yml")) "Publication gaps generation should bind the Marketplace publish workflow."
  Assert-True ($packageJson.scripts."release:generate-publication-gaps:win32-x64".Contains("-MarketplaceIdentityBootstrapEvidencePath docs/release/marketplace-identity-bootstrap-evidence.json")) "Publication gaps generation should bind the Marketplace identity bootstrap evidence."
  Assert-True ($packageJson.scripts."release:generate-publication-gaps:win32-x64".Contains("-MarketplaceExistingListingEvidencePath docs/release/marketplace-existing-listing-evidence.json")) "Publication gaps generation should bind the existing Marketplace listing evidence."
  Assert-True ($packageJson.scripts."release:test-beta-candidate-evidence-scripts".Contains("release-beta-candidate-evidence-scripts.tests.ps1")) "Root package should expose Beta candidate evidence script tests."
  Assert-True ($packageJson.scripts."release:generate-beta-artifact-bundle-manifest:win32-x64".Contains("generate-beta-artifact-bundle-manifest.ps1")) "Root package should expose the Beta artifact bundle manifest generator."
  Assert-True ($packageJson.scripts."release:verify-beta-candidate:win32-x64".Contains("verify-beta-candidate-evidence.ps1")) "Root package should expose the Beta candidate consistency gate."
  Assert-True ($packageJson.scripts."release:verify-beta-candidate:win32-x64".Contains("-CiWorkflowPath .github/workflows/ci.yml")) "Beta candidate consistency gate should receive the explicit CI workflow upload contract path."
  Assert-True ($packageJson.scripts."release:verify-beta-candidate:win32-x64".Contains("-ArtifactBundleManifestPath target/release-evidence/subversionr-beta-artifact-bundle-manifest-win32-x64.json")) "Beta candidate consistency gate should require the artifact bundle manifest path."

  $ciWorkflow = Get-Content -Raw -LiteralPath $ciWorkflowPath
  Assert-True ($ciWorkflow.Contains("Release script tests")) "CI should run release script tests."
  Assert-True ($ciWorkflow.Contains("Release Beta candidate evidence script tests")) "CI should run Beta candidate evidence script tests."
  Assert-True ($ciWorkflow.Contains("Build release sidecar")) "CI should build the release sidecar before staging."
  Assert-True ($ciWorkflow.Contains("Stage VS Code win32-x64 package layout")) "CI should stage the win32-x64 VS Code package layout."
  Assert-True ($ciWorkflow.Contains("Verify VS Code win32-x64 package layout")) "CI should verify the win32-x64 VS Code package layout."
  Assert-True ($ciWorkflow.Contains("Generate Beta artifact bundle manifest")) "CI should generate the Beta artifact bundle manifest after installed gates."
  Assert-True ($ciWorkflow.Contains("Verify Beta candidate evidence consistency")) "CI should verify Beta candidate evidence consistency after installed gates."
  Assert-True ($ciWorkflow.Contains("actions/upload-artifact@v7")) "CI should upload the Beta candidate artifact bundle with the current upload-artifact major."
  Assert-True ($ciWorkflow.Contains("subversionr-win32-x64-beta-candidate")) "CI should name the Beta candidate artifact bundle."
  Assert-True (-not $ciWorkflow.Contains("target/release-evidence/*.json")) "CI should not use a broad release evidence JSON glob for the Beta candidate bundle."
  Assert-True ($ciWorkflow.Contains("target/release-evidence/subversionr-source-sbom.cdx.json")) "CI should upload source SBOM explicitly for the Beta candidate bundle."
  Assert-True ($ciWorkflow.Contains("target/release-evidence/subversionr-beta-artifact-bundle-manifest-win32-x64.json")) "CI should upload the artifact bundle manifest explicitly."
  Assert-True ($ciWorkflow.Contains("target/release-evidence/subversionr-beta-candidate-consistency-win32-x64.json")) "CI should upload the final consistency report explicitly."
  Assert-True ($ciWorkflow.Contains("target/release-evidence/installed-source-control-ui-e2e/win32-x64/**/*.png")) "CI should upload installed renderer screenshots for the Beta candidate bundle."
  Assert-ContainsInOrder $ciWorkflow @(
    "Build release sidecar",
    "Smoke native bridge",
    "Stage VS Code win32-x64 package layout",
    "Verify VS Code win32-x64 package layout",
    "Package VS Code win32-x64 VSIX",
    "Verify publication gaps preflight",
    "Test installed VSIX Source Control UI E2E",
    "Test VS Code install upgrade rollback fixture",
    "Generate Beta artifact bundle manifest",
    "Verify Beta candidate evidence consistency",
    "Rust native bridge integration test",
    "Validate native build entrypoints fail fast",
    "Upload Beta candidate VSIX and evidence bundle"
  ) "CI should verify and upload the Beta candidate bundle only after packaging, provenance, publication gaps, installed VSIX gates, and final native validation."

  Write-Host "Release script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

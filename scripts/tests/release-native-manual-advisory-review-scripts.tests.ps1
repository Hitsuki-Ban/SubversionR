$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$verifyScript = Join-Path $repoRoot "scripts\release\verify-native-manual-advisory-review.ps1"
$packageJsonPath = Join-Path $repoRoot "package.json"
$ciWorkflowPath = Join-Path $repoRoot ".github\workflows\ci.yml"
$readinessVerifierPath = Join-Path $repoRoot "scripts\release\verify-readiness.ps1"

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

function Assert-NativeCommandFailsContaining([scriptblock]$Action, [string]$ExpectedText, [string]$Message) {
  $output = & $Action 2>&1
  $exitCode = $LASTEXITCODE
  Assert-True ($exitCode -ne 0) "$Message Expected native command to fail."
  $text = $output | Out-String
  Assert-True ($text.Contains($ExpectedText)) "$Message Expected output to contain '$ExpectedText', got '$text'."
}

function Assert-ContainsInOrder([string]$Text, [string[]]$Needles, [string]$Message) {
  $previousIndex = -1
  foreach ($needle in $Needles) {
    $currentIndex = $Text.IndexOf($needle, [System.StringComparison]::Ordinal)
    Assert-True ($currentIndex -ge 0) "$Message Missing '$needle'."
    Assert-True ($currentIndex -gt $previousIndex) "$Message '$needle' should appear after the previous checked term."
    $previousIndex = $currentIndex
  }
}

function Write-JsonFile([string]$Path, [object]$Value) {
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $Value | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $Path -Encoding utf8
}

function New-SourceRef([string]$SourceId, [string]$Url, [string]$Summary) {
  [pscustomobject]@{
    type = "official-source-review"
    sourceId = $SourceId
    url = $Url
    summary = $Summary
  }
}

function New-PendingManualReview([string]$Name, [string]$Version, [string]$PackageMode, [string[]]$SourceIds, [object[]]$EvidenceRefs, [string]$ReviewedAt) {
  [pscustomobject]@{
    key = "native:$Name@$Version"
    componentName = $Name
    version = $Version
    packageMode = $PackageMode
    dedicatedAdvisoryIndex = $false
    reviewer = "SubversionR release security review"
    reviewedAt = $ReviewedAt
    advisorySourceIds = $SourceIds
    terminalDecisionAllowed = $false
    triageStatus = "under_investigation"
    vexStatus = "under_investigation"
    remediationDecision = "pending"
    releaseBlocking = $true
    evidence = $EvidenceRefs
    blockers = @(
      "No dedicated versioned vulnerability advisory index is available for this component.",
      "Terminal release decision requires explicit CVE or named security-finding mapping to the locked version."
    )
    nonClaims = @(
      "This record does not assert that the component is free of known vulnerabilities.",
      "This record does not approve remediation or VEX release readiness."
    )
  }
}

function New-TerminalFixedReview([string]$Name, [string]$Version, [string]$PackageMode, [string[]]$SourceIds, [object[]]$EvidenceRefs, [object[]]$Findings, [object[]]$Approvals, [string]$ReviewedAt) {
  [pscustomobject]@{
    key = "native:$Name@$Version"
    componentName = $Name
    version = $Version
    packageMode = $PackageMode
    dedicatedAdvisoryIndex = $false
    reviewer = "SubversionR release security review"
    reviewedAt = $ReviewedAt
    advisorySourceIds = $SourceIds
    terminalDecisionAllowed = $true
    terminalVexStatus = "fixed"
    triageStatus = "complete"
    vexStatus = "fixed"
    remediationDecision = "fixed"
    fixedVersion = $Version
    releaseBlocking = $false
    evidence = $EvidenceRefs
    terminalFindings = $Findings
    approvals = $Approvals
    nonClaims = @(
      "This record only permits the exact terminal decision recorded here.",
      "This record does not claim public release readiness."
    )
  }
}

function New-TerminalNotAffectedReview([string]$Name, [string]$Version, [string]$PackageMode, [string[]]$SourceIds, [object[]]$EvidenceRefs, [object[]]$Findings, [object[]]$Approvals, [string]$ReviewedAt) {
  [pscustomobject]@{
    key = "native:$Name@$Version"
    componentName = $Name
    version = $Version
    packageMode = $PackageMode
    dedicatedAdvisoryIndex = $false
    reviewer = "SubversionR release security review"
    reviewedAt = $ReviewedAt
    advisorySourceIds = $SourceIds
    terminalDecisionAllowed = $true
    terminalVexStatus = "not_affected"
    triageStatus = "complete"
    vexStatus = "not_affected"
    remediationDecision = "not_required"
    vexJustification = "vulnerable_code_not_present"
    impactStatement = "Fixture named finding is not present in the locked component build."
    releaseBlocking = $false
    evidence = $EvidenceRefs
    terminalFindings = $Findings
    approvals = $Approvals
    nonClaims = @(
      "This record only permits the exact terminal decision recorded here.",
      "This record does not claim public release readiness."
    )
  }
}

function New-Finding([string]$Id, [string]$Type, [string]$SourceId, [string]$Version) {
  [pscustomobject]@{
    id = $Id
    type = $Type
    affectedComponent = "audit-lib"
    resolvedInVersion = $Version
    sourceId = $SourceId
    url = "https://example.test/audit-lib/security/$Id"
    resolutionStatement = "Official release evidence maps $Id to audit-lib $Version."
  }
}

function New-Approval([string]$Reviewer, [string]$ApprovedAt) {
  New-ApprovalForDecision $Reviewer $ApprovedAt "approve-terminal-fixed"
}

function New-ApprovalForDecision([string]$Reviewer, [string]$ApprovedAt, [string]$Decision) {
  [pscustomobject]@{
    reviewer = $Reviewer
    approvedAt = $ApprovedAt
    decision = $Decision
  }
}

function New-Decision([string]$Name, [string]$Version, [string]$Status, [string]$SourceId, [string]$ReviewedAt) {
  $decision = [ordered]@{
    key = "native:$Name@$Version"
    kind = "native-component"
    componentName = $Name
    version = $Version
    triageStatus = if ($Status -eq "under_investigation") { "under_investigation" } else { "complete" }
    vexStatus = $Status
    remediationDecision = if ($Status -eq "under_investigation") { "pending" } elseif ($Status -eq "fixed") { "fixed" } else { "not_required" }
    reviewer = "SubversionR release security review"
    reviewedAt = $ReviewedAt
    analysisEvidence = @(
      [pscustomobject]@{
        type = "advisory-source-review"
        sourceId = $SourceId
        url = "https://example.test/$Name/security"
        summary = "Fixture source-contract review for $Name $Version."
      }
    )
  }
  if ($Status -eq "fixed") {
    $decision.fixedVersion = $Version
    $decision.fixEvidence = @(
      [pscustomobject]@{
        type = "project-advisory"
        sourceId = $SourceId
        url = "https://example.test/$Name/security/fixed"
        summary = "Fixture terminal evidence for $Name $Version."
      }
    )
  } elseif ($Status -eq "not_affected") {
    $decision.vexJustification = "vulnerable_code_not_present"
    $decision.impactStatement = "Fixture named finding is not present in the locked component build."
  }
  [pscustomobject]$decision
}

function New-ManualReviewFixture([string]$Root) {
  $now = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")

  $sourceLockPath = Join-Path $Root "sources.lock.json"
  Write-JsonFile $sourceLockPath ([pscustomobject]@{
      sources = @(
        [pscustomobject]@{ name = "runtime-lib"; version = "1.0.0"; license = "MIT"; url = "https://example.test/runtime-lib-1.0.0.tar.gz"; sha512 = ("a" * 128) },
        [pscustomobject]@{ name = "manual-lib"; version = "3.0.0"; license = "Apache-2.0"; url = "https://example.test/manual-lib-3.0.0.tar.gz"; sha512 = ("b" * 128) },
        [pscustomobject]@{ name = "audit-lib"; version = "4.0.0"; license = "Zlib"; url = "https://example.test/audit-lib-4.0.0.tar.gz"; sha512 = ("c" * 128) }
      )
    })

  $advisorySourcesPath = Join-Path $Root "native-advisory-sources.lock.json"
  Write-JsonFile $advisorySourcesPath ([pscustomobject]@{
      schemaVersion = 1
      schema = "subversionr.security.native-advisory-sources.v1"
      capturedAt = "2026-06-25"
      components = @(
        [pscustomobject]@{
          name = "runtime-lib"
          displayName = "Runtime Lib"
          primaryAuthority = "Fixture project"
          dedicatedAdvisoryIndex = $true
          reviewLimitation = "Fixture dedicated vulnerability index."
          advisorySources = @(
            [pscustomobject]@{ id = "runtime-security"; type = "project-security"; authority = "project"; url = "https://example.test/runtime-lib/security"; purpose = "Fixture runtime security index." }
          )
        },
        [pscustomobject]@{
          name = "manual-lib"
          displayName = "Manual Lib"
          primaryAuthority = "Fixture project"
          dedicatedAdvisoryIndex = $false
          reviewLimitation = "Fixture component has no dedicated advisory index."
          advisorySources = @(
            [pscustomobject]@{ id = "manual-security"; type = "project-security-reporting"; authority = "project"; url = "https://example.test/manual-lib/security"; purpose = "Manual security source." },
            [pscustomobject]@{ id = "manual-release-notes"; type = "project-release-notes"; authority = "project"; url = "https://example.test/manual-lib/releases/3.0.0"; purpose = "Manual release source." }
          )
        },
        [pscustomobject]@{
          name = "audit-lib"
          displayName = "Audit Lib"
          primaryAuthority = "Fixture project"
          dedicatedAdvisoryIndex = $false
          reviewLimitation = "Fixture component needs named finding evidence before terminalization."
          advisorySources = @(
            [pscustomobject]@{ id = "audit-release-notes"; type = "project-release-notes"; authority = "project"; url = "https://example.test/audit-lib/releases/4.0.0"; purpose = "Audit release notes." },
            [pscustomobject]@{ id = "audit-security-audit"; type = "project-security-audit"; authority = "project"; url = "https://example.test/audit-lib/security/audit"; purpose = "Audit finding source." }
          )
        }
      )
    })

  $artifactMapPath = Join-Path $Root "native-artifact-map.win32-x64.json"
  Write-JsonFile $artifactMapPath ([pscustomobject]@{
      schemaVersion = 1
      schema = "subversionr.release.native-artifact-map.win32-x64.v1"
      target = "win32-x64"
      components = @(
        [pscustomobject]@{ sourceName = "runtime-lib"; expectedVersion = "1.0.0"; packageMode = "packaged-runtime"; requiredArtifactPaths = @("resources/backend/win32-x64/runtime.dll"); rationale = "Fixture runtime." },
        [pscustomobject]@{ sourceName = "manual-lib"; expectedVersion = "3.0.0"; packageMode = "static-link-input"; carrierArtifactPaths = @("resources/backend/win32-x64/manual-carrier.dll"); rationale = "Fixture manual static input." },
        [pscustomobject]@{ sourceName = "audit-lib"; expectedVersion = "4.0.0"; packageMode = "packaged-runtime"; requiredArtifactPaths = @("resources/backend/win32-x64/audit.dll"); rationale = "Fixture audit runtime." }
      )
    })

  $manualReviewPath = Join-Path $Root "native-manual-advisory-review.win32-x64.json"
  Write-JsonFile $manualReviewPath ([pscustomobject]@{
      schemaVersion = 1
      schema = "subversionr.security.native-manual-advisory-review.win32-x64.v1"
      target = "win32-x64"
      capturedAt = "2026-06-25"
      publicReadinessClaim = $false
      nativeManualAdvisoryReviewComplete = $false
      reviewPolicy = [pscustomobject]@{
        appliesToDedicatedAdvisoryIndex = $false
        terminalDecisionMaxAgeDays = 90
        terminalDecisionRequiresFindingMapping = $true
        terminalDecisionRequiresTwoApprovals = $true
        underInvestigationIsReleaseBlocking = $true
      }
      reviews = @(
        (New-PendingManualReview "manual-lib" "3.0.0" "static-link-input" @("manual-security", "manual-release-notes") @(
            (New-SourceRef "manual-security" "https://example.test/manual-lib/security" "Security reporting guidance is not a versioned advisory index."),
            (New-SourceRef "manual-release-notes" "https://example.test/manual-lib/releases/3.0.0" "Release-status evidence is insufficient for terminal vulnerability decisions.")
          ) $now),
        (New-PendingManualReview "audit-lib" "4.0.0" "packaged-runtime" @("audit-release-notes", "audit-security-audit") @(
            (New-SourceRef "audit-release-notes" "https://example.test/audit-lib/releases/4.0.0" "Release notes mention security fixes but do not enumerate CVEs or named findings."),
            (New-SourceRef "audit-security-audit" "https://example.test/audit-lib/security/audit" "Audit source needs finding-to-version mapping before terminalization.")
          ) $now)
      )
    })

  $decisionInputPath = Join-Path $Root "vulnerability-decisions.win32-x64.json"
  Write-JsonFile $decisionInputPath ([pscustomobject]@{
      schemaVersion = 1
      schema = "subversionr.security.vulnerability-decisions.v1"
      target = "win32-x64"
      decisionPolicy = [pscustomobject]@{
        terminalVexStatuses = @("not_affected", "affected", "fixed")
        nonTerminalVexStatuses = @("under_investigation")
        underInvestigationIsReleaseBlocking = $true
      }
      decisions = @(
        (New-Decision "runtime-lib" "1.0.0" "fixed" "runtime-security" $now),
        (New-Decision "manual-lib" "3.0.0" "under_investigation" "manual-security" $now),
        (New-Decision "audit-lib" "4.0.0" "under_investigation" "audit-release-notes" $now)
      )
    })

  [pscustomobject]@{
    sourceLockPath = $sourceLockPath
    advisorySourcesPath = $advisorySourcesPath
    artifactMapPath = $artifactMapPath
    manualReviewPath = $manualReviewPath
    decisionInputPath = $decisionInputPath
    now = $now
  }
}

function Invoke-VerifyManualReview([object]$Fixture) {
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
    -Target win32-x64 `
    -SourceLockPath $Fixture.sourceLockPath `
    -AdvisorySourcesPath $Fixture.advisorySourcesPath `
    -ArtifactMapPath $Fixture.artifactMapPath `
    -ManualReviewPath $Fixture.manualReviewPath `
    -DecisionInputPath $Fixture.decisionInputPath
}

$tempId = [Guid]::NewGuid().ToString("N")
$tempRoot = Join-Path $repoRoot "target\tests\release-native-manual-advisory-review-scripts\$tempId"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  Assert-True (Test-Path -LiteralPath $verifyScript -PathType Leaf) "verify-native-manual-advisory-review.ps1 should exist."

  $fixture = New-ManualReviewFixture $tempRoot
  Invoke-VerifyManualReview $fixture
  if ($LASTEXITCODE -ne 0) {
    throw "verify-native-manual-advisory-review.ps1 failed with exit code $LASTEXITCODE."
  }

  $tamperedPath = Join-Path $tempRoot "missing-review-row.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.manualReviewPath | ConvertFrom-Json
  $tampered.reviews = @($tampered.reviews | Where-Object { $_.componentName -ne "audit-lib" })
  Write-JsonFile $tamperedPath $tampered
  $tamperedFixture = $fixture.PSObject.Copy()
  $tamperedFixture.manualReviewPath = $tamperedPath
  Assert-NativeCommandFailsContaining { Invoke-VerifyManualReview $tamperedFixture } "Missing manual advisory review rows" "Verifier should reject missing no-dedicated-index review rows."

  $tamperedPath = Join-Path $tempRoot "extra-dedicated-row.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.manualReviewPath | ConvertFrom-Json
  $extra = New-PendingManualReview "runtime-lib" "1.0.0" "packaged-runtime" @("runtime-security") @(
    (New-SourceRef "runtime-security" "https://example.test/runtime-lib/security" "Dedicated advisory components must not enter the manual path.")
  ) $fixture.now
  $tampered.reviews += $extra
  Write-JsonFile $tamperedPath $tampered
  $tamperedFixture = $fixture.PSObject.Copy()
  $tamperedFixture.manualReviewPath = $tamperedPath
  Assert-NativeCommandFailsContaining { Invoke-VerifyManualReview $tamperedFixture } "Unexpected manual advisory review rows" "Verifier should reject dedicated-index components in the manual review path."

  $tamperedPath = Join-Path $tempRoot "terminal-without-findings.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.manualReviewPath | ConvertFrom-Json
  $audit = @($tampered.reviews | Where-Object { $_.componentName -eq "audit-lib" })[0]
  $audit.terminalDecisionAllowed = $true
  $audit | Add-Member -NotePropertyName terminalVexStatus -NotePropertyValue "fixed"
  $audit.triageStatus = "complete"
  $audit.vexStatus = "fixed"
  $audit.remediationDecision = "fixed"
  $audit | Add-Member -NotePropertyName fixedVersion -NotePropertyValue "4.0.0"
  $audit.releaseBlocking = $false
  Write-JsonFile $tamperedPath $tampered
  $tamperedFixture = $fixture.PSObject.Copy()
  $tamperedFixture.manualReviewPath = $tamperedPath
  Assert-NativeCommandFailsContaining { Invoke-VerifyManualReview $tamperedFixture } "terminalFindings" "Verifier should reject terminal grants without CVE or named finding mapping."

  $tamperedPath = Join-Path $tempRoot "terminal-one-approval.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.manualReviewPath | ConvertFrom-Json
  $tampered.reviews = @(
    $tampered.reviews[0],
    (New-TerminalFixedReview "audit-lib" "4.0.0" "packaged-runtime" @("audit-release-notes", "audit-security-audit") @(
        (New-SourceRef "audit-release-notes" "https://example.test/audit-lib/releases/4.0.0" "Official release evidence maps CVE-2099-0001 to audit-lib 4.0.0."),
        (New-SourceRef "audit-security-audit" "https://example.test/audit-lib/security/audit" "Audit finding details identify the fixed release.")
      ) @(
        (New-Finding "CVE-2099-0001" "cve" "audit-security-audit" "4.0.0")
      ) @(
        (New-Approval "security-reviewer-a" $fixture.now)
      ) $fixture.now)
  )
  Write-JsonFile $tamperedPath $tampered
  $tamperedFixture = $fixture.PSObject.Copy()
  $tamperedFixture.manualReviewPath = $tamperedPath
  Assert-NativeCommandFailsContaining { Invoke-VerifyManualReview $tamperedFixture } "two distinct reviewer approvals" "Verifier should reject terminal grants without two distinct approvals."

  $tamperedPath = Join-Path $tempRoot "terminal-approval-decision-mismatch.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.manualReviewPath | ConvertFrom-Json
  $tampered.reviews = @(
    $tampered.reviews[0],
    (New-TerminalFixedReview "audit-lib" "4.0.0" "packaged-runtime" @("audit-release-notes", "audit-security-audit") @(
        (New-SourceRef "audit-release-notes" "https://example.test/audit-lib/releases/4.0.0" "Official release evidence maps CVE-2099-0001 to audit-lib 4.0.0."),
        (New-SourceRef "audit-security-audit" "https://example.test/audit-lib/security/audit" "Audit finding details identify the fixed release.")
      ) @(
        (New-Finding "CVE-2099-0001" "cve" "audit-security-audit" "4.0.0")
      ) @(
        (New-ApprovalForDecision "security-reviewer-a" $fixture.now "approve-terminal-not_affected"),
        (New-Approval "security-reviewer-b" $fixture.now)
      ) $fixture.now)
  )
  Write-JsonFile $tamperedPath $tampered
  $tamperedFixture = $fixture.PSObject.Copy()
  $tamperedFixture.manualReviewPath = $tamperedPath
  Assert-NativeCommandFailsContaining { Invoke-VerifyManualReview $tamperedFixture } "approval decision should" "Verifier should reject terminal approvals that do not match the granted VEX status."

  $tamperedPath = Join-Path $tempRoot "stale-review.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.manualReviewPath | ConvertFrom-Json
  $tampered.reviews[0].reviewedAt = ([DateTimeOffset]::UtcNow.AddDays(-91)).ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
  Write-JsonFile $tamperedPath $tampered
  $tamperedFixture = $fixture.PSObject.Copy()
  $tamperedFixture.manualReviewPath = $tamperedPath
  Assert-NativeCommandFailsContaining { Invoke-VerifyManualReview $tamperedFixture } "reviewedAt is stale" "Verifier should reject stale manual review rows."

  $tamperedPath = Join-Path $tempRoot "public-readiness-claim.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.manualReviewPath | ConvertFrom-Json
  $tampered.publicReadinessClaim = $true
  Write-JsonFile $tamperedPath $tampered
  $tamperedFixture = $fixture.PSObject.Copy()
  $tamperedFixture.manualReviewPath = $tamperedPath
  Assert-NativeCommandFailsContaining { Invoke-VerifyManualReview $tamperedFixture } "publicReadinessClaim" "Verifier should reject public readiness overclaims."

  $tamperedDecisionPath = Join-Path $tempRoot "terminal-decision-without-grant.json"
  $tamperedDecision = Get-Content -Raw -LiteralPath $fixture.decisionInputPath | ConvertFrom-Json
  $tamperedDecision.decisions[2] = New-Decision "audit-lib" "4.0.0" "fixed" "audit-release-notes" $fixture.now
  Write-JsonFile $tamperedDecisionPath $tamperedDecision
  $tamperedFixture = $fixture.PSObject.Copy()
  $tamperedFixture.decisionInputPath = $tamperedDecisionPath
  Assert-NativeCommandFailsContaining { Invoke-VerifyManualReview $tamperedFixture } "requires a matching manual terminal review grant" "Verifier should reject terminal decisions without a matching manual grant."

  $notAffectedGrantPath = Join-Path $tempRoot "not-affected-grant.json"
  $notAffected = Get-Content -Raw -LiteralPath $fixture.manualReviewPath | ConvertFrom-Json
  $notAffected.reviews = @(
    $notAffected.reviews[0],
    (New-TerminalNotAffectedReview "audit-lib" "4.0.0" "packaged-runtime" @("audit-release-notes", "audit-security-audit") @(
        (New-SourceRef "audit-release-notes" "https://example.test/audit-lib/releases/4.0.0" "Official release evidence maps CVE-2099-0002 to audit-lib 4.0.0 non-affected scope."),
        (New-SourceRef "audit-security-audit" "https://example.test/audit-lib/security/audit" "Audit finding details identify the non-affected scope.")
      ) @(
        (New-Finding "CVE-2099-0002" "cve" "audit-security-audit" "4.0.0")
      ) @(
        (New-ApprovalForDecision "security-reviewer-a" $fixture.now "approve-terminal-not_affected"),
        (New-ApprovalForDecision "security-reviewer-b" $fixture.now "approve-terminal-not_affected")
      ) $fixture.now)
  )
  Write-JsonFile $notAffectedGrantPath $notAffected
  $notAffectedDecisionPath = Join-Path $tempRoot "not-affected-decision-mismatch.json"
  $notAffectedDecision = Get-Content -Raw -LiteralPath $fixture.decisionInputPath | ConvertFrom-Json
  $notAffectedDecision.decisions[2] = New-Decision "audit-lib" "4.0.0" "not_affected" "audit-release-notes" $fixture.now
  $notAffectedDecision.decisions[2].vexJustification = "inline_mitigations_already_exist"
  Write-JsonFile $notAffectedDecisionPath $notAffectedDecision
  $notAffectedFixture = $fixture.PSObject.Copy()
  $notAffectedFixture.manualReviewPath = $notAffectedGrantPath
  $notAffectedFixture.decisionInputPath = $notAffectedDecisionPath
  Assert-NativeCommandFailsContaining { Invoke-VerifyManualReview $notAffectedFixture } "vexJustification should" "Verifier should reject terminal not_affected decisions that diverge from the manual grant."

  $namedNoDbPath = Join-Path $tempRoot "named-finding-without-database-evidence.json"
  $namedNoDb = Get-Content -Raw -LiteralPath $fixture.manualReviewPath | ConvertFrom-Json
  $namedNoDb.reviews = @(
    $namedNoDb.reviews[0],
    (New-TerminalNotAffectedReview "audit-lib" "4.0.0" "packaged-runtime" @("audit-release-notes", "audit-security-audit") @(
        (New-SourceRef "audit-release-notes" "https://example.test/audit-lib/releases/4.0.0" "Release notes identify no applicable published vulnerability."),
        (New-SourceRef "audit-security-audit" "https://example.test/audit-lib/security/audit" "Audit source identifies no applicable published vulnerability.")
      ) @(
        (New-Finding "AUDIT-LIB-4.0.0-NO-PUBLISHED-ADVISORY" "named-security-finding" "audit-security-audit" "4.0.0")
      ) @(
        (New-ApprovalForDecision "security-reviewer-a" $fixture.now "approve-terminal-not_affected"),
        (New-ApprovalForDecision "security-reviewer-b" $fixture.now "approve-terminal-not_affected")
      ) $fixture.now)
  )
  Write-JsonFile $namedNoDbPath $namedNoDb
  $namedNoDbFixture = $fixture.PSObject.Copy()
  $namedNoDbFixture.manualReviewPath = $namedNoDbPath
  Assert-NativeCommandFailsContaining { Invoke-VerifyManualReview $namedNoDbFixture } "nvd-authority evidence" "Verifier should reject named-security-finding grants without vulnerability-database evidence."

  $namedSourcesPath = Join-Path $tempRoot "named-finding-advisory-sources.json"
  $namedSources = Get-Content -Raw -LiteralPath $fixture.advisorySourcesPath | ConvertFrom-Json
  $auditComponent = @($namedSources.components | Where-Object { $_.name -eq "audit-lib" })[0]
  $auditComponent.advisorySources += [pscustomobject]@{ id = "audit-nvd-search"; type = "vulnerability-database"; authority = "nvd"; url = "https://example.test/nvd/audit-lib"; purpose = "Fixture NVD keyword search." }
  $auditComponent.advisorySources += [pscustomobject]@{ id = "audit-osv-query"; type = "vulnerability-database"; authority = "osv"; url = "https://example.test/osv/audit-lib"; purpose = "Fixture OSV query." }
  Write-JsonFile $namedSourcesPath $namedSources
  $namedSourceIds = @("audit-release-notes", "audit-security-audit", "audit-nvd-search", "audit-osv-query")
  $namedEvidenceRefs = @(
    (New-SourceRef "audit-release-notes" "https://example.test/audit-lib/releases/4.0.0" "Release notes identify no applicable published vulnerability."),
    (New-SourceRef "audit-security-audit" "https://example.test/audit-lib/security/audit" "Audit source identifies no applicable published vulnerability."),
    (New-SourceRef "audit-nvd-search" "https://example.test/nvd/audit-lib" "NVD keyword search returns no applicable published vulnerability."),
    (New-SourceRef "audit-osv-query" "https://example.test/osv/audit-lib" "OSV query returns no applicable published vulnerability.")
  )
  $namedApprovals = @(
    (New-ApprovalForDecision "security-reviewer-a" $fixture.now "approve-terminal-not_affected"),
    (New-ApprovalForDecision "security-reviewer-b" $fixture.now "approve-terminal-not_affected")
  )
  $namedFindings = @(
    (New-Finding "AUDIT-LIB-4.0.0-NO-PUBLISHED-ADVISORY" "named-security-finding" "audit-security-audit" "4.0.0")
  )

  $namedNoDisclaimerPath = Join-Path $tempRoot "named-finding-without-disclaimer.json"
  $namedNoDisclaimer = Get-Content -Raw -LiteralPath $fixture.manualReviewPath | ConvertFrom-Json
  $namedNoDisclaimer.reviews = @(
    $namedNoDisclaimer.reviews[0],
    (New-TerminalNotAffectedReview "audit-lib" "4.0.0" "packaged-runtime" $namedSourceIds $namedEvidenceRefs $namedFindings $namedApprovals $fixture.now)
  )
  Write-JsonFile $namedNoDisclaimerPath $namedNoDisclaimer
  $namedNoDisclaimerFixture = $fixture.PSObject.Copy()
  $namedNoDisclaimerFixture.advisorySourcesPath = $namedSourcesPath
  $namedNoDisclaimerFixture.manualReviewPath = $namedNoDisclaimerPath
  Assert-NativeCommandFailsContaining { Invoke-VerifyManualReview $namedNoDisclaimerFixture } "does-not-assert impact disclaimer" "Verifier should reject named-security-finding grants without an explicit does-not-assert impact disclaimer."

  $namedGrantPath = Join-Path $tempRoot "named-finding-grant.json"
  $namedGrant = Get-Content -Raw -LiteralPath $fixture.manualReviewPath | ConvertFrom-Json
  $namedGrantImpact = "Fixture named finding review identifies no applicable published vulnerability for the locked scope and does not assert audit-lib is vulnerability-free."
  $namedGrantReview = New-TerminalNotAffectedReview "audit-lib" "4.0.0" "packaged-runtime" $namedSourceIds $namedEvidenceRefs $namedFindings $namedApprovals $fixture.now
  $namedGrantReview.impactStatement = $namedGrantImpact
  $namedGrant.reviews = @($namedGrant.reviews[0], $namedGrantReview)
  Write-JsonFile $namedGrantPath $namedGrant
  $namedGrantDecisionPath = Join-Path $tempRoot "named-finding-decision.json"
  $namedGrantDecision = Get-Content -Raw -LiteralPath $fixture.decisionInputPath | ConvertFrom-Json
  $namedGrantDecision.decisions[2] = New-Decision "audit-lib" "4.0.0" "not_affected" "audit-release-notes" $fixture.now
  $namedGrantDecision.decisions[2].impactStatement = $namedGrantImpact
  Write-JsonFile $namedGrantDecisionPath $namedGrantDecision
  $namedGrantFixture = $fixture.PSObject.Copy()
  $namedGrantFixture.advisorySourcesPath = $namedSourcesPath
  $namedGrantFixture.manualReviewPath = $namedGrantPath
  $namedGrantFixture.decisionInputPath = $namedGrantDecisionPath
  Invoke-VerifyManualReview $namedGrantFixture
  if ($LASTEXITCODE -ne 0) {
    throw "verify-native-manual-advisory-review.ps1 should accept a named-security-finding grant with nvd/osv evidence and a does-not-assert disclaimer."
  }

  $terminalPath = Join-Path $tempRoot "terminal-grant.json"
  $terminal = Get-Content -Raw -LiteralPath $fixture.manualReviewPath | ConvertFrom-Json
  $terminal.reviews = @(
    $terminal.reviews[0],
    (New-TerminalFixedReview "audit-lib" "4.0.0" "packaged-runtime" @("audit-release-notes", "audit-security-audit") @(
        (New-SourceRef "audit-release-notes" "https://example.test/audit-lib/releases/4.0.0" "Official release evidence maps CVE-2099-0001 to audit-lib 4.0.0."),
        (New-SourceRef "audit-security-audit" "https://example.test/audit-lib/security/audit" "Audit finding details identify the fixed release.")
      ) @(
        (New-Finding "CVE-2099-0001" "cve" "audit-security-audit" "4.0.0")
      ) @(
        (New-Approval "security-reviewer-a" $fixture.now),
        (New-Approval "security-reviewer-b" $fixture.now)
      ) $fixture.now)
  )
  Write-JsonFile $terminalPath $terminal
  $terminalDecisionPath = Join-Path $tempRoot "terminal-decision-with-grant.json"
  $terminalDecision = Get-Content -Raw -LiteralPath $fixture.decisionInputPath | ConvertFrom-Json
  $terminalDecision.decisions[2] = New-Decision "audit-lib" "4.0.0" "fixed" "audit-release-notes" $fixture.now
  Write-JsonFile $terminalDecisionPath $terminalDecision
  $terminalFixture = $fixture.PSObject.Copy()
  $terminalFixture.manualReviewPath = $terminalPath
  $terminalFixture.decisionInputPath = $terminalDecisionPath
  Invoke-VerifyManualReview $terminalFixture
  if ($LASTEXITCODE -ne 0) {
    throw "verify-native-manual-advisory-review.ps1 should accept a terminal fixed decision with matching finding mapping and approvals."
  }

  $packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  Assert-True ($packageJson.scripts."release:test-native-manual-advisory-review-scripts".Contains("release-native-manual-advisory-review-scripts.tests.ps1")) "Root package should expose manual native advisory review script tests."
  Assert-True ($packageJson.scripts."release:verify-native-manual-advisory-review:win32-x64".Contains("verify-native-manual-advisory-review.ps1")) "Root package should expose manual native advisory review verification."
  Assert-ContainsInOrder $packageJson.scripts."release:verify-vulnerability-decision-input:win32-x64" @(
    "verify-native-manual-advisory-review.ps1",
    "&&",
    "verify-vulnerability-decision-input.ps1"
  ) "Decision input package verifier should run the manual review gate before the decision input verifier."

  $ciWorkflow = Get-Content -Raw -LiteralPath $ciWorkflowPath
  Assert-ContainsInOrder $ciWorkflow @(
    "Release native advisory triage input script tests",
    "Release native manual advisory review script tests",
    "Release vulnerability decision input script tests",
    "Release vulnerability decision evidence script tests"
  ) "CI should run manual native advisory review script tests before vulnerability decision gates."

  $readinessVerifier = Get-Content -Raw -LiteralPath $readinessVerifierPath
  foreach ($term in @(
      "M7l2f manual native advisory terminal-review gate",
      "subversionr.security.native-manual-advisory-review.win32-x64.v1",
      "pnpm release:test-native-manual-advisory-review-scripts",
      "pnpm release:verify-native-manual-advisory-review:win32-x64"
    )) {
    Assert-True ($readinessVerifier.Contains($term)) "Release readiness verifier should require '$term'."
  }

  Write-Host "Release native manual advisory review script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

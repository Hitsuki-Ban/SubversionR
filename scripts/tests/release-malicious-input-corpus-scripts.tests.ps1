$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$generateScript = Join-Path $repoRoot "scripts\release\generate-malicious-input-corpus.ps1"
$verifyScript = Join-Path $repoRoot "scripts\release\verify-malicious-input-corpus.ps1"
$packageJsonPath = Join-Path $repoRoot "package.json"
$ciWorkflowPath = Join-Path $repoRoot ".github\workflows\ci.yml"

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
    Assert-True ($currentIndex -gt $previousIndex) "$Message '$needle' should appear after the previous checked step."
    $previousIndex = $currentIndex
  }
}

function Get-Sha256([string]$Path) {
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-JsonFile([string]$Path, [object]$Value) {
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

function New-FileWithText([string]$Path, [string]$Text) {
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  Set-Content -LiteralPath $Path -Value $Text -Encoding utf8
}

function New-SecurityEvidenceMatrix([string]$Path, [string]$Sec016Status = "release-blocker", [string]$Tst020Status = "release-blocker") {
  New-FileWithText -Path $Path -Text @"
| ID | Status | Evidence | Release Requirement |
| --- | --- | --- | --- |
| ``SEC-016`` | $Sec016Status | Malicious input corpus preflight plus focused protocol/native tests | Coverage-guided native remote-protocol fuzzing remains incomplete. |
| ``TST-020`` | $Tst020Status | Malicious input corpus preflight plus focused protocol/native tests | Security fuzz matrix remains incomplete while coverage-guided native remote-protocol fuzzing remains deferred. |
"@
}

function New-TestFile([string]$Root, [string]$RelativePath, [string[]]$TestNames) {
  $path = Join-Path $Root $RelativePath.Replace("/", [System.IO.Path]::DirectorySeparatorChar)
  $body = @($TestNames | ForEach-Object { "it(`"$_`", () => undefined);" }) -join "`n"
  New-FileWithText -Path $path -Text $body
}

function New-SkippedTestFile([string]$Root, [string]$RelativePath, [string]$TestName) {
  $path = Join-Path $Root $RelativePath.Replace("/", [System.IO.Path]::DirectorySeparatorChar)
  New-FileWithText -Path $path -Text "it.skip(`"$TestName`", () => undefined);"
}

function New-MaliciousInputCorpusFixture([string]$Root) {
  $corpusPath = Join-Path $Root "docs\security\malicious-input-corpus.win32-x64.json"
  $matrixPath = Join-Path $Root "docs\release\security-evidence-matrix.md"
  $outputPath = Join-Path $Root "target\release-evidence\subversionr-malicious-input-corpus-win32-x64.json"

  $testFilePath = Join-Path $Root "fixture-tests\securityCorpus.test.ts"
  $testFile = [System.IO.Path]::GetRelativePath($repoRoot, $testFilePath).Replace("\", "/")
  New-TestFile -Root $repoRoot -RelativePath $testFile -TestNames @(
    "rejects invalid request paths before sending",
    "redacts encoded credential urls and control characters",
    "renders malicious log messages as escaped text without synthetic section breaks",
    "rejects pending requests when inbound framing is malformed",
    "native_bridge_malicious_dav_xml_history_log_fails_without_auth_prompts_or_crash",
    "native_bridge_malicious_svn_server_response_history_log_fails_without_auth_prompts_or_crash"
  )
  New-SecurityEvidenceMatrix -Path $matrixPath

  Write-JsonFile $corpusPath ([pscustomobject]@{
      schemaVersion = 1
      schema = "subversionr.security.malicious-input-corpus.win32-x64.v1"
      target = "win32-x64"
      publicReadinessClaim = $false
      completeFuzzClaim = $false
      localCorpusOnly = $true
      evidenceBoundary = "Deterministic malicious-input corpus evidence floor; not coverage-guided fuzzing and not complete libsvn remote-protocol fuzz coverage."
      requiredTraceIds = @("SEC-016", "TST-020")
      requiredCategories = @(
        "unsafe-paths",
        "credential-url-redaction",
        "log-rendering",
        "json-rpc-server-response",
        "svn-server-response",
        "xml-dtd-payloads"
      )
      entries = @(
        [pscustomobject]@{
          id = "TS-PATH-001"
          traceIds = @("SEC-016", "TST-020")
          category = "unsafe-paths"
          boundary = "typescript-extension"
          payloadClasses = @("absolute working-copy paths", "parent-relative paths")
          status = "covered"
          test = [pscustomobject]@{
            file = $testFile
            name = "rejects invalid request paths before sending"
          }
        },
        [pscustomobject]@{
          id = "TS-REDACTION-001"
          traceIds = @("SEC-016", "TST-020")
          category = "credential-url-redaction"
          boundary = "typescript-diagnostics"
          payloadClasses = @("credentialed URLs", "authorization headers", "control characters")
          status = "covered"
          test = [pscustomobject]@{
            file = $testFile
            name = "redacts encoded credential urls and control characters"
          }
        },
        [pscustomobject]@{
          id = "TS-LOG-001"
          traceIds = @("SEC-016", "TST-020")
          category = "log-rendering"
          boundary = "typescript-history-ui"
          payloadClasses = @("CRLF log injection", "HTML-like text", "DTD-like text")
          status = "covered"
          test = [pscustomobject]@{
            file = $testFile
            name = "renders malicious log messages as escaped text without synthetic section breaks"
          }
        },
        [pscustomobject]@{
          id = "TS-RPC-001"
          traceIds = @("SEC-016", "TST-020")
          category = "json-rpc-server-response"
          boundary = "typescript-stdio-transport"
          payloadClasses = @("malformed Content-Length", "malformed JSON")
          status = "covered"
          test = [pscustomobject]@{
            file = $testFile
            name = "rejects pending requests when inbound framing is malformed"
          }
        },
        [pscustomobject]@{
          id = "NATIVE-XML-DAV-001"
          traceIds = @("SEC-016", "TST-020")
          category = "xml-dtd-payloads"
          boundary = "native-libsvn-dav"
          payloadClasses = @("DTD declarations", "external entities", "malformed DAV XML")
          status = "covered"
          test = [pscustomobject]@{
            file = $testFile
            name = "native_bridge_malicious_dav_xml_history_log_fails_without_auth_prompts_or_crash"
          }
        },
        [pscustomobject]@{
          id = "NATIVE-SVN-SERVER-001"
          traceIds = @("SEC-016", "TST-020")
          category = "svn-server-response"
          boundary = "native-libsvn-remote-protocols"
          payloadClasses = @("malformed SVN server responses", "stateful remote protocol sequences")
          status = "covered"
          test = [pscustomobject]@{
            file = $testFile
            name = "native_bridge_malicious_svn_server_response_history_log_fails_without_auth_prompts_or_crash"
          }
        },
        [pscustomobject]@{
          id = "NATIVE-REMOTE-FUZZ-001"
          traceIds = @("SEC-016", "TST-020")
          category = "svn-server-response"
          boundary = "native-libsvn-remote-protocol-fuzzing"
          payloadClasses = @("coverage-guided remote protocol fuzzing", "cross-provider libsvn server-response fuzzing")
          status = "release-blocker"
          blocker = "Coverage-guided fuzzing across libsvn remote access providers is not complete."
        }
      )
    })

  [pscustomobject]@{
    root = $Root
    corpusPath = $corpusPath
    matrixPath = $matrixPath
    outputPath = $outputPath
    testFile = Join-Path $repoRoot $testFile.Replace("/", [System.IO.Path]::DirectorySeparatorChar)
  }
}

function Invoke-GenerateMaliciousInputCorpus([object]$Fixture, [string]$OutputPath) {
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $generateScript `
    -Target win32-x64 `
    -CorpusPath $Fixture.corpusPath `
    -SecurityEvidenceMatrixPath $Fixture.matrixPath `
    -OutputPath $OutputPath
}

$tempRoot = Join-Path $repoRoot "target\tests\release-malicious-input-corpus-scripts\$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  Assert-True (Test-Path -LiteralPath $generateScript -PathType Leaf) "generate-malicious-input-corpus.ps1 should exist."
  Assert-True (Test-Path -LiteralPath $verifyScript -PathType Leaf) "verify-malicious-input-corpus.ps1 should exist."

  $fixture = New-MaliciousInputCorpusFixture $tempRoot
  Invoke-GenerateMaliciousInputCorpus -Fixture $fixture -OutputPath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "generate-malicious-input-corpus.ps1 failed with exit code $LASTEXITCODE."
  }

  $report = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  Assert-Equal "subversionr.release.malicious-input-corpus.win32-x64.v1" $report.schema "Malicious input corpus evidence should use the release schema."
  Assert-Equal "False" ([string]$report.publicReadinessClaim) "Malicious input corpus evidence must not claim public readiness."
  Assert-Equal "False" ([string]$report.completeFuzzClaim) "Malicious input corpus evidence must not claim complete fuzzing."
  Assert-Equal "True" ([string]$report.localCorpusOnly) "Malicious input corpus evidence should be local corpus only."
  Assert-Equal 7 ([int]$report.coverage.entryCount) "Coverage should count all corpus entries."
  Assert-Equal 6 ([int]$report.coverage.coveredEntryCount) "Coverage should count covered entries."
  Assert-Equal 1 ([int]$report.coverage.releaseBlockerEntryCount) "Coverage should count blocker entries."
  Assert-True (@($report.coverage.blockedCategories | Where-Object { $_ -eq "svn-server-response" }).Count -eq 1) "Remote protocol fuzz coverage must remain explicitly blocked."
  Assert-True ($report.evidenceBoundary.Contains("not coverage-guided fuzzing")) "Evidence boundary should reject fuzzing overclaims."
  Assert-Equal (Get-Sha256 $fixture.corpusPath) $report.inputs.corpus.sha256 "Evidence should bind the corpus manifest."
  Assert-Equal (Get-Sha256 $fixture.matrixPath) $report.inputs.securityEvidenceMatrix.sha256 "Evidence should bind the security evidence matrix."
  foreach ($nonClaim in @(
      "This gate is a deterministic malicious-input corpus evidence floor, not coverage-guided fuzzing.",
      "This gate does not prove complete libsvn remote-protocol fuzz coverage, filesystem normalization, or VS Code rendering coverage.",
      "This gate does not close public release readiness while any corpus entry remains release-blocker."
    )) {
    Assert-True (@($report.nonClaims | Where-Object { $_ -eq $nonClaim }).Count -eq 1) "Malicious input corpus evidence should preserve non-claim: $nonClaim"
  }

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
    -Target win32-x64 `
    -EvidencePath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "verify-malicious-input-corpus.ps1 failed with exit code $LASTEXITCODE."
  }

  Set-Content -LiteralPath $fixture.testFile -Value "it(`"different test`", () => undefined);" -Encoding utf8
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
      -Target win32-x64 `
      -EvidencePath $fixture.outputPath
  } "test declaration" "Malicious input corpus verification should fail when referenced tests drift."

  $fixture = New-MaliciousInputCorpusFixture (Join-Path $tempRoot "missing-test")
  $badCorpus = Get-Content -Raw -LiteralPath $fixture.corpusPath | ConvertFrom-Json
  $badCorpus.entries[0].test.name = "missing malicious input test"
  Write-JsonFile $fixture.corpusPath $badCorpus
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateMaliciousInputCorpus -Fixture $fixture -OutputPath $fixture.outputPath
  } "test declaration" "Malicious input corpus generation should reject missing covered test evidence."

  $fixture = New-MaliciousInputCorpusFixture (Join-Path $tempRoot "missing-blocker")
  $badCorpus = Get-Content -Raw -LiteralPath $fixture.corpusPath | ConvertFrom-Json
  $badBlockerEntry = @($badCorpus.entries | Where-Object { $_.id -eq "NATIVE-REMOTE-FUZZ-001" })[0]
  $badBlockerEntry.PSObject.Properties.Remove("blocker")
  Write-JsonFile $fixture.corpusPath $badCorpus
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateMaliciousInputCorpus -Fixture $fixture -OutputPath $fixture.outputPath
  } "blocker" "Malicious input corpus generation should require explicit blockers for uncovered categories."

  $fixture = New-MaliciousInputCorpusFixture (Join-Path $tempRoot "matrix-overclaim")
  New-SecurityEvidenceMatrix -Path $fixture.matrixPath -Sec016Status "verified"
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateMaliciousInputCorpus -Fixture $fixture -OutputPath $fixture.outputPath
  } "SEC-016" "Malicious input corpus generation should reject evidence-matrix overclaims."

  $fixture = New-MaliciousInputCorpusFixture (Join-Path $tempRoot "evidence-overclaim")
  Invoke-GenerateMaliciousInputCorpus -Fixture $fixture -OutputPath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "generate-malicious-input-corpus.ps1 failed for overclaim fixture with exit code $LASTEXITCODE."
  }
  $tamperedReportPath = Join-Path $tempRoot "tampered-overclaim.json"
  $tamperedReport = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tamperedReport.completeFuzzClaim = $true
  Write-JsonFile $tamperedReportPath $tamperedReport
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
      -Target win32-x64 `
      -EvidencePath $tamperedReportPath
  } "completeFuzzClaim" "Malicious input corpus verification should reject complete-fuzz overclaims."

  $fixture = New-MaliciousInputCorpusFixture (Join-Path $tempRoot "evidence-entry-drift")
  Invoke-GenerateMaliciousInputCorpus -Fixture $fixture -OutputPath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "generate-malicious-input-corpus.ps1 failed for entry drift fixture with exit code $LASTEXITCODE."
  }
  $tamperedReportPath = Join-Path $tempRoot "tampered-entry-drift.json"
  $tamperedReport = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tamperedReport.entries = @($tamperedReport.entries | Where-Object { $_.id -ne "NATIVE-REMOTE-FUZZ-001" })
  Write-JsonFile $tamperedReportPath $tamperedReport
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
      -Target win32-x64 `
      -EvidencePath $tamperedReportPath
  } "manifest entry" "Malicious input corpus verification should reject evidence missing a manifest blocker entry."

  $fixture = New-MaliciousInputCorpusFixture (Join-Path $tempRoot "evidence-status-drift")
  Invoke-GenerateMaliciousInputCorpus -Fixture $fixture -OutputPath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "generate-malicious-input-corpus.ps1 failed for status drift fixture with exit code $LASTEXITCODE."
  }
  $tamperedReportPath = Join-Path $tempRoot "tampered-status-drift.json"
  $tamperedReport = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $blockerEntry = @($tamperedReport.entries | Where-Object { $_.id -eq "NATIVE-REMOTE-FUZZ-001" })[0]
  $blockerEntry.status = "covered"
  $blockerEntry.test = $tamperedReport.entries[0].test
  $blockerEntry.blocker = ""
  Write-JsonFile $tamperedReportPath $tamperedReport
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
      -Target win32-x64 `
      -EvidencePath $tamperedReportPath
  } "status should match manifest" "Malicious input corpus verification should reject evidence status drift from the manifest."

  $fixture = New-MaliciousInputCorpusFixture (Join-Path $tempRoot "skipped-test")
  $badCorpus = Get-Content -Raw -LiteralPath $fixture.corpusPath | ConvertFrom-Json
  New-SkippedTestFile -Root $repoRoot -RelativePath $badCorpus.entries[0].test.file -TestName $badCorpus.entries[0].test.name
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateMaliciousInputCorpus -Fixture $fixture -OutputPath $fixture.outputPath
  } "test declaration" "Malicious input corpus generation should reject skipped tests as evidence."

  $fixture = New-MaliciousInputCorpusFixture (Join-Path $tempRoot "credential-pattern")
  $badCorpus = Get-Content -Raw -LiteralPath $fixture.corpusPath | ConvertFrom-Json
  $badCorpus.entries[0].payloadClasses += "https://alice:secret@example.invalid/repo"
  Write-JsonFile $fixture.corpusPath $badCorpus
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateMaliciousInputCorpus -Fixture $fixture -OutputPath $fixture.outputPath
  } "credentials" "Malicious input corpus generation should reject credential-like payload text."

  $fixture = New-MaliciousInputCorpusFixture (Join-Path $tempRoot "outside-output")
  $badOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "subversionr-malicious-input-corpus-outside-target.json"
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateMaliciousInputCorpus -Fixture $fixture -OutputPath $badOutputPath
  } "OutputPath must resolve inside" "Malicious input corpus generation should reject output paths outside target."

  $packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  Assert-True ($packageJson.scripts."release:test-malicious-input-corpus-scripts".Contains("release-malicious-input-corpus-scripts.tests.ps1")) "Root package should expose malicious input corpus script tests."
  Assert-True ($packageJson.scripts."release:generate-malicious-input-corpus:win32-x64".Contains("generate-malicious-input-corpus.ps1")) "Root package should expose malicious input corpus generation."
  Assert-True ($packageJson.scripts."release:verify-malicious-input-corpus:win32-x64".Contains("verify-malicious-input-corpus.ps1")) "Root package should expose malicious input corpus verification."

  $ciWorkflow = Get-Content -Raw -LiteralPath $ciWorkflowPath
  Assert-ContainsInOrder $ciWorkflow @(
    "Release malicious input corpus script tests",
    "TypeScript tests",
    "Rust tests",
    "Generate malicious input corpus preflight",
    "Verify malicious input corpus preflight"
  ) "CI should run malicious input corpus preflight after focused tests pass."

  Write-Host "Release malicious input corpus script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

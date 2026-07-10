$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$preflightGenerateScript = Join-Path $repoRoot "scripts\release\generate-vulnerability-review-preflight.ps1"
$generateScript = Join-Path $repoRoot "scripts\release\generate-live-osv-vulnerability-review.ps1"
$verifyScript = Join-Path $repoRoot "scripts\release\verify-live-osv-vulnerability-review.ps1"
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
  $Value | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $Path -Encoding utf8
}

function New-LiveOsvFixture([string]$Root, [string]$PreflightRoot) {
  $evidenceRoot = Join-Path $Root "evidence"
  $preflightEvidenceRoot = Join-Path $PreflightRoot "evidence"
  New-Item -ItemType Directory -Force -Path $evidenceRoot | Out-Null
  New-Item -ItemType Directory -Force -Path $preflightEvidenceRoot | Out-Null

  $sbomPath = Join-Path $evidenceRoot "subversionr-source-sbom.cdx.json"
  Write-JsonFile $sbomPath ([pscustomobject]@{
      bomFormat = "CycloneDX"
      specVersion = "1.6"
      metadata = [pscustomobject]@{
        component = [pscustomobject]@{
          type = "application"
          name = "SubversionR"
          version = "0.1.0"
        }
      }
      components = @(
        [pscustomobject]@{
          "bom-ref" = "pkg:npm/%40vscode/vsce@3.9.2"
          type = "library"
          name = "@vscode/vsce"
          version = "3.9.2"
          purl = "pkg:npm/%40vscode/vsce@3.9.2"
          properties = @(
            [pscustomobject]@{ name = "subversionr:componentScope"; value = "pnpm-lockfile-component" }
          )
        },
        [pscustomobject]@{
          "bom-ref" = "pkg:cargo/serde@1.0.228"
          type = "library"
          name = "serde"
          version = "1.0.228"
          purl = "pkg:cargo/serde@1.0.228"
          properties = @(
            [pscustomobject]@{ name = "subversionr:componentScope"; value = "cargo-lockfile-component" }
          )
        },
        [pscustomobject]@{
          "bom-ref" = "pkg:generic/openssl@3.5.7"
          type = "library"
          name = "openssl"
          version = "3.5.7"
          purl = "pkg:generic/openssl@3.5.7"
          properties = @(
            [pscustomobject]@{ name = "subversionr:componentScope"; value = "native-source-lock" }
          )
        }
      )
    })

  $preflightPath = Join-Path $preflightEvidenceRoot "subversionr-vulnerability-review-preflight-win32-x64.json"
  $preflightOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $preflightGenerateScript `
    -Target win32-x64 `
    -SbomPath $sbomPath `
    -OutputPath $preflightPath 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "generate-vulnerability-review-preflight.ps1 failed with exit code $LASTEXITCODE`: $($preflightOutput | Out-String)"
  }

  [pscustomobject]@{
    sbomPath = $sbomPath
    preflightPath = $preflightPath
    outputPath = Join-Path $evidenceRoot "subversionr-live-osv-vulnerability-review-win32-x64.json"
  }
}

function Start-MockOsvServer([string]$Root) {
  $serverScript = Join-Path $Root "mock-osv-server.ps1"
  $readyPath = Join-Path $Root "mock-osv-ready.json"
  $requestsPath = Join-Path $Root "mock-osv-requests.json"
  $donePath = Join-Path $Root "mock-osv-done"

  Set-Content -LiteralPath $serverScript -Encoding utf8 -Value @'
param(
  [Parameter(Mandatory = $true)]
  [int]$Port,
  [Parameter(Mandatory = $true)]
  [string]$ReadyPath,
  [Parameter(Mandatory = $true)]
  [string]$RequestsPath,
  [Parameter(Mandatory = $true)]
  [string]$DonePath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse("127.0.0.1"), $Port)
$listener.Start()
$actualPort = $listener.LocalEndpoint.Port
@{ port = $actualPort } | ConvertTo-Json | Set-Content -LiteralPath $ReadyPath -Encoding utf8
$requests = New-Object System.Collections.Generic.List[object]

function Read-HttpRequest([System.Net.Sockets.NetworkStream]$Stream) {
  $buffer = New-Object byte[] 4096
  $raw = New-Object System.Text.StringBuilder
  do {
    $read = $Stream.Read($buffer, 0, $buffer.Length)
    if ($read -le 0) {
      break
    }
    [void]$raw.Append([System.Text.Encoding]::ASCII.GetString($buffer, 0, $read))
  } while ($raw.ToString().IndexOf("`r`n`r`n", [System.StringComparison]::Ordinal) -lt 0)

  $text = $raw.ToString()
  $headerEnd = $text.IndexOf("`r`n`r`n", [System.StringComparison]::Ordinal)
  if ($headerEnd -lt 0) {
    throw "Malformed HTTP request."
  }
  $headerText = $text.Substring(0, $headerEnd)
  $body = $text.Substring($headerEnd + 4)
  $lines = $headerText -split "`r`n"
  $requestLine = $lines[0] -split " "
  $contentLength = 0
  foreach ($line in $lines) {
    if ($line -match '^Content-Length:\s*(\d+)\s*$') {
      $contentLength = [int]$Matches[1]
    }
  }
  while ([System.Text.Encoding]::UTF8.GetByteCount($body) -lt $contentLength) {
    $read = $Stream.Read($buffer, 0, $buffer.Length)
    if ($read -le 0) {
      break
    }
    $body += [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
  }
  [pscustomobject]@{
    method = $requestLine[0]
    path = $requestLine[1]
    body = $body
  }
}

function Write-HttpJsonResponse([System.Net.Sockets.NetworkStream]$Stream, [object]$Value) {
  $json = $Value | ConvertTo-Json -Depth 40 -Compress
  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $headers = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
  $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headers)
  $Stream.Write($headerBytes, 0, $headerBytes.Length)
  $Stream.Write($bodyBytes, 0, $bodyBytes.Length)
}

try {
  $queryBatchCall = 0
  while ($requests.Count -lt 5) {
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      $request = Read-HttpRequest $stream
      $requests.Add($request)
      if ($request.method -eq "POST" -and $request.path -eq "/v1/querybatch") {
        $queryBatchCall += 1
        $payload = $request.body | ConvertFrom-Json
        if ($queryBatchCall -eq 1) {
          if (@($payload.queries).Count -ne 1 -or [string]$payload.queries[0].package.purl -ne "pkg:pypi/mlflow@0.4.0") {
            throw "Expected first querybatch request to be the OSV positive control."
          }
          Write-HttpJsonResponse $stream ([pscustomobject]@{
              results = @(
                [pscustomobject]@{
                  vulns = @(
                    [pscustomobject]@{ id = "GHSA-positive-control"; modified = "2026-01-01T03:04:05Z" }
                  )
                }
              )
            })
        } elseif ($queryBatchCall -eq 2) {
          if (@($payload.queries).Count -ne 2) {
            throw "Expected second querybatch request to contain 2 project queries."
          }
          Write-HttpJsonResponse $stream ([pscustomobject]@{
              results = @(
                [pscustomobject]@{
                  vulns = @(
                    [pscustomobject]@{ id = "GHSA-test-one"; modified = "2026-01-02T03:04:05Z" }
                  )
                  next_page_token = "page-2-token"
                },
                [pscustomobject]@{
                  vulns = @()
                }
              )
            })
        } else {
          if (@($payload.queries).Count -ne 1 -or [string]$payload.queries[0].page_token -ne "page-2-token") {
            throw "Expected paginated querybatch request for the first query only."
          }
          Write-HttpJsonResponse $stream ([pscustomobject]@{
              results = @(
                [pscustomobject]@{
                  vulns = @(
                    [pscustomobject]@{ id = "CVE-2026-0001"; modified = "2026-01-03T03:04:05Z" }
                  )
                }
              )
            })
        }
      } elseif ($request.method -eq "GET" -and $request.path -eq "/v1/vulns/GHSA-test-one") {
        Write-HttpJsonResponse $stream ([pscustomobject]@{
            schema_version = "1.7.5"
            id = "GHSA-test-one"
            modified = "2026-01-02T03:04:05Z"
            published = "2026-01-01T00:00:00Z"
            aliases = @()
            summary = "Fixture npm advisory"
            severity = @(
              [pscustomobject]@{ type = "CVSS_V3"; score = "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H" }
            )
            affected = @(
              [pscustomobject]@{
                package = [pscustomobject]@{ ecosystem = "npm"; name = "@vscode/vsce"; purl = "pkg:npm/%40vscode/vsce" }
              }
            )
            references = @(
              [pscustomobject]@{ type = "ADVISORY"; url = "https://osv.dev/vulnerability/GHSA-test-one" }
            )
          })
      } elseif ($request.method -eq "GET" -and $request.path -eq "/v1/vulns/CVE-2026-0001") {
        Write-HttpJsonResponse $stream ([pscustomobject]@{
            schema_version = "1.7.5"
            id = "CVE-2026-0001"
            modified = "2026-01-03T03:04:05Z"
            published = "2026-01-02T00:00:00Z"
            aliases = @("GHSA-alias-two")
            summary = "Fixture paginated advisory"
            affected = @(
              [pscustomobject]@{
                package = [pscustomobject]@{ ecosystem = "npm"; name = "@vscode/vsce"; purl = "pkg:npm/%40vscode/vsce" }
              }
            )
            references = @(
              [pscustomobject]@{ type = "WEB"; url = "https://osv.dev/vulnerability/CVE-2026-0001" }
            )
          })
      } else {
        throw "Unexpected request $($request.method) $($request.path)."
      }
    } finally {
      $client.Close()
    }
  }
} finally {
  $requests | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $RequestsPath -Encoding utf8
  New-Item -ItemType File -Path $DonePath -Force | Out-Null
  $listener.Stop()
}
'@

  $port = 0
  $job = Start-Job -ScriptBlock {
    param($ScriptPath, $Port, $ReadyPath, $RequestsPath, $DonePath)
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -Port $Port -ReadyPath $ReadyPath -RequestsPath $RequestsPath -DonePath $DonePath
  } -ArgumentList $serverScript, $port, $readyPath, $requestsPath, $donePath

  $deadline = [DateTime]::UtcNow.AddSeconds(20)
  while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
    if ($job.State -ne "Running") {
      Receive-Job -Job $job | Out-String | Write-Host
      throw "Mock OSV server exited before writing readiness."
    }
    if ([DateTime]::UtcNow -gt $deadline) {
      throw "Timed out waiting for mock OSV server readiness."
    }
    Start-Sleep -Milliseconds 100
  }
  $ready = Get-Content -Raw -LiteralPath $readyPath | ConvertFrom-Json
  [pscustomobject]@{
    job = $job
    queryBatchEndpoint = "http://127.0.0.1:$($ready.port)/v1/querybatch"
    vulnEndpointBase = "http://127.0.0.1:$($ready.port)/v1/vulns"
    requestsPath = $requestsPath
    donePath = $donePath
  }
}

function Stop-MockOsvServer([object]$Server) {
  if ($null -eq $Server) {
    return
  }
  Wait-Job -Job $Server.job -Timeout 10 | Out-Null
  if ($Server.job.State -ne "Completed") {
    Stop-Job -Job $Server.job -ErrorAction SilentlyContinue
  }
  Receive-Job -Job $Server.job | Out-Null
  Remove-Job -Job $Server.job -Force -ErrorAction SilentlyContinue
}

$tempId = [Guid]::NewGuid().ToString('N')
$tempRoot = Join-Path $repoRoot "target\tests\release-live-osv-review-scripts\$tempId"
$preflightTempRoot = Join-Path $repoRoot "target\tests\release-vulnerability-review-scripts\live-osv-$tempId"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
$server = $null

try {
  Assert-True (Test-Path -LiteralPath $generateScript -PathType Leaf) "generate-live-osv-vulnerability-review.ps1 should exist."
  Assert-True (Test-Path -LiteralPath $verifyScript -PathType Leaf) "verify-live-osv-vulnerability-review.ps1 should exist."

  $fixture = New-LiveOsvFixture -Root $tempRoot -PreflightRoot $preflightTempRoot
  $server = Start-MockOsvServer $tempRoot

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $generateScript `
    -Target win32-x64 `
    -PreflightPath $fixture.preflightPath `
    -OutputPath $fixture.outputPath `
    -OsvQueryBatchEndpoint $server.queryBatchEndpoint `
    -OsvVulnEndpointBase $server.vulnEndpointBase
  if ($LASTEXITCODE -ne 0) {
    throw "generate-live-osv-vulnerability-review.ps1 failed with exit code $LASTEXITCODE."
  }
  Stop-MockOsvServer $server
  $server = $null

  $report = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  Assert-Equal "subversionr.release.vulnerability-review-osv.win32-x64.v1" $report.schema "Live OSV review should use the M7l2a schema."
  Assert-Equal "False" ([string]$report.publicReadinessClaim) "Live OSV review must not claim public readiness."
  Assert-Equal "False" ([string]$report.vulnerabilityReviewComplete) "Live OSV review must not claim full vulnerability review completion."
  Assert-Equal "True" ([string]$report.osv.liveQueryPerformed) "Live OSV review should record live query execution."
  Assert-Equal "True" ([string]$report.osv.resultRecorded) "Live OSV review should record OSV results."
  Assert-Equal "queried" ([string]$report.osv.status) "Live OSV status should be queried."
  Assert-Equal "passed" ([string]$report.osv.positiveControl.status) "Live OSV review should require a passing OSV positive control."
  Assert-Equal 1 ([int]$report.osv.positiveControl.vulnerabilityCount) "The fixture positive control should record one OSV finding."
  Assert-Equal "True" ([string]$report.osv.paginationComplete) "Live OSV review should record pagination completion."
  Assert-Equal 0 ([int]$report.osv.unresolvedPageTokenCount) "Live OSV review should record zero unresolved pagination tokens."
  Assert-Equal 2 ([int]$report.osv.queriedComponentCount) "The fixture should query two npm/Cargo components."
  Assert-Equal 2 ([int]$report.osv.vulnerabilityIdCount) "The fixture should record two unique vulnerability IDs."
  Assert-Equal 2 ([int]$report.osv.detailCount) "The fixture should fetch details for both vulnerability IDs."
  Assert-Equal 1 ([int]$report.osv.paginationRequestCount) "The fixture should record one pagination request."
  Assert-Equal 1 ([int]$report.manualReview.componentCount) "Native generic components should remain in manual review."
  Assert-Equal "True" ([string]$report.manualReview.releaseBlocking) "Native manual review should remain release-blocking."
  Assert-Equal (Get-Sha256 $fixture.preflightPath) $report.evidence.preflight.sha256 "Live OSV review should bind the preflight SHA256."

  $preflight = Get-Content -Raw -LiteralPath $fixture.preflightPath | ConvertFrom-Json
  $firstResult = @($report.osv.results | Where-Object { [int]$_.queryIndex -eq 0 })[0]
  Assert-Equal ([string]$preflight.osv.queries[0].package.purl) ([string]$firstResult.query.package.purl) "The first ordered OSV result should stay bound to the first preflight purl."
  Assert-True (@($firstResult.vulnerabilityIds | Where-Object { $_ -eq "GHSA-test-one" }).Count -eq 1) "The first result should include the direct OSV finding."
  Assert-True (@($firstResult.vulnerabilityIds | Where-Object { $_ -eq "CVE-2026-0001" }).Count -eq 1) "The first result should include the paginated OSV finding."
  $secondResult = @($report.osv.results | Where-Object { [int]$_.queryIndex -eq 1 })[0]
  Assert-Equal ([string]$preflight.osv.queries[1].package.purl) ([string]$secondResult.query.package.purl) "The second ordered OSV result should stay bound to the second preflight purl."
  Assert-Equal 0 @($secondResult.vulnerabilityIds).Count "The second fixture result should have no OSV findings."
  Assert-True (@($report.osv.vulnerabilityDetails | Where-Object { $_.id -eq "GHSA-test-one" }).Count -eq 1) "OSV details should include GHSA-test-one."
  Assert-True (@($report.review.findings | Where-Object { $_.id -eq "CVE-2026-0001" -and $_.triageStatus -eq "pending" }).Count -eq 1) "OSV findings should require pending triage."

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
    -Target win32-x64 `
    -EvidencePath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "verify-live-osv-vulnerability-review.ps1 failed with exit code $LASTEXITCODE."
  }

  $badOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "subversionr-live-osv-outside-target.json"
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $generateScript `
      -Target win32-x64 `
      -PreflightPath $fixture.preflightPath `
      -OutputPath $badOutputPath `
      -OsvQueryBatchEndpoint "http://127.0.0.1:1/v1/querybatch" `
      -OsvVulnEndpointBase "http://127.0.0.1:1/v1/vulns"
  } "OutputPath must resolve inside" "Live OSV generation should reject output paths outside target."

  $tamperedPath = Join-Path $tempRoot "tampered-complete.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tampered.vulnerabilityReviewComplete = $true
  $tampered.review.triageComplete = $true
  $tampered.review.remediationApproved = $true
  $tampered.review.vexDecisionsComplete = $true
  Write-JsonFile $tamperedPath $tampered
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript -Target win32-x64 -EvidencePath $tamperedPath
  } "vulnerabilityReviewComplete" "Verification should reject vulnerability review completion overclaims."

  $tamperedPath = Join-Path $tempRoot "tampered-preflight-hash.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tampered.evidence.preflight.sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  Write-JsonFile $tamperedPath $tampered
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript -Target win32-x64 -EvidencePath $tamperedPath
  } "Preflight SHA256" "Verification should reject preflight hash drift."

  $tamperedPath = Join-Path $tempRoot "tampered-order.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tampered.osv.results[0].query.package.purl = "pkg:npm/not-the-preflight-purl@0.0.0"
  Write-JsonFile $tamperedPath $tampered
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript -Target win32-x64 -EvidencePath $tamperedPath
  } "ordered OSV result" "Verification should reject OSV result/preflight order drift."

  $tamperedPath = Join-Path $tempRoot "tampered-secret.json"
  $tampered = Get-Content -Raw -LiteralPath $fixture.outputPath
  $tampered = $tampered -replace '"summary": "Fixture npm advisory"', '"summary": "Authorization: Bearer fake-token"'
  Set-Content -LiteralPath $tamperedPath -Value $tampered -Encoding utf8
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript -Target win32-x64 -EvidencePath $tamperedPath
  } "must not record credentials" "Verification should reject credential-like evidence text."

  $packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  Assert-True ($packageJson.scripts."release:test-live-osv-review-scripts".Contains("release-live-osv-review-scripts.tests.ps1")) "Root package should expose live OSV script tests."
  Assert-True ($packageJson.scripts."release:generate-live-osv-review:win32-x64".Contains("generate-live-osv-vulnerability-review.ps1")) "Root package should expose live OSV review generation."
  Assert-True ($packageJson.scripts."release:verify-live-osv-review:win32-x64".Contains("verify-live-osv-vulnerability-review.ps1")) "Root package should expose live OSV review verification."

  $ciWorkflow = Get-Content -Raw -LiteralPath $ciWorkflowPath
  Assert-ContainsInOrder $ciWorkflow @(
    "Release vulnerability review script tests",
    "Release live OSV review script tests",
    "Generate vulnerability review preflight",
    "Verify vulnerability review preflight",
    "Generate live OSV vulnerability review",
    "Verify live OSV vulnerability review"
  ) "CI should run live OSV tests and the live gate after the preflight gate."

  $readinessVerifier = Get-Content -Raw -LiteralPath $readinessVerifierPath
  foreach ($term in @(
      "M7l2a live OSV vulnerability review evidence gate",
      "subversionr.release.vulnerability-review-osv.win32-x64.v1",
      "pnpm release:test-live-osv-review-scripts",
      "pnpm release:generate-live-osv-review:win32-x64",
      "pnpm release:verify-live-osv-review:win32-x64"
    )) {
    Assert-True ($readinessVerifier.Contains($term)) "Release readiness verifier should require '$term'."
  }

  Write-Host "Release live OSV vulnerability review script tests passed."
}
finally {
  Stop-MockOsvServer $server
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $preflightTempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$generateScript = Join-Path $repoRoot "scripts\release\generate-native-artifact-map-preflight.ps1"
$verifyScript = Join-Path $repoRoot "scripts\release\verify-native-artifact-map-preflight.ps1"
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

function New-ArtifactRecord([string]$PackageRoot, [string]$RelativePath, [string]$Role, [string]$Content) {
  $filePath = Join-Path $PackageRoot $RelativePath.Replace("/", [System.IO.Path]::DirectorySeparatorChar)
  New-FileWithText -Path $filePath -Text $Content
  [pscustomobject]@{
    role = $Role
    path = $RelativePath
    size = (Get-Item -LiteralPath $filePath).Length
    sha256 = Get-Sha256 $filePath
  }
}

function New-NativeArtifactMapFixture([string]$Root) {
  $sourceLockPath = Join-Path $Root "native\sources.lock.json"
  $artifactMapPath = Join-Path $Root "docs\release\native-artifact-map.win32-x64.json"
  $packageRoot = Join-Path $Root "target\vscode-package\subversionr-win32-x64"
  $resourceRoot = Join-Path $packageRoot "resources\backend\win32-x64"
  $backendManifestPath = Join-Path $resourceRoot "subversionr-backend-package-manifest.json"
  $evidenceRoot = Join-Path $Root "target\release-evidence"
  $vsixEvidencePath = Join-Path $evidenceRoot "subversionr-vsix-package-win32-x64.json"
  $outputPath = Join-Path $evidenceRoot "subversionr-native-artifact-map-preflight-win32-x64.json"

  $sources = @(
    [pscustomobject]@{
      name = "component-a"
      version = "1.0.0"
      license = "MIT"
      url = "https://example.invalid/component-a-1.0.0.tar.gz"
      sha512 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    },
    [pscustomobject]@{
      name = "component-b"
      version = "2.0.0"
      license = "Apache-2.0"
      url = "https://example.invalid/component-b-2.0.0.tar.gz"
      sha512 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      sha256 = "2222222222222222222222222222222222222222222222222222222222222222"
    },
    [pscustomobject]@{
      name = "component-c"
      version = "3.0.0"
      license = "BSD-3-Clause"
      url = "https://example.invalid/component-c-3.0.0.tar.gz"
      sha512 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    }
  )
  Write-JsonFile $sourceLockPath ([pscustomobject]@{ sources = $sources })

  $artifacts = @()
  $artifacts += New-ArtifactRecord -PackageRoot $packageRoot -RelativePath "resources/backend/win32-x64/subversionr-daemon.exe" -Role "sidecar" -Content "sidecar fixture"
  $artifacts += New-ArtifactRecord -PackageRoot $packageRoot -RelativePath "resources/backend/win32-x64/subversionr_svn_bridge.dll" -Role "bridge" -Content "bridge fixture"
  $artifacts += New-ArtifactRecord -PackageRoot $packageRoot -RelativePath "resources/backend/win32-x64/libcomponent-a.dll" -Role "nativeDependency" -Content "component-a runtime"

  Write-JsonFile $backendManifestPath ([pscustomobject]@{
      schemaVersion = 1
      schema = "subversionr.vscode.backend-package.win32-x64.v1"
      layoutKind = "staged-vsix-layout"
      target = "win32-x64"
      vsceTarget = "win32-x64"
      architecture = "x64"
      configuration = "Release"
      extension = [pscustomobject]@{
        id = "subversionr"
        displayName = "SubversionR"
        version = "0.1.0"
      }
      resourceRoot = "resources/backend/win32-x64"
      artifacts = $artifacts
      sourceLocks = @($sources | ForEach-Object {
          [pscustomobject]@{
            name = $_.name
            version = $_.version
            license = $_.license
            sha512 = $_.sha512
          }
        })
    })

  Write-JsonFile $vsixEvidencePath ([pscustomobject]@{
      schemaVersion = 1
      schema = "subversionr.release.vsix-package.win32-x64.v1"
      publicReadinessClaim = $false
      target = "win32-x64"
      extension = [pscustomobject]@{
        id = "hitsuki-ban.subversionr"
        displayName = "SubversionR"
        version = "0.1.0"
      }
      inputs = [pscustomobject]@{
        packageRoot = $packageRoot
      }
      vsix = [pscustomobject]@{
        path = (Join-Path $evidenceRoot "fixture.vsix")
        relativePath = "target/release-evidence/fixture.vsix"
        size = 0
        sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
      }
      assertions = @(
        "packaged backend sidecar, bridge, and manifest are present",
        "publicReadinessClaim remains false"
      )
    })

  Write-JsonFile $artifactMapPath ([pscustomobject]@{
      schemaVersion = 1
      schema = "subversionr.release.native-artifact-map.win32-x64.v1"
      target = "win32-x64"
      packageModes = @("packaged-runtime", "static-link-input", "fixture-runtime")
      components = @(
        [pscustomobject]@{
          sourceName = "component-a"
          expectedVersion = "1.0.0"
          packageMode = "packaged-runtime"
          requiredArtifactPaths = @("resources/backend/win32-x64/libcomponent-a.dll")
          artifactPathPatterns = @("resources/backend/win32-x64/libcomponent-a.dll")
          rationale = "Fixture runtime component with a shipped DLL."
        },
        [pscustomobject]@{
          sourceName = "component-b"
          expectedVersion = "2.0.0"
          packageMode = "static-link-input"
          carrierArtifactPaths = @("resources/backend/win32-x64/libcomponent-a.dll")
          nonShippingReason = "Static link input represented by the carrier artifact for this fixture."
          rationale = "Fixture static-link component without a standalone DLL."
        },
        [pscustomobject]@{
          sourceName = "component-c"
          expectedVersion = "3.0.0"
          packageMode = "fixture-runtime"
          nonShippingReason = "Built only for release fixture coverage and not shipped in the VSIX."
          rationale = "Fixture-only component."
        }
      )
    })

  [pscustomobject]@{
    root = $Root
    sourceLockPath = $sourceLockPath
    artifactMapPath = $artifactMapPath
    packageRoot = $packageRoot
    backendManifestPath = $backendManifestPath
    vsixEvidencePath = $vsixEvidencePath
    outputPath = $outputPath
    shippedArtifactPath = Join-Path $packageRoot "resources\backend\win32-x64\libcomponent-a.dll"
  }
}

function Invoke-GenerateNativeArtifactMap([object]$Fixture, [string]$OutputPath) {
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $generateScript `
    -Target win32-x64 `
    -SourceLockPath $Fixture.sourceLockPath `
    -ArtifactMapPath $Fixture.artifactMapPath `
    -BackendManifestPath $Fixture.backendManifestPath `
    -VsixEvidencePath $Fixture.vsixEvidencePath `
    -OutputPath $OutputPath
}

$tempRoot = Join-Path $repoRoot "target\tests\release-native-artifact-map-scripts\$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  Assert-True (Test-Path -LiteralPath $generateScript -PathType Leaf) "generate-native-artifact-map-preflight.ps1 should exist."
  Assert-True (Test-Path -LiteralPath $verifyScript -PathType Leaf) "verify-native-artifact-map-preflight.ps1 should exist."

  $fixture = New-NativeArtifactMapFixture $tempRoot
  Invoke-GenerateNativeArtifactMap -Fixture $fixture -OutputPath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "generate-native-artifact-map-preflight.ps1 failed with exit code $LASTEXITCODE."
  }

  $report = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  Assert-Equal "subversionr.release.native-artifact-map-preflight.win32-x64.v1" $report.schema "Native artifact map preflight evidence should use the M7 source-lock artifact map schema."
  Assert-Equal "False" ([string]$report.publicReadinessClaim) "Native artifact map preflight must not claim public readiness."
  Assert-Equal "False" ([string]$report.reproducibleBuildClaim) "Native artifact map preflight must not claim reproducible builds."
  Assert-Equal "False" ([string]$report.signedAttestationClaim) "Native artifact map preflight must not claim signed attestations."
  Assert-Equal "win32-x64" $report.target "Native artifact map preflight should record the target."
  Assert-True ($report.evidenceBoundary.Contains("does not attest reproducibility")) "Evidence boundary should reject reproducible-build overclaims."
  Assert-True ($report.evidenceBoundary.Contains("post-gate integrity")) "Evidence boundary should reject post-gate integrity overclaims."
  Assert-Equal 3 ([int]$report.coverage.sourceLockComponentCount) "Coverage should count source-lock components."
  Assert-Equal 3 ([int]$report.coverage.mappedComponentCount) "Coverage should count mapped components."
  Assert-Equal 0 (@($report.coverage.unmappedSourceComponents).Count) "Coverage should have no unmapped source components."
  Assert-Equal 0 (@($report.coverage.extraMappedComponents).Count) "Coverage should have no extra mapped components."
  Assert-Equal 0 (@($report.coverage.unmappedNativeDependencyArtifacts).Count) "Coverage should have no unmapped native dependency artifacts."
  Assert-Equal 2 ([int]$report.coverage.firstPartyArtifactCount) "Coverage should count sidecar/bridge first-party artifacts outside native source-lock mapping."
  Assert-Equal "packaged-runtime" $report.componentMappings[0].packageMode "Component A should be packaged runtime."
  Assert-Equal "static-link-input" $report.componentMappings[1].packageMode "Component B should be static-link input."
  Assert-Equal "fixture-runtime" $report.componentMappings[2].packageMode "Component C should be fixture runtime."
  Assert-Equal (Get-Sha256 $fixture.sourceLockPath) $report.inputs.sourceLock.sha256 "Evidence should bind the source lock."
  Assert-Equal (Get-Sha256 $fixture.artifactMapPath) $report.inputs.artifactMap.sha256 "Evidence should bind the artifact map input."
  Assert-Equal (Get-Sha256 $fixture.backendManifestPath) $report.inputs.backendManifest.sha256 "Evidence should bind the backend manifest."
  Assert-Equal (Get-Sha256 $fixture.vsixEvidencePath) $report.inputs.vsixEvidence.sha256 "Evidence should bind the VSIX package evidence."
  Assert-Equal (Get-Sha256 $fixture.shippedArtifactPath) $report.componentMappings[0].packagedArtifacts[0].sha256 "Evidence should bind shipped artifact bytes."
  foreach ($nonClaim in @(
      "This gate does not prove reproducible builds.",
      "This gate does not prove the staged binaries were compiled from the locked source archives.",
      "This gate does not prove signing, notarization, or GitHub artifact attestation publication.",
      "This gate does not prove post-gate artifact integrity."
    )) {
    Assert-True (@($report.nonClaims | Where-Object { $_ -eq $nonClaim }).Count -eq 1) "Native artifact map preflight should preserve non-claim: $nonClaim"
  }

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
    -Target win32-x64 `
    -EvidencePath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "verify-native-artifact-map-preflight.ps1 failed with exit code $LASTEXITCODE."
  }

  Set-Content -LiteralPath $fixture.shippedArtifactPath -Value "tampered runtime" -Encoding utf8
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
      -Target win32-x64 `
      -EvidencePath $fixture.outputPath
  } "size" "Native artifact map verification should fail when staged artifact bytes drift."

  $fixture = New-NativeArtifactMapFixture (Join-Path $tempRoot "missing-map-entry")
  $badMap = Get-Content -Raw -LiteralPath $fixture.artifactMapPath | ConvertFrom-Json
  $badMap.components = @($badMap.components | Where-Object { $_.sourceName -ne "component-c" })
  Write-JsonFile $fixture.artifactMapPath $badMap
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateNativeArtifactMap -Fixture $fixture -OutputPath $fixture.outputPath
  } "unmapped source-lock components" "Native artifact map generation should reject missing source-lock coverage."

  $fixture = New-NativeArtifactMapFixture (Join-Path $tempRoot "extra-map-entry")
  $badMap = Get-Content -Raw -LiteralPath $fixture.artifactMapPath | ConvertFrom-Json
  $badMap.components += [pscustomobject]@{
    sourceName = "component-extra"
    expectedVersion = "9.9.9"
    packageMode = "fixture-runtime"
    nonShippingReason = "Extra fixture component."
    rationale = "Should fail because the source lock does not contain it."
  }
  Write-JsonFile $fixture.artifactMapPath $badMap
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateNativeArtifactMap -Fixture $fixture -OutputPath $fixture.outputPath
  } "extra mapped components" "Native artifact map generation should reject extra map entries."

  $fixture = New-NativeArtifactMapFixture (Join-Path $tempRoot "missing-artifact")
  $badMap = Get-Content -Raw -LiteralPath $fixture.artifactMapPath | ConvertFrom-Json
  $badMap.components[0].requiredArtifactPaths = @("resources/backend/win32-x64/missing.dll")
  Write-JsonFile $fixture.artifactMapPath $badMap
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateNativeArtifactMap -Fixture $fixture -OutputPath $fixture.outputPath
  } "required artifact" "Native artifact map generation should reject missing required artifacts."

  $fixture = New-NativeArtifactMapFixture (Join-Path $tempRoot "unknown-mode")
  $badMap = Get-Content -Raw -LiteralPath $fixture.artifactMapPath | ConvertFrom-Json
  $badMap.components[0].packageMode = "inferred-runtime"
  Write-JsonFile $fixture.artifactMapPath $badMap
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateNativeArtifactMap -Fixture $fixture -OutputPath $fixture.outputPath
  } "packageMode" "Native artifact map generation should reject unknown package modes."

  $fixture = New-NativeArtifactMapFixture (Join-Path $tempRoot "missing-reason")
  $badMap = Get-Content -Raw -LiteralPath $fixture.artifactMapPath | ConvertFrom-Json
  $badMap.components[1].PSObject.Properties.Remove("nonShippingReason")
  Write-JsonFile $fixture.artifactMapPath $badMap
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateNativeArtifactMap -Fixture $fixture -OutputPath $fixture.outputPath
  } "nonShippingReason" "Native artifact map generation should reject non-shipping modes without explicit reasons."

  $fixture = New-NativeArtifactMapFixture (Join-Path $tempRoot "overclaim")
  Invoke-GenerateNativeArtifactMap -Fixture $fixture -OutputPath $fixture.outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "generate-native-artifact-map-preflight.ps1 failed for overclaim fixture with exit code $LASTEXITCODE."
  }
  $tamperedReportPath = Join-Path $tempRoot "tampered-overclaim.json"
  $tamperedReport = Get-Content -Raw -LiteralPath $fixture.outputPath | ConvertFrom-Json
  $tamperedReport.reproducibleBuildClaim = $true
  $tamperedReport.nonClaims = @($tamperedReport.nonClaims | Where-Object { $_ -ne "This gate does not prove reproducible builds." })
  Write-JsonFile $tamperedReportPath $tamperedReport
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
      -Target win32-x64 `
      -EvidencePath $tamperedReportPath
  } "reproducibleBuildClaim" "Native artifact map verification should reject reproducible-build overclaims."

  $fixture = New-NativeArtifactMapFixture (Join-Path $tempRoot "outside-output")
  $badOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "subversionr-native-artifact-map-outside-target.json"
  Assert-NativeCommandFailsContaining {
    Invoke-GenerateNativeArtifactMap -Fixture $fixture -OutputPath $badOutputPath
  } "OutputPath must resolve inside" "Native artifact map generation should reject output paths outside target."

  $packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  Assert-True ($packageJson.scripts."release:test-native-artifact-map-scripts".Contains("release-native-artifact-map-scripts.tests.ps1")) "Root package should expose native artifact map script tests."
  Assert-True ($packageJson.scripts."release:generate-native-artifact-map:win32-x64".Contains("generate-native-artifact-map-preflight.ps1")) "Root package should expose native artifact map generation."
  Assert-True ($packageJson.scripts."release:verify-native-artifact-map:win32-x64".Contains("verify-native-artifact-map-preflight.ps1")) "Root package should expose native artifact map verification."

  $ciWorkflow = Get-Content -Raw -LiteralPath $ciWorkflowPath
  Assert-ContainsInOrder $ciWorkflow @(
    "Release native artifact map script tests",
    "Package VS Code win32-x64 VSIX",
    "Generate native artifact map preflight",
    "Verify native artifact map preflight",
    "Generate release provenance preflight"
  ) "CI should run native artifact map preflight after VSIX evidence exists and before provenance."

  Write-Host "Release native artifact map preflight script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

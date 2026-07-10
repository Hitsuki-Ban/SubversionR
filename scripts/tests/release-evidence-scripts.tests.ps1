$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$generateSbomScript = Join-Path $repoRoot "scripts\release\generate-source-sbom.ps1"
$generateNoticeScript = Join-Path $repoRoot "scripts\release\generate-third-party-notice.ps1"
$verifyEvidenceScript = Join-Path $repoRoot "scripts\release\verify-release-evidence.ps1"
$packageJsonPath = Join-Path $repoRoot "package.json"
$ciWorkflowPath = Join-Path $repoRoot ".github\workflows\ci.yml"
$extensionPackagePath = Join-Path $repoRoot "packages\vscode-extension\package.json"
$cargoWorkspacePath = Join-Path $repoRoot "Cargo.toml"
$cargoLockPath = Join-Path $repoRoot "Cargo.lock"
$pnpmLockPath = Join-Path $repoRoot "pnpm-lock.yaml"
$nativeBridgeCMakePath = Join-Path $repoRoot "native\svn-bridge\CMakeLists.txt"

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

$tempRoot = Join-Path $repoRoot "target\tests\release-evidence-scripts\$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  Assert-True (Test-Path -LiteralPath $generateSbomScript -PathType Leaf) "generate-source-sbom.ps1 should exist."
  Assert-True (Test-Path -LiteralPath $generateNoticeScript -PathType Leaf) "generate-third-party-notice.ps1 should exist."
  Assert-True (Test-Path -LiteralPath $verifyEvidenceScript -PathType Leaf) "verify-release-evidence.ps1 should exist."

  $fixtureSourceLock = Join-Path $tempRoot "sources.lock.json"
  @'
{
  "sources": [
    {
      "name": "apache-subversion",
      "version": "1.14.5",
      "license": "Apache-2.0",
      "licenseUrl": "https://www.apache.org/licenses/LICENSE-2.0",
      "url": "https://downloads.apache.org/subversion/subversion-1.14.5.zip",
      "sha512": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "signatureUrl": "https://downloads.apache.org/subversion/subversion-1.14.5.zip.asc",
      "keysUrl": "https://downloads.apache.org/subversion/KEYS"
    },
    {
      "name": "pcre2",
      "version": "10.47",
      "license": "BSD-3-Clause WITH PCRE2-exception",
      "licenseUrl": "https://github.com/PCRE2Project/pcre2/blob/pcre2-10.47/LICENCE.md",
      "url": "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.47/pcre2-10.47.tar.gz",
      "sha512": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    }
  ]
}
'@ | Set-Content -LiteralPath $fixtureSourceLock -NoNewline

  $outputRoot = Join-Path $tempRoot "evidence"
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $generateSbomScript `
    -SourceLockPath $fixtureSourceLock `
    -ExtensionPackagePath $extensionPackagePath `
    -CargoWorkspacePath $cargoWorkspacePath `
    -CargoLockPath $cargoLockPath `
    -PnpmLockPath $pnpmLockPath `
    -NativeBridgeCMakePath $nativeBridgeCMakePath `
    -OutputPath (Join-Path $outputRoot "subversionr-source-sbom.cdx.json")
  if ($LASTEXITCODE -ne 0) {
    throw "generate-source-sbom.ps1 failed with exit code $LASTEXITCODE."
  }

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $generateNoticeScript `
    -SourceLockPath $fixtureSourceLock `
    -ExtensionPackagePath $extensionPackagePath `
    -CargoWorkspacePath $cargoWorkspacePath `
    -CargoLockPath $cargoLockPath `
    -PnpmLockPath $pnpmLockPath `
    -NativeBridgeCMakePath $nativeBridgeCMakePath `
    -OutputPath (Join-Path $outputRoot "THIRD-PARTY-NOTICES.md")
  if ($LASTEXITCODE -ne 0) {
    throw "generate-third-party-notice.ps1 failed with exit code $LASTEXITCODE."
  }

  $sbomPath = Join-Path $outputRoot "subversionr-source-sbom.cdx.json"
  $noticePath = Join-Path $outputRoot "THIRD-PARTY-NOTICES.md"
  Assert-True (Test-Path -LiteralPath $sbomPath -PathType Leaf) "SBOM generation should create a CycloneDX JSON file."
  Assert-True (Test-Path -LiteralPath $noticePath -PathType Leaf) "NOTICE generation should create a Markdown notice file."

  $sbom = Get-Content -Raw -LiteralPath $sbomPath | ConvertFrom-Json
  Assert-Equal "CycloneDX" $sbom.bomFormat "SBOM should use CycloneDX."
  Assert-Equal "1.6" $sbom.specVersion "SBOM should use CycloneDX 1.6."
  Assert-Equal "SubversionR" $sbom.metadata.component.name "SBOM metadata should describe SubversionR."
  Assert-Equal "application" $sbom.metadata.component.type "SBOM root component should be an application."
  $sourceLockSha256 = (Get-FileHash -LiteralPath $fixtureSourceLock -Algorithm SHA256).Hash.ToLowerInvariant()
  $metadataHash = @($sbom.metadata.properties | Where-Object { $_.name -eq "subversionr:sourceLockSha256" })
  Assert-Equal 1 $metadataHash.Count "SBOM metadata should include the source lock hash."
  Assert-Equal $sourceLockSha256 $metadataHash[0].value "SBOM metadata source lock hash should match the fixture lock."
  Assert-True (@($sbom.components | Where-Object { $_.name -eq "apache-subversion" -and $_.version -eq "1.14.5" }).Count -eq 1) "SBOM should include Apache Subversion."
  Assert-True (@($sbom.components | Where-Object { $_.name -eq "subversionr" -and $_.properties[0].value -eq "typescript-extension" }).Count -eq 1) "SBOM should include the VS Code extension component."
  Assert-True (@($sbom.components | Where-Object { $_.name -eq "subversionr-daemon" -and $_.properties[0].value -eq "rust-workspace-crate" }).Count -eq 1) "SBOM should include the daemon Rust crate."
  Assert-True (@($sbom.components | Where-Object { $_.name -eq "subversionr-protocol" -and $_.properties[0].value -eq "rust-workspace-crate" }).Count -eq 1) "SBOM should include the protocol Rust crate."
  Assert-True (@($sbom.components | Where-Object { $_.name -eq "subversionr_svn_bridge" -and $_.properties[0].value -eq "native-c-bridge" }).Count -eq 1) "SBOM should include the C bridge component."
  Assert-True (@($sbom.components | Where-Object { $_.name -eq "serde" -and $_.version -eq "1.0.228" -and $_.properties[0].value -eq "cargo-lockfile-component" }).Count -eq 1) "SBOM should include Cargo.lock dependencies."
  Assert-True (@($sbom.components | Where-Object { $_.name -eq "windows-link" -and $_.properties[0].value -eq "cargo-lockfile-component" }).Count -eq 1) "SBOM should include transitive Cargo.lock dependencies."
  Assert-True (@($sbom.components | Where-Object { $_.name -eq "@types/node" -and $_.version -eq "24.13.2" -and $_.properties[0].value -eq "pnpm-lockfile-component" }).Count -eq 1) "SBOM should include pnpm lockfile dependencies."
  Assert-True (@($sbom.components | Where-Object { $_.name -eq "vite" -and $_.properties[0].value -eq "pnpm-lockfile-component" }).Count -eq 1) "SBOM should include transitive pnpm lockfile dependencies."
  Assert-True (@($sbom.components | Where-Object { $_.name -eq "pcre2" -and $_.licenses[0].expression -eq "BSD-3-Clause WITH PCRE2-exception" }).Count -eq 1) "SBOM should preserve license expressions."
  Assert-True (@($sbom.components | Where-Object { $_.name -eq "apache-subversion" -and $_.hashes[0].alg -eq "SHA-512" }).Count -eq 1) "SBOM should include SHA-512 hashes."
  $apacheComponent = @($sbom.components | Where-Object { $_.name -eq "apache-subversion" -and $_.version -eq "1.14.5" })[0]
  Assert-True (@($apacheComponent.externalReferences | Where-Object { $_.type -eq "other" -and $_.url -eq "https://downloads.apache.org/subversion/subversion-1.14.5.zip.asc" }).Count -eq 1) "SBOM should preserve upstream signature evidence."
  Assert-True (@($apacheComponent.externalReferences | Where-Object { $_.type -eq "other" -and $_.url -eq "https://downloads.apache.org/subversion/KEYS" }).Count -eq 1) "SBOM should preserve upstream signing key evidence."
  Assert-True (@($sbom.components | Where-Object { $_.name -eq "pcre2" -and ($_.externalReferences | Where-Object { $_.type -eq "license" -and $_.url -eq "https://github.com/PCRE2Project/pcre2/blob/pcre2-10.47/LICENCE.md" }) }).Count -eq 1) "SBOM should include license external references."

  $notice = Get-Content -Raw -LiteralPath $noticePath
  foreach ($requiredText in @(
      "SubversionR Third-Party Notices",
      "Generated from native source locks",
      "apache-subversion",
      "pcre2",
      "subversionr",
      "subversionr-daemon",
      "subversionr_svn_bridge",
      "@types/node",
      "serde",
      "BSD-3-Clause WITH PCRE2-exception",
      "This generated evidence is not a completed legal review"
    )) {
    Assert-True ($notice.Contains($requiredText)) "NOTICE should contain '$requiredText'."
  }
  Assert-True ([regex]::IsMatch($notice, "\| npm \| @types/node \| 24\.13\.2 \| true \| sha512-[^|]+ \| unresolved by lockfile-only evidence \|")) "NOTICE should include complete npm lockfile evidence rows."
  Assert-True ([regex]::IsMatch($notice, "\| cargo \| serde \| 1\.0\.228 \| true \| checksum:[a-f0-9]+ \| unresolved by lockfile-only evidence \|")) "NOTICE should include complete Cargo lockfile evidence rows."

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyEvidenceScript `
    -SourceLockPath $fixtureSourceLock `
    -ExtensionPackagePath $extensionPackagePath `
    -CargoWorkspacePath $cargoWorkspacePath `
    -CargoLockPath $cargoLockPath `
    -PnpmLockPath $pnpmLockPath `
    -NativeBridgeCMakePath $nativeBridgeCMakePath `
    -SbomPath $sbomPath `
    -NoticePath $noticePath
  if ($LASTEXITCODE -ne 0) {
    throw "verify-release-evidence.ps1 failed with exit code $LASTEXITCODE."
  }

  $tamperedSbomPath = Join-Path $outputRoot "tampered.cdx.json"
  $tampered = Get-Content -Raw -LiteralPath $sbomPath | ConvertFrom-Json
  $tampered.components = @($tampered.components | Where-Object { $_.name -ne "pcre2" })
  $tampered | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tamperedSbomPath -Encoding utf8
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyEvidenceScript `
      -SourceLockPath $fixtureSourceLock `
      -ExtensionPackagePath $extensionPackagePath `
      -CargoWorkspacePath $cargoWorkspacePath `
      -CargoLockPath $cargoLockPath `
      -PnpmLockPath $pnpmLockPath `
      -NativeBridgeCMakePath $nativeBridgeCMakePath `
      -SbomPath $tamperedSbomPath `
      -NoticePath $noticePath
  } "pcre2" "Release evidence verification should fail when a locked source is missing from the SBOM."

  $extraSbomPath = Join-Path $outputRoot "extra-component.cdx.json"
  $extra = Get-Content -Raw -LiteralPath $sbomPath | ConvertFrom-Json
  $extra.components = @($extra.components) + [pscustomobject]@{
    type = "library"
    name = "unexpected-component"
    version = "0.0.0"
    properties = @(
      [pscustomobject]@{
        name = "subversionr:componentScope"
        value = "unexpected-test-component"
      }
    )
  }
  $extra | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $extraSbomPath -Encoding utf8
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyEvidenceScript `
      -SourceLockPath $fixtureSourceLock `
      -ExtensionPackagePath $extensionPackagePath `
      -CargoWorkspacePath $cargoWorkspacePath `
      -CargoLockPath $cargoLockPath `
      -PnpmLockPath $pnpmLockPath `
      -NativeBridgeCMakePath $nativeBridgeCMakePath `
      -SbomPath $extraSbomPath `
      -NoticePath $noticePath
  } "unexpected-component" "Release evidence verification should fail when the SBOM contains components outside declared inputs."

  $missingHashSbomPath = Join-Path $outputRoot "missing-source-lock-hash.cdx.json"
  $missingHash = Get-Content -Raw -LiteralPath $sbomPath | ConvertFrom-Json
  $missingHash.metadata.properties = @($missingHash.metadata.properties | Where-Object { $_.name -ne "subversionr:sourceLockSha256" })
  $missingHash | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $missingHashSbomPath -Encoding utf8
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyEvidenceScript `
      -SourceLockPath $fixtureSourceLock `
      -ExtensionPackagePath $extensionPackagePath `
      -CargoWorkspacePath $cargoWorkspacePath `
      -CargoLockPath $cargoLockPath `
      -PnpmLockPath $pnpmLockPath `
      -NativeBridgeCMakePath $nativeBridgeCMakePath `
      -SbomPath $missingHashSbomPath `
      -NoticePath $noticePath
  } "sourceLockSha256" "Release evidence verification should fail when SBOM metadata loses the source-lock binding hash."

  $duplicateHashSbomPath = Join-Path $outputRoot "duplicate-source-lock-hash.cdx.json"
  $duplicateHash = Get-Content -Raw -LiteralPath $sbomPath | ConvertFrom-Json
  $duplicateHash.metadata.properties = @($duplicateHash.metadata.properties) + [pscustomobject]@{
    name = "subversionr:sourceLockSha256"
    value = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  }
  $duplicateHash | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $duplicateHashSbomPath -Encoding utf8
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyEvidenceScript `
      -SourceLockPath $fixtureSourceLock `
      -ExtensionPackagePath $extensionPackagePath `
      -CargoWorkspacePath $cargoWorkspacePath `
      -CargoLockPath $cargoLockPath `
      -PnpmLockPath $pnpmLockPath `
      -NativeBridgeCMakePath $nativeBridgeCMakePath `
      -SbomPath $duplicateHashSbomPath `
      -NoticePath $noticePath
  } "sourceLockSha256" "Release evidence verification should fail when SBOM metadata contains duplicate source-lock hashes."

  $missingSignatureSbomPath = Join-Path $outputRoot "missing-signature-ref.cdx.json"
  $missingSignature = Get-Content -Raw -LiteralPath $sbomPath | ConvertFrom-Json
  $missingSignatureApache = @($missingSignature.components | Where-Object { $_.name -eq "apache-subversion" -and $_.version -eq "1.14.5" })[0]
  $missingSignatureApache.externalReferences = @($missingSignatureApache.externalReferences | Where-Object { $_.url -ne "https://downloads.apache.org/subversion/subversion-1.14.5.zip.asc" })
  $missingSignature | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $missingSignatureSbomPath -Encoding utf8
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyEvidenceScript `
      -SourceLockPath $fixtureSourceLock `
      -ExtensionPackagePath $extensionPackagePath `
      -CargoWorkspacePath $cargoWorkspacePath `
      -CargoLockPath $cargoLockPath `
      -PnpmLockPath $pnpmLockPath `
      -NativeBridgeCMakePath $nativeBridgeCMakePath `
      -SbomPath $missingSignatureSbomPath `
      -NoticePath $noticePath
  } "subversion-1.14.5.zip.asc" "Release evidence verification should fail when upstream signature evidence is removed from the SBOM."

  $tamperedSignatureCommentSbomPath = Join-Path $outputRoot "tampered-signature-comment.cdx.json"
  $tamperedSignatureComment = Get-Content -Raw -LiteralPath $sbomPath | ConvertFrom-Json
  $tamperedSignatureCommentApache = @($tamperedSignatureComment.components | Where-Object { $_.name -eq "apache-subversion" -and $_.version -eq "1.14.5" })[0]
  $signatureReference = @($tamperedSignatureCommentApache.externalReferences | Where-Object { $_.url -eq "https://downloads.apache.org/subversion/subversion-1.14.5.zip.asc" })[0]
  $signatureReference.comment = "Upstream release signing keys"
  $tamperedSignatureComment | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tamperedSignatureCommentSbomPath -Encoding utf8
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyEvidenceScript `
      -SourceLockPath $fixtureSourceLock `
      -ExtensionPackagePath $extensionPackagePath `
      -CargoWorkspacePath $cargoWorkspacePath `
      -CargoLockPath $cargoLockPath `
      -PnpmLockPath $pnpmLockPath `
      -NativeBridgeCMakePath $nativeBridgeCMakePath `
      -SbomPath $tamperedSignatureCommentSbomPath `
      -NoticePath $noticePath
  } "must preserve comment" "Release evidence verification should fail when upstream signature evidence loses its semantic comment."

  $missingIntegritySbomPath = Join-Path $outputRoot "missing-lockfile-integrity.cdx.json"
  $missingIntegrity = Get-Content -Raw -LiteralPath $sbomPath | ConvertFrom-Json
  $serdeComponent = @($missingIntegrity.components | Where-Object { $_.name -eq "serde" -and $_.version -eq "1.0.228" })[0]
  $serdeComponent.properties = @($serdeComponent.properties | Where-Object { $_.name -ne "subversionr:lockfileIntegrity" })
  $missingIntegrity | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $missingIntegritySbomPath -Encoding utf8
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyEvidenceScript `
      -SourceLockPath $fixtureSourceLock `
      -ExtensionPackagePath $extensionPackagePath `
      -CargoWorkspacePath $cargoWorkspacePath `
      -CargoLockPath $cargoLockPath `
      -PnpmLockPath $pnpmLockPath `
      -NativeBridgeCMakePath $nativeBridgeCMakePath `
      -SbomPath $missingIntegritySbomPath `
      -NoticePath $noticePath
  } "subversionr:lockfileIntegrity" "Release evidence verification should fail when Cargo checksum evidence is removed from the SBOM."

  $duplicateIntegritySbomPath = Join-Path $outputRoot "duplicate-lockfile-integrity.cdx.json"
  $duplicateIntegrity = Get-Content -Raw -LiteralPath $sbomPath | ConvertFrom-Json
  $duplicateIntegritySerde = @($duplicateIntegrity.components | Where-Object { $_.name -eq "serde" -and $_.version -eq "1.0.228" })[0]
  $duplicateIntegritySerde.properties = @($duplicateIntegritySerde.properties) + [pscustomobject]@{
    name = "subversionr:lockfileIntegrity"
    value = "checksum:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  }
  $duplicateIntegrity | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $duplicateIntegritySbomPath -Encoding utf8
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyEvidenceScript `
      -SourceLockPath $fixtureSourceLock `
      -ExtensionPackagePath $extensionPackagePath `
      -CargoWorkspacePath $cargoWorkspacePath `
      -CargoLockPath $cargoLockPath `
      -PnpmLockPath $pnpmLockPath `
      -NativeBridgeCMakePath $nativeBridgeCMakePath `
      -SbomPath $duplicateIntegritySbomPath `
      -NoticePath $noticePath
  } "subversionr:lockfileIntegrity" "Release evidence verification should fail when SBOM component evidence contains duplicate lockfile integrity values."

  $tamperedNoticePath = Join-Path $outputRoot "tampered-notice.md"
  $tamperedNotice = $notice -replace '\| npm \| @types/node \| 24\.13\.2 \| true \| [^|]+ \| unresolved by lockfile-only evidence \|', '| npm | @types/node | 24.13.2 | true | removed | unresolved by lockfile-only evidence |'
  $tamperedNotice | Set-Content -LiteralPath $tamperedNoticePath -Encoding utf8
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyEvidenceScript `
      -SourceLockPath $fixtureSourceLock `
      -ExtensionPackagePath $extensionPackagePath `
      -CargoWorkspacePath $cargoWorkspacePath `
      -CargoLockPath $cargoLockPath `
      -PnpmLockPath $pnpmLockPath `
      -NativeBridgeCMakePath $nativeBridgeCMakePath `
      -SbomPath $sbomPath `
      -NoticePath $tamperedNoticePath
  } "complete npm dependency evidence for @types/node" "Release evidence verification should fail when NOTICE lockfile evidence is incomplete."

  $missingNpmManifestDependencyPath = Join-Path $tempRoot "package-missing-lock-dependency.json"
  $missingNpmManifestDependency = Get-Content -Raw -LiteralPath $extensionPackagePath | ConvertFrom-Json
  $missingNpmManifestDependency.devDependencies | Add-Member -NotePropertyName "missing-lock-entry" -NotePropertyValue "^1.0.0"
  $missingNpmManifestDependency | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $missingNpmManifestDependencyPath -Encoding utf8
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyEvidenceScript `
      -SourceLockPath $fixtureSourceLock `
      -ExtensionPackagePath $missingNpmManifestDependencyPath `
      -CargoWorkspacePath $cargoWorkspacePath `
      -CargoLockPath $cargoLockPath `
      -PnpmLockPath $pnpmLockPath `
      -NativeBridgeCMakePath $nativeBridgeCMakePath `
      -SbomPath $sbomPath `
      -NoticePath $noticePath
  } "missing-lock-entry" "Release evidence verification should fail when a direct npm manifest dependency is absent from pnpm lockfile evidence."

  $missingCargoWorkspaceRoot = Join-Path $tempRoot "cargo-missing-lock-dependency"
  New-Item -ItemType Directory -Force -Path (Join-Path $missingCargoWorkspaceRoot "crates\subversionr-daemon") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $missingCargoWorkspaceRoot "crates\subversionr-protocol") | Out-Null
  Copy-Item -LiteralPath $cargoWorkspacePath -Destination (Join-Path $missingCargoWorkspaceRoot "Cargo.toml")
  Copy-Item -LiteralPath (Join-Path $repoRoot "crates\subversionr-daemon\Cargo.toml") -Destination (Join-Path $missingCargoWorkspaceRoot "crates\subversionr-daemon\Cargo.toml")
  Copy-Item -LiteralPath (Join-Path $repoRoot "crates\subversionr-protocol\Cargo.toml") -Destination (Join-Path $missingCargoWorkspaceRoot "crates\subversionr-protocol\Cargo.toml")
  $missingCargoDaemonManifestPath = Join-Path $missingCargoWorkspaceRoot "crates\subversionr-daemon\Cargo.toml"
  $missingCargoDaemonManifest = Get-Content -Raw -LiteralPath $missingCargoDaemonManifestPath
  $missingCargoDaemonManifest = $missingCargoDaemonManifest.Replace('subversionr-protocol = { path = "../subversionr-protocol" }', "subversionr-protocol = { path = `"../subversionr-protocol`" }`nmissing-cargo-lock-entry = `"1`"")
  $missingCargoDaemonManifest | Set-Content -LiteralPath $missingCargoDaemonManifestPath -Encoding utf8
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyEvidenceScript `
      -SourceLockPath $fixtureSourceLock `
      -ExtensionPackagePath $extensionPackagePath `
      -CargoWorkspacePath (Join-Path $missingCargoWorkspaceRoot "Cargo.toml") `
      -CargoLockPath $cargoLockPath `
      -PnpmLockPath $pnpmLockPath `
      -NativeBridgeCMakePath $nativeBridgeCMakePath `
      -SbomPath $sbomPath `
      -NoticePath $noticePath
  } "missing-cargo-lock-entry" "Release evidence verification should fail when a direct Cargo manifest dependency is absent from Cargo.lock evidence."

  $badSourceLock = Join-Path $tempRoot "bad-sources.lock.json"
  @'
{
  "sources": [
    {
      "name": "missing-license-url",
      "version": "1.0.0",
      "license": "MIT",
      "url": "https://example.invalid/source.tar.gz",
      "sha512": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    }
  ]
}
'@ | Set-Content -LiteralPath $badSourceLock -NoNewline
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $generateSbomScript `
      -SourceLockPath $badSourceLock `
      -ExtensionPackagePath $extensionPackagePath `
      -CargoWorkspacePath $cargoWorkspacePath `
      -CargoLockPath $cargoLockPath `
      -PnpmLockPath $pnpmLockPath `
      -NativeBridgeCMakePath $nativeBridgeCMakePath `
      -OutputPath (Join-Path $tempRoot "bad.cdx.json")
  } "licenseUrl" "SBOM generation should fail fast when source-lock license metadata is incomplete."

  $unpairedSignatureLock = Join-Path $tempRoot "unpaired-signature.lock.json"
  @'
{
  "sources": [
    {
      "name": "unpaired-signature",
      "version": "1.0.0",
      "license": "MIT",
      "licenseUrl": "https://example.invalid/license",
      "url": "https://example.invalid/source.tar.gz",
      "sha512": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
      "signatureUrl": "https://example.invalid/source.tar.gz.asc"
    }
  ]
}
'@ | Set-Content -LiteralPath $unpairedSignatureLock -NoNewline
  Assert-NativeCommandFailsContaining {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $generateNoticeScript `
      -SourceLockPath $unpairedSignatureLock `
      -ExtensionPackagePath $extensionPackagePath `
      -CargoWorkspacePath $cargoWorkspacePath `
      -CargoLockPath $cargoLockPath `
      -PnpmLockPath $pnpmLockPath `
      -NativeBridgeCMakePath $nativeBridgeCMakePath `
      -OutputPath (Join-Path $tempRoot "unpaired-notice.md")
  } "keysUrl" "NOTICE generation should fail fast when source-lock signature metadata is incomplete."

  $packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  Assert-Equal "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/tests/release-evidence-scripts.tests.ps1" $packageJson.scripts."release:test-evidence-scripts" "Root package should expose release evidence script tests."
  Assert-True ($packageJson.scripts."release:generate-source-sbom".Contains("scripts/release/generate-source-sbom.ps1")) "Root package should expose source SBOM generation."
  Assert-True ($packageJson.scripts."release:generate-third-party-notice".Contains("scripts/release/generate-third-party-notice.ps1")) "Root package should expose third-party notice generation."
  Assert-True ($packageJson.scripts."release:verify-evidence".Contains("scripts/release/verify-release-evidence.ps1")) "Root package should expose release evidence verification."

  $ciWorkflow = Get-Content -Raw -LiteralPath $ciWorkflowPath
  Assert-ContainsInOrder $ciWorkflow @(
    "Release script tests",
    "Release evidence script tests",
    "Generate source SBOM",
    "Generate third-party notices",
    "Verify release evidence"
  ) "CI should run M7c release evidence gates after release script tests."

  Write-Host "Release evidence script tests passed."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

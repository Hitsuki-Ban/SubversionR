$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$extensionRoot = Join-Path $repoRoot "packages\vscode-extension"
$packageJsonPath = Join-Path $extensionRoot "package.json"
$sourceRoot = Join-Path $extensionRoot "src"

$packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
if ($packageJson.description -notmatch '^%[^%]+%$') {
  throw "Extension package description must use package.nls indirection."
}
if ($packageJson.l10n -ne "./l10n") {
  throw "Extension package must declare `"l10n`": `"./l10n`" for runtime vscode.l10n.t strings."
}

$l10nRoot = Join-Path $extensionRoot "l10n"
$requiredBundles = @(
  "bundle.l10n.json",
  "bundle.l10n.ja.json",
  "bundle.l10n.zh-cn.json"
)
$bundleKeys = $null
foreach ($bundleName in $requiredBundles) {
  $bundlePath = Join-Path $l10nRoot $bundleName
  if (-not (Test-Path -LiteralPath $bundlePath -PathType Leaf)) {
    throw "Missing runtime localization bundle: $bundlePath"
  }
  $bundle = Get-Content -Raw -LiteralPath $bundlePath | ConvertFrom-Json
  $keys = @($bundle.PSObject.Properties.Name | Sort-Object)
  if ($keys.Count -eq 0) {
    throw "Runtime localization bundle is empty: $bundlePath"
  }
  if ($null -eq $bundleKeys) {
    $bundleKeys = $keys
  }
  elseif (($bundleKeys -join "`n") -ne ($keys -join "`n")) {
    throw "Runtime localization bundle keys must match bundle.l10n.json: $bundlePath"
  }
}

$violations = @()
Get-ChildItem -Recurse -File -LiteralPath $sourceRoot -Include *.ts | ForEach-Object {
  $content = Get-Content -Raw -LiteralPath $_.FullName
  if ($content -match 'show(?:Information|Warning|Error)Message\(\s*"') {
    $violations += $_.FullName
  }
}

if ($violations.Count -gt 0) {
  throw "VS Code notification text must be routed through vscode.l10n.t: $($violations -join ', ')"
}

Write-Host "Localization checks passed."

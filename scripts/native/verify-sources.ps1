$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$modulePath = Join-Path $repoRoot "scripts\native\SubversionR.Native.psm1"
$lockPath = Join-Path $repoRoot "native\sources.lock.json"
$cacheRoot = Join-Path $repoRoot ".cache\native\sources"

if (-not (Test-Path -LiteralPath $lockPath)) {
  throw "Missing native source lock file: $lockPath"
}

Import-Module $modulePath -Force

$lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
if (-not $lock.sources -or $lock.sources.Count -eq 0) {
  throw "native/sources.lock.json must contain at least one source entry."
}

New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
$gpgHome = Join-Path $cacheRoot "gnupg"
New-Item -ItemType Directory -Force -Path $gpgHome | Out-Null

function Get-SourceField($Source, [string]$Field) {
  $property = $Source.PSObject.Properties[$Field]
  if ($null -eq $property) {
    return $null
  }

  return $property.Value
}

function Resolve-Gpg {
  foreach ($candidate in @(
    "C:\Program Files\GnuPG\bin\gpg.exe",
    "C:\Program Files (x86)\GnuPG\bin\gpg.exe"
  )) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return $candidate
    }
  }

  $command = Get-Command gpg -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Source
  }

  throw "gpg is required for signed native sources."
}

function Convert-GpgHomePath([string]$Path, [string]$GpgPath) {
  $resolved = (Resolve-Path -LiteralPath $Path).Path
  if ($GpgPath -match '\\Git\\usr\\bin\\gpg\.exe$' -and $resolved -match '^([A-Za-z]):\\(.*)$') {
    $drive = $Matches[1].ToLowerInvariant()
    $rest = $Matches[2].Replace('\', '/')
    return "/$drive/$rest"
  }

  return $resolved
}

$gpg = Resolve-Gpg
$env:GNUPGHOME = Convert-GpgHomePath $gpgHome $gpg

foreach ($source in $lock.sources) {
  foreach ($field in @("name", "version", "license", "licenseUrl", "url", "sha512")) {
    if (-not (Get-SourceField $source $field)) {
      throw "Source entry is missing required field '$field'."
    }
  }

  $name = Get-SourceField $source "name"
  $version = Get-SourceField $source "version"
  $url = Get-SourceField $source "url"
  $signatureUrl = Get-SourceField $source "signatureUrl"
  $keysUrl = Get-SourceField $source "keysUrl"

  $archivePath = Join-Path $cacheRoot ([IO.Path]::GetFileName([Uri]$url))

  if (-not (Test-Path -LiteralPath $archivePath)) {
    Invoke-WebRequest -Uri $url -OutFile $archivePath
  }

  Assert-NativeArchiveChecksum -ArchivePath $archivePath -Source $source | Out-Null

  if ($signatureUrl -or $keysUrl) {
    if (-not $signatureUrl -or -not $keysUrl) {
      throw "Source entry $name must set both signatureUrl and keysUrl, or neither."
    }

    $signaturePath = "$archivePath.asc"
    $keysPath = Join-Path $cacheRoot "$name-KEYS"
    if (-not (Test-Path -LiteralPath $signaturePath)) {
      Invoke-WebRequest -Uri $signatureUrl -OutFile $signaturePath
    }
    if (-not (Test-Path -LiteralPath $keysPath)) {
      Invoke-WebRequest -Uri $keysUrl -OutFile $keysPath
    }

    $importOutput = & $gpg --batch --import $keysPath 2>&1
    if ($LASTEXITCODE -ne 0) {
      $importOutput | Out-Host
      throw "Failed to import PGP keys for $name."
    }

    $verifyOutput = & $gpg --batch --status-fd 1 --verify $signaturePath $archivePath 2>&1

    $hasValidSignature = $false
    $hasRejectedSignature = $false
    foreach ($line in $verifyOutput) {
      if ($line -match '^\[GNUPG:\] VALIDSIG ') {
        $hasValidSignature = $true
      }
      if ($line -match '^\[GNUPG:\] (BADSIG|EXPSIG|EXPKEYSIG|REVKEYSIG) ') {
        $hasRejectedSignature = $true
      }
    }

    if (-not $hasValidSignature -or $hasRejectedSignature) {
      $verifyOutput | Out-Host
      throw "PGP signature verification failed for $archivePath."
    }
  }

  Write-Host "Verified $name $version"
}

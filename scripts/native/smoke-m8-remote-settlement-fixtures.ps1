[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$SubversionStageRoot,

  [Parameter(Mandatory = $true)]
  [string]$OpenSslExe,

  [Parameter(Mandatory = $true)]
  [string]$VsDevCmd,

  [ValidateSet("Release", "Debug")]
  [string]$Configuration = "Release",

  [ValidateSet("x64")]
  [string]$Arch = "x64"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..") -ErrorAction Stop).Path
$modulePath = Join-Path $PSScriptRoot "SubversionR.Native.psm1"
$sourceRoot = Join-Path $repoRoot "native\feasibility\m8-remote-settlement"
$fixtureScript = Join-Path $sourceRoot "http-fixture.ps1"
$openSslConfig = Join-Path $sourceRoot "openssl-fixture.cnf"
$sourceLockPath = Join-Path $repoRoot "native\sources.lock.json"
Import-Module $modulePath -Force

function Assert-RequiredFile([string]$Path, [string]$Description) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Missing $Description`: $Path"
  }
}

function Quote-CmdArgument([string]$Value) {
  return '"' + $Value.Replace('"', '\"') + '"'
}

function Wait-ReadyFile(
  [Diagnostics.Process]$Process,
  [string]$ReadyFile,
  [string]$Stdout,
  [string]$Stderr
) {
  for ($attempt = 0; $attempt -lt 200; $attempt += 1) {
    Assert-BoundedLog -Path $Stdout
    Assert-BoundedLog -Path $Stderr
    if (Test-Path -LiteralPath $ReadyFile -PathType Leaf) {
      Assert-BoundedLog -Path $ReadyFile
      return
    }
    if ($Process.HasExited) {
      throw "The controlled fixture exited before readiness."
    }
    Start-Sleep -Milliseconds 25
  }
  throw "The controlled fixture did not become ready before its deadline."
}

function Stop-ControlledProcess([Diagnostics.Process]$Process) {
  if (-not $Process.HasExited) {
    Stop-Process -Id $Process.Id -Force
    $Process.WaitForExit()
  }
}

$maxLogBytes = 64 * 1024

function Assert-BoundedLog([string]$Path) {
  if ((Test-Path -LiteralPath $Path -PathType Leaf) -and
      (Get-Item -LiteralPath $Path).Length -gt $maxLogBytes) {
    throw "A controlled child log exceeded its hard size limit."
  }
}

function Read-BoundedLines([string]$Path) {
  Assert-BoundedLog -Path $Path
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return @()
  }
  return @(Get-Content -LiteralPath $Path)
}

function Invoke-BoundedProbe(
  [string]$ProbeExe,
  [string[]]$Arguments,
  [string]$StageRoot,
  [string]$OutputRoot,
  [string[]]$AdditionalLogs
) {
  $stdout = Join-Path $OutputRoot "probe.stdout.jsonl"
  $stderr = Join-Path $OutputRoot "probe.stderr.log"
  $previousPath = $env:PATH
  try {
    $env:PATH = "$(Join-Path $StageRoot 'bin');$previousPath"
    $process = Start-Process `
      -FilePath $ProbeExe `
      -ArgumentList $Arguments `
      -WindowStyle Hidden `
      -RedirectStandardOutput $stdout `
      -RedirectStandardError $stderr `
      -PassThru
  }
  finally {
    $env:PATH = $previousPath
  }

  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  try {
    while (-not $process.HasExited) {
      Assert-BoundedLog -Path $stdout
      Assert-BoundedLog -Path $stderr
      foreach ($log in $AdditionalLogs) {
        Assert-BoundedLog -Path $log
      }
      if ([DateTime]::UtcNow -ge $deadline) {
        throw "The controlled probe exceeded its absolute deadline."
      }
      Start-Sleep -Milliseconds 25
    }
    Assert-BoundedLog -Path $stdout
    Assert-BoundedLog -Path $stderr
    if ((Test-Path -LiteralPath $stderr -PathType Leaf) -and
        (Get-Item -LiteralPath $stderr).Length -ne 0) {
      throw "The controlled probe wrote to stderr."
    }
    return [pscustomobject]@{
      ExitCode = $process.ExitCode
      Lines = @(Read-BoundedLines -Path $stdout)
    }
  }
  finally {
    Stop-ControlledProcess -Process $process
  }
}

function Convert-ProbeEvents([object[]]$Lines) {
  $events = @()
  foreach ($lineObject in $Lines) {
    $line = [string]$lineObject
    if (-not $line.StartsWith('{"event"')) {
      throw "The probe emitted a non-JSONL line."
    }
    $events += $line | ConvertFrom-Json
  }
  return $events
}

function Assert-NoCredentialLeak([object[]]$Lines, [string[]]$Passwords) {
  $text = $Lines -join "`n"
  foreach ($forbidden in @($Passwords) + @(
    "fixture-user",
    "SUBVERSIONR_M8_FIXTURE_PASSWORD",
    "SUBVERSIONR_M8_FIXTURE_CLIENT_PASSWORD",
    "SUBVERSIONR_M8_FIXTURE_CLIENT_PASSWORD_2",
    "m8-fixture"
  )) {
    if ($text.Contains($forbidden)) {
      throw "Fixture evidence exposed credential material or an environment variable name."
    }
  }
}

function Assert-EventSequence([object[]]$Events, [string[]]$Expected) {
  $actual = @($Events | ForEach-Object { [string]$_.event })
  if (($actual -join ",") -cne ($Expected -join ",")) {
    throw "Unexpected probe event ordering: $($actual -join ',')."
  }
}

function Assert-Event([object[]]$Events, [string]$Name, [string]$Kind) {
  $matches = @($Events | Where-Object {
    $_.event -eq $Name -and ($null -eq $_.PSObject.Properties["kind"] -or $_.kind -eq $Kind)
  })
  if ($matches.Count -eq 0) {
    throw "Expected probe event '$Name' was not observed."
  }
}

function Invoke-BasicFixtureScenario(
  [string]$Scenario,
  [string]$ProbeExe,
  [string]$StageRoot,
  [string]$RunRoot,
  [string[]]$Passwords
) {
  $scenarioRoot = New-Item -ItemType Directory -Path (Join-Path $RunRoot $Scenario)
  $readyFile = Join-Path $scenarioRoot.FullName "ready.json"
  $recordFile = Join-Path $scenarioRoot.FullName "records.jsonl"
  $stopFile = Join-Path $scenarioRoot.FullName "stop"
  $fixtureStdout = Join-Path $scenarioRoot.FullName "fixture.stdout.log"
  $fixtureStderr = Join-Path $scenarioRoot.FullName "fixture.stderr.log"
  $fixture = Start-Process `
    -FilePath (Get-Command pwsh -ErrorAction Stop).Source `
    -ArgumentList @(
      "-NoProfile",
      "-File", $fixtureScript,
      "-Scenario", $Scenario,
      "-Transport", "http",
      "-ReadyFile", $readyFile,
      "-RecordFile", $recordFile,
      "-StopFile", $stopFile
    ) `
    -WindowStyle Hidden `
    -RedirectStandardOutput $fixtureStdout `
    -RedirectStandardError $fixtureStderr `
    -PassThru

  try {
    Wait-ReadyFile -Process $fixture -ReadyFile $readyFile -Stdout $fixtureStdout -Stderr $fixtureStderr
    $ready = (Read-BoundedLines -Path $readyFile) -join "`n" | ConvertFrom-Json
    if ($ready.schema -ne "subversionr.m8-http-fixture-ready.v1" -or
        $ready.port -lt 1 -or $ready.port -gt 65535) {
      throw "The HTTP fixture readiness record is invalid."
    }

    $probeArguments = @(
      "--mode", "basic",
      "--url", "http://127.0.0.1:$($ready.port)/repo",
      "--credential-env", "fixture-user", "SUBVERSIONR_M8_FIXTURE_CLIENT_PASSWORD"
    )
    if ($Scenario -eq "basic-rejection") {
      $probeArguments += @(
        "--credential-env", "fixture-user", "SUBVERSIONR_M8_FIXTURE_CLIENT_PASSWORD_2"
      )
    }
    if ($Scenario -in @("basic-later-403", "basic-later-404", "basic-later-409")) {
      $probeArguments += @("--post-open-check-path", "probe-path")
    }
    $probeResult = Invoke-BoundedProbe `
      -ProbeExe $ProbeExe `
      -Arguments $probeArguments `
      -StageRoot $StageRoot `
      -OutputRoot $scenarioRoot.FullName `
      -AdditionalLogs @($fixtureStdout, $fixtureStderr, $recordFile)
    $probeLines = @($probeResult.Lines)
    $probeExit = $probeResult.ExitCode

    Set-Content -LiteralPath $stopFile -Value "stop" -Encoding ascii -NoNewline
    if (-not $fixture.WaitForExit(5000)) {
      throw "The HTTP fixture did not stop after the stop signal."
    }
    if ($fixture.ExitCode -ne 0) {
      throw "The HTTP fixture failed."
    }
    Assert-BoundedLog -Path $fixtureStdout
    Assert-BoundedLog -Path $fixtureStderr
    if ((Get-Item -LiteralPath $fixtureStdout).Length -ne 0 -or
        (Get-Item -LiteralPath $fixtureStderr).Length -ne 0) {
      throw "The HTTP fixture wrote unexpected process output."
    }

    Assert-NoCredentialLeak -Lines $probeLines -Passwords $Passwords
    $events = @(Convert-ProbeEvents -Lines $probeLines)
    Assert-Event -Events $events -Name "provider.first" -Kind "simple"

    $records = @(Read-BoundedLines -Path $recordFile | ForEach-Object {
      $_ | ConvertFrom-Json
    })
    if ($records.Count -lt 2 -or
        -not ($records | Where-Object { $_.status -eq 401 -and $_.authorization -eq "missing" })) {
      throw "The HTTP fixture did not record the initial Basic challenge."
    }

    switch ($Scenario) {
      "basic-success" {
        if ($probeExit -ne 0) {
          throw "The accepted Basic fixture did not open an RA session."
        }
        Assert-Event -Events $events -Name "provider.save" -Kind "simple"
        Assert-Event -Events $events -Name "ra.opened" -Kind ""
        if (-not ($records | Where-Object { $_.status -eq 200 -and $_.authorization -eq "accepted" })) {
          throw "The accepted Basic fixture did not record an authenticated 200 response."
        }
        Assert-EventSequence -Events $events -Expected @(
          "probe.started", "provider.first", "provider.save", "ra.opened", "probe.completed"
        )
      }
      "basic-direct-403" {
        if ($probeExit -eq 0 -or $events.event -contains "provider.save" -or
            $events.event -contains "ra.opened") {
          throw "A direct authenticated 403 produced a false accepted settlement."
        }
        Assert-Event -Events $events -Name "ra.failed" -Kind ""
        if (-not ($records | Where-Object { $_.status -eq 403 -and $_.authorization -eq "accepted" })) {
          throw "The direct-403 fixture did not record its authenticated 403 response."
        }
        Assert-EventSequence -Events $events -Expected @(
          "probe.started", "provider.first", "ra.failed"
        )
      }
      "basic-later-dav-failure" {
        if ($probeExit -eq 0 -or $events.event -contains "ra.opened") {
          throw "The malformed DAV fixture unexpectedly opened an RA session."
        }
        Assert-Event -Events $events -Name "provider.save" -Kind "simple"
        Assert-Event -Events $events -Name "ra.failed" -Kind ""
        if (-not ($records | Where-Object { $_.status -eq 200 -and $_.authorization -eq "accepted" })) {
          throw "The malformed DAV fixture did not record its authenticated 200 response."
        }
        Assert-EventSequence -Events $events -Expected @(
          "probe.started", "provider.first", "provider.save", "ra.failed"
        )
      }
      "basic-rejection" {
        if ($probeExit -eq 0 -or $events.event -contains "provider.save" -or
            $events.event -contains "ra.opened") {
          throw "Rejected Basic credentials produced a false accepted settlement."
        }
        Assert-Event -Events $events -Name "provider.next" -Kind "simple"
        Assert-Event -Events $events -Name "ra.failed" -Kind ""
        Assert-EventSequence -Events $events -Expected @(
          "probe.started", "provider.first", "provider.next", "provider.next", "ra.failed"
        )
      }
      "basic-termination" {
        if ($probeExit -eq 0 -or $events.event -contains "provider.save" -or
            $events.event -contains "ra.opened") {
          throw "Basic termination produced a false accepted settlement."
        }
        Assert-Event -Events $events -Name "ra.failed" -Kind ""
        if (-not ($records | Where-Object { $_.status -eq 0 -and $_.authorization -eq "accepted" })) {
          throw "The Basic termination fixture did not terminate after Authorization."
        }
        Assert-EventSequence -Events $events -Expected @(
          "probe.started", "provider.first", "ra.failed"
        )
      }
      { $_ -in @("basic-later-403", "basic-later-409") } {
        if ($probeExit -eq 0) {
          throw "A later DAV failure unexpectedly succeeded."
        }
        Assert-Event -Events $events -Name "provider.save" -Kind "simple"
        Assert-Event -Events $events -Name "ra.opened" -Kind ""
        Assert-Event -Events $events -Name "ra.failed" -Kind ""
        Assert-EventSequence -Events $events -Expected @(
          "probe.started", "provider.first", "provider.save", "ra.opened", "ra.failed"
        )
      }
      "basic-later-404" {
        if ($probeExit -ne 0) {
          throw "The missing-path check did not return a typed none result."
        }
        Assert-Event -Events $events -Name "provider.save" -Kind "simple"
        Assert-Event -Events $events -Name "ra.opened" -Kind ""
        Assert-Event -Events $events -Name "ra.check-path" -Kind "none"
        Assert-EventSequence -Events $events -Expected @(
          "probe.started", "provider.first", "provider.save", "ra.opened",
          "ra.check-path", "probe.completed"
        )
      }
    }

    Write-Output (@{
      event = "fixture.assertion"
      scenario = $Scenario
      verdict = "passed"
    } | ConvertTo-Json -Compress)
  }
  finally {
    if (-not (Test-Path -LiteralPath $stopFile)) {
      Set-Content -LiteralPath $stopFile -Value "stop" -Encoding ascii -NoNewline
    }
    Stop-ControlledProcess -Process $fixture
  }
}

function New-TlsFixtureCertificate(
  [string]$RunRoot,
  [string]$OpenSsl
) {
  $certificateRoot = New-Item -ItemType Directory -Path (Join-Path $RunRoot "tls-certificate")
  $certificate = Join-Path $certificateRoot.FullName "certificate.pem"
  $privateKey = Join-Path $certificateRoot.FullName "private-key.pem"
  $stdout = Join-Path $certificateRoot.FullName "openssl.stdout.log"
  $stderr = Join-Path $certificateRoot.FullName "openssl.stderr.log"
  $process = Start-Process `
    -FilePath $OpenSsl `
    -ArgumentList @(
      "req", "-x509", "-newkey", "rsa:2048", "-nodes",
      "-config", $openSslConfig,
      "-keyout", $privateKey,
      "-out", $certificate,
      "-days", "1",
      "-subj", "/CN=127.0.0.1",
      "-addext", "subjectAltName=IP:127.0.0.1"
    ) `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr `
    -PassThru
  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  try {
    while (-not $process.HasExited) {
      Assert-BoundedLog -Path $stdout
      Assert-BoundedLog -Path $stderr
      if ([DateTime]::UtcNow -ge $deadline) {
        throw "OpenSSL certificate generation exceeded its absolute deadline."
      }
      Start-Sleep -Milliseconds 25
    }
    Assert-BoundedLog -Path $stdout
    Assert-BoundedLog -Path $stderr
    if ($process.ExitCode -ne 0) {
      throw "OpenSSL failed to create the TLS fixture certificate."
    }
    Assert-RequiredFile $certificate "TLS fixture certificate"
    Assert-RequiredFile $privateKey "TLS fixture private key"
    return [pscustomobject]@{ Certificate = $certificate; PrivateKey = $privateKey }
  }
  finally {
    Stop-ControlledProcess -Process $process
  }
}

function Invoke-TlsFixtureScenario(
  [string]$Scenario,
  [string]$ProbeExe,
  [string]$StageRoot,
  [string]$RunRoot,
  [string]$Certificate,
  [string]$PrivateKey,
  [string[]]$ForbiddenSecrets
) {
  $scenarioRoot = New-Item -ItemType Directory -Path (Join-Path $RunRoot $Scenario)
  $readyFile = Join-Path $scenarioRoot.FullName "ready.json"
  $recordFile = Join-Path $scenarioRoot.FullName "records.jsonl"
  $stopFile = Join-Path $scenarioRoot.FullName "stop"
  $fixtureStdout = Join-Path $scenarioRoot.FullName "fixture.stdout.log"
  $fixtureStderr = Join-Path $scenarioRoot.FullName "fixture.stderr.log"
  $fixture = Start-Process `
    -FilePath (Get-Command pwsh -ErrorAction Stop).Source `
    -ArgumentList @(
      "-NoProfile",
      "-File", $fixtureScript,
      "-Scenario", $Scenario,
      "-Transport", "https",
      "-ReadyFile", $readyFile,
      "-RecordFile", $recordFile,
      "-StopFile", $stopFile,
      "-CertificatePem", $Certificate,
      "-PrivateKeyPem", $PrivateKey
    ) `
    -WindowStyle Hidden `
    -RedirectStandardOutput $fixtureStdout `
    -RedirectStandardError $fixtureStderr `
    -PassThru

  try {
    Wait-ReadyFile -Process $fixture -ReadyFile $readyFile -Stdout $fixtureStdout -Stderr $fixtureStderr
    $ready = (Read-BoundedLines -Path $readyFile) -join "`n" | ConvertFrom-Json
    if ($ready.schema -ne "subversionr.m8-http-fixture-ready.v1" -or
        $ready.port -lt 1 -or $ready.port -gt 65535) {
      throw "The HTTPS fixture readiness record is invalid."
    }

    $probeArguments = @(
      "--mode", "ra-open",
      "--url", "https://127.0.0.1:$($ready.port)/repo",
      "--accept-tls-failures", "12"
    )
    if ($Scenario -in @("tls-later-403", "tls-later-404")) {
      $probeArguments += @("--post-open-check-path", "probe-path")
    }
    $probeResult = Invoke-BoundedProbe `
      -ProbeExe $ProbeExe `
      -Arguments $probeArguments `
      -StageRoot $StageRoot `
      -OutputRoot $scenarioRoot.FullName `
      -AdditionalLogs @($fixtureStdout, $fixtureStderr, $recordFile)
    $probeLines = @($probeResult.Lines)
    $events = @(Convert-ProbeEvents -Lines $probeLines)

    Set-Content -LiteralPath $stopFile -Value "stop" -Encoding ascii -NoNewline
    if (-not $fixture.WaitForExit(5000)) {
      throw "The HTTPS fixture did not stop after the stop signal."
    }
    if ($fixture.ExitCode -ne 0) {
      throw "The HTTPS fixture failed."
    }
    Assert-BoundedLog -Path $fixtureStdout
    Assert-BoundedLog -Path $fixtureStderr
    if ((Get-Item -LiteralPath $fixtureStdout).Length -ne 0 -or
        (Get-Item -LiteralPath $fixtureStderr).Length -ne 0) {
      throw "The HTTPS fixture wrote unexpected process output."
    }
    Assert-NoCredentialLeak -Lines $probeLines -Passwords $ForbiddenSecrets

    Assert-Event -Events $events -Name "provider.first" -Kind "ssl-server-trust"
    Assert-Event -Events $events -Name "provider.save" -Kind "ssl-server-trust"
    $records = @(Read-BoundedLines -Path $recordFile | ForEach-Object {
      $_ | ConvertFrom-Json
    })

    switch ($Scenario) {
      "tls-success" {
        if ($probeResult.ExitCode -ne 0 -or -not ($records | Where-Object {
          $_.method -eq "OPTIONS" -and $_.authorization -eq "anonymous" -and $_.status -eq 200
        })) {
          throw "Anonymous HTTPS DAV RA-open did not succeed."
        }
        Assert-EventSequence -Events $events -Expected @(
          "probe.started", "provider.first", "provider.save", "provider.save",
          "ra.opened", "probe.completed"
        )
      }
      "tls-later-403" {
        if ($probeResult.ExitCode -eq 0) {
          throw "The later HTTPS DAV 403 unexpectedly succeeded."
        }
        Assert-EventSequence -Events $events -Expected @(
          "probe.started", "provider.first", "provider.save", "provider.save",
          "ra.opened", "provider.save", "ra.failed"
        )
      }
      "tls-later-404" {
        if ($probeResult.ExitCode -ne 0) {
          throw "The later HTTPS DAV missing path was not typed as none."
        }
        Assert-Event -Events $events -Name "ra.check-path" -Kind "none"
        Assert-EventSequence -Events $events -Expected @(
          "probe.started", "provider.first", "provider.save", "provider.save", "ra.opened",
          "provider.save", "ra.check-path", "probe.completed"
        )
      }
      "tls-termination-before-dav" {
        if ($probeResult.ExitCode -eq 0 -or $events.event -contains "ra.opened" -or
            -not ($records | Where-Object {
              $_.event -eq "tls.handshake" -and $_.status -eq "terminated-before-dav"
            })) {
          throw "TLS termination before DAV produced invalid settlement evidence."
        }
        Assert-EventSequence -Events $events -Expected @(
          "probe.started", "provider.first", "provider.save", "ra.failed"
        )
      }
    }

    Write-Output (@{
      event = "fixture.assertion"
      scenario = $Scenario
      verdict = "passed"
    } | ConvertTo-Json -Compress)
  }
  finally {
    if (-not (Test-Path -LiteralPath $stopFile)) {
      Set-Content -LiteralPath $stopFile -Value "stop" -Encoding ascii -NoNewline
    }
    Stop-ControlledProcess -Process $fixture
  }
}

if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
  throw "cmake is required to build the M8 settlement fixture probe."
}
foreach ($requiredFile in @(
  $VsDevCmd,
  $OpenSslExe,
  (Join-Path $sourceRoot "CMakeLists.txt"),
  (Join-Path $sourceRoot "probe.c"),
  $fixtureScript,
  $openSslConfig
)) {
  Assert-RequiredFile $requiredFile "M8 settlement fixture dependency"
}

$stageRootResolved = (Resolve-Path -LiteralPath $SubversionStageRoot -ErrorAction Stop).Path
$openSslResolved = (Resolve-Path -LiteralPath $OpenSslExe -ErrorAction Stop).Path
Assert-SubversionStageForBridge `
  -StageRoot $stageRootResolved `
  -WorkspaceRoot $repoRoot `
  -SourceLockPath $sourceLockPath `
  -ExpectedArch $Arch `
  -ExpectedConfiguration $Configuration | Out-Null

$generatedRoot = Join-Path $repoRoot "target\native\m8-remote-settlement-fixtures\$Arch\$Configuration"
Clear-NativeGeneratedDirectory `
  -Path $generatedRoot `
  -WorkspaceRoot $repoRoot `
  -Description "M8 remote settlement fixture root" | Out-Null
$buildRoot = Join-Path $generatedRoot "probe-build"
$runRoot = Join-Path $generatedRoot "run"
New-Item -ItemType Directory -Path $runRoot | Out-Null

$configureCommand = "call $(Quote-CmdArgument $VsDevCmd) -arch=$Arch -host_arch=$Arch && " +
  "cmake -S $(Quote-CmdArgument $sourceRoot) -B $(Quote-CmdArgument $buildRoot) " +
  "-G `"Visual Studio 17 2022`" -A $Arch " +
  "-DSVN_ROOT=$(Quote-CmdArgument $stageRootResolved)"
cmd.exe /d /s /c $configureCommand
if ($LASTEXITCODE -ne 0) {
  throw "M8 settlement fixture probe configuration failed."
}

$buildCommand = "call $(Quote-CmdArgument $VsDevCmd) -arch=$Arch -host_arch=$Arch && " +
  "cmake --build $(Quote-CmdArgument $buildRoot) --config $Configuration --parallel"
cmd.exe /d /s /c $buildCommand
if ($LASTEXITCODE -ne 0) {
  throw "M8 settlement fixture probe build failed."
}

$probeExe = Join-Path $buildRoot "$Configuration\m8_remote_settlement_probe.exe"
Assert-RequiredFile $probeExe "M8 settlement fixture probe executable"

$passwordBytes = [byte[]]::new(32)
[Security.Cryptography.RandomNumberGenerator]::Fill($passwordBytes)
$fixturePassword = [Convert]::ToBase64String($passwordBytes)
$secondaryPasswordBytes = [byte[]]::new(32)
[Security.Cryptography.RandomNumberGenerator]::Fill($secondaryPasswordBytes)
$secondaryFixturePassword = [Convert]::ToBase64String($secondaryPasswordBytes)
$env:SUBVERSIONR_M8_FIXTURE_PASSWORD = $fixturePassword
$env:SUBVERSIONR_M8_FIXTURE_CLIENT_PASSWORD = $fixturePassword
$env:SUBVERSIONR_M8_FIXTURE_CLIENT_PASSWORD_2 = $secondaryFixturePassword
try {
  foreach ($scenario in @(
    "basic-success",
    "basic-direct-403",
    "basic-later-dav-failure",
    "basic-rejection",
    "basic-termination",
    "basic-later-403",
    "basic-later-404",
    "basic-later-409"
  )) {
    Invoke-BasicFixtureScenario `
      -Scenario $scenario `
      -ProbeExe $probeExe `
      -StageRoot $stageRootResolved `
      -RunRoot $runRoot `
      -Passwords @($fixturePassword, $secondaryFixturePassword)
  }
}
finally {
  Remove-Item Env:SUBVERSIONR_M8_FIXTURE_PASSWORD -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_M8_FIXTURE_CLIENT_PASSWORD -ErrorAction SilentlyContinue
  Remove-Item Env:SUBVERSIONR_M8_FIXTURE_CLIENT_PASSWORD_2 -ErrorAction SilentlyContinue
}

$tlsCertificate = New-TlsFixtureCertificate -RunRoot $runRoot -OpenSsl $openSslResolved
foreach ($scenario in @(
  "tls-success",
  "tls-later-403",
  "tls-later-404",
  "tls-termination-before-dav"
)) {
  Invoke-TlsFixtureScenario `
    -Scenario $scenario `
    -ProbeExe $probeExe `
    -StageRoot $stageRootResolved `
    -RunRoot $runRoot `
    -Certificate $tlsCertificate.Certificate `
    -PrivateKey $tlsCertificate.PrivateKey `
    -ForbiddenSecrets @($fixturePassword, $secondaryFixturePassword)
}

Write-Output (@{
  event = "gate.verdict"
  gate = "server-auth-settlement"
  verdict = "closed-by-controlled-fixture"
  gateClosed = $true
} | ConvertTo-Json -Compress)

Write-Output (@{
  event = "gate.verdict"
  gate = "tls-trust-settlement"
  verdict = "closed-by-controlled-fixture"
  gateClosed = $true
} | ConvertTo-Json -Compress)

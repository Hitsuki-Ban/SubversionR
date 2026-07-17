[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$KeyscanInputPath,

  [Parameter(Mandatory = $true)]
  [string]$ExpectedKnownHost
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$MaxProcessOutputBytes = 65536
$MaxJsonBytes = 65536
$ProcessTimeoutMilliseconds = 10000
$ProbeHost = "probe.invalid"
$ProbeUser = "subversionr-probe"
$ProbeKnownHostsPath = "C:/SubversionRProbe/known_hosts"
$ProbeIdentityPath = "C:/SubversionRProbe/identity_ed25519"
$ProbeAgentPublicKeyPath = "C:/SubversionRProbe/identity_ed25519.pub"
$WindowsOpenSshAgentPipe = "//./pipe/openssh-ssh-agent"

function Fail-Probe {
  param([Parameter(Mandatory = $true)][string]$Code)

  throw [System.InvalidOperationException]::new($Code)
}

function Write-BoundedJson {
  param(
    [Parameter(Mandatory = $true)][object]$Value,
    [Parameter(Mandatory = $true)][int]$ExitCode
  )

  $json = $Value | ConvertTo-Json -Depth 8 -Compress
  if ([System.Text.Encoding]::UTF8.GetByteCount($json) -gt $MaxJsonBytes) {
    $json = '{"schemaVersion":1,"probe":"m8-i1-openssh-gate7","status":"failed","failure":"PROBE_JSON_TOO_LARGE"}'
    $ExitCode = 1
  }
  [Console]::Out.WriteLine($json)
  if ($ExitCode -ne 0) {
    exit $ExitCode
  }
}

function Get-CanonicalExistingItem {
  param(
    [Parameter(Mandatory = $true)][string]$LiteralPath,
    [Parameter(Mandatory = $true)][bool]$RequireDirectory,
    [Parameter(Mandatory = $true)][string]$FailurePrefix
  )

  if (-not (Test-Path -LiteralPath $LiteralPath)) {
    Fail-Probe "${FailurePrefix}_MISSING"
  }

  $item = Get-Item -LiteralPath $LiteralPath -Force
  if ($RequireDirectory -and -not $item.PSIsContainer) {
    Fail-Probe "${FailurePrefix}_NOT_DIRECTORY"
  }
  if (-not $RequireDirectory -and $item.PSIsContainer) {
    Fail-Probe "${FailurePrefix}_NOT_FILE"
  }
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    Fail-Probe "${FailurePrefix}_REPARSE_POINT"
  }

  $fullPath = [System.IO.Path]::GetFullPath($item.FullName)
  $resolvedPath = (Resolve-Path -LiteralPath $item.FullName).ProviderPath
  $resolvedFullPath = [System.IO.Path]::GetFullPath($resolvedPath)
  if (-not [string]::Equals($fullPath, $resolvedFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    Fail-Probe "${FailurePrefix}_NON_CANONICAL"
  }

  return [pscustomobject]@{
    Item = $item
    Path = $resolvedFullPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar)
  }
}

function Invoke-BoundedProcess {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$FailurePrefix
  )

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FilePath
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  foreach ($argument in $Arguments) {
    [void]$startInfo.ArgumentList.Add($argument)
  }

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  $stdoutBytes = $null
  $stderrBytes = $null
  try {
    if (-not $process.Start()) {
      Fail-Probe "${FailurePrefix}_START_FAILED"
    }

    $stdoutStream = $process.StandardOutput.BaseStream
    $stderrStream = $process.StandardError.BaseStream
    $stdoutBytes = [System.IO.MemoryStream]::new()
    $stderrBytes = [System.IO.MemoryStream]::new()
    $stdoutBuffer = [byte[]]::new(4096)
    $stderrBuffer = [byte[]]::new(4096)
    $stdoutTask = $stdoutStream.ReadAsync($stdoutBuffer, 0, $stdoutBuffer.Length)
    $stderrTask = $stderrStream.ReadAsync($stderrBuffer, 0, $stderrBuffer.Length)
    $exitTask = $process.WaitForExitAsync()
    $deadline = [System.Diagnostics.Stopwatch]::StartNew()

    while ($null -ne $stdoutTask -or $null -ne $stderrTask -or -not $exitTask.IsCompleted) {
      $remaining = $ProcessTimeoutMilliseconds - [int]$deadline.ElapsedMilliseconds
      if ($remaining -le 0) {
        if (-not $process.HasExited) {
          $process.Kill($true)
          $process.WaitForExit()
        }
        Fail-Probe "${FailurePrefix}_TIMED_OUT"
      }

      $pending = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
      if ($null -ne $stdoutTask) {
        $pending.Add($stdoutTask)
      }
      if ($null -ne $stderrTask) {
        $pending.Add($stderrTask)
      }
      if (-not $exitTask.IsCompleted) {
        $pending.Add($exitTask)
      }
      if ([System.Threading.Tasks.Task]::WaitAny($pending.ToArray(), $remaining) -lt 0) {
        if (-not $process.HasExited) {
          $process.Kill($true)
          $process.WaitForExit()
        }
        Fail-Probe "${FailurePrefix}_TIMED_OUT"
      }

      if ($null -ne $stdoutTask -and $stdoutTask.IsCompleted) {
        $count = $stdoutTask.GetAwaiter().GetResult()
        if ($count -eq 0) {
          $stdoutTask = $null
        } else {
          if ($stdoutBytes.Length + $count -gt $MaxProcessOutputBytes) {
            if (-not $process.HasExited) {
              $process.Kill($true)
              $process.WaitForExit()
            }
            Fail-Probe "${FailurePrefix}_OUTPUT_TOO_LARGE"
          }
          $stdoutBytes.Write($stdoutBuffer, 0, $count)
          $stdoutTask = $stdoutStream.ReadAsync($stdoutBuffer, 0, $stdoutBuffer.Length)
        }
      }
      if ($null -ne $stderrTask -and $stderrTask.IsCompleted) {
        $count = $stderrTask.GetAwaiter().GetResult()
        if ($count -eq 0) {
          $stderrTask = $null
        } else {
          if ($stderrBytes.Length + $count -gt $MaxProcessOutputBytes) {
            if (-not $process.HasExited) {
              $process.Kill($true)
              $process.WaitForExit()
            }
            Fail-Probe "${FailurePrefix}_OUTPUT_TOO_LARGE"
          }
          $stderrBytes.Write($stderrBuffer, 0, $count)
          $stderrTask = $stderrStream.ReadAsync($stderrBuffer, 0, $stderrBuffer.Length)
        }
      }
    }

    $process.WaitForExit()
    $stdout = [System.Text.Encoding]::UTF8.GetString($stdoutBytes.ToArray())
    $stderr = [System.Text.Encoding]::UTF8.GetString($stderrBytes.ToArray())
    if ($process.ExitCode -ne 0) {
      Fail-Probe "${FailurePrefix}_EXIT_$($process.ExitCode)"
    }
    return [pscustomobject]@{
      Stdout = $stdout
      Stderr = $stderr
    }
  } finally {
    if ($null -ne $stdoutBytes) {
      $stdoutBytes.Dispose()
    }
    if ($null -ne $stderrBytes) {
      $stderrBytes.Dispose()
    }
    $process.Dispose()
  }
}

function ConvertFrom-SshConfigDump {
  param([Parameter(Mandatory = $true)][string]$Text)

  $values = @{}
  foreach ($line in ($Text -split "`r?`n")) {
    if ($line.Length -eq 0) {
      continue
    }
    if ($line -notmatch '^(?<key>[a-z0-9]+)[ \t]+(?<value>.+)$') {
      Fail-Probe "SSH_CONFIG_OUTPUT_INVALID"
    }
    $key = $Matches.key
    $value = $Matches.value
    if ($values.ContainsKey($key)) {
      $values[$key] = @($values[$key]) + @($value)
    } else {
      $values[$key] = @($value)
    }
  }
  return $values
}

function Get-SingleSshConfigValue {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Values,
    [Parameter(Mandatory = $true)][string]$Key
  )

  if (-not $Values.ContainsKey($Key) -or @($Values[$Key]).Count -ne 1) {
    Fail-Probe "SSH_CONFIG_${Key}_MISSING_OR_DUPLICATE"
  }
  return [string]@($Values[$Key])[0]
}

function Assert-SshConfigValue {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Values,
    [Parameter(Mandatory = $true)][string]$Key,
    [Parameter(Mandatory = $true)][string]$Expected
  )

  $actual = Get-SingleSshConfigValue -Values $Values -Key $Key
  if (-not [string]::Equals($actual, $Expected, [System.StringComparison]::Ordinal)) {
    Fail-Probe "SSH_CONFIG_${Key}_UNEXPECTED"
  }
}

function ConvertTo-StrictBoolean {
  param(
    [Parameter(Mandatory = $true)][string]$Value,
    [Parameter(Mandatory = $true)][string]$Key
  )

  if ($Value -eq "yes" -or $Value -eq "true") {
    return $true
  }
  if ($Value -eq "no" -or $Value -eq "false") {
    return $false
  }
  Fail-Probe "SSH_CONFIG_${Key}_BOOLEAN_INVALID"
}

function Assert-SshConfigBoolean {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Values,
    [Parameter(Mandatory = $true)][string]$Key,
    [Parameter(Mandatory = $true)][bool]$Expected
  )

  $actual = ConvertTo-StrictBoolean -Value (Get-SingleSshConfigValue -Values $Values -Key $Key) -Key $Key
  if ($actual -ne $Expected) {
    Fail-Probe "SSH_CONFIG_${Key}_UNEXPECTED"
  }
}

function Assert-SshConfigDisabledCommand {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Values,
    [Parameter(Mandatory = $true)][string]$Key
  )

  if (-not $Values.ContainsKey($Key)) {
    return
  }
  Assert-SshConfigValue -Values $Values -Key $Key -Expected "none"
}

function Get-StringArraySha256 {
  param([Parameter(Mandatory = $true)][string[]]$Values)

  $builder = [System.Text.StringBuilder]::new()
  foreach ($value in $Values) {
    [void]$builder.Append($value.Length)
    [void]$builder.Append(":")
    [void]$builder.Append($value)
    [void]$builder.Append(";")
  }
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($builder.ToString())
  return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Test-SshEffectiveConfig {
  param(
    [Parameter(Mandatory = $true)][string]$SshPath,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string[]]$CommonArguments,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ModeArguments
  )

  $arguments = @($CommonArguments) + @($ModeArguments) + @($ProbeHost)
  $result = Invoke-BoundedProcess -FilePath $SshPath -Arguments $arguments -FailurePrefix "SSH_CONFIG_$($Mode.ToUpperInvariant())"
  $values = ConvertFrom-SshConfigDump -Text $result.Stdout

  Assert-SshConfigValue -Values $values -Key "hostname" -Expected $ProbeHost
  Assert-SshConfigValue -Values $values -Key "user" -Expected $ProbeUser
  Assert-SshConfigValue -Values $values -Key "port" -Expected "22"
  Assert-SshConfigValue -Values $values -Key "userknownhostsfile" -Expected $ProbeKnownHostsPath
  Assert-SshConfigValue -Values $values -Key "globalknownhostsfile" -Expected "NUL"
  Assert-SshConfigValue -Values $values -Key "hostkeyalgorithms" -Expected "ssh-ed25519"
  Assert-SshConfigBoolean -Values $values -Key "stricthostkeychecking" -Expected $true
  Assert-SshConfigBoolean -Values $values -Key "checkhostip" -Expected $false
  Assert-SshConfigBoolean -Values $values -Key "updatehostkeys" -Expected $false
  Assert-SshConfigBoolean -Values $values -Key "verifyhostkeydns" -Expected $false
  Assert-SshConfigBoolean -Values $values -Key "canonicalizehostname" -Expected $false
  Assert-SshConfigBoolean -Values $values -Key "controlmaster" -Expected $false
  Assert-SshConfigBoolean -Values $values -Key "controlpersist" -Expected $false
  Assert-SshConfigBoolean -Values $values -Key "forwardagent" -Expected $false
  Assert-SshConfigBoolean -Values $values -Key "forwardx11" -Expected $false
  Assert-SshConfigBoolean -Values $values -Key "clearallforwardings" -Expected $true
  Assert-SshConfigBoolean -Values $values -Key "requesttty" -Expected $false
  Assert-SshConfigBoolean -Values $values -Key "addkeystoagent" -Expected $false
  Assert-SshConfigBoolean -Values $values -Key "exitonforwardfailure" -Expected $true
  Assert-SshConfigValue -Values $values -Key "connectionattempts" -Expected "1"
  Assert-SshConfigDisabledCommand -Values $values -Key "knownhostscommand"
  Assert-SshConfigDisabledCommand -Values $values -Key "proxycommand"
  Assert-SshConfigDisabledCommand -Values $values -Key "proxyjump"
  Assert-SshConfigDisabledCommand -Values $values -Key "controlpath"

  if ($Mode -eq "identity") {
    Assert-SshConfigBoolean -Values $values -Key "batchmode" -Expected $true
    Assert-SshConfigValue -Values $values -Key "preferredauthentications" -Expected "publickey"
    Assert-SshConfigBoolean -Values $values -Key "pubkeyauthentication" -Expected $true
    Assert-SshConfigBoolean -Values $values -Key "passwordauthentication" -Expected $false
    Assert-SshConfigBoolean -Values $values -Key "kbdinteractiveauthentication" -Expected $false
    Assert-SshConfigBoolean -Values $values -Key "gssapiauthentication" -Expected $false
    Assert-SshConfigBoolean -Values $values -Key "hostbasedauthentication" -Expected $false
    Assert-SshConfigBoolean -Values $values -Key "identitiesonly" -Expected $true
    Assert-SshConfigValue -Values $values -Key "identityagent" -Expected "none"
    Assert-SshConfigValue -Values $values -Key "identityfile" -Expected $ProbeIdentityPath
    Assert-SshConfigValue -Values $values -Key "certificatefile" -Expected "none"
  } elseif ($Mode -eq "agent") {
    Assert-SshConfigBoolean -Values $values -Key "batchmode" -Expected $true
    Assert-SshConfigValue -Values $values -Key "preferredauthentications" -Expected "publickey"
    Assert-SshConfigBoolean -Values $values -Key "pubkeyauthentication" -Expected $true
    Assert-SshConfigBoolean -Values $values -Key "passwordauthentication" -Expected $false
    Assert-SshConfigBoolean -Values $values -Key "kbdinteractiveauthentication" -Expected $false
    Assert-SshConfigBoolean -Values $values -Key "gssapiauthentication" -Expected $false
    Assert-SshConfigBoolean -Values $values -Key "hostbasedauthentication" -Expected $false
    Assert-SshConfigBoolean -Values $values -Key "identitiesonly" -Expected $true
    Assert-SshConfigValue -Values $values -Key "identityagent" -Expected $WindowsOpenSshAgentPipe
    Assert-SshConfigValue -Values $values -Key "identityfile" -Expected $ProbeAgentPublicKeyPath
    Assert-SshConfigValue -Values $values -Key "certificatefile" -Expected "none"
  } elseif ($Mode -eq "password") {
    Assert-SshConfigBoolean -Values $values -Key "batchmode" -Expected $false
    Assert-SshConfigValue -Values $values -Key "preferredauthentications" -Expected "password"
    Assert-SshConfigBoolean -Values $values -Key "pubkeyauthentication" -Expected $false
    Assert-SshConfigBoolean -Values $values -Key "passwordauthentication" -Expected $true
    Assert-SshConfigBoolean -Values $values -Key "kbdinteractiveauthentication" -Expected $false
    Assert-SshConfigBoolean -Values $values -Key "gssapiauthentication" -Expected $false
    Assert-SshConfigBoolean -Values $values -Key "hostbasedauthentication" -Expected $false
    Assert-SshConfigBoolean -Values $values -Key "identitiesonly" -Expected $true
    Assert-SshConfigValue -Values $values -Key "identityagent" -Expected "none"
    Assert-SshConfigValue -Values $values -Key "identityfile" -Expected "none"
    Assert-SshConfigValue -Values $values -Key "certificatefile" -Expected "none"
    Assert-SshConfigValue -Values $values -Key "numberofpasswordprompts" -Expected "1"
  } elseif ($Mode -ne "common") {
    Fail-Probe "SSH_CONFIG_MODE_INVALID"
  }

  return [ordered]@{
    validated = $true
    argumentSha256 = Get-StringArraySha256 -Values $arguments
  }
}

function Read-UInt32BigEndian {
  param(
    [Parameter(Mandatory = $true)][byte[]]$Bytes,
    [Parameter(Mandatory = $true)][int]$Offset
  )

  if ($Offset -lt 0 -or $Offset + 4 -gt $Bytes.Length) {
    Fail-Probe "KEYSCAN_BLOB_TRUNCATED"
  }
  return (
    ([uint32]$Bytes[$Offset] -shl 24) -bor
    ([uint32]$Bytes[$Offset + 1] -shl 16) -bor
    ([uint32]$Bytes[$Offset + 2] -shl 8) -bor
    [uint32]$Bytes[$Offset + 3]
  )
}

function Assert-ExpectedKnownHost {
  param([Parameter(Mandatory = $true)][string]$Value)

  if ($Value.Length -eq 0 -or $Value.Length -gt 512 -or $Value -match '[\s,*!|@#]') {
    Fail-Probe "KEYSCAN_EXPECTED_HOST_INVALID"
  }
  if ($Value.StartsWith("[", [System.StringComparison]::Ordinal)) {
    if ($Value -notmatch '^\[(?<host>[A-Za-z0-9._:-]+)\]:(?<port>[0-9]+)$') {
      Fail-Probe "KEYSCAN_EXPECTED_HOST_INVALID"
    }
    $port = [int]$Matches.port
    if ($port -lt 1 -or $port -gt 65535 -or $Matches.host.StartsWith("-", [System.StringComparison]::Ordinal)) {
      Fail-Probe "KEYSCAN_EXPECTED_HOST_INVALID"
    }
  } elseif ($Value -notmatch '^[A-Za-z0-9._:-]+$' -or $Value.StartsWith("-", [System.StringComparison]::Ordinal)) {
    Fail-Probe "KEYSCAN_EXPECTED_HOST_INVALID"
  }
}

function Get-KeyscanEvidence {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$KnownHost
  )

  Assert-ExpectedKnownHost -Value $KnownHost
  $inputItem = Get-CanonicalExistingItem -LiteralPath $InputPath -RequireDirectory $false -FailurePrefix "KEYSCAN_INPUT"
  if ($inputItem.Item.Length -gt $MaxProcessOutputBytes) {
    Fail-Probe "KEYSCAN_INPUT_TOO_LARGE"
  }
  $inputBytes = [System.IO.File]::ReadAllBytes($inputItem.Path)
  if ([Array]::IndexOf($inputBytes, [byte]0) -ge 0) {
    Fail-Probe "KEYSCAN_INPUT_NUL"
  }
  $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
  try {
    $text = $strictUtf8.GetString($inputBytes)
  } catch [System.Text.DecoderFallbackException] {
    Fail-Probe "KEYSCAN_INPUT_NOT_UTF8"
  }

  $recordCount = 0
  $canonicalBlob = $null
  foreach ($line in ($text -split "`r?`n")) {
    if ($line.Length -eq 0 -or $line.StartsWith("#", [System.StringComparison]::Ordinal)) {
      continue
    }
    if ($line.Length -gt 8192 -or $line -notmatch '^(?<host>[^\s]+)[ \t]+(?<type>[^\s]+)[ \t]+(?<blob>[^\s]+)$') {
      Fail-Probe "KEYSCAN_RECORD_INVALID"
    }
    if (-not [string]::Equals($Matches.host, $KnownHost, [System.StringComparison]::Ordinal)) {
      Fail-Probe "KEYSCAN_HOST_MISMATCH"
    }
    if ($Matches.type -ne "ssh-ed25519") {
      Fail-Probe "KEYSCAN_ALGORITHM_UNEXPECTED"
    }
    $blobText = $Matches.blob
    if ($blobText -notmatch '^[A-Za-z0-9+/]+={0,2}$') {
      Fail-Probe "KEYSCAN_BASE64_INVALID"
    }
    try {
      $blob = [Convert]::FromBase64String($blobText)
    } catch [System.FormatException] {
      Fail-Probe "KEYSCAN_BASE64_INVALID"
    }
    if ([Convert]::ToBase64String($blob) -ne $blobText) {
      Fail-Probe "KEYSCAN_BASE64_NON_CANONICAL"
    }

    $algorithmLength = Read-UInt32BigEndian -Bytes $blob -Offset 0
    if ($algorithmLength -ne 11 -or 4 + $algorithmLength + 4 -gt $blob.Length) {
      Fail-Probe "KEYSCAN_BLOB_INVALID"
    }
    $algorithm = [System.Text.Encoding]::ASCII.GetString($blob, 4, [int]$algorithmLength)
    if ($algorithm -ne "ssh-ed25519") {
      Fail-Probe "KEYSCAN_BLOB_ALGORITHM_MISMATCH"
    }
    $keyLengthOffset = 4 + [int]$algorithmLength
    $keyLength = Read-UInt32BigEndian -Bytes $blob -Offset $keyLengthOffset
    $keyOffset = $keyLengthOffset + 4
    if ($keyLength -ne 32 -or $keyOffset + $keyLength -ne $blob.Length) {
      Fail-Probe "KEYSCAN_BLOB_KEY_INVALID"
    }

    if ($null -eq $canonicalBlob) {
      $canonicalBlob = $blobText
    } elseif (-not [string]::Equals($canonicalBlob, $blobText, [System.StringComparison]::Ordinal)) {
      Fail-Probe "KEYSCAN_MULTIPLE_KEYS"
    }
    $recordCount += 1
  }

  if ($recordCount -ne 1 -or $null -eq $canonicalBlob) {
    Fail-Probe "KEYSCAN_RECORD_COUNT_INVALID"
  }
  $canonicalBytes = [Convert]::FromBase64String($canonicalBlob)
  $fingerprint = [Convert]::ToBase64String([System.Security.Cryptography.SHA256]::HashData($canonicalBytes)).TrimEnd("=")
  return [ordered]@{
    validated = $true
    recordCount = $recordCount
    host = $KnownHost
    algorithm = "ssh-ed25519"
    fingerprint = "SHA256:$fingerprint"
    knownHostsLine = "$KnownHost ssh-ed25519 $canonicalBlob"
    inputSha256 = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($inputBytes)).ToLowerInvariant()
  }
}

try {
  if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Fail-Probe "WINDOWS_REQUIRED"
  }
  if ([string]::IsNullOrWhiteSpace($KeyscanInputPath) -xor [string]::IsNullOrWhiteSpace($ExpectedKnownHost)) {
    Fail-Probe "KEYSCAN_INPUT_AND_HOST_REQUIRED_TOGETHER"
  }

  $systemDirectoryItem = Get-CanonicalExistingItem -LiteralPath ([System.Environment]::SystemDirectory) -RequireDirectory $true -FailurePrefix "SYSTEM_DIRECTORY"
  $openSshDirectoryPath = Join-Path $systemDirectoryItem.Path "OpenSSH"
  $openSshDirectoryItem = Get-CanonicalExistingItem -LiteralPath $openSshDirectoryPath -RequireDirectory $true -FailurePrefix "OPENSSH_DIRECTORY"

  $expectedFiles = @("ssh.exe", "ssh-keyscan.exe", "ssh-keygen.exe")
  $fileEvidence = @()
  foreach ($expectedFile in $expectedFiles) {
    $candidatePath = Join-Path $openSshDirectoryItem.Path $expectedFile
    $candidate = Get-CanonicalExistingItem -LiteralPath $candidatePath -RequireDirectory $false -FailurePrefix ("OPENSSH_" + $expectedFile.Replace("-", "_").Replace(".", "_").ToUpperInvariant())
    if ($candidate.Item.Name -cne $expectedFile) {
      Fail-Probe "OPENSSH_FILENAME_MISMATCH"
    }
    $candidateParent = [System.IO.Path]::GetFullPath($candidate.Item.DirectoryName).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    if (-not [string]::Equals($candidateParent, $openSshDirectoryItem.Path, [System.StringComparison]::OrdinalIgnoreCase)) {
      Fail-Probe "OPENSSH_PARENT_MISMATCH"
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $candidate.Path
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
      Fail-Probe "OPENSSH_SIGNATURE_INVALID"
    }
    if ($signature.SignatureType.ToString() -ne "Catalog" -or $signature.IsOSBinary -ne $true) {
      Fail-Probe "OPENSSH_NOT_CATALOG_OS_BINARY"
    }
    if ($null -eq $signature.SignerCertificate) {
      Fail-Probe "OPENSSH_SIGNER_MISSING"
    }
    $publisher = $signature.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    if (
      $publisher -ne "Microsoft Windows" -or
      $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)'
    ) {
      Fail-Probe "OPENSSH_PUBLISHER_INVALID"
    }

    $fileVersion = $candidate.Item.VersionInfo.FileVersion
    $productVersion = $candidate.Item.VersionInfo.ProductVersion
    if ([string]::IsNullOrWhiteSpace($fileVersion) -or [string]::IsNullOrWhiteSpace($productVersion)) {
      Fail-Probe "OPENSSH_VERSION_MISSING"
    }
    $fileEvidence += [ordered]@{
      name = $expectedFile
      path = $candidate.Path
      sha256 = (Get-FileHash -LiteralPath $candidate.Path -Algorithm SHA256).Hash.ToLowerInvariant()
      signatureType = "Catalog"
      osBinary = $true
      publisher = $publisher
      fileVersion = $fileVersion
      productVersion = $productVersion
    }
  }

  $fileVersions = @($fileEvidence | ForEach-Object { $_["fileVersion"] } | Select-Object -Unique)
  $productVersions = @($fileEvidence | ForEach-Object { $_["productVersion"] } | Select-Object -Unique)
  if ($fileVersions.Count -ne 1 -or $productVersions.Count -ne 1) {
    Fail-Probe "OPENSSH_VERSION_RELATIONSHIP_INVALID"
  }

  $sshEvidence = @($fileEvidence | Where-Object { $_["name"] -eq "ssh.exe" })
  if ($sshEvidence.Count -ne 1) {
    Fail-Probe "OPENSSH_SSH_EXE_RELATIONSHIP_INVALID"
  }
  $sshPath = [string]$sshEvidence[0]["path"]
  $queryResult = Invoke-BoundedProcess -FilePath $sshPath -Arguments @("-Q", "HostKeyAlgorithms") -FailurePrefix "SSH_QUERY_HOST_KEY_ALGORITHMS"
  $hostKeyAlgorithms = @($queryResult.Stdout -split "`r?`n" | Where-Object { $_.Length -gt 0 })
  if (@($hostKeyAlgorithms | Where-Object { $_ -eq "ssh-ed25519" }).Count -ne 1) {
    Fail-Probe "SSH_ED25519_UNAVAILABLE"
  }

  $commonArguments = @(
    "-F", "NUL", "-G", "-p", "22", "-l", $ProbeUser,
    "-o", "UserKnownHostsFile=$ProbeKnownHostsPath",
    "-o", "GlobalKnownHostsFile=NUL",
    "-o", "StrictHostKeyChecking=yes",
    "-o", "CheckHostIP=no",
    "-o", "UpdateHostKeys=no",
    "-o", "VerifyHostKeyDNS=no",
    "-o", "HostKeyAlgorithms=ssh-ed25519",
    "-o", "KnownHostsCommand=none",
    "-o", "CanonicalizeHostname=no",
    "-o", "ProxyCommand=none",
    "-o", "ProxyJump=none",
    "-o", "ControlMaster=no",
    "-o", "ControlPath=none",
    "-o", "ControlPersist=no",
    "-o", "ForwardAgent=no",
    "-o", "ForwardX11=no",
    "-o", "ClearAllForwardings=yes",
    "-o", "RequestTTY=no",
    "-o", "AddKeysToAgent=no",
    "-o", "ExitOnForwardFailure=yes",
    "-o", "ConnectionAttempts=1"
  )
  $identityArguments = @(
    "-o", "BatchMode=yes",
    "-o", "PreferredAuthentications=publickey",
    "-o", "PubkeyAuthentication=yes",
    "-o", "PasswordAuthentication=no",
    "-o", "KbdInteractiveAuthentication=no",
    "-o", "GSSAPIAuthentication=no",
    "-o", "HostbasedAuthentication=no",
    "-o", "IdentitiesOnly=yes",
    "-o", "IdentityAgent=none",
    "-o", "IdentityFile=$ProbeIdentityPath",
    "-o", "CertificateFile=none"
  )
  $agentArguments = @(
    "-o", "BatchMode=yes",
    "-o", "PreferredAuthentications=publickey",
    "-o", "PubkeyAuthentication=yes",
    "-o", "PasswordAuthentication=no",
    "-o", "KbdInteractiveAuthentication=no",
    "-o", "GSSAPIAuthentication=no",
    "-o", "HostbasedAuthentication=no",
    "-o", "IdentitiesOnly=yes",
    "-o", "IdentityAgent=$WindowsOpenSshAgentPipe",
    "-o", "IdentityFile=$ProbeAgentPublicKeyPath",
    "-o", "CertificateFile=none"
  )
  $passwordArguments = @(
    "-o", "BatchMode=no",
    "-o", "PreferredAuthentications=password",
    "-o", "PubkeyAuthentication=no",
    "-o", "PasswordAuthentication=yes",
    "-o", "KbdInteractiveAuthentication=no",
    "-o", "GSSAPIAuthentication=no",
    "-o", "HostbasedAuthentication=no",
    "-o", "IdentitiesOnly=yes",
    "-o", "IdentityAgent=none",
    "-o", "IdentityFile=none",
    "-o", "CertificateFile=none",
    "-o", "NumberOfPasswordPrompts=1"
  )

  $configEvidence = [ordered]@{
    common = Test-SshEffectiveConfig -SshPath $sshPath -Mode "common" -CommonArguments $commonArguments -ModeArguments @()
    identity = Test-SshEffectiveConfig -SshPath $sshPath -Mode "identity" -CommonArguments $commonArguments -ModeArguments $identityArguments
    agent = Test-SshEffectiveConfig -SshPath $sshPath -Mode "agent" -CommonArguments $commonArguments -ModeArguments $agentArguments
    password = Test-SshEffectiveConfig -SshPath $sshPath -Mode "password" -CommonArguments $commonArguments -ModeArguments $passwordArguments
  }

  $keyscanEvidence = $null
  if (-not [string]::IsNullOrWhiteSpace($KeyscanInputPath)) {
    $keyscanEvidence = Get-KeyscanEvidence -InputPath $KeyscanInputPath -KnownHost $ExpectedKnownHost
  }

  $evidence = [ordered]@{
    schemaVersion = 1
    probe = "m8-i1-openssh-gate7"
    status = "passed"
    networkAccess = "none"
    userSshState = "notReadOrWritten"
    installation = [ordered]@{
      systemDirectory = $systemDirectoryItem.Path
      openSshDirectory = $openSshDirectoryItem.Path
      fileVersion = $fileVersions[0]
      productVersion = $productVersions[0]
      files = $fileEvidence
    }
    hostKey = [ordered]@{
      algorithm = "ssh-ed25519"
      queryValidated = $true
    }
    effectiveConfig = $configEvidence
    keyscan = $keyscanEvidence
    runtimeGates = [ordered]@{
      authorityAttribution = "notProbed"
      redirectInterception = "notProbed"
      raSvnRepositoryRoot = "notProbed"
      svnGreetingSettlement = "notProbed"
      sshSecretRejectionSettlement = "notProbed"
      serverResidueOracle = "notProbed"
    }
  }
  Write-BoundedJson -Value $evidence -ExitCode 0
} catch {
  $failure = "PROBE_UNEXPECTED_FAILURE"
  if ($_.Exception -is [System.InvalidOperationException] -and $_.Exception.Message -match '^[A-Z0-9_]+$') {
    $failure = $_.Exception.Message
  }
  Write-BoundedJson -Value ([ordered]@{
    schemaVersion = 1
    probe = "m8-i1-openssh-gate7"
    status = "failed"
    failure = $failure
  }) -ExitCode 1
}

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet(
    "basic-success",
    "basic-direct-403",
    "basic-later-dav-failure",
    "basic-rejection",
    "basic-termination",
    "basic-later-403",
    "basic-later-404",
    "basic-later-409",
    "tls-success",
    "tls-later-403",
    "tls-later-404",
    "tls-termination-before-dav"
  )]
  [string]$Scenario,

  [Parameter(Mandatory = $true)]
  [ValidateSet("http", "https")]
  [string]$Transport,

  [Parameter(Mandatory = $true)]
  [string]$ReadyFile,

  [Parameter(Mandatory = $true)]
  [string]$RecordFile,

  [Parameter(Mandatory = $true)]
  [string]$StopFile,

  [string]$CertificatePem,

  [string]$PrivateKeyPem
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$usesBasic = $Scenario.StartsWith("basic-", [StringComparison]::Ordinal)
if (($Transport -eq "http") -ne $usesBasic) {
  throw "The fixture scenario does not match its transport."
}

$fixtureUsername = "fixture-user"
$expectedAuthorization = $null
if ($usesBasic) {
  $fixturePassword = [Environment]::GetEnvironmentVariable(
    "SUBVERSIONR_M8_FIXTURE_PASSWORD",
    [EnvironmentVariableTarget]::Process
  )
  if ([string]::IsNullOrEmpty($fixturePassword)) {
    throw "The fixture credential environment value must be present and non-empty."
  }
  $credentialBytes = [Text.Encoding]::UTF8.GetBytes("$fixtureUsername`:$fixturePassword")
  $expectedAuthorization = "Basic $([Convert]::ToBase64String($credentialBytes))"
}
elseif ([string]::IsNullOrEmpty($CertificatePem) -or
        [string]::IsNullOrEmpty($PrivateKeyPem)) {
  throw "HTTPS fixtures require explicit certificate and private-key files."
}

foreach ($outputPath in @($ReadyFile, $RecordFile, $StopFile)) {
  if (-not [IO.Path]::IsPathRooted($outputPath)) {
    throw "Fixture coordination paths must be absolute."
  }
  $parent = Split-Path -Parent $outputPath
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    throw "Fixture coordination path parent is missing."
  }
}
if ((Test-Path -LiteralPath $ReadyFile) -or
    (Test-Path -LiteralPath $RecordFile) -or
    (Test-Path -LiteralPath $StopFile)) {
  throw "Fixture coordination paths must not exist before startup."
}

$utf8NoBom = [Text.UTF8Encoding]::new($false)
$maxRecordBytes = 64 * 1024
$maxRequestRecords = 128

function Write-JsonLine([string]$Path, [hashtable]$Value) {
  $line = ($Value | ConvertTo-Json -Compress -Depth 3) + "`n"
  $existingBytes = if (Test-Path -LiteralPath $Path -PathType Leaf) {
    (Get-Item -LiteralPath $Path).Length
  }
  else {
    0
  }
  if ($existingBytes + $utf8NoBom.GetByteCount($line) -gt $maxRecordBytes) {
    throw "HTTP fixture record output exceeded its hard size limit."
  }
  [IO.File]::AppendAllText($Path, $line, $utf8NoBom)
}

function Read-HttpRequest([IO.Stream]$Stream) {
  $Stream.ReadTimeout = 5000
  $reader = [IO.StreamReader]::new($Stream, [Text.Encoding]::ASCII, $false, 1024, $true)
  $requestLine = $reader.ReadLine()
  if ([string]::IsNullOrEmpty($requestLine)) {
    throw "HTTP fixture received an empty request line."
  }
  $parts = $requestLine.Split(' ')
  if ($parts.Count -lt 3 -or [string]::IsNullOrEmpty($parts[0])) {
    throw "HTTP fixture received a malformed request line."
  }
  if ($parts[0] -notmatch '^[A-Z]{1,16}$') {
    throw "HTTP fixture received an invalid method token."
  }

  $authorization = $null
  $headerCount = 0
  while ($true) {
    $line = $reader.ReadLine()
    if ($null -eq $line) {
      throw "HTTP fixture connection ended before the request headers."
    }
    if ($line.Length -eq 0) {
      break
    }
    $headerCount += 1
    if ($headerCount -gt 128) {
      throw "HTTP fixture request exceeded the header-count limit."
    }
    $separator = $line.IndexOf(':')
    if ($separator -gt 0 -and
        $line.Substring(0, $separator).Equals("Authorization", [StringComparison]::OrdinalIgnoreCase)) {
      $authorization = $line.Substring($separator + 1).Trim()
    }
  }

  return [pscustomobject]@{
    Method = $parts[0]
    Authorization = $authorization
  }
}

function New-Response([int]$Status, [string[]]$Headers, [string]$Body) {
  $reason = switch ($Status) {
    200 { "OK" }
    207 { "Multi-Status" }
    401 { "Unauthorized" }
    403 { "Forbidden" }
    404 { "Not Found" }
    409 { "Conflict" }
    default { throw "HTTP fixture response status is unsupported." }
  }
  $bodyBytes = $utf8NoBom.GetBytes($Body)
  $lines = @("HTTP/1.1 $Status $reason") + $Headers + @(
    "Content-Length: $($bodyBytes.Length)",
    "Connection: close",
    "",
    ""
  )
  $headerBytes = $utf8NoBom.GetBytes($lines -join "`r`n")
  $response = [byte[]]::new($headerBytes.Length + $bodyBytes.Length)
  [Array]::Copy($headerBytes, 0, $response, 0, $headerBytes.Length)
  [Array]::Copy($bodyBytes, 0, $response, $headerBytes.Length, $bodyBytes.Length)
  return $response
}

function New-OptionsResponse([string]$Body) {
  return New-Response -Status 200 -Headers @(
    "Server: SubversionR-M8-fixture",
    "DAV: 1,2",
    "DAV: version-control,checkout,working-resource",
    "DAV: merge,baseline,activity,version-controlled-collection",
    "DAV: http://subversion.tigris.org/xmlns/dav/svn/depth",
    "DAV: http://subversion.tigris.org/xmlns/dav/svn/log-revprops",
    "DAV: http://subversion.tigris.org/xmlns/dav/svn/atomic-revprops",
    "DAV: http://subversion.tigris.org/xmlns/dav/svn/partial-replay",
    "DAV: http://subversion.tigris.org/xmlns/dav/svn/mergeinfo",
    "MS-Author-Via: DAV",
    "Allow: OPTIONS,GET,HEAD,PROPFIND,REPORT",
    "SVN-Youngest-Rev: 1",
    "SVN-Repository-UUID: 12345678-1234-1234-1234-123456789abc",
    "SVN-Repository-Root: /repo",
    "SVN-Me-Resource: /repo/!svn/me",
    "SVN-Rev-Root-Stub: /repo/!svn/rvr",
    "SVN-Rev-Stub: /repo/!svn/rev",
    "SVN-Txn-Root-Stub: /repo/!svn/txr",
    "SVN-Txn-Stub: /repo/!svn/txn",
    "SVN-VTxn-Root-Stub: /repo/!svn/vtxr",
    "SVN-VTxn-Stub: /repo/!svn/vtxn",
    "SVN-Relative-Path:",
    "SVN-Repository-MergeInfo: yes",
    "SVN-Allow-Bulk-Updates: Prefer",
    "SVN-Supported-Posts: create-txn",
    "Content-Type: text/xml; charset=utf-8"
  ) -Body $Body
}

function New-MultiStatusResponse() {
  $body = @"
<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:" xmlns:V="http://subversion.tigris.org/xmlns/dav/">
  <D:response>
    <D:href>/repo</D:href>
    <D:propstat>
      <D:prop>
        <D:resourcetype><D:collection/></D:resourcetype>
        <D:version-name>1</D:version-name>
        <V:repository-uuid>12345678-1234-1234-1234-123456789abc</V:repository-uuid>
        <V:baseline-relative-path></V:baseline-relative-path>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
</D:multistatus>
"@
  return New-Response -Status 207 -Headers @(
    "Server: SubversionR-M8-fixture",
    "Content-Type: text/xml; charset=utf-8"
  ) -Body $body
}

$optionsBody = @"
<?xml version="1.0" encoding="utf-8"?>
<D:options-response xmlns:D="DAV:">
  <D:activity-collection-set>
    <D:href>/repo/!svn/act</D:href>
  </D:activity-collection-set>
</D:options-response>
"@
$malformedOptionsBody = "<D:options-response xmlns:D=`"DAV:`"><D:activity-collection-set>"

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$serverCertificate = $null
if ($Transport -eq "https") {
  foreach ($certificatePath in @($CertificatePem, $PrivateKeyPem)) {
    if (-not (Test-Path -LiteralPath $certificatePath -PathType Leaf)) {
      throw "An HTTPS fixture certificate input is missing."
    }
  }
  $pemCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile(
    $CertificatePem,
    $PrivateKeyPem
  )
  $serverCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
    $pemCertificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx)
  )
  $pemCertificate.Dispose()
}
$listener.Start()
$deadline = [DateTime]::UtcNow.AddSeconds(30)
$sequence = 0
try {
  $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
  [IO.File]::WriteAllText(
    $ReadyFile,
    (@{ schema = "subversionr.m8-http-fixture-ready.v1"; port = $port } | ConvertTo-Json -Compress),
    $utf8NoBom
  )

  while (-not (Test-Path -LiteralPath $StopFile)) {
    if ([DateTime]::UtcNow -ge $deadline) {
      throw "HTTP fixture deadline expired."
    }
    if (-not $listener.Pending()) {
      Start-Sleep -Milliseconds 10
      continue
    }

    $client = $listener.AcceptTcpClient()
    $applicationStream = $null
    try {
      $networkStream = $client.GetStream()
      if ($Transport -eq "https") {
        $applicationStream = [Net.Security.SslStream]::new($networkStream, $false)
        $applicationStream.AuthenticateAsServer(
          $serverCertificate,
          $false,
          [Security.Authentication.SslProtocols]::Tls12 -bor
            [Security.Authentication.SslProtocols]::Tls13,
          $false
        )
        if ($Scenario -eq "tls-termination-before-dav") {
          $sequence += 1
          Write-JsonLine -Path $RecordFile -Value @{
            event = "tls.handshake"
            sequence = $sequence
            status = "terminated-before-dav"
          }
          continue
        }
      }
      else {
        $applicationStream = $networkStream
      }

      $request = Read-HttpRequest -Stream $applicationStream
      $sequence += 1
      if ($sequence -gt $maxRequestRecords) {
        throw "HTTP fixture exceeded its request-record limit."
      }
      $authorizationState = if (-not $usesBasic) {
        "anonymous"
      }
      elseif ($null -eq $request.Authorization) {
        "missing"
      }
      elseif ($request.Authorization -ceq $expectedAuthorization) {
        "accepted"
      }
      else {
        "rejected"
      }

      $response = $null
      if ($Scenario -eq "basic-rejection") {
        $status = 401
        $response = New-Response -Status 401 -Headers @(
          'WWW-Authenticate: Basic realm="m8-fixture"'
        ) -Body ""
      }
      elseif ($usesBasic -and $authorizationState -ne "accepted") {
        $status = 401
        $response = New-Response -Status 401 -Headers @(
          'WWW-Authenticate: Basic realm="m8-fixture"'
        ) -Body ""
      }
      elseif ($Scenario -eq "basic-direct-403") {
        $status = 403
        $response = New-Response -Status 403 -Headers @() -Body ""
      }
      elseif ($request.Method -eq "OPTIONS" -and $Scenario -eq "basic-later-dav-failure") {
        $status = 200
        $response = New-OptionsResponse -Body $malformedOptionsBody
      }
      elseif ($request.Method -eq "OPTIONS") {
        $status = 200
        $response = New-OptionsResponse -Body $optionsBody
      }
      else {
        switch ($Scenario) {
          { $_ -in @("basic-later-403", "tls-later-403") } {
            $status = 403
            $response = New-Response -Status 403 -Headers @() -Body ""
          }
          "basic-later-404" {
            $status = 404
            $response = New-Response -Status 404 -Headers @() -Body ""
          }
          "tls-later-404" {
            $status = 404
            $response = New-Response -Status 404 -Headers @() -Body ""
          }
          "basic-later-409" {
            $status = 409
            $response = New-Response -Status 409 -Headers @() -Body ""
          }
          default {
            $status = 207
            $response = New-MultiStatusResponse
          }
        }
      }

      if ($Scenario -eq "basic-termination" -and $authorizationState -eq "accepted") {
        $status = 0
        $response = $null
      }

      Write-JsonLine -Path $RecordFile -Value @{
        event = "http.request"
        sequence = $sequence
        method = $request.Method
        authorization = $authorizationState
        status = $status
      }
      if ($null -ne $response) {
        $applicationStream.Write($response, 0, $response.Length)
        $applicationStream.Flush()
      }
    }
    finally {
      if ($null -ne $applicationStream -and
          $applicationStream -is [Net.Security.SslStream]) {
        $applicationStream.Dispose()
      }
      $client.Dispose()
    }
  }
}
finally {
  $listener.Stop()
  if ($null -ne $serverCertificate) {
    $serverCertificate.Dispose()
  }
}

# M8 remote settlement feasibility probes

This directory contains test-only probes. Nothing here is a production remote
access path or a support claim.

Run the complete local fixture matrix from the repository root:

```powershell
pwsh ./scripts/native/smoke-m8-remote-settlement-fixtures.ps1 `
  -SubversionStageRoot ./.cache/native/stage/subversion-win-x64 `
  -OpenSslExe ./.cache/native/stage/subversion-deps-win-x64/bin/openssl.exe `
  -VsDevCmd <absolute-path-to-VsDevCmd.bat>
```

The command requires the manifest-verified locked Subversion stage. It does not
fall back to a system Subversion, Serf, OpenSSL, config directory, or credential
store. Random fixture passwords are passed to child processes only through
fixed process environment variables; neither their values nor variable names
are written to probe JSONL.

## Basic settlement matrix

The controlled HTTP fixture records only method, sequence, authorization state,
and response status.

| Scenario | Controlled response | Required probe result |
| --- | --- | --- |
| `basic-success` | `401`, then authenticated DAV `200` | simple `first`, simple `save`, `ra.opened` |
| `basic-direct-403` | `401`, then authenticated `403` | simple `first`, no simple `save`, `ra.failed` |
| `basic-later-dav-failure` | `401`, then authenticated `200` with malformed DAV XML | simple `first`, simple `save`, then `ra.failed`; the prior save is not reversed |
| `basic-rejection` | repeated authenticated `401` challenges | simple `first`, simple `next`, exhaustion, no save, `ra.failed` |
| `basic-termination` | `401`, then connection termination after Authorization | simple `first`, no save, `ra.failed` |
| `basic-later-403` | accepted DAV RA-open, then post-open `403` | simple `save`, `ra.opened`, `ra.failed` |
| `basic-later-404` | accepted DAV RA-open, then post-open `404` | simple `save`, `ra.opened`, `ra.check-path` kind `none` |
| `basic-later-409` | accepted DAV RA-open, then post-open `409` | simple `save`, `ra.opened`, `ra.failed` |

This matches the locked ra_serf rule: after a 401 challenge it calls
`svn_auth_save_credentials` only when the next response status is below 400.
See
[`libsvn_ra_serf/util.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_serf/util.c#L1401-L1410).

The harness asserts the complete event sequence for every cell and emits a
closed server-auth settlement verdict only after all cells pass.

## TLS verdict

OpenSSL creates one explicit self-signed fixture certificate. The controlled
PowerShell listener serves it through `SslStream`; OpenSSL is not used as the
DAV server. The HTTPS matrix covers anonymous DAV RA-open success, post-open
`403` and typed missing-path `404`, plus termination after the TLS handshake
but before the first DAV response.

The termination cell proves that the trust-provider save callback is not
evidence of a completed initial SVN protocol exchange. The locked source also
places that save in the certificate callback before the session exchange:
[`libsvn_ra_serf/util.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_serf/util.c#L375-L395).

The harness asserts exact callback ordering for every HTTPS cell and emits a
closed TLS trust-settlement verdict only after all cells pass.

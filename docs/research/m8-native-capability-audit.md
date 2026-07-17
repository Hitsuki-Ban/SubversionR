# M8 native capability and tunnel API audit

Status: M8 R2 research input for D1. This report changes no dependency,
product code, capability, release gate, or public claim.

Baseline: SubversionR `3bbebeca3fd29eb57ce95c7a7e9aed548b588a9a`,
Apache Subversion 1.14.5, Serf 1.3.10, and APR 1.7.6 on the locked Windows
`win32-x64` native build.

R1 established the transport/session boundary and evidence gap in
[`m8-remote-access-survey.md`](m8-remote-access-survey.md). R2 narrows the
remaining native questions: which auth providers are actually present, what is
not built, what the RA tunnel callbacks guarantee, and what can be concluded
about FBL-06.

## Issue #116 acceptance mapping

| Requested item | Coverage |
| --- | --- |
| Serf build flags and exact server/proxy auth capability | Section 1 |
| Cyrus SASL state, internal `ra_svn` mechanisms, and enablement cost | Section 2 |
| Windows simple/SSL-trust provider availability and auth-cache compatibility | Section 3 |
| Tunnel callback semantics and daemon-owned process/stream feasibility | Section 4 |
| Default tunnel spawn/lifecycle baseline | Section 5 |
| Timeboxed FBL-06 root-cause inspection | Section 6 |

This report distinguishes **committed evidence** (reproducible from the tree),
**staged observation** (inspection of one locally rebuilt locked artifact), and
**fixture result** (a disposable experiment). A compiled symbol or successful
fixture is not a product policy or support claim.

## Executive findings

1. The locked Windows Serf build compiles Basic, Digest, Negotiate, and NTLM.
   The same Serf authentication framework handles server 401 and proxy 407, but
   credential ownership differs: server Basic/Digest can enter the current
   Subversion auth baton, proxy Basic/Digest comes from `servers` config, and
   Negotiate/NTLM uses the daemon process's Windows token through SSPI.
2. Cyrus SASL is not built into the current Subversion client or svnserve.
   Direct `svn://` is limited to the internal `EXTERNAL`, `ANONYMOUS`, and
   `CRAM-MD5` path. Enabling SASL is a new locked dependency and package/evidence
   variant, not a flag-only change.
3. The Windows DPAPI simple provider and Windows certificate-chain trust
   provider are compiled and exported, but SubversionR registers neither. A
   disposable fixture proved that the platform simple provider can read a
   source-built CLI Wincrypt cache entry with exact `svn:realmstring` keying.
   D1 must choose an explicit provider mode/order and persistence owner; adding
   providers to the current array without that decision would be a hidden
   credential route.
4. The RA tunnel callbacks can carry daemon-owned pipe streams, but their close
   contract is weak: the close callback returns no error, is invoked before
   libsvn closes the two streams, and cannot make blocking stream I/O observe a
   deadline by itself. A reliable Windows design needs cancellable pipe streams
   plus explicit process-tree ownership.
5. `ra_svn` deliberately uses its default tunnel path whenever a custom
   `check_tunnel_func` declines a tunnel. Under SubversionR's no-fallback rule,
   a future custom opener must own every allowed tunnel name and fail unsupported
   names itself; it must never decline into `$SVN_SSH` / `[tunnels]` implicitly.
6. In the merge-preview flow, the two relevant selector routes emit FBL-06's
   exact warning only when the extension-local open-session list is empty before
   the first wizard input. The same literal exists in other command routes, so
   the text alone does not identify one method or invocation. The recorded
   post-wizard chronology cannot be produced by the current preview invocation;
   the historical cause still requires the original build/log/recording.

## 1. Locked Serf and HTTP authentication capability

### 1.1 Committed build evidence

The source lock pins Serf 1.3.10 by URL and SHA-512
(`native/sources.lock.json:36-43`). The dependency builder invokes Serf's SCons
Windows path with MSVC (`scripts/native/build-dependencies.ps1:472-548`). In
Serf 1.3.10 that Windows path defines `SERF_HAVE_SSPI`, which in turn enables
SPNEGO
([`SConstruct`](https://github.com/apache/serf/blob/1.3.10/SConstruct#L399-L408),
[`auth_spnego.h`](https://github.com/apache/serf/blob/1.3.10/auth/auth_spnego.h#L29-L37)).

Serf's ordered scheme table is:

1. Negotiate;
2. NTLM on Win32;
3. Digest;
4. Basic.

The scheme table and challenge dispatcher support both server 401 and proxy 407
([`auth.c`](https://github.com/apache/serf/blob/1.3.10/auth/auth.c#L42-L99),
[`auth.c`](https://github.com/apache/serf/blob/1.3.10/auth/auth.c#L141-L219)).
Subversion passes all Serf auth types when `http-auth-types` is absent
([`ra_serf/serf.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_serf/serf.c#L98-L144)).

This yields the following dependency-level routes:

| Challenge | Basic / Digest | Negotiate / NTLM |
| --- | --- | --- |
| Server 401 | Serf asks `ra_serf`, which requests `SVN_AUTH_CRED_SIMPLE`; the current simple prompt provider can reach the TS broker. | Serf SSPI acquires the daemon process's current Windows credentials; the TS credential broker is not involved. |
| Proxy 407 | `ra_serf` supplies `http-proxy-username` / `http-proxy-password` from the selected Subversion `servers` group; the current broker is not involved. | Serf SSPI authenticates to the proxy with the daemon process's Windows token. |

Sources: [`ra_serf/util.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_serf/util.c#L1182-L1261),
[`ra_serf/serf.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_serf/serf.c#L206-L223),
[`auth_basic.c`](https://github.com/apache/serf/blob/1.3.10/auth/auth_basic.c#L53-L116),
and [`auth_digest.c`](https://github.com/apache/serf/blob/1.3.10/auth/auth_digest.c#L251-L337).
The SSPI backend calls `AcquireCredentialsHandleA` with a null principal, so it
uses the process token rather than a username/password supplied by the broker
([`auth_spnego_sspi.c`](https://github.com/apache/serf/blob/1.3.10/auth/auth_spnego_sspi.c#L118-L157)).

The current native build therefore makes VisualSVN-style IWA reachable at the
dependency layer without adding a library. It does **not** prove a selected
SSPI policy, daemon-token suitability, Kerberos or NTLM interoperability,
background behavior, proxy behavior, or any product claim.

### 1.2 Staged artifact observation and missing gate

One locally rebuilt locked stage was inspected. Its `libsvn_ra-1.dll` SHA-256
was `540EB8419D7339E7E2B9D1C269A0FA4CCEC44D7F86D3B40394AAF2708BB7C049`.
PE imports included `Secur32.dll`, `AcquireCredentialsHandleA`,
`InitializeSecurityContextA`, `FreeCredentialsHandle`, and
`DeleteSecurityContext`; `svn.exe --version --verbose` reported Serf 1.3.10 and
HTTP/HTTPS handling.

The committed gates assert the generated ra_serf graph and the staged
HTTP/HTTPS registration (`scripts/native/SubversionR.Native.psm1:1500-1569,1993-2046`).
They do not assert the four auth schemes, SSPI imports, proxy routes, or any
401/407 interoperability. D1 evidence must close that difference before a
capability statement becomes durable.

### 1.3 Current implicit configuration boundary

The bridge currently calls `svn_config_get_config(&config, NULL, pool)` and
assigns the result to `svn_client_ctx_t.config`
(`native/svn-bridge/src/subversionr_bridge.c:1411-1420`). With a null config
directory, upstream loads the normal per-user and system configuration sources,
including the Windows registry
([`svn_config.h`](https://github.com/apache/subversion/blob/1.14.5/subversion/include/svn_config.h#L239-L256)).
This means the present native path is not isolated from ambient Subversion
configuration. At minimum, `http-auth-types`, proxy host/credentials, client
certificate and trust settings, HTTP timeout/connection settings, `[tunnels]`,
`SVN_SSH`, and cached usernames can alter behavior without being represented in
the TypeScript request contract.

The extension validates its own external-tool settings, but does not serialize
an explicit Subversion config snapshot into native requests
(`packages/vscode-extension/src/security/externalToolConfiguration.ts:49-104`,
`docs/plans/m6-auth-security-trust.md:123-136`). D1 therefore must choose and
test one explicit, trusted configuration owner: either construct the allowed
config snapshot or deliberately provide an empty one and add reviewed fields.
Continuing to discover system/user defaults would violate the fail-fast and
no-silent-fallback invariant, especially for authentication and tunnels.

## 2. Cyrus SASL and direct `svn://`

The Subversion generator arguments include Serf/OpenSSL but no `--with-sasl`
(`scripts/native/build-subversion.ps1:121-131`). The source lock and staged
dependency manifest contain no Cyrus library. Upstream's Windows dependency
generator only defines `SVN_HAVE_SASL` after finding the supplied SASL headers
and import library
([`gen_win_dependencies.py`](https://github.com/apache/subversion/blob/1.14.5/build/generator/gen_win_dependencies.py#L1361-L1417)).

The no-SASL client selects internal auth and supports only:

- tunneled `EXTERNAL` when the server advertises it;
- `ANONYMOUS` when allowed;
- username/password through `CRAM-MD5`;
- otherwise `SVN_ERR_RA_SVN_NO_MECHANISMS`.

See [`ra_svn/client.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_svn/client.c#L61-L65)
and [`internal_auth.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_svn/internal_auth.c#L70-L120).
CRAM-MD5 does not send the clear password, but it does not encrypt later SVN
protocol traffic.

A staged `svn --version` observation omitted the Cyrus availability marker, and
the binary contained the three internal mechanism names. The conclusion is
also derivable from committed generator/dependency inputs; however, a future
package gate should record the generated `SVN_HAVE_SASL` state so build drift
cannot change the result silently.

Enabling SASL requires all of the following as one explicit build variant:

- a newly pinned Cyrus SASL dependency (upstream requires at least 2.0.0),
  Windows headers/import library/runtime, and chosen mechanism plugins;
- source lock, reproducible build, license, SBOM, advisory, artifact-map, and
  package-closure evidence;
- `--with-sasl`, generated graph/macro assertions, and staged runtime checks;
- precise client and source-built svnserve fixtures for each allowed mechanism,
  security layer/QOP, failure class, and credential policy.

Upstream attaches the SASL dependency to both `libsvn_ra_svn` and svnserve
([`build.conf`](https://github.com/apache/subversion/blob/1.14.5/build.conf#L186-L194),
[`build.conf`](https://github.com/apache/subversion/blob/1.14.5/build.conf#L344-L351)).
Adding only a generator flag or accepting arbitrary installed plugins would not
meet the locked-dependency or fail-fast contracts.

## 3. Windows credential providers and cache compatibility

### 3.1 What is present and what is registered

One locally rebuilt `libsvn_subr-1.dll` (SHA-256
`B556061C3524DA1BB555E83AFC653D6906A706FA516C13ABACFCF7B009A7A3FE`)
exported:

- `svn_auth_get_windows_simple_provider`;
- `svn_auth_get_windows_ssl_server_trust_provider`;
- `svn_auth_get_platform_specific_provider`.

Its imports included `CryptProtectData`, `CryptUnprotectData`, and Windows
certificate-chain APIs. `svn.exe --version --verbose` reported Wincrypt as an
available credential cache. These are staged observations, not current product
registration gates.

The simple provider encrypts/decrypts with DPAPI, stores the encoded password,
and records `passtype=wincrypt`
([`win32_crypto.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_subr/win32_crypto.c#L51-L224)).
The Windows SSL provider only clears `UNKNOWNCA` when Windows chain validation
succeeds; it does not erase hostname, expiry, or other certificate failures
([`win32_crypto.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_subr/win32_crypto.c#L373-L505)).

SubversionR's auth baton currently registers exactly simple prompt, username
prompt, and SSL server-trust prompt providers
(`native/svn-bridge/src/subversionr_bridge.c:1340-1393`). It does not register
either Windows provider. The daemon also forces `may_save = 0` for credential
and certificate responses
(`crates/subversionr-daemon/src/native.rs:3252-3256,3479-3483`). Thus the
product neither reads Wincrypt passwords through a platform simple provider nor
writes standard auth-cache entries today.

### 3.2 Disposable Wincrypt readback fixture

R2 ran a disposable localhost fixture using the locked source-built tools and
removed the repository, config directory, probe source, and binaries afterward.
No real `%APPDATA%` or user credentials were read.

The inspected locked stage reported
`libsvn_subr-1.dll` SHA-256
`B556061C3524DA1BB555E83AFC653D6906A706FA516C13ABACFCF7B009A7A3FE`.
The disposable svnserve used fixed configured realm
`SubversionR Wincrypt Fixture`; its exact auth realm was
`<svn://127.0.0.1:4167> SubversionR Wincrypt Fixture`. All paths below were
temporary directories under the ignored research cache, and `<fixture-secret>`
was never printed or retained in the report.

Procedure:

1. Create a temporary repository and source-built svnserve with anonymous access
   disabled, a fixed test realm, and one fixture-only username/secret.
2. Run source-built `svn info` with an explicit temporary `--config-dir` and
   `config:auth:password-stores=windows-cryptoapi`, plus explicit auth-cache
   storage options.
3. Inspect the single `auth/svn.simple` entry without printing its encrypted
   password.
4. Compile a temporary C probe against the staged headers/import libraries. The
   probe registers **only**
   `svn_auth_get_platform_specific_provider(..., "windows", "simple")`, sets
   `SVN_AUTH_PARAM_CONFIG_DIR` and the default username, then calls
   `svn_auth_first_credentials` for the exact realm.
5. Compare username and decrypted fixture secret in probe memory, then repeat
   `svn info` with no explicit password as a full-chain smoke.

The complete provider-only probe source was:

```c
#include <stdio.h>
#include <string.h>

#include <apr_general.h>
#include <apr_pools.h>
#include <apr_tables.h>
#include <svn_auth.h>
#include <svn_error.h>

static int report_error(svn_error_t *error)
{
  svn_handle_error2(error, stderr, FALSE, "wincrypt_probe: ");
  svn_error_clear(error);
  return 1;
}

int main(int argc, char **argv)
{
  apr_pool_t *pool;
  apr_array_header_t *providers;
  svn_auth_provider_object_t *provider = NULL;
  svn_auth_baton_t *auth_baton;
  svn_auth_iterstate_t *state = NULL;
  svn_auth_cred_simple_t *credentials = NULL;
  svn_error_t *error;
  int matched;

  if (argc != 5)
    {
      fputs("usage: wincrypt_probe CONFIG_DIR REALM USER EXPECTED_SECRET\n",
            stderr);
      return 2;
    }
  if (apr_initialize() != APR_SUCCESS)
    return 3;
  if (apr_pool_create(&pool, NULL) != APR_SUCCESS)
    {
      apr_terminate();
      return 4;
    }

  error = svn_auth_get_platform_specific_provider(
      &provider, "windows", "simple", pool);
  if (error != NULL)
    {
      report_error(error);
      apr_pool_destroy(pool);
      apr_terminate();
      return 1;
    }
  providers = apr_array_make(
      pool, 1, sizeof(svn_auth_provider_object_t *));
  APR_ARRAY_PUSH(providers, svn_auth_provider_object_t *) = provider;
  svn_auth_open(&auth_baton, providers, pool);
  svn_auth_set_parameter(
      auth_baton, SVN_AUTH_PARAM_CONFIG_DIR, argv[1]);
  svn_auth_set_parameter(
      auth_baton, SVN_AUTH_PARAM_DEFAULT_USERNAME, argv[3]);

  error = svn_auth_first_credentials(
      (void **)&credentials, &state, SVN_AUTH_CRED_SIMPLE,
      argv[2], auth_baton, pool);
  if (error != NULL)
    {
      report_error(error);
      apr_pool_destroy(pool);
      apr_terminate();
      return 1;
    }
  matched = credentials != NULL
            && credentials->username != NULL
            && credentials->password != NULL
            && strcmp(credentials->username, argv[3]) == 0
            && strcmp(credentials->password, argv[4]) == 0;
  puts(matched
       ? "provider_probe=matched username+secret"
       : "provider_probe=no match");

  apr_pool_destroy(pool);
  apr_terminate();
  return matched ? 0 : 5;
}
```

The following is valid PowerShell when run from an MSVC x64 developer shell.
It assumes the source above is saved as `$temp\wincrypt_probe.c`; the fixture
secret is supplied through a transient environment variable and is not printed:

```powershell
$stage = '<locked-stage>'
$temp = '<disposable-fixture-directory>'
$config = Join-Path $temp 'config'
$url = 'svn://127.0.0.1:4167/repository'
$realm = '<svn://127.0.0.1:4167> SubversionR Wincrypt Fixture'
$env:SUBVERSIONR_FIXTURE_SECRET = '<fixture-secret>'

$writeArgs = @(
  'info', $url,
  '--username', 'fixture-user',
  '--password', $env:SUBVERSIONR_FIXTURE_SECRET,
  '--non-interactive',
  '--config-dir', $config,
  '--config-option', 'config:auth:password-stores=windows-cryptoapi',
  '--config-option', 'config:auth:store-passwords=yes',
  '--config-option', 'config:auth:store-auth-creds=yes'
)
& (Join-Path $stage 'bin\svn.exe') @writeArgs
if ($LASTEXITCODE -ne 0) { throw 'credential-write fixture failed' }

$clArgs = @(
  '/nologo', '/W4',
  "/I$stage\include",
  "/I$stage\include\subversion-1",
  (Join-Path $temp 'wincrypt_probe.c'),
  "/Fe:$temp\wincrypt_probe.exe",
  '/link',
  "/LIBPATH:$stage\lib",
  'libsvn_subr-1.lib',
  'libapr-1.lib'
)
& cl.exe @clArgs
if ($LASTEXITCODE -ne 0) { throw 'probe compilation failed' }

$env:PATH = "$(Join-Path $stage 'bin');$env:PATH"
$probeArgs = @(
  $config, $realm, 'fixture-user', $env:SUBVERSIONR_FIXTURE_SECRET
)
& (Join-Path $temp 'wincrypt_probe.exe') @probeArgs
if ($LASTEXITCODE -ne 0) { throw 'provider-only readback failed' }

$readArgs = @(
  'info', $url,
  '--username', 'fixture-user',
  '--non-interactive',
  '--config-dir', $config,
  '--config-option', 'config:auth:password-stores=windows-cryptoapi'
)
& (Join-Path $stage 'bin\svn.exe') @readArgs
if ($LASTEXITCODE -ne 0) { throw 'cache-only CLI readback failed' }
Remove-Item Env:SUBVERSIONR_FIXTURE_SECRET
```

Sanitized observed output:

```text
wincrypt provider read matching fixture credential
wincrypt_fixture=passed
cache_entry=a68840c5bb2f85473e228b63ee08ff0e
realm=<svn://127.0.0.1:4167> SubversionR Wincrypt Fixture
plaintext_secret_present=false
provider_probe=matched username+secret
cache_only_cli_read=passed
```

Observed results:

- exactly one `svn.simple` entry was written;
- its filename was the lowercase MD5 of the exact `svn:realmstring`;
- the entry carried the exact realm, fixture username, and `passtype=wincrypt`;
- the plaintext fixture secret did not occur in the cache file;
- the platform-provider-only probe returned the matching username and secret;
- the cache-only CLI request authenticated successfully.

The file layout and realm validation match upstream
[`config_auth.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_subr/config_auth.c#L38-L109).
This proves same-user, same-machine read compatibility with a source-built CLI
entry. It does not choose product persistence, migration, precedence, or trust
policy, and it does not prove cross-user/machine portability (DPAPI is expected
not to provide that).

### 3.3 D1 policy boundary

The Windows providers can technically share an auth baton with prompt providers,
but provider array order controls lookup and save order
([`libsvn_subr/auth.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_subr/auth.c#L43-L86)).
D1 must select one observable mode rather than append an implicit chain. Candidate
policy choices to evaluate are:

- broker-only (the current explicit product path);
- explicit Wincrypt-cache read before the broker, with a visible credential
  source and exact retry/invalidation rules;
- explicit Windows root-store validation before the certificate broker, limited
  to the precise failure bits that provider can clear;
- a separately reviewed standard-cache write mode with an identified persistence
  owner. The current `may_save = 0` makes this unavailable.

These are alternatives for D1, not simultaneous fallback paths. A cache miss,
rejected credential, changed realm, or unsupported platform must produce the
chosen mode's defined next state or fail explicitly.

## 4. Custom RA tunnel callback contract

### 4.1 Public callback surface

`svn_ra_callbacks2_t` provides:

- `check_tunnel_func`: report whether the application wants a named tunnel;
- `open_tunnel_func`: return request/response `svn_stream_t` objects plus an
  optional close callback/context;
- `tunnel_baton`: application state supplied to the callbacks.

See [`svn_ra.h`](https://github.com/apache/subversion/blob/1.14.5/subversion/include/svn_ra.h#L274-L329)
and [`svn_ra.h`](https://github.com/apache/subversion/blob/1.14.5/subversion/include/svn_ra.h#L599-L623).

The 1.14.5 implementation adds critical lifetime detail:

- if custom open returns an error, libsvn has not yet registered cleanup; the
  opener must release every process/pipe/handle it created;
- after success, the connection pool owns the returned streams and registers
  tunnel cleanup (`libsvn_ra_svn/client.c:635-688`);
- cleanup invokes the void close callback first, then closes request and
  response streams; stream-close errors are cleared
  (`libsvn_ra_svn/client.c:580-605`);
- close cannot propagate process-exit, stderr, stream-close, or cleanup failure
  back through the RA call.

The streams can therefore wrap daemon-created process pipes. The callback API
does not itself supply asynchronous I/O, a deadline, a Windows process tree, or
safe diagnostics.

### 4.2 No-fallback selection rule

`ra_svn` uses the application opener when it is present and accepted. If both
callbacks exist and `check_tunnel_func` returns false, it deliberately selects
the default `[tunnels]` / environment path
([`libsvn_ra_svn/client.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_svn/client.c#L842-L890)).

SubversionR must not use that behavior as compatibility fallback. If D1 chooses
daemon-owned tunnels, the safe shape is one custom `open_tunnel_func` for every
allowed name, without a declining check callback; the opener validates the
selected explicit provider and returns `SVN_ERR_RA_CANNOT_CREATE_TUNNEL` for an
unsupported or unconfigured name. A test must poison the default `[tunnels]`
and `SVN_SSH` routes and prove they are never executed.

### 4.3 Windows implementation feasibility

The current bridge already uses the Win32 API and can add system calls without
a third-party library (`native/svn-bridge/src/subversionr_bridge.c:7-10`,
`native/svn-bridge/CMakeLists.txt:1-30`). A prototype should falsify this single
candidate design:

1. Create the exact configured executable/argv with `CreateProcessW`, never a
   shell string.
2. Use `STARTUPINFOEX` and `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` so only the
   intended stdin/stdout/stderr child handles are inherited.
3. Start suspended with `CREATE_NO_WINDOW | CREATE_SUSPENDED |
   CREATE_UNICODE_ENVIRONMENT`.
4. Assign the process to a per-tunnel Job using
   `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` before resume; assignment failure aborts
   the open and cleans every handle.
5. Back request/response streams with overlapped named-pipe I/O that waits on
   I/O completion plus cancel/deadline events. Anonymous `CreatePipe` handles
   are synchronous and cannot provide this hard boundary.
6. Drain stderr concurrently into a bounded redacted buffer. Never merge it
   into the SVN protocol stdout stream.
7. Make close idempotent: close stdin for a normal EOF, wait a bounded grace
   period, then close the Job on cancellation, deadline, or daemon shutdown.

Relevant Windows contracts:
[CreatePipe](https://learn.microsoft.com/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-createpipe),
[redirected child I/O](https://learn.microsoft.com/en-us/windows/win32/procthread/creating-a-child-process-with-redirected-input-and-output),
[process creation flags](https://learn.microsoft.com/en-us/windows/win32/procthread/process-creation-flags),
[Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects),
and [overlapped pipe I/O](https://learn.microsoft.com/en-us/windows/win32/ipc/synchronous-and-overlapped-input-and-output).

The Job controls the local tunnel process tree only. It cannot directly kill a
remote sshd/svnserve child; normal stdin EOF and a server-side residue check are
both required before a forced local close can be considered correct.

A further lifetime risk needs a prototype: the bridge owns a long-lived
`svn_client_ctx_t` / result pool and temporarily installs stack-backed operation
batons (`native/svn-bridge/src/subversionr_bridge.c:48-83,1396-1448,3605-3627`).
If an RA stream or cleanup outlives the call, it must not retain those batons.
An operation-owned scratch/session pool destroyed before restoring context
pointers is the candidate boundary, with durable results copied elsewhere.

## 5. Default `svn+ssh` baseline

The default `ra_svn` tunnel path:

1. resolves `[tunnels] <name>`; for SSH it also honors `$SVN_SSH` and otherwise
   uses `ssh -q --`;
2. tokenizes the command to argv and appends host plus `svnserve -t`;
3. starts it with APR `apr_proc_create`;
4. connects child stdin/stdout to blocking pipes while stderr is inherited;
5. registers `APR_KILL_NEVER` cleanup on Windows.

See [`libsvn_ra_svn/client.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_svn/client.c#L375-L453)
and [`libsvn_ra_svn/client.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_svn/client.c#L485-L561).
APR's Win32 process implementation and kill policy are in
[`proc.c`](https://github.com/apache/apr/blob/1.7.6/threadproc/win32/proc.c#L77-L124),
[`proc.c`](https://github.com/apache/apr/blob/1.7.6/threadproc/win32/proc.c#L780-L878),
and [`apr_thread_proc.h`](https://github.com/apache/apr/blob/1.7.6/include/apr_thread_proc.h#L80-L90).

`ra_svn` checks cancellation before entering a stream read/write, but the
blocking operation itself has no common deadline
([`marshal.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_svn/marshal.c#L79-L85),
[`marshal.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_svn/marshal.c#L493-L510),
[`streams.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_svn/streams.c#L67-L95)).
Pool cleanup neither kills nor waits for a still-running Windows tunnel. This
baseline lacks bounded stderr, prompt ownership, process-tree termination, and
a hard operation deadline; it cannot be retained behind a silent escape hatch.

## 6. FBL-06 timeboxed root-cause inspection

The public claim matrix records an installed merge-preview repro whose visible
text was `No SVN repository is open.`
(`docs/release/public-claim-matrix.md`, Merge, merge preview, and mergeinfo).

The preview command calls `selectOpenSessionForRepository` before its first
wizard input
(`packages/vscode-extension/src/repository/repositoryCommandController.ts:1105-1175,3725-3747`).
When no repository id is supplied, that method delegates to
`selectOpenSession`; both preview-relevant routes read `listOpenSessions()` and
emit the warning when the list is empty
(`repositoryCommandController.ts:3675-3684,3725-3747`). The literal is not a
repository-wide unique emission point: other repository-controller helpers and
the Tortoise controller also use it (`repositoryCommandController.ts:3703,3829,3862,3905`,
`tortoiseCommandController.ts:108`). Therefore the text alone cannot identify
the exact method or command invocation.

By contrast, a missing daemon-side repository map produces
`REPOSITORY_NOT_OPEN` (`crates/subversionr-daemon/src/state.rs:1214-1232`) and
passes through the generic operation-failure UI
(`repositoryCommandController.ts:4367-4395,4480-4553`). It cannot emit that
exact selector warning after the wizard.

For the current preview invocation, the supported immediate conclusion is:

- the extension-local session list was empty at the preview selector, before the
  preview wizard began.

The evidence does not identify why. A failed/incomplete open can leave the list
empty because `RepositorySessionService` publishes a session only after backend
open, watcher, status, projection, and initial snapshot setup all succeed
(`packages/vscode-extension/src/repository/repositorySessionService.ts:116-281`).
But no current evidence ties one of those stages to the historical repro. A
daemon restart during a wizard is also not the observed warning route.

The recorded “completed the wizard, then warning” chronology may describe a
different command invocation, a different build, or an attribution error. R2
found no obvious merge target-resolution defect. Further attribution requires
the original installed VSIX/commit, SubversionR log, renderer recording, and
exact command sequence; absent those, FBL-06 remains a truthful deferred repro,
not a diagnosed bug.

Targeted verification:

```text
pnpm --filter ./packages/vscode-extension exec vitest run \
  tests/repositoryCommandController.test.ts --reporter=dot
```

passed 418 tests. Existing tests cover successful preview flow but not the
recorded FBL chronology.

## 7. D1 decisions and falsifiable follow-ups

R2 establishes capability facts, not final policy. D1 must decide:

1. exact HTTP auth allowlist per operation/interaction mode, including whether
   daemon-token SSPI is ever permitted and how proxy identity differs;
2. broker-only versus explicit Wincrypt/root-store provider modes, provider
   order, invalidation, observability, and one persistence owner;
3. whether SASL is deliberately unsupported or introduced as a separately
   locked dependency/build/evidence variant;
4. whether all `svn+ssh` traffic is daemon-owned; if so, a custom opener must
   fail unsupported names and prove the default route is unreachable;
5. operation pool/baton lifetime, overlapped stream cancellation, deadline,
   stderr, Job cleanup, and server-side residue contracts.

Minimum falsifiable checks before implementation claims:

- committed PE/generated-config gates for SSPI, Wincrypt exports, RA schemes,
  and SASL presence/absence;
- server/proxy Basic, Digest, Negotiate, and NTLM challenges with exact selected
  identity route and no hidden scheme change;
- the disposable platform-provider-only Wincrypt readback fixture in CI if D1
  selects cache interoperability;
- a poisoned default config/tunnel sentinel proving explicit config ownership;
- custom opener failures before and after cleanup registration;
- cancellation/deadline during tunnel connect, mid-read, mid-write, stderr
  backpressure, and daemon shutdown;
- repeated tunnel cleanup with no local or server-side process residue;
- operation-pool instrumentation proving no stream/close callback retains a
  stack-backed baton.

The public transport/auth claim matrix remains unchanged until the selected
policy and packaged real-server gates pass.

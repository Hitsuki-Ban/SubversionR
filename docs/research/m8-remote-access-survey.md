# M8 remote-access and libsvn RA survey

Status: R1 research input for M8 D1. This document changes no product code,
capability, release gate, or public claim.

Baseline: SubversionR `0.2.5` at `6cc691152650d0e05f4f00c282d9e44d2a639380`,
Apache Subversion 1.14.5, and Serf 1.3.10 on the locked Windows `win32-x64`
native build.

## Scope and method

This survey separates three kinds of evidence:

- **tree fact**: behavior visible in the current SubversionR source, tests, build,
  or release documentation;
- **upstream contract**: behavior documented or implemented by the exact
  Subversion/Serf versions that SubversionR builds;
- **design inference**: a constraint or candidate for D1 that still requires a
  falsifiable test before it can become a product contract.

The current public support boundary remains the local file-backed Windows path.
The authenticated localhost `svn://` and HTTPS DAV paths remain fixture-only;
arbitrary remote servers and `svn+ssh` remain deferred
([`docs/release/public-claim-matrix.md`, Repository Transports](../release/public-claim-matrix.md#repository-transports)).

### Issue #114 acceptance mapping

| Requested research item | Report coverage |
| --- | --- |
| RA inventory, locked build, common session/auth/cancel/timeout contract | Sections 1 and 2 |
| HTTP/S auth, proxy, client certificates, redirects, authz, connections, Windows behavior, and current DAV evidence | Section 3 |
| Direct `svn://` internal/SASL auth, realm/cache, fixtures, and arbitrary-server gaps | Section 4 |
| `svn+ssh` tunnel execution, Windows clients/agents, lifecycle, diagnostics, and Workspace Trust | Section 5 |
| Operation-by-transport fixture and gap map | Section 6 |
| Real-server evidence options, trade-offs, and recommendation | Section 8 |
| Ranked unknowns with falsifiable D1 checks | Section 9 |

The unified-envelope material in Section 7 is deliberately bounded input to D1,
not an extra R1 implementation or a final protocol design.

## Executive findings

1. The locked runtime exercises the standard `ra_local`, `ra_svn`, and
   `ra_serf` transport families through local-file, source-built svnserve, and
   HTTPS DAV fixtures. The generated build explicitly enables Serf and OpenSSL,
   and the staged `svn.exe --version` gate independently proves `ra_serf`
   handles `http` and `https` (`scripts/native/build-subversion.ps1:121-172`,
   `scripts/native/SubversionR.Native.psm1:1500-1569,1993-2046`). The committed
   registration gate does not yet assert `ra_local` or `ra_svn` by name.
2. The bridge does not expose or pool `svn_ra_session_t`. It owns one long-lived
   `svn_client_ctx_t`; individual `svn_client_*` operations let libsvn select
   and own the physical RA session. A unified SubversionR abstraction therefore
   should describe an operation's remote policy and lifetime, not promise a
   reusable cross-operation connection.
3. The current auth baton registers simple username/password, username, and TLS
   server-trust providers only. Proxy credentials, TLS client certificates,
   SSPI identity, Cyrus SASL, and SSH prompts have different ownership and are
   not covered by that broker.
4. Cancellation is cooperative. Serf has its own HTTP inactivity timeout, while
   direct `ra_svn` can block in socket I/O and the default Windows SSH tunnel is
   deliberately not killed during APR cleanup. There is no existing
   cross-transport operation deadline.
5. `subversionr.svn.configDirectory` and `subversionr.svn.tunnelCommand` are
   trust-restricted future settings, but are not passed to libsvn. The bridge
   nevertheless calls `svn_config_get_config(..., NULL, ...)` today and gives
   the resulting default user config to `svn_client_ctx_t`; proxy/auth-type and
   tunnel policy from that config is therefore current runtime input outside
   the extension setting boundary. D1 must close this exposure and replace it
   with an explicit trusted config contract, not add another implicit route.

## 1. RA inventory and session model

### 1.1 Module inventory

The Subversion 1.14.5 RA loader maps schemes as follows
([`ra_loader.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra/ra_loader.c#L62-L103)):

| Module | Schemes | Upstream role | Locked-build evidence |
| --- | --- | --- | --- |
| `ra_local` | `file` | Opens repository and filesystem objects in-process; authorization is primarily OS filesystem access. | Broad native/installed local-file operations prove the module is usable in the locked runtime. The committed registration gate does not independently assert it by name. |
| `ra_serf` | `http`, `https` | WebDAV/DeltaV over Serf, including HTTP auth, proxy, TLS, redirects, and multiple HTTP connections. | Explicit `--with-serf`/`--with-openssl`; generated project graph, link inputs, runtime registration, and HTTP/HTTPS schemes are hard-gated. |
| `ra_svn` | `svn`, `svn+<tunnel>` | Stateful svn protocol stream, directly over TCP or over an application/default tunnel process. | Authenticated source-built `svnserve` fixtures prove direct `svn://` use in the locked runtime. The committed registration gate does not independently assert it by name; `svn+ssh` has no product fixture. |

The bridge links the unified `libsvn_ra-1` import library rather than choosing a
module itself (`native/svn-bridge/CMakeLists.txt:8-30`). Serf is a build input
linked into the staged native graph; OpenSSL runtime DLLs are packaged, but an
HTTP server is only a test fixture
(`docs/release/native-artifact-map.win32-x64.json:12-69`). The packaged extension
does not ship the source-built SVN command-line tools
(`scripts/release/stage-vscode-package-layout.ps1:218-224,265-343`). Production
therefore remains libsvn-backed and does not gain an `svn.exe` fallback.

### 1.2 What all RA modules expose

`svn_ra_callbacks2_t` supplies a common auth baton, progress notification,
cancellation, client string, working-copy callbacks, and optional tunnel
callbacks
([`svn_ra.h`](https://github.com/apache/subversion/blob/1.14.5/subversion/include/svn_ra.h#L533-L624)).
The RA vtable offers repository revision, properties, file/directory access,
update reporters, commit editors, history, locks, and related operations. These
are common entry points, not a promise of identical auth, timeout, concurrency,
or failure behavior.

`svn_ra_open5` creates a pool-lifetime opaque `svn_ra_session_t` with one session
URL; `reparent` remains within the same repository root
([Subversion 1.14 API](https://subversion.apache.org/docs/api/1.14/svn__ra_8h.html)).
The public API does not promise concurrent calls on one session. Capability
support must be queried or exercised, not inferred from the scheme alone.

### 1.3 Current SubversionR lifetime

The C runtime loads the default config with `svn_config_get_config(&config,
NULL, pool)`, creates one `svn_client_ctx_t`, and keeps it for the daemon runtime
(`native/svn-bridge/src/subversionr_bridge.c:1396-1438`). Each operation
temporarily installs auth/cancel/notify batons. The Rust `RepositorySession` is
working-copy state and cache metadata, not an RA connection
(`crates/subversionr-daemon/src/state.rs:37-54`). Stdio dispatch serializes
bridge execution today.

Consequently, D1 may rely on libsvn selecting the correct RA module behind the
`svn_client_*` API. It may not rely on one authentication, one socket, or one
physical session being reused across operations. If future concurrency is
introduced, independent operation contexts/sessions are the safe starting
hypothesis until a dedicated test disproves it.

### 1.4 `ra_local` cancellation and blocking boundary

`ra_local` executes repository and filesystem calls in-process. It wires the
common cancellation callback into update editors, history/log delivery, stream
copy, and directory-list loops
([`ra_local/ra_plugin.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_local/ra_plugin.c#L329-L349),
[`ra_local/ra_plugin.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_local/ra_plugin.c#L1095-L1113),
[`ra_local/ra_plugin.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_local/ra_plugin.c#L1300-L1318),
[`ra_local/ra_plugin.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_local/ra_plugin.c#L1850-L1868)).
The classic commit-editor entry does not independently install the session
cancel callback; the Ev2 entry instead receives an explicit cancel function and
passes it to the repository editor
([`ra_local/ra_plugin.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_local/ra_plugin.c#L864-L911),
[`ra_local/ra_plugin.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_local/ra_plugin.c#L1764-L1818)).
Those checks are cooperative boundaries, not a hard interrupt around every
repository call. `ra_local` has no network timeout; a slow filesystem, repository
lock, antivirus filter, or blocked OS I/O can delay the next cancellation check.
The unified deadline policy therefore still needs a bounded operation boundary
for local access, while avoiding invented network/auth settings for `file://`.

## 2. Common callbacks, current broker, and lifetime gaps

The bridge's auth baton contains exactly three prompt providers:

- simple username/password;
- username;
- TLS server-certificate trust.

See `native/svn-bridge/src/subversionr_bridge.c:1359-1393`. Rust routes those
prompts through the daemon with a fixed 120-second **prompt response** timeout
and disables libsvn credential-store persistence
(`crates/subversionr-daemon/src/native.rs:53,3078-3500`). This is not a network
or operation timeout. The protocol has generic credential and certificate
envelopes (`crates/subversionr-protocol/src/lib.rs:530-620`), but those envelopes
do not prove proxy, client-certificate, SSPI, SASL, or SSH support.

Cancellation flows from `$/cancelRequest` through the daemon to the bridge
(`crates/subversionr-daemon/src/stdio.rs:77-180`,
`crates/subversionr-daemon/src/native.rs:3118-3147`,
`native/svn-bridge/src/subversionr_bridge.c:1697-1756`). It is available for
checkout, remote status, update, commit, lock/unlock, and property mutation.
Repository open, content, history, blame, and property listing do not currently
carry the same per-operation cancellation parameter
(`crates/subversionr-daemon/src/bridge.rs:395-496`).

The stable operation failure taxonomy currently has five causes: out-of-date,
conflict-present, authentication-failed, not-working-copy, and unknown-native
(`crates/subversionr-protocol/src/lib.rs:497-503`). It intentionally does not yet
distinguish DNS, connection refusal, timeout, TLS, proxy, tunnel, host-key, or
path-authorization failures.

## 3. HTTP and HTTPS through `ra_serf`

### 3.1 Authentication and Windows identity

Subversion 1.14.5 accepts `Basic`, `Digest`, `NTLM`, and `Negotiate` in the
`http-auth-types` runtime configuration; absent that setting it enables all Serf
auth types
([`ra_serf/serf.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_serf/serf.c#L98-L148)).
Serf 1.3.10 prioritizes Negotiate, NTLM, Digest, then Basic where compiled
([`auth.c`](https://github.com/apache/serf/blob/1.3.10/auth/auth.c#L42-L92)).

The locked Windows Serf build enables SSPI. Negotiate/NTLM acquire the current
process's Windows credentials, not the simple username/password broker
([`auth_spnego_sspi.c`](https://github.com/apache/serf/blob/1.3.10/auth/auth_spnego_sspi.c#L124-L151)).
Thus source availability is not product proof for VisualSVN Integrated Windows
Authentication, which may use Kerberos or NTLM
([VisualSVN Windows Authentication](https://www.visualsvn.com/server/features/windows-auth/)).
Because the bridge currently loads default user config and absent
`http-auth-types` enables all compiled Serf methods, SSPI negotiation with the
daemon's Windows identity is reachable today without broker involvement. This
is an unclaimed current exposure, not a future capability. D1 must make
daemon-process identity use explicit and separately test it; it must not
silently retain or introduce a broker-to-SSPI switch.

### 3.2 Proxy and runtime configuration

`ra_serf` reads proxy host, port, username/password, exceptions, HTTP timeout,
CA files, and connection limits from Subversion's `servers` configuration
([`ra_serf/serf.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_serf/serf.c#L149-L443),
[runtime configuration reference](https://svnbook.red-bean.com/en/1.8/svn.advanced.confarea.html)).
Proxy credentials are read from config and supplied directly to Serf; they do
not pass through the current simple credential prompt
([`ra_serf/util.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_serf/util.c#L1183-L1254)).
The locked source does not justify a claim that Windows System Proxy, PAC,
environment variables, or Credential Manager are inherited.

This conflicts with the current product boundary in an important way. The
extension validates the future `svn.configDirectory` setting and its Workspace
Trust provenance (`packages/vscode-extension/src/security/externalToolConfiguration.ts:3-104`),
but the native runtime is not passed that value. M6 explicitly records that no
SVN config/tunnel setting is passed to libsvn
(`docs/plans/m6-auth-security-trust.md:123-136`). D1 must choose and test an
explicit trusted config snapshot and stop the current implicit default
discovery. Installed VSIX fixtures isolate `APPDATA`
(`scripts/release/test-vscode-installed-core-workflow.ps1:700-730` and
`scripts/release/test-vscode-installed-source-control-surface.ps1:985-1015`),
but the in-process native bridge tests pass isolated `--config-dir` values only
to their CLI setup/oracle commands and do not isolate the bridge runtime's
default APPDATA config (`crates/subversionr-daemon/tests/native_bridge.rs:1084-1107,5661-5674`).
That is a fixture-determinism gap as well as a product policy gap.

### 3.3 TLS and client certificates

The upstream module can use CA files, the server-trust credential kind, and the
`SVN_AUTH_CRED_SSL_CLIENT_CERT` / `SVN_AUTH_CRED_SSL_CLIENT_CERT_PW` kinds
([`svn_auth.h`](https://github.com/apache/subversion/blob/1.14.5/subversion/include/svn_auth.h#L227-L340),
[`ra_serf/util.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_serf/util.c#L689-L770)).
Serf 1.3.10 treats the client identity as PKCS#12. The current bridge registers
neither client-certificate provider, so the existing server-certificate trust
broker is not mTLS evidence.

The existing HTTPS fixture proves certificate rejection routing and a
self-signed trust-once path for HEAD content and update
(`crates/subversionr-daemon/tests/native_bridge.rs:1822-1883,1968-2105`). It does
not prove normal HTTP, public CA chains, hostname/SAN variants, proxy CONNECT,
client certificates, IWA, or arbitrary Apache/VisualSVN configurations.

### 3.4 Redirects, authz, and connections

The initial OPTIONS exchange treats a usable 301 as a corrected URL; other 3xx
responses become session-URL mismatch rather than a universal transparent
redirect
([`ra_serf/options.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_serf/options.c#L544-L605)).
D1 must decide scheme/authority changes, credential forwarding, loop limits,
and root/UUID validation explicitly.

Path authz is server-side and can filter descendants differently across list,
checkout/update, history, content, commit, and lock operations
([Subversion path-based authorization](https://svnbook.red-bean.com/en/1.8/svn.serverconfig.pathbasedauthz.html)).
An absent child is therefore not automatically a node-not-found result.

One `ra_serf` session owns a Serf context and may use multiple persistent HTTP
connections. Subversion defaults to four and clamps the configured value to 2-8
([`svn_config.h`](https://github.com/apache/subversion/blob/1.14.5/subversion/include/svn_config.h#L78-L112),
[`ra_serf/serf.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_serf/serf.c#L149-L443)). Authentication and server/proxy
behavior can reduce practical request concurrency. The locked Serf 1.3.10 build
does not enter Subversion's newer Serf HTTP/2 branch, so this survey assumes
HTTP/1.1 only. Keep-alive or request concurrency must not be represented as a
single reusable SubversionR connection guarantee.

At the Serf 1.3.10 layer, the per-connection outstanding-request limit defaults
to zero, meaning unlimited; more than one request may therefore be sent before
earlier responses complete, which is HTTP/1.1 pipelining rather than merely a
queue behind one response
([`serf.h`](https://github.com/apache/serf/blob/1.3.10/serf.h#L499-L508),
[`outgoing.c`](https://github.com/apache/serf/blob/1.3.10/outgoing.c#L743-L757)).
This is allowed behavior, not a delivery guarantee. CONNECT setup forces one
outstanding request, SPNEGO/NTLM stateful or stateless authentication temporarily
sets the limit to one, and a closed connection requeues eligible outstanding
requests
([`auth_spnego.c`](https://github.com/apache/serf/blob/1.3.10/auth/auth_spnego.c#L294-L317),
[`auth_spnego.c`](https://github.com/apache/serf/blob/1.3.10/auth/auth_spnego.c#L400-L416),
[`outgoing.c`](https://github.com/apache/serf/blob/1.3.10/outgoing.c#L565-L585)).
Consequently an update can have outstanding work distributed across connections,
while auth, proxy handshake, HTTP/1.0/non-keepalive peers, or connection closure
can serialize or replay it. D1 cannot assume a fixed pipeline depth or that one
request maps to one connection.

Serf checks cancellation in its event loop and applies `http-timeout`, whose
Subversion default is 600 seconds and whose activity resets the inactivity
timer
([`ra_serf/util.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_serf/util.c#L910-L946)).
This timeout is specific to HTTP; it is not a cross-transport deadline.

## 4. Direct `svn://` through `ra_svn`

### 4.1 Authentication mechanisms

The current generator arguments include Serf/OpenSSL but no `--with-sasl`
(`scripts/native/build-subversion.ps1:121-131`), and the staged dependency map
contains no Cyrus SASL runtime. The current build must therefore be treated as
the non-Cyrus branch unless a future generated-config gate proves otherwise.

That branch tries tunneled `EXTERNAL`, then `ANONYMOUS`, then `CRAM-MD5`, and
fails if the server offers no usable mechanism
([`internal_auth.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_svn/internal_auth.c#L71-L120)).
CRAM-MD5 avoids sending the clear password but does not encrypt later SVN
traffic. A Cyrus-enabled build can negotiate additional server/plugin-dependent
mechanisms, but no fixed set is guaranteed
([`cyrus_auth.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_svn/cyrus_auth.c#L836-L966)).
SubversionR must report SASL as unavailable for this build, not fall back to an
unadvertised mechanism.

### 4.2 Realm, cache, and current evidence

`ra_svn` obtains the realm from the server and combines it with the endpoint for
the auth baton/cache key. The current bridge sets `may_save = false`, so the
standard disk cache is not product persistence; successful fixture prompts are
served by the SubversionR broker. SSH identity, by contrast, belongs to the SSH
client and is not a Subversion password credential.

The source-built authenticated localhost `svnserve` tests prove checkout,
update, on-demand remote status, HEAD content, log, blame, commit, and
lock/unlock through the broker
(`crates/subversionr-daemon/tests/native_bridge.rs:339-392,1121-1684,2636-2725`).
They use the internal password database and do not prove arbitrary realms,
Cyrus mechanisms, encryption/QOP, IPv6, proxies, WAN failures, or other
svnserve versions/configurations.

### 4.3 Cancellation and timeout

Direct `ra_svn` checks cancellation before a blocking read/write but uses an
unbounded socket timeout when no blockage handler is installed
([`marshal.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_svn/marshal.c#L79-L85),
[`marshal.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_svn/marshal.c#L493-L510)).
TCP keepalive is not an operation deadline. A stalled connect or mid-stream read
can therefore fail to observe cancellation promptly. D1 needs a bounded hard
termination design; a cancel flag alone cannot supply it.

## 5. `svn+ssh` tunnel behavior and Windows constraints

`svn+<name>://` still selects `ra_svn`. The default loader reads `[tunnels]
<name>` or, for SSH, `$SVN_SSH` and otherwise `ssh -q --`; it tokenizes the
command to argv, appends the host plus `svnserve -t`, starts the executable
directly with APR, and pipes stdin/stdout
([`ra_svn/client.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_svn/client.c#L375-L453),
[`ra_svn/client.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_svn/client.c#L485-L561)).
There is no shell expansion in that upstream path, but trusted tunnel config can
still select an arbitrary executable. Stderr is not structured into the
SubversionR error channel, and the default `-q` suppresses useful SSH details.

On Windows, upstream registers tunnel cleanup as `APR_KILL_NEVER`. Its comment
explains that forcibly terminating the local client can leave remote sshd and
svnserve processes behind. Therefore pool destruction or cooperative libsvn
cancellation does not prove local or remote tunnel cleanup.

Windows OpenSSH Client may be an optional capability rather than installed, and
`ssh-agent` is disabled by default
([Microsoft OpenSSH installation](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse),
[Microsoft key management](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement)).
Host-key, password, and key-passphrase prompts belong to the SSH process and
cannot be routed through the current libsvn simple-credential callback. OpenSSH
and Plink/Pageant also have different executable, argument, profile, agent, and
non-interactive contracts; they must be explicit providers, not interchangeable
fallbacks.

The RA callback API offers `check_tunnel_func`, `open_tunnel_func`, and a close
callback. D1 should evaluate using them to let the daemon own exact executable
and argv, bounded stderr, process handles/Windows Job Object, cancellation, and
close semantics. The current trust-restricted `svn.tunnelCommand` is only a
future string setting (`packages/vscode-extension/src/security/externalToolConfiguration.ts:55-104`);
it is not an implemented capability and need not dictate D1's final structured
configuration. Missing or unsafe tunnel configuration must fail fast, with no
default libsvn tunnel execution.

## 6. Current operation-by-transport evidence map

Legend: **broad local** means the release matrix has native/installed local-file
evidence; **fixture** means a transport-specific localhost native fixture exists;
**source path only** means the generic `svn_client_*` path can select the module,
but no transport-specific success fixture proves it; **local WC only** means the
operation reads or mutates local working-copy state and does not exercise its
repository URL's RA transport; **none** means no relevant product gate. These
cells are evidence statements, not support claims.

| Operation | `file://` | `svn://` | HTTP | HTTPS | `svn+ssh` |
| --- | --- | --- | --- | --- | --- |
| Open existing WC | local WC only; broad local | local WC only; svnserve-origin fixture is opened | local WC only; relocated malicious-DAV HTTP-origin fixture is opened | local WC only; CLI-bootstrapped HTTPS-origin fixture is opened | local WC only; origin untested |
| Checkout | broad local | credential-broker fixture | source path only | source path only; current HTTPS WC is CLI-bootstrapped | none |
| Remote status | broad local, on demand | credential-broker fixture | source path only | source path only | none |
| Update | broad local | credential-broker fixture | source path only | certificate-broker fixture | none |
| Commit | broad local | credential-broker fixture | source path only | source path only | none |
| History/log | broad local | credential-broker fixture | malicious DAV failure fixture only | source path only | none |
| Blame | broad local | credential-broker fixture | source path only | source path only | none |
| HEAD content | broad local | credential-broker fixture | source path only | certificate-broker fixture | none |
| Lock/unlock | broad local | credential-broker fixture | source path only | source path only | none |
| Properties list | local WC only; broad local | local WC only; origin untested | local WC only; origin untested | local WC only; origin untested | local WC only; origin untested |
| Property set/delete | local WC only; narrow fixture | local WC only; origin untested | local WC only; origin untested | local WC only; origin untested | local WC only; origin untested |

The table is derived from the transport fixtures in
`crates/subversionr-daemon/tests/native_bridge.rs:339-2105,2636-2725` and the
workflow/transport boundaries in
[`docs/release/public-claim-matrix.md`](../release/public-claim-matrix.md). In
particular, the HTTP test at `native_bridge.rs:1885-1964` is a malicious DAV XML
failure case, not normal HTTP server evidence. No cell authorizes background
remote polling; remote access remains user-initiated under the product
invariants.

The local-only rows reflect the current C calls: repository open supplies a
local path to `svn_client_info4`, property listing asks for the working revision,
and mutation uses `svn_client_propset_local`
(`native/svn-bridge/src/subversionr_bridge.c:1474-1528,2267-2305,3739-3796`).
The URL recorded in WC metadata identifies its origin but does not make those
operations transport probes.

Transport-specific prompt and failure gaps follow directly:

- HTTP/S needs explicit basic/digest versus SSPI identity, proxy 407, server TLS,
  client-certificate, redirect, and path-authz handling.
- `svn://` needs exact unavailable-SASL reporting plus connect/read/write
  timeout classification.
- `svn+ssh` needs executable/host-key/key/agent/passphrase ownership, bounded
  stderr, and process-cleanup failures; SSH prompts must not masquerade as
  Subversion credential prompts.
- all remote transports need stable DNS, refused, deadline, cancellation, auth,
  authorization, and transport failure classes without leaking URLs, paths,
  credentials, or command arguments.

## 7. Input to the D1 unified abstraction

The smallest useful common layer is a **daemon-owned remote operation policy and
lifetime envelope** around the existing `svn_client_*` calls. It is not a custom
RA implementation and not a promise to retain one physical session.

Candidate common fields and state:

- logical repository/session ID, operation ID, requested/effective URL,
  repository root/UUID, and expected transport family derived from the URL
  scheme; actual RA module selection remains inside libsvn unless separately
  verified;
- exact trusted config snapshot plus hash, Workspace Trust state, foreground or
  background interaction policy;
- auth/certificate/tunnel capability policy, absolute operation deadline,
  cooperative cancel token, and bounded termination grace;
- redirect/retry decisions, safe failure chain, redacted diagnostics, and
  evidence correlation ID;
- explicit create, active, cancelling, terminating, and completed operation
  lifecycle. These states do not imply daemon ownership of a libsvn socket.

Transport-specific capability branches remain visible:

| Transport | Capabilities that must be explicit |
| --- | --- |
| HTTP/S | brokered Basic/Digest versus daemon SSPI; proxy source/auth; server and client certificates; redirect policy; HTTP inactivity timeout |
| `svn://` | internal auth versus a separately built Cyrus variant; offered mechanism/QOP; connect/read/write deadline behavior |
| `svn+ssh` | provider, exact executable/argv, host-key policy, key/agent/passphrase mode, child/Job ownership, stderr, close/kill behavior |
| `file://` | filesystem identity and local cancellation; no invented network/auth policy |

The candidate flow is: validate trust -> select one explicit transport policy ->
materialize config/auth/cancel/deadline context -> invoke libsvn -> map a stable
result/failure -> close daemon-owned resources such as tunnel processes ->
reconcile state. For in-libsvn connections, completed means the operation
returned or its worker boundary was hard-terminated; it does not mean the daemon
closed a socket. Missing required policy fails fast. There is no automatic
transport switch, implicit tunnel, default-config fallback, or hidden retry.

R1 does not decide final protocol field names, persistence UX, process-isolation
architecture, or which remote transports become 0.3.0 claims. Those are D1 and
later evidence decisions.

## 8. Evidence strategies

### Option A: pinned local real-server fixtures

Build or stage exact server binaries/configs and start loopback processes on the
Windows hosted runner. This extends the existing source-built Apache
httpd/mod_dav_svn and svnserve substrate.

- Cost: medium initial build/config work; moderate CI time.
- Determinism: high when sources, binaries, config, ports, and credentials are
  captured in an evidence manifest.
- Representation: excellent for the packaged Windows client and lifecycle;
  limited for domain IWA and vendor-specific servers.

### Option B: disposable service/container matrix

Create fresh pinned server instances for every run. Linux containers make
Apache/svnserve variants cheap, while disposable Windows services/VMs can cover
SSPI, VisualSVN-like deployment, and OpenSSH process behavior.

- Cost: medium for Linux-only, high for Windows/domain fixtures.
- Determinism: high if images and provisioning inputs are pinned; weaker if
  external image tags or installers float.
- Representation: broad server configuration coverage. Linux-only execution is
  supplemental because it cannot prove packaged Windows SSPI, config discovery,
  or tunnel lifecycle.

### Option C: persistent external or vendor servers

Exercise a shared lab/public server manually or on a non-blocking schedule.

- Cost: low setup, ongoing operational and credential cost.
- Determinism: low because server policy, network, certificates, identities, and
  versions drift.
- Representation: useful compatibility signal, but unsuitable as release truth.

### Recommendation

Use Option A as the PR/nightly deterministic base and authoritative packaged
Windows evidence substrate. Add pinned disposable Windows service/VM cases from
Option B as release gates for behavior that loopback source builds cannot
represent, especially VisualSVN IWA and Windows OpenSSH lifecycle. Use Linux
containers for fast server-policy breadth only, and Option C only as a
non-blocking compatibility observation.

The minimum server matrix should include:

- HTTP/S: anonymous, Basic, Digest, TLS reject/trust, CA chain, path authz,
  redirects, proxy/CONNECT, and client PKCS#12; IWA in a separate Windows
  identity lane;
- `svn://`: the current internal password database, negative mechanism cases,
  authz, and blackhole/stall cases; add SASL only if a separately locked Cyrus
  build is introduced;
- `svn+ssh`: pinned Windows OpenSSH with key/agent mode, host-key failure,
  non-interactive failure, cancellation, daemon crash, and local/remote process
  cleanup. Plink can be a separate explicit provider lane if D1 chooses it.

Every evidence result should record client artifact digest, RA registration,
server/version/config digest, operation, transport/auth mode, interaction mode,
deadline/cancel outcome, and safe error class. A complete operation row is
required before broadening its claim.

## 9. Ranked risks and falsifiable D1 checks

| Rank | Risk / unknown | Falsifiable check |
| --- | --- | --- |
| P0 | The current default user config and `[tunnels]` input executes outside the Workspace Trust setting policy. | Run the packaged daemon with a poisoned default APPDATA config and executable sentinel; first reproduce the exposure, then require the D1 path to read/launch nothing unless the exact trusted snapshot is supplied. |
| P0 | Cooperative cancellation cannot interrupt stalled `svn://` or tunnel I/O. | Blackhole connect and mid-read for each transport. After the absolute deadline, require a bounded result and a daemon that can serve the next request. |
| P0 | Windows SSH child/grandchild survives cancellation or daemon exit. | Repeat long-lived `svn+ssh` cancellation 100 times and crash the daemon; assert no local SSH or remote svnserve process remains after the defined grace period. |
| P0 | Shared `svn_client_ctx_t` leaks auth/cancel baton state between operations. | Run two repositories with different realms and independent cancellation concurrently or in forced interleaving; assert credentials, prompts, result, and cancellation cannot cross. |
| P0 | Proxy/client-certificate challenges bypass or deadlock the current broker. | Gate Basic and Negotiate proxy, HTTPS CONNECT, valid/wrong/missing PKCS#12, and prompt cancellation. Require either the selected explicit route or an exact unsupported-capability failure. |
| P1 | SSPI silently uses an unintended daemon Windows identity, especially in background work. | Test domain Kerberos, NTLM fallback, non-domain identity, and different daemon tokens. Assert the chosen identity mode and prohibit hidden prompts/background fallback. |
| P1 | Cross-authority redirects forward credentials or change repository identity. | Redirect across scheme/host/port and through loops; assert policy rejection or explicit decision, no credential forwarding, and stable root/UUID checks. |
| P1 | Path authz is misreported as node-not-found or produces inconsistent partial state. | Deny one subtree and run checkout/update/list/history/blame/content/commit/lock; record exact filtered/error semantics and post-operation reconcile. |
| P1 | Current runtime packaging drifts from assumed RA/SASL capabilities. | Extend the staged-runtime gate to assert `ra_local`, `ra_svn`, `ra_serf`, schemes, Serf version, and generated `SVN_HAVE_SASL` state for every packaged artifact. |
| P1 | Failure taxonomy collapses actionable remote failures into `unknownNative`. | Inject DNS, refused, HTTP timeout, TLS, proxy, tunnel, host-key, authn, and authz failures; require distinct stable safe classifications chosen by D1. |
| P1 | Remote evidence is broadened into claims before the matrix is complete. | Have the release claim/evidence gate reject any transport/operation claim without an exact packaged artifact, pinned server/config manifest, and completed result row. |
| P1 | A local event accidentally starts background remote access. | Instrument transport opens; mutate local files and run ordinary status reconciliation. Assert zero remote session creation until an explicit user operation requests it. |

## 10. D1 entry criteria and non-decisions

D1 can start when it treats the following as fixed inputs:

1. libsvn remains the semantic authority and `svn_client_*` remains the product
   entry point; no CLI or custom working-copy semantics are introduced.
2. The common abstraction owns policy, operation lifetime, diagnostics, and
   reconciliation. Transport capability and process ownership remain explicit.
3. Required config, identity, certificate, tunnel, and deadline choices fail
   fast when absent or unsupported. No default/fallback route is implied.
4. Fixture evidence remains separate from public support. The claim matrix is
   unchanged until packaged real-server gates pass.

Open D1 decisions include the final protocol shape, config snapshot format,
SSPI policy, mTLS credential storage, proxy credential policy, deadline hard-stop
boundary, SSH provider/process isolation, redirect policy, and remote failure
taxonomy. The ranked tests above must be attached to those decisions so that
the design remains falsifiable.

## Upstream references

- [Apache Subversion 1.14.5 RA loader](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra/ra_loader.c)
- [Apache Subversion 1.14.5 RA API](https://github.com/apache/subversion/blob/1.14.5/subversion/include/svn_ra.h)
- [Apache Subversion 1.14.5 client context](https://github.com/apache/subversion/blob/1.14.5/subversion/include/svn_client.h#L950-L1085)
- [Apache Subversion 1.14.5 Serf RA](https://github.com/apache/subversion/tree/1.14.5/subversion/libsvn_ra_serf)
- [Apache Subversion 1.14.5 svn RA](https://github.com/apache/subversion/tree/1.14.5/subversion/libsvn_ra_svn)
- [Apache Serf 1.3.10](https://github.com/apache/serf/tree/1.3.10)
- [Version Control with Subversion: runtime configuration](https://svnbook.red-bean.com/en/1.8/svn.advanced.confarea.html)
- [Version Control with Subversion: svnserve and SASL](https://svnbook.red-bean.com/en/1.8/svn.serverconfig.svnserve.html)
- [Version Control with Subversion: path-based authorization](https://svnbook.red-bean.com/en/1.8/svn.serverconfig.pathbasedauthz.html)

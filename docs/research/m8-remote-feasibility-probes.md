# M8 remote feasibility probes

Status: M8 I1 feasibility evidence for issue #123. This report changes no
dependency, production code, protocol version, capability advertisement,
workflow, release gate, or public support claim.

Baseline: SubversionR `d35430ee1b32f12dd96f6065ba762b5225f2e8e2`,
Apache Subversion 1.14.5, Serf 1.3.10, APR 1.7.6, Windows `win32-x64`, and the
locked native build epoch `1784241450`.

The normative design resulting from these probes is
[`m8-unified-remote-access-design.md`](../roadmap/m8-unified-remote-access-design.md).
This document distinguishes locked-source conclusions, disposable-fixture
results, and product evidence. A source callback, local process-shape test, or
successful RA open is not a shipped transport claim.

## Acceptance map and verdicts

| Gate | Probe or source boundary | Verdict | Design consequence |
| --- | --- | --- | --- |
| server auth settlement | custom libsvn provider plus CRAM-MD5 and eight Basic fixture cells | closed for the proved auth paths | CRAM acceptance is its post-exchange save; challenged Basic acceptance survives later 403/404/409 outcomes |
| proxy settlement | locked Serf CONNECT state transition | blocked at an exact missing callback | all proxy capabilities are deferred; no hard-coded blocked output is treated as evidence |
| TLS trust settlement | four controlled HTTPS/DAV fixture cells | closed for the separate verification path | provider save is too early; permanent trust requires a distinct successful foreground RA-session open |
| authority attribution | high-level corrected-URL loop, ra_svn greeting, multi-URL callers | exact native-hook blockers locked | HTTPS auto-follow and direct svn remain disabled until their zero-contact hooks pass; relocate is rejected |
| worker containment and IPC | Windows Job/pipe process-shape tests | foundation passed | I3 must repeat with the packaged Extension Host and retain zero-descendant evidence |
| Workspace Trust ordering | deterministic state-model tests plus VS Code API/source | contract passed with corrected revoke path | grant waits for ack; revoke primarily arrives as Extension Host EOF/restart, with false update only defensive |
| OpenSSH | Windows inbox provenance, effective argv, Ed25519 parser, upstream interfaces | isolated foundation eligible; transport claim blocked | agent/unencrypted identity integration still requires the greeting hook and the locked local/server residue oracle |

## 1. Reproducible artifacts

The branch adds only test/research artifacts:

- `native/feasibility/m8-remote-settlement/probe.c` registers custom simple and
  TLS trust providers against a caller-supplied verified Subversion stage;
- `native/feasibility/m8-remote-settlement/http-fixture.ps1` implements the
  controlled HTTP and HTTPS/DAV response matrix;
- `scripts/native/smoke-m8-remote-settlement.ps1` validates inputs, rebuilds the
  probe with MSVC `/W4 /WX`, and executes a selected gate;
- `scripts/native/smoke-m8-remote-settlement-fixtures.ps1` compiles the probe,
  runs all twelve settlement cells with absolute deadlines and bounded child
  logs, and emits the two closed verdicts only after every assertion;
- `crates/subversionr-daemon/tests/m8_worker_containment_probe.rs` exercises the
  Windows process and private-pipe shape;
- `crates/subversionr-daemon/tests/m8_trust_ordering_probe.rs` exercises the
  trust epoch state machine;
- `scripts/research/m8-i1-openssh-probe.ps1` performs a no-network, no-user-SSH-
  state provenance/config/keyscan probe;
- `scripts/research/fixtures/m8-i1/ssh-keyscan-ed25519.txt` is a static public
  Ed25519 parser fixture.

The settlement CLI accepts credentials only as
`--credential-env USER SUBVERSIONR_M8_*`. The restricted process-environment
variable must already exist and be non-empty. A password value is never placed
in argv, JSONL, usage, or error output. The wrapper and C program reject URL
userinfo and control characters before build or network access. There is no
legacy raw-password argument.

## 2. Server authentication settlement

### 2.1 General provider behavior

libsvn iterates registered providers with `svn_auth_first_credentials`, then
`svn_auth_next_credentials` after a rejected credential, and explicitly calls
`svn_auth_save_credentials` when the RA implementation considers the current
credential accepted. The custom provider sets `*saved = TRUE`; it performs no
disk write. The provider baton binds the returned object to a numbered fixture
slot, so the JSONL sequence identifies which attempt was accepted without
logging a username, password, realm, or environment-variable name.

Subversion's global `SVN_AUTH_PARAM_NO_AUTH_CACHE` must not be set. In the
locked implementation it suppresses provider save callbacks, including this
custom in-memory settlement signal. Persistence is instead prevented by
registering no disk-cache provider and constructing a fresh config with
`store-auth-creds = no` and `store-passwords = no`.

Primary sources:

- [`svn_auth.h`](https://github.com/apache/subversion/blob/1.14.5/subversion/include/svn_auth.h#L93-L163)
- [`libsvn_subr/auth.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_subr/auth.c#L388-L445)
- [Subversion authentication API](https://subversion.apache.org/docs/api/latest/group__auth__fns.html)

### 2.2 ra_svn CRAM-MD5

The locked ra_svn code asks for the first simple credential, advances to the
next credential after a failed CRAM exchange, and calls
`svn_auth_save_credentials` only after server CRAM success. A disposable local
svnserve fixture with an intentionally wrong first password and correct second
password produced:

```text
provider.first(slot 0)
provider.next(slot 1)
provider.save(slot 1)
ra.opened
```

The output contained none of the supplied usernames, password values, realm, or
environment-variable names. This proves acceptance and rejection ordering for
the locked internal CRAM-MD5 cell. It does not yet prove authority confinement,
installed-product brokering, cancellation, or public direct-svn support.

Primary sources:

- [`ra_svn/internal_auth.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_svn/internal_auth.c#L70-L120)
- [`ra_svn/cram.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_svn/cram.c#L182-L220)

### 2.3 ra_serf Basic

In the locked ra_serf path, a first or repeated 401 requests/advances simple
credentials. After a challenged request receives a status below 400, ra_serf
calls `svn_auth_save_credentials`. An authz or path failure occurring after an
earlier successful OPTIONS exchange does not revoke that already accepted
credential. A direct 403 without the prior 401-to-below-400 sequence does not
call save and remains conservative.

A disposable local HTTP fixture closes eight controlled cells: successful
challenged RA open; direct challenged 403; malformed DAV after save; two-slot
credential rejection and exhaustion; termination after Authorization but
before a response; and accepted RA open followed by controlled 403, 404, or
409. The 404 cell returns `svn_node_none`; the 403 and 409 cells return bounded
Subversion error-code chains. In every later-failure cell the earlier accepted
credential remains saved. The harness requires the exact callback/event order,
contains no supplied secret or secret-variable name in its evidence, and emits
`server-auth-settlement gateClosed=true` only after all eight cells pass.

These are feasibility fixtures, not product or Apache/mod_dav_svn evidence. I9
still owns installed-product authz/path/error UX and exact support-claim gates.

Primary sources:

- [`ra_serf/util.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_serf/util.c#L1182-L1464)
- [`ra_serf/serf.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_serf/serf.c#L475-L612)

## 3. Proxy settlement

Serf obtains explicit proxy Basic credentials from the selected `servers`
config rather than the server simple-credential realm. The locked source has no
application callback that attributes an accepted CONNECT to one proxy
credential attempt. In Serf 1.3.10 `ssltunnel.c::handle_response`, the 2xx
branch sets `conn->state = SERF_CONN_CONNECTED` internally. The public
`serf_credentials_callback_t` is entered for 401/407 challenges, not for that
accepted transition.

The exact missing hook is an application callback at that CONNECT 2xx branch,
carrying the canonical proxy endpoint and the current proxy credential attempt
before origin traffic continues. The intended identity would be proxy endpoint,
`basic`, and normalized fixed username; no libsvn realm participates. That
identity is a design input only, not a proved persistence or capability key.

The following are specifically invalid acceptance signals:

- top-level SVN operation success;
- no later 407;
- origin 401/credential acceptance;
- an origin response after CONNECT.

The committed wrapper reports this exact source blocker and exits nonzero; it is
not a network probe and makes no claim that repeated 407, CONNECT/origin
separation, or bypass has been executed. The entire Basic-proxy capability cell
is deferred. A later bounded feasibility issue must either add the exact callback
or run a controlled loopback CONNECT matrix covering 407 to credential callback,
repeated 407, CONNECT 2xx followed by origin 401/403, and an origin name
resolvable only inside the proxy. Until then there is no proxy SecretStorage
entry, ephemeral proxy capability, settlement capability, or background proxy
route.

Primary sources:

- [`Serf auth dispatcher`](https://github.com/apache/serf/blob/1.3.10/auth/auth.c#L141-L219)
- [`Serf Basic auth`](https://github.com/apache/serf/blob/1.3.10/auth/auth_basic.c#L53-L116)
- [`Serf CONNECT response handler`](https://github.com/apache/serf/blob/1.3.10/ssltunnel.c#L66-L139)

## 4. TLS trust settlement

The ra_serf certificate provider's `save_credentials` callback occurs while
certificate verification is being configured, before the handshake and DAV
protocol exchange have completed. It cannot justify persistent trust.

The exact usable boundary is a distinct foreground
`svn_client_open_ra_session2` call with the pending certificate decision applied
only in memory. Successful return proves the selected certificate passed TLS
and the initial SVN/DAV session exchange for that endpoint. Only that distinct
success may persist a v2 trust decision. An ordinary operation can use
trust-once, but its certificate-provider save or later top-level result is never
converted into a permanent write.

The controlled HTTPS fixture creates an explicit self-signed certificate, uses
PowerShell `SslStream` as the DAV endpoint, and closes four cells: anonymous
RA-open success; accepted RA open followed by 403; accepted RA open followed by
typed missing-path 404; and TLS handshake/provider save followed by termination
before the first DAV response. The last cell proves save is too early, while the
first three prove the distinct successful RA-open boundary and that later
failures do not reverse it. The harness emits
`tls-trust-settlement gateClosed=true` only after all four exact event-order
assertions pass.

Changed-certificate, timeout, installed UI, and full Apache/mod_dav_svn rows
remain I8 product evidence; they are not missing from this settlement decision.

Primary sources:

- [`ra_serf/serf.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_serf/serf.c#L475-L612)
- [`ra_serf/options.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_serf/options.c#L546-L630)
- [`svn_client_open_ra_session2`](https://subversion.apache.org/docs/api/latest/group__clnt__sessions.html)

## 5. Authority attribution

### 5.1 HTTP redirects

The locked ra_serf OPTIONS exchange can return a corrected URL only for an
initial 301. It does not itself follow the redirect. Optional following belongs
to `svn_client__open_ra_session_internal`: when its caller supplies a
`corrected_url` output, the client emits the redirect notification and loops to
open another session. The next Serf network loop has a cancellation check, but
I1 has not executed the required double-sentinel zero-contact fixture. Initial
302, 307, and 308 do not produce that corrected-URL path.

High-level client entrypoints do not all let SubversionR decline this behavior.
The locked `update_internal` always passes `&corrected_url` through
`reuse_ra_session`; after the follow loop returns, it may automatically relocate
the working copy. The desired initial reject-all policy is therefore an exact
native blocker, not a caller option. No HTTPS capability whose high-level
entrypoint enables corrected URLs is eligible until that entrypoint is audited
and the blocker below passes.

The exact hook belongs in `svn_client__open_ra_session_internal` immediately
after `svn_ra_open5` returns a non-null corrected URL and before notification or
the next loop iteration changes `base_url`. It must consult the operation's
redirect policy and return the typed rejection before a second target can be
contacted. An alternative notification/cancel implementation is eligible only
if the operation-scoped reject state is guaranteed visible to the cancel
callback before the next Serf context run. Either route requires a controlled
origin listener returning 301 plus a forbidden listener whose connection,
request, and Authorization-header counters all remain exactly zero. Same-origin
enablement remains a later independent cell; cross-authority and HTTPS-to-HTTP
redirects are unconditional failures.

### 5.2 ra_svn repository root and multi-URL operations

The ra_svn server greeting contains a server-selected `repos_root`; the public
client API provides no callback before the value can influence later behavior.
I6/I7 therefore require a narrow locked-source authority hook and a malicious
greeting fixture. Without it, all direct-svn capabilities remain deferred.

The missing hook is exact and falsifiable: immediately after the post-auth
`svn_ra_svn__read_cmd_response(conn, ..., "c?c?l", &conn->uuid,
&conn->repos_root, ...)` succeeds, and before canonicalization, capability use,
or returning the session, compare the returned root with the prevalidated
requested authority and reject a mismatch. Every reconnect through
`open_session` must traverse the same hook. A malicious fixture must return a
different authority and observe zero follow-up connections/commands. The same
post-auth response is the only eligible exact-once accepted signal for an
OpenSSH tunnel; it proves acceptance, not structured rejection.

Relocate is rejected in the first scope. Other multi-URL operations must
canonicalize all explicit/WC-derived URLs and prove one authority before worker
launch; externals stay disabled. A same-authority preflight is not permission to
accept a later server-selected authority change.

The normative initial inventory is: branch create/repository copy compares
source and destination; switch compares the WC repository and destination;
merge compares every source/peg URL and the target WC repository; update,
commit, lock, and unlock compare the WC repository with every explicit target;
checkout/open/status/content/log/blame compare their explicit URL with any
opened-session/WC repository URL. Relocate is reject-only, and any operation
whose externals cannot be disabled fails before network. The normative table is
in design section 7.1. This is a pre-launch implementation contract, not a claim
that every future `libsvn_client` entrypoint was already executed by I1; each
capability slice must pair its concrete entrypoint with a zero-network rejection
test before advertising it.

Primary sources:

- [`ra_serf/options.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_serf/options.c#L546-L630)
- [`libsvn_client/ra.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_client/ra.c#L405-L462)
- [`libsvn_client/update.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_client/update.c#L470-L495)
- [`ra_serf context cancellation`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_serf/util.c#L902-L915)
- [`ra_svn/client.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_svn/client.c)

## 6. Worker containment and private IPC

The Windows-only Rust test creates a worker suspended, assigns it to a Job with
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, passes only an explicit inherited-handle
list, resumes it, and performs bounded full-duplex traffic large enough to block
both pipe directions. The worker's 1 MiB overlapped named-pipe write must return
exactly `ERROR_IO_PENDING` before it signals the parent to drain, and
`GetOverlappedResult` later verifies the full byte count; no elapsed-time guess
decides backpressure.

Two separate cleanup tests preserve both contracts. The normal hard-stop calls
`TerminateJobObject`, retains the Job query handle, and observes
`ActiveProcesses == 0`. The crash/disconnect backstop snapshots the complete Job
PID list, opens independent process handles, closes the last kill-on-close Job
handle, and waits for the worker and deliberately spawned descendant to exit. A
subsequent request succeeds. A separate RAII test proves an unassigned suspended
child is terminated and waited if Job assignment fails before ownership transfer.

A Node fixture repeats the shape under a synthetic Extension Host parent already
inside its own Job. The exact nested Node test passed ten consecutive local
runs after replacing the timing-dependent pipe with overlapped-I/O evidence. The
full worker file passed all eight tests for ten consecutive runs, and the trust
file passed all six tests.

This is foundation evidence, not packaged VS Code evidence. I3 must run the
actual installed extension-host shape on the supported Windows runner and retain
the Job accounting, bounded broker, forced-close, and subsequent-request
artifacts.

Primary sources:

- [Windows Job Objects](https://learn.microsoft.com/windows/win32/procthread/job-objects)
- [`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`](https://learn.microsoft.com/windows/win32/api/winnt/ns-winnt-jobobject_extended_limit_information)
- [`PROC_THREAD_ATTRIBUTE_HANDLE_LIST`](https://learn.microsoft.com/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute)
- [Overlapped pipe I/O](https://learn.microsoft.com/windows/win32/ipc/synchronous-and-overlapped-input-and-output)
- [Node.js writable backpressure](https://nodejs.org/api/stream.html#writablewritechunk-encoding-callback)

The current TypeScript JSON-RPC writer does not wait for `drain` after
`write(false)`. I2 must introduce one ordered write queue. I3 must supervise
parent stdio EOF/disconnect concurrently with worker and broker waits so host
termination can never queue behind a long operation.

## 7. Workspace Trust ordering

The VS Code API exposes `workspace.isTrusted` and
`onDidGrantWorkspaceTrust`, but no revocation event. VS Code's transition code
stops/restarts the local Extension Host, or reloads a remote window, for the
reverse transition. The design therefore cannot depend on an extension-sent
false update as its primary revoke signal.

The proved contract is:

1. initialize a trust epoch for each Extension Host connection;
2. on grant, increment the epoch, send `trusted: true`, and keep remote submit
   disabled until the matching acknowledgement;
3. on parent stdio EOF/disconnect, cancel waits, terminate all operation Jobs,
   and observe zero descendants before discarding the connection;
4. accept `trusted: false` only as a defensive/testable path and acknowledge it
   only after queued/reserved work is cancelled and active Jobs reach zero;
5. reject replayed, skipped, stale, or future epochs.

The six deterministic tests cover grant acknowledgement, queued and reserved
revocation, active-worker cleanup before acknowledgement, invalid epochs, and
the reserved-to-resume race.

Primary sources:

- [Workspace Trust Extension Guide](https://code.visualstudio.com/api/extension-guides/workspace-trust)
- [VS Code API](https://code.visualstudio.com/api/references/vscode-api#workspace)
- [`extensionEnablementWorkspaceTrustTransitionParticipant.ts`](https://github.com/microsoft/vscode/blob/b12476e6af47cbeb95f54b4e03ff50cccef50048/src/vs/workbench/contrib/extensions/browser/extensionEnablementWorkspaceTrustTransitionParticipant.ts)

## 8. Windows OpenSSH

The no-network probe accepts only the Windows inbox
`%SystemRoot%\System32\OpenSSH` trio. It verifies canonical non-reparse paths in
one directory, catalog signatures, `IsOSBinary`, Microsoft Windows publisher,
one file/product version set, and per-file SHA-256. It then validates effective
`ssh -G` output for isolated common, agent, unencrypted identity, and research-
only password argv, and strictly parses one Ed25519 keyscan record.

On the local Windows host the probe passed with OpenSSH for Windows 9.5.5.1 /
OpenSSH_9.5p2. The recorded SHA-256 values were:

| File | SHA-256 |
| --- | --- |
| `ssh.exe` | `8607ff933e769e77534b1244e39965bcf1c904dbfd4b9da819bbb71034cfef88` |
| `ssh-keyscan.exe` | `43ad579511e145036282f67783459906da4d58b23b46cfc62f1b9b35a8003d06` |
| `ssh-keygen.exe` | `3e2f8579e998bc77870b4544efa852391d20afb1bdcf6f48fccb34383ab4b730` |

The static `[fixture.invalid]:2222` Ed25519 record produced fingerprint
`SHA256:ZkAslGjFiUHdGf/WUL8rQvkib4PTvQatUV0OUQSncCA`. The probe reads or writes no
user SSH state and performs no network access.

Initial product onboarding does not depend on keyscan: in a trusted foreground
flow the user imports a complete Ed25519 known-hosts record obtained out of band,
SubversionR requires its host/port to equal the profile authority, recomputes
and displays the fingerprint, and stores the public blob/fingerprint as
non-secret profile data only after explicit confirmation. Each operation renders
that snapshot to a private temporary known-hosts file. Network keyscan
enrollment remains a later cell.

An ra_svn greeting occurs after SSH authentication, but the public tunnel API
has no greeting callback. I11 needs a narrow exact-once hook at the successful
greeting response before any OpenSSH capability is enabled. More importantly,
Windows OpenSSH uses exit 255 for wrong password/passphrase and several network
or remote-command failures. Without stderr parsing there is no structured
rejection signal. Password and encrypted-key askpass are therefore deferred,
not persisted or advertised. The first eligible subset is pre-pinned Ed25519
plus agent or unencrypted identity-file authentication.

The server residue boundary is locked as a falsifiable contract rather than an
unproved clean-tree assertion. A controlled `sshd` forced-command fixture must
give every tunnel an unpredictable session id and expose before/after snapshots
of that session's server PID and descendants, live connection count, and fixture
temporary artifacts. Normal completion, cancellation, timeout, and client crash
must each reach `activePids=0`, `connections=0`, and `tempArtifacts=0` inside one
absolute cleanup deadline. The client side must simultaneously observe Job
`ActiveProcesses=0` and removal of the operation temp root, after which a new
session must succeed. Until that fixture and the post-auth greeting hook pass,
no OpenSSH transport capability is advertised; I12 retains the 100-cycle product
evidence row.

Primary sources:

- [Windows OpenSSH overview](https://learn.microsoft.com/windows-server/administration/openssh/openssh-overview)
- [`Get-AuthenticodeSignature`](https://learn.microsoft.com/powershell/module/microsoft.powershell.security/get-authenticodesignature?view=powershell-7.6)
- [`WINTRUST_CATALOG_INFO`](https://learn.microsoft.com/windows/win32/api/wintrust/ns-wintrust-wintrust_catalog_info)
- [`ssh_config(5)`](https://man.openbsd.org/ssh_config)
- [`ssh-keyscan(1)`](https://man.openbsd.org/ssh-keyscan)
- [`ra_svn/client.c`](https://github.com/apache/subversion/blob/1.14.5/subversion/libsvn_ra_svn/client.c)

## 9. Local reproduction record

The locked dependency and Subversion stages were rebuilt from source with
`SOURCE_DATE_EPOCH=1784241450` and `LINK=/Brepro`. The staged Subversion build
completed with ra_serf enabled. The following checks then passed locally:

```text
PowerShell AST parse: settlement wrappers, HTTP(S) fixture, and OpenSSH probe
MSVC C11 /W4 /WX: settlement probe
settlement negative gates: missing env, invalid env name, URL userinfo/control,
  unsupported proxy, unreachable RA
CRAM-MD5: wrong first credential -> correct second -> save second -> RA opened
Basic fixture matrix: 8/8; server-auth-settlement gateClosed=true
TLS fixture matrix: 4/4; tls-trust-settlement gateClosed=true
OpenSSH: provenance/effective argv, no-network default, static Ed25519 fixture
worker containment: exact nested Node test 10 consecutive runs; full 8/8 for 10 runs
trust ordering: 6/6
cargo fmt --all -- --check
git diff --check
```

The PR baseline must additionally run the repository-wide TypeScript, Rust,
native-script, documentation support/security/readiness, and PR Fast gates.

## 10. Explicit non-claims and remaining product gates

I1 does not claim any remote transport. Specifically, it does not prove:

- installed VS Code UI, real Extension Host revocation, localization, or
  reconciliation;
- a product authority hook for ra_svn repository roots or redirects;
- product certificate-trust storage, installed UX, or release evidence;
- any Basic-proxy capability or credential settlement;
- OpenSSH network authentication, server-side cleanup, or a 100-cycle residue
  run;
- password/passphrase askpass settlement;
- externals, relocate, cross-authority operations, ambient configuration,
  public-host uptime, or a Marketplace artifact.

Those items remain owned by the narrowed I2-I13 slices in the normative design.

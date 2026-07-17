# M8 unified remote-access design

Status: proposed design candidate for issue #121 and parent tracker #113. This
document defines the implementation contract for M8. It does not change product
code, protocol v1.30, dependencies, release gates, or public support claims.

Target: SubversionR `0.3.0` on Windows `win32-x64`.

## 1. Inputs and decision authority

This design reconciles the three public M8 research reports:

- [`m8-remote-access-survey.md`](../research/m8-remote-access-survey.md) defines
  the RA/session boundary, transport behavior, existing fixture coverage, and
  ranked falsifiable risks.
- [`m8-native-capability-audit.md`](../research/m8-native-capability-audit.md)
  locks the Serf/SSPI, SASL, Wincrypt, custom tunnel, and Windows process facts.
- [`m8-external-ecosystem-survey.md`](../research/m8-external-ecosystem-survey.md)
  supplies deployment archetypes, user-demand categories, VS Code platform
  constraints, SSH adapter separation, and an independent evidence plan.

The repository invariants in [`AGENTS.md`](../../AGENTS.md), the engineering
rules in [`CONTRIBUTING.md`](../../CONTRIBUTING.md), and the current
[`public-claim-matrix.md`](../release/public-claim-matrix.md) take precedence if
a research recommendation is broader than current evidence.

The implementation-level constraints are additionally grounded in the primary
[Windows Job Objects](https://learn.microsoft.com/windows/win32/procthread/job-objects),
[`TerminateJobObject`](https://learn.microsoft.com/windows/win32/api/jobapi2/nf-jobapi2-terminatejobobject),
and [Job accounting](https://learn.microsoft.com/windows/win32/api/winnt/ns-winnt-jobobject_basic_accounting_information)
contracts; the Apache Subversion
[authentication API](https://subversion.apache.org/docs/api/latest/group__auth__fns.html),
[`auth.c`](https://github.com/apache/subversion/blob/trunk/subversion/libsvn_subr/auth.c),
[ra_svn auth](https://github.com/apache/subversion/blob/trunk/subversion/libsvn_ra_svn/internal_auth.c),
and [ra_serf auth handling](https://github.com/apache/subversion/blob/trunk/subversion/libsvn_ra_serf/util.c);
and the OpenBSD [ssh](https://man.openbsd.org/ssh.1),
[ssh_config](https://man.openbsd.org/ssh_config.5), and
[ssh-keyscan](https://man.openbsd.org/ssh-keyscan.1) manuals. These sources
establish mechanism behavior; SubversionR support still requires the controlled
evidence gates below.

The design uses these terms precisely:

- **operation envelope**: SubversionR policy and lifetime for one top-level
  `svn_client_*` call; it is not a reusable `svn_ra_session_t`;
- **authority**: one prevalidated transport endpoint plus the exact
  authentication realm reported for that endpoint; an auth callback realm is
  not treated as a challenged URL;
- **operation authority set**: one exact origin endpoint and, only when the
  selected profile requires it, one exact proxy endpoint; no other authority is
  reachable by the worker;
- **profile**: a trusted, non-secret, machine-scoped configuration selected for
  one authority;
- **worker**: a disposable Rust sidecar process that loads the C bridge and
  executes exactly one remote operation;
- **claim cell**: one exact combination of transport, authentication mode,
  operation group, server fixture, packaged client artifact, and expected
  result.

## 2. Normative decisions

| Area | Decision |
| --- | --- |
| SVN semantics | Continue to call `svn_client_*` through the narrow C ABI. No production `svn` CLI, RA reimplementation, or direct working-copy database access. |
| RA lifetime | One request-scoped operation envelope. libsvn owns any physical RA session opened inside that call; SubversionR does not pool or promise connection reuse. |
| hard-stop boundary | Execute every operation that can reach a remote URL in a one-operation worker process owned by the parent daemon. The parent can terminate the worker tree at the absolute deadline and continue serving later requests. |
| config owner | TypeScript owns validated user intent; the parent daemon validates the typed snapshot; the worker constructs a fresh allowlisted in-memory Subversion config. System/user config, registry config, `%APPDATA%\\Subversion`, `SVN_SSH`, and `[tunnels]` are never read. |
| credential persistence | `SecretStorage` is the only M8 persistence owner. Session credentials are memory-only. Standard SVN/Wincrypt auth-cache interoperability remains deferred and is not a read fallback or write mirror. |
| server password auth | libsvn simple credentials are brokered by authority. A credential is persisted only after the remote operation proves it was accepted. |
| TLS server trust | Normal certificate verification runs first. Remaining failure bits may enter the existing foreground trust broker. Background work never prompts. Changed fingerprints always fail and require a new explicit decision. |
| proxy auth | A configured proxy is the only optional second member of the operation authority set. Its credential lease is acquired before worker start and supplied only to the worker's in-memory config; it is not written to a `servers` file or persisted without a proved non-407 acceptance signal. |
| SSPI | Compiled availability is not enablement. Negotiate/NTLM is disabled unless a later, separately evidenced `windowsIntegrated` profile selects the operation worker's process token explicitly. It is not a `0.3.0` Tier-1 claim cell. |
| direct `svn://` | M8 Tier 1 supports the locked build's internal `ANONYMOUS` and `CRAM-MD5` mechanisms. Cyrus SASL remains unsupported until introduced as a separately locked build variant. |
| `svn+ssh` | All allowed tunnels use the application opener. Windows OpenSSH and Plink/Pageant are different explicit providers and never fall back to each other. The first `0.3.0` claim targets Windows OpenSSH; Plink/Pageant remains a later cell. |
| external repositories | Externals remain outside the first `0.3.0` claim. Remote operations must force externals off or fail before network access when the requested operation cannot enforce that boundary. A worker may contact only its prevalidated origin and optional proxy. |
| public hosts | Public hosted repositories may be permission-reviewed, low-frequency compatibility canaries only. They are not release gates and cannot replace controlled fixtures. |
| background access | No default remote polling. Background operations are non-interactive and cannot create credentials, certificate trust, host-key trust, or adapter configuration. |
| failure behavior | Missing profile, unsupported auth mode, unsafe Workspace Trust state, ambiguous profile match, expired deadline, and invalid executable/configuration all fail with stable typed errors. There is no compatibility alias, ambient lookup, or silent retry through another mode. |

These choices deliberately reject two tempting compatibility chains:

1. `SecretStorage -> Wincrypt cache -> prompt` is not permitted. M8 uses
   `SecretStorage -> foreground prompt` within one explicit broker mode. A
   future standard-cache mode must be designed and evidenced as an alternative,
   not appended to this chain.
2. `OpenSSH -> Plink -> default libsvn tunnel` is not permitted. One profile
   selects one adapter, and any adapter failure terminates that operation.

## 3. Current boundary that M8 replaces

The current bridge creates one long-lived `svn_client_ctx_t` and calls
`svn_config_get_config(&config, NULL, pool)` in
`native/svn-bridge/src/subversionr_bridge.c:1396-1420`. This admits ambient
Subversion config even though the extension's future settings in
`packages/vscode-extension/src/security/externalToolConfiguration.ts` are not
passed to the bridge. M8 must replace the null config directory; adding another
config source would leave the exposure intact.

The current protocol has `credentials/request` and `certificate/request`
contracts and protocol v1.30 capabilities in
`crates/subversionr-protocol/src/lib.rs:530-620,675-699`. The TypeScript
credential controller already provides hashed realm keys, session/SecretStorage
persistence, background rejection, and prompt single-flight in
`packages/vscode-extension/src/auth/credentialController.ts`. It currently
stores a requested persistent credential before the operation succeeds and its
storage identity does not support multiple accounts per authority. M8 changes
those two semantics; it does not discard the controller.

The daemon's `AuthRequestBroker` currently carries simple credentials and TLS
server trust only (`crates/subversionr-daemon/src/bridge.rs:856-892`). The stable
failure cause enum has five local-oriented values
(`crates/subversionr-protocol/src/lib.rs:497-503`). Proxy credentials, client
certificate selection, SSH host keys, tunnel results, and actionable network
failures therefore require distinct contracts rather than string parsing.

`RepositoryOperationScheduler` already serializes user operations per
repository, and `remoteStatusCheckService.ts` keeps explicit remote refresh
separate from ordinary local refresh. M8 extends those boundaries; it does not
route local watcher events into the remote lane.

## 4. Process and ownership model

### 4.1 Parent daemon

The existing stdio daemon remains the only process connected to the extension.
It owns:

- repository identity and cached session metadata;
- request validation and operation classification;
- one active native operation per working-copy root;
- the canonical monotonic deadline and cancellation state;
- auth/trust reverse-RPC forwarding;
- connection-state transitions and safe diagnostics;
- creation, supervision, settlement, and termination of workers.

The parent must not load remote libsvn state for an operation after M8 worker
isolation is enabled. Local-only calls may continue on the existing bridge until
a later design chooses otherwise.

### 4.2 One-operation worker

The packaged daemon binary gains a private worker mode. It is not a public CLI.
The parent starts it with an inherited control pipe and the already verified
absolute bridge path. The worker:

1. accepts one length-framed request with one operation envelope;
2. creates a fresh bridge runtime and operation pool;
3. builds the exact allowlisted Subversion config in memory;
4. forwards broker challenges over the private control pipe;
5. executes one `svn_client_*` call;
6. copies the bounded result and native diagnostic chain into one response;
7. destroys its operation pool and exits.

The worker never accepts a second operation. It has no repository cache,
SecretStorage access, UI, arbitrary config-directory input, or network listener.
Its protocol is internal, versioned, and rejects unknown fields and versions.

### 4.3 Windows process containment

Before worker resume, the parent assigns it to a per-operation Windows Job with
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. Descendants, including an OpenSSH process,
remain in that Job because neither the Job nor worker permits breakaway. Worker
creation must use an explicit executable and argv, `shell: false` semantics, a
minimal environment, `CREATE_NO_WINDOW | CREATE_SUSPENDED`, and an explicit
inherited-handle allowlist. Windows 8 and later support nested Jobs, but VS Code
or a CI host may already place the daemon in a parent Job with incompatible
limits. The parent must query its Job state, attempt the valid nested assignment
while the worker is suspended, and fail with the exact Win32 result if it cannot
form the operation Job. It must never resume an uncontained worker as fallback.

Normal completion, or early cancellation while budget remains, may close tunnel
input and drain bounded output/stderr only within the remaining operation
deadline. Budget exhaustion calls `TerminateJobObject` immediately; it never
starts or resets a grace period. The Job is unnamed and its handle is
non-inheritable and excluded from the child's inherited-handle allowlist. After
hard termination, the operation is already settled and the parent keeps its Job
handle open under a separate bounded supervision budget while it polls
`JobObjectBasicAccountingInformation.ActiveProcesses` until it reaches zero;
only then does it close the handle. `KILL_ON_JOB_CLOSE` is the parent-crash
backstop, not the observable normal hard-stop sequence. Failure to observe zero
enters the typed cleanup/recovery failure state. Result settlement does not
release the working-copy native lane; section 4.4's zero-process and recovery
conditions do. Evidence must prove no worker
or local tunnel descendant remains and that the parent serves a subsequent
request.

Killing a client process cannot prove a remote `svnserve -t` process exited.
The controlled SSH fixture must expose a server-side residue oracle. A clean
local process tree without that oracle is incomplete evidence.

### 4.4 Scheduling

Each working-copy root has one native lane. A remote read or mutation holds that
lane until success/failure cleanup completes. After hard termination it remains
blocked until Job accounting observes zero active descendants and any required
recovery reaches a terminal result. If residue accounting expires, the
repository enters `remoteRecoveryBlocked`; no later local or remote native call
for that working copy may start. The parent may still serve diagnostics,
filesystem event collection, and unrelated repositories. This prevents two
libsvn processes from mutating or locking the same working copy at once.
Different repositories may run in different workers.

Local filesystem event collection remains live while a remote operation runs,
but publication waits for operation settlement and any required targeted
reconcile. A hard-terminated or otherwise indeterminate mutation schedules a
separate bounded recovery operation; it does not extend the expired operation.
Local commands never wait on an unrelated repository's remote worker. The
explicit remote-status command uses the same per-repository lane and coalesces
duplicate requests; it is never started by a local dirty-path event.

### 4.5 ADR impact

[`ADR-013`](../adr/ADR-013-disposable-remote-operation-workers.md) records the
private one-operation worker topology. It clarifies rather than supersedes
ADR-007: the Extension Host still starts and connects to exactly one parent
sidecar, while workers expose no product endpoint. ADR-010 remains unchanged:
only the TypeScript layer accesses SecretStorage, and workers receive bounded
ephemeral leases through the parent. ADR-001 and ADR-002 continue to govern the
public TypeScript/daemon/native split and Extension Host stdio RPC; the worker
pipe is a private versioned execution protocol, not a second public transport.

## 5. Remote operation envelope

Every RPC that can resolve to `http`, `https`, `svn`, or `svn+ssh` must carry a
`remote` object. The exact protocol minor is allocated by the implementation PR;
this design does not change v1.30.

```text
RemoteOperationEnvelope {
  operationId: non-empty UUID
  intent: foreground | background
  interaction: allowed | forbidden
  timeoutMs: bounded positive integer
  workspaceTrust: trusted
  trustEpoch: monotonic positive integer
  profile: RemoteAccessProfileSnapshot
  expectedOrigin: CanonicalEndpoint
  expectedProxy?: CanonicalEndpoint
}
```

Normative validation:

- `background` requires `interaction=forbidden`.
- The parent captures one monotonic `deadline = now + timeoutMs`; queueing,
  connect, broker waits, provider iteration, libsvn work, and tunnel close all
  consume that same budget. No nested step resets it.
- Deadline expiry settles the operation immediately as `timedOut`, or as
  `indeterminate` when mutation may have started. A required full reconcile is a
  new operation with its own bounded deadline. No later mutation may start for
  that working copy until recovery succeeds or returns an explicit blocked
  state.
- The extension sends ordered `workspaceTrust/update { trusted, trustEpoch }`
  requests to the parent and waits for
  `{ acknowledgedTrustEpoch: trustEpoch }`. An operation requires
  `workspaceTrust=trusted` and an epoch equal to the parent's latest
  acknowledged epoch. A stale or future value returns
  `SUBVERSIONR_REMOTE_TRUST_EPOCH_MISMATCH`. Trust revocation cancels
  interactive waits and prevents worker/network launch for queued operations.
- A remote URL without an envelope fails before network access. A `file` URL
  with a remote envelope fails as a caller contract error.
- The daemon independently canonicalizes every explicit input URL and compares
  it with the selected profile and `expectedOrigin`. When a proxy is selected,
  `expectedProxy` is required and must exactly match the profile; without a
  proxy profile it is forbidden. The extension's
  classification is not sufficient authority.
- One initial worker may contact only the prevalidated origin, or only the exact
  proxy socket that carries requests for that origin. Direct proxy bypass is a
  typed failure. Externals are disabled. Multi-URL copy, switch, relocate, or
  other operations whose targets cannot all be proven to use that origin fail
  before worker/network launch.
  Redirects are rejected until a transport slice proves enforcement before any
  credential forwarding.
- Unknown profile schema versions and unknown enum values fail. They are never
  interpreted as defaults.

The initial timeout limits are constants owned by the daemon and tested per
operation class. A later user setting may only narrow those bounds unless a
separate reviewed requirement allows expansion.

### 5.1 Protocol capability and failure contract

Protocol negotiation advertises granular capabilities instead of one broad
`remoteAccess` flag. Foundation capabilities are:

- `remoteOperationEnvelope`;
- `trustedConfigSnapshot`;
- `remoteWorkerIsolation`;
- `remoteConnectionState`;
- `credentialLeaseSettlement`;
- `certificateTrustLeaseSettlement`, `proxyCredentialLeaseSettlement`, and
  `sshSecretLeaseSettlement` only after their distinct contracts pass evidence;
- `sshHostKeyChallenge` only after that contract is implemented.

Each enabled transport and auth mode has a separate capability, for example
`remoteSvnAnonymous`, `remoteSvnCramMd5`, `remoteHttpsAnonymous`,
`remoteHttpsBasic`, `remoteHttpsBasicProxy`, `remoteSvnSshOpenSshAgent`, and
`remoteSvnSshOpenSshIdentityFile`. Reserved profile enum values do not cause
their capabilities to be advertised. The exact protocol minor is allocated in
each implementation slice and older peers fail negotiation for required
capabilities rather than accepting a reduced path.

The typed failure surface distinguishes at least cancellation, absolute
deadline expiry, recovery required/blocked, credential rejection, redirect
rejection, cross-authority rejection, SSH executable/provenance failure, host
key required/changed, tunnel startup/exit, tunnel cleanup failure, Job
containment failure, and unsupported transport/auth capability. These classes
are derived from owned state and symbolic native errors, never localized output.
Trust-epoch mismatch is a dedicated caller/state error, not a generic remote
configuration failure.

## 6. Trusted profile snapshot

### 6.1 Ownership and selection

Profiles contain no secrets and live in a new machine-scoped
`subversionr.remote.profiles` setting. Workspace and folder values are invalid,
not ignored. A foreground onboarding flow may create a profile only after
Workspace Trust is granted. An authority must match exactly one enabled profile;
zero or multiple matches fail before worker/network launch.

The snapshot is immutable for the operation and contains:

```text
RemoteAccessProfileSnapshot {
  schema: subversionr.remote-profile.v1
  profileId: stable non-secret identifier
  authority: { scheme, canonicalHost, effectivePort }
  serverAuth: anonymous | basic | cramMd5 | windowsIntegrated
  serverAccount: none | { mode: fixed, username } | { mode: chooseForeground }
  credentialPersistence: secretStorage
  tls?: { trust: windowsRootsThenBroker | explicitCaThenBroker,
          caBundlePath?: absolute canonical path }
  proxy: none | { authority, auth: anonymous | basic,
                  account: none | { mode: fixed, username } }
  ssh: none | OpenSshProfile | PlinkProfile
  redirectPolicy: sameAuthorityOnly
}
```

The Tier-1 implementation accepts only the modes required by its slice.
`windowsIntegrated`, `explicitCaThenBroker`, and `PlinkProfile` are rejected
until their own evidence slice enables them. Reserving a name in this design is
not a product capability.

The parent serializes a canonical form, validates it again, and records only a
SHA-256 profile hash plus safe enum fields in diagnostics. Raw usernames,
realms, proxy paths, CA paths, repository URLs, and secrets are not logged.

Anonymous modes require `serverAccount=none`. Password modes require either a
fixed normalized username or `chooseForeground`. The latter is valid only for
a foreground interactive operation: the controller always shows an attributed
account chooser before releasing a lease, even if one stored account exists.
Background operations require `fixed`; a missing fixed entry fails without a
prompt, and multiple matching entries are a storage-integrity error. Accounts
are never attempted in sequence. Proxy Basic always requires one fixed username
because its lease must exist before worker/network launch.

### 6.2 In-memory Subversion config

The worker creates a fresh config hash with only `config` and `servers`
categories and sets allowlisted keys through libsvn config APIs. It does not
call `svn_config_get_config` with a null or user-provided directory. The initial
allowlist is:

- explicit `http-auth-types` for the selected server auth mode;
- server timeout derived from the remaining envelope budget;
- explicit proxy host, port, username, and ephemeral password when selected;
- selected certificate authority inputs;
- `auth:store-auth-creds = no` and `auth:store-passwords = no`;
- no `[tunnels]` entries.

The custom provider set contains no disk-cache provider. It deliberately does
not set `SVN_AUTH_PARAM_NO_AUTH_CACHE`, because libsvn uses that parameter to
skip every provider `save_credentials` callback, including SubversionR's
in-memory lease settlement hook. Disabling persistence is achieved by the
provider set and config keys above, not by suppressing the accepted signal.

An implementation test places executable sentinels and conflicting auth/proxy
values in system/user config, the Windows registry, `%APPDATA%\\Subversion`,
`SVN_SSH`, and a conventional SSH config. A passing operation must neither read
their behavior nor execute their sentinels.

### 6.3 Existing future settings

`subversionr.svn.configDirectory` and `subversionr.svn.tunnelCommand` were
published as future configuration surfaces but have no native product effect.
The first M8 implementation removes them and introduces the typed profile
surface. Their values are not migrated, aliased, parsed, or used as fallback.
`subversionr.tortoise.configDirectory` remains scoped to the optional
TortoiseSVN adapter and never enters the native remote profile.

The existing credential key format is a v1 realm-only index. M8 introduces a v2
endpoint/realm/auth/account index as a destructive schema cutover: M8 never
reads, migrates, or falls back to v1 entries. If v1 entries are detected, the
extension offers one explicit localized clear action before remote password
authentication is enabled. Declining or failing that clear leaves the relevant
profile blocked. A separately reviewed migration requirement would be needed to
preserve values.

Existing `subversionr.certificateTrust.v1.<realmHash>` values were written when
the user selected permanent trust, before the connection proved acceptance. I8
introduces `subversionr.certificateTrust.v2.<authorityHash>` entries whose
hashed identity binds endpoint, exact realm, fingerprint algorithm, fingerprint,
and normalized failure set, and whose value records only an accepted trust
lease. The v2 controller never reads, migrates, or falls back to v1. When a
challenge computes an existing exact v1 key, a foreground flow may offer one
explicit localized deletion of that key; background use and a declined or
failed deletion return a stable legacy-trust-blocked error. SecretStorage is not
enumerated, and unrelated v1 keys remain unreachable. Preserving a v1 decision
would require a separately reviewed migration requirement and new evidence.

The remote worker registers only the auth providers selected by its profile. It
does not register the ambient operating-system username provider currently
backed by `svn_user_get_name`; local `file://` behavior is outside this cutover.

## 7. Authority, credentials, and settlement

### 7.1 Canonical authority

A server-password credential storage key contains:

```text
prevalidated profile endpoint + auth kind
+ exact libsvn realm + normalized account
```

Host canonicalization lowercases DNS names, removes a trailing dot, applies one
documented IDNA form, and normalizes IPv6 brackets without resolving DNS.
Default ports are materialized (`80`, `443`, `3690`, or `22`). The realm remains
the exact libsvn-provided byte string after UTF-8 validation. Proxy-password and
SSH tunnel-secret keys use the separate identities below because neither has a
libsvn realm. SSH host-key authorities are host plus effective port plus adapter
kind.

The endpoint is known before the worker starts. libsvn's simple-credential
provider callback supplies a realm and optional username, not a challenged URL;
therefore SubversionR never derives or changes the endpoint from that callback.
The one-origin operation rule makes endpoint attribution unambiguous.
Repository id, repository UUID, working-copy root, and external-parent identity
are attribution fields only. They never make two authority keys equivalent.
Safe logs use the authority hash and enum fields; UI may display the canonical
host and a bounded repository label.

### 7.2 Credential lease

`credentials/request` evolves to include the canonical endpoint/auth fields and
returns an opaque `leaseId` with the credential. The controller may satisfy the
request from a session entry, SecretStorage, or one foreground prompt. Prompt
single-flight is keyed by the authority without account until the user chooses
an account, then storage is keyed by authority plus account. This permits
multiple accounts for one realm without overwriting them.

Account selection is fixed by the immutable profile rules in section 6.1. A
fixed username reads only that account and may prompt only for that username. A
`chooseForeground` request shows the account chooser before any credential is
released. Background requests never select among accounts, and neither mode
automatically advances to a different stored account after rejection.

The response's persistence value is an **intent**, not an immediate write. The
controller retains a pending lease in memory. The parent later sends exactly one
settlement:

- `accepted`: store the credential if the user chose `secretStorage`, otherwise
  retain it for the session;
- `rejected`: delete the matching stored value and the pending lease;
- `unused`: discard the pending lease without changing an existing stored value;
- `cancelled` or `timedOut`: discard the pending lease.

The bridge implements a custom libsvn auth provider around each lease. Its
`first_credentials` callback acquires the lease, `next_credentials` settles the
previous lease as `rejected` before requesting another credential, and
`save_credentials` settles the current lease as `accepted`. These are the
libsvn authentication iterator signals; SubversionR must not infer acceptance
from a translated top-level error or stderr. A later authz, path-not-found,
conflict, or out-of-date error does not turn an already accepted credential into
a rejected one. If the selected RA/auth path does not invoke the custom
provider's `save_credentials`, the lease remains `unused`; top-level success is
not a substitute signal. A feasibility gate must prove `save_credentials`
behavior for every claimed RA/auth cell. The provider baton maps the exact
credential object to its opaque `leaseId`; it does not settle by realm alone.
`save_credentials` sets libsvn's `saved` result and settlement is idempotent by
`leaseId`, so repeated cache/challenge signals cannot emit a second settlement.
Provider/operation teardown settles an unconsumed lease as
`unused`, `cancelled`, or `timedOut`; a daemon/extension disconnect discards all
unsettled leases.

Within one operation, use of a stored credential may be followed by at most one
foreground prompt for the same authority. There is no automatic rerun of the
top-level SVN operation after it returns. The evidence suite covers stale
password, password rotation, cancel-then-retry, simultaneous same-realm
operations, and independent different-realm operations.

### 7.3 Proxy and tunnel-secret leases

Proxy Basic does not use the server-password realm key. Its storage identity is
`proxy endpoint + basic + normalized fixed username`. A
`proxyCredentials/request` creates a pending opaque lease before worker launch;
the worker receives only that ephemeral value. ra_serf must expose a controlled
signal that the proxy advanced beyond its 407 challenge before the parent may
settle `accepted`. A repeated 407 settles `rejected`; termination before a
conclusive signal settles `unused`, `cancelled`, or `timedOut`. I10 remains
disabled and does not advertise `remoteHttpsBasicProxy` until its feasibility
probe proves that signal and direct-bypass rejection.

OpenSSH password and private-key passphrase secrets have no libsvn realm and
never use `credentials/request`. `sshSecret/request` keys password by
`adapter + host + port + normalized SSH username + password`, and a passphrase
by `adapter + host + port + exact public-key fingerprint + keyPassphrase`.
Each returns an operation- and secret-kind-bound lease. It settles `accepted`
only after the controlled tunnel reaches the SVN protocol greeting, which proves
SSH authentication completed; authentication rejection settles `rejected`, and
earlier termination settles conservatively. Agent mode creates no secret lease.
The askpass capability is rejected and unadvertised until I12 proves this signal
and exact-once settlement.

### 7.4 TLS and SSH trust are different contracts

TLS server trust continues through `certificate/request`, keyed by endpoint,
realm, exact SHA-256 DER fingerprint, and failure bits. The response returns a
`trustLeaseId`; reject, trust-once, and trust-permanent are intents rather than
immediate persistent writes. The controller keeps a pending permanent decision
in memory. An instrumented ra_serf path settles `accepted` only after the TLS
handshake and initial SVN protocol exchange complete for the exact endpoint;
otherwise it settles `unused`, `rejected`, `cancelled`, or `timedOut`. Only
accepted trust-permanent writes SecretStorage. A changed fingerprint never
consumes the old decision. The HTTPS TLS slice must replace the current
prompt-time store and prove this signal before advertising
`certificateTrustLeaseSettlement`.

SSH adds `sshHostKey/request`; it must not reuse the X.509 contract. The request
contains adapter, host, port, algorithm, SHA-256 fingerprint, state
(`unknown` or `changed`), interaction mode, and remaining budget. The response
is reject, trust once, or pin. A changed key cannot be accepted by a generic
`yes`; the UI must show the old and new fingerprints and require an explicit
replacement action.

Client certificate selection is also separate (`clientCertificate/request`)
and remains disabled until its later evidence slice. A private-key passphrase
may use the credential broker only after a non-secret certificate identity has
been selected.

## 8. Transport policies

### 8.1 HTTP and HTTPS

- Anonymous HTTP(S) selects no auth provider that can reveal a stored secret.
- `basic` selects Basic only. Digest, Negotiate, and NTLM are not silently
  enabled because they are compiled into Serf.
- Credentialed cleartext HTTP is rejected unless a future authority-scoped
  profile mode and evidence explicitly permit it. Anonymous HTTP remains a
  separate test cell.
- HTTPS uses the selected trust chain and the broker only for remaining failure
  bits. Trust decisions never disable hostname or expiry checks globally.
- Manual proxy selection is explicit. Origin and proxy credentials have
  different authority keys and failure states. Environment/system proxy, PAC,
  and browser proxy discovery are outside Tier 1.
- Redirects are initially rejected. Same-endpoint redirects may be enabled by a
  later HTTPS slice only after evidence proves scheme, canonical host, and port
  are checked before credential forwarding. Cross-authority and HTTPS-to-HTTP
  redirects always fail.
- `windowsIntegrated` explicitly restricts `http-auth-types` to the reviewed
  integrated modes and records that identity comes from the worker process
  token. It remains disabled until a private domain-lab gate distinguishes
  Kerberos, NTLM, DNS/SPN failure, and unintended identity use.

### 8.2 Direct `svn://`

- `anonymous` permits only the internal anonymous route.
- `cramMd5` permits the internal CRAM-MD5 username/password route through the
  broker.
- A server that offers only SASL produces an exact unsupported-mechanism state.
  The client does not add Cyrus SASL or retry another transport.
- The controlled matrix includes authz denial, wrong/stale password, blackhole
  connect, stalled mid-read, cancellation, realm changes, and repository
  externals disabled.

### 8.3 `svn+ssh` with Windows OpenSSH

The profile requires absolute canonical `ssh.exe`, `ssh-keyscan.exe`, and
`ssh-keygen.exe` paths from one verified OpenSSH installation, one explicit host
key algorithm, and one auth mode: `agent`, `identityFile`, or `askpass`. PATH
lookup, Windows optional-capability installation, `~/.ssh/config`, an arbitrary
`SSH_AUTH_SOCK`, and `SVN_SSH` are not implicit inputs. Agent mode explicitly
permits the Windows OpenSSH agent service; identity-file mode names one absolute
user-selected key; askpass mode uses a private broker shim owned by the
operation.

The custom RA opener owns every accepted tunnel name and returns an exact
unsupported-tunnel error for all others. It never declines into libsvn's default
opener. The first OpenSSH claim requires an already pinned exact public key in
the profile-owned known-hosts file. A separate enrollment slice may run the
configured `ssh-keyscan.exe` for one selected algorithm inside the same deadline
and Job, validate its known-hosts output, and compute the SHA-256 fingerprint in
SubversionR (or cross-check it with the configured `ssh-keygen.exe`). Keyscan
does not authenticate the result, so that slice requires out-of-band fingerprint
verification before writing the key. A changed scan result becomes a structured
`changed` request; it is never accepted from SSH stderr or askpass text. Until
the enrollment feasibility gate passes, unknown or changed keys are typed
failures and no `sshHostKeyChallenge` capability is advertised.

The tunnel then creates SSH with a structured argv, `-F NUL`, the isolated
`UserKnownHostsFile`, no global known-hosts file, `StrictHostKeyChecking=yes`,
`CheckHostIP=no`, `UpdateHostKeys=no`, and one exact `HostKeyAlgorithms` value
matching `ssh-keyscan -t`. It disables connection sharing, bounds stderr, and
reserves stdin/stdout exclusively for the SVN tunnel. Host, port, username, and
remote `svnserve -t` arguments are validated fields, never a shell fragment.

Authentication argv is mode-specific. Password mode selects only `password`,
disables public-key and keyboard-interactive auth, permits one password prompt,
and forces a one-shot askpass shim. Identity-file mode selects only `publickey`,
sets `IdentitiesOnly=yes`, and passes one exact absolute key path; an encrypted
key uses a distinct key-passphrase shim. Agent mode selects public-key auth and
never injects askpass. Every shim is created for one operation and one secret
kind, ignores localized prompt text, returns only its pre-bound secret over the
private channel, and cannot handle host-key decisions.

The OpenSSH version/path hash, profile hash, host-key fingerprint, auth mode,
exit class, and residue result enter evidence. Password/passphrase prompts use
the broker only for a foreground operation. Background mode uses non-interactive
SSH behavior and fails on missing agent/key or unknown host.

Future host-key `trust once` writes only an operation-scoped temporary
known-hosts file. `pin` and explicit changed-key replacement are the only paths
that atomically replace the persistent profile-owned file.

### 8.4 Plink/Pageant and standard SVN cache

Plink/Pageant needs its own argv, saved-session prohibition/selection policy,
`-hostkey` behavior, prompt broker, process evidence, and provenance checks. It
does not ship as an OpenSSH compatibility path. Standard SVN/Wincrypt auth cache
similarly needs its own persistence owner, read/write/invalidation rules, UI,
and evidence. Both are explicit post-Tier-1 slices and remain rejected until
then.

## 9. Connection state and user experience

The extension keeps local working-copy projection separately from a per-repo
remote connection state:

```text
unchecked
checking(operationId, startedAt)
online(transport, checkedAt)
attention(authRequired | certificateRequired | hostKeyRequired |
          configurationInvalid | unsupportedCapability)
unreachable(dns | refused | proxy | timeout | tunnel)
indeterminate(cancelledAfterMutation | workerTerminated)
```

`online` means the last explicit remote operation reached and authenticated to
the configured authority; it is not a permanent connection. Failure preserves
the last successful Incoming projection but marks it stale. It never clears
local Changes. A remote mutation failure or hard termination enters
`indeterminate`, schedules a separately bounded full recovery reconcile, blocks
another mutation until recovery reaches a safe completed state, and may
offer Cleanup only when libsvn reports that cleanup is appropriate. SubversionR
does not auto-clean or claim rollback of a partially applied SVN operation.
`remoteRecoveryBlocked` is terminal for reporting but never releases the native
lane.

Foreground commands may show one localized, attributed prompt or recovery
notification and expose Retry, Configure Remote Access, Review Certificate,
Review Host Key, or Show Log as appropriate. Background failures update state
and diagnostics without modal UI. User cancellation is a visible settled state,
not an error loop.

All user text remains in the TypeScript localization bundles for English,
Japanese, and Chinese. Rust/native layers return stable keys and safe enum/hash
arguments. Diagnostics add no raw realm, credential-bearing URL, username,
password, passphrase, proxy secret, private-key contents, or unbounded SSH
stderr.

The remote failure taxonomy extends the current cause enum with at least:

- `networkDns`, `networkRefused`, `networkTimeout`;
- `proxyAuthenticationRequired`, `proxyUnreachable`;
- `tlsUntrusted`, `tlsChanged`, `tlsProtocol`;
- `authenticationRequired`, `authorizationDenied`;
- `sshHostKeyRequired`, `sshHostKeyChanged`, `sshTunnelFailed`;
- `operationCancelled`, `operationDeadlineExceeded`, `redirectRejected`,
  `crossAuthorityRejected`, `credentialRejected`;
- `sshExecutableInvalid`, `sshProvenanceInvalid`, `sshTunnelCleanupFailed`,
  `workerContainmentFailed`, `remoteRecoveryBlocked`;
- `remoteConfigurationInvalid`, `remoteCapabilityUnsupported`;
- `remoteOperationIndeterminate`.

Mapping is based on the native symbolic error chain and owned process outcomes,
not localized stderr substring matching. Unknown errors remain bounded and
redacted.

## 10. Evidence and claim gates

### 10.1 Tier-1 controlled matrix

| Cell | Required controlled evidence |
| --- | --- |
| `svn://` anonymous | source-built `svnserve`; checkout/open, remote status, content, history/blame, update, commit, copy/switch, lock/unlock; authz and deadline negatives |
| `svn://` CRAM-MD5 | the same operation groups; correct/stale/wrong/cancelled credentials, multiple accounts, realm changes, single-flight, no cache/config ambient route |
| HTTPS Basic | source-built Apache/mod_dav_svn; the same applicable operation groups; system/explicit CA, reject/once/permanent/change, redirect and authz negatives |
| HTTPS through Basic proxy | controlled forward proxy; CONNECT, 407, wrong/cancelled credential, bypass rejection, origin/proxy separation, timeout and redaction |
| `svn+ssh` OpenSSH | pinned Windows client and controlled server; key/agent/askpass modes selected by their slice, unknown/changed host key, timeout/cancel/crash, 100-cycle local and server residue check |

For each row, evidence records the packaged client and native artifact hashes,
RA/build capability manifest, server/proxy/SSH versions and config hashes,
profile hash, operation, interaction mode, prompt count, settlement, deadline,
process cleanup, reconcile result, stable error class, and redaction assertion.
Fixture startup or a source skeleton is not a completed row.

### 10.2 Claim boundaries

The current claim matrix remains unchanged throughout the design and foundation
slices. A transport row flips only after all native, worker, daemon, protocol,
VS Code UI, error/localization, installed-product, reconcile, negative, and
evidence-contract gates for its exact claim cells pass.

The first eligible `0.3.0` wording is bounded to Windows `win32-x64` remote
repositories over direct `svn://` anonymous/CRAM-MD5, HTTPS Basic with explicit
TLS/proxy policy, and explicitly configured Windows OpenSSH `svn+ssh`. It does
not imply Digest, IWA/Kerberos/NTLM, SASL, client certificates, Plink/Pageant,
standard SVN credential cache, mixed-transport externals, public-host uptime,
cross-platform packages, or default remote polling.

SourceForge, ASF, Assembla, VisualSVN, or another vendor can add a named manual
compatibility observation only after terms/permission and rate limits are
recorded. Passing such an observation never broadens the controlled claim.

## 11. Required feasibility gates

These questions must be answered by source probes or controlled executable
fixtures before the dependent product slice starts. A negative result changes
the design or removes the claim cell; it does not trigger a fallback path.

1. **Auth settlement.** Instrument custom provider `first_credentials`,
   `next_credentials`, and `save_credentials` callbacks for ra_svn CRAM-MD5 and
   ra_serf Basic. Prove how accepted credentials settle when the final operation
   result is success, authz denial, missing path, or conflict. Any path without a
   reliable `save_credentials` signal remains non-persistent.
2. **Proxy settlement.** Prove the ra_serf signal that distinguishes accepted
   Basic proxy authentication from repeated 407, origin auth, later origin
   failure, and bypass. Confirm the proxy storage identity needs no libsvn realm.
3. **TLS trust settlement.** Prove the exact ra_serf point that establishes the
   selected certificate was accepted for the endpoint and protocol exchange,
   including later authz/path failure and handshake termination. Without it,
   permanent trust remains disabled and pending decisions are never stored.
4. **Authority attribution.** Prove the native interception points for HTTP
   redirects and every multi-URL operation. Until a point can reject before
   credential forwarding or network contact, redirects and operations not
   statically confined to one endpoint stay disabled.
5. **Worker containment and IPC.** On the supported Windows host, GitHub Actions,
   and an Extension Host launched inside a parent Job, prove suspended creation,
   nested Job assignment, handle allowlisting, duplex broker traffic under
   backpressure, Job close, descendant cleanup, and a subsequent parent request.
6. **Trust ordering.** Prove acknowledged trust-epoch updates cannot race a
   queued operation into worker/network launch after trust revocation.
7. **OpenSSH provenance, host keys, and secret settlement.** Lock the supported
   Windows OpenSSH
   source/version, executable relationship checks, known-hosts grammar, keyscan
   validation, out-of-band fingerprint UX, and local plus server-side residue
   oracle. Prove that an SVN protocol greeting is a reliable post-authentication
   signal for password/passphrase settlement. The first product slice uses only
   a pre-pinned key and non-interactive key/agent auth; enrollment and askpass
   remain later gates.

## 12. Implementation slices

Each slice is one branch and PR. A product-capability slice closes protocol,
native, worker/daemon, TypeScript UI, stable errors, localization, tests,
reconcile, and claim/evidence wording together as required by `AGENTS.md`.

1. **I1 — feasibility probes.** Close the seven gates above with locked source
   citations and controlled probe evidence. Record any resulting design delta;
   no product capability or support claim changes.
2. **I2 — envelope and trusted config foundation.** Add trust-epoch ordering,
   typed profile/envelope validation, granular capabilities, an allowlisted
   in-memory libsvn config, removal of the two unused future SVN config/tunnel
   settings, remote ambient username-provider exclusion, and poison-config
   sentinels. No remote claim changes.
3. **I3 — disposable worker and deadline recovery.** Add versioned private duplex
   IPC, one-operation workers, suspended Job containment, absolute deadline,
   cancellation/hard termination, separate bounded recovery, and subsequent
   request evidence. No transport claim changes.
4. **I4 — server credential v2 and leases.** Perform the explicit v1 clear
   cutover; add fixed/foreground account selection, endpoint/realm/auth/account
   keys, custom provider leases and exact-once settlement, same-realm
   single-flight, and localized clear/chooser flows. No transport claim changes.
5. **I5 — connection and recovery state.** Add the per-repository remote state
   machine, typed errors, English/Japanese/Chinese status/recovery UI, hard-stop
   residue blocking, separately bounded reconcile, stale Incoming behavior, and
   local-event zero-network evidence. No transport claim changes.
6. **I6 — direct `svn://` anonymous.** Close every claimed anonymous operation
   group, authz/deadline negatives, installed-product flows, reconciliation, and
   exact anonymous claim cells.
7. **I7 — direct `svn://` CRAM-MD5.** Close credential rotation, multiple
   accounts, realm changes, provider iteration, installed-product negatives,
   reconciliation, and exact CRAM-MD5 claim cells.
8. **I8 — HTTPS anonymous and TLS trust.** Move ra_serf into workers; replace
   prompt-time permanent storage with trust leases; close anonymous HTTPS,
   system/explicit CA, certificate reject/once/permanent/change, strict initial
   redirect rejection, installed UI, and exact claim cells.
9. **I9 — HTTPS Basic.** Add Basic-only origin credentials and close provider
   settlement, authz, same-endpoint redirect only if its feasibility proof
   passed, installed negatives, and exact Basic claim cells.
10. **I10 — explicit Basic proxy.** Add proxy authority/profile fields, proxy
    leases and proved settlement, ephemeral in-memory proxy config, 407/CONNECT,
    origin/proxy separation, bypass rejection, timeout/redaction evidence, and
    exact proxy claim cells.
11. **I11 — OpenSSH pre-pinned key.** Add the strict custom opener, verified
    executable set, product-owned pre-pinned known-hosts file, non-interactive
    identity-file/agent modes, Job-contained pipes/stderr, poison-default-tunnel
    gate, installed UI, and 100-cycle local/server residue evidence.
12. **I12 — OpenSSH interaction.** Only after the host-key and secret-settlement
    feasibility gates, add explicit scan/out-of-band enrollment and replacement;
    add exact-once password or key-passphrase leases through the proven private
    askpass channel. Unsupported submodes remain rejected and unadvertised.
13. **I13 — `0.3.0` seal.** Run the complete packaged Tier-1 matrix, installed
    VSIX evidence, exact claim/readiness flips, candidate/release attestation,
    and Marketplace pre-release chain for `0.3.0`.

Later independent issues may add client certificates, Digest, IWA private-lab
evidence, Plink/Pageant, an explicit standard SVN cache mode, SASL build
variants, externals, or permission-reviewed hosted canaries. None is hidden
inside I1-I13 as an alternate path.

## 13. Review checklist

The D1 design is ready to merge only if review can answer yes to all of these:

- Does every remote operation have one owner, one immutable profile, one
  monotonic deadline, and one settlement path?
- Can a stalled network or tunnel be terminated without killing the parent
  daemon or leaking a local/remote child process?
- Is every ambient config, cache, tunnel, executable, identity, and proxy route
  either explicitly selected or unreachable?
- Are server, proxy, TLS, SSH host-key, and client-certificate challenges kept
  distinct?
- Can multiple accounts and same-realm concurrent operations behave without
  credential or prompt cross-talk?
- Do local operations and dirty-path refresh remain network-free?
- Does cancellation preserve truthful working-copy and Incoming state rather
  than claiming rollback?
- Does each planned claim cell have a controlled falsifiable gate and an exact
  non-claim boundary?
- Are future modes rejected rather than accepted through placeholders,
  fallback, aliases, or undocumented defaults?

# M8 I6 direct `svn://` anonymous evidence contract

This gate is the first transport-capability gate in M8. It is eligible to support
only the exact **Windows `win32-x64`, direct `svn://`, anonymous** claim. It does
not establish CRAM-MD5, SASL, SSH, HTTP(S), proxy, externals, or cross-platform
support.

`docs/release/m8-i6-svn-anonymous-evidence.v1.schema.json` defines the strict
machine-readable shape, and the report binds its exact SHA-256.
`scripts/release/verify-m8-i6-svn-anonymous-evidence.ps1` is the executable
semantic contract. The verifier accepts one evidence JSON document and the exact VSIX,
daemon, bridge, Subversion stage manifest and fixture tools, probe driver,
reviewed ra_svn origin patch and contract, native source lock, fixture
configuration, fixture authz, and svnserve command-log files. Every input is mandatory and absolute;
missing inputs, extra JSON fields, a hash mismatch, a partial matrix, or a
provisional verdict fails the gate. There is no historical-schema alias,
inferred version, skipped cell, or compatibility fallback.

## Authority and fixture boundary

The positive fixture is a loopback-only, source-built Apache Subversion 1.14.5
`svnserve` with SASL disabled and explicit anonymous authz. Source-built
`svnadmin` and `svn` may create and mutate fixture repositories as test oracles.
The packaged daemon and installed VSIX operation surfaces must record zero SVN
CLI invocations; product behavior continues to use the packaged Rust sidecar,
bridge, and libsvn.

The evidence binds the exact bytes of:

- the installed VSIX;
- the packaged daemon and native bridge;
- `subversionr-stage-manifest.json`;
- `native/sources.lock.json`;
- the reviewed Apache Subversion 1.14.5 ra_svn origin patch and its adjacent
  contract;
- the source-controlled I6 probe driver;
- the packaged-native and installed-VSIX negative probes, the dedicated
  packaged-native and installed-VSIX authz-denied and recovery-indeterminate
  probes, the dedicated packaged-native and installed-VSIX worker-crash probes,
  the dedicated packaged-native and installed-VSIX blackhole-connect and
  daemon-disconnect probes, the no-accept conditional-listener fixture,
  controlled ra_svn fault fixture, and installed-VSIX 100+1 stress probe;
- the exact source-built `svn.exe`, `svnadmin.exe`, and `svnserve.exe`; and
- the positive fixture `svnserve.conf` and restored `authz` files; and
- the exact svnserve command log used to measure authz-denied command-stage
  attempts and connections.

The report contains no raw repository URL, working-copy path, username, realm,
credential, log message, source content, or unbounded diagnostic. Repository and
profile identities used by a driver are ephemeral and may be retained only as
bounded hashes.

## Probe-driver boundary

`scripts/release/run-m8-i6-svn-anonymous-evidence.ps1` imports the
source-controlled Native module and requires
`Assert-SubversionStageForBridge` to validate the stage against
`native/sources.lock.json`, architecture `x64`, configuration `Release`, all
required headers/libraries/runtime files, the exact dependency manifest, and
forbidden dynamic-Serf artifacts. It then creates the positive
repository, starts the source-built loopback `svnserve`, and then invokes one
mandatory PowerShell probe driver. `ProbeDriverPath` must be exactly
`scripts/release/probe-m8-i6-svn-anonymous.ps1`; an arbitrary external driver is
rejected even if it emits schema-valid JSON. The driver receives the repository URL,
fixture root, fixture config/authz/log files, two separately prepared denied
working copies, exact source-built fixture-tool paths,
candidate VSIX/daemon/bridge paths, Code CLI path, stage-manifest path, ra_svn
patch/contract paths, native source-lock path, expected product version, and
output path. It owns the packaged and
installed product actions and the additional malicious-root, SASL-only, authz,
blackhole-connect, stalled-mid-read, deadline, cancellation, worker-crash,
daemon-disconnect, trust-revoke, recovery, unrelated-repository, local-event,
redaction, and stress fixture controls.

The generated fixture root must remain under `target/i6-evidence` and may be at
most 110 characters after absolute-path resolution. This reviewed Windows path
budget is enforced before fixture creation so nested VS Code profiles and
Extension Host IPC paths cannot silently cross the legacy path limit.
Every separately installed VS Code child fixture is subject to the same
110-character absolute-root budget. The installed positive/compatibility block
uses a per-run short root below `target/i6p`; it must fail before launch if that
root escapes `target` or exceeds the budget. A successful block removes its
short root. A failed block retains its isolated VS Code logs and the bounded
child stdout/stderr locally under that root for diagnosis; those failure files
are not evidence inputs and cannot appear in a passing aggregate.
Every installed launcher is bound to its exact returned or started PID. Before
the driver accepts that launcher and before any successful short-root cleanup,
the subscribed start-event ancestry from that probe through every VS Code,
Extension Host, daemon, worker, and utility descendant must remain at zero live
identities for the complete settlement window. PID reuse is distinguished by
creation time. A business or lifecycle failure retains the affected short root;
the same process-tree settlement runs after any post-start failure, including
pre-completion barriers, completion, and live-capture handshakes, while
preserving that primary error. Process snapshots use the
remaining monotonic deadline as their operation timeout, so an unresponsive WMI
query cannot turn settlement into an unbounded wait. The driver fails at the
deadline with a bounded live-identity summary, and it neither retries deletion
nor ignores a locked fixture file.

The report binds the exact bytes of the main driver and every source-controlled
helper it executes: the I6 packaged-native positive/negative probes, the
controlled ra_svn fault fixture, the I6 installed-VSIX probe,
the packaged-native compatibility probe, and the installed Extension Host
harness. The verifier resolves those helpers only from their reviewed repository
paths and rejects any hash drift, so changing any executable probe invalidates
previous evidence.

There is deliberately no bundled synthetic driver. Until a driver executes the
real candidate product and emits the complete hash-bound report, the runner
fails on a missing `ProbeDriverPath` or on verifier rejection. Source-built
`svn`/`svnadmin` observations may seed or inspect fixtures only and cannot be
copied into either product surface's operation results.

## Required anonymous operation matrix

Both `packaged-native` and `installed-vsix-extension-host` surfaces must execute
these nine positive cells in this exact order:

1. checkout/open;
2. remote status;
3. repository content;
4. log history;
5. blame history;
6. update;
7. commit;
8. repository copy for branch/tag creation; and
9. switch.

Every cell proves anonymous access with zero prompts and no credential
settlement, a fresh reconcile result, and redacted diagnostics. The
`packaged-native` probe additionally records the directly observed count of
remaining operation temporary roots and requires it to be zero. The installed
extension-host report does not expose worker-process or operation-temporary-root
state, so it must not synthesize either observation.
Fixture startup or a direct bridge/unit probe does not satisfy the installed
surface.

Each surface then submits two additional, unique remote requests for lock and
unlock. They are not positive anonymous operations. Apache Subversion's RA API
states that both [`svn_ra_lock`](https://subversion.apache.org/docs/api/latest/svn__ra_8h.html)
and `svn_ra_unlock` are never anonymous and require the server to obtain a
username. The controlled PASS result is therefore the exact outer product code
`SVN_OPERATION_LOCK_FAILED` or `SVN_OPERATION_UNLOCK_FAILED`, preserved bounded
libsvn symbolic causes, diagnostics cause `authenticationFailed`, and
`authentication` / `authenticationRequired` remote settlement. Both operations
must set the explicit `anonymousIdentityRequired` marker, prove
`mayHaveMutated: false`, and preserve at least one exact upstream identity cause
in the unique symbolic cause names. The controlled server produces
`SVN_ERR_RA_NOT_AUTHORIZED` for lock and `SVN_ERR_FS_NO_USER` for break-unlock;
these are the only accepted qualifying identity causes. Both cells produce no
prompt or credential settlement. Immediately
after each expected failure, the same product surface must issue a fresh
`status/refresh` for the same repository and epoch; only that successful fresh
reconcile proves `nativeLaneReleased`. The `packaged-native` probe additionally
requires the directly observed operation-temporary-root count to be zero. The
installed report omits unobservable worker and temporary-root fields rather than
hard-coding them. No ambient OS username, cached username, retry, or alternate
profile may be introduced.
The report's `allOperationCellsPassed` verdict means both that all nine positive
cells succeeded and that both identity-required boundary cells produced their
exact expected failures; it never means eleven anonymous successes.

## Required negative and recovery matrix

The report must contain all of the following controlled cells in exact order:

- malicious repository-root response rejected as
  `SUBVERSIONR_REMOTE_ORIGIN_MISMATCH` / `crossAuthorityRejected`, with zero
  follow-up contact to the supplied authority;
- SASL-only server rejected as `SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED` /
  `remoteCapabilityUnsupported`, without credential prompting;
- controlled remote-status authz denial classified as
  `SVN_REMOTE_STATUS_AUTH_FAILED` / `authorizationDenied`; each surface uses a
  distinct working copy prepared while root access is writable, then runs the
  real remote-status path after an atomic authz switch. The source-built
  svnserve log must append exactly one repository-open line and one authorization
  denial line for that surface, proving one attempt, one connection, and
  command-stage progress. The driver restores the exact root-write authz bytes
  in `finally` and proves the restored fixture before positive or stress work;
- a blackhole connect that reaches its owned absolute deadline and leaves zero
  worker/process/temp-root residue;
- a server that accepts a connection and stalls mid-read, independently proving
  the same deadline and cleanup properties after network progress;
- absolute deadline and explicit cancellation terminated through their owned
  worker outcomes. Cancellation is triggered only after the controlled
  greeting barrier, preserves the caller's immediate
  `JSON_RPC_REQUEST_CANCELLED` result, and separately observes the daemon's
  exact `SUBVERSIONR_REMOTE_WORKER_CANCELLED` / `operationCancelled` response
  for the same request ID before proving the native lane reusable;
- worker crash contained with zero residue;
- daemon/client disconnect supervised as
  `SUBVERSIONR_REMOTE_WORKER_DISCONNECTED` / `workerContainmentFailed`, with no
  surviving operation worker;
- trust revocation rejected before any subsequent network contact;
  this cell uses the reviewed defensive and testable
  `workspaceTrust/update { trusted: false, trustEpoch: N + 1 }` production path,
  then submits an envelope captured at epoch N and requires the daemon's exact
  stale-epoch rejection. VS Code exposes no live revocation event, so this cell
  does not claim to replace the primary Extension Host stop/restart boundary;
- recovery Safe settlement that releases only after fresh reconcile;
- recovery Indeterminate settlement that records
  `SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE` / `remoteOperationIndeterminate`;
- recovery Blocked settlement, including restart after an armed checkout target,
  whose controlled origin is `SUBVERSIONR_REMOTE_WORKER_TIMED_OUT` /
  `operationDeadlineExceeded`, whose product settlement is
  `SUBVERSIONR_REMOTE_RECOVERY_BLOCKED` / `remoteRecoveryBlocked`, and which
  clears only through the exact explicit disposition confirmation contract;
- unrelated-repository serviceability while the original checkout-target lane
  remains blocked: each surface checks out a second source-built repository
  with a distinct UUID through one transparent counting-proxy connection, while
  the original blocked entry and its durable journal bytes remain unchanged;
- local filesystem events causing zero remote network attempts; and
- bounded redaction with no forbidden token disclosure.

Every controlled failure and recovery cell carries separate, ordered
`packaged-native` and `installed-vsix-extension-host` observations. The cell's
top-level `stableCode` and `reason` define the controlled origin. Each surface
observation separately records that exact origin as `originCode` /
`originReason` and the product's exact post-cleanup result as `settlementCode` /
`settlementReason`. All four fields are mandatory and use controlled pairs; the
verifier never infers one pair from the other. Ordinary cells record equal
origin and settlement pairs, while the Blocked recovery cell proves the real
timeout-origin/recovery-blocked-settlement transition. Each observation also
records the furthest controlled network progress, the measured network-attempt
and successful-connection counts, zero product-side fixture CLI use, zero credential activity, zero
forbidden follow-up contacts, zero worker descendants and operation temporary
roots, and redacted diagnostics. These values must be measured on the real
surface; a shared aggregate constant is not evidence.

The worker-crash cell additionally records the live bound daemon/worker tree's
descendant count at the greeting barrier. Windows may attach `conhost.exe` to a
console-subsystem daemon or its contained worker even when no visible console
is created, so this running baseline is measured rather than required to be
zero. The retained PID, creation-time, image-path, and ancestry binding must
still settle to zero descendants after the probe closes; only that measured
post-settlement zero is the residue invariant.

Zero-worker process observations apply the same Windows console-host boundary
without weakening the worker gate: the candidate executable may start no
second daemon process, while its OS baseline may contain at most one direct
`conhost.exe` start bound by PID, start time, and ancestry. Any other descendant,
a second console host, or a retained daemon/console-host identity fails the
observation. The daemon and console host are captured while live and bound to
their exact Windows file identities and one session; a basename alone is not
accepted. For an installed surface, the daemon identity is resolved from the
exact extension path reported by that surface, constrained to its isolated
extensions root, and its bytes must match the hash-locked candidate before the
captured process identity is compared. The build-tree source file identity is
not interchangeable with the installed copy's identity. A later reuse of
either PID is not settlement residue.

Installed zero-worker probes use a mandatory, nonce-bound ready/ack barrier.
After the installed extension has started its daemon, the Extension Host
atomically publishes its exact installed extension identity and remains alive
until the elevated driver acknowledges the capture. Before that acknowledgement
the driver must retain a Windows process handle for the single exact-path daemon
generation, match its PID, parent, creation FILETIME, session, full image path,
argument-free command line read through that handle, installed file identity,
and exact live descendant count, bracketed by retained-handle liveness checks.
Once the driver observes the atomically published ready file, acknowledgement
has a 20-second bound. The ready-file wait and pre-acknowledgement phase contain
no synchronous CIM query or process-start event drain. This acknowledgement is a daemon
identity/liveness barrier; asynchronous WMI delivery cannot delay product work.
The driver keeps the retained daemon handle until exit, then binds its subscribed
start event to the captured `(PID, creation FILETIME, exit FILETIME, parent,
session, path, file identity)` lifetime. The optional Windows console host is
instead an asynchronous start-event identity: when its WMI start metadata is
received, the driver opens that exact live PID and captures its path, system file
identity, creation time, and session through native process APIs. A missing live
capture or any other daemon descendant fails the final observation. The
local-event probe cannot mutate its working copy before the acknowledgement, and
the installed trust-revoked probe cannot let its Extension Host exit before it.
A missing, stale, malformed, duplicate, timed-out, or mismatched handshake or
post-ACK event join fails the cell; there is no post-exit PID lookup, synchronous
CIM enrichment, or event-only daemon identity fallback.

All subscribed process-tree observations bind an exact start-event identity,
not a numeric PID for the whole subscription. The controlled probe root must
match its recorded PID, still-live driver parent, and expected executable name;
every descendant root is the unique `(PID, start-event time)` selected from that
tree. Its ancestry lifetime ends at the next recorded start of the same PID.
A later unrelated PID reuse, and children of that later lifetime, are therefore
outside the original product tree. Settlement still compares the live CIM
creation time with the selected start-event boundary and fails if the original
generation or any bound descendant remains alive. Missing or duplicate exact
start identities fail the observation.
Multi-phase recovery observations bind each daemon-to-worker edge to the exact
parent lifetime. Parent and child cannot share one live PID, while sequential
workers or a restarted daemon may reuse a PID after the earlier lifetime ends.

The Safe cell's controlled `none` / `none` origin and settlement fields describe
the successful recovery RPC recorded by the matrix. They do not claim that the
mutation which required recovery succeeded. Each Safe product probe separately
retains and validates the prerequisite mutation's exact
`SUBVERSIONR_REMOTE_WORKER_TIMED_OUT` / `operationDeadlineExceeded` result, the
`pending` recovery transition bound to that origin operation, and the distinct
recovery operation ID. The fixture must reach the command barrier exactly once;
the fresh local reconcile, lane release, and subsequent local request must not
produce another network contact. Consistent with #135, Safe does not claim
automatic SVN Cleanup, rollback, byte-identical working-copy metadata, or that
libsvn management locks were cleared. The working-copy database must remain
present and nonempty and user content must be preserved; stronger cleanup
claims require separate evidence.

The Indeterminate cell starts from an existing working copy and reaches the
dedicated `command-stall` barrier exactly once. Only after the in-flight worker
owns that command does the probe add an explicit DENY for the current Windows
identity on `.svn/wc.db` for `ReadData`, `ReadAttributes`, and
`ReadExtendedAttributes`. The probe fails fast unless that identity owns the
database. It proves a newly opened read is denied, retains the captured binary
security descriptor, and restores and verifies the exact binary DACL in
`finally`; it does not require administrator elevation. The origin envelope
uses a reviewed 5,000 ms deadline so the external command-barrier observer can
apply and verify the DACL before recovery begins. The packaged surface
invokes recovery explicitly, while the installed Extension Host exercises its
automatic recovery attempt. In both cases the recovery outcome is
`Indeterminate` and its raw failure remains `unknown` / `unknownRemote`; the
subsequent same-lane request is rejected with the exact stable
`SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE` /
`remoteOperationIndeterminate` recovery classification. The fixture records
exactly one attempt, one connection, and zero follow-up contacts. Each surface
also proves unchanged user content and a present, nonempty `.svn/wc.db` after
exact DACL restoration. As with Safe, libsvn may update working-copy metadata;
the cell does not claim byte-identical metadata. It leaves the native lane
blocked for explicit recovery and makes no automatic SVN Cleanup, rollback, or
libsvn management-lock-clearing claim.

The `localEventZeroNetwork` cell is installed-only because #135 requires the real
Extension Host watcher/dirty-path path and the packaged daemon has no filesystem
event surface. It requires both network-attempt and successful-connection counts
to remain zero. The installed harness arms a one-shot observer before changing
an existing versioned file, then requires the production VS Code filesystem
watcher callback, the exact `fileChanged` / `empty` dirty-path refresh with
`libsvn-local` coverage, and the corresponding SCM modified projection. The
observer has one absolute deadline. Because VS Code exposes no watcher-readiness
promise, the harness allows one bounded registration-stability window before its
single target write; that window is never treated as evidence and is not a retry.
Direct dirty-path injection, delay-only success, repeated writes, or polling
compensation is not evidence. The dedicated working copy is checked
out through a transparent loopback counting proxy to the source-built
`svnserve`. After checkout traffic has settled, the observation window requires
the proxy's accepted-connection, upstream-connection, client-byte, and
server-byte counters to remain unchanged and its active-connection count to
remain zero. The source-built `svnserve --log-file` must also remain unchanged,
but is only a high-level operation-log corroboration and is never substituted
for the proxy counters. The blackhole cell independently requires one measured
network attempt and zero successful connections.

Safe, Indeterminate, and Blocked recovery settlements are likewise recorded
separately for both product surfaces. Blocked checkout recovery binds the exact
target-path and origin-operation-ID SHA-256 values captured when the entry was
armed to the corresponding values used for explicit confirmation. The verifier
compares both pairs and rejects cross-entry confirmation. This does not claim
that the durable journal stores a repository URL or origin authority.

The separate stress record runs exactly 100 checkout cycles in one installed
VSIX Extension Host, reusing one target-path hash with a unique operation-ID
hash per cycle, one constant Extension Host session hash, and an explicit
no-fault mode. Every ordered cycle records the native `checkoutOpen` operation,
the real checkout revision, zero fixture CLI use, zero credential activity,
worker descendants,
temporary roots, fixture-server children, and durable checkout-journal entries.
On Windows, a source-built `svnserve` started in a console may own one baseline
`conhost.exe`; the probe binds that baseline by PID plus creation time before
VS Code starts and reports only additional descendants as fixture-server
children. Worker and descendant settlement likewise binds process identity by
PID plus start time, so a later Windows PID reuse is not reported as residue.
The verifier recomputes all maxima from those 100 observations, rejects missing,
duplicate, or reordered cycles, and requires an independent successful cycle
101 observation against the same target hash in the same Extension Host session.

## Current execution blocker

The source branch contains real candidate drivers for the packaged-native and
installed Extension Host positive operation matrix, malicious-root, SASL-only,
authz-denied, stalled-mid-read, absolute-deadline, and installed local-event
zero-network cells.
The authz-denied cell additionally binds the exact svnserve command log and
requires atomic deny/restore controls. The stalled-mid-read cell reuses two
pre-existing working copies, replaces the exact original svnserve port with a
single-connection greeting-stall fixture for each product surface, and requires
the original timeout plus a same-session local snapshot proving the native lane
was released. The local-event cell binds a transparent byte-counting proxy and
a real VS Code watcher observer. All drivers keep the evidence report absent
when any candidate observation fails.

This contract intentionally remains fail-closed. The source branch now contains
the installed 100+1 stress probe and real packaged/installed `maliciousRoot`,
`saslOnly`, `greetingStall`, `connectedStall`, `authzDenied`,
`stalledMidRead`, `deadline`, `cancellation`, `trustRevoked`,
`recoverySafe`, `recoveryIndeterminate`, `recoveryBlocked`,
`unrelatedRepository`, and `redaction` product probes. The
blocked-recovery probe uses a dedicated
`command-stall` server that completes greeting, anonymous authentication, and
repository-info exchange, then stalls after the first real RA command. While
that request remains pending, each surface captures the exact durable `armed`
entry before observing the timeout-origin/recovery-blocked settlement.
Before confirming that blocked entry, the same restarted product surface checks
out `/unrelated/trunk` from a separately created repository whose UUID is
independently checked by both the runner and the bound probe driver. A fresh
transparent counting proxy must observe exactly one accepted connection, one
upstream attempt, one upstream connection, nonzero bytes in both directions,
zero connection failures, and zero active connections at settlement. The
unrelated working copy must contain a nonempty `.svn/wc.db`; the recovery RPC
entry and the original checkout journal's raw bytes must remain identical across
that checkout.
The separate `deadline` probes use independent
operation IDs and a reviewed 500 ms envelope timeout, measure request settlement
with a monotonic clock, and require the owned timeout plus cleanup to settle no
later than the 5,000 ms cleanup slack before proving the same-session local lane
is available. The evidence schema requires those timing values only for the
`deadline` cell, so an existing stalled-mid-read observation cannot be
relabelled.

The reviewed `blackholeConnect` cell starts a loopback-only Winsock listener
with `SO_CONDITIONAL_ACCEPT` enabled and read back before `listen`; neither the
fixture nor the aggregate calls `accept` or `WSAAccept`. A mandatory provider
preflight and each product observation show one stable owner-PID `SYN_SENT` row
through `GetExtendedTcpTable(TCP_TABLE_OWNER_PID_ALL)`. The product observation
locks its loopback local address and ephemeral port together with the remote
address and port. A background owner-table observer publishes an initial sample
barrier before the product probe launches, then samples the fixture port across
every owner PID without pausing for process discovery or identity binding and
continues through probe exit and TCP cleanup. The evidence carries the actual stable `SYN_SENT`
span separately from the total observation duration. It requires at least three
samples spanning 25 ms, rejects a replacement worker identity, replacement TCB,
or any state other than `SYN_SENT`, and derives exactly one
network attempt and zero established connections from the complete observation;
no final row may remain. Both surfaces use the
exact 5,000 ms operation deadline, report
`SUBVERSIONR_REMOTE_WORKER_TIMED_OUT` / `operationDeadlineExceeded`, preserve
the working copy, release the native lane, retain no journal entry or temporary
root, and terminate all daemon candidates. The tamper-detecting fixture proves
zero accept invocations and accepted connections and reaches `stopped`. No
external address, firewall rule, backlog saturation, or alternate fixture is
permitted.

The reviewed `daemonDisconnect` cell runs an active request to the exact
greeting barrier, binds the unique daemon/worker process pair, and creates an
empty shutdown trigger from the aggregate observer. Production graceful
shutdown must expose the active request's
`SUBVERSIONR_REMOTE_WORKER_DISCONNECTED` / `workerContainmentFailed` settlement
and daemon `indeterminate` / `workerTerminated` state before acknowledging
shutdown. Recovery remains `notRequired`; the fixture receives no follow-up
contact, the working copy and empty journal are preserved, and no daemon
process, bound descendant, or temporary root remains.

The reviewed `workerCrash` cell runs
one real packaged-native probe and one real installed-VSIX Extension Host probe
against separate `greeting-stall` fixtures. The driver starts each probe with
redirected stdout/stderr and asynchronous drains, waits for exactly one accepted
connection and one greeting with no follow-up contact, and then binds the only
candidate daemon parent and its only direct worker child by the exact canonical
daemon executable path and process creation FILETIME. The binding uses
Toolhelp32 ancestry plus retained Windows process handles; it does not use WMI
process-start events or command-line guessing. Before injection the driver
rechecks the exact path, creation time, and parent/child relationship, then calls
`TerminateProcess` only for the bound worker with exit code `0x53565243`
(`1398166083`). It requires that exact exit code after worker settlement while
the retained daemon handle remains unsignaled.

Each worker-crash surface must report origin and settlement
`SUBVERSIONR_REMOTE_WORKER_CRASHED` / `workerContainmentFailed`, exact
`workerCrashSettlement` proof, and daemon state `indeterminate` /
`workerTerminated` with `recovery: notRequired` and
`cleanupAppropriate: false`. The same product lifetime must prove a fresh local
snapshot after the crash, native-lane release, an unchanged working copy,
redacted diagnostics, zero credential activity, zero follow-up contacts, zero
temporary roots, and zero surviving daemon/worker candidates. The fixture must
remain at exactly one connection and one greeting. Any missing candidate,
ambiguous ancestry, identity drift, unexpected exit code, daemon exit, extra
network contact, or cleanup residue fails closed.

The lock/unlock boundary is closed as nine positive anonymous operations plus two
exact authentication-required negative cells. The aggregate writes evidence
only after every real packaged-native and installed-VSIX observation passes;
the exact schema and candidate/helper artifact hashes are bound before the
report is public-claim eligible. Missing or synthetic observations may not be represented as
`verified`.

The two earlier checkout-stall probes establish only the installed surface's exact
timeout origin, recovery-blocked settlement, and one durable blocked entry bound
to the checkout target and origin operation. They do not satisfy the
`stalledMidRead` cell; that cell is established separately by a read-only
remote-status operation whose origin and settlement both remain timeout. The
dedicated packaged and installed `recoveryBlocked` probes close that separate
cell by capturing the armed entry before settlement, restarting the real product
surface, proving the same target remains blocked without another network
contact, confirming the reviewed target and origin through the exact
`reviewedAndResolved` contract, requiring journal clearance, and completing a
subsequent checkout against the still-running source-built `svnserve`. The
command-stage stall occurs before libsvn creates the target directory, so the
evidence records the operator disposition as an explicit `confirmedAbsent`
review; it does not manufacture or silently remove a synthetic partial target.
The same probes also close `unrelatedRepository`: the separately seeded fixture
has deterministic HEAD `r2`, and the probes require the checkout to report that
exact revision. The unrelated checkout occurs
after restart has restored the blocked lane and before same-target retry or
operator confirmation, so later journal clearance cannot mask cross-repository
interference.

The dedicated packaged and installed `redaction` probes each perform one real
checkout of the controlled main repository's exact HEAD `r3` through an
independently counted loopback proxy. The URL, absolute
target path, and per-run high-entropy token must be present in the diagnostic
input derived from that checkout before the candidate production redactor and
`OperationDiagnostics` paths process it. The installed probe also requires a
real production diagnostics bundle from the same Extension Host. The safe
reports contain none of the three raw values, bind the URL and path markers to
the exact inputs, require the secret marker, and limit every serialized
diagnostic value to 32 KiB. A hard-coded or pre-redacted fixture cannot satisfy
this cell.

The installed-negative VSIX/user-data environment uses a bounded disposable
work root under repository `target/i6n`, separate from the evidence fixture
tree, so the staged native bridge remains within the reviewed Windows path
budget. Scenario fixture state and all reportable observations remain under the
I6 fixture root. The driver verifies the disposable root stays below repository
`target`, removes it in `finally`, and rejects any cleanup residue.

The packaged and installed blocked-recovery probes use a separate bounded work
root under repository `target/i6b`. Each surface owns an isolated remote-state
root across exactly two daemon or Extension Host lifetimes. Its command-stall
fixture binds an ephemeral loopback port while the original source-built
`svnserve` remains online for the final successful checkout. The blocked retry
must leave every fixture counter unchanged, so the explicit confirmation is the
only action that releases the target lane.

The packaged and installed recovery-indeterminate probes use a separate bounded
work root under repository `target/i6i`. Each surface reuses an existing
working copy and an isolated `command-stall` fixture. The DACL fault is scoped
to that working copy's `.svn/wc.db`, is armed only after the fixture command
barrier, and is restored exactly even when the child probe fails. The packaged
probe observes explicit manual recovery; the installed probe observes automatic
Extension Host recovery. Both retain the Indeterminate lane state and perform
the exact same-lane rejection without another network contact.

The stalled-mid-read packaged profile and installed VSIX/user-data environment
similarly use a bounded disposable work root under repository `target/i6r`.
The fault fixture state remains in the evidence tree. The driver verifies the
original svnserve process identity before the one-way handoff, binds each
surface's greeting-stall fixture to the original port, then removes the short
root in `finally` and rejects residue. The driver starts no unowned replacement
server.

The absolute-deadline product probes use a separate bounded disposable work root
under repository `target/i6d`. They reuse the preserved read-only working-copy
identities only after the stalled-mid-read cell has settled, bind a fresh
single-connection greeting-stall fixture to the original controlled port for
each surface, and record independent monotonic deadline timing. The driver
removes the short root in `finally` and rejects any residue.

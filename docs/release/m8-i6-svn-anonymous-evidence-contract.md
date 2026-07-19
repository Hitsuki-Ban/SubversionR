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
  packaged-native and installed-VSIX authz-denied probes, controlled ra_svn
  fault fixture, and installed-VSIX 100+1 stress probe;
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

## Required positive matrix

Both `packaged-native` and `installed-vsix-extension-host` surfaces must execute
these cells in this exact order:

1. checkout/open;
2. remote status;
3. repository content;
4. log history;
5. blame history;
6. update;
7. commit;
8. repository copy for branch/tag creation;
9. switch;
10. lock; and
11. unlock.

Every cell proves anonymous access with zero prompts and no credential
settlement, a fresh reconcile result, zero remaining worker descendants and
operation temporary roots, native-lane release after cleanup, and redacted
diagnostics. Fixture startup or a direct bridge/unit probe does not satisfy the
installed surface.

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
`recoverySafe`, `recoveryBlocked`, `unrelatedRepository`, and `redaction` product probes. The
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
relabelled. The remaining controlled negative/recovery cells, including
Indeterminate recovery, are incomplete and no complete candidate report has passed the executable
verifier. Missing controlled observations may not be represented as `verified`
by synthetic evidence. The I6 readiness/public-claim aggregation must be wired
only after one real report passes the executable verifier against the candidate
artifacts.

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

The stalled-mid-read packaged profile and installed VSIX/user-data environment
similarly use a bounded disposable work root under repository `target/i6r`.
The fault fixture state remains in the evidence tree. The driver verifies the
original svnserve process identity before the one-way handoff, binds each
surface's greeting-stall fixture to the original port, then removes the short
root in `finally` and rejects residue. Because the driver still terminates at
the incomplete-matrix blocker, it does not start an unowned replacement server.

The absolute-deadline product probes use a separate bounded disposable work root
under repository `target/i6d`. They reuse the preserved read-only working-copy
identities only after the stalled-mid-read cell has settled, bind a fresh
single-connection greeting-stall fixture to the original controlled port for
each surface, and record independent monotonic deadline timing. The driver
removes the short root in `finally` and rejects any residue.

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
  worker outcomes;
- worker crash contained with zero residue;
- daemon/client disconnect supervised as
  `SUBVERSIONR_REMOTE_WORKER_DISCONNECTED` / `workerContainmentFailed`, with no
  surviving operation worker;
- trust revocation rejected before any subsequent network contact;
- recovery Safe settlement that releases only after fresh reconcile;
- recovery Indeterminate settlement that records
  `SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE` / `remoteOperationIndeterminate`;
- recovery Blocked settlement, including restart after an armed checkout target,
  whose controlled origin is `SUBVERSIONR_REMOTE_WORKER_TIMED_OUT` /
  `operationDeadlineExceeded`, whose product settlement is
  `SUBVERSIONR_REMOTE_RECOVERY_BLOCKED` / `remoteRecoveryBlocked`, and which
  clears only through the exact explicit disposition confirmation contract;
- unrelated repository state unchanged;
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
surface; a shared aggregate constant is not evidence. The
`localEventZeroNetwork` cell is installed-only because #135 requires the real
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
authz-denied, and installed local-event zero-network cells. The authz-denied
cell additionally binds the exact svnserve command log and requires atomic
deny/restore controls. The local-event cell binds a transparent byte-counting
proxy and a real VS Code watcher observer. All drivers keep the evidence report
absent when any candidate observation fails.

This contract intentionally remains fail-closed. The source branch now contains
the installed 100+1 stress probe and real packaged/installed `maliciousRoot`,
`saslOnly`, and `authzDenied` product probes, but the remaining controlled
negative/recovery cells
are incomplete and no complete candidate report has passed the executable
verifier. Missing controlled observations may not be represented as `verified`
by synthetic evidence. The I6 readiness/public-claim aggregation must be wired
only after one real report passes the executable verifier against the candidate
artifacts.

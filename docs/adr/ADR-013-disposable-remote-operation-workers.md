# ADR-013: Disposable Remote Operation Workers

Status: Accepted

## Context

Remote libsvn calls and SSH tunnel descendants can block after cooperative
cancellation stops making progress. Terminating the long-lived sidecar would
also interrupt unrelated repositories and discard the Extension Host's protocol
session.

ADR-007 establishes one Rust sidecar connection per Extension Host. It does not
define the private process topology used to execute an operation.

## Decision

The process connected to the Extension Host remains the single parent sidecar
and product protocol endpoint described by ADR-007. Every operation that can
reach a remote URL executes in a disposable private worker process:

- the worker receives exactly one versioned, length-framed request over an
  inherited private pipe and exposes no listener or public CLI;
- the parent validates the immutable operation envelope, trusted profile,
  Workspace Trust epoch, capability set, and absolute bridge path before the
  worker may reach the network;
- the worker creates a fresh libsvn runtime and allowlisted in-memory
  configuration, executes one `svn_client_*` call, returns one bounded result,
  and exits;
- before resume, the parent must place the worker in a per-operation Windows Job
  that does not permit breakaway and kills the complete descendant tree when
  closed; failure to establish containment fails the operation;
- deadline exhaustion uses `TerminateJobObject` immediately without extending
  the operation budget, then keeps the unnamed, non-inheritable Job handle open
  under a separate bounded supervision budget until accounting observes zero
  active processes; kill-on-close remains the parent-crash backstop;
- the parent owns the monotonic deadline, broker forwarding, connection state,
  credential settlement, post-termination residue accounting, and any
  separately bounded recovery reconcile.

Workers never access VS Code SecretStorage. ADR-010 remains the credential
persistence boundary, with the TypeScript layer brokering ephemeral leases to a
worker through the parent.

Local-only operations may remain in the parent sidecar until a later accepted
ADR changes that boundary.

## Consequences

- A stalled remote call or tunnel can be terminated without killing the parent
  sidecar or unrelated repository sessions.
- The packaged daemon binary may provide a private worker mode, but this creates
  no second Extension Host endpoint and does not change the one-sidecar product
  lifecycle in ADR-007.
- Native runtime startup cost is paid per remote operation; bounded termination
  and state isolation take precedence over remote connection reuse.
- Hard termination cannot claim rollback. An affected working copy enters an
  indeterminate state. Its native lane remains blocked until Job accounting
  observes zero descendants and a separate bounded recovery reconcile reaches a
  terminal result; an accounting timeout blocks all later local and remote
  native calls for that working copy.
- Hosts that cannot establish the required Windows Job containment fail closed;
  an uncontained compatibility path is not provided.

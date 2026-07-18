import { describe, expect, it, vi } from "vitest";
import {
  createCredentialController,
  createCredentialRequestHandler,
  discardCredentialOperationAfterBackendRequest,
  SUBVERSIONR_CREDENTIAL_CANCELLED,
  SUBVERSIONR_CREDENTIAL_LEASE_FOREIGN,
  SUBVERSIONR_CREDENTIAL_LEGACY_BLOCKED,
  SUBVERSIONR_CREDENTIAL_NON_INTERACTIVE,
  SUBVERSIONR_CREDENTIAL_RETRY_INVALID,
  SUBVERSIONR_CREDENTIAL_SECRET_INVALID,
  SUBVERSIONR_CREDENTIAL_SETTLEMENT_CONFLICT,
  SUBVERSIONR_CREDENTIAL_STORAGE_INTEGRITY,
  SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE,
  type CredentialController,
  type CredentialPromptUi,
  type CredentialRequest,
  type CredentialResponse,
  type CredentialSecretStorage,
  type CredentialSettlementOutcome,
} from "../src/auth/credentialController";

const OPERATION_1 = "00000000-0000-4000-8000-000000000001";
const OPERATION_2 = "00000000-0000-4000-8000-000000000002";

class MemorySecretStorage implements CredentialSecretStorage {
  public readonly values = new Map<string, string>();
  public readonly store = vi.fn(async (key: string, value: string) => { this.values.set(key, value); });
  public readonly delete = vi.fn(async (key: string) => { this.values.delete(key); });
  public readonly get = vi.fn(async (key: string) => this.values.get(key));
}

function request(overrides: Partial<CredentialRequest> = {}): CredentialRequest {
  return {
    requestId: "request-1",
    operationId: OPERATION_1,
    endpoint: { scheme: "https", canonicalHost: "svn.example.com", effectivePort: 443 },
    authKind: "basic",
    realm: "Example Realm",
    account: { mode: "fixed", username: "alice" },
    attempt: { kind: "initial" },
    interactive: true,
    persistenceAllowed: true,
    origin: "foreground",
    timeoutMs: 30_000,
    ...overrides,
  };
}

function ui(overrides: Partial<CredentialPromptUi> = {}): CredentialPromptUi {
  return {
    pickAccount: vi.fn(async () => "alice"),
    promptSecret: vi.fn(async () => "secret"),
    pickPersistence: vi.fn(async () => "secretStorage" as const),
    confirmLegacyClear: vi.fn(async () => true),
    ...overrides,
  };
}

function idFactory(): () => string {
  let value = 16;
  return () => `00000000-0000-4000-8000-${(value++).toString(16).padStart(12, "0")}`;
}

function controller(
  storage: MemorySecretStorage,
  promptUi: CredentialPromptUi,
  overrides: { trusted?: boolean; now?: () => number } = {},
): CredentialController {
  return createCredentialController({
    workspaceTrusted: () => overrides.trusted ?? true,
    secretStorage: storage,
    ui: promptUi,
    createId: idFactory(),
    now: overrides.now,
  });
}

function provided(response: CredentialResponse): Extract<CredentialResponse, { action: "provide" }> {
  expect(response.action).toBe("provide");
  return response as Extract<CredentialResponse, { action: "provide" }>;
}

async function settle(
  target: CredentialController,
  response: Extract<CredentialResponse, { action: "provide" }>,
  outcome: CredentialSettlementOutcome,
  operationId = response.operationId,
) {
  return await target.handleCredentialSettlement({
    requestId: `settle-${outcome}`,
    operationId,
    leaseId: response.leaseId,
    outcome,
    timeoutMs: 10_000,
  });
}

describe("credential request wire contract", () => {
  it("accepts only the exact v2 request and settlement shapes", async () => {
    const storage = new MemorySecretStorage();
    const target = controller(storage, ui());
    const handler = createCredentialRequestHandler(target);
    const response = provided(await handler("credentials/request", request()) as CredentialResponse);

    const ack = await handler("credentials/settle", {
      requestId: "settle-1",
      operationId: OPERATION_1,
      leaseId: response.leaseId,
      outcome: "unused",
      timeoutMs: 10_000,
    });
    expect(ack).toEqual({
      requestId: "settle-1",
      operationId: OPERATION_1,
      leaseId: response.leaseId,
      outcome: "unused",
    });

    await expect(handler("credentials/request", { ...request(), username: "legacy" })).rejects.toMatchObject({
      code: "RPC_INVALID_PARAMS",
      safeArgs: { field: "params" },
    });
    await expect(handler("credentials/settle", {
      requestId: "settle-2",
      operationId: OPERATION_1,
      leaseId: response.leaseId,
      outcome: "unused",
    })).rejects.toMatchObject({ code: "RPC_INVALID_PARAMS", safeArgs: { field: "params" } });
  });

  it("rejects invalid endpoint/auth combinations and background chooser requests", async () => {
    const handler = createCredentialRequestHandler(controller(new MemorySecretStorage(), ui()));
    await expect(handler("credentials/request", request({ authKind: "cramMd5" }))).rejects.toMatchObject({
      code: "RPC_INVALID_PARAMS",
      safeArgs: { field: "authKind" },
    });
    await expect(handler("credentials/request", request({
      endpoint: { scheme: "https", canonicalHost: "ＳＶＮ.example.com", effectivePort: 443 },
    }))).rejects.toMatchObject({
      code: "RPC_INVALID_PARAMS",
      safeArgs: { field: "endpoint.canonicalHost" },
    });
    await expect(handler("credentials/request", request({ realm: "😀".repeat(1_025) }))).rejects.toMatchObject({
      code: "RPC_INVALID_PARAMS",
      safeArgs: { field: "realm" },
    });
    await expect(handler("credentials/request", request({
      account: { mode: "fixed", username: "😀".repeat(65) },
    }))).rejects.toMatchObject({
      code: "RPC_INVALID_PARAMS",
      safeArgs: { field: "account.username" },
    });
    await expect(handler("credentials/request", request({
      account: { mode: "chooseForeground" },
      interactive: false,
      origin: "background",
    }))).rejects.toMatchObject({ code: "RPC_INVALID_PARAMS" });
  });
});

describe("credential leases", () => {
  it("does not persist prompted credentials until accepted, then reuses them", async () => {
    const storage = new MemorySecretStorage();
    const promptUi = ui();
    const target = controller(storage, promptUi);
    const first = provided(await target.handleCredentialRequest(request()));
    expect(storage.store).not.toHaveBeenCalled();

    await settle(target, first, "accepted");
    expect([...storage.values.keys()]).toHaveLength(2);
    expect([...storage.values.keys()].every((key) => !key.includes("alice") && !key.includes("svn.example.com"))).toBe(true);

    const second = provided(await target.handleCredentialRequest(request({
      requestId: "request-2",
      operationId: OPERATION_2,
      interactive: false,
      origin: "background",
    })));
    expect(second.credential).toEqual({ username: "alice", secret: "secret" });
    expect(second.leaseId).not.toBe(first.leaseId);
    expect(promptUi.promptSecret).toHaveBeenCalledTimes(1);
  });

  it("uses session intent without asking for persistence when persistence is disallowed", async () => {
    const promptUi = ui();
    const target = controller(new MemorySecretStorage(), promptUi);
    const response = provided(await target.handleCredentialRequest(request({ persistenceAllowed: false })));

    expect(response.persistenceIntent).toBe("session");
    expect(promptUi.pickPersistence).not.toHaveBeenCalled();
  });

  it("fans out one compatible prompt to independent leases", async () => {
    let resolveSecret!: (secret: string) => void;
    const secret = new Promise<string>((resolve) => { resolveSecret = resolve; });
    const promptUi = ui({ promptSecret: vi.fn(async () => await secret) });
    const target = controller(new MemorySecretStorage(), promptUi);
    const firstPromise = target.handleCredentialRequest(request());
    const secondPromise = target.handleCredentialRequest(request({ requestId: "request-2", operationId: OPERATION_2 }));
    resolveSecret("shared");
    const [first, second] = (await Promise.all([firstPromise, secondPromise])).map(provided);

    expect(promptUi.promptSecret).toHaveBeenCalledTimes(1);
    expect(first.leaseId).not.toBe(second.leaseId);
    expect(first.requestId).toBe("request-1");
    expect(second.requestId).toBe("request-2");
  });

  it("keeps prompts for different realms concurrent", async () => {
    let resolveBothStarted!: () => void;
    const bothStarted = new Promise<void>((resolve) => { resolveBothStarted = resolve; });
    let releasePrompts!: () => void;
    const promptsReleased = new Promise<void>((resolve) => { releasePrompts = resolve; });
    let started = 0;
    const promptSecret = vi.fn(async (credentialRequest: CredentialRequest) => {
      started += 1;
      if (started === 2) {
        resolveBothStarted();
      }
      await promptsReleased;
      return `secret-${credentialRequest.realm}`;
    });
    const target = controller(new MemorySecretStorage(), ui({ promptSecret }));

    const firstPromise = target.handleCredentialRequest(request({ realm: "Realm One" }));
    const secondPromise = target.handleCredentialRequest(request({
      requestId: "request-2",
      operationId: OPERATION_2,
      realm: "Realm Two",
    }));
    await expect(Promise.race([
      bothStarted.then(() => true),
      new Promise<boolean>((resolve) => setTimeout(() => resolve(false), 1_000)),
    ])).resolves.toBe(true);
    releasePrompts();

    const [first, second] = (await Promise.all([firstPromise, secondPromise])).map(provided);
    expect(promptSecret).toHaveBeenCalledTimes(2);
    expect(first.credential.secret).toBe("secret-Realm One");
    expect(second.credential.secret).toBe("secret-Realm Two");
  });

  it("starts fixed-account single-flight before asynchronous SecretStorage lookup", async () => {
    const storage = new MemorySecretStorage();
    storage.get.mockImplementation(async (key: string) => {
      await new Promise((resolve) => setTimeout(resolve, 5));
      return storage.values.get(key);
    });
    const promptUi = ui();
    const target = controller(storage, promptUi);

    const [first, second] = (await Promise.all([
      target.handleCredentialRequest(request()),
      target.handleCredentialRequest(request({ requestId: "request-2", operationId: OPERATION_2 })),
    ])).map(provided);

    expect(promptUi.promptSecret).toHaveBeenCalledTimes(1);
    expect(first.leaseId).not.toBe(second.leaseId);
  });

  it("bounds each single-flight waiter by its own remaining timeout", async () => {
    let resolveSecret!: (secret: string) => void;
    const secret = new Promise<string>((resolve) => { resolveSecret = resolve; });
    const target = controller(
      new MemorySecretStorage(),
      ui({ promptSecret: vi.fn(async () => await secret) }),
    );
    const firstPromise = target.handleCredentialRequest(request({ timeoutMs: 1_000 }));
    const second = await target.handleCredentialRequest(request({
      requestId: "request-2",
      operationId: OPERATION_2,
      timeoutMs: 1,
    }));
    expect(second).toMatchObject({ action: "cancel", error: { code: "SUBVERSIONR_CREDENTIAL_TIMEOUT" } });

    resolveSecret("shared");
    expect((await firstPromise).action).toBe("provide");
  });

  it("does not issue a late lease after its backend operation settles during a prompt", async () => {
    let notifyPromptStarted!: () => void;
    const promptStarted = new Promise<void>((resolve) => { notifyPromptStarted = resolve; });
    let resolveSecret!: (secret: string) => void;
    const secret = new Promise<string>((resolve) => { resolveSecret = resolve; });
    const storage = new MemorySecretStorage();
    const promptUi = ui({
      promptSecret: vi.fn(async () => {
        notifyPromptStarted();
        return await secret;
      }),
    });
    const target = controller(storage, promptUi);

    const pending = target.handleCredentialRequest(request());
    await promptStarted;
    discardCredentialOperationAfterBackendRequest(target, {
      remote: { version: 1, operationId: OPERATION_1 },
    });
    await expect(target.handleCredentialRequest(request({ requestId: "request-after-settlement" }))).resolves.toMatchObject({
      action: "cancel",
      error: { code: SUBVERSIONR_CREDENTIAL_CANCELLED },
    });
    resolveSecret("too-late");

    await expect(pending).resolves.toMatchObject({
      action: "cancel",
      error: { code: SUBVERSIONR_CREDENTIAL_CANCELLED },
    });
    expect((target as unknown as { pendingLeases: Map<string, unknown> }).pendingLeases.size).toBe(0);
    expect((target as unknown as { operationRequests: Map<string, unknown> }).operationRequests.size).toBe(0);
    expect(storage.store).not.toHaveBeenCalled();
    expect(promptUi.promptSecret).toHaveBeenCalledTimes(1);
  });

  it("lets acceptance win over a sibling rejection of the same generation", async () => {
    const storage = new MemorySecretStorage();
    const target = controller(storage, ui());
    const [first, second] = (await Promise.all([
      target.handleCredentialRequest(request()),
      target.handleCredentialRequest(request({ requestId: "request-2", operationId: OPERATION_2 })),
    ])).map(provided);

    await settle(target, first, "rejected");
    await settle(target, second, "accepted");
    expect([...storage.values.keys()]).toHaveLength(2);
  });

  it("deletes a rejected stored generation when its sibling is unused", async () => {
    const storage = new MemorySecretStorage();
    const target = controller(storage, ui());
    const seeded = provided(await target.handleCredentialRequest(request()));
    await settle(target, seeded, "accepted");
    const [rejected, unused] = (await Promise.all([
      target.handleCredentialRequest(request({ requestId: "request-rejected" })),
      target.handleCredentialRequest(request({ requestId: "request-unused", operationId: OPERATION_2 })),
    ])).map(provided);

    await settle(target, rejected, "rejected");
    await settle(target, unused, "unused");

    expect(storage.values.size).toBe(0);
  });

  it("restores a rejected stored generation when its sibling is subsequently accepted", async () => {
    const storage = new MemorySecretStorage();
    const target = controller(storage, ui());
    const seeded = provided(await target.handleCredentialRequest(request()));
    await settle(target, seeded, "accepted");
    const [rejected, accepted] = (await Promise.all([
      target.handleCredentialRequest(request({ requestId: "request-rejected" })),
      target.handleCredentialRequest(request({ requestId: "request-accepted", operationId: OPERATION_2 })),
    ])).map(provided);

    await settle(target, rejected, "rejected");
    expect(storage.values.size).toBe(0);
    await settle(target, accepted, "accepted");

    expect(storage.values.size).toBe(2);
  });

  it("forgets an accepted generation when its last sibling is discarded", async () => {
    const storage = new MemorySecretStorage();
    const target = controller(storage, ui());
    const seeded = provided(await target.handleCredentialRequest(request()));
    await settle(target, seeded, "accepted");
    const [accepted, discarded] = (await Promise.all([
      target.handleCredentialRequest(request({ requestId: "request-accepted" })),
      target.handleCredentialRequest(request({ requestId: "request-discarded", operationId: OPERATION_2 })),
    ])).map(provided);

    await settle(target, accepted, "accepted");
    expect((target as unknown as { acceptedGenerations: Set<string> }).acceptedGenerations.size).toBe(1);
    target.discardOperation(discarded.operationId);
    expect((target as unknown as { acceptedGenerations: Set<string> }).acceptedGenerations.size).toBe(0);

    const rejected = provided(await target.handleCredentialRequest(request({ requestId: "request-rejected" })));
    await settle(target, rejected, "rejected");
    expect(storage.values.size).toBe(0);
  });

  it("invalidates rejected stored credentials and permits one attributed retry", async () => {
    const storage = new MemorySecretStorage();
    const promptSecret = vi.fn()
      .mockResolvedValueOnce("bad-secret")
      .mockResolvedValueOnce("good-secret");
    const target = controller(storage, ui({ promptSecret }));
    const first = provided(await target.handleCredentialRequest(request()));
    await settle(target, first, "accepted");

    const stored = provided(await target.handleCredentialRequest(request({ requestId: "request-2" })));
    await settle(target, stored, "rejected");
    expect(storage.values.size).toBe(0);

    const retry = provided(await target.handleCredentialRequest(request({
      requestId: "request-3",
      attempt: { kind: "retryAfterRejected", previousLeaseId: stored.leaseId },
    })));
    expect(retry.credential).toEqual({ username: "alice", secret: "good-secret" });

    const duplicateRetry = await target.handleCredentialRequest(request({
      requestId: "request-duplicate-retry",
      attempt: { kind: "retryAfterRejected", previousLeaseId: stored.leaseId },
    }));
    expect(duplicateRetry).toMatchObject({
      action: "cancel",
      error: { code: SUBVERSIONR_CREDENTIAL_RETRY_INVALID },
    });

    const invalid = await target.handleCredentialRequest(request({
      requestId: "request-4",
      operationId: OPERATION_2,
      attempt: { kind: "retryAfterRejected", previousLeaseId: stored.leaseId },
    }));
    expect(invalid).toMatchObject({ action: "cancel", error: { code: SUBVERSIONR_CREDENTIAL_RETRY_INVALID } });
  });

  it("does not permit a retry after an initial prompted credential", async () => {
    const target = controller(new MemorySecretStorage(), ui());
    const prompted = provided(await target.handleCredentialRequest(request()));
    await settle(target, prompted, "rejected");

    const retry = await target.handleCredentialRequest(request({
      requestId: "request-2",
      attempt: { kind: "retryAfterRejected", previousLeaseId: prompted.leaseId },
    }));

    expect(retry).toMatchObject({
      action: "cancel",
      error: { code: SUBVERSIONR_CREDENTIAL_RETRY_INVALID },
    });
  });

  it("makes duplicate settlement idempotent and conflicting or foreign settlement fail", async () => {
    const target = controller(new MemorySecretStorage(), ui());
    const lease = provided(await target.handleCredentialRequest(request()));
    const first = await settle(target, lease, "unused");
    expect(await settle(target, lease, "unused")).toEqual(first);
    await expect(settle(target, lease, "cancelled")).rejects.toMatchObject({
      code: SUBVERSIONR_CREDENTIAL_SETTLEMENT_CONFLICT,
    });
    await expect(settle(target, lease, "unused", OPERATION_2)).rejects.toMatchObject({
      code: SUBVERSIONR_CREDENTIAL_LEASE_FOREIGN,
    });
  });

  it("serializes concurrent settlement so effects happen once and conflicts fail deterministically", async () => {
    const storage = new MemorySecretStorage();
    const target = controller(storage, ui());
    const lease = provided(await target.handleCredentialRequest(request()));

    const [first, duplicate] = await Promise.all([
      settle(target, lease, "accepted"),
      settle(target, lease, "accepted"),
    ]);
    expect(duplicate).toEqual(first);
    expect(storage.store).toHaveBeenCalledTimes(2);

    const conflictLease = provided(await target.handleCredentialRequest(request({
      requestId: "request-conflict",
      operationId: OPERATION_2,
    })));
    const accepted = settle(target, conflictLease, "accepted");
    const rejected = settle(target, conflictLease, "rejected");
    await expect(accepted).resolves.toMatchObject({ outcome: "accepted" });
    await expect(rejected).rejects.toMatchObject({ code: SUBVERSIONR_CREDENTIAL_SETTLEMENT_CONFLICT });
    expect(storage.store).toHaveBeenCalledTimes(2);
  });

  it("binds pending leases to the backend connection lifecycle", async () => {
    const storage = new MemorySecretStorage();
    const target = controller(storage, ui());
    const lease = provided(await target.handleCredentialRequest(request()));

    target.invalidateBackendConnection();

    await expect(settle(target, lease, "accepted")).rejects.toMatchObject({
      code: "SUBVERSIONR_CREDENTIAL_LEASE_UNKNOWN",
    });
    expect(storage.store).not.toHaveBeenCalled();
  });

  it("rejects settlement after Workspace Trust is revoked without writing", async () => {
    let trusted = true;
    const storage = new MemorySecretStorage();
    const target = createCredentialController({
      workspaceTrusted: () => trusted,
      secretStorage: storage,
      ui: ui(),
      createId: idFactory(),
    });
    const lease = provided(await target.handleCredentialRequest(request()));
    trusted = false;

    await expect(settle(target, lease, "accepted")).rejects.toMatchObject({
      code: SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE,
    });
    expect(storage.store).not.toHaveBeenCalled();
  });

  it("does not write when the backend disconnects during settlement storage reads", async () => {
    const storage = new MemorySecretStorage();
    const target = controller(storage, ui());
    const lease = provided(await target.handleCredentialRequest(request()));
    let releaseRead!: () => void;
    const read = new Promise<void>((resolve) => { releaseRead = resolve; });
    let block = true;
    storage.get.mockImplementation(async (key: string) => {
      if (block && key === "subversionr.credential.index.v2") {
        await read;
      }
      return storage.values.get(key);
    });

    const settlement = settle(target, lease, "accepted");
    await Promise.resolve();
    target.invalidateBackendConnection();
    block = false;
    releaseRead();

    await expect(settlement).rejects.toMatchObject({ code: "SUBVERSIONR_CREDENTIAL_LEASE_UNKNOWN" });
    expect(storage.store).not.toHaveBeenCalled();
  });

  it("rolls back accepted persistence when the backend disconnects during a SecretStorage write", async () => {
    const storage = new MemorySecretStorage();
    const target = controller(storage, ui());
    const lease = provided(await target.handleCredentialRequest(request()));
    let releaseWrite!: () => void;
    let notifyWriteStarted!: () => void;
    const writeStarted = new Promise<void>((resolve) => { notifyWriteStarted = resolve; });
    const write = new Promise<void>((resolve) => { releaseWrite = resolve; });
    let call = 0;
    storage.store.mockImplementation(async (key: string, value: string) => {
      call += 1;
      if (call === 2) {
        notifyWriteStarted();
        await write;
      }
      storage.values.set(key, value);
    });

    const settlement = settle(target, lease, "accepted");
    await writeStarted;
    target.invalidateBackendConnection();
    releaseWrite();

    await expect(settlement).rejects.toMatchObject({ code: "SUBVERSIONR_CREDENTIAL_LEASE_UNKNOWN" });
    expect(storage.values.size).toBe(0);
  });

  it("uses one absolute request deadline across UI phases and as the lease expiry", async () => {
    let now = 100;
    const persistenceTimeouts: number[] = [];
    const promptUi = ui({
      promptSecret: vi.fn(async () => {
        now = 107;
        return "secret";
      }),
      pickPersistence: vi.fn(async (value) => {
        persistenceTimeouts.push(value.timeoutMs);
        return "session" as const;
      }),
    });
    const target = controller(new MemorySecretStorage(), promptUi, { now: () => now });
    const lease = provided(await target.handleCredentialRequest(request({ timeoutMs: 10 })));
    expect(persistenceTimeouts).toEqual([3]);

    now = 110;
    await expect(settle(target, lease, "accepted")).rejects.toMatchObject({
      code: "SUBVERSIONR_CREDENTIAL_LEASE_EXPIRED",
    });
  });

  it("fails a settlement budget before writes and leaves no background storage work", async () => {
    let now = 0;
    const storage = new MemorySecretStorage();
    const target = controller(storage, ui(), { now: () => now });
    const lease = provided(await target.handleCredentialRequest(request({ timeoutMs: 10 })));
    storage.get.mockImplementation(async (key: string) => {
      now = 10;
      return storage.values.get(key);
    });

    await expect(settle(target, lease, "accepted")).rejects.toMatchObject({
      code: "SUBVERSIONR_CREDENTIAL_TIMEOUT",
    });
    expect(storage.store).not.toHaveBeenCalled();
    await Promise.resolve();
    expect(storage.store).not.toHaveBeenCalled();
  });

  it("backend request settlement and dispose discard leases without persistence", async () => {
    const storage = new MemorySecretStorage();
    const target = controller(storage, ui());
    const discarded = provided(await target.handleCredentialRequest(request()));
    discardCredentialOperationAfterBackendRequest(target, {
      remote: { version: 1, operationId: OPERATION_1 },
    });
    await expect(settle(target, discarded, "accepted")).rejects.toMatchObject({ code: expect.any(String) });
    expect(storage.store).not.toHaveBeenCalled();

    const pending = provided(await target.handleCredentialRequest(request({ operationId: OPERATION_2 })));
    target.dispose();
    await expect(settle(target, pending, "accepted")).rejects.toMatchObject({ code: expect.any(String) });
    expect(storage.store).not.toHaveBeenCalled();
  });

  it("ignores non-remote and non-canonical operation settlement params", () => {
    const discardOperation = vi.fn();
    const target = { discardOperation };

    discardCredentialOperationAfterBackendRequest(target, {});
    discardCredentialOperationAfterBackendRequest(target, { remote: [] });
    discardCredentialOperationAfterBackendRequest(target, {
      remote: { version: 1, operationId: "NOT-CANONICAL" },
    });

    expect(discardOperation).not.toHaveBeenCalled();
  });

  it("removes empty operation lease buckets after settlement and discard", async () => {
    const target = controller(new MemorySecretStorage(), ui());
    const settled = provided(await target.handleCredentialRequest(request()));
    await settle(target, settled, "unused");
    expect((target as unknown as { operationLeases: Map<string, Set<string>> }).operationLeases.size).toBe(0);
    expect((target as unknown as { tombstones: Map<string, unknown> }).tombstones.size).toBe(1);
    target.discardOperation(OPERATION_1);
    expect((target as unknown as { tombstones: Map<string, unknown> }).tombstones.size).toBe(0);
    await expect(settle(target, settled, "unused")).rejects.toMatchObject({
      code: "SUBVERSIONR_CREDENTIAL_LEASE_UNKNOWN",
    });

    const discarded = provided(await target.handleCredentialRequest(request({ operationId: OPERATION_2 })));
    target.discardOperation(discarded.operationId);
    expect((target as unknown as { operationLeases: Map<string, Set<string>> }).operationLeases.size).toBe(0);
  });

  it("keeps retry tombstones free of credential secrets", async () => {
    const target = controller(new MemorySecretStorage(), ui());
    const lease = provided(await target.handleCredentialRequest(request()));
    await settle(target, lease, "rejected");

    const tombstones = (target as unknown as { tombstones: Map<string, unknown> }).tombstones;
    expect(JSON.stringify(tombstones.get(lease.leaseId))).not.toContain("secret");
    expect(tombstones.get(lease.leaseId)).toMatchObject({ username: "alice", source: "prompt" });
  });
});

describe("credential policy and storage integrity", () => {
  it("blocks untrusted workspaces before storage or UI", async () => {
    const storage = new MemorySecretStorage();
    const promptUi = ui();
    const response = await controller(storage, promptUi, { trusted: false }).handleCredentialRequest(request());
    expect(response).toMatchObject({ action: "cancel", error: { code: SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE } });
    expect(storage.get).not.toHaveBeenCalled();
    expect(promptUi.promptSecret).not.toHaveBeenCalled();
  });

  it("rechecks Workspace Trust after an in-flight prompt and does not issue a lease", async () => {
    let trusted = true;
    let resolveSecret!: (value: string) => void;
    const secret = new Promise<string>((resolve) => { resolveSecret = resolve; });
    const storage = new MemorySecretStorage();
    const target = createCredentialController({
      workspaceTrusted: () => trusted,
      secretStorage: storage,
      ui: ui({ promptSecret: vi.fn(async () => await secret) }),
      createId: idFactory(),
    });
    const pending = target.handleCredentialRequest(request());
    await Promise.resolve();
    trusted = false;
    resolveSecret("secret");

    await expect(pending).resolves.toMatchObject({
      action: "cancel",
      error: { code: SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE },
    });
    expect((target as unknown as { pendingLeases: Map<string, unknown> }).pendingLeases.size).toBe(0);
    expect(storage.store).not.toHaveBeenCalled();
  });

  it("never prompts for background requests", async () => {
    const promptUi = ui();
    const response = await controller(new MemorySecretStorage(), promptUi).handleCredentialRequest(request({
      interactive: false,
      origin: "background",
      account: { mode: "chooseForeground" },
    }));
    expect(response).toMatchObject({ action: "cancel", error: { code: SUBVERSIONR_CREDENTIAL_NON_INTERACTIVE } });
    expect(promptUi.pickAccount).not.toHaveBeenCalled();
  });

  it("requires explicit foreground clearing when legacy v1 credentials exist", async () => {
    const storage = new MemorySecretStorage();
    storage.values.set("subversionr.credential.index.v1", JSON.stringify({
      version: 1,
      keys: ["subversionr.credential.v1.legacy"],
    }));
    storage.values.set("subversionr.credential.v1.legacy", "legacy-secret");
    const promptUi = ui();
    const target = controller(storage, promptUi);

    const blocked = await target.handleCredentialRequest(request({ interactive: false, origin: "background" }));
    expect(blocked).toMatchObject({ action: "cancel", error: { code: SUBVERSIONR_CREDENTIAL_LEGACY_BLOCKED } });
    expect(promptUi.confirmLegacyClear).not.toHaveBeenCalled();

    expect((await target.handleCredentialRequest(request())).action).toBe("provide");
    expect(promptUi.confirmLegacyClear).toHaveBeenCalledWith(expect.anything(), 1);
    expect(storage.values.has("subversionr.credential.index.v1")).toBe(false);
    expect(storage.values.has("subversionr.credential.v1.legacy")).toBe(false);
  });

  it("does not clear legacy credentials when a timed-out confirmation resolves late", async () => {
    const storage = new MemorySecretStorage();
    storage.values.set("subversionr.credential.index.v1", JSON.stringify({
      version: 1,
      keys: ["subversionr.credential.v1.legacy"],
    }));
    storage.values.set("subversionr.credential.v1.legacy", "legacy-secret");
    let resolveConfirmation!: (value: boolean) => void;
    const confirmation = new Promise<boolean>((resolve) => { resolveConfirmation = resolve; });
    const target = controller(storage, ui({
      confirmLegacyClear: vi.fn(async () => await confirmation),
    }));

    const response = await target.handleCredentialRequest(request({ timeoutMs: 1 }));
    expect(response).toMatchObject({ action: "cancel", error: { code: "SUBVERSIONR_CREDENTIAL_TIMEOUT" } });
    resolveConfirmation(true);
    await Promise.resolve();
    await Promise.resolve();

    expect(storage.delete).not.toHaveBeenCalled();
    expect(storage.values.has("subversionr.credential.index.v1")).toBe(true);
    expect(storage.values.has("subversionr.credential.v1.legacy")).toBe(true);
  });

  it("times out a slow initial legacy index read without late UI or mutation", async () => {
    let notifyReadStarted!: () => void;
    const readStarted = new Promise<void>((resolve) => { notifyReadStarted = resolve; });
    let resolveRead!: (value: string | undefined) => void;
    const read = new Promise<string | undefined>((resolve) => { resolveRead = resolve; });
    const storage = new MemorySecretStorage();
    storage.get.mockImplementation(async () => {
      notifyReadStarted();
      return await read;
    });
    const promptUi = ui();
    const target = controller(storage, promptUi);

    const pending = target.handleCredentialRequest(request({ timeoutMs: 5 }));
    await readStarted;
    await expect(pending).resolves.toMatchObject({
      action: "cancel",
      error: { code: "SUBVERSIONR_CREDENTIAL_TIMEOUT" },
    });
    resolveRead(undefined);
    await Promise.resolve();
    await Promise.resolve();

    expect(promptUi.confirmLegacyClear).not.toHaveBeenCalled();
    expect(promptUi.promptSecret).not.toHaveBeenCalled();
    expect(storage.store).not.toHaveBeenCalled();
    expect(storage.delete).not.toHaveBeenCalled();
    expect((target as unknown as { pendingLeases: Map<string, unknown> }).pendingLeases.size).toBe(0);
  });

  it("fails closed on malformed indexed storage", async () => {
    const storage = new MemorySecretStorage();
    storage.values.set("subversionr.credential.index.v2", JSON.stringify({ version: 2, entries: [], extra: true }));
    const target = controller(storage, ui());
    await expect(target.handleCredentialRequest(request())).rejects.toMatchObject({
      code: SUBVERSIONR_CREDENTIAL_STORAGE_INTEGRITY,
    });
    const second = await target.handleCredentialRequest(request({ requestId: "request-2" }));
    expect(second).toMatchObject({ action: "cancel", error: { code: SUBVERSIONR_CREDENTIAL_STORAGE_INTEGRITY } });
  });

  it("clears a registered partial credential after storage integrity blocking", async () => {
    const storage = new MemorySecretStorage();
    const creator = controller(storage, ui());
    const lease = provided(await creator.handleCredentialRequest(request()));
    await settle(creator, lease, "accepted");
    const entryKey = [...storage.values.keys()].find((key) => key.startsWith("subversionr.credential.v2."));
    expect(entryKey).toBeDefined();
    storage.values.delete(entryKey!);

    const target = controller(storage, ui());
    await expect(target.handleCredentialRequest(request())).rejects.toMatchObject({
      code: SUBVERSIONR_CREDENTIAL_STORAGE_INTEGRITY,
    });
    await expect(target.clearSavedCredentials()).resolves.toEqual({ deleted: 1 });
    expect(storage.values.size).toBe(0);
  });

  it("discards pending leases before explicitly clearing saved credentials", async () => {
    const storage = new MemorySecretStorage();
    const target = controller(storage, ui());
    const pending = provided(await target.handleCredentialRequest(request()));

    await expect(target.clearSavedCredentials()).resolves.toEqual({ deleted: 0 });
    await expect(settle(target, pending, "accepted")).rejects.toMatchObject({
      code: "SUBVERSIONR_CREDENTIAL_LEASE_UNKNOWN",
    });
    expect(storage.values.size).toBe(0);
  });

  it("rejects empty and oversized prompt secrets with a stable code", async () => {
    for (const secret of ["", "x".repeat(32_769)]) {
      const target = controller(new MemorySecretStorage(), ui({ promptSecret: vi.fn(async () => secret) }));
      await expect(target.handleCredentialRequest(request())).resolves.toMatchObject({
        action: "cancel",
        error: { code: SUBVERSIONR_CREDENTIAL_SECRET_INVALID, messageKey: "error.auth.credentialSecretInvalid" },
      });
    }
  });

  it("treats an invalid stored secret as storage integrity failure", async () => {
    const storage = new MemorySecretStorage();
    const creator = controller(storage, ui());
    const lease = provided(await creator.handleCredentialRequest(request()));
    await settle(creator, lease, "accepted");
    const entryKey = [...storage.values.keys()].find((key) => key.startsWith("subversionr.credential.v2."))!;
    const stored = JSON.parse(storage.values.get(entryKey)!) as Record<string, unknown>;
    storage.values.set(entryKey, JSON.stringify({ ...stored, secret: "" }));

    await expect(controller(storage, ui()).handleCredentialRequest(request())).rejects.toMatchObject({
      code: SUBVERSIONR_CREDENTIAL_STORAGE_INTEGRITY,
    });
  });
});

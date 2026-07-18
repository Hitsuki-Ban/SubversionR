import { createHash, randomUUID } from "node:crypto";
import { isIP } from "node:net";
import { URL } from "node:url";

export const SUBVERSIONR_CREDENTIAL_CANCELLED = "SUBVERSIONR_CREDENTIAL_CANCELLED";
export const SUBVERSIONR_CREDENTIAL_NON_INTERACTIVE = "SUBVERSIONR_CREDENTIAL_NON_INTERACTIVE";
export const SUBVERSIONR_CREDENTIAL_TIMEOUT = "SUBVERSIONR_CREDENTIAL_TIMEOUT";
export const SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE = "SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE";
export const SUBVERSIONR_CREDENTIAL_LEGACY_BLOCKED = "SUBVERSIONR_CREDENTIAL_LEGACY_BLOCKED";
export const SUBVERSIONR_CREDENTIAL_LEGACY_CLEAR_DECLINED = "SUBVERSIONR_CREDENTIAL_LEGACY_CLEAR_DECLINED";
export const SUBVERSIONR_CREDENTIAL_ACCOUNT_UNAVAILABLE = "SUBVERSIONR_CREDENTIAL_ACCOUNT_UNAVAILABLE";
export const SUBVERSIONR_CREDENTIAL_RETRY_INVALID = "SUBVERSIONR_CREDENTIAL_RETRY_INVALID";
export const SUBVERSIONR_CREDENTIAL_STORAGE_INTEGRITY = "SUBVERSIONR_CREDENTIAL_STORAGE_INTEGRITY";
export const SUBVERSIONR_CREDENTIAL_LEASE_UNKNOWN = "SUBVERSIONR_CREDENTIAL_LEASE_UNKNOWN";
export const SUBVERSIONR_CREDENTIAL_LEASE_FOREIGN = "SUBVERSIONR_CREDENTIAL_LEASE_FOREIGN";
export const SUBVERSIONR_CREDENTIAL_LEASE_EXPIRED = "SUBVERSIONR_CREDENTIAL_LEASE_EXPIRED";
export const SUBVERSIONR_CREDENTIAL_SETTLEMENT_CONFLICT = "SUBVERSIONR_CREDENTIAL_SETTLEMENT_CONFLICT";
export const SUBVERSIONR_CREDENTIAL_SECRET_INVALID = "SUBVERSIONR_CREDENTIAL_SECRET_INVALID";

const LEGACY_INDEX_KEY = "subversionr.credential.index.v1";
const LEGACY_ENTRY_PREFIX = "subversionr.credential.v1.";
const V2_INDEX_KEY = "subversionr.credential.index.v2";
const V2_ENTRY_PREFIX = "subversionr.credential.v2.";
const MAX_INDEX_ENTRIES = 256;
const MAX_ACTIVE_LEASES = 1024;
const MAX_TOMBSTONES = 4096;
const MAX_SECRET_UTF8_BYTES = 32_768;
const PROMPT_TIMEOUT = Symbol("credentialPromptTimeout");

export type CredentialPersistenceIntent = "secretStorage" | "session";
export type ServerAuthKind = "basic" | "cramMd5";
export type CredentialSettlementOutcome = "accepted" | "rejected" | "unused" | "cancelled" | "timedOut";

export interface CanonicalCredentialEndpoint {
  scheme: "http" | "https" | "svn";
  canonicalHost: string;
  effectivePort: number;
}

export type CredentialAccountSelection =
  | { mode: "fixed"; username: string }
  | { mode: "chooseForeground" };

export type CredentialAttempt =
  | { kind: "initial" }
  | { kind: "retryAfterRejected"; previousLeaseId: string };

export interface CredentialRequest {
  requestId: string;
  operationId: string;
  endpoint: CanonicalCredentialEndpoint;
  authKind: ServerAuthKind;
  realm: string;
  account: CredentialAccountSelection;
  attempt: CredentialAttempt;
  interactive: boolean;
  persistenceAllowed: boolean;
  origin: "foreground" | "background";
  timeoutMs: number;
}

export interface Credential {
  username: string;
  secret: string;
}

export type CredentialResponse =
  | {
      requestId: string;
      operationId: string;
      action: "provide";
      leaseId: string;
      credential: Credential;
      persistenceIntent: CredentialPersistenceIntent;
    }
  | {
      requestId: string;
      operationId: string;
      action: "cancel";
      error: CredentialError;
    };

export interface CredentialSettlementRequest {
  requestId: string;
  operationId: string;
  leaseId: string;
  outcome: CredentialSettlementOutcome;
  timeoutMs: number;
}

export interface CredentialSettlementAck {
  requestId: string;
  operationId: string;
  leaseId: string;
  outcome: CredentialSettlementOutcome;
}

export interface CredentialError {
  code: string;
  category: "auth" | "lifecycle";
  messageKey: string;
  args: Record<string, unknown>;
  retryable: false;
}

export interface CredentialSecretStorage {
  get(key: string): Promise<string | undefined>;
  store(key: string, value: string): Promise<void>;
  delete(key: string): Promise<void>;
}

export interface CredentialPromptUi {
  pickAccount(request: CredentialRequest, storedAccounts: readonly string[]): Promise<string | undefined>;
  promptSecret(request: CredentialRequest, username: string): Promise<string | undefined>;
  pickPersistence(request: CredentialRequest): Promise<CredentialPersistenceIntent | undefined>;
  confirmLegacyClear(request: CredentialRequest, entryCount: number): Promise<boolean>;
}

export interface CredentialControllerOptions {
  workspaceTrusted(): boolean;
  secretStorage: CredentialSecretStorage;
  ui: CredentialPromptUi;
  now?: () => number;
  createId?: () => string;
}

export interface CredentialController {
  handleCredentialRequest(request: CredentialRequest): Promise<CredentialResponse>;
  handleCredentialSettlement(request: CredentialSettlementRequest): Promise<CredentialSettlementAck>;
  clearSavedCredentials(): Promise<CredentialClearResult>;
  discardOperation(operationId: string): void;
  invalidateBackendConnection(): void;
  dispose(): void;
}

export interface CredentialClearResult {
  deleted: number;
}

export class CredentialRpcError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: string,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown>,
    public readonly retryable = false,
  ) {
    super(code);
    this.name = "CredentialRpcError";
  }
}

interface StoredCredential {
  version: 2;
  authorityHash: string;
  accountHash: string;
  username: string;
  secret: string;
  generation: string;
}

interface CredentialIndexEntry {
  storageKey: string;
  authorityHash: string;
  accountHash: string;
  username: string;
}

interface StoredCredentialIndex {
  version: 2;
  entries: CredentialIndexEntry[];
}

interface AcquiredCredential {
  credential: Credential;
  persistenceIntent: CredentialPersistenceIntent;
  generation: string;
  source: "stored" | "session" | "prompt";
  baseGeneration?: string;
  acquisitionId: string;
}

interface PendingLease extends AcquiredCredential {
  leaseId: string;
  operationId: string;
  authorityHash: string;
  accountHash: string;
  storageKey: string;
  expiresAt: number;
  connectionEpoch: number;
}

interface LeaseTombstone {
  operationId: string;
  leaseId: string;
  outcome: CredentialSettlementOutcome;
  authorityHash: string;
  accountHash: string;
  generation: string;
  source: AcquiredCredential["source"];
  username: string;
  retryConsumed: boolean;
}

interface PromptFlight {
  compatibilityKey: string;
  promise: Promise<AcquiredCredential | CredentialResponse>;
}

interface StorageMutation {
  rollback(): Promise<void>;
}

interface OperationRequestState {
  epoch: number;
  inFlight: number;
  closed: boolean;
}

const NO_STORAGE_MUTATION: StorageMutation = { rollback: async () => undefined };

export function createCredentialController(options: CredentialControllerOptions): CredentialController {
  return new SecretStorageCredentialController(options);
}

export function discardCredentialOperationAfterBackendRequest(
  controller: Pick<CredentialController, "discardOperation">,
  params: unknown,
): void {
  if (!isRecord(params) || !isRecord(params.remote) || params.remote.version !== 1) {
    return;
  }
  const operationId = params.remote.operationId;
  if (isCanonicalId(operationId)) {
    controller.discardOperation(operationId);
  }
}

export function createCredentialRequestHandler(
  controller: CredentialController,
): (method: string, params: unknown) => Promise<CredentialResponse | CredentialSettlementAck> {
  return async (method, params) => {
    if (method === "credentials/request") {
      return await controller.handleCredentialRequest(parseCredentialRequest(params));
    }
    if (method === "credentials/settle") {
      return await controller.handleCredentialSettlement(parseCredentialSettlementRequest(params));
    }
    throw new CredentialRpcError("RPC_METHOD_NOT_FOUND", "unsupported", "error.rpc.methodNotFound", { method });
  };
}

class SecretStorageCredentialController implements CredentialController {
  private readonly sessionCredentials = new Map<string, StoredCredential>();
  private readonly pendingLeases = new Map<string, PendingLease>();
  private readonly tombstones = new Map<string, LeaseTombstone>();
  private readonly operationLeases = new Map<string, Set<string>>();
  private readonly promptFlights = new Map<string, PromptFlight>();
  private readonly acceptedGenerations = new Set<string>();
  private readonly settlementFlights = new Map<string, Promise<CredentialSettlementAck>>();
  private readonly operationRequests = new Map<string, OperationRequestState>();
  private storageQueue: Promise<void> = Promise.resolve();
  private legacyClearFlight: Promise<boolean | typeof PROMPT_TIMEOUT> | undefined;
  private legacyReady = false;
  private storageBlocked = false;
  private disposed = false;
  private connectionEpoch = 0;

  public constructor(private readonly options: CredentialControllerOptions) {}

  public async handleCredentialRequest(request: CredentialRequest): Promise<CredentialResponse> {
    const operationEpoch = this.beginOperationRequest(request.operationId);
    try {
      return await this.handleCredentialRequestInOperation(request, operationEpoch);
    } finally {
      this.finishOperationRequest(request.operationId);
    }
  }

  private async handleCredentialRequestInOperation(
    request: CredentialRequest,
    operationEpoch: number,
  ): Promise<CredentialResponse> {
    const connectionEpoch = this.connectionEpoch;
    const deadline = this.now() + request.timeoutMs;
    if (!this.operationRequestCurrent(request.operationId, operationEpoch)) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_CANCELLED, "auth", "error.auth.credentialCancelled");
    }
    if (this.disposed || !this.options.workspaceTrusted()) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE, "lifecycle", "error.auth.credentialUntrustedWorkspace");
    }
    if (this.storageBlocked) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_STORAGE_INTEGRITY, "auth", "error.auth.credentialStorageIntegrity");
    }
    const legacyReady = await withDeadline(
      deadline,
      () => this.now(),
      this.ensureLegacyReady(request, deadline, connectionEpoch, operationEpoch),
    );
    if (!this.operationRequestCurrent(request.operationId, operationEpoch)) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_CANCELLED, "auth", "error.auth.credentialCancelled");
    }
    if (this.disposed || !this.options.workspaceTrusted() || this.connectionEpoch !== connectionEpoch) {
      if (!this.disposed) {
        this.invalidateBackendConnection();
      }
      return cancel(request, SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE, "lifecycle", "error.auth.credentialUntrustedWorkspace");
    }
    if (legacyReady === PROMPT_TIMEOUT) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_TIMEOUT, "auth", "error.auth.credentialTimeout");
    }
    if (!legacyReady) {
      return cancel(
        request,
        request.origin === "foreground" && request.interactive
          ? SUBVERSIONR_CREDENTIAL_LEGACY_CLEAR_DECLINED
          : SUBVERSIONR_CREDENTIAL_LEGACY_BLOCKED,
        "auth",
        request.origin === "foreground" && request.interactive
          ? "error.auth.credentialLegacyClearDeclined"
          : "error.auth.credentialLegacyBlocked",
      );
    }
    if (this.pendingLeases.size >= MAX_ACTIVE_LEASES) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_STORAGE_INTEGRITY, "auth", "error.auth.credentialStorageIntegrity");
    }

    const authorityHash = credentialAuthorityHash(request);
    const acquisition = request.attempt.kind === "initial"
      ? this.acquireInitial(request, authorityHash, deadline)
      : this.acquireRetry(request, authorityHash, request.attempt.previousLeaseId, deadline);
    const acquired = await withDeadline(deadline, () => this.now(), acquisition);
    if (acquired === PROMPT_TIMEOUT) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_TIMEOUT, "auth", "error.auth.credentialTimeout");
    }
    if ("action" in acquired) {
      return {
        ...acquired,
        requestId: request.requestId,
        operationId: request.operationId,
      };
    }
    if (!this.operationRequestCurrent(request.operationId, operationEpoch)) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_CANCELLED, "auth", "error.auth.credentialCancelled");
    }
    if (this.disposed || !this.options.workspaceTrusted() || this.connectionEpoch !== connectionEpoch) {
      if (!this.disposed && !this.options.workspaceTrusted()) {
        this.invalidateBackendConnection();
      }
      return cancel(request, SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE, "lifecycle", "error.auth.credentialUntrustedWorkspace");
    }
    if (this.now() >= deadline) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_TIMEOUT, "auth", "error.auth.credentialTimeout");
    }
    return this.issueLease(request, authorityHash, acquired, deadline, connectionEpoch);
  }

  public async handleCredentialSettlement(request: CredentialSettlementRequest): Promise<CredentialSettlementAck> {
    const active = this.settlementFlights.get(request.leaseId);
    if (active) {
      await active;
      return await this.handleCredentialSettlement(request);
    }
    const flight = this.settleCredential(request);
    this.settlementFlights.set(request.leaseId, flight);
    try {
      return await flight;
    } finally {
      if (this.settlementFlights.get(request.leaseId) === flight) {
        this.settlementFlights.delete(request.leaseId);
      }
    }
  }

  public async clearSavedCredentials(): Promise<CredentialClearResult> {
    if (this.disposed) {
      throw storageIntegrityError();
    }
    return await this.serializeCleanup(async () => {
      this.invalidateBackendConnection();
      const index = await this.readV2Index();
      const legacy = await this.readLegacyIndex();
      for (const entry of index.entries) {
        await this.options.secretStorage.delete(entry.storageKey);
      }
      for (const key of legacy) {
        await this.options.secretStorage.delete(key);
      }
      if (index.entries.length > 0) {
        await this.options.secretStorage.delete(V2_INDEX_KEY);
      }
      if (legacy.length > 0) {
        await this.options.secretStorage.delete(LEGACY_INDEX_KEY);
      }
      this.sessionCredentials.clear();
      this.legacyReady = true;
      this.storageBlocked = false;
      return { deleted: index.entries.length + legacy.length };
    });
  }

  public discardOperation(operationId: string): void {
    const operationRequest = this.operationRequests.get(operationId);
    if (operationRequest) {
      operationRequest.epoch += 1;
      operationRequest.closed = true;
    }
    const ids = this.operationLeases.get(operationId);
    if (ids) {
      for (const leaseId of ids) {
        const lease = this.pendingLeases.get(leaseId);
        if (lease) {
          this.discardLease(lease);
        }
      }
      this.operationLeases.delete(operationId);
    }
    for (const [leaseId, tombstone] of this.tombstones) {
      if (tombstone.operationId === operationId) {
        this.tombstones.delete(leaseId);
      }
    }
  }

  public invalidateBackendConnection(): void {
    this.connectionEpoch += 1;
    this.pendingLeases.clear();
    this.operationLeases.clear();
    this.tombstones.clear();
    this.promptFlights.clear();
    this.settlementFlights.clear();
    this.legacyClearFlight = undefined;
    this.acceptedGenerations.clear();
  }

  public dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.invalidateBackendConnection();
    this.sessionCredentials.clear();
  }

  private async settleCredential(request: CredentialSettlementRequest): Promise<CredentialSettlementAck> {
    if (this.disposed || !this.options.workspaceTrusted()) {
      this.invalidateBackendConnection();
      throw settlementLifecycleError(request);
    }
    const lease = this.pendingLeases.get(request.leaseId);
    if (!lease) {
      return this.acknowledgeTombstone(request);
    }
    if (lease.operationId !== request.operationId) {
      throw leaseError(SUBVERSIONR_CREDENTIAL_LEASE_FOREIGN, "error.auth.credentialLeaseForeign", request);
    }
    if (lease.connectionEpoch !== this.connectionEpoch) {
      this.discardLease(lease);
      throw leaseError(SUBVERSIONR_CREDENTIAL_LEASE_UNKNOWN, "error.auth.credentialLeaseUnknown", request);
    }
    const deadline = Math.min(lease.expiresAt, this.now() + request.timeoutMs);
    if (this.now() >= lease.expiresAt && request.outcome !== "timedOut") {
      this.discardLease(lease);
      throw leaseError(SUBVERSIONR_CREDENTIAL_LEASE_EXPIRED, "error.auth.credentialLeaseExpired", request);
    }
    if (request.outcome === "accepted" || request.outcome === "rejected") {
      await this.serializeStorage(async () => {
        let mutation: StorageMutation = NO_STORAGE_MUTATION;
        let acceptedGenerationAdded = false;
        try {
          this.assertSettlementWritable(lease, deadline, request);
          mutation = request.outcome === "accepted"
            ? await this.acceptLease(lease, deadline, request)
            : await this.rejectLease(lease, deadline, request);
          this.assertSettlementWritable(lease, deadline, request);
          if (request.outcome === "accepted" && !this.acceptedGenerations.has(generationKey(lease))) {
            this.acceptedGenerations.add(generationKey(lease));
            acceptedGenerationAdded = true;
          }
          this.settleLease(lease, request.outcome);
        } catch (error) {
          if (acceptedGenerationAdded) {
            this.acceptedGenerations.delete(generationKey(lease));
          }
          await this.rollbackMutation(mutation);
          throw error;
        }
      });
      return settlementAck(request);
    }
    this.assertSettlementLifecycle(lease, request);
    this.settleLease(lease, request.outcome);
    return settlementAck(request);
  }

  private acknowledgeTombstone(request: CredentialSettlementRequest): CredentialSettlementAck {
    const tombstone = this.tombstones.get(request.leaseId);
    if (!tombstone) {
      throw leaseError(SUBVERSIONR_CREDENTIAL_LEASE_UNKNOWN, "error.auth.credentialLeaseUnknown", request);
    }
    if (tombstone.operationId !== request.operationId) {
      throw leaseError(SUBVERSIONR_CREDENTIAL_LEASE_FOREIGN, "error.auth.credentialLeaseForeign", request);
    }
    if (tombstone.outcome !== request.outcome) {
      throw leaseError(SUBVERSIONR_CREDENTIAL_SETTLEMENT_CONFLICT, "error.auth.credentialSettlementConflict", request);
    }
    return settlementAck(request);
  }

  private async acquireInitial(
    request: CredentialRequest,
    authorityHash: string,
    deadline: number,
  ): Promise<AcquiredCredential | CredentialResponse> {
    if (request.account.mode === "fixed") {
      const username = request.account.username;
      if (!request.interactive || request.origin === "background") {
        const stored = await this.readAvailableCredential(authorityHash, username);
        if (stored) {
          return stored;
        }
        return cancel(request, SUBVERSIONR_CREDENTIAL_ACCOUNT_UNAVAILABLE, "auth", "error.auth.credentialAccountUnavailable");
      }
      return await this.runPromptFlight(request, deadline, authorityHash, `fixed-initial\0${username}`, async () => {
        const stored = await this.readAvailableCredential(authorityHash, username);
        return stored ?? await this.promptForSecret(request, deadline, username, undefined);
      });
    }

    if (!request.interactive || request.origin !== "foreground") {
      return cancel(request, SUBVERSIONR_CREDENTIAL_NON_INTERACTIVE, "auth", "error.auth.credentialNonInteractive");
    }
    return await this.acquireChooserSingleFlight(request, authorityHash, deadline);
  }

  private async acquireRetry(
    request: CredentialRequest,
    authorityHash: string,
    previousLeaseId: string,
    deadline: number,
  ): Promise<AcquiredCredential | CredentialResponse> {
    const previous = this.tombstones.get(previousLeaseId);
    if (
      !previous ||
      previous.operationId !== request.operationId ||
      previous.outcome !== "rejected" ||
      previous.authorityHash !== authorityHash ||
      previous.retryConsumed ||
      (previous.source !== "stored" && previous.source !== "session")
    ) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_RETRY_INVALID, "auth", "error.auth.credentialRetryInvalid");
    }
    if (!request.interactive || request.origin !== "foreground") {
      return cancel(request, SUBVERSIONR_CREDENTIAL_NON_INTERACTIVE, "auth", "error.auth.credentialNonInteractive");
    }
    if (request.account.mode === "fixed" && request.account.username !== previous.username) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_RETRY_INVALID, "auth", "error.auth.credentialRetryInvalid");
    }
    previous.retryConsumed = true;
    return await this.acquirePromptSingleFlight(
      request,
      authorityHash,
      previous.username,
      previous.generation,
      deadline,
    );
  }

  private async acquireChooserSingleFlight(
    request: CredentialRequest,
    authorityHash: string,
    deadline: number,
  ): Promise<AcquiredCredential | CredentialResponse> {
    return await this.runPromptFlight(request, deadline, authorityHash, "chooseForeground", async () => {
      const accounts = await this.readAccounts(authorityHash);
      const uiRequest = this.requestWithRemainingTimeout(request, deadline);
      if (!uiRequest) {
        return cancel(request, SUBVERSIONR_CREDENTIAL_TIMEOUT, "auth", "error.auth.credentialTimeout");
      }
      const selected = await withDeadline(deadline, () => this.now(), this.options.ui.pickAccount(uiRequest, accounts));
      if (selected === PROMPT_TIMEOUT) {
        return cancel(request, SUBVERSIONR_CREDENTIAL_TIMEOUT, "auth", "error.auth.credentialTimeout");
      }
      if (selected === undefined) {
        return cancel(request, SUBVERSIONR_CREDENTIAL_CANCELLED, "auth", "error.auth.credentialCancelled");
      }
      const username = normalizeUsername(selected);
      if (!username) {
        throw invalidParams("account.username");
      }
      const stored = await this.readAvailableCredential(authorityHash, username);
      if (stored) {
        return stored;
      }
      return await this.promptForSecret(request, deadline, username, undefined);
    });
  }

  private async acquirePromptSingleFlight(
    request: CredentialRequest,
    authorityHash: string,
    username: string,
    baseGeneration: string | undefined,
    deadline: number,
  ): Promise<AcquiredCredential | CredentialResponse> {
    return await this.runPromptFlight(request, deadline, authorityHash, `fixed\0${username}\0${baseGeneration ?? ""}`, async () =>
      await this.promptForSecret(request, deadline, username, baseGeneration));
  }

  private async runPromptFlight(
    request: CredentialRequest,
    deadline: number,
    authorityHash: string,
    compatibilityKey: string,
    factory: () => Promise<AcquiredCredential | CredentialResponse>,
  ): Promise<AcquiredCredential | CredentialResponse> {
    const active = this.promptFlights.get(authorityHash);
    if (active) {
      const result = await withDeadline(deadline, () => this.now(), active.promise);
      if (result === PROMPT_TIMEOUT) {
        return cancel(request, SUBVERSIONR_CREDENTIAL_TIMEOUT, "auth", "error.auth.credentialTimeout");
      }
      if (active.compatibilityKey === compatibilityKey) {
        return result;
      }
      return await this.runPromptFlight(request, deadline, authorityHash, compatibilityKey, factory);
    }
    const promise = factory();
    this.promptFlights.set(authorityHash, { compatibilityKey, promise });
    try {
      return await promise;
    } finally {
      if (this.promptFlights.get(authorityHash)?.promise === promise) {
        this.promptFlights.delete(authorityHash);
      }
    }
  }

  private async promptForSecret(
    request: CredentialRequest,
    deadline: number,
    username: string,
    baseGeneration: string | undefined,
  ): Promise<AcquiredCredential | CredentialResponse> {
    const secretRequest = this.requestWithRemainingTimeout(request, deadline);
    if (!secretRequest) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_TIMEOUT, "auth", "error.auth.credentialTimeout");
    }
    const secret = await withDeadline(deadline, () => this.now(), this.options.ui.promptSecret(secretRequest, username));
    if (secret === PROMPT_TIMEOUT) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_TIMEOUT, "auth", "error.auth.credentialTimeout");
    }
    if (secret === undefined) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_CANCELLED, "auth", "error.auth.credentialCancelled");
    }
    if (!isValidSecret(secret)) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_SECRET_INVALID, "auth", "error.auth.credentialSecretInvalid");
    }
    if (!request.persistenceAllowed) {
      return {
        credential: { username, secret },
        persistenceIntent: "session",
        generation: this.createId(),
        source: "prompt",
        baseGeneration,
        acquisitionId: this.createId(),
      };
    }
    const persistenceRequest = this.requestWithRemainingTimeout(request, deadline);
    if (!persistenceRequest) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_TIMEOUT, "auth", "error.auth.credentialTimeout");
    }
    const persistence = await withDeadline(deadline, () => this.now(), this.options.ui.pickPersistence(persistenceRequest));
    if (persistence === PROMPT_TIMEOUT) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_TIMEOUT, "auth", "error.auth.credentialTimeout");
    }
    if (persistence === undefined) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_CANCELLED, "auth", "error.auth.credentialCancelled");
    }
    return {
      credential: { username, secret },
      persistenceIntent: persistence,
      generation: this.createId(),
      source: "prompt",
      baseGeneration,
      acquisitionId: this.createId(),
    };
  }

  private issueLease(
    request: CredentialRequest,
    authorityHash: string,
    acquired: AcquiredCredential,
    deadline: number,
    connectionEpoch: number,
  ): CredentialResponse {
    const accountHash = credentialAccountHash(acquired.credential.username);
    const leaseId = this.createId();
    const lease: PendingLease = {
      ...acquired,
      leaseId,
      operationId: request.operationId,
      authorityHash,
      accountHash,
      storageKey: credentialStorageKey(authorityHash, accountHash),
      expiresAt: deadline,
      connectionEpoch,
    };
    this.pendingLeases.set(leaseId, lease);
    const operation = this.operationLeases.get(request.operationId) ?? new Set<string>();
    operation.add(leaseId);
    this.operationLeases.set(request.operationId, operation);
    return {
      requestId: request.requestId,
      operationId: request.operationId,
      action: "provide",
      leaseId,
      credential: { ...acquired.credential },
      persistenceIntent: acquired.persistenceIntent,
    };
  }

  private async readAvailableCredential(authorityHash: string, username: string): Promise<AcquiredCredential | undefined> {
    const accountHash = credentialAccountHash(username);
    const storageKey = credentialStorageKey(authorityHash, accountHash);
    const session = this.sessionCredentials.get(storageKey);
    if (session) {
      return acquiredFromStored(session, "session", this.createId());
    }
    return await this.serializeStorage(async () => {
      const index = await this.readV2Index();
      const metadata = index.entries.find((entry) => entry.storageKey === storageKey);
      if (!metadata) {
        return undefined;
      }
      if (metadata.authorityHash !== authorityHash || metadata.accountHash !== accountHash || metadata.username !== username) {
        throw storageIntegrityError();
      }
      const stored = await this.readStoredCredential(metadata);
      return acquiredFromStored(stored, "stored", this.createId());
    });
  }

  private async readAccounts(authorityHash: string): Promise<string[]> {
    return await this.serializeStorage(async () => {
      const index = await this.readV2Index();
      const accounts = new Set(
        index.entries.filter((entry) => entry.authorityHash === authorityHash).map((entry) => entry.username),
      );
      for (const credential of this.sessionCredentials.values()) {
        if (credential.authorityHash === authorityHash) {
          accounts.add(credential.username);
        }
      }
      return [...accounts];
    });
  }

  private async acceptLease(
    lease: PendingLease,
    deadline: number,
    request: CredentialSettlementRequest,
  ): Promise<StorageMutation> {
    const stored: StoredCredential = {
      version: 2,
      authorityHash: lease.authorityHash,
      accountHash: lease.accountHash,
      username: lease.credential.username,
      secret: lease.credential.secret,
      generation: lease.generation,
    };
    if (lease.persistenceIntent === "session") {
      const current = this.sessionCredentials.get(lease.storageKey);
      if (!current || current.generation === lease.baseGeneration || current.generation === lease.generation) {
        this.assertSettlementWritable(lease, deadline, request);
        this.sessionCredentials.set(lease.storageKey, stored);
        return {
          rollback: async () => {
            if (current) {
              this.sessionCredentials.set(lease.storageKey, current);
            } else {
              this.sessionCredentials.delete(lease.storageKey);
            }
          },
        };
      }
      return NO_STORAGE_MUTATION;
    }

    const index = await this.readV2Index();
    const metadata = index.entries.find((entry) => entry.storageKey === lease.storageKey);
    if (metadata) {
      const current = await this.readStoredCredential(metadata);
      if (current.generation !== lease.generation && current.generation !== lease.baseGeneration) {
        return NO_STORAGE_MUTATION;
      }
      if (current.generation === lease.generation) {
        return NO_STORAGE_MUTATION;
      }
      const previous = JSON.stringify(current);
      let attempted = false;
      const mutation: StorageMutation = {
        rollback: async () => {
          if (attempted) {
            await this.options.secretStorage.store(lease.storageKey, previous);
          }
        },
      };
      try {
        this.assertSettlementWritable(lease, deadline, request);
        attempted = true;
        await this.options.secretStorage.store(lease.storageKey, JSON.stringify(stored));
        return mutation;
      } catch (error) {
        await this.rollbackMutation(mutation);
        throw error;
      }
    }
    const nextEntry: CredentialIndexEntry = {
      storageKey: lease.storageKey,
      authorityHash: lease.authorityHash,
      accountHash: lease.accountHash,
      username: lease.credential.username,
    };
    if (index.entries.length >= MAX_INDEX_ENTRIES) {
      throw storageIntegrityError();
    }
    const previousIndex = index.entries.length === 0 ? undefined : JSON.stringify(index);
    let indexAttempted = false;
    let credentialAttempted = false;
    const mutation: StorageMutation = {
      rollback: async () => {
        if (credentialAttempted) {
          await this.options.secretStorage.delete(lease.storageKey);
        }
        if (indexAttempted) {
          if (previousIndex === undefined) {
            await this.options.secretStorage.delete(V2_INDEX_KEY);
          } else {
            await this.options.secretStorage.store(V2_INDEX_KEY, previousIndex);
          }
        }
      },
    };
    try {
      this.assertSettlementWritable(lease, deadline, request);
      indexAttempted = true;
      await this.options.secretStorage.store(V2_INDEX_KEY, JSON.stringify({ version: 2, entries: [...index.entries, nextEntry] }));
      this.assertSettlementWritable(lease, deadline, request);
      credentialAttempted = true;
      await this.options.secretStorage.store(lease.storageKey, JSON.stringify(stored));
      return mutation;
    } catch (error) {
      await this.rollbackMutation(mutation);
      throw error;
    }
  }

  private async rejectLease(
    lease: PendingLease,
    deadline: number,
    request: CredentialSettlementRequest,
  ): Promise<StorageMutation> {
    if (this.acceptedGenerations.has(generationKey(lease))) {
      return NO_STORAGE_MUTATION;
    }
    if (lease.source === "session") {
      const current = this.sessionCredentials.get(lease.storageKey);
      if (current?.generation === lease.generation) {
        this.assertSettlementWritable(lease, deadline, request);
        this.sessionCredentials.delete(lease.storageKey);
        return {
          rollback: async () => {
            this.sessionCredentials.set(lease.storageKey, current);
          },
        };
      }
      return NO_STORAGE_MUTATION;
    }
    if (lease.source !== "stored") {
      return NO_STORAGE_MUTATION;
    }
    const index = await this.readV2Index();
    const metadata = index.entries.find((entry) => entry.storageKey === lease.storageKey);
    if (!metadata) {
      return NO_STORAGE_MUTATION;
    }
    const current = await this.readStoredCredential(metadata);
    if (current.generation !== lease.generation) {
      return NO_STORAGE_MUTATION;
    }
    const remaining = index.entries.filter((entry) => entry.storageKey !== lease.storageKey);
    const previousCredential = JSON.stringify(current);
    const previousIndex = JSON.stringify(index);
    let credentialAttempted = false;
    let indexAttempted = false;
    const mutation: StorageMutation = {
      rollback: async () => {
        if (credentialAttempted) {
          await this.options.secretStorage.store(lease.storageKey, previousCredential);
        }
        if (indexAttempted) {
          await this.options.secretStorage.store(V2_INDEX_KEY, previousIndex);
        }
      },
    };
    try {
      this.assertSettlementWritable(lease, deadline, request);
      credentialAttempted = true;
      await this.options.secretStorage.delete(lease.storageKey);
      this.assertSettlementWritable(lease, deadline, request);
      indexAttempted = true;
      if (remaining.length === 0) {
        await this.options.secretStorage.delete(V2_INDEX_KEY);
      } else {
        await this.options.secretStorage.store(V2_INDEX_KEY, JSON.stringify({ version: 2, entries: remaining }));
      }
      return mutation;
    } catch (error) {
      await this.rollbackMutation(mutation);
      throw error;
    }
  }

  private hasUnsettledSibling(lease: PendingLease): boolean {
    for (const candidate of this.pendingLeases.values()) {
      if (
        candidate.leaseId !== lease.leaseId &&
        candidate.authorityHash === lease.authorityHash &&
        candidate.accountHash === lease.accountHash &&
        candidate.generation === lease.generation
      ) {
        return true;
      }
    }
    return false;
  }

  private async ensureLegacyReady(
    request: CredentialRequest,
    deadline: number,
    connectionEpoch: number,
    operationEpoch: number,
  ): Promise<boolean | typeof PROMPT_TIMEOUT> {
    if (this.legacyReady) {
      return true;
    }
    if (this.legacyClearFlight) {
      return await withDeadline(deadline, () => this.now(), this.legacyClearFlight);
    }
    const legacy = await withDeadline(
      deadline,
      () => this.now(),
      this.serializeStorage(async () => await this.readLegacyIndex()),
    );
    if (legacy === PROMPT_TIMEOUT) {
      return PROMPT_TIMEOUT;
    }
    if (!this.requestLifecycleCurrent(request.operationId, operationEpoch, deadline, connectionEpoch)) {
      return this.now() >= deadline ? PROMPT_TIMEOUT : false;
    }
    if (legacy.length === 0) {
      this.legacyReady = true;
      return true;
    }
    if (!request.interactive || request.origin !== "foreground") {
      return false;
    }
    const flight = (async () => {
      const uiRequest = this.requestWithRemainingTimeout(request, deadline);
      if (!uiRequest) {
        return PROMPT_TIMEOUT;
      }
      const confirmed = await withDeadline(
        deadline,
        () => this.now(),
        this.options.ui.confirmLegacyClear(uiRequest, legacy.length),
      );
      if (confirmed === PROMPT_TIMEOUT) {
        return PROMPT_TIMEOUT;
      }
      if (confirmed !== true) {
        return false;
      }
      if (!this.requestLifecycleCurrent(request.operationId, operationEpoch, deadline, connectionEpoch)) {
        return this.now() >= deadline ? PROMPT_TIMEOUT : false;
      }
      try {
        await this.serializeStorage(async () => {
          this.assertRequestLifecycle(request, operationEpoch, deadline, connectionEpoch);
          const current = await this.readLegacyIndex();
          this.assertRequestLifecycle(request, operationEpoch, deadline, connectionEpoch);
          const snapshots = new Map<string, string>();
          for (const key of current) {
            const value = await this.options.secretStorage.get(key);
            this.assertRequestLifecycle(request, operationEpoch, deadline, connectionEpoch);
            if (value === undefined) {
              throw storageIntegrityError();
            }
            snapshots.set(key, value);
          }
          let indexDeleteAttempted = false;
          const deleted = new Set<string>();
          const mutation: StorageMutation = {
            rollback: async () => {
              for (const key of deleted) {
                await this.options.secretStorage.store(key, snapshots.get(key)!);
              }
              if (indexDeleteAttempted) {
                await this.options.secretStorage.store(
                  LEGACY_INDEX_KEY,
                  JSON.stringify({ version: 1, keys: current }),
                );
              }
            },
          };
          try {
            for (const key of current) {
              deleted.add(key);
              await this.options.secretStorage.delete(key);
              this.assertRequestLifecycle(request, operationEpoch, deadline, connectionEpoch);
            }
            indexDeleteAttempted = true;
            await this.options.secretStorage.delete(LEGACY_INDEX_KEY);
            this.assertRequestLifecycle(request, operationEpoch, deadline, connectionEpoch);
          } catch (error) {
            await this.rollbackMutation(mutation);
            throw error;
          }
        });
      } catch (error) {
        if (error instanceof CredentialRpcError && error.code === SUBVERSIONR_CREDENTIAL_TIMEOUT) {
          return PROMPT_TIMEOUT;
        }
        if (
          error instanceof CredentialRpcError &&
          (error.code === SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE || error.code === SUBVERSIONR_CREDENTIAL_CANCELLED)
        ) {
          return false;
        }
        throw error;
      }
      if (!this.requestLifecycleCurrent(request.operationId, operationEpoch, deadline, connectionEpoch)) {
        return this.now() >= deadline ? PROMPT_TIMEOUT : false;
      }
      this.legacyReady = true;
      return true;
    })();
    this.legacyClearFlight = flight;
    try {
      return await flight;
    } finally {
      if (this.legacyClearFlight === flight) {
        this.legacyClearFlight = undefined;
      }
    }
  }

  private async readLegacyIndex(): Promise<string[]> {
    const raw = await this.options.secretStorage.get(LEGACY_INDEX_KEY);
    if (raw === undefined) {
      return [];
    }
    try {
      const parsed = JSON.parse(raw) as unknown;
      if (!isRecord(parsed) || !hasExactKeys(parsed, ["version", "keys"]) || parsed.version !== 1 || !Array.isArray(parsed.keys)) {
        throw storageIntegrityError();
      }
      const keys = parsed.keys;
      if (
        keys.length === 0 ||
        keys.length > MAX_INDEX_ENTRIES ||
        keys.some((key) => typeof key !== "string" || !key.startsWith(LEGACY_ENTRY_PREFIX)) ||
        new Set(keys).size !== keys.length
      ) {
        throw storageIntegrityError();
      }
      return keys as string[];
    } catch (error) {
      this.storageBlocked = true;
      throw error instanceof CredentialRpcError ? error : storageIntegrityError();
    }
  }

  private async readV2Index(): Promise<StoredCredentialIndex> {
    const raw = await this.options.secretStorage.get(V2_INDEX_KEY);
    if (raw === undefined) {
      return { version: 2, entries: [] };
    }
    try {
      const parsed = JSON.parse(raw) as unknown;
      if (!isRecord(parsed) || !hasExactKeys(parsed, ["version", "entries"]) || parsed.version !== 2 || !Array.isArray(parsed.entries)) {
        throw storageIntegrityError();
      }
      if (parsed.entries.length === 0 || parsed.entries.length > MAX_INDEX_ENTRIES) {
        throw storageIntegrityError();
      }
      const entries = parsed.entries.map(parseIndexEntry);
      const keys = new Set(entries.map((entry) => entry.storageKey));
      const accounts = new Set(entries.map((entry) => `${entry.authorityHash}\0${entry.accountHash}`));
      if (keys.size !== entries.length || accounts.size !== entries.length) {
        throw storageIntegrityError();
      }
      return { version: 2, entries };
    } catch (error) {
      this.storageBlocked = true;
      throw error instanceof CredentialRpcError ? error : storageIntegrityError();
    }
  }

  private async readStoredCredential(metadata: CredentialIndexEntry): Promise<StoredCredential> {
    const raw = await this.options.secretStorage.get(metadata.storageKey);
    if (raw === undefined) {
      this.storageBlocked = true;
      throw storageIntegrityError();
    }
    try {
      const parsed = JSON.parse(raw) as unknown;
      if (
        !isRecord(parsed) ||
        !hasExactKeys(parsed, ["version", "authorityHash", "accountHash", "username", "secret", "generation"]) ||
        parsed.version !== 2 ||
        parsed.authorityHash !== metadata.authorityHash ||
        parsed.accountHash !== metadata.accountHash ||
        parsed.username !== metadata.username ||
        typeof parsed.secret !== "string" ||
        !isValidSecret(parsed.secret) ||
        !isCanonicalId(parsed.generation)
      ) {
        throw storageIntegrityError();
      }
      return parsed as unknown as StoredCredential;
    } catch (error) {
      this.storageBlocked = true;
      throw error instanceof CredentialRpcError ? error : storageIntegrityError();
    }
  }

  private settleLease(lease: PendingLease, outcome: CredentialSettlementOutcome): void {
    this.pendingLeases.delete(lease.leaseId);
    this.removeOperationLease(lease.operationId, lease.leaseId);
    this.addTombstone(lease, outcome);
    if (!this.hasUnsettledSibling(lease)) {
      this.acceptedGenerations.delete(generationKey(lease));
    }
  }

  private discardLease(lease: PendingLease): void {
    this.pendingLeases.delete(lease.leaseId);
    this.removeOperationLease(lease.operationId, lease.leaseId);
    if (!this.hasUnsettledSibling(lease)) {
      this.acceptedGenerations.delete(generationKey(lease));
    }
  }

  private addTombstone(lease: PendingLease, outcome: CredentialSettlementOutcome): void {
    if (this.tombstones.size >= MAX_TOMBSTONES) {
      this.storageBlocked = true;
      throw storageIntegrityError();
    }
    this.tombstones.set(lease.leaseId, {
      operationId: lease.operationId,
      leaseId: lease.leaseId,
      outcome,
      authorityHash: lease.authorityHash,
      accountHash: lease.accountHash,
      generation: lease.generation,
      source: lease.source,
      username: lease.credential.username,
      retryConsumed: false,
    });
  }

  private removeOperationLease(operationId: string, leaseId: string): void {
    const operation = this.operationLeases.get(operationId);
    operation?.delete(leaseId);
    if (operation?.size === 0) {
      this.operationLeases.delete(operationId);
    }
  }

  private assertSettlementLifecycle(lease: PendingLease, request: CredentialSettlementRequest): void {
    if (this.disposed || !this.options.workspaceTrusted()) {
      this.invalidateBackendConnection();
      throw settlementLifecycleError(request);
    }
    if (lease.connectionEpoch !== this.connectionEpoch || this.pendingLeases.get(lease.leaseId) !== lease) {
      throw leaseError(SUBVERSIONR_CREDENTIAL_LEASE_UNKNOWN, "error.auth.credentialLeaseUnknown", request);
    }
  }

  private assertSettlementWritable(
    lease: PendingLease,
    deadline: number,
    request: CredentialSettlementRequest,
  ): void {
    this.assertSettlementLifecycle(lease, request);
    if (this.now() >= deadline) {
      throw leaseError(SUBVERSIONR_CREDENTIAL_TIMEOUT, "error.auth.credentialTimeout", request);
    }
  }

  private requestWithRemainingTimeout(request: CredentialRequest, deadline: number): CredentialRequest | undefined {
    const remaining = Math.ceil(deadline - this.now());
    if (remaining <= 0) {
      return undefined;
    }
    return { ...request, timeoutMs: remaining };
  }

  private beginOperationRequest(operationId: string): number {
    const state = this.operationRequests.get(operationId) ?? { epoch: 0, inFlight: 0, closed: false };
    state.inFlight += 1;
    this.operationRequests.set(operationId, state);
    return state.epoch;
  }

  private finishOperationRequest(operationId: string): void {
    const state = this.operationRequests.get(operationId);
    if (!state) {
      return;
    }
    state.inFlight -= 1;
    if (state.inFlight === 0) {
      this.operationRequests.delete(operationId);
    }
  }

  private operationRequestCurrent(operationId: string, operationEpoch: number): boolean {
    const state = this.operationRequests.get(operationId);
    return state?.epoch === operationEpoch && !state.closed;
  }

  private requestLifecycleCurrent(
    operationId: string,
    operationEpoch: number,
    deadline: number,
    connectionEpoch: number,
  ): boolean {
    return !this.disposed &&
      this.options.workspaceTrusted() &&
      this.operationRequestCurrent(operationId, operationEpoch) &&
      this.connectionEpoch === connectionEpoch &&
      this.now() < deadline;
  }

  private assertRequestLifecycle(
    request: CredentialRequest,
    operationEpoch: number,
    deadline: number,
    connectionEpoch: number,
  ): void {
    if (this.now() >= deadline) {
      throw new CredentialRpcError(
        SUBVERSIONR_CREDENTIAL_TIMEOUT,
        "auth",
        "error.auth.credentialTimeout",
        safeCredentialArgs(request),
      );
    }
    if (!this.operationRequestCurrent(request.operationId, operationEpoch)) {
      throw new CredentialRpcError(
        SUBVERSIONR_CREDENTIAL_CANCELLED,
        "auth",
        "error.auth.credentialCancelled",
        safeCredentialArgs(request),
      );
    }
    if (this.disposed || !this.options.workspaceTrusted() || this.connectionEpoch !== connectionEpoch) {
      throw new CredentialRpcError(
        SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE,
        "lifecycle",
        "error.auth.credentialUntrustedWorkspace",
        safeCredentialArgs(request),
      );
    }
  }

  private async rollbackMutation(mutation: StorageMutation): Promise<void> {
    try {
      await mutation.rollback();
    } catch {
      this.storageBlocked = true;
      throw storageIntegrityError();
    }
  }

  private async serializeStorage<T>(operation: () => Promise<T>): Promise<T> {
    const previous = this.storageQueue;
    let release!: () => void;
    this.storageQueue = new Promise<void>((resolve) => { release = resolve; });
    await previous;
    try {
      if (this.storageBlocked) {
        throw storageIntegrityError();
      }
      return await operation();
    } catch (error) {
      if (!(error instanceof CredentialRpcError) || error.code === SUBVERSIONR_CREDENTIAL_STORAGE_INTEGRITY) {
        this.storageBlocked = true;
      }
      throw error instanceof CredentialRpcError ? error : storageIntegrityError();
    } finally {
      release();
    }
  }

  private async serializeCleanup<T>(operation: () => Promise<T>): Promise<T> {
    const previous = this.storageQueue;
    let release!: () => void;
    this.storageQueue = new Promise<void>((resolve) => { release = resolve; });
    await previous;
    try {
      return await operation();
    } catch (error) {
      this.storageBlocked = true;
      throw error instanceof CredentialRpcError ? error : storageIntegrityError();
    } finally {
      release();
    }
  }

  private now(): number {
    return this.options.now?.() ?? Date.now();
  }

  private createId(): string {
    return this.options.createId?.() ?? randomUUID();
  }
}

function parseCredentialRequest(params: unknown): CredentialRequest {
  const value = requireRecord(params, "params");
  requireExactKeys(value, ["requestId", "operationId", "endpoint", "authKind", "realm", "account", "attempt", "interactive", "persistenceAllowed", "origin", "timeoutMs"], "params");
  const endpoint = parseEndpoint(value.endpoint);
  const authKind = requireEnum(value.authKind, ["basic", "cramMd5"] as const, "authKind");
  if ((authKind === "cramMd5") !== (endpoint.scheme === "svn")) {
    throw invalidParams("authKind");
  }
  const operationId = requireCanonicalId(value.operationId, "operationId");
  const requestId = requireBoundedString(value.requestId, "requestId", 1, 128);
  const realm = requireBoundedString(value.realm, "realm", 1, 4096);
  if (realm.includes("\0") || Buffer.byteLength(realm, "utf8") > 4096) {
    throw invalidParams("realm");
  }
  const account = parseAccount(value.account);
  const attempt = parseAttempt(value.attempt);
  const origin = requireEnum(value.origin, ["foreground", "background"] as const, "origin");
  const interactive = requireBoolean(value.interactive, "interactive");
  const persistenceAllowed = requireBoolean(value.persistenceAllowed, "persistenceAllowed");
  if (origin === "background" && (interactive || account.mode !== "fixed")) {
    throw invalidParams("interactive");
  }
  const timeoutMs = requireInteger(value.timeoutMs, "timeoutMs", 1, 300_000);
  return { requestId, operationId, endpoint, authKind, realm, account, attempt, interactive, persistenceAllowed, origin, timeoutMs };
}

function parseCredentialSettlementRequest(params: unknown): CredentialSettlementRequest {
  const value = requireRecord(params, "params");
  requireExactKeys(value, ["requestId", "operationId", "leaseId", "outcome", "timeoutMs"], "params");
  return {
    requestId: requireBoundedString(value.requestId, "requestId", 1, 128),
    operationId: requireCanonicalId(value.operationId, "operationId"),
    leaseId: requireCanonicalId(value.leaseId, "leaseId"),
    outcome: requireEnum(value.outcome, ["accepted", "rejected", "unused", "cancelled", "timedOut"] as const, "outcome"),
    timeoutMs: requireInteger(value.timeoutMs, "timeoutMs", 1, 300_000),
  };
}

function parseEndpoint(value: unknown): CanonicalCredentialEndpoint {
  const endpoint = requireRecord(value, "endpoint");
  requireExactKeys(endpoint, ["scheme", "canonicalHost", "effectivePort"], "endpoint");
  const scheme = requireEnum(endpoint.scheme, ["http", "https", "svn"] as const, "endpoint.scheme");
  const canonicalHost = requireBoundedString(endpoint.canonicalHost, "endpoint.canonicalHost", 1, 253);
  if (!isCanonicalHost(canonicalHost)) {
    throw invalidParams("endpoint.canonicalHost");
  }
  return {
    scheme,
    canonicalHost,
    effectivePort: requireInteger(endpoint.effectivePort, "endpoint.effectivePort", 1, 65_535),
  };
}

function isCanonicalHost(host: string): boolean {
  if (!/^[\x00-\x7f]+$/u.test(host) || host !== host.toLowerCase()) {
    return false;
  }
  if (isIP(host) === 6) {
    try {
      return new URL(`http://[${host}]/`).hostname === `[${host}]`;
    } catch {
      return false;
    }
  }
  if (host.startsWith(".") || host.endsWith(".")) {
    return false;
  }
  return host.split(".").every((label) =>
    label.length > 0 &&
    label.length <= 63 &&
    !label.startsWith("-") &&
    !label.endsWith("-") &&
    /^[a-z0-9-]+$/u.test(label));
}

function parseAccount(value: unknown): CredentialAccountSelection {
  const account = requireRecord(value, "account");
  if (account.mode === "chooseForeground") {
    requireExactKeys(account, ["mode"], "account");
    return { mode: "chooseForeground" };
  }
  requireExactKeys(account, ["mode", "username"], "account");
  if (account.mode !== "fixed") {
    throw invalidParams("account.mode");
  }
  const username = normalizeUsername(account.username);
  if (!username) {
    throw invalidParams("account.username");
  }
  return { mode: "fixed", username };
}

function parseAttempt(value: unknown): CredentialAttempt {
  const attempt = requireRecord(value, "attempt");
  if (attempt.kind === "initial") {
    requireExactKeys(attempt, ["kind"], "attempt");
    return { kind: "initial" };
  }
  requireExactKeys(attempt, ["kind", "previousLeaseId"], "attempt");
  if (attempt.kind !== "retryAfterRejected") {
    throw invalidParams("attempt.kind");
  }
  return { kind: "retryAfterRejected", previousLeaseId: requireCanonicalId(attempt.previousLeaseId, "attempt.previousLeaseId") };
}

function parseIndexEntry(value: unknown): CredentialIndexEntry {
  const entry = requireRecord(value, "index.entries");
  requireExactKeys(entry, ["storageKey", "authorityHash", "accountHash", "username"], "index.entries");
  const authorityHash = requireHash(entry.authorityHash, "index.authorityHash");
  const accountHash = requireHash(entry.accountHash, "index.accountHash");
  const username = normalizeUsername(entry.username);
  const storageKey = requireBoundedString(entry.storageKey, "index.storageKey", 1, 256);
  if (!username || accountHash !== credentialAccountHash(username) || storageKey !== credentialStorageKey(authorityHash, accountHash)) {
    throw storageIntegrityError();
  }
  return { storageKey, authorityHash, accountHash, username };
}

function cancel(request: CredentialRequest, code: string, category: "auth" | "lifecycle", messageKey: string): CredentialResponse {
  return {
    requestId: request.requestId,
    operationId: request.operationId,
    action: "cancel",
    error: { code, category, messageKey, args: safeCredentialArgs(request), retryable: false },
  };
}

function settlementAck(request: CredentialSettlementRequest): CredentialSettlementAck {
  return {
    requestId: request.requestId,
    operationId: request.operationId,
    leaseId: request.leaseId,
    outcome: request.outcome,
  };
}

function leaseError(code: string, messageKey: string, request: CredentialSettlementRequest): CredentialRpcError {
  return new CredentialRpcError(code, "auth", messageKey, {
    operationHash: hashText(`operation\0${request.operationId}`),
    leaseHash: hashText(`lease\0${request.leaseId}`),
    outcome: request.outcome,
  });
}

function storageIntegrityError(): CredentialRpcError {
  return new CredentialRpcError(
    SUBVERSIONR_CREDENTIAL_STORAGE_INTEGRITY,
    "auth",
    "error.auth.credentialStorageIntegrity",
    {},
  );
}

function settlementLifecycleError(request: CredentialSettlementRequest): CredentialRpcError {
  return new CredentialRpcError(
    SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE,
    "lifecycle",
    "error.auth.credentialUntrustedWorkspace",
    {
      operationHash: hashText(`operation\0${request.operationId}`),
      leaseHash: hashText(`lease\0${request.leaseId}`),
    },
  );
}

function invalidParams(field: string): CredentialRpcError {
  return new CredentialRpcError("RPC_INVALID_PARAMS", "protocol", "error.rpc.invalidParams", { field });
}

function safeCredentialArgs(request: CredentialRequest): Record<string, unknown> {
  return {
    operationHash: hashText(`operation\0${request.operationId}`),
    authorityHash: credentialAuthorityHash(request),
    authKind: request.authKind,
    accountMode: request.account.mode,
    attempt: request.attempt.kind,
    origin: request.origin,
  };
}

function credentialAuthorityHash(request: CredentialRequest): string {
  return hashText(`${request.endpoint.scheme}\0${request.endpoint.canonicalHost}\0${request.endpoint.effectivePort}\0${request.authKind}\0${request.realm}`);
}

function credentialAccountHash(username: string): string {
  return hashText(`account\0${username}`);
}

function credentialStorageKey(authorityHash: string, accountHash: string): string {
  return `${V2_ENTRY_PREFIX}${authorityHash}.${accountHash}`;
}

function generationKey(lease: Pick<PendingLease, "authorityHash" | "accountHash" | "generation">): string {
  return `${lease.authorityHash}\0${lease.accountHash}\0${lease.generation}`;
}

function acquiredFromStored(stored: StoredCredential, source: "stored" | "session", acquisitionId: string): AcquiredCredential {
  return {
    credential: { username: stored.username, secret: stored.secret },
    persistenceIntent: source === "stored" ? "secretStorage" : "session",
    generation: stored.generation,
    source,
    baseGeneration: stored.generation,
    acquisitionId,
  };
}

async function withDeadline<T>(
  deadline: number,
  now: () => number,
  promise: Promise<T>,
): Promise<T | typeof PROMPT_TIMEOUT> {
  const remaining = Math.ceil(deadline - now());
  if (remaining <= 0) {
    return PROMPT_TIMEOUT;
  }
  return await new Promise<T | typeof PROMPT_TIMEOUT>((resolve, reject) => {
    const timeout = setTimeout(() => resolve(PROMPT_TIMEOUT), remaining);
    promise.then(
      (value) => { clearTimeout(timeout); resolve(value); },
      (error: unknown) => { clearTimeout(timeout); reject(error); },
    );
  });
}

function isValidSecret(value: string): boolean {
  return value.length > 0 && !value.includes("\0") && Buffer.byteLength(value, "utf8") <= MAX_SECRET_UTF8_BYTES;
}

function normalizeUsername(value: unknown): string | undefined {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    Buffer.byteLength(value, "utf8") > 256 ||
    value !== value.trim() ||
    /[\u0000-\u001f\u007f]/u.test(value)
  ) {
    return undefined;
  }
  return value;
}

function hashText(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function requireRecord(value: unknown, field: string): Record<string, unknown> {
  if (!isRecord(value)) {
    throw invalidParams(field);
  }
  return value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  return actual.length === expected.length && actual.every((key, index) => key === expected[index]);
}

function requireExactKeys(value: Record<string, unknown>, keys: readonly string[], field: string): void {
  if (!hasExactKeys(value, keys)) {
    throw invalidParams(field);
  }
}

function requireBoundedString(value: unknown, field: string, minimum: number, maximum: number): string {
  if (typeof value !== "string" || value.length < minimum || value.length > maximum) {
    throw invalidParams(field);
  }
  return value;
}

function requireBoolean(value: unknown, field: string): boolean {
  if (typeof value !== "boolean") {
    throw invalidParams(field);
  }
  return value;
}

function requireInteger(value: unknown, field: string, minimum: number, maximum: number): number {
  if (!Number.isSafeInteger(value) || (value as number) < minimum || (value as number) > maximum) {
    throw invalidParams(field);
  }
  return value as number;
}

function requireEnum<const T extends string>(value: unknown, values: readonly T[], field: string): T {
  if (typeof value !== "string" || !values.includes(value as T)) {
    throw invalidParams(field);
  }
  return value as T;
}

function requireCanonicalId(value: unknown, field: string): string {
  if (!isCanonicalId(value)) {
    throw invalidParams(field);
  }
  return value;
}

function isCanonicalId(value: unknown): value is string {
  return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(value);
}

function requireHash(value: unknown, field: string): string {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/u.test(value)) {
    throw invalidParams(field);
  }
  return value;
}

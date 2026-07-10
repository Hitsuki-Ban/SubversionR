import { createHash } from "node:crypto";

export const SUBVERSIONR_CREDENTIAL_CANCELLED = "SUBVERSIONR_CREDENTIAL_CANCELLED";
export const SUBVERSIONR_CREDENTIAL_NON_INTERACTIVE = "SUBVERSIONR_CREDENTIAL_NON_INTERACTIVE";
export const SUBVERSIONR_CREDENTIAL_REALM_REQUIRED = "SUBVERSIONR_CREDENTIAL_REALM_REQUIRED";
export const SUBVERSIONR_CREDENTIAL_INDEX_INVALID = "SUBVERSIONR_CREDENTIAL_INDEX_INVALID";
export const SUBVERSIONR_CREDENTIAL_STORE_INVALID = "SUBVERSIONR_CREDENTIAL_STORE_INVALID";
export const SUBVERSIONR_CREDENTIAL_TIMEOUT = "SUBVERSIONR_CREDENTIAL_TIMEOUT";
export const SUBVERSIONR_CREDENTIAL_UNSUPPORTED_KIND = "SUBVERSIONR_CREDENTIAL_UNSUPPORTED_KIND";
export const SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE = "SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE";

const CREDENTIAL_PROMPT_TIMEOUT = Symbol("credentialPromptTimeout");

export type CredentialKind = "usernamePassword" | "proxyPassword" | "clientCertificatePassword" | "sshPassphrase";
export type CredentialPersistence = "secretStorage" | "session";

export interface CredentialRequest {
  requestId: string;
  realm: string;
  kind: CredentialKind;
  username?: string;
  interactive: boolean;
  persistenceAllowed: boolean;
  origin: "foreground" | "background";
  timeoutMs: number;
  repositoryId?: string;
  workingCopyRoot?: string;
}

export interface Credential {
  username?: string;
  secret: string;
}

export type CredentialResponse =
  | {
      requestId: string;
      action: "provide";
      credential: Credential;
      persistence: CredentialPersistence;
    }
  | {
      requestId: string;
      action: "cancel";
      error: CredentialError;
    };

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
  promptUsername(request: CredentialRequest): Promise<string | undefined>;
  promptSecret(request: CredentialRequest, username: string | undefined): Promise<string | undefined>;
  pickPersistence(request: CredentialRequest): Promise<CredentialPersistence | undefined>;
}

export interface CredentialControllerOptions {
  workspaceTrusted(): boolean;
  secretStorage: CredentialSecretStorage;
  ui: CredentialPromptUi;
}

export interface CredentialController {
  handleCredentialRequest(request: CredentialRequest): Promise<CredentialResponse>;
  clearSavedCredentials(): Promise<CredentialClearResult>;
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
  version: 1;
  username?: string;
  secret: string;
}

interface StoredCredentialIndex {
  version: 1;
  keys: string[];
}

const CREDENTIAL_INDEX_KEY = "subversionr.credential.index.v1";

const SUPPORTED_CREDENTIAL_KINDS: readonly CredentialKind[] = [
  "usernamePassword",
  "proxyPassword",
  "clientCertificatePassword",
  "sshPassphrase",
];

export function createCredentialController(options: CredentialControllerOptions): CredentialController {
  return new SecretStorageCredentialController(options);
}

export function createCredentialRequestHandler(
  controller: CredentialController,
): (method: string, params: unknown) => Promise<CredentialResponse> {
  return async (method, params) => {
    if (method !== "credentials/request") {
      throw new CredentialRpcError("RPC_METHOD_NOT_FOUND", "unsupported", "error.rpc.methodNotFound", {
        method,
      });
    }
    return await controller.handleCredentialRequest(parseCredentialRequest(params));
  };
}

class SecretStorageCredentialController implements CredentialController {
  private readonly pendingInteractivePrompts = new Map<string, Promise<CredentialResponse>>();
  private readonly sessionCredentials = new Map<string, StoredCredential>();

  public constructor(private readonly options: CredentialControllerOptions) {}

  public async handleCredentialRequest(request: CredentialRequest): Promise<CredentialResponse> {
    if (!this.options.workspaceTrusted()) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE, "lifecycle", "error.auth.credentialUntrustedWorkspace");
    }
    if (request.realm.trim().length === 0) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_REALM_REQUIRED, "auth", "error.auth.credentialRealmRequired");
    }
    if (!isSupportedCredentialKind(request.kind)) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_UNSUPPORTED_KIND, "auth", "error.auth.credentialUnsupportedKind");
    }

    const storageKey = credentialStorageKey(request);
    const sessionCredential = this.sessionCredentials.get(storageKey);
    if (sessionCredential !== undefined && usernameIsValidForKind(request.kind, sessionCredential.username)) {
      return {
        requestId: request.requestId,
        action: "provide",
        credential: credential(sessionCredential.username, sessionCredential.secret),
        persistence: "session",
      };
    }

    const stored = await readStoredCredential(this.options.secretStorage, storageKey, request);
    if ("action" in stored) {
      return stored;
    }
    if (stored.credential) {
      return {
        requestId: request.requestId,
        action: "provide",
        credential: {
          username: stored.credential.username,
          secret: stored.credential.secret,
        },
        persistence: "secretStorage",
      };
    }

    if (!request.interactive || request.origin === "background") {
      return cancel(request, SUBVERSIONR_CREDENTIAL_NON_INTERACTIVE, "auth", "error.auth.credentialNonInteractive");
    }

    const pendingPrompt = this.pendingInteractivePrompts.get(storageKey);
    if (pendingPrompt) {
      return withRequestId(await pendingPrompt, request.requestId, request);
    }

    const prompt = this.promptForCredential(request, storageKey);
    this.pendingInteractivePrompts.set(storageKey, prompt);
    try {
      return withRequestId(await prompt, request.requestId, request);
    } finally {
      if (this.pendingInteractivePrompts.get(storageKey) === prompt) {
        this.pendingInteractivePrompts.delete(storageKey);
      }
    }
  }

  public async clearSavedCredentials(): Promise<CredentialClearResult> {
    const index = await readCredentialIndex(this.options.secretStorage);
    this.sessionCredentials.clear();
    if (index === undefined) {
      return { deleted: 0 };
    }

    for (const key of index.keys) {
      await this.options.secretStorage.delete(key);
    }
    await this.options.secretStorage.delete(CREDENTIAL_INDEX_KEY);
    return { deleted: index.keys.length };
  }

  private async promptForCredential(request: CredentialRequest, storageKey: string): Promise<CredentialResponse> {
    const usernameResult = await this.resolveUsername(request);
    if (usernameResult.action === "cancel") {
      return usernameResult.response;
    }
    const username = usernameResult.username;

    const secret = await withCredentialTimeout(request, this.options.ui.promptSecret(request, username));
    if (secret === CREDENTIAL_PROMPT_TIMEOUT) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_TIMEOUT, "auth", "error.auth.credentialTimeout");
    }
    if (secret === undefined) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_CANCELLED, "auth", "error.auth.credentialCancelled");
    }

    const persistence = request.persistenceAllowed
      ? await withCredentialTimeout(request, this.options.ui.pickPersistence(request))
      : "session";
    if (persistence === CREDENTIAL_PROMPT_TIMEOUT) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_TIMEOUT, "auth", "error.auth.credentialTimeout");
    }
    if (persistence === undefined) {
      return cancel(request, SUBVERSIONR_CREDENTIAL_CANCELLED, "auth", "error.auth.credentialCancelled");
    }
    const storedCredential =
      username === undefined
        ? ({ version: 1, secret } satisfies StoredCredential)
        : ({ version: 1, username, secret } satisfies StoredCredential);
    if (persistence === "secretStorage") {
      const index = await readCredentialIndex(this.options.secretStorage);
      await this.options.secretStorage.store(
        CREDENTIAL_INDEX_KEY,
        JSON.stringify(credentialIndexWithKey(index, storageKey)),
      );
      await this.options.secretStorage.store(
        storageKey,
        JSON.stringify(storedCredential),
      );
    } else if (request.persistenceAllowed) {
      this.sessionCredentials.set(storageKey, storedCredential);
    }

    return {
      requestId: request.requestId,
      action: "provide",
      credential: credential(username, secret),
      persistence,
    };
  }

  private async resolveUsername(
    request: CredentialRequest,
  ): Promise<{ action: "provide"; username: string | undefined } | { action: "cancel"; response: CredentialResponse }> {
    if (!credentialKindNeedsUsername(request.kind)) {
      const username = normalizeOptionalUsername(request.username);
      return { action: "provide", username };
    }

    if (request.kind === "proxyPassword") {
      const username = normalizeOptionalUsername(request.username);
      if (username !== undefined) {
        return { action: "provide", username };
      }
    }

    const username = await withCredentialTimeout(request, this.options.ui.promptUsername(request));
    if (username === CREDENTIAL_PROMPT_TIMEOUT) {
      return {
        action: "cancel",
        response: cancel(request, SUBVERSIONR_CREDENTIAL_TIMEOUT, "auth", "error.auth.credentialTimeout"),
      };
    }
    if (username === undefined || username.trim().length === 0) {
      return {
        action: "cancel",
        response: cancel(request, SUBVERSIONR_CREDENTIAL_CANCELLED, "auth", "error.auth.credentialCancelled"),
      };
    }
    return { action: "provide", username };
  }
}

async function readStoredCredential(
  secretStorage: CredentialSecretStorage,
  storageKey: string,
  request: CredentialRequest,
): Promise<{ credential?: StoredCredential } | CredentialResponse> {
  const raw = await secretStorage.get(storageKey);
  if (raw === undefined) {
    return {};
  }

  try {
    const stored = JSON.parse(raw) as Partial<StoredCredential>;
    if (stored.version === 1 && typeof stored.secret === "string" && usernameIsValidForKind(request.kind, stored.username)) {
      return { credential: stored as StoredCredential };
    }
  } catch {
    return cancel(request, SUBVERSIONR_CREDENTIAL_STORE_INVALID, "auth", "error.auth.credentialStoreInvalid");
  }

  return cancel(request, SUBVERSIONR_CREDENTIAL_STORE_INVALID, "auth", "error.auth.credentialStoreInvalid");
}

async function readCredentialIndex(secretStorage: CredentialSecretStorage): Promise<StoredCredentialIndex | undefined> {
  const raw = await secretStorage.get(CREDENTIAL_INDEX_KEY);
  if (raw === undefined) {
    return undefined;
  }

  try {
    const stored = JSON.parse(raw) as Partial<StoredCredentialIndex>;
    if (
      stored.version === 1 &&
      Array.isArray(stored.keys) &&
      stored.keys.every((key) => typeof key === "string" && key.startsWith("subversionr.credential.v1."))
    ) {
      return { version: 1, keys: [...new Set(stored.keys)] };
    }
  } catch {
    throw invalidCredentialIndex();
  }

  throw invalidCredentialIndex();
}

function credentialIndexWithKey(index: StoredCredentialIndex | undefined, key: string): StoredCredentialIndex {
  return { version: 1, keys: [...new Set([...(index?.keys ?? []), key])] };
}

function credentialStorageKey(request: CredentialRequest): string {
  return `subversionr.credential.v1.${request.kind}.${realmHash(request)}`;
}

function credential(username: string | undefined, secret: string): Credential {
  if (username === undefined) {
    return { secret };
  }
  return { username, secret };
}

function isSupportedCredentialKind(kind: string): kind is CredentialKind {
  return SUPPORTED_CREDENTIAL_KINDS.includes(kind as CredentialKind);
}

function credentialKindNeedsUsername(kind: CredentialKind): boolean {
  return kind === "usernamePassword" || kind === "proxyPassword";
}

function normalizeOptionalUsername(username: string | undefined): string | undefined {
  if (username === undefined || username.trim().length === 0) {
    return undefined;
  }
  return username;
}

function usernameIsValidForKind(kind: CredentialKind, username: unknown): boolean {
  if (credentialKindNeedsUsername(kind)) {
    return typeof username === "string" && username.trim().length > 0;
  }
  return username === undefined || (typeof username === "string" && username.trim().length > 0);
}

function cancel(
  request: CredentialRequest,
  code: string,
  category: "auth" | "lifecycle",
  messageKey: string,
): CredentialResponse {
  return {
    requestId: request.requestId,
    action: "cancel",
    error: {
      code,
      category,
      messageKey,
      args: safeCredentialArgs(request),
      retryable: false,
    },
  };
}

function withRequestId(response: CredentialResponse, requestId: string, request?: CredentialRequest): CredentialResponse {
  if (response.action === "provide") {
    return {
      ...response,
      requestId,
      persistence: request?.persistenceAllowed === false ? "session" : response.persistence,
    };
  }
  return {
    ...response,
    requestId,
    error: {
      ...response.error,
    },
  };
}

async function withCredentialTimeout<T>(
  request: CredentialRequest,
  promise: Promise<T>,
): Promise<T | typeof CREDENTIAL_PROMPT_TIMEOUT> {
  if (request.timeoutMs <= 0) {
    return CREDENTIAL_PROMPT_TIMEOUT;
  }

  return await new Promise<T | typeof CREDENTIAL_PROMPT_TIMEOUT>((resolve, reject) => {
    const timeout = setTimeout(() => resolve(CREDENTIAL_PROMPT_TIMEOUT), request.timeoutMs);
    promise.then(
      (value) => {
        clearTimeout(timeout);
        resolve(value);
      },
      (error: unknown) => {
        clearTimeout(timeout);
        reject(error);
      },
    );
  });
}

function safeCredentialArgs(request: CredentialRequest): Record<string, unknown> {
  return {
    realmHash: realmHash(request),
    kind: request.kind,
    origin: request.origin,
  };
}

function realmHash(request: CredentialRequest): string {
  return createHash("sha256").update(`${request.kind}\0${request.realm}`, "utf8").digest("hex");
}

function parseCredentialRequest(params: unknown): CredentialRequest {
  const record = requireRecord(params, "params");
  const origin = requireString(record.origin, "origin");
  if (origin !== "foreground" && origin !== "background") {
    throw invalidCredentialParams("origin");
  }

  return {
    requestId: requireString(record.requestId, "requestId"),
    realm: requireString(record.realm, "realm"),
    kind: requireString(record.kind, "kind") as CredentialKind,
    username: optionalString(record.username, "username"),
    interactive: requireBoolean(record.interactive, "interactive"),
    persistenceAllowed: requireBoolean(record.persistenceAllowed, "persistenceAllowed"),
    origin,
    timeoutMs: requireNumber(record.timeoutMs, "timeoutMs"),
    repositoryId: optionalString(record.repositoryId, "repositoryId"),
    workingCopyRoot: optionalString(record.workingCopyRoot, "workingCopyRoot"),
  };
}

function requireRecord(value: unknown, field: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null) {
    throw invalidCredentialParams(field);
  }
  return value as Record<string, unknown>;
}

function requireString(value: unknown, field: string): string {
  if (typeof value !== "string") {
    throw invalidCredentialParams(field);
  }
  return value;
}

function optionalString(value: unknown, field: string): string | undefined {
  if (value === undefined) {
    return undefined;
  }
  return requireString(value, field);
}

function requireBoolean(value: unknown, field: string): boolean {
  if (typeof value !== "boolean") {
    throw invalidCredentialParams(field);
  }
  return value;
}

function requireNumber(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isInteger(value)) {
    throw invalidCredentialParams(field);
  }
  return value;
}

function invalidCredentialParams(field: string): CredentialRpcError {
  return new CredentialRpcError("RPC_INVALID_PARAMS", "protocol", "error.rpc.invalidParams", {
    field,
  });
}

function invalidCredentialIndex(): CredentialRpcError {
  return new CredentialRpcError(
    SUBVERSIONR_CREDENTIAL_INDEX_INVALID,
    "auth",
    "error.auth.credentialIndexInvalid",
    {},
  );
}

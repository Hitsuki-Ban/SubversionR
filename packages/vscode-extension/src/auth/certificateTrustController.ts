import { createHash } from "node:crypto";

export const SUBVERSIONR_CERTIFICATE_CANCELLED = "SUBVERSIONR_CERTIFICATE_CANCELLED";
export const SUBVERSIONR_CERTIFICATE_CHANGED = "SUBVERSIONR_CERTIFICATE_CHANGED";
export const SUBVERSIONR_CERTIFICATE_FINGERPRINT_ALGORITHM_UNSUPPORTED =
  "SUBVERSIONR_CERTIFICATE_FINGERPRINT_ALGORITHM_UNSUPPORTED";
export const SUBVERSIONR_CERTIFICATE_NON_INTERACTIVE = "SUBVERSIONR_CERTIFICATE_NON_INTERACTIVE";
export const SUBVERSIONR_CERTIFICATE_PERSISTENCE_DISALLOWED = "SUBVERSIONR_CERTIFICATE_PERSISTENCE_DISALLOWED";
export const SUBVERSIONR_CERTIFICATE_REALM_REQUIRED = "SUBVERSIONR_CERTIFICATE_REALM_REQUIRED";
export const SUBVERSIONR_CERTIFICATE_REJECTED = "SUBVERSIONR_CERTIFICATE_REJECTED";
export const SUBVERSIONR_CERTIFICATE_STORE_INVALID = "SUBVERSIONR_CERTIFICATE_STORE_INVALID";
export const SUBVERSIONR_CERTIFICATE_TIMEOUT = "SUBVERSIONR_CERTIFICATE_TIMEOUT";
export const SUBVERSIONR_CERTIFICATE_UNTRUSTED_WORKSPACE = "SUBVERSIONR_CERTIFICATE_UNTRUSTED_WORKSPACE";

const CERTIFICATE_PROMPT_TIMEOUT = Symbol("certificatePromptTimeout");
const SUPPORTED_FINGERPRINT_ALGORITHM = "sha256-der";

export type CertificateFingerprintAlgorithm = typeof SUPPORTED_FINGERPRINT_ALGORITHM;
export type CertificateTrustDecision = "reject" | "once" | "permanent";

export interface CertificateTrustRequest {
  requestId: string;
  realm: string;
  host: string;
  fingerprint: string;
  fingerprintAlgorithm: CertificateFingerprintAlgorithm;
  failures: string[];
  validFrom: string;
  validTo: string;
  issuer?: string;
  subject?: string;
  interactive: boolean;
  persistenceAllowed: boolean;
  origin: "foreground" | "background";
  timeoutMs: number;
  repositoryId?: string;
  workingCopyRoot?: string;
}

export type CertificateTrustResponse =
  | {
      requestId: string;
      action: "trust";
      trust: "once" | "permanent";
      fingerprint: string;
      fingerprintAlgorithm: CertificateFingerprintAlgorithm;
    }
  | {
      requestId: string;
      action: "reject";
      error: CertificateTrustError;
    };

export interface CertificateTrustError {
  code: string;
  category: "auth" | "lifecycle";
  messageKey: string;
  args: Record<string, unknown>;
  retryable: false;
}

export interface CertificateTrustSecretStorage {
  get(key: string): Promise<string | undefined>;
  store(key: string, value: string): Promise<void>;
  delete(key: string): Promise<void>;
}

export interface CertificateTrustPromptUi {
  pickTrust(request: CertificateTrustRequest): Promise<CertificateTrustDecision | undefined>;
}

export interface CertificateTrustControllerOptions {
  workspaceTrusted(): boolean;
  secretStorage: CertificateTrustSecretStorage;
  ui: CertificateTrustPromptUi;
  now?: () => string;
}

export interface CertificateTrustController {
  handleCertificateTrustRequest(request: CertificateTrustRequest): Promise<CertificateTrustResponse>;
}

export class CertificateTrustRpcError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: string,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown>,
    public readonly retryable = false,
  ) {
    super(code);
    this.name = "CertificateTrustRpcError";
  }
}

interface StoredCertificateTrust {
  version: 1;
  fingerprint: string;
  fingerprintAlgorithm: CertificateFingerprintAlgorithm;
  trustedAt: string;
}

export function createCertificateTrustController(
  options: CertificateTrustControllerOptions,
): CertificateTrustController {
  return new SecretStorageCertificateTrustController(options);
}

export function createCertificateTrustRequestHandler(
  controller: CertificateTrustController,
): (method: string, params: unknown) => Promise<CertificateTrustResponse> {
  return async (method, params) => {
    if (method !== "certificate/request") {
      throw new CertificateTrustRpcError("RPC_METHOD_NOT_FOUND", "unsupported", "error.rpc.methodNotFound", {
        method,
      });
    }
    return await controller.handleCertificateTrustRequest(parseCertificateTrustRequest(params));
  };
}

class SecretStorageCertificateTrustController implements CertificateTrustController {
  private readonly pendingInteractivePrompts = new Map<string, Promise<CertificateTrustResponse>>();

  public constructor(private readonly options: CertificateTrustControllerOptions) {}

  public async handleCertificateTrustRequest(
    request: CertificateTrustRequest,
  ): Promise<CertificateTrustResponse> {
    if (!this.options.workspaceTrusted()) {
      return reject(
        request,
        SUBVERSIONR_CERTIFICATE_UNTRUSTED_WORKSPACE,
        "lifecycle",
        "error.auth.certificateUntrustedWorkspace",
      );
    }
    if (request.realm.trim().length === 0) {
      return reject(request, SUBVERSIONR_CERTIFICATE_REALM_REQUIRED, "auth", "error.auth.certificateRealmRequired");
    }
    if (request.fingerprintAlgorithm !== SUPPORTED_FINGERPRINT_ALGORITHM) {
      return reject(
        request,
        SUBVERSIONR_CERTIFICATE_FINGERPRINT_ALGORITHM_UNSUPPORTED,
        "auth",
        "error.auth.certificateFingerprintAlgorithmUnsupported",
      );
    }

    const storageKey = certificateTrustStorageKey(request);
    const stored = await readStoredCertificateTrust(this.options.secretStorage, storageKey, request);
    if ("action" in stored) {
      return stored;
    }
    if (stored.trust) {
      if (stored.trust.fingerprint === request.fingerprint && stored.trust.fingerprintAlgorithm === request.fingerprintAlgorithm) {
        return trust(request, "permanent");
      }
      if (!request.interactive || request.origin === "background") {
        return reject(request, SUBVERSIONR_CERTIFICATE_CHANGED, "auth", "error.auth.certificateChanged");
      }
    }

    if (!request.interactive || request.origin === "background") {
      return reject(request, SUBVERSIONR_CERTIFICATE_NON_INTERACTIVE, "auth", "error.auth.certificateNonInteractive");
    }

    const pendingKey = certificatePromptKey(request);
    const pendingPrompt = this.pendingInteractivePrompts.get(pendingKey);
    if (pendingPrompt) {
      return withRequestId(await pendingPrompt, request.requestId);
    }

    const prompt = this.promptForCertificateTrust(request, storageKey);
    this.pendingInteractivePrompts.set(pendingKey, prompt);
    try {
      return withRequestId(await prompt, request.requestId);
    } finally {
      if (this.pendingInteractivePrompts.get(pendingKey) === prompt) {
        this.pendingInteractivePrompts.delete(pendingKey);
      }
    }
  }

  private async promptForCertificateTrust(
    request: CertificateTrustRequest,
    storageKey: string,
  ): Promise<CertificateTrustResponse> {
    const decision = await withCertificateTimeout(request, this.options.ui.pickTrust(request));
    if (decision === CERTIFICATE_PROMPT_TIMEOUT) {
      return reject(request, SUBVERSIONR_CERTIFICATE_TIMEOUT, "auth", "error.auth.certificateTimeout");
    }
    if (decision === undefined) {
      return reject(request, SUBVERSIONR_CERTIFICATE_CANCELLED, "auth", "error.auth.certificateCancelled");
    }
    if (decision === "reject") {
      return reject(request, SUBVERSIONR_CERTIFICATE_REJECTED, "auth", "error.auth.certificateRejected");
    }
    if (decision === "permanent") {
      if (!request.persistenceAllowed) {
        return reject(
          request,
          SUBVERSIONR_CERTIFICATE_PERSISTENCE_DISALLOWED,
          "auth",
          "error.auth.certificatePersistenceDisallowed",
        );
      }
      await this.options.secretStorage.store(
        storageKey,
        JSON.stringify({
          version: 1,
          fingerprint: request.fingerprint,
          fingerprintAlgorithm: request.fingerprintAlgorithm,
          trustedAt: this.options.now?.() ?? new Date().toISOString(),
        } satisfies StoredCertificateTrust),
      );
      return trust(request, "permanent");
    }

    return trust(request, "once");
  }
}

async function readStoredCertificateTrust(
  secretStorage: CertificateTrustSecretStorage,
  storageKey: string,
  request: CertificateTrustRequest,
): Promise<{ trust?: StoredCertificateTrust } | CertificateTrustResponse> {
  const raw = await secretStorage.get(storageKey);
  if (raw === undefined) {
    return {};
  }

  try {
    const stored = JSON.parse(raw) as Partial<StoredCertificateTrust>;
    if (
      stored.version === 1 &&
      typeof stored.fingerprint === "string" &&
      stored.fingerprintAlgorithm === SUPPORTED_FINGERPRINT_ALGORITHM &&
      typeof stored.trustedAt === "string"
    ) {
      return { trust: stored as StoredCertificateTrust };
    }
  } catch {
    return reject(request, SUBVERSIONR_CERTIFICATE_STORE_INVALID, "auth", "error.auth.certificateStoreInvalid");
  }

  return reject(request, SUBVERSIONR_CERTIFICATE_STORE_INVALID, "auth", "error.auth.certificateStoreInvalid");
}

function trust(request: CertificateTrustRequest, certificateTrust: "once" | "permanent"): CertificateTrustResponse {
  return {
    requestId: request.requestId,
    action: "trust",
    trust: certificateTrust,
    fingerprint: request.fingerprint,
    fingerprintAlgorithm: request.fingerprintAlgorithm,
  };
}

function reject(
  request: CertificateTrustRequest,
  code: string,
  category: "auth" | "lifecycle",
  messageKey: string,
): CertificateTrustResponse {
  return {
    requestId: request.requestId,
    action: "reject",
    error: {
      code,
      category,
      messageKey,
      args: safeCertificateArgs(request),
      retryable: false,
    },
  };
}

function withRequestId(response: CertificateTrustResponse, requestId: string): CertificateTrustResponse {
  if (response.action === "trust") {
    return { ...response, requestId };
  }
  return {
    ...response,
    requestId,
    error: {
      ...response.error,
    },
  };
}

async function withCertificateTimeout<T>(
  request: CertificateTrustRequest,
  promise: Promise<T>,
): Promise<T | typeof CERTIFICATE_PROMPT_TIMEOUT> {
  if (request.timeoutMs <= 0) {
    return CERTIFICATE_PROMPT_TIMEOUT;
  }

  return await new Promise<T | typeof CERTIFICATE_PROMPT_TIMEOUT>((resolve, rejectPromise) => {
    const timeout = setTimeout(() => resolve(CERTIFICATE_PROMPT_TIMEOUT), request.timeoutMs);
    promise.then(
      (value) => {
        clearTimeout(timeout);
        resolve(value);
      },
      (error: unknown) => {
        clearTimeout(timeout);
        rejectPromise(error);
      },
    );
  });
}

function safeCertificateArgs(request: CertificateTrustRequest): Record<string, unknown> {
  return {
    realmHash: realmHash(request),
    fingerprint: request.fingerprint,
    fingerprintAlgorithm: request.fingerprintAlgorithm,
    failureCount: request.failures.length,
    origin: request.origin,
  };
}

function certificateTrustStorageKey(request: CertificateTrustRequest): string {
  return `subversionr.certificateTrust.v1.${realmHash(request)}`;
}

function certificatePromptKey(request: CertificateTrustRequest): string {
  return `${certificateTrustStorageKey(request)}\0${request.fingerprintAlgorithm}\0${request.fingerprint}\0${request.persistenceAllowed}`;
}

function realmHash(request: CertificateTrustRequest): string {
  return createHash("sha256").update(`certificate\0${request.realm}`, "utf8").digest("hex");
}

function parseCertificateTrustRequest(params: unknown): CertificateTrustRequest {
  const record = requireRecord(params, "params");
  const origin = requireString(record.origin, "origin");
  if (origin !== "foreground" && origin !== "background") {
    throw invalidCertificateParams("origin");
  }

  return {
    requestId: requireString(record.requestId, "requestId"),
    realm: requireString(record.realm, "realm"),
    host: requireString(record.host, "host"),
    fingerprint: requireString(record.fingerprint, "fingerprint"),
    fingerprintAlgorithm: requireString(record.fingerprintAlgorithm, "fingerprintAlgorithm") as CertificateFingerprintAlgorithm,
    failures: requireStringArray(record.failures, "failures"),
    validFrom: requireString(record.validFrom, "validFrom"),
    validTo: requireString(record.validTo, "validTo"),
    issuer: optionalString(record.issuer, "issuer"),
    subject: optionalString(record.subject, "subject"),
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
    throw invalidCertificateParams(field);
  }
  return value as Record<string, unknown>;
}

function requireString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw invalidCertificateParams(field);
  }
  return value;
}

function optionalString(value: unknown, field: string): string | undefined {
  if (value === undefined) {
    return undefined;
  }
  return requireString(value, field);
}

function requireStringArray(value: unknown, field: string): string[] {
  if (!Array.isArray(value) || value.length === 0 || value.some((item) => typeof item !== "string" || item.trim().length === 0)) {
    throw invalidCertificateParams(field);
  }
  return value as string[];
}

function requireBoolean(value: unknown, field: string): boolean {
  if (typeof value !== "boolean") {
    throw invalidCertificateParams(field);
  }
  return value;
}

function requireNumber(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isInteger(value)) {
    throw invalidCertificateParams(field);
  }
  return value;
}

function invalidCertificateParams(field: string): CertificateTrustRpcError {
  return new CertificateTrustRpcError("RPC_INVALID_PARAMS", "protocol", "error.rpc.invalidParams", {
    field,
  });
}

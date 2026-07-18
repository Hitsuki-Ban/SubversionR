import type { BackendService } from "../backend/backendService";
import type { JsonRpcSender } from "../status/types";

export interface CheckoutTargetRecoveryEntry {
  targetPath: string;
  targetSha256: string;
  originOperationId: string;
  state: "armed" | "blocked";
}

export interface ConfirmCheckoutTargetDispositionRequest {
  targetPath: string;
  targetSha256: string;
  originOperationId: string;
  confirmation: "reviewedAndResolved";
}

export interface ConfirmCheckoutTargetDispositionResponse {
  released: true;
  targetSha256: string;
  originOperationId: string;
}

export class CheckoutTargetRecoveryRpcClient {
  public constructor(private readonly sender: JsonRpcSender) {}

  public async list(): Promise<readonly CheckoutTargetRecoveryEntry[]> {
    const response = requireRecord(
      await this.sender.sendRequest<unknown>("remote/listCheckoutTargetRecoveries", {}),
      "result",
    );
    requireExactKeys(response, ["entries"], "result");
    if (!Array.isArray(response.entries) || response.entries.length > 128) {
      throw invalidResponse("entries");
    }
    return response.entries.map((rawEntry, index) => parseEntry(rawEntry, index));
  }

  public async confirm(
    request: ConfirmCheckoutTargetDispositionRequest,
  ): Promise<ConfirmCheckoutTargetDispositionResponse> {
    const validated = parseConfirmationRequest(request);
    const response = requireRecord(
      await this.sender.sendRequest<unknown>("remote/confirmCheckoutTargetDisposition", validated),
      "result",
    );
    requireExactKeys(response, ["released", "targetSha256", "originOperationId"], "result");
    if (
      response.released !== true
      || response.targetSha256 !== validated.targetSha256
      || response.originOperationId !== validated.originOperationId
    ) {
      throw invalidResponse("attribution");
    }
    return {
      released: true,
      targetSha256: validated.targetSha256,
      originOperationId: validated.originOperationId,
    };
  }
}

export class BackendCheckoutTargetRecoveryClient {
  public constructor(private readonly backendService: Pick<BackendService, "initialize">) {}

  public async list(): Promise<readonly CheckoutTargetRecoveryEntry[]> {
    return await new CheckoutTargetRecoveryRpcClient(await this.backendService.initialize()).list();
  }

  public async confirm(
    request: ConfirmCheckoutTargetDispositionRequest,
  ): Promise<ConfirmCheckoutTargetDispositionResponse> {
    return await new CheckoutTargetRecoveryRpcClient(await this.backendService.initialize()).confirm(request);
  }
}

function parseEntry(value: unknown, index: number): CheckoutTargetRecoveryEntry {
  const entry = requireRecord(value, `entries.${index}`);
  requireExactKeys(
    entry,
    ["targetPath", "targetSha256", "originOperationId", "state"],
    `entries.${index}`,
  );
  const targetPath = requireString(entry.targetPath, `entries.${index}.targetPath`, 32 * 1024);
  if (!isAbsolutePath(targetPath)) {
    throw invalidResponse(`entries.${index}.targetPath`);
  }
  const targetSha256 = requireString(entry.targetSha256, `entries.${index}.targetSha256`, 64);
  const originOperationId = requireString(
    entry.originOperationId,
    `entries.${index}.originOperationId`,
    36,
  );
  if (!/^[0-9a-f]{64}$/u.test(targetSha256) || !isCanonicalUuid(originOperationId)) {
    throw invalidResponse(`entries.${index}.attribution`);
  }
  if (entry.state !== "armed" && entry.state !== "blocked") {
    throw invalidResponse(`entries.${index}.state`);
  }
  return { targetPath, targetSha256, originOperationId, state: entry.state };
}

function parseConfirmationRequest(
  value: ConfirmCheckoutTargetDispositionRequest,
): ConfirmCheckoutTargetDispositionRequest {
  const request = requireRequestRecord(value, "request");
  requireExactRequestKeys(
    request,
    ["targetPath", "targetSha256", "originOperationId", "confirmation"],
    "request",
  );
  const targetPath = requireRequestString(request.targetPath, "targetPath", 32 * 1024);
  const targetSha256 = requireRequestString(request.targetSha256, "targetSha256", 64);
  const originOperationId = requireRequestString(request.originOperationId, "originOperationId", 36);
  if (
    !isAbsolutePath(targetPath)
    || !/^[0-9a-f]{64}$/u.test(targetSha256)
    || !isCanonicalUuid(originOperationId)
    || request.confirmation !== "reviewedAndResolved"
  ) {
    throw invalidRequest("attribution");
  }
  return { targetPath, targetSha256, originOperationId, confirmation: "reviewedAndResolved" };
}

function requireRequestRecord(value: unknown, field: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw invalidRequest(field);
  }
  return value as Record<string, unknown>;
}

function requireExactRequestKeys(
  value: Record<string, unknown>,
  expected: readonly string[],
  field: string,
): void {
  if (
    Object.keys(value).length !== expected.length
    || expected.some((key) => !Object.prototype.hasOwnProperty.call(value, key))
  ) {
    throw invalidRequest(field);
  }
}

function requireRequestString(value: unknown, field: string, maxLength: number): string {
  if (
    typeof value !== "string"
    || value.length === 0
    || value.length > maxLength
    || value.includes("\0")
    || value.includes("\r")
    || value.includes("\n")
  ) {
    throw invalidRequest(field);
  }
  return value;
}

function requireRecord(value: unknown, field: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw invalidResponse(field);
  }
  return value as Record<string, unknown>;
}

function requireExactKeys(
  value: Record<string, unknown>,
  expected: readonly string[],
  field: string,
): void {
  if (
    Object.keys(value).length !== expected.length
    || expected.some((key) => !Object.prototype.hasOwnProperty.call(value, key))
  ) {
    throw invalidResponse(field);
  }
}

function requireString(value: unknown, field: string, maxLength: number): string {
  if (
    typeof value !== "string"
    || value.length === 0
    || value.length > maxLength
    || value.includes("\0")
    || value.includes("\r")
    || value.includes("\n")
  ) {
    throw invalidResponse(field);
  }
  return value;
}

function isAbsolutePath(value: string): boolean {
  return /^[A-Za-z]:[\\/]/u.test(value) || value.startsWith("/") || value.startsWith("\\\\");
}

function isCanonicalUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u.test(value)
    && value !== "00000000-0000-0000-0000-000000000000";
}

function invalidRequest(field: string): Error {
  return new Error(`SUBVERSIONR_CHECKOUT_TARGET_RECOVERY_REQUEST_INVALID:${field}`);
}

function invalidResponse(field: string): Error {
  return new Error(`SUBVERSIONR_CHECKOUT_TARGET_RECOVERY_RESPONSE_INVALID:${field}`);
}

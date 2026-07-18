import { randomUUID } from "node:crypto";
import * as nodePath from "node:path";
import type { BackendConnection } from "../backend/backendProcess";
import { JsonRpcStreamError } from "../transport/jsonRpcStreamClient";

const EXPECTED_PROTOCOL_MAJOR = 1;
const EXPECTED_PROTOCOL_MINOR = 32;

export interface InstalledRemoteWorkerReportOptions {
  expectedToken: string | undefined;
  request: unknown;
  targetPath: string;
  initialize(): Promise<Pick<BackendConnection, "initializeResult" | "isRemoteSubmissionEnabled" | "sendRequest">>;
  createOperationId?(): string;
}

export async function collectInstalledRemoteWorkerReport(
  options: InstalledRemoteWorkerReportOptions,
): Promise<Record<string, unknown>> {
  if (
    typeof options.expectedToken !== "string" ||
    options.expectedToken.length === 0 ||
    requestToken(options.request) !== options.expectedToken
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_REMOTE_WORKER_REPORT_FORBIDDEN");
  }
  if (!isAbsolutePath(options.targetPath)) {
    throw reportError("SUBVERSIONR_INSTALLED_REMOTE_WORKER_TARGET_INVALID");
  }

  const connection = await options.initialize();
  const initialize = connection.initializeResult;
  if (
    initialize.protocol.major !== EXPECTED_PROTOCOL_MAJOR ||
    initialize.protocol.minor !== EXPECTED_PROTOCOL_MINOR ||
    initialize.capabilities.remoteWorkerIsolation !== true ||
    !connection.isRemoteSubmissionEnabled()
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_REMOTE_WORKER_CAPABILITY_UNAVAILABLE");
  }

  const createOperationId = options.createOperationId ?? randomUUID;
  const operationId = createOperationId();
  const subsequentOperationId = createOperationId();
  if (
    !isCanonicalOperationId(operationId) ||
    !isCanonicalOperationId(subsequentOperationId) ||
    subsequentOperationId === operationId
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_REMOTE_WORKER_OPERATION_ID_INVALID");
  }
  const transportResult = await requireUnsupportedAfterWorker(
    connection,
    remoteCheckoutParams(options.targetPath, operationId, initialize.acknowledgedTrustEpoch),
  );
  await requireUnsupportedAfterWorker(
    connection,
    remoteCheckoutParams(options.targetPath, subsequentOperationId, initialize.acknowledgedTrustEpoch),
  );

  const diagnostics = await connection.sendRequest<unknown>("diagnostics/get", {});
  if (!isCurrentWorkerDiagnostics(diagnostics)) {
    throw reportError("SUBVERSIONR_INSTALLED_REMOTE_WORKER_FOLLOW_UP_INVALID");
  }

  return {
    schemaVersion: 1,
    kind: "subversionr.installedRemoteWorkerReport",
    protocol: { major: EXPECTED_PROTOCOL_MAJOR, minor: EXPECTED_PROTOCOL_MINOR },
    remoteWorkerIsolation: true,
    transportResult,
    sameLaneSubsequent: true,
    subsequentDiagnostics: true,
  };
}

async function requireUnsupportedAfterWorker(
  connection: Pick<BackendConnection, "sendRequest">,
  params: Record<string, unknown>,
): Promise<"unsupportedAfterWorker"> {
  try {
    await connection.sendRequest("repository/checkout", params);
  } catch (error) {
    if (error instanceof JsonRpcStreamError && error.code === "SUBVERSIONR_REMOTE_TRANSPORT_UNSUPPORTED") {
      return "unsupportedAfterWorker";
    }
    throw error;
  }
  throw reportError("SUBVERSIONR_INSTALLED_REMOTE_WORKER_BOUNDARY_INVALID");
}

function remoteCheckoutParams(targetPath: string, operationId: string, trustEpoch: number): Record<string, unknown> {
  const authority = {
    scheme: "https",
    canonicalHost: "svn.example.invalid",
    effectivePort: 443,
  };
  return {
    url: "https://svn.example.invalid/project/trunk",
    targetPath,
    revision: "head",
    depth: "infinity",
    ignoreExternals: true,
    remote: {
      version: 1,
      operationId,
      intent: "foreground",
      interaction: "allowed",
      timeoutMs: 30_000,
      workspaceTrust: "trusted",
      trustEpoch,
      profile: {
        schema: "subversionr.remote-profile.v1",
        profileId: "installed-worker-evidence",
        authority,
        serverAuth: "anonymous",
        serverAccount: "none",
        serverCredentialPersistence: "secretStorage",
        tls: { trust: "windowsRootsThenBroker" },
        proxy: "none",
        ssh: "none",
        redirectPolicy: "rejectAll",
      },
      expectedOrigin: authority,
    },
  };
}

function isCurrentWorkerDiagnostics(value: unknown): boolean {
  if (typeof value !== "object" || value === null) {
    return false;
  }
  const diagnostics = value as Record<string, unknown>;
  const protocol = diagnostics.protocol;
  const capabilities = diagnostics.capabilities;
  return (
    typeof protocol === "object" &&
    protocol !== null &&
    (protocol as Record<string, unknown>).major === EXPECTED_PROTOCOL_MAJOR &&
    (protocol as Record<string, unknown>).minor === EXPECTED_PROTOCOL_MINOR &&
    typeof capabilities === "object" &&
    capabilities !== null &&
    (capabilities as Record<string, unknown>).remoteWorkerIsolation === true
  );
}

function requestToken(request: unknown): string | undefined {
  if (typeof request !== "object" || request === null || !("token" in request)) {
    return undefined;
  }
  const token = (request as { token?: unknown }).token;
  return typeof token === "string" && token.length > 0 ? token : undefined;
}

function isAbsolutePath(value: string): boolean {
  return nodePath.isAbsolute(value) || nodePath.win32.isAbsolute(value) || nodePath.posix.isAbsolute(value);
}

function isCanonicalOperationId(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-9a-f][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);
}

export class InstalledRemoteWorkerReportError extends Error {
  public readonly messageKey = "error.diagnostics.installedRemoteWorkerReportInvalid";

  public constructor(public readonly code: string) {
    super(code);
    this.name = "InstalledRemoteWorkerReportError";
  }
}

function reportError(code: string): InstalledRemoteWorkerReportError {
  return new InstalledRemoteWorkerReportError(code);
}

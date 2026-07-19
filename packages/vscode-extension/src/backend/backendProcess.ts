import { spawn as nodeSpawn, type SpawnOptions } from "node:child_process";
import { EventEmitter } from "node:events";
import path from "node:path";
import type { Readable, Writable } from "node:stream";
import {
  JsonRpcStreamClient,
  type JsonRpcNotificationHandler,
  type JsonRpcRequestHandler,
  type JsonRpcStreamError,
} from "../transport/jsonRpcStreamClient";
import type { JsonRpcRequestOptions, JsonRpcSender } from "../status/types";

const EXPECTED_PROTOCOL_MAJOR = 1;
const MINIMUM_PROTOCOL_MINOR = 35;
const EXPECTED_CACHE_SCHEMA_ID = "subversionr.cache.v1";
const EXPECTED_CACHE_SCHEMA_VERSION = 1;
const EXPECTED_CACHE_SCHEMA_ROLLBACK = "delete-and-reconcile";
const STDERR_LIMIT_BYTES = 16 * 1024;
const INITIALIZE_PROCESS_CLOSE_GRACE_MS = 250;
const REQUIRED_CAPABILITIES: Array<keyof InitializeResult["capabilities"]> = [
  "contentLengthFraming",
  "realLibsvnBridge",
  "repositoryDiscover",
  "repositoryOpen",
  "repositoryClose",
  "repositoryCheckout",
  "statusSnapshot",
  "statusRefresh",
  "statusRemoteCheck",
  "statusStaleNotification",
  "contentGet",
  "contentGetRevision",
  "historyLog",
  "historyBlame",
  "operationRun",
  "operationRunAdd",
  "operationRunRemove",
  "operationRunMove",
  "operationRunCleanup",
  "operationRunResolve",
  "operationRunUpdate",
  "operationRunUpdateSelectedPath",
  "operationRunUpdateToRevision",
  "operationRunUpdateDepth",
  "operationRunUpdateExternalsPolicy",
  "propertiesList",
  "operationRunPropertySet",
  "operationRunPropertyDelete",
  "ignore",
  "operationRunChangelistSet",
  "operationRunChangelistClear",
  "operationRunLock",
  "operationRunUnlock",
  "operationRunBranchCreate",
  "operationRunSwitch",
  "operationRunCommit",
  "operationRunCommitMultiPath",
  "diagnosticsGet",
  "credentialRequest",
  "certificateRequest",
  "remoteOperationEnvelope",
  "trustedConfigSnapshot",
  "remoteWorkerIsolation",
  "credentialLeaseSettlement",
  "remoteConnectionState",
  "remoteSvnAnonymous",
];

export type WorkspaceTrustState = "trusted" | "untrusted";
export type BackendErrorCategory = "configuration" | "process" | "protocol";

export interface BackendLaunchConfig {
  executablePath: string;
  bridgeDllPath: string;
  cacheRoot: string;
  remoteStateRoot: string;
  clientName: string;
  clientVersion: string;
  locale: string;
  workspaceTrust: WorkspaceTrustState;
  baseEnv: NodeJS.ProcessEnv;
}

export interface BackendSpawnOptions {
  env: NodeJS.ProcessEnv;
  shell: false;
  stdio: ["pipe", "pipe", "pipe"];
  windowsHide: true;
}

export interface BackendProcessSpawner {
  spawn(executablePath: string, args: readonly string[], options: BackendSpawnOptions): BackendChildProcess;
}

export interface BackendChildProcess extends EventEmitter {
  stdin: Writable;
  stdout: Readable;
  stderr: Readable;
  pid?: number;
  kill(signal?: NodeJS.Signals | number): boolean;
}

export interface InitializeParams {
  clientName: string;
  clientVersion: string;
  locale: string;
  workspaceTrust: WorkspaceTrustState;
  trustEpoch: number;
  cacheRoot: string;
  remoteStateRoot: string;
}

export interface ProtocolVersion {
  major: number;
  minor: number;
}

export interface CacheSchema {
  schemaId: string;
  version: number;
  rollback: string;
}

export interface InitializeResult {
  protocol: ProtocolVersion;
  backendVersion: string;
  bridgeVersion: string;
  libsvnVersion: string;
  platform: {
    os: string;
    arch: string;
  };
  cacheSchema: CacheSchema;
  capabilities: {
    contentLengthFraming: boolean;
    realLibsvnBridge: boolean;
    repositoryDiscover: boolean;
    repositoryOpen: boolean;
    repositoryClose: boolean;
    repositoryCheckout: boolean;
    statusSnapshot: boolean;
    statusRefresh: boolean;
    statusRemoteCheck: boolean;
    statusStaleNotification: boolean;
    contentGet: boolean;
    contentGetRevision: boolean;
    historyLog: boolean;
    historyBlame: boolean;
    operationRun: boolean;
    operationRunAdd: boolean;
    operationRunRemove: boolean;
    operationRunMove: boolean;
    operationRunCleanup: boolean;
    operationRunResolve: boolean;
    operationRunUpdate: boolean;
    operationRunUpdateSelectedPath: boolean;
    operationRunUpdateToRevision: boolean;
    operationRunUpdateDepth: boolean;
    operationRunUpdateExternalsPolicy: boolean;
    propertiesList: boolean;
    operationRunPropertySet: boolean;
    operationRunPropertyDelete: boolean;
    ignore: boolean;
    operationRunChangelistSet: boolean;
    operationRunChangelistClear: boolean;
    operationRunLock: boolean;
    operationRunUnlock: boolean;
    operationRunBranchCreate: boolean;
    operationRunSwitch: boolean;
    operationRunCommit: boolean;
    operationRunCommitMultiPath: boolean;
    diagnosticsGet: boolean;
    credentialRequest: boolean;
    certificateRequest: boolean;
    remoteOperationEnvelope: boolean;
    trustedConfigSnapshot: boolean;
    remoteWorkerIsolation: boolean;
    credentialLeaseSettlement: boolean;
    remoteConnectionState: boolean;
    remoteSvnAnonymous: boolean;
  };
  acknowledgedTrustEpoch: number;
}

export interface BackendConnection extends JsonRpcSender {
  readonly initializeResult: InitializeResult;
  isRemoteSubmissionEnabled(): boolean;
  currentRemoteTrustEpoch(): number;
  waitForCancelledRequestWireSettlement?<T>(requestId: number, timeoutMs: number): Promise<T>;
  updateWorkspaceTrust(trusted: boolean): Promise<number>;
  onDidTerminate(listener: (event: BackendConnectionTermination) => void): BackendConnectionTerminationSubscription;
  shutdown(): Promise<void>;
  dispose(): void;
}

export type BackendConnectionTerminationReason =
  | "processExit"
  | "processClose"
  | "processError"
  | "protocolFault"
  | "heartbeatFailed";

export interface BackendConnectionTermination {
  reason: BackendConnectionTerminationReason;
  exitCode?: number | null;
  signal?: NodeJS.Signals | null;
  message?: string;
}

export interface BackendConnectionTerminationSubscription {
  dispose(): void;
}

export class BackendLaunchError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: BackendErrorCategory,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
    public readonly retryable = false,
    public readonly diagnostics: unknown = null,
  ) {
    super(code);
    this.name = "BackendLaunchError";
  }
}

export class NodeBackendProcessSpawner implements BackendProcessSpawner {
  public spawn(executablePath: string, args: readonly string[], options: BackendSpawnOptions): BackendChildProcess {
    return nodeSpawn(executablePath, [...args], options as SpawnOptions) as BackendChildProcess;
  }
}

export async function startBackendProcess(
  config: BackendLaunchConfig,
  deps: {
    spawner?: BackendProcessSpawner;
    requestHandler?: JsonRpcRequestHandler;
    notificationHandler?: JsonRpcNotificationHandler;
    onRequestError?: (method: string, error: JsonRpcStreamError) => void;
    onRequestSettled?: (method: string, params: unknown) => void;
  } = {},
): Promise<BackendConnection> {
  validateLaunchConfig(config);
  const notificationHandler = requireNotificationHandler(deps.notificationHandler);

  const spawner = deps.spawner ?? new NodeBackendProcessSpawner();
  const child = spawner.spawn(config.executablePath, [], {
    env: {
      ...config.baseEnv,
      SUBVERSIONR_BRIDGE_DLL: config.bridgeDllPath,
    },
    shell: false,
    stdio: ["pipe", "pipe", "pipe"],
    windowsHide: true,
  });
  const stderr = new BoundedTextBuffer(STDERR_LIMIT_BYTES);
  const collectStderr = (chunk: Buffer | string): void => {
    stderr.push(chunk);
  };
  child.stderr.on("data", collectStderr);
  let activeConnection: BackendConnectionImpl | undefined;

  const rpc = new JsonRpcStreamClient({
    readable: child.stdout,
    writable: child.stdin,
    requestHandler: deps.requestHandler,
    notificationHandler,
    onRequestError: deps.onRequestError,
    onProtocolFault: (error) => {
      activeConnection?.terminateForProtocolFault(error);
    },
  });

  return await new Promise<BackendConnection>((resolve, reject) => {
    let settled = false;
    let initializeRequestFailureTimer: NodeJS.Timeout | undefined;
    let exitCloseGraceTimer: NodeJS.Timeout | undefined;

    const fail = (error: Error): void => {
      if (settled) {
        return;
      }
      settled = true;
      if (initializeRequestFailureTimer !== undefined) {
        clearTimeout(initializeRequestFailureTimer);
      }
      if (exitCloseGraceTimer !== undefined) {
        clearTimeout(exitCloseGraceTimer);
      }
      child.off("exit", handleExit);
      child.off("close", handleClose);
      child.off("error", handleProcessError);
      child.stderr.off("data", collectStderr);
      rpc.dispose(error);
      reject(error);
    };

    const handleExit = (exitCode: number | null, signal: NodeJS.Signals | null): void => {
      if (initializeRequestFailureTimer !== undefined) {
        clearTimeout(initializeRequestFailureTimer);
        initializeRequestFailureTimer = undefined;
      }
      exitCloseGraceTimer = setTimeout(() => {
        fail(backendExitedDuringInitialize(stderr.value(), exitCode, signal));
      }, INITIALIZE_PROCESS_CLOSE_GRACE_MS);
    };

    const handleClose = (exitCode: number | null, signal: NodeJS.Signals | null): void => {
      fail(backendExitedDuringInitialize(stderr.value(), exitCode, signal));
    };

    const handleProcessError = (error: Error): void => {
      fail(
        new BackendLaunchError(
          "SUBVERSIONR_BACKEND_SPAWN_FAILED",
          "process",
          "error.backend.spawnFailed",
          { message: error.message },
        ),
      );
    };

    child.once("exit", handleExit);
    child.once("close", handleClose);
    child.once("error", handleProcessError);

    rpc
      .sendRequest<unknown>("initialize", initializeParams(config))
      .then((rawResult) => {
        if (settled) {
          return;
        }

        let initializeResult: InitializeResult;
        try {
          initializeResult = parseInitializeResult(rawResult);
          requireCapabilities(initializeResult);
        } catch (error) {
          terminateChild(child);
          fail(error instanceof Error ? error : new Error(String(error)));
          return;
        }

        if (initializeResult.protocol.major !== EXPECTED_PROTOCOL_MAJOR) {
          terminateChild(child);
          fail(
            new BackendLaunchError(
              "SUBVERSIONR_PROTOCOL_MAJOR_UNSUPPORTED",
              "protocol",
              "error.backend.protocolMajorUnsupported",
              {
                expected: EXPECTED_PROTOCOL_MAJOR,
                actual: initializeResult.protocol.major,
              },
            ),
          );
          return;
        }
        if (initializeResult.protocol.minor < MINIMUM_PROTOCOL_MINOR) {
          terminateChild(child);
          fail(
            new BackendLaunchError(
              "SUBVERSIONR_PROTOCOL_MINOR_UNSUPPORTED",
              "protocol",
              "error.backend.protocolMinorUnsupported",
              {
                expectedMinimum: MINIMUM_PROTOCOL_MINOR,
                actual: initializeResult.protocol.minor,
              },
            ),
          );
          return;
        }

        settled = true;
        child.off("exit", handleExit);
        child.off("close", handleClose);
        child.off("error", handleProcessError);
        const connection = new BackendConnectionImpl(
          child,
          rpc,
          collectStderr,
          initializeResult,
          config.workspaceTrust === "trusted",
          deps.onRequestSettled,
        );
        activeConnection = connection;
        resolve(connection);
      })
      .catch((error: unknown) => {
        if (settled) {
          return;
        }
        if (!child.stdout.readableEnded && !child.stdout.destroyed) {
          terminateChild(child);
          fail(error instanceof Error ? error : new Error(String(error)));
          return;
        }
        initializeRequestFailureTimer = setTimeout(() => {
          if (settled) {
            return;
          }
          terminateChild(child);
          fail(error instanceof Error ? error : new Error(String(error)));
        }, INITIALIZE_PROCESS_CLOSE_GRACE_MS);
      });
  });
}

function backendExitedDuringInitialize(
  stderr: string,
  exitCode: number | null,
  signal: NodeJS.Signals | null,
): BackendLaunchError {
  const startupError = parseDaemonStartupError(stderr);
  if (startupError !== undefined) {
    return startupError;
  }
  return new BackendLaunchError(
    "SUBVERSIONR_BACKEND_EXITED",
    "process",
    "error.backend.exitedDuringInitialize",
    { exitCode, signal, stderr },
  );
}

function parseDaemonStartupError(stderr: string): BackendLaunchError | undefined {
  const recordText = stderr.trim();
  if (recordText.length === 0 || recordText.includes("\n") || recordText.includes("\r")) {
    return undefined;
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(recordText);
  } catch {
    return undefined;
  }
  if (!isRecord(parsed) || parsed.schema !== "subversionr.daemon.startup-error.v1") {
    return undefined;
  }
  if (
    typeof parsed.code !== "string" ||
    parsed.code.trim().length === 0 ||
    parsed.category !== "process" ||
    typeof parsed.messageKey !== "string" ||
    parsed.messageKey.trim().length === 0 ||
    !isRecord(parsed.safeArgs) ||
    typeof parsed.retryable !== "boolean" ||
    parsed.diagnostics !== null
  ) {
    return undefined;
  }

  return new BackendLaunchError(
    parsed.code,
    parsed.category,
    parsed.messageKey,
    parsed.safeArgs,
    parsed.retryable,
    parsed.diagnostics,
  );
}

function initializeParams(config: BackendLaunchConfig): InitializeParams {
  return {
    clientName: config.clientName,
    clientVersion: config.clientVersion,
    locale: config.locale,
    workspaceTrust: config.workspaceTrust,
    trustEpoch: 1,
    cacheRoot: config.cacheRoot,
    remoteStateRoot: config.remoteStateRoot,
  };
}

function validateLaunchConfig(config: BackendLaunchConfig): void {
  requireAbsolutePath(
    config.executablePath,
    "error.backend.executablePathNotAbsolute",
    "executablePath",
  );
  requireAbsolutePath(config.bridgeDllPath, "error.backend.bridgeDllPathNotAbsolute", "bridgeDllPath");
  requireAbsolutePath(config.cacheRoot, "error.backend.cacheRootNotAbsolute", "cacheRoot");
  requireAbsolutePath(config.remoteStateRoot, "error.backend.remoteStateRootNotAbsolute", "remoteStateRoot");
  requireNonEmpty(config.clientName, "clientName");
  requireNonEmpty(config.clientVersion, "clientVersion");
  requireNonEmpty(config.locale, "locale");
}

function requireNotificationHandler(handler: JsonRpcNotificationHandler | undefined): JsonRpcNotificationHandler {
  if (!handler) {
    throw new BackendLaunchError(
      "SUBVERSIONR_BACKEND_NOTIFICATION_HANDLER_REQUIRED",
      "configuration",
      "error.backend.notificationHandlerRequired",
    );
  }
  return handler;
}

function requireAbsolutePath(value: string, messageKey: string, field: string): void {
  if (value.trim().length === 0 || !isAbsolutePath(value)) {
    throw new BackendLaunchError("SUBVERSIONR_BACKEND_PATH_NOT_ABSOLUTE", "configuration", messageKey, {
      field,
      path: value,
    });
  }
}

function requireNonEmpty(value: string, field: string): void {
  if (value.trim().length === 0) {
    throw new BackendLaunchError("SUBVERSIONR_BACKEND_CONFIG_REQUIRED", "configuration", "error.backend.configRequired", {
      field,
    });
  }
}

function isAbsolutePath(value: string): boolean {
  return typeof value === "string" &&
    (path.isAbsolute(value) || path.win32.isAbsolute(value) || path.posix.isAbsolute(value));
}

function parseInitializeResult(rawResult: unknown): InitializeResult {
  const result = requireRecord(rawResult, "result");
  const protocol = requireRecord(result.protocol, "protocol");
  const backendVersion = requireString(result.backendVersion, "backendVersion");
  const bridgeVersion = requireString(result.bridgeVersion, "bridgeVersion");
  const libsvnVersion = requireString(result.libsvnVersion, "libsvnVersion");
  const platform = requireRecord(result.platform, "platform");
  const cacheSchema = requireCacheSchema(result.cacheSchema);
  const capabilities = requireRecord(result.capabilities, "capabilities");
  const acknowledgedTrustEpoch = requirePositiveInteger(
    result.acknowledgedTrustEpoch,
    "acknowledgedTrustEpoch",
  );
  if (acknowledgedTrustEpoch !== 1) {
    throw invalidInitializeResponse("acknowledgedTrustEpoch");
  }
  requireSupportedCacheSchema(cacheSchema);

  return {
    protocol: {
      major: requireNumber(protocol.major, "protocol.major"),
      minor: requireNumber(protocol.minor, "protocol.minor"),
    },
    backendVersion,
    bridgeVersion,
    libsvnVersion,
    platform: {
      os: requireString(platform.os, "platform.os"),
      arch: requireString(platform.arch, "platform.arch"),
    },
    cacheSchema,
    acknowledgedTrustEpoch,
    capabilities: {
      contentLengthFraming: requireBoolean(
        capabilities.contentLengthFraming,
        "capabilities.contentLengthFraming",
      ),
      realLibsvnBridge: requireBoolean(capabilities.realLibsvnBridge, "capabilities.realLibsvnBridge"),
      repositoryDiscover: requireBoolean(capabilities.repositoryDiscover, "capabilities.repositoryDiscover"),
      repositoryOpen: requireBoolean(capabilities.repositoryOpen, "capabilities.repositoryOpen"),
      repositoryClose: requireBoolean(capabilities.repositoryClose, "capabilities.repositoryClose"),
      repositoryCheckout: requireBoolean(capabilities.repositoryCheckout, "capabilities.repositoryCheckout"),
      statusSnapshot: requireBoolean(capabilities.statusSnapshot, "capabilities.statusSnapshot"),
      statusRefresh: requireBoolean(capabilities.statusRefresh, "capabilities.statusRefresh"),
      statusRemoteCheck: requireBoolean(
        capabilities.statusRemoteCheck,
        "capabilities.statusRemoteCheck",
      ),
      statusStaleNotification: requireBoolean(
        capabilities.statusStaleNotification,
        "capabilities.statusStaleNotification",
      ),
      contentGet: requireBoolean(capabilities.contentGet, "capabilities.contentGet"),
      contentGetRevision: requireBoolean(capabilities.contentGetRevision, "capabilities.contentGetRevision"),
      historyLog: requireBoolean(capabilities.historyLog, "capabilities.historyLog"),
      historyBlame: requireBoolean(capabilities.historyBlame, "capabilities.historyBlame"),
      operationRun: requireBoolean(capabilities.operationRun, "capabilities.operationRun"),
      operationRunAdd: requireBoolean(capabilities.operationRunAdd, "capabilities.operationRunAdd"),
      operationRunRemove: requireBoolean(capabilities.operationRunRemove, "capabilities.operationRunRemove"),
      operationRunMove: requireBoolean(capabilities.operationRunMove, "capabilities.operationRunMove"),
      operationRunCleanup: requireBoolean(capabilities.operationRunCleanup, "capabilities.operationRunCleanup"),
      operationRunResolve: requireBoolean(capabilities.operationRunResolve, "capabilities.operationRunResolve"),
      operationRunUpdate: requireBoolean(capabilities.operationRunUpdate, "capabilities.operationRunUpdate"),
      operationRunUpdateSelectedPath: requireBoolean(
        capabilities.operationRunUpdateSelectedPath,
        "capabilities.operationRunUpdateSelectedPath",
      ),
      operationRunUpdateToRevision: requireBoolean(
        capabilities.operationRunUpdateToRevision,
        "capabilities.operationRunUpdateToRevision",
      ),
      operationRunUpdateDepth: requireBoolean(
        capabilities.operationRunUpdateDepth,
        "capabilities.operationRunUpdateDepth",
      ),
      operationRunUpdateExternalsPolicy: requireBoolean(
        capabilities.operationRunUpdateExternalsPolicy,
        "capabilities.operationRunUpdateExternalsPolicy",
      ),
      propertiesList: requireBoolean(capabilities.propertiesList, "capabilities.propertiesList"),
      operationRunPropertySet: requireBoolean(
        capabilities.operationRunPropertySet,
        "capabilities.operationRunPropertySet",
      ),
      operationRunPropertyDelete: requireBoolean(
        capabilities.operationRunPropertyDelete,
        "capabilities.operationRunPropertyDelete",
      ),
      ignore: requireBoolean(capabilities.ignore, "capabilities.ignore"),
      operationRunChangelistSet: requireBoolean(
        capabilities.operationRunChangelistSet,
        "capabilities.operationRunChangelistSet",
      ),
      operationRunChangelistClear: requireBoolean(
        capabilities.operationRunChangelistClear,
        "capabilities.operationRunChangelistClear",
      ),
      operationRunLock: requireBoolean(capabilities.operationRunLock, "capabilities.operationRunLock"),
      operationRunUnlock: requireBoolean(capabilities.operationRunUnlock, "capabilities.operationRunUnlock"),
      operationRunBranchCreate: requireBoolean(
        capabilities.operationRunBranchCreate,
        "capabilities.operationRunBranchCreate",
      ),
      operationRunSwitch: requireBoolean(capabilities.operationRunSwitch, "capabilities.operationRunSwitch"),
      operationRunCommit: requireBoolean(capabilities.operationRunCommit, "capabilities.operationRunCommit"),
      operationRunCommitMultiPath: requireBoolean(
        capabilities.operationRunCommitMultiPath,
        "capabilities.operationRunCommitMultiPath",
      ),
      diagnosticsGet: requireBoolean(capabilities.diagnosticsGet, "capabilities.diagnosticsGet"),
      credentialRequest: requireBoolean(capabilities.credentialRequest, "capabilities.credentialRequest"),
      certificateRequest: requireBoolean(capabilities.certificateRequest, "capabilities.certificateRequest"),
      remoteOperationEnvelope: requireBoolean(
        capabilities.remoteOperationEnvelope,
        "capabilities.remoteOperationEnvelope",
      ),
      trustedConfigSnapshot: requireBoolean(
        capabilities.trustedConfigSnapshot,
        "capabilities.trustedConfigSnapshot",
      ),
      remoteWorkerIsolation: requireBoolean(
        capabilities.remoteWorkerIsolation,
        "capabilities.remoteWorkerIsolation",
      ),
      credentialLeaseSettlement: requireBoolean(
        capabilities.credentialLeaseSettlement,
        "capabilities.credentialLeaseSettlement",
      ),
      remoteConnectionState: requireBoolean(
        capabilities.remoteConnectionState,
        "capabilities.remoteConnectionState",
      ),
      remoteSvnAnonymous: requireBoolean(
        capabilities.remoteSvnAnonymous,
        "capabilities.remoteSvnAnonymous",
      ),
    },
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function requireRecord(value: unknown, field: string): Record<string, unknown> {
  if (!isRecord(value)) {
    throw invalidInitializeResponse(field);
  }
  return value;
}

function requireString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw invalidInitializeResponse(field);
  }
  return value;
}

function requireNumber(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value)) {
    throw invalidInitializeResponse(field);
  }
  return value;
}

function requirePositiveInteger(value: unknown, field: string): number {
  const number = requireNumber(value, field);
  if (number <= 0) {
    throw invalidInitializeResponse(field);
  }
  return number;
}

function requireBoolean(value: unknown, field: string): boolean {
  if (typeof value !== "boolean") {
    throw invalidInitializeResponse(field);
  }
  return value;
}

function requireCacheSchema(value: unknown): CacheSchema {
  const cacheSchema = requireRecord(value, "cacheSchema");
  return {
    schemaId: requireString(cacheSchema.schemaId, "cacheSchema.schemaId"),
    version: requireNumber(cacheSchema.version, "cacheSchema.version"),
    rollback: requireString(cacheSchema.rollback, "cacheSchema.rollback"),
  };
}

function requireSupportedCacheSchema(cacheSchema: CacheSchema): void {
  if (
    cacheSchema.schemaId !== EXPECTED_CACHE_SCHEMA_ID ||
    cacheSchema.version !== EXPECTED_CACHE_SCHEMA_VERSION ||
    cacheSchema.rollback !== EXPECTED_CACHE_SCHEMA_ROLLBACK
  ) {
    throw new BackendLaunchError(
      "SUBVERSIONR_CACHE_SCHEMA_UNSUPPORTED",
      "protocol",
      "error.backend.cacheSchemaUnsupported",
      {
        schemaId: cacheSchema.schemaId,
        version: cacheSchema.version,
        rollback: cacheSchema.rollback,
      },
    );
  }
}

function invalidInitializeResponse(field: string): BackendLaunchError {
  return new BackendLaunchError(
    "SUBVERSIONR_INITIALIZE_RESPONSE_INVALID",
    "protocol",
    "error.backend.initializeResponseInvalid",
    { field },
  );
}

function requireCapabilities(initializeResult: InitializeResult): void {
  for (const capability of REQUIRED_CAPABILITIES) {
    if (!initializeResult.capabilities[capability]) {
      throw new BackendLaunchError(
        "SUBVERSIONR_BACKEND_CAPABILITY_REQUIRED",
        "protocol",
        "error.backend.capabilityRequired",
        { capability },
      );
    }
  }
}

function requireExactTrustUpdateResponse(rawResult: unknown): { acknowledgedTrustEpoch: number } {
  const result = requireRecord(rawResult, "workspaceTrust.update.result");
  const keys = Object.keys(result);
  if (keys.length !== 1 || keys[0] !== "acknowledgedTrustEpoch") {
    throw new BackendLaunchError(
      "SUBVERSIONR_REMOTE_TRUST_ACK_INVALID",
      "protocol",
      "error.remote.trustAckInvalid",
    );
  }
  return {
    acknowledgedTrustEpoch: requirePositiveInteger(
      result.acknowledgedTrustEpoch,
      "workspaceTrust.update.acknowledgedTrustEpoch",
    ),
  };
}

function terminateChild(child: BackendChildProcess): void {
  child.kill("SIGTERM");
}

class BackendConnectionImpl implements BackendConnection {
  private readonly terminationListeners = new Set<(event: BackendConnectionTermination) => void>();
  private disposed = false;
  private shutdownPromise: Promise<void> | undefined;
  private terminationEmitted = false;
  private currentTrustEpoch: number;
  private remoteSubmissionEnabled: boolean;
  private trustUpdatePromise: Promise<number> | undefined;

  public constructor(
    private readonly child: BackendChildProcess,
    private readonly rpc: JsonRpcStreamClient,
    private readonly collectStderr: (chunk: Buffer | string) => void,
    public readonly initializeResult: InitializeResult,
    initiallyTrusted: boolean,
    private readonly onRequestSettled?: (method: string, params: unknown) => void,
  ) {
    this.currentTrustEpoch = initializeResult.acknowledgedTrustEpoch;
    this.remoteSubmissionEnabled = initiallyTrusted;
    this.child.once("exit", this.handleExit);
    this.child.once("close", this.handleClose);
    this.child.once("error", this.handleProcessError);
  }

  public isRemoteSubmissionEnabled(): boolean {
    return this.remoteSubmissionEnabled && !this.disposed;
  }

  public currentRemoteTrustEpoch(): number {
    return this.currentTrustEpoch;
  }

  public updateWorkspaceTrust(trusted: boolean): Promise<number> {
    if (this.disposed) {
      return Promise.reject(
        new BackendLaunchError(
          "SUBVERSIONR_REMOTE_TRUST_CONNECTION_CLOSED",
          "process",
          "error.remote.trustConnectionClosed",
        ),
      );
    }
    if (this.trustUpdatePromise) {
      return Promise.reject(
        new BackendLaunchError(
          "SUBVERSIONR_REMOTE_TRUST_UPDATE_IN_PROGRESS",
          "protocol",
          "error.remote.trustUpdateInProgress",
        ),
      );
    }
    const trustEpoch = this.currentTrustEpoch + 1;
    if (!Number.isSafeInteger(trustEpoch)) {
      return Promise.reject(
        new BackendLaunchError(
          "SUBVERSIONR_REMOTE_TRUST_EPOCH_EXHAUSTED",
          "protocol",
          "error.remote.trustEpochExhausted",
        ),
      );
    }
    this.remoteSubmissionEnabled = false;
    const update = this.rpc
      .sendRequest<unknown>("workspaceTrust/update", { trusted, trustEpoch })
      .then((rawResult) => {
        const result = requireExactTrustUpdateResponse(rawResult);
        if (result.acknowledgedTrustEpoch !== trustEpoch) {
          throw new BackendLaunchError(
            "SUBVERSIONR_REMOTE_TRUST_ACK_INVALID",
            "protocol",
            "error.remote.trustAckInvalid",
          );
        }
        this.currentTrustEpoch = trustEpoch;
        this.remoteSubmissionEnabled = trusted;
        return trustEpoch;
      })
      .finally(() => {
        if (this.trustUpdatePromise === update) {
          this.trustUpdatePromise = undefined;
        }
      });
    this.trustUpdatePromise = update;
    return update;
  }

  public onDidTerminate(
    listener: (event: BackendConnectionTermination) => void,
  ): BackendConnectionTerminationSubscription {
    this.terminationListeners.add(listener);
    return {
      dispose: () => {
        this.terminationListeners.delete(listener);
      },
    };
  }

  public shutdown(): Promise<void> {
    if (this.shutdownPromise) {
      return this.shutdownPromise;
    }

    this.detachTerminationListeners();
    this.remoteSubmissionEnabled = false;
    this.shutdownPromise = this.rpc
      .sendRequest<{ accepted: boolean }>("shutdown", {})
      .then(() => {
        this.disposeAfterShutdown();
      });
    return this.shutdownPromise;
  }

  public sendRequest<T>(method: string, params: unknown, options?: JsonRpcRequestOptions): Promise<T> {
    const request = this.rpc.sendRequest<T>(method, params, options);
    if (!this.onRequestSettled) {
      return request;
    }
    return request.finally(() => {
      try {
        this.onRequestSettled?.(method, params);
      } catch {
        // Operation-finalization cleanup must not replace the daemon result.
      }
    });
  }

  public waitForCancelledRequestWireSettlement<T>(requestId: number, timeoutMs: number): Promise<T> {
    return this.rpc.waitForCancelledRequestWireSettlement<T>(requestId, timeoutMs);
  }

  public dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.remoteSubmissionEnabled = false;
    this.detachTerminationListeners();
    this.child.stderr.off("data", this.collectStderr);
    this.rpc.dispose(new Error("backend connection disposed"));
    terminateChild(this.child);
  }

  private disposeAfterShutdown(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.detachTerminationListeners();
    this.child.stderr.off("data", this.collectStderr);
    this.rpc.dispose(new Error("backend connection disposed"));
  }

  private readonly handleExit = (exitCode: number | null, signal: NodeJS.Signals | null): void => {
    this.emitTermination({
      reason: "processExit",
      exitCode,
      signal,
    });
  };

  private readonly handleClose = (exitCode: number | null, signal: NodeJS.Signals | null): void => {
    this.emitTermination({
      reason: "processClose",
      exitCode,
      signal,
    });
  };

  private readonly handleProcessError = (error: Error): void => {
    this.emitTermination({
      reason: "processError",
      message: error.message,
    });
  };

  public terminateForProtocolFault(error: Error): void {
    this.emitTermination({
      reason: "protocolFault",
      message: protocolFaultMessage(error),
    });
    terminateChild(this.child);
  }

  private emitTermination(event: BackendConnectionTermination): void {
    if (this.disposed || this.terminationEmitted) {
      return;
    }
    this.terminationEmitted = true;
    this.disposed = true;
    this.detachTerminationListeners();
    this.child.stderr.off("data", this.collectStderr);
    this.rpc.dispose(new Error("backend process terminated"));

    for (const listener of this.terminationListeners) {
      listener(event);
    }
  }

  private detachTerminationListeners(): void {
    this.child.off("exit", this.handleExit);
    this.child.off("close", this.handleClose);
    this.child.off("error", this.handleProcessError);
  }
}

function protocolFaultMessage(error: Error): string {
  return error.message.trim().length > 0 ? error.message : "SUBVERSIONR_BACKEND_PROTOCOL_FAULT";
}

class BoundedTextBuffer {
  private text = "";

  public constructor(private readonly limitBytes: number) {}

  public push(chunk: Buffer | string): void {
    this.text += Buffer.isBuffer(chunk) ? chunk.toString("utf8") : chunk;
    while (Buffer.byteLength(this.text, "utf8") > this.limitBytes) {
      this.text = this.text.slice(1);
    }
  }

  public value(): string {
    return this.text;
  }
}

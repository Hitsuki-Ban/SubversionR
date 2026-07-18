import { randomUUID } from "node:crypto";
import * as nodePath from "node:path";
import type { BackendConnection } from "../backend/backendProcess";
import { JsonRpcStreamError } from "../transport/jsonRpcStreamClient";
import {
  RemoteConnectionStateStore,
  RemoteConnectionStateStoreError,
  type RemoteConnectionState,
} from "../status/remoteConnectionStateStore";
import { RemoteRecoveryService } from "../status/remoteRecoveryService";
import type { RemoteRecoveryRequest } from "../status/remoteRecoveryRpcClient";
import { SourceControlResourceStore } from "../scm/sourceControlResourceStore";
import {
  SourceControlProjectionService,
  type SourceControlProjectionPresenter,
} from "../scm/sourceControlProjectionService";
import { DirtyPathPipeline } from "../status/dirtyPathPipeline";
import { StatusRefreshRpcClient, type StatusDelta } from "../status/statusRefreshRpcClient";
import type { StatusSnapshot } from "../status/statusSnapshotRpcClient";
import { StatusSnapshotStore } from "../status/statusSnapshotStore";
import type { JsonRpcSender } from "../status/types";

const EXPECTED_PROTOCOL_MAJOR = 1;
const EXPECTED_PROTOCOL_MINOR = 35;

export interface InstalledRemoteWorkerReportOptions {
  expectedToken: string | undefined;
  request: unknown;
  targetPath: string;
  initialize(): Promise<Pick<BackendConnection, "initializeResult" | "isRemoteSubmissionEnabled" | "sendRequest">>;
  collectCredentialLeaseReport(): Promise<Record<string, unknown>>;
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
    initialize.capabilities.credentialLeaseSettlement !== true ||
    initialize.capabilities.remoteConnectionState !== true ||
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
  const credentialLeaseReport = await options.collectCredentialLeaseReport();
  const remoteConnectionState = await collectRemoteConnectionStateEvidence();

  return {
    schemaVersion: 3,
    kind: "subversionr.installedRemoteWorkerReport",
    protocol: { major: EXPECTED_PROTOCOL_MAJOR, minor: EXPECTED_PROTOCOL_MINOR },
    remoteWorkerIsolation: true,
    credentialLeaseSettlement: true,
    remoteConnectionState,
    transportResult,
    sameLaneSubsequent: true,
    subsequentDiagnostics: true,
    credentialLeaseReport,
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
    (capabilities as Record<string, unknown>).remoteWorkerIsolation === true &&
    (capabilities as Record<string, unknown>).credentialLeaseSettlement === true &&
    (capabilities as Record<string, unknown>).remoteConnectionState === true
  );
}

async function collectRemoteConnectionStateEvidence(): Promise<Record<string, unknown>> {
  const store = new RemoteConnectionStateStore();
  const observedKinds = new Set<string>();
  const projectedRemoteStates: RemoteConnectionState[] = [];
  store.onDidChange((state) => observedKinds.add(state.kind));
  const projectionService = remoteEvidenceProjectionService((state) => projectedRemoteStates.push(state));
  projectionService.registerRepository({ repositoryId: "fixture-projection", epoch: 1, workingCopyRoot: "C:/fixture" });
  const projectionBefore = projectionService.applySnapshot(remoteEvidenceSnapshot());
  projectionService.updateRemoteConnectionState({
    kind: "unreachable",
    repositoryId: "fixture-projection",
    epoch: 1,
    reason: "timeout",
    incoming: { kind: "stale" },
    recovery: { kind: "notRequired" },
    lastFailure: {
      reason: "networkTimeout",
      cleanupAppropriate: false,
      occurredAt: "2026-07-18T00:00:00.000Z",
    },
  });
  const checked = "00000000-0000-4000-8000-000000000011";
  const failed: string = "00000000-0000-4000-8000-000000000012";
  const recovery: string = "00000000-0000-4000-8000-000000000013";
  const other = "00000000-0000-4000-8000-000000000014";
  const cancelled = "00000000-0000-4000-8000-000000000015";
  const unknown = "00000000-0000-4000-8000-000000000016";
  const startedAt = "2026-07-18T00:00:00.000Z";
  store.registerRepository({ repositoryId: "fixture-primary", epoch: 1 });
  store.registerRepository({ repositoryId: "fixture-unrelated", epoch: 1 });
  const unrelatedBefore = store.getState("fixture-unrelated");
  store.registerRepository({ repositoryId: "fixture-cancelled", epoch: 1 });
  store.registerRepository({ repositoryId: "fixture-unknown", epoch: 1 });
  store.registerRepository({ repositoryId: "fixture-attention", epoch: 1 });
  store.registerRepository({ repositoryId: "fixture-unreachable", epoch: 1 });
  projectionService.registerRepository({ repositoryId: "fixture-primary", epoch: 1, workingCopyRoot: "C:/fixture" });
  projectionService.applySnapshot(remoteEvidenceSnapshot("fixture-primary"));
  store.beginCheck({ repositoryId: "fixture-primary", epoch: 1, operationId: checked, startedAt });
  store.completeOnline({
    repositoryId: "fixture-primary",
    epoch: 1,
    operationId: checked,
    transport: "https",
    checkedAt: startedAt,
    incomingApplied: true,
  });
  store.beginCheck({ repositoryId: "fixture-primary", epoch: 1, operationId: failed, startedAt });
  store.completeFailure({
    repositoryId: "fixture-primary",
    epoch: 1,
    operationId: failed,
    failedAt: startedAt,
    failure: { category: "indeterminate", reason: "workerContainmentFailed", cleanupAppropriate: false },
    workingCopyRecoveryRequired: true,
  });
  let observedRecoveryRequest: RemoteRecoveryRequest | undefined;
  let observedRecoveryChecking: RemoteConnectionState | undefined;
  const recoveryTimes = [startedAt, "2026-07-18T00:00:01.000Z"];
  const recoveryService = new RemoteRecoveryService({
    client: {
      recoverWorkingCopy: async (request) => {
        observedRecoveryRequest = { ...request };
        observedRecoveryChecking = store.getState("fixture-primary");
        return {
          outcome: "blocked",
          operationId: request.operationId,
          failure: { category: "indeterminate", reason: "remoteRecoveryBlocked", cleanupAppropriate: false },
        };
      },
    },
    store,
    projection: projectionService,
    createOperationId: () => recovery,
    now: () => recoveryTimes.shift() ?? "2026-07-18T00:00:02.000Z",
    timeoutMs: 30_000,
  });
  await recoveryService.recover({ repositoryId: "fixture-primary", epoch: 1 });
  let recoveryGateEnforced = false;
  try {
    store.beginCheck({ repositoryId: "fixture-primary", epoch: 1, operationId: other, startedAt });
  } catch (error) {
    recoveryGateEnforced =
      error instanceof RemoteConnectionStateStoreError &&
      error.code === "SUBVERSIONR_REMOTE_STATE_RECOVERY_REQUIRED";
  }
  const primary = store.getState("fixture-primary");
  store.beginCheck({ repositoryId: "fixture-cancelled", epoch: 1, operationId: cancelled, startedAt });
  store.completeFailure({
    repositoryId: "fixture-cancelled",
    epoch: 1,
    operationId: cancelled,
    failedAt: startedAt,
    failure: { category: "cancelled", reason: "operationCancelled", cleanupAppropriate: false },
    workingCopyRecoveryRequired: false,
  });
  store.beginCheck({ repositoryId: "fixture-unknown", epoch: 1, operationId: unknown, startedAt });
  store.completeFailure({
    repositoryId: "fixture-unknown",
    epoch: 1,
    operationId: unknown,
    failedAt: startedAt,
    failure: { category: "attention", reason: "unknownRemote", cleanupAppropriate: false },
    workingCopyRecoveryRequired: false,
  });
  const cancelledState = store.getState("fixture-cancelled");
  const unknownState = store.getState("fixture-unknown");
  store.beginCheck({ repositoryId: "fixture-attention", epoch: 1, operationId: "00000000-0000-4000-8000-000000000017", startedAt });
  store.completeFailure({
    repositoryId: "fixture-attention", epoch: 1,
    operationId: "00000000-0000-4000-8000-000000000017", failedAt: startedAt,
    failure: { category: "attention", reason: "authenticationRequired", cleanupAppropriate: false },
    workingCopyRecoveryRequired: false,
  });
  store.beginCheck({ repositoryId: "fixture-unreachable", epoch: 1, operationId: "00000000-0000-4000-8000-000000000018", startedAt });
  store.completeFailure({
    repositoryId: "fixture-unreachable", epoch: 1,
    operationId: "00000000-0000-4000-8000-000000000018", failedAt: startedAt,
    failure: { category: "unreachable", reason: "networkTimeout", cleanupAppropriate: false },
    workingCopyRecoveryRequired: false,
  });
  const unrelatedAfter = store.getState("fixture-unrelated");
  const projectionAfter = projectionService.getProjection("fixture-projection");
  const localPipelineEvidence = await collectLocalEventZeroNetworkEvidence();
  const stateOrder = ["unchecked", "checking", "online", "attention", "unreachable", "indeterminate"];
  return {
    stateUnion: stateOrder.filter((kind) => observedKinds.has(kind)),
    staleIncomingPreserved: primary?.incoming.kind === "stale" && primary.incoming.lastSuccessfulCheckAt === startedAt,
    localProjectionUnchanged:
      JSON.stringify(localProjectionShape(projectionAfter)) === JSON.stringify(localProjectionShape(projectionBefore)),
    separateRecoveryOperation:
      observedRecoveryRequest?.operationId === recovery &&
      observedRecoveryRequest.originOperationId === failed &&
      observedRecoveryRequest.operationId !== observedRecoveryRequest.originOperationId,
    separateRecoveryDeadline:
      observedRecoveryRequest?.timeoutMs === 30_000 &&
      observedRecoveryChecking?.recovery.kind === "checking" &&
      observedRecoveryChecking.recovery.operationId === observedRecoveryRequest.operationId &&
      Date.parse(observedRecoveryChecking.recovery.deadlineAt) - Date.parse(observedRecoveryChecking.recovery.startedAt) ===
        observedRecoveryRequest.timeoutMs,
    recoveryGateEnforced,
    terminalBlockedStateProjected:
      primary?.kind === "indeterminate" && primary.recovery.kind === "blocked" &&
      projectedRemoteStates.some((state) =>
        state.repositoryId === "fixture-primary" && state.kind === "indeterminate" && state.recovery.kind === "blocked"
      ),
    cancellationSettledWithoutReprompt:
      cancelledState?.kind === "unchecked" && cancelledState.lastFailure?.reason === "operationCancelled",
    unknownFailureRedacted:
      unknownState?.kind === "unchecked" && unknownState.lastFailure?.reason === "unknownRemote",
    unrelatedRepositoryUnchanged:
      unrelatedBefore !== undefined && JSON.stringify(unrelatedAfter) === JSON.stringify(unrelatedBefore),
    localEventZeroNetwork:
      localPipelineEvidence.methods.length === 1 &&
      localPipelineEvidence.methods[0] === "status/refresh" &&
      !localPipelineEvidence.methods.includes("status/remoteCheck"),
  };
}

async function collectLocalEventZeroNetworkEvidence(): Promise<{ methods: string[] }> {
  const methods: string[] = [];
  const snapshot = remoteEvidenceSnapshot("fixture-local-event");
  const sender: JsonRpcSender = {
    sendRequest: async <T>(method: string): Promise<T> => {
      methods.push(method);
      if (method !== "status/refresh") {
        throw reportError("SUBVERSIONR_INSTALLED_REMOTE_LOCAL_EVENT_METHOD_INVALID");
      }
      return remoteEvidenceLocalDelta(snapshot.repositoryId) as T;
    },
  };
  const snapshotStore = new StatusSnapshotStore();
  snapshotStore.registerRepository({ repositoryId: snapshot.repositoryId, epoch: snapshot.epoch });
  snapshotStore.applySnapshot(snapshot);
  const projectionService = remoteEvidenceProjectionService();
  projectionService.registerRepository({
    repositoryId: snapshot.repositoryId,
    epoch: snapshot.epoch,
    workingCopyRoot: snapshot.identity.workingCopyRoot,
  });
  projectionService.applySnapshot(snapshot);
  const pipeline = new DirtyPathPipeline(
    new StatusRefreshRpcClient(sender),
    snapshotStore,
    projectionService,
    { debounceMs: 0 },
  );
  pipeline.registerRepository({
    repositoryId: snapshot.repositoryId,
    epoch: snapshot.epoch,
    workingCopyRoot: snapshot.identity.workingCopyRoot,
    pathCase: "case-insensitive",
  });
  pipeline.accept(snapshot.repositoryId, {
    fsPath: nodePath.join(snapshot.identity.workingCopyRoot, "local.txt"),
    kind: "changed",
    timestamp: 1,
  });
  await pipeline.flushRepository(snapshot.repositoryId);
  return { methods };
}

function remoteEvidenceProjectionService(
  onRemoteState: (state: RemoteConnectionState) => void = () => undefined,
): SourceControlProjectionService {
  const presenter: SourceControlProjectionPresenter = {
    registerRepository: () => undefined,
    updateRepository: () => undefined,
    updateRemoteConnectionState: onRemoteState,
    unregisterRepository: () => undefined,
    isCurrentResourceState: () => false,
  };
  return new SourceControlProjectionService(
    new SourceControlResourceStore({
      countPolicy: { countUnversioned: false, ignoreChangelistsInCount: ["ignore-on-commit"] },
    }),
    presenter,
  );
}

function localProjectionShape(projection: ReturnType<SourceControlProjectionService["getProjection"]>): unknown {
  return projection
    ? { groups: projection.groups, count: projection.count, freshness: projection.freshness }
    : undefined;
}

function remoteEvidenceSnapshot(repositoryId = "fixture-projection"): StatusSnapshot {
  return {
    repositoryId,
    epoch: 1,
    generation: 1,
    completeness: "complete",
    identity: {
      repositoryUuid: "fixture-uuid",
      repositoryRootUrl: "file:///C:/fixture-repo",
      workingCopyRoot: "C:/fixture",
      workspaceScopeRoot: "C:/fixture",
      format: 31,
    },
    localEntries: [remoteEvidenceEntry("local.txt", "modified", "notChecked")],
    remoteEntries: [remoteEvidenceEntry("incoming.txt", "normal", "modified")],
    summary: { localChanges: 1, remoteChanges: 1, conflicts: 0, unversioned: 0 },
    timestamp: "2026-07-18T00:00:00.000Z",
    source: "libsvn-local",
  };
}

function remoteEvidenceEntry(path: string, localStatus: string, remoteStatus: string): StatusSnapshot["localEntries"][number] {
  return {
    path, kind: "file", nodeStatus: localStatus, textStatus: localStatus, propertyStatus: "normal",
    localStatus, remoteStatus, revision: 1, changedRevision: 1, changedAuthor: null, changedDate: null,
    changelist: null, lock: null, needsLock: false, copy: null, move: null, switched: false,
    depth: "infinity", conflict: null, conflictArtifacts: [], external: false, generation: 1,
  };
}

function remoteEvidenceLocalDelta(repositoryId: string): StatusDelta {
  return {
    repositoryId, epoch: 1, generation: 2,
    coverage: [{ path: "local.txt", depth: "empty", generation: 2, reason: "fileChanged" }],
    upsert: [{ ...remoteEvidenceEntry("local.txt", "modified", "notChecked"), generation: 2 }], remove: [],
    remoteUpsert: [], remoteRemove: [],
    summaryDelta: { localChanges: 0, remoteChanges: 0, conflicts: 0, unversioned: 0 },
    completeness: "partial", timestamp: "2026-07-18T00:00:01.000Z", source: "libsvn-local",
  };
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
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value)
    && value !== "00000000-0000-0000-0000-000000000000";
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

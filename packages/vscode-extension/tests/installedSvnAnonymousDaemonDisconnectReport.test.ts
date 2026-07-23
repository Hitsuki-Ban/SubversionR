import { randomUUID } from "node:crypto";
import { rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, expect, it, vi } from "vitest";
import type { BackendConnection } from "../src/backend/backendProcess";
import {
  collectInstalledSvnAnonymousDaemonDisconnectReport,
  type InstalledSvnAnonymousDaemonDisconnectReportOptions,
} from "../src/diagnostics/installedSvnAnonymousDaemonDisconnectReport";
import type { RepositorySession } from "../src/repository/repositorySessionService";
import type { RemoteConnectionNotification } from "../src/status/remoteConnectionNotificationHandler";
import { JsonRpcStreamError } from "../src/transport/jsonRpcStreamClient";

const TOKEN = "1234567890abcdef1234567890abcdef";
const REPOSITORY_URL = "svn://127.0.0.1:3693/repo/trunk";
const WORKING_COPY_PATH = "C:/evidence/i6-daemon-disconnect-wc";
const FIXTURE_STATE_PATH = "C:/evidence/i6-daemon-disconnect-fixture-state.json";
const OPERATION_ID = "80000000-0000-4000-8000-000000000001";
const REPOSITORY_ID = "repo-uuid:C:/evidence/i6-daemon-disconnect-wc";

describe("installed SVN anonymous daemon disconnect report", () => {
  it("observes exact active settlement and daemon state before production shutdown ack", async () => {
    const harness = createHarness();
    try {
      const report = await collectWithTrigger(harness);
      expect(report).toEqual({
        schema: "subversionr.release.m8-i6-installed-vsix-daemon-disconnect.v1",
        schemaVersion: 1,
        kind: "subversionr.installedSvnAnonymousDaemonDisconnectReport",
        scenario: "daemonDisconnect",
        settlement: {
          code: "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED", category: "state",
          messageKey: "error.remote.workerDisconnected", retryable: false,
          safeArgs: { remoteFailure: { category: "process", reason: "workerContainmentFailed", cleanupAppropriate: false } },
          diagnostics: null,
        },
        daemonState: {
          kind: "indeterminate", reason: "workerTerminated", originOperationIdMatched: true,
          recovery: "notRequired", cleanupAppropriate: false, repositoryIdMatched: true, epochMatched: true,
        },
        daemonDisconnectSettlement: {
          trigger: "graceful-client-shutdown-after-greeting", activeRequestSettlementObserved: true,
          daemonStateObserved: true, settlementBeforeShutdownAck: true, shutdownAcknowledged: true,
          workingCopyPreserved: true,
        },
        protocol: { major: 1, minor: 35 },
        trust: { acknowledgedEpoch: 7, consistentUntilShutdown: true },
        authActivity: { credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 },
        repositorySession: { opened: true, terminatedByShutdown: true },
        diagnosticsRedacted: true,
        redaction: { rawUrls: false, rawPaths: false, rawContent: false },
      });
      expect(harness.options.shutdownBackend).toHaveBeenCalledOnce();
      expect(harness.order.at(-1)).toBe("shutdownBackendResolved");
      expect(harness.sendRequest).toHaveBeenCalledWith("status/checkRemote", {
        repositoryId: REPOSITORY_ID, epoch: 7, remote: expectedRemote(),
      });
    } finally { await harness.cleanup(); }
  });

  it("rejects every non-exact disconnect settlement component", async () => {
    const cases: Array<Record<string, unknown>> = [
      { code: "SUBVERSIONR_REMOTE_WORKER_CANCELLED" },
      { category: "cancelled" },
      { messageKey: "error.remote.workerCancelled" },
      { retryable: true },
      { diagnostics: {} },
      { failureReason: "operationCancelled" },
      { cleanupAppropriate: true },
      { safeArgsExtra: true },
    ];
    for (const disconnect of cases) {
      const harness = createHarness({ disconnect });
      try {
        await expect(collectWithTrigger(harness)).rejects.toMatchObject({
          code: expect.stringMatching(/^SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_(WIRE|FAILURE)_INVALID$/u),
        });
      } finally { await harness.cleanup(); }
    }
  });

  it("rejects shutdown ack before the active response/state pair", async () => {
    const harness = createHarness({ ackFirst: true });
    try {
      await expect(collectWithTrigger(harness)).rejects.toMatchObject({
        code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_ORDER_INVALID",
      });
    } finally { await harness.cleanup(); }
  });

  it("rejects request aliases and a pre-existing shutdown trigger before initialization", async () => {
    const invalid = createHarness();
    try {
      invalid.options.request = { ...request(invalid.triggerPath), triggerPath: invalid.triggerPath };
      await expect(collectInstalledSvnAnonymousDaemonDisconnectReport(invalid.options)).rejects.toMatchObject({
        code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_REQUEST_INVALID",
      });
      expect(invalid.options.initialize).not.toHaveBeenCalled();
    } finally { await invalid.cleanup(); }

    const dirty = createHarness();
    try {
      await writeFile(dirty.triggerPath, "");
      await expect(collectInstalledSvnAnonymousDaemonDisconnectReport(dirty.options)).rejects.toMatchObject({
        code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_TRIGGER_INVALID",
      });
      expect(dirty.options.initialize).not.toHaveBeenCalled();
    } finally { await dirty.cleanup(); }
  });

  it("rejects forbidden fixture progress, stale store mismatch, and auth activity", async () => {
    for (const config of [
      { finalFixture: fixtureState({ commandsReceived: 1 }) },
      { storedRecovery: "required" as const },
      { mutateAuth: true },
    ]) {
      const harness = createHarness(config);
      try {
        await expect(collectWithTrigger(harness)).rejects.toMatchObject({
          code: expect.stringMatching(/^SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_(?:FIXTURE_STATE|STORED_STATE|AUTH_ACTIVITY)_INVALID$/u),
        });
      } finally { await harness.cleanup(); }
    }
  });
});

function createHarness(config: {
  disconnect?: Record<string, unknown>;
  ackFirst?: boolean;
  finalFixture?: Record<string, unknown>;
  storedRecovery?: "notRequired" | "required";
  mutateAuth?: boolean;
} = {}) {
  const triggerPath = path.join(os.tmpdir(), `subversionr-daemon-disconnect-${randomUUID()}.trigger`);
  const listeners = new Set<(state: RemoteConnectionNotification) => void>();
  const auth = { credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 };
  const order: string[] = [];
  let rejectRemote!: (error: unknown) => void;
  const remoteResult = new Promise<never>((_resolve, reject) => { rejectRemote = reject; });
  const sendRequest = vi.fn(async (method: string, params: unknown): Promise<unknown> => {
    expect(method).toBe("status/checkRemote");
    expect(params).toEqual({ repositoryId: REPOSITORY_ID, epoch: 7, remote: expectedRemote() });
    for (const listener of listeners) listener(checkingNotification());
    return remoteResult;
  });
  const connection = {
    initializeResult: initializeResult(),
    isRemoteSubmissionEnabled: () => true,
    currentRemoteTrustEpoch: () => 7,
    sendRequest,
  } as unknown as BackendConnection;
  const finalFixture = config.finalFixture ?? fixtureState({ connections: 1, greetingSent: 1, clientResponseReceived: 1 });
  const fixtureValues = [fixtureState(), finalFixture, finalFixture];
  const shutdownBackend = vi.fn(async () => {
    const settle = () => {
      order.push("activeRequestSettlement");
      rejectRemote(disconnectError(config.disconnect));
      order.push("daemonState");
      for (const listener of listeners) listener(terminalNotification());
      if (config.mutateAuth) auth.credentialRequests += 1;
    };
    if (config.ackFirst) {
      order.push("shutdownBackendResolved");
      setTimeout(settle, 1);
      return;
    }
    settle();
    await new Promise((resolve) => setTimeout(resolve, 1));
    order.push("shutdownBackendResolved");
  });
  const options: InstalledSvnAnonymousDaemonDisconnectReportOptions = {
    expectedToken: TOKEN,
    request: request(triggerPath),
    initialize: vi.fn().mockResolvedValue(connection),
    shutdownBackend,
    openWorkingCopy: vi.fn().mockResolvedValue(session()),
    onDaemonRemoteStateChange: (listener) => {
      listeners.add(listener);
      return { dispose: () => listeners.delete(listener) };
    },
    getRemoteState: () => storedState(config.storedRecovery ?? "notRequired"),
    readFixtureState: vi.fn(async () => fixtureValues.shift() ?? finalFixture),
    authActivity: () => ({ ...auth }),
  };
  return { options, sendRequest, triggerPath, order, cleanup: () => rm(triggerPath, { force: true }) };
}

async function collectWithTrigger(harness: ReturnType<typeof createHarness>) {
  const result = collectInstalledSvnAnonymousDaemonDisconnectReport(harness.options);
  void result.catch(() => undefined);
  await waitFor(() => harness.sendRequest.mock.calls.length === 1);
  await writeFile(harness.triggerPath, "", { flag: "wx" });
  return await result;
}

function disconnectError(overrides: Record<string, unknown> = {}): JsonRpcStreamError {
  const safeArgs: Record<string, unknown> = {
    remoteFailure: {
      category: "process",
      reason: overrides.failureReason ?? "workerContainmentFailed",
      cleanupAppropriate: overrides.cleanupAppropriate ?? false,
    },
  };
  if (overrides.safeArgsExtra === true) safeArgs.extra = true;
  const error = new JsonRpcStreamError({
    code: String(overrides.code ?? "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED"),
    category: String(overrides.category ?? "state"),
    messageKey: String(overrides.messageKey ?? "error.remote.workerDisconnected"),
    args: safeArgs,
    retryable: overrides.retryable === true,
    diagnostics: null,
  });
  if ("diagnostics" in overrides) Object.defineProperty(error, "diagnostics", { value: overrides.diagnostics });
  return error;
}

function request(triggerPath: string): Record<string, unknown> {
  return {
    token: TOKEN, repositoryUrl: REPOSITORY_URL, workingCopyPath: WORKING_COPY_PATH,
    operationId: OPERATION_ID, fixtureStatePath: FIXTURE_STATE_PATH, shutdownTriggerPath: triggerPath,
  };
}
function fixtureState(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    schema: "subversionr.release.m8-i6-ra-svn-fault-fixture.v1", pid: 1234, port: 3693,
    suppliedAuthorityPort: 0, scenario: "greeting-stall", status: "ready", connections: 0,
    suppliedAuthorityConnections: 0, greetingSent: 0, clientResponseReceived: 0,
    authRequestSent: 0, reposInfoSent: 0, commandsReceived: 0, followupContacts: 0, ...overrides,
  };
}
function checkingNotification(): RemoteConnectionNotification {
  return { repositoryId: REPOSITORY_ID, epoch: 7, state: { kind: "checking", operationId: OPERATION_ID, startedAt: "2026-07-20T00:00:00Z" } };
}
function terminalNotification(): RemoteConnectionNotification {
  return {
    repositoryId: REPOSITORY_ID, epoch: 7,
    state: { kind: "indeterminate", reason: "workerTerminated", originOperationId: OPERATION_ID, recovery: "notRequired", cleanupAppropriate: false },
  };
}
function storedState(recovery: "notRequired" | "required"): ReturnType<InstalledSvnAnonymousDaemonDisconnectReportOptions["getRemoteState"]> {
  return {
    repositoryId: REPOSITORY_ID, epoch: 7, kind: "indeterminate", reason: "workerTerminated",
    incoming: { kind: "stale" },
    recovery: recovery === "notRequired" ? { kind: "notRequired" } : { kind: "required", operationId: OPERATION_ID, requiredAt: "2026-07-20T00:00:00Z" },
    lastFailure: { reason: "workerContainmentFailed", cleanupAppropriate: false, occurredAt: "2026-07-20T00:00:00Z" },
  };
}
function session(): RepositorySession {
  return {
    repositoryId: REPOSITORY_ID, epoch: 7,
    identity: { repositoryUuid: "repo-uuid", repositoryRootUrl: REPOSITORY_URL, workingCopyRoot: WORKING_COPY_PATH, workspaceScopeRoot: WORKING_COPY_PATH, format: 31 },
    watchScope: { repositoryId: REPOSITORY_ID, epoch: 7, workingCopyRoot: WORKING_COPY_PATH, boundaryRoots: [], pathCase: "case-insensitive" },
  };
}
function expectedRemote(): Record<string, unknown> {
  const endpoint = { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: 3693 };
  return {
    version: 1, operationId: OPERATION_ID, intent: "foreground", interaction: "allowed", timeoutMs: 30_000,
    workspaceTrust: "trusted", trustEpoch: 7,
    profile: { schema: "subversionr.remote-profile.v1", profileId: "installed-i6-svn-anonymous-daemon-disconnect", authority: endpoint, serverAuth: "anonymous", serverAccount: "none", serverCredentialPersistence: "secretStorage", proxy: "none", ssh: "none", redirectPolicy: "rejectAll" },
    expectedOrigin: endpoint,
  };
}
function initializeResult(): BackendConnection["initializeResult"] {
  return {
    protocol: { major: 1, minor: 35 },
    capabilities: { realLibsvnBridge: true, repositoryOpen: true, statusRemoteCheck: true, remoteOperationEnvelope: true, remoteWorkerIsolation: true, remoteConnectionState: true, remoteSvnAnonymous: true },
    acknowledgedTrustEpoch: 7,
  } as BackendConnection["initializeResult"];
}
async function waitFor(condition: () => boolean): Promise<void> {
  const deadline = Date.now() + 2_000;
  while (!condition()) { if (Date.now() >= deadline) throw new Error("test condition timeout"); await new Promise((resolve) => setTimeout(resolve, 1)); }
}

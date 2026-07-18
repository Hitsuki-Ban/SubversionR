import { describe, expect, it, vi } from "vitest";
import type { BackendConnection } from "../src/backend/backendProcess";
import {
  collectInstalledSvnAnonymousReport,
  type InstalledSvnAnonymousAuthActivity,
  type InstalledSvnAnonymousReportOptions,
} from "../src/diagnostics/installedSvnAnonymousReport";
import type { RepositorySession } from "../src/repository/repositorySessionService";
import type { ScmRepositoryProjection } from "../src/scm/sourceControlResourceStore";
import type { StatusDelta } from "../src/status/statusRefreshRpcClient";

const TOKEN = "installed-i6-token";
const REPOSITORY_URL = "svn://127.0.0.1:3691/repo/trunk";
const CHECKOUT_PATH = "C:/evidence/i6-checkout";
const FILE_PATH = "src/main.txt";
const REPOSITORY_ID = "fixture-uuid:C:/evidence/i6-checkout";

describe("installed SVN anonymous report", () => {
  it("executes all real typed RPC surfaces with unique envelopes and emits only redacted machine evidence", async () => {
    const observedEnvelopes: Array<Record<string, unknown>> = [];
    const sendRequest = vi.fn(async (method: string, params: unknown): Promise<unknown> => {
      const request = params as Record<string, unknown>;
      if ("remote" in request) {
        observedEnvelopes.push(request.remote as Record<string, unknown>);
      }
      if (method === "repository/checkout") return { workingCopyPath: CHECKOUT_PATH, revision: 1 };
      if (method === "status/checkRemote") return remoteDelta();
      if (method === "content/get") return contentResponse();
      if (method === "history/log") return logResponse();
      if (method === "history/blame") return blameResponse();
      if (method === "operation/run") return operationResponse(request.kind as string);
      throw new Error(`unexpected method: ${method}`);
    });
    let generation = 1;
    const projection = () => freshProjection(generation);
    const append = vi.fn(async () => undefined);
    const fullReconcile = vi.fn(async () => {
      generation += 1;
    });
    let operationIndex = 0;
    const options = baseOptions();
    const closeRepository = options.closeRepository as ReturnType<typeof vi.fn>;
    const report = await collectInstalledSvnAnonymousReport({
      ...options,
      initialize: vi.fn().mockResolvedValue(connection(sendRequest)),
      getProjection: projection,
      applyRemoteStatusDelta: async () => {
        generation += 1;
      },
      fullReconcile,
      appendFile: append,
      createOperationId: () => `00000000-0000-4000-8000-${String(++operationIndex).padStart(12, "0")}`,
    });

    expect(report).toMatchObject({
      schemaVersion: 1,
      kind: "subversionr.installedSvnAnonymousReport",
      protocol: { major: 1, minor: 35 },
      origin: { scheme: "svn", loopback: true, consistent: true },
      trust: { acknowledgedEpoch: 7, consistent: true },
      remoteOperationCount: 11,
      uniqueOperationIds: true,
      semanticValidation: {
        checkoutRevision: 1,
        updateRevision: 3,
        commitRevision: 4,
        branchRevision: 5,
        switchRevision: 5,
        finalProjectionGeneration: 11,
        freshReconcile: true,
      },
      authActivity: { credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 },
      redaction: { rawUrls: false, rawPaths: false, rawContent: false },
    });
    expect(report.operations).toEqual([
      "checkoutOpen", "remoteStatus", "content", "historyLog", "historyBlame", "update", "commit",
      "branchCopy", "switch", "lock", "unlock",
    ]);
    expect(observedEnvelopes).toHaveLength(11);
    expect(new Set(observedEnvelopes.map((remote) => remote.operationId)).size).toBe(11);
    expect(observedEnvelopes.every((remote) => remote.trustEpoch === 7)).toBe(true);
    expect(observedEnvelopes.every((remote) => JSON.stringify(remote.expectedOrigin) === JSON.stringify({
      scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: 3691,
    }))).toBe(true);
    expect(observedEnvelopes.every((remote) => (remote.profile as Record<string, unknown>).serverAuth === "anonymous")).toBe(true);
    expect(sendRequest.mock.calls.map(([method]) => method)).toEqual([
      "repository/checkout",
      "status/checkRemote",
      "content/get",
      "history/log",
      "history/blame",
      "operation/run",
      "operation/run",
      "operation/run",
      "operation/run",
      "operation/run",
      "operation/run",
    ]);
    expect(sendRequest.mock.calls.slice(5).map(([, params]) => (params as Record<string, unknown>).kind)).toEqual([
      "update", "commit", "branchCreate", "switch", "lock", "unlock",
    ]);
    expect(sendRequest.mock.calls[7]?.[1]).toMatchObject({
      options: {
        sourceUrl: REPOSITORY_URL,
        destinationUrl: "svn://127.0.0.1:3691/repo/branches/i6",
        makeParents: false,
      },
    });
    expect(append).toHaveBeenCalledWith(
      expect.stringMatching(/[\\/]src[\\/]main\.txt$/),
      "\nSubversionR installed I6 anonymous evidence mutation.\n",
    );
    expect(fullReconcile).toHaveBeenCalledTimes(9);
    expect(closeRepository).toHaveBeenCalledOnce();
    expect(closeRepository).toHaveBeenCalledWith(REPOSITORY_ID);
    const serialized = JSON.stringify(report);
    expect(serialized).not.toContain(REPOSITORY_URL);
    expect(serialized).not.toContain(CHECKOUT_PATH);
    expect(serialized).not.toContain(FILE_PATH);
    expect(serialized).not.toContain("evidence mutation");
    expect(serialized).not.toContain("00000000-0000-4000");
  });

  it("fails closed without the one-shot token and rejects non-loopback origins before initialization", async () => {
    const forbidden = baseOptions();
    forbidden.expectedToken = undefined;
    await expect(collectInstalledSvnAnonymousReport(forbidden)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REPORT_FORBIDDEN",
    });
    expect(forbidden.initialize).not.toHaveBeenCalled();

    const external = baseOptions();
    external.request = { ...request(), repositoryUrl: "svn://svn.example.invalid/repo/trunk" };
    await expect(collectInstalledSvnAnonymousReport(external)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_ORIGIN_INVALID",
    });
    expect(external.initialize).not.toHaveBeenCalled();
  });

  it("rejects stale projection settlement and any real authentication activity", async () => {
    const stale = successfulOptions();
    stale.getProjection = () => ({
      ...freshProjection(1),
      freshness: {
        repositoryCompleteness: "stale",
        lastRefreshCompleteness: "stale",
        lastRefreshKind: "stale",
      },
    });
    await expect(collectInstalledSvnAnonymousReport(stale)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECONCILE_INVALID",
    });

    const activity = successfulOptions();
    let reads = 0;
    activity.authActivity = () => ({
      credentialRequests: reads++ === 0 ? 0 : 1,
      credentialSettlements: 0,
      certificateRequests: 0,
    });
    await expect(collectInstalledSvnAnonymousReport(activity)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTH_ACTIVITY_INVALID",
    });
  });
});

function successfulOptions(): InstalledSvnAnonymousReportOptions {
  let generation = 1;
  let operationIndex = 0;
  return {
    ...baseOptions(),
    initialize: vi.fn().mockResolvedValue(connection(async (method, params) => {
      if (method === "repository/checkout") return { workingCopyPath: CHECKOUT_PATH, revision: 1 };
      if (method === "status/checkRemote") return remoteDelta();
      if (method === "content/get") return contentResponse();
      if (method === "history/log") return logResponse();
      if (method === "history/blame") return blameResponse();
      if (method === "operation/run") return operationResponse((params as Record<string, unknown>).kind as string);
      throw new Error(`unexpected method: ${method}`);
    })),
    applyRemoteStatusDelta: async () => { generation += 1; },
    fullReconcile: async () => { generation += 1; },
    getProjection: () => freshProjection(generation),
    createOperationId: () => `00000000-0000-4000-8000-${String(++operationIndex).padStart(12, "0")}`,
  };
}

function baseOptions(): InstalledSvnAnonymousReportOptions {
  return {
    expectedToken: TOKEN,
    request: request(),
    initialize: vi.fn(),
    openWorkingCopy: vi.fn().mockResolvedValue(session()),
    closeRepository: vi.fn().mockResolvedValue(undefined),
    applyRemoteStatusDelta: vi.fn(),
    fullReconcile: vi.fn(),
    getProjection: () => freshProjection(1),
    appendFile: vi.fn().mockResolvedValue(undefined),
    authActivity: () => zeroAuthActivity(),
  };
}

function request(): Record<string, unknown> {
  return {
    token: TOKEN,
    repositoryUrl: REPOSITORY_URL,
    checkoutPath: CHECKOUT_PATH,
    checkoutRevision: 1,
    filePath: FILE_PATH,
  };
}

function connection(
  sendRequest: (method: string, params: unknown) => Promise<unknown>,
): Pick<BackendConnection, "initializeResult" | "isRemoteSubmissionEnabled" | "currentRemoteTrustEpoch" | "sendRequest"> {
  return {
    initializeResult: {
      protocol: { major: 1, minor: 35 },
      acknowledgedTrustEpoch: 7,
      capabilities: {
        realLibsvnBridge: true,
        repositoryCheckout: true,
        repositoryOpen: true,
        statusSnapshot: true,
        statusRefresh: true,
        statusRemoteCheck: true,
        contentGet: true,
        contentGetRevision: true,
        historyLog: true,
        historyBlame: true,
        operationRun: true,
        operationRunUpdate: true,
        operationRunCommit: true,
        operationRunBranchCreate: true,
        operationRunSwitch: true,
        operationRunLock: true,
        operationRunUnlock: true,
        remoteOperationEnvelope: true,
        remoteWorkerIsolation: true,
        remoteConnectionState: true,
        remoteSvnAnonymous: true,
      },
    } as BackendConnection["initializeResult"],
    isRemoteSubmissionEnabled: () => true,
    currentRemoteTrustEpoch: () => 7,
    sendRequest: sendRequest as BackendConnection["sendRequest"],
  };
}

function session(): RepositorySession {
  return {
    repositoryId: REPOSITORY_ID,
    epoch: 1,
    identity: {
      repositoryUuid: "fixture-uuid",
      repositoryRootUrl: "svn://127.0.0.1:3691/repo",
      workingCopyRoot: CHECKOUT_PATH,
      workspaceScopeRoot: CHECKOUT_PATH,
      format: 31,
    },
    watchScope: {} as RepositorySession["watchScope"],
  };
}

function freshProjection(generation: number): ScmRepositoryProjection {
  return {
    repositoryId: REPOSITORY_ID,
    epoch: 1,
    workingCopyRoot: CHECKOUT_PATH,
    generation,
    freshness: {
      repositoryCompleteness: "complete",
      lastRefreshCompleteness: "complete",
      lastRefreshKind: generation === 1 ? "snapshot" : "delta",
    },
    count: 0,
    groups: [],
  };
}

function remoteDelta(): StatusDelta {
  return {
    repositoryId: REPOSITORY_ID,
    epoch: 1,
    generation: 2,
    coverage: [{ path: ".", depth: "workingCopy", generation: 2, reason: "manualRemoteCheck" }],
    upsert: [],
    remove: [],
    remoteUpsert: [statusEntry()],
    remoteRemove: [],
    summaryDelta: { localChanges: 0, remoteChanges: 1, conflicts: 0, unversioned: 0 },
    completeness: "complete",
    timestamp: "2026-07-18T00:00:00.000Z",
    source: "libsvn-remote",
  };
}

function statusEntry() {
  return {
    path: FILE_PATH,
    kind: "file",
    nodeStatus: "normal",
    textStatus: "normal",
    propertyStatus: "normal",
    localStatus: "normal",
    remoteStatus: "modified",
    revision: 1,
    changedRevision: 2,
    changedAuthor: null,
    changedDate: null,
    changelist: null,
    lock: null,
    needsLock: false,
    copy: null,
    move: null,
    switched: false,
    depth: "infinity",
    conflict: null,
    conflictArtifacts: [],
    external: false,
    generation: 2,
  };
}

function contentResponse() {
  return {
    repositoryId: REPOSITORY_ID,
    epoch: 1,
    path: FILE_PATH,
    revision: "head",
    contentBase64: "YWxwaGEK",
    byteLength: 6,
    mimeType: "text/plain",
    isBinary: false,
    source: "libsvn-head",
  };
}

function logResponse() {
  return {
    repositoryId: REPOSITORY_ID,
    epoch: 1,
    path: FILE_PATH,
    startRevision: "head",
    endRevision: "r0",
    limit: 32,
    entries: [{
      revision: 2,
      author: null,
      date: null,
      message: null,
      changedPaths: [],
      hasChildren: false,
      nonInheritable: false,
      subtractiveMerge: false,
    }],
    source: "libsvn-log",
  };
}

function blameResponse() {
  return {
    repositoryId: REPOSITORY_ID,
    epoch: 1,
    path: FILE_PATH,
    pegRevision: "head",
    startRevision: "r0",
    endRevision: "head",
    resolvedStartRevision: 0,
    resolvedEndRevision: 2,
    lineStart: 1,
    lineLimit: 5_000,
    ignoreWhitespace: "none",
    ignoreEolStyle: false,
    ignoreMimeType: false,
    includeMergedRevisions: false,
    hasMore: false,
    lines: [{
      lineNumber: 1,
      revision: 2,
      author: null,
      date: null,
      mergedRevision: null,
      mergedAuthor: null,
      mergedDate: null,
      mergedPath: null,
      lineBase64: "YWxwaGE=",
      byteLength: 5,
      localChange: false,
    }],
    source: "libsvn-blame",
  };
}

function operationResponse(kind: string) {
  const revision = kind === "update" ? 3 : kind === "commit" ? 4 : kind === "branchCreate" || kind === "switch" ? 5 : null;
  const touchedPaths = kind === "branchCreate" ? [] : [kind === "update" || kind === "switch" ? "." : FILE_PATH];
  const requiresFullReconcile = kind === "update" || kind === "switch";
  return {
    repositoryId: REPOSITORY_ID,
    epoch: 1,
    operationId: `daemon-${kind}`,
    kind,
    touchedPaths,
    revision,
    summary: { affectedPaths: touchedPaths.length, skippedPaths: 0 },
    warnings: [],
    reconcile: {
      targets: kind === "branchCreate" || requiresFullReconcile
        ? []
        : [{ path: FILE_PATH, depth: "empty", reason: `operation${kind[0]!.toUpperCase()}${kind.slice(1)}` }],
      requiresFullReconcile,
    },
  };
}

function zeroAuthActivity(): InstalledSvnAnonymousAuthActivity {
  return { credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 };
}

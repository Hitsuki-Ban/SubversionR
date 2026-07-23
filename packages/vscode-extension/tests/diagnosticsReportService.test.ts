import { describe, expect, it, vi } from "vitest";
import { BackendLaunchError, type BackendConnection, type InitializeResult } from "../src/backend/backendProcess";
import type { BackendLifecycleState } from "../src/backend/backendService";
import { collectDiagnosticsBundle, collectVersionReport } from "../src/diagnostics/diagnosticsReportService";
import type { OperationJournalEntry } from "../src/operations/repositoryOperationJournal";
import type { WatcherOverflowDiagnosticsSnapshot } from "../src/status/watcherOverflowDiagnostics";

describe("diagnostics report service", () => {
  it("collects extension backend bridge and libsvn versions without leaking packaged paths", async () => {
    const report = await collectVersionReport({
      context: diagnosticsContext(),
      backendService: diagnosticsBackendService(vi.fn().mockResolvedValue(fakeConnection())),
    });

    expect(report.extension).toEqual({
      name: "SubversionR",
      version: "0.1.0",
    });
    expect(report.backend as Record<string, unknown>).toMatchObject({
      status: "initialized",
      backendVersion: "0.1.0",
      bridgeVersion: "subversionr-svn-bridge/0.1.0",
      libsvnVersion: "1.14.5",
      cacheSchema: {
        schemaId: "subversionr.cache.v1",
        version: 1,
        rollback: "delete-and-reconcile",
      },
    });
    expect(JSON.stringify(report)).not.toContain("resources\\backend");
  });

  it("reports backend startup errors with recursively redacted safe args", async () => {
    const report = await collectVersionReport({
      context: diagnosticsContext(),
      backendService: diagnosticsBackendService(
        vi.fn().mockRejectedValue(
          new BackendLaunchError("SUBVERSIONR_BACKEND_EXITED", "process", "error.backend.exitedDuringInitialize", {
            stderr:
              "https://alice:hunter2@example.com/repos/project?token=abc123 failed at C:\\Users\\Alice\\wc\\secret.txt",
            executablePath: "C:\\Users\\Alice\\tools\\subversionr-daemon.exe",
          }),
        ),
      ),
    });

    const json = JSON.stringify(report);
    const backend = report.backend as Record<string, unknown>;
    expect(backend.status).toBe("unavailable");
    expect(json).toContain("SUBVERSIONR_BACKEND_EXITED");
    expect(json).not.toContain("hunter2");
    expect(json).not.toContain("abc123");
    expect(json).not.toContain("Alice");
    expect(json).not.toContain("example.com");
  });

  it("includes degraded backend lifecycle and restart backoff in version diagnostics", async () => {
    const lifecycle: BackendLifecycleState = {
      status: "degraded",
      reason: "startupFailed",
      since: 1000,
      consecutiveFailures: 2,
      restartAfter: 3000,
      lastErrorCode: "SUBVERSIONR_BACKEND_EXITED",
    };

    const report = await collectVersionReport({
      context: diagnosticsContext(),
      backendService: diagnosticsBackendService(
        vi.fn().mockRejectedValue(
          new BackendLaunchError("SUBVERSIONR_BACKEND_EXITED", "process", "error.backend.exitedDuringInitialize", {}),
        ),
        lifecycle,
      ),
    });

    expect(report.backend).toMatchObject({
      status: "unavailable",
      lifecycle,
    });
  });

  it("collects a default diagnostics bundle with counts only and no backend path settings", async () => {
    const connection = fakeConnection({
      repositorySummary: {
        openRepositories: 3,
        cachedLocalEntries: 42,
      },
    });
    const bundle = await collectDiagnosticsBundle({
      context: diagnosticsContext({
        vscode: {
          version: "1.101.0",
          appName: "Visual Studio Code",
          uiKind: "desktop",
          remoteName: "ssh-remote+alice@example.com",
        },
        workspace: {
          trusted: true,
          workspaceFolders: ["C:\\Users\\Alice\\checkout\\project", "/home/alice/secret-project"],
        },
      }),
      backendService: diagnosticsBackendService(vi.fn().mockResolvedValue(connection)),
      operationJournal: operationJournal(),
      watcherOverflowDiagnostics: watcherOverflowDiagnostics(),
    });

    expect(bundle.kind).toBe("subversionr.diagnosticsBundle");
    expect(bundle.workspace).toEqual({
      trusted: true,
      folderCount: 2,
    });
    expect(bundle.settings).toEqual({
      backend: {
        source: "packaged",
      },
    });
    expect(bundle.repositorySummary).toMatchObject({
      openRepositories: 3,
      cachedLocalEntries: 42,
    });
    expect(connection.sendRequest).toHaveBeenCalledWith("diagnostics/get", {});
    const json = JSON.stringify(bundle);
    expect(json).not.toContain("Alice");
    expect(json).not.toContain("secret-project");
    expect(json).not.toContain("example.com");
    expect(json).not.toContain("subversionr-daemon.exe");
  });

  it("includes sanitized watcher overflow diagnostics in diagnostics bundles", async () => {
    const bundle = await collectDiagnosticsBundle({
      context: diagnosticsContext(),
      backendService: diagnosticsBackendService(vi.fn().mockResolvedValue(fakeConnection())),
      operationJournal: operationJournal(),
      watcherOverflowDiagnostics: watcherOverflowDiagnostics({
        overflowCount: 2,
        lastOverflow: {
          repositoryHash: "0123456789abcdef",
          epoch: 7,
          timestamp: "2026-06-25T00:00:00Z",
          source: "native-watcher",
        },
      }),
    });

    expect(bundle.metrics).toMatchObject({
      watcher: {
        overflowCount: 2,
        lastOverflow: {
          repositoryHash: "0123456789abcdef",
          epoch: 7,
          timestamp: "2026-06-25T00:00:00Z",
          source: "native-watcher",
        },
      },
    });
    expect(JSON.stringify(bundle.metrics)).not.toContain("C:\\Users");
    expect(JSON.stringify(bundle.metrics)).not.toContain("repo-uuid");
  });

  it("records a redacted diagnostics rpc failure instead of silently defaulting counts", async () => {
    const bundle = await collectDiagnosticsBundle({
      context: diagnosticsContext(),
      backendService: diagnosticsBackendService(
        vi.fn().mockResolvedValue({
          ...fakeConnection(),
          sendRequest: vi.fn().mockRejectedValue(
            new Error("diagnostics/get failed for https://alice:hunter2@example.com/repos"),
          ),
        }),
      ),
      operationJournal: operationJournal(),
      watcherOverflowDiagnostics: watcherOverflowDiagnostics(),
    });

    expect(bundle.repositorySummary).toBeUndefined();
    const json = JSON.stringify(bundle);
    expect(json).toContain("SUBVERSIONR_BACKEND_DIAGNOSTICS_RPC_FAILED");
    expect(json).not.toContain("hunter2");
    expect(json).not.toContain("example.com");
  });

  it("includes recent sanitized operation journal entries in diagnostics bundles", async () => {
    const bundle = await collectDiagnosticsBundle({
      context: diagnosticsContext(),
      backendService: diagnosticsBackendService(vi.fn().mockResolvedValue(fakeConnection())),
      operationJournal: operationJournal([
        {
          kind: "update",
          repositoryHash: "0123456789abcdef",
          startedAt: "2026-06-25T00:00:00.000Z",
          endedAt: "2026-06-25T00:00:02.500Z",
          durationMs: 2500,
          resultCategory: "succeeded",
          scanPlan: "full",
          touchedCount: 3,
          retryCount: 0,
          cancelled: false,
        },
      ]),
      watcherOverflowDiagnostics: watcherOverflowDiagnostics(),
    });

    expect(bundle.operationJournal).toEqual({
      entries: [
        {
          kind: "update",
          repositoryHash: "0123456789abcdef",
          startedAt: "2026-06-25T00:00:00.000Z",
          endedAt: "2026-06-25T00:00:02.500Z",
          durationMs: 2500,
          resultCategory: "succeeded",
          scanPlan: "full",
          touchedCount: 3,
          retryCount: 0,
          cancelled: false,
        },
      ],
      recordingFailures: {
        count: 0,
        lastCode: null,
      },
      omittedFields: ["paths", "urls", "repositoryLogMessages", "sourceContent", "credentials"],
    });
    const json = JSON.stringify(bundle);
    expect(json).not.toContain("C:\\Users");
    expect(json).not.toContain("file://");
    expect(json).not.toContain("hunter2");
  });
});

function diagnosticsContext(overrides: Partial<Parameters<typeof collectVersionReport>[0]["context"]> = {}) {
  return {
    generatedAt: "2026-06-24T00:00:00.000Z",
    extension: {
      name: "SubversionR",
      version: "0.1.0",
    },
    vscode: {
      version: "1.101.0",
      appName: "Visual Studio Code",
      uiKind: "desktop",
      remoteName: undefined,
    },
    process: {
      platform: "win32",
      arch: "x64",
      nodeVersion: "24.16.0",
    },
    workspace: {
      trusted: true,
      workspaceFolders: [],
    },
    ...overrides,
  };
}

function diagnosticsBackendService(
  initialize: ReturnType<typeof vi.fn<() => Promise<BackendConnection>>>,
  lifecycleState: BackendLifecycleState = { status: "idle" },
) {
  return {
    initialize,
    getLifecycleState: vi.fn(() => lifecycleState),
  };
}

function operationJournal(entries: OperationJournalEntry[] = []) {
  return {
    diagnosticsSnapshot: () => ({
      entries,
      recordingFailures: {
        count: 0,
        lastCode: null,
      },
    }),
  };
}

function watcherOverflowDiagnostics(
  snapshot: WatcherOverflowDiagnosticsSnapshot = {
    overflowCount: 0,
    lastOverflow: null,
  },
) {
  return {
    diagnosticsSnapshot: () => snapshot,
  };
}

function fakeConnection(
  diagnostics: Record<string, unknown> = {
    repositorySummary: {
      openRepositories: 0,
      cachedLocalEntries: 0,
    },
    backendStderr: {
      truncated: false,
      text: null,
    },
  },
): BackendConnection {
  return {
    initializeResult: initializeResult(),
    sendRequest: vi.fn().mockResolvedValue(diagnostics),
    isRemoteSubmissionEnabled: vi.fn(() => true),
    currentRemoteTrustEpoch: vi.fn(() => 1),
    updateWorkspaceTrust: vi.fn(async () => 2),
    onDidTerminate: vi.fn(() => ({ dispose: vi.fn() })),
    shutdown: vi.fn().mockResolvedValue(undefined),
    dispose: vi.fn(),
  };
}

function initializeResult(): InitializeResult {
  return {
    protocol: { major: 1, minor: 35 },
    backendVersion: "0.1.0",
    bridgeVersion: "subversionr-svn-bridge/0.1.0",
    libsvnVersion: "1.14.5",
    platform: { os: "windows", arch: "x86_64" },
    cacheSchema: {
      schemaId: "subversionr.cache.v1",
      version: 1,
      rollback: "delete-and-reconcile",
    },
    capabilities: {
      contentLengthFraming: true,
      realLibsvnBridge: true,
      repositoryDiscover: true,
      repositoryOpen: true,
      repositoryClose: true,
      repositoryCheckout: true,
      statusSnapshot: true,
      statusRefresh: true,
      statusRemoteCheck: true,
      statusStaleNotification: true,
      contentGet: true,
      contentGetRevision: true,
      historyLog: true,
      historyBlame: true,
      operationRun: true,
      operationRunAdd: true,
      operationRunRemove: true,
      operationRunMove: true,
      operationRunCleanup: true,
      operationRunResolve: true,
      operationRunUpdate: true,
      operationRunUpdateSelectedPath: true,
      operationRunUpdateToRevision: true,
      operationRunUpdateDepth: true,
      operationRunUpdateExternalsPolicy: true,
      propertiesList: true,
      operationRunPropertySet: true,
      operationRunPropertyDelete: true,
      ignore: true,
      operationRunChangelistSet: true,
      operationRunChangelistClear: true,
      operationRunLock: true,
      operationRunUnlock: true,
      operationRunBranchCreate: true,
      operationRunSwitch: true,
      operationRunCommit: true,
      operationRunCommitMultiPath: true,
      diagnosticsGet: true,
      credentialRequest: true,
      certificateRequest: true,
      remoteOperationEnvelope: true,
      trustedConfigSnapshot: true,
      remoteWorkerIsolation: true,
      credentialLeaseSettlement: true,
      remoteConnectionState: true,
      remoteSvnAnonymous: true,
    },
    acknowledgedTrustEpoch: 1,
  };
}

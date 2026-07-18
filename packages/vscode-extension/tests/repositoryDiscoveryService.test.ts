import { describe, expect, it, vi } from "vitest";
import { JsonRpcStreamError } from "../src/transport/jsonRpcStreamClient";
import {
  RepositoryDiscoveryError,
  RepositoryDiscoveryService,
  type RepositoryDiscoveryResponse,
} from "../src/repository/repositoryDiscoveryService";
import type { BackendConnection, InitializeResult } from "../src/backend/backendProcess";
import type { BackendService } from "../src/backend/backendService";
import type { RepositorySession, RepositorySessionService } from "../src/repository/repositorySessionService";

describe("RepositoryDiscoveryService", () => {
  it("sends the complete repository/discover contract and validates discovered candidates", async () => {
    const response = discoverResponse();
    response.fileExternalBoundaries = ["C:\\workspace\\externals\\pinned.txt"];
    const connection = fakeConnection(response);
    const sessionService = fakeSessionService();
    const service = new RepositoryDiscoveryService({
      backendService: fakeBackendService(connection),
      sessionService,
    });

    const result = await service.discoverRepositories({
      workspaceRoots: ["C:\\workspace"],
      discoverNested: false,
      discoveryDepth: 4,
      discoveryIgnore: ["**/node_modules"],
      ignoredRoots: ["C:\\workspace\\ignored"],
      externalsMode: "lazy",
    });

    expect(connection.sendRequest).toHaveBeenCalledWith("repository/discover", {
      workspaceRoots: ["C:\\workspace"],
      discoverNested: false,
      discoveryDepth: 4,
      discoveryIgnore: ["**/node_modules"],
      ignoredRoots: ["C:\\workspace\\ignored"],
      externalsMode: "lazy",
    });
    expect(result).toEqual(response);
    expect(result.fileExternalBoundaries).toEqual(["C:\\workspace\\externals\\pinned.txt"]);
  });

  it("rejects repository/discover responses without explicit file external boundaries", async () => {
    const response = discoverResponse();
    delete (response as Partial<RepositoryDiscoveryResponse>).fileExternalBoundaries;
    const service = new RepositoryDiscoveryService({
      backendService: fakeBackendService(fakeConnection(response)),
      sessionService: fakeSessionService(),
    });

    await expect(service.discoverRepositories(validDiscoveryRequest())).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_DISCOVERY_RESPONSE_INVALID",
      category: "protocol",
      safeArgs: { field: "fileExternalBoundaries" },
    });
  });

  it("accepts null parentWorkingCopyRoot as an absent parent boundary", async () => {
    const response = discoverResponse();
    response.candidates[0].parentWorkingCopyRoot = null as never;
    const service = new RepositoryDiscoveryService({
      backendService: fakeBackendService(fakeConnection(response)),
      sessionService: fakeSessionService(),
    });

    const result = await service.discoverRepositories(validDiscoveryRequest());

    expect(result.candidates[0]).not.toHaveProperty("parentWorkingCopyRoot");
  });

  it("rejects nested or external candidates without a parent working copy root", async () => {
    const response = discoverResponse();
    response.candidates[0].isNested = true;
    response.candidates[0].parentWorkingCopyRoot = undefined;
    const service = new RepositoryDiscoveryService({
      backendService: fakeBackendService(fakeConnection(response)),
      sessionService: fakeSessionService(),
    });

    await expect(service.discoverRepositories(validDiscoveryRequest())).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_DISCOVERY_RESPONSE_INVALID",
      category: "protocol",
      safeArgs: { field: "candidates.0.parentWorkingCopyRoot" },
    });
  });

  it("rejects parent working copy roots on top-level discovery candidates", async () => {
    const response = discoverResponse();
    response.candidates[0].parentWorkingCopyRoot = "C:\\workspace-parent";
    const service = new RepositoryDiscoveryService({
      backendService: fakeBackendService(fakeConnection(response)),
      sessionService: fakeSessionService(),
    });

    await expect(service.discoverRepositories(validDiscoveryRequest())).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_DISCOVERY_RESPONSE_INVALID",
      category: "protocol",
      safeArgs: { field: "candidates.0.parentWorkingCopyRoot" },
    });
  });

  it("passes discoverNested through without coercing unsupported backend modes", async () => {
    const backendError = new JsonRpcStreamError({
      code: "REPOSITORY_DISCOVERY_MODE_UNSUPPORTED",
      category: "unsupported",
      messageKey: "error.repository.discoveryModeUnsupported",
      args: { field: "discoverNested" },
      retryable: false,
      diagnostics: null,
    });
    const connection = fakeConnection(backendError);
    const service = new RepositoryDiscoveryService({
      backendService: fakeBackendService(connection),
      sessionService: fakeSessionService(),
    });

    await expect(
      service.discoverRepositories({
        ...validDiscoveryRequest(),
        discoverNested: true,
      }),
    ).rejects.toBe(backendError);
    expect(connection.sendRequest).toHaveBeenCalledWith("repository/discover", {
      ...validDiscoveryRequest(),
      discoverNested: true,
    });
  });

  it.each([
    ["workspaceRoots", { workspaceRoots: [], discoverNested: false, discoveryDepth: 4, discoveryIgnore: [], ignoredRoots: [], externalsMode: "lazy" }],
    ["discoverNested", { workspaceRoots: ["C:/workspace"], discoverNested: undefined, discoveryDepth: 4, discoveryIgnore: [], ignoredRoots: [], externalsMode: "lazy" }],
    ["discoveryDepth", { workspaceRoots: ["C:/workspace"], discoverNested: false, discoveryDepth: -1, discoveryIgnore: [], ignoredRoots: [], externalsMode: "lazy" }],
    ["discoveryIgnore.0", { workspaceRoots: ["C:/workspace"], discoverNested: false, discoveryDepth: 4, discoveryIgnore: [""], ignoredRoots: [], externalsMode: "lazy" }],
    ["externalsMode", { workspaceRoots: ["C:/workspace"], discoverNested: false, discoveryDepth: 4, discoveryIgnore: [], ignoredRoots: [], externalsMode: "eager" }],
  ])("fails fast when discovery input is invalid: %s", async (field, request) => {
    const connection = fakeConnection(discoverResponse());
    const service = new RepositoryDiscoveryService({
      backendService: fakeBackendService(connection),
      sessionService: fakeSessionService(),
    });

    await expect(service.discoverRepositories(request as never)).rejects.toMatchObject({
      code: field === "externalsMode" ? "SUBVERSIONR_REPOSITORY_DISCOVERY_MODE_UNSUPPORTED" : "SUBVERSIONR_REPOSITORY_DISCOVERY_INPUT_INVALID",
      category: field === "externalsMode" ? "unsupported" : "input",
      safeArgs: { field },
    });
    expect(connection.sendRequest).not.toHaveBeenCalled();
  });

  it("rejects invalid repository/discover responses without opening a session", async () => {
    const response = discoverResponse();
    const identity = response.candidates[0].identity as Partial<RepositoryDiscoveryResponse["candidates"][number]["identity"]>;
    delete identity.workingCopyRoot;
    const connection = fakeConnection(response);
    const sessionService = fakeSessionService();
    const service = new RepositoryDiscoveryService({
      backendService: fakeBackendService(connection),
      sessionService,
    });

    await expect(
      service.discoverRepositories({
        workspaceRoots: ["C:/workspace"],
        discoverNested: false,
        discoveryDepth: 4,
        discoveryIgnore: [],
        ignoredRoots: [],
        externalsMode: "lazy",
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_DISCOVERY_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.repository.discoveryResponseInvalid",
      safeArgs: { field: "candidates.0.identity.workingCopyRoot" },
    });
    expect(sessionService.openWorkingCopy).not.toHaveBeenCalled();
  });

  it("opens an explicit discovered candidate through the session service using backend workingCopyRoot", async () => {
    const session = fakeSession();
    const sessionService = fakeSessionService(session);
    const service = new RepositoryDiscoveryService({
      backendService: fakeBackendService(fakeConnection(discoverResponse())),
      sessionService,
    });

    const result = await service.openDiscoveredRepository({
      candidate: discoverResponse().candidates[0],
      pathCase: "case-insensitive",
      boundaryRoots: ["C:\\workspace\\external"],
    });

    expect(sessionService.openWorkingCopy).toHaveBeenCalledWith({
      path: "C:\\workspace",
      pathCase: "case-insensitive",
      boundaryRoots: ["C:\\workspace\\external"],
    });
    expect(result).toBe(session);
  });

  it("fails fast when opening a discovered candidate without explicit path case", async () => {
    const sessionService = fakeSessionService();
    const service = new RepositoryDiscoveryService({
      backendService: fakeBackendService(fakeConnection(discoverResponse())),
      sessionService,
    });

    await expect(
      service.openDiscoveredRepository({
        candidate: discoverResponse().candidates[0],
        pathCase: undefined,
      } as never),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_DISCOVERY_INPUT_INVALID",
      category: "input",
      safeArgs: { field: "pathCase" },
    });
    expect(sessionService.openWorkingCopy).not.toHaveBeenCalled();
  });
});

function discoverResponse(): RepositoryDiscoveryResponse {
  return {
    candidates: [
      {
        identity: {
          repositoryUuid: "8fb8e1d2-013a-4d91-8a7b-94f39937b46d",
          repositoryRootUrl: "file:///C:/repo",
          workingCopyRoot: "C:\\workspace",
          workspaceScopeRoot: "C:\\workspace",
          format: 31,
        },
        isNested: false,
        isExternal: false,
      },
    ],
    fileExternalBoundaries: [],
  };
}

function validDiscoveryRequest() {
  return {
    workspaceRoots: ["C:\\workspace"],
    discoverNested: false,
    discoveryDepth: 4,
    discoveryIgnore: [],
    ignoredRoots: [],
    externalsMode: "lazy" as const,
  };
}

function fakeConnection(response: unknown): BackendConnection {
  return {
    initializeResult: initializeResult(),
    sendRequest: vi.fn(() => {
      if (response instanceof Error) {
        return Promise.reject(response);
      }
      return Promise.resolve(response);
    }) as unknown as BackendConnection["sendRequest"],
    isRemoteSubmissionEnabled: vi.fn(() => true),
    currentRemoteTrustEpoch: vi.fn(() => 1),
    updateWorkspaceTrust: vi.fn(async () => 2),
    onDidTerminate: vi.fn(() => ({ dispose: vi.fn() })),
    shutdown: vi.fn().mockResolvedValue(undefined),
    dispose: vi.fn(),
  };
}

function fakeBackendService(connection: BackendConnection): Pick<BackendService, "initialize"> {
  return {
    initialize: vi.fn().mockResolvedValue(connection),
  };
}

function fakeSessionService(session: RepositorySession = fakeSession()): Pick<RepositorySessionService, "openWorkingCopy"> & {
  openWorkingCopy: ReturnType<typeof vi.fn<RepositorySessionService["openWorkingCopy"]>>;
} {
  return {
    openWorkingCopy: vi.fn<RepositorySessionService["openWorkingCopy"]>().mockResolvedValue(session),
  };
}

function fakeSession(): RepositorySession {
  return {
    repositoryId: "repo-uuid:C:/workspace",
    epoch: 7,
    identity: discoverResponse().candidates[0].identity,
    watchScope: {
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      workingCopyRoot: "C:\\workspace",
      pathCase: "case-insensitive",
    },
  };
}

function initializeResult(): InitializeResult {
  return {
    protocol: { major: 1, minor: 34 },
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
    },
    acknowledgedTrustEpoch: 1,
  };
}

expect(RepositoryDiscoveryError).toBeDefined();

import { describe, expect, it, vi } from "vitest";
import { JsonRpcStreamError } from "../src/transport/jsonRpcStreamClient";
import {
  RepositorySessionError,
  RepositorySessionService,
  type RepositoryCloseResponse,
  type RepositoryOpenResponse,
} from "../src/repository/repositorySessionService";
import type { SourceControlProjectionService } from "../src/scm/sourceControlProjectionService";
import type {
  ScmRepositoryProjection,
  SourceControlProjectionRepository,
} from "../src/scm/sourceControlResourceStore";
import type { BackendConnection, InitializeResult } from "../src/backend/backendProcess";
import type { BackendService } from "../src/backend/backendService";
import type { BackendStatusSnapshotClient } from "../src/status/backendStatusSnapshotClient";
import type { RepositoryWatcherService } from "../src/status/repositoryWatcherService";
import type {
  StatusSnapshot,
  StatusSnapshotRequest,
} from "../src/status/statusSnapshotRpcClient";
import type {
  StatusStaleMark,
  StoredStatusSnapshot,
  StatusSnapshotRepository,
  StatusSnapshotStore,
} from "../src/status/statusSnapshotStore";
import type { RepositoryWatchScope } from "../src/status/types";

describe("RepositorySessionService", () => {
  it("opens a working copy through the backend and registers a watcher scope from the backend identity", async () => {
    const connection = fakeConnection(openResponse());
    const backendService = fakeBackendService(connection);
    const watcherService = fakeWatcherService();
    const initialSnapshot = snapshotResponse();
    const statusSnapshotClient = fakeSnapshotClient(initialSnapshot);
    const statusSnapshotStore = fakeSnapshotStore();
    const sourceControlProjection = fakeSourceControlProjection();
    const service = repositorySessionService(backendService, watcherService, {
      statusSnapshotClient,
      statusSnapshotStore,
      sourceControlProjection,
    });

    const session = await service.openWorkingCopy({
      path: "C:\\wc\\src",
      pathCase: "case-insensitive",
      boundaryRoots: ["C:\\wc\\vendor\\external"],
    });

    expect(backendService.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("repository/open", {
      path: "C:\\wc\\src",
      boundaryRoots: ["C:\\wc\\vendor\\external"],
    });
    expect(watcherService.registerRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:\\wc",
      pathCase: "case-insensitive",
      boundaryRoots: ["C:\\wc\\vendor\\external"],
    });
    expect(statusSnapshotStore.registerRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
    });
    expect(sourceControlProjection.registerRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:\\wc",
    });
    expect(statusSnapshotClient.getSnapshot).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
    });
    expect(statusSnapshotStore.applySnapshot).toHaveBeenCalledWith(initialSnapshot);
    expect(sourceControlProjection.applySnapshot).toHaveBeenCalledWith(initialSnapshot);
    expect(statusSnapshotStore.applySnapshot.mock.invocationCallOrder[0]).toBeLessThan(
      sourceControlProjection.applySnapshot.mock.invocationCallOrder[0],
    );
    expect(session).toEqual({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      identity: openResponse().identity,
      watchScope: {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        workingCopyRoot: "C:\\wc",
        pathCase: "case-insensitive",
        boundaryRoots: ["C:\\wc\\vendor\\external"],
      },
    });
  });

  it("refreshes an open session identity from the latest status snapshot", async () => {
    const connection = fakeConnection(openResponse());
    const statusSnapshotStore = fakeSnapshotStore();
    const service = repositorySessionService(fakeBackendService(connection), fakeWatcherService(), {
      statusSnapshotStore,
    });
    await service.openWorkingCopy({ path: "C:/wc", pathCase: "case-insensitive" });
    statusSnapshotStore.replaceSnapshot(snapshotResponse({
      identity: {
        ...openResponse().identity,
        repositoryRootUrl: "https://svn.example.invalid/repo",
      },
    }));

    const refreshed = service.refreshSessionIdentityFromSnapshot({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
    });

    expect(refreshed.identity.repositoryRootUrl).toBe("https://svn.example.invalid/repo");
    expect(service.listOpenSessions()[0]?.identity.repositoryRootUrl).toBe("https://svn.example.invalid/repo");
  });

  it("marks open repository state stale when the backend connection is lost", async () => {
    const connection = fakeConnection(openResponse());
    const statusSnapshotStore = fakeSnapshotStore();
    const sourceControlProjection = fakeSourceControlProjection();
    const service = repositorySessionService(fakeBackendService(connection), fakeWatcherService(), {
      statusSnapshotStore,
      sourceControlProjection,
    });

    await service.openWorkingCopy({ path: "C:/wc", pathCase: "case-insensitive" });
    service.markOpenSessionsStale({
      reason: "backendConnectionLost",
      timestamp: "2026-06-25T00:00:00.000Z",
      source: "backend-lifecycle",
    });

    const staleMark = {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      reason: "backendConnectionLost",
      timestamp: "2026-06-25T00:00:00.000Z",
      source: "backend-lifecycle",
    };
    expect(statusSnapshotStore.markStale).toHaveBeenCalledWith(staleMark);
    expect(sourceControlProjection.markStale).toHaveBeenCalledWith(staleMark);
    expect(statusSnapshotStore.markStale.mock.invocationCallOrder[0]).toBeLessThan(
      sourceControlProjection.markStale.mock.invocationCallOrder[0],
    );
  });

  it("recovers projection from the stale canonical snapshot when backend stale publishing fails", async () => {
    const connection = fakeConnection(openResponse());
    const statusSnapshotStore = fakeSnapshotStore();
    const sourceControlProjection = fakeSourceControlProjection();
    sourceControlProjection.markStale.mockImplementationOnce(() => {
      throw new Error("projection failed");
    });
    const service = repositorySessionService(fakeBackendService(connection), fakeWatcherService(), {
      statusSnapshotStore,
      sourceControlProjection,
    });

    await service.openWorkingCopy({ path: "C:/wc", pathCase: "case-insensitive" });

    expect(() =>
      service.markOpenSessionsStale({
        reason: "backendConnectionLost",
        timestamp: "2026-06-25T00:00:00.000Z",
        source: "backend-lifecycle",
      }),
    ).toThrow("projection failed");

    expect(sourceControlProjection.replaceSnapshot).toHaveBeenCalledTimes(1);
    expect(sourceControlProjection.replaceSnapshot).toHaveBeenCalledWith(
      statusSnapshotStore.getSnapshot("repo-uuid:C:/wc"),
    );
  });

  it("rejects backend stale marking before mutating when projection state is unavailable", async () => {
    const connection = fakeConnection(openResponse());
    const statusSnapshotStore = fakeSnapshotStore();
    const sourceControlProjection = fakeSourceControlProjection();
    const service = repositorySessionService(fakeBackendService(connection), fakeWatcherService(), {
      statusSnapshotStore,
      sourceControlProjection,
    });

    await service.openWorkingCopy({ path: "C:/wc", pathCase: "case-insensitive" });
    sourceControlProjection.getProjection.mockReturnValueOnce(undefined);

    expect(() =>
      service.markOpenSessionsStale({
        reason: "backendConnectionLost",
        timestamp: "2026-06-25T00:00:00.000Z",
        source: "backend-lifecycle",
      }),
    ).toThrowError(
      expect.objectContaining({
        code: "SUBVERSIONR_REPOSITORY_STALE_STATE_UNAVAILABLE",
        category: "lifecycle",
        messageKey: "error.status.notificationStateUnavailable",
        safeArgs: {
          repositoryId: "repo-uuid:C:/wc",
          state: "projection",
        },
      }),
    );
    expect(statusSnapshotStore.markStale).not.toHaveBeenCalled();
    expect(sourceControlProjection.markStale).not.toHaveBeenCalled();
  });

  it("reopens stale sessions on a replacement backend connection with a new epoch", async () => {
    const reopened = openResponse({ epoch: 1 });
    const reopenedSnapshot = snapshotResponse({ epoch: 1, generation: 1, source: "libsvn-restarted" });
    const connection = fakeConnection([openResponse(), reopened]);
    const backendService = fakeBackendService(connection);
    const watcherService = fakeWatcherService();
    const statusSnapshotStore = fakeSnapshotStore();
    const sourceControlProjection = fakeSourceControlProjection();
    const service = repositorySessionService(backendService, watcherService, {
      statusSnapshotClient: fakeSnapshotClient([snapshotResponse(), reopenedSnapshot]),
      statusSnapshotStore,
      sourceControlProjection,
    });
    const events: unknown[] = [];

    await service.openWorkingCopy({
      path: "C:/wc",
      pathCase: "case-insensitive",
      boundaryRoots: ["C:/wc/vendor/external"],
    });
    service.markOpenSessionsStale({
      reason: "backendConnectionLost",
      timestamp: "2026-06-25T00:00:00.000Z",
      source: "backend-lifecycle",
    });
    service.onDidChangeSessions((event) => {
      events.push({
        ...event,
        openSessions: service.listOpenSessions().map((session) => ({
          repositoryId: session.repositoryId,
          epoch: session.epoch,
        })),
      });
    });

    const result = await service.reopenOpenSessions();

    expect(connection.sendRequest).toHaveBeenLastCalledWith("repository/open", {
      path: "C:\\wc",
      boundaryRoots: ["C:/wc/vendor/external"],
    });
    expect(watcherService.replaceRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 1,
      workingCopyRoot: "C:\\wc",
      pathCase: "case-insensitive",
      boundaryRoots: ["C:/wc/vendor/external"],
    });
    expect(statusSnapshotStore.replaceSnapshot).toHaveBeenCalledWith(reopenedSnapshot);
    expect(sourceControlProjection.replaceSnapshot).toHaveBeenCalledWith(reopenedSnapshot);
    expect(statusSnapshotStore.replaceSnapshot.mock.invocationCallOrder[0]).toBeLessThan(
      sourceControlProjection.replaceSnapshot.mock.invocationCallOrder[0],
    );
    expect(result).toEqual([
      {
        kind: "reopened",
        repositoryId: "repo-uuid:C:/wc",
        previousEpoch: 7,
        epoch: 1,
        workingCopyRoot: "C:\\wc",
      },
    ]);
    expect(service.listOpenSessions()).toEqual([
      expect.objectContaining({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 1,
        watchScope: expect.objectContaining({
          epoch: 1,
        }),
      }),
    ]);
    expect(events).toEqual([
      {
        kind: "reopened",
        repositoryId: "repo-uuid:C:/wc",
        previousEpoch: 7,
        epoch: 1,
        openSessions: [{ repositoryId: "repo-uuid:C:/wc", epoch: 1 }],
      },
    ]);
  });

  it("keeps stale session state when backend reopen fails", async () => {
    const connection = fakeConnection([openResponse(), new CodedError("SUBVERSIONR_REPOSITORY_REOPEN_BACKEND_FAILED")]);
    const watcherService = fakeWatcherService();
    const statusSnapshotStore = fakeSnapshotStore();
    const sourceControlProjection = fakeSourceControlProjection();
    const service = repositorySessionService(fakeBackendService(connection), watcherService, {
      statusSnapshotStore,
      sourceControlProjection,
    });

    await service.openWorkingCopy({ path: "C:/wc", pathCase: "case-insensitive" });
    service.markOpenSessionsStale({
      reason: "backendConnectionLost",
      timestamp: "2026-06-25T00:00:00.000Z",
      source: "backend-lifecycle",
    });

    const result = await service.reopenOpenSessions();

    expect(result).toEqual([
      {
        kind: "reopenFailed",
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        workingCopyRoot: "C:\\wc",
        code: "SUBVERSIONR_REPOSITORY_REOPEN_BACKEND_FAILED",
      },
    ]);
    expect(watcherService.replaceRepository).not.toHaveBeenCalled();
    expect(statusSnapshotStore.replaceSnapshot).not.toHaveBeenCalled();
    expect(sourceControlProjection.replaceSnapshot).not.toHaveBeenCalled();
    expect(statusSnapshotStore.getSnapshot("repo-uuid:C:/wc")).toMatchObject({
      epoch: 7,
      completeness: "stale",
      source: "backend-lifecycle",
    });
    expect(service.listOpenSessions()).toEqual([
      expect.objectContaining({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
      }),
    ]);
  });

  it("keeps stale session state when backend reopen returns a different repository identity for the same path", async () => {
    const connection = fakeConnection([
      openResponse(),
      openResponse({
        repositoryId: "other-repo:C:/wc",
        identity: {
          repositoryUuid: "other-repo",
          repositoryRootUrl: "file:///C:/repos/other-project",
          workingCopyRoot: "C:\\wc",
          workspaceScopeRoot: "C:\\wc",
          format: 31,
        },
      }),
    ]);
    const watcherService = fakeWatcherService();
    const statusSnapshotStore = fakeSnapshotStore();
    const sourceControlProjection = fakeSourceControlProjection();
    const service = repositorySessionService(fakeBackendService(connection), watcherService, {
      statusSnapshotStore,
      sourceControlProjection,
    });

    await service.openWorkingCopy({ path: "C:/wc", pathCase: "case-insensitive" });
    service.markOpenSessionsStale({
      reason: "backendConnectionLost",
      timestamp: "2026-06-25T00:00:00.000Z",
      source: "backend-lifecycle",
    });

    const result = await service.reopenOpenSessions();

    expect(result).toEqual([
      {
        kind: "reopenFailed",
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        workingCopyRoot: "C:\\wc",
        code: "SUBVERSIONR_REPOSITORY_REOPEN_IDENTITY_MISMATCH",
      },
    ]);
    expect(watcherService.replaceRepository).not.toHaveBeenCalled();
    expect(statusSnapshotStore.replaceSnapshot).not.toHaveBeenCalled();
    expect(sourceControlProjection.replaceSnapshot).not.toHaveBeenCalled();
    expect(statusSnapshotStore.getSnapshot("repo-uuid:C:/wc")).toMatchObject({
      epoch: 7,
      completeness: "stale",
      source: "backend-lifecycle",
    });
    expect(service.listOpenSessions()).toEqual([
      expect.objectContaining({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
      }),
    ]);
  });

  it("emits a session change event only after an opened session is visible", async () => {
    const connection = fakeConnection(openResponse());
    const service = repositorySessionService(fakeBackendService(connection), fakeWatcherService());
    const events: unknown[] = [];

    service.onDidChangeSessions((event) => {
      events.push({
        ...event,
        openSessions: service.listOpenSessions().map((session) => session.repositoryId),
      });
    });

    await service.openWorkingCopy({ path: "C:/wc", pathCase: "case-insensitive" });

    expect(events).toEqual([
      {
        kind: "opened",
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        openSessions: ["repo-uuid:C:/wc"],
      },
    ]);
  });

  it.each([
    ["path", { path: "", pathCase: "case-insensitive" }],
    ["pathCase", { path: "C:/wc", pathCase: undefined }],
  ])("fails fast when required open input is missing: %s", async (_field, request) => {
    const connection = fakeConnection(openResponse());
    const backendService = fakeBackendService(connection);
    const watcherService = fakeWatcherService();
    const service = repositorySessionService(backendService, watcherService);

    await expect(service.openWorkingCopy(request as never)).rejects.toBeInstanceOf(RepositorySessionError);

    expect(backendService.initialize).not.toHaveBeenCalled();
    expect(connection.sendRequest).not.toHaveBeenCalled();
    expect(watcherService.registerRepository).not.toHaveBeenCalled();
  });

  it("rejects invalid repository/open responses without registering a watcher", async () => {
    const response = openResponse();
    delete (response.identity as Partial<typeof response.identity>).workingCopyRoot;
    const connection = fakeConnection(response);
    const backendService = fakeBackendService(connection);
    const watcherService = fakeWatcherService();
    const service = repositorySessionService(backendService, watcherService);

    await expect(
      service.openWorkingCopy({ path: "C:/wc", pathCase: "case-insensitive" }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_OPEN_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.repository.openResponseInvalid",
      safeArgs: { field: "identity.workingCopyRoot" },
    });

    expect(watcherService.registerRepository).not.toHaveBeenCalled();
  });

  it("closes the backend session when watcher registration fails after repository/open succeeds", async () => {
    const watcherFailure = new Error("watcher unavailable");
    const connection = fakeConnection(openResponse());
    const backendService = fakeBackendService(connection);
    const watcherService = fakeWatcherService();
    watcherService.registerRepository.mockImplementation(() => {
      throw watcherFailure;
    });
    const service = repositorySessionService(backendService, watcherService);

    await expect(
      service.openWorkingCopy({ path: "C:/wc", pathCase: "case-insensitive" }),
    ).rejects.toBe(watcherFailure);

    expect(connection.sendRequest).toHaveBeenNthCalledWith(1, "repository/open", {
      path: "C:/wc",
    });
    expect(connection.sendRequest).toHaveBeenNthCalledWith(2, "repository/close", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
    });
  });

  it("reports rollback failure when the backend cannot close a session after watcher registration fails", async () => {
    const watcherFailure = new Error("watcher unavailable");
    const closeFailure = new Error("close failed");
    const connection = fakeConnection(openResponse(), closeFailure);
    const backendService = fakeBackendService(connection);
    const watcherService = fakeWatcherService();
    watcherService.registerRepository.mockImplementation(() => {
      throw watcherFailure;
    });
    const service = repositorySessionService(backendService, watcherService);

    await expect(
      service.openWorkingCopy({ path: "C:/wc", pathCase: "case-insensitive" }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_OPEN_ROLLBACK_FAILED",
      category: "lifecycle",
      messageKey: "error.repository.openRollbackFailed",
      safeArgs: {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
      },
    });
  });

  it("rolls back backend, watcher, and status store state when initial snapshot loading fails", async () => {
    const snapshotFailure = new Error("snapshot failed");
    const connection = fakeConnection(openResponse());
    const backendService = fakeBackendService(connection);
    const watcherService = fakeWatcherService();
    const statusSnapshotClient = fakeSnapshotClient(snapshotFailure);
    const statusSnapshotStore = fakeSnapshotStore();
    const sourceControlProjection = fakeSourceControlProjection();
    const service = repositorySessionService(backendService, watcherService, {
      statusSnapshotClient,
      statusSnapshotStore,
      sourceControlProjection,
    });

    await expect(
      service.openWorkingCopy({ path: "C:/wc", pathCase: "case-insensitive" }),
    ).rejects.toBe(snapshotFailure);

    expect(statusSnapshotStore.registerRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
    });
    expect(statusSnapshotClient.getSnapshot).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
    });
    expect(statusSnapshotStore.applySnapshot).not.toHaveBeenCalled();
    expect(sourceControlProjection.applySnapshot).not.toHaveBeenCalled();
    expect(watcherService.unregisterRepository).toHaveBeenCalledWith("repo-uuid:C:/wc");
    expect(sourceControlProjection.unregisterRepository).toHaveBeenCalledWith("repo-uuid:C:/wc");
    expect(statusSnapshotStore.unregisterRepository).toHaveBeenCalledWith("repo-uuid:C:/wc");
    expect(connection.sendRequest).toHaveBeenNthCalledWith(2, "repository/close", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
    });
    await expect(service.closeRepository("repo-uuid:C:/wc")).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_SESSION_NOT_OPEN",
    });
  });

  it("does not publish the initial SCM projection when status store snapshot application fails", async () => {
    const applyFailure = new Error("status store rejected snapshot");
    const connection = fakeConnection(openResponse());
    const backendService = fakeBackendService(connection);
    const watcherService = fakeWatcherService();
    const statusSnapshotClient = fakeSnapshotClient(snapshotResponse());
    const statusSnapshotStore = fakeSnapshotStore();
    const sourceControlProjection = fakeSourceControlProjection();
    statusSnapshotStore.applySnapshot.mockImplementation(() => {
      throw applyFailure;
    });
    const service = repositorySessionService(backendService, watcherService, {
      statusSnapshotClient,
      statusSnapshotStore,
      sourceControlProjection,
    });

    await expect(
      service.openWorkingCopy({ path: "C:/wc", pathCase: "case-insensitive" }),
    ).rejects.toBe(applyFailure);

    expect(sourceControlProjection.applySnapshot).not.toHaveBeenCalled();
    expect(sourceControlProjection.unregisterRepository).toHaveBeenCalledWith("repo-uuid:C:/wc");
  });

  it("reports rollback failure when the backend cannot close a session after initial snapshot loading fails", async () => {
    const snapshotFailure = new Error("snapshot failed");
    const closeFailure = new Error("close failed");
    const connection = fakeConnection(openResponse(), closeFailure);
    const backendService = fakeBackendService(connection);
    const watcherService = fakeWatcherService();
    const statusSnapshotClient = fakeSnapshotClient(snapshotFailure);
    const statusSnapshotStore = fakeSnapshotStore();
    const service = repositorySessionService(backendService, watcherService, {
      statusSnapshotClient,
      statusSnapshotStore,
    });

    await expect(
      service.openWorkingCopy({ path: "C:/wc", pathCase: "case-insensitive" }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_OPEN_ROLLBACK_FAILED",
      category: "lifecycle",
      messageKey: "error.repository.openRollbackFailed",
      safeArgs: {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
      },
    });
  });

  it("attempts all local cleanup and reports cleanup failure when initial snapshot rollback cleanup fails", async () => {
    const snapshotFailure = new Error("snapshot failed");
    const cleanupFailure = new Error("status store cleanup failed");
    const connection = fakeConnection(openResponse());
    const backendService = fakeBackendService(connection);
    const watcherService = fakeWatcherService();
    const statusSnapshotClient = fakeSnapshotClient(snapshotFailure);
    const statusSnapshotStore = fakeSnapshotStore();
    statusSnapshotStore.unregisterRepository.mockImplementation(() => {
      throw cleanupFailure;
    });
    const service = repositorySessionService(backendService, watcherService, {
      statusSnapshotClient,
      statusSnapshotStore,
    });

    await expect(
      service.openWorkingCopy({ path: "C:/wc", pathCase: "case-insensitive" }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_OPEN_CLEANUP_FAILED",
      category: "lifecycle",
      messageKey: "error.repository.openCleanupFailed",
      safeArgs: {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
      },
    });
    expect(statusSnapshotStore.unregisterRepository).toHaveBeenCalledWith("repo-uuid:C:/wc");
    expect(watcherService.unregisterRepository).toHaveBeenCalledWith("repo-uuid:C:/wc");
    expect(connection.sendRequest).toHaveBeenNthCalledWith(2, "repository/close", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
    });
  });

  it("maps backend duplicate-open errors to a repository session lifecycle error", async () => {
    const connection = fakeConnection([
      openResponse(),
      new JsonRpcStreamError({
        code: "REPOSITORY_ALREADY_OPEN",
        category: "repository",
        messageKey: "error.repository.alreadyOpen",
        args: { repositoryId: "repo-uuid:C:/wc" },
        retryable: false,
        diagnostics: null,
      }),
    ]);
    const backendService = fakeBackendService(connection);
    const watcherService = fakeWatcherService();
    const service = repositorySessionService(backendService, watcherService);

    await service.openWorkingCopy({ path: "C:/wc", pathCase: "case-insensitive" });

    await expect(
      service.openWorkingCopy({ path: "C:/wc-from-symlink", pathCase: "case-insensitive" }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_SESSION_ALREADY_OPEN",
      category: "lifecycle",
      messageKey: "error.repository.sessionAlreadyOpen",
      safeArgs: { repositoryId: "repo-uuid:C:/wc" },
    });

    expect(watcherService.registerRepository).toHaveBeenCalledTimes(1);
  });

  it("closes an open repository session and unregisters its watcher", async () => {
    const connection = fakeConnection(openResponse());
    const backendService = fakeBackendService(connection);
    const watcherService = fakeWatcherService();
    const statusSnapshotStore = fakeSnapshotStore();
    const sourceControlProjection = fakeSourceControlProjection();
    const service = repositorySessionService(backendService, watcherService, {
      statusSnapshotStore,
      sourceControlProjection,
    });

    await service.openWorkingCopy({ path: "C:/wc", pathCase: "case-insensitive" });
    await service.closeRepository("repo-uuid:C:/wc");

    expect(connection.sendRequest).toHaveBeenNthCalledWith(2, "repository/close", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
    });
    expect(watcherService.unregisterRepository).toHaveBeenCalledWith("repo-uuid:C:/wc");
    expect(statusSnapshotStore.unregisterRepository).toHaveBeenCalledWith("repo-uuid:C:/wc");
    expect(sourceControlProjection.unregisterRepository).toHaveBeenCalledWith("repo-uuid:C:/wc");
  });

  it("lists open sessions as defensive copies", async () => {
    const connection = fakeConnection(openResponse());
    const backendService = fakeBackendService(connection);
    const watcherService = fakeWatcherService();
    const service = repositorySessionService(backendService, watcherService);

    await service.openWorkingCopy({
      path: "C:/wc",
      pathCase: "case-insensitive",
      boundaryRoots: ["C:/wc/vendor"],
    });

    const listed = service.listOpenSessions();
    listed[0].identity.workingCopyRoot = "C:\\mutated";
    listed[0].watchScope.boundaryRoots?.push("C:/wc/mutated");

    expect(service.listOpenSessions()).toEqual([
      {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        identity: openResponse().identity,
        watchScope: {
          repositoryId: "repo-uuid:C:/wc",
          epoch: 7,
          workingCopyRoot: "C:\\wc",
          pathCase: "case-insensitive",
          boundaryRoots: ["C:/wc/vendor"],
        },
      },
    ]);
  });

  it("keeps local session state when backend repository/close fails", async () => {
    const closeFailure = new Error("backend close failed");
    const connection = fakeConnection(openResponse(), closeFailure);
    const backendService = fakeBackendService(connection);
    const watcherService = fakeWatcherService();
    const service = repositorySessionService(backendService, watcherService);

    await service.openWorkingCopy({ path: "C:/wc", pathCase: "case-insensitive" });

    await expect(service.closeRepository("repo-uuid:C:/wc")).rejects.toBe(closeFailure);

    expect(watcherService.unregisterRepository).not.toHaveBeenCalled();
  });

  it("rejects invalid repository/close responses without unregistering the watcher", async () => {
    const connection = fakeConnection(openResponse(), {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      closed: false,
    });
    const backendService = fakeBackendService(connection);
    const watcherService = fakeWatcherService();
    const service = repositorySessionService(backendService, watcherService);

    await service.openWorkingCopy({ path: "C:/wc", pathCase: "case-insensitive" });

    await expect(service.closeRepository("repo-uuid:C:/wc")).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_CLOSE_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.repository.closeResponseInvalid",
      safeArgs: { field: "closed" },
    });

    expect(watcherService.unregisterRepository).not.toHaveBeenCalled();
  });

  it("removes the local session after backend close succeeds even when watcher cleanup fails", async () => {
    const cleanupFailure = new Error("watcher cleanup failed");
    const connection = fakeConnection(openResponse());
    const backendService = fakeBackendService(connection);
    const watcherService = fakeWatcherService();
    watcherService.unregisterRepository.mockImplementation(() => {
      throw cleanupFailure;
    });
    const statusSnapshotStore = fakeSnapshotStore();
    const service = repositorySessionService(backendService, watcherService, { statusSnapshotStore });

    await service.openWorkingCopy({ path: "C:/wc", pathCase: "case-insensitive" });

    await expect(service.closeRepository("repo-uuid:C:/wc")).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_CLOSE_CLEANUP_FAILED",
      category: "lifecycle",
      messageKey: "error.repository.closeCleanupFailed",
      safeArgs: {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
      },
    });
    expect(statusSnapshotStore.unregisterRepository).toHaveBeenCalledWith("repo-uuid:C:/wc");
    await expect(service.closeRepository("repo-uuid:C:/wc")).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_SESSION_NOT_OPEN",
    });
  });

  it("isolates dispose cleanup failures and clears every local session", async () => {
    const connection = fakeConnection([openResponse(), secondOpenResponse()]);
    const backendService = fakeBackendService(connection);
    const watcherService = fakeWatcherService();
    watcherService.unregisterRepository.mockImplementationOnce(() => {
      throw new Error("watcher cleanup failed");
    });
    const statusSnapshotStore = fakeSnapshotStore();
    statusSnapshotStore.unregisterRepository.mockImplementationOnce(() => {
      throw new Error("status store cleanup failed");
    });
    const sourceControlProjection = fakeSourceControlProjection();
    const service = repositorySessionService(backendService, watcherService, {
      statusSnapshotStore,
      sourceControlProjection,
    });

    await service.openWorkingCopy({ path: "C:/wc", pathCase: "case-insensitive" });
    await service.openWorkingCopy({ path: "D:/other-wc", pathCase: "case-insensitive" });

    expect(() => service.dispose()).not.toThrow();

    expect(watcherService.unregisterRepository).toHaveBeenNthCalledWith(1, "repo-uuid:C:/wc");
    expect(watcherService.unregisterRepository).toHaveBeenNthCalledWith(2, "repo-uuid:D:/other-wc");
    expect(statusSnapshotStore.unregisterRepository).toHaveBeenNthCalledWith(1, "repo-uuid:C:/wc");
    expect(statusSnapshotStore.unregisterRepository).toHaveBeenNthCalledWith(2, "repo-uuid:D:/other-wc");
    expect(sourceControlProjection.unregisterRepository).toHaveBeenNthCalledWith(1, "repo-uuid:C:/wc");
    expect(sourceControlProjection.unregisterRepository).toHaveBeenNthCalledWith(2, "repo-uuid:D:/other-wc");
    await expect(service.closeRepository("repo-uuid:C:/wc")).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_SESSION_NOT_OPEN",
    });
    await expect(service.closeRepository("repo-uuid:D:/other-wc")).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_SESSION_NOT_OPEN",
    });
  });

  it("fails fast when closing a repository session that is not open", async () => {
    const connection = fakeConnection(openResponse());
    const backendService = fakeBackendService(connection);
    const watcherService = fakeWatcherService();
    const service = repositorySessionService(backendService, watcherService);

    await expect(service.closeRepository("repo-uuid:C:/wc")).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_SESSION_NOT_OPEN",
      category: "lifecycle",
      messageKey: "error.repository.sessionNotOpen",
      safeArgs: { repositoryId: "repo-uuid:C:/wc" },
    });

    expect(backendService.initialize).not.toHaveBeenCalled();
    expect(watcherService.unregisterRepository).not.toHaveBeenCalled();
  });

  it("fails fast on invalid boundary roots without sending an RPC", async () => {
    const connection = fakeConnection(openResponse());
    const backendService = fakeBackendService(connection);
    const watcherService = fakeWatcherService();
    const service = repositorySessionService(backendService, watcherService);

    await expect(
      service.openWorkingCopy({
        path: "C:/wc",
        pathCase: "case-insensitive",
        boundaryRoots: ["C:/wc/external", ""],
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_BOUNDARY_ROOT_INVALID",
      category: "input",
      messageKey: "error.repository.boundaryRootInvalid",
      safeArgs: { field: "boundaryRoots.1" },
    });

    expect(backendService.initialize).not.toHaveBeenCalled();
    expect(connection.sendRequest).not.toHaveBeenCalled();
  });

  it("fails fast on relative boundary roots without sending an RPC", async () => {
    const connection = fakeConnection(openResponse());
    const backendService = fakeBackendService(connection);
    const watcherService = fakeWatcherService();
    const service = repositorySessionService(backendService, watcherService);

    await expect(
      service.openWorkingCopy({
        path: "C:/wc",
        pathCase: "case-insensitive",
        boundaryRoots: ["vendor/external"],
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_BOUNDARY_ROOT_INVALID",
      category: "input",
      messageKey: "error.repository.boundaryRootInvalid",
      safeArgs: { field: "boundaryRoots.0" },
    });

    expect(backendService.initialize).not.toHaveBeenCalled();
    expect(connection.sendRequest).not.toHaveBeenCalled();
  });

  it("rolls back the opened backend session when a boundary root is outside the opened working copy", async () => {
    const connection = fakeConnection(openResponse());
    const backendService = fakeBackendService(connection);
    const watcherService = fakeWatcherService();
    const service = repositorySessionService(backendService, watcherService);

    await expect(
      service.openWorkingCopy({
        path: "C:/wc",
        pathCase: "case-insensitive",
        boundaryRoots: ["D:/other-wc"],
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_BOUNDARY_ROOT_OUTSIDE_WORKING_COPY",
      category: "input",
      messageKey: "error.repository.boundaryRootOutsideWorkingCopy",
      safeArgs: { field: "boundaryRoots.0" },
    });

    expect(connection.sendRequest).toHaveBeenNthCalledWith(1, "repository/open", {
      path: "C:/wc",
      boundaryRoots: ["D:/other-wc"],
    });
    expect(connection.sendRequest).toHaveBeenNthCalledWith(2, "repository/close", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
    });
    expect(watcherService.registerRepository).not.toHaveBeenCalled();
  });

  it("rolls back the opened backend session when a boundary root equals the opened working copy root", async () => {
    const connection = fakeConnection(openResponse());
    const backendService = fakeBackendService(connection);
    const watcherService = fakeWatcherService();
    const service = repositorySessionService(backendService, watcherService);

    await expect(
      service.openWorkingCopy({
        path: "C:/wc",
        pathCase: "case-insensitive",
        boundaryRoots: ["C:/WC"],
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_BOUNDARY_ROOT_OUTSIDE_WORKING_COPY",
      category: "input",
      messageKey: "error.repository.boundaryRootOutsideWorkingCopy",
      safeArgs: { field: "boundaryRoots.0" },
    });

    expect(connection.sendRequest).toHaveBeenNthCalledWith(1, "repository/open", {
      path: "C:/wc",
      boundaryRoots: ["C:/WC"],
    });
    expect(connection.sendRequest).toHaveBeenNthCalledWith(2, "repository/close", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
    });
    expect(watcherService.registerRepository).not.toHaveBeenCalled();
  });
});

function openResponse(overrides: Partial<RepositoryOpenResponse> = {}): RepositoryOpenResponse {
  const identity = {
    repositoryUuid: "8fb8e1d2-013a-4d91-8a7b-94f39937b46d",
    repositoryRootUrl: "file:///C:/repos/project",
    workingCopyRoot: "C:\\wc",
    workspaceScopeRoot: "C:\\wc",
    format: 31,
    ...overrides.identity,
  };
  return {
    repositoryId: overrides.repositoryId ?? "repo-uuid:C:/wc",
    epoch: overrides.epoch ?? 7,
    identity,
  };
}

function secondOpenResponse(): RepositoryOpenResponse {
  return {
    repositoryId: "repo-uuid:D:/other-wc",
    epoch: 3,
    identity: {
      repositoryUuid: "69b56c42-04c0-43c9-b3fb-76e26e1a57e8",
      repositoryRootUrl: "file:///D:/repos/other-project",
      workingCopyRoot: "D:\\other-wc",
      workspaceScopeRoot: "D:\\other-wc",
      format: 31,
    },
  };
}

function closeResponse(): RepositoryCloseResponse {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    closed: true,
  };
}

function fakeBackendService(connection: BackendConnection): Pick<BackendService, "initialize"> {
  return {
    initialize: vi.fn().mockResolvedValue(connection),
  };
}

function fakeConnection(openResult: unknown | unknown[], closeResult: unknown = closeResponse()): BackendConnection {
  const openResults = Array.isArray(openResult) ? [...openResult] : undefined;
  const sendRequest = vi.fn((method: string, _params: unknown): Promise<unknown> => {
    if (method === "repository/open") {
      const result = openResults ? openResults.shift() : openResult;
      if (result instanceof Error) {
        return Promise.reject(result);
      }
      return Promise.resolve(result);
    }
    if (method === "repository/close") {
      if (closeResult instanceof Error) {
        return Promise.reject(closeResult);
      }
      return Promise.resolve(closeResult);
    }
    return Promise.resolve({});
  });

  return {
    initializeResult: initializeResult(),
    sendRequest: sendRequest as unknown as BackendConnection["sendRequest"],
    onDidTerminate: vi.fn(() => ({ dispose: vi.fn() })),
    shutdown: vi.fn().mockResolvedValue(undefined),
    dispose: vi.fn(),
  };
}

function fakeWatcherService(): Pick<RepositoryWatcherService, "registerRepository" | "replaceRepository" | "unregisterRepository"> & {
  registerRepository: ReturnType<typeof vi.fn<(scope: RepositoryWatchScope) => void>>;
  replaceRepository: ReturnType<typeof vi.fn<(scope: RepositoryWatchScope) => void>>;
  unregisterRepository: ReturnType<typeof vi.fn<(repositoryId: string) => void>>;
} {
  return {
    registerRepository: vi.fn<(scope: RepositoryWatchScope) => void>(),
    replaceRepository: vi.fn<(scope: RepositoryWatchScope) => void>(),
    unregisterRepository: vi.fn<(repositoryId: string) => void>(),
  };
}

function repositorySessionService(
  backendService: Pick<BackendService, "initialize">,
  watcherService: Pick<RepositoryWatcherService, "registerRepository" | "replaceRepository" | "unregisterRepository">,
  deps: {
    statusSnapshotClient?: Pick<BackendStatusSnapshotClient, "getSnapshot">;
    statusSnapshotStore?: Pick<
      StatusSnapshotStore,
      "registerRepository" | "unregisterRepository" | "applySnapshot" | "getSnapshot" | "markStale" | "replaceSnapshot"
    >;
    sourceControlProjection?: Pick<
      SourceControlProjectionService,
      "registerRepository" | "unregisterRepository" | "applySnapshot" | "getProjection" | "markStale" | "replaceSnapshot"
    >;
  } = {},
): RepositorySessionService {
  return new RepositorySessionService({
    backendService,
    watcherService,
    statusSnapshotClient: deps.statusSnapshotClient ?? fakeSnapshotClient(snapshotResponse()),
    statusSnapshotStore: deps.statusSnapshotStore ?? fakeSnapshotStore(),
    sourceControlProjection: deps.sourceControlProjection ?? fakeSourceControlProjection(),
  });
}

function fakeSourceControlProjection(): Pick<
  SourceControlProjectionService,
  "registerRepository" | "unregisterRepository" | "applySnapshot" | "getProjection" | "markStale" | "replaceSnapshot"
> & {
  registerRepository: ReturnType<typeof vi.fn<(repository: SourceControlProjectionRepository) => void>>;
  unregisterRepository: ReturnType<typeof vi.fn<(repositoryId: string) => void>>;
  applySnapshot: ReturnType<typeof vi.fn<(snapshot: StatusSnapshot) => ReturnType<SourceControlProjectionService["applySnapshot"]>>>;
  getProjection: ReturnType<typeof vi.fn<(repositoryId: string) => ScmRepositoryProjection | undefined>>;
  markStale: ReturnType<typeof vi.fn<(mark: StatusStaleMark) => ScmRepositoryProjection>>;
  replaceSnapshot: ReturnType<typeof vi.fn<(snapshot: StatusSnapshot) => ScmRepositoryProjection>>;
} {
  let projection: ScmRepositoryProjection | undefined;
  const applySnapshot = (snapshot: StatusSnapshot): ScmRepositoryProjection => {
    projection = {
      repositoryId: snapshot.repositoryId,
      epoch: snapshot.epoch,
      workingCopyRoot: snapshot.identity.workingCopyRoot,
      generation: snapshot.generation,
      count: 0,
      freshness: {
        repositoryCompleteness: snapshot.completeness,
        lastRefreshCompleteness: snapshot.completeness,
        lastRefreshKind: "snapshot",
      },
      groups: [],
    };
    return projection;
  };
  return {
    registerRepository: vi.fn<(repository: SourceControlProjectionRepository) => void>(),
    unregisterRepository: vi.fn<(repositoryId: string) => void>(() => {
      projection = undefined;
    }),
    applySnapshot: vi.fn<(snapshot: StatusSnapshot) => ReturnType<SourceControlProjectionService["applySnapshot"]>>(
      applySnapshot,
    ),
    getProjection: vi.fn<(repositoryId: string) => ScmRepositoryProjection | undefined>((repositoryId) =>
      projection?.repositoryId === repositoryId ? projection : undefined,
    ),
    markStale: vi.fn<(mark: StatusStaleMark) => ScmRepositoryProjection>((mark) => {
      if (!projection || projection.repositoryId !== mark.repositoryId || projection.epoch !== mark.epoch) {
        throw new Error("projection state unavailable");
      }
      projection = {
        ...projection,
        freshness: {
          repositoryCompleteness: "stale",
          lastRefreshCompleteness: "stale",
          lastRefreshKind: "stale",
        },
      };
      return projection;
    }),
    replaceSnapshot: vi.fn<(snapshot: StatusSnapshot) => ScmRepositoryProjection>(applySnapshot),
  };
}

function fakeSnapshotClient(
  result: StatusSnapshot | StatusSnapshot[] | Error,
): Pick<BackendStatusSnapshotClient, "getSnapshot"> & {
  getSnapshot: ReturnType<typeof vi.fn<(request: StatusSnapshotRequest) => Promise<StatusSnapshot>>>;
} {
  const results = Array.isArray(result) ? [...result] : undefined;
  const singleResult: StatusSnapshot | Error | undefined = Array.isArray(result) ? undefined : result;
  return {
    getSnapshot: vi.fn<(request: StatusSnapshotRequest) => Promise<StatusSnapshot>>(() => {
      const nextResult: StatusSnapshot | Error | undefined = results ? results.shift() : singleResult;
      if (!nextResult) {
        return Promise.reject(new Error("snapshot result exhausted"));
      }
      if (nextResult instanceof Error) {
        return Promise.reject(nextResult);
      }
      return Promise.resolve(nextResult);
    }),
  };
}

function fakeSnapshotStore(): Pick<
  StatusSnapshotStore,
  "registerRepository" | "unregisterRepository" | "applySnapshot" | "getSnapshot" | "markStale" | "replaceSnapshot"
> & {
  registerRepository: ReturnType<typeof vi.fn<(repository: StatusSnapshotRepository) => void>>;
  unregisterRepository: ReturnType<typeof vi.fn<(repositoryId: string) => void>>;
  applySnapshot: ReturnType<typeof vi.fn<(snapshot: StatusSnapshot) => ReturnType<StatusSnapshotStore["applySnapshot"]>>>;
  getSnapshot: ReturnType<typeof vi.fn<(repositoryId: string) => StoredStatusSnapshot | undefined>>;
  markStale: ReturnType<typeof vi.fn<(mark: StatusStaleMark) => StoredStatusSnapshot>>;
  replaceSnapshot: ReturnType<typeof vi.fn<(snapshot: StatusSnapshot) => StoredStatusSnapshot>>;
} {
  let snapshot: StoredStatusSnapshot | undefined;
  const applySnapshot = (nextSnapshot: StatusSnapshot): StoredStatusSnapshot => {
    snapshot = {
      repositoryId: nextSnapshot.repositoryId,
      epoch: nextSnapshot.epoch,
      generation: nextSnapshot.generation,
      completeness: nextSnapshot.completeness,
      identity: nextSnapshot.identity,
      localEntries: nextSnapshot.localEntries,
      remoteEntries: nextSnapshot.remoteEntries,
      summary: nextSnapshot.summary,
      timestamp: nextSnapshot.timestamp,
      source: nextSnapshot.source,
    };
    return snapshot;
  };
  return {
    registerRepository: vi.fn<(repository: StatusSnapshotRepository) => void>(),
    unregisterRepository: vi.fn<(repositoryId: string) => void>(() => {
      snapshot = undefined;
    }),
    applySnapshot: vi.fn<(snapshot: StatusSnapshot) => ReturnType<StatusSnapshotStore["applySnapshot"]>>(
      applySnapshot,
    ),
    getSnapshot: vi.fn<(repositoryId: string) => StoredStatusSnapshot | undefined>((repositoryId) =>
      snapshot?.repositoryId === repositoryId ? snapshot : undefined,
    ),
    markStale: vi.fn<(mark: StatusStaleMark) => StoredStatusSnapshot>((mark) => {
      if (!snapshot || snapshot.repositoryId !== mark.repositoryId || snapshot.epoch !== mark.epoch) {
        throw new Error("snapshot state unavailable");
      }
      snapshot = {
        ...snapshot,
        completeness: "stale",
        timestamp: mark.timestamp,
        source: mark.source,
      };
      return snapshot;
    }),
    replaceSnapshot: vi.fn<(snapshot: StatusSnapshot) => StoredStatusSnapshot>(applySnapshot),
  };
}

function snapshotResponse(overrides: Partial<StatusSnapshot> = {}): StatusSnapshot {
  const response = openResponse({
    repositoryId: overrides.repositoryId,
    epoch: overrides.epoch,
    identity: overrides.identity,
  });
  return {
    repositoryId: response.repositoryId,
    epoch: response.epoch,
    generation: overrides.generation ?? 1,
    completeness: overrides.completeness ?? "complete",
    identity: response.identity,
    localEntries: overrides.localEntries ?? [],
    remoteEntries: overrides.remoteEntries ?? [],
    summary: overrides.summary ?? {
      localChanges: 0,
      remoteChanges: 0,
      conflicts: 0,
      unversioned: 0,
    },
    timestamp: overrides.timestamp ?? "2026-06-22T00:00:00Z",
    source: overrides.source ?? "libsvn-local",
  };
}

class CodedError extends Error {
  public constructor(public readonly code: string) {
    super(code);
  }
}

function initializeResult(): InitializeResult {
  return {
    protocol: { major: 1, minor: 28 },
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
    },
  };
}

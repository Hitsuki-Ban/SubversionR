import * as nodePath from "node:path";
import type { BackendConnection } from "../backend/backendProcess";
import type { BackendService } from "../backend/backendService";
import type { SourceControlProjectionService } from "../scm/sourceControlProjectionService";
import type { BackendStatusSnapshotClient } from "../status/backendStatusSnapshotClient";
import type { RepositoryWatcherService } from "../status/repositoryWatcherService";
import type { StatusSnapshotStore, StatusStaleMark } from "../status/statusSnapshotStore";
import type { PathCasePolicy, RepositoryWatchScope } from "../status/types";

export type RepositorySessionErrorCategory = "input" | "protocol" | "lifecycle";

export interface RepositorySessionServiceOptions {
  backendService: Pick<BackendService, "initialize">;
  watcherService: Pick<RepositoryWatcherService, "registerRepository" | "replaceRepository" | "unregisterRepository">;
  statusSnapshotClient: Pick<BackendStatusSnapshotClient, "getSnapshot">;
  statusSnapshotStore: Pick<
    StatusSnapshotStore,
    "registerRepository" | "unregisterRepository" | "applySnapshot" | "getSnapshot" | "markStale" | "replaceSnapshot"
  >;
  sourceControlProjection: Pick<
    SourceControlProjectionService,
    "registerRepository" | "unregisterRepository" | "applySnapshot" | "getProjection" | "markStale" | "replaceSnapshot"
  >;
}

export interface RepositoryOpenRequest {
  path: string;
  pathCase: PathCasePolicy;
  boundaryRoots?: string[];
}

export interface RepositoryIdentity {
  repositoryUuid: string;
  repositoryRootUrl: string;
  workingCopyRoot: string;
  workspaceScopeRoot: string;
  format: number;
}

export interface RepositoryOpenResponse {
  repositoryId: string;
  epoch: number;
  identity: RepositoryIdentity;
}

export interface RepositoryCloseResponse {
  repositoryId: string;
  epoch: number;
  closed: boolean;
}

export interface RepositorySession {
  repositoryId: string;
  epoch: number;
  identity: RepositoryIdentity;
  watchScope: RepositoryWatchScope;
}

export interface RepositorySessionsStaleRequest {
  reason: string;
  timestamp: string;
  source: string;
}

export type RepositorySessionReopenResult =
  | {
      kind: "reopened";
      repositoryId: string;
      previousEpoch: number;
      epoch: number;
      workingCopyRoot: string;
    }
  | {
      kind: "reopenFailed";
      repositoryId: string;
      epoch: number;
      workingCopyRoot: string;
      code: string;
    };

export type RepositorySessionChange =
  | {
      kind: "opened";
      repositoryId: string;
      epoch: number;
    }
  | {
      kind: "reopened";
      repositoryId: string;
      previousEpoch: number;
      epoch: number;
    }
  | {
      kind: "closed";
      repositoryId: string;
      epoch: number;
    };

export interface RepositorySessionSubscription {
  dispose(): void;
}

export class RepositorySessionError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: RepositorySessionErrorCategory,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
    options?: ErrorOptions,
  ) {
    super(code, options);
    this.name = "RepositorySessionError";
  }
}

export class RepositorySessionService {
  private readonly sessions = new Map<string, RepositorySession>();
  private readonly listeners = new Set<(event: RepositorySessionChange) => void>();

  public constructor(private readonly options: RepositorySessionServiceOptions) {}

  public onDidChangeSessions(listener: (event: RepositorySessionChange) => void): RepositorySessionSubscription {
    this.listeners.add(listener);
    return {
      dispose: () => {
        this.listeners.delete(listener);
      },
    };
  }

  public async openWorkingCopy(request: RepositoryOpenRequest): Promise<RepositorySession> {
    const validatedRequest = validateOpenRequest(request);
    const connection = await this.options.backendService.initialize();
    const rawResponse = await connection
      .sendRequest<unknown>("repository/open", repositoryOpenParams(validatedRequest))
      .catch((error: unknown) => {
        throw mapRepositoryOpenError(error);
      });
    const response = parseOpenResponse(rawResponse);
    if (this.sessions.has(response.repositoryId)) {
      throw new RepositorySessionError(
        "SUBVERSIONR_REPOSITORY_SESSION_ALREADY_OPEN",
        "lifecycle",
        "error.repository.sessionAlreadyOpen",
        { repositoryId: response.repositoryId },
      );
    }
    let watchScope: RepositoryWatchScope | undefined;
    let watcherRegistered = false;
    let statusStoreRegistered = false;
    let sourceControlRegistered = false;

    try {
      watchScope = watchScopeFromResponse(response, validatedRequest);
      this.options.watcherService.registerRepository(watchScope);
      watcherRegistered = true;
      this.options.statusSnapshotStore.registerRepository({
        repositoryId: response.repositoryId,
        epoch: response.epoch,
      });
      statusStoreRegistered = true;
      this.options.sourceControlProjection.registerRepository({
        repositoryId: response.repositoryId,
        epoch: response.epoch,
        workingCopyRoot: response.identity.workingCopyRoot,
      });
      sourceControlRegistered = true;
      const snapshot = await this.options.statusSnapshotClient.getSnapshot({
        repositoryId: response.repositoryId,
        epoch: response.epoch,
      });
      this.options.statusSnapshotStore.applySnapshot(snapshot);
      this.options.sourceControlProjection.applySnapshot(snapshot);
    } catch (error) {
      const cleanupError = this.cleanupLocalOpenState(response, {
        watcherRegistered,
        statusStoreRegistered,
        sourceControlRegistered,
      });
      await rollbackOpenedRepository(connection, response, error);
      if (cleanupError) {
        throw new RepositorySessionError(
          "SUBVERSIONR_REPOSITORY_OPEN_CLEANUP_FAILED",
          "lifecycle",
          "error.repository.openCleanupFailed",
          {
            repositoryId: response.repositoryId,
            epoch: response.epoch,
          },
          { cause: { originalError: error, cleanupError } },
        );
      }
      throw error;
    }

    if (!watchScope) {
      throw new RepositorySessionError(
        "SUBVERSIONR_REPOSITORY_WATCH_SCOPE_UNINITIALIZED",
        "lifecycle",
        "error.repository.watchScopeUninitialized",
        { repositoryId: response.repositoryId },
      );
    }

    const session: RepositorySession = {
      repositoryId: response.repositoryId,
      epoch: response.epoch,
      identity: response.identity,
      watchScope,
    };
    this.sessions.set(session.repositoryId, session);
    this.fireSessionChange({
      kind: "opened",
      repositoryId: session.repositoryId,
      epoch: session.epoch,
    });
    return session;
  }

  public async closeRepository(repositoryId: string): Promise<void> {
    if (typeof repositoryId !== "string" || repositoryId.trim().length === 0) {
      throw new RepositorySessionError(
        "SUBVERSIONR_REPOSITORY_ID_REQUIRED",
        "input",
        "error.repository.idRequired",
      );
    }

    const session = this.sessions.get(repositoryId);
    if (!session) {
      throw new RepositorySessionError(
        "SUBVERSIONR_REPOSITORY_SESSION_NOT_OPEN",
        "lifecycle",
        "error.repository.sessionNotOpen",
        { repositoryId },
      );
    }

    const connection = await this.options.backendService.initialize();
    await closeBackendSession(connection, session.repositoryId, session.epoch);
    let cleanupError: unknown;
    try {
      this.options.watcherService.unregisterRepository(session.repositoryId);
    } catch (error) {
      cleanupError = error;
    }
    try {
      this.options.statusSnapshotStore.unregisterRepository(session.repositoryId);
    } catch (error) {
      cleanupError ??= error;
    }
    try {
      this.options.sourceControlProjection.unregisterRepository(session.repositoryId);
    } catch (error) {
      cleanupError ??= error;
    } finally {
      if (this.sessions.delete(session.repositoryId)) {
        this.fireSessionChange({
          kind: "closed",
          repositoryId: session.repositoryId,
          epoch: session.epoch,
        });
      }
    }
    if (cleanupError) {
      throw new RepositorySessionError(
        "SUBVERSIONR_REPOSITORY_CLOSE_CLEANUP_FAILED",
        "lifecycle",
        "error.repository.closeCleanupFailed",
        {
          repositoryId: session.repositoryId,
          epoch: session.epoch,
        },
        { cause: cleanupError },
      );
    }
  }

  public listOpenSessions(): RepositorySession[] {
    return Array.from(this.sessions.values()).map((session) => cloneSession(session));
  }

  public refreshSessionIdentityFromSnapshot(request: { repositoryId: string; epoch: number }): RepositorySession {
    const session = this.sessions.get(request.repositoryId);
    if (!session || session.epoch !== request.epoch) {
      throw new RepositorySessionError(
        "SUBVERSIONR_REPOSITORY_SESSION_NOT_OPEN",
        "lifecycle",
        "error.repository.sessionNotOpen",
        {
          repositoryId: request.repositoryId,
          epoch: request.epoch,
        },
      );
    }
    const snapshot = this.options.statusSnapshotStore.getSnapshot(request.repositoryId);
    if (!snapshot || snapshot.epoch !== request.epoch) {
      throw new RepositorySessionError(
        "SUBVERSIONR_REPOSITORY_SESSION_SNAPSHOT_UNAVAILABLE",
        "lifecycle",
        "error.repository.sessionSnapshotUnavailable",
        {
          repositoryId: request.repositoryId,
          epoch: request.epoch,
        },
      );
    }
    validateSnapshotIdentityForSession(snapshot.identity, session);
    const refreshedSession: RepositorySession = {
      ...session,
      identity: {
        ...snapshot.identity,
      },
    };
    this.sessions.set(refreshedSession.repositoryId, refreshedSession);
    return cloneSession(refreshedSession);
  }

  public markOpenSessionsStale(request: RepositorySessionsStaleRequest): void {
    const staleRequest = validateStaleRequest(request);
    const marks = Array.from(this.sessions.values()).map((session): StatusStaleMark => ({
      repositoryId: session.repositoryId,
      epoch: session.epoch,
      reason: staleRequest.reason,
      timestamp: staleRequest.timestamp,
      source: staleRequest.source,
    }));

    for (const mark of marks) {
      const snapshot = this.options.statusSnapshotStore.getSnapshot(mark.repositoryId);
      if (!snapshot || snapshot.epoch !== mark.epoch) {
        throw staleStateUnavailable(mark.repositoryId, "status");
      }
      const projection = this.options.sourceControlProjection.getProjection(mark.repositoryId);
      if (!projection || projection.epoch !== mark.epoch) {
        throw staleStateUnavailable(mark.repositoryId, "projection");
      }
    }

    for (const mark of marks) {
      this.options.statusSnapshotStore.markStale(mark);
      this.markProjectionStale(mark);
    }
  }

  public async reopenOpenSessions(): Promise<RepositorySessionReopenResult[]> {
    const results: RepositorySessionReopenResult[] = [];
    for (const session of Array.from(this.sessions.values()).map((openSession) => cloneSession(openSession))) {
      try {
        results.push(await this.reopenSession(session));
      } catch (error) {
        results.push({
          kind: "reopenFailed",
          repositoryId: session.repositoryId,
          epoch: session.epoch,
          workingCopyRoot: session.identity.workingCopyRoot,
          code: errorCode(error, "SUBVERSIONR_REPOSITORY_REOPEN_FAILED"),
        });
      }
    }
    return results;
  }

  public dispose(): void {
    try {
      for (const session of this.sessions.values()) {
        this.disposeLocalSession(session.repositoryId);
      }
    } finally {
      this.sessions.clear();
    }
  }

  private fireSessionChange(event: RepositorySessionChange): void {
    for (const listener of this.listeners) {
      listener(event);
    }
  }

  private cleanupLocalOpenState(
    response: RepositoryOpenResponse,
    registrations: { watcherRegistered: boolean; statusStoreRegistered: boolean; sourceControlRegistered: boolean },
  ): unknown {
    let cleanupError: unknown;
    if (registrations.sourceControlRegistered) {
      try {
        this.options.sourceControlProjection.unregisterRepository(response.repositoryId);
      } catch (error) {
        cleanupError = error;
      }
    }
    if (registrations.statusStoreRegistered) {
      try {
        this.options.statusSnapshotStore.unregisterRepository(response.repositoryId);
      } catch (error) {
        cleanupError ??= error;
      }
    }
    if (registrations.watcherRegistered) {
      try {
        this.options.watcherService.unregisterRepository(response.repositoryId);
      } catch (error) {
        cleanupError ??= error;
      }
    }
    return cleanupError;
  }

  private disposeLocalSession(repositoryId: string): void {
    try {
      this.options.watcherService.unregisterRepository(repositoryId);
    } catch {
      // Deactivation cleanup is best-effort; continue releasing the rest of the session.
    }
    try {
      this.options.statusSnapshotStore.unregisterRepository(repositoryId);
    } catch {
      // Deactivation cleanup is best-effort; continue releasing the rest of the session.
    }
    try {
      this.options.sourceControlProjection.unregisterRepository(repositoryId);
    } catch {
      // Deactivation cleanup is best-effort; dispose must not block later sessions.
    }
  }

  private async reopenSession(session: RepositorySession): Promise<RepositorySessionReopenResult> {
    const connection = await this.options.backendService.initialize();
    const openRequest = {
      path: session.identity.workingCopyRoot,
      pathCase: session.watchScope.pathCase,
      ...(session.watchScope.boundaryRoots ? { boundaryRoots: [...session.watchScope.boundaryRoots] } : {}),
    };
    const rawResponse = await connection
      .sendRequest<unknown>("repository/open", repositoryOpenParams(openRequest))
      .catch((error: unknown) => {
        throw mapRepositoryOpenError(error);
      });
    const response = parseOpenResponse(rawResponse);
    validateReopenResponse(response, session);
    const snapshot = await this.options.statusSnapshotClient.getSnapshot({
      repositoryId: response.repositoryId,
      epoch: response.epoch,
    });
    const watchScope = watchScopeFromResponse(response, openRequest);

    this.options.statusSnapshotStore.replaceSnapshot(snapshot);
    this.options.sourceControlProjection.replaceSnapshot(snapshot);
    this.options.watcherService.replaceRepository(watchScope);

    const reopenedSession: RepositorySession = {
      repositoryId: response.repositoryId,
      epoch: response.epoch,
      identity: response.identity,
      watchScope,
    };
    this.sessions.set(reopenedSession.repositoryId, reopenedSession);
    this.fireSessionChange({
      kind: "reopened",
      repositoryId: reopenedSession.repositoryId,
      previousEpoch: session.epoch,
      epoch: reopenedSession.epoch,
    });
    return {
      kind: "reopened",
      repositoryId: reopenedSession.repositoryId,
      previousEpoch: session.epoch,
      epoch: reopenedSession.epoch,
      workingCopyRoot: reopenedSession.identity.workingCopyRoot,
    };
  }

  private markProjectionStale(mark: StatusStaleMark): void {
    try {
      this.options.sourceControlProjection.markStale(mark);
    } catch (error) {
      const snapshot = this.options.statusSnapshotStore.getSnapshot(mark.repositoryId);
      if (!snapshot || snapshot.epoch !== mark.epoch) {
        throw staleStateUnavailable(mark.repositoryId, "status");
      }
      this.options.sourceControlProjection.replaceSnapshot(snapshot);
      throw error;
    }
  }
}

function cloneSession(session: RepositorySession): RepositorySession {
  return {
    repositoryId: session.repositoryId,
    epoch: session.epoch,
    identity: {
      repositoryUuid: session.identity.repositoryUuid,
      repositoryRootUrl: session.identity.repositoryRootUrl,
      workingCopyRoot: session.identity.workingCopyRoot,
      workspaceScopeRoot: session.identity.workspaceScopeRoot,
      format: session.identity.format,
    },
    watchScope: {
      repositoryId: session.watchScope.repositoryId,
      epoch: session.watchScope.epoch,
      workingCopyRoot: session.watchScope.workingCopyRoot,
      pathCase: session.watchScope.pathCase,
      ...(session.watchScope.boundaryRoots ? { boundaryRoots: [...session.watchScope.boundaryRoots] } : {}),
    },
  };
}

interface ValidatedRepositoryOpenRequest {
  path: string;
  pathCase: PathCasePolicy;
  boundaryRoots?: string[];
}

function repositoryOpenParams(request: ValidatedRepositoryOpenRequest): { path: string; boundaryRoots?: string[] } {
  return {
    path: request.path,
    ...(request.boundaryRoots ? { boundaryRoots: [...request.boundaryRoots] } : {}),
  };
}

function validateOpenRequest(request: RepositoryOpenRequest): ValidatedRepositoryOpenRequest {
  if (!isRecord(request) || typeof request.path !== "string" || request.path.trim().length === 0) {
    throw new RepositorySessionError(
      "SUBVERSIONR_REPOSITORY_OPEN_PATH_REQUIRED",
      "input",
      "error.repository.open.pathRequired",
      { field: "path" },
    );
  }
  if (request.pathCase !== "case-sensitive" && request.pathCase !== "case-insensitive") {
    throw new RepositorySessionError(
      "SUBVERSIONR_REPOSITORY_PATH_CASE_REQUIRED",
      "input",
      "error.repository.pathCaseRequired",
      { field: "pathCase" },
    );
  }

  return {
    path: request.path,
    pathCase: request.pathCase,
    boundaryRoots: validateBoundaryRoots(request.boundaryRoots),
  };
}

function validateStaleRequest(request: RepositorySessionsStaleRequest): RepositorySessionsStaleRequest {
  if (!isRecord(request)) {
    throw staleRequestInvalid("request");
  }
  if (typeof request.reason !== "string" || request.reason.trim().length === 0) {
    throw staleRequestInvalid("reason");
  }
  if (typeof request.timestamp !== "string" || request.timestamp.trim().length === 0) {
    throw staleRequestInvalid("timestamp");
  }
  if (typeof request.source !== "string" || request.source.trim().length === 0) {
    throw staleRequestInvalid("source");
  }
  return {
    reason: request.reason,
    timestamp: request.timestamp,
    source: request.source,
  };
}

function staleRequestInvalid(field: string): RepositorySessionError {
  return new RepositorySessionError(
    "SUBVERSIONR_REPOSITORY_STALE_REQUEST_INVALID",
    "input",
    "error.status.staleNotificationInvalid",
    { field },
  );
}

function staleStateUnavailable(repositoryId: string, state: "status" | "projection"): RepositorySessionError {
  return new RepositorySessionError(
    "SUBVERSIONR_REPOSITORY_STALE_STATE_UNAVAILABLE",
    "lifecycle",
    "error.status.notificationStateUnavailable",
    { repositoryId, state },
  );
}

function validateBoundaryRoots(boundaryRoots: unknown): string[] | undefined {
  if (boundaryRoots === undefined) {
    return undefined;
  }
  if (!Array.isArray(boundaryRoots)) {
    throw new RepositorySessionError(
      "SUBVERSIONR_REPOSITORY_BOUNDARY_ROOT_INVALID",
      "input",
      "error.repository.boundaryRootInvalid",
      { field: "boundaryRoots" },
    );
  }

  return boundaryRoots.map((boundaryRoot, index) => {
    if (typeof boundaryRoot !== "string" || boundaryRoot.trim().length === 0) {
      throw invalidBoundaryRoot(`boundaryRoots.${index}`);
    }
    if (!isSafeAbsolutePath(normalizeAbsolutePath(boundaryRoot))) {
      throw invalidBoundaryRoot(`boundaryRoots.${index}`);
    }
    return boundaryRoot;
  });
}

function parseOpenResponse(rawResponse: unknown): RepositoryOpenResponse {
  const response = requireRecord(rawResponse, "result");
  const identity = requireRecord(response.identity, "identity");

  return {
    repositoryId: requireString(response.repositoryId, "repositoryId"),
    epoch: requireSafeInteger(response.epoch, "epoch"),
    identity: {
      repositoryUuid: requireString(identity.repositoryUuid, "identity.repositoryUuid"),
      repositoryRootUrl: requireString(identity.repositoryRootUrl, "identity.repositoryRootUrl"),
      workingCopyRoot: requireString(identity.workingCopyRoot, "identity.workingCopyRoot"),
      workspaceScopeRoot: requireString(identity.workspaceScopeRoot, "identity.workspaceScopeRoot"),
      format: requireSafeInteger(identity.format, "identity.format"),
    },
  };
}

function mapRepositoryOpenError(error: unknown): unknown {
  const rpcError = rpcErrorObject(error);
  if (rpcError && rpcError.code === "REPOSITORY_ALREADY_OPEN") {
    const args = isRecord(rpcError.args) ? rpcError.args : {};
    const repositoryId = typeof args.repositoryId === "string" ? args.repositoryId : undefined;
    throw new RepositorySessionError(
      "SUBVERSIONR_REPOSITORY_SESSION_ALREADY_OPEN",
      "lifecycle",
      "error.repository.sessionAlreadyOpen",
      repositoryId ? { repositoryId } : {},
      { cause: error },
    );
  }
  return error;
}

function watchScopeFromResponse(
  response: RepositoryOpenResponse,
  request: ValidatedRepositoryOpenRequest,
): RepositoryWatchScope {
  const boundaryRoots = validateBoundaryRootScope(response.identity.workingCopyRoot, request);
  return {
    repositoryId: response.repositoryId,
    epoch: response.epoch,
    workingCopyRoot: response.identity.workingCopyRoot,
    pathCase: request.pathCase,
    ...(boundaryRoots ? { boundaryRoots } : {}),
  };
}

function validateReopenResponse(response: RepositoryOpenResponse, session: RepositorySession): void {
  if (
    response.repositoryId === session.repositoryId &&
    response.identity.repositoryUuid === session.identity.repositoryUuid &&
    response.identity.repositoryRootUrl === session.identity.repositoryRootUrl &&
    normalizeAbsolutePath(response.identity.workingCopyRoot) ===
      normalizeAbsolutePath(session.identity.workingCopyRoot)
  ) {
    return;
  }
  throw new RepositorySessionError(
    "SUBVERSIONR_REPOSITORY_REOPEN_IDENTITY_MISMATCH",
    "protocol",
    "error.repository.reopenIdentityMismatch",
    {
      repositoryId: session.repositoryId,
      actualRepositoryId: response.repositoryId,
    },
  );
}

function validateSnapshotIdentityForSession(identity: RepositoryIdentity, session: RepositorySession): void {
  if (
    identity.repositoryUuid === session.identity.repositoryUuid &&
    normalizeAbsolutePath(identity.workingCopyRoot) === normalizeAbsolutePath(session.identity.workingCopyRoot)
  ) {
    return;
  }
  throw new RepositorySessionError(
    "SUBVERSIONR_REPOSITORY_SESSION_IDENTITY_MISMATCH",
    "protocol",
    "error.repository.sessionIdentityMismatch",
    {
      repositoryId: session.repositoryId,
      actualRepositoryUuid: identity.repositoryUuid,
      actualWorkingCopyRoot: identity.workingCopyRoot,
    },
  );
}

function validateBoundaryRootScope(
  workingCopyRoot: string,
  request: ValidatedRepositoryOpenRequest,
): string[] | undefined {
  if (!request.boundaryRoots) {
    return undefined;
  }
  const workingCopyRootKey = comparisonKey(request.pathCase, normalizeAbsolutePath(workingCopyRoot));
  return request.boundaryRoots.map((boundaryRoot, index) => {
    const boundaryRootKey = comparisonKey(request.pathCase, normalizeAbsolutePath(boundaryRoot));
    if (boundaryRootKey === workingCopyRootKey || !boundaryRootKey.startsWith(`${workingCopyRootKey}/`)) {
      throw new RepositorySessionError(
        "SUBVERSIONR_REPOSITORY_BOUNDARY_ROOT_OUTSIDE_WORKING_COPY",
        "input",
        "error.repository.boundaryRootOutsideWorkingCopy",
        { field: `boundaryRoots.${index}` },
      );
    }
    return boundaryRoot;
  });
}

async function rollbackOpenedRepository(
  connection: BackendConnection,
  response: RepositoryOpenResponse,
  originalError: unknown,
): Promise<void> {
  try {
    await closeBackendSession(connection, response.repositoryId, response.epoch);
  } catch (rollbackError) {
    throw new RepositorySessionError(
      "SUBVERSIONR_REPOSITORY_OPEN_ROLLBACK_FAILED",
      "lifecycle",
      "error.repository.openRollbackFailed",
      {
        repositoryId: response.repositoryId,
        epoch: response.epoch,
      },
      { cause: { originalError, rollbackError } },
    );
  }
}

async function closeBackendSession(
  connection: BackendConnection,
  repositoryId: string,
  epoch: number,
): Promise<void> {
  parseCloseResponse(
    await connection.sendRequest<unknown>("repository/close", {
      repositoryId,
      epoch,
    }),
    { repositoryId, epoch },
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function errorCode(error: unknown, fallback: string): string {
  if (typeof error === "object" && error !== null && "code" in error) {
    const code = (error as { code?: unknown }).code;
    if (typeof code === "string" && code.trim().length > 0) {
      return code;
    }
  }
  return fallback;
}

function invalidBoundaryRoot(field: string): RepositorySessionError {
  return new RepositorySessionError(
    "SUBVERSIONR_REPOSITORY_BOUNDARY_ROOT_INVALID",
    "input",
    "error.repository.boundaryRootInvalid",
    { field },
  );
}

function normalizeAbsolutePath(path: string): string {
  return path.replaceAll("\\", "/").replace(/\/+$/u, "");
}

function isSafeAbsolutePath(path: string): boolean {
  if (!nodePath.win32.isAbsolute(path) && !nodePath.posix.isAbsolute(path)) {
    return false;
  }
  const parts = path.split("/");
  return !parts.some((part, index) => {
    if (part === "." || part === "..") {
      return true;
    }
    if (part !== "") {
      return false;
    }
    return !isAllowedAbsolutePrefix(parts, index);
  });
}

function isAllowedAbsolutePrefix(parts: string[], index: number): boolean {
  if (index === 0 && parts.length > 1) {
    return true;
  }
  return index === 1 && parts[0] === "" && parts.length > 2;
}

function comparisonKey(pathCase: PathCasePolicy, path: string): string {
  return pathCase === "case-insensitive" ? path.toLocaleLowerCase("en-US") : path;
}

function rpcErrorObject(error: unknown): Record<string, unknown> | undefined {
  if (!isRecord(error) || !isRecord(error.error)) {
    return undefined;
  }
  return error.error;
}

function requireRecord(value: unknown, field: string): Record<string, unknown> {
  if (!isRecord(value)) {
    throw invalidOpenResponse(field);
  }
  return value;
}

function requireString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw invalidOpenResponse(field);
  }
  return value;
}

function requireSafeInteger(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw invalidOpenResponse(field);
  }
  return value;
}

function invalidOpenResponse(field: string): RepositorySessionError {
  return new RepositorySessionError(
    "SUBVERSIONR_REPOSITORY_OPEN_RESPONSE_INVALID",
    "protocol",
    "error.repository.openResponseInvalid",
    { field },
  );
}

function parseCloseResponse(
  rawResponse: unknown,
  expected: { repositoryId: string; epoch: number },
): RepositoryCloseResponse {
  const response = requireCloseRecord(rawResponse, "result");
  const repositoryId = requireCloseString(response.repositoryId, "repositoryId");
  const epoch = requireCloseSafeInteger(response.epoch, "epoch");
  const closed = requireCloseBoolean(response.closed, "closed");

  if (repositoryId !== expected.repositoryId) {
    throw invalidCloseResponse("repositoryId");
  }
  if (epoch !== expected.epoch) {
    throw invalidCloseResponse("epoch");
  }
  if (!closed) {
    throw invalidCloseResponse("closed");
  }

  return { repositoryId, epoch, closed };
}

function requireCloseRecord(value: unknown, field: string): Record<string, unknown> {
  if (!isRecord(value)) {
    throw invalidCloseResponse(field);
  }
  return value;
}

function requireCloseString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw invalidCloseResponse(field);
  }
  return value;
}

function requireCloseSafeInteger(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw invalidCloseResponse(field);
  }
  return value;
}

function requireCloseBoolean(value: unknown, field: string): boolean {
  if (typeof value !== "boolean") {
    throw invalidCloseResponse(field);
  }
  return value;
}

function invalidCloseResponse(field: string): RepositorySessionError {
  return new RepositorySessionError(
    "SUBVERSIONR_REPOSITORY_CLOSE_RESPONSE_INVALID",
    "protocol",
    "error.repository.closeResponseInvalid",
    { field },
  );
}

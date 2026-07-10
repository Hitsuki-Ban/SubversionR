import type { JsonRpcSender, StatusRefreshDepth, StatusRefreshTarget } from "../status/types";

export type OperationRunErrorCategory = "input" | "protocol";

export interface RevertOperationRequest {
  repositoryId: string;
  epoch: number;
  paths: string[];
  depth: StatusRefreshDepth;
  changelists: string[];
  clearChangelists: boolean;
  metadataOnly: boolean;
  addedKeepLocal: boolean;
}

export interface AddOperationRequest {
  repositoryId: string;
  epoch: number;
  paths: string[];
  depth: StatusRefreshDepth;
  force: boolean;
  noIgnore: boolean;
  noAutoprops: boolean;
  addParents: boolean;
}

export interface RemoveOperationRequest {
  repositoryId: string;
  epoch: number;
  paths: string[];
  force: boolean;
  keepLocal: boolean;
}

export interface MoveOperationRequest {
  repositoryId: string;
  epoch: number;
  sourcePath: string;
  destinationPath: string;
  makeParents: boolean;
}

export type ResolveOperationChoice =
  | "working"
  | "base"
  | "mineFull"
  | "theirsFull"
  | "mineConflict"
  | "theirsConflict";

export interface ResolveOperationRequest {
  repositoryId: string;
  epoch: number;
  paths: string[];
  depth: "empty";
  choice: ResolveOperationChoice;
}

export interface CleanupOperationRequest {
  repositoryId: string;
  epoch: number;
  path: ".";
  breakLocks: boolean;
  fixRecordedTimestamps: boolean;
  clearDavCache: boolean;
  vacuumPristines: boolean;
  includeExternals: boolean;
}

export interface UpgradeOperationRequest {
  repositoryId: string;
  epoch: number;
  path: ".";
}

const MAX_SVN_REVNUM = 2_147_483_647;

export type UpdateOperationRevision = "head" | number;
export type UpdateOperationDepth = "workingCopy" | StatusRefreshDepth;

export interface UpdateOperationRequest {
  repositoryId: string;
  epoch: number;
  path: string;
  revision: UpdateOperationRevision;
  depth: UpdateOperationDepth;
  depthIsSticky: boolean;
  ignoreExternals: boolean;
}

export interface BranchCreateOperationRequest {
  repositoryId: string;
  epoch: number;
  sourceUrl: string;
  destinationUrl: string;
  revision: UpdateOperationRevision;
  message: string;
  makeParents: boolean;
  ignoreExternals: boolean;
}

export interface SwitchOperationRequest {
  repositoryId: string;
  epoch: number;
  path: string;
  url: string;
  revision: UpdateOperationRevision;
  depth: UpdateOperationDepth;
  depthIsSticky: boolean;
  ignoreExternals: boolean;
  ignoreAncestry: boolean;
}

export interface RelocateOperationRequest {
  repositoryId: string;
  epoch: number;
  fromUrl: string;
  toUrl: string;
  ignoreExternals: boolean;
}

export interface MergeRangeOperationRequest {
  repositoryId: string;
  epoch: number;
  sourceUrl: string;
  targetPath: string;
  startRevision: number;
  endRevision: number;
  depth: StatusRefreshDepth;
  ignoreMergeinfo: boolean;
  diffIgnoreAncestry: boolean;
  forceDelete: boolean;
  recordOnly: boolean;
  dryRun: boolean;
  allowMixedRevisions: boolean;
}

export interface PropertySetOperationRequest {
  repositoryId: string;
  epoch: number;
  path: string;
  name: string;
  value: string;
}

export interface PropertyDeleteOperationRequest {
  repositoryId: string;
  epoch: number;
  path: string;
  name: string;
}

export interface ChangelistSetOperationRequest {
  repositoryId: string;
  epoch: number;
  paths: string[];
  depth: StatusRefreshDepth;
  changelist: string;
  changelists: string[];
}

export interface ChangelistClearOperationRequest {
  repositoryId: string;
  epoch: number;
  paths: string[];
  depth: StatusRefreshDepth;
  changelists: string[];
}

export interface LockOperationRequest {
  repositoryId: string;
  epoch: number;
  paths: string[];
  comment: string | null;
  stealLock: boolean;
}

export interface UnlockOperationRequest {
  repositoryId: string;
  epoch: number;
  paths: string[];
  breakLock: boolean;
}

export interface CommitOperationRequest {
  repositoryId: string;
  epoch: number;
  paths: string[];
  message: string;
  depth: "empty";
  changelists: string[];
  keepLocks: false;
  keepChangelists: false;
  commitAsOperations: false;
  includeFileExternals: false;
  includeDirExternals: false;
}

export interface OperationWarning {
  code: string;
  messageKey: string;
  args: Record<string, unknown>;
}

export interface OperationSummary {
  affectedPaths: number;
  skippedPaths: number;
}

export interface OperationReconcileHint {
  targets: StatusRefreshTarget[];
  requiresFullReconcile: boolean;
}

export interface OperationRunResponse {
  repositoryId: string;
  epoch: number;
  operationId: string;
  kind: string;
  touchedPaths: string[];
  revision: number | null;
  summary: OperationSummary;
  warnings: OperationWarning[];
  reconcile: OperationReconcileHint;
}

export interface OperationRunClientOptions {
  signal?: AbortSignal;
}

export interface OperationClient {
  add(request: AddOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse>;
  cleanup(request: CleanupOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse>;
  upgrade(request: UpgradeOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse>;
  remove(request: RemoveOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse>;
  move(request: MoveOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse>;
  resolve(request: ResolveOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse>;
  revert(request: RevertOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse>;
  update(request: UpdateOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse>;
  branchCreate(request: BranchCreateOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse>;
  switch(request: SwitchOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse>;
  relocate(request: RelocateOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse>;
  merge(request: MergeRangeOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse>;
  propertySet(request: PropertySetOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse>;
  propertyDelete(request: PropertyDeleteOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse>;
  changelistSet(request: ChangelistSetOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse>;
  changelistClear(request: ChangelistClearOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse>;
  lock(request: LockOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse>;
  unlock(request: UnlockOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse>;
  commit(request: CommitOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse>;
}

export class OperationRunResponseError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: OperationRunErrorCategory,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "OperationRunResponseError";
  }
}

export class OperationRunRpcClient implements OperationClient {
  public constructor(private readonly sender: JsonRpcSender) {}

  public async add(request: AddOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse> {
    const validatedRequest = validateAddRequest(request);
    const rawResponse = await sendOperationRunRequest(this.sender, {
      repositoryId: validatedRequest.repositoryId,
      epoch: validatedRequest.epoch,
      kind: "add",
      options: {
        version: 1,
        paths: validatedRequest.paths,
        depth: validatedRequest.depth,
        force: validatedRequest.force,
        noIgnore: validatedRequest.noIgnore,
        noAutoprops: validatedRequest.noAutoprops,
        addParents: validatedRequest.addParents,
      },
    }, options);
    const response = parseOperationRunResponse(rawResponse);
    requireOperationMatchesRequest(response, validatedRequest, "add");
    return response;
  }

  public async remove(request: RemoveOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse> {
    const validatedRequest = validateRemoveRequest(request);
    const rawResponse = await sendOperationRunRequest(this.sender, {
      repositoryId: validatedRequest.repositoryId,
      epoch: validatedRequest.epoch,
      kind: "remove",
      options: {
        version: 1,
        paths: validatedRequest.paths,
        force: validatedRequest.force,
        keepLocal: validatedRequest.keepLocal,
      },
    }, options);
    const response = parseOperationRunResponse(rawResponse);
    requireOperationMatchesRequest(response, validatedRequest, "remove");
    return response;
  }

  public async move(request: MoveOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse> {
    const validatedRequest = validateMoveRequest(request);
    const rawResponse = await sendOperationRunRequest(this.sender, {
      repositoryId: validatedRequest.repositoryId,
      epoch: validatedRequest.epoch,
      kind: "move",
      options: {
        version: 1,
        sourcePath: validatedRequest.sourcePath,
        destinationPath: validatedRequest.destinationPath,
        makeParents: validatedRequest.makeParents,
      },
    }, options);
    const response = parseOperationRunResponse(rawResponse);
    requireOperationMatchesRequest(response, validatedRequest, "move");
    return response;
  }

  public async cleanup(request: CleanupOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse> {
    const validatedRequest = validateCleanupRequest(request);
    const rawResponse = await sendOperationRunRequest(this.sender, {
      repositoryId: validatedRequest.repositoryId,
      epoch: validatedRequest.epoch,
      kind: "cleanup",
      options: {
        version: 1,
        path: validatedRequest.path,
        breakLocks: validatedRequest.breakLocks,
        fixRecordedTimestamps: validatedRequest.fixRecordedTimestamps,
        clearDavCache: validatedRequest.clearDavCache,
        vacuumPristines: validatedRequest.vacuumPristines,
        includeExternals: validatedRequest.includeExternals,
      },
    }, options);
    const response = parseOperationRunResponse(rawResponse);
    requireOperationMatchesRequest(response, validatedRequest, "cleanup");
    if (!response.reconcile.requiresFullReconcile) {
      throw invalidOperationResponse("reconcile.requiresFullReconcile");
    }
    return response;
  }

  public async upgrade(request: UpgradeOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse> {
    const validatedRequest = validateUpgradeRequest(request);
    const rawResponse = await sendOperationRunRequest(this.sender, {
      repositoryId: validatedRequest.repositoryId,
      epoch: validatedRequest.epoch,
      kind: "upgrade",
      options: {
        version: 1,
        path: validatedRequest.path,
      },
    }, options);
    const response = parseOperationRunResponse(rawResponse);
    requireOperationMatchesRequest(response, validatedRequest, "upgrade");
    if (!response.reconcile.requiresFullReconcile) {
      throw invalidOperationResponse("reconcile.requiresFullReconcile");
    }
    return response;
  }

  public async update(request: UpdateOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse> {
    const validatedRequest = validateUpdateRequest(request);
    const rawResponse = await sendOperationRunRequest(this.sender, {
      repositoryId: validatedRequest.repositoryId,
      epoch: validatedRequest.epoch,
      kind: "update",
      options: {
        version: 1,
        path: validatedRequest.path,
        revision: validatedRequest.revision,
        depth: validatedRequest.depth,
        depthIsSticky: validatedRequest.depthIsSticky,
        ignoreExternals: validatedRequest.ignoreExternals,
      },
    }, options);
    const response = parseOperationRunResponse(rawResponse);
    requireOperationMatchesRequest(response, validatedRequest, "update");
    if (!response.reconcile.requiresFullReconcile) {
      throw invalidOperationResponse("reconcile.requiresFullReconcile");
    }
    if (response.revision === null) {
      throw invalidOperationResponse("revision");
    }
    return response;
  }

  public async branchCreate(
    request: BranchCreateOperationRequest,
    options?: OperationRunClientOptions,
  ): Promise<OperationRunResponse> {
    const validatedRequest = validateBranchCreateRequest(request);
    const rawResponse = await sendOperationRunRequest(this.sender, {
      repositoryId: validatedRequest.repositoryId,
      epoch: validatedRequest.epoch,
      kind: "branchCreate",
      options: {
        version: 1,
        sourceUrl: validatedRequest.sourceUrl,
        destinationUrl: validatedRequest.destinationUrl,
        revision: validatedRequest.revision,
        message: validatedRequest.message,
        makeParents: validatedRequest.makeParents,
        ignoreExternals: validatedRequest.ignoreExternals,
      },
    }, options);
    const response = parseOperationRunResponse(rawResponse, {
      allowEmptyTargetedReconcile: true,
    });
    requireOperationMatchesRequest(response, validatedRequest, "branchCreate");
    if (response.reconcile.requiresFullReconcile) {
      throw invalidOperationResponse("reconcile.requiresFullReconcile");
    }
    if (response.reconcile.targets.length !== 0) {
      throw invalidOperationResponse("reconcile.targets");
    }
    if (response.revision === null) {
      throw invalidOperationResponse("revision");
    }
    return response;
  }

  public async switch(
    request: SwitchOperationRequest,
    options?: OperationRunClientOptions,
  ): Promise<OperationRunResponse> {
    const validatedRequest = validateSwitchRequest(request);
    const rawResponse = await sendOperationRunRequest(this.sender, {
      repositoryId: validatedRequest.repositoryId,
      epoch: validatedRequest.epoch,
      kind: "switch",
      options: {
        version: 1,
        path: validatedRequest.path,
        url: validatedRequest.url,
        revision: validatedRequest.revision,
        depth: validatedRequest.depth,
        depthIsSticky: validatedRequest.depthIsSticky,
        ignoreExternals: validatedRequest.ignoreExternals,
        ignoreAncestry: validatedRequest.ignoreAncestry,
      },
    }, options);
    const response = parseOperationRunResponse(rawResponse);
    requireOperationMatchesRequest(response, validatedRequest, "switch");
    if (!response.reconcile.requiresFullReconcile) {
      throw invalidOperationResponse("reconcile.requiresFullReconcile");
    }
    if (response.revision === null) {
      throw invalidOperationResponse("revision");
    }
    return response;
  }

  public async relocate(
    request: RelocateOperationRequest,
    options?: OperationRunClientOptions,
  ): Promise<OperationRunResponse> {
    const validatedRequest = validateRelocateRequest(request);
    const rawResponse = await sendOperationRunRequest(this.sender, {
      repositoryId: validatedRequest.repositoryId,
      epoch: validatedRequest.epoch,
      kind: "relocate",
      options: {
        version: 1,
        fromUrl: validatedRequest.fromUrl,
        toUrl: validatedRequest.toUrl,
        ignoreExternals: validatedRequest.ignoreExternals,
      },
    }, options);
    const response = parseOperationRunResponse(rawResponse);
    requireOperationMatchesRequest(response, validatedRequest, "relocate");
    if (!response.reconcile.requiresFullReconcile) {
      throw invalidOperationResponse("reconcile.requiresFullReconcile");
    }
    return response;
  }

  public async merge(
    request: MergeRangeOperationRequest,
    options?: OperationRunClientOptions,
  ): Promise<OperationRunResponse> {
    const validatedRequest = validateMergeRangeRequest(request);
    const rawResponse = await sendOperationRunRequest(this.sender, {
      repositoryId: validatedRequest.repositoryId,
      epoch: validatedRequest.epoch,
      kind: "merge",
      options: {
        version: 1,
        sourceUrl: validatedRequest.sourceUrl,
        targetPath: validatedRequest.targetPath,
        startRevision: validatedRequest.startRevision,
        endRevision: validatedRequest.endRevision,
        depth: validatedRequest.depth,
        ignoreMergeinfo: validatedRequest.ignoreMergeinfo,
        diffIgnoreAncestry: validatedRequest.diffIgnoreAncestry,
        forceDelete: validatedRequest.forceDelete,
        recordOnly: validatedRequest.recordOnly,
        dryRun: validatedRequest.dryRun,
        allowMixedRevisions: validatedRequest.allowMixedRevisions,
      },
    }, options);
    const response = parseOperationRunResponse(rawResponse);
    requireOperationMatchesRequest(response, validatedRequest, "merge");
    if (validatedRequest.dryRun && response.reconcile.requiresFullReconcile) {
      throw invalidOperationResponse("reconcile.requiresFullReconcile");
    }
    if (!validatedRequest.dryRun && !response.reconcile.requiresFullReconcile) {
      throw invalidOperationResponse("reconcile.requiresFullReconcile");
    }
    return response;
  }

  public async propertySet(request: PropertySetOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse> {
    const validatedRequest = validatePropertySetRequest(request);
    const rawResponse = await sendOperationRunRequest(this.sender, {
      repositoryId: validatedRequest.repositoryId,
      epoch: validatedRequest.epoch,
      kind: "propertySet",
      options: {
        version: 1,
        path: validatedRequest.path,
        name: validatedRequest.name,
        value: validatedRequest.value,
      },
    }, options);
    const response = parseOperationRunResponse(rawResponse);
    requireOperationMatchesRequest(response, validatedRequest, "propertySet");
    return response;
  }

  public async propertyDelete(request: PropertyDeleteOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse> {
    const validatedRequest = validatePropertyDeleteRequest(request);
    const rawResponse = await sendOperationRunRequest(this.sender, {
      repositoryId: validatedRequest.repositoryId,
      epoch: validatedRequest.epoch,
      kind: "propertyDelete",
      options: {
        version: 1,
        path: validatedRequest.path,
        name: validatedRequest.name,
      },
    }, options);
    const response = parseOperationRunResponse(rawResponse);
    requireOperationMatchesRequest(response, validatedRequest, "propertyDelete");
    return response;
  }

  public async changelistSet(request: ChangelistSetOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse> {
    const validatedRequest = validateChangelistSetRequest(request);
    const rawResponse = await sendOperationRunRequest(this.sender, {
      repositoryId: validatedRequest.repositoryId,
      epoch: validatedRequest.epoch,
      kind: "changelistSet",
      options: {
        version: 1,
        paths: validatedRequest.paths,
        depth: validatedRequest.depth,
        changelist: validatedRequest.changelist,
        changelists: validatedRequest.changelists,
      },
    }, options);
    const response = parseOperationRunResponse(rawResponse);
    requireOperationMatchesRequest(response, validatedRequest, "changelistSet");
    return response;
  }

  public async changelistClear(request: ChangelistClearOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse> {
    const validatedRequest = validateChangelistClearRequest(request);
    const rawResponse = await sendOperationRunRequest(this.sender, {
      repositoryId: validatedRequest.repositoryId,
      epoch: validatedRequest.epoch,
      kind: "changelistClear",
      options: {
        version: 1,
        paths: validatedRequest.paths,
        depth: validatedRequest.depth,
        changelists: validatedRequest.changelists,
      },
    }, options);
    const response = parseOperationRunResponse(rawResponse);
    requireOperationMatchesRequest(response, validatedRequest, "changelistClear");
    return response;
  }

  public async lock(request: LockOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse> {
    const validatedRequest = validateLockRequest(request);
    const rawResponse = await sendOperationRunRequest(this.sender, {
      repositoryId: validatedRequest.repositoryId,
      epoch: validatedRequest.epoch,
      kind: "lock",
      options: {
        version: 1,
        paths: validatedRequest.paths,
        comment: validatedRequest.comment,
        stealLock: validatedRequest.stealLock,
      },
    }, options);
    const response = parseOperationRunResponse(rawResponse);
    requireOperationMatchesRequest(response, validatedRequest, "lock");
    return response;
  }

  public async unlock(request: UnlockOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse> {
    const validatedRequest = validateUnlockRequest(request);
    const rawResponse = await sendOperationRunRequest(this.sender, {
      repositoryId: validatedRequest.repositoryId,
      epoch: validatedRequest.epoch,
      kind: "unlock",
      options: {
        version: 1,
        paths: validatedRequest.paths,
        breakLock: validatedRequest.breakLock,
      },
    }, options);
    const response = parseOperationRunResponse(rawResponse);
    requireOperationMatchesRequest(response, validatedRequest, "unlock");
    return response;
  }

  public async commit(request: CommitOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse> {
    const validatedRequest = validateCommitRequest(request);
    const rawResponse = await sendOperationRunRequest(this.sender, {
      repositoryId: validatedRequest.repositoryId,
      epoch: validatedRequest.epoch,
      kind: "commit",
      options: {
        version: 1,
        paths: validatedRequest.paths,
        message: validatedRequest.message,
        depth: validatedRequest.depth,
        changelists: validatedRequest.changelists,
        keepLocks: validatedRequest.keepLocks,
        keepChangelists: validatedRequest.keepChangelists,
        commitAsOperations: validatedRequest.commitAsOperations,
        includeFileExternals: validatedRequest.includeFileExternals,
        includeDirExternals: validatedRequest.includeDirExternals,
      },
    }, options);
    const response = parseOperationRunResponse(rawResponse);
    requireOperationMatchesRequest(response, validatedRequest, "commit");
    if (response.revision === null) {
      throw invalidOperationResponse("revision");
    }
    return response;
  }

  public async resolve(request: ResolveOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse> {
    const validatedRequest = validateResolveRequest(request);
    const rawResponse = await sendOperationRunRequest(this.sender, {
      repositoryId: validatedRequest.repositoryId,
      epoch: validatedRequest.epoch,
      kind: "resolve",
      options: {
        version: 1,
        paths: validatedRequest.paths,
        depth: validatedRequest.depth,
        choice: validatedRequest.choice,
      },
    }, options);
    const response = parseOperationRunResponse(rawResponse);
    requireOperationMatchesRequest(response, validatedRequest, "resolve");
    return response;
  }

  public async revert(request: RevertOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse> {
    const validatedRequest = validateRevertRequest(request);
    const rawResponse = await sendOperationRunRequest(this.sender, {
      repositoryId: validatedRequest.repositoryId,
      epoch: validatedRequest.epoch,
      kind: "revert",
      options: {
        version: 1,
        paths: validatedRequest.paths,
        depth: validatedRequest.depth,
        changelists: validatedRequest.changelists,
        clearChangelists: validatedRequest.clearChangelists,
        metadataOnly: validatedRequest.metadataOnly,
        addedKeepLocal: validatedRequest.addedKeepLocal,
      },
    }, options);
    const response = parseOperationRunResponse(rawResponse);
    requireOperationMatchesRequest(response, validatedRequest, "revert");
    return response;
  }
}

function sendOperationRunRequest(
  sender: JsonRpcSender,
  params: Record<string, unknown>,
  options?: OperationRunClientOptions,
): Promise<unknown> {
  if (options === undefined) {
    return sender.sendRequest<unknown>("operation/run", params);
  }
  return sender.sendRequest<unknown>("operation/run", params, options);
}

function validatePropertySetRequest(request: PropertySetOperationRequest): PropertySetOperationRequest {
  if (!isRecord(request)) {
    throw invalidOperationRequest("repositoryId");
  }
  requireExactRequestKeys(request, "request", ["repositoryId", "epoch", "path", "name", "value"]);
  return {
    repositoryId: requireRequestString(request.repositoryId, "repositoryId"),
    epoch: requireNonNegativeInteger(request.epoch, "epoch", "request"),
    path: requireRequestPath(request.path, "path"),
    name: requirePropertyName(request.name, "name"),
    value: requirePropertyValue(request.value, "value"),
  };
}

function validatePropertyDeleteRequest(request: PropertyDeleteOperationRequest): PropertyDeleteOperationRequest {
  if (!isRecord(request)) {
    throw invalidOperationRequest("repositoryId");
  }
  requireExactRequestKeys(request, "request", ["repositoryId", "epoch", "path", "name"]);
  return {
    repositoryId: requireRequestString(request.repositoryId, "repositoryId"),
    epoch: requireNonNegativeInteger(request.epoch, "epoch", "request"),
    path: requireRequestPath(request.path, "path"),
    name: requirePropertyName(request.name, "name"),
  };
}

function validateChangelistSetRequest(request: ChangelistSetOperationRequest): ChangelistSetOperationRequest {
  if (!isRecord(request)) {
    throw invalidOperationRequest("repositoryId");
  }
  requireExactRequestKeys(request, "request", [
    "repositoryId",
    "epoch",
    "paths",
    "depth",
    "changelist",
    "changelists",
  ]);
  return {
    repositoryId: requireRequestString(request.repositoryId, "repositoryId"),
    epoch: requireNonNegativeInteger(request.epoch, "epoch", "request"),
    paths: requireDistinctPathArray(request.paths, "paths"),
    depth: requireDepth(request.depth, "depth", "request"),
    changelist: requireChangelistName(request.changelist, "changelist"),
    changelists: requireChangelistArray(request.changelists, "changelists", true),
  };
}

function validateChangelistClearRequest(request: ChangelistClearOperationRequest): ChangelistClearOperationRequest {
  if (!isRecord(request)) {
    throw invalidOperationRequest("repositoryId");
  }
  requireExactRequestKeys(request, "request", [
    "repositoryId",
    "epoch",
    "paths",
    "depth",
    "changelists",
  ]);
  return {
    repositoryId: requireRequestString(request.repositoryId, "repositoryId"),
    epoch: requireNonNegativeInteger(request.epoch, "epoch", "request"),
    paths: requireDistinctPathArray(request.paths, "paths"),
    depth: requireDepth(request.depth, "depth", "request"),
    changelists: requireChangelistArray(request.changelists, "changelists", true),
  };
}

function validateLockRequest(request: LockOperationRequest): LockOperationRequest {
  if (!isRecord(request)) {
    throw invalidOperationRequest("repositoryId");
  }
  requireExactRequestKeys(request, "request", [
    "repositoryId",
    "epoch",
    "paths",
    "comment",
    "stealLock",
  ]);
  return {
    repositoryId: requireRequestString(request.repositoryId, "repositoryId"),
    epoch: requireNonNegativeInteger(request.epoch, "epoch", "request"),
    paths: requireLockPathArray(request.paths, "paths"),
    comment: requireLockComment(request.comment, "comment"),
    stealLock: requireBoolean(request.stealLock, "stealLock", "request"),
  };
}

function validateUnlockRequest(request: UnlockOperationRequest): UnlockOperationRequest {
  if (!isRecord(request)) {
    throw invalidOperationRequest("repositoryId");
  }
  requireExactRequestKeys(request, "request", [
    "repositoryId",
    "epoch",
    "paths",
    "breakLock",
  ]);
  return {
    repositoryId: requireRequestString(request.repositoryId, "repositoryId"),
    epoch: requireNonNegativeInteger(request.epoch, "epoch", "request"),
    paths: requireLockPathArray(request.paths, "paths"),
    breakLock: requireBoolean(request.breakLock, "breakLock", "request"),
  };
}

function validateCommitRequest(request: CommitOperationRequest): CommitOperationRequest {
  if (!isRecord(request)) {
    throw invalidOperationRequest("repositoryId");
  }
  requireExactRequestKeys(request, "request", [
    "repositoryId",
    "epoch",
    "paths",
    "message",
    "depth",
    "changelists",
    "keepLocks",
    "keepChangelists",
    "commitAsOperations",
    "includeFileExternals",
    "includeDirExternals",
  ]);
  const changelists = requireChangelistArray(request.changelists, "changelists", true);
  return {
    repositoryId: requireRequestString(request.repositoryId, "repositoryId"),
    epoch: requireNonNegativeInteger(request.epoch, "epoch", "request"),
    paths: requireCommitPathArray(request.paths, "paths"),
    message: requireCommitMessage(request.message, "message"),
    depth: requireCommitDepth(request.depth, "depth"),
    changelists,
    keepLocks: requireFalse(request.keepLocks, "keepLocks"),
    keepChangelists: requireFalse(request.keepChangelists, "keepChangelists"),
    commitAsOperations: requireFalse(request.commitAsOperations, "commitAsOperations"),
    includeFileExternals: requireFalse(request.includeFileExternals, "includeFileExternals"),
    includeDirExternals: requireFalse(request.includeDirExternals, "includeDirExternals"),
  };
}

function validateUpdateRequest(request: UpdateOperationRequest): UpdateOperationRequest {
  if (!isRecord(request)) {
    throw invalidOperationRequest("repositoryId");
  }
  requireExactRequestKeys(request, "request", [
    "repositoryId",
    "epoch",
    "path",
    "revision",
    "depth",
    "depthIsSticky",
    "ignoreExternals",
  ]);
  const depth = requireUpdateDepth(request.depth, "depth");
  const depthIsSticky = requireBoolean(request.depthIsSticky, "depthIsSticky", "request");
  if (depth === "workingCopy" && depthIsSticky) {
    throw invalidOperationRequest("depthIsSticky");
  }
  return {
    repositoryId: requireRequestString(request.repositoryId, "repositoryId"),
    epoch: requireNonNegativeInteger(request.epoch, "epoch", "request"),
    path: requireRequestPath(request.path, "path"),
    revision: requireUpdateRevision(request.revision, "revision"),
    depth,
    depthIsSticky,
    ignoreExternals: requireBoolean(request.ignoreExternals, "ignoreExternals", "request"),
  };
}

function validateBranchCreateRequest(request: BranchCreateOperationRequest): BranchCreateOperationRequest {
  if (!isRecord(request)) {
    throw invalidOperationRequest("repositoryId");
  }
  requireExactRequestKeys(request, "request", [
    "repositoryId",
    "epoch",
    "sourceUrl",
    "destinationUrl",
    "revision",
    "message",
    "makeParents",
    "ignoreExternals",
  ]);
  const sourceUrl = requireRepositoryUrl(request.sourceUrl, "sourceUrl");
  const destinationUrl = requireRepositoryUrl(request.destinationUrl, "destinationUrl");
  if (destinationUrl === sourceUrl) {
    throw invalidOperationRequest("destinationUrl");
  }
  return {
    repositoryId: requireRequestString(request.repositoryId, "repositoryId"),
    epoch: requireNonNegativeInteger(request.epoch, "epoch", "request"),
    sourceUrl,
    destinationUrl,
    revision: requireUpdateRevision(request.revision, "revision"),
    message: requireCommitMessage(request.message, "message"),
    makeParents: requireBoolean(request.makeParents, "makeParents", "request"),
    ignoreExternals: requireBoolean(request.ignoreExternals, "ignoreExternals", "request"),
  };
}

function validateSwitchRequest(request: SwitchOperationRequest): SwitchOperationRequest {
  if (!isRecord(request)) {
    throw invalidOperationRequest("repositoryId");
  }
  requireExactRequestKeys(request, "request", [
    "repositoryId",
    "epoch",
    "path",
    "url",
    "revision",
    "depth",
    "depthIsSticky",
    "ignoreExternals",
    "ignoreAncestry",
  ]);
  const depth = requireUpdateDepth(request.depth, "depth");
  const depthIsSticky = requireBoolean(request.depthIsSticky, "depthIsSticky", "request");
  if (depth === "workingCopy" && depthIsSticky) {
    throw invalidOperationRequest("depthIsSticky");
  }
  return {
    repositoryId: requireRequestString(request.repositoryId, "repositoryId"),
    epoch: requireNonNegativeInteger(request.epoch, "epoch", "request"),
    path: requireRequestPath(request.path, "path"),
    url: requireRepositoryUrl(request.url, "url"),
    revision: requireUpdateRevision(request.revision, "revision"),
    depth,
    depthIsSticky,
    ignoreExternals: requireBoolean(request.ignoreExternals, "ignoreExternals", "request"),
    ignoreAncestry: requireBoolean(request.ignoreAncestry, "ignoreAncestry", "request"),
  };
}

function validateRelocateRequest(request: RelocateOperationRequest): RelocateOperationRequest {
  if (!isRecord(request)) {
    throw invalidOperationRequest("repositoryId");
  }
  requireExactRequestKeys(request, "request", [
    "repositoryId",
    "epoch",
    "fromUrl",
    "toUrl",
    "ignoreExternals",
  ]);
  const fromUrl = requireRepositoryUrl(request.fromUrl, "fromUrl");
  const toUrl = requireRepositoryUrl(request.toUrl, "toUrl");
  if (fromUrl === toUrl) {
    throw invalidOperationRequest("toUrl");
  }
  return {
    repositoryId: requireRequestString(request.repositoryId, "repositoryId"),
    epoch: requireNonNegativeInteger(request.epoch, "epoch", "request"),
    fromUrl,
    toUrl,
    ignoreExternals: requireBoolean(request.ignoreExternals, "ignoreExternals", "request"),
  };
}

function validateMergeRangeRequest(request: MergeRangeOperationRequest): MergeRangeOperationRequest {
  if (!isRecord(request)) {
    throw invalidOperationRequest("repositoryId");
  }
  requireExactRequestKeys(request, "request", [
    "repositoryId",
    "epoch",
    "sourceUrl",
    "targetPath",
    "startRevision",
    "endRevision",
    "depth",
    "ignoreMergeinfo",
    "diffIgnoreAncestry",
    "forceDelete",
    "recordOnly",
    "dryRun",
    "allowMixedRevisions",
  ]);
  const startRevision = requireMergeRevision(request.startRevision, "startRevision");
  const endRevision = requireMergeRevision(request.endRevision, "endRevision");
  if (startRevision === endRevision) {
    throw invalidOperationRequest("endRevision");
  }
  return {
    repositoryId: requireRequestString(request.repositoryId, "repositoryId"),
    epoch: requireNonNegativeInteger(request.epoch, "epoch", "request"),
    sourceUrl: requireRepositoryUrl(request.sourceUrl, "sourceUrl"),
    targetPath: requireRequestPath(request.targetPath, "targetPath"),
    startRevision,
    endRevision,
    depth: requireDepth(request.depth, "depth", "request"),
    ignoreMergeinfo: requireBoolean(request.ignoreMergeinfo, "ignoreMergeinfo", "request"),
    diffIgnoreAncestry: requireBoolean(request.diffIgnoreAncestry, "diffIgnoreAncestry", "request"),
    forceDelete: requireBoolean(request.forceDelete, "forceDelete", "request"),
    recordOnly: requireBoolean(request.recordOnly, "recordOnly", "request"),
    dryRun: requireBoolean(request.dryRun, "dryRun", "request"),
    allowMixedRevisions: requireBoolean(request.allowMixedRevisions, "allowMixedRevisions", "request"),
  };
}

function validateResolveRequest(request: ResolveOperationRequest): ResolveOperationRequest {
  if (!isRecord(request)) {
    throw invalidOperationRequest("repositoryId");
  }
  requireExactRequestKeys(request, "request", [
    "repositoryId",
    "epoch",
    "paths",
    "depth",
    "choice",
  ]);
  return {
    repositoryId: requireRequestString(request.repositoryId, "repositoryId"),
    epoch: requireNonNegativeInteger(request.epoch, "epoch", "request"),
    paths: requireSinglePathArray(request.paths, "paths"),
    depth: requireResolveDepth(request.depth, "depth"),
    choice: requireResolveChoice(request.choice, "choice"),
  };
}

function validateCleanupRequest(request: CleanupOperationRequest): CleanupOperationRequest {
  if (!isRecord(request)) {
    throw invalidOperationRequest("repositoryId");
  }
  requireExactRequestKeys(request, "request", [
    "repositoryId",
    "epoch",
    "path",
    "breakLocks",
    "fixRecordedTimestamps",
    "clearDavCache",
    "vacuumPristines",
    "includeExternals",
  ]);
  return {
    repositoryId: requireRequestString(request.repositoryId, "repositoryId"),
    epoch: requireNonNegativeInteger(request.epoch, "epoch", "request"),
    path: requireRootPath(request.path, "path"),
    breakLocks: requireBoolean(request.breakLocks, "breakLocks", "request"),
    fixRecordedTimestamps: requireBoolean(
      request.fixRecordedTimestamps,
      "fixRecordedTimestamps",
      "request",
    ),
    clearDavCache: requireBoolean(request.clearDavCache, "clearDavCache", "request"),
    vacuumPristines: requireBoolean(request.vacuumPristines, "vacuumPristines", "request"),
    includeExternals: requireBoolean(request.includeExternals, "includeExternals", "request"),
  };
}

function validateUpgradeRequest(request: UpgradeOperationRequest): UpgradeOperationRequest {
  if (!isRecord(request)) {
    throw invalidOperationRequest("repositoryId");
  }
  requireExactRequestKeys(request, "request", ["repositoryId", "epoch", "path"]);
  return {
    repositoryId: requireRequestString(request.repositoryId, "repositoryId"),
    epoch: requireNonNegativeInteger(request.epoch, "epoch", "request"),
    path: requireRootPath(request.path, "path"),
  };
}

function validateAddRequest(request: AddOperationRequest): AddOperationRequest {
  if (!isRecord(request)) {
    throw invalidOperationRequest("repositoryId");
  }
  requireExactRequestKeys(request, "request", [
    "repositoryId",
    "epoch",
    "paths",
    "depth",
    "force",
    "noIgnore",
    "noAutoprops",
    "addParents",
  ]);
  return {
    repositoryId: requireRequestString(request.repositoryId, "repositoryId"),
    epoch: requireNonNegativeInteger(request.epoch, "epoch", "request"),
    paths: requireSinglePathArray(request.paths, "paths"),
    depth: requireDepth(request.depth, "depth", "request"),
    force: requireBoolean(request.force, "force", "request"),
    noIgnore: requireBoolean(request.noIgnore, "noIgnore", "request"),
    noAutoprops: requireBoolean(request.noAutoprops, "noAutoprops", "request"),
    addParents: requireBoolean(request.addParents, "addParents", "request"),
  };
}

function validateRemoveRequest(request: RemoveOperationRequest): RemoveOperationRequest {
  if (!isRecord(request)) {
    throw invalidOperationRequest("repositoryId");
  }
  requireExactRequestKeys(request, "request", [
    "repositoryId",
    "epoch",
    "paths",
    "force",
    "keepLocal",
  ]);
  return {
    repositoryId: requireRequestString(request.repositoryId, "repositoryId"),
    epoch: requireNonNegativeInteger(request.epoch, "epoch", "request"),
    paths: requireDistinctPathArray(request.paths, "paths"),
    force: requireBoolean(request.force, "force", "request"),
    keepLocal: requireBoolean(request.keepLocal, "keepLocal", "request"),
  };
}

function validateMoveRequest(request: MoveOperationRequest): MoveOperationRequest {
  if (!isRecord(request)) {
    throw invalidOperationRequest("repositoryId");
  }
  requireExactRequestKeys(request, "request", [
    "repositoryId",
    "epoch",
    "sourcePath",
    "destinationPath",
    "makeParents",
  ]);
  const sourcePath = requireMovePath(request.sourcePath, "sourcePath");
  const destinationPath = requireMovePath(request.destinationPath, "destinationPath");
  if (destinationPath === sourcePath) {
    throw invalidOperationRequest("destinationPath");
  }
  return {
    repositoryId: requireRequestString(request.repositoryId, "repositoryId"),
    epoch: requireNonNegativeInteger(request.epoch, "epoch", "request"),
    sourcePath,
    destinationPath,
    makeParents: requireBoolean(request.makeParents, "makeParents", "request"),
  };
}

function validateRevertRequest(request: RevertOperationRequest): RevertOperationRequest {
  if (!isRecord(request)) {
    throw invalidOperationRequest("repositoryId");
  }
  requireExactRequestKeys(request, "request", [
    "repositoryId",
    "epoch",
    "paths",
    "depth",
    "changelists",
    "clearChangelists",
    "metadataOnly",
    "addedKeepLocal",
  ]);
  return {
    repositoryId: requireRequestString(request.repositoryId, "repositoryId"),
    epoch: requireNonNegativeInteger(request.epoch, "epoch", "request"),
    paths: requirePathArray(request.paths, "paths", false),
    depth: requireDepth(request.depth, "depth", "request"),
    changelists: requireChangelistArray(request.changelists, "changelists", true),
    clearChangelists: requireBoolean(request.clearChangelists, "clearChangelists", "request"),
    metadataOnly: requireBoolean(request.metadataOnly, "metadataOnly", "request"),
    addedKeepLocal: requireBoolean(request.addedKeepLocal, "addedKeepLocal", "request"),
  };
}

interface ParseOperationRunResponseOptions {
  allowEmptyTargetedReconcile?: boolean;
}

function parseOperationRunResponse(
  rawResponse: unknown,
  options: ParseOperationRunResponseOptions = {},
): OperationRunResponse {
  const response = requireResponseRecord(rawResponse, "result");
  requireExactResponseKeys(response, "result", [
    "repositoryId",
    "epoch",
    "operationId",
    "kind",
    "touchedPaths",
    "revision",
    "summary",
    "warnings",
    "reconcile",
  ]);
  return {
    repositoryId: requireResponseString(response.repositoryId, "repositoryId"),
    epoch: requireNonNegativeInteger(response.epoch, "epoch", "response"),
    operationId: requireResponseString(response.operationId, "operationId"),
    kind: requireResponseString(response.kind, "kind"),
    touchedPaths: requireResponsePathArray(response.touchedPaths, "touchedPaths", true),
    revision: requireRevision(response.revision, "revision"),
    summary: parseOperationSummary(response.summary, "summary"),
    warnings: parseWarnings(response.warnings, "warnings"),
    reconcile: parseReconcile(response.reconcile, "reconcile", options),
  };
}

function requireOperationMatchesRequest(
  response: OperationRunResponse,
  request: OperationRequestIdentity,
  kind: string,
): void {
  if (response.repositoryId !== request.repositoryId) {
    throw invalidOperationResponse("repositoryId");
  }
  if (response.epoch !== request.epoch) {
    throw invalidOperationResponse("epoch");
  }
  if (response.kind !== kind) {
    throw invalidOperationResponse("kind");
  }
}

interface OperationRequestIdentity {
  repositoryId: string;
  epoch: number;
}

function parseOperationSummary(rawSummary: unknown, field: string): OperationSummary {
  const summary = requireResponseRecord(rawSummary, field);
  requireExactResponseKeys(summary, field, ["affectedPaths", "skippedPaths"]);
  return {
    affectedPaths: requireNonNegativeInteger(summary.affectedPaths, `${field}.affectedPaths`, "response"),
    skippedPaths: requireNonNegativeInteger(summary.skippedPaths, `${field}.skippedPaths`, "response"),
  };
}

function parseWarnings(rawWarnings: unknown, field: string): OperationWarning[] {
  if (!Array.isArray(rawWarnings)) {
    throw invalidOperationResponse(field);
  }
  return rawWarnings.map((warning, index) => parseWarning(warning, `${field}.${index}`));
}

function parseWarning(rawWarning: unknown, field: string): OperationWarning {
  const warning = requireResponseRecord(rawWarning, field);
  requireExactResponseKeys(warning, field, ["code", "messageKey", "args"]);
  const args = warning.args;
  if (!isPlainObject(args)) {
    throw invalidOperationResponse(`${field}.args`);
  }
  return {
    code: requireResponseString(warning.code, `${field}.code`),
    messageKey: requireResponseString(warning.messageKey, `${field}.messageKey`),
    args,
  };
}

function parseReconcile(
  rawReconcile: unknown,
  field: string,
  options: ParseOperationRunResponseOptions,
): OperationReconcileHint {
  const reconcile = requireResponseRecord(rawReconcile, field);
  requireExactResponseKeys(reconcile, field, ["targets", "requiresFullReconcile"]);
  const targets = parseTargets(reconcile.targets, `${field}.targets`);
  const requiresFullReconcile = requireBoolean(
    reconcile.requiresFullReconcile,
    `${field}.requiresFullReconcile`,
    "response",
  );
  if (!requiresFullReconcile && targets.length === 0 && !options.allowEmptyTargetedReconcile) {
    throw invalidOperationResponse(`${field}.targets`);
  }
  return {
    targets,
    requiresFullReconcile,
  };
}

function parseTargets(rawTargets: unknown, field: string): StatusRefreshTarget[] {
  if (!Array.isArray(rawTargets)) {
    throw invalidOperationResponse(field);
  }
  return rawTargets.map((target, index) => parseTarget(target, `${field}.${index}`));
}

function parseTarget(rawTarget: unknown, field: string): StatusRefreshTarget {
  const target = requireResponseRecord(rawTarget, field);
  requireExactResponseKeys(target, field, ["path", "depth", "reason"]);
  return {
    path: requireResponsePath(target.path, `${field}.path`),
    depth: requireDepth(target.depth, `${field}.depth`, "response"),
    reason: requireResponseString(target.reason, `${field}.reason`),
  };
}

function requirePathArray(value: unknown, field: string, allowEmpty: boolean): string[] {
  if (!Array.isArray(value) || (!allowEmpty && value.length === 0)) {
    throw invalidOperationRequest(field);
  }
  return value.map((path, index) => requireRequestPath(path, `${field}.${index}`));
}

function requireSinglePathArray(value: unknown, field: string): string[] {
  const paths = requirePathArray(value, field, false);
  if (paths.length !== 1) {
    throw invalidOperationRequest(field);
  }
  return paths;
}

function requireDistinctPathArray(value: unknown, field: string): string[] {
  const paths = requirePathArray(value, field, false);
  const seen = new Set<string>();
  for (const [index, path] of paths.entries()) {
    if (seen.has(path)) {
      throw invalidOperationRequest(`${field}.${index}`);
    }
    seen.add(path);
  }
  return paths;
}

function requireCommitPathArray(value: unknown, field: string): string[] {
  const paths = requirePathArray(value, field, false);
  const seen = new Set<string>();
  for (const [index, path] of paths.entries()) {
    if (path === "." || seen.has(path)) {
      throw invalidOperationRequest(`${field}.${index}`);
    }
    seen.add(path);
  }
  return paths;
}

function requireLockPathArray(value: unknown, field: string): string[] {
  const paths = requirePathArray(value, field, false);
  const seen = new Set<string>();
  for (const [index, path] of paths.entries()) {
    if (path === "." || seen.has(path)) {
      throw invalidOperationRequest(`${field}.${index}`);
    }
    seen.add(path);
  }
  return paths;
}

function requireResponsePathArray(value: unknown, field: string, allowEmpty: boolean): string[] {
  if (!Array.isArray(value) || (!allowEmpty && value.length === 0)) {
    throw invalidOperationResponse(field);
  }
  return value.map((path, index) => requireResponsePath(path, `${field}.${index}`));
}

function requireStringArray(value: unknown, field: string, allowEmpty: boolean): string[] {
  if (!Array.isArray(value) || (!allowEmpty && value.length === 0)) {
    throw invalidOperationRequest(field);
  }
  return value.map((item, index) => requireRequestString(item, `${field}.${index}`));
}

function requireChangelistArray(value: unknown, field: string, allowEmpty: boolean): string[] {
  if (!Array.isArray(value) || (!allowEmpty && value.length === 0)) {
    throw invalidOperationRequest(field);
  }
  const seen = new Set<string>();
  return value.map((item, index) => {
    const changelist = requireChangelistName(item, `${field}.${index}`);
    if (seen.has(changelist)) {
      throw invalidOperationRequest(`${field}.${index}`);
    }
    seen.add(changelist);
    return changelist;
  });
}

function requireEmptyStringArray(value: unknown, field: string): [] {
  const items = requireStringArray(value, field, true);
  if (items.length !== 0) {
    throw invalidOperationRequest(field);
  }
  return [];
}

function requireRevision(value: unknown, field: string): number | null {
  if (value === null) {
    return null;
  }
  if (typeof value !== "number" || !Number.isSafeInteger(value)) {
    throw invalidOperationResponse(field);
  }
  return value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return isRecord(value) && !Array.isArray(value);
}

function requireResponseRecord(value: unknown, field: string): Record<string, unknown> {
  if (!isRecord(value)) {
    throw invalidOperationResponse(field);
  }
  return value;
}

function requireExactRequestKeys(value: Record<string, unknown>, field: string, expectedKeys: readonly string[]): void {
  const expected = new Set(expectedKeys);
  for (const key of Object.keys(value)) {
    if (!expected.has(key)) {
      throw invalidOperationRequest(field === "request" ? key : `${field}.${key}`);
    }
  }
}

function requireExactResponseKeys(value: Record<string, unknown>, field: string, expectedKeys: readonly string[]): void {
  const expected = new Set(expectedKeys);
  for (const key of Object.keys(value)) {
    if (!expected.has(key)) {
      throw invalidOperationResponse(field === "result" ? key : `${field}.${key}`);
    }
  }
}

function requireRequestString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw invalidOperationRequest(field);
  }
  return value;
}

function requireChangelistName(value: unknown, field: string): string {
  const changelist = requireRequestString(value, field);
  if (changelist.includes("\0") || changelist.includes("\r") || changelist.includes("\n")) {
    throw invalidOperationRequest(field);
  }
  return changelist;
}

function requireResponseString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw invalidOperationResponse(field);
  }
  return value;
}

function requireRequestPath(value: unknown, field: string): string {
  const path = requireRequestString(value, field);
  if (!isRepositoryRelativePath(path)) {
    throw invalidOperationRequest(field);
  }
  return path;
}

function requireRootPath(value: unknown, field: string): "." {
  const path = requireRequestString(value, field);
  if (path !== ".") {
    throw invalidOperationRequest(field);
  }
  return path;
}

function requireMovePath(value: unknown, field: string): string {
  const path = requireRequestPath(value, field);
  if (path === ".") {
    throw invalidOperationRequest(field);
  }
  return path;
}

function requireResponsePath(value: unknown, field: string): string {
  const path = requireResponseString(value, field);
  if (!isRepositoryRelativePath(path)) {
    throw invalidOperationResponse(field);
  }
  return path;
}

function requireDepth(value: unknown, field: string, source: "request" | "response"): StatusRefreshDepth {
  const depth =
    source === "request" ? requireRequestString(value, field) : requireResponseString(value, field);
  if (depth !== "empty" && depth !== "files" && depth !== "immediates" && depth !== "infinity") {
    if (source === "request") {
      throw invalidOperationRequest(field);
    }
    throw invalidOperationResponse(field);
  }
  return depth;
}

function requireResolveChoice(value: unknown, field: string): ResolveOperationChoice {
  const choice = requireRequestString(value, field);
  if (
    choice !== "working" &&
    choice !== "base" &&
    choice !== "mineFull" &&
    choice !== "theirsFull" &&
    choice !== "mineConflict" &&
    choice !== "theirsConflict"
  ) {
    throw invalidOperationRequest(field);
  }
  return choice;
}

function requireResolveDepth(value: unknown, field: string): "empty" {
  const depth = requireRequestString(value, field);
  if (depth !== "empty") {
    throw invalidOperationRequest(field);
  }
  return depth;
}

function requireCommitDepth(value: unknown, field: string): "empty" {
  return requireResolveDepth(value, field);
}

function requireCommitMessage(value: unknown, field: string): string {
  const message = requireRequestString(value, field);
  if (message.includes("\0") || message.includes("\r")) {
    throw invalidOperationRequest(field);
  }
  return message;
}

function requireRepositoryUrl(value: unknown, field: string): string {
  const url = requireRequestString(value, field);
  if (url.includes("\0") || url.includes("\r") || url.includes("\n")) {
    throw invalidOperationRequest(field);
  }
  return url;
}

function requireLockComment(value: unknown, field: string): string | null {
  if (value === null) {
    return null;
  }
  const comment = requireRequestString(value, field);
  if (comment.includes("\0") || comment.includes("\r")) {
    throw invalidOperationRequest(field);
  }
  return comment;
}

function requirePropertyName(value: unknown, field: string): string {
  const name = requireRequestString(value, field);
  if (
    name.includes("\0") ||
    name.includes("\r") ||
    name.includes("\n") ||
    !name.split(":").every(isPropertyNamePart)
  ) {
    throw invalidOperationRequest(field);
  }
  return name;
}

function isPropertyNamePart(part: string): boolean {
  return part.length > 0 && /^[A-Za-z0-9._-]+$/u.test(part);
}

function requirePropertyValue(value: unknown, field: string): string {
  if (typeof value !== "string" || value.includes("\0") || value.includes("\r")) {
    throw invalidOperationRequest(field);
  }
  return value;
}

function requireUpdateRevision(value: unknown, field: string): UpdateOperationRevision {
  if (value === "head") {
    return value;
  }
  const revision = requireNonNegativeInteger(value, field, "request");
  if (revision > MAX_SVN_REVNUM) {
    throw invalidOperationRequest(field);
  }
  return revision;
}

function requireMergeRevision(value: unknown, field: string): number {
  const revision = requireNonNegativeInteger(value, field, "request");
  if (revision > MAX_SVN_REVNUM) {
    throw invalidOperationRequest(field);
  }
  return revision;
}

function requireUpdateDepth(value: unknown, field: string): UpdateOperationDepth {
  const depth = requireRequestString(value, field);
  if (depth === "workingCopy" || depth === "empty" || depth === "files" || depth === "immediates" || depth === "infinity") {
    return depth;
  }
  throw invalidOperationRequest(field);
}

function requireFalse(value: unknown, field: string): false {
  const bool = requireBoolean(value, field, "request");
  if (bool !== false) {
    throw invalidOperationRequest(field);
  }
  return bool;
}

function requireTrue(value: unknown, field: string): true {
  const bool = requireBoolean(value, field, "request");
  if (bool !== true) {
    throw invalidOperationRequest(field);
  }
  return bool;
}

function requireBoolean(value: unknown, field: string, source: "request" | "response"): boolean {
  if (typeof value !== "boolean") {
    if (source === "request") {
      throw invalidOperationRequest(field);
    }
    throw invalidOperationResponse(field);
  }
  return value;
}

function requireNonNegativeInteger(value: unknown, field: string, source: "request" | "response"): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    if (source === "request") {
      throw invalidOperationRequest(field);
    }
    throw invalidOperationResponse(field);
  }
  return value;
}

function isRepositoryRelativePath(path: string): boolean {
  if (path === ".") {
    return true;
  }
  const normalized = path.replace(/\\/g, "/");
  if (
    path.includes("\\") ||
    normalized.startsWith("/") ||
    normalized.includes(":") ||
    normalized.includes("\0")
  ) {
    return false;
  }
  return normalized.split("/").every((part) => part.length > 0 && part !== "." && part !== "..");
}

function invalidOperationRequest(field: string): OperationRunResponseError {
  return new OperationRunResponseError(
    "SUBVERSIONR_OPERATION_RUN_REQUEST_INVALID",
    "input",
    "error.operation.runRequestInvalid",
    { field },
  );
}

function invalidOperationResponse(field: string): OperationRunResponseError {
  return new OperationRunResponseError(
    "SUBVERSIONR_OPERATION_RUN_RESPONSE_INVALID",
    "protocol",
    "error.operation.runResponseInvalid",
    { field },
  );
}

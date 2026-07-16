import type {
  JsonRpcSender,
  StatusRefreshClient,
  StatusRefreshClientOptions,
  StatusRefreshDepth,
  StatusRefreshRequest,
} from "./types";
import {
  MAX_CONFLICT_ARTIFACTS_PER_ENTRY,
  type StatusEntry,
  type StatusSnapshotCompleteness,
} from "./statusSnapshotRpcClient";

export type StatusRefreshErrorCategory = "input" | "protocol";

export interface StatusCoverageScope {
  path: string;
  depth: string;
  generation: number;
  reason: string;
}

export interface StatusSummaryDelta {
  localChanges: number;
  remoteChanges: number;
  conflicts: number;
  unversioned: number;
}

export interface StatusDelta {
  repositoryId: string;
  epoch: number;
  generation: number;
  coverage: StatusCoverageScope[];
  upsert: StatusEntry[];
  remove: string[];
  remoteUpsert: StatusEntry[];
  remoteRemove: string[];
  summaryDelta: StatusSummaryDelta;
  completeness: StatusSnapshotCompleteness;
  timestamp: string;
  source: string;
}

export class StatusRefreshResponseError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: StatusRefreshErrorCategory,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "StatusRefreshResponseError";
  }
}

export class StatusRefreshRpcClient implements StatusRefreshClient {
  public constructor(private readonly sender: JsonRpcSender) {}

  public async refreshStatus(
    request: StatusRefreshRequest,
    options: StatusRefreshClientOptions = {},
  ): Promise<StatusDelta> {
    const validatedRequest = validateRefreshRequest(request);
    const rawResponse = options.signal
      ? await this.sender.sendRequest<unknown>("status/refresh", validatedRequest, options)
      : await this.sender.sendRequest<unknown>("status/refresh", validatedRequest);
    const delta = parseStatusDelta(rawResponse);
    requireDeltaMatchesRequest(delta, validatedRequest);
    return delta;
  }
}

function validateRefreshRequest(request: StatusRefreshRequest): StatusRefreshRequest {
  if (!isRecord(request)) {
    throw invalidRefreshRequest("repositoryId");
  }
  requireExactRequestKeys(request, "request", ["repositoryId", "epoch", "targets"]);
  if (!isNonEmptyString(request.repositoryId)) {
    throw invalidRefreshRequest("repositoryId");
  }
  if (!isNonNegativeSafeInteger(request.epoch)) {
    throw invalidRefreshRequest("epoch");
  }
  if (!Array.isArray(request.targets) || request.targets.length === 0) {
    throw invalidRefreshRequest("targets");
  }
  return {
    repositoryId: request.repositoryId,
    epoch: request.epoch,
    targets: request.targets.map((target, index) => validateRefreshTarget(target, `targets.${index}`)),
  };
}

function validateRefreshTarget(target: unknown, field: string): StatusRefreshRequest["targets"][number] {
  const targetRecord = requireRequestRecord(target, field);
  requireExactRequestKeys(targetRecord, field, ["path", "depth", "reason"]);
  return {
    path: requireRequestPath(targetRecord.path, `${field}.path`),
    depth: requireRefreshDepth(targetRecord.depth, `${field}.depth`),
    reason: requireRequestString(targetRecord.reason, `${field}.reason`),
  };
}

export function parseStatusDelta(rawResponse: unknown): StatusDelta {
  const response = requireResponseRecord(rawResponse, "result");
  requireExactResponseKeys(response, "result", [
    "repositoryId",
    "epoch",
    "generation",
    "coverage",
    "upsert",
    "remove",
    "remoteUpsert",
    "remoteRemove",
    "summaryDelta",
    "completeness",
    "timestamp",
    "source",
  ]);
  const generation = requireNonNegativeInteger(response.generation, "generation");
  const upsert = parseStatusEntries(response.upsert, "upsert", generation, "local");
  const remove = parseRemovedPaths(response.remove, "remove");
  const remoteUpsert = parseStatusEntries(response.remoteUpsert, "remoteUpsert", generation, "remote");
  const remoteRemove = parseRemovedPaths(response.remoteRemove, "remoteRemove");
  requireUniqueEntryPaths(upsert, "upsert");
  requireUniquePaths(remove, "remove");
  requireNoDeltaPathOverlap(upsert, remove);
  requireUniqueEntryPaths(remoteUpsert, "remoteUpsert");
  requireUniquePaths(remoteRemove, "remoteRemove");
  requireNoDeltaPathOverlap(remoteUpsert, remoteRemove, "remoteRemove");
  return {
    repositoryId: requireResponseString(response.repositoryId, "repositoryId"),
    epoch: requireNonNegativeInteger(response.epoch, "epoch"),
    generation,
    coverage: parseCoverage(response.coverage, "coverage", generation),
    upsert,
    remove,
    remoteUpsert,
    remoteRemove,
    summaryDelta: parseSummaryDelta(response.summaryDelta, "summaryDelta"),
    completeness: requireCompleteness(response.completeness, "completeness"),
    timestamp: requireResponseString(response.timestamp, "timestamp"),
    source: requireResponseString(response.source, "source"),
  };
}

function requireDeltaMatchesRequest(delta: StatusDelta, request: StatusRefreshRequest): void {
  if (delta.repositoryId !== request.repositoryId) {
    throw invalidRefreshResponse("repositoryId");
  }
  if (delta.epoch !== request.epoch) {
    throw invalidRefreshResponse("epoch");
  }
}

function parseCoverage(rawCoverage: unknown, field: string, deltaGeneration: number): StatusCoverageScope[] {
  if (!Array.isArray(rawCoverage)) {
    throw invalidRefreshResponse(field);
  }
  return rawCoverage.map((scope, index) => parseCoverageScope(scope, `${field}.${index}`, deltaGeneration));
}

function parseCoverageScope(rawScope: unknown, field: string, deltaGeneration: number): StatusCoverageScope {
  const scope = requireResponseRecord(rawScope, field);
  requireExactResponseKeys(scope, field, ["path", "depth", "generation", "reason"]);
  const generation = requireNonNegativeInteger(scope.generation, `${field}.generation`);
  if (generation !== deltaGeneration) {
    throw invalidRefreshResponse(`${field}.generation`);
  }
  return {
    path: requireResponsePath(scope.path, `${field}.path`),
    depth: requireResponseString(scope.depth, `${field}.depth`),
    generation,
    reason: requireResponseString(scope.reason, `${field}.reason`),
  };
}

function parseStatusEntries(
  rawEntries: unknown,
  field: string,
  deltaGeneration: number,
  source: "local" | "remote",
): StatusEntry[] {
  if (!Array.isArray(rawEntries)) {
    throw invalidRefreshResponse(field);
  }
  const entries = rawEntries.map((entry, index) => parseStatusEntry(entry, `${field}.${index}`, deltaGeneration, source));
  if (source === "local") {
    requireNoConflictArtifactEntries(entries, field);
  }
  return entries;
}

function parseStatusEntry(
  rawEntry: unknown,
  field: string,
  deltaGeneration: number,
  source: "local" | "remote",
): StatusEntry {
  const entry = requireResponseRecord(rawEntry, field);
  requireExactResponseKeys(entry, field, [
    "path",
    "kind",
    "nodeStatus",
    "textStatus",
    "propertyStatus",
    "localStatus",
    "remoteStatus",
    "revision",
    "changedRevision",
    "changedAuthor",
    "changedDate",
    "changelist",
    "lock",
    "needsLock",
    "copy",
    "move",
    "switched",
    "depth",
    "conflict",
    "conflictArtifacts",
    "external",
    "generation",
  ]);
  const generation = requireNonNegativeInteger(entry.generation, `${field}.generation`);
  if (generation !== deltaGeneration) {
    throw invalidRefreshResponse(`${field}.generation`);
  }
  const path = requireResponsePath(entry.path, `${field}.path`);
  const conflict = requireNullableString(entry.conflict, `${field}.conflict`);
  const localStatus = requireResponseString(entry.localStatus, `${field}.localStatus`);
  const nodeStatus = requireResponseString(entry.nodeStatus, `${field}.nodeStatus`);
  const textStatus = requireResponseString(entry.textStatus, `${field}.textStatus`);
  const propertyStatus = requireResponseString(entry.propertyStatus, `${field}.propertyStatus`);
  const conflictArtifacts = parseConflictArtifacts(entry.conflictArtifacts, `${field}.conflictArtifacts`, path);
  if (
    conflictArtifacts.length > 0 &&
    (source !== "local" || !hasConflict(conflict, localStatus, nodeStatus, textStatus, propertyStatus))
  ) {
    throw invalidRefreshResponse(`${field}.conflictArtifacts`);
  }
  return {
    path,
    kind: requireResponseString(entry.kind, `${field}.kind`),
    nodeStatus,
    textStatus,
    propertyStatus,
    localStatus,
    remoteStatus: requireResponseString(entry.remoteStatus, `${field}.remoteStatus`),
    revision: requireInteger(entry.revision, `${field}.revision`),
    changedRevision: requireInteger(entry.changedRevision, `${field}.changedRevision`),
    changedAuthor: requireNullableString(entry.changedAuthor, `${field}.changedAuthor`),
    changedDate: requireNullableString(entry.changedDate, `${field}.changedDate`),
    changelist: requireNullableString(entry.changelist, `${field}.changelist`),
    lock: parseLockInfo(entry.lock, `${field}.lock`),
    needsLock: requireBoolean(entry.needsLock, `${field}.needsLock`),
    copy: requireNullableString(entry.copy, `${field}.copy`),
    move: requireNullableString(entry.move, `${field}.move`),
    switched: requireBoolean(entry.switched, `${field}.switched`),
    depth: requireResponseString(entry.depth, `${field}.depth`),
    conflict,
    conflictArtifacts,
    external: requireBoolean(entry.external, `${field}.external`),
    generation,
  };
}

function parseConflictArtifacts(rawArtifacts: unknown, field: string, entryPath: string): string[] {
  if (!Array.isArray(rawArtifacts) || rawArtifacts.length > MAX_CONFLICT_ARTIFACTS_PER_ENTRY) {
    throw invalidRefreshResponse(field);
  }
  const seen = new Set<string>();
  const entryPathKey = canonicalStatusPathKey(entryPath);
  let previous: string | undefined;
  return rawArtifacts.map((artifact, index) => {
    const path = requireResponsePath(artifact, `${field}.${index}`);
    const pathKey = canonicalStatusPathKey(path);
    if (
      path === "." ||
      pathKey === entryPathKey ||
      hasWorkingCopyAdminComponent(path) ||
      seen.has(pathKey) ||
      (previous !== undefined && compareUtf8(previous, path) >= 0)
    ) {
      throw invalidRefreshResponse(`${field}.${index}`);
    }
    seen.add(pathKey);
    previous = path;
    return path;
  });
}

function hasWorkingCopyAdminComponent(path: string): boolean {
  return path.split("/").some((component) => component.toLowerCase() === ".svn");
}

function compareUtf8(left: string, right: string): number {
  return Buffer.compare(Buffer.from(left, "utf8"), Buffer.from(right, "utf8"));
}

function requireNoConflictArtifactEntries(entries: StatusEntry[], field: string): void {
  const artifactPaths = new Set(
    entries.flatMap((entry) => entry.conflictArtifacts).map(canonicalStatusPathKey),
  );
  entries.forEach((entry, index) => {
    if (artifactPaths.has(canonicalStatusPathKey(entry.path))) {
      throw invalidRefreshResponse(`${field}.${index}.path`);
    }
  });
}

function canonicalStatusPathKey(path: string): string {
  return process.platform === "win32" ? path.replace(/[A-Z]/g, (character) => character.toLowerCase()) : path;
}

function hasConflict(
  conflict: string | null,
  localStatus: string,
  nodeStatus: string,
  textStatus: string,
  propertyStatus: string,
): boolean {
  return (
    conflict !== null ||
    localStatus === "conflicted" ||
    nodeStatus === "conflicted" ||
    textStatus === "conflicted" ||
    propertyStatus === "conflicted"
  );
}

function parseLockInfo(rawLock: unknown, field: string): StatusEntry["lock"] {
  if (rawLock === null) {
    return null;
  }
  const lock = requireResponseRecord(rawLock, field);
  requireExactResponseKeys(lock, field, [
    "token",
    "owner",
    "comment",
    "createdDate",
    "expiresDate",
    "isRemote",
  ]);
  return {
    token: requireNullableString(lock.token, `${field}.token`),
    owner: requireNullableString(lock.owner, `${field}.owner`),
    comment: requireNullableString(lock.comment, `${field}.comment`),
    createdDate: requireNullableString(lock.createdDate, `${field}.createdDate`),
    expiresDate: requireNullableString(lock.expiresDate, `${field}.expiresDate`),
    isRemote: requireBoolean(lock.isRemote, `${field}.isRemote`),
  };
}

function parseRemovedPaths(rawPaths: unknown, field: string): string[] {
  if (!Array.isArray(rawPaths)) {
    throw invalidRefreshResponse(field);
  }
  return rawPaths.map((path, index) => requireResponsePath(path, `${field}.${index}`));
}

function parseSummaryDelta(rawSummary: unknown, field: string): StatusSummaryDelta {
  const summary = requireResponseRecord(rawSummary, field);
  requireExactResponseKeys(summary, field, ["localChanges", "remoteChanges", "conflicts", "unversioned"]);
  return {
    localChanges: requireInteger(summary.localChanges, `${field}.localChanges`),
    remoteChanges: requireInteger(summary.remoteChanges, `${field}.remoteChanges`),
    conflicts: requireInteger(summary.conflicts, `${field}.conflicts`),
    unversioned: requireInteger(summary.unversioned, `${field}.unversioned`),
  };
}

function requireUniqueEntryPaths(entries: StatusEntry[], field: string): void {
  const seen = new Set<string>();
  entries.forEach((entry, index) => {
    if (seen.has(entry.path)) {
      throw invalidRefreshResponse(`${field}.${index}.path`);
    }
    seen.add(entry.path);
  });
}

function requireUniquePaths(paths: string[], field: string): void {
  const seen = new Set<string>();
  paths.forEach((path, index) => {
    if (seen.has(path)) {
      throw invalidRefreshResponse(`${field}.${index}`);
    }
    seen.add(path);
  });
}

function requireNoDeltaPathOverlap(upsert: StatusEntry[], remove: string[], removeField = "remove"): void {
  const upsertPaths = new Set(upsert.map((entry) => entry.path));
  remove.forEach((path, index) => {
    if (upsertPaths.has(path)) {
      throw invalidRefreshResponse(`${removeField}.${index}`);
    }
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function isNonNegativeSafeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function requireRequestRecord(value: unknown, field: string): Record<string, unknown> {
  if (!isRecord(value)) {
    throw invalidRefreshRequest(field);
  }
  return value;
}

function requireResponseRecord(value: unknown, field: string): Record<string, unknown> {
  if (!isRecord(value)) {
    throw invalidRefreshResponse(field);
  }
  return value;
}

function requireExactRequestKeys(value: Record<string, unknown>, field: string, expectedKeys: readonly string[]): void {
  const expected = new Set(expectedKeys);
  for (const key of Object.keys(value)) {
    if (!expected.has(key)) {
      throw invalidRefreshRequest(field === "request" ? key : `${field}.${key}`);
    }
  }
}

function requireExactResponseKeys(value: Record<string, unknown>, field: string, expectedKeys: readonly string[]): void {
  const expected = new Set(expectedKeys);
  for (const key of Object.keys(value)) {
    if (!expected.has(key)) {
      throw invalidRefreshResponse(field === "result" ? key : `${field}.${key}`);
    }
  }
}

function requireRequestString(value: unknown, field: string): string {
  if (!isNonEmptyString(value)) {
    throw invalidRefreshRequest(field);
  }
  return value;
}

function requireRequestPath(value: unknown, field: string): string {
  const path = requireRequestString(value, field);
  if (!isRepositoryRelativePath(path)) {
    throw invalidRefreshRequest(field);
  }
  return path;
}

function requireRefreshDepth(value: unknown, field: string): StatusRefreshDepth {
  const depth = requireRequestString(value, field);
  if (depth !== "empty" && depth !== "files" && depth !== "immediates" && depth !== "infinity") {
    throw invalidRefreshRequest(field);
  }
  return depth;
}

function isRepositoryRelativePath(path: string): boolean {
  if (path === ".") {
    return true;
  }
  const normalized = path.replace(/\\/g, "/");
  if (normalized.startsWith("/") || normalized.includes(":") || normalized.includes("\0")) {
    return false;
  }
  return normalized.split("/").every((part) => part.length > 0 && part !== "." && part !== "..");
}

function requireResponseString(value: unknown, field: string): string {
  if (!isNonEmptyString(value)) {
    throw invalidRefreshResponse(field);
  }
  return value;
}

function requireResponsePath(value: unknown, field: string): string {
  const path = requireResponseString(value, field);
  if (!isRepositoryRelativePath(path)) {
    throw invalidRefreshResponse(field);
  }
  return path;
}

function requireNullableString(value: unknown, field: string): string | null {
  if (value === null) {
    return null;
  }
  if (!isNonEmptyString(value)) {
    throw invalidRefreshResponse(field);
  }
  return value;
}

function requireCompleteness(value: unknown, field: string): StatusSnapshotCompleteness {
  const completeness = requireResponseString(value, field);
  if (completeness !== "complete" && completeness !== "partial" && completeness !== "stale") {
    throw invalidRefreshResponse(field);
  }
  return completeness;
}

function requireInteger(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value)) {
    throw invalidRefreshResponse(field);
  }
  return value;
}

function requireNonNegativeInteger(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw invalidRefreshResponse(field);
  }
  return value;
}

function requireBoolean(value: unknown, field: string): boolean {
  if (typeof value !== "boolean") {
    throw invalidRefreshResponse(field);
  }
  return value;
}

function invalidRefreshRequest(field: string): StatusRefreshResponseError {
  return new StatusRefreshResponseError(
    "SUBVERSIONR_STATUS_REFRESH_REQUEST_INVALID",
    "input",
    "error.status.refreshRequestInvalid",
    { field },
  );
}

function invalidRefreshResponse(field: string): StatusRefreshResponseError {
  return new StatusRefreshResponseError(
    "SUBVERSIONR_STATUS_REFRESH_RESPONSE_INVALID",
    "protocol",
    "error.status.refreshResponseInvalid",
    { field },
  );
}

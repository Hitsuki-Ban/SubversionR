import type { JsonRpcSender } from "./types";

export type StatusSnapshotErrorCategory = "input" | "protocol";

export interface StatusSnapshotRequest {
  repositoryId: string;
  epoch: number;
}

export type StatusSnapshotCompleteness = "complete" | "partial" | "stale";

export const MAX_CONFLICT_ARTIFACTS_PER_ENTRY = 4;

export interface RepositoryIdentity {
  repositoryUuid: string;
  repositoryRootUrl: string;
  workingCopyRoot: string;
  workspaceScopeRoot: string;
  format: number;
}

export interface StatusEntry {
  path: string;
  kind: string;
  nodeStatus: string;
  textStatus: string;
  propertyStatus: string;
  localStatus: string;
  remoteStatus: string;
  revision: number;
  changedRevision: number;
  changedAuthor: string | null;
  changedDate: string | null;
  changelist: string | null;
  lock: LockInfo | null;
  needsLock: boolean;
  copy: string | null;
  move: string | null;
  switched: boolean;
  depth: string;
  conflict: string | null;
  conflictArtifacts: string[];
  external: boolean;
  generation: number;
}

export interface LockInfo {
  token: string | null;
  owner: string | null;
  comment: string | null;
  createdDate: string | null;
  expiresDate: string | null;
  isRemote: boolean;
}

export interface StatusSummary {
  localChanges: number;
  remoteChanges: number;
  conflicts: number;
  unversioned: number;
}

export interface StatusSnapshot {
  repositoryId: string;
  epoch: number;
  generation: number;
  completeness: StatusSnapshotCompleteness;
  identity: RepositoryIdentity;
  localEntries: StatusEntry[];
  remoteEntries: StatusEntry[];
  summary: StatusSummary;
  timestamp: string;
  source: string;
}

export class StatusSnapshotResponseError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: StatusSnapshotErrorCategory,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "StatusSnapshotResponseError";
  }
}

export class StatusSnapshotRpcClient {
  public constructor(private readonly sender: JsonRpcSender) {}

  public async getSnapshot(request: StatusSnapshotRequest): Promise<StatusSnapshot> {
    const validatedRequest = validateSnapshotRequest(request);
    const rawResponse = await this.sender.sendRequest<unknown>("status/getSnapshot", validatedRequest);
    const snapshot = parseStatusSnapshot(rawResponse);
    requireSnapshotMatchesRequest(snapshot, validatedRequest);
    return snapshot;
  }
}

function validateSnapshotRequest(request: StatusSnapshotRequest): StatusSnapshotRequest {
  if (!isRecord(request) || typeof request.repositoryId !== "string" || request.repositoryId.trim().length === 0) {
    throw invalidSnapshotRequest("repositoryId");
  }
  if (typeof request.epoch !== "number" || !Number.isSafeInteger(request.epoch) || request.epoch < 0) {
    throw invalidSnapshotRequest("epoch");
  }
  return {
    repositoryId: request.repositoryId,
    epoch: request.epoch,
  };
}

function parseStatusSnapshot(rawResponse: unknown): StatusSnapshot {
  const response = requireRecord(rawResponse, "result");
  requireExactKeys(response, "result", [
    "repositoryId",
    "epoch",
    "generation",
    "completeness",
    "identity",
    "localEntries",
    "remoteEntries",
    "summary",
    "timestamp",
    "source",
  ]);
  const generation = requireSafeInteger(response.generation, "generation");
  return {
    repositoryId: requireString(response.repositoryId, "repositoryId"),
    epoch: requireSafeInteger(response.epoch, "epoch"),
    generation,
    completeness: requireCompleteness(response.completeness, "completeness"),
    identity: parseRepositoryIdentity(response.identity, "identity"),
    localEntries: parseStatusEntries(response.localEntries, "localEntries", generation, "local"),
    remoteEntries: parseStatusEntries(response.remoteEntries, "remoteEntries", generation, "remote"),
    summary: parseStatusSummary(response.summary, "summary"),
    timestamp: requireString(response.timestamp, "timestamp"),
    source: requireString(response.source, "source"),
  };
}

function requireSnapshotMatchesRequest(snapshot: StatusSnapshot, request: StatusSnapshotRequest): void {
  if (snapshot.repositoryId !== request.repositoryId) {
    throw invalidSnapshotResponse("repositoryId");
  }
  if (snapshot.epoch !== request.epoch) {
    throw invalidSnapshotResponse("epoch");
  }
}

function parseRepositoryIdentity(rawIdentity: unknown, field: string): RepositoryIdentity {
  const identity = requireRecord(rawIdentity, field);
  requireExactKeys(identity, field, [
    "repositoryUuid",
    "repositoryRootUrl",
    "workingCopyRoot",
    "workspaceScopeRoot",
    "format",
  ]);
  return {
    repositoryUuid: requireString(identity.repositoryUuid, `${field}.repositoryUuid`),
    repositoryRootUrl: requireString(identity.repositoryRootUrl, `${field}.repositoryRootUrl`),
    workingCopyRoot: requireString(identity.workingCopyRoot, `${field}.workingCopyRoot`),
    workspaceScopeRoot: requireString(identity.workspaceScopeRoot, `${field}.workspaceScopeRoot`),
    format: requireSafeInteger(identity.format, `${field}.format`),
  };
}

function parseStatusEntries(
  rawEntries: unknown,
  field: string,
  generation: number,
  source: "local" | "remote",
): StatusEntry[] {
  if (!Array.isArray(rawEntries)) {
    throw invalidSnapshotResponse(field);
  }
  const entries = rawEntries.map((entry, index) => parseStatusEntry(entry, `${field}.${index}`, generation, source));
  if (source === "local") {
    requireNoConflictArtifactEntries(entries, field);
  }
  return entries;
}

function parseStatusEntry(
  rawEntry: unknown,
  field: string,
  snapshotGeneration: number,
  source: "local" | "remote",
): StatusEntry {
  const entry = requireRecord(rawEntry, field);
  requireExactKeys(entry, field, [
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
  const generation = requireSafeInteger(entry.generation, `${field}.generation`);
  if (generation !== snapshotGeneration) {
    throw invalidSnapshotResponse(`${field}.generation`);
  }
  const path = requireRepositoryRelativePath(entry.path, `${field}.path`);
  const conflict = requireNullableString(entry.conflict, `${field}.conflict`);
  const localStatus = requireString(entry.localStatus, `${field}.localStatus`);
  const nodeStatus = requireString(entry.nodeStatus, `${field}.nodeStatus`);
  const textStatus = requireString(entry.textStatus, `${field}.textStatus`);
  const propertyStatus = requireString(entry.propertyStatus, `${field}.propertyStatus`);
  const conflictArtifacts = parseConflictArtifacts(entry.conflictArtifacts, `${field}.conflictArtifacts`, path);
  if (
    conflictArtifacts.length > 0 &&
    (source !== "local" || !hasConflict(conflict, localStatus, nodeStatus, textStatus, propertyStatus))
  ) {
    throw invalidSnapshotResponse(`${field}.conflictArtifacts`);
  }
  return {
    path,
    kind: requireString(entry.kind, `${field}.kind`),
    nodeStatus,
    textStatus,
    propertyStatus,
    localStatus,
    remoteStatus: requireString(entry.remoteStatus, `${field}.remoteStatus`),
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
    depth: requireString(entry.depth, `${field}.depth`),
    conflict,
    conflictArtifacts,
    external: requireBoolean(entry.external, `${field}.external`),
    generation,
  };
}

function parseConflictArtifacts(rawArtifacts: unknown, field: string, entryPath: string): string[] {
  if (!Array.isArray(rawArtifacts) || rawArtifacts.length > MAX_CONFLICT_ARTIFACTS_PER_ENTRY) {
    throw invalidSnapshotResponse(field);
  }
  const seen = new Set<string>();
  const entryPathKey = canonicalStatusPathKey(entryPath);
  let previous: string | undefined;
  return rawArtifacts.map((artifact, index) => {
    const path = requireRepositoryRelativePath(artifact, `${field}.${index}`);
    const pathKey = canonicalStatusPathKey(path);
    if (
      path === "." ||
      pathKey === entryPathKey ||
      hasWorkingCopyAdminComponent(path) ||
      seen.has(pathKey) ||
      (previous !== undefined && compareUtf8(previous, path) >= 0)
    ) {
      throw invalidSnapshotResponse(`${field}.${index}`);
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
      throw invalidSnapshotResponse(`${field}.${index}.path`);
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

function parseLockInfo(rawLock: unknown, field: string): LockInfo | null {
  if (rawLock === null) {
    return null;
  }
  const lock = requireRecord(rawLock, field);
  requireExactKeys(lock, field, [
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

function parseStatusSummary(rawSummary: unknown, field: string): StatusSummary {
  const summary = requireRecord(rawSummary, field);
  requireExactKeys(summary, field, ["localChanges", "remoteChanges", "conflicts", "unversioned"]);
  return {
    localChanges: requireSafeInteger(summary.localChanges, `${field}.localChanges`),
    remoteChanges: requireSafeInteger(summary.remoteChanges, `${field}.remoteChanges`),
    conflicts: requireSafeInteger(summary.conflicts, `${field}.conflicts`),
    unversioned: requireSafeInteger(summary.unversioned, `${field}.unversioned`),
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function requireRecord(value: unknown, field: string): Record<string, unknown> {
  if (!isRecord(value)) {
    throw invalidSnapshotResponse(field);
  }
  return value;
}

function requireExactKeys(value: Record<string, unknown>, field: string, expectedKeys: readonly string[]): void {
  const expected = new Set(expectedKeys);
  for (const key of Object.keys(value)) {
    if (!expected.has(key)) {
      throw invalidSnapshotResponse(field === "result" ? key : `${field}.${key}`);
    }
  }
}

function requireString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw invalidSnapshotResponse(field);
  }
  return value;
}

function requireRepositoryRelativePath(value: unknown, field: string): string {
  const path = requireString(value, field);
  if (!isRepositoryRelativePath(path)) {
    throw invalidSnapshotResponse(field);
  }
  return path;
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

function requireNullableString(value: unknown, field: string): string | null {
  if (value === null) {
    return null;
  }
  if (typeof value !== "string" || value.trim().length === 0) {
    throw invalidSnapshotResponse(field);
  }
  return value;
}

function requireCompleteness(value: unknown, field: string): StatusSnapshotCompleteness {
  const completeness = requireString(value, field);
  if (completeness !== "complete" && completeness !== "partial" && completeness !== "stale") {
    throw invalidSnapshotResponse(field);
  }
  return completeness;
}

function requireInteger(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value)) {
    throw invalidSnapshotResponse(field);
  }
  return value;
}

function requireSafeInteger(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw invalidSnapshotResponse(field);
  }
  return value;
}

function requireBoolean(value: unknown, field: string): boolean {
  if (typeof value !== "boolean") {
    throw invalidSnapshotResponse(field);
  }
  return value;
}

function invalidSnapshotRequest(field: string): StatusSnapshotResponseError {
  return new StatusSnapshotResponseError(
    "SUBVERSIONR_STATUS_SNAPSHOT_REQUEST_INVALID",
    "input",
    "error.status.snapshotRequestInvalid",
    { field },
  );
}

function invalidSnapshotResponse(field: string): StatusSnapshotResponseError {
  return new StatusSnapshotResponseError(
    "SUBVERSIONR_STATUS_SNAPSHOT_RESPONSE_INVALID",
    "protocol",
    "error.status.snapshotResponseInvalid",
    { field },
  );
}

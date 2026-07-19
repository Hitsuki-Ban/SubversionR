import type { StatusDelta } from "./statusRefreshRpcClient";

export type PathCasePolicy = "case-sensitive" | "case-insensitive";

export type FileEventKind = "create" | "change" | "delete" | "rename" | "metadata";

export type RawWatcherEventKind = "created" | "changed" | "deleted";

export type StatusRefreshDepth = "empty" | "files" | "immediates" | "infinity";

export interface RepositoryWatchScope {
  repositoryId: string;
  epoch: number;
  workingCopyRoot: string;
  pathCase: PathCasePolicy;
  boundaryRoots?: string[];
}

export interface DirtyFileEvent {
  path: string;
  kind: FileEventKind;
  timestamp: number;
}

export interface RawWatcherEvent {
  fsPath: string;
  kind: RawWatcherEventKind;
  timestamp: number;
}

export interface StatusRefreshTarget {
  path: string;
  depth: StatusRefreshDepth;
  reason: string;
}

export interface StatusRefreshRequest {
  repositoryId: string;
  epoch: number;
  targets: StatusRefreshTarget[];
}

export interface StatusRefreshClientOptions {
  signal?: AbortSignal;
  retainCancelledWireSettlementForEvidence?: true;
}

export interface StatusRefreshClient {
  refreshStatus(request: StatusRefreshRequest, options?: StatusRefreshClientOptions): Promise<StatusDelta>;
}

export interface JsonRpcSender {
  sendRequest<T>(method: string, params: unknown, options?: JsonRpcRequestOptions): Promise<T>;
}

export interface JsonRpcRequestOptions {
  signal?: AbortSignal;
  retainCancelledWireSettlementForEvidence?: true;
}

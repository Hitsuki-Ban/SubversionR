import type { SourceControlProjectionService } from "../scm/sourceControlProjectionService";
import type { RemoteConnectionStateStore } from "./remoteConnectionStateStore";

export type DaemonRemoteConnectionState =
  | { kind: "unchecked" }
  | { kind: "checking"; operationId: string; startedAt: string }
  | { kind: "online"; transport: "http" | "https" | "svn" | "svn+ssh"; checkedAt: string }
  | { kind: "attention"; reason: "authRequired" | "certificateRequired" | "hostKeyRequired" | "configurationInvalid" | "unsupportedCapability" }
  | { kind: "unreachable"; reason: "dns" | "refused" | "proxy" | "timeout" | "tunnel" }
  | {
      kind: "indeterminate";
      reason: "cancelledAfterMutation" | "workerTerminated";
      originOperationId: string;
      recovery: "notRequired" | "pending" | "blocked";
      cleanupAppropriate: boolean;
    };

export interface RemoteConnectionNotification {
  repositoryId: string;
  epoch: number;
  state: DaemonRemoteConnectionState;
}

export function createRemoteConnectionNotificationHandler(options: {
  store: Pick<RemoteConnectionStateStore, "applyDaemonState" | "getState">;
  projection: Pick<SourceControlProjectionService, "updateRemoteConnectionState">;
  now(): string;
  scheduleRecovery(target: { repositoryId: string; epoch: number }): Promise<unknown>;
  recordBackgroundRecoveryFailure(error: unknown): void;
}): (method: string, params: unknown) => boolean {
  return (method, params) => {
    if (method !== "remoteConnection/state") return false;
    const notification = parseRemoteConnectionStateNotification(params);
    const previous = options.store.getState(notification.repositoryId);
    const applied = options.store.applyDaemonState({ ...notification, receivedAt: options.now() });
    if (applied.applied) {
      options.projection.updateRemoteConnectionState(applied.state);
      if (
        notification.state.kind === "indeterminate" && notification.state.recovery === "pending" &&
        previous?.recovery.kind !== "checking"
      ) {
        void options.scheduleRecovery({ repositoryId: notification.repositoryId, epoch: notification.epoch })
          .catch((error: unknown) => options.recordBackgroundRecoveryFailure(error));
      }
    }
    return true;
  };
}

export function parseRemoteConnectionStateNotification(params: unknown): RemoteConnectionNotification {
  const value = record(params, "params");
  exact(value, ["repositoryId", "epoch", "state"], "params");
  if (typeof value.repositoryId !== "string" || value.repositoryId.trim().length === 0) invalid("repositoryId");
  if (!Number.isSafeInteger(value.epoch) || (value.epoch as number) < 0) invalid("epoch");
  return {
    repositoryId: value.repositoryId as string,
    epoch: value.epoch as number,
    state: parseState(value.state),
  };
}

function parseState(raw: unknown): DaemonRemoteConnectionState {
  const state = record(raw, "state");
  if (state.kind === "unchecked") {
    exact(state, ["kind"], "state");
    return { kind: "unchecked" };
  }
  if (state.kind === "checking") {
    exact(state, ["kind", "operationId", "startedAt"], "state");
    return { kind: "checking", operationId: uuid(state.operationId, "operationId"), startedAt: timestamp(state.startedAt, "startedAt") };
  }
  if (state.kind === "online") {
    exact(state, ["kind", "transport", "checkedAt"], "state");
    return { kind: "online", transport: enumValue(state.transport, ["http", "https", "svn", "svn+ssh"], "transport"), checkedAt: timestamp(state.checkedAt, "checkedAt") };
  }
  if (state.kind === "attention") {
    exact(state, ["kind", "reason"], "state");
    return { kind: "attention", reason: enumValue(state.reason, ["authRequired", "certificateRequired", "hostKeyRequired", "configurationInvalid", "unsupportedCapability"], "reason") };
  }
  if (state.kind === "unreachable") {
    exact(state, ["kind", "reason"], "state");
    return { kind: "unreachable", reason: enumValue(state.reason, ["dns", "refused", "proxy", "timeout", "tunnel"], "reason") };
  }
  if (state.kind === "indeterminate") {
    exact(state, ["kind", "reason", "originOperationId", "recovery", "cleanupAppropriate"], "state");
    if (typeof state.cleanupAppropriate !== "boolean") invalid("cleanupAppropriate");
    return {
      kind: "indeterminate",
      reason: enumValue(state.reason, ["cancelledAfterMutation", "workerTerminated"], "reason"),
      originOperationId: uuid(state.originOperationId, "originOperationId"),
      recovery: enumValue(state.recovery, ["notRequired", "pending", "blocked"], "recovery"),
      cleanupAppropriate: state.cleanupAppropriate as boolean,
    };
  }
  return invalid("kind");
}

export class RemoteConnectionNotificationError extends Error {
  public readonly code = "SUBVERSIONR_REMOTE_CONNECTION_NOTIFICATION_INVALID";
  public readonly category = "protocol";
  public readonly messageKey = "error.remote.connectionNotificationInvalid";
  public constructor(public readonly safeArgs: Readonly<Record<string, unknown>>) {
    super("SUBVERSIONR_REMOTE_CONNECTION_NOTIFICATION_INVALID");
    this.name = "RemoteConnectionNotificationError";
  }
}

function invalid(field: string): never { throw new RemoteConnectionNotificationError({ field }); }
function record(value: unknown, field: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return invalid(field);
  return value as Record<string, unknown>;
}
function exact(value: Record<string, unknown>, keys: string[], field: string): void {
  if (Object.keys(value).sort().join(",") !== [...keys].sort().join(",")) invalid(field);
}
function enumValue<const T extends readonly string[]>(value: unknown, allowed: T, field: string): T[number] {
  if (typeof value !== "string" || !allowed.includes(value)) return invalid(field);
  return value as T[number];
}
function uuid(value: unknown, field: string): string {
  if (typeof value !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value)) return invalid(field);
  return value;
}
function timestamp(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length > 64 || Number.isNaN(Date.parse(value))) return invalid(field);
  return value;
}

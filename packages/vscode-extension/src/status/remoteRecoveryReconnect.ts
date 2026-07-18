import type { RepositorySessionService } from "../repository/repositorySessionService";
import type { RemoteConnectionStateStore } from "./remoteConnectionStateStore";
import type { RemoteRecoveryService } from "./remoteRecoveryService";

export async function redriveRequiredRemoteRecoveries(options: {
  sessions: Pick<RepositorySessionService, "listOpenSessions">;
  store: Pick<RemoteConnectionStateStore, "getState">;
  recovery: Pick<RemoteRecoveryService, "recover">;
  recordFailure(error: unknown): void;
}): Promise<void> {
  const pending = options.sessions.listOpenSessions().filter((session) => {
    const state = options.store.getState(session.repositoryId);
    return state?.epoch === session.epoch && state.kind === "indeterminate" && state.recovery.kind === "required";
  });
  await Promise.all(pending.map(async (session) => {
    try {
      await options.recovery.recover({ repositoryId: session.repositoryId, epoch: session.epoch });
    } catch (error) {
      options.recordFailure(error);
    }
  }));
}

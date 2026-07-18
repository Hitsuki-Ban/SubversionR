import type { SourceControlProjectionService } from "../scm/sourceControlProjectionService";
import type { DirtyPathPipeline } from "./dirtyPathPipeline";
import type { StatusSnapshotStore } from "./statusSnapshotStore";
import type { StatusRemoteCheckClient, StatusRemoteCheckRequest } from "./statusRemoteCheckRpcClient";
import type { StatusRefreshClientOptions } from "./types";
import type { RemoteOperationEnvelope } from "../security/remoteAccessProfile";
import { RemoteProfileConfigurationError } from "../security/remoteAccessProfile";
import {
  type NativeRemoteFailure,
  type RemoteConnectionStateStore,
  parseWireRemoteFailure,
} from "./remoteConnectionStateStore";

export interface RemoteStatusCheckServiceOptions {
  client: StatusRemoteCheckClient;
  statusSnapshotStore: Pick<StatusSnapshotStore, "applyDelta">;
  sourceControlProjection: Pick<SourceControlProjectionService, "applyDelta" | "replaceSnapshot">;
  remoteStateProjection: Pick<SourceControlProjectionService, "updateRemoteConnectionState">;
  refreshPipeline: Pick<DirtyPathPipeline, "runExclusive">;
  remoteConnectionStateStore: Pick<RemoteConnectionStateStore, "beginCheck" | "completeFailure" | "completeOnline">;
  now(): string;
  createOperationId(): string;
  createRemoteEnvelope(input: {
    operationId: string;
    repositoryRootUrl: string;
  }): Promise<RemoteOperationEnvelope>;
}

export interface RemoteStatusCheckTarget {
  repositoryId: string;
  epoch: number;
  repositoryRootUrl: string;
}

export class RemoteStatusCheckService {
  public constructor(private readonly options: RemoteStatusCheckServiceOptions) {}

  public async checkRemoteChanges(
    target: RemoteStatusCheckTarget,
    clientOptions: StatusRefreshClientOptions = {},
  ): Promise<number> {
    const operationId = this.options.createOperationId();
    const checking = this.options.remoteConnectionStateStore.beginCheck({
      repositoryId: target.repositoryId,
      epoch: target.epoch,
      operationId,
      startedAt: this.options.now(),
    });
    this.options.remoteStateProjection.updateRemoteConnectionState(checking);
    let remote: RemoteOperationEnvelope;
    try {
      remote = await this.options.createRemoteEnvelope({ operationId, repositoryRootUrl: target.repositoryRootUrl });
    } catch (error) {
      this.completeFailure(target, operationId, error);
      throw error;
    }
    const request: StatusRemoteCheckRequest = {
      repositoryId: target.repositoryId,
      epoch: target.epoch,
      remote,
    };
    let delta;
    try {
      delta = await this.options.client.checkRemoteStatus(request, clientOptions);
    } catch (error) {
      this.completeFailure(target, operationId, error);
      throw error;
    }
    return await this.options.refreshPipeline.runExclusive(request.repositoryId, async () => {
      let snapshot;
      try {
        snapshot = this.options.statusSnapshotStore.applyDelta(delta);
      } catch (error) {
        this.completeOnline(request, false);
        throw error;
      }
      try {
        this.options.sourceControlProjection.applyDelta(delta);
      } catch (error) {
        try {
          this.options.sourceControlProjection.replaceSnapshot(snapshot);
        } catch (replacementError) {
          this.completeOnline(request, false);
          throw new AggregateError(
            [error, replacementError],
            "SUBVERSIONR_REMOTE_STATUS_PROJECTION_REBUILD_FAILED",
          );
        }
        this.completeOnline(request, true);
        throw error;
      }
      this.completeOnline(request, true);
      return snapshot.summary.remoteChanges;
    });
  }

  private completeOnline(request: StatusRemoteCheckRequest, incomingApplied: boolean): void {
    const completed = this.options.remoteConnectionStateStore.completeOnline({
      repositoryId: request.repositoryId,
      epoch: request.epoch,
      operationId: request.remote.operationId,
      transport: request.remote.profile.authority.scheme,
      checkedAt: this.options.now(),
      incomingApplied,
    });
    if (completed.applied) {
      this.options.remoteStateProjection.updateRemoteConnectionState(completed.state);
    }
  }

  private completeFailure(target: RemoteStatusCheckTarget, operationId: string, error: unknown): void {
    const completed = this.options.remoteConnectionStateStore.completeFailure({
      repositoryId: target.repositoryId,
      epoch: target.epoch,
      operationId,
      failedAt: this.options.now(),
      failure: remoteFailureFromError(error),
      workingCopyRecoveryRequired: false,
    });
    if (completed.applied) {
      this.options.remoteStateProjection.updateRemoteConnectionState(completed.state);
    }
  }
}

export function remoteFailureFromError(error: unknown): NativeRemoteFailure {
  if (error instanceof RemoteProfileConfigurationError) {
    return {
      category: "attention",
      reason: LOCAL_UNSUPPORTED_REMOTE_CODES.has(error.code)
        ? "remoteCapabilityUnsupported"
        : "remoteConfigurationInvalid",
      cleanupAppropriate: false,
    };
  }
  if (!isRecord(error) || !isRecord(error.safeArgs) || !("remoteFailure" in error.safeArgs)) {
    return { category: "attention", reason: "unknownRemote", cleanupAppropriate: false };
  }
  const value = error.safeArgs.remoteFailure;
  try {
    return parseWireRemoteFailure(value);
  } catch {
    return { category: "attention", reason: "unknownRemote", cleanupAppropriate: false };
  }
}

const LOCAL_UNSUPPORTED_REMOTE_CODES = new Set([
  "SUBVERSIONR_REMOTE_PROXY_UNSUPPORTED",
  "SUBVERSIONR_REMOTE_SSH_PROFILE_UNSUPPORTED",
  "SUBVERSIONR_REMOTE_REDIRECT_POLICY_UNSUPPORTED",
  "SUBVERSIONR_REMOTE_TLS_POLICY_UNSUPPORTED",
  "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED",
  "SUBVERSIONR_REMOTE_SCHEME_UNSUPPORTED",
]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

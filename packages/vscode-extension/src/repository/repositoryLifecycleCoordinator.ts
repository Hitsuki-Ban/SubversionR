import type {
  RepositoryAutoOpenTrigger,
  RepositoryLifecycleEvent,
  RepositoryLifecycleService,
} from "./repositoryLifecycleService";
import type { RepositorySessionService } from "./repositorySessionService";

export type RepositoryLifecycleCoordinatorReason =
  | RepositoryAutoOpenTrigger
  | "backendRestart"
  | "manualOpen"
  | "manualCheckout"
  | "manualClose";

export interface RepositoryLifecycleCoordinatorOptions {
  lifecycleService: Pick<
    RepositoryLifecycleService,
    | "recoverMovedRepositories"
    | "closeDisappearedRepositories"
    | "autoOpenWorkspaceRepositories"
    | "reopenBackendRestartedRepositories"
  >;
  sessionService: Pick<RepositorySessionService, "markOpenSessionsStale">;
  now(): string;
  onBackendRestartStaleFailure(error: unknown): Promise<void> | void;
}

export class RepositoryLifecycleCoordinator {
  private tail: Promise<void> = Promise.resolve();

  public constructor(private readonly options: RepositoryLifecycleCoordinatorOptions) {}

  public async reconcileWorkspaceRepositories(
    trigger: RepositoryAutoOpenTrigger,
  ): Promise<RepositoryLifecycleEvent[]> {
    return await this.runExclusive(trigger, async () => {
      const movedRecoveryEvents = await this.options.lifecycleService.recoverMovedRepositories(trigger);
      const disappearedCleanupEvents = await this.options.lifecycleService.closeDisappearedRepositories(trigger);
      const automaticOpenEvent = await this.options.lifecycleService.autoOpenWorkspaceRepositories(trigger);
      return [...movedRecoveryEvents, ...disappearedCleanupEvents, automaticOpenEvent];
    });
  }

  public async recoverBackendRestartedRepositories(): Promise<RepositoryLifecycleEvent[]> {
    return await this.runExclusive("backendRestart", async () => {
      try {
        this.options.sessionService.markOpenSessionsStale({
          reason: "backendConnectionLost",
          timestamp: this.options.now(),
          source: "backend-lifecycle",
        });
      } catch (error) {
        await this.options.onBackendRestartStaleFailure(error);
        return [];
      }
      return await this.options.lifecycleService.reopenBackendRestartedRepositories();
    });
  }

  public async runExclusive<T>(
    _reason: RepositoryLifecycleCoordinatorReason,
    task: () => Promise<T>,
  ): Promise<T> {
    const previous = this.tail;
    let release!: () => void;
    this.tail = new Promise<void>((resolve) => {
      release = resolve;
    });
    await previous.catch(() => undefined);
    try {
      return await task();
    } finally {
      release();
    }
  }
}

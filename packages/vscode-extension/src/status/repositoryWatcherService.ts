import type { DirtyPathPipeline } from "./dirtyPathPipeline";
import type { RawWatcherEventKind, RepositoryWatchScope } from "./types";

const REPOSITORY_WATCH_PATTERN = "**/*";

export interface DisposableLike {
  dispose(): void;
}

export interface WatcherUriLike {
  fsPath: string;
}

export interface RepositoryFileWatcher extends DisposableLike {
  onDidChange(listener: (uri: WatcherUriLike) => void): DisposableLike;
  onDidCreate(listener: (uri: WatcherUriLike) => void): DisposableLike;
  onDidDelete(listener: (uri: WatcherUriLike) => void): DisposableLike;
}

export interface RepositoryWatcherRequest {
  repositoryId: string;
  basePath: string;
  pattern: string;
  ignoreCreateEvents: boolean;
  ignoreChangeEvents: boolean;
  ignoreDeleteEvents: boolean;
}

export type RepositoryWatcherFactory = (request: RepositoryWatcherRequest) => RepositoryFileWatcher;

export interface RepositoryWatcherServiceOptions {
  pipeline: DirtyPathPipeline;
  createWatcher: RepositoryWatcherFactory;
  now?: () => number;
}

interface RepositoryWatcherRegistration {
  watcher: RepositoryFileWatcher;
  subscriptions: DisposableLike[];
  scope: RepositoryWatchScope;
  basePath: string;
}

export class RepositoryWatcherService implements DisposableLike {
  private readonly registrations = new Map<string, RepositoryWatcherRegistration>();
  private readonly now: () => number;

  public constructor(private readonly options: RepositoryWatcherServiceOptions) {
    this.now = options.now ?? Date.now;
  }

  public registerRepository(scope: RepositoryWatchScope): void {
    if (this.registrations.has(scope.repositoryId)) {
      throw new Error(`Repository watcher already registered: ${scope.repositoryId}`);
    }

    const basePath = normalizeWatchRoot(scope.workingCopyRoot);
    this.options.pipeline.registerRepository(scope);
    let watcher: RepositoryFileWatcher;
    try {
      watcher = this.options.createWatcher({
        repositoryId: scope.repositoryId,
        basePath,
        pattern: REPOSITORY_WATCH_PATTERN,
        ignoreCreateEvents: false,
        ignoreChangeEvents: false,
        ignoreDeleteEvents: false,
      });
    } catch (error) {
      this.options.pipeline.unregisterRepository(scope.repositoryId);
      throw error;
    }
    const subscriptions: DisposableLike[] = [];
    try {
      subscriptions.push(watcher.onDidChange((uri) => this.accept(scope.repositoryId, "changed", uri)));
      subscriptions.push(watcher.onDidCreate((uri) => this.accept(scope.repositoryId, "created", uri)));
      subscriptions.push(watcher.onDidDelete((uri) => this.accept(scope.repositoryId, "deleted", uri)));
    } catch (error) {
      disposeRegistration({ watcher, subscriptions });
      this.options.pipeline.unregisterRepository(scope.repositoryId);
      throw error;
    }

    this.registrations.set(scope.repositoryId, { watcher, subscriptions, scope, basePath });
  }

  public replaceRepository(scope: RepositoryWatchScope): void {
    const registration = this.registrations.get(scope.repositoryId);
    if (!registration) {
      throw new Error(`Repository watcher is not registered: ${scope.repositoryId}`);
    }
    const basePath = normalizeWatchRoot(scope.workingCopyRoot);
    if (registration.basePath !== basePath) {
      throw new Error(`Repository watcher root replacement is not supported: ${scope.repositoryId}`);
    }

    registration.scope = scope;
    this.options.pipeline.registerRepository(scope);
  }

  public unregisterRepository(repositoryId: string): void {
    const registration = this.registrations.get(repositoryId);
    if (!registration) {
      return;
    }

    let cleanupError: unknown;
    try {
      disposeRegistration(registration);
    } catch (error) {
      cleanupError = error;
    } finally {
      this.registrations.delete(repositoryId);
      this.options.pipeline.unregisterRepository(repositoryId);
    }
    if (cleanupError) {
      throw cleanupError;
    }
  }

  public dispose(): void {
    for (const repositoryId of Array.from(this.registrations.keys())) {
      this.unregisterRepository(repositoryId);
    }
  }

  private accept(repositoryId: string, kind: RawWatcherEventKind, uri: WatcherUriLike): void {
    this.options.pipeline.accept(repositoryId, {
      fsPath: uri.fsPath,
      kind,
      timestamp: this.now(),
    });
  }
}

function disposeRegistration(registration: Pick<RepositoryWatcherRegistration, "subscriptions" | "watcher">): void {
  const errors: unknown[] = [];
  for (const subscription of registration.subscriptions) {
    try {
      subscription.dispose();
    } catch (error) {
      errors.push(error);
    }
  }
  try {
    registration.watcher.dispose();
  } catch (error) {
    errors.push(error);
  }
  if (errors.length > 0) {
    throw errors[0];
  }
}

function normalizeWatchRoot(path: string): string {
  const normalized = path.replaceAll("\\", "/");
  if (normalized === "/" || /^[A-Za-z]:\/$/u.test(normalized)) {
    return normalized;
  }
  if (/^\/\/[^/]+\/[^/]+\/?$/u.test(normalized)) {
    return normalized.replace(/\/$/u, "");
  }
  return normalized.replace(/\/+$/u, "");
}

import type { RepositoryFileWatcher, RepositoryWatcherFactory } from "./repositoryWatcherService";

export interface VscodeWatcherApi {
  uriFile(path: string): unknown;
  relativePattern(base: unknown, pattern: string): unknown;
  createFileSystemWatcher(
    pattern: unknown,
    ignoreCreateEvents: boolean,
    ignoreChangeEvents: boolean,
    ignoreDeleteEvents: boolean,
  ): RepositoryFileWatcher;
}

export function createVscodeRepositoryWatcherFactory(vscode: VscodeWatcherApi): RepositoryWatcherFactory {
  return (request) => {
    const base = vscode.uriFile(request.basePath);
    const pattern = vscode.relativePattern(base, request.pattern);
    return vscode.createFileSystemWatcher(
      pattern,
      request.ignoreCreateEvents,
      request.ignoreChangeEvents,
      request.ignoreDeleteEvents,
    );
  };
}

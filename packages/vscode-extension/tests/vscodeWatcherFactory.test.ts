import { describe, expect, it, vi } from "vitest";
import { createVscodeRepositoryWatcherFactory } from "../src/status/vscodeWatcherFactory";
import type { RepositoryFileWatcher } from "../src/status/repositoryWatcherService";

describe("createVscodeRepositoryWatcherFactory", () => {
  it("creates VS Code file watchers from repository watcher requests", () => {
    const watcher = fakeWatcher();
    const baseUri = { fsPath: "C:/wc" };
    const relativePattern = { base: baseUri, pattern: "**/*" };
    const api = {
      uriFile: vi.fn().mockReturnValue(baseUri),
      relativePattern: vi.fn().mockReturnValue(relativePattern),
      createFileSystemWatcher: vi.fn().mockReturnValue(watcher),
    };
    const factory = createVscodeRepositoryWatcherFactory(api);

    const result = factory({
      repositoryId: "repo-uuid:C:/wc",
      basePath: "C:/wc",
      pattern: "**/*",
      ignoreCreateEvents: false,
      ignoreChangeEvents: false,
      ignoreDeleteEvents: false,
    });

    expect(result).toBe(watcher);
    expect(api.uriFile).toHaveBeenCalledWith("C:/wc");
    expect(api.relativePattern).toHaveBeenCalledWith(baseUri, "**/*");
    expect(api.createFileSystemWatcher).toHaveBeenCalledWith(relativePattern, false, false, false);
  });
});

function fakeWatcher(): RepositoryFileWatcher {
  return {
    onDidChange: () => ({ dispose: () => undefined }),
    onDidCreate: () => ({ dispose: () => undefined }),
    onDidDelete: () => ({ dispose: () => undefined }),
    dispose: () => undefined,
  };
}
